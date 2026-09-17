#!/bin/bash
# Network connectivity monitor for setup-device
# Automatically starts hotspot if no internet connectivity is detected (wired or wireless)

CHECK_INTERVAL=3   # Check every 3 seconds (aggressive)
FAILURE_THRESHOLD=2  # Start hotspot after 2 failed connectivity checks (~6 seconds)
BOOT_DISCOVERY_GRACE_SECONDS=45  # Allow boot-time WiFi discovery/auto-connect before AP fallback
SCAN_READY_MIN_SSIDS=1
START_BACKOFF_SEC=45  # After failed start, wait 45s before retrying (avoids constant restart loop)

fail_count=0
hotspot_active=false
boot_started_at=$(date +%s)
last_start_fail_time=0

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
        local gateway=$(ip route | grep "^default" | awk '{print $3}' | head -1)
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

wifi_link_active_or_connecting() {
    local states
    states=$(nmcli -t -f TYPE,STATE device status 2>/dev/null | awk -F: '$1=="wifi" {print tolower($2)}')
    if [[ -z "$states" ]]; then
        return 1
    fi

    if echo "$states" | grep -Eq '(^|\n)(connected|connecting|config|ip-config|ip-check|need-auth)($|\n)'; then
        return 0
    fi

    return 1
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
        return 0
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
        if [ $since_fail -lt $START_BACKOFF_SEC ]; then
            return 1  # Still in backoff, skip
        fi
    fi
    log "No connectivity detected. Starting hotspot via startup script..."
    if /usr/local/bin/setup-device-hotspot-start.sh >/dev/null 2>&1; then
        log "Hotspot started (stays on until successful setup or error)"
        hotspot_active=true
        last_start_fail_time=0
    else
        last_start_fail_time=$(date +%s)
        log "Failed to start hotspot - will retry in ${START_BACKOFF_SEC}s"
    fi
}

# stop_hotspot removed - monitor NEVER stops the hotspot; only /api/configure does on success

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
