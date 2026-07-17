# CI-OS ISO Build Guide

Complete guide for building custom CI-OS ISOs from Ubuntu 24.04.

© Companion Intelligence — Lifescope Inc

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Build Process Details](#build-process-details)
5. [Customization](#customization)
6. [Troubleshooting](#troubleshooting)
7. [CI/CD Integration](#cicd-integration)

---

## Overview

CI-OS is built from Ubuntu 24.04 LTS (Noble Numbat) with extensive customizations:

- **Identity**: All Ubuntu branding replaced with CI-OS
- **Privacy**: Telemetry services removed, metrics blocked
- **AI Hardware**: ROCm support for AMD GPUs
- **Developer Tools**: Docker, VS Code, Node.js, Ollama ready
- **Custom Branding**: Dark green color scheme (#066c80, #00a9a7, #72ddd4)

### Build Architecture

```
Ubuntu 24.04 ISO
      ↓
Extract ISO contents
      ↓
Extract squashfs → chroot environment
      ↓
Customize chroot (OS identity, packages, branding)
      ↓
Repack squashfs
      ↓
Regenerate ISO with CI-OS branding
      ↓
Sign and publish
```

---

## Prerequisites

### Build Host Requirements

- **OS**: Ubuntu 24.04 or newer (or compatible Debian-based system)
- **Disk Space**: Minimum 30GB free (50GB+ recommended)
- **RAM**: 4GB minimum (8GB+ recommended)
- **CPU**: Multi-core processor recommended for faster compression
- **Privileges**: Root access required

### Required Packages

Install dependencies:

```bash
sudo apt-get update
sudo apt-get install -y \
  debootstrap \
  squashfs-tools \
  xorriso \
  isolinux \
  rsync \
  gpg \
  wget
```

### Download Base ISO

Download Ubuntu 24.04 Desktop ISO:

```bash
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso
```

Or use the latest:

```bash
wget https://releases.ubuntu.com/noble/ubuntu-24.04-desktop-amd64.iso
```

---

## Quick Start

### Build Locally

1. **Clone the repository**:

```bash
git clone https://github.com/companionintelligence/CI-OS.git
cd CI-OS
```

2. **Run the build script**:

```bash
sudo ./tools/iso-build/scripts/build-iso.sh \
  --base-iso /path/to/ubuntu-24.04.1-desktop-amd64.iso \
  --output-dir ./output \
  --version 1.0
```

3. **Wait for build to complete** (typically 30-60 minutes depending on hardware)

4. **Find your ISO**:

```bash
ls -lh output/companion-os-*.iso
```

### Build Options

```bash
sudo ./tools/iso-build/scripts/build-iso.sh [options]

Options:
  --base-iso PATH       Path to Ubuntu 24.04 Desktop ISO (required)
  --output-dir PATH     Output directory for built ISO (default: ./output)
  --work-dir PATH       Working directory (default: ./work)
  --version VERSION     CI-OS version string (default: 1.0)
  --sign                Sign the ISO checksums with GPG
  --clean               Clean work directory before building
  -h, --help            Show help message
```

### Example Builds

**Basic build**:
```bash
sudo ./tools/iso-build/scripts/build-iso.sh \
  --base-iso ~/ubuntu-24.04.1-desktop-amd64.iso
```

**Production build with signing**:
```bash
sudo ./tools/iso-build/scripts/build-iso.sh \
  --base-iso ~/ubuntu-24.04.1-desktop-amd64.iso \
  --version 1.0.1 \
  --sign \
  --clean
```

**Development build with custom output**:
```bash
sudo ./tools/iso-build/scripts/build-iso.sh \
  --base-iso ~/ubuntu-24.04.1-desktop-amd64.iso \
  --output-dir /mnt/data/ci-os-builds \
  --version 1.0-dev
```

---

## Build Process Details

### 1. ISO Extraction

The build script:
1. Mounts the base Ubuntu ISO
2. Copies all contents to a working directory
3. Extracts the `casper/filesystem.squashfs` separately

**Key files extracted**:
- `isolinux/` - BIOS boot loader
- `boot/grub/` - UEFI boot loader
- `casper/filesystem.squashfs` - Root filesystem
- `casper/` - Live system configuration

### 2. Squashfs Extraction

The squashfs is extracted to a chroot environment:

```bash
unsquashfs -f -d work/chroot work/squashfs/filesystem.squashfs
```

This creates a complete Ubuntu root filesystem that can be customized.

### 3. Chroot Environment Setup

System directories are bind-mounted into the chroot:

```bash
mount --bind /dev chroot/dev
mount --bind /run chroot/run
mount -t proc proc chroot/proc
mount -t sysfs sysfs chroot/sys
mount -t devpts devpts chroot/dev/pts
```

This allows package management and system configuration inside the chroot.

### 4. Customizations Applied

The `scripts/customize-chroot.sh` script applies all CI-OS customizations:

#### OS Identity
- Rewrites `/etc/os-release` with CI-OS branding
- Updates `/etc/lsb-release`
- Creates custom `/etc/issue` banner
- Changes hostname default to `ci-os`

#### Telemetry Removal
- Purges: `ubuntu-report`, `popularity-contest`, `apport`, `whoopsie`, `landscape-common`
- Blocks metrics domains in `/etc/hosts`
- Disables MOTD news
- Removes snap-store

#### Branding
- Copies CI-OS logos and wallpapers
- Configures dconf for system-wide wallpaper
- Updates GRUB distributor name
- Creates CI-OS MOTD

#### AMD GPU Support
- Installs AMD firmware and Vulkan drivers
- Creates `ci-os-install-rocm` helper script
- Pre-configures for amdgpu driver

#### Installer Customization
- Creates `/usr/share/desktop-provision/whitelabel.yaml`
- Adds custom installer slides
- Applies CI-OS color scheme (#066c80, #00a9a7, #72ddd4)
- Disables telemetry page

#### System Utilities
- Installs `ci-os-info` command
- Configures package repository template

### 5. Squashfs Repacking

The customized chroot is compressed back into squashfs:

```bash
mksquashfs chroot/ custom-iso/casper/filesystem.squashfs \
  -comp xz -b 1M \
  -e var/cache/apt/archives/* \
  -e var/lib/apt/lists/* \
  -e tmp/* \
  -noappend \
  -no-recovery
```

**Compression options**:
- `-comp xz`: XZ compression (best ratio, slower)
- `-b 1M`: 1MB block size
- `-e`: Exclude patterns for cache and temporary files

### 6. ISO Generation

The final ISO is created with `xorriso`:

```bash
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "CI-OS 1.0" \
  -eltorito-boot isolinux/isolinux.bin \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -isohybrid-gpt-basdat \
  -output companion-os-1.0-amd64.iso \
  custom-iso/
```

This creates a **hybrid ISO** that works with:
- Legacy BIOS (via isolinux)
- UEFI (via GRUB)
- USB drives (isohybrid)
- Secure Boot (inherited from Ubuntu)

### 7. Checksums and Signatures

Generated files:
- `SHA256SUMS` - SHA256 checksums
- `MD5SUMS` - MD5 checksums
- `SHA256SUMS.gpg` - GPG signature (if `--sign` used)
- `MD5SUMS.gpg` - GPG signature (if `--sign` used)
- `SBOM.txt` - Software Bill of Materials (CI builds only; local builds must generate separately)

---

## Customization

### Modifying the Build

#### Change OS Identity

Edit `scripts/customize-chroot.sh`:

```bash
# Around line 40
cat > "$CHROOT_PATH/etc/os-release" << 'EOF'
NAME="Your Custom Name"
VERSION="2.0"
...
EOF
```

#### Add/Remove Packages

Edit the package removal section in `scripts/customize-chroot.sh`:

```bash
# Add packages
apt-get install -y your-package-name

# Remove packages
apt-get purge -y unwanted-package
```

#### Change Branding Assets

Replace files in:
- `assets/logos/` - Logo files
- `setup/os-changes/background.png` - Wallpaper

#### Customize Installer

Edit `scripts/customize-chroot.sh`:

```bash
# Around line 280
cat > "$CHROOT_PATH/usr/share/desktop-provision/whitelabel.yaml" << 'EOF'
theme:
  primary_color: "#your-color"
  accent_color: "#your-accent"
EOF
```

#### Add Custom Scripts

Place scripts under the repo (for example `scripts/`) and call them from `scripts/customize-chroot.sh`:

```bash
# In scripts/customize-chroot.sh
copy_to_chroot "$REPO_ROOT/scripts/your-custom-script.sh" "/tmp/custom.sh"
chroot_exec "/tmp/custom.sh"
```

### Building Custom Packages

1. **Create package directory**:

```bash
mkdir -p packages/your-package/{DEBIAN,usr/local/bin}
```

2. **Create DEBIAN/control**:

```bash
cat > packages/your-package/DEBIAN/control << 'EOF'
Package: your-package
Version: 1.0.0
Architecture: all
Maintainer: Your Name <your@email.com>
Description: Your package description
EOF
```

3. **Add files**:

```bash
# Place binaries, configs, etc. in usr/ hierarchy
cp your-binary packages/your-package/usr/local/bin/
```

4. **Build package**:

```bash
./tools/iso-build/scripts/build-packages.sh
```

5. **Install in chroot**:

Modify `scripts/customize-chroot.sh` to copy and install your .deb.

---

## Troubleshooting

### Common Issues

#### Build fails with "No space left on device"

**Solution**: Ensure at least 30GB free space. Clean work directory:

```bash
sudo rm -rf work/
```

#### Chroot mounts not cleaned up

**Solution**: Manually unmount:

```bash
sudo umount -lf work/chroot/dev/pts
sudo umount -lf work/chroot/sys
sudo umount -lf work/chroot/proc
sudo umount -lf work/chroot/run
sudo umount -lf work/chroot/dev
```

#### ISO won't boot

**Possible causes**:
1. Corrupted squashfs - Try rebuilding with `--clean`
2. Missing boot files - Verify base ISO is complete
3. USB write error - Use `dd` with `sync` or a different tool

**Test ISO in VM**:

```bash
qemu-system-x86_64 -cdrom output/companion-os-*.iso -m 4G -enable-kvm
```

#### Package installation fails in chroot

**Solution**: Check network access:

```bash
# Ensure resolv.conf is copied
cat work/chroot/etc/resolv.conf
```

### Debug Mode

Run scripts with bash debug mode:

```bash
sudo bash -x ./tools/iso-build/scripts/build-iso.sh --base-iso ubuntu.iso
```

### Logs

Check system logs during build:

```bash
# In another terminal
sudo journalctl -f
```

---

## CI/CD Integration

### GitHub Actions Workflow

The repository includes `.github/workflows/build-companion-os-iso.yml` for automated builds.

#### Trigger Builds

**Manual build**:
1. Go to Actions tab
2. Select "Build CI-OS Ubuntu 24.04 ISO"
3. Click "Run workflow"
4. Enter version number

**Tag-based release**:
```bash
git tag v1.0.1
git push origin v1.0.1
```

**Scheduled builds**: Runs weekly on Sundays at 2 AM UTC

#### Workflow Features

- ✅ Automatic dependency installation
- ✅ Disk space cleanup (removes unused tools)
- ✅ Downloads Ubuntu base ISO
- ✅ Builds CI-OS ISO
- ✅ Generates checksums and SBOM
- ✅ Optional GPG signing
- ✅ Creates GitHub releases
- ✅ Uploads artifacts (90-day retention)

#### GPG Signing in CI

To enable signing, add repository secrets:

1. `GPG_PRIVATE_KEY` - Your GPG private key (armor format)
2. `GPG_PASSPHRASE` - Key passphrase

Generate keys:

```bash
# Generate key (if needed)
gpg --full-generate-key

# Export private key
gpg --armor --export-secret-key your@email.com > private.key

# Add to GitHub Secrets
cat private.key | pbcopy  # or xclip on Linux
```

#### Workflow Configuration

Edit `.github/workflows/build-companion-os-iso.yml`:

```yaml
env:
  UBUNTU_VERSION: "24.04"
  BASE_ISO_URL: "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso"
```

### Local CI Testing

Test workflow locally with [act](https://github.com/nektos/act):

```bash
# Install act
curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash

# Run workflow
act workflow_dispatch -j build-iso
```

---

## Best Practices

### Version Management

Use semantic versioning:
- **Major.Minor.Patch** (e.g., 1.0.0, 1.1.0, 2.0.0)
- **Date-based** for development (e.g., 1.0-20240219)

### Build Reproducibility

For reproducible builds:
1. Pin base ISO URL in workflow
2. Use `--clean` flag to start fresh
3. Record build environment details
4. Sign all releases

### Testing ISOs

Before release, test:
1. ✅ Boot in VM (BIOS and UEFI modes)
2. ✅ Complete installation
3. ✅ First boot experience
4. ✅ Package updates (`apt update && apt upgrade`)
5. ✅ AMD GPU detection (if applicable)
6. ✅ Branding verification (no Ubuntu logos)

### Security

- Store GPG keys securely (use GitHub Secrets, never commit)
- Sign all release ISOs and checksums
- Publish GPG public key on website
- Generate and publish SBOM
- Keep base Ubuntu ISO up to date

---

## Additional Resources

- [Ubuntu ISO Customization Guide](https://help.ubuntu.com/community/LiveCDCustomization)
- [Squashfs Tools Documentation](https://github.com/plougher/squashfs-tools/blob/master/README)
- [Xorriso Manual](https://www.gnu.org/software/xorriso/man_1_xorriso.html)
- [Ubuntu Desktop Installer Whitelabel](https://canonical-subiquity.readthedocs-hosted.com/en/latest/)

---

## Support

For issues and questions:
- GitHub Issues: https://github.com/companionintelligence/CI-OS/issues
- Website: https://ci.computer/support

© Companion Intelligence — Lifescope Inc
