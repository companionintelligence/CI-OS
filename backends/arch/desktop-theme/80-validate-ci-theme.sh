#!/usr/bin/env bash
#
# CI OS Theme Validation for Arch Linux / GNOME Shell (read-only checks).
#
# Adapted from backends/fedora/desktop-theme/80-validate-ci-theme.sh (compared
# side by side): the Plymouth/brand-asset checks are kept as-is (shared
# mechanism, same canon tokens). The GDM/GNOME-Shell checks are the same
# accent-color/color-scheme equivalents Fedora uses (see
# 28-gdm-accent-branding.sh's header for why there is no gresource to check
# here). The GRUB check is Arch-specific: unlike Ubuntu/Mint/Fedora, a
# missing GRUB background/config here is expected and NOT a failure when
# systemd-boot is in use instead — see 15-grub-theme.sh's header. Checks for
# things this backend deliberately does not touch (os-release ID rewrite,
# Yaru start-icon, dash-to-dock, KDE color scheme) are dropped rather than
# reported as failures/warnings, same as Fedora/Mint.
#
# Usage:
#   ./apply-ci-os-desktop.sh --validate
#   bash backends/arch/desktop-theme/80-validate-ci-theme.sh
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
echo " CI OS Theme Validation (Arch / GNOME)"
echo "=========================================="
echo ""

# Check 1: Plymouth Theme (shared mechanism with Ubuntu/Fedora — kept as-is)
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

# Check 2: Bootloader theme — Arch-specific: GRUB vs systemd-boot is a real
# fork here (see 15-grub-theme.sh's header), not a single expected path.
log_info "Checking bootloader theme..."

GRUB_IN_USE=0
if [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null 2>&1; then
    GRUB_IN_USE=1
fi

if [[ "$GRUB_IN_USE" -eq 1 ]]; then
    if [[ -f "/usr/share/pixmaps/ci-os-grub-bg.png" ]]; then
        check_pass "GRUB background image installed"
    else
        check_warn "GRUB background image not found (run: sudo backends/arch/desktop-theme/apply-ci-os-desktop.sh --only grub)"
    fi

    if grep -qE '^GRUB_TERMINAL=console' /etc/default/grub 2>/dev/null; then
        check_fail "GRUB_TERMINAL=console in /etc/default/grub disables GRUB_BACKGROUND — remove that line"
    else
        check_pass "GRUB_TERMINAL not forced to console (background can render)"
    fi
    if grep -qE '^GRUB_DISTRIBUTOR="CI OS"' /etc/default/grub 2>/dev/null; then
        check_pass "GRUB_DISTRIBUTOR set to CI OS"
    else
        check_warn "GRUB_DISTRIBUTOR not set to CI OS"
    fi
elif command -v bootctl >/dev/null 2>&1 && bootctl status 2>/dev/null | grep -qi 'systemd-boot'; then
    check_pass "systemd-boot detected — no GRUB boot menu on this system, GRUB checks intentionally skipped (see 15-grub-theme.sh's header; no systemd-boot theming is implemented in this pass)"
elif [[ -f /boot/loader/loader.conf ]]; then
    check_pass "systemd-boot loader.conf detected — no GRUB boot menu on this system, GRUB checks intentionally skipped"
else
    check_warn "Neither GRUB nor systemd-boot was detected — cannot verify bootloader theming either way"
fi

# Check 3: OS identity — this backend intentionally does not rewrite
# /etc/os-release (see apply-ci-os-desktop.sh's header), so just confirm
# Arch's own native ID is intact rather than expecting CI branding there.
log_info "Checking OS identity..."

if [[ -f "/etc/os-release" ]]; then
    if grep -qE '^ID=arch' /etc/os-release 2>/dev/null; then
        check_pass "Machine OS ID is arch (pacman-tooling compatible)"
    else
        check_warn "ID=arch not found in /etc/os-release — verify this is actually an Arch host"
    fi
    check_pass "os-release branding rewrite intentionally skipped on Arch (see apply-ci-os-desktop.sh header)"
else
    check_fail "/etc/os-release not found"
fi

# Check 4: GNOME theme configuration (system dconf overrides written by
# 28-gdm-accent-branding.sh — NOT 20-dconf-system.sh's own 01- fragment,
# which still carries the hardcoded-Yaru values this file's overlay exists
# to correct; see that script's header)
log_info "Checking GNOME accent-color / theme configuration..."

ARCH_DCONF_FILE="/etc/dconf/db/local.d/05-ci-os-arch-overrides"
if [[ -f "$ARCH_DCONF_FILE" ]]; then
    if grep -q "accent-color='teal'" "$ARCH_DCONF_FILE" 2>/dev/null; then
        check_pass "Arch dconf overrides set accent-color=teal"
    else
        check_warn "05-ci-os-arch-overrides exists but accent-color is not 'teal'"
    fi
    if grep -q "color-scheme='prefer-dark'" "$ARCH_DCONF_FILE" 2>/dev/null; then
        check_pass "Arch dconf overrides set color-scheme=prefer-dark"
    else
        check_warn "05-ci-os-arch-overrides exists but color-scheme is not 'prefer-dark'"
    fi
    if grep -q "gtk-theme='Adwaita'" "$ARCH_DCONF_FILE" 2>/dev/null; then
        check_pass "Arch dconf overrides restore gtk-theme=Adwaita (correcting the reused mixin's Yaru default)"
    else
        check_warn "05-ci-os-arch-overrides exists but gtk-theme is not 'Adwaita'"
    fi
else
    check_warn "Arch dconf overrides not found (expected $ARCH_DCONF_FILE — run: sudo backends/arch/desktop-theme/apply-ci-os-desktop.sh --only accent)"
fi

if [[ -f "/etc/dconf/db/local.d/01-ci-os-gnome-defaults" ]]; then
    check_pass "Reused GNOME dconf defaults present (background colors, dock, power, privacy)"
else
    check_warn "Reused GNOME dconf defaults not found (expected /etc/dconf/db/local.d/01-ci-os-gnome-defaults — run: sudo backends/arch/desktop-theme/apply-ci-os-desktop.sh --only dconf)"
fi

if command -v gsettings >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    CURRENT_ACCENT=$(gsettings get org.gnome.desktop.interface accent-color 2>/dev/null | tr -d "'" || true)
    if [[ "$CURRENT_ACCENT" == "teal" ]]; then
        check_pass "Live GNOME accent-color is teal"
    else
        check_warn "Live GNOME accent-color is: $CURRENT_ACCENT (expected teal — accent-color requires GNOME 47+; older GNOME silently ignores this key)"
    fi

    CURRENT_SCHEME=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d "'" || true)
    if [[ "$CURRENT_SCHEME" == "prefer-dark" ]]; then
        check_pass "Live GNOME color-scheme is prefer-dark"
    else
        check_warn "Live GNOME color-scheme is: $CURRENT_SCHEME (expected prefer-dark)"
    fi

    PRIMARY_COLOR=$(gsettings get org.gnome.desktop.background primary-color 2>/dev/null | tr -d "'" || true)
    if [[ "${PRIMARY_COLOR,,}" == *"${CI_LIGHT_PRIMARY#\#}"* ]]; then
        check_pass "GNOME background primary color is the CI canon primary ($CI_LIGHT_PRIMARY)"
    else
        check_warn "GNOME background primary color: $PRIMARY_COLOR (expected $CI_LIGHT_PRIMARY)"
    fi
else
    check_warn "Cannot check live GNOME settings (not in graphical session or gsettings not available)"
fi

# Check 5: GDM dconf profile override
log_info "Checking GDM theme configuration..."

if [[ -f "/etc/dconf/db/gdm.d/05-ci-os-arch-overrides" ]] || [[ -f "/etc/dconf/db/gdm.d/01-ci-os-gdm" ]]; then
    check_pass "GDM dconf configuration exists"
else
    check_warn "GDM dconf configuration not found (login screen may not be themed — OK if /etc/dconf/profile/gdm has no system-db:gdm line on this install, or if GDM isn't installed at all — see provision.sh's check_desktop_prereqs())"
fi

# Check 6: Wallpaper (installed by Ubuntu's fully-portable 30-wallpaper.sh)
log_info "Checking wallpaper..."

if [[ -f "/usr/share/backgrounds/ci-os-wallpaper.png" ]]; then
    check_pass "CI OS wallpaper installed"
else
    check_warn "CI OS wallpaper not found at /usr/share/backgrounds/ci-os-wallpaper.png"
fi

# Check 7: MOTD (Message of the Day) — shared render-motd.sh, same as
# Ubuntu/Mint/Fedora. See apply-ci-os-desktop.sh's header: whether Arch's
# stock PAM/openssh actually displays /etc/update-motd.d content at login
# was not independently verified for this pass, so this warns rather than
# fails, same as Fedora's check.
log_info "Checking MOTD configuration..."

if [[ -f "/etc/update-motd.d/00-ci-header" ]]; then
    if grep -q "CI OS" /etc/update-motd.d/00-ci-header 2>/dev/null; then
        check_pass "CI OS MOTD header file exists"
    else
        check_warn "MOTD header exists but may not have CI branding"
    fi
    check_warn "Whether Arch's stock SSH/login actually renders /etc/update-motd.d content was not verified for this backend — confirm at an actual login before relying on it"
else
    check_warn "CI OS MOTD header not found"
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

_APPLY_HINT="sudo $REPO_ROOT/backends/arch/desktop-theme/apply-ci-os-desktop.sh"

if [[ $FAIL_COUNT -eq 0 ]] && [[ $WARN_COUNT -eq 0 ]]; then
    echo -e "${GREEN}All checks passed.${NC}"
    exit 0
elif [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${YELLOW}Theme mostly applied. Check warnings above.${NC}"
    echo "Some checks may warn if you have not rebooted yet, are not in a graphical session, or are on a systemd-boot system (expected, not a failure)."
    exit 0
else
    echo -e "${RED}Theme validation failed. See errors above.${NC}"
    echo ""
    echo "To apply or repair branding, run:"
    echo "  $_APPLY_HINT"
    echo ""
    exit 1
fi
