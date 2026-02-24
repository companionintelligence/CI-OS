#!/usr/bin/env bash
#=============================================================================
# CI-OS Bootstrap Script
#
# One-command setup for a freshly flashed Ubuntu machine. Run this after
# cloning the CI-OS repo to configure headless WiFi setup, branding, and
# default applications.
#
# Usage:
#   # Run with WIRED (Ethernet) internet connected. After reboot, unplug Ethernet
#   # to use the Companion-Setup-XXXX hotspot for WiFi configuration.
#
#   # From repo root:
#   sudo ./scripts/bootstrap-ci-os.sh
#
#   # Or from scripts/ (e.g. after cd ~/CI-OS/scripts):
#   chmod +x ./bootstrap-ci-os.sh && sudo ./bootstrap-ci-os.sh --yes
#
#   # One-liner: clone + bootstrap (run on the flashed machine)
#   git clone https://github.com/companionintelligence/CI-OS.git && cd CI-OS && sudo ./scripts/bootstrap-ci-os.sh --yes
#
# Options:
#   --no-headless   Skip headless WiFi setup (captive portal)
#   --no-rebrand    Skip CI OS branding (Plymouth, wallpaper, Chromium, etc.)
#   --no-reboot     Do not prompt for reboot at end
#   --yes, -y       Non-interactive: skip all prompts, do not reboot
#
# What this script runs (in order):
#   1. System setup - setup-fresh-ubuntu --light (Docker, Tailscale, Ollama, Node/Bun, etc.)
#   2. Complete rebranding - Plymouth, Chromium, wallpaper, start icon, MOTD
#   3. Headless device setup - builds and installs setup-device .deb
#      (WiFi captive portal: Companion-Setup-XXXX hotspot, setup.ci.computer)
#      NOTE: runs last because it disables internet connectivity
#   4. Restart (or prompt when not --yes)
#
# Recoverable: Re-run after any failure. Steps are idempotent; use --no-headless
# or --no-rebrand to skip completed parts.
#
# Requires: Ubuntu 24.04 (or compatible), root/sudo
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
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_header()  { echo -e "${BOLD}${CYAN}$1${NC}"; }

DO_HEADLESS=1
DO_REBRAND=1
NO_REBOOT=0
NONINTERACTIVE=0
HEADLESS_INSTALLED=0

for arg in "$@"; do
    case "$arg" in
        --no-headless)  DO_HEADLESS=0 ;;
        --no-rebrand)   DO_REBRAND=0 ;;
        --no-reboot)    NO_REBOOT=1 ;;
        --yes|-y)       NONINTERACTIVE=1; NO_REBOOT=1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Find repo root (script lives in scripts/; works when run from scripts/ or repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Pre-flight: ensure critical assets exist (fail early with clear message)
if [[ $DO_REBRAND -eq 1 ]]; then
    for f in "setup/os-changes/Logo_Banner_Color.png" "setup/os-changes/background.png" "setup/os-changes/LogoMark_Color_StartIcon-cropped.svg"; do
        if [[ ! -f "$REPO_ROOT/$f" ]]; then
            log_error "Missing asset: $f"
            log_info "Ensure the repo is complete (e.g. full git clone, not partial download)"
            exit 1
        fi
    done
fi

# Repair broken dpkg state from any previous failed install (makes re-runs recoverable)
dpkg --configure -a 2>/dev/null || true

# Quick connectivity check - Step 1 needs apt to work
log_info "Checking network (apt mirrors need internet)..."
if ! apt-get update -qq 2>/dev/null; then
    log_error "apt-get update failed. Ensure wired Ethernet is connected and has internet."
    log_error "If behind a captive portal, complete browser login first, then re-run bootstrap."
    exit 1
fi

echo ""
log_header "=========================================="
log_header " CI-OS Bootstrap"
log_header "=========================================="
echo ""
log_info "Repo root: $REPO_ROOT"
log_info "Will run:"
log_info "  ✓ System setup (Docker, Tailscale, Ollama, Node/Bun)"
[[ $DO_REBRAND -eq 1 ]] && log_info "  ✓ Complete CI OS rebranding"
[[ $DO_HEADLESS -eq 1 ]] && log_info "  ✓ Headless device setup (WiFi captive portal) — runs last"
echo ""

#-----------------------------------------------------------------------------
# 1. System setup (Docker, Tailscale, Ollama, Node/Bun, etc.) - MUST run first
#-----------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/setup-fresh-ubuntu.sh" ]]; then
    log_header "Step 1: System setup (Docker, Tailscale, Ollama, etc.)"
    echo ""
    log_info "Ensure wired Ethernet is connected. This step needs internet for apt packages."
    echo ""
    if ! bash "$SCRIPT_DIR/setup-fresh-ubuntu.sh" --light; then
        log_error "Step 1 (setup-fresh-ubuntu) failed. Fix the error above and re-run:"
        log_error "  cd $REPO_ROOT/scripts && sudo ./bootstrap-ci-os.sh ${NONINTERACTIVE:+--yes}"
        log_error "Bootstrap will not continue without a successful Step 1 (Docker, Tailscale, etc. are required)."
        exit 1
    fi
    log_success "System setup complete"
    echo ""
fi

#-----------------------------------------------------------------------------
# 2. Complete rebranding
#-----------------------------------------------------------------------------
if [[ $DO_REBRAND -eq 1 ]]; then
    log_header "Step 2: Complete CI OS rebranding"
    echo ""

    REBRAND="$REPO_ROOT/setup/os-changes/complete-rebranding.sh"
    if [[ ! -f "$REBRAND" ]]; then
        log_error "Rebranding script not found: $REBRAND"
        exit 1
    fi

    REBRAND_ARGS=()
    [[ $NONINTERACTIVE -eq 1 ]] && REBRAND_ARGS+=(--yes)
    [[ $NO_REBOOT -eq 1 ]] && REBRAND_ARGS+=(--skip-reboot-check)

    if ! bash "$REBRAND" "${REBRAND_ARGS[@]}"; then
        log_error "Rebranding failed"
        exit 1
    fi
    log_success "Rebranding complete"
    echo ""
fi

#-----------------------------------------------------------------------------
# 3. Headless device setup — MUST run last (disables internet connectivity)
#-----------------------------------------------------------------------------
if [[ $DO_HEADLESS -eq 1 ]]; then
    log_header "Step 3: Headless device setup"
    echo ""

    # Build and install setup-device .deb (or use ci-os-setup.sh as main entry for full orchestration)
    if [[ $HEADLESS_INSTALLED -eq 0 ]]; then
        HEADLESS_DIR="$REPO_ROOT/setup/headless"
        if [[ ! -d "$HEADLESS_DIR" ]]; then
            log_error "Headless setup directory not found: $HEADLESS_DIR"
            exit 1
        fi

        log_info "Building setup-device package..."
        if ! (cd "$HEADLESS_DIR" && bash build.sh); then
            log_error "Failed to build setup-device package"
            exit 1
        fi

        DEB=$(ls "$HEADLESS_DIR"/setup-device_*.deb 2>/dev/null | head -1)
        if [[ -z "$DEB" ]] || [[ ! -f "$DEB" ]]; then
            log_error "setup-device .deb not found after build"
            exit 1
        fi

        log_info "Updating package lists..."
        APT_UPDATE_OUT=$(mktemp)
        APT_INSTALL_OUT=$(mktemp)
        trap "rm -f '$APT_UPDATE_OUT' '$APT_INSTALL_OUT'" EXIT

        if apt-get update 2>"$APT_UPDATE_OUT"; then
            log_info "Installing setup-device..."
            if apt-get install -y --fix-missing "$DEB" 2>"$APT_INSTALL_OUT"; then
                HEADLESS_INSTALLED=1
                log_success "Headless setup installed"
            else
                log_error "apt-get install failed. Output:"
                cat "$APT_INSTALL_OUT" | tail -30 | sed 's/^/  /'
            fi
        else
            log_error "apt-get update failed. Output:"
            cat "$APT_UPDATE_OUT" | tail -30 | sed 's/^/  /'
        fi
    fi

    if [[ $HEADLESS_INSTALLED -eq 0 ]]; then
        log_warn "Could not install setup-device (apt failed)"
        log_info "Common causes: captive portal (login page), DNS issues, or unreachable mirrors"
        [[ -n "${DEB:-}" ]] && log_info "The .deb was built at: $DEB"
        log_info "Try: ping -c 1 8.8.8.8 && curl -s -o /dev/null -w '%{http_code}' https://archive.ubuntu.com"
        log_info "Then run: sudo $SCRIPT_DIR/bootstrap-ci-os.sh --no-rebrand"
    else
        log_info "Hotspot: Companion-Setup-XXXX (password: SetupDevice123)"
        log_info "Portal: https://setup.ci.computer or http://192.168.99.1"
    fi
    echo ""
fi

#-----------------------------------------------------------------------------
# 4. Restart (when not --yes / NO_REBOOT=0)
#-----------------------------------------------------------------------------
if [[ ($DO_REBRAND -eq 1 || $DO_HEADLESS -eq 1) ]] && [[ $NO_REBOOT -eq 0 ]]; then
    echo ""
    log_info "Rebooting to apply Plymouth and full branding..."
    sleep 3
    reboot
fi

#-----------------------------------------------------------------------------
# Done (reached when NO_REBOOT=1, e.g. --yes)
#-----------------------------------------------------------------------------
log_header "=========================================="
log_header " Bootstrap complete!"
log_header "=========================================="
echo ""
log_success "CI-OS is configured."
echo ""
log_info "Summary:"
[[ $HEADLESS_INSTALLED -eq 1 ]] && log_info "  • Headless WiFi: After reboot, unplug Ethernet → hotspot starts → connect to Companion-Setup-XXXX → setup.ci.computer"
[[ $DO_HEADLESS -eq 1 && $HEADLESS_INSTALLED -eq 0 ]] && log_info "  • Headless WiFi: Install skipped (apt failed). Connect to internet and run: sudo $SCRIPT_DIR/bootstrap-ci-os.sh --no-rebrand"
[[ $DO_REBRAND -eq 1 ]] && log_info "  • Reboot to see Plymouth boot splash and full branding"
[[ $NO_REBOOT -eq 1 ]] && log_info "  • Run 'sudo reboot' when ready to apply branding"
echo ""
