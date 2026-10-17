"""Credentials of the setup session: the AP key, the PIN, API tokens and the limits on guessing.

Three secrets, three jobs (report 02, section 4.1):

* the **AP key** - 12 characters from a 31-symbol alphabet without look-alikes (about 59 bits), new for every AP session,
  from the ``secrets`` module. It is the Wi-Fi passphrase and is shown only on the console or the Wi-Fi QR code;
* the **PIN** - 6 digits, new per session, valid 10 minutes, the thing a person types into the portal;
* the **API token** - what a successful PIN buys: 128 bits of session id, signed with HMAC-SHA256, bound to the client's
  address, expiring (sliding, with an absolute cap).

Guessing is limited by :class:`AttemptLimiter`, a state machine with an injected clock: exponential back-off between
attempts, a lockout per client, and PIN rotation after a handful of failures overall, so a PIN is never worth more than a
few guesses. Every comparison of a secret goes through :func:`consteq` (``hmac.compare_digest``).

Nothing here reads a clock or a random source by itself: both are arguments (default: monotonic clock and ``secrets``).
"""
from __future__ import annotations

import hmac
import secrets
import threading
from dataclasses import asdict, dataclass
from hashlib import sha256
from typing import Any, Dict, Iterator, List, Optional, Tuple

from .clock import SystemClock
from .errors import ValidationError

AP_KEY_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"      # 31 symbols: no I, L, O, 0, 1
AP_KEY_LEN = 12
PIN_LEN = 6
DIGITS = "0123456789"
SETUP_KEY_LEN = 16
SSID_SUFFIX_LEN = 4

# 31 ** 12 candidates: log2 = 59.45
AP_KEY_BITS = 59.45


class SystemRng:
    """The default random source: the operating system's CSPRNG through ``secrets``."""

    def randbelow(self, n: int) -> int:
        return secrets.randbelow(n)

    def token_bytes(self, n: int) -> bytes:
        return secrets.token_bytes(n)


def _rng(rng: Any) -> Any:
    return rng if rng is not None else SystemRng()


def consteq(a: Any, b: Any) -> bool:
    """Constant-time equality for secrets. Accepts ``str`` or ``bytes`` (text is compared as UTF-8); anything else, or
    text that cannot be encoded, is simply not equal. Never raises."""
    try:
        if isinstance(a, str):
            a = a.encode("utf-8")
        if isinstance(b, str):
            b = b.encode("utf-8")
        if not isinstance(a, (bytes, bytearray)) or not isinstance(b, (bytes, bytearray)):
            return False
        return hmac.compare_digest(bytes(a), bytes(b))
    except (UnicodeError, TypeError, ValueError):
        return False


# --------------------------------------------------------------------------------------------------------------------
# generation
# --------------------------------------------------------------------------------------------------------------------


def generate_ap_key(rng: Any = None) -> str:
    """A fresh AP key: 12 symbols, each chosen uniformly (``randbelow`` rejects the biased range)."""
    r = _rng(rng)
    n = len(AP_KEY_ALPHABET)
    return "".join(AP_KEY_ALPHABET[r.randbelow(n)] for _ in range(AP_KEY_LEN))


def generate_pin(rng: Any = None) -> str:
    """A fresh PIN: six decimal digits, leading zeros included."""
    r = _rng(rng)
    return "".join(DIGITS[r.randbelow(10)] for _ in range(PIN_LEN))


def generate_setup_key(rng: Any = None) -> str:
    """A printable per-unit setup key: 16 symbols of the AP-key alphabet (about 79 bits)."""
    r = _rng(rng)
    n = len(AP_KEY_ALPHABET)
    return "".join(AP_KEY_ALPHABET[r.randbelow(n)] for _ in range(SETUP_KEY_LEN))


def format_setup_key(key: str) -> str:
    """``ABCD-EFGH-JKMN-PQRS`` for printing."""
    return "-".join(key[i:i + 4] for i in range(0, len(key), 4))


def normalize_setup_key(text: Any) -> str:
    """Strip dashes, spaces and case from a typed setup key and check it: 16 symbols of the alphabet. Look-alike
    characters (0, 1, I, L, O) are not in the alphabet and are refused, not guessed at."""
    if not isinstance(text, str) or len(text) > 40:
        raise ValidationError("setup_key", "format", "not a setup key")
    key = "".join(c for c in text if c not in "- \t").upper()
    if len(key) != SETUP_KEY_LEN or any(c not in AP_KEY_ALPHABET for c in key):
        raise ValidationError("setup_key", "format", "not a setup key")
    return key


def is_valid_ap_key(text: Any) -> bool:
    return isinstance(text, str) and len(text) == AP_KEY_LEN and all(c in AP_KEY_ALPHABET for c in text)


def _stream_symbols(blocks: Iterator[bytes], alphabet: str, n: int) -> str:
    """Turn a stream of pseudo-random bytes into ``n`` symbols without modulo bias: a byte at or above the largest
    multiple of the alphabet size that fits in 256 is skipped."""
    size = len(alphabet)
    limit = 256 - (256 % size)
    out = []  # type: List[str]
    for block in blocks:
        for byte in block:
            if byte < limit:
                out.append(alphabet[byte % size])
                if len(out) == n:
                    return "".join(out)
    raise ValueError("stream exhausted")  # 64 blocks of 32 bytes make this unreachable for n <= 16


def _hmac_blocks(key: bytes, label: bytes) -> Iterator[bytes]:
    for counter in range(64):
        yield hmac.new(key, label + b"\x00" + counter.to_bytes(4, "big"), sha256).digest()


@dataclass(frozen=True)
class LabelCredentials:
    ap_key: str
    pin: str
    ssid_suffix: str

    def to_dict(self) -> Dict[str, str]:
        """Not for logs: it holds the secrets. Used by the CLI's ``--show-secrets`` style tools and tests only."""
        return asdict(self)


def derive_credentials(setup_key: str) -> LabelCredentials:
    """The AP key, PIN and SSID suffix of a unit with a printed setup key: ``HMAC-SHA256(setup_key, label)`` expanded
    with a counter and mapped to symbols without bias. Deterministic, so the label and the unit agree with no
    state; the setup key must be replaced after the first claim (that is the caller's job)."""
    key = normalize_setup_key(setup_key).encode("ascii")
    return LabelCredentials(
        ap_key=_stream_symbols(_hmac_blocks(key, b"ci-setup/ap-key"), AP_KEY_ALPHABET, AP_KEY_LEN),
        pin=_stream_symbols(_hmac_blocks(key, b"ci-setup/pin"), DIGITS, PIN_LEN),
        ssid_suffix=_stream_symbols(_hmac_blocks(key, b"ci-setup/ssid-suffix"), AP_KEY_ALPHABET, SSID_SUFFIX_LEN))


# --------------------------------------------------------------------------------------------------------------------
# tokens
# --------------------------------------------------------------------------------------------------------------------

_HEXCH = frozenset("0123456789abcdef")
_DIGITCH = frozenset("0123456789")


@dataclass(frozen=True)
class TokenInfo:
    session_id: str
    client: str
    issued_s: float
    expires_s: float
    remaining_s: float


class TokenIssuer:
    """Issues and verifies bearer tokens for one AP session.

    A token is ``v1.<session id>.<issued ms>.<expires ms>.<mac>`` where the MAC is HMAC-SHA256 over those fields and the
    client identifier (the client's IP address) under a key that exists only for this session. Verification recomputes
    the MAC with the *presented* client identifier, so a token used from another address, or altered in any field, fails;
    the comparison is constant-time. A token is valid until ``expires``; :meth:`refresh` moves it forward by ``ttl_s``
    but never beyond ``issued + max_lifetime_s``. Revoked sessions stay revoked.
    """

    MAX_TOKEN_LEN = 200

    def __init__(self, key: bytes, clock: Any = None, ttl_s: float = 900.0, max_lifetime_s: float = 2700.0,
                 rng: Any = None, max_revoked: int = 256) -> None:
        if not isinstance(key, (bytes, bytearray)) or len(key) < 16:
            raise ValueError("the session key must be at least 16 bytes")
        self._key = bytes(key)
        self.clock = clock if clock is not None else SystemClock()
        self.ttl_s = float(ttl_s)
        self.max_lifetime_s = float(max_lifetime_s)
        self._rng = _rng(rng)
        self._revoked = []  # type: List[str]
        self._max_revoked = max_revoked

    @classmethod
    def new_session(cls, clock: Any = None, rng: Any = None, **kw: Any) -> "TokenIssuer":
        """An issuer with a fresh 32-byte key."""
        r = _rng(rng)
        return cls(r.token_bytes(32), clock=clock, rng=r, **kw)

    # -- encoding
    def _mac(self, sid: str, issued_ms: int, expires_ms: int, client: str) -> bytes:
        msg = ("v1|%s|%d|%d|%s" % (sid, issued_ms, expires_ms, client)).encode("utf-8", "replace")
        return hmac.new(self._key, msg, sha256).digest()

    def _encode(self, sid: str, issued_ms: int, expires_ms: int, client: str) -> str:
        return "v1.%s.%d.%d.%s" % (sid, issued_ms, expires_ms, self._mac(sid, issued_ms, expires_ms, client).hex())

    @staticmethod
    def _parse(token: Any) -> Optional[Tuple[str, int, int, bytes]]:
        if not isinstance(token, str) or not 20 <= len(token) <= TokenIssuer.MAX_TOKEN_LEN:
            return None
        parts = token.split(".")
        if len(parts) != 5 or parts[0] != "v1":
            return None
        sid, issued, expires, mac = parts[1], parts[2], parts[3], parts[4]
        if len(sid) != 32 or not all(c in _HEXCH for c in sid):
            return None
        for num in (issued, expires):
            if not 1 <= len(num) <= 15 or not all(c in _DIGITCH for c in num):
                return None
        if len(mac) != 64 or not all(c in _HEXCH for c in mac):
            return None
        return sid, int(issued), int(expires), bytes.fromhex(mac)

    # -- API
    def issue(self, client: str) -> str:
        """A new token for ``client`` (an address string), valid for ``ttl_s``."""
        now_ms = int(self.clock.now() * 1000)
        sid = self._rng.token_bytes(16).hex()
        return self._encode(sid, now_ms, now_ms + int(self.ttl_s * 1000), str(client))

    def verify(self, token: Any, client: str) -> Optional[TokenInfo]:
        """The :class:`TokenInfo` if the token is genuine, unexpired, unrevoked and presented by the client it was issued
        to; otherwise None (no reason is given: callers must not tell a guesser which part failed)."""
        parsed = self._parse(token)
        if parsed is None:
            return None
        sid, issued_ms, expires_ms, mac = parsed
        expected = self._mac(sid, issued_ms, expires_ms, str(client))
        if not consteq(expected, mac):
            return None
        now_ms = int(self.clock.now() * 1000)
        if now_ms >= expires_ms or issued_ms > now_ms + 1000 or sid in self._revoked:
            return None
        if expires_ms - issued_ms > int(self.max_lifetime_s * 1000):
            return None
        return TokenInfo(session_id=sid, client=str(client), issued_s=issued_ms / 1000.0,
                         expires_s=expires_ms / 1000.0, remaining_s=(expires_ms - now_ms) / 1000.0)

    def refresh(self, token: Any, client: str) -> Optional[str]:
        """Slide the expiry of a valid token forward by ``ttl_s`` (never past ``issued + max_lifetime_s``) and return
        the new token, or None if the old one is not valid."""
        info = self.verify(token, client)
        if info is None:
            return None
        issued_ms = int(info.issued_s * 1000)
        now_ms = int(self.clock.now() * 1000)
        expires_ms = min(now_ms + int(self.ttl_s * 1000), issued_ms + int(self.max_lifetime_s * 1000))
        if expires_ms <= now_ms:
            return None
        return self._encode(info.session_id, issued_ms, expires_ms, str(client))

    def revoke(self, token: Any, client: str) -> bool:
        info = self.verify(token, client)
        if info is None:
            return False
        if info.session_id not in self._revoked:
            self._revoked.append(info.session_id)
            del self._revoked[:-self._max_revoked]
        return True


# --------------------------------------------------------------------------------------------------------------------
# guessing limits
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class LimiterPolicy:
    max_failures_per_client: int = 3       # then that client is locked out
    max_failures_global: int = 5           # then the PIN is rotated
    lockout_s: float = 300.0
    backoff_base_s: float = 1.0            # wait after the 1st failure; doubles per failure
    backoff_cap_s: float = 30.0
    forget_after_s: float = 900.0          # failures older than this are forgotten
    max_clients: int = 64                  # bound on the state kept


@dataclass(frozen=True)
class Verdict:
    allowed: bool
    reason: str                            # ok, backoff, locked
    retry_after_s: float = 0.0


@dataclass(frozen=True)
class FailureOutcome:
    rotate_pin: bool
    locked: bool
    retry_after_s: float


class AttemptLimiter:
    """Limits guesses of a secret. State: per client the number of failures, the time before which it must not try again
    (back-off) and until when it is locked out; overall the number of failures since the last rotation. Time comes from
    ``clock.now()``; nothing else is read."""

    def __init__(self, clock: Any = None, policy: Optional[LimiterPolicy] = None) -> None:
        self.clock = clock if clock is not None else SystemClock()
        self.policy = policy or LimiterPolicy()
        self._clients = {}  # type: Dict[str, Dict[str, float]]
        self._global_failures = 0
        self._global_last = 0.0
        self.rotations = 0

    def _expire(self, now: float) -> None:
        p = self.policy
        for cid in [c for c, st in self._clients.items()
                    if st["locked_until"] <= now and now - st["last"] > p.forget_after_s]:
            del self._clients[cid]
        if self._global_failures and now - self._global_last > p.forget_after_s:
            self._global_failures = 0

    def check(self, client: str) -> Verdict:
        now = self.clock.now()
        self._expire(now)
        st = self._clients.get(client)
        if st is None:
            return Verdict(True, "ok")
        if st["locked_until"] > now:
            return Verdict(False, "locked", st["locked_until"] - now)
        if st["next_allowed"] > now:
            return Verdict(False, "backoff", st["next_allowed"] - now)
        return Verdict(True, "ok")

    def record_failure(self, client: str) -> FailureOutcome:
        now = self.clock.now()
        p = self.policy
        self._expire(now)
        if client not in self._clients and len(self._clients) >= p.max_clients:
            oldest = min(self._clients, key=lambda c: self._clients[c]["last"])
            del self._clients[oldest]
        st = self._clients.setdefault(client, {"failures": 0.0, "next_allowed": 0.0, "locked_until": 0.0, "last": now})
        st["failures"] += 1
        st["last"] = now
        wait = min(p.backoff_cap_s, p.backoff_base_s * (2 ** min(int(st["failures"]) - 1, 30)))
        st["next_allowed"] = now + wait
        locked = False
        if st["failures"] >= p.max_failures_per_client:
            st["locked_until"] = now + p.lockout_s
            st["failures"] = 0.0
            st["next_allowed"] = 0.0
            locked, wait = True, p.lockout_s
        self._global_failures += 1
        self._global_last = now
        rotate = self._global_failures >= p.max_failures_global
        if rotate:
            self._global_failures = 0
            self.rotations += 1
        return FailureOutcome(rotate_pin=rotate, locked=locked, retry_after_s=wait)

    def record_success(self, client: str) -> None:
        self._clients.pop(client, None)
        self._global_failures = 0

    def snapshot(self) -> Dict[str, Any]:
        """Counters only (no client addresses): safe to put in a status page."""
        now = self.clock.now()
        self._expire(now)
        return {"clients_tracked": len(self._clients),
                "clients_locked": sum(1 for st in self._clients.values() if st["locked_until"] > now),
                "global_failures": self._global_failures, "rotations": self.rotations}


# --------------------------------------------------------------------------------------------------------------------
# PIN gate: PIN + limiter + token issuer
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class GateResult:
    status: str                            # ok, wrong, locked, backoff, expired, rotated
    token: Optional[str] = None
    retry_after_s: float = 0.0
    pin_rotated: bool = False              # the console must show the new PIN

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["token"] = "<redacted>" if self.token else None
        return d


class PinGate:
    """The PIN prompt of the portal. ``attempt(client, guess)`` is the only way in; it never reveals the PIN, applies the
    limits first, rotates the PIN on expiry or on too many failures overall, and on success returns a token."""

    def __init__(self, clock: Any = None, rng: Any = None, issuer: Optional[TokenIssuer] = None,
                 limiter: Optional[AttemptLimiter] = None, pin_ttl_s: float = 600.0,
                 pin: Optional[str] = None) -> None:
        self.clock = clock if clock is not None else SystemClock()
        self._rng = _rng(rng)
        self.issuer = issuer if issuer is not None else TokenIssuer.new_session(self.clock, self._rng)
        self.limiter = limiter if limiter is not None else AttemptLimiter(self.clock)
        self.pin_ttl_s = float(pin_ttl_s)
        self._lock = threading.Lock()
        self._pin = pin if pin is not None else generate_pin(self._rng)
        self._pin_born = self.clock.now()
        self.pin_generation = 1

    def current_pin(self) -> str:
        """For the console banner only."""
        return self._pin

    def _rotate(self) -> None:
        self._pin = generate_pin(self._rng)
        self._pin_born = self.clock.now()
        self.pin_generation += 1

    def attempt(self, client: str, guess: Any) -> GateResult:
        with self._lock:
            now = self.clock.now()
            if now - self._pin_born >= self.pin_ttl_s:
                self._rotate()
                return GateResult("expired", pin_rotated=True)
            verdict = self.limiter.check(client)
            if not verdict.allowed:
                return GateResult(verdict.reason, retry_after_s=verdict.retry_after_s)
            well_formed = isinstance(guess, str) and len(guess) == PIN_LEN and all(c in _DIGITCH for c in guess)
            if well_formed and consteq(guess, self._pin):
                self.limiter.record_success(client)
                return GateResult("ok", token=self.issuer.issue(client))
            out = self.limiter.record_failure(client)
            if out.rotate_pin:
                self._rotate()
                return GateResult("rotated", retry_after_s=out.retry_after_s, pin_rotated=True)
            return GateResult("locked" if out.locked else "wrong", retry_after_s=out.retry_after_s)

