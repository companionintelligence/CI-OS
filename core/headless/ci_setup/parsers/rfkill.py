"""Parser for ``rfkill list`` (text) and ``rfkill -J`` (JSON, util-linux)."""
from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Optional

from .common import iter_lines, to_int

# type names as `rfkill list` prints them -> short names as `rfkill -J` prints them
_TYPE_LONG = {
    "wireless lan": "wlan", "bluetooth": "bluetooth", "wireless wan": "wwan", "gps": "gps", "fm": "fm", "nfc": "nfc",
    "ultra-wideband": "uwb", "wimax": "wimax", "ultrawideband": "uwb",
}


@dataclass(frozen=True)
class RfkillEntry:
    id: int
    device: str          # phy0, hci0, ...
    type: str            # wlan, bluetooth, wwan, ...
    soft_blocked: bool
    hard_blocked: bool

    @property
    def blocked(self) -> bool:
        return self.soft_blocked or self.hard_blocked

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["blocked"] = self.blocked
        return d


_HDR = re.compile(r"^([0-9]+):\s*(\S+):\s*(.+)$")


def parse_rfkill_list(text: str) -> List[RfkillEntry]:
    """``rfkill list`` output."""
    out = []  # type: List[RfkillEntry]
    cur = None  # type: Optional[Dict[str, Any]]

    def flush() -> None:
        nonlocal cur
        if cur is not None and cur.get("soft") is not None and cur.get("hard") is not None:
            out.append(RfkillEntry(id=cur["id"], device=cur["device"], type=cur["type"], soft_blocked=cur["soft"],
                                   hard_blocked=cur["hard"]))
        cur = None

    for line in iter_lines(text):
        s = line.strip()
        m = _HDR.match(s)
        if m:
            flush()
            idx = to_int(m.group(1))
            if idx is None:
                continue
            long_type = m.group(3).strip().lower()
            cur = {"id": idx, "device": m.group(2)[:32], "type": _TYPE_LONG.get(long_type, long_type[:24]),
                   "soft": None, "hard": None}
            continue
        if cur is None:
            continue
        low = s.lower()
        if low.startswith("soft blocked:"):
            cur["soft"] = low.split(":", 1)[1].strip() == "yes"
        elif low.startswith("hard blocked:"):
            cur["hard"] = low.split(":", 1)[1].strip() == "yes"
    flush()
    return out[:64]


def parse_rfkill_json(text: str) -> List[RfkillEntry]:
    """``rfkill -J``: ``{"rfkilldevices": [{"id": 0, "type": "wlan", "device": "phy0", "soft": "unblocked",
    "hard": "unblocked"}]}``. Older util-linux versions print the list under an empty key; any list value is read."""
    try:
        doc = json.loads(text)
    except (ValueError, RecursionError):
        return []
    items = None  # type: Any
    if isinstance(doc, dict):
        for value in doc.values():
            if isinstance(value, list):
                items = value
                break
    elif isinstance(doc, list):
        items = doc
    out = []  # type: List[RfkillEntry]
    for it in items or []:
        if not isinstance(it, dict):
            continue
        idx = it.get("id")
        if type(idx) is not int:
            continue
        out.append(RfkillEntry(id=idx, device=str(it.get("device", ""))[:32], type=str(it.get("type", ""))[:24],
                               soft_blocked=str(it.get("soft", "")).lower() == "blocked",
                               hard_blocked=str(it.get("hard", "")).lower() == "blocked"))
    return out[:64]


def wlan_block_state(entries: List[RfkillEntry]) -> Dict[str, Any]:
    """Summary of the Wi-Fi switches: ``{"present", "soft_blocked": [devices], "hard_blocked": [devices]}``."""
    wlan = [e for e in entries if e.type == "wlan"]
    return {
        "present": bool(wlan),
        "soft_blocked": [e.device for e in wlan if e.soft_blocked],
        "hard_blocked": [e.device for e in wlan if e.hard_blocked],
    }
