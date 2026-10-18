#!/usr/bin/env bash
#=============================================================================
# Golden test for the shared identity writer, backends/ubuntu/lib/os-release.sh
#
# customize-chroot.sh used to write /etc/os-release and /etc/lsb-release with heredocs of its own. It now
# runs the shared writer (50-os-release.sh -> ci_os_write_branded_os_release / _lsb_release), which is also
# what the first-boot rebrand and the post-install re-skin run. The expected text below is exactly what
# those heredocs wrote for a stock 26.04 (resolute) base and CI_OS_VERSION=1.0, except VERSION=, which put the
# company name in front of the version and now names the product ("... (Companion OS 1.0)") like NAME= and
# PRETTY_NAME= (check-repo.sh refuses the old spelling). A pass proves the identity files of the ISO are otherwise unchanged. They are what apt, curtin
# and unattended-upgrades key off: ID=ubuntu,
# ID_LIKE=debian, VERSION_ID, VERSION_CODENAME, UBUNTU_CODENAME and DISTRIB_ID=Ubuntu must never drift.
#
# The fixtures are the real files of the stock Ubuntu 26.04.1 desktop image (/usr/lib/os-release and /etc/lsb-release,
# read from casper/minimal.squashfs of ubuntu-26.04.1-desktop-amd64.iso, sha256 601e30fb...da1f). Besides the literal
# text the test compares the identity keys of the written files with the keys of those stock files, so a key that
# drifts from what Ubuntu ships fails even if the expected text below was edited to match.
#
# CI_OS_BUILD is the day of the build, so it is compared as a placeholder (its position is still pinned).
#
# Pure bash (3.2 safe), no root, no network, nothing read from the host's /etc:
#   backends/ubuntu/lib/tests/os-release-golden.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../os-release.sh"
FIXTURE="$HERE/fixtures/os-release.ubuntu-base.resolute"
LSB_FIXTURE="$HERE/fixtures/lsb-release.ubuntu-base.resolute"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/os-release-golden.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
same() { # same "<label>" <expected file> <actual file>
    if diff -u "$2" "$3" >"$TMP/diff.out"; then pass "$1"; else fail "$1"; sed 's/^/      /' "$TMP/diff.out"; fi
}
stamp_placeholder() { sed 's/^CI_OS_BUILD=.*/CI_OS_BUILD=<day of the build>/' "$1"; }
key_of() { # key_of <KEY> <file>: the value of KEY= with its quotes removed
    sed -n "s/^$1=//p" "$2" | head -n 1 | tr -d '"'
}

[[ -f "$LIB" && -f "$FIXTURE" && -f "$LSB_FIXTURE" ]] || { echo "missing $LIB or a fixture" >&2; exit 2; }
# shellcheck source=../os-release.sh
source "$LIB"
# The stock identity, as customize-chroot.sh saves it before branding; and the version run_theme_step exports.
CI_OS_UBUNTU_BASE_OS_RELEASE="$FIXTURE"
export CI_OS_VERSION=1.0

cat >"$TMP/os-release.expected" <<'EOF'
NAME="Companion OS"
VERSION="26.04 LTS (Companion OS 1.0)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Companion OS 1.0"
VERSION_ID="26.04"
HOME_URL="https://ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
UBUNTU_CODENAME=resolute
VERSION_CODENAME=resolute
CI_OS_ID=ci-os
CI_OS_VERSION="1.0"
CI_OS_BUILD=<day of the build>
LOGO=ci-os-logo
EOF

cat >"$TMP/lsb-release.expected" <<'EOF'
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=26.04
DISTRIB_CODENAME=resolute
DISTRIB_DESCRIPTION="Companion OS 1.0"
EOF

echo "== shared writer vs. what customize-chroot.sh Step 1 wrote"
ci_os_write_branded_os_release "$TMP/os-release"
ci_os_write_branded_lsb_release "$TMP/lsb-release"
stamp_placeholder "$TMP/os-release" >"$TMP/os-release.actual"
same "os-release is byte-identical to the Step 1 heredoc (modulo CI_OS_BUILD)" "$TMP/os-release.expected" "$TMP/os-release.actual"
same "lsb-release is byte-identical to the Step 1 heredoc" "$TMP/lsb-release.expected" "$TMP/lsb-release"
if grep -q -E '^CI_OS_BUILD="[0-9]{8}"$' "$TMP/os-release"; then pass "CI_OS_BUILD is a quoted YYYYMMDD day"; else fail "CI_OS_BUILD is not a quoted YYYYMMDD day"; fi

echo
echo "== the identity keys apt, curtin and unattended-upgrades read are the ones the stock 26.04.1 image ships"
for k in ID ID_LIKE VERSION_ID VERSION_CODENAME UBUNTU_CODENAME; do
    if [[ "$(key_of "$k" "$TMP/os-release")" == "$(key_of "$k" "$FIXTURE")" && -n "$(key_of "$k" "$FIXTURE")" ]]; then
        pass "os-release $k=$(key_of "$k" "$FIXTURE") equals the stock value"
    else
        fail "os-release $k is '$(key_of "$k" "$TMP/os-release")', stock is '$(key_of "$k" "$FIXTURE")'"
    fi
done
for k in DISTRIB_ID DISTRIB_RELEASE DISTRIB_CODENAME; do
    if [[ "$(key_of "$k" "$TMP/lsb-release")" == "$(key_of "$k" "$LSB_FIXTURE")" && -n "$(key_of "$k" "$LSB_FIXTURE")" ]]; then
        pass "lsb-release $k=$(key_of "$k" "$LSB_FIXTURE") equals the stock value"
    else
        fail "lsb-release $k is '$(key_of "$k" "$TMP/lsb-release")', stock is '$(key_of "$k" "$LSB_FIXTURE")'"
    fi
done
# The stock image is the thing that defines "26.04 / resolute": the constants may not drift from it either.
if [[ "$CI_OS_UBUNTU_VERSION_ID" == "$(key_of VERSION_ID "$FIXTURE")" && "$CI_OS_UBUNTU_CODENAME" == "$(key_of UBUNTU_CODENAME "$FIXTURE")" ]]; then
    pass "the supported release constants ($CI_OS_UBUNTU_VERSION_ID, $CI_OS_UBUNTU_CODENAME) are the stock image's"
else
    fail "CI_OS_UBUNTU_VERSION_ID/CI_OS_UBUNTU_CODENAME ($CI_OS_UBUNTU_VERSION_ID, $CI_OS_UBUNTU_CODENAME) differ from the stock image"
fi

echo
echo "== a rewrite keeps the build day of the image (first-boot-rebrand must not re-date it)"
printf 'NAME="Companion OS"\nCI_OS_BUILD="20200101"\n' >"$TMP/rewrite"
ci_os_write_branded_os_release "$TMP/rewrite"
if grep -q -x 'CI_OS_BUILD="20200101"' "$TMP/rewrite"; then pass "existing CI_OS_BUILD survives a rewrite"; else fail "existing CI_OS_BUILD was replaced by a rewrite"; fi
stamp_placeholder "$TMP/rewrite" >"$TMP/rewrite.actual"
same "a rewrite changes nothing else" "$TMP/os-release.expected" "$TMP/rewrite.actual"

echo
echo "== the base is refused unless it is Ubuntu 26.04 (resolute)"
if ci_os_base_is_supported 26.04 resolute 2>/dev/null; then pass "26.04 / resolute is accepted"; else fail "26.04 / resolute was refused"; fi
# What a rebuild sees when customize-chroot.sh runs again on a chroot it already branded.
if ci_os_base_is_supported "$(key_of VERSION_ID "$TMP/os-release")" "$(key_of VERSION_CODENAME "$TMP/os-release")" 2>/dev/null; then
    pass "an already-branded 26.04 chroot is accepted again"; else fail "an already-branded 26.04 chroot was refused"; fi
for pair in "24.04 noble" "22.04 jammy" "25.10 questing" "26.04 noble" "24.04 resolute" "26.10 resolute" "26.04 " " resolute" " "; do
    # shellcheck disable=SC2086
    set -- $pair
    if ci_os_base_is_supported "${1:-}" "${2:-}" >/dev/null 2>"$TMP/refuse.err"; then
        fail "'$pair' was accepted"
    elif grep -q 'Ubuntu 26.04 LTS (resolute)' "$TMP/refuse.err"; then
        pass "'$pair' is refused and the message names the supported release"
    else
        fail "'$pair' was refused without naming Ubuntu 26.04"
    fi
done

echo
echo "== last-resort answers, with no saved base file, no os-release and no lsb_release to ask"
(
    ci_os_find_ubuntu_base_os_release() { return 1; }
    CI_OS_SYSTEM_OS_RELEASE="$TMP/no-such-os-release"
    mkdir -p "$TMP/empty-path"
    PATH="$TMP/empty-path"                          # no lsb_release
    [[ "$(ci_os_ubuntu_codename)" == "resolute" ]] && [[ "$(ci_os_ubuntu_version_id)" == "26.04" ]]
) && pass "codename falls back to resolute and version to 26.04" || fail "the last-resort answers are not resolute / 26.04"
(
    ci_os_find_ubuntu_base_os_release() { return 1; }
    mkdir -p "$TMP/empty-path"
    printf 'UBUNTU_CODENAME=ci\nVERSION_CODENAME=ci\nVERSION_ID="9.9"\n' >"$TMP/branded-wrong"
    CI_OS_SYSTEM_OS_RELEASE="$TMP/branded-wrong"
    PATH="$TMP/empty-path"
    # the marketing codename "ci" is never an Ubuntu suite; a version that is not N.N is ignored
    [[ "$(ci_os_ubuntu_codename)" == "resolute" ]]
) && pass "the marketing codename 'ci' is replaced, not passed on to apt" || fail "codename 'ci' reached the caller"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
