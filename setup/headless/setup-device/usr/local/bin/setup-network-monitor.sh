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
    # Check for default route and attempt a lightweight external reachability test
    if ip route | grep -q "^default"; then
        # Try pinging a public IP (no DNS dependency)
        if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
            return 0
        fi

        # If ping fails, consult NetworkManager state as a fallback
        if systemctl is-active --quiet NetworkManager; then
            local nm_state
            nm_state=$(nmcli -t -f STATE general 2>/dev/null || echo "unknown")
            if [ "$nm_state" = "connected" ] || [ "$nm_state" = "connecting" ]; then
                return 0
            fi
            # Also consider any device explicitly marked 'connected'
            if nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q ':connected$'; then
                return 0
            fi
        fi
    fi

    # If there is a local global IPv4 address but no default route, treat as no connectivity
    if ip -4 addr show scope global | grep -q 'inet '; then
        return 1
    fi

    return 1
}

start_hotspot() {
    if [ "$hotspot_active" = false ]; then
        log "No connectivity detected. Starting hotspot via startup script..."
        /usr/local/bin/setup-device-hotspot-start.sh
        hotspot_active=true
    fi
}

stop_hotspot() {
    if [ "$hotspot_active" = true ]; then
        log "Connectivity restored. Stopping hotspot services..."
        systemctl stop hostapd-setup.service dnsmasq-setup.service 2>/dev/null
        hotspot_active=false
        fail_count=0
    fi
}

log "Setup network monitor started"

# Main monitoring loop
while true; do
    # Check connectivity
    if check_connectivity; then
        # Connected - reset failure count and stop hotspot if running
        if [ $fail_count -gt 0 ]; then
            log "Connectivity restored ($fail_count failed checks before recovery)"
            fail_count=0
        fi
        stop_hotspot
    else
        # No connectivity
        fail_count=$((fail_count + 1))
        
        if [ $fail_count -eq 1 ]; then
            log "Lost connectivity (check $fail_count/$FAILURE_THRESHOLD)"
        fi
        
        # Start hotspot after threshold reached
        if [ $fail_count -ge $FAILURE_THRESHOLD ]; then
            start_hotspot
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
