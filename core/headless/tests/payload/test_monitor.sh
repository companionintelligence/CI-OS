#!/bin/bash
#=============================================================================
# Tests for usr/local/bin/setup-network-monitor.sh (sourced, so its loop does not run), the reset helper and the recover
# helper, against the PATH stubs of lib.sh. bash 3.2 compatible. Exit: non-zero when a check fails.
#
#   L5  the "is the Wi-Fi link connected or connecting" test, against the real `nmcli` device state strings
#       (src/nmcli/common.c of NetworkManager, C locale: "connecting (getting IP configuration)", "connected
#       (externally)", ...). The old pattern listed enum names that nmcli never prints and matched a bare "connected".
#   R2  exit status 3 of the hotspot script (no AP-capable radio) backs the monitor off for much longer than 45 s
#   L10 the reset helper no longer defaults to one board's interface
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

MONITOR="$BIN/setup-network-monitor.sh"
RESET="$BIN/setup-hotspot-reset.sh"
RECOVER="$BIN/setup-wifi-recover"
[ -f "$MONITOR" ] || { echo "no monitor at $MONITOR" >&2; exit 2; }

# nmcli answers for the two queries the monitor makes about link state
set_device_states() {  # WIFI-STATE  (the ethernet row is always "connected": it must never count as a Wi-Fi link)
    if [ -n "$1" ]; then
        printf '@@ nmcli -t -f TYPE,STATE device status\nethernet:connected\nwifi:%s\n' "$1" > "$W/fixtures/responses"
    else
        printf '@@ nmcli -t -f TYPE,STATE device status\nethernet:connected\n' > "$W/fixtures/responses"
    fi
}
set_general_state() { printf '@@ nmcli -t -f STATE general\n%s\n' "$1" > "$W/fixtures/responses"; }

# in_monitor 'shell code': run code with the monitor sourced, under the stub PATH, in a subshell
in_monitor() {
    ( PATH="$SB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
      # shellcheck source=/dev/null
      . "$MONITOR"
      eval "$1" )
}

echo "== A  sourcing the monitor does not start its loop"
new_sandbox
check "sourcing returns at once and defines the functions" in_monitor 'type wifi_link_active_or_connecting >/dev/null && type start_hotspot >/dev/null'
check "sourcing starts no check at all (no command was run)" test ! -s "$SB_LOG"
check "the monitor forces the C locale (nmcli translates its state names)" \
    sh -c "LC_ALL=de_DE.UTF-8 PATH='$SB_BIN:/usr/bin:/bin' bash -c '. \"$MONITOR\"; [ \"\$LC_ALL\" = C ]'"
end_sandbox

echo "== B  [L5] Wi-Fi link states, as nmcli prints them"
link_case() {  # EXPECTED(yes|no) STATE
    new_sandbox
    set_device_states "$2"
    if in_monitor 'wifi_link_active_or_connecting'; then got=yes; else got=no; fi
    if [ "$got" = "$1" ]; then t_pass "wifi state '${2:-<none>}' -> $1"; else t_fail "wifi state '${2:-<none>}' -> expected $1, got $got"; fi
    end_sandbox
}
for st in "connected" "connected (externally)" "connecting (prepare)" "connecting (configuring)" "connecting (need authentication)" \
          "connecting (getting IP configuration)" "connecting (checking IP connectivity)" "connecting (starting secondary connections)" \
          "connecting (externally)"; do
    link_case yes "$st"
done
for st in "disconnected" "unavailable" "unmanaged" "deactivating" "deactivating (externally)" "connection failed" "connected-ish" "disconnecting" ""; do
    link_case no "$st"
done

echo "== C  boot-time 'still initialising' test (general state)"
general_case() {  # EXPECTED STATE
    new_sandbox
    set_general_state "$2"
    if in_monitor 'nm_is_connecting_or_initializing'; then got=yes; else got=no; fi
    if [ "$got" = "$1" ]; then t_pass "general state '$2' -> initialising=$1"; else t_fail "general state '$2' -> expected $1, got $got"; fi
    end_sandbox
}
general_case yes "connecting"
general_case yes "asleep"
general_case yes "unknown"
general_case yes ""
general_case no "connected"
general_case no "disconnected"
general_case no "connected (site only)"

echo "== D  [R2] the hotspot script's exit status decides how long the monitor waits"
new_sandbox
cat > "$W/fake-start.sh" <<'EOF'
#!/bin/bash
echo "start $*" >> "$STUB_LOG"
exit "${FAKE_START_RC:-0}"
EOF
chmod 755 "$W/fake-start.sh"
export SETUP_DEVICE_HOTSPOT_START="$W/fake-start.sh"
starts() { grep -c '^start' "$SB_LOG" || true; }

FAKE_START_RC=0 in_monitor 'start_hotspot; [ "$hotspot_active" = true ]'
check "exit 0: the hotspot is considered active" eq "$?" 0
check "exit 0 ran the script once" eq "$(starts)" 1

: > "$SB_LOG"
FAKE_START_RC=3 in_monitor 'start_hotspot; [ "$start_backoff_sec" = "$NO_AP_RADIO_BACKOFF_SEC" ] && [ "$hotspot_active" = false ]'
check "exit 3 (no AP-capable radio): the long back-off applies and the hotspot is not active" eq "$?" 0
check "the long back-off is much longer than the normal one (>= 300 s)" in_monitor '[ "$NO_AP_RADIO_BACKOFF_SEC" -ge 300 ] && [ "$NO_AP_RADIO_BACKOFF_SEC" -gt "$START_BACKOFF_SEC" ]'

: > "$SB_LOG"
FAKE_START_RC=3 in_monitor 'start_hotspot; start_hotspot; start_hotspot'
check "after exit 3 the script is NOT run again at the next checks" eq "$(starts)" 1

: > "$SB_LOG"
FAKE_START_RC=3 in_monitor 'start_hotspot; last_start_fail_time=$(( $(date +%s) - 100 )); start_hotspot'
check "... nor 100 s later (the old 45 s back-off would have retried)" eq "$(starts)" 1

: > "$SB_LOG"
FAKE_START_RC=3 in_monitor 'start_hotspot; last_start_fail_time=$(( $(date +%s) - NO_AP_RADIO_BACKOFF_SEC - 5 )); start_hotspot'
check "... but it asks again once the long back-off is over (a dongle may have been plugged in)" eq "$(starts)" 2

: > "$SB_LOG"
FAKE_START_RC=1 in_monitor 'start_hotspot; start_hotspot'
check "exit 1 (failed, rolled back): the normal back-off applies, no immediate retry" eq "$(starts)" 1
: > "$SB_LOG"
FAKE_START_RC=1 in_monitor 'start_hotspot; last_start_fail_time=$(( $(date +%s) - START_BACKOFF_SEC - 1 )); start_hotspot'
check "... and a retry after 45 s" eq "$(starts)" 2

: > "$SB_LOG"
FAKE_START_RC=75 in_monitor 'start_hotspot; [ "$start_backoff_sec" = "$START_BACKOFF_SEC" ]'
check "exit 75 (another instance is starting it): normal back-off" eq "$?" 0
unset SETUP_DEVICE_HOTSPOT_START
end_sandbox

echo "== E  [L10] the reset helper does not assume one board's interface"
new_sandbox
fixture_two_radios
export SETUP_DEVICE_HOTSPOT_START="$BIN/setup-device-hotspot-start.sh"
run_sandboxed "$RESET"
check "reset with no argument detects the AP-capable interface and uses it (wlan1)" has "$SB_LOG" "nmcli device disconnect wlan1"
check "... and never mentions the old default (wlp192s0)" lacks "$SB_LOG" wlp192s0
check "it ends the previous hotspot episode before anything else (the script's stop mode ran)" has "$SB_JOURNAL" "Ending the hotspot episode"
check "it then starts one again (the forced start)" has "$SB_LOG" "systemctl start hostapd-setup.service"
end_sandbox

new_sandbox
run_sandboxed "$RESET" wlan0
check "an explicit interface argument is used as given" has "$SB_LOG" "nmcli device disconnect wlan0"
end_sandbox

new_sandbox
fixture_no_ap_radio
run_sandboxed "$RESET"
check "no AP-capable interface and no argument: exit 3 with a clear message, nothing reset" sh -c "[ '$RC' = 3 ] && grep -q 'pass the interface name' '$W/out.txt' && ! grep -E '^(systemctl |nmcli (device|radio|connection)|ip )' '$SB_LOG'"
end_sandbox
unset SETUP_DEVICE_HOTSPOT_START

echo "== F  the recover helper ends a hotspot episode too"
check "setup-wifi-recover calls the hotspot script's stop mode" has_re "$RECOVER" 'setup-device-hotspot-start\.sh stop'
check "the unit stops come first" sh -c "[ \$(grep -n 'systemctl stop hostapd-setup' '$RECOVER' | head -n 1 | cut -d: -f1) -lt \$(grep -n 'hotspot-start.sh stop' '$RECOVER' | head -n 1 | cut -d: -f1) ]"

summary
