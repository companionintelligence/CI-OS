#!/bin/bash
#
# CI OS Dark Green Theme Validation Script
#
# Validates that the CI OS dark green theme is properly applied
# and that Ubuntu branding has been removed.
#
# Usage: ./validate-ci-theme.sh
# Can be run with or without sudo (some checks require root)
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[✗ FAIL]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓ PASS]${NC} $1"; }

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check_pass() {
    log_success "$1"
    ((PASS_COUNT++))
}

check_fail() {
    log_error "$1"
    ((FAIL_COUNT++))
}

check_warn() {
    log_warn "$1"
    ((WARN_COUNT++))
}

echo ""
echo "=========================================="
echo " CI OS Dark Green Theme Validation"
echo "=========================================="
echo ""

# Check 1: Color Scheme Files
log_info "Checking color scheme files..."

if [[ -f "/usr/share/color-schemes/CI-OS-Dark.colors" ]] || [[ -f "$HOME/.local/share/color-schemes/CI-OS-Dark.colors" ]]; then
    check_pass "KDE color scheme file exists"
else
    check_warn "KDE color scheme not installed (OK if using GNOME)"
fi

# Check 2: Plymouth Theme
log_info "Checking Plymouth boot theme..."

PLYMOUTH_WATERMARK="/usr/share/plymouth/themes/spinner/watermark.png"
PLYMOUTH_SPINNER="/usr/share/plymouth/themes/spinner/spinner.plymouth"

if [[ -f "$PLYMOUTH_WATERMARK" ]]; then
    # Check if it's been modified (different from default Ubuntu)
    if file "$PLYMOUTH_WATERMARK" | grep -q "PNG image"; then
        check_pass "Plymouth watermark exists"
    else
        check_fail "Plymouth watermark is not a valid PNG"
    fi
else
    check_fail "Plymouth watermark not found"
fi

if [[ -f "$PLYMOUTH_SPINNER" ]]; then
    if grep -q "0x066c80" "$PLYMOUTH_SPINNER" 2>/dev/null; then
        check_pass "Plymouth uses CI dark green colors (#066c80)"
    else
        check_warn "Plymouth theme exists but may not have CI colors"
    fi
else
    check_warn "Plymouth spinner config not found"
fi

# Check 3: OS Release Information
log_info "Checking OS identity..."

if [[ -f "/etc/os-release" ]]; then
    if grep -q "CI OS" /etc/os-release 2>/dev/null; then
        check_pass "/etc/os-release shows CI OS identity"
    else
        check_fail "/etc/os-release still shows Ubuntu branding"
    fi
    
    if grep -q "ID=ci-os" /etc/os-release 2>/dev/null; then
        check_pass "OS ID set to ci-os"
    else
        check_warn "OS ID not set to ci-os"
    fi
else
    check_fail "/etc/os-release not found"
fi

# Check 4: GNOME Theme Settings
log_info "Checking GNOME theme configuration..."

if command -v gsettings >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    CURRENT_THEME=$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'")
    if [[ "$CURRENT_THEME" == *"prussiangreen"* ]] || [[ "$CURRENT_THEME" == *"sage"* ]] || [[ "$CURRENT_THEME" == *"viridian"* ]]; then
        check_pass "GNOME theme is dark green variant: $CURRENT_THEME"
    else
        check_warn "GNOME theme is: $CURRENT_THEME (expected dark green variant)"
    fi
    
    PRIMARY_COLOR=$(gsettings get org.gnome.desktop.background primary-color 2>/dev/null | tr -d "'")
    if [[ "$PRIMARY_COLOR" == *"066c80"* ]]; then
        check_pass "GNOME background primary color is CI dark green"
    else
        check_warn "GNOME background primary color: $PRIMARY_COLOR (expected #066c80)"
    fi
else
    check_warn "Cannot check GNOME settings (not in graphical session or gsettings not available)"
fi

# Check 5: GDM/dconf system settings
log_info "Checking GDM theme configuration..."

if [[ -f "/etc/dconf/db/local.d/01-ci-theme" ]]; then
    if grep -q "066c80" /etc/dconf/db/local.d/01-ci-theme 2>/dev/null; then
        check_pass "dconf system theme configured with CI colors"
    else
        check_warn "dconf system theme exists but may not have CI colors"
    fi
else
    check_warn "dconf system theme configuration not found"
fi

if [[ -f "/etc/dconf/db/gdm.d/01-ci-theme" ]]; then
    check_pass "GDM theme configuration exists"
else
    check_warn "GDM theme configuration not found (login screen may not be themed)"
fi

# Check 6: MOTD (Message of the Day)
log_info "Checking MOTD configuration..."

if [[ -f "/etc/update-motd.d/00-ci-header" ]]; then
    if grep -q "CI OS" /etc/update-motd.d/00-ci-header 2>/dev/null; then
        check_pass "CI OS MOTD header exists"
    else
        check_warn "MOTD header exists but may not have CI branding"
    fi
else
    check_warn "CI OS MOTD header not found"
fi

if [[ -f "/etc/update-motd.d/50-motd-news" ]]; then
    if [[ -x "/etc/update-motd.d/50-motd-news" ]]; then
        check_warn "Ubuntu MOTD news is still enabled (should be disabled)"
    else
        check_pass "Ubuntu MOTD news is disabled"
    fi
else
    check_pass "Ubuntu MOTD news not present"
fi

# Check 7: Ubuntu Branding Removal
log_info "Checking for remaining Ubuntu branding..."

UBUNTU_FOUND=0

# Check for Ubuntu in key files
if grep -i "ubuntu" /etc/os-release 2>/dev/null | grep -v "ID_LIKE\|CODENAME" | grep -q "ubuntu"; then
    check_warn "Found 'Ubuntu' reference in /etc/os-release"
    UBUNTU_FOUND=1
fi

# Check Plymouth themes for Ubuntu text
if grep -qi "ubuntu" /usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth 2>/dev/null; then
    if ! grep -q "CI OS" /usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth 2>/dev/null; then
        check_warn "Plymouth text theme still references Ubuntu"
        UBUNTU_FOUND=1
    fi
fi

if [[ $UBUNTU_FOUND -eq 0 ]]; then
    check_pass "No obvious Ubuntu branding found"
fi

# Check 8: Wallpaper
log_info "Checking wallpaper..."

if [[ -f "/usr/share/backgrounds/ci-os-wallpaper.png" ]]; then
    check_pass "CI OS wallpaper installed"
else
    check_warn "CI OS wallpaper not found at /usr/share/backgrounds/ci-os-wallpaper.png"
fi

# Check 9: Start Icon (GNOME)
log_info "Checking start icon..."

START_ICON_FOUND=0
for theme_dir in /usr/share/icons/Yaru*/scalable/places/; do
    if [[ -f "$theme_dir/start-here-symbolic.svg" ]]; then
        START_ICON_FOUND=1
        break
    fi
done

if [[ $START_ICON_FOUND -eq 1 ]]; then
    check_pass "Start icons found in Yaru themes"
else
    check_warn "Start icons not found (may be using default)"
fi

# Check 10: Brand Assets
log_info "Checking brand assets..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -f "$REPO_ROOT/assets/branding/brand-guidelines.md" ]]; then
    if grep -q "066c80" "$REPO_ROOT/assets/branding/brand-guidelines.md" 2>/dev/null; then
        check_pass "Brand guidelines contain CI dark green colors"
    else
        check_warn "Brand guidelines exist but may not have correct colors"
    fi
else
    check_warn "Brand guidelines not found in repository"
fi

# Summary
echo ""
echo "=========================================="
echo " Validation Summary"
echo "=========================================="
echo -e "${GREEN}✓ Passed:${NC} $PASS_COUNT"
echo -e "${YELLOW}⚠ Warnings:${NC} $WARN_COUNT"
echo -e "${RED}✗ Failed:${NC} $FAIL_COUNT"
echo ""

if [[ $FAIL_COUNT -eq 0 ]] && [[ $WARN_COUNT -eq 0 ]]; then
    echo -e "${GREEN}🎉 Perfect! CI OS dark green theme is fully applied!${NC}"
    exit 0
elif [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${YELLOW}⚠ Theme mostly applied. Check warnings above.${NC}"
    echo "Some checks may warn if you haven't rebooted yet or aren't in a graphical session."
    exit 0
else
    echo -e "${RED}❌ Theme validation failed. See errors above.${NC}"
    echo ""
    echo "To fix issues, run the following scripts:"
    echo "  sudo ./set-ci-branding.sh        # Apply theme and colors"
    echo "  sudo ./update-os-release.sh      # Update OS identity"
    echo "  sudo ./setup-ci-motd.sh          # Update MOTD"
    echo "  sudo ./replace-wallpaper.sh      # Set wallpaper"
    echo "  sudo ./replace-start-icon.sh     # Update start icon"
    echo ""
    exit 1
fi
