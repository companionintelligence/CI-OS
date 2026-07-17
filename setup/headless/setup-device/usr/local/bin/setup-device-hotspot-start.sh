#!/bin/bash
# Setup Device - Automatic Hotspot Startup Script
# This script performs all necessary steps to start AP mode
# Called by setup-network-monitor.service when connectivity is lost

set -e

SCAN_CACHE_DIR="/var/lib/setup-device"
SCAN_CACHE_FILE="${SCAN_CACHE_DIR}/last_scan_networks.txt"
WIFI_IFACE="wlp192s0"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-hotspot-start -p info
}

recover_wifi_radio() {
    # AP mode can fail after client/AP transitions if radio is soft-blocked or NM leaves interface in a bad state.
    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on 2>/dev/null || true
    ip link set "${WIFI_IFACE}" up 2>/dev/null || true
}

stop_companion_hub_traefik() {
    # Stop only Traefik reverse proxy to free port 80/443 for captive portal
    # Keep Hub backend running so setup can still communicate with it for device registration
    if command -v docker >/dev/null 2>&1; then
        if docker ps 2>/dev/null | grep -q "traefik" 2>/dev/null; then
            log "Pausing Traefik to free port 80/443 for captive portal (keeping Hub backend running)..."
            docker stop traefik 2>/dev/null || true
            sleep 2  # Give port time to be fully released
            log "Traefik paused - Hub backend still available for device registration"
        fi
    fi
}

start_nginx_captive_portal() {
    # Start nginx to serve captive portal on port 80 (now that Hub is stopped)
    log "Starting nginx for captive portal on port 80..."
    if systemctl start nginx.service; then
        log "✓ Nginx started successfully for captive portal"
    else
        log "Warning: Failed to start nginx - captive portal may not be accessible"
    fi
}

start_hostapd_with_retry() {
    log "Starting hostapd-setup.service..."
    if systemctl start hostapd-setup.service; then
        return 0
    fi

    log "hostapd start failed on first attempt; applying radio recovery and retrying once"
    systemctl stop hostapd-setup.service 2>/dev/null || true
    recover_wifi_radio
    sleep 1

    if systemctl start hostapd-setup.service; then
        return 0
    fi

    return 1
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

# Pause Traefik to free port 80/443 for captive portal (Hub backend stays running)
stop_companion_hub_traefik
sleep 1

# Start nginx to serve captive portal on freed port 80
start_nginx_captive_portal
sleep 1

wait_for_wifi_ready_for_scan() {
    local max_wait=12
    local i=0

    ip link set "${WIFI_IFACE}" up 2>/dev/null || true

    while [ "$i" -lt "$max_wait" ]; do
        # Consider these states scan-ready for nmcli wifi list.
        local state
        state=$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | awk -F: -v iface="${WIFI_IFACE}" '$1==iface && $2=="wifi" {print $3; exit}')

        case "$state" in
            connected|connecting|disconnected)
                return 0
                ;;
        esac

        sleep 1
        i=$((i + 1))
    done

    return 1
}

# Step 2: Validate required runtime config files installed by the package
log "Validating required config files..."
mkdir -p /etc/hostapd /etc/dnsmasq.d

if [ ! -f /etc/hostapd/hostapd-setup.conf ]; then
    if [ -f /usr/share/setup-device/defaults/hostapd-setup.conf ]; then
        cp /usr/share/setup-device/defaults/hostapd-setup.conf /etc/hostapd/hostapd-setup.conf
        chmod 644 /etc/hostapd/hostapd-setup.conf
        log "Restored missing /etc/hostapd/hostapd-setup.conf from defaults"
    else
        log "Error: /etc/hostapd/hostapd-setup.conf is missing"
        exit 1
    fi
fi
if [ ! -f /etc/dnsmasq.d/setup-portal.conf ]; then
    if [ -f /usr/share/setup-device/defaults/setup-portal.conf ]; then
        cp /usr/share/setup-device/defaults/setup-portal.conf /etc/dnsmasq.d/setup-portal.conf
        chmod 644 /etc/dnsmasq.d/setup-portal.conf
        log "Restored missing /etc/dnsmasq.d/setup-portal.conf from defaults"
    else
        log "Error: /etc/dnsmasq.d/setup-portal.conf is missing"
        exit 1
    fi
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

# Step 3: Capture nearby WiFi networks before switching interface into AP mode
mkdir -p "${SCAN_CACHE_DIR}"
log "Capturing pre-AP WiFi scan results for setup dropdown fallback..."
if ! wait_for_wifi_ready_for_scan; then
    log "Warning: WiFi interface did not become scan-ready before timeout; attempting scan anyway"
fi
if nmcli -t -f SSID,SIGNAL,SECURITY device wifi list --rescan yes > "${SCAN_CACHE_FILE}.tmp" 2>/dev/null; then
    mv "${SCAN_CACHE_FILE}.tmp" "${SCAN_CACHE_FILE}"
    chmod 644 "${SCAN_CACHE_FILE}"
    log "Saved pre-AP WiFi scan cache to ${SCAN_CACHE_FILE}"
else
    rm -f "${SCAN_CACHE_FILE}.tmp"
    log "Warning: Could not capture pre-AP WiFi scan results"
fi

# Step 4: Reset WiFi interface (disconnect from any existing connection)
log "Resetting WiFi interface ${WIFI_IFACE}..."
# Commands run as root by systemd service; avoid internal sudo to prevent extra PAM sessions
# Stop any running hostapd/dnsmasq processes from previous attempts
systemctl stop hostapd-setup.service 2>/dev/null || true
systemctl stop dnsmasq-setup.service 2>/dev/null || true
sleep 1

recover_wifi_radio

ip link set "${WIFI_IFACE}" down 2>/dev/null || log "Warning: Could not bring interface down"
sleep 1
ip addr flush dev "${WIFI_IFACE}" 2>/dev/null || log "Warning: Could not flush addresses"
sleep 1
ip link set "${WIFI_IFACE}" up 2>/dev/null || log "Warning: Could not bring interface up"
sleep 2

# Step 5: Assign static IP
log "Assigning static IP 192.168.99.1/24..."
ip addr add 192.168.99.1/24 dev "${WIFI_IFACE}" 2>/dev/null || log "Warning: Could not assign IP (may already exist)"

# Step 6: Start hostapd (with one-shot recovery retry)
if ! start_hostapd_with_retry; then
    log "✗ hostapd-setup.service failed to start after retry"
fi
sleep 2

# Step 7: Start dnsmasq
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

# Verify interface has IP
IP_CHECK=$(ip addr show wlp192s0 | grep "inet 192.168.99" || echo "")
if [ -n "$IP_CHECK" ]; then
    log "✓ Interface wlp192s0 has static IP configured"
else
    log "✗ Warning: Interface may not have correct IP"
fi

log "Hotspot startup sequence complete - Companion-Setup should be broadcasting"
