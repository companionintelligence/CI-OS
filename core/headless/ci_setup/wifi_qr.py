"""The Wi-Fi join string that goes into a QR code: ``WIFI:T:WPA;S:<ssid>;P:<key>;;``.

The format is the ZXing "Wi-Fi Network config" (Android and iOS 11+ cameras read it), a MECARD-like list of ``X:value;``
fields ending in ``;;``. Special characters ``\\``, ``;``, ``,``, ``"`` and ``:`` are escaped with a backslash; a value that
could be read as hexadecimal (an SSID or key made only of hex digits) is wrapped in double quotes so that it is taken as
text. The fields are validated first, so the payload can contain no control character, and the generated AP key alphabet
needs no escaping at all (the escaping exists for the SSID of someone else's network and for tests).
"""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple

from . import qr
from .errors import ValidationError
from .validators import validate_psk, validate_ssid

_SPECIAL = "\\;,\":"
_HEX = frozenset("0123456789abcdefABCDEF")
SECURITY_CODES = ("WPA", "WEP", "nopass")


def escape_field(value: str) -> str:
    """Backslash-escape ``\\ ; , " :``."""
    out = []
    for ch in value:
        if ch in _SPECIAL:
            out.append("\\")
        out.append(ch)
    return "".join(out)


def _field(value: str) -> str:
    esc = escape_field(value)
    if value and all(c in _HEX for c in value):
        return '"' + esc + '"'   # would be read as hex otherwise
    return esc


def wifi_payload(ssid: str, key: Optional[str] = None, security: str = "WPA", hidden: bool = False) -> str:
    """The string to encode. ``key`` is required for ``WPA``/``WEP`` and must be None for ``nopass``."""
    ssid = validate_ssid(ssid)
    if security not in SECURITY_CODES:
        raise ValidationError("security", "format", "WPA, WEP or nopass")
    parts = ["T:" + security, "S:" + _field(ssid)]
    if security == "nopass":
        if key is not None:
            raise ValidationError("key", "unexpected", "an open network takes no key")
    else:
        if key is None:
            raise ValidationError("key", "empty", "a key is required")
        parts.append("P:" + _field(validate_psk(key, "key")))
    if hidden:
        parts.append("H:true")
    return "WIFI:" + ";".join(parts) + ";;"


def parse_wifi_payload(text: str) -> Optional[Dict[str, str]]:
    """The inverse, as a camera app reads it: ``{"T", "S", "P", "H"}`` with escapes removed and the hex-protecting double
    quotes stripped; None if ``text`` is not a well-formed ``WIFI:`` string. Used by tests and by tools that accept a
    scanned code."""
    if not isinstance(text, str) or not text.startswith("WIFI:") or len(text) > 512:
        return None
    body = text[5:]
    n = len(body)
    fields = {}  # type: Dict[str, str]
    i = 0
    while i < n:
        j = i
        while j < n and body[j] not in ":;":
            j += 1
        if j >= n:
            return None                     # a key with no value
        if body[j] == ";":
            return fields if j == i else None   # ";;" ends the list; "key;" is malformed
        key = body[i:j]
        i = j + 1
        chars = []  # type: List[Tuple[str, bool]]
        closed = False
        while i < n:
            ch = body[i]
            if ch == "\\" and i + 1 < n:
                chars.append((body[i + 1], True))
                i += 2
                continue
            if ch == ";":
                closed = True
                break
            chars.append((ch, False))
            i += 1
        if not closed:
            return None
        i += 1
        if len(chars) >= 2 and chars[0] == ('"', False) and chars[-1] == ('"', False):
            chars = chars[1:-1]
        fields[key] = "".join(c for c, _ in chars)
    return fields


def console_qr(ssid: str, key: Optional[str], security: str = "WPA", hidden: bool = False, ecl: str = "M",
               ansi: bool = True) -> Optional[str]:
    """The join code as text for a console: black-on-white half blocks (``ansi``) or plain ``##`` / spaces. None when the payload is
    too long for the encoder (the caller then shows the SSID and key as text)."""
    payload = wifi_payload(ssid, key, security, hidden)
    try:
        code = qr.encode(payload, ecl)
    except ValueError:
        return None
    return qr.render_ansi(code) if ansi else qr.render_ascii(code)

