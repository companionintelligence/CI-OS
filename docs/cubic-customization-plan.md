# CI OS Cubic Customization Plan

## Overview
This document outlines the complete plan for creating CI OS, a custom Ubuntu distribution optimized for continuous integration, development, and gaming workloads using Cubic (Custom Ubuntu ISO Creator).

## Project Structure
```
ci-os/
├── assets/                     # Branding and visual assets
│   ├── logos/                  # CI OS logos in various formats
│   ├── icons/                  # Application and system icons
│   ├── wallpapers/            # Desktop wallpapers
│   └── branding/              # Brand guidelines and assets
├── cubic-project/             # Cubic project files and workspace
├── scripts/                   # Post-installation and setup scripts
│   ├── ci-server-setup-ubuntu-amd.sh
│   ├── ci-server-linux-dev-setup.sh
│   └── setup-gaming.sh
├── configs/                   # Configuration files for customization
│   ├── packages/              # Package lists and selections
│   ├── preseed/               # Automated installation configs
│   ├── boot/                  # Boot configuration and GRUB settings
│   └── scripts/               # Customization scripts for Cubic
├── docs/                      # Documentation
├── iso/                       # ISO storage
│   ├── base/                  # Original Ubuntu ISOs
│   └── output/                # Generated CI OS ISOs
└── README.md
```

## Phase 1: Environment Setup

### 1.1 Install Cubic
Follow the installation instructions for your platform:

**Ubuntu and Derivatives:**
```bash
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys B7579F80E494ED3406A59DF9081525E2B4F1283B
sudo apt-add-repository universe
sudo apt-add-repository ppa:cubic-wizard/release
sudo apt update
sudo apt install --no-install-recommends cubic
```

**Debian and Derivatives:**
```bash
echo "deb https://ppa.launchpadcontent.net/cubic-wizard/release/ubuntu/ noble main" | sudo tee /etc/apt/sources.list.d/cubic-wizard-release.list
curl -S "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x081525e2b4f1283b" | sudo gpg --batch --yes --dearmor --output /etc/apt/trusted.gpg.d/cubic-wizard-ubuntu-release.gpg
sudo apt update
sudo apt install --no-install-recommends cubic
```

### 1.2 Download Base Ubuntu ISO
Download Ubuntu 24.04 LTS Desktop ISO from:
- https://ubuntu.com/download/desktop
- Place in `iso/base/` directory

## Phase 2: Cubic Project Setup

### 2.1 Create New Cubic Project
1. Launch Cubic
2. Create new project in `cubic-project/` directory
3. Select base Ubuntu ISO from `iso/base/`
4. Set custom ISO filename: `ci-os-24.04-desktop-amd64.iso`
5. Set output directory to `iso/output/`

### 2.2 Project Configuration
- **Project Name:** CI OS 24.04 LTS
- **ISO Volume ID:** CI-OS-24-04
- **ISO Application:** CI OS Linux Distribution
- **ISO Publisher:** CI OS Team

## Phase 3: System Customization

### 3.1 Package Management
1. **Remove Unwanted Packages:**
   - Games (solitaire, mines, etc.)
   - Unnecessary office applications
   - Redundant media players

2. **Add Required Packages:**
   ```bash
   # Development tools
   apt install build-essential git curl wget vim nano htop tree
   
   # CI/CD tools
   apt install docker.io docker-compose nodejs npm python3 python3-pip
   
   # System administration
   apt install openssh-server ufw fail2ban rsync
   
   # Gaming support
   apt install steam-installer gamemode mangohud
   
   # Hardware support
   apt install linux-firmware mesa-vulkan-drivers
   ```

### 3.2 Custom Scripts Integration
Copy and execute customization scripts:
1. Copy `configs/scripts/ci-os-customization.sh` to chroot environment
2. Execute script in Cubic terminal
3. Verify all packages installed correctly

### 3.3 User Account Configuration
1. Create default `cios` user account
2. Configure sudo privileges
3. Set up Docker group membership
4. Configure SSH access

## Phase 4: Visual Customization

### 4.1 Branding Integration
1. **Copy Brand Assets:**
   ```bash
   # Copy logos and icons
   cp assets/logos/* /usr/share/pixmaps/
   cp assets/icons/* /usr/share/icons/hicolor/scalable/apps/
   
   # Copy wallpapers
   cp assets/wallpapers/* /usr/share/backgrounds/
   ```

2. **Update System Branding:**
   - Replace Ubuntu logos with CI OS logos
   - Update GRUB bootloader branding
   - Customize Plymouth splash screen
   - Update desktop environment themes

### 4.2 Desktop Environment
1. **GNOME Configuration:**
   - Set CI OS wallpaper as default
   - Configure dock with relevant applications
   - Install and configure extensions
   - Set up custom shortcuts

2. **Application Menu:**
   - Create CI OS application categories
   - Pin essential development tools
   - Configure favorites bar

## Phase 5: Configuration Files

### 5.1 System Configuration
1. **SSH Configuration:**
   - Enable SSH server
   - Configure secure defaults
   - Set up key-based authentication

2. **Firewall Setup:**
   - Enable UFW
   - Configure default rules
   - Open necessary ports (22, 80, 443)

3. **Docker Configuration:**
   - Enable Docker service
   - Configure daemon settings
   - Set up Docker Compose

### 5.2 Development Environment
1. **Programming Languages:**
   - Python 3.12 with pip and venv
   - Node.js with npm, yarn, pnpm
   - Go, Rust (optional)

2. **IDEs and Editors:**
   - Visual Studio Code
   - Vim/Neovim configuration
   - Git configuration templates

## Phase 6: Testing and Validation

### 6.1 Virtual Machine Testing
1. Create VM with generated ISO
2. Test installation process
3. Verify all scripts execute correctly
4. Test gaming capabilities
5. Validate CI/CD tools functionality

### 6.2 Hardware Testing
1. Test on AMD systems
2. Verify GPU driver installation
3. Test gaming performance
4. Validate container functionality

## Phase 7: Documentation and Distribution

### 7.1 Documentation
1. Create user manual
2. Document installation process
3. Provide troubleshooting guide
4. Create video tutorials

### 7.2 Distribution
1. Upload to release repository
2. Create checksums and signatures
3. Announce release
4. Gather feedback

## Phase 8: Maintenance and Updates

### 8.1 Regular Updates
1. Monthly security updates
2. Quarterly feature releases
3. Annual LTS updates

### 8.2 Community Support
1. Issue tracking
2. Feature requests
3. Community contributions
4. Documentation updates

## Automation Scripts

### Build Script
Create `scripts/build-ci-os.sh` for automated builds:
```bash
#!/bin/bash
# Automated CI OS build script
set -e

# Download latest Ubuntu ISO
# Set up Cubic project
# Apply customizations
# Generate new ISO
# Test and validate
```

### Testing Script
Create `scripts/test-ci-os.sh` for automated testing:
```bash
#!/bin/bash
# Automated CI OS testing script
set -e

# Create test VM
# Install CI OS
# Run validation tests
# Generate test report
```

## Success Metrics
- Boot time under 30 seconds
- Full installation under 20 minutes
- All development tools functional
- Gaming performance equivalent to base Ubuntu
- Docker containers start within 5 seconds
- Zero critical security vulnerabilities

## Timeline
- **Week 1-2:** Environment setup and base customization
- **Week 3-4:** Branding and visual customization
- **Week 5-6:** Testing and validation
- **Week 7-8:** Documentation and release preparation

This plan provides a comprehensive roadmap for creating CI OS using Cubic, ensuring a professional, functional, and user-friendly custom Ubuntu distribution.
