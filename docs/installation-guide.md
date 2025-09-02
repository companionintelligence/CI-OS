# CI-OS v01 Installation Guide

Complete guide for installing and setting up CI-OS on your system.

## Download CI-OS

### Available Variants

**CI-OS Regular** (Recommended for most users)
- Based on Bazzite Fedora 41 with KDE Plasma
- Wine, Proton, and WinApps support
- Size: ~4GB ISO
- Suitable for: Gaming and general-purpose systems

**CI-OS NVIDIA** (For NVIDIA GPU users)
- All features of Regular + NVIDIA driver optimizations
- GPU acceleration for Wine and WinApps
- CUDA toolkit included
- Size: ~4.2GB ISO
- Suitable for: Systems with NVIDIA graphics cards

### Download Links

1. Visit [GitHub Releases](https://github.com/companionintelligence/CI-OS/releases)
2. Download the latest release
3. Choose your variant:
   - `CI-OS-v01-regular-41.iso` - Regular variant
   - `CI-OS-v01-nvidia-41.iso` - NVIDIA variant

### Verification

Verify your download integrity:

```bash
# Download checksum file
wget https://github.com/companionintelligence/CI-OS/releases/download/v01-YYYYMMDD/CI-OS-v01-regular-41.iso-CHECKSUM

# Verify checksum
sha256sum -c CI-OS-v01-regular-41.iso-CHECKSUM
```

## System Requirements

### Minimum Requirements
- **CPU**: 64-bit x86 processor (Intel/AMD)
- **RAM**: 4GB (8GB recommended)
- **Storage**: 25GB free space (50GB recommended)
- **Graphics**: Any GPU with OpenGL 3.0+ support

### Recommended Requirements
- **CPU**: Quad-core processor (Intel i5/AMD Ryzen 5 or better)
- **RAM**: 16GB for optimal Wine/WinApps performance
- **Storage**: 100GB+ SSD for best performance
- **Graphics**: Dedicated GPU (NVIDIA GTX 1060+ or AMD RX 580+)

### NVIDIA Systems
- **GPU**: NVIDIA GTX 900 series or newer
- **VRAM**: 4GB+ for optimal gaming performance
- **Driver**: Automatically installed with NVIDIA variant
- **Additional**: Secure Boot must be disabled for NVIDIA drivers

## Creating Installation Media

### Using Fedora Media Writer (Recommended)

1. **Download Fedora Media Writer**:
   - [Windows](https://getfedora.org/en/workstation/download/)
   - [macOS](https://getfedora.org/en/workstation/download/)
   - Linux: `sudo dnf install mediawriter`

2. **Create USB Drive**:
   - Open Fedora Media Writer
   - Select "Custom Image"
   - Choose your downloaded CI-OS ISO
   - Select target USB drive (8GB+ recommended)
   - Click "Write"

### Using dd (Linux/macOS)

```bash
# Find USB device
lsblk

# Write ISO to USB (replace /dev/sdX with your USB device)
sudo dd if=CI-OS-v01-regular-41.iso of=/dev/sdX bs=4M status=progress sync

# Ensure write completion
sync
```

### Using Rufus (Windows)

1. Download [Rufus](https://rufus.ie/)
2. Select your USB drive
3. Choose CI-OS ISO file
4. Use "DD Image" mode (important!)
5. Click "START"

## Installation Process

### 1. Boot from USB

1. **Insert USB drive** into target computer
2. **Boot from USB**:
   - Restart computer
   - Press F12, F8, or DEL (varies by manufacturer)
   - Select USB drive from boot menu
3. **NVIDIA Systems**: If you have black screen, try:
   - Add `nomodeset` to kernel parameters
   - Press 'e' on GRUB menu and add `nomodeset` to kernel line

### 2. CI-OS Live Environment

1. **Boot Options**:
   - "Start CI-OS" - Normal live environment
   - "Start CI-OS (Safe Graphics)" - If you have display issues
   - "Test media & start CI-OS" - Verify ISO integrity first

2. **Live Environment**:
   - CI-OS boots to KDE Plasma desktop
   - Test hardware compatibility
   - Connect to WiFi if needed
   - All features available for testing

### 3. Start Installation

1. **Open Installer**: Double-click "Install to Hard Drive" on desktop
2. **Language Selection**: Choose your language and region
3. **Installation Summary**: Configure installation options

### 4. Installation Configuration

#### Storage Configuration
- **Automatic**: Let installer partition disk automatically
- **Custom**: Advanced users can create custom partitions
- **Minimum Partitions**:
  - `/boot/efi`: 512MB (UEFI systems)
  - `/`: 25GB+ (root filesystem)
  - `swap`: 2-4GB (optional, for hibernation)

#### User Account
- **Full Name**: Your display name
- **Username**: Login name (lowercase, no spaces)
- **Password**: Strong password for your account
- **Administrator**: Check to give sudo privileges

#### Network & Time
- **Hostname**: Computer name on network
- **Timezone**: Automatic or manual selection
- **Network**: Wired/wireless configuration

### 5. Complete Installation

1. **Begin Installation**: Click "Begin Installation"
2. **Installation Progress**: 15-30 minutes depending on system
3. **Completion**: Reboot when prompted
4. **Remove USB**: Take out installation media

## First Boot Setup

### 1. Initial Boot

1. **GRUB Menu**: Select CI-OS (first option)
2. **Login Screen**: Use credentials created during installation
3. **Welcome Wizard**: Complete KDE first-run setup

### 2. System Updates

```bash
# Update system packages
rpm-ostree upgrade

# Reboot to apply updates
systemctl reboot
```

### 3. CI-OS Configuration

Run the CI-OS setup wizard:

```bash
# Complete setup wizard (recommended)
ujust setup-ci-os

# Or step-by-step setup
ujust setup-wine        # Configure Wine environment
ujust setup-proton      # Install Proton tools
ujust setup-winapps     # Set up WinApps VM (optional)
```

**NVIDIA Systems**:
```bash
# NVIDIA-optimized setup
ujust setup-ci-os-nvidia

# Verify NVIDIA status
ujust nvidia-info
```

### 4. Essential Software

Install additional software via Software Center (Discover) or command line:

```bash
# Gaming platforms
flatpak install flathub com.valvesoftware.Steam
flatpak install flathub net.lutris.Lutris

# Media and productivity
flatpak install flathub org.mozilla.firefox
flatpak install flathub org.libreoffice.LibreOffice
flatpak install flathub org.videolan.VLC

# Development tools
flatpak install flathub com.visualstudio.code
flatpak install flathub com.jetbrains.IntelliJ-IDEA-Community
```

## Post-Installation Configuration

### Wine Setup

```bash
# Configure Wine environment
ujust setup-wine

# Test Wine installation
ujust test-wine

# Install Windows software
ujust wine-install vcrun2019 dotnet48 corefonts

# Run Windows applications
ujust run-wine notepad.exe
wine /path/to/your/application.exe
```

### Gaming Setup

```bash
# Configure Proton for Steam games
ujust setup-proton

# List Steam games for configuration
ujust proton-games

# Configure specific game
ujust proton-config 292030  # The Witcher 3 example

# Gaming performance optimizations
ujust optimize-proton-gaming
```

### WinApps (Windows VM Integration)

```bash
# Set up WinApps infrastructure
ujust setup-winapps

# Configure connection to Windows VM
ujust configure-winapps

# Test connectivity
ujust test-winapps

# Install Windows applications
ujust winapps-install cmd
ujust winapps-install explorer
```

### NVIDIA Optimizations

```bash
# Apply NVIDIA gaming optimizations
ujust optimize-nvidia-gaming

# Monitor GPU performance
ujust nvidia-monitor

# Test NVIDIA functionality
ujust test-nvidia

# Troubleshoot issues
ujust nvidia-troubleshoot
```

## Troubleshooting

### Boot Issues

**Black Screen on Boot (NVIDIA)**:
1. Add `nomodeset` to kernel parameters
2. Boot to desktop and run `ujust setup-ci-os-nvidia`
3. Reboot normally

**Can't Boot from USB**:
1. Verify USB creation method (use DD mode)
2. Try different USB port
3. Disable Secure Boot in BIOS
4. Enable Legacy/CSM mode if using old hardware

### Installation Issues

**Installation Hangs**:
1. Test ISO integrity first
2. Check RAM with memtest86+
3. Try safe graphics mode
4. Verify minimum system requirements

**Storage Issues**:
1. Ensure 25GB+ free space
2. Disable fast startup on dual-boot Windows systems
3. Use custom partitioning for complex setups

### Post-Install Issues

**Wine Not Working**:
```bash
# Reinstall Wine
ujust wine-reset
ujust setup-wine

# Check Wine status
ujust test-wine
wine --version
```

**Steam/Gaming Issues**:
```bash
# Verify Proton setup
ujust test-proton

# Reinstall gaming optimizations
ujust optimize-proton-gaming

# Check graphics drivers
inxi -G
```

**WinApps Issues**:
```bash
# Check virtualization support
grep -E '(vmx|svm)' /proc/cpuinfo

# Verify KVM
lsmod | grep kvm

# Test connectivity
ujust test-winapps
```

## Advanced Configuration

### Dual Boot with Windows

1. **Install Windows First**: Always install Windows before CI-OS
2. **Shrink Windows Partition**: Use Windows Disk Management
3. **Install CI-OS**: Choose custom partitioning
4. **GRUB Configuration**: Automatically detects Windows

### Custom Kernels

```bash
# List available kernels
rpm-ostree status

# Switch to different kernel
rpm-ostree rebase fedora:fedora/41/x86_64/kinoite

# Custom kernel parameters
sudo grubby --update-kernel=ALL --args="nouveau.modeset=0"
```

### System Maintenance

```bash
# Update system
rpm-ostree upgrade

# Clean up old deployments
rpm-ostree cleanup -m

# Check system status
ujust ci-os-info

# View system logs
journalctl -f
```

## Support Resources

### Getting Help

1. **GitHub Issues**: [Report problems](https://github.com/companionintelligence/CI-OS/issues)
2. **Bazzite Community**: [Gaming support](https://bazzite.gg/)
3. **Wine Support**: [Wine HQ](https://www.winehq.org/)
4. **Universal Blue**: [Immutable OS help](https://universal-blue.org/)

### Documentation

- [Quick Start Guide](quick-start-guide.md)
- [Build Guide](iso-build-guide.md)
- [CI-OS Commands Reference](../README.md#available-commands)

### Community

- **Discord**: Join CI-OS community discussions
- **Matrix**: Universal Blue community chat
- **Reddit**: r/Bazzite for gaming-specific topics

## Uninstallation

### Remove CI-OS Only

If dual-booting, use Windows boot repair:

1. Boot Windows installation media
2. Select "Repair your computer"
3. Choose "Command Prompt"
4. Run: `bootrec /fixmbr && bootrec /fixboot`
5. Remove CI-OS partitions with Disk Management

### Complete System Wipe

1. Boot from any Linux live USB
2. Use `gparted` or `fdisk` to delete all partitions
3. Create new partition table
4. Install desired operating system

---

**Welcome to CI-OS!** 🎮🍷💻

Your system is now ready for gaming, productivity, and seamless Windows application compatibility.