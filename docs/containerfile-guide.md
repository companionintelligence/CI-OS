# CI OS Containerfile (v0) - Bazzite + Windows Apps

This directory contains the modern container-based approach for CI OS, built on top of [Bazzite](https://github.com/ublue-os/bazzite) with Wine, Proton, and WinApps support.

## Quick Start

### 1. Build the Container

```bash
# Clone this repository
git clone https://github.com/companionintelligence/CI-OS.git
cd CI-OS

# Build the container image
docker build -t ci-os-bazzite:dev -f Containerfile .

# Or build with custom base image
docker build --build-arg BASE_IMAGE=ghcr.io/ublue-os/bazzite-nvidia:stable \
  -t ci-os-bazzite-nvidia:dev -f Containerfile .
```

### 2. Deploy to Your System

```bash
# Rebase your Fedora/Universal Blue system to the container
rpm-ostree rebase ostree-unverified-registry:localhost/ci-os-bazzite:dev
systemctl reboot
```

### 3. First-Time Setup (after reboot)

```bash
# Set up Wine with default 64-bit prefix and common components
ujust setup-wine

# Configure Proton tools and documentation
ujust setup-proton-tools

# Set up WinApps (requires Windows ISO - see below)
ujust setup-winapps WIN_ISO=/path/to/Windows11.iso VIRTIO_ISO=/path/to/virtio-win.iso
```

## Windows ISO Requirements

To use WinApps, you need:

1. **Windows ISO**: Windows 10 or 11 installation ISO
2. **VirtIO ISO** (recommended): [Download from here](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)

Example with ISOs in ~/Downloads:

```bash
ujust setup-winapps WIN_ISO="$HOME/Downloads/Win11_22H2_English_x64v1.iso" \
  VIRTIO_ISO="$HOME/Downloads/virtio-win-0.1.240.iso"
```

## Available Commands

After installation, these `ujust` commands are available:

- `ujust setup-wine` - Create Wine prefix with common fonts and settings
- `ujust setup-proton-tools` - Configure protontricks and display usage info
- `ujust setup-winapps` - Set up Windows VM for seamless app integration

## What's Included

### Base System (Bazzite)
- Fedora-based with gaming optimizations
- Steam pre-installed with Proton
- AMD/Intel graphics optimized
- NVIDIA variant available

### Wine Stack
- Latest Wine with full 32-bit support
- winetricks for easy Windows component installation
- Common fonts and libraries pre-configured

### Proton Tools
- protontricks for managing Steam/Proton prefixes
- Integration with Steam's Proton versions
- Documentation for non-Steam executable usage

### WinApps Integration
- KVM/QEMU virtualization stack
- libvirt VM management
- RDP clients for seamless integration
- Automatic .desktop launcher creation

## Customization Options

### Build Arguments

- `BASE_IMAGE`: Change base image (default: `ghcr.io/ublue-os/bazzite:stable`)
- `WINAPPS_REPO`: Use different WinApps fork
- `WINAPPS_REF`: Pin to specific commit/tag

### Examples

```bash
# NVIDIA variant
docker build --build-arg BASE_IMAGE=ghcr.io/ublue-os/bazzite-nvidia:stable \
  -t ci-os-bazzite-nvidia:dev -f Containerfile .

# Pin WinApps to specific version
docker build --build-arg WINAPPS_REF=v1.0.0 \
  -t ci-os-bazzite:stable -f Containerfile .

# Use custom WinApps fork
docker build --build-arg WINAPPS_REPO=https://github.com/your-fork/winapps.git \
  -t ci-os-bazzite:custom -f Containerfile .
```

### Package Modifications

Edit the `rpm-ostree install` section in the Containerfile to:
- Add hardware-specific drivers
- Include additional development tools  
- Remove unnecessary packages

## Publishing to Registry

### GitHub Container Registry

```bash
# Build and tag for GHCR
docker build -t ghcr.io/companionintelligence/ci-os-bazzite:latest -f Containerfile .

# Push to registry
echo $GITHUB_TOKEN | docker login ghcr.io -u $GITHUB_USERNAME --password-stdin
docker push ghcr.io/companionintelligence/ci-os-bazzite:latest
```

### Using Published Image

```bash
# Rebase to published image
rpm-ostree rebase ostree-unverified-registry:ghcr.io/companionintelligence/ci-os-bazzite:latest
systemctl reboot
```

## Troubleshooting

### WinApps Issues

- Ensure virtualization is enabled in BIOS
- Check if user is in libvirt/kvm groups: `groups $USER`
- Verify libvirtd is running: `systemctl status libvirtd`

### Wine/Proton Issues

- Run `winecfg` to configure Wine settings
- Use `protontricks --gui` for graphical prefix management
- Install additional Windows components: `winetricks`

### System Issues

- Check container status: `rpm-ostree status`
- View system logs: `journalctl -f`
- Reset to previous version: `rpm-ostree rollback`

## Next Steps

1. **Gaming**: Launch Steam, enable Proton for Windows games
2. **Development**: Install development tools via Flatpak or Distrobox
3. **Windows Apps**: Use WinApps to run Windows applications seamlessly
4. **Customization**: Layer additional packages with `rpm-ostree install`

For detailed documentation, see the main [README.md](../README.md) and [project documentation](../docs/).