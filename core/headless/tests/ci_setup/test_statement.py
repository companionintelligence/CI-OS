"""Tests for ci_setup.statement: the canonical encoding and its known answers, every step of verify_statement in its order, the
binding to type, scope, target and parameters, the lifetime rules and the clock floor, the replay guard behind it, and error text
that never echoes a value.

The signature scheme is injected; the tests use the HMAC stand-in of helpers.py (labelled test-only). Expected bytes are built with
the standard library, not with the code under test, wherever a mutant of that code could otherwise hide itself.
"""
import hashlib
import json
import unittest
from unittest import mock

import helpers
from ci_setup import auth, replay, selftest, statement
from ci_setup.clock import ManualClock, ManualWallClock, SystemClock, WallClock
from ci_setup.errors import ValidationError
from ci_setup.statement import (Expected, StatementError, canonical_json, canonical_statement, new_request_id, params_hash,
                                verify_statement)

T0 = helpers.STMT_T0


def nest(depth):
    value = 1
    for _ in range(depth):
        value = [value]
    return value


class Harness(object):
    """A signer, a replay guard over a fresh in-memory backend, a wall clock at T0 and an Expected for the standard statement."""

    def __init__(self, **policy):
        self.signer = helpers.HmacStandInVerifier()
        self.backend = replay.MemoryBackend()
        self.guard = replay.ReplayGuard(self.backend)
        self.clock = ManualWallClock(T0)
        kw = dict(types=(helpers.STMT_TYPE,), scope=helpers.STMT_SCOPE, target=helpers.STMT_TARGET)
        kw.update(policy)
        self.expected = Expected(**kw)
        self.params = dict(helpers.STMT_PARAMS)

    def signed(self, **over):
        return helpers.make_statement(self.signer, **over)

    def run(self, raw, signature, **override):
        args = dict(verifier=self.signer, expected=self.expected, params=self.params, now=self.clock, store=self.guard)
        args.update(override)
        return verify_statement(raw, signature, **args)

    def code(self, raw, signature, **override):
        """The code of the error verify_statement raises, or 'accepted'. Any other exception fails the test."""
        try:
            self.run(raw, signature, **override)
        except StatementError as exc:
            return exc.code
        return "accepted"

    def code_of(self, signed, **override):
        return self.code(signed.raw, signed.signature, **override)

    def code_signed(self, raw):
        """The code for ``raw`` signed with the right key and namespace (so only its own content can make it fail)."""
        return self.code(raw, helpers.sign_raw(self.signer, raw))

    def code_structure(self, raw):
        """The code for ``raw`` when every signature is accepted: only the structure of the bytes decides."""
        return self.code(raw, b"x", verifier=helpers.AcceptAllVerifier())

    def untouched(self):
        """True if nothing was written: no step of the backend ran, no marker, no floor."""
        return self.backend.steps == [] and self.guard.marker_count() == 0 and self.guard.floor() == 0


class CanonicalJson(unittest.TestCase):
    def test_members_are_sorted_and_nothing_is_spaced(self):
        value = {"b": 1, "a": [1, 2, {"d": None, "c": True}], "": {}}
        self.assertEqual(b'{"":{},"a":[1,2,{"c":true,"d":null}],"b":1}', canonical_json(value))
        self.assertEqual(canonical_json({"x": 1, "y": 2}), canonical_json({"y": 2, "x": 1}))

    def test_strings_are_ascii_with_lowercase_unicode_escapes(self):
        text = "tab\t quote\" back\\ nl\n ff\f cr\r bs\b del\x7f nul\x00 e\U000000e9 euro\U000020ac smile\U0001f600"
        expected = b'"tab\\t quote\\" back\\\\ nl\\n ff\\f cr\\r bs\\b del\\u007f nul\\u0000 e\\u00e9 euro\\u20ac smile\\ud83d\\ude00"'
        self.assertEqual(expected, canonical_json(text))
        self.assertTrue(canonical_json({"k": text}).isascii())

    def test_the_output_is_bytes(self):
        self.assertIs(bytes, type(canonical_json({"a": 1})))

    def test_integers_up_to_two_to_the_53_minus_one(self):
        for n in (0, 1, -1, 2 ** 53 - 1, -(2 ** 53 - 1)):
            self.assertEqual(str(n).encode("ascii"), canonical_json(n))
        for n in (2 ** 53, -(2 ** 53), 2 ** 64, -(2 ** 70)):
            with self.assertRaises(StatementError) as ctx:
                canonical_json(n)
            self.assertEqual("format", ctx.exception.code)

    def test_floats_and_foreign_types_are_refused(self):
        for bad in (1.0, 0.5, float("nan"), float("inf"), b"x", {1, 2}, object(), complex(1, 2), 10 ** 30, ...):
            with self.assertRaises(StatementError) as ctx:
                canonical_json(bad)
            self.assertEqual("format", ctx.exception.code, repr(bad))
        with self.assertRaises(StatementError):
            canonical_json({"a": [1, 2.5]})

    def test_booleans_and_null_are_values(self):
        self.assertEqual(b"[true,false,null]", canonical_json([True, False, None]))

    def test_nesting_is_at_most_eight_deep(self):
        self.assertEqual(b"[" * 8 + b"1" + b"]" * 8, canonical_json(nest(8)))
        with self.assertRaises(StatementError):
            canonical_json(nest(9))
        deep = {"a": 1}
        for _ in range(7):
            deep = {"a": deep}
        canonical_json(deep)
        with self.assertRaises(StatementError):
            canonical_json({"a": deep})
        loop = []
        loop.append(loop)
        with self.assertRaises(StatementError):
            canonical_json(loop)

    def test_member_names_are_ascii_text(self):
        for key in (1, None, b"a", ("a",), 1.5, "\U000000e9", "a\U000020ac"):
            with self.assertRaises(StatementError):
                canonical_json({key: 1})

    def test_tuples_are_arrays_and_subclasses_are_not_accepted(self):
        self.assertEqual(b"[1,2]", canonical_json((1, 2)))

        class Dict(dict):
            pass

        class Text(str):
            pass

        for bad in (Dict(a=1), Text("x"), [Text("x")]):
            with self.assertRaises(StatementError):
                canonical_json(bad)

    def test_text_that_is_not_unicode_is_refused(self):
        for bad in ("\ud800", "a\udfffb", {"k": "\ud83d"}):
            with self.assertRaises(StatementError):
                canonical_json(bad)

    def test_the_size_limit(self):
        self.assertEqual(12, len(canonical_json("x" * 10)))
        self.assertEqual(12, len(canonical_json("x" * 10, 12)))
        with self.assertRaises(StatementError) as ctx:
            canonical_json("x" * 10, 11)
        self.assertEqual("size", ctx.exception.code)


class ParamsHash(unittest.TestCase):
    def test_it_is_the_sha256_of_the_canonical_bytes(self):
        self.assertEqual(hashlib.sha256(b'{"a":"x","b":[1,2]}').hexdigest(), params_hash({"b": [1, 2], "a": "x"}))
        self.assertEqual(hashlib.sha256(b"{}").hexdigest(), params_hash({}))
        self.assertEqual(hashlib.sha256(b"null").hexdigest(), params_hash(None))

    def test_values_of_different_types_have_different_hashes(self):
        values = [1, "1", True, [1], {"1": 1}, None, 0, False, "", [], {}, "null", "true"]
        self.assertEqual(len(values), len({params_hash(v) for v in values}))

    def test_what_cannot_be_written_canonically_is_a_params_error(self):
        for bad in (1.5, {"a": float("nan")}, {1: 2}, object(), nest(9), "\ud800", 2 ** 60):
            with self.assertRaises(StatementError) as ctx:
                params_hash(bad)
            self.assertEqual("params", ctx.exception.code)

    def test_parameters_over_64_kib_are_refused(self):
        params_hash({"a": "x" * 65000})
        with self.assertRaises(StatementError) as ctx:
            params_hash({"a": "x" * 65536})
        self.assertEqual("params", ctx.exception.code)


class Structure(unittest.TestCase):
    """What the bytes alone decide, with a verifier that says yes to everything: the codes of the steps before the binding."""

    def setUp(self):
        self.h = Harness()
        self.fields = helpers.statement_fields()
        self.good = helpers.canon_bytes(self.fields)

    def test_the_standard_statement_is_accepted(self):
        self.assertEqual("accepted", self.h.code_structure(self.good))

    def test_input_that_is_not_a_statement(self):
        dup = self.good.replace(b'"v":1}', b'"v":1,"v":1}')
        self.assertNotEqual(self.good, dup)
        cases = [
            ("empty", b"", "format"), ("none", None, "format"), ("text", "{}", "format"), ("int", 5, "format"),
            ("list", [b"{}"], "format"), ("array", b"[]", "format"), ("string", b'"x"', "format"), ("number", b"5", "format"),
            ("null", b"null", "format"), ("not json", b"not json", "format"), ("nul", b"\x00", "format"),
            ("duplicate member", dup, "format"),
            ("nan", self.good.replace(b"1790000300", b"NaN"), "format"),
            ("infinity", self.good.replace(b"1790000300", b"Infinity"), "format"),
            ("minus infinity", self.good.replace(b"1790000300", b"-Infinity"), "format"),
            ("number of 31 digits", self.good.replace(b"1790000300", b"1" * 31), "format"),
            ("nested arrays", b"[" * 1000 + b"]" * 1000, "format"),
            ("2048 spaces", b" " * 2048, "format"),
        ]
        for name, raw, code in cases:
            self.assertEqual(code, self.h.code_structure(raw), name)
        self.assertTrue(self.h.untouched())

    def test_size(self):
        for name, raw in (("2049 spaces", b" " * 2049), ("3000 bytes", self.good + b" " * 3000), ("a megabyte", b"x" * 2 ** 20)):
            self.assertEqual("size", self.h.code_structure(raw), name)
        # the limit is on the bytes received, so a bytearray counts the same
        self.assertEqual("size", self.h.code_structure(bytearray(b" " * 2049)))

    def test_encoding(self):
        for name, raw in (("non-UTF-8", b"\xff\xfe"), ("UTF-8 outside ASCII", self.good[:-1] + b',"x":"\xc3\xa9"}'),
                          ("byte order mark", b"\xef\xbb\xbf" + self.good), ("one high byte", self.good[:-1] + b"\x80}")):
            self.assertEqual("encoding", self.h.code_structure(raw), name)

    def test_bytearray_is_read_as_bytes(self):
        self.assertEqual("accepted", self.h.code_structure(bytearray(self.good)))

    def test_not_canonical(self):
        reordered = json.dumps(self.fields, separators=(",", ":"), sort_keys=False).encode("ascii")
        self.assertNotEqual(self.good, reordered)
        f = self.fields
        cases = [
            ("space after comma", self.good.replace(b",", b", ")),
            ("space after colon", self.good.replace(b":", b": ")),
            ("leading space", b" " + self.good),
            ("trailing newline", self.good + b"\n"),
            ("members out of order", reordered),
            ("escape where a character will do", self.good.replace(b'"wifi.join"', b'"wifi\\u002ejoin"')),
            ("upper-case hex in an escape", self.good.replace(b'"wifi:home-network"', b'"wifi:home\\u002Dnetwork"')),
            ("float", self.good.replace(b"1790000300", b"1790000300.0")),
            ("exponent", self.good.replace(b"1790000300", b"1790000300e0")),
            ("negative zero", self.good.replace(b"1790000300", b"-0")),
            ("integer beyond 2**53 - 1", self.good.replace(b"1790000300", b"9007199254740993")),
            ("nesting beyond 8 in an unknown member", helpers.canon_bytes(dict(f, x=nest(9)))),
            ("lone surrogate", self.good.replace(b'"wifi.join"', b'"\\ud800"')),
            ("member name outside ASCII", helpers.canon_bytes(dict(f, x=1)).replace(b'"x"', b'"\\u00e9"')),
        ]
        for name, raw in cases:
            self.assertEqual("noncanonical", self.h.code_structure(raw), name)
        self.assertTrue(self.h.untouched())

    def test_members(self):
        h = self.h
        f = self.fields
        for name in helpers.statement_fields():
            self.assertEqual("field", h.code_signed(helpers.canon_bytes(helpers.statement_fields(**{name: helpers.OMIT}))),
                             "missing " + name)
        self.assertEqual("field", h.code_signed(helpers.canon_bytes(dict(f, extra=1))))
        self.assertEqual("field", h.code_signed(helpers.canon_bytes(dict(f, extra=1, other=[1]))))
        self.assertEqual("field", h.code_signed(helpers.canon_bytes(dict(f, V=1))))
        self.assertEqual("field", h.code_signed(b"{}"))
        bad = {
            "v": ["1", True, False, None, [1], {"a": 1}],
            "type": ["", "Wifi.join", "wifi join", "x" * 33, 5, None, ["a"], "wifi/join", "w\U000000e9", "wifi.join\n", True],
            "request_id": ["", "0" * 31, "0" * 33, "A" * 32, "g" * 32, "0" * 31 + "\U000000e9", None, 5, ["0" * 32]],
            "scope": ["", "x" * 129, "tab\there", "\U000000e9", "\x7f", "\x00", None, 5, ["a"], True, "a\nb"],
            "target": ["", "x" * 129, "tab\there", "\U000000e9", "\x7f", "\x00", None, 5, ["a"], True, "a\nb"],
            "params_hash": ["", "0" * 63, "0" * 65, "A" * 64, "g" * 64, None, 5, True],
            "expires_at": [0, -1, 10 ** 12, 2 ** 53 - 1, True, False, "1790000300", None, [1], {"a": 1}],
        }
        for name, values in bad.items():
            for value in values:
                self.assertEqual("field", h.code_signed(helpers.canon_bytes(helpers.statement_fields(**{name: value}))),
                                 "%s=%r" % (name, value))
        self.assertTrue(h.untouched())

    def test_version(self):
        for version in (2, 0, -1, 99, 2 ** 53 - 1):
            raw = helpers.canon_bytes(helpers.statement_fields(v=version))
            self.assertEqual("version", self.h.code_signed(raw), version)
            # an unknown version is reported whatever else the object holds: another version may have other members
            raw = helpers.canon_bytes(dict(helpers.statement_fields(v=version), extra="x"))
            self.assertEqual("version", self.h.code_signed(raw), version)
        self.assertTrue(self.h.untouched())

    def test_the_longest_members_and_the_largest_expiry_are_accepted(self):
        scope, target, kind = "s" * 126 + "\"\\", "t" * 126 + "\\\"", "a" * 30 + "._"
        h = Harness(scope=scope, target=target, types=(kind,))
        h.clock.set(999999999999 - 300)
        signed = h.signed(scope=scope, target=target, type=kind, expires_at=999999999999)
        self.assertLessEqual(len(signed.raw), 2048)
        self.assertEqual("accepted", h.code_of(signed))

    def test_the_smallest_members_are_accepted(self):
        h = Harness(scope="s", target="t", types=("a",))
        h.clock.set(0)
        self.assertEqual("accepted", h.code_of(h.signed(scope="s", target="t", type="a", request_id="0" * 32, expires_at=1)))

    def test_all_printable_ascii_is_allowed_in_scope_and_target(self):
        text = "".join(chr(c) for c in range(0x20, 0x7F))
        h = Harness(scope=text, target=text)
        self.assertEqual("accepted", h.code_of(h.signed(scope=text, target=text)))


class Order(unittest.TestCase):
    def test_a_statement_that_fails_two_steps_reports_the_earlier(self):
        h = Harness()
        good = helpers.canon_bytes(helpers.statement_fields())
        bad_signature = b"\x00" * 32
        self.assertEqual("noncanonical", h.code(good.replace(b",", b", "), bad_signature))
        self.assertEqual("signature", h.code(helpers.canon_bytes(helpers.statement_fields(extra=1)), bad_signature))
        self.assertEqual("signature", h.code(helpers.canon_bytes(helpers.statement_fields(v=2)), bad_signature))
        self.assertEqual("signature", h.code(helpers.canon_bytes(helpers.statement_fields(type="other.op")), bad_signature))
        self.assertTrue(h.untouched())

    def test_the_members_are_judged_in_order(self):
        """Break everything at once and repair one thing at a time: each repair uncovers the next step."""
        h = Harness()
        h.params = {"changed": True}
        h.clock.set(T0 + 500)
        fields = helpers.statement_fields(v=2, type="other.op", scope="other-scope", target="other-target",
                                          expires_at=T0 + 100, extra=1)
        steps = [("version", {"v": 1}), ("field", {"extra": helpers.OMIT}), ("type", {"type": helpers.STMT_TYPE}),
                 ("scope", {"scope": helpers.STMT_SCOPE}), ("target", {"target": helpers.STMT_TARGET}),
                 ("params", {"params_hash": helpers.params_digest(h.params)}), ("expired", {"expires_at": T0 + 500 + 721}),
                 ("ttl", {"expires_at": T0 + 500 + 720}), ("accepted", {})]
        for want, repair in steps:
            raw = helpers.canon_bytes(fields)
            self.assertEqual(want, h.code_signed(raw))
            for key, value in repair.items():
                if value is helpers.OMIT:
                    del fields[key]
                else:
                    fields[key] = value

    def test_nothing_is_written_before_every_check_has_passed(self):
        h = Harness()
        for raw, signature in ((b"", b"x"), (b"junk", b"x"), (h.signed().raw, b"\x00" * 32), (h.signed(extra=1).raw, b"\x00" * 32)):
            self.assertNotEqual("accepted", h.code(raw, signature))
        for over, params in (({"type": "other.op"}, None), ({"scope": "other"}, None), ({"target": "other"}, None),
                             ({}, {"changed": 1}), ({"expires_at": T0}, None), ({"expires_at": T0 + 721}, None),
                             ({"v": 2}, None), ({"extra": 1}, None)):
            kw = {} if params is None else {"params": params}
            self.assertNotEqual("accepted", h.code_of(h.signed(**over), **kw), over)
        self.assertTrue(h.untouched())


class Signature(unittest.TestCase):
    def test_tampering_with_any_member_after_signing_is_a_signature_error(self):
        h = Harness()
        signed = h.signed()
        other = {"v": 2, "type": "wifi.leave", "request_id": "ff" * 16, "scope": "device-key-thumbprint-0002",
                 "target": "wifi:other", "params_hash": "ab" * 32, "expires_at": T0 + 301}
        self.assertEqual(sorted(helpers.statement_fields()), sorted(other))
        for name, value in other.items():
            raw = helpers.canon_bytes(dict(signed.fields, **{name: value}))
            self.assertNotEqual(signed.raw, raw)
            self.assertEqual("signature", h.code(raw, signed.signature), name)
        self.assertTrue(h.untouched())
        self.assertEqual("accepted", h.code_of(signed))

    def test_a_signature_by_another_key_is_refused(self):
        h = Harness()
        stranger = helpers.HmacStandInVerifier(b"TEST-ONLY another key")
        signed = helpers.make_statement(stranger)
        self.assertEqual(signed.raw, h.signed().raw)
        self.assertEqual("signature", h.code_of(signed))

    def test_a_proof_made_for_another_purpose_is_not_a_statement(self):
        h = Harness()
        raw = helpers.canon_bytes(helpers.statement_fields())
        for namespace in ("ci-os-login@ci.computer", "", "ci-os-statement@ci.computer ", "CI-OS-STATEMENT@ci.computer",
                          "ci-os-statement@example.test", "ci-os-statement"):
            self.assertEqual("signature", h.code(raw, helpers.sign_raw(h.signer, raw, namespace)), namespace)
        self.assertEqual("signature", h.code(raw, h.signer.sign(helpers.STMT_NAMESPACE, raw)), "no prefix")
        self.assertEqual("signature", h.code(raw, h.signer.sign(helpers.STMT_NAMESPACE, b"ci-os-statement/2\n" + raw)), "prefix 2")
        self.assertEqual("accepted", h.code(raw, helpers.sign_raw(h.signer, raw)))

    def test_the_verifier_is_called_once_with_the_namespace_and_the_prefixed_bytes(self):
        h = Harness()
        signed = h.signed()
        h.run(signed.raw, signed.signature)
        self.assertEqual([(helpers.STMT_NAMESPACE, helpers.STMT_PREFIX + signed.raw, signed.signature)], h.signer.calls)
        self.assertEqual(statement.NAMESPACE, helpers.STMT_NAMESPACE)
        self.assertEqual(statement.SIGNING_PREFIX, helpers.STMT_PREFIX)

    def test_a_verifier_that_fails_or_answers_oddly_means_no(self):
        h = Harness()
        signed = h.signed()

        class Raises(object):
            def verify(self, namespace, message, signature):
                raise RuntimeError("scheme failure " + helpers.STMT_TARGET)

        self.assertEqual("signature", h.code_of(signed, verifier=Raises()))
        self.assertEqual("signature", h.code_of(signed, verifier=object()))
        for answer in (1, "yes", b"ok", None, [True], 0.5, 0, False, ()):
            class Odd(object):
                def verify(self, namespace, message, signature, _a=answer):
                    return _a

            self.assertEqual("signature", h.code_of(signed, verifier=Odd()), repr(answer))
        self.assertTrue(h.untouched())

    def test_the_shape_of_the_signature_argument(self):
        h = Harness()
        signed = h.signed()
        for bad in (None, "text", 5, b"", b"x" * 1025, [b"x"], 1.5, True):
            self.assertEqual("signature", h.code(signed.raw, bad), repr(bad)[:30])
        self.assertTrue(h.untouched())
        self.assertEqual("accepted", h.code(signed.raw, bytearray(signed.signature)))

    def test_the_signature_is_checked_before_any_member_is_judged(self):
        """An unsigned statement for another operation is a bad signature, not a wrong type: nothing is learned from a forger."""
        h = Harness()
        for over in ({"type": "other.op"}, {"scope": "other"}, {"target": "other"}, {"expires_at": T0 - 1}, {"extra": 1}):
            raw = helpers.canon_bytes(helpers.statement_fields(**over))
            self.assertEqual("signature", h.code(raw, b"\x00" * 32), over)


class Binding(unittest.TestCase):
    def test_wrong_type_scope_target_and_parameters(self):
        for over, kw, want in (({"type": "wifi.leave"}, {}, "type"), ({"scope": "device-key-thumbprint-0002"}, {}, "scope"),
                               ({"target": "wifi:elsewhere"}, {}, "target"), ({}, {"params": {"ssid": "Home Net"}}, "params"),
                               ({}, {"params": {"security": "wpa3", "ssid": "Home Net"}}, "params"),
                               ({}, {"params": {"security": "wpa2", "ssid": "Home Net", "x": 1}}, "params")):
            h = Harness()
            signed = h.signed(**over)
            self.assertEqual(want, h.code_of(signed, **kw), over or kw)
            self.assertTrue(h.untouched())
            if want == "params":
                self.assertEqual("accepted", h.code_of(h.signed()), "the id was not burned")

    def test_a_refusal_does_not_consume_the_request_id(self):
        h = Harness()
        signed = h.signed()
        for kw in ({"params": {"x": 1}}, {"expected": Expected(types=("a",), scope=helpers.STMT_SCOPE, target=helpers.STMT_TARGET)},
                   {"expected": Expected(types=(helpers.STMT_TYPE,), scope="s", target=helpers.STMT_TARGET)},
                   {"expected": Expected(types=(helpers.STMT_TYPE,), scope=helpers.STMT_SCOPE, target="t")}):
            self.assertNotEqual("accepted", h.code_of(signed, **kw))
            self.assertTrue(h.untouched())
        self.assertEqual("accepted", h.code_of(signed))
        self.assertEqual("replayed", h.code_of(signed))

    def test_several_types_may_be_allowed(self):
        h = Harness(types=("wifi.join", "wifi.leave"))
        self.assertEqual("accepted", h.code_of(h.signed(type="wifi.leave", request_id="1" * 32)))
        self.assertEqual("accepted", h.code_of(h.signed(type="wifi.join", request_id="2" * 32)))
        self.assertEqual("type", h.code_of(h.signed(type="wifi", request_id="3" * 32)))

    def test_parameters_are_compared_by_their_canonical_form(self):
        h = Harness()
        signed = h.signed()
        self.assertEqual("accepted", h.code_of(signed, params={"ssid": "Home Net", "security": "wpa2"}))

    def test_parameters_that_cannot_be_hashed_are_a_params_error(self):
        h = Harness()
        signed = h.signed()
        for bad in (1.5, {"a": float("nan")}, object(), nest(9)):
            self.assertEqual("params", h.code_of(signed, params=bad))
        self.assertTrue(h.untouched())

    def test_the_hash_comparison_is_the_constant_time_one(self):
        h = Harness()
        signed = h.signed()
        with mock.patch.object(statement, "consteq", wraps=auth.consteq) as spy:
            self.assertEqual("accepted", h.code_of(signed))
        pairs = [tuple(c.args) for c in spy.call_args_list]
        self.assertIn((helpers.params_digest(helpers.STMT_PARAMS), helpers.params_digest(helpers.STMT_PARAMS)), pairs)

    def test_the_result_is_a_small_frozen_record(self):
        h = Harness()
        signed = h.signed()
        record = h.run(signed.raw, signed.signature)
        self.assertEqual(statement.VerifiedStatement(type=helpers.STMT_TYPE, request_id=helpers.STMT_REQUEST_ID,
                                                     scope=helpers.STMT_SCOPE, target=helpers.STMT_TARGET,
                                                     params_hash=helpers.params_digest(helpers.STMT_PARAMS),
                                                     expires_at=T0 + 300), record)
        with self.assertRaises(Exception):
            record.target = "other"


class Lifetime(unittest.TestCase):
    def verdict(self, now, expires_at, **policy):
        h = Harness(**policy)
        h.clock.set(now)
        return h.code_of(h.signed(expires_at=expires_at))

    def test_expiry_boundary(self):
        self.assertEqual("accepted", self.verdict(T0, T0 + 1))
        self.assertEqual("expired", self.verdict(T0, T0))
        self.assertEqual("expired", self.verdict(T0, T0 - 1))
        self.assertEqual("expired", self.verdict(T0, 1))

    def test_lifetime_boundary(self):
        self.assertEqual("accepted", self.verdict(T0, T0 + 720))
        self.assertEqual("ttl", self.verdict(T0, T0 + 721))
        self.assertEqual("ttl", self.verdict(T0, T0 + 3600))
        self.assertEqual("accepted", self.verdict(T0, T0 + 60, max_ttl_s=60, skew_s=0))
        self.assertEqual("ttl", self.verdict(T0, T0 + 61, max_ttl_s=60, skew_s=0))
        self.assertEqual("accepted", self.verdict(T0, T0 + 1, max_ttl_s=1, skew_s=0))
        self.assertEqual("ttl", self.verdict(T0, T0 + 2, max_ttl_s=1, skew_s=0))
        self.assertEqual("accepted", self.verdict(T0, T0 + 3600 + 86400, max_ttl_s=86400, skew_s=3600))
        self.assertEqual("ttl", self.verdict(T0, T0 + 3600 + 86400 + 1, max_ttl_s=86400, skew_s=3600))

    def test_the_defaults(self):
        self.assertEqual(600, statement.DEFAULT_MAX_TTL_S)
        self.assertEqual(120, statement.DEFAULT_SKEW_S)
        e = Expected(types=("a",), scope="s", target="t")
        self.assertEqual((600, 120), (e.max_ttl_s, e.skew_s))

    def test_a_clock_far_behind_sees_a_far_future_expiry_and_fails_closed(self):
        h = Harness()
        h.clock.set(T0 - 10 ** 6)
        self.assertEqual("ttl", h.code_of(h.signed()))
        h.clock.set(0)
        self.assertEqual("ttl", h.code_of(h.signed()))
        self.assertTrue(h.untouched())

    def test_a_clock_far_ahead_sees_an_expired_statement(self):
        h = Harness()
        h.clock.set(T0 + 10 ** 6)
        self.assertEqual("expired", h.code_of(h.signed()))
        self.assertTrue(h.untouched())

    def test_a_clock_reading_that_is_not_whole_seconds_is_refused(self):
        class Fixed(object):
            def __init__(self, value):
                self.value = value

            def now(self):
                return self.value

        class Raises(object):
            def now(self):
                raise OSError("no clock")

        h = Harness()
        signed = h.signed()
        for value in (1.5, float(T0), str(T0), None, True, -1, 10 ** 12, [T0]):
            self.assertEqual("clock", h.code_of(signed, now=Fixed(value)), repr(value))
        self.assertEqual("clock", h.code_of(signed, now=Raises()))
        self.assertEqual("clock", h.code_of(signed, now=object()))
        self.assertEqual("clock", h.code_of(signed, now=T0))
        self.assertTrue(h.untouched())
        self.assertEqual("accepted", h.code_of(signed, now=Fixed(T0)))


class ClockFloor(unittest.TestCase):
    def test_a_clock_behind_the_floor_by_more_than_the_skew_is_refused(self):
        h = Harness()
        self.assertEqual("accepted", h.code_of(h.signed(request_id="0" * 32)))
        self.assertEqual(T0, h.guard.floor())
        cases = [(0, "accepted"), (1, "accepted"), (60, "accepted"), (119, "accepted"), (120, "accepted"), (121, "clock"),
                 (122, "clock"), (3600, "clock"), (10 ** 6, "clock")]
        for n, (behind, want) in enumerate(cases, start=1):
            h.clock.set(T0 - behind)
            signed = h.signed(request_id="%032x" % n, expires_at=T0 - behind + 300)
            self.assertEqual(want, h.code_of(signed), behind)
        self.assertEqual(T0, h.guard.floor(), "the floor never goes down")

    def test_known_limit_a_clock_set_back_inside_the_life_of_an_unused_statement_is_not_noticed(self):
        """The floor is the latest time at which a statement was accepted. It notices a clock that goes back past that time, not one
        that is set back to a time after it: a statement nobody has used is still inside its life by the clock's account. This is why
        the life is short by default, and a limit of any expiry that is judged by a wall clock alone."""
        h = Harness()
        self.assertEqual("accepted", h.code_of(h.signed(request_id="0" * 32)))              # floor T0
        unused = h.signed(request_id="1" * 32, expires_at=T0 + 100)
        h.clock.set(T0 + 10 ** 5)
        self.assertEqual("expired", h.code_of(unused))
        h.clock.set(T0 + 50)                                                                 # set back, but not past the floor
        self.assertEqual("accepted", h.code_of(unused))

    def test_the_skew_is_the_callers_to_set(self):
        h = Harness(skew_s=0)
        h.code_of(h.signed(request_id="0" * 32))
        h.clock.set(T0 - 1)
        self.assertEqual("clock", h.code_of(h.signed(request_id="1" * 32, expires_at=T0 + 100)))
        h.clock.set(T0)
        self.assertEqual("accepted", h.code_of(h.signed(request_id="1" * 32, expires_at=T0 + 100)))

    def test_only_an_accepted_statement_moves_the_floor(self):
        h = Harness()
        first = h.signed()
        self.assertEqual("accepted", h.code_of(first))
        self.assertEqual(T0, h.guard.floor())
        h.clock.set(T0 + 100)
        n = [0]

        def fresh(**over):
            n[0] += 1
            return h.signed(request_id="%032x" % (100 + n[0]), **over)

        refusals = [
            ("format", h.code(b"junk", b"x")),
            ("signature", h.code(first.raw, b"\x01" * 32)),
            ("replayed", h.code_of(first)),
            ("type", h.code_of(fresh(type="other.op"))),
            ("scope", h.code_of(fresh(scope="other"))),
            ("target", h.code_of(fresh(target="other"))),
            ("params", h.code_of(fresh(), params={"x": 1})),
            ("expired", h.code_of(fresh(expires_at=T0 + 100))),
            ("ttl", h.code_of(fresh(expires_at=T0 + 100 + 721))),
            ("version", h.code_of(fresh(v=2))),
            ("field", h.code_of(fresh(extra=1))),
        ]
        for want, got in refusals:
            self.assertEqual(want, got)
            self.assertEqual(T0, h.guard.floor(), want)
        self.assertEqual("accepted", h.code_of(fresh()))
        self.assertEqual(T0 + 100, h.guard.floor())

    def test_the_floor_is_not_moved_by_a_replay_or_a_full_store_or_a_refused_clock(self):
        h = Harness()
        h.code_of(h.signed(request_id="0" * 32))
        h.clock.set(T0 + 50)
        self.assertEqual("replayed", h.code_of(h.signed(request_id="0" * 32, expires_at=T0 + 400)))
        self.assertEqual(T0, h.guard.floor())
        h.clock.set(T0 - 500)
        self.assertEqual("clock", h.code_of(h.signed(request_id="1" * 32, expires_at=T0 - 200)))
        self.assertEqual(T0, h.guard.floor())
        full = Harness()
        full.guard = replay.ReplayGuard(full.backend, max_markers=1)
        full.code_of(full.signed(request_id="0" * 32))
        full.clock.set(T0 + 10)
        self.assertEqual("store_full", full.code_of(full.signed(request_id="1" * 32, expires_at=T0 + 300)))
        self.assertEqual(T0, full.guard.floor())


class Replays(unittest.TestCase):
    def test_a_second_use_is_replayed_and_a_restart_does_not_help(self):
        h = Harness()
        signed = h.signed()
        h.run(signed.raw, signed.signature)
        self.assertEqual("replayed", h.code_of(signed))
        h.guard = replay.ReplayGuard(h.backend)         # a restart: a new guard over the same store
        self.assertEqual("replayed", h.code_of(signed))
        h.clock.advance(100)
        self.assertEqual("replayed", h.code_of(signed))

    def test_the_request_id_is_the_key(self):
        h = Harness()
        first = h.signed()
        self.assertEqual("accepted", h.code_of(first))
        # same id, another expiry and another operation's worth of members: still the same id
        self.assertEqual("replayed", h.code_of(h.signed(expires_at=T0 + 400)))
        self.assertEqual("replayed", h.code_of(h.signed(expires_at=T0 + 100)))
        # another id is another statement
        self.assertEqual("accepted", h.code_of(h.signed(request_id="1" * 32)))

    def test_independent_statements_do_not_interfere(self):
        h = Harness()
        for n in range(20):
            self.assertEqual("accepted", h.code_of(h.signed(request_id="%032x" % n)))
        self.assertEqual(20, h.guard.marker_count())

    def test_the_store_failing_is_a_store_error(self):
        h = Harness()
        signed = h.signed()
        h.backend.safe = False
        self.assertEqual("store", h.code_of(signed))
        h.backend.safe = True
        h.backend.set_floor_raw(b"garbage")
        self.assertEqual("store", h.code_of(signed))
        h.backend.set_floor_raw(None)

        class Broken(object):
            def claim(self, *args):
                raise MemoryError("no memory for " + helpers.STMT_TARGET)

        self.assertEqual("store", h.code_of(signed, store=Broken()))
        self.assertEqual("store", h.code_of(signed, store=object()))
        self.assertEqual("accepted", h.code_of(signed), "nothing was consumed by the failures")


class Crashes(unittest.TestCase):
    """The process dies at each durable step of the claim: the id is consumed or untouched, never accepted and unrecorded."""

    def crash_at(self, step):
        h = Harness()
        h.backend.fault = replay.crash_at(step)
        signed = h.signed()
        with self.assertRaises(replay.SimulatedCrash):
            h.run(signed.raw, signed.signature)
        h.backend.fault = None
        h.guard = replay.ReplayGuard(h.backend)         # the restart
        return h, signed

    def test_before_the_marker_exists_the_id_is_not_consumed(self):
        h, signed = self.crash_at("create")
        self.assertEqual(0, h.guard.marker_count())
        self.assertEqual(0, h.guard.floor())
        self.assertEqual("accepted", h.code_of(signed))

    def test_once_the_marker_exists_the_id_is_consumed(self):
        for step in ("write", "fsync_file", "fsync_dir", "floor"):
            h, signed = self.crash_at(step)
            self.assertEqual(1, h.guard.marker_count(), step)
            self.assertEqual(0, h.guard.floor(), step)            # the floor is raised after the marker, so a crash left it
            self.assertEqual("replayed", h.code_of(signed), step)

    def test_a_marker_whose_body_was_never_written_still_counts(self):
        h, signed = self.crash_at("write")
        name = replay.marker_name(signed.fields["expires_at"], replay.request_hash(signed.fields["request_id"]))
        self.assertEqual(b"", h.backend.marker_body(name))
        self.assertEqual("replayed", h.code_of(signed))

    def test_success_is_returned_only_after_the_last_durable_step(self):
        h = Harness()
        signed = h.signed()
        h.run(signed.raw, signed.signature)
        self.assertEqual(["create", "write", "fsync_file", "fsync_dir", "floor"], h.backend.steps)
        # a crash at any of those steps means the caller never got a record; the next presentation is accepted only if the
        # marker was never created
        for step in h.backend.steps:
            h2, signed2 = self.crash_at(step)
            self.assertEqual("accepted" if step == "create" else "replayed", h2.code_of(signed2), step)


class ErrorText(unittest.TestCase):
    SENTINELS = ("TARGET-SENTINEL-4f2a", "SCOPE-SENTINEL-77c1", "type.sentinel9", "PARAM-SENTINEL-1d3e", "9f8e7d6c5b4a39281706f5e4d3c2b1a0")

    def errors(self):
        """One error of every code that can carry a value, raised on statements full of sentinel strings."""
        target, scope, kind, param, rid = self.SENTINELS
        h = Harness(types=(kind,), scope=scope, target=target)
        h.params = {"p": param}
        digest = helpers.params_digest(h.params)
        good = dict(type=kind, scope=scope, target=target, request_id=rid, params_hash=digest)
        out = []

        def collect(raw, signature, **kw):
            try:
                h.run(raw, signature, **kw)
            except StatementError as exc:
                out.append(exc)
                return
            raise AssertionError("accepted")

        signed = h.signed(**good)
        collect(signed.raw.replace(b",", b", "), b"x")                                               # noncanonical
        collect(signed.raw, b"\x00" * 32)                                                            # signature
        raw = helpers.canon_bytes(dict(signed.fields, extra=target))
        collect(raw, helpers.sign_raw(h.signer, raw))                                                 # field
        raw = helpers.canon_bytes(dict(signed.fields, v=2, extra=scope))
        collect(raw, helpers.sign_raw(h.signer, raw))                                                 # version
        for other in (h.signed(**dict(good, type=param)), h.signed(**dict(good, scope=param)), h.signed(**dict(good, target=param))):
            collect(other.raw, other.signature)                                                      # type, scope, target
        collect(signed.raw, signed.signature, params={"p": target})                                  # params
        late = h.signed(**dict(good, expires_at=T0 - 1))
        collect(late.raw, late.signature)                                                            # expired
        far = h.signed(**dict(good, expires_at=T0 + 5000))
        collect(far.raw, far.signature)                                                              # ttl
        h.run(signed.raw, signed.signature)
        collect(signed.raw, signed.signature)                                                        # replayed
        collect(b"x" * 3000, b"x")                                                                   # size
        collect(b"\xff" + target.encode(), b"x")                                                     # encoding
        collect(b"[" + target.encode() + b"]", b"x")                                                 # format
        return out

    def test_no_error_text_contains_a_value(self):
        errors = self.errors()
        self.assertGreaterEqual(len({e.code for e in errors}), 12)
        for exc in errors:
            self.assertTrue(exc.__suppress_context__ or exc.__context__ is None, exc.code)
            texts = [str(exc), repr(exc), exc.hint, json.dumps(exc.to_dict()), exc.field, exc.code, str(exc.__cause__)]
            for text in texts:
                for sentinel in self.SENTINELS:
                    self.assertNotIn(sentinel, text, (exc.code, sentinel))

    def test_the_error_is_a_validation_error_with_a_stable_code(self):
        for exc in self.errors():
            self.assertIsInstance(exc, ValidationError)
            self.assertIsInstance(exc, ValueError)
            self.assertEqual("statement", exc.field)
            self.assertIn(exc.code, statement.CODES)
            self.assertTrue(exc.hint)
            self.assertEqual({"field": "statement", "code": exc.code, "hint": exc.hint}, exc.to_dict())

    def test_every_code_has_a_constant_hint(self):
        for code in statement.CODES:
            self.assertEqual(StatementError(code).hint, StatementError(code).hint)
            self.assertTrue(StatementError(code).hint, code)
        self.assertEqual(sorted(statement.CODES), sorted(statement._HINTS))
        self.assertEqual(17, len(statement.CODES))

    def test_the_replay_errors_carry_no_id(self):
        for code in replay.REPLAY_CODES:
            self.assertEqual("replay: " + code, str(replay.ReplayError(code)))


class Expecteds(unittest.TestCase):
    def test_arguments_that_make_no_sense_are_a_value_error(self):
        ok = dict(types=("a",), scope="s", target="t")
        Expected(**ok)
        bad = [dict(types="wifi.join"), dict(types=["a"]), dict(types=()), dict(types=("A",)), dict(types=("a", "a")),
               dict(types=("",)), dict(types=("a" * 33,)), dict(types=(5,)), dict(scope=""), dict(scope="x" * 129),
               dict(scope="\U000000e9"), dict(scope="a\nb"), dict(scope=None), dict(target=""), dict(target="x" * 129),
               dict(target="\x7f"), dict(target=5), dict(max_ttl_s=0), dict(max_ttl_s=86401), dict(max_ttl_s=1.5),
               dict(max_ttl_s=True), dict(max_ttl_s=None), dict(skew_s=-1), dict(skew_s=3601), dict(skew_s=2.0),
               dict(skew_s=False)]
        for over in bad:
            with self.assertRaises(ValueError, msg=repr(over)):
                Expected(**dict(ok, **over))
        Expected(**dict(ok, max_ttl_s=1, skew_s=0))
        Expected(**dict(ok, max_ttl_s=86400, skew_s=3600))

    def test_it_is_frozen(self):
        e = Expected(types=("a",), scope="s", target="t")
        with self.assertRaises(Exception):
            e.target = "u"


class WallClocks(unittest.TestCase):
    def test_the_real_wall_clock_is_whole_seconds_from_time_time(self):
        with mock.patch("time.time", return_value=1790000000.9):
            now = WallClock().now()
        self.assertEqual(1790000000, now)
        self.assertIs(int, type(now))

    def test_the_manual_wall_clock_goes_both_ways_on_purpose(self):
        clock = ManualWallClock(100)
        self.assertEqual(100, clock.now())
        self.assertEqual(105, clock.advance(5))
        self.assertEqual(95, clock.advance(-10))
        self.assertEqual(3, clock.set(3))
        self.assertEqual(0, clock.set(0))
        self.assertEqual(1700000000, ManualWallClock().now())

    def test_the_manual_wall_clock_holds_whole_seconds_only(self):
        for bad in (1.5, "1", None, True):
            with self.assertRaises(TypeError):
                ManualWallClock(bad)
            with self.assertRaises(TypeError):
                ManualWallClock(1).set(bad)
            with self.assertRaises(TypeError):
                ManualWallClock(1).advance(bad)

    def test_the_monotonic_clocks_are_as_they_were(self):
        clock = ManualClock(5.0)
        with self.assertRaises(ValueError):
            clock.advance(-1)
        self.assertIs(float, type(SystemClock().now()))
        with mock.patch("time.monotonic", return_value=12.5):
            self.assertEqual(12.5, SystemClock().now())

    def test_wall_time_appears_only_in_the_wall_clock(self):
        """Elapsed-time code stays monotonic: of the clocks, only WallClock reads time.time()."""
        with mock.patch("time.time", side_effect=AssertionError("time.time was read")):
            SystemClock().now()
            ManualClock().now()
            ManualWallClock().now()


class NewRequestId(unittest.TestCase):
    def test_it_is_32_lowercase_hex_digits_from_16_random_bytes(self):
        self.assertEqual("01" * 16, new_request_id(helpers.ScriptedRng([])))
        rid = new_request_id(helpers.SeededRng(7))
        self.assertEqual(32, len(rid))
        self.assertTrue(all(c in "0123456789abcdef" for c in rid))
        self.assertNotEqual(rid, new_request_id(helpers.SeededRng(8)))

    def test_the_default_source_is_secrets(self):
        with mock.patch.object(auth.secrets, "token_bytes", return_value=bytes(range(16))) as tb:
            self.assertEqual("000102030405060708090a0b0c0d0e0f", new_request_id())
            tb.assert_called_with(16)


def vectors():
    return json.loads(helpers.fixture("statements/vectors.json"))


def assembled(f):
    """The canonical bytes of a statement written out by hand, member by member, in sorted order."""
    return ('{"expires_at":%d,"params_hash":"%s","request_id":"%s","scope":%s,"target":%s,"type":"%s","v":%d}'
            % (f["expires_at"], f["params_hash"], f["request_id"], json.dumps(f["scope"]), json.dumps(f["target"]), f["type"],
               f["v"])).encode("ascii")


class Vectors(unittest.TestCase):
    """Known answers for the other languages that must produce the same bytes (the Portal, a phone)."""

    def test_the_file_describes_itself(self):
        v = vectors()
        self.assertEqual("ci-os-statement-vectors/1", v["format"])
        self.assertEqual(helpers.STMT_NAMESPACE, v["namespace"])
        self.assertEqual(helpers.STMT_PREFIX.hex(), v["signing_prefix_hex"])
        self.assertGreaterEqual(len(v["statements"]), 6)
        self.assertGreaterEqual(len(v["canonical_json"]), 6)
        self.assertGreaterEqual(len(v["rejected"]), 16)
        names = [c["name"] for k in ("statements", "canonical_json", "rejected") for c in v[k]]
        self.assertEqual(len(names), len(set(names)))

    def test_statements(self):
        for case in vectors()["statements"]:
            name, f = case["name"], case["fields"]
            by_hand = assembled(f)
            self.assertEqual(case["canonical_hex"], by_hand.hex(), name)
            self.assertEqual(case["canonical_hex"], canonical_json(f).hex(), name)
            self.assertEqual(case["canonical_hex"], canonical_statement(f).hex(), name)
            self.assertEqual(case["signing_sha256"], hashlib.sha256(helpers.STMT_PREFIX + by_hand).hexdigest(), name)
            self.assertEqual(case["params_canonical_hex"], canonical_json(case["params"]).hex(), name)
            self.assertEqual(case["params_hash"], hashlib.sha256(bytes.fromhex(case["params_canonical_hex"])).hexdigest(), name)
            self.assertEqual(case["params_hash"], params_hash(case["params"]), name)
            self.assertEqual(case["params_hash"], f["params_hash"], name)

    def test_canonical_json_values(self):
        for case in vectors()["canonical_json"]:
            self.assertEqual(case["canonical_hex"], canonical_json(case["value"]).hex(), case["name"])

    def test_every_statement_in_the_file_verifies(self):
        for case in vectors()["statements"]:
            f = case["fields"]
            h = Harness(types=(f["type"],), scope=f["scope"], target=f["target"])
            h.params = case["params"]
            h.clock.set(max(f["expires_at"] - 300, 0))
            raw = bytes.fromhex(case["canonical_hex"])
            self.assertEqual("accepted", h.code(raw, helpers.sign_raw(h.signer, raw)), case["name"])

    def test_the_bytes_that_must_be_refused_and_where(self):
        for case in vectors()["rejected"]:
            h = Harness()
            raw = bytes.fromhex(case["raw_hex"])
            self.assertEqual(case["code"], h.code_structure(raw), case["name"])
            self.assertTrue(h.untouched(), case["name"])


class SelfTestVectors(unittest.TestCase):
    def test_the_embedded_case_is_in_the_file(self):
        embedded = selftest._STATEMENT_CASE
        in_file = [c for c in vectors()["statements"] if c["name"] == "typical"][0]
        self.assertEqual(in_file["fields"], embedded["fields"])
        self.assertEqual(in_file["params"], embedded["params"])
        self.assertEqual(bytes.fromhex(in_file["canonical_hex"]).decode("ascii"), embedded["canonical"])
        self.assertEqual(in_file["signing_sha256"], embedded["signing_sha256"])

    def test_the_check_runs_and_is_registered(self):
        names = [n for n, _ in selftest.CHECKS]
        self.assertIn("statements and replay", names)
        selftest.check_statements()


if __name__ == "__main__":
    unittest.main()
