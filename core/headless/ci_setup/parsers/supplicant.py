"""Parsers for the status text of ``wpa_cli`` / ``wpa_supplicant`` and ``hostapd_cli`` / hostapd.

Both print ``key=value`` lines. ``wpa_cli status`` and ``hostapd_cli status`` are the polling interface; the
unsolicited event lines (``AP-STA-CONNECTED aa:bb:...``) are what an agent would read from the control socket's event
stream, and are parsed here too.
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Optional, Tuple

from .common import decode_printf_ssid, iter_lines, ssid_escaped, to_int

WPA_STATES = ("DISCONNECTED", "INTERFACE_DISABLED", "INACTIVE", "SCANNING", "AUTHENTICATING", "ASSOCIATING",
              "ASSOCIATED", "4WAY_HANDSHAKE", "GROUP_HANDSHAKE", "COMPLETED", "UNKNOWN")
HOSTAPD_STATES = ("UNINITIALIZED", "COUNTRY_UPDATE", "ENABLED", "DISABLED", "DFS", "HT_SCAN", "ACS")

_MAC = re.compile(r"^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}$")


def parse_kv(text: str, max_keys: int = 512) -> Dict[str, str]:
    """``key=value`` lines to a dict. A line without ``=`` is skipped; the first ``=`` splits, so values may contain
    ``=``; a repeated key keeps the last value."""
    out = {}  # type: Dict[str, str]
    for line in iter_lines(text):
        key, sep, val = line.partition("=")
        if not sep or not key or " " in key or len(out) >= max_keys and key not in out:
            continue
        out[key[:48]] = val[:256]
    return out


@dataclass(frozen=True)
class WpaStatus:
    state: str
    ssid_hex: Optional[str] = None
    ssid_escaped: Optional[str] = None
    bssid: Optional[str] = None
    freq_mhz: Optional[int] = None
    key_mgmt: Optional[str] = None
    ip_address: Optional[str] = None

    @property
    def connected(self) -> bool:
        return self.state == "COMPLETED"

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["connected"] = self.connected
        return d


def parse_wpa_status(text: str) -> WpaStatus:
    kv = parse_kv(text)
    state = kv.get("wpa_state", "UNKNOWN").upper()
    if state not in WPA_STATES:
        state = "UNKNOWN"
    ssid_raw = decode_printf_ssid(kv["ssid"])[:32] if "ssid" in kv else None
    bssid = kv.get("bssid", "").lower()
    return WpaStatus(
        state=state, ssid_hex=ssid_raw.hex() if ssid_raw is not None else None,
        ssid_escaped=ssid_escaped(ssid_raw) if ssid_raw is not None else None,
        bssid=bssid if _MAC.fullmatch(bssid) else None, freq_mhz=to_int(kv.get("freq", "")),
        key_mgmt=kv.get("key_mgmt"), ip_address=kv.get("ip_address"))


@dataclass(frozen=True)
class HostapdStatus:
    state: str
    iface: Optional[str] = None
    ssid_hex: Optional[str] = None
    bssid: Optional[str] = None
    channel: Optional[int] = None
    freq_mhz: Optional[int] = None
    hw_mode: Optional[str] = None
    country: Optional[str] = None
    num_sta: int = 0

    @property
    def enabled(self) -> bool:
        return self.state == "ENABLED"

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["enabled"] = self.enabled
        return d


def parse_hostapd_status(text: str) -> HostapdStatus:
    """``hostapd_cli status``. ``bss[0]``/``ssid[0]``/``num_sta[0]`` describe the first BSS."""
    kv = parse_kv(text)
    state = kv.get("state", "UNINITIALIZED").upper()
    if state not in HOSTAPD_STATES:
        state = "UNINITIALIZED"
    ssid_raw = decode_printf_ssid(kv["ssid[0]"])[:32] if "ssid[0]" in kv else None
    bssid = kv.get("bssid[0]", "").lower()
    n = to_int(kv.get("num_sta[0]", "")) or 0
    return HostapdStatus(
        state=state, iface=kv.get("bss[0]"), ssid_hex=ssid_raw.hex() if ssid_raw is not None else None,
        bssid=bssid if _MAC.fullmatch(bssid) else None, channel=to_int(kv.get("channel", "")),
        freq_mhz=to_int(kv.get("freq", "")), hw_mode=kv.get("hw_mode"), country=kv.get("country_code"),
        num_sta=max(0, n))


@dataclass(frozen=True)
class HostapdSta:
    mac: str
    flags: Tuple[str, ...]
    aid: Optional[int]

    @property
    def authorized(self) -> bool:
        return "AUTHORIZED" in self.flags

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["authorized"] = self.authorized
        return d


def parse_hostapd_all_sta(text: str) -> List[HostapdSta]:
    """``hostapd_cli all_sta``: a MAC line, then ``flags=[AUTH][ASSOC][AUTHORIZED]...``, ``aid=1`` ..."""
    out = []  # type: List[HostapdSta]
    cur = None  # type: Optional[Dict[str, Any]]
    for line in iter_lines(text):
        s = line.strip()
        if _MAC.fullmatch(s):
            if cur is not None:
                out.append(HostapdSta(**cur))
            cur = {"mac": s.lower(), "flags": (), "aid": None}
            continue
        if cur is None:
            continue
        key, _, val = s.partition("=")
        if key == "flags":
            cur["flags"] = tuple(re.findall(r"\[([A-Za-z0-9_\-]+)\]", val))[:24]
        elif key == "aid":
            cur["aid"] = to_int(val)
    if cur is not None:
        out.append(HostapdSta(**cur))
    return out[:256]


@dataclass(frozen=True)
class CtrlEvent:
    name: str                    # AP-STA-CONNECTED, AP-STA-DISCONNECTED, AP-ENABLED, AP-DISABLED, CTRL-EVENT-...
    mac: Optional[str]
    args: Tuple[str, ...]

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


_EVENT = re.compile(r"^(?:<[0-9]>)?\s*([A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+)(?:\s+(.*))?$")


def parse_ctrl_event(line: str) -> Optional[CtrlEvent]:
    """One line of the hostapd/wpa_supplicant control-interface event stream, e.g.
    ``<3>AP-STA-CONNECTED aa:bb:cc:dd:ee:ff`` or ``<3>CTRL-EVENT-CONNECTED - Connection to ... completed``. Returns
    None for anything that is not an event line."""
    if not isinstance(line, str):
        return None
    m = _EVENT.match(line.strip()[:512])
    if not m:
        return None
    rest = (m.group(2) or "").split()
    mac = None
    if rest and _MAC.fullmatch(rest[0]):
        mac = rest[0].lower()
        rest = rest[1:]
    return CtrlEvent(name=m.group(1), mac=mac, args=tuple(a[:64] for a in rest[:8]))
