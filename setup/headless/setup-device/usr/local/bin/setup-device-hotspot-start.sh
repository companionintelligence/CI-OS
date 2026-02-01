#!/bin/bash
# Setup Device - Automatic Hotspot Startup Script
# This script performs all necessary steps to start AP mode
# Called by setup-network-monitor.service when connectivity is lost

set -e

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-hotspot-start -p info
}

log "Starting hotspot setup sequence..."

# Step 1: Ensure config directories exist and detect WiFi interface
log "Ensuring config directories and detecting WiFi interface..."
mkdir -p /etc/hostapd /etc/dnsmasq.d /var/lib/setup-device 2>/dev/null || true

# Detect wireless interface (prefer 'iw dev', fallback to /sys/class/net patterns)
WIFI_IFACE=""
if command -v iw >/dev/null 2>&1; then
    WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}' || true)
fi
if [ -z "$WIFI_IFACE" ]; then
    WIFI_IFACE=$(ls /sys/class/net 2>/dev/null | grep -E '^wl|^wlan' | head -n1 || true)
fi
if [ -z "$WIFI_IFACE" ]; then
    WIFI_IFACE="wlp192s0"
fi
log "Using WiFi interface: ${WIFI_IFACE}"

# If hostapd config missing, create a reasonable default
if [ ! -f /etc/hostapd/hostapd-setup.conf ]; then
    log "No /etc/hostapd/hostapd-setup.conf found - creating default config"
    cat > /etc/hostapd/hostapd-setup.conf <<'EOF'
interface=wlp192s0
driver=nl80211
ssid=Companion-Setup
wpa=2
wpa_passphrase=SetupDevice123
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP CCMP
rsn_pairwise=CCMP
hw_mode=g
channel=6
max_num_sta=10
country_code=US
ieee80211n=1
ht_capab=[SHORT-GI-20]
wps_state=0
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
EOF
    chmod 644 /etc/hostapd/hostapd-setup.conf 2>/dev/null || true
fi

# If dnsmasq config missing, create a default
if [ ! -f /etc/dnsmasq.d/setup-portal.conf ]; then
    log "No /etc/dnsmasq.d/setup-portal.conf found - creating default config"
    cat > /etc/dnsmasq.d/setup-portal.conf <<'EOF'
interface=wlp192s0
bind-interfaces
dhcp-range=192.168.99.10,192.168.99.250,255.255.255.0,12h
dhcp-option=3,192.168.99.1
dhcp-option=6,192.168.99.1
dhcp-option=option:dns-server,192.168.99.1
no-resolv
no-poll
address=/setup.ci.computer/192.168.99.1
address=/captive.apple.com/192.168.99.1
address=/gstatic.com/192.168.99.1
address=/www.msftconnecttest.com/192.168.99.1
address=/connectivitycheck.gstatic.com/192.168.99.1
address=/clients3.google.com/192.168.99.1
address=/www.google.com/192.168.99.1
address=/#/192.168.99.1
log-queries
log-facility=/var/log/dnsmasq-setup.log
EOF
    chmod 644 /etc/dnsmasq.d/setup-portal.conf 2>/dev/null || true
fi

# Generate a random 4-letter uppercase suffix and update SSID to avoid collisions
if [ -f /etc/hostapd/hostapd-setup.conf ]; then
    # Always use base SSID without any existing suffix (in case script runs multiple times)
    BASE_SSID="Companion-Setup"
    # Generate exactly 4 uppercase letters
    SUFFIX=$(tr -dc 'A-Z' </dev/urandom | head -c4 2>/dev/null || echo "XXXX")
    NEW_SSID="${BASE_SSID}-${SUFFIX}"
    log "Setting hotspot SSID to ${NEW_SSID}"
    if grep -q '^ssid=' /etc/hostapd/hostapd-setup.conf; then
        sed -i "s/^ssid=.*/ssid=${NEW_SSID}/" /etc/hostapd/hostapd-setup.conf || true
    else
        echo "ssid=${NEW_SSID}" >> /etc/hostapd/hostapd-setup.conf || true
    fi
    echo "${SUFFIX}" > /var/lib/setup-device/hotspot-suffix 2>/dev/null || true
fi

# Step 2: Reset WiFi interface (disconnect from any existing connection)
log "Resetting WiFi interface ${WIFI_IFACE}..."
# Commands run as root by systemd service; avoid internal sudo to prevent extra PAM sessions
# Stop any running hostapd/dnsmasq processes from previous attempts
systemctl stop hostapd-setup.service 2>/dev/null || true
systemctl stop dnsmasq-setup.service 2>/dev/null || true
sleep 1

ip link set "${WIFI_IFACE}" down 2>/dev/null || log "Warning: Could not bring interface down"
sleep 1
ip addr flush dev "${WIFI_IFACE}" 2>/dev/null || log "Warning: Could not flush addresses"
sleep 1
ip link set "${WIFI_IFACE}" up 2>/dev/null || log "Warning: Could not bring interface up"
sleep 2

# Step 3: Assign static IP
log "Assigning static IP 192.168.99.1/24..."
ip addr add 192.168.99.1/24 dev "${WIFI_IFACE}" 2>/dev/null || log "Warning: Could not assign IP (may already exist)"

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
    journalctl -u hostapd-setup.service -n 10 --no-pager | systemd-cat -t setup-hotspot-start -p warning
fi

if systemctl is-active --quiet dnsmasq-setup.service; then
    log "✓ dnsmasq-setup.service started successfully"
else
    log "✗ dnsmasq-setup.service failed to start - checking logs"
    journalctl -u dnsmasq-setup.service -n 5 --no-pager | systemd-cat -t setup-hotspot-start -p warning
fi

# Wait briefly for hostapd to stabilize and broadcast SSID
sleep 3
log "Hotspot setup complete - Companion-Setup network should be available"

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
