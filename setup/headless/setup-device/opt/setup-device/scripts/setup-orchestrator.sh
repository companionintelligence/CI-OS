#!/usr/bin/env bash
# Setup Orchestrator - runs after Configure Device when AP is kept open
# Keeps AP running, starts CI OS Hub, waits for registration, then closes AP and connects WiFi
# Called by setup_service.py as a background process

set -e
LOG_TAG="setup-orchestrator"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t "$LOG_TAG" -p info
}

CREDENTIALS_JSON="${1:-/var/lib/setup-device/credentials.json}"
PULL_DEV_SCRIPT="${2:-/opt/setup-device/scripts/pull-dev.sh}"
HUB_STATUS_URL="http://127.0.0.1:5002/api/registration/status"
HUB_READY_TIMEOUT=300   # 5 min to pull and start
REG_POLL_INTERVAL=5     # Poll every 5 sec
REG_POLL_TIMEOUT=600    # 10 min max wait for registration

log "Starting setup orchestrator (AP stays open during Hub registration)"

# Read WiFi credentials (avoid jq dependency - use Python)
read_creds() {
    python3 - "$CREDENTIALS_JSON" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('ssid', ''))
    print(d.get('password', ''))
except Exception:
    print('')
    print('')
PY
}
cred_out=$(read_creds)
SSID=$(echo "$cred_out" | head -1)
PASSWORD=$(echo "$cred_out" | tail -1)

if [ -z "$SSID" ]; then
    log "ERROR: No SSID in credentials file $CREDENTIALS_JSON"
    exit 1
fi

# Run pull-dev.sh (as root, HOME=/root)
log "Running pull-dev.sh to start CI OS Hub..."
if [ -f "$PULL_DEV_SCRIPT" ]; then
    if HOME=/root bash "$PULL_DEV_SCRIPT"; then
        log "pull-dev.sh completed successfully"
    else
        log "ERROR: pull-dev.sh failed"
        exit 1
    fi
else
    log "ERROR: pull-dev.sh not found at $PULL_DEV_SCRIPT"
    exit 1
fi

# Wait for Hub to be ready
log "Waiting for CI OS Hub to be ready..."
elapsed=0
while [ $elapsed -lt $HUB_READY_TIMEOUT ]; do
    if curl -sf "$HUB_STATUS_URL" >/dev/null 2>&1; then
        log "CI OS Hub is ready"
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done
if [ $elapsed -ge $HUB_READY_TIMEOUT ]; then
    log "WARNING: Hub not ready after ${HUB_READY_TIMEOUT}s, proceeding anyway"
fi

# Poll for login page loaded (user completed registration and was redirected to /login)
# The Hub login page calls /api/setup/login-seen when it mounts, which creates this file
LOGIN_SEEN_FILE="/var/lib/setup-device/login-page-seen"
log "Waiting for user to reach login page (registration -> /register -> /login)..."
elapsed=0
while [ $elapsed -lt $REG_POLL_TIMEOUT ]; do
    if [ -f "$LOGIN_SEEN_FILE" ]; then
        log "Login page loaded - registration complete, closing AP"
        break
    fi
    sleep $REG_POLL_INTERVAL
    elapsed=$((elapsed + REG_POLL_INTERVAL))
done
if [ $elapsed -ge $REG_POLL_TIMEOUT ]; then
    log "WARNING: Login page not seen - closing AP anyway"
fi

# Only NOW do we stop the AP and connect to user's WiFi (AP was alive the whole time)
log "Stopping hotspot and connecting to WiFi..."
systemctl stop hostapd-setup.service 2>/dev/null || true
systemctl stop dnsmasq-setup.service 2>/dev/null || true

# Remove netplan static config
if [ -f /etc/netplan/50-setup-mode.yaml ]; then
    rm -f /etc/netplan/50-setup-mode.yaml
    netplan apply 2>/dev/null || true
fi

sleep 2
log "Connecting to WiFi: $SSID"
nmcli connection up "$SSID" 2>/dev/null || log "WiFi connect may need retry"

# Write setup-complete and remove flags
mkdir -p /var/lib/setup-device
touch /var/lib/setup-device/setup-complete
rm -f /var/lib/setup-device/keep-ap-during-registration
rm -f /var/lib/setup-device/login-page-seen
log "Setup complete. AP closed, device on WiFi."
