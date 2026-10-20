# Companion OS on arm64

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**
> State of 2026-10-19. **A supported architecture of the Ubuntu 26.04.1 target since 2026-10-19** (owner decision; the policy is [supported-targets.md](supported-targets.md)). Supported means the five points of its section 2, with the gaps listed [below](#gaps-against-the-five-points); it does not mean proven on real hardware. Evidence tags: **[V]** run and seen, **[I]** implemented, not run, **[N]** not done.

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
| First sign-in | the one-time password was accepted and GDM asked for a new one (the designed `chage -d 0` flow); **no Canonical first-run screen was seen**; Firefox opened the Companion getting-started page by itself. **Correction, same day:** the next image showed that screen (the upgrade-login service, see below), with the same configuration, so "none was seen" on this first image is not proof that it could not appear | 1 min to the desktop |
| First-boot setup | started by its timer 3 min after boot, waited for a quiet machine (`wait-quiet: quiet after 30s`), removed the snap-store and Thunderbird snaps, pulled `nomic-embed-text` and `gemma3:1b`, **started Companion Hub** (`ci-hub`, `ci-hub-db`, `ci-hub-queue` healthy), wrote its marker. The unit showed `Type=exec`, `Nice=19`, idle CPU scheduling; `ollama.service` showed `CPUWeight=20 IOWeight=20` while it ran | 2 min 48 s |
| Hub | `http://localhost:5002` answered 200 and redirected to its device-registration page: the pairing step the docs describe. Nothing needed a credential | |
| Login text | `/etc/legal` says Companion OS; the four Pro motd scripts are held off by `dpkg-statoverride` | |

## The second run: the image of the current branch [V]

The first image (`ee25b63`) predated the trust fix for the desktop shortcuts and the download-progress filter, so the branch was built and run again, twice. **The first rebuild
(`c0059d6`) found a defect the first image had not shown**: the first sign-in opened Canonical's "Welcome to Companion OS 1.0!" page with the raccoon, from
`gnome-initial-setup-upgrade-login.service`, which the stamp in `/etc/skel` did not cover (KI-27). Commit `6aa27f6` fixes it. The image built from that commit
(`4b7597d`) is the one in the screenshots of [`docs/ui/companion-os/ubuntu/CAPTURE.md`](../ui/companion-os/ubuntu/CAPTURE.md).

| Step | `c0059d6` | `4b7597d` (the fix) |
|---|---|---|
| Build | 811 s | 917 s |
| `verify-iso.sh` | 436 passed, 0 failed | **438 passed, 0 failed** (two new checks: the upgrade-login unit names a stamp, and `/etc/skel` holds it) |
| Live desktop | the five shortcuts show their icons and names (the trust fix works) | the same |
| One-click install | 9 min 35 s | 12 min 10 s |
| First sign-in | **Canonical's welcome page (the defect)** | no first-run page; the Companion getting-started page opens |
| First-boot job | 1 min 58 s, exit 0 | 1 min 58 s, exit 0 |
| Hub | `ci-hub`, `ci-hub-db`, `ci-hub-queue`, `traefik` up; the Hub window shows the pairing screen | the same |
| Failed units | `pd-mapper.service` | the same |

The same fix was also proved live on the `c0059d6` machine before the rebuild: with the stamp placed in the home, the second sign-in went straight to a clean desktop
(`docs/evidence/2026-10-19-ubuntu-arm64-c0059d6-first-run/frames/02-...png`). The amd64 image of `4b7597d` was built (1113 s) and verified (**446 passed, 0 failed**,
`docs/evidence/2026-10-19-ubuntu-amd64-4b7597d/`); its live session was booted under emulation (no desktop icons, see KI-27), it was not installed [I].

## The third run: the quiet first sign-in [V]

Commit `ee4a3b4` (items 3 and 4 of the home-lab polish proposal in CI-Engineering) was built and installed fresh, the same steps as above: **build 747 s, `verify-iso.sh` 442 passed and 0 failed** (the four new checks are the Firefox policy, the notifier default and two on `ci-os-info`), **install 9 min 22 s**, then a first sign-in with **one browser tab and no notification** over 70 s of frames while 78 packages were waiting, a first-boot job that finished with a clean setup log, and `ci-os-info` showing the setup, Hub's address, the models and the disk. The first boot of the ISO that day froze once on a text boot log with the guest idle (the host load average was 14); a restart booted normally, and the cause was not found. Records: `docs/evidence/2026-10-19-ubuntu-arm64-ee4a3b4/`. One failed service (`pd-mapper.service`) now shows in `ci-os-info` as "1 failed service(s)"; it is the open item 7 of the proposal.

## The fourth run: language, keyboard and time zone, and the first-boot notifications [V]

Commit `b124745` (items 1 and 2 of the same proposal): **build 879 s, `verify-iso.sh` 446 passed and 0 failed**, a fresh install with German (Germany), the German keyboard and Berlin chosen in the one-click dialog (**11 min 23 s at most**, the poll is 15 s), then a German greeter and desktop, `LANG=de_DE.UTF-8`, X11 layout `de`, `/etc/timezone` `Europe/Berlin`, and a first boot of **2 min 28 s** whose five notifications reached GNOME. The run found that `notify-send -A` sends no action on this image, so the ready message's "Open Companion Hub" button never existed; commit `c8de040` removed it (KI-29). Records: [`../evidence/2026-10-19-ubuntu-arm64-b124745/`](../evidence/2026-10-19-ubuntu-arm64-b124745/), frames 12 to 19b of [`../ui/companion-os/ubuntu/`](../ui/companion-os/ubuntu/CAPTURE.md). The image with that fix (commit `82e9335`, code of `c8de040`) was built in 869 s and verified (446 passed, 0 failed) and then installed fresh, see the next section.

## The fifth run: the fix image, recorded from power-on [V]

Commit `82e9335` (sha256 `e43e2066...e86ac`) installed fresh with German (Germany), the German keyboard and Berlin chosen in the dialog: **install at most 11 min 38 s**, a German greeter and desktop, the same `LANG`, X11 layout and `/etc/timezone` as before, and a first boot of **2 min 11 s** whose banners were recorded: "waiting for the internet" (the network was not up yet), "getting the computer ready", step 1, step 5, step 7 and **"Companion OS is ready" with the final wording** ("the first icon in the dock"). The sha256 of the installed `setup-progress`, `setup-status.sh` and autostart entry equal the repository's. Records: [`../evidence/2026-10-19-ubuntu-arm64-82e9335/`](../evidence/2026-10-19-ubuntu-arm64-82e9335/), frames 20 to 23. The run was recorded from power-on and cut into a 52 second video ([testing-in-qemu.md](../guides/testing-in-qemu.md#recording-a-first-run-video)).

**Seen for the first time:** five minutes after the last input the screen **blanks and the session locks** ("Durch Mausklick oder Tastendruck entsperren"). The first boot takes about two minutes, so a person who leaves a new machine to set itself up will come back to a lock screen; the notifications wait in the list after the unlock (frame 23). Not changed here; the default is Ubuntu's.

## The sixth run: the same image at 1920 x 1080, English (United Kingdom), for the film [V]

The image of `82e9335` (sha256 `e43e2066...e86ac`, nothing rebuilt) installed fresh again, this time with the virtual display at **1920 x 1080** (`CI_VM_RES=1920x1080`) and **English (United Kingdom)**, keyboard English (UK) and London chosen in the dialog, to make the frames of the stick's film ([`video/README.md`](../../video/README.md)). **Install 16 min 33 s on a loaded host** (the German run took at most 11 min 38 s on a quiet one: nothing here says how long an install takes). The greeter showed the English date and London time, the first sign-in forced the password change as before, and the first boot showed the same notices (waiting, getting ready, step 1, step 5 "Downloading the AI models (the longest step)", step 7, "Companion OS is ready") over **2 min 15 s**; Companion Hub opened from the first dock icon at its pairing page about 12 s after the click. **Seen again:** the installed system showed the root filesystem check message and then nothing for a minute on its first start (the second time this was seen); a restart reached the greeter (KI-28, cause unknown). Records: [`../evidence/2026-10-19-ubuntu-arm64-82e9335-video-run/`](../evidence/2026-10-19-ubuntu-arm64-82e9335-video-run/). The film: 86 seconds, landscape and square, from 15 plates of 1,009 recorded frames, the one-time password covered by a bar that a test checks.

## The fifth change: streamlined setup (2026-10-19) [V]

Built and installed twice on arm64 in a virtual machine, with the same harness as the runs above: the first five commits of the change (`cf68024`: **build 759 s, `verify-iso.sh` 492 passed and 0 failed**, **install 10 min 19 s at most**) and, after the fix described below, `5ff5224` (**build 779 s, 493 passed and 0 failed**, **install 11 min 12 s at most**; both installs apply updates from the network, so the time depends on it). The change removes Ubuntu Pro prompts and Canonical's background callers, stops the live session opening Canonical's installer wizard by itself, and sets a dark scheme with a green accent ([KI-30](known-issues-and-decisions.md#ki-30-streamlined-setup-no-ubuntu-pro-prompts-no-canonical-telemetry-no-canonical-wizard-in-the-live-session-dark-and-green-by-default); [one-click-install.md](one-click-install.md); `backends/ubuntu/lib/quiet-canonical.sh`, `appearance.sh`, `customize-chroot.sh` Steps 2c, 3 and 7b). What the boots showed, with the records (`docs/evidence/2026-10-19-ubuntu-arm64-streamline/`) and the frames (`docs/ui/companion-os/ubuntu-streamline/`): from the automatic boot entry the one-click dialog is the only window, dark, and Canonical's installer stays reachable; the installed system has `prefer-dark` and `green`, the Pro apt hook diverted, the Pro and `motd-news` timers masked, `ubuntu-insights` removed, no first-run page and no Software Updater banner. **The first boot also found a defect**: with Canonical's installer unit not started, nothing took the live session out of the live layer's "installer mode", so it had no dock and no desktop icons; `5ff5224` does what the unit does when its window closes, and the rebuilt image shows the dock and the icons. The amd64 image of the same code was built (`8fea315`, 892 s) and passed `verify-iso.sh` (**501 passed, 0 failed**, the real stock amd64 installer unit compared with the helper included; `docs/evidence/2026-10-19-ubuntu-amd64-streamline-8fea315/`) but was not booted **[N]**; nothing in the change is x86-64 only, and the amd64 base has the same user service, `gnome-initial-setup` units and Pro client.

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
* **The amd64 image from the same branch**: rebuilt from `331df4d` and verified, **444 passed, 0 failed** (`../evidence/2026-10-19-ubuntu-amd64-331df4d/`) [V]. Its live session was booted under emulation on 2026-10-19: greeter in about 11 minutes, dock correct with Companion Capture, **but no desktop icons** (the desktop-icons process was relaunched every 3 s; see KI-27), so amd64 shortcut rendering is still [I]. It was not installed.

## Gaps against the five points

The five points of [supported-targets.md, section 2](supported-targets.md#2-what-supported-means), for the arm64 image:

| Point | State |
|---|---|
| 1. It builds | **[V]** a documented command (above); built three times natively (1161 s, 811 s, 917 s). |
| 2. Verified without booting | **[V]** `verify-iso.sh` reads the architecture from the volume id and passed 436 checks on the arm64 image. **Gap [N]:** the arm64 branches of the verifier (EFI names, the no-GRUB case, the `$cmdline` menu line, Capture expected absent) have no good-and-broken fixture self-test; they were exercised only by the real image. |
| 3. Fast tests in the gate | **[V]** the architecture handling of `customize-chroot.sh` is pinned by `customize-chroot-checks.sh` (section 11, mutation-tested), and the new first-boot and welcome scripts have their own suites. **Gap [N]:** no job builds an arm64 image; the build is run by hand. |
| 4. Limits written | **[V]** this page and KI-28. |
| 5. Maintenance | A defect in the arm64 image is fixed here. **Gap:** with no CI job for arm64, a change that breaks only the arm64 build is found by the next hand build, so rebuild it before a release. |
