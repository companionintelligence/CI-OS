"""Operation-bound owner statements: a signed approval of ONE operation on ONE target with ONE set of parameters.

A library only: nothing in the setup service calls it yet. The service redesign (known issue KI-02) and the identity daemon are its
intended users. What it does: decide, from the bytes of a statement, the signature that came with it and what the caller is about
to do, whether the owner approved exactly that, once. What it does not do: sign anything. The signature scheme is injected
(``verifier.verify(namespace, message, signature) -> bool``) and none ships here.

A statement is a JSON object with exactly these members (anything else is refused):

    v           the integer 1
    type        the kind of operation, 1 to 32 characters from a-z 0-9 . _ - (the caller gives the list it accepts)
    request_id  32 lowercase hex digits (128 random bits from :func:`new_request_id`); the key of the replay guard
    scope       1 to 128 printable ASCII characters; must equal what the verifier expects for itself (a device key thumbprint)
    target      1 to 128 printable ASCII characters; must equal what the caller is about to act on
    params_hash 64 lowercase hex digits: SHA-256 of the canonical JSON of the parameters the caller is about to apply
    expires_at  whole seconds since the epoch, 1 to 999999999999

so an approval for one operation on one target with one parameter set cannot be used for another.

Canonical JSON (:func:`canonical_json`) is the one encoding that is hashed and signed. Members sorted by key, no space anywhere,
ASCII only. A string uses the short escapes for quote, backslash, backspace, tab, newline, form feed and carriage return, and for
every other character outside 0x20 to 0x7E (DEL included) a backslash, the letter u and four lowercase hex digits of the UTF-16
code unit, so a character above U+FFFF is a surrogate pair. Numbers are integers with absolute value at most 2**53 - 1 (what a
JavaScript number holds exactly); there are no floats, no NaN, no exponents. ``true``, ``false`` and ``null`` are allowed in
parameters but never in a member that is a number. Member names are ASCII. Nesting is at most 8 deep. A received statement is
accepted only if its bytes equal the canonical encoding of what they parse to, so there is exactly one byte string for one
statement. The bytes a signature covers are the 18 bytes ``ci-os-statement/1`` and a newline, followed by those bytes, and the
verifier is called with the namespace ``ci-os-statement@ci.computer``, so a login proof and an operation statement can never
stand in for each other. Known answers for other languages: ``tests/ci_setup/fixtures/statements/vectors.json``.

:func:`verify_statement` runs these steps in this order, and the first failure ends it with a :class:`StatementError` whose
``code`` names the step. Nothing unauthenticated has an effect: the signature is checked on the exact bytes before any member is
given a meaning, and nothing is written until every check has passed.

    size          more than 2048 bytes
    encoding      a byte above 0x7F
    format        not JSON, a duplicate member, NaN or Infinity, a number longer than 30 characters, not an object
    noncanonical  the bytes differ from the canonical encoding of what they parse to (a space, another order, a float ...)
    signature     the injected verifier says no (or raises, or the signature is not 1 to 1024 bytes)
    version       ``v`` is an integer but not 1 (judged first, whatever else the object holds: another version may have other members)
    field         the members are not exactly the seven above, or one has the wrong type or shape
    type scope target params   the statement is not for this operation, scope, target or parameter set (``params`` is compared
                  with ``consteq``)
    expired       ``now >= expires_at``
    ttl           ``expires_at - now > max_ttl_s + skew_s``; with a clock far behind, a far-future expiry fails closed here
    clock         the clock reading is not a whole number of seconds, or it is behind the replay floor by more than ``skew_s``
    replayed store store_full   the replay guard (replay.py): already used, the store failed, the store is full

A statement that fails any step before the last three does not consume its ``request_id``: presenting a valid statement with
the wrong parameters cannot burn it. On success the result is a frozen :class:`VerifiedStatement`; the caller then acts; if the
action fails it needs a new statement (at most once). Error texts are constant: they never contain the statement, the target, the
scope, the id or the parameters.

``now`` is a wall clock (``clock.WallClock``, or ``ManualWallClock`` in tests): an expiry is an absolute time that the signer chose.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Dict, Optional, Tuple

from .auth import SystemRng, consteq
from .errors import ValidationError
from .replay import MAX_TIME, ReplayError
from .validators import loads_strict

VERSION = 1
NAMESPACE = "ci-os-statement@ci.computer"
SIGNING_PREFIX = b"ci-os-statement/1\n"
MAX_STATEMENT_BYTES = 2048
MAX_PARAMS_BYTES = 65536
MAX_SIGNATURE_BYTES = 1024
MAX_DEPTH = 8
MAX_INT = 2 ** 53 - 1
DEFAULT_MAX_TTL_S = 600
DEFAULT_SKEW_S = 120
MAX_TTL_CEILING_S = 86400
MAX_SKEW_CEILING_S = 3600

FIELDS = ("v", "type", "request_id", "scope", "target", "params_hash", "expires_at")
FIELD_SET = frozenset(FIELDS)
CODES = ("size", "encoding", "format", "noncanonical", "signature", "version", "field", "type", "scope", "target", "params",
         "expired", "ttl", "clock", "replayed", "store", "store_full")

_LOWER_HEX = frozenset("0123456789abcdef")
_TYPE_CHARS = frozenset("abcdefghijklmnopqrstuvwxyz0123456789._-")
_HINTS = {
    "size": "statement too large", "encoding": "statement is not ASCII", "format": "statement is not a JSON object",
    "noncanonical": "statement is not in canonical form", "signature": "signature check failed",
    "field": "statement members are wrong", "version": "statement version is not supported",
    "type": "statement is for another kind of operation", "scope": "statement is for another scope",
    "target": "statement is for another target", "params": "statement does not cover these parameters",
    "expired": "statement has expired", "ttl": "statement expiry is too far away", "clock": "the clock cannot be trusted",
    "replayed": "statement was already used", "store": "replay store failure", "store_full": "replay store is full",
}


class StatementError(ValidationError):
    """A statement was refused. ``code`` is one of :data:`CODES`. The text is constant: it never contains the statement, its
    target, its scope, its id or the parameters."""

    def __init__(self, code: str, hint: Optional[str] = None) -> None:
        super().__init__("statement", code, hint if hint is not None else _HINTS.get(code, ""))


# --------------------------------------------------------------------------------------------------------------------
# canonical JSON
# --------------------------------------------------------------------------------------------------------------------


def _check_tree(obj: Any, depth: int) -> None:
    """Refuse everything canonical JSON does not have: floats, other types, non-text or non-ASCII member names, text that is not
    Unicode (a lone surrogate), integers beyond 2**53 - 1, nesting beyond MAX_DEPTH."""
    t = type(obj)
    if obj is None or t is bool:
        return
    if t is int:
        if not -MAX_INT <= obj <= MAX_INT:
            raise StatementError("format")
        return
    if t is str:
        try:
            obj.encode("utf-8")
        except UnicodeEncodeError:
            raise StatementError("format") from None
        return
    if t is list or t is tuple:
        if depth >= MAX_DEPTH:
            raise StatementError("format")
        for item in obj:
            _check_tree(item, depth + 1)
        return
    if t is dict:
        if depth >= MAX_DEPTH:
            raise StatementError("format")
        for key, item in obj.items():
            if type(key) is not str or not key.isascii():
                raise StatementError("format")
            _check_tree(item, depth + 1)
        return
    raise StatementError("format")


def canonical_json(obj: Any, max_bytes: Optional[int] = None) -> bytes:
    """The canonical encoding of ``obj`` (see the module text) as ASCII bytes. Raises :class:`StatementError` (``format``) for a
    value canonical JSON cannot hold, and ``size`` if the result is longer than ``max_bytes``."""
    _check_tree(obj, 0)
    try:
        text = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    except (TypeError, ValueError, RecursionError):
        raise StatementError("format") from None
    data = text.encode("ascii")
    if max_bytes is not None and len(data) > max_bytes:
        raise StatementError("size")
    return data


def params_hash(params: Any) -> str:
    """SHA-256, as 64 lowercase hex digits, of the canonical JSON of the parameters the caller is about to apply. Raises
    :class:`StatementError` (``params``) if they cannot be written canonically or are larger than 64 KiB."""
    try:
        data = canonical_json(params, MAX_PARAMS_BYTES)
    except StatementError:
        raise StatementError("params") from None
    return hashlib.sha256(data).hexdigest()


def new_request_id(rng: Any = None) -> str:
    """A fresh request id: 128 random bits as 32 lowercase hex digits, from the injected source (default: ``secrets``)."""
    source = rng if rng is not None else SystemRng()
    return bytes(source.token_bytes(16)).hex()


# --------------------------------------------------------------------------------------------------------------------
# the members
# --------------------------------------------------------------------------------------------------------------------


def _is_int(value: Any) -> bool:
    return type(value) is int and -MAX_INT <= value <= MAX_INT


def _is_hex(value: Any, length: int) -> bool:
    return type(value) is str and len(value) == length and all(c in _LOWER_HEX for c in value)


def _is_text(value: Any, max_len: int) -> bool:
    return type(value) is str and 1 <= len(value) <= max_len and all(0x20 <= ord(c) <= 0x7E for c in value)


def _is_type_name(value: Any) -> bool:
    return type(value) is str and 1 <= len(value) <= 32 and all(c in _TYPE_CHARS for c in value)


def _check_fields(obj: Dict[str, Any]) -> None:
    """The members of a statement: ``v`` first (an integer that is not 1 is a version this code does not speak, whatever else
    the object holds), then exactly the seven members, each of the right shape."""
    version = obj.get("v")
    if not _is_int(version):
        raise StatementError("field")
    if version != VERSION:
        raise StatementError("version")
    if set(obj) != FIELD_SET:
        raise StatementError("field")
    shapes = (_is_type_name(obj["type"]), _is_hex(obj["request_id"], 32), _is_text(obj["scope"], 128),
              _is_text(obj["target"], 128), _is_hex(obj["params_hash"], 64),
              _is_int(obj["expires_at"]) and 1 <= obj["expires_at"] <= MAX_TIME)
    if not all(shapes):
        raise StatementError("field")


def canonical_statement(fields: Any) -> bytes:
    """The canonical bytes of a statement given as a dict: the form that is signed and sent. It checks the members exactly as the
    verifier does, so a signer cannot make a statement this code would refuse for its shape. Raises :class:`StatementError`."""
    if type(fields) is not dict:
        raise StatementError("format")
    _check_fields(fields)
    return canonical_json(fields, MAX_STATEMENT_BYTES)


# --------------------------------------------------------------------------------------------------------------------
# what the caller expects, and what comes back
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Expected:
    """What the caller will accept: the statement types it allows, the scope it expects for itself, the target it is about to act
    on, and the lifetime policy (a statement may live at most ``max_ttl_s`` plus ``skew_s`` seconds ahead of the clock; the clock may
    be behind the replay floor by at most ``skew_s``). A wrong argument is a programming error and raises ValueError."""

    types: Tuple[str, ...]
    scope: str
    target: str
    max_ttl_s: int = DEFAULT_MAX_TTL_S
    skew_s: int = DEFAULT_SKEW_S

    def __post_init__(self) -> None:
        types_ok = type(self.types) is tuple and bool(self.types) and all(_is_type_name(t) for t in self.types)
        if not types_ok or len(set(self.types)) != len(self.types):
            raise ValueError("types must be a non-empty tuple of distinct statement type names")
        if not _is_text(self.scope, 128):
            raise ValueError("scope must be 1 to 128 printable ASCII characters")
        if not _is_text(self.target, 128):
            raise ValueError("target must be 1 to 128 printable ASCII characters")
        if type(self.max_ttl_s) is not int or not 1 <= self.max_ttl_s <= MAX_TTL_CEILING_S:
            raise ValueError("max_ttl_s must be an integer from 1 to %d" % MAX_TTL_CEILING_S)
        if type(self.skew_s) is not int or not 0 <= self.skew_s <= MAX_SKEW_CEILING_S:
            raise ValueError("skew_s must be an integer from 0 to %d" % MAX_SKEW_CEILING_S)


@dataclass(frozen=True)
class VerifiedStatement:
    """A statement that passed every step and whose id is now consumed."""

    type: str
    request_id: str
    scope: str
    target: str
    params_hash: str
    expires_at: int


# --------------------------------------------------------------------------------------------------------------------
# the steps, in the order verify_statement runs them
# --------------------------------------------------------------------------------------------------------------------


def _statement_bytes(raw: Any) -> bytes:
    if not isinstance(raw, (bytes, bytearray)):
        raise StatementError("format")
    data = bytes(raw)
    if len(data) > MAX_STATEMENT_BYTES:
        raise StatementError("size")
    if not data.isascii():
        raise StatementError("encoding")
    return data


def _parse_object(data: bytes) -> Dict[str, Any]:
    try:
        obj = loads_strict(data)
    except ValidationError:
        raise StatementError("format") from None
    if type(obj) is not dict:
        raise StatementError("format")
    return obj


def _require_canonical(obj: Dict[str, Any], data: bytes) -> None:
    try:
        canonical = canonical_json(obj)
    except StatementError:
        raise StatementError("noncanonical") from None
    if canonical != data:
        raise StatementError("noncanonical")


def _signature_ok(verifier: Any, message: bytes, signature: Any) -> bool:
    if not isinstance(signature, (bytes, bytearray)) or not 1 <= len(signature) <= MAX_SIGNATURE_BYTES:
        return False
    try:
        return verifier.verify(NAMESPACE, message, bytes(signature)) is True
    except Exception:  # an injected object: whatever it raises, the answer is no
        return False


def _check_signature(verifier: Any, data: bytes, signature: Any) -> None:
    if not _signature_ok(verifier, SIGNING_PREFIX + data, signature):
        raise StatementError("signature")


def _check_type(obj: Dict[str, Any], expected: Expected) -> None:
    if obj["type"] not in expected.types:
        raise StatementError("type")


def _check_scope(obj: Dict[str, Any], expected: Expected) -> None:
    if not consteq(obj["scope"], expected.scope):
        raise StatementError("scope")


def _check_target(obj: Dict[str, Any], expected: Expected) -> None:
    if not consteq(obj["target"], expected.target):
        raise StatementError("target")


def _check_params(obj: Dict[str, Any], params: Any) -> None:
    if not consteq(obj["params_hash"], params_hash(params)):
        raise StatementError("params")


def _read_clock(now: Any) -> int:
    try:
        reading = now.now()
    except Exception:  # an injected object: a clock that fails cannot be trusted
        raise StatementError("clock") from None
    if type(reading) is not int or not 0 <= reading <= MAX_TIME:
        raise StatementError("clock")
    return reading


def _check_time(obj: Dict[str, Any], t: int, expected: Expected) -> None:
    if t >= obj["expires_at"]:
        raise StatementError("expired")
    if obj["expires_at"] - t > expected.max_ttl_s + expected.skew_s:
        raise StatementError("ttl")


def _claim(store: Any, obj: Dict[str, Any], t: int, expected: Expected) -> None:
    try:
        store.claim(obj["request_id"], obj["expires_at"], t, expected.max_ttl_s, expected.skew_s)
    except ReplayError as exc:
        raise StatementError(exc.code) from None
    except Exception:  # an injected object: whatever it raises, nothing was claimed that we can rely on
        raise StatementError("store") from None


def verify_statement(raw: Any, signature: Any, *, verifier: Any, expected: Expected, params: Any, now: Any,
                     store: Any) -> VerifiedStatement:
    """Decide whether ``raw`` (the bytes of a statement) with ``signature`` is the owner's approval of what the caller is about to
    do, and consume it. ``verifier`` has ``verify(namespace, message, signature) -> bool``; ``expected`` is an :class:`Expected`;
    ``params`` are the parameters about to be applied (anything canonical JSON can hold); ``now`` is a wall clock; ``store`` is a
    ``replay.ReplayGuard``. Returns a :class:`VerifiedStatement`. Raises :class:`StatementError` and nothing else for any
    input (see the module text for the order of the steps and the codes)."""
    data = _statement_bytes(raw)
    obj = _parse_object(data)
    _require_canonical(obj, data)
    _check_signature(verifier, data, signature)
    _check_fields(obj)
    _check_type(obj, expected)
    _check_scope(obj, expected)
    _check_target(obj, expected)
    _check_params(obj, params)
    t = _read_clock(now)
    _check_time(obj, t, expected)
    _claim(store, obj, t, expected)
    return VerifiedStatement(type=obj["type"], request_id=obj["request_id"], scope=obj["scope"], target=obj["target"],
                             params_hash=obj["params_hash"], expires_at=obj["expires_at"])
