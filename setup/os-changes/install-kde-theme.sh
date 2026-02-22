#!/bin/bash
#
# CI OS KDE Plasma Dark Green Theme Installer
#
# Installs and applies the CI OS Dark Green color scheme for KDE Plasma.
# This script complements the GNOME theming in set-ci-branding.sh for KDE environments.
#
# Official CI Dark Green Color Scheme:
# - Primary Dark Green: #066c80 (backgrounds, window frames, selection)
# - Medium Green: #00a9a7 (highlights, links, buttons)  
# - Light Green: #72ddd4 (accents, text highlights)
#
# Usage: ./install-kde-theme.sh
# Requirements: KDE Plasma desktop environment
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

# Check if running KDE
if [[ -z "${KDE_FULL_SESSION:-}" ]] && [[ ! -f "/usr/bin/kwriteconfig5" ]]; then
    log_error "This script is for KDE Plasma environments only"
    log_info "For GNOME, use: sudo ./set-ci-branding.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLOR_SCHEME_SOURCE="$SCRIPT_DIR/../../configs/desktop/CI-OS-Dark.colors"
COLOR_SCHEME_DEST_GLOBAL="/usr/share/color-schemes/CI-OS-Dark.colors"
COLOR_SCHEME_DEST_USER="$HOME/.local/share/color-schemes/CI-OS-Dark.colors"

if [[ ! -f "$COLOR_SCHEME_SOURCE" ]]; then
    log_error "Color scheme file not found: $COLOR_SCHEME_SOURCE"
    exit 1
fi

# Install color scheme globally (requires sudo) or to user directory
if [[ $EUID -eq 0 ]]; then
    log_info "Installing CI OS Dark Green color scheme globally..."
    mkdir -p "$(dirname "$COLOR_SCHEME_DEST_GLOBAL")"
    cp "$COLOR_SCHEME_SOURCE" "$COLOR_SCHEME_DEST_GLOBAL"
    chmod 644 "$COLOR_SCHEME_DEST_GLOBAL"
    log_success "Color scheme installed to: $COLOR_SCHEME_DEST_GLOBAL"
else
    log_info "Installing CI OS Dark Green color scheme for current user..."
    mkdir -p "$(dirname "$COLOR_SCHEME_DEST_USER")"
    cp "$COLOR_SCHEME_SOURCE" "$COLOR_SCHEME_DEST_USER"
    log_success "Color scheme installed to: $COLOR_SCHEME_DEST_USER"
fi

# Apply the color scheme if kwriteconfig5 is available
if command -v kwriteconfig5 >/dev/null 2>&1; then
    log_info "Applying CI OS Dark Green color scheme to current session..."
    
    # Set color scheme
    kwriteconfig5 --file kdeglobals --group General --key ColorScheme "CI-OS-Dark"
    
    # Set window decoration colors (if using Breeze or compatible)
    kwriteconfig5 --file breezerc --group Common --key OutlineCloseButton true
    
    # Apply wallpaper if available
    WALLPAPER_SOURCE="$SCRIPT_DIR/background.png"
    if [[ -f "$WALLPAPER_SOURCE" ]]; then
        log_info "Setting CI OS wallpaper..."
        # KDE wallpaper setting requires qdbus, which may not work in all contexts
        if command -v qdbus >/dev/null 2>&1; then
            qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
                var allDesktops = desktops();
                for (i=0;i<allDesktops.length;i++) {
                    d = allDesktops[i];
                    d.wallpaperPlugin = 'org.kde.image';
                    d.currentConfigGroup = Array('Wallpaper', 'org.kde.image', 'General');
                    d.writeConfig('Image', 'file://$WALLPAPER_SOURCE');
                }
            " 2>/dev/null && log_success "Wallpaper set" || log_warn "Could not set wallpaper automatically"
        fi
    fi
    
    log_success "CI OS Dark Green theme applied"
    log_info "You may need to log out and back in for all changes to take effect"
else
    log_warn "kwriteconfig5 not found. Color scheme installed but not auto-applied."
    log_info "To apply: System Settings → Appearance → Colors → Select 'CI OS Dark Green'"
fi

log_success "CI OS KDE Dark Green theme installation complete"
log_info ""
log_info "Official CI Dark Green Color Scheme:"
log_info "  Primary Dark Green: #066c80"
log_info "  Medium Green: #00a9a7"
log_info "  Light Green: #72ddd4"
