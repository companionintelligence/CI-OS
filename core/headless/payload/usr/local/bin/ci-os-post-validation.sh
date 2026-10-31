#!/bin/bash
# Companion OS Post-Validation Setup
# Runs after pairing with the Portal (hub.ci.computer) + Hub. Heavy downloads: ROCm, Ollama models.
# Only runs once; creates /var/lib/setup-device/post-validation-done when complete.
#
# The heavy install runs only on supported hardware (Strix Halo-class APU with
# at least ~32 GB RAM). Anything else is recorded and skipped. The desktop stays
# up, and this script does not retry the install.

DATA_DIR="/var/lib/setup-device"
HUB_ENV="${DATA_DIR}/hub.env"
POST_VALIDATION_FLAG="${DATA_DIR}/post-validation-done"
BOOTSTRAP_ROOT="/usr/lib/ci-os/bootstrap"
GPU_DETECT=""
for _candidate in /usr/lib/ci-os/gpu-detect.sh "${BOOTSTRAP_ROOT}/core/lib/gpu-detect.sh"; do
    if [[ -f "$_candidate" ]]; then
        GPU_DETECT="$_candidate"
        break
    fi
done
unset _candidate
CI_OS_SCRIPTS_URL="${CI_OS_SCRIPTS_URL:-https://raw.githubusercontent.com/companionintelligence/CI-OS/main/scripts}"
ROCM_SCRIPT="/tmp/ci-os-install-rocm-driver.sh"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t ci-os-post-validation -p info 2>/dev/null || true
}

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
mkdir -p "$DATA_DIR"

[ ! -f "$HUB_ENV" ] && { log "hub.env not found; run WiFi setup first"; exit 0; }
[ -f "$POST_VALIDATION_FLAG" ] && { log "Already completed"; exit 0; }

if [[ ! -f "$GPU_DETECT" ]]; then
    log "Hardware support check is missing (${GPU_DETECT}). Not installing ROCm or models."
    printf 'supported=no\nreason=support check missing\nchecked=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "${DATA_DIR}/hardware-support"
    touch "$POST_VALIDATION_FLAG"
    exit 0
fi
# shellcheck source=../../../../../../core/lib/gpu-detect.sh
source "$GPU_DETECT"
if ! ci_os_hardware_supported; then
    log "Unsupported hardware: ${CI_OS_HARDWARE_SUPPORT_REASON}. Skipping ROCm and model install."
    ci_os_record_hardware_support || true
    touch "$POST_VALIDATION_FLAG"
    exit 0
fi
log "Supported hardware: ${CI_OS_HARDWARE_SUPPORT_REASON}."
ci_os_record_hardware_support || true

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
    for model in nomic-embed-text gemma3:1b qwen3.6:27b; do
        ollama list 2>/dev/null | grep -q "$model" || { log "Pulling $model"; ollama pull "$model" 2>/dev/null || true; }
    done
fi

touch "$POST_VALIDATION_FLAG"
log "Post-validation setup complete"
