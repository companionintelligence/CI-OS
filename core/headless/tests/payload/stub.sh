#!/bin/bash
# Test double for the system commands the setup-portal shell scripts call. TEST-ONLY.
#
# lib.sh symlinks this one file as sleep, systemd-cat, journalctl, systemctl, nmcli, ip, iw, rfkill, ss, docker (and
# flock when the machine has none) into a directory placed first on PATH; what it does depends on the name it was
# called by. Every call is appended to $STUB_LOG as "name args...". Nothing here touches the real system.
#
# Environment (all set by lib.sh):
#   STUB_LOG        file the calls are appended to
#   STUB_JOURNAL    file systemd-cat appends its input to (the journal)
#   STUB_STATE      directory of fake system state: active/<unit> (a started unit), managed/<if> (NetworkManager
#                   "unmanaged" marker), addr/<if> (addresses on an interface)
#   STUB_FIXTURES   directory with a "responses" file: sections headed "@@ name args..." whose body is printed when a
#                   call matches the heading exactly (iw dev, nmcli -t -f DEVICE,TYPE device, ss ..., iw reg get)
#   STUB_FAIL       newline-separated substrings of "name args": a call that contains one exits 1 and changes nothing
#   STUB_BLOCK      same, but the call blocks (sleeps) instead, so a test can signal the script while it waits
#   STUB_NOACTIVATE substrings of a `systemctl start` line whose unit then does NOT become active (exit 0)
#   STUB_REAL_SLEEP 1: `sleep` really sleeps (default: it returns at once, so the tests are fast)
#   STUB_SLEEP_SECONDS  every `sleep` sleeps this many seconds whatever its argument (to prove a signal interrupts a sleep)
#
# Units are normalised to their name without ".service".

name="${0##*/}"
line="$name $*"

matches() {  # NEEDLES -> 0 when $line contains one of the newline-separated needles
    local n
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        case "$line" in *"$n"*) return 0 ;; esac
    done <<EOF
$1
EOF
    return 1
}

respond() {  # print the body of the section whose heading is "@@ $line"
    [ -f "$STUB_FIXTURES/responses" ] || return 0
    awk -v want="@@ $line" '$0 == want { f = 1; next } /^@@ / { f = 0 } f' "$STUB_FIXTURES/responses"
}

unit_of() {  # foo.service -> foo
    local u="${1%.service}"
    printf '%s' "$u"
}

case "$name" in
    sleep)
        if [ -n "${STUB_SLEEP_SECONDS:-}" ]; then exec /bin/sleep "$STUB_SLEEP_SECONDS"; fi
        if [ "${STUB_REAL_SLEEP:-0}" = 1 ]; then exec /bin/sleep "$@"; fi
        exit 0
        ;;
    systemd-cat)
        cat >> "${STUB_JOURNAL:-/dev/null}"
        exit 0
        ;;
esac

printf '%s\n' "$line" >> "$STUB_LOG"

if [ -n "${STUB_BLOCK:-}" ] && matches "$STUB_BLOCK"; then
    # Wait to be killed. A loop of short sleeps so a signal to the process group ends it promptly.
    while :; do /bin/sleep 1; done
fi
if [ -n "${STUB_FAIL:-}" ] && matches "$STUB_FAIL"; then
    echo "stub $name: refused: $line" >&2
    exit 1
fi

case "$name" in
    systemctl)
        sub="${1:-}"
        case "$sub" in
            start)
                shift
                # STUB_NOACTIVATE: the start "succeeds" but the unit does not stay up (a daemon that exits at once)
                if [ -z "${STUB_NOACTIVATE:-}" ] || ! matches "$STUB_NOACTIVATE"; then
                    for u in "$@"; do mkdir -p "$STUB_STATE/active"; : > "$STUB_STATE/active/$(unit_of "$u")"; done
                fi
                ;;
            stop)
                shift
                for u in "$@"; do rm -f "$STUB_STATE/active/$(unit_of "$u")"; done
                ;;
            is-active)
                shift
                quiet=0
                [ "${1:-}" = "--quiet" ] && { quiet=1; shift; }
                u="$(unit_of "${1:-}")"
                if [ -f "$STUB_STATE/active/$u" ]; then
                    [ "$quiet" = 1 ] || echo active
                    exit 0
                fi
                [ "$quiet" = 1 ] || echo inactive
                exit 3
                ;;
            *) ;;
        esac
        ;;
    nmcli)
        if [ "${1:-}" = device ] && [ "${2:-}" = set ]; then
            # nmcli device set IF managed yes|no
            mkdir -p "$STUB_STATE/managed"
            if [ "${4:-}" = managed ] && [ "${5:-}" = no ]; then : > "$STUB_STATE/managed/$3"; fi
            if [ "${4:-}" = managed ] && [ "${5:-}" = yes ]; then rm -f "$STUB_STATE/managed/$3"; fi
        else
            respond
        fi
        ;;
    ip)
        case "${1:-} ${2:-}" in
            "addr add")
                mkdir -p "$STUB_STATE/addr"
                echo "$3" >> "$STUB_STATE/addr/$5"
                ;;
            "addr del")
                if [ -f "$STUB_STATE/addr/$5" ]; then
                    grep -vx "$3" "$STUB_STATE/addr/$5" > "$STUB_STATE/addr/$5.new" || true
                    mv "$STUB_STATE/addr/$5.new" "$STUB_STATE/addr/$5"
                fi
                ;;
            "addr flush") rm -f "$STUB_STATE/addr/$4" ;;
            "addr show")
                if [ -f "$STUB_STATE/addr/$3" ]; then sed "s|^|    inet |" "$STUB_STATE/addr/$3"; fi
                ;;
            *) respond ;;
        esac
        ;;
    iw | ss | docker | rfkill | journalctl | flock)
        if [ "$name" = flock ]; then
            # Only installed where the machine has no flock(1). Same contract: `flock [-n] FD` locks the open file
            # description behind FD; it stays locked until every descriptor to it is closed.
            exec "$STUB_PYTHON" -c '
import fcntl, sys
args = sys.argv[1:]
nonblock = False
while args and args[0].startswith("-"):
    if args[0] == "-n":
        nonblock = True
    args.pop(0)
try:
    fcntl.flock(int(args[0]), fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblock else 0))
except (BlockingIOError, OSError):
    sys.exit(1)
' "$@"
        fi
        respond
        ;;
    *) ;;
esac
exit 0
