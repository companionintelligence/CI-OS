# CI OS

## Custom Linux Distribution for AI Companions and Development

![CI OS Logo](assets/logos/ci-holo-depth.png)

CI OS is a specialized Ubuntu-based Linux distribution optimized for
continuous integration, software development, and gaming workloads.
Built using [Cubic](https://github.com/PJ-Singh-001/Cubic), it provides
a pre-configured environment with essential development tools, CI/CD
platforms, and gaming support.

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

### 🎮 Gaming Support

- **Steam Integration**: Steam launcher with Proton support
- **Performance Optimization**: GameMode and MangoHud
- **Graphics Drivers**: NVIDIA and AMD GPU support
- **Vulkan Ready**: Latest Vulkan drivers included

### 🔒 Security & Administration

- **Hardened Configuration**: Secure SSH and firewall defaults
- **User Management**: Pre-configured user accounts
- **System Monitoring**: Built-in monitoring and logging
- **Automatic Updates**: Security update automation

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

- 4GB+ RAM (8GB+ recommended)
- 25GB+ disk space
- USB drive for installation
- Internet connection

#### Download

1. Download the latest CI OS ISO from [Releases](../../releases)
2. Verify checksums for integrity
3. Create bootable USB using tools like:
   - [Rufus](https://rufus.ie/) (Windows)
   - [Etcher](https://www.balena.io/etcher/) (Cross-platform)
   - `dd` command (Linux/macOS)

### Installation

```bash
# Standard installation - follow GUI wizard
# OR automated installation with defaults
# Default user: cios / password: ci0s2024!
```

### Post-Installation Setup

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Run development environment setup
sudo ./scripts/ci-server-linux-dev-setup.sh

# Optional: Gaming setup
sudo ./scripts/setup-gaming.sh

# Optional: AMD GPU optimization
sudo ./scripts/ci-server-setup-ubuntu-amd.sh
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

### 1. Install Cubic

**Ubuntu/Derivatives:**

```bash
sudo apt-key adv --keyserver keyserver.ubuntu.com \
  --recv-keys B7579F80E494ED3406A59DF9081525E2B4F1283B
sudo apt-add-repository universe
sudo apt-add-repository ppa:cubic-wizard/release
sudo apt update
sudo apt install --no-install-recommends cubic
```

**Debian/Derivatives:**

```bash
echo "deb https://ppa.launchpadcontent.net/cubic-wizard/release/ubuntu/ \
  noble main" | sudo tee \
  /etc/apt/sources.list.d/cubic-wizard-release.list
curl -S "https://keyserver.ubuntu.com/pks/lookup?op=get&search=\
0x081525e2b4f1283b" | sudo gpg --batch --yes --dearmor \
  --output /etc/apt/trusted.gpg.d/cubic-wizard-ubuntu-release.gpg
sudo apt update
sudo apt install --no-install-recommends cubic
```

### 2. Download Base ISO

Download Ubuntu 24.04 LTS Desktop ISO and place in `iso/base/`

### 3. Build Process

1. Launch Cubic
2. Create new project in `cubic-project/`
3. Select base Ubuntu ISO
4. Follow the [Cubic Customization Plan](docs/cubic-customization-plan.md)
5. Apply configurations from `configs/`
6. Copy assets from `assets/`
7. Execute customization scripts
8. Generate CI OS ISO

### 4. Testing

```bash
# Test in virtual machine
# Validate all features work
# Check performance benchmarks
```

## 📚 Documentation

- **[Installation Guide](docs/installation-guide.md)** - Complete
  installation instructions
- **[Cubic Customization Plan](docs/cubic-customization-plan.md)** -
  Detailed build process
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

- ✅ Base Ubuntu 24.04 LTS
- ✅ Development tools integration
- ✅ Gaming support
- ✅ CI/CD tools

### Version 1.1 (Planned)

- [ ] Kubernetes tools integration
- [ ] Additional language support (Go, Rust)
- [ ] Enhanced security features
- [ ] Performance optimizations

### Version 2.0 (Future)

- [ ] Custom package manager
- [ ] Cloud-native tooling
- [ ] Advanced virtualization
- [ ] Enterprise features

## 📄 License

CI OS is based on Ubuntu and inherits its licensing terms. Custom scripts
and configurations are licensed under MIT License.

## 🙏 Acknowledgments

- **[Cubic Project](https://github.com/PJ-Singh-001/Cubic)** - Ubuntu
  customization tool
- **Ubuntu Team** - Base operating system
- **Community Contributors** - Testing and feedback

## 📊 Statistics

- **Base Size**: ~4.5GB ISO
- **Installation Time**: ~15-20 minutes
- **Boot Time**: <30 seconds
- **Memory Usage**: ~1.5GB idle
- **Supported Architectures**: x86_64 (AMD64)

---

## Made with ❤️ for developers, by developers
