"""Tests for the Wi-Fi join string (ZXing 'WIFI:' format) and its escaping."""
import random
import unittest

import helpers
from ci_setup import validators as v
from ci_setup import wifi_qr as q
from ci_setup.errors import ValidationError


class Payload(unittest.TestCase):
    def test_the_access_point(self):
        self.assertEqual("WIFI:T:WPA;S:Companion-Setup-AB12;P:ABCDEFGHJKMN;;", q.wifi_payload("Companion-Setup-AB12", "ABCDEFGHJKMN"))

    def test_zxing_documentation_example(self):
        # the ZXing wiki: an SSID that is literally "foo;bar\baz" with the quotes part of the name
        ssid = '"foo;bar\\baz"'
        self.assertEqual("WIFI:T:nopass;S:\\\"foo\\;bar\\\\baz\\\";;", q.wifi_payload(ssid, None, "nopass"))
        self.assertEqual({"S": ssid}, q.parse_wifi_payload('WIFI:S:\\"foo\\;bar\\\\baz\\";;'))

    def test_escaping_of_all_five_specials(self):
        self.assertEqual("\\\\", q.escape_field("\\"))
        self.assertEqual("\\;", q.escape_field(";"))
        self.assertEqual("\\,", q.escape_field(","))
        self.assertEqual('\\"', q.escape_field('"'))
        self.assertEqual("\\:", q.escape_field(":"))
        self.assertEqual("a\\\\\\;b", q.escape_field("a\\;b"))               # the backslash is escaped first
        self.assertEqual("plain text", q.escape_field("plain text"))
        self.assertEqual("caf\u00e9 #1 =x", q.escape_field("caf\u00e9 #1 =x"))

    def test_hex_looking_values_are_quoted(self):
        self.assertEqual('WIFI:T:WPA;S:"ABCD";P:"12345678";;', q.wifi_payload("ABCD", "12345678"))
        self.assertEqual('WIFI:T:WPA;S:"deadBEEF00";P:"abcdef12";;', q.wifi_payload("deadBEEF00", "abcdef12"))
        self.assertEqual("WIFI:T:WPA;S:ABCDEFG;P:1234567g;;", q.wifi_payload("ABCDEFG", "1234567g"))
        self.assertEqual("WIFI:T:WPA;S:Net;P:abcd efgh;;", q.wifi_payload("Net", "abcd efgh"))
        r = q.parse_wifi_payload(q.wifi_payload("ABCD", "12345678"))
        self.assertEqual(("ABCD", "12345678"), (r["S"], r["P"]))

    def test_open_network_and_hidden(self):
        self.assertEqual("WIFI:T:nopass;S:Guest;;", q.wifi_payload("Guest", None, "nopass"))
        self.assertEqual("WIFI:T:WPA;S:Net;P:passw0rd!;H:true;;", q.wifi_payload("Net", "passw0rd!", hidden=True))
        self.assertEqual("WIFI:T:WEP;S:Net;P:passw0rd!;;", q.wifi_payload("Net", "passw0rd!", "WEP"))

    def test_invalid_input(self):
        cases = [("", "12345678", "WPA"), ("a\nb", "12345678", "WPA"), ("Net", "short", "WPA"), ("Net", None, "WPA"),
                 ("Net", "12345678", "nopass"), ("Net", "12345678", "SAE"), ("Net", "12345678", "wpa"),
                 ("Net", "pass\nword", "WPA")]
        for ssid, key, sec in cases:
            with self.assertRaises(ValidationError, msg=repr((ssid, key, sec))):
                q.wifi_payload(ssid, key, sec)

    def test_no_control_characters_in_any_payload(self):
        rnd = random.Random(helpers.fuzz_seed())
        made = 0
        for _ in range(helpers.fuzz_n(20000) // 2 or 1):
            ssid, key = helpers.rand_text(rnd, 12), helpers.rand_text(rnd, 12)
            try:
                payload = q.wifi_payload(ssid, key)
            except ValidationError:
                continue
            made += 1
            self.assertFalse(v.has_control_char(payload))
            self.assertTrue(payload.startswith("WIFI:") and payload.endswith(";;"))
        self.assertGreater(made, 0)


class RoundTrip(unittest.TestCase):
    def test_parse_inverts_build(self):
        rnd = random.Random(helpers.fuzz_seed() + 1)
        ok = 0
        for _ in range(helpers.fuzz_n(20000)):
            ssid = helpers.rand_text(rnd, 14)
            key = "".join(rnd.choice(helpers.NASTY[:95] + ["\\", ";", ":", ",", '"']) for _ in range(rnd.randint(8, 20)))
            try:
                v.validate_ssid(ssid)
                v.validate_psk(key)
            except ValidationError:
                continue
            payload = q.wifi_payload(ssid, key, hidden=rnd.random() < 0.3)
            got = q.parse_wifi_payload(payload)
            self.assertIsNotNone(got, payload)
            self.assertEqual(ssid, got["S"], payload)
            self.assertEqual(key, got["P"], payload)
            self.assertEqual("WPA", got["T"])
            ok += 1
        self.assertGreater(ok, 100)

    def test_a_hostile_ssid_cannot_add_or_replace_a_field(self):
        for ssid in ("x;P:evil", "x;;T:nopass;S:y", "x\\;P:evil", 'x";P:"evil', "x:y;z", "a,b;c:d\\e"):
            payload = q.wifi_payload(ssid, "RealKey12345")
            got = q.parse_wifi_payload(payload)
            self.assertEqual(ssid, got["S"], ssid)
            self.assertEqual("RealKey12345", got["P"], ssid)
            self.assertEqual({"T", "S", "P"}, set(got), ssid)

    def test_a_hostile_key_cannot_end_the_list_early(self):
        key = "12345678;;H:true"
        got = q.parse_wifi_payload(q.wifi_payload("Net", key))
        self.assertEqual(key, got["P"])
        self.assertNotIn("H", got)


class Parser(unittest.TestCase):
    def test_malformed(self):
        for bad in ("", "WIFI", "wifi:S:x;;", "WIFI:S:x", "WIFI:S:x;P", "WIFI:S;x;;", "http://x", None, 5,
                    "WIFI:" + "S:x;" * 300 + ";"):
            self.assertIsNone(q.parse_wifi_payload(bad), bad if not isinstance(bad, str) else bad[:30])

    def test_wellformed_variants(self):
        self.assertEqual({}, q.parse_wifi_payload("WIFI:;"))
        self.assertEqual({"S": "x", "T": "WPA"}, q.parse_wifi_payload("WIFI:T:WPA;S:x;;"))
        self.assertEqual({"S": "a"}, q.parse_wifi_payload("WIFI:S:a;;trailing"))
        self.assertEqual({"S": 'a"b'}, q.parse_wifi_payload('WIFI:S:a\\"b;;'))
        self.assertEqual({"S": '"'}, q.parse_wifi_payload('WIFI:S:\\";;'))             # one escaped quote is not a wrapper
        self.assertEqual({"S": "ab"}, q.parse_wifi_payload('WIFI:S:"ab";;'))           # unescaped quotes wrap
        self.assertEqual({"S": "x", "P": "y"}, q.parse_wifi_payload("WIFI:S:x;P:y;"))    # a single closing ";" is accepted


if __name__ == "__main__":
    unittest.main()
