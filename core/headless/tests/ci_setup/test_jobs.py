"""Tests for ci_setup.jobs: every transition, every timeout, cancellation from every state, snapshots, and random event sequences."""
import json
import random
import unittest

import helpers
from ci_setup import jobs
from ci_setup.clock import ManualClock
from ci_setup.jobs import Job

MAC = "8a:11:22:33:44:01"
MAC2 = "8a:11:22:33:44:02"

# a script that reaches each state in turn: (event, kwargs)
PATH = [
    ("start", {}),                                                           # -> probing
    ("probe_ok", {"phy": "phy0", "iface": "wlan0", "mode": "sequential"}),   # stays in probing
    ("ap_started", {}),                                                      # -> ap_up
    ("client_associated", {"mac": MAC}),                                     # -> client_joined
    ("authenticated", {}),
    ("credentials", {"ssid": "HomeNet", "security": "wpa2", "hidden": False}),   # -> credentials_received
    ("join_started", {}),                                                    # -> joining
    ("join_ok", {}),                                                         # -> verifying
]
STATE_AFTER = {0: "probing", 1: "probing", 2: "ap_up", 3: "client_joined", 4: "client_joined", 5: "credentials_received",
               6: "joining", 7: "verifying"}


def new_job(clock=None, job_id="0123456789abcdef", **kw):
    return Job(job_id, clock or ManualClock(1000.0), **kw)


def drive(job, upto):
    """Apply PATH[0..upto] inclusive, one second apart; returns the job."""
    for i in range(upto + 1):
        ev, kw = PATH[i]
        r = job.apply(ev, **kw)
        assert r.accepted, (ev, r)
        job.clock.advance(1.0)
    return job


class HappyPath(unittest.TestCase):
    def test_full_run(self):
        j = new_job()
        self.assertEqual("idle", j.state)
        effects = {}
        for i, (ev, kw) in enumerate(PATH):
            r = j.apply(ev, **kw)
            self.assertTrue(r.accepted, (ev, r.reason))
            self.assertEqual(STATE_AFTER[i], j.state, ev)
            effects[ev] = [e["op"] for e in r.effects]
            j.clock.advance(1.0)
        r = j.apply("verify_ok")
        self.assertEqual(("done", "joined", None), (j.state, j.outcome, j.error_code))
        self.assertTrue(j.terminal)
        self.assertEqual({"start": ["probe"], "probe_ok": ["start_ap"], "ap_started": ["publish_credentials"],
                          "client_associated": [], "authenticated": [], "credentials": ["begin_join"], "join_started": [],
                          "join_ok": ["verify"]}, effects)
        self.assertEqual([{"op": "finish", "linger_s": 30}], list(r.effects))

    def test_effects_carry_the_data_the_agent_needs(self):
        j = new_job()
        j.apply("start")
        r = j.apply("probe_ok", phy="phy0", iface="wlan0", mode="dedicated")
        self.assertEqual({"op": "start_ap", "phy": "phy0", "iface": "wlan0", "mode": "dedicated"}, r.effects[0])
        j.apply("ap_started")
        j.apply("client_associated", mac=MAC)
        j.apply("authenticated")
        r = j.apply("credentials", ssid="Home Net", security="sae-only", hidden=True)
        self.assertEqual({"op": "begin_join", "ssid": "Home Net", "security": "sae-only", "hidden": True}, r.effects[0])
        for e in r.effects:
            self.assertNotIn("psk", e)

    def test_join_progress_steps(self):
        j = drive(new_job(), 6)
        for step in jobs.JOIN_STEPS:
            self.assertTrue(j.apply("join_progress", step=step).accepted)
            self.assertEqual(step, j.step)
            self.assertEqual("joining", j.state)
        self.assertFalse(j.apply("join_progress", step="teleporting").accepted)

    def test_uplink_appearing_ends_an_idle_job(self):
        j = drive(new_job(), 2)
        r = j.apply("uplink_appeared")
        self.assertEqual(("done", "uplink_appeared", ["teardown"]), (j.state, j.outcome, [e["op"] for e in r.effects]))
        j = drive(new_job(), 3)                                         # a client is associated but has not authenticated
        self.assertTrue(j.apply("uplink_appeared").accepted)
        self.assertEqual("done", j.state)

    def test_uplink_does_not_interrupt_a_person_mid_setup(self):
        j = drive(new_job(), 4)                                         # authenticated
        r = j.apply("uplink_appeared")
        self.assertEqual((False, "client_active", "client_joined"), (r.accepted, r.reason, j.state))


class Failures(unittest.TestCase):
    def test_probe_and_ap_failures(self):
        for ev, code in (("probe_failed", "no_ap_capable_radio"), ("ap_failed", "hostapd_exited")):
            j = new_job()
            j.apply("start")
            r = j.apply(ev, code=code)
            self.assertEqual(("failed", code, ["teardown"]), (j.state, j.error_code, [e["op"] for e in r.effects]))
        j = new_job()
        j.apply("start")
        j.apply("ap_failed")
        self.assertEqual("ap_failed", j.error_code)                   # default code

    def test_join_failure_rolls_back(self):
        j = drive(new_job(), 6)
        r = j.apply("join_failed", code="bad_psk")
        self.assertEqual(("rolling_back", "bad_psk", ["rollback"]), (j.state, j.error_code, [e["op"] for e in r.effects]))
        r = j.apply("rollback_ok", reopen_ap=True)
        self.assertEqual(("rolled_back", "bad_psk", [{"op": "reopen_ap"}]), (j.state, j.error_code, list(r.effects)))
        self.assertEqual("rolled_back", j.outcome)

    def test_rollback_without_reopening_tears_down(self):
        j = drive(new_job(), 6)
        j.apply("join_failed", code="dhcp_timeout")
        r = j.apply("rollback_ok")
        self.assertEqual([{"op": "teardown"}], list(r.effects))

    def test_verify_failure_rolls_back(self):
        j = drive(new_job(), 7)
        j.apply("verify_failed", code="upstream_portal")
        self.assertEqual("rolling_back", j.state)
        j.apply("rollback_ok", reopen_ap=False)
        self.assertEqual(("rolled_back", "upstream_portal"), (j.state, j.error_code))

    def test_rollback_failure_is_failed(self):
        j = drive(new_job(), 6)
        j.apply("join_failed", code="no_ap_seen")
        j.apply("rollback_failed", code="nm_unreachable")
        self.assertEqual(("failed", "nm_unreachable"), (j.state, j.error_code))

    def test_bad_codes_are_rejected(self):
        j = drive(new_job(), 6)
        for bad in ("Bad Code", "x" * 41, "", 5, None, "a;b", "a\nb", "\U000000e9"):
            r = j.apply("join_failed", code=bad)
            self.assertFalse(r.accepted, bad)
            self.assertEqual("joining", j.state)


class Cancellation(unittest.TestCase):
    def test_cancel_from_every_active_state(self):
        for upto, state in STATE_AFTER.items():
            j = drive(new_job(), upto)
            self.assertEqual(state, j.state)
            r = j.apply("cancel")
            self.assertTrue(r.accepted, state)
            if state in ("joining", "verifying"):
                self.assertEqual(("rolling_back", "cancelled", ["rollback"]), (j.state, j.error_code, [e["op"] for e in r.effects]), state)
                j.apply("rollback_ok", reopen_ap=False)
                self.assertEqual(("rolled_back", "cancelled"), (j.state, j.error_code))
            else:
                self.assertEqual(("failed", "cancelled", "cancelled", ["teardown"]),
                                 (j.state, j.error_code, j.outcome, [e["op"] for e in r.effects]), state)

    def test_cancel_in_credentials_received_changes_nothing_so_no_rollback(self):
        j = drive(new_job(), 5)
        self.assertEqual([{"op": "teardown"}], list(j.apply("cancel").effects))

    def test_cancel_not_accepted_when_idle_or_terminal(self):
        j = new_job()
        self.assertFalse(j.apply("cancel").accepted)
        self.assertEqual("not_allowed_in_state", j.apply("cancel").reason)
        j = drive(new_job(), 2)
        j.apply("cancel")
        r = j.apply("cancel")
        self.assertEqual((False, "terminal"), (r.accepted, r.reason))

    def test_cancel_while_rolling_back_is_not_a_second_rollback(self):
        j = drive(new_job(), 6)
        j.apply("join_failed", code="x")
        r = j.apply("cancel")
        self.assertEqual((False, "rolling_back"), (r.accepted, j.state))


class Timeouts(unittest.TestCase):
    def after(self, j, seconds):
        j.clock.advance(seconds)
        return j.tick()

    def test_probing(self):
        j = new_job()
        j.apply("start")
        self.assertEqual("ok", self.after(j, 59.9).reason)
        r = self.after(j, 0.2)
        self.assertEqual(("timeout", "failed", "timeout_probe", [{"op": "teardown"}]), (r.reason, j.state, j.error_code, list(r.effects)))

    def test_ap_idle_timeout_is_fifteen_minutes_from_ap_up_and_clients_do_not_extend_it(self):
        j = drive(new_job(), 2)                                         # ap_up reached at t=1002 (after the third second)
        j.clock.advance(100)
        j.apply("client_associated", mac=MAC)
        j.clock.advance(780)                                            # 881 s since ap_up
        self.assertEqual("ok", j.tick().reason)
        j.clock.advance(20)                                             # 901 s: past the 900 s idle limit though a client sits there
        r = j.tick()
        self.assertEqual(("timeout", "failed", "timeout_idle"), (r.reason, j.state, j.error_code))

    def test_a_client_coming_and_going_does_not_restart_the_idle_clock(self):
        j = drive(new_job(), 2)
        for _ in range(5):
            j.clock.advance(150)
            j.apply("client_associated", mac=MAC)
            j.clock.advance(1)
            j.apply("client_left", mac=MAC)                              # back to ap_up each time
            self.assertEqual("ap_up", j.state)
        j.clock.advance(200)                                            # 5 * 151 + 200 = 955 s since ap_up
        r = j.tick()
        self.assertEqual(("timeout", "failed", "timeout_idle"), (r.reason, j.state, j.error_code))

    def test_authentication_lifts_the_idle_limit_but_not_the_total_one(self):
        j = drive(new_job(), 3)
        j.clock.advance(800)
        j.apply("authenticated")
        j.clock.advance(1000)                                           # 1800 s: beyond idle (900) but inside total (2700)
        self.assertEqual("ok", j.tick().reason)
        self.assertEqual("client_joined", j.state)
        j.clock.advance(1000)                                           # 2800 s
        r = j.tick()
        self.assertEqual(("timeout", "timeout_total"), (r.reason, j.error_code))

    def test_credentials_received_timeout(self):
        j = drive(new_job(), 5)
        r = self.after(j, 31)
        self.assertEqual(("failed", "timeout_start_join", [{"op": "teardown"}]), (j.state, j.error_code, list(r.effects)))

    def test_joining_and_verifying_roll_back_on_timeout(self):
        j = drive(new_job(), 6)
        r = self.after(j, 91)
        self.assertEqual(("rolling_back", "timeout_join", [{"op": "rollback"}]), (j.state, j.error_code, list(r.effects)))
        j = drive(new_job(), 7)
        r = self.after(j, 61)
        self.assertEqual(("rolling_back", "timeout_verify"), (j.state, j.error_code))

    def test_rollback_timeout_is_failed(self):
        j = drive(new_job(), 6)
        j.apply("join_failed", code="x")
        r = self.after(j, 61)
        self.assertEqual(("failed", "timeout_rollback", [{"op": "teardown"}]), (j.state, j.error_code, list(r.effects)))

    def test_every_non_terminal_state_has_a_deadline_and_a_target(self):
        for upto, state in STATE_AFTER.items():
            j = drive(new_job(), upto)
            self.assertIsNotNone(j._deadline, state)
            self.assertIn(state, jobs.TIMEOUT_TARGETS)
            j.clock.advance(100000)
            r = j.tick()
            self.assertEqual("timeout", r.reason, state)
            self.assertEqual(jobs.TIMEOUT_TARGETS[state], j.state, state)
        self.assertNotIn("idle", jobs.TIMEOUT_TARGETS)
        self.assertEqual(set(jobs.TIMEOUT_TARGETS), set(jobs.STATES) - set(jobs.TERMINAL) - {"idle"})

    def test_terminal_states_have_no_deadline(self):
        j = drive(new_job(), 7)
        j.apply("verify_ok")
        self.assertIsNone(j._deadline)
        j.clock.advance(10 ** 6)
        self.assertEqual("ok", j.tick().reason)
        self.assertEqual("done", j.state)

    def test_an_event_after_the_deadline_sees_the_timeout_first(self):
        j = drive(new_job(), 6)
        j.clock.advance(100)
        r = j.apply("join_ok")                                          # the join took too long; the late success is not honoured
        self.assertEqual("rolling_back", j.state)
        self.assertEqual([{"op": "rollback"}], [e for e in r.effects if e["op"] == "rollback"])
        self.assertFalse(r.accepted)
        self.assertEqual("not_allowed_in_state", r.reason)

    def test_event_after_a_terminating_timeout_reports_the_effects(self):
        j = drive(new_job(), 2)
        j.clock.advance(5000)
        r = j.apply("client_associated", mac=MAC)
        self.assertEqual((False, "terminal_after_timeout", "failed"), (r.accepted, r.reason, j.state))
        self.assertEqual([{"op": "teardown"}], list(r.effects))
        self.assertEqual("ap_up", r.previous)

    def test_custom_config(self):
        cfg = jobs.JobConfig(probe_timeout_s=5.0)
        j = new_job(config=cfg)
        j.apply("start")
        j.clock.advance(6)
        self.assertEqual("timeout", j.tick().reason)


class Clients(unittest.TestCase):
    def test_client_left_returns_to_ap_up_only_when_nobody_is_left_and_nobody_authenticated(self):
        j = drive(new_job(), 2)
        j.apply("client_associated", mac=MAC)
        j.apply("client_associated", mac=MAC2)
        j.apply("client_left", mac=MAC)
        self.assertEqual("client_joined", j.state)
        j.apply("client_left", mac=MAC2)
        self.assertEqual("ap_up", j.state)
        j.apply("client_associated", mac=MAC)
        j.apply("authenticated")
        j.apply("client_left", mac=MAC)
        self.assertEqual("client_joined", j.state)                      # an authenticated session is not dropped by roaming

    def test_credentials_need_authentication(self):
        j = drive(new_job(), 3)
        r = j.apply("credentials", ssid="HomeNet", security="wpa2")
        self.assertEqual((False, "not_authenticated", "client_joined"), (r.accepted, r.reason, j.state))
        self.assertIsNone(j.ssid)

    def test_credentials_validation(self):
        j = drive(new_job(), 4)
        for kw in ({}, {"ssid": ""}, {"ssid": "a\nb"}, {"ssid": "ok", "security": "wep"}, {"ssid": "ok", "security": "enterprise"},
                   {"ssid": "ok", "hidden": "yes"}, {"ssid": "ok", "extra": 1}, {"ssid": "x" * 33}):
            r = j.apply("credentials", **kw)
            self.assertFalse(r.accepted, kw)
            self.assertEqual("client_joined", j.state)

    def test_client_cap(self):
        j = drive(new_job(config=jobs.JobConfig(max_clients=2)), 2)
        self.assertTrue(j.apply("client_associated", mac=MAC).accepted)
        self.assertTrue(j.apply("client_associated", mac=MAC2).accepted)
        r = j.apply("client_associated", mac="8a:11:22:33:44:03")
        self.assertEqual((False, "too_many_clients"), (r.accepted, r.reason))
        self.assertTrue(j.apply("client_associated", mac=MAC).accepted)        # a known client may re-associate

    def test_bad_mac(self):
        j = drive(new_job(), 2)
        for bad in ("zz", "ff:ff:ff:ff:ff:ff", "01:00:5e:00:00:01", "", None, 5):
            self.assertFalse(j.apply("client_associated", mac=bad).accepted, bad)
        self.assertEqual("ap_up", j.state)


class Rejections(unittest.TestCase):
    def test_secrets_cannot_enter_the_machine(self):
        for name in jobs.FORBIDDEN_FIELDS:
            j = drive(new_job(), 4)
            r = j.apply("credentials", ssid="HomeNet", **{name: "hunter2hunter2"})
            self.assertEqual((False, "forbidden_field"), (r.accepted, r.reason), name)
            self.assertEqual("client_joined", j.state)
            self.assertNotIn("hunter2", json.dumps(j.snapshot()))

    def test_unknown_data_keys(self):
        j = new_job()
        self.assertFalse(j.apply("start", surprise=1).accepted)
        self.assertEqual("idle", j.state)

    def test_not_allowed_in_state(self):
        j = new_job()
        for ev in ("probe_ok", "ap_started", "client_associated", "credentials", "join_started", "join_ok", "verify_ok",
                   "rollback_ok", "client_left", "authenticated", "uplink_appeared"):
            r = j.apply(ev)
            self.assertEqual((False, "not_allowed_in_state"), (r.accepted, r.reason), ev)
        self.assertFalse(j.apply("no_such_event").accepted)
        for bad in (None, 5, b"start", ["start"]):
            r = j.apply(bad)
            self.assertEqual((False, "bad_event"), (r.accepted, r.reason))
        self.assertTrue(j.apply("tick").accepted)

    def test_probe_ok_data_validation(self):
        j = new_job()
        j.apply("start")
        for kw in ({"phy": "wlan0"}, {"iface": "a b"}, {"mode": "teleport"}, {"extra": 1}, {"iface": 'wl"an'}):
            self.assertFalse(j.apply("probe_ok", **kw).accepted, kw)
        self.assertTrue(j.apply("probe_ok").accepted)

    def test_terminal_absorbs_everything(self):
        for finish in (
                lambda j: drive(j, 2) and j.apply("cancel"),
                lambda j: drive(j, 7) and j.apply("verify_ok"),
                lambda j: drive(j, 6) and j.apply("join_failed", code="x") and j.apply("rollback_ok"),
                lambda j: drive(j, 6) and j.apply("join_failed", code="x") and j.apply("rollback_failed")):
            j = new_job()
            finish(j)
            self.assertTrue(j.terminal)
            snap = j.snapshot()
            for ev in jobs.EVENTS:
                r = j.apply(ev)
                self.assertFalse(r.accepted, ev)
                self.assertEqual("terminal", r.reason)
            self.assertEqual(snap, j.snapshot())


class TableCoverage(unittest.TestCase):
    def test_every_listed_transition_is_reachable_and_every_other_pair_is_rejected(self):
        """Exhaustive: for each (state, event) pair, put a job in the state and apply the event."""
        data = {
            "probe_ok": {}, "client_associated": {"mac": MAC}, "client_left": {"mac": MAC}, "credentials": {"ssid": "Home"},
            "join_progress": {"step": "dhcp"}, "rollback_ok": {}, "rollback_failed": {}, "join_failed": {"code": "x"},
            "verify_failed": {"code": "x"}, "probe_failed": {"code": "x"}, "ap_failed": {"code": "x"},
        }
        reach = {"idle": None, "probing": 0, "ap_up": 2, "client_joined": 4, "credentials_received": 5, "joining": 6, "verifying": 7}
        for state in jobs.STATES:
            for ev in jobs.EVENTS:
                if ev == "tick":
                    continue
                j = new_job()
                if state in reach:
                    if reach[state] is not None:
                        drive(j, reach[state])
                elif state == "rolling_back":
                    drive(j, 6)
                    j.apply("join_failed", code="x")
                elif state in jobs.TERMINAL:
                    drive(j, 2)
                    j.apply("cancel")
                    if state == "done":
                        j = drive(new_job(), 7)
                        j.apply("verify_ok")
                    elif state == "rolled_back":
                        j = drive(new_job(), 6)
                        j.apply("join_failed", code="x")
                        j.apply("rollback_ok")
                self.assertEqual(state, j.state, (state, ev))
                prev = j.state
                r = j.apply(ev, **data.get(ev, {}))
                allowed = jobs.TRANSITIONS.get((prev, ev))
                if allowed is None:
                    self.assertFalse(r.accepted, (prev, ev))
                    self.assertEqual(prev, j.state, (prev, ev))
                elif r.accepted:
                    self.assertIn(j.state, allowed, (prev, ev))

    def test_events_constant(self):
        self.assertIn("cancel", jobs.EVENTS)
        self.assertIn("tick", jobs.EVENTS)
        for (_state, ev) in jobs.TRANSITIONS:
            self.assertIn(ev, jobs.EVENTS)
        self.assertEqual(11, len(jobs.STATES))
        self.assertEqual(("done", "rolled_back", "failed"), jobs.TERMINAL)

    def test_cancel_is_defined_for_every_active_state(self):
        for state in jobs.STATES:
            if state in jobs.TERMINAL or state in ("idle", "rolling_back"):
                self.assertNotIn((state, "cancel"), jobs.TRANSITIONS, state)
            else:
                self.assertIn((state, "cancel"), jobs.TRANSITIONS, state)


class Snapshots(unittest.TestCase):
    def test_roundtrip_in_every_state(self):
        paths = {}
        for upto in range(8):
            paths[STATE_AFTER[upto] + str(upto)] = drive(new_job(), upto)
        j = drive(new_job(), 6)
        j.apply("join_failed", code="bad_psk")
        paths["rolling_back"] = j
        j = drive(new_job(), 7)
        j.apply("verify_ok")
        paths["done"] = j
        j = drive(new_job(), 2)
        j.apply("cancel")
        paths["failed"] = j
        for name, job in paths.items():
            snap = job.snapshot()
            text = json.dumps(snap)
            again = Job.restore(json.loads(text), job.clock)
            self.assertEqual(snap, again.snapshot(), name)
            self.assertEqual(job.state, again.state)

    def test_restore_on_a_different_clock_keeps_remaining_time(self):
        j = drive(new_job(), 2)
        j.clock.advance(100)
        snap = json.loads(json.dumps(j.snapshot()))
        c2 = ManualClock(5.0)                                           # a fresh boot: the monotonic clock starts over
        j2 = Job.restore(snap, c2)
        self.assertAlmostEqual(snap["deadline_in_s"], j2.snapshot()["deadline_in_s"], places=2)
        c2.advance(snap["deadline_in_s"] + 1)
        self.assertEqual("timeout", j2.tick().reason)

    def test_restored_job_continues(self):
        j = drive(new_job(), 4)
        j2 = Job.restore(json.loads(json.dumps(j.snapshot())), j.clock)
        self.assertTrue(j2.apply("credentials", ssid="HomeNet").accepted)
        self.assertEqual("credentials_received", j2.state)

    def test_restore_rejects_junk(self):
        for bad in (None, {}, {"v": 2, "state": "idle", "job_id": "x"}, {"v": 1, "state": "bogus", "job_id": "x"}, "x", []):
            with self.assertRaises(ValueError):
                Job.restore(bad)

    def test_snapshot_holds_no_secret_and_public_view_holds_no_ssid(self):
        j = drive(new_job(), 6)
        text = json.dumps(j.snapshot())
        for secret in ("psk", "password", "token", "pin"):
            self.assertNotIn('"%s"' % secret, text)
        pv = j.public_view()
        self.assertNotIn("HomeNet", json.dumps(pv))
        self.assertEqual({"state", "step", "error_code", "outcome", "needs_pin"}, set(pv))
        j2 = drive(new_job(), 3)
        self.assertTrue(j2.public_view()["needs_pin"])
        j2.apply("authenticated")
        self.assertFalse(j2.public_view()["needs_pin"])
        self.assertFalse(drive(new_job(), 6).public_view()["needs_pin"])

    def test_history_is_bounded(self):
        j = drive(new_job(config=jobs.JobConfig(history_limit=5)), 2)
        for _ in range(100):
            j.apply("client_associated", mac=MAC)
            j.apply("client_left", mac=MAC)
        self.assertEqual(5, len(j.snapshot()["history"]))


def stable(snap):
    """A snapshot without its time-relative fields (they move with the clock even when the machine does not)."""
    out = {k: v for k, v in snap.items() if k not in ("entered_ago_s", "history")}
    out["history"] = [{k: v for k, v in h.items() if k != "ago_s"} for h in snap["history"]]
    return out


class RandomSequences(unittest.TestCase):
    def test_invariants_under_random_events(self):
        rnd = random.Random(helpers.fuzz_seed())
        events = [e for e in jobs.EVENTS] + ["bogus"]
        datas = [{}, {"mac": MAC}, {"mac": MAC2}, {"code": "x"}, {"step": "dhcp"}, {"ssid": "Home"}, {"ssid": "Home", "security": "sae-only"},
                 {"reopen_ap": True}, {"phy": "phy0", "iface": "wlan0", "mode": "dedicated"}, {"psk": "x"}, {"junk": 1}, {"mac": "bad"}]
        valid = {
            "idle": [("start", {})],
            "probing": [("probe_ok", {"phy": "phy0", "iface": "wlan0", "mode": "dedicated"}), ("ap_started", {}),
                        ("probe_failed", {"code": "x"}), ("ap_failed", {})],
            "ap_up": [("client_associated", {"mac": MAC}), ("uplink_appeared", {})],
            "client_joined": [("client_associated", {"mac": MAC2}), ("client_left", {"mac": MAC}), ("authenticated", {}),
                              ("authenticated", {}), ("credentials", {"ssid": "Home"}), ("credentials", {"ssid": "Home"}),
                              ("uplink_appeared", {})],
            "credentials_received": [("join_started", {})],
            "joining": [("join_progress", {"step": "dhcp"}), ("join_ok", {}), ("join_ok", {}), ("join_failed", {"code": "x"})],
            "verifying": [("verify_ok", {}), ("verify_ok", {}), ("verify_failed", {"code": "x"})],
            "rolling_back": [("rollback_ok", {"reopen_ap": True}), ("rollback_ok", {}), ("rollback_failed", {})],
        }
        seen_states = set()
        n_runs = helpers.fuzz_n(20000) // 100 or 1
        for run in range(n_runs):
            clock = ManualClock(rnd.random() * 1e6)
            j = Job("%016x" % rnd.getrandbits(64), clock)
            terminal_snapshot = None
            for _ in range(rnd.randint(1, 60)):
                if rnd.random() < 0.7 and j.state in valid:
                    ev, kw = rnd.choice(valid[j.state])
                elif rnd.random() < 0.1:
                    ev, kw = "cancel", {}
                else:
                    ev, kw = rnd.choice(events), rnd.choice(datas)
                if rnd.random() < 0.08:
                    clock.advance(rnd.choice([0.5, 5, 40, 100, 1000, 3000]))
                before = j.state
                r = j.apply(ev, **kw)
                seen_states.add(j.state)
                self.assertIn(j.state, jobs.STATES)
                self.assertEqual(j.state, r.state)
                if before in jobs.TERMINAL:
                    self.assertEqual(before, j.state)
                    self.assertFalse(r.accepted)
                for e in r.effects:
                    self.assertIn(e["op"], ("probe", "start_ap", "publish_credentials", "begin_join", "verify", "rollback",
                                            "teardown", "reopen_ap", "finish"))
                    self.assertNotIn("psk", e)
                snap = j.snapshot()
                self.assertLessEqual(len(snap["history"]), 64)
                self.assertEqual(snap, Job.restore(json.loads(json.dumps(snap)), clock).snapshot())
                if j.terminal:
                    if terminal_snapshot is None:
                        terminal_snapshot = stable(snap)
                    else:
                        self.assertEqual(terminal_snapshot, stable(snap))
                elif r.accepted and ev not in ("tick", "bogus"):
                    pass
                if not j.terminal and j.state != "idle":
                    self.assertIsNotNone(j._deadline)
                else:
                    self.assertTrue(j.state == "idle" or j._deadline is None)
        # the generator must reach most of the machine, or the test proves little
        if n_runs >= 100:
            self.assertEqual(set(jobs.STATES), seen_states)


if __name__ == "__main__":
    unittest.main()
