# CI OS

## Custom Linux Distribution for AI Companions and Development

![CI OS Logo](assets/logos/ci-holo-depth.png)

## COPYRIGHT COMPANION INTELLIGENCE - LIFESCOPE INC

# IN DEV - DO NOT DISTRIBUTE

## PRIVATE AND CONFIDENTIAL

CI OS is a specialized Bazzite-based Linux distribution optimized for
continuous integration, software development, and gaming workloads with
Windows application compatibility. Built on [Bazzite](https://bazzite.gg/)
(Fedora-based immutable gaming OS with KDE Plasma), it provides a
pre-configured environment with Wine, Proton, WinApps, and a beautiful
dark green theme throughout the system.

## ✨ Features

### 🎨 Visual Identity
- **Dark Green Theme**: Beautiful CI-OS Dark color scheme throughout
- **KDE Plasma Desktop**: Polished, gaming-optimized interface
- **CI Branding**: Custom logos, wallpapers, and boot screens
- **Color Scheme**: 
  - Primary Dark Green: #066c80
  - Medium Green: #00a9a7
  - Light Green: #72ddd4

### 🍷 Windows Compatibility

- **Wine Integration**: Pre-configured Wine environment with 32-bit libraries
- **Proton Support**: Steam Proton compatibility tools included
- **Protontricks**: Per-game Proton configuration
- **WinApps Ready**: QEMU/KVM stack for seamless Windows VM apps
- **Winetricks**: Easy installation of Windows components

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

### First-Time Setup

After installing CI-OS, run the first-time setup:

```bash
# Run the interactive CI-OS setup
ujust setup-ci-os

# This will configure:
# - Wine environment with common Windows components
# - Proton compatibility tools
# - CI-OS dark green theme
# - KDE Plasma customizations
```

### Available Commands

CI-OS includes helpful `ujust` commands for easy management:

```bash
# Display system information
ujust ci-os-info

# Set up Wine for Windows applications
ujust setup-wine

# Configure Proton for Steam games
ujust setup-proton

# Install WinApps for seamless Windows VM apps
ujust setup-winapps

# Apply or reapply the dark green theme
ujust apply-ci-theme

# NVIDIA-specific optimizations (NVIDIA variant only)
ujust setup-ci-os-nvidia
ujust nvidia-info
```

### Running Windows Applications

```bash
# Run a Windows application with Wine
wine application.exe

# Use Winetricks to install Windows components
winetricks dotnet48 vcrun2019

# Configure Proton for a Steam game
protontricks <steam-app-id> <winetricks-command>
```

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

- **RAM**: 8GB+ (16GB recommended for Windows VM apps)
- **Storage**: 40GB+ disk space (more for Windows VMs)
- **USB Drive**: For installation media
- **Internet**: Required for installation and updates
- **GPU**: AMD or NVIDIA (NVIDIA variant available for NVIDIA GPUs)
- USB drive for installation
- Internet connection

#### Download

CI-OS is available in two variants:

1. **CI-OS Regular**: Standard Bazzite base with Windows apps support
2. **CI-OS NVIDIA**: Includes NVIDIA drivers and GPU acceleration

Download the latest ISO from [Releases](../../releases) and verify checksums.

#### Create Installation Media

```bash
# Linux/macOS
sudo dd if=CI-OS-v01-regular-41.iso of=/dev/sdX bs=4M status=progress

# Or use a GUI tool:
# - Rufus (Windows)
# - Etcher (Cross-platform)
# - Fedora Media Writer
```

#### Installation

1. Boot from USB drive
2. Follow the Anaconda installer wizard
3. Select your language, timezone, and keyboard layout
4. Configure disk partitioning (automatic recommended)
5. Create your user account
6. Complete installation and reboot

### Post-Installation Setup

```bash
# Run first-time CI-OS setup
ujust setup-ci-os

# This configures Wine, Proton, and applies the dark green theme
```

#### Optional: WinApps Setup

For seamless Windows application integration via VM:

```bash
ujust setup-winapps
# Follow the prompts to configure your Windows VM
```

#### NVIDIA Users

If you installed the NVIDIA variant:

```bash
# Apply NVIDIA-specific optimizations
ujust setup-ci-os-nvidia

# Check GPU status
ujust nvidia-info
```

## 📁 Project Structure

```text
ci-os/
├── .github/
│   └── workflows/
│       └── build-iso.yml          # GitHub Actions ISO build workflow
├── assets/                        # Branding and visual assets
│   ├── logos/                     # CI OS logos and branding
│   ├── wallpapers/                # Desktop wallpapers
│   └── branding/                  # Brand guidelines with color scheme
├── files/                         # OS customization files
│   ├── etc/
│   │   ├── default/grub.d/        # GRUB bootloader configuration
│   │   └── sddm.conf.d/           # Login manager theme
│   └── usr/share/
│       ├── color-schemes/         # KDE Plasma CI-OS Dark theme
│       ├── pixmaps/               # Logos and boot graphics
│       ├── plymouth/themes/       # Boot splash screen
│       ├── ublue-os/just/         # ujust command definitions
│       └── wallpapers/            # System wallpapers
├── scripts/                       # Installation and setup scripts
│   ├── ci-server-setup-ubuntu-amd.sh    # AMD GPU setup
│   ├── ci-server-linux-dev-setup.sh     # Development environment
│   └── setup-gaming.sh                  # Gaming optimization
├── configs/                       # Legacy configuration files
├── docs/                          # Documentation
├── Containerfile                  # Regular variant build definition
├── Containerfile.nvidia           # NVIDIA variant build definition
└── README.md                      # This file
```

## 🔧 Building from Source

CI-OS uses container-based builds with GitHub Actions. ISOs are automatically
built weekly and on every push to main.

### Prerequisites

- Linux system with Docker/Podman
- 20GB+ free disk space
- Internet connection

### Local Build (Advanced)

```bash
# Clone the repository
git clone https://github.com/companionintelligence/CI-OS.git
cd CI-OS

# Build regular variant
podman build -f Containerfile -t ci-os:latest .

# Build NVIDIA variant
podman build -f Containerfile.nvidia -t ci-os-nvidia:latest .

# Tag and push (maintainers only)
podman tag ci-os:latest ghcr.io/companionintelligence/ci-os/ci-os:v01-latest
podman push ghcr.io/companionintelligence/ci-os/ci-os:v01-latest
```

### ISO Generation

ISOs are built automatically via GitHub Actions using the
[build-container-installer](https://github.com/jasonn3/build-container-installer)
action. See `.github/workflows/build-iso.yml` for details.

To trigger a manual build:

1. Go to the **Actions** tab in GitHub
2. Select **Build and Publish CI-OS ISOs**
3. Click **Run workflow**

### Customization

To customize CI-OS:

1. Edit files in the `files/` directory
2. Modify `Containerfile` or `Containerfile.nvidia`
3. Update color scheme in `files/usr/share/color-schemes/CI-OS-Dark.colors`
4. Commit and push changes
5. GitHub Actions will build new ISOs automatically

### Legacy Build Instructions (Cubic)

The original Ubuntu-based build using Cubic is now deprecated.
See `docs/cubic-customization-plan.md` for historical reference.

## 📚 Documentation

- **[Files Directory](files/README.md)** - Customization files documentation
- **[Brand Guidelines](assets/branding/brand-guidelines.md)** - Visual
  identity and dark green color scheme
- **[Build Workflow](.github/workflows/build-iso.yml)** - Automated ISO build
  configuration
- **[Installation Guide](docs/installation-guide.md)** - Complete
  installation instructions (legacy)
- **[Cubic Customization Plan](docs/cubic-customization-plan.md)** -
  Legacy Ubuntu build process (deprecated)

## 🤝 Contributing

We welcome contributions! Please see our contributing guidelines:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

### Areas for Contribution

- Windows application compatibility improvements
- KDE Plasma theme enhancements
- Additional ujust commands
- WinApps integration improvements
- Documentation updates
- Bug fixes and security patches

## 🐛 Issues and Support

- **Bug Reports**: [GitHub Issues](../../issues)
- **Feature Requests**: [GitHub Discussions](../../discussions)
- **Security Issues**: Email <security@ci-os.org>

## 📋 Roadmap

### Version 1.0 (Current)

- ✅ Bazzite Fedora 41 base
- ✅ KDE Plasma desktop with dark green theme
- ✅ Wine and Proton integration
- ✅ Windows compatibility tools
- ✅ ujust commands for easy setup
- ✅ NVIDIA variant support

### Version 1.1 (Planned)

- [ ] Enhanced WinApps integration
- [ ] Additional Windows compatibility layers
- [ ] Performance optimizations for Wine/Proton
- [ ] Improved theme customization options
- [ ] More pre-configured Windows app profiles

### Version 2.0 (Future)

- [ ] One-click Windows app installation
- [ ] Advanced GPU passthrough for VMs
- [ ] Multi-monitor gaming optimizations
- [ ] Enhanced development tool integration

## 📄 License

CI OS is based on Bazzite and Fedora, inheriting their licensing terms.
Custom scripts, themes, and configurations are proprietary to Companion
Intelligence - Lifescope Inc.

## 🙏 Acknowledgments

- **[Bazzite Project](https://bazzite.gg/)** - Gaming-optimized immutable OS
- **[Universal Blue](https://universal-blue.org/)** - Cloud-native OS toolkit
- **[Fedora Project](https://fedoraproject.org/)** - Base operating system
- **[KDE Project](https://kde.org/)** - Plasma desktop environment
- **Wine/Proton Teams** - Windows compatibility layers

## 📊 Statistics

- **Base Size**: ~6-8GB ISO (varies by variant)
- **Installation Time**: ~20-30 minutes
- **Boot Time**: <20 seconds (SSD)
- **Memory Usage**: ~2GB idle (KDE Plasma)
- **Supported Architectures**: x86_64 (AMD64)
- **Base OS**: Fedora 41 (Bazzite/Kinoite)

---

## Made with ❤️ by Companion Intelligence
