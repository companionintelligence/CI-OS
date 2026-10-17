"""Tests for the command line: python3 -m ci_setup probe | policy | render | selftest."""
import io
import json
import os
import subprocess
import sys
import unittest

import helpers
from ci_setup import cli, probe, runners
from ci_setup.fs import DictFs

SCEN = helpers.fixture_path("scenarios/two_radios_uplink_on_first")


def run_cli(argv, stdin_text="", runner=None, fs=None):
    out = io.StringIO()
    rc = cli.main(argv, runner=runner, fs=fs, stdin=io.StringIO(stdin_text), stdout=out)
    return rc, out.getvalue()


class Probe(unittest.TestCase):
    def test_probe_from_fixtures_prints_json(self):
        rc, text = run_cli(["probe", "--fixtures", SCEN])
        self.assertEqual(0, rc)
        rep = json.loads(text)
        self.assertEqual("dedicated", rep["radio"]["mode"])
        self.assertEqual("wlan0", rep["ip"]["uplink"])
        self.assertEqual(1, rep["version"])

    def test_fixture_runs_do_not_look_at_this_machine(self):
        rc, text = run_cli(["probe", "--fixtures", helpers.fixture_path("scenarios/no_ap_capable_radio")])
        rep = json.loads(text)
        self.assertEqual(("unknown", False, False), (rep["system"]["display"], rep["system"]["live"], rep["system"]["claimed"]))
        self.assertIsNone(rep["system"]["timezone"])

    def test_probe_country_override(self):
        rc, text = run_cli(["probe", "--fixtures", helpers.fixture_path("scenarios/no_ap_capable_radio"), "--country", "fr"])
        self.assertEqual(("FR", "explicit"), (json.loads(text)["country"]["code"], json.loads(text)["country"]["source"]))

    def test_no_scan(self):
        rc, text = run_cli(["probe", "--fixtures", SCEN, "--no-scan"])
        self.assertEqual(0, json.loads(text)["scan"]["count"])

    def test_probe_with_injected_runner_and_fs(self):
        fr = runners.FixtureRunner.from_dir(SCEN)
        rc, text = run_cli(["probe"], runner=runners.ReadOnlyRunner(fr), fs=DictFs())
        self.assertEqual(0, rc)
        self.assertTrue(fr.calls)

    def test_probe_on_a_machine_without_the_tools_still_works(self):
        rc, text = run_cli(["probe"], runner=runners.ReadOnlyRunner(runners.FixtureRunner()), fs=DictFs())
        self.assertEqual(0, rc)
        rep = json.loads(text)
        self.assertEqual("no_wifi", rep["radio"]["reason"])

    def test_the_cli_never_runs_a_command_outside_the_read_only_list(self):
        fr = runners.FixtureRunner.from_dir(SCEN)
        run_cli(["probe"], runner=fr, fs=DictFs())             # even handed a bare runner, probe wraps it
        run_cli(["policy", "--auto"], runner=fr, fs=DictFs())
        self.assertGreater(len(fr.calls), 10)
        for argv in fr.calls:
            self.assertTrue(runners.is_read_only_command(argv), argv)


class Policy(unittest.TestCase):
    def test_explicit_inputs(self):
        rc, text = run_cli(["policy", "--context", "installed-claimed", "--display", "headless", "--network", "down",
                            "--setup-key-present"])
        d = json.loads(text)["decision"]
        self.assertEqual((False, "claimed_lockdown"), (d["offer_ap"], d["reason"]))
        rc, text = run_cli(["policy", "--context", "installed-claimed", "--headless-param", "1", "--setup-key-present"])
        d = json.loads(text)["decision"]
        self.assertEqual((True, "explicit"), (d["offer_ap"], d["mode"]))

    def test_triggers(self):
        rc, text = run_cli(["policy", "--context", "installed-claimed", "--trigger", "http_request", "--trigger", "cli",
                            "--setup-key-present"])
        d = json.loads(text)["decision"]
        self.assertTrue(d["offer_ap"])
        self.assertEqual(["http_request"], d["ignored_triggers"])

    def test_matrix(self):
        rc, text = run_cli(["policy", "--matrix"])
        self.assertEqual(144, len(json.loads(text)))
        rc, text = run_cli(["policy", "--matrix", "--table"])
        self.assertIn("installed-claimed", text)
        self.assertIn("claimed_lockdown", text)
        self.assertEqual(helpers.fixture("../golden/policy_table.txt"), text)

    def test_auto_from_a_probe(self):
        files = {"/proc/cmdline": helpers.fixture("sys/cmdline_stick_headless.txt")}
        rc, text = run_cli(["policy", "--auto", "--fixtures", helpers.fixture_path("scenarios/single_radio_offline"),
                            "--setup-key-present"], fs=DictFs(files=files))
        out = json.loads(text)
        self.assertEqual("live", out["input"]["context"])
        self.assertTrue(out["input"]["stick"])
        self.assertEqual("1", out["input"]["headless_param"])
        self.assertEqual("down", out["input"]["network"])
        self.assertTrue(out["decision"]["offer_ap"])

    def test_auto_without_ap_radio_refuses(self):
        rc, text = run_cli(["policy", "--auto", "--fixtures", helpers.fixture_path("scenarios/no_ap_capable_radio"),
                            "--headless-param", "1", "--setup-key-present"], fs=DictFs())
        d = json.loads(text)["decision"]
        self.assertEqual((False, "no_ap_capable_radio"), (d["offer_ap"], d["reason"]))

    def test_bad_arguments_exit_2(self):
        for argv in (["policy", "--context", "nope"], ["nonsense"], [], ["render"], ["policy", "--down-for", "abc"]):
            with self.assertRaises(SystemExit) as cm:
                run_cli(argv)
            self.assertEqual(2, cm.exception.code)


class Render(unittest.TestCase):
    def test_example_all(self):
        rc, text = run_cli(["render", "all", "--example"])
        self.assertEqual(0, rc)
        out = json.loads(text)
        self.assertEqual({"hostapd.conf", "dnsmasq.conf", "ci_setup.nft", "ci_setup-teardown.nft"}, set(out["files"]))
        self.assertIn("EXAMPLEKEY12", out["files"]["hostapd.conf"])
        self.assertIn("contains the AP key", out["note"])
        self.assertIn("iifname \"wlan0\" drop", out["files"]["ci_setup.nft"])

    def test_key_from_stdin_only(self):
        rc, text = run_cli(["render", "hostapd", "--key-stdin", "--ssid", "My AP", "--country", "de", "--channel", "11"], "S3cretKey!!\n")
        self.assertEqual(0, rc)
        conf = json.loads(text)["files"]["hostapd.conf"]
        self.assertIn("wpa_passphrase=S3cretKey!!", conf)
        self.assertIn("country_code=DE", conf)
        self.assertIn("channel=11", conf)
        self.assertEqual(b"My AP".hex(), [ln for ln in conf.splitlines() if ln.startswith("ssid2=")][0][6:])

    def test_a_key_option_does_not_exist(self):
        for flag in ("--key", "--passphrase", "--psk", "--password"):
            with self.assertRaises(SystemExit):
                run_cli(["render", "hostapd", flag, "x"])

    def test_hostapd_without_a_key_source_is_refused(self):
        rc, text = run_cli(["render", "hostapd"])
        self.assertEqual(2, rc)

    def test_other_files_need_no_key(self):
        for what in ("dnsmasq", "nft", "nft-teardown"):
            rc, text = run_cli(["render", what])
            self.assertEqual(0, rc, what)
            self.assertEqual(1, len(json.loads(text)["files"]))

    def test_raw_output(self):
        rc, text = run_cli(["render", "dnsmasq", "--raw", "--subnet", "10.77.3.0/24", "--iface", "ap0"])
        self.assertTrue(text.startswith("# Generated by ci_setup"))
        self.assertIn("listen-address=10.77.3.1", text)
        rc, text = run_cli(["render", "all", "--example", "--raw"])
        self.assertEqual(2, rc)

    def test_refusals_exit_1(self):
        for argv in (["render", "nft", "--iface", "wl an"], ["render", "dnsmasq", "--subnet", "8.8.8.0/24"],
                     ["render", "nft", "--port", "80"], ["render", "hostapd", "--example", "--channel", "99"],
                     ["render", "hostapd", "--example", "--country", "ZZZ"]):
            rc, text = run_cli(argv)
            self.assertEqual(1, rc, argv)

    def test_key_file_content_is_validated(self):
        rc, text = run_cli(["render", "hostapd", "--key-stdin"], "short\n")
        self.assertEqual(1, rc)
        self.assertNotIn("short", text)

    def test_stderr_never_contains_the_key(self):
        import contextlib
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc, _ = run_cli(["render", "hostapd", "--key-stdin"], "Sh0rt\n")
        self.assertEqual(1, rc)
        self.assertNotIn("Sh0rt", err.getvalue())


class Selftest(unittest.TestCase):
    def test_in_process(self):
        rc, text = run_cli(["selftest"])
        out = json.loads(text)
        self.assertEqual(0, rc, [c for c in out["checks"] if not c["ok"]])
        self.assertTrue(out["ok"])
        self.assertGreaterEqual(len(out["checks"]), 10)

    def test_subprocess_module_entry_point(self):
        env = dict(os.environ)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        res = subprocess.run([sys.executable, "-m", "ci_setup", "selftest"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=env, cwd=helpers.HEADLESS, timeout=60)
        self.assertEqual(0, res.returncode, res.stderr.decode())
        self.assertTrue(json.loads(res.stdout.decode())["ok"])

    def test_subprocess_version_and_help(self):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        res = subprocess.run([sys.executable, "-m", "ci_setup", "--version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                             cwd=helpers.HEADLESS, timeout=60)
        self.assertEqual(0, res.returncode)
        self.assertIn("ci_setup 0.", (res.stdout + res.stderr).decode())
        res = subprocess.run([sys.executable, "-m", "ci_setup", "-h"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                             cwd=helpers.HEADLESS, timeout=60)
        self.assertEqual(0, res.returncode)
        for word in (b"probe", b"policy", b"render", b"selftest"):
            self.assertIn(word, res.stdout)

    def test_subprocess_probe_on_this_machine_is_json_and_read_only(self):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        res = subprocess.run([sys.executable, "-m", "ci_setup", "probe", "--no-scan"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=env, cwd=helpers.HEADLESS, timeout=120)
        self.assertEqual(0, res.returncode, res.stderr.decode())
        rep = json.loads(res.stdout.decode())
        self.assertIn("radio", rep)
        # whatever this machine is, every command the probe ran is on the read-only list
        for cmd in rep["commands"]:
            self.assertTrue(runners.is_read_only_command(cmd.split(" ")), cmd)


if __name__ == "__main__":
    unittest.main()
