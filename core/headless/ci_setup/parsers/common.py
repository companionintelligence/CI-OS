"""Helpers shared by the parsers: SSID decoding, frequency and channel arithmetic."""
from __future__ import annotations

import re
from typing import Optional

from ..errors import ValidationError
from ..validators import validate_ssid

_HEX = "0123456789abcdefABCDEF"

MAX_LINE = 4096
MAX_LINES = 200000


def iter_lines(text: str):
    """The lines of ``text`` with trailing whitespace removed, each cut at 4096 characters, at most 200000 of them.
    Parsers read their input only through this, so a hostile or broken command output costs bounded time and the
    regular expressions in them never see a megabyte-long line."""
    if not isinstance(text, str):
        return
    n = 0
    for line in text.splitlines():
        n += 1
        if n > MAX_LINES:
            return
        yield line[:MAX_LINE].rstrip()


def decode_iw_ssid(text: str) -> bytes:
    """Decode an SSID the way ``iw`` prints it (``print_ssid_escaped``): printable ASCII as is, every other octet
    (including a leading or trailing space and every byte of a non-ASCII character) as ``\\xNN``. ``\\\\`` is also
    understood, which older versions printed for a backslash. Anything else is taken literally."""
    out = bytearray()
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "\\" and i + 1 < n:
            nxt = text[i + 1]
            if nxt in ("x", "X") and i + 3 < n and text[i + 2] in _HEX and text[i + 3] in _HEX:
                out.append(int(text[i + 2:i + 4], 16))
                i += 4
                continue
            if nxt == "\\":
                out.append(0x5C)
                i += 2
                continue
        out.extend(ch.encode("utf-8", "surrogatepass") if ord(ch) > 0x7F else bytes([ord(ch)]))
        i += 1
    return bytes(out)


_PRINTF_SIMPLE = {"n": 0x0A, "r": 0x0D, "t": 0x09, "e": 0x1B, "\\": 0x5C, '"': 0x22}


def decode_printf_ssid(text: str) -> bytes:
    """Decode the escaping of ``wpa_ssid_txt`` / ``printf_encode`` used by wpa_cli and hostapd_cli: ``\\\\``,
    ``\\"``, ``\\n``, ``\\r``, ``\\t``, ``\\e`` and ``\\xNN``."""
    out = bytearray()
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "\\" and i + 1 < n:
            nxt = text[i + 1]
            if nxt == "x" and i + 3 < n and text[i + 2] in _HEX and text[i + 3] in _HEX:
                out.append(int(text[i + 2:i + 4], 16))
                i += 4
                continue
            if nxt in _PRINTF_SIMPLE:
                out.append(_PRINTF_SIMPLE[nxt])
                i += 2
                continue
        out.extend(ch.encode("utf-8", "surrogatepass") if ord(ch) > 0x7F else bytes([ord(ch)]))
        i += 1
    return bytes(out)


def ssid_escaped(raw: bytes) -> str:
    """A form of the SSID that is always safe to log or show: printable ASCII except backslash, everything else
    ``\\xNN``. (Same idea as iw's; no newline, ESC or NUL can survive it.)"""
    out = []
    for b in raw:
        if 0x20 <= b <= 0x7E and b != 0x5C:
            out.append(chr(b))
        else:
            out.append("\\x%02x" % b)
    return "".join(out)


def ssid_text(raw: bytes) -> Optional[str]:
    """The SSID as text if (and only if) it is something the setup page may offer for joining: valid UTF-8 and
    accepted by :func:`ci_setup.validators.validate_ssid`. Otherwise None; use :func:`ssid_escaped` for display."""
    try:
        text = raw.decode("utf-8", "strict")
        return validate_ssid(text)
    except (UnicodeDecodeError, ValidationError):
        return None


def is_hidden_ssid(raw: bytes) -> bool:
    """A hidden network beacons an empty SSID or one of NUL octets (``\\x00\\x00\\x00\\x00`` or longer)."""
    return len(raw) == 0 or all(b == 0 for b in raw)


def band_of(mhz: float) -> str:
    """``"2.4"``, ``"5"``, ``"6"``, ``"60"`` or ``"other"`` for a centre frequency in MHz."""
    if 2400 <= mhz < 2500:
        return "2.4"
    if 4900 <= mhz < 5925:
        return "5"
    if 5925 <= mhz <= 7125:
        return "6"
    if 57000 <= mhz <= 71000:
        return "60"
    return "other"


def freq_to_channel(mhz: float) -> Optional[int]:
    """The 802.11 channel number for a centre frequency, or None if it is not a channel centre."""
    if mhz == 2484:
        return 14
    if 2412 <= mhz <= 2472 and (mhz - 2407) % 5 == 0:
        return int((mhz - 2407) // 5)
    if 5160 <= mhz <= 5885 and (mhz - 5000) % 5 == 0:
        return int((mhz - 5000) // 5)
    if 5955 <= mhz <= 7115 and (mhz - 5950) % 5 == 0:
        return int((mhz - 5950) // 5)
    return None


_FLOAT_RE = re.compile(r"[+-]?[0-9]{1,18}(?:\.[0-9]{1,18})?")


def to_float(text: str) -> Optional[float]:
    """A decimal number written in ASCII digits, or None. (``float()`` itself accepts ``nan``, ``inf``, underscores
    and non-ASCII digits, none of which belong in command output we trust.)"""
    t = text.strip()
    if not _FLOAT_RE.fullmatch(t):
        return None
    return float(t)


def to_int(text: str) -> Optional[int]:
    """An integer written in ASCII digits with an optional sign, or None."""
    t = text.strip()
    if not t:
        return None
    sign = 1
    if t[0] in "+-":
        sign = -1 if t[0] == "-" else 1
        t = t[1:]
    if not t or len(t) > 18 or not all(c in "0123456789" for c in t):
        return None
    return sign * int(t, 10)
