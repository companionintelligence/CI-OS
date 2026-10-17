#!/bin/bash
# Network connectivity monitor for setup-device
# Automatically starts hotspot if no internet connectivity is detected (wired or wireless)
#
# This file can be sourced (the tests do): the monitoring loop only runs when it is executed.

# nmcli translates its state names ("connected" -> "verbunden"); everything below matches the English ones.
export LC_ALL=C

CHECK_INTERVAL=3   # Check every 3 seconds (aggressive)
FAILURE_THRESHOLD=2  # Start hotspot after 2 failed connectivity checks (~6 seconds)
BOOT_DISCOVERY_GRACE_SECONDS=45  # Allow boot-time WiFi discovery/auto-connect before AP fallback
SCAN_READY_MIN_SSIDS=1
START_BACKOFF_SEC=45  # After failed start, wait 45s before retrying (avoids constant restart loop)
# Exit status 3 of the start script means no Wi-Fi interface can run an access point. A retry every
# 45 s would only repeat the same refusal, so the next try is this much later (a dongle may be plugged in).
NO_AP_RADIO_BACKOFF_SEC=600
HOTSPOT_START_SCRIPT="${SETUP_DEVICE_HOTSPOT_START:-/usr/local/bin/setup-device-hotspot-start.sh}"

fail_count=0
hotspot_active=false
boot_started_at=$(date +%s)
last_start_fail_time=0
start_backoff_sec=$START_BACKOFF_SEC

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-network-monitor -p info
}

check_connectivity() {
    # Check for INTERNET connectivity, not just any connection
    # A device may have connections (Docker, loopback, etc) but no internet
    
    # Primary: Does the device have a default route to the internet?
    if ip route | grep -q "^default"; then
        # Has default route - check if it actually works
        # Try pinging 8.8.8.8 (Google DNS)
        if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
            return 0  # Has internet connectivity via ping
        fi
        
        # Ping failed - check if there's an actual route to external network
        # Extract gateway from default route
        local gateway
        gateway=$(ip route | grep "^default" | awk '{print $3}' | head -1)
        if [ -n "$gateway" ]; then
            # Try to ping the gateway itself
            if ping -c1 -W1 "$gateway" >/dev/null 2>&1; then
                return 0  # Can reach gateway, likely has internet
            fi
        fi
    fi
    
    # No internet connectivity detected
    return 1
}

nm_is_connecting_or_initializing() {
    local state
    state=$(nmcli -t -f STATE general 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]')
    case "$state" in
        connecting*|asleep|unknown|*)
            # unknown/empty values are treated as still-initializing during boot grace.
            [[ -z "$state" ]] && return 0
            [[ "$state" == connecting* || "$state" == asleep || "$state" == unknown ]] && return 0
            return 1
            ;;
    esac
}

wifi_scan_ready() {
    local count
    count=$(nmcli -t -f SSID device wifi list --rescan auto 2>/dev/null | sed '/^\s*$/d' | wc -l)
    [[ "$count" -ge "$SCAN_READY_MIN_SSIDS" ]]
}

# `nmcli -t -f TYPE,STATE device status` prints the device state as one of (nmcli, src/nmcli/common.c,
# C locale): unmanaged, unavailable, disconnected, connecting (prepare), connecting (configuring),
# connecting (need authentication), connecting (getting IP configuration), connecting (checking IP
# connectivity), connecting (starting secondary connections), connected, connected (externally),
# connecting (externally), deactivating, deactivating (externally), connection failed.
# A Wi-Fi link that is up or being brought up is "connected" or "connecting", with an optional "(...)".
# The old pattern listed config/ip-config/ip-check/need-auth, which are NM_DEVICE_STATE enum names and
# never nmcli output, and anchored the words bare, so only a plain "connected" matched and the
# "connecting (getting IP configuration)" a slow DHCP shows did not.
wifi_state_is_active_or_connecting() {
    grep -Eq '^(connected|connecting)( \(.*\))?$'
}

wifi_link_active_or_connecting() {
    local states
    states=$(nmcli -t -f TYPE,STATE device status 2>/dev/null | awk -F: '$1=="wifi" {print tolower($2)}')
    if [[ -z "$states" ]]; then
        return 1
    fi

    if echo "$states" | wifi_state_is_active_or_connecting; then
        return 0
    fi

    return 1
}

# setup-backend touches this while it has stopped the hotspot to join WiFi (see
# CONFIGURING_FLAG in setup_service.py). Ignore it once stale, in case the backend died.
CONFIGURING_FLAG=/run/setup-device/configuring
CONFIGURING_MAX_AGE_SECONDS=300

setup_backend_configuring() {
    [ -f "$CONFIGURING_FLAG" ] || return 1
    local age
    age=$(( $(date +%s) - $(stat -c %Y "$CONFIGURING_FLAG" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$CONFIGURING_MAX_AGE_SECONDS" ]
}

should_delay_hotspot_during_boot() {
    local now elapsed
    now=$(date +%s)
    elapsed=$((now - boot_started_at))

    if [[ "$elapsed" -ge "$BOOT_DISCOVERY_GRACE_SECONDS" ]]; then
        return 1
    fi

    # If NM is still connecting/initializing or scan list is not ready, wait.
    if nm_is_connecting_or_initializing; then
        return 0
    fi

    if ! wifi_scan_ready; then
        return 0
    fi

    return 1
}

start_hotspot() {
    if [ "$hotspot_active" = true ]; then
        # setup-backend stops the hotspot itself when it joins WiFi. If that join
        # then fails, the services are down while this flag still says active --
        # resync, or the device is left with neither WiFi nor a setup hotspot.
        if systemctl is-active --quiet hostapd-setup.service 2>/dev/null; then
            return 0
        fi
        log "Hotspot services are down (stopped by setup-backend); clearing state"
        hotspot_active=false
    fi
    # Sync state: if services are already running externally, we're good (avoids restart loop)
    if systemctl is-active --quiet hostapd-setup.service 2>/dev/null && systemctl is-active --quiet dnsmasq-setup.service 2>/dev/null; then
        log "Hostapd/dnsmasq already active - syncing state"
        hotspot_active=true
        return 0
    fi
    # Backoff: avoid retrying immediately after failure (prevents constant restart loop)
    local now
    now=$(date +%s)
    if [ $last_start_fail_time -gt 0 ]; then
        local since_fail=$((now - last_start_fail_time))
        if [ $since_fail -lt "$start_backoff_sec" ]; then
            return 1  # Still in backoff, skip
        fi
    fi
    log "No connectivity detected. Starting hotspot via startup script..."
    local rc=0
    "$HOTSPOT_START_SCRIPT" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log "Hotspot started (stays on until successful setup or error)"
        hotspot_active=true
        last_start_fail_time=0
        start_backoff_sec=$START_BACKOFF_SEC
    elif [ "$rc" -eq 3 ]; then
        # No interface can run an access point. The script changed nothing; asking again in 45 s would
        # only log the same refusal, so back off for much longer.
        last_start_fail_time=$(date +%s)
        start_backoff_sec=$NO_AP_RADIO_BACKOFF_SEC
        log "No Wi-Fi interface can run an access point; not retrying for ${NO_AP_RADIO_BACKOFF_SEC}s"
    else
        last_start_fail_time=$(date +%s)
        start_backoff_sec=$START_BACKOFF_SEC
        log "Failed to start hotspot (exit $rc) - will retry in ${START_BACKOFF_SEC}s"
    fi
}

# stop_hotspot removed - monitor NEVER stops the hotspot; only /api/configure does on success

# The monitoring loop. Wrapped in a function so the file can be sourced without starting it.
main() {
    log "Setup network monitor started (checking every ${CHECK_INTERVAL}s, threshold=${FAILURE_THRESHOLD})"

    # Initialize hotspot state from current service status.
    if systemctl is-active --quiet hostapd-setup.service && systemctl is-active --quiet dnsmasq-setup.service; then
        hotspot_active=true
        log "Detected active hotspot services at startup"
    fi

    # Initial connectivity check
    if check_connectivity; then
        log "Initial check: Internet connectivity detected - hotspot will start if connectivity is lost"
    else
        log "Initial check: No connectivity detected - will start hotspot after threshold"
    fi

    # Main monitoring loop
    while true; do
        # Check connectivity
        if check_connectivity; then
            fail_count=0
            # NEVER stop the hotspot - user needs time to fill form and hit Configure
        else
            # Once a WiFi link is connected (or still negotiating), do not force AP fallback
            # on temporary internet probe failures; this prevents setup from tearing down
            # a valid station connection.
            if wifi_link_active_or_connecting; then
                if [ $fail_count -gt 0 ]; then
                    log "WiFi link active/connecting; suppressing hotspot fallback"
                fi
                fail_count=0
                sleep $CHECK_INTERVAL
                continue
            fi

            if setup_backend_configuring; then
                # setup-backend is between stopping the hotspot and bringing WiFi up.
                fail_count=0
                sleep $CHECK_INTERVAL
                continue
            fi

            if should_delay_hotspot_during_boot; then
                fail_count=0
                if [ $(( ($(date +%s) - boot_started_at) % 10 )) -lt "$CHECK_INTERVAL" ]; then
                    log "Boot grace: waiting for WiFi discovery/auto-connect before AP fallback"
                fi
                sleep $CHECK_INTERVAL
                continue
            fi

            # No connectivity - increment failure count
            fail_count=$((fail_count + 1))

            if [ $fail_count -eq 1 ]; then
                log "Lost connectivity (check $fail_count/$FAILURE_THRESHOLD)"
            elif [ $((fail_count % 10)) -eq 0 ]; then
                log "Still no connectivity (check $fail_count/$FAILURE_THRESHOLD)"
            fi

            # Start hotspot after threshold reached (backoff handled inside start_hotspot)
            if [ $fail_count -ge $FAILURE_THRESHOLD ]; then
                if start_hotspot; then
                    :  # Success or already running
                else
                    # Failed or in backoff - don't reset fail_count so we retry after backoff
                    :
                fi
            fi
        fi
    
        sleep $CHECK_INTERVAL
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
