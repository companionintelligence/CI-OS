#!/bin/bash
# CI OS Hub - Start after setup verification
# Reads /var/lib/setup-device/hub.env (CI_ZONE_ID, DEVICE_ID, API_KEY, CI_CLOUD_API_URL)
# Triggers Hub download/start. No-op if Hub or Docker not installed.
# After Hub starts, triggers Phase 2 (ROCm, Ollama models) once via ci-os-post-validation.sh.

HUB_ENV="/var/lib/setup-device/hub.env"
POST_VALIDATION_FLAG="/var/lib/setup-device/post-validation-done"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t ci-os-hub-start -p info 2>/dev/null || true
}

[ ! -f "$HUB_ENV" ] && exit 0

# Option 1: ci-os-hub-install (run first - ensures Hub via pull-dev or merge+start with API_KEY)
if [ -x /usr/local/bin/ci-os-hub-install.sh ]; then
    log "Running ci-os-hub-install.sh"
    /usr/local/bin/ci-os-hub-install.sh 2>/dev/null || true
fi

# Option 2: Start ci-os-hub.service if it exists (uses EnvironmentFile=hub.env)
if systemctl list-unit-files --type=service ci-os-hub.service 2>/dev/null | grep -q ci-os-hub; then
    log "Starting ci-os-hub.service"
    systemctl start ci-os-hub.service 2>/dev/null
fi

# Option 3: Docker-based install at standard path (fallback if ci-os-hub-install did not start)
if command -v docker >/dev/null 2>&1 && [ -d /opt/ci-os-hub ] && [ -f /opt/ci-os-hub/docker-compose.yml ]; then
    log "Starting CI OS Hub via docker compose"
    (cd /opt/ci-os-hub && \
     { grep -v '^DEVICE_ID=\|^API_KEY=\|^CI_CLOUD_API_KEY=\|^CI_CLOUD_API_URL=\|^CI_ZONE_ID=' .env 2>/dev/null || true
       grep -v '^#\|^$' "$HUB_ENV"
     } > .env.merged 2>/dev/null && mv .env.merged .env; \
     docker compose up -d 2>/dev/null) || true
fi

# Phase 2: After validation + Hub, run heavy setup (ROCm, Ollama models) once in background
if [ ! -f "$POST_VALIDATION_FLAG" ] && [ -x /usr/local/bin/ci-os-post-validation.sh ]; then
    log "Scheduling post-validation setup (ROCm, Ollama models)"
    nohup /usr/local/bin/ci-os-post-validation.sh >/var/log/ci-os-post-validation.log 2>&1 &
fi

exit 0
