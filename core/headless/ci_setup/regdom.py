"""Regulatory-domain policy for the setup access point.

Two questions are answered here, both as pure functions of already-parsed data:

1. **Which country is this machine in?** (:func:`resolve_country`) - from the sources below, strongest first. When none
   is trustworthy the answer is "unknown", never a default: the old service hard-coded ``country_code=US``.

   1. an explicit choice: ``ci.country=XX`` on the kernel command line, or ``/var/lib/setup-device/regdom``;
   2. the country the kernel currently has (``iw reg get``), unless it is the world domain ``00`` or one of the
      special ``97``/``98``/``99`` markers; a phy with a *self-managed* regulatory domain (many Intel chips) is read
      from its own block, because hostapd's ``country_code`` is ignored by such a chip;
   3. the country announced by most of the networks around (the Country information element in the scan), but only
      when at least 3 networks agree and they are at least 60 % of those that announce one;
   4. the country of the time zone, when the time zone belongs to exactly one country;
   5. unknown.

2. **Which channels may an access point use?** (:func:`plan_channel`) - an AP never starts on a DFS channel (it would have
   to listen for radar for 60 s first, and can be forced off), on a channel that is disabled or passive-only in the
   current domain, on 5 GHz without a known country, or on 2.4 GHz channels 12 to 14 without a known country. The
   frequency flags in ``iw phy info`` are the authority for what the *current* domain allows; the static country table
   below only decides, when no flags are available, whether channels 12 and 13 may even be considered. The kernel and the
   chip's firmware still have the last word; this module keeps the setup page from asking for the impossible.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Optional, Tuple

from .errors import ValidationError
from .parsers.common import band_of, freq_to_channel
from .parsers.iw import PhyInfo, RegDomain
from .validators import validate_country

# ISO 3166-1 alpha-2, 249 officially assigned codes.
ISO_COUNTRIES = frozenset("""
AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ
BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ
CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ
DE DJ DK DM DO DZ
EC EE EG EH ER ES ET
FI FJ FK FM FO FR
GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY
HK HM HN HR HT HU
ID IE IL IM IN IO IQ IR IS IT
JE JM JO JP
KE KG KH KI KM KN KP KR KW KY KZ
LA LB LC LI LK LR LS LT LU LV LY
MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ
NA NC NE NF NG NI NL NO NP NR NU NZ
OM
PA PE PF PG PH PK PL PM PN PR PS PT PW PY
QA
RE RO RS RU RW
SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ
TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ
UA UG UM US UY UZ
VA VC VE VG VI VN VU
WF WS
YE YT
ZA ZM ZW
""".split())

# The kernel's markers that are not countries: world domain, "unknown" (set by a driver), intersection, custom.
NON_COUNTRY_CODES = frozenset(["00", "97", "98", "99"])

# Countries where 2.4 GHz channels 12 and 13 are certainly allowed (the EU/EFTA states, the UK and a few more). Every
# other country is treated as channels 1 to 11 only, which is the safe side: the default channels 1, 6 and 11 are
# inside it everywhere that allows 2.4 GHz at all.
CH_1_13 = frozenset("""
AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE
CH LI NO IS GB AU NZ JP KR CN IN SG HK ZA BR TR
""".split())

DEFAULT_24 = (1, 6, 11)                       # the non-overlapping channels
TIE_ORDER_24 = (6, 1, 11)                     # on equal load prefer the middle one
PREFERRED_5 = (36, 40, 44, 48, 149, 153, 157, 161, 165)   # non-DFS channels in the usual order of preference


def is_known_country(code: Any) -> bool:
    """True for an assigned ISO 3166-1 alpha-2 code in upper case (``DE``). ``00``, ``99`` and the rest are not."""
    return isinstance(code, str) and code in ISO_COUNTRIES


# --------------------------------------------------------------------------------------------------------------------
# country resolution
# --------------------------------------------------------------------------------------------------------------------

SOURCES = ("explicit", "kernel", "scan", "timezone", "unknown")


@dataclass(frozen=True)
class CountryDecision:
    code: Optional[str]                 # None when unknown
    source: str                         # one of SOURCES
    confidence: str                     # high, medium, low, none
    self_managed: bool = False          # the radio sets its own domain and ignores hostapd's country_code
    notes: Tuple[str, ...] = ()

    @property
    def known(self) -> bool:
        return self.code is not None

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["known"] = self.known
        return d


def _real_country(code: Optional[str]) -> Optional[str]:
    if code is None or code in NON_COUNTRY_CODES:
        return None
    return code if is_known_country(code) else None


def resolve_country(explicit: Optional[str] = None, reg_domains: Optional[List[RegDomain]] = None,
                    scan_votes: Optional[Dict[str, int]] = None, timezone_country: Optional[str] = None,
                    phy: Optional[str] = None, min_votes: int = 3, min_share: float = 0.6) -> CountryDecision:
    """Decide the country from the sources in the module docstring. Each argument may be None (source unavailable)."""
    notes = []  # type: List[str]
    kernel_code = None  # type: Optional[str]
    self_managed = False
    for dom in reg_domains or []:
        if phy is not None and dom.scope == "phy" and dom.phy == phy and dom.self_managed:
            code = _real_country(dom.country)
            if code:
                kernel_code, self_managed = code, True
                break
    if kernel_code is None:
        for dom in reg_domains or []:
            if dom.scope == "global":
                kernel_code = _real_country(dom.country)
                break

    exp = None  # type: Optional[str]
    if explicit is not None:
        try:
            exp = _real_country(validate_country(explicit))
        except ValidationError:
            exp = None
        if exp is None:
            notes.append("explicit country ignored: not a valid country code")
    if exp is not None:
        if kernel_code is not None and kernel_code != exp:
            notes.append("kernel regulatory domain %s differs from the explicit choice" % kernel_code)
        return CountryDecision(exp, "explicit", "high", self_managed and kernel_code == exp, tuple(notes))

    if kernel_code is not None:
        # a domain the kernel learned from a neighbour (802.11d) is as good as the neighbour's information
        return CountryDecision(kernel_code, "kernel", "medium", self_managed, tuple(notes))

    votes = {k: v for k, v in (scan_votes or {}).items() if _real_country(k)}
    total = sum(votes.values())
    if total >= min_votes:
        top_code = sorted(votes, key=lambda k: (-votes[k], k))[0]
        if votes[top_code] >= min_votes and votes[top_code] >= min_share * total:
            return CountryDecision(top_code, "scan", "low", False, tuple(notes))
        notes.append("neighbouring networks disagree about the country")
    elif total:
        notes.append("too few neighbouring networks announce a country")

    tz = _real_country(timezone_country)
    if tz:
        return CountryDecision(tz, "timezone", "low", False, tuple(notes))
    return CountryDecision(None, "unknown", "none", False, tuple(notes))


# --------------------------------------------------------------------------------------------------------------------
# channel plan
# --------------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class ChannelPlan:
    ok: bool
    band: str                                  # "2.4" or "5" (empty when not ok)
    channel: Optional[int]
    hw_mode: Optional[str]                     # hostapd: "g" or "a"
    candidates: Tuple[int, ...]                # allowed channels in order of preference
    country_code: Optional[str]                # what to put in hostapd's country_code, None to omit it
    world_safe: bool                           # unknown country: 2.4 GHz, channels 1-11, nothing else
    requires_cac: bool                         # a DFS channel was allowed and chosen (60 s radar listening)
    reasons: Tuple[str, ...]
    rejected: Dict[str, str]

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def _load_24(channel: int, survey: Dict[int, int]) -> float:
    """Crowding of a 2.4 GHz channel: BSS on it count fully, on a channel two away half, four away a quarter."""
    load = 0.0
    for ch, n in survey.items():
        d = abs(ch - channel)
        if d == 0:
            load += n
        elif d <= 2:
            load += 0.5 * n
        elif d <= 4:
            load += 0.25 * n
    return load


def plan_channel(phy: Optional[PhyInfo], country: CountryDecision, survey: Optional[Dict[int, int]] = None,
                 want_band: str = "2.4", allow_dfs: bool = False, follow_freq_mhz: Optional[int] = None) -> ChannelPlan:
    """Pick the access-point channel. See the module docstring for the rules.

    ``phy`` is the parsed ``iw phy info`` of the chosen radio (None if not known), ``survey`` is the BSS count per
    channel from a scan (channel -> count), ``want_band`` is ``"2.4"`` (the default and the only band chosen without
    being asked) or ``"5"`` (an explicit request that falls back to 2.4 GHz with a reason when it cannot be met).
    ``allow_dfs`` exists for completeness and is off: with it a DFS channel is only used when nothing else is left.
    ``follow_freq_mhz`` is the uplink's frequency when the radio can run an AP and a station only on one channel: the plan
    then has to be that very channel, and is not ok if the rules above forbid it.
    """
    survey = survey or {}
    reasons = []  # type: List[str]
    rejected = {}  # type: Dict[str, str]
    world_safe = not country.known
    hostapd_country = country.code
    if world_safe:
        reasons.append("country unknown: 2.4 GHz channels 1-11 only, no country_code")
    if follow_freq_mhz is not None:
        return _plan_follow(phy, country, follow_freq_mhz, reasons, rejected)

    if want_band == "5":
        plan = _plan_5ghz(phy, country, survey, allow_dfs, reasons, rejected)
        if plan is not None:
            return plan

    # ---- 2.4 GHz
    usable = None  # type: Optional[set]
    if phy is not None:
        freqs24 = [f for f in phy.freqs if f.band == "2.4"]
        if freqs24:
            usable = set()
            for f in freqs24:
                if f.usable_for_ap:
                    usable.add(f.channel)
                else:
                    rejected[str(f.channel)] = "disabled" if f.disabled else ("passive only" if f.no_ir else "radar")
        else:
            reasons.append("the radio lists no 2.4 GHz channel")
            return ChannelPlan(False, "", None, None, (), hostapd_country, world_safe, False,
                               tuple(reasons + ["no_usable_channel"]), rejected)
    else:
        reasons.append("no frequency table: using the default channels")

    max_allowed = 13 if (country.known and country.code in CH_1_13) else 11
    if usable is None:
        candidates = [c for c in DEFAULT_24]
    else:
        candidates = [c for c in DEFAULT_24 if c in usable]
        if not candidates:
            candidates = sorted(c for c in usable if c <= 11)
            if candidates:
                reasons.append("channels 1, 6 and 11 are not usable here: using the other usable channels")
        if not candidates and max_allowed == 13:
            candidates = sorted(c for c in usable if 12 <= c <= 13)
    if not candidates:
        return ChannelPlan(False, "", None, None, (), hostapd_country, world_safe, False,
                           tuple(reasons + ["no_usable_channel"]), rejected)
    ordered = sorted(candidates, key=lambda c: (_load_24(c, survey), TIE_ORDER_24.index(c) if c in TIE_ORDER_24 else 99, c))
    return ChannelPlan(True, "2.4", ordered[0], "g", tuple(ordered), hostapd_country, world_safe, False,
                       tuple(reasons), rejected)


def _plan_follow(phy: Optional[PhyInfo], country: CountryDecision, mhz: int, reasons: List[str],
                 rejected: Dict[str, str]) -> ChannelPlan:
    """The AP shares the uplink's channel: allowed only if that channel passes the same rules as any other."""
    band = band_of(mhz)
    channel = freq_to_channel(mhz)

    def fail(why: str) -> ChannelPlan:
        return ChannelPlan(False, "", None, None, (), country.code, not country.known, False,
                           tuple(reasons + ["uplink channel unusable for an AP: " + why]), rejected)

    if channel is None or band not in ("2.4", "5"):
        return fail("not a 2.4 or 5 GHz channel")
    if band == "5" and not country.known:
        return fail("5 GHz needs a known country")
    if band == "2.4" and channel > (13 if (country.known and country.code in CH_1_13) else 11):
        return fail("channel not allowed without a known country")
    if phy is not None:
        match = [f for f in phy.freqs if f.mhz == mhz]
        if not match:
            return fail("the radio lists no such frequency")
        if not match[0].usable_for_ap:
            return fail("disabled, passive-only or radar frequency")
    elif band == "5":
        return fail("no frequency table to check 5 GHz against")
    reasons.append("the AP shares the uplink's channel")
    return ChannelPlan(True, band, channel, "g" if band == "2.4" else "a", (channel,), country.code,
                       not country.known, False, tuple(reasons), rejected)


def _plan_5ghz(phy: Optional[PhyInfo], country: CountryDecision, survey: Dict[int, int], allow_dfs: bool,
               reasons: List[str], rejected: Dict[str, str]) -> Optional[ChannelPlan]:
    """The 5 GHz plan, or None (with the reason appended) when 2.4 GHz has to be used instead."""
    if not country.known:
        reasons.append("5 GHz not offered: the country is unknown")
        return None
    if phy is None:
        reasons.append("5 GHz not offered: no frequency table for the radio")
        return None
    freqs = [f for f in phy.freqs if f.band == "5"]
    if not freqs:
        reasons.append("5 GHz not offered: the radio has no 5 GHz band")
        return None
    plain, dfs = [], []
    for f in freqs:
        if f.disabled:
            rejected[str(f.channel)] = "disabled"
        elif f.no_ir and not f.radar:
            rejected[str(f.channel)] = "passive only"
        elif f.radar:
            if allow_dfs and not f.no_ir:
                dfs.append(f.channel)
            else:
                rejected[str(f.channel)] = "radar detection (DFS)" if not f.no_ir else "passive only (DFS)"
        else:
            plain.append(f.channel)
    pref = [c for c in PREFERRED_5 if c in plain] + sorted(c for c in plain if c not in PREFERRED_5)
    requires_cac = False
    if not pref and dfs:
        pref, requires_cac = sorted(dfs), True
        reasons.append("only DFS channels are usable: radar listening of 60 s applies")
    if not pref:
        reasons.append("5 GHz not offered: no channel is usable without DFS")
        return None
    ordered = sorted(pref, key=lambda c: (survey.get(c, 0), pref.index(c)))
    return ChannelPlan(True, "5", ordered[0], "a", tuple(ordered), country.code, False, requires_cac,
                       tuple(reasons), rejected)
