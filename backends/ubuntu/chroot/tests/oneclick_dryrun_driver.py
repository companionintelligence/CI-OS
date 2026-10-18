#!/usr/bin/env python3
"""The Python half of oneclick-subiquity-dryrun.sh: drive the installer's REAL server (dry-run mode) and ci-os-auto-install.

Do not run this by hand; the shell script sets the container up (stubs, the snap extracted from the stock ISO, the server control
script) and calls this with `python3 -I`. What it does, with the server of the 26.04.1 installer snap (ubuntu-desktop-bootstrap
rev 665, `python -m subiquity.cmd.server --dry-run`) as the other end:

  protocol   curl against the server, with the autoinstall document that ci-os-auto-install generates:
             * the OLD confirm request (the tty as a JSON body) -> HTTP 500 `missing required argument "tty"`, state unchanged
             * what the OLD helper did next (remove the file, restart the idle server) -> WAITING, interactive true, for ever
             * a confirm that is not JSON-quoted -> HTTP 500 too; the NEW request (?tty=%22%2Fdev%2Ftty1%22) -> 200
             * NEEDS_CONFIRMATION -> RUNNING -> UU_RUNNING -> DONE, the log says `shutdown ... mode=POWEROFF`, the server exits
  helper     ci-os-auto-install's own run_install() (one copy per call: --helper) against the same server, with only the system
             around it replaced (sudo, systemctl, zenity, the fixture disk): the success path, a file the server does not read,
             a target check that fails

Exit status 0 when every check passed. Evidence goes to stdout; the shell script keeps it in $OUT/.
"""
import argparse
import glob
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from unittest import mock

RUN = os.environ.get("ONECLICK_RUN", "/tmp/ci-os-oneclick-run")
SELF_SH = os.environ["ONECLICK_SELF"]          # the shell script: `--serverctl` starts, restarts and stops the dry-run server
DISK = "/dev/sda"                              # the disk of the dry-run machine (examples/machines/simple.json): 100 GiB
DISK_BYTES = 107374182400
RESULTS = []


def check(ok, text, detail=""):
    RESULTS.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'}  {text}" + (f"   [{detail}]" if detail else ""), flush=True)
    return ok


def note(text):
    print(f"      {text}", flush=True)


def load_helper(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def serverctl(*args):
    r = subprocess.run(["bash", SELF_SH, "--serverctl", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"serverctl {' '.join(args)} failed: {r.stdout}{r.stderr}")
    return r.stdout.strip()


class Server:
    """The dry-run server of one stage: output base /tmp/ci-os-oneclick-run/<name>, socket <out>/socket."""

    def __init__(self, name):
        self.name = name
        self.out = os.path.join(RUN, name)
        self.socket = os.path.join(self.out, "socket")

    def start(self, mode, fresh=True):
        serverctl("start", self.name, mode, "fresh" if fresh else "keep")

    def stop(self):
        serverctl("stop", self.name)

    def curl(self, *args, timeout=10):
        r = subprocess.run(["curl", "-sS", "--max-time", str(timeout), "--unix-socket", self.socket, "-w", "\n%{http_code}", *args],
                           capture_output=True, text=True)
        body, _, code = r.stdout.rpartition("\n")
        return (int(code) if code.isdigit() else 0), body

    def status(self):
        code, body = self.curl("http://a/meta/status", timeout=5)
        try:
            return json.loads(body) if code == 200 else {}
        except ValueError:
            return {}

    def wait_state(self, wanted, timeout=120, poll=0.25):
        """Poll until the state is in `wanted`; returns (state, status, [(seconds, state, interactive) per change])."""
        t0, seen, last = time.time(), [], None
        while time.time() - t0 < timeout:
            st = self.status()
            s = st.get("state")
            if s and s != last:
                seen.append((round(time.time() - t0, 1), s, st.get("interactive")))
                last = s
            if s in wanted:
                return s, st, seen
            time.sleep(poll)
        return last, {}, seen

    def log(self, last_only=False):
        """The debug log of the server: every instance since the stage began (one file per server process), or the last one only."""
        paths = sorted(glob.glob(os.path.join(self.out, "subiquity-server-debug.log.*")), key=os.path.getmtime)
        if last_only:
            paths = paths[-1:]
        text = []
        for path in paths:
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    text.append(fh.read())
            except OSError:
                pass
        return "".join(text)

    def confirm_posts(self, last_only=False):
        """(started, answered with 200, answered with 500) counts of POST /meta/confirm in the server's log."""
        log = self.log(last_only)
        return (log.count("start: subiquity/Meta/confirm_POST"), log.count("finish: subiquity/Meta/confirm_POST: SUCCESS: 200"),
                log.count("finish: subiquity/Meta/confirm_POST: SUCCESS: 500"))


def disk_fixture(path):
    """lsblk -J for the dry-run machine: the stick-less QEMU box, /dev/sda internal and /dev/sr0 the install medium."""
    devs = [
        {"name": "sda", "path": DISK, "size": DISK_BYTES, "type": "disk", "rm": False, "ro": False, "hotplug": False,
         "model": "QEMU HARDDISK", "serial": "QM00001", "tran": "sata", "rota": False, "fstype": None, "label": None,
         "partlabel": None, "mountpoints": [None], "children": []},
        {"name": "sr0", "path": "/dev/sr0", "size": 6482409472, "type": "rom", "rm": True, "ro": False, "hotplug": True,
         "model": "QEMU DVD-ROM", "serial": "QM00003", "tran": "sata", "rota": True, "fstype": "iso9660", "label": "Companion OS",
         "partlabel": None, "mountpoints": ["/cdrom"], "children": []},
    ]
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"blockdevices": devs}, fh)


def document(ai, disk_bytes=DISK_BYTES):
    """The autoinstall file exactly as ci-os-auto-install builds it for the dry-run machine's disk (docker group left out)."""
    pw_hash = ai.hash_password("abcd-efgh-jkmn-pqrs")
    return ai.dump_yaml(ai.build_autoinstall({"path": DISK, "size": disk_bytes}, pw_hash, extra_groups=[])), pw_hash


# ───────────────────────────── stage: protocol ─────────────────────────────

def stage_protocol(helper_path):
    print("\n== protocol: the REAL server, the autoinstall document of ci-os-auto-install, curl as the client", flush=True)
    ai = load_helper(helper_path, "ai_protocol")
    doc, _ = document(ai)
    os.makedirs(RUN, exist_ok=True)
    doc_path = os.path.join(RUN, "protocol-autoinstall.yaml")
    with open(doc_path, "w", encoding="utf-8") as fh:
        fh.write(doc)
    srv = Server("protocol")

    # 1. the document is accepted and the server reaches NEEDS_CONFIRMATION by itself
    srv.start(f"file:{doc_path}")
    state, st, seen = srv.wait_state({"NEEDS_CONFIRMATION", "ERROR", "EXITED"}, timeout=120)
    note("states: " + " -> ".join(f"{s}({t}s)" for t, s, _ in seen))
    check(state == "NEEDS_CONFIRMATION", "the helper's document takes the real server to NEEDS_CONFIRMATION on its own", state)
    check(st.get("interactive") is False, "the server reports interactive=false for it (no interactive-sections)", repr(st.get("interactive")))
    check(any(s == "WAITING" for _, s, _ in seen), "WAITING comes before NEEDS_CONFIRMATION (not instead of it)")
    check("Early/run_user_supplied/command_0: SUCCESS" in srv.log(), "the early-command (the target check) ran and passed")
    check(ai.CONFIRM_TTY == "/dev/tty1", "the helper confirms with tty /dev/tty1", ai.CONFIRM_TTY)

    # 2. the request the first revision of the helper sent: the tty as a JSON body
    code, body = srv.curl("-X", "POST", "-H", "Content-Type: application/json", "-d", json.dumps("/dev/tty1"), "http://a/meta/confirm")
    check(code == 500 and 'missing required argument "tty"' in body, "OLD request (tty as JSON body): HTTP 500, missing required argument \"tty\"",
          f"HTTP {code}: {body.strip().splitlines()[-1] if body.strip() else ''}")
    check(srv.status().get("state") == "NEEDS_CONFIRMATION", "the refused request changed nothing: still NEEDS_CONFIRMATION")

    # 3. the query argument without the JSON quoting is refused as well
    code, body = srv.curl("-X", "POST", "http://a/meta/confirm?tty=/dev/tty1")
    check(code == 500 and "JSONDecodeError" in body, "tty in the query but not JSON-quoted (?tty=/dev/tty1): HTTP 500, JSONDecodeError",
          f"HTTP {code}: {body.strip().splitlines()[-1] if body.strip() else ''}")
    started, ok200, ok500 = srv.confirm_posts()
    check((started, ok200, ok500) == (2, 0, 2), "this server instance saw two confirm requests and refused both", f"{(started, ok200, ok500)}")

    # 4. what the OLD helper did after the 500: dropped its file and restarted the (idle) server -> a stock, interactive server
    copied = os.path.join(srv.out, "autoinstall.yaml")      # the server copies the file it was given to <output base>/autoinstall.yaml
    if os.path.lexists(copied):
        os.unlink(copied)                                    # = remove_autoinstall(): the file at /autoinstall.yaml is gone
    srv.start("root", fresh=False)
    state, st, seen = srv.wait_state({"WAITING", "NEEDS_CONFIRMATION", "ERROR", "EXITED"}, timeout=60)
    time.sleep(25)
    later = srv.status()
    check(state == "WAITING" and st.get("interactive") is True and later.get("state") == "WAITING" and later.get("interactive") is True,
          "after the OLD helper's clean-up restart (no autoinstall file): WAITING, interactive=true, and still there 25 s later "
          "(= the stuck state of the VM run)", f"{later.get('state')} interactive={later.get('interactive')}")

    # 5. the NEW request on a server that has the document again
    srv.start(f"file:{doc_path}", fresh=False)
    state, st, seen = srv.wait_state({"NEEDS_CONFIRMATION", "ERROR", "EXITED"}, timeout=120)
    check(state == "NEEDS_CONFIRMATION" and st.get("interactive") is False, "restarted with the document: NEEDS_CONFIRMATION again", state)
    code, body = srv.curl("-X", "POST", "http://a/meta/confirm?tty=%22%2Fdev%2Ftty1%22")
    check(code == 200, "NEW request (?tty=%22%2Fdev%2Ftty1%22, no body): HTTP 200", f"HTTP {code}")
    state, st, seen = srv.wait_state({"DONE", "ERROR", "EXITED"}, timeout=400)
    note("states after the confirmation: " + " -> ".join(f"{s}({t}s)" for t, s, _ in seen))
    names = [s for _, s, _ in seen]
    check(state == "DONE", "the dry-run install runs to DONE", state)
    check("RUNNING" in names and names.index("RUNNING") < names.index("DONE"), "RUNNING comes before DONE")
    check(st.get("confirming_tty") == "/dev/tty1", "the server recorded the confirming tty", repr(st.get("confirming_tty")))
    time.sleep(8)
    log = srv.log(last_only=True)
    check("Shutdown/shutdown: mode=POWEROFF" in log, "`shutdown: poweroff` of the document is honoured (Shutdown/shutdown: mode=POWEROFF)")
    check("Late/run_user_supplied/command_1: SUCCESS" in log or "Late/run_user_supplied" in log, "the late-commands ran")
    started, ok200, ok500 = srv.confirm_posts(last_only=True)
    note(f"confirm_POST in the log of the restarted server: started {started}, 200 x {ok200}, 500 x {ok500}")
    check((started, ok200, ok500) == (1, 1, 0), "the restarted server saw exactly one confirm request and accepted it", f"{(started, ok200, ok500)}")
    check(srv.status() == {}, "after DONE the server shuts down (dry run: exits; real: the machine powers off) and stops answering")
    srv.stop()

    # 6. what the server does with a confirmation that comes too early (why the helper confirms in NEEDS_CONFIRMATION only)
    srv.start(f"file:{doc_path}")
    state, st, seen = srv.wait_state({"WAITING", "NEEDS_CONFIRMATION"}, timeout=60, poll=0.05)
    early = state
    code = None
    if state == "WAITING":
        code, _ = srv.curl("-X", "POST", "http://a/meta/confirm?tty=%22%2Fdev%2Ftty1%22")
    state2, _, seen2 = srv.wait_state({"RUNNING", "ERROR", "EXITED"}, timeout=60)
    names = []
    for _, s, _ in seen + seen2:
        if not names or names[-1] != s:
            names.append(s)
    note(f"fact: a confirmation sent in {early} (HTTP {code}) is kept by the server and NEEDS_CONFIRMATION is skipped: {' -> '.join(names)}")
    srv.stop()


# ───────────────────────────── stage: helper ─────────────────────────────

class FakeProgress:
    def __init__(self, *a, **k):
        self.lines, self.stdin, self.terminated = [], self, False

    def write(self, text):
        self.lines.append(text)

    def flush(self):
        pass

    def terminate(self):
        self.terminated = True


def run_helper(helper_path, label, scenario):
    """ci-os-auto-install's run_install() against the dry-run server. Returns a dict of what happened."""
    ai = load_helper(helper_path, "ai_" + label)
    srv = Server(label)
    work = os.path.join(RUN, label + "-work")
    os.makedirs(work, exist_ok=True)
    lsblk = os.path.join(work, "lsblk.json")
    disk_fixture(lsblk)
    size = 53687091200 if scenario == "target-check-fails" else DISK_BYTES     # the stub blockdev answers 100 GiB
    doc, _ = document(ai, size)               # the document pins `size`; the stub blockdev says DISK_BYTES
    password = "abcd-efgh-jkmn-pqrs"
    # the settings file goes where the dry-run server looks (<output base>/autoinstall.yaml, the counterpart of /autoinstall.yaml)
    link = os.path.join(srv.out, "autoinstall.yaml")
    ai.SOCKET = srv.socket
    ai.RUN_DIR = os.path.join(work, "run")
    ai.AUTOINSTALL_PATH = os.path.join(ai.RUN_DIR, "autoinstall.yaml")
    ai.AUTOINSTALL_LINK = os.path.join(srv.out, "not-read-by-the-server.yaml") if scenario == "file-not-read" else link
    ai.POLL_SECONDS = 0.5
    ai.FOLLOW_POLL_SECONDS = 0.25
    ai.PREPARE_TIMEOUT = 90
    dialogs, normal = [], []
    prog = FakeProgress()
    real_popen = subprocess.Popen

    def popen(cmd, *a, **k):
        return prog if cmd and cmd[0] == "zenity" else real_popen(cmd, *a, **k)
    target = {"path": DISK, "size": DISK_BYTES}
    srv.start("root")                                     # the stock server of the live session: no file, interactive
    st = srv.wait_state({"WAITING"}, timeout=60)[1]
    env = {"CI_OS_AI_LSBLK_JSON": lsblk, "CI_OS_AI_CDROM_SOURCE": "/dev/sr0",
           "CI_OS_AI_CMDLINE": "BOOT_IMAGE=/casper/vmlinuz boot=casper ci.autoinstall=1 --- quiet splash"}
    t0 = time.time()
    with mock.patch.dict(os.environ, env), \
            mock.patch.object(ai.subprocess, "Popen", side_effect=popen), \
            mock.patch.object(ai, "error_dialog", side_effect=lambda t: dialogs.append(t)), \
            mock.patch.object(ai, "normal_installer", side_effect=lambda: normal.append(1) or 0), \
            mock.patch.object(ai, "zenity", side_effect=lambda a, **k: subprocess.CompletedProcess(a, 0, "", "")):
        rc = ai.run_install(target, doc, password)
    elapsed = time.time() - t0
    state_after = srv.wait_state({"WAITING", "ERROR", "EXITED", "DONE"}, timeout=30)[0]     # a restarted server needs a few seconds
    if state_after == "DONE":
        end = time.time() + 30
        while time.time() < end and "finish: subiquity/Shutdown/shutdown" not in srv.log(last_only=True):
            time.sleep(0.5)
    after = srv.status()
    result = {"rc": rc, "dialogs": dialogs, "normal": len(normal), "elapsed": elapsed, "status_after": after, "posts": srv.confirm_posts(),
              "progress": prog.lines, "terminated": prog.terminated, "link_left": os.path.lexists(ai.AUTOINSTALL_LINK) or
              os.path.lexists(ai.AUTOINSTALL_PATH), "log": srv.log(), "initial_interactive": st.get("interactive"),
              "curtin_calls": open(os.path.join(RUN, "curtin-calls.log")).read() if os.path.exists(os.path.join(RUN, "curtin-calls.log")) else ""}
    srv.stop()
    return result


def stage_helper(helper_path, label_prefix, expect_old=False):
    kind = "OLD" if expect_old else "NEW"
    print(f"\n== helper ({kind}): {helper_path} run_install() against the real server", flush=True)
    if os.path.exists(os.path.join(RUN, "curtin-calls.log")):
        os.unlink(os.path.join(RUN, "curtin-calls.log"))

    # success path
    r = run_helper(helper_path, label_prefix + "-ok", "success")
    note(f"rc={r['rc']} in {r['elapsed']:.0f}s, dialogs={[d[:140] for d in r['dialogs']]}")
    note(f"confirm_POST (started, 200, 500) = {r['posts']}; server after: {r['status_after'] or 'not answering'}")
    if expect_old:
        check(r["rc"] == 7, "OLD helper: the install fails (exit 7)", f"rc={r['rc']}")
        check(any("HTTP 500" in d for d in r["dialogs"]), "OLD helper: the dialog says the installer refused (HTTP 500)")
        check(any("Nothing was erased" in d for d in r["dialogs"]), "OLD helper: ... and that nothing was erased (the safety design held)")
        check(r["posts"][2] == 1 and r["posts"][1] == 0, "OLD helper: the server saw one confirm request and answered it with 500", str(r["posts"]))
        check(r["status_after"].get("state") == "WAITING" and r["status_after"].get("interactive") is True,
              "OLD helper: it leaves a stock server in WAITING, interactive=true (the stuck state of the VM run)", repr(r["status_after"].get("state")))
        check(not r["link_left"], "OLD helper: its autoinstall file and link are gone")
        return
    check(r["rc"] == 0, "NEW helper: run_install returns 0 (DONE)", f"rc={r['rc']}")
    check(not r["dialogs"], "NEW helper: no error dialog", str(r["dialogs"]))
    check(r["posts"] == (1, 1, 0), "NEW helper: exactly one confirm request, answered 200", str(r["posts"]))
    log = r["log"]
    order = [log.find(k) for k in ("Early/run_user_supplied/command_0: SUCCESS", "Meta/confirm_POST", '"state": "RUNNING"', "Shutdown/shutdown: mode=POWEROFF")]
    check(all(i >= 0 for i in order) and order == sorted(order),
          "NEW helper: server log order is target check -> confirm -> RUNNING -> power-off", str(order))
    check("mode=POWEROFF" in log, "NEW helper: `shutdown: poweroff` honoured (mode=POWEROFF)")
    check("curtin in-target --target=/target -- chage -d 0 companion" in r["curtin_calls"],
          "NEW helper: the late-command that expires the one-time password ran")
    check(not r["link_left"], "NEW helper: the autoinstall file and link are removed at the end")
    check(r["terminated"], "NEW helper: the progress window is closed")
    said = " ".join(r["progress"])
    check("Installing Companion OS" in said and all("abcd-efgh-jkmn-pqrs" in ln for ln in r["progress"]),
          "NEW helper: the progress text keeps the sign-in details in every line")
    check(r["normal"] == 0, "NEW helper: the normal installer is not reopened after a success")

    # the settings file is not read by the server
    r = run_helper(helper_path, label_prefix + "-ignored", "file-not-read")
    note(f"rc={r['rc']} in {r['elapsed']:.0f}s, dialogs={[d[:300] for d in r['dialogs']]}")
    check(r["rc"] == 7, "NEW helper, file not read by the server: exit 7", f"rc={r['rc']}")
    check(r["elapsed"] < 60, "... and it says so at once, not after the 10-minute wait", f"{r['elapsed']:.0f}s")
    text = " ".join(r["dialogs"])
    check("interactive" in text and "WAITING" in text, "... the dialog names the state (WAITING) and the mode (interactive)")
    check("/var/log/installer/subiquity-server-debug.log" in text, "... and says where the log is")
    check("Nothing was erased" in text, "... and that nothing was erased")
    check(r["posts"][0] == 0, "... no confirm request was ever sent", str(r["posts"]))
    check(r["normal"] == 1, "... the normal installer is opened again for the user")
    check(r["status_after"].get("state") == "WAITING", "... the server is back in a clean WAITING state", repr(r["status_after"].get("state")))

    # the target check of the document fails inside the real server
    r = run_helper(helper_path, label_prefix + "-target", "target-check-fails")
    note(f"rc={r['rc']} in {r['elapsed']:.0f}s, dialogs={[d[:300] for d in r['dialogs']]}")
    check(r["rc"] == 7, "NEW helper, target check fails in the server: exit 7", f"rc={r['rc']}")
    text = " ".join(r["dialogs"])
    check("did not pass" in text and "ERROR" in text, "... the dialog says the disk check did not pass and names the state (ERROR)")
    check("Nothing was erased" in text, "... and that nothing was erased")
    check(r["posts"][0] == 0, "... no confirm request was ever sent", str(r["posts"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--helper", required=True, help="the current ci-os-auto-install")
    ap.add_argument("--old-helper", help="a copy of the helper from before the fix (git show <rev>:<path>)")
    ap.add_argument("--stage", choices=("protocol", "helper", "all"), default="all")
    args = ap.parse_args()
    os.makedirs(RUN, exist_ok=True)
    if args.stage in ("protocol", "all"):
        stage_protocol(args.helper)
    if args.stage in ("helper", "all"):
        if args.old_helper:
            stage_helper(args.old_helper, "old", expect_old=True)
        stage_helper(args.helper, "new")
    print(f"\n{sum(RESULTS)} of {len(RESULTS)} checks passed", flush=True)
    return 0 if all(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
