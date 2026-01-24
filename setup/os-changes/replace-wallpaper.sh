#!/bin/bash
#
# Ubuntu Desktop Wallpaper Replacement Script
# 
# This script replaces the default desktop wallpaper with a custom image.
# Usage: sudo ./replace-wallpaper.sh /path/to/wallpaper.png
#
# Requirements:
# - Root/sudo access
# - Wallpaper image file (PNG, JPG, or other image format)
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

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check if wallpaper path provided
if [[ $# -lt 1 ]]; then
    log_error "Usage: $0 <path-to-wallpaper-file>"
    log_info "Example: $0 /home/user/custom-wallpaper.png"
    exit 1
fi

WALLPAPER_PATH="$1"

# Validate wallpaper file exists
if [[ ! -f "$WALLPAPER_PATH" ]]; then
    log_error "Wallpaper file not found: $WALLPAPER_PATH"
    exit 1
fi

# Get wallpaper extension and validate it's an image
WALLPAPER_EXT="${WALLPAPER_PATH##*.}"
if [[ ! "$WALLPAPER_EXT" =~ ^(png|PNG|jpg|JPG|jpeg|JPEG|webp|WEBP)$ ]]; then
    log_warn "File extension '$WALLPAPER_EXT' may not be a standard image format"
    log_warn "Proceeding anyway, but ensure it's a valid image file"
fi

WALLPAPER_NAME="ci-os-wallpaper"
DEST_WALLPAPER="/usr/share/backgrounds/${WALLPAPER_NAME}.${WALLPAPER_EXT}"

log_info "Setting custom desktop wallpaper..."
log_info "Source wallpaper: $WALLPAPER_PATH"
log_info "Destination: $DEST_WALLPAPER"

# Create backup directory
BACKUP_DIR="/usr/share/backgrounds/ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
log_info "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# Backup existing wallpaper if it exists
if [[ -f "$DEST_WALLPAPER" ]]; then
    cp "$DEST_WALLPAPER" "$BACKUP_DIR/${WALLPAPER_NAME}.${WALLPAPER_EXT}.bak"
    log_info "Backup created: $BACKUP_DIR/${WALLPAPER_NAME}.${WALLPAPER_EXT}.bak"
fi

# Ensure backgrounds directory exists
if ! mkdir -p /usr/share/backgrounds 2>/dev/null; then
    log_error "Failed to create /usr/share/backgrounds directory. Insufficient privileges?"
    exit 1
fi

# Copy wallpaper to system backgrounds directory
if ! cp "$WALLPAPER_PATH" "$DEST_WALLPAPER" 2>/dev/null; then
    log_error "Failed to copy wallpaper to $DEST_WALLPAPER. Check permissions."
    exit 1
fi
chmod 644 "$DEST_WALLPAPER"
log_success "Copied wallpaper to system directory"

# Get the actual user (not root) for gsettings
ACTUAL_USER="${SUDO_USER:-${USER}}"
if [[ "$ACTUAL_USER" == "root" ]] || [[ -z "$ACTUAL_USER" ]]; then
    # Try to find a logged-in user
    ACTUAL_USER=$(who | awk 'NR==1{print $1}' || echo "")
fi

# Set wallpaper for current user using gsettings
if command -v gsettings >/dev/null 2>&1; then
    # Try to get the actual user from the environment
    ACTUAL_USER="${SUDO_USER:-${USER}}"
    
    # If we're running as root, try to find a logged-in user
    if [[ "$ACTUAL_USER" == "root" ]] || [[ -z "$ACTUAL_USER" ]]; then
        # Try to find a user with an active session
        ACTUAL_USER=$(who | awk 'NR==1{print $1}' 2>/dev/null || echo "")
    fi
    
    if [[ -n "$ACTUAL_USER" ]] && [[ "$ACTUAL_USER" != "root" ]]; then
        log_info "Setting wallpaper for user: $ACTUAL_USER"
        
        # Set wallpaper as the actual user (not root)
        # Use su instead of sudo -u to properly inherit the user's environment
        su - "$ACTUAL_USER" -c "export DISPLAY=:0; export XAUTHORITY=\$HOME/.Xauthority; gsettings set org.gnome.desktop.background picture-uri 'file://$DEST_WALLPAPER' 2>/dev/null" || {
            # Fallback: try with sudo and proper environment
            sudo -u "$ACTUAL_USER" env DISPLAY=:0 XAUTHORITY="/home/$ACTUAL_USER/.Xauthority" gsettings set org.gnome.desktop.background picture-uri "file://$DEST_WALLPAPER" 2>/dev/null || true
        }
        
        su - "$ACTUAL_USER" -c "export DISPLAY=:0; export XAUTHORITY=\$HOME/.Xauthority; gsettings set org.gnome.desktop.background picture-uri-dark 'file://$DEST_WALLPAPER' 2>/dev/null" || {
            sudo -u "$ACTUAL_USER" env DISPLAY=:0 XAUTHORITY="/home/$ACTUAL_USER/.Xauthority" gsettings set org.gnome.desktop.background picture-uri-dark "file://$DEST_WALLPAPER" 2>/dev/null || true
        }
        
        log_success "Wallpaper set for current user"
        log_info "Note: You may need to log out and log back in for the change to take effect"
    else
        log_warn "Could not determine current user. Setting wallpaper manually..."
        log_info "Run these commands as your user (not root) to set the wallpaper:"
        log_info "  gsettings set org.gnome.desktop.background picture-uri 'file://$DEST_WALLPAPER'"
        log_info "  gsettings set org.gnome.desktop.background picture-uri-dark 'file://$DEST_WALLPAPER'"
    fi
else
    log_warn "gsettings not available. Wallpaper copied but not set."
    log_info "You can set it manually from Settings > Appearance > Background"
fi

# Set system-wide defaults for new users using dconf
log_info "Configuring system-wide wallpaper defaults for new users..."
if ! mkdir -p /etc/dconf/db/local.d 2>/dev/null; then
    log_warn "Failed to create dconf directory. System-wide wallpaper defaults may not be set."
else
    # Create dconf configuration file
    if ! cat > /etc/dconf/db/local.d/00-wallpaper <<EOF
[org/gnome/desktop/background]
picture-uri='file://$DEST_WALLPAPER'
picture-uri-dark='file://$DEST_WALLPAPER'
EOF
    then
        log_warn "Failed to write dconf configuration. Check permissions."
    else
        # Update dconf database
        if command -v dconf >/dev/null 2>&1; then
            dconf update 2>/dev/null || log_warn "Failed to update dconf database"
            log_success "System-wide wallpaper defaults configured"
        else
            log_warn "dconf not available. System-wide defaults written but database not updated."
        fi
    fi
fi

log_info "Wallpaper replacement completed!"
log_info "Backup location: $BACKUP_DIR"
log_info "Wallpaper location: $DEST_WALLPAPER"
log_warn "Note: Existing users may need to log out and log back in to see the change"
log_info "New users will automatically get this wallpaper"
