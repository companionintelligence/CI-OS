# CI-OS Bazzite Customization Guide

This document outlines the complete approach for customizing Bazzite with CI-OS branding and dark green theming.

## Overview

CI-OS is now based on **Bazzite**, a Fedora-based immutable gaming operating system built on Universal Blue. This provides several advantages:

- **Immutable OS**: More stable and reliable than traditional distributions
- **Container-based customization**: Uses containerfiles (similar to Dockerfiles) for modifications
- **Gaming optimizations**: Built-in gaming tools and optimizations from Bazzite
- **Atomic updates**: Safe, rollback-capable system updates
- **KDE Plasma**: Modern desktop environment with excellent customization support

## Architecture

### Base System
- **Base Image**: `ghcr.io/ublue-os/bazzite:stable`
- **Package Manager**: rpm-ostree (immutable) + Flatpak (applications)
- **Desktop Environment**: KDE Plasma 6
- **Boot Manager**: systemd-boot (instead of GRUB)
- **Container Runtime**: Podman

### Customization Approach

Unlike traditional Linux distributions that require live CD/DVD tools like Cubic, Bazzite uses a **container-based build system**:

1. **Containerfile**: Defines the CI-OS customizations on top of Bazzite base
2. **Build Scripts**: Shell scripts that apply theming and branding
3. **Asset Integration**: Logos, wallpapers, and themes copied during build
4. **Container Registry**: Built images stored in GitHub Container Registry
5. **ISO Generation**: Container images converted to bootable ISOs

## Dark Green Theme Implementation

### Color Palette

The CI-OS dark green theme uses the following color scheme:

| Color | Hex Code | Usage |
|-------|----------|-------|
| Primary Green | `#066c80` | Main accent color, buttons, highlights |
| Secondary Green | `#00a9a7` | Secondary accents, links |
| Light Green | `#72ddd4` | Text highlights, selection |
| Enhanced Green | `#4ade80` | Success states, positive elements |
| Forest Green | `#0a4f3c` | Background gradients |
| Deep Green | `#1a6b3a` | Alternative backgrounds |
| Dark Background | `#1a1a1a` | Main dark background |
| Light Text | `#ffffff` | Primary text color |

### Theme Components

#### 1. KDE Plasma Theme
- **Color Scheme**: `CI-OS-DarkGreen.colors`
- **Plasma Theme**: `ci-os-dark-green`
- **Look and Feel**: `ci-os-dark-green`
- **Icon Replacements**: CI-OS logos replace distributor icons

#### 2. Boot Experience
- **Plymouth Theme**: Custom CI-OS boot splash with dark green gradients
- **GRUB Theme**: Dark green themed boot menu (if using GRUB)
- **systemd-boot**: CI-OS themed boot entries

#### 3. Desktop Experience
- **Wallpapers**: Multiple dark green themed wallpapers
- **Window Decorations**: Breeze theme with CI-OS colors
- **Panel Theming**: Dark green accents in KDE panels
- **Application Theming**: System-wide dark green color scheme

## File Structure

```
CI-OS/
├── Containerfile                    # Main build definition
├── .github/workflows/build-ci-os.yml  # CI/CD pipeline
├── assets/
│   ├── logos/                       # CI-OS logos and branding
│   │   ├── 2024_CI__LogoMark_Color_med.svg
│   │   ├── ci-holo-depth.png
│   │   ├── ci-holo-flat.png
│   │   └── ...
│   └── wallpapers/                  # Dark green themed wallpapers
│       ├── ci-os-wallpaper.svg
│       ├── ci-os-dark-green-1.svg
│       ├── ci-os-dark-green-2.svg
│       └── ...
├── configs/bazzite/
│   ├── etc/                         # System configuration overlays
│   └── usr/                         # User space configurations
└── scripts/bazzite/
    ├── apply-ci-os-theming.sh      # Main theming script
    ├── setup-dark-green-theme.sh  # KDE theme configuration
    └── configure-branding.sh      # System branding setup
```

## Build Process

### 1. Container Build

The CI-OS image is built using the `Containerfile`:

```bash
# Build locally
podman build -t ci-os:latest .

# Or use GitHub Actions for automated builds
```

### 2. Automatic Builds

GitHub Actions automatically builds CI-OS images when code is pushed:

- **Trigger**: Push to `main` or `develop` branches
- **Registry**: GitHub Container Registry (`ghcr.io`)
- **Tags**: Branch name, commit SHA, and `latest`
- **Artifacts**: Container images ready for deployment

### 3. ISO Generation (Future)

Future versions will include automatic ISO generation from container images:

```bash
# Example ISO generation (not yet implemented)
lorax --product="CI-OS" --version="1.0" \
      --release="Sage" --source=... \
      --installpkgs=... ci-os.iso
```

## Installation Methods

### Method 1: Container Image (Advanced Users)

```bash
# Pull the latest CI-OS image
podman pull ghcr.io/companionintelligence/ci-os:latest

# Rebase existing Bazzite system to CI-OS
rpm-ostree rebase ghcr.io/companionintelligence/ci-os:latest

# Reboot to CI-OS
systemctl reboot
```

### Method 2: ISO Installation (Coming Soon)

1. Download CI-OS ISO from releases
2. Create bootable USB drive
3. Boot from USB and install normally
4. First boot will show CI-OS branding and dark green theme

## Customization Scripts

### apply-ci-os-theming.sh

Main script that:
- Copies CI-OS logos to system locations
- Installs wallpapers
- Replaces distributor icons across all icon themes
- Configures GRUB/boot theming
- Sets up system information display (neofetch)

### setup-dark-green-theme.sh

KDE-specific theming:
- Creates CI-OS color scheme for KDE
- Sets up Plasma theme with dark green colors
- Configures look-and-feel package
- Sets default wallpaper and theme for new users
- Themes SDDM login screen

### configure-branding.sh

System-wide branding:
- Updates `/etc/os-release` with CI-OS information
- Sets default hostname and MOTD
- Configures KDE About dialog
- Sets up Plymouth boot splash
- Creates welcome screen for new users
- Establishes default applications

## Testing and Validation

### Local Testing

```bash
# Build and test locally
podman build -t ci-os-test .
podman run -it --rm ci-os-test /bin/bash

# Check theming is applied
ls /usr/share/color-schemes/
ls /usr/share/backgrounds/ci-os/
cat /etc/os-release
```

### VM Testing

1. Generate ISO or rebase existing Bazzite VM
2. Test boot experience (Plymouth, login screen)
3. Validate desktop theming and wallpapers
4. Check system information and branding
5. Test application theming consistency

## Development Workflow

### Making Changes

1. **Edit Assets**: Update logos, wallpapers in `assets/`
2. **Modify Scripts**: Update theming scripts in `scripts/bazzite/`
3. **Update Containerfile**: Add new customizations if needed
4. **Test Locally**: Build and test container image
5. **Push Changes**: GitHub Actions will build automatically

### Adding New Wallpapers

1. Create SVG wallpapers with CI-OS dark green color scheme
2. Place in `assets/wallpapers/`
3. Update `apply-ci-os-theming.sh` if special handling needed
4. Test wallpaper selection in KDE System Settings

### Theme Modifications

1. Edit color values in `setup-dark-green-theme.sh`
2. Update KDE color scheme definitions
3. Test across different KDE components
4. Validate consistency with CI-OS branding

## Integration with Bazzite Features

CI-OS preserves all Bazzite features while adding CI-OS branding:

### Gaming Features (Inherited from Bazzite)
- ✅ Steam with Proton
- ✅ Lutris gaming client
- ✅ GameMode performance optimization
- ✅ MangoHud performance overlay
- ✅ Nvidia/AMD driver support
- ✅ Xbox controller support

### Developer Tools (CI-OS Additions)
- ✅ Git, development tools
- ✅ Container tools (Podman, Docker)
- ✅ Code editors and IDEs
- ✅ Database clients
- ✅ AI/ML development tools

### System Features
- ✅ Immutable OS benefits from Bazzite
- ✅ Flatpak application support
- ✅ Atomic updates and rollback
- ✅ CI-OS branding and theming
- ✅ Dark green visual identity

## Roadmap

### Version 1.0 (Current)
- [x] Bazzite base integration
- [x] Dark green theme implementation
- [x] CI-OS branding and logos
- [x] Container build system
- [x] GitHub Actions CI/CD
- [ ] ISO generation
- [ ] Automated testing

### Version 1.1 (Planned)
- [ ] Additional wallpaper variants
- [ ] Custom KDE widgets
- [ ] Enhanced boot animations
- [ ] System monitoring dashboards
- [ ] Developer tool presets

### Version 2.0 (Future)
- [ ] Custom package overlays
- [ ] AI companion integration
- [ ] Cloud development tools
- [ ] Enterprise management features

## Support and Documentation

- **Repository**: https://github.com/companionintelligence/CI-OS
- **Issues**: Report bugs and request features via GitHub Issues
- **Discussions**: Community discussion via GitHub Discussions
- **Documentation**: This guide and additional docs in `/docs`

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines on contributing to CI-OS development.

---

*This customization approach leverages the power of immutable operating systems while providing a fully branded CI-OS experience with beautiful dark green theming.*