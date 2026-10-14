#!/usr/bin/env bash
#
# Companion OS Theme Validation (read-only checks).
#
# Usage:
#   ./apply-ci-os-desktop.sh --validate
#   bash backends/ubuntu/desktop-theme/80-validate-ci-theme.sh
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
echo " Companion OS Theme Validation"
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

# Check 2b: GRUB Theme
log_info "Checking GRUB theme..."

if [[ -f "/usr/share/pixmaps/ci-os-grub-bg.png" ]]; then
    check_pass "GRUB background image installed"
else
    check_warn "GRUB background image not found (run: sudo backends/ubuntu/desktop-theme/15-grub-theme.sh)"
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

# Check 3: OS Release Information
log_info "Checking OS identity..."

if [[ -f "/etc/os-release" ]]; then
    if grep -q "Companion OS" /etc/os-release 2>/dev/null; then
        check_pass "/etc/os-release shows Companion OS identity"
    else
        check_fail "/etc/os-release still shows Ubuntu branding"
    fi

    if grep -qE '^ID=ubuntu' /etc/os-release 2>/dev/null; then
        check_pass "Machine OS ID is ubuntu (apt/ROCm compatible)"
    elif grep -q "ID=ci-os" /etc/os-release 2>/dev/null; then
        check_warn "OS ID is ci-os — run backends/ubuntu/desktop-theme/50-os-release.sh to restore Ubuntu-compatible ID"
    else
        check_warn "Unexpected OS ID in /etc/os-release"
    fi

    if grep -qE '^CI_OS_ID=ci-os' /etc/os-release 2>/dev/null; then
        check_pass "CI_OS_ID=ci-os branding field present"
    fi

    if grep -qE '^UBUNTU_CODENAME=(noble|resolute|jammy)' /etc/os-release 2>/dev/null; then
        check_pass "UBUNTU_CODENAME set to a real Ubuntu suite"
    else
        check_warn "UBUNTU_CODENAME missing or set to marketing codename 'ci'"
    fi
else
    check_fail "/etc/os-release not found"
fi

# Check 4: GNOME Theme Settings
log_info "Checking GNOME theme configuration..."

if command -v gsettings >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    CURRENT_THEME=$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'" || true)
    if [[ "$CURRENT_THEME" == *"prussiangreen"* ]] || [[ "$CURRENT_THEME" == *"sage"* ]] || [[ "$CURRENT_THEME" == *"viridian"* ]]; then
        check_pass "GNOME theme is dark green variant: $CURRENT_THEME"
    else
        check_warn "GNOME theme is: $CURRENT_THEME (expected dark green variant)"
    fi

    PRIMARY_COLOR=$(gsettings get org.gnome.desktop.background primary-color 2>/dev/null | tr -d "'" || true)
    if [[ "${PRIMARY_COLOR,,}" == *"${CI_LIGHT_PRIMARY#\#}"* ]]; then
        check_pass "GNOME background primary color is the CI canon primary ($CI_LIGHT_PRIMARY)"
    else
        check_warn "GNOME background primary color: $PRIMARY_COLOR (expected $CI_LIGHT_PRIMARY)"
    fi
else
    check_warn "Cannot check GNOME settings (not in graphical session or gsettings not available)"
fi

# Check 5: GDM/dconf system settings
log_info "Checking GDM theme configuration..."

if [[ -f "/etc/dconf/db/local.d/01-ci-os-gnome-defaults" ]]; then
    if grep -qi "${CI_LIGHT_PRIMARY#\#}" /etc/dconf/db/local.d/01-ci-os-gnome-defaults 2>/dev/null; then
        check_pass "dconf system theme configured with the CI canon primary"
    else
        check_warn "dconf system defaults exist but may not have CI colors"
    fi
else
    check_warn "dconf system defaults not found (expected /etc/dconf/db/local.d/01-ci-os-gnome-defaults)"
fi

if [[ -f "/etc/dconf/db/gdm.d/01-ci-os-gdm" ]] || [[ -f "/etc/dconf/db/gdm.d/01-ci-theme" ]]; then
    check_pass "GDM theme configuration exists"
else
    check_warn "GDM theme configuration not found (login screen may not be themed)"
fi

if command -v gsettings >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    DOCK_POS=$(gsettings get org.gnome.shell.extensions.dash-to-dock dock-position 2>/dev/null | tr -d "'" || true)
    DOCK_AUTO=$(gsettings get org.gnome.shell.extensions.dash-to-dock autohide 2>/dev/null | tr -d "'" || true)
    if [[ "$DOCK_POS" == "LEFT" ]] && [[ "$DOCK_AUTO" == "true" ]]; then
        check_pass "Dock on left with autohide (dismissable)"
    else
        check_warn "Dock position=$DOCK_POS autohide=$DOCK_AUTO (expected LEFT + true)"
    fi
fi

# Check 6: MOTD (Message of the Day)
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

if grep -i "ubuntu" /etc/os-release 2>/dev/null | grep -v "ID_LIKE\|CODENAME" | grep -q "ubuntu"; then
    check_warn "Found 'Ubuntu' reference in /etc/os-release"
    UBUNTU_FOUND=1
fi

if grep -qi "ubuntu" /usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth 2>/dev/null; then
    if ! grep -q "Companion OS" /usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth 2>/dev/null; then
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
    check_pass "Companion OS wallpaper installed"
else
    check_warn "Companion OS wallpaper not found at /usr/share/backgrounds/ci-os-wallpaper.png"
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

# Check 9b: Settings > About logo, dock start icon, LOGO icon, greeter logo
log_info "Checking About logo, start icon, LOGO icon and greeter logo..."

# What "the canon mark" means is derived from the vendored files (vendor/brand), not from literals: the tokens
# for the colours, mark.svg for the artwork. The PNG pixels are read with backends/ubuntu/lib/png-colours.py
# (python3, standard library); without it the content checks are skipped with a warning.
CANON_MARK="$REPO_ROOT/vendor/brand/logos/mark.svg"
PNGTOOL="$REPO_ROOT/backends/ubuntu/lib/png-colours.py"
CAN_READ_PNG=0
if [[ -f "$CANON_MARK" && -f "$PNGTOOL" ]] && command -v python3 >/dev/null 2>&1; then CAN_READ_PNG=1; fi

# canon_png_check <label> <png> <solid|palette> <colours>: the opaque pixels are exactly those colours.
canon_png_check() {
    local msg
    if [[ $CAN_READ_PNG -eq 0 ]]; then
        check_warn "$1: content not checked (needs python3 and the repo's vendor/brand)"
    elif msg="$(python3 -I "$PNGTOOL" "$3" "$2" "$4" 2>&1)"; then
        check_pass "$1: $msg"
    else
        check_fail "$1: $msg"
    fi
}

# 40-start-icon.sh builds the icon from the vendored one-colour mark: every path of mark.svg, currentColor, and none
# of the logo artwork's colours (GTK repaints a -symbolic icon, brand hexes belong in the artwork only).
YARU_START="/usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg"
if [[ -f "$YARU_START" ]]; then
    if grep -q 'viewBox="0 0 16 16"' "$YARU_START" 2>/dev/null || [[ ! -f "$CANON_MARK" ]]; then
        check_warn "Yaru start-here-symbolic.svg is still Ubuntu's, or cannot be compared (run: apply-ci-os-desktop.sh --only start-icon)"
    else
        start_paths=0; start_missing=0
        while IFS= read -r dattr; do
            start_paths=$((start_paths + 1))
            grep -qF -- "$dattr" "$YARU_START" || start_missing=$((start_missing + 1))
        done < <(grep -o ' d="[^"]*"' "$CANON_MARK")
        start_ramp=""
        while IFS= read -r hex; do
            if grep -qi -- "$hex" "$YARU_START"; then start_ramp="$start_ramp $hex"; fi
        done < <(grep -o 'fill:#[0-9a-fA-F]\{6\}' "$CANON_MARK" | sed 's/fill://')
        if [[ $start_paths -ge 1 && $start_missing -eq 0 && -z "$start_ramp" ]]; then
            check_pass "Yaru start-here-symbolic.svg is the vendored Companion mark, all $start_paths paths, no artwork colours (dock Show Applications button)"
        elif [[ -n "$start_ramp" ]]; then
            check_fail "Yaru start-here-symbolic.svg ships logo artwork colours:$start_ramp (run: apply-ci-os-desktop.sh --only start-icon)"
        else
            check_warn "Yaru start-here-symbolic.svg lacks $start_missing of the $start_paths paths of the vendored mark (run: apply-ci-os-desktop.sh --only start-icon)"
        fi
    fi
fi

# Settings > About: the one-colour mark in the canon primary of each mode.
for about_pair in "ubuntu-logo-text.png:light:$CI_LIGHT_PRIMARY" "ubuntu-logo-text-dark.png:dark:$CI_DARK_PRIMARY"; do
    about_logo="${about_pair%%:*}"; about_rest="${about_pair#*:}"; about_mode="${about_rest%%:*}"; about_fill="${about_rest##*:}"
    if [[ ! -f "/usr/share/pixmaps/$about_logo" ]]; then
        check_warn "Settings > About logo not found: /usr/share/pixmaps/$about_logo"
    elif command -v dpkg-divert >/dev/null 2>&1 && [[ -n "$(dpkg-divert --list "/usr/share/pixmaps/$about_logo" 2>/dev/null)" ]]; then
        check_pass "Settings > About logo replaced, stock file diverted: $about_logo"
        canon_png_check "Settings > About logo $about_logo ($about_mode mode)" "/usr/share/pixmaps/$about_logo" solid "${about_fill#\#}"
    else
        check_warn "Settings > About logo is still Ubuntu's: $about_logo (needs rsvg-convert or ImageMagick: apt-get install librsvg2-bin, then apply-ci-os-desktop.sh --only about-logo)"
    fi
done

if [[ -f "/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg" ]]; then
    if [[ ! -f "$CANON_MARK" ]]; then
        check_pass "ci-os-logo icon installed (os-release LOGO=ci-os-logo resolves)"
    elif cmp -s "/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg" "$CANON_MARK"; then
        check_pass "ci-os-logo icon installed and equal to the vendored mark (os-release LOGO=ci-os-logo resolves)"
    else
        check_fail "ci-os-logo icon differs from vendor/brand/logos/mark.svg (run: apply-ci-os-desktop.sh --only about-logo)"
    fi
else
    check_warn "ci-os-logo icon not found at /usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
fi

# The greeter logo exists on images built by customize-chroot.sh (its gdm dconf logo= key names the file),
# not on a desktop re-skinned by apply-ci-os-desktop.sh. It is the 256 px colour mark (about 12 KB); the pre-canon
# hologram it replaced was 1.6 MB. Its opaque pixels are exactly the three tones of the vendored mark.svg.
if grep -qs "^logo='/usr/share/pixmaps/companion-logo.png'" /etc/dconf/db/gdm.d/01-ci-os-login; then
    if [[ ! -f "/usr/share/pixmaps/companion-logo.png" ]]; then
        check_warn "Greeter logo not found at /usr/share/pixmaps/companion-logo.png"
    elif [[ "$(wc -c < /usr/share/pixmaps/companion-logo.png)" -ge 200000 ]]; then
        check_warn "Greeter logo at /usr/share/pixmaps/companion-logo.png looks like the old hologram image"
    elif [[ -f "$CANON_MARK" ]]; then
        greeter_ramp="$(grep -o 'fill:#[0-9a-fA-F]\{6\}' "$CANON_MARK" | sed 's/fill:#//' | tr 'A-F' 'a-f' | sort -u | paste -sd, - || true)"
        canon_png_check "Greeter logo companion-logo.png" /usr/share/pixmaps/companion-logo.png palette "$greeter_ramp"
    else
        check_pass "Greeter logo installed"
    fi
fi

# Check 10: Brand Assets
log_info "Checking brand assets..."

if [[ -f "$REPO_ROOT/vendor/brand/SHA256SUMS" ]]; then
    if "$REPO_ROOT/core/lib/vendor-brand.sh" --check >/dev/null 2>&1; then
        check_pass "Vendored brand bundle matches its SHA256SUMS (ci-brand $(cat "$REPO_ROOT/vendor/brand/.version"))"
    else
        check_fail "Vendored brand bundle does not match SHA256SUMS — run core/lib/vendor-brand.sh"
    fi
    if grep -q "066c80" "$REPO_ROOT/assets/branding/brand-guidelines.md" 2>/dev/null; then
        check_fail "brand-guidelines.md still names the logo ramp #066c80 as the brand colour"
    else
        check_pass "brand-guidelines.md points at the canon"
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

_APPLY_HINT="sudo $REPO_ROOT/backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh"

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
