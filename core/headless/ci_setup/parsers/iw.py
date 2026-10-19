"""Parsers for ``iw``: ``iw dev``, ``iw phy <phy> info`` / ``iw list``, ``iw reg get``, ``iw dev <if> scan dump``,
``iw dev <if> link`` and ``iw dev <if> station dump``.

The formats are those printed by iw's own source (``interface.c``, ``info.c``, ``reg.c``, ``scan.c``, ``link.c``,
``station.c``) as of iw 5.x/6.x. Fields that older or newer versions add are ignored; a line that does not match is
skipped. See the fixtures under core/headless/tests/ci_setup/fixtures: they are written by hand from those sources
(no wireless hardware was available when they were made) and say so.
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Optional, Tuple

from .common import (band_of, decode_iw_ssid, freq_to_channel, is_hidden_ssid, iter_lines, ssid_escaped, ssid_text,
                     to_float, to_int)

# --------------------------------------------------------------------------------------------------------------------
# iw dev
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class IwInterface:
    phy: str                      # "phy0"
    name: Optional[str]           # None for a wdev without a netdev (P2P-device)
    ifindex: Optional[int] = None
    wdev: Optional[str] = None
    mac: Optional[str] = None
    type: Optional[str] = None    # managed, AP, monitor, P2P-device, mesh point, ...
    ssid_hex: Optional[str] = None
    ssid_escaped: Optional[str] = None
    channel: Optional[int] = None
    freq_mhz: Optional[int] = None
    width_mhz: Optional[int] = None
    txpower_dbm: Optional[float] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @property
    def connected(self) -> bool:
        """A managed interface that reports an SSID is associated; an AP interface that reports one is serving."""
        return self.ssid_hex is not None


_PHY_HDR = re.compile(r"^phy#([0-9]+)\s*$")
_IFACE_HDR = re.compile(r"^\s*Interface\s+(\S+)\s*$")
_CHANNEL_LINE = re.compile(r"^channel\s+([0-9]+)\s+\(([0-9]+)\s*MHz\)(?:,\s*width:\s*([0-9]+)\s*MHz)?")


def parse_iw_dev(text: str) -> List[IwInterface]:
    """``iw dev``: every interface (and every netdev-less wdev) with its phy."""
    out = []  # type: List[IwInterface]
    phy = None  # type: Optional[str]
    cur = None  # type: Optional[Dict[str, Any]]

    def flush() -> None:
        nonlocal cur
        if cur is not None and cur["phy"] is not None:
            out.append(IwInterface(**cur))
        cur = None

    for raw in iter_lines(text):
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            continue
        m = _PHY_HDR.match(line)
        if m:
            flush()
            phy = "phy" + m.group(1)
            continue
        m = _IFACE_HDR.match(line)
        if m:
            flush()
            cur = {"phy": phy, "name": m.group(1)[:32]}
            continue
        if stripped.startswith("Unnamed/non-netdev interface"):
            flush()
            cur = {"phy": phy, "name": None}
            continue
        if cur is None:
            continue
        key, _, rest = stripped.partition(" ")
        rest = rest.strip()
        if key == "ifindex":
            cur["ifindex"] = to_int(rest)
        elif key == "wdev":
            cur["wdev"] = rest[:32] or None
        elif key == "addr":
            cur["mac"] = rest.lower()[:17] or None
        elif key == "type":
            cur["type"] = rest[:32] or None
        elif key == "ssid":
            raw_ssid = decode_iw_ssid(rest)
            cur["ssid_hex"] = raw_ssid[:32].hex()
            cur["ssid_escaped"] = ssid_escaped(raw_ssid[:32])
        elif key == "channel":
            cm = _CHANNEL_LINE.match(stripped)
            if cm:
                cur["channel"] = int(cm.group(1))
                cur["freq_mhz"] = int(cm.group(2))
                cur["width_mhz"] = int(cm.group(3)) if cm.group(3) else None
        elif key == "txpower":
            cur["txpower_dbm"] = to_float(rest.split(" ")[0]) if rest else None
    flush()
    return out


# --------------------------------------------------------------------------------------------------------------------
# iw phy info
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class FreqInfo:
    mhz: int
    channel: int
    band: str                       # "2.4", "5", "6", "60", "other"
    disabled: bool = False
    no_ir: bool = False             # no initiating radiation: passive only, an access point may not use it
    radar: bool = False             # radar detection (DFS)
    no_ibss: bool = False
    max_dbm: Optional[float] = None
    other_flags: Tuple[str, ...] = ()

    @property
    def usable_for_ap(self) -> bool:
        """Allowed to start an access point here without DFS: not disabled, not passive-only, no radar detection."""
        return not (self.disabled or self.no_ir or self.radar)

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["usable_for_ap"] = self.usable_for_ap
        return d


@dataclass(frozen=True)
class IfaceLimit:
    types: Tuple[str, ...]
    max: int


@dataclass(frozen=True)
class IfaceCombo:
    limits: Tuple[IfaceLimit, ...]
    total: int
    channels: int
    sta_ap_bi_match: bool = False
    radar_widths: Tuple[int, ...] = ()

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class PhyInfo:
    name: str                                   # "phy0"
    index: Optional[int] = None
    modes: Tuple[str, ...] = ()                 # "Supported interface modes"
    software_modes: Tuple[str, ...] = ()        # "software interface modes (can always be added)"
    combos: Tuple[IfaceCombo, ...] = ()
    freqs: Tuple[FreqInfo, ...] = ()
    commands: Tuple[str, ...] = ()
    ciphers: Tuple[str, ...] = ()
    ext_features: Tuple[str, ...] = ()
    notes: Tuple[str, ...] = ()                 # "Device supports ..." lines, verbatim

    @property
    def supports_ap(self) -> bool:
        """The driver lists AP mode. When the command list is present it must also offer ``start_ap``."""
        if "AP" not in self.modes:
            return False
        return (not self.commands) or ("start_ap" in self.commands)

    @property
    def supports_sae(self) -> bool:
        text = " ".join(self.notes + self.ext_features)
        return "SAE" in text

    def bands(self) -> Tuple[str, ...]:
        seen = []  # type: List[str]
        for f in self.freqs:
            if f.band not in seen:
                seen.append(f.band)
        return tuple(seen)

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["supports_ap"] = self.supports_ap
        d["supports_sae"] = self.supports_sae
        d["bands"] = list(self.bands())
        d["concurrent_ap_sta"] = concurrent_ap_sta(self.combos)
        return d


_WIPHY_HDR = re.compile(r"^Wiphy\s+(\S+)\s*$")
_FREQ_LINE = re.compile(r"^\*\s*([0-9]+(?:\.[0-9]+)?)\s*MHz\s*\[([0-9]+)\](.*)$")
_PAREN = re.compile(r"\(([^()]*)\)")
_LIMIT_RE = re.compile(r"#\{\s*([^}]*?)\s*\}\s*<=\s*([0-9]+)")
_TOTAL_RE = re.compile(r"total\s*<=\s*([0-9]+)")
_CHAN_RE = re.compile(r"#channels\s*<=\s*([0-9]+)")
_WIDTHS_RE = re.compile(r"radar detect widths:\s*\{([^}]*)\}")
_BAND_HDR = re.compile(r"^Band\s+[0-9]+:\s*$")


def _parse_freq(rest_mhz: str, chan: str, flags_text: str) -> Optional[FreqInfo]:
    mhz_f = to_float(rest_mhz)
    ch = to_int(chan)
    if mhz_f is None or ch is None:
        return None
    mhz = int(round(mhz_f))
    disabled = no_ir = radar = no_ibss = False
    max_dbm = None  # type: Optional[float]
    other = []  # type: List[str]
    for group in _PAREN.findall(flags_text):
        g = group.strip()
        if g.endswith("dBm"):
            max_dbm = to_float(g[:-3].strip())
            continue
        for flag in g.split(","):
            f = flag.strip()
            if not f:
                continue
            if f == "disabled":
                disabled = True
            elif f == "no IR":
                no_ir = True
            elif f == "radar detection":
                radar = True
            elif f == "no IBSS":
                no_ibss = True
            else:
                other.append(f[:40])
    return FreqInfo(mhz=mhz, channel=ch, band=band_of(mhz), disabled=disabled, no_ir=no_ir, radar=radar,
                    no_ibss=no_ibss, max_dbm=max_dbm, other_flags=tuple(other[:8]))


def parse_iface_combo(text: str) -> Optional[IfaceCombo]:
    """One ``valid interface combinations`` entry (its two printed lines joined) to an :class:`IfaceCombo`."""
    text = text[:2000]
    limits = []  # type: List[IfaceLimit]
    for types_s, max_s in _LIMIT_RE.findall(text):
        types = tuple(t.strip() for t in types_s.split(",") if t.strip())
        mx = to_int(max_s)
        if types and mx is not None:
            limits.append(IfaceLimit(types=types, max=mx))
    tm = _TOTAL_RE.search(text)
    cm = _CHAN_RE.search(text)
    if not limits or tm is None or cm is None:
        return None
    widths = []  # type: List[int]
    wm = _WIDTHS_RE.search(text)
    if wm:
        for part in wm.group(1).split(","):
            digits = part.strip().split(" ")[0]
            v = to_int(digits)
            if v is not None and v not in widths:
                widths.append(v)
    return IfaceCombo(limits=tuple(limits), total=int(tm.group(1)), channels=int(cm.group(1)),
                      sta_ap_bi_match="STA/AP BI must match" in text, radar_widths=tuple(widths))


def concurrent_ap_sta(combos: Tuple[IfaceCombo, ...]) -> Optional[Dict[str, Any]]:
    """The best combination that lets one AP and one station interface exist at the same time, or None.

    A combination qualifies when its limits can hold both: either one limit group names both ``AP`` and ``managed``
    with a maximum of at least 2, or two separate groups name them with a maximum of at least 1 each, and the total
    is at least 2. ``channels`` is how many channels they may use at once: with 1, the AP has to sit on the station's
    channel. The combination with the most channels wins.
    """
    best = None  # type: Optional[Dict[str, Any]]
    for combo in combos:
        if combo.total < 2:
            continue
        ap_groups = [g for g in combo.limits if "AP" in g.types and g.max >= 1]
        sta_groups = [g for g in combo.limits if "managed" in g.types and g.max >= 1]
        ok = False
        for a in ap_groups:
            for g in sta_groups:
                if a is not g or a.max >= 2:  # one shared group must hold both interfaces
                    ok = True
        if not ok:
            continue
        cand = {"channels": combo.channels, "total": combo.total, "sta_ap_bi_match": combo.sta_ap_bi_match}
        if best is None or cand["channels"] > best["channels"]:
            best = cand
    return best


def parse_iw_phy_info(text: str) -> List[PhyInfo]:
    """``iw phy <phy> info`` or ``iw list`` (several ``Wiphy`` blocks)."""
    phys = []  # type: List[PhyInfo]
    cur = None  # type: Optional[Dict[str, Any]]
    section = "other"
    combo_texts = []  # type: List[str]

    def flush() -> None:
        nonlocal cur, combo_texts
        if cur is None:
            return
        combos = []
        for ct in combo_texts:
            c = parse_iface_combo(ct)
            if c is not None:
                combos.append(c)
        phys.append(PhyInfo(
            name=cur["name"], index=cur["index"], modes=tuple(cur["modes"]),
            software_modes=tuple(cur["software_modes"]), combos=tuple(combos), freqs=tuple(cur["freqs"]),
            commands=tuple(cur["commands"]), ciphers=tuple(cur["ciphers"]),
            ext_features=tuple(cur["ext_features"]), notes=tuple(cur["notes"])))
        cur = None
        combo_texts = []

    for raw in iter_lines(text):
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            continue
        m = _WIPHY_HDR.match(stripped)
        if m:
            flush()
            cur = {"name": m.group(1) if m.group(1).startswith("phy") else "phy" + m.group(1), "index": None,
                   "modes": [], "software_modes": [], "freqs": [], "commands": [], "ciphers": [],
                   "ext_features": [], "notes": []}
            section = "other"
            continue
        if cur is None:
            continue
        is_bullet = stripped.startswith("* ") or stripped == "*"
        if not is_bullet:
            if stripped.startswith("wiphy index:"):
                cur["index"] = to_int(stripped.split(":", 1)[1])
                section = "other"
                continue
            if section == "combos" and stripped.startswith("total"):
                if combo_texts:
                    combo_texts[-1] += " " + stripped
                continue
            if stripped.startswith(("Device supports", "Device has", "Device can", "Device uses")):
                if len(cur["notes"]) < 64:
                    cur["notes"].append(stripped[:120])
                section = "other"
                continue
            if section == "freqs" and not stripped.endswith(":") and not _BAND_HDR.match(stripped):
                continue  # "DFS state: ...", "DFS CAC time: ..." under a frequency
            low = stripped.lower()
            if _BAND_HDR.match(stripped):
                section = "band"
            elif low == "frequencies:":
                section = "freqs"
            elif low.startswith("supported interface modes"):
                section = "modes"
            elif low.startswith("software interface modes"):
                section = "sw_modes"
            elif low.startswith("valid interface combinations"):
                section = "combos"
            elif low.startswith("supported commands"):
                section = "commands"
            elif low.startswith("supported ciphers"):
                section = "ciphers"
            elif low.startswith("supported extended features"):
                section = "ext"
            else:
                section = "other"
            continue
        body = stripped[2:].strip() if stripped != "*" else ""
        if section == "freqs":
            fm = _FREQ_LINE.match(stripped)
            if fm:
                fi = _parse_freq(fm.group(1), fm.group(2), fm.group(3))
                if fi is not None and len(cur["freqs"]) < 2048:
                    cur["freqs"].append(fi)
        elif section == "modes":
            if body and len(cur["modes"]) < 32:
                cur["modes"].append(body[:32])
        elif section == "sw_modes":
            if body and len(cur["software_modes"]) < 32:
                cur["software_modes"].append(body[:32])
        elif section == "combos":
            if body and len(combo_texts) < 64:
                combo_texts.append(body)
        elif section == "commands":
            if body and len(cur["commands"]) < 256:
                cur["commands"].append(body.split(" ")[0][:48])
        elif section == "ciphers":
            if body and len(cur["ciphers"]) < 64:
                cur["ciphers"].append(body[:48])
        elif section == "ext":
            em = re.match(r"\[\s*([A-Za-z0-9_]+)\s*\]", body)
            if em and len(cur["ext_features"]) < 128:
                cur["ext_features"].append(em.group(1))
    flush()
    return phys


# --------------------------------------------------------------------------------------------------------------------
# iw reg get
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class RegRule:
    start_mhz: float
    end_mhz: float
    max_bw_mhz: float
    max_eirp_dbm: Optional[float] = None
    cac_ms: Optional[int] = None
    flags: Tuple[str, ...] = ()

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class RegDomain:
    scope: str                      # "global" or "phy"
    phy: Optional[str]              # "phy0" for a per-phy block
    self_managed: bool
    country: str                    # "DE", "US", "00" (world), "99", "98"
    dfs: Optional[str]              # "ETSI", "FCC", "JP", "UNSET", or the raw word
    rules: Tuple[RegRule, ...] = ()

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


_REG_PHY = re.compile(r"^phy#([0-9]+)(\s+\(self-managed\))?\s*$")
_REG_COUNTRY = re.compile(r"^country\s+(\S\S):\s*(?:DFS-(\S+))?\s*$")
_REG_RULE = re.compile(
    r"^\(\s*([0-9]+(?:\.[0-9]+)?)\s*-\s*([0-9]+(?:\.[0-9]+)?)\s*@\s*([0-9]+(?:\.[0-9]+)?)\s*\)"
    r"(?:\s*,\s*\(([^)]*)\))?(?:\s*,\s*\(([^)]*)\))?(.*)$")


def parse_iw_reg_get(text: str) -> List[RegDomain]:
    """``iw reg get``: the global regulatory domain and one block per phy that has its own (``self-managed`` ones are
    flagged)."""
    out = []  # type: List[RegDomain]
    scope, phy, selfm = None, None, False  # type: Optional[str], Optional[str], bool
    country, dfs = None, None  # type: Optional[str], Optional[str]
    rules = []  # type: List[RegRule]

    def flush() -> None:
        nonlocal country, dfs, rules
        if scope is not None and country is not None:
            out.append(RegDomain(scope=scope, phy=phy, self_managed=selfm, country=country, dfs=dfs,
                                 rules=tuple(rules)))
        country, dfs, rules = None, None, []

    for raw in iter_lines(text):
        stripped = raw.strip()
        if not stripped:
            continue
        if stripped == "global":
            flush()
            scope, phy, selfm = "global", None, False
            continue
        m = _REG_PHY.match(stripped)
        if m:
            flush()
            scope, phy, selfm = "phy", "phy" + m.group(1), bool(m.group(2))
            continue
        m = _REG_COUNTRY.match(stripped)
        if m:
            if country is not None:
                flush()
            country, dfs = m.group(1).upper(), m.group(2)
            continue
        m = _REG_RULE.match(stripped)
        if m and country is not None and len(rules) < 64:
            start, end, bw = to_float(m.group(1)), to_float(m.group(2)), to_float(m.group(3))
            if start is None or end is None or bw is None:
                continue
            eirp = None  # type: Optional[float]
            if m.group(4):
                parts = [p.strip() for p in m.group(4).split(",")]
                if parts:
                    eirp = to_float(parts[-1])
            cac = None  # type: Optional[int]
            if m.group(5):
                cm = re.match(r"([0-9]+)\s*ms", m.group(5).strip())
                if cm:
                    cac = int(cm.group(1))
            flags = tuple(f.strip()[:24] for f in m.group(6).split(",") if f.strip())[:12]
            rules.append(RegRule(start_mhz=start, end_mhz=end, max_bw_mhz=bw, max_eirp_dbm=eirp, cac_ms=cac,
                                 flags=flags))
    flush()
    return out


# --------------------------------------------------------------------------------------------------------------------
# iw scan dump
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class ScanBss:
    bssid: str
    ssid_hex: str                       # exact octets; empty string for an empty SSID
    ssid_escaped: str                   # always safe to show or log
    ssid: Optional[str]                 # text only when it may be offered for joining (valid UTF-8, no controls)
    hidden: bool
    freq_mhz: Optional[int]
    channel: Optional[int]
    band: Optional[str]
    signal_dbm: Optional[float]
    security: str                       # open, wep, wpa1, wpa2, wpa3, sae-only, owe, enterprise, unknown
    akms: Tuple[str, ...]               # "PSK", "SAE", "802.1X", "OWE" found in the RSN/WPA elements
    privacy: bool
    country: Optional[str]
    associated: bool                    # iw marks the BSS the interface is connected to

    @property
    def signal_pct(self) -> Optional[int]:
        """A rough 0-100 figure for a UI bar: -90 dBm and below is 0, -30 dBm and above is 100."""
        if self.signal_dbm is None:
            return None
        return max(0, min(100, int(round((self.signal_dbm + 90.0) * 100.0 / 60.0))))

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["signal_pct"] = self.signal_pct
        return d


_BSS_HDR = re.compile(r"^BSS\s+([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\s*(?:\(on\s+(\S+)\))?(.*)$")
_AKM_NAMES = (("802.1X", "802.1X"), ("SUITE-B", "802.1X"), ("SAE", "SAE"), ("PSK", "PSK"), ("OWE", "OWE"))


def classify_security(has_rsn: bool, has_wpa: bool, rsn_akm: str, wpa_akm: str, privacy: bool) -> str:
    """Map the RSN/WPA elements of a beacon to the security vocabulary of the setup page."""
    if not has_rsn and not has_wpa:
        return "wep" if privacy else "open"
    psk = "PSK" in rsn_akm
    sae = "SAE" in rsn_akm
    ent = "802.1X" in rsn_akm or "SUITE-B" in rsn_akm
    owe = "OWE" in rsn_akm
    if has_rsn:
        if ent and not psk and not sae:
            return "enterprise"
        if owe and not psk and not sae:
            return "owe"
        if sae and psk:
            return "wpa3"
        if sae:
            return "sae-only"
        if psk:
            return "wpa2"
    if has_wpa and "PSK" in wpa_akm:
        return "wpa1"
    if has_wpa and "802.1X" in wpa_akm:
        return "enterprise"
    return "unknown"


def _akm_tokens(text: str) -> Tuple[str, ...]:
    found = []  # type: List[str]
    for needle, name in _AKM_NAMES:
        if needle in text and name not in found:
            found.append(name)
    return tuple(found)


def parse_iw_scan(text: str) -> List[ScanBss]:
    """``iw dev <if> scan dump`` (also ``scan``): one entry per BSS, in the order printed."""
    blocks = []  # type: List[Tuple[Tuple[str, str], List[str]]]
    for raw in iter_lines(text):
        m = _BSS_HDR.match(raw.strip()) if raw.startswith("BSS") else None
        if m:
            blocks.append(((m.group(1).lower(), m.group(3) or ""), []))
        elif blocks:
            blocks[-1][1].append(raw)
    out = []  # type: List[ScanBss]
    for (bssid, tail), lines in blocks[:512]:
        freq = signal = None  # type: Optional[float], Optional[float]
        ssid_raw = b""
        privacy = False
        country = None  # type: Optional[str]
        ie = None  # type: Optional[str]
        has_rsn = has_wpa = False
        rsn_akm = wpa_akm = ""
        for raw in lines[:400]:
            s = raw.strip()
            if not s:
                continue
            lead = raw[:len(raw) - len(raw.lstrip("\t "))]
            top = lead.count("\t") <= 1 and not s.startswith("*")
            if s.startswith("RSN:"):
                ie, has_rsn = "RSN", True
                continue
            if s.startswith("WPA:"):
                ie, has_wpa = "WPA", True
                continue
            if s.startswith("* ") and ie is not None:
                if "Authentication suites:" in s:
                    names = s.split("Authentication suites:", 1)[1]
                    if ie == "RSN":
                        rsn_akm += " " + names
                    else:
                        wpa_akm += " " + names
                continue
            if top:
                ie = None
            key, _, val = s.partition(":")
            val = val.strip()
            if key == "freq":
                freq = to_float(val)
            elif key == "signal":
                signal = to_float(val.split(" ")[0]) if val else None
            elif key == "SSID" and s.startswith("SSID:"):
                ssid_raw = decode_iw_ssid(val)[:32]
            elif key == "capability":
                privacy = privacy or ("Privacy" in val.split("(")[0].split())
            elif key == "Country":
                cm = re.match(r"([A-Za-z0-9]{2})\b", val)
                if cm:
                    country = cm.group(1).upper()
        freq_i = int(round(freq)) if freq is not None else None
        out.append(ScanBss(
            bssid=bssid, ssid_hex=ssid_raw.hex(), ssid_escaped=ssid_escaped(ssid_raw),
            ssid=None if is_hidden_ssid(ssid_raw) else ssid_text(ssid_raw), hidden=is_hidden_ssid(ssid_raw),
            freq_mhz=freq_i, channel=freq_to_channel(freq_i) if freq_i is not None else None,
            band=band_of(freq_i) if freq_i is not None else None, signal_dbm=signal,
            security=classify_security(has_rsn, has_wpa, rsn_akm, wpa_akm, privacy),
            akms=_akm_tokens(rsn_akm + " " + wpa_akm), privacy=privacy, country=country,
            associated="associated" in tail))
    return out


def strongest_per_ssid(entries: List[ScanBss]) -> List[ScanBss]:
    """One entry per (SSID octets, security) - the strongest BSS - strongest first. Hidden networks are kept apart
    (they all share an empty SSID and are not the same network)."""
    best = {}  # type: Dict[Tuple[str, str, str], ScanBss]
    for e in entries:
        key = (e.ssid_hex, e.security, e.bssid if e.hidden else "")
        cur = best.get(key)
        if cur is None or (e.signal_dbm if e.signal_dbm is not None else -999.0) > (
                cur.signal_dbm if cur.signal_dbm is not None else -999.0):
            best[key] = e
    return sorted(best.values(), key=lambda b: (-(b.signal_dbm if b.signal_dbm is not None else -999.0), b.bssid))


def channel_survey(entries: List[ScanBss], band: str = "2.4") -> Dict[int, int]:
    """BSS count per channel in a band, for choosing the least loaded channel."""
    counts = {}  # type: Dict[int, int]
    for e in entries:
        if e.band == band and e.channel is not None:
            counts[e.channel] = counts.get(e.channel, 0) + 1
    return counts


def country_votes(entries: List[ScanBss]) -> Dict[str, int]:
    """How many scanned BSS announce each country code in their Country information element."""
    votes = {}  # type: Dict[str, int]
    for e in entries:
        if e.country and len(e.country) == 2 and e.country[0].isalpha() and e.country[1].isalpha():
            votes[e.country] = votes.get(e.country, 0) + 1
    return votes


# --------------------------------------------------------------------------------------------------------------------
# iw link, station dump
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class LinkInfo:
    connected: bool
    bssid: Optional[str] = None
    ssid_hex: Optional[str] = None
    ssid_escaped: Optional[str] = None
    freq_mhz: Optional[int] = None
    channel: Optional[int] = None
    signal_dbm: Optional[float] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def parse_iw_link(text: str) -> LinkInfo:
    """``iw dev <if> link``."""
    bssid = ssid_raw = None  # type: Optional[str], Optional[bytes]
    freq = signal = None  # type: Optional[float], Optional[float]
    connected = False
    for raw in iter_lines(text):
        s = raw.strip()
        m = re.match(r"^Connected to\s+([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})", s)
        if m:
            connected, bssid = True, m.group(1).lower()
        elif s.startswith("SSID:"):
            ssid_raw = decode_iw_ssid(s[5:].strip())[:32]
        elif s.startswith("freq:"):
            freq = to_float(s[5:].strip())
        elif s.startswith("signal:"):
            signal = to_float(s[7:].strip().split(" ")[0])
    if not connected:
        return LinkInfo(connected=False)
    freq_i = int(round(freq)) if freq is not None else None
    return LinkInfo(connected=True, bssid=bssid, ssid_hex=ssid_raw.hex() if ssid_raw is not None else None,
                    ssid_escaped=ssid_escaped(ssid_raw) if ssid_raw is not None else None, freq_mhz=freq_i,
                    channel=freq_to_channel(freq_i) if freq_i is not None else None, signal_dbm=signal)


@dataclass(frozen=True)
class StationInfo:
    mac: str
    signal_dbm: Optional[float] = None
    inactive_ms: Optional[int] = None
    connected_s: Optional[int] = None
    authorized: Optional[bool] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def parse_iw_station_dump(text: str) -> List[StationInfo]:
    """``iw dev <if> station dump``: the stations associated with an access point interface."""
    out = []  # type: List[StationInfo]
    cur = None  # type: Optional[Dict[str, Any]]
    for raw in iter_lines(text):
        s = raw.strip()
        m = re.match(r"^Station\s+([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\b", s)
        if m:
            if cur is not None:
                out.append(StationInfo(**cur))
            cur = {"mac": m.group(1).lower()}
            continue
        if cur is None:
            continue
        key, _, val = s.partition(":")
        val = val.strip()
        if key == "signal":
            cur["signal_dbm"] = to_float(val.split(" ")[0]) if val else None
        elif key == "inactive time":
            cur["inactive_ms"] = to_int(val.split(" ")[0]) if val else None
        elif key == "connected time":
            cur["connected_s"] = to_int(val.split(" ")[0]) if val else None
        elif key == "authorized":
            cur["authorized"] = True if val.startswith("yes") else (False if val.startswith("no") else None)
    if cur is not None:
        out.append(StationInfo(**cur))
    return out[:256]
