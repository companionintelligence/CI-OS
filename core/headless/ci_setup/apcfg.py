"""hostapd and dnsmasq configuration for the setup access point, rendered from validated parameters.

The only inputs are typed parameter objects whose constructors validate every field; the templates are in
``ci_setup/templates``. The SSID is written as ``ssid2=<hex of its UTF-8 bytes>`` - the hostapd.conf reference documents the
hex form - so a space at either end, ``#``, ``=``, quotes or any non-ASCII character cannot be misread. The passphrase goes
into ``wpa_passphrase=`` (or ``wpa_psk=`` for a raw 64-digit key); hostapd's parser takes the rest of the line verbatim and
a validated passphrase cannot contain a line break.

A rendered hostapd file contains the AP key. This module returns text; the caller writes it (mode 0600, under /run) with
:func:`ci_setup.privfile.write_private_file`.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Dict, Optional, Sequence

from .errors import ValidationError
from .templating import lint_config, load_template, render_template
from .validators import (Ipv4Net, format_ipv4, is_hex64, parse_cidr, ssid_bytes, validate_channel,
                         validate_country, validate_ifname, validate_ipv4_subnet, validate_psk, validate_ssid)

DEFAULT_SUBNET = "192.168.99.0/24"
FALLBACK_BLOCK = "10.77.0.0/16"     # candidates /24s are taken from here when the default collides
_RUN_PATH = re.compile(r"^/run/[A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+){0,4}$")


def _run_path(value: str, field: str) -> str:
    if not isinstance(value, str) or len(value) > 100 or ".." in value or not _RUN_PATH.fullmatch(value):
        raise ValidationError(field, "format", "an absolute path under /run")
    return value


@dataclass(frozen=True)
class ApParams:
    iface: str
    ssid: str
    passphrase: str
    channel: int
    band: str = "2.4"                     # "2.4" or "5"
    country: Optional[str] = None         # None: omit country_code (unknown country)
    max_sta: int = 4
    ctrl_dir: str = "/run/ci-setup/hostapd-ctrl"

    def __post_init__(self) -> None:
        validate_ifname(self.iface, "iface")
        validate_ssid(self.ssid, "ssid")
        validate_psk(self.passphrase, "passphrase")
        if self.band not in ("2.4", "5"):
            raise ValidationError("band", "format", "2.4 or 5")
        validate_channel(self.channel, self.band, "channel")
        if self.band == "2.4" and self.channel > 13:
            raise ValidationError("channel", "range", "channel 14 is not used")
        if self.country is not None:
            validate_country(self.country, "country")
            if self.country != self.country.upper():
                raise ValidationError("country", "format", "upper case")
        if type(self.max_sta) is not int or not 1 <= self.max_sta <= 8:
            raise ValidationError("max_sta", "range", "1 to 8")
        _run_path(self.ctrl_dir, "ctrl_dir")


def render_hostapd(p: ApParams) -> str:
    """The hostapd configuration. Contains the AP key."""
    if p.country is None:
        country_lines = "# country_code omitted: the country is unknown"
    else:
        country_lines = "country_code=%s\nieee80211d=1" % p.country
    if is_hex64(p.passphrase):
        psk_line = "wpa_psk=%s" % p.passphrase.lower()
    else:
        psk_line = "wpa_passphrase=%s" % p.passphrase
    text = render_template(load_template("hostapd.conf.in"), {
        "IFACE": p.iface, "CTRL_DIR": p.ctrl_dir, "SSID_HEX": ssid_bytes(p.ssid).hex(),
        "COUNTRY_LINES": country_lines, "HW_MODE": "g" if p.band == "2.4" else "a", "CHANNEL": str(p.channel),
        "PSK_LINE": psk_line, "MAX_STA": str(p.max_sta),
    }, multiline=("COUNTRY_LINES",))
    lint_config(text)
    return text


@dataclass(frozen=True)
class DhcpParams:
    iface: str
    subnet: str = DEFAULT_SUBNET          # a /24
    run_dir: str = "/run/ci-setup"
    lease: str = "2h"

    def __post_init__(self) -> None:
        validate_ifname(self.iface, "iface")
        net = validate_ipv4_subnet(self.subnet, "subnet")      # aligned and private (RFC 1918)
        if net.prefix != 24:
            raise ValidationError("subnet", "range", "the access point serves a /24")
        _run_path(self.run_dir, "run_dir")
        if not re.fullmatch(r"[1-9][0-9]{0,2}[hm]", self.lease):
            raise ValidationError("lease", "format", "like 2h or 30m")

    def net(self) -> Ipv4Net:
        return parse_cidr(self.subnet, "subnet")


def ap_addresses(net: Ipv4Net) -> Dict[str, str]:
    """For a /24: the AP address (.1), the DHCP range (.10 to .250) and the netmask."""
    return {"ap_ip": format_ipv4(net.address(1)), "range_start": format_ipv4(net.address(10)),
            "range_end": format_ipv4(net.address(250)), "netmask": net.netmask_str()}


def render_dnsmasq(p: DhcpParams) -> str:
    """The dnsmasq configuration: DHCP and a catch-all DNS on the AP address, nothing forwarded, no query log."""
    a = ap_addresses(p.net())
    text = render_template(load_template("dnsmasq.conf.in"), {
        "IFACE": p.iface, "AP_IP": a["ap_ip"], "RANGE_START": a["range_start"], "RANGE_END": a["range_end"],
        "NETMASK": a["netmask"], "LEASE": p.lease, "RUN_DIR": p.run_dir,
    })
    lint_config(text, allow_bare=True)
    return text


def pick_ap_subnet(used: Sequence[str], preferred: str = DEFAULT_SUBNET) -> Ipv4Net:
    """The /24 for the access point that collides with no network in ``used`` (CIDR strings from the routing table and
    the interface addresses): ``preferred`` if free, else the first free /24 inside 10.77.0.0/16. Raises ValidationError
    when every candidate is taken."""
    taken = []
    for u in used:
        try:
            taken.append(parse_cidr(u, "used", strict=False))
        except ValidationError:
            continue
    first = validate_ipv4_subnet(preferred, "subnet")
    if first.prefix != 24:
        raise ValidationError("subnet", "range", "the access point serves a /24")
    block = parse_cidr(FALLBACK_BLOCK, "block")
    candidates = [first] + [Ipv4Net(block.network + (i << 8), 24) for i in range(256)]
    for cand in candidates:
        if not any(cand.overlaps(t) for t in taken):
            return cand
    raise ValidationError("subnet", "range", "no free /24 for the access point")
