# CI-OS v01: Bazzite-based ISO with Windows Apps Support

![CI OS Logo](assets/logos/ci-holo-depth.png)

A bootable ISO distribution based on [Bazzite](https://bazzite.gg/) that includes Wine, Proton helpers, and WinApps support built-in. Drop this ISO into any system for instant Windows application compatibility alongside Linux gaming.

## 🎯 Project Overview

CI-OS v01 creates bootable installer ISOs based on Bazzite with pre-configured Windows compatibility tools. Install like any Linux distribution and get instant access to Windows apps through multiple compatibility layers.

### Key Features

- 💿 **Bootable ISOs**: Ready-to-install images with everything included
- 🎮 **Bazzite Foundation**: Gaming-optimized Fedora Silverblue derivative
- 🍷 **Wine Pre-configured**: Wine environment ready out-of-the-box
- ⚙️ **Proton Integration**: Includes protontricks and Proton tools  
- 💻 **WinApps Ready**: VM-based Windows app integration support
- 🚀 **One-Command Setup**: Easy configuration with `ujust` commands
- 🎯 **Two Variants**: Regular and NVIDIA-optimized versions

## 📦 Available ISOs

### Regular CI-OS
- **Base**: Bazzite Fedora 41 (KDE)
- **Target**: Gaming and general-purpose systems
- **Size**: ~4GB ISO
- **Includes**: Wine, Proton, WinApps, virtualization stack

### NVIDIA CI-OS  
- **Base**: Bazzite NVIDIA Fedora 41 (KDE)
- **Target**: Systems with NVIDIA GPUs
- **Size**: ~4.2GB ISO
- **Includes**: Everything + NVIDIA drivers and optimizations

## 🚀 Quick Start

### Download and Install

1. **Download ISO** from [GitHub Releases](https://github.com/companionintelligence/CI-OS/releases)
2. **Create bootable USB** (8GB+ recommended):
   ```bash
   sudo dd if=CI-OS-v01-regular-41.iso of=/dev/sdX bs=4M status=progress
   ```
3. **Boot and install** like any Linux distribution
4. **First-time setup** after installation:
   ```bash
   ujust setup-ci-os  # Complete setup wizard
   ```

### What's Included After Installation

✅ **Wine Stack**
- Wine (latest stable) with 32-bit libraries
- Winetricks for Windows components
- Mesa and Vulkan drivers (32-bit support)

✅ **Proton Integration**  
- Protontricks for per-game configuration
- Steam Proton compatibility tools

✅ **Virtualization Ready**
- QEMU/KVM stack for WinApps
- libvirt management tools
- RDP clients (FreeRDP, Remmina)

✅ **Gaming Features** (from Bazzite)
- Steam and Lutris pre-installed
- Controller support and optimizations
- HDR/VRR support, gaming kernel

## ⚙️ First-Time Configuration

After installation and first boot:

```bash
# Complete setup wizard (recommended)
ujust setup-ci-os

# Or step-by-step setup
ujust setup-wine        # Configure Wine environment
ujust setup-proton      # Install Proton tools  
ujust setup-winapps     # Set up WinApps VM (optional)

# For NVIDIA systems
ujust setup-ci-os-nvidia  # NVIDIA-optimized setup
ujust nvidia-info         # Check NVIDIA status
```

## 🔧 Available Commands

### Setup & Configuration
```bash
ujust setup-ci-os       # Complete setup wizard
ujust setup-wine        # Wine configuration only
ujust setup-proton      # Proton tools only
ujust setup-winapps     # WinApps VM setup
ujust ci-os-info        # System information
```

### Running Windows Apps
```bash
ujust run-wine <app.exe>    # Run app with Wine
ujust list-winapps          # List WinApps applications
wine program.exe            # Direct Wine execution
```

### NVIDIA Systems (NVIDIA variant)
```bash
ujust setup-ci-os-nvidia        # Complete NVIDIA setup
ujust nvidia-info               # GPU status and info
ujust optimize-nvidia-gaming    # Performance optimization
ujust test-nvidia-wine          # Test Wine+NVIDIA integration
```
## 🏗️ Building Custom ISOs

### Prerequisites

For local building:
```bash
# On Fedora
sudo dnf install podman
```

### Quick Build

```bash
# Build regular ISO (creates container, GitHub Actions creates ISO)
./scripts/build-iso.sh

# Build NVIDIA variant
./scripts/build-iso.sh nvidia

# Build both variants
./scripts/build-iso.sh both --clean
```

### GitHub Actions (Recommended)

Full ISO building happens automatically via GitHub Actions:

1. **Automatic**: Weekly builds every Sunday
2. **Manual**: Go to Actions → "Build and Publish CI-OS ISOs" → "Run workflow"  
3. **On Push**: Triggered by Containerfile changes

Results published to [GitHub Releases](https://github.com/companionintelligence/CI-OS/releases) with:
- ✅ Signed container images
- 💿 Bootable ISOs for both variants  
- 🔐 Checksums for verification

## 📚 Documentation

- [ISO Build Guide](docs/iso-build-guide.md) - Complete building documentation
- [Installation Guide](docs/installation-guide.md) - Detailed installation walkthrough  
- [Quick Start Guide](docs/quick-start-guide.md) - Get running fast

## 🖥️ Windows App Integration

### Wine (Direct)
- Run Windows executables directly: `wine program.exe`
- Windows games and productivity applications
- Office suite and development tools compatibility
- 32-bit and 64-bit application support

### WinApps (VM-based)  
- Full Windows VM with seamless Linux integration
- Windows apps appear as native Linux applications
- Shared clipboard and file systems
- Hardware acceleration and GPU passthrough support

### Proton (Gaming)
- Steam Proton for Windows games
- Protontricks for per-game tweaks
- Lutris integration for non-Steam games

## 🔨 Customization

### Adding Packages

Edit `Containerfile` or `Containerfile.nvidia`:

```dockerfile
RUN --mount=type=cache,target=/var/cache/dnf \
    rpm-ostree install -y \
      your-package-here \
    && rpm-ostree cleanup -m \
    && ostree container commit
```

### Custom Just Commands

Add `.just` files to `files/just/` and reference in Containerfile:

```dockerfile
COPY files/just/my-commands.just /usr/share/ublue-os/justfiles/70-my-commands.just
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Test changes: `./scripts/build-iso.sh --verbose`
4. Commit changes: `git commit -m 'Add amazing feature'`
5. Push to branch: `git push origin feature/amazing-feature`
6. Open a Pull Request

### Development Workflow

```bash
git clone https://github.com/companionintelligence/CI-OS.git
cd CI-OS
./scripts/build-iso.sh regular --verbose  # Test build
# Make changes to Containerfiles
./scripts/build-iso.sh both --clean      # Test both variants
```

## 🏷️ Versioning

- **v01**: Initial release based on Bazzite Fedora 41
- **WinApps**: Pinned to latest stable commit
- **Container Images**: Tagged with build date and `latest`
- **ISOs**: Released as GitHub releases with checksums

## 📄 License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

## 🙏 Acknowledgments

- [Bazzite Team](https://bazzite.gg/) - For the excellent gaming-focused base distribution
- [Universal Blue](https://universal-blue.org/) - For the container-to-ISO methodology  
- [WinApps Projects](https://github.com/winapps-org/winapps) - For seamless Windows VM integration
- [Wine Project](https://www.winehq.org/) - For Windows compatibility layer
- [jasonn3/build-container-installer](https://github.com/jasonn3/build-container-installer) - For container-to-ISO conversion

## ⚡ Quick Links

- 📥 [Download ISOs](https://github.com/companionintelligence/CI-OS/releases)
- 🏗️ [Build Guide](docs/iso-build-guide.md)
- 🎮 [Bazzite Homepage](https://bazzite.gg/)
- 💻 [WinApps Documentation](https://github.com/winapps-org/winapps)
- 🍷 [Wine Documentation](https://www.winehq.org/documentation)

---

**CI-OS v01**: Drop-in ISO for instant Windows app support on Linux gaming systems! 💿🎮🍷
