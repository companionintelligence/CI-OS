# CI-OS Installation Guide

Complete guide for installing CI-OS on your computer.

© Companion Intelligence — Lifescope Inc

---

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Download CI-OS](#download-ci-os)
3. [Verify Your Download](#verify-your-download)
4. [Create Bootable USB](#create-bootable-usb)
5. [Installation Steps](#installation-steps)
6. [First Boot Setup](#first-boot-setup)
7. [Post-Installation](#post-installation)
8. [Troubleshooting](#troubleshooting)

---

## System Requirements

### Minimum Requirements

- **CPU**: 64-bit x86 processor (Intel or AMD)
- **RAM**: 4GB
- **Storage**: 25GB available disk space
- **Display**: 1024x768 resolution
- **Internet**: Recommended for updates

### Recommended for AI Features

- **CPU**: AMD Ryzen 5 5600 or newer
- **RAM**: 16GB or more
- **Storage**: 100GB SSD
- **GPU**: AMD Radeon RX 5000 series or newer (RDNA 2/3/4)
- **Display**: 1920x1080 or higher

### Supported Hardware

- **CPU**: 
  - AMD: Ryzen 1000 series and newer
  - Intel: Core i3/i5/i7/i9 6th gen and newer
- **GPU**: 
  - AMD Radeon RX 5000/6000/7000 series (best support)
  - NVIDIA cards supported via Ubuntu's default drivers
  - Intel integrated graphics supported
- **Storage**: SATA/NVMe SSD recommended, HDD supported
- **Network**: Ethernet or WiFi

---

## Download CI-OS

### Official Download

Visit https://github.com/companionintelligence/CI-OS/releases

Download:
- `companion-os-1.0-amd64.iso` - Main ISO file
- `SHA256SUMS` - Checksum file
- `SHA256SUMS.gpg` - GPG signature (optional)

### ISO Variants

- **Standard**: Works on most hardware
- Future variants may include:
  - NVIDIA-optimized (with proprietary drivers)
  - Server edition (minimal install)

---

## Verify Your Download

**Important**: Always verify ISO integrity before installation.

### Verify Checksum (Linux/macOS)

```bash
# Download ISO and SHA256SUMS to same directory
cd ~/Downloads

# Verify checksum
sha256sum -c SHA256SUMS
# Expected output: companion-os-1.0-amd64.iso: OK
```

### Verify Checksum (Windows)

Using PowerShell:

```powershell
# Calculate SHA256
Get-FileHash companion-os-1.0-amd64.iso -Algorithm SHA256

# Compare with SHA256SUMS file content
```

### Verify GPG Signature (Optional)

If you downloaded `SHA256SUMS.gpg`:

```bash
# Import CI-OS public key (first time only)
# Replace <CI-OS-KEY-ID> with the CI-OS GPG key ID published on the CI-OS
# GitHub Releases page (see the "Release signing key" information there).
# The CI-OS GPG key ID is published on the GitHub Releases page
# Look for "Release signing key" in the release notes
gpg --keyserver keyserver.ubuntu.com --recv-keys <CI-OS-KEY-ID>

# Verify signature
gpg --verify SHA256SUMS.gpg SHA256SUMS
# Expected: "Good signature from Companion Intelligence"
```

---

## Create Bootable USB

You need a USB drive with at least 8GB capacity.

**⚠️ Warning**: This will erase all data on the USB drive!

### Using Linux

```bash
# Find your USB device
lsblk
# Look for your USB drive (e.g., /dev/sdb)

# Write ISO to USB
sudo dd if=companion-os-1.0-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
# Replace /dev/sdX with your USB device (e.g., /dev/sdb)

# Sync to ensure write completion
sync
```

### Using macOS

```bash
# Find your USB device
diskutil list
# Look for your USB drive (e.g., /dev/disk2)

# Unmount the drive
diskutil unmountDisk /dev/diskX
# Replace /dev/diskX with your USB device

# Write ISO to USB
sudo dd if=companion-os-1.0-amd64.iso of=/dev/rdiskX bs=4m
# Use /dev/rdiskX (with 'r') for faster writes

# Eject when complete
diskutil eject /dev/diskX
```

### Using Windows

**Option 1: Rufus (Recommended)**

1. Download Rufus: https://rufus.ie
2. Launch Rufus
3. Select your USB device
4. Click "SELECT" and choose `companion-os-1.0-amd64.iso`
5. Partition scheme: GPT
6. Target system: UEFI (or BIOS if using older system)
7. Click "START"
8. Wait for completion

**Option 2: Etcher**

1. Download Etcher: https://www.balena.io/etcher
2. Launch Etcher
3. Select ISO file
4. Select USB drive
5. Click "Flash!"

---

## Installation Steps

### 1. Boot from USB

1. **Insert USB drive** into your computer
2. **Restart** your computer
3. **Enter boot menu**:
   - Common keys: F12, F2, F10, ESC, DEL
   - Varies by manufacturer (watch boot screen)
4. **Select USB drive** from boot menu
5. Wait for CI-OS to load (1-2 minutes)

### 2. Try or Install

When CI-OS boots, you'll see two options:

- **Try CI-OS**: Test without installing (runs from USB)
- **Install CI-OS**: Proceed with installation

Select **Install CI-OS** to begin installation.

### 3. Choose Language

Select your preferred language and click **Continue**.

### 4. Keyboard Layout

1. Select your keyboard layout
2. Test in the text box
3. Click **Continue**

### 5. Updates and Other Software

Options:
- **Normal installation**: Recommended - includes web browser, utilities, office software
- **Minimal installation**: Basic system with web browser only

Additional options:
- ☑️ **Download updates while installing** (recommended if you have internet)
- ☑️ **Install third-party software** (recommended for better hardware support)

Click **Continue**.

### 6. Installation Type

Choose how to install CI-OS:

**Option A: Erase disk and install CI-OS**
- Simplest option
- Wipes the entire disk
- CI-OS becomes the only OS
- **⚠️ Warning**: All existing data will be erased!

**Option B: Install CI-OS alongside existing OS**
- Dual-boot configuration
- Keep existing Windows/Linux
- Installer will resize partitions automatically
- Choose how much space to allocate

**Option C: Something else**
- Manual partitioning
- For advanced users
- Full control over partitions

**Recommended partitioning (for manual)**:
- `/` (root): 50GB minimum, ext4
- `/home`: Remaining space, ext4
- swap: 4-8GB (or equal to RAM for hibernation)
- `/boot/efi`: 512MB, FAT32 (for UEFI systems)

Click **Install Now** after making selection.

### 7. Confirm Changes

Review partition changes and click **Continue** to proceed.

### 8. Select Timezone

1. Click your location on the map, or
2. Type your city name
3. Click **Continue**

### 9. Create User Account

Enter:
- **Your name**: Full name
- **Computer name**: Hostname (default: `ci-os`)
- **Username**: Login username
- **Password**: Strong password (required)
- **Confirm password**

Options:
- ○ Log in automatically
- ● Require password to log in (recommended)

Click **Continue**.

### 10. Installation Progress

The installer will:
1. Copy files to disk (15-25 minutes)
2. Install boot loader
3. Configure system
4. Clean up

You can continue using the live system during installation.

### 11. Installation Complete

When finished:
1. Click **Restart Now**
2. Remove USB drive when prompted
3. Press Enter to restart

---

## First Boot Setup

### 1. Boot into CI-OS

After restart:
1. System will boot from hard drive
2. GRUB boot menu appears (press ESC to see options)
3. CI-OS loads automatically (10-30 seconds)

### 2. Login

Enter your password at the login screen.

### 3. Welcome to CI-OS

You'll see the CI-OS desktop with:
- Custom wallpaper (CI brand)
- Dark green color scheme
- CI-OS logo in top bar

---

## Post-Installation

### Essential First Steps

#### 1. Update System

```bash
# Open Terminal (Ctrl+Alt+T)
sudo apt update
sudo apt upgrade -y
```

#### 2. Check System Info

```bash
# Display CI-OS system information
ci-os-info
```

This shows:
- OS version
- Kernel version
- AMD GPU detection
- ROCm status
- User groups

#### 3. Install AMD ROCm (for AI workloads)

If you have an AMD GPU:

```bash
sudo ci-os-install-rocm
```

This installs:
- ROCm **7.2.4** (newest Ryzen-compatible apt line; there is no 7.3 on repo.radeon.com)
- On **Strix Halo / gfx1151**: `amdgpu-install --usecase=rocm --no-dkms` (inbox amdgpu; DKMS is removed if present)
- On other AMD GPUs: `amdgpu-install --usecase=rocm` (DKMS allowed)
- AMD GPU tools (rocm-smi, rocminfo)
- Adds user to `video` and `render` groups

**Log out and back in** after installation for group changes to take effect. Prefer Ubuntu 24.04 HWE ≥ `6.17.0-19…` or OEM ≥ `6.14.0-1018` on Strix Halo.

#### 4. Verify GPU Support

```bash
# Check GPU detection
lspci | grep -i vga

# Check amdgpu driver (AMD GPUs)
lsmod | grep amdgpu

# Check ROCm (if installed)
rocminfo

# Check groups
groups
# Should include: video render
```

### Install Additional Software

#### From Ubuntu Repositories

```bash
# Example: Install development tools
sudo apt install build-essential git curl

# Example: Install media tools
sudo apt install vlc gimp inkscape
```

#### Using Snap (Alternative to removed Snap Store)

```bash
# Example: Install Slack
sudo snap install slack

# List installed snaps
snap list
```

#### Using Flatpak

```bash
# Enable Flatpak (if not already)
sudo apt install flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Example: Install Spotify
flatpak install flathub com.spotify.Client
```

### Configure Development Environment

CI-OS includes setup scripts for development tools:

```bash
# Setup Docker, Node.js, VS Code, etc. (from the repository root)
sudo ./scripts/setup-fresh-ubuntu.sh
```

See README.md for details on included tools.

### Customization

#### Change Wallpaper

System Settings → Appearance → Background

Or use the existing wallpaper replacement script (from the repository root):

```bash
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only wallpaper
```

#### Install Additional Themes

```bash
sudo apt install gnome-tweaks
```

Launch "Tweaks" to customize themes, fonts, and more.

---

## Troubleshooting

### Boot Issues

#### GRUB Menu Doesn't Appear

**Solution**: GRUB is hidden by default. Press ESC during boot to show menu.

#### System Won't Boot After Installation

**Possible causes**:
1. **Secure Boot**: Try disabling Secure Boot in BIOS/UEFI
2. **Boot order**: Ensure hard drive is first in boot order
3. **UEFI/Legacy mismatch**: Reinstall with correct boot mode

**How to access BIOS/UEFI**:
- Restart and press DEL, F2, F10, or ESC (varies by manufacturer)
- Look for "Boot" settings

### Display Issues

#### Low Resolution or No GUI

**Solution**: Install proprietary drivers

For NVIDIA:
```bash
ubuntu-drivers devices
sudo ubuntu-drivers autoinstall
sudo reboot
```

For AMD (ROCm 7.2.4; Strix Halo uses `--no-dkms`):
```bash
sudo ci-os-install-rocm
sudo reboot
```

#### Multiple Monitors Not Detected

**Solution**: 
1. System Settings → Displays
2. Click "Detect Displays"
3. Arrange monitors as needed

### Hardware Issues

#### WiFi Not Working

**Solution 1**: Check hardware switch (some laptops have physical WiFi switches)

**Solution 2**: Install additional firmware
```bash
sudo apt install linux-firmware
sudo reboot
```

#### Bluetooth Not Working

```bash
# Check status
systemctl status bluetooth

# Start service
sudo systemctl start bluetooth
sudo systemctl enable bluetooth
```

#### Sound Not Working

```bash
# Check sound devices
aplay -l

# Install PulseAudio controls
sudo apt install pavucontrol

# Launch and configure
pavucontrol
```

### AMD GPU Issues

#### GPU Not Detected

```bash
# Check if GPU is visible
lspci | grep -i vga
lspci | grep -i amd

# Check driver
lsmod | grep amdgpu
```

If amdgpu driver not loaded:
```bash
# Try loading manually
sudo modprobe amdgpu

# Make permanent
echo "amdgpu" | sudo tee -a /etc/modules
```

#### ROCm Installation Fails

Check compatibility: https://rocm.docs.amd.com/en/latest/release/gpu_os_support.html

Ensure your GPU is supported by ROCm 7.2.4 (Strix Halo / gfx1151: inbox amdgpu, `--no-dkms`).

### Performance Issues

#### System Slow After Installation

**Solution**: Check for pending updates
```bash
sudo apt update
sudo apt upgrade
sudo apt autoremove
```

#### High CPU Usage

```bash
# Check what's using CPU
top
# Press 'q' to quit

# Or use htop (more user-friendly)
sudo apt install htop
htop
```

---

## Getting Help

### Resources

- **Documentation**: https://github.com/companionintelligence/CI-OS
- **Issue Tracker**: https://github.com/companionintelligence/CI-OS/issues
- **Website**: https://ci.computer

### Community Support

Report issues on GitHub with:
- CI-OS version (`cat /etc/os-release`)
- Hardware info (`lspci`, `lscpu`)
- Error messages
- Steps to reproduce

### Logs

Useful logs for troubleshooting:
```bash
# System log
sudo journalctl -b

# Kernel messages
sudo dmesg

# Display server
cat ~/.local/share/xorg/Xorg.0.log
```

---

© Companion Intelligence — Lifescope Inc

**No ads. No surveillance. Sovereign computing.**
