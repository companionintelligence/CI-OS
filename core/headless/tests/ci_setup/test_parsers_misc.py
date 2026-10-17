"""Tests for the nmcli, rfkill, ip -j, wpa_cli/hostapd_cli parsers and the /proc and /sys readers."""
import json
import unittest

import helpers
from ci_setup import sysinfo
from ci_setup.fs import DictFs
from ci_setup.parsers import ipjson, nmcli, rfkill, supplicant


class NmcliTerseTests(unittest.TestCase):
    def test_split_unescapes_colon_and_backslash(self):
        s = nmcli.split_terse_line
        self.assertEqual(["a", "b", "c"], s("a:b:c"))
        self.assertEqual(["a:b", "c"], s("a\\:b:c"))
        self.assertEqual(["a\\", "c"], s("a\\\\:c"))
        self.assertEqual(["a\\:b"], s("a\\\\\\:b"))          # \\ then \:  ->  backslash, colon
        self.assertEqual(["", ""], s(":"))
        self.assertEqual([""], s(""))
        self.assertEqual(["a\\x", "b"], s("a\\x:b"))        # an unknown escape is kept
        self.assertEqual(["trailing\\"], s("trailing\\"))
        self.assertEqual(["AA:BB:CC:DD:EE:FF"], s("AA\\:BB\\:CC\\:DD\\:EE\\:FF"))

    def test_escape_roundtrip(self):
        for fields in (["a", "b"], ["x:y", "z\\w"], ["", ":", "\\"], ["::", "\\\\", "a\\:"], ["no escapes"]):
            line = ":".join(nmcli.escape_terse(f) for f in fields)
            self.assertEqual(fields, nmcli.split_terse_line(line), line)

    def test_rows_with_wrong_field_count_are_dropped(self):
        rows, dropped = nmcli.parse_terse("a:b:c\nonly:two\nx:y:z:extra\n\nok:ok:ok\n", ("A", "B", "C"))
        self.assertEqual(2, dropped)
        self.assertEqual([{"A": "a", "B": "b", "C": "c"}, {"A": "ok", "B": "ok", "C": "ok"}], rows)
        rows, dropped = nmcli.parse_terse("a:b\nc\n")
        self.assertEqual(([["a", "b"], ["c"]], 0), (rows, dropped))


class NmcliCommandTests(unittest.TestCase):
    def test_device_status(self):
        devs = nmcli.parse_device_status(helpers.fixture("nmcli/device_status.txt"))
        by = {d.device: d for d in devs}
        self.assertEqual(9, len(devs))
        self.assertEqual(("connecting", "getting IP configuration", "HomeNet"),
                         (by["wlan0"].state.state, by["wlan0"].state.detail, by["wlan0"].connection))
        self.assertTrue(by["wlan0"].state.is_busy and not by["wlan0"].state.is_up)
        self.assertTrue(by["eth0"].state.is_up)
        self.assertEqual(("connected", "externally"), (by["lo"].state.state, by["lo"].state.detail))
        self.assertEqual("Cafe:Guest", by["wlx00c0caaabbcc"].connection)
        self.assertEqual(("connected", "site only"), (by["wlx00c0caaabbcc"].state.state, by["wlx00c0caaabbcc"].state.detail))
        self.assertEqual("failed", by["wlan3"].state.state)
        self.assertEqual("unmanaged", by["docker0"].state.state)
        self.assertEqual("unavailable", by["wlan1"].state.state)
        self.assertEqual("need authentication", by["wlan2"].state.detail)

    def test_the_old_monitors_blind_spot(self):
        # defect L5: matching only the bare word "connected" misses every one of these
        for text in ("connecting (getting IP configuration)", "connecting (need authentication)",
                     "connecting (configuring)", "connected (externally)", "connected (site only)"):
            st = nmcli.parse_device_state(text)
            self.assertIn(st.state, ("connecting", "connected"), text)
            self.assertNotEqual("unknown", st.state)

    def test_device_state_forms(self):
        p = nmcli.parse_device_state
        self.assertEqual(("connected", ""), (p("100 (connected)").state, p("100 (connected)").detail))
        self.assertEqual(("connecting", "configuring"), (p("50 (connecting (configuring))").state, p("50 (connecting (configuring))").detail))
        self.assertEqual("unmanaged", p("10 (unmanaged)").state)
        self.assertEqual("failed", p("120 (connection failed)").state)
        self.assertEqual("unknown", p("whatever").state)
        self.assertEqual("unknown", p("").state)
        self.assertEqual("connected", p("Connected").state)

    def test_connections_keep_their_type(self):
        cons = nmcli.parse_connection_show(helpers.fixture("nmcli/connection_show.txt"))
        self.assertEqual(8, len(cons))
        wifi = [c.name for c in cons if c.is_wifi]
        self.assertEqual(["HomeNet", "HomeNet 1", "Cafe:Guest", "back\\slash"], wifi)
        wired = [c for c in cons if c.name.startswith("Wired")]
        self.assertEqual(2, len(wired))
        self.assertFalse(any(c.is_wifi for c in wired))
        self.assertEqual("vpn", [c for c in cons if c.name == "work-vpn"][0].type)

    def test_wifi_list(self):
        aps, dropped = nmcli.parse_wifi_list(helpers.fixture("nmcli/wifi_list.txt"))
        self.assertEqual((11, 0), (len(aps), dropped))
        by = {a.bssid: a for a in aps}
        a = by["aa:bb:cc:00:00:02"]
        self.assertEqual((True, "HomeNet", 36, 5180, 80, "wpa2"), (a.in_use, a.ssid, a.channel, a.freq_mhz, a.signal_pct, a.security))
        self.assertEqual("", by["aa:bb:cc:00:00:09"].ssid)                         # hidden
        self.assertEqual("Colon:Net\\Slash", by["aa:bb:cc:00:00:0b"].ssid)
        expect = {"03": "wpa3", "04": "sae-only", "05": "owe", "06": "enterprise", "07": "open", "08": "wep", "0e": "wpa1"}
        for k, sec in expect.items():
            self.assertEqual(sec, by["aa:bb:cc:00:00:" + k].security, k)

    def test_nmcli_security_column(self):
        c = nmcli.classify_nm_security
        self.assertEqual("open", c(""))
        self.assertEqual("open", c("--"))
        self.assertEqual("wep", c("WEP"))
        self.assertEqual("wpa1", c("WPA1"))
        self.assertEqual("wpa2", c("WPA1 WPA2"))
        self.assertEqual("wpa2", c("WPA2"))
        self.assertEqual("wpa3", c("WPA2 WPA3"))
        self.assertEqual("sae-only", c("WPA3"))
        self.assertEqual("owe", c("OWE"))
        self.assertEqual("owe", c("OWE-TM"))
        self.assertEqual("enterprise", c("WPA2 802.1X"))
        self.assertEqual("enterprise", c("WPA-EAP-SUITE-B-192"))
        self.assertEqual("unknown", c("SOMETHING"))

    def test_forged_row_limit_is_documented_by_a_test(self):
        # an SSID holding a newline can forge a row with the right field count; the short row is dropped,
        # the forged complete one cannot be told apart. SSIDs from nmcli are for display only.
        aps, dropped = nmcli.parse_wifi_list(helpers.fixture("nmcli/wifi_list_injection.txt"))
        self.assertEqual(1, dropped)
        self.assertEqual(["Real", "Forged", "Next"], [a.ssid for a in aps])

    def test_connectivity_and_general(self):
        for word in ("full", "limited", "portal", "none", "unknown"):
            self.assertEqual(word, nmcli.parse_connectivity(word + "\n"))
        self.assertEqual("portal", nmcli.parse_connectivity(helpers.fixture("nmcli/connectivity_portal.txt")))
        self.assertEqual("unknown", nmcli.parse_connectivity("garbage"))
        self.assertEqual("unknown", nmcli.parse_connectivity(""))
        g = nmcli.parse_general_status(helpers.fixture("nmcli/general_status.txt"))
        self.assertEqual(("connected", "full"), (g["STATE"], g["CONNECTIVITY"]))
        self.assertEqual({}, nmcli.parse_general_status(""))


class NmcliMultilineTests(unittest.TestCase):
    def test_terse_multiline(self):
        objs = nmcli.parse_multiline(helpers.fixture("nmcli/device_show_terse_multiline.txt"))
        self.assertEqual(2, len(objs))
        self.assertEqual("wlan0", objs[0]["GENERAL.DEVICE"])
        self.assertEqual("192.168.1.20/24", objs[0]["IP4.ADDRESS[1]"])
        self.assertEqual("192.168.1.21/24", objs[0]["IP4.ADDRESS[2]"])
        self.assertEqual("eth0", objs[1]["GENERAL.DEVICE"])
        self.assertEqual("", objs[1]["GENERAL.CONNECTION"])

    def test_values_with_colons_are_not_escaped_in_multiline(self):
        objs = nmcli.parse_multiline("GENERAL.CON-PATH:/org/x:y\nGENERAL.DEVICE:a:b\\c\n")
        self.assertEqual("/org/x:y", objs[0]["GENERAL.CON-PATH"])
        self.assertEqual("a:b\\c", objs[0]["GENERAL.DEVICE"])

    def test_pretty_multiline(self):
        objs = nmcli.parse_multiline(helpers.fixture("nmcli/device_show_pretty_multiline.txt"), terse=False)
        self.assertEqual(2, len(objs))
        self.assertEqual("wlan0", objs[0]["GENERAL.DEVICE"])
        self.assertEqual("", objs[0]["IP4.ADDRESS[1]"])          # "--" means not set
        self.assertEqual("", objs[1]["GENERAL.CONNECTION"])

    def test_dash_separator(self):
        objs = nmcli.parse_multiline("A:1\nB:2\n" + "-" * 40 + "\nA:3\n")
        self.assertEqual([{"A": "1", "B": "2"}, {"A": "3"}], objs)

    def test_device_show(self):
        dev = nmcli.parse_device_show(helpers.fixture("nmcli/device_show_terse_multiline.txt"))
        self.assertEqual(("wlan0", "wifi", "iwlwifi"), (dev[0].device, dev[0].type, dev[0].driver))
        self.assertTrue(dev[0].state.is_up)
        self.assertEqual(("192.168.1.20/24", "192.168.1.21/24"), dev[0].ip4_addresses)
        self.assertEqual("38:11:22:33:44:55", dev[0].hwaddr)
        self.assertEqual("unavailable", dev[1].state.state)
        pretty = nmcli.parse_device_show(helpers.fixture("nmcli/device_show_pretty_multiline.txt"), terse=False)
        self.assertEqual("configuring", pretty[0].state.detail)
        self.assertEqual((), pretty[0].ip4_addresses)


class RfkillTests(unittest.TestCase):
    def test_text(self):
        e = rfkill.parse_rfkill_list(helpers.fixture("rfkill/list_ok.txt"))
        self.assertEqual([("phy0", "wlan", False, False), ("hci0", "bluetooth", True, False)],
                         [(x.device, x.type, x.soft_blocked, x.hard_blocked) for x in e])
        self.assertFalse(e[0].blocked)
        self.assertTrue(e[1].blocked)

    def test_hard_blocked(self):
        e = rfkill.parse_rfkill_list(helpers.fixture("rfkill/list_hard_blocked.txt"))
        state = rfkill.wlan_block_state(e)
        self.assertEqual({"present": True, "soft_blocked": ["phy0"], "hard_blocked": ["phy0"]}, state)

    def test_none_and_junk(self):
        self.assertEqual([], rfkill.parse_rfkill_list(helpers.fixture("rfkill/list_none.txt")))
        self.assertEqual([], rfkill.parse_rfkill_list("0: phy0: Wireless LAN\n"))      # no block lines
        self.assertEqual({"present": False, "soft_blocked": [], "hard_blocked": []}, rfkill.wlan_block_state([]))

    def test_json_matches_text(self):
        a = rfkill.parse_rfkill_list(helpers.fixture("rfkill/list_ok.txt"))
        b = rfkill.parse_rfkill_json(helpers.fixture("rfkill/list.json"))
        self.assertEqual(a, b)
        self.assertEqual([], rfkill.parse_rfkill_json("not json"))
        self.assertEqual([], rfkill.parse_rfkill_json("{}"))
        self.assertEqual([], rfkill.parse_rfkill_json('{"": [5, null, {"id": "x"}]}'))
        self.assertEqual(1, len(rfkill.parse_rfkill_json('{"": [{"id": 0, "type": "wlan", "device": "phy0", "soft": "unblocked", "hard": "blocked"}]}')))


class IpJsonTests(unittest.TestCase):
    """The ip fixtures are REAL captures (iproute2-7.2.0 in a throwaway container with dummy interfaces)."""

    def test_links(self):
        links = ipjson.parse_ip_link(helpers.fixture("real/ip_j_link.json"))
        by = {lk.name: lk for lk in links}
        self.assertEqual(13, len(links))
        self.assertTrue(by["lo"].is_up and by["lo"].has_carrier)
        self.assertFalse(by["tunl0"].is_up)
        self.assertTrue(by["wlan0"].is_up and by["wlan0"].has_carrier)
        self.assertEqual("ether", by["eth0"].link_type)
        self.assertRegex(by["eth0"].mac, r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")

    def test_addresses(self):
        addrs = ipjson.parse_ip_addr(helpers.fixture("real/ip_j_addr.json"))
        v4 = {(a.ifname, a.local, a.prefixlen) for a in addrs if a.family == "inet"}
        self.assertIn(("wlan0", "192.168.1.20", 24), v4)
        self.assertIn(("ap0", "192.168.99.1", 24), v4)
        self.assertTrue(any(a.family == "inet6" for a in addrs))

    def test_routes_and_uplink(self):
        routes = ipjson.parse_ip_route(helpers.fixture("real/ip_j_route.json"))
        self.assertEqual(6, len(routes))
        defaults = ipjson.default_routes(routes)
        self.assertEqual(["eth0", "wlan0"], [r.dev for r in defaults])           # metric 0 before metric 600
        self.assertEqual("eth0", ipjson.uplink_device(routes))
        self.assertEqual("wlan0", ipjson.uplink_device(routes, exclude=("eth0",)))
        self.assertIsNone(ipjson.uplink_device(routes, exclude=("eth0", "wlan0")))
        black = [r for r in routes if r.type == "blackhole"]
        self.assertEqual(["10.99.0.0/16"], [r.dst for r in black])
        self.assertEqual(6, len(routes) - 0)
        self.assertTrue(all(r.is_default for r in defaults))

    def test_used_networks_include_blackholes_and_addresses(self):
        routes = ipjson.parse_ip_route(helpers.fixture("real/ip_j_route.json"))
        addrs = ipjson.parse_ip_addr(helpers.fixture("real/ip_j_addr.json"))
        used = ipjson.used_ipv4_networks(routes, addrs)
        for want in ("10.99.0.0/16", "192.168.1.0/24", "192.168.99.0/24", "172.17.0.0/16", "127.0.0.1/8"):
            self.assertIn(want, used)
        self.assertFalse(any(":" in u for u in used))

    def test_ipv6_routes_parse(self):
        routes = ipjson.parse_ip_route(helpers.fixture("real/ip_j_route6.json"))
        self.assertEqual(["fe80::/64", "fe80::/64"], [r.dst for r in routes])
        self.assertEqual([], ipjson.default_routes(routes))

    def test_tolerant(self):
        for text in ("", "   ", "null", "{}", '"x"', "[1, 2]", "[{}]", "not json", '[{"ifindex": "x", "ifname": 5}]'):
            self.assertEqual([], ipjson.parse_ip_link(text))
            self.assertEqual([], ipjson.parse_ip_route(text))
            self.assertEqual([], ipjson.parse_ip_addr(text))
        self.assertEqual(0, ipjson.parse_ip_route('[{"dst": "default", "dev": "x"}]')[0].metric)
        self.assertEqual("unicast", ipjson.parse_ip_route('[{"dst": "default", "dev": "x"}]')[0].type)

    def test_unusable_default_routes_are_skipped(self):
        routes = ipjson.parse_ip_route(json.dumps([
            {"dst": "default", "type": "unreachable", "metric": 1}, {"dst": "default", "dev": "wlan0", "metric": 5},
            {"dst": "default", "metric": 0}]))
        self.assertEqual(["wlan0"], [r.dev for r in ipjson.default_routes(routes)])


class SupplicantTests(unittest.TestCase):
    def test_wpa_status(self):
        s = supplicant.parse_wpa_status(helpers.fixture("supplicant/wpa_status_completed.txt"))
        self.assertEqual(("COMPLETED", True, "HomeNet", "aa:bb:cc:00:00:02", 5180, "WPA2-PSK", "192.168.1.20"),
                         (s.state, s.connected, s.ssid_escaped, s.bssid, s.freq_mhz, s.key_mgmt, s.ip_address))
        s = supplicant.parse_wpa_status(helpers.fixture("supplicant/wpa_status_scanning.txt"))
        self.assertEqual(("SCANNING", False, None), (s.state, s.connected, s.ssid_hex))
        self.assertEqual("UNKNOWN", supplicant.parse_wpa_status("wpa_state=BOGUS").state)
        self.assertEqual("UNKNOWN", supplicant.parse_wpa_status("").state)

    def test_hostapd_status(self):
        s = supplicant.parse_hostapd_status(helpers.fixture("supplicant/hostapd_status_enabled.txt"))
        self.assertEqual(("ENABLED", True, "ap0", 6, 2437, "g", "DE", 2), (s.state, s.enabled, s.iface, s.channel, s.freq_mhz, s.hw_mode, s.country, s.num_sta))
        self.assertEqual(b"Companion-Setup-AB12".hex(), s.ssid_hex)
        d = supplicant.parse_hostapd_status(helpers.fixture("supplicant/hostapd_status_disabled.txt"))
        self.assertEqual(("DISABLED", False, 0), (d.state, d.enabled, d.num_sta))
        self.assertEqual("UNINITIALIZED", supplicant.parse_hostapd_status("state=WEIRD").state)

    def test_all_sta(self):
        sta = supplicant.parse_hostapd_all_sta(helpers.fixture("supplicant/hostapd_all_sta.txt"))
        self.assertEqual(2, len(sta))
        self.assertEqual((True, 1), (sta[0].authorized, sta[0].aid))
        self.assertIn("AUTHORIZED", sta[0].flags)
        self.assertFalse(sta[1].authorized)

    def test_events(self):
        lines = helpers.fixture("supplicant/hostapd_events.txt").splitlines()
        events = [supplicant.parse_ctrl_event(ln) for ln in lines]
        self.assertEqual(["AP-ENABLED", "AP-STA-CONNECTED", "AP-STA-DISCONNECTED", "AP-STA-CONNECTED",
                          "EAPOL-4WAY-HS-COMPLETED", "CTRL-EVENT-TERMINATING", "AP-DISABLED", None],
                         [e.name if e else None for e in events])
        self.assertEqual("8a:11:22:33:44:01", events[1].mac)
        self.assertEqual(("auth_alg=open",), events[3].args)
        self.assertIsNone(supplicant.parse_ctrl_event(5))
        self.assertIsNone(supplicant.parse_ctrl_event(""))

    def test_kv(self):
        kv = supplicant.parse_kv("a=1\nb=x=y\nnoequals\n=novalue\nc d=1\na=2\n")
        self.assertEqual({"a": "2", "b": "x=y"}, kv)


class SysinfoTests(unittest.TestCase):
    def test_cmdline(self):
        p = sysinfo.parse_cmdline(helpers.fixture("sys/cmdline_stick_headless.txt"))
        self.assertEqual("1", p["ci.headless"])
        self.assertEqual("A", p["ci_stick.slot"])
        self.assertEqual("casper", p["boot"])
        self.assertEqual("", p["quiet"])
        self.assertNotIn("---", p)
        self.assertTrue(sysinfo.is_live_boot(p) and sysinfo.is_stick_boot(p))
        self.assertEqual("1", sysinfo.headless_param(p))

    def test_cmdline_variants(self):
        auto = sysinfo.parse_cmdline(helpers.fixture("sys/cmdline_stick_auto.txt"))
        self.assertEqual("auto", sysinfo.headless_param(auto))
        plain = sysinfo.parse_cmdline(helpers.fixture("sys/cmdline_plain_live.txt"))
        self.assertTrue(sysinfo.is_live_boot(plain) and not sysinfo.is_stick_boot(plain))
        inst = sysinfo.parse_cmdline(helpers.fixture("sys/cmdline_installed.txt"))
        self.assertFalse(sysinfo.is_live_boot(inst) or sysinfo.is_stick_boot(inst))
        arch = sysinfo.parse_cmdline(helpers.fixture("sys/cmdline_arch_live_country.txt"))
        self.assertTrue(sysinfo.is_live_boot(arch))
        self.assertEqual("0", sysinfo.headless_param(arch))
        self.assertEqual("DE", sysinfo.explicit_country(arch))
        q = sysinfo.parse_cmdline(helpers.fixture("sys/cmdline_quoted.txt"))
        self.assertEqual("auto", q["ci.headless"])               # quotes stripped
        self.assertEqual("a b", q["foo"])
        self.assertEqual("FR", q["ci.country"])                   # the last of two wins
        self.assertEqual("auto", sysinfo.headless_param({"ci.headless": "maybe"}))

    def test_cmdline_is_bounded(self):
        p = sysinfo.parse_cmdline(" ".join("k%d=v" % i for i in range(1000)))
        self.assertLessEqual(len(p), 256)
        self.assertEqual({}, sysinfo.parse_cmdline(""))
        self.assertEqual({"a": ""}, sysinfo.parse_cmdline("a"))

    def test_explicit_country_sources(self):
        etc, var = sysinfo.REGDOM_FILES
        self.assertEqual(("/etc/setup-device/regdom", "/var/lib/setup-device/regdom"), (etc, var))
        fs = DictFs(files={var: "fr\nignored\n"})
        self.assertEqual("FR", sysinfo.explicit_country({}, fs))
        self.assertEqual("DE", sysinfo.explicit_country({"ci.country": "de"}, fs))        # the command line wins
        self.assertEqual("FR", sysinfo.explicit_country({"ci.country": "xyz"}, fs))       # junk falls through
        self.assertIsNone(sysinfo.explicit_country({"ci.country": "00"}))
        self.assertIsNone(sysinfo.explicit_country({}, DictFs(files={var: "\n"})))
        both = DictFs(files={etc: "at\n", var: "fr\n"})
        self.assertEqual("AT", sysinfo.explicit_country({}, both))                        # /etc, where the stop-gap reads it, first
        self.assertEqual("FR", sysinfo.explicit_country({}, DictFs(files={etc: "junk\n", var: "fr\n"})))
        self.assertEqual("AT", sysinfo.explicit_country({}, DictFs(files={etc: "at"})))

    def drm_fs(self, fixture_name):
        files = {}
        for line in helpers.fixture(fixture_name).splitlines():
            name, status = line.split()
            files["/sys/class/drm/%s/status" % name] = status + "\n"
        return DictFs(files=files)

    def test_display_state(self):
        self.assertEqual("connected", sysinfo.display_state(self.drm_fs("sys/drm_connected.txt")))
        self.assertEqual("headless", sysinfo.display_state(self.drm_fs("sys/drm_none_connected.txt")))
        self.assertEqual("unknown", sysinfo.display_state(DictFs()))
        status = sysinfo.drm_status(self.drm_fs("sys/drm_connected.txt"))
        self.assertEqual({"eDP-1": "connected", "HDMI-A-1": "disconnected"}, status)        # no Writeback
        self.assertEqual("headless", sysinfo.display_state(DictFs(dirs=["/sys/class/drm"])))

    def test_bus_info(self):
        fs = DictFs(
            files={"/sys/class/net/wlan0/device/vendor": "0x8086\n", "/sys/class/net/wlan0/device/device": "0x2725\n"},
            links={"/sys/class/net/wlan0/device/subsystem": "../../../../../../bus/pci",
                   "/sys/class/net/wlan0/device/driver": "../../../../../../bus/pci/drivers/iwlwifi",
                   "/sys/class/net/wlan0/phy80211": "../../ieee80211/phy0",
                   "/sys/class/net/wlan1/device/subsystem": "../../../../bus/usb"})
        a = sysinfo.bus_info(fs, "wlan0")
        self.assertEqual({"bus": "pci", "driver": "iwlwifi", "vendor": "0x8086", "device": "0x2725", "phy": "phy0"}, a)
        b = sysinfo.bus_info(fs, "wlan1")
        self.assertEqual(("usb", None, None), (b["bus"], b["driver"], b["vendor"]))
        bad = sysinfo.bus_info(fs, "../etc")
        self.assertEqual({k: None for k in ("bus", "driver", "vendor", "device", "phy")}, bad)
        self.assertEqual([0, 0, 1, 2, 3], [sysinfo.bus_rank(x) for x in ("pci", "platform", "sdio", "usb", None)])

    def test_claimed(self):
        self.assertFalse(sysinfo.is_claimed(DictFs()))
        self.assertTrue(sysinfo.is_claimed(DictFs(files={"/var/lib/setup-device/hub.env": ""})))
        self.assertTrue(sysinfo.is_claimed(DictFs(files={"/var/lib/setup-device/cloud_credentials.json": "{}"})))

    def test_zone_tab_real_excerpt(self):
        table = sysinfo.parse_zone_tab(helpers.fixture("sys/zone.tab"))
        self.assertEqual(("DE",), table["Europe/Berlin"])
        self.assertEqual("DE", sysinfo.country_for_timezone("Europe/Berlin", table))
        self.assertEqual("DE", sysinfo.country_for_timezone("Europe/Busingen", table))
        self.assertEqual("JP", sysinfo.country_for_timezone("Asia/Tokyo", table))
        self.assertIsNone(sysinfo.country_for_timezone("Etc/UTC", table))
        self.assertIsNone(sysinfo.country_for_timezone("Europe/Nowhere", table))
        self.assertIsNone(sysinfo.country_for_timezone("../etc/passwd", table))
        self.assertIsNone(sysinfo.country_for_timezone(None, table))

    def test_zone1970_with_shared_zones(self):
        table = sysinfo.parse_zone_tab("# c\nDE,DK,NO,SE\t+5230+01322\tEurope/Berlin\tmany\nUS\t+4042-07400\tAmerica/New_York\n")
        self.assertEqual(("DE", "DK", "NO", "SE"), table["Europe/Berlin"])
        self.assertIsNone(sysinfo.country_for_timezone("Europe/Berlin", table))      # ambiguous
        self.assertEqual("US", sysinfo.country_for_timezone("America/New_York", table))


if __name__ == "__main__":
    unittest.main()
