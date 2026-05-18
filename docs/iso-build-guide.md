# CI OS ISO Build Guide

## Overview

This guide explains how to build a **bootable, installable** CI-OS ISO from a stock Ubuntu 24.04 Desktop ISO. The build system rebrands the installer, GDM login screen, GNOME Shell theme, and GRUB menus with CI-OS colors (`#00a9a7` teal, `#066c80` dark teal, grey retained).

## Prerequisites

### Build Host
- **Ubuntu 24.04 Desktop** (Noble) — **must have Yaru theme installed** (needed to extract and rebrand the GNOME Shell gresource)
- Root privileges
- ~30 GB free disk space

### Base ISO
Download Ubuntu 24.04.4 Desktop:
```bash
cd /home/ci/Development/COMPANION/CI-OS
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso
sha256sum ubuntu-24.04.4-desktop-amd64.iso  # verify checksum
```

### Install Build Dependencies
```bash
sudo apt-get install -y \
    squashfs-tools \
    xorriso \
    libglib2.0-dev \
    libglib2.0-bin \
    yaru-theme-gnome-shell \
    debootstrap \
    rsync \
    gpg \
    python3
```

## Build Process

### Quick Build (recommended)
```bash
cd /home/ci/Development/COMPANION/CI-OS
sudo ./tools/iso-build/scripts/build-iso.sh
```

### Full Build With Options
```bash
sudo ./tools/iso-build/scripts/build-iso.sh \
    --base-iso ./ubuntu-24.04.4-desktop-amd64.iso \
    --output-dir ./output \
    --version 1.0 \
    --clean
```

### Iterative Build (skip package rebuilding)
After the first build, if you only changed chroot customizations (not the gresource/theme):
```bash
sudo ./tools/iso-build/scripts/build-iso.sh --skip-packages
```

### Options Reference
| Flag | Default | Description |
|------|---------|-------------|
| `--base-iso PATH` | `./ubuntu-24.04.4-desktop-amd64.iso` | Path to Ubuntu 24.04 Desktop ISO |
| `--output-dir PATH` | `./output` | Where to write the built ISO |
| `--work-dir PATH` | `./work` | Temporary build directory (~20 GB) |
| `--version VER` | `1.0` | CI-OS version string |
| `--clean` | off | Delete work directory before building |
| `--skip-packages` | off | Skip .deb package and gresource build |
| `--sign` | off | GPG-sign the checksum files |

## What The Build Does

### Pipeline Steps

1. **Build .deb packages** — Extracts host Yaru gresource, remaps Ubuntu colors → CI colors, replaces logos, recompiles gresource
2. **Extract base ISO** — Mounts Ubuntu ISO, copies contents, extracts 3 squashfs layers into a merged chroot
3. **Customize chroot** — 11-step customization (identity, telemetry, theme, branding, GRUB, installer, packages, bootstrap)
4. **Generate manifest** — Captures `dpkg-query` package list while chroot mounts are active
5. **Repack squashfs** — Repacks chroot into `minimal.squashfs`, creates placeholder upper layers, regenerates `install-sources.yaml` and checksums
6. **Generate ISO** — Uses `xorriso --boot_image any replay` preserving the original volume label and EFI boot chain

### Chroot Customization Steps

| Step | Description |
|------|-------------|
| 1 | OS Identity — `NAME="CI-OS"` (keeps `ID=ubuntu` for installer compat, first-boot rebrand) |
| 2 | Telemetry removal — purges ubuntu-report, apport, bloatware games |
| 2b | GNOME/GDM theme — installs color-remapped gresource |
| 3 | Branding — logos, wallpaper, dconf defaults |
| 4 | GRUB — `GRUB_DISTRIBUTOR="CI-OS"` |
| 5 | Plymouth — placeholder |
| 6 | AMD GPU — firmware, Vulkan drivers, ROCm helper (`ci-os-install-rocm`) |
| 7 | Installer whitelabel — `whitelabel.yaml` with CI colors + slideshow |
| 8 | MOTD — CI-OS ASCII banner |
| 9 | `ci-os-info` command |
| 10 | APT repo template |
| 10b | Pre-installed dev packages (git, build-essential, htop, jq, etc.) |
| 10c | **Bootstrap scripts + first-boot setup service** |
| 11 | Final cleanup (caches, logs, history) |

## Bootstrap Scripts in the ISO

### What's pre-installed (in the squashfs, available offline)
- git, build-essential, ca-certificates, wget, curl, htop, jq, openssh-server, python3-pip
- AMD GPU firmware + Vulkan drivers
- All CI-OS branding and theme

### What's installed on first boot (needs network)
A systemd service (`ci-os-first-boot-setup.service`) runs after the first post-install boot:
- Docker CE + compose
- Homebrew, asdf, Node.js 22.15.1, Bun, UV
- Ollama + benchmark-recommended AI models via `ci-os-benchmark`, `ci-os-model-recommend`, and `ci-os-model-install`
- Express Setup + privacy controls (`ci-os-express-setup`, `ci-os-privacy-status`, `ci-os-privacy-apply`)
- Headless setup reporting (`ci-os-headless-status`)
- GitHub CLI, cloudflared, VS Code (snap), Tailscale
- GNOME power profile → performance

Manual trigger: `sudo ci-os-setup`
Express Setup trigger: `sudo ci-os-express-setup --yes`

AI model setup writes:
- `/var/lib/ci-os/benchmark.json`
- `/var/lib/ci-os/model-recommendations.json`
Express Setup writes:
- `/var/lib/ci-os/setup-report.json`
- `/var/lib/ci-os/privacy-status.json`
- `/var/lib/ci-os/headless-status.json`

The original scripts are also copied to `/usr/lib/ci-os/bootstrap/` for manual use.

## Color Scheme

| Role | Hex | Replaces |
|------|-----|----------|
| Primary teal | `#00a9a7` | Ubuntu orange `#E95420`, Ubuntu blue `#19B6EE` |
| Dark teal | `#066c80` | Ubuntu purple `#77216F` |
| Grey | kept as-is | — |

## Output

```
output/
├── companion-os-1.0-amd64.iso   # Bootable ISO
├── SHA256SUMS                     # SHA256 checksum
└── MD5SUMS                        # MD5 checksum
```

## Testing

### QEMU (EFI — recommended)
```bash
qemu-system-x86_64 \
    -bios /usr/share/ovmf/OVMF.fd \
    -cdrom output/companion-os-1.0-amd64.iso \
    -m 4096 -smp 2 \
    -enable-kvm
```

### VirtualBox
Enable EFI in VM settings → System → Enable EFI

### Physical USB
```bash
sudo dd if=output/companion-os-1.0-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

## Critical Design Decisions

### Why `ID=ubuntu` is kept in os-release
Subiquity/curtin rely on `ID=ubuntu` and `VERSION_ID=24.04` to configure APT sources, run curthooks, and install GRUB. Setting `ID=ci-os` **breaks the installer**. A first-boot systemd service rewrites to `ID=ci-os` after installation.

### Why the original ISO volume label is preserved
The EFI boot chain contains an **embedded GRUB config** that uses `search --set=root --label "Ubuntu 24.04.4 LTS amd64"` (or `--file /.disk/info`) to find the boot medium. `--boot_image any replay` replays this embedded image verbatim. Changing the volume label causes EFI GRUB to fail → **kernel panic (0x00000100)**.

The BIOS grub.cfg is edited surgically: only menuentry display text is changed, never `search` labels or boot parameters.

### Why squashfs uses placeholder layers
Ubuntu 24.04 casper expects three named layers. We merge all into `minimal.squashfs` and create valid-but-empty upper layers. OverlayFS handles this correctly.

## Troubleshooting

### Kernel panic on boot (0x00000100)
**Root cause**: Volume label mismatch between ISO and EFI embedded GRUB search.
- Verify the build uses the original volume label (check build log for `Original ISO volume id`)
- Verify `casper/` has all 3 .squashfs files + SHA256SUMS
- Do NOT blindly `sed s/Ubuntu/CI-OS/g` in grub.cfg — this breaks search commands

### Installer fails
- Verify `cat /etc/os-release` inside the squashfs has `ID=ubuntu` and `VERSION_ID=24.04`
- Check `casper/install-sources.yaml` has correct paths and sizes
- In live session: `cat /var/log/installer/subiquity-server-debug.log`

### GDM shows Ubuntu theme
- Build log should show `[+] GDM/GNOME Shell theme applied`
- Verify gresource exists at both:
  - `/usr/share/gnome-shell/gnome-shell-theme.gresource`
  - `/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource`

### First-boot setup didn't run
- Check: `systemctl status ci-os-first-boot-setup.service`
- Log: `/var/log/ci-os-first-boot-setup.log`
- Re-run: `sudo ci-os-setup`
