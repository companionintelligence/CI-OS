# Companion OS ISO Build Tools

Tools and scripts for building the branded Companion OS ISO from the Ubuntu 26.04.1 LTS Desktop ISO
(`ubuntu-26.04.1-desktop-amd64.iso`, "Resolute Raccoon"). Ubuntu 26.04 is the only Ubuntu release this builds on: 24.04
(noble) is retired. Numbers in this file that were measured on 24.04.5 are labelled "retired baseline (24.04.5)"; the 26.04.1
facts (the stock ISO's layers, `md5sum.txt`, `install-sources.yaml`, sessions, About logo files ...) were read off the real ISO.

© Companion Intelligence — Lifescope Inc

---

## Quick Start

```bash
# 1. Download the Ubuntu 26.04.1 base ISO (if you don't already have it) and check it. (The directory also lists
#    ubuntu-26.04-desktop-amd64.iso, the 26.04.0 image: take the .1 file.)
wget https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso
echo '601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f  ubuntu-26.04.1-desktop-amd64.iso' | sha256sum -c -

# 2. Build the Companion OS ISO (single entry point — runs as root, on Ubuntu 26.04)
sudo ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso ./ubuntu-26.04.1-desktop-amd64.iso
```

Output: `./output/companion-os-1.0-amd64.iso`

---

## Build Host Requirements

**Must be Ubuntu 26.04 (Resolute)** with the Yaru theme installed (`build-iso.sh` stops at the start on any other
Ubuntu, or on a host that is not Ubuntu, unless `CI_OS_ALLOW_OTHER_BUILD_HOST=1`). The branding script extracts the Yaru
gresource from the build host, so the host's Yaru has to be the one of the GNOME Shell 50 the image carries. On 26.04 the
coreutils are uutils (Rust) and `sudo` is sudo-rs; the scripts here use only forms that behave the same
(`stat -c`, `du -sx --block-size=1`, `chmod --reference`, `install -D`, `dd iflag=skip_bytes,count_bytes` ... were run
against uutils 0.10.0 in the 26.04 container, see Testing).

```bash
sudo apt-get install \
  squashfs-tools \
  xorriso \
  libglib2.0-bin \
  libglib2.0-dev-bin \
  yaru-theme-gnome-shell \
  rsync \
  gpg \
  cpio \
  zstd \
  initramfs-tools-core \
  imagemagick \
  librsvg2-bin \
  curl
```

Minimum **35 GB free disk space** (work directory + ISO output, plus the 1.4 GB Ollama tarball cache in
`~/.cache/ci-os`, override with `CI_OS_CACHE_DIR`). The build needs **network access**: it runs `apt`
inside the image (Ubuntu archive, Docker's, Tailscale's, Cloudflare's and GitHub's apt repositories) and
downloads the Ollama release tarball (github.com) and the Companion Launcher `.deb` (dl.ci.computer) while
pre-installing the tools. Every third-party key fingerprint and download hash is pinned in
`core/manifest/tier-b-pins.env` and the build fails closed on a mismatch.

The stock desktop image has no image renderer, so the logo PNGs are rendered on the build host from the vendored SVG marks (`core/render/render-mark-png.sh`): `librsvg2-bin` (`rsvg-convert`) renders the greeter logo, the Settings > About logo and the GRUB background, and `imagemagick` scales the Plymouth logo and composes the GRUB background. `build-iso.sh` stops at the start if either is missing, and `verify-iso.sh` fails an image built without them. `unmkinitramfs` (`initramfs-tools-core` 0.151, a 3cpio-based program that extracts all four segments of the 26.04 initrd flat into one directory; a desktop install has it, a minimal container or a bare `ubuntu:26.04` does not) unpacks the stock casper initrd to take the live Plymouth theme files from it. To verify a built ISO (below) you only need `xorriso squashfs-tools zstd cpio python3`.

> **Building on a Mac or any non-Ubuntu host:** run the whole build in a privileged `ubuntu:26.04` container with a clean tree of the repo,
> the base ISO mounted read-only and a named Docker volume for `--work-dir` and `--output-dir`. A privileged container is needed for the
> chroot's `proc`/`dev` mounts. **On Apple silicon use an ARM64 container** (`--platform linux/arm64`): it is the route that built and verified
> the image, and the image's x86-64 chroot runs through the Docker VM's Rosetta binfmt handlers. An amd64 `ubuntu:26.04` container may fail
> (GNU tar 1.35 reported "Function not implemented" under Rosetta once; the trigger was not isolated). The full, tested recipe is in
> [`docs/guides/building-on-a-mac.md`](../../../docs/guides/building-on-a-mac.md#recipe) and in the root `README.md`; do not use the
> `--platform linux/amd64` form that an earlier version of this note gave. (A `ubuntu:24.04` container is not a build host any more: its Yaru
> and its `unmkinitramfs` do not match the 26.04.1 image.)

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
2. Unsquashes all three stock casper layers (`minimal`, `minimal.standard`, `minimal.standard.live`) into one merged chroot,
   the rootfs `C` that the next step customizes
3. Runs `backends/ubuntu/chroot/customize-chroot.sh` on the extracted rootfs to apply:
   - OS identity (Companion OS name, version, first-boot rebrand service)
   - Telemetry/bloatware removal
   - **Branding**: copies the compiled gresource directly into the chroot at
     `/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource` and
     `/usr/share/gnome-shell/gnome-shell-theme.gresource`
   - **Logos** (the brand mark, `vendor/brand/logos/`): the dock's bottom "Show Applications" button
     (Yaru `start-here-symbolic.svg`, generated by `40-start-icon.sh` from the vendored
     `mark-mono.svg`: its path data, `currentColor`, viewBox cropped), the Settings > About logo (`/usr/share/pixmaps/ubuntu-logo-text.png`
     and `-dark.png`: the one-colour mark in the canon primary of each mode), the `ci-os-logo` icon that
     `LOGO=` in os-release names (setup-device's payload ships the same file for its Hub launcher entry,
     "Companion Hub (browser)", on both editions that install the payload: Ubuntu and, through `stage-headless.sh`, CachyOS), and the greeter logo (`/usr/share/pixmaps/companion-logo.png`: the
     colour mark at 256 px). The package-owned stock files are `dpkg-divert`ed to `*.ubuntu-stock`, so an
     `apt upgrade` cannot restore Ubuntu's. `customize-chroot.sh` runs these and the Plymouth step from
     `backends/ubuntu/desktop-theme/` inside the chroot with `run_theme_step` (Steps 5, 5b, 5c): the same
     code the post-install re-skin runs.
   - **Visible names** (`60-visible-names.sh`, Step 5d): the display names Ubuntu still showed. GDM's gear menu
     lists the one session as "Companion OS" (`wayland-sessions/ubuntu.desktop` `Name=`/`Comment=`; Ubuntu 26.04.1 has no Xorg session and
     no other session file),
     the Settings sidebar entry reads "Companion OS Desktop" (`gnome-ubuntu-panel.desktop`), and the Extensions
     app lists "Companion OS Dock", "Companion OS AppIndicators" and "Companion OS Tiling Assistant". Only
     those lines change, on a copy and with the stock file diverted. File names, extension uuids, `Exec=`,
     `DesktopNames=` and the other identifiers the session and shell find them by stay Ubuntu's. On a live
     system a file that is missing or has a stock text the step does not know is reported and skipped; in an
     image build the step fails instead, because the base ISO has every one of these files and `verify-iso.sh` requires
     every one of them to read Companion OS.
   - GRUB configuration
   - AMD GPU / ROCm helper tools
   - The installer's product name: there is **no installer whitelabel step** (the installer is Canonical's snap and its text is fixed); the launcher
     label and the last page read the name from `/.disk/info`, which the boot-media step rewrites
   - MOTD and CI-OS utilities
4. Deletes the snapd seed of Ubuntu's TPM full-disk-encryption variant from `C` (`remove_esb_seed`; 0.66 GB the stock live layer carries:
   `seed/systems/enhanced-secureboot-desktop` and the pc-kernel, pc, second firefox and nvidia component snap files in `seed/snaps` that
   `seed.yaml` does not name). This image ships none of the `enhanced-secureboot` layers and offers no such variation, so the variant
   cannot be installed from it and the seed is dead weight on a medium that must fit a Stick boot slot (see [Size](#size-and-the-stick-boot-slot)).
   It is in neither layer afterwards; the split's own rows and `verify-iso.sh` keep it out of the installed layer and check the live layer too.
   Not boot-tested: that the live session and the installer behave the same without the seed rests on the installer examining the layers
   `install-sources.yaml` names (it lists no such variation) and on `seed.yaml`, not `systems/`, being the live session's classic seed.
5. Splits the customized rootfs `C` back into layers (`repack_squashfs`, `scripts/lib/split-live-layer.sh`; see
   [Layers](#layers-what-the-installer-installs-and-what-only-the-live-session-sees)): `minimal.squashfs` is `C` minus the live-only
   content (the `casper` package and its files, the live dconf overrides, the installer's own snap, the live image's cloud-init, getty
   and udisks settings, ...) and is the **only layer the installer copies to the disk**; `minimal.standard.live.squashfs` holds exactly
   what must be stacked on it to give `C` back, so the live session is unchanged; `minimal.standard.squashfs` stays an empty
   placeholder whose directory modes mirror the rootfs, so `/tmp` stays `1777` in the overlay. The build mounts the three packed layers,
   stacks them as casper does and stops unless the stack equals `C` and the base holds no live-only content. All the other stock layers
   (the language layers and the 20 `enhanced-secureboot` layers, with their `.size`, `.manifest` and `.manifest.full` files) are removed first.
   It then writes the true `.size`, `.manifest` and `.manifest.full` files of the three layers, `install-sources.yaml` (26.04.1's version 2
   mapping with the stock `kernel:` block copied verbatim; the installer still installs `minimal.squashfs` alone, no language layers) and
   `casper/SHA256SUMS` (the three layers). The ISO pool's apt source `/etc/apt/sources.list.d/cdrom.sources` is disabled in the chroot
   only while `apt-get update` runs and put back before packing: subiquity 26.04 expects it in the installed layer
6. Brands the live boot media (`brand_boot_media`). The live session's splash is drawn from Plymouth files
   inside `casper/initrd`, which the rootfs theming never reaches, so a small zstd cpio overlay is appended to
   the stock initrd (padded to 4 bytes; the kernel unpacks concatenated archives in order and later files win,
   and the stock archives stay byte for byte as they were). It carries `casper.conf`, the watermark (a regular file; the
   stock one is a symlink into `pixmaps`; the 26.04.1 initrd has no `ubuntu-logo.png` any more), the firmware-logo fallback `bgrt-fallback.png` (the colour mark at 128 px, in place of Ubuntu's; the
   plugin only draws it if a theme asks for the firmware background again, see
   [Live boot splash](#live-boot-splash-plymouth)), and the initrd's own `bgrt.plymouth`,
   `spinner.plymouth` and `ubuntu-text.plymouth` repainted from the brand tokens (navy ground, sage progress bar,
   the text splash titled `Companion OS <version>`) with `ci_plymouth_recolor` / `ci_plymouth_text_theme` from
   `core/lib/theme-lib.sh`, the helpers the rootfs step uses. The `Font=` lines stay Ubuntu's, the only fonts that
   initrd carries. Stock `bgrt`, the default theme, asks for the firmware background in every mode, which makes
   Plymouth's two-step plugin paint black whatever `BackgroundStartColor` says (an image built before `4382caa` showed a
   black splash with navy colour lines), so `ci_plymouth_recolor` also switches `UseFirmwareBackground` off, in the overlay's copy and in
   the rootfs copy alike: the live splash is the navy ground with the spinner and the Companion lockup, and the
   installed system's is the same. What that costs on real hardware, and what a boot still has to prove, is in
   [Live boot splash](#live-boot-splash-plymouth). The kernel's acceptance of the overlay was seen in a QEMU
   boot of the image built from `584a867` (the lockup watermark in the overlay was on screen); a boot of an image built from
   `4382caa` or later is still the proof.
7. Themes the live GRUB menu (`brand_live_grub`: background image and token-derived colours in
   `boot/grub/grub.cfg`, see [Live GRUB menu](#live-grub-menu)), then generates the bootable ISO with
   xorriso (inheriting EFI/BIOS boot from base ISO). The image's own `/md5sum.txt` is rewritten in the same
   xorriso run (`write_md5sum_txt`, [below](#disc-integrity-md5sumtxt-inside-the-image)) and the finished
   image is read back against it before the build succeeds
   `/.disk/info` is rewritten from `Ubuntu 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)` to `Companion OS 26.04.1 LTS ...`: the
   product's name, with a blank, because one reader of the file puts it on a screen. The installer's last page says "<name> is installed
   and ready to use" with the text before the codename's quote (the recorded 24.04.5 run, which wrote the name with a hyphen, shows
   "Companion-OS 24.04.5 LTS is installed and ready to use"; the 26.04.1 installer snap has the same string and reads the same file).
   What the blank costs the other readers, read from 26.04.1's own files and asserted by `verify-iso.sh` section 5 and
   `tests/boot-media-plymouth.sh` (casper's lines run over the rewritten line): casper's launcher label ("Install RELEASE": fields 1-2, plus
   " LTS" when field 3 is `LTS`) becomes "Install Companion OS", with no release and no LTS; and subiquity's `refresh.py` takes the second
   word, now "OS", for the release it names its snap channel after (`stable/ubuntu-OS`), which it never acts on: `configure_snapd`
   switches the channel only when the installer snap tracks `stable/ubuntu-<release of the live system>`, and the snap's seed entry says
   `26.04/stable/ubuntu-26.04.1`. `verify-iso.sh` reads that channel from the image's own `seed.yaml`, so a base whose installer snap
   tracked `stable/ubuntu-26.04` would fail the build instead of silently switching channels. The first page and the review page of the
   installer say "Ubuntu" whatever this file says (see [What stays Ubuntu](#what-stays-ubuntu-and-why)). An earlier revision kept the
   hyphen and said no user reads it; the screenshot of the done page shows otherwise.
   The ISO volume id stays `Ubuntu 26.04.1 LTS amd64` (the signed GRUB finds the medium by it; the build refuses to guess one).
7. Produces SHA256/MD5 checksums

---

## Layers: what the installer installs and what only the live session sees

The Ubuntu 26.04.1 desktop ISO keeps its root filesystem in three stacked squashfs layers (`minimal`, `minimal.standard`,
`minimal.standard.live`; the ISO has 41 layer files in all, the rest being per-language and TPM-encryption variants that this image does not ship).
casper (the live session) mounts all three;
subiquity and curtin (the installer) copy **one stack to the disk, the one `casper/install-sources.yaml` names**, and the third layer,
`minimal.standard.live.squashfs`, is named by no entry. Everything that belongs to the live session alone lives there: the `casper`
package and its initramfs hook, the live session's dconf overrides, the installer's own snap, the live image's cloud-init, getty and
udisks settings, a polkit rule and a sysctl file for the installer, and the snapd seed of the TPM full-disk-encryption variant. That is why a
stock install never has them. (On 26.04.1 the live layer is thin: 2 883 paths, 51 packages added and the dracut packages removed; on
24.04.5 it was 56 270 paths.)

Until the split this build merged the three layers, customized the result and put **all of it** into `minimal.squashfs`. The installer
copied the live-only content to the disk, and casper's initramfs hook (`BOOT=casper` in every initrd regenerated there) made the
installed system stop at "Unable to find a medium containing a live file system". The live ISO boots fine in that state, which is why
nothing showed it until a complete install of the v7 image (2026-10-15 and 16). The comment in `build-iso.sh` that said a
`filesystem.manifest-remove` was "not needed" and that "subiquity handles package removal" was wrong for the merged design: subiquity
has no removal step, and stock Ubuntu only avoids the problem by never installing the live layer.

| Layer | Content now | Seen by |
|---|---|---|
| `minimal.squashfs` | the customized rootfs minus the live-only content (kernels, firmware and bootloader stay: the installed system needs them; initramfs-tools stays, see below) | live session and **installer** |
| `minimal.standard.squashfs` | empty placeholder | live session, and installer entry 2 (adds nothing) |
| `minimal.standard.live.squashfs` | exactly what must be stacked on the two others to give the customized rootfs back: casper and its files, the live-only files, the stock versions of the files the live image rewrote | **live session only** |

**The installed system is initramfs-tools based.** Ubuntu 26.04.1's minimal layer (the stock installed system) is dracut based; its live layer
whites dracut out and installs initramfs-tools for casper. The build merges all three layers, so the base it gives back is initramfs-tools
based, and curtin's `update-initramfs` step runs initramfs-tools'. `customize-chroot.sh` pins `dracut` and `dracut-core` (not `dracut-install`: initramfs-tools-core depends on it, and a -1 pin would freeze its updates) to
Pin-Priority -1 in `/etc/apt/preferences.d/ci-os-no-dracut` (`ubuntu-desktop-minimal` recommends dracut, which conflicts with
initramfs-tools), and `verify-iso.sh` asserts the pin, initramfs-tools installed and dracut absent. The header of `build-iso.sh` has the reasoning.

### Size and the Stick boot slot

`ci-stick flash` writes the ISO raw into the stick's `CI-BOOT-A` slot and refuses one that does not fit. The slot is the stick's usable space
divided by 10, clamped to 8..48 GiB (`ci-stick-layout/1`), so a **64 GB stick has 8 GiB (8,589,934,592 bytes)** and a 128 GB one 11 GiB.
`verify-iso.sh` section 9 fails an image above 8 GiB (`VERIFY_MAX_ISO_BYTES=<n>` sets another limit for a build meant for bigger sticks only, `0` turns
the check off), so an oversize image is found by the build and not by whoever flashes it.

What is measured (2026-10-18; the build's own `repack_squashfs`, so its production compression, `xz -b 1M`, in an `ubuntu:26.04` container;
the rootfs is the STOCK 26.04.1 merged the way `extract_squashfs` does, with `remove_esb_seed` applied, standing in for a customized one):

| | bytes |
|---|---|
| stock `ubuntu-26.04.1-desktop-amd64.iso` | 6,482,409,472 |
| its 41 casper layer files (3 layers, 18 language layers, 20 enhanced-secureboot layers) | 5,058,371,584 |
| `minimal.squashfs` (the installed base, B) | 3,803,525,120 |
| `minimal.standard.live.squashfs` (the live-only layer, L) | 117,178,368 |
| `minimal.standard.squashfs` (empty placeholder) | 4,096 |
| rootfs `du`, before and after `remove_esb_seed` | 9,064,407,040, then 8,402,255,872 (the seed: 662,151,168) |
| **image without any Companion OS addition** | **5,344,745,472 (4.98 GiB)** |

The seed matters: snap files do not compress, so L would have been about 0.78 GB instead of 117 MB and the floor 6.0 GB. On top of the floor come
the pre-installed tools: `docs/architecture/tier-b-tools.md` section 6 measured Ollama's CUDA libraries at 1.52 GB (24 MB with
`CI_OS_OLLAMA_CUDA=none`), the other optional tools at about 0.1 GB, and the Docker and wireless additions are estimated at 0.3 GB (unmeasured).
That adds up to **about 7.3 GB (6.8 GiB) with everything on, about 5.8 GB with `CI_OS_OLLAMA_CUDA=none`**: inside the 8 GiB slot by about 1.3 GB. That
sum is arithmetic over pieces measured on different bases, not a build. **The first complete Companion OS image built on 26.04.1 measures
7,076,577,280 bytes (6.59 GiB)** with every optional bake on (clean checkout at `02c575e`, 2026-10-18, `docs/evidence/2026-10-18-ubuntu-clean-02c575e/`),
so 1,513,357,312 bytes are spare in an 8 GiB slot, and the estimate above was about 3 percent high. `verify-iso.sh` section 9 prints the spare
bytes on every build. An earlier estimate of 7.5 to 9.5 GB did not take the seed out of the live layer.

The list of what is live-only, the reason for each row, how to extend it, what each test proves and the test status are in
[`docs/architecture/ubuntu-iso-layers.md`](../../../docs/architecture/ubuntu-iso-layers.md). `verify-iso.sh` section 3g and
`tests/verify-installer-base.sh` guard it, `tests/installed-boot.sh` boots an installed system built from the base layer.

---

## Flags

The environment variables (`CI_OS_BAKE_*`, `CI_OS_OLLAMA_CUDA`, `CI_OS_CACHE_DIR`, `CI_OS_ALLOW_OTHER_BUILD_HOST`, `VERIFY_*`, ...) are tabulated in the
[environment reference](../../../docs/guides/environment-reference.md).

| Flag | Default | Description |
|------|---------|-------------|
| `--base-iso PATH` | `./ubuntu-26.04.1-desktop-amd64.iso` | Path to the Ubuntu 26.04.1 Desktop ISO |
| `--output-dir PATH` | `./output` | Where the finished ISO is written |
| `--work-dir PATH` | `./work` | Scratch space (needs ~25 GB) |
| `--version VERSION` | `1.0` | Companion OS version string embedded in ISO |
| `--clean` | off | Wipe work directory before building. Without it the chroot of the previous run is reused: the stock layers are extracted over it again and the customization re-runs on top, so every step must be repeat-safe. The `dpkg-divert` helper is (`core/lib/tests/divert-file.sh` runs it through a rebuild in a throw-away container) |
| `--skip-packages` | off | Skip `build-packages.sh` (iterative builds only — use when packages/gresource haven't changed) |
| `--sign` | off | GPG-sign SHA256SUMS and MD5SUMS |

---

## Directory Structure

Tracked files only (`git ls-files backends/ubuntu`); the layout below is what the build reads. Generated output (`work/`, `output/`) is not tracked.

```
backends/ubuntu/
├── iso/
│   ├── README.md                            ← This file
│   ├── scripts/
│   │   ├── build-iso.sh                     ← Main entry point (run this, as root on Ubuntu 26.04)
│   │   ├── build-packages.sh                ← Builds the .deb packages and the branded gresource
│   │   ├── build-gdm-branding-gresource.sh  ← Thin caller of core/render/render-gnome-shell-gresource.sh (Yaru data)
│   │   ├── yaru-color-map.pl                ← The orange-to-teal ramp for the Yaru CSS
│   │   ├── yaru-audit-patterns.txt          ← Regression patterns for pre-rebrand Yaru colours
│   │   ├── md5sum-txt.sh                    ← Writes and verifies the image's /md5sum.txt
│   │   ├── verify-iso.sh                    ← Inspects a built ISO without booting it
│   │   ├── lib/split-live-layer.sh          ← The installer-base / live-only split and its table
│   │   ├── stage-live-build-branding-package.sh  ← Unused by the build: stages the .deb into a live-build path
│   │   └── setup-repository.sh              ← reprepro repository helper (status: docs/guides/package-repository-setup.md)
│   └── tests/                               ← See "Testing" below; tests/lib/ holds the harness code, tests/fixtures/ the stock-ISO facts
├── chroot/
│   ├── customize-chroot.sh                  ← Chroot customization (identity, branding, Docker, tools, installer, first boot)
│   ├── payload/                             ← apt, docker, live-start (the one-click installer), models, ssh
│   └── tests/                               ← customize-chroot checks, models-*.sh, test_auto_install.py, first-boot-units-boot.sh
├── packages/
│   ├── PROVENANCE-gnome-shell-theme.txt     ← Input and output hashes of the branded gresource
│   └── ci-os-branding/                      ← The GNOME Shell theme .deb: DEBIAN/{control,postinst,prerm,postrm} and
│                                              usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource (rebuilt by the build)
├── provision/, desktop-theme/, lib/, headless-package/   ← see the repository README
assets/
├── logos/                                   ← 2024_CI__LogoMark_Color_med.svg, 2024_CI__Logo_Banner_Color_small.svg, ci-holo-depth.png (not installed)
├── package theme assets/                    ← four checkbox and toggle SVGs for the Shell theme
└── wallpapers/ci-os-wallpaper.svg           ← Fallback wallpaper
```

> **Note:** `stage-live-build-branding-package.sh` copies the `.deb` into `config/packages.chroot/`, a live-build path. This build does not use
> live-build and there is no `config/` directory in the repository (an older version of this file showed a stale `mydistro-branding` package
> there). The active pipeline copies the gresource directly into the chroot.

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

### Live GRUB menu

The menu you see when the ISO itself is booted (a disc, or the image written to a USB drive) is
`boot/grub/grub.cfg` on the medium. The base ISO's is a text menu; `build-iso.sh` (`brand_live_grub`) gives
it the canon look and nothing else. A Companion Stick has its own menu (`ci-stick/grub.cfg`, from
`stick/crates/ci-stick/templates/grub.cfg.in`) and is not themed here:

| Part | Value | Where it comes from |
|---|---|---|
| Background | `/boot/grub/ci-os-bg.png`: the mark on the dark canon background, 1920x1080, 8-bit RGB | `core/render/render-grub-background.sh` (the installed system's `/usr/share/pixmaps/ci-os-grub-bg.png` is the same file) |
| Entries | `menu_color_normal=white/black` | nearest GRUB colour to `CI_DARK_FOREGROUND` |
| Highlight | `menu_color_highlight=black/cyan` | nearest GRUB colour to `CI_ACCENT_AQUA` |

GRUB takes colour *names* from a fixed table of 16, never hex, so the pair is derived, not hand-picked:
`ci_grub_nearest_color` in `core/lib/grub-merge.sh` returns the nearest name by RGB distance, and
`verify-iso.sh` recomputes it from `vendor/brand/tokens/tokens.sh`. A token change that moves the nearest
name changes the menu on the next build (`core/lib/tests/grub-nearest-color.sh` pins the function).

**Known cosmetic limit: the background is a fixed 1920x1080 image, and GRUB stretches `background_image` to the
screen.** On a 16:9 screen the mark is round, on 16:10 slightly tall, and on a 4:3 mode, such as the 800x600 that QEMU
and many first-run VMs give the menu, it is drawn as a vertical oval (measured: 1.34 times as tall as wide at 800x600). Only the picture is
affected: the entries, the colours and booting work, and Secure Boot is unaffected. It is accepted rather than fixed
because the options trade worse things: `background_image -m normal` centres the image without scaling and leaves
black borders on any screen larger than 1920x1080, and forcing a `gfxmode` changes how GRUB probes video on real
hardware. A fix would be a few backgrounds at different aspect ratios (or a smaller mark on a plain navy field,
where the stretch is invisible) chosen by `if`, which has not been done.

The change is one block that `build-iso.sh` inserts after the existing `loadfont unicode` line, guarded by
`if loadfont unicode` so a GRUB without the font keeps the text menu:

```
if loadfont unicode ; then
  set gfxmode=auto
  insmod gfxterm
  insmod png
  terminal_output gfxterm
  background_image /boot/grub/ci-os-bg.png
fi
```

Secure Boot's chain is untouched. The block `insmod`s only `gfxterm` and `png`, which are built into Canonical's
signed GRUB (any other module is a separate file that Secure Boot refuses to load, so GRUB prints an error at every boot; whether it
also stops for a keypress was not tested). **`all_video` is not among them: the 24.04 image had it built in, GRUB 2.14's 26.04.1 CD
image does not** (95 built-in modules, `efi_gop`, `gfxterm`, `png`, `video` and `video_fb` among them, read from the ISO's
`EFI/boot/grubx64.efi` with `stick/scripts/grub-builtin-modules.py`; a string search of the binary finds
`feature_all_video_module`, a feature flag, which is not the module). `efi_gop`, the video driver the menu uses, is built in and
registers itself, so nothing replaces it. The module list is committed (`tests/fixtures/grub-cd-builtin-modules-26.04.1.txt`) and
`tests/grub-live-menu-modules.sh` holds the block to it, so a new `insmod` that the image lacks fails `check-repo.sh` and not a
boot. The signed `bootx64.efi`, `grubx64.efi` and `mmx64.efi`, the ESP image and the volume id are the base ISO's, and the
`menuentry`, `linux` and `initrd` lines and `loopback.cfg` are not touched. `verify-iso.sh` checks the `insmod` set, looks every
module of it up in the built-in list of the `EFI/boot/grubx64.efi` on the ISO, and with `VERIFY_BASE_ISO` compares the three signed
binaries byte for byte. A new base ISO (a point release) can change the built-in set: re-read it (`CI_TEST_STOCK_ISO=<iso> bash
tests/grub-live-menu-modules.sh` does, G4) before trusting the committed list.

### Live boot splash (Plymouth)

The live session's splash is drawn by the copy of Plymouth inside `casper/initrd`, from the initrd's own theme files (the
rootfs copies are not read until the session's own shutdown). Its default theme is `bgrt` (`default.plymouth` in the initrd
points at it; there is no `plymouthd.conf`), so the files that matter are `bgrt.plymouth` and its images in the `spinner`
directory. `brand_boot_media` appends them, repainted, in the initrd overlay (see step 6 above).

**Which image is meant.** The images are named by the commit they were built from, not by a number. `584a867` is the build
that was booted and measured for this section (the 1.0 image, sha256 `f79c09d17777a856cff51cf96e3773d3dbfc90e3ff0e6dcc54737cbe86a36e76`):
its live splash was black. `4382caa` is the commit that made the ground canon navy, so an image built from it or later is the
one this section describes.

**What decides the ground colour.** Plymouth's two-step plugin (24.004.60, `src/plugins/splash/two-step/plugin.c`) fills the
screen with `BackgroundStartColor` / `BackgroundEndColor` only if no firmware background is in use. Stock `bgrt` has
`UseFirmwareBackground=true` in `[boot-up]`, `[shutdown]` and `[reboot]`; the plugin then loads the ACPI BGRT image (the
firmware's own boot logo) or, where the machine has none, `bgrt-fallback.png`, fills the screen with a hard-coded
`0x000000` and draws that image on it. The colour lines are never read. It is all or nothing: the plugin loads the firmware
images if any mode asks for them and then paints black in every mode that does not. The `spinner` theme has no such key, so
there the ground is whatever `BackgroundStartColor` says.

| Theme file | Ground the plugin draws |
|---|---|
| stock `bgrt` | black, with the firmware logo or `bgrt-fallback.png` on it |
| navy colour lines, `UseFirmwareBackground=true` (before `4382caa`) | black, the same |
| navy colour lines, `false` in `[boot-up]` only | black: `[shutdown]` and `[reboot]` still ask |
| navy colour lines, `false` in all three (`4382caa` on) | `#041620`, the canon dark background |
| `spinner`, navy colour lines | `#041620` |

**What the build does since `4382caa`.** `ci_plymouth_recolor` sets `UseFirmwareBackground=false` wherever the key is set, and it is the one
helper both the initrd overlay (`build-iso.sh`) and the installed system (`10-plymouth.sh`) use, so the live boot, the live
session's own shutdown splash and the installed system show the same navy ground: the two copies of each theme have the same
keys and values apart from the fonts (the initrd has no Cantarell), and `verify-iso.sh` compares them. The build fails
if a repainted theme still asks for the firmware background. The Companion lockup watermark is unchanged. What is on the
screen is the navy ground, the spinner and the lockup; `bgrt-fallback.png` (the colour mark) is still installed and diverted,
but the plugin no longer loads it, so it is only drawn if a theme ever asks for the firmware background again.

**The real-hardware trade-off, and the choice made.** The firmware background exists to make the hand-over from the
vendor's boot logo seamless: Plymouth repaints the same logo, at the offset the firmware drew it, on black, so a machine with
a BGRT table goes from the vendor logo to the splash without a visible change. Forcing navy gives that up for brand
consistency: the vendor logo is no longer repainted, and the first Plymouth frame is a flat navy screen. This was chosen
because the ground is the brand's, and because on the live medium the seamless hand-over was never there: the boot menu
(navy, 30 second timeout) sits between the firmware logo and the kernel, so the path is firmware logo, navy GRUB menu,
splash, and a black splash after the navy menu was the one visible cut. It is now navy to navy. On an **installed** system
with GRUB's menu hidden (the Ubuntu default for a single OS) the firmware logo goes straight to the splash, so there the
cut from the vendor's black to navy is the price. Anyone who wants the vendor hand-over back for installed systems removes
the `UseFirmwareBackground` line from `ci_plymouth_recolor` (and the matching checks in `build-iso.sh`,
`verify-iso.sh` and the three tests, `desktop-theme/tests/plymouth-theme.sh`, `tests/boot-media-plymouth.sh` and
`tests/plymouth-ground-render.sh`, the last of which expects navy and goes black without the key); a ground that is navy AND a repainted vendor logo is not possible with this plugin,
because the black fill is hard-coded.

**What is proven where.** `tests/plymouth-ground-render.sh` starts the real `plymouthd` of the Ubuntu packages on its X11
renderer in a virtual X server and reads the ground off screenshots: black for the stock theme, for the theme as it was before
`4382caa` and for a theme switched off in `[boot-up]` only, `#041620` for the repainted `bgrt` and `spinner`.
`tests/boot-media-plymouth.sh` builds the overlay against a stock-shaped fixture initrd and, only when
`CI_TEST_STOCK_INITRD=<the casper/initrd of the stock ISO>` is set (it is opt-in, nothing sets it by default), also against the
real stock initrd; it checks the files, the padding, the byte-identical stock part and that the kernel-style merge (stock archives, then the
overlay) differs from the stock tree in the overlay's files only. `verify-iso.sh` section 7 checks the shipped ISO. **Not
shown until an image from `4382caa` or later has been booted:** the colour on the live framebuffer of a real or QEMU guest (the ground logic is in the plugin,
above the renderer, but the DRM, simpledrm and efifb renderers are not exercised by the X11 test); that the kernel accepts
and applies the appended overlay and that Plymouth then reads the new `bgrt.plymouth` (the `584a867` image showed it applies the overlay's
watermark, not that this file is read); the `nomodeset` entry, which uses the frame-buffer renderer; whether a black frame
still shows between the GRUB menu and the first Plymouth frame; and any real BGRT firmware.

---

## Iterative Development

When you've already built packages and only changed `backends/ubuntu/chroot/customize-chroot.sh`:

```bash
sudo ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso ./ubuntu-26.04.1-desktop-amd64.iso \
  --skip-packages
```

When you've changed branding assets or colors (must rebuild gresource):

```bash
# Rebuild just the gresource manually
./backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh

# Or let build-iso.sh handle it (default, no --skip-packages)
sudo ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso ./ubuntu-26.04.1-desktop-amd64.iso
```

---

## Testing

### Script tests: what runs where

Every suite of the repository, with what it needs and which one to run for which change, is in one table in [`docs/guides/running-the-tests.md`](../../../docs/guides/running-the-tests.md); this section keeps the Ubuntu ISO detail.

Two of the ISO tests run automatically: `core/lib/check-repo.sh` (and so the PR checks) runs `tests/md5sum-txt.sh` and
`tests/grub-live-menu-modules.sh`, besides the Ubuntu 26.04 backend's other host suites listed under the table. **The others are
manual: run the ones that cover a file before you push a change to it**, because nothing else runs them, and a regression in them
otherwise shows up only after a one-hour build (or in `verify-iso.sh`, which the manual `build-companion-os-iso.yml` workflow runs).

| Test | Covers | Where it runs |
|---|---|---|
| `tests/md5sum-txt.sh` | `md5sum-txt.sh`, the md5sum.txt wiring in `build-iso.sh` (`write_md5sum_txt`, `check_base_md5sum`, `generate_iso`) | **the fast gate**: `core/lib/check-repo.sh` runs it (awk, find, a hash tool; with `xorriso` and GNU `dd`, as in PR checks, also the mini-ISO part) |
| `tests/grub-live-menu-modules.sh` | the live GRUB menu's `insmod` lines against the module list of the signed GRUB's CD image (`tests/fixtures/grub-cd-builtin-modules-26.04.1.txt`, 95 modules, no `all_video`): the block in `build-iso.sh` (any shell), the real `brand_live_grub` on the real stock `grub.cfg` (GNU sed and stat: a container), and with `CI_TEST_STOCK_ISO` the list against the ISO's own `EFI/boot/grubx64.efi` | **the fast gate**: `core/lib/check-repo.sh` runs it |
| `tests/boot-media-plymouth.sh` | `brand_boot_media`, the initrd overlay, the `.disk/info` rewrite and the installer launcher's label computed with casper's own lines | manual, throw-away `ubuntu:26.04` container (`unmkinitramfs`, `cpio`, `zstd`); `CI_TEST_STOCK_INITRD=<stock casper/initrd>` adds the real stock initrd |
| `tests/plymouth-ground-render.sh` | what the real Plymouth plugin draws, `ci_plymouth_recolor` | manual, throw-away container (`plymouth`, `xvfb`; command in its header) |
| `desktop-theme/tests/plymouth-theme.sh` | the rootfs Plymouth step, its diversions | manual, throw-away container (command in its header) |
| `tests/placeholder-layer-modes.sh` | `make_placeholder_layer`: the empty `minimal.standard.squashfs` keeps the rootfs directory modes (the live layer's modes are checked by `verify-iso.sh` section 3e and `tests/split-live-layer.sh`) | manual, privileged container (`squashfs-tools`, overlayfs) |
| `tests/verify-logo-surfaces.sh` | the logo checks of `verify-iso.sh` (section 4b): every variant must produce the FAIL line that names its defect, so a check that is switched off cannot hide behind another that fails for the same file; the stock-wordmark checks run against a copy of the section whose sha256 constant is the variant's own file | manual, container with `python3` and a renderer |
| `tests/verify-installer-base.sh` | `verify-iso.sh` section 3g (every check of "the installer base layer is clean", the live layer's seed), the live menu's `insmod` modules against the signed GRUB on the image (section 5, with a synthetic GRUB image from `tests/lib/make-grub-image.py`) and the Stick boot-slot size limit (section 9) each fail on the defect they are for, and so do the one-click launcher, the diverted Plymouth files (a symlinked stock copy included), the one-session check, the GNOME Shell theme (section 4d), the `/.disk/info` chain (product name, launcher label, the subiquity channel guard), the volume id, and the initrd overlay and its `plymouthd.conf` (those need `unmkinitramfs`) (226 variants on a small synthetic image, 52 of them taken from the split library's own lists; run it against weakened copies of the script to test the test: `VERIFY_ISO_SCRIPT=<copy>`, which has to sit in a tree that looks like the repo, as `weak_copy` in the test builds it) | manual, container with `xorriso squashfs-tools zstd cpio python3`, 1 to 3 minutes |
| `tests/split-live-layer.sh` | the split of the merged rootfs into the installer base and the live-only layer (`scripts/lib/split-live-layer.sh`): Part A the helpers on synthetic trees, Part B the whole split on a real merged rootfs and the stock layers (B1 audits the stock live layer: every live-only path is in the table or is kept-package state; then overlay of the layers equals the rootfs, no casper in the base, true `.size`, `.manifest` and `.manifest.full`) | Part A anywhere (bash 3.2 is enough); Part B manual, privileged container with the layers on a volume (command in its header); the STOCK layers merged by `extract_squashfs` stand in for a customized rootfs until a build exists |
| `tests/installed-boot.sh` | the INSTALLED system boots: a disk built the way an install ends up from the installer base layer, initrds regenerated (initramfs-tools, as curtin does), then booted in QEMU to the greeter | manual, privileged Docker plus QEMU, minutes to tens of minutes; header has the options; `--selftest` (its parts, seconds: the boot watcher against a fake QEMU, the initrd audit, and the in-guest probe against stand-in `loginctl`, `pgrep` and `plymouth`, for GDM 46's `gdm` and GDM 50's `gdm-greeter`) and `--quick` (the static audit of the base layer, about a minute) |
| `core/lib/tests/*.sh` | `ci_grub_nearest_color`, `ci_divert_file`, `check-untracked-deps.sh` | `untracked-deps.sh`: the fast gate; the others manual |

The Ubuntu 26.04 backend's other suites, outside this directory. `check-repo.sh` runs these on any host (a suite that needs a tool the
host lacks exits 2 and is reported as "cannot run here", not failed): `backends/ubuntu/lib/tests/{os-release-golden,install-rocm-driver,strix-halo-boot-params,lact-release,shell-theme}.sh`
(`strix-halo-boot-params.sh` rehearses `lib/strix-halo-boot-params.sh` on throwaway GRUB files and needs GNU sed and bash 4, so it exits 2 on a Mac),
`backends/ubuntu/chroot/tests/customize-chroot-checks.sh` (the refusal of a base that is not Ubuntu 26.04, 24.04 included),
`backends/ubuntu/headless-package/tests/control-depends.sh`, `core/render/tests/gresource-provenance.sh` and `core/lib/tests/untracked-deps.sh`.
These are manual, in a throw-away `ubuntu:26.04` container (command in each header): `backends/ubuntu/chroot/tests/no-dracut-pin.sh` (apt, simulated),
`backends/ubuntu/desktop-theme/tests/{about-logo-svg,visible-names,about-logo-no-renderer,start-icon-from-mark,plymouth-theme}.sh`,
`backends/ubuntu/chroot/tests/render-preflight.sh`, `backends/ubuntu/headless-package/tests/netplan-keeps-networkmanager.sh`, `core/lib/tests/divert-file.sh` (root, dpkg),
and Part B of `tests/split-live-layer.sh`. Part B is also what audits a NEW base ISO: bumping `BASE_ISO_SHA256` (see the comment next to it in
`build-companion-os-iso.yml`) starts with `SPLIT_TEST_ONLY="B1"` on the new stock layers.

Touching `core/lib/theme-lib.sh` (`ci_plymouth_recolor`), `build-iso.sh`'s `brand_boot_media`, or `md5sum-txt.sh` means running
the tests in that table that cover it. For the whole image, `verify-iso.sh` with `VERIFY_BASE_ISO` set (the CI workflow does)
also compares the Secure Boot binaries and the initrd's stock bytes with the stock ISO.

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

### Disc integrity (`md5sum.txt` inside the image)

The live medium carries `/md5sum.txt`, and the live system checks it on **every boot**: casper's
`casper-md5check.service`, enabled in the live layer (`minimal.standard.live.squashfs`: it is casper's, so the installed system has none), runs `/usr/lib/casper/casper-md5check /cdrom /cdrom/md5sum.txt`
over it. For each `<md5>  ./<path>` line it prints `<path>: OK` or `<path>: mismatch` and it ends with "errors found in N
files" or "no errors found"; a file that is listed but cannot be opened is one error. The result is in
`journalctl -u casper-md5check` and `/run/casper-md5check.json`, and `fsck.mode=skip` on the kernel command line skips the
check. Ubuntu 26.04.1's GRUB has **no menu entry** for it (the menu is "Try or Install", "safe graphics", "Boot from next
volume" and "UEFI Firmware Settings"), so a stale file was not an opt-in defect: it was hit on every live boot.

This build replaces the casper layers and manifests, the initrd, `grub.cfg`, `loopback.cfg` and `.disk/info`, deletes the
stock language layers and adds the GRUB background, so Ubuntu's own `md5sum.txt` is wrong for all of them (the image built from
`584a867`: 14 mismatches, 55 listed files that are gone, 1 unlisted file) and the check failed on every Companion OS image.
`build-iso.sh` now rewrites it with [`md5sum-txt.sh`](scripts/md5sum-txt.sh):

- the stock hash is kept for every file the build does not touch; the files the xorriso operations replace are hashed from their
  sources; entries of deleted files are dropped; new files are added; the whole list is written sorted by path in the C locale,
  as Ubuntu 26.04.1's own is (24.04.5.1's was in `find` order);
- the stock exclusions stay out, and they are exactly three on 26.04.1: `/md5sum.txt` itself, `/boot.catalog` (xorriso does not even
  report it as a regular file) and the BIOS boot image `/boot/grub/i386-pc/eltorito.img` (its boot-info-table is patched on every
  remaster). Unlike 24.04's file, the three Secure Boot files under `/EFI/boot` and the other 611 files under
  `/boot/grub/{fonts,i386-pc,x86_64-efi}` ARE listed (948 entries, 950 regular files). The script proves the base
  ISO still follows exactly that (`check-stock`) and that its own hashes are right (`verify` on the base ISO, because the stock
  hash of every untouched file is copied into the new file); both run before any build work, and a base ISO of another shape or
  with a damaged file stops the build. Both were run on the real `ubuntu-26.04.1-desktop-amd64.iso`: `check-stock` holds
  (948 entries, 950 regular files, 2 reported as excluded, sorted) and `verify` matches all 948 entries;
- the list of files is computed from the very `-rm_r` / `-map` operations that xorriso is given, so the two cannot drift,
  and the file is mapped in by the same run, as its last map. Any problem fails the build, including a hash or a file listing
  that fails half way (no blank hash, no dropped file); there is no fallback to the stock file;
- after xorriso, the finished image is read back (`md5sum-txt.sh verify`): every listed file is hashed by streaming it out of
  the ISO (`xorriso -find ... report_lba` for the extents, then `dd | md5sum`, so nothing is extracted), which takes about a
  minute or two (retired baseline (24.04.5): 34 to 37 s for the 7.7 GB `584a867` image, 22 s for its stock ISO, on a native Linux host; the
  6.4 GB stock 26.04.1 ISO took 1 min 41 s through a Docker Desktop bind mount with uutils' `dd` and `md5sum`; it is I/O-bound), and the build fails if
  anything differs. An image that fails this, or that xorriso could not write, is renamed to `NAME.rejected` and no checksums are
  written; the earlier run's image, `.rejected` file and checksums are deleted before xorriso starts, so the output directory never
  holds an image next to the checksums of another build. `verify-iso.sh` section 8 runs the same check on any ISO.

```bash
backends/ubuntu/iso/scripts/md5sum-txt.sh verify output/companion-os-1.0-amd64.iso   # prints MISMATCH / MISSING / UNLISTED lines and a SUMMARY
backends/ubuntu/iso/tests/md5sum-txt.sh                                              # the logic on a synthetic tree and a mini ISO
```

`tests/md5sum-txt.sh` needs only awk and a hash tool for its first part (a stock macOS with bash 3.2 is enough); with
`xorriso` and a `dd` with `iflag=skip_bytes,count_bytes` (GNU or uutils) it also remasters a mini ISO exactly as `build-iso.sh` does (with an El Torito image,
a boot catalog and `-boot_image any replay`; the mini ISO's files and menus have the real 26.04.1 shapes), runs `generate_iso` on it and shows that `verify` fails on the stale stock file. With
`CI_TEST_STOCK_ISO=<the 26.04.1 ISO>` it also runs `check-stock` and `verify` on the real image. `core/lib/check-repo.sh`
runs it. A file over 4 GiB is too big to build there: the two-extent path that the 5.6 GB `casper/minimal.squashfs` takes is tested
with a report written by hand in xorriso's format and a fake image. On a real image the same code can be checked by hand against
`casper/SHA256SUMS` (take the extents from `xorriso -indev ISO -find /casper/minimal.squashfs -exec report_lba --`, one `lba`
and `blocks` pair per `xt` row):

```bash
( source backends/ubuntu/iso/scripts/md5sum-txt.sh
  iso_stream_hash ISO.iso <size in bytes> '<lba>:<blocks>,<lba>:<blocks>' sha256sum )   # equals the minimal.squashfs line of casper/SHA256SUMS
```

**Not proven until a boot.** `md5sum-txt.sh verify` is a reimplementation of the check (awk, `dd` and `md5sum`), not casper's
binary. It was compared with the real `casper-md5check` (casper 1.498, 24.04; 26.04.1 ships casper 26.04.2, not re-compared) on a synthetic tree only: the two agreed on OK, a
mismatch, a path with a space and an empty file. For a file that is listed but missing casper prints "No such file or
directory" and then "mismatch" and counts one error, which `verify` reports as MISSING. `verify` also reports UNLISTED (a regular
file of the image that the stock convention lists and `md5sum.txt` does not); casper ignores unlisted files, so that is this
script's policy and not a casper failure. Other comparisons show that `verify` reads files correctly (the extent reading
against `casper/SHA256SUMS`, 948 of 948 stock entries of the 26.04.1 ISO against Canonical's own `md5sum.txt`, and, retired baseline
(24.04.5.1), 448 of 448); none is a run of
casper-md5check. What has **not** been done is the in-guest run on an image built
from `d6255cc` or later: `journalctl -u casper-md5check` (or `/run/casper-md5check.json`) saying "no errors found" in a booted
guest. Until that is recorded here, a clean `verify` means the file is right by this script's model, not by casper's.

### Verify the image contents (pre-installed tools and branding)

```bash
backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-1.0-amd64.iso
```

Needs no root and does not boot the ISO. It extracts the root squashfs, the initrd and a few files and
asserts that every CI-Hub and wireless-setup tool is pre-installed, that the hotspot units are guarded
against live sessions, that Docker is unguarded and the docker group is set up, that the optional tools
are installed from their pinned sources, that the Settings > About logo, the dock start icon, the `LOGO=` icon and the greeter logo are the canon mark and diverted from the packages that own the stock files (it reads their pixels and paths and compares them with `vendor/brand`: the About PNGs hold only the mode's primary token colour, the greeter only the three tones of the colour mark, `ci-os-logo.svg` is the vendored `mark.svg` byte for byte, the start icon carries every path of the mark and no artwork colour, its crop lies inside the mark's canvas and, with `rsvg-convert`, keeps the mark's ink (`40-start-icon.sh` crops with a constant cut for the 1.0.0 mark and stops on a mark with another viewBox), and, with `rsvg-convert` or ImageMagick on the verifying machine, the PNG shapes match a fresh render of the mark; run it from the repo checkout, and see `tests/verify-logo-surfaces.sh`), that the casper layers stacked on the base keep the rootfs directory modes
(`/tmp` is `1777`; `tests/placeholder-layer-modes.sh` checks the build step in a privileged container), that the **installer base layer is clean**
(section 3g, [below](#installer-base-layer-section-3g)), that NetworkManager still manages wired devices (no
`/etc/netplan` file sets a global renderer other than NetworkManager; the setup-mode profile sets
`renderer: networkd` on `eth0` only), and that the visible branding is Companion OS while `ID=ubuntu`, `DISTRIB_ID`,
`BUILD_SYSTEM` and the ISO volume id (which apt, casper, the installer and Secure Boot depend on) are
untouched. The product name is the same everywhere a user reads it: the installer's source names in
`install-sources.yaml`, the text-mode splash title (`Companion OS <version>`, the version `os-release` carries),
the Hub launcher entry, and no retired spelling of the name (the list is `OLD_NAMES` in the script) in the
identity, GRUB, MOTD and installer files. It also checks the live GRUB menu: the background is an 8-bit PNG, `grub.cfg` loads it with
`gfxterm` and `insmod`s only `gfxterm` and `png` (each of them built into the signed GRUB on the ISO itself), the menu colours equal what the brand tokens
give (`core/lib/tests/grub-nearest-color.sh` pins the function that derives them), and the installed system's GRUB background is 8-bit too. A copy of the script run outside the repo cannot derive the canon checks; it lists them under SKIPPED in the Summary, and `VERIFY_REQUIRE_CANON=1` makes that a failure. For the live boot it unpacks the appended initrd overlay
(`tests/boot-media-plymouth.sh` runs the build step against a stock-shaped initrd) and asserts that it holds exactly the branded
files and that the bgrt and spinner themes carry the canon ground and progress-bar colours with their stock fonts, that no section of
either asks for the firmware background (which would make the plugin paint black, see [Live boot splash](#live-boot-splash-plymouth)),
that the overlay's and the rootfs' copies agree key by key apart from the fonts, and (with `unmkinitramfs`) that the initrd's default theme is the
bgrt one the overlay repaints, nothing in its `plymouthd.conf` selects another theme (26.04.1's own file has comments only, so only an
active `Theme=` line naming another theme is a defect), the text splash is titled
Companion OS, and `bgrt-fallback.png` is the same non-Ubuntu 128 px canon mark in the overlay and the rootfs. In the rootfs every package-owned Plymouth file the build rewrites (the watermark, `bgrt-fallback.png`, `bgrt.plymouth`, `spinner.plymouth`, and the text theme's template `ubuntu-text.plymouth.in`, from which the package regenerates the text theme) is `dpkg-divert`ed, so a package upgrade or an `/etc/lsb-release` trigger cannot bring Ubuntu's logo or colours back (`desktop-theme/tests/plymouth-theme.sh` shows this against the real packages). The stock copy of a diverted file is at
`<file>.ubuntu-stock`, a regular file for all but one: 26.04.1's `spinner/watermark.png` is a symlink (`-> ../../../pixmaps/ubuntu-logo-text-dark.png`),
and `unsquashfs -ll` ends a link's line in ` -> target`, so the check accepts both.
Section 4d checks the GNOME Shell theme: `theme/Yaru/gnome-shell-theme.gresource`, which the Ubuntu session and (through `/etc/alternatives/gdm-theme.gresource`)
the greeter load, is the branded blob of the checkout, byte for byte, and not Ubuntu's stock Yaru file, and the upstream
`gnome-shell-theme.gresource`, which the built-in session modes load, still lists `gnome-shell-light.css` and `gnome-shell-dark.css`, which the
branded blob lacks (the build once copied the blob over both, and a missing blob is only a warning in `customize-chroot.sh`, so nothing else notices
an unthemed image or one that lost the stylesheets).
<a id="installer-base-layer-section-3g"></a>
Section 3g checks the layer split ([Layers](#layers-what-the-installer-installs-and-what-only-the-live-session-sees)).
The base layer (`minimal.squashfs`, the only layer the installer copies to the disk) must hold none of what the stock ISO keeps in its
live layer: neither package `casper` nor `finalrd` (in no dpkg state), none of casper's files, initramfs configuration, scripts, hook, units
or enable links, no `livecd-rootfs.gschema.override`, nothing of the installer snap `ubuntu-desktop-bootstrap` (files, desktop
entry, AppArmor and seccomp profiles, mount and service units, seed entry, snapd state; its base `core24` is the system's own and stays), nothing of subiquity's live-session files, and none
of the other live-image files in the table of
[`docs/architecture/ubuntu-iso-layers.md`](../../../docs/architecture/ubuntu-iso-layers.md) (masked `getty@tty1`, `udisks2-inhibit`, the
journald drop-ins, the live polkit rule and AppArmor sysctl file, the snapd drop-in, the display-manager wait drop-in, ...) and nothing of the
snapd seed of the TPM-encryption variant (`seed/systems/enhanced-secureboot-desktop`); its snapd seed names only snap files the base holds and
`seed/snaps` holds only files the seed names, its `/etc/cloud/cloud.cfg` is not the live session's (which
creates the user `installer`) and `systemd-networkd-wait-online` is the real binary, not a symlink to `/bin/true`. It also asserts the
initramfs decision (initramfs-tools installed, no dracut, `/etc/apt/preferences.d/ci-os-no-dracut` pins `dracut` and `dracut-core` to -1) and
that the ISO pool's `cdrom.sources` is still in the base layer.
The live layer (`minimal.standard.live.squashfs`) must not be a placeholder: it holds casper's files (including `casper-md5check` and the enable link of
its unit) and the live-session pieces the base had taken out (the installer's user service, the livecd override, the installer snap's seed file;
the 26.04 additions, the polkit rule, the sysctl file and the encryption seed, are deliberately not required there: a customization may delete them from the rootfs altogether), the live session's own `cloud.cfg` and snapd `seed.yaml`, a dpkg status that lists casper, and a `.size` file in the
range its own listing allows (the lower bound leaves out one name of every snap blob: `var/lib/snapd/snaps/X.snap` and `seed/snaps/X.snap` are one hard-linked
inode, and the stock minimal layer lists 9.06 GB for 6.16 GB of `du`); `minimal.standard.squashfs` stays the empty placeholder. The `.manifest` files are the stock "diff" shape and match the
dpkg status files (`minimal.manifest` the base's packages, `minimal.standard.manifest` none, `minimal.standard.live.manifest` the packages the live
layer adds), and the three `.manifest.full` files list the whole stack up to their layer (packages, then `snap:` lines that match the seed). Section 3d
asserts that `install-sources.yaml` is the version 2 mapping with the stock `kernel:` block and a kernel package the base has, and that `/casper` holds
exactly the three layers' twelve files and no stock language or enhanced-secureboot file. The kernel lines of `grub.cfg` and `loopback.cfg` stay the stock ones
(`linux /casper/vmlinuz [nomodeset] [iso-scan/filename=${iso_path}] --- quiet splash`, plus `ci.autoinstall=1` in the one automatic entry; with
`VERIFY_BASE_ISO`, equal to the stock ISO's). Run on the v7 image (which put the whole merged rootfs in `minimal.squashfs`) the section
passes 9 and fails 31 of its 40 checks; on an ISO carrying the real output of the split (made from the v7 build's saved chroot) it passes all 40 (retired baseline (24.04.5): both counts are of the old 40-check section).
Run on the **stock** 26.04.1 ISO as a control, the 18 `BASE_FORBIDDEN` rows pass on its minimal layer (174 601 entries) (no row matches a stock install's base), its live layer
holds every `LIVE_REQUIRED` path, and the checks that tell a dracut-based stock base from this image's initramfs-tools one fail, as they should.
`tests/verify-installer-base.sh` shows every check failing on the defect it is for. Run the section on every built image: a row can be wrong
about a real base layer in a way the stock layers and a small fixture cannot show (the finalrd row once flagged a file of the kept package `mdadm`).
Section 8 checks the image's `md5sum.txt` (see [Disc integrity](#disc-integrity-md5sumtxt-inside-the-image)):
every entry matches the file in the ISO, no entry names a file that is gone, and every regular file the stock convention
lists is listed. It is `verify`'s model of casper-md5check, not a boot of the image, and says so in its output.
Exit status is non-zero if any check fails.

To also prove the Secure Boot chain is intact, name the stock ISO the image was built from; the check then
asserts that `/EFI/boot/bootx64.efi`, `grubx64.efi` and `mmx64.efi` are byte-identical to it and that `casper/initrd`
starts with the stock initrd's exact bytes, then its 4-byte padding, then the overlay, and that the `md5sum.txt` exclusions are
the stock ISO's own, and that the volume id and the `kernel:` block of `install-sources.yaml` are the stock ISO's (without it those checks are skipped and reported):

```bash
VERIFY_BASE_ISO=ubuntu-26.04.1-desktop-amd64.iso backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-1.0-amd64.iso
```

---

## What is pre-installed

| Group | What | Notes |
|---|---|---|
| Wireless setup | `setup-device` package: hostapd, dnsmasq, nginx-light, python3-flask, gunicorn, network-manager, iw, and the portal, backend, hotspot and monitor scripts and units | Enabled for the installed system; guarded off in live sessions |
| CI-Hub runtime | Docker Engine, Compose and Buildx (Docker's apt repo, key pinned by fingerprint), curl, jq, the CI-Hub deploy scripts under `/usr/lib/ci-os/bootstrap/` | The same Docker source as `core/manifest/role-map/apt.yaml`, so first boot skips it |
| Docker everywhere | Docker runs on the installed system, in the plain live ISO and in a Companion Stick live boot; the live user and the installer-created administrator are in the `docker` group | Live sessions get a tmpfs (ISO) or the Stick's `CI-PERSIST` volume as Docker's data root. `docker` membership is root-equivalent; opt out with `touch /etc/ci-os/no-docker-group`. See `docs/architecture/docker-in-live-sessions.md` |
| Optional tools | tailscale, cloudflared, GitHub CLI (vendor apt repos), Ollama (pinned release tarball, runs on the installed system only) the Companion Launcher (pinned `.deb`, `companion-hub`) and Companion Capture (pinned `.deb`, `companion-capture`, from dl.ci.computer/applet; installed but never started: no autostart, no service) | On by default. `CI_OS_BAKE_THIRD_PARTY`, `CI_OS_BAKE_OLLAMA`, `CI_OS_BAKE_LAUNCHER` = 0 turn a group off; `CI_OS_OLLAMA_CUDA=none` saves 1.5 GB. See `docs/architecture/tier-b-tools.md` |
| Left to first boot, on purpose | The CI-Hub container image (needs registry credentials and device pairing), model pulls, per-user developer tools | See `core/manifest/ecosystem.yaml` (`ci_hub`) |

## What stays Ubuntu, and why

These cannot be changed by remastering the image, and `verify-iso.sh` lists them as known:

- **The installer window.** It is Canonical's `ubuntu-desktop-bootstrap` snap. Its flavour list is fixed
  (Ubuntu, Kubuntu, Lubuntu, Xubuntu, Edubuntu), so "Welcome to Ubuntu" is inside the snap. The launcher
  label ("Install Companion OS ...") is ours, via `/.disk/info`. Rebranding the window means shipping a
  modified installer snap.
- **The ISO volume id** (`Ubuntu 26.04.1 LTS amd64`). Casper and the signed EFI GRUB search for it.
- **Most of the installer's own text**: "Welcome to Ubuntu", "Erase disk and install Ubuntu" and the logo are fixed text in the snap. What
  comes from `/.disk/info` is the launcher label ("Install Companion OS") and the last page ("Companion OS 26.04.1 LTS is installed and
  ready to use"); the file spells the product with a blank (step 7 above). Not measured on a booted 26.04.1 installer: the done page
  with the new spelling (the string and the file read are in the snap, the 24.04.5 page is recorded).
- **`ID=ubuntu`, `ID_LIKE`, `UBUNTU_CODENAME`, `DISTRIB_ID=Ubuntu`, `BUILD_SYSTEM=Ubuntu`.** apt, curtin,
  casper and `unattended-upgrades` key off them.

---

## Troubleshooting

### "Source gresource not found"

The build host must be Ubuntu 26.04 with Yaru installed:

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

### The installed system stops at "Unable to find a medium containing a live file system"

Symptom: the live ISO boots and installs, but the first boot of the installed disk prints `/init: line 38: can't open /dev/sr0: No
medium found` over and over and ends with "Attempt interactive netboot from a URL?". Cause: the base layer the installer copied
(`minimal.squashfs`) held the stock live layer's content, among it the `casper` package, whose initramfs hook is in every initrd the
installer regenerates (`BOOT=casper`). Every image built before the layer split has that layout; the v7 image was installed and failed this
way, earlier ones were not installed here. Check: `verify-iso.sh`
section 3g lists what the base layer ships that it must not (casper's files and package, `livecd-rootfs.gschema.override`, the installer
snap's files, ...), and `tests/installed-boot.sh --quick` (per its header: no disk, no boot, about a minute) names `casper` in the base layer. Fix: build with the
layer split (`lib/split-live-layer.sh`) and install again; a disk that is already installed can be repaired from a live session by
purging `casper`, deleting `/etc/initramfs-tools/conf.d/casperize.conf` and `default-layer.conf`, removing
`livecd-rootfs.gschema.override` and recompiling the schemas, then `update-initramfs -u -k all`. That repair was tried once, on a QEMU copy
of the v7 install, and reached the GDM greeter; it is not a supported procedure (the same image also leaves the live image's
`/etc/cloud/cloud.cfg`, which creates a user `installer` with `NOPASSWD:ALL` sudo, and a masked tty1 getty). Details and evidence:
[`docs/architecture/ubuntu-iso-layers.md`](../../../docs/architecture/ubuntu-iso-layers.md), section 2.

### ISO won't boot

- Verify the base ISO SHA256 matches the release checksum
- Try `--clean` to rebuild from scratch
- Test in VM before writing to USB
- Stuck at a `grub>` prompt, or the live menu is plain text without the background: look at what the
  medium really carries. The unthemed original is
  `work/custom-iso/boot/grub/grub.cfg.orig`; diff it against `grub.cfg` (only the titles, two
  `menu_color_*` lines and the `if loadfont unicode` block should differ), and check that
  `/boot/grub/ci-os-bg.png` is on the ISO. Test both UEFI and BIOS (SeaBIOS) boot in QEMU.

---

## CI/CD

The repository includes `.github/workflows/build-companion-os-iso.yml`. It is **manual dispatch only** (inputs `version` and `sign`): the tag
and weekly-schedule triggers are commented out inside the `ci-local:gated` block, and restoring them is a maintainer call. It builds in a
privileged `ubuntu:26.04` container on the runner. See the workflow for the GitHub secrets (`GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`) that signing needs;
its "Create GitHub Release" step is not safe for ISOs (KI-12 in `docs/architecture/known-issues-and-decisions.md`).

---

## Support

- **Issues**: https://github.com/companionintelligence/CI-OS/issues
- **Website**: https://ci.computer

---

© Companion Intelligence — Lifescope Inc
