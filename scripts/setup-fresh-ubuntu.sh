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
    
    echo
    log_success "Setup completed successfully!"
    echo
    log_info "Next steps:"
    echo "  • User $ACTUAL_USER: Log out and log back in (or start a new shell) to use new tools"
    echo "  • For CI user: log in as 'ci' user or use 'newgrp docker' to activate docker group"
    echo "  • Start Ollama service: systemctl start ollama"
    echo "  • Verify installations: docker --version, node --version, bun --version, ollama --version, gh --version"
    echo "  • Note: 'Create deploy read key' step was not specified - please add this manually if needed"
}

# Run main function
main "$@"
