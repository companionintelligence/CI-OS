"""Tests for ci_setup.parsers.iw against the fixtures (hand-written from iw's source; see fixtures/MANIFEST.json)."""
import json
import unittest

import helpers
from ci_setup.parsers import common, iw


class IwDevTests(unittest.TestCase):
    def test_two_phys(self):
        ifs = iw.parse_iw_dev(helpers.fixture("iw_dev/two_phys.txt"))
        self.assertEqual(4, len(ifs))
        by = {(i.phy, i.name): i for i in ifs}
        wlan0 = by[("phy0", "wlan0")]
        self.assertEqual(("managed", 3, "38:11:22:33:44:55", 36, 5180, 80, 22.0),
                         (wlan0.type, wlan0.ifindex, wlan0.mac, wlan0.channel, wlan0.freq_mhz, wlan0.width_mhz,
                          wlan0.txpower_dbm))
        self.assertTrue(wlan0.connected)
        self.assertEqual("HomeNet", wlan0.ssid_escaped)
        self.assertEqual(b"HomeNet".hex(), wlan0.ssid_hex)
        wlan1 = by[("phy1", "wlan1")]
        self.assertFalse(wlan1.connected)
        self.assertIsNone(wlan1.channel)
        p2p = by[("phy0", None)]
        self.assertEqual(("P2P-device", "0x2"), (p2p.type, p2p.wdev))

    def test_ap_interface(self):
        (ap,) = iw.parse_iw_dev(helpers.fixture("iw_dev/ap_running.txt"))
        self.assertEqual(("ap0", "AP", 6, 2437, 20), (ap.name, ap.type, ap.channel, ap.freq_mhz, ap.width_mhz))
        self.assertEqual("Companion-Setup-AB12", ap.ssid_escaped)

    def test_escaped_ssid_is_decoded_and_stays_escaped(self):
        (i,) = iw.parse_iw_dev(helpers.fixture("iw_dev/escaped_ssid.txt"))
        raw = bytes.fromhex(i.ssid_hex)
        self.assertEqual("Caf\U000000e9 Wi-Fi\n\x1b[31m".encode("utf-8"), raw)
        self.assertEqual("Caf\\xc3\\xa9 Wi-Fi\\x0a\\x1b[31m", i.ssid_escaped)
        for ch in i.ssid_escaped:
            self.assertTrue(0x20 <= ord(ch) <= 0x7E)
        self.assertEqual((1, 2412, 20), (i.channel, i.freq_mhz, i.width_mhz))   # "(no HT)" width syntax

    def test_empty(self):
        self.assertEqual([], iw.parse_iw_dev(""))
        self.assertEqual([], iw.parse_iw_dev(helpers.fixture("iw_dev/empty.txt")))
        self.assertEqual([], iw.parse_iw_dev("garbage\nmore garbage\n"))

    def test_to_dict_is_json(self):
        json.dumps([i.to_dict() for i in iw.parse_iw_dev(helpers.fixture("iw_dev/two_phys.txt"))])


class PhyInfoTests(unittest.TestCase):
    def phy(self, name):
        phys = iw.parse_iw_phy_info(helpers.fixture("iw_phy_info/%s.txt" % name))
        self.assertEqual(1, len(phys))
        return phys[0]

    def test_dual_band_6ghz(self):
        p = self.phy("dual_band_6ghz_ap_sta_2ch_de")
        self.assertEqual(("phy0", 0), (p.name, p.index))
        self.assertTrue(p.supports_ap)
        self.assertEqual(("2.4", "5", "6"), p.bands())
        self.assertIn("AP", p.modes)
        self.assertIn("P2P-device", p.modes)
        self.assertNotIn("monitor", p.software_modes[:0])
        self.assertEqual(("AP/VLAN", "monitor"), p.software_modes)
        self.assertIn("start_ap", p.commands)
        self.assertEqual(14 + 25 + 16, len(p.freqs))
        by = {(f.band, f.channel): f for f in p.freqs}
        self.assertTrue(by[("2.4", 14)].disabled)
        self.assertFalse(by[("2.4", 13)].disabled)
        self.assertEqual(2484, by[("2.4", 14)].mhz)
        self.assertEqual(20.0, by[("2.4", 6)].max_dbm)
        self.assertTrue(by[("5", 52)].radar and not by[("5", 52)].no_ir)
        self.assertFalse(by[("5", 52)].usable_for_ap)
        self.assertTrue(by[("5", 36)].usable_for_ap)
        self.assertTrue(by[("5", 144)].disabled)
        self.assertTrue(by[("6", 5)].no_ir)
        self.assertEqual(5975, by[("6", 5)].mhz)
        self.assertEqual(12.0, by[("6", 5)].max_dbm)
        self.assertEqual(1, len(p.combos))
        c = p.combos[0]
        self.assertEqual(3, c.total)
        self.assertEqual(2, c.channels)
        self.assertEqual([(("managed",), 1), (("AP", "P2P-client", "P2P-GO"), 1), (("P2P-device",), 1)],
                         [(lim.types, lim.max) for lim in c.limits])
        self.assertEqual({"channels": 2, "total": 3, "sta_ap_bi_match": False}, iw.concurrent_ap_sta(p.combos))
        self.assertFalse(p.supports_sae)
        self.assertEqual(11, len(p.ext_features))
        self.assertIn("TXQS", p.ext_features)
        self.assertTrue(any("roaming" in n for n in p.notes))

    def test_dfs_sublines_do_not_become_frequencies_or_headers(self):
        p = self.phy("dual_band_6ghz_ap_sta_2ch_de")
        chans5 = [f.channel for f in p.freqs if f.band == "5"]
        self.assertEqual(len(chans5), len(set(chans5)))
        self.assertEqual(25, len(chans5))

    def test_usb_one_channel(self):
        p = self.phy("usb_ap_1ch_us")
        self.assertEqual("phy1", p.name)
        c = p.combos[0]
        self.assertTrue(c.sta_ap_bi_match)
        self.assertEqual(1, c.channels)
        self.assertEqual({"channels": 1, "total": 3, "sta_ap_bi_match": True}, iw.concurrent_ap_sta(p.combos))
        self.assertIn("mesh point", p.modes)
        disabled = sorted(f.channel for f in p.freqs if f.band == "2.4" and f.disabled)
        self.assertEqual([12, 13, 14], disabled)

    def test_station_only_chip(self):
        p = self.phy("sta_only_no_ap")
        self.assertFalse(p.supports_ap)
        self.assertNotIn("start_ap", p.commands)
        self.assertIsNone(iw.concurrent_ap_sta(p.combos))

    def test_ap_in_modes_without_start_ap_command_is_not_ap_capable(self):
        text = helpers.fixture("iw_phy_info/single_band_ap_world.txt").replace("\t\t * start_ap\n", "")
        (p,) = iw.parse_iw_phy_info(text)
        self.assertIn("AP", p.modes)
        self.assertFalse(p.supports_ap)

    def test_world_domain_flags(self):
        p = self.phy("dual_band_world_domain")
        by = {(f.band, f.channel): f for f in p.freqs}
        self.assertTrue(by[("2.4", 12)].no_ir and not by[("2.4", 12)].disabled)
        self.assertTrue(by[("2.4", 14)].disabled)
        for ch in (36, 40, 149, 165):
            self.assertTrue(by[("5", ch)].no_ir and not by[("5", ch)].radar, ch)
        for ch in (52, 100):
            self.assertTrue(by[("5", ch)].no_ir and by[("5", ch)].radar, ch)
        usable5 = [f.channel for f in p.freqs if f.band == "5" and f.usable_for_ap]
        self.assertEqual([], usable5)

    def test_single_band_world(self):
        p = self.phy("single_band_ap_world")
        self.assertEqual(("2.4",), p.bands())
        self.assertEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], [f.channel for f in p.freqs if f.usable_for_ap])

    def test_hwsim_shape(self):
        p = self.phy("hwsim_radio")
        self.assertEqual(2048, p.combos[0].total)
        self.assertEqual({"channels": 2, "total": 2048, "sta_ap_bi_match": False}, iw.concurrent_ap_sta(p.combos))

    def test_radar_widths_and_sae(self):
        p = self.phy("sae_single_channel_radar_widths")
        c = p.combos[0]
        self.assertEqual((20, 40, 80), c.radar_widths)
        self.assertEqual(1, c.channels)
        self.assertTrue(p.supports_sae)
        self.assertIn("SAE_OFFLOAD", p.ext_features)

    def test_iw_list_has_two_wiphys(self):
        phys = iw.parse_iw_phy_info(helpers.fixture("iw_phy_info/iw_list_two_wiphys.txt"))
        self.assertEqual(["phy0", "phy1"], [p.name for p in phys])
        self.assertTrue(phys[0].supports_ap)
        self.assertFalse(phys[1].supports_ap)
        self.assertEqual(1, phys[1].index)

    def test_both_frequency_notations(self):
        # ".0" (iw 6.x) and plain (older) give the same numbers
        a = iw.parse_iw_phy_info("Wiphy phy0\n\tBand 1:\n\t\tFrequencies:\n\t\t\t* 2412.0 MHz [1] (20.0 dBm)\n")[0]
        b = iw.parse_iw_phy_info("Wiphy phy0\n\tBand 1:\n\t\tFrequencies:\n\t\t\t* 2412 MHz [1] (20.0 dBm)\n")[0]
        self.assertEqual(a.freqs, b.freqs)
        self.assertEqual(2412, a.freqs[0].mhz)

    def test_flags_parse(self):
        f = iw._parse_freq("5260", "52", " (23.0 dBm) (no IR, radar detection, indoor only)")
        self.assertTrue(f.no_ir and f.radar and not f.disabled)
        self.assertEqual(("indoor only",), f.other_flags)
        self.assertFalse(f.usable_for_ap)
        f = iw._parse_freq("2467", "12", " (disabled)")
        self.assertTrue(f.disabled)
        self.assertIsNone(f.max_dbm)
        self.assertIsNone(iw._parse_freq("x", "12", ""))

    def test_combination_semantics(self):
        def combo(text):
            return iw.parse_iface_combo(text)

        both_one_group = combo("#{ managed, AP } <= 1, total <= 2, #channels <= 1")
        self.assertIsNone(iw.concurrent_ap_sta((both_one_group,)))          # one slot shared: not both at once
        both_two = combo("#{ managed, AP } <= 2, total <= 2, #channels <= 2")
        self.assertEqual(2, iw.concurrent_ap_sta((both_two,))["channels"])
        sep = combo("#{ managed } <= 1, #{ AP } <= 1, total <= 2, #channels <= 1")
        self.assertEqual(1, iw.concurrent_ap_sta((sep,))["channels"])
        p2p_go_only = combo("#{ managed } <= 1, #{ P2P-GO } <= 1, total <= 2, #channels <= 1")
        self.assertIsNone(iw.concurrent_ap_sta((p2p_go_only,)))            # P2P-GO is not an AP for hostapd
        total_one = combo("#{ managed } <= 1, #{ AP } <= 1, total <= 1, #channels <= 1")
        self.assertIsNone(iw.concurrent_ap_sta((total_one,)))
        best = iw.concurrent_ap_sta((sep, both_two))
        self.assertEqual(2, best["channels"])
        self.assertIsNone(combo("no limits here"))
        self.assertIsNone(combo("#{ managed } <= 1,"))


class RegGetTests(unittest.TestCase):
    def test_world(self):
        (d,) = iw.parse_iw_reg_get(helpers.fixture("iw_reg_get/world.txt"))
        self.assertEqual(("global", None, False, "00", "UNSET"), (d.scope, d.phy, d.self_managed, d.country, d.dfs))
        self.assertEqual(7, len(d.rules))
        self.assertEqual((2402.0, 2472.0, 40.0), (d.rules[0].start_mhz, d.rules[0].end_mhz, d.rules[0].max_bw_mhz))
        self.assertEqual(20.0, d.rules[0].max_eirp_dbm)
        self.assertIn("PASSIVE-SCAN", d.rules[1].flags)
        self.assertEqual(0, d.rules[4].cac_ms)
        self.assertIn("DFS", d.rules[4].flags)

    def test_germany_with_self_managed_phy(self):
        doms = iw.parse_iw_reg_get(helpers.fixture("iw_reg_get/de_with_selfmanaged_phy.txt"))
        self.assertEqual([("global", None, False, "DE", "ETSI"), ("phy", "phy0", True, "DE", "ETSI")],
                         [(d.scope, d.phy, d.self_managed, d.country, d.dfs) for d in doms])
        self.assertEqual(7, len(doms[0].rules))
        self.assertEqual(60000, doms[1].rules[3].cac_ms)
        self.assertEqual(22.0, doms[1].rules[0].max_eirp_dbm)

    def test_us_and_markers(self):
        (us,) = iw.parse_iw_reg_get(helpers.fixture("iw_reg_get/us.txt"))
        self.assertEqual(("US", "FCC"), (us.country, us.dfs))
        self.assertEqual(902.0, us.rules[0].start_mhz)
        doms = iw.parse_iw_reg_get(helpers.fixture("iw_reg_get/unknown_99_custom.txt"))
        self.assertEqual(["99", "98"], [d.country for d in doms])
        self.assertEqual("phy1", doms[1].phy)

    def test_junk(self):
        self.assertEqual([], iw.parse_iw_reg_get(""))
        self.assertEqual([], iw.parse_iw_reg_get("rules without a country\n\t(1 - 2 @ 3)\n"))


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.bss = iw.parse_iw_scan(helpers.fixture("iw_scan/mixed_neighbourhood.txt"))
        self.by = {b.bssid[-2:]: b for b in self.bss}

    def test_count_and_basics(self):
        self.assertEqual(15, len(self.bss))
        a = self.by["01"]
        self.assertEqual(("HomeNet", False, 2437, 6, "2.4", -71.0), (a.ssid, a.hidden, a.freq_mhz, a.channel, a.band, a.signal_dbm))
        self.assertEqual("DE", a.country)
        self.assertTrue(self.by["02"].associated)
        self.assertFalse(a.associated)
        self.assertEqual(36, self.by["02"].channel)
        self.assertEqual("5", self.by["02"].band)
        self.assertEqual("6", self.by["0f"].band)
        self.assertEqual(1, self.by["0f"].channel)

    def test_security_classification(self):
        expect = {"01": "wpa2", "03": "wpa3", "04": "sae-only", "05": "owe", "06": "enterprise", "07": "open",
                  "08": "wep", "0e": "wpa1", "0f": "sae-only"}
        for k, sec in expect.items():
            self.assertEqual(sec, self.by[k].security, k)
        self.assertEqual(("SAE", "PSK"), self.by["03"].akms)
        self.assertEqual(("802.1X",), self.by["06"].akms)

    def test_hidden_networks(self):
        for k in ("09", "0a"):
            self.assertTrue(self.by[k].hidden, k)
            self.assertIsNone(self.by[k].ssid)
        self.assertEqual("", self.by["09"].ssid_hex)
        self.assertEqual("00000000", self.by["0a"].ssid_hex)

    def test_unsafe_ssids_are_never_offered_as_text(self):
        utf8 = self.by["0b"]
        self.assertEqual("Caf\U000000e9 Bar", utf8.ssid)
        self.assertEqual("Caf\\xc3\\xa9 Bar", utf8.ssid_escaped)
        bad = self.by["0c"]
        self.assertIsNone(bad.ssid)                        # \xff\xfe is not UTF-8
        self.assertEqual("bad\\xff\\xfename", bad.ssid_escaped)
        inj = self.by["0d"]
        self.assertIsNone(inj.ssid)                        # contains a newline and a tab
        self.assertNotIn("\n", inj.ssid_escaped)
        self.assertNotIn("\t", inj.ssid_escaped)
        # the injected "freq:" / "SSID:" text inside the SSID must not have been parsed as fields
        self.assertEqual(2422, inj.freq_mhz)
        self.assertEqual(3, inj.channel)

    def test_signal_percent(self):
        self.assertEqual(70, self.by["02"].signal_pct)     # -48 dBm
        self.assertEqual(32, self.by["01"].signal_pct)     # -71 dBm
        self.assertTrue(all(0 <= (b.signal_pct or 0) <= 100 for b in self.bss))
        weak = iw.parse_iw_scan("BSS aa:bb:cc:00:00:01(on wlan0)\n\tfreq: 2412\n\tsignal: -95.00 dBm\n\tSSID: a\n")[0]
        loud = iw.parse_iw_scan("BSS aa:bb:cc:00:00:01(on wlan0)\n\tfreq: 2412\n\tsignal: -10.00 dBm\n\tSSID: a\n")[0]
        self.assertEqual((0, 100), (weak.signal_pct, loud.signal_pct))
        none = iw.parse_iw_scan("BSS aa:bb:cc:00:00:01(on wlan0)\n\tfreq: 2412\n\tSSID: a\n")[0]
        self.assertIsNone(none.signal_pct)

    def test_helpers(self):
        strong = iw.strongest_per_ssid(self.bss)
        names = [b.ssid_hex for b in strong]
        self.assertEqual(1, names.count(b"HomeNet".hex()))
        home = [b for b in strong if b.ssid == "HomeNet"][0]
        self.assertEqual(-48.0, home.signal_dbm)
        self.assertEqual(sorted(strong, key=lambda b: (-b.signal_dbm, b.bssid)), strong)
        hidden = [b for b in strong if b.hidden]
        self.assertEqual(2, len(hidden))                    # two different hidden networks are not merged
        votes = iw.country_votes(self.bss)
        self.assertEqual({"DE": 9, "US": 1}, votes)
        survey = iw.channel_survey(self.bss, "2.4")
        self.assertEqual(4, survey[6])
        self.assertEqual(1, survey[11])
        self.assertNotIn(36, survey)

    def test_old_style_header(self):
        (b,) = iw.parse_iw_scan(helpers.fixture("iw_scan/old_style_header.txt"))
        self.assertEqual(("OldIw", "wpa2", 6), (b.ssid, b.security, b.channel))

    def test_empty(self):
        self.assertEqual([], iw.parse_iw_scan(""))
        self.assertEqual([], iw.parse_iw_scan(helpers.fixture("iw_scan/empty.txt")))


class LinkAndStationTests(unittest.TestCase):
    def test_link(self):
        c = iw.parse_iw_link(helpers.fixture("iw_link/connected.txt"))
        self.assertEqual((True, "aa:bb:cc:00:00:02", 5180, 36, -48.0, "HomeNet"),
                         (c.connected, c.bssid, c.freq_mhz, c.channel, c.signal_dbm, c.ssid_escaped))
        n = iw.parse_iw_link(helpers.fixture("iw_link/not_connected.txt"))
        self.assertEqual((False, None), (n.connected, n.bssid))

    def test_stations(self):
        sta = iw.parse_iw_station_dump(helpers.fixture("iw_station_dump/two_clients.txt"))
        self.assertEqual(2, len(sta))
        self.assertEqual(("8a:11:22:33:44:01", -45.0, 120, 23, True), (sta[0].mac, sta[0].signal_dbm, sta[0].inactive_ms,
                                                                       sta[0].connected_s, sta[0].authorized))
        self.assertFalse(sta[1].authorized)
        self.assertEqual([], iw.parse_iw_station_dump(helpers.fixture("iw_station_dump/empty.txt")))


class SsidDecodeTests(unittest.TestCase):
    def test_iw_decoding(self):
        d = common.decode_iw_ssid
        self.assertEqual(b"abc", d("abc"))
        self.assertEqual(b"a b", d("a b"))
        self.assertEqual(b"\xc3\xa9", d("\\xc3\\xa9"))
        self.assertEqual(b"\\", d("\\\\"))
        self.assertEqual(b"\\", d("\\x5c"))
        self.assertEqual(b"\\x41", d("\\x5cx41"))            # an escaped backslash followed by plain text
        self.assertEqual(b"\\xZZ", d("\\xZZ"))               # not a valid escape: literal
        self.assertEqual(b"\\x4", d("\\x4"))
        self.assertEqual(b"a\\", d("a\\"))
        self.assertEqual("\U000000e9".encode(), d("\U000000e9"))
        self.assertEqual(b"\x00\x00", d("\\x00\\x00"))

    def test_printf_decoding(self):
        d = common.decode_printf_ssid
        self.assertEqual(b'a"b', d('a\\"b'))
        self.assertEqual(b"a\nb\tc\x1b", d("a\\nb\\tc\\e"))
        self.assertEqual(b"\xff", d("\\xff"))
        self.assertEqual(b"\\", d("\\\\"))

    def test_escape_roundtrip_and_safety(self):
        for raw in (b"", b"abc", b"\x00\x01\xff", "\U000000e9".encode(), b"a\nb", b"\\x41", b" lead", bytes(range(256))[:32]):
            esc = common.ssid_escaped(raw)
            self.assertTrue(all(0x20 <= ord(c) <= 0x7E for c in esc))
            self.assertEqual(raw, common.decode_iw_ssid(esc))

    def test_text_and_hidden(self):
        self.assertEqual("Home", common.ssid_text(b"Home"))
        self.assertIsNone(common.ssid_text(b"\xff"))
        self.assertIsNone(common.ssid_text(b"a\nb"))
        self.assertIsNone(common.ssid_text(b""))
        self.assertTrue(common.is_hidden_ssid(b""))
        self.assertTrue(common.is_hidden_ssid(b"\x00\x00\x00"))
        self.assertFalse(common.is_hidden_ssid(b"\x00a"))

    def test_bands_and_channels(self):
        b = common.band_of
        self.assertEqual(["2.4", "2.4", "5", "5", "5", "6", "6", "60", "other"], [b(2412), b(2484), b(5180), b(5885), b(5900), b(5955), b(7115), b(58320), b(900)])
        c = common.freq_to_channel
        self.assertEqual([1, 6, 13, 14, 36, 165, 1, 233, None, None, None],
                         [c(2412), c(2437), c(2472), c(2484), c(5180), c(5825), c(5955), c(7115), c(2413), c(900), c(5181)])

    def test_number_parsing_is_strict(self):
        self.assertEqual(-5, common.to_int(" -5 "))
        self.assertEqual(5, common.to_int("+5"))
        for bad in ("", "1_000", "\U00000663", "1.5", "nan", "0x10", "9" * 30, "--1", "+"):
            self.assertIsNone(common.to_int(bad), bad)
        self.assertEqual(-20.5, common.to_float("-20.5"))
        for bad in ("nan", "inf", "1e5", "1_0.5", "\U00000663", ".5", "5.", "", "--1"):
            self.assertIsNone(common.to_float(bad), bad)


if __name__ == "__main__":
    unittest.main()
