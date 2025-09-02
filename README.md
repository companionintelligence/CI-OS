# CI OS

## Custom Linux Distribution for AI Companions and Development

![CI OS Logo](assets/logos/ci-holo-depth.png)

## COPYRIGHT COMPANION INTELLIGENCE - LIFESCOPE INC

## DO NOT DISTRIBUTE

## PRIVATE AND CONFIDENTIAL

CI OS is a specialized **Bazzite-based** immutable Linux distribution optimized for
continuous integration, software development, and gaming workloads.
Built using **container technology** on top of [Bazzite](https://bazzite.gg/), it provides
a pre-configured environment with essential development tools, CI/CD
platforms, gaming optimizations, and beautiful **dark green theming**.

## ✨ Features

### 🛠️ Development Environment

- **Pre-installed Development Tools**: Git, build-essential, vim, nano, htop
- **Container Support**: Docker and Docker Compose ready
- **Multiple Language Support**: Python 3.12, Node.js, npm/yarn/pnpm
- **Database Ready**: PostgreSQL pre-configured
- **IDE Support**: Visual Studio Code included

### 🔄 CI/CD Ready

- **Process Management**: PM2 for application lifecycle
- **SSH Server**: Secure remote access configured
- **Security**: UFW firewall and fail2ban protection
- **Monitoring**: System monitoring tools included
- **Automation**: Scripts for rapid deployment

### 🎨 Modern Interface

- **Dark Green Theme**: Beautiful dark green theming throughout the system
- **KDE Plasma Desktop**: Modern, customizable desktop environment
- **CI-OS Branding**: Custom logos, wallpapers, and visual identity
- **Immutable OS**: Stable, atomic updates with rollback capability
- **Container-based**: Built using modern container technologies

### 🎮 Gaming Excellence (Inherited from Bazzite)

- **Steam Integration**: Steam launcher with Proton support
- **Performance Optimization**: GameMode and MangoHud
- **Graphics Drivers**: NVIDIA and AMD GPU support  
- **Controller Support**: Xbox, PlayStation, and other controllers
- **Gaming Tools**: Lutris, Heroic Games Launcher, and more

## 🚀 Quick Start

### CI Server Development Setup

For setting up the CI Server development environment, use our automated
setup scripts:

#### Option 1: Interactive Setup (Recommended)

```bash
# Clone this repository
git clone https://github.com/companionintelligence/ci-os.git
cd ci-os

# Run the interactive setup launcher
./scripts/ci-setup-launcher.sh
```

#### Option 2: Direct Setup

```bash
# Download and setup CI Server with GitHub credentials
./scripts/setup-ci-server-dev.sh -u <github-username> -t <github-token>

# Or specify custom directory
./scripts/setup-ci-server-dev.sh -u <github-username> -t <github-token> \
  -d /opt/ci-server
```

#### Option 3: Manual Repository Setup

```bash
# If you already have the CI Server repository
cd /path/to/ci-server
/path/to/ci-os/scripts/ci-server-linux-dev-setup.sh
```

**What the setup includes:**

- ✅ Node.js 18.x LTS with npm/yarn
- ✅ Docker CE with Docker Compose
- ✅ PostgreSQL database with CI Server schema
- ✅ Ollama AI server with required models
- ✅ PM2 process manager
- ✅ Development hosts configuration
- ✅ All project dependencies installed

**Access your development environment:**

- 🌐 Web Application: <http://dev.companionintelligence.com>
- 📊 Database: PostgreSQL on localhost:5432
- 🤖 Ollama API: <http://localhost:11434>

### CI OS Installation

#### Prerequisites

- 8GB+ RAM (16GB+ recommended for gaming)
- 64GB+ disk space  
- USB drive for installation
- Internet connection
- Compatible hardware (see [Bazzite requirements](https://universal-blue.org/images/bazzite/))

#### Method 1: Rebase from Existing Bazzite (Recommended)

If you already have Bazzite installed:

```bash
# Rebase to CI-OS
sudo rpm-ostree rebase ghcr.io/companionintelligence/ci-os:latest

# Reboot to CI-OS
sudo systemctl reboot
```

#### Method 2: Download CI-OS ISO (Coming Soon)

1. Download the latest CI-OS ISO from [Releases](../../releases)
2. Verify checksums for integrity
3. Create bootable USB using tools like:
   - [Rufus](https://rufus.ie/) (Windows)
   - [Etcher](https://www.balena.io/etcher/) (Cross-platform)
   - `dd` command (Linux/macOS)

### Installation

```bash
# Boot from USB and follow the installation wizard
# First boot will show CI-OS dark green theme and branding
# Default user: cios / password: ci0s2024!
```

### Post-Installation Experience

After installation, CI-OS provides:

```bash
# System already configured with:
# - Dark green KDE Plasma theme
# - CI-OS branding and logos
# - Development tools pre-installed  
# - Gaming optimizations active
# - Immutable OS benefits

# Check CI-OS version
cat /etc/ci-os-release

# Update system (atomic updates)
rpm-ostree upgrade

# Install additional applications via Flatpak
flatpak install flathub com.visualstudio.code
```

## 📁 Project Structure

```text
ci-os/
├── assets/                     # Branding and visual assets
│   ├── logos/                  # CI OS logos and branding
│   ├── icons/                  # System and application icons
│   ├── wallpapers/            # Desktop wallpapers
│   └── branding/              # Brand guidelines
├── cubic-project/             # Cubic workspace (created during build)
├── scripts/                   # Installation and setup scripts
│   ├── ci-server-setup-ubuntu-amd.sh    # AMD GPU setup
│   ├── ci-server-linux-dev-setup.sh     # Development environment
│   └── setup-gaming.sh                  # Gaming optimization
├── configs/                   # Configuration files
│   ├── packages/              # Package lists and selections
│   ├── preseed/               # Automated installation configs
│   ├── boot/                  # GRUB and boot configuration
│   └── scripts/               # Cubic customization scripts
├── docs/                      # Documentation
│   ├── cubic-customization-plan.md      # Build instructions
│   └── installation-guide.md            # User installation guide
└── iso/                       # ISO storage
    ├── base/                  # Source Ubuntu ISOs
    └── output/                # Generated CI OS ISOs
```

## 🔧 Building from Source

CI-OS uses a **container-based build system** instead of traditional live CD tools.

### 1. Install Container Tools

**Linux (Fedora/RHEL):**
```bash
sudo dnf install podman buildah
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt install podman buildah
```

**macOS:**
```bash
brew install podman
```

### 2. Build CI-OS Container Image

```bash
# Clone the repository
git clone https://github.com/companionintelligence/CI-OS.git
cd CI-OS

# Build the container image
podman build -t ci-os:latest .

# Or build with specific tag
podman build -t ci-os:1.0-sage .
```

### 3. Test the Build

```bash
# Test the container
podman run -it --rm ci-os:latest /bin/bash

# Check CI-OS branding
cat /etc/os-release
ls /usr/share/backgrounds/ci-os/
```

### 4. Generate ISO (Advanced)

```bash
# Future: ISO generation from container
# This will be automated in future versions
lorax --product="CI-OS" --version="1.0" \
      --release="Sage" ci-os.iso
```

### 5. Automated Builds

GitHub Actions automatically builds CI-OS:
- **Triggers**: Push to main/develop branches
- **Registry**: `ghcr.io/companionintelligence/ci-os`
- **Tags**: `latest`, branch names, commit SHAs

## 📚 Documentation

- **[Installation Guide](docs/installation-guide.md)** - Complete
  installation instructions
- **[Bazzite Customization Guide](docs/bazzite-customization-guide.md)** -
  Detailed build process and theming
- **[Brand Guidelines](assets/branding/brand-guidelines.md)** - Visual
  identity standards

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

### Version 1.0 (Current)

- ✅ Base Bazzite integration
- ✅ Dark green themed interface  
- ✅ CI-OS branding and logos
- ✅ Container-based build system
- ✅ KDE Plasma customization
- [ ] ISO generation automation
- [ ] Enhanced wallpaper collection

### Version 1.1 (Planned)

- [ ] Additional dark green wallpaper variants
- [ ] Custom KDE widgets and themes
- [ ] Enhanced boot animations
- [ ] Developer workflow integrations
- [ ] System monitoring dashboards

### Version 2.0 (Future)

- [ ] AI companion integration
- [ ] Custom Flatpak repository
- [ ] Enterprise management features
- [ ] Multi-architecture support
- [ ] Cloud development environments

## 📄 License

CI OS is based on Bazzite (Fedora immutable) and inherits its licensing terms. 
Custom scripts, themes, and configurations are licensed under MIT License.

## 🙏 Acknowledgments

- **[Bazzite Project](https://bazzite.gg/)** - Base immutable gaming OS
- **[Universal Blue](https://universal-blue.org/)** - Container-based OS framework  
- **Ubuntu Team** - Foundational operating system components
- **KDE Team** - Plasma desktop environment
- **Community Contributors** - Testing and feedback

## 📊 Statistics

- **Container Size**: ~8GB (compressed)
- **Installation Time**: ~20-30 minutes
- **Boot Time**: <20 seconds (NVMe SSD)
- **Memory Usage**: ~2GB idle (KDE Plasma)
- **Supported Architectures**: x86_64 (AMD64)
- **Base**: Bazzite/Fedora immutable

---

## Made with ❤️ for developers, by developers
