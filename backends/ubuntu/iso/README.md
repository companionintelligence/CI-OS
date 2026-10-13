# CI-OS ISO Build Tools

Tools and scripts for building the branded CI-OS ISO from Ubuntu 24.04 Desktop.

© Companion Intelligence — Lifescope Inc

---

## Quick Start

```bash
# 1. Download Ubuntu 24.04 base ISO (if you don't already have it)
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso

# 2. Build CI-OS ISO (single entry point — runs as root)
sudo ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso ./ubuntu-24.04.4-desktop-amd64.iso
```

Output: `./output/companion-os-1.0-amd64.iso`

---

## Build Host Requirements

**Must be Ubuntu 24.04 (Noble)** with Yaru theme installed.
The branding script extracts the Yaru gresource from the build host, so the
host OS must match the target OS version.

```bash
sudo apt-get install \
  squashfs-tools \
  xorriso \
  libglib2.0-bin \
  libglib2.0-dev-bin \
  yaru-theme-gnome-shell \
  debootstrap \
  rsync \
  gpg \
  cpio \
  zstd \
  imagemagick \
  librsvg2-bin
```

Minimum **30 GB free disk space** (work directory + ISO output). The build needs **network access**:
it runs `apt` inside the image (Ubuntu archive and Docker's apt repository) while pre-installing
the CI-Hub and wireless setup tools.

`imagemagick` scales the Plymouth logo and `librsvg2-bin` / `imagemagick` render the GRUB background; `verify-iso.sh` fails the image if either is missing. To verify a built ISO (below) you only need `xorriso squashfs-tools zstd cpio`.

> **Building on a Mac or any non-Ubuntu host:** run the whole build in a privileged
> `ubuntu:24.04` container (`docker run --privileged --platform linux/amd64 ...`) with the repo and
> the base ISO mounted and a named Docker volume for `--work-dir` and `--output-dir`. A privileged
> container is needed for the chroot's `proc`/`dev` mounts.

---

## How It Works (Two-Step Build)

### Step 1 — Build packages and branded gresource

`build-iso.sh` first calls `build-packages.sh`, which:

1. Iterates over all package directories in `packages/`
2. For `ci-os-branding`, calls `build-gdm-branding-gresource.sh`:
   - Extracts the upstream Yaru gresource from `/usr/share/gnome-shell/theme/Yaru/`
   - Remaps all Ubuntu orange (`#E95420`) and purple (`#77216F`) and Ubuntu blue
     (`#19B6EE`) hex values in CSS to CI teal (`#00a9a7` / `#066c80`)
   - Replaces Ubuntu logo SVGs with the CI logo banner
   - Recompiles the patched theme into a new `.gresource` binary
   - Audits remaining brand colors and prints a summary
3. Builds each package into `output/packages/*.deb`

The compiled gresource is committed to source at:
`backends/ubuntu/packages/ci-os-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource`

### Step 2 — Assemble the ISO

`build-iso.sh` then:

1. Mounts and extracts the base Ubuntu ISO
2. Unsquashes all three casper layers into a merged chroot
3. Runs `backends/ubuntu/chroot/customize-chroot.sh` on the extracted rootfs to apply:
   - OS identity (CI-OS name, version, first-boot rebrand service)
   - Telemetry/bloatware removal
   - **Branding**: copies the compiled gresource directly into the chroot at
     `/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource` and
     `/usr/share/gnome-shell/gnome-shell-theme.gresource`
   - GRUB configuration
   - AMD GPU / ROCm helper tools
   - Installer whitelabel (whitelabel.yaml, slides)
   - MOTD and CI-OS utilities
4. Repacks squashfs, regenerates casper manifests
5. Generates bootable ISO with xorriso (inheriting EFI/BIOS boot from base ISO)
6. Produces SHA256/MD5 checksums

---

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--base-iso PATH` | *(required)* | Path to Ubuntu 24.04 Desktop ISO |
| `--output-dir PATH` | `./output` | Where the finished ISO is written |
| `--work-dir PATH` | `./work` | Scratch space (needs ~25 GB) |
| `--version VERSION` | `1.0` | CI-OS version string embedded in ISO |
| `--clean` | off | Wipe work directory before building |
| `--skip-packages` | off | Skip `build-packages.sh` (iterative builds only — use when packages/gresource haven't changed) |
| `--sign` | off | GPG-sign SHA256SUMS and MD5SUMS |

---

## Directory Structure

```
backends/ubuntu/iso/
├── README.md                              ← This file
└── scripts/
    ├── build-iso.sh                       ← Main entry point (run this)
    ├── build-packages.sh                  ← Builds all .deb packages
    ├── build-gdm-branding-gresource.sh    ← Builds branded Yaru gresource
    ├── stage-live-build-branding-package.sh  ← Stages .deb into config/packages.chroot
    └── setup-repository.sh                ← reprepro repository setup helper

scripts/
└── customize-chroot.sh                  ← Chroot customization (OS identity,
                                              branding, AMD GPU, installer, etc.)

packages/
└── ci-os-branding/
    ├── DEBIAN/
    │   ├── control      ← Package metadata
    │   ├── postinst     ← Adds dpkg-divert for gresource override
    │   ├── prerm        ← Removes divert on uninstall
    │   └── postrm
    └── usr/share/gnome-shell/theme/Yaru/
        └── gnome-shell-theme.gresource    ← Compiled branded theme (regenerated by build)

assets/
├── logos/
│   ├── 2024_CI__Logo_Banner_Color_small.svg   ← CI logo used in GDM/GNOME Shell
│   └── ci-holo-depth.png                      ← CI logo for pixmaps
├── package theme assets/
│   ├── checkbox-focused-light.svg
│   ├── checkbox-light.svg
│   ├── checkbox-off-focused-light.svg
│   └── toggle-on-light.svg
└── wallpapers/
    └── ci-os-wallpaper.svg                    ← Fallback wallpaper

config/
└── packages.chroot/
    └── mydistro-branding_1.0_all.deb          ← STALE — regenerate with build-packages.sh
```

> **Note:** `config/packages.chroot/` contains a stale `.deb` from the old
> `mydistro-branding` package name. The live-build staging path is not part of
> the active build pipeline — `build-iso.sh` copies the gresource directly.
> Run `./backends/ubuntu/iso/scripts/build-packages.sh` and then
> `./backends/ubuntu/iso/scripts/stage-live-build-branding-package.sh` if you need
> to refresh it.

---

## Branding Details

### CI Teal Color Palette

| Role | Hex | Usage |
|------|-----|-------|
| Primary teal | `#00a9a7` | Accent, highlights, selection |
| Dark teal | `#066c80` | Secondary accent, focus rings |

### Colors replaced in Yaru CSS

| Original | Replaced with |
|----------|--------------|
| `#E95420` / `#e95420` (Ubuntu orange) | `#00a9a7` |
| `rgb(233, 84, 32)` | `rgb(0, 169, 167)` |
| `rgba(233, 84, 32, ...)` | `rgba(0, 169, 167, ...)` |
| `#77216F` / `#77216f` (Yaru aubergine) | `#066c80` |
| `rgb(119, 33, 111)` | `rgb(6, 108, 128)` |
| `rgba(119, 33, 111, ...)` | `rgba(6, 108, 128, ...)` |
| `#19B6EE` / `#19b6ee` (Ubuntu blue) | `#00a9a7` |
| `rgb(25, 182, 238)` | `rgb(0, 169, 167)` |
| `rgba(25, 182, 238, ...)` | `rgba(0, 169, 167, ...)` |

After replacement, the script audits all CSS files and prints any remaining
Ubuntu brand color occurrences so they can be caught manually.

### Logo replacement

All SVG files in the Yaru theme whose filename contains `ubuntu` (case-insensitive),
plus `logo.svg` and `logo-text.svg`, are replaced with the CI logo banner:
`assets/logos/2024_CI__Logo_Banner_Color_small.svg`

---

## Iterative Development

When you've already built packages and only changed `backends/ubuntu/chroot/customize-chroot.sh`:

```bash
sudo ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso ./ubuntu-24.04.4-desktop-amd64.iso \
  --skip-packages
```

When you've changed branding assets or colors (must rebuild gresource):

```bash
# Rebuild just the gresource manually
./backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh

# Or let build-iso.sh handle it (default, no --skip-packages)
sudo ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso ./ubuntu-24.04.4-desktop-amd64.iso
```

---

## Testing

### Quick VM Test

```bash
sudo apt install qemu-system-x86

qemu-system-x86_64 \
  -cdrom output/companion-os-1.0-amd64.iso \
  -m 4G \
  -enable-kvm \
  -cpu host \
  -smp 2
```

### USB Boot Test

```bash
sudo dd if=output/companion-os-1.0-amd64.iso of=/dev/sdX bs=4M status=progress
```

### Verify Checksums

```bash
cd output/
sha256sum -c SHA256SUMS
```

### Verify the image contents (pre-installed tools and branding)

```bash
backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-1.0-amd64.iso
```

Needs no root and does not boot the ISO. It extracts the root squashfs, the initrd and a few files and
asserts that every CI-Hub and wireless-setup tool is pre-installed, that the hotspot units are guarded
against live sessions, and that the visible branding is Companion OS while `ID=ubuntu`, `DISTRIB_ID`,
`BUILD_SYSTEM` and the ISO volume id (which apt, casper, the installer and Secure Boot depend on) are
untouched. Exit status is non-zero if any check fails.

---

## What is pre-installed

| Group | What | Notes |
|---|---|---|
| Wireless setup | `setup-device` package: hostapd, dnsmasq, nginx-light, python3-flask, gunicorn, network-manager, iw, and the portal, backend, hotspot and monitor scripts and units | Enabled for the installed system; guarded off in live sessions |
| CI-Hub runtime | Docker Engine, Compose and Buildx (Docker's apt repo, key pinned by fingerprint), curl, jq, the CI-Hub deploy scripts under `/usr/lib/ci-os/bootstrap/` | The same Docker source as `core/manifest/role-map/apt.yaml`, so first boot skips it |
| Left to first boot, on purpose | The CI-Hub container image (needs registry credentials and device pairing), model pulls, per-user developer tools | See `core/manifest/ecosystem.yaml` (`ci_hub`) |

## What stays Ubuntu, and why

These cannot be changed by remastering the image, and `verify-iso.sh` lists them as known:

- **The installer window.** It is Canonical's `ubuntu-desktop-bootstrap` snap. Its flavour list is fixed
  (Ubuntu, Kubuntu, Lubuntu, Xubuntu, Edubuntu), so "Welcome to Ubuntu" is inside the snap. The launcher
  label ("Install Companion OS ...") is ours, via `/.disk/info`. Rebranding the window means shipping a
  modified installer snap.
- **The ISO volume id.** Casper and the signed EFI GRUB search for it.
- **`ID=ubuntu`, `ID_LIKE`, `UBUNTU_CODENAME`, `DISTRIB_ID=Ubuntu`, `BUILD_SYSTEM=Ubuntu`.** apt, curtin,
  casper and `unattended-upgrades` key off them.

---

## Troubleshooting

### "Source gresource not found"

The build host must be Ubuntu 24.04 with Yaru installed:

```bash
sudo apt-get install yaru-theme-gnome-shell
```

### "No space left on device"

```bash
sudo rm -rf work/
df -h
```

### Chroot mounts left behind

```bash
sudo umount -lf work/chroot/{dev/pts,sys,proc,run,dev}
```

### ISO won't boot

- Verify the base ISO SHA256 matches the release checksum
- Try `--clean` to rebuild from scratch
- Test in VM before writing to USB

---

## CI/CD

The repository includes `.github/workflows/build-companion-os-iso.yml` for
automated builds triggered by tags, manual dispatch, or weekly schedule.
See that workflow for GitHub Secrets required for GPG signing.

---

## Support

- **Issues**: https://github.com/companionintelligence/CI-OS/issues
- **Website**: https://ci.computer

---

© Companion Intelligence — Lifescope Inc
