# CI-OS v01 Quick Start Guide

Get up and running with CI-OS in 10 minutes! This guide covers the essentials for a fast start.

## 🚀 Quick Installation

### 1. Download CI-OS ISO

Choose your variant:
- **Regular**: [CI-OS-v01-regular-41.iso](https://github.com/companionintelligence/CI-OS/releases) - For most users
- **NVIDIA**: [CI-OS-v01-nvidia-41.iso](https://github.com/companionintelligence/CI-OS/releases) - For NVIDIA GPU users

### 2. Create Bootable USB

**Windows**: Use [Rufus](https://rufus.ie/) with DD Image mode  
**Linux**: `sudo dd if=CI-OS-v01-regular-41.iso of=/dev/sdX bs=4M status=progress`  
**macOS**: Use [Fedora Media Writer](https://getfedora.org/en/workstation/download/)

### 3. Install CI-OS

1. Boot from USB drive
2. Double-click "Install to Hard Drive"
3. Follow installation wizard (20-30 minutes)
4. Reboot and remove USB

## ⚡ Essential Setup (5 minutes)

### First Boot

```bash
# Run complete setup wizard
ujust setup-ci-os

# For NVIDIA systems
ujust setup-ci-os-nvidia
```

This configures Wine, Proton, and WinApps automatically!

### Verify Installation

```bash
# Check system status
ujust ci-os-info

# Test Wine
wine --version

# Test Proton (requires Steam)
ujust test-proton
```

## 🍷 Running Windows Apps

### Method 1: Direct Wine

```bash
# Run any Windows .exe file
ujust run-wine notepad.exe
ujust run-wine /path/to/installer.exe

# Configure Wine
ujust configure-wine
```

### Method 2: WinApps (VM-based)

```bash
# Set up Windows VM integration
ujust setup-winapps

# Configure connection
ujust configure-winapps

# Install Windows apps
ujust winapps-install cmd
ujust winapps-install explorer
```

## 🎮 Gaming Quick Start

### Steam Setup

```bash
# Install Steam
flatpak install flathub com.valvesoftware.Steam

# Configure Proton
ujust setup-proton

# Apply gaming optimizations
ujust optimize-proton-gaming
```

### Non-Steam Games

```bash
# Install Lutris
flatpak install flathub net.lutris.Lutris

# Set up Proton for Lutris
ujust proton-lutris
```

## 🔧 Essential Commands

### System Information
```bash
ujust ci-os-info              # System overview
ujust nvidia-info            # NVIDIA status (NVIDIA variant)
```

### Wine Management
```bash
ujust setup-wine              # Initial Wine setup
ujust test-wine               # Test Wine functionality
ujust wine-install vcrun2019  # Install Windows components
ujust wine-reset              # Reset Wine environment
```

### Gaming Optimization
```bash
ujust optimize-proton-gaming  # Gaming performance tweaks
ujust nvidia-monitor          # GPU monitoring (NVIDIA)
ujust proton-games            # List Steam games
```

### WinApps Management
```bash
ujust setup-winapps           # VM infrastructure setup
ujust test-winapps            # Test connectivity
ujust list-winapps            # Show installed apps
```

## 📦 Installing Software

### Via Software Center (Discover)
- Open "Discover" from application menu
- Browse Flatpaks and native packages
- Install with one click

### Via Command Line
```bash
# Flatpak applications
flatpak install flathub org.mozilla.firefox
flatpak install flathub org.libreoffice.LibreOffice
flatpak install flathub com.visualstudio.code

# System packages (requires reboot)
rpm-ostree install htop neofetch
systemctl reboot
```

## 🔍 Troubleshooting Quick Fixes

### Wine Issues
```bash
# Reset and reconfigure Wine
ujust wine-reset
ujust setup-wine
```

### NVIDIA Issues (NVIDIA variant)
```bash
# Apply NVIDIA optimizations
ujust optimize-nvidia-gaming

# Check GPU status
ujust nvidia-info

# Troubleshoot problems
ujust nvidia-troubleshoot
```

### Performance Issues
```bash
# Check system resources
ujust ci-os-info

# Apply gaming optimizations
ujust optimize-proton-gaming
```

### Update System
```bash
# Update all packages
rpm-ostree upgrade
systemctl reboot
```

## 🎯 Common Use Cases

### Office Work
```bash
# Install LibreOffice
flatpak install flathub org.libreoffice.LibreOffice

# Run Windows Office via Wine
ujust wine-install vcrun2019 dotnet48
ujust run-wine /path/to/office-installer.exe
```

### Gaming Setup
```bash
# Complete gaming stack
flatpak install flathub com.valvesoftware.Steam
flatpak install flathub net.lutris.Lutris
ujust setup-proton
ujust optimize-proton-gaming
```

### Development Environment
```bash
# Development tools
flatpak install flathub com.visualstudio.code
flatpak install flathub com.jetbrains.IntelliJ-IDEA-Community
rpm-ostree install git nodejs npm python3-pip
systemctl reboot
```

### Media Production
```bash
# Creative applications
flatpak install flathub org.blender.Blender
flatpak install flathub org.kde.kdenlive
flatpak install flathub org.gimp.GIMP

# Windows creative apps via Wine
ujust wine-install vcrun2019 d3dx9
ujust run-wine /path/to/creative-app.exe
```

## 📚 Next Steps

### Learn More
- [Complete Installation Guide](installation-guide.md) - Detailed installation
- [Build Guide](iso-build-guide.md) - Building custom ISOs
- [Main README](../README.md) - Full feature documentation

### Get Support
- 🐛 [Report Issues](https://github.com/companionintelligence/CI-OS/issues)
- 💬 [Bazzite Community](https://bazzite.gg/)
- 📖 [Wine Documentation](https://www.winehq.org/documentation)

### Advanced Topics
- Dual-booting with Windows
- Custom kernel configurations
- Building custom variants
- VM and container management

## 🎉 Welcome to CI-OS!

You're now ready to enjoy:
- 🎮 **Gaming**: Steam, Lutris, and Windows games
- 💼 **Productivity**: Wine and native Linux applications  
- 🖥️ **Virtualization**: Seamless Windows VM integration
- 🚀 **Performance**: NVIDIA optimizations and gaming kernel

**Tip**: Run `just --list` to see all available commands anytime!

---

**Happy computing!** 🎮🍷💻