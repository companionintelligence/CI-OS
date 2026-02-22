#!/bin/bash
# Setup Device - Automatic Hotspot Startup Script
# This script performs all necessary steps to start AP mode
# Called by setup-network-monitor.service when connectivity is lost
#
# Uses dynamic WiFi interface detection and per-boot SSID (Companion-Setup-XXXX)

set -e

DATA_DIR="/var/lib/setup-device"
SSID_SUFFIX_FILE="$DATA_DIR/ssid-suffix"
HOSTAPD_CONF="/etc/hostapd/hostapd-setup.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/setup-portal.conf"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-hotspot-start -p info
}

# Detect WiFi interface (wlan0, wlp2s0, wlp192s0, etc.)
get_wifi_interface() {
    if command -v nmcli &>/dev/null; then
        local iface
        iface=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | while IFS=: read -r dev type; do
            [ "$type" = "wifi" ] && echo "$dev" && break
        done)
        [ -n "$iface" ] && echo "$iface" && return
    fi
    if command -v iw &>/dev/null; then
        iw dev 2>/dev/null | awk '/Interface/ {print $2}' | head -1
        return
    fi
    # Fallback: first phy that supports AP
    for f in /sys/class/net/*/phy80211; do
        [ -e "$f" ] && basename "$(dirname "$f")" && return
    done
    echo "wlan0"
}

# Generate 4-char alphanumeric suffix for SSID
generate_ssid_suffix() {
    local s
    s=$(tr -dc 'A-Z0-9' < /dev/urandom 2>/dev/null | head -c 4)
    [ -n "$s" ] && echo "$s" && return
    # Fallback: last 4 chars of machine-id or random from $$
    s=$(cat /etc/machine-id 2>/dev/null | tr -dc 'A-Za-z0-9' | tail -c 4)
    [ -n "$s" ] && echo "$s" && return
    printf "%04X" $((RANDOM % 65536))
}

log "Starting hotspot setup sequence..."

# Step 1: Detect WiFi interface
WIFI_IFACE=$(get_wifi_interface)
log "Detected WiFi interface: $WIFI_IFACE"
if [ -z "$WIFI_IFACE" ]; then
    log "ERROR: No WiFi interface found"
    exit 1
fi

# Step 2: Unblock WiFi (rfkill)
if command -v rfkill &>/dev/null; then
    rfkill unblock wifi 2>/dev/null || true
    sleep 1
fi

# Step 3: Generate SSID suffix for this boot and persist for portal
mkdir -p "$DATA_DIR"
SSID_SUFFIX=$(generate_ssid_suffix)
[ -z "$SSID_SUFFIX" ] && SSID_SUFFIX="SETUP"
echo -n "$SSID_SUFFIX" > "$SSID_SUFFIX_FILE"
SSID="Companion-Setup-$SSID_SUFFIX"
log "Generated SSID: $SSID"

# Step 4: Generate hostapd config with dynamic interface and SSID
mkdir -p /etc/hostapd
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
wpa_pairwise=TKIP CCMP
rsn_pairwise=CCMP

# 2.4 GHz (optimal for compatibility and range)
hw_mode=g
channel=6

max_num_sta=10
country_code=US

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

# Step 5: Generate dnsmasq config with dynamic interface
mkdir -p /etc/dnsmasq.d
cat > "$DNSMASQ_CONF" << EOF
# DNSmasq configuration for setup portal (generated at runtime)
interface=$WIFI_IFACE
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
address=/connectivitycheck.android.com/192.168.99.1
address=/clients3.google.com/192.168.99.1
address=/www.google.com/192.168.99.1
address=/detectportal.firefox.com/192.168.99.1
address=/#/192.168.99.1

log-queries
log-facility=/var/log/dnsmasq-setup.log
EOF

# Step 6: Stop any running hostapd/dnsmasq from previous attempts
systemctl stop hostapd-setup.service 2>/dev/null || true
systemctl stop dnsmasq-setup.service 2>/dev/null || true
sleep 1

# Step 6b: Tell NetworkManager to release the WiFi interface (prevents NM/wpa_supplicant from conflicting with hostapd)
if command -v nmcli &>/dev/null; then
    log "Unmanaging WiFi interface from NetworkManager..."
    nmcli device set "$WIFI_IFACE" managed no 2>/dev/null || log "Warning: Could not unmanage interface (may be ok)"
    nmcli device disconnect "$WIFI_IFACE" 2>/dev/null || true
    sleep 1
fi

# Step 7: Reset WiFi interface (disconnect from any existing connection)
log "Resetting WiFi interface $WIFI_IFACE..."
ip link set "$WIFI_IFACE" down 2>/dev/null || log "Warning: Could not bring interface down"
sleep 1
ip addr flush dev "$WIFI_IFACE" 2>/dev/null || log "Warning: Could not flush addresses"
sleep 1
ip link set "$WIFI_IFACE" up 2>/dev/null || log "Warning: Could not bring interface up"
sleep 3

# Step 7b: Pre-scan for networks (BEFORE starting AP - single-radio chips cannot scan in AP mode)
# MediaTek MT7921, etc.: scan must happen while interface is up but not yet in master/AP mode
log "Pre-scanning for WiFi networks (interface in station mode)..."
if [ -x /usr/local/bin/setup-device-prescan.py ]; then
    if /usr/local/bin/setup-device-prescan.py "$WIFI_IFACE" 2>/dev/null; then
        log "Pre-scan complete - networks saved for portal"
    else
        log "Pre-scan failed or no networks - portal will offer manual entry"
    fi
else
    log "Pre-scan script not found - portal will offer manual entry only"
fi

# Step 8: Assign static IP (AP mode - no netplan for WiFi, we manage manually)
log "Assigning static IP 192.168.99.1/24..."
ip addr add 192.168.99.1/24 dev "$WIFI_IFACE" 2>/dev/null || log "Warning: Could not assign IP (may already exist)"

# Step 9: Start hostapd
log "Starting hostapd-setup.service..."
systemctl start hostapd-setup.service
sleep 2

# Step 10: Start dnsmasq
log "Starting dnsmasq-setup.service..."
systemctl start dnsmasq-setup.service
sleep 1

# Verify services started
if systemctl is-active --quiet hostapd-setup.service; then
    log "hostapd-setup.service started successfully"
else
    log "hostapd-setup.service failed to start - checking logs"
    journalctl -u hostapd-setup.service -n 10 --no-pager | systemd-cat -t setup-hotspot-start -p warning
fi

if systemctl is-active --quiet dnsmasq-setup.service; then
    log "dnsmasq-setup.service started successfully"
else
    log "dnsmasq-setup.service failed to start - checking logs"
    journalctl -u dnsmasq-setup.service -n 5 --no-pager | systemd-cat -t setup-hotspot-start -p warning
fi

# Wait briefly for hostapd to stabilize and broadcast SSID
sleep 3
log "Hotspot setup complete - $SSID network should be available"

# Verify interface has IP
IP_CHECK=$(ip addr show "$WIFI_IFACE" 2>/dev/null | grep "inet 192.168.99" || true)
if [ -n "$IP_CHECK" ]; then
    log "Interface $WIFI_IFACE has static IP configured"
else
    log "Warning: Interface may not have correct IP"
fi

log "Hotspot startup sequence complete - $SSID should be broadcasting"
