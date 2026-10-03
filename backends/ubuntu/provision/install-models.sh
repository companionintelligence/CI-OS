#!/usr/bin/env bash
# CI OS Install Ollama Models
# Pulls required Ollama models (nomic-embed-text, gemma3:1b, qwen3:4b).
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

if ! systemctl is-active --quiet ollama 2>/dev/null; then
    systemctl start ollama 2>/dev/null || true
    sleep 5
fi

# Pull models as the actual user (ollama stores models in user's home)
sudo -u "$ACTUAL_USER" bash <<'MODEL_EOF' || log_warn "Failed to pull some Ollama models"
for model in nomic-embed-text gemma3:1b qwen3:4b; do
    if ollama list 2>/dev/null | grep -q "$model"; then
        echo "$model already installed"
    else
        echo "Pulling $model..."
        ollama pull "$model"
    fi
done
MODEL_EOF

log_success "Ollama models checked/pulled"
