"""Tests for ci_setup.replay: single use across a restart, damaged markers that stay consumed, the clock floor, purging by the
persisted floor, the bound, crash injection at every durable step, backend failures, the order of the backend calls, threads.

The guard is exercised directly (ids, expiries and clock readings are plain integers); test_statement.py goes through the verifier.
"""
import contextlib
import hashlib
import threading
import unittest

from ci_setup import replay
from ci_setup.replay import MemoryBackend, ReplayError, ReplayGuard, SimulatedCrash, StoreError

T = 1790000000
TTL = 600
SKEW = 120


def rid(n):
    return "%032x" % n


def digest(n):
    return hashlib.sha256(rid(n).encode("ascii")).hexdigest()


def name_of(n, expires_at):
    return "%012d-%s" % (expires_at, digest(n))


def claim(guard, n, expires_at=T + 300, now=T, ttl=TTL, skew=SKEW):
    return guard.claim(rid(n), expires_at, now, ttl, skew)


def code(fn, *args, **kw):
    """The code of the ReplayError fn raises, or 'ok'."""
    try:
        fn(*args, **kw)
    except ReplayError as exc:
        return exc.code
    return "ok"


def fresh(**kw):
    backend = MemoryBackend()
    return backend, ReplayGuard(backend, **kw)


class Recording(object):
    """Wraps a backend and records the calls the guard makes, in order."""

    def __init__(self, inner):
        self.inner = inner
        self.calls = []

    @contextlib.contextmanager
    def lock(self):
        self.calls.append("lock")
        try:
            with self.inner.lock():
                yield
        finally:
            self.calls.append("unlock")

    def check_safe(self):
        self.calls.append("check_safe")
        return self.inner.check_safe()

    def list_markers(self):
        self.calls.append("list_markers")
        return self.inner.list_markers()

    def create_marker(self, name):
        self.calls.append("create_marker")
        return self.inner.create_marker(name)

    def remove_marker(self, name):
        self.calls.append("remove_marker")
        return self.inner.remove_marker(name)

    def read_floor(self):
        self.calls.append("read_floor")
        return self.inner.read_floor()

    def write_floor(self, value):
        self.calls.append("write_floor")
        return self.inner.write_floor(value)


class Names(unittest.TestCase):
    def test_the_hash_is_sha256_of_the_request_id(self):
        self.assertEqual(hashlib.sha256(b"00112233445566778899aabbccddeeff").hexdigest(),
                         replay.request_hash("00112233445566778899aabbccddeeff"))

    def test_a_marker_name_has_the_expiry_in_twelve_digits_then_the_hash(self):
        self.assertEqual("000000000007-" + "ab" * 32, replay.marker_name(7, "ab" * 32))
        self.assertEqual("999999999999-" + "ab" * 32, replay.marker_name(999999999999, "ab" * 32))

    def test_the_expiry_is_read_back_only_from_a_well_formed_name(self):
        good = name_of(1, 1790000300)
        self.assertEqual(1790000300, replay.marker_expiry(good))
        self.assertEqual(0, replay.marker_expiry("000000000000-" + "0" * 64))
        for bad in ("", "README", good + "0", good[1:], good.replace("-", "_"), good.upper(), "x" + good[1:], "00000000000a-" + "0" * 64,
                    "000000000001-" + "0" * 63 + "G", "0000000000001-" + "0" * 64, None, 5, b"x", good.encode("ascii"),
                    "\U00000661" * 12 + "-" + "0" * 64):
            self.assertIsNone(replay.marker_expiry(bad), repr(bad))

    def test_floor_bytes_are_decimal_ascii_and_a_newline(self):
        self.assertEqual(b"0\n", replay.encode_floor(0))
        self.assertEqual(b"1790000000\n", replay.encode_floor(T))
        for value in (0, 1, 9, 10, T, 999999999999):
            self.assertEqual(value, replay.decode_floor(replay.encode_floor(value)))
        self.assertEqual(7, replay.decode_floor(bytearray(b"7\n")))

    def test_anything_else_is_a_damaged_floor(self):
        for raw in (b"", b"\n", b"0", b"01\n", b"-1\n", b"+1\n", b" 1\n", b"1 \n", b"1\n\n", b"1\r\n", b"\xd9\xa1\n", b"1.5\n",
                    b"12345678901234\n", b"garbage\n", b"1\x00\n", None, "1\n", 5):
            with self.assertRaises(StoreError, msg=repr(raw)):
                replay.decode_floor(raw)


class Claim(unittest.TestCase):
    def test_the_first_claim_creates_the_marker_and_raises_the_floor(self):
        backend, guard = fresh()
        name = claim(guard, 1)
        self.assertEqual(name_of(1, T + 300), name)
        self.assertEqual([name], backend.list_markers())
        self.assertEqual(replay.MARKER_BODY, backend.marker_body(name))
        self.assertEqual(T, guard.floor())

    def test_a_second_claim_is_replayed_and_a_restart_does_not_help(self):
        backend, guard = fresh()
        claim(guard, 1)
        self.assertEqual("replayed", code(claim, guard, 1))
        self.assertEqual("replayed", code(claim, ReplayGuard(backend), 1))
        self.assertEqual("replayed", code(claim, ReplayGuard(backend), 1, now=T + 5))

    def test_different_ids_are_independent(self):
        backend, guard = fresh()
        for n in range(30):
            claim(guard, n)
        self.assertEqual(30, len(backend.list_markers()))
        self.assertEqual(30, guard.marker_count())
        for n in range(30):
            self.assertEqual("replayed", code(claim, guard, n))

    def test_the_floor_only_goes_up(self):
        backend, guard = fresh()
        claim(guard, 1, now=T)
        claim(guard, 2, now=T - 100)        # behind the floor, within the skew: accepted, floor stays
        self.assertEqual(T, guard.floor())
        claim(guard, 3, now=T + 100, expires_at=T + 400)
        self.assertEqual(T + 100, guard.floor())
        claim(guard, 4, now=T + 100, expires_at=T + 400)    # equal to the floor: nothing to write
        self.assertEqual(["floor", "floor"], [s for s in backend.steps if s == "floor"])

    def test_arguments_that_make_no_sense_are_a_value_error(self):
        _, guard = fresh()
        good = dict(request_id=rid(1), expires_at=T + 300, now=T, max_ttl_s=TTL, skew_s=SKEW)
        guard.claim(**good)
        bad = [dict(request_id=rid(10).upper()), dict(request_id="x" * 32), dict(request_id=rid(1)[:-1]), dict(request_id=None),
               dict(request_id=b"0" * 32), dict(expires_at=-1), dict(expires_at=1000000000000), dict(expires_at=1.5),
               dict(expires_at=True), dict(now=-1), dict(now=None), dict(now=1000000000000), dict(max_ttl_s=-1),
               dict(max_ttl_s="600"), dict(skew_s=-1), dict(skew_s=1.0)]
        for over in bad:
            with self.assertRaises(ValueError, msg=repr(over)):
                guard.claim(**dict(good, **over))
        self.assertEqual(1, guard.marker_count())

    def test_a_lost_race_for_the_exact_name_is_replayed(self):
        """Another claimant creates the marker between the listing and the create: the exclusive create loses and the id is consumed."""

        class Racing(MemoryBackend):
            def list_markers(self):
                names = MemoryBackend.list_markers(self)
                self.put_marker(name_of(1, T + 300))
                return names

        backend = Racing()
        guard = ReplayGuard(backend)
        self.assertEqual("replayed", code(claim, guard, 1))
        self.assertEqual(0, backend.read_floor())

    def test_construction(self):
        self.assertEqual(4096, replay.MAX_MARKERS)
        self.assertEqual(4096, ReplayGuard(MemoryBackend()).max_markers)
        for bad in (0, -1, 4097, 1.5, "4096", None, True):
            with self.assertRaises(ValueError, msg=repr(bad)):
                ReplayGuard(MemoryBackend(), max_markers=bad)
        ReplayGuard(MemoryBackend(), max_markers=1)


class DamagedMarkers(unittest.TestCase):
    """A marker is found by the hash in its name. Whatever is wrong with it, it still means consumed."""

    BODIES = (b"", b"garbage", b"ci-repl", b"\x00" * 64, replay.MARKER_BODY[:5], replay.MARKER_BODY + b"more", b"\xff\xfe")

    def test_a_damaged_body_stays_consumed(self):
        for body in self.BODIES:
            for expiry in (T + 300, T + 299, 5):               # the claim's own name, and the same id under another expiry
                backend, guard = fresh()
                backend.put_marker(name_of(1, expiry), body)
                self.assertEqual("replayed", code(claim, guard, 1), (body, expiry))
                self.assertEqual(0, guard.floor())
                self.assertEqual([name_of(1, expiry)], backend.list_markers())

    def test_the_expiry_digits_do_not_matter(self):
        for prefix in ("000000000000", "000000000001", "999999999999", "zzzzzzzzzzzz", "0", "", "x" * 40):
            for body in (replay.MARKER_BODY, b""):
                backend, guard = fresh()
                backend.put_marker("%s-%s" % (prefix, digest(1)), body)
                self.assertEqual("replayed", code(claim, guard, 1), prefix)

    def test_a_name_without_the_dash_and_the_hash_is_not_a_marker_of_that_id(self):
        backend, guard = fresh()
        backend.put_marker("x" + digest(1))          # ends in the hash but not in "-<hash>"
        backend.put_marker("-" + digest(2)[:-1])
        backend.put_marker("README")
        claim(guard, 1)
        claim(guard, 2)
        self.assertEqual("replayed", code(claim, guard, 1))

    def test_the_same_id_with_another_expiry_is_replayed(self):
        backend, guard = fresh()
        claim(guard, 1, expires_at=T + 300)
        self.assertEqual("replayed", code(claim, guard, 1, expires_at=T + 400))
        self.assertEqual("replayed", code(claim, guard, 1, expires_at=T + 100))
        self.assertEqual("replayed", code(claim, guard, 1, expires_at=T + 300))
        self.assertEqual(1, guard.marker_count())

    def test_a_marker_that_a_crash_left_without_a_body_is_consumed(self):
        backend, guard = fresh()
        backend.fault = replay.crash_at("write")
        with self.assertRaises(SimulatedCrash):
            claim(guard, 1)
        self.assertEqual(b"", backend.marker_body(name_of(1, T + 300)))
        backend.fault = None
        self.assertEqual("replayed", code(claim, ReplayGuard(backend), 1))

    def test_the_decision_does_not_read_the_body(self):
        class NoRead(MemoryBackend):
            def marker_body(self, name):
                raise AssertionError("the body was read")

        backend = NoRead()
        backend.put_marker(name_of(1, T + 300), b"")
        self.assertEqual("replayed", code(claim, ReplayGuard(backend), 1))
        claim(ReplayGuard(backend), 2)


class Floor(unittest.TestCase):
    def setUp(self):
        self.backend, self.guard = fresh()
        claim(self.guard, 0, now=T)

    def test_a_clock_behind_the_floor_by_more_than_the_skew(self):
        for n, (behind, want) in enumerate(((0, "ok"), (1, "ok"), (SKEW - 1, "ok"), (SKEW, "ok"), (SKEW + 1, "clock"),
                                            (10 * SKEW, "clock"), (T, "clock")), start=1):
            now = T - behind
            self.assertEqual(want, code(claim, self.guard, n, expires_at=now + 300, now=now), behind)
        self.assertEqual(T, self.guard.floor())

    def test_the_skew_is_an_argument(self):
        self.assertEqual("ok", code(claim, self.guard, 1, now=T - 5, skew=5))
        self.assertEqual("clock", code(claim, self.guard, 2, now=T - 6, skew=5))
        self.assertEqual("ok", code(claim, self.guard, 3, now=T - 1000, skew=1000))
        self.assertEqual("clock", code(claim, self.guard, 4, now=T - 1, skew=0))

    def test_a_refusal_never_moves_the_floor(self):
        before = self.backend.steps[:]
        claim(self.guard, 1, now=T + 50, expires_at=T + 300)
        self.assertEqual(T + 50, self.guard.floor())
        steps = self.backend.steps[:]
        for later in (T + 60, T + 1000):
            self.assertEqual("replayed", code(claim, self.guard, 1, now=later, expires_at=later + 300))
        self.assertEqual("clock", code(claim, self.guard, 2, now=T - 100, expires_at=T + 300))
        self.assertEqual(steps, self.backend.steps)
        self.assertEqual(T + 50, self.guard.floor())
        self.assertNotEqual(before, steps)

    def test_a_damaged_floor_fails_closed(self):
        for raw in (b"", b"garbage", b"-5\n", b"1.5\n", b"12345678901234\n", b"\n"):
            backend, guard = fresh()
            backend.set_floor_raw(raw)
            self.assertEqual("store", code(claim, guard, 1), raw)
            self.assertEqual("store", code(guard.floor), raw)
            self.assertEqual([], backend.list_markers())

    def test_a_missing_floor_is_zero(self):
        backend, guard = fresh()
        self.assertEqual(0, guard.floor())
        self.assertEqual("ok", code(claim, guard, 1, now=0, expires_at=300))

    def test_the_floor_is_read_before_the_marker_list(self):
        backend = Recording(MemoryBackend())
        guard = ReplayGuard(backend)
        claim(guard, 1)
        self.assertLess(backend.calls.index("read_floor"), backend.calls.index("list_markers"))


class Purge(unittest.TestCase):
    """Markers go when expiry + skew + ttl < floor, by the persisted floor and never by the clock."""

    EXPIRY = T + 300
    LIMIT = EXPIRY + SKEW + TTL

    def run_with_floor(self, floor, now=None):
        backend, guard = fresh()
        backend.put_marker(name_of(9, self.EXPIRY))
        backend.set_floor_raw(replay.encode_floor(floor))
        claim(guard, 1, now=floor if now is None else now, expires_at=(floor if now is None else now) + 300)
        return backend

    def test_the_boundary(self):
        kept = self.run_with_floor(self.LIMIT)
        self.assertIn(name_of(9, self.EXPIRY), kept.list_markers())
        gone = self.run_with_floor(self.LIMIT + 1)
        self.assertNotIn(name_of(9, self.EXPIRY), gone.list_markers())
        self.assertEqual(1, len(gone.list_markers()))

    def test_the_policy_of_the_claim_decides_the_slack(self):
        backend, guard = fresh()
        backend.put_marker(name_of(9, 1000))
        backend.set_floor_raw(replay.encode_floor(2000))
        claim(guard, 1, now=2000, expires_at=2300, ttl=600, skew=120)             # 1000 + 720 < 2000: gone
        self.assertNotIn(name_of(9, 1000), backend.list_markers())
        backend, guard = fresh()
        backend.put_marker(name_of(9, 1000))
        backend.set_floor_raw(replay.encode_floor(2000))
        claim(guard, 1, now=2000, expires_at=2300, ttl=900, skew=120)             # 1000 + 1020 >= 2000: kept
        self.assertIn(name_of(9, 1000), backend.list_markers())

    def test_names_that_are_not_well_formed_are_never_purged(self):
        backend, guard = fresh()
        odd = ["README", "123-" + digest(8), "x" * 12 + "-" + digest(8), "000000000001-" + digest(8).upper(), "000000000001-" + "0" * 63]
        for name in odd:
            backend.put_marker(name)
        backend.set_floor_raw(replay.encode_floor(T))
        claim(guard, 1)
        for name in odd:
            self.assertIn(name, backend.list_markers())

    def test_the_decision_uses_the_persisted_floor_not_the_clock(self):
        """A clock far ahead, and a claim that dies before it is recorded: nothing may have been purged on the clock's word."""
        backend, guard = fresh()
        claim(guard, 1, now=T, expires_at=T + 300)
        self.assertEqual(T, guard.floor())
        backend.fault = replay.crash_at("create")
        far = self.LIMIT + 10 * TTL
        with self.assertRaises(SimulatedCrash):
            claim(guard, 2, now=far, expires_at=far + 300)
        backend.fault = None
        self.assertIn(name_of(1, T + 300), backend.list_markers())
        self.assertEqual(T, guard.floor())

    def test_a_jump_back_of_the_clock_cannot_bring_back_a_purged_statement(self):
        backend, guard = fresh()
        claim(guard, 1, now=T, expires_at=T + 300)
        later = T + 300 + SKEW + TTL + 1
        claim(guard, 2, now=later, expires_at=later + 300)             # raises the floor beyond the first statement's life
        claim(guard, 3, now=later + 1, expires_at=later + 301)         # the purge happens in this claim
        self.assertNotIn(name_of(1, T + 300), backend.list_markers())
        # the statement is gone from the store, and the clock goes back to when it was valid: the floor still refuses it
        for back in (T, T + 100, T + 299, later - 1000):
            self.assertEqual("clock", code(claim, guard, 1, now=back, expires_at=T + 300), back)
        self.assertEqual("ok", code(claim, guard, 4, now=later + 2, expires_at=later + 302))

    def test_a_refusal_before_the_purge_changes_nothing(self):
        backend, guard = fresh()
        backend.put_marker(name_of(9, 1000))
        backend.set_floor_raw(replay.encode_floor(T))
        claim(guard, 1)
        backend.put_marker(name_of(8, 1001))
        before = backend.list_markers()
        self.assertEqual("replayed", code(claim, guard, 1))
        self.assertEqual("clock", code(claim, guard, 2, now=T - 1000, expires_at=T - 700))
        self.assertEqual(before, backend.list_markers())

    def test_purging_makes_room(self):
        backend, guard = fresh(max_markers=4)
        for n in range(3):
            claim(guard, n, now=T, expires_at=T + 100 + n)
        later = T + 100 + 3 + SKEW + TTL + 1
        claim(guard, 3, now=later, expires_at=later + 300)             # accepted: the floor moves beyond the three old statements
        self.assertEqual(4, guard.marker_count())
        claim(guard, 4, now=later + 1, expires_at=later + 301)         # the purge happens in this claim
        self.assertEqual(2, guard.marker_count())
        self.assertEqual("replayed", code(claim, guard, 3, now=later + 1, expires_at=later + 301))

    def test_a_store_that_fills_inside_one_lifetime_cannot_make_room_by_waiting(self):
        """Known limit of the rules (a decision for the reviewer): the floor moves only when a statement is accepted and a marker
        is purged only by the floor, so a store filled with statements that were all accepted at about the same time stays full,
        however long the wall clock runs on, until a statement can be accepted."""
        backend, guard = fresh(max_markers=3)
        for n in range(3):
            claim(guard, n, now=T, expires_at=T + 100 + n)
        very_late = T + 10 ** 6
        self.assertEqual("store_full", code(claim, guard, 3, now=very_late, expires_at=very_late + 300))
        self.assertEqual(T, guard.floor())
        self.assertEqual(3, guard.marker_count())


class Bound(unittest.TestCase):
    def test_a_full_store_refuses_and_loses_nothing(self):
        backend, guard = fresh(max_markers=5)
        for n in range(5):
            claim(guard, n)
        before = backend.list_markers()
        self.assertEqual("store_full", code(claim, guard, 5))
        self.assertEqual("store_full", code(claim, guard, 6))
        self.assertEqual(before, backend.list_markers())
        self.assertEqual("replayed", code(claim, guard, 0), "the old ones are still known")

    def test_the_default_bound_is_4096_names(self):
        backend, guard = fresh()
        for n in range(4095):
            backend.put_marker(name_of(n, T + 300))
        self.assertEqual("ok", code(claim, guard, 5000))
        self.assertEqual(4096, guard.marker_count())
        self.assertEqual("store_full", code(claim, guard, 5001))
        self.assertEqual(4096, guard.marker_count())

    def test_names_that_are_not_markers_count_toward_the_bound(self):
        backend, guard = fresh(max_markers=3)
        for junk in ("a", "b", "c"):
            backend.put_marker(junk)
        self.assertEqual("store_full", code(claim, guard, 1))
        self.assertEqual(3, guard.marker_count())

    def test_the_bound_is_checked_after_the_purge(self):
        backend, guard = fresh(max_markers=2)
        backend.set_floor_raw(replay.encode_floor(T))
        backend.put_marker(name_of(8, 100))          # long gone
        backend.put_marker(name_of(9, 200))          # long gone
        self.assertEqual("ok", code(claim, guard, 1))
        self.assertEqual([name_of(1, T + 300)], backend.list_markers())


class Crashes(unittest.TestCase):
    def crash_at(self, step, skip=0):
        backend, guard = fresh()
        backend.fault = replay.crash_at(step, skip)
        with self.assertRaises(SimulatedCrash):
            claim(guard, 1)
        backend.fault = None
        return backend, ReplayGuard(backend)

    def test_success_goes_through_the_steps_in_this_order(self):
        backend, guard = fresh()
        claim(guard, 1)
        self.assertEqual(["create", "write", "fsync_file", "fsync_dir", "floor"], backend.steps)
        self.assertEqual(("create", "write", "fsync_file", "fsync_dir", "remove", "floor"), MemoryBackend.STEPS)

    def test_before_create_nothing_happened(self):
        backend, guard = self.crash_at("create")
        self.assertEqual([], backend.list_markers())
        self.assertEqual(0, guard.floor())
        self.assertEqual("ok", code(claim, guard, 1))

    def test_after_create_the_id_is_consumed_and_the_floor_is_not_raised(self):
        for step in ("write", "fsync_file", "fsync_dir", "floor"):
            backend, guard = self.crash_at(step)
            self.assertEqual([name_of(1, T + 300)], backend.list_markers(), step)
            self.assertEqual(0, guard.floor(), step)
            self.assertEqual("replayed", code(claim, guard, 1), step)

    def test_a_crash_leaves_the_lock_free(self):
        backend, guard = self.crash_at("fsync_file")
        self.assertEqual("ok", code(claim, guard, 2))

    def test_a_crash_in_the_purge_loses_no_live_marker(self):
        backend, guard = fresh()
        backend.set_floor_raw(replay.encode_floor(T))
        for n in range(4):
            backend.put_marker(name_of(100 + n, 50 + n))             # all long gone
        live = name_of(7, T + 200)
        backend.put_marker(live)
        backend.fault = replay.crash_at("remove", skip=1)
        with self.assertRaises(SimulatedCrash):
            claim(guard, 1)
        backend.fault = None
        names = backend.list_markers()
        self.assertIn(live, names)
        self.assertEqual(4, len(names))                                # one old marker removed, three left, plus the live one
        self.assertEqual("ok", code(claim, ReplayGuard(backend), 1))   # the claim itself was never made


class BackendFailures(unittest.TestCase):
    METHODS = ("check_safe", "list_markers", "create_marker", "remove_marker", "read_floor", "write_floor")

    def failing(self, method, error):
        class Failing(MemoryBackend):
            pass

        def boom(self, *args, **kw):
            raise error

        setattr(Failing, method, boom)
        backend = Failing()
        backend.put_marker(name_of(9, 100))
        backend.set_floor_raw(replay.encode_floor(T - 1000))      # the old marker is purged and the floor is raised
        return backend, ReplayGuard(backend)

    def test_any_failure_of_the_backend_is_a_store_error(self):
        for method in self.METHODS:
            for error in (OSError("disk full: /secret/path"), StoreError("unsafe"), RuntimeError("bug"), MemoryError(), KeyError("k")):
                backend, guard = self.failing(method, error)
                self.assertEqual("store", code(claim, guard, 1), (method, error))

    def test_the_error_text_is_constant(self):
        backend, guard = self.failing("create_marker", OSError("disk full: /secret/path/" + digest(1)))
        with self.assertRaises(ReplayError) as ctx:
            claim(guard, 1)
        text = str(ctx.exception) + repr(ctx.exception) + str(ctx.exception.__cause__)
        self.assertEqual("replay: store", str(ctx.exception))
        self.assertIsNone(ctx.exception.__cause__)
        self.assertTrue(ctx.exception.__suppress_context__, "the backend's own text is not shown with the error")
        for secret in ("secret", digest(1), rid(1)):
            self.assertNotIn(secret, text)

    def test_an_unsafe_store_is_refused_before_anything_else_is_touched(self):
        backend = Recording(MemoryBackend())
        guard = ReplayGuard(backend)
        backend.inner.safe = False
        self.assertEqual("store", code(claim, guard, 1))
        self.assertEqual(["lock", "check_safe", "unlock"], backend.calls)

    def test_odd_answers_from_a_backend_are_a_store_error(self):
        for method, answer in (("read_floor", "5"), ("read_floor", -1), ("read_floor", True), ("read_floor", 1.5),
                               ("read_floor", 1000000000000), ("list_markers", ("a",)), ("list_markers", [b"a"]),
                               ("list_markers", None), ("list_markers", "ab")):
            class Odd(MemoryBackend):
                pass

            setattr(Odd, method, lambda self, _a=answer: _a)
            self.assertEqual("store", code(claim, ReplayGuard(Odd()), 1), (method, answer))

    def test_the_lock_is_released_after_every_failure(self):
        backend, guard = self.failing("write_floor", OSError("x"))
        self.assertEqual("store", code(claim, guard, 1))
        self.assertTrue(backend.lock().acquire(False))
        backend.lock().release()

    def test_a_lock_that_cannot_be_taken_is_a_store_error(self):
        class NoLock(MemoryBackend):
            def lock(self):
                raise OSError("cannot lock")

        self.assertEqual("store", code(claim, ReplayGuard(NoLock()), 1))
        self.assertEqual("store", code(ReplayGuard(NoLock()).floor))
        self.assertEqual("store", code(ReplayGuard(NoLock()).marker_count))

    def test_the_simulated_crash_is_not_a_store_error(self):
        self.assertTrue(issubclass(SimulatedCrash, BaseException))
        self.assertFalse(issubclass(SimulatedCrash, Exception))


class Order(unittest.TestCase):
    def test_the_calls_of_a_successful_claim(self):
        backend = Recording(MemoryBackend())
        claim(ReplayGuard(backend), 1)
        self.assertEqual(["lock", "check_safe", "read_floor", "list_markers", "create_marker", "write_floor", "unlock"], backend.calls)

    def test_the_floor_is_written_only_after_the_marker_is_durable(self):
        steps = []

        class Logging(MemoryBackend):
            def _step(self, step):
                steps.append(step)
                MemoryBackend._step(self, step)

        claim(ReplayGuard(Logging()), 1)
        self.assertEqual(["create", "write", "fsync_file", "fsync_dir", "floor"], steps)

    def test_a_replayed_claim_creates_and_writes_nothing(self):
        backend = Recording(MemoryBackend())
        guard = ReplayGuard(backend)
        claim(guard, 1)
        backend.calls[:] = []
        self.assertEqual("replayed", code(claim, guard, 1))
        self.assertEqual(["lock", "check_safe", "read_floor", "list_markers", "unlock"], backend.calls)

    def test_a_clock_refusal_does_not_even_list_the_markers(self):
        backend = Recording(MemoryBackend())
        guard = ReplayGuard(backend)
        claim(guard, 1)
        backend.calls[:] = []
        self.assertEqual("clock", code(claim, guard, 2, now=T - 1000, expires_at=T - 700))
        self.assertEqual(["lock", "check_safe", "read_floor", "unlock"], backend.calls)


class Threads(unittest.TestCase):
    def test_sixteen_threads_claim_one_id_and_exactly_one_wins(self):
        backend, guard = fresh()
        barrier = threading.Barrier(16, timeout=60)
        results = []

        def work():
            barrier.wait()
            results.append(code(claim, guard, 1))

        threads = [threading.Thread(target=work) for _ in range(16)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(60)
        self.assertEqual(1, results.count("ok"))
        self.assertEqual(15, results.count("replayed"))
        self.assertEqual(1, guard.marker_count())

    def test_threads_with_different_ids_all_win(self):
        backend, guard = fresh()
        barrier = threading.Barrier(16, timeout=60)
        results = []

        def work(n):
            barrier.wait()
            results.append(code(claim, guard, n))

        threads = [threading.Thread(target=work, args=(n,)) for n in range(16)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(60)
        self.assertEqual(["ok"] * 16, results)
        self.assertEqual(16, guard.marker_count())

    def test_two_guards_over_one_backend_share_the_lock(self):
        backend = MemoryBackend()
        guards = [ReplayGuard(backend), ReplayGuard(backend)]
        results = []
        barrier = threading.Barrier(8, timeout=60)

        def work(i):
            barrier.wait()
            results.append(code(claim, guards[i % 2], 1))

        threads = [threading.Thread(target=work, args=(i,)) for i in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(60)
        self.assertEqual(1, results.count("ok"))


class MemoryBackendItself(unittest.TestCase):
    def test_the_fault_hook_sees_each_step_before_it_takes_effect(self):
        seen = []

        def hook(step):
            seen.append((step, MemoryBackend.list_markers(backend)))

        backend = MemoryBackend(fault=hook)
        backend.create_marker("m")
        self.assertEqual([("create", []), ("write", ["m"]), ("fsync_file", ["m"]), ("fsync_dir", ["m"])], seen)
        self.assertEqual(["create", "write", "fsync_file", "fsync_dir"], backend.steps)

    def test_crash_at_counts_occurrences(self):
        hook = replay.crash_at("create", skip=2)
        hook("create")
        hook("write")
        hook("create")
        with self.assertRaises(SimulatedCrash):
            hook("create")

    def test_create_is_exclusive_and_remove_is_forgiving(self):
        backend = MemoryBackend()
        backend.create_marker("m")
        with self.assertRaises(replay.MarkerExists):
            backend.create_marker("m")
        backend.remove_marker("m")
        backend.remove_marker("m")
        self.assertEqual([], backend.list_markers())

    def test_the_listing_is_a_copy(self):
        backend = MemoryBackend()
        backend.create_marker("m")
        backend.list_markers().append("x")
        self.assertEqual(["m"], backend.list_markers())

    def test_the_floor_goes_through_its_file_format(self):
        backend = MemoryBackend()
        self.assertEqual(0, backend.read_floor())
        backend.write_floor(T)
        self.assertEqual(b"1790000000\n", backend._floor_raw)
        self.assertEqual(T, backend.read_floor())


if __name__ == "__main__":
    unittest.main()
