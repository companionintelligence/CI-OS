#!/usr/bin/env bash
#=============================================================================
# Golden test for the shared identity writer, backends/ubuntu/lib/os-release.sh
#
# customize-chroot.sh used to write /etc/os-release and /etc/lsb-release with heredocs of its own. It now
# runs the shared writer (50-os-release.sh -> ci_os_write_branded_os_release / _lsb_release), which is also
# what the first-boot rebrand and the post-install re-skin run. The expected text below is exactly what
# those heredocs wrote for a stock 24.04 (noble) base and CI_OS_VERSION=1.0, except VERSION=, which put the
# company name in front of the version and now names the product ("... (Companion OS 1.0)") like NAME= and
# PRETTY_NAME= (check-repo.sh refuses the old spelling). A pass proves the identity files of the ISO are otherwise unchanged. They are what apt, curtin
# and unattended-upgrades key off: ID=ubuntu,
# ID_LIKE=debian, VERSION_ID, VERSION_CODENAME, UBUNTU_CODENAME and DISTRIB_ID=Ubuntu must never drift.
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
FIXTURE="$HERE/fixtures/os-release.ubuntu-base.noble"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/os-release-golden.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
same() { # same "<label>" <expected file> <actual file>
    if diff -u "$2" "$3" >"$TMP/diff.out"; then pass "$1"; else fail "$1"; sed 's/^/      /' "$TMP/diff.out"; fi
}
stamp_placeholder() { sed 's/^CI_OS_BUILD=.*/CI_OS_BUILD=<day of the build>/' "$1"; }

[[ -f "$LIB" && -f "$FIXTURE" ]] || { echo "missing $LIB or $FIXTURE" >&2; exit 2; }
# shellcheck source=../os-release.sh
source "$LIB"
# The stock identity, as customize-chroot.sh saves it before branding; and the version run_theme_step exports.
CI_OS_UBUNTU_BASE_OS_RELEASE="$FIXTURE"
export CI_OS_VERSION=1.0

cat >"$TMP/os-release.expected" <<'EOF'
NAME="Companion OS"
VERSION="24.04 LTS (Companion OS 1.0)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Companion OS 1.0"
VERSION_ID="24.04"
HOME_URL="https://ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
UBUNTU_CODENAME=noble
VERSION_CODENAME=noble
CI_OS_ID=ci-os
CI_OS_VERSION="1.0"
CI_OS_BUILD=<day of the build>
LOGO=ci-os-logo
EOF

cat >"$TMP/lsb-release.expected" <<'EOF'
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=24.04
DISTRIB_CODENAME=noble
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
echo "== a rewrite keeps the build day of the image (first-boot-rebrand must not re-date it)"
printf 'NAME="Companion OS"\nCI_OS_BUILD="20200101"\n' >"$TMP/rewrite"
ci_os_write_branded_os_release "$TMP/rewrite"
if grep -q -x 'CI_OS_BUILD="20200101"' "$TMP/rewrite"; then pass "existing CI_OS_BUILD survives a rewrite"; else fail "existing CI_OS_BUILD was replaced by a rewrite"; fi
stamp_placeholder "$TMP/rewrite" >"$TMP/rewrite.actual"
same "a rewrite changes nothing else" "$TMP/os-release.expected" "$TMP/rewrite.actual"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
