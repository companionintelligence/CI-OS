# Companion OS on arm64

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**
> State of 2026-10-19. **An experimental build option, not a supported target** (the policy is [supported-targets.md](supported-targets.md); section 8 there says what a promotion needs). Evidence tags: **[V]** run and seen, **[I]** implemented, not run, **[N]** not done.

`build-iso.sh --arch arm64` remasters Canonical's **Ubuntu 26.04.1 desktop arm64** ISO the way the amd64 build remasters the amd64 one. The result is the same product on an arm64 machine: the Companion dock, links and welcome page, the one-click installer, the first-boot setup, Companion Hub started headless, and Ollama with the small models. One piece is missing: **Companion Capture publishes no Linux arm64 build**, so an arm64 image does not bake it.

## What was run [V]

One image, built from the commit `ee25b63` of the branch `liam/companion-os-arm64` (later commits only changed the verifier and the welcome script), on an Apple-silicon Mac, **natively**: an arm64 container, an arm64 chroot, no emulation. The guest ran under QEMU with `-accel hvf` and Homebrew's `edk2-aarch64-code.fd` (no Secure Boot firmware). Records: [`../evidence/2026-10-19-ubuntu-arm64/`](../evidence/2026-10-19-ubuntu-arm64/).

| Step | Result | Time |
|---|---|---|
| Base ISO | `ubuntu-26.04.1-desktop-arm64.iso`, 4,154,798,080 bytes, sha256 `c54d1964...2517`, equal to the signed `SHA256SUMS` (key `843938DF...2092`, GOODSIG) | download 15 min (8 parallel ranges; one stream was 0.5 MB/s) |
| Build | `companion-os-1.0-arm64.iso`, 5,593,038,848 bytes; its `md5sum.txt` matches (359 of 359 files) | **19 min** (the amd64 build under Rosetta: 22 min) |
| `verify-iso.sh` | **436 passed, 0 failed** (after the verifier learned the differences below) | 1.5 min |
| Live boot to the desktop | the Companion wallpaper, the installer window, the dock with the new list (installer, Hub, Docs, Files, Terminal; no Capture) | **about 2 min** (x86 under emulation: 6 to 15 min) |
| One-click install | the confirmation dialog, then the install; the machine powered itself off | **12 min** (x86 under emulation: about 6 hours) |
| Installed boot | branded GDM greeter; `graphical.target` after **18.5 s** of userspace | 45 s from power-on |
| First sign-in | the one-time password was accepted and GDM asked for a new one (the designed `chage -d 0` flow); **no Canonical first-run screen**; Firefox opened the Companion getting-started page by itself | 1 min to the desktop |
| First-boot setup | started by its timer 3 min after boot, waited for a quiet machine (`wait-quiet: quiet after 30s`), removed the snap-store and Thunderbird snaps, pulled `nomic-embed-text` and `gemma3:1b`, **started Companion Hub** (`ci-hub`, `ci-hub-db`, `ci-hub-queue` healthy), wrote its marker. The unit showed `Type=exec`, `Nice=19`, idle CPU scheduling; `ollama.service` showed `CPUWeight=20 IOWeight=20` while it ran | 2 min 48 s |
| Hub | `http://localhost:5002` answered 200 and redirected to its device-registration page: the pairing step the docs describe. Nothing needed a credential | |
| Login text | `/etc/legal` says Companion OS; the four Pro motd scripts are held off by `dpkg-statoverride` | |

## How it differs from amd64

| Difference | Why | What the build does |
|---|---|---|
| No GRUB in the base image | the arm64 layers have no grub package; the installer installs `grub-efi-arm64-signed` from the ISO's pool | Step 4 skips `/etc/default/grub` on arm64 (an amd64 build still fails if it is missing). The installed GRUB takes its name from `os-release`, so it says Companion OS; its background is stock |
| No `loopback.cfg`, no BIOS image | arm64 is GPT with an appended ESP only | `verify-iso.sh` notes it; `md5sum-txt.sh` also leaves out `/boot/boot.cat` |
| Stock menu line `linux /casper/vmlinuz $cmdline --- quiet splash console=tty0` | Canonical's Snapdragon quirk variable and `console=tty0` | the verifier accepts exactly that shape; the boot shows the kernel's messages instead of the splash |
| EFI files `bootaa64`, `grubaa64`, `mmaa64` | arm64 names | `verify-iso.sh` reads the architecture from the volume id (or `VERIFY_ARCH`) |
| Companion Capture is absent | no Linux arm64 build exists (`CAPTURE_*_ARM64` pins are empty) | not baked; an explicit `CI_OS_BAKE_CAPTURE=1` stops the build; the dock entry is hidden by GNOME |
| Ollama has no Vulkan runner | the arm64 tarball has CPU, CUDA and Jetson runners; ROCm is x86-64 only | the verifier does not expect it; the `ci-os-install-rocm` command and `amd64-microcode` are amd64-only |
| `setup-device` package | it was `Architecture: amd64` although it holds shell, Python and config | now `all` |
| `pd-mapper.service` fails | Canonical's arm64 image ships the Qualcomm PD mapper; on any other arm64 machine it fails and the system reads `degraded` | not changed (see KI-28) |

## Build it

```bash
# on an Apple-silicon Mac or an arm64 Linux host (an arm64 container: docs/guides/building-on-a-mac.md)
curl -fLO https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso
echo 'c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517  ubuntu-26.04.1-desktop-arm64.iso' | shasum -a 256 -c -
./backends/ubuntu/iso/scripts/build-iso.sh --arch arm64 --base-iso ./ubuntu-26.04.1-desktop-arm64.iso --output-dir out --work-dir work --version 1.0 --clean
VERIFY_BASE_ISO=./ubuntu-26.04.1-desktop-arm64.iso ./backends/ubuntu/iso/scripts/verify-iso.sh out/companion-os-1.0-arm64.iso
```

The base ISO is on `cdimage.ubuntu.com`, not `releases.ubuntu.com`. `build-iso.sh` refuses a base ISO whose volume id does not end with the architecture. Pins for an arm64 image carry the suffix `_ARM64` in `core/manifest/tier-b-pins.env`.

To boot it on an Apple-silicon Mac at near-native speed: `qemu-system-aarch64 -machine virt,gic-version=3 -accel hvf -cpu host -smp 6 -m 8192`, `edk2-aarch64-code.fd` plus a copy of `edk2-arm-vars.fd` as pflash, `virtio-gpu-pci`, `qemu-xhci` with `usb-kbd` and `usb-tablet`, the ISO as a `usb-storage` drive with `bootindex=0`, a blank NVMe disk for the install.

## Not proven

* **Secure Boot on arm64** [N]: Homebrew ships no aarch64 Secure Boot firmware (Ubuntu's `qemu-efi-aarch64` has `AAVMF_CODE.ms.fd`); the arm64 checks of the signed boot chain compare files with the base ISO's, they do not boot under Secure Boot.
* **Real hardware** [N]: Snapdragon X, Ampere, Raspberry Pi 5 or a Mac under another hypervisor. Nothing here ran on any of them (KI-17 applies to arm64 too).
* **Companion Stick** [N]: `ci-stick` and its boot chain are x86-64 (`stick/crates/ci-stick/src/host.rs` says arm64 boot images are not built). An arm64 ISO can be written to a USB stick by other means; `ci-stick flash` will not take it.
* **GitHub Actions** [N]: no workflow builds arm64; the existing one is x86-64 and gated to manual dispatch.
* **The amd64 image from the same branch** has to be rebuilt and verified (the commands above with `--arch amd64` or none) before this is merged into an amd64 release.
