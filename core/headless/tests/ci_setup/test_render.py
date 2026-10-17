"""Tests for the renderers (hostapd, dnsmasq, nftables), the template engine, the subnet picker and the private-file writer.

Golden files pin the exact text. The nftables ruleset is also parsed here for the properties that matter (what is accepted
from the AP interface, the hook priority); tests/ci_setup/nft_check.sh loads it into a real nftables in a container when
Docker is available (opt-in).
"""
import os
import re
import stat
import tempfile
import unittest
from unittest import mock

import helpers
from ci_setup import apcfg, fw, privfile, templating
from ci_setup.errors import ValidationError
from ci_setup.templating import TemplateError

KEY = "ABCDEFGHJKMN"


def hostapd(**kw):
    args = dict(iface="wlan0", ssid="Companion-Setup-AB12", passphrase=KEY, channel=6, band="2.4", country="DE")
    args.update(kw)
    return apcfg.render_hostapd(apcfg.ApParams(**args))


def directives(text):
    out = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            k, _, val = line.partition("=")
            out.setdefault(k, []).append(val)
    return out


class Hostapd(unittest.TestCase):
    def test_golden_known_country(self):
        helpers.golden_check(self, "hostapd_de_2g.conf", hostapd())

    def test_golden_unknown_country(self):
        helpers.golden_check(self, "hostapd_unknown_country.conf", hostapd(country=None, ssid="Caf\U000000e9 #1 ", passphrase="12345678"))

    def test_golden_5ghz(self):
        helpers.golden_check(self, "hostapd_us_5g.conf", hostapd(country="US", band="5", channel=36, passphrase="ab" * 32))

    def test_security_settings(self):
        d = directives(hostapd())
        self.assertEqual(["2"], d["wpa"])
        self.assertEqual(["WPA-PSK"], d["wpa_key_mgmt"])
        self.assertEqual(["CCMP"], d["rsn_pairwise"])
        self.assertNotIn("wpa_pairwise", d)                       # no TKIP, which the old generated file listed
        self.assertEqual(["1"], d["ap_isolate"])
        self.assertEqual(["4"], d["max_num_sta"])
        self.assertEqual(["0"], d["macaddr_acl"])
        self.assertEqual(["0"], d["ignore_broadcast_ssid"])
        self.assertEqual(["1"], d["auth_algs"])
        self.assertEqual(["0"], d["ctrl_interface_group"])
        self.assertNotIn("wps_state", d)
        self.assertEqual([KEY], d["wpa_passphrase"])

    def test_ssid_is_written_as_hex_of_its_bytes(self):
        for ssid in ("Companion-Setup-AB12", "Caf\U000000e9 #1 ", " lead", "trail ", "a=b", 'q"uote', "semi;colon", "\U0001f600" * 8,
                     "x" * 32, "a#b", "back\\slash", "ssid=other", "@SSID_HEX@", "@PSK_LINE@"):
            text = hostapd(ssid=ssid)
            d = directives(text)
            self.assertEqual([ssid.encode("utf-8").hex()], d["ssid2"], ssid)
            self.assertNotIn("ssid", d)                             # no plain ssid= line that could be misparsed
            self.assertEqual(1, len(d["wpa_passphrase"]))
            self.assertEqual(1, len(d["ssid2"]))

    def test_country_lines(self):
        d = directives(hostapd(country="DE"))
        self.assertEqual((["DE"], ["1"]), (d["country_code"], d["ieee80211d"]))
        d = directives(hostapd(country=None))
        self.assertNotIn("country_code", d)
        self.assertNotIn("ieee80211d", d)
        self.assertIn("# country_code omitted", hostapd(country=None))

    def test_raw_key_uses_wpa_psk(self):
        d = directives(hostapd(passphrase="AB" * 32))
        self.assertEqual(["ab" * 32], d["wpa_psk"])
        self.assertNotIn("wpa_passphrase", d)

    def test_band_and_channel(self):
        d = directives(hostapd(band="5", channel=149, country="US"))
        self.assertEqual((["a"], ["149"]), (d["hw_mode"], d["channel"]))
        d = directives(hostapd(channel=11))
        self.assertEqual((["g"], ["11"]), (d["hw_mode"], d["channel"]))

    def test_only_directives_and_comments(self):
        templating.lint_config(hostapd())
        self.assertTrue(hostapd().endswith("\n"))

    def test_invalid_parameters(self):
        bad = [dict(iface="wl an"), dict(iface='wl"an'), dict(iface=""), dict(ssid=""), dict(ssid="a\nb"), dict(ssid="x" * 33),
               dict(passphrase="short"), dict(passphrase="pass\nword1"), dict(passphrase="x" * 64), dict(channel=0),
               dict(channel=14), dict(channel=36), dict(band="5", channel=6), dict(band="6"), dict(country="de"),
               dict(country="DEU"), dict(country="00"), dict(max_sta=0), dict(max_sta=9), dict(max_sta=True),
               dict(ctrl_dir="/etc/hostapd"), dict(ctrl_dir="/run/../etc"), dict(ctrl_dir="/run/a b"), dict(ctrl_dir="run/x")]
        for kw in bad:
            with self.assertRaises(ValidationError, msg=str(kw)):
                hostapd(**kw)

    def test_a_newline_cannot_reach_the_file_by_any_parameter(self):
        for field in ("iface", "ssid", "passphrase", "ctrl_dir"):
            with self.assertRaises(ValidationError):
                hostapd(**{field: "ok\nwpa=1"})


class Dnsmasq(unittest.TestCase):
    def test_golden(self):
        helpers.golden_check(self, "dnsmasq_default.conf", apcfg.render_dnsmasq(apcfg.DhcpParams("wlan0")))

    def test_golden_other_subnet(self):
        helpers.golden_check(self, "dnsmasq_10_77_3.conf", apcfg.render_dnsmasq(apcfg.DhcpParams("ap0", "10.77.3.0/24", "/run/ci-setup", "30m")))

    def test_properties(self):
        text = apcfg.render_dnsmasq(apcfg.DhcpParams("wlan0"))
        d = directives(text)
        for key in ("no-resolv", "no-hosts", "bind-interfaces"):
            self.assertIn(key, text.split())
        self.assertNotIn("log-queries", text)                      # privacy: no per-phone DNS log
        self.assertNotIn("log-facility", text)
        self.assertNotIn("conf-dir", d)
        self.assertNotIn("conf-file", d)
        self.assertNotIn("server=", text)                           # nothing is forwarded upstream
        self.assertEqual(["192.168.99.1"], d["listen-address"])
        self.assertEqual(["/#/192.168.99.1"], d["address"])
        self.assertEqual(["192.168.99.10,192.168.99.250,255.255.255.0,2h"], d["dhcp-range"])
        self.assertEqual({"option:router,192.168.99.1", "option:dns-server,192.168.99.1"}, set(d["dhcp-option"]))
        self.assertEqual(["/run/ci-setup/dnsmasq.leases"], d["dhcp-leasefile"])
        templating.lint_config(text, allow_bare=True)

    def test_invalid(self):
        for kw in (dict(iface="a b"), dict(subnet="192.168.99.0/16"), dict(subnet="192.168.99.1/24"), dict(subnet="8.8.8.0/24"), dict(subnet="x"),
                   dict(lease="2"), dict(lease="0h"), dict(lease="2 h"), dict(run_dir="/tmp/x"), dict(run_dir="/run/x\n")):
            args = dict(iface="wlan0")
            args.update(kw)
            with self.assertRaises(ValidationError, msg=str(kw)):
                apcfg.DhcpParams(**args)

    def test_addresses(self):
        a = apcfg.ap_addresses(apcfg.parse_cidr("10.77.5.0/24"))
        self.assertEqual({"ap_ip": "10.77.5.1", "range_start": "10.77.5.10", "range_end": "10.77.5.250", "netmask": "255.255.255.0"}, a)


class SubnetPicker(unittest.TestCase):
    def test_default_when_free(self):
        self.assertEqual("192.168.99.0/24", apcfg.pick_ap_subnet([]).cidr())
        self.assertEqual("192.168.99.0/24", apcfg.pick_ap_subnet(["192.168.1.0/24", "10.0.0.0/8"]).cidr())

    def test_collisions(self):
        self.assertEqual("10.77.0.0/24", apcfg.pick_ap_subnet(["192.168.99.0/24"]).cidr())
        self.assertEqual("10.77.0.0/24", apcfg.pick_ap_subnet(["192.168.0.0/16"]).cidr())      # a wider net containing it
        self.assertEqual("10.77.0.0/24", apcfg.pick_ap_subnet(["192.168.99.5/32"]).cidr())      # a host route inside it
        self.assertEqual("10.77.1.0/24", apcfg.pick_ap_subnet(["192.168.99.0/24", "10.77.0.0/24"]).cidr())
        self.assertEqual("10.77.2.0/24", apcfg.pick_ap_subnet(["192.168.99.0/24", "10.77.0.0/23"]).cidr())
        self.assertEqual("10.77.0.0/24", apcfg.pick_ap_subnet(["192.168.99.0/24", "10.78.0.0/16"]).cidr())
        self.assertEqual("10.77.0.0/24", apcfg.pick_ap_subnet(["192.168.99.1/24"]).cidr())      # host bits in an address entry

    def test_everything_taken(self):
        with self.assertRaises(ValidationError):
            apcfg.pick_ap_subnet(["192.168.99.0/24", "10.77.0.0/16"])
        with self.assertRaises(ValidationError):
            apcfg.pick_ap_subnet(["10.0.0.0/8", "192.168.0.0/16"])

    def test_junk_entries_are_ignored(self):
        self.assertEqual("192.168.99.0/24", apcfg.pick_ap_subnet(["garbage", "", "fe80::/64", "1.2.3/24"]).cidr())

    def test_preferred_must_be_a_private_24(self):
        for bad in ("192.168.99.0/16", "8.8.8.0/24", "192.168.99.1/24"):
            with self.assertRaises(ValidationError):
                apcfg.pick_ap_subnet([], bad)

    def test_used_networks_from_a_real_capture_feed_the_picker(self):
        from ci_setup.parsers import ipjson
        routes = ipjson.parse_ip_route(helpers.fixture("real/ip_j_route.json"))
        addrs = ipjson.parse_ip_addr(helpers.fixture("real/ip_j_addr.json"))
        picked = apcfg.pick_ap_subnet(ipjson.used_ipv4_networks(routes, addrs))
        self.assertEqual("10.77.0.0/24", picked.cidr())             # the capture has 192.168.99.0/24 on ap0


class Nft(unittest.TestCase):
    def setUp(self):
        self.text = fw.render_nft("wlan0", "192.168.99.1")
        self.lines = [ln.strip() for ln in self.text.splitlines() if ln.strip() and not ln.strip().startswith("#")]

    def test_golden(self):
        helpers.golden_check(self, "ci_setup.nft", self.text)
        helpers.golden_check(self, "ci_setup_8081.nft", fw.render_nft("ap0", "10.77.3.1", 8081))
        helpers.golden_check(self, "ci_setup_teardown.nft", fw.render_nft_teardown())

    def chain(self, name):
        start = self.lines.index("chain %s {" % name)
        end = self.lines.index("}", start)
        return self.lines[start + 1:end]

    def test_the_filter_hooks_before_docker_nat(self):
        body = self.chain("raw_in")
        self.assertEqual("type filter hook prerouting priority raw; policy accept;", body[0])
        # priority raw is -300; Docker's DNAT lives at dstnat (-100)
        self.assertIn("priority raw", body[0])

    def test_everything_accepted_comes_from_the_ap_interface_and_is_one_of_the_known_services(self):
        sub = 'ip saddr 192.168.99.0/24 '
        allowed = {
            'iifname "wlan0" udp sport 68 udp dport 67 accept',
            'iifname "wlan0" ' + sub + 'udp dport 53 accept',
            'iifname "wlan0" ' + sub + 'tcp dport { 53, 80 } accept',
            'iifname "wlan0" ' + sub + 'ip daddr 192.168.99.1 tcp dport 8080 accept',
            'iifname "wlan0" ' + sub + 'ip daddr 224.0.0.251 udp dport 5353 accept',
            'iifname "wlan0" ' + sub + 'ip daddr 192.168.99.1 icmp type echo-request limit rate 5/second accept',
        }
        rules = self.chain("raw_in")[1:]
        self.assertEqual(allowed | {'iifname "wlan0" drop'}, set(rules))
        self.assertEqual('iifname "wlan0" drop', rules[-1])                      # the catch-all comes last
        for r in rules:
            self.assertTrue(r.startswith('iifname "wlan0" '))
            if "sport 68" not in r and not r.endswith(" drop"):
                self.assertIn(sub, r)                       # only a client still without an address is served by port alone
        # nothing mentions the host's other services
        for port in ("22", "5002", "11434", "443", "3000", "8000"):
            self.assertNotRegex(self.text, r"dport[^\n]*\b%s\b" % port)

    def test_forwarding_is_dropped_in_both_directions(self):
        body = self.chain("forward")
        self.assertEqual({'iifname "wlan0" drop', 'oifname "wlan0" drop'}, set(body[1:]))
        self.assertIn("hook forward", body[0])

    def test_no_nat_out_of_the_access_point(self):
        for word in ("masquerade", "snat", "dnat", "oifname \"eth"):
            self.assertNotIn(word, self.text)

    def test_redirects(self):
        body = self.chain("pre")
        self.assertIn("hook prerouting priority dstnat - 5", body[0])             # before Docker's own dstnat rules
        self.assertEqual({'iifname "wlan0" udp dport 53 redirect to :53', 'iifname "wlan0" tcp dport 53 redirect to :53',
                          'iifname "wlan0" tcp dport 80 redirect to :8080'}, set(body[1:]))

    def test_the_tables_exist_only_in_this_file_and_are_replaced_atomically(self):
        self.assertEqual(["add table inet ci_setup", "delete table inet ci_setup", "add table ip ci_setup_nat",
                          "delete table ip ci_setup_nat"], self.lines[:4])
        self.assertEqual("table inet ci_setup {", self.lines[4])
        tables = [ln for ln in self.lines if ln.startswith("table ")]
        self.assertEqual(["table inet ci_setup {", "table ip ci_setup_nat {"], tables)

    def test_subnet_defaults_to_the_24_around_the_ap_address_and_can_be_given(self):
        self.assertIn("ip saddr 10.77.3.0/24", fw.render_nft("ap0", "10.77.3.1"))
        self.assertIn("ip saddr 10.77.0.0/16", fw.render_nft("ap0", "10.77.3.1", 8080, "10.77.0.0/16"))
        self.assertEqual(fw.render_nft("wlan0", "192.168.99.1"), fw.render_nft("wlan0", "192.168.99.1", 8080, "192.168.99.0/24"))

    def test_teardown(self):
        t = fw.render_nft_teardown()
        self.assertEqual(["add table inet ci_setup", "delete table inet ci_setup", "add table ip ci_setup_nat",
                          "delete table ip ci_setup_nat"], t.strip().splitlines())

    def test_nft_chain_names_are_not_nft_keywords(self):
        # nftables 1.1.7 rejected `chain fwd`: fwd is a statement keyword. Keep names to ones it accepts.
        names = re.findall(r"chain (\w+) \{", self.text)
        self.assertEqual(["raw_in", "forward", "pre"], names)
        for bad in ("fwd", "accept", "drop", "type", "hook", "table", "chain", "ip", "tcp", "udp", "meta", "ct", "counter"):
            self.assertNotIn(bad, names)

    def test_invalid_parameters(self):
        for kw in (dict(iface="wl an"), dict(iface='wlan0" drop; accept'), dict(iface=""), dict(ap_ip="8.8.8.8"), dict(ap_ip="192.168.99.1\n"),
                   dict(ap_ip="x"), dict(port=80), dict(port=53), dict(port=0), dict(port=1023), dict(port=70000), dict(port="8080"),
                   dict(port=True), dict(subnet="10.0.0.0/24"), dict(subnet="8.8.8.0/24"), dict(subnet="192.168.99.1/24"),
                   dict(subnet="192.168.99.0/24 accept"), dict(subnet="")):
            args = dict(iface="wlan0", ap_ip="192.168.99.1", port=8080)
            args.update(kw)
            with self.assertRaises(ValidationError, msg=str(kw)):
                fw.render_nft(**args)

    def test_interface_name_cannot_break_out_of_its_string(self):
        for name in ("a", "wlan0", "wlp192s0", "a.b-c_d", "ap0"):
            text = fw.render_nft(name, "192.168.99.1")
            self.assertEqual({name}, set(re.findall(r'"([^"]*)"', text)))
            self.assertNotIn('""', text)


class Templating(unittest.TestCase):
    def test_placeholders_and_values_must_match(self):
        t = "a=@X@\nb=@Y@\n"
        self.assertEqual("a=1\nb=2\n", templating.render_template(t, {"X": "1", "Y": "2"}))
        with self.assertRaises(TemplateError):
            templating.render_template(t, {"X": "1"})
        with self.assertRaises(TemplateError):
            templating.render_template(t, {"X": "1", "Y": "2", "Z": "3"})
        with self.assertRaises(TemplateError):
            templating.render_template(t, {"X": 1, "Y": "2"})

    def test_single_pass_substitution(self):
        out = templating.render_template("a=@X@\nb=@Y@\n", {"X": "@Y@", "Y": "@X@"})
        self.assertEqual("a=@Y@\nb=@X@\n", out)

    def test_line_breaks_and_nul_are_refused(self):
        for bad in ("x\ny", "x\ry", "x\x00y"):
            with self.assertRaises(TemplateError):
                templating.render_template("a=@X@\n", {"X": bad})
        out = templating.render_template("a=@X@\n", {"X": "p\nq"}, multiline=("X",))
        self.assertEqual("a=p\nq\n", out)
        with self.assertRaises(TemplateError):
            templating.render_template("a=@X@\n", {"X": "p\rq"}, multiline=("X",))
        with self.assertRaises(TemplateError):
            templating.render_template("a=@X@\n", {"X": "p\x00q"}, multiline=("X",))

    def test_lint(self):
        templating.lint_config("# comment\n\nkey=value\nother.key[0]=v w x\n")
        templating.lint_config("bind-interfaces\nkey=v\n", allow_bare=True)
        for bad in ("key=value\nbad line\n", "Key=value\n", " key=value\n", "key=value \n", "bare\n", "=x\n", "k=v\x00\n", "k=v\r\n", "key value\n",
                    "key=v\n\tindented=1\n"):
            with self.assertRaises(TemplateError, msg=repr(bad)):
                templating.lint_config(bad)
        with self.assertRaises(TemplateError):
            templating.lint_config("Bare\n", allow_bare=True)

    def test_lint_catches_a_directive_smuggled_through_a_multiline_value(self):
        text = templating.render_template("a=@X@\n", {"X": "1\nINJECTED LINE"}, multiline=("X",))
        with self.assertRaises(TemplateError):
            templating.lint_config(text)

    def test_load_template_is_a_whitelist(self):
        for name in templating.TEMPLATE_NAMES:
            self.assertIn("@", templating.load_template(name))
        for bad in ("../validators.py", "/etc/passwd", "hostapd.conf", "", "hostapd.conf.in/../x"):
            with self.assertRaises(TemplateError):
                templating.load_template(bad)

    def test_shipped_templates_have_matching_placeholders(self):
        expect = {"hostapd.conf.in": {"IFACE", "CTRL_DIR", "SSID_HEX", "COUNTRY_LINES", "HW_MODE", "CHANNEL", "PSK_LINE", "MAX_STA"},
                  "dnsmasq.conf.in": {"IFACE", "AP_IP", "RANGE_START", "RANGE_END", "NETMASK", "LEASE", "RUN_DIR"},
                  "ci_setup.nft.in": {"IFACE", "AP_IP", "PORT", "SUBNET"}}
        for name, want in expect.items():
            self.assertEqual(want, templating.placeholders(templating.load_template(name)), name)

    def test_templates_contain_no_block_art_and_no_retired_names(self):
        for name in templating.TEMPLATE_NAMES:
            text = templating.load_template(name)
            self.assertNotIn("\U00002588", text)
            self.assertNotIn("CI" + " OS", text)
            self.assertTrue(text.isascii(), name)


class PrivateFile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "hostapd.conf")

    def mode(self, p=None):
        return stat.S_IMODE(os.stat(p or self.path).st_mode)

    def read(self, p=None):
        with open(p or self.path) as fh:
            return fh.read()

    def test_mode_is_0600_whatever_the_umask(self):
        for umask in (0o000, 0o022, 0o077):
            old = os.umask(umask)
            try:
                privfile.write_private_file(self.path, "secret\n")
            finally:
                os.umask(old)
            self.assertEqual(0o600, self.mode(), oct(umask))
            self.assertEqual("secret\n", self.read())

    def test_the_file_is_created_private_not_chmodded_later(self):
        # simulate a platform where fchmod does nothing: the file must still be 0600 because it was CREATED that way
        old = os.umask(0)
        try:
            with mock.patch.object(os, "fchmod", side_effect=OSError("no")):
                privfile.write_private_file(self.path, b"secret")
        finally:
            os.umask(old)
        self.assertEqual(0o600, self.mode())

    def test_open_is_called_with_a_private_mode_and_exclusive_create(self):
        real_open = os.open
        seen = []

        def spy(path, flags, mode=0o777, **kw):
            seen.append((path, flags, mode))
            return real_open(path, flags, mode, **kw)

        with mock.patch.object(os, "open", spy):
            privfile.write_private_file(self.path, "x")
        (path, flags, mode), = seen
        self.assertEqual(0o600, mode)
        self.assertTrue(flags & os.O_EXCL and flags & os.O_CREAT)
        self.assertTrue(path.startswith(self.path + ".tmp-"))

    def test_replace_is_atomic_and_leaves_no_temporary(self):
        privfile.write_private_file(self.path, "one")
        privfile.write_private_file(self.path, "two")
        self.assertEqual("two", self.read())
        self.assertEqual([os.path.basename(self.path)], os.listdir(self.tmp.name))
        self.assertEqual(0o600, self.mode())

    def test_an_existing_world_readable_file_is_replaced_by_a_private_one(self):
        with open(self.path, "w") as fh:
            fh.write("old")
        os.chmod(self.path, 0o644)
        privfile.write_private_file(self.path, "new")
        self.assertEqual(0o600, self.mode())

    def test_a_symlink_at_the_target_is_replaced_not_followed(self):
        victim = os.path.join(self.tmp.name, "victim")
        with open(victim, "w") as fh:
            fh.write("untouched")
        os.symlink(victim, self.path)
        privfile.write_private_file(self.path, "secret")
        self.assertEqual("untouched", self.read(victim))
        self.assertFalse(os.path.islink(self.path))

    def test_refusals(self):
        for bad in ("relative.conf", "", "/tmp/x\x00y"):
            with self.assertRaises(ValueError):
                privfile.write_private_file(bad, "x")
        for mode in (0o644, 0o660, 0o604, 0o700 | 0o001):
            with self.assertRaises(ValueError):
                privfile.write_private_file(self.path, "x", mode)
        self.assertEqual([], os.listdir(self.tmp.name))

    def test_a_failed_write_leaves_nothing_behind(self):
        with mock.patch.object(os, "fsync", side_effect=OSError("disk gone")):
            with self.assertRaises(OSError):
                privfile.write_private_file(self.path, "secret")
        self.assertEqual([], os.listdir(self.tmp.name))
        privfile.write_private_file(self.path, "ok")
        with mock.patch.object(os, "replace", side_effect=OSError("busy")):
            with self.assertRaises(OSError):
                privfile.write_private_file(self.path, "secret2")
        self.assertEqual(["hostapd.conf"], os.listdir(self.tmp.name))
        self.assertEqual("ok", self.read())

    def test_large_data(self):
        data = b"x" * (3 * 1024 * 1024)
        privfile.write_private_file(self.path, data)
        self.assertEqual(len(data), os.path.getsize(self.path))


if __name__ == "__main__":
    unittest.main()
