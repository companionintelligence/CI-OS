# CI-OS Gaming Distribution (ISO v01)

## Bazzite Fork with Wine + WinApps Integration

![CI OS Logo](assets/logos/ci-holo-depth.png)

## COPYRIGHT COMPANION INTELLIGENCE - LIFESCOPE INC

## DO NOT DISTRIBUTE

## PRIVATE AND CONFIDENTIAL

CI-OS is a specialized Bazzite-based gaming distribution focused on seamless Windows application compatibility. Built on Universal Blue's container-based approach, it provides Wine, Proton, and WinApps integration for running Windows applications natively on a modern Fedora-based immutable operating system.

## ✨ Features

### 🎮 Gaming Excellence
- **Bazzite Foundation**: Built on the proven Bazzite gaming distribution
- **Steam Integration**: Full Steam support with Proton compatibility layers
- **Performance Optimization**: GameMode, MangoHud, and gaming-focused kernel
- **Graphics Drivers**: NVIDIA and AMD GPU support with container variants

### 🪟 Windows App Integration
- **Wine Compatibility**: Latest Wine with Windows API compatibility
- **Proton Support**: Steam's Proton for enhanced gaming and app compatibility
- **WinApps Integration**: Seamless Windows application integration via [WinApps](https://github.com/winapps-org/winapps)
- **DirectX Acceleration**: DXVK and VKD3D for DirectX 11/12 support

### 🔄 Container-Based Architecture
- **Immutable System**: Atomic updates via ostree technology
- **Container Builds**: Reproducible builds using Containerfiles
- **Universal Blue**: Built on Universal Blue infrastructure
- **GitHub Actions**: Automated builds with cosign signing

### 🔒 Security & Reliability
- **Signed Images**: Cryptographically signed with cosign
- **Immutable Base**: System integrity through immutable filesystem
- **Automated Updates**: Reliable system updates via ostree
- **Enterprise Ready**: Production-grade container infrastructure

## 🚀 Quick Start

### Development Setup

Set up the development environment to build custom CI-OS images:

```bash
# Clone this repository
git clone https://github.com/companionintelligence/ci-os.git
cd ci-os

# Set up development environment
./scripts/setup-development.sh

# Build base image
podman build -f Containerfile.ci-os -t ci-os:dev .

# Build NVIDIA variant
podman build -f Containerfile.ci-os-nvidia -t ci-os-nvidia:dev .

# Test the builds
./scripts/test-containers.sh
```

### Using CI-OS Images

Pull and run pre-built images from the container registry:

```bash
# Pull base image
podman pull ghcr.io/companionintelligence/ci-os:latest

# Pull NVIDIA variant
podman pull ghcr.io/companionintelligence/ci-os:nvidia

# Run Windows applications
podman run --rm -it \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  ghcr.io/companionintelligence/ci-os:latest \
  wine notepad.exe
```

### Installation on Hardware

For bare-metal installation (when ISO generation is enabled):

1. Download the latest CI-OS ISO from [Releases](../../releases)
2. Create bootable USB using [Balena Etcher](https://www.balena.io/etcher/)
3. Boot from USB and follow installation wizard
4. Default user: `deck` / password: Follow Bazzite setup

**What's included out of the box:**
- ✅ Bazzite gaming-optimized base system
- ✅ Wine with Windows app compatibility
- ✅ WinApps for seamless Windows app integration
- ✅ Proton compatibility layers
- ✅ DirectX acceleration (DXVK/VKD3D)
- ✅ Steam with full Proton support
- ✅ Gaming performance optimizations

## 📁 Project Structure

```text
ci-os/
├── .github/workflows/          # GitHub Actions CI/CD
│   └── build.yml              # Automated container builds
├── assets/                    # Branding and visual assets
│   ├── logos/                 # CI OS logos and branding  
│   └── branding/             # Brand guidelines
├── configs/                   # Configuration files
│   ├── wine/                  # Wine configuration and registry
│   ├── wine-nvidia/          # NVIDIA-specific Wine settings
│   ├── winapps/              # WinApps integration config
│   ├── proton/               # Proton helpers and versions
│   └── proton-nvidia/        # NVIDIA Proton optimizations
├── scripts/                   # Setup and utility scripts
│   ├── setup-development.sh  # Development environment setup
│   ├── setup-wine.sh         # Wine environment configuration
│   ├── setup-wine-nvidia.sh  # NVIDIA Wine setup
│   └── test-containers.sh    # Container testing and validation
├── docs/                      # Documentation
├── Containerfile.ci-os        # Base Bazzite image build
├── Containerfile.ci-os-nvidia # NVIDIA variant build
└── bazzite-reference/         # Bazzite source reference (dev only)
```

## 🔧 Building from Source

### 1. Prerequisites

Install container runtime (podman recommended):

**Fedora/RHEL:**
```bash
sudo dnf install podman git
```

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install podman git
```

### 2. Development Setup

```bash
# Clone the repository
git clone https://github.com/companionintelligence/ci-os.git
cd ci-os

# Set up development environment
./scripts/setup-development.sh
```

### 3. Build Images

```bash
# Build base CI-OS image
podman build -f Containerfile.ci-os -t ci-os:latest .

# Build NVIDIA variant
podman build -f Containerfile.ci-os-nvidia -t ci-os-nvidia:latest .

# Pin specific WinApps version
podman build --build-arg WINAPPS_COMMIT=v1.2.0 -f Containerfile.ci-os -t ci-os:stable .
```

### 4. Testing

```bash
# Run container tests
./scripts/test-containers.sh

# Manual testing
podman run --rm -it ci-os:latest wine --version
podman run --rm -it ci-os:latest winapps check

# Test Windows application
podman run --rm -it -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  ci-os:latest wine notepad.exe
```

## 📚 Documentation

## 🤝 Contributing

We welcome contributions! Please see our contributing guidelines:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

### Areas for Contribution

- Package selection optimization
- Performance improvements
- Additional hardware support
- Documentation updates
- Bug fixes and security patches

## 🐛 Issues and Support

- **Bug Reports**: [GitHub Issues](../../issues)
- **Feature Requests**: [GitHub Discussions](../../discussions)
- **Security Issues**: Email <security@ci-os.org>

## 📋 Roadmap

### Version 1.0 (Current - ISO v01)

- ✅ Base Bazzite gaming distribution
- ✅ Wine + WinApps integration
- ✅ Proton compatibility layers
- ✅ Container-based builds
- ✅ GitHub Actions automation

### Version 1.1 (Planned)

- [ ] Enhanced Windows app compatibility
- [ ] Additional gaming optimizations
- [ ] Improved WinApps integration
- [ ] ISO generation pipeline
- [ ] Performance benchmarking

### Version 2.0 (Future)

- [ ] Advanced Windows application support
- [ ] DirectX 12 Ultimate optimization
- [ ] HDR gaming support
- [ ] Enhanced NVIDIA features

## 📄 License

CI-OS is based on Bazzite/Fedora and inherits its licensing terms. Custom scripts
and configurations are licensed under MIT License.

## 🙏 Acknowledgments

- **[Bazzite Project](https://bazzite.gg/)** - Gaming-optimized base distribution
- **[Universal Blue](https://universal-blue.org/)** - Container-based OS infrastructure
- **[WinApps Project](https://github.com/winapps-org/winapps)** - Windows app integration
- **[Wine Project](https://www.winehq.org/)** - Windows compatibility layer
- **Fedora Team** - Base operating system
- **Community Contributors** - Testing and feedback

## 📊 Statistics

- **Base Container Size**: ~3.5GB compressed
- **Full Container Size**: ~8GB uncompressed
- **Wine Compatibility**: 80%+ Windows applications
- **Gaming Performance**: Native-level with Proton
- **Supported Architectures**: x86_64 (AMD64)

---

## Made with ❤️ for developers, by developers
