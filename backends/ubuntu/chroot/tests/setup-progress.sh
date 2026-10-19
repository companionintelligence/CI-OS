#!/usr/bin/env bash
#=============================================================================
# Test: setup-progress (backends/ubuntu/chroot/payload/start/usr/libexec/ci-os/setup-progress) shows the first-boot setup on the desktop
#
# Runs the real script against fake status files, a stub notify-send and a stub sleep that moves the status file to its next snapshot,
# one scenario at a time: a live session, no notify-send, an old install, the first sign-in before the setup has started, a full run from
# "waiting" through every step to "ready", a failure and its retry, a sign-in after the setup finished, and the ready message once only.
# Also the wiring around it: the library's total equals provision.sh's steps, the first-boot wrapper writes every state,
# and the image installs the script and its autostart entry.
#
# Pure bash 3.2, no root, no session, writes only to a temporary directory.
#   backends/ubuntu/chroot/tests/setup-progress.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
TOOL="$REPO/backends/ubuntu/chroot/payload/start/usr/libexec/ci-os/setup-progress"
DESKTOP="$REPO/backends/ubuntu/chroot/payload/start/etc/xdg/autostart/ci-os-setup-progress.desktop"
PROVISION="$REPO/backends/ubuntu/provision/provision.sh"
CUSTOMIZE="$REPO/backends/ubuntu/chroot/customize-chroot.sh"
[[ -f "$TOOL" ]] || { echo "missing $TOOL" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/setup-progress.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
has() { if grep -q -F -- "$2" "$LOG"; then pass "$1"; else fail "$1 (no '$2' in the notifications)"; fi; }
lacks() { if grep -q -F -- "$2" "$LOG"; then fail "$1 (found '$2')"; else pass "$1"; fi; }
count() { grep -c . "$LOG" | tr -d ' '; }

# --- the stubs -----------------------------------------------------------------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
# notify-send: one line per call in $LOG; -p prints an id (a new one, or the one of -r)
cat >"$BIN/notify-send" <<'STUB'
#!/bin/sh
line="notify-send"; want_id=0; replace=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p) want_id=1 ;;
        -r) replace="$2"; line="$line [replace=$2]"; shift ;;
        -A|--action) line="$line [ACTION=$2]"; shift ;;
        -a|-i) shift ;;
        *) line="$line | $1" ;;
    esac
    shift
done
echo "$line" >> "$STUB_LOG"
if [ "$want_id" = 1 ]; then
    if [ -n "$replace" ]; then echo "$replace"; else n=$(cat "$STUB_IDS" 2>/dev/null || echo 40); n=$((n + 1)); echo "$n" > "$STUB_IDS"; echo "$n"; fi
fi
exit 0
STUB
# sleep: every call moves the status file to the next snapshot (snap.1, snap.2, ...); out of snapshots, the file stays as it is
cat >"$BIN/sleep" <<'STUB'
#!/bin/sh
n=$(cat "$STUB_SNAP_N" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_SNAP_N"
[ -f "$STUB_SNAPS/snap.$n" ] && cp "$STUB_SNAPS/snap.$n" "$CI_OS_PROGRESS_FILE"
[ -f "$STUB_SNAPS/rm.$n" ] && rm -f "$CI_OS_PROGRESS_FILE"
exit 0
STUB
chmod 755 "$BIN"/*

LOG="$WORK/notifications.log"
snap() { # N STATE STEP STEPS TITLE [DETAIL]   snapshot N of the status file (N=0: the file before the first poll)
    local f="$WORK/snaps/snap.$1"; [[ "$1" == 0 ]] && f="$CI_OS_PROGRESS_FILE"
    printf 'state=%s\nstep=%s\nsteps=%s\ntitle=%s\ndetail=%s\ntime=1760900000\n' "$2" "$3" "$4" "$5" "${6:-}" >"$f"
}
reset() {
    rm -rf "$WORK/snaps" "$WORK/state" "$WORK/config"; mkdir -p "$WORK/snaps" "$WORK/state" "$WORK/config"
    : >"$LOG"; rm -f "$WORK/ids" "$WORK/snap_n"
    export CI_OS_PROGRESS_FILE="$WORK/state/setup-status" CI_OS_PROGRESS_MARKER="$WORK/state/.first-boot-setup-done"
    export CI_OS_PROGRESS_STAMP="$WORK/config/ci-os/setup-ready-shown" CI_OS_PROGRESS_LIVE="$WORK/no-live-here"
    export CI_OS_PROGRESS_POLLS=40 CI_OS_PROGRESS_SLEEP=0
    export STUB_LOG="$LOG" STUB_IDS="$WORK/ids" STUB_SNAPS="$WORK/snaps" STUB_SNAP_N="$WORK/snap_n"
}
run() { OUT="$(env PATH="$BIN:/usr/bin:/bin" sh "$TOOL" 2>&1)"; RC=$?; }

echo "== when nothing is to be said"
reset; mkdir -p "$WORK/live"; : >"$WORK/live/vmlinuz"; CI_OS_PROGRESS_LIVE="$WORK/live/vmlinuz"; snap 0 running 2 7 "Installing Docker"; run
eq "a live session: exit 0, no notification" "$RC/$(count)" "0/0"
reset; snap 0 running 2 7 "Installing Docker"; OUT="$(env PATH="/usr/bin:/bin" CI_OS_PROGRESS_NOTIFY=no-such-notifier sh "$TOOL" 2>&1)"; RC=$?
eq "no notify-send: exit 0, quiet" "$RC/$OUT" "0/"
reset; : >"$CI_OS_PROGRESS_MARKER"; run
eq "an installed system from before this (marker, no status file): exit 0, no notification" "$RC/$(count)" "0/0"
reset; snap 0 done 7 7 "Companion OS is set up"; mkdir -p "$WORK/config/ci-os"; : >"$CI_OS_PROGRESS_STAMP"; run
eq "ready already shown: silent" "$RC/$(count)" "0/0"

echo
echo "== the first sign-in, before the setup has started"
reset; snap 1 running 0 0 "Getting the computer ready"; rm -f "$CI_OS_PROGRESS_FILE"; run
has "a 'getting ready' notice" "Companion OS is getting ready"
has "  it says setup runs in the background and the computer stays usable" "You can keep using the computer"
has "  and the setup's first state replaces it (same notification)" "[replace=41]"
eq "  and the script gave up after its polls (it never hangs)" "$RC" "0"

echo
echo "== a whole run: waiting, every step, ready"
reset
snap 0 waiting 0 0 "Waiting for the internet"
snap 1 running 0 0 "Getting the computer ready"
snap 2 running 1 7 "Preparing the system"
snap 3 running 1 7 "Preparing the system"
snap 4 running 2 7 "Installing Docker"
snap 5 running 5 7 "Downloading the AI models (the longest step)"
snap 6 running 7 7 "Starting Companion Hub"
snap 7 done 7 7 "Companion OS is set up"
run
has "waiting for the internet is said" "Companion OS is waiting for the internet"
has "  with what to do" "Connect to the internet"
has "a step says its number" "Setting up Companion OS: step 2 of 7"
has "  and its title" "Installing Docker"
has "the long step is named" "Downloading the AI models (the longest step)"
has "the last step" "step 7 of 7"
has "the first state before the numbered steps has no number" "| Setting up Companion OS | Getting the computer ready."
has "the ready message" "Companion OS is ready"
has "  and says where Hub is" "Open Companion Hub, the first icon in the dock"
lacks "  with no action button (GNOME's server refuses them on the 26.04 image)" "[ACTION="
eq "eight snapshots, a repeated one is not repeated: 7 messages (waiting, getting ready, steps 1, 2, 5 and 7, ready)" "$(count)" "7"
eq "every message after the first replaces it (one notification on screen)" "$(grep -c 'replace=41' "$LOG" | tr -d ' ')" "6"
eq "the ready stamp is written" "$([[ -e "$CI_OS_PROGRESS_STAMP" ]] && echo yes || echo no)" "yes"

echo
echo "== the ready message is shown once"
reset; snap 0 done 7 7 "Companion OS is set up"; run
eq "a sign-in after the setup finished: one ready message" "$(count)" "1"
eq "  and the stamp is written" "$([[ -e "$CI_OS_PROGRESS_STAMP" ]] && echo yes || echo no)" "yes"
run; eq "the next sign-in says nothing more" "$(count)" "1"

echo "== a failure and its retry"
reset
snap 0 running 4 7 "Installing the AI runtime (Ollama)"
snap 1 failed 4 7 "Setup stopped" "Installing the AI runtime (Ollama)"
snap 2 failed 4 7 "Setup stopped" "Installing the AI runtime (Ollama)"
snap 3 running 4 7 "Installing the AI runtime (Ollama)"
run
has "a failure is said" "Companion OS setup needs attention"
has "  where it stopped" "Setup stopped while: Installing the AI runtime (Ollama)"
has "  and how to try again at once" "sudo ci-os-setup"
eq "the same failure is not said twice; the retry is a new message (3 in all)" "$(count)" "3"

echo
echo "== odd status files"
reset; printf 'state=running\nstep=2\nsteps=7\ntitle=Installing a=b tool\ndetail=\ntime=1\n' >"$CI_OS_PROGRESS_FILE"; run
has "an = inside a value survives" "Installing a=b tool"
reset; printf 'state=running\nstep=x\nsteps=\ntitle=Working\n' >"$CI_OS_PROGRESS_FILE"; run
has "no numbers: the message has no step count" "| Setting up Companion OS | Working."
lacks "  and no 'of'" "step"
reset; printf 'state=exploding\ntitle=?\n' >"$CI_OS_PROGRESS_FILE"; run
eq "an unknown state: no message, no crash" "$RC/$(count)" "0/0"
reset; printf 'garbage\n' >"$CI_OS_PROGRESS_FILE"; run
eq "garbage reads as 'not started': the getting-ready notice, no crash" "$RC/$(count)" "0/1"

echo
echo "== the wiring around it"
steps_calls="$(grep -c '^ *ci_os_status_step "' "$PROVISION")"
begin_core=$(sed -n 's/.*status_steps=\$((status_steps + \([0-9]*\))); fi.*/\1/p' "$PROVISION" | head -n 1)
begin_ext=$(sed -n '/tier_requested extended; then status_steps/s/.*+ \([0-9]*\)).*/\1/p' "$PROVISION" | head -n 1)
eq "provision.sh: the steps it announces equal 1 + core + extended" "$steps_calls" "$((1 + ${begin_core:-0} + ${begin_ext:-0}))"
if grep -q 'setup-status.sh' "$PROVISION" && grep -q 'ci_os_status_begin "\$status_steps"' "$PROVISION"; then pass "provision.sh sources the library and announces its total"; else fail "provision.sh does not use the library"; fi
for what in 'export CI_OS_SETUP_STATUS="/var/lib/ci-os/setup-status"' 'ci_os_status_set waiting 0 0 "Waiting for the internet"' 'ci_os_status_set running 0 0 "Getting the computer ready"' \
            'ci_os_status_state failed "Setup stopped"' 'ci_os_status_state done "Companion OS is set up"' 'ci_os_status_set failed 0 0 "Setup could not start"'; do
    if grep -q -F -- "$what" "$CUSTOMIZE"; then pass "the first-boot wrapper has: $what"; else fail "the first-boot wrapper lacks: $what"; fi
done
if grep -q -F 'install -m 0755 "$START_PAYLOAD/usr/libexec/ci-os/setup-progress"' "$CUSTOMIZE" && grep -q -F 'ci-os-setup-progress.desktop' "$CUSTOMIZE"; then pass "the image installs the script and its autostart entry"; else fail "customize-chroot.sh does not install setup-progress"; fi
if grep -q '^Exec=/usr/libexec/ci-os/setup-progress$' "$DESKTOP" && grep -q '^NoDisplay=true' "$DESKTOP" && grep -q '^OnlyShowIn=GNOME;' "$DESKTOP"; then pass "the autostart entry runs the script, hidden, in GNOME"; else fail "the autostart entry is wrong"; fi

echo
echo "== the script itself"
if sh -n "$TOOL"; then pass "it parses (sh -n)"; else fail "it does not parse"; fi
if [[ -x "$TOOL" ]]; then pass "it is executable"; else fail "it is not executable"; fi
if grep -q -E '(^|[^[:alnum:]_])\[\[|\$\(\(.*\*\*|local |function ' "$TOOL"; then fail "it uses a bashism (it runs under /bin/sh)"; else pass "no bashism"; fi
if grep -v '^[[:space:]]*#' "$TOOL" | grep -q -E '(^|[[:space:]])(-A|--action)[[:space:]=]'; then fail "it uses notify-send actions (the 26.04 image's server refuses them: 'Actions are not supported by this notifications server')"; else pass "no notify-send actions"; fi
if grep -q -E '^[[:space:]]*(sudo|systemctl|docker|rm|mv|chmod|chown|snap|apt)[[:space:]]' "$TOOL"; then fail "it touches the system (it must only read a file and notify)"; else pass "it only reads the status file and notifies"; fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
