"""Tests for ci_setup.auth: key and PIN generation, derivation from a setup key, tokens, guess limiting, the PIN gate."""
import hashlib
import hmac
import json
import math
import random
import threading
import unittest
from unittest import mock

import helpers
from ci_setup import auth
from ci_setup.clock import ManualClock
from ci_setup.errors import ValidationError

IP = "192.168.99.10"
IP2 = "192.168.99.11"


class Generation(unittest.TestCase):
    def test_alphabet(self):
        a = auth.AP_KEY_ALPHABET
        self.assertEqual(31, len(a))
        self.assertEqual(len(a), len(set(a)))
        for ch in "ILO01":
            self.assertNotIn(ch, a)
        self.assertTrue(all(c in "ABCDEFGHJKMNPQRSTUVWXYZ23456789" for c in a))
        self.assertTrue(all(c.isascii() and (c.isupper() or c.isdigit()) for c in a))
        self.assertAlmostEqual(auth.AP_KEY_BITS, auth.AP_KEY_LEN * math.log2(len(a)), places=1)
        self.assertGreater(auth.AP_KEY_BITS, 59)
        # nothing in the alphabet needs escaping in the Wi-Fi QR string or in a config file
        for ch in '\\;,":# =':
            self.assertNotIn(ch, a)

    def test_key_uses_randbelow_31_twelve_times(self):
        rng = helpers.ScriptedRng(list(range(12)))
        key = auth.generate_ap_key(rng)
        self.assertEqual(auth.AP_KEY_ALPHABET[:12], key)
        self.assertEqual([31] * 12, rng.calls)
        rng = helpers.ScriptedRng([30] * 12)
        self.assertEqual(auth.AP_KEY_ALPHABET[30] * 12, auth.generate_ap_key(rng))

    def test_pin_uses_randbelow_10_six_times_and_keeps_leading_zeros(self):
        rng = helpers.ScriptedRng([0, 0, 0, 0, 1, 2])
        self.assertEqual("000012", auth.generate_pin(rng))
        self.assertEqual([10] * 6, rng.calls)
        self.assertEqual("999999", auth.generate_pin(helpers.ScriptedRng([9] * 6)))

    def test_default_source_is_the_secrets_module(self):
        with mock.patch.object(auth.secrets, "randbelow", side_effect=lambda n: n - 1) as rb:
            self.assertEqual(auth.AP_KEY_ALPHABET[-1] * 12, auth.generate_ap_key())
            self.assertEqual("999999", auth.generate_pin())
            self.assertEqual(12 + 6, rb.call_count)
        with mock.patch.object(auth.secrets, "token_bytes", return_value=b"\x07" * 32) as tb:
            issuer = auth.TokenIssuer.new_session(ManualClock())
            tb.assert_called_with(32)
            self.assertEqual(b"\x07" * 32, issuer._key)

    def test_distribution_is_flat(self):
        rng = helpers.SeededRng(11)
        counts = {c: 0 for c in auth.AP_KEY_ALPHABET}
        keys = set()
        n = 4000
        for _ in range(n):
            k = auth.generate_ap_key(rng)
            keys.add(k)
            self.assertTrue(auth.is_valid_ap_key(k))
            for c in k:
                counts[c] += 1
        expected = n * auth.AP_KEY_LEN / 31.0
        for c, got in counts.items():
            self.assertLess(abs(got - expected), expected * 0.15, (c, got, expected))
        self.assertEqual(n, len(keys))
        pin_digits = {d: 0 for d in "0123456789"}
        for _ in range(n):
            for d in auth.generate_pin(rng):
                pin_digits[d] += 1
        for d, got in pin_digits.items():
            self.assertLess(abs(got - n * 6 / 10.0), n * 6 / 10.0 * 0.1, d)

    def test_real_generation_smoke(self):
        keys = {auth.generate_ap_key() for _ in range(200)}
        self.assertEqual(200, len(keys))
        for k in keys:
            self.assertTrue(auth.is_valid_ap_key(k))
        for _ in range(50):
            p = auth.generate_pin()
            self.assertEqual(6, len(p))
            self.assertTrue(all(c in "0123456789" for c in p))

    def test_is_valid_ap_key(self):
        self.assertTrue(auth.is_valid_ap_key("ABCDEFGHJKMN"))
        for bad in ("ABCDEFGHJKM", "ABCDEFGHJKMNP", "ABCDEFGHJKMO", "abcdefghjkmn", "ABCDEFGHJKM0", None, 5):
            self.assertFalse(auth.is_valid_ap_key(bad), bad)


class SetupKey(unittest.TestCase):
    def test_generate_and_format(self):
        k = auth.generate_setup_key(helpers.ScriptedRng(list(range(16))))
        self.assertEqual(auth.AP_KEY_ALPHABET[:16], k)
        self.assertEqual("ABCD-EFGH-JKMN-PQRS", auth.format_setup_key(k))
        self.assertEqual(16, len(auth.generate_setup_key()))

    def test_normalize(self):
        want = "ABCDEFGHJKMNPQRS"
        for text in ("ABCD-EFGH-JKMN-PQRS", "abcd efgh jkmn pqrs", " ABCDEFGHJKMNPQRS ", "abcd-EFGH-jkmn-PQRS", "AB CD-EF GH-JK MN-PQ RS"):
            self.assertEqual(want, auth.normalize_setup_key(text))
        for bad in ("", "ABCD-EFGH-JKMN-PQR", "ABCD-EFGH-JKMN-PQRSA", "ABCD-EFGH-JKMN-PQR0", "ABCD-EFGH-JKMN-PQRI",
                    "ABCD-EFGH-JKMN-PQRL", "ABCD-EFGH-JKMN-PQRO", "ABCD-EFGH-JKMN-PQR1", "x" * 100, None, 5, "ABCD-EFGH-JKMN-PQR\U000000c9"):
            with self.assertRaises(ValidationError):
                auth.normalize_setup_key(bad)


class Derivation(unittest.TestCase):
    KEY = "ABCD-EFGH-JKMN-PQRS"

    @staticmethod
    def reference(setup_key, label, alphabet, n):
        """Independent restatement: HMAC-SHA256(key, label || 0x00 || counter) blocks, rejection sampling."""
        size = len(alphabet)
        limit = 256 - 256 % size
        out = []
        counter = 0
        while len(out) < n:
            block = hmac.new(setup_key.encode(), label + b"\x00" + counter.to_bytes(4, "big"), hashlib.sha256).digest()
            counter += 1
            for b in block:
                if b < limit and len(out) < n:
                    out.append(alphabet[b % size])
        return "".join(out)

    def test_matches_the_reference_construction(self):
        c = auth.derive_credentials(self.KEY)
        k = "ABCDEFGHJKMNPQRS"
        self.assertEqual(self.reference(k, b"ci-setup/ap-key", auth.AP_KEY_ALPHABET, 12), c.ap_key)
        self.assertEqual(self.reference(k, b"ci-setup/pin", "0123456789", 6), c.pin)
        self.assertEqual(self.reference(k, b"ci-setup/ssid-suffix", auth.AP_KEY_ALPHABET, 4), c.ssid_suffix)

    def test_known_answer_pins_the_construction(self):
        # Changing the label, the expansion or the mapping changes every printed label ever made: fail loudly.
        c = auth.derive_credentials(self.KEY)
        self.assertEqual(("XRM8FPK3U7SB", "737933", "6XRV"), (c.ap_key, c.pin, c.ssid_suffix))

    def test_shapes_and_determinism(self):
        c = auth.derive_credentials(self.KEY)
        self.assertTrue(auth.is_valid_ap_key(c.ap_key))
        self.assertEqual(6, len(c.pin))
        self.assertEqual(4, len(c.ssid_suffix))
        self.assertEqual(c, auth.derive_credentials("abcdefghjkmnpqrs"))
        self.assertNotEqual(c, auth.derive_credentials("ABCD-EFGH-JKMN-PQRT"))
        self.assertNotEqual(c.ap_key, auth.derive_credentials("BBCD-EFGH-JKMN-PQRS").ap_key)

    def test_different_keys_different_credentials(self):
        rng = helpers.SeededRng(5)
        seen = set()
        for _ in range(300):
            k = auth.generate_setup_key(rng)
            c = auth.derive_credentials(k)
            seen.add(c.ap_key)
            self.assertTrue(auth.is_valid_ap_key(c.ap_key))
        self.assertEqual(300, len(seen))

    def test_mapping_has_no_modulo_bias(self):
        every_byte = [bytes(range(256))]
        out = auth._stream_symbols(iter(every_byte), auth.AP_KEY_ALPHABET, 248)         # bytes 0..247 are accepted
        for sym in auth.AP_KEY_ALPHABET:
            self.assertEqual(8, out.count(sym), sym)
        out = auth._stream_symbols(iter(every_byte), "0123456789", 250)                 # bytes 0..249
        for d in "0123456789":
            self.assertEqual(25, out.count(d), d)
        # bytes at or above the limit are skipped, not folded
        self.assertEqual("A", auth._stream_symbols(iter([bytes([255, 248, 0])]), auth.AP_KEY_ALPHABET, 1))
        with self.assertRaises(ValueError):
            auth._stream_symbols(iter([bytes([250, 251])]), auth.AP_KEY_ALPHABET, 1)


class Consteq(unittest.TestCase):
    def test_semantics(self):
        self.assertTrue(auth.consteq("abc", "abc"))
        self.assertTrue(auth.consteq(b"abc", "abc"))
        self.assertTrue(auth.consteq("caf\U000000e9", "caf\U000000e9"))
        self.assertFalse(auth.consteq("abc", "abd"))
        self.assertFalse(auth.consteq("abc", "abcd"))
        self.assertFalse(auth.consteq("", "a"))
        self.assertTrue(auth.consteq("", ""))
        for odd in (None, 5, 1.5, [], ("a",), object()):
            self.assertFalse(auth.consteq(odd, "a"))
            self.assertFalse(auth.consteq("a", odd))
        self.assertFalse(auth.consteq("\ud800", "x"))                    # not encodable: simply not equal, no exception
        self.assertFalse(auth.consteq("x", "\ud800"))

    def test_goes_through_compare_digest(self):
        with mock.patch.object(auth.hmac, "compare_digest", wraps=hmac.compare_digest) as cd:
            auth.consteq("a", "a")
            self.assertEqual(1, cd.call_count)
            (a, b), _ = cd.call_args
            self.assertIsInstance(a, bytes)
            self.assertIsInstance(b, bytes)

    def test_token_and_pin_checks_use_it(self):
        clock = ManualClock()
        gate = auth.PinGate(clock=clock, pin="123456")
        with mock.patch.object(auth.hmac, "compare_digest", wraps=hmac.compare_digest) as cd:
            res = gate.attempt(IP, "123456")
            pin_calls = cd.call_count
            self.assertGreaterEqual(pin_calls, 1)
            gate.issuer.verify(res.token, IP)
            self.assertGreater(cd.call_count, pin_calls)


class Tokens(unittest.TestCase):
    def setUp(self):
        self.clock = ManualClock(500.0)
        self.iss = auth.TokenIssuer(b"k" * 32, self.clock, ttl_s=900, max_lifetime_s=2700, rng=helpers.SeededRng(3))

    def test_roundtrip_and_shape(self):
        t = self.iss.issue(IP)
        parts = t.split(".")
        self.assertEqual(5, len(parts))
        self.assertEqual("v1", parts[0])
        self.assertEqual(32, len(parts[1]))
        self.assertEqual(64, len(parts[4]))
        self.assertLessEqual(len(t), auth.TokenIssuer.MAX_TOKEN_LEN)
        info = self.iss.verify(t, IP)
        self.assertEqual((IP, 500.0, 1400.0, 900.0), (info.client, info.issued_s, info.expires_s, info.remaining_s))
        self.assertNotIn(("k" * 32).encode().hex(), t)

    def test_unique_tokens(self):
        self.assertEqual(500, len({self.iss.issue(IP) for _ in range(500)}))

    def test_bound_to_the_client_address(self):
        t = self.iss.issue(IP)
        self.assertIsNotNone(self.iss.verify(t, IP))
        self.assertIsNone(self.iss.verify(t, IP2))
        self.assertIsNone(self.iss.verify(t, ""))
        self.assertIsNone(self.iss.verify(t, IP + " "))

    def test_every_field_is_protected(self):
        t = self.iss.issue(IP)
        parts = t.split(".")
        for i in range(1, 5):
            for repl in ("0", "f", "1"):
                bad = list(parts)
                bad[i] = (bad[i][:-1] + (repl if bad[i][-1] != repl else "2")) if i != 3 else str(int(bad[i]) + 60000)
                self.assertIsNone(self.iss.verify(".".join(bad), IP), (i, repl))
        bad = list(parts)
        bad[3] = str(int(parts[3]) + 10**6)                              # extend the lifetime by 1000 s
        self.assertIsNone(self.iss.verify(".".join(bad), IP))
        bad = list(parts)
        bad[2] = str(int(parts[2]) - 5000)
        self.assertIsNone(self.iss.verify(".".join(bad), IP))
        flip = parts[4][:-1] + ("0" if parts[4][-1] != "0" else "1")
        self.assertIsNone(self.iss.verify(".".join(parts[:4] + [flip]), IP))

    def test_other_session_key_rejects(self):
        other = auth.TokenIssuer(b"j" * 32, self.clock)
        self.assertIsNone(other.verify(self.iss.issue(IP), IP))

    def test_expiry_boundary(self):
        t = self.iss.issue(IP)
        self.clock.advance(899.0)
        self.assertIsNotNone(self.iss.verify(t, IP))
        self.clock.advance(0.9)
        self.assertIsNotNone(self.iss.verify(t, IP))
        self.clock.advance(0.2)
        self.assertIsNone(self.iss.verify(t, IP))
        self.clock.advance(100000)
        self.assertIsNone(self.iss.verify(t, IP))

    def test_sliding_refresh_and_absolute_cap(self):
        t = self.iss.issue(IP)
        for _ in range(2):
            self.clock.advance(800)
            t = self.iss.refresh(t, IP)
            self.assertIsNotNone(t)
            self.assertIsNotNone(self.iss.verify(t, IP))
        # 1600 s elapsed; a third refresh would end at 2500 s, inside the 2700 s cap: fine
        self.clock.advance(800)
        t = self.iss.refresh(t, IP)
        info = self.iss.verify(t, IP)
        self.assertEqual(500.0 + 2700.0, info.expires_s)                 # capped at issued + max lifetime, not +900
        self.clock.advance(300)
        self.assertIsNone(self.iss.refresh(t, IP))                       # 2400 + 300: the cap has passed
        self.assertIsNone(self.iss.verify(t, IP))

    def test_refresh_requires_a_valid_token(self):
        t = self.iss.issue(IP)
        self.assertIsNone(self.iss.refresh(t, IP2))
        self.assertIsNone(self.iss.refresh("junk", IP))
        self.clock.advance(901)
        self.assertIsNone(self.iss.refresh(t, IP))

    def test_revocation(self):
        t = self.iss.issue(IP)
        refreshed = self.iss.refresh(t, IP)
        self.assertTrue(self.iss.revoke(t, IP))
        self.assertIsNone(self.iss.verify(t, IP))
        self.assertIsNone(self.iss.verify(refreshed, IP))                # same session id
        self.assertFalse(self.iss.revoke(t, IP))                         # already revoked
        self.assertFalse(self.iss.revoke("junk", IP))
        other = self.iss.issue(IP)
        self.assertIsNotNone(self.iss.verify(other, IP))

    def test_garbage_never_raises_and_is_never_accepted(self):
        rnd = random.Random(helpers.fuzz_seed())
        good = self.iss.issue(IP)
        pieces = ["v1", "v2", "", "0", "f" * 32, "f" * 64, "9" * 15, "9" * 16, "-1", "x", good, "\U000000e9", "\ud800", "."]
        for _ in range(helpers.fuzz_n(20000) // 4 or 1):
            if rnd.random() < 0.5:
                tok = ".".join(rnd.choice(pieces) for _ in range(rnd.randint(0, 7)))
            else:
                tok = helpers.rand_text(rnd, 80)
            if tok != good:                                   # a join of the pieces can be the real token itself
                self.assertIsNone(self.iss.verify(tok, IP), tok)
        for bad in (None, 5, b"v1", [], {}):
            self.assertIsNone(self.iss.verify(bad, IP))
        self.assertIsNone(self.iss.verify(good + "A" * 500, IP))
        self.assertIsNone(self.iss.verify(good.upper(), IP))
        self.assertIsNone(self.iss.verify(" " + good, IP))

    def test_short_key_is_refused(self):
        for key in (b"", b"short", "string-key-not-bytes-0123456789", None):
            with self.assertRaises(ValueError):
                auth.TokenIssuer(key)

    def test_time_comes_from_the_injected_clock_only(self):
        with mock.patch("time.monotonic", side_effect=AssertionError("real clock used")), \
                mock.patch("time.time", side_effect=AssertionError("wall clock used")):
            iss = auth.TokenIssuer(b"k" * 32, self.clock)
            t = iss.issue(IP)
            self.assertIsNotNone(iss.verify(t, IP))


class Limiter(unittest.TestCase):
    def setUp(self):
        self.clock = ManualClock(0.0)
        self.lim = auth.AttemptLimiter(self.clock)

    def test_back_off_then_lockout(self):
        self.assertTrue(self.lim.check(IP).allowed)
        out = self.lim.record_failure(IP)
        self.assertEqual((False, False, 1.0), (out.rotate_pin, out.locked, out.retry_after_s))
        v = self.lim.check(IP)
        self.assertEqual((False, "backoff"), (v.allowed, v.reason))
        self.assertAlmostEqual(1.0, v.retry_after_s)
        self.clock.advance(0.5)
        self.assertAlmostEqual(0.5, self.lim.check(IP).retry_after_s)
        self.clock.advance(0.5)
        self.assertTrue(self.lim.check(IP).allowed)
        out = self.lim.record_failure(IP)
        self.assertEqual(2.0, out.retry_after_s)                          # doubles
        self.clock.advance(2.0)
        out = self.lim.record_failure(IP)                                 # third failure from one client
        self.assertTrue(out.locked)
        self.assertEqual(300.0, out.retry_after_s)
        v = self.lim.check(IP)
        self.assertEqual((False, "locked"), (v.allowed, v.reason))
        self.clock.advance(299.0)
        self.assertFalse(self.lim.check(IP).allowed)
        self.clock.advance(1.5)
        self.assertTrue(self.lim.check(IP).allowed)
        # failures start from zero after a lockout
        out = self.lim.record_failure(IP)
        self.assertFalse(out.locked)
        self.assertEqual(1.0, out.retry_after_s)

    def test_back_off_is_capped(self):
        lim = auth.AttemptLimiter(self.clock, auth.LimiterPolicy(max_failures_per_client=100, max_failures_global=1000))
        waits = []
        for _ in range(12):
            waits.append(lim.record_failure(IP).retry_after_s)
            self.clock.advance(100)
        self.assertEqual([1, 2, 4, 8, 16, 30, 30, 30, 30, 30, 30, 30], waits)

    def test_other_clients_are_not_affected(self):
        self.lim.record_failure(IP)
        self.assertTrue(self.lim.check(IP2).allowed)

    def test_global_failures_rotate_the_pin(self):
        rotated = []
        for i in range(5):
            rotated.append(self.lim.record_failure("10.0.0.%d" % i).rotate_pin)
        self.assertEqual([False] * 4 + [True], rotated)
        self.assertEqual(1, self.lim.rotations)
        self.assertEqual(0, self.lim.snapshot()["global_failures"])
        for i in range(4):
            self.assertFalse(self.lim.record_failure("10.0.1.%d" % i).rotate_pin)
        self.assertTrue(self.lim.record_failure("10.0.1.9").rotate_pin)

    def test_success_clears_the_client_and_the_global_count(self):
        self.lim.record_failure(IP)
        self.lim.record_failure(IP2)
        self.lim.record_success(IP)
        self.assertTrue(self.lim.check(IP).allowed)
        self.assertEqual(0, self.lim.snapshot()["global_failures"])

    def test_old_failures_are_forgotten(self):
        self.lim.record_failure(IP)
        self.clock.advance(901)
        self.lim.check(IP)
        self.assertEqual(0, self.lim.snapshot()["clients_tracked"])
        self.assertEqual(0, self.lim.snapshot()["global_failures"])

    def test_state_is_bounded(self):
        for i in range(500):
            self.lim.record_failure("10.%d.%d.1" % (i // 250, i % 250))
            self.clock.advance(0.001)
            self.assertLessEqual(self.lim.snapshot()["clients_tracked"], 64)

    def test_snapshot_has_no_addresses(self):
        self.lim.record_failure("10.9.8.7")
        text = json.dumps(self.lim.snapshot())
        self.assertNotIn("10.9.8.7", text)
        self.assertEqual({"clients_tracked", "clients_locked", "global_failures", "rotations"}, set(self.lim.snapshot()))

    def test_lock_counts_in_snapshot(self):
        for _ in range(3):
            self.lim.record_failure(IP)
            self.clock.advance(30)
        self.assertEqual(1, self.lim.snapshot()["clients_locked"])


class Gate(unittest.TestCase):
    def setUp(self):
        self.clock = ManualClock(0.0)
        self.rng = helpers.SeededRng(9)
        self.gate = auth.PinGate(clock=self.clock, rng=self.rng, pin="482913")

    def test_right_pin_gives_a_token_bound_to_the_client(self):
        res = self.gate.attempt(IP, "482913")
        self.assertEqual("ok", res.status)
        self.assertIsNotNone(self.gate.issuer.verify(res.token, IP))
        self.assertIsNone(self.gate.issuer.verify(res.token, IP2))

    def test_wrong_pins(self):
        for guess in ("000000", "48291", "4829133", "48291a", "", None, 482913, "482913 ", "\U00000664\U00000668\U00000662\U00000669\U00000661\U00000663"):
            gate = auth.PinGate(clock=ManualClock(), rng=helpers.SeededRng(1), pin="482913")
            res = gate.attempt(IP, guess)
            self.assertEqual("wrong", res.status, guess)
            self.assertIsNone(res.token)

    def test_pin_never_in_results(self):
        res = self.gate.attempt(IP, "111111")
        self.assertNotIn("482913", json.dumps(res.to_dict()))
        ok = self.gate.attempt(IP2, "482913")
        self.assertNotIn(ok.token, json.dumps(ok.to_dict()))
        self.assertEqual("<redacted>", ok.to_dict()["token"])

    def test_back_off_and_lockout_apply_before_the_pin_is_looked_at(self):
        self.assertEqual("wrong", self.gate.attempt(IP, "000000").status)
        self.assertEqual("backoff", self.gate.attempt(IP, "482913").status)       # even the right PIN waits
        self.clock.advance(1.1)
        self.assertEqual("wrong", self.gate.attempt(IP, "000001").status)
        self.clock.advance(2.1)
        self.assertEqual("locked", self.gate.attempt(IP, "000002").status)
        self.clock.advance(100)
        self.assertEqual("locked", self.gate.attempt(IP, "482913").status)        # still locked: right PIN refused
        self.clock.advance(250)
        self.assertEqual("ok", self.gate.attempt(IP, "482913").status)

    def test_pin_rotates_after_five_failures_overall(self):
        statuses = []
        for i in range(5):
            statuses.append(self.gate.attempt("10.0.0.%d" % i, "000000"))
        self.assertEqual(["wrong"] * 4 + ["rotated"], [s.status for s in statuses])
        self.assertTrue(statuses[-1].pin_rotated)
        self.assertEqual(2, self.gate.pin_generation)
        self.assertNotEqual("482913", self.gate.current_pin())
        self.assertEqual("wrong", self.gate.attempt("10.0.0.99", "482913").status)    # the old PIN is dead

    def test_pin_expires(self):
        self.clock.advance(599)
        self.assertEqual("wrong", self.gate.attempt(IP, "000000").status)
        self.clock.advance(1)
        res = self.gate.attempt(IP2, "482913")
        self.assertEqual(("expired", True), (res.status, res.pin_rotated))
        self.assertNotEqual("482913", self.gate.current_pin())
        self.assertEqual(2, self.gate.pin_generation)
        self.assertEqual("ok", self.gate.attempt(IP2, self.gate.current_pin()).status)

    def test_expired_attempts_do_not_count_as_failures(self):
        self.clock.advance(601)
        self.gate.attempt(IP, "482913")
        self.assertEqual(0, self.gate.limiter.snapshot()["global_failures"])

    def test_brute_force_budget(self):
        """An attacker with many addresses: no PIN generation is ever tested more than five times."""
        clock = ManualClock()
        gate = auth.PinGate(clock=clock, rng=helpers.SeededRng(21))
        per_generation = {}
        evaluated = 0
        real = auth.consteq

        def counting(a, b):
            nonlocal evaluated
            evaluated += 1
            return real(a, b)

        with mock.patch.object(auth, "consteq", counting):
            for i in range(3000):
                gen = gate.pin_generation
                before = evaluated
                res = gate.attempt("10.%d.%d.%d" % (i % 7, (i // 7) % 250, i % 250), "%06d" % (i * 7919 % 1000000))
                if evaluated > before:
                    per_generation[gen] = per_generation.get(gen, 0) + 1
                clock.advance(0.7)
                if res.status == "ok":
                    break
        self.assertGreater(len(per_generation), 100)                    # the PIN rotated over and over
        self.assertLessEqual(max(per_generation.values()), 5)

    def test_one_client_budget(self):
        """A single address gets about three guesses per five minutes."""
        clock = ManualClock()
        gate = auth.PinGate(clock=clock, rng=helpers.SeededRng(22), pin="654321", pin_ttl_s=10 ** 9)
        evaluated = 0
        real = auth.consteq

        def counting(a, b):
            nonlocal evaluated
            evaluated += 1
            return real(a, b)

        with mock.patch.object(auth, "consteq", counting):
            for step in range(3600):                                    # one hour in one-second steps
                gate.attempt(IP, "%06d" % step)
                clock.advance(1.0)
        self.assertLessEqual(evaluated, 3 * (3600 // 300 + 1))

    def test_threaded_use_is_safe(self):
        gate = auth.PinGate(clock=ManualClock(), rng=helpers.SeededRng(4), pin="123456")
        results = []

        def work(n):
            for i in range(50):
                results.append(gate.attempt("10.0.0.%d" % n, "%06d" % i).status)

        threads = [threading.Thread(target=work, args=(n,)) for n in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(300, len(results))
        self.assertTrue(set(results) <= {"wrong", "locked", "backoff", "rotated", "ok", "expired"})


if __name__ == "__main__":
    unittest.main()
