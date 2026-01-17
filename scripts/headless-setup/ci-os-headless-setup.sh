#!/bin/bash
# CI OS Headless Setup Daemon
# Manages first-time WiFi setup via captive portal
set -euo pipefail

# Configuration
SETUP_FLAG="/var/lib/ci-os/setup-complete"
HOTSPOT_SSID="CI-OS-Setup"
HOTSPOT_INTERFACE="wlan0"
HOTSPOT_IP="10.42.0.1"
WEB_SERVER_PORT="80"
SETUP_DIR="/usr/local/share/ci-os-headless-setup"
LOG_FILE="/var/log/ci-os-headless-setup.log"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Check if setup is already complete
check_setup_complete() {
    if [ -f "$SETUP_FLAG" ]; then
        log "Setup already completed. Exiting."
        return 0
    fi
    return 1
}

# Check if WiFi is already configured
check_wifi_configured() {
    # Check if any WiFi connection exists in NetworkManager
    if nmcli -t -f TYPE,STATE connection show | grep -q "802-11-wireless:activated"; then
        log "WiFi already configured and connected"
        return 0
    fi
    
    # Check if there are saved WiFi connections
    if nmcli -t -f TYPE connection show | grep -q "802-11-wireless"; then
        log "WiFi connections exist but not connected"
        return 0
    fi
    
    return 1
}

# Create hotspot using NetworkManager
create_hotspot() {
    log "Creating WiFi hotspot: $HOTSPOT_SSID"
    
    # Remove existing hotspot connection if it exists
    nmcli connection delete "$HOTSPOT_SSID" 2>/dev/null || true
    
    # Create new hotspot connection
    nmcli connection add type wifi ifname "$HOTSPOT_INTERFACE" \
        con-name "$HOTSPOT_SSID" \
        autoconnect yes \
        ssid "$HOTSPOT_SSID" \
        mode ap \
        ipv4.method shared \
        ipv4.addresses "$HOTSPOT_IP/24"
    
    # Activate the hotspot
    nmcli connection up "$HOTSPOT_SSID"
    
    log "Hotspot created and activated: $HOTSPOT_SSID"
}

# Start the captive portal web server
start_web_server() {
    log "Starting captive portal web server on port $WEB_SERVER_PORT"
    
    # Kill any existing web server
    pkill -f "ci-os-captive-portal" || true
    
    # Start the Python Flask web server
    python3 "$SETUP_DIR/web/captive-portal.py" >> "$LOG_FILE" 2>&1 &
    
    log "Web server started (PID: $!)"
}

# Setup DNS hijacking for captive portal detection
setup_dns_hijacking() {
    log "Setting up DNS hijacking for captive portal"
    
    # Create dnsmasq configuration for captive portal
    cat > /etc/dnsmasq.d/ci-os-captive-portal.conf <<EOF
# CI OS Captive Portal DNS Configuration
interface=$HOTSPOT_INTERFACE
bind-interfaces
dhcp-range=10.42.0.10,10.42.0.100,12h
address=/#/$HOTSPOT_IP
EOF
    
    # Restart dnsmasq
    systemctl restart dnsmasq || systemctl start dnsmasq
    
    log "DNS hijacking configured"
}

# Setup iptables rules for captive portal
setup_iptables() {
    log "Setting up iptables rules for captive portal"
    
    # Flush existing rules for the captive portal
    iptables -t nat -F PREROUTING 2>/dev/null || true
    
    # Redirect all HTTP traffic to our web server
    iptables -t nat -A PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 80 -j DNAT --to-destination "$HOTSPOT_IP:$WEB_SERVER_PORT"
    iptables -t nat -A PREROUTING -i "$HOTSPOT_INTERFACE" -p tcp --dport 443 -j DNAT --to-destination "$HOTSPOT_IP:$WEB_SERVER_PORT"
    
    log "iptables rules configured"
}

# Cleanup hotspot and restore normal networking
cleanup_hotspot() {
    log "Cleaning up hotspot configuration"
    
    # Stop web server
    pkill -f "ci-os-captive-portal" || true
    
    # Remove iptables rules
    iptables -t nat -F PREROUTING 2>/dev/null || true
    
    # Remove dnsmasq configuration
    rm -f /etc/dnsmasq.d/ci-os-captive-portal.conf
    systemctl restart dnsmasq || true
    
    # Deactivate and delete hotspot connection
    nmcli connection down "$HOTSPOT_SSID" 2>/dev/null || true
    nmcli connection delete "$HOTSPOT_SSID" 2>/dev/null || true
    
    log "Hotspot cleanup completed"
}

# Main function
main() {
    log "=== CI OS Headless Setup Started ==="
    
    # Check if setup is already complete
    if check_setup_complete; then
        exit 0
    fi
    
    # Check if WiFi is already configured
    if check_wifi_configured; then
        log "WiFi already configured, marking setup as complete"
        mkdir -p "$(dirname "$SETUP_FLAG")"
        touch "$SETUP_FLAG"
        exit 0
    fi
    
    # Ensure setup directory exists
    mkdir -p "$SETUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Create hotspot
    create_hotspot
    
    # Setup DNS hijacking
    setup_dns_hijacking
    
    # Setup iptables rules
    setup_iptables
    
    # Start web server
    start_web_server
    
    log "=== CI OS Headless Setup running - waiting for configuration ==="
    
    # Wait for setup completion signal
    while [ ! -f "$SETUP_FLAG" ]; do
        sleep 5
    done
    
    log "Setup complete flag detected, cleaning up"
    cleanup_hotspot
    
    log "=== CI OS Headless Setup Completed ==="
}

# Handle signals
trap cleanup_hotspot EXIT INT TERM

# Run main function
main
