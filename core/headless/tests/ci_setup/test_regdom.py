"""Tests for ci_setup.regdom: country resolution and the channel plan (never DFS, never 5 GHz without a country)."""
import random
import unittest

import helpers
from ci_setup import regdom
from ci_setup.parsers import iw


def phy(name):
    return iw.parse_iw_phy_info(helpers.fixture("iw_phy_info/%s.txt" % name))[0]


def reg(name):
    return iw.parse_iw_reg_get(helpers.fixture("iw_reg_get/%s.txt" % name))


class CountryTable(unittest.TestCase):
    def test_iso_list(self):
        self.assertEqual(249, len(regdom.ISO_COUNTRIES))
        for code in ("DE", "US", "GB", "JP", "AU", "NZ", "ZW", "AX", "BQ", "SS", "CW", "SX"):
            self.assertIn(code, regdom.ISO_COUNTRIES)
        for code in ("00", "99", "XX", "UK", "EU", "AN", "", "de"):
            self.assertFalse(regdom.is_known_country(code), code)
        self.assertFalse(regdom.is_known_country(None))
        self.assertTrue(all(len(c) == 2 and c.isalpha() and c.isupper() for c in regdom.ISO_COUNTRIES))

    def test_channel_13_class_is_a_subset_of_known_countries(self):
        self.assertTrue(regdom.CH_1_13 <= regdom.ISO_COUNTRIES)
        for c in ("US", "CA", "MX", "TW", "CO", "PA"):
            self.assertNotIn(c, regdom.CH_1_13)
        for c in ("DE", "FR", "GB", "JP", "AU"):
            self.assertIn(c, regdom.CH_1_13)


class ResolveCountry(unittest.TestCase):
    def test_no_source_is_unknown_not_a_default(self):
        d = regdom.resolve_country()
        self.assertEqual((None, "unknown", "none", False), (d.code, d.source, d.confidence, d.known))
        d = regdom.resolve_country(reg_domains=reg("world"))
        self.assertIsNone(d.code)

    def test_explicit_wins(self):
        d = regdom.resolve_country(explicit="fr", reg_domains=reg("us"), scan_votes={"DE": 9}, timezone_country="JP")
        self.assertEqual(("FR", "explicit", "high"), (d.code, d.source, d.confidence))
        self.assertTrue(any("differs" in n for n in d.notes))

    def test_invalid_explicit_falls_through_with_a_note(self):
        for bad in ("00", "99", "ZZ", "DEU", "", "1", "d3"):
            d = regdom.resolve_country(explicit=bad, reg_domains=reg("us"))
            self.assertEqual(("US", "kernel"), (d.code, d.source), bad)
            self.assertTrue(any("ignored" in n for n in d.notes), bad)

    def test_kernel_domain(self):
        d = regdom.resolve_country(reg_domains=reg("us"))
        self.assertEqual(("US", "kernel", "medium", False), (d.code, d.source, d.confidence, d.self_managed))

    def test_kernel_special_markers_are_not_countries(self):
        for markers in (reg("world"), reg("unknown_99_custom")):
            d = regdom.resolve_country(reg_domains=markers, scan_votes={"DE": 4})
            self.assertEqual(("DE", "scan"), (d.code, d.source))

    def test_self_managed_phy(self):
        doms = reg("de_with_selfmanaged_phy")
        d = regdom.resolve_country(reg_domains=doms, phy="phy0")
        self.assertEqual(("DE", "kernel", True), (d.code, d.source, d.self_managed))
        d = regdom.resolve_country(reg_domains=doms, phy="phy1")           # a phy without its own domain
        self.assertEqual(("DE", "kernel", False), (d.code, d.source, d.self_managed))
        d = regdom.resolve_country(explicit="DE", reg_domains=doms, phy="phy0")
        self.assertEqual(("explicit", True), (d.source, d.self_managed))

    def test_scan_vote_rules(self):
        r = regdom.resolve_country
        self.assertEqual("DE", r(scan_votes={"DE": 3}).code)                               # 3 of 3
        self.assertEqual("unknown", r(scan_votes={"DE": 2}).source)                       # too few
        self.assertEqual("DE", r(scan_votes={"DE": 6, "FR": 4}).code)                     # 60 %
        d = r(scan_votes={"DE": 5, "FR": 5})
        self.assertEqual("unknown", d.source)                                             # a tie is not a majority
        self.assertTrue(any("disagree" in n for n in d.notes))
        self.assertEqual("unknown", r(scan_votes={"DE": 5, "FR": 4, "AT": 3}).source)     # 5/12 < 60 %
        self.assertEqual("DE", r(scan_votes={"DE": 4, "00": 50, "99": 50}).code)          # junk codes do not count
        self.assertEqual("unknown", r(scan_votes={"00": 50}).source)
        self.assertEqual("scan", r(scan_votes={"DE": 4}).source)

    def test_timezone_is_last(self):
        d = regdom.resolve_country(timezone_country="JP")
        self.assertEqual(("JP", "timezone", "low"), (d.code, d.source, d.confidence))
        self.assertIsNone(regdom.resolve_country(timezone_country="ZZ").code)

    def test_precedence_order(self):
        order = []
        d = regdom.resolve_country("AT", reg("us"), {"DE": 9}, "JP")
        order.append(d.source)
        d = regdom.resolve_country(None, reg("us"), {"DE": 9}, "JP")
        order.append(d.source)
        d = regdom.resolve_country(None, None, {"DE": 9}, "JP")
        order.append(d.source)
        d = regdom.resolve_country(None, None, None, "JP")
        order.append(d.source)
        d = regdom.resolve_country(None, None, None, None)
        order.append(d.source)
        self.assertEqual(["explicit", "kernel", "scan", "timezone", "unknown"], order)
        self.assertEqual(list(regdom.SOURCES), order)

    def test_to_dict(self):
        self.assertIn("known", regdom.resolve_country(explicit="DE").to_dict())


class PlanChannel(unittest.TestCase):
    def unknown(self):
        return regdom.resolve_country()

    def known(self, code="DE"):
        return regdom.resolve_country(explicit=code)

    def test_unknown_country_world_safe(self):
        plan = regdom.plan_channel(phy("dual_band_world_domain"), self.unknown())
        self.assertTrue(plan.ok and plan.world_safe)
        self.assertEqual("2.4", plan.band)
        self.assertIn(plan.channel, (1, 6, 11))
        self.assertIsNone(plan.country_code)
        self.assertEqual("g", plan.hw_mode)
        self.assertTrue(all(c <= 11 for c in plan.candidates))

    def test_unknown_country_refuses_5ghz_even_when_asked(self):
        for name in ("dual_band_6ghz_ap_sta_2ch_de", "usb_ap_1ch_us", "dual_band_world_domain"):
            plan = regdom.plan_channel(phy(name), self.unknown(), want_band="5")
            self.assertEqual("2.4", plan.band, name)
            self.assertTrue(any("country is unknown" in r for r in plan.reasons))

    def test_known_country_5ghz_skips_dfs_and_prefers_unii1(self):
        plan = regdom.plan_channel(phy("dual_band_6ghz_ap_sta_2ch_de"), self.known(), want_band="5")
        self.assertEqual(("5", 36, "a", "DE"), (plan.band, plan.channel, plan.hw_mode, plan.country_code))
        self.assertEqual((36, 40, 44, 48, 149, 153, 157, 161, 165), plan.candidates)
        for dfs in (52, 56, 60, 64, 100, 140):
            self.assertNotIn(dfs, plan.candidates)
            self.assertIn(str(dfs), plan.rejected)
        self.assertIn("disabled", plan.rejected["144"])
        self.assertFalse(plan.requires_cac)

    def test_5ghz_unusable_in_world_domain_falls_back(self):
        plan = regdom.plan_channel(phy("dual_band_world_domain"), self.known(), want_band="5")
        self.assertEqual("2.4", plan.band)
        self.assertTrue(any("no channel is usable without DFS" in r for r in plan.reasons))
        self.assertTrue(plan.ok)

    def test_5ghz_with_survey_picks_the_quietest(self):
        plan = regdom.plan_channel(phy("dual_band_6ghz_ap_sta_2ch_de"), self.known(), {36: 5, 40: 2, 44: 0}, want_band="5")
        self.assertEqual(44, plan.channel)

    def test_dfs_never_by_default_even_when_only_dfs_is_left(self):
        text = helpers.fixture("iw_phy_info/dual_band_6ghz_ap_sta_2ch_de.txt")
        # make every non-DFS 5 GHz channel disabled
        lines = []
        for ln in text.splitlines():
            if "MHz [" in ln and ("5180" in ln or "5200" in ln or "5220" in ln or "5240" in ln or any(
                    ("%d.0 MHz" % m) in ln for m in (5745, 5765, 5785, 5805, 5825))):
                ln = ln.split("(")[0].rstrip() + " (disabled)"
            lines.append(ln)
        only_dfs = iw.parse_iw_phy_info("\n".join(lines) + "\n")[0]
        plan = regdom.plan_channel(only_dfs, self.known(), want_band="5")
        self.assertEqual("2.4", plan.band)
        plan = regdom.plan_channel(only_dfs, self.known(), want_band="5", allow_dfs=True)
        self.assertEqual("5", plan.band)
        self.assertTrue(plan.requires_cac)
        self.assertIn(plan.channel, (52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140))

    def test_passive_only_channels_are_not_used(self):
        plan = regdom.plan_channel(phy("single_band_ap_world"), self.unknown())
        self.assertEqual([1, 6, 11], sorted(plan.candidates))
        self.assertNotIn(12, plan.candidates)
        self.assertNotIn(13, plan.candidates)
        self.assertIn("12", plan.rejected)
        self.assertEqual("passive only", plan.rejected["12"])
        self.assertEqual("disabled", plan.rejected["14"])

    def test_24ghz_least_loaded(self):
        p = phy("usb_ap_1ch_us")
        # channels 1 and 6 crowded, 11 empty
        plan = regdom.plan_channel(p, self.known("US"), {1: 4, 2: 1, 6: 3, 7: 2, 11: 0})
        self.assertEqual(11, plan.channel)
        plan = regdom.plan_channel(p, self.known("US"), {11: 5, 10: 3, 6: 3, 1: 0})
        self.assertEqual(1, plan.channel)
        # no survey: the tie goes to the middle channel
        self.assertEqual(6, regdom.plan_channel(p, self.known("US")).channel)

    def test_overlapping_channels_count(self):
        # a busy channel 4 hurts channels 1 and 6 (distance 3, 2) more than 11 (distance 7)
        plan = regdom.plan_channel(phy("usb_ap_1ch_us"), self.known("US"), {4: 6})
        self.assertEqual(11, plan.channel)

    def test_channels_12_13_only_with_a_13_country_and_only_as_a_last_resort(self):
        text = helpers.fixture("iw_phy_info/single_band_ap_world.txt")
        # leave only channels 12 and 13 usable
        lines = []
        for ln in text.splitlines():
            if "MHz [" in ln:
                ch = int(ln.split("[")[1].split("]")[0])
                if ch not in (12, 13):
                    ln = ln.split("(")[0].rstrip() + " (disabled)"
                else:
                    ln = "\t\t\t* %d MHz [%d] (20.0 dBm)" % (2407 + 5 * ch, ch)
            lines.append(ln)
        p = iw.parse_iw_phy_info("\n".join(lines) + "\n")[0]
        self.assertFalse(regdom.plan_channel(p, self.unknown()).ok)
        self.assertFalse(regdom.plan_channel(p, self.known("US")).ok)
        plan = regdom.plan_channel(p, self.known("DE"))
        self.assertTrue(plan.ok)
        self.assertIn(plan.channel, (12, 13))

    def test_no_phy_information(self):
        plan = regdom.plan_channel(None, self.unknown())
        self.assertTrue(plan.ok)
        self.assertEqual((6, 1, 11), plan.candidates)
        self.assertIn("no frequency table", " ".join(plan.reasons))
        self.assertEqual("2.4", regdom.plan_channel(None, self.known(), want_band="5").band)

    def test_band_without_24ghz_channels(self):
        p = iw.parse_iw_phy_info("Wiphy phy0\n\tSupported interface modes:\n\t\t * AP\n\tBand 1:\n\t\tFrequencies:\n\t\t\t* 5180 MHz [36] (23.0 dBm)\n")[0]
        plan = regdom.plan_channel(p, self.known())
        self.assertFalse(plan.ok)
        self.assertIn("no_usable_channel", plan.reasons)

    def test_follow_uplink_channel(self):
        p = phy("usb_ap_1ch_us")
        plan = regdom.plan_channel(p, self.known("US"), follow_freq_mhz=5180)
        self.assertEqual((True, "5", 36, (36,)), (plan.ok, plan.band, plan.channel, plan.candidates))
        plan = regdom.plan_channel(p, self.known("US"), follow_freq_mhz=2437)
        self.assertEqual((True, "2.4", 6), (plan.ok, plan.band, plan.channel))
        for mhz, why in ((5260, "radar"), (2467, "disabled"), (9999, "not a")):
            plan = regdom.plan_channel(p, self.known("US"), follow_freq_mhz=mhz)
            self.assertFalse(plan.ok, mhz)
        self.assertFalse(regdom.plan_channel(p, self.unknown(), follow_freq_mhz=5180).ok)         # 5 GHz needs a country
        self.assertTrue(regdom.plan_channel(p, self.unknown(), follow_freq_mhz=2437).ok)
        self.assertFalse(regdom.plan_channel(None, self.known(), follow_freq_mhz=5180).ok)         # nothing to check against
        self.assertFalse(regdom.plan_channel(p, self.unknown(), follow_freq_mhz=2472).ok)          # channel 13 without a country

    def test_property_no_dfs_and_no_unusable_channel_ever(self):
        """Seeded: random frequency tables and countries; the chosen channel is always usable, never radar, never
        5 GHz with an unknown country, never 12+ with an unknown country."""
        rnd = random.Random(helpers.fuzz_seed())
        for _ in range(helpers.fuzz_n(20000) // 20 or 1):
            freqs = []
            for ch in range(1, 15):
                freqs.append(iw.FreqInfo(2407 + 5 * ch if ch < 14 else 2484, ch, "2.4", disabled=rnd.random() < 0.2,
                                         no_ir=rnd.random() < 0.2))
            for ch in (36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 140, 149, 153, 157, 161, 165):
                freqs.append(iw.FreqInfo(5000 + 5 * ch, ch, "5", disabled=rnd.random() < 0.15, no_ir=rnd.random() < 0.2,
                                         radar=ch in (52, 56, 60, 64, 100, 104, 140) and rnd.random() < 0.9))
            p = iw.PhyInfo(name="phy0", modes=("AP", "managed"), freqs=tuple(freqs))
            country = rnd.choice([self.unknown(), self.known("DE"), self.known("US"), self.known("JP")])
            band = rnd.choice(["2.4", "5"])
            survey = {rnd.randint(1, 14): rnd.randint(0, 5) for _ in range(rnd.randint(0, 6))}
            plan = regdom.plan_channel(p, country, survey, want_band=band)
            if not plan.ok:
                continue
            chosen = [f for f in freqs if f.band == plan.band and f.channel == plan.channel][0]
            self.assertTrue(chosen.usable_for_ap, (plan, chosen))
            self.assertFalse(chosen.radar)
            if not country.known:
                self.assertEqual("2.4", plan.band)
                self.assertLessEqual(plan.channel, 11)
                self.assertIsNone(plan.country_code)
            for c in plan.candidates:
                f = [x for x in freqs if x.band == plan.band and x.channel == c][0]
                self.assertTrue(f.usable_for_ap and not f.radar)

    def test_plan_serialises(self):
        import json
        json.dumps(regdom.plan_channel(phy("usb_ap_1ch_us"), self.known("US")).to_dict())


if __name__ == "__main__":
    unittest.main()
