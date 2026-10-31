"""Seeded fuzz of the statement verifier and the replay guard.

* Bytes mutated from a validly signed statement are never accepted under the old signature, and only the module's error ever
  escapes.
* Mutated bytes that are signed afresh are accepted exactly when an independent oracle says so. The oracle restates the rules in a
  different style (the standard library's json module and regular expressions instead of the verifier's own loops), so a regression
  or a typo in either shows up as a disagreement.
* Random input of every shape gives the module's error and nothing else.
* Random clock readings, expiries and policies agree with a plain model of the lifetime rules.
* Random sequences of claims agree with a dictionary model of the replay rules.

Size: CI_SETUP_FUZZ_N (default 10000 per test); seed: CI_SETUP_FUZZ_SEED.
"""
import json
import random
import re
import unittest

import helpers
from ci_setup import replay
from ci_setup.clock import ManualWallClock
from ci_setup.replay import MemoryBackend, ReplayError, ReplayGuard
from ci_setup.statement import Expected, StatementError, verify_statement

T0 = helpers.STMT_T0
SIGNER = helpers.HmacStandInVerifier()
ACCEPT_ALL = helpers.AcceptAllVerifier()
EXPECTED = Expected(types=(helpers.STMT_TYPE,), scope=helpers.STMT_SCOPE, target=helpers.STMT_TARGET)
SEVEN = {"v", "type", "request_id", "scope", "target", "params_hash", "expires_at"}
JSONISH = b'{}[]",:0123456789abcdefABCDEF\\ntrufalsNI.-+eE \t\n\x00\x7f\xc3\xa9u'


def verify(raw, signature, verifier=SIGNER, now=T0, expected=EXPECTED, params=None):
    """One verification against a fresh, empty store."""
    guard = ReplayGuard(MemoryBackend())
    return verify_statement(raw, signature, verifier=verifier, expected=expected,
                            params=helpers.STMT_PARAMS if params is None else params, now=ManualWallClock(now), store=guard)


def accepted(raw, signature, **kw):
    """True if verified, False on the module's error; any other exception escapes and fails the test."""
    try:
        verify(raw, signature, **kw)
    except StatementError:
        return False
    return True


# ------------------------------------------------------------------------------------------------ the oracle


def _pairs(items):
    out = {}
    for key, value in items:
        if key in out:
            raise ValueError("duplicate member")
        out[key] = value
    return out


def _constant(name):
    raise ValueError(name)


def oracle(raw, now=T0):
    """Would a plain reading of the rules accept these exact bytes, given a good signature and an empty store?"""
    if len(raw) > 2048 or any(b > 127 for b in raw):
        return False
    try:
        obj = json.loads(raw.decode("ascii"), object_pairs_hook=_pairs, parse_constant=_constant)
    except (ValueError, RecursionError):
        return False
    if type(obj) is not dict:
        return False
    if json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii") != raw:
        return False
    if set(obj) != SEVEN or type(obj["v"]) is not int or obj["v"] != 1:
        return False
    if obj["type"] != helpers.STMT_TYPE or obj["scope"] != helpers.STMT_SCOPE or obj["target"] != helpers.STMT_TARGET:
        return False
    if obj["params_hash"] != helpers.params_digest(helpers.STMT_PARAMS):
        return False
    if type(obj["request_id"]) is not str or re.fullmatch(r"[0-9a-f]{32}", obj["request_id"]) is None:
        return False
    expiry = obj["expires_at"]
    return type(expiry) is int and 1 <= expiry <= 999999999999 and now < expiry <= now + 600 + 120


# ------------------------------------------------------------------------------------------------ mutations of bytes


def _pos(raw, rnd):
    return rnd.randrange(len(raw)) if raw else 0


def m_flip_bit(raw, rnd):
    b = bytearray(raw)
    if b:
        b[_pos(raw, rnd)] ^= 1 << rnd.randrange(8)
    return bytes(b)


def m_replace(raw, rnd):
    b = bytearray(raw)
    if b:
        b[_pos(raw, rnd)] = rnd.choice(JSONISH)
    return bytes(b)


def m_delete(raw, rnd):
    i = _pos(raw, rnd)
    return raw[:i] + raw[i + rnd.randint(1, 3):]


def m_insert(raw, rnd):
    i = _pos(raw, rnd)
    return raw[:i] + bytes(rnd.choice(JSONISH) for _ in range(rnd.randint(1, 3))) + raw[i:]


def m_duplicate_slice(raw, rnd):
    i, j = sorted((_pos(raw, rnd), _pos(raw, rnd)))
    return raw[:j] + raw[i:j] + raw[j:]


def m_swap_adjacent(raw, rnd):
    b = bytearray(raw)
    if len(b) > 1:
        i = rnd.randrange(len(b) - 1)
        b[i], b[i + 1] = b[i + 1], b[i]
    return bytes(b)


def m_truncate(raw, rnd):
    return raw[:_pos(raw, rnd)]


def m_append(raw, rnd):
    return raw + bytes(rnd.choice(JSONISH) for _ in range(rnd.randint(1, 6)))


def m_whitespace(raw, rnd):
    i = _pos(raw, rnd)
    return raw[:i] + rnd.choice((b" ", b"\n", b"\t", b"\r")) + raw[i:]


def m_digit(raw, rnd):
    spots = [i for i, c in enumerate(raw) if 48 <= c <= 57]
    b = bytearray(raw)
    if spots:
        b[rnd.choice(spots)] = 48 + rnd.randrange(10)
    return bytes(b)


def m_hex_case(raw, rnd):
    spots = [i for i, c in enumerate(raw) if 97 <= c <= 102]
    b = bytearray(raw)
    if spots:
        b[rnd.choice(spots)] -= 32
    return bytes(b)


def m_escape(raw, rnd):
    """Write a printable character as a \\u escape: the same text, another representation."""
    spots = [i for i, c in enumerate(raw) if 97 <= c <= 122]
    if not spots:
        return raw
    i = rnd.choice(spots)
    return raw[:i] + b"\\u%04x" % raw[i] + raw[i + 1:]


def _members(raw):
    try:
        return json.loads(raw.decode("ascii"))
    except (ValueError, RecursionError):
        return None


def m_member(raw, rnd):
    """Re-encode with one member replaced by an interesting value, dropped, duplicated or added, and a random layout."""
    obj = _members(raw)
    if type(obj) is not dict:
        return raw
    key = rnd.choice(sorted(SEVEN & set(obj)) or ["v"])
    action = rnd.randrange(6)
    values = [0, 1, -1, 2, 99, 1.0, 1.5, 1e3, "", "x", "x" * 200, None, True, False, [], {}, [1], {"a": 1}, 2 ** 53, 2 ** 53 - 1,
              -(2 ** 53 - 1), 10 ** 12, 10 ** 12 - 1, T0, T0 + 1, T0 + 719, T0 + 720, T0 + 721, T0 - 1, "A" * 32, "a" * 32, "g" * 32,
              "\U000000e9", "\U0001f600", "\ud83d", "\x7f", "\x00", "wifi.join", "WIFI.JOIN", float("nan"), float("inf")]
    if action == 0:
        obj[key] = rnd.choice(values)
    elif action == 1:
        obj.pop(key, None)
    elif action == 2:
        obj["extra"] = rnd.choice(values)
    elif action == 3:
        obj[key.upper()] = obj.get(key)
    elif action == 4:
        obj["expires_at"] = T0 + rnd.randint(-3, 725)
    else:
        obj["request_id"] = "%032x" % rnd.getrandbits(128)
    items = list(obj.items())
    layout = rnd.randrange(4)
    if layout == 0:
        rnd.shuffle(items)
        return json.dumps(dict(items), separators=(",", ":")).encode("ascii")
    if layout == 1:
        return json.dumps(obj, sort_keys=True).encode("ascii")
    if layout == 2:
        return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8", "surrogatepass")
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("ascii")


def m_dup_member(raw, rnd):
    text = raw.decode("ascii", "replace")
    parts = text[1:-1].split(",")
    if len(parts) < 2:
        return raw
    parts.insert(rnd.randrange(len(parts)), rnd.choice(parts))
    return ("{" + ",".join(parts) + "}").encode("ascii", "replace")


def m_pad(raw, rnd):
    """Pad to about the size limit, with spaces before or after."""
    pad = b" " * rnd.randint(1700, 2100)
    return pad + raw if rnd.randrange(2) else raw + pad


MUTATORS = [m_flip_bit, m_replace, m_delete, m_insert, m_duplicate_slice, m_swap_adjacent, m_truncate, m_append, m_whitespace,
            m_digit, m_hex_case, m_escape, m_member, m_member, m_dup_member, m_pad]


def mutate(raw, rnd):
    for _ in range(rnd.choice((1, 1, 1, 2, 3))):
        raw = rnd.choice(MUTATORS)(raw, rnd)
    return raw


def bases():
    overs = ({}, {"request_id": "f" * 32}, {"expires_at": T0 + 720}, {"expires_at": T0 + 1, "request_id": "0123456789abcdef" * 2})
    return [helpers.make_statement(SIGNER, **over) for over in overs]


class Mutations(unittest.TestCase):
    def test_a_mutated_statement_is_never_accepted_under_the_old_signature(self):
        rnd = random.Random(helpers.fuzz_seed())
        pool = bases()
        for signed in pool:
            self.assertTrue(accepted(signed.raw, signed.signature))
        codes = {}
        tried = 0
        for _ in range(helpers.fuzz_n(10000)):
            signed = rnd.choice(pool)
            raw = mutate(signed.raw, rnd)
            if raw == signed.raw:
                continue
            tried += 1
            try:
                verify(raw, signed.signature)
            except StatementError as exc:
                codes[exc.code] = codes.get(exc.code, 0) + 1
            else:
                self.fail("accepted: %r" % raw)
        self.assertGreater(tried, 100)
        # the mutations reach every step before the signature, and the signature itself
        for code in ("size", "encoding", "format", "noncanonical", "signature"):
            self.assertIn(code, codes)

    def test_resigned_mutations_are_accepted_exactly_when_the_oracle_says_so(self):
        rnd = random.Random(helpers.fuzz_seed() + 1)
        pool = bases()
        yes = no = 0
        codes = set()
        for _ in range(helpers.fuzz_n(10000)):
            raw = mutate(rnd.choice(pool).raw, rnd)
            want = oracle(raw)
            signature = helpers.sign_raw(SIGNER, raw)
            try:
                verify(raw, signature)
                got = True
            except StatementError as exc:
                got = False
                codes.add(exc.code)
            self.assertEqual(want, got, raw)
            if want:
                yes += 1
            else:
                no += 1
        self.assertGreater(yes, 20)
        self.assertGreater(no, 100)
        for code in ("format", "noncanonical", "field", "version", "expired", "ttl"):
            self.assertIn(code, codes)

    def test_the_same_mutations_with_a_verifier_that_says_yes_follow_the_same_rules(self):
        rnd = random.Random(helpers.fuzz_seed() + 2)
        pool = bases()
        for _ in range(helpers.fuzz_n(10000)):
            raw = mutate(rnd.choice(pool).raw, rnd)
            self.assertEqual(oracle(raw), accepted(raw, b"x", verifier=ACCEPT_ALL), raw)


class AnyInput(unittest.TestCase):
    def random_bytes(self, rnd):
        kind = rnd.randrange(5)
        if kind == 0:
            return bytes(rnd.randrange(256) for _ in range(rnd.randint(0, 40)))
        if kind == 1:
            return bytes(rnd.choice(JSONISH) for _ in range(rnd.randint(0, 120)))
        if kind == 2:
            return b"{" + b",".join(b'"%s":%s' % (rnd.choice(sorted(k.encode() for k in SEVEN) + [b"x", b""]),
                                                   bytes(rnd.choice(JSONISH) for _ in range(rnd.randint(0, 8))))
                                    for _ in range(rnd.randint(0, 9))) + b"}"
        if kind == 3:
            return bytes(rnd.choice(JSONISH) for _ in range(rnd.randint(1990, 2100)))
        return rnd.choice(bases()).raw[:rnd.randint(0, 400)]

    def random_signature(self, rnd):
        kind = rnd.randrange(6)
        if kind == 0:
            return bytes(rnd.randrange(256) for _ in range(rnd.choice((0, 1, 31, 32, 33, 64, 1024, 1025))))
        return rnd.choice((None, "text", 5, 1.5, [b"x"], {"a": 1}, bytearray(b"y" * 32), b"z" * 32, True))

    def test_nothing_but_the_modules_error_escapes(self):
        rnd = random.Random(helpers.fuzz_seed() + 3)
        for _ in range(helpers.fuzz_n(10000)):
            raw = self.random_bytes(rnd) if rnd.randrange(8) else rnd.choice((None, "{}", 5, 1.5, [], {}, object(), True))
            signature = self.random_signature(rnd)
            for verifier in (SIGNER, ACCEPT_ALL):
                accepted(raw, signature, verifier=verifier)


class Lifetimes(unittest.TestCase):
    def test_random_times_and_policies_agree_with_a_plain_model(self):
        rnd = random.Random(helpers.fuzz_seed() + 5)
        seen = set()
        for i in range(helpers.fuzz_n(10000) // 4):
            ttl = rnd.choice((1, 5, 60, 600, 3600, 86400))
            skew = rnd.choice((0, 1, 30, 120, 3600))
            before = rnd.choice((None, 0, 1, skew, skew + 1, 10 * skew + 7))        # how far the floor is ahead of the clock
            now = T0 + rnd.randint(-5, 5)
            expires_at = now + rnd.choice((-ttl, -1, 0, 1, 2, ttl - 1, ttl, ttl + skew - 1, ttl + skew, ttl + skew + 1, 2 * ttl + 3 * skew,
                                           rnd.randint(-1000, 100000)))
            if expires_at < 1:
                continue
            expected = Expected(types=(helpers.STMT_TYPE,), scope=helpers.STMT_SCOPE, target=helpers.STMT_TARGET, max_ttl_s=ttl,
                                skew_s=skew)
            backend = MemoryBackend()
            guard = ReplayGuard(backend)
            floor = 0
            if before is not None:
                floor = now + before
                backend.set_floor_raw(replay.encode_floor(floor))
            signed = helpers.make_statement(SIGNER, expires_at=expires_at)
            if now >= expires_at:
                want = "expired"
            elif expires_at - now > ttl + skew:
                want = "ttl"
            elif now < floor - skew:
                want = "clock"
            else:
                want = "accepted"
            try:
                verify_statement(signed.raw, signed.signature, verifier=SIGNER, expected=expected, params=helpers.STMT_PARAMS,
                                 now=ManualWallClock(now), store=guard)
                got = "accepted"
            except StatementError as exc:
                got = exc.code
            self.assertEqual(want, got, (ttl, skew, before, now, expires_at))
            self.assertEqual(max(floor, now) if got == "accepted" else floor, guard.floor())
            seen.add(got)
        self.assertEqual({"accepted", "expired", "ttl", "clock"}, seen)


class Model(unittest.TestCase):
    """The guard against a dictionary: random claims with ids from a small pool, random clock readings and expiries."""

    def test_the_guard_agrees_with_a_model_of_the_rules(self):
        rnd = random.Random(helpers.fuzz_seed() + 6)
        for run in range(max(1, helpers.fuzz_n(10000) // 2000)):
            bound = rnd.choice((3, 8, 40))
            ttl, skew = rnd.choice(((600, 120), (10, 0), (50, 7)))
            backend = MemoryBackend()
            guard = ReplayGuard(backend, max_markers=bound)
            consumed = {}                      # request id -> expiry
            floor = 0
            now = T0
            outcomes = set()
            for step in range(300):
                now = max(1, now + rnd.choice((-3 * skew - 1, -skew, -1, 0, 1, 5, ttl, ttl + skew + 2, 3 * (ttl + skew))))
                n = rnd.randrange(60)
                expires_at = now + rnd.randint(1, ttl + skew)
                if now < floor - skew:
                    want = "clock"
                elif n in consumed:
                    want = "replayed"
                else:
                    for k in [k for k, e in consumed.items() if e + skew + ttl < floor]:
                        del consumed[k]
                    if len(consumed) >= bound:
                        want = "store_full"
                    else:
                        want = "ok"
                        consumed[n] = expires_at
                        floor = max(floor, now)
                try:
                    guard.claim("%032x" % n, expires_at, now, ttl, skew)
                    got = "ok"
                except ReplayError as exc:
                    got = exc.code
                self.assertEqual(want, got, (run, step, n, now, floor))
                self.assertEqual(floor, guard.floor())
                self.assertEqual(len(consumed), guard.marker_count())
                outcomes.add(got)
            self.assertIn("ok", outcomes)


if __name__ == "__main__":
    unittest.main()
