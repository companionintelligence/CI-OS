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
# 5. Sets up Plymouth, GRUB themes
# 6. Configures the installer (whitelabel.yaml)
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

echo "[*] Customizing chroot: $CHROOT_PATH"
echo "[*] CI-OS Version: $CI_OS_VERSION"

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

#=============================================================================
# 1. Update OS Identity
#=============================================================================
echo "[*] Step 1: Updating OS identity..."

# IMPORTANT: The squashfs is both the live session AND the base that gets
# copied to disk during installation. Subiquity/curtin rely on ID=ubuntu and
# VERSION_ID=24.04 to configure apt sources, run curthooks (update-initramfs,
# grub-install), and seed snaps correctly. Setting ID=ci-os here breaks the
# installer toolchain. Instead, we:
#  - Keep ubuntu-compatible IDs in os-release / lsb-release (live + initial install)
#  - Brand NAME and PRETTY_NAME as CI-OS (visible in grub, neofetch, etc.)
#  - Install a first-boot systemd service that rewrites the IDs to ci-os after
#    the installer has finished and the system first boots into the desktop.

cat > "$CHROOT_PATH/etc/os-release" << EOF
NAME="CI OS"
VERSION="24.04 LTS (Companion Intelligence ${CI_OS_VERSION})"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="CI OS ${CI_OS_VERSION} (Ubuntu Noble)"
VERSION_ID="24.04"
HOME_URL="https://ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
UBUNTU_CODENAME=noble
VERSION_CODENAME=noble
CI_OS_ID=ci-os
CI_OS_VERSION="${CI_OS_VERSION}"
CI_OS_BUILD="$(date -u +%Y%m%d)"
LOGO=ci-os-logo
EOF

# lsb-release: keep DISTRIB_ID=Ubuntu and DISTRIB_RELEASE=24.04 so that
# lsb_release -si / -sr return values the installer and apt tooling expect.
cat > "$CHROOT_PATH/etc/lsb-release" << EOF
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=24.04
DISTRIB_CODENAME=noble
DISTRIB_DESCRIPTION="CI-OS $CI_OS_VERSION"
EOF

# ---------------------------------------------------------------------------
# First-boot rebrand service
# Runs once after installation is complete and the user boots the installed
# system for the first time. Writes the real CI-OS IDs and disables itself.
# ---------------------------------------------------------------------------
mkdir -p "$CHROOT_PATH/usr/lib/ci-os"

cat > "$CHROOT_PATH/usr/lib/ci-os/first-boot-rebrand.sh" << 'REBRAND'
#!/bin/bash
# CI-OS first-boot branding refresh — keeps Ubuntu-compatible machine identity.
set -euo pipefail

if [[ -f /usr/lib/ci-os/os-release.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/lib/ci-os/os-release.sh
  ci_os_write_branded_os_release /etc/os-release
  ci_os_write_branded_lsb_release /etc/lsb-release
else
  CI_OS_VERSION="$(grep '^CI_OS_VERSION=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
  CI_OS_VERSION="${CI_OS_VERSION:-1.0}"
  UBUNTU_CODENAME="$(grep '^UBUNTU_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo noble)"
  UBUNTU_VER="$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo 24.04)"
  cat > /etc/os-release << __EOF__
NAME="CI OS"
VERSION="${UBUNTU_VER} LTS (Companion Intelligence ${CI_OS_VERSION})"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="CI OS ${CI_OS_VERSION} (Ubuntu ${UBUNTU_CODENAME})"
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

systemctl disable ci-os-first-boot-rebrand.service
echo "[CI-OS] First-boot branding refresh complete (ID=ubuntu, CI_OS_ID=ci-os)"
REBRAND

chmod +x "$CHROOT_PATH/usr/lib/ci-os/first-boot-rebrand.sh"

cat > "$CHROOT_PATH/usr/lib/systemd/system/ci-os-first-boot-rebrand.service" << 'SVCEOF'
[Unit]
Description=CI-OS First-Boot Identity Rebranding
Documentation=https://ci.computer
After=local-fs.target
Before=display-manager.service gdm.service
ConditionPathExists=/usr/lib/ci-os/first-boot-rebrand.sh
# Only run once — service disables itself on success
ConditionFirstBoot=yes
# NEVER run in the live USB session.
# Ubuntu 24.04 does NOT pass boot=casper on the kernel command line, so
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
echo "ci-os" > "$CHROOT_PATH/etc/hostname"

# Create custom issue banner
cat > "$CHROOT_PATH/etc/issue" << 'EOF'

   ██████╗██╗      ██████╗ ███████╗
  ██╔════╝██║     ██╔═══██╗██╔════╝
  ██║     ██║     ██║   ██║███████╗
  ██║     ██║     ██║   ██║╚════██║
  ╚██████╗██║     ╚██████╔╝███████║
   ╚═════╝╚═╝      ╚═════╝ ╚══════╝
  
  Companion Intelligence Operating System
  https://ci.computer

EOF

cp "$CHROOT_PATH/etc/issue" "$CHROOT_PATH/etc/issue.net"

echo "[+] OS identity updated"

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
# NOTE: thunderbird is a snap on 24.04, already removed from snap seed above.
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
if [[ -f "$GRESOURCE_SRC" ]]; then
    # Replace the top-level shell theme (desktop session)
    install -m 644 -o root -g root "$GRESOURCE_SRC" \
        "$CHROOT_PATH/usr/share/gnome-shell/gnome-shell-theme.gresource"
    # Replace the Yaru variant (GDM alternatives chain points here)
    mkdir -p "$CHROOT_PATH/usr/share/gnome-shell/theme/Yaru"
    install -m 644 -o root -g root "$GRESOURCE_SRC" \
        "$CHROOT_PATH/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
    echo "[+] GDM/GNOME Shell theme applied"
else
    echo "[!] CI-OS gresource not found at $GRESOURCE_SRC — skipping theme"
fi

#=============================================================================
# 3. Install CI-OS Branding
#=============================================================================
echo "[*] Step 3: Installing CI-OS branding..."

# Copy logo
if [[ -f "$REPO_ROOT/assets/logos/ci-holo-depth.png" ]]; then
    copy_to_chroot "$REPO_ROOT/assets/logos/ci-holo-depth.png" "/usr/share/pixmaps/companion-logo.png"
fi

# Copy wallpaper — try primary path first, then fallback, warn if neither exists
if [[ -f "$REPO_ROOT/core/render/inputs/background.png" ]]; then
    copy_to_chroot "$REPO_ROOT/core/render/inputs/background.png" "/usr/share/backgrounds/ci-os-wallpaper.png"
    echo "[+] Wallpaper installed from core/render/inputs/background.png"
elif [[ -f "$REPO_ROOT/assets/wallpapers/ci-os-wallpaper.svg" ]]; then
    copy_to_chroot "$REPO_ROOT/assets/wallpapers/ci-os-wallpaper.svg" "/usr/share/backgrounds/ci-os-wallpaper.svg"
    echo "[+] Wallpaper installed from assets/wallpapers/ci-os-wallpaper.svg"
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

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
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

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'

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

ci_grub_merge_key "$CHROOT_PATH/etc/default/grub" GRUB_DISTRIBUTOR "CI OS"
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
# repo). Staged into the chroot preserving the real repo's relative directory
# layout, so 10-plymouth.sh's own REPO_ROOT/theme-lib.sh sourcing resolves
# without any chroot-specific changes to the script itself.
#
# Note: this brands Plymouth for the INSTALLED system's own boots (curtin
# regenerates the initramfs from this rootfs during install finalization).
# The live/installer-session splash itself, before GRUB hands off, is driven
# by casper/initrd copied verbatim from the stock Ubuntu ISO — rebuilding
# that is a materially higher-risk change for a several-second one-time
# screen, so it's an accepted residual gap, not something chased here.
STAGE="$CHROOT_PATH/tmp/ci-brand"
mkdir -p "$STAGE/backends/ubuntu/desktop-theme" "$STAGE/core/lib" \
         "$STAGE/core/render/inputs" "$STAGE/vendor/brand/tokens"
cp "$REPO_ROOT/backends/ubuntu/desktop-theme/10-plymouth.sh" "$STAGE/backends/ubuntu/desktop-theme/"
cp "$REPO_ROOT/core/lib/theme-lib.sh" "$STAGE/core/lib/"
cp "$REPO_ROOT/core/render/inputs/Logo_Banner_Color.png" "$STAGE/core/render/inputs/"
cp "$REPO_ROOT/vendor/brand/tokens/tokens.sh" "$STAGE/vendor/brand/tokens/"

chroot_exec "bash /tmp/ci-brand/backends/ubuntu/desktop-theme/10-plymouth.sh"

echo "[+] Plymouth configured from the canon tokens (installed-system boots)"

#=============================================================================
# 6. Install AMD GPU Support
#=============================================================================
echo "[*] Step 6: Installing AMD GPU support..."

cat > "$CHROOT_PATH/tmp/install-amd.sh" << 'EOFSCRIPT'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# Add AMD GPU PPA (if available) or use Ubuntu's default amdgpu driver
# For ROCm, we'll document manual installation post-install due to kernel dependencies

# Ensure amdgpu firmware is installed
apt-get install -y linux-firmware amd64-microcode || true

# Install AMD tools that are available in Ubuntu repos
apt-get install -y \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    libvulkan1 \
    libvulkan1:i386 \
    vulkan-tools || true

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
# Delegates to the maintained CI OS ROCm installer (Ubuntu codename + AMDGPU repo probe).
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
# 7. Configure Installer (Ubuntu Desktop Installer Whitelabel)
#=============================================================================
echo "[*] Step 7: Configuring installer..."

mkdir -p "$CHROOT_PATH/usr/share/desktop-provision"

# Create whitelabel configuration
cat > "$CHROOT_PATH/usr/share/desktop-provision/whitelabel.yaml" << 'EOF'
# CI-OS Installer Whitelabel Configuration
app:
  name: "Companion Intelligence Installer"
  
theme:
  primary_color: "#066c80"    # Primary Dark Green
  accent_color: "#00a9a7"     # Medium Green
  
pages:
  try_install:
    visible: true
  telemetry:
    visible: false            # Disable telemetry opt-in page
  
mode: normal                  # Use 'oem' for OEM mode (GNOME Initial Setup on first boot)
EOF

# Colors only — source from the canon, not the retired logo-ramp literals.
# The heredoc above stays single-quoted (no other $ references to worry
# about breaking); substitute after the fact instead, matching the pattern
# already used elsewhere in this file (see the wallpaper dconf rewrite above).
sed -i "s/#066c80/${CI_LIGHT_PRIMARY}/g; s/#00a9a7/${CI_DARK_PRIMARY}/g" \
    "$CHROOT_PATH/usr/share/desktop-provision/whitelabel.yaml"

# Create custom installer slides directory
mkdir -p "$CHROOT_PATH/usr/share/desktop-provision/slides"

cat > "$CHROOT_PATH/usr/share/desktop-provision/slides/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: linear-gradient(135deg, #066c80 0%, #00a9a7 100%);
            color: white;
            margin: 0;
            padding: 40px;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
        }
        h1 {
            font-size: 3em;
            margin-bottom: 20px;
        }
        p {
            font-size: 1.5em;
            max-width: 600px;
            text-align: center;
            line-height: 1.6;
        }
    </style>
</head>
<body>
    <h1>🚀 Uncloud Modern Life</h1>
    <p>Welcome to CI-OS — your sovereign computing platform with no ads, no surveillance, and seamless AMD AI hardware integration.</p>
</body>
</html>
EOF

# Colors only, same canon substitution as whitelabel.yaml above — font stack
# is intentionally untouched.
sed -i "s/#066c80/${CI_LIGHT_PRIMARY}/g; s/#00a9a7/${CI_DARK_PRIMARY}/g" \
    "$CHROOT_PATH/usr/share/desktop-provision/slides/index.html"

echo "[+] Installer configured"

#=============================================================================
# 8. Create CI-OS MOTD
#=============================================================================
echo "[*] Step 8: Creating CI-OS MOTD..."

cat > "$CHROOT_PATH/etc/update-motd.d/00-ci-os-header" << 'EOF'
#!/bin/sh
cat << 'MOTD'

   ██████╗██╗      ██████╗ ███████╗
  ██╔════╝██║     ██╔═══██╗██╔════╝
  ██║     ██║     ██║   ██║███████╗
  ██║     ██║     ██║   ██║╚════██║
  ╚██████╗██║     ╚██████╔╝███████║
   ╚═════╝╚═╝      ╚═════╝ ╚══════╝
  
  Companion Intelligence Operating System
  https://ci.computer

MOTD
EOF

chmod +x "$CHROOT_PATH/etc/update-motd.d/00-ci-os-header"

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
echo "  CI-OS System Information"
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
# deb [signed-by=/usr/share/keyrings/ci-archive-keyring.gpg] https://packages.ci.computer/ubuntu noble main
EOF

echo "[+] Package repository template created"

#=============================================================================
# 10b. Pre-install Development Packages
#=============================================================================
echo "[*] Step 10b: Pre-installing development packages..."

cat > "$CHROOT_PATH/tmp/install-dev-packages.sh" << 'EOFSCRIPT'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

apt-get update

# Core development tools (safe to install in chroot)
apt-get install -y \
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
    openssh-server || true

# Clean up after install
apt-get clean
rm -rf /var/lib/apt/lists/*
EOFSCRIPT

chmod +x "$CHROOT_PATH/tmp/install-dev-packages.sh"
chroot_exec "/tmp/install-dev-packages.sh"
rm -f "$CHROOT_PATH/tmp/install-dev-packages.sh"

echo "[+] Development packages pre-installed"

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
# network access. This runs automatically on first boot, or can be re-run
# manually: sudo ci-os-setup
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

# NOTE: Do NOT use 'set -e' here. Expected cleanup failures are best-effort.
# Provisioning itself is checked explicitly below so the completion marker is
# written only after a successful run.
set -u

BOOTSTRAP_ROOT="/usr/lib/ci-os/bootstrap"
PROVISION_SH="${BOOTSTRAP_ROOT}/backends/ubuntu/provision/provision.sh"
LOG_FILE="/var/log/ci-os-first-boot-setup.log"
MARKER_FILE="/var/lib/ci-os/.first-boot-setup-done"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "[CI-OS] First-boot setup starting at $(date -u)"

# Bail out immediately if running in a live session (safety net)
# Detect live session: Ubuntu 24.04 does NOT pass boot=casper on the kernel
# command line. Instead casper mounts the boot medium at /cdrom. Check both
# the mount point and the kernel BOOT_IMAGE path for maximum reliability.
if [ -d /cdrom/casper ] || grep -q 'BOOT_IMAGE=/casper/' /proc/cmdline 2>/dev/null; then
    echo "[CI-OS] Live session detected — skipping first-boot setup."
    exit 0
fi

# If already completed, skip
if [[ -f "$MARKER_FILE" ]]; then
    echo "[CI-OS] First-boot setup already completed. To re-run: sudo rm $MARKER_FILE && sudo ci-os-setup"
    exit 0
fi

# ── Wait for network ──────────────────────────────────────────────────────
NETWORK_OK=false
echo "[CI-OS] Waiting for network..."
for i in $(seq 1 30); do
    if ping -c1 -W2 archive.ubuntu.com &>/dev/null || ping -c1 -W2 1.1.1.1 &>/dev/null; then
        echo "[CI-OS] Network available."
        NETWORK_OK=true
        break
    fi
    echo "[CI-OS] Waiting for network... ($i/30)"
    sleep 2
done

if [[ "$NETWORK_OK" != "true" ]]; then
    echo "[CI-OS] WARNING: Network not available after 60s. Skipping network-dependent setup."
    echo "[CI-OS] Re-run later with: sudo ci-os-setup"
    # Do not create the completion marker while offline. The enabled oneshot
    # will try again on the next boot, and `ci-os-setup` remains immediately
    # runnable without asking the user to remove a misleading marker first.
    exit 1
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
if [[ -x "$PROVISION_SH" ]]; then
    echo "[CI-OS] Running provision.sh --tier=core..."
    if ! bash "$PROVISION_SH" --tier=core; then
        echo "[CI-OS] ERROR: provision.sh reported issues; setup remains incomplete."
        echo "[CI-OS] Re-run later with: sudo ci-os-setup"
        exit 1
    fi
else
    echo "[CI-OS] ERROR: $PROVISION_SH not found or not executable; setup remains incomplete."
    exit 1
fi

# ── Mark complete ─────────────────────────────────────────────────────────
mkdir -p "$(dirname "$MARKER_FILE")"
date -u > "$MARKER_FILE"

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
exec /usr/lib/ci-os/first-boot-setup.sh "$@"
EOF
chmod +x "$CHROOT_PATH/usr/local/bin/ci-os-setup"

# ── Create systemd service unit for first-boot auto-execution ───────────────
cat > "$CHROOT_PATH/usr/lib/systemd/system/ci-os-first-boot-setup.service" << 'SVCEOF'
[Unit]
Description=CI-OS First-Boot Development Environment Setup
Documentation=https://ci.computer
After=network-online.target
Wants=network-online.target
# Only run once — script checks a marker file and exits if already done
ConditionPathExists=!/var/lib/ci-os/.first-boot-setup-done
# NEVER run in the live USB session.
# Ubuntu 24.04 does NOT pass boot=casper on the kernel command line. Instead
# we detect the live session by checking for casper files on the ISO mount.
ConditionPathExists=!/cdrom/casper/vmlinuz

[Service]
Type=oneshot
ExecStart=/usr/lib/ci-os/first-boot-setup.sh
RemainAfterExit=yes
TimeoutStartSec=1800
StandardOutput=journal+console
StandardError=journal+console
Environment=DEBIAN_FRONTEND=noninteractive

[Install]
WantedBy=multi-user.target
SVCEOF

# Enable the first-boot setup service
mkdir -p "$CHROOT_PATH/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/ci-os-first-boot-setup.service \
    "$CHROOT_PATH/etc/systemd/system/multi-user.target.wants/ci-os-first-boot-setup.service"

echo "[+] First-boot bootstrap service installed"
echo "[+] Bootstrap scripts copied to /usr/lib/ci-os/bootstrap/"
echo "[+] Manual re-run available via: sudo ci-os-setup"

#=============================================================================
# 11. Final Cleanup
#=============================================================================
echo "[*] Step 11: Final cleanup..."

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
