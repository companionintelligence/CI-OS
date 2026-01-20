#!/bin/bash
# Setup Device - Automatic Hotspot Startup Script
# This script performs all necessary steps to start AP mode
# Called by setup-network-monitor.service when connectivity is lost

set -e

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-hotspot-start -p info
}

log "Starting hotspot setup sequence..."

# Check if setup is complete
if [ -f /var/lib/setup-device/setup-complete ]; then
    log "Setup already complete. Exiting."
    exit 0
fi

# Step 1: Copy config files (ensure they're present)
log "Ensuring config files are in place..."
mkdir -p /etc/hostapd /etc/dnsmasq.d
cp -f /home/companion/devel/companion/CI-OS/setup/headless/setup-device/etc/hostapd/hostapd-setup.conf /etc/hostapd/ 2>/dev/null || log "Warning: Could not copy hostapd config"
cp -f /home/companion/devel/companion/CI-OS/setup/headless/setup-device/etc/dnsmasq.d/setup-portal.conf /etc/dnsmasq.d/ 2>/dev/null || log "Warning: Could not copy dnsmasq config"

# Step 2: Reset WiFi interface (disconnect from any existing connection)
log "Resetting WiFi interface wlp192s0..."
sudo ip link set wlp192s0 down 2>/dev/null || log "Warning: Could not bring interface down"
sleep 1
sudo ip addr flush dev wlp192s0 2>/dev/null || log "Warning: Could not flush addresses"
sleep 1
sudo ip link set wlp192s0 up 2>/dev/null || log "Warning: Could not bring interface up"
sleep 1

# Step 3: Assign static IP
log "Assigning static IP 192.168.99.1/24..."
sudo ip addr add 192.168.99.1/24 dev wlp192s0 2>/dev/null || log "Warning: Could not assign IP (may already exist)"

# Step 4: Start hostapd
log "Starting hostapd-setup.service..."
systemctl start hostapd-setup.service
sleep 2

# Step 5: Start dnsmasq
log "Starting dnsmasq-setup.service..."
systemctl start dnsmasq-setup.service
sleep 1

# Verify services started
if systemctl is-active --quiet hostapd-setup.service; then
    log "✓ hostapd-setup.service started successfully"
else
    log "✗ hostapd-setup.service failed to start - checking logs"
    journalctl -u hostapd-setup.service -n 5 | systemd-cat -t setup-hotspot-start -p warning
fi

if systemctl is-active --quiet dnsmasq-setup.service; then
    log "✓ dnsmasq-setup.service started successfully"
else
    log "✗ dnsmasq-setup.service failed to start - checking logs"
    journalctl -u dnsmasq-setup.service -n 5 | systemd-cat -t setup-hotspot-start -p warning
fi

# Verify interface has IP
IP_CHECK=$(ip addr show wlp192s0 | grep "inet 192.168.99" || echo "")
if [ -n "$IP_CHECK" ]; then
    log "✓ Interface wlp192s0 has static IP configured"
else
    log "✗ Warning: Interface may not have correct IP"
fi

log "Hotspot startup sequence complete - Companion-Setup should be broadcasting"
