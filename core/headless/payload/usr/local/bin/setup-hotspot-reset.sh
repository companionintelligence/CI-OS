#!/bin/bash
# Setup Device - Hotspot reset helper
# Flushes transient WiFi/AP state and restarts setup services.

set -euo pipefail

WIFI_IFACE="${1:-wlp192s0}"
FLUSH_SETUP_PROFILES="${FLUSH_SETUP_PROFILES:-0}"

log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" | systemd-cat -t setup-hotspot-reset -p info
}

warn() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1"
    echo "$msg"
    echo "$msg" | systemd-cat -t setup-hotspot-reset -p warning
}

flush_setup_profiles() {
    # Keep this conservative: only delete setup/AP related connection names.
    local names
    names=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="wifi" {print $1}' | grep -E '^(Companion-Setup|Setup-Portal|setup-portal|Hotspot)$' || true)

    if [[ -z "$names" ]]; then
        log "No setup WiFi profiles to delete"
        return 0
    fi

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        log "Deleting stale setup profile: $name"
        nmcli connection delete "$name" >/dev/null 2>&1 || warn "Failed deleting profile $name"
    done <<< "$names"
}

log "Starting hotspot reset on interface $WIFI_IFACE"

log "Stopping setup monitor/AP services"
systemctl stop setup-network-monitor.service hostapd-setup.service dnsmasq-setup.service || true

log "Disconnecting interface from any active WiFi connection"
nmcli device disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true

if [[ "$FLUSH_SETUP_PROFILES" == "1" ]]; then
    log "FLUSH_SETUP_PROFILES=1; removing setup AP profiles"
    flush_setup_profiles
fi

log "Flushing IP addresses and routes on $WIFI_IFACE"
ip addr flush dev "$WIFI_IFACE" >/dev/null 2>&1 || true
ip route flush dev "$WIFI_IFACE" >/dev/null 2>&1 || true

log "Resetting radio and interface state"
rfkill unblock wifi >/dev/null 2>&1 || true
nmcli radio wifi on >/dev/null 2>&1 || true
ip link set "$WIFI_IFACE" down >/dev/null 2>&1 || true
ip link set "$WIFI_IFACE" up >/dev/null 2>&1 || true

log "Restarting NetworkManager"
systemctl restart NetworkManager

log "Restarting setup services"
systemctl restart setup-backend.service
systemctl restart setup-network-monitor.service

if [[ -x /usr/local/bin/setup-device-hotspot-start.sh ]]; then
    log "Forcing hotspot startup script once"
    /usr/local/bin/setup-device-hotspot-start.sh || warn "Hotspot startup script returned non-zero"
else
    warn "/usr/local/bin/setup-device-hotspot-start.sh not found; skipping forced start"
fi

log "Current service states"
systemctl --no-pager --full status hostapd-setup.service dnsmasq-setup.service setup-network-monitor.service | sed -n '1,120p'

log "Recent AP logs"
journalctl --no-pager -u hostapd-setup.service -u dnsmasq-setup.service -n 40 || true

log "Hotspot reset complete"
