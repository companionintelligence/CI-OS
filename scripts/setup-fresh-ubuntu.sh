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

# Fix Docker apt source conflicts before any apt-get update.
# Different machines may have docker.list (docker.gpg) AND docker.sources (docker.asc);
# both target the same repo and cause: "Conflicting values set for option Signed-By"
fix_docker_apt_conflicts() {
    for f in /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources; do
        if [[ -f "$f" ]]; then
            log_info "Removing conflicting Docker apt source: $f"
            rm -f "$f"
        fi
    done
}

# Update apt packages (requires root)
update_apt() {
    log_info "Updating apt package lists..."
    apt-get update
    log_success "apt package lists updated"
}

# Install make (requires root)
install_make() {
    if command_exists make; then
        log_info "make is already installed, skipping..."
        return 0
    fi
    
    log_info "Installing make..."
    sudo apt install -y make
    log_success "make installed"
}

# Install Tailscale (requires root)
install_tailscale() {
    if command_exists tailscale; then
        log_info "Tailscale is already installed, skipping..."
        return 0
    fi

    log_info "Installing Tailscale..."
    # Import Tailscale GPG key and repo
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    apt-get update
    apt-get install -y tailscale
    log_success "Tailscale installed"
}

# Install Docker (requires root for package installation and repository configuration)
install_docker() {
    # Note: fix_docker_apt_conflicts() runs earlier (before update_apt) to resolve
    # Signed-By conflicts from mixed docker.list/docker.sources on pre-configured machines

    # Check if Docker is already installed
    if command_exists docker && docker --version &>/dev/null; then
        log_info "Docker is already installed, skipping installation..."
        # Still ensure repository is configured (we removed any old conflicting sources above)
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
    
    # Ensure docker group exists (usually created by Docker installation, but ensure it exists)
    if ! getent group docker >/dev/null 2>&1; then
        log_info "Creating docker group..."
        groupadd docker
        log_success "Docker group created"
    fi
    
    log_success "Docker installed"
}

# Add actual user to docker group (requires root for user management)
add_user_to_docker_group() {
    # Ensure docker group exists
    if ! getent group docker >/dev/null 2>&1; then
        log_info "Creating docker group..."
        groupadd docker
        log_success "Docker group created"
    fi
    
    # Add actual user to docker group (if not already in group)
    if ! user_in_group "$ACTUAL_USER" "docker"; then
        log_info "Adding user $ACTUAL_USER to docker group..."
        usermod -aG docker "$ACTUAL_USER"
        log_success "User $ACTUAL_USER added to docker group"
        log_warning "Note: User $ACTUAL_USER will need to log out and back in (or use 'newgrp docker') for docker group changes to take effect"
    else
        log_info "User $ACTUAL_USER is already in docker group, skipping..."
    fi
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

# Configure passwordless sudo for user (required for Homebrew noninteractive installation)
configure_passwordless_sudo() {
    log_info "Configuring passwordless sudo for user $ACTUAL_USER..."
    
    # Ensure user is in sudo group (required for sudo access)
    if ! user_in_group "$ACTUAL_USER" "sudo"; then
        log_info "Adding user $ACTUAL_USER to sudo group..."
        usermod -aG sudo "$ACTUAL_USER"
        log_success "User $ACTUAL_USER added to sudo group"
    else
        log_info "User $ACTUAL_USER is already in sudo group"
    fi
    
    # Check if user already has passwordless sudo
    if sudo -u "$ACTUAL_USER" sudo -n true 2>/dev/null; then
        log_info "User $ACTUAL_USER already has passwordless sudo access"
        return 0
    fi
    
    # Create sudoers.d file for passwordless sudo
    local sudoers_file="/etc/sudoers.d/${ACTUAL_USER}-passwordless"
    if [[ ! -f "$sudoers_file" ]]; then
        echo "${ACTUAL_USER} ALL=(ALL) NOPASSWD: ALL" > "$sudoers_file"
        chmod 0440 "$sudoers_file"
        log_success "Configured passwordless sudo for $ACTUAL_USER"
    else
        log_info "Passwordless sudo already configured for $ACTUAL_USER"
    fi
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
    
    # Configure passwordless sudo first (required for noninteractive Homebrew installation)
    configure_passwordless_sudo
    
    # Install Homebrew dependencies
    log_info "Installing Homebrew dependencies..."
    local deps=("build-essential" "git" "file" "procps")
    for dep in "${deps[@]}"; do
        if ! package_installed "$dep"; then
            apt-get install -y "$dep"
        fi
    done
    
    # Install Homebrew as the actual user with proper environment
    log_info "Running Homebrew installer..."
    sudo -u "$ACTUAL_USER" bash <<EOF
export NONINTERACTIVE=1
export CI=1
/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
EOF
    
    # Verify Homebrew installation
    if ! sudo -u "$ACTUAL_USER" bash -c "command -v brew" &>/dev/null; then
        # Try to source brew environment and check again
        if [[ -f /home/linuxbrew/.linuxbrew/bin/brew ]]; then
            sudo -u "$ACTUAL_USER" bash -c "eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\" && command -v brew" &>/dev/null || {
                log_warning "Homebrew installed but not in PATH yet. Will be available after shell restart."
            }
        else
            log_error "Homebrew installation may have failed. Please check the output above."
            return 1
        fi
    fi
    
    # Finalize homebrew and set path variable in user's bashrc
    RC="$ACTUAL_HOME/.bashrc"
    if ! grep -q "linuxbrew" "$RC"; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$RC"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$RC"
    fi
    
    log_success "Homebrew installed and configured"
}

# Install asdf and Node.js (standalone asdf via git clone - no Homebrew dependency)
install_asdf_nodejs() {
    # Check if Node.js is already installed via asdf
    if sudo -u "$ACTUAL_USER" bash -c '[[ -f "$HOME/.asdf/asdf.sh" ]] && source "$HOME/.asdf/asdf.sh" && command -v node &>/dev/null' 2>/dev/null && \
       sudo -u "$ACTUAL_USER" bash -c 'source "$HOME/.asdf/asdf.sh" && node --version' 2>/dev/null | grep -q "v22.15.1"; then
        log_info "Node.js 22.15.1 is already installed via asdf, skipping installation..."
        return 0
    fi
    
    log_info "Installing asdf and Node.js for user $ACTUAL_USER..."
    
    # Ensure git is available (needed to clone asdf)
    if ! command_exists git; then
        apt install -y git
    fi

    # Install asdf and Node.js as the actual user (standalone asdf - no Homebrew)
    sudo -u "$ACTUAL_USER" bash <<'EOF'
ASDF_DIR="$HOME/.asdf"
ASDF_VERSION="v0.14.0"

# Install asdf via git clone (if not already installed)
if [[ ! -d "$ASDF_DIR" ]]; then
    git clone https://github.com/asdf-vm/asdf.git "$ASDF_DIR" --branch "$ASDF_VERSION"
fi

# Add asdf to shell (if not already there)
if ! grep -q "asdf.sh" ~/.bashrc 2>/dev/null; then
    echo '' >> ~/.bashrc
    echo '# asdf version manager' >> ~/.bashrc
    echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
fi

# Source asdf for current session
export PATH="$HOME/.asdf/bin:$PATH"
if [[ -f "$ASDF_DIR/asdf.sh" ]]; then
    . "$ASDF_DIR/asdf.sh"
fi

# Create .asdfrc for legacy version file support
echo 'legacy_version_file = yes' > ~/.asdfrc 2>/dev/null || true

# Add Node.js plugin (if not already added)
asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git 2>/dev/null || true

# Install Node.js 22.15.1 (if not already installed)
if ! asdf list nodejs 2>/dev/null | grep -q "22.15.1"; then
    asdf install nodejs 22.15.1
    asdf reshim
fi

# Set as global version
asdf global nodejs 22.15.1
EOF
    
    log_success "asdf and Node.js installed"
}

# Set global Node.js version (standalone asdf in ~/.asdf)
set_global_nodejs() {
    log_info "Setting global Node.js version to 22.15.1 for user $ACTUAL_USER..."
    
    sudo -u "$ACTUAL_USER" bash <<'EOF'
# Load standalone asdf from ~/.asdf
ASDF_DIR="$HOME/.asdf"
if [[ ! -f "$ASDF_DIR/asdf.sh" ]]; then
    exit 0
fi
export PATH="$HOME/.asdf/bin:$PATH"
. "$ASDF_DIR/asdf.sh"

# Check if Node.js 22.15.1 is installed
if ! asdf list nodejs 2>/dev/null | grep -q "22.15.1"; then
    exit 0
fi

# Check current global version
CURRENT_GLOBAL=$(asdf current nodejs 2>/dev/null | awk '{print $2}' || echo "")
if [[ "$CURRENT_GLOBAL" == "22.15.1" ]]; then
    exit 0
fi

# Set global Node.js version
asdf global nodejs 22.15.1
EOF
    
    log_success "Global Node.js version set to 22.15.1"
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
curl -fsSL https://bun.com/install | bash
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
    
    # Source bashrc to load Bun
    sudo -u "$ACTUAL_USER" bash -c "source ~/.bashrc" 2>/dev/null || true
    
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

# Check if ollama systemd unit exists (official installer creates it; Homebrew/manual installs may not)
ollama_systemd_unit_exists() {
    systemctl cat ollama.service &>/dev/null || \
    [[ -f /etc/systemd/system/ollama.service ]] || \
    [[ -f /usr/lib/systemd/system/ollama.service ]]
}

# Configure Ollama service (requires root for systemd operations)
configure_ollama() {
    if ! command_exists ollama; then
        log_warning "Ollama is not installed, skipping service configuration..."
        return 0
    fi
    
    # Skip systemd configuration if no ollama.service unit exists (e.g. Homebrew install)
    if ! ollama_systemd_unit_exists; then
        log_info "Ollama is installed but no systemd unit found (e.g. Homebrew/manual install). Skipping systemd configuration."
        log_info "To run Ollama, use 'ollama serve' or reinstall via: curl -fsSL https://ollama.com/install.sh | sh"
        log_success "Ollama configured (user-managed)"
        return 0
    fi
    
    log_info "Configuring Ollama service..."
    
    # Enable ollama service (if not already enabled)
    if ! service_enabled ollama; then
        if systemctl enable ollama 2>/dev/null; then
            log_info "Ollama service enabled"
        else
            log_warning "Could not enable ollama service (unit may not support it), continuing..."
        fi
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
    
    # Start ollama if not running (systemd or background)
    if ollama_systemd_unit_exists && systemctl is-active --quiet ollama 2>/dev/null; then
        :
    elif ollama_systemd_unit_exists; then
        systemctl start ollama 2>/dev/null || true
        sleep 5
    elif ! pgrep -f "ollama serve" >/dev/null 2>&1; then
        log_info "Starting Ollama in background (no systemd unit)..."
        sudo -u "$ACTUAL_USER" nohup ollama serve >/tmp/ollama.log 2>&1 &
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

# Add qwen3-vl:32b model
if ollama list 2>/dev/null | grep -q "qwen3-vl:32b"; then
     echo "qwen3-vl:32b already installed"
else
     echo "Pulling qwen3-vl:32b..."
     ollama pull qwen3-vl:32b
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

# Remove Ubuntu telemetry (requires root)
remove_telemetry() {
    log_info "Removing Ubuntu telemetry..."
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Use bash explicitly so it works even if remove-telemetry.sh lacks execute bit (e.g. fresh clone)
    bash "${script_dir}/remove-telemetry.sh" --from-setup
    log_success "Telemetry removal complete"
}

# Enable corepack (requires Node.js via asdf; corepack provides yarn/pnpm)
enable_corepack() {
    log_info "Enabling corepack for user $ACTUAL_USER..."
    
    # Check if Node.js is available via asdf
    if ! sudo -u "$ACTUAL_USER" bash -c '[[ -f "$HOME/.asdf/asdf.sh" ]] && source "$HOME/.asdf/asdf.sh" && command -v node &>/dev/null' 2>/dev/null; then
        log_warning "Node.js not found. Skipping corepack enable. It will be enabled when Node.js is available."
        return 0
    fi
    
    sudo -u "$ACTUAL_USER" bash <<'EOF'
# Load standalone asdf from ~/.asdf
ASDF_DIR="$HOME/.asdf"
if [[ -f "$ASDF_DIR/asdf.sh" ]]; then
    export PATH="$HOME/.asdf/bin:$PATH"
    . "$ASDF_DIR/asdf.sh"
fi

if command -v corepack &>/dev/null; then
    if corepack enable 2>/dev/null; then
        echo "Corepack enabled successfully (yarn/pnpm available)"
    else
        echo "Warning: Failed to enable corepack. You may need to run 'corepack enable' manually after logging out and back in."
    fi
else
    echo "Warning: corepack command not found. Node.js may not be properly installed or in PATH."
fi
EOF
    
    log_success "Corepack enable attempted (check output above for status)"
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
    # service configuration, user management
    check_root
    
    # Double-check root privileges are available
    if [[ $EUID -ne 0 ]]; then
        log_error "Script must be run as root. Use: sudo $0"
        log_error "This script requires root privileges for:"
        log_error "  - Installing system packages (apt)"
        log_error "  - Configuring system services (systemctl)"
        log_error "  - Managing users and groups"
        exit 1
    fi
    
    detect_user
    
    log_info "✓ Running with root privileges (EUID: $EUID)"
    log_info "✓ All system operations will run with root privileges"
    log_info "✓ User-specific operations will run as user: $ACTUAL_USER"
    log_info "Starting installation process..."
    echo
    
    install_curl
    fix_docker_apt_conflicts
    update_apt
    install_make
    install_docker
    add_user_to_docker_group
    install_uv
    install_homebrew
    install_asdf_nodejs
    set_global_nodejs
    install_bun
    note_bashrc
    create_ci_user
    install_github_cli
    install_ollama
    configure_ollama
    pull_ollama_models
    install_cloudflared
    install_vscode
    enable_corepack
    remove_telemetry

        install_tailscale
    
    echo
    log_success "Setup completed successfully!"
    echo
    log_info "Next steps:"
    echo "  • User $ACTUAL_USER: Log out and log back in (or start a new shell) to use new tools and activate docker group"
    echo "  • For CI user: log in as 'ci' user or use 'newgrp docker' to activate docker group"
    echo "  • Start Ollama service: systemctl start ollama"
    echo "  • Verify installations: docker --version, node --version, bun --version, ollama --version, gh --version"
    echo "  • Note: 'Create deploy read key' step was not specified - please add this manually if needed"
}

# Run main function
main "$@"

# Hook: install ROCm driver (standalone script; can also be run directly: ./scripts/install-rocm-driver.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/install-rocm-driver.sh"

# Install LACT GPU monitor (latest release from GitHub)
install_lact() {
    if command_exists lact; then
        log_info "LACT GPU monitor is already installed, skipping..."
        return 0
    fi

    log_info "Downloading and installing LACT GPU monitor..."
    # Get latest .deb release URL from GitHub API
    LACT_DEB_URL=$(curl -s https://api.github.com/repos/ilya-zlobintsev/LACT/releases/latest | grep browser_download_url | grep 'amd64.deb' | cut -d '"' -f 4 | head -n 1)
    if [[ -z "$LACT_DEB_URL" ]]; then
        log_error "Could not find LACT .deb package URL."
        return 1
    fi
    TMP_DEB="/tmp/lact-latest.deb"
    curl -L "$LACT_DEB_URL" -o "$TMP_DEB"
    apt-get install -y "$TMP_DEB" || dpkg -i "$TMP_DEB"
    rm -f "$TMP_DEB"
    log_success "LACT GPU monitor installed. Run 'lact-gui' to launch."
        # Pin LACT to GNOME favorites bar for the user
        if command_exists gsettings && [[ -n "$ACTUAL_USER" ]] && [[ "$ACTUAL_USER" != "root" ]]; then
            UID_NUM="$(id -u "$ACTUAL_USER" 2>/dev/null || true)"
            RUNTIME_DIR="/run/user/${UID_NUM}"
            DBUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus"
            if [[ -S "${RUNTIME_DIR}/bus" ]]; then
                log_info "Pinning LACT to GNOME favorites bar for $ACTUAL_USER"
                CURRENT_FAVS=$(sudo -u "$ACTUAL_USER" env DISPLAY=:0 XAUTHORITY="/home/$ACTUAL_USER/.Xauthority" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" \
                    gsettings get org.gnome.shell favorite-apps 2>/dev/null)
                if [[ "$CURRENT_FAVS" != *"lact-gui.desktop"* ]]; then
                    # Remove brackets and quotes, then add lact-gui.desktop
                    FAVS_CLEAN=$(echo "$CURRENT_FAVS" | sed -e "s/^\[//" -e "s/\]$//" -e "s/'//g" -e 's/, /,/g')
                    if [[ -z "$FAVS_CLEAN" ]]; then
                        NEW_FAVS="['lact-gui.desktop']"
                    else
                        NEW_FAVS="[$(echo "$FAVS_CLEAN" | sed 's/$/,lact-gui.desktop/')]"
                        NEW_FAVS=$(echo "$NEW_FAVS" | sed "s/,/, /g" | sed "s/\[/['/g" | sed "s/\]/']/g" | sed "s/, '/, '/g")
                    fi
                    sudo -u "$ACTUAL_USER" env DISPLAY=:0 XAUTHORITY="/home/$ACTUAL_USER/.Xauthority" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" \
                        gsettings set org.gnome.shell favorite-apps "$NEW_FAVS" 2>/dev/null || true
                    log_success "Pinned LACT to GNOME favorites bar for $ACTUAL_USER"
                else
                    log_info "LACT already pinned to favorites bar for $ACTUAL_USER"
                fi
            else
                log_warning "No D-Bus session for ${ACTUAL_USER}. User may not be logged in. Cannot pin LACT to favorites bar."
            fi
        else
            log_warning "gsettings not available or no valid user detected. Skipping LACT pinning."
        fi
}

# Call LACT install at the end
install_lact

# Set GNOME Power Mode to 'performance' for the user
set_gnome_power_performance() {
    if command_exists gsettings && [[ -n "$ACTUAL_USER" ]] && [[ "$ACTUAL_USER" != "root" ]]; then
        UID_NUM="$(id -u "$ACTUAL_USER" 2>/dev/null || true)"
        RUNTIME_DIR="/run/user/${UID_NUM}"
        DBUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus"
        if [[ -S "${RUNTIME_DIR}/bus" ]]; then
            log_info "Setting GNOME Power Mode to 'performance' for $ACTUAL_USER"
            sudo -u "$ACTUAL_USER" env DISPLAY=:0 XAUTHORITY="/home/$ACTUAL_USER/.Xauthority" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" \
                gsettings set org.gnome.settings-daemon.plugins.power power-profile 'performance' 2>/dev/null || true
            log_success "GNOME Power Mode set to 'performance' for $ACTUAL_USER"
        else
            log_warning "No D-Bus session for ${ACTUAL_USER}. User may not be logged in. Power mode will apply on next login if set via dconf defaults."
        fi
    else
        log_warning "gsettings not available or no valid user detected. Skipping GNOME Power Mode setting."
    fi
}

set_gnome_power_performance
