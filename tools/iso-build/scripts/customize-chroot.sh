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
#   ./customize-chroot.sh <chroot_path> <version>
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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
NAME="CI-OS"
VERSION="$CI_OS_VERSION"
ID=ubuntu
ID_LIKE=ubuntu
PRETTY_NAME="CI-OS $CI_OS_VERSION"
VERSION_ID="24.04"
HOME_URL="https://ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
UBUNTU_CODENAME=noble
VERSION_CODENAME=noble
CI_OS_VERSION="$CI_OS_VERSION"
CI_OS_BUILD="$(date -u +%Y%m%d)"
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
# CI-OS first-boot identity rebranding
# Replaces the Ubuntu-compatible IDs used during installation with real CI-OS IDs.

CI_OS_VERSION="$(grep '^CI_OS_VERSION=' /etc/os-release | cut -d= -f2 | tr -d '"')"
CI_OS_VERSION="${CI_OS_VERSION:-1.0}"

cat > /etc/os-release << __EOF__
NAME="CI-OS"
VERSION="${CI_OS_VERSION}"
ID=ci-os
ID_LIKE=ubuntu
PRETTY_NAME="CI-OS ${CI_OS_VERSION}"
VERSION_ID="${CI_OS_VERSION}"
HOME_URL="https://ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
UBUNTU_CODENAME=noble
VERSION_CODENAME=noble
__EOF__

cat > /etc/lsb-release << __EOF__
DISTRIB_ID=CI-OS
DISTRIB_RELEASE=${CI_OS_VERSION}
DISTRIB_CODENAME=noble
DISTRIB_DESCRIPTION="CI-OS ${CI_OS_VERSION}"
__EOF__

# Disable this service so it only runs once
systemctl disable ci-os-first-boot-rebrand.service

echo "[CI-OS] First-boot rebrand complete: ID=ci-os VERSION_ID=${CI_OS_VERSION}"
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

# Remove snap store (in chroot, snapd isn't running, so we clean up files directly)
# NOTE: We are in a chroot, so snapd is typically not running and
# `snap remove snap-store` would fail. Instead, remove snap-store
# by cleaning up its snap files, seeds, and desktop entries directly.
rm -f /var/lib/snapd/snaps/snap-store_*.snap
rm -f /var/lib/snapd/seed/snaps/snap-store.*
rm -rf /snap/snap-store
rm -rf /var/snap/snap-store
rm -f /var/lib/snapd/desktop/applications/snap-store_*.desktop

# Remove bloatware (be conservative - only remove obvious bloat)
apt-get purge -y \
    aisleriot \
    gnome-mahjongg \
    gnome-mines \
    gnome-sudoku \
    thunderbird || true

# Clean up
apt-get autoremove -y
apt-get autoclean
EOFSCRIPT

chmod +x "$CHROOT_PATH/tmp/remove-packages.sh"
chroot_exec "/tmp/remove-packages.sh"
rm "$CHROOT_PATH/tmp/remove-packages.sh"

echo "[+] Telemetry and bloatware removed"

#=============================================================================
# 2b. Install CI-OS Custom Packages
#=============================================================================
echo "[*] Step 2b: Installing CI-OS custom packages..."

CI_DEBS_DIR="$REPO_ROOT/output/packages"
if [[ -d "$CI_DEBS_DIR" ]] && compgen -G "$CI_DEBS_DIR/*.deb" > /dev/null 2>&1; then
    # Stage debs inside the chroot
    mkdir -p "$CHROOT_PATH/tmp/ci-debs"
    cp "$CI_DEBS_DIR"/*.deb "$CHROOT_PATH/tmp/ci-debs/"

    # Build a local apt repo so apt can handle dependency resolution
    # dpkg-scanpackages is in dpkg-dev — use apt-ftparchive if available,
    # otherwise fall back to direct dpkg install + apt-get install -f
    cat > "$CHROOT_PATH/tmp/install-ci-packages.sh" << 'EOFSCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

DEB_DIR="/tmp/ci-debs"

# Build a local Packages index so apt can resolve inter-package deps
if command -v dpkg-scanpackages &>/dev/null; then
    dpkg-scanpackages --multiversion "$DEB_DIR" > "$DEB_DIR/Packages" 2>/dev/null
    echo "deb [trusted=yes] file://$DEB_DIR ./" > /etc/apt/sources.list.d/ci-local.list
    apt-get update -o Dir::Etc::sourcelist="sources.list.d/ci-local.list" \
                   -o Dir::Etc::sourceparts="-" \
                   -o APT::Get::List-Cleanup="0" 2>/dev/null || true
    apt-get install -y --allow-downgrades \
        companion-os-base \
        companion-os-keyring \
        companion-memory \
        companion-agents \
        mydistro-branding || dpkg -i --force-overwrite "$DEB_DIR"/*.deb || true
    rm -f /etc/apt/sources.list.d/ci-local.list
else
    # Fallback: install directly with dpkg then fix any missing deps
    # --force-overwrite needed for mydistro-branding which replaces a Yaru file
    dpkg -i --force-overwrite "$DEB_DIR"/*.deb || true
    apt-get install -f -y || true
fi

# Clean up staged debs
rm -rf "$DEB_DIR"
EOFSCRIPT

    chmod +x "$CHROOT_PATH/tmp/install-ci-packages.sh"
    chroot_exec "/tmp/install-ci-packages.sh"
    rm -f "$CHROOT_PATH/tmp/install-ci-packages.sh"
    echo "[+] CI-OS custom packages installed"
else
    echo "[!] No CI-OS .deb packages found in $CI_DEBS_DIR — skipping"
fi

#=============================================================================
# 3. Install CI-OS Branding
#=============================================================================
echo "[*] Step 3: Installing CI-OS branding..."

# Copy logo
if [[ -f "$REPO_ROOT/assets/logos/ci-holo-depth.png" ]]; then
    copy_to_chroot "$REPO_ROOT/assets/logos/ci-holo-depth.png" "/usr/share/pixmaps/companion-logo.png"
fi

# Copy wallpaper
if [[ -f "$REPO_ROOT/setup/os-changes/background.png" ]]; then
    copy_to_chroot "$REPO_ROOT/setup/os-changes/background.png" "/usr/share/backgrounds/ci-os-wallpaper.png"
fi

# Set default wallpaper for GDM and user sessions
mkdir -p "$CHROOT_PATH/etc/dconf/db/local.d"
cat > "$CHROOT_PATH/etc/dconf/db/local.d/01-ci-os-wallpaper" << 'EOF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-uri-dark='file:///usr/share/backgrounds/ci-os-wallpaper.png'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
EOF

# Update dconf database
chroot_exec "dconf update" || true

echo "[+] Branding installed"

#=============================================================================
# 4. Configure GRUB
#=============================================================================
echo "[*] Step 4: Configuring GRUB..."

# Update GRUB defaults
sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="CI-OS"/' "$CHROOT_PATH/etc/default/grub" || true
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' "$CHROOT_PATH/etc/default/grub" || true

echo "[+] GRUB configured"

#=============================================================================
# 5. Configure Plymouth Splash
#=============================================================================
echo "[*] Step 5: Configuring Plymouth splash..."

# We'll use the default ubuntu-logo theme but could customize later
# TODO: Create custom Plymouth theme in future enhancement

echo "[+] Plymouth configured (using default theme)"

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
#=============================================================================
# CI-OS ROCm Installation Helper
# Installs ROCm 7.2+ and AMD GPU tools
#
# Usage: sudo ci-os-install-rocm
#=============================================================================

set -e

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Check for required tools
for cmd in wget gpg; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed. Please install it first."
        exit 1
    fi
done

echo "[*] Installing ROCm for CI-OS..."

# Add ROCm repository using keyring and signed-by (apt-key is deprecated)
ROCM_KEYRING="/usr/share/keyrings/rocm-archive-keyring.gpg"
install -d -m 0755 "$(dirname "$ROCM_KEYRING")"
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o "$ROCM_KEYRING"
echo "deb [arch=amd64 signed-by=$ROCM_KEYRING] https://repo.radeon.com/rocm/apt/latest ubuntu main" > /etc/apt/sources.list.d/rocm.list

# Update and install
apt-get update
apt-get install -y rocm-hip-sdk rocm-smi-lib

# Add user to video and render groups
if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -a -G video,render "$SUDO_USER"
    echo "[+] Added $SUDO_USER to video and render groups"
fi

echo "[+] ROCm installed successfully"
echo "[!] Please log out and back in for group changes to take effect"
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
