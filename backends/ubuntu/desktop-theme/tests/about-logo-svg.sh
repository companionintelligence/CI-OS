#!/usr/bin/env bash
#=============================================================================
# Test: 45-about-logo.sh replaces the SVG pair GNOME 50 reads, as well as the PNG pair, and diverts all four stock files
#
# gnome-control-center 50.3 (Ubuntu 26.04.1) names /usr/share/pixmaps/ubuntu-logo-text.svg and ubuntu-logo-text-dark.svg for
# the logo at the top of Settings > About and has no .png name in it any more. The step used to replace only the PNG pair, so
# About kept Ubuntu's wordmark on 26.04 and nothing failed. base-files owns all four files (the ubuntu:26.04 container has
# them too, from the real base-files). This test runs the real step as an image build with PNGs staged and checks that
#
#   - the SVG pair is the vendored one-colour mark with currentColor set to the canon primary of each mode (light, dark);
#   - the PNG pair is what was staged;
#   - all four stock files are dpkg-diverted to *.ubuntu-stock with their stock bytes;
#   - a second run changes nothing;
#   - with network (apt-get update works), reinstalling base-files leaves ours in place and puts the stock files at
#     *.ubuntu-stock again (CI_TEST_NO_APT=1 skips this).
#
# It changes /usr/share/pixmaps and the dpkg diversion list of the machine it runs on, so run it in a throw-away container,
# with the repo mounted read-only (the test copies what it needs):
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:26.04 bash /repo/backends/ubuntu/desktop-theme/tests/about-logo-svg.sh
#
# (CI_TEST_ALLOW_HOST=1 overrides the container check on a disposable VM.) Exit status is non-zero if any check fails;
# 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then t_pass "$label"; else t_fail "$label"; fi; }

if [[ "$(id -u)" -ne 0 ]]; then echo "needs root: run it in a throw-away container" >&2; exit 2; fi
if [[ ! -e /.dockerenv && ! -e /run/.containerenv && "${CI_TEST_ALLOW_HOST:-0}" != 1 ]]; then
    echo "refusing to change this machine's pixmaps: run it in a throw-away container (or set CI_TEST_ALLOW_HOST=1)" >&2
    exit 2
fi
command -v dpkg-deb >/dev/null 2>&1 || { echo "dpkg-deb not found" >&2; exit 2; }

WORK="$(mktemp -d)"
PIX=/usr/share/pixmaps
FILES=("$PIX/ubuntu-logo-text.svg" "$PIX/ubuntu-logo-text-dark.svg" "$PIX/ubuntu-logo-text.png" "$PIX/ubuntu-logo-text-dark.png")

STOCK_SUMS="$WORK/stock.sums"
cleanup_machine() {
    local f
    for f in "${FILES[@]}"; do
        if [[ -e "$f.ubuntu-stock" ]]; then
            rm -f "$f"
            dpkg-divert --remove --rename "$f" >/dev/null 2>&1 || true
        fi
    done
}
trap 'cleanup_machine; rm -rf "$WORK"' EXIT

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "$f is not in this container (base-files should ship it)" >&2; exit 2; }
    dpkg -S "$f" >/dev/null 2>&1 || { echo "$f is not owned by a package here" >&2; exit 2; }
done
sha256sum "${FILES[@]}" > "$STOCK_SUMS"          # the stock bytes, as base-files ships them

# A copy of what the step needs, with PNGs staged where an image build looks for them (the repo itself is read-only).
R="$WORK/repo"
mkdir -p "$R/backends/ubuntu" "$R/core/render/output"
cp -a "$REPO/backends/ubuntu/desktop-theme" "$R/backends/ubuntu/"
cp -a "$REPO/core/lib" "$R/core/"
cp -a "$REPO/vendor" "$R/"
printf 'staged light png\n' > "$R/core/render/output/ci-os-about-logo.png"
printf 'staged dark png\n' > "$R/core/render/output/ci-os-about-logo-dark.png"
# shellcheck source=../../../../vendor/brand/tokens/tokens.sh
source "$R/vendor/brand/tokens/tokens.sh"
MONO="$R/vendor/brand/logos/mark-mono.svg"

hashes() { sha256sum "${FILES[@]}"; }

OUT="$(CI_BRAND_IMAGE_BUILD=1 bash "$R/backends/ubuntu/desktop-theme/45-about-logo.sh" 2>&1)" && RC=0 || RC=$?
expect "the step exits 0 as an image build with PNGs staged" test "$RC" -eq 0

expect "light SVG: the mark with the light canon primary" bash -c "[[ \"\$(sed 's/currentColor/$CI_LIGHT_PRIMARY/g' '$MONO')\" == \"\$(cat $PIX/ubuntu-logo-text.svg)\" ]]"
expect "dark SVG: the mark with the dark canon primary" bash -c "[[ \"\$(sed 's/currentColor/$CI_DARK_PRIMARY/g' '$MONO')\" == \"\$(cat $PIX/ubuntu-logo-text-dark.svg)\" ]]"
expect "the SVGs are well-formed SVG with the colour in the style" bash -c "grep -q '<svg' $PIX/ubuntu-logo-text.svg && grep -qi 'fill:$CI_LIGHT_PRIMARY' $PIX/ubuntu-logo-text.svg && grep -qi 'fill:$CI_DARK_PRIMARY' $PIX/ubuntu-logo-text-dark.svg"
expect "light PNG is the staged one" grep -q -x 'staged light png' "$PIX/ubuntu-logo-text.png"
expect "dark PNG is the staged one" grep -q -x 'staged dark png' "$PIX/ubuntu-logo-text-dark.png"
for f in "${FILES[@]}"; do
    stock_sum="$(grep " $f\$" "$STOCK_SUMS" | cut -d' ' -f1)"
    expect "$(basename "$f") is diverted and the stock bytes are at .ubuntu-stock" bash -c "[[ -n \"\$(dpkg-divert --list '$f')\" ]] && [[ \"\$(sha256sum '$f.ubuntu-stock' | cut -d' ' -f1)\" == '$stock_sum' ]]"
    expect "$(basename "$f") is no longer the stock file" bash -c "[[ \"\$(sha256sum '$f' | cut -d' ' -f1)\" != '$stock_sum' ]]"
done

H1="$(hashes)"; D1="$(dpkg-divert --list | sort)"
OUT="$(CI_BRAND_IMAGE_BUILD=1 bash "$R/backends/ubuntu/desktop-theme/45-about-logo.sh" 2>&1)" && RC=0 || RC=$?
expect "a second run exits 0" test "$RC" -eq 0
expect "a second run changes no file" test "$(hashes)" = "$H1"
expect "a second run diverts nothing more" test "$(dpkg-divert --list | sort)" = "$D1"

if [[ "${CI_TEST_NO_APT:-0}" != 1 ]] && command -v apt-get >/dev/null 2>&1 && apt-get update -qq >/dev/null 2>&1; then
    if apt-get install --reinstall -y -qq base-files >/dev/null 2>&1; then
        expect "after reinstalling base-files the SVGs are still ours" bash -c "[[ \"\$(cat $PIX/ubuntu-logo-text.svg)\" == \"\$(sed 's/currentColor/$CI_LIGHT_PRIMARY/g' '$MONO')\" ]]"
        expect "after reinstalling base-files the PNGs are still ours" grep -q -x 'staged light png' "$PIX/ubuntu-logo-text.png"
        for f in "${FILES[@]}"; do
            expect "after reinstalling base-files the stock $(basename "$f") is back at .ubuntu-stock" bash -c "[[ -f '$f.ubuntu-stock' ]]"
        done
    else
        echo "SKIP  reinstalling base-files failed in this container"
    fi
else
    echo "SKIP  reinstall of base-files (no network or CI_TEST_NO_APT=1)"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
