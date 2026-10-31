"""The replay guard: an approval can be used once, even across restarts, and a clock that goes backwards cannot revive one.

``ReplayGuard`` is the logic. It works over a *backend* that holds the durable state, so the same rules can be proved on an
in-memory stand-in (:class:`MemoryBackend`, here) and later on a directory. Nothing in this file opens a file, starts a process
or reads the clock: the caller passes the time in, and the backend is an argument.

The state is one *marker* per consumed request id, named ``<expiry as 12 digits>-<sha256 of the request id>``, and one number,
the clock *floor*: the latest time at which a statement was accepted. The rules (each has a test, and where a wrong line would
be a vulnerability, a planted bug in mutation_check.py):

* The claim is durable before the operation runs. :meth:`ReplayGuard.claim` returns only after ``create_marker`` and
  ``write_floor`` have returned. A crash before that leaves the id consumed (the marker exists) or untouched, never accepted
  and unrecorded.
* A marker is found by the hash of the request id: any name that ends in ``-<hash>`` means consumed, whatever its expiry digits
  or its body.
* A damaged marker stays consumed. Existence is the signal; the body is never read for the decision. An empty or garbled file (a
  crash between create and write, a bad disk) must never turn into "not used".
* The floor is raised to ``now`` only when a statement is accepted, so only the holder of the signing key can move it. A claim
  with ``now < floor - skew_s`` fails with ``clock``: the clock went backwards (a restored snapshot, a reset real-time clock).
* A marker is purged only when ``expiry + skew_s + max_ttl_s < floor``, using the persisted floor and never the current clock, so
  a later jump of the clock backwards cannot bring back a statement whose marker is gone.
* At most 4096 markers. At the bound the guard purges first and then refuses with ``store_full``: it fails closed.
* Any failure of the backend is ``store``. Nothing is guessed, nothing is repaired on the way.

The backend is an object with these methods (a backend that writes files implements the same ones, in a module of its own):

    lock()                 a context manager, exclusive for a whole claim
    check_safe()           raise StoreError if the store is not safe to use
    list_markers()         the names of all markers, as a list of str
    create_marker(name)    create the marker exclusively; return only when it is durable; raise MarkerExists if it is there
    remove_marker(name)    remove a marker; a missing one is not an error
    read_floor()           the persisted floor as an int (0 if it was never raised); raise StoreError if it is damaged
    write_floor(value)     replace the floor atomically and durably

Errors carry a stable code (``clock``, ``replayed``, ``store``, ``store_full``) and a constant text; they never contain the
request id.
"""
from __future__ import annotations

import hashlib
import threading
from typing import Any, Callable, Dict, List, Optional

from .errors import CiSetupError

MAX_MARKERS = 4096
MAX_TIME = 999999999999            # twelve digits: the expiry in a marker name has a fixed width
MARKER_BODY = b"ci-replay/1\n"     # informational; no decision ever reads it
REPLAY_CODES = ("clock", "replayed", "store", "store_full")

_LOWER_HEX = frozenset("0123456789abcdef")
_DIGITS = frozenset("0123456789")
_NAME_LEN = 12 + 1 + 64


class ReplayError(CiSetupError):
    """A claim was refused. ``code`` is one of :data:`REPLAY_CODES`; the text is constant."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__("replay: " + code)


class StoreError(CiSetupError):
    """A backend cannot do what was asked, or finds its store unsafe, lost or damaged. The guard turns it into ``store``."""


class MarkerExists(CiSetupError):
    """``create_marker`` found the name already there (an exclusive create lost): the id is consumed."""


class SimulatedCrash(BaseException):
    """Raised by a fault hook to model the process dying at a durable step. A BaseException on purpose: nothing in the guard may
    catch it and carry on."""


# --------------------------------------------------------------------------------------------------------------------
# names and the floor
# --------------------------------------------------------------------------------------------------------------------


def request_hash(request_id: str) -> str:
    """SHA-256 of the request id as 64 lowercase hex digits: what identifies a marker."""
    return hashlib.sha256(request_id.encode("ascii")).hexdigest()


def marker_name(expires_at: int, digest: str) -> str:
    """``<expiry as 12 digits>-<digest>``: the expiry is in the name, so a marker is purged by name even when its body is gone."""
    return "%012d-%s" % (expires_at, digest)


def marker_expiry(name: Any) -> Optional[int]:
    """The expiry in a well-formed marker name (12 digits, a dash, 64 lowercase hex digits); None for any other name."""
    if type(name) is not str or len(name) != _NAME_LEN or name[12] != "-":
        return None
    if not all(c in _DIGITS for c in name[:12]) or not all(c in _LOWER_HEX for c in name[13:]):
        return None
    return int(name[:12])


def encode_floor(value: int) -> bytes:
    """The bytes of the floor file: decimal ASCII and one newline."""
    return b"%d\n" % value


def decode_floor(raw: Any) -> int:
    """The floor from the bytes of its file: ASCII digits without leading zeros and one newline, nothing else. Raises
    :class:`StoreError` for anything else (empty, garbled, truncated, a sign, a space)."""
    if not isinstance(raw, (bytes, bytearray)) or not 2 <= len(raw) <= 13 or raw[-1:] != b"\n":
        raise StoreError("the floor is damaged")
    digits = bytes(raw[:-1])
    if not all(48 <= b <= 57 for b in digits) or (len(digits) > 1 and digits[0] == 48):
        raise StoreError("the floor is damaged")
    return int(digits)


def _check_claim_args(request_id: Any, expires_at: Any, now: Any, max_ttl_s: Any, skew_s: Any) -> None:
    if type(request_id) is not str or len(request_id) != 32 or not all(c in _LOWER_HEX for c in request_id):
        raise ValueError("request_id must be 32 lowercase hex digits")
    for value in (expires_at, now, max_ttl_s, skew_s):
        if type(value) is not int or not 0 <= value <= MAX_TIME:
            raise ValueError("expires_at, now, max_ttl_s and skew_s must be integers from 0 to %d" % MAX_TIME)


def _persisted_floor(backend: Any) -> int:
    value = backend.read_floor()
    if type(value) is not int or not 0 <= value <= MAX_TIME:
        raise StoreError("the backend returned a bad floor")
    return value


def _listing(backend: Any) -> List[str]:
    names = backend.list_markers()
    if type(names) is not list or not all(type(n) is str for n in names):
        raise StoreError("the backend returned a bad listing")
    return names


# --------------------------------------------------------------------------------------------------------------------
# the guard
# --------------------------------------------------------------------------------------------------------------------


class ReplayGuard:
    """Makes each request id single-use over a backend. The backend is the only state; the guard holds none, so a restart is a
    new guard over the same backend."""

    def __init__(self, backend: Any, max_markers: int = MAX_MARKERS) -> None:
        if type(max_markers) is not int or not 1 <= max_markers <= MAX_MARKERS:
            raise ValueError("max_markers must be an integer from 1 to %d" % MAX_MARKERS)
        self._backend = backend
        self.max_markers = max_markers

    def claim(self, request_id: str, expires_at: int, now: int, max_ttl_s: int, skew_s: int) -> str:
        """Consume ``request_id`` and return the name of its marker. ``now`` is the caller's wall-clock reading in whole seconds;
        ``expires_at`` the expiry of the statement; ``max_ttl_s`` and ``skew_s`` the lifetime policy.

        Under the backend's lock: the store must be safe; ``now`` must not be behind the floor by more than ``skew_s``
        (``clock``); an id that is already consumed is ``replayed`` (the marker is found by the hash, never by its expiry or its
        body); markers that no statement can need are purged by the persisted floor; at the bound the answer is ``store_full``;
        then the marker is created (durable on return) and only then is the floor raised to ``now`` if that is higher.
        A refused claim changes nothing except the purge. Raises :class:`ReplayError`; a ``ValueError`` means a programming error
        in the arguments."""
        _check_claim_args(request_id, expires_at, now, max_ttl_s, skew_s)
        digest = request_hash(request_id)
        name = marker_name(expires_at, digest)
        backend = self._backend
        try:
            with backend.lock():
                backend.check_safe()
                floor = _persisted_floor(backend)
                if now < floor - skew_s:
                    raise ReplayError("clock")
                names = _listing(backend)
                if any(n.endswith("-" + digest) for n in names):
                    raise ReplayError("replayed")
                live = self._purge(names, floor, max_ttl_s, skew_s)
                if live >= self.max_markers:
                    raise ReplayError("store_full")
                try:
                    backend.create_marker(name)
                except MarkerExists:
                    raise ReplayError("replayed") from None
                if now > floor:
                    backend.write_floor(now)
        except ReplayError:
            raise
        except Exception:
            raise ReplayError("store") from None
        return name

    def _purge(self, names: List[str], floor: int, max_ttl_s: int, skew_s: int) -> int:
        """Remove the markers that no statement can need any more and return how many names are left. A statement is accepted
        only while ``now < expiry`` and ``now >= floor - skew_s``, and the floor never goes down, so once ``floor - skew_s`` has
        reached the expiry nothing can accept it again; the extra ``max_ttl_s`` is slack. A name that is not well formed has no
        provable expiry and stays."""
        remaining = len(names)
        for n in names:
            expiry = marker_expiry(n)
            if expiry is not None and expiry + skew_s + max_ttl_s < floor:
                self._backend.remove_marker(n)
                remaining -= 1
        return remaining

    def floor(self) -> int:
        """The persisted floor (0 if it was never raised). Raises ReplayError (``store``) if it cannot be read."""
        try:
            with self._backend.lock():
                self._backend.check_safe()
                return _persisted_floor(self._backend)
        except Exception:
            raise ReplayError("store") from None

    def marker_count(self) -> int:
        """How many names the store holds (well formed or not). Raises ReplayError (``store``)."""
        try:
            with self._backend.lock():
                self._backend.check_safe()
                return len(_listing(self._backend))
        except Exception:
            raise ReplayError("store") from None


# --------------------------------------------------------------------------------------------------------------------
# the in-memory backend
# --------------------------------------------------------------------------------------------------------------------


def crash_at(step: str, skip: int = 0) -> Callable[[str], None]:
    """A fault hook for :class:`MemoryBackend`: raises :class:`SimulatedCrash` the (``skip`` + 1)th time ``step`` is reached."""
    seen = [0]

    def hook(name: str) -> None:
        if name == step:
            if seen[0] >= skip:
                raise SimulatedCrash(step)
            seen[0] += 1
    return hook


class MemoryBackend:
    """A backend that keeps its state in memory: the reference for the rules, and the stand-in for the tests and the self-test.

    Creating a marker goes through the durable steps a directory would have: ``create`` (the name appears, empty), ``write`` (the
    body), ``fsync_file``, ``fsync_dir``. Removing one is ``remove``, replacing the floor is ``floor``. ``fault`` is called with
    the name of each step just BEFORE it takes effect, so a test can stop the sequence there by raising
    :class:`SimulatedCrash` (see :func:`crash_at`); ``steps`` lists the steps that took effect. The model keeps everything that
    was written: it stops a sequence, it does not lose data. ``safe`` False makes ``check_safe`` fail, as an unsafe directory would.
    """

    STEPS = ("create", "write", "fsync_file", "fsync_dir", "remove", "floor")

    def __init__(self, fault: Optional[Callable[[str], None]] = None) -> None:
        self.fault = fault
        self.safe = True
        self.steps = []  # type: List[str]
        self._markers = {}  # type: Dict[str, bytes]
        self._floor_raw = None  # type: Optional[bytes]
        self._lock = threading.Lock()

    def _step(self, step: str) -> None:
        if self.fault is not None:
            self.fault(step)
        self.steps.append(step)

    # -- the backend interface
    def lock(self) -> Any:
        return self._lock

    def check_safe(self) -> None:
        if not self.safe:
            raise StoreError("the store is not safe to use")

    def list_markers(self) -> List[str]:
        return sorted(self._markers)

    def create_marker(self, name: str) -> None:
        if name in self._markers:
            raise MarkerExists(name)
        self._step("create")
        self._markers[name] = b""
        self._step("write")
        self._markers[name] = MARKER_BODY
        self._step("fsync_file")
        self._step("fsync_dir")

    def remove_marker(self, name: str) -> None:
        self._step("remove")
        self._markers.pop(name, None)

    def read_floor(self) -> int:
        if self._floor_raw is None:
            return 0
        return decode_floor(self._floor_raw)

    def write_floor(self, value: int) -> None:
        self._step("floor")
        self._floor_raw = encode_floor(value)

    # -- for tests: look at the state and damage it
    def marker_body(self, name: str) -> Optional[bytes]:
        return self._markers.get(name)

    def put_marker(self, name: str, body: bytes = MARKER_BODY) -> None:
        """Plant a marker as it would be found after a crash or a bad disk (no step, no fault)."""
        self._markers[name] = bytes(body)

    def set_floor_raw(self, raw: Optional[bytes]) -> None:
        """Plant the content of the floor file (None: the file does not exist)."""
        self._floor_raw = None if raw is None else bytes(raw)
