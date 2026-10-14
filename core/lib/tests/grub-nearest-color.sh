#!/usr/bin/env bash
#=============================================================================
# Test: ci_grub_nearest_color (core/lib/grub-merge.sh) maps a hex colour to the right GRUB colour name
#
# menu_color_normal and menu_color_highlight take only names from GRUB's fixed 16-colour table, so the live menu's
# colours are derived from the brand tokens with ci_grub_nearest_color, by squared RGB distance. build-iso.sh writes
# them with it and verify-iso.sh re-derives them with the SAME function, so the two always agree: a wrong row in the
# function's table would be written and then accepted. This test is the independent side. It carries its own copy of
# the table (grub_video_fbstd_colors in GRUB's grub-core/video/fb/video_fb.c, the names from color_list in
# grub-core/normal/color.c, both GRUB 2.12) and requires that
#
#   palette   every one of the 16 colours maps to itself, so no row of the function's table has a wrong name or value;
#   nearest   colours between rows go to the nearest row, and an exact tie to the earlier row;
#   tokens    the brand tokens the live menu uses give the pairs the README documents: the dark foreground is "white",
#             the accent aqua is "cyan" (so white/black for entries and black/cyan for the highlight). If a re-vendored
#             token moves to another GRUB colour this fails, deliberately: look at the menu before changing the expectation;
#   input     anything that is not #rrggbb (with or without the #) is refused with a non-zero status.
#
# Pure bash 3.2, no root, no network, nothing outside the repo is read:
#   core/lib/tests/grub-nearest-color.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
is() { # is "<label>" <expected> <actual>
    if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1 (want '$2', got '$3')"; fi
}

# shellcheck source=../grub-merge.sh
source "$REPO/core/lib/grub-merge.sh"
# shellcheck source=../../../vendor/brand/tokens/tokens.sh
source "$REPO/vendor/brand/tokens/tokens.sh"

# name R G B, as GRUB paints them (0xFE, not 0xFF, for the bright half)
while read -r name r g b; do
    hex="$(printf '#%02x%02x%02x' "$r" "$g" "$b")"
    is "palette: $hex is $name" "$name" "$(ci_grub_nearest_color "$hex")"
done <<'GRUB_PALETTE'
black 0 0 0
blue 0 0 168
green 0 168 0
cyan 0 168 168
red 168 0 0
magenta 168 0 168
brown 168 84 0
light-gray 168 168 168
dark-gray 84 84 84
light-blue 84 84 254
light-green 84 254 84
light-cyan 84 254 254
light-red 254 84 84
light-magenta 254 84 254
yellow 254 254 84
white 254 254 254
GRUB_PALETTE

is "nearest: just off black is black" black "$(ci_grub_nearest_color '#010203')"
is "nearest: a pale grey is light-gray, not white" light-gray "$(ci_grub_nearest_color '#b0b0b0')"
is "nearest: a mid grey is dark-gray, not light-gray" dark-gray "$(ci_grub_nearest_color '#707070')"
is "nearest: upper case digits and no # are accepted" white "$(ci_grub_nearest_color 'FFFFFF')"
# #7e7e7e (126) is 42 from both 84 (dark-gray) and 168 (light-gray) on every channel: the tie goes to the earlier row,
# light-gray, which comes before dark-gray in GRUB's list.
is "nearest: an exact tie goes to the earlier row" light-gray "$(ci_grub_nearest_color '#7e7e7e')"

is "tokens: CI_DARK_FOREGROUND ($CI_DARK_FOREGROUND) is white" white "$(ci_grub_nearest_color "$CI_DARK_FOREGROUND")"
is "tokens: CI_ACCENT_AQUA ($CI_ACCENT_AQUA) is cyan" cyan "$(ci_grub_nearest_color "$CI_ACCENT_AQUA")"
is "tokens: CI_DARK_BACKGROUND ($CI_DARK_BACKGROUND) is black" black "$(ci_grub_nearest_color "$CI_DARK_BACKGROUND")"
is "tokens: the menu colours are white/black (entries) and black/cyan (highlight)" \
    "white/black black/cyan" \
    "$(ci_grub_nearest_color "$CI_DARK_FOREGROUND")/black black/$(ci_grub_nearest_color "$CI_ACCENT_AQUA")"

for bad in "" "#fff" "#12345" "#1234567" "#gggggg" "red" "#12 456"; do
    set +e
    out="$(ci_grub_nearest_color "$bad" 2>/dev/null)"; rc=$?
    set -e
    if [[ $rc -ne 0 && -z "$out" ]]; then t_pass "input: '$bad' is refused"; else t_fail "input: '$bad' was accepted (rc=$rc, output '$out')"; fi
done

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
