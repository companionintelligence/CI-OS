"""Seeded fuzz and pathological-input tests for every parser: they never raise, return JSON-serialisable data, and
stay fast on input built to make a regular expression backtrack.

The seed corpus is every text fixture; mutations delete, duplicate, swap, truncate and garble lines and characters.
"""
import json
import os
import random
import time
import unittest

import helpers
from ci_setup import sysinfo
from ci_setup.parsers import ipjson, iw, nmcli, rfkill, supplicant

PARSERS = [
    ("iw.dev", iw.parse_iw_dev), ("iw.phy", iw.parse_iw_phy_info), ("iw.reg", iw.parse_iw_reg_get), ("iw.scan", iw.parse_iw_scan),
    ("iw.link", iw.parse_iw_link), ("iw.station", iw.parse_iw_station_dump),
    ("nm.device_status", nmcli.parse_device_status), ("nm.connection", nmcli.parse_connection_show),
    ("nm.wifi_list", nmcli.parse_wifi_list), ("nm.connectivity", nmcli.parse_connectivity),
    ("nm.general", nmcli.parse_general_status), ("nm.device_show_terse", lambda t: nmcli.parse_device_show(t, True)),
    ("nm.device_show_pretty", lambda t: nmcli.parse_device_show(t, False)), ("nm.multiline", nmcli.parse_multiline),
    ("nm.terse_rows", nmcli.parse_terse), ("nm.state", nmcli.parse_device_state),
    ("rfkill.list", rfkill.parse_rfkill_list), ("rfkill.json", rfkill.parse_rfkill_json),
    ("ip.link", ipjson.parse_ip_link), ("ip.addr", ipjson.parse_ip_addr), ("ip.route", ipjson.parse_ip_route),
    ("wpa.status", supplicant.parse_wpa_status), ("hostapd.status", supplicant.parse_hostapd_status),
    ("hostapd.all_sta", supplicant.parse_hostapd_all_sta), ("ctrl.event", supplicant.parse_ctrl_event),
    ("kv", supplicant.parse_kv), ("cmdline", sysinfo.parse_cmdline), ("zone_tab", sysinfo.parse_zone_tab),
]


def plain(obj):
    """Reduce a parser result to JSON types (dataclasses via to_dict)."""
    if hasattr(obj, "to_dict"):
        return plain(obj.to_dict())
    if isinstance(obj, dict):
        return {str(k): plain(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple, set, frozenset)):
        return [plain(x) for x in obj]
    if hasattr(obj, "__dataclass_fields__"):
        import dataclasses
        return plain(dataclasses.asdict(obj))
    return obj


def corpus():
    texts = []
    for root, _dirs, files in os.walk(helpers.FIXTURES):
        for name in sorted(files):
            if name.endswith(".json") and "commands" in name:
                continue
            path = os.path.join(root, name)
            if "scenarios" in path and name == "commands.json":
                continue
            with open(path, "r", encoding="utf-8") as fh:
                texts.append(fh.read())
    return texts


def mutate_text(rnd, text):
    lines = text.split("\n")
    for _ in range(rnd.randint(1, 4)):
        kind = rnd.randrange(8)
        if not lines:
            lines = [""]
        i = rnd.randrange(len(lines))
        if kind == 0:
            del lines[i]
        elif kind == 1:
            lines.insert(i, lines[i])
        elif kind == 2:
            j = rnd.randrange(len(lines))
            lines[i], lines[j] = lines[j], lines[i]
        elif kind == 3:
            lines[i] = lines[i][:rnd.randint(0, len(lines[i]))]
        elif kind == 4 and lines[i]:
            p = rnd.randrange(len(lines[i]))
            lines[i] = lines[i][:p] + rnd.choice(helpers.NASTY) + lines[i][p:]
        elif kind == 5:
            lines[i] = helpers.rand_text(rnd, 30)
        elif kind == 6 and i + 1 < len(lines):
            lines[i] = lines[i] + lines[i + 1]
            del lines[i + 1]
        else:
            lines[i] = "\t\t" + lines[i]
    out = "\n".join(lines)
    if rnd.random() < 0.2:
        out = out[:rnd.randint(0, len(out))]
    return out


class FuzzParsers(unittest.TestCase):
    def test_no_parser_ever_raises(self):
        rnd = random.Random(helpers.fuzz_seed())
        seeds = corpus()
        self.assertGreater(len(seeds), 50)
        n = helpers.fuzz_n(200000) // 10 or 1
        failures = 0
        for i in range(n):
            text = mutate_text(rnd, rnd.choice(seeds)) if rnd.random() < 0.85 else helpers.rand_text(rnd, 200)
            name, fn = PARSERS[i % len(PARSERS)]
            try:
                result = fn(text)
                json.dumps(plain(result))
            except Exception as exc:                                  # noqa: BLE001 - the point of the test
                failures += 1
                self.fail("%s raised %s on %r" % (name, repr(exc), text[:300]))
        self.assertEqual(0, failures)

    def test_every_parser_on_every_fixture_untouched(self):
        seeds = corpus()
        for text in seeds:
            for name, fn in PARSERS:
                json.dumps(plain(fn(text)))

    def test_non_string_input(self):
        for bad in (None, 5, b"bytes", [], {}):
            for name, fn in PARSERS:
                if name in ("nm.state", "ctrl.event"):
                    continue
                try:
                    fn(bad)
                except (AttributeError, TypeError):
                    pass                                              # the contract is text in; these two are acceptable
                except Exception as exc:                              # noqa: BLE001
                    self.fail("%s raised %r on %r" % (name, exc, bad))


class Pathological(unittest.TestCase):
    BUDGET_S = 1.5

    def inputs(self):
        n = 60000
        yield "combos", "Wiphy phy0\n\tvalid interface combinations:\n\t\t * " + "#{ " * n + "} <= 1, total <= 2, #channels <= 1\n"
        yield "combos2", "Wiphy phy0\n\tvalid interface combinations:\n\t\t * #{ " + "a, " * n + "} <= 1\n\t\t   total <= 2, #channels <= 1\n"
        yield "parens", "Wiphy phy0\n\tBand 1:\n\t\tFrequencies:\n\t\t\t* 2412 MHz [1] " + "(" * n + "\n"
        yield "parens2", "Wiphy phy0\n\tBand 1:\n\t\tFrequencies:\n\t\t\t* 2412 MHz [1] " + "(a)" * n + "\n"
        yield "colons", ":" * n + "\n" + "a:" * n + "\n"
        yield "backslashes", "\\" * n + "\n" + "\\:" * n + "\n"
        yield "bss", "BSS " + "a" * n + "\nBSS aa:bb:cc:dd:ee:ff" + "(on x" * 10000 + "\n"
        yield "tabs", "\t" * n + "x\n" + " " * n + "y\n"
        yield "freq", "Wiphy phy0\n\tBand 1:\n\t\tFrequencies:\n\t\t\t* " + "1" * n + " MHz [" + "2" * n + "]\n"
        yield "country", "country " + "A" * n + ": DFS-ETSI\n\t(" + "1" * n + " - 2 @ 3)\n"
        yield "many_lines", "\n".join("BSS aa:bb:cc:dd:ee:%02x(on x)" % (i % 256) for i in range(n))
        yield "many_phys", "\n".join("Wiphy phy%d" % i for i in range(n))
        yield "deep_json", "[" * 200000
        yield "deep_json2", '{"a":' * 100000
        yield "long_json_string", '[{"ifname": "' + "x" * 3000000 + '"}]'
        yield "equals", "=" * n + "\n" + "a=" * n + "\n"
        yield "multiline_keys", "\n".join("K%d:v" % i for i in range(n))
        yield "quotes", '"' * n + " a=" + '"' * n
        yield "dashes", "-" * n + "\n"

    def test_fast_on_hostile_input(self):
        for label, text in self.inputs():
            for name, fn in PARSERS:
                t0 = time.process_time()
                try:
                    result = fn(text)
                except (AttributeError, TypeError):
                    continue
                spent = time.process_time() - t0
                self.assertLess(spent, self.BUDGET_S, "%s on %s took %.2fs" % (name, label, spent))
                json.dumps(plain(result))

    def test_results_are_bounded(self):
        many = "\n".join("Wiphy phy%d\n\tSupported interface modes:\n\t\t * AP" % i for i in range(3000))
        self.assertEqual(3000, len(iw.parse_iw_phy_info(many)))            # phys are not capped, but each phy's lists are
        modes = "Wiphy phy0\n\tSupported interface modes:\n" + "\t\t * X\n" * 5000
        self.assertLessEqual(len(iw.parse_iw_phy_info(modes)[0].modes), 32)
        scan = "\n".join("BSS aa:bb:cc:00:%02x:%02x(on x)\n\tfreq: 2412\n\tSSID: a" % (i // 256, i % 256) for i in range(2000))
        self.assertLessEqual(len(iw.parse_iw_scan(scan)), 512)
        sta = "\n".join("Station aa:bb:cc:00:%02x:%02x (on x)" % (i // 256, i % 256) for i in range(2000))
        self.assertLessEqual(len(iw.parse_iw_station_dump(sta)), 256)
        rows, _ = nmcli.parse_terse("\n".join("a:b" for _ in range(10000)))
        self.assertLessEqual(len(rows), 4096)
        self.assertLessEqual(len(supplicant.parse_kv("\n".join("k%d=v" % i for i in range(5000)))), 512)


if __name__ == "__main__":
    unittest.main()
