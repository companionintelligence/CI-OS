"""Unit tests for ci_setup.validators: boundaries, known-bad inputs, and the rule that errors never echo the input."""
import random
import unittest

import helpers  # noqa: F401  (makes ci_setup importable)
from ci_setup import validators as v
from ci_setup.errors import ValidationError


def rejects(test, fn, *args, **kw):
    with test.assertRaises(ValidationError) as cm:
        fn(*args, **kw)
    return cm.exception


class SsidTests(unittest.TestCase):
    def test_accepts_ordinary_names(self):
        for s in ("a", "HomeNet", "Home Net", "Caf\U000000e9", "\U00004e2d\U00006587", "x" * 32, "Companion-Setup-AB12", "a b", " lead",
                  "trail ", "with#hash", "eq=sign", "quote\"s", "semi;colon", "\U0001f468\U0000200d\U0001f469"):
            self.assertEqual(s, v.validate_ssid(s))

    def test_length_is_counted_in_bytes(self):
        self.assertEqual(32, len(v.validate_ssid("\U0001f600" * 8).encode()))
        e = rejects(self, v.validate_ssid, "\U0001f600" * 9)  # 9 characters, 36 bytes: len() alone would pass it
        self.assertEqual("length", e.code)
        self.assertEqual("length", rejects(self, v.validate_ssid, "x" * 33).code)
        # 16 two-byte characters = 32 bytes fits, 17 do not
        self.assertEqual(32, len(v.validate_ssid("\U000000e9" * 16).encode()))
        rejects(self, v.validate_ssid, "\U000000e9" * 17)

    def test_empty_and_blank(self):
        self.assertEqual("empty", rejects(self, v.validate_ssid, "").code)
        for blank in (" ", "   ", "\U000000a0", "\U00003000", "\U00002003"):
            self.assertEqual("blank", rejects(self, v.validate_ssid, blank).code)

    def test_control_characters(self):
        for bad in ("a\nb", "a\rb", "a\x00b", "\x00", "a\tb", "a\x1bb", "a\x7fb", "a\x85b", "a\x9fb", "a\U00002028b", "a\U00002029b"):
            self.assertEqual("control_char", rejects(self, v.validate_ssid, bad).code, repr(bad))

    def test_trailing_newline_is_not_forgiven(self):
        # the classic `$` bug: "name\n" passes a regex that ends in $
        rejects(self, v.validate_ssid, "HomeNet\n")

    def test_bidi_and_invisible(self):
        for bad in ("\U0000202eevil", "ab\U0000202ec", "\U00002066x", "a\U0000200eb", "a\U0000061cb"):
            self.assertEqual("bidi_char", rejects(self, v.validate_ssid, bad).code, repr(bad))
        for bad in ("\U0000200bx", "x\U0000200b", "\U0000feffx", "x\U000000ad", "\U00002060x", "x\U0000200d"):
            self.assertEqual("invisible_edge", rejects(self, v.validate_ssid, bad).code, repr(bad))
        v.validate_ssid("a\U0000200bb")  # inside a name it is allowed

    def test_lone_surrogate_and_type(self):
        self.assertEqual("encoding", rejects(self, v.validate_ssid, "a\ud800").code)
        for bad in (None, 5, b"abc", ["a"], True):
            self.assertEqual("type", rejects(self, v.validate_ssid, bad).code)

    def test_huge_input_is_cheap(self):
        self.assertEqual("length", rejects(self, v.validate_ssid, "x" * 5000000).code)

    def test_hints(self):
        self.assertIn("leading_or_trailing_space", v.ssid_hints("a "))
        self.assertIn("non_ascii", v.ssid_hints("caf\U000000e9"))
        self.assertIn("max_length", v.ssid_hints("x" * 32))
        self.assertEqual([], v.ssid_hints("fine"))


class PskTests(unittest.TestCase):
    def test_boundaries(self):
        rejects(self, v.validate_psk, "x" * 7)
        self.assertEqual("x" * 8, v.validate_psk("x" * 8))
        self.assertEqual("x" * 63, v.validate_psk("x" * 63))
        e = rejects(self, v.validate_psk, "x" * 64)  # 64 characters must all be hex
        self.assertEqual("format", e.code)
        self.assertEqual("ab" * 32, v.validate_psk("ab" * 32))
        self.assertEqual("AB" * 32, v.validate_psk("AB" * 32))
        rejects(self, v.validate_psk, "x" * 65)

    def test_printable_ascii_only(self):
        self.assertEqual(" !\"#$%&'()*+,-./0:;<=>?@[\\]^_`{|}~ab", v.validate_psk(" !\"#$%&'()*+,-./0:;<=>?@[\\]^_`{|}~ab"))
        for bad in ("pass\x00word", "pass\nword", "pass\tword", "passw\U000000f6rd", "pass\x7fword", "\U00000663" * 8, "caf\U000000e9caf\U000000e9"):
            rejects(self, v.validate_psk, bad)

    def test_trailing_newline_is_not_forgiven(self):
        rejects(self, v.validate_psk, "1234567\n")
        rejects(self, v.validate_psk, "ab" * 31 + "a\n")  # 64 characters, the last one a newline

    def test_kind(self):
        self.assertEqual("passphrase", v.psk_kind("12345678"))
        self.assertEqual("pmk_hex", v.psk_kind("0" * 64))

    def test_type(self):
        for bad in (None, 12345678, b"12345678"):
            self.assertEqual("type", rejects(self, v.validate_psk, bad).code)


class MiscTextTests(unittest.TestCase):
    def test_hostname(self):
        for ok in ("a", "companion-os", "Companion-OS", "a1", "1a", "x" * 63):
            self.assertEqual(ok.lower(), v.validate_hostname(ok))
        for bad in ("", "-a", "a-", "a_b", "a b", "a.b", "x" * 64, "12345", "\U0000212a", "caf\U000000e9", "a\n", "a\x00"):
            rejects(self, v.validate_hostname, bad)
        self.assertEqual("a.example.org", v.validate_hostname("A.Example.Org", allow_fqdn=True))
        rejects(self, v.validate_hostname, "a..b", allow_fqdn=True)
        rejects(self, v.validate_hostname, "a.b.", allow_fqdn=True)
        rejects(self, v.validate_hostname, "1.2.3.4", allow_fqdn=True)
        rejects(self, v.validate_hostname, ("x" * 63 + ".") * 4, allow_fqdn=True)

    def test_country(self):
        self.assertEqual("DE", v.validate_country("de"))
        self.assertEqual("US", v.validate_country("US"))
        for bad in ("", "D", "DEU", "00", "9A", "D\U000000c9", "\U00000394\U00000395", "D\n", " D", None, 5):
            rejects(self, v.validate_country, bad)

    def test_mac(self):
        self.assertEqual("aa:bb:cc:00:11:22", v.validate_mac("AA:BB:CC:00:11:22"))
        self.assertEqual("aa:bb:cc:00:11:22", v.validate_mac("aa-bb-cc-00-11-22"))
        for bad in ("aa:bb:cc:00:11", "aa:bb:cc:00:11:22:33", "aa:bb:cc:00:11:2", "aa:bb:cc:00:11:zz", "aabbcc001122",
                    "aa:bb-cc:00:11:22", "01:00:5e:00:00:01", "ff:ff:ff:ff:ff:ff", "00:00:00:00:00:00", "aa:bb:cc:00:11:22\n",
                    "\U00000661a:bb:cc:00:11:22"):
            rejects(self, v.validate_mac, bad)
        self.assertEqual("01:00:5e:00:00:01", v.validate_mac("01:00:5e:00:00:01", unicast=False))

    def test_pin(self):
        self.assertEqual("012345", v.validate_pin("012345"))
        for bad in ("12345", "1234567", "12345a", "12345\n", "\U00000661\U00000662\U00000663\U00000664\U00000665\U00000666", "", None, 123456):
            rejects(self, v.validate_pin, bad)

    def test_job_id(self):
        self.assertEqual("0123456789abcdef", v.validate_job_id("0123456789abcdef"))
        for bad in ("0123456", "ABCDEF0123456789", "g" * 16, "0" * 65, "0123456789abcde\n"):
            rejects(self, v.validate_job_id, bad)

    def test_port_and_channel(self):
        self.assertEqual(8080, v.validate_port(8080))
        for bad in (0, 65536, -1, True, False, "80", 80.0, None):
            rejects(self, v.validate_port, bad)
        rejects(self, v.validate_port, 80, minimum=1024)
        self.assertEqual(6, v.validate_channel(6, "2.4"))
        self.assertEqual(36, v.validate_channel(36, "5"))
        for args in ((0, "2.4"), (15, "2.4"), (36, "2.4"), (6, "5"), (True, "2.4"), (6, "60"), ("6", "2.4")):
            rejects(self, v.validate_channel, *args)

    def test_ifname(self):
        for ok in ("wlan0", "wlp192s0", "wlx00c0caaabbcc", "ap0", "a", "a" * 15, "wlan0.1", "w-l_an"):
            self.assertEqual(ok, v.validate_ifname(ok))
        self.assertEqual("length", rejects(self, v.validate_ifname, "a" * 16).code)
        for bad in ("", ".", "..", "-wlan", "_x", "wl an", "wl/an", "wl:an", 'wl"an', "wl;an", "wl\nan", "wl\x00an",
                    "w\U000000e9", "wlan0\n", "a" * 15 + "\U000000e9"):
            rejects(self, v.validate_ifname, bad)
        self.assertEqual("phy0", v.validate_phy_name("phy0"))
        for bad in ("phy", "phy#0", "phy-1", "phy12345", "wlan0", "phy0\n", "phy\U00000663"):
            rejects(self, v.validate_phy_name, bad)


class Ipv4Tests(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(0xC0A86301, v.parse_ipv4("192.168.99.1"))
        self.assertEqual("10.0.0.1", v.validate_ipv4("10.0.0.1"))
        self.assertEqual("192.168.99.1", v.format_ipv4(0xC0A86301))
        for bad in ("", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.-4", "01.2.3.4", "1.2.3.04", "1.2.3.4 ", " 1.2.3.4",
                    "1.2.3.4\n", "1..3.4", "a.b.c.d", "1.2.3.\U00000664", "0x1.2.3.4", "+1.2.3.4", "1.2.3.4/24", "1,2,3,4",
                    "\U0000ff11.2.3.4"):
            rejects(self, v.parse_ipv4, bad)
        self.assertEqual(0, v.parse_ipv4("0.0.0.0"))
        self.assertEqual(0xFFFFFFFF, v.parse_ipv4("255.255.255.255"))

    def test_cidr_and_subnet(self):
        net = v.validate_ipv4_subnet("192.168.99.0/24")
        self.assertEqual(("192.168.99.0/24", "255.255.255.0"), (net.cidr(), net.netmask_str()))
        self.assertEqual(0xC0A86301, net.address(1))
        self.assertTrue(net.contains(v.parse_ipv4("192.168.99.200")))
        self.assertFalse(net.contains(v.parse_ipv4("192.168.100.1")))
        for bad in ("192.168.99.1/24", "192.168.99.0/33", "192.168.99.0/31", "192.168.99.0/32", "192.168.99.0/7",
                    "8.8.8.0/24", "172.32.0.0/16", "100.64.0.0/24", "192.168.99.0/024", "192.168.99.0/", "192.168.99.0",
                    "192.168.99.0/24/24", "192.168.99.0/2 4", "10.0.0.0/8\n"):
            rejects(self, v.validate_ipv4_subnet, bad)
        v.validate_ipv4_subnet("172.16.0.0/12")
        v.validate_ipv4_subnet("10.0.0.0/8")
        v.validate_ipv4_subnet("8.8.8.0/24", private_only=False)
        # a block that only starts inside private space
        rejects(self, v.validate_ipv4_subnet, "172.0.0.0/8")

    def test_overlap(self):
        a = v.parse_cidr("192.168.0.0/16")
        b = v.parse_cidr("192.168.99.0/24")
        c = v.parse_cidr("192.169.0.0/24")
        self.assertTrue(a.overlaps(b) and b.overlaps(a))
        self.assertFalse(a.overlaps(c) or c.overlaps(a))
        self.assertTrue(b.overlaps(b))

    def test_rfc1918(self):
        for ok in ("10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.1"):
            self.assertTrue(v.is_rfc1918(v.parse_ipv4(ok)), ok)
        for bad in ("9.255.255.255", "11.0.0.0", "172.15.255.255", "172.32.0.0", "192.167.255.255", "192.169.0.0",
                    "100.64.0.1", "169.254.1.1", "127.0.0.1"):
            self.assertFalse(v.is_rfc1918(v.parse_ipv4(bad)), bad)


class JsonTests(unittest.TestCase):
    def test_accepts_normal(self):
        self.assertEqual({"a": [1, 2]}, v.loads_strict('{"a": [1, 2]}'))
        self.assertEqual({"a": 1}, v.loads_strict(b'{"a": 1}'))

    def test_rejects(self):
        cases = ['{"a": 1, "a": 2}', "[NaN]", "[Infinity]", "[-Infinity]", "{", "", "nul", "\U0000feff{}", '{"a": 1}}',
                 "[" * 100000, '{"a": ' + "9" * 5000 + "}"]
        for text in cases:
            self.assertEqual("json" if text != "" else "json", rejects(self, v.loads_strict, text, 200000).code, text[:20])
        self.assertEqual("encoding", rejects(self, v.loads_strict, b"\xff\xfe{}").code)
        self.assertEqual("length", rejects(self, v.loads_strict, "x" * 100, 50).code)
        self.assertEqual("length", rejects(self, v.loads_strict, b"x" * 100, 50).code)
        self.assertEqual("type", rejects(self, v.loads_strict, 5).code)

    def test_error_text_is_constant(self):
        e = rejects(self, v.loads_strict, '{"secret-key-value-9999": ')
        self.assertNotIn("9999", str(e))


class JoinRequestTests(unittest.TestCase):
    def test_valid(self):
        r = v.validate_wifi_join_request({"ssid": "Home", "psk": "12345678"})
        self.assertEqual({"ssid": "Home", "psk": "12345678", "hidden": False, "security": "wpa2"}, r)
        r = v.validate_wifi_join_request({"ssid": "Guest", "security": "open"})
        self.assertEqual((None, "open"), (r["psk"], r["security"]))
        r = v.validate_wifi_join_request({"ssid": "Hid", "psk": "12345678", "hidden": True, "security": "wpa3"})
        self.assertTrue(r["hidden"])
        r = v.validate_wifi_join_request({"ssid": "Sae", "psk": "12345678", "security": "sae-only"})
        self.assertEqual("sae-only", r["security"])
        r = v.validate_wifi_join_request({"ssid": "Raw", "psk": "ab" * 32, "security": "wpa2"})
        self.assertEqual("ab" * 32, r["psk"])
        r = v.validate_wifi_join_request({"ssid": "N", "psk": None})
        self.assertEqual("open", r["security"])

    def test_invalid(self):
        bad = [
            None, [], "x", {}, {"psk": "12345678"}, {"ssid": ""}, {"ssid": "a\nb", "psk": "12345678"},
            {"ssid": "a", "psk": "short"}, {"ssid": "a", "psk": "12345678", "extra": 1},
            {"ssid": "a", "psk": "12345678", "hidden": "yes"}, {"ssid": "a", "psk": "12345678", "hidden": 1},
            {"ssid": "a", "security": "wpa2"},                       # password required
            {"ssid": "a", "psk": "12345678", "security": "open"},    # open takes none
            {"ssid": "a", "psk": "12345678", "security": "wep"},
            {"ssid": "a", "psk": "12345678", "security": "enterprise"},
            {"ssid": "a", "psk": "12345678", "security": "owe"},
            {"ssid": "a", "psk": "12345678", "security": "bogus"},
            {"ssid": "a", "psk": "ab" * 32, "security": "sae-only"},  # SAE needs the passphrase
            {"ssid": "a", "psk": 12345678},
        ]
        for doc in bad:
            rejects(self, v.validate_wifi_join_request, doc)

    def test_unknown_key_name_not_echoed(self):
        e = rejects(self, v.validate_wifi_join_request, {"ssid": "a", "psk": "12345678", "tok-9876-en": 1})
        self.assertNotIn("9876", str(e))

    def test_validation_order_does_not_leak_through_message(self):
        e = rejects(self, v.validate_wifi_join_request, {"ssid": "a", "psk": "pass word 7"[:7]})
        self.assertNotIn("pass wo", str(e))


class ProvisioningTests(unittest.TestCase):
    GOOD = {"version": 1,
            "wifi": [{"ssid": "HomeNet", "psk_hex": "ab" * 32, "hidden": False, "security": "wpa2"}],
            "country": "de", "hostname": "Companion-OS"}

    def test_valid(self):
        r = v.validate_provisioning_doc(self.GOOD)
        self.assertEqual(("DE", "companion-os", []), (r["country"], r["hostname"], r["warnings"]))
        self.assertEqual("ab" * 32, r["wifi"][0]["psk_hex"])
        self.assertIsNone(r["wifi"][0]["psk"])

    def test_passphrase_warns_and_hex_in_psk_is_moved(self):
        r = v.validate_provisioning_doc({"version": 1, "wifi": [
            {"ssid": "Sae", "psk": "correct horse", "security": "sae-only"},
            {"ssid": "Raw", "psk": "AB" * 32}]})
        self.assertEqual(1, len(r["warnings"]))
        self.assertEqual("correct horse", r["wifi"][0]["psk"])
        self.assertEqual("ab" * 32, r["wifi"][1]["psk_hex"])
        self.assertIsNone(r["wifi"][1]["psk"])

    def test_open_network(self):
        r = v.validate_provisioning_doc({"version": 1, "wifi": [{"ssid": "Open"}]})
        self.assertEqual("open", r["wifi"][0]["security"])

    def test_minimal(self):
        r = v.validate_provisioning_doc({"version": 1})
        self.assertEqual([], r["wifi"])
        self.assertIsNone(r["country"])

    def test_invalid(self):
        bad = [
            None, [], {}, {"version": 2}, {"version": "1"}, {"version": True}, {"version": 1.0 + 0.5},
            {"version": 1, "extra": 1}, {"version": 1, "wifi": {}}, {"version": 1, "wifi": ["x"]},
            {"version": 1, "wifi": [{"ssid": "a", "psk_hex": "ab" * 32, "psk": "12345678"}]},
            {"version": 1, "wifi": [{"ssid": "a", "psk_hex": "zz" * 32}]},
            {"version": 1, "wifi": [{"ssid": "a", "psk_hex": "ab" * 31}]},
            {"version": 1, "wifi": [{"ssid": "a", "psk_hex": "ab" * 32, "security": "sae-only"}]},
            {"version": 1, "wifi": [{"ssid": "a", "psk": "ab" * 32, "security": "sae-only"}]},
            {"version": 1, "wifi": [{"ssid": "a", "security": "wpa2"}]},
            {"version": 1, "wifi": [{"ssid": "a", "psk": "12345678", "security": "open"}]},
            {"version": 1, "wifi": [{"ssid": "a", "psk": "12345678", "security": "enterprise"}]},
            {"version": 1, "wifi": [{"psk": "12345678"}]},
            {"version": 1, "wifi": [{"ssid": "a\n", "psk": "12345678"}]},
            {"version": 1, "wifi": [{"ssid": "a", "psk": "12345678", "unknown": 1}]},
            {"version": 1, "wifi": [{"ssid": "a", "psk": "12345678", "hidden": "no"}]},
            {"version": 1, "wifi": [{"ssid": "n%d" % i, "psk": "12345678"} for i in range(9)]},
            {"version": 1, "country": "DEU"}, {"version": 1, "hostname": "bad host"},
        ]
        for doc in bad:
            rejects(self, v.validate_provisioning_doc, doc)


class NoEchoTests(unittest.TestCase):
    """An exception text ends up in logs and HTTP responses; the input may be a passphrase."""

    def test_errors_never_contain_the_input(self):
        rnd = random.Random(7)
        checks = [(v.validate_ssid, "ssid"), (v.validate_psk, "psk"), (v.validate_ifname, "ifname"),
                  (v.validate_hostname, "hostname"), (v.validate_pin, "pin"), (v.validate_mac, "mac"),
                  (v.parse_ipv4, "ip"), (v.parse_cidr, "cidr"), (v.validate_country, "country")]
        for _ in range(3000):
            secret = "".join(rnd.choice("QWXZKJqwxzkj0123456789!@#%^&*") for _ in range(rnd.randint(6, 14)))
            secret = "Zq" + secret + "9Kx"
            for fn, _name in checks:
                try:
                    fn(secret)
                except ValidationError as e:
                    self.assertNotIn(secret, str(e))
                    self.assertNotIn(secret, repr(e))
                    self.assertNotIn(secret, str(e.to_dict()))
                    for tail in (secret[2:8], secret[-6:]):
                        self.assertNotIn(tail, str(e))


if __name__ == "__main__":
    unittest.main()
