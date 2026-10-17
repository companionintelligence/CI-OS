"""Probe the Wi-Fi hardware and the network state, and choose a radio for the setup access point.

:func:`run_probe` reads (through a read-only runner and a read-only file-system view) and returns one JSON-serialisable
report. :func:`select_radio` is the pure decision at its heart; it works on parsed data so fixtures can drive it.

Choice of radio, in order (report 02, section 4.2):

1. an access-point-capable radio that does not carry the uplink or an association is used for the AP; if another radio is
   there to do the joining the mode is **dedicated** (the AP stays up while the other radio joins the home network);
2. with one radio only: if the driver allows an AP and a station at the same time and on two channels, **concurrent**; if it
   allows both but on one channel only, the AP must sit on the station's channel (``follow_uplink_mhz``) and the join is
   **sequential** unless the uplink exists already;
3. otherwise **sequential**: the AP and the join take turns on the same radio (the phone drops for a few seconds);
4. no radio can run an AP: mode **none**, with the reason, and nothing is touched.
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, replace
from typing import Any, Dict, List, Optional, Sequence, Tuple

from . import regdom, sysinfo
from .errors import ValidationError
from .fs import DictFs, RealFs
from .parsers import ipjson, iw, nmcli, rfkill
from .parsers.iw import IwInterface, PhyInfo
from .runners import CommandResult, FixtureRunner, ReadOnlyRunner, Runner, SubprocessRunner
from .validators import validate_ifname, validate_phy_name

REPORT_VERSION = 1


# --------------------------------------------------------------------------------------------------------------------
# radio selection
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class RadioChoice:
    mode: str                              # dedicated, concurrent, sequential, none
    reason: str                            # ok, no_wifi, no_ap_capable_radio, hard_blocked, no_netdev
    ap_phy: Optional[str] = None
    ap_iface: Optional[str] = None
    sta_phy: Optional[str] = None
    sta_iface: Optional[str] = None
    follow_uplink_mhz: Optional[int] = None    # the AP must use this frequency (one-channel concurrency)
    needs_unblock: bool = False                # soft-blocked by rfkill: unblock before use
    notes: Tuple[str, ...] = ()

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def _netdevs(interfaces: Sequence[IwInterface], phy: str) -> List[IwInterface]:
    return [i for i in interfaces if i.phy == phy and i.name and i.type in ("managed", "AP")]


def select_radio(interfaces: Sequence[IwInterface], phys: Dict[str, PhyInfo],
                 bus: Optional[Dict[str, Dict[str, Optional[str]]]] = None,
                 rfkill_entries: Optional[Sequence[rfkill.RfkillEntry]] = None,
                 uplink_iface: Optional[str] = None,
                 uplink_freq_mhz: Optional[int] = None) -> RadioChoice:
    """Pick the radio for the access point and say how the join will share the air. See the module docstring."""
    bus = bus or {}
    blocks = {e.device: e for e in (rfkill_entries or []) if e.type == "wlan"}
    notes = []  # type: List[str]

    if not phys and not interfaces:
        return RadioChoice(mode="none", reason="no_wifi", notes=("no wireless interface found",))

    uplink_phy = None  # type: Optional[str]
    connected = set()  # type: set
    for i in interfaces:
        if i.name and (i.name == uplink_iface or (i.type == "managed" and i.connected)):
            connected.add(i.phy)
        if i.name and i.name == uplink_iface:
            uplink_phy = i.phy

    eligible = []  # type: List[str]
    hard_blocked = no_netdev = False
    for name, info in sorted(phys.items()):
        if not info.supports_ap:
            continue
        if name in blocks and blocks[name].hard_blocked:
            hard_blocked = True
            notes.append("%s is blocked by a hardware switch" % name)
            continue
        if not _netdevs(interfaces, name):
            no_netdev = True
            continue
        eligible.append(name)
    if not eligible:
        reason = "hard_blocked" if hard_blocked else ("no_netdev" if no_netdev else "no_ap_capable_radio")
        return RadioChoice(mode="none", reason=reason, notes=tuple(notes))

    def rank(phy_name: str) -> Tuple[int, int, int, str]:
        ifs = _netdevs(interfaces, phy_name)
        b = sysinfo.bus_rank((bus.get(ifs[0].name or "", {}) or {}).get("bus")) if ifs else 3
        return (1 if phy_name in connected else 0, b, phys[phy_name].index if phys[phy_name].index is not None else 99,
                phy_name)

    best = sorted(eligible, key=rank)[0]
    ap_ifs = _netdevs(interfaces, best)
    ap_if = sorted(ap_ifs, key=lambda i: (0 if i.type == "AP" else 1, i.name or ""))[0]
    needs_unblock = best in blocks and blocks[best].soft_blocked
    conc = iw.concurrent_ap_sta(phys[best].combos)

    # a second radio that can station-join
    sta_phy = sta_if = None  # type: Optional[str], Optional[str]
    for name in sorted(phys, key=lambda n: (0 if n in connected else 1, phys[n].index if phys[n].index is not None else 99)):
        if name == best or "managed" not in phys[name].modes:
            continue
        cand = [i for i in _netdevs(interfaces, name) if i.type == "managed"]
        if cand and not (name in blocks and blocks[name].hard_blocked):
            sta_phy, sta_if = name, cand[0].name
            break
    if best not in connected and sta_phy is not None:
        return RadioChoice(mode="dedicated", reason="ok", ap_phy=best, ap_iface=ap_if.name, sta_phy=sta_phy,
                           sta_iface=sta_if, needs_unblock=needs_unblock, notes=tuple(notes))
    if best in connected:
        notes.append("every access-point-capable radio is in use for the uplink")
        if conc is not None:
            freq = uplink_freq_mhz
            follow = freq if (conc["channels"] <= 1 and freq is not None) else None
            if conc["channels"] <= 1 and freq is None:
                notes.append("the radio allows one channel for AP and station together but the uplink channel is unknown")
            return RadioChoice(mode="concurrent", reason="ok", ap_phy=best, ap_iface=ap_if.name, sta_phy=best,
                               sta_iface=_first_managed(interfaces, best), follow_uplink_mhz=follow,
                               needs_unblock=needs_unblock, notes=tuple(notes))
        notes.append("the radio cannot run an AP and a station together: the uplink will drop while the AP is up")
        return RadioChoice(mode="sequential", reason="ok", ap_phy=best, ap_iface=ap_if.name, sta_phy=best,
                           sta_iface=_first_managed(interfaces, best), needs_unblock=needs_unblock, notes=tuple(notes))
    # one free radio, nobody else to join with
    if conc is not None and conc["channels"] >= 2:
        return RadioChoice(mode="concurrent", reason="ok", ap_phy=best, ap_iface=ap_if.name, sta_phy=best,
                           sta_iface=_first_managed(interfaces, best), needs_unblock=needs_unblock, notes=tuple(notes))
    if conc is not None:
        notes.append("AP and station share one channel on this radio: the join may need the AP to move")
    return RadioChoice(mode="sequential", reason="ok", ap_phy=best, ap_iface=ap_if.name, sta_phy=best,
                       sta_iface=_first_managed(interfaces, best), needs_unblock=needs_unblock, notes=tuple(notes))


def _first_managed(interfaces: Sequence[IwInterface], phy: str) -> Optional[str]:
    for i in _netdevs(interfaces, phy):
        if i.type == "managed":
            return i.name
    return None


# --------------------------------------------------------------------------------------------------------------------
# summaries (the report is meant to be read; a 6 GHz frequency table is not)
# --------------------------------------------------------------------------------------------------------------------


def phy_summary(phy: PhyInfo) -> Dict[str, Any]:
    usable = {}  # type: Dict[str, List[int]]
    dfs = {}  # type: Dict[str, List[int]]
    passive = {}  # type: Dict[str, List[int]]
    for f in phy.freqs:
        if f.disabled:
            continue
        bucket = usable if f.usable_for_ap else (dfs if f.radar else passive)
        bucket.setdefault(f.band, []).append(f.channel)
    return {
        "name": phy.name, "index": phy.index, "supports_ap": phy.supports_ap, "supports_sae": phy.supports_sae,
        "modes": list(phy.modes), "bands": list(phy.bands()),
        "usable_ap_channels": usable, "dfs_channels": dfs, "passive_only_channels": passive,
        "combos": [c.to_dict() for c in phy.combos], "concurrent_ap_sta": iw.concurrent_ap_sta(phy.combos),
        "start_ap_command": ("start_ap" in phy.commands) if phy.commands else None,
    }


# --------------------------------------------------------------------------------------------------------------------
# the probe
# --------------------------------------------------------------------------------------------------------------------


def _timezone_name(fs: Any) -> Optional[str]:
    text = fs.read_text("/etc/timezone", 128)
    if text and text.strip():
        return text.strip().splitlines()[0][:64]
    target = fs.readlink("/etc/localtime")
    if target and "zoneinfo/" in target:
        return target.split("zoneinfo/", 1)[1][:64]
    return None


def run_probe(runner: Runner, fs: Any, explicit_country: Optional[str] = None,
              include_scan: bool = True) -> Dict[str, Any]:
    """Read the state of the machine and return the report. Never raises for a missing tool or a failing command; the
    ``commands`` section says what ran and what did not. ``explicit_country`` overrides the kernel command line."""
    ro = runner if isinstance(runner, ReadOnlyRunner) else ReadOnlyRunner(runner)
    status = {}  # type: Dict[str, Dict[str, Any]]

    def run(argv: Sequence[str]) -> CommandResult:
        res = ro(list(argv), 8.0)
        status[" ".join(argv)] = {"rc": res.rc, "missing": res.missing, "timed_out": res.timed_out,
                                  "bytes": len(res.stdout)}
        return res

    interfaces = iw.parse_iw_dev(run(["iw", "dev"]).stdout)
    phy_names = []  # type: List[str]
    for i in interfaces:
        if i.phy not in phy_names:
            phy_names.append(i.phy)
    phys = {}  # type: Dict[str, PhyInfo]
    for name in phy_names:
        try:
            validate_phy_name(name)
        except ValidationError:
            continue
        parsed = iw.parse_iw_phy_info(run(["iw", "phy", name, "info"]).stdout)
        for p in parsed:
            phys[p.name] = p
    if phy_names and not phys:
        for p in iw.parse_iw_phy_info(run(["iw", "list"]).stdout):
            phys[p.name] = p
    reg_domains = iw.parse_iw_reg_get(run(["iw", "reg", "get"]).stdout)
    rf = rfkill.parse_rfkill_list(run(["rfkill", "list"]).stdout)
    links = ipjson.parse_ip_link(run(["ip", "-j", "link"]).stdout)
    addrs = ipjson.parse_ip_addr(run(["ip", "-j", "addr"]).stdout)
    routes = ipjson.parse_ip_route(run(["ip", "-j", "route"]).stdout)
    nm_devices = nmcli.parse_device_status(run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION",
                                                "device", "status"]).stdout)
    nm_profiles = nmcli.parse_connection_show(run(["nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE",
                                                   "connection", "show"]).stdout)
    nm_conn = nmcli.parse_connectivity(run(["nmcli", "networking", "connectivity"]).stdout)

    uplink = ipjson.uplink_device(routes)
    bus = {}  # type: Dict[str, Dict[str, Optional[str]]]
    links_by_if = {}  # type: Dict[str, Any]
    scan_entries = []  # type: List[iw.ScanBss]
    for i in interfaces:
        if not i.name:
            continue
        try:
            validate_ifname(i.name)
        except ValidationError:
            continue
        bus[i.name] = sysinfo.bus_info(fs, i.name)
        if i.type == "managed":
            links_by_if[i.name] = iw.parse_iw_link(run(["iw", "dev", i.name, "link"]).stdout)
            if include_scan:
                scan_entries.extend(iw.parse_iw_scan(run(["iw", "dev", i.name, "scan", "dump"]).stdout))

    uplink_freq = None  # type: Optional[int]
    if uplink in links_by_if and links_by_if[uplink].connected:
        uplink_freq = links_by_if[uplink].freq_mhz
    radio = select_radio(interfaces, phys, bus, rf, uplink, uplink_freq)

    cmdline_text = fs.read_text(sysinfo.CMDLINE_PATH, 4096) or ""
    params = sysinfo.parse_cmdline(cmdline_text)
    zone_text = fs.read_text("/usr/share/zoneinfo/zone1970.tab", 1 << 20) or fs.read_text("/usr/share/zoneinfo/zone.tab", 1 << 20)
    tz_country = None
    tz = _timezone_name(fs)
    if zone_text and tz:
        tz_country = sysinfo.country_for_timezone(tz, sysinfo.parse_zone_tab(zone_text))
    explicit = explicit_country or sysinfo.explicit_country(params, fs)
    country = regdom.resolve_country(explicit, reg_domains, iw.country_votes(scan_entries), tz_country,
                                     phy=radio.ap_phy)
    ap_phy_info = phys.get(radio.ap_phy) if radio.ap_phy else None
    survey = iw.channel_survey(scan_entries, "2.4")
    plan = None  # type: Optional[regdom.ChannelPlan]
    if radio.mode != "none":
        plan = regdom.plan_channel(ap_phy_info, country, survey, follow_freq_mhz=radio.follow_uplink_mhz)
        if radio.follow_uplink_mhz is not None and not plan.ok:
            # the radio can only run AP and station on one channel and the uplink's channel is not one an AP may use:
            # the join has to be sequential, and the AP picks its channel freely
            radio = replace(radio, mode="sequential", follow_uplink_mhz=None,
                            notes=radio.notes + ("the uplink channel cannot host the AP: sequential mode",))
            plan = regdom.plan_channel(ap_phy_info, country, survey)

    networks = iw.strongest_per_ssid([e for e in scan_entries if not e.hidden])
    report = {
        "version": REPORT_VERSION,
        "commands": status,
        "interfaces": [dict(i.to_dict(), bus=bus.get(i.name or "")) for i in interfaces],
        "phys": {n: phy_summary(p) for n, p in sorted(phys.items())},
        "regdom": [{"scope": d.scope, "phy": d.phy, "self_managed": d.self_managed, "country": d.country,
                    "dfs": d.dfs, "rules": len(d.rules)} for d in reg_domains],
        "rfkill": {"entries": [e.to_dict() for e in rf], "wlan": rfkill.wlan_block_state(rf)},
        "ip": {"links": [lk.to_dict() for lk in links if lk.name != "lo"][:64],
               "addresses": [a.to_dict() for a in addrs if a.ifname != "lo"][:64],
               "routes": [r.to_dict() for r in routes][:64], "uplink": uplink,
               "used_ipv4_networks": ipjson.used_ipv4_networks(routes, addrs)},
        "network_manager": {"connectivity": nm_conn, "devices": [d.to_dict() for d in nm_devices],
                            "wifi_profiles": [p.to_dict() for p in nm_profiles if p.is_wifi][:64]},
        "wifi_links": {k: v.to_dict() for k, v in sorted(links_by_if.items())},
        "scan": {"count": len(scan_entries),
                 "countries": iw.country_votes(scan_entries),
                 "survey_2_4": {str(k): v for k, v in sorted(survey.items())},
                 "networks": [e.to_dict() for e in networks[:40]]},
        "country": country.to_dict(),
        "radio": radio.to_dict(),
        "channel_plan": plan.to_dict() if plan is not None else None,
        "system": {
            "display": sysinfo.display_state(fs),
            "live": sysinfo.is_live_boot(params), "stick": sysinfo.is_stick_boot(params),
            "headless_param": sysinfo.headless_param(params),
            "claimed": sysinfo.is_claimed(fs), "timezone": tz, "timezone_country": tz_country,
        },
    }
    return report


def default_runner() -> Runner:
    """The runner the CLI uses: real commands, read-only allow-list enforced."""
    return ReadOnlyRunner(SubprocessRunner())


def default_fs() -> RealFs:
    return RealFs()


def fixture_dir_runner(path: str) -> Runner:
    """A read-only runner that answers from ``<path>/commands.json`` (see ``FixtureRunner.from_dir``)."""
    return ReadOnlyRunner(FixtureRunner.from_dir(os.path.abspath(path)))


def fixture_dir_fs(path: str) -> DictFs:
    """The file-system view that goes with a fixture directory: ``<path>/fs.json`` (``{"files": {...}, "links":
    {...}}``) if present, else an empty one - never the real machine, so a fixture run gives the same answer everywhere."""
    spec = os.path.join(os.path.abspath(path), "fs.json")
    if not os.path.exists(spec):
        return DictFs()
    with open(spec, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    return DictFs(files=doc.get("files"), links=doc.get("links"))
