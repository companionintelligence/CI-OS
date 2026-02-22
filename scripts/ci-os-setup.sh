#!/usr/bin/env bash
#=============================================================================
# CI OS Master Setup
#
# Orchestrates all setup steps, checks if everything is in place, self-repairs.
# Phased approach:
#   Phase 1 (lightweight): Download scripts, repair packages, headless WiFi. No heavy downloads.
#   Phase 2 (post-validation): After portal.ci.computer pairing + Hub running: ROCm, Ollama models.
#
# Usage:
#   sudo ./scripts/ci-os-setup.sh           # Full phase 1
#   sudo ./scripts/ci-os-setup.sh --phase2  # Run phase 2 only (after validation)
#   sudo ./scripts/ci-os-setup.sh --check   # Verify install state, report missing items
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()    { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_header()  { echo -e "${BOLD}${CYAN}$1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CI_OS_SCRIPTS_URL="${CI_OS_SCRIPTS_URL:-https://raw.githubusercontent.com/companionintelligence/CI-OS/main/scripts}"
DATA_DIR="/var/lib/setup-device"
POST_VALIDATION_FLAG="${DATA_DIR}/post-validation-done"

[[ $EUID -eq 0 ]] || { log_error "Run with sudo"; exit 1; }

# Download script from URL if not present locally
download_script() {
    local name="$1"
    local url="${CI_OS_SCRIPTS_URL}/${name}"
    local dest="${SCRIPT_DIR}/${name}"
    if [[ -f "$dest" ]]; then
        log_info "Using local $name"
        return 0
    fi
    log_info "Downloading $name from $url"
    mkdir -p "$SCRIPT_DIR"
    if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
        chmod +x "$dest"
        log_success "Downloaded $name"
        return 0
    fi
    log_warn "Could not download $name (no network or URL changed)"
    return 1
}

# Phase 1: Lightweight setup - no ROCm, no Ollama models
run_phase1() {
    log_header "Phase 1: Lightweight setup (scripts, repair, headless WiFi)"
    mkdir -p "$DATA_DIR"

    # Download scripts if missing
    download_script "setup-fresh-ubuntu.sh" || true
    download_script "install-rocm-driver.sh" || true
    download_script "bootstrap-ci-os.sh" || true

    # Repair dpkg
    log_info "Repairing package state..."
    dpkg --configure -a 2>/dev/null || true

    # Run bootstrap (headless WiFi)
    if [[ -f "${SCRIPT_DIR}/bootstrap-ci-os.sh" ]]; then
        log_info "Running bootstrap-ci-os.sh..."
        bash "${SCRIPT_DIR}/bootstrap-ci-os.sh" --yes || log_warn "Bootstrap had issues"
    else
        log_info "Running headless build and install..."
        if [[ -d "${REPO_ROOT}/setup/headless" ]]; then
            (cd "${REPO_ROOT}/setup/headless" && bash build.sh 2>/dev/null) || true
            DEB=$(ls "${REPO_ROOT}/setup/headless"/setup-device_*.deb 2>/dev/null | head -1)
            [[ -n "$DEB" ]] && apt-get install -y --fix-missing "$DEB" 2>/dev/null || log_warn "Could not install setup-device"
        fi
    fi

    # Optional: run setup-fresh-ubuntu --light (basic tools, no ROCm, no model pulls)
    if [[ -f "${SCRIPT_DIR}/setup-fresh-ubuntu.sh" ]]; then
        log_info "Running setup-fresh-ubuntu.sh --light (skip ROCm, Ollama models)..."
        bash "${SCRIPT_DIR}/setup-fresh-ubuntu.sh" --light 2>/dev/null || log_warn "Light setup had issues"
    fi

    log_success "Phase 1 complete"
}

# Phase 2: Heavy setup - only after portal.ci.computer validation + Hub
run_phase2() {
    log_header "Phase 2: Post-validation setup (ROCm, Ollama models)"
    mkdir -p "$DATA_DIR"

    if [[ ! -f "${DATA_DIR}/hub.env" ]]; then
        log_warn "hub.env not found - run WiFi setup and complete portal.ci.computer pairing first"
        return 1
    fi

    if [[ -f "$POST_VALIDATION_FLAG" ]]; then
        log_info "Post-validation already completed, skipping"
        return 0
    fi

    # ROCm / AMD drivers
    if [[ -f "${SCRIPT_DIR}/install-rocm-driver.sh" ]]; then
        log_info "Installing ROCm AMD drivers..."
        bash "${SCRIPT_DIR}/install-rocm-driver.sh" 2>/dev/null || log_warn "ROCm install had issues"
    else
        download_script "install-rocm-driver.sh" && bash "${SCRIPT_DIR}/install-rocm-driver.sh" 2>/dev/null || true
    fi

    # Ollama models (heavy)
    if command -v ollama >/dev/null 2>&1; then
        log_info "Pulling Ollama models (nomic-embed-text, gemma3:1b, qwen3-vl:32b)..."
        systemctl start ollama 2>/dev/null || true
        sleep 5
        for model in nomic-embed-text gemma3:1b qwen3-vl:32b; do
            ollama list 2>/dev/null | grep -q "$model" || ollama pull "$model" 2>/dev/null || log_warn "Could not pull $model"
        done
    else
        log_warn "Ollama not installed, skipping model pull"
    fi

    touch "$POST_VALIDATION_FLAG"
    log_success "Phase 2 complete"
}

# Check state and report
run_check() {
    log_header "CI OS setup state check"
    echo ""
    echo "Phase 1 (lightweight):"
    [[ -f /usr/local/bin/setup-network-monitor.sh ]] && echo "  ✓ setup-device scripts" || echo "  ✗ setup-device missing"
    [[ -f "${SCRIPT_DIR}/setup-fresh-ubuntu.sh" ]] && echo "  ✓ setup-fresh-ubuntu.sh" || echo "  ✗ setup-fresh-ubuntu.sh missing"
    command -v docker >/dev/null 2>&1 && echo "  ✓ Docker" || echo "  ✗ Docker missing"
    command -v ollama >/dev/null 2>&1 && echo "  ✓ Ollama" || echo "  ✗ Ollama missing"
    echo ""
    echo "Phase 2 (post-validation):"
    [[ -f "${DATA_DIR}/hub.env" ]] && echo "  ✓ hub.env (paired)" || echo "  ✗ hub.env not found (complete WiFi setup)"
    [[ -f "$POST_VALIDATION_FLAG" ]] && echo "  ✓ Post-validation done" || echo "  ✗ Post-validation pending"
    command -v rocminfo >/dev/null 2>&1 && echo "  ✓ ROCm" || echo "  ✗ ROCm not installed"
    ollama list 2>/dev/null | grep -q "nomic-embed-text" && echo "  ✓ Ollama models" || echo "  ✗ Ollama models missing"
    echo ""
}

# Main
case "${1:-}" in
    --phase2)  run_phase2 ;;
    --check)   run_check ;;
    --help|-h) echo "Usage: sudo $0 [--phase2|--check]"; exit 0 ;;
    *)         run_phase1 ;;
esac
