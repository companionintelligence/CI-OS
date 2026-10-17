#!/bin/bash
#=============================================================================
# Tests for usr/local/bin/setup-device-hotspot-start.sh (start, stop, --detect-interface) and the helpers around it,
# against PATH stubs that record every call and keep a little fake system state (stub.sh). No root, no radio, no
# systemd, no network. bash 3.2 compatible. Exit: non-zero when a check fails.
#
# What it proves (report 02 findings in brackets):
#   - the episode is reversible: after a stop, after a failed start, after SIGTERM/SIGINT/SIGHUP at any point, the
#     AP address is gone, NetworkManager manages the interface again, dnsmasq, hostapd and (if the script started it)
#     nginx are stopped and the state is removed [L4]
#   - two instances cannot race; a second start exits 75 without touching anything; a start while the access point is up
#     changes nothing; a crash that could not clean up is repaired by the next start [L6]
#   - Docker and Traefik are never touched, even when a container owns port 80 [L3]
#   - the interface is one that supports AP mode; none -> exit 3 and NOTHING changed [R2]
#   - the regulatory country comes from an override or `iw reg get`, never a constant; unknown -> none set [R1]
#   - the hostapd config isolates clients, has no TKIP, and is root-only; the dnsmasq log is root-only [R3, H3]
#
# ONLY_SECTIONS="A F" runs just those sections (the mutation checker uses it); unset runs all.
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

want() { [ -z "${ONLY_SECTIONS:-}" ] || case " $ONLY_SECTIONS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

HOTSPOT="$BIN/setup-device-hotspot-start.sh"
[ -f "$HOTSPOT" ] || { echo "no hotspot script at $HOTSPOT" >&2; exit 2; }
command -v mktemp >/dev/null 2>&1 || exit 2

STATEF() { echo "$SB_ROOT/run/setup-device/hotspot.state"; }
HCONF() { echo "$SB_ROOT/etc/hostapd/hostapd-setup.conf"; }
DCONF() { echo "$SB_ROOT/etc/dnsmasq.d/setup-portal.conf"; }

line_no() { grep -nF -- "$1" "$SB_LOG" | head -n 1 | cut -d: -f1; }
before() {  # PATTERN-A PATTERN-B: A is logged before B
    local a b
    a="$(line_no "$1")"
    b="$(line_no "$2")"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
journal_has() { has "$SB_JOURNAL" "$1"; }

# After any end of an episode: everything the start changed is back.
assert_rolled_back() {  # LABEL IFACE
    local label="$1" iface="${2:-wlan0}"
    check "$label: the AP address is off $iface" test ! -s "$SB_STATE/addr/$iface"
    check "$label: NetworkManager manages $iface again" test ! -e "$SB_STATE/managed/$iface"
    check "$label: hostapd-setup is stopped" test ! -e "$SB_STATE/active/hostapd-setup"
    check "$label: dnsmasq-setup is stopped" test ! -e "$SB_STATE/active/dnsmasq-setup"
    check "$label: nginx is stopped (the script started it)" test ! -e "$SB_STATE/active/nginx"
    check "$label: the state file is gone" test ! -e "$(STATEF)"
}

if want A; then
echo "== A  a successful start and its stop"
new_sandbox
run_sandboxed "$HOTSPOT"
check "start exits 0" eq "$RC" 0
check "hostapd, dnsmasq and nginx are running" test -e "$SB_STATE/active/hostapd-setup" -a -e "$SB_STATE/active/dnsmasq-setup" -a -e "$SB_STATE/active/nginx"
check "the AP address is on wlan0" has "$SB_STATE/addr/wlan0" 192.168.99.1/24
check "NetworkManager was told to leave wlan0 alone" test -e "$SB_STATE/managed/wlan0"
check "the state records the interface, the unmanaged interface and nginx" \
    sh -c "grep -qx 'iface=wlan0' '$(STATEF)' && grep -qx 'nm_unmanaged=1' '$(STATEF)' && grep -qx 'nginx_started=1' '$(STATEF)'"
check "the state file is root-only" eq "$(mode_of "$(STATEF)")" 600
check "pre-scan ran before hostapd started" before "prescan wlan0" "systemctl start hostapd-setup.service"
check "hostapd started before dnsmasq" before "systemctl start hostapd-setup.service" "systemctl start dnsmasq-setup.service"
check "[L3] no docker call at all, not even a look at the containers" lacks "$SB_LOG" docker
check "[L3] nothing named traefik is mentioned in any call" lacks "$SB_LOG" traefik
check "[L2] hostapd/dnsmasq/nginx are started by name (no enable)" lacks "$SB_LOG" "systemctl enable"
H="$(HCONF)"
check "[R3] the hostapd config isolates clients (ap_isolate=1)" has "$H" "ap_isolate=1"
check "[R3] no TKIP anywhere in the hostapd config" lacks "$H" TKIP
check "[R3] WPA2/CCMP only" has_re "$H" '^rsn_pairwise=CCMP$'
check_not "[R1] no country is invented (kernel domain is 00 here)" has_re "$H" '^country_code='
check "[R1] and the channel is one every domain allows (2.4 GHz, 1-11)" has_re "$H" '^channel=6$'
check "the interface in the config is the detected one" has "$H" "interface=wlan0"
check "[H3] the hostapd config holds the passphrase and is root-only" eq "$(mode_of "$H")" 600
check "the SSID suffix file is world-readable (the backend serves it)" eq "$(mode_of "$SB_ROOT/var/lib/setup-device/ssid-suffix")" 644
check "the dnsmasq config binds the detected interface" has "$(DCONF)" "interface=wlan0"
check "[H3] the DNS query log is root-only" eq "$(mode_of "$SB_ROOT/var/log/dnsmasq-setup.log")" 600
check "the dnsmasq config points its log at the root-only file" has "$(DCONF)" "log-facility=$SB_ROOT/var/log/dnsmasq-setup.log"

run_sandboxed "$HOTSPOT" stop
check "stop exits 0" eq "$RC" 0
assert_rolled_back "stop"
check "stop restored management with the documented command (nmcli device set <if> managed yes)" has "$SB_LOG" "nmcli device set wlan0 managed yes"
check "stop removed exactly the AP address (the one 'ip addr flush' is the start's own reset of the interface)" \
    sh -c "grep -qF 'ip addr del 192.168.99.1/24 dev wlan0' '$SB_LOG' && test \$(grep -cF 'ip addr flush' '$SB_LOG') = 1"
run_sandboxed "$HOTSPOT" stop
check "a second stop is harmless" eq "$RC" 0
end_sandbox
fi

if want B; then
echo "== B  stop does not stop an nginx it did not start"
new_sandbox
mkdir -p "$SB_STATE/active"
: > "$SB_STATE/active/nginx"       # running before the episode, for some other reason
run_sandboxed "$HOTSPOT"
check "start exits 0" eq "$RC" 0
check "the state does not claim nginx" sh -c "! grep -q nginx_started '$(STATEF)'"
run_sandboxed "$HOTSPOT" stop
check "nginx is still running after the stop" test -e "$SB_STATE/active/nginx"
check "hostapd and dnsmasq are stopped" test ! -e "$SB_STATE/active/hostapd-setup" -a ! -e "$SB_STATE/active/dnsmasq-setup"
end_sandbox
fi

if want C; then
echo "== C  Docker and Traefik are left alone, even when a container owns port 80"
new_sandbox
# the last section of the default fixture is the (empty) answer to `ss ... sport = :80`: give it a listener, and add a docker answer
cat >> "$W/fixtures/responses" <<'EOF'
LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("docker-proxy",pid=4242,fd=7))
@@ docker ps
abc123   traefik:v3   "traefik"   traefik
EOF
run_sandboxed "$HOTSPOT"
check "start still succeeds" eq "$RC" 0
check "[L3] no 'docker stop', no docker call whatsoever" lacks "$SB_LOG" docker
check "the journal names the process holding port 80 and says it is left running" sh -c "grep -q 'port 80 is also held' '$SB_JOURNAL' && grep -q docker-proxy '$SB_JOURNAL'"
run_sandboxed "$HOTSPOT" stop
check "[L3] still no docker call after the stop" lacks "$SB_LOG" docker
end_sandbox
fi

if want D; then
echo "== D  interface selection (AP mode in 'iw phy ... info')"
new_sandbox
fixture_two_radios
run_sandboxed "$HOTSPOT"
check "two radios: start succeeds" eq "$RC" 0
check "the interface that supports AP is chosen (wlan1), not the first one listed (wlan0)" has "$(HCONF)" "interface=wlan1"
check "the other radio is never touched" sh -c "! grep -E 'nmcli device (set|disconnect) wlan0|ip .* wlan0' '$SB_LOG'"
check "wlan1 is unmanaged and addressed" test -e "$SB_STATE/managed/wlan1" -a -s "$SB_STATE/addr/wlan1"
run_sandboxed "$HOTSPOT" stop
assert_rolled_back "two radios, stop" wlan1
end_sandbox

new_sandbox
fixture_two_radios
run_sandboxed "$HOTSPOT" --detect-interface
check "--detect-interface prints the AP-capable interface and exits 0" sh -c "[ '$RC' = 0 ] && [ \"\$(cat '$W/out.txt')\" = wlan1 ]"
check "--detect-interface changes nothing" sh -c "! grep -E '^(systemctl|nmcli device set|ip )' '$SB_LOG'"
end_sandbox

new_sandbox
fixture_no_ap_radio
run_sandboxed "$HOTSPOT"
check "[R2] no AP-capable interface: exit 3" eq "$RC" 3
check "[R2] NOTHING was changed: no unit started, NetworkManager untouched, no address, no config rewritten" \
    sh -c "! grep -E '^(systemctl start|nmcli device|ip |rfkill)' '$SB_LOG' && test ! -e '$(HCONF)' && test ! -e '$(STATEF)' && test ! -e '$SB_STATE/managed/wlan0'"
check "the journal says why, in words" sh -c "grep -q 'no Wi-Fi interface supports AP mode' '$SB_JOURNAL'"
run_sandboxed "$HOTSPOT" --detect-interface
check "--detect-interface exits 3 too" eq "$RC" 3
run_sandboxed "$HOTSPOT" stop
check "stop on a machine that never started one is harmless" eq "$RC" 0
end_sandbox

new_sandbox
printf '@@ nmcli -t -f DEVICE,TYPE device\neth0:ethernet\n@@ iw dev\n' > "$W/fixtures/responses"
run_sandboxed "$HOTSPOT"
check "no Wi-Fi interface at all: exit 3 and a clear message" sh -c "[ '$RC' = 3 ] && grep -q 'no Wi-Fi interface found' '$SB_JOURNAL'"
end_sandbox

new_sandbox no-iw
if PATH="$SB_BIN:/usr/bin:/bin:/usr/sbin:/sbin" command -v iw >/dev/null 2>&1; then
    t_skip "without iw the first Wi-Fi interface is used, with a warning (this machine has a real iw on PATH)"
else
    run_sandboxed "$HOTSPOT"
    check "without iw nothing can be verified: the first Wi-Fi interface is used (old behaviour), start succeeds" eq "$RC" 0
    check "... and the journal says it could not verify AP support" sh -c "grep -q 'cannot verify' '$SB_JOURNAL'"
    check "... on the interface nmcli named" has "$(HCONF)" "interface=wlan0"
fi
end_sandbox
fi

if want E; then
echo "== E  regulatory country"
country_case() {  # DESC EXPECTED(country or none) [setup-function]
    new_sandbox
    [ -n "${3:-}" ] && "$3"
    run_sandboxed "$HOTSPOT"
    if [ "$2" = none ]; then
        check "$1" sh -c "[ '$RC' = 0 ] && ! grep -q '^country_code=' '$(HCONF)' && ! grep -q '^ieee80211d' '$(HCONF)'"
    else
        check "$1" sh -c "[ '$RC' = 0 ] && grep -qx 'country_code=$2' '$(HCONF)' && grep -qx 'ieee80211d=1' '$(HCONF)'"
    fi
    end_sandbox
}
set_reg() {  # replace the body of the 'iw reg get' answer; \n for new lines
    awk -v body="$1" '/^@@ iw reg get$/ { print; printf "%s\n", body; skip = 1; next } /^@@ / { skip = 0 } !skip' \
        "$W/fixtures/responses" > "$W/fixtures/responses.new" && mv "$W/fixtures/responses.new" "$W/fixtures/responses"
}
set_kernel_de() { set_reg 'global\ncountry DE: DFS-ETSI'; }
set_kernel_99() { set_reg 'global\ncountry 99: DFS-UNSET'; }
set_phy_de_only() { set_reg 'global\ncountry 00: DFS-UNSET\n\nphy#0 (self-managed)\ncountry DE: DFS-ETSI'; }
set_phy_de_global_empty() { set_reg 'global\n\nphy#0 (self-managed)\ncountry DE: DFS-ETSI'; }
set_file_fr() { set_kernel_de; echo fr > "$SB_ROOT/etc/setup-device/regdom"; }
set_env_gb() { set_kernel_de; export SETUP_DEVICE_COUNTRY=gb; }
set_cmdline_jp() { set_kernel_de; echo "quiet splash ci.country=jp ro" > "$SB_ROOT/proc/cmdline"; }
set_file_garbage() { echo "hello world" > "$SB_ROOT/etc/setup-device/regdom"; }
set_file_three() { set_kernel_de; echo "DEU" > "$SB_ROOT/etc/setup-device/regdom"; }
set_file_world() { set_kernel_de; echo "00" > "$SB_ROOT/etc/setup-device/regdom"; }
country_case "the world domain (00) sets no country at all" none
country_case "the kernel's current domain is used (DE from 'iw reg get')" DE set_kernel_de
country_case "a custom/intersection domain (99) is not a country" none set_kernel_99
country_case "only the global section counts; a per-phy domain (self-managed chips) is ignored" none set_phy_de_only
country_case "a per-phy domain is ignored even when the global section names none" none set_phy_de_global_empty
country_case "the override file beats the kernel's domain (fr over DE)" FR set_file_fr
country_case "the environment override works (gb)" GB set_env_gb
country_case "ci.country=jp on the kernel command line works" JP set_cmdline_jp
country_case "a garbage override file is ignored, not truncated into a country (HE)" none set_file_garbage
country_case "three letters are not a country (DEU is not truncated to DE-or-anything)" DE set_file_three
country_case "an override of 00 is not a country; the kernel's domain applies" DE set_file_world
unset SETUP_DEVICE_COUNTRY
fi

if want F; then
echo "== F  failure part-way: the start undoes itself [L4]"
fail_case() {  # LABEL FAIL-SUBSTRING [EXPECTED-RC]
    new_sandbox
    STUB_FAIL="$2" run_sandboxed "$HOTSPOT"
    check "$1: the start fails (exit ${3:-1})" eq "$RC" "${3:-1}"
    assert_rolled_back "$1"
    check "$1: the journal says it is undoing the start" journal_has "undoing what it changed"
    # the lock is released: the next start can run
    run_sandboxed "$HOTSPOT"
    check "$1: a later start is not blocked by the failed one" eq "$RC" 0
    run_sandboxed "$HOTSPOT" stop
    end_sandbox
}
fail_case "dnsmasq fails to start" "systemctl start dnsmasq-setup.service"
fail_case "hostapd fails to start (both tries)" "systemctl start hostapd-setup.service"

new_sandbox
STUB_NOACTIVATE="systemctl start hostapd-setup.service" run_sandboxed "$HOTSPOT"
check "hostapd 'starts' but is not running afterwards: the start fails" eq "$RC" 1
assert_rolled_back "hostapd exits at once"
end_sandbox

new_sandbox
STUB_NOACTIVATE="systemctl start dnsmasq-setup.service" run_sandboxed "$HOTSPOT"
check "dnsmasq 'starts' but is not running afterwards: the start fails" eq "$RC" 1
assert_rolled_back "dnsmasq exits at once"
end_sandbox

new_sandbox
STUB_FAIL="systemctl start nginx.service" run_sandboxed "$HOTSPOT"
check "nginx failing to start is not fatal (the access point still comes up)" eq "$RC" 0
check "... and it is reported" journal_has "Failed to start nginx"
STUB_FAIL="" run_sandboxed "$HOTSPOT" stop
end_sandbox

new_sandbox
STUB_FAIL="nmcli device set wlan0 managed no" run_sandboxed "$HOTSPOT"
check "NetworkManager refusing to release the interface is not fatal (as before)" eq "$RC" 0
run_sandboxed "$HOTSPOT" stop
check "the stop still asks NetworkManager to manage the interface again" has "$SB_LOG" "nmcli device set wlan0 managed yes"
end_sandbox
fi

if want G; then
echo "== G  signals: SIGTERM, SIGINT and SIGHUP end the start cleanly"
signal_case() {  # SIGNAL EXPECTED-RC BLOCK-PATTERN LABEL
    new_sandbox
    STUB_BLOCK="$3" run_sandboxed_bg "$HOTSPOT"
    if ! wait_for_log "$3" 90; then
        t_fail "$4: the script never reached '$3'"
        kill -KILL -- "-$BGPID" 2>/dev/null
        end_sandbox
        return
    fi
    kill -"$1" -- "-$BGPID"
    if wait_for_exit "$BGPID" 90; then
        check "$4: SIG$1 ends the script with status $2" eq "$BGRC" "$2"
    else
        t_fail "$4: the script did not exit after SIG$1"
        kill -KILL -- "-$BGPID" 2>/dev/null
    fi
    assert_rolled_back "$4 (SIG$1)"
    check "$4: the lock is free afterwards" sh -c "PATH='$SB_BIN:/usr/bin:/bin:/usr/sbin:/sbin' bash -c 'exec 9>\"$SB_ROOT/run/setup-device/hotspot.lock\"; flock -n 9'"
    end_sandbox
}
signal_case TERM 143 "systemctl start hostapd-setup.service" "while hostapd is starting"
signal_case INT 130 "systemctl start hostapd-setup.service" "while hostapd is starting"
signal_case HUP 129 "systemctl start hostapd-setup.service" "while hostapd is starting"
signal_case TERM 143 "systemctl start dnsmasq-setup.service" "while dnsmasq is starting (everything else is already up)"
signal_case TERM 143 "ip addr add" "while the AP address is being added"
signal_case TERM 143 "nmcli device disconnect wlan0" "right after NetworkManager released the interface"
signal_case TERM 143 "systemctl start nginx.service" "while nginx is starting"

# SIGTERM to the script alone while it sleeps. Every sleep lasts 30 s here (STUB_SLEEP_SECONDS), so a trap that only runs
# after the sleep returns would take 30 s; handled at once it takes as long as the clean-up (a few stub calls, even on a busy machine).
new_sandbox
STUB_SLEEP_SECONDS=30 run_sandboxed_bg "$HOTSPOT"
if wait_for_log "systemctl start nginx.service" 90; then
    /bin/sleep 1          # now inside the first nap
    kill -TERM "$BGPID"
    started=$(date +%s)
    if wait_for_exit "$BGPID" 90; then
        waited=$(($(date +%s) - started))
        check "SIGTERM during a nap: exit 143" eq "$BGRC" 143
        check "SIGTERM during a nap is handled at once, not after the 30 s sleep (${waited}s)" test "$waited" -lt 20
    else
        t_fail "SIGTERM during a nap: the script did not exit"
        kill -KILL -- "-$BGPID" 2>/dev/null
    fi
    assert_rolled_back "SIGTERM during a nap"
else
    t_fail "SIGTERM during a nap: the script never reached the first nap"
    kill -KILL -- "-$BGPID" 2>/dev/null
fi
end_sandbox
fi

if want H; then
echo "== H  one instance at a time, and an access point that is up is left alone [L6]"
new_sandbox
STUB_BLOCK="systemctl start hostapd-setup.service" run_sandboxed_bg "$HOTSPOT"
if wait_for_log "systemctl start hostapd-setup.service" 90; then
    lines_before="$(grep -vc '^flock ' "$SB_LOG")"      # (the flock stand-in logs; the real flock(1) does not)
    ( unset STUB_BLOCK; run_sandboxed "$HOTSPOT"; echo "$RC" > "$W/second.rc" )
    check "a second start while one is running exits 75" eq "$(cat "$W/second.rc")" 75
    check "... and does not run a single command" eq "$(grep -vc '^flock ' "$SB_LOG")" "$lines_before"
    check "... and says so" journal_has "Another hotspot start or stop is running"
    # stop must WAIT for the running start, then tear it down
    ( unset STUB_BLOCK; PATH="$SB_BIN:/usr/bin:/bin:/usr/sbin:/sbin" bash "$HOTSPOT" stop > "$W/stop.out" 2>&1; echo $? > "$W/stop.rc" ) &
    STOPPID=$!
    /bin/sleep 1
    check "stop is still waiting while the start holds the lock" test ! -e "$W/stop.rc"
    kill -TERM -- "-$BGPID"
    wait_for_exit "$BGPID" 90 || kill -KILL -- "-$BGPID"
    wait "$STOPPID" 2>/dev/null
    check "stop ran once the start had ended, and succeeded" eq "$(cat "$W/stop.rc" 2>/dev/null)" 0
    assert_rolled_back "start interrupted, then stop"
else
    t_fail "the first start never reached hostapd"
    kill -KILL -- "-$BGPID" 2>/dev/null
fi
end_sandbox

new_sandbox
run_sandboxed "$HOTSPOT"
: > "$SB_LOG"
: > "$SB_JOURNAL"
run_sandboxed "$HOTSPOT"
check "a start while the access point is up exits 0" eq "$RC" 0
check "... and changes nothing: no unit is restarted, no address or NetworkManager change" \
    sh -c "! grep -E '^(systemctl (start|stop)|nmcli device|ip )' '$SB_LOG'"
check "... and the journal says why" journal_has "already up"
check "the access point is still up" test -e "$SB_STATE/active/hostapd-setup" -a -e "$SB_STATE/active/dnsmasq-setup"
run_sandboxed "$HOTSPOT" stop
end_sandbox
fi

if want I; then
echo "== I  state left by a crash is repaired by the next start"
new_sandbox
# a previous start was SIGKILLed after it had taken the interface: state, unmanaged marker, address and nginx remain
mkdir -p "$SB_ROOT/run/setup-device" "$SB_STATE/managed" "$SB_STATE/addr" "$SB_STATE/active"
printf 'iface=wlan0\nnginx_started=1\nnm_unmanaged=1\nap_addr=192.168.99.1/24\n' > "$(STATEF)"
: > "$SB_STATE/managed/wlan0"
echo 192.168.99.1/24 > "$SB_STATE/addr/wlan0"
: > "$SB_STATE/active/nginx"
run_sandboxed "$HOTSPOT"
check "the start after a crash succeeds" eq "$RC" 0
check "... and says it undid the earlier episode first" journal_has "Found state from an earlier hotspot episode"
check "... the earlier episode was undone BEFORE the new one began" before "ip addr del 192.168.99.1/24 dev wlan0" "ip addr add 192.168.99.1/24 dev wlan0"
check "... the address is on the interface exactly once" eq "$(count_of "$SB_STATE/addr/wlan0" 192.168.99.1/24)" 1
run_sandboxed "$HOTSPOT" stop
assert_rolled_back "after the repair"
end_sandbox

new_sandbox
# SIGKILL for real: the process cannot clean up; its lock must still be released, and the next start repairs it
STUB_BLOCK="systemctl start hostapd-setup.service" run_sandboxed_bg "$HOTSPOT"
if wait_for_log "systemctl start hostapd-setup.service" 90; then
    { kill -KILL -- "-$BGPID"; wait_for_exit "$BGPID" 60; } 2>/dev/null
    check "SIGKILL leaves the state behind (nothing can run)" test -e "$(STATEF)"
    check "... and the address" test -s "$SB_STATE/addr/wlan0"
    run_sandboxed "$HOTSPOT"
    check "the lock died with the process: the next start is not refused" eq "$RC" 0
    check "... it repaired the earlier episode" journal_has "Found state from an earlier hotspot episode"
    run_sandboxed "$HOTSPOT" stop
    assert_rolled_back "after SIGKILL and a repair"
else
    t_fail "the start never reached hostapd"
    kill -KILL -- "-$BGPID" 2>/dev/null
fi
end_sandbox
fi

if want J; then
echo "== J  usage"
new_sandbox
run_sandboxed "$HOTSPOT" frobnicate
check "an unknown argument is refused (exit 2) and nothing runs" sh -c "[ '$RC' = 2 ] && ! grep -E '^(systemctl|nmcli|ip)' '$SB_LOG'"
end_sandbox
fi

summary
