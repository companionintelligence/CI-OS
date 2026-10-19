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
# It needs BOTH tools, the rule build-iso.sh applies: rsvg-convert draws the marks and ImageMagick composes the
# GRUB background (Step 4) and scales the Plymouth watermark (Step 5); with only one of them those steps used to
# warn and ship a degraded image.
#
# This test points it at an empty directory on a host with no renderer, and with only one of the two (a stub on
# PATH; the preflight only asks `command -v`), and checks that it fails, says what is missing, and leaves the
# directory empty (the old script already staged files into it at Step 1).
#
# Run it where there is NO rsvg-convert and no ImageMagick, e.g. the stock ubuntu image, with the repo
# mounted read-only (it needs no root and writes only to a temp directory):
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:26.04 bash /repo/backends/ubuntu/chroot/tests/render-preflight.sh
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

run_script() { # run_script <name> [extra PATH dir]: sets OUT and RC for a fresh empty chroot directory
    CHROOT="$WORK/chroot-$1"
    mkdir -p "$CHROOT"
    set +e
    OUT="$(PATH="${2:+$2:}$PATH" bash "$SCRIPT" "$CHROOT" 1.0 2>&1)"; RC=$?
    set -e
}
stub_dir() { # stub_dir <dir> <tool>...: executables that do nothing, so `command -v` finds them
    local d="$1"; shift
    mkdir -p "$d"
    for t in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$d/$t"; chmod 755 "$d/$t"; done
}

run_script none
expect "no renderer: customize-chroot.sh fails" test "$RC" -ne 0
expect "no renderer: it names both missing tools" \
    bash -c "printf '%s\n' \"\$1\" | grep -q 'rsvg-convert' && printf '%s\n' \"\$1\" | grep -q 'magick or convert'" _ "$OUT"
expect "no renderer: it did not get as far as Step 1" bash -c "! printf '%s\n' \"\$1\" | grep -q 'Step 1'" _ "$OUT"
expect "no renderer: the chroot directory is untouched" bash -c "[[ -z \"\$(ls -A '$CHROOT')\" ]]"

stub_dir "$WORK/only-rsvg" rsvg-convert
run_script rsvg "$WORK/only-rsvg"
expect "rsvg-convert alone: customize-chroot.sh fails (ImageMagick composes the GRUB background and scales the watermark)" test "$RC" -ne 0
expect "rsvg-convert alone: it names ImageMagick and not rsvg-convert" \
    bash -c "printf '%s\n' \"\$1\" | grep -q 'Missing on this host: magick or convert' && ! printf '%s\n' \"\$1\" | grep -q 'Missing on this host:.*rsvg-convert'" _ "$OUT"
expect "rsvg-convert alone: it did not get as far as Step 1" bash -c "! printf '%s\n' \"\$1\" | grep -q 'Step 1'" _ "$OUT"
expect "rsvg-convert alone: the chroot directory is untouched" bash -c "[[ -z \"\$(ls -A '$CHROOT')\" ]]"

stub_dir "$WORK/only-magick" magick
run_script magick "$WORK/only-magick"
expect "ImageMagick alone: customize-chroot.sh fails" test "$RC" -ne 0
expect "ImageMagick alone: it names rsvg-convert and not ImageMagick" \
    bash -c "printf '%s\n' \"\$1\" | grep -q 'Missing on this host: rsvg-convert' && ! printf '%s\n' \"\$1\" | grep -q 'magick or convert (imagemagick)'" _ "$OUT"
expect "ImageMagick alone: it did not get as far as Step 1" bash -c "! printf '%s\n' \"\$1\" | grep -q 'Step 1'" _ "$OUT"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
