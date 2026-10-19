#!/usr/bin/env bash
#=============================================================================
# Test: backends/ubuntu/lib/install-rocm-driver.sh installs ROCm from the Ubuntu 26.04 archive, with names that exist
#
# The installer used to ask apt for `rocm rocminfo rocm-smi-lib`. `rocm-smi-lib` is not a package in the resolute
# archive (the tool is `rocm-smi`), so apt refused the whole line ("Unable to locate package"), nothing was installed,
# and `set -e` ended the script before the video/render groups were set. It also carried a second path for another
# Ubuntu release (amdgpu-install from repo.radeon.com); with only Ubuntu 26.04 supported that path is gone, and so is
# everything only it used.
#
# The script only defines functions when it is sourced, so this test sources it, replaces the machine-touching commands
# (apt-get, apt-cache, usermod, uname, the hardware gate) by shell functions that write a log, and drives main().
# Nothing is installed, no root is needed. bash 3.2 safe.
#
# Optional, in a 26.04 container with network and apt lists:  CI_TEST_ARCHIVE=1  also asks the REAL archive whether
# the three names exist for amd64 (apt-cache -o APT::Architecture=amd64 policy ...). Skipped otherwise, and said so.
#
#   backends/ubuntu/lib/tests/install-rocm-driver.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../install-rocm-driver.sh"
[[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rocm-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/calls.log"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

# run_main <hardware 0|1> <codename> <version_id> <missing package or ''>
# Runs main() of the script in a subshell with the system replaced by recorders. Sets RC and OUT; the calls are in $LOG.
run_main() {
    # t_ prefix: the stubs below run inside the script's functions, whose own locals (missing, pkg...) shadow plain names.
    local t_hw="$1" t_codename="$2" t_ver="$3" t_missing="$4"
    : >"$LOG"
    OUT="$( {
        # shellcheck source=../install-rocm-driver.sh
        source "$SCRIPT"                      # keeps the set -euo pipefail of the script: a failed install must end main()
        require_root() { :; }
        ci_os_hardware_supported() { CI_OS_HARDWARE_SUPPORT_REASON="test machine"; [[ "$t_hw" == 1 ]]; }
        ci_os_record_hardware_support() { :; }
        ci_os_ubuntu_codename() { echo "$t_codename"; }
        ci_os_ubuntu_version_id() { echo "$t_ver"; }
        ci_os_marketing_version() { echo "9.9"; }
        apt-get() { echo "apt-get $*" >>"$LOG"; return 0; }
        apt-cache() { echo "apt-cache $*" >>"$LOG"; [[ -z "$t_missing" || "$*" != *"$t_missing"* ]]; }
        usermod() { echo "usermod $*" >>"$LOG"; return 0; }
        uname() { echo "7.0.0-30-generic"; }
        main
    } 2>&1 )"
    RC=$?
}
logged() { grep -q -- "$1" "$LOG"; }
kernel_is_too_old() { ! kernel_is_new_enough "$1"; }
line_of() { grep -n -- "$1" "$LOG" | head -n 1 | cut -d: -f1; }

echo "== the package list"
# shellcheck source=../install-rocm-driver.sh
source "$SCRIPT"
set +e
expect "the packages are exactly: rocm rocminfo rocm-smi" test "${ROCM_PACKAGES[*]}" = "rocm rocminfo rocm-smi"
expect "rocm-smi-lib (not an archive package) is not asked for anywhere in the script" bash -c "! grep -v '^ *#' '$SCRIPT' | grep -q 'rocm-smi-lib'"
expect "nothing is taken from repo.radeon.com (no amdgpu-install, no amdgpu-dkms in the code)" bash -c "! grep -v '^ *#' '$SCRIPT' | grep -v 'echo ' | grep -q -E 'radeon\\.com|amdgpu-install|amdgpu-dkms'"
expect "no code for another Ubuntu release is left (no noble/jammy fallbacks, no 7.2.4 pin)" bash -c "! grep -v '^ *#' '$SCRIPT' | grep -q -i -E 'noble|jammy|7\\.2\\.4|FALLBACK'"

echo
echo "== a supported machine on Ubuntu 26.04"
run_main 1 resolute 26.04 ""
expect "exit status 0" test "$RC" -eq 0
expect "apt-get install -y rocm rocminfo rocm-smi runs once" test "$(grep -c '^apt-get install' "$LOG")" -eq 1
expect "  with exactly those arguments" logged 'apt-get install -y rocm rocminfo rocm-smi$'
expect "apt-get update runs before the install" test "$(line_of 'apt-get update')" -lt "$(line_of 'apt-get install')"
expect "the render and video groups are added" logged 'usermod -a -G render,video'
expect "the groups are set before the packages are installed" test "$(line_of 'usermod')" -lt "$(line_of 'apt-get install')"
expect "every package name is looked up before the install" test "$(grep -c '^apt-cache show' "$LOG")" -eq 3
expect "the output names the release" bash -c "grep -q 'Ubuntu 26.04 (resolute)' <<<\"\$1\"" _ "$OUT"

echo
echo "== a package that is not in the archive stops before the install and says which"
run_main 1 resolute 26.04 "rocm-smi"
expect "exit status is not 0" test "$RC" -ne 0
expect "apt-get install is never run" bash -c "! grep -q '^apt-get install' '$LOG'"
expect "the message names the missing package" bash -c "grep -q 'not in the Ubuntu resolute archive: rocm-smi' <<<\"\$1\"" _ "$OUT"
expect "the groups were still added (GPU access does not depend on the packages)" logged 'usermod -a -G render,video'

echo
echo "== another Ubuntu release is refused and nothing is touched"
for pair in "noble 24.04" "jammy 22.04" "questing 25.10"; do
    set -- $pair
    run_main 1 "$1" "$2" ""
    expect "$1 / $2: exit status 1" test "$RC" -eq 1
    expect "$1 / $2: no apt-get, no usermod" test ! -s "$LOG"
    expect "$1 / $2: the message names the supported release" bash -c "grep -q 'Ubuntu 26.04 LTS (resolute)' <<<\"\$1\"" _ "$OUT"
done

echo
echo "== unsupported hardware exits 0 and installs nothing"
run_main 0 resolute 26.04 ""
expect "exit status 0" test "$RC" -eq 0
expect "no apt-get, no usermod" test ! -s "$LOG"
expect "it says the desktop is unchanged" bash -c "grep -q 'The desktop is unchanged' <<<\"\$1\"" _ "$OUT"

echo
echo "== the kernel check (only a warning)"
for k in 7.0.0-30-generic 6.17.0-19-generic 6.18.4 6.20.1-generic 8.1; do
    expect "$k is new enough" kernel_is_new_enough "$k"
done
for k in 6.16.9 6.8.0-45-generic 5.15.0-100 garbage ""; do
    expect "'$k' is too old (or not a kernel version)" kernel_is_too_old "$k"
done

echo
echo "== the real archive (CI_TEST_ARCHIVE=1 in a 26.04 container)"
if [[ "${CI_TEST_ARCHIVE:-0}" == 1 ]] && command -v apt-cache >/dev/null 2>&1 && [[ -r /etc/os-release ]] && grep -q '^VERSION_CODENAME=resolute' /etc/os-release; then
    for p in "${ROCM_PACKAGES[@]}"; do
        cand="$(apt-cache -o APT::Architecture=amd64 policy "$p" 2>/dev/null | sed -n 's/^  Candidate: //p')"
        if [[ -n "$cand" && "$cand" != "(none)" ]]; then pass "$p exists in the resolute archive for amd64 ($cand)"; else fail "$p is not in the resolute archive for amd64"; fi
    done
    cand="$(apt-cache -o APT::Architecture=amd64 policy rocm-smi-lib 2>/dev/null | sed -n 's/^  Candidate: //p')"
    if [[ -z "$cand" ]]; then pass "rocm-smi-lib is still not an archive package (the reason it must not be asked for)"; else fail "rocm-smi-lib now exists ($cand): the script could name it again"; fi
else
    echo "SKIP  real-archive check (set CI_TEST_ARCHIVE=1 in an Ubuntu 26.04 container with network and apt lists)"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
