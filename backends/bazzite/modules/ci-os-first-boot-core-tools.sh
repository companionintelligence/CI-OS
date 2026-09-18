#!/usr/bin/env bash
#=============================================================================
# CI-OS Bazzite backend — first-boot module: ci system user + uv + asdf/Node
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
#
# WHY THIS FILE EXISTS
# ---------------------
# core/manifest/role-map/bootc.yaml documents uv, asdf, node, and the `ci`
# system user as install_method: first_boot, with a clear rationale (all
# write into $HOME — /var/home on ostree, excluded from the image commit —
# so none of them can be baked). That analysis was written before this
# script existed; this is the module the role-map's own notes describe but
# that, in this backend's first implementation pass, had no script behind
# it — a real gap an adversarial review caught (a device built from the
# original image would never get the `ci` user, uv, asdf, or Node.js at
# all, despite all four being core-tier per core/manifest/ecosystem.yaml on
# every other backend). This file closes that gap.
#
# Homebrew (also first_boot in the role-map, tier: extended) is NOT
# implemented here, deliberately, not silently: it is opt-in/manual on
# EVERY backend already (never part of the default core-tier first-boot
# flow on Ubuntu/Mint/Fedora/Arch either), so leaving it out here doesn't
# regress anything a fresh Bazzite appliance would otherwise have had by
# default. Install it by hand later if wanted (see
# backends/fedora/provision/provision.sh's install_homebrew() for the
# reference implementation this backend would port from, if a future pass
# decides to add it as an opt-in module).
#
# BUILD-TIME PREREQUISITES THIS SCRIPT ASSUMES
# -----------------------------------------------
# asdf's Node.js plugin needs `git` to clone both asdf itself and the
# asdf-nodejs plugin, `curl` for uv's installer, and a compiler toolchain
# (gcc/gcc-c++/make) as asdf-nodejs's fallback path if a prebuilt binary
# for this architecture isn't available. Unlike backends/fedora's
# install_asdf_nodejs_dnf_prereqs() (a `dnf install` RUN AT PROVISIONING
# TIME on a normal, writable filesystem), those packages CANNOT be
# installed here, at first boot, on this backend — /usr is read-only at
# runtime on an ostree/bootc root; there is no first-boot equivalent of
# `dnf install` that takes effect immediately without a reboot. They must
# already be baked into the image at BUILD time instead — see
# backends/bazzite/image/Containerfile's own asdf/Node build-prerequisites
# RUN step (git, curl, gnupg2, gcc, gcc-c++, make). This script only checks
# for their presence and fails loudly (not silently) if they're missing,
# rather than attempting a runtime `dnf`/`rpm-ostree install` this backend
# has no support for.
#
# WHY create_ci_user() DROPS THE "docker GROUP" STEP EVERY OTHER BACKEND
# HAS
# -------------------------------------------------------------------------
# backends/fedora's/backends/ubuntu's create_ci_user() also runs
# `usermod -aG docker ci` so the `ci` user can talk to the Docker socket
# without sudo. This backend's runtime is Podman, not Docker (see
# lib/podman-docker-compat.sh's header) — its rootful API socket at
# /run/podman/podman.sock is owned by root with no `docker`-equivalent
# group Podman grants membership-based access through by default on this
# image (unverified whether Bazzite's base configures one; not assumed).
# Nothing in this backend currently runs CI-Hub or any other container
# workload AS the `ci` user — ci-os-first-boot-ci-hub.sh runs as root, like
# every other first-boot module here — so there is no present need for `ci`
# to have socket access, and granting a group membership on a guess would
# be worse than granting none: an unverified claim of working, unmediated
# root-equivalent container access is a real security-relevant claim were
# this ever wrong. Left out, disclosed here, not silently different from
# Fedora's version without explanation.
#
# ACTUAL_USER DETECTION — DIFFERENT FROM EVERY OTHER BACKEND
# --------------------------------------------------------------
# Every other backend's provisioning script learns the real desktop user
# from $SUDO_USER (they're invoked via `sudo ./provision.sh`, run
# interactively by a human who is already logged in as that user). This
# script runs from a systemd oneshot unit at first boot — there is no sudo
# invocation, no $SUDO_USER, and very possibly no interactive session yet
# either. Instead, this script scans /etc/passwd for the first real
# (UID >= 1000, UID < 60000, has a real home directory, shell is not
# nologin/false) account that isn't `ci` itself. On Bazzite this is
# expected to already exist by the time this unit runs: Anaconda/the
# ublue-os first-setup flow creates the human user's account as part of
# initial OS setup, which completes before this systemd service's
# `multi-user.target` ordering point. If no such user is found (e.g. this
# image was booted standalone with no OS-level first-setup flow at all),
# uv/asdf/Node are skipped with a clear log message — creating the `ci`
# system user itself does not depend on a human user existing, so that
# part still runs regardless.
#=============================================================================

set -o nounset
set -o pipefail
# Deliberately NOT `set -e` — see ci-os-first-boot-ci-hub.sh's header for
# why: a failed step here must still fall through to the unconditional
# marker-write at the end, not abort and re-attempt forever on every boot.

MARKER_FILE="/var/lib/ci-os/.first-boot-core-tools-done"
LOG_FILE="/var/log/ci-os-first-boot-core-tools.log"
NODE_VERSION="22.15.1"
ASDF_VERSION="v0.14.0"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[CI-OS] Bazzite first-boot core-tools setup starting at $(date -u)"

if [[ -f "$MARKER_FILE" ]]; then
    echo "[CI-OS] Core-tools first-boot setup already completed ($(cat "$MARKER_FILE" 2>/dev/null)). To re-run: sudo rm $MARKER_FILE && sudo systemctl start ci-os-first-boot-core-tools.service"
    exit 0
fi

# --- 1. Create the `ci` system user (identity only — see header for why ---
# the docker-group step every other backend has is intentionally absent).
if ! id -u ci >/dev/null 2>&1; then
    echo "[CI-OS] Creating ci system user..."
    if useradd -m ci; then
        echo "[CI-OS] ci user created"
    else
        echo "[CI-OS] WARNING: useradd -m ci failed; continuing with the rest of this module"
    fi
else
    echo "[CI-OS] ci user already exists, skipping creation"
fi

# --- 2. Detect the real desktop user (see header) -------------------------
ACTUAL_USER=""
while IFS=: read -r pw_name _ pw_uid _ _ pw_home pw_shell; do
    [[ "$pw_uid" -ge 1000 && "$pw_uid" -lt 60000 ]] || continue
    [[ "$pw_name" != "ci" && "$pw_name" != "nobody" ]] || continue
    [[ "$pw_shell" != */nologin && "$pw_shell" != */false ]] || continue
    [[ -d "$pw_home" ]] || continue
    ACTUAL_USER="$pw_name"
    ACTUAL_HOME="$pw_home"
    break
done < /etc/passwd

if [[ -z "$ACTUAL_USER" ]]; then
    echo "[CI-OS] No real desktop user account found yet (checked /etc/passwd for UID 1000-59999 with a real shell/home) — skipping uv/asdf/Node for this run. Re-run after a user account exists: sudo rm $MARKER_FILE && sudo systemctl start ci-os-first-boot-core-tools.service"
    mkdir -p "$(dirname "$MARKER_FILE")"
    date -u > "$MARKER_FILE"
    echo "[CI-OS] Core-tools first-boot setup finished (partial — no desktop user) at $(date -u)"
    exit 0
fi
echo "[CI-OS] Detected desktop user: $ACTUAL_USER (home: $ACTUAL_HOME)"

# --- 3. Verify build-time prerequisites are actually present (see header) -
missing_prereqs=()
for bin in git curl gcc make; do
    command -v "$bin" >/dev/null 2>&1 || missing_prereqs+=("$bin")
done
if (( ${#missing_prereqs[@]} > 0 )); then
    echo "[CI-OS] WARNING: missing expected build-time prerequisites: ${missing_prereqs[*]} — these should be baked into the image (see backends/bazzite/image/Containerfile's asdf/Node prerequisites RUN step). uv/asdf/Node install below will likely fail."
fi

# --- 4. Install uv (CONFIRMED distro-generic curl-pipe installer, ---------
# unchanged from backends/fedora's/backends/ubuntu's install_uv()).
if sudo -u "$ACTUAL_USER" bash -c "command -v uv" &>/dev/null; then
    echo "[CI-OS] uv already installed for $ACTUAL_USER, skipping"
else
    echo "[CI-OS] Installing uv for $ACTUAL_USER..."
    sudo -u "$ACTUAL_USER" bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh" \
        || echo "[CI-OS] uv install failed (see above) — continuing"
fi

# --- 5. Install asdf + Node.js (ported from backends/fedora's -------------
# install_asdf_nodejs(), same version pin, same verification checks —
# nothing here is apt/dnf-specific, only the now-removed build-prereqs
# install call, which is a build-time image concern on this backend).
_verify_asdf_nodejs_installed() {
    local install_dir
    install_dir="$(sudo -u "$ACTUAL_USER" HOME="$ACTUAL_HOME" bash -c '
        export ASDF_DIR="$HOME/.asdf"
        [[ -f "$ASDF_DIR/asdf.sh" ]] || exit 1
        . "$ASDF_DIR/asdf.sh"
        asdf where nodejs '"$NODE_VERSION"' 2>/dev/null
    ' 2>/dev/null)"
    [[ -n "$install_dir" ]] && [[ -x "$install_dir/bin/node" ]]
}

if _verify_asdf_nodejs_installed; then
    echo "[CI-OS] Node.js $NODE_VERSION already installed via asdf for $ACTUAL_USER, skipping"
else
    echo "[CI-OS] Installing asdf + Node.js $NODE_VERSION for $ACTUAL_USER..."
    if ! sudo -H -u "$ACTUAL_USER" HOME="$ACTUAL_HOME" USER="$ACTUAL_USER" LOGNAME="$ACTUAL_USER" ASDF_VERSION="$ASDF_VERSION" NODE_VERSION="$NODE_VERSION" bash <<'INNER_EOF'
set -euo pipefail
ASDF_DIR="$HOME/.asdf"
ASDF_DATA_DIR="${ASDF_DATA_DIR:-$ASDF_DIR}"

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

asdf install nodejs "$NODE_VERSION"
asdf reshim nodejs
asdf global nodejs "$NODE_VERSION"

install_dir="$(asdf where nodejs "$NODE_VERSION" 2>/dev/null || true)"
[[ -n "$install_dir" ]]
test -x "$install_dir/bin/node"
test -x "$install_dir/bin/npm"
INNER_EOF
    then
        echo "[CI-OS] asdf/Node.js install failed for $ACTUAL_USER (see errors above) — continuing"
    elif ! _verify_asdf_nodejs_installed; then
        echo "[CI-OS] Post-install check failed: Node.js $NODE_VERSION not present under ~/.asdf for $ACTUAL_USER — continuing"
    else
        echo "[CI-OS] asdf and Node.js installed"
    fi
fi

# --- 6. bashrc note (identical to every other backend's note_bashrc()) ----
echo "[CI-OS] Note: user $ACTUAL_USER should start a new shell or run 'source ~/.bashrc' to use uv/asdf/node"

mkdir -p "$(dirname "$MARKER_FILE")"
date -u > "$MARKER_FILE"

echo "[CI-OS] Core-tools first-boot setup finished at $(date -u)"
echo "[CI-OS] Log saved to $LOG_FILE"
