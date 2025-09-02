# CI-OS v01 ISO Build Guide

This guide explains how to build CI-OS ISOs, which are bootable installer images based on Bazzite with Wine, Proton, and WinApps support.

## Overview

CI-OS v01 creates bootable ISOs that can be installed like any Linux distribution. The ISOs include:

- 🎮 **Bazzite base**: Gaming-optimized Fedora Silverblue derivative
- 🍷 **Wine & Proton**: Pre-configured Windows compatibility layers
- 💻 **WinApps**: Seamless Windows VM integration 
- 🚀 **Easy setup**: Just commands for one-click configuration

## Build Process

The build process has two stages:

1. **Container Image**: Build a container image with all packages and configuration
2. **ISO Conversion**: Convert the container image to a bootable ISO using specialized tools

## Variants

### Regular CI-OS
- Base: `ghcr.io/ublue-os/bazzite:stable`
- Target: Gaming and general-purpose systems
- Includes: Wine, Proton, WinApps, virtualization stack

### NVIDIA CI-OS  
- Base: `ghcr.io/ublue-os/bazzite-nvidia:stable`
- Target: NVIDIA GPU systems
- Includes: Everything from regular + NVIDIA drivers and optimizations

## Building Locally

### Prerequisites

```bash
# On Fedora
sudo dnf install podman

# For full ISO building (optional - GitHub Actions handles this)
sudo dnf install lorax
```

### Quick Build

```bash
# Build regular variant
./scripts/build-iso.sh

# Build NVIDIA variant  
./scripts/build-iso.sh nvidia

# Build both variants
./scripts/build-iso.sh both

# Clean build
./scripts/build-iso.sh both --clean
```

### Build Options

```bash
./scripts/build-iso.sh [OPTIONS] [VARIANT]

Variants:
  regular     Regular CI-OS (default)
  nvidia      NVIDIA variant
  both        Build both variants

Options:
  -h, --help              Show help
  -c, --clean             Clean build directory  
  -k, --keep-containers   Keep containers after build
  -v, --verbose           Verbose output
  --no-iso                Only build containers
  --fedora-version VER    Fedora version (default: 41)
```

## GitHub Actions Build

The repository includes automated ISO building via GitHub Actions.

### Automatic Builds

- **Weekly**: Every Sunday at 2 AM UTC
- **Push**: When Containerfiles or configs change
- **Manual**: Via workflow_dispatch

### Build Artifacts

Each build produces:
- ✅ Signed container images
- 💿 Bootable ISOs for both variants
- 🔐 Checksums for verification
- 📦 GitHub releases with download links

### Triggering Manual Builds

1. Go to Actions tab in GitHub
2. Select "Build and Publish CI-OS ISOs" 
3. Click "Run workflow"
4. Wait for completion (~30-45 minutes)

## Container Images

Container images are published to:

```
ghcr.io/companionintelligence/ci-os/ci-os:v01-latest
ghcr.io/companionintelligence/ci-os/ci-os-nvidia:v01-latest
```

These can be used with:

```bash
# Test the container
podman run --rm -it ghcr.io/companionintelligence/ci-os/ci-os:v01-latest bash

# Check installed packages
podman run --rm ghcr.io/companionintelligence/ci-os/ci-os:v01-latest rpm -qa | grep wine
```

## ISO Usage

### Installation

1. **Download** the appropriate ISO from GitHub Releases
2. **Verify** using the provided checksums
3. **Create** a bootable USB drive (8GB+):
   ```bash
   sudo dd if=CI-OS-v01-regular-41.iso of=/dev/sdX bs=4M status=progress
   ```
4. **Boot** from USB and install like any Linux distribution

### First-Time Setup

After installation and first boot:

```bash
# Complete setup wizard
ujust setup-ci-os

# Or step-by-step setup
ujust setup-wine        # Configure Wine
ujust setup-proton      # Install Proton tools  
ujust setup-winapps     # Set up WinApps VM
```

### Available Commands

```bash
# Setup commands
ujust setup-ci-os       # Complete setup wizard
ujust setup-wine        # Wine configuration
ujust setup-proton      # Proton tools
ujust setup-winapps     # WinApps VM setup

# Usage commands  
ujust run-wine <app>    # Run Windows app with Wine
ujust list-winapps      # List available Windows apps
ujust ci-os-info        # Show system information

# NVIDIA-specific (NVIDIA variant only)
ujust setup-ci-os-nvidia    # NVIDIA setup wizard
ujust nvidia-info           # NVIDIA status
ujust optimize-nvidia-gaming # Performance optimization
```

## Customization

### Adding Packages

Edit the appropriate Containerfile:

```dockerfile
# Add to rpm-ostree install section
RUN --mount=type=cache,target=/var/cache/dnf \
    rpm-ostree install -y \
      your-package-here \
    && rpm-ostree cleanup -m \
    && ostree container commit
```

### Custom Just Commands

Add new `.just` files to `files/just/`:

```bash
files/just/my-custom.just
```

Copy them in the Containerfile:

```dockerfile
COPY files/just/my-custom.just /usr/share/ublue-os/justfiles/70-my-custom.just
```

### Version Pinning

Update build arguments in Containerfiles:

```dockerfile
ARG WINAPPS_REPO="https://github.com/winapps-org/winapps.git"
ARG WINAPPS_COMMIT="specific-commit-hash"  # Pin to specific commit
```

## Troubleshooting

### Build Issues

```bash
# Clean everything and rebuild
./scripts/build-iso.sh both --clean --verbose

# Check container logs
podman logs <container-id>

# Test container interactively
podman run --rm -it <image> bash
```

### Runtime Issues

```bash
# Check system status
ujust ci-os-info

# Check Wine configuration  
wine --version
winecfg

# Check virtualization
systemctl status libvirtd
```

### Common Problems

1. **Wine not working**: Run `ujust setup-wine` to reconfigure
2. **GPU issues**: For NVIDIA systems, use the NVIDIA variant
3. **VM problems**: Ensure virtualization is enabled in BIOS
4. **Permission issues**: Add user to `libvirt` group

## Support

- 📚 **Documentation**: Check `/usr/share/doc/ci-os/`  
- 💬 **Issues**: GitHub Issues for bug reports
- 🔧 **Logs**: Check `journalctl -u libvirtd` for VM issues

## Development

### Testing Changes

1. Modify Containerfiles locally
2. Build with `./scripts/build-iso.sh --verbose`
3. Test container: `podman run --rm -it <image> bash`
4. Push changes to trigger CI builds

### Contributing

1. Fork the repository
2. Create feature branch
3. Test changes locally  
4. Submit pull request
5. CI will build and test ISOs automatically