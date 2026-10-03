#!/bin/bash
# CI OS Post-Validation Setup
# Runs after portal.ci.computer pairing + Hub. Heavy downloads: ROCm, Ollama models.
# Only runs once; creates /var/lib/setup-device/post-validation-done when complete.

DATA_DIR="/var/lib/setup-device"
HUB_ENV="${DATA_DIR}/hub.env"
POST_VALIDATION_FLAG="${DATA_DIR}/post-validation-done"
BOOTSTRAP_ROOT="/usr/lib/ci-os/bootstrap"
CI_OS_SCRIPTS_URL="${CI_OS_SCRIPTS_URL:-https://raw.githubusercontent.com/companionintelligence/CI-OS/main/scripts}"
ROCM_SCRIPT="/tmp/ci-os-install-rocm-driver.sh"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t ci-os-post-validation -p info 2>/dev/null || true
}

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
mkdir -p "$DATA_DIR"

[ ! -f "$HUB_ENV" ] && { log "hub.env not found; run WiFi setup first"; exit 0; }
[ -f "$POST_VALIDATION_FLAG" ] && { log "Already completed"; exit 0; }

log "Starting post-validation setup (ROCm, Ollama models)"

# ROCm / AMD drivers — prefer the staged image copy (always present on a
# built ISO), then a dev/manual repo checkout, then a last-resort download.
if [ -f "${BOOTSTRAP_ROOT}/backends/ubuntu/lib/install-rocm-driver.sh" ]; then
    log "Installing ROCm via staged bootstrap script"
    bash "${BOOTSTRAP_ROOT}/backends/ubuntu/lib/install-rocm-driver.sh" 2>/dev/null || log "ROCm had issues"
elif [ -f "${CI_OS_REPO:-/opt/ci-os}/backends/ubuntu/lib/install-rocm-driver.sh" ]; then
    log "Installing ROCm via repo script"
    bash "${CI_OS_REPO:-/opt/ci-os}/backends/ubuntu/lib/install-rocm-driver.sh" 2>/dev/null || log "ROCm had issues"
elif command -v curl >/dev/null 2>&1; then
    log "Downloading and running ROCm installer"
    curl -fsSL "${CI_OS_SCRIPTS_URL}/install-rocm-driver.sh" -o "$ROCM_SCRIPT" 2>/dev/null
    [ -f "$ROCM_SCRIPT" ] && chmod +x "$ROCM_SCRIPT" && bash "$ROCM_SCRIPT" 2>/dev/null || true
    rm -f "$ROCM_SCRIPT"
fi

# Ollama models — same preference order. provision.sh --tier=core already
# pulls these at first boot; this is an idempotent catch-up for the case
# where first boot ran without network (see first-boot-setup.sh).
if [ -f "${BOOTSTRAP_ROOT}/backends/ubuntu/provision/install-models.sh" ]; then
    log "Installing Ollama models via staged bootstrap script"
    bash "${BOOTSTRAP_ROOT}/backends/ubuntu/provision/install-models.sh" 2>/dev/null || log "install-models.sh had issues"
elif [ -f "${CI_OS_REPO:-/opt/ci-os}/backends/ubuntu/provision/install-models.sh" ]; then
    log "Installing Ollama models via repo script"
    bash "${CI_OS_REPO:-/opt/ci-os}/backends/ubuntu/provision/install-models.sh" 2>/dev/null || log "install-models.sh had issues"
elif command -v ollama >/dev/null 2>&1; then
    systemctl start ollama 2>/dev/null || true
    sleep 5
    for model in nomic-embed-text gemma3:1b qwen3:4b; do
        ollama list 2>/dev/null | grep -q "$model" || { log "Pulling $model"; ollama pull "$model" 2>/dev/null || true; }
    done
fi

touch "$POST_VALIDATION_FLAG"
log "Post-validation setup complete"
