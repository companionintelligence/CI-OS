#!/bin/bash
# Network connectivity monitor for setup-device
# Automatically starts hotspot if no internet connectivity is detected (wired or wireless)

CHECK_INTERVAL=3   # Check every 3 seconds (aggressive)
FAILURE_THRESHOLD=2  # Start hotspot after 2 failed connectivity checks (~6 seconds)

fail_count=0
hotspot_active=false

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

start_hotspot() {
    if [ "$hotspot_active" = false ]; then
        log "No connectivity detected. Starting hotspot via startup script..."
        if /usr/local/bin/setup-device-hotspot-start.sh >/dev/null 2>&1; then
            log "Hotspot started successfully"
            hotspot_active=true
        else
            log "Failed to start hotspot - will retry"
        fi
    fi
}

stop_hotspot() {
    if [ "$hotspot_active" = true ]; then
        log "Connectivity restored. Stopping hotspot services..."
        systemctl stop hostapd-setup.service 2>/dev/null || true
        systemctl stop dnsmasq-setup.service 2>/dev/null || true
        hotspot_active=false
        fail_count=0
    fi
}

log "Setup network monitor started (checking every ${CHECK_INTERVAL}s, threshold=${FAILURE_THRESHOLD})"

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
        # Connected - reset failure count and stop hotspot if running
        if [ $fail_count -gt 0 ]; then
            log "Connectivity restored after $fail_count failed checks"
            fail_count=0
        fi
        stop_hotspot
    else
        # No connectivity
        fail_count=$((fail_count + 1))
        
        if [ $fail_count -eq 1 ]; then
            log "Lost connectivity (check $fail_count/$FAILURE_THRESHOLD)"
        elif [ $((fail_count % 10)) -eq 0 ]; then
            # Log periodically so we know monitor is still running
            log "Still no connectivity (check $fail_count/$FAILURE_THRESHOLD)"
        fi
        
        # Start hotspot after threshold reached
        if [ $fail_count -ge $FAILURE_THRESHOLD ]; then
            start_hotspot
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
