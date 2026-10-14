#!/usr/bin/env bash
#
# Companion OS Theme Validation for Linux Mint / Cinnamon (read-only checks).
#
# Adapted from backends/ubuntu/desktop-theme/80-validate-ci-theme.sh: the
# Plymouth/GRUB/brand-asset checks are kept as-is (shared mechanism, same
# canon tokens), the GNOME/dash-to-dock/GDM checks are replaced with
# Cinnamon/slick-greeter equivalents, and the checks for things this backend
# deliberately does not touch (os-release ID rewrite, Yaru start-icon, KDE
# color scheme) are dropped rather than reported as failures/warnings — see
# apply-ci-os-desktop.sh's header for why each is out of scope here.
#
# Usage:
#   ./apply-ci-os-desktop.sh --validate
#   bash backends/mint/desktop-theme/80-validate-ci-theme.sh
#

set -euo pipefail

# The canon tokens (CI_* variables + ci_hex0x) and REPO_ROOT come from lib.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"

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

# Not ((COUNT++)): that returns status 1 while COUNT is 0, and set -e then ended the script at its first check.
check_pass() {
    log_success "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

check_fail() {
    log_error "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_warn() {
    log_warn "$1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

echo ""
echo "=========================================="
echo " Companion OS Theme Validation (Mint / Cinnamon)"
echo "=========================================="
echo ""

# Check 1: Plymouth Theme (shared mechanism with Ubuntu — kept as-is)
log_info "Checking Plymouth boot theme..."

PLYMOUTH_WATERMARK="/usr/share/plymouth/themes/spinner/watermark.png"
PLYMOUTH_SPINNER="/usr/share/plymouth/themes/spinner/spinner.plymouth"

if [[ -f "$PLYMOUTH_WATERMARK" ]]; then
    if file "$PLYMOUTH_WATERMARK" | grep -q "PNG image"; then
        check_pass "Plymouth watermark exists"
    else
        check_fail "Plymouth watermark is not a valid PNG"
    fi
else
    check_fail "Plymouth watermark not found"
fi

if [[ -f "$PLYMOUTH_SPINNER" ]]; then
    if grep -qi "$(ci_hex0x "$CI_DARK_BACKGROUND")" "$PLYMOUTH_SPINNER" 2>/dev/null; then
        check_pass "Plymouth uses the CI canon ground ($CI_DARK_BACKGROUND navy)"
    else
        check_warn "Plymouth theme exists but may not have CI colors"
    fi
else
    check_warn "Plymouth spinner config not found"
fi

# Check 2: GRUB Theme (shared mechanism with Ubuntu — kept as-is)
log_info "Checking GRUB theme..."

if [[ -f "/usr/share/pixmaps/ci-os-grub-bg.png" ]]; then
    check_pass "GRUB background image installed"
else
    check_warn "GRUB background image not found (run: sudo backends/mint/desktop-theme/apply-ci-os-desktop.sh --only grub)"
fi

if [[ -f "/etc/default/grub" ]]; then
    if grep -qE '^GRUB_TERMINAL=console' /etc/default/grub 2>/dev/null; then
        check_fail "GRUB_TERMINAL=console in /etc/default/grub disables GRUB_BACKGROUND — remove that line"
    else
        check_pass "GRUB_TERMINAL not forced to console (background can render)"
    fi
    if grep -qE '^GRUB_DISTRIBUTOR="Companion OS"' /etc/default/grub 2>/dev/null; then
        check_pass "GRUB_DISTRIBUTOR set to Companion OS"
    else
        check_warn "GRUB_DISTRIBUTOR not set to Companion OS"
    fi
else
    check_warn "/etc/default/grub not found"
fi

# Check 3: OS identity — this backend intentionally does not rewrite
# /etc/os-release (see apply-ci-os-desktop.sh's header), so just confirm the
# apt role-map's codename assumption holds rather than expecting CI branding.
log_info "Checking OS identity..."

if [[ -f "/etc/os-release" ]]; then
    if grep -qE '^UBUNTU_CODENAME=noble' /etc/os-release 2>/dev/null; then
        check_pass "UBUNTU_CODENAME=noble present (Mint 22.x on Ubuntu Noble base — apt role-map assumption holds)"
    else
        check_warn "UBUNTU_CODENAME missing or unexpected — verify Mint version against docs/architecture/multi-distro-design.md's Mint packaging notes"
    fi
    check_pass "os-release branding rewrite intentionally skipped on Mint (see apply-ci-os-desktop.sh header)"
else
    check_fail "/etc/os-release not found"
fi

# Check 4: Cinnamon theme configuration (system dconf defaults)
log_info "Checking Cinnamon theme configuration..."

CINNAMON_DCONF_FILE="/etc/dconf/db/local.d/01-ci-os-cinnamon-defaults"
if [[ -f "$CINNAMON_DCONF_FILE" ]]; then
    if grep -qi "${CI_LIGHT_PRIMARY#\#}" "$CINNAMON_DCONF_FILE" 2>/dev/null; then
        check_pass "Cinnamon dconf system defaults configured with the CI canon primary"
    else
        check_warn "Cinnamon dconf system defaults exist but may not have CI colors"
    fi
    if grep -q "org/cinnamon\]" "$CINNAMON_DCONF_FILE" 2>/dev/null && grep -q "panels-autohide" "$CINNAMON_DCONF_FILE" 2>/dev/null; then
        check_pass "Cinnamon panel autohide default present"
    else
        check_warn "Cinnamon panel autohide default not found"
    fi
else
    check_warn "Cinnamon dconf system defaults not found (expected $CINNAMON_DCONF_FILE)"
fi

if command -v gsettings >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    CURRENT_THEME=$(gsettings get org.cinnamon.desktop.interface gtk-theme 2>/dev/null | tr -d "'" || true)
    if [[ "$CURRENT_THEME" == Mint-Y-Dark* ]]; then
        check_pass "Cinnamon theme is a Mint-Y-Dark variant: $CURRENT_THEME"
    else
        check_warn "Cinnamon theme is: $CURRENT_THEME (expected a Mint-Y-Dark variant)"
    fi

    PRIMARY_COLOR=$(gsettings get org.cinnamon.desktop.background primary-color 2>/dev/null | tr -d "'" || true)
    if [[ "${PRIMARY_COLOR,,}" == *"${CI_LIGHT_PRIMARY#\#}"* ]]; then
        check_pass "Cinnamon background primary color is the CI canon primary ($CI_LIGHT_PRIMARY)"
    else
        check_warn "Cinnamon background primary color: $PRIMARY_COLOR (expected $CI_LIGHT_PRIMARY)"
    fi
else
    check_warn "Cannot check live Cinnamon settings (not in graphical session or gsettings not available)"
fi

# Check 5: Wallpaper (installed by 20-cinnamon-dconf.sh on this backend)
log_info "Checking wallpaper..."

if [[ -f "/usr/share/backgrounds/ci-os-wallpaper.png" ]]; then
    check_pass "Companion OS wallpaper installed"
else
    check_warn "Companion OS wallpaper not found at /usr/share/backgrounds/ci-os-wallpaper.png"
fi

# Check 6: Slick-Greeter (LightDM login screen)
log_info "Checking Slick-Greeter configuration..."

SLICK_CONF="/etc/lightdm/slick-greeter.conf"
if [[ -f "$SLICK_CONF" ]]; then
    if grep -q "^logo=" "$SLICK_CONF" 2>/dev/null; then
        LOGO_PATH=$(grep "^logo=" "$SLICK_CONF" | head -1 | cut -d= -f2-)
        if [[ -f "$LOGO_PATH" ]]; then
            check_pass "slick-greeter.conf logo key present and file exists ($LOGO_PATH)"
        else
            check_fail "slick-greeter.conf logo key points to a missing file: $LOGO_PATH"
        fi
    else
        check_fail "slick-greeter.conf has no logo= key"
    fi

    if grep -qi "${CI_DARK_BACKGROUND#\#}" "$SLICK_CONF" 2>/dev/null; then
        check_pass "slick-greeter.conf background uses the CI canon dark background"
    else
        check_warn "slick-greeter.conf background may not use CI colors"
    fi

    if grep -q "^theme-name=Mint-Y" "$SLICK_CONF" 2>/dev/null; then
        check_pass "slick-greeter.conf theme-name set to a Mint-Y variant"
    else
        check_warn "slick-greeter.conf theme-name not set to a Mint-Y variant"
    fi
else
    check_warn "slick-greeter.conf not found (expected $SLICK_CONF — run: sudo backends/mint/desktop-theme/apply-ci-os-desktop.sh --only slick-greeter)"
fi

DROPIN="/etc/lightdm/lightdm.conf.d/51-ci-os-greeter.conf"
if [[ -f "$DROPIN" ]] && grep -q "greeter-session=slick-greeter" "$DROPIN" 2>/dev/null; then
    check_pass "LightDM configured to use slick-greeter ($DROPIN)"
else
    check_warn "LightDM greeter-session drop-in not found or not set to slick-greeter (expected $DROPIN)"
fi

# Check 7: MOTD (Message of the Day) — shared render-motd.sh, same as Ubuntu
log_info "Checking MOTD configuration..."

if [[ -f "/etc/update-motd.d/00-ci-os-header" ]]; then
    if grep -q "Companion OS" /etc/update-motd.d/00-ci-os-header 2>/dev/null; then
        check_pass "Companion OS MOTD header exists"
    else
        check_warn "MOTD header exists but may not have CI branding"
    fi
else
    check_warn "Companion OS MOTD header not found"
fi

# Check 8: Brand Assets (fully portable — kept as-is)
log_info "Checking brand assets..."

if [[ -f "$REPO_ROOT/vendor/brand/SHA256SUMS" ]]; then
    if "$REPO_ROOT/core/lib/vendor-brand.sh" --check >/dev/null 2>&1; then
        check_pass "Vendored brand bundle matches its SHA256SUMS (ci-brand $(cat "$REPO_ROOT/vendor/brand/.version"))"
    else
        check_fail "Vendored brand bundle does not match SHA256SUMS — run core/lib/vendor-brand.sh"
    fi
else
    check_warn "Brand guidelines not found in repository"
fi

# Summary
echo ""
echo "=========================================="
echo " Validation Summary"
echo "=========================================="
echo -e "${GREEN}Passed:${NC} $PASS_COUNT"
echo -e "${YELLOW}Warnings:${NC} $WARN_COUNT"
echo -e "${RED}Failed:${NC} $FAIL_COUNT"
echo ""

_APPLY_HINT="sudo $REPO_ROOT/backends/mint/desktop-theme/apply-ci-os-desktop.sh"

if [[ $FAIL_COUNT -eq 0 ]] && [[ $WARN_COUNT -eq 0 ]]; then
    echo -e "${GREEN}All checks passed.${NC}"
    exit 0
elif [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${YELLOW}Theme mostly applied. Check warnings above.${NC}"
    echo "Some checks may warn if you have not rebooted yet or are not in a graphical session."
    exit 0
else
    echo -e "${RED}Theme validation failed. See errors above.${NC}"
    echo ""
    echo "To apply or repair branding, run:"
    echo "  $_APPLY_HINT"
    echo ""
    exit 1
fi
