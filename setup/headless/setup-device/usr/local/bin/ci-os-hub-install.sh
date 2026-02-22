#!/bin/bash
# CI OS Hub Install - Ensures Hub is present and started with API_KEY and DEVICE_ID
# Called by ci-os-hub-start.sh after portal verification. Sources hub.env, runs pull-dev
# (if available) or merges hub.env into existing install and starts Docker.
# The API key validates Hub connection to portal.companionintelligence.com.
#
# © Companion Intelligence — Lifescope Inc

set -euo pipefail

HUB_ENV="/var/lib/setup-device/hub.env"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t ci-os-hub-install -p info 2>/dev/null || true
}

[ ! -f "$HUB_ENV" ] && { log "hub.env not found"; exit 0; }

# Source hub.env and export for child processes (pull-dev uses these)
set -a
# shellcheck source=/dev/null
. "$HUB_ENV"
set +a

# Override CI Cloud URLs to portal.companionintelligence.com (setup.companionintelligence.com does not resolve)
BASE_URL="${CI_CLOUD_API_URL:-https://portal.companionintelligence.com}"
BASE_URL="${BASE_URL%/api}"
BASE_URL="${BASE_URL%/}"
export CI_CLOUD_URL="${CI_CLOUD_URL:-${BASE_URL}}"
export CI_CLOUD_API_URL="${CI_CLOUD_API_URL:-${BASE_URL}/api}"
export CI_CLOUD_FRONTEND_URL="${CI_CLOUD_FRONTEND_URL:-${BASE_URL}}"
export CI_CLOUD_API_KEY="${CI_CLOUD_API_KEY:-$API_KEY}"
export DEVICE_ID="${DEVICE_ID}"

if ! command -v docker >/dev/null 2>&1; then
    log "Docker not installed; cannot install Hub"
    exit 0
fi

# Try pull-dev from repo if available
PULL_DEV=""
for d in /opt/ci-os "${CI_OS_REPO:-}" "$HOME/CI-OS"; do
    p="$d/pull-dev.sh"
    if [ -f "$p" ] && [ -x "$p" ]; then
        PULL_DEV="$p"
        break
    fi
done

if [ -n "$PULL_DEV" ]; then
    log "Running pull-dev: $PULL_DEV"
    if bash "$PULL_DEV" 2>/dev/null; then
        log "Hub installed via pull-dev"
        exit 0
    fi
    log "pull-dev had issues; trying fallback"
fi

# Fallback: merge hub.env into existing Hub install and start
for HUB_DIR in /opt/ci-os-hub /root/ci-os-hub-staging "$HOME/ci-os-hub-staging"; do
    if [ -d "$HUB_DIR" ] && [ -f "$HUB_DIR/docker-compose.yml" ]; then
        log "Merging hub.env into $HUB_DIR and starting"
        # Remove our keys from .env, then append hub.env (preserves other vars)
        { grep -v '^DEVICE_ID=\|^API_KEY=\|^CI_CLOUD_API_KEY=\|^CI_CLOUD_API_URL=\|^CI_ZONE_ID=' "$HUB_DIR/.env" 2>/dev/null || true
          grep -v '^#\|^$' "$HUB_ENV"
        } > "$HUB_DIR/.env.merged"
        mv "$HUB_DIR/.env.merged" "$HUB_DIR/.env"
        (cd "$HUB_DIR" && docker compose up -d 2>/dev/null) && log "Hub started" && exit 0
    fi
done

log "No Hub install found; run pull-dev.sh manually after setup"
exit 0
