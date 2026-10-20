# Testing in QEMU on Apple silicon

Private & Confidential. Property of Lifescope Inc. Do not distribute.

How the Companion OS images are booted, installed and photographed under QEMU on an Apple-silicon Mac: the firmware files, CPU models, device list, QMP screenshots and typing, the timings to expect under TCG, and how the installed-boot test and the full capture runs work. Building the images is in [Building on a Mac](building-on-a-mac.md); what has been run and what it showed is in [Test evidence](../architecture/test-evidence.md).

Evidence tags: **[V]** verified (run, result seen), **[I]** read from code or documentation and not run, **[N]** not checked.

## The harness at a glance

| Piece | Where | What it does |
|---|---|---|
| Installed-system boot test (Ubuntu edition) | `backends/ubuntu/iso/tests/installed-boot.sh`, `backends/ubuntu/iso/tests/lib/` | Builds a throw-away installed disk from the ISO's default install layers in a privileged container, boots it, asserts the GDM greeter comes up |
| CachyOS live-ISO boot supervisor | `backends/cachyos/iso/tests/qemu-boot.sh` | Boots the live ISO in `direct`, `bios` or `uefi` mode, asks the guest agent whether `plasmashell` and `kwin_wayland` run, takes screenshots |
| Stick boot tests | `stick/tests/qemu/run.sh`, `stick/tests/secureboot/run-on-mac.sh` | Flash a sparse stick image and boot it as a USB stick (development chain; Secure Boot A/B/C) |
| QMP helper for the repo's tests | `backends/ubuntu/iso/tests/lib/qmp.py` | `shot FILE.png`, `status`, `quit` over a QMP socket (standard library only) |
| arm64 live-to-installed runs (Ubuntu edition) | `backends/ubuntu/iso/tests/boot-arm64-vm.sh`, `backends/ubuntu/iso/tests/lib/qmp-drive.py` | Boots an arm64 image as a USB drive at near-native speed (HVF), photographs it, clicks and types over QMP; the runs of 2026-10-19 used exactly these two files **[V]** |
| Full x86-64 live-to-installed capture runs | a session harness, not in the repository; the recipe is below | Interactive GUI VM driven over QMP, with a guest agent for read-only checks |

The supervisor scripts start and stop QEMU themselves. For anything interactive (clicking through an installer, taking documentation screenshots) start QEMU yourself with the command line below and drive it over QMP.

## Host

| Item | Value |
|---|---|
| Binary | Homebrew `qemu-system-x86_64` 11.1.2 [V]. x86-64 guests run under **TCG only**: there is no KVM and no HVF for another instruction set. Use `-accel tcg,thread=multi` |
| `qemu-img` | Prefer Homebrew's (`/opt/homebrew/bin/qemu-img`). The first `qemu-img` on `PATH` may be the Android SDK's copy, whose version differs [V] |
| Firmware | See next section |
| Image tools | ImageMagick (`magick`), `ffmpeg`, system `python3` with Pillow for frame statistics [V on the session host] |
| Keep awake | `caffeinate -i` for runs of tens of minutes |

## Firmware: OVMF files

Four files, one pair for normal boots and one for Secure Boot:

| File | Use |
|---|---|
| `OVMF_CODE_4M.fd` | UEFI code, Secure Boot **not** enforcing. Mapped read-only (`unit=0`) |
| `OVMF_VARS_4M.fd` | Variable store for it. **Give every VM its own copy** (`unit=1`, writable); the installer writes its boot entry there |
| `OVMF_CODE_4M.secboot.fd` | UEFI code with Secure Boot enforcing |
| `OVMF_VARS_4M.ms.fd` | Variable store with the Microsoft keys enrolled |

They come from Ubuntu's `ovmf` package, produced by `stick/tests/secureboot/build-in-container.sh` into `stick/tests/secureboot/out/firmware/` (gitignored) with a `firmware.lock` that records the version. On Ubuntu 26.04 the same four files are in the `ovmf-generic` package (`ovmf` is a metapackage there; 2025.11-3ubuntu7.3 in the port run) [V]. The Plasma capture runs used the 2024.02 build (Ubuntu 24.04 `ovmf 2024.02-2ubuntu0.10`); the Secure Boot A/B/C run of the Stick used 2025.11 [V]. Homebrew also ships `edk2-x86_64-code.fd` and `edk2-x86_64-secure-code.fd` [V, present; not used by the recorded runs].

The CachyOS edition's GRUB and kernel are **not signed**, so it boots with the non-Secure-Boot pair only. The `.secboot` variant was never tried on it, so "the Secure Boot firmware refuses this GRUB" is expected, not observed [N].

## CPU models

| Guest | `-cpu` | Result | Source |
|---|---|---|---|
| Ubuntu 24.04 live and installer GUI, native macOS QEMU 11.1.2 (retired baseline) | `Haswell` | works, the installer completed | session evidence, retired |
| same | `max` | desktop comes up, **the installer GUI aborts** (Mesa software rendering under that model) | session evidence, retired |
| Ubuntu 24.04 live in Docker's aarch64 QEMU 8.2.2 (retired baseline) | `Haswell` / `Nehalem` | `Haswell` crashes GNOME Shell (signal 11) and the installer; `Nehalem` works | session notes, retired |
| installed Ubuntu 24.04 disk, native (retired baseline) | `Nehalem` (the default of `installed-boot.sh`) | GDM greeter at 257 to 261 s | `installed-boot` results of the 24.04 layer, retired |
| CachyOS live and installed | `max` (the default of `qemu-boot.sh` under TCG) | works; `qemu64` also works | [V] captures of ISO #4, `docs/architecture/cachyos-backend.md` |
| **Ubuntu 26.04.1 Companion OS** | not measured | **pending**: `installed-boot.sh` keeps `Nehalem` as its default; `Haswell` is the safe first alternative; `max` is known to break the 24.04 installer | [test-evidence.md](../architecture/test-evidence.md#pending-evidence-for-the-ubuntu-2604-image) |

## The QEMU command line for an interactive run

This is the command that took the Plasma edition from live boot through Calamares to an installed boot, with the host-specific paths replaced by variables. It was also run against the stock Ubuntu 26.04.1 ISO for this guide: GRUB 2.14 appeared at 1280 by 800 within 8 seconds and a QMP screenshot and a key press worked [V].

```bash
FW=stick/tests/secureboot/out/firmware          # or wherever OVMF_*.fd live
W=$(mktemp -d /tmp/ci-qmp.XXXXXX)               # SHORT path: macOS limits unix socket paths to 104 bytes
ISO=$PWD/output/companion-os-plasma-2026.10.18-x86_64.iso
cp "$FW/OVMF_VARS_4M.fd" "$W/vars.fd"
/opt/homebrew/bin/qemu-img create -q -f qcow2 "$W/target.qcow2" 64G     # the install target; sparse

nice -n 5 caffeinate -i qemu-system-x86_64 -name ci-run -pidfile "$W/qemu.pid" \
  -machine q35 -accel tcg,thread=multi -cpu max -smp 4 -m 6144 -rtc base=utc \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW/OVMF_CODE_4M.fd" \
  -drive if=pflash,format=raw,unit=1,file="$W/vars.fd" \
  -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 \
  -drive if=none,id=cd,file="$ISO",media=cdrom,readonly=on,format=raw -device ide-cd,drive=cd,bootindex=0 \
  -drive if=none,id=target,format=qcow2,file="$W/target.qcow2" -device nvme,drive=target,serial=ci-target,bootindex=1 \
  -nic user,model=virtio-net-pci -vga std -display none \
  -device virtio-serial-pci,id=vser0 -chardev socket,id=qga0,path="$W/qga.sock",server=on,wait=off \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0,bus=vser0.0 \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  -qmp unix:"$W/qmp.sock",server=on,wait=off -serial file:"$W/serial.log" &
echo "QEMU started, files in $W"        # caffeinate exits when QEMU does; kill $(cat "$W/qemu.pid") discards the VM
```

| Part | Why |
|---|---|
| `-machine q35`, `-accel tcg,thread=multi`, `-cpu max`, `-smp 4`, `-m 6144` | The measured configuration of the Plasma runs. 6 GiB and 4 vCPUs never ran short of memory (guest free RAM stayed above 3.8 GB during the install) |
| `-rtc base=utc` | The guest clock starts as UTC; the installed system's time zone then decides what its clock shows |
| two `pflash` drives | UEFI code read-only, per-VM variables writable |
| `qemu-xhci` plus `usb-tablet` | An **absolute pointer**. Without it, QMP clicks do not land where you aim |
| `ide-cd` on `bootindex=0`, NVMe target on `bootindex=1` | The ISO boots first; after the install the empty target is the second choice. An NVMe disk is also what the Ubuntu one-click installer accepts as an internal disk (a USB or SATA-on-USB target would be refused) |
| `-nic user,model=virtio-net-pci` | NAT: the guest reaches the internet through the host. The Plasma installer is an **online** installer and needs it. For an offline boot use `-nic user,model=virtio-net-pci,restrict=on` (an address, no route out) |
| `-vga std -display none` | A frame buffer with no window; screenshots come from QMP |
| guest agent on `virtio-serial` | Read-only checks (`systemctl`, `cat`, `df`) without typing. The CachyOS live image and the installed system ship `qemu-guest-agent`; the recorded Ubuntu 24.04 runs used a small HTTP channel to the host instead |
| `virtio-rng` | Entropy for `pacman-key` and the first boot |
| `-qmp unix:...`, `-serial file:...` | Control socket in the short directory; the serial log stays empty unless the kernel line has `console=ttyS0` |
| no `-no-reboot` | A Calamares "Restart now" would go back into the ISO, so the runs power off with `systemctl poweroff` through the guest agent instead. With `-no-reboot`, a restart simply ends QEMU |

For a **Secure Boot** boot, use `-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on` with the `.secboot` code file and the `.ms` variable store. For a boot of the **installed** disk, drop the CD drive, make the target `bootindex=0`, and start from a fresh `qcow2` overlay of the pristine post-install disk so the disk stays reusable:

```bash
/opt/homebrew/bin/qemu-img create -q -f qcow2 -b target.qcow2 -F qcow2 "$W/boot-A.qcow2"
cp "$W/vars.after-install.fd" "$W/vars.boot-A.fd"     # the variable store that holds the installer's boot entry
```

## Driving the guest over QMP

QMP is QEMU's JSON control socket. Four things matter: screenshots, keys, typing, and the pointer. The repository's `qmp.py` does screenshots only; the appendix has a small helper (`qmpctl.py`, standard library only) that does all four. Verified against a bare QEMU for `screendump` (PNG), `send-key`, `input-send-event` and `query-status` [V].

```bash
S="$W/qmp.sock"
python3 qmpctl.py "$S" shot  "$W/01.png"        # PNG, no retouching
python3 qmpctl.py "$S" key   meta_l              # open the Plasma launcher
python3 qmpctl.py "$S" type  "konsole"           # 0.12 s per character
python3 qmpctl.py "$S" key   ret
python3 qmpctl.py "$S" click 1040 650            # a Calamares "Next" button, at 1280x800
python3 qmpctl.py "$S" move  1279 400            # park the pointer at the right edge
```

Rules learned the slow way:

- **Act, wait 10 to 20 seconds, take a screenshot, open it, judge it, then go on.** Under TCG a busy guest drops or reorders keystrokes.
- **Typing speed.** The default 0.06 s per character duplicated a character once; 0.10 to 0.12 s was correct on every line of the Plasma runs (`QMP_TYPE_DELAY`). Keys are QEMU qcodes: `meta_l` (the launcher; pressed again it closes the launcher, and the next typed text then opens KRunner at the top of the screen), `esc` (not `Escape`), `ret`, `ctrl+l` (clears the terminal so the command line stays in the frame), `meta_l+pgup` (maximise).
- **The screen dims after about 5 idle minutes and the session locks after about 13.** A pointer move wakes the screen; wait 2 to 4 seconds for the fade before a screenshot. Text typed at a lock screen is submitted as a password attempt.
- **Park the pointer.** Good spots: the right edge `(1279,400)` and, with a normal window open, the top-right corner `(1279,1)`. Bad spots: the bottom-right corner (the panel's "Show Desktop" button shows a "Peek at Desktop" tooltip) and the top-right corner with a maximised window (it lands on the Close button and turns it red). A one-pixel sliver of the arrow can remain visible.
- **Frame sizes.** GRUB frames are 800 by 600 on the CachyOS UEFI menu (OVMF's GOP mode); the stock Ubuntu menu was 1280 by 800 in the smoke test. Every desktop frame was 1280 by 800.
- **Stopping the GRUB countdown.** The Plasma menu counts down 6 seconds, the stock Ubuntu menu 30. Any key cancels it. A simple catch is a short loop of `up` presses right after starting QEMU (harmless before GRUB is running; **[I]**, the recorded runs used the polling catch described next):

```bash
for i in $(seq 1 24); do python3 qmpctl.py "$S" key up; sleep 0.5; done
```

  The capture runs polled screenshots every 0.4 seconds and pressed `up` once the themed menu was on screen; they saw the menu 2.2 to 2.7 seconds after QEMU started.
- **Waiting for a drawn desktop.** Poll screenshots and wait until a frame is mostly non-black (the runs used at least 35 percent non-black pixels and 200 distinct colours at 1280 by 800), then until three consecutive polls change less than 1 percent.
- **The guest agent** (`virtio-serial` port `org.qemu.guest_agent.0`) runs read-only commands as root in the CachyOS live and installed systems. Use it to ask `systemctl is-system-running`, to `cat` a log, to `poweroff`. It never started the installer in the capture runs.
- **Documentation screenshots** must show no host paths, user names, hashes of 24 or more hex characters, or passwords. Check each frame by eye, and run an OCR or text scan over a whole set before it is published.

## Timings to expect under TCG

Measured on a 12-core Apple-silicon Mac, QEMU TCG, 4 vCPUs, 6 GiB, host load 2.5 to 9 for ISO #4 unless stated. Loaded hosts (load 13 to 96) were 2 to 3 times slower.

| Step | Time | Source |
|---|---|---|
| Plasma live: QEMU start to GRUB menu | 2.2 to 2.7 s | [V] ISO #4, #5 and #6 captures |
| Plasma live: Enter in GRUB to first drawn frame | 4 min 05 s to 4 min 10 s (ISO #4, #5); 5 min 08 s on ISO #6 at host load 13 to 20; desktop settled 5 min 08 s to 6 min 38 s after Enter | [V] |
| Plasma live: click "Install Companion OS" to the Calamares window | about 3 min (keyring, database sync, guards, overlay, package preflight); about 2 min 40 s on ISO #5 and #6 | [V] ISO #4, #5 and #6 |
| Calamares install, "Install Now" to "completion: succeeded" | **22 min 09 s** (the whole stage with the page walk-through about 40 min); 47 jobs | [V] ISO #4 |
| Installed Plasma, offline: power-on to GRUB / splash / greeter | 10.5 s / about 56 s / 113 s | [V] |
| Installed Plasma: login to a drawn panel | 55 s offline; 93 s while the first-boot provisioning ran beside it | [V] |
| `systemd-analyze` of the installed system | offline: 2.8 s kernel, 4.2 s initrd, 3 min 55 s userspace; online with provisioning (before the unit fix): 16 min 27 s userspace | [V] |
| First-boot provisioning with a network (three Ollama models, about 18.8 GB) | **16 min 4.6 s** on ISO #4 (the 17.8 GB model alone about 10 min at 26 to 50 MB/s); **21 min 49 s** on ISO #5 (about 14 min at 20 to 29 MB/s plus about 3.5 min of digest check); **21 min 19 s** on ISO #6. Network speed decides | [V] |
| Installed Plasma (ISO #5), online, with provisioning running: `systemd-analyze` | 2.7 s kernel, 4.1 s initrd, 37.8 s userspace; graphical target after 37.8 s (ISO #4: 16 min 27 s) | [V] |
| Calamares install on ISO #5 (the successful third attempt) | 23 min 20 s; two earlier attempts died at 2 percent after about 1 min 50 s each (the 30 s keyring limit, KI-20) | [V] |
| Calamares install on ISO #6 (`ad37b64`, the first attempt) | **28 min 26 s** at host load 9 to 13: `create-pacman-keyring` 32 s, `pacstrap` 553 s, `packages` 717 s, `mkinitcpio` 120 s | [V] `docs/evidence/2026-10-18-plasma-iso6/calamares-jobs.txt` |
| Installed Plasma (ISO #6), online, with provisioning running | GRUB menu 1.2 s after power-on, greeter 1 min 32 s after Enter in GRUB; `systemd-analyze` 3.2 s kernel, 4.2 s initrd, 43.9 s userspace; first-boot provisioning **21 min 18.9 s** | [V] `docs/ui/companion-os/plasma/CAPTURE.md` |
| `verify-iso.sh` on the Plasma ISO #6 | about 84 s, 215 passed, 0 failed | [V] `docs/evidence/2026-10-18-plasma-iso6/verify.log` |
| Retired baseline (Ubuntu 24.04.5): live ISO to a usable desktop | about 9.4 to 10 min | session notes, retired |
| Retired baseline: installed disk to the GDM greeter (`installed-boot.sh`, Nehalem, 4 GB, no network) | 257 to 261 s | [V], retired |
| Retired baseline: Ubuntu 24.04 GUI install (click Install to "Installation complete") | about 5 h 39 min, most of it in "Setting up the system" | [V] file times, retired |
| Ubuntu 26.04.1 Companion OS: live boot, GUI install, installed boot | **pending** | [test-evidence.md](../architecture/test-evidence.md#pending-evidence-for-the-ubuntu-2604-image) |
| Stick boot test, signed chain (GRUB menu 3 to 7 s) | the whole boot-and-test 25 to 33 s | [V] |

The 4 to 10 hour estimate made for a Calamares install under TCG did not happen; the mirrors were fast and the guest only had to download, check and unpack. Plan on the lower figure, but keep the stall rule below.

## The installed-boot test (Ubuntu edition)

`backends/ubuntu/iso/tests/installed-boot.sh` exists because a boot of the live ISO proves nothing about the installed system: the v7 image installed fine and then stopped at "Unable to find a medium containing a live file system", found only after a seven-hour GUI install. The test builds the installed disk the way an install ends up and boots it in minutes.

```bash
# What an installer would install, from a built ISO: static checks, then a boot to the GDM greeter.
backends/ubuntu/iso/tests/installed-boot.sh --iso output/companion-os-1.0-amd64.iso --keep-disk

# Static checks only (no boot): the regenerated initrds, grub.cfg, the ESP.
backends/ubuntu/iso/tests/installed-boot.sh --iso output/companion-os-1.0-amd64.iso --no-boot

# Its own parts against a fake QEMU and synthetic initrds (no Docker, no QEMU; seconds).
backends/ubuntu/iso/tests/installed-boot.sh --selftest
```

Exit status: 0 passed; 1 the installed system is defective; 2 cannot run here (a tool, firmware or Docker missing); 3 the harness failed (not a verdict). Results land in `--work DIR` (`result.txt`, `checks.txt`, `timeline.txt`, `serial.log`, `guest-report.txt`, `screenshots/`). Defaults: `--timeout 1800`, `--cpu Nehalem`, `--memory 4096`, `--smp 4`, no network (`restrict=on`, because the first-boot provisioning would otherwise pull gigabytes of models during the test).

Status on 26.04.1: `--selftest` passes (25 checks in the last full `check-repo.sh` run), and `--squashfs <B> --no-boot` on the split base layer gave 23 PASS, 2 WARN, 0 FAIL, with the initrd generated by initramfs-tools in 104 s and no `casper` in it [V]. `--iso` on the first built 26.04.1 Companion OS image with `--no-boot` gave **0 FAIL, 0 WARN, 25 PASS in 413 seconds** [V] (the root filesystem copy took about 270 s and `update-initramfs` about 98 s). The run **with a boot** on that clean-checkout image is pending (row U2 of [test-evidence.md](../architecture/test-evidence.md#pending-evidence-for-the-ubuntu-2604-image)). The same command without `--no-boot` did pass on an **earlier fix-pass image** (version string 9.9, sha256 `dce9eb71...`, built from a worktree snapshot and not from a commit): 25 static checks, then the assembled disk reached the GDM greeter after 230 s of boot, 681 s in all [V] (`docs/evidence/2026-10-18-ubuntu-fixpass-9.9/`). That disk is assembled by the harness, not installed by the installer.

On Apple silicon the script starts its builder container with `--platform linux/amd64` and the default image `ubuntu:26.04`. That worked on 2026-10-18 under Rosetta (apt unpacked packages in it without error [V]), although a different amd64 `ubuntu:26.04` container failed on 2026-10-17 with a tar ENOSYS (see [Building on a Mac](building-on-a-mac.md#why-arm64)). If it fails for you, the exit status 2 message names the builder image; pass `--image` with an image that already has `losetup`, `mount`, `mkfs.ext4`, `mkfs.vfat`, `sfdisk`, `blkid`, `e2fsck` and `python3`. The disk build runs in a chroot of the ISO's own layers, so the builder image's release does not decide what is tested.

## The full capture run, step by step

The documentation screenshots and the "does it really install" evidence come from three stages on one VM. The latest recorded run is ISO #6, whose capture record, frames and text records are in the repository ([`docs/ui/companion-os/plasma/CAPTURE.md`](../ui/companion-os/plasma/CAPTURE.md), `docs/evidence/2026-10-18-plasma-iso6/`); the earlier runs (ISO #4, and ISO #5 with its three stages) have their notes only in the session `CAPTURE.md` files. All are summarised in [test-evidence.md](../architecture/test-evidence.md).

1. **Live.** Start QEMU with the command above, stop the GRUB countdown, wait for the drawn desktop, take the live frames (GRUB, first frame, desktop, launcher, About, terminal). Start the installer **exactly as a user would**: launcher search, "Install Companion OS", Enter. No keyring initialisation by hand, no `CI_OS_SKIP_KEYRING`, no package installed by hand.
2. **Install.** Page order of the Plasma edition (`backends/cachyos/installer/settings.conf`): Welcome, Location, Keyboard, Bootloader (GRUB is the only choice), Partitions, Packages, Users, Summary, Install, Finish. Choose Erase disk on the only disk. The slideshow is four text-only slides rotating every 20 seconds. Monitor read-only: a watcher that polls the guest agent every 120 seconds (Calamares log size and last job, free RAM, free space on the target, host free space) with a stall rule of "no change in percentage, status, log size and job line for 90 minutes". The stall rule never triggered. Finish with "Restart now" **unticked**, then `systemctl poweroff` through the guest agent.
3. **Installed.** Boot the disk with no CD-ROM and a fresh overlay per boot: once **offline** (`restrict=on`) for clean product frames, once **online** for the first-boot provisioning. The stage 3 findings (the `$HOME` panic that made provisioning end "degraded", the boot targets held by a oneshot, the model-pull flood in the journal, the disk budget) came from this stage.

Credentials: use a throwaway account, a random password from `openssl rand -base64 30 | tr -d '/+=\n' | cut -c1-20` written to a file with mode 0600, typed into the installer straight from that file through a shell variable, never echoed, never with the "show" control. Scan every frame, manifest and log for the password before anything is published (the runs found 0 occurrences). Hard rules: QEMU uses **file-backed images only**; never attach or write a physical USB stick or any host block device; stop and thin Time Machine snapshots if the Data volume falls under 30 GiB; keep the Mac awake.

## The arm64 run on an Apple-silicon Mac (Ubuntu edition)

An arm64 guest on an Apple-silicon Mac runs with HVF, the host's own accelerator, so it is a different world from the TCG numbers above: the live desktop
appeared in about 2 minutes, a one-click install took 9 min 35 s and 12 min 10 s, the greeter came 50 s after power-on and the first-boot job took 1 min 58 s
(2026-10-19, `docs/evidence/2026-10-19-ubuntu-arm64-4b7597d/`) **[V]**. The harness is two committed files:

```bash
T=backends/ubuntu/iso/tests
$T/boot-arm64-vm.sh start output/companion-os-1.0-arm64.iso ./target.qcow2   # the ISO as a USB drive, a file-backed NVMe target (created, 64 GiB sparse)
$T/boot-arm64-vm.sh shot frame.png                                           # a screenshot; also: status, stop, info
python3 -I $T/lib/qmp-drive.py /tmp/ci-arm64-vm/qmp.sock click 33 64 1280x800    # key, type, click, dclick, rclick, scroll
$T/boot-arm64-vm.sh start - ./target.qcow2                                   # after the installer powers off: boot the installed disk alone
```

Facts the runs taught:

* `type` sends PHYSICAL keys (QMP names them by their US position). A guest installed with another keyboard layout needs `QMP_LAYOUT=de` (German is the one table there is: y and z swapped, `-` on the slash key, `:` on shift+dot, `|` on AltGr+less); without it the one-time password and every command come out wrong. `qmp-drive.py - keys de "text"` prints the keys without a VM. The table is tested against an independent copy of the layout (`test_qmp_layouts.py`).
* The screen is 1280 by 800; the dock's first launcher is at (33, 64) and a window's close button at the top right. Look at a frame before you click.
* Under load a key can be dropped or a modifier can stick: `QMP_HOLD=0.1`, `QMP_TYPE_DELAY=0.08`, and tap `shift shift_r ctrl alt` once to release everything. The guest is slow
  while the first-boot job runs (3 min after boot): wait 20 s after a sign-in step and look before you type the next.
* The one-click dialog and its progress window show a one-time password. **Read it from the picture, not only from OCR**: `tesseract` read one character wrong (`c` as `e`) and five
  sign-ins failed without a message. Save the password to a 0600 file outside the repository, type it from the file, and redact the dialog's frames before they are kept.
* A text channel is easier than screenshots: serve a script directory from `127.0.0.1` with any small HTTP server, run `curl http://10.0.2.2:<port>/script.sh | sh` in the guest
  terminal (user networking reaches the host at `10.0.2.2`) and have the script `POST` its output back. The first-boot status, the journal and the unit settings were read this way.
* The guest has no Secure Boot firmware under Homebrew's QEMU; `qemu-efi-aarch64` on Ubuntu has `AAVMF_CODE.ms.fd`, not tried **[N]**.

## Recording a first-run video

The same harness records a video of the first start: boot menu, the one-click dialog, the install, the first sign-in and the first-boot notifications. A QMP `screendump` has no mouse pointer and no sound, so the video is made from frames and a few text files; nothing is recorded from the host's screen.

1. **Record before power-on.** `backends/ubuntu/iso/tests/record-frames.sh DIR 1.5` writes one PNG every 1.5 s plus the time a screendump takes (about 3 s apart in practice) into `DIR/f-<epoch>.png` until `DIR/STOP` exists; it keeps going while the VM is off, so one recording covers the install's power-off and the next boot. Keep `DIR` outside the repository: frames show the one-time password.
2. **Drive the run at a human pace** (a pause of 4 to 5 s between steps, or a state is between two frames). `QMP_CLICK_LOG=clicks.txt` makes `qmp-drive.py` log every click so the video can draw a ring there; `QMP_LAYOUT=de` types for a German keyboard. After each step append `date -u +%FT%TZ` and what you did to an events file: the chapters come from it.
3. **Write `chapters.txt`** (`<time> | caption`) and **`redact.txt`**. For the one-click dialog of 1280 by 800 (rules of `lib/make-video.py`'s header): the confirmation's password line is `340 386 290 26` while the dialog is on screen, and the progress window's whole text block is `385 386 580 62` (the password moves between its lines as the status text changes), each with `bright` and a pixel region of the dialog so a console or a login screen is left alone, for example `bright 700 130 100 20` for the confirmation and `bright 400 330 100 20` for the progress window.
4. **Assemble:** `python3 backends/ubuntu/iso/tests/lib/make-video.py out.mp4 --frames DIR --chapters chapters.txt --redact redact.txt --clicks clicks.txt --clock --title "..." --outro "..."`. A frame that repeats the one before is dropped, so the install's 11 minutes become seconds; `--clock` shows the real time that has passed. Needs Pillow and ffmpeg (ffmpeg of Homebrew has no `drawtext`, so Pillow draws the captions).
5. **Look at the result before it goes anywhere.** The tool paints boxes where you say; it does not find the password. `tesseract` did **not** read the bold monospace password at 1280 by 800 with `--psm 11`, so an OCR scan of the video proves nothing. Tile frames with `ffmpeg -i out.mp4 -vf "fps=1,crop=700:200:290:300,scale=640:-1,tile=3x9" -frames:v 1 sheet.png` and read the dialog region of each.

Keep the guest awake: after five minutes without input GNOME blanks the screen (the next frames are black, "Display output is not active") and locks the session; a mouse move every couple of minutes (`qmp-drive.py SOCK move X Y`) avoids it, or accept it as what a user would see. Limits seen: a banner stays on screen for about half a minute here, and a script started from a terminal had its banners held back by GNOME (start it with `systemd-run --user`); typing and clicking jump from state to state because the recorder is not continuous; the first frames of a run are the firmware's. The video of a run is evidence of what was shown, not of anything else: it is a virtual machine. The run of `82e9335` (`docs/evidence/2026-10-19-ubuntu-arm64-82e9335/`, with its chapters and redaction rules in `video-inputs/`) gave a 52 second cut from 942 frames; the video file is not in the repository.

**The film, not the time-lapse.** The same recording also feeds the org's own film of the first run, `video/` (CI-Common's video kit, one storyboard, house voice, landscape and square cuts): [`video/README.md`](../../video/README.md). It needs a few things the time-lapse does not. Start the VM at the film's size with `CI_VM_RES=1920x1080` (the plates are 1920 x 1080 frames, and `qmp-drive.py click X Y 1920x1080` takes that as the screen size); log every click with `QMP_CLICK_LOG` (the pointer coordinates of the storyboard come from that file as fractions of the plate); keep the epoch of each frame you want (the boot menu with the automatic entry highlighted, each setup notice); and cover the one-time password on the plates with `video/tools/make-plates.py` rather than with `make-video.py`'s boxes. The run of 2026-10-19 at 1920 x 1080 (`docs/evidence/2026-10-19-ubuntu-arm64-82e9335-video-run/`) gave 1,009 frames, 15 plates and an 86 second film; its installed system showed the root filesystem check message and then nothing for a minute, once, on the first start (KI-28), and the next start was normal.

## Safety rules

1. File-backed disk images only. No host mounts, no host block devices.
2. Each VM has its own OVMF variable store and its own qcow2 target; an overlay protects a pristine post-install disk.
3. No real credentials and no host secrets in any frame, log or command line that is saved. Record the QEMU command line with paths abbreviated.
4. Record for every run: the ISO file name and sha256, the build record next to it (`.build-info`), the QEMU command, the host load at the start and the date, in a `CAPTURE.md` beside the frames. Copy the text records (result files, timelines, serial and installer logs, the sha256) into [`docs/evidence/`](../evidence/README.md) as well, so that the proof outlives the session scratch directory; the frames and `CAPTURE.md` go under `docs/ui/companion-os/`.

## Appendix: qmpctl.py

Save as `qmpctl.py`. It uses only the standard library and talks to the QMP socket of a running VM. The keyboard mapping covers ASCII; the pointer needs `-device usb-tablet`.

```python
#!/usr/bin/env python3
"""Minimal QMP helper for GUI runs under QEMU (standard library only).

  qmpctl.py SOCK shot FILE.png          screendump as PNG (QEMU 7.1 or newer)
  qmpctl.py SOCK key ret tab ctrl+alt+t press keys (QEMU qcodes; modifiers joined with +)
  qmpctl.py SOCK type "text"            type ASCII text, 0.12 s per character (QMP_TYPE_DELAY overrides)
  qmpctl.py SOCK click X Y [W H]        left click at pixel X,Y of a W x H screen (default 1280 800); needs -device usb-tablet
  qmpctl.py SOCK move X Y [W H]         move the pointer without clicking
  qmpctl.py SOCK status                 run state of the VM
  qmpctl.py SOCK quit                   power the VM off at once
"""
import json, os, socket, sys, time

SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
           '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash', ':': 'semicolon',
           '"': 'apostrophe', '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent'}
PLAIN = {' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
         ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent',
         '\n': 'ret', '\t': 'tab'}


class Qmp(object):
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile('rw')
        self.f.readline()                       # greeting
        self.call('qmp_capabilities')

    def call(self, cmd, **args):
        self.f.write(json.dumps({'execute': cmd, 'arguments': args}) + '\n')
        self.f.flush()
        while True:
            msg = json.loads(self.f.readline())
            if 'return' in msg:
                return msg['return']
            if 'error' in msg:
                raise SystemExit('QMP %s: %s' % (cmd, msg['error'].get('desc')))


def keys(q, names):
    parts = [{'type': 'qcode', 'data': n} for n in names]
    q.call('send-key', keys=parts, **{'hold-time': 80})


def type_text(q, text):
    delay = float(os.environ.get('QMP_TYPE_DELAY', '0.12'))
    for ch in text:
        if ch.isupper():
            names = ['shift', ch.lower()]
        elif ch in SHIFTED:
            names = ['shift', SHIFTED[ch]]
        elif ch in PLAIN:
            names = [PLAIN[ch]]
        else:
            names = [ch]
        keys(q, names)
        time.sleep(delay)


def pointer(q, x, y, w, h, click):
    ax = int(x * 32767 / max(w - 1, 1))
    ay = int(y * 32767 / max(h - 1, 1))
    q.call('input-send-event', events=[{'type': 'abs', 'data': {'axis': 'x', 'value': ax}},
                                       {'type': 'abs', 'data': {'axis': 'y', 'value': ay}}])
    if click:
        time.sleep(0.2)
        q.call('input-send-event', events=[{'type': 'btn', 'data': {'down': True, 'button': 'left'}}])
        time.sleep(0.1)
        q.call('input-send-event', events=[{'type': 'btn', 'data': {'down': False, 'button': 'left'}}])


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    q, cmd, rest = Qmp(argv[1]), argv[2], argv[3:]
    if cmd == 'shot':
        q.call('screendump', filename=os.path.abspath(rest[0]), format='png')
    elif cmd == 'key':
        for combo in rest:
            keys(q, combo.split('+'))
            time.sleep(0.15)
    elif cmd == 'type':
        type_text(q, rest[0])
    elif cmd in ('click', 'move'):
        x, y = int(rest[0]), int(rest[1])
        w, h = (int(rest[2]), int(rest[3])) if len(rest) >= 4 else (1280, 800)
        pointer(q, x, y, w, h, cmd == 'click')
    elif cmd == 'status':
        print(q.call('query-status')['status'])
    elif cmd == 'quit':
        q.call('quit')
    else:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
```

© Companion Intelligence, Lifescope Inc
