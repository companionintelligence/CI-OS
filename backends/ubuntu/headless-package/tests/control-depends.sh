#!/usr/bin/env bash
#=============================================================================
# Test: the setup-device package depends on names that exist in the Ubuntu 26.04 archive, and build.sh installs the same set
#
# DEBIAN/control Depends is what `apt-get install setup-device.deb` pulls in on the image (customize-chroot.sh Step 10d), and
# BUILD_DEPS in build.sh is what a local build installs so that `dpkg -i` of the result is configured. A name that is not in
# the archive makes the image build fail at Step 10d, an hour into a build, so this checks:
#
#   1. (anywhere) the two lists agree: every dependency of the package except python3 (always present) is in BUILD_DEPS;
#   2. (in an Ubuntu 26.04 container with apt lists, CI_TEST_ARCHIVE=1, or when apt-cache already knows resolute) every
#      name has an installation candidate for amd64 in the resolute archive.
#
# The names checked on 2026-10-17: hostapd 2.11, dnsmasq 2.92, nginx-light 1.28, python3 3.14, python3-flask 3.1,
# gunicorn 25.1 (gunicorn provides /usr/bin/gunicorn, which setup-backend.service starts), network-manager 1.54,
# iw 6.17, iproute2 6.19, rfkill 2.41.
#
#   backends/ubuntu/headless-package/tests/control-depends.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$HERE/.."
CONTROL="$PKG/DEBIAN/control"
BUILD="$PKG/build.sh"
[[ -f "$CONTROL" && -f "$BUILD" ]] || { echo "missing $CONTROL or $BUILD" >&2; exit 2; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

DEPENDS="$(sed -n 's/^Depends:[[:space:]]*//p' "$CONTROL" | head -n 1)"
[[ -n "$DEPENDS" ]] || { fail "no Depends: line in $CONTROL"; exit 1; }
# names only: drop version constraints and alternatives' alternatives
NAMES=()
while IFS= read -r n; do NAMES+=("$n"); done < <(printf '%s\n' "$DEPENDS" | tr ',' '\n' | sed -E 's/\(.*\)//; s/\|.*//; s/[[:space:]]//g' | grep .)
BUILD_DEPS="$(sed -n 's/^BUILD_DEPS=(\(.*\))$/\1/p' "$BUILD" | head -n 1)"

echo "== the lists agree (Depends: ${NAMES[*]})"
[[ -n "$BUILD_DEPS" ]] && pass "build.sh has a BUILD_DEPS list" || fail "build.sh has no BUILD_DEPS=(...) line"
for n in "${NAMES[@]}"; do
    [[ "$n" == python3 ]] && continue
    if printf ' %s ' "$BUILD_DEPS" | grep -q " $n "; then pass "$n is in BUILD_DEPS"; else fail "$n is a Depends of the package but not in BUILD_DEPS of build.sh (a local dpkg -i would be left unconfigured)"; fi
done
for n in $BUILD_DEPS; do
    if printf '%s\n' "${NAMES[@]}" | grep -qx "$n"; then :; else fail "$n is in BUILD_DEPS but is not a Depends of the package"; fi
done

echo
echo "== the names in the Ubuntu 26.04 archive"
have_archive=0
if command -v apt-cache >/dev/null 2>&1 && grep -q '^VERSION_CODENAME=resolute' /etc/os-release 2>/dev/null; then
    if apt-cache policy hostapd 2>/dev/null | grep -q 'Candidate: [0-9]'; then have_archive=1
    elif [[ "${CI_TEST_ARCHIVE:-0}" == 1 && "$(id -u)" -eq 0 ]] && apt-get update -qq >/dev/null 2>&1; then have_archive=1; fi
fi
if [[ $have_archive -eq 1 ]]; then
    for n in "${NAMES[@]}"; do
        cand="$(apt-cache -o APT::Architecture=amd64 policy "$n" 2>/dev/null | sed -n 's/^  Candidate: //p')"
        if [[ -n "$cand" && "$cand" != "(none)" ]]; then pass "$n has a candidate in the resolute archive ($cand)"; else fail "$n has no installation candidate for amd64 in the resolute archive"; fi
    done
    if apt-cache -o APT::Architecture=amd64 show gunicorn 2>/dev/null | grep -q '^Package: gunicorn'; then pass "gunicorn is a real package (it ships /usr/bin/gunicorn, the unit's ExecStart)"; else fail "gunicorn is not a package"; fi
else
    echo "SKIP  archive check (run in an Ubuntu 26.04 container with apt lists, or with CI_TEST_ARCHIVE=1 and network, as root)"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
