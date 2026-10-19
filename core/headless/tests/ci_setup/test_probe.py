"""Tests for ci_setup.probe, ci_setup.runners and ci_setup.fs: radio selection, the read-only runner, whole-probe goldens."""
import json
import os
import unittest

import helpers
from ci_setup import probe, runners
from ci_setup.fs import DictFs, RealFs
from ci_setup.parsers import iw, rfkill

SCENARIOS = ("single_radio_offline", "two_radios_uplink_on_first", "no_ap_capable_radio", "hard_blocked",
             "single_radio_one_channel_uplink", "no_wifi")


def scenario_report(name, fs=None):
    d = helpers.fixture_path("scenarios/" + name)
    return probe.run_probe(probe.fixture_dir_runner(d), fs if fs is not None else probe.fixture_dir_fs(d))


def parsed(dev, phys):
    return iw.parse_iw_dev(helpers.fixture(dev)), {p.name: p for name in phys for p in iw.parse_iw_phy_info(helpers.fixture(name))}


class SelectRadio(unittest.TestCase):
    def test_no_wifi_at_all(self):
        c = probe.select_radio([], {})
        self.assertEqual(("none", "no_wifi"), (c.mode, c.reason))

    def test_dedicated_when_a_second_radio_can_join(self):
        ifs, phys = parsed("iw_dev/two_phys.txt", ["iw_phy_info/dual_band_6ghz_ap_sta_2ch_de.txt", "iw_phy_info/usb_ap_1ch_us.txt"])
        bus = {"wlan0": {"bus": "pci"}, "wlan1": {"bus": "usb"}}
        c = probe.select_radio(ifs, phys, bus, uplink_iface="wlan0", uplink_freq_mhz=5180)
        # wlan0's radio holds the uplink, so the free USB radio hosts the AP and the PCIe radio joins
        self.assertEqual(("dedicated", "phy1", "wlan1", "phy0", "wlan0"), (c.mode, c.ap_phy, c.ap_iface, c.sta_phy, c.sta_iface))

    def test_prefers_pcie_over_usb_when_both_are_free(self):
        ifs, phys = parsed("iw_dev/two_phys.txt", ["iw_phy_info/dual_band_6ghz_ap_sta_2ch_de.txt", "iw_phy_info/usb_ap_1ch_us.txt"])
        ifs = [i if i.name != "wlan0" else iw.IwInterface(phy=i.phy, name=i.name, type="managed") for i in ifs]   # not connected
        bus = {"wlan0": {"bus": "usb"}, "wlan1": {"bus": "pci"}}
        c = probe.select_radio(ifs, phys, bus)
        self.assertEqual(("phy1", "dedicated"), (c.ap_phy, c.mode))
        bus = {"wlan0": {"bus": "pci"}, "wlan1": {"bus": "usb"}}
        c = probe.select_radio(ifs, phys, bus)
        self.assertEqual(("phy0", "dedicated"), (c.ap_phy, c.mode))

    def test_single_radio_two_channels_is_concurrent(self):
        ifs, phys = parsed("iw_dev/ap_running.txt", ["iw_phy_info/dual_band_6ghz_ap_sta_2ch_de.txt"])
        ifs = [iw.IwInterface(phy="phy0", name="wlan0", type="managed")]
        c = probe.select_radio(ifs, phys)
        self.assertEqual(("concurrent", "phy0", "wlan0", None), (c.mode, c.ap_phy, c.ap_iface, c.follow_uplink_mhz))

    def test_single_radio_one_channel_offline_is_sequential(self):
        ifs = [iw.IwInterface(phy="phy1", name="wlan1", type="managed")]
        phys = {p.name: p for p in iw.parse_iw_phy_info(helpers.fixture("iw_phy_info/usb_ap_1ch_us.txt"))}
        c = probe.select_radio(ifs, phys)
        self.assertEqual("sequential", c.mode)
        self.assertTrue(any("share one channel" in n for n in c.notes))

    def test_uplink_on_the_only_radio_with_one_channel_follows_the_uplink(self):
        ifs = [iw.IwInterface(phy="phy1", name="wlan1", type="managed", ssid_hex="00")]
        phys = {p.name: p for p in iw.parse_iw_phy_info(helpers.fixture("iw_phy_info/usb_ap_1ch_us.txt"))}
        c = probe.select_radio(ifs, phys, uplink_iface="wlan1", uplink_freq_mhz=5180)
        self.assertEqual(("concurrent", 5180), (c.mode, c.follow_uplink_mhz))
        c = probe.select_radio(ifs, phys, uplink_iface="wlan1", uplink_freq_mhz=None)
        self.assertEqual("concurrent", c.mode)
        self.assertTrue(any("unknown" in n for n in c.notes))

    def test_uplink_on_a_radio_that_cannot_do_both_is_sequential(self):
        ifs = [iw.IwInterface(phy="phy0", name="wlan0", type="managed", ssid_hex="00")]
        p = iw.parse_iw_phy_info(helpers.fixture("iw_phy_info/single_band_ap_world.txt"))[0]
        p = iw.PhyInfo(name="phy0", index=0, modes=p.modes, combos=(), commands=p.commands, freqs=p.freqs)
        c = probe.select_radio(ifs, {"phy0": p}, uplink_iface="wlan0")
        self.assertEqual("sequential", c.mode)

    def test_station_only_chip(self):
        ifs, phys = parsed("iw_dev/two_phys.txt", ["iw_phy_info/sta_only_no_ap.txt"])
        c = probe.select_radio(ifs[:2] if False else [i for i in ifs if i.phy == "phy0"], phys)
        self.assertEqual(("none", "no_ap_capable_radio"), (c.mode, c.reason))

    def test_hard_block_excludes_a_radio(self):
        ifs = [iw.IwInterface(phy="phy0", name="wlan0", type="managed")]
        phys = {p.name: p for p in iw.parse_iw_phy_info(helpers.fixture("iw_phy_info/dual_band_world_domain.txt"))}
        hard = rfkill.parse_rfkill_list(helpers.fixture("rfkill/list_hard_blocked.txt"))
        c = probe.select_radio(ifs, phys, rfkill_entries=hard)
        self.assertEqual(("none", "hard_blocked"), (c.mode, c.reason))
        soft = rfkill.parse_rfkill_list("0: phy0: Wireless LAN\n\tSoft blocked: yes\n\tHard blocked: no\n")
        c = probe.select_radio(ifs, phys, rfkill_entries=soft)
        self.assertTrue(c.needs_unblock)
        self.assertEqual("concurrent", c.mode)

    def test_phy_without_a_netdev_is_not_usable(self):
        ifs = [iw.IwInterface(phy="phy0", name=None, type="P2P-device")]
        phys = {p.name: p for p in iw.parse_iw_phy_info(helpers.fixture("iw_phy_info/dual_band_world_domain.txt"))}
        self.assertEqual("no_netdev", probe.select_radio(ifs, phys).reason)

    def test_existing_ap_interface_is_reused(self):
        ifs = [iw.IwInterface(phy="phy0", name="wlan0", type="managed"), iw.IwInterface(phy="phy0", name="ap0", type="AP")]
        phys = {p.name: p for p in iw.parse_iw_phy_info(helpers.fixture("iw_phy_info/dual_band_world_domain.txt"))}
        self.assertEqual("ap0", probe.select_radio(ifs, phys).ap_iface)

    def test_to_dict_is_json(self):
        json.dumps(probe.select_radio([], {}).to_dict())


class ProbeScenarios(unittest.TestCase):
    def test_modes(self):
        got = {n: scenario_report(n)["radio"] for n in SCENARIOS}
        self.assertEqual("concurrent", got["single_radio_offline"]["mode"])
        self.assertEqual(("dedicated", "phy1", "wlan1"), (got["two_radios_uplink_on_first"]["mode"], got["two_radios_uplink_on_first"]["ap_phy"], got["two_radios_uplink_on_first"]["ap_iface"]))
        self.assertEqual("no_ap_capable_radio", got["no_ap_capable_radio"]["reason"])
        self.assertEqual("hard_blocked", got["hard_blocked"]["reason"])
        self.assertEqual(("concurrent", 5180), (got["single_radio_one_channel_uplink"]["mode"], got["single_radio_one_channel_uplink"]["follow_uplink_mhz"]))
        self.assertEqual("no_wifi", got["no_wifi"]["reason"])

    def test_country_comes_from_where_the_scenario_says(self):
        self.assertEqual(("DE", "scan"), tuple(scenario_report("single_radio_offline")["country"][k] for k in ("code", "source")))
        self.assertEqual(("DE", "kernel"), tuple(scenario_report("two_radios_uplink_on_first")["country"][k] for k in ("code", "source")))
        self.assertEqual("unknown", scenario_report("no_ap_capable_radio")["country"]["source"])

    def test_following_the_uplink_gives_a_5ghz_channel(self):
        plan = scenario_report("single_radio_one_channel_uplink")["channel_plan"]
        self.assertEqual(("5", 36, (36,)), (plan["band"], plan["channel"], tuple(plan["candidates"])))

    def test_unusable_uplink_channel_downgrades_to_sequential(self):
        # the uplink sits on a DFS channel: the AP cannot follow it
        d = helpers.fixture_path("scenarios/single_radio_one_channel_uplink")
        runner = runners.FixtureRunner.from_dir(d)
        link = helpers.fixture("iw_link/connected.txt").replace("freq: 5180", "freq: 5260")
        dev = helpers.fixture("scenarios/single_radio_one_channel_uplink/iw_dev.txt")
        runner.answers["iw dev wlan0 link"] = runners.CommandResult(0, link)
        rep = probe.run_probe(runners.ReadOnlyRunner(runner), probe.fixture_dir_fs(d))
        self.assertEqual("sequential", rep["radio"]["mode"])
        self.assertIsNone(rep["radio"]["follow_uplink_mhz"])
        self.assertTrue(rep["channel_plan"]["ok"])
        self.assertEqual("2.4", rep["channel_plan"]["band"])
        self.assertIn("sequential", " ".join(rep["radio"]["notes"]))
        self.assertTrue(dev)

    def test_goldens(self):
        for n in SCENARIOS:
            helpers.golden_check(self, "probe_%s.json" % n, helpers.to_json(scenario_report(n)))

    def test_probe_with_filesystem_facts(self):
        files = {"/proc/cmdline": helpers.fixture("sys/cmdline_stick_headless.txt"),
                 "/var/lib/setup-device/hub.env": "X=1\n",
                 "/usr/share/zoneinfo/zone.tab": helpers.fixture("sys/zone.tab"), "/etc/timezone": "Europe/Berlin\n",
                 "/sys/class/drm/card0-HDMI-A-1/status": "disconnected\n"}
        rep = scenario_report("no_ap_capable_radio", DictFs(files=files))
        s = rep["system"]
        self.assertEqual((True, True, "1", True, "headless", "Europe/Berlin", "DE"),
                         (s["live"], s["stick"], s["headless_param"], s["claimed"], s["display"], s["timezone"], s["timezone_country"]))
        self.assertEqual(("DE", "timezone"), (rep["country"]["code"], rep["country"]["source"]))

    def test_no_secrets_or_raw_ssid_text_leak_in_the_report(self):
        text = json.dumps(scenario_report("single_radio_offline"))
        self.assertNotIn("\n", json.dumps(scenario_report("single_radio_offline")["scan"]["networks"][0]["ssid_escaped"]))
        # the neighbour whose SSID forges a field must appear only in escaped form
        self.assertNotIn("SSID: forged\n", text)
        self.assertIn("evil\\\\x0a\\\\x09freq: 9999\\\\x0aSSID: forged", text)

    def test_missing_tools_never_raise(self):
        rep = probe.run_probe(runners.ReadOnlyRunner(runners.FixtureRunner()), DictFs())
        self.assertEqual("no_wifi", rep["radio"]["reason"])
        self.assertTrue(all(c["missing"] for c in rep["commands"].values()))
        json.dumps(rep)

    def test_failing_and_timed_out_commands(self):
        fr = runners.FixtureRunner({"iw dev": runners.CommandResult(rc=1, stderr="boom"),
                                    "ip -j route": runners.CommandResult(rc=124, timed_out=True)})
        rep = probe.run_probe(runners.ReadOnlyRunner(fr), DictFs())
        self.assertEqual(1, rep["commands"]["iw dev"]["rc"])
        self.assertTrue(rep["commands"]["ip -j route"]["timed_out"])

    def test_commands_run_are_all_read_only(self):
        d = helpers.fixture_path("scenarios/two_radios_uplink_on_first")
        fr = runners.FixtureRunner.from_dir(d)
        probe.run_probe(runners.ReadOnlyRunner(fr), probe.fixture_dir_fs(d))
        self.assertGreater(len(fr.calls), 8)
        for argv in fr.calls:
            self.assertTrue(runners.is_read_only_command(argv), argv)


class ReadOnlyRunnerTests(unittest.TestCase):
    ALLOWED = [
        ["iw", "dev"], ["iw", "list"], ["iw", "reg", "get"], ["iw", "phy", "phy0", "info"], ["iw", "dev", "wlan0", "link"],
        ["iw", "dev", "wlan0", "station", "dump"], ["iw", "dev", "wlan0", "scan", "dump"], ["iw", "dev", "wlan0", "info"],
        ["rfkill", "list"], ["ip", "-j", "link"], ["ip", "-j", "addr"], ["ip", "-j", "route"], ["ip", "-j", "-6", "route"],
        ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"],
        ["nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE", "connection", "show"], ["nmcli", "networking", "connectivity"],
        ["nmcli", "-t", "general", "status"], ["nmcli", "-t", "-m", "multiline", "device", "show"],
        ["nmcli", "-t", "-m", "multiline", "device", "show", "wlan0"],
        ["nmcli", "-t", "-f", "IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "no"],
        ["nmcli", "-t", "-f", "IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY", "device", "wifi", "list", "ifname", "wlan0", "--rescan", "no"],
        ["hostapd_cli", "-i", "ap0", "status"], ["hostapd_cli", "-i", "ap0", "all_sta"], ["wpa_cli", "-i", "wlan0", "status"],
        ["hostapd_cli", "-p", "/run/ci-setup/hostapd-ctrl", "-i", "ap0", "status"],
    ]
    REFUSED = [
        [], [""], ["iw"], ["iw", "dev", "wlan0", "scan"], ["iw", "dev", "wlan0", "scan", "trigger"],
        ["iw", "dev", "wlan0", "connect", "x"], ["iw", "dev", "wlan0", "del"], ["iw", "reg", "set", "DE"],
        ["iw", "phy", "phy0", "interface", "add", "ap0", "type", "__ap"], ["iw", "phy", "phy0;x", "info"],
        ["iw", "dev", "wlan0;reboot", "link"], ["iw", "dev", "wl an", "link"], ["iw", "dev", "-h", "link"],
        ["rfkill", "unblock", "all"], ["rfkill", "block", "wlan"], ["ip", "link", "set", "wlan0", "down"],
        ["ip", "addr", "add", "1.2.3.4/24", "dev", "wlan0"], ["ip", "-j", "route", "add", "default"], ["ip", "route", "flush"],
        ["ip", "-j", "link", "set", "wlan0", "up"], ["ip", "-j", "addr", "flush", "dev", "wlan0"],
        ["nmcli", "device", "set", "wlan0", "managed", "no"], ["nmcli", "connection", "delete", "x"],
        ["nmcli", "connection", "add", "type", "wifi"], ["nmcli", "device", "wifi", "connect", "x"],
        ["nmcli", "networking", "connectivity", "check"], ["nmcli", "networking", "off"], ["nmcli", "radio", "wifi", "off"],
        ["nmcli", "-t", "-f", "IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY", "device", "wifi", "list"],            # would rescan
        ["nmcli", "-t", "-f", "IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes"],
        ["nmcli", "-t", "-f", "IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY", "device", "wifi", "rescan"],
        ["nmcli", "-t", "-m", "multiline", "device", "show", "wlan0;x"],
        ["hostapd_cli", "-i", "ap0", "disable"], ["hostapd_cli", "-i", "ap0", "terminate"], ["wpa_cli", "-i", "wlan0", "reconfigure"],
        ["hostapd_cli", "-p", "/etc/shadow", "-i", "ap0", "status"], ["hostapd_cli", "-p", "/run/../etc", "-i", "ap0", "status"],
        ["systemctl", "stop", "hostapd"], ["sh", "-c", "iw dev"], ["docker", "stop", "traefik"], ["nft", "flush", "ruleset"],
        ["sudo", "iw", "dev"], ["iw", "dev\x00"], ["IW", "dev"], ["/sbin/iw", "dev"],
    ]

    def test_allowed(self):
        for argv in self.ALLOWED:
            self.assertTrue(runners.is_read_only_command(argv), argv)

    def test_refused(self):
        for argv in self.REFUSED:
            self.assertFalse(runners.is_read_only_command(argv), argv)

    def test_non_string_arguments_are_refused(self):
        for argv in (["iw", 5], [b"iw", b"dev"], None, ["iw", None], [["iw"]]):
            self.assertFalse(runners.is_read_only_command(argv), argv)

    def test_wrapper_refuses_before_running(self):
        inner = runners.FixtureRunner({"iw dev": "phy#0\n"})
        ro = runners.ReadOnlyRunner(inner)
        self.assertTrue(ro(["iw", "dev"], 1.0).ok)
        with self.assertRaises(runners.ReadOnlyViolation):
            ro(["nmcli", "device", "set", "wlan0", "managed", "no"], 1.0)
        self.assertEqual([["iw", "dev"]], inner.calls)          # the refused command never reached the inner runner

    def test_every_allowed_shape_has_no_verb_that_changes_state(self):
        verbs = {"set", "add", "del", "delete", "up", "down", "flush", "unblock", "block", "connect", "disconnect", "enable",
                 "disable", "reload", "restart", "start", "stop", "off", "on", "modify", "scan"}
        for argv in self.ALLOWED:
            words = set(argv)
            bad = words & verbs
            # "scan" only appears as "scan dump"
            if bad == {"scan"}:
                self.assertEqual("dump", argv[argv.index("scan") + 1], argv)
            else:
                self.assertEqual(set(), bad, argv)

    def test_subprocess_runner_never_raises(self):
        r = runners.SubprocessRunner()
        res = r(["definitely-not-a-program-9f3a"], 2.0)
        self.assertTrue(res.missing and res.rc == 127 and not res.ok)
        res = r(["sh", "-c", "echo hi; echo err >&2; exit 3"], 5.0)
        self.assertEqual((3, "hi\n", "err\n"), (res.rc, res.stdout, res.stderr))
        res = r(["sh", "-c", "sleep 5"], 0.2)
        self.assertTrue(res.timed_out)
        res = r(["sh", "-c", "echo $LC_ALL $HOME_IS_NOT_SET"], 5.0)
        self.assertEqual("C", res.stdout.split()[0])                 # locale pinned so messages parse

    def test_environment_is_minimal(self):
        os.environ["CI_SETUP_TEST_SECRET"] = "sentinel-secret"
        try:
            res = runners.SubprocessRunner()(["sh", "-c", "env"], 5.0)
        finally:
            del os.environ["CI_SETUP_TEST_SECRET"]
        self.assertNotIn("sentinel-secret", res.stdout)


class FsTests(unittest.TestCase):
    def test_dictfs(self):
        fs = DictFs(files={"/a/b/c": "x", "/a/d": "y"}, links={"/a/l": "t"}, dirs=["/e"])
        self.assertEqual(["b", "d", "l"], fs.listdir("/a"))
        self.assertTrue(fs.exists("/a") and fs.exists("/a/b/c") and fs.exists("/a/l") and fs.exists("/e"))
        self.assertFalse(fs.exists("/z") or fs.exists("/a/b/cc"))
        self.assertEqual("x", fs.read_text("/a/b/c"))
        self.assertEqual("", fs.read_text("/a/b/c", 0))
        self.assertIsNone(fs.read_text("/nope"))
        self.assertEqual("t", fs.readlink("/a/l"))

    def test_realfs_never_raises(self):
        fs = RealFs()
        self.assertIsNone(fs.read_text("/definitely/not/here"))
        self.assertIsNone(fs.readlink("/definitely/not/here"))
        self.assertEqual([], fs.listdir("/definitely/not/here"))
        self.assertFalse(fs.exists("/definitely/not/here"))
        self.assertIsNotNone(fs.read_text(helpers.fixture_path("sys/cmdline_installed.txt")))
        self.assertEqual(5, len(fs.read_text(helpers.fixture_path("sys/cmdline_installed.txt"), 5)))


if __name__ == "__main__":
    unittest.main()
