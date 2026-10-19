#!/usr/bin/env bash
#=============================================================================
# CI-OS Chroot Customization Script
# Applies all CI-OS customizations to the extracted Ubuntu rootfs
#
# This script runs inside (or operates on) the chroot environment and:
# 1. Updates OS identity files (/etc/os-release, etc.)
# 2. Removes Ubuntu telemetry and bloatware
# 3. Installs CI-OS packages and branding
# 4. Configures AMD GPU support (ROCm, drivers)
# 5. Sets up Plymouth, GRUB themes, the dock start icon and the Settings > About logo (PNG and SVG)
# 6. Pre-installs the wireless setup stack, Docker and the CI-Hub tooling (Step 10d)
# 7. Pre-installs the optional tools: tailscale, cloudflared, gh, Ollama, Companion Launcher (Step 10e)
#
# Usage:
#   ./backends/ubuntu/chroot/customize-chroot.sh <chroot_path> <version>
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

set -euo pipefail

CHROOT_PATH="${1:-}"
CI_OS_VERSION="${2:-1.0}"

if [[ -z "$CHROOT_PATH" ]] || [[ ! -d "$CHROOT_PATH" ]]; then
    echo "Error: Invalid chroot path: $CHROOT_PATH"
    exit 1
fi

# SCRIPT_DIR is backends/ubuntu/chroot/ — three levels below the repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../../vendor/brand/tokens/tokens.sh
source "$REPO_ROOT/vendor/brand/tokens/tokens.sh"
# shellcheck source=../lib/os-release.sh
source "$REPO_ROOT/backends/ubuntu/lib/os-release.sh"
# shellcheck source=../lib/shell-theme.sh
source "$REPO_ROOT/backends/ubuntu/lib/shell-theme.sh"
# shellcheck source=../lib/dock-favorites.sh
source "$REPO_ROOT/backends/ubuntu/lib/dock-favorites.sh"

echo "[*] Customizing chroot: $CHROOT_PATH"
echo "[*] CI-OS Version: $CI_OS_VERSION"

# Render the logo PNGs on THIS host before anything in the chroot changes. The stock desktop image has neither
# rsvg-convert nor ImageMagick, so the greeter logo (Step 3), the Plymouth firmware-logo fallback (Step 5) and the
# Settings > About logos (Step 5c) are drawn here from the vendored marks and installed from this directory. Doing
# it first means a host that cannot render them (build-iso.sh checks the tools, but this script can be run
# directly) stops now, with a message, and not in Step 3 with os-release rewritten and packages removed.
# Removed again after Step 5c.
# Both are needed, the rule build-iso.sh applies: rsvg-convert draws the marks, ImageMagick composes the GRUB
# background (Step 4) and scales the Plymouth watermark (Step 5), and without it those two steps only warn and
# ship a degraded image that verify-iso.sh catches after the build.
render_missing=()
command -v rsvg-convert >/dev/null 2>&1 || render_missing+=("rsvg-convert (librsvg2-bin)")
if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
    render_missing+=("magick or convert (imagemagick)")
fi
if [[ ${#render_missing[@]} -gt 0 ]]; then
    echo "[ERROR] Missing on this host: ${render_missing[*]}; the logo PNGs, the GRUB background and the Plymouth watermark cannot be rendered." >&2
    echo "[ERROR] apt-get install librsvg2-bin imagemagick" >&2
    exit 1
fi
# What this script makes outside the chroot proper (the host render directory, the Plymouth overlay, the staged copy
# of the repo that run_theme_step puts in the chroot's /tmp) is removed on EVERY exit, so a theme step that fails
# under set -e does not leave a host temp directory behind per attempt. The paths are removed again where their
# steps finish; Step 10e's own EXIT trap calls this too, and puts this one back.
LOGO_RENDER_DIR=""
PLYMOUTH_OVERLAY=""
ci_brand_cleanup() {
    if [[ -n "$LOGO_RENDER_DIR" ]]; then rm -rf "$LOGO_RENDER_DIR"; fi
    if [[ -n "$PLYMOUTH_OVERLAY" ]]; then rm -rf "$PLYMOUTH_OVERLAY"; fi
    rm -rf "$CHROOT_PATH/tmp/ci-brand"
}
trap ci_brand_cleanup EXIT
LOGO_RENDER_DIR="$(mktemp -d)"
bash "$REPO_ROOT/core/render/render-mark-png.sh" "$LOGO_RENDER_DIR/companion-logo.png" 256
# 128 px, the size of Ubuntu's bgrt-fallback.png (10-plymouth.sh installs it over that file).
mkdir -p "$LOGO_RENDER_DIR/plymouth/core/render/output"
bash "$REPO_ROOT/core/render/render-mark-png.sh" "$LOGO_RENDER_DIR/plymouth/core/render/output/ci-os-bgrt-fallback.png" 128
mkdir -p "$LOGO_RENDER_DIR/about/core/render/output"
bash "$REPO_ROOT/core/render/render-mark-png.sh" "$LOGO_RENDER_DIR/about/core/render/output/ci-os-about-logo.png" 192 "$CI_LIGHT_PRIMARY"
bash "$REPO_ROOT/core/render/render-mark-png.sh" "$LOGO_RENDER_DIR/about/core/render/output/ci-os-about-logo-dark.png" 192 "$CI_DARK_PRIMARY"

# Helper function to run commands in chroot
chroot_exec() {
    chroot "$CHROOT_PATH" /bin/bash -c "$*"
}

# Helper function to copy files into chroot
copy_to_chroot() {
    local src="$1"
    local dest="$2"
    mkdir -p "$CHROOT_PATH/$(dirname "$dest")"
    cp -r "$src" "$CHROOT_PATH/$dest"
}

# run_theme_step <script> [overlay_dir]
# Run one backends/ubuntu/desktop-theme step INSIDE the chroot, so it is the same token-driven code the
# post-install re-skin (apply-ci-os-desktop.sh) runs. The step is staged with the shared theme library, the
# os-release writer (backends/ubuntu/lib/os-release.sh), the vendored canon (tokens, logos) and the render
# inputs/outputs, keeping the repo's relative layout so the script's own REPO_ROOT / theme-lib.sh sourcing
# resolves without chroot-specific changes. It runs with CI_BRAND_IMAGE_BUILD=1 and the build's CI_OS_VERSION:
# no backup directories, stock files diverted (ci_install_file). overlay_dir, a host directory laid out like
# the repo, is copied over the stage: it carries what has to be prepared on the build host, because the
# stock desktop image has neither ImageMagick nor rsvg-convert. The stage is removed afterwards.
run_theme_step() {
    local script="$1" overlay="${2:-}"
    local stage="$CHROOT_PATH/tmp/ci-brand"
    rm -rf "$stage"
    mkdir -p "$stage/backends/ubuntu/desktop-theme" "$stage/backends/ubuntu/lib" "$stage/core/lib" "$stage/core/render" "$stage/vendor/brand"
    cp "$REPO_ROOT"/backends/ubuntu/desktop-theme/*.sh "$stage/backends/ubuntu/desktop-theme/"
    cp "$REPO_ROOT/backends/ubuntu/lib/os-release.sh" "$stage/backends/ubuntu/lib/"
    cp "$REPO_ROOT/core/lib/theme-lib.sh" "$stage/core/lib/"
    cp -R "$REPO_ROOT/vendor/brand/tokens" "$REPO_ROOT/vendor/brand/logos" "$stage/vendor/brand/"
    cp -R "$REPO_ROOT/core/render/inputs" "$stage/core/render/"
    if [[ -d "$REPO_ROOT/core/render/output" ]]; then
        cp -R "$REPO_ROOT/core/render/output" "$stage/core/render/"
    fi
    if [[ -n "$overlay" ]]; then
        cp -R "$overlay/." "$stage/"
    fi
    chroot_exec "CI_BRAND_IMAGE_BUILD=1 CI_OS_VERSION=$(printf '%q' "$CI_OS_VERSION") bash /tmp/ci-brand/backends/ubuntu/desktop-theme/$script"
    rm -rf "$stage"
}

#=============================================================================
# 1. Update OS Identity
#=============================================================================
echo "[*] Step 1: Updating OS identity..."

# IMPORTANT: The squashfs is both the live session AND the base that gets
# copied to disk during installation. Subiquity/curtin rely on ID=ubuntu and
# the base image's VERSION_ID (26.04) to configure apt sources, run
# curthooks (update-initramfs, grub-install), and seed snaps correctly.
# Setting ID=ci-os here breaks the installer toolchain. Instead, we:
#  - Keep ubuntu-compatible IDs in os-release / lsb-release (live + initial install)
#  - Keep the base image's version and codename (26.04, resolute)
#  - Brand NAME and PRETTY_NAME as Companion OS (visible in Settings > About, neofetch, etc.)
#  - Install a first-boot systemd service that rewrites the IDs to ci-os after
#    the installer has finished and the system first boots into the desktop.

# Companion OS is built on Ubuntu 26.04 LTS (resolute) and nothing else. Read what the base says it is and stop, before
# anything in the chroot has changed, if it is not that: a base of another release is not converted. There is no default
# for a base that does not say (a chroot without /etc/os-release is not an extracted Ubuntu desktop image at all).
if [[ ! -f "$CHROOT_PATH/etc/os-release" ]]; then
    echo "[ERROR] $CHROOT_PATH/etc/os-release not found: this is not an extracted Ubuntu 26.04 desktop image." >&2
    exit 1
fi
BASE_VERSION_ID="$(grep -E '^VERSION_ID=' "$CHROOT_PATH/etc/os-release" | head -1 | cut -d= -f2 | tr -d '"' || true)"
BASE_CODENAME="$(grep -E '^VERSION_CODENAME=' "$CHROOT_PATH/etc/os-release" | head -1 | cut -d= -f2 | tr -d '"' || true)"
if ! ci_os_base_is_supported "$BASE_VERSION_ID" "$BASE_CODENAME"; then
    exit 1
fi
# Save the pristine Ubuntu identity before branding overwrites it. ROCm, apt and the Docker and Tailscale repositories
# look here for the Ubuntu suite.
install -m 644 "$CHROOT_PATH/etc/os-release" "$CHROOT_PATH/etc/os-release.ubuntu-base"
echo "[*] Base Ubuntu identity: ${BASE_VERSION_ID} (${BASE_CODENAME})"

# os-release and lsb-release (DISTRIB_ID=Ubuntu, so lsb_release -si / -sr return what the installer and apt
# expect) come from the one writer, backends/ubuntu/lib/os-release.sh, which 50-os-release.sh calls: the same
# code first-boot-rebrand.sh and the post-install re-skin run. It reads the base identity saved above from
# /etc/os-release.ubuntu-base and the version from the CI_OS_VERSION that run_theme_step exports.
run_theme_step 50-os-release.sh

# ---------------------------------------------------------------------------
# First-boot rebrand service
# Runs once after installation is complete and the user boots the installed
# system for the first time. Writes the real CI-OS IDs and disables itself.
# ---------------------------------------------------------------------------
mkdir -p "$CHROOT_PATH/usr/lib/ci-os"

# The version this image was built as, kept outside /etc/os-release for the rebrand below: that file is base-files' and
# is what gets reset to Ubuntu's, and a writer that finds no CI_OS_VERSION in it falls back to 0.0.1.
printf '%s\n' "$CI_OS_VERSION" > "$CHROOT_PATH/usr/lib/ci-os/version"
chmod 0644 "$CHROOT_PATH/usr/lib/ci-os/version"

cat > "$CHROOT_PATH/usr/lib/ci-os/first-boot-rebrand.sh" << 'REBRAND'
#!/bin/bash
# CI-OS first-boot branding refresh — keeps Ubuntu-compatible machine identity.
set -euo pipefail

# The version the image was built as (customize-chroot.sh writes it). It wins over whatever /etc/os-release says now.
CI_OS_VERSION=""
if [[ -r /usr/lib/ci-os/version ]]; then
  CI_OS_VERSION="$(head -n 1 /usr/lib/ci-os/version)"
fi
export CI_OS_VERSION

if [[ -f /usr/lib/ci-os/bootstrap/backends/ubuntu/lib/os-release.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/lib/ci-os/bootstrap/backends/ubuntu/lib/os-release.sh
  ci_os_write_branded_os_release /etc/os-release
  ci_os_write_branded_lsb_release /etc/lsb-release
else
  if [[ -z "$CI_OS_VERSION" ]]; then
    CI_OS_VERSION="$(grep '^CI_OS_VERSION=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
  fi
  CI_OS_VERSION="${CI_OS_VERSION:-1.0}"
  UBUNTU_CODENAME="$(grep '^UBUNTU_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo resolute)"
  UBUNTU_VER="$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo 26.04)"
  cat > /etc/os-release << __EOF__
NAME="Companion OS"
VERSION="${UBUNTU_VER} LTS (Companion OS ${CI_OS_VERSION})"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Companion OS ${CI_OS_VERSION}"
VERSION_ID="${UBUNTU_VER}"
VERSION_CODENAME=${UBUNTU_CODENAME}
UBUNTU_CODENAME=${UBUNTU_CODENAME}
CI_OS_ID=ci-os
CI_OS_VERSION="${CI_OS_VERSION}"
HOME_URL="https://ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
LOGO=ci-os-logo
__EOF__
fi

# The stamp is what keeps the unit from running again (its ConditionPathExists=!); disabling it as well is tidiness.
install -d -m 0755 /var/lib/ci-os
: > /var/lib/ci-os/.first-boot-rebrand-done
systemctl disable ci-os-first-boot-rebrand.service
echo "[CI-OS] First-boot branding refresh complete (ID=ubuntu, CI_OS_ID=ci-os)"
REBRAND

chmod +x "$CHROOT_PATH/usr/lib/ci-os/first-boot-rebrand.sh"

cat > "$CHROOT_PATH/usr/lib/systemd/system/ci-os-first-boot-rebrand.service" << 'SVCEOF'
[Unit]
Description=Companion OS first-boot identity rebranding
Documentation=https://ci.computer
After=local-fs.target
Before=display-manager.service gdm.service
ConditionPathExists=/usr/lib/ci-os/first-boot-rebrand.sh
# Run once: the script writes this stamp when it is done (and disables the service). Not ConditionFirstBoot=yes:
# subiquity copies the live session's /etc/machine-id into the new system, and a boot with a valid machine-id is not a
# first boot to systemd (machine-id(5)), so on an installed machine that condition is false and the unit never ran.
# Measured with systemd 259.5 as PID 1: the unit is skipped with an installer-style machine-id.
ConditionPathExists=!/var/lib/ci-os/.first-boot-rebrand-done
# NEVER run in the live USB session.
# Ubuntu's ISO does NOT pass boot=casper on the kernel command line (measured on 26.04.1: the entries are
# "linux /casper/vmlinuz --- quiet splash"; casper's initrd sets BOOT=casper itself), so
# ConditionKernelCommandLine would silently pass. Instead we check for the
# casper live-boot files on the ISO mount at /cdrom.
ConditionPathExists=!/cdrom/casper/vmlinuz

[Service]
Type=oneshot
ExecStart=/usr/lib/ci-os/first-boot-rebrand.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

# Enable the service
mkdir -p "$CHROOT_PATH/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/ci-os-first-boot-rebrand.service \
    "$CHROOT_PATH/etc/systemd/system/multi-user.target.wants/ci-os-first-boot-rebrand.service"

echo "[+] OS identity configured (Ubuntu-compatible IDs for installer, CI-OS rebrand on first boot)"

# Update hostname default
echo "companion-os" > "$CHROOT_PATH/etc/hostname"

# Live-session identity. casper derives HOST and USERNAME from the first word of /.disk/info at boot (and
# rewrites casper.conf) unless FLAVOUR is set, which is why a stock live session is always ubuntu@ubuntu.
# Setting FLAVOUR explicitly turns that off. The live boot reads the copy of this file that lives INSIDE
# casper/initrd, so build-iso.sh (brand_boot_media) copies this file there.
cat > "$CHROOT_PATH/etc/casper.conf" << 'EOF'
# This file should go in /etc/casper.conf
# Values are used by casper, the live-session boot scripts. A copy is baked into casper/initrd.
export USERNAME="companion"
export USERFULLNAME="Companion OS live session"
export HOST="companion-os"
# casper keys several decisions off BUILD_SYSTEM; leave it as Ubuntu.
export BUILD_SYSTEM="Ubuntu"
# Any non-empty value stops casper deriving HOST and USERNAME from /.disk/info.
export FLAVOUR="Companion"
EOF

# Create custom issue banner
cat > "$CHROOT_PATH/etc/issue" << 'EOF'

  Companion OS
  Companion Intelligence - https://ci.computer

EOF

cp "$CHROOT_PATH/etc/issue" "$CHROOT_PATH/etc/issue.net"

echo "[+] OS identity updated"

#=============================================================================
# 1b. Pin the initramfs generator (before the first apt call below)
#=============================================================================
echo "[*] Step 1b: Pinning the initramfs generator (no dracut)..."

# The merged base is an initramfs-tools system (the stock live layer removes dracut), but ubuntu-desktop-minimal
# Recommends dracut and dracut Conflicts with initramfs-tools. The file keeps apt from ever swapping them. It goes in
# before Step 2, the first step that runs apt-get in the chroot. See the file for why dracut-install is not in it.
install -D -m 0644 "$SCRIPT_DIR/payload/apt/etc/apt/preferences.d/ci-os-no-dracut" \
    "$CHROOT_PATH/etc/apt/preferences.d/ci-os-no-dracut"

echo "[+] dracut and dracut-core are pinned to priority -1 (/etc/apt/preferences.d/ci-os-no-dracut)"

#=============================================================================
# 2. Remove Telemetry and Bloatware
#=============================================================================
echo "[*] Step 2: Removing telemetry and bloatware..."

# Add telemetry domains to /etc/hosts
cat >> "$CHROOT_PATH/etc/hosts" << 'EOF'

# Block Ubuntu telemetry
127.0.0.1 metrics.ubuntu.com
127.0.0.1 www.metrics.ubuntu.com
127.0.0.1 popcon.ubuntu.com
127.0.0.1 www.popcon.ubuntu.com
EOF

# Disable Ubuntu MOTD ads
chroot_exec "chmod -x /etc/update-motd.d/50-motd-news" || true
chroot_exec "chmod -x /etc/update-motd.d/10-help-text" || true

# Create script to run apt operations
cat > "$CHROOT_PATH/tmp/remove-packages.sh" << 'EOFSCRIPT'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# Update package lists
apt-get update

# Remove telemetry packages
apt-get purge -y ubuntu-report popularity-contest apport whoopsie apport-symptoms landscape-common || true

# Hold packages to prevent reinstall
apt-mark hold ubuntu-report popularity-contest apport whoopsie apport-symptoms landscape-common || true

# ── DO NOT TOUCH THE SNAP SEED ──────────────────────────────────────────────
# The snap seed (/var/lib/snapd/seed/) is cryptographically signed via the
# model assertion. Removing any snap files or editing seed.yaml causes snapd
# seed validation to fail on boot, which prevents ALL snaps from mounting —
# including ubuntu-desktop-bootstrap (the installer). This results in a
# "broken desktop file" error and the installer never launches.
#
# Instead, snap-store and thunderbird removal is deferred to the first-boot
# service that runs AFTER installation is complete and snapd is fully running.

# Remove bloatware debs (be conservative - only remove obvious bloat)
# NOTE: thunderbird is a snap on 26.04 (in the standard layer's seed); it is removed at first boot, see above.
apt-get purge -y \
    aisleriot \
    gnome-mahjongg \
    gnome-mines \
    gnome-sudoku || true

# Clean up
apt-get autoremove -y
apt-get autoclean
EOFSCRIPT

chmod +x "$CHROOT_PATH/tmp/remove-packages.sh"
chroot_exec "/tmp/remove-packages.sh"
rm "$CHROOT_PATH/tmp/remove-packages.sh"

echo "[+] Telemetry and bloatware removed"

#=============================================================================
# 2b. Apply CI-OS Branding Theme (direct file copy — no packages/postinst)
#=============================================================================
echo "[*] Step 2b: Applying CI-OS GNOME Shell / GDM theme..."

GRESOURCE_SRC="$REPO_ROOT/backends/ubuntu/packages/ci-os-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
# The blob is the Ubuntu 26.04 Yaru theme recoloured (backends/ubuntu/packages/PROVENANCE-gnome-shell-theme.txt says from
# what, and core/render/render-gnome-shell-gresource.sh refuses to rebuild it from anything else). It always replaces the
# Yaru theme, which the ubuntu session and the GDM greeter load. It replaces the upstream GNOME theme too only if it
# provides every resource that file does: see backends/ubuntu/lib/shell-theme.sh.
ci_os_install_shell_theme "$GRESOURCE_SRC" "$CHROOT_PATH" || true

#=============================================================================
# 3. Install CI-OS Branding
#=============================================================================
echo "[*] Step 3: Installing CI-OS branding..."

# Greeter logo (the gdm dconf logo= key below points here): the colour mark from the vendored canon at 256 px,
# rendered on the build host at the top of this script. assets/logos/ci-holo-depth.png (a pastel hologram, no
# CI-Common counterpart) is no longer used.
install -D -m 644 "$LOGO_RENDER_DIR/companion-logo.png" "$CHROOT_PATH/usr/share/pixmaps/companion-logo.png"

# Copy wallpaper — try primary path first, then fallback, warn if neither exists
if [[ -f "$REPO_ROOT/core/render/inputs/background.png" ]]; then
    copy_to_chroot "$REPO_ROOT/core/render/inputs/background.png" "/usr/share/backgrounds/ci-os-wallpaper.png"
    echo "[+] Wallpaper installed from core/render/inputs/background.png"
elif [[ -f "$REPO_ROOT/assets/wallpapers/ci-os-wallpaper.svg" ]]; then
    copy_to_chroot "$REPO_ROOT/assets/wallpapers/ci-os-wallpaper.svg" "/usr/share/backgrounds/ci-os-wallpaper.svg"
    echo "[+] Wallpaper installed from assets/wallpapers/ci-os-wallpaper.svg"
    WALLPAPER_EXT="svg"
    # Update dconf to point to the SVG path
    sed -i "s|ci-os-wallpaper.png|ci-os-wallpaper.svg|g" \
        "$CHROOT_PATH/etc/dconf/db/local.d/01-ci-os-wallpaper" || true
else
    echo "[WARN] No wallpaper found at core/render/inputs/background.png or assets/wallpapers/ci-os-wallpaper.svg — skipping wallpaper install"
fi

# Set default wallpaper for user sessions (local.d applies to regular users)
mkdir -p "$CHROOT_PATH/etc/dconf/db/local.d"
cat > "$CHROOT_PATH/etc/dconf/db/local.d/01-ci-os-wallpaper" << 'EOF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-uri-dark='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-options='zoom'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-options='zoom'
EOF

# The dock (the left GNOME bar): Ubuntu's default pins Firefox, Thunderbird, LibreOffice Writer, App Center and Help. The
# list is backends/ubuntu/chroot/dock-favorites.txt. It goes into the local dconf db, not a schema override: Ubuntu's own
# favorite-apps is set per desktop session (10_ubuntu-settings.gschema.override), which an unscoped 9x_ override does not
# beat, while a system db value does (the user profile above reads it) and applies to the live session and the installed
# system alike. A user's own pin or unpin still wins, as it lives in the user db.
DOCK_FAVORITES_VALUE="$(dock_favorites_value "$REPO_ROOT/backends/ubuntu/chroot/dock-favorites.txt")" \
    || { echo "[ERROR] backends/ubuntu/chroot/dock-favorites.txt is not a valid dock list" >&2; exit 1; }
cat > "$CHROOT_PATH/etc/dconf/db/local.d/02-ci-os-dock" << EOF
[org/gnome/shell]
favorite-apps=$DOCK_FAVORITES_VALUE
EOF

# ── Configure GDM (login screen) branding ──────────────────────────────────
# GDM reads from its OWN dconf database, not the user's local.d.
# The profile at /usr/share/dconf/profile/gdm tells GDM to read:
#   user-db:user
#   file-db:/var/lib/gdm3/greeter-dconf-defaults
# We write our overrides to /etc/dconf/db/gdm.d/ and compile via dconf update.
mkdir -p "$CHROOT_PATH/etc/dconf/db/gdm.d"
cat > "$CHROOT_PATH/etc/dconf/db/gdm.d/01-ci-os-login" << 'EOF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-uri-dark='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-options='zoom'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-options='zoom'

[org/gnome/login-screen]
logo='/usr/share/pixmaps/companion-logo.png'
EOF

# Ensure the GDM dconf profile references the gdm database
# (Ubuntu ships this by default, but ensure it exists in our chroot)
mkdir -p "$CHROOT_PATH/usr/share/dconf/profile"
cat > "$CHROOT_PATH/usr/share/dconf/profile/gdm" << 'EOF'
user-db:user
system-db:gdm
file-db:/var/lib/gdm3/greeter-dconf-defaults
EOF

# Lock the GDM settings so they can't be overridden per-user
mkdir -p "$CHROOT_PATH/etc/dconf/db/gdm.d/locks"
cat > "$CHROOT_PATH/etc/dconf/db/gdm.d/locks/01-ci-os-login" << 'EOF'
/org/gnome/desktop/background/picture-uri
/org/gnome/desktop/background/picture-uri-dark
/org/gnome/login-screen/logo
EOF

# ── Make the wallpaper actually apply ─────────────────────────────────────
# Without /etc/dconf/profile/user, dconf reads ONLY the user's own database, so the system "local" database
# written above is ignored, and Ubuntu's 10_ubuntu-settings.gschema.override (the Ubuntu wallpaper) wins.
mkdir -p "$CHROOT_PATH/etc/dconf/profile"
cat > "$CHROOT_PATH/etc/dconf/profile/user" << 'EOF'
user-db:user
system-db:local
EOF

# Belt and braces: override the schema default itself. Sorts after Ubuntu's 10_ override, applies to every
# session type, and does not depend on the dconf profile.
cat > "$CHROOT_PATH/usr/share/glib-2.0/schemas/90_companion-os.gschema.override" << 'EOF'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-uri-dark='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-options='zoom'

[org.gnome.desktop.screensaver]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-options='zoom'
EOF

# The SVG fallback above rewrote a file that did not exist yet; apply the extension to what was written.
if [[ "${WALLPAPER_EXT:-png}" != "png" ]]; then
    sed -i "s|ci-os-wallpaper\.png|ci-os-wallpaper.${WALLPAPER_EXT}|g" \
        "$CHROOT_PATH/etc/dconf/db/local.d/01-ci-os-wallpaper" \
        "$CHROOT_PATH/etc/dconf/db/gdm.d/01-ci-os-login" \
        "$CHROOT_PATH/usr/share/glib-2.0/schemas/90_companion-os.gschema.override"
fi

# Settings > Background should offer ours, not Ubuntu's collections. dpkg-divert so a package upgrade does
# not bring them back. Every *.xml of the directory except ours: the stock 26.04.1 image has ubuntu-wallpapers.xml and
# resolute-wallpapers.xml (ubuntu-wallpapers-resolute), and a later release adds a file named after itself, so no
# fixed list of names is kept.
for xml_path in "$CHROOT_PATH"/usr/share/gnome-background-properties/*.xml; do
    [[ -f "$xml_path" ]] || continue
    xml="$(basename "$xml_path")"
    [[ "$xml" == "ci-os-wallpapers.xml" ]] && continue
    # A rebuild without --clean re-extracts the stock layers over this chroot: the stock xml and the stock
    # diversions registry come back, but the .disabled file of the previous run (in no layer) stays, and
    # dpkg-divert refuses to rename over it. The `|| true` below would hide that, and Settings > Background
    # would offer Ubuntu's collections. With no diversion registered the xml is the fresh stock file, so the
    # leftover is stale (the same reasoning as ci_divert_file in core/lib/theme-lib.sh).
    if [[ -z "$(chroot_exec "dpkg-divert --list /usr/share/gnome-background-properties/$xml" 2>/dev/null)" ]]; then
        rm -f "$CHROOT_PATH/usr/share/gnome-background-properties/$xml.disabled"
    fi
    chroot_exec "dpkg-divert --local --rename --divert /usr/share/gnome-background-properties/$xml.disabled --add /usr/share/gnome-background-properties/$xml" \
        || echo "[WARN] could not divert gnome-background-properties/$xml: Settings > Background may still offer it"
done
cat > "$CHROOT_PATH/usr/share/gnome-background-properties/ci-os-wallpapers.xml" << EOF
<?xml version="1.0"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
  <wallpaper deleted="false">
    <name>Companion OS</name>
    <filename>/usr/share/backgrounds/ci-os-wallpaper.${WALLPAPER_EXT:-png}</filename>
    <options>zoom</options>
    <pcolor>${CI_LIGHT_PRIMARY}</pcolor>
    <scolor>${CI_LIGHT_PRIMARY}</scolor>
    <shade_type>solid</shade_type>
  </wallpaper>
</wallpapers>
EOF
chroot_exec "glib-compile-schemas /usr/share/glib-2.0/schemas" || echo "[WARN] glib-compile-schemas failed"

# Update dconf database (compiles local + gdm databases)
chroot_exec "dconf update" || true

echo "[+] Branding installed"

#=============================================================================
# 4. Configure GRUB
#=============================================================================
echo "[*] Step 4: Configuring GRUB..."

# shellcheck source=../../../core/lib/grub-merge.sh
source "$REPO_ROOT/core/lib/grub-merge.sh"

# Kernel cmdline stays as its own explicit sed (not a branding key, no reason
# to route it through the merge helper). Branding keys below use
# ci_grub_merge_key so they never clobber other keys already in this file.
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' "$CHROOT_PATH/etc/default/grub" || true

ci_grub_merge_key "$CHROOT_PATH/etc/default/grub" GRUB_DISTRIBUTOR "Companion OS"
ci_grub_merge_key "$CHROOT_PATH/etc/default/grub" GRUB_GFXMODE "auto"
ci_grub_merge_key "$CHROOT_PATH/etc/default/grub" GRUB_TIMEOUT_STYLE "menu"
ci_grub_merge_key "$CHROOT_PATH/etc/default/grub" GRUB_TIMEOUT "5"

# Render and install the GRUB background (colors-only theming, same as
# Plymouth below — see docs/architecture/multi-distro-design.md). Deliberately
# does not set GRUB_TERMINAL: a hardcoded GRUB_TERMINAL=console previously
# found in an old, now-deleted config silently disabled GRUB_BACKGROUND
# entirely (console mode is text-only). Leaving it unset lets GRUB default to
# gfxterm when a background is present.
GRUB_BG_DEST_REL="usr/share/pixmaps/ci-os-grub-bg.png"
if bash "$REPO_ROOT/core/render/render-grub-background.sh" "$CHROOT_PATH/$GRUB_BG_DEST_REL"; then
    chmod 644 "$CHROOT_PATH/$GRUB_BG_DEST_REL"
    ci_grub_merge_key "$CHROOT_PATH/etc/default/grub" GRUB_BACKGROUND "/$GRUB_BG_DEST_REL"
    echo "[+] GRUB background installed: /$GRUB_BG_DEST_REL"
else
    echo "[!] Could not render GRUB background — GRUB will use its default background"
fi

echo "[+] GRUB configured"

#=============================================================================
# 5. Configure Plymouth Splash
#=============================================================================
echo "[*] Step 5: Configuring Plymouth splash..."

# Reuse backends/ubuntu/desktop-theme/10-plymouth.sh — the same, already-correct
# token-driven Plymouth theming the post-install re-skin path uses — instead of
# forking its sed/color logic into a second copy here (that duplication is
# exactly what caused the terminal-theme token drift found elsewhere in this
# repo). run_theme_step stages it into the chroot (see its comment).
#
# Note: this brands Plymouth for the INSTALLED system's own boots (curtin
# regenerates the initramfs from this rootfs during install finalization)
# and the live session's rootfs copies. The live/installer-session splash
# itself, before GRUB hands off, is drawn from the copies inside casper/initrd,
# which is copied verbatim from the stock Ubuntu ISO: build-iso.sh
# (brand_boot_media) appends an overlay to it that repaints those copies with
# the same helpers and takes the watermark and the firmware-logo fallback from
# this rootfs, so they have to be right here first.

# The stock desktop image has no ImageMagick or rsvg-convert, so the overlay carries what 10-plymouth.sh cannot
# draw inside the chroot. The firmware-logo fallback (rendered at the top of this script) is always staged. The
# watermark is pre-scaled on the build host to 50% (10-plymouth.sh would otherwise copy the full-size banner,
# 1024 px wide, about four times Ubuntu's own splash logo), laid over the staged inputs; skipped if the chroot
# does have ImageMagick, so it is never scaled twice.
PLYMOUTH_OVERLAY="$(mktemp -d)"
cp -R "$LOGO_RENDER_DIR/plymouth/." "$PLYMOUTH_OVERLAY/"
if ! chroot "$CHROOT_PATH" /bin/sh -c 'command -v convert || command -v magick' >/dev/null 2>&1; then
    mkdir -p "$PLYMOUTH_OVERLAY/core/render/inputs"
    _wm="$PLYMOUTH_OVERLAY/core/render/inputs/Logo_Banner_Color.png"
    cp "$REPO_ROOT/core/render/inputs/Logo_Banner_Color.png" "$_wm"
    if command -v convert >/dev/null 2>&1; then
        convert "$_wm" -resize 50% "$_wm"
    elif command -v magick >/dev/null 2>&1; then
        magick "$_wm" -resize 50% "$_wm"
    else
        echo "[WARN] ImageMagick is not installed on the build host: the Plymouth watermark will be full size"
        echo "[WARN] (apt-get install imagemagick). verify-iso.sh flags this."
    fi
fi

run_theme_step 10-plymouth.sh "$PLYMOUTH_OVERLAY"
rm -rf "$PLYMOUTH_OVERLAY"

echo "[+] Plymouth configured from the canon tokens (installed-system boots, live initrd overlay source)"

#=============================================================================
# 5b. Dock "Show Applications" button (Yaru start-here-symbolic)
#=============================================================================
echo "[*] Step 5b: Replacing the dock start icon..."

# 40-start-icon.sh: the dock's bottom button is view-app-grid-ubuntu-symbolic.svg, a symlink to Yaru's
# start-here-symbolic.svg. The step generates the icon from the vendored one-colour mark (vendor/brand/logos/
# mark-mono.svg: its path data, currentColor, viewBox cropped); GNOME recolours a -symbolic icon to one tone,
# so it shows as a silhouette.
# yaru-theme-icon owns the file; the step diverts it so an upgrade cannot restore Ubuntu's.
run_theme_step 40-start-icon.sh

echo "[+] Dock start icon replaced"

#=============================================================================
# 5c. Settings > About logo and the os-release LOGO= icon
#=============================================================================
echo "[*] Step 5c: Replacing the Settings > About logo..."

# 45-about-logo.sh installs the one-colour mark over base-files' /usr/share/pixmaps/ubuntu-logo-text{,-dark}.svg (the
# files gnome-control-center 50 reads for Settings > About) and over the .png pair (the older reader, and the Plymouth
# watermark's target), and the mark as the ci-os-logo icon that os-release LOGO= names. The mark is filled with the canon
# primary of each mode. The SVGs are the vendored mark with its colour set (no renderer needed); the PNGs are rendered on
# the build host at the top of this script (the chroot has no rsvg-convert) and handed to the step as an overlay. In an
# image build the step fails without the PNGs rather than leave Ubuntu's wordmark.
run_theme_step 45-about-logo.sh "$LOGO_RENDER_DIR/about"
rm -rf "$LOGO_RENDER_DIR"

echo "[+] About logo replaced (light and dark)"

#=============================================================================
# 5d. Visible Ubuntu names: session picker, Settings sidebar entry, extension names
#=============================================================================
echo "[*] Step 5d: Renaming the visible Ubuntu display names..."

# 60-visible-names.sh rewrites only the display strings the other steps leave on screen: the Name=/Comment= of the one
# session Ubuntu 26.04 ships, /usr/share/wayland-sessions/ubuntu.desktop (GDM lists it as "Companion OS"; there is no
# Xorg session and no second entry), of gnome-ubuntu-panel.desktop (the Settings sidebar entry) and the "name" of the
# dock, AppIndicators and Tiling Assistant extensions. File names, uuids, Exec=, TryExec=, DesktopNames= and the other
# required identifiers stay as shipped, and the step stops if an edit would change any other line. The owning packages
# (ubuntu-session, gnome-control-center, gnome-shell-ubuntu-extensions) are diverted first, so an upgrade cannot bring the
# Ubuntu names back.
run_theme_step 60-visible-names.sh

echo "[+] Session picker, Settings entry and extension names read Companion OS"

#=============================================================================
# 6. Install AMD GPU Support
#=============================================================================
echo "[*] Step 6: Installing AMD GPU support..."

cat > "$CHROOT_PATH/tmp/install-amd.sh" << 'EOFSCRIPT'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Add AMD GPU PPA (if available) or use Ubuntu's default amdgpu driver
# For ROCm, we'll document manual installation post-install due to kernel dependencies

# Ensure amdgpu firmware is installed (both are in the stock image already; a failure here is not fatal)
apt-get install -y linux-firmware amd64-microcode || true

# The 64-bit Vulkan stack. One call of its own, and a failure is NOT hidden: this line used to list the :i386 libraries
# too, and with `|| true` a single unavailable name made apt install none of them and the build went on without
# Vulkan. The 32-bit libraries (mesa-vulkan-drivers:i386, libvulkan1:i386: 40 packages, about 150 MB) are left out on
# purpose: i386 is only a configured foreign architecture of the stock image (the archive still serves them), and
# Companion OS ships no 32-bit application, Wine or Steam. `apt install <name>:i386` works on a machine that wants them.
apt-get install -y \
    mesa-vulkan-drivers \
    libvulkan1 \
    vulkan-tools

# Note: Full ROCm stack requires specific kernel versions and is best installed post-install
# We'll create a helper script for that

EOFSCRIPT

chmod +x "$CHROOT_PATH/tmp/install-amd.sh"
chroot_exec "/tmp/install-amd.sh"
rm "$CHROOT_PATH/tmp/install-amd.sh"

# Create post-install ROCm setup script
mkdir -p "$CHROOT_PATH/usr/local/bin"
cat > "$CHROOT_PATH/usr/local/bin/ci-os-install-rocm" << 'EOFSCRIPT'
#!/bin/bash
# Delegates to the maintained Companion OS ROCm installer (ROCm from the Ubuntu 26.04 archive).
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi
BOOTSTRAP_ROOT="/usr/lib/ci-os/bootstrap/backends/ubuntu"
if [[ -x "$BOOTSTRAP_ROOT/lib/install-rocm-driver.sh" ]]; then
  exec "$BOOTSTRAP_ROOT/lib/install-rocm-driver.sh" "$@"
fi
echo "[ci-os-install-rocm] bootstrap installer missing; install ROCm manually." >&2
exit 1
EOFSCRIPT

chmod +x "$CHROOT_PATH/usr/local/bin/ci-os-install-rocm"

echo "[+] AMD GPU support configured (ROCm available via ci-os-install-rocm)"

#=============================================================================
# 7. Installer
#=============================================================================
# Nothing to configure, on purpose. The installer is Canonical's ubuntu-desktop-bootstrap snap (rev 665 on 26.04.1;
# base core24, classic confinement: a Flutter UI plus the Subiquity server). Its flavour list is fixed inside the snap, so
# the window cannot be given another name or palette from the image. The whitelabel.yaml and slideshow this
# step used to write under /usr/share/desktop-provision were never read by it.
# What the image CAN control is the launcher label ("Install Companion OS ..."), which casper derives from
# /.disk/info at boot: see brand_boot_media in backends/ubuntu/iso/scripts/build-iso.sh. Rebranding the
# installer window itself would mean shipping a modified installer snap.
echo "[*] Step 7: Installer: nothing to configure (launcher label comes from /.disk/info)"

#=============================================================================
# 8. Create CI-OS MOTD
#=============================================================================
echo "[*] Step 8: Creating Companion OS MOTD..."

# The same text core/render/render-motd.sh writes when it re-skins an installed system: keep the two in step.
cat > "$CHROOT_PATH/etc/update-motd.d/00-ci-os-header" << 'EOF'
#!/bin/sh
cat << 'MOTD'

  Companion OS
  Companion Intelligence - https://ci.computer

MOTD
EOF

chmod +x "$CHROOT_PATH/etc/update-motd.d/00-ci-os-header"

# Ubuntu's own welcome line and the Ubuntu Pro advert. (50-motd-news and 10-help-text are handled in Step 2.)
for _motd in 00-header 91-contract-ua-esm-status; do
    [[ -e "$CHROOT_PATH/etc/update-motd.d/$_motd" ]] && chmod -x "$CHROOT_PATH/etc/update-motd.d/$_motd"
done

echo "[+] MOTD created"

#=============================================================================
# 9. Create CI-OS Info Command
#=============================================================================
echo "[*] Step 9: Creating CI-OS info command..."

cat > "$CHROOT_PATH/usr/local/bin/ci-os-info" << 'EOF'
#!/bin/bash
#=============================================================================
# CI-OS System Information
# Displays CI-OS version, AMD GPU info, and system status
#=============================================================================

echo "======================================"
echo "  Companion OS System Information"
echo "======================================"
echo

# OS Version
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "OS: $PRETTY_NAME"
    echo "Version: $VERSION_ID"
    echo "Codename: $UBUNTU_CODENAME"
fi
echo

# Kernel
echo "Kernel: $(uname -r)"
echo

# AMD GPU Detection
echo "AMD GPU Information:"
if lspci | grep -i "VGA.*AMD" > /dev/null; then
    lspci | grep -i "VGA.*AMD"
    echo
    
    # Check for amdgpu driver
    if lsmod | grep amdgpu > /dev/null; then
        echo "✓ amdgpu driver loaded"
    else
        echo "✗ amdgpu driver not loaded"
    fi
    
    # Check for ROCm
    if command -v rocminfo > /dev/null 2>&1; then
        echo "✓ ROCm installed"
    else
        echo "✗ ROCm not installed (run: sudo ci-os-install-rocm)"
    fi
else
    echo "No AMD GPU detected"
fi
echo

# User groups (for GPU access)
echo "User groups: $(groups)"
echo

echo "======================================"
echo "For ROCm installation: sudo ci-os-install-rocm"
echo "For support: https://ci.computer/support"
echo "======================================"
EOF

chmod +x "$CHROOT_PATH/usr/local/bin/ci-os-info"

echo "[+] CI-OS info command created"

#=============================================================================
# 10. Set up APT repository configuration (template)
#=============================================================================
echo "[*] Step 10: Setting up package repository configuration..."

mkdir -p "$CHROOT_PATH/etc/apt/sources.list.d"

# Create a template for the CI package repository (to be activated later)
cat > "$CHROOT_PATH/etc/apt/sources.list.d/companion-intelligence.list.disabled" << 'EOF'
# CI-OS Official Package Repository
# Uncomment when repository is available
# deb [signed-by=/usr/share/keyrings/ci-archive-keyring.gpg] https://packages.ci.computer/ubuntu resolute main
EOF

echo "[+] Package repository template created"

#=============================================================================
# 10b. Pre-install Development Packages
#=============================================================================
echo "[*] Step 10b: Pre-installing development packages..."

cat > "$CHROOT_PATH/tmp/install-dev-packages.sh" << 'EOFSCRIPT'
#!/bin/bash
# set -e: a name that is not in the archive stops the build. This install used to end in `|| true`, which turns a single
# unavailable package into "none of them installed" without a word.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update

# Core development tools. curl is first on purpose: the stock Ubuntu 26.04 desktop image does not have it (only the
# libcurl libraries), and everything after this step that downloads something inside the chroot uses it.
# Every name here was checked against the resolute archive.
apt-get install -y \
    curl \
    git \
    build-essential \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    wget \
    htop \
    net-tools \
    jq \
    unzip \
    tree \
    python3-pip \
    python3-venv \
    openssh-server

# Clean up after install
apt-get clean
rm -rf /var/lib/apt/lists/*
EOFSCRIPT

chmod +x "$CHROOT_PATH/tmp/install-dev-packages.sh"
chroot_exec "/tmp/install-dev-packages.sh"
rm -f "$CHROOT_PATH/tmp/install-dev-packages.sh"

echo "[+] Development packages pre-installed"

#=============================================================================
# 10d. Pre-install the wireless setup stack, Docker and the CI-Hub tooling
#=============================================================================
echo "[*] Step 10d: Pre-installing wireless setup stack, Docker and CI-Hub tooling..."

# Why this lives in the image and not at first boot: a freshly installed appliance has no network until the
# wireless setup portal has run, so the tools that bring it online, and the Docker engine the Hub runs on,
# have to be there already.
# Stays at first boot on purpose (core/manifest/ecosystem.yaml, ci_hub): the CI-Hub container image itself
# (registry credentials and device pairing), model pulls, and per-user developer tools.

# 1. Build the setup-device package without touching the build host or the repo tree.
SETUP_DEB_DIR="$(mktemp -d)"
if ! SETUP_DEVICE_OUTPUT_DIR="$SETUP_DEB_DIR" \
     SETUP_DEVICE_PKGROOT="$SETUP_DEB_DIR/pkgroot" \
     SETUP_DEVICE_SKIP_BUILD_DEPS=1 \
     "$REPO_ROOT/backends/ubuntu/headless-package/build.sh" > "$SETUP_DEB_DIR/build.log" 2>&1; then
    cat "$SETUP_DEB_DIR/build.log" >&2
    echo "[ERROR] setup-device package build failed" >&2
    exit 1
fi
SETUP_DEB="$(find "$SETUP_DEB_DIR" -maxdepth 1 -name 'setup-device_*.deb' | head -1)"
[[ -f "$SETUP_DEB" ]] || { echo "[ERROR] setup-device .deb was not produced" >&2; exit 1; }
install -m 644 "$SETUP_DEB" "$CHROOT_PATH/tmp/setup-device.deb"
rm -rf "$SETUP_DEB_DIR"

# 2. Install inside the chroot. policy-rc.d keeps maintainer scripts from starting daemons here (the
# setup-device scripts also skip all service management when systemd is not running).
cat > "$CHROOT_PATH/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
chmod 755 "$CHROOT_PATH/usr/sbin/policy-rc.d"

cat > "$CHROOT_PATH/tmp/preinstall-hub-wireless.sh" << 'EOSCRIPT'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
# curl and iw are not in the stock desktop image (26.04.1); ci-hub.sh and the hotspot scripts need them. curl is installed
# here, in this script, before the first line below that runs it (Step 10b installs it too, for the same reason).
apt-get install -y --no-install-recommends curl iw ca-certificates gnupg

# Docker Engine + Compose from Docker's apt repository: the same source as core/manifest/role-map/apt.yaml
# and provision.sh install_docker, so first boot finds Docker already installed and skips it. The signing
# key is pinned by fingerprint.
DOCKER_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
got_fpr="$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '/^fpr:/ {print $10; exit}')"
if [ "$got_fpr" != "$DOCKER_KEY_FPR" ]; then
    echo "Docker apt key fingerprint mismatch (got $got_fpr)" >&2
    exit 1
fi
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Wireless setup stack. The package's Depends (hostapd, dnsmasq, nginx-light, python3-flask, gunicorn,
# network-manager) are pulled in by apt.
apt-get install -y /tmp/setup-device.deb

apt-get clean
rm -rf /var/lib/apt/lists/*
EOSCRIPT
chmod +x "$CHROOT_PATH/tmp/preinstall-hub-wireless.sh"
chroot_exec "/tmp/preinstall-hub-wireless.sh"
rm -f "$CHROOT_PATH/tmp/preinstall-hub-wireless.sh" "$CHROOT_PATH/tmp/setup-device.deb" \
      "$CHROOT_PATH/usr/sbin/policy-rc.d"

# 3. Service layout. The setup-mode units were enabled by the package. The distro dnsmasq.service must stay
# off (it fights systemd-resolved for port 53; only dnsmasq-setup.service should run), Docker is on.
chroot_exec "systemctl disable dnsmasq.service" || true
chroot_exec "systemctl enable docker.service docker.socket containerd.service"

# 3b. Docker for everyone, in every boot mode.
# - Docker is deliberately NOT guarded against live sessions: it must work on the installed system, in the plain
#   ISO live session and in a Companion Stick live boot (the Stick runs the Hub and its models from the live OS).
# - The live user gets the 'docker' group from casper. casper.conf has no USERGROUPS (casper ignores it); the
#   live user's groups come from the debconf question passwd/user-default-groups that user-setup reads from the
#   rootfs, so the group is appended there. (Read in casper 26.04.2: casper-bottom/25adduser sets the passwd/*
#   answers and runs `chroot /root /usr/lib/user-setup/user-setup-apply`.)
# - The user the interactive installer creates cannot be put in 'docker' by the installer (ubuntu-desktop-bootstrap
#   hands `useradd --groups` the list in the snap's users-and-groups file, adm cdrom dip lpadmin plugdev sambashare
#   debian-tor libvirtd users lxd, plus sudo). The one-click installer asks for docker in its autoinstall file
#   (identity.groups, see ci-os-auto-install). For every other install an offline oneshot adds the machine's
#   administrators (members of 'sudo') to 'docker' at boot, before any session starts. `docker` membership is
#   root-equivalent; opt out with: touch /etc/ci-os/no-docker-group
# - In a live session "/" is an overlayfs, which overlay2/containerd cannot use as a data root, so a live-only
#   oneshot bind-mounts /var/lib/docker and /var/lib/containerd from tmpfs (plain ISO) or the Stick's ext4
#   CI-PERSIST volume. Inert on an installed system. See docs/architecture/docker-in-live-sessions.md.
DOCKER_PAYLOAD="$REPO_ROOT/backends/ubuntu/chroot/payload/docker"
install -d -m 0755 "$CHROOT_PATH/usr/lib/ci-os" "$CHROOT_PATH/usr/lib/systemd/system" \
    "$CHROOT_PATH/etc/systemd/system/docker.service.d" "$CHROOT_PATH/etc/systemd/system/containerd.service.d" \
    "$CHROOT_PATH/etc/ci-os"
install -m 0755 "$DOCKER_PAYLOAD/usr/lib/ci-os/ci-os-docker-group"             "$CHROOT_PATH/usr/lib/ci-os/ci-os-docker-group"
install -m 0755 "$DOCKER_PAYLOAD/usr/lib/ci-os/ci-os-live-container-storage"   "$CHROOT_PATH/usr/lib/ci-os/ci-os-live-container-storage"
install -m 0644 "$DOCKER_PAYLOAD/usr/lib/systemd/system/ci-os-docker-group.service"             "$CHROOT_PATH/usr/lib/systemd/system/"
install -m 0644 "$DOCKER_PAYLOAD/usr/lib/systemd/system/ci-os-live-container-storage.service"   "$CHROOT_PATH/usr/lib/systemd/system/"
install -m 0644 "$DOCKER_PAYLOAD/etc/systemd/system/docker.service.d/20-ci-os-live.conf"       "$CHROOT_PATH/etc/systemd/system/docker.service.d/20-ci-os-live.conf"
install -m 0644 "$DOCKER_PAYLOAD/etc/systemd/system/containerd.service.d/20-ci-os-live.conf"   "$CHROOT_PATH/etc/systemd/system/containerd.service.d/20-ci-os-live.conf"
chroot_exec "systemctl enable ci-os-docker-group.service"

cat > "$CHROOT_PATH/tmp/live-user-docker-group.sh" << 'EOSCRIPT'
#!/bin/bash
set -euo pipefail
getent group docker >/dev/null || { echo "docker group missing: docker-ce did not create it" >&2; exit 1; }
cur="$(echo 'get passwd/user-default-groups' | debconf-communicate user-setup | cut -d' ' -f2-)"
[ -n "$cur" ] || { echo "user-setup default group list is empty" >&2; exit 1; }
case " $cur " in *" docker "*) ;; *) cur="$cur docker" ;; esac
echo "user-setup passwd/user-default-groups string $cur" | debconf-set-selections
echo 'get passwd/user-default-groups' | debconf-communicate user-setup | grep -Eq ' docker( |$)'
EOSCRIPT
chmod 755 "$CHROOT_PATH/tmp/live-user-docker-group.sh"
chroot_exec "/tmp/live-user-docker-group.sh"
rm -f "$CHROOT_PATH/tmp/live-user-docker-group.sh"

# 4. Live-session guard. These units belong to an installed appliance: in a live session they must not
# take over Wi-Fi, bind ports 53/80 or run a hotspot. /cdrom/casper/vmlinuz is the live-session test the
# first-boot units already use: casper does not always put boot=casper on the kernel command line, but the
# live medium is always mounted at /cdrom. Docker and containerd are intentionally absent from this list (3b).
for _unit in hostapd-setup.service dnsmasq-setup.service setup-backend.service \
             setup-network-monitor.service nginx.service; do
    mkdir -p "$CHROOT_PATH/etc/systemd/system/${_unit}.d"
    cat > "$CHROOT_PATH/etc/systemd/system/${_unit}.d/10-not-live.conf" << 'EOF'
[Unit]
# Companion OS: wireless setup mode is for the installed appliance, never a live session.
ConditionPathExists=!/cdrom/casper/vmlinuz
EOF
done

# 5. Record what was baked (verify-iso.sh and Step 10e read this file). Step 10e appends to it.
mkdir -p "$CHROOT_PATH/usr/lib/ci-os"
{
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    chroot "$CHROOT_PATH" dpkg-query -W -f='${Package}=${Version}\n' \
        setup-device docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
        hostapd dnsmasq nginx-light gunicorn iw
} > "$CHROOT_PATH/usr/lib/ci-os/baked-hub-tools.txt"

echo "[+] Wireless setup stack, Docker and CI-Hub tooling pre-installed"


#=============================================================================
# 10f. One-click automatic install (live session)
#
# "Install Companion OS (automatic)": a desktop icon, an app-grid entry and (optionally) a boot-menu entry that pick the
# internal disk, ask ONE question that names it and drive the stock installer through its autoinstall path. The helper
# never touches the boot medium and fails closed when it cannot identify it (see its header and
# backends/ubuntu/chroot/tests/test_auto_install.py). It needs only what the desktop image already ships: python3,
# python3-yaml, zenity, curl, openssl. The XDG autostart hook does nothing on an installed system (is_live() is false).
#=============================================================================
echo "[*] Step 10f: Installing the one-click automatic installer..."
LIVE_PAYLOAD="$REPO_ROOT/backends/ubuntu/chroot/payload/live-start"
install -d -m 0755 "$CHROOT_PATH/usr/libexec/ci-os" "$CHROOT_PATH/usr/share/ci-os/live" "$CHROOT_PATH/etc/xdg/autostart"
install -m 0755 "$LIVE_PAYLOAD/usr/libexec/ci-os/ci-os-auto-install"                    "$CHROOT_PATH/usr/libexec/ci-os/ci-os-auto-install"
install -m 0644 "$LIVE_PAYLOAD/usr/share/ci-os/live/ci-os-auto-install.desktop"         "$CHROOT_PATH/usr/share/ci-os/live/ci-os-auto-install.desktop"
install -m 0644 "$LIVE_PAYLOAD/etc/xdg/autostart/ci-os-live-setup.desktop"              "$CHROOT_PATH/etc/xdg/autostart/ci-os-live-setup.desktop"
for _tool in zenity curl openssl lsblk findmnt; do
    chroot_exec "command -v $_tool >/dev/null" || { echo "[ERROR] Step 10f: $_tool is missing from the image; the automatic installer needs it" >&2; exit 1; }
done
chroot_exec "python3 -c 'import yaml'" || { echo "[ERROR] Step 10f: python3-yaml is missing from the image" >&2; exit 1; }
chroot_exec "python3 -m py_compile /usr/libexec/ci-os/ci-os-auto-install && rm -rf /usr/libexec/ci-os/__pycache__"
echo "[+] One-click automatic installer installed"


#=============================================================================
# 10e. Pre-install the optional ("Tier B") tools: tailscale, cloudflared, gh, Ollama, Companion Launcher
#
# Runs after Step 10d (Docker, wireless stack; /usr/lib/ci-os/baked-hub-tools.txt exists).
# Knobs (all default ON; 0 disables):
#   CI_OS_BAKE_THIRD_PARTY  tailscale + cloudflared + gh from the vendors' apt repositories
#   CI_OS_BAKE_OLLAMA       Ollama from the vendor's release tarball (never install.sh)
#   CI_OS_BAKE_LAUNCHER     Companion Launcher (.deb from dl.ci.computer)
#   CI_OS_BAKE_CAPTURE      Companion Capture (.deb from a private GitHub release: the build cache, else `gh release download`)
#   CI_OS_OLLAMA_CUDA       all (default) | none   - "none" drops cuda_v12 + cuda_v13 (about 2.0 GiB installed)
#   CI_OS_LAUNCHER_AUTOSTART  0 (default) | 1      - XDG autostart of the Launcher on the installed system
#   CI_OS_TIERB_PINS        path of the pins file (default core/manifest/tier-b-pins.env)
#   CI_OS_CACHE_DIR         download cache for the Ollama tarball (default ~/.cache/ci-os)
# Fails closed: any key-fingerprint or sha256 mismatch aborts the build. Everything is downloaded and verified
# on the build host BEFORE the chroot is touched. Nothing is started in the chroot, and every service that would
# run is guarded against live sessions.
#=============================================================================
echo "[*] Step 10e: Pre-installing optional tools (Tier B)..."

CI_OS_BAKE_THIRD_PARTY="${CI_OS_BAKE_THIRD_PARTY:-1}"
CI_OS_BAKE_OLLAMA="${CI_OS_BAKE_OLLAMA:-1}"
CI_OS_BAKE_LAUNCHER="${CI_OS_BAKE_LAUNCHER:-1}"
CI_OS_BAKE_CAPTURE="${CI_OS_BAKE_CAPTURE:-1}"
CI_OS_OLLAMA_CUDA="${CI_OS_OLLAMA_CUDA:-all}"
CI_OS_LAUNCHER_AUTOSTART="${CI_OS_LAUNCHER_AUTOSTART:-0}"
TIERB_PINS="${CI_OS_TIERB_PINS:-$REPO_ROOT/core/manifest/tier-b-pins.env}"

tb_die() { echo "[ERROR] Step 10e: $*" >&2; exit 1; }
for _k in CI_OS_BAKE_THIRD_PARTY CI_OS_BAKE_OLLAMA CI_OS_BAKE_LAUNCHER CI_OS_BAKE_CAPTURE CI_OS_LAUNCHER_AUTOSTART; do
    case "${!_k}" in 0|1) ;; *) tb_die "$_k must be 0 or 1 (got '${!_k}')" ;; esac
done
case "$CI_OS_OLLAMA_CUDA" in all|none) ;; *) tb_die "CI_OS_OLLAMA_CUDA must be all or none (got '$CI_OS_OLLAMA_CUDA')" ;; esac

if [[ "$CI_OS_BAKE_THIRD_PARTY$CI_OS_BAKE_OLLAMA$CI_OS_BAKE_LAUNCHER$CI_OS_BAKE_CAPTURE" == "0000" ]]; then
    echo "[+] Step 10e: all Tier B knobs are 0, nothing to do"
else
    [[ -f "$TIERB_PINS" ]] || tb_die "pins file not found: $TIERB_PINS"
    # shellcheck source=../../../core/manifest/tier-b-pins.env
    source "$TIERB_PINS"

    for _t in curl gpg sha256sum tar zstd awk dpkg-deb install mktemp; do
        command -v "$_t" >/dev/null 2>&1 || tb_die "build host is missing '$_t'"
    done
    [[ -f "$CHROOT_PATH/usr/lib/ci-os/baked-hub-tools.txt" ]] || tb_die "Step 10d has not run (no baked-hub-tools.txt)"

    TB_WORK="$(mktemp -d)"
    TB_GNUPGHOME="$TB_WORK/gnupg"; install -d -m 700 "$TB_GNUPGHOME"      # throwaway: never the host's keyring
    TB_CACHE="${CI_OS_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/ci-os}"; install -d -m 755 "$TB_CACHE"
    TB_POLICY_RC="$CHROOT_PATH/usr/sbin/policy-rc.d"

    # policy-rc.d (exit 101) stops maintainer scripts from starting anything; always restored, even on failure.
    tb_policy_on() {
        [[ -e "$TB_POLICY_RC" && ! -e "$TB_POLICY_RC.ci-os-orig" ]] && mv "$TB_POLICY_RC" "$TB_POLICY_RC.ci-os-orig"
        printf '#!/bin/sh\nexit 101\n' > "$TB_POLICY_RC"; chmod 755 "$TB_POLICY_RC"
    }
    tb_policy_off() {
        rm -f "$TB_POLICY_RC"
        [[ -e "$TB_POLICY_RC.ci-os-orig" ]] && mv "$TB_POLICY_RC.ci-os-orig" "$TB_POLICY_RC"
        return 0
    }
    tb_cleanup() { tb_policy_off; rm -rf "$TB_WORK"; ci_brand_cleanup; }
    trap tb_cleanup EXIT

    tb_fetch() {   # URL DEST
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 3600 \
            -o "$2" "$1" || tb_die "download failed: $1"
    }
    tb_sha256_of() { sha256sum "$1" | awk '{print $1}'; }
    tb_size_of() { wc -c < "$1" | tr -d '[:space:]'; }
    tb_expect_sha256() {   # FILE WANT_SHA256 LABEL
        local got; got="$(tb_sha256_of "$1")"
        [[ "$got" == "$2" ]] || tb_die "$3: sha256 mismatch (got $got, pinned $2)"
    }
    # Primary-key fingerprints of a key file, one per line (sub-key fingerprints are not listed).
    tb_primary_fprs() {
        GNUPGHOME="$TB_GNUPGHOME" gpg --batch --no-tty --show-keys --with-colons "$1" 2>/dev/null |
            awk -F: '$1=="pub"{w=1; next} $1=="sub"||$1=="sec"||$1=="ssb"{w=0} $1=="fpr"&&w{print $10; w=0}'
    }
    # tb_check_key FILE REQUIRED_FPR [TOLERATED_FPR...]: REQUIRED must be present; any other primary key must be tolerated.
    tb_check_key() {
        local file="$1" required="$2" got fpr extra ok; shift 2
        if head -c 10 "$file" | grep -q -- '-----BEGIN'; then tb_die "$file is ASCII-armored; apt needs a binary keyring"; fi
        got="$(tb_primary_fprs "$file")"
        [[ -n "$got" ]] || tb_die "no OpenPGP key in $file"
        grep -qx "$required" <<<"$got" || tb_die "$file does not contain the pinned key $required (found: $(tr '\n' ' ' <<<"$got"))"
        while IFS= read -r fpr; do
            ok=0; [[ "$fpr" == "$required" ]] && ok=1
            for extra in "$@"; do [[ "$fpr" == "$extra" ]] && ok=1; done
            [[ $ok -eq 1 ]] || tb_die "$file contains an unpinned key $fpr"
        done <<<"$got"
    }

    TB_CODENAME="$(chroot "$CHROOT_PATH" /bin/bash -c '. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}"')"
    [[ "$TB_CODENAME" =~ ^[a-z]+$ ]] || tb_die "cannot determine the Ubuntu codename of the image (got '$TB_CODENAME')"

    #---- 1. Download and verify everything first (the chroot is untouched until all of this has passed) ---------------
    TB_APT_PKGS=""
    if [[ "$CI_OS_BAKE_THIRD_PARTY" == 1 ]]; then
        tb_fetch "https://pkgs.tailscale.com/stable/ubuntu/${TB_CODENAME}.noarmor.gpg" "$TB_WORK/tailscale.gpg"
        tb_check_key "$TB_WORK/tailscale.gpg" "$TAILSCALE_KEY_FPR"

        tb_fetch "https://pkg.cloudflare.com/cloudflare-main.gpg" "$TB_WORK/cloudflare-main.gpg"
        tb_check_key "$TB_WORK/cloudflare-main.gpg" "$CLOUDFLARED_KEY_FPR"

        # GitHub's keyring carries an expired key (2C61...) next to the live one (7F38...). Keep only the live key.
        tb_fetch "https://cli.github.com/packages/githubcli-archive-keyring.gpg" "$TB_WORK/gh-vendor.gpg"
        tb_check_key "$TB_WORK/gh-vendor.gpg" "$GH_KEY_FPR" "$GH_KEY_FPR_EXPIRED"
        GNUPGHOME="$TB_GNUPGHOME" gpg --batch --no-tty --quiet --import "$TB_WORK/gh-vendor.gpg" 2>/dev/null || true
        GNUPGHOME="$TB_GNUPGHOME" gpg --batch --no-tty --export --export-options export-minimal "$GH_KEY_FPR" > "$TB_WORK/gh.gpg"
        tb_check_key "$TB_WORK/gh.gpg" "$GH_KEY_FPR"
        [[ "$(tb_primary_fprs "$TB_WORK/gh.gpg" | wc -l | tr -d '[:space:]')" == 1 ]] || tb_die "gh keyring must hold exactly one key"
        TB_APT_PKGS="tailscale cloudflared gh"
    fi

    TB_LAUNCHER_DEB=""
    if [[ "$CI_OS_BAKE_LAUNCHER" == 1 ]]; then
        TB_LAUNCHER_DEB="$TB_CACHE/${LAUNCHER_PACKAGE}_${LAUNCHER_VERSION}_amd64.deb"
        if [[ ! -f "$TB_LAUNCHER_DEB" ]] || [[ "$(tb_sha256_of "$TB_LAUNCHER_DEB")" != "$LAUNCHER_SHA256" ]]; then
            tb_fetch "$LAUNCHER_URL" "$TB_LAUNCHER_DEB.part"; mv "$TB_LAUNCHER_DEB.part" "$TB_LAUNCHER_DEB"
        fi
        tb_expect_sha256 "$TB_LAUNCHER_DEB" "$LAUNCHER_SHA256" "Companion Launcher .deb"
        [[ "$(tb_size_of "$TB_LAUNCHER_DEB")" == "$LAUNCHER_SIZE" ]] || tb_die "Companion Launcher .deb size differs from the pin"
        [[ "$(dpkg-deb -f "$TB_LAUNCHER_DEB" Package)" == "$LAUNCHER_PACKAGE" ]] || tb_die "unexpected package name in the Launcher .deb"
        [[ "$(dpkg-deb -f "$TB_LAUNCHER_DEB" Version)" == "$LAUNCHER_VERSION" ]] || tb_die "unexpected version in the Launcher .deb"
        [[ "$(dpkg-deb -f "$TB_LAUNCHER_DEB" Architecture)" == "amd64" ]] || tb_die "Launcher .deb is not amd64"
        # Member names only (perms owner size date time NAME [-> target]); written to a file so no pipe is closed early.
        dpkg-deb -c "$TB_LAUNCHER_DEB" | sed -E -e 's/^[^ ]+ +[^ ]+ +[0-9]+ +[0-9-]+ +[0-9:]+ +//' -e 's/ -> .*$//' > "$TB_WORK/launcher.members"
        grep -qx './usr/bin/companion-hub' "$TB_WORK/launcher.members" || tb_die "Launcher .deb has no /usr/bin/companion-hub"
        # A launcher must not bring its own system services, cron jobs or sudo rules.
        if grep -E '^\./(etc/|lib/systemd|usr/lib/systemd)' "$TB_WORK/launcher.members" | grep -q .; then
            tb_die "Launcher .deb ships files under /etc or systemd; review before baking"
        fi
    fi

    TB_CAPTURE_DEB=""
    if [[ "$CI_OS_BAKE_CAPTURE" == 1 ]]; then
        TB_CAPTURE_DEB="$TB_CACHE/${CAPTURE_PACKAGE}_${CAPTURE_VERSION}_amd64.deb"
        if [[ ! -f "$TB_CAPTURE_DEB" ]] || [[ "$(tb_sha256_of "$TB_CAPTURE_DEB")" != "$CAPTURE_SHA256" ]]; then
            # The release lives in a private repository, so only the builder's own GitHub credentials can fetch it.
            command -v gh >/dev/null 2>&1 || tb_die "Companion Capture .deb is not in the cache and gh is not installed on this build host. Put $CAPTURE_ASSET (sha256 $CAPTURE_SHA256) at $TB_CAPTURE_DEB, or install gh and sign in (gh auth login, or GH_TOKEN with read access to $CAPTURE_REPO), or build with CI_OS_BAKE_CAPTURE=0"
            install -d -m 700 "$TB_WORK/capture-dl"
            GH_PROMPT_DISABLED=1 gh release download "$CAPTURE_TAG" --repo "$CAPTURE_REPO" --pattern "$CAPTURE_ASSET" --dir "$TB_WORK/capture-dl" \
                || tb_die "gh release download of $CAPTURE_ASSET ($CAPTURE_REPO $CAPTURE_TAG) failed: sign in (gh auth login, or GH_TOKEN with read access to the repository), or put the file at $TB_CAPTURE_DEB"
            [[ -f "$TB_WORK/capture-dl/$CAPTURE_ASSET" ]] || tb_die "gh did not produce $CAPTURE_ASSET"
            mv "$TB_WORK/capture-dl/$CAPTURE_ASSET" "$TB_CAPTURE_DEB.part"; mv "$TB_CAPTURE_DEB.part" "$TB_CAPTURE_DEB"
        fi
        tb_expect_sha256 "$TB_CAPTURE_DEB" "$CAPTURE_SHA256" "Companion Capture .deb"
        [[ "$(tb_size_of "$TB_CAPTURE_DEB")" == "$CAPTURE_SIZE" ]] || tb_die "Companion Capture .deb size differs from the pin"
        [[ "$(dpkg-deb -f "$TB_CAPTURE_DEB" Package)" == "$CAPTURE_PACKAGE" ]] || tb_die "unexpected package name in the Capture .deb"
        [[ "$(dpkg-deb -f "$TB_CAPTURE_DEB" Version)" == "$CAPTURE_VERSION" ]] || tb_die "unexpected version in the Capture .deb"
        [[ "$(dpkg-deb -f "$TB_CAPTURE_DEB" Architecture)" == "amd64" ]] || tb_die "Capture .deb is not amd64"
        dpkg-deb -c "$TB_CAPTURE_DEB" | sed -E -e 's/^[^ ]+ +[^ ]+ +[0-9]+ +[0-9-]+ +[0-9:]+ +//' -e 's/ -> .*$//' > "$TB_WORK/capture.members"
        grep -qx "./usr/bin/$CAPTURE_BINARY" "$TB_WORK/capture.members" || tb_die "Capture .deb has no /usr/bin/$CAPTURE_BINARY"
        grep -qx './usr/share/applications/companion-capture.desktop' "$TB_WORK/capture.members" || tb_die "Capture .deb has no companion-capture.desktop (the dock entry needs it)"
        # Capture records the screen: it must not start by itself, bring services, cron jobs or sudo rules, or autostart.
        if grep -E '^\./(etc/|lib/systemd|usr/lib/systemd)' "$TB_WORK/capture.members" | grep -q .; then
            tb_die "Capture .deb ships files under /etc or systemd (an autostart or a service?); review before baking"
        fi
    fi

    TB_OLLAMA_TAR=""
    if [[ "$CI_OS_BAKE_OLLAMA" == 1 ]]; then
        TB_OLLAMA_TAR="$TB_CACHE/ollama-linux-amd64-${OLLAMA_VERSION}.tar.zst"
        if [[ ! -f "$TB_OLLAMA_TAR" ]] || [[ "$(tb_size_of "$TB_OLLAMA_TAR")" != "$OLLAMA_SIZE" ]] || [[ "$(tb_sha256_of "$TB_OLLAMA_TAR")" != "$OLLAMA_SHA256" ]]; then
            tb_fetch "$OLLAMA_URL" "$TB_OLLAMA_TAR.part"; mv "$TB_OLLAMA_TAR.part" "$TB_OLLAMA_TAR"
        fi
        tb_expect_sha256 "$TB_OLLAMA_TAR" "$OLLAMA_SHA256" "Ollama tarball"
        # The tarball is root-owned and extracted as root: refuse anything but bin/ollama and lib/ollama/**.
        zstd -dc "$TB_OLLAMA_TAR" | tar -t > "$TB_WORK/ollama.members"
        grep -q . "$TB_WORK/ollama.members" || tb_die "Ollama tarball is empty"
        if grep -E '(^|/)\.{1,2}(/|$)' "$TB_WORK/ollama.members" | grep -q .; then tb_die "Ollama tarball has a '.' or '..' path component"; fi
        if grep -v -E '^(bin/ollama|lib/ollama(/[A-Za-z0-9._+-]+)*/?)$' "$TB_WORK/ollama.members" | grep -q .; then
            tb_die "Ollama tarball has unexpected members: $(grep -v -E '^(bin/ollama|lib/ollama(/[A-Za-z0-9._+-]+)*/?)$' "$TB_WORK/ollama.members" | head -3 | tr '\n' ' ')"
        fi
        grep -qx 'bin/ollama' "$TB_WORK/ollama.members" || tb_die "Ollama tarball has no bin/ollama"
        zstd -dc "$TB_OLLAMA_TAR" | tar -tv > "$TB_WORK/ollama.tv"
        awk '$1 !~ /^[-dl]/' "$TB_WORK/ollama.tv" > "$TB_WORK/ollama.odd"
        [[ ! -s "$TB_WORK/ollama.odd" ]] || tb_die "Ollama tarball has members that are not files, directories or symlinks"
        awk '$1 ~ /^l/ {print $NF}' "$TB_WORK/ollama.tv" > "$TB_WORK/ollama.links"
        if grep -E '^/|\.\.' "$TB_WORK/ollama.links" | grep -q .; then tb_die "Ollama tarball has an absolute or escaping symlink"; fi
    fi

    #---- 2. Mutate the chroot: apt sources, Ollama files and units, the Launcher autostart -------------------------------
    if [[ "$CI_OS_BAKE_THIRD_PARTY" == 1 ]]; then
        install -d -m 0755 "$CHROOT_PATH/usr/share/keyrings" "$CHROOT_PATH/etc/apt/sources.list.d"
        # File names and key paths are the vendors' own, so a later run of their install instructions (or provision.sh)
        # rewrites the same files instead of adding a second source with a different Signed-By (apt would then exit 100).
        install -m 0644 "$TB_WORK/tailscale.gpg"        "$CHROOT_PATH/usr/share/keyrings/tailscale-archive-keyring.gpg"
        install -m 0644 "$TB_WORK/cloudflare-main.gpg"  "$CHROOT_PATH/usr/share/keyrings/cloudflare-main.gpg"
        install -m 0644 "$TB_WORK/gh.gpg"               "$CHROOT_PATH/usr/share/keyrings/githubcli-archive-keyring.gpg"
        printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu %s main\n' \
            "$TB_CODENAME" > "$CHROOT_PATH/etc/apt/sources.list.d/tailscale.list"
        printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' \
            > "$CHROOT_PATH/etc/apt/sources.list.d/cloudflared.list"
        printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
            > "$CHROOT_PATH/etc/apt/sources.list.d/github-cli.list"
        chmod 0644 "$CHROOT_PATH"/etc/apt/sources.list.d/{tailscale,cloudflared,github-cli}.list

        # tailscaled is enabled by the package's postinst; keep it out of live sessions. cloudflared and gh ship no unit.
        install -d -m 0755 "$CHROOT_PATH/etc/systemd/system/tailscaled.service.d"
        cat > "$CHROOT_PATH/etc/systemd/system/tailscaled.service.d/10-not-live.conf" << 'EOF'
[Unit]
# Companion OS: tailscaled belongs to the installed appliance, never to a casper live session (ISO or Companion Stick).
# The stock Ubuntu ISO does not put boot=casper on the command line (26.04.1), so also test for the live medium at /cdrom.
ConditionPathExists=!/cdrom/casper/vmlinuz
ConditionKernelCommandLine=!boot=casper
EOF
    fi

    if [[ "$CI_OS_BAKE_OLLAMA" == 1 ]]; then
        # Same as `curl .../ollama-linux-amd64.tar.zst | sudo tar x -C /usr` in the vendor's manual-install docs.
        rm -rf "$CHROOT_PATH/usr/lib/ollama"
        zstd -dc "$TB_OLLAMA_TAR" | tar -x --no-same-owner -C "$CHROOT_PATH/usr"
        [[ "$CI_OS_OLLAMA_CUDA" == none ]] && rm -rf "$CHROOT_PATH/usr/lib/ollama/cuda_v12" "$CHROOT_PATH/usr/lib/ollama/cuda_v13"
        [[ -x "$CHROOT_PATH/usr/bin/ollama" ]] || tb_die "usr/bin/ollama missing after extraction"
        [[ "$(head -c4 "$CHROOT_PATH/usr/bin/ollama" | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] || tb_die "usr/bin/ollama is not an ELF binary"
        [[ -e "$CHROOT_PATH/usr/lib/ollama/libggml-base.so.0" ]] || tb_die "usr/lib/ollama/libggml-base.so.0 missing after extraction"

        install -d -m 0755 "$CHROOT_PATH/usr/libexec/ci-os" "$CHROOT_PATH/etc/ci-os"
        install -m 0755 "$REPO_ROOT/backends/ubuntu/chroot/payload/ci-os-ollama-models-env.sh" \
            "$CHROOT_PATH/usr/libexec/ci-os/ollama-models-env"

        # Based on the vendor's unit (docs/linux: User=ollama, ExecStart=/usr/bin/ollama serve, Restart=always).
        # Added: a runtime directory for the models-dir selection, and the live-session guard in a drop-in.
        cat > "$CHROOT_PATH/etc/systemd/system/ollama.service" << 'EOF'
[Unit]
Description=Ollama Service
Documentation=https://docs.ollama.com/linux
After=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Companion Stick: put models on the CI-CACHE volume when it is attached, else keep the default directory.
RuntimeDirectory=ollama
RuntimeDirectoryMode=0755
ExecStartPre=-+/usr/libexec/ci-os/ollama-models-env
ExecStopPost=-+/usr/libexec/ci-os/ollama-models-env release
EnvironmentFile=-/run/ollama/ci-models.env

[Install]
WantedBy=multi-user.target
EOF
        install -d -m 0755 "$CHROOT_PATH/etc/systemd/system/ollama.service.d"
        cat > "$CHROOT_PATH/etc/systemd/system/ollama.service.d/10-not-live.conf" << 'EOF'
[Unit]
# Companion OS: Ollama runs on the installed appliance, never in a casper live session (ISO or Companion Stick).
ConditionPathExists=!/cdrom/casper/vmlinuz
ConditionKernelCommandLine=!boot=casper
EOF
    fi

    if [[ "$CI_OS_BAKE_LAUNCHER" == 1 && "$CI_OS_LAUNCHER_AUTOSTART" == 1 ]]; then
        install -d -m 0755 "$CHROOT_PATH/usr/libexec/ci-os" "$CHROOT_PATH/etc/xdg/autostart"
        cat > "$CHROOT_PATH/usr/libexec/ci-os/launcher-autostart" << 'EOF'
#!/bin/sh
# Start the Companion Launcher at graphical login on the installed system only, never in a live session.
[ -e /cdrom/casper/vmlinuz ] && exit 0
exec /usr/bin/companion-hub "$@"
EOF
        chmod 0755 "$CHROOT_PATH/usr/libexec/ci-os/launcher-autostart"
        cat > "$CHROOT_PATH/etc/xdg/autostart/companion-launcher.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Companion Launcher
Comment=Start Companion Launcher
Exec=/usr/libexec/ci-os/launcher-autostart
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    fi

    #---- 3. Install inside the chroot. The chroot is NOT booted: nothing may start, stop or signal anything. ----------------
    if [[ -n "$TB_LAUNCHER_DEB" ]]; then install -m 0644 "$TB_LAUNCHER_DEB" "$CHROOT_PATH/tmp/companion-hub.deb"; fi
    if [[ -n "$TB_CAPTURE_DEB" ]]; then install -m 0644 "$TB_CAPTURE_DEB" "$CHROOT_PATH/tmp/companion-capture.deb"; fi
    cat > "$CHROOT_PATH/tmp/preinstall-tier-b.sh" << 'EOSCRIPT'
#!/bin/bash
# usage: preinstall-tier-b.sh "<apt packages or empty>" <launcher 0|1> <ollama 0|1> <capture 0|1>
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
export SYSTEMD_OFFLINE=1        # systemctl enable/disable act on symlinks only; start/stop/daemon-reload are no-ops
export CI_OS_IMAGE_BUILD=1
apt_pkgs="$1"; launcher="$2"; ollama="$3"; capture="$4"

if [ -n "$apt_pkgs" ]; then
    apt-get update --error-on=any
    declare -A origin=([tailscale]=pkgs.tailscale.com [cloudflared]=pkg.cloudflare.com [gh]=cli.github.com)
    for p in $apt_pkgs; do
        # The newest version of each package must come from its vendor repository (Ubuntu's archive carries an old gh).
        top="$(apt-cache madison "$p" | sed -n 1p)"
        case "$top" in *"${origin[$p]}"*) ;; *) echo "[ERROR] newest '$p' is not from ${origin[$p]}: ${top:-none}" >&2; exit 1 ;; esac
    done
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends $apt_pkgs
fi

if [ "$launcher" = 1 ]; then
    apt-get install -y --no-install-recommends /tmp/companion-hub.deb
fi

if [ "$capture" = 1 ]; then
    # Its dependencies (libgtk-3-0, libayatana-appindicator3-1, libxdo3, libxcb1) come from the Ubuntu archive.
    apt-get install -y --no-install-recommends /tmp/companion-capture.deb
fi

if [ "$ollama" = 1 ]; then
    # What the vendor's install.sh configure_systemd() does, without running install.sh (it needs a booted system and
    # would install NVIDIA/ROCm drivers from the network).
    getent group ollama >/dev/null || groupadd --system ollama
    id ollama >/dev/null 2>&1 || useradd --system --gid ollama --shell /bin/false --create-home --home-dir /usr/share/ollama ollama
    for g in render video; do
        if getent group "$g" >/dev/null; then usermod -a -G "$g" ollama; fi
    done
    systemctl enable ollama.service
fi

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/companion-hub.deb /tmp/companion-capture.deb
EOSCRIPT
    chmod +x "$CHROOT_PATH/tmp/preinstall-tier-b.sh"
    tb_policy_on
    chroot "$CHROOT_PATH" /tmp/preinstall-tier-b.sh "$TB_APT_PKGS" "$CI_OS_BAKE_LAUNCHER" "$CI_OS_BAKE_OLLAMA" "$CI_OS_BAKE_CAPTURE"
    tb_policy_off
    rm -f "$CHROOT_PATH/tmp/preinstall-tier-b.sh"

    #---- 4. Assert the result (host-side, so a broken chroot cannot lie) --------------------------------------------------
    for _r in /proc/[0-9]*/root; do
        [[ "$(readlink "$_r" 2>/dev/null)" == "$CHROOT_PATH" ]] && tb_die "process still rooted in the chroot: $_r"
    done
    tb_pkg_ok() { [[ "$(chroot "$CHROOT_PATH" dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]] || tb_die "package $1 is not installed"; }
    tb_enabled() { [[ -L "$CHROOT_PATH/etc/systemd/system/multi-user.target.wants/$1" ]] || tb_die "$1 is not enabled"; }
    tb_guard() { grep -q '^ConditionPathExists=!/cdrom/casper/vmlinuz' "$CHROOT_PATH/etc/systemd/system/$1.d/10-not-live.conf" 2>/dev/null || tb_die "$1 has no live-session guard"; }

    if [[ "$CI_OS_BAKE_THIRD_PARTY" == 1 ]]; then
        for _p in tailscale cloudflared gh; do tb_pkg_ok "$_p"; done
        tb_enabled tailscaled.service; tb_guard tailscaled.service
        [[ ! -e "$CHROOT_PATH/var/lib/tailscale/tailscaled.state" ]] || tb_die "tailscaled ran in the chroot (state file exists)"
        if compgen -G "$CHROOT_PATH/usr/lib/systemd/system/cloudflared*.service" >/dev/null || compgen -G "$CHROOT_PATH/etc/systemd/system/cloudflared*.service" >/dev/null; then
            tb_die "a cloudflared unit appeared; decide whether it must be guarded"
        fi
        for _f in usr/sbin/tailscaled usr/bin/tailscale usr/bin/cloudflared usr/bin/gh; do [[ -x "$CHROOT_PATH/$_f" ]] || tb_die "missing $_f"; done
    fi
    if [[ "$CI_OS_BAKE_LAUNCHER" == 1 ]]; then
        tb_pkg_ok "$LAUNCHER_PACKAGE"
        [[ -x "$CHROOT_PATH/usr/bin/$LAUNCHER_BINARY" ]] || tb_die "missing /usr/bin/$LAUNCHER_BINARY"
        chroot "$CHROOT_PATH" test -x /usr/bin/cihub || tb_die "/usr/bin/cihub symlink missing or dangling"
    fi
    if [[ "$CI_OS_BAKE_CAPTURE" == 1 ]]; then
        tb_pkg_ok "$CAPTURE_PACKAGE"
        [[ -x "$CHROOT_PATH/usr/bin/$CAPTURE_BINARY" ]] || tb_die "missing /usr/bin/$CAPTURE_BINARY"
        grep -q "^Exec=/usr/bin/$CAPTURE_BINARY\b\|^Exec=$CAPTURE_BINARY\b" "$CHROOT_PATH/usr/share/applications/companion-capture.desktop" \
            || tb_die "companion-capture.desktop does not start /usr/bin/$CAPTURE_BINARY"
        # Capture records the screen: nothing may start it for the user, in a live session or on an installed system.
        [[ ! -e "$CHROOT_PATH/etc/xdg/autostart/companion-capture.desktop" ]] || tb_die "Capture has an XDG autostart entry; it must not start by itself"
        if compgen -G "$CHROOT_PATH/usr/lib/systemd/system/companion-capture*.service" >/dev/null || compgen -G "$CHROOT_PATH/etc/systemd/system/companion-capture*.service" >/dev/null; then
            tb_die "a companion-capture unit appeared; Capture must not run as a service"
        fi
    fi
    if [[ "$CI_OS_BAKE_OLLAMA" == 1 ]]; then
        chroot "$CHROOT_PATH" getent passwd ollama >/dev/null || tb_die "ollama user missing"
        [[ "$(chroot "$CHROOT_PATH" id -u ollama)" -lt 1000 ]] || tb_die "ollama must be a system user (uid < 1000)"
        tb_enabled ollama.service; tb_guard ollama.service
        [[ ! -e "$CHROOT_PATH/usr/share/ollama/.ollama" ]] || tb_die "model data exists in the image"
        # Soft: --version must not start a server, but a failure to run an x86-64 binary on an exotic build host is not fatal.
        timeout 30 chroot "$CHROOT_PATH" /usr/bin/ollama --version 2>&1 | head -n 3 || true
    fi

    #---- 5. Record what was baked ---------------------------------------------------------------------------------------------
    {
        echo "tierb-pins-reviewed=$TIERB_PINS_REVIEWED"
        echo "bake-third-party=$CI_OS_BAKE_THIRD_PARTY"
        echo "bake-ollama=$CI_OS_BAKE_OLLAMA"
        echo "bake-launcher=$CI_OS_BAKE_LAUNCHER"
        echo "bake-capture=$CI_OS_BAKE_CAPTURE"
        [[ "$CI_OS_BAKE_THIRD_PARTY" == 1 ]] && chroot "$CHROOT_PATH" dpkg-query -W -f='${Package}=${Version}\n' tailscale cloudflared gh
        [[ "$CI_OS_BAKE_LAUNCHER" == 1 ]]    && chroot "$CHROOT_PATH" dpkg-query -W -f='${Package}=${Version}\n' "$LAUNCHER_PACKAGE"
        [[ "$CI_OS_BAKE_CAPTURE" == 1 ]]     && chroot "$CHROOT_PATH" dpkg-query -W -f='${Package}=${Version}\n' "$CAPTURE_PACKAGE"
        if [[ "$CI_OS_BAKE_OLLAMA" == 1 ]]; then
            echo "ollama=$OLLAMA_VERSION"
            echo "ollama-tarball-sha256=$OLLAMA_SHA256"
            echo "ollama-bin-sha256=$(tb_sha256_of "$CHROOT_PATH/usr/bin/ollama")"
            echo "ollama-cuda=$CI_OS_OLLAMA_CUDA"
        fi
    } >> "$CHROOT_PATH/usr/lib/ci-os/baked-hub-tools.txt"

    tb_cleanup; trap ci_brand_cleanup EXIT
    echo "[+] Step 10e: optional tools pre-installed (third-party=$CI_OS_BAKE_THIRD_PARTY ollama=$CI_OS_BAKE_OLLAMA launcher=$CI_OS_BAKE_LAUNCHER capture=$CI_OS_BAKE_CAPTURE)"
fi

#=============================================================================
# 10c. Include Bootstrap Scripts & First-Boot Setup Service
#=============================================================================
echo "[*] Step 10c: Setting up first-boot bootstrap service..."

# ── Copy provision.sh + its dependencies into the image ──────────────────────
# Staged under /usr/lib/ci-os/bootstrap/, preserving the real repo's relative
# layout (backends/ubuntu/{provision,lib}/, core/lib/, core/manifest/) so
# provision.sh's own REPO_ROOT-relative sourcing resolves unmodified on the
# installed system — the same staging approach Step 5 (Plymouth) uses.
mkdir -p "$CHROOT_PATH/usr/lib/ci-os/bootstrap/backends/ubuntu/provision"
mkdir -p "$CHROOT_PATH/usr/lib/ci-os/bootstrap/backends/ubuntu/lib"
mkdir -p "$CHROOT_PATH/usr/lib/ci-os/bootstrap/core/lib"
mkdir -p "$CHROOT_PATH/usr/lib/ci-os/bootstrap/core/manifest/role-map"
mkdir -p "$CHROOT_PATH/usr/lib/ci-os/bootstrap/vendor/brand/tokens"

if [[ -f "$REPO_ROOT/backends/ubuntu/provision/provision.sh" ]]; then
    install -m 755 "$REPO_ROOT/backends/ubuntu/provision/provision.sh" \
        "$CHROOT_PATH/usr/lib/ci-os/bootstrap/backends/ubuntu/provision/provision.sh"
    echo "[+] Copied provision.sh"
fi

# install-models.sh: called standalone by ci-os-post-validation.sh (the
# headless flow's post-pairing catch-up step) — idempotent, safe to re-run
# even though provision.sh --tier=core already pulls models at first boot.
if [[ -f "$REPO_ROOT/backends/ubuntu/provision/install-models.sh" ]]; then
    install -m 755 "$REPO_ROOT/backends/ubuntu/provision/install-models.sh" \
        "$CHROOT_PATH/usr/lib/ci-os/bootstrap/backends/ubuntu/provision/install-models.sh"
    echo "[+] Copied install-models.sh"
fi

for lib_script in "$REPO_ROOT/backends/ubuntu/lib/"*.sh; do
    if [[ -f "$lib_script" ]]; then
        install -m 755 "$lib_script" \
            "$CHROOT_PATH/usr/lib/ci-os/bootstrap/backends/ubuntu/lib/$(basename "$lib_script")"
    fi
done
echo "[+] Copied backends/ubuntu/lib/*.sh"

for core_lib in "$REPO_ROOT/core/lib/"*.sh; do
    if [[ -f "$core_lib" ]]; then
        install -m 755 "$core_lib" \
            "$CHROOT_PATH/usr/lib/ci-os/bootstrap/core/lib/$(basename "$core_lib")"
    fi
done
echo "[+] Copied core/lib/*.sh (including ci-hub.sh)"

if [[ -f "$REPO_ROOT/core/manifest/ecosystem.yaml" ]]; then
    install -m 644 "$REPO_ROOT/core/manifest/ecosystem.yaml" \
        "$CHROOT_PATH/usr/lib/ci-os/bootstrap/core/manifest/ecosystem.yaml"
    install -m 644 "$REPO_ROOT/core/manifest/role-map/apt.yaml" \
        "$CHROOT_PATH/usr/lib/ci-os/bootstrap/core/manifest/role-map/apt.yaml"
fi

# vendor/brand/tokens/tokens.sh is a dependency of core/lib/theme-lib.sh
# (sourced by core/lib/vendor-brand.sh's neighbors, and harmless to have
# present even though provision.sh itself doesn't need brand tokens).
if [[ -f "$REPO_ROOT/vendor/brand/tokens/tokens.sh" ]]; then
    install -m 644 "$REPO_ROOT/vendor/brand/tokens/tokens.sh" \
        "$CHROOT_PATH/usr/lib/ci-os/bootstrap/vendor/brand/tokens/tokens.sh"
fi

# ── Create the first-boot setup script ─────────────────────────────────────
# This runs on first boot AFTER the OS has been installed to disk — a thin
# wrapper handling first-boot-specific concerns (live-session bail-out, the
# marker file, waiting for network, removing snaps that couldn't be purged at
# ISO-build time) around a single call to the staged provision.sh --tier=core.
# provision.sh itself is single-sourced with the manual/on-device entrypoint —
# see backends/ubuntu/provision/provision.sh — so this file no longer
# reimplements the tool-install list a second time.
cat > "$CHROOT_PATH/usr/lib/ci-os/first-boot-setup.sh" << 'BOOTSTRAP_SCRIPT'
#!/bin/bash
#=============================================================================
# CI-OS First-Boot Setup
# Runs provision.sh --tier=core once the system has a kernel, systemd, and
# network access. Runs automatically until it has completed once: at every
# boot and every 15 minutes (ci-os-first-boot-setup.timer) while pending, with
# at most MAX_AUTO_ATTEMPTS failed provisioning runs. `sudo ci-os-setup`
# (passes --manual) re-runs it at any time, completed or not.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

# NOTE: Do NOT use 'set -e' here. provision.sh's own install steps already
# tolerate individual network/third-party failures; a hard exit here would
# also abort the marker-file bookkeeping below.
set -u

BOOTSTRAP_ROOT="/usr/lib/ci-os/bootstrap"
PROVISION_SH="${BOOTSTRAP_ROOT}/backends/ubuntu/provision/provision.sh"
LOG_FILE="/var/log/ci-os-first-boot-setup.log"
# Written ONLY when provisioning succeeded. The unit and timer are gated on it.
MARKER_FILE="/var/lib/ci-os/.first-boot-setup-done"
# Failed automatic provisioning runs so far. An offline boot is not a run --
# waiting for network is cheap, re-downloading on every retry is not.
ATTEMPTS_FILE="/var/lib/ci-os/first-boot-setup-attempts"
MAX_AUTO_ATTEMPTS=3
LOCK_FILE="/run/ci-os-first-boot-setup.lock"

MANUAL=false
if [[ "${1:-}" == "--manual" ]]; then
    MANUAL=true
fi

exec > >(tee -a "$LOG_FILE") 2>&1

echo "[CI-OS] First-boot setup starting at $(date -u)$([[ "$MANUAL" == true ]] && echo ' (manual)')"

# Bail out immediately if running in a live session (safety net)
# Detect live session: Ubuntu's ISO does NOT pass boot=casper on the kernel
# command line (26.04.1). Instead casper mounts the boot medium at /cdrom. Check both
# the mount point and the kernel BOOT_IMAGE path for maximum reliability.
if [ -d /cdrom/casper ] || grep -q 'BOOT_IMAGE=/casper/' /proc/cmdline 2>/dev/null; then
    echo "[CI-OS] Live session detected — skipping first-boot setup."
    exit 0
fi

# One run at a time: the timer and a manual `ci-os-setup` can overlap.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[CI-OS] First-boot setup is already running (see $LOG_FILE)."
    exit 0
fi

if [[ "$MANUAL" != true ]]; then
    # Automatic run (boot or timer): skip once completed...
    if [[ -f "$MARKER_FILE" ]]; then
        echo "[CI-OS] First-boot setup already completed ($(cat "$MARKER_FILE")). To re-run: sudo ci-os-setup"
        exit 0
    fi
    # ...and stop retrying a provisioning run that keeps failing.
    attempts=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
    if [[ "$attempts" =~ ^[0-9]+$ ]] && (( attempts >= MAX_AUTO_ATTEMPTS )); then
        echo "[CI-OS] Provisioning failed $attempts times; not retrying automatically. See $LOG_FILE, then run: sudo ci-os-setup"
        exit 0
    fi
fi

# ── Wait for network ──────────────────────────────────────────────────────
# ICMP first, then HTTPS: some networks drop ping but allow the downloads
# provisioning actually needs.
network_up() {
    ping -c1 -W2 archive.ubuntu.com &>/dev/null && return 0
    ping -c1 -W2 1.1.1.1 &>/dev/null && return 0
    command -v curl >/dev/null 2>&1 \
        && curl -fsS -o /dev/null --max-time 5 https://archive.ubuntu.com/ubuntu/ &>/dev/null
}

NETWORK_OK=false
echo "[CI-OS] Waiting for network..."
for i in $(seq 1 30); do
    if network_up; then
        echo "[CI-OS] Network available."
        NETWORK_OK=true
        break
    fi
    echo "[CI-OS] Waiting for network... ($i/30)"
    sleep 2
done

if [[ "$NETWORK_OK" != "true" ]]; then
    # No marker: the next boot, or ci-os-first-boot-setup.timer within 15
    # minutes, tries again. Not counted as a failed attempt.
    echo "[CI-OS] WARNING: Network not available after 60s. Setup will retry automatically"
    echo "[CI-OS] (next boot, or within 15 minutes); or run once online: sudo ci-os-setup"
    exit 0
fi

# ── Remove unwanted snaps (deferred from ISO build) ───────────────────────
# These cannot be removed during ISO build because the snap seed is
# cryptographically signed. Now that snapd is running on the installed
# system, we can safely remove them. Not part of provision.sh's manifest —
# this is a one-time ISO-build-limitation cleanup, not an "install" step.
echo "[CI-OS] Removing unwanted snaps..."
snap remove --purge snap-store 2>/dev/null || true
snap remove --purge thunderbird 2>/dev/null || true
echo "[CI-OS] Unwanted snaps removed."

# ── Run provisioning ───────────────────────────────────────────────────────
mkdir -p "$(dirname "$MARKER_FILE")"
if [[ ! -x "$PROVISION_SH" ]]; then
    # A broken image, not a transient failure: retrying cannot help.
    echo "[CI-OS] WARNING: $PROVISION_SH not found or not executable; skipping provisioning."
    echo "no provisioner - $(date -u)" > "$MARKER_FILE"
    exit 0
fi

if [[ "$MANUAL" != true ]]; then
    # Count the run before starting it, so one killed by TimeoutStartSec
    # (e.g. a slow model pull) still counts toward the retry limit.
    attempts=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    attempts=$((attempts + 1))
    echo "$attempts" > "$ATTEMPTS_FILE"
    echo "[CI-OS] Running provision.sh --tier=core (automatic attempt $attempts/$MAX_AUTO_ATTEMPTS)..."
else
    echo "[CI-OS] Running provision.sh --tier=core..."
fi

if ! bash "$PROVISION_SH" --tier=core; then
    if [[ "$MANUAL" == true ]]; then
        echo "[CI-OS] provision.sh reported issues (see above). Fix them and re-run: sudo ci-os-setup"
    elif (( attempts < MAX_AUTO_ATTEMPTS )); then
        echo "[CI-OS] provision.sh reported issues (see above). Will retry automatically (next boot, or within 15 minutes)."
    else
        echo "[CI-OS] provision.sh reported issues (see above). Automatic retries exhausted; run: sudo ci-os-setup"
    fi
    exit 0
fi

# ── Mark complete ─────────────────────────────────────────────────────────
date -u > "$MARKER_FILE"
rm -f "$ATTEMPTS_FILE"

echo "[CI-OS] First-boot setup completed at $(date -u)"
echo "[CI-OS] Log saved to $LOG_FILE"
echo "[CI-OS] NOTE: Log out and back in for Docker group and PATH changes."
BOOTSTRAP_SCRIPT

chmod +x "$CHROOT_PATH/usr/lib/ci-os/first-boot-setup.sh"

# ── Create a convenient command alias ───────────────────────────────────────
cat > "$CHROOT_PATH/usr/local/bin/ci-os-setup" << 'EOF'
#!/bin/bash
# CI-OS Setup — install development tools (Docker, Node.js, Ollama, etc.)
# Usage: sudo ci-os-setup
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root: sudo ci-os-setup"
    exit 1
fi
# --manual: run even if setup already completed or automatic retries are exhausted.
exec /usr/lib/ci-os/first-boot-setup.sh --manual "$@"
EOF
chmod +x "$CHROOT_PATH/usr/local/bin/ci-os-setup"

# ── Create systemd service unit for first-boot auto-execution ───────────────
cat > "$CHROOT_PATH/usr/lib/systemd/system/ci-os-first-boot-setup.service" << 'SVCEOF'
[Unit]
Description=Companion OS first-boot development environment setup
Documentation=https://ci.computer
After=network-online.target
Wants=network-online.target
# Runs until provisioning has succeeded once: the script writes this marker
# only on success, and ci-os-first-boot-setup.timer retries while it's absent.
ConditionPathExists=!/var/lib/ci-os/.first-boot-setup-done
# NEVER run in the live USB session.
# Ubuntu's ISO does NOT pass boot=casper on the kernel command line (26.04.1). Instead
# we detect the live session by checking for casper files on the ISO mount.
ConditionPathExists=!/cdrom/casper/vmlinuz

[Service]
Type=oneshot
ExecStart=/usr/lib/ci-os/first-boot-setup.sh
# No RemainAfterExit: an "active (exited)" unit would ignore the retry timer.
RemainAfterExit=no
TimeoutStartSec=1800
StandardOutput=journal+console
StandardError=journal+console
Environment=DEBIAN_FRONTEND=noninteractive

[Install]
WantedBy=multi-user.target
SVCEOF

# Retry timer: re-runs the service every 15 minutes while setup is pending
# (e.g. first boot was offline). Once the marker exists the service's own
# condition makes each tick a no-op, and from the next boot the timer itself
# no longer starts.
cat > "$CHROOT_PATH/usr/lib/systemd/system/ci-os-first-boot-setup.timer" << 'TIMEREOF'
[Unit]
Description=Retry Companion OS first-boot setup until it completes
ConditionPathExists=!/var/lib/ci-os/.first-boot-setup-done
ConditionPathExists=!/cdrom/casper/vmlinuz

[Timer]
OnBootSec=15min
OnUnitInactiveSec=15min

[Install]
WantedBy=timers.target
TIMEREOF

# Enable the first-boot setup service and its retry timer
mkdir -p "$CHROOT_PATH/etc/systemd/system/multi-user.target.wants" \
         "$CHROOT_PATH/etc/systemd/system/timers.target.wants"
ln -sf /usr/lib/systemd/system/ci-os-first-boot-setup.service \
    "$CHROOT_PATH/etc/systemd/system/multi-user.target.wants/ci-os-first-boot-setup.service"
ln -sf /usr/lib/systemd/system/ci-os-first-boot-setup.timer \
    "$CHROOT_PATH/etc/systemd/system/timers.target.wants/ci-os-first-boot-setup.timer"

echo "[+] First-boot bootstrap service installed"
echo "[+] Bootstrap scripts copied to /usr/lib/ci-os/bootstrap/"
echo "[+] Manual re-run available via: sudo ci-os-setup"

#=============================================================================
# 11. Final Cleanup
#=============================================================================
echo "[*] Step 11: Final cleanup..."

# SSH host keys: openssh-server's postinst generated a set while this chroot was built (Step 10b). They would be the same on
# every machine installed from this image, so the cleanup below removes them, and this drop-in makes the machine make its
# own. It is installed first: the cleanup refuses to remove the keys unless it is in place. Why a drop-in and not the
# stock sshd-keygen.service as it is: that unit has ConditionFirstBoot=yes, which is false on a machine installed from the
# live USB (subiquity copies the live session's /etc/machine-id into the target), so the keys would never be made and
# ssh.service would fail in `sshd -t`. See the file.
install -D -m 0644 "$SCRIPT_DIR/payload/ssh/etc/systemd/system/sshd-keygen.service.d/10-ci-os-host-keys.conf" \
    "$CHROOT_PATH/etc/systemd/system/sshd-keygen.service.d/10-ci-os-host-keys.conf"

cat > "$CHROOT_PATH/tmp/final-cleanup.sh" << 'EOFSCRIPT'
#!/bin/bash

# Clean package cache
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/archives/*.deb

# Clean temporary files
rm -rf /tmp/*
rm -rf /var/tmp/*

# Clean shell history
rm -f /root/.bash_history
rm -f /home/*/.bash_history

# SSH host keys (see the install of the drop-in above): remove the set made while the image was built, but only with the
# unit that makes a new one on each machine in place. `ssh-keygen -A` in that unit is `Before=ssh.service`.
if [ ! -f /etc/systemd/system/sshd-keygen.service.d/10-ci-os-host-keys.conf ] || [ ! -f /usr/lib/systemd/system/sshd-keygen.service ]; then
    echo "[ERROR] the sshd-keygen drop-in or openssh-server's sshd-keygen.service is missing: not removing the SSH host keys" >&2
    exit 1
fi
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# Clean logs
find /var/log -type f -exec truncate -s 0 {} \;

echo "[+] Cleanup complete"
EOFSCRIPT

chmod +x "$CHROOT_PATH/tmp/final-cleanup.sh"
chroot_exec "/tmp/final-cleanup.sh"
rm -f "$CHROOT_PATH/tmp/final-cleanup.sh"

echo "[+] Final cleanup complete"

#=============================================================================
# Complete
#=============================================================================
echo
echo "[+] CI-OS customization complete!"
echo "[+] Chroot: $CHROOT_PATH"
echo "[+] Version: $CI_OS_VERSION"
