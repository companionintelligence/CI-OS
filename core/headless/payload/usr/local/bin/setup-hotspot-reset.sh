#!/bin/bash
# Setup Device - Hotspot reset helper
# Flushes transient WiFi/AP state and restarts setup services.

set -euo pipefail

HOTSPOT_START_SCRIPT="${SETUP_DEVICE_HOTSPOT_START:-/usr/local/bin/setup-device-hotspot-start.sh}"
FLUSH_SETUP_PROFILES="${FLUSH_SETUP_PROFILES:-0}"
WIFI_IFACE="${1:-}"

log() {
    local msg
    msg="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" | systemd-cat -t setup-hotspot-reset -p info
}

warn() {
    local msg
    msg="[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1"
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

if [[ -z "$WIFI_IFACE" ]]; then
    # No interface given: the one the hotspot would use (an AP-capable Wi-Fi interface), not a board-specific name.
    if ! WIFI_IFACE="$("$HOTSPOT_START_SCRIPT" --detect-interface 2>/dev/null)" || [[ -z "$WIFI_IFACE" ]]; then
        warn "No Wi-Fi interface that can run an access point was found; pass the interface name as the first argument"
        exit 3
    fi
fi

log "Starting hotspot reset on interface $WIFI_IFACE"

log "Stopping setup monitor/AP services"
systemctl stop setup-network-monitor.service hostapd-setup.service dnsmasq-setup.service || true
# Undo what the last hotspot start changed (AP address, NetworkManager's hold on the interface, nginx).
if [[ -x "$HOTSPOT_START_SCRIPT" ]]; then
    "$HOTSPOT_START_SCRIPT" stop || warn "Hotspot teardown returned non-zero"
fi

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

if [[ -x "$HOTSPOT_START_SCRIPT" ]]; then
    log "Forcing hotspot startup script once"
    "$HOTSPOT_START_SCRIPT" || warn "Hotspot startup script returned non-zero"
else
    warn "$HOTSPOT_START_SCRIPT not found; skipping forced start"
fi

log "Current service states"
systemctl --no-pager --full status hostapd-setup.service dnsmasq-setup.service setup-network-monitor.service | sed -n '1,120p'

log "Recent AP logs"
journalctl --no-pager -u hostapd-setup.service -u dnsmasq-setup.service -n 40 || true

log "Hotspot reset complete"
