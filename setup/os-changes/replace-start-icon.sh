#!/bin/bash
#
# Ubuntu Start Icon Replacement Script
# 
# This script replaces the Ubuntu start icon (Activities button) with a custom icon.
# Usage: sudo ./replace-start-icon.sh /path/to/custom-icon.png
#
# Requirements:
# - Root/sudo access
# - Custom icon file (PNG or SVG)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check if icon path provided
if [[ $# -lt 1 ]]; then
    log_error "Usage: $0 <path-to-icon-file> [icon-theme-variant]"
    log_info "Example: $0 /home/user/custom-icon.png"
    log_info "Example: $0 /home/user/custom-icon.png Yaru-dark"
    exit 1
fi

CUSTOM_ICON_PATH="$1"
ICON_THEME="${2:-Yaru}"  # Default to Yaru, but allow override

# Validate icon file exists
if [[ ! -f "$CUSTOM_ICON_PATH" ]]; then
    log_error "Icon file not found: $CUSTOM_ICON_PATH"
    exit 1
fi

# Get icon extension
ICON_EXT="${CUSTOM_ICON_PATH##*.}"
ICON_NAME="ci-os-activities-icon"

log_info "Replacing Ubuntu start icon..."
log_info "Source icon: $CUSTOM_ICON_PATH"
log_info "Icon theme: $ICON_THEME"
log_info "Icon format: $ICON_EXT"

# Create backup directory
BACKUP_DIR="/usr/share/icons/ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
log_info "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR/$ICON_THEME/scalable/actions"

# Backup original icon (the actual icon used by Ubuntu Dock)
ACTIVITIES_ICON="/usr/share/icons/$ICON_THEME/scalable/places/start-here-symbolic.svg"
if [[ -f "$ACTIVITIES_ICON" ]]; then
    mkdir -p "$BACKUP_DIR/$ICON_THEME/scalable/places"
    cp "$ACTIVITIES_ICON" "$BACKUP_DIR/$ICON_THEME/scalable/places/start-here-symbolic.svg.bak"
    log_info "Backup created: $BACKUP_DIR/$ICON_THEME/scalable/places/start-here-symbolic.svg.bak"
else
    log_warn "Original icon not found: $ACTIVITIES_ICON"
    log_warn "Proceeding without backup..."
fi

# Handle PNG icons (create SVG wrapper)
if [[ "$ICON_EXT" =~ ^(png|PNG)$ ]]; then
    log_info "PNG format detected. Creating SVG wrapper..."
    
    # Copy PNG to pixmaps
    PIXMAP_DEST="/usr/share/pixmaps/${ICON_NAME}.png"
    mkdir -p /usr/share/pixmaps
    cp "$CUSTOM_ICON_PATH" "$PIXMAP_DEST"
    log_info "Copied PNG to: $PIXMAP_DEST"
    
    # Create SVG wrapper
    mkdir -p "$(dirname "$ACTIVITIES_ICON")"
    cat > "$ACTIVITIES_ICON" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="24" height="24" viewBox="0 0 24 24">
  <image xlink:href="file://$PIXMAP_DEST" width="24" height="24"/>
</svg>
EOF
    log_info "Created SVG wrapper at: $ACTIVITIES_ICON"

# Handle SVG icons (direct copy)
elif [[ "$ICON_EXT" =~ ^(svg|SVG)$ ]]; then
    log_info "SVG format detected. Copying directly..."
    mkdir -p "$(dirname "$ACTIVITIES_ICON")"
    cp "$CUSTOM_ICON_PATH" "$ACTIVITIES_ICON"
    log_info "Copied SVG to: $ACTIVITIES_ICON"
else
    log_error "Unsupported icon format: $ICON_EXT"
    log_error "Supported formats: PNG, SVG"
    exit 1
fi

# Set correct permissions
chmod 644 "$ACTIVITIES_ICON"
log_info "Set permissions on icon file"

# Update icon cache
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    log_info "Updating icon cache for $ICON_THEME..."
    gtk-update-icon-cache -f "/usr/share/icons/$ICON_THEME" 2>&1 || log_warn "Icon cache update had warnings"
    log_info "Icon cache updated"
else
    log_warn "gtk-update-icon-cache not found. Icon cache not updated."
fi

log_info "Icon replacement completed!"
log_info "Backup location: $BACKUP_DIR"
log_warn "You may need to log out and log back in (or restart GNOME Shell) for changes to take effect"
log_info "To restart GNOME Shell: Press Alt+F2, type 'r', press Enter"
