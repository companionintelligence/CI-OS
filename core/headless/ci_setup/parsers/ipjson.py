"""Parsers for ``ip -j link``, ``ip -j addr`` and ``ip -j route`` (iproute2 JSON output).

The JSON key names are those of iproute2 (``ifname``, ``operstate``, ``addr_info``, ``dst``, ``gateway``, ``dev``,
``protocol``, ``metric``, ``prefsrc``). Old iproute2 prints nothing at all (not ``[]``) for an empty route table; that
is read as an empty list. Records that do not look right are skipped.
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Optional, Tuple

from ..errors import ValidationError
from ..validators import parse_ipv4


def _load_list(text: str) -> List[Any]:
    if not isinstance(text, str) or not text.strip():
        return []
    try:
        doc = json.loads(text)
    except (ValueError, RecursionError):
        return []
    return doc if isinstance(doc, list) else []


def _s(value: Any, limit: int = 64) -> Optional[str]:
    return value[:limit] if isinstance(value, str) else None


def _i(value: Any) -> Optional[int]:
    return value if type(value) is int else None


@dataclass(frozen=True)
class IpLink:
    ifindex: int
    name: str
    flags: Tuple[str, ...]
    operstate: Optional[str]
    link_type: Optional[str]
    mac: Optional[str]
    mtu: Optional[int]
    master: Optional[str]

    @property
    def is_up(self) -> bool:
        return "UP" in self.flags

    @property
    def has_carrier(self) -> bool:
        return "LOWER_UP" in self.flags

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["is_up"] = self.is_up
        d["has_carrier"] = self.has_carrier
        return d


def parse_ip_link(text: str) -> List[IpLink]:
    out = []  # type: List[IpLink]
    for it in _load_list(text)[:512]:
        if not isinstance(it, dict):
            continue
        idx, name = _i(it.get("ifindex")), _s(it.get("ifname"), 32)
        if idx is None or not name:
            continue
        flags = it.get("flags")
        out.append(IpLink(
            ifindex=idx, name=name,
            flags=tuple(f[:24] for f in flags[:32] if isinstance(f, str)) if isinstance(flags, list) else (),
            operstate=_s(it.get("operstate"), 24), link_type=_s(it.get("link_type"), 24),
            mac=(_s(it.get("address"), 17) or "").lower() or None, mtu=_i(it.get("mtu")),
            master=_s(it.get("master"), 32)))
    return out


@dataclass(frozen=True)
class IpAddr:
    ifname: str
    family: str                  # inet, inet6
    local: str
    prefixlen: Optional[int]
    scope: Optional[str]

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def parse_ip_addr(text: str) -> List[IpAddr]:
    out = []  # type: List[IpAddr]
    for it in _load_list(text)[:512]:
        if not isinstance(it, dict):
            continue
        name = _s(it.get("ifname"), 32)
        infos = it.get("addr_info")
        if not name or not isinstance(infos, list):
            continue
        for info in infos[:64]:
            if not isinstance(info, dict):
                continue
            fam, local = _s(info.get("family"), 8), _s(info.get("local"), 64)
            if fam in ("inet", "inet6") and local:
                out.append(IpAddr(ifname=name, family=fam, local=local, prefixlen=_i(info.get("prefixlen")),
                                  scope=_s(info.get("scope"), 16)))
    return out


@dataclass(frozen=True)
class IpRoute:
    dst: str                     # "default" or a prefix
    gateway: Optional[str]
    dev: Optional[str]
    protocol: Optional[str]
    scope: Optional[str]
    metric: int
    prefsrc: Optional[str]
    type: str                    # unicast unless the record says unreachable/blackhole/...

    @property
    def is_default(self) -> bool:
        return self.dst in ("default", "0.0.0.0/0", "::/0")

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["is_default"] = self.is_default
        return d


def parse_ip_route(text: str) -> List[IpRoute]:
    out = []  # type: List[IpRoute]
    for it in _load_list(text)[:2048]:
        if not isinstance(it, dict):
            continue
        dst = _s(it.get("dst"), 64)
        if not dst:
            continue
        metric = _i(it.get("metric"))
        out.append(IpRoute(dst=dst, gateway=_s(it.get("gateway"), 64), dev=_s(it.get("dev"), 32),
                           protocol=_s(it.get("protocol"), 24), scope=_s(it.get("scope"), 16),
                           metric=metric if metric is not None else 0, prefsrc=_s(it.get("prefsrc"), 64),
                           type=_s(it.get("type"), 16) or "unicast"))
    return out


def default_routes(routes: List[IpRoute]) -> List[IpRoute]:
    """Usable default routes, lowest metric first (the kernel's choice). Routes of type unreachable, prohibit or
    blackhole are not usable."""
    usable = [r for r in routes if r.is_default and r.type == "unicast" and r.dev]
    return sorted(usable, key=lambda r: (r.metric, r.dev or ""))


def uplink_device(routes: List[IpRoute], exclude: Tuple[str, ...] = ()) -> Optional[str]:
    """The interface that carries the preferred default route, skipping any in ``exclude`` (the AP interface)."""
    for r in default_routes(routes):
        if r.dev not in exclude:
            return r.dev
    return None


def used_ipv4_networks(routes: List[IpRoute], addrs: List[IpAddr]) -> List[str]:
    """CIDR strings of IPv4 networks already on the machine (routes with a prefix, and addresses of interfaces),
    for choosing an access-point subnet that collides with nothing."""
    nets = []  # type: List[str]
    for r in routes:
        if ":" in r.dst or r.dst == "default":
            continue
        if "/" in r.dst:
            cidr = r.dst
        else:
            try:  # a host route prints as a bare address
                parse_ipv4(r.dst)
            except ValidationError:
                continue
            cidr = r.dst + "/32"
        if cidr not in nets:
            nets.append(cidr)
    for a in addrs:
        if a.family == "inet" and a.prefixlen is not None:
            cidr = "%s/%d" % (a.local, a.prefixlen)
            if cidr not in nets:
                nets.append(cidr)
    return nets
