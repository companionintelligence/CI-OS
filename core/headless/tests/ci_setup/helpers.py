"""Shared helpers for the ci_setup tests: fixtures, golden files, a seeded random source, fuzz sizes.

Python 3.8 or newer, standard library only. The tests find the package through PYTHONPATH (run.sh sets it); if it is not
importable the repository's core/headless is added, so ``python3 -m unittest`` from the tests directory also works.
"""
import collections
import hashlib
import hmac
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HEADLESS = os.path.normpath(os.path.join(HERE, "..", ".."))
FIXTURES = os.path.join(HERE, "fixtures")
GOLDEN = os.path.join(HERE, "golden")

try:
    import ci_setup  # noqa: F401
except ImportError:  # pragma: no cover - direct invocation without PYTHONPATH
    sys.path.insert(0, HEADLESS)
    import ci_setup  # noqa: F401


def fixture(rel):
    """Text of a fixture file (path relative to fixtures/)."""
    with open(os.path.join(FIXTURES, rel), "r", encoding="utf-8") as fh:
        return fh.read()


def fixture_path(rel):
    return os.path.join(FIXTURES, rel)


def golden_check(testcase, name, actual):
    """Compare ``actual`` text with golden/<name>. With CI_SETUP_UPDATE_GOLDEN=1 the file is (re)written instead; review
    the diff before committing it."""
    path = os.path.join(GOLDEN, name)
    if os.environ.get("CI_SETUP_UPDATE_GOLDEN") == "1":
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(actual)
        return
    if not os.path.exists(path):
        testcase.fail("golden file missing: %s (run with CI_SETUP_UPDATE_GOLDEN=1 and review it)" % name)
    with open(path, "r", encoding="utf-8") as fh:
        expected = fh.read()
    testcase.assertEqual(expected, actual, "golden file %s differs (CI_SETUP_UPDATE_GOLDEN=1 rewrites it)" % name)


def to_json(obj):
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def fuzz_n(default):
    """Number of fuzz cases: ``CI_SETUP_FUZZ_N`` overrides every suite's default (run.sh --quick sets it low)."""
    try:
        return int(os.environ.get("CI_SETUP_FUZZ_N", default))
    except ValueError:
        return default


def fuzz_seed():
    try:
        return int(os.environ.get("CI_SETUP_FUZZ_SEED", "1"))
    except ValueError:
        return 1


class SeededRng(object):
    """A deterministic stand-in for the random source of ci_setup.auth. NOT secure; tests only."""

    def __init__(self, seed=1):
        self._r = random.Random(seed)
        self.calls = []

    def randbelow(self, n):
        self.calls.append(n)
        return self._r.randrange(n)

    def token_bytes(self, n):
        return bytes(self._r.randrange(256) for _ in range(n))


class ScriptedRng(object):
    """Returns the scripted values of randbelow in turn (and zero bytes for token_bytes)."""

    def __init__(self, values):
        self.values = list(values)
        self.calls = []

    def randbelow(self, n):
        self.calls.append(n)
        v = self.values.pop(0)
        assert 0 <= v < n
        return v

    def token_bytes(self, n):
        return b"\x01" * n


# an alphabet of the characters that break validators and parsers
NASTY = (
    [chr(c) for c in range(0x20, 0x7F)]
    + ["\x00", "\x01", "\x07", "\x08", "\t", "\n", "\x0b", "\x0c", "\r", "\x1b", "\x7f", "\x80", "\x85", "\x9f"]
    + ["\U000000a0", "\U000000ad", "\U0000061c", "\U0000180e", "\U0000200b", "\U0000200c", "\U0000200d", "\U0000200e", "\U0000200f", "\U00002028", "\U00002029",
       "\U0000202a", "\U0000202e", "\U00002060", "\U00002066", "\U00002069", "\U0000feff", "\U0000fffd", "\U0000ffff"]
    + ["\U000000e9", "\U000020ac", "\U00000663", "\U0000ff11", "\U0000212a", "\U00004e2d", "\U0001f600", "\U0001f468\U0000200d\U0001f469",
       "\ud800", "\udfff"]
    + ["\\", ";", ":", ",", '"', "'", "`", "$", "(", ")", "{", "}", "|", "&", "<", ">", "%", "#", "=", "@"]
)


def rand_text(rnd, max_len=40):
    return "".join(rnd.choice(NASTY) for _ in range(rnd.randint(0, max_len)))


# --------------------------------------------------------------------------------------------------------------------
# owner statements (statement.py, replay.py)
# --------------------------------------------------------------------------------------------------------------------

# Restated here on purpose: a test must not follow a changed constant of the module it tests.
STMT_NAMESPACE = "ci-os-statement@ci.computer"
STMT_PREFIX = b"ci-os-statement/1\n"
STMT_T0 = 1790000000
STMT_TYPE = "wifi.join"
STMT_REQUEST_ID = "00112233445566778899aabbccddeeff"
STMT_SCOPE = "device-key-thumbprint-0001"
STMT_TARGET = "wifi:home-network"
STMT_PARAMS = {"security": "wpa2", "ssid": "Home Net"}


class HmacStandInVerifier(object):
    """TEST ONLY. Stands in for the signature scheme that the identity daemon will supply: HMAC-SHA256 over the namespace, a NUL
    byte and the message, under a key that signer and verifier share. A MAC is not a signature (whoever can verify can also sign)
    and nothing outside the tests may use this. What the tests need from a scheme is that it binds the namespace and every byte of
    the message, and this does. The key is derived at run time from a label; it protects nothing."""

    def __init__(self, label=b"TEST-ONLY ci_setup statement stand-in"):
        self._key = hashlib.sha256(label).digest()
        self.calls = []

    def sign(self, namespace, message):
        return hmac.new(self._key, namespace.encode("utf-8") + b"\x00" + bytes(message), hashlib.sha256).digest()

    def verify(self, namespace, message, signature):
        self.calls.append((namespace, bytes(message), bytes(signature)))
        return hmac.compare_digest(self.sign(namespace, message), bytes(signature))


class AcceptAllVerifier(object):
    """TEST ONLY. Says yes to every signature, to show that a refusal comes from the structure of the statement and not from the
    signature check."""

    def verify(self, namespace, message, signature):
        return True


def canon_bytes(value):
    """Canonical JSON written with the standard library only (not with ci_setup), so a test does not rely on the code it tests."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def params_digest(params):
    return hashlib.sha256(canon_bytes(params)).hexdigest()


OMIT = object()    # as the value of a member in statement_fields / make_statement: leave the member out


def statement_fields(**over):
    """The members of a valid statement for the standard harness, with ``over`` applied (a member set to OMIT is left out)."""
    fields = {"v": 1, "type": STMT_TYPE, "request_id": STMT_REQUEST_ID, "scope": STMT_SCOPE, "target": STMT_TARGET,
              "params_hash": params_digest(STMT_PARAMS), "expires_at": STMT_T0 + 300}
    fields.update(over)
    return {k: v for k, v in fields.items() if v is not OMIT}


Signed = collections.namedtuple("Signed", "raw signature fields")


def sign_raw(signer, raw, namespace=STMT_NAMESPACE):
    return signer.sign(namespace, STMT_PREFIX + bytes(raw))


def make_statement(signer, namespace=STMT_NAMESPACE, **over):
    """A signed statement (canonical bytes, signature, members). ``over`` replaces members; a member set to OMIT is left out."""
    fields = statement_fields(**over)
    raw = canon_bytes(fields)
    return Signed(raw, sign_raw(signer, raw, namespace), fields)
