# Ubuntu 26.04.1 port notes: what changed from 24.04 and why

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Date 2026-10-18. Scope: the Ubuntu backend (`backends/ubuntu/`) and what it touches in `core/`, `stick/` and `.github/workflows/`, after the
owner's decision of 2026-10-17: Companion OS is supported on Ubuntu 26.04.1 LTS (resolute) and on CachyOS, and on nothing else.

Ubuntu 24.04 (noble) is retired as a base, and the Linux Mint, Fedora, Bazzite and NixOS backends were removed on 2026-10-17; restore one with `git checkout pre-retire-multidistro-2026-10-17 -- backends/<name>` (the tag is local; a verified bundle is kept in the maintainer's `_archive` directory outside the repository: file name, size and sha256 are in [supported-targets.md](supported-targets.md#7-retired-targets-and-the-restore-recipe), and KI-21 records that this is not a durable location).

Evidence tags used in every table: **[V]** verified (read in the cited file, run, or measured on the real stock ISO), **[I]** implemented and
tested in parts, not proven end to end, **[N]** not implemented or not checked. A row marked **pending evidence** names what will confirm it.
Dates are 2026-10-17 and 2026-10-18 unless a row says otherwise. "The stock-ISO report" is the read-only inspection of
`ubuntu-26.04.1-desktop-amd64.iso` (6,482,409,472 bytes, sha256 `601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f`) made on
2026-10-17; it lives in the working session's scratchpad, not in the repository, so every fact below also names a repository test or command that
can find it again.

## 1. Summary

| Section | Change | Why (measured) | Guard | Tag |
|---|---|---|---|---|
| 2 | `md5sum.txt` convention rewritten | the stock file now lists the EFI and GRUB-module files | `tests/md5sum-txt.sh`, `verify-iso.sh` section 8 | [V] |
| 3 | `install-sources.yaml` is a version 2 mapping with the stock `kernel:` block | a bare list makes subiquity ask for a kernel that is nowhere on the image | `verify-iso.sh` section 3d, `tests/split-live-layer.sh` A12 | [V] |
| 4 | The installed system stays initramfs-tools based; dracut is pinned out | the stock installed system is dracut based, the stock live layer swaps it out | `chroot/tests/no-dracut-pin.sh`, `verify-iso.sh` section 3g, `tests/installed-boot.sh` | [V] static and a QEMU boot, [N] a real install |
| 5 | One session file, Wayland only | no Xorg session and no Xorg server in the image | `desktop-theme/tests/visible-names.sh`, `verify-iso.sh` section 4c | [V] |
| 6 | sudo-rs and uutils are the defaults | 26.04 ships them | the suites run on a 26.04 container; `check_build_host` | [V] for the forms tested |
| 7 | Settings > About logo is replaced as SVG as well as PNG | gnome-control-center 50.3 reads only the SVG names | `desktop-theme/tests/about-logo-svg.sh`, `verify-iso.sh` section 4b | [V] static, [N] rendered |
| 8 | The 20 TPM-encryption layers and their snapd seed are removed | 64.7 MB of layers and 0.66 GB of seed that this image cannot install | `verify-iso.sh` sections 3d and 3g, `tests/split-live-layer.sh` A12 | [V] |
| 9 | New live-only rows; one 24.04 row and the `core22` name dropped | the stock live layer carries a polkit rule, a sysctl file and more | `verify-iso.sh` section 3g, `tests/verify-installer-base.sh` | [V] |
| 10 | SSH host keys and the rebrand unit no longer depend on `ConditionFirstBoot` | the installer copies the live session's machine-id into the target | `chroot/tests/customize-chroot-checks.sh`, `chroot/tests/first-boot-units-boot.sh` | [V] in containers, [N] on a real install |
| 11 | Size gate of 8 GiB | a 64 GB Stick has 8 GiB boot slots | `verify-iso.sh` section 9 | [V] |
| 12 | `/.disk/info` says `Companion OS`, with a blank | the installer's last page prints it | `verify-iso.sh` section 5, `tests/boot-media-plymouth.sh` | [V] static, [N] on a booted installer |
| 13 | Build and test host rules | Docker Desktop on Apple silicon behaves differently | `check_build_host` in `build-iso.sh` | [V] |

Section 14 lists the smaller changes. Section 15 says what has been run and what is pending.

## 2. md5sum.txt convention

**Fact.** The stock 26.04.1 `md5sum.txt` has 948 entries, sorted by path in the C locale, and lists the three Secure Boot files
`/EFI/boot/{bootx64,grubx64,mmx64}.efi` and the 611 other files under `/boot/grub/{fonts,i386-pc,x86_64-efi}`. It leaves out exactly three regular
files: `/md5sum.txt`, `/boot.catalog` and `/boot/grub/i386-pc/eltorito.img` (its boot-info-table is patched on every remaster). 24.04.5.1's file
excluded the EFI and GRUB-module files and was in `find` order. [V] `backends/ubuntu/iso/scripts/md5sum-txt.sh` header.

**Effect.** Run against the real 26.04.1 ISO, the 24.04 rule reported 614 "lists X, which this script treats as an exclusion" errors (3 EFI files and 611 under `boot/grub/<subdir>`) and exited 1, so the build stopped at its first step, `check_base_md5sum` (`build-iso.sh:989`). [V] executed 2026-10-17.

**Change.** `md5sum-txt.sh` now excludes only those three paths and writes the whole list sorted. `casper-md5check.service` is enabled in the live
layer and runs on every live boot (the 26.04.1 GRUB menu has no entry for it), so a stale file fails every live boot.

```bash
backends/ubuntu/iso/scripts/md5sum-txt.sh check-stock --base-iso ubuntu-26.04.1-desktop-amd64.iso
backends/ubuntu/iso/scripts/md5sum-txt.sh verify output/companion-os-1.0-amd64.iso
CI_TEST_STOCK_ISO="$PWD/ubuntu-26.04.1-desktop-amd64.iso" bash backends/ubuntu/iso/tests/md5sum-txt.sh
```

| Check | Result | Tag |
|---|---|---|
| `check-stock` on the real ISO | convention holds: 948 entries, 950 regular files, 2 reported as excluded, sorted | [V] |
| `tests/md5sum-txt.sh` with `CI_TEST_STOCK_ISO` | 75 passed, 0 failed (`core/lib/check-repo.sh` runs the part that needs no ISO) | [V] |
| `verify-iso.sh` section 8 on the built image | 6 passed: 800 entries, all hash, none names a missing file | [V] |
| `casper-md5check` inside a booted guest ("no errors found") | not recorded | pending evidence: `journalctl -u casper-md5check` or `/run/casper-md5check.json` in the capture directory of section 15 |

## 3. install-sources.yaml: version 2 and the kernel block

**Fact.** The stock file is a mapping with three keys: `kernel: {default: linux-generic-hwe-24.04}`, `sources:` and `version: 2`. 24.04's was a
bare list. In subiquity (`subiquity/models/source.py`, read in the installer snap, rev 665) a list becomes `SourceCatalog(version=1, kernel=KernelInfo(default="linux-generic"))`,
so the installer would ask curtin for `linux-generic`, which is neither in the base layer nor in the ISO's `pool/`. The kernel package of the stock
file, `linux-generic-hwe-24.04`, is installed in the minimal layer (the name says 24.04 on a 26.04.1 image because that is what Canonical's file names). [V] stock-ISO report 6.1 row 2.

**Change.** `write_install_sources` (`build-iso.sh:516`) copies the stock `kernel:` block verbatim, writes the two entries (`ubuntu-desktop-minimal` and
`ubuntu-desktop`, `type: fsimage-layered`, `preinstalled_langs: []`, no variations for the TPM-encryption layers) and `version: 2`. It refuses a stock
file that is a bare list or has no `kernel:` block with a `default:`. `/etc/subiquity/kernel-meta-package` no longer exists on 26.04.1, so the live-layer
row that required it was deleted (section 9).

| Check | Result | Tag |
|---|---|---|
| `verify-iso.sh` section 3d on the built image | 11 passed: version 2, the stock kernel block (with `VERIFY_BASE_ISO`), a kernel package the base has, exactly the twelve `minimal*` files | [V] |
| `tests/split-live-layer.sh` A12 with `CI_TEST_SUBIQUITY_DIR` | subiquity's own `SourceModel` loads the generated file (version 2, kernel `linux-generic-hwe-24.04`, two entries, default `ubuntu-desktop-minimal`): 18 passed | [V] 2026-10-17 |
| curtin installs from this file on a booted installer | not recorded | pending evidence |

## 4. Initramfs generator: initramfs-tools, and the pin

**Fact.** Ubuntu 26.04.1's minimal layer, which is what a stock install copies, is dracut based: dracut 110-11, a dracut-built
`/boot/initrd.img-7.0.0-30-generic` of 87,308,219 bytes, and `/usr/sbin/update-initramfs` is dracut's wrapper around `dracut --force`. The live layer swaps that
for initramfs-tools 0.151 (casper needs it) with 75 whiteout nodes: all of dracut and the dracut-built initrd. `ubuntu-desktop-minimal` Recommends dracut, and dracut Conflicts with initramfs-tools.
curtin's initramfs step runs `update-initramfs` if it exists, does nothing if only dracut exists, and raises if a kernel exists and neither does. [V] stock-ISO report 2.2 and 3.4 (`curthooks.py:939-1011`).

**Decision (2026-10-17).** The installed system is initramfs-tools based. `extract_squashfs` merges the three layers and applies the whiteouts, so the rootfs, and the base
layer the split gives back, have initramfs-tools and no dracut; curtin then regenerates the initrd with initramfs-tools' own `update-initramfs`.
Restoring dracut was not chosen: the installed system would build its initrd with a different tool than the live one, and every initramfs test would have to be redone. The
reasoning is in the header of `build-iso.sh`.

**What it costs and the pin.** apt could later try to swap the generator. `backends/ubuntu/chroot/payload/apt/etc/apt/preferences.d/ci-os-no-dracut`
(installed by `customize-chroot.sh` Step 1b, line 301, before the first apt call) pins `dracut` and `dracut-core` to Pin-Priority -1. `dracut-install` is deliberately not pinned:
`initramfs-tools-core` depends on it, and pinning it held back its security update in a simulated `dist-upgrade` and made `apt-get -s install initramfs-tools` fail (measured on 26.04; mutant A of the test below).

| Check | Result | Tag |
|---|---|---|
| `chroot/tests/no-dracut-pin.sh` (privileged `ubuntu:26.04` container, apt in simulation) | 12 checks; `ubuntu-desktop-minimal` installs neither dracut package; `dracut-install` and `initramfs-tools` stay installable; 3 mutants killed | [V] |
| `verify-iso.sh` section 3g | initramfs-tools installed, no `dracut` or `dracut-core` in the base status, the pin file pins both to -1 | [V] on the built image |
| `tests/installed-boot.sh --iso <built image>`, **the fix-pass image (version 9.9, sha256 `dce9eb71...`, a worktree snapshot, not the clean-checkout image `709b8485...`)** | PASS: 25 static checks, 0 FAIL, 0 WARN (`initramfs-generator`: initramfs-tools 0.151ubuntu1, `dracut-pin`, no casper in `initrd.img-7.0.0-30-generic`, 2,456 entries), then the disk the test assembled (not a real install) booted to the GDM greeter, greeter up at 53 s of probe time, 230 s of boot, screen not black (`nonblack=1.0`) | [V] 2026-10-18 |
| curtin's initrd on a real subiquity install boots | the test builds a disk "the way an install ends up"; it is not the installer | pending evidence |

## 5. One session, Wayland only

**Fact.** The image has exactly one session file, `/usr/share/wayland-sessions/ubuntu.desktop` (`Exec=/usr/bin/gnome-session --session=ubuntu`, `TryExec=/usr/bin/gnome-session`,
`DesktopNames=ubuntu;GNOME`). There is no `/usr/share/xsessions`, no `ubuntu-wayland.desktop`, no `ubuntu-xorg.desktop` and no Xorg server (only `Xwayland`). GDM 50 has no `WaylandEnable` key. [V] stock-ISO report 4.
24.04 had four session files.

**Change.** `desktop-theme/60-visible-names.sh` (Step 5d) renames the one session, the Settings entry and the three extensions; an image build fails if a stock file is missing or reads differently, because the base ISO has all of them.
Identifiers (`DesktopNames=`, extension uuids, `OnlyShowIn=`) stay Ubuntu's.

**Guard.** `desktop-theme/tests/visible-names.sh` runs on the five real stock files (`desktop-theme/tests/fixtures/stock-26.04.1/`): 49 checks, mutant killed. `verify-iso.sh` section 4c: 17 passed on the built image. [V]

## 6. sudo-rs, uutils, Python 3.14, bash 5.3

**Fact.** `sudo` is sudo-rs 0.2.13 (`/usr/bin/sudo -> /etc/alternatives/sudo -> /usr/lib/cargo/bin/sudo`; classic sudo 1.9.17p2 is also installed). Coreutils are uutils
(`rust-coreutils` 0.8.0 on the ISO, 0.10 in the `ubuntu:26.04` container); `cp`, `mv`, `rm` stay GNU and `su` is util-linux's. Python is 3.14, bash 5.3. [V] stock-ISO report 4.

**Evidence that the scripts are unaffected.** About 60 concrete forms the scripts use (`stat -c %t/%T/%a`, `du -sx --block-size=1`, `install -D -m`, `date -u`, `od`, `comm`, `sort -z`, `head -c`, `tail -c +N`,
`chmod --reference`, `readlink -f`, `mktemp -d -u`, `touch -d @0` and more) gave the GNU answer when run against the ISO's own `usr/bin/coreutils` 0.8.0 in an amd64 container. The `sudo -H -u U VAR=val`, `sudo -u U env ...` and `sudo -n tee|install|ln|chmod|rm` forms were run against sudo-rs 0.2.13. No module removed in Python 3.12 to 3.14
is imported by any tracked Python file (AST scan). The model suites passed under mawk and gawk. [V] 2026-10-17.
**Not covered:** `du` block-count parity on real filesystems.

The build host rule (section 13) exists partly for this reason: `build-iso.sh` is run where uutils and sudo-rs are the defaults.

## 7. Settings > About logo: SVG as well as PNG

**Fact.** `gnome-control-center` 50.3 contains the strings `/usr/share/pixmaps/ubuntu-logo-text.svg` and `/usr/share/pixmaps/ubuntu-logo-text-dark.svg` and no `.png` name. The PNG pair is still shipped (187x72);
base-files owns all four files. A build that replaced only the PNGs would leave Ubuntu's wordmark in About on 26.04 and fail nothing. [V] strings of the binary; rendering in a booted GNOME 50: [N].

**Change.** `desktop-theme/45-about-logo.sh` diverts and replaces both pairs. The SVGs are the vendored one-colour mark with `currentColor` replaced by the canon primary of each mode
(`#0a6358` light, `#c5e8dc` dark), by text substitution, so no renderer is needed. Stock hashes: PNGs `5f8a4779...` and `63c599f9...`, SVGs `351337c2...c433` and `bc60770f...8119`.

<!-- figure: docs/ui/companion-os/ubuntu/NN-live-settings-about.png (Settings > About with the Companion OS mark) -->

**Guard.** `desktop-theme/tests/about-logo-svg.sh` (23 checks, real base-files, apt reinstall keeps the files), `about-logo-no-renderer.sh` (16), `iso/tests/verify-logo-surfaces.sh` (30 variants, each must print the FAIL line that names its defect),
`verify-iso.sh` section 4b (40 passed on the built image). [V]

## 8. The TPM-encryption layers and seed are removed

**Fact.** The stock ISO has 41 layer files: three main layers, 18 language layers and 20 `enhanced-secureboot` layers (64,704,512 bytes), each with `.size`, `.manifest` and `.manifest.full`. The live layer also carries
the snapd seed of Ubuntu's TPM full-disk-encryption variant: `seed/systems/enhanced-secureboot-desktop` and five snap files that `seed.yaml` does not name (`pc-kernel`, `pc`, a second firefox revision, two nvidia components), 662,151,168 bytes that do not compress. [V] stock-ISO report 2.1 and `build-iso.sh` log below.

**Change.** `remove_stock_layer_files` deletes every `minimal*` file in `casper/`; `assert_casper_layer_files` requires exactly the twelve files of the three layers; `remove_esb_seed` (`build-iso.sh:397`) deletes the seed from the merged rootfs before the split. It refuses to sweep unless `seed.yaml` names at least one snap file and every file it names exists.
The split's own rows (`rm|var/lib/snapd/seed/systems`, `seed-orphans|`) remain as the second line.

| Check | Result | Tag |
|---|---|---|
| real build log, `remove_esb_seed` | "seed-orphans: 5 snap file(s) ... removed"; `seed/` 2,641,399,808 -> 1,979,248,640 bytes | [V] |
| `tests/split-live-layer.sh` A12 | refusal cases and a mutant covered | [V] |
| `verify-iso.sh` 3g (live layer) | no `seed/systems`, no `seed/snaps` file that its own `seed.yaml` does not name | [V] |
| the live session and installer behave the same without the seed | rests on the installer reading the layers `install-sources.yaml` names and on `seed.yaml`, not `systems/`, being the live seed | pending evidence |

## 9. New live-only rows, and the rows that went

The split library's table (`scripts/lib/split-live-layer.sh:135`) is described in [ubuntu-iso-layers.md](ubuntu-iso-layers.md), section 4.3. What differs from 24.04.5:

| Row | Status | Why |
|---|---|---|
| polkit rule `10-allow-installer-wait-on-snap.rules` | new | grants `io.snapcraft.snapd.manage-configuration` to every subject; its own header says "ONLY AVAILABLE ON THE LIVE SYSTEM" |
| `/etc/sysctl.d/20-apparmor.conf` | new | sets `kernel.apparmor_restrict_unprivileged_userns = 0`, which switches off Ubuntu's default restriction |
| `display-manager.service.d/wait-for-snapd-seeding.conf` | new | holds the login screen for the installer's snap seeding |
| `etc/systemd/system/snapd.service.d/snapd-snap-reexec.conf` | moved | 24.04 had `usr/lib/systemd/system/snapd.service.d/no-reexec.conf` (a real setting); the 26.04.1 file is all comments |
| `var/lib/snapd/seed/systems` and `seed-orphans` | new | the TPM-encryption seed (section 8) |
| `/etc/subiquity/kernel-meta-package` as a required live path | deleted | no `/etc/subiquity` exists on 26.04.1; the kernel comes from the `kernel:` block |
| installer snap base `core22` | deleted | the snap's base is `core24`, shared with the system, so it stays |

Found by the audit of the stock live layer (`tests/split-live-layer.sh` group B1), not by the 24.04 derivation. [V] The first two are security-relevant: on 26.04.1 they would have reached every installed system.

## 10. machine-id, SSH host keys and ConditionFirstBoot

**Fact.** The stock image's `/etc/machine-id` is empty, so every live boot is a "first boot". The installer copies the live session's valid machine-id into the target: `subiquity/models/subiquity.py` `_machine_id()` (line 451) and `render()` (lines 477-482) put it in curtin's `write_files` as `etc/machine-id`, mode 0444 (read in the snap, rev 665). Per `machine-id(5)` a valid ID is not a first boot, so
`ConditionFirstBoot=yes` is false on an installed machine. [V]

**Effect, reproduced.** With systemd 259.5 as PID 1 in a container, the host keys removed by Step 11 and a valid machine-id, `sshd-keygen.service` is skipped, no key exists, and `ssh.service` dies in `ExecStartPre=/usr/sbin/sshd -t` ("no hostkeys available") until the start limit trips. The old `ci-os-first-boot-rebrand.service` had the same condition and was skipped. [V] containers, 2026-10-18.
On the installer's own path cloud-init's `ssh` module also makes the keys, so a normal install was probably fine by that mechanism; nothing should depend on it (it is disabled after the first boot).

**Change.**
- `payload/ssh/etc/systemd/system/sshd-keygen.service.d/10-ci-os-host-keys.conf` clears `ConditionFirstBoot` (an empty assignment resets every `Condition*` line, so the package's two others are restated) and runs when `/etc/ssh/ssh_host_ed25519_key` is missing.
- Step 11 of `customize-chroot.sh` (line 1699) installs the drop-in first, and the cleanup script refuses to remove the host keys unless the drop-in and `sshd-keygen.service` exist. The base layer must hold no host keys (`verify-iso.sh` section 3g).
- `ci-os-first-boot-rebrand.service` is gated on the stamp `/var/lib/ci-os/.first-boot-rebrand-done`, as `ci-os-first-boot-setup.service` already was. The build records its version in `/usr/lib/ci-os/version` so a reset `os-release` is rebranded to the build's version and not to `0.0.1`.
- **Rule:** gate first-boot units on a stamp file, never on `ConditionFirstBoot`. The live-session guard (`ConditionPathExists=!/cdrom/casper/vmlinuz`) stays.

| Check | Result | Tag |
|---|---|---|
| `chroot/tests/customize-chroot-checks.sh` (host, bash 3.2 is enough) | 75 passed, 0 failed, including the guard block executed against scratch roots; 13 mutants killed | [V] |
| `chroot/tests/first-boot-units-boot.sh` (Docker, privileged, systemd as PID 1) | 41 passed: control reproduces the defect, drop-in makes 6 key files and ssh answers, second boot keeps the keys, read-only `/etc/ssh` still skips, the installer's cloud-init path; 7 mutants killed | [V] arm64 Docker Desktop; read section 13 before running it |
| on an installed machine from the real installer | not recorded | pending evidence: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` and `systemctl is-active ssh` on the installed disk |

`tests/installed-boot.sh` still writes an **empty** machine-id into its disk (`tests/lib/installed-boot-disk.sh:374`), so it models a first boot, runs both units, and cannot see this defect. See section 16.

## 11. Sizes

Stock numbers (measured, [V] stock-ISO report 2.1 and 6.2; `backends/ubuntu/iso/README.md`, "Size and the Stick boot slot"):

| | bytes |
|---|---|
| stock ISO | 6,482,409,472 |
| `minimal.squashfs` (1,537 packages, 13 snaps) | 3,432,136,704 |
| `minimal.standard.squashfs` (+228 packages, +1 snap) | 590,053,376 |
| `minimal.standard.live.squashfs` (+51 packages, -2) | 793,112,576 |
| the 41 layer files | 5,058,371,584 |
| `pool/` (155 debs) | 1,288,305,210 |

Built image, one real `build-iso.sh` run on 2026-10-18 (version string 9.9, privileged `ubuntu:26.04` container, Tier B knobs all on, 860 s; log `fixA-evidence/real-image-build.log` in the session scratchpad). [V]

| | bytes |
|---|---|
| `minimal.squashfs` (B, 1,874 packages; the merged rootfs C has 1,876) | 5,537,636,352 (`du` 10,764,008,960) |
| `minimal.standard.live.squashfs` (L, 249 paths staged from C, 0 whiteouts) | 117,485,568 (`du` 240,519,168) |
| whole live stack (`du`) | 10,998,049,792 |
| the ISO | 7,076,577,280 |
| under the 8 GiB gate (8,589,934,592) | 1,513,357,312 spare |

The split took 253 s to pack B and L and 274 s to prove that the stack of the three layers equals C. `md5sum.txt`: 800 entries (778 stock hashes kept, 18 recomputed, 4 new, 152 dropped).

**Hard links.** Every snap blob exists under two names that are one inode (`/var/lib/snapd/snaps/X.snap` and `/var/lib/snapd/seed/snaps/X.snap`). mksquashfs 4.6.1 keeps such links (measured), so an `unsquashfs -ll` listing over-counts by the size of one name per blob: the stock minimal layer lists 9.06 GB and `du` says 6.16 GB. The
`.size` interval in `verify-iso.sh` (`layer_size_bounds`) leaves one name out of its lower bound. The 24.04 comment that mksquashfs "does not keep links between directories" was wrong and was corrected. The build container has squashfs-tools 4.7.5; the stack-equals-rootfs check passed with it.

**Retired baseline (24.04.5).** The v7 image was 7,692,484,608 bytes with a 5,640,392,704-byte `minimal.squashfs`; its live layer was 399 MB.

**Gate.** `verify-iso.sh` section 9 fails an image above 8 GiB (`VERIFY_MAX_ISO_BYTES` changes it, `0` turns it off), because `ci-stick flash` writes the ISO raw into a boot slot of usable/10 clamped to 8..48 GiB: 8 GiB on a 64 GB stick. The 8 GiB default ties the build to the 64 GB stick; that is an owner decision (section 17).

## 12. /.disk/info: Companion OS, with a blank

The line `Ubuntu 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)` becomes `Companion OS 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)` (`build-iso.sh:853`; anything but the stock shape fails the build).

Readers, each read in the real 26.04.1 files and asserted by `verify-iso.sh` section 5: [V] static

| Reader | What it does with the file | With a blank in the name |
|---|---|---|
| the installer's last page (`ubuntu_bootstrap` `ProductService`, reads `/cdrom/.disk/info`) | prints "<name> is installed and ready to use" | "Companion OS 26.04.1 LTS is installed and ready to use" |
| casper `25adduser` | launcher label "Install RELEASE": fields 1-2 with `-` as a blank, plus " LTS" when field 3 is `LTS` | "Install Companion OS" (no release, no LTS) |
| casper `scripts/casper` | field 1 lower-cased is the live user and host unless `casper.conf` sets `FLAVOUR` | no effect: the image sets `FLAVOUR` |
| subiquity `refresh.py` | the second word names the snap channel (`stable/ubuntu-OS`) | never acted on: `configure_snapd` switches channel only if the snap tracks `stable/ubuntu-<release>`, and the seed says `26.04/stable/ubuntu-26.04.1` |
| pollinate | the trailing serial | unchanged |

**Why the blank, and what the hyphen was.** An earlier revision wrote `Companion-OS` (a hyphen), so field 1 was one word, casper turned the hyphen back into a blank, and the launcher read "Install Companion OS 26.04.1 LTS". The comment said no user ever reads the file. That was wrong: the recorded 24.04.5 install shows "Companion-OS 24.04.5 LTS is installed and ready to use" on the last page. The product is spelt "Companion OS" everywhere a user reads it, so the blank won; the cost is the shorter launcher label and a latent second word.
`verify-iso.sh` reads the installer snap's channel from the image's own live `seed.yaml` and fails if it ever tracks `stable/ubuntu-<release>`, so the latent case cannot become real silently. To flip it back, five places change: `build-iso.sh` (the `sed` and the two greps), `verify-iso.sh` section 5, `tests/boot-media-plymouth.sh`, `tests/md5sum-txt.sh` and the `.disk/info` fixture in `tests/verify-installer-base.sh`.

<!-- figure: docs/ui/companion-os/ubuntu/NN-install-installer-done-page.png (the installer's last page with the product name) -->

The installer's first and review pages ("Welcome to Ubuntu", "Erase disk and install Ubuntu") are fixed text in the snap and stay Ubuntu's. The ISO volume id stays `Ubuntu 26.04.1 LTS amd64` because the signed GRUB finds the medium by it.
The done page with the new spelling on a booted installer: pending evidence (the string and the file are in the snap; the 24.04.5 page is recorded).

## 13. Build and test host rules

| Rule | Why | Evidence |
|---|---|---|
| The build host is Ubuntu 26.04. `build-iso.sh` stops otherwise; `CI_OS_ALLOW_OTHER_BUILD_HOST=1` overrides. | The branded GNOME Shell theme is built from the host's Yaru, which must be GNOME Shell 50's; `unmkinitramfs` is initramfs-tools 0.151's, a 3cpio program that extracts the four initrd segments flat (a 24.04 host's shell script does not). | [V] `build-iso.sh:117-133` |
| On Apple silicon with Docker Desktop, build in an **ARM64** `ubuntu:26.04` privileged container; the x86-64 chroot runs through Rosetta binfmt. | An amd64 `ubuntu:26.04` container failed once on that setup and the trigger was not isolated (another amd64 `ubuntu:26.04` container installed packages and ran `installed-boot.sh --no-boot` to the end on 2026-10-18; see [Building on a Mac](../guides/building-on-a-mac.md#why-arm64)): GNU tar 1.35 failed to create anything inside a directory it had just created ("Cannot mkdir ... Function not implemented"), so `dpkg-deb -x` fails. The same tar in amd64 `ubuntu:24.04` works; bsdtar and Python `tarfile` work; `--privileged` and `seccomp=unconfined` do not help. | [V] 2026-10-17; `stick/tests/secureboot/build-in-container.sh` has a nested create-and-extract preflight that stops with this explanation |
| **Never run systemd as PID 1 in a privileged container** on that setup. | It wipes the Docker VM's binfmt_misc registrations (Rosetta and the qemu handlers), after which amd64 containers fail. | [V] `binfmt-guard.log` in the scratchpad: 10 handlers re-registered at 08:28 and again at 08:29 on 2026-10-18 after a privileged systemd test |
| Time Machine local snapshots pin freed APFS space. Keep more than 40 GiB free on the Data volume. | They wedged Docker Desktop twice: deleting files freed almost nothing while `Docker.raw` was rewritten under the snapshots. | [V] the owner's session notes of 2026-10-14 and 2026-10-15 (not in the repository): about 145 GiB came back at once after thinning |
| QEMU on Apple silicon is TCG only (no HVF for x86-64 guests). Use `-cpu Nehalem` for the Ubuntu desktop. | On 24.04.5, Haswell crashed GNOME Shell (signal 11) under TCG, and so did the stock image; the default of `installed-boot.sh` is Nehalem. Not re-measured on 26.04.1. | [V] 24.04.5, [N] 26.04.1 |
| Firmware: `OVMF_CODE_4M.fd` and `OVMF_VARS_4M.fd` (and `.secboot.fd` / `.ms.fd` for Secure Boot), from `$CI_OS_OVMF_DIR` or `stick/tests/secureboot/out/firmware/`. | On 26.04 `ovmf` is a metapackage; the four files are in `ovmf-generic` 2025.11. | [V] `installed-boot.sh:153-161` |
| A QMP unix socket path is limited to 104 bytes on macOS: use a short `mktemp -d /tmp/ci-xx.XXXXXX`. | `sun_path` limit. | [V] `installed-boot.sh:285`, `lib/selftest.sh:22` |
| A graphical guest that you click in needs an absolute pointer: `-device qemu-xhci -device usb-tablet`. | Without it the mouse is unusable in a GUI install. | [V] `backends/cachyos/iso/tests/qemu-boot.sh:1131` |
| The test suites run on a stock Mac: bash 3.2 and BSD tools (no associative arrays, no `((VAR++))`, no `\b` in `git grep -E`). | `check-repo.sh` is run on the owner's Mac. | [V] `core/lib/check-repo.sh:40-43` and the header of each suite |

Recovery after a binfmt wipe, and the symptom check:

```bash
docker run --rm --platform linux/amd64 alpine uname -m   # prints x86_64 while amd64 emulation works
osascript -e 'quit app "Docker"'; open -a Docker          # restart Docker Desktop; handlers return
```

If a test needs systemd as PID 1, record the registrations first (`cat /proc/sys/fs/binfmt_misc/*` inside the VM namespace) so that they can be re-registered, newest entry last: the `rosetta` entry must be registered after `rosetta-wrapper`, because the newest entry is matched first.

Freeing space when `df` barely moves after deletes:

```bash
tmutil listlocalsnapshots /
tmutil thinlocalsnapshots / 60000000000 4
```

The first time `sudo` was used; the second time the command worked without it.

## 14. Smaller changes

| Change | Fact | Guard | Tag |
|---|---|---|---|
| `insmod all_video` removed from the live GRUB menu; the block insmods `gfxterm` and `png` only | The signed GRUB 2.14 CD image on 26.04.1 has 95 built-in modules and no `all_video` (only the string `feature_all_video_module`); under Secure Boot any non-built-in `insmod` is refused | `iso/tests/grub-live-menu-modules.sh` (G4 compares the committed list with the ISO's own binary), `verify-iso.sh` section 5, `stick/scripts/grub-builtin-modules.py` | [V] |
| `cdrom.sources` stays in the base layer | it is in the minimal layer; subiquity 26.04 expects it and removes it from the installed system itself. `apt-get update` in the chroot disables it, so `restore_cdrom_source` (`build-iso.sh:372`) puts it back | `verify-iso.sh` section 3g | [V] |
| `curl` is not on the stock image | `customize-chroot.sh` Steps 10b and 10d install it before first use | `verify-iso.sh` section "One-click automatic install" | [V] |
| i386 Vulkan libraries dropped | i386 is a configured foreign architecture but nothing uses 32-bit code; the old call ended in a command that hid every failure | `chroot/tests/customize-chroot-checks.sh` | [V] |
| LACT asset chosen by series (`lact-<v>-<rev>.amd64.ubuntu-2604.deb`) | the old `grep 'amd64.deb'` matched the Debian 13 asset, listed first | `lib/tests/lact-release.sh` (28 checks) | [V] |
| ROCm from the Ubuntu archive; `rocm-smi-lib` is not a package | see [the ROCm plan](../plans/strix-halo-rocm-companion-ubuntu.md) | `lib/tests/install-rocm-driver.sh` (38 checks; 42 against the real archive) | [V] looked up, [N] installed on hardware |
| Docker group for the first user | the 26.04.1 autoinstall schema takes `identity.groups: {append: [...]}`; the one-click installer appends `docker` when the image has the group | `chroot/tests/test_auto_install.py` | [V] code and schema, [N] a real run |
| GNOME Shell 50 theme: the branded blob goes over the Yaru gresource only | `/usr/share/gnome-shell/gnome-shell-theme.gresource` on 26.04 is the upstream theme (811,524 bytes, `gnome-shell-light.css` and friends) which the built-in session modes load; copying the Yaru-shaped blob over it would make `loadTheme()` throw | `lib/tests/shell-theme.sh` (17 checks), `core/render/tests/gresource-provenance.sh`, `verify-iso.sh` section 4d | [V] |
| The gresource build refuses a source that is not Ubuntu 26.04 with `yaru-theme-gnome-shell` 26.04.x | rebuilding from 26.04.5.1ubuntu gives the tracked blob byte for byte (sha256 `0a0ec5cd...c2f1`, 1,325,684 bytes) | `backends/ubuntu/packages/PROVENANCE-gnome-shell-theme.txt`, `core/render/render-gnome-shell-gresource.sh` | [V] |
| Plymouth: the stock `spinner/watermark.png` is a symlink; `plymouthd.conf` in the initrd is comment-only | `dpkg-divert --rename` moves the link itself; the verifier accepts ` -> target` after the stock copy and fails only an active `Theme=` line naming another theme | `verify-iso.sh` section 7, `tests/verify-installer-base.sh` | [V] |
| The installer-boot probe waits for `gdm-greeter`, not `gdm`, and its verdict is the condition the loop broke on | GDM 50's greeter session user is dynamic | `tests/lib/selftest.sh` (five scenarios) | [V] |
| Vendor apt suites | Docker, Tailscale, Cloudflare and GitHub CLI answer for `resolute`; the real build installed tailscale 1.104.1, cloudflared 2026.10.1, gh 2.102.0, companion-hub 0.3.5 and Ollama 0.40.3 | `verify-iso.sh` section 3c (47 passed) | [V] |
| Workflows build in an `ubuntu:26.04` container on an `ubuntu-24.04` runner (the runner label names the VM, not the build host); the base ISO is downloaded and verified (signed `SHA256SUMS`, pinned key, pinned sha256) | the 26.04 directory lists the 26.04.0 image beside 26.04.1, so "first line" picks the wrong file | `.github/workflows/build-companion-os-iso.yml` | [V] pieces, [N] a run on GitHub |
| Stick: the signed GRUB module set is read from the binary and checked by `fetch-signed-boot.sh`; boot-image path `companion-ubuntu-26.04-x86_64.img` | the disk GRUB image has 122 built-in modules, the CD image 95; all 14 the Stick needs are in both | `stick/crates/ci-stick/tests/grub_modules_tool.rs`, `cargo test` | [V] |

## 15. What has been run, and what is pending

| What | Result | Tag |
|---|---|---|
| One real `build-iso.sh` run on 26.04.1 (section 11) | completed; ISO 7,076,577,280 bytes; the finished image read back against its `md5sum.txt` (800 of 800) | [V] 2026-10-18, from a snapshot of the worktree taken during the fix pass, not from the committed HEAD |
| `VERIFY_BASE_ISO=<stock ISO> verify-iso.sh` on that image | 393 passed, 0 failed, nothing skipped. Section 3g: 59 passed | [V] |
| The same image with three verify fixes reverted in a copy of the script | 386 passed, 4 failed (the four defects the review found) | [V] |
| The image under OVMF Secure Boot | no `prohibited by secure boot policy` on the serial console; the themed GRUB menu draws | [V] |
| `tests/installed-boot.sh --iso <that image>` | PASS, see section 4. A disk assembled from the base layer, not a real install | [V] |
| `tests/verify-installer-base.sh` | 226 variants behaved | [V] |
| `tests/split-live-layer.sh` Part A in a privileged container | 207 passed, 0 failed, 1 skipped. Part B groups B1 B2 B9 B10 on the real merged rootfs after `remove_esb_seed`: 116 passed, 0 failed, 2 skipped | [V] |
| `tests/boot-media-plymouth.sh` with the real stock initrd | 103 passed, 0 failed | [V] |
| `chroot/tests/test_auto_install.py` (host, Python 3.14.7, run again for this page) | 121 tests OK | [V] |
| `core/lib/check-repo.sh` on a clean copy of `git ls-files` | exit 0 at the time of the cross-area pass; the final gate is the orchestrator's | [V] earlier, rerun at the gate |
| **A real subiquity install of a built Ubuntu 26.04.1 image, then a boot of the installed disk** (normal installer and the one-click path) | not recorded | **pending evidence**: a `CAPTURE.md` and logs in the capture directories of the Ubuntu run (`shots/ubuntu/` and `ubuntu/` in the session scratch; their text records are copied into [`docs/evidence/`](../evidence/README.md) and the frames into `docs/ui/companion-os/ubuntu/` when the row is run); it confirms sections 3, 4, 10 and 12 if the installed disk reaches GDM, `ssh` has host keys, the done page reads "Companion OS 26.04.1 LTS", and `journalctl -u casper-md5check` on the live medium says "no errors found" |
| Docker in live sessions on a 26.04.1 image (`stick/tests/qemu/docker-live.sh`) | not run | pending evidence |
| Settings > About rendering the SVG in GNOME 50 | not looked at | pending evidence: a screenshot of Settings > About in the capture directory |
| GitHub workflows | none has run | [N] |

```bash
# the verification that was run, for a built image
VERIFY_BASE_ISO=ubuntu-26.04.1-desktop-amd64.iso backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-1.0-amd64.iso
backends/ubuntu/iso/tests/installed-boot.sh --iso output/companion-os-1.0-amd64.iso
```

## 16. Defects noticed while writing this page

These were found while writing this page and sit in code or documents outside it (item 5 is partly fixed; items 3 and 4 were fixed afterwards, in the documentation pass of 2026-10-18).

1. `backends/ubuntu/iso/tests/lib/installed-boot-disk.sh:374` writes an empty `/etc/machine-id`; the real installer writes the live session's valid one. The test therefore models a first boot and cannot see the `ConditionFirstBoot` defect of section 10. It should write a valid ID (32 lowercase hex digits and a newline, mode 0444) and its probe should report the SSH host keys and the rebrand stamp.
2. `backends/ubuntu/chroot/tests/first-boot-units-boot.sh` creates `--privileged` containers with systemd as PID 1 (`docker create --privileged --cgroupns=host ... /sbin/init`, line 140). On Docker Desktop for Mac that wipes the binfmt registrations (section 13). The header says nothing about it.
3. **Fixed.** `backends/ubuntu/iso/README.md` said no complete Companion OS image had been built on 26.04.1. It now gives the measured 7,076,577,280 bytes of the build of section 11.
4. **Fixed.** `backends/ubuntu/iso/README.md` listed "Installer whitelabel" among the things `customize-chroot.sh` does, but Step 7 of the script configures nothing (the installer snap ignores `whitelabel.yaml`). The list now says there is no such step.
5. `docs/architecture/headless-setup.md`: the stop-gap landed in `b882e00`. The two work-package rows of its section 0 now say so; the heading of its section 2.7 ("working tree, uncommitted, read on 2026-10-17") and the State column of its work-package table in section 8 still say "working tree".
6. `docs/architecture/headless-setup.md` section 4.8 gives "the Ubuntu 20.04 floor" as the reason for requiring Python 3.8. No supported edition is that old (Ubuntu 26.04 has Python 3.14); the floor is a portability choice now, not a requirement of a target.

## 17. Open decisions that concern the Ubuntu edition

| Decision | State |
|---|---|
| ROCm source on Ubuntu 26.04: the archive's 7.1 or AMD's 10.0 repository | open, see [the ROCm plan](../plans/strix-halo-rocm-companion-ubuntu.md) |
| The 8 GiB size gate ties the build to the 64 GB Stick | owner decision; `VERIFY_MAX_ISO_BYTES` overrides |
| Strix Halo GTT boot parameters (`strix-halo-boot-params.sh`) exist only in this backend | CachyOS has no equivalent |

See also: [ubuntu-iso-layers.md](ubuntu-iso-layers.md) (the layer split), [one-click-install.md](one-click-install.md) (the automatic installer), [docker-in-live-sessions.md](docker-in-live-sessions.md), [tier-b-tools.md](tier-b-tools.md) and `backends/ubuntu/iso/README.md`.
