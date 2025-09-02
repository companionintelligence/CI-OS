# Changelog

All notable changes to CI OS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v01-2024.12] - 2024-12-02

### Changed - Complete redesign to ISO-based approach
- **BREAKING**: Removed all container-based approach per user request
- **NEW**: Redesigned as bootable ISO distribution based on Bazzite
- **NEW**: Two variants: Regular CI-OS and NVIDIA CI-OS
- **NEW**: Full GitHub Actions workflow for automated ISO building
- **NEW**: Signed container images with cosign
- **NEW**: Weekly automated builds with GitHub Releases
- **NEW**: Container-to-ISO conversion using jasonn3/build-container-installer

### Added - ISO v01 Features
- **Bootable ISOs**: Ready-to-install images based on Bazzite Fedora 41
- **Two Containerfiles**: Regular and NVIDIA variants for container image building
- **GitHub Actions**: Automated ISO building, signing, and release publishing
- **Build Scripts**: Local container building with `./scripts/build-iso.sh`
- **Just Commands**: Complete setup automation with `ujust` integration
- **Wine Stack**: Pre-configured Wine with 32-bit libraries and winetricks
- **Proton Integration**: Protontricks and Proton tools included
- **WinApps Ready**: Full virtualization stack for seamless Windows app integration
- **NVIDIA Support**: Dedicated NVIDIA variant with GPU optimizations
- **Documentation**: Comprehensive ISO build guide and user documentation

### Removed - Container-only approach
- Removed Containerfile-only approach (now used for ISO base image creation)
- Removed build-containerfile.sh script (replaced with build-iso.sh)
- Removed container-specific documentation (replaced with ISO documentation)

### Technical Details - ISO Creation Process
- Container images serve as base for ISO creation via GitHub Actions
- ISOs include complete Bazzite gaming environment plus Windows app support
- Automatic weekly builds ensure fresh releases with latest security updates
- Signed container images for security and verification
- GitHub Releases with checksums for integrity verification

## [Unreleased - Previous Container Approach]

### Added - Initial container implementation (removed per user request)
- **Containerfile (v0)**: Bazzite-based container approach for modern Linux gaming/development
- **Wine/Proton Integration**: Complete Windows application support with Wine stack and Proton tools
- **WinApps Support**: Seamless Windows app integration using KVM/libvirt backend
- **ujust Automation**: First-boot helper commands for Wine, Proton, and WinApps setup  
- **Build Automation**: Container build scripts and comprehensive documentation
- Initial project structure and documentation
- Cubic customization plan and build scripts
- CI OS branding and visual assets
- Comprehensive setup scripts for development, gaming, and AMD GPU support
- Automated testing framework
- Contributing guidelines and code of conduct

### Removed
- N/A (Initial release)

### Fixed
- N/A (Initial release)

### Security
- N/A (Initial release)

## [1.0.0] - TBD

### Added
- Ubuntu 24.04 LTS base system
- Pre-configured development environment
  - Docker and Docker Compose
  - Node.js, npm, yarn, pnpm
  - Python 3.12 with pip and venv
  - Git, build-essential, development tools
  - Visual Studio Code
  - PostgreSQL database
- Gaming support
  - Steam with Proton integration
  - GameMode for performance optimization
  - MangoHud for system monitoring
  - Graphics drivers for NVIDIA and AMD
  - Vulkan support
- CI/CD tools
  - PM2 process manager
  - SSH server with secure configuration
  - UFW firewall with default rules
  - System monitoring tools
- Security features
  - Hardened SSH configuration
  - Fail2ban for intrusion prevention
  - Automatic security updates
  - User privilege management
- Custom branding
  - CI OS logos and icons
  - Custom wallpapers
  - GRUB bootloader customization
  - Desktop environment theming
- Documentation
  - Installation guide
  - Cubic customization plan
  - User manual
  - Troubleshooting guide
- Build automation
  - Automated build scripts
  - Testing framework
  - Quality assurance tools

### Technical Specifications
- **Base**: Ubuntu 24.04 LTS Desktop
- **Architecture**: x86_64 (AMD64)
- **ISO Size**: ~4.5GB
- **Installation Time**: 15-20 minutes
- **Boot Time**: <30 seconds
- **Memory Usage**: ~1.5GB idle
- **Minimum Requirements**: 4GB RAM, 25GB disk space

### Package Highlights
- **Development**: build-essential, git, curl, wget, vim, nano, htop, tree
- **Containers**: docker.io, docker-compose
- **Languages**: nodejs, npm, python3, python3-pip, python3-venv
- **Databases**: postgresql, postgresql-contrib, sqlite3
- **Security**: openssh-server, ufw, fail2ban, rsync
- **Gaming**: steam-installer, gamemode, mangohud
- **Graphics**: mesa-vulkan-drivers, linux-firmware
- **Virtualization**: qemu-kvm, libvirt-daemon-system, virt-manager
- **Monitoring**: glances, iotop, iftop, nethogs

---

## Release Notes Template

### Version X.Y.Z - YYYY-MM-DD

#### 🎉 Highlights
- Major feature or improvement summary

#### 🚀 New Features
- Feature 1: Description
- Feature 2: Description

#### 🛠️ Improvements
- Improvement 1: Description
- Improvement 2: Description

#### 🐛 Bug Fixes
- Fix 1: Description
- Fix 2: Description

#### 🔒 Security Updates
- Security update 1: Description
- Security update 2: Description

#### 📦 Package Updates
- Package 1: Version X.Y.Z → X.Y.Z
- Package 2: Version X.Y.Z → X.Y.Z

#### ⚠️ Breaking Changes
- Breaking change 1: Description and migration guide
- Breaking change 2: Description and migration guide

#### 📝 Documentation
- Documentation update 1: Description
- Documentation update 2: Description

#### 🙏 Contributors
- @username1 - Contribution description
- @username2 - Contribution description

#### 📊 Statistics
- Download count: X,XXX
- Installation success rate: XX%
- Community feedback score: X.X/5

---

## Version History

- **1.0.0** - Initial release (TBD)
- **0.9.0** - Release candidate (TBD)
- **0.8.0** - Beta release (TBD)
- **0.7.0** - Alpha release (TBD)
