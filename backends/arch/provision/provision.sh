#!/usr/bin/bash
# provision.sh — the Arch Linux (pacman) ecosystem provisioning entrypoint.
#
# This is a genuine reimplementation of backends/ubuntu/provision/provision.sh
# and backends/fedora/provision/provision.sh for pacman, NOT a thin wrapper
# like backends/mint/provision/provision.sh — pacman's package names and
# packaging conventions differ enough from both apt and dnf that a wrapper
# wouldn't work. Structure (tier gating, function-per-tool shape,
# require_root/detect_user/log_* conventions, the --tier=/--step= argument
# parsing, hardware-tier steps run as top-level statements AFTER "main \"\$@\""
# returns rather than from inside main()) is copied from Fedora's
# provision.sh unchanged, because none of that is pacman-specific. See
# core/manifest/role-map/pacman.yaml for the package data this script
# implements, and docs/architecture/multi-distro-design.md for the overall
# rollout plan (this is Phase 4: provisioning + theming; archiso
# profile-building and AUR-helper automation are explicitly out of scope —
# see both files' headers).
#
# PREREQUISITE, not installed by this script: a working Arch install with
# GNOME already set up (this backend targets GNOME Shell, reusing
# backends/_mixins/gnome-dconf/ like Fedora — see
# backends/arch/desktop-theme/apply-ci-os-desktop.sh) and `sudo` present.
# Unlike Ubuntu/Fedora, Arch has no "Workstation"/"Desktop" installer flavor —
# a real Arch install is assembled manually or via archinstall, so this
# script does NOT install a desktop environment or bootloader (see
# check_desktop_prereqs(), which warns rather than fails when GNOME/GDM
# aren't detected, and backends/arch/desktop-theme/15-grub-theme.sh, which
# detects and cleanly skips on a systemd-boot-only system rather than
# assuming GRUB is present).
#
# ROLLING-RELEASE CORRECTNESS NOTE (no apt/dnf analog — read before editing):
# pacman explicitly does NOT support "partial upgrades" — running `pacman -Sy`
# (sync the package database) without also fully upgrading the system
# (`pacman -Syu`) and THEN installing new packages in a separate transaction
# can pull a newly-indexed package against stale already-installed
# dependencies and corrupt the system in ways that are hard to diagnose
# after the fact (this is Arch's own official, repeatedly-stated policy, not
# a hypothetical). Every apt-get/dnf equivalent in this repo calls
# "refresh metadata" once, then does N separate installs across the rest of
# the script — replicating that exact shape here (a separate `pacman -Sy`
# followed by later `pacman -S <pkg>` calls scattered across many functions)
# would reproduce precisely the failure mode pacman's own docs warn against.
# So this script instead runs ONE `pacman -Syu --noconfirm` up front
# (full_system_sync_and_upgrade(), called once from main() before any
# install_* function), and every install_* function below uses
# `pacman -S --needed --noconfirm <pkgs>` (--needed skips a package already
# at the latest installed version, keeping reruns idempotent and cheap)
# against that already-fresh, already-upgraded database — never a bare `-Sy`
# anywhere else in this file.
#
# ARCH PACKAGES NEVER AUTO-START SERVICES (no apt/dnf analog either): Arch's
# packaging policy is that a package installs files and nothing else —
# no postinst-style hook enables or starts a systemd unit the way Debian's
# packaging convention does (and Fedora's RPM docker-ce package was ALSO
# observed not to auto-start, per backends/fedora/provision/provision.sh's
# install_docker() comment — so this generalizes something Fedora already
# found for one package into a blanket rule that holds for every package
# here). Every install_* function below that installs a daemon runs an
# explicit `systemctl enable --now <unit>` itself; do not assume a fresh
# `pacman -S` left anything running.
#
# What's in this file, by confidence level (see also each function's own
# header comment, and core/manifest/role-map/pacman.yaml for the
# package-level detail):
#
#   CONFIRMED (backed by direct archlinux.org package-search verification —
#   see pacman.yaml for the exact package names/versions checked):
#     install_docker, install_github_cli, install_cloudflared,
#     install_tailscale, install_chromium, install_rocm_driver_arch,
#     install_lact, install_uv, install_homebrew, install_ollama,
#     remove_telemetry, create_ci_user.
#
#   BEST-EFFORT (translated by inference from the Ubuntu/Fedora pattern, not
#   independently re-verified package-by-package):
#     install_asdf_nodejs_pacman_prereqs (build-prerequisite package list),
#     configure_passwordless_sudo (wheel vs. Fedora's wheel / Ubuntu's sudo
#     group — Arch also uses wheel, but whether a bare `pacman -S base` boot
#     environment ships /etc/sudoers with the `@includedir /etc/sudoers.d`
#     line was not independently verified against a live box; this script's
#     sudoers.d drop-in approach doesn't depend on %wheel being uncommented
#     either way, since it grants the user directly).
#
#   INTENTIONALLY STUBBED GAPS (no confident, non-AUR Arch path found; these
#   log a clear message and return 0 rather than guessing at commands that
#   could partially apply and leave the system half-configured, OR that
#   would require invoking an AUR helper this backend explicitly does not
#   assume is installed — see docs/architecture/multi-distro-design.md's
#   "Arch AUR-helper automation (manual/documented first)" deferral):
#     install_vscode (Microsoft's VS Code build is AUR-only —
#     visual-studio-code-bin — Code-OSS's native `code` package is a
#     DIFFERENT product, not silently substituted),
#     install_companion_launcher (no Arch package, official or AUR, was
#     found for it — dl.ci.computer only ships a .deb).
#
# What's identical to Fedora's/Ubuntu's provision.sh, reused verbatim because
# it has no package-manager-specific content at all: the asdf/Node.js install
# flow itself (asdf is a git-clone + shell-function tool), Ollama
# install/service/model-pull (curl|sh installer, package-manager-agnostic),
# corepack/pnpm enablement, create_ci_user, deploy_ci_hub
# (core/lib/ci-hub.sh is Docker-Compose-based, confirmed distro-portable),
# GPU/context systemd drop-in logic (pure /dev/kfd + /proc/meminfo checks),
# and the --tier=/--step=ci-hub argument parsing.
#
# NOT ported from Ubuntu's/Fedora's provision.sh, deliberately: apt's
# fix_docker_apt_conflicts/disable_stale_media_apt_sources/
# enable_apt_force_ipv4 (apt-specific, no pacman analog researched or
# needed), dnf5-vs-dnf4 branching (pacman has had one stable CLI syntax for
# this script's entire scope), the Strix Halo GRUB boot-param tuning
# (backends/ubuntu/lib/strix-halo-boot-params.sh — out of scope for this
# pass, no backends/arch/lib/ equivalent exists yet) and LACT dock-pinning
# (Arch's default GNOME Shell has no dash-to-dock favorites-bar the way
# Ubuntu's does — see backends/_mixins/gnome-dconf/'s own known-no-op note,
# reused verbatim by this backend's desktop-theme step).
#
# REQUIREMENTS:
# - This script MUST be run as root (use: sudo ./provision.sh)
# - All system-level operations require root privileges
# - User-specific operations run as the actual user via sudo -u
# - Target: Arch Linux, pacman (current, single stable CLI syntax — no
#   version branching needed the way Fedora's dnf5-vs-dnf4 split required).
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

# SCRIPT_DIR is backends/arch/provision/ — three levels below the repo root,
# same depth as backends/ubuntu/provision/ and backends/fedora/provision/
# (verified by counting: backends/ <- arch/ <- provision/ <- this file).
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

# Helper function to check if a pacman package is installed (pacman/apt
# equivalent of Ubuntu's `dpkg -l` / Fedora's `rpm -q`)
package_installed() {
    pacman -Qi "$1" &>/dev/null
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

# Helper function to check if a service is enabled
service_enabled() {
    systemctl is-enabled "$1" &>/dev/null
}

# ONE full sync+upgrade for the whole run — see this file's header
# "ROLLING-RELEASE CORRECTNESS NOTE" for why this must never be a bare
# `pacman -Sy` and must never be repeated mid-script.
full_system_sync_and_upgrade() {
    log_info "Running pacman -Syu (full sync + upgrade — required before any install on a rolling-release system; see this script's header)..."
    pacman -Syu --noconfirm
    log_success "System synced and upgraded"
}

# Install a set of official-repo packages, --needed so already-installed/
# up-to-date packages are skipped (keeps reruns idempotent and cheap).
pacman_install() {
    pacman -S --needed --noconfirm "$@"
}

# Enable+start a systemd unit if it exists, warning (not failing) if it
# doesn't — see this file's header: pacman packages never auto-enable
# services, so every daemon-installing function below must call this.
enable_now() {
    local unit="$1"
    if systemctl cat "$unit" &>/dev/null; then
        if systemctl enable --now "$unit" 2>/dev/null; then
            log_success "$unit enabled and started"
        else
            log_warning "Could not enable/start $unit; start it manually with: systemctl enable --now $unit"
        fi
    else
        log_warning "$unit not found after install; skipping enable"
    fi
}

# Best-effort, non-fatal check that this looks like a GNOME/GDM desktop —
# this script never installs a DE (see this file's header), it only warns so
# a headless/no-DE Arch box doesn't silently get theming steps it can't use.
# Not called from main() by default failure paths; informational only.
check_desktop_prereqs() {
    local warned=0
    if ! command_exists gnome-shell && [[ ! -d /usr/share/gnome-shell ]]; then
        log_warning "gnome-shell not detected — this backend assumes GNOME Shell is already installed (prerequisite, not installed by this script). Desktop theming steps in backends/arch/desktop-theme/ will be no-ops until GNOME is present."
        warned=1
    fi
    if ! command_exists gdm && [[ ! -f /usr/lib/systemd/system/gdm.service ]]; then
        log_warning "gdm not detected — GDM login-screen branding will be skipped until GDM is installed and enabled."
        warned=1
    fi
    if [[ "$warned" -eq 0 ]]; then
        log_info "GNOME Shell + GDM detected"
    fi
}

# Install curl (requires root) — usually present on a real desktop install,
# but not guaranteed on a minimal Arch base.
install_curl() {
    if command_exists curl; then
        log_info "curl is already installed, skipping..."
        return 0
    fi

    log_info "Installing curl..."
    pacman_install curl
    log_success "curl installed"
}

# Install make (requires root) — part of base-devel, but check standalone
# first since a caller may already have it without the whole group.
install_make() {
    if command_exists make; then
        log_info "make is already installed, skipping..."
        return 0
    fi

    log_info "Installing make..."
    pacman_install make
    log_success "make installed"
}

# Ensure sudo is present and configured before anything below relies on it.
#
# BEST-EFFORT: a full Arch desktop install (manual or archinstall with the
# GNOME profile) almost always includes sudo already, but — unlike
# Ubuntu/Fedora's ISO-seeded installers — nothing guarantees it on Arch, so
# this is checked explicitly rather than assumed. Adds the user to `wheel`
# (Arch's convention, same as Fedora's) for familiarity/parity with a
# manually-uncommented `%wheel` line, but the actual passwordless grant below
# is a direct per-user /etc/sudoers.d drop-in that does not depend on
# %wheel being active either way.
configure_passwordless_sudo() {
    if ! command_exists sudo; then
        log_info "sudo not found; installing..."
        pacman_install sudo
    fi

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
    if ! getent group docker >/dev/null 2>&1; then
        log_info "Creating docker group..."
        groupadd docker
        log_success "Docker group created"
    fi

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

# Install Docker (requires root for package installation)
#
# CONFIRMED via archlinux.org: docker, docker-buildx, and docker-compose are
# all official `extra` packages — no third-party repo needed at all, unlike
# Ubuntu's apt-keyring dance or even Fedora's docker-ce.repo add. See
# core/manifest/role-map/pacman.yaml's docker entry.
install_docker() {
    if command_exists docker && docker --version &>/dev/null; then
        log_info "Docker is already installed, skipping installation..."
        finalize_docker_access_for_actual_user
        return 0
    fi

    log_info "Installing Docker from Arch's official extra repo..."
    pacman_install docker docker-buildx docker-compose

    if ! getent group docker >/dev/null 2>&1; then
        log_info "Creating docker group..."
        groupadd docker
        log_success "Docker group created"
    fi

    # Arch packages never auto-enable services (see this file's header) —
    # unlike Fedora's docker-ce.rpm, which at least ships with the group
    # pre-created by package hooks, pacman's docker package does neither.
    enable_now docker.service

    log_success "Docker installed"
    finalize_docker_access_for_actual_user
}

# Install UV
#
# CONFIRMED via research (carried over from Fedora's provision.sh): astral.sh/uv/install.sh
# contains zero package-manager references — pure static-binary shell installer, distro-generic.
install_uv() {
    if sudo -u "$ACTUAL_USER" bash -c "command -v uv" &>/dev/null; then
        log_info "UV is already installed for user $ACTUAL_USER, skipping..."
        return 0
    fi

    log_info "Installing UV for user $ACTUAL_USER..."
    sudo -u "$ACTUAL_USER" bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
    log_success "UV installed"
}

# Install Homebrew
#
# CONFIRMED via research: the core installer (Homebrew/install/HEAD/install.sh)
# is distro-generic. Arch's build-tools prerequisite is the `base-devel`
# package GROUP (gcc/make/patch/etc. as a set, not a single package) plus
# procps-ng/curl/file/git — same procps-ng naming Fedora's role-map uses.
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

    log_info "Installing Homebrew dependencies (base-devel group + procps-ng curl file git)..."
    pacman_install base-devel procps-ng curl file git

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
            log_warning "Homebrew installation may have failed. Node.js/Bun will use pacman/asdf instead."
            return 0
        fi
    fi

    _homebrew_ensure_bashrc
    log_success "Homebrew installed and configured"
}

# Ensure Homebrew eval is in user's bashrc (helper used by install_homebrew).
# Identical to Ubuntu's/Fedora's — Homebrew's Linux install path (/home/linuxbrew) is
# the same regardless of distro.
_homebrew_ensure_bashrc() {
    RC="$ACTUAL_HOME/.bashrc"
    if ! grep -q "linuxbrew" "$RC"; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$RC"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$RC"
        log_info "Added Homebrew to bashrc"
    fi
}

# pacman packages for asdf / Node.js (prebuilt binaries + optional compile fallback).
#
# BEST-EFFORT TRANSLATION — not independently re-verified package-by-package
# the way docker/gh/cloudflared/tailscale/chromium/rocm/lact were. Arch's
# `base-devel` group already covers gcc/make/patch/etc. in one shot (unlike
# Fedora, which has no single-package/group equivalent to Debian's
# build-essential and had to list gcc/gcc-c++/make by hand) — gnupg is one
# package on Arch (bundles dirmngr the same way Fedora's gnupg2 does).
install_asdf_nodejs_pacman_prereqs() {
    log_info "Installing pacman packages for asdf / Node.js (git, curl, gnupg, base-devel)..."
    pacman_install base-devel git curl gnupg ca-certificates python
    log_success "asdf / Node.js pacman prerequisites ready"
}

# True if Node 22.15.1 is installed under asdf and binaries run (does not depend on PATH order).
# Identical to Ubuntu's/Fedora's — asdf itself has no package-manager dependency.
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
# Identical to Ubuntu's/Fedora's — this edits ~/.bashrc, which is a shell concern, not a package-manager one.
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
# Identical to Ubuntu's/Fedora's.
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
# Identical to Ubuntu's/Fedora's.
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
# Identical logic to Ubuntu's/Fedora's; only the prereqs call is swapped for the pacman one.
install_asdf_nodejs() {
    if _verify_asdf_nodejs_22_15_1_installed 2>/dev/null; then
        log_info "Node.js 22.15.1 is already installed via asdf, skipping install..."
        _ensure_asdf_in_bashrc_with_shim_priority
        return 0
    fi

    install_asdf_nodejs_pacman_prereqs

    log_info "Installing asdf and Node.js for user $ACTUAL_USER..."

    if ! command_exists git; then
        pacman_install git
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

# Set global Node.js version (standalone asdf in ~/.asdf). Identical to Ubuntu's/Fedora's.
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

# Note about bashrc. Identical to Ubuntu's/Fedora's.
note_bashrc() {
    log_info "Note: User $ACTUAL_USER should start a new shell or run 'source ~/.bashrc' to use new tools"
    log_info "Docker: if 'docker ps' says permission denied but setup verified OK, run 'newgrp docker' once, or log out and back in (GUI sessions keep old group set until then)"
}

# Create CI user and add to docker group (requires root for user management)
#
# CONFIRMED: useradd/usermod/getent/id are POSIX shadow-utils commands, not
# pacman-specific — identical to Ubuntu's/Fedora's, no translation needed.
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
# CONFIRMED via research (carried over from Fedora's provision.sh):
# ollama.com/install.sh's base install (binary + systemd unit) is
# package-manager-agnostic. Reused verbatim.
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
# Identical to Ubuntu's/Fedora's.
ollama_systemd_unit_exists() {
    systemctl cat ollama.service &>/dev/null || \
    [[ -f /etc/systemd/system/ollama.service ]] || \
    [[ -f /usr/lib/systemd/system/ollama.service ]]
}

# Pick an Ollama default context length appropriate for installed memory.
# Identical to Ubuntu's/Fedora's — pure /proc/meminfo arithmetic, no distro dependency.
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

# True only when a *functional* NVIDIA GPU is present. Identical to Ubuntu's/Fedora's.
has_nvidia_gpu() {
    command_exists nvidia-smi || return 1
    nvidia-smi -L 2>/dev/null | grep -q '^GPU'
}

# Detect inference accelerator and emit hardware-aware Ollama systemd drop-ins.
# Identical to Ubuntu's/Fedora's — pure /dev/kfd + systemd logic, no package-manager dependency.
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
# Identical to Ubuntu's/Fedora's — see that script's header comment for the
# full rationale (OpenAI-compatible /v1 endpoint ignores per-request num_ctx).
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
# write_ollama_context_dropin() in backends/arch/provision/provision.sh
# (ported unchanged from backends/ubuntu/provision/provision.sh via
# backends/fedora/provision/provision.sh).
[Service]
Environment="OLLAMA_CONTEXT_LENGTH=${ctx}"
EOF

    local conflicts
    conflicts="$(grep -rlE '^[[:space:]]*Environment="?OLLAMA_CONTEXT_LENGTH=' "$dropin_dir" 2>/dev/null | grep -vF "$ctx_dropin" | paste -sd, - || true)"
    if [[ -n "$conflicts" ]]; then
        log_warning "OLLAMA_CONTEXT_LENGTH is also set in: ${conflicts} — now overridden by ${ctx_dropin} (=${ctx}). Remove the stale entries to avoid confusion."
    fi
}

# Configure Ollama service (requires root for systemd operations). Identical to Ubuntu's/Fedora's.
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

# Pull Ollama models (runs as user, but service management requires root). Identical to Ubuntu's/Fedora's.
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

    # qwen3.6:27b (17.8 GB) only where the machine can hold it: RAM and GPU memory against model-packs.yaml
    # (core/lib/gpu-detect.sh, the same gate Ubuntu uses). Arch had no gate before; a machine the gate cannot
    # judge (the file is missing, no fit data) keeps the old behaviour and pulls it.
    PULL_QWEN=1
    local gpu_detect="${REPO_ROOT}/core/lib/gpu-detect.sh"
    if [[ -f "$gpu_detect" ]]; then
        # shellcheck source=../../../core/lib/gpu-detect.sh
        source "$gpu_detect"
        if ! ci_os_model_gate_allows qwen3.6:27b; then
            PULL_QWEN=0
            log_info "Skipping qwen3.6:27b: ${CI_OS_MODEL_FIT_REASON}"
        fi
    else
        log_warning "Model fit check missing; pulling qwen3.6:27b as before"
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

# qwen3.6:27b only where it fits (see PULL_QWEN above).
if [[ "$PULL_QWEN" == 1 ]]; then
if ollama list 2>/dev/null | grep -q "qwen3.6:27b"; then
     echo "qwen3.6:27b already installed"
else
     echo "Pulling qwen3.6:27b..."
     ollama pull qwen3.6:27b
fi
fi
EOF

    log_success "Ollama models checked/pulled"
}

# Install GitHub CLI (requires root for package installation)
#
# CONFIRMED via archlinux.org: github-cli is an official `extra` package.
# Genuinely simpler than apt.yaml/dnf.yaml's entries — no third-party repo,
# signing key, or config-manager plugin needed at all.
install_github_cli() {
    if command_exists gh; then
        log_info "GitHub CLI is already installed, skipping installation..."
        return 0
    fi

    log_info "Installing GitHub CLI from Arch's official extra repo..."
    pacman_install github-cli
    log_success "GitHub CLI installed"
}

# Install cloudflared (requires root for package installation)
#
# CONFIRMED via archlinux.org: cloudflared is an official `extra` package.
# No repo-add step needed, unlike apt.yaml's/dnf.yaml's entries.
install_cloudflared() {
    if command_exists cloudflared; then
        log_info "cloudflared is already installed, skipping installation..."
        return 0
    fi

    log_info "Installing cloudflared from Arch's official extra repo..."
    pacman_install cloudflared
    log_success "cloudflared installed"
}

# Install Tailscale (requires root for package installation)
#
# CONFIRMED via archlinux.org: tailscale is an official `extra` package —
# no codename/VERSION_ID repo-URL resolution needed at all, unlike
# Ubuntu's/Fedora's install_tailscale(). Arch's package does NOT auto-enable
# tailscaled.service (see this file's header no-autostart note), so it's
# enabled explicitly here — apt's/dnf's packaging handles that at install
# time, which is why neither of those functions calls enable_now itself.
install_tailscale() {
    if command_exists tailscale; then
        log_info "Tailscale is already installed, skipping installation..."
    else
        log_info "Installing Tailscale from Arch's official extra repo..."
        pacman_install tailscale
        log_success "Tailscale installed"
    fi
    enable_now tailscaled.service
}

# Remove Arch telemetry (requires root)
#
# CONFIRMED: Arch Linux ships no phone-home telemetry stack by design (a
# minimalist, rolling-release community distro) — a non-issue the same way
# it is on Fedora Workstation. Deliberate no-op, documented rather than
# silently absent from main(), matching
# core/manifest/role-map/pacman.yaml's telemetry_removal entry.
remove_telemetry() {
    log_info "No Arch telemetry removal needed: Arch Linux ships no phone-home telemetry stack by design. This is a deliberate no-op; see core/manifest/role-map/pacman.yaml's telemetry_removal entry."
}

# Enable corepack (requires Node.js via asdf; corepack provides yarn/pnpm).
# Identical to Ubuntu's/Fedora's — asdf/corepack have no package-manager dependency.
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

# Chromium: CONFIRMED via archlinux.org, official `extra` package, same
# binary name (chromium) as Fedora's — no PPA/snap/flatpak fallback chain
# needed, simpler than Ubuntu's apt.yaml entry.
chromium_usable() {
    if command_exists chromium; then
        [[ -x "$(command -v chromium)" ]] && return 0
    fi
    [[ -x /usr/bin/chromium ]] && return 0
    return 1
}

install_chromium() {
    if chromium_usable; then
        log_info "Chromium already available, skipping..."
        return 0
    fi

    log_info "Installing Chromium (native Arch extra package)..."

    if pacman_install chromium; then
        if chromium_usable; then
            log_success "Chromium installed (pacman)"
            return 0
        fi
        log_warning "pacman install chromium completed, but no chromium binary was detected on PATH"
        return 0
    fi

    log_error "Chromium could not be installed via pacman"
    return 1
}

# Install VS Code — INTENTIONALLY STUBBED GAP, not a best-effort guess.
# The Microsoft-branded VS Code build that Ubuntu's/Fedora's install_vscode()
# installs has NO official Arch package — only the AUR's
# visual-studio-code-bin. This backend explicitly does not invoke an AUR
# helper and does not assume one is installed (see
# docs/architecture/multi-distro-design.md's "Arch AUR-helper automation"
# deferral). A DIFFERENT native package, `code` (Code - OSS: no MS branding,
# telemetry, or Marketplace access), does exist in Arch's official `extra`
# repo — that is not silently substituted here since it is a different
# product decision than "install VS Code," not this pass's call to make.
install_vscode() {
    if command_exists code; then
        log_info "A 'code' binary is already on PATH (Code-OSS or VS Code), skipping..."
        return 0
    fi
    log_warning "VS Code has no official Arch package — Microsoft's build is AUR-only (visual-studio-code-bin). This backend does not invoke an AUR helper (see docs/architecture/multi-distro-design.md's AUR-helper-automation deferral). Install manually via your own AUR helper (yay -S visual-studio-code-bin / paru -S visual-studio-code-bin), or install the native, MS-marketplace-free alternative with: pacman -S code (Code - OSS). See core/manifest/role-map/pacman.yaml's vscode entry."
    return 0
}

# Install Companion Launcher — INTENTIONALLY STUBBED GAP, not a best-effort
# guess. Companion Launcher (core/manifest/ecosystem.yaml's companion_launcher
# entry) is published by dl.ci.computer as a .deb only; no Arch package
# (official or AUR) was found for it. See
# core/manifest/role-map/pacman.yaml's companion_launcher entry.
install_companion_launcher() {
    log_warning "Companion Launcher has no published Arch build (official or AUR) — dl.ci.computer only publishes .deb artifacts today. Skipping (not implemented for this backend yet). See core/manifest/ecosystem.yaml's companion_launcher entry."
    return 0
}

# Configure Companion Launcher autostart — a no-op in practice on Arch
# today, since install_companion_launcher() above never installs the binary.
# Kept for the same forward-compatibility reason Fedora's version is kept.
configure_companion_launcher_autostart() {
    local launcher_bin=""
    if command_exists companion-hub; then launcher_bin="companion-hub"
    elif command_exists ci-os-hub-desktop; then launcher_bin="ci-os-hub-desktop"   # legacy (<= v0.1.4)
    fi
    if [[ -z "$launcher_bin" ]]; then
        log_info "Companion Launcher binary not found (expected — no Arch build is published yet), skipping autostart configuration"
        return 0
    fi

    log_info "Configuring Companion Launcher autostart..."

    install -d -m 755 /etc/xdg/autostart
    cat > /etc/xdg/autostart/companion-launcher.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Companion Launcher
Comment=Start Companion Launcher
Exec=${launcher_bin}
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

    if [[ -d "${ACTUAL_HOME}/.local/share/companion-hub" ]]; then
        chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${ACTUAL_HOME}/.local/share/companion-hub" || true
    fi

    log_success "Companion Launcher autostart configured"
}

# Deploy the CI Hub Service backend via core/lib/ci-hub.sh — CONFIRMED
# genuinely distro-portable (Docker Compose based, no package-manager
# assumptions; verified by reading core/lib/ci-hub.sh in full). Called
# exactly like Ubuntu's/Fedora's deploy_ci_hub(), no translation needed.
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

# Install the AMD ROCm driver.
#
# CONFIRMED via archlinux.org: rocm-hip-sdk is an official `extra` package
# (currently 7.2.4-1 — the same version Ubuntu's backend pins for Strix Halo
# hardware, by coincidence of the current `extra` snapshot, not by design).
# A real, non-stubbed implementation — unlike Fedora, which has no official
# ROCm repo at all and stubs this. Arch is rolling-release, so — unlike
# Ubuntu's version-pinned install — this installs whatever `extra` currently
# resolves to; no version pin is attempted (would need the Arch Linux
# Archive, out of scope here).
#
# ensure_render_video_groups() below ports backends/ubuntu/lib/
# install-rocm-driver.sh's ensure_video_groups() — a real, working ROCm
# install this backend has no Fedora equivalent to have carried the omission
# from. Without it, /dev/kfd and /dev/dri/renderD* stay root/render-group
# only, so a non-root desktop session (or the `ci` user's Docker workloads)
# has the package installed but no actual access to ROCm-accelerated
# Ollama/Docker workloads until someone runs this by hand and re-logs in.
ensure_render_video_groups() {
    local users=("$ACTUAL_USER")
    if id -u ci >/dev/null 2>&1; then
        users+=("ci")
    fi

    local u
    for u in "${users[@]}"; do
        log_info "Adding user ${u} to render and video groups (if needed)..."
        usermod -a -G render,video "${u}" 2>/dev/null || true
    done
}

install_rocm_driver_arch() {
    if pacman -Qi rocm-hip-sdk &>/dev/null; then
        log_info "rocm-hip-sdk is already installed, skipping..."
        ensure_render_video_groups
        return 0
    fi
    log_info "Installing ROCm (rocm-hip-sdk) from Arch's official extra repo..."
    if pacman_install rocm-hip-sdk; then
        log_success "ROCm installed (rocm-hip-sdk, unpinned — Arch is rolling-release, see this function's header)"
        ensure_render_video_groups
    else
        log_warning "rocm-hip-sdk install failed; Ollama will still get AMD iGPU acceleration via the Vulkan path configure_ollama_gpu() already sets up. See core/manifest/role-map/pacman.yaml's rocm entry."
    fi
}

# Install LACT GPU monitor.
#
# CONFIRMED via archlinux.org: lact is an official `extra` package (currently
# 0.10.1-1). A real, non-stubbed implementation — unlike Fedora, where
# whether ilya-zlobintsev/LACT publishes an .rpm was never confirmed.
# lactd.service is enabled/started explicitly (Arch no-autostart convention).
install_lact() {
    if command_exists lact; then
        log_info "LACT GPU monitor is already installed, skipping..."
    else
        log_info "Installing LACT from Arch's official extra repo..."
        if ! pacman_install lact; then
            log_warning "lact install failed via pacman. See core/manifest/role-map/pacman.yaml's lact entry."
            return 0
        fi
        log_success "LACT installed"
    fi
    enable_now lactd.service
}

# Main function
main() {
    log_info "CI-OS Arch Linux provisioning (tiers: ${TIER_LIST})"
    log_info "===================================="
    echo

    check_root

    if [[ $EUID -ne 0 ]]; then
        log_error "Script must be run as root. Use: sudo $0"
        log_error "This script requires root privileges for:"
        log_error "  - Installing system packages (pacman)"
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

    check_desktop_prereqs
    install_curl
    full_system_sync_and_upgrade
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
        # Homebrew is optional; don't fail the run if it has issues (Node/Bun use pacman/asdf)
        set +e
        install_homebrew || log_warning "Homebrew had issues; Node.js will use pacman/asdf"
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

# Post-main: ROCm and LACT — hardware tier, auto-detected, gated on tier
# inclusion the same way Ubuntu's/Fedora's provision.sh invokes its
# hardware-tier steps as TOP-LEVEL STATEMENTS AFTER "main \"\$@\"" RETURNS
# rather than from inside main() — this exact structural point was a real
# bug Fedora's own adversarial review caught and required fixing after its
# first implementation pass (see backends/fedora/provision/provision.sh's
# own tail comment), so it's matched exactly here rather than re-introducing
# it: a failure in either call can never abort the rest of setup, and log
# ordering matches Ubuntu's/Fedora's (hardware-tier output after "Setup
# completed successfully!").
tier_requested hardware && install_rocm_driver_arch || true
tier_requested hardware && install_lact || true
