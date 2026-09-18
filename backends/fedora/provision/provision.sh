#!/usr/bin/bash
# provision.sh — the Fedora (dnf) ecosystem provisioning entrypoint.
#
# This is a genuine reimplementation of backends/ubuntu/provision/provision.sh
# for dnf/rpm, NOT a thin wrapper like backends/mint/provision/provision.sh —
# Mint shares Ubuntu's apt base exactly; Fedora's dnf syntax and most package
# names differ substantially. Structure (tier gating, function-per-tool shape,
# require_root/detect_user/log_* conventions, the --tier=/--step= argument
# parsing) is copied from Ubuntu's provision.sh unchanged, because none of
# that is apt-specific. See core/manifest/role-map/dnf.yaml for the package/
# repo data this script implements, and docs/architecture/multi-distro-design.md
# for the overall rollout plan (this is Phase 3a: provisioning + theming;
# Phase 3b, kickstart/lorax ISO building, is explicitly out of scope here).
#
# What's in this file, by confidence level (see also each function's own
# header comment):
#
#   CONFIRMED (backed by hands-on Fedora packaging research — see the research
#   notes this script was built from, and core/manifest/role-map/dnf.yaml):
#     install_docker, install_github_cli, install_cloudflared, install_tailscale,
#     install_uv, install_homebrew, install_ollama, install_vscode,
#     install_chromium, remove_telemetry, create_ci_user.
#
#   BEST-EFFORT (translated by inference, not directly covered by that
#   research — flagged inline where it matters):
#     install_asdf_nodejs_dnf_prereqs (package-name mapping for asdf/Node
#     build prerequisites), configure_passwordless_sudo (wheel vs. Ubuntu's
#     sudo group).
#
#   INTENTIONALLY STUBBED GAPS (no confident Fedora path found; these log a
#   clear message and return 0 rather than guessing at commands that could
#   partially apply and leave the system half-configured):
#     install_companion_launcher (no Fedora/.rpm build is published anywhere
#     for Companion Launcher — dl.ci.computer only ships .deb), the ROCm
#     driver step (no official Fedora ROCm repo from AMD), install_lact (LACT
#     GitHub releases were not verified to publish an .rpm asset).
#
# What's identical to Ubuntu's provision.sh, reused verbatim because it has
# no apt-specific content at all: the asdf/Node.js install flow itself (asdf
# is a git-clone + shell-function tool, not tied to any system package
# manager), Ollama install/service/model-pull, corepack/pnpm enablement,
# create_ci_user, deploy_ci_hub (core/lib/ci-hub.sh is Docker-Compose-based,
# confirmed distro-portable), and the --tier=/--step=ci-hub argument parsing.
#
# NOT ported from Ubuntu's provision.sh, deliberately, because they are
# apt-specific fixups with no dnf analog and Fedora packaging research found
# no equivalent problem to fix:
#   - fix_docker_apt_conflicts (docker.list vs. docker.sources Signed-By
#     conflicts — an apt/deb822 quirk; dnf's single docker-ce.repo file has
#     no equivalent failure mode)
#   - disable_stale_media_apt_sources (stale cdrom: apt sources from
#     USB/CD installer media — no dnf analog was researched or found)
#   - enable_apt_force_ipv4 (writes /etc/apt/apt.conf.d/99force-ipv4 to work
#     around IPv6 apt-fetch issues — dnf has its own ip_resolve config knob,
#     but Fedora packaging research found no equivalent problem report to fix,
#     so this wasn't translated rather than added speculatively)
# Also NOT ported: the Strix Halo GRUB boot-param tuning
# (backends/ubuntu/lib/strix-halo-boot-params.sh) and LACT dock-pinning —
# out of scope for this pass (no backends/fedora/lib/ equivalent exists yet,
# and LACT install itself is stubbed below, so there's nothing to pin).
#
# REQUIREMENTS:
# - This script MUST be run as root (use: sudo ./provision.sh)
# - All system-level operations require root privileges
# - User-specific operations run as the actual user via sudo -u
# - Target: Fedora Workstation, dnf5 (Fedora 41+) or dnf4. Scripts branch on
#   dnf5 binary presence rather than assuming one syntax — see have_dnf5().
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

# SCRIPT_DIR is backends/fedora/provision/ — three levels below the repo root,
# same depth as backends/ubuntu/provision/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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

# Helper function to check if an rpm package is installed (dnf/rpm equivalent
# of Ubuntu's `dpkg -l | grep "^ii.*$1 "`)
package_installed() {
    rpm -q "$1" &>/dev/null
}

# Helper function to check if a dnf/yum repo file is configured
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

# True if `dnf` on this system is dnf5 (Fedora 41+ ships dnf5 as `dnf`).
# Both `dnf5 config-manager` and `dnf4`'s config-manager plugin exist, but the
# subcommand syntax differs (`addrepo --from-repofile=` vs. `--add-repo`), so
# every repo-adding function below branches on this rather than assuming one
# form — per the Fedora packaging research this script implements (see
# core/manifest/role-map/dnf.yaml).
have_dnf5() {
    command_exists dnf5 && return 0
    dnf --version 2>/dev/null | head -n1 | grep -qi 'dnf5'
}

# Ensure the config-manager subcommand is available before any addrepo call.
ensure_config_manager_plugin() {
    if have_dnf5; then
        dnf5 config-manager --help &>/dev/null && return 0
        log_info "Installing dnf5-plugins for the config-manager subcommand..."
        dnf install -y dnf5-plugins
    else
        dnf config-manager --help &>/dev/null && return 0
        log_info "Installing 'dnf-command(config-manager)' for the config-manager subcommand..."
        dnf install -y 'dnf-command(config-manager)'
    fi
}

# Add a third-party repo from a vendor-published *.repo file URL. Confirmed
# form for dnf5 (Fedora 41/42) and dnf4 — see core/manifest/role-map/dnf.yaml
# for the per-tool URLs this is called with.
add_repo_from_url() {
    local repofile_url="$1"
    ensure_config_manager_plugin
    if have_dnf5; then
        dnf5 -y config-manager addrepo --from-repofile="$repofile_url"
    else
        dnf config-manager --add-repo "$repofile_url"
    fi
}

# Install curl (requires root)
install_curl() {
    if command_exists curl; then
        log_info "curl is already installed, skipping..."
        return 0
    fi

    log_info "Installing curl..."
    dnf install -y curl
    log_success "curl installed"
}

# Refresh dnf metadata (dnf equivalent of Ubuntu's `apt-get update`).
update_dnf_cache() {
    log_info "Refreshing dnf metadata..."
    dnf makecache
    log_success "dnf metadata refreshed"
}

# Install make (requires root)
install_make() {
    if command_exists make; then
        log_info "make is already installed, skipping..."
        return 0
    fi

    log_info "Installing make..."
    dnf install -y make
    log_success "make installed"
}

# Install Tailscale (requires root)
#
# CONFIRMED via research: Fedora has a release-number-keyed repo path (unlike
# Ubuntu/Mint's codename-keyed one), and Fedora sets VERSION_ID directly in
# /etc/os-release with no derivative-distro mismatch problem analogous to
# Mint. Ubuntu's function falls back from snap to an apt repo only when snap
# is missing; that snap branch is skipped here entirely and this goes
# straight to the dnf repo method, per the research recommendation.
install_tailscale() {
    if command_exists tailscale; then
        log_info "Tailscale is already installed, skipping..."
        return 0
    fi

    log_info "Installing Tailscale via the Fedora-specific dnf repo..."

    local version_id
    version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    if [[ -z "$version_id" ]]; then
        log_error "Could not determine Fedora VERSION_ID from /etc/os-release; cannot resolve the Tailscale repo URL."
        return 1
    fi

    if ! repo_configured "/etc/yum.repos.d/tailscale.repo"; then
        add_repo_from_url "https://pkgs.tailscale.com/stable/fedora/${version_id}/tailscale.repo"
    fi
    dnf install -y tailscale
    log_success "Tailscale installed"
}

# Ensure /var/run/docker.sock is root:docker and mode 660 (fixes some partial installs)
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
#
# CONFIRMED via research: download.docker.com/linux/fedora/docker-ce.repo is a
# real repo whose file embeds $releasever/$basearch itself, so — unlike
# Ubuntu's install_docker(), which resolves UBUNTU_CODENAME/VERSION_CODENAME
# into the repo URL by hand — no codename resolution is needed here at all.
install_docker() {
    if command_exists docker && docker --version &>/dev/null; then
        log_info "Docker is already installed, skipping installation..."
        finalize_docker_access_for_actual_user
        return 0
    fi

    log_info "Installing Docker via the official Fedora dnf repo..."

    if ! repo_configured "/etc/yum.repos.d/docker-ce.repo"; then
        add_repo_from_url "https://download.docker.com/linux/fedora/docker-ce.repo"
    fi

    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Ensure docker group exists (usually created by the docker-ce package,
    # but ensure it exists in case package hooks differ across dnf versions).
    if ! getent group docker >/dev/null 2>&1; then
        log_info "Creating docker group..."
        groupadd docker
        log_success "Docker group created"
    fi

    # Unlike Debian/Ubuntu's postinst, Fedora RPM packaging convention does
    # not auto-enable/start services on install — do it explicitly.
    if ! systemctl enable --now docker 2>/dev/null; then
        log_warning "Could not enable/start docker.service; start it manually with: systemctl enable --now docker"
    fi

    log_success "Docker installed"
    finalize_docker_access_for_actual_user
}

# Install UV
#
# CONFIRMED via research: astral.sh/uv/install.sh contains zero package-
# manager references — pure static-binary shell installer, distro-generic.
# Reused verbatim from Ubuntu's install_uv(); no dnf translation needed.
install_uv() {
    if sudo -u "$ACTUAL_USER" bash -c "command -v uv" &>/dev/null; then
        log_info "UV is already installed for user $ACTUAL_USER, skipping..."
        return 0
    fi

    log_info "Installing UV for user $ACTUAL_USER..."
    sudo -u "$ACTUAL_USER" bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
    log_success "UV installed"
}

# Configure passwordless sudo for user (required for Homebrew noninteractive installation)
#
# BEST-EFFORT TRANSLATION: Ubuntu's equivalent adds the user to the `sudo`
# group (Debian/Ubuntu convention). Fedora Workstation's convention is the
# `wheel` group instead — sudo is preconfigured for %wheel in Fedora's
# default /etc/sudoers via `@includedir /etc/sudoers.d`, same as Ubuntu's
# %sudo. This is a standard, well-known Fedora convention, not something the
# Fedora packaging research explicitly re-verified.
configure_passwordless_sudo() {
    log_info "Configuring passwordless sudo for user $ACTUAL_USER..."

    if ! user_in_group "$ACTUAL_USER" "wheel"; then
        log_info "Adding user $ACTUAL_USER to wheel group..."
        usermod -aG wheel "$ACTUAL_USER"
        log_success "User $ACTUAL_USER added to wheel group"
    else
        log_info "User $ACTUAL_USER is already in wheel group"
    fi

    if sudo -u "$ACTUAL_USER" sudo -n true 2>/dev/null; then
        log_info "User $ACTUAL_USER already has passwordless sudo access"
        return 0
    fi

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
#
# CONFIRMED via research: the core installer (Homebrew/install/HEAD/install.sh)
# is distro-generic, but its missing-build-tools hint explicitly distinguishes
# Fedora/RHEL-like distros via dnf group id `development-tools`, and Fedora's
# procps package is named procps-ng (not procps as on Ubuntu).
install_homebrew() {
    local brew_bin="/home/linuxbrew/.linuxbrew/bin/brew"

    if sudo -u "$ACTUAL_USER" bash -c "command -v brew" &>/dev/null; then
        log_info "Homebrew is already installed and available for user $ACTUAL_USER, skipping installation..."
        _homebrew_ensure_bashrc
        return 0
    fi

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

    configure_passwordless_sudo

    log_info "Installing Homebrew dependencies (dnf group 'development-tools' + procps-ng curl file git)..."
    if ! dnf group list --installed 2>/dev/null | grep -qi 'Development Tools'; then
        dnf group install -y development-tools 2>/dev/null || dnf groupinstall -y "Development Tools"
    fi
    local deps=("procps-ng" "curl" "file" "git")
    for dep in "${deps[@]}"; do
        if ! package_installed "$dep"; then
            dnf install -y "$dep"
        fi
    done

    log_info "Running Homebrew installer..."
    sudo -u "$ACTUAL_USER" bash <<EOF || true
export NONINTERACTIVE=1
export CI=1
/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
EOF

    if [[ -d /home/linuxbrew/.linuxbrew ]]; then
        log_info "Ensuring Homebrew directory permissions for $ACTUAL_USER..."
        chown -R "$ACTUAL_USER:$ACTUAL_USER" /home/linuxbrew/.linuxbrew
    fi

    if [[ -f "$brew_bin" ]]; then
        log_info "Running brew update to complete installation..."
        sudo -u "$ACTUAL_USER" "$brew_bin" update --force --quiet 2>/dev/null || true
    fi

    if ! sudo -u "$ACTUAL_USER" bash -c "eval \"\$($brew_bin shellenv)\" && command -v brew" &>/dev/null; then
        if [[ -f "$brew_bin" ]]; then
            log_warning "Homebrew installed but not in PATH yet. Will be available after shell restart."
        else
            log_warning "Homebrew installation may have failed. Node.js/Bun will use dnf/asdf instead."
            return 0
        fi
    fi

    _homebrew_ensure_bashrc
    log_success "Homebrew installed and configured"
}

# Ensure Homebrew eval is in user's bashrc (helper used by install_homebrew).
# Identical to Ubuntu's — Homebrew's Linux install path (/home/linuxbrew) is
# the same regardless of distro.
_homebrew_ensure_bashrc() {
    RC="$ACTUAL_HOME/.bashrc"
    if ! grep -q "linuxbrew" "$RC"; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$RC"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$RC"
        log_info "Added Homebrew to bashrc"
    fi
}

# dnf packages for asdf / Node.js (prebuilt binaries + optional compile fallback).
#
# BEST-EFFORT TRANSLATION — this list was NOT covered by the Fedora packaging
# research this script otherwise implements (that research focused on the
# tools with their own install_<tool>() functions; asdf/Node's *build*
# prerequisites were not separately investigated). Ubuntu's package list
# (ca-certificates curl git gnupg dirmngr build-essential python3) doesn't
# map 1:1 onto Fedora: `dirmngr` ships as part of Fedora's `gnupg2` with no
# separate package, and `build-essential` has no single-package equivalent —
# closest is the `development-tools` group (same one install_homebrew() uses)
# plus explicit gcc/gcc-c++/make. Flagged as a gap worth verifying in the
# final report.
install_asdf_nodejs_dnf_prereqs() {
    log_info "Installing dnf packages for asdf / Node.js (git, curl, gnupg2, build tools)..."
    if ! dnf group list --installed 2>/dev/null | grep -qi 'Development Tools'; then
        dnf group install -y development-tools 2>/dev/null || dnf groupinstall -y "Development Tools" || true
    fi
    dnf install -y \
        ca-certificates \
        curl \
        git \
        gnupg2 \
        gcc \
        gcc-c++ \
        make \
        python3
    log_success "asdf / Node.js dnf prerequisites ready"
}

# True if Node 22.15.1 is installed under asdf and binaries run (does not depend on PATH order).
# Identical to Ubuntu's — asdf itself has no package-manager dependency.
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

# Insert asdf before "non-interactive return" so npm/node work under bash -c / CI / scripts.
# Identical to Ubuntu's — this edits ~/.bashrc, which is a shell concern, not a package-manager one.
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
# Identical to Ubuntu's.
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
# Identical to Ubuntu's.
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
# Identical logic to Ubuntu's; only the apt-prereqs call is swapped for the dnf one.
install_asdf_nodejs() {
    if _verify_asdf_nodejs_22_15_1_installed 2>/dev/null; then
        log_info "Node.js 22.15.1 is already installed via asdf, skipping install..."
        _ensure_asdf_in_bashrc_with_shim_priority
        return 0
    fi

    install_asdf_nodejs_dnf_prereqs

    log_info "Installing asdf and Node.js for user $ACTUAL_USER..."

    if ! command_exists git; then
        dnf install -y git
    fi

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

# Set global Node.js version (standalone asdf in ~/.asdf). Identical to Ubuntu's.
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

# Note about bashrc. Identical to Ubuntu's.
note_bashrc() {
    log_info "Note: User $ACTUAL_USER should start a new shell or run 'source ~/.bashrc' to use new tools"
    log_info "Docker: if 'docker ps' says permission denied but setup verified OK, run 'newgrp docker' once, or log out and back in (GUI sessions keep old group set until then)"
}

# Create CI user and add to docker group (requires root for user management)
#
# CONFIRMED via research: useradd/usermod/getent/id are POSIX shadow-utils
# commands, not apt-specific — identical to Ubuntu's, no Fedora translation
# needed (dnf's docker-ce package creates the `docker` group the same way
# Ubuntu's does).
create_ci_user() {
    if ! user_exists "ci"; then
        log_info "Creating CI user..."
        useradd -m ci
        log_success "CI user created"
    else
        log_info "CI user already exists, skipping creation..."
    fi

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
#
# CONFIRMED via research: ollama.com/install.sh's base install (binary +
# systemd unit) is package-manager-agnostic. Its optional NVIDIA CUDA-driver
# path has a dedicated `fedora` case upstream — confirms native Fedora
# awareness, no Fedora-specific breakage. Reused verbatim from Ubuntu's
# install_ollama().
install_ollama() {
    if command_exists ollama; then
        log_info "Ollama is already installed, skipping installation..."
        return 0
    fi

    log_info "Installing Ollama (this requires root privileges)..."
    curl -fsSL https://ollama.com/install.sh | sh
    log_success "Ollama installed"
}

# Check if ollama systemd unit exists (official installer creates it; Homebrew/manual installs may not)
# Identical to Ubuntu's.
ollama_systemd_unit_exists() {
    systemctl cat ollama.service &>/dev/null || \
    [[ -f /etc/systemd/system/ollama.service ]] || \
    [[ -f /usr/lib/systemd/system/ollama.service ]]
}

# Pick an Ollama default context length appropriate for installed memory.
# Identical to Ubuntu's — pure /proc/meminfo arithmetic, no distro dependency.
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

# True only when a *functional* NVIDIA GPU is present. Identical to Ubuntu's.
has_nvidia_gpu() {
    command_exists nvidia-smi || return 1
    nvidia-smi -L 2>/dev/null | grep -q '^GPU'
}

# Detect inference accelerator and emit hardware-aware Ollama systemd drop-ins.
# Identical to Ubuntu's — pure /dev/kfd + systemd logic, no apt/dnf dependency.
configure_ollama_gpu() {
    local dropin_dir="/etc/systemd/system/ollama.service.d"
    local gpu_dropin="${dropin_dir}/10-ci-gpu.conf"
    mkdir -p "$dropin_dir"

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
# Identical to Ubuntu's — see that script's header comment for the full
# rationale (OpenAI-compatible /v1 endpoint ignores per-request num_ctx).
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
# write_ollama_context_dropin() in backends/fedora/provision/provision.sh
# (ported unchanged from backends/ubuntu/provision/provision.sh).
[Service]
Environment="OLLAMA_CONTEXT_LENGTH=${ctx}"
EOF

    local conflicts
    conflicts="$(grep -rlE '^[[:space:]]*Environment="?OLLAMA_CONTEXT_LENGTH=' "$dropin_dir" 2>/dev/null | grep -vF "$ctx_dropin" | paste -sd, - || true)"
    if [[ -n "$conflicts" ]]; then
        log_warning "OLLAMA_CONTEXT_LENGTH is also set in: ${conflicts} — now overridden by ${ctx_dropin} (=${ctx}). Remove the stale entries to avoid confusion."
    fi
}

# Configure Ollama service (requires root for systemd operations). Identical to Ubuntu's.
configure_ollama() {
    if ! command_exists ollama; then
        log_warning "Ollama is not installed, skipping service configuration..."
        return 0
    fi

    if ! ollama_systemd_unit_exists; then
        log_info "Ollama is installed but no systemd unit found (e.g. Homebrew/manual install). Skipping systemd configuration."
        log_info "To run Ollama, use 'ollama serve' or reinstall via: curl -fsSL https://ollama.com/install.sh | sh"
        log_success "Ollama configured (user-managed)"
        return 0
    fi

    log_info "Configuring Ollama service..."

    if ! service_enabled ollama; then
        if systemctl enable ollama 2>/dev/null; then
            log_info "Ollama service enabled"
        else
            log_warning "Could not enable ollama service (unit may not support it), continuing..."
        fi
    else
        log_info "Ollama service is already enabled, skipping..."
    fi

    mkdir -p /etc/systemd/system/ollama.service.d

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

    configure_ollama_gpu

    log_success "Ollama service configured"
}

# Pull Ollama models (runs as user, but service management requires root). Identical to Ubuntu's.
pull_ollama_models() {
    if ! command_exists ollama; then
        log_warning "Ollama is not installed, skipping model pull..."
        return 0
    fi

    log_info "Checking Ollama models..."

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

    sudo -u "$ACTUAL_USER" bash <<EOF || log_warning "Failed to pull some Ollama models"
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

if ollama list 2>/dev/null | grep -q "qwen3.6:27b"; then
     echo "qwen3.6:27b already installed"
else
     echo "Pulling qwen3.6:27b..."
     ollama pull qwen3.6:27b
fi
EOF

    log_success "Ollama models checked/pulled"
}

# Install GitHub CLI (requires root for package installation and repository configuration)
#
# CONFIRMED via research: dnf5 needs the dnf5-plugins package, dnf4 needs
# 'dnf-command(config-manager)', before `config-manager addrepo/--add-repo`
# from cli.github.com/packages/rpm/gh-cli.repo works — handled by
# ensure_config_manager_plugin()/add_repo_from_url() above.
install_github_cli() {
    if command_exists gh; then
        log_info "GitHub CLI is already installed, skipping installation..."
        return 0
    fi

    log_info "Installing GitHub CLI..."

    if ! repo_configured "/etc/yum.repos.d/gh-cli.repo"; then
        add_repo_from_url "https://cli.github.com/packages/rpm/gh-cli.repo"
    fi

    dnf install -y gh

    log_success "GitHub CLI installed"
}

# Install cloudflared (requires root for package installation and repository configuration)
#
# CONFIRMED via research: pkg.cloudflare.com/cloudflared.repo is a generic
# repo file (baseurl pkg.cloudflare.com/cloudflared/rpm, no distro/version
# gating) — verified by fetching it directly.
install_cloudflared() {
    if command_exists cloudflared; then
        log_info "cloudflared is already installed, skipping installation..."
        return 0
    fi

    log_info "Installing cloudflared..."

    if ! repo_configured "/etc/yum.repos.d/cloudflared.repo"; then
        # NOTE (from research): Cloudflare rotated their signing key on
        # 2025-10-30. If GPG verification starts failing on this repo, that
        # key rollover is the first thing to check.
        add_repo_from_url "https://pkg.cloudflare.com/cloudflared.repo"
    fi

    dnf install -y cloudflared

    log_success "cloudflared installed"
}

# Remove Fedora telemetry (requires root)
#
# CONFIRMED via research: Fedora Workstation ships no equivalent to Ubuntu's
# ubuntu-report/popularity-contest/whoopsie stack — this is a non-issue on
# Fedora, not an unresearched gap. The closest analog, ABRT (a local crash
# collector, not phone-home telemetry by default), is left alone since it
# isn't actually telemetry; this function is a deliberate no-op documented
# here rather than silently absent from main(), matching
# core/manifest/role-map/dnf.yaml's telemetry_removal entry (install_method: none).
remove_telemetry() {
    log_info "No Fedora telemetry removal needed: Fedora Workstation ships no equivalent to Ubuntu's ubuntu-report/popularity-contest/whoopsie. (ABRT, the closest analog, is a local crash-collection daemon and is not phone-home telemetry by default — left untouched.) This is a deliberate no-op; see core/manifest/role-map/dnf.yaml's telemetry_removal entry."
}

# Enable corepack (requires Node.js via asdf; corepack provides yarn/pnpm).
# Identical to Ubuntu's — asdf/corepack have no package-manager dependency.
enable_corepack() {
    log_info "Enabling corepack and pnpm for user $ACTUAL_USER..."

    if ! sudo -u "$ACTUAL_USER" bash -c '[[ -f "$HOME/.asdf/asdf.sh" ]] && export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH" && . "$HOME/.asdf/asdf.sh" && command -v node &>/dev/null' 2>/dev/null; then
        log_warning "Node.js not found. Skipping corepack enable. It will be enabled when Node.js is available."
        return 0
    fi

    sudo -u "$ACTUAL_USER" bash <<'EOF'
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

# Chromium: Fedora ships Chromium in its own repos (unlike Debian/Ubuntu's
# Snap-steered transitional package), so a plain dnf install is sufficient —
# CONFIRMED via research, no PPA/snap/flatpak fallback chain needed.
#
# True if Chromium is already usable (skip reinstall). The exact binary name
# Fedora's build exposes (`chromium` vs `chromium-browser`) was NOT
# confidently confirmed by research (sources disagreed) — both are checked.
chromium_usable() {
    if command_exists chromium; then
        [[ -x "$(command -v chromium)" ]] && return 0
    fi
    [[ -x /usr/bin/chromium ]] && return 0
    [[ -x /usr/bin/chromium-browser ]] && return 0
    return 1
}

install_chromium() {
    if chromium_usable; then
        log_info "Chromium already available, skipping..."
        return 0
    fi

    log_info "Installing Chromium (native Fedora dnf package)..."

    if dnf install -y chromium; then
        if chromium_usable; then
            log_success "Chromium installed (dnf)"
            return 0
        fi
        log_warning "dnf install chromium completed, but no chromium/chromium-browser binary was detected on PATH — verify the package's binary name on this Fedora release."
        return 0
    fi

    log_error "Chromium could not be installed via dnf"
    return 1
}

# True if the Microsoft VS Code / code package is already on the system (skip reinstall).
vscode_installed() {
    command_exists code && return 0
    [[ -x /usr/bin/code ]] && return 0
    if package_installed code; then
        return 0
    fi
    return 1
}

# VS Code: Microsoft's official yum repo, CONFIRMED via research
# (rpm --import + a hand-written /etc/yum.repos.d/vscode.repo, then dnf
# install code). Microsoft's own docs note the repo can lag ~3h behind
# latest — same two-tier (repo, then direct download) structure as Ubuntu's
# install_vscode(), translated to a direct .rpm fallback.
install_vscode() {
    if vscode_installed; then
        log_info "VS Code is already installed (code on PATH or rpm), skipping installation..."
        return 0
    fi

    log_info "Installing VS Code via Microsoft's yum repo..."

    rpm --import https://packages.microsoft.com/keys/microsoft.asc

    if [[ ! -f /etc/yum.repos.d/vscode.repo ]]; then
        cat > /etc/yum.repos.d/vscode.repo <<EOF
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
    fi

    if dnf install -y code && vscode_installed; then
        log_success "VS Code installed (Microsoft yum repo)"
        return 0
    fi

    log_warning "Repo-based VS Code install failed or the repo is lagging; falling back to a direct .rpm download..."
    install_vscode_direct_rpm_fallback
}

# Direct .rpm download fallback for install_vscode(), mirroring Ubuntu's
# direct-.deb-download structure. CONFIRMED available per Microsoft's docs.
install_vscode_direct_rpm_fallback() {
    if ! command_exists curl; then
        log_error "curl is required to download VS Code (install_curl should have run first)"
        return 1
    fi

    local arch rpm_url tmprpm="/tmp/code_stable_linux.rpm"
    arch="$(uname -m)"
    case "$arch" in
        x86_64) rpm_url="https://update.code.visualstudio.com/latest/linux-rpm-x64/stable" ;;
        aarch64) rpm_url="https://update.code.visualstudio.com/latest/linux-rpm-arm64/stable" ;;
        *)
            log_warning "VS Code automatic install supports x86_64/aarch64 only (this system: $arch). Install VS Code manually."
            return 0
            ;;
    esac

    log_info "Downloading latest stable VS Code (.rpm) from Microsoft..."
    if ! curl -fL --connect-timeout 90 --retry 3 -o "$tmprpm" "$rpm_url"; then
        log_error "VS Code .rpm download failed from $rpm_url"
        rm -f "$tmprpm"
        return 1
    fi

    log_info "Installing VS Code .rpm..."
    if ! dnf install -y "$tmprpm"; then
        rpm -i "$tmprpm" || { log_error "VS Code .rpm install failed"; rm -f "$tmprpm"; return 1; }
    fi
    rm -f "$tmprpm"

    if vscode_installed; then
        log_success "VS Code installed (direct .rpm)"
    else
        log_error "VS Code .rpm install reported success but the code command was not detected"
        return 1
    fi
}

# Install Companion Launcher — INTENTIONALLY STUBBED GAP, not a best-effort
# guess. Companion Launcher (core/manifest/ecosystem.yaml's companion_launcher
# entry) is published by dl.ci.computer as a .deb only (Ubuntu's
# install_companion_launcher() downloads and dpkg -i's it); no Fedora/.rpm
# build exists anywhere as of this writing. Attempting to dpkg/alien-convert
# a foreign .deb on Fedora is exactly the kind of "guess at commands that
# might fail destructively" this task's brief says to avoid — skip with a
# clear message instead. See docs/architecture/multi-distro-design.md.
install_companion_launcher() {
    log_warning "Companion Launcher has no published Fedora/.rpm build — dl.ci.computer only publishes .deb artifacts today. Skipping (not implemented for this backend yet). See core/manifest/ecosystem.yaml's companion_launcher entry."
    return 0
}

# Configure Companion Launcher autostart — a no-op in practice on Fedora
# today, since install_companion_launcher() above never installs the binary.
# Kept (rather than dropped) so this function still does the right thing if a
# Fedora build of Companion Launcher ever ships and someone installs it
# manually ahead of this script gaining real support for it.
configure_companion_launcher_autostart() {
    if ! command_exists ci-os-hub-desktop; then
        log_info "Companion Launcher binary not found (expected — no Fedora build is published yet), skipping autostart configuration"
        return 0
    fi

    log_info "Configuring Companion Launcher autostart..."

    install -d -m 755 /etc/xdg/autostart
    cat > /etc/xdg/autostart/companion-launcher.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Companion Launcher
Comment=Start Companion Launcher
Exec=ci-os-hub-desktop
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

    if [[ -d "${ACTUAL_HOME}/.local/share/companion-hub" ]]; then
        chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${ACTUAL_HOME}/.local/share/companion-hub" || true
    fi

    log_success "Companion Launcher autostart configured"
}

# Deploy the CI Hub Service backend via core/lib/ci-hub.sh — CONFIRMED
# genuinely distro-portable (Docker Compose based, no apt/dpkg assumptions;
# verified by reading core/lib/ci-hub.sh in full). Called exactly like
# Ubuntu's deploy_ci_hub(), no translation needed.
deploy_ci_hub() {
    if ! command_exists docker; then
        log_warning "Docker not installed; skipping CI-Hub deploy"
        return 0
    fi

    local ci_hub_sh="${REPO_ROOT:-}/core/lib/ci-hub.sh"
    if [[ ! -f "$ci_hub_sh" ]]; then
        log_warning "core/lib/ci-hub.sh not found at $ci_hub_sh; skipping CI-Hub deploy"
        return 0
    fi

    log_info "Deploying CI Hub Service..."
    bash "$ci_hub_sh" || log_warning "CI-Hub deploy had issues; run core/lib/ci-hub.sh manually with registry credentials set"
}

# Install the AMD ROCm driver — INTENTIONALLY STUBBED GAP. AMD does not
# publish an official Fedora ROCm repo. The only workable path found in
# research maps to RHEL 10's EPEL/CodeReady-Builder-equivalent repos, with
# reported ROCm 6.4.1/Fedora 42 repo-availability gaps as recently as 2025.
# Ubuntu's backend pins a specific tested ROCm version (7.2.4) for Strix Halo
# hardware (backends/ubuntu/lib/install-rocm-driver.sh); no Fedora equivalent
# has been verified on real hardware, so this stubs rather than guesses at
# commands that could partially apply and leave the system half-configured.
# See core/manifest/role-map/dnf.yaml's rocm entry.
install_rocm_driver_fedora() {
    log_warning "ROCm driver install is NOT IMPLEMENTED for Fedora yet (stubbed gap, not a guess) — AMD publishes no official Fedora ROCm repo, and the closest documented workaround has known version-availability gaps. Skipping; Ollama will still get AMD iGPU acceleration via the Vulkan path configure_ollama_gpu() already sets up. See core/manifest/role-map/dnf.yaml's rocm entry."
    return 0
}

# Install LACT GPU monitor — INTENTIONALLY STUBBED GAP. Ubuntu's install_lact()
# downloads the latest *amd64.deb asset from ilya-zlobintsev/LACT's GitHub
# releases API; whether that project publishes an .rpm asset suitable for
# Fedora was not verified by the research this script is based on. See
# core/manifest/role-map/dnf.yaml's lact entry.
install_lact() {
    if command_exists lact; then
        log_info "LACT GPU monitor is already installed, skipping..."
        return 0
    fi
    log_warning "LACT GPU monitor install is NOT IMPLEMENTED for Fedora yet (stubbed gap, not a guess) — whether ilya-zlobintsev/LACT publishes an .rpm release asset was not verified. Skipping rather than guessing at a possibly-wrong package format. See core/manifest/role-map/dnf.yaml's lact entry."
    return 0
}

# Main function
main() {
    log_info "CI-OS Fedora provisioning (tiers: ${TIER_LIST})"
    log_info "===================================="
    echo

    check_root

    if [[ $EUID -ne 0 ]]; then
        log_error "Script must be run as root. Use: sudo $0"
        log_error "This script requires root privileges for:"
        log_error "  - Installing system packages (dnf)"
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

    install_curl
    update_dnf_cache
    install_make
    if tier_requested core; then
        install_docker
        install_uv
        install_asdf_nodejs
        set_global_nodejs || true
        note_bashrc
        create_ci_user
        install_github_cli
        install_ollama
        configure_ollama
        pull_ollama_models
        install_cloudflared
        enable_corepack
        remove_telemetry
        install_tailscale
        deploy_ci_hub
    fi
    if tier_requested extended; then
        # Homebrew is optional; don't fail the run if it has issues (Node/Bun use dnf/asdf)
        set +e
        install_homebrew || log_warning "Homebrew had issues; Node.js will use dnf/asdf"
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
    echo "  • User $ACTUAL_USER: Log out and log back in (or start a new shell) to use new tools; for Docker without re-login run: newgrp docker"
    echo "  • For CI user: log in as 'ci' user or use 'newgrp docker' to activate docker group"
    echo "  • Start Ollama service: systemctl start ollama"
    echo "  • Verify installations: docker --version, node --version, pnpm --version, ollama --version, gh --version"
}

# Run main function
main "$@"

# Post-main: ROCm and LACT — hardware tier, auto-detected (both stubbed on
# Fedora, see their own headers above), gated on tier inclusion the same way
# Ubuntu's provision.sh invokes its hardware-tier steps as top-level
# statements after main() returns rather than from inside main(), so a
# failure here can never abort the rest of setup and log ordering matches
# Ubuntu's (hardware-tier output after "Setup completed successfully!").
tier_requested hardware && install_rocm_driver_fedora || true
tier_requested hardware && install_lact || true
