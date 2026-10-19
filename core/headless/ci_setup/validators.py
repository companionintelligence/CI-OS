"""Input validators for everything that can reach nmcli, hostapd, dnsmasq, nftables, a file name or a log line.

One module, used by the portal API, the provisioning file (``companion-setup.json`` on CI-SHARED) and the CLI,
so a value is judged by the same rules wherever it comes from. The rules follow IEEE 802.11 and the Linux kernel,
not what is convenient:

* An SSID is 1 to 32 OCTETS (not characters) of UTF-8 here, without control characters.
* A WPA2/WPA3 personal passphrase is 8 to 63 printable ASCII characters, or exactly 64 hexadecimal digits (the raw
  pre-shared key).
* An interface name is at most 15 bytes (IFNAMSIZ is 16 with the terminating NUL).

Every validator takes exactly one kind of input, checks its type first, bounds the length BEFORE doing anything that
costs time proportional to it, and returns the (possibly normalised) value or raises :class:`ValidationError`. The
error never contains the rejected value (it may be a secret). Nothing here uses ``str.isdigit``, ``\\d``, ``$`` or
``str.isalnum``: they accept non-ASCII digits and a trailing newline, which is how validators get bypassed.
"""
from __future__ import annotations

import json
import unicodedata
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from .errors import ValidationError

# --------------------------------------------------------------------------------------------------------------------
# character classes
# --------------------------------------------------------------------------------------------------------------------

_HEXDIGITS = frozenset("0123456789abcdefABCDEF")
_DIGITS = frozenset("0123456789")
_LOWER_HEX = frozenset("0123456789abcdef")
_LOWER_ALNUM = frozenset("abcdefghijklmnopqrstuvwxyz0123456789")
_ASCII_LETTERS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
_IFNAME_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

# Format characters that reorder or hide text. They are how an SSID is made to look like another one on a phone
# screen, so they are never accepted anywhere in a name we display.
_BIDI_CONTROLS = frozenset(
    ["\U0000061c", "\U0000200e", "\U0000200f", "\U0000202a", "\U0000202b", "\U0000202c", "\U0000202d", "\U0000202e",
     "\U00002066", "\U00002067", "\U00002068", "\U00002069"])
# Zero-width and invisible characters: accepted inside a name (a ZWJ is part of emoji sequences) but not at its ends,
# where they only exist to make two names look identical.
_INVISIBLE_EDGE = frozenset(["\U000000ad", "\U0000180e", "\U0000200b", "\U0000200c", "\U0000200d", "\U00002060", "\U0000feff"])


def _fail(field: str, code: str, hint: Optional[str] = None) -> "ValidationError":
    return ValidationError(field, code, hint)


def _need_text(value: Any, field: str, max_chars: int, min_chars: int = 1) -> str:
    """Type and cheap length checks shared by every text validator."""
    if not isinstance(value, str):
        raise _fail(field, "type", "must be text")
    n = len(value)
    if n < min_chars:
        raise _fail(field, "empty" if min_chars == 1 else "length", "too short")
    if n > max_chars:
        # cheap rejection before any per-character work, so a megabyte of input costs nothing
        raise _fail(field, "length", "too long")
    return value


def has_control_char(text: str) -> bool:
    """True if ``text`` contains NUL, a newline or any other control character (C0, DEL, C1) or a line/paragraph
    separator."""
    for ch in text:
        o = ord(ch)
        if o < 0x20 or 0x7F <= o <= 0x9F or o in (0x2028, 0x2029):
            return True
    return False


# --------------------------------------------------------------------------------------------------------------------
# SSID and passphrase
# --------------------------------------------------------------------------------------------------------------------

SSID_MAX_BYTES = 32
PSK_MIN = 8
PSK_MAX = 63
PSK_HEX_LEN = 64


def ssid_bytes(ssid: str) -> bytes:
    """The octets that go on the air for an already validated SSID."""
    return ssid.encode("utf-8")


def validate_ssid(value: Any, field: str = "ssid") -> str:
    """1 to 32 octets of UTF-8, no control or bidi characters, not blank, no invisible character at either end.

    The length is counted in BYTES: eight 4-byte emoji fit, nine do not, and ``len()`` alone would admit all nine.
    Leading and trailing ordinary spaces are legal 802.11 and accepted (see :func:`ssid_hints`).
    """
    s = _need_text(value, field, SSID_MAX_BYTES)  # characters <= bytes, so > 32 characters can never fit
    try:
        raw = s.encode("utf-8", "strict")  # a lone surrogate raises here
    except UnicodeEncodeError:
        raise _fail(field, "encoding", "not valid UTF-8") from None
    if not 1 <= len(raw) <= SSID_MAX_BYTES:
        raise _fail(field, "length", "must be 1 to 32 bytes")
    if has_control_char(s):
        raise _fail(field, "control_char", "control characters are not allowed")
    for ch in s:
        if ch in _BIDI_CONTROLS:
            raise _fail(field, "bidi_char", "direction control characters are not allowed")
        if unicodedata.category(ch) in ("Cs", "Zl", "Zp"):
            raise _fail(field, "control_char", "separator characters are not allowed")
    if s[0] in _INVISIBLE_EDGE or s[-1] in _INVISIBLE_EDGE:
        raise _fail(field, "invisible_edge", "invisible character at an end")
    if all(ch.isspace() for ch in s):
        raise _fail(field, "blank", "must contain a visible character")
    return s


def ssid_hints(ssid: str) -> List[str]:
    """Non-fatal observations about a valid SSID, for the UI ("did you type a trailing space?")."""
    hints = []  # type: List[str]
    if ssid != ssid.strip(" "):
        hints.append("leading_or_trailing_space")
    if not all(ord(c) < 0x80 for c in ssid):
        hints.append("non_ascii")
    if len(ssid.encode("utf-8")) == SSID_MAX_BYTES:
        hints.append("max_length")
    return hints


def is_hex64(value: str) -> bool:
    return len(value) == PSK_HEX_LEN and all(c in _HEXDIGITS for c in value)


def validate_psk(value: Any, field: str = "psk") -> str:
    """8 to 63 printable ASCII characters (0x20 to 0x7e), or exactly 64 hex digits (a raw PSK).

    A 64 character string is accepted only when it is entirely hexadecimal; a 64 character passphrase is invalid
    (the limit is 63), which is why :func:`psk_kind` is unambiguous.
    """
    p = _need_text(value, field, PSK_HEX_LEN)
    n = len(p)
    if n == PSK_HEX_LEN:
        if not all(c in _HEXDIGITS for c in p):
            raise _fail(field, "format", "64 characters must all be hex digits")
        return p
    if n < PSK_MIN:
        raise _fail(field, "length", "must be 8 to 63 characters, or 64 hex digits")
    for ch in p:
        if not 0x20 <= ord(ch) <= 0x7E:
            raise _fail(field, "charset", "printable ASCII only")
    return p


def psk_kind(value: str) -> str:
    """``"pmk_hex"`` for 64 hex digits, otherwise ``"passphrase"``. Call only on a validated value."""
    return "pmk_hex" if len(value) == PSK_HEX_LEN else "passphrase"


# --------------------------------------------------------------------------------------------------------------------
# hostname, country, MAC, PIN, ids, ports, channels
# --------------------------------------------------------------------------------------------------------------------

def validate_hostname(value: Any, field: str = "hostname", allow_fqdn: bool = False) -> str:
    """RFC 1123 host name, returned in lower case.

    One label of 1 to 63 characters from a-z, 0-9 and hyphen, not starting or ending with a hyphen. A name made only of
    digits is refused (it reads as an address). With ``allow_fqdn`` dotted names up to 253 characters are accepted;
    a trailing dot is not. Upper case is accepted and lowered; non-ASCII input is refused before lowering, because
    ``str.lower`` maps a few non-ASCII characters (the Kelvin sign) onto ASCII ones.
    """
    h = _need_text(value, field, 253 if allow_fqdn else 63)
    if not all(ord(c) < 0x80 for c in h):
        raise _fail(field, "charset", "ASCII only")
    h = h.lower()
    labels = h.split(".") if allow_fqdn else [h]
    for label in labels:
        if not 1 <= len(label) <= 63:
            raise _fail(field, "length", "each label must be 1 to 63 characters")
        if label[0] == "-" or label[-1] == "-":
            raise _fail(field, "format", "a label cannot start or end with a hyphen")
        for ch in label:
            if ch not in _LOWER_ALNUM and ch != "-":
                raise _fail(field, "charset", "letters, digits and hyphen only")
    if all(all(c in _DIGITS for c in label) for label in labels):
        raise _fail(field, "format", "must not be made only of digits")
    return h


def validate_country(value: Any, field: str = "country") -> str:
    """Two ASCII letters (ISO 3166-1 alpha-2 shape), returned in upper case. Whether the code is a real country is
    decided by :func:`ci_setup.regdom.is_known_country`; the special regulatory codes ``00`` and friends are not
    countries and are rejected here."""
    c = _need_text(value, field, 2, 2)
    if not all(ch in _ASCII_LETTERS for ch in c):
        raise _fail(field, "format", "two ASCII letters")
    return c.upper()


def validate_mac(value: Any, field: str = "mac", unicast: bool = True) -> str:
    """Six hex octets separated by ':' or '-', returned as lower-case ``aa:bb:cc:dd:ee:ff``.

    With ``unicast`` (the default) the all-zero, broadcast and any multicast address is refused.
    """
    m = _need_text(value, field, 17, 17)
    sep = m[2]
    if sep not in ":-":
        raise _fail(field, "format", "octets must be separated by ':' or '-'")
    parts = m.split(sep)
    if len(parts) != 6:
        raise _fail(field, "format", "six octets")
    octets = []
    for part in parts:
        if len(part) != 2 or not all(c in _HEXDIGITS for c in part):
            raise _fail(field, "format", "each octet is two hex digits")
        octets.append(int(part, 16))
    if unicast and (octets[0] & 1 or not any(octets)):
        raise _fail(field, "range", "not a unicast station address")
    return ":".join("%02x" % o for o in octets)


def validate_pin(value: Any, field: str = "pin", length: int = 6) -> str:
    """Exactly ``length`` ASCII digits (leading zeros count)."""
    p = _need_text(value, field, length, length)
    if not all(c in _DIGITS for c in p):
        raise _fail(field, "format", "digits only")
    return p


def validate_job_id(value: Any, field: str = "job_id") -> str:
    """The identifiers this package hands out: 8 to 64 lower-case hex digits."""
    j = _need_text(value, field, 64, 8)
    if not all(c in _LOWER_HEX for c in j):
        raise _fail(field, "format", "lower-case hex")
    return j


def validate_port(value: Any, field: str = "port", minimum: int = 1) -> int:
    if type(value) is not int:  # bool is an int subclass and must not pass
        raise _fail(field, "type", "must be an integer")
    if not minimum <= value <= 65535:
        raise _fail(field, "range", "out of range")
    return value


def validate_channel(value: Any, band: str, field: str = "channel") -> int:
    """A channel number valid for the band: 1-14 (2.4 GHz), 32-177 (5 GHz), 1-233 (6 GHz)."""
    if type(value) is not int:
        raise _fail(field, "type", "must be an integer")
    limits = {"2.4": (1, 14), "5": (32, 177), "6": (1, 233)}
    if band not in limits:
        raise _fail(field, "format", "unknown band")
    lo, hi = limits[band]
    if not lo <= value <= hi:
        raise _fail(field, "range", "out of range")
    return value


# --------------------------------------------------------------------------------------------------------------------
# interface names
# --------------------------------------------------------------------------------------------------------------------

IFNAME_MAX = 15


def validate_ifname(value: Any, field: str = "ifname") -> str:
    """A network interface name safe to put on a command line, in a config file and in an nftables string.

    The kernel only forbids '/', whitespace, ':' and "." / ".." (``dev_valid_name``); this is stricter: 1 to 15
    characters from ``A-Za-z0-9_.-``, starting with a letter or digit. 15 because IFNAMSIZ counts the NUL.
    """
    n = _need_text(value, field, IFNAME_MAX)
    if n[0] in "_.-":
        raise _fail(field, "format", "must start with a letter or digit")
    if not all(c in _IFNAME_CHARS for c in n):
        raise _fail(field, "charset", "letters, digits, '_', '.' and '-' only")
    # UTF-8 bytes == characters here because the charset is ASCII; len(n) <= 15 therefore also bounds the bytes
    return n


def validate_phy_name(value: Any, field: str = "phy") -> str:
    """``phy0`` ... ``phy9999``."""
    p = _need_text(value, field, 7, 4)
    if not p.startswith("phy") or not all(c in _DIGITS for c in p[3:]):
        raise _fail(field, "format", "phyN")
    return p


# --------------------------------------------------------------------------------------------------------------------
# IPv4
# --------------------------------------------------------------------------------------------------------------------

def parse_ipv4(value: Any, field: str = "ipv4") -> int:
    """Strict dotted quad to an integer: four decimal fields 0..255, no sign, no spaces, no leading zeros, ASCII
    digits only. (The standard library's ``ipaddress`` accepted leading zeros in some 3.8/3.9 point releases, where
    they can mean octal; a parser of our own removes the question.)"""
    s = _need_text(value, field, 15, 7)
    parts = s.split(".")
    if len(parts) != 4:
        raise _fail(field, "format", "a.b.c.d")
    out = 0
    for part in parts:
        if not 1 <= len(part) <= 3 or not all(c in _DIGITS for c in part):
            raise _fail(field, "format", "decimal octets")
        if len(part) > 1 and part[0] == "0":
            raise _fail(field, "format", "no leading zeros")
        octet = int(part, 10)
        if octet > 255:
            raise _fail(field, "range", "octet above 255")
        out = (out << 8) | octet
    return out


def format_ipv4(n: int) -> str:
    if not 0 <= n <= 0xFFFFFFFF:
        raise ValueError("not an IPv4 integer")
    return "%d.%d.%d.%d" % ((n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255)


def validate_ipv4(value: Any, field: str = "ipv4") -> str:
    return format_ipv4(parse_ipv4(value, field))


_PRIVATE_BLOCKS = ((0x0A000000, 8), (0xAC100000, 12), (0xC0A80000, 16))  # 10/8, 172.16/12, 192.168/16


def is_rfc1918(addr: int) -> bool:
    for net, prefix in _PRIVATE_BLOCKS:
        mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF
        if addr & mask == net:
            return True
    return False


@dataclass(frozen=True)
class Ipv4Net:
    """An IPv4 network: ``network`` is the integer network address, ``prefix`` the prefix length."""

    network: int
    prefix: int

    @property
    def mask(self) -> int:
        return (0xFFFFFFFF << (32 - self.prefix)) & 0xFFFFFFFF

    @property
    def size(self) -> int:
        return 1 << (32 - self.prefix)

    @property
    def last(self) -> int:
        return self.network + self.size - 1

    def address(self, offset: int) -> int:
        if not 0 <= offset < self.size:
            raise ValueError("offset outside the network")
        return self.network + offset

    def contains(self, addr: int) -> bool:
        return addr & self.mask == self.network

    def overlaps(self, other: "Ipv4Net") -> bool:
        return self.network <= other.last and other.network <= self.last

    def cidr(self) -> str:
        return "%s/%d" % (format_ipv4(self.network), self.prefix)

    def netmask_str(self) -> str:
        return format_ipv4(self.mask)

    def to_dict(self) -> Dict[str, Any]:
        return {"cidr": self.cidr(), "netmask": self.netmask_str()}


def parse_cidr(value: Any, field: str = "subnet", strict: bool = True) -> Ipv4Net:
    """``a.b.c.d/n``. With ``strict`` (default) the host bits must be zero."""
    s = _need_text(value, field, 18, 9)
    if s.count("/") != 1:
        raise _fail(field, "format", "a.b.c.d/n")
    addr_s, pre_s = s.split("/")
    if not 1 <= len(pre_s) <= 2 or not all(c in _DIGITS for c in pre_s) or (len(pre_s) > 1 and pre_s[0] == "0"):
        raise _fail(field, "format", "prefix length")
    prefix = int(pre_s, 10)
    if not 0 <= prefix <= 32:
        raise _fail(field, "range", "prefix length")
    addr = parse_ipv4(addr_s, field)
    mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF
    if strict and addr & ~mask & 0xFFFFFFFF:
        raise _fail(field, "format", "host bits are set")
    return Ipv4Net(addr & mask, prefix)


def validate_ipv4_subnet(value: Any, field: str = "subnet", min_prefix: int = 8, max_prefix: int = 30,
                         private_only: bool = True) -> Ipv4Net:
    """A network address in CIDR form that an access point may serve: aligned, RFC 1918 unless told otherwise,
    and between /8 and /30 (a /31 or /32 has no room for a gateway and a client)."""
    net = parse_cidr(value, field, strict=True)
    if not min_prefix <= net.prefix <= max_prefix:
        raise _fail(field, "range", "prefix length outside the allowed range")
    if private_only and not (is_rfc1918(net.network) and is_rfc1918(net.last)):
        raise _fail(field, "range", "must be a private (RFC 1918) network")
    return net


# --------------------------------------------------------------------------------------------------------------------
# strict JSON
# --------------------------------------------------------------------------------------------------------------------

def _no_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    out = {}  # type: Dict[str, Any]
    for key, val in pairs:
        if key in out:
            raise ValueError("duplicate key")
        out[key] = val
    return out


def _no_constants(name: str) -> Any:
    raise ValueError("non-finite number")


def _bounded_int(text: str) -> int:
    # Python before 3.11 converts a 60000-digit integer without complaint (and slowly); an API has no use for one
    if len(text) > 30:
        raise ValueError("number too long")
    return int(text)


def _bounded_float(text: str) -> float:
    if len(text) > 30:
        raise ValueError("number too long")
    return float(text)


def loads_strict(data: Any, max_bytes: int = 65536, field: str = "body") -> Any:
    """Parse JSON the way an API should: bounded size, valid UTF-8, no duplicate keys, no NaN or Infinity, no number longer than 30 characters,
    bounded nesting. Any failure is a :class:`ValidationError` with code ``json`` - never a stray ``RecursionError``,
    ``UnicodeDecodeError`` or ``JSONDecodeError`` (the failure mode that made a malformed body restart the access
    point in the old service)."""
    if isinstance(data, (bytes, bytearray)):
        if len(data) > max_bytes:
            raise _fail(field, "length", "body too large")
        try:
            text = bytes(data).decode("utf-8", "strict")
        except UnicodeDecodeError:
            raise _fail(field, "encoding", "body is not UTF-8") from None
    elif isinstance(data, str):
        if len(data) > max_bytes:
            raise _fail(field, "length", "body too large")
        text = data
    else:
        raise _fail(field, "type", "bytes or text expected")
    if text.startswith("\U0000feff"):
        raise _fail(field, "json", "byte order mark")
    try:
        return json.loads(text, object_pairs_hook=_no_duplicates, parse_constant=_no_constants, parse_int=_bounded_int,
                          parse_float=_bounded_float)
    except (ValueError, RecursionError):
        raise _fail(field, "json", "not valid JSON") from None


# --------------------------------------------------------------------------------------------------------------------
# Wi-Fi join request and the provisioning file
# --------------------------------------------------------------------------------------------------------------------

# What the portal and the scan parser call a network's security.
SECURITY_TYPES = ("open", "wep", "wpa1", "wpa2", "wpa3", "sae-only", "owe", "enterprise", "unknown")
# What this release will join. wpa3 means the WPA2/WPA3 transition mode (joined with a PSK key-management), sae-only
# needs SAE. wep, wpa1, owe and enterprise are refused (decision 12: enterprise is a later phase).
JOINABLE_SECURITY = ("open", "wpa2", "wpa3", "sae-only")

_JOIN_KEYS = frozenset(["ssid", "psk", "hidden", "security"])
_PROV_KEYS = frozenset(["version", "wifi", "country", "hostname"])
_PROV_WIFI_KEYS = frozenset(["ssid", "psk", "psk_hex", "hidden", "security"])


def _reject_unknown(doc: Mapping[str, Any], allowed: frozenset, field: str) -> None:
    for key in doc:
        if not isinstance(key, str) or key not in allowed:
            raise _fail(field, "unknown_key", "unexpected field")  # the key itself is not echoed


def _need_bool(value: Any, field: str) -> bool:
    if type(value) is not bool:
        raise _fail(field, "type", "must be true or false")
    return value


def validate_security(value: Any, field: str = "security") -> str:
    s = _need_text(value, field, 16)
    if s not in SECURITY_TYPES:
        raise _fail(field, "format", "unknown security type")
    return s


def validate_wifi_join_request(doc: Any, field: str = "request") -> Dict[str, Any]:
    """The body of ``POST /api/v1/wifi/join``: ``{"ssid", "psk"?, "hidden"?, "security"?}``.

    Returns ``{"ssid", "psk" (or None), "hidden", "security"}``. Unknown keys are refused. ``security`` defaults to
    ``open`` when there is no key and ``wpa2`` when there is one. An open network must not come with a key (a silently
    ignored password is a bug waiting to happen); every other joinable type must have one. A 64-digit raw key is
    refused for ``sae-only``: SAE needs the passphrase.
    """
    if not isinstance(doc, dict):
        raise _fail(field, "type", "object expected")
    _reject_unknown(doc, _JOIN_KEYS, field)
    ssid = validate_ssid(doc.get("ssid"), "ssid") if "ssid" in doc else _missing("ssid")
    psk = validate_psk(doc["psk"], "psk") if doc.get("psk") is not None else None
    hidden = _need_bool(doc["hidden"], "hidden") if "hidden" in doc else False
    if "security" in doc:
        security = validate_security(doc["security"])
    else:
        security = "wpa2" if psk is not None else "open"
    if security not in JOINABLE_SECURITY:
        raise _fail("security", "unsupported", "this network type cannot be joined from the setup page")
    if security == "open" and psk is not None:
        raise _fail("psk", "unexpected", "an open network takes no password")
    if security != "open" and psk is None:
        raise _fail("psk", "empty", "a password is required")
    if security == "sae-only" and psk is not None and psk_kind(psk) == "pmk_hex":
        raise _fail("psk", "format", "SAE needs the passphrase, not a raw key")
    return {"ssid": ssid, "psk": psk, "hidden": hidden, "security": security}


def _missing(field: str) -> Any:
    raise _fail(field, "empty", "required")


def validate_provisioning_doc(doc: Any, max_networks: int = 8) -> Dict[str, Any]:
    """Version 1 of ``companion-setup.json``::

        {"version": 1,
         "wifi": [{"ssid": "HomeNet", "psk_hex": "<64 hex>", "hidden": false, "security": "wpa2"}],
         "country": "DE", "hostname": "companion-os"}

    ``psk_hex`` is the WPA2 pairwise master key (PBKDF2-HMAC-SHA1 of passphrase and SSID), so the file need not hold
    the passphrase. A plain ``psk`` is accepted (SAE-only networks need it) and flagged in ``warnings``. Returns the
    normalised document ``{"version", "wifi", "country", "hostname", "warnings"}``.
    """
    if not isinstance(doc, dict):
        raise _fail("provisioning", "type", "object expected")
    _reject_unknown(doc, _PROV_KEYS, "provisioning")
    if type(doc.get("version")) is not int or doc["version"] != 1:
        raise _fail("version", "unsupported", "only version 1 is understood")
    wifi_in = doc.get("wifi", [])
    if not isinstance(wifi_in, list):
        raise _fail("wifi", "type", "list expected")
    if len(wifi_in) > max_networks:
        raise _fail("wifi", "length", "too many networks")
    warnings = []  # type: List[str]
    wifi_out = []  # type: List[Dict[str, Any]]
    for i, entry in enumerate(wifi_in):
        label = "wifi[%d]" % i
        if not isinstance(entry, dict):
            raise _fail(label, "type", "object expected")
        _reject_unknown(entry, _PROV_WIFI_KEYS, label)
        ssid = validate_ssid(entry.get("ssid"), label + ".ssid") if "ssid" in entry else _missing(label + ".ssid")
        has_hex = entry.get("psk_hex") is not None
        has_psk = entry.get("psk") is not None
        if has_hex and has_psk:
            raise _fail(label, "conflict", "give psk or psk_hex, not both")
        security = validate_security(entry["security"], label + ".security") if "security" in entry else (
            "wpa2" if (has_hex or has_psk) else "open")
        if security not in JOINABLE_SECURITY:
            raise _fail(label + ".security", "unsupported", "network type not supported")
        hidden = _need_bool(entry["hidden"], label + ".hidden") if "hidden" in entry else False
        psk = None  # type: Optional[str]
        psk_hex = None  # type: Optional[str]
        if has_hex:
            value = _need_text(entry["psk_hex"], label + ".psk_hex", PSK_HEX_LEN, PSK_HEX_LEN)
            if not is_hex64(value):
                raise _fail(label + ".psk_hex", "format", "64 hex digits")
            psk_hex = value.lower()
        elif has_psk:
            psk = validate_psk(entry["psk"], label + ".psk")
            if psk_kind(psk) == "pmk_hex":
                psk_hex, psk = psk.lower(), None
            else:
                warnings.append("%s: passphrase stored in the file" % label)
        if psk_hex is not None and security not in ("wpa2", "wpa3"):
            raise _fail(label, "conflict", "a raw key only works for WPA2 and the WPA2/WPA3 transition mode")
        if security == "open" and (psk is not None or psk_hex is not None):
            raise _fail(label, "unexpected", "an open network takes no password")
        if security != "open" and psk is None and psk_hex is None:
            raise _fail(label, "empty", "a password is required")
        wifi_out.append({"ssid": ssid, "psk": psk, "psk_hex": psk_hex, "hidden": hidden, "security": security})
    country = validate_country(doc["country"], "country") if doc.get("country") is not None else None
    hostname = validate_hostname(doc["hostname"], "hostname") if doc.get("hostname") is not None else None
    return {"version": 1, "wifi": wifi_out, "country": country, "hostname": hostname, "warnings": warnings}
