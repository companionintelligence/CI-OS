# Companion OS, Plasma edition (ISO #6): screenshot capture record

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

**Evidence label for every frame: Tested in a virtual machine.** Each frame is a screen capture of a QEMU TCG virtual machine on an Apple-silicon Mac, with software emulation, UEFI firmware (OVMF) with Secure Boot off, and a file-backed 64 GiB virtual NVMe disk. **No frame comes from real hardware.** Some frames show the virtual hardware on purpose (About this System, the terminals).

This directory holds the 29 frames (26 distinct pictures, see "Same picture under two names") selected from the 51-frame capture of the run, `MANIFEST.json` (the fields of each frame) and this record. The text records of the run (build record, verifier log, job timeline, command lines) are in [`docs/evidence/2026-10-18-plasma-iso6/`](../../../evidence/2026-10-18-plasma-iso6/). What the run proves, tag by tag, is on the [test evidence page](../../../architecture/test-evidence.md#plasma-edition-iso-6-the-whole-path-on-the-first-attempt).

Run of 2026-10-18. Clock: the host clock is Pacific Daylight Time (PDT), and the "Taken" column uses it. The live session's own clock is UTC (a frame of the live desktop reads 19:2x for 12:2x PDT). The installer was left on the preselected time zone, New York, so frames of the installed system read PDT plus 3 hours.

## Inputs

| Item | Value |
|---|---|
| ISO | `companion-os-plasma-2026.10.18-x86_64.iso`, 3,217,129,472 bytes |
| sha256 | `5ab1fe2c422fb8960a0dfd0c2f12f70460d13fb3eb9e13febab5ef2a41802d20` (re-hashed before the run; the same as the `.sha256` file and `ISO_SHA256` of the build record) |
| Built from | CI-OS commit `ad37b64291bb46450195b122329d7e66155b495e`, `REPO_TREE=clean` (0 changed, 0 untracked, 0 ignored); upstream pin `3215497d2e8c5fea90e185affcf973dfa2cf790b`; 202 listed packages; 3 compatibility libraries (`boost-libs-1.91.0-2`); `COMPAT_REVIEW_OVERDUE=0`; `PATCH_COUNT=2` |
| Build record | [`docs/evidence/2026-10-18-plasma-iso6/companion-os-plasma-2026.10.18-x86_64.build-info`](../../../evidence/2026-10-18-plasma-iso6/companion-os-plasma-2026.10.18-x86_64.build-info) |
| Host | Apple-silicon Mac, Homebrew `qemu-system-x86_64` 11.1.2, TCG only (no KVM, no HVF for x86-64). Host load average 9 to 37 during the run: another agent's QEMU was using about 390 percent of a CPU the whole time and was not touched |
| Free disk | 214 GiB at the start of the install, 180 GiB at the end of the run (the rule was to stop below 64 GiB) |

## ISO verifier

`backends/cachyos/iso/scripts/verify-iso.sh`, run as the Plasma README prescribes: in the builder image `ci-os-cachyos-builder:74d94e89adef` (an amd64 container on an arm64 Docker, 4 CPUs, 8 GB), the worktree mounted **read-only** as `/repo`, the ISO directory read-only as `/iso`, `VERIFY_FETCH_UPSTREAM=1` so that the kernel and initrd parity checks against the pinned upstream run. The worktree head was `8412662`, and `git diff --stat ad37b64 8412662 -- backends/cachyos` is empty, so the verifier and overlay it read are the ones the ISO was built from.

| | |
|---|---|
| Result | **`== Summary: 215 passed, 0 failed`** (12:18:09 to 12:19:33 PDT, about 84 s) |
| Counts | 215 `PASS`, 0 `FAIL`, 15 `info` lines (the disclosed residual CachyOS and Arch strings: kernel names, the `[cachyos]` repository, package and unit names, Arch strings in `/usr/lib/os-release`, `DISTRIB_ID=cachyos`, Firefox's own `distribution.ini`), no skipped group |
| Log | [`verify.log`](../../../evidence/2026-10-18-plasma-iso6/verify.log) (255 lines) |

The groups that matter for the fixes of this round all passed: medium name, label and publisher (section 1), Companion titles in every menu and kernel and initrd parity with the pin (2), the Calamares overlay with the explicit time limit on every `shellprocess` command, no CachyOS label on the install page and the installed GRUB menu switches (5), the build record and the compatibility libraries (7), and the `.sha256` and `airootfs.sha512` (8).

## Firmware and virtual machine

`OVMF_CODE_4M.fd` (no Secure Boot) with a per-VM copy of `OVMF_VARS_4M.fd`, both from Ubuntu 24.04 `ovmf` 2024.02-2ubuntu0.10. The edition's GRUB and kernels are not signed for Secure Boot (risk R4 of the [CachyOS backend page](../../../architecture/cachyos-backend.md)), so the Secure Boot variant was **not tried**: a refusal is expected, not observed. The boot is real UEFI GRUB from the ISO, not direct-kernel mode. The live medium has no boot splash.

Live session and install (the copy in [`qemu-cmdline-live-and-install.txt`](../../../evidence/2026-10-18-plasma-iso6/qemu-cmdline-live-and-install.txt); `$PLASMA` is the capture directory (`<scratch>/shots/plasma-v6`), `$FW` the OVMF directory of the repository checkout (`stick/tests/secureboot/out/firmware`), `$ISODIR` the directory of the ISO (`<scratch>/cachyos/iso-out-v6`), `$SOCKDIR` a short temporary directory for the QMP and guest-agent sockets (macOS limits a unix socket path to 104 bytes)):

```
nice -n 5 caffeinate -i qemu-system-x86_64 -name ci-plasma-v6 -pidfile $PLASMA/vm/qemu.pid \
  -machine q35 -accel tcg,thread=multi -cpu max -smp 4 -m 6144 -rtc base=utc \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=$FW/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file=$PLASMA/vm/OVMF_VARS_v6.fd \
  -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 \
  -drive if=none,id=cd,file=$ISODIR/companion-os-plasma-2026.10.18-x86_64.iso,media=cdrom,readonly=on,format=raw -device ide-cd,drive=cd,bootindex=0 \
  -drive if=none,id=target,format=qcow2,file=$PLASMA/vm/target.qcow2 -device nvme,drive=target,serial=ci-target,bootindex=1 \
  -nic user,model=virtio-net-pci -vga std -display none \
  -device virtio-serial-pci,id=vser0 -chardev socket,id=qga0,path=$SOCKDIR/qga.sock,server=on,wait=off \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0,bus=vser0.0 \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  -qmp unix:$SOCKDIR/qmp.sock,server=on,wait=off -serial file:$PLASMA/vm/logs/serial.log
```

Installed boot (the copy in [`qemu-cmdline-installed.txt`](../../../evidence/2026-10-18-plasma-iso6/qemu-cmdline-installed.txt)): the same machine without the CD-ROM, on a qcow2 overlay whose backing file is the pristine post-install disk, with a copy of the NVRAM that holds the installer's `companion-os` boot entry, user-mode NAT because the first-boot provisioning needs the internet.

Settings in words: 4 vCPUs, 6144 MiB RAM, a **64 GiB qcow2 on a virtual NVMe** (`qemu-img create -f qcow2 target.qcow2 64G`, 196 KB on disk at the start), a user-mode NAT NIC (the guest reaches the internet through the host), no host mounts, no host block devices, no `-no-reboot`. The installer's "Restart now" box was left unticked, because a restart would have gone back into the ISO; the VM was powered off through the guest agent instead. The serial log stays empty because the kernel line has no `console=ttyS0`.

## Method

- **Frames** are QEMU monitor (QMP) `screendump` PNG files. The GRUB frame of the live medium is 800x600, the firmware's own graphics mode while GRUB runs; the installed GRUB menu and the splash are 1280x800; the desktop frames are 1280x800 before the trim below.
- **GRUB** shows its menu for a few seconds and then boots itself. A watcher polled every 0.4 s and, once the navy theme was on screen, pressed `Up` (any key cancels the countdown). A second frame five seconds later was byte-identical, so the countdown really was stopped. `Enter` on the first entry followed.
- **Waiting.** Before every frame that followed a state change the harness waited until three consecutive polls changed less than 1 percent of the screen. Opening a launcher result or System Settings took 50 to 100 s under load.
- **Typing and clicking** were injected through QMP (an absolute pointer and key events). Every typed line was correct first time on the frames in this set; one retake is described under the harness notes below.
- **The installer was started as a user would**, on a fresh boot: launcher search, `Enter` on "Install Companion OS". No keyring step by hand, no `CI_OS_SKIP_KEYRING`, no package installed by hand, no symlink, no configuration edit. The guest agent was used read-only (`command -v`, `ls`, `systemctl`, `pacman -Q`, `systemd-analyze`, reading logs) and never started or changed anything.
- **Pixels.** The capture parks the pointer at a screen edge, and in most desktop frames a 14-row, 2-column sliver of it stayed visible at the right edge. Where columns -1 and -2 differed from column -3 over one short run of rows (3 to 20) and columns -3 and -4 were clean, those two columns were cropped, which turns 1280x800 into **1278x800** for 26 of the 29 files. This is a crop, not a resize. There was no colour change, no retouching and no blurring. The PNG files are lossless (the decoded pixels equal the source pixels) with no metadata chunks.
- **Credentials.** The Users page and the sign-in were driven with a throwaway account made for the run (full name `Companion Demo`, login `companion-demo`, host name `companion`). Its password was generated at random for the run and typed by the harness from a file outside this repository; the reveal control was never used, frame 13 shows masked dots, and frame 21 was taken before anything was typed. **No password appears in any file of this directory or of the evidence directory.**

### Hygiene check of this set

1. The exporter OCR'd every PNG (3 times enlarged, plain and inverted, six thresholds, two page-segmentation modes) and searched the pooled text and the raw bytes for the host path prefixes, the host and user names, the Mac user's name, the company name, other agents' VM names, host tool and platform names, IPv4 and MAC addresses, e-mail addresses, any run of 24 or more hex digits, and the throwaway password (whole, and every 8-character piece, with and without case). One OCR false positive was found and checked by eye: on the Users page Tesseract reads the masked password dots as letters.
2. When the files were imported into this repository the check was repeated: the raw bytes of all 29 files were searched for the password and its pieces and for host path, user and host-name literals (0 hits), every distinct picture was OCR'd again (26 pictures, plain and inverted, two modes) and searched for the same literals, hex runs of 24 or more digits, IP addresses, MAC addresses and e-mail addresses (0 hits), and the pictures were looked at.
3. Frames that carry two 32-digit systemd identifiers (the first-boot unit status, Machine ID and Boot ID) were **not** exported, because the CI-Docs privacy net refuses such strings and retouching is not allowed.

## Timings

Host load 9 to 37 with another agent's VM running; read every figure as "under emulation on a busy Mac".

| Phase | Duration | Notes |
|---|---|---|
| ISO verifier | about 84 s | 215 passed, 0 failed |
| Live: power-on to GRUB menu | 2.6 s | UEFI GRUB, countdown stopped with a key |
| Live: Enter on GRUB to the first graphical frame | 5 min 08 s | no boot splash on the live medium |
| Live: Enter on GRUB to the settled desktop | 6 min 38 s | `systemd-analyze`: 15.5 s kernel + 3 min 21.5 s userspace |
| Live: Enter on the installer entry to the Calamares window | about 2 min 40 s | keyring check, database sync, guards, overlay, package preflight (194 packages found), 7 of 7 requirements (all in [`launcher-excerpt.txt`](../../../evidence/2026-10-18-plasma-iso6/launcher-excerpt.txt)) |
| Calamares: Install Now to the end of the queue | **28 min 26 s** | first attempt, 47 jobs, `create-pacman-keyring` 32 s (job 13 as a whole 78 s) |
| Installed: power-on to GRUB menu | 1.2 s | 5 s countdown, clean menu |
| Installed: Enter on GRUB to the greeter (first graphical frame) | **1 min 32 s** | Plymouth splash from about 16 s |
| Installed: `systemd-analyze` | 3.246 s kernel + 4.199 s initrd + 43.901 s userspace = 51.348 s | `graphical.target` after 43.896 s of userspace, with provisioning running beside it |
| Installed: login to the drawn desktop | about 70 s | settled about 85 s after the login |
| Installed: first-boot provisioning, whole run with the downloads | **21 min 18.9 s** | 2 min 57 s CPU, 618.7 MB peak; exit 0; Ollama pulls at 15 to 35 MB/s; `qwen3.6:27b` is the 17 GB model |
| Installed: clean shutdown | about 13 s | `systemctl poweroff` to QEMU exit |

Install timeline (the whole table of 47 jobs is in [`calamares-jobs.txt`](../../../evidence/2026-10-18-plasma-iso6/calamares-jobs.txt); times are guest clock, New York):

| Jobs | What | Duration |
|---|---|---|
| 1 to 12 | partition the disk, mount | 25 s |
| 13 | initialize pacman: rank mirrors, `create-pacman-keyring`, copy the keyring to the target | 78 s (the keyring command 32 s, of which the Arch key import 25 s) |
| 15 | `pacstrap` | 553 s |
| 26 | `chwd` (the drivers job) | 152 s |
| 27 | `packages` | 717 s |
| 35 | `mkinitcpio` | 120 s |
| 40 | `bootloader` | 13 s |
| 1 to 47 | the whole queue | 15:47:02 to 16:15:30 = 28 min 26 s from Install Now |

## Frames

`MANIFEST.json` carries the full text of each row (alt text, caption, shows, notes) and the placeholder that asked for the frame.

| # | File | Stage | What it shows | Taken (PDT) |
|---|---|---|---|---|
| 01 | [`01-live-grub-boot-menu.png`](01-live-grub-boot-menu.png) | live | UEFI GRUB menu of the live ISO: Companion OS (Plasma) selected, then the LTS kernel, safe graphics, UEFI Shell, UEFI Firmware Settings and System shutdown entries. | 12:19:57 |
| 02 | [`02-live-desktop.png`](02-live-desktop.png) | live | Fully loaded live Plasma desktop: Companion wallpaper, floating teal panel with the launcher, System Settings, Dolphin and Firefox icons, tray and clock; no windows. | 12:26:51 |
| 03 | [`03-live-app-launcher-install-entry.png`](03-live-app-launcher-install-entry.png) | live | Launcher scrolled to the I section: Info Center and the highlighted entry Install Companion OS, Install Companion OS on this computer; user liveuser. | 12:28:09 |
| 04 | [`04-live-about.png`](04-live-about.png) | live | System Settings, About this System on the live medium: Companion OS 1.0, Plasma (based on CachyOS), https://ci.computer, Plasma 6.8.0, Frameworks 6.31.0, Qt 6.12.0, kernel 7.2.7-1-cachyos, Wayland, QEMU TCG CPU. | 12:29:40 |
| 05 | [`05-live-terminal.png`](05-live-terminal.png) | live | Konsole maximised on the live medium: cat /etc/os-release (Companion OS 1.0, Plasma based on CachyOS, IMAGE_ID companion-os-plasma), docker and ollama command not found, /usr/local/bin and /usr/share/ci-os listings, uname -r. | 12:31:39 |
| 06 | [`06-live-install-menu-entry.png`](06-live-install-menu-entry.png) | live | Launcher search for 'install companion': Applications, Install Companion OS (System Installer) highlighted, and the generic Run-command fallback below it. | 12:32:14 |
| 07 | [`07-live-calamares-welcome.png`](07-live-calamares-welcome.png) | live | Calamares Welcome page 'Welcome to the Companion OS 1.0 installer': sidebar Welcome to Install, language American English, Companion OS Support link, Back, Next and Cancel. | 12:36:12 |
| 08 | [`08-install-location.png`](08-install-location.png) | install | Calamares Location page: world map with a New York marker, Region America, Zone New York, system language and number and date locale lines with Change buttons. | 12:40:43 |
| 09 | [`09-install-keyboard.png`](09-install-keyboard.png) | install | Calamares Keyboard page: keyboard picture, model Generic 105-key PC, layout English (US) and variant Default highlighted, a test field and Switch Keyboard. | 12:41:44 |
| 10 | [`10-install-bootloader.png`](10-install-bootloader.png) | install | Calamares Bootloader page: GRUB selected as the only entry, Companion mark, description of GRUB. | 12:42:14 |
| 11 | [`11-install-partition-erase-disk.png`](11-install-partition-erase-disk.png) | install | Calamares Partitions page after choosing Erase disk: drive QEMU NVMe Ctrl 64.00 GiB, filesystem btrfs, no encryption, After bar with a 512 MiB FAT32 EFI system partition and a 63.50 GiB Btrfs Companion OS partition. | 12:43:13 |
| 12 | [`12-install-packages.png`](12-install-packages.png) | install | Calamares Packages page: Firefox and language package ticked; Chromium, NVIDIA GPU acceleration, AMD ROCm acceleration, Printing support and Accessibility tools unticked. | 12:44:33 |
| 13 | [`13-install-users.png`](13-install-users.png) | install | Calamares Users page: Companion Demo, companion-demo, host name companion, two masked password fields, all four green checks, administrator-password box ticked. | 12:46:00 |
| 14 | [`14-install-summary.png`](14-install-summary.png) | install | Calamares Summary page: time zone America/New_York, language and locale, keyboard, Erase disk /dev/nvme0n1 (QEMU NVMe Ctrl) and install Companion OS 1.0, Current and After bars, operation list, Install button. | 12:46:30 |
| 15 | [`15-install-confirm.png`](15-install-confirm.png) | install | Dialog Continue with Installation? over the summary: the installer is about to make changes to your disk, you will not be able to undo these changes, buttons Install Now and Go Back. | 12:46:50 |
| 16 | [`16-install-progress.png`](16-install-progress.png) | install | Calamares Install page: teal progress bar at 61 percent on the dark slideshow panel, slide The AI That You Own, status Creating initramfs with mkinitcpio. | 13:12:58 |
| 17 | [`17-install-progress-late.png`](17-install-progress-late.png) | install | Calamares Install page: progress bar at 85 percent, logo slide Companion OS, The appliance operating system, status Running shell processes. | 13:15:17 |
| 18 | [`18-install-finished.png`](18-install-finished.png) | install | Calamares Finish page: All done, Companion OS 1.0 has been installed, Restart now unticked, Done. | 13:20:31 |
| 19 | [`19-installed-grub-boot-menu.png`](19-installed-grub-boot-menu.png) | installed | Installed GRUB menu with the Companion theme at 1280x800: Companion OS Linux (selected), Advanced options for Companion OS Linux, UEFI Firmware Settings, Companion OS snapshots. | 13:28:55 |
| 20 | [`20-installed-boot-splash.png`](20-installed-boot-splash.png) | installed | Plymouth splash of the installed system: spinner, Companion Intelligence mark and wordmark on navy. | 13:29:52 |
| 21 | [`21-installed-login-screen.png`](21-installed-login-screen.png) | installed | Plasma Login Manager greeter after a key press: clock, user Companion Demo, empty Password field, Sleep, Restart, Shut Down and Other buttons, Companion wallpaper. | 13:31:57 |
| 22 | [`22-first-boot-login.png`](22-first-boot-login.png) | installed | Plasma Login Manager greeter of the installed system, one account, empty Password field. Same picture as 21. | 13:31:57 |
| 23 | [`23-installed-first-desktop.png`](23-installed-first-desktop.png) | installed | First desktop after login, settled: Companion wallpaper, bottom panel with the launcher, System Settings, Dolphin and Firefox icons, tray and clock; no windows, no update notifier, no first-run window. | 13:34:43 |
| 24 | [`24-first-boot-desktop.png`](24-first-boot-desktop.png) | installed | Plasma desktop of the installed system right after the first sign-in: Companion wallpaper, panel, nothing else open. Same picture as 23. | 13:34:43 |
| 25 | [`25-installed-app-launcher-hub.png`](25-installed-app-launcher-hub.png) | installed | Launcher, All Applications (A to E): Ark, btop++, Btrfs Assistant, Companion Hub (browser), Dolphin, Emoji Selector; user Companion Demo. | 13:35:27 |
| 26 | [`26-installed-about-this-system.png`](26-installed-about-this-system.png) | installed | System Settings, About this System: Companion OS 1.0, Plasma (based on CachyOS), https://ci.computer, Plasma 6.8.0, Frameworks 6.31.0, Qt 6.12.0, kernel 7.2.11-1-cachyos, Wayland, 4 x QEMU TCG CPU, 6 GiB RAM. | 13:37:56 |
| 27 | [`27-installed-about.png`](27-installed-about.png) | installed | System Settings About this System page with the Companion OS name and version, Plasma, kernel and virtual hardware lines. Same picture as 26. | 13:37:56 |
| 28 | [`28-installed-terminal-tools.png`](28-installed-terminal-tools.png) | installed | Konsole maximized: cat /etc/os-release (Companion OS 1.0, Plasma based on CachyOS, ci.computer URLs, CI_OS_VERSION 1.0, CI_OS_BUILD 20261018), docker --version 29.9.1, ollama --version 0.40.6. | 13:54:11 |
| 29 | [`29-first-boot-models.png`](29-first-boot-models.png) | installed | Konsole: ollama list (qwen3.6:27b 17 GB, gemma3:1b 806 MB, nomic-embed-text:latest 274 MB), df -h / (64G, 26G used, 37G free, 42 percent), free -h (5.8Gi RAM and swap). | 13:56:26 |

### Same picture under two names

Three pairs are the same pixels, written under two names because the public documentation pages and this repository name the same surface differently. Git stores one blob for each pair. The first name of each pair is the one the documents of this repository use.

| This repository | Other name | Frame |
|---|---|---|
| `21-installed-login-screen.png` | `22-first-boot-login.png` | the sign-in screen |
| `23-installed-first-desktop.png` | `24-first-boot-desktop.png` | the first desktop |
| `26-installed-about-this-system.png` | `27-installed-about.png` | About this System of the installed system |

### Frames of the capture that are not in this set

The full capture has 51 frames. These are not here, with the reason:

- First graphical frame of the live session (wallpaper only, panel not drawn yet, pointer in the middle of the screen), launcher Favorites page (empty), launcher All Applications A to H, the Welcome page (a near-duplicate of frame 07).
- The language popup (the right-hand column is unreadable on the highlighted row: a known flaw, finding 3 below) and the zone popup (evidence for a styling fix, not a documentation surface); the filesystem popup with no highlight at all (a finding, not a documentation frame).
- Near-duplicates of exported pages: the partition page before a choice, a selected package row, the empty Users page with "Password is too short", the 11 percent install frame, the "drivers" label frame.
- The three frames where the install page shows raw pacman status lines that name `cachyos` packages (a known cosmetic gap, finding 2 below).
- The installed GRUB Advanced options submenu (kernel package names only), the Autostart page, the hidden tray popup (weak negative evidence), the first-boot unit status (two 32-digit systemd identifiers, see above), the journal tail, and `systemd-analyze` with `hostnamectl` (Machine ID and Boot ID).

## What was fixed (the re-verification list of this round)

Each row says what the run showed. "Seen" means seen in the capture; where the frame is not in this set the row says so.

| # | Item | Result on ISO #6 |
|---|---|---|
| 1 | Install completes on the first attempt; note how long `create-pacman-keyring` takes | **Fixed, seen once.** First attempt, no error dialog, all 47 jobs, 28 min 26 s. `create-pacman-keyring` took **32 s** (15:48:13 to 15:48:45), longer than the old 30 s default that killed two of three attempts on ISO #5, and passed under the explicit `timeout: 3600` of the shipped `shellprocess_initialize_pacman.conf`. One run, at host load 9 to 13 |
| 2 | Install page status line at about 35 percent said "Installing needed drivers for CachyOS..." | **Label fixed.** The capture frame reads "Installing needed drivers for Companion OS..." at 35 percent (the frame is not in this set). **Raw pacman output with `cachyos` package names is unchanged**: see finding 2 |
| 3 | The language and zone popups and the partition radio buttons had no visible highlight | **Fixed for the zone popup and the radio buttons** (ring, and ring plus dot when selected; frame 11 shows the radio). **Gaps remain**: see finding 3 |
| 4 | Keyboard, package and progress pages still look right | **Still right** (frames 09, 12, 16, 17) |
| 5 | The installed GRUB lists only Companion entries plus firmware settings | **Fixed** (frame 19): Companion OS Linux, Advanced options for Companion OS Linux, UEFI Firmware Settings, Companion OS snapshots. The virtual machine's firmware still held a UiApp, an EFI shell and an NVMe boot entry, and none of them became a menu entry |
| 6 | No update notifier; graphical target within a minute while first-boot provisioning runs; provisioning ends clean with all three models and a short log | **Fixed** (frames 23, 29 and the capture record): no notifier on the desktop or in the hidden tray popup, no welcome app, no `cachy-update`, `arch-update`, `cachyos-welcome` or `cachyos-hello` package on the installed system; `graphical.target` after 43.9 s with provisioning running; `systemctl --failed` empty and `is-system-running` `running`; provisioning exit 0 after 21 min 18.9 s, the done marker written, `nomic-embed-text`, `gemma3:1b` and `qwen3.6:27b` listed (frame 29), a 301-line log and 320 journal lines. The frame that shows the unit status and the marker is not in this set |
| 7 | `verify-iso.sh` on this ISO, 0 failures expected | **Done: 215 passed, 0 failed** |

## What was found

Ordered by what a person at the screen notices first. Severity is the one given on the [known issues page](../../../architecture/known-issues-and-decisions.md).

1. **The login manager is the Plasma Login Manager, not SDDM** (decision D2 of the backend README). The greeter starts on a clock page and shows the prompt after a key press (frame 21). It has the stock avatar and button set and no Companion mark; the wallpaper behind it is Companion's. Low (KI-26).
2. **Raw pacman output with `cachyos` package names** passes through the install page's status line for seconds at a time, in the pacstrap job (for example "Updating CachyOS specific configuration." and "Optional dependencies for linux-cachyos-lts") and in the packages job ("pacman: installing cachyos-alacritty-config..."). These are the packages' own lines, not job labels, and no other install frame names CachyOS. Low (KI-08).
3. **Highlight gaps in the installer** (KI-09). The right-hand column of the language popup is white on the pale highlight, nearly unreadable on the highlighted row. The filesystem drop-down on the Partitions page has no highlight, neither for the current entry nor on hover. The selected partition option has the ring-and-dot radio but no row highlight (frame 11). Low.
4. **The boot splash reads "COMPANION INTELLIGENCE"**, the company lockup, not "Companion OS" (frame 20), while the GRUB menu, the login screen and About this System say Companion OS. Not a CachyOS leak. Low, an owner decision (KI-08).
5. **Copy mismatches and untidy pages in the installer** (frames 10, 14, 15). The Bootloader page says GRUB finds other operating systems on the disk, but the installed `GRUB_DISABLE_OS_PROBER` is `true` by design, so another system installed next to Companion OS gets no menu entry. The Summary page grows the window and does not list the package choice. The confirmation says "your disk" without naming the device, which the Summary behind it does. The language selector keeps the stock translate pictogram. Low (KI-09, KI-26).
6. **Log noise of a successful install.** 58 `WARNING` lines and 1 `ERROR` line, all non-fatal and no "timed out" line: `Could not inhibit sleep` (no PowerManagement service in the live session), unknown global-storage keys, "Cannot enable/disable systemd unit" for units this edition does not ship (cups, vboxservice, vmtoolsd, firewalld, the zfs units, pacman-init; ten failed `systemctl` lines), `No config file for "chwd"`, and **eight lines `[Errno 2] No such file or directory: 'chcon'`** (a job looking for `chcon`, which is not in the live image; SELinux is not used on this edition, so it is harmless noise). Low (KI-26).
7. **Noise in the first-boot log**, none of it changing the exit code: a Node stack trace `Cannot find module '.../pnpm.cjs'` after `corepack prepare pnpm@latest --activate: ok`, followed by "[SUCCESS] pnpm is available"; `[WARNING] gdm not detected` (irrelevant on Plasma); a Node 22.15.1 maintenance warning; and `CI-Hub not deployed: REGISTRY_USERNAME/REGISTRY_PASSWORD not set` (expected without registry credentials, and the units and the marker do not depend on it). Low (KI-26).
8. **Other lines of the installed boot** (`journalctl -b -p err`): `virt/tdx: TDX not supported by the host platform` (kernel, harmless in a virtual machine), a user unit "Failed to start Portal service" (51 s into the session under heavy load; the desktop and About page worked; not investigated), and a libinput warning that event processing lags behind by 24 ms. The first journal lines carry the host name `cachyos` (the kernel's pre-set name); the host name the person sees is `companion`.
9. **Live medium.** `systemctl is-system-running` is `degraded` there because `systemd-time-wait-sync.service` fails (it waits for a kernel time sync; not user-visible; the installed system is `running`). `/usr/local/bin` lists upstream CachyOS helper names (`choose-mirror`, `dmcheck`, `pkexec-wrapper`, `prepare-live-desktop.sh`, `remove-nvidia`, `removeun`, `removeun-online`) next to the overlay's `calamares-online.sh`. There is no installer icon on the desktop; the application menu entry is the only way in. `cachyos-hello` is installed on the live medium but hidden and does not start. Low.
10. **The model gate still has no data on this edition.** A 6 GiB, GPU-less guest pulled `qwen3.6:27b` (17 GB) again, and the root file system went from 8.34 GiB to 26 GB used of 64 GB (KI-01).
11. **Time zone.** The Location page preselected New York, and the installed system took America/New_York. The capture notes do not say which, but the Calamares session log of the run (scratch only, not in the repository) points to the fallback: the country request to `geoip.kde.org/v1/ubiquity` answered `US`, while the zone request to `geoip.kde.org/v1/calamares` failed with `QNetworkReply::ProtocolFailure` at 19:35:04 guest time. ISO #5 showed the same failure on its first attempt and the same New York fallback.

### Harness notes (not product findings)

- Under guest load (load average 26 while Ollama downloaded and kwin rendered in software) typed characters were **doubled** in a first attempt at frame 28 (`os-reelease`, `doccker ---version`). That frame was discarded and retaken after provisioning ended, with a longer key delay, and every line was checked before `Enter`.
- The screen locked after about 10 idle minutes while waiting for provisioning, and Plasma dims after about 5. The line typed at the lock screen went into the masked field, was cleared, and the real password was typed.
- The first boot attempt missed the installed GRUB menu (the watcher of the live medium only recognised the 800x600 mode); that boot was discarded and the overlay and NVRAM recreated, so every installed frame comes from one clean boot.
- A poll for the done marker used a plain `ls`, which hides the dot file `.first-boot-setup-done`, so it never fired and timed out; completion was read from the service state and confirmed with `ls -la`. A root-owned `ollama list` from the guest agent panicked because the agent has no `$HOME`; the shipped unit sets `HOME=/root`, and the user's own `ollama list` in a terminal worked (frame 29).

## What the frames do not show

A virtual machine with software emulation, not a physical computer. They do not show Secure Boot, Wi-Fi, several drives, a GPU, BIOS (syslinux) boot, an offline install, a second install run, the setup portal, or the Hub running (no registry credentials were set, so the page behind the "Companion Hub (browser)" launcher entry, frame 25, was not tested). The first-boot unit status and the done marker were read in the capture but their frame is not in this set.
