"""Should the setup access point be offered? One decision function, one table.

This replaces the static guards of the old design (``ConditionPathExists=!/cdrom/casper/vmlinuz`` on five units, a 45 s
timer in a shell loop) with a function of the facts, so the answer can be tested for every combination and printed.

The decisions it encodes (docs/architecture/headless-setup.md, "Decisions"):

* A machine with a display attached does not become a hotspot by itself (the desktop has a Wi-Fi settings page).
* An appliance that has been claimed never opens the AP by itself. Recovery is an explicit act: ``ci.headless=1`` on the
  kernel command line, the recovery boot-menu entry, ``ci-setup start`` on the box, or the physical key.
* Plain live media (not a Companion Stick) does not open it by itself either.
* Where it may open by itself (a Stick booted without a display, an unclaimed installed appliance without a display) it does
  so only when the network is down and has been down for the grace period.
* Nothing opens without a way to show the operator the one-time credentials (a console, or a printed setup key) and without
  a radio that can run an access point.
* An event the AP itself or the LAN can cause is never a trigger. Only the names in :data:`TRIGGERS` count; anything else is
  reported in ``ignored_triggers`` and has no effect.

Input values are plain strings so the table can be generated and diffed; invalid ones raise
:class:`~ci_setup.errors.ValidationError`.
"""
from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from typing import Any, Dict, Iterator, List, Optional, Sequence, Tuple

from .errors import ValidationError

CONTEXTS = ("live", "installed-unclaimed", "installed-claimed")
DISPLAYS = ("connected", "headless", "unknown")
NETWORKS = ("up", "down")
HEADLESS_PARAMS = ("0", "1", "auto")
# explicit recovery triggers other than the kernel parameter (which is `headless_param == "1"`)
TRIGGERS = ("menu_entry", "cli", "physical_key")
GRACE_S = 60            # seconds without a usable network before an automatic AP (report 02, 4.3)

PRIMARY_REASONS = (
    "explicit_trigger", "kernel_param_off", "claimed_lockdown", "network_up", "plain_live_media", "display_attached",
    "display_unknown", "provisioning_file_first", "grace_period", "auto_headless_offline", "no_ap_capable_radio",
    "no_credential_channel",
)


@dataclass(frozen=True)
class PolicyInput:
    context: str                                   # live | installed-unclaimed | installed-claimed
    display: str                                   # connected | headless | unknown
    network: str                                   # up | down
    stick: bool = False                            # live only: booted from a Companion Stick
    headless_param: str = "auto"                   # kernel command line ci.headless=0|1 (auto when absent)
    triggers: Tuple[str, ...] = ()                 # explicit recovery triggers actually seen
    ap_capable_radio: bool = True
    has_setup_key: bool = False                    # a printed label / per-stick setup key exists to derive credentials
    static_credentials_test: bool = False          # ci.setup.static_credentials=1 (tests only, needs ci.headless=1)
    provisioning_file: bool = False                # companion-setup.json present on CI-SHARED
    provisioning_failed: bool = False
    network_down_for_s: float = 1e9                # how long the network has been down (default: long enough)

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class Decision:
    offer_ap: bool
    mode: Optional[str]                  # "auto", "explicit" or None
    reason: str                          # first applicable entry of PRIMARY_REASONS
    wait_s: int = 0                      # > 0: would be offered after this many more seconds
    provision_first: bool = False        # apply companion-setup.json before anything else
    credential_channel: Optional[str] = None   # console | label | test_static
    auto_blockers: Tuple[str, ...] = ()  # every reason an automatic AP is ruled out
    blocked_by: Tuple[str, ...] = ()     # prerequisites that are missing
    ignored_triggers: Tuple[str, ...] = ()

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def _check_enum(value: Any, allowed: Sequence[str], field: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise ValidationError(field, "format", "not one of the allowed values")
    return value


def credential_channel(inp: PolicyInput) -> Optional[str]:
    """How the operator will be shown (or can derive) the one-time AP key and PIN, or None."""
    if inp.display == "connected":
        return "console"
    if inp.has_setup_key:
        return "label"
    if inp.static_credentials_test and inp.headless_param == "1":
        return "test_static"
    return None


def decide(inp: PolicyInput) -> Decision:
    """Apply the rules in the module docstring to one set of facts."""
    ctx = _check_enum(inp.context, CONTEXTS, "context")
    display = _check_enum(inp.display, DISPLAYS, "display")
    network = _check_enum(inp.network, NETWORKS, "network")
    hp = _check_enum(inp.headless_param, HEADLESS_PARAMS, "headless_param")

    explicit_seen = []  # type: List[str]
    ignored = []  # type: List[str]
    if hp == "1":
        explicit_seen.append("kernel_param")
    for t in inp.triggers:
        if isinstance(t, str) and t in TRIGGERS:
            explicit_seen.append(t)
        else:
            ignored.append(str(t)[:40])
    explicit = bool(explicit_seen)

    provision_first = bool(inp.provisioning_file and ctx == "live" and inp.stick and not inp.provisioning_failed)

    blockers = []  # type: List[str]
    if hp == "0":
        blockers.append("kernel_param_off")
    if ctx == "installed-claimed":
        blockers.append("claimed_lockdown")
    if network == "up":
        blockers.append("network_up")
    if ctx == "live" and not inp.stick:
        blockers.append("plain_live_media")
    if display == "connected":
        blockers.append("display_attached")
    elif display == "unknown":
        blockers.append("display_unknown")
    if provision_first:
        blockers.append("provisioning_file_first")

    channel = credential_channel(inp)
    missing = []  # type: List[str]
    if not inp.ap_capable_radio:
        missing.append("no_ap_capable_radio")
    if channel is None:
        missing.append("no_credential_channel")

    def result(offer: bool, mode: Optional[str], reason: str, wait: int = 0) -> Decision:
        return Decision(offer_ap=offer, mode=mode, reason=reason, wait_s=wait, provision_first=provision_first,
                        credential_channel=channel, auto_blockers=tuple(blockers), blocked_by=tuple(missing),
                        ignored_triggers=tuple(ignored))

    if explicit:
        if missing:
            return result(False, "explicit", missing[0])
        return result(True, "explicit", "explicit_trigger")
    if blockers:
        return result(False, None, blockers[0])
    if missing:
        return result(False, "auto", missing[0])
    if inp.network_down_for_s < GRACE_S:
        return result(False, "auto", "grace_period", int(math.ceil(GRACE_S - inp.network_down_for_s)))
    return result(True, "auto", "auto_headless_offline")


def network_state(has_default_route: bool, connectivity: str) -> str:
    """Map facts to ``"up"``/``"down"``. A default route with NetworkManager connectivity ``full``, ``limited`` (a link
    but no internet), ``portal`` (an upstream sign-in page: the AP would not help) or ``unknown`` (NetworkManager cannot
    say, and a route exists) counts as up. No route, or connectivity ``none``, is down."""
    return "up" if has_default_route and connectivity in ("full", "limited", "portal", "unknown") else "down"


def context_from_facts(live: bool, claimed: bool) -> str:
    if live:
        return "live"
    return "installed-claimed" if claimed else "installed-unclaimed"


# --------------------------------------------------------------------------------------------------------------------
# the table
# --------------------------------------------------------------------------------------------------------------------


def iter_matrix(has_setup_key: bool = True) -> Iterator[Tuple[PolicyInput, Decision]]:
    """Every combination of context (live split into plain media and Stick), display, network, kernel parameter and one
    explicit trigger or none. ``has_setup_key`` says whether a printed key exists for headless machines."""
    rows = [("live", False), ("live", True), ("installed-unclaimed", False), ("installed-claimed", False)]
    for ctx, stick in rows:
        for display in DISPLAYS:
            for network in NETWORKS:
                for hp in HEADLESS_PARAMS:
                    for trig in ((), ("cli",)):
                        inp = PolicyInput(context=ctx, display=display, network=network, stick=stick,
                                          headless_param=hp, triggers=trig, has_setup_key=has_setup_key)
                        yield inp, decide(inp)


def matrix_table(has_setup_key: bool = True) -> str:
    """The base table for the documentation: automatic behaviour (no kernel parameter, no trigger) for every context,
    display and network state, plus what the kernel parameter ``ci.headless=1`` does."""
    head = "%-30s %-9s %-7s %-34s %-34s" % ("context", "display", "network", "automatic", "with ci.headless=1")
    lines = [head.rstrip(), "-" * len(head.rstrip())]
    for ctx, stick in (("live", False), ("live", True), ("installed-unclaimed", False), ("installed-claimed", False)):
        label = ctx + (" (Stick)" if stick else (" (plain media)" if ctx == "live" else ""))
        for display in ("connected", "headless"):
            for network in ("up", "down"):
                auto = decide(PolicyInput(ctx, display, network, stick=stick, has_setup_key=has_setup_key))
                forced = decide(PolicyInput(ctx, display, network, stick=stick, headless_param="1",
                                            has_setup_key=has_setup_key))
                lines.append(("%-30s %-9s %-7s %-34s %-34s" % (
                    label, display, network, "AP" if auto.offer_ap else "no (" + auto.reason + ")",
                    "AP" if forced.offer_ap else "no (" + forced.reason + ")")).rstrip())
    return "\n".join(lines) + "\n"
