"""Tests for ci_setup.policy: the table of when the setup AP is offered, and the properties that must hold for every row."""
import itertools
import json
import unittest

import helpers
from ci_setup import policy
from ci_setup.errors import ValidationError
from ci_setup.policy import PolicyInput, decide


def D(ctx="installed-unclaimed", display="headless", network="down", **kw):
    kw.setdefault("has_setup_key", True)
    return decide(PolicyInput(ctx, display, network, **kw))


class Properties(unittest.TestCase):
    """For EVERY combination of context, display, network, kernel parameter and trigger."""

    def test_matrix_size(self):
        self.assertEqual(144, sum(1 for _ in policy.iter_matrix(True)))
        self.assertEqual(144, sum(1 for _ in policy.iter_matrix(False)))

    def test_an_automatic_ap_needs_every_condition(self):
        for has_key in (True, False):
            for inp, dec in policy.iter_matrix(has_key):
                if dec.offer_ap and dec.mode == "auto":
                    self.assertNotEqual("installed-claimed", inp.context, inp)
                    self.assertEqual("headless", inp.display, inp)
                    self.assertEqual("down", inp.network, inp)
                    self.assertNotEqual("0", inp.headless_param, inp)
                    self.assertFalse(inp.context == "live" and not inp.stick, inp)
                    self.assertEqual((), inp.triggers, inp)
                    self.assertNotEqual("1", inp.headless_param, inp)

    def test_claimed_never_opens_by_itself(self):
        for inp, dec in policy.iter_matrix():
            if inp.context == "installed-claimed" and inp.headless_param != "1" and not inp.triggers:
                self.assertFalse(dec.offer_ap, inp)
                self.assertIn("claimed_lockdown", dec.auto_blockers, inp)
                self.assertIn(dec.reason, ("claimed_lockdown", "kernel_param_off"), inp)

    def test_display_attached_never_opens_by_itself(self):
        for inp, dec in policy.iter_matrix():
            if inp.display in ("connected", "unknown") and inp.headless_param != "1" and not inp.triggers:
                self.assertFalse(dec.offer_ap, inp)

    def test_network_up_never_opens_by_itself(self):
        for inp, dec in policy.iter_matrix():
            if inp.network == "up" and inp.headless_param != "1" and not inp.triggers:
                self.assertFalse(dec.offer_ap, inp)

    def test_explicit_triggers_always_work_when_the_prerequisites_hold(self):
        for inp, dec in policy.iter_matrix(True):
            explicit = inp.headless_param == "1" or "cli" in inp.triggers
            if explicit:
                self.assertEqual("explicit", dec.mode, inp)
                self.assertTrue(dec.offer_ap, inp)         # a key exists in every row of this matrix

    def test_an_ap_is_never_offered_without_a_credential_channel(self):
        for inp, dec in policy.iter_matrix(False):
            if dec.offer_ap:
                self.assertIsNotNone(dec.credential_channel)
                self.assertEqual("connected", inp.display, "without a printed key only a console can show the credentials")
            if inp.display != "connected":
                self.assertFalse(dec.offer_ap, inp)

    def test_kernel_param_off_blocks_automatic_ap_in_every_context(self):
        for ctx in policy.CONTEXTS:
            self.assertFalse(D(ctx, headless_param="0", stick=True).offer_ap)

    def test_decisions_serialise(self):
        json.dumps([{"i": i.to_dict(), "d": d.to_dict()} for i, d in policy.iter_matrix()])

    def test_reason_is_always_a_known_code(self):
        for _, dec in policy.iter_matrix():
            self.assertIn(dec.reason, policy.PRIMARY_REASONS)


class Table(unittest.TestCase):
    def test_the_documented_rows(self):
        # report 02, section 4.3
        self.assertEqual((False, "plain_live_media"), (D("live", "headless", "down").offer_ap, D("live", "headless", "down").reason))
        self.assertTrue(D("live", "headless", "down", stick=True).offer_ap)
        self.assertEqual("display_attached", D("live", "connected", "down", stick=True).reason)
        self.assertTrue(D("installed-unclaimed", "headless", "down").offer_ap)
        self.assertEqual("display_attached", D("installed-unclaimed", "connected", "down").reason)
        self.assertEqual("claimed_lockdown", D("installed-claimed", "headless", "down").reason)

    def test_first_run_wizard_machine_with_a_screen_gets_no_hotspot(self):
        d = D("installed-unclaimed", "connected", "down")
        self.assertFalse(d.offer_ap)
        self.assertEqual("console", d.credential_channel)

    def test_unknown_display_is_treated_like_a_display(self):
        d = D("installed-unclaimed", "unknown", "down")
        self.assertEqual((False, "display_unknown"), (d.offer_ap, d.reason))
        self.assertTrue(D("installed-unclaimed", "unknown", "down", headless_param="1").offer_ap)

    def test_recovery_of_a_claimed_appliance(self):
        for kw in ({"headless_param": "1"}, {"triggers": ("menu_entry",)}, {"triggers": ("cli",)}, {"triggers": ("physical_key",)}):
            d = D("installed-claimed", "headless", "down", **kw)
            self.assertTrue(d.offer_ap, kw)
            self.assertEqual(("explicit", "explicit_trigger"), (d.mode, d.reason))
            self.assertEqual(("claimed_lockdown",), d.auto_blockers)

    def test_recovery_works_with_the_network_up_and_a_display(self):
        self.assertTrue(D("installed-claimed", "connected", "up", triggers=("cli",)).offer_ap)

    def test_untrusted_triggers_have_no_effect(self):
        for name in ("http_request", "ap_client", "lan_peer", "usb_key", "", "CLI", "cli ", None, 5):
            d = D("installed-claimed", "headless", "down", triggers=(name,))
            self.assertFalse(d.offer_ap, name)
            self.assertEqual(1, len(d.ignored_triggers), name)
        d = D("installed-claimed", "headless", "down", triggers=("http_request", "cli"))
        self.assertTrue(d.offer_ap)
        self.assertEqual(("http_request",), d.ignored_triggers)

    def test_grace_period(self):
        d = D("installed-unclaimed", "headless", "down", network_down_for_s=20)
        self.assertEqual((False, "grace_period", 40), (d.offer_ap, d.reason, d.wait_s))
        d = D("installed-unclaimed", "headless", "down", network_down_for_s=59.2)
        self.assertEqual(1, d.wait_s)
        self.assertTrue(D("installed-unclaimed", "headless", "down", network_down_for_s=60).offer_ap)
        self.assertEqual(0, D("installed-unclaimed", "headless", "down", network_down_for_s=60).wait_s)
        # an explicit trigger does not wait
        self.assertTrue(D("installed-claimed", "headless", "down", headless_param="1", network_down_for_s=0).offer_ap)

    def test_missing_radio_blocks_even_an_explicit_request(self):
        d = D("installed-claimed", "headless", "down", headless_param="1", ap_capable_radio=False)
        self.assertEqual((False, "explicit", "no_ap_capable_radio"), (d.offer_ap, d.mode, d.reason))
        d = D("installed-unclaimed", "headless", "down", ap_capable_radio=False)
        self.assertEqual("no_ap_capable_radio", d.reason)

    def test_no_credential_channel_refuses_to_open(self):
        d = D("installed-unclaimed", "headless", "down", has_setup_key=False)
        self.assertEqual((False, "no_credential_channel", None), (d.offer_ap, d.reason, d.credential_channel))
        d = D("installed-unclaimed", "headless", "down", has_setup_key=False, headless_param="1")
        self.assertEqual((False, "no_credential_channel"), (d.offer_ap, d.reason))
        d = D("installed-unclaimed", "connected", "up", has_setup_key=False, headless_param="1")
        self.assertTrue(d.offer_ap)
        self.assertEqual("console", d.credential_channel)

    def test_static_test_credentials_only_with_ci_headless_1(self):
        d = D("live", "headless", "down", stick=True, has_setup_key=False, static_credentials_test=True)
        self.assertFalse(d.offer_ap)
        d = D("live", "headless", "down", stick=True, has_setup_key=False, static_credentials_test=True, headless_param="1")
        self.assertEqual((True, "test_static"), (d.offer_ap, d.credential_channel))
        d = D("live", "headless", "down", stick=True, has_setup_key=False, static_credentials_test=True, triggers=("cli",))
        self.assertFalse(d.offer_ap)                           # a CLI trigger is not the kernel parameter

    def test_provisioning_file_comes_first_on_a_stick(self):
        d = D("live", "headless", "down", stick=True, provisioning_file=True)
        self.assertEqual((False, "provisioning_file_first", True), (d.offer_ap, d.reason, d.provision_first))
        d = D("live", "headless", "down", stick=True, provisioning_file=True, provisioning_failed=True)
        self.assertEqual((True, False), (d.offer_ap, d.provision_first))
        d = D("live", "connected", "down", stick=True, provisioning_file=True)
        self.assertTrue(d.provision_first)                      # honoured with a display attached as well
        d = D("installed-unclaimed", "headless", "down", provisioning_file=True)
        self.assertFalse(d.provision_first)                     # there is no CI-SHARED volume on an installed system
        d = D("live", "headless", "down", stick=False, provisioning_file=True)
        self.assertFalse(d.provision_first)
        d = D("live", "headless", "down", stick=True, provisioning_file=True, headless_param="1")
        self.assertTrue(d.offer_ap and d.provision_first)       # forced: AP and file are independent

    def test_invalid_input_is_an_error(self):
        for kw in ({"context": "installed"}, {"display": "maybe"}, {"network": "flaky"}, {"headless_param": "2"}):
            args = dict(context="live", display="headless", network="down")
            args.update(kw)
            with self.assertRaises(ValidationError):
                decide(PolicyInput(**args))


class Helpers(unittest.TestCase):
    def test_network_state(self):
        up = [(True, c) for c in ("full", "limited", "portal", "unknown")]
        down = [(False, c) for c in ("full", "limited", "portal", "unknown", "none")] + [(True, "none")]
        for route, conn in up:
            self.assertEqual("up", policy.network_state(route, conn), (route, conn))
        for route, conn in down:
            self.assertEqual("down", policy.network_state(route, conn), (route, conn))
        self.assertEqual("down", policy.network_state(True, "garbage"))

    def test_context_from_facts(self):
        self.assertEqual("live", policy.context_from_facts(True, True))
        self.assertEqual("live", policy.context_from_facts(True, False))
        self.assertEqual("installed-claimed", policy.context_from_facts(False, True))
        self.assertEqual("installed-unclaimed", policy.context_from_facts(False, False))

    def test_all_combinations_of_helpers_are_total(self):
        for route, conn in itertools.product((True, False), ("full", "limited", "portal", "none", "unknown", "x")):
            self.assertIn(policy.network_state(route, conn), policy.NETWORKS)


class Golden(unittest.TestCase):
    def test_table_text(self):
        helpers.golden_check(self, "policy_table.txt", policy.matrix_table())
        helpers.golden_check(self, "policy_table_no_key.txt", policy.matrix_table(False))

    def test_full_matrix_json(self):
        rows = [{"input": i.to_dict(), "decision": d.to_dict()} for i, d in policy.iter_matrix()]
        helpers.golden_check(self, "policy_matrix.json", helpers.to_json(rows))


if __name__ == "__main__":
    unittest.main()
