# CI OS Installation Guide

## Prerequisites
- 4GB+ USB drive or DVD
- 4GB+ RAM (8GB+ recommended)
- 25GB+ free disk space
- AMD or NVIDIA graphics card (for gaming features)
- Internet connection for updates

## Installation Methods

### Method 1: Standard Installation
1. Boot from CI OS USB/DVD
2. Select "Install CI OS"
3. Follow the installation wizard
4. Choose installation type (minimal, full, gaming)
5. Configure user account
6. Complete installation and reboot

### Method 2: Automated Installation
1. Boot from CI OS USB/DVD
2. Select "Automated Install"
3. System will install with preset configurations
4. Default user: `cios` / password: `ci0s2024!`
5. Automatic reboot after completion

## Post-Installation Setup

### 1. System Updates
```bash
sudo apt update && sudo apt upgrade -y
```

### 2. Development Environment
```bash
# Run the development setup script
sudo ./scripts/ci-server-linux-dev-setup.sh
```

### 3. Gaming Setup (Optional)
```bash
# Run the gaming setup script
sudo ./scripts/setup-gaming.sh
```

### 4. AMD GPU Setup
```bash
# Run the AMD-specific setup script
sudo ./scripts/ci-server-setup-ubuntu-amd.sh
```

## Features

### Development Tools
- Docker and Docker Compose
- Node.js, npm, yarn, pnpm
- Python 3.12 with pip and venv
- Git, build-essential, development headers
- Visual Studio Code
- PostgreSQL database

### CI/CD Tools
- PM2 process manager
- SSH server configured
- Firewall (UFW) enabled
- Fail2ban for security

### Gaming Support
- Steam with Proton
- GameMode for performance
- MangoHud for monitoring
- GPU drivers (NVIDIA/AMD)
- Vulkan support

### System Administration
- SSH server with secure configuration
- UFW firewall with sensible defaults
- Automatic security updates
- System monitoring tools (htop, iotop, etc.)

## Default Credentials
- **Username:** cios
- **Password:** ci0s2024!
- **Root:** Disabled (use sudo)

## Network Configuration
- SSH: Port 22 (enabled)
- HTTP: Port 80 (allowed)
- HTTPS: Port 443 (allowed)
- UFW: Enabled with default deny incoming

## Troubleshooting

### Boot Issues
1. Verify ISO integrity with checksums
2. Check BIOS/UEFI boot order
3. Disable Secure Boot if necessary
4. Try different USB creation tools

### Graphics Issues
1. Install proprietary drivers after installation
2. Check X11 configuration
3. Update kernel and drivers
4. Switch to integrated graphics temporarily

### Network Issues
1. Check network manager status
2. Verify firewall rules
3. Test with wired connection first
4. Update network drivers

## Support
- GitHub Issues: https://github.com/your-org/ci-os/issues
- Documentation: https://github.com/your-org/ci-os/wiki
- Community Forum: [To be created]

## License
CI OS is based on Ubuntu and follows the same licensing terms.
