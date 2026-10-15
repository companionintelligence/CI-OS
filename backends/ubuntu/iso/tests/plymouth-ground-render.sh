#!/usr/bin/env bash
#=============================================================================
# Test: the REAL Plymouth plugin fills the splash with the canon navy, not black, from the repainted bgrt theme
#
# The live boot's splash ground was pure black although the repainted bgrt.plymouth carried BackgroundStartColor=0x041620:
# stock bgrt sets UseFirmwareBackground=true in [boot-up], [shutdown] and [reboot], and the two-step plugin then paints a
# hard-coded black behind the firmware's boot logo (or bgrt-fallback.png) and never looks at BackgroundStartColor. The
# unit-style tests (boot-media-plymouth.sh, desktop-theme/tests/plymouth-theme.sh) check the theme FILES; this one checks
# what the plugin DRAWS. It starts the real plymouthd of the Ubuntu packages on its X11 renderer, in a virtual X server (no
# DRM, no framebuffer, no VM), shows the splash for each theme file below and reads the ground off a screenshot:
#
#   stock bgrt                           black     (the starting point: the stock theme)
#   navy keys, firmware background on    black     (what v6 shipped: the four colour lines repainted, nothing else,
#                                                   i.e. the bug; proves the harness can tell black from navy)
#   navy keys, ONE section still true    black     (all or nothing: the plugin loads the firmware images when any mode
#                                                   asks for them and paints black in every mode that does not)
#   bgrt after ci_plymouth_recolor       navy      (what the live initrd and the rootfs now carry)
#   spinner after ci_plymouth_recolor    navy      (the theme that never had the key)
#
# The colour is the canon's: CI_DARK_BACKGROUND from vendor/brand/tokens, compared on four corners and the middle of the
# left edge, where no logo or spinner is drawn. What this does NOT show: the DRM/simpledrm/efifb renderers a real boot
# uses (the ground logic is in the plugin, above the renderer, so it is the same code), the kernel's acceptance of the initrd
# overlay, real BGRT firmware logos, or anything about a booted guest.
#
# It changes /usr/share/plymouth and /etc/plymouth of the machine it runs on, so run it in a throw-away container:
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:24.04 bash -c \
#     'apt-get update -qq && apt-get install -y -qq plymouth plymouth-x11 plymouth-theme-spinner xvfb imagemagick bsdutils \
#      && bash /repo/backends/ubuntu/iso/tests/plymouth-ground-render.sh'
#
# (CI_TEST_ALLOW_HOST=1 overrides the container check on a disposable VM.) CI_TEST_KEEP_SHOTS=<dir> keeps the screenshots.
# Exit status is non-zero if any check fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { # expect "<label>" <command...>
    local label="$1"; shift
    if "$@"; then t_pass "$label"; else t_fail "$label"; fi
}

if [[ "$(id -u)" -ne 0 ]]; then echo "needs root: run it in a throw-away container" >&2; exit 2; fi
if [[ ! -e /.dockerenv && ! -e /run/.containerenv && "${CI_TEST_ALLOW_HOST:-0}" != 1 ]]; then
    echo "refusing to re-skin this machine: run it in a throw-away container (or set CI_TEST_ALLOW_HOST=1)" >&2
    exit 2
fi
for t in plymouthd plymouth Xvfb import convert script sed awk; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t (apt-get install plymouth plymouth-x11 plymouth-theme-spinner xvfb imagemagick bsdutils)" >&2; exit 2; }
done
THEMES=/usr/share/plymouth/themes
for f in bgrt/bgrt.plymouth spinner/spinner.plymouth; do
    [[ -f "$THEMES/$f" ]] || { echo "missing $THEMES/$f (apt-get install plymouth-theme-spinner)" >&2; exit 2; }
done
ls /usr/lib/*/plymouth/renderers/x11.so >/dev/null 2>&1 || { echo "missing the X11 renderer (apt-get install plymouth-x11)" >&2; exit 2; }

# shellcheck source=../../../../core/lib/theme-lib.sh
source "$REPO/core/lib/theme-lib.sh"

WORK="$(mktemp -d)"
cleanup() {
    pkill plymouthd 2>/dev/null || true
    pkill Xvfb 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

W=1280; H=800
export DISPLAY=:99
Xvfb "$DISPLAY" -screen 0 "${W}x${H}x24" >"$WORK/xvfb.log" 2>&1 &
sleep 2

# render_theme <theme name> <conf file> <out png>: show the splash with <conf> installed as <theme name>'s file
render_theme() {
    local name="$1" conf="$2" out="$3"
    pkill plymouthd 2>/dev/null || true
    sleep 0.5
    rm -rf /run/plymouth; mkdir -p /run/plymouth /etc/plymouth
    cp -f "$conf" "$THEMES/$name/$name.plymouth"
    printf '[Daemon]\nTheme=%s\nShowDelay=0\n' "$name" > /etc/plymouth/plymouthd.conf
    # A controlling terminal is what the X11 renderer attaches its text display to: `script` supplies a pty. The kernel
    # command line is given, not read, so a container with a serial console does not switch plymouthd to details mode.
    script -qfec "plymouthd --mode=boot --no-daemon --tty=/dev/tty --pid-file=/run/plymouth/pid \
        --kernel-command-line='plymouth.ignore-serial-consoles plymouth.ignore-udev splash'" /dev/null >"$WORK/plymouthd.out" 2>&1 &
    sleep 2
    plymouth --show-splash >/dev/null 2>&1 || true
    sleep 3
    import -window root "$out" >/dev/null 2>&1 || true
    plymouth quit >/dev/null 2>&1 || true
    sleep 1
    pkill plymouthd 2>/dev/null || true
}
colours_of() { convert "$1" -format '%k' info: 2>/dev/null; } # colours_of <png>: how many distinct colours the screenshot has
pixel() { convert "$1" -format '%[hex:u.p{'"$2"','"$3"'}]' info: 2>/dev/null | tr 'a-f' 'A-F'; } # pixel <png> <x> <y>: RRGGBB
# ground_of <png>: the one colour all five ground samples share (RRGGBB), or "mixed:<list>"
ground_of() {
    local list first c
    list="$(pixel "$1" 5 5) $(pixel "$1" $((W - 6)) 5) $(pixel "$1" 5 $((H - 6))) $(pixel "$1" $((W - 6)) $((H - 6))) $(pixel "$1" 5 $((H / 2)))"
    first="${list%% *}"
    for c in $list; do [[ "$c" == "$first" ]] || { echo "mixed:$list"; return; }; done
    echo "$first"
}

NAVY="$(printf '%s' "${CI_DARK_BACKGROUND#\#}" | tr 'a-f' 'A-F')"
BLACK=000000
STOCK_BGRT="$WORK/stock-bgrt.plymouth"; cp "$THEMES/bgrt/bgrt.plymouth" "$STOCK_BGRT"
STOCK_SPINNER="$WORK/stock-spinner.plymouth"; cp "$THEMES/spinner/spinner.plymouth" "$STOCK_SPINNER"
expect "precondition: Ubuntu's bgrt asks for the firmware background in boot-up, shutdown and reboot" \
    test "$(grep -c '^UseFirmwareBackground=true' "$STOCK_BGRT")" -eq 3

# The variants. "v6" is the previous ci_plymouth_recolor, which repainted the colour lines and left the firmware background on.
cp "$STOCK_BGRT" "$WORK/v6-bgrt.plymouth"
sed -i -e "s/BackgroundStartColor=0x[0-9a-fA-F]*/BackgroundStartColor=$(ci_hex0x "$CI_DARK_BACKGROUND")/" \
       -e "s/BackgroundEndColor=0x[0-9a-fA-F]*/BackgroundEndColor=$(ci_hex0x "$CI_DARK_BACKGROUND")/" "$WORK/v6-bgrt.plymouth"
# ...and the same with only the [boot-up] section switched off (the other two modes still ask for the firmware background)
awk '/^\[/ { sec = $0 } sec == "[boot-up]" && /^UseFirmwareBackground=true/ { print "UseFirmwareBackground=false"; next } { print }' \
    "$WORK/v6-bgrt.plymouth" > "$WORK/partial-bgrt.plymouth"
cp "$STOCK_BGRT" "$WORK/v7-bgrt.plymouth";       ci_plymouth_recolor "$WORK/v7-bgrt.plymouth"
cp "$STOCK_SPINNER" "$WORK/v7-spinner.plymouth"; ci_plymouth_recolor "$WORK/v7-spinner.plymouth"

SHOTS="$WORK/shots"; mkdir -p "$SHOTS"
render_theme bgrt    "$STOCK_BGRT"                    "$SHOTS/stock-bgrt.png"
render_theme bgrt    "$WORK/v6-bgrt.plymouth"         "$SHOTS/v6-bgrt.png"
render_theme bgrt    "$WORK/partial-bgrt.plymouth"    "$SHOTS/partial-bgrt.png"
render_theme bgrt    "$WORK/v7-bgrt.plymouth"         "$SHOTS/v7-bgrt.png"
render_theme spinner "$WORK/v7-spinner.plymouth"      "$SHOTS/v7-spinner.png"
cp -f "$STOCK_BGRT" "$THEMES/bgrt/bgrt.plymouth"; cp -f "$STOCK_SPINNER" "$THEMES/spinner/spinner.plymouth"

for f in stock-bgrt v6-bgrt partial-bgrt v7-bgrt v7-spinner; do
    expect "screenshot $f.png exists and is ${W}x${H} (the splash was shown)" \
        test "$(identify -format '%wx%h' "$SHOTS/$f.png" 2>/dev/null || convert "$SHOTS/$f.png" -format '%wx%h' info: 2>/dev/null)" = "${W}x${H}"
done
# A black ground only means something if the splash is really on the screen (an empty X root is black too): every shot
# has the spinner and the watermark on it, so it holds many more colours than a flat fill.
for f in stock-bgrt v6-bgrt partial-bgrt v7-bgrt v7-spinner; do
    expect "$f.png is a drawn splash, not an empty screen ($(colours_of "$SHOTS/$f.png") colours)" test "$(colours_of "$SHOTS/$f.png")" -gt 8
done
expect "stock bgrt: the ground is black ($BLACK)" test "$(ground_of "$SHOTS/stock-bgrt.png")" = "$BLACK"
expect "navy colour lines with the firmware background on (what v6 shipped): the ground is STILL black, the bug this fixes" \
    test "$(ground_of "$SHOTS/v6-bgrt.png")" = "$BLACK"
expect "navy colour lines with only [boot-up] switched off: still black (the other modes make the plugin paint black everywhere)" \
    test "$(ground_of "$SHOTS/partial-bgrt.png")" = "$BLACK"
expect "bgrt after ci_plymouth_recolor: the ground is the canon dark background ($NAVY)" test "$(ground_of "$SHOTS/v7-bgrt.png")" = "$NAVY"
expect "spinner after ci_plymouth_recolor: the ground is the canon dark background ($NAVY)" test "$(ground_of "$SHOTS/v7-spinner.png")" = "$NAVY"

if [[ -n "${CI_TEST_KEEP_SHOTS:-}" ]]; then
    mkdir -p "$CI_TEST_KEEP_SHOTS" && cp "$SHOTS"/*.png "$CI_TEST_KEEP_SHOTS"/ && echo "screenshots kept in $CI_TEST_KEEP_SHOTS"
fi
echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
