#!/usr/bin/env bash
#=============================================================================
# Test: core/lib/setup-status.sh writes the first-boot progress file, and can never stop an install
#
# Each case sources the real library in a fresh bash (with `set -euo pipefail`, like provision.sh) and looks at the file it wrote:
#   writes the six keys, world-readable, replaced atomically (no temp file left)   no-op without CI_OS_SETUP_STATUS
#   step counter and total                                                         a title cannot add a line (state=done injection)
#   reload takes the counters back from the file (first-boot-setup.sh does, after provision.sh ran in a child process)
#   an unwritable path, missing arguments, a stray `set -u`: every function still returns 0
#
# Needs bash 3.2+ (a stock macOS is enough). Exit status: non-zero if any check fails.
#   core/lib/tests/setup-status.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../setup-status.sh"
[ -f "$LIB" ] || { echo "missing $LIB" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/setup-status.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
F="$WORK/state/setup-status"
key() { sed -n "s/^$1=//p" "$F" | head -n 1; }
# lib CODE: run CODE in a fresh strict bash with the library loaded and the status file set
lib() { bash -c 'set -euo pipefail; export CI_OS_SETUP_STATUS="$1"; . "$2"; shift 2; eval "$1"' _ "$F" "$LIB" "$1"; }

echo "== writing"
rm -rf "$WORK/state"
lib 'ci_os_status_set running 3 7 "Installing the AI runtime" "gemma3:1b"'; rc=$?
eq "returns 0" "$rc" "0"
eq "state" "$(key state)" "running"
eq "step" "$(key step)" "3"
eq "steps" "$(key steps)" "7"
eq "title" "$(key title)" "Installing the AI runtime"
eq "detail" "$(key detail)" "gemma3:1b"
case "$(key time)" in ''|*[!0-9]*) fail "time is not epoch seconds: '$(key time)'" ;; *) pass "time is epoch seconds" ;; esac
eq "exactly six lines" "$(grep -c . "$F" | tr -d ' ')" "6"
eq "world-readable (a desktop user reads it)" "$(ls -l "$F" | cut -c1-10)" "-rw-r--r--"
eq "the directory is made" "$([ -d "$WORK/state" ] && echo yes || echo no)" "yes"
eq "no temporary file is left behind" "$(ls "$WORK/state" | grep -c -v '^setup-status$' | tr -d ' ')" "0"
lib 'ci_os_status_set done 7 7 "Companion OS is set up"'
eq "a second write replaces the first" "$(key state)/$(key detail)" "done/"

echo
echo "== counters"
lib 'ci_os_status_begin 3; ci_os_status_step "One"'
eq "first step is 1 of the total" "$(key step)/$(key steps)/$(key title)/$(key state)" "1/3/One/running"
lib 'ci_os_status_begin 3; ci_os_status_step "One"; ci_os_status_step "Two"; ci_os_status_state failed "Setup stopped" "Two"'
eq "a state keeps the current step" "$(key step)/$(key steps)/$(key state)/$(key title)/$(key detail)" "2/3/failed/Setup stopped/Two"
lib 'ci_os_status_begin 5; ci_os_status_step A; ci_os_status_begin 2; ci_os_status_step B'
eq "begin starts again from 0" "$(key step)/$(key steps)" "1/2"

echo
echo "== a value cannot add a line"
lib 'ci_os_status_set running 1 2 "$(printf "evil\nstate=done\r\n\tx")"'
eq "one state line" "$(grep -c '^state=' "$F" | tr -d ' ')" "1"
eq "the state is still running" "$(key state)" "running"
eq "six lines still" "$(grep -c . "$F" | tr -d ' ')" "6"

echo
echo "== reload (the counters of a child process)"
lib 'ci_os_status_set running 4 7 "Installing the AI runtime"'
out="$(lib 'ci_os_status_reload; echo "$CI_OS_STATUS_STEP/$CI_OS_STATUS_STEPS/$CI_OS_STATUS_TITLE"')"
eq "step, steps and title come back" "$out" "4/7/Installing the AI runtime"
printf 'state=running\nstep=abc\nsteps=\ntitle=T\n' >"$F"
out="$(lib 'ci_os_status_reload; echo "$CI_OS_STATUS_STEP/$CI_OS_STATUS_STEPS/$CI_OS_STATUS_TITLE"')"
eq "non-numbers are ignored" "$out" "0/0/T"
out="$(lib 'ci_os_status_set running 6 7 "Six"; ci_os_status_reload; CI_OS_STATUS_STEP="$CI_OS_STATUS_STEPS"; ci_os_status_state done "Set up"; sed -n "s/^step=//p" "$CI_OS_SETUP_STATUS"')"
eq "done after a reload is step N of N" "$out" "7"

echo
echo "== it never stops an install"
rm -f "$F"
out="$(bash -c 'set -euo pipefail; unset CI_OS_SETUP_STATUS; . "$1"; ci_os_status_begin 2; ci_os_status_step "x"; ci_os_status_state done "y"; ci_os_status_reload; echo survived' _ "$LIB")"
eq "without CI_OS_SETUP_STATUS: nothing written, the caller goes on" "$out/$([ -e "$F" ] && echo file || echo none)" "survived/none"
out="$(bash -c 'set -euo pipefail; export CI_OS_SETUP_STATUS=/proc/no-such/dir/status; . "$1"; ci_os_status_set running 1 2 t; ci_os_status_step x; ci_os_status_state failed y; ci_os_status_reload; echo survived' _ "$LIB" 2>&1)"
eq "an unwritable path: silent, the caller goes on" "$out" "survived"
out="$(bash -c 'set -euo pipefail; export CI_OS_SETUP_STATUS="$1"; . "$2"; ci_os_status_set; ci_os_status_step; ci_os_status_state; echo survived' _ "$F" "$LIB" 2>&1)"
eq "no arguments under set -u: the caller goes on" "$out" "survived"
rm -rf "$WORK/ro"; mkdir -p "$WORK/ro"; chmod 555 "$WORK/ro"
out="$(bash -c 'set -euo pipefail; export CI_OS_SETUP_STATUS="$1/status"; . "$2"; ci_os_status_set running 1 2 t; echo survived' _ "$WORK/ro" "$LIB" 2>&1)"
chmod 755 "$WORK/ro"
eq "a read-only directory: silent, the caller goes on" "$out" "survived"

echo
echo "== the library itself"
if bash -n "$LIB"; then pass "it parses"; else fail "it does not parse"; fi
if grep -q -E '^[[:space:]]*(set -e|exit )' "$LIB"; then fail "it sets -e or exits (it is sourced into other scripts)"; else pass "it neither sets -e nor exits"; fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
