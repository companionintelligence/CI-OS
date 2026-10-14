#!/usr/bin/env bash
#=============================================================================
# Test: customize-chroot.sh refuses to start without a logo renderer, before it touches the chroot
#
# The greeter logo (Step 3) and the Settings > About logos (Step 5c) are PNGs rendered on the build host
# from the vendored SVG marks, with rsvg-convert or ImageMagick (core/render/render-mark-png.sh). build-iso.sh
# checks for the tools, but customize-chroot.sh can be run directly, and it used to render in the middle of
# the run: with no renderer it died at Step 3, after Step 1 had rewritten os-release and Step 2 had removed
# packages, leaving a half-customized chroot. It now renders everything first.
#
# This test points it at an empty directory on a host with no renderer and checks that it fails, says why,
# and leaves the directory empty (the old script already staged files into it at Step 1).
#
# Run it where there is NO rsvg-convert and no ImageMagick, e.g. the stock ubuntu image, with the repo
# mounted read-only (it needs no root and writes only to a temp directory):
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:24.04 bash /repo/backends/ubuntu/chroot/tests/render-preflight.sh
#
# Exit status is non-zero if any check fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../customize-chroot.sh"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { # expect "<label>" <command...>
    local label="$1"; shift
    if "$@"; then t_pass "$label"; else t_fail "$label"; fi
}

for t in rsvg-convert magick convert; do
    if command -v "$t" >/dev/null 2>&1; then echo "this test needs a host WITHOUT a renderer, but $t is installed" >&2; exit 2; fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CHROOT="$WORK/chroot"
mkdir -p "$CHROOT"

set +e
OUT="$(bash "$SCRIPT" "$CHROOT" 1.0 2>&1)"; RC=$?
set -e

expect "no renderer: customize-chroot.sh fails" test "$RC" -ne 0
expect "no renderer: it names the missing tools" bash -c "printf '%s\n' \"\$1\" | grep -q 'Neither rsvg-convert nor ImageMagick'" _ "$OUT"
expect "no renderer: it did not get as far as Step 1" bash -c "! printf '%s\n' \"\$1\" | grep -q 'Step 1'" _ "$OUT"
expect "no renderer: the chroot directory is untouched" bash -c "[[ -z \"\$(ls -A '$CHROOT')\" ]]"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
