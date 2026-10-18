#!/usr/bin/env bash
#=============================================================================
# Test: the apt pin that keeps dracut out of a Companion OS system works, with apt, on Ubuntu 26.04
#
# The installed base is an initramfs-tools system (the stock live layer removes dracut) and ubuntu-desktop-minimal
# Recommends dracut, which Conflicts with initramfs-tools. customize-chroot.sh installs
# payload/apt/etc/apt/preferences.d/ci-os-no-dracut (Step 1b). This test installs that same file into a 26.04 container and
# asks the real apt, in simulation (-s), what it would do:
#
#   - without the pin dracut has a candidate and a simulated `apt-get install dracut` works (so the test can fail);
#   - with the pin dracut and dracut-core have NO candidate, installing dracut is refused, and a simulated
#     `apt-get install ubuntu-desktop-minimal` (which Recommends dracut) installs neither;
#   - dracut-install keeps its candidate, so its updates still flow: initramfs-tools-core depends on it, and a -1 pin on it
#     held back its security update in a simulated dist-upgrade (the reason it is not in the file);
#   - initramfs-tools stays installable.
#
# It changes /etc/apt/preferences.d of the machine it runs on and runs `apt-get update`, so run it in a throw-away container
# with network:
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:26.04 bash /repo/backends/ubuntu/chroot/tests/no-dracut-pin.sh
#
# (CI_TEST_ALLOW_HOST=1 overrides the container check on a disposable VM.) Exit status is non-zero if any check fails; 2 if it
# cannot run here (not root, not a 26.04 container, no network for apt-get update).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN="$HERE/../payload/apt/etc/apt/preferences.d/ci-os-no-dracut"
DEST=/etc/apt/preferences.d/ci-os-no-dracut
[[ -f "$PIN" ]] || { echo "missing $PIN" >&2; exit 2; }

if [[ "$(id -u)" -ne 0 ]]; then echo "no-dracut-pin test: needs root: run it in a throw-away container" >&2; exit 2; fi
if [[ ! -e /.dockerenv && ! -e /run/.containerenv && "${CI_TEST_ALLOW_HOST:-0}" != 1 ]]; then
    echo "no-dracut-pin test: refusing to change this machine's apt preferences: run it in a throw-away container (or set CI_TEST_ALLOW_HOST=1)" >&2
    exit 2
fi
command -v apt-get >/dev/null 2>&1 || { echo "no-dracut-pin test: apt-get not found" >&2; exit 2; }
if ! grep -q '^VERSION_CODENAME=resolute' /etc/os-release 2>/dev/null; then echo "no-dracut-pin test: this is not Ubuntu 26.04 (resolute)" >&2; exit 2; fi

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

export DEBIAN_FRONTEND=noninteractive
rm -f "$DEST"
if ! apt-cache policy dracut 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    apt-get update -qq >/dev/null 2>&1 || { echo "no-dracut-pin test: apt-get update failed (no network?)" >&2; exit 2; }
fi
candidate() { apt-cache policy "$1" 2>/dev/null | sed -n 's/^  Candidate: //p'; }

echo "== without the pin"
expect "dracut has a candidate ($(candidate dracut))" bash -c "[[ -n '$(candidate dracut)' && '$(candidate dracut)' != '(none)' ]]"
expect "apt-get -s install dracut works" apt-get -s install dracut
SIM0="$(mktemp)"; apt-get -s install ubuntu-desktop-minimal >"$SIM0" 2>&1
expect "a simulated install of ubuntu-desktop-minimal pulls dracut in (so the pin has something to prevent)" grep -q '^Inst dracut ' "$SIM0"
rm -f "$SIM0"

echo
echo "== with the pin installed the way customize-chroot.sh installs it"
install -D -m 0644 "$PIN" "$DEST"
expect "dracut has no candidate" test "$(candidate dracut)" = "(none)"
expect "dracut-core has no candidate" test "$(candidate dracut-core)" = "(none)"
expect "apt-get -s install dracut is refused" bash -c "! apt-get -s install dracut >/dev/null 2>&1"
expect "apt-get -s install dracut-core is refused" bash -c "! apt-get -s install dracut-core >/dev/null 2>&1"
SIM="$(mktemp)"; trap 'rm -f "$SIM"' EXIT        # the simulation is 1,200+ lines: a file, not an argument
apt-get -s install ubuntu-desktop-minimal >"$SIM" 2>&1
expect "a simulated install of ubuntu-desktop-minimal still works" grep -q '^Inst ubuntu-desktop-minimal ' "$SIM"
expect "  and installs neither dracut nor dracut-core" bash -c "! grep -q -E '^Inst dracut(-core)? ' '$SIM'"
expect "dracut-install keeps its candidate ($(candidate dracut-install)), so its updates still reach the system" \
    bash -c "[[ -n '$(candidate dracut-install)' && '$(candidate dracut-install)' != '(none)' ]]"
expect "initramfs-tools stays installable" apt-get -s install initramfs-tools
expect "initramfs-tools-core still depends on dracut-install (why dracut-install is not pinned)" \
    bash -c "apt-cache depends initramfs-tools-core | grep -q 'Depends: dracut-install'"

rm -f "$DEST"
echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
