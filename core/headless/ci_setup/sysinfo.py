"""Facts about the machine that the setup policy needs, read through the injectable :mod:`ci_setup.fs` view.

Everything here is a pure function of text or of what a :class:`~ci_setup.fs.DictFs` / ``RealFs`` returns: the kernel
command line, the DRM connector status files (is a display attached), the bus and driver behind a network interface,
the claim state of the appliance, and the ``zone.tab`` timezone-to-country table.
"""
from __future__ import annotations

import re
from typing import Any, Dict, List, Optional, Tuple

from .errors import ValidationError
from .validators import validate_country, validate_ifname

CMDLINE_PATH = "/proc/cmdline"
SETUP_STATE_DIR = "/var/lib/setup-device"
SETUP_CONFIG_DIR = "/etc/setup-device"
CLAIM_FILES = (SETUP_STATE_DIR + "/hub.env", SETUP_STATE_DIR + "/cloud_credentials.json")
# The operator's country choice. /etc/setup-device/regdom is where the stop-gap start script reads it (an administrator edits it);
# /var/lib/setup-device/regdom is the state-directory name of the design and is read too, after it.
REGDOM_FILES = (SETUP_CONFIG_DIR + "/regdom", SETUP_STATE_DIR + "/regdom")

# --------------------------------------------------------------------------------------------------------------------
# kernel command line
# --------------------------------------------------------------------------------------------------------------------


def parse_cmdline(text: str) -> Dict[str, str]:
    """``/proc/cmdline`` to ``{name: value}``. A bare flag has the value ``""``; a double-quoted value may contain
    spaces; a name given twice keeps its last value (the kernel's rule for most parameters); the ``--`` and ``---``
    separators are skipped. At most 256 parameters are read from the first 4096 characters."""
    params = {}  # type: Dict[str, str]
    tokens = []  # type: List[str]
    cur = []  # type: List[str]
    in_quote = False
    for ch in text.strip()[:4096]:
        if ch == '"':
            in_quote = not in_quote
            cur.append(ch)
        elif ch in " \t\n" and not in_quote:
            if cur:
                tokens.append("".join(cur))
                cur = []
        else:
            cur.append(ch)
    if cur:
        tokens.append("".join(cur))
    for tok in tokens[:256]:
        if tok in ("--", "---"):
            continue
        name, _, value = tok.partition("=")
        if not name:
            continue
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]
        params[name[:64]] = value[:256]
    return params


def headless_param(params: Dict[str, str]) -> str:
    """``ci.headless=`` as ``"0"``, ``"1"`` or ``"auto"`` (the default; anything unrecognised is ``auto``)."""
    v = params.get("ci.headless", "auto").strip().lower()
    return v if v in ("0", "1") else "auto"


def is_live_boot(params: Dict[str, str]) -> bool:
    """Booted from live media: casper (Ubuntu), archiso (CachyOS) or a dracut live image (``rd.live.image``; no supported edition uses it)."""
    return params.get("boot") == "casper" or "archisobasedir" in params or "rd.live.image" in params


def is_stick_boot(params: Dict[str, str]) -> bool:
    """Booted from a Companion Stick (its boot entries carry ``ci_stick.slot=A|B``)."""
    return "ci_stick.slot" in params


def explicit_country(params: Dict[str, str], fs: Any = None) -> Optional[str]:
    """The operator's choice of regulatory domain: ``ci.country=XX`` on the kernel command line, else the first line of
    ``/etc/setup-device/regdom``, else of ``/var/lib/setup-device/regdom``. A value that is not two letters is skipped.
    Returns None when absent or malformed."""
    candidates = []  # type: List[str]
    if "ci.country" in params:
        candidates.append(params["ci.country"])
    if fs is not None:
        for path in REGDOM_FILES:
            text = fs.read_text(path, 64)
            if text and text.strip():
                candidates.append(text.strip().splitlines()[0])
    for c in candidates:
        try:
            return validate_country(c.strip())
        except ValidationError:
            continue
    return None


# --------------------------------------------------------------------------------------------------------------------
# display, bus, claim state
# --------------------------------------------------------------------------------------------------------------------

_DRM_CONNECTOR = re.compile(r"^card[0-9]+-(.+)$")


def drm_status(fs: Any, base: str = "/sys/class/drm") -> Dict[str, str]:
    """``{connector: "connected" | "disconnected" | "unknown"}`` for the DRM connectors (``card0-HDMI-A-1`` ...),
    without the always-disconnected Writeback connectors."""
    out = {}  # type: Dict[str, str]
    for entry in fs.listdir(base)[:128]:
        m = _DRM_CONNECTOR.fullmatch(entry)
        if not m or "Writeback" in entry:
            continue
        text = (fs.read_text("%s/%s/status" % (base, entry), 32) or "").strip().lower()
        out[m.group(1)[:48]] = text if text in ("connected", "disconnected", "unknown") else "unknown"
    return out


def display_state(fs: Any, base: str = "/sys/class/drm") -> str:
    """``"connected"``, ``"headless"`` or ``"unknown"``.

    ``unknown`` means /sys/class/drm cannot be read at all; the setup policy treats it like ``connected`` for anything
    automatic, because taking the radio away from a machine whose user has a screen is the worse mistake. A virtual
    GPU (QEMU, virtio) reports a connected connector, so a VM test must set ``ci.headless=1``."""
    if not fs.exists(base):
        return "unknown"
    status = drm_status(fs, base)
    if any(v == "connected" for v in status.values()):
        return "connected"
    return "headless"


def _link_name(target: Optional[str]) -> Optional[str]:
    if not target:
        return None
    name = target.rstrip("/").rsplit("/", 1)[-1]
    return name[:32] if re.fullmatch(r"[A-Za-z0-9_.:-]{1,32}", name) else None


def bus_info(fs: Any, ifname: str) -> Dict[str, Optional[str]]:
    """Where a Wi-Fi interface hangs: ``{"bus": "pci"|"usb"|"sdio"|"platform"|None, "driver", "vendor", "device",
    "phy"}``, from ``/sys/class/net/<if>/device/...``. Nothing is guessed: a link that is missing is None."""
    try:
        validate_ifname(ifname)
    except ValidationError:
        return {"bus": None, "driver": None, "vendor": None, "device": None, "phy": None}
    dev = "/sys/class/net/%s/device" % ifname
    vendor = (fs.read_text(dev + "/vendor", 16) or "").strip()
    device = (fs.read_text(dev + "/device", 16) or "").strip()
    return {
        "bus": _link_name(fs.readlink(dev + "/subsystem")),
        "driver": _link_name(fs.readlink(dev + "/driver")),
        "vendor": vendor if re.fullmatch(r"0x[0-9a-fA-F]{1,8}", vendor) else None,
        "device": device if re.fullmatch(r"0x[0-9a-fA-F]{1,8}", device) else None,
        "phy": _link_name(fs.readlink("/sys/class/net/%s/phy80211" % ifname)),
    }


def bus_rank(bus: Optional[str]) -> int:
    """Preference order for the access-point radio: soldered/PCIe first, then SDIO, USB dongles last (they are the
    ones that get unplugged, and the ones carrying an SSH session on a bench machine)."""
    return {"pci": 0, "platform": 0, "sdio": 1, "usb": 2}.get(bus or "", 3)


def is_claimed(fs: Any) -> bool:
    """The appliance has been claimed once ``hub.env`` or ``cloud_credentials.json`` exists."""
    return any(fs.exists(p) for p in CLAIM_FILES)


# --------------------------------------------------------------------------------------------------------------------
# zone.tab
# --------------------------------------------------------------------------------------------------------------------

_TZ_RE = re.compile(r"^[A-Za-z0-9_+\-]+(?:/[A-Za-z0-9_+\-]+){0,2}$")


def parse_zone_tab(text: str) -> Dict[str, Tuple[str, ...]]:
    """``/usr/share/zoneinfo/zone.tab`` or ``zone1970.tab`` (tab separated: countries, coordinates, zone, comment) to
    ``{zone: (countries...)}``. ``zone1970.tab`` lists several comma-separated countries per row."""
    table = {}  # type: Dict[str, Tuple[str, ...]]
    for line in text.splitlines()[:5000]:
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 3 or not _TZ_RE.fullmatch(cols[2]):
            continue
        countries = tuple(c for c in cols[0].split(",") if len(c) == 2 and c.isascii() and c.isalpha() and c.isupper())
        if countries:
            table[cols[2]] = countries
    return table


def country_for_timezone(tz: str, table: Dict[str, Tuple[str, ...]]) -> Optional[str]:
    """The country of a timezone name, only when the table gives exactly one (``Etc/UTC``, or a zone shared by two
    countries, answers None)."""
    if not isinstance(tz, str) or not _TZ_RE.fullmatch(tz.strip()):
        return None
    countries = table.get(tz.strip())
    return countries[0] if countries and len(countries) == 1 else None
