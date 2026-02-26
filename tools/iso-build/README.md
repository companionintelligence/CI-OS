# CI-OS ISO Build Tools

Tools and scripts for building custom CI-OS ISOs from Ubuntu 24.04.

© Companion Intelligence — Lifescope Inc

---

## Overview

This directory contains the complete toolchain for:

- Building custom Ubuntu 24.04-based CI-OS ISOs
- Creating and managing .deb packages
- Setting up package repositories
- Automating ISO builds in CI/CD

---

## Directory Structure

```
tools/iso-build/
├── scripts/
│   ├── build-iso.sh              # Main ISO builder
│   ├── customize-chroot.sh       # Chroot customization
│   ├── build-packages.sh         # Build .deb packages
│   ├── build-gdm-branding-gresource.sh # Build branded Yaru gresource
│   ├── stage-live-build-branding-package.sh # Stage .deb into live-build config/packages.chroot
│   └── setup-repository.sh       # Repository setup helper
├── configs/                       # Build configurations (future)
└── templates/                     # Templates (future)
```

---

## Quick Start

### Build an ISO

```bash
# Download Ubuntu 24.04 base ISO
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso

# Build CI-OS ISO
sudo ./scripts/build-iso.sh \
  --base-iso ubuntu-24.04.1-desktop-amd64.iso \
  --version 1.0
```

Output: `./output/companion-os-1.0-amd64.iso`

### Build Packages

```bash
# Build all .deb packages
./scripts/build-packages.sh ./output/packages
```

Output: `./output/packages/*.deb`

### Setup Repository

```bash
# Set your GPG key ID
export CI_OS_GPG_KEY=YOUR_KEY_ID

# Setup repository
sudo ./scripts/setup-repository.sh /srv/packages.ci.computer
```

---

## Scripts Reference

### build-iso.sh

Main ISO build orchestrator.

**Usage**:
```bash
sudo ./scripts/build-iso.sh [options]
```

**Options**:
- `--base-iso PATH` - Path to Ubuntu 24.04 Desktop ISO (required)
- `--output-dir PATH` - Output directory (default: `./output`)
- `--work-dir PATH` - Working directory (default: `./work`)
- `--version VERSION` - CI-OS version (default: `1.0`)
- `--sign` - Sign checksums with GPG
- `--clean` - Clean work directory before building

**What it does**:
1. Extracts base Ubuntu ISO
2. Extracts and mounts squashfs rootfs
3. Sets up chroot environment
4. Applies customizations via `customize-chroot.sh`
5. Repacks squashfs
6. Generates bootable ISO
7. Creates checksums (SHA256/MD5) - SBOM generated in CI workflow

**Requirements**:
- Root privileges
- Ubuntu 24.04+ build host
- Packages: `debootstrap`, `squashfs-tools`, `xorriso`, `rsync`, `gpg`
- Minimum 30GB free disk space

### customize-chroot.sh

Applies all CI-OS customizations to the chroot.

**Usage**:
```bash
./scripts/customize-chroot.sh <chroot_path> <version>
```

**What it does**:
1. **OS Identity**: Updates `/etc/os-release`, `/etc/lsb-release`, creates custom banner
2. **Telemetry Removal**: Purges Ubuntu tracking, blocks metrics domains
3. **Branding**: Installs CI-OS logos, wallpapers, sets GNOME defaults
4. **GRUB**: Updates boot configuration with CI-OS identity
5. **AMD GPU**: Installs drivers, creates ROCm helper script
6. **Installer**: Creates whitelabel.yaml, custom slides
7. **Utilities**: Installs `ci-os-info`, `ci-os-install-rocm` commands

**Customization**: Edit this script to modify OS behavior.

### build-packages.sh

Builds all .deb packages from `packages/` directory.

**Usage**:
```bash
./scripts/build-packages.sh [output_dir]
```

**Default output**: `./output/packages/`

**Packages built**:
- `companion-os-base` - Base system package
- `companion-os-keyring` - Repository keyring
- `companion-agents` - AI agents (stub)
- `companion-memory` - Memory system (stub)
- `mydistro-branding` - GDM Yaru gresource override using dpkg-divert

When `mydistro-branding` is built, `build-packages.sh` automatically runs:

- `scripts/build-gdm-branding-gresource.sh`

to generate `packages/mydistro-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource` from upstream Yaru with CI accent/assets.

**Add custom packages**: Create directory in `packages/` with `DEBIAN/control`.

### setup-repository.sh

Sets up reprepro-based package repository.

**Usage**:
```bash
export CI_OS_GPG_KEY=YOUR_KEY_ID
sudo ./scripts/setup-repository.sh [repo_root]
```

**Default repo root**: `/srv/packages.ci.computer`

**What it does**:
1. Installs reprepro
2. Creates directory structure
3. Configures reprepro for `noble` distribution
4. Exports GPG public key
5. Creates nginx configuration
6. Sets permissions

**Follow-up**: Run `certbot` for SSL, add packages with `reprepro`.

---

## CI/CD Integration

### GitHub Actions

The repository includes `.github/workflows/build-companion-os-iso.yml` for automated builds.

**Triggers**:
- Manual workflow dispatch
- Git tags (`v*`)
- Weekly schedule (Sundays 2 AM UTC)

**Outputs**:
- Bootable ISO
- SHA256/MD5 checksums
- GPG signatures (if configured)
- SBOM
- GitHub release

**Configuration**:
Set GitHub Secrets for signing:
- `GPG_PRIVATE_KEY` - GPG private key (armor format)
- `GPG_PASSPHRASE` - Key passphrase

---

## Build Process Flow

```
┌─────────────────────────────────────┐
│ Start: build-iso.sh                 │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 1. Extract base Ubuntu ISO          │
│    - Mount ISO                      │
│    - Copy contents                  │
│    - Extract squashfs               │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 2. Setup chroot environment         │
│    - Bind mount /dev, /proc, etc.   │
│    - Copy resolv.conf               │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 3. Run customize-chroot.sh          │
│    - Update OS identity             │
│    - Remove telemetry               │
│    - Install branding               │
│    - Configure AMD support          │
│    - Customize installer            │
│    - Clean up                       │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 4. Cleanup chroot                   │
│    - Unmount bind mounts            │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 5. Repack squashfs                  │
│    - Compress with xz               │
│    - Generate manifest              │
│    - Update filesystem.size         │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 6. Generate ISO                     │
│    - Update GRUB config             │
│    - Calculate MD5 sums             │
│    - Create hybrid ISO (xorriso)    │
│    - Support BIOS + UEFI            │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ 7. Generate artifacts               │
│    - SHA256/MD5 checksums           │
│    - GPG signatures (optional)      │
│    - SBOM                           │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Done: ISO ready in output/          │
└─────────────────────────────────────┘
```

---

## Customization Guide

### Change OS Name/Identity

Edit `scripts/customize-chroot.sh`:

```bash
# Around line 40
cat > "$CHROOT_PATH/etc/os-release" << 'EOF'
NAME="Your Custom OS"
VERSION="2.0"
...
EOF
```

### Add/Remove Packages

Edit `scripts/customize-chroot.sh`:

```bash
# In the remove-packages.sh section
apt-get purge -y unwanted-package

# Or install new packages
apt-get install -y new-package
```

### Change Branding

Replace files:
- Logo: `assets/logos/ci-holo-depth.png`
- Wallpaper: `setup/os-changes/background.png`

Edit `scripts/customize-chroot.sh` to reference new files.

### Custom Installer Theme

Edit `scripts/customize-chroot.sh` around line 280:

```bash
cat > "$CHROOT_PATH/usr/share/desktop-provision/whitelabel.yaml" << 'EOF'
theme:
  primary_color: "#your-color"
  accent_color: "#your-accent"
EOF
```

### Add Custom Scripts

1. Create script in `scripts/your-script.sh`
2. Call from `customize-chroot.sh`:
   ```bash
   copy_to_chroot "$SCRIPT_DIR/your-script.sh" "/tmp/custom.sh"
   chroot_exec "/tmp/custom.sh"
   ```

---

## Testing

### Test in VM

```bash
# Install QEMU
sudo apt install qemu-system-x86

# Test ISO
qemu-system-x86_64 \
  -cdrom output/companion-os-1.0-amd64.iso \
  -m 4G \
  -enable-kvm \
  -cpu host \
  -smp 2
```

### Test USB Boot

```bash
# Write to USB
sudo dd if=output/companion-os-1.0-amd64.iso of=/dev/sdX bs=4M status=progress

# Boot from USB on test machine
```

### Verify Checksums

```bash
cd output/
sha256sum -c SHA256SUMS
# Expected: companion-os-1.0-amd64.iso: OK
```

---

## Troubleshooting

### Build Fails: "No space left on device"

Free up space or use larger disk:

```bash
# Clean work directory
sudo rm -rf work/

# Check disk space
df -h
```

### Chroot Mounts Not Cleaned

Manually unmount:

```bash
sudo umount -lf work/chroot/{dev/pts,sys,proc,run,dev}
```

### ISO Won't Boot

- Verify base ISO is complete (check SHA256)
- Try rebuilding with `--clean` flag
- Test in VM before physical hardware

### Package Installation Fails in Chroot

Check network:

```bash
cat work/chroot/etc/resolv.conf
# Should have nameserver entries
```

---

## Performance Tips

### Faster Builds

1. **Use SSD** for work directory
2. **More RAM** speeds up compression
3. **Parallel compression**: Edit `customize-chroot.sh` mksquashfs to add `-processors $(nproc)`

### Smaller ISOs

1. Remove more bloatware in `customize-chroot.sh`
2. Use higher compression: `-comp xz -Xbcj x86` in mksquashfs
3. Clean package cache more aggressively

---

## Documentation

- [ISO Build Guide](../../docs/guides/iso-build-guide.md) - Complete build documentation
- [Installation Guide](../../docs/guides/installation-guide.md) - End-user installation
- [Quick Start Guide](../../docs/guides/quick-start-guide.md) - Get started fast
- [Package Repository Setup](../../docs/guides/package-repository-setup.md) - Repository hosting

---

## Support

- **Issues**: https://github.com/companionintelligence/CI-OS/issues
- **Documentation**: https://github.com/companionintelligence/CI-OS
- **Website**: https://ci.computer

---

© Companion Intelligence — Lifescope Inc
