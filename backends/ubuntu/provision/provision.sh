#!/usr/bin/bash
# provision.sh — the canonical CI-OS ecosystem provisioning entrypoint.
#
# Replaces what were six independently-drifted entrypoints doing overlapping
# versions of "install the ecosystem" (this script under its former name
# setup-fresh-ubuntu.sh, an embedded first-boot heredoc in customize-chroot.sh,
# the undocumented ci-os-setup.sh, bootstrap-ci-os.sh's own tool list,
# pull-dev.sh's CI-Hub deploy, and an orphaned preseed late_command). See
# docs/architecture/multi-distro-design.md.
#
# What gets installed is driven by tier, not a script-specific flag:
#   core     - auto-run on first boot, and by default with no flags. Docker,
#              uv, asdf+Node, gh, cloudflared, Tailscale, Ollama+models,
#              telemetry removal, the ci user, CI-Hub (if credentials present).
#   extended - opt-in developer/workstation tooling: Homebrew, VS Code,
#              Chromium, Companion Launcher.
#   hardware - auto-detected (ROCm, LACT, Strix Halo tuning); included by
#              default. The support rule in core/lib/gpu-detect.sh no-ops these
#              on anything that is not a Strix Halo-class APU with ~32 GB RAM.
#
# REQUIREMENTS:
# - This script MUST be run as root (use: sudo ./provision.sh)
# - All system-level operations require root privileges
# - User-specific operations run as the actual user via sudo -u
#
# OPTIONS:
#   --tier=LIST   Comma-separated subset of {core,extended,hardware}.
#                 Default: core,hardware. Example: --tier=core,extended,hardware
#   --step=ci-hub Run only the CI-Hub deploy step (used by the headless
#                 captive-portal flow after WiFi/pairing setup completes).
#
# © Companion Intelligence — Lifescope Inc

set -euo pipefail

TIER_LIST="core,hardware"
STEP_ONLY=""
for arg in "$@"; do
    case "$arg" in
        --tier=*) TIER_LIST="${arg#--tier=}" ;;
        --step=*) STEP_ONLY="${arg#--step=}" ;;
        --light) TIER_LIST="core" ;;  # back-compat with the old --light flag
    esac
done

tier_requested() {
    case ",${TIER_LIST}," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# SCRIPT_DIR is backends/ubuntu/provision/ — three levels below the repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Progress for the person at the desktop (core/lib/setup-status.sh): a file that the desktop turns into a notification. It writes nothing
# unless CI_OS_SETUP_STATUS is set, and only first-boot-setup.sh sets it, so a run by hand is as quiet as before. Without the library
# (a copy of this script on its own) the calls are no-ops.
if [[ -f "$REPO_ROOT/core/lib/setup-status.sh" ]]; then
    # shellcheck source=../../../core/lib/setup-status.sh
    source "$REPO_ROOT/core/lib/setup-status.sh"
else
    ci_os_status_begin() { :; }
    ci_os_status_step() { :; }
fi

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
    local docker_list="/etc/apt/sources.list.d/docker.list"
    local docker_sources="/etc/apt/sources.list.d/docker.sources"

    # Keep a valid single source file; only remove when both coexist.
    if [[ -f "$docker_list" && -f "$docker_sources" ]]; then
        log_info "Removing legacy conflicting Docker apt source: $docker_list"
        rm -f "$docker_list"
    fi
}

# Disable stale installer media apt sources (common after USB/CD installs)
# that break apt update with: "file:/cdrom ... no longer has a Release file".
disable_stale_media_apt_sources() {
    local changed=0
    local file
    local disabled_dir="/etc/apt/disabled-sources.d"

    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$file" ]] || continue

        if grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*(cdrom:|file:/+cdrom)' "$file"; then
            sed -i -E '/^[[:space:]]*deb(-src)?[[:space:]].*(cdrom:|file:\/+cdrom)/ s/^/# ci-os disabled stale installer media repo: /' "$file"
            log_info "Disabled stale installer media apt source(s) in $file"
            changed=1
        fi
    done

    # Handle deb822 source files (Ubuntu 26.04 uses *.sources).
    # Prefer in-place disable via "Enabled: no" to avoid apt filename warnings.
    for file in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$file" ]] || continue

        if grep -Eqi '^[[:space:]]*URIs:[[:space:]].*(cdrom:|file:/+cdrom)' "$file"; then
            if grep -Eq '^[[:space:]]*Enabled:[[:space:]]*no' "$file"; then
                continue
            fi

            if grep -Eq '^[[:space:]]*Enabled:' "$file"; then
                sed -i -E 's/^[[:space:]]*Enabled:.*/Enabled: no/' "$file"
            else
                sed -i '1i Enabled: no' "$file"
            fi

            log_info "Disabled stale installer media deb822 source file: $file"
            changed=1
        fi
    done

    # Migrate older .disabled-by-ci-os files out of sources.list.d to silence apt notices.
    if compgen -G '/etc/apt/sources.list.d/*.disabled-by-ci-os' > /dev/null; then
        mkdir -p "$disabled_dir"
        for file in /etc/apt/sources.list.d/*.disabled-by-ci-os; do
            [[ -f "$file" ]] || continue
            mv "$file" "$disabled_dir/$(basename "$file")"
            log_info "Moved disabled apt source out of sources.list.d: $file"
            changed=1
        done
    fi

    if [[ "$changed" -eq 0 ]]; then
        log_info "No stale installer media apt sources detected"
    fi
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

    log_info "Installing Tailscale via snap..."
    if command -v snap >/dev/null 2>&1; then
        snap install tailscale
        log_success "Tailscale installed"
    else
        log_warning "snap not available; installing Tailscale via apt..."
        # Use the same /etc/os-release-based codename resolution install_docker
        # uses above, not `lsb_release -cs`: on a derivative distro (whose
        # stock os-release carries UBUNTU_CODENAME alongside its own
        # VERSION_CODENAME/ID) lsb_release returns the derivative's own
        # codename, which 404s against pkgs.tailscale.com's Ubuntu-only repo.
        local ubuntu_codename
        ubuntu_codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
        curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${ubuntu_codename}.noarmor.gpg" | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${ubuntu_codename}.tailscale-keyring.list" | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
        apt-get update
        apt-get install -y tailscale
        log_success "Tailscale installed"
    fi
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
        # Keep setup idempotent: best effort to ensure repo is configured, but do not fail
        # the whole setup on transient network/DNS errors when Docker is already usable.
        if ! repo_configured "/etc/apt/sources.list.d/docker.sources"; then
            log_info "Configuring Docker repository..."
            install -m 0755 -d /etc/apt/keyrings
            if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; then
                log_warning "Could not download Docker GPG key (network/DNS). Continuing because Docker is already installed."
                finalize_docker_access_for_actual_user
                return 0
            fi
            chmod a+r /etc/apt/keyrings/docker.asc
            tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
            if ! apt update; then
                log_warning "Docker repo apt update failed. Continuing because Docker is already installed."
            fi
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
            log_warning "Homebrew installation may have failed. Node.js/Bun will use apt instead."
            return 0
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
    sudo -H -u "$ACTUAL_USER" HOME="$ACTUAL_HOME" USER="$ACTUAL_USER" LOGNAME="$ACTUAL_USER" bash <<'VERIFY'
set -euo pipefail
ASDF_DIR="${ASDF_DIR:-$HOME/.asdf}"
[[ -f "$ASDF_DIR/asdf.sh" ]]

export ASDF_DIR
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$ASDF_DIR}"
export PATH="$ASDF_DIR/bin:$PATH"
. "$ASDF_DIR/asdf.sh"

install_dir="$(asdf where nodejs 22.15.1 2>/dev/null || true)"
[[ -n "$install_dir" ]]
test -x "$install_dir/bin/node"
test -x "$install_dir/bin/npm"
"$install_dir/bin/node" -v | grep -q '^v22\.15\.1'
"$install_dir/bin/npm" -v >/dev/null
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
    if ! sudo -H -u "$ACTUAL_USER" HOME="$ACTUAL_HOME" USER="$ACTUAL_USER" LOGNAME="$ACTUAL_USER" bash <<'EOF'
set -euo pipefail
ASDF_DIR="$HOME/.asdf"
ASDF_DATA_DIR="${ASDF_DATA_DIR:-$ASDF_DIR}"
ASDF_VERSION="v0.14.0"

if [[ ! -d "$ASDF_DIR" ]]; then
    git clone https://github.com/asdf-vm/asdf.git "$ASDF_DIR" --branch "$ASDF_VERSION"
fi

export PATH="$HOME/.asdf/bin:$PATH"
if [[ -f "$ASDF_DIR/asdf.sh" ]]; then
    . "$ASDF_DIR/asdf.sh"
fi
export ASDF_DIR
export ASDF_DATA_DIR

echo 'legacy_version_file = yes' > "$HOME/.asdfrc"

asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git 2>/dev/null || true

asdf install nodejs 22.15.1
asdf reshim nodejs
asdf global nodejs 22.15.1

install_dir="$(asdf where nodejs 22.15.1 2>/dev/null || true)"
[[ -n "$install_dir" ]]
test -x "$install_dir/bin/node"
test -x "$install_dir/bin/npm"
"$install_dir/bin/node" -v | grep -q '^v22\.15\.1'
"$install_dir/bin/npm" -v >/dev/null
EOF
    then
        log_warning "asdf / Node.js install failed for user $ACTUAL_USER (see errors above); continuing setup."
        return 0
    fi

    _ensure_asdf_in_bashrc_with_shim_priority

    if ! _verify_asdf_nodejs_22_15_1_installed 2>/dev/null; then
        log_warning "Post-install check failed: Node.js 22.15.1 not present under ~/.asdf/installs for $ACTUAL_USER; continuing setup."
        return 0
    fi

    log_success "asdf and Node.js installed"
}

# Set global Node.js version (standalone asdf in ~/.asdf)
set_global_nodejs() {
    log_info "Setting global Node.js version to 22.15.1 for user $ACTUAL_USER..."

    if ! sudo -H -u "$ACTUAL_USER" HOME="$ACTUAL_HOME" USER="$ACTUAL_USER" LOGNAME="$ACTUAL_USER" bash <<'EOF'
set -euo pipefail
ASDF_DIR="$HOME/.asdf"
[[ -f "$ASDF_DIR/asdf.sh" ]] || exit 0
export ASDF_DIR
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$ASDF_DIR}"
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

# Pick an Ollama default context length appropriate for installed memory. On
# unified-memory APUs Ollama otherwise defaults to the model's full window
# (e.g. 262144), which wastes memory and slows prefill for interactive use.
recommend_ollama_context_length() {
    local mem_kb mem_mb
    mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
    mem_mb=$(( ${mem_kb:-0} / 1024 ))
    if   (( mem_mb >= 49152 )); then echo 65536
    elif (( mem_mb >= 24576 )); then echo 32768
    elif (( mem_mb >= 12288 )); then echo 16384
    elif (( mem_mb >= 6144 ));  then echo 8192
    else echo 4096; fi
}

# True only when a *functional* NVIDIA GPU is present. The binary alone (e.g.
# nvidia-utils installed without a card) is not enough, so query the hardware.
has_nvidia_gpu() {
    command_exists nvidia-smi || return 1
    nvidia-smi -L 2>/dev/null | grep -q '^GPU'
}

# Detect inference accelerator and emit hardware-aware Ollama systemd drop-ins.
# GPU selection (AMD Vulkan/iGPU) is written to 10-ci-gpu.conf; the default
# context length is written SEPARATELY by write_ollama_context_dropin. The
# context drop-in is deliberately authoritative: it overrides any earlier
# OLLAMA_CONTEXT_LENGTH assignment, including one in override.conf. Any OTHER
# settings in a hand-tuned override.conf are left intact — only the context
# value is superseded (and a warning is logged when that happens).
configure_ollama_gpu() {
    local dropin_dir="/etc/systemd/system/ollama.service.d"
    local gpu_dropin="${dropin_dir}/10-ci-gpu.conf"
    mkdir -p "$dropin_dir"

    # /dev/kfd means the AMD amdgpu/ROCm kernel driver is present (a discrete
    # Radeon or a Ryzen-AI / Strix-Halo APU). Ollama drops integrated GPUs unless
    # OLLAMA_IGPU_ENABLE=1, and its Vulkan backend is the most reliable path on
    # these parts. A discrete NVIDIA GPU (if actually present) needs no extra env
    # — Ollama auto-selects CUDA — so we only force the AMD path when there is no
    # functional NVIDIA GPU.
    if [[ -e /dev/kfd ]] && ! has_nvidia_gpu; then
        log_info "AMD GPU detected (/dev/kfd); enabling Vulkan + integrated-GPU inference for Ollama"
        cat > "$gpu_dropin" <<EOF
# Managed by CI-OS provision.sh — AMD GPU inference for Ollama.
[Service]
Environment="OLLAMA_VULKAN=1"
Environment="OLLAMA_IGPU_ENABLE=1"
Environment="OLLAMA_NEW_ENGINE=1"
EOF
    elif [[ -f "$gpu_dropin" ]]; then
        # Hardware/driver situation changed (e.g. /dev/kfd gone, or a functional
        # NVIDIA GPU now present): remove our stale managed AMD drop-in so it no
        # longer forces Vulkan/iGPU. Only our own managed file is touched.
        log_info "No AMD iGPU path; removing stale managed drop-in ${gpu_dropin}"
        rm -f "$gpu_dropin"
    fi

    write_ollama_context_dropin "$dropin_dir"

    systemctl daemon-reload
    if systemctl is-active --quiet ollama 2>/dev/null; then
        systemctl restart ollama 2>/dev/null || log_warning "Could not restart ollama to apply context/GPU settings"
    fi
    log_success "Ollama GPU/context drop-ins configured"
}

# Write the hardware-aware OLLAMA_CONTEXT_LENGTH default to its own drop-in.
#
# Ollama's OpenAI-compatible /v1 endpoint IGNORES the per-request `num_ctx`
# option, so this server-level default is the only lever for /v1 consumers
# (e.g. CI-Hermes). Left unset, Ollama sizes context from available memory and
# on unified-memory APUs picks the model's full window (e.g. 131072), wasting
# memory and slowing prefill. Native-API consumers (e.g. CI-OpenClaw) can still
# request a smaller num_ctx; they just cannot exceed this default.
#
# The filename is intentionally last-sorting ("zz-"): systemd merges drop-ins in
# lexical order and the final assignment of a variable wins, so this overrides
# any earlier file that also sets OLLAMA_CONTEXT_LENGTH (override.conf,
# 10-ci-tuning.conf, a stale 10-ci-gpu.conf from an older CI-OS, …). This makes
# the function idempotent and authoritative on re-run — do NOT rename it to sort
# earlier.
write_ollama_context_dropin() {
    local dropin_dir="$1"
    local ctx_dropin="${dropin_dir}/zz-ci-ollama-context.conf"

    local ctx
    ctx="$(recommend_ollama_context_length)"

    log_info "Setting hardware-aware Ollama default context length (${ctx})"
    cat > "$ctx_dropin" <<EOF
# Managed by CI-OS provision.sh — hardware-aware Ollama default context
# length for the OpenAI-compatible (/v1) surface. Last-sorting filename so it
# overrides any earlier drop-in that also sets OLLAMA_CONTEXT_LENGTH. See
# write_ollama_context_dropin() in backends/ubuntu/provision/provision.sh.
[Service]
Environment="OLLAMA_CONTEXT_LENGTH=${ctx}"
EOF

    # Flag any other drop-in that still sets a (now-shadowed) value, so a stale
    # hand-tuned default like 8192 does not silently confuse future operators.
    local conflicts
    conflicts="$(grep -rlE '^[[:space:]]*Environment="?OLLAMA_CONTEXT_LENGTH=' "$dropin_dir" 2>/dev/null | grep -vF "$ctx_dropin" | paste -sd, - || true)"
    if [[ -n "$conflicts" ]]; then
        log_warning "OLLAMA_CONTEXT_LENGTH is also set in: ${conflicts} — now overridden by ${ctx_dropin} (=${ctx}). Remove the stale entries to avoid confusion."
    fi
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
    
    # Enable AMD GPU inference (when /dev/kfd is present and no functional NVIDIA
    # GPU) and set a hardware-aware default context length. configure_ollama_gpu
    # runs the single `systemctl daemon-reload` after all drop-ins (override.conf
    # + 10-ci-gpu.conf) are written.
    configure_ollama_gpu

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
    
    # qwen3.6:27b is part of the supported-hardware install. Small models stay.
    PULL_QWEN=0
    local gpu_detect
    gpu_detect="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/gpu-detect.sh"
    if [[ -f "$gpu_detect" ]]; then
        # shellcheck source=../../../core/lib/gpu-detect.sh
        source "$gpu_detect"
        if ci_os_hardware_supported; then
            # The Strix Halo rule above is the class gate; the data-driven fit gate (RAM and GPU memory against
            # core/manifest/model-packs.yaml) applies on top of it. "No fit data" never blocks a pull.
            if ci_os_model_gate_allows qwen3.6:27b; then
                PULL_QWEN=1
            else
                log_info "Skipping qwen3.6:27b: ${CI_OS_MODEL_FIT_REASON}"
            fi
        else
            log_info "Skipping qwen3.6:27b: ${CI_OS_HARDWARE_SUPPORT_REASON}"
        fi
    else
        log_warning "Hardware support check missing; skipping qwen3.6:27b"
    fi

    # `ollama pull` redraws a progress bar several times a second; written to the first-boot log and the journal that is hundreds of lines
    # per model. The image has a filter that keeps one line per 10 percent per layer (a checkout has not: then the output is left alone).
    PULL_FILTER=cat
    [[ -x /usr/libexec/ci-os/pull-progress-filter ]] && PULL_FILTER=/usr/libexec/ci-os/pull-progress-filter

    # Check and pull models as the actual user (ollama stores models in user's home)
    sudo -u "$ACTUAL_USER" bash <<EOF || log_warning "Failed to pull some Ollama models"
# the filter must not hide a failed pull: with pipefail the pipeline's status is the pull's, and a failure is remembered for the exit status
set -o pipefail
rc=0
# Check if models are already pulled
if ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
    echo "nomic-embed-text already installed"
else
    echo "Pulling nomic-embed-text..."
    ollama pull nomic-embed-text 2>&1 | $PULL_FILTER || rc=1
fi

if ollama list 2>/dev/null | grep -q "gemma3:1b"; then
    echo "gemma3:1b already installed"
else
    echo "Pulling gemma3:1b..."
    ollama pull gemma3:1b 2>&1 | $PULL_FILTER || rc=1
fi

# Add qwen3.6:27b only on supported hardware (see PULL_QWEN above).
if [[ "$PULL_QWEN" == 1 ]]; then
if ollama list 2>/dev/null | grep -q "qwen3.6:27b"; then
     echo "qwen3.6:27b already installed"
else
     echo "Pulling qwen3.6:27b..."
     ollama pull qwen3.6:27b 2>&1 | $PULL_FILTER || rc=1
fi
fi
exit \$rc
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
    # cloudflare-main.gpg is the vendor's current key file (CloudFlare Software Packaging 2025, rolled 2025-10-30);
    # the old cloudflare-public-v2.gpg URL serves the identical file. The ISO bakes the same name (Step 10e).
    if [[ ! -f /usr/share/keyrings/cloudflare-main.gpg ]]; then
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    fi
    
    # Add repository (only if not configured)
    if ! repo_configured "/etc/apt/sources.list.d/cloudflared.list"; then
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
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
    bash "${script_dir}/../lib/remove-telemetry.sh" --from-setup
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
    [[ -x /snap/bin/code ]] && return 0
    if command_exists snap && snap list code >/dev/null 2>&1; then
        return 0
    fi
    if dpkg-query -W -f='${Status}' code 2>/dev/null | grep -q 'ok installed'; then
        return 0
    fi
    return 1
}

install_vscode_snap_fallback() {
    log_warning "Falling back to VS Code Snap install (code --classic)..."

    if ! command_exists snap; then
        log_info "snap not detected; installing snapd for VS Code fallback..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y snapd; then
            log_error "Could not install snapd for VS Code fallback"
            return 1
        fi
        systemctl enable --now snapd.socket >/dev/null 2>&1 || true
    fi

    if ! snap install code --classic; then
        log_error "VS Code Snap fallback failed"
        return 1
    fi

    if vscode_installed; then
        log_success "VS Code installed (snap fallback)"
        return 0
    fi

    log_error "VS Code fallback reported success but code command was not detected"
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
    if ! command_exists snap; then
        log_info "snap not detected; installing snapd for Chromium fallback..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y snapd; then
            systemctl enable --now snapd.socket >/dev/null 2>&1 || true
        else
            log_warning "Could not install snapd; skipping snap-based Chromium"
        fi
    fi

    if command_exists snap; then
        log_info "Trying Chromium via snap..."
        if snap install chromium 2>/dev/null; then
            if chromium_usable; then
                chromium_desktop_compat_symlink || true
                log_success "Chromium installed (snap)"
                return 0
            fi
            chromium_desktop_compat_symlink || true
            log_warning "snap install chromium completed, but chromium is not yet usable on PATH"
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
        log_warning "VS Code .deb download failed from $deb_url"
        rm -f "$tmpdeb"
        install_vscode_snap_fallback
        return $?
    fi

    log_info "Installing VS Code (configures Microsoft apt repository for updates)..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmpdeb"; then
        rm -f "$tmpdeb"
        log_warning "VS Code .deb install failed"
        install_vscode_snap_fallback
        return $?
    fi
    rm -f "$tmpdeb"
    log_success "VS Code installed"
}

# Install Companion Launcher (requires root) — a native/Electron GUI app that
# opens a browser tab to the CI Hub Service backend (deployed separately by
# deploy_ci_hub below). Renamed from "Companion Hub Desktop" to resolve a
# 3-way naming collision on "Hub" — see docs/architecture/multi-distro-design.md.
# The underlying binary/package names and the dl.ci.computer download layout
# are external artifacts this repo doesn't control/build. The binary is
# `companion-hub` (package `companion-hub`) since CI-Hub 2026-06-03
# (tauri.conf.json mainBinaryName); releases up to v0.1.4 shipped
# `ci-os-hub-desktop`, which is still accepted as a legacy name.
# The Companion OS ISO bakes the pinned release (core/manifest/tier-b-pins.env,
# customize-chroot.sh Step 10e), so on an ISO install this function is a no-op.
install_companion_launcher() {
    local base_url="https://dl.ci.computer"
    local fallback_version="v0.1.4"
    local version_tag="$fallback_version"
    local clean_version latest_json manifest_json manifest_url
    local arch deb_arch dl_arch arch_match_regex
    local hub_url hub_deb

    if { command_exists companion-hub || command_exists ci-os-hub-desktop; } && dpkg -s companion-hub >/dev/null 2>&1; then
        log_info "Companion Launcher is already installed, skipping..."
        return 0
    fi

    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64)
            deb_arch="amd64"
            dl_arch="x64"
            arch_match_regex='(amd64|x64)'
            ;;
        arm64)
            deb_arch="arm64"
            dl_arch="arm"
            arch_match_regex='(arm64|aarch64|arm)'
            ;;
        *)
            log_warning "Companion Launcher install supports amd64/arm64 only (this system: $arch). Skipping."
            return 0
            ;;
    esac

    latest_json="$(curl -fsSL --connect-timeout 20 --retry 2 "${base_url}/latest.json" 2>/dev/null || true)"
    if [[ -n "$latest_json" ]]; then
        version_tag="$(echo "$latest_json" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)"/\1/' || true)"
        if [[ -z "$version_tag" ]]; then
            version_tag="$fallback_version"
        fi
    fi

    clean_version="${version_tag#v}"
    manifest_url="${base_url}/${version_tag}/manifest.json"
    manifest_json="$(curl -fsSL --connect-timeout 20 --retry 2 "$manifest_url" 2>/dev/null || true)"
    hub_url=""
    if [[ -n "$manifest_json" ]]; then
        hub_url="$(echo "$manifest_json" | tr '\n' ' ' | grep -Eo 'https?://[^"[:space:]]+\.deb' | grep -Ei "$arch_match_regex" | head -n 1 || true)"
    fi

    # Fallback to deterministic dl.ci.computer path if manifest parsing returns no match.
    # URL/filename ("Companion Hub") is the external artifact's own naming — unchanged.
    if [[ -z "$hub_url" ]]; then
        hub_url="${base_url}/${version_tag}/linux/deb/${dl_arch}/Companion%20Hub_${clean_version}_${deb_arch}.deb"
    fi

    hub_deb="/tmp/Companion_Hub_${clean_version}_${deb_arch}.deb"

    # The release manifest carries a sha256 per artifact; use it when present (the v0.1.4 fallback has none).
    local expected_sha=""
    if [[ -n "$manifest_json" ]] && command_exists jq; then
        expected_sha="$(echo "$manifest_json" | jq -r --arg u "$hub_url" \
            '[.. | objects | select(.url? == $u) | .sha256?] | first // empty' 2>/dev/null || true)"
    fi

    log_info "Installing Companion Launcher for ${arch} from ${hub_url}..."
    if ! curl -fL --connect-timeout 90 --retry 3 -o "$hub_deb" "$hub_url"; then
        if [[ "$version_tag" != "$fallback_version" ]]; then
            clean_version="${fallback_version#v}"
            hub_url="${base_url}/${fallback_version}/linux/deb/${dl_arch}/Companion%20Hub_${clean_version}_${deb_arch}.deb"
            hub_deb="/tmp/Companion_Hub_${clean_version}_${deb_arch}.deb"
            expected_sha=""
            log_warning "Primary Companion Launcher download failed; retrying fallback ${hub_url}"
            curl -fL --connect-timeout 90 --retry 3 -o "$hub_deb" "$hub_url"
        else
            log_error "Failed to download Companion Launcher from ${hub_url}"
            return 1
        fi
    fi
    if [[ -n "$expected_sha" ]]; then
        if [[ "$(sha256sum "$hub_deb" | awk '{print $1}')" != "$expected_sha" ]]; then
            log_error "Companion Launcher sha256 does not match the release manifest; not installing"
            rm -f "$hub_deb"
            return 1
        fi
        log_info "Companion Launcher sha256 verified against the release manifest"
    else
        log_warning "No sha256 available for ${hub_url}; installing without checksum verification"
    fi

    # Prefer apt install for dependency resolution.
    if ! apt-get install -y "$hub_deb"; then
        dpkg -i "$hub_deb" || true
        apt-get install -f -y
        dpkg -i "$hub_deb"
    fi

    rm -f "$hub_deb"
    log_success "Companion Launcher installed"
}

# Configure Companion Launcher to auto-launch for desktop sessions and at boot.
configure_companion_launcher_autostart() {
    local launcher_bin=""
    if command_exists companion-hub; then launcher_bin="companion-hub"
    elif command_exists ci-os-hub-desktop; then launcher_bin="ci-os-hub-desktop"   # legacy (<= v0.1.4)
    fi
    if [[ -z "$launcher_bin" ]]; then
        log_warning "Companion Launcher binary not found, skipping autostart configuration"
        return 0
    fi

    log_info "Configuring Companion Launcher autostart..."

    # Ensure launcher appears in system autostart for graphical login sessions.
    install -d -m 755 /etc/xdg/autostart
    rm -f /etc/xdg/autostart/companion-hub.desktop  # old filename, pre-rename
    # The ISO can bake its own entry (Exec=/usr/libexec/ci-os/launcher-autostart, which refuses to run in a live
    # session). Keep it; rewriting it here would drop that guard.
    if grep -q 'launcher-autostart' /etc/xdg/autostart/companion-launcher.desktop 2>/dev/null; then
        log_info "Companion Launcher autostart already provided by the image, keeping it"
    else
    cat > /etc/xdg/autostart/companion-launcher.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Companion Launcher
Comment=Start Companion Launcher
Exec=${launcher_bin}
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    fi

    # Ensure Launcher runtime directories are writable by the actual desktop user.
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

    log_success "Companion Launcher autostart configured"
    pin_companion_launcher_to_dock
}

# Pin Companion Launcher's icon to the GNOME dock/favorites — a distinct
# feature from autostart-on-login above. Ported from the standalone
# setup/CI-OS-Hub-Setup/install-or-update-hub.sh (deleted: zero callers, and
# its install/download logic was otherwise a near-duplicate of
# install_companion_launcher above — this was the one piece of it not
# already covered elsewhere).
pin_companion_launcher_to_dock() {
    # The current .deb installs "Companion Hub.desktop"; releases up to v0.1.4 installed ci-os-hub-desktop.desktop.
    local desktop_id="Companion Hub.desktop"
    [[ -f "/usr/share/applications/${desktop_id}" ]] || desktop_id="ci-os-hub-desktop.desktop"

    if [[ -z "${ACTUAL_USER:-}" ]] || [[ "$ACTUAL_USER" == "root" ]]; then
        log_warning "No non-root desktop user detected; skipping dock pin."
        return 0
    fi

    local uid_num runtime_dir dbus_addr
    uid_num="$(id -u "$ACTUAL_USER" 2>/dev/null || true)"
    runtime_dir="/run/user/${uid_num}"
    dbus_addr="unix:path=${runtime_dir}/bus"

    if [[ ! -S "${runtime_dir}/bus" ]]; then
        log_warning "No active D-Bus session for $ACTUAL_USER (not logged in to a desktop session?). Companion Launcher was not pinned to the dock; log in and re-run to pin it."
        return 0
    fi

    local env_args=(DISPLAY=:0 XAUTHORITY="${ACTUAL_HOME}/.Xauthority" DBUS_SESSION_BUS_ADDRESS="$dbus_addr")

    local current_favs
    current_favs="$(sudo -u "$ACTUAL_USER" env "${env_args[@]}" gsettings get org.gnome.shell favorite-apps 2>/dev/null || true)"

    if [[ "$current_favs" == *"$desktop_id"* ]]; then
        log_info "Companion Launcher is already pinned to the dock for $ACTUAL_USER."
        return 0
    fi

    local favs_clean new_favs
    favs_clean="$(echo "$current_favs" | sed -e "s/^\[//" -e "s/\]$//" -e "s/'//g" -e 's/, /,/g')"
    if [[ -z "$favs_clean" ]]; then
        new_favs="['$desktop_id']"
    else
        new_favs="['$(echo "$favs_clean" | sed "s/,/', '/g")', '$desktop_id']"
    fi

    if sudo -u "$ACTUAL_USER" env "${env_args[@]}" gsettings set org.gnome.shell favorite-apps "$new_favs" 2>/dev/null; then
        log_success "Companion Launcher pinned to the dock for $ACTUAL_USER."
    else
        log_warning "gsettings call failed; Companion Launcher was not pinned to the dock."
    fi
}

# Deploy the CI Hub Service backend (Docker/Runtipi, ci-os-hub container,
# port 5002) via core/lib/ci-hub.sh — the distro-portable, Docker-Compose-based
# deploy script shared with the headless captive-portal flow. Gated on
# registry credentials by design (private registry); core/lib/ci-hub.sh itself
# reports a single clear message and exits 0 (not a hard failure) when they're
# absent, rather than this function duplicating that check.
deploy_ci_hub() {
    if ! command_exists docker; then
        log_warning "Docker not installed; skipping CI-Hub deploy"
        return 0
    fi

    # REPO_ROOT resolves correctly in both contexts this script runs in: a repo
    # checkout (core/lib/ci-hub.sh is a real sibling), and the staged image
    # customize-chroot.sh builds under /usr/lib/ci-os/bootstrap/ (which
    # preserves the same backends/ubuntu/provision/ -> repo-root relative
    # depth, so REPO_ROOT/core/lib/ci-hub.sh resolves there too).
    local ci_hub_sh="${REPO_ROOT:-}/core/lib/ci-hub.sh"
    if [[ ! -f "$ci_hub_sh" ]]; then
        log_warning "core/lib/ci-hub.sh not found at $ci_hub_sh; skipping CI-Hub deploy"
        return 0
    fi

    log_info "Deploying CI Hub Service..."
    bash "$ci_hub_sh" || log_warning "CI-Hub deploy had issues; run core/lib/ci-hub.sh manually with registry credentials set"
}

# The human user of this machine: the lowest uid from 1000 up that has a login shell and is not the "ci" service user (create_ci_user).
# First boot runs as root with no SUDO_USER, so detect_user cannot tell: ACTUAL_USER is root there.
companion_hub_user() {
    getent passwd | sort -t: -k3 -n | awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "ci" && $7 !~ /(nologin|false)$/ { print $1; exit }'
}

# Start the Companion Hub the way Hub itself does for a headless machine: `companion-hub --detached` is the desktop app without a
# window. It checks Docker and Compose (2.33 or newer), seeds ~/.local/share/companion-hub with generated secrets, pulls the stack's
# images (public ghcr.io images, postgres, rabbitmq, traefik; about 0.4 GB) and starts it, then exits; the containers come back with
# Docker. Run as the human user, because Hub's data and its Docker access are per user. Nothing here needs a credential: pairing
# the device with a CI Account is the person's, in the Hub window (docs.ci.computer, getting-started/installation: Companion Core
# hardware ships the same way, with Hub preinstalled and running). The packaged Hub is not the legacy deploy_ci_hub path above.
# Permanent reasons to skip (no Hub, no Docker, Compose too old, no user yet) return 0; a failed start returns 1, so the first-boot
# retry (the timer, three attempts) runs it again.
start_companion_hub() {
    local stamp="${CI_OS_HUB_STAMP:-/var/lib/ci-os/.companion-hub-started}" hub_user min_compose="2.33" have_compose   # CI_OS_HUB_STAMP: for the test
    if [[ -f "$stamp" ]]; then
        log_info "Companion Hub was started on $(cat "$stamp"); skipping"
        return 0
    fi
    if ! command_exists companion-hub; then
        log_info "Companion Hub is not installed; skipping the Hub start"
        return 0
    fi
    if ! command_exists docker; then
        log_warning "Docker is not installed; skipping the Hub start"
        return 0
    fi
    hub_user="$(companion_hub_user)"
    if [[ -z "$hub_user" ]]; then
        log_warning "No human user on this machine yet; skipping the Hub start (run: companion-hub --detached, as that user)"
        return 0
    fi
    have_compose="$(docker compose version --short 2>/dev/null | head -n 1 | tr -d 'v' || true)"
    if [[ -z "$have_compose" ]] || [[ "$(printf '%s\n%s\n' "$min_compose" "$have_compose" | sort -V | head -n 1)" != "$min_compose" ]]; then
        log_warning "Docker Compose ${have_compose:-missing}: the Hub needs $min_compose or newer; skipping the Hub start"
        return 0
    fi
    id -nG "$hub_user" | tr ' ' '\n' | grep -qx docker || usermod -aG docker "$hub_user"
    log_info "Starting Companion Hub as $hub_user (companion-hub --detached)..."
    if sudo -u "$hub_user" -H timeout 1500 companion-hub --detached; then
        mkdir -p "$(dirname "$stamp")"
        date -u > "$stamp"
        log_success "Companion Hub started. Pair it with your CI Account from the Companion Hub window (docs.ci.computer/docs/getting-started)."
        return 0
    fi
    log_warning "Companion Hub did not start (see above); the first-boot retry will try again"
    return 1
}

# Main function
main() {
    log_info "CI-OS provisioning (tiers: ${TIER_LIST})"
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

    # --step=ci-hub: used by the headless captive-portal flow after WiFi/pairing
    # completes. Skips the rest of provisioning — Docker is assumed already
    # present from an earlier core-tier run (first boot or manual).
    if [[ "$STEP_ONLY" == "ci-hub" ]]; then
        deploy_ci_hub
        return 0
    fi

    log_info "✓ Running with root privileges (EUID: $EUID)"
    log_info "✓ All system operations will run with root privileges"
    log_info "✓ User-specific operations will run as user: $ACTUAL_USER"
    log_info "Starting installation process..."
    echo

    # The steps a person sees in the setup notification: one for the preparation, six for the core tier, one for the extended tier. Keep
    # this count equal to the ci_os_status_step calls below (backends/ubuntu/chroot/tests/setup-progress.sh checks it).
    status_steps=1
    if tier_requested core; then status_steps=$((status_steps + 6)); fi
    if tier_requested extended; then status_steps=$((status_steps + 1)); fi
    ci_os_status_begin "$status_steps"

    ci_os_status_step "Preparing the system"
    install_curl
    fix_docker_apt_conflicts
    enable_apt_force_ipv4
    disable_stale_media_apt_sources
    update_apt
    install_make
    if tier_requested core; then
        ci_os_status_step "Installing Docker"
        install_docker
        ci_os_status_step "Installing developer tools"
        install_uv
        install_asdf_nodejs
        set_global_nodejs || true
        note_bashrc
        create_ci_user
        install_github_cli
        ci_os_status_step "Installing the AI runtime (Ollama)"
        install_ollama
        configure_ollama
        ci_os_status_step "Downloading the AI models (the longest step)"
        pull_ollama_models
        ci_os_status_step "Installing network tools"
        install_cloudflared
        enable_corepack
        remove_telemetry
        install_tailscale
        ci_os_status_step "Starting Companion Hub"
        deploy_ci_hub
        start_companion_hub
    fi
    if tier_requested extended; then
        ci_os_status_step "Installing optional apps"
        # Homebrew is optional; don't fail the run if it has issues (Node/Bun use apt)
        set +e
        install_homebrew || log_warning "Homebrew had issues; Node.js will use apt"
        set -e
        install_chromium
        install_vscode
        install_companion_launcher
        configure_companion_launcher_autostart
    fi

    echo
    log_success "Setup completed successfully!"
    echo
    log_info "Next steps:"
    echo "  • Open Companion Hub (from the dock, or at http://<this machine's address>:5002) and pair it with your CI Account."
    if command -v ci-os-info >/dev/null 2>&1; then
        echo "  • See how the machine is doing at any time: ci-os-info"
    fi
    echo "  • If a command says it has no permission for Docker, sign out and back in so the new group applies (or run: newgrp docker)."
}

# Run main function
main "$@"

# Post-main: ROCm, Strix Halo boot params, and LACT. Hardware tier. Each one
# no-ops unless core/lib/gpu-detect.sh says this machine is supported
# (Strix Halo-class APU, ~32 GB RAM or more). Non-fatal: a ROCm repo miss
# does not undo the core install above.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if tier_requested hardware && [[ -f "${SCRIPT_DIR}/../lib/install-rocm-driver.sh" ]]; then
    "${SCRIPT_DIR}/../lib/install-rocm-driver.sh" || log_warning "install-rocm-driver.sh failed or was skipped; run it manually after fixing GPU/repo issues."
fi

# Hook: tune AMD Strix Halo unified-memory boot params (iommu=pt, amdgpu.gttsize,
# ttm.pages_limit, and amdttm.pages_limit when AMD's DKMS amdgpu driver is installed:
# that driver's own copy of TTM ignores ttm.pages_limit). Runs at first-boot/provisioning time (not ISO build time)
# because it depends on detecting the *target* hardware (CPU model / rocminfo)
# and total RAM, neither of which is known when the ISO is built. Standalone
# script; can also be run directly: ./backends/ubuntu/lib/strix-halo-boot-params.sh
# Gated on confidently-detected Strix Halo-class hardware + large RAM (see
# script header); no-ops on everything else. Idempotent — safe to re-run.
# Non-fatal: a GRUB/detection hiccup here should not fail the rest of setup.
if tier_requested hardware; then
    bash "${SCRIPT_DIR}/../lib/strix-halo-boot-params.sh" || log_warning "strix-halo-boot-params.sh failed or was skipped; run it manually to enable large-GTT boot params on Strix Halo hardware."
fi

# Install LACT GPU monitor (latest release from GitHub). The .deb built for THIS Ubuntu release is chosen by its
# series suffix (ubuntu-2604): see backends/ubuntu/lib/lact-release.sh.
install_lact() {
    if command_exists lact; then
        log_info "LACT GPU monitor is already installed, skipping..."
        return 0
    fi

    log_info "Downloading and installing LACT GPU monitor..."
    # shellcheck source=../lib/lact-release.sh
    source "${SCRIPT_DIR}/../lib/lact-release.sh"
    local lact_series_name release_json asset LACT_SHA256 got_sha
    lact_series_name="$(lact_series)"
    release_json="$(curl -fsSL --connect-timeout 20 --retry 2 https://api.github.com/repos/ilya-zlobintsev/LACT/releases/latest 2>/dev/null || true)"
    asset="$(printf '%s' "$release_json" | lact_pick_asset "$lact_series_name" || true)"
    if [[ -z "$asset" ]]; then
        log_error "Could not find a LACT .deb for ${lact_series_name} in the latest release (no build for this Ubuntu release, or GitHub could not be reached)."
        return 1
    fi
    LACT_DEB_URL="${asset%%$'\t'*}"
    LACT_SHA256="${asset#*$'\t'}"
    TMP_DEB="/tmp/lact-latest.deb"
    curl -fL --connect-timeout 30 --retry 2 "$LACT_DEB_URL" -o "$TMP_DEB"
    if [[ -n "$LACT_SHA256" ]]; then
        got_sha="$(sha256sum "$TMP_DEB" | awk '{print $1}')"
        if [[ "$got_sha" != "$LACT_SHA256" ]]; then
            log_error "LACT .deb sha256 does not match the release (got ${got_sha}, release says ${LACT_SHA256}); not installing"
            rm -f "$TMP_DEB"
            return 1
        fi
        log_info "LACT .deb sha256 verified against the release"
    else
        log_warning "The release lists no sha256 for ${LACT_DEB_URL}; installing without checksum verification"
    fi
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

# LACT is part of the supported-hardware install. Skip it everywhere else.
if tier_requested hardware; then
    gpu_detect="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/gpu-detect.sh"
    if [[ -f "$gpu_detect" ]]; then
        # shellcheck source=../../../core/lib/gpu-detect.sh
        source "$gpu_detect"
    fi
    if declare -F ci_os_hardware_supported >/dev/null && ci_os_hardware_supported; then
        install_lact || true
    else
        log_info "Skipping LACT: ${CI_OS_HARDWARE_SUPPORT_REASON:-hardware support check unavailable}"
    fi
fi

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
            log_info "No desktop session for ${ACTUAL_USER} right now; GNOME power mode stays at its default."
        fi
    else
        log_info "No desktop user to configure; GNOME power mode stays at its default."
    fi
}

set_gnome_power_performance
