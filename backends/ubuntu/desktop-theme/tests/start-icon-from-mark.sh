#!/usr/bin/env bash
#=============================================================================
# Test: the dock start icon is generated from the vendored mark, not kept as a second copy
#
# 40-start-icon.sh used to install core/render/inputs/LogoMark_Color_StartIcon-cropped.svg, a hand-cropped
# copy of the mark that neither check-brand-mirrors.sh nor vendor-brand.sh covered, so it would have stayed on
# the old artwork after the next re-vendoring while the About logo, the greeter logo and ci-os-logo moved on.
# It now builds the icon from vendor/brand/logos/mark-mono.svg. This test stages a fake Yaru theme and runs the
# real step, as an image build, and checks that
#
#   - every path of the vendored colour mark (vendor/brand/logos/mark.svg) is in the installed icon, with the
#     one-colour fill currentColor and none of the logo-ramp colours of the artwork, and the viewBox is cropped;
#   - the stock Yaru file is diverted when a package owns it, and a second run (a rebuild without --clean)
#     still succeeds;
#   - the icon FOLLOWS the vendored mark: a repo copy whose mark-mono.svg has different path data gives an icon
#     with that path data.
#
# It changes /usr/share of the machine it runs on, so run it in a throw-away container, with the repo mounted
# read-only:
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:24.04 bash /repo/backends/ubuntu/desktop-theme/tests/start-icon-from-mark.sh
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
    echo "refusing to change this machine's icons: run it in a throw-away container (or set CI_TEST_ALLOW_HOST=1)" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" /usr/share/icons/Yaru' EXIT

# A fake Yaru theme whose start-here-symbolic.svg a package owns, like the real one (yaru-theme-icon).
YARU=/usr/share/icons/Yaru/scalable/places
mkdir -p "$WORK/pkg/DEBIAN" "$WORK/pkg$YARU"
printf 'Package: ci-fake-yaru\nVersion: 1\nArchitecture: all\nMaintainer: test <test@example.invalid>\nDescription: test\n' > "$WORK/pkg/DEBIAN/control"
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg>\n' > "$WORK/pkg$YARU/start-here-symbolic.svg"
dpkg-deb --root-owner-group --build "$WORK/pkg" "$WORK/pkg.deb" >/dev/null
dpkg -i "$WORK/pkg.deb" >/dev/null
ICON="$YARU/start-here-symbolic.svg"

OUT=""; RC=0
run_step() { # run_step <repo> [rerun]
    set +e
    OUT="$(CI_BRAND_IMAGE_BUILD=1 bash "$1/backends/ubuntu/desktop-theme/40-start-icon.sh" 2>&1)"; RC=$?
    set -e
}
has_all_paths() { # every d="..." of mark.svg is in the icon
    local n=0 d
    while IFS= read -r d; do
        n=$((n + 1))
        grep -qF -- "$d" "$ICON" || return 1
    done < <(grep -o ' d="[^"]*"' "$REPO/vendor/brand/logos/mark.svg")
    [[ "$n" -ge 1 ]]
}
no_ramp_colours() { # none of the artwork's fill colours ship in the symbolic icon
    local hex
    while IFS= read -r hex; do
        if grep -qi -- "$hex" "$ICON"; then return 1; fi
    done < <(grep -o 'fill:#[0-9a-fA-F]\{6\}' "$REPO/vendor/brand/logos/mark.svg" | sed 's/fill://')
    return 0
}

# ── the real repo ───────────────────────────────────────────────────────────
run_step "$REPO"
expect "step exits 0" test "$RC" -eq 0
expect "icon carries every path of the vendored mark" has_all_paths
expect "icon fills with currentColor" grep -q 'fill:currentColor' "$ICON"
expect "icon ships none of the artwork's logo-ramp colours" no_ramp_colours
expect "icon is no longer Ubuntu's (viewBox 0 0 16 16)" bash -c "! grep -q 'viewBox=\"0 0 16 16\"' '$ICON'"
expect "icon viewBox is cropped, not the whole mark" bash -c "grep -q 'viewBox=\"34.60548 ' '$ICON'"
expect "stock file diverted to .ubuntu-stock" bash -c "[[ -n \"\$(dpkg-divert --list '$ICON')\" ]] && grep -q 'viewBox=\"0 0 16 16\"' '$ICON.ubuntu-stock'"
expect "an image build leaves no backup directory" bash -c "! ls -d /usr/share/icons/ubuntu-backup-* >/dev/null 2>&1"

run_step "$REPO"
expect "second run (rebuild) exits 0" test "$RC" -eq 0

# ── the icon follows the vendored mark ──────────────────────────────────────
mkdir -p "$WORK/repo/backends/ubuntu" "$WORK/repo/core"
cp -a "$REPO/backends/ubuntu/desktop-theme" "$WORK/repo/backends/ubuntu/"
cp -a "$REPO/core/lib" "$WORK/repo/core/"
cp -a "$REPO/vendor" "$WORK/repo/"
sed -i 's/M51\.451,125\.652/M1.5,2.5/' "$WORK/repo/vendor/brand/logos/mark-mono.svg"
run_step "$WORK/repo"
expect "step with a different vendored mark exits 0" test "$RC" -eq 0
expect "icon follows the vendored mark (new path data is in it)" grep -q 'M1\.5,2\.5' "$ICON"
expect "icon no longer has the old path data" bash -c "! grep -q 'M51\\.451,125\\.652' '$ICON'"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
