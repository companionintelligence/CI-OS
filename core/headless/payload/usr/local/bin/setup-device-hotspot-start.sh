#!/bin/bash
# Setup Device - setup hotspot (access point) episode: start it, and undo it.
#
#   setup-device-hotspot-start.sh                    start the access point (the default)
#   setup-device-hotspot-start.sh stop               end the episode: undo what a start changed
#   setup-device-hotspot-start.sh --detect-interface print the Wi-Fi interface a start would use
#
# Called by setup-network-monitor.service when connectivity is lost, by setup_service.py (stop when
# it joins the user's network, start again if that join fails), and by hand through
# setup-hotspot-reset.sh.
#
# An episode changes the machine in a handful of ways, and every one of them is recorded in
# $RUN_DIR/hotspot.state as it happens so `stop` (and the failure trap below) can reverse exactly
# those and nothing else:
#   - nginx is started for the portal                       (stop: stopped again, if THIS script started it)
#   - the Wi-Fi interface is taken from NetworkManager      (stop: `nmcli device set <if> managed yes`)
#   - 192.168.99.1/24 is put on the interface               (stop: removed from it)
#   - hostapd-setup and dnsmasq-setup run                   (stop: stopped)
# Traefik, or any other container, is NOT touched. An earlier version ran `docker stop traefik` to
# free port 80 and never started it again. If something else owns port 80 the portal is not
# reachable on it, this script says so in the journal, and the owner is left running.
#
# Safety properties (tested in core/headless/tests/payload/test_hotspot_start.sh):
#   - one instance at a time (flock on $RUN_DIR/hotspot.lock): the monitor and the backend can both
#     call this, and a second concurrent start exits 75 without touching anything
#   - a start that fails part-way, or is interrupted by SIGTERM/SIGINT/SIGHUP, undoes what it did
#     before it exits; a start that succeeds leaves the access point up (that is its job)
#   - a start while the access point is already up changes nothing (it does not kick the clients)
#   - state left by a start that could not clean up (SIGKILL, power loss while /run survives) is
#     undone before the next start
#   - every file it writes is root-only unless it says otherwise (umask 077): the hostapd config holds
#     the passphrase, the dnsmasq log holds the DNS queries of every phone that joined
#
# Exit status of a start: 0 the access point is up, 1 it failed and was rolled back, 3 no Wi-Fi
# interface can run an access point (nothing was changed: no retry will help until hardware
# changes), 75 another instance holds the lock.
#
# Test hook: SETUP_DEVICE_ROOT prefixes every path (it is unset on a device).

set -e
export LC_ALL=C
umask 077

ROOT="${SETUP_DEVICE_ROOT:-}"
DATA_DIR="$ROOT/var/lib/setup-device"
RUN_DIR="$ROOT/run/setup-device"
STATE_FILE="$RUN_DIR/hotspot.state"
LOCK_FILE="$RUN_DIR/hotspot.lock"
SSID_SUFFIX_FILE="$DATA_DIR/ssid-suffix"
HOSTAPD_CONF="$ROOT/etc/hostapd/hostapd-setup.conf"
DNSMASQ_CONF="$ROOT/etc/dnsmasq.d/setup-portal.conf"
DNSMASQ_LOG="$ROOT/var/log/dnsmasq-setup.log"
PRESCAN="$ROOT/usr/local/bin/setup-device-prescan.py"
COUNTRY_FILE="$ROOT/etc/setup-device/regdom"
CMDLINE_FILE="$ROOT/proc/cmdline"
AP_IP="192.168.99.1"
AP_ADDR="$AP_IP/24"

WIFI_IFACE=""
COUNTRY=""
AP_UP=0
NAP_PID=""

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-hotspot-start -p "${2:-info}"
}

# Sleep that a signal interrupts at once. A plain `sleep` runs in the foreground, and bash defers a
# trap until it returns; waiting on a background sleep lets the trap run immediately.
nap() {
    sleep "$1" &
    NAP_PID=$!
    wait "$NAP_PID" 2>/dev/null || true
    NAP_PID=""
}

# A directory this script has to create must be traversable by the services that read what is put in it
# (the umask is 077). Existing directories are left as they are.
ensure_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
        chmod 755 "$1"
    fi
}

# --- state ---------------------------------------------------------------------------------------------------------------
# One KEY=VALUE per line, replaced in place and written before the change it records, so a failure
# half-way through a step is still undone.
state_set() {
    local tmp="$STATE_FILE.$$"
    mkdir -p "$RUN_DIR"
    { [ -f "$STATE_FILE" ] && grep -v "^$1=" "$STATE_FILE" || true; echo "$1=$2"; } > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

state_get() {
    [ -f "$STATE_FILE" ] || return 0
    sed -n "s/^$1=//p" "$STATE_FILE" | tail -n 1
}

# The only characters a Linux interface name can sensibly hold here; anything else read back from
# a state or config file is not trusted into a command line.
valid_iface() {
    case "$1" in
        ''|*[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    [ "${#1}" -le 15 ]
}

# --- Wi-Fi interface selection --------------------------------------------------------------------------------------------
# Candidates: what NetworkManager calls Wi-Fi, then what `iw` and sysfs list; each once, in that order.
wifi_candidates() {
    {
        if command -v nmcli >/dev/null 2>&1; then
            nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" { print $1 }'
        fi
        if command -v iw >/dev/null 2>&1; then
            iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }'
        fi
        for f in "$ROOT"/sys/class/net/*/phy80211; do
            [ -e "$f" ] && basename "$(dirname "$f")"
        done
    } | awk 'NF && !seen[$1]++ { print $1 }'
}

iface_phy() {  # IFACE -> phyN
    iw dev 2>/dev/null | awk -v want="$1" '
        /^phy#/ { phy = "phy" substr($1, 5) }
        $1 == "Interface" && $2 == want { print phy; exit }'
}

# 0: the interface can run an access point; 1: it cannot; 2: cannot tell (no iw, or iw does not know it)
iface_supports_ap() {
    local phy info
    command -v iw >/dev/null 2>&1 || return 2
    phy="$(iface_phy "$1")"
    [ -n "$phy" ] || return 2
    info="$(iw phy "$phy" info 2>/dev/null)" || return 2
    [ -n "$info" ] || return 2
    # "Supported interface modes:" is followed by one "* mode" bullet per mode; "AP" is the one needed.
    printf '%s\n' "$info" | awk '
        /Supported interface modes:/ { f = 1; next }
        f && $1 == "*" { if ($2 == "AP") ok = 1; next }
        f { exit }
        END { exit ok ? 0 : 1 }'
}

# Prints the interface to use. Returns 0 with an interface, 3 with a message on stderr when there is none.
pick_ap_interface() {
    local c rc unverified="" seen=0
    while IFS= read -r c; do
        valid_iface "$c" || continue
        seen=1
        rc=0
        iface_supports_ap "$c" || rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "$c"
            return 0
        fi
        if [ "$rc" -eq 2 ] && [ -z "$unverified" ]; then
            unverified="$c"
        fi
    done < <(wifi_candidates)
    if [ -n "$unverified" ]; then
        # No iw (or no answer from it): the old behaviour, first Wi-Fi interface, and a note about it.
        echo "WARNING: cannot verify that $unverified supports AP mode (iw missing or silent); using it" >&2
        echo "$unverified"
        return 0
    fi
    if [ "$seen" -eq 1 ]; then
        echo "no Wi-Fi interface supports AP mode (iw lists no 'AP' under Supported interface modes)" >&2
    else
        echo "no Wi-Fi interface found" >&2
    fi
    return 3
}

# --- regulatory country ------------------------------------------------------------------------------------------------------
# A usable country is two capital letters. The kernel's placeholders - 00 (the world domain), 98 and 99 (a domain it built
# itself) - are digits, so they are not countries without any special case.
valid_country() {
    case "$1" in
        [A-Z][A-Z]) return 0 ;;
    esac
    return 1
}

# A country code is exactly two letters (any case). Anything else - "DEU", "1A", a sentence - is not one, and is
# ignored rather than truncated into a different country.
norm_country() {
    local v
    v="$(printf '%s' "$1" | tr -d ' \t\r\n')"
    case "$v" in
        [A-Za-z][A-Za-z]) printf '%s' "$v" | tr 'a-z' 'A-Z' ;;
    esac
}

# Prints the country to put in the hostapd config, or nothing when it is not known. Order: an explicit
# override (environment, /etc/setup-device/regdom, "ci.country=XX" on the kernel command line), then the
# domain the kernel currently has (`iw reg get`, "global" section). Never a made-up default: with no
# country the config sets none, the kernel's world regulatory domain applies, and the channel below stays
# within 1-11, which every domain allows.
detect_country() {
    local c=""
    c="$(norm_country "${SETUP_DEVICE_COUNTRY:-}")"
    if ! valid_country "$c" && [ -r "$COUNTRY_FILE" ]; then
        c="$(norm_country "$(head -n 1 "$COUNTRY_FILE" 2>/dev/null)")"
    fi
    if ! valid_country "$c" && [ -r "$CMDLINE_FILE" ]; then
        c="$(norm_country "$(tr ' ' '\n' < "$CMDLINE_FILE" | sed -n 's/^ci\.country=//p' | head -n 1)")"
    fi
    if ! valid_country "$c" && command -v iw >/dev/null 2>&1; then
        c="$(iw reg get 2>/dev/null | awk '
            /^global/ { g = 1; next }
            /^phy#/ { g = 0 }
            g && $1 == "country" { c = $2; sub(/:.*/, "", c); print c; exit }')"
    fi
    if valid_country "$c"; then
        echo "$c"
    fi
    return 0
}

# --- helpers of a start -----------------------------------------------------------------------------------------------------------
# Detect-only run for tools (reset helper, tests): print the interface and stop.
detect_interface_only() {
    local iface
    iface="$(pick_ap_interface)" || exit 3
    echo "$iface"
    exit 0
}

recover_wifi_radio() {
    # AP mode can fail after client/AP transitions if radio is soft-blocked or NM leaves interface in a bad state.
    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on 2>/dev/null || true
    ip link set "${WIFI_IFACE}" up 2>/dev/null || true
}

# Generate 4-char alphanumeric suffix for SSID
generate_ssid_suffix() {
    local s
    # Bounded input: `tr -dc ... < /dev/urandom | head -c 4` reads for ever when the pipe cannot signal tr (SIGPIPE ignored
    # by whatever started this script, and a tr that does not stop on a write error).
    s=$(head -c 512 /dev/urandom 2>/dev/null | tr -dc 'A-Z0-9' | head -c 4)
    [ -n "$s" ] && echo "$s" && return
    # Fallback: last 4 chars of machine-id or random from $$
    s=$(tr -dc 'A-Za-z0-9' < "$ROOT/etc/machine-id" 2>/dev/null | tail -c 4)
    [ -n "$s" ] && echo "$s" && return
    printf "%04X" $((RANDOM % 65536))
}

start_nginx_captive_portal() {
    # nginx serves the portal on port 80. Remember whether THIS script started it: only then does the
    # end of the episode stop it (nginx may be running for another reason).
    if ! systemctl is-active --quiet nginx.service 2>/dev/null; then
        state_set nginx_started 1
    fi
    log "Starting nginx for captive portal on port 80..."
    if systemctl start nginx.service; then
        log "Nginx started successfully for captive portal"
    else
        log "Warning: Failed to start nginx - captive portal may not be accessible" warning
    fi
    # Something else (a container publishing port 80, for instance) may own the port. It is not ours
    # to stop; say who has it so the missing portal is explained.
    if command -v ss >/dev/null 2>&1; then
        local holder
        holder="$(ss -H -ltnp 'sport = :80' 2>/dev/null | grep -v nginx | head -n 1 || true)"
        if [ -n "$holder" ]; then
            log "WARNING: port 80 is also held by another process, so the captive portal may be unreachable on it. Not stopping it: $holder" warning
        fi
    fi
}

start_hostapd_with_retry() {
    log "Starting hostapd-setup.service..."
    if systemctl start hostapd-setup.service; then
        return 0
    fi

    log "hostapd start failed on first attempt; applying radio recovery and retrying once" warning
    systemctl stop hostapd-setup.service 2>/dev/null || true
    recover_wifi_radio
    nap 1

    if systemctl start hostapd-setup.service; then
        return 0
    fi

    return 1
}

render_hostapd_conf() {
    local country_lines=""
    if [ -n "$COUNTRY" ]; then
        country_lines="country_code=$COUNTRY
ieee80211d=1"
    fi
    ensure_dir "$(dirname "$HOSTAPD_CONF")"
    cat > "$HOSTAPD_CONF" << EOF
# HostAPD configuration for setup mode hotspot (generated at runtime)
interface=$WIFI_IFACE
driver=nl80211

# SSID - Companion Device Setup (dynamic suffix per boot)
ssid=$SSID

# WPA2-PSK only
wpa=2
wpa_passphrase=SetupDevice123
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP

# 2.4 GHz (optimal for compatibility and range). Channel 6 is legal in every regulatory domain;
# the world domain (no country_code below) allows channels 1-11.
hw_mode=g
channel=6

max_num_sta=10
# Clients of the setup network can reach the device, not each other.
ap_isolate=1

# Regulatory country: only when it is known (override file, kernel command line or the kernel's
# current domain). Nothing is assumed.
$country_lines

ieee80211n=1
ht_capab=[SHORT-GI-20]
ieee80211ax=0

# Disable WPS for security
wps_state=0

logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
EOF
    chmod 600 "$HOSTAPD_CONF"
}

render_dnsmasq_conf() {
    ensure_dir "$(dirname "$DNSMASQ_CONF")"
    ensure_dir "$(dirname "$DNSMASQ_LOG")"
    # The query log names every site every phone on the setup network looks up: root-only, like the rest.
    : >> "$DNSMASQ_LOG"
    chmod 600 "$DNSMASQ_LOG"
    cat > "$DNSMASQ_CONF" << EOF
# DNSmasq configuration for setup portal (generated at runtime)
interface=$WIFI_IFACE
bind-interfaces

dhcp-range=192.168.99.10,192.168.99.250,255.255.255.0,12h
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
dhcp-option=option:dns-server,$AP_IP

no-resolv
no-poll

address=/setup.ci.computer/$AP_IP
address=/captive.apple.com/$AP_IP
address=/gstatic.com/$AP_IP
address=/www.msftconnecttest.com/$AP_IP
address=/connectivitycheck.gstatic.com/$AP_IP
address=/connectivitycheck.android.com/$AP_IP
address=/clients3.google.com/$AP_IP
address=/www.google.com/$AP_IP
address=/detectportal.firefox.com/$AP_IP
address=/#/$AP_IP

log-queries
log-facility=$DNSMASQ_LOG
EOF
    chmod 644 "$DNSMASQ_CONF"
}

# --- teardown: the reverse of a start --------------------------------------------------------------------------------------------
# Idempotent and never fails: it runs from the failure trap and from the backend, possibly twice.
teardown() {
    local iface
    iface="$(state_get iface)"
    if ! valid_iface "$iface" && [ -r "$HOSTAPD_CONF" ]; then
        # An access point from before this script kept state: the interface it ran on is in its config.
        iface="$(sed -n 's/^interface=//p' "$HOSTAPD_CONF" | head -n 1)"
    fi
    log "Ending the hotspot episode (interface: ${iface:-unknown})"

    systemctl stop dnsmasq-setup.service 2>/dev/null || true
    systemctl stop hostapd-setup.service 2>/dev/null || true
    # A unit that failed its way through the start limit stays refused until this; the next episode must be able to start.
    systemctl reset-failed hostapd-setup.service dnsmasq-setup.service 2>/dev/null || true
    if [ "$(state_get nginx_started)" = 1 ]; then
        systemctl stop nginx.service 2>/dev/null || true
    fi

    if valid_iface "$iface"; then
        # Only the address this script added; whatever NetworkManager configures afterwards stays.
        ip addr del "$AP_ADDR" dev "$iface" 2>/dev/null || true
        if [ "$(state_get nm_unmanaged)" = 1 ] && command -v nmcli >/dev/null 2>&1; then
            nmcli device set "$iface" managed yes 2>/dev/null || log "Warning: could not hand $iface back to NetworkManager" warning
        fi
    fi
    rm -f "$STATE_FILE"
}

on_exit() {
    local rc=$?
    trap - EXIT
    if [ -n "$NAP_PID" ]; then
        kill "$NAP_PID" 2>/dev/null || true
    fi
    if [ "$AP_UP" != 1 ] && [ "$MODE" = start ] && [ "$LOCKED" = 1 ]; then
        log "Hotspot start did not complete (exit $rc); undoing what it changed" warning
        teardown || true
    fi
    exit "$rc"
}

# --- main ------------------------------------------------------------------------------------------------------------------------
MODE=start
LOCKED=0
case "${1:-}" in
    ''|start) ;;
    stop) MODE=stop ;;
    --detect-interface) detect_interface_only ;;
    *)
        echo "usage: ${0##*/} [start|stop|--detect-interface]" >&2
        exit 2
        ;;
esac

mkdir -p "$RUN_DIR"
# fd 9 holds the lock for the life of this process; the kernel drops it when the process dies, however it dies.
exec 9> "$LOCK_FILE"
if [ "$MODE" = stop ]; then
    # A teardown waits for a start in progress instead of tearing the radio down underneath it.
    flock 9
    teardown
    exit 0
fi
if ! flock -n 9; then
    log "Another hotspot start or stop is running; not starting a second one" warning
    exit 75
fi
LOCKED=1

trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

log "Starting hotspot setup sequence..."

# An access point that is already up is left alone: starting again would drop every connected phone.
if [ -f "$STATE_FILE" ] && systemctl is-active --quiet hostapd-setup.service 2>/dev/null \
    && systemctl is-active --quiet dnsmasq-setup.service 2>/dev/null; then
    log "Hotspot is already up; nothing to do"
    AP_UP=1
    exit 0
fi
# State left by an episode that never cleaned up after itself (SIGKILL, a crash): undo it first.
if [ -f "$STATE_FILE" ]; then
    log "Found state from an earlier hotspot episode; undoing it first" warning
    teardown
fi

# Step 1: Pick an interface that can run an access point (nothing has been changed yet)
if ! WIFI_IFACE="$(pick_ap_interface 2> "$RUN_DIR/pick.err")"; then
    log "ERROR: $(cat "$RUN_DIR/pick.err" 2>/dev/null)" err
    rm -f "$RUN_DIR/pick.err"
    exit 3
fi
if [ -s "$RUN_DIR/pick.err" ]; then
    log "$(cat "$RUN_DIR/pick.err")" warning
fi
rm -f "$RUN_DIR/pick.err"
log "Detected WiFi interface: $WIFI_IFACE"
state_set iface "$WIFI_IFACE"

# Step 2: nginx for the portal. Traefik and every other container are left alone.
start_nginx_captive_portal
nap 1

# Step 3: Unblock WiFi (rfkill)
if command -v rfkill &>/dev/null; then
    rfkill unblock wifi 2>/dev/null || true
    nap 1
fi

# Step 4: Generate SSID suffix for this boot and persist for portal
ensure_dir "$DATA_DIR"
SSID_SUFFIX=$(generate_ssid_suffix)
[ -z "$SSID_SUFFIX" ] && SSID_SUFFIX="SETUP"
echo -n "$SSID_SUFFIX" > "$SSID_SUFFIX_FILE"
chmod 644 "$SSID_SUFFIX_FILE"   # the backend serves it to the portal
SSID="Companion-Setup-$SSID_SUFFIX"
log "Generated SSID: $SSID"

# Step 5: Stop any running hostapd/dnsmasq from previous attempts
systemctl stop hostapd-setup.service 2>/dev/null || true
systemctl stop dnsmasq-setup.service 2>/dev/null || true
systemctl reset-failed hostapd-setup.service dnsmasq-setup.service 2>/dev/null || true
nap 1

# Step 5b: Tell NetworkManager to release the WiFi interface (prevents NM/wpa_supplicant from conflicting with hostapd)
if command -v nmcli &>/dev/null; then
    log "Unmanaging WiFi interface from NetworkManager..."
    state_set nm_unmanaged 1
    nmcli device set "$WIFI_IFACE" managed no 2>/dev/null || log "Warning: Could not unmanage interface (may be ok)" warning
    nmcli device disconnect "$WIFI_IFACE" 2>/dev/null || true
    nap 1
fi
recover_wifi_radio

# Step 6: Reset WiFi interface (disconnect from any existing connection)
log "Resetting WiFi interface $WIFI_IFACE..."
ip link set "$WIFI_IFACE" down 2>/dev/null || log "Warning: Could not bring interface down" warning
nap 1
ip addr flush dev "$WIFI_IFACE" 2>/dev/null || log "Warning: Could not flush addresses" warning
nap 1
ip link set "$WIFI_IFACE" up 2>/dev/null || log "Warning: Could not bring interface up" warning
nap 3

# Step 6b: Pre-scan for networks (BEFORE starting AP - single-radio chips cannot scan in AP mode)
# MediaTek MT7921, etc.: scan must happen while interface is up but not yet in master/AP mode
log "Pre-scanning for WiFi networks (interface in station mode)..."
if [ -x "$PRESCAN" ]; then
    if "$PRESCAN" "$WIFI_IFACE" 2>/dev/null; then
        log "Pre-scan complete - networks saved for portal"
    else
        log "Pre-scan failed or no networks - portal will offer manual entry"
    fi
else
    log "Pre-scan script not found - portal will offer manual entry only"
fi

# Step 7: Render the configs. After the pre-scan on purpose: scanning is how the kernel learns the
# neighbourhood's regulatory domain (802.11d), so `iw reg get` can answer now where it could not before.
COUNTRY="$(detect_country)"
if [ -n "$COUNTRY" ]; then
    log "Regulatory country: $COUNTRY"
else
    log "Regulatory country unknown; the world domain applies (channel 6, 2.4 GHz)"
fi
render_hostapd_conf
render_dnsmasq_conf

# Step 8: Assign static IP (AP mode - no netplan for WiFi, we manage manually)
log "Assigning static IP $AP_ADDR..."
state_set ap_addr "$AP_ADDR"
ip addr add "$AP_ADDR" dev "$WIFI_IFACE" 2>/dev/null || log "Warning: Could not assign IP (may already exist)" warning

# Step 9: Start hostapd (with one-shot recovery retry). A failure ends the start (and the trap undoes it).
if ! start_hostapd_with_retry; then
    log "hostapd-setup.service failed to start after retry" err
    journalctl -u hostapd-setup.service -n 10 --no-pager 2>/dev/null | systemd-cat -t setup-hotspot-start -p warning || true
    exit 1
fi
nap 2

# Step 10: Start dnsmasq
log "Starting dnsmasq-setup.service..."
systemctl start dnsmasq-setup.service
nap 1

# Verify services started
if ! systemctl is-active --quiet hostapd-setup.service; then
    log "hostapd-setup.service is not running - checking logs" err
    journalctl -u hostapd-setup.service -n 10 --no-pager 2>/dev/null | systemd-cat -t setup-hotspot-start -p warning || true
    exit 1
fi
log "hostapd-setup.service started successfully"

if ! systemctl is-active --quiet dnsmasq-setup.service; then
    log "dnsmasq-setup.service is not running - checking logs" err
    journalctl -u dnsmasq-setup.service -n 5 --no-pager 2>/dev/null | systemd-cat -t setup-hotspot-start -p warning || true
    exit 1
fi
log "dnsmasq-setup.service started successfully"

# Wait briefly for hostapd to stabilize and broadcast SSID
nap 3
log "Hotspot setup complete - $SSID network should be available"

# Verify interface has IP
IP_CHECK=$(ip addr show "$WIFI_IFACE" 2>/dev/null | grep "inet 192.168.99" || true)
if [ -n "$IP_CHECK" ]; then
    log "Interface $WIFI_IFACE has static IP configured"
else
    log "Warning: Interface may not have correct IP" warning
fi

AP_UP=1
log "Hotspot startup sequence complete - $SSID should be broadcasting"
