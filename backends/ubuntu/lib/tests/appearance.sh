#!/usr/bin/env bash
#=============================================================================
# Test: backends/ubuntu/lib/appearance.sh (dark, with a green accent, by default)
#
# The library holds the two GNOME values the Ubuntu image sets for every user, and writes them as a dconf keyfile and as a glib schema
# override. This test checks
#   * the values are ones GNOME's schema accepts, and anything else is refused (a value outside the enum is silently ignored by
#     glib-compile-schemas and stored by dconf as a string that gsettings rejects: no error at build time, no dark theme on the desktop),
#   * the two texts are exactly what the build writes and what verify-iso.sh section 6c reads back,
#   * the accent shares the brand's hue: within 45 degrees of phthalo's CIELAB hue, and one of the two nearest by RGB distance (green and
#     teal; a later edit to orange or purple would fail here). CIELAB distance is not used to rank them: phthalo is far darker than any
#     accent, so lightness dominates it and a grey-blue (slate) comes second,
#   * the dark scheme does not leave the brand's own light-on-dark pairs unreadable: the brand's dark foreground on its dark background,
#     the dark primary on the dark background and the accent on both stay above WCAG contrast 3 (large text and controls) or 4.5 (text).
# Pure bash (3.2 safe) plus python3 for the colour arithmetic; no root, no network.
#   backends/ubuntu/lib/tests/appearance.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../appearance.sh"
TOKENS="$HERE/../../../../vendor/brand/tokens/tokens.sh"
[[ -f "$LIB" && -f "$TOKENS" ]] || { echo "missing $LIB or $TOKENS" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is needed for the colour arithmetic" >&2; exit 2; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=../appearance.sh
source "$LIB"
# shellcheck source=../../../../vendor/brand/tokens/tokens.sh
source "$TOKENS"

echo "== 1. the values"
eq "the colour scheme is prefer-dark" "$CI_OS_COLOR_SCHEME" "prefer-dark"
eq "the accent is green" "$CI_OS_ACCENT_COLOR" "green"
expect "both are values the schema accepts" ci_os_appearance_valid
out="$(CI_OS_ACCENT_COLOR=phthalo ci_os_appearance_valid)"; rc=$?
eq "an accent GNOME does not have is refused (exit 1)" "$rc" "1"
expect "  and the message names the accent and the nine that exist" bash -c 'printf "%s\n" "$1" | grep -q "accent-color .phthalo. is not one of: blue teal green yellow orange red pink purple slate"' _ "$out"
out="$(CI_OS_COLOR_SCHEME=dark ci_os_appearance_valid)"; rc=$?
eq "a colour scheme GNOME does not have is refused (dark is not prefer-dark)" "$rc" "1"
expect "  and the message names it" bash -c 'printf "%s\n" "$1" | grep -q "color-scheme .dark. is not one of: default prefer-dark prefer-light"' _ "$out"
eq "the empty value is refused" "$(CI_OS_ACCENT_COLOR= ci_os_appearance_valid >/dev/null; echo $?)" "1"
eq "the nine accents are GNOME 47's" "$CI_OS_ACCENT_COLORS" "blue teal green yellow orange red pink purple slate"

echo
echo "== 2. the two texts"
eq "the dconf keyfile" "$(ci_os_appearance_dconf)" "$(printf "[org/gnome/desktop/interface]\ncolor-scheme='prefer-dark'\naccent-color='green'")"
eq "the schema override" "$(ci_os_appearance_override)" "$(printf "[org.gnome.desktop.interface]\ncolor-scheme='prefer-dark'\naccent-color='green'")"
expect "the keyfile parses and holds the two keys as quoted strings (the form dconf and glib expect for a string)" python3 -I -c '
import configparser, sys
c = configparser.RawConfigParser(); c.optionxform = str
c.read_string(sys.argv[1])
assert c.sections() == ["org/gnome/desktop/interface"], c.sections()
s = c["org/gnome/desktop/interface"]
assert dict(s) == {"color-scheme": "'"'"'prefer-dark'"'"'", "accent-color": "'"'"'green'"'"'"}, dict(s)
' "$(ci_os_appearance_dconf)"
expect "a changed value flows into both texts (one edit changes everything the build writes)" bash -c '. "$1"; CI_OS_ACCENT_COLOR=teal; ci_os_appearance_dconf | grep -q "accent-color=.teal." && ci_os_appearance_override | grep -q "accent-color=.teal."' _ "$LIB"

echo
echo "== 3. the accent against the brand"
# The nine accents as libadwaita 1.6 defines them (accent background colours). A rounding error in one of these moves a distance by a unit
# or two and changes nothing below, which only asks for the two nearest by RGB and for a hue within 45 degrees.
ACCENTS="blue=#3584e4 teal=#2190a4 green=#3a944a yellow=#c88800 orange=#ed5b00 red=#e62d42 pink=#d56199 purple=#9141ac slate=#6f8396"
nearest="$(python3 -I - "$CI_LIGHT_PRIMARY" "$ACCENTS" <<'PYEOF'
import math, sys

def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def lin(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def lab(h):
    r, g, b = (lin(c) for c in rgb(h))
    x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))

def hue(h):
    _, a, b = lab(h)
    return math.degrees(math.atan2(b, a)) % 360

def hue_gap(x, y):
    d = abs(hue(x) - hue(y)) % 360
    return min(d, 360 - d)

brand = sys.argv[1]
acc = dict(kv.split("=") for kv in sys.argv[2].split())
by_rgb = sorted(acc, key=lambda a: math.dist(rgb(brand), rgb(acc[a])))
by_hue = sorted(acc, key=lambda a: hue_gap(brand, acc[a]))
print(" ".join(by_rgb[:2]), "|", " ".join(a for a in by_hue if hue_gap(brand, acc[a]) <= 45), "|",
      "%.0f %.0f" % (math.dist(rgb(brand), rgb(acc["green"])), math.dist(rgb(brand), rgb(acc["teal"]))), "|",
      "%.0f %.0f" % (hue_gap(brand, acc["green"]), hue_gap(brand, acc["teal"])))
PYEOF
)"
echo "info  brand primary $CI_LIGHT_PRIMARY: nearest two by RGB distance | accents within 45 degrees of its CIELAB hue | RGB distance green teal | hue gap in degrees green teal: $nearest"
by_rgb="${nearest%% | *}"; rest="${nearest#* | }"; by_hue="${rest%% | *}"
expect "the accent is among the two nearest to phthalo by RGB distance ($by_rgb)" bash -c 'case " $1 " in *" $2 "*) true ;; *) false ;; esac' _ "$by_rgb" "$CI_OS_ACCENT_COLOR"
expect "  and within 45 degrees of its CIELAB hue ($by_hue)" bash -c 'case " $1 " in *" $2 "*) true ;; *) false ;; esac' _ "$by_hue" "$CI_OS_ACCENT_COLOR"
expect "  orange (Ubuntu's own default) and purple are in neither list, so an edit to either would fail the two tests above" bash -c 'for a in orange purple red; do case " $1 $2 " in *" $a "*) exit 1 ;; esac; done' _ "$by_rgb" "$by_hue"

echo
echo "== 4. light on dark: the brand's pairs stay readable on a dark scheme"
# WCAG 2.x contrast ratio of two colours; 4.5 for text, 3 for large text and controls. The brand ships dark tokens for exactly this; the check
# says the pairs this image shows on a dark desktop (text on the ground, the accent on the ground) have not been broken by a token change.
ratio() { python3 -I -c '
import sys
def lum(h):
    h = h.lstrip("#"); r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    f = lambda c: c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
a, b = lum(sys.argv[1]), lum(sys.argv[2])
hi, lo = max(a, b), min(a, b)
print("%.2f" % ((hi + 0.05) / (lo + 0.05)))
' "$1" "$2"; }
atleast() { python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$1" "$2"; }
r1="$(ratio "$CI_DARK_FOREGROUND" "$CI_DARK_BACKGROUND")"; r2="$(ratio "$CI_DARK_PRIMARY" "$CI_DARK_BACKGROUND")"
r3="$(ratio "#3a944a" "$CI_DARK_BACKGROUND")"; r4="$(ratio "$CI_DARK_PRIMARY_FOREGROUND" "$CI_DARK_PRIMARY")"
expect "the brand's dark foreground on its dark background is readable text (contrast $r1, want 4.5)" atleast "$r1" 4.5
expect "  its sage primary on the dark background is readable text (contrast $r2, want 4.5)" atleast "$r2" 4.5
expect "  its dark ground on a sage button is readable text (contrast $r4, want 4.5)" atleast "$r4" 4.5
expect "  and the green accent (libadwaita #3a944a) on that background is a visible control (contrast $r3, want 3)" atleast "$r3" 3

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
