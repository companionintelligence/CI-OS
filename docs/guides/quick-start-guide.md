# CI-OS Quick Start Guide

Get up and running with CI-OS in minutes.

© Companion Intelligence — Lifescope Inc

---

## Installation (5 Steps)

### 1. Download

Get CI-OS from: https://github.com/companionintelligence/CI-OS/releases

Download:
- `companion-os-1.0-amd64.iso`
- `SHA256SUMS`

### 2. Verify

```bash
sha256sum -c SHA256SUMS
```

Should show: `companion-os-1.0-amd64.iso: OK`

### 3. Create Bootable USB

**Linux/macOS:**
```bash
sudo dd if=companion-os-1.0-amd64.iso of=/dev/sdX bs=4M status=progress
# Replace /dev/sdX with your USB device
```

**Windows:** Use [Rufus](https://rufus.ie) or [Etcher](https://www.balena.io/etcher)

### 4. Boot and Install

1. Boot from USB
2. Select "Install CI-OS"
3. Follow installer (choose language, keyboard, disk)
4. Create user account
5. Wait for installation (15-25 min)
6. Restart

### 5. First Boot Setup

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Check CI-OS info
ci-os-info

# Install AMD ROCm (if you have AMD GPU)
sudo ci-os-install-rocm
```

**Done!** You're running CI-OS.

---

## Key Features

### What's Included

✅ **Based on Ubuntu 24.04 LTS** - Solid, stable foundation  
✅ **No Telemetry** - Privacy-first, no tracking  
✅ **AMD GPU Support** - ROCm 7.2+ ready for AI workloads  
✅ **Developer Tools Ready** - Docker, Node.js, VS Code, Ollama  
✅ **Custom Branding** - Dark green CI theme  
✅ **Secure Boot Compatible** - Works with modern systems

### What's Removed

❌ Ubuntu telemetry services  
❌ Snap Store (use apt, flatpak, or snap CLI)  
❌ Default games and bloatware  
❌ Ads and tracking

---

## Common Commands

### System Info

```bash
# CI-OS version and GPU info
ci-os-info

# Detailed system info
neofetch   # or: screenfetch
```

### Updates

```bash
# Update package lists
sudo apt update

# Upgrade packages
sudo apt upgrade

# Clean up
sudo apt autoremove
```

### AMD GPU

```bash
# Install ROCm
sudo ci-os-install-rocm

# Check GPU
lspci | grep -i vga

# ROCm info (after install)
rocminfo
```

### Package Management

```bash
# Install from apt
sudo apt install package-name

# Search for packages
apt search keyword

# Install snap
sudo snap install package-name

# Install flatpak
flatpak install flathub com.example.App
```

---

## Quick Troubleshooting

### Display Issues

```bash
# Install proprietary GPU drivers
sudo ubuntu-drivers autoinstall
sudo reboot
```

### WiFi Not Working

```bash
# Install firmware
sudo apt install linux-firmware
sudo reboot
```

### System Slow

```bash
# Check what's running
htop   # Install with: sudo apt install htop

# Check disk space
df -h
```

### AMD GPU Not Working

```bash
# Check if driver loaded
lsmod | grep amdgpu

# Load driver
sudo modprobe amdgpu

# Install ROCm
sudo ci-os-install-rocm
```

---

## Development Setup

### Quick Dev Stack

```bash
# Run full setup script (from the repository root)
sudo ./scripts/setup-fresh-ubuntu.sh
```

This installs:
- Docker & Docker Compose
- Node.js (via asdf)
- Bun runtime
- Ollama (local AI)
- GitHub CLI
- VS Code
- PostgreSQL tools

### Manual Installs

**Docker:**
```bash
sudo apt install docker.io
sudo usermod -aG docker $USER
# Log out and back in
```

**Node.js:**
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
source ~/.bashrc
nvm install --lts
```

**VS Code:**
```bash
sudo snap install code --classic
```

---

## Keyboard Shortcuts

### System

- `Ctrl + Alt + T` - Open Terminal
- `Super` (Windows key) - Activities Overview
- `Super + L` - Lock Screen
- `Alt + F2` - Run Command
- `Super + A` - Show Applications
- `Alt + Tab` - Switch Windows
- `Super + Arrow Keys` - Tile Windows

### Terminal

- `Ctrl + Shift + T` - New Tab
- `Ctrl + Shift + W` - Close Tab
- `Ctrl + Shift + C` - Copy
- `Ctrl + Shift + V` - Paste
- `Ctrl + L` - Clear Screen
- `Ctrl + C` - Cancel Command

---

## Customization

### Wallpaper

System Settings → Appearance → Background

### Themes

```bash
sudo apt install gnome-tweaks
```

Launch "Tweaks" for advanced customization.

### Extensions

Visit: https://extensions.gnome.org

Recommended:
- Dash to Dock
- User Themes
- Caffeine

---

## System Requirements

### Minimum

- **CPU**: 64-bit x86
- **RAM**: 4GB
- **Storage**: 25GB
- **Display**: 1024x768

### Recommended (for AI)

- **CPU**: AMD Ryzen 5 5600+
- **RAM**: 16GB+
- **Storage**: 100GB SSD
- **GPU**: AMD Radeon RX 5000+

---

## Getting Help

**Documentation**: https://github.com/companionintelligence/CI-OS  
**Issues**: https://github.com/companionintelligence/CI-OS/issues  
**Website**: https://ci.computer

### Useful Commands for Bug Reports

```bash
# OS version
cat /etc/os-release

# Kernel version
uname -a

# Hardware info
lscpu
lspci
lsusb

# System logs
sudo journalctl -b > system-log.txt
```

---

## What's Next?

### For Developers

1. **Clone Your Projects**
   ```bash
   git clone https://github.com/username/repo.git
   cd repo
   ```

2. **Set Up Your Tools**
   ```bash
   # Install language-specific tools
   sudo apt install python3-pip python3-venv
   pip3 install virtualenv
   ```

3. **Start Coding**
   ```bash
   code .   # Open VS Code in current directory
   ```

### For AI/ML Work

1. **Verify GPU**
   ```bash
   ci-os-info
   ```

2. **Install ROCm**
   ```bash
   sudo ci-os-install-rocm
   ```

3. **Install ML Frameworks**
   ```bash
   pip3 install torch torchvision --index-url https://download.pytorch.org/whl/rocm5.7
   ```

4. **Try Local AI**
   ```bash
   ollama run llama2
   ```

### For General Use

1. **Install Your Apps**
   ```bash
   # Examples
   sudo apt install vlc gimp inkscape libreoffice
   flatpak install flathub com.spotify.Client
   ```

2. **Configure Backups**
   - Timeshift (system)
   - Deja Dup (user files)

3. **Enjoy Your Privacy-First OS!**

---

## Tips & Tricks

### Speed Up apt Updates

```bash
# Use fastest mirror
sudo apt install apt-fast
```

### Better Terminal

```bash
# Install zsh + oh-my-zsh
sudo apt install zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
```

### Disk Usage Analyzer

```bash
# Visual disk usage
sudo apt install baobab
baobab
```

### System Monitor

```bash
# Install better system monitor
sudo apt install gnome-system-monitor
```

### Firewall

```bash
# Enable firewall
sudo ufw enable

# Allow specific ports
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Check status
sudo ufw status
```

---

## Security Best Practices

1. **Keep System Updated**
   ```bash
   sudo apt update && sudo apt upgrade
   ```

2. **Enable Firewall**
   ```bash
   sudo ufw enable
   ```

3. **Use Strong Passwords**
   - Min 12 characters
   - Mix letters, numbers, symbols

4. **Enable Automatic Security Updates**
   ```bash
   sudo apt install unattended-upgrades
   sudo dpkg-reconfigure -plow unattended-upgrades
   ```

5. **Backup Regularly**
   - Use Timeshift for system
   - Use rsync or Deja Dup for files

---

## Welcome to CI-OS!

**No ads. No surveillance. Sovereign computing.**

Enjoy your freedom. Build amazing things. 🚀

© Companion Intelligence — Lifescope Inc
