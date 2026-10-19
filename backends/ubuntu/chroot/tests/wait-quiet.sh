#!/usr/bin/env bash
#=============================================================================
# Test: wait-quiet (backends/ubuntu/chroot/payload/first-boot/usr/libexec/ci-os/wait-quiet) waits for a quiet machine, and never forever
#
# Runs the script against a fake load average and a stub sleep that records itself, so it takes no real time.
#   backends/ubuntu/chroot/tests/wait-quiet.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../payload/first-boot/usr/libexec/ci-os/wait-quiet"
[[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT" >&2; exit 2; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wq.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
mkdir -p "$TMP/bin"
# the stub sleep records a call and, on request, makes the load drop after N calls (a load file per phase)
cat >"$TMP/bin/sleep" <<'SLP'
#!/bin/sh
echo s >> "$STUB_SLEEP_LOG"
n=$(grep -c . "$STUB_SLEEP_LOG")
[ -n "${STUB_DROP_AFTER:-}" ] && [ "$n" -ge "$STUB_DROP_AFTER" ] && echo "0.10 0.10 0.10 1/100 1" > "$CI_OS_LOADAVG"
exit 0
SLP
chmod +x "$TMP/bin/sleep"
run() { # LOAD NCPU [MAX] [extra env...]
  local load="$1" ncpu="$2" max="${3:-1200}"; shift 3 2>/dev/null || shift $#
  echo "$load $load $load 1/100 1" > "$TMP/loadavg"; : > "$TMP/sleep.log"
  OUT="$(env PATH="$TMP/bin:$PATH" CI_OS_LOADAVG="$TMP/loadavg" CI_OS_NCPU="$ncpu" STUB_SLEEP_LOG="$TMP/sleep.log" "$@" sh "$SCRIPT" "$max" 2>&1)"; RC=$?
  SLEEPS="$(grep -c . "$TMP/sleep.log" | tr -d ' ')"
}
run 0.20 4 1200
eq "a quiet machine: exit 0 after the three samples (two pauses)" "$RC/$SLEEPS" "0/2"
eq "  and it says it was quiet" "$(grep -c 'quiet after' <<<"$OUT" | tr -d ' ')" "1"
run 7.50 4 1200 STUB_DROP_AFTER=5
eq "a busy machine that settles: waits (5 pauses) then 3 quiet samples (2 more pauses), exit 0" "$RC/$SLEEPS" "0/7"
run 7.50 4 60
eq "a machine that stays busy: gives up after the limit (60 s / 15 s = 4 pauses), exit 0" "$RC/$SLEEPS" "0/4"
eq "  and says it goes on anyway" "$(grep -c 'going on anyway' <<<"$OUT" | tr -d ' ')" "1"
run 2.39 4 60
eq "the threshold is 60 percent of the CPUs: 2.39 on 4 CPUs is quiet" "$RC/$SLEEPS" "0/2"
run 2.41 4 60
eq "  2.41 on 4 CPUs is not" "$(grep -c 'going on anyway' <<<"$OUT" | tr -d ' ')" "1"
run 0.50 1 60
eq "one CPU: 0.50 is quiet (below 0.6)" "$RC/$SLEEPS" "0/2"
run 0.70 1 60
eq "  0.70 on one CPU is not" "$(grep -c 'going on anyway' <<<"$OUT" | tr -d ' ')" "1"
run 0.20 4 abc
eq "a SECONDS that is not a number is refused (exit 2)" "$RC" "2"
: > "$TMP/sleep.log"; rm -f "$TMP/loadavg"
OUT="$(env PATH="$TMP/bin:$PATH" CI_OS_LOADAVG="$TMP/none" CI_OS_NCPU=2 STUB_SLEEP_LOG="$TMP/sleep.log" sh "$SCRIPT" 30 2>&1)"; RC=$?
eq "an unreadable load file counts as quiet (the check must not block provisioning)" "$RC" "0"
echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
