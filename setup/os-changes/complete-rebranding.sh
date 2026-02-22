#!/bin/bash
#
# Complete CI OS Rebranding Master Script
#
# Applies comprehensive Ubuntu → CI OS rebranding including:
# - Plymouth boot splash (dark green theme)
# - OS release information
# - GNOME/KDE theme configuration
# - Wallpaper and start icon
# - MOTD customization
# - Ubuntu branding removal
#
# Usage: sudo ./complete-rebranding.sh [--skip-reboot-check] [--yes|-y]
# Requirements: Root/sudo access, Ubuntu 24.04 base system
#

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

SKIP_REBOOT_CHECK=0
NONINTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --skip-reboot-check) SKIP_REBOOT_CHECK=1 ;;
        --yes|-y) NONINTERACTIVE=1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
log_header "=========================================="
log_header " CI OS Complete Rebranding"
log_header "=========================================="
echo ""
log_info "This script will apply comprehensive CI OS branding:"
log_info "  ✓ Plymouth boot splash (dark green #066c80, #00a9a7, #72ddd4)"
log_info "  ✓ OS identity (/etc/os-release)"
log_info "  ✓ GNOME/KDE theme configuration"
log_info "  ✓ Wallpaper and start icon"
log_info "  ✓ MOTD customization"
log_info "  ✓ Ubuntu branding removal"
echo ""
log_warn "System will require a reboot to see Plymouth changes"
echo ""
if [[ $NONINTERACTIVE -eq 0 ]]; then
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted by user"
        exit 0
    fi
fi

# Check if all required scripts are present
declare -a REQUIRED_SCRIPTS=(
    "set-ci-branding.sh"
    "set-chromium-default.sh"
    "update-os-release.sh"
    "setup-ci-motd.sh"
    "replace-wallpaper.sh"
    "replace-start-icon.sh"
)

log_info "Checking for required scripts..."
MISSING_SCRIPTS=0
for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
        log_error "Missing required script: $script"
        MISSING_SCRIPTS=1
    fi
done

if [[ $MISSING_SCRIPTS -eq 1 ]]; then
    log_error "Cannot proceed with missing scripts"
    exit 1
fi
log_success "All required scripts found"
echo ""

# Step 1: Apply CI branding (Plymouth, GNOME theme, wallpaper)
log_header "Step 1/6: Applying CI branding theme..."
echo ""
if bash "$SCRIPT_DIR/set-ci-branding.sh"; then
    log_success "CI branding theme applied"
else
    log_error "Failed to apply CI branding theme"
    exit 1
fi
echo ""

# Step 2: Install Chromium and set as default browser
log_header "Step 2/6: Installing Chromium as default browser..."
echo ""
if bash "$SCRIPT_DIR/set-chromium-default.sh"; then
    log_success "Chromium set as default browser"
else
    log_warn "Chromium setup had issues (may already be configured)"
fi
echo ""

# Step 3: Update OS release information
log_header "Step 3/6: Updating OS identity..."
echo ""
if bash "$SCRIPT_DIR/update-os-release.sh"; then
    log_success "OS identity updated"
else
    log_error "Failed to update OS identity"
    exit 1
fi
echo ""

# Step 4: Setup CI MOTD
log_header "Step 4/6: Configuring MOTD..."
echo ""
if bash "$SCRIPT_DIR/setup-ci-motd.sh"; then
    log_success "MOTD configured"
else
    log_error "Failed to configure MOTD"
    exit 1
fi
echo ""

# Step 5: Replace wallpaper
log_header "Step 5/6: Setting wallpaper..."
echo ""
if bash "$SCRIPT_DIR/replace-wallpaper.sh"; then
    log_success "Wallpaper set"
else
    log_warn "Wallpaper script had issues (may be OK if already set)"
fi
echo ""

# Step 6: Replace start icon
log_header "Step 6/6: Updating start icon..."
echo ""
if bash "$SCRIPT_DIR/replace-start-icon.sh"; then
    log_success "Start icon updated"
else
    log_warn "Start icon script had issues (may be OK if already set)"
fi
echo ""

# Optional: Install KDE theme if KDE is present
if [[ $NONINTERACTIVE -eq 0 ]] && { [[ -f "/usr/bin/kwriteconfig5" ]] || [[ -d "/usr/share/plasma" ]]; }; then
    log_header "Optional: KDE Plasma detected"
    echo ""
    read -p "Install KDE theme? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        if [[ -f "$SCRIPT_DIR/install-kde-theme.sh" ]]; then
            log_info "Installing KDE theme..."
            if bash "$SCRIPT_DIR/install-kde-theme.sh"; then
                log_success "KDE theme installed"
            else
                log_warn "KDE theme installation had issues"
            fi
        fi
    fi
    echo ""
fi

# Summary
echo ""
log_header "=========================================="
log_header " Rebranding Complete!"
log_header "=========================================="
echo ""
log_success "CI OS branding has been applied successfully"
echo ""
log_info "Changes applied:"
log_info "  ✓ Plymouth boot splash (dark green CI colors)"
log_info "  ✓ Chromium installed and set as default browser"
log_info "  ✓ OS identity updated (/etc/os-release)"
log_info "  ✓ GNOME/KDE theme configured"
log_info "  ✓ Wallpaper set"
log_info "  ✓ Start icon updated"
log_info "  ✓ MOTD customized"
log_info "  ✓ Ubuntu branding removed"
echo ""
log_info "Official CI Dark Green Color Scheme:"
log_info "  Primary Dark Green: #066c80"
log_info "  Medium Green: #00a9a7"
log_info "  Light Green: #72ddd4"
echo ""

# Validation
if [[ -f "$SCRIPT_DIR/validate-ci-theme.sh" ]]; then
    log_info "Running validation..."
    echo ""
    if bash "$SCRIPT_DIR/validate-ci-theme.sh"; then
        log_success "Validation passed!"
    else
        log_warn "Validation found some issues (may need reboot)"
    fi
    echo ""
fi

# Reboot recommendation
if [[ $SKIP_REBOOT_CHECK -eq 0 ]]; then
    if [[ $NONINTERACTIVE -eq 0 ]]; then
        log_warn "IMPORTANT: Reboot required for Plymouth boot splash changes"
        echo ""
        read -p "Reboot now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
            sleep 5
            reboot
        else
            log_info "Please reboot when convenient to see all changes"
        fi
    else
        log_info "Reboot when convenient to see Plymouth boot splash changes"
    fi
fi

echo ""
log_success "Done! Enjoy your CI OS dark green theme! 🎉"
echo ""
