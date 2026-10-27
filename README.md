<h1 align="center">Companion OS</h1>

<p align="center"><strong>The Companion Intelligence appliance operating system, for Ubuntu 26.04 LTS and CachyOS</strong></p>

<p align="center"><a href="#documentation">Documentation</a> · <a href="#install">Get started</a></p>

![Companion OS logo](assets/logos/2024_CI__LogoMark_Color_med.svg)

**© Companion Intelligence, Lifescope Inc**  
Companion OS uses the [PolyForm Noncommercial License 1.0.0](LICENSE.md). See the [License FAQ](License-FAQ.md).

---

## What Companion OS is

1. Companion OS is the operating system of the Companion Intelligence appliance: a private, local-first AI memory box that runs on an ordinary x86-64 PC (the Ubuntu edition also builds for arm64, see [`docs/architecture/arm64.md`](docs/architecture/arm64.md)).
2. It comes in two editions, both live-and-installer ISOs: one on **Ubuntu 26.04.1 LTS** (GNOME) and a **Plasma edition based on CachyOS**.
3. A first-boot step provisions Docker, Ollama with three local models, CI Hub and the network tools. A machine with no screen is reached through a Wi-Fi setup hotspot.
4. The **Companion Stick** (`ci-stick`) turns a USB stick into a bootable, verifiable carrier for the Ubuntu edition, its installers and its model packs.
5. This repository builds, themes, provisions and verifies all of it. No image is published yet, so you build one, and no run on real hardware is recorded.

Evidence tags used in this page: **[V]** verified (executed, result recorded), **[I]** implemented, not proven end to end, **[N]** not implemented.
The support policy and the full capability matrix are in [`docs/architecture/supported-targets.md`](docs/architecture/supported-targets.md).

## Contents

1. [The two editions side by side](#the-two-editions-side-by-side)
2. [Get an ISO](#get-an-iso)
3. [Flash the USB installer](#flash-the-usb-installer)
4. [Make a Companion Stick](#make-a-companion-stick)
5. [Install](#install)
6. [First boot and hotspot setup](#first-boot-and-hotspot-setup)
7. [Models and model packs](#models-and-model-packs)
8. [Work on an existing machine (Ubuntu)](#work-on-an-existing-machine-ubuntu)
9. [Test suite](#test-suite)
10. [Repo layout](#repo-layout)
11. [Status and evidence](#status-and-evidence)
12. [Documentation](#documentation)

---

## The two editions side by side

| | Ubuntu edition | Plasma edition (CachyOS base) |
|---|---|---|
| Base | The stock Ubuntu 26.04.1 LTS Desktop ISO, repacked. GNOME 50, one Wayland session. | The pinned CachyOS-Live-ISO profile (archiso) plus a Companion overlay. KDE Plasma 6. |
| Backend | `backends/ubuntu/` | `backends/cachyos/` (runs `backends/arch/` on first boot) |
| Image | `companion-os-<version>-amd64.iso`, 7,076,577,280 bytes in both full builds **[V]**; `-arm64.iso` for arm64 (supported since 2026-10-19, [`arm64.md`](docs/architecture/arm64.md)) | `companion-os-plasma-<YYYY.MM.DD>-x86_64.iso`, 3,217,129,472 bytes **[V]** |
| Build host | Ubuntu 26.04 as root; a privileged container on a Mac | Any host with Docker |
| Package source | Ubuntu archive at build time, vendor apt repositories with pinned keys | CachyOS and Arch repositories, rolling, on build day and again on install day |
| Installer | Canonical's installer, plus "Install Companion OS (automatic)" | Calamares, online only |
| One-click install | Yes: **[V]** on the arm64 image in a virtual machine (dialog, install in 12 min 10 s, power-off, installed boot); **[I]** on amd64 (207 unit tests, not driven on a booted ISO) | No **[N]** |
| Companion Stick boot | Yes. The stock 26.04.1 ISO boots from a stick under Secure Boot to early systemd **[V]**; a Companion image on a stick **[I]** | No **[N]**: the stick's boot menu is built for casper |
| Secure Boot | Inherited from the base ISO **[I]** | No **[N]**: unsigned GRUB and kernels |
| Hotspot setup | `setup-device` package, installed system **[I]** | Payload staged by the installer **[I]** |
| Models | Ollama baked in; models pulled at first boot **[I]** | Ollama installed by the installer; three models pulled at first boot **[V]** |
| Docker | Baked in, also in live sessions **[I]** | Installed system **[V]**; not on the live medium |
| GPU, ROCm | ROCm from the Ubuntu archive and Strix Halo boot parameters, Strix Halo class only **[I]** | Vulkan Ollama; ROCm only on request **[I]**; no boot parameters **[N]** |
| Status | amd64: built from a clean checkout and statically verified (446 checks on `4b7597d`) **[V]**; its live session booted under emulation to the desktop, without desktop icons **[V]**; install and first boot of the amd64 image pending. arm64 (a supported architecture since 2026-10-19): built, verified (438), live desktop, one-click install, installed boot, first sign-in, first boot and Hub pairing screen all ran in a virtual machine **[V]** | Live boot, install, installed boot and first boot ran end to end in QEMU three times (ISO #4, #5, #6) **[V]**; ISO #6 (`ad37b64`) installed on its first attempt with the keyring-step fix working, passed `verify-iso.sh` (215 passed, 0 failed) and ended first boot clean **[V]**. Virtual machine only, one run of the fix; open: highlight gaps, a CachyOS name in raw pacman output, the splash wording |

![The boot menu of the Ubuntu edition's arm64 live medium: the Companion mark on a dark teal screen and four entries, Try or Install Companion OS highlighted.](docs/ui/companion-os/ubuntu/arm64-01-live-grub-menu.png)

*Ubuntu edition (arm64 image): the boot menu of the live medium, captured in a virtual machine with hardware acceleration (not real hardware).*

![The Ubuntu edition's live desktop: the dock on the left, five Companion shortcuts and two Install Companion OS launchers on the right, on the Companion wallpaper.](docs/ui/companion-os/ubuntu/arm64-03-live-desktop.png)

*Ubuntu edition (arm64 image): the live desktop, about two minutes after power-on. All frames of the run: [`docs/ui/companion-os/ubuntu/`](docs/ui/companion-os/ubuntu/CAPTURE.md).*
![Boot menu on a navy background with the Companion mark and six entries; Companion OS (Plasma) is highlighted.](docs/ui/companion-os/plasma/01-live-grub-boot-menu.png)

*Plasma edition: the boot menu of the live medium, captured in a virtual machine (QEMU, software emulation; not real hardware).*

![The Plasma live desktop with a teal wallpaper and a panel along the bottom with app icons, tray and clock; no windows open.](docs/ui/companion-os/plasma/02-live-desktop.png)

*Plasma edition: the settled live desktop, signed in as liveuser, captured in a virtual machine. All frames of the run, with the capture record, are in [`docs/ui/companion-os/plasma/`](docs/ui/companion-os/plasma/CAPTURE.md).*

Caveats that apply to both: the shared setup portal is a stop-gap that needs a human security review; credentials found by the
2026-10-12 review are still to be rotated; model pulls have no disk-space guard. See
[`docs/architecture/known-issues-and-decisions.md`](docs/architecture/known-issues-and-decisions.md).

---

## Get an ISO

Neither edition has public hosting or a signing key holder yet **[N]**, so you build the image from this repository.

### Ubuntu edition

Needs Ubuntu 26.04 (resolute) with the Yaru theme installed, root, about 35 GB free and network access. `build-iso.sh` stops on any
other host. It repacks the stock Ubuntu 26.04.1 Desktop ISO: take the `.1` file, not the 26.04.0 image listed next to it.

```bash
sudo apt-get install squashfs-tools xorriso libglib2.0-bin libglib2.0-dev-bin yaru-theme-gnome-shell \
  rsync gpg cpio zstd initramfs-tools-core imagemagick librsvg2-bin curl

wget https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso
echo '601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f  ubuntu-26.04.1-desktop-amd64.iso' | sha256sum -c -

sudo ./backends/ubuntu/iso/scripts/build-iso.sh --base-iso ./ubuntu-26.04.1-desktop-amd64.iso
```

Output: `./output/companion-os-1.0-amd64.iso`, `SHA256SUMS`, `MD5SUMS`. Common flags: `--output-dir`, `--work-dir` (about 25 GB),
`--version`, `--skip-packages`, `--clean`, `--sign`. The full reference, the branding colour map and the iterative-development tips are
in [`backends/ubuntu/iso/README.md`](backends/ubuntu/iso/README.md) and the
[ISO build guide](docs/guides/iso-build-guide.md).

**On a Mac or any host that is not Ubuntu 26.04**, build inside a privileged container. On Apple silicon use an **ARM64**
`ubuntu:26.04` container: it is the route that produced the verified image, and the image's x86-64 chroot runs through the Docker VM's
Rosetta binfmt handlers. An amd64 `ubuntu:26.04` container may fail (GNU tar 1.35 reported "Function not implemented" under Rosetta once; the
trigger was not isolated), so it is not the recommended route. On an x86-64 Linux host drop `--platform linux/arm64`.

```bash
export ISO="$HOME/Downloads/ubuntu-26.04.1-desktop-amd64.iso"        # the 26.04.1 file, not the 26.04.0 image
export BUILD="$HOME/ci-os-build-tree"
echo '601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f  '"$ISO" | shasum -a 256 -c -
rm -rf "$BUILD" && mkdir -p "$BUILD" && git archive HEAD | tar -x -C "$BUILD"      # a clean tree of the commit you want to build
docker volume create ci-os-ubuild-vol
docker run -d --name ci-os-ubuild --privileged --platform linux/arm64 -v ci-os-ubuild-vol:/vol -v "$BUILD":/src:ro \
  -v "$ISO":/base/ubuntu-base.iso:ro -w /vol -e DEBIAN_FRONTEND=noninteractive ubuntu:26.04 sleep infinity
docker exec ci-os-ubuild bash -euc 'for i in $(seq 0 127); do [ -e /dev/loop$i ] || mknod -m 0660 /dev/loop$i b 7 $i; done; [ -e /dev/loop-control ] || mknod -m 0660 /dev/loop-control c 10 237'
docker exec ci-os-ubuild bash -euo pipefail -c 'apt-get update -qq && apt-get install -y -qq ca-certificates squashfs-tools xorriso rsync gpg curl cpio zstd initramfs-tools-core imagemagick librsvg2-bin libglib2.0-bin libglib2.0-dev-bin yaru-theme-gnome-shell python3 python3-yaml diffutils mount util-linux file'
docker exec ci-os-ubuild bash -euc 'mkdir -p /vol/repo /vol/work /vol/out /vol/cache && rsync -a --delete /src/ /vol/repo/'
caffeinate -i docker exec -e CI_OS_CACHE_DIR=/vol/cache -w /vol/repo ci-os-ubuild ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso /base/ubuntu-base.iso --output-dir /vol/out --work-dir /vol/work --version 1.0 --clean 2>&1 | tee build.log
docker exec -e VERIFY_BASE_ISO=/base/ubuntu-base.iso -e VERIFY_REQUIRE_CANON=1 -w /vol/repo ci-os-ubuild ./backends/ubuntu/iso/scripts/verify-iso.sh /vol/out/companion-os-1.0-amd64.iso
mkdir -p output && docker cp ci-os-ubuild:/vol/out/. ./output/
docker rm -f ci-os-ubuild && docker volume rm ci-os-ubuild-vol
```

The same commands as one script: `backends/ubuntu/iso/scripts/build-in-docker.sh --base-iso "$ISO"` (add `--arch amd64` and the amd64 ISO for the x86-64 image; it refuses a dirty tree and an unpinned base ISO). The commands, with the reasons for each step, are in [`docs/guides/building-on-a-mac.md`](docs/guides/building-on-a-mac.md#recipe);
`CLAUDE.md` carries the same block, and the three are changed together. Never run systemd as PID 1 in that container, in any privileged
container or with `CAP_SYS_ADMIN` (a privileged one wipes the Docker VM's Rosetta registrations, and the capability alone lets a container
mount the shared `binfmt_misc` itself; restart Docker Desktop to recover; the reference implementation of a test that must boot systemd is
`backends/ubuntu/chroot/tests/first-boot-units-boot.sh`), and keep more than 40 GiB free on the Data volume.
[`.github/workflows/build-companion-os-iso.yml`](.github/workflows/build-companion-os-iso.yml) does the same in CI, in a privileged
`ubuntu:26.04` container, and is manual-only. **Publishing:** images go to Cloudflare R2 (the shared `dl-dev` and `dl-prod` buckets, served from
`dl-dev.ci.computer` and `dl.ci.computer`), not to GitHub releases (an asset is limited to 2 GiB, an image is 5.6 GB):
`backends/ubuntu/iso/scripts/publish-r2.sh` (a dry run until `--apply`), `verify-published.sh` and the workflow's `publish` input are **[I]**,
tested against stubs and never run against the real buckets; [Publishing to R2](docs/guides/release-checklist.md#publishing-to-r2) has the layout and the steps left for the owner. Nothing has been published.

### Plasma edition (CachyOS base)

Needs Docker, bash 3.2 or newer, network, and about 25 GiB free in the Docker VM plus about 3 GB for the output.

```bash
backends/cachyos/iso/scripts/build-iso.sh --version 1.0
```

Output in `output/`: `companion-os-plasma-<YYYY.MM.DD>-x86_64.iso`, `.iso.sha256`, `.pkgs.txt` (the package list), `.build-info`
(pins, hashes, whether the tree was clean) and `.build.log`. The build packs the **working tree**, not a commit; add
`--require-clean` for a release. Flags and pins: [`backends/cachyos/README.md`](backends/cachyos/README.md).

### Verify an image

```bash
# Ubuntu: no root needed to read an image (xorriso, squashfs-tools, zstd, cpio, python3)
VERIFY_BASE_ISO=./ubuntu-26.04.1-desktop-amd64.iso backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-*.iso

# Plasma: in the builder image, the ISO mounted read-only
IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' ci-os-cachyos-builder | head -n 1)"
docker run --rm --platform linux/amd64 --cpus 4 --memory 8g -v "$PWD:/repo:ro" -v "$PWD/output:/iso:ro" "$IMAGE" bash -c '
  VERIFY_FETCH_UPSTREAM=1 /repo/backends/cachyos/iso/scripts/verify-iso.sh "$(ls /iso/companion-os-plasma-*-x86_64.iso | head -n 1)"'
```

### Measured so far

| | Ubuntu 26.04.1 | Plasma |
|---|---|---|
| Build time | **772 s** (12 min 52 s) from a clean checkout at `02c575e`; 860 s for the earlier build of a worktree snapshot during the fix pass. Both had every optional bake on and ran in a privileged ARM64 `ubuntu:26.04` container on an Apple-silicon Mac | 25 to 26 minutes under Rosetta on a lightly loaded Mac (ISO #4 26 min, ISO #5 25 min, ISO #6 about 26 min); 31 to 37 minutes on a loaded one; upstream's own CI needs about 18 minutes on a native runner |
| Image size | 7,076,577,280 bytes (6.59 GiB); the Stick slot of a 64 GB stick is 8 GiB and `verify-iso.sh` fails above it | 3,217,129,472 bytes (3.0 GiB) |
| Static verification | 393 passed, 0 failed, 0 skipped in 34 s, on the clean-checkout image **[V]** | **215 passed, 0 failed on ISO #6** (84 s) **[V]**, log in [`docs/evidence/2026-10-18-plasma-iso6/`](docs/evidence/2026-10-18-plasma-iso6/verify.log); 187 passed on ISO #2; no log of ISO #4 or #5 was kept |
| Still to measure | A boot of the clean-checkout image (test-evidence U2 to U11) | A second install run (the keyring result is one run), the Secure Boot variant of the firmware, any real hardware |

The records of the 772 s build (build record, exit status, verifier log) and of the 860 s build's boot and verify are in
[`docs/evidence/`](docs/evidence/README.md); the transcript of the 860 s build is not in the repository. The Plasma ISO #6 records
(build record, verifier log, job timeline) are in `docs/evidence/2026-10-18-plasma-iso6/`; the earlier Plasma times are from
`docs/architecture/cachyos-backend.md`.

---

### Measured ISO sizes

These are the image sizes recorded in the table above. The Ubuntu image is close to the 8 GiB Stick slot limit; verify-iso.sh enforces that limit.

```mermaid
xychart-beta
    title "Recorded ISO size (GiB)"
    x-axis ["Ubuntu 26.04.1", "Plasma"]
    y-axis "GiB" 0 --> 8
    bar [6.59, 3.0]
```


## Flash the USB installer

Every Companion OS image is a hybrid ISO: write it byte for byte to a USB stick and a UEFI machine boots the stick. Nothing is
extracted or "burned", and **writing erases the whole stick**. The same file also boots as a virtual machine's USB drive, which is how the
screenshots below were taken ([Test suite](#test-suite)).

**Evidence.** The ISO attached to a QEMU machine as a USB mass-storage drive (what a flashed stick looks like to the firmware) booted,
installed and ran first boot on the arm64 image, 2026-10-19 **[V]**. The write and verify commands below were rehearsed on regular files
and on no device **[V for the commands, N for a physical stick]**. No Companion OS image has been written to a physical stick in this repository yet **[N]**.

### 1. Pick the image and the stick

| You have | Write this file | With | Notes |
|---|---|---|---|
| An x86-64 PC, Ubuntu edition | `companion-os-<version>-amd64.iso` (6.6 GiB) | `dd`, Rufus (DD Image mode), balenaEtcher, or `ci-stick flash` for the A/B stick | Boots with Secure Boot on: the chain is Canonical's, inherited from the base ISO **[I]** |
| An arm64 PC or VM, Ubuntu edition | `companion-os-<version>-arm64.iso` (5.2 GiB) | `dd`, Rufus, balenaEtcher. `ci-stick` does not take it **[N]** | No Companion Capture on arm64. An Apple-silicon Mac cannot boot a USB stick into it: use the VM recipe in the [Test suite](#test-suite) |
| An x86-64 PC, Plasma edition | `companion-os-plasma-<YYYY.MM.DD>-x86_64.iso` (3.0 GiB) | `dd`, Rufus, balenaEtcher | **Secure Boot must be off** |

Use a stick larger than the file; 16 GB or more is comfortable and 8 GB is the least that holds the amd64 image. The install target needs at
least 25 GB (the one-click installer refuses a smaller disk, a removable disk and the boot medium); give a machine that will also pull the
models 64 GB or more.

### 2. Check the file

Each build writes `SHA256SUMS` next to the ISO. Run this in the folder that holds both:

```bash
sha256sum -c SHA256SUMS         # Linux
shasum -a 256 -c SHA256SUMS     # macOS
```

On Windows PowerShell, `Get-FileHash .\companion-os-1.0-amd64.iso -Algorithm SHA256` prints the hash to compare with the file. For the full
verifier of an image (444 checks on amd64, 436 on arm64) see [Verify an image](#verify-an-image).

### 3. Find the stick, and be sure it is the stick

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINTS   # Linux: the stick has TRAN=usb, RM=1 and the size you expect, and nothing of yours mounted
diskutil list external physical                # macOS: the stick is the external, physical disk of the right size
```

Unplug the stick, run the command, plug it in and run it again: the line that appears is the stick. You write to the **whole device**
(`/dev/sdX`, `/dev/diskN`), never to a partition (`/dev/sdX1`). Anything that holds `/`, your home folder or a mounted volume you care about is
not the stick. `dd` has no safety net: it writes to what you name. `ci-stick flash` refuses the system disk and anything mounted; no other
tool here does.

### 4. Write it

```bash
# Linux
ISO=companion-os-1.0-amd64.iso               # or the arm64 or Plasma file
DEV=/dev/sdX                                 # the whole device from step 3
sudo umount "$DEV"?* 2>/dev/null || true
sudo dd if="$ISO" of="$DEV" bs=4M conv=fsync oflag=direct status=progress
sync
```

```bash
# macOS
ISO=companion-os-1.0-amd64.iso
N=4                                          # the disk number from step 3
diskutil unmountDisk /dev/disk$N
sudo dd if="$ISO" of=/dev/rdisk$N bs=4m      # press Control-T to see progress; there is no status=progress
diskutil eject /dev/disk$N
```

On Windows use [Rufus](https://rufus.ie) and pick **DD Image** mode when it asks, or [balenaEtcher](https://etcher.balena.io); neither was tried
for this repository **[N]**. The write takes a few minutes: it is limited by the stick, not by the machine.

### 5. Check the write

A stick that fails halfway can still look fine. Read back exactly as many bytes as the ISO has and compare the hashes:

```bash
# Linux
SZ=$(wc -c < "$ISO"); want=$(sha256sum "$ISO" | cut -c1-64)
got=$(sudo dd if="$DEV" bs=1M count=$(( (SZ + 1048575) / 1048576 )) 2>/dev/null | head -c "$SZ" | sha256sum | cut -c1-64)
[ "$want" = "$got" ] && echo "the stick matches the ISO" || echo "MISMATCH: write it again, or try another stick or port"
```

```bash
# macOS
SZ=$(wc -c < "$ISO" | tr -d ' '); want=$(shasum -a 256 "$ISO" | cut -c1-64)
got=$(sudo dd if=/dev/rdisk$N bs=1m count=$(( (SZ + 1048575) / 1048576 )) 2>/dev/null | head -c "$SZ" | shasum -a 256 | cut -c1-64)
[ "$want" = "$got" ] && echo "the stick matches the ISO" || echo "MISMATCH: write it again, or try another stick or port"
```

(Do not use `cmp -n "$SZ"` on macOS: its `-n` stops one byte late and reports an end-of-file difference even when the two are identical.
The hash form above was run against a file standing in for a stick, once matching and once with one byte flipped **[V]**.)

### 6. Boot it and install

1. Plug the stick into the target machine, power on and open the firmware's boot menu (usually Esc, F2, F10, F12 or Del) and pick the stick's
   **UEFI** entry. A "legacy" or "CSM" entry will not boot it. Secure Boot may stay on for the Ubuntu images (the chain is Canonical's; a boot under Secure Boot firmware has not been done **[I]**), and must be off for Plasma. If the firmware refuses the stick, turn Secure Boot off.
2. The boot menu has two entries: **Try or Install Companion OS** (the default, after 15 seconds) and **Install Companion OS (automatic)**.
   On arm64 the screen shows kernel messages while the live system starts, and the desktop takes about two minutes under a virtual machine
   with hardware acceleration.
3. On the live desktop the left dock starts with **Install Companion OS (automatic)**. The five Companion shortcuts (Support, Getting
   Started, Docs, Community, App Store) are on the desktop. Canonical's installer window no longer opens by itself (**[I]**: the link that started
   it is removed from the image, not yet seen on a booted one); it is one click away in the application grid (**Install Companion OS**) and behind
   **Use the normal installer** in the dialog.
4. **One dialog** names the disk it will erase (model, size, device node, and everything found on it), shows a one-time password for the
   user `companion`, says which language, keyboard and time zone it will use (a button changes them) and defaults to **Cancel**. After "Erase the disk and install" a progress window follows the installer; the computer turns itself off when it is done.
   Remove the stick, then turn the machine on. Safety rules: [`docs/architecture/one-click-install.md`](docs/architecture/one-click-install.md).
5. First sign-in: the one-time password, then a forced new one. A Companion welcome page opens once in the browser. About three minutes after
   boot a first-boot job waits for a quiet machine and then pulls the models and starts Companion Hub (`http://localhost:5002`, which leads to
   device registration: pairing is a person's step).

![The boot menu of the arm64 live medium: a navy screen with the Companion mark and four entries, the first highlighted.](docs/ui/companion-os/ubuntu/arm64-01-live-grub-menu.png)

*The boot menu of the arm64 image, from a virtual machine started with the ISO attached as a USB drive.*

![The live desktop: the Companion dock on the left, five Companion shortcuts and the Install Companion OS launchers on the right, on the Companion wallpaper.](docs/ui/companion-os/ubuntu/arm64-03-live-desktop.png)

*The live desktop, about two minutes after power-on. The shortcuts show their own icons and names. All ten frames, with the run's times, are in [`docs/ui/companion-os/ubuntu/`](docs/ui/companion-os/ubuntu/CAPTURE.md).*

![The one-click installer's confirmation: it names the disk to be erased and offers Cancel, Erase the disk and install, or the normal installer.](docs/ui/companion-os/ubuntu/arm64-04-one-click-confirmation.png)

*The one-click installer's only dialog. The one-time password is hidden in this capture; the disk is a file-backed virtual NVMe drive.*

![The sign-in screen asking for the current password, with the line Changing password for companion.](docs/ui/companion-os/ubuntu/arm64-07-forced-password-change.png)

*First sign-in: the one-time password, then a forced new one.*

![The installed desktop: the dock holds Companion Hub, Docs, Files and Terminal, and the five Companion shortcuts are on the desktop.](docs/ui/companion-os/ubuntu/arm64-09-installed-desktop.png)

*The installed desktop. No first-run page from Canonical appears; the Companion getting-started page opens once in the browser instead.*

![Companion Hub on its first screen: Step 1, get your pairing code, and Step 2, connect this device, with the device ID and a pairing-code field.](docs/ui/companion-os/ubuntu/arm64-10-hub-pairing.png)

*Companion Hub, started by the first-boot job, on its pairing screen. Pairing is a person's step.*

If the stick is not offered by the firmware: write it again (steps 4 and 5), try another port, and check that the machine boots UEFI. If the
one-click dialog says no disk qualifies, the machine has no internal disk of 25 GB or more besides the stick. A stick can also carry the
**Companion Stick** layout (A/B boot slots, persistence, model packs) instead of a plain image: that is the next section, and it takes the amd64 Ubuntu image only.

---

## Make a Companion Stick

`ci-stick` (Rust, `stick/`) builds and verifies a signed bundle, plans the partition layout, flashes a stick or a sparse stick image
(Ubuntu x86_64 layout, A/B boot slots, persistence) and manages model packs. A stick boots the **Ubuntu** edition through the
signed chain shim, Canonical GRUB, Canonical kernel. It cannot boot the Plasma edition **[N]**. Rust 1.75 or newer is needed.

```bash
(cd stick && cargo build --release) && export PATH="$PWD/stick/target/release:$PATH"
ci-stick layout plan --size 64GB             # 1 GiB EFI, 4 GiB shared, 8 GiB slots A and B, 30 GiB cache, ~8.6 GiB persistence
ci-stick models list                         # the model-pack catalog (core/manifest/model-packs.yaml)

# Stage: boot/ is the ISO, efi/ the signed boot chain (installers/, oci/, models/, docs/, tools/ are optional)
mkdir -p staging/boot staging/efi && cp output/companion-os-1.0-amd64.iso staging/boot/
stick/scripts/fetch-signed-boot.sh ./signed-boot                  # shim, Canonical GRUB, MokManager from the resolute archive (needs apt on Ubuntu 26.04)
cp ./signed-boot/{shimx64,grubx64,mmx64}.efi staging/efi/
ci-stick lock ./staging --id companion-stick-ubuntu --version 2026.10.0 --size 64GB --packs core/manifest/model-packs.yaml
ci-stick dev keygen --out ./dev && ci-stick dev sign ./staging --key ./dev.key     # development key; release bundles are signed by the release pipeline
ci-stick verify ./staging --pubkey ./dev.pub

# Flash: ALWAYS a dry run first. --device ERASES the whole device.
ci-stick flash ./staging --pubkey ./dev.pub --image stick.img --size 64GB --dry-run
sudo ci-stick flash ./staging --pubkey ./dev.pub --device /dev/disk/by-id/usb-XYZ --dry-run

# Slots: A/B pointer in ci-stick/grubenv on the EFI volume
ci-stick slot show --image stick.img
ci-stick slot set B --image stick.img
```

Without Secure Boot (development only), `stick/scripts/build-grub-efi.sh` builds an unsigned GRUB instead of the signed chain.
`ci-stick flash` writes only to removable or USB disks with nothing mounted, refuses the system disk and re-checks the device's
identity before the first write; you are still the last check. Device writes are Linux-only. Evidence: `stick/tests/qemu/run.sh`
(17 PASS lines: three boots, persistence, slot B, a tampered bundle, device-safety refusals) and the Secure Boot A, B, C run
(`stick/tests/secureboot/run-on-mac.sh`, 8 checks) pass **[V]**; no write to physical media has been exercised **[N]**. Full
usage and exit codes: [`stick/README.md`](stick/README.md). Architecture and trust model:
[`docs/architecture/companion-stick.md`](docs/architecture/companion-stick.md).

---

## Install

Both ISOs are hybrid images: write one to a USB stick ([Flash the USB installer](#flash-the-usb-installer): `dd`, an imaging tool, or `ci-stick`
for the amd64 Ubuntu image) or attach it to a virtual machine, and boot it. The Plasma edition needs Secure Boot off.

### Ubuntu edition

The GRUB menu has two entries: **Try or Install Companion OS** and **Install Companion OS (automatic)**.

* **One-click.** Pick the automatic entry, or click "Install Companion OS (automatic)" on the live desktop. One dialog names the target
  disk (model, size, device node and everything found on it) and the disks it will leave alone, and shows a one-time password for the
  user `companion`. Enter never confirms; the default is **Cancel**. After the click a progress window follows the installer, the
  computer turns off when it is done, and the first sign-in forces a new password. The tool never offers the boot medium, a removable
  disk or one under 25 GB. Safety rules, state machine and tests: [`docs/architecture/one-click-install.md`](docs/architecture/one-click-install.md).
  Status: **[V]** on the arm64 image in a virtual machine (the frames are in [Flash the USB installer](#flash-the-usb-installer)); **[I]** on amd64: unit-tested, not yet driven on a booted image.
* **Interactive.** Pick the first entry, then start Canonical's installer from the application grid (**Install Companion OS**) or press **Use the normal
  installer** in the automatic dialog. Its window keeps Ubuntu's own text and its 13 pages (it is a Canonical snap, which a remaster cannot change); the
  launcher label and the last page read "Companion OS".

### Plasma edition

1. Boot **Companion OS (Plasma)**. On a software-emulated VM the desktop takes 4 to 5 minutes to its first frame on a quiet host and 5 to 7 on a busy one (ISO #6: 5 min 08 s to the first frame, 6 min 38 s settled) **[V]**.
2. Open the application menu and start **Install Companion OS**. The launcher first makes sure the pacman keyring works, checks the
   installer package against its guards, applies the Companion overlay and runs a package preflight (about 3 minutes **[V]**), then
   opens Calamares. The install is **online only**: it needs a working internet connection.
3. Calamares pages: Welcome, Location, Keyboard, Bootloader (GRUB only), Partitions, Packages, Users, Summary, Install, Finish.
4. The install took 22 min 9 s for 47 jobs on a 30 GiB virtual NVMe in QEMU (ISO #4), 23 min 20 s on a 64 GiB one (ISO #5) and 28 min 26 s on a 64 GiB one
   (ISO #6) **[V]**. On ISO #5 two of three attempts died at 2 percent with "create-pacman-keyring failed to finish in 30 seconds" on the slow emulated
   host. Commit `ad37b64` gives that step an explicit time limit, and ISO #6 passed it (32 seconds) on its first attempt, in one run **[V]**; on an older ISO,
   if you see that dialog, close it and start the installer again (KI-20). Restart, remove the medium.

![Welcome page of the Companion OS 1.0 installer with the page list on the left and American English chosen.](docs/ui/companion-os/plasma/07-live-calamares-welcome.png)

*Plasma edition: the first page of the installer, started from the live session, captured in a virtual machine.*

The one-click dialog and the installed system are pictured in [Flash the USB installer](#flash-the-usb-installer).

Disk size: the installed system takes about 7.9 GiB and the model set adds about 18.8 GB (a 30 GiB disk ended 88 % full). Give the
Plasma edition 64 GiB or more. Step-by-step instructions, recovery and troubleshooting:
[`docs/guides/installation-guide.md`](docs/guides/installation-guide.md).

---

## First boot and hotspot setup

**First boot.** A systemd unit runs the provisioner on the installed system until it has succeeded once, at every boot and every
15 minutes while pending (an offline first boot just waits for the network), with at most three failed automatic runs.

| | Ubuntu | Plasma |
|---|---|---|
| Units | `ci-os-first-boot-rebrand.service`, `ci-os-first-boot-setup.service` and its timer | `ci-os-first-boot-setup.service` and its timer (`Type=exec`, so the boot targets do not wait for it) |
| Runs | `backends/ubuntu/provision/provision.sh --tier=core` | the wrapper `backends/cachyos/provision/provision.sh`, which runs `backends/arch/provision/provision.sh --tier=core` |
| Result | a marker file on success | `/var/lib/ci-os/first-boot-setup-status`; a missing model is "degraded" (exit 74) and is retried |
| Re-run | `sudo ci-os-setup` | `sudo ci-os-setup` (add `--tier=core,hardware` for ROCm and LACT) |

The `extended` tier (VS Code, Chromium, Homebrew, Companion Launcher) is never run at first boot. The Plasma first boot with a
network took 16 min 4.6 s to pull the three models in the ISO #4 run, and ended "degraded" because of a defect (`ollama list` ran
without `$HOME`). Commit `552063f` fixes it, and on ISO #5 the same step took 21 min 49 s, ended with status 0, wrote its marker and
reported no "degraded" **[V]**; ISO #6 did the same in 21 min 19 s (exit 0, marker, all three models, a 301-line log) **[V]**.

**Hotspot (headless setup).** A device with no screen reaches your Wi-Fi through a captive portal. When both Ethernet and Wi-Fi are
down, `setup-network-monitor.service` starts an access point named `Companion-Setup-XXXX` (the suffix is random per start). Connect,
open `http://192.168.99.1` (or `http://setup.ci.computer`), choose a network, enter its password and the pairing code, and the
device joins your network and stops the hotspot.

| Item | Value |
|---|---|
| Gateway, DHCP range | 192.168.99.1, 192.168.99.10 to 192.168.99.250 |
| Pairing code | `/etc/setup-device/pairing_code.json` (root only; the backend creates it on its first request) |
| AP passphrase | the shared default in `core/headless/payload/hostapd/hostapd-setup.conf` (a known weakness) |
| Key paths | backend `/opt/setup-backend/setup_service.py`, portal `/var/www/setup-portal/`, state in `/var/lib/setup-device/` |
| Start it again | the monitor starts the hotspot whenever there is no connectivity: take the network down (`sudo nmcli connection down --active`) and wait; it checks about every 3 s and acts after two failed checks past a 45 s grace |
| Build the Ubuntu package alone | `cd backends/ubuntu/headless-package && ./build.sh && sudo dpkg -i setup-device_*.deb` |

The portal API has no local authentication (audit findings S1 and S2), and the access point uses a shared passphrase. The stop-gap
fixes landed in `b882e00`; a human security review is required, and a tested replacement library (`core/headless/ci_setup/`) exists
but is not wired into any service. Details, the 51-defect audit and the threat model:
[`docs/architecture/headless-setup.md`](docs/architecture/headless-setup.md). Status **[I]**: the units are present on the
installed Plasma system **[V]**, but no access point has been brought up on a real radio **[N]**.

<table>
<tr>
<td align="center"><img src="docs/ui/setup-portal-dark.png" alt="Setup portal: first-boot pairing form" width="200"><br>First-boot form</td>
<td align="center"><img src="docs/ui/setup-portal-networks-dark.png" alt="Setup portal: scanned networks" width="200"><br>Network scan</td>
<td align="center"><img src="docs/ui/setup-portal-manual-dark.png" alt="Setup portal: manual network entry" width="200"><br>Manual entry</td>
</tr>
<tr>
<td align="center"><img src="docs/ui/setup-portal-nopairing-dark.png" alt="Setup portal: pairing not required" width="200"><br>No-pairing variant</td>
<td align="center"><img src="docs/ui/setup-portal-success-dark.png" alt="Setup portal: success" width="200"><br>Success</td>
<td align="center"><img src="docs/ui/setup-portal-error-dark.png" alt="Setup portal: error" width="200"><br>Error</td>
</tr>
</table>

The portal is a single-theme (dark) captive page built on the Companion Intelligence design tokens and the self-hosted Manrope font
(`vendor/brand/`). The screens were rendered offline from `core/headless/payload/var/www/setup-portal/` with Playwright at phone width,
the backend responses stubbed only to trigger the portal's own render paths; nothing is hand-drawn.

### What a printed QR code may carry

No sticker ships today. A QR printed on an appliance cannot rotate and cannot expire: whatever is in the ink stays valid for the life of
the box, on every unit of the run, readable by anyone who sees the case.

* **It may carry** a non-secret per-unit serial and a Portal claim URL for that serial (`https://portal.companionintelligence.com/...`).
* **It must not carry** a long-lived key, token or device secret; Wi-Fi credentials (the setup hotspot passphrase is a shared default,
  and printing it would make that default physically permanent for the whole fleet); anything still valid after the first claim.
* **Do not ship a hotspot QR until the SSID is per-device.** `device.conf` reserves `SERIAL_SUFFIX` for this and nothing reads it
  yet; the live SSID suffix is random on every start, so no label can name the network it should join.
* **Always print the URL in readable text beside the code**, on a domain the user can verify by eye. A QR is opaque, and a sticker
  placed over ours redirects the scan unnoticed ("quishing"); legible text is what lets a user see the destination is wrong.

Changing the hostapd defaults is a separate product decision with fleet implications and is not made here.

---

## Models and model packs

`core/manifest/ecosystem.yaml` fixes the appliance's model set: `nomic-embed-text`, `gemma3:1b` and `qwen3.6:27b` (the pack
`appliance-core`, 18.8 GB; `qwen3.6:27b` alone is 17.8 GB). The set is pulled at first boot and never baked into an image. The Ubuntu
edition pulls `qwen3.6:27b` only on a Strix Halo class machine, and then the RAM and GPU-memory gate `ci_os_model_gate_allows`
(`core/lib/gpu-detect.sh`) applies on top. The Plasma edition relies on that gate alone, and on an installed system it has no data
(`model-packs.yaml` is not staged), so all three models are pulled on every machine **[N]**. **No guard checks the free disk space
either [N]**; both are tracked as KI-01 in [Known issues and decisions](docs/architecture/known-issues-and-decisions.md).

For sticks and offline use, `ci-stick models` manages a content-addressed Ollama-format cache on the stick's `CI-CACHE` volume. Digests
come from the registry, are written to `core/manifest/model-packs.lock.json` and are never typed by hand:

```bash
ci-stick models list --fits 300GiB                                   # which packs fit a cache of that size
ci-stick models lock                                                 # maintainers: resolve the catalog against the registry (network)
ci-stick models plan --pack stick-128 --cache /Volumes/CI-CACHE      # cost and fit, no network
ci-stick models fetch --pack stick-128 --cache /Volumes/CI-CACHE     # resumable, SHA-256 verified; run again after any interruption
ci-stick models cache-info --cache /Volumes/CI-CACHE
```

On a running Companion OS, `ci-os-models` (`core/lib/ci-os-models.sh`) decides where the cache is, what the consumers need in their
environment (Ollama, Hugging Face tools, llama.cpp), whether the machine can run a model, and, opt-in, when a background prefetch may
run. Design and status: [`docs/architecture/models-tooling.md`](docs/architecture/models-tooling.md),
[`docs/architecture/model-packs-128gb.md`](docs/architecture/model-packs-128gb.md).

---

## Work on an existing machine (Ubuntu)

Without reimaging, the Ubuntu backend's scripts convert a machine you already have. The provisioning, bootstrap and theme scripts are idempotent, so a failed run can simply be run again.

| Goal | Entry point | Run on |
|---|---|---|
| Ship a branded installer ISO | `backends/ubuntu/iso/scripts/build-iso.sh` | An Ubuntu 26.04 build host or container |
| Provision the appliance stack | `sudo backends/ubuntu/provision/provision.sh --tier=core,extended,hardware` | The target, as root |
| One command for a freshly flashed Ubuntu 26.04 | `sudo backends/ubuntu/provision/bootstrap-ci-os.sh --yes` (provision, rebrand, headless package; `--no-headless`, `--no-rebrand`, `--no-reboot`) | The target |
| Re-skin a running GNOME desktop, no packages | `sudo backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh` (`--wizard`, `--only plymouth,dconf`, `--validate`) | The target |
| Build the headless setup package | `backends/ubuntu/headless-package/build.sh` | Anywhere with `dpkg-deb` |

`provision.sh --tier=` takes a comma list of `core`, `extended`, `hardware` (default `core,hardware`). The `hardware` tier acts only on a
Strix Halo class machine (Ryzen AI Max, gfx1151 or Radeon 8060S, at least about 32 GB of RAM): it installs ROCm and LACT from the Ubuntu
26.04 archive and the inbox amdgpu driver, and adds `iommu=pt amdgpu.gttsize=<N> ttm.pages_limit=<M>` to the kernel command line
so the amdgpu driver can address most of system RAM as GPU-visible memory, which is needed for local-LLM/ROCm/Vulkan workloads on
these unified-memory APUs (a reboot is needed; set the BIOS integrated-graphics memory to its smallest option). On a machine that has
AMD's out-of-tree DKMS amdgpu driver it adds `amdttm.pages_limit=<M>` too, because that driver uses its own copy of the memory manager,
which ignores `ttm.pages_limit` (run `backends/ubuntu/lib/strix-halo-boot-params.sh` again after installing or removing that driver).
Anywhere else it changes nothing. The theme
steps run in a fixed order: plymouth, grub, dconf, terminal, wallpaper, session, start-icon, about-logo, os-release, names, motd. Palette and
assets: [`assets/branding/brand-guidelines.md`](assets/branding/brand-guidelines.md). `pull-dev-manual.sh` at the root is a thin
wrapper around `core/lib/ci-hub.sh` for manual CI-Hub deploys: inputs, ports and the security notes are in the
[CI-Hub deploy guide](docs/guides/ci-hub-deploy.md).

On the Plasma edition the first-boot unit provisions the machine; `sudo ci-os-setup` re-runs it.

---

## Test suite

The tests are layered from seconds to hours. Run the cheapest layer that covers your change, and the whole gate before you push.
A suite that needs a tool the host lacks exits 2 and is reported "cannot run here", never as a pass. Which suite to run for which
change is in [Running the tests](docs/guides/running-the-tests.md); the per-suite tables are in
[`backends/ubuntu/iso/README.md`](backends/ubuntu/iso/README.md) ("Script tests") and [`backends/cachyos/README.md`](backends/cachyos/README.md) ("Tests").

| Layer | Command | Needs | Time | What it proves |
|---|---|---|---|---|
| 1. The gate | `./core/lib/check-repo.sh` | `git`, `shellcheck`, `python3` with PyYAML, `yamllint` (macOS: `brew install shellcheck yamllint`; a bare Debian or Ubuntu container also wants `libarchive-tools`, `libglib2.0-bin` and `curl`, or four suites print `!` and do not run) | about 6 minutes on a quiet laptop, 25 to 40 on a Mac that is also running builds and VMs | Syntax and lint of every shell, Python and YAML file, the retired-name and block-art guards, and about 40 host-side suites of both editions |
| 2. One behaviour | `bash <suite>` from [Running the tests](docs/guides/running-the-tests.md), for example `backends/ubuntu/chroot/tests/customize-chroot-checks.sh` (159 checks) | `bash` | seconds | One script, one rule: the dock list (40), the Companion links and welcome page (70), the first-boot load gate (11), the headless Hub start (20), the download-progress filter (21), the one-click installer (121 unit tests) |
| 3. A built image, read | `VERIFY_BASE_ISO=<stock ISO> VERIFY_REQUIRE_CANON=1 backends/ubuntu/iso/scripts/verify-iso.sh <ISO>` | `xorriso`, `squashfs-tools`, `zstd`, `cpio`, `python3` | 35 to 90 s | The finished ISO against the stock one and against what the build meant to do: 444 checks on amd64, 436 on arm64 (the architecture is read from the volume id) |
| 4. A built image, run | `backends/ubuntu/iso/tests/boot-arm64-vm.sh`, `installed-boot.sh`, `stick/tests/qemu/run.sh` | QEMU, firmware, a container for some | 2 to 20 min (arm64 with hardware acceleration); hours for x86-64 under emulation | The live desktop, the one-click install, the installed boot and the first-boot job, as a person would see them |
| 5. Real hardware | none | a machine | | **[N]** no run is recorded (KI-17) |

### Walk an image through the whole chain (arm64 on an Apple-silicon Mac)

This is the run behind the screenshots on this page. The same steps work for the amd64 image, much more slowly: an x86-64 guest on a Mac
is software emulation, so the live desktop takes 6 to 15 minutes and an install about six hours ([`docs/guides/testing-in-qemu.md`](docs/guides/testing-in-qemu.md)).

```bash
# 1. Build and verify (the arm64 container recipe of "Get an ISO", with --arch arm64 and the arm64 desktop ISO from cdimage.ubuntu.com)
# 2. Boot the ISO as a USB drive, with a blank file-backed disk to install to (created at 64 GiB, sparse)
T=backends/ubuntu/iso/tests
$T/boot-arm64-vm.sh start output/companion-os-1.0-arm64.iso ./target.qcow2   # prints the QMP socket and the serial log
$T/boot-arm64-vm.sh shot live.png                                            # take a screenshot at any time
python3 $T/lib/qmp-drive.py /tmp/ci-arm64-vm/qmp.sock click 33 64 1280x800  # click, type, press keys: see the script header
$T/boot-arm64-vm.sh stop
# 3. After the installer powers the machine off, boot the installed disk alone
$T/boot-arm64-vm.sh start - ./target.qcow2
```

### Film the first run

The first run (boot menu, the one-click dialog, the install, the first sign-in, the setup notices, Companion Hub's pairing page) is also a film, made with the
org's video kit (CI-Common `packages/video-kit`, CI-Engineering `projects/product-video-pipeline`) from plates recorded in a VM: `./video/render.sh` renders
landscape and square cuts in about three minutes. [`video/README.md`](video/README.md) says what is true about it (a virtual machine, not real hardware), how
the plates are made (the one-time password is covered by a bar that a test checks) and how to shoot it again. The internal time-lapse of the same run is in
[`docs/guides/testing-in-qemu.md`](docs/guides/testing-in-qemu.md#recording-a-first-run-video).

The runner needs `qemu-system-aarch64`, `qemu-img`, `python3` and the edk2 aarch64 firmware (macOS: `brew install qemu`). It refuses a block
or character device as the disk, so a test cannot write to a real one. The guest has no Secure Boot firmware under Homebrew's QEMU.

What a good run shows, in order. Each line is a check you make on a screenshot or in the guest, and each leaves a record in
[`docs/evidence/`](docs/evidence/README.md):

| Step | Expect | Seen on arm64 (HVF, 2026-10-19) |
|---|---|---|
| Boot menu | The Companion mark and four entries, the first highlighted, a 15 s countdown | **[V]** |
| Live desktop | Companion wallpaper; dock: installer, Hub, Docs, Files, Terminal; five desktop shortcuts **with their icons and names** (a red cross means an untrusted launcher) | **[V]**, about 2 min |
| One-click dialog | Names the disk and what is on it; default **Cancel**; a one-time password | **[V]** |
| Install | A progress window, then the machine powers itself off | **[V]**, 9 min 35 s and 12 min 10 s |
| Installed boot | Branded greeter, `graphical.target` in about 20 s of userspace | **[V]** |
| First sign-in | The one-time password, then a forced new one; **no** "Welcome to Companion OS" page with the raccoon; the Companion getting-started page in the browser | **[V]** on the current image. The first rebuild showed the raccoon page (KI-27); the fix is in [Status and evidence](#status-and-evidence) |
| First-boot job | Starts 3 min after boot; `wait-quiet` passes; `ollama.service` runs at `CPUWeight=20`; two models pulled; Hub containers healthy; about 280 journal lines, not 40 KB of progress bars | **[V]**, 1 min 58 s |
| Hub | The Companion Hub window opens on the pairing screen; `http://localhost:5002` answers 200 | **[V]** |
| Failed units | Only `pd-mapper.service` on arm64 (KI-28) | **[V]** |

A text channel into the guest is easier to read than screenshots: serve a script directory from `127.0.0.1` with any small HTTP server and
`curl http://10.0.2.2:<port>/script.sh | sh` from the guest terminal (QEMU's user networking reaches the host at `10.0.2.2`); have the script `POST` its output back.

### Adding a test

Register the suite in `core/lib/check-repo.sh` (exit 2 when a tool is missing, never a silent skip), put a row in
[Running the tests](docs/guides/running-the-tests.md), and **mutation-check it**: break the line it guards and watch the test go red. The
tests of the first-boot and first-run scripts do this; the stamp that skips Canonical's upgrade welcome page is checked against the real unit
captured from an image (`backends/ubuntu/chroot/tests/fixtures/`). A claim about behaviour needs an evidence tag and a record: see
[`docs/evidence/README.md`](docs/evidence/README.md).

---

## Repo layout

```
.
├── CLAUDE.md, AGENTS.md, ANTIGRAVITY.md, opencode.json, .github/copilot-instructions.md   agent guides (CLAUDE.md is canonical)
├── .claude/              settings, session-start hook, skills/steward (PR conventions)
├── .github/workflows/    build-companion-os-iso.yml, pr-checks.yml, stick-real-iso.yml, style-canon-lint.yml (manual-only)
├── core/                 distro-portable: no package-manager assumptions
│   ├── manifest/         ecosystem.yaml, role-map/{apt,pacman}.yaml, model-packs.yaml + lock, tier-b-pins.env, licenses.yaml
│   ├── render/           tokens + assets -> GRUB background, MOTD, mark PNGs, GNOME Shell gresource; inputs/, tests/
│   ├── lib/              theme-lib.sh, gpu-detect.sh, ci-os-models.sh, ci-hub.sh, vendor-brand.sh, check-repo.sh, retired-names.allow, tests/
│   └── headless/         payload/ (setup backend, portal, hostapd/dnsmasq/nginx, units), ci_setup/ (tested library), tests/
├── backends/
│   ├── ubuntu/           Companion OS on Ubuntu 26.04.1: apt/dpkg + Bash
│   │   ├── iso/          scripts/ (build-iso.sh, build-in-docker.sh, verify-iso.sh, publish-r2.sh, verify-published.sh, release-manifest.py, md5sum-txt.sh, lib/split-live-layer.sh, gresource builder), tests/, README.md
│   │   ├── chroot/       customize-chroot.sh, payload/ (apt, docker, live-start = one-click installer, models, ssh), tests/
│   │   ├── provision/    provision.sh, bootstrap-ci-os.sh, install-models.sh
│   │   ├── desktop-theme/  apply-ci-os-desktop.sh + plymouth, grub, wallpaper, start-icon, about-logo, os-release, names steps; tests/
│   │   ├── lib/          os-release writer, ROCm and LACT installers, telemetry removal, Strix Halo boot parameters
│   │   ├── packages/     ci-os-branding (GNOME Shell theme .deb sources)
│   │   └── headless-package/  build.sh, DEBIAN/, netplan/ (apt packaging of the setup payload)
│   ├── cachyos/          Companion OS on CachyOS: pinned archiso profile + overlay, built in a container
│   │   ├── iso/          scripts/ (build-iso.sh, in-container engine, verify-iso.sh), overlay/, docker/, tests/
│   │   ├── installer/    Calamares overlay: settings, modules, branding, guards, scripts
│   │   ├── provision/    first-boot wrapper, systemd units, progress filter, setup-portal stager
│   │   └── upstream.lock, compat-libs.lock, NOTICE, README.md
│   ├── arch/             NOT a target: the frozen pacman engine under CachyOS (provision/, headless-setup/ oracle, desktop-theme/ unused)
│   └── _mixins/          gnome-dconf/ (Ubuntu), kde-plasma/ (CachyOS)
├── stick/                Rust workspace: crates/ci-stick, schema/, scripts/ (signed-boot fetch, GRUB), tests/{qemu,secureboot}
├── video/                the stick's first-run film (org video-kit): storyboard.json, plates from a VM recording, narration, render.sh
├── vendor/brand/         the pinned brand bundle (ci-brand 1.0.0): tokens, logos, Manrope font; SHA256SUMS
├── assets/               logos, wallpaper, branding/brand-guidelines.md, GNOME Shell theme assets
├── docs/                 README.md (index), architecture/, guides/, evidence/ (text records behind the verified rows), plans/, ui/, CI.md
├── pull-dev-manual.sh    thin wrapper around core/lib/ci-hub.sh
└── LICENSE.md, License-FAQ.md, NOTICE.md, THIRD_PARTY.md, CREDITS.md
```

---

## Status and evidence

As of 2026-10-19 (branch `liam/companion-os-arm64`, local commits only; the Plasma column is of 2026-10-18). The columns say what was run, not
what is intended. The sources and the pending items are in [`docs/architecture/test-evidence.md`](docs/architecture/test-evidence.md)
and [`docs/architecture/supported-targets.md`](docs/architecture/supported-targets.md).

| Area | Ubuntu 26.04.1 | Plasma (CachyOS) |
|---|---|---|
| Build | **[V]** clean checkout at `02c575e`, 772 s; fix-pass snapshot, 860 s | **[V]** six ISOs (#6 from the clean commit `ad37b64`) |
| Static verifier | **[V]** amd64 446 passed, arm64 438 passed, 0 failed (commit `4b7597d`; 393 on the images of 2026-10-18) | **[V]** 215 passed, 0 failed on ISO #6; 187 on ISO #2; no log of ISO #4 or #5 |
| Live session boots | arm64: **[V]** to the GNOME desktop in about 2 min (QEMU, HVF), shortcuts trusted. amd64: GRUB menu under Secure Boot **[V]** (earlier image); live desktop of the current image under emulation: dock correct with Capture, **no desktop icons** (KI-27) | **[V]** to the Plasma desktop under QEMU/OVMF (ISO #4, #5, #6; frames in [`docs/ui/companion-os/plasma/`](docs/ui/companion-os/plasma/CAPTURE.md)) |
| Install to disk | arm64: **[V]** one-click install in 9 min 35 s and 12 min 10 s, then installed boot with the greeter 50 s after power-on. amd64: pending; a harness-assembled disk of an earlier image (version 9.9, `dce9eb71...`, not a commit) booted to the GDM greeter in 230 s **[V]**; the clean-checkout image (`709b8485...`) has only the `--no-boot` checks | **[V]** ISO #4 22 min 9 s; ISO #5 23 min 20 s on its third attempt (two failed at the 30 s keyring limit, KI-20); ISO #6 28 min 26 s on its first attempt (keyring step 32 s under the explicit limit of the fix) |
| First boot and models | arm64: **[V]** 1 min 58 s, two models, Hub healthy, no first-run page from Canonical (the first rebuild showed one: KI-27). amd64: pending | **[V]** ISO #4: models pulled in 16 min, ended "degraded" (defect); ISO #5: 21 min 49 s, status 0, no "degraded"; ISO #6: 21 min 19 s, status 0, three models, 301-line log |
| Stick boot | stock ISO under Secure Boot to early systemd **[V]** | **[N]** |
| Real hardware | **[N]** | **[N]** |

Pending evidence: for the Ubuntu 26.04.1 image the live session, both installers, the boot of the clean-checkout image and first boot
(test-evidence rows U2 to U11), and for Plasma the Secure Boot variant of the firmware, a second install run and any real hardware. Each row says what confirms it in
[`test-evidence.md`](docs/architecture/test-evidence.md); [`supported-targets.md`](docs/architecture/supported-targets.md) maps the matrix to those rows.

Retired on 2026-10-17 (restore tag `pre-retire-multidistro-2026-10-17`): Ubuntu 24.04, Linux Mint, Fedora, Bazzite and NixOS.

---

## Documentation

The index of every document is [`docs/README.md`](docs/README.md). Start here:

* [Supported targets](docs/architecture/supported-targets.md): policy, capability matrix, retirement and restore.
* [Core and backends design](docs/architecture/multi-distro-design.md): how the repository is organised.
* [Known issues and decisions](docs/architecture/known-issues-and-decisions.md), [Test evidence](docs/architecture/test-evidence.md) and
  the [evidence records](docs/evidence/README.md).
* Building and installing: [ISO build guide](docs/guides/iso-build-guide.md), [Installation guide](docs/guides/installation-guide.md),
  [Quick start](docs/guides/quick-start-guide.md), [Building on a Mac](docs/guides/building-on-a-mac.md),
  [Testing in QEMU](docs/guides/testing-in-qemu.md), [Running the tests](docs/guides/running-the-tests.md),
  [Release checklist](docs/guides/release-checklist.md), [CI-Hub deploy](docs/guides/ci-hub-deploy.md),
  [Environment reference](docs/guides/environment-reference.md).
* The stick's first-run film: [`video/README.md`](video/README.md).
* Per edition: [`backends/ubuntu/iso/README.md`](backends/ubuntu/iso/README.md), [`backends/cachyos/README.md`](backends/cachyos/README.md),
  [Ubuntu ISO layers](docs/architecture/ubuntu-iso-layers.md), [CachyOS backend](docs/architecture/cachyos-backend.md).
* Stick and models: [`stick/README.md`](stick/README.md), [Companion Stick](docs/architecture/companion-stick.md),
  [Models tooling](docs/architecture/models-tooling.md).

<!-- companion-hub-readme-deep-review -->

## Build and install path

```mermaid
flowchart LR
  Source[Edition configuration] --> Build[Image build workflow]
  Build --> ISO[Published ISO artifact]
  ISO --> Verify[Checksum and image verification]
  Verify --> USB[Flash installer USB]
  USB --> Install[Install selected edition]
```

The Ubuntu and Plasma/CachyOS editions have different bases and verification details; use the edition-specific instructions above and verify the downloaded image before writing it to removable media. The measured build and image-size notes in this README are environment-specific observations, not performance guarantees.

## Support

* **Issues**: https://github.com/companionintelligence/CI-OS/issues
* **Website**: https://ci.computer

© Companion Intelligence, Lifescope Inc
