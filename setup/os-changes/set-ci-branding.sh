#!/bin/bash
#
# CI Branding for Plymouth Boot Theme, Login Screen & User Defaults
#
# Replaces Plymouth boot splash theme files with CI-branded assets.
# Sets default theme to dark green/teal for login screen and user sessions.
# Our brand uses teal, dark green, aquamarine, and black colors.
# Removes all Ubuntu references from Plymouth themes.
#
# This script:
# - Replaces watermark.png in the Plymouth spinner theme (resized to 50% for smaller boot logo)
# - Updates spinner.plymouth, bgrt.plymouth with CI colors (no Ubuntu refs)
# - Updates ubuntu-text.plymouth (text fallback) with CI OS title and colors
# - Ensures default.plymouth and text.plymouth point to CI-themed variants
# - Sets GDM login screen and user default to dark green (Yaru-prussiangreen-dark)
# - Applies same theme/desktop settings as configs/desktop/gnome-settings.sh to current user
#
# Usage: sudo ./set-ci-branding.sh
# Requirements: Root/sudo access. ImageMagick (apt install imagemagick) for logo scaling.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Paths: same directory as this script (repo is moved together)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGO_SOURCE="$SCRIPT_DIR/Logo_Banner_Color.png"
PLYMOUTH_SPINNER_DIR="/usr/share/plymouth/themes/spinner"

# Watermark scaling: make logo smaller on boot screen (Plymouth uses image at native size)
# Set to 50 = 50% of original, 75 = 75%, etc. Use 100 to disable scaling.
WATERMARK_SCALE_PERCENT=50
WATERMARK_DEST="$PLYMOUTH_SPINNER_DIR/watermark.png"
PLYMOUTH_UBUNTU_TEXT_DIR="/usr/share/plymouth/themes/ubuntu-text"
UBUNTU_TEXT_PLYMOUTH="$PLYMOUTH_UBUNTU_TEXT_DIR/ubuntu-text.plymouth"
PLYMOUTH_SPINNER_CONF="$PLYMOUTH_SPINNER_DIR/spinner.plymouth"
PLYMOUTH_BGRT_CONF="/usr/share/plymouth/themes/bgrt/bgrt.plymouth"

# CI color scheme: Official dark green palette
# Primary Dark Green: #066c80, Medium Green: #00a9a7, Light Green: #72ddd4
BG_DARK_GREEN="0x066c80"     # Primary dark green background
PROGRESS_BG="0x1b4332"       # Deep green for progress background
PROGRESS_FG="0x00a9a7"       # Medium green for progress foreground

# GNOME/GDM theme (dark green - matches our brand)
# Fallback order: prussiangreen > sage > viridian > dark
if [[ -d /usr/share/themes/Yaru-prussiangreen-dark ]]; then
    CI_GTK_THEME="Yaru-prussiangreen-dark"
elif [[ -d /usr/share/themes/Yaru-sage-dark ]]; then
    CI_GTK_THEME="Yaru-sage-dark"
elif [[ -d /usr/share/themes/Yaru-viridian-dark ]]; then
    CI_GTK_THEME="Yaru-viridian-dark"
else
    CI_GTK_THEME="Yaru-dark"
fi

if [[ ! -f "$LOGO_SOURCE" ]]; then
    log_error "Logo file not found: $LOGO_SOURCE"
    log_info "Expected: repo/setup/os-changes/Logo_Banner_Color.png"
    exit 1
fi

if [[ ! -d "$PLYMOUTH_SPINNER_DIR" ]]; then
    log_error "Plymouth spinner theme directory not found: $PLYMOUTH_SPINNER_DIR"
    log_info "Is Plymouth installed? Try: apt install plymouth-theme-spinner"
    exit 1
fi

# --- Replace watermark.png ---
log_info "Replacing Plymouth watermark with CI branding..."
log_info "Source: $LOGO_SOURCE"
log_info "Destination: $WATERMARK_DEST"

# Backup existing watermark if present
BACKUP_DIR="/usr/share/plymouth/ci-branding-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
if [[ -f "$WATERMARK_DEST" ]]; then
    cp "$WATERMARK_DEST" "$BACKUP_DIR/watermark.png.bak"
    log_info "Backup created: $BACKUP_DIR/watermark.png.bak"
fi

# Copy our logo as watermark.png (resized smaller for boot screen)
if [[ "$WATERMARK_SCALE_PERCENT" -lt 100 ]] && command -v convert >/dev/null 2>&1; then
    convert "$LOGO_SOURCE" -resize "${WATERMARK_SCALE_PERCENT}%" "$WATERMARK_DEST"
    log_success "Resized Logo_Banner_Color.png (${WATERMARK_SCALE_PERCENT}%) → watermark.png"
elif [[ "$WATERMARK_SCALE_PERCENT" -lt 100 ]] && command -v magick >/dev/null 2>&1; then
    magick "$LOGO_SOURCE" -resize "${WATERMARK_SCALE_PERCENT}%" "$WATERMARK_DEST"
    log_success "Resized Logo_Banner_Color.png (${WATERMARK_SCALE_PERCENT}%) → watermark.png"
else
    if [[ "$WATERMARK_SCALE_PERCENT" -lt 100 ]]; then
        log_warn "ImageMagick not found (install: apt install imagemagick). Copying at full size."
    fi
    cp "$LOGO_SOURCE" "$WATERMARK_DEST"
    log_success "Copied Logo_Banner_Color.png → watermark.png"
fi
chmod 644 "$WATERMARK_DEST"

# --- Update spinner.plymouth (CI colors: dark green bg, teal progress bar) ---
if [[ -f "$PLYMOUTH_SPINNER_CONF" ]]; then
    cp "$PLYMOUTH_SPINNER_CONF" "$BACKUP_DIR/spinner.plymouth.bak"
    sed -i "s/BackgroundStartColor=0x[0-9a-fA-F]*/BackgroundStartColor=$BG_DARK_GREEN/" "$PLYMOUTH_SPINNER_CONF"
    sed -i "s/BackgroundEndColor=0x[0-9a-fA-F]*/BackgroundEndColor=$BG_DARK_GREEN/" "$PLYMOUTH_SPINNER_CONF"
    sed -i "s/ProgressBarBackgroundColor=0x[0-9a-fA-F]*/ProgressBarBackgroundColor=$PROGRESS_BG/" "$PLYMOUTH_SPINNER_CONF"
    sed -i "s/ProgressBarForegroundColor=0x[0-9a-fA-F]*/ProgressBarForegroundColor=$PROGRESS_FG/" "$PLYMOUTH_SPINNER_CONF"
    log_success "Updated spinner.plymouth with CI colors (dark green, teal)"
fi

# --- Update bgrt.plymouth (CI colors, remove Ubuntu font refs) ---
if [[ -f "$PLYMOUTH_BGRT_CONF" ]]; then
    cp "$PLYMOUTH_BGRT_CONF" "$BACKUP_DIR/bgrt.plymouth.bak"
    sed -i "s/Font=Ubuntu 12/Font=Cantarell 12/" "$PLYMOUTH_BGRT_CONF"
    sed -i "s/TitleFont=Ubuntu Light 30/TitleFont=Cantarell Light 30/" "$PLYMOUTH_BGRT_CONF"
    sed -i "s/BackgroundStartColor=0x[0-9a-fA-F]*/BackgroundStartColor=$BG_DARK_GREEN/" "$PLYMOUTH_BGRT_CONF"
    sed -i "s/BackgroundEndColor=0x[0-9a-fA-F]*/BackgroundEndColor=$BG_DARK_GREEN/" "$PLYMOUTH_BGRT_CONF"
    sed -i "s/ProgressBarBackgroundColor=0x[0-9a-fA-F]*/ProgressBarBackgroundColor=$PROGRESS_BG/" "$PLYMOUTH_BGRT_CONF"
    sed -i "s/ProgressBarForegroundColor=0x[0-9a-fA-F]*/ProgressBarForegroundColor=$PROGRESS_FG/" "$PLYMOUTH_BGRT_CONF"
    log_success "Updated bgrt.plymouth with CI colors, Cantarell font (no Ubuntu refs)"
fi

# --- Replace ubuntu-text.plymouth (title and colors) ---
if [[ -f "$UBUNTU_TEXT_PLYMOUTH" ]]; then
    log_info "Updating ubuntu-text.plymouth with CI OS branding..."
    cp "$UBUNTU_TEXT_PLYMOUTH" "$BACKUP_DIR/ubuntu-text.plymouth.bak"
    log_info "Backup created: $BACKUP_DIR/ubuntu-text.plymouth.bak"

    # CI OS color scheme: Official dark green palette
    # black=background, white=light green (main text), brown=medium green, blue=primary dark green
    cat > "$UBUNTU_TEXT_PLYMOUTH" <<'PLYMOUTH_EOF'
[Plymouth Theme]
Name=CI OS Text
Description=Text mode theme with CI OS branding
ModuleName=ubuntu-text

[ubuntu-text]
title=CI OS 0.0.1
black=0x000000
white=0x72ddd4
brown=0x00a9a7
blue=0x066c80
PLYMOUTH_EOF
    chmod 644 "$UBUNTU_TEXT_PLYMOUTH"
    log_success "Updated ubuntu-text.plymouth: title=CI OS 0.0.1, colors=teal/green/aquamarine/black"
else
    log_warn "ubuntu-text.plymouth not found: $UBUNTU_TEXT_PLYMOUTH (is plymouth-theme-ubuntu-text installed?)"
fi

# --- Ensure default.plymouth and text.plymouth point to CI-themed variants ---
# default.plymouth -> bgrt (graphical boot, uses our spinner assets + colors)
# text.plymouth -> ubuntu-text (text fallback, we've replaced its content)
if command -v update-alternatives >/dev/null 2>&1; then
    if update-alternatives --list default.plymouth 2>/dev/null | grep -q "bgrt"; then
        update-alternatives --set default.plymouth /usr/share/plymouth/themes/bgrt/bgrt.plymouth 2>/dev/null || true
    fi
    if [[ -f "$UBUNTU_TEXT_PLYMOUTH" ]] && update-alternatives --list text.plymouth 2>/dev/null | grep -q "ubuntu-text"; then
        update-alternatives --set text.plymouth "$UBUNTU_TEXT_PLYMOUTH" 2>/dev/null || true
    fi
    log_info "Plymouth theme selection: default=bgrt, text=ubuntu-text (CI-themed)"
fi

# --- Set GDM login screen and user default to dark green theme ---
# Using official CI dark green color palette
CI_THEME_COLORS="066c80"  # Primary dark green for lock screen / accent
CI_SECONDARY_COLOR="1b4332"  # Deep green for secondary elements
if [[ -d "/etc/dconf" ]]; then
    mkdir -p /etc/dconf/db/local.d

    # User defaults: GTK theme, icon theme, colors (new users + lock screen)
    cat > /etc/dconf/db/local.d/01-ci-theme <<DCONF_EOF
[org/gnome/desktop/interface]
gtk-theme='$CI_GTK_THEME'
icon-theme='Yaru'
cursor-theme='Yaru'

[org/gnome/desktop/background]
primary-color='#$CI_THEME_COLORS'
secondary-color='#1b4332'

# Enable GNOME Remote Desktop (screen sharing and remote control)
[org/gnome/desktop/remote-desktop]
screen-sharing-enabled=true
remote-control-enabled=true

[org/gnome/desktop/remote-desktop/rdp]
enabled=true
view-only=false
DCONF_EOF

    # GDM login screen: Ubuntu uses system-db:gdm when /etc/dconf/profile/gdm exists
    GDM_DB="/etc/dconf/db/gdm.d"
    if grep -q "system-db:gdm" /etc/dconf/profile/gdm 2>/dev/null; then
        mkdir -p "$GDM_DB"
        cat > "$GDM_DB/01-ci-theme" <<GDM_EOF
[org/gnome/desktop/interface]
gtk-theme='$CI_GTK_THEME'

[org/gnome/desktop/background]
primary-color='#$CI_THEME_COLORS'
secondary-color='#$CI_SECONDARY_COLOR'

    [org/gnome/desktop/remote-desktop]
    screen-sharing-enabled=true
    remote-control-enabled=true

    [org/gnome/desktop/remote-desktop/rdp]
    enabled=true
    view-only=false
GDM_EOF
    fi

    if command -v dconf >/dev/null 2>&1; then
        dconf update 2>/dev/null || true
        log_success "Set default theme to $CI_GTK_THEME (login + new users)"
    fi
else
    log_warn "dconf not found; set manually: gsettings set org.gnome.desktop.interface gtk-theme '$CI_GTK_THEME'"
fi

# --- Apply theme/desktop settings to current user (matches gnome-settings.sh for Cubic) ---
# Same variables as configs/desktop/gnome-settings.sh, for standalone setup flow
ACTUAL_USER="${SUDO_USER:-}"
[[ -z "$ACTUAL_USER" || "$ACTUAL_USER" == "root" ]] && ACTUAL_USER="$(who -u 2>/dev/null | awk '{print $1; exit}' || true)"

if command -v gsettings >/dev/null 2>&1 && [[ -n "$ACTUAL_USER" ]] && [[ "$ACTUAL_USER" != "root" ]]; then
    UID_NUM="$(id -u "$ACTUAL_USER" 2>/dev/null || true)"
    RUNTIME_DIR="/run/user/${UID_NUM}"
    DBUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus"

    if [[ -S "${RUNTIME_DIR}/bus" ]]; then
        log_info "Applying theme to current user: $ACTUAL_USER"
        _gset() { sudo -u "$ACTUAL_USER" env DISPLAY=:0 XAUTHORITY="/home/$ACTUAL_USER/.Xauthority" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" gsettings set "$1" "$2" "$3" 2>/dev/null || true; }
        _gset org.gnome.desktop.interface gtk-theme "$CI_GTK_THEME"
        _gset org.gnome.desktop.interface icon-theme "Yaru"
        _gset org.gnome.desktop.interface cursor-theme "Yaru"
        _gset org.gnome.desktop.background primary-color "#066c80"
        _gset org.gnome.desktop.background secondary-color "#1b4332"
        _gset org.gnome.shell.extensions.dash-to-dock dock-fixed false
        _gset org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'
        _gset org.gnome.shell.extensions.dash-to-dock extend-height false
        _gset org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 48
        _gset org.gnome.desktop.wm.preferences button-layout "close,minimize,maximize:"
        _gset org.gnome.desktop.wm.preferences focus-mode "click"
        _gset org.gnome.shell favorite-apps "['org.gnome.Nautilus.desktop', 'firefox.desktop', 'org.gnome.Terminal.desktop', 'code.desktop', 'steam.desktop', 'org.gnome.Settings.desktop']"
        _gset org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
        _gset org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 1800
        _gset org.gnome.desktop.privacy disable-microphone false
        _gset org.gnome.desktop.privacy disable-camera false
        _gset org.gnome.Terminal.Legacy.Settings default-show-menubar false
        _gset org.gnome.Terminal.Legacy.Settings theme-variant 'dark'
            # Enable GNOME Remote Desktop (screen sharing and remote control) for current user
            _gset org.gnome.desktop.remote-desktop screen-sharing-enabled true
            _gset org.gnome.desktop.remote-desktop remote-control-enabled true
            _gset org.gnome.desktop.remote-desktop.rdp enabled true
            _gset org.gnome.desktop.remote-desktop.rdp view-only false
        log_success "Applied theme and desktop settings to $ACTUAL_USER"
    else
        log_warn "No D-Bus session for $ACTUAL_USER (not logged in?). Theme will apply on next login via dconf defaults."
    fi
fi

# Regenerate initramfs so Plymouth picks up the new image
if command -v update-initramfs >/dev/null 2>&1; then
    log_info "Regenerating initramfs for Plymouth..."
    if update-initramfs -u -k all 2>/dev/null; then
        log_success "Initramfs updated. New branding will appear on next boot."
    else
        log_warn "update-initramfs had issues. You may need to run manually: sudo update-initramfs -u"
    fi
else
    log_warn "update-initramfs not found. Plymouth changes may not take effect until initramfs is regenerated."
fi

log_success "CI branding applied. Backup: $BACKUP_DIR"
log_info "Plymouth: Official CI dark green (#066c80, #00a9a7, #72ddd4) | GNOME: $CI_GTK_THEME"
log_info ""
log_info "For complete CI OS rebranding, also run:"
log_info "  sudo ./update-os-release.sh   # Update /etc/os-release identity"
log_info "  sudo ./setup-ci-motd.sh       # Replace Ubuntu MOTD with CI OS welcome"
log_info ""
log_info "Reboot recommended to see Plymouth boot splash changes"
