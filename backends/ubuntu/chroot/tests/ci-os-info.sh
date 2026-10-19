#!/usr/bin/env bash
#=============================================================================
# Test: ci-os-info (backends/ubuntu/chroot/payload/info/usr/local/bin/ci-os-info) says in plain words what Companion OS is doing
#
# Runs the real script against fake files (CI_OS_INFO_* variables) and stub commands on PATH, one scenario at a time: the first-time setup
# finished, running, or not started; Hub answering or not (and at which address: the one on the route out, never a Docker bridge's);
# models; failed services; a pending restart; the ROCm hint only where `ci-os-install-rocm` exists (an arm64 image has none).
#
# Found on the first installed arm64 image (2026-10-19): the old command ended with "For ROCm installation: sudo ci-os-install-rocm", a command
# that does not exist on arm64, and said nothing about the setup, Hub or the models.
#
# Pure bash 3.2, no root, no network, writes only to a temporary directory.
#   backends/ubuntu/chroot/tests/ci-os-info.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../payload/info/usr/local/bin/ci-os-info"
[[ -f "$TOOL" ]] || { echo "missing $TOOL" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-os-info.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
has() { if grep -q -F -- "$2" <<<"$OUT"; then pass "$1"; else fail "$1 (no '$2' in the output)"; fi; }
lacks() { if grep -q -F -- "$2" <<<"$OUT"; then fail "$1 (found '$2')"; else pass "$1"; fi; }

# --- the stubs: each reads its answer from a variable of the scenario ---------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
mk() { printf '#!/bin/sh\n%s\n' "$2" >"$BIN/$1"; chmod 755 "$BIN/$1"; }
mk uname 'echo 7.0.0-test'
mk groups 'echo companion sudo docker'
mk lsmod 'exit 0'
mk lspci 'printf "%s" "$T_LSPCI"'
mk timeout 'shift; exec "$@"'
mk ip 'if [ -n "$T_IP_SRC" ]; then echo "1.1.1.1 via 10.0.2.2 dev enp0s1 src $T_IP_SRC uid 1000"; else exit 1; fi'
mk hostname 'if [ "$1" = "-I" ]; then echo "$T_HOST_I"; else echo companion-os; fi'
mk curl 'printf "%s" "$T_CURL_CODE"'
mk df 'printf "Filesystem Size Used Avail Use%% Mounted on\n/dev/x 62G 19G 40G 32%% /\n"'
mk ollama 'if [ "$T_OLLAMA" = none ]; then printf "NAME ID SIZE MODIFIED\n"; else printf "NAME ID SIZE MODIFIED\nnomic-embed-text:latest abc 274MB now\ngemma3:1b def 806MB now\n"; fi'
# systemctl: is-active for the setup service and avahi; --failed lists T_FAILED lines
mk systemctl 'case "$*" in
  *"is-active"*"ci-os-first-boot-setup.service"*) [ "$T_SETUP_ACTIVE" = yes ] && exit 0 || exit 3 ;;
  *"is-active"*"avahi-daemon"*) [ "$T_AVAHI" = yes ] && exit 0 || exit 3 ;;
  *"--failed"*) [ -n "$T_FAILED" ] && printf "%s\n" "$T_FAILED" ; exit 0 ;;
esac'

# run NAME: run the tool with the scenario variables exported; OUT holds what it printed
run() {
  mkdir -p "$WORK/state"
  OUT="$(env PATH="$BIN:/usr/bin:/bin" CI_OS_INFO_OSRELEASE="$WORK/os-release" CI_OS_INFO_STATE_DIR="$WORK/state" CI_OS_INFO_LOG="/var/log/ci-os-first-boot-setup.log" \
        CI_OS_INFO_REBOOT="$WORK/reboot-required" CI_OS_INFO_HUB_URL="http://stub/" bash "$TOOL" 2>&1)"
}
reset() {
  rm -rf "$WORK/state" "$WORK/reboot-required" "$BIN/ci-os-install-rocm" "$BIN/rocminfo"
  printf 'PRETTY_NAME="Companion OS 1.0"\nVERSION_ID="26.04"\nUBUNTU_CODENAME=resolute\n' >"$WORK/os-release"
  export T_LSPCI="" T_IP_SRC="10.0.2.15" T_HOST_I="172.17.0.1 10.0.2.15" T_CURL_CODE=200 T_OLLAMA=two T_SETUP_ACTIVE=no T_AVAHI=yes T_FAILED=""
}

echo "== a healthy machine (setup finished, Hub answering)"
reset; mkdir -p "$WORK/state"; echo "Mon Oct 19 05:55:59 AM UTC 2026" >"$WORK/state/.first-boot-setup-done"
run
has "the OS name and version are shown" "OS: Companion OS 1.0"
has "setup: finished, with its time" "Setup:    finished Mon Oct 19 05:55:59 AM UTC 2026"
has "Hub answers at the address on the route out, not a Docker bridge's" "answering at http://10.0.2.15:5002"
lacks "  the bridge address is not offered" "172.17.0.1"
has "the .local name is offered while avahi runs" "or http://companion-os.local:5002"
has "models are listed" "Models:   nomic-embed-text:latest, gemma3:1b"
has "disk usage in words" "Disk:     19G used of 62G (32%)"
has "no failed services" "Health:   no failed services"
lacks "no restart line when none is needed" "Restart:"
has "no AMD GPU is said plainly" "No AMD GPU detected"
lacks "the ROCm hint is absent where the command does not exist (arm64)" "ci-os-install-rocm"
has "the support link is there" "https://ci.computer/support"

echo
echo "== the setup states"
reset; run
has "not started: says when it starts" "starts about 3 minutes after the machine starts"
has "  and how to run it now" "sudo ci-os-setup"
reset; T_SETUP_ACTIVE=yes; run
has "running now" "Setup:    running now"
reset; mkdir -p "$WORK/state"; : >"$WORK/state/.first-boot-setup-done"; run
has "an empty marker still reads as finished" "Setup:    finished"

echo
echo "== Hub"
reset; T_CURL_CODE=000; run
has "not answering: a minute after a start is normal" "not answering yet. A minute after a start is normal."
has "  and what to do if it stays down" "docker ps, then sudo ci-os-setup"
lacks "  no address is promised" "answering at"
reset; T_CURL_CODE=302; run
has "a redirect (Hub's pairing page) counts as answering" "answering at http://10.0.2.15:5002"
reset; T_AVAHI=no; run
lacks "no .local name when avahi is not running" ".local:5002"
reset; T_IP_SRC=""; T_HOST_I="192.168.1.20 172.17.0.1"; run
has "no route: the first address of hostname -I" "answering at http://192.168.1.20:5002"
reset; T_IP_SRC=""; T_HOST_I=""; run
has "no address at all: a placeholder, not an empty URL" "<this machine's address>"

echo
echo "== models, services, restart"
reset; T_OLLAMA=none; run
has "no models yet" "Models:   none yet"
reset; mv "$BIN/ollama" "$BIN/ollama.away"; run
has "no Ollama command" "Ollama is not installed"
mv "$BIN/ollama.away" "$BIN/ollama"
reset; T_FAILED="pd-mapper.service loaded failed failed Qualcomm PD mapper service"; run
has "one failed service is counted" "1 failed service(s); list them with: systemctl --failed"
reset; mkdir -p "$WORK"; : >"$WORK/reboot-required"; run
has "a pending restart is said" "Restart:  needed to finish updates"

echo
echo "== GPU and ROCm"
reset; T_LSPCI="00:02.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Strix"; run
has "an AMD GPU is shown" "[AMD/ATI] Strix"
has "no ROCm command, no ROCm: says it is not available here" "ROCm is not available for this architecture"
lacks "  and offers no command that does not exist" "sudo ci-os-install-rocm"
mk ci-os-install-rocm 'exit 0'
T_LSPCI="00:02.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Strix"; run
has "with the command (amd64): the install hint" "ROCm not installed (run: sudo ci-os-install-rocm)"
has "  and the closing hint" "For ROCm installation: sudo ci-os-install-rocm"

echo
echo "== the script itself"
if bash -n "$TOOL"; then pass "it parses"; else fail "it does not parse"; fi
if [[ -x "$TOOL" ]]; then pass "it is executable"; else fail "it is not executable"; fi
if grep -q -E 'set -[a-z]*e' "$TOOL"; then fail "it uses set -e (a missing tool would stop the report halfway)"; else pass "it never stops halfway (no set -e)"; fi
if grep -q -E 'ci-os-install-rocm' "$TOOL" && ! grep -n 'ci-os-install-rocm' "$TOOL" | grep -v 'command -v\|ROCm not installed\|For ROCm installation\|^[0-9]*:#' | grep -q .; then pass "every mention of the ROCm command sits behind a check for it"; else fail "an unguarded mention of ci-os-install-rocm"; fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
