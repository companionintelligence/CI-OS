"""Seeded property/fuzz tests for every validator.

Each validator is run on a stream of random hostile strings (control characters, NUL, ESC, lone surrogates, bidi marks, zero
width characters, non-ASCII digits, shell and config metacharacters, emoji) and on single-character mutations of valid
values. The oracle is an independent re-statement of the rules written in a different style (code point ranges and regular
expressions instead of the validators' own loops), so a regression or a typo in either shows up as a disagreement.

Size: CI_SETUP_FUZZ_N (default 200000 for the SSID/passphrase pair, as in the design prototype); seed: CI_SETUP_FUZZ_SEED.
"""
import random
import re
import time
import unittest

import helpers
from ci_setup import validators as v
from ci_setup.errors import ValidationError

_CTRL = re.compile("[\x00-\x1f\x7f-\x9f\U00002028\U00002029]")
_BIDI = re.compile("[\U0000061c\U0000200e\U0000200f\U0000202a-\U0000202e\U00002066-\U00002069]")
_EDGE = "\U000000ad\U0000180e\U0000200b\U0000200c\U0000200d\U00002060\U0000feff"


def ref_ssid_ok(s):
    if not isinstance(s, str):
        return False
    try:
        raw = s.encode("utf-8")
    except UnicodeEncodeError:
        return False
    if not 1 <= len(raw) <= 32:
        return False
    if _CTRL.search(s) or _BIDI.search(s):
        return False
    if s[0] in _EDGE or s[-1] in _EDGE:
        return False
    if re.fullmatch(r"\s*", s):
        return False
    return True


def ref_psk_ok(p):
    if not isinstance(p, str):
        return False
    if re.fullmatch(r"[0-9a-fA-F]{64}", p):
        return True
    return re.fullmatch(r"[\x20-\x7e]{8,63}", p) is not None


def ref_ifname_ok(n):
    return isinstance(n, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.\-]{0,14}", n) is not None


def ref_ipv4_ok(s):
    m = re.fullmatch(r"(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})", s)
    return bool(m) and all(int(g) <= 255 for g in m.groups())


def accepts(fn, *args):
    try:
        fn(*args)
        return True
    except ValidationError:
        return False


def mutate(rnd, text):
    if not text:
        return rnd.choice(helpers.NASTY)
    i = rnd.randrange(len(text))
    kind = rnd.random()
    if kind < 0.5:
        return text[:i] + rnd.choice(helpers.NASTY) + text[i + 1:]
    if kind < 0.8:
        return text[:i] + rnd.choice(helpers.NASTY) + text[i:]
    return text[:i] + text[i + 1:]


class FuzzSsidPsk(unittest.TestCase):
    def test_ssid_and_psk_200k(self):
        n = helpers.fuzz_n(200000)
        rnd = random.Random(helpers.fuzz_seed())
        valid_ssids = ["HomeNet", "Caf\U000000e9 Bar", "x" * 32, "Companion-Setup-AB12", "\U0001f600" * 8]
        valid_psks = ["12345678", "correct horse battery", "x" * 63, "ab" * 32, "P@ss w0rd!"]
        accepted_ssid = accepted_psk = 0
        t0 = time.process_time()
        for i in range(n):
            if i % 3 == 0:
                s = helpers.rand_text(rnd, 40)
            elif i % 3 == 1:
                s = mutate(rnd, rnd.choice(valid_ssids))
            else:
                s = mutate(rnd, rnd.choice(valid_psks))
            ok = accepts(v.validate_ssid, s)
            if ok != ref_ssid_ok(s):
                self.fail("validate_ssid disagrees with the reference for %r (validator says %s)" % (s, ok))
            if ok:
                accepted_ssid += 1
                raw = s.encode("utf-8")
                self.assertTrue(1 <= len(raw) <= 32)
                self.assertNotIn("\x00", s)
                self.assertNotIn("\n", s)
                self.assertNotIn("\r", s)
            ok = accepts(v.validate_psk, s)
            if ok != ref_psk_ok(s):
                self.fail("validate_psk disagrees with the reference for %r (validator says %s)" % (s, ok))
            if ok:
                accepted_psk += 1
                self.assertTrue(len(s) == 64 or all(0x20 <= ord(c) <= 0x7E for c in s))
        # the generator must actually exercise both outcomes, or the test proves nothing
        if n >= 5000:
            self.assertGreater(accepted_ssid, n // 50)
            self.assertGreater(accepted_psk, n // 200)
            self.assertLess(accepted_ssid, n)
        self.assertLess(time.process_time() - t0, 120)


class FuzzOthers(unittest.TestCase):
    def test_ifname_hostname_country_mac_pin(self):
        n = helpers.fuzz_n(200000) // 4 or 1
        rnd = random.Random(helpers.fuzz_seed() + 1)
        seeds = ["wlan0", "wlp192s0", "ap0", "companion-os", "aa:bb:cc:00:11:22", "012345", "de"]
        for _ in range(n):
            s = mutate(rnd, rnd.choice(seeds)) if rnd.random() < 0.7 else helpers.rand_text(rnd, 20)
            self.assertEqual(ref_ifname_ok(s), accepts(v.validate_ifname, s), repr(s))
            if accepts(v.validate_hostname, s):
                out = v.validate_hostname(s)
                self.assertTrue(re.fullmatch(r"[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?", out) is not None, repr(s))
                self.assertFalse(out.isdigit())
            if accepts(v.validate_country, s):
                self.assertTrue(re.fullmatch(r"[A-Z]{2}", v.validate_country(s)) is not None)
            if accepts(v.validate_mac, s):
                self.assertTrue(re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", v.validate_mac(s)) is not None)
            self.assertEqual(re.fullmatch(r"[0-9]{6}", s) is not None, accepts(v.validate_pin, s), repr(s))

    def test_ipv4_and_cidr(self):
        n = helpers.fuzz_n(200000) // 4 or 1
        rnd = random.Random(helpers.fuzz_seed() + 2)
        seeds = ["192.168.99.1", "10.0.0.255", "0.0.0.0", "255.255.255.255", "172.16.5.4"]
        for _ in range(n):
            if rnd.random() < 0.5:
                s = mutate(rnd, rnd.choice(seeds))
            else:
                s = ".".join(str(rnd.choice([0, 1, 9, 10, 99, 100, 255, 256, 999, -1, "01", "007", "x", ""])) for _ in range(rnd.choice([3, 4, 4, 4, 5])))
            self.assertEqual(ref_ipv4_ok(s), accepts(v.parse_ipv4, s), repr(s))
            if ref_ipv4_ok(s):
                self.assertEqual(s, v.format_ipv4(v.parse_ipv4(s)))
        # CIDR: aligned networks only
        for _ in range(max(1, n // 4)):
            addr = rnd.getrandbits(32)
            prefix = rnd.randint(0, 32)
            text = "%s/%d" % (v.format_ipv4(addr), prefix)
            mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF
            self.assertEqual(addr & ~mask & 0xFFFFFFFF == 0, accepts(v.parse_cidr, text), text)
            net = v.parse_cidr(text, strict=False)
            self.assertEqual(addr & mask, net.network)
            self.assertTrue(net.contains(addr))

    def test_strict_json(self):
        n = helpers.fuzz_n(200000) // 20 or 1
        rnd = random.Random(helpers.fuzz_seed() + 3)
        pieces = ['{', '}', '[', ']', '"', ':', ',', 'null', 'true', '1', '-0', '1e999', 'NaN', '"a"', '\\u0000', '\\ud800',
                  ' ', '\n', '\U0000feff', '{"a":1,"a":2}', '"\\']
        for _ in range(n):
            text = "".join(rnd.choice(pieces) for _ in range(rnd.randint(0, 12)))
            try:
                out = v.loads_strict(text, 4096)
            except ValidationError as e:
                self.assertIn(e.code, ("json", "length", "encoding", "type"))
            else:
                # whatever was accepted must be plain JSON data
                self.assertIsInstance(out, (dict, list, str, int, float, bool, type(None)))


class FuzzSmallValidators(unittest.TestCase):
    def test_ids_ports_channels_security(self):
        n = helpers.fuzz_n(200000) // 4 or 1
        rnd = random.Random(helpers.fuzz_seed() + 6)
        seeds = ["0123456789abcdef", "phy0", "phy12", "open", "sae-only", "wpa2"]
        for _ in range(n):
            s = mutate(rnd, rnd.choice(seeds)) if rnd.random() < 0.7 else helpers.rand_text(rnd, 20)
            self.assertEqual(re.fullmatch(r"[0-9a-f]{8,64}", s) is not None, accepts(v.validate_job_id, s), repr(s))
            self.assertEqual(re.fullmatch(r"phy[0-9]{1,4}", s) is not None, accepts(v.validate_phy_name, s), repr(s))
            self.assertEqual(s in v.SECURITY_TYPES, accepts(v.validate_security, s), repr(s))
            value = rnd.choice([rnd.randint(-5, 70000), True, False, None, "80", 80.0, s, rnd.randint(0, 300)])
            self.assertEqual(type(value) is int and 1 <= value <= 65535, accepts(v.validate_port, value), repr(value))
            band = rnd.choice(["2.4", "5", "6", "60", "", None])
            ref = {"2.4": (1, 14), "5": (32, 177), "6": (1, 233)}.get(band)
            expect = type(value) is int and ref is not None and ref[0] <= value <= ref[1]
            self.assertEqual(expect, accepts(v.validate_channel, value, band), (value, band))


class FuzzRequestValidators(unittest.TestCase):
    def test_join_request_never_returns_an_unsafe_value(self):
        n = helpers.fuzz_n(200000) // 10 or 1
        rnd = random.Random(helpers.fuzz_seed() + 4)
        for _ in range(n):
            doc = {}
            for key in ("ssid", "psk", "hidden", "security", rnd.choice(["extra", "ssid2", "PSK"])):
                if rnd.random() < 0.7:
                    doc[key] = rnd.choice([
                        helpers.rand_text(rnd, 12), "HomeNet", "12345678", True, False, None, 5, "wpa2", "open",
                        "sae-only", "wpa3", "ab" * 32, [], {}])
            try:
                out = v.validate_wifi_join_request(doc)
            except ValidationError:
                continue
            self.assertTrue(ref_ssid_ok(out["ssid"]))
            self.assertIn(out["security"], v.JOINABLE_SECURITY)
            self.assertIs(type(out["hidden"]), bool)
            if out["security"] == "open":
                self.assertIsNone(out["psk"])
            else:
                self.assertTrue(ref_psk_ok(out["psk"]))
            self.assertEqual({"ssid", "psk", "hidden", "security"}, set(out))
            self.assertLessEqual(set(doc), {"ssid", "psk", "hidden", "security"})

    def test_provisioning_never_returns_an_unsafe_value(self):
        n = helpers.fuzz_n(200000) // 20 or 1
        rnd = random.Random(helpers.fuzz_seed() + 5)
        for _ in range(n):
            entry = {}
            for key in ("ssid", "psk", "psk_hex", "hidden", "security"):
                if rnd.random() < 0.6:
                    entry[key] = rnd.choice([helpers.rand_text(rnd, 10), "Home", "12345678", "ab" * 32, True, "wpa2",
                                             "open", "sae-only", None])
            doc = {"version": 1, "wifi": [entry]}
            if rnd.random() < 0.3:
                doc["country"] = rnd.choice(["de", "DEU", helpers.rand_text(rnd, 3)])
            if rnd.random() < 0.3:
                doc["hostname"] = rnd.choice(["companion", helpers.rand_text(rnd, 8)])
            try:
                out = v.validate_provisioning_doc(doc)
            except ValidationError:
                continue
            for w in out["wifi"]:
                self.assertTrue(ref_ssid_ok(w["ssid"]))
                self.assertTrue(w["psk"] is None or ref_psk_ok(w["psk"]))
                self.assertTrue(w["psk_hex"] is None or re.fullmatch(r"[0-9a-f]{64}", w["psk_hex"]))
                self.assertFalse(w["psk"] is not None and w["psk_hex"] is not None)
            if out["country"] is not None:
                self.assertTrue(re.fullmatch(r"[A-Z]{2}", out["country"]))


if __name__ == "__main__":
    unittest.main()
