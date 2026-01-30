#!/bin/bash
#
# Ubuntu Desktop Wallpaper Replacement Script
#
# Sets the current user's desktop background to the CI-OS wallpaper.
# Uses the image in this repo: setup/os-changes/background.png
#
# Usage: sudo ./replace-wallpaper.sh
# Requirements: Root/sudo access (to copy to /usr/share/backgrounds and set dconf defaults)
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

# Wallpaper path: same directory as this script (repo is moved together)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WALLPAPER_PATH="$SCRIPT_DIR/background.png"

if [[ ! -f "$WALLPAPER_PATH" ]]; then
    log_error "Wallpaper file not found: $WALLPAPER_PATH"
    log_info "Expected: repo/setup/os-changes/background.png"
    exit 1
fi

WALLPAPER_EXT="${WALLPAPER_PATH##*.}"
WALLPAPER_NAME="ci-os-wallpaper"
DEST_WALLPAPER="/usr/share/backgrounds/${WALLPAPER_NAME}.${WALLPAPER_EXT}"

log_info "Setting custom desktop wallpaper..."
log_info "Source: $WALLPAPER_PATH"
log_info "Destination: $DEST_WALLPAPER"

# Backup existing if present
BACKUP_DIR="/usr/share/backgrounds/ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
if [[ -f "$DEST_WALLPAPER" ]]; then
    cp "$DEST_WALLPAPER" "$BACKUP_DIR/${WALLPAPER_NAME}.${WALLPAPER_EXT}.bak"
    log_info "Backup created in $BACKUP_DIR"
fi

# Copy to system backgrounds
mkdir -p /usr/share/backgrounds
cp "$WALLPAPER_PATH" "$DEST_WALLPAPER"
chmod 644 "$DEST_WALLPAPER"
log_success "Copied wallpaper to $DEST_WALLPAPER"

# Current user (the one who ran sudo)
ACTUAL_USER="${SUDO_USER:-}"
if [[ -z "$ACTUAL_USER" ]] || [[ "$ACTUAL_USER" == "root" ]]; then
    ACTUAL_USER="$(who -u 2>/dev/null | awk '{print $1; exit}' || true)"
fi

# Set wallpaper for current user via gsettings (requires their D-Bus session)
if command -v gsettings >/dev/null 2>&1 && [[ -n "$ACTUAL_USER" ]] && [[ "$ACTUAL_USER" != "root" ]]; then
    UID_NUM="$(id -u "$ACTUAL_USER" 2>/dev/null || true)"
    RUNTIME_DIR="/run/user/${UID_NUM}"
    DBUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus"

    if [[ -S "${RUNTIME_DIR}/bus" ]]; then
        log_info "Setting wallpaper for user: $ACTUAL_USER (via session D-Bus)"
        if sudo -u "$ACTUAL_USER" env \
            DISPLAY=:0 \
            XAUTHORITY="/home/$ACTUAL_USER/.Xauthority" \
            DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" \
            gsettings set org.gnome.desktop.background picture-uri "file://$DEST_WALLPAPER" 2>/dev/null; then
            log_success "Set picture-uri for $ACTUAL_USER"
        else
            log_warn "Could not set picture-uri for $ACTUAL_USER (is a graphical session active?)"
        fi
        if sudo -u "$ACTUAL_USER" env \
            DISPLAY=:0 \
            XAUTHORITY="/home/$ACTUAL_USER/.Xauthority" \
            DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" \
            gsettings set org.gnome.desktop.background picture-uri-dark "file://$DEST_WALLPAPER" 2>/dev/null; then
            log_success "Set picture-uri-dark for $ACTUAL_USER"
        else
            log_warn "Could not set picture-uri-dark for $ACTUAL_USER"
        fi
    else
        log_warn "No D-Bus session for $ACTUAL_USER (not logged in?). Set wallpaper manually:"
        log_info "  gsettings set org.gnome.desktop.background picture-uri 'file://$DEST_WALLPAPER'"
        log_info "  gsettings set org.gnome.desktop.background picture-uri-dark 'file://$DEST_WALLPAPER'"
    fi
else
    if ! command -v gsettings >/dev/null 2>&1; then
        log_warn "gsettings not available."
    elif [[ -z "$ACTUAL_USER" ]] || [[ "$ACTUAL_USER" == "root" ]]; then
        log_warn "Could not determine non-root user. Run as your user (no sudo) to set wallpaper:"
        log_info "  gsettings set org.gnome.desktop.background picture-uri 'file://$DEST_WALLPAPER'"
        log_info "  gsettings set org.gnome.desktop.background picture-uri-dark 'file://$DEST_WALLPAPER'"
    fi
fi

# System-wide defaults for new users
mkdir -p /etc/dconf/db/local.d
if cat > /etc/dconf/db/local.d/00-wallpaper <<EOF
[org/gnome/desktop/background]
picture-uri='file://$DEST_WALLPAPER'
picture-uri-dark='file://$DEST_WALLPAPER'
EOF
then
    if command -v dconf >/dev/null 2>&1; then
        dconf update 2>/dev/null || log_warn "dconf update had warnings"
        log_success "System-wide wallpaper defaults configured for new users"
    fi
else
    log_warn "Could not write dconf defaults"
fi

log_info "Wallpaper replacement completed. Backup: $BACKUP_DIR"
log_info "Wallpaper file: $DEST_WALLPAPER"
