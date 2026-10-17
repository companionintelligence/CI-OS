"""``python3 -m ci_setup selftest``: a fast built-in check that the library works on THIS machine's Python.

It needs no test files and no hardware: the vectors are embedded. It is what an installed system can run to prove the
setup library is intact (``ci-setup doctor`` can call it), and what the unit-test runner runs once more as a smoke test.
Each check returns normally or raises ``AssertionError``; nothing is skipped silently.
"""
from __future__ import annotations

import json
import sys
from typing import Any, Callable, Dict, List, Tuple

from . import apcfg, auth, captive, fw, jobs, policy, qr, regdom, runners, validators, wifi_qr
from .clock import ManualClock
from .errors import ValidationError
from .parsers import ipjson, iw, nmcli, rfkill, supplicant

Check = Callable[[], None]


def _expect(cond: Any, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def _rejects(fn: Callable[..., Any], *args: Any) -> bool:
    try:
        fn(*args)
    except ValidationError:
        return True
    return False


# ------------------------------------------------------------------------------------------------ validators
def check_python() -> None:
    _expect(sys.version_info >= (3, 8), "Python 3.8 or newer is required, found %s" % sys.version.split()[0])


def check_validators() -> None:
    _expect(validators.validate_ssid("\U0001f600" * 8), "eight 4-byte characters (32 bytes) must fit")
    _expect(_rejects(validators.validate_ssid, "\U0001f600" * 9), "nine 4-byte characters (36 bytes) must not fit")
    for bad in ("", "a\nb", "a\x00b", "x" * 33, "\U0000202eabc", "\ud800"):
        _expect(_rejects(validators.validate_ssid, bad), "bad SSID accepted")
    _expect(validators.validate_psk("x" * 8) and validators.validate_psk("x" * 63), "8 and 63 characters are valid")
    _expect(validators.validate_psk("ab" * 32), "64 hex digits are a valid raw key")
    for bad in ("x" * 7, "x" * 64, "pass\nword", "p\U000000e4ssword1", "1234567\n"):
        _expect(_rejects(validators.validate_psk, bad), "bad passphrase accepted")
    _expect(_rejects(validators.parse_ipv4, "192.168.099.1"), "leading zero accepted")
    _expect(validators.validate_ipv4_subnet("192.168.99.0/24").cidr() == "192.168.99.0/24", "subnet")
    _expect(_rejects(validators.validate_ipv4_subnet, "192.168.99.1/24"), "host bits accepted")
    _expect(_rejects(validators.validate_ifname, "a" * 16) and _rejects(validators.validate_ifname, 'wl"an'), "ifname")
    _expect(validators.validate_mac("AA-BB-CC-00-11-22") == "aa:bb:cc:00:11:22", "mac")
    _expect(_rejects(validators.loads_strict, '{"a":1,"a":2}') and _rejects(validators.loads_strict, "[NaN]"), "json")


# ------------------------------------------------------------------------------------------------ parsers
_IW_DEV = "phy#0\n\tInterface wlan0\n\t\tifindex 3\n\t\ttype managed\n\t\tssid Home\\x20Net\n"
_PHY = ("Wiphy phy0\n\twiphy index: 0\n\tSupported interface modes:\n\t\t * managed\n\t\t * AP\n\tBand 1:\n"
        "\t\tFrequencies:\n\t\t\t* 2412 MHz [1] (20.0 dBm)\n\t\t\t* 2467 MHz [12] (disabled)\n"
        "\tBand 2:\n\t\tFrequencies:\n\t\t\t* 5260 MHz [52] (23.0 dBm) (no IR, radar detection)\n"
        "\t\t\t  DFS state: usable (for 3 sec)\n\t\t\t* 5180 MHz [36] (23.0 dBm)\n"
        "\tvalid interface combinations:\n\t\t * #{ managed } <= 1, #{ AP } <= 1,\n\t\t   total <= 2, #channels <= 2\n")


def check_parsers() -> None:
    ifs = iw.parse_iw_dev(_IW_DEV)
    _expect(len(ifs) == 1 and ifs[0].name == "wlan0" and ifs[0].ssid_escaped == "Home Net", "iw dev")
    phy = iw.parse_iw_phy_info(_PHY)[0]
    _expect(phy.supports_ap and phy.bands() == ("2.4", "5"), "iw phy info modes/bands")
    by_ch = {f.channel: f for f in phy.freqs}
    _expect(by_ch[12].disabled and by_ch[52].radar and by_ch[52].no_ir and by_ch[36].usable_for_ap, "frequency flags")
    _expect(iw.concurrent_ap_sta(phy.combos) == {"channels": 2, "total": 2, "sta_ap_bi_match": False}, "AP+STA combo")
    reg = iw.parse_iw_reg_get("global\ncountry DE: DFS-ETSI\n\t(2400 - 2483 @ 40), (N/A, 20), (N/A)\n"
                              "\nphy#0 (self-managed)\ncountry 99: DFS-UNSET\n")
    _expect(reg[0].country == "DE" and reg[1].self_managed and reg[1].phy == "phy0", "iw reg get")
    rows, dropped = nmcli.parse_terse("*:Home\\:Net:AA\\:BB\\:CC\\:DD\\:EE\\:FF:WPA2\nbroken\n",
                                      ("IN-USE", "SSID", "BSSID", "SECURITY"))
    _expect(dropped == 1 and rows[0]["SSID"] == "Home:Net" and rows[0]["BSSID"] == "AA:BB:CC:DD:EE:FF", "nmcli -t")
    st = nmcli.parse_device_state("connecting (getting IP configuration)")
    _expect(st.state == "connecting" and st.is_busy and not st.is_up, "nmcli device state")
    _expect(nmcli.classify_nm_security("WPA2 WPA3") == "wpa3" and nmcli.classify_nm_security("") == "open", "security")
    rf = rfkill.parse_rfkill_list("0: phy0: Wireless LAN\n\tSoft blocked: no\n\tHard blocked: yes\n")
    _expect(rf[0].hard_blocked and rf[0].type == "wlan", "rfkill")
    routes = ipjson.parse_ip_route('[{"dst":"default","gateway":"10.0.0.1","dev":"eth0","metric":100},'
                                   '{"dst":"default","gateway":"10.0.1.1","dev":"wlan0","metric":600}]')
    _expect(ipjson.uplink_device(routes) == "eth0", "ip route uplink")
    _expect(supplicant.parse_ctrl_event("<3>AP-STA-CONNECTED 8a:11:22:33:44:01").mac == "8a:11:22:33:44:01", "ctrl event")


# ------------------------------------------------------------------------------------------------ regdom, policy
def check_regdom() -> None:
    phy = iw.parse_iw_phy_info(_PHY)[0]
    unknown = regdom.resolve_country()
    _expect(not unknown.known and unknown.source == "unknown", "no source must mean unknown, never a default")
    plan = regdom.plan_channel(phy, unknown, want_band="5")
    _expect(plan.ok and plan.band == "2.4" and plan.channel in (1, 6, 11) and plan.world_safe, "unknown country: 2.4 GHz only")
    de = regdom.resolve_country(explicit="DE")
    p5 = regdom.plan_channel(phy, de, want_band="5")
    _expect(p5.ok and p5.band == "5" and p5.channel == 36 and 52 not in p5.candidates, "5 GHz must skip DFS")
    _expect(regdom.resolve_country(scan_votes={"DE": 2}).source == "unknown", "two votes are not enough")
    _expect(regdom.resolve_country(scan_votes={"DE": 4, "FR": 1}).code == "DE", "scan majority")


def check_policy() -> None:
    n = 0
    for inp, dec in policy.iter_matrix():
        n += 1
        if dec.mode == "auto" and dec.offer_ap:
            _expect(inp.context != "installed-claimed", "a claimed appliance must never open the AP by itself")
            _expect(inp.display == "headless", "a machine with a display must not become a hotspot by itself")
            _expect(inp.network == "down" and inp.headless_param != "0", "auto AP with network up or switched off")
            _expect(not (inp.context == "live" and not inp.stick), "plain live media opens no AP by itself")
        if dec.offer_ap:
            _expect(dec.credential_channel is not None, "AP offered with no way to show the credentials")
    _expect(n == 144, "matrix size changed: %d" % n)
    d = policy.decide(policy.PolicyInput("installed-claimed", "headless", "down", triggers=("http_request",),
                                         has_setup_key=True))
    _expect(not d.offer_ap and d.ignored_triggers == ("http_request",), "an unknown trigger must have no effect")
    d = policy.decide(policy.PolicyInput("installed-claimed", "headless", "down", headless_param="1", has_setup_key=True))
    _expect(d.offer_ap and d.mode == "explicit", "ci.headless=1 must work as recovery")


# ------------------------------------------------------------------------------------------------ auth
def check_auth() -> None:
    key = auth.generate_ap_key()
    _expect(auth.is_valid_ap_key(key), "AP key shape")
    pin = auth.generate_pin()
    _expect(len(pin) == 6 and all(c in "0123456789" for c in pin), "PIN shape")
    _expect(auth.derive_credentials("ABCD-EFGH-JKMN-PQRS") == auth.derive_credentials("abcdefghjkmnpqrs"), "derivation")
    clock = ManualClock()
    gate = auth.PinGate(clock=clock, pin="123456")
    _expect(gate.attempt("10.0.0.2", "000000").status == "wrong", "wrong PIN")
    _expect(gate.attempt("10.0.0.2", "123456").status == "backoff", "back-off after a failure")
    clock.advance(2)
    res = gate.attempt("10.0.0.2", "123456")
    _expect(res.status == "ok" and res.token, "right PIN after the back-off")
    _expect(gate.issuer.verify(res.token, "10.0.0.2") is not None, "token verifies for its client")
    _expect(gate.issuer.verify(res.token, "10.0.0.3") is None, "token must be bound to the client address")
    forged = res.token[:-1] + ("0" if res.token[-1] != "0" else "1")
    _expect(gate.issuer.verify(forged, "10.0.0.2") is None, "altered token accepted")
    clock.advance(901)
    _expect(gate.issuer.verify(res.token, "10.0.0.2") is None, "expired token accepted")
    g2 = auth.PinGate(clock=ManualClock(), pin="123456")
    seen = []
    for i in range(8):
        r = g2.attempt("10.0.0.%d" % (10 + i), "000000")
        seen.append(r.status)
    _expect("rotated" in seen and g2.current_pin() != "123456", "PIN must rotate after repeated failures: %s" % seen)
    _expect(auth.consteq("a", "a") and not auth.consteq("a", None) and not auth.consteq("\ud800", "x"), "consteq")


# ------------------------------------------------------------------------------------------------ qr, captive
def check_wifi_qr() -> None:
    _expect(wifi_qr.wifi_payload("Companion-Setup-AB12", "ABCDEFGHJKMN") == "WIFI:T:WPA;S:Companion-Setup-AB12;P:ABCDEFGHJKMN;;",
            "payload")
    _expect(wifi_qr.escape_field('foo;bar\\baz"') == 'foo\\;bar\\\\baz\\"', "escaping")
    _expect(wifi_qr.wifi_payload("ABCD", "12345678") == 'WIFI:T:WPA;S:"ABCD";P:"12345678";;', "hex-like values are quoted")


def check_qr() -> None:
    _expect(qr.rs_remainder([32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17], 10)
            == [196, 35, 39, 119, 235, 215, 231, 226, 93, 23], "Reed-Solomon worked example of the standard")
    _expect(qr.format_word("L", 0) == 0x77C4 and qr.format_word("M", 0) == 0x5412, "format words")
    code = qr.encode(wifi_qr.wifi_payload("Companion-Setup-AB12", "ABCDEFGHJKMN"), "M")
    _expect((code.version, code.size) == (4, 33), "the access point code is version 4: %r" % ((code.version, code.size),))
    text = qr.render_ansi(code)
    _expect(text.count("\n") == 19 and text.startswith("\x1b[30;47m"), "console rendering")
    _expect(wifi_qr.console_qr(";" * 32, "\\" * 63, ecl="H") is None, "an over-long payload must not be encoded")


def check_captive() -> None:
    for path in sorted(captive.PROBE_PATHS):
        st, hdr, _ = captive.probe_response("GET", path, "pending", "192.168.99.1")
        _expect(st == 302 and dict(hdr)["Location"] == "http://192.168.99.1/", "pending probe must redirect: " + path)
    _expect(captive.probe_response("GET", "/generate_204", "done", "192.168.99.1")[0] == 204, "android done")
    body = captive.probe_response("GET", "/hotspot-detect.html", "done", "192.168.99.1")[2]
    _expect(b"Success" in body, "apple done")


# ------------------------------------------------------------------------------------------------ jobs
def check_jobs() -> None:
    clock = ManualClock()
    j = jobs.Job("0123456789abcdef", clock)
    for ev, kw in (("start", {}), ("probe_ok", {"phy": "phy0", "iface": "wlan0", "mode": "sequential"}),
                   ("ap_started", {}), ("client_associated", {"mac": "8a:11:22:33:44:01"}), ("authenticated", {}),
                   ("credentials", {"ssid": "Home", "security": "wpa2"}), ("join_started", {}),
                   ("join_ok", {}), ("verify_ok", {})):
        r = j.apply(ev, **kw)
        _expect(r.accepted, "%s rejected: %s" % (ev, r.reason))
        clock.advance(1)
    _expect(j.state == jobs.DONE and j.outcome == "joined", "happy path")
    _expect(not j.apply("start").accepted, "a finished job must absorb events")
    _expect(not jobs.Job("0123456789abcdef", clock).apply("probe_ok", psk="x").accepted, "secret field accepted")
    snap = json.loads(json.dumps(j.snapshot()))
    _expect(jobs.Job.restore(snap, clock).snapshot() == j.snapshot(), "snapshot round trip")
    k = jobs.Job("fedcba9876543210", clock)
    k.apply("start")
    clock.advance(61)
    _expect(k.tick().reason == "timeout" and k.state == jobs.FAILED, "probe timeout")


# ------------------------------------------------------------------------------------------------ renderers
def check_render() -> None:
    hostapd = apcfg.render_hostapd(apcfg.ApParams("wlan0", "Companion-Setup-AB12", "ABCDEFGHJKMN", 6, "2.4", "DE"))
    _expect("ssid2=" in hostapd and "ap_isolate=1" in hostapd and "country_code=DE" in hostapd, "hostapd")
    hostapd = apcfg.render_hostapd(apcfg.ApParams("wlan0", "x", "ABCDEFGHJKMN", 6))
    _expect("country_code" not in hostapd.replace("# country_code omitted", ""), "unknown country must omit country_code")
    dns = apcfg.render_dnsmasq(apcfg.DhcpParams("wlan0"))
    _expect("log-queries" not in dns and "address=/#/192.168.99.1" in dns, "dnsmasq")
    nft = fw.render_nft("wlan0", "192.168.99.1")
    lines = [ln.strip() for ln in nft.splitlines()]
    _expect("type filter hook prerouting priority raw; policy accept;" in lines, "firewall must hook at raw")
    _expect(lines.index('iifname "wlan0" drop') > lines.index('iifname "wlan0" udp sport 68 udp dport 67 accept'),
            "the catch-all drop must come after the accepts")
    _expect("masquerade" not in nft and "snat" not in nft, "no NAT out of the access point")
    sub = apcfg.pick_ap_subnet(["192.168.99.0/24", "10.77.0.0/24"])
    _expect(sub.cidr() == "10.77.1.0/24", "subnet collision: " + sub.cidr())


def check_read_only() -> None:
    ro = runners.ReadOnlyRunner(runners.FixtureRunner({"iw dev": "phy#0\n"}))
    _expect(ro(["iw", "dev"], 1.0).ok, "allowed command")
    for argv in (["nmcli", "device", "set", "wlan0", "managed", "no"], ["iw", "dev", "wlan0", "scan"],
                 ["ip", "link", "set", "wlan0", "down"], ["nmcli", "networking", "connectivity", "check"],
                 ["systemctl", "stop", "hostapd"], ["iw", "dev", "wlan0;reboot", "link"]):
        try:
            ro(argv, 1.0)
        except runners.ReadOnlyViolation:
            continue
        raise AssertionError("not refused: " + " ".join(argv))


CHECKS: List[Tuple[str, Check]] = [
    ("python version", check_python), ("validators", check_validators), ("parsers", check_parsers),
    ("regulatory domain", check_regdom), ("policy matrix", check_policy), ("credentials and tokens", check_auth),
    ("wifi qr payload", check_wifi_qr), ("qr encoder", check_qr), ("captive portal answers", check_captive), ("job state machine", check_jobs),
    ("config renderers", check_render), ("read-only runner", check_read_only),
]


def run_selftest() -> Dict[str, Any]:
    results = []
    for name, fn in CHECKS:
        try:
            fn()
            results.append({"name": name, "ok": True, "detail": ""})
        except Exception as exc:  # a failing check must be reported, whatever it raised
            results.append({"name": name, "ok": False, "detail": "%s: %s" % (type(exc).__name__, str(exc)[:300])})
    return {"ok": all(r["ok"] for r in results), "python": sys.version.split()[0], "checks": results}
