#!/usr/bin/env bash
#=============================================================================
# CI-OS Headless Setup Status
#=============================================================================

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
    DATA_DIR="${CI_OS_DATA_DIR:-/var/lib/ci-os}"
else
    DATA_DIR="${CI_OS_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ci-os}"
fi
STATUS_JSON="$DATA_DIR/headless-status.json"
mkdir -p "$DATA_DIR"

service_state() {
    local service="$1"
    if command -v systemctl >/dev/null 2>&1; then
        local state
        state="$(systemctl is-active "$service" 2>/dev/null || true)"
        echo "${state:-unknown}"
    else
        echo "systemctl-missing"
    fi
}

service_enabled() {
    local service="$1"
    if command -v systemctl >/dev/null 2>&1; then
        local state
        state="$(systemctl is-enabled "$service" 2>/dev/null || true)"
        echo "${state:-unknown}"
    else
        echo "systemctl-missing"
    fi
}

wifi_interfaces() {
    if command -v nmcli >/dev/null 2>&1; then
        nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" {print $1}' | paste -sd, -
    else
        find /sys/class/net -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | grep -E '^(wl|wlan)' | paste -sd, - || true
    fi
}

default_route() {
    ip route 2>/dev/null | awk '/^default/ {print; exit}' || true
}

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    printf '%s' "$value"
}

write_json() {
    local created_at
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$STATUS_JSON" <<EOF
{
  "created_at": "$created_at",
  "wifi_interfaces": "$(json_escape "$(wifi_interfaces)")",
  "default_route": "$(json_escape "$(default_route)")",
  "portal_url": "http://setup.ci.computer",
  "gateway": "192.168.99.1",
  "services": {
    "setup-backend.service": {"active": "$(service_state setup-backend.service)", "enabled": "$(service_enabled setup-backend.service)"},
    "setup-network-monitor.service": {"active": "$(service_state setup-network-monitor.service)", "enabled": "$(service_enabled setup-network-monitor.service)"},
    "hostapd-setup.service": {"active": "$(service_state hostapd-setup.service)", "enabled": "$(service_enabled hostapd-setup.service)"},
    "dnsmasq-setup.service": {"active": "$(service_state dnsmasq-setup.service)", "enabled": "$(service_enabled dnsmasq-setup.service)"},
    "nginx.service": {"active": "$(service_state nginx.service)", "enabled": "$(service_enabled nginx.service)"}
  }
}
EOF
}

write_json

if [[ "${1:-}" == "--json" ]]; then
    cat "$STATUS_JSON"
    exit 0
fi

echo "Headless setup status written to $STATUS_JSON"
echo "WiFi interfaces: $(wifi_interfaces)"
echo "Default route: $(default_route)"
echo "Portal: http://setup.ci.computer or http://192.168.99.1"
echo
printf '%-34s %-14s %s\n' "Service" "Active" "Enabled"
for service in setup-backend.service setup-network-monitor.service hostapd-setup.service dnsmasq-setup.service nginx.service; do
    printf '%-34s %-14s %s\n' "$service" "$(service_state "$service")" "$(service_enabled "$service")"
done
