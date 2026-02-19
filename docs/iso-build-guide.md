# CI OS ISO Build Guide

## Overview

This guide walks through creating a customized Ubuntu 24.04 ISO with CI OS branding, dark green theme, and pre-installed configuration. The resulting ISO can be used to install CI OS on bare metal or VMs.

## Prerequisites

### Build Environment
- **Host OS**: Ubuntu 22.04 or 24.04 (or Debian-based distro)
- **Disk Space**: At least 25GB free
- **RAM**: 8GB minimum (16GB recommended)
- **Tools**: 
  - Cubic (recommended) or manual ISO remastering tools
  - squashfs-tools
  - xorriso
  - git

### Source ISO
- **Base**: Ubuntu 24.04 LTS Desktop (Noble Numbat)
- **Download**: https://releases.ubuntu.com/24.04/
- **Checksum**: Verify SHA256 checksum before use

## Method 1: Using Cubic (Recommended)

Cubic is a GUI tool that simplifies ISO customization.

### Install Cubic

```bash
sudo apt-add-repository universe
sudo apt-add-repository ppa:cubic-wizard/release
sudo apt update
sudo apt install --no-install-recommends cubic
```

### Cubic Workflow

1. **Launch Cubic**
   ```bash
   cubic
   ```

2. **Create Project**
   - Select project directory (e.g., `~/cubic/ci-os`)
   - Select source ISO (Ubuntu 24.04 Desktop)
   - Click "Next"

3. **Customize Chroot Environment**
   
   Cubic opens a terminal inside the live system. Run:
   
   ```bash
   # Update package lists
   apt update
   
   # Clone CI OS repository
   cd /root
   git clone https://github.com/companionintelligence/CI-OS.git
   cd CI-OS
   
   # Run complete rebranding
   cd setup/os-changes
   chmod +x *.sh
   ./complete-rebranding.sh --skip-reboot-check
   
   # Optional: Install additional packages
   apt install -y \
       gnome-remote-desktop \
       code \
       docker.io \
       ollama
   
   # Clean up
   apt clean
   apt autoremove -y
   rm -rf /root/CI-OS/.git  # Remove git history to save space
   
   # Exit when done
   exit
   ```

4. **Customize Installer (Optional)**
   
   In Cubic's file browser tab, navigate to:
   - `/usr/share/plymouth/themes/` - Verify Plymouth theme
   - `/etc/os-release` - Verify OS identity
   - `/usr/share/backgrounds/` - Verify wallpaper

5. **Generate ISO**
   - Configure ISO metadata:
     - Disk name: `CI OS 0.0.1`
     - Volume ID: `CI-OS-001`
     - Filename: `ci-os-0.0.1-amd64.iso`
   - Click "Generate"
   - Wait for ISO creation (10-30 minutes)

6. **Test ISO**
   ```bash
   # Boot in QEMU for quick test
   qemu-system-x86_64 -cdrom ~/cubic/ci-os/ci-os-0.0.1-amd64.iso -m 4G -enable-kvm
   ```

## Method 2: Manual Remastering

For more control or automation in CI/CD.

### Extract Base ISO

```bash
#!/bin/bash
set -euo pipefail

BASE_ISO="ubuntu-24.04-desktop-amd64.iso"
WORK_DIR="$HOME/ci-os-build"
ISO_EXTRACT="$WORK_DIR/iso"
SQUASH_DIR="$WORK_DIR/squashfs"

mkdir -p "$WORK_DIR" "$ISO_EXTRACT" "$SQUASH_DIR"

# Mount and copy ISO contents
sudo mount -o loop "$BASE_ISO" /mnt
sudo rsync -a /mnt/ "$ISO_EXTRACT"/
sudo umount /mnt

# Make writable
sudo chmod -R u+w "$ISO_EXTRACT"

# Extract squashfs (main filesystem)
sudo unsquashfs -d "$SQUASH_DIR" "$ISO_EXTRACT/casper/filesystem.squashfs"
```

### Customize Squashfs

```bash
#!/bin/bash
set -euo pipefail

SQUASH_DIR="$HOME/ci-os-build/squashfs"

# Prepare chroot environment
sudo mount --bind /dev "$SQUASH_DIR/dev"
sudo mount --bind /run "$SQUASH_DIR/run"
sudo mount -t proc none "$SQUASH_DIR/proc"
sudo mount -t sysfs none "$SQUASH_DIR/sys"
sudo mount -t devpts none "$SQUASH_DIR/dev/pts"

# Copy DNS config
sudo cp /etc/resolv.conf "$SQUASH_DIR/etc/resolv.conf"

# Copy CI OS repo into chroot
sudo cp -r /path/to/CI-OS "$SQUASH_DIR/root/"

# Enter chroot
sudo chroot "$SQUASH_DIR" /bin/bash <<'CHROOT_SCRIPT'
#!/bin/bash
set -euo pipefail

# Update
apt update

# Apply CI OS branding
cd /root/CI-OS/setup/os-changes
chmod +x *.sh
./complete-rebranding.sh --skip-reboot-check

# Optional: Preinstall packages
apt install -y \
    gnome-remote-desktop \
    code \
    docker.io

# Clean up
apt clean
apt autoremove -y
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*
rm -rf /root/CI-OS/.git

# Update initramfs
update-initramfs -u -k all

exit
CHROOT_SCRIPT

# Unmount
sudo umount "$SQUASH_DIR/dev/pts"
sudo umount "$SQUASH_DIR/sys"
sudo umount "$SQUASH_DIR/proc"
sudo umount "$SQUASH_DIR/run"
sudo umount "$SQUASH_DIR/dev"
```

### Repack ISO

```bash
#!/bin/bash
set -euo pipefail

WORK_DIR="$HOME/ci-os-build"
ISO_EXTRACT="$WORK_DIR/iso"
SQUASH_DIR="$WORK_DIR/squashfs"
OUTPUT_ISO="ci-os-0.0.1-amd64.iso"

# Regenerate squashfs
sudo rm "$ISO_EXTRACT/casper/filesystem.squashfs"
sudo mksquashfs "$SQUASH_DIR" "$ISO_EXTRACT/casper/filesystem.squashfs" \
    -comp xz -b 1M -Xdict-size 100%

# Update filesystem.size
sudo du -sx --block-size=1 "$SQUASH_DIR" | cut -f1 > "$ISO_EXTRACT/casper/filesystem.size"

# Update manifest
sudo chroot "$SQUASH_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' \
    | sudo tee "$ISO_EXTRACT/casper/filesystem.manifest" > /dev/null

# Calculate MD5 sums
cd "$ISO_EXTRACT"
sudo find . -type f -print0 | sudo xargs -0 md5sum | \
    grep -v isolinux/boot.cat | sudo tee md5sum.txt > /dev/null

# Create ISO
sudo xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "CI-OS-001" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "../$OUTPUT_ISO" \
    .

echo "ISO created: $WORK_DIR/$OUTPUT_ISO"
```

## Automated Build Pipeline (GitHub Actions)

See `.github/workflows/build-companion-os-iso.yml` for automated ISO builds.

Basic structure:

```yaml
name: Build CI OS ISO

on:
  release:
    types: [published]
  workflow_dispatch:

jobs:
  build-iso:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Download base ISO
        run: wget https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop-amd64.iso
      
      - name: Install dependencies
        run: |
          sudo apt update
          sudo apt install -y squashfs-tools xorriso isolinux
      
      - name: Build ISO
        run: ./scripts/build-iso.sh
      
      - name: Upload ISO
        uses: actions/upload-artifact@v3
        with:
          name: ci-os-iso
          path: ci-os-*.iso
```

## Post-Build Steps

### Test ISO

1. **VM Testing**
   ```bash
   # QEMU
   qemu-system-x86_64 -cdrom ci-os-0.0.1-amd64.iso -m 4G -enable-kvm
   
   # VirtualBox
   VBoxManage createvm --name "CI OS Test" --ostype Ubuntu_64 --register
   VBoxManage modifyvm "CI OS Test" --memory 4096 --vram 128
   VBoxManage storagectl "CI OS Test" --name "IDE" --add ide
   VBoxManage storageattach "CI OS Test" --storagectl "IDE" --port 0 --device 0 \
       --type dvddrive --medium ci-os-0.0.1-amd64.iso
   VBoxManage startvm "CI OS Test"
   ```

2. **Physical Hardware** (recommended before release)
   - Test on at least one target AMD GPU system
   - Verify Plymouth boot splash
   - Verify login screen theme
   - Verify desktop theme consistency

### Generate Checksums

```bash
sha256sum ci-os-0.0.1-amd64.iso > ci-os-0.0.1-amd64.iso.sha256
md5sum ci-os-0.0.1-amd64.iso > ci-os-0.0.1-amd64.iso.md5
```

### Sign ISO (Optional but Recommended)

```bash
# Create GPG signature
gpg --armor --detach-sign ci-os-0.0.1-amd64.iso

# Verify
gpg --verify ci-os-0.0.1-amd64.iso.asc ci-os-0.0.1-amd64.iso
```

## Validation Checklist

Before releasing ISO:

### Visual Checks
- [ ] Plymouth boot splash shows CI logo with dark green background (#066c80)
- [ ] Boot messages show "CI OS" (not Ubuntu)
- [ ] Login screen uses dark green theme
- [ ] Desktop theme is dark green throughout
- [ ] Wallpaper is CI OS wallpaper
- [ ] Start menu icon is CI logo

### System Checks
- [ ] `cat /etc/os-release` shows CI OS identity
- [ ] `lsb_release -a` shows CI OS
- [ ] No "Ubuntu" branding visible in UI
- [ ] MOTD shows CI OS welcome message
- [ ] Network, sound, graphics work correctly

### Installation Checks
- [ ] Installer launches correctly
- [ ] Can install to disk without errors
- [ ] Installed system retains CI OS branding
- [ ] First boot shows proper theme

## Troubleshooting

### ISO Won't Boot

Check:
- UEFI boot structure: `/boot/grub/efi.img` present
- BIOS boot: `/isolinux/isolinux.bin` present
- Hybrid ISO structure: Used `isohybrid-gpt-basdat` flag

### Chroot Errors

```bash
# If network doesn't work in chroot
sudo cp /etc/resolv.conf "$SQUASH_DIR/etc/resolv.conf"

# If locale errors
sudo chroot "$SQUASH_DIR" locale-gen en_US.UTF-8
```

### Plymouth Not Showing

```bash
# In chroot, regenerate initramfs
update-initramfs -u -k all
update-grub
```

### Squashfs Too Large

```bash
# Compress more aggressively
sudo mksquashfs "$SQUASH_DIR" filesystem.squashfs \
    -comp xz -b 1M -Xdict-size 100% -Xbcj x86

# Remove unnecessary packages
sudo chroot "$SQUASH_DIR" apt purge -y \
    thunderbird libreoffice-* transmission-* rhythmbox
```

## References

- [Ubuntu ISO Remastering](https://help.ubuntu.com/community/LiveCDCustomization)
- [Cubic Documentation](https://github.com/PJ-Singh-001/Cubic)
- [CI OS Theme Guide](dark-green-theme-guide.md)
- [ISO 9660 / El Torito Spec](https://wiki.osdev.org/ISO_9660)

## Future Enhancements

- [ ] Automated daily builds
- [ ] Multiple desktop environment variants (GNOME, KDE, XFCE)
- [ ] Minimal/Server ISO variant
- [ ] OEM installation mode
- [ ] Custom installer with CI OS slideshow
- [ ] Secure Boot signing
