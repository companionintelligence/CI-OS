"""Parsers for ``nmcli`` output.

Two output shapes matter, and the escaping rules differ (checked against the nmcli sources, ``nmcli-utils.c``
``print_required_fields`` / ``print_data``):

* **Terse tabular** (``nmcli -t -f A,B,C ...``, also ``nmcli -g``): one line per object, fields separated by ``:``.
  Inside a value a ``:`` and a ``\\`` are written ``\\:`` and ``\\\\`` (the ``--escape yes`` default). A BSSID is
  therefore printed ``AA\\:BB\\:CC\\:DD\\:EE\\:FF``. The nmcli manual says the escaping applies to "terse tabular
  mode".
* **Multiline** (``nmcli -m multiline``, the default for ``device show`` and ``connection show <id>``): one
  ``NAME:value`` line per property, and array properties as ``NAME[1]:value``. With ``-t`` the value follows the colon
  directly; without it the value is padded to column 40. Values are NOT escaped in this mode.

A value in terse tabular mode is not guaranteed to be free of a newline (an SSID is attacker-chosen text), so a row
whose field count is not the expected one is dropped and counted: it may be a forged row.
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .common import iter_lines, to_int

# --------------------------------------------------------------------------------------------------------------------
# terse tabular
# --------------------------------------------------------------------------------------------------------------------


def escape_terse(value: str) -> str:
    """The inverse of the unescaping below (what ``nmcli -t`` does to one value). Used by tests and fixtures."""
    return value.replace("\\", "\\\\").replace(":", "\\:")


def split_terse_line(line: str) -> List[str]:
    """Split one terse line on unescaped ``:`` and unescape ``\\:`` and ``\\\\``. A backslash before any other
    character is kept literally; a trailing lone backslash is kept."""
    fields = []  # type: List[str]
    cur = []  # type: List[str]
    i, n = 0, len(line)
    while i < n:
        ch = line[i]
        if ch == "\\" and i + 1 < n and line[i + 1] in (":", "\\"):
            cur.append(line[i + 1])
            i += 2
            continue
        if ch == ":":
            fields.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    fields.append("".join(cur))
    return fields


def parse_terse(text: str, columns: Optional[Sequence[str]] = None) -> Tuple[List[Any], int]:
    """Parse ``nmcli -t`` tabular output.

    With ``columns`` each row becomes a dict and a row whose field count differs from ``len(columns)`` is dropped;
    without, each row is a list. Returns ``(rows, dropped)`` - ``dropped`` counts blank-free lines that were rejected.
    """
    rows = []  # type: List[Any]
    dropped = 0
    for line in iter_lines(text):
        if not line:
            continue
        fields = split_terse_line(line)
        if columns is not None:
            if len(fields) != len(columns):
                dropped += 1
                continue
            rows.append(dict(zip(columns, fields)))
        else:
            rows.append(fields)
        if len(rows) >= 4096:
            break
    return rows, dropped


# --------------------------------------------------------------------------------------------------------------------
# multiline
# --------------------------------------------------------------------------------------------------------------------

_ML_KEY = re.compile(r"^([A-Za-z0-9_.\-]+(?:\[[0-9]+\])?):(.*)$")


def parse_multiline(text: str, terse: bool = True) -> List[Dict[str, str]]:
    """Parse ``nmcli -m multiline`` (with ``-t`` when ``terse``): a list of objects, each a dict of
    ``NAME`` or ``NAME[n]`` to value. A new object starts when a name repeats, at a blank line, or at nmcli's pretty
    separator line of dashes. Without ``terse`` the padding after the colon is stripped and ``--`` (nmcli's "not set")
    becomes an empty string."""
    objs = []  # type: List[Dict[str, str]]
    cur = {}  # type: Dict[str, str]
    for line in iter_lines(text):
        stripped = line.strip()
        if not stripped or set(stripped) == {"-"}:
            if cur:
                objs.append(cur)
                cur = {}
            continue
        m = _ML_KEY.match(line)
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if not terse:
            val = val.strip()
            if val == "--":
                val = ""
        if key in cur:
            objs.append(cur)
            cur = {}
        cur[key] = val
        if len(objs) >= 1024:
            break
    if cur:
        objs.append(cur)
    return objs


# --------------------------------------------------------------------------------------------------------------------
# device state
# --------------------------------------------------------------------------------------------------------------------

# Strings from nmc_device_state_to_string() in nmcli-common2.c (and the "(externally)" variants).
_STATE_RE = re.compile(r"^(unmanaged|unavailable|disconnected|connecting|connected|deactivating|connection failed|unknown)"
                       r"(?:\s*\(([^)]*)\))?$", re.IGNORECASE)


@dataclass(frozen=True)
class DeviceState:
    state: str                    # unmanaged, unavailable, disconnected, connecting, connected, deactivating, failed, unknown
    detail: str = ""              # "getting IP configuration", "externally", "site only", ...

    @property
    def is_up(self) -> bool:
        """Activated: the link is up, whether or not the network beyond it works."""
        return self.state == "connected"

    @property
    def is_busy(self) -> bool:
        """In the middle of activating: a join is under way and the radio must not be taken away."""
        return self.state == "connecting"

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["is_up"] = self.is_up
        d["is_busy"] = self.is_busy
        return d


def parse_device_state(text: str) -> DeviceState:
    """``connecting (getting IP configuration)`` -> ``DeviceState("connecting", "getting IP configuration")``.

    The old setup monitor matched only the bare word ``connected`` and so treated every ``connecting (...)`` and
    ``connected (externally)`` state as "not connected" (defect L5); this keeps the detail apart from the state."""
    t = text.strip()
    # `nmcli device show` prints "100 (connected)": the numeric NMDeviceState first
    nm = re.match(r"^([0-9]{1,3})\s*\((.*)\)$", t)
    if nm:
        t = nm.group(2).strip()
    m = _STATE_RE.fullmatch(t)
    if not m:
        return DeviceState("unknown", t[:60])
    state = m.group(1).lower()
    state = "failed" if state == "connection failed" else state
    return DeviceState(state, (m.group(2) or "")[:60])


# --------------------------------------------------------------------------------------------------------------------
# concrete commands
# --------------------------------------------------------------------------------------------------------------------

DEVICE_STATUS_COLUMNS = ("DEVICE", "TYPE", "STATE", "CONNECTION")


@dataclass(frozen=True)
class NmDevice:
    device: str
    type: str
    state: DeviceState
    connection: str

    def to_dict(self) -> Dict[str, Any]:
        return {"device": self.device, "type": self.type, "state": self.state.to_dict(), "connection": self.connection}


def parse_device_status(text: str) -> List[NmDevice]:
    """``nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status``."""
    rows, _ = parse_terse(text, DEVICE_STATUS_COLUMNS)
    out = []
    for r in rows:
        out.append(NmDevice(device=r["DEVICE"][:32], type=r["TYPE"][:24], state=parse_device_state(r["STATE"]),
                            connection=r["CONNECTION"][:128]))
    return out


CONNECTION_COLUMNS = ("NAME", "UUID", "TYPE", "DEVICE")


@dataclass(frozen=True)
class NmConnection:
    name: str
    uuid: str
    type: str          # 802-11-wireless, 802-3-ethernet, vpn, bridge, loopback, ...
    device: str

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @property
    def is_wifi(self) -> bool:
        return self.type == "802-11-wireless"


def parse_connection_show(text: str) -> List[NmConnection]:
    """``nmcli -t -f NAME,UUID,TYPE,DEVICE connection show``.

    The TYPE column is the point of this parser: deleting a profile because its NAME equals an SSID, without looking at
    its type, removed wired and VPN profiles in the old service (defect S4)."""
    rows, _ = parse_terse(text, CONNECTION_COLUMNS)
    return [NmConnection(name=r["NAME"][:128], uuid=r["UUID"][:40], type=r["TYPE"][:40], device=r["DEVICE"][:32])
            for r in rows]


WIFI_LIST_COLUMNS = ("IN-USE", "SSID", "BSSID", "CHAN", "FREQ", "SIGNAL", "SECURITY")


def classify_nm_security(security: str) -> str:
    """The SECURITY column of ``device wifi list`` (tokens ``WEP WPA1 WPA2 WPA3 OWE OWE-TM 802.1X
    WPA-EAP-SUITE-B-192``, empty or ``--`` for open) in the setup page's vocabulary. ``WPA2`` alone is PSK or 802.1X
    (nmcli prints ``WPA2`` for both, with ``802.1X`` added for the latter)."""
    tokens = set(security.replace("--", " ").split())
    if not tokens:
        return "open"
    if "802.1X" in tokens or "WPA-EAP-SUITE-B-192" in tokens:
        return "enterprise"
    if "OWE" in tokens or "OWE-TM" in tokens:
        return "owe"
    if "WEP" in tokens:
        return "wep"
    if "WPA3" in tokens and "WPA2" in tokens:
        return "wpa3"
    if "WPA3" in tokens:
        return "sae-only"
    if "WPA2" in tokens:
        return "wpa2"
    if "WPA1" in tokens:
        return "wpa1"
    return "unknown"


@dataclass(frozen=True)
class NmAccessPoint:
    in_use: bool
    ssid: str                  # as nmcli printed it: UNTRUSTED text, may contain anything
    bssid: str
    channel: Optional[int]
    freq_mhz: Optional[int]
    signal_pct: Optional[int]
    security_raw: str
    security: str

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def parse_wifi_list(text: str) -> Tuple[List[NmAccessPoint], int]:
    """``nmcli -t -f IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list --rescan no``.

    Returns ``(access_points, dropped_rows)``. SSIDs here come from other people's beacons; use them for display
    only and prefer ``iw scan dump`` (which escapes) as the source for anything that is acted on."""
    rows, dropped = parse_terse(text, WIFI_LIST_COLUMNS)
    out = []
    for r in rows:
        freq_txt = r["FREQ"].split(" ")[0]
        out.append(NmAccessPoint(
            in_use=r["IN-USE"].strip() == "*", ssid=r["SSID"][:64], bssid=r["BSSID"].lower()[:17],
            channel=to_int(r["CHAN"]), freq_mhz=to_int(freq_txt), signal_pct=to_int(r["SIGNAL"]),
            security_raw=r["SECURITY"][:64], security=classify_nm_security(r["SECURITY"])))
    return out, dropped


CONNECTIVITY_VALUES = ("full", "limited", "portal", "none", "unknown")


def parse_connectivity(text: str) -> str:
    """``nmcli networking connectivity`` (no ``check``): one of full, limited, portal, none, unknown."""
    for line in iter_lines(text):
        word = line.strip().lower()
        if word in CONNECTIVITY_VALUES:
            return word
    return "unknown"


GENERAL_STATUS_COLUMNS = ("STATE", "CONNECTIVITY", "WIFI-HW", "WIFI", "WWAN-HW", "WWAN")


def parse_general_status(text: str) -> Dict[str, str]:
    """``nmcli -t general status`` (default columns STATE:CONNECTIVITY:WIFI-HW:WIFI:WWAN-HW:WWAN)."""
    rows, _ = parse_terse(text, GENERAL_STATUS_COLUMNS)
    return rows[0] if rows else {}


@dataclass(frozen=True)
class NmDeviceDetail:
    device: str
    type: str
    state: DeviceState
    hwaddr: str
    connection: str
    ip4_addresses: Tuple[str, ...]
    ip4_gateway: str
    driver: str

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["state"] = self.state.to_dict()
        return d


def parse_device_show(text: str, terse: bool = True) -> List[NmDeviceDetail]:
    """``nmcli [-t] -m multiline device show [ifname]``."""
    out = []
    for obj in parse_multiline(text, terse=terse):
        addrs = tuple(v for k, v in sorted(obj.items()) if k.startswith("IP4.ADDRESS[") and v)
        out.append(NmDeviceDetail(
            device=obj.get("GENERAL.DEVICE", "")[:32], type=obj.get("GENERAL.TYPE", "")[:24],
            state=parse_device_state(obj.get("GENERAL.STATE", "")), hwaddr=obj.get("GENERAL.HWADDR", "")[:17].lower(),
            connection=obj.get("GENERAL.CONNECTION", "")[:128], ip4_addresses=addrs[:8],
            ip4_gateway=obj.get("IP4.GATEWAY", "")[:15], driver=obj.get("GENERAL.DRIVER", "")[:32]))
    return out

