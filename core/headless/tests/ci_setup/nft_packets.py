"""Packet-level test of the setup firewall, run INSIDE a Linux container (opt-in; see nft_check.sh).

It renders the ruleset with ci_setup.fw, creates a veth pair with one end in a network namespace ("phone", address
192.168.99.20) and the other end ("ap0", 192.168.99.1) in the container, starts listeners on 0.0.0.0 that stand in for the
services of a real host (SSH 22, the CI Hub 5002, Ollama 11434, ...), loads the ruleset with `nft -f`, and checks from the
"phone" what is reachable: the portal on 8080, port 80 and any destination's port 80 redirected to it, DNS to any address
redirected to the local resolver, DHCP from port 68 only; everything else dropped (a timeout, not a refusal). Then it removes the
tables and checks that everything is reachable again, which proves the rules were what blocked it.

Needs root with CAP_NET_ADMIN and CAP_SYS_ADMIN, `nft`, `ip` and python3 in the container. Exit 0 if every expectation holds, 1 if
one does not, 2 if the environment cannot run it. Nothing here is imported by the unit tests.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..")))

PHONE_CODE = r'''
import socket, sys, json
def tcp(host, port, t=1.0):
    s = socket.socket(); s.settimeout(t)
    try:
        s.connect((host, port)); return "OK:" + s.recv(64).decode()
    except socket.timeout: return "TIMEOUT"
    except ConnectionRefusedError: return "REFUSED"
    except OSError as e: return "ERR:%s" % e.errno
    finally: s.close()
def tcp_from(src, host, port, t=1.0):
    s = socket.socket(); s.settimeout(t); s.bind((src, 0))
    try:
        s.connect((host, port)); return "OK:" + s.recv(64).decode()
    except socket.timeout: return "TIMEOUT"
    except OSError as e: return "ERR:%s" % e.errno
    finally: s.close()
def udp(host, port, sport=None, t=1.0, bcast=False):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(t)
    if bcast: s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    if sport: s.bind(("0.0.0.0", sport))
    try:
        s.sendto(b"q", (host, port))
        try: return "OK:" + s.recvfrom(64)[0].decode()
        except socket.timeout: return "NOREPLY"
    except OSError as e: return "ERR:%s" % e.errno
    finally: s.close()
host_other = sys.argv[1]
r = {}
r["tcp ap:8080"] = tcp("192.168.99.1", 8080)
r["tcp ap:80"] = tcp("192.168.99.1", 80)
r["tcp 1.2.3.4:80"] = tcp("1.2.3.4", 80)
r["tcp ap:22"] = tcp("192.168.99.1", 22)
r["tcp ap:5002"] = tcp("192.168.99.1", 5002)
r["tcp ap:11434"] = tcp("192.168.99.1", 11434)
r["tcp ap:8000"] = tcp("192.168.99.1", 8000)
r["tcp host-other-address:5002"] = tcp(host_other, 5002)
r["tcp ap:8080 from a spoofed source"] = tcp_from("10.9.9.9", "192.168.99.1", 8080)
r["udp ap:53"] = udp("192.168.99.1", 53)
r["udp 8.8.8.8:53"] = udp("8.8.8.8", 53)
r["udp ap:67 sport 68"] = udp("192.168.99.1", 67, sport=68)
r["udp ap:67 sport 1234"] = udp("192.168.99.1", 67, sport=1234)
r["udp broadcast:67 sport 68"] = udp("255.255.255.255", 67, sport=68, bcast=True)
print(json.dumps(r))
'''

ALLOWED_AFTER = {
    "tcp ap:8080": "OK:hello:8080",
    "tcp ap:80": "OK:hello:8080",              # redirected to the portal port
    "tcp 1.2.3.4:80": "OK:hello:8080",         # any destination: the captive redirect
    "tcp ap:22": "TIMEOUT", "tcp ap:5002": "TIMEOUT", "tcp ap:11434": "TIMEOUT", "tcp ap:8000": "TIMEOUT",
    "tcp host-other-address:5002": "TIMEOUT",
    "tcp ap:8080 from a spoofed source": "TIMEOUT",   # a source address outside the AP subnet is not served
    "udp ap:53": "OK:dns:53",
    "udp 8.8.8.8:53": "OK:dns:53",             # a hard-coded resolver is redirected to dnsmasq
}
OPEN_BEFORE = {
    "tcp ap:8080": "OK:hello:8080", "tcp ap:22": "OK:hello:22", "tcp ap:5002": "OK:hello:5002",
    "tcp ap:11434": "OK:hello:11434", "tcp ap:8000": "OK:hello:8000", "tcp host-other-address:5002": "OK:hello:5002",
    "tcp ap:8080 from a spoofed source": "OK:hello:8080", "udp ap:53": "OK:dns:53",
}


def sh(*argv, **kw):
    return subprocess.run(list(argv), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, **kw)


def start_listeners(log_dir):
    def tcp(port):
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", port))
        s.listen(16)

        def run():
            while True:
                c, _ = s.accept()
                c.sendall(("hello:%d" % port).encode())
                c.close()
        threading.Thread(target=run, daemon=True).start()

    def udp(port, reply):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("0.0.0.0", port))

        def run():
            while True:
                data, addr = s.recvfrom(512)
                with open(os.path.join(log_dir, "udp-%d.log" % port), "a") as fh:
                    fh.write("%d\n" % addr[1])
                if reply:
                    s.sendto(("dns:%d" % port).encode(), addr)
        threading.Thread(target=run, daemon=True).start()

    for p in (22, 5002, 11434, 8080, 8000):
        tcp(p)
    udp(53, True)
    udp(67, False)


def probe_from_phone(other_addr):
    res = sh("ip", "netns", "exec", "phone", sys.executable, "-c", PHONE_CODE, other_addr)
    return json.loads(res.stdout.strip().splitlines()[-1])


def main():
    if os.geteuid() != 0:
        print("cannot run: needs root in a container")
        return 2
    for tool in ("nft", "ip"):
        if shutil.which(tool) is None:
            print("cannot run: %s not found" % tool)
            return 2
    from ci_setup import fw
    tmp = "/tmp/ci-setup-nft-packets"
    os.makedirs(tmp, exist_ok=True)
    rules, teardown = os.path.join(tmp, "rules.nft"), os.path.join(tmp, "teardown.nft")
    with open(rules, "w") as fh:
        fh.write(fw.render_nft("ap0", "192.168.99.1"))
    with open(teardown, "w") as fh:
        fh.write(fw.render_nft_teardown())
    steps = [
        ("ip", "netns", "add", "phone"), ("ip", "link", "add", "ap0", "type", "veth", "peer", "name", "phone0"),
        ("ip", "link", "set", "phone0", "netns", "phone"), ("ip", "addr", "add", "192.168.99.1/24", "dev", "ap0"),
        ("ip", "link", "set", "ap0", "up"),
        ("ip", "netns", "exec", "phone", "ip", "addr", "add", "192.168.99.20/24", "dev", "phone0"),
        ("ip", "netns", "exec", "phone", "ip", "addr", "add", "10.9.9.9/32", "dev", "phone0"),
        ("ip", "netns", "exec", "phone", "ip", "link", "set", "phone0", "up"),
        ("ip", "netns", "exec", "phone", "ip", "link", "set", "lo", "up"),
        ("ip", "netns", "exec", "phone", "ip", "route", "add", "default", "via", "192.168.99.1"),
    ]
    for argv in steps:
        res = sh(*argv)
        if res.returncode != 0:
            print("cannot run: %s failed: %s" % (" ".join(argv), res.stdout.strip()))
            return 2
    other = None
    for line in sh("ip", "-4", "-o", "addr", "show").stdout.splitlines():
        parts = line.split()
        if parts[1] not in ("lo", "ap0"):
            other = parts[3].split("/")[0]
            break
    if other is None:
        other = "127.0.0.1"
    start_listeners(tmp)
    time.sleep(0.5)

    failures = []

    def expect(label, got, want):
        ok = got == want
        print("%s  %-34s %-18s%s" % ("PASS" if ok else "FAIL", label, got, "" if ok else " (wanted %s)" % want))
        if not ok:
            failures.append(label)

    print("== before the ruleset: every listener answers")
    before = probe_from_phone(other)
    for label, want in OPEN_BEFORE.items():
        expect(label, before[label], want)

    print("== load the ruleset (nft -c, then nft -f)")
    for argv in (("nft", "-c", "-f", rules), ("nft", "-f", rules)):
        res = sh(*argv)
        if res.returncode != 0:
            print("FAIL  %s: %s" % (" ".join(argv), res.stdout.strip()))
            return 1
    tables = sh("nft", "list", "tables").stdout.split("\n")
    expect("tables present", sorted(t for t in tables if t), ["table inet ci_setup", "table ip ci_setup_nat"])
    for f in os.listdir(tmp):
        if f.startswith("udp-"):
            os.unlink(os.path.join(tmp, f))
    after = probe_from_phone(other)
    print("== with the ruleset")
    for label, want in ALLOWED_AFTER.items():
        expect(label, after[label], want)
    expect("udp ap:67 sport 68 reaches dnsmasq", os.path.exists(os.path.join(tmp, "udp-67.log")) and "68" in open(os.path.join(tmp, "udp-67.log")).read().split(), True)
    sources = open(os.path.join(tmp, "udp-67.log")).read().split() if os.path.exists(os.path.join(tmp, "udp-67.log")) else []
    expect("udp ap:67 sport 1234 is dropped", "1234" in sources, False)
    expect("udp broadcast sport 68 reaches dnsmasq", sources.count("68") >= 2, True)

    print("== load it again (idempotent), then remove it")
    expect("second nft -f", sh("nft", "-f", rules).returncode, 0)
    expect("tables after reload", sorted(t for t in sh("nft", "list", "tables").stdout.split("\n") if t),
           ["table inet ci_setup", "table ip ci_setup_nat"])
    expect("teardown", sh("nft", "-f", teardown).returncode, 0)
    expect("no tables left", [t for t in sh("nft", "list", "tables").stdout.split("\n") if t], [])
    expect("teardown twice", sh("nft", "-f", teardown).returncode, 0)
    reopened = probe_from_phone(other)
    print("== after the teardown: everything is reachable again")
    for label, want in OPEN_BEFORE.items():
        expect(label, reopened[label], want)

    sh("ip", "netns", "delete", "phone")
    sh("ip", "link", "delete", "ap0")
    print("== %s" % ("ALL EXPECTATIONS HOLD" if not failures else "FAILED: %s" % ", ".join(failures)))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
