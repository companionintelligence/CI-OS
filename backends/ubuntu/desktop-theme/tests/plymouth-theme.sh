#!/usr/bin/env bash
#=============================================================================
# Test: 10-plymouth.sh paints the rootfs Plymouth themes from the canon and replaces the firmware-logo fallback
#
# The Plymouth step used to set colours with four inline seds per file and left Ubuntu's bgrt-fallback.png (the logo
# in a circle of friends, shown by the bgrt theme where the firmware has no boot logo: legacy BIOS, most VMs) in
# place. It now calls ci_plymouth_recolor / ci_plymouth_text_theme (core/lib/theme-lib.sh, the same helpers
# build-iso.sh uses for the copies inside the casper initrd) and installs the colour mark over the fallback with
# ci_install_file. This test runs the real step, as an image build, against the stock theme files of the Ubuntu
# packages and checks that
#
#   colours     bgrt.plymouth and spinner.plymouth carry the canon dark background, progress track and fill
#               (derived from vendor/brand/tokens, never typed here), and only those four lines differ from the
#               stock files, plus bgrt's UseFirmwareBackground, which stock sets true in boot-up, shutdown and reboot
#               and which makes the two-step plugin paint black instead of the ground (ci_plymouth_recolor says why);
#               the rootfs bgrt keeps the Cantarell font swap; and the colours FOLLOW the tokens;
#   text        ubuntu-text.plymouth is the Companion OS theme, titled with the build's CI_OS_VERSION;
#   fallback    bgrt-fallback.png is the staged colour mark, 128x128, not Ubuntu's; the stock file is dpkg-diverted
#               to .ubuntu-stock (when a package owns it) with its bytes intact; a second run (a rebuild without
#               --clean) still succeeds; an image build with nothing staged fails instead of shipping Ubuntu's logo;
#   diverted    the same for every other package-owned file the step rewrites: watermark.png, bgrt.plymouth,
#               spinner.plymouth and the text theme's template ubuntu-text.plymouth.in, so the branding survives what
#               an upgrade of the Plymouth packages does: the lsb-release trigger that regenerates the text theme
#               from its template, and (best effort, needs the network) a reinstall of the three packages;
#   backups     an image build leaves no ci-branding-backup-* directory;
#   live        a live system renders the fallback itself and keeps a backup; with no renderer it warns, keeps
#               Ubuntu's file and still exits 0, so the steps after it in apply-ci-os-desktop.sh run.
#
# It changes /usr/share/plymouth of the machine it runs on, so run it in a throw-away container with the Plymouth
# themes, a renderer and the repo mounted read-only:
#
#   docker run --rm --platform linux/amd64 -v "$PWD:/repo:ro" ubuntu:26.04 bash -c \
#     'apt-get update -qq && apt-get install -y -qq plymouth-theme-spinner plymouth-theme-ubuntu-text imagemagick librsvg2-bin \
#      && bash /repo/backends/ubuntu/desktop-theme/tests/plymouth-theme.sh'
#
# (CI_TEST_ALLOW_HOST=1 overrides the container check on a disposable VM.) Exit status is non-zero if any check
# fails; 2 if it cannot run here.
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
for t in dpkg dpkg-divert rsvg-convert convert od sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t (apt-get install plymouth-theme-spinner plymouth-theme-ubuntu-text imagemagick librsvg2-bin)" >&2; exit 2; }
done
THEMES=/usr/share/plymouth/themes
for f in spinner/spinner.plymouth spinner/watermark.png bgrt/bgrt.plymouth ubuntu-text/ubuntu-text.plymouth ubuntu-text/ubuntu-text.plymouth.in; do
    [[ -f "$THEMES/$f" ]] || { echo "missing $THEMES/$f (apt-get install plymouth-theme-spinner plymouth-theme-ubuntu-text)" >&2; exit 2; }
done

# shellcheck source=../../../../vendor/brand/tokens/tokens.sh
source "$REPO/vendor/brand/tokens/tokens.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

png_dim() { # png_dim <png>: "<width>x<height>"
    local w h
    w="$(od -An -tu1 -j16 -N4 "$1" | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}')"
    h="$(od -An -tu1 -j20 -N4 "$1" | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}')"
    echo "${w}x${h}"
}
sha() { sha256sum "$1" | cut -d' ' -f1; }

# A writable copy of the repo pieces the step sources, so a staged PNG and a changed token can be tried.
make_repo() { # make_repo <dir>
    mkdir -p "$1/backends/ubuntu" "$1/core"
    cp -a "$REPO/backends/ubuntu/desktop-theme" "$1/backends/ubuntu/"
    cp -a "$REPO/backends/ubuntu/lib" "$1/backends/ubuntu/"
    cp -a "$REPO/core/lib" "$REPO/core/render" "$1/core/"
    cp -a "$REPO/vendor" "$1/"
    rm -rf "$1/core/render/output"
}
stage_png() { # stage_png <repo>: what customize-chroot.sh does on the build host
    mkdir -p "$1/core/render/output"
    bash "$1/core/render/render-mark-png.sh" "$1/core/render/output/ci-os-bgrt-fallback.png" 128 >/dev/null
}
OUT=""; RC=0
run_step() { # run_step <repo> [env...]: combined output and status without tripping set -e
    local repo="$1"; shift
    set +e
    OUT="$(env "$@" bash "$repo/backends/ubuntu/desktop-theme/10-plymouth.sh" 2>&1)"; RC=$?
    set -e
}
changed_keys() { # changed_keys <old> <new>: the keys of the lines that differ, sorted
    diff <(sort "$1") <(sort "$2") | sed -n 's/^[<>] \([A-Za-z]*\)=.*/\1/p' | sort -u | paste -sd' ' -
}

FALLBACK="$THEMES/spinner/bgrt-fallback.png"
if [[ -n "$(dpkg-divert --list "$FALLBACK" 2>/dev/null)" ]]; then
    echo "this machine is already re-skinned ($FALLBACK is diverted), so there are no stock files to compare with: use a fresh container" >&2
    exit 2
fi
STOCK="$WORK/stock"; mkdir -p "$STOCK"
cp "$THEMES/bgrt/bgrt.plymouth" "$STOCK/bgrt.plymouth"
cp "$THEMES/spinner/spinner.plymouth" "$STOCK/spinner.plymouth"
cp "$THEMES/ubuntu-text/ubuntu-text.plymouth" "$STOCK/ubuntu-text.plymouth"
cp "$THEMES/ubuntu-text/ubuntu-text.plymouth.in" "$STOCK/ubuntu-text.plymouth.in"
cp "$THEMES/spinner/watermark.png" "$STOCK/watermark.png"
if [[ -f "$FALLBACK" ]]; then
    cp "$FALLBACK" "$STOCK/bgrt-fallback.png"; STOCK_FB_SHA="$(sha "$FALLBACK")"
else
    echo "this Plymouth theme package ships no $FALLBACK: nothing for the step to replace" >&2; exit 2
fi
OWNED=0; if dpkg -S "$FALLBACK" >/dev/null 2>&1; then OWNED=1; fi
expect "precondition: a package owns the stock bgrt-fallback.png (so the diversion is testable)" test "$OWNED" -eq 1

want_ground="$(ci_hex0x "$CI_DARK_BACKGROUND")"
want_track="$(ci_hex0x "$CI_DARK_SECONDARY")"
want_fill="$(ci_hex0x "$CI_DARK_PRIMARY")"

# ── an image build with no staged fallback fails and leaves Ubuntu's logo alone ─────────────────────────────
make_repo "$WORK/bare"
run_step "$WORK/bare" CI_BRAND_IMAGE_BUILD=1 CI_OS_VERSION=7.3
expect "image build with nothing staged exits non-zero (it must not ship Ubuntu's fallback logo)" test "$RC" -ne 0
expect "...and says why" bash -c "grep -q 'No pre-rendered firmware-logo fallback' <<<\"\$1\"" _ "$OUT"
expect "...and Ubuntu's bgrt-fallback.png is untouched" test "$(sha "$FALLBACK")" = "$STOCK_FB_SHA"

# ── the real repo, an image build, the fallback staged by the build host ─────────────────────────────────────
make_repo "$WORK/repo"; stage_png "$WORK/repo"
run_step "$WORK/repo" CI_BRAND_IMAGE_BUILD=1 CI_OS_VERSION=7.3
expect "image build exits 0" test "$RC" -eq 0
for theme in bgrt spinner; do
    conf="$THEMES/$theme/$theme.plymouth"
    expect "$theme.plymouth: ground is the canon dark background ($want_ground)" \
        bash -c "grep -q -x 'BackgroundStartColor=$want_ground' '$conf' && grep -q -x 'BackgroundEndColor=$want_ground' '$conf'"
    expect "$theme.plymouth: progress bar is the canon primary ($want_fill) on the canon secondary ($want_track)" \
        bash -c "grep -q -x 'ProgressBarForegroundColor=$want_fill' '$conf' && grep -q -x 'ProgressBarBackgroundColor=$want_track' '$conf'"
    colour_keys="BackgroundEndColor BackgroundStartColor ProgressBarBackgroundColor ProgressBarForegroundColor"
    if [[ "$theme" == bgrt ]]; then allowed="BackgroundEndColor BackgroundStartColor Font ProgressBarBackgroundColor ProgressBarForegroundColor TitleFont UseFirmwareBackground"; else allowed="$colour_keys"; fi
    expect "$theme.plymouth: only the colour lines differ from Ubuntu's file (and the rootfs font swap and the firmware background for bgrt)" \
        test "$(changed_keys "$STOCK/$theme.plymouth" "$conf")" = "$allowed"
    expect "$theme.plymouth: no section asks for the firmware background any more (the plugin would paint black behind it)" \
        bash -c "! grep -q -E '^[[:space:]]*UseFirmwareBackground[[:space:]]*=[[:space:]]*(1|y|yes|true)' '$conf'"
done
expect "precondition: Ubuntu's bgrt asks for the firmware background in boot-up, shutdown and reboot" \
    test "$(grep -c '^UseFirmwareBackground=true' "$STOCK/bgrt.plymouth")" -eq 3
expect "bgrt.plymouth switches it off in boot-up, shutdown and reboot (three lines, all false)" \
    test "$(grep -c '^UseFirmwareBackground=false' "$THEMES/bgrt/bgrt.plymouth")" -eq 3
expect "bgrt.plymouth on the rootfs asks for Cantarell (the initrd copy keeps Ubuntu's font)" \
    bash -c "grep -q -x 'Font=Cantarell 12' '$THEMES/bgrt/bgrt.plymouth' && grep -q -x 'TitleFont=Cantarell Light 30' '$THEMES/bgrt/bgrt.plymouth'"
TEXT="$THEMES/ubuntu-text/ubuntu-text.plymouth"
expect "text splash is titled Companion OS <CI_OS_VERSION>" grep -q -x 'title=Companion OS 7.3' "$TEXT"
expect "text splash is the Companion OS Text theme on the ubuntu-text module" \
    bash -c "grep -q -x 'Name=Companion OS Text' '$TEXT' && grep -q -x 'ModuleName=ubuntu-text' '$TEXT'"
expect "text splash colours come from the canon (black=$want_ground the ground, white=$(ci_hex0x "$CI_DARK_FOREGROUND") brown=$want_fill blue=$(ci_hex0x "$CI_LIGHT_PRIMARY"))" \
    bash -c "grep -q -x 'white=$(ci_hex0x "$CI_DARK_FOREGROUND")' '$TEXT' && grep -q -x 'brown=$want_fill' '$TEXT' && grep -q -x 'blue=$(ci_hex0x "$CI_LIGHT_PRIMARY")' '$TEXT' && grep -q -x 'black=$want_ground' '$TEXT'"
expect "text splash has no aubergine left" bash -c "! grep -qi '0x2c001e' '$TEXT'"

expect "bgrt-fallback.png is the staged colour mark (same bytes)" cmp -s "$FALLBACK" "$WORK/repo/core/render/output/ci-os-bgrt-fallback.png"
expect "bgrt-fallback.png is 128x128, the size of Ubuntu's" test "$(png_dim "$FALLBACK")" = 128x128
expect "bgrt-fallback.png is no longer Ubuntu's" test "$(sha "$FALLBACK")" != "$STOCK_FB_SHA"
expect "Ubuntu's file is dpkg-diverted to .ubuntu-stock" bash -c "[[ -n \"\$(dpkg-divert --list '$FALLBACK')\" ]]"
expect "...and its bytes are intact there" test "$(sha "$FALLBACK.ubuntu-stock")" = "$STOCK_FB_SHA"
# Everything the step rewrites that a package owns is diverted, so Ubuntu's version is kept (as .ubuntu-stock) and an
# upgrade of the package unpacks to that name instead of over ours.
DIVERTED="spinner/watermark.png:watermark.png bgrt/bgrt.plymouth:bgrt.plymouth spinner/spinner.plymouth:spinner.plymouth ubuntu-text/ubuntu-text.plymouth.in:ubuntu-text.plymouth.in"
for pair in $DIVERTED; do
    f="$THEMES/${pair%%:*}"; stock="$STOCK/${pair##*:}"
    expect "${pair%%:*} is dpkg-diverted to .ubuntu-stock" bash -c "[[ -n \"\$(dpkg-divert --list '$f')\" ]]"
    expect "...and Ubuntu's bytes are intact there" test "$(sha "$f.ubuntu-stock")" = "$(sha "$stock")"
    expect "...and ours differs from Ubuntu's" test "$(sha "$f")" != "$(sha "$stock")"
done
expect "the text theme template is the Companion OS theme too (the package's postinst generates the text theme from it)" \
    bash -c "grep -q -x 'title=Companion OS 7.3' '$TEXT.in' && grep -q -x 'Name=Companion OS Text' '$TEXT.in' && ! grep -qi '0x2c001e' '$TEXT.in'"
expect "an image build leaves no backup directory" bash -c "! ls -d /usr/share/plymouth/ci-branding-backup-* >/dev/null 2>&1"
expect "the other theme images are untouched (animation frames are Ubuntu's)" bash -c "ls '$THEMES'/spinner/animation-*.png >/dev/null 2>&1"

# ── what an upgrade of the Plymouth packages does to the branding ───────────────────────────────────────────
# plymouth-theme-ubuntu-text regenerates ubuntu-text.plymouth from its template on every configure and whenever
# /etc/lsb-release changes (a base-files upgrade): the title must stay ours.
branded_sums() { for pair in $DIVERTED; do sha "$THEMES/${pair%%:*}"; done; sha "$FALLBACK"; sha "$TEXT"; }
BRANDED_BEFORE="$(branded_sums)"
set +e
dpkg-trigger --no-await /etc/lsb-release >/dev/null 2>&1
dpkg --configure --pending >/dev/null 2>&1
set -e
expect "after the lsb-release trigger the text theme is still titled Companion OS 7.3 (regenerated from our template)" \
    grep -q -x 'title=Companion OS 7.3' "$TEXT"
expect "...and has no aubergine and no Ubuntu title" bash -c "! grep -qi '0x2c001e' '$TEXT' && ! grep -q 'title=Ubuntu' '$TEXT'"
# A reinstall unpacks the same files an upgrade would. Best effort: it needs the network.
set +e
apt-get install --reinstall -y -qq plymouth plymouth-theme-spinner plymouth-theme-ubuntu-text >"$WORK/reinstall.log" 2>&1
REINSTALL_RC=$?
set -e
if [[ "$REINSTALL_RC" -eq 0 ]]; then
    expect "a reinstall of the Plymouth packages leaves every branded file as it was (watermark, themes, fallback, text theme)" \
        test "$(branded_sums)" = "$BRANDED_BEFORE"
    expect "...and puts Ubuntu's unpacked files at the .ubuntu-stock names" \
        test "$(sha "$THEMES/spinner/watermark.png.ubuntu-stock")" = "$(sha "$STOCK/watermark.png")"
else
    printf 'info  reinstall skipped (apt-get install --reinstall failed, offline?): the upgrade check above is the lsb-release trigger only\n'
fi

run_step "$WORK/repo" CI_BRAND_IMAGE_BUILD=1 CI_OS_VERSION=7.3
expect "second run (a rebuild without --clean) exits 0" test "$RC" -eq 0
expect "...and the fallback is still the staged mark" cmp -s "$FALLBACK" "$WORK/repo/core/render/output/ci-os-bgrt-fallback.png"
expect "...and the stock file is still the one at .ubuntu-stock" test "$(sha "$FALLBACK.ubuntu-stock")" = "$STOCK_FB_SHA"
for pair in $DIVERTED; do
    expect "...and Ubuntu's ${pair%%:*} is still the file at .ubuntu-stock" \
        test "$(sha "$THEMES/${pair%%:*}.ubuntu-stock")" = "$(sha "$STOCK/${pair##*:}")"
done

# ── the colours follow the vendored tokens ──────────────────────────────────────────────────────────────────
make_repo "$WORK/tok"; stage_png "$WORK/tok"
sed -i 's/^CI_DARK_BACKGROUND=.*/CI_DARK_BACKGROUND="#123456"/' "$WORK/tok/vendor/brand/tokens/tokens.sh"
run_step "$WORK/tok" CI_BRAND_IMAGE_BUILD=1 CI_OS_VERSION=7.3
expect "step with a different CI_DARK_BACKGROUND exits 0" test "$RC" -eq 0
expect "bgrt.plymouth and spinner.plymouth follow the token (ground 0x123456)" \
    bash -c "grep -q -x 'BackgroundStartColor=0x123456' '$THEMES/bgrt/bgrt.plymouth' && grep -q -x 'BackgroundStartColor=0x123456' '$THEMES/spinner/spinner.plymouth'"
expect "...and so does the text splash ground (black=0x123456)" grep -q -x 'black=0x123456' "$TEXT"

# ── a live system (no CI_BRAND_IMAGE_BUILD): renders the fallback itself, keeps a backup ────────────────────
run_step "$REPO" CI_OS_VERSION=7.3
# $REPO is read-only; the step only reads it, and renders into a temp directory
expect "live run with a renderer exits 0" test "$RC" -eq 0
expect "live run rendered a 128x128 colour mark over the fallback" test "$(png_dim "$FALLBACK")" = 128x128
expect "live run keeps a backup of the files it changed, fallback included" \
    bash -c "ls /usr/share/plymouth/ci-branding-backup-*/bgrt-fallback.png.bak >/dev/null 2>&1"

# ── a live system with no renderer: the fallback is skipped, the step still succeeds ────────────────────────
# Restore Ubuntu's file first, as a system that never had the step run would have it.
install -m 644 "$STOCK/bgrt-fallback.png" "$FALLBACK"
NOREND="$WORK/norender-bin"; mkdir -p "$NOREND"
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
        [[ -e "$f" || -L "$f" ]] || continue
        case "${f##*/}" in rsvg-convert|magick|convert|convert-im6*|magick-im6*) continue ;; esac
        [[ -e "$NOREND/${f##*/}" ]] || ln -s "$f" "$NOREND/${f##*/}"
    done
done
set +e
OUT="$(env -i PATH="$NOREND" CI_OS_VERSION=7.3 bash "$REPO/backends/ubuntu/desktop-theme/10-plymouth.sh" 2>&1)"; RC=$?
set -e
expect "live run with no renderer exits 0 (apply-ci-os-desktop.sh goes on to the next step)" test "$RC" -eq 0
expect "...warns that the fallback cannot be drawn" bash -c "grep -q 'cannot be drawn' <<<\"\$1\"" _ "$OUT"
expect "...and warns that the watermark is copied at full size (nothing on a live system scaled it)" \
    bash -c "grep -q 'copying logo at full size' <<<\"\$1\"" _ "$OUT"
expect "...and leaves Ubuntu's fallback logo as it was" test "$(sha "$FALLBACK")" = "$STOCK_FB_SHA"

# ── an image build in a chroot with no ImageMagick (the stock desktop image): the host scaled the logo ─────
# customize-chroot.sh scales Logo_Banner_Color.png on the build host and lays it over the step's inputs, so the step
# copies it as it is and must not say it is copying the logo at full size.
set +e
OUT="$(env -i PATH="$NOREND" CI_BRAND_IMAGE_BUILD=1 CI_OS_VERSION=7.3 bash "$WORK/repo/backends/ubuntu/desktop-theme/10-plymouth.sh" 2>&1)"; RC=$?
set -e
expect "image build with no ImageMagick exits 0 (the host pre-scaled the logo)" test "$RC" -eq 0
expect "...and does not warn about a full-size logo" bash -c "! grep -q 'copying logo at full size' <<<\"\$1\"" _ "$OUT"
expect "...and installs the input logo as it is" cmp -s "$THEMES/spinner/watermark.png" "$WORK/repo/core/render/inputs/Logo_Banner_Color.png"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
