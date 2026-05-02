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

# Helper function to check if a user is in a group (uses nss; reliable vs "groups" formatting)
user_in_group() {
    local user="$1"
    local group="$2"
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"
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

# Enforce apt to prefer IPv4 to avoid failures on systems with broken IPv6
enable_apt_force_ipv4() {
    log_info "Ensuring apt uses IPv4 (workaround for IPv6 network issues)"
    local conf_file="/etc/apt/apt.conf.d/99force-ipv4"
    if [[ ! -f "$conf_file" ]] || ! grep -q 'Acquire::ForceIPv4 "true";' "$conf_file" 2>/dev/null; then
        echo 'Acquire::ForceIPv4 "true";' > "$conf_file"
        log_info "Wrote apt IPv4 config to $conf_file"
    else
        log_info "APT IPv4 enforcement already configured"
    fi
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

# Ensure /var/run/docker.sock is root:docker and mode 660 (fixes some snap/partial installs)
ensure_docker_socket_permissions() {
    local sock="/var/run/docker.sock"
    if [[ ! -S "$sock" ]]; then
        log_info "Docker socket $sock not found (daemon may be stopped); skipping socket permission fix"
        return 0
    fi
    local grp
    grp=$(stat -c '%G' "$sock" 2>/dev/null || echo "")
    if [[ "$grp" != "docker" ]]; then
        log_warning "Docker socket group is '$grp' (expected docker); running chgrp docker on $sock"
        chgrp docker "$sock" 2>/dev/null || log_warning "chgrp docker on $sock failed (is Docker running?)"
    fi
    chmod 660 "$sock" 2>/dev/null || true
}

# Add actual user to docker group (requires root for user management)
add_user_to_docker_group() {
    # Ensure docker group exists
    if ! getent group docker >/dev/null 2>&1; then
        log_info "Creating docker group..."
        groupadd docker
        log_success "Docker group created"
    fi

    # Idempotent: safe if the user is already a member (covers fresh install and re-runs).
    local was_member=0
    if user_in_group "$ACTUAL_USER" "docker"; then
        was_member=1
    fi
    log_info "Ensuring user $ACTUAL_USER is in the docker group..."
    usermod -aG docker "$ACTUAL_USER"
    if [[ "$was_member" -eq 0 ]]; then
        log_success "User $ACTUAL_USER added to docker group"
        log_warning "Note: User $ACTUAL_USER must open a new login session for docker group to apply to existing terminals (or run: newgrp docker)"
    else
        log_info "User $ACTUAL_USER was already in the docker group (nss)"
    fi
}

# Verify the desktop user can reach the daemon (uses nss group list, not the invoking shell)
verify_docker_cli_for_actual_user() {
    if ! command_exists docker; then
        return 0
    fi
    if [[ ! -S /var/run/docker.sock ]]; then
        log_warning "Docker socket missing; skipping docker CLI verification"
        return 0
    fi
    if sudo -u "$ACTUAL_USER" docker info &>/dev/null; then
        log_success "Docker CLI verified for $ACTUAL_USER (docker info as that user)"
        return 0
    fi
    if sudo -u "$ACTUAL_USER" sg docker -c "docker info" &>/dev/null; then
        log_warning "Docker works for $ACTUAL_USER via sg docker only; fix group/socket and re-login."
        return 0
    fi
    log_warning "Docker CLI check failed for $ACTUAL_USER (docker info). Check: getent group docker, ls -la /var/run/docker.sock"
}

# Socket + group + verification (call after any Docker install/skip path)
finalize_docker_access_for_actual_user() {
    ensure_docker_socket_permissions
    add_user_to_docker_group
    verify_docker_cli_for_actual_user
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
    else
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
    fi

    # Always run: Docker may be pre-installed while the user was never added, or socket group wrong,
    # or this is a re-run after usermod (verification uses fresh nss via sudo).
    finalize_docker_access_for_actual_user
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
    local brew_bin="/home/linuxbrew/.linuxbrew/bin/brew"

    # Check if brew is already available (in PATH)
    if sudo -u "$ACTUAL_USER" bash -c "command -v brew" &>/dev/null; then
        log_info "Homebrew is already installed and available for user $ACTUAL_USER, skipping installation..."
        _homebrew_ensure_bashrc
        return 0
    fi

    # Check if brew binary exists (e.g. from a previous run that failed at brew update)
    if [[ -f "$brew_bin" ]]; then
        log_info "Homebrew binary found at $brew_bin (partial install or permission issue). Fixing and verifying..."
        chown -R "$ACTUAL_USER:$ACTUAL_USER" /home/linuxbrew/.linuxbrew 2>/dev/null || true
        if sudo -u "$ACTUAL_USER" "$brew_bin" update --force --quiet 2>/dev/null; then
            log_success "Homebrew recovered and verified."
            _homebrew_ensure_bashrc
            return 0
        fi
        log_warning "Could not recover existing Homebrew. Will attempt reinstall..."
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

    # Install Homebrew as the actual user with proper environment (allow installer failure; we fix perms after)
    log_info "Running Homebrew installer..."
    sudo -u "$ACTUAL_USER" bash <<EOF || true
export NONINTERACTIVE=1
export CI=1
/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
EOF

    # Fix lock directory permissions (Homebrew installer can leave var/homebrew owned by root)
    if [[ -d /home/linuxbrew/.linuxbrew ]]; then
        log_info "Ensuring Homebrew directory permissions for $ACTUAL_USER..."
        chown -R "$ACTUAL_USER:$ACTUAL_USER" /home/linuxbrew/.linuxbrew
    fi

    # Complete brew update if installer failed mid-way (e.g. due to lock permissions)
    if [[ -f "$brew_bin" ]]; then
        log_info "Running brew update to complete installation..."
        sudo -u "$ACTUAL_USER" "$brew_bin" update --force --quiet 2>/dev/null || true
    fi

    # Verify Homebrew installation
    if ! sudo -u "$ACTUAL_USER" bash -c "eval \"\$($brew_bin shellenv)\" && command -v brew" &>/dev/null; then
        if [[ -f "$brew_bin" ]]; then
            log_warning "Homebrew installed but not in PATH yet. Will be available after shell restart."
        else
            log_error "Homebrew installation may have failed. Please check the output above."
            return 1
        fi
    fi

    _homebrew_ensure_bashrc
    log_success "Homebrew installed and configured"
}

# Ensure Homebrew eval is in user's bashrc (helper used by install_homebrew)
_homebrew_ensure_bashrc() {
    RC="$ACTUAL_HOME/.bashrc"
    if ! grep -q "linuxbrew" "$RC"; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$RC"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$RC"
        log_info "Added Homebrew to bashrc"
    fi
}

# Apt packages for asdf-nodejs (prebuilt binaries + optional compile fallback)
install_asdf_nodejs_apt_prereqs() {
    log_info "Installing apt packages for asdf / Node.js (git, curl, gpg, build tools)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates \
        curl \
        git \
        gnupg \
        dirmngr \
        build-essential \
        python3
    log_success "asdf / Node.js apt prerequisites ready"
}

# True if Node 22.15.1 is installed under asdf and binaries run (does not depend on PATH order).
_verify_asdf_nodejs_22_15_1_installed() {
    sudo -u "$ACTUAL_USER" bash <<'VERIFY'
set -euo pipefail
test -x "$HOME/.asdf/installs/nodejs/22.15.1/bin/node"
test -x "$HOME/.asdf/installs/nodejs/22.15.1/bin/npm"
"$HOME/.asdf/installs/nodejs/22.15.1/bin/node" -v | grep -q '^v22\.15\.1'
"$HOME/.asdf/installs/nodejs/22.15.1/bin/npm" -v >/dev/null
VERIFY
}

# Insert asdf before Ubuntu's "non-interactive return" so npm/node work under bash -c / CI / scripts.
_insert_asdf_bootstrap_before_noninteractive_return() {
    local rc="$ACTUAL_HOME/.bashrc"
    [[ -f "$rc" ]] || return 0
    chown "$ACTUAL_USER:$ACTUAL_USER" "$rc"

    if grep -q 'asdf-before-noninteractive-return' "$rc" 2>/dev/null; then
        return 0
    fi

    local line
    line=$(grep -n '^# If not running interactively' "$rc" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [[ -z "$line" ]]; then
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    {
        head -n "$((line - 1))" "$rc"
        cat <<'ASDFTOP'

# asdf (before non-interactive return): node/npm for scripts / ssh / CI (ci-os setup)
export ASDF_DIR="${ASDF_DIR:-$HOME/.asdf}"
if [[ -f "$ASDF_DIR/asdf.sh" ]]; then
  # shellcheck source=/dev/null
  . "$ASDF_DIR/asdf.sh"
  export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"  # asdf-shims-priority asdf-before-noninteractive-return
fi
ASDFTOP
        tail -n "+${line}" "$rc"
    } > "$tmp" && mv "$tmp" "$rc"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$rc"
    log_info "Inserted asdf bootstrap before non-interactive early return in $rc"
}

# After Homebrew / ~/.local env: prepend shims again so asdf wins over editor-bundled Node on PATH.
_append_asdf_shim_priority_tail() {
    local rc="$ACTUAL_HOME/.bashrc"
    [[ -f "$rc" ]] || touch "$rc"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$rc"

    if grep -q 'asdf-after-path-toolchains' "$rc" 2>/dev/null; then
        return 0
    fi

    {
        echo ''
        echo '# After brew/env: asdf shims first again (node/npm vs linuxbrew, editor PATH)'
        echo 'export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"  # asdf-shims-priority asdf-after-path-toolchains'
    } >> "$rc"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$rc"
    log_info "Appended asdf PATH tail to $rc"
}

# Ensure ~/.bashrc loads asdf and prepends shims so node/npm win over editor-bundled PATH entries.
_ensure_asdf_in_bashrc_with_shim_priority() {
    local rc="$ACTUAL_HOME/.bashrc"
    [[ -f "$rc" ]] || touch "$rc"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$rc"

    _insert_asdf_bootstrap_before_noninteractive_return

    if grep -q 'asdf-after-path-toolchains' "$rc" 2>/dev/null; then
        return 0
    fi

    if grep -q 'asdf\.sh' "$rc" 2>/dev/null; then
        _append_asdf_shim_priority_tail
    else
        log_info "Adding classic asdf block to end of $rc (no asdf.sh reference yet)"
        {
            echo ''
            echo '# asdf version manager (ci-os setup)'
            echo '. "$HOME/.asdf/asdf.sh"'
            echo 'export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"  # asdf-shims-priority asdf-after-path-toolchains'
        } >> "$rc"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$rc"
    fi
}

# Install asdf and Node.js (standalone asdf via git clone - no Homebrew dependency)
install_asdf_nodejs() {
    if _verify_asdf_nodejs_22_15_1_installed 2>/dev/null; then
        log_info "Node.js 22.15.1 is already installed via asdf, skipping install..."
        _ensure_asdf_in_bashrc_with_shim_priority
        return 0
    fi

    install_asdf_nodejs_apt_prereqs

    log_info "Installing asdf and Node.js for user $ACTUAL_USER..."

    if ! command_exists git; then
        apt install -y git
    fi

    # Install asdf and Node.js as the actual user. set -e ensures a failed install never leaves
    # .tool-versions pointing at a missing version (which breaks npm/node shims with asdf errors).
    if ! sudo -u "$ACTUAL_USER" bash <<'EOF'
set -euo pipefail
ASDF_DIR="$HOME/.asdf"
ASDF_VERSION="v0.14.0"

if [[ ! -d "$ASDF_DIR" ]]; then
    git clone https://github.com/asdf-vm/asdf.git "$ASDF_DIR" --branch "$ASDF_VERSION"
fi

export PATH="$HOME/.asdf/bin:$PATH"
if [[ -f "$ASDF_DIR/asdf.sh" ]]; then
    . "$ASDF_DIR/asdf.sh"
fi

echo 'legacy_version_file = yes' > "$HOME/.asdfrc"

asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git 2>/dev/null || true

asdf install nodejs 22.15.1
asdf reshim nodejs
asdf global nodejs 22.15.1

test -x "$HOME/.asdf/installs/nodejs/22.15.1/bin/node"
test -x "$HOME/.asdf/installs/nodejs/22.15.1/bin/npm"
"$HOME/.asdf/installs/nodejs/22.15.1/bin/node" -v | grep -q '^v22\.15\.1'
"$HOME/.asdf/installs/nodejs/22.15.1/bin/npm" -v >/dev/null
EOF
    then
        log_error "asdf / Node.js install failed for user $ACTUAL_USER (see errors above)."
        return 1
    fi

    _ensure_asdf_in_bashrc_with_shim_priority

    if ! _verify_asdf_nodejs_22_15_1_installed 2>/dev/null; then
        log_error "Post-install check failed: Node.js 22.15.1 not present under ~/.asdf/installs for $ACTUAL_USER"
        return 1
    fi

    log_success "asdf and Node.js installed"
}

# Set global Node.js version (standalone asdf in ~/.asdf)
set_global_nodejs() {
    log_info "Setting global Node.js version to 22.15.1 for user $ACTUAL_USER..."

    if ! sudo -u "$ACTUAL_USER" bash <<'EOF'
set -euo pipefail
ASDF_DIR="$HOME/.asdf"
[[ -f "$ASDF_DIR/asdf.sh" ]] || exit 0
export PATH="$HOME/.asdf/bin:$PATH"
. "$ASDF_DIR/asdf.sh"
asdf list nodejs 2>/dev/null | grep -q "22.15.1" || exit 0
asdf global nodejs 22.15.1
EOF
    then
        log_warning "Could not set asdf global nodejs (asdf or install missing); install_asdf_nodejs may need to run first"
        return 0
    fi

    log_success "Global Node.js version set to 22.15.1"
}

# Bun installation removed — Bun is no longer required

# Note about bashrc
note_bashrc() {
    log_info "Note: User $ACTUAL_USER should start a new shell or run 'source ~/.bashrc' to use new tools"
    log_info "Docker: if 'docker ps' says permission denied but setup verified OK, run 'newgrp docker' once, or log out and back in (GUI sessions keep old group set until then)"
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
    bash "${script_dir}/lib/remove-telemetry.sh" --from-setup
    log_success "Telemetry removal complete"
}

# Enable corepack (requires Node.js via asdf; corepack provides yarn/pnpm).
# pnpm only appears under ~/.asdf/shims after `corepack prepare ... --activate` + `asdf reshim nodejs`.
enable_corepack() {
    log_info "Enabling corepack and pnpm for user $ACTUAL_USER..."

    if ! sudo -u "$ACTUAL_USER" bash -c '[[ -f "$HOME/.asdf/asdf.sh" ]] && export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH" && . "$HOME/.asdf/asdf.sh" && command -v node &>/dev/null' 2>/dev/null; then
        log_warning "Node.js not found. Skipping corepack enable. It will be enabled when Node.js is available."
        return 0
    fi

    sudo -u "$ACTUAL_USER" bash <<'EOF'
# Match login PATH: shims first so node/corepack/pnpm resolve like ~/.bashrc (ci-os asdf blocks).
ASDF_DIR="$HOME/.asdf"
export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"
if [[ ! -f "$ASDF_DIR/asdf.sh" ]]; then
    echo "Warning: $ASDF_DIR/asdf.sh missing; skipping corepack."
    exit 0
fi
. "$ASDF_DIR/asdf.sh"

if ! command -v corepack &>/dev/null; then
    echo "Warning: corepack not found next to Node; check asdf nodejs install."
    exit 0
fi

if corepack enable 2>/dev/null; then
    echo "corepack enable: ok"
else
    echo "Warning: corepack enable failed; try again after a new login shell."
fi

if corepack prepare pnpm@latest --activate 2>/dev/null; then
    echo "corepack prepare pnpm@latest --activate: ok"
else
    echo "Warning: corepack prepare pnpm failed (network or registry); run: corepack prepare pnpm@latest --activate && asdf reshim nodejs"
fi

if command -v asdf &>/dev/null; then
    asdf reshim nodejs 2>/dev/null || true
fi

if command -v pnpm &>/dev/null; then
    echo "pnpm $(pnpm --version) on PATH"
else
    echo "Warning: pnpm not on PATH yet; open a new shell or: source ~/.asdf/asdf.sh && asdf reshim nodejs"
fi
exit 0
EOF

    if sudo -u "$ACTUAL_USER" bash -c 'export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"; [[ -f "$HOME/.asdf/asdf.sh" ]] && . "$HOME/.asdf/asdf.sh" && command -v pnpm &>/dev/null' 2>/dev/null; then
        log_success "pnpm is available for $ACTUAL_USER (Corepack + asdf shims)"
    else
        log_warning "pnpm not detected on PATH for $ACTUAL_USER after corepack step; re-login or run: source ~/.asdf/asdf.sh && asdf reshim nodejs"
    fi
}

# Chromium: Ubuntu's transitional chromium-browser package often pulls Snap; Snap may be
# missing or broken on minimal / lab images (e.g. 26.04). Prefer native .deb (xtradeb PPA),
# then Snap, then Flatpak. Keep `chromium_chromium.desktop` working for CI defaults (symlink).
# Install Chromium browser (requires root)
# True if Chromium is already usable (skip reinstall).
# Important: /usr/bin/chromium-browser may exist as an executable shell stub that only
# delegates to /snap/bin/chromium — without the snap, the browser is not usable; do not skip.
chromium_usable() {
    [[ -x /snap/bin/chromium ]] && return 0
    if command_exists flatpak && flatpak info org.chromium.Chromium &>/dev/null; then
        return 0
    fi
    [[ -x /usr/bin/chromium ]] && return 0
    if command_exists chromium; then
        [[ -x "$(command -v chromium)" ]] && return 0
    fi
    if [[ -x /usr/bin/chromium-browser ]]; then
        if head -n 20 /usr/bin/chromium-browser 2>/dev/null | grep -q '/snap/bin/chromium'; then
            return 1
        fi
        return 0
    fi
    return 1
}

# True if the Microsoft VS Code / code package is already on the system (skip reinstall).
vscode_installed() {
    command_exists code && return 0
    [[ -x /usr/bin/code ]] && return 0
    if dpkg-query -W -f='${Status}' code 2>/dev/null | grep -q 'ok installed'; then
        return 0
    fi
    return 1
}

chromium_desktop_compat_symlink() {
    if [[ -f /var/lib/snapd/desktop/applications/chromium_chromium.desktop ]]; then
        return 0
    fi
    if [[ -f /usr/share/applications/chromium.desktop ]] && [[ ! -e /usr/local/share/applications/chromium_chromium.desktop ]]; then
        install -d -m 755 /usr/local/share/applications
        ln -sf /usr/share/applications/chromium.desktop /usr/local/share/applications/chromium_chromium.desktop
        log_info "Added chromium_chromium.desktop → chromium.desktop (CI defaults / favorites)"
    fi
}

install_chromium() {
    if chromium_usable; then
        log_info "Chromium already available, skipping..."
        chromium_desktop_compat_symlink || true
        return 0
    fi

    log_info "Installing Chromium (native .deb preferred; Snap/Flatpak as fallback)..."

    # 1) Native Chromium via xtradeb PPA (maintained .deb; avoids Snap-only transitional packages)
    if ! grep -rq 'xtradeb/apps' /etc/apt/sources.list.d/ 2>/dev/null; then
        if ! command_exists add-apt-repository; then
            log_info "Installing software-properties-common for add-apt-repository..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
        fi
        log_info "Adding PPA ppa:xtradeb/apps for Chromium .deb builds..."
        if ! DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:xtradeb/apps; then
            log_warning "Could not add xtradeb PPA (unsupported release or network); will try other install methods..."
        else
            apt-get update -y
        fi
    fi

    if grep -rq 'xtradeb/apps' /etc/apt/sources.list.d/ 2>/dev/null; then
        apt-get update -y || true
        if DEBIAN_FRONTEND=noninteractive apt-get install -y chromium; then
            if chromium_usable; then
                chromium_desktop_compat_symlink || true
                log_success "Chromium installed (xtradeb PPA .deb)"
                return 0
            fi
        fi
    else
        log_warning "xtradeb PPA not configured; skipping apt install chromium (Ubuntu metapackage often pulls Snap)"
    fi

    # 2) Snap (only if snapd works — may be absent on trimmed images)
    if command_exists snap; then
        log_info "Trying Chromium via snap..."
        if snap install chromium 2>/dev/null; then
            chromium_desktop_compat_symlink || true
            log_success "Chromium installed (snap)"
            return 0
        fi
    else
        log_warning "snap not available; skipping snap-based Chromium"
    fi

    # 3) Flatpak from Flathub
    if command_exists flatpak; then
        log_info "Trying Chromium via Flatpak (Flathub)..."
        if flatpak remote-list 2>/dev/null | grep -q flathub; then
            true
        else
            flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
        fi
        if flatpak install -y flathub org.chromium.Chromium 2>/dev/null; then
            log_success "Chromium installed (Flatpak: org.chromium.Chromium)"
            log_warning "Flatpak Chromium uses a different .desktop id; update favorites if you rely on chromium_chromium.desktop"
            return 0
        fi
    fi

    log_error "Chromium could not be installed (tried xtradeb PPA, snap, flatpak)"
    return 1
}

# VS Code: install latest stable official .deb (adds Microsoft apt repo; no Snap).
install_vscode() {
    if vscode_installed; then
        log_info "VS Code is already installed (code on PATH or dpkg), skipping installation..."
        return 0
    fi

    if ! command_exists curl; then
        log_error "curl is required to download VS Code (install_curl should have run first)"
        return 1
    fi

    local arch deb_url tmpdeb="/tmp/code_stable_linux.deb"
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64) deb_url="https://update.code.visualstudio.com/latest/linux-deb-x64/stable" ;;
        arm64) deb_url="https://update.code.visualstudio.com/latest/linux-deb-arm64/stable" ;;
        *)
            log_warning "VS Code automatic install supports amd64/arm64 only (this system: $arch). Install VS Code manually."
            return 0
            ;;
    esac

    log_info "Downloading latest stable VS Code (.deb) from Microsoft..."
    # Pre-accept Microsoft apt repo prompt from the postinst (non-interactive installs)
    echo "code code/add-microsoft-repo boolean true" | debconf-set-selections

    if ! curl -fL --connect-timeout 90 --retry 3 -o "$tmpdeb" "$deb_url"; then
        log_error "VS Code download failed from $deb_url"
        return 1
    fi

    log_info "Installing VS Code (configures Microsoft apt repository for updates)..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmpdeb"; then
        rm -f "$tmpdeb"
        log_error "VS Code .deb install failed"
        return 1
    fi
    rm -f "$tmpdeb"
    log_success "VS Code installed"
}

# Install Companion Hub Desktop (requires root)
install_companion_hub() {
    local hub_url="https://dl.ci.computer/v0.1.4/linux/deb/x64/Companion%20Hub_0.1.4_amd64.deb"
    local hub_deb="/tmp/Companion_Hub_0.1.4_amd64.deb"

    if command_exists ci-os-hub-desktop && dpkg -s companion-hub >/dev/null 2>&1; then
        log_info "Companion Hub is already installed, skipping..."
        return 0
    fi

    log_info "Installing Companion Hub Desktop..."
    curl -L "$hub_url" -o "$hub_deb"

    # Prefer apt install for dependency resolution.
    if ! apt-get install -y "$hub_deb"; then
        dpkg -i "$hub_deb" || true
        apt-get install -f -y
        dpkg -i "$hub_deb"
    fi

    rm -f "$hub_deb"
    log_success "Companion Hub Desktop installed"
}

# Configure Companion Hub to auto-launch for desktop sessions and at boot.
configure_companion_hub_autostart() {
    if ! command_exists ci-os-hub-desktop; then
        log_warning "Companion Hub binary not found, skipping autostart configuration"
        return 0
    fi

    log_info "Configuring Companion Hub autostart..."

    # Ensure launcher appears in system autostart for graphical login sessions.
    install -d -m 755 /etc/xdg/autostart
    cat > /etc/xdg/autostart/companion-hub.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Companion Hub
Comment=Start Companion Hub Desktop
Exec=ci-os-hub-desktop
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

    # Ensure Hub runtime directories are writable by the actual desktop user.
    if [[ -d "${ACTUAL_HOME}/.local/share/companion-hub" ]]; then
        chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${ACTUAL_HOME}/.local/share/companion-hub" || true
    fi

    # Disable/remove legacy system service autostart. GUI apps are more reliable
    # via desktop-session autostart than root-managed system services.
    if systemctl list-unit-files | grep -q '^companion-hub-autostart.service'; then
        systemctl disable --now companion-hub-autostart.service 2>/dev/null || true
        rm -f /etc/systemd/system/companion-hub-autostart.service
        systemctl daemon-reload
    fi

    log_success "Companion Hub autostart configured"
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
    enable_apt_force_ipv4
    update_apt
    install_make
    install_docker
    install_uv
    install_homebrew
    install_asdf_nodejs
    set_global_nodejs
    # Bun removed from setup — no longer installed
    note_bashrc
    create_ci_user
    install_github_cli
    install_ollama
    configure_ollama
    pull_ollama_models
    install_cloudflared
    install_chromium
    install_vscode
    install_companion_hub
    configure_companion_hub_autostart
    enable_corepack
    remove_telemetry

        install_tailscale
    
    echo
    log_success "Setup completed successfully!"
    echo
    log_info "Next steps:"
    echo "  • User $ACTUAL_USER: Log out and log back in (or start a new shell) to use new tools; for Docker without re-login run: newgrp docker"
    echo "  • For CI user: log in as 'ci' user or use 'newgrp docker' to activate docker group"
    echo "  • Start Ollama service: systemctl start ollama"
    echo "  • Verify installations: docker --version, node --version, pnpm --version, ollama --version, gh --version"
    echo "  • Note: 'Create deploy read key' step was not specified - please add this manually if needed"
}

# Run main function
main "$@"

# Hook: install ROCm driver (standalone script; can also be run directly: ./scripts/install-rocm-driver.sh)
# Non-fatal: main setup above may succeed even if ROCm download/repo fails on a given Ubuntu codename.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/install-rocm-driver.sh" || log_warning "install-rocm-driver.sh failed or was skipped; run it manually after fixing GPU/repo issues."

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
