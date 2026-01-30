#!/bin/bash
#
# Ubuntu Start Icon Replacement Script
#
# Replaces the Ubuntu "Show Apps" / Activities button icon with the CI-OS icon.
# Uses the icon in this repo: setup/os-changes/LogoMark_Color_StartIcon-cropped.svg
#
# Usage: sudo ./replace-start-icon.sh
# Requirements: Root/sudo access
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Icon path: same directory as this script (repo is moved together)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_ICON_PATH="$SCRIPT_DIR/LogoMark_Color_StartIcon-cropped.svg"

if [[ ! -f "$CUSTOM_ICON_PATH" ]]; then
    log_error "Icon file not found: $CUSTOM_ICON_PATH"
    log_info "Expected: repo/setup/os-changes/LogoMark_Color_StartIcon-cropped.svg"
    exit 1
fi

ICON_EXT="${CUSTOM_ICON_PATH##*.}"
ICON_NAME="ci-os-activities-icon"

log_info "Replacing Ubuntu Show Apps icon..."
log_info "Source icon: $CUSTOM_ICON_PATH"

# Create backup directory
BACKUP_DIR="/usr/share/icons/ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
log_info "Backup directory: $BACKUP_DIR"

# Replace start-here-symbolic.svg in every Yaru theme variant (Yaru, Yaru-dark, Yaru-light, etc.)
# Ubuntu Dock uses start-here-symbolic.svg in places/; view-app-grid-*-symbolic is a symlink to it.
REPLACED=0
for THEME_DIR in /usr/share/icons/Yaru*/scalable/places; do
    [[ -d "$THEME_DIR" ]] || continue
    ACTIVITIES_ICON="$THEME_DIR/start-here-symbolic.svg"
    THEME_NAME="$(basename "$(dirname "$(dirname "$(dirname "$THEME_DIR")")")")"

    if [[ ! -f "$ACTIVITIES_ICON" ]]; then
        log_warn "Icon not found in theme $THEME_NAME, skipping: $ACTIVITIES_ICON"
        continue
    fi

    # Backup
    mkdir -p "$BACKUP_DIR/$THEME_NAME/scalable/places"
    cp "$ACTIVITIES_ICON" "$BACKUP_DIR/$THEME_NAME/scalable/places/start-here-symbolic.svg.bak"

    if [[ "$ICON_EXT" =~ ^(svg|SVG)$ ]]; then
        cp "$CUSTOM_ICON_PATH" "$ACTIVITIES_ICON"
    else
        # PNG: copy to pixmaps and create SVG wrapper
        PIXMAP_DEST="/usr/share/pixmaps/${ICON_NAME}.png"
        mkdir -p /usr/share/pixmaps
        cp "$CUSTOM_ICON_PATH" "$PIXMAP_DEST"
        cat > "$ACTIVITIES_ICON" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="24" height="24" viewBox="0 0 24 24">
  <image xlink:href="file://$PIXMAP_DEST" width="24" height="24"/>
</svg>
EOF
    fi
    chmod 644 "$ACTIVITIES_ICON"
    log_info "Replaced icon in theme: $THEME_NAME"
    REPLACED=$((REPLACED + 1))
done

if [[ $REPLACED -eq 0 ]]; then
    log_error "No Yaru theme icon was replaced. Check that /usr/share/icons/Yaru*/scalable/places/start-here-symbolic.svg exist."
    exit 1
fi

# Update icon cache for all Yaru themes
for CACHE_DIR in /usr/share/icons/Yaru*; do
    [[ -d "$CACHE_DIR" ]] || continue
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f "$CACHE_DIR" 2>/dev/null || log_warn "Icon cache update had warnings for $CACHE_DIR"
    fi
done
log_info "Icon cache updated"

log_info "Icon replacement completed. Backup: $BACKUP_DIR"
log_warn "Log out and log back in (or Alt+F2 → r → Enter to restart GNOME Shell) for changes to take effect."
