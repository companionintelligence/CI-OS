#!/usr/bin/env bash
# CI OS Install Ollama Models
# Pulls nomic-embed-text and gemma3:1b on every machine. Pulls qwen3.6:27b only
# when the hardware support rule passes (Strix Halo-class APU, ~32 GB RAM or more).
# Idempotent: skips models already present.
# Used by post-validation after portal setup. Run with: sudo ./backends/ubuntu/provision/install-models.sh
#
# © Companion Intelligence — Lifescope Inc

set -euo pipefail

detect_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        ACTUAL_USER="$SUDO_USER"
        ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        # Fallback: first non-root user with /home
        ACTUAL_USER=$(getent passwd | awk -F: '$3 >= 1000 && $6 ~ /^\/home\// {print $1; exit}')
        ACTUAL_HOME="${ACTUAL_USER:+$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6)}"
        [[ -z "$ACTUAL_USER" ]] && ACTUAL_USER="root" && ACTUAL_HOME="/root"
    fi
}

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_success() { echo "[SUCCESS] $1"; }

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
detect_user

if ! command -v ollama >/dev/null 2>&1; then
    log_warn "Ollama is not installed, skipping model pull"
    exit 0
fi

log_info "Checking Ollama models..."

MODELS=(nomic-embed-text gemma3:1b)
GPU_DETECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/gpu-detect.sh"
if [[ -f "$GPU_DETECT" ]]; then
    # shellcheck source=../../../core/lib/gpu-detect.sh
    source "$GPU_DETECT"
    if ci_os_hardware_supported; then
        MODELS+=(qwen3.6:27b)
    else
        log_info "Skipping qwen3.6:27b: ${CI_OS_HARDWARE_SUPPORT_REASON}"
    fi
else
    log_warn "Hardware support check missing; skipping qwen3.6:27b"
fi

if ! systemctl is-active --quiet ollama 2>/dev/null; then
    systemctl start ollama 2>/dev/null || true
    sleep 5
fi

# Pull models as the actual user (ollama stores models in user's home)
sudo -u "$ACTUAL_USER" bash -c '
for model in "$@"; do
    if ollama list 2>/dev/null | grep -q "$model"; then
        echo "$model already installed"
    else
        echo "Pulling $model..."
        ollama pull "$model"
    fi
done
' _ "${MODELS[@]}" || log_warn "Failed to pull some Ollama models"

log_success "Ollama models checked/pulled"
