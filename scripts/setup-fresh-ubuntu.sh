#!/usr/bin/bash
# Fresh Ubuntu Setup Script for CI-OS
# This script sets up a fresh Ubuntu installation with all required tools and services
#
# REQUIREMENTS:
# - This script MUST be run as root (use: sudo ./setup-fresh-ubuntu.sh)
# - All system-level operations require root privileges
# - User-specific operations run as the actual user via sudo -u

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect the actual user (if running with sudo, use SUDO_USER)
detect_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        ACTUAL_USER="$SUDO_USER"
        ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        ACTUAL_USER="${USER:-$(whoami)}"
        ACTUAL_HOME="${HOME:-$(getent passwd "$ACTUAL_USER" | cut -d: -f6)}"
    fi
    log_info "Detected user: $ACTUAL_USER (home: $ACTUAL_HOME)"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Helper function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Helper function to check if a package is installed
package_installed() {
    dpkg -l | grep -q "^ii.*$1 " 2>/dev/null
}

# Helper function to check if an apt repository is configured
repo_configured() {
    local repo_file="$1"
    [[ -f "$repo_file" ]]
}

# Helper function to check if a user exists
user_exists() {
    id "$1" &>/dev/null
}

# Helper function to check if a user is in a group
user_in_group() {
    local user="$1"
    local group="$2"
    groups "$user" 2>/dev/null | grep -q "\b${group}\b"
}

# Helper function to check if a directory exists and is not empty
dir_exists_and_not_empty() {
    [[ -d "$1" ]] && [[ -n "$(ls -A "$1" 2>/dev/null)" ]]
}

# Helper function to check if a service is enabled
service_enabled() {
    systemctl is-enabled "$1" &>/dev/null
}

# Install curl (requires root)
install_curl() {
    if command_exists curl; then
        log_info "curl is already installed, skipping..."
        return 0
    fi
    
    log_info "Installing curl..."
    apt install -y curl
    log_success "curl installed"
}

# Update apt packages (requires root)
update_apt() {
    log_info "Updating apt package lists..."
    apt-get update
    log_success "apt package lists updated"
}

# Install Docker (requires root for package installation and repository configuration)
install_docker() {
    # Check if Docker is already installed
    if command_exists docker && docker --version &>/dev/null; then
        log_info "Docker is already installed, skipping installation..."
        # Still check if repository is configured
        if ! repo_configured "/etc/apt/sources.list.d/docker.sources"; then
            log_info "Configuring Docker repository..."
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
            apt update
        fi
        return 0
    fi
    
    log_info "Installing Docker..."
    
    # Install prerequisites
    if ! package_installed ca-certificates; then
        apt install -y ca-certificates
    fi
    if ! command_exists curl; then
        apt install -y curl
    fi
    
    # Add Docker's official GPG key (only if not exists)
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi
    
    # Add the repository to Apt sources (only if not configured)
    if ! repo_configured "/etc/apt/sources.list.d/docker.sources"; then
        tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    fi
    
    # Update apt and install Docker
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    log_success "Docker installed"
}

# Create directories (requires root for chown operation)
create_directories() {
    if [[ -d "$ACTUAL_HOME/devel/companion" ]]; then
        log_info "Development directories already exist, skipping creation..."
        return 0
    fi
    
    log_info "Creating development directories..."
    # Create in the actual user's home directory (requires root for chown)
    mkdir -p "$ACTUAL_HOME/devel/companion"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/devel"
    log_success "Directories created at $ACTUAL_HOME/devel/companion"
}

# Clone CI server repo
clone_ci_server() {
    if dir_exists_and_not_empty "$ACTUAL_HOME/devel/companion/CI-Server"; then
        log_info "CI-Server repository already exists, skipping clone..."
        return 0
    fi
    
    log_info "Cloning CI-Server repository..."
    # Clone as the actual user
    sudo -u "$ACTUAL_USER" git clone https://github.com/companionintelligence/CI-Server "$ACTUAL_HOME/devel/companion/CI-Server"
    log_success "CI-Server repository cloned"
}

# Install UV
install_uv() {
    if sudo -u "$ACTUAL_USER" bash -c "command -v uv" &>/dev/null; then
        log_info "UV is already installed for user $ACTUAL_USER, skipping..."
        return 0
    fi
    
    log_info "Installing UV for user $ACTUAL_USER..."
    # Install UV as the actual user
    sudo -u "$ACTUAL_USER" bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
    log_success "UV installed"
}

# Install Homebrew
install_homebrew() {
    if sudo -u "$ACTUAL_USER" bash -c "command -v brew" &>/dev/null; then
        log_info "Homebrew is already installed for user $ACTUAL_USER, skipping installation..."
        # Still ensure bashrc is configured
        RC="$ACTUAL_HOME/.bashrc"
        if ! grep -q "linuxbrew" "$RC"; then
            echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$RC"
            chown "$ACTUAL_USER:$ACTUAL_USER" "$RC"
            log_info "Added Homebrew to bashrc"
        fi
        return 0
    fi
    
    log_info "Installing Homebrew for user $ACTUAL_USER..."
    
    # Install build-essential first
    if ! package_installed build-essential; then
        apt-get install -y build-essential
    fi
    
    # Install Homebrew as the actual user
    sudo -u "$ACTUAL_USER" bash <<EOF
export NONINTERACTIVE=1
/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
EOF
    
    # Finalize homebrew and set path variable in user's bashrc
    RC="$ACTUAL_HOME/.bashrc"
    if ! grep -q "linuxbrew" "$RC"; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$RC"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$RC"
    fi
    
    log_success "Homebrew installed and configured"
}

# Install asdf and Node.js
install_asdf_nodejs() {
    # Check if Node.js is already installed via asdf
    if sudo -u "$ACTUAL_USER" bash -c "command -v node" &>/dev/null && \
       sudo -u "$ACTUAL_USER" bash -c "node --version" 2>/dev/null | grep -q "v22.15.1"; then
        log_info "Node.js 22.15.1 is already installed, skipping installation..."
        return 0
    fi
    
    log_info "Installing asdf and Node.js for user $ACTUAL_USER..."
    
    # Install npm first (system-wide)
    if ! command_exists npm; then
        apt install -y npm
    fi
    
    # Install asdf and Node.js as the actual user
    sudo -u "$ACTUAL_USER" bash <<EOF
# Source brew environment
eval "\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" 2>/dev/null || true

# Install asdf (if not already installed)
if ! command -v asdf &>/dev/null; then
    brew install asdf
fi

# Add asdf to shell (if not already there)
if ! grep -q "asdf.sh" ~/.bashrc; then
    echo '. "\$(brew --prefix asdf)/libexec/asdf.sh"' >> ~/.bashrc
fi

# Source asdf for this session
. "\$(brew --prefix asdf)/libexec/asdf.sh" 2>/dev/null || true

# Add Node.js plugin (if not already added)
asdf plugin add nodejs 2>/dev/null || true

# Install Node.js (if not already installed)
if ! asdf list nodejs 2>/dev/null | grep -q "22.15.1"; then
    asdf install nodejs 22.15.1
fi

# Set Node.js version
asdf global nodejs 22.15.1

# Install yarn globally (if not already installed)
if ! command -v yarn &>/dev/null; then
    npm install --global yarn
fi

# Enable corepack
corepack enable 2>/dev/null || true
EOF
    
    log_success "asdf and Node.js installed"
}

# Install Bun
install_bun() {
    if sudo -u "$ACTUAL_USER" bash -c "command -v bun" &>/dev/null; then
        log_info "Bun is already installed for user $ACTUAL_USER, skipping installation..."
        # Still ensure bashrc is configured
        RC="$ACTUAL_HOME/.bashrc"
        if ! grep -q "bun" "$RC"; then
            echo '' >> "$RC"
            echo '# Bun' >> "$RC"
            echo 'export BUN_INSTALL="$HOME/.bun"' >> "$RC"
            echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$RC"
            chown "$ACTUAL_USER:$ACTUAL_USER" "$RC"
            log_info "Added Bun to bashrc"
        fi
        return 0
    fi
    
    log_info "Installing Bun for user $ACTUAL_USER..."
    
    # Install Bun as the actual user using the official installer
    sudo -u "$ACTUAL_USER" bash <<EOF
curl -fsSL https://bun.sh/install | bash
EOF
    
    # Add Bun to PATH in user's bashrc if not already there
    RC="$ACTUAL_HOME/.bashrc"
    if ! grep -q "bun" "$RC"; then
        echo '' >> "$RC"
        echo '# Bun' >> "$RC"
        echo 'export BUN_INSTALL="$HOME/.bun"' >> "$RC"
        echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$RC"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$RC"
    fi
    
    log_success "Bun installed"
}

# Note about bashrc
note_bashrc() {
    log_info "Note: User $ACTUAL_USER should start a new shell or run 'source ~/.bashrc' to use new tools"
}

# Get script directory and project root
get_script_paths() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    DEFAULT_ICON="$PROJECT_ROOT/LogoMark_Color_StartIcon.svg"
    DEFAULT_WALLPAPER="$PROJECT_ROOT/background.png"
}

# Prompt for icon path with default
prompt_icon_path() {
    get_script_paths
    
    echo
    log_info "Custom Start Menu Icon Configuration"
    echo "Default icon: $DEFAULT_ICON"
    read -p "Enter path to custom start menu icon (SVG or PNG) [Press Enter for default]: " ICON_PATH
    
    # Use default if empty
    if [[ -z "$ICON_PATH" ]]; then
        ICON_PATH="$DEFAULT_ICON"
    fi
    
    # Expand ~ and resolve relative paths
    ICON_PATH="${ICON_PATH/#\~/$HOME}"
    if [[ ! "$ICON_PATH" =~ ^/ ]]; then
        # Resolve relative to current directory or script directory
        if [[ -f "$ICON_PATH" ]]; then
            ICON_PATH="$(cd "$(dirname "$ICON_PATH")" 2>/dev/null && pwd)/$(basename "$ICON_PATH")"
        elif [[ -f "$SCRIPT_DIR/$ICON_PATH" ]]; then
            ICON_PATH="$SCRIPT_DIR/$ICON_PATH"
        elif [[ -f "$PROJECT_ROOT/$ICON_PATH" ]]; then
            ICON_PATH="$PROJECT_ROOT/$ICON_PATH"
        fi
    fi
    
    # Validate file exists
    if [[ ! -f "$ICON_PATH" ]]; then
        log_error "Icon file not found: $ICON_PATH"
        log_warning "Skipping icon customization"
        ICON_PATH=""
        return 1
    fi
    
    # Validate file format
    local ext="${ICON_PATH##*.}"
    if [[ ! "$ext" =~ ^(svg|SVG|png|PNG)$ ]]; then
        log_warning "Icon file should be SVG or PNG format. Proceeding anyway..."
    fi
    
    log_success "Using icon: $ICON_PATH"
    CUSTOM_ICON_PATH="$ICON_PATH"
    return 0
}

# Prompt for wallpaper path with default
prompt_wallpaper_path() {
    get_script_paths
    
    echo
    log_info "Custom Desktop Wallpaper Configuration"
    echo "Default wallpaper: $DEFAULT_WALLPAPER"
    read -p "Enter path to custom desktop wallpaper (PNG, JPG, or JPEG) [Press Enter for default]: " WALLPAPER_PATH
    
    # Use default if empty
    if [[ -z "$WALLPAPER_PATH" ]]; then
        WALLPAPER_PATH="$DEFAULT_WALLPAPER"
    fi
    
    # Expand ~ and resolve relative paths
    WALLPAPER_PATH="${WALLPAPER_PATH/#\~/$HOME}"
    if [[ ! "$WALLPAPER_PATH" =~ ^/ ]]; then
        # Resolve relative to current directory or script directory
        if [[ -f "$WALLPAPER_PATH" ]]; then
            WALLPAPER_PATH="$(cd "$(dirname "$WALLPAPER_PATH")" 2>/dev/null && pwd)/$(basename "$WALLPAPER_PATH")"
        elif [[ -f "$SCRIPT_DIR/$WALLPAPER_PATH" ]]; then
            WALLPAPER_PATH="$SCRIPT_DIR/$WALLPAPER_PATH"
        elif [[ -f "$PROJECT_ROOT/$WALLPAPER_PATH" ]]; then
            WALLPAPER_PATH="$PROJECT_ROOT/$WALLPAPER_PATH"
        fi
    fi
    
    # Validate file exists
    if [[ ! -f "$WALLPAPER_PATH" ]]; then
        log_error "Wallpaper file not found: $WALLPAPER_PATH"
        log_warning "Skipping wallpaper customization"
        WALLPAPER_PATH=""
        return 1
    fi
    
    # Validate file format
    local ext="${WALLPAPER_PATH##*.}"
    if [[ ! "$ext" =~ ^(png|PNG|jpg|JPG|jpeg|JPEG)$ ]]; then
        log_warning "Wallpaper file should be PNG, JPG, or JPEG format. Proceeding anyway..."
    fi
    
    log_success "Using wallpaper: $WALLPAPER_PATH"
    CUSTOM_WALLPAPER_PATH="$WALLPAPER_PATH"
    return 0
}

# Replace Ubuntu icons with custom icon (requires root for system directory operations)
replace_ubuntu_icons() {
    # Verify we have root privileges for system directory operations
    if [[ $EUID -ne 0 ]]; then
        log_error "Icon replacement requires root privileges. Please run with sudo."
        return 1
    fi
    
    if [[ -z "${CUSTOM_ICON_PATH:-}" ]] || [[ ! -f "$CUSTOM_ICON_PATH" ]]; then
        log_warning "No custom icon specified, skipping icon replacement"
        return 0
    fi
    
    # Check if icon was already replaced (check if backup directory exists)
    local backup_check_dir="/usr/share/icons/ubuntu-backup-*"
    if ls -d $backup_check_dir &>/dev/null; then
        log_info "Icon replacement appears to have been done before (backup found), skipping..."
        log_info "To re-run icon replacement, remove backup directories in /usr/share/icons/ubuntu-backup-*"
        return 0
    fi
    
    log_info "Replacing Ubuntu icons with custom icon (requires root privileges)..."
    
    local icon_ext="${CUSTOM_ICON_PATH##*.}"
    local icon_name="ci-os-logo"
    
    # Create backup directory (requires root)
    local backup_dir="/usr/share/icons/ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
    if ! mkdir -p "$backup_dir" 2>/dev/null; then
        log_error "Failed to create backup directory. Insufficient privileges?"
        return 1
    fi
    
    # Activities button icon (GNOME Shell start menu) - requires root
    local activities_icon="/usr/share/icons/Yaru/scalable/actions/view-app-grid-symbolic.svg"
    if [[ -f "$activities_icon" ]]; then
        # Backup original (requires root)
        mkdir -p "$backup_dir/Yaru/scalable/actions"
        if ! cp "$activities_icon" "$backup_dir/Yaru/scalable/actions/view-app-grid-symbolic.svg.bak" 2>/dev/null; then
            log_warning "Could not backup original icon, but continuing..."
        fi
        
        # Copy custom icon (SVG preferred for Activities button) - requires root
        if [[ "$icon_ext" =~ ^(svg|SVG)$ ]]; then
            if ! cp "$CUSTOM_ICON_PATH" "$activities_icon" 2>/dev/null; then
                log_error "Failed to copy icon to $activities_icon. Check permissions."
                return 1
            fi
        else
            # For PNG, create an SVG wrapper that references the PNG - requires root
            log_info "PNG format detected. Creating SVG wrapper for Activities button..."
            # Copy PNG to a location we can reference (requires root)
            local png_dest="/usr/share/pixmaps/ci-os-activities-icon.png"
            if ! cp "$CUSTOM_ICON_PATH" "$png_dest" 2>/dev/null; then
                log_error "Failed to copy PNG icon. Check permissions."
                return 1
            fi
            # Create SVG wrapper (requires root)
            if ! cat > "$activities_icon" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="24" height="24" viewBox="0 0 24 24">
  <image xlink:href="file://$png_dest" width="24" height="24"/>
</svg>
EOF
            then
                log_error "Failed to create SVG wrapper. Check permissions."
                return 1
            fi
        fi
        chmod 644 "$activities_icon"
        log_success "Replaced Activities button icon"
    else
        log_warning "Activities icon file not found: $activities_icon"
    fi
    
    # System pixmaps (requires root)
    if ! mkdir -p /usr/share/pixmaps 2>/dev/null; then
        log_error "Failed to create /usr/share/pixmaps directory. Insufficient privileges?"
        return 1
    fi
    
    if [[ "$icon_ext" =~ ^(svg|SVG)$ ]]; then
        if ! cp "$CUSTOM_ICON_PATH" "/usr/share/pixmaps/${icon_name}.svg" 2>/dev/null; then
            log_error "Failed to copy icon to pixmaps. Check permissions."
            return 1
        fi
        # Also create PNG versions for compatibility
        if command -v convert >/dev/null 2>&1; then
            convert "$CUSTOM_ICON_PATH" -resize 64x64 "/usr/share/pixmaps/${icon_name}.png" 2>/dev/null || true
        fi
    else
        if ! cp "$CUSTOM_ICON_PATH" "/usr/share/pixmaps/${icon_name}.png" 2>/dev/null; then
            log_error "Failed to copy icon to pixmaps. Check permissions."
            return 1
        fi
    fi
    log_success "Added icon to system pixmaps"
    
    # Application icons in hicolor theme (requires root)
    local icon_sizes=(16 22 24 32 48 64 128 256 scalable)
    for size in "${icon_sizes[@]}"; do
        local icon_dir="/usr/share/icons/hicolor/${size}x${size}/apps"
        if [[ "$size" == "scalable" ]]; then
            icon_dir="/usr/share/icons/hicolor/scalable/apps"
        fi
        if ! mkdir -p "$icon_dir" 2>/dev/null; then
            log_warning "Failed to create icon directory: $icon_dir"
            continue
        fi
        
        if [[ "$icon_ext" =~ ^(svg|SVG)$ ]] && [[ "$size" == "scalable" ]]; then
            cp "$CUSTOM_ICON_PATH" "${icon_dir}/${icon_name}.svg" 2>/dev/null || true
        elif [[ ! "$icon_ext" =~ ^(svg|SVG)$ ]] && [[ "$size" != "scalable" ]]; then
            if command -v convert >/dev/null 2>&1 && [[ "$size" != "scalable" ]]; then
                convert "$CUSTOM_ICON_PATH" -resize "${size}x${size}" "${icon_dir}/${icon_name}.png" 2>/dev/null || true
            else
                cp "$CUSTOM_ICON_PATH" "${icon_dir}/${icon_name}.png" 2>/dev/null || true
            fi
        fi
    done
    log_success "Added icon to hicolor theme"
    
    # Update icon cache (requires root)
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || log_warning "Failed to update hicolor icon cache"
        gtk-update-icon-cache -f /usr/share/icons/Yaru 2>/dev/null || log_warning "Failed to update Yaru icon cache"
        log_success "Updated icon cache"
    fi
    
    log_success "Icon replacement completed. Backup saved to: $backup_dir"
    log_warning "Note: You may need to log out and log back in for all icon changes to take effect"
}

# Set custom wallpaper (requires root for system directory and dconf operations)
set_custom_wallpaper() {
    # Verify we have root privileges for system directory operations
    if [[ $EUID -ne 0 ]]; then
        log_error "Wallpaper setup requires root privileges. Please run with sudo."
        return 1
    fi
    
    if [[ -z "${CUSTOM_WALLPAPER_PATH:-}" ]] || [[ ! -f "$CUSTOM_WALLPAPER_PATH" ]]; then
        log_warning "No custom wallpaper specified, skipping wallpaper setup"
        return 0
    fi
    
    # Check if wallpaper is already set
    local wallpaper_name="ci-os-wallpaper"
    local wallpaper_ext="${CUSTOM_WALLPAPER_PATH##*.}"
    local dest_wallpaper="/usr/share/backgrounds/${wallpaper_name}.${wallpaper_ext}"
    
    log_info "Setting custom desktop wallpaper (requires root privileges)..."
    
    # Ensure backgrounds directory exists (requires root)
    if ! mkdir -p /usr/share/backgrounds 2>/dev/null; then
        log_error "Failed to create /usr/share/backgrounds directory. Insufficient privileges?"
        return 1
    fi
    
    # Copy wallpaper to system backgrounds directory (requires root)
    if [[ ! -f "$dest_wallpaper" ]]; then
        if ! cp "$CUSTOM_WALLPAPER_PATH" "$dest_wallpaper" 2>/dev/null; then
            log_error "Failed to copy wallpaper to $dest_wallpaper. Check permissions."
            return 1
        fi
        chmod 644 "$dest_wallpaper"
        log_success "Copied wallpaper to system directory"
    else
        log_info "Custom wallpaper already exists in system directory, skipping copy..."
    fi
    
    # Set wallpaper for all users using gsettings (requires desktop environment)
    if command -v gsettings >/dev/null 2>&1; then
        # Set for the actual user (runs as user, not root)
        sudo -u "$ACTUAL_USER" bash <<EOF || true
export DISPLAY=:0
export XAUTHORITY=\$HOME/.Xauthority
gsettings set org.gnome.desktop.background picture-uri "file://$dest_wallpaper" 2>/dev/null || true
gsettings set org.gnome.desktop.background picture-uri-dark "file://$dest_wallpaper" 2>/dev/null || true
EOF
        
        # Also set system-wide defaults for new users (requires root)
        if ! mkdir -p /etc/dconf/db/local.d 2>/dev/null; then
            log_warning "Failed to create dconf directory. System-wide wallpaper may not be set."
        else
            if ! cat > /etc/dconf/db/local.d/00-wallpaper <<EOF
[org/gnome/desktop/background]
picture-uri='file://$dest_wallpaper'
picture-uri-dark='file://$dest_wallpaper'
EOF
            then
                log_warning "Failed to write dconf configuration. Check permissions."
            else
                # Update dconf database (requires root)
                if command -v dconf >/dev/null 2>&1; then
                    dconf update 2>/dev/null || log_warning "Failed to update dconf database"
                fi
                log_success "Wallpaper configured for all users"
            fi
        fi
    else
        log_warning "gsettings not available. Wallpaper copied but not set as default."
        log_info "You can set it manually from Settings > Appearance > Background"
    fi
    
    log_success "Wallpaper setup completed"
}

# Create CI user and add to docker group (requires root for user management)
create_ci_user() {
    # Create user if it doesn't exist
    if ! user_exists "ci"; then
        log_info "Creating CI user..."
        useradd -m ci
        log_success "CI user created"
    else
        log_info "CI user already exists, skipping creation..."
    fi
    
    # Add user to docker group (if not already in group)
    if ! user_in_group "ci" "docker"; then
        log_info "Adding CI user to docker group..."
        usermod -aG docker ci
        log_success "CI user added to docker group"
        log_warning "Note: User 'ci' will need to log out and back in (or use 'newgrp docker') for docker group changes to take effect"
    else
        log_info "CI user is already in docker group, skipping..."
    fi
}

# Install Ollama (requires root - installer script needs root privileges)
install_ollama() {
    if command_exists ollama; then
        log_info "Ollama is already installed, skipping installation..."
        return 0
    fi
    
    log_info "Installing Ollama (this requires root privileges)..."
    # The Ollama install script requires root to install system-wide
    curl -fsSL https://ollama.com/install.sh | sh
    log_success "Ollama installed"
}

# Configure Ollama service (requires root for systemd operations)
configure_ollama() {
    if ! command_exists ollama; then
        log_warning "Ollama is not installed, skipping service configuration..."
        return 0
    fi
    
    log_info "Configuring Ollama service..."
    
    # Enable ollama service (if not already enabled)
    if ! service_enabled ollama; then
        systemctl enable ollama
        log_info "Ollama service enabled"
    else
        log_info "Ollama service is already enabled, skipping..."
    fi
    
    # Create systemd override directory
    mkdir -p /etc/systemd/system/ollama.service.d
    
    # Create override file with OLLAMA_HOST environment variable (only if not exists or different)
    local override_file="/etc/systemd/system/ollama.service.d/override.conf"
    if [[ ! -f "$override_file" ]] || ! grep -q "OLLAMA_HOST=0.0.0.0" "$override_file" 2>/dev/null; then
        cat > "$override_file" <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
EOF
        log_info "Created Ollama service override"
    else
        log_info "Ollama service override already configured, skipping..."
    fi
    
    # Reload daemon (always safe to do)
    systemctl daemon-reload
    
    log_success "Ollama service configured"
}

# Pull Ollama models (runs as user, but service management requires root)
pull_ollama_models() {
    if ! command_exists ollama; then
        log_warning "Ollama is not installed, skipping model pull..."
        return 0
    fi
    
    log_info "Checking Ollama models..."
    
    # Start ollama service if not running
    if ! systemctl is-active --quiet ollama; then
        systemctl start ollama || true
        sleep 5
    fi
    
    # Check and pull models as the actual user (ollama stores models in user's home)
    sudo -u "$ACTUAL_USER" bash <<EOF || log_warning "Failed to pull some Ollama models"
# Check if models are already pulled
if ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
    echo "nomic-embed-text already installed"
else
    echo "Pulling nomic-embed-text..."
    ollama pull nomic-embed-text
fi

if ollama list 2>/dev/null | grep -q "gemma3:1b"; then
    echo "gemma3:1b already installed"
else
    echo "Pulling gemma3:1b..."
    ollama pull gemma3:1b
fi
EOF
    
    log_success "Ollama models checked/pulled"
}

# Install GitHub CLI (requires root for package installation and repository configuration)
install_github_cli() {
    if command_exists gh; then
        log_info "GitHub CLI is already installed, skipping installation..."
        return 0
    fi
    
    log_info "Installing GitHub CLI..."
    
    # Add GitHub CLI GPG key (only if not exists)
    if [[ ! -f /usr/share/keyrings/githubcli-archive-keyring.gpg ]]; then
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    fi
    
    # Add GitHub CLI repository (only if not configured)
    if ! repo_configured "/etc/apt/sources.list.d/github-cli.list"; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    fi
    
    # Update and install GitHub CLI
    apt-get update
    apt-get install -y gh
    
    log_success "GitHub CLI installed"
}

# Install cloudflared (requires root for package installation and repository configuration)
install_cloudflared() {
    if command_exists cloudflared; then
        log_info "cloudflared is already installed, skipping installation..."
        return 0
    fi
    
    log_info "Installing cloudflared..."
    
    # Add cloudflare GPG key (only if not exists)
    mkdir -p --mode=0755 /usr/share/keyrings
    if [[ ! -f /usr/share/keyrings/cloudflare-public-v2.gpg ]]; then
        curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    fi
    
    # Add repository (only if not configured)
    if ! repo_configured "/etc/apt/sources.list.d/cloudflared.list"; then
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
    fi
    
    # Install cloudflared
    apt-get update
    apt-get install -y cloudflared
    
    log_success "cloudflared installed"
}

# Install VS Code (requires root for snap installation)
install_vscode() {
    if command_exists code; then
        log_info "VS Code is already installed, skipping installation..."
        return 0
    fi
    
    log_info "Installing VS Code..."
    snap install code --classic
    log_success "VS Code installed"
}

# Main function
main() {
    log_info "Fresh Ubuntu Setup Script for CI-OS"
    log_info "===================================="
    echo
    
    # Ensure we're running as root (required for all system operations)
    # This includes: package installation, system directory modifications, 
    # icon/wallpaper replacement, service configuration, user management
    check_root
    
    # Double-check root privileges are available
    if [[ $EUID -ne 0 ]]; then
        log_error "Script must be run as root. Use: sudo $0"
        log_error "This script requires root privileges for:"
        log_error "  - Installing system packages (apt)"
        log_error "  - Modifying system directories (/usr/share/icons, /usr/share/backgrounds)"
        log_error "  - Configuring system services (systemctl)"
        log_error "  - Managing users and groups"
        exit 1
    fi
    
    detect_user
    
    log_info "✓ Running with root privileges (EUID: $EUID)"
    log_info "✓ All system operations will run with root privileges"
    log_info "✓ User-specific operations will run as user: $ACTUAL_USER"
    log_info "✓ Icon and wallpaper replacement will use system directories"
    echo
    
    # Prompt for custom icon and wallpaper
    prompt_icon_path || CUSTOM_ICON_PATH=""
    prompt_wallpaper_path || CUSTOM_WALLPAPER_PATH=""
    
    log_info "Starting installation process..."
    echo
    
    install_curl
    update_apt
    install_docker
    create_directories
    clone_ci_server
    install_uv
    install_homebrew
    install_asdf_nodejs
    install_bun
    note_bashrc
    create_ci_user
    install_github_cli
    install_ollama
    configure_ollama
    pull_ollama_models
    install_cloudflared
    install_vscode
    
    # Customize branding (icons and wallpaper)
    if [[ -n "${CUSTOM_ICON_PATH:-}" ]]; then
        replace_ubuntu_icons
    fi
    
    if [[ -n "${CUSTOM_WALLPAPER_PATH:-}" ]]; then
        set_custom_wallpaper
    fi
    
    echo
    log_success "Setup completed successfully!"
    echo
    log_info "Next steps:"
    echo "  • User $ACTUAL_USER: Log out and log back in (or start a new shell) to use new tools"
    echo "  • For CI user: log in as 'ci' user or use 'newgrp docker' to activate docker group"
    echo "  • Start Ollama service: systemctl start ollama"
    echo "  • Verify installations: docker --version, node --version, bun --version, ollama --version, gh --version"
    if [[ -n "${CUSTOM_ICON_PATH:-}" ]]; then
        echo "  • Custom icon applied - log out and log back in to see changes"
    fi
    if [[ -n "${CUSTOM_WALLPAPER_PATH:-}" ]]; then
        echo "  • Custom wallpaper applied"
    fi
    echo "  • Note: 'Create deploy read key' step was not specified - please add this manually if needed"
}

# Run main function
main "$@"
