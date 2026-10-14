#!/usr/bin/env bash
#=============================================================================
# Test: the About logo step degrades, it does not abort the re-skin, when nothing can draw the PNGs
#
# A stock Ubuntu desktop has neither rsvg-convert nor ImageMagick. 45-about-logo.sh renders the
# Settings > About PNGs itself on a live system, and apply-ci-os-desktop.sh runs under set -e, so a
# render failure used to stop the whole apply at step 8 of 10: os-release and motd stayed unbranded
# and the exit status was 1. Now, with no renderer:
#
#   live        the step warns, skips only the PNG replacement, still installs the ci-os-logo icon
#               and exits 0, so the steps after it run;
#   image       an image build (CI_BRAND_IMAGE_BUILD=1) without the staged PNGs still fails: it must
#               never ship Ubuntu's wordmark, and it leaves /usr/share/pixmaps alone.
#
# It changes /etc and /usr of the machine it runs on, so run it in a throw-away container that has
# no renderer (the stock ubuntu image), with the repo mounted read-only:
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:24.04 bash /repo/backends/ubuntu/desktop-theme/tests/about-logo-no-renderer.sh
#
# (CI_TEST_ALLOW_HOST=1 overrides the container check on a disposable VM.) Exit status is non-zero if
# any check fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME="$HERE/.."

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
for t in rsvg-convert magick convert; do
    if command -v "$t" >/dev/null 2>&1; then echo "this test needs a system WITHOUT a renderer, but $t is installed" >&2; exit 2; fi
done

OUT=""; RC=0
run() { # run <command...>: capture combined output and status without tripping set -e
    set +e
    OUT="$("$@" 2>&1)"; RC=$?
    set -e
}
out_has() { printf '%s\n' "$OUT" | grep -q -- "$1"; }

# ── live system, no renderer ────────────────────────────────────────────────
run bash "$THEME/apply-ci-os-desktop.sh" --only about-logo,os-release,motd
expect "live: apply-ci-os-desktop.sh exits 0" test "$RC" -eq 0
expect "live: the step warned that the About logo cannot be drawn" out_has 'cannot be drawn'
expect "live: the ci-os-logo icon was installed" test -s /usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg
expect "live: the os-release step after it ran" out_has '=== os-release ==='
expect "live: the motd step after it ran" out_has '=== motd ==='
expect "live: os-release is branded" grep -q '^NAME="Companion OS"$' /etc/os-release
expect "live: the About pixmaps were left alone (not diverted)" bash -c "[[ ! -e /usr/share/pixmaps/ubuntu-logo-text.png.ubuntu-stock ]]"

# The step on its own: the same.
run bash "$THEME/45-about-logo.sh"
expect "live: 45-about-logo.sh on its own exits 0" test "$RC" -eq 0

# ── image build, nothing staged ─────────────────────────────────────────────
run env CI_BRAND_IMAGE_BUILD=1 bash "$THEME/45-about-logo.sh"
expect "image: without the staged PNGs the step fails" test "$RC" -ne 0
expect "image: it says why" out_has 'No pre-rendered About logo'
expect "image: it left the About pixmaps alone" bash -c "[[ ! -e /usr/share/pixmaps/ubuntu-logo-text.png.ubuntu-stock ]]"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
