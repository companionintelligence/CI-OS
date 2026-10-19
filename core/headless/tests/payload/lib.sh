#!/bin/bash
# Helpers for the shell tests of core/headless/payload (sourced by test_*.sh). TEST-ONLY.
#
# bash 3.2 compatible (no associative arrays, no mapfile, no ${var,,}); needs python3 only for the flock stand-in on
# machines without flock(1) (a stock macOS).
#
# shellcheck disable=SC2034  # this file is sourced: the variables are read by the test scripts
#
#   PAYLOAD_DIR  the payload under test (default: this repository's core/headless/payload); the mutation checker points
#                it at a modified copy.
#
# Deletion rule: the only thing this library ever removes is a scratch directory that new_sandbox created itself, proven by
# a marker file inside it. (A first version removed "$W" unchecked; when mktemp failed on a overloaded machine, "cd ''" left
# W at the current directory - the tests directory - and end_sandbox deleted the tests.)

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../../.." && pwd)"
PAYLOAD="${PAYLOAD_DIR:-$REPO_ROOT/core/headless/payload}"
BIN="$PAYLOAD/usr/local/bin"
SANDBOX_MARKER=".payload-test-sandbox"

PASS=0
FAIL=0
SKIP=0

t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
note() { printf '      %s\n' "$*"; }

# check DESC CMD...: pass when the command succeeds
check() {
    local desc="$1"
    shift
    if "$@"; then t_pass "$desc"; else t_fail "$desc"; fi
}

# check_not DESC CMD...: pass when the command fails
check_not() {
    local desc="$1"
    shift
    if "$@"; then t_fail "$desc"; else t_pass "$desc"; fi
}

eq() { [ "$1" = "$2" ]; }

# has FILE PATTERN (fixed string) / lacks FILE PATTERN
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
has_re() { grep -qE -- "$2" "$1" 2>/dev/null; }
count_of() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

mode_of() {  # octal permission bits of FILE, portable between GNU and BSD stat
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

summary() {
    echo
    echo "== $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" -eq 0 ]
}

# --- sandbox -----------------------------------------------------------------------------------------------------------------
# new_sandbox [no-iw]: a scratch root for SETUP_DEVICE_ROOT plus a bin directory of stubs. Sets W (the directory),
# SB_ROOT, SB_BIN, SB_STATE, SB_LOG (calls), SB_JOURNAL and exports the STUB_* variables. Exits 2 (cannot run) when it
# cannot make a scratch directory of its own.
new_sandbox() {
    local base made
    base="${TMPDIR:-/tmp}"
    made="$(mktemp -d "${base%/}/payload-test.XXXXXX")" || made=""
    case "$made" in
        /*/payload-test.*) ;;
        *) echo "payload tests: cannot create a scratch directory under $base (mktemp failed); nothing was run" >&2; exit 2 ;;
    esac
    [ -d "$made" ] && [ -O "$made" ] || { echo "payload tests: scratch directory $made is not ours" >&2; exit 2; }
    : > "$made/$SANDBOX_MARKER" || { echo "payload tests: cannot write in $made" >&2; exit 2; }
    W="$(cd "$made" && pwd -P)" || exit 2
    case "$W" in
        "$TESTS_DIR"|"$TESTS_DIR"/*|"$REPO_ROOT"|"$REPO_ROOT"/*|/|"${HOME:-/nonexistent}")
            echo "payload tests: refusing to use $W as a scratch directory" >&2; exit 2 ;;
    esac
    SB_ROOT="$W/root"
    SB_BIN="$W/bin"
    SB_STATE="$W/state"
    SB_LOG="$W/calls.log"
    SB_JOURNAL="$W/journal.log"
    mkdir -p "$SB_ROOT/etc/hostapd" "$SB_ROOT/etc/dnsmasq.d" "$SB_ROOT/etc/setup-device" "$SB_ROOT/var/lib/setup-device" \
        "$SB_ROOT/var/log" "$SB_ROOT/run" "$SB_ROOT/usr/local/bin" "$SB_ROOT/proc" "$SB_ROOT/sys/class/net" \
        "$SB_BIN" "$SB_STATE" "$W/fixtures" || exit 2
    : > "$SB_LOG"
    : > "$SB_JOURNAL"
    local c
    for c in sleep systemd-cat journalctl systemctl nmcli ip rfkill ss docker; do
        ln -s "$TESTS_DIR/stub.sh" "$SB_BIN/$c"
    done
    if [ "${1:-}" != no-iw ]; then ln -s "$TESTS_DIR/stub.sh" "$SB_BIN/iw"; fi
    STUB_PYTHON="$(command -v python3 || true)"
    export STUB_PYTHON
    if ! command -v flock >/dev/null 2>&1; then
        [ -n "$STUB_PYTHON" ] || { echo "no flock and no python3: cannot run" >&2; exit 2; }
        ln -s "$TESTS_DIR/stub.sh" "$SB_BIN/flock"
    fi
    # the prescan the start script runs: records the call and leaves a scan result
    cat > "$SB_ROOT/usr/local/bin/setup-device-prescan.py" <<'EOF'
#!/bin/bash
echo "prescan $*" >> "$STUB_LOG"
echo '{"networks": []}' > "${SETUP_DEVICE_ROOT}/var/lib/setup-device/last-scan.json"
EOF
    chmod 755 "$SB_ROOT/usr/local/bin/setup-device-prescan.py"
    export STUB_LOG="$SB_LOG" STUB_JOURNAL="$SB_JOURNAL" STUB_STATE="$SB_STATE" STUB_FIXTURES="$W/fixtures"
    export SETUP_DEVICE_ROOT="$SB_ROOT"
    unset STUB_FAIL STUB_BLOCK STUB_NOACTIVATE STUB_REAL_SLEEP STUB_SLEEP_SECONDS SETUP_DEVICE_COUNTRY
    fixture_default
}

# Removes the scratch directory new_sandbox made - and only that: the directory must carry the marker file and a
# payload-test.* name inside the temp directory; anything else is left alone.
end_sandbox() {
    case "${W:-}" in
        /*/payload-test.*)
            if [ -f "$W/$SANDBOX_MARKER" ] && [ "$W" != "$TESTS_DIR" ]; then rm -rf "$W"; fi
            ;;
    esac
    W=""
}

# The machine most tests run on: eth0 and one Wi-Fi interface (phy0, can do AP), regulatory domain unknown (world, 00).
fixture_default() {
    cat > "$W/fixtures/responses" <<'EOF'
@@ nmcli -t -f DEVICE,TYPE device
lo:loopback
eth0:ethernet
wlan0:wifi
@@ iw dev
phy#0
	Interface wlan0
		ifindex 3
		wdev 0x1
		addr 02:00:00:00:00:00
		type managed
@@ iw phy phy0 info
Wiphy phy0
	max # scan SSIDs: 20
	Supported interface modes:
		 * IBSS
		 * managed
		 * AP
		 * AP/VLAN
		 * monitor
	Band 1:
		Capabilities: 0x1
@@ iw reg get
global
country 00: DFS-UNSET
	(1 - 13 @ 40), (N/A, 20), (N/A)
@@ ss -H -ltnp sport = :80
EOF
}

# Two Wi-Fi interfaces: wlan0 (phy0) cannot run an AP, wlan1 (phy1) can.
fixture_two_radios() {
    cat > "$W/fixtures/responses" <<'EOF'
@@ nmcli -t -f DEVICE,TYPE device
eth0:ethernet
wlan0:wifi
wlan1:wifi
@@ iw dev
phy#0
	Interface wlan0
		ifindex 3
		type managed
phy#1
	Interface wlan1
		ifindex 4
		type managed
@@ iw phy phy0 info
Wiphy phy0
	Supported interface modes:
		 * IBSS
		 * managed
		 * monitor
	Band 1:
		Capabilities: 0x1
@@ iw phy phy1 info
Wiphy phy1
	Supported interface modes:
		 * IBSS
		 * managed
		 * AP
		 * monitor
	Band 1:
		Capabilities: 0x1
@@ iw reg get
global
country 00: DFS-UNSET
@@ ss -H -ltnp sport = :80
EOF
}

# One Wi-Fi interface and it cannot run an access point (managed only).
fixture_no_ap_radio() {
    cat > "$W/fixtures/responses" <<'EOF'
@@ nmcli -t -f DEVICE,TYPE device
eth0:ethernet
wlan0:wifi
@@ iw dev
phy#0
	Interface wlan0
		ifindex 3
		type managed
@@ iw phy phy0 info
Wiphy phy0
	Supported interface modes:
		 * managed
		 * monitor
	Band 1:
		Capabilities: 0x1
@@ iw reg get
global
country 00: DFS-UNSET
EOF
}

# Run a payload script with the sandbox PATH. Output goes to $W/out.txt; the exit status is left in RC.
# PATH is the stubs, then the system directories (never /usr/local or Homebrew, so no real iw/nmcli/docker can leak in).
run_sandboxed() {
    RC=0
    PATH="$SB_BIN:/usr/bin:/bin:/usr/sbin:/sbin" bash "$@" > "$W/out.txt" 2>&1 || RC=$?
}

# The same, in the background, in its own process group (so a test can signal the script AND what it is running).
# Sets BGPID (also the process group id).
run_sandboxed_bg() {
    # A shell that is itself a background job of a non-interactive shell (a CI step, `run.sh &`, the mutation checker
    # started that way) has SIGINT and SIGHUP IGNORED, and a shell script started from it can neither trap nor un-ignore
    # them: `trap 'exit 130' INT` silently does nothing. So the script under test is started through python, which
    # restores the default dispositions (SIGPIPE too: python itself ignores it) before exec'ing bash - the dispositions
    # systemd and a terminal give it.
    set -m
    PATH="$SB_BIN:/usr/bin:/bin:/usr/sbin:/sbin" "${STUB_PYTHON:-python3}" -c '
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGHUP, signal.SIG_DFL)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)   # python ignores SIGPIPE, and ignored signals survive exec
os.execvp("bash", ["bash"] + sys.argv[1:])' "$@" > "$W/out-bg.txt" 2>&1 &
    BGPID=$!
    set +m
}

# wait_for_log PATTERN [SECONDS]: poll the call log until a line contains PATTERN
wait_for_log() {
    local i=0 limit=$((${2:-10} * 20))
    while [ "$i" -lt "$limit" ]; do
        grep -qF -- "$1" "$SB_LOG" 2>/dev/null && return 0
        /bin/sleep 0.05
        i=$((i + 1))
    done
    return 1
}

# wait_for_exit PID [SECONDS]: wait for a background job (any status), with a timeout; sets BGRC
wait_for_exit() {
    local i=0 limit=$((${2:-10} * 20))
    while kill -0 "$1" 2>/dev/null; do
        [ "$i" -ge "$limit" ] && { BGRC=timeout; return 1; }
        /bin/sleep 0.05
        i=$((i + 1))
    done
    BGRC=0
    wait "$1" 2>/dev/null || BGRC=$?
    return 0
}
