#!/usr/bin/bash
# Fresh Ubuntu Setup Script for CI-OS
# This script sets up a fresh Ubuntu installation with all required tools and services

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

# Install curl
install_curl() {
    log_info "Installing curl..."
    apt install -y curl
    log_success "curl installed"
}

# Update apt packages
update_apt() {
    log_info "Updating apt packages..."
    apt-get update
    log_success "apt packages updated"
}

# Install Docker
install_docker() {
    log_info "Installing Docker..."
    
    # Install prerequisites
    apt install -y ca-certificates curl
    
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    
    # Add the repository to Apt sources
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    
    # Update apt and install Docker
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    log_success "Docker installed"
}

# Create directories
create_directories() {
    log_info "Creating development directories..."
    # Create in the actual user's home directory
    mkdir -p "$ACTUAL_HOME/devel/companion"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/devel"
    log_success "Directories created at $ACTUAL_HOME/devel/companion"
}

# Clone CI server repo
clone_ci_server() {
    log_info "Cloning CI-Server repository..."
    if [ ! -d "$ACTUAL_HOME/devel/companion/CI-Server" ]; then
        # Clone as the actual user
        sudo -u "$ACTUAL_USER" git clone https://github.com/companionintelligence/CI-Server "$ACTUAL_HOME/devel/companion/CI-Server"
        log_success "CI-Server repository cloned"
    else
        log_warning "CI-Server directory already exists, skipping clone"
    fi
}

# Install UV
install_uv() {
    log_info "Installing UV for user $ACTUAL_USER..."
    # Install UV as the actual user
    sudo -u "$ACTUAL_USER" bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
    log_success "UV installed"
}

# Install Homebrew
install_homebrew() {
    log_info "Installing Homebrew for user $ACTUAL_USER..."
    
    # Install build-essential first
    apt-get install -y build-essential
    
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
    log_info "Installing asdf and Node.js for user $ACTUAL_USER..."
    
    # Install npm first (system-wide)
    apt install -y npm
    
    # Install asdf and Node.js as the actual user
    sudo -u "$ACTUAL_USER" bash <<EOF
# Source brew environment
eval "\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# Install asdf
brew install asdf

# Add asdf to shell (if not already there)
if ! grep -q "asdf.sh" ~/.bashrc; then
    echo '. "\$(brew --prefix asdf)/libexec/asdf.sh"' >> ~/.bashrc
fi

# Source asdf for this session
. "\$(brew --prefix asdf)/libexec/asdf.sh"

# Add Node.js plugin
asdf plugin add nodejs || true

# Install Node.js
asdf install nodejs 22.15.1

# Set Node.js version
asdf global nodejs 22.15.1

# Install yarn globally
npm install --global yarn

# Enable corepack
corepack enable
EOF
    
    log_success "asdf and Node.js installed"
}

# Install Bun
install_bun() {
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

# Replace Ubuntu icons with custom icon
replace_ubuntu_icons() {
    if [[ -z "${CUSTOM_ICON_PATH:-}" ]] || [[ ! -f "$CUSTOM_ICON_PATH" ]]; then
        log_warning "No custom icon specified, skipping icon replacement"
        return 0
    fi
    
    log_info "Replacing Ubuntu icons with custom icon..."
    
    local icon_ext="${CUSTOM_ICON_PATH##*.}"
    local icon_name="ci-os-logo"
    
    # Create backup directory
    local backup_dir="/usr/share/icons/ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    # Activities button icon (GNOME Shell start menu)
    local activities_icon="/usr/share/icons/Yaru/scalable/actions/view-app-grid-symbolic.svg"
    if [[ -f "$activities_icon" ]]; then
        # Backup original
        mkdir -p "$backup_dir/Yaru/scalable/actions"
        cp "$activities_icon" "$backup_dir/Yaru/scalable/actions/view-app-grid-symbolic.svg.bak" 2>/dev/null || true
        
        # Copy custom icon (SVG preferred for Activities button)
        if [[ "$icon_ext" =~ ^(svg|SVG)$ ]]; then
            cp "$CUSTOM_ICON_PATH" "$activities_icon"
        else
            # For PNG, create an SVG wrapper that references the PNG
            log_info "PNG format detected. Creating SVG wrapper for Activities button..."
            # Copy PNG to a location we can reference
            local png_dest="/usr/share/pixmaps/ci-os-activities-icon.png"
            cp "$CUSTOM_ICON_PATH" "$png_dest"
            # Create SVG wrapper
            cat > "$activities_icon" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="24" height="24" viewBox="0 0 24 24">
  <image xlink:href="file://$png_dest" width="24" height="24"/>
</svg>
EOF
        fi
        chmod 644 "$activities_icon"
        log_success "Replaced Activities button icon"
    fi
    
    # System pixmaps
    mkdir -p /usr/share/pixmaps
    if [[ "$icon_ext" =~ ^(svg|SVG)$ ]]; then
        cp "$CUSTOM_ICON_PATH" "/usr/share/pixmaps/${icon_name}.svg"
        # Also create PNG versions for compatibility
        if command -v convert >/dev/null 2>&1; then
            convert "$CUSTOM_ICON_PATH" -resize 64x64 "/usr/share/pixmaps/${icon_name}.png" 2>/dev/null || true
        fi
    else
        cp "$CUSTOM_ICON_PATH" "/usr/share/pixmaps/${icon_name}.png"
    fi
    log_success "Added icon to system pixmaps"
    
    # Application icons in hicolor theme
    local icon_sizes=(16 22 24 32 48 64 128 256 scalable)
    for size in "${icon_sizes[@]}"; do
        local icon_dir="/usr/share/icons/hicolor/${size}x${size}/apps"
        if [[ "$size" == "scalable" ]]; then
            icon_dir="/usr/share/icons/hicolor/scalable/apps"
        fi
        mkdir -p "$icon_dir"
        
        if [[ "$icon_ext" =~ ^(svg|SVG)$ ]] && [[ "$size" == "scalable" ]]; then
            cp "$CUSTOM_ICON_PATH" "${icon_dir}/${icon_name}.svg"
        elif [[ ! "$icon_ext" =~ ^(svg|SVG)$ ]] && [[ "$size" != "scalable" ]]; then
            if command -v convert >/dev/null 2>&1 && [[ "$size" != "scalable" ]]; then
                convert "$CUSTOM_ICON_PATH" -resize "${size}x${size}" "${icon_dir}/${icon_name}.png" 2>/dev/null || true
            else
                cp "$CUSTOM_ICON_PATH" "${icon_dir}/${icon_name}.png" 2>/dev/null || true
            fi
        fi
    done
    log_success "Added icon to hicolor theme"
    
    # Update icon cache
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
        gtk-update-icon-cache -f /usr/share/icons/Yaru 2>/dev/null || true
        log_success "Updated icon cache"
    fi
    
    log_success "Icon replacement completed. Backup saved to: $backup_dir"
    log_warning "Note: You may need to log out and log back in for all icon changes to take effect"
}

# Set custom wallpaper
set_custom_wallpaper() {
    if [[ -z "${CUSTOM_WALLPAPER_PATH:-}" ]] || [[ ! -f "$CUSTOM_WALLPAPER_PATH" ]]; then
        log_warning "No custom wallpaper specified, skipping wallpaper setup"
        return 0
    fi
    
    log_info "Setting custom desktop wallpaper..."
    
    # Copy wallpaper to system backgrounds directory
    local wallpaper_name="ci-os-wallpaper"
    local wallpaper_ext="${CUSTOM_WALLPAPER_PATH##*.}"
    local dest_wallpaper="/usr/share/backgrounds/${wallpaper_name}.${wallpaper_ext}"
    
    cp "$CUSTOM_WALLPAPER_PATH" "$dest_wallpaper"
    chmod 644 "$dest_wallpaper"
    log_success "Copied wallpaper to system directory"
    
    # Set wallpaper for all users using gsettings (requires desktop environment)
    if command -v gsettings >/dev/null 2>&1; then
        # Set for the actual user
        sudo -u "$ACTUAL_USER" bash <<EOF || true
export DISPLAY=:0
export XAUTHORITY=\$HOME/.Xauthority
gsettings set org.gnome.desktop.background picture-uri "file://$dest_wallpaper" 2>/dev/null || true
gsettings set org.gnome.desktop.background picture-uri-dark "file://$dest_wallpaper" 2>/dev/null || true
EOF
        
        # Also set system-wide defaults for new users
        mkdir -p /etc/dconf/db/local.d
        cat > /etc/dconf/db/local.d/00-wallpaper <<EOF
[org/gnome/desktop/background]
picture-uri='file://$dest_wallpaper'
picture-uri-dark='file://$dest_wallpaper'
EOF
        
        # Update dconf database
        if command -v dconf >/dev/null 2>&1; then
            dconf update 2>/dev/null || true
        fi
        
        log_success "Wallpaper configured for all users"
    else
        log_warning "gsettings not available. Wallpaper copied but not set as default."
        log_info "You can set it manually from Settings > Appearance > Background"
    fi
    
    log_success "Wallpaper setup completed"
}

# Create CI user and add to docker group
create_ci_user() {
    log_info "Creating CI user and adding to docker group..."
    
    # Create user if it doesn't exist
    if ! id "ci" &>/dev/null; then
        useradd -m ci
        log_success "CI user created"
    else
        log_warning "CI user already exists"
    fi
    
    # Add user to docker group
    usermod -aG docker ci
    log_success "CI user added to docker group"
    
    log_warning "Note: User 'ci' will need to log out and back in (or use 'newgrp docker') for docker group changes to take effect"
}

# Install Ollama
install_ollama() {
    log_info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    log_success "Ollama installed"
}

# Configure Ollama service
configure_ollama() {
    log_info "Configuring Ollama service..."
    
    # Enable ollama service
    systemctl enable ollama
    
    # Create systemd override directory
    mkdir -p /etc/systemd/system/ollama.service.d
    
    # Create override file with OLLAMA_HOST environment variable
    cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
EOF
    
    # Reload daemon
    systemctl daemon-reload
    
    log_success "Ollama service configured"
}

# Pull Ollama models
pull_ollama_models() {
    log_info "Pulling Ollama models..."
    
    # Start ollama service if not running
    systemctl start ollama || true
    
    # Wait a moment for service to start
    sleep 5
    
    # Pull models as the actual user (ollama stores models in user's home)
    sudo -u "$ACTUAL_USER" bash <<EOF || log_warning "Failed to pull some Ollama models"
ollama pull nomic-embed-text
ollama pull gemma3:1b
EOF
    
    log_success "Ollama models pulled"
}

# Install GitHub CLI
install_github_cli() {
    log_info "Installing GitHub CLI..."
    
    # Add GitHub CLI GPG key
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    
    # Add GitHub CLI repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    
    # Update and install GitHub CLI
    apt-get update
    apt-get install -y gh
    
    log_success "GitHub CLI installed"
}

# Install cloudflared
install_cloudflared() {
    log_info "Installing cloudflared..."
    
    # Add cloudflare GPG key
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    
    # Add repository
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
    
    # Install cloudflared
    apt-get update
    apt-get install -y cloudflared
    
    log_success "cloudflared installed"
}

# Main function
main() {
    log_info "Fresh Ubuntu Setup Script for CI-OS"
    log_info "===================================="
    echo
    
    check_root
    detect_user
    
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
