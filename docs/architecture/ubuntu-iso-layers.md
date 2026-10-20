# Ubuntu ISO layers: what the installer installs, what only the live session sees

> Private & Confidential — Property of Lifescope Inc. Do not distribute.

Scope: the Ubuntu backend's ISO (`backends/ubuntu/iso/`), built from the stock Ubuntu 26.04.1 LTS desktop ISO. This page explains the three-layer root
filesystem of that ISO, why packing the whole customized rootfs into the first layer made the **installed** system unbootable, how the build splits the
rootfs into an installer base layer and a live-only layer, what is in each, how `verify-iso.sh` section 3g keeps the split honest, how to extend the
table, and which tests prove what. The CachyOS edition is archiso based and does not use these layers.
What changed between 24.04 and 26.04.1 is in [ubuntu-2604-port-notes.md](ubuntu-2604-port-notes.md).

Evidence tags: **[V]** verified (run, or read in the cited file or on the real stock ISO), **[I]** implemented and tested in parts, not proven end to end,
**[N]** not implemented or not checked. Measurements of Ubuntu 24.04.5 are kept only where they explain a design decision and are labelled
"retired baseline (24.04.5)".

**Status of this page: 2026-10-18.** The defect and its cause were found by a complete GUI install of the 24.04.5 based v7 image in QEMU followed by offline
inspection of the installed disk (section 2). The split (section 4) is in `build-iso.sh` and `scripts/lib/split-live-layer.sh` and was ported to 26.04.1.
Section 7 says, row by row, what has been run. What has been shown on 26.04.1: one real `build-iso.sh` run produced an ISO (7,076,577,280 bytes) whose three
layers the build itself proved equal to the rootfs; `verify-iso.sh` passed 393 checks, 59 of them in section 3g; a disk assembled from its base layer
booted to the branded GDM greeter. What has **not** been shown: **no real subiquity install of a 26.04.1 build, and no boot of the disk it writes, is recorded**
(section 7, pending evidence).

## 1. In one paragraph

subiquity installs exactly one stack of layers, the one named by the chosen entry of `casper/install-sources.yaml` (`minimal.squashfs` for the entry the Companion
ISO defaults to). On a stock Ubuntu ISO everything that belongs to the live session alone (the `casper` package and its initramfs hook, the live session's dconf
overrides, the installer's own snap, the live image's cloud-init, getty and udisks settings) sits in a third layer, `minimal.standard.live.squashfs`, that the
installer never copies. Until the split, `build-iso.sh` packed the whole merged rootfs (all three stock layers plus the Companion customization) into
`minimal.squashfs` and shipped two empty placeholders for the other two layers. The installer therefore copied the live-only content to the disk, and `casper`'s
initramfs hook made every initrd regenerated on the installed system boot the live medium: **the installed system stops at "Unable to find a medium containing a
live file system".** A boot of the live ISO cannot show this, because the live session never looks at the installed disk.

## 2. Evidence (2026-10-15 and 16, v7 image, retired baseline 24.04.5)

A complete GUI install of the v7 ISO (`companion-os-1.0-amd64.iso`, 7,692,484,608 bytes, `casper/minimal.squashfs` 5,640,392,704 bytes) into a QEMU NVMe disk,
then offline inspection of the installed disk and of the build's merged chroot:

| Observation | Where it was seen |
|---|---|
| The first boot of the installed disk loops on `/init: line 38: can't open /dev/sr0: No medium found` and ends at "Unable to find a medium containing a live file system / Attempt interactive netboot from a URL? yes no (default yes)" | screenshot of the installed boot |
| The installer installed from one layer only: curtin's source stack was `['///cdrom/casper/minimal.squashfs']` | installer log |
| The installed disk has the `casper` package in `var/lib/dpkg/status`, `/etc/casper.conf`, `/etc/initramfs-tools/conf.d/casperize.conf` (`export CASPER_GENERATE_UUID=1`) and `default-layer.conf` (`LAYERFS_PATH=minimal.standard.live.squashfs`) | offline inspection |
| Every initrd regenerated in the target holds casper's scripts and `conf/conf.d/default-boot-to-casper.conf` (`if [ -z "$BOOT" ]; then export BOOT=casper`). casper's hook writes that file when `CASPER_GENERATE_UUID` is set, which `casperize.conf` does | the regenerated initrds; `usr/share/initramfs-tools/hooks/casper` of the merged chroot |
| Also on the disk, from the same layer: `livecd-rootfs.gschema.override` (the live session's dconf overrides, compiled into `gschemas.compiled`); the installer snap `ubuntu-desktop-bootstrap` and `core22` with AppArmor profiles, a desktop entry, mount and service units and seed entries; `/etc/subiquity/kernel-meta-package`; `/etc/cloud/cloud.cfg.d/06_quiet.cfg`; `/etc/apt/preferences.d.save` (the stock standard layer has this directory too, with two flat `ubuntu-pro-esm-*` files; the live-only part is the nested `preferences.d` copy the live layer adds) | offline inspection |
| The merged chroot also carries the live image's rewrites of files the installed system shares: `/etc/cloud/cloud.cfg` creates a user `installer` (shell `/usr/bin/subiquity-shell`, `NOPASSWD:ALL`) and sets `ssh_pwauth: yes`; `getty@tty1.service` is masked to `/dev/null`; `systemd-networkd-wait-online` is a symlink to `/bin/true`; `udisks2-inhibit.service` is present | `/v/w/chroot` of the v7 build volume |
| subiquity's `install.py` has no package-removal step | the installer snap, rev 680 (24.04.5); rev 665 on 26.04.1 has none either |
| A copy of the installed disk repaired offline (purge `casper`, delete the two initramfs configuration files and the livecd override, recompile the schemas, `update-initramfs -u -k all` in a chroot) reached the GDM greeter in QEMU: the user's login screen with the Companion mark, one frame. Whether the session is entered was not looked at | screenshot of the repaired boot |
| `verify-iso.sh` before section 3g passed this image: it asserted that Companion content was present, not that live-only content was absent | rerun with section 3g on the v7 ISO: 3g failed 31 of its 40 checks |

The logs and screenshots are in the research scratch directory of the session that produced them, not in the repository.

<!-- figure: docs/ui/companion-os/ubuntu/NN-retired-installed-boot-no-medium.png (the retired baseline failure: the installed v7 disk stopping at "Unable to find a medium containing a live file system") -->

### Why the build did not see it

`build-iso.sh` carried a comment in `main` saying that a `filesystem.manifest-remove` is not needed for Ubuntu 24.04 because the original ISO ships none and
"subiquity handles package removal internally". Both halves are wrong for the merged design. Subiquity has no removal step (above). The stock ISO needs no
removal list because it never installs the live layer; once the live layer's content is merged into the layer the installer does install, nothing removes it.
The comment was true of the stock layout and false of the layout this build made. It has been rewritten.

## 3. The stock layer model

### 3.1 Stacking (the same rule on 24.04.5 and 26.04.1)

casper and curtin stack layers by the same rule: a layer path such as `minimal.standard.live.squashfs` stands for the stack of the prefixes of its dotted name,
bottom first: `minimal.squashfs`, `minimal.standard.squashfs`, `minimal.standard.live.squashfs`. casper: `usr/share/initramfs-tools/scripts/casper`
(`LAYERFS_PATH` handling, lines 602-647 of casper 26.04.2; the overlay is `lowerdir=live:std:min`, topmost first). curtin: `_get_image_stack` in `commands/extract.py`
of the installer snap. [V] read on both releases.

**Live session.** casper reads `LAYERFS_PATH` (the `layerfs-path=` kernel parameter, or the default in the initrd's `conf/conf.d/default-layer.conf`, a copy of
`/etc/initramfs-tools/conf.d/default-layer.conf` of the image the initrd was built in: `LAYERFS_PATH=minimal.standard.live.squashfs`) and mounts the layers with
overlayfs. The stock boot menus carry no layer parameter: their kernel lines are `linux /casper/vmlinuz  --- quiet splash`. The live initrd is the stock one
plus a small cpio overlay with Companion's `casper.conf` and Plymouth files, so the live boot does not depend on casper inside the squashfs.

**Installer.** subiquity (the `ubuntu-desktop-bootstrap` snap) reads `casper/install-sources.yaml`. For the chosen entry curtin builds the stack from the
entry's `path` by the same prefix rule, mounts it read-only with overlayfs and copies it to the target with `rsync -aXHAS --one-file-system`. The live layer is
named by no entry, so it is never installed. On a stock install curtin then installs the kernel and the bootloader from the ISO's apt pool (the live layer carries
its own copies for the live boot).

That is the whole reason the stock layout is safe: **nothing in the live layer can reach the disk, whatever it contains.**

### 3.2 Ubuntu 26.04.1 (measured on the stock ISO)

Stock `ubuntu-26.04.1-desktop-amd64.iso`, 6,482,409,472 bytes. Packages from each layer's own dpkg status and manifests. [V] 2026-10-17; the same
facts can be re-read with the commands in section 6.

| Layer | squashfs bytes | stock `.size` | Added packages | What is in it | Seen by |
|---|---|---|---|---|---|
| `minimal.squashfs` | 3,432,136,704 | 6,506,545,152 | 1,537 debs, 13 snaps | the minimal desktop (GNOME Shell 50.1, GDM 50.1), the kernel `7.0.0-30` with modules, headers and `linux-generic-hwe-*`, `linux-firmware*`, **dracut 110-11 and a dracut-built `/boot/initrd.img-7.0.0-30-generic`**, `grub-pc`, snapd and the 13-snap seed (core24, snapd, firefox, snap-store, firmware-updater, gnome-46-2404, mesa-2404, gtk-common-themes, bare, hwctl, desktop-security-center, prompting-client, snapd-desktop-integration), cloud-init, `sudo` and `sudo-rs`, `coreutils` and `rust-coreutils`, `/etc/apt/sources.list.d/cdrom.sources` | live session, **installer** |
| `minimal.standard.squashfs` | 590,053,376 | 3,443,830,784 | +228 debs, +1 snap (thunderbird), 6 whiteouts | LibreOffice, Rhythmbox, Shotwell, Remmina, Transmission, Simple Scan, Deja Dup, File Roller, Calendar, restic, the `ubuntu-desktop` meta-package | live session; installer entry 2 (the stack minimal + standard) |
| `minimal.standard.live.squashfs` | 793,112,576 | 4,168,642,560 | +51 debs, **-2 (dracut, dracut-core)**, +1 snap | `casper` 26.04.2, `finalrd`, **initramfs-tools 0.151**, `user-setup`, `localechooser-data`, cryptsetup, lvm2, mdadm, btrfs, xfs, jfs, zfs, gparted, `grub-efi-amd64-signed`, `shim-signed`, `efibootmgr`, input-method engines, realmd, adcli, cifs-utils; the installer snap `ubuntu-desktop-bootstrap` rev 665 (base `core24`, classic); a UC-style snapd seed of the TPM-encryption variant; **75 whiteouts** of dracut and of the dracut-built initrd | **live session only** |

The stacked live system has 1,814 debs and 15 snaps; the minimal layer alone, which is what a stock install copies, has 1,537 debs and 13 snaps (1,765 and 14 with the standard layer).
The ISO has 41 layer files in all: the three above, 18 language layers (`minimal.<lang>`, `minimal.standard.<lang>`) and 20 `enhanced-secureboot` layers for Ubuntu's TPM
encryption variant. All are xz squashfs with 128 KiB blocks, exportable, with xattrs, and they keep hard links. `casper/` holds a `.size`, `.manifest` and
`.manifest.full` file for every layer and has neither `filesystem.size` nor `SHA256SUMS`; the build writes both.

**The live layer is thin on 26.04.1.** It lists 2,883 paths below the root (24.04.5: 56,270), because the kernel, firmware, bootloaders and disk tools moved into
`minimal.squashfs`. 2,542 of those exist in neither lower layer and 342 rewrite or whiteout a lower path. 76 are character devices: the 75 dracut whiteouts and lvm2's
`/dev/mapper/control`. 497 of the 2,542 are owned by no package: 372 are dpkg bookkeeping or the generated state of packages that stay, and 125 are live-only; the
`rm` and `restore` rows of section 4.3 remove those 125. [V] library header, `tests/split-live-layer.sh` group B1.

**dracut.** The stock installed system (the minimal layer) is dracut based. The live layer swaps dracut for initramfs-tools. The merged build therefore gives an
initramfs-tools based base layer. That is a decision, with a pin and a test, in section 4.5.

### 3.3 Retired baseline (24.04.5)

| Layer | What the stock ISO kept in it | Packages (24.04.5) | Compressed | Seen by |
|---|---|---|---|---|
| `minimal.squashfs` | the minimal desktop: GNOME, the system, the snap seed (firefox, snap-store, firmware-updater, gnome-46-2404, mesa-2404, gtk-common-themes, core24, bare, snapd-desktop-integration) | 1,488 | 2.24 GB | live session, **installer** |
| `minimal.standard.squashfs` | the standard desktop apps (deja-dup, file-roller, duplicity, thunderbird seed, ...) | +222 | 0.56 GB | live session, installer entry "Ubuntu" |
| `minimal.standard.live.squashfs` | `casper` and `finalrd`, `user-setup`, `localechooser-data`, the kernel (`linux-image-7.0.0-31-generic`), `linux-firmware*`, the bootloaders, the disk tools, the ibus engines, microcode, the installer snap with `core22`, and the live image's settings | +113 packages, +2 snaps | 1.22 GB | **live session only** |

Its live layer listed 56,271 entries (the root among them): 55,994 existed in neither lower layer, the live layer's packages owned all of those but 905, of which 781 were
bookkeeping and 124 live-only, and it rewrote 66 paths a lower layer has. The installer snap was rev 680.

## 4. The split

### 4.1 What the merged design did

`extract_squashfs` unpacks the three stock layers, in order, into one chroot `C` and applies the layers' whiteouts. `customize-chroot.sh` customizes `C`. The old
`repack_squashfs` packed all of `C` into `minimal.squashfs` and wrote two empty placeholder layers (directories only, modes copied from `C`, see
`make_placeholder_layer`). That is right for the live session (the placeholders add nothing, so the stack is `C`) and for the Companion content, which belongs in both.
It also put everything the stock ISO keeps in the live layer into the layer the installer copies.

### 4.2 What the build does now

Before the split `repack_squashfs` and `main` do four things to the casper directory and to `C` (all in `build-iso.sh`):

- `restore_cdrom_source` (line 372) puts `/etc/apt/sources.list.d/cdrom.sources` back if the chroot's `apt-get update` disabled it, and fails if there is none or two copies. subiquity 26.04 expects it in the installed layer.
- `remove_esb_seed` (line 397) deletes the snapd seed of the TPM-encryption variant from `C`, so that it is in neither layer (0.66 GB that does not compress).
- `remove_stock_layer_files` (line 483) removes every `minimal*` file of `casper/`, and `assert_casper_layer_files` (line 494) requires exactly the twelve files of the three layers afterwards.
- `write_install_sources` (line 516) writes the version 2 `install-sources.yaml` with the stock `kernel:` block (port notes, section 3).

Let `C` be the customized merged rootfs. `repack_squashfs` then calls `ci_split_live_layer` (`scripts/lib/split-live-layer.sh`), which produces:

| Layer | Content | Role |
|---|---|---|
| `B` = `minimal.squashfs` | `C` with the live-only content removed | **the only layer the installer installs** (`install-sources.yaml` names `minimal.squashfs` alone, no language layers) |
| `S` = `minimal.standard.squashfs` | empty placeholder (directories only, modes mirrored, `make_placeholder_layer`) | stays: the second entry of `install-sources.yaml` names it |
| `L` = `minimal.standard.live.squashfs` | exactly what must be stacked on `B` and `S` to give `C` | **live session only** |

```
 live session (casper, overlayfs, topmost first)        installer (curtin, either entry of install-sources.yaml)
   L   minimal.standard.live.squashfs   live-only         (named by no entry: never installed)
   S   minimal.standard.squashfs        empty
   B   minimal.squashfs                 installer base  -> copied to the disk with rsync
   ==  C, what the live session showed before the split (checksums, modes, owners, links, devices, xattrs; the paths mksquashfs leaves out apart)
```

How, in the library's words: mount an overlayfs with `C` as the read-only lower directory and a scratch directory `U` as the upper one; apply the rows of the
table (section 4.3) inside the merged view (a chroot for `dpkg --purge`, `glib-compile-schemas` and `apt-get check`); pack `B` from the merged view with the
build's long-standing `mksquashfs` options (`-comp xz -b 1M`); derive `L` from `U`: for every path the removal changed or deleted, `L` carries `C`'s version, for
every path the removal created that `C` lacks, `L` carries a whiteout (a character device 0:0); `L` is staged with rsync from `C` so modes, owners, symlinks and
extended attributes are `C`'s. Directory modes are kept exactly: a directory present in several layers takes its mode from the topmost one (the `/tmp` trap that
`make_placeholder_layer` and `verify-iso.sh` section 3e guard against).

The build then refuses to continue unless two checks pass (`ci_split_verify_layers`, run on the three **packed** layers): the base layer holds none of the live-only
content (`ci_split_assert_base_tree`, an independent list of paths and packages), and the stack `L` over `S` over `B`, mounted the way casper does, equals `C`
(rsync comparison by checksum: content, modes, owners, symlinks, device nodes, extended attributes). Two more guards stop the build: a `restore` row refuses to run
over a path the build itself customized (the rootfs's copy must still be the stock live layer's, or restoring the stock standard copy would silently drop the
customization from the installed system while the live session kept it), and dpkg and apt must find the package database consistent after the removal
(`apt-get check`, `dpkg --audit`). Then `ci_split_write_metadata` writes the true `.size`, `.manifest` and `.manifest.full` files (4.4).

The kernels and the bootloader stay in `B`: the minimal layer already ships the kernel and GRUB, and the installer finds a kernel installed and only has curtin generate
the initrd, which now has no casper in it.

### 4.3 What is live-only (the table to extend)

The authoritative table is `ci_split_table` in `scripts/lib/split-live-layer.sh` (line 135): one row per package to purge or path to remove or restore, with the reason
beside it. `verify-iso.sh` section 3g keeps its own copy as data (`BASE_FORBIDDEN`, `LIVE_ONLY_PKGS`, `LIVE_REQUIRED`), the library's invariant list
(`ci_split_assert_base_tree`) a third. They are written independently on purpose and `tests/verify-installer-base.sh` fails if the library lists a path that section 3g
does not. By group (rows new on 26.04.1 are marked **new**):

| Group | What | Why it must not be in `B` |
|---|---|---|
| casper | packages `casper` and `finalrd` (the directory `/usr/share/finalrd` is shared with `mdadm`, which stays, and is not on the list); `/etc/casper.conf`, `/usr/lib/casper`, `/usr/share/casper`, `/usr/sbin/casper-*`, `casper.service`, `casper-md5check.service` and their enable links, `/usr/share/initramfs-tools/{scripts,hooks}/casper*` | the hook turns every regenerated initrd into a live boot; `finalrd` exists for casper (a live system needs it to unmount its squashfs root at shutdown) |
| casper initramfs configuration | `/etc/initramfs-tools/conf.d/casperize.conf` and `default-layer.conf` | written by livecd-rootfs for the live initrd; the hook reads them. Removed even though the package is gone, so a returning hook finds nothing |
| live dconf overrides | `usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override`, then `glib-compile-schemas` (the `schemas` row proves the compiled file is current) | an "installer only" session: universal-access status always shown, dock not fixed, desktop-icons extension disabled |
| the installer | `ubuntu-desktop-installer.service` (user unit and its enable link; since 2026-10-19 `customize-chroot.sh` Step 7b removes the enable link from the rootfs so the live session does not open the stock window by itself: the `rm` row is then a no-op, the link is in neither layer, the unit file stays in the live layer, and section 3g fails on any wants or requires link of it there [I]), `subiquity_config.mount` and the device drop-in that wants it, `/etc/subiquity` (absent on 26.04.1; the row is kept, harmless), the installer snap `ubuntu-desktop-bootstrap` with everything snapd generated for it (the names are the live seed minus the standard seed; its base `core24` is the system's own and stays) | a launcher, mounts and profiles for an installer that is not installed |
| snapd state | `var/lib/snapd/{state.json,system-key,seed/seed.yaml,seed/assertions,assertions,apparmor/profiles,cgroup,cookie,desktop/applications,inhibit,mount,seccomp/bpf,sequence}` and `var/cache/snapd/aux`: **restored** to what the stock standard stack (minimal + standard) has | each stock layer holds a complete, self-consistent snapd preseed run; the live layer's covers the installer snap with other cookies. Mixing them breaks the cookies, and a `state.json` that knows a snap whose file is gone makes snapd fail to seed |
| the TPM-encryption seed (**new**) | `rm var/lib/snapd/seed/systems`, then `seed-orphans`: every file in `seed/snaps` that the restored `seed.yaml` does not name (`pc-kernel`, `pc`, a second firefox revision, two nvidia components) | 0.66 GB the installed system's snapd never seeds. The build also removes it from `C` (`remove_esb_seed`), so it is in neither layer |
| settings in shared files | `/etc/cloud/cloud.cfg` and `/usr/lib/systemd/systemd-networkd-wait-online`: **restored** to the stock standard stack's | the live copy of `cloud.cfg` creates the user `installer` (shell `subiquity-shell`, `NOPASSWD:ALL`) with `ssh_pwauth: yes`; the live image replaces the real `systemd-networkd-wait-online` with a symlink to `/bin/true` |
| live-session security settings (**new**) | `/etc/polkit-1/rules.d/10-allow-installer-wait-on-snap.rules`, `/etc/sysctl.d/20-apparmor.conf` | the rule grants snapd's configuration to every subject (its header says "ONLY AVAILABLE ON THE LIVE SYSTEM"); the sysctl file sets `kernel.apparmor_restrict_unprivileged_userns = 0`, switching off Ubuntu's default |
| other live-image files | `/var/lib/cloud/seed/nocloud`, `/etc/cloud/cloud.cfg.d/06_quiet.cfg`, `/etc/apt/preferences.d.save/preferences.d`, `/root/packages.chroot`, `getty@tty1.service` (masked to `/dev/null` for casper's own login), `udisks2-inhibit.service` (a udev rule that makes every block device ignored by udisks, so the live session does not automount its own medium) with its links and the dangling `media-filesystem.mount` link, `etc/systemd/system/snapd.service.d/snapd-snap-reexec.conf` (moved: all lines commented on 26.04.1), `etc/systemd/system/display-manager.service.d/wait-for-snapd-seeding.conf` (**new**), the journald drop-ins that make the journal readable inside the installer snap | written by livecd-rootfs for the live session; on the installed system they hide devices, remove the tty1 login prompt, hold the login screen or leave a way in |

What stays in `B` although the stock live layer carries it: **kernels, firmware, microcode, bootloader and disk-tool packages** (a disk install must boot without the
network, and the tools are useful on the disk), the input-method engines (typing Korean, Japanese, Vietnamese or Thai works offline), `user-setup` and
`localechooser-data` (inert data), and the paths that belong to those kept packages or are state their scripts generated (modules.dep, `/etc/default/grub`, `mdadm.conf`,
crypttab, the zfs rc links, alternatives, caches). On 26.04.1 most of these packages are in the minimal layer already.

Why the table is believed complete (the derivation is in the library's header, and `tests/split-live-layer.sh` group B1 repeats it on the real layers): see the numbers in
section 3.2. The 125 live-only paths are the `rm` rows; the 342 rewritten paths are generated state that package scripts regenerate, the snapd preseed state
(the `restore` rows) and the two live settings above. That the derivation found everything is an argument, not a proof (section 8).

The apt pin backup row is narrow on purpose, in the library and in section 3g alike: the stock **standard** layer (installed by a stock "Ubuntu" install) carries
`/etc/apt/preferences.d.save/ubuntu-pro-esm-*`, so those flat files stay; only the live layer's nested `preferences.d.save/preferences.d` is live-only.

### 4.4 Metadata that must stay true

| File | Rule | Written by | Checked by |
|---|---|---|---|
| `casper/minimal.size`, `minimal.standard.size`, `minimal.standard.live.size` | the size of the layer's tree, `du -sx --block-size=1` (`0` for the placeholder) | `ci_split_write_metadata` | 3g: a plausibility interval from the layer's own listing |
| `casper/filesystem.size`, `install-sources.yaml` `size:` | whole live stack, and the installed base | the same, `repack_squashfs` | (not checked) |
| `casper/minimal.manifest`, `minimal.standard.manifest`, `minimal.standard.live.manifest` | the stock "diff" shape: `+package<TAB>version` lines (and `+snap:name<TAB>channel<TAB>revision`); `B`'s packages, none, and the packages `L` adds | `ci_split_write_metadata` | 3g: set equality with the dpkg status files |
| `casper/minimal.manifest.full`, `minimal.standard.manifest.full`, `minimal.standard.live.manifest.full` | the whole stack up to that layer: packages, then `snap:` lines | `ci_split_write_metadata` | 3g: set equality with the dpkg status of the stack, and with the seed's snaps |
| `casper/install-sources.yaml` | version 2, the stock `kernel:` block, both entries, `preinstalled_langs: []`, no enhanced-secureboot variations, every named path exists | `write_install_sources` | 3d |
| `casper/SHA256SUMS`, `/md5sum.txt` | regenerated after the layers are written | `repack_squashfs`, `md5sum-txt.sh` | 8 |

The `.size` check is deliberately an interval, not an equality. The number the build writes is `du -sx --block-size=1` of the mounted layer
(`ci_split_verify_layers`), and a listing cannot reproduce `du` exactly: a hard link is listed once per name, and **every snap blob on 26.04.1 has two names that are one inode**
(`/var/lib/snapd/snaps/X.snap` and `/var/lib/snapd/seed/snaps/X.snap`). In the stock minimal layer the listing sums to 9,055,157,103 bytes and `du` says 6,156,994,048 (ratio 0.68).
`layer_size_bounds` in `verify-iso.sh` therefore leaves one name of every blob out of its lower bound (80 % of the rest) and counts both in the upper bound (4 KiB-rounded sizes, +20 %).
The stock `.size` files are build-system numbers unrelated to `du` (the standard layer's 3,443,830,784 is 2.05 times its `du` of 1,682,590,720, the live layer's 4,168,642,560 is 4.7 times its `du` of 888,631,296), which is why the build overwrites them. The interval catches `0` for a layer that is not empty and another layer's number; it cannot catch a few per cent of drift.
(Retired baseline (24.04.5): `du` of the split base was 12,728,797,184 bytes against 12,689,013,551 of regular-file sizes in its listing, because that ISO had no such links.)

### 4.5 The initramfs generator

The base layer is initramfs-tools based on purpose, and apt is pinned so that it stays so. The reasoning, the cost and the tests are in
[ubuntu-2604-port-notes.md](ubuntu-2604-port-notes.md), section 4; the rows of the table do not touch it. `verify-iso.sh` section 3g asserts initramfs-tools installed, `dracut` and
`dracut-core` absent, and `/etc/apt/preferences.d/ci-os-no-dracut` pinning both to -1.

### 4.6 Sizes on a real build

One real build on 2026-10-18 (port notes, section 11): `minimal.squashfs` 5,537,636,352 bytes (1,874 packages), `minimal.standard.live.squashfs` 117,485,568 bytes
(249 paths staged from `C`, no whiteouts), the ISO 7,076,577,280 bytes, 1,513,357,312 bytes under the 8 GiB Stick boot-slot gate of `verify-iso.sh` section 9. [V]

### 4.7 How verify-iso.sh section 3g enforces the split

The build proves the split while `C` exists (`ci_split_verify_layers`). Section 3g (`verify-iso.sh:599`) proves, from the finished ISO alone, that what ships still has the split's properties. It reads the base layer
with `unsquashfs -ll` plus a few extracted files, and the live layer, the placeholder, the `casper/` metadata and the boot menus. On the real 26.04.1 image it passed 59 checks: [V] 2026-10-18

| Group | What is asserted | Checks |
|---|---|---|
| readable | the base layer's listing and dpkg status could be read (otherwise every "has no" check below would pass for nothing) | 1 |
| forbidden paths | the 18 `BASE_FORBIDDEN` rows of section 4.3: nothing matches in the base layer | 18 |
| host keys | no `/etc/ssh/ssh_host_*_key[.pub]` (the same private keys on every install) | 1 |
| live-only packages | `casper` and `finalrd` are in no dpkg state in the base status | 2 |
| snapd seed and state of the base | `seed.yaml` names no installer snap, names only files the base holds, and `seed/snaps` holds only files it names; `state.json` knows no installer snap | 4 |
| shared files restored | `/etc/cloud/cloud.cfg` is not the live session's (no `subiquity-shell`); `systemd-networkd-wait-online` is not a symlink | 2 |
| initramfs decision | initramfs-tools installed; `dracut` and `dracut-core` absent; `ci-os-no-dracut` pins both to -1 | 4 |
| ISO pool source | `cdrom.sources` present with `URIs: file:///cdrom`; no `cdrom.sources.disabled` left over | 2 |
| live layer | not a placeholder; the 14 `LIVE_REQUIRED` paths are there (one check); its `seed.yaml` names the installer snap; no `seed/systems`; `seed/snaps` holds only files its seed names; the live `cloud.cfg`; casper installed in its dpkg status | 7 |
| standard layer | still the empty placeholder | 1 |
| `.size` | one plausible-interval check per layer (4.4) | 3 |
| manifests | the three diff manifests equal the dpkg status (the base's, none, the live delta); the three `.manifest.full` files equal the stack up to each layer; two snap-line comparisons against the seeds; the live manifest lists the live layer's casper version; `minimal.manifest` has no casper | 10 |
| boot menus | the kernel lines of `grub.cfg` and `loopback.cfg` are the stock allow-list; with `VERIFY_BASE_ISO` they equal the base ISO's | 4 |

Added 2026-10-19 (not yet run on an image): a live-layer check that fails on a `*.wants/ubuntu-desktop-installer.service` or `*.requires/` link, or an autostart entry for the installer, because the live session then opens the stock wizard in front of the Companion dialog (`customize-chroot.sh` Step 7b removes the stock link; the unit file stays and is still a required live-layer path). It is the live-layer group's eighth check, so section 3g has 60 checks on an image with it.

Neighbours that belong to the same property: section 3d (the twelve `casper/` files, version 2 `install-sources.yaml`), 3e (directory modes: `/tmp` stays `1777`), 8 (`md5sum.txt`) and 9 (the 8 GiB gate).
Each row and check is shown failing by a planted defect in `tests/verify-installer-base.sh`, and the test is itself run against weakened copies of the script.

## 5. How to extend the live-only table

1. Find the content. List the stock live layer (`unsquashfs -ll casper/minimal.standard.live.squashfs`) and the built base layer; anything the live layer ships that the
   installed system should not have goes on the table. The installed-boot test (section 6) shows what an installed system really got.
2. Add the row to `ci_split_table` with its reason: `purge|<package>` for a package (a removed package must leave no dpkg stanza), `rm|<path>` for a path,
   `restore|<path>` for a file the live image rewrote in place (the stock standard stack's copy comes back).
3. Add the path or package to the library's invariant list (the `gone` array in `ci_split_assert_base_tree`; the packages are named in its loop;
   `CI_SPLIT_LIVE_REQUIRED` for something the live layer must now hold). Keep both arrays in the layout they have: `tests/verify-installer-base.sh` (the drift guard) and
   group A4 of `tests/split-live-layer.sh` cut them out by their opening and closing lines, and the library's comment says why no comment may quote those lines.
4. Add the same row to `verify-iso.sh` section 3g: a `BASE_FORBIDDEN` row (`label|extended regex` matched against the whole path of a listing entry), an entry in
   `LIVE_ONLY_PKGS`, or a `LIVE_REQUIRED` row if the live layer must now carry something. Run the row against the stock layers (the `.ll` listings of a base ISO) to see
   that it matches nothing in the stock minimal and standard layers: a row that does is not live-only.
5. Add a variant to `tests/verify-installer-base.sh` (a `mutate` case that plants the path in the base tree and names the text of the FAIL line it must produce) and run
   the test. Every entry of the library's two lists becomes a variant of its own without any edit (`drift:<path>` for the base, `driftlive:<path>` for the live layer), so a
   path the library calls live-only that section 3g lacks makes the test fail at once. The reverse is allowed: section 3g may be stricter than the library.
6. Update the table in 4.3.

If the content is owned by a package, purging the package is the removal; deleting only its files leaves dpkg's database listing it. A new base ISO (a point release)
starts with the audit: `SPLIT_TEST_ONLY="B1"` on the new stock layers (section 6).

## 6. How to test

| What | Command | Needs | Time |
|---|---|---|---|
| section 3g can fail | `docker run --rm -v "$PWD:/repo:ro" <image with xorriso squashfs-tools zstd cpio python3; add initramfs-tools-core for the variants that unpack an initrd> bash /repo/backends/ubuntu/iso/tests/verify-installer-base.sh` (`VERIFY_TEST_ONLY="good base-casper-conf"` runs chosen variants) | Docker | 226 variants, 1 to 3 minutes on a quiet host |
| verify a built ISO | `VERIFY_BASE_ISO=<stock ISO> backends/ubuntu/iso/scripts/verify-iso.sh ISO` (with the stock ISO it also compares the boot menus' kernel lines, the volume id, the kernel block and the Secure Boot files) | `xorriso squashfs-tools zstd cpio python3`, `unmkinitramfs` for section 7 | minutes, 8 GB scratch |
| the base layer an installer would install is free of casper | `backends/ubuntu/iso/tests/installed-boot.sh --iso ISO --quick` (or `--squashfs minimal.squashfs`): the static audit of the base layer, no disk, no boot | Docker (privileged) | about a minute |
| the installed system boots | `backends/ubuntu/iso/tests/installed-boot.sh --iso ISO` (sources: `--iso`, `--squashfs`, `--chroot-volume VOL:PATH`; `--no-boot` stops after the static checks) | Docker (privileged), QEMU, OVMF | minutes without a boot, tens of minutes with TCG |
| the installed-boot test's own parts | `backends/ubuntu/iso/tests/installed-boot.sh --selftest` (a fake QEMU, synthetic initrds, the in-guest probe against stand-in `loginctl`, `pgrep`, `plymouth` for GDM 46's `gdm` and GDM 50's `gdm-greeter`) | bash, python3 | seconds |
| the split adds up | the build itself (`ci_split_verify_layers`), and `backends/ubuntu/iso/tests/split-live-layer.sh`: Part A (the helpers, on synthetic trees) runs anywhere, Part B (the whole split on a real merged rootfs and the stock layers, with the installed-initrd probe, the audit B1 and mutation proofs) in a privileged container with the saved build volume mounted read-only (`SPLIT_TEST_*`, header of the test) | root, overlayfs (Part B) | Part A about 20 s on a Mac; Part B see the header |
| re-read the stock facts | `CI_TEST_STOCK_ISO="$PWD/ubuntu-26.04.1-desktop-amd64.iso" bash backends/ubuntu/iso/tests/grub-live-menu-modules.sh` and `backends/ubuntu/iso/scripts/md5sum-txt.sh check-stock --base-iso ubuntu-26.04.1-desktop-amd64.iso` | `xorriso`, python3 | under a minute |

What each proves, and what it does not:

* `verify-installer-base.sh` proves that every check of section 3g fails on the defect it is for, on a small synthetic image (real squashfs layers in a real ISO). It also
  checks that the library's lists are a subset of section 3g's. It proves nothing about the real image, and it can only find defects someone put in the table. The test
  itself is tested by running it against weakened copies of `verify-iso.sh` (`VERIFY_ISO_SCRIPT`).
* `verify-iso.sh` on a built ISO proves that the base layer holds none of the table's rows and that the live layer is not a placeholder. It is static: it does not boot
  anything and cannot know about a live-only file that is not in the table.
* The installed-boot test builds a disk the way an install ends up (the base layer copied, kernel and initrd regenerated in a chroot with initramfs-tools, GRUB installed),
  audits it (no casper in the base layer, in any regenerated initrd or in `grub.cfg`; `root=UUID=...`; initramfs-tools and the dracut pin) and boots it to the GDM greeter.
  It is the only test of the thing that failed. It is not the installer: subiquity's partitioning, curtin's other steps, the first-boot units and the user's account are not
  exercised, and it writes an **empty** machine-id where the installer writes the live session's valid one (port notes, section 10), so it cannot see failures of units gated on `ConditionFirstBoot`.
  Its verdict is in `result.txt` of its work directory.
* `split-live-layer.sh` is the test of the split itself: its header lists what Part A and Part B prove (overlay of the three packed layers equal to the rootfs by checksum, the base free of
  casper and the installer snap, the true `.size` and `.manifest` files, an initrd regenerated on the base without casper and the same on the unsplit rootfs with it as the control, mutation proofs).
* No test replaces one real GUI install of a freshly built ISO. That has not been repeated since the split, on either release.

## 7. Test status

Honest columns. "Ran" is a command that was executed and what it printed. "Not run" means exactly that. The boot and verifier logs of the 9.9 image are in
[`docs/evidence/2026-10-18-ubuntu-fixpass-9.9/`](../evidence/2026-10-18-ubuntu-fixpass-9.9/installed-boot-result.txt); the other logs named here are in the research scratch directory of the session, not in the repository.

### 7.1 Ubuntu 26.04.1

| Check | Ran | Result | Not proven |
|---|---|---|---|
| One real `build-iso.sh` run (privileged `ubuntu:26.04` container, version string 9.9, Tier B knobs on) | yes, 2026-10-18, 860 s | completed; `repack_squashfs` proved "overlay(B + placeholder + L) == rootfs" in 274 s; the finished image was read back against its `md5sum.txt` (800 of 800) | built from a snapshot of the worktree during the fix pass, not from the committed HEAD (image sha256 `dce9eb71...`; every "that image" row below means this one. The clean-checkout image is `709b8485...`: [test-evidence.md](test-evidence.md#ubuntu-2604-image-build-and-static-verification)) |
| `VERIFY_BASE_ISO=<stock ISO> verify-iso.sh` on that image | yes | **393 passed, 0 failed, nothing skipped**; section 3g 59 passed, 3d 11, 3e 5, 8 6, 9 1 (7,076,577,280 bytes, 1,513,357,312 spare) | static checks only |
| the same image with three verify fixes reverted in a copy of the script | yes | 386 passed, 4 failed: exactly the four defects the review found | |
| section 3g tables against the **real stock layers** (control) | yes | the 18 `BASE_FORBIDDEN` rows match nothing in the stock minimal layer (174,601 entries); the stock live layer has every `LIVE_REQUIRED` path; the checks that tell a dracut-based stock base from this image's initramfs-tools one fail, as they should | |
| `tests/verify-installer-base.sh` | yes | **226 variants behaved** (229 variants since 2026-10-19: the three that plant a wants link, a requires link and an autostart entry for the installer in the live layer have not been run, the host has no xorriso or squashfs-tools): a good image, hand-written defects for every row and check, and variants taken from the library's own lists (the drift guard). Run against 23 weakened copies of `verify-iso.sh`, each made exactly its dependent variants misbehave | real-image behaviour beyond the one image above; a defect nobody wrote a variant for |
| `tests/split-live-layer.sh` Part A, privileged container | yes | 207 passed, 0 failed, 1 skipped | |
| `tests/split-live-layer.sh` Part B (B1 B2 B9 B10) on the stock layers merged, after `remove_esb_seed` | yes | 116 passed, 0 failed, 2 skipped; B10 ran the real `verify-iso.sh` sections 3d, 3e and 3g on the real split layers: 10, 5 and 56 checks passed | the rootfs was the STOCK merge, not a customized one (the real build above covers a customized one) |
| `tests/installed-boot.sh --iso <that image>` | yes, 2026-10-18 | **PASS**: 25 static checks (no FAIL, no WARN), then the disk the test assembled booted to the GDM greeter (greeter up after 53 s of probe time, 230 s of boot, `nonblack=1.0`); `failed-units` and `restarted-units` empty | the disk is assembled, not installed; empty machine-id; not the installer |
| `tests/installed-boot.sh --selftest` | yes | 20 passed (21 with the real stock initrd, 2,897 entries over 4 segments, 50 of them casper's) | |
| the image booted under OVMF Secure Boot | yes | no `prohibited by secure boot policy` on the serial console; the themed GRUB menu draws | the live session and installer were not entered |
| **a real subiquity install of a built image (normal installer and the one-click path), then a boot of the installed disk** | **not run** | | **pending evidence**: `CAPTURE.md` and logs in the capture directories of the Ubuntu run (`shots/ubuntu/` and `ubuntu/` in the session scratch; their text records are copied into [`docs/evidence/`](../evidence/README.md) and the frames into `docs/ui/companion-os/ubuntu/` when the row is run). It confirms this page when the installer's curtin source stack is `minimal.squashfs` alone, the installed disk reaches GDM with no `casper` package and an initrd without casper's scripts, and `ssh` has host keys |

<!-- figure: docs/ui/companion-os/ubuntu/NN-harness-installed-greeter.png (the installed disk assembled from the 26.04.1 base layer, at the branded GDM greeter) -->

### 7.2 Retired baseline (24.04.5, v7 image, 2026-10-15 to 17)

| Check | Result |
|---|---|
| `verify-iso.sh` on the v7 ISO | section 3g 9 passed, 31 failed of 40 (every `BASE_FORBIDDEN` row, casper and finalrd in the status, the installer snap in the seed and `state.json`, the live `cloud.cfg`, the `/bin/true` symlink, an empty live layer, three stale manifests) |
| an ISO carrying the real output of the split, made from the v7 chroot with the library's functions | the split took 1,316 s; `B` 5,445,337,088 bytes (1,941 packages), `L` 196,075,520 bytes (259 paths, no whiteouts); the comparison "overlay == rootfs" passed (444 s); section 3g 40 passed, 0 failed |
| `tests/verify-installer-base.sh` | 144 variants behaved |
| `tests/installed-boot.sh --iso <that ISO> --quick` | PASS in 38 s (8 static checks) |

## 8. Known gaps

* The table is hand-made. A live-only file nobody put in it is invisible to every check on this page. The derivation (section 3.2) is the evidence that the table is complete for the
  26.04.1 live layer; it is not a proof. Group B1 repeats the audit on real layers, so a new base ISO that adds live-only files fails there. It found the polkit rule and the sysctl file on 26.04.1, which the 24.04 derivation did not.
* A path that looks live-only may belong to a package the base keeps. The finalrd row of section 3g was written as "everything under `/usr/share/finalrd`" and failed on the first real split because `mdadm`, which
  stays, puts a hook there. The stock minimal and standard layers cannot show this kind of mistake, since the kept packages are in the stock live layer; a real base layer can.
  Run section 3g on every built image, and write a row for what the live-only package owns, not for a directory it shares.
* The `.size` and `.manifest` checks are consistency checks against the same layer's own listing and dpkg status. A manifest that is wrong in the same way as the status passes.
* Section 3g trusts `unsquashfs -ll`: it sees paths, not contents, except for the files it extracts (dpkg status, `seed.yaml`, `state.json`, `cloud.cfg`, `casper.conf`, the pin file, `cdrom.sources`).
  A base layer whose `gschemas.compiled` still contains the livecd overrides passes the path checks if the override file is gone; the build's `schemas` row proves the compiled file is current, section 3g does not look at it.
* Section 3g cannot prove that the stack of the three layers equals `C`: it has no `C`. That comparison is made by the build (`ci_split_verify_layers`) while `C` exists.
* Section 3g names the installer snap statically (`ubuntu-desktop-bootstrap`). The library derives the names from the difference between the live and the standard snapd seed, so a base ISO whose installer
  snap changes name is handled by the build but not by the `BASE_FORBIDDEN` row, which then needs the new name.
* The kernel-line check is an allow-list (`nomodeset`, `iso-scan/filename=${iso_path}`, `ci.autoinstall=1`, then `--- quiet splash`). A parameter someone adds on purpose fails it until the list in
  `verify-iso.sh` (`stock_kernel_line`) is edited; that is the point.
* Companion's own live-session pieces are not split out. The one-click helper (`/usr/libexec/ci-os/ci-os-auto-install`, its launcher and autostart hook) and `ci-os-live-container-storage.service` are in the
  base layer, as is everything `customize-chroot.sh` adds; they guard themselves (the helper exits with code 4 outside a live session, the units test for `/cdrom/casper/vmlinuz`). The table lists only what the
  **stock** live layer carries, which has no such guards. Whether the installed system should carry those inert files at all is a separate decision.
* The base layer is initramfs-tools based, which is not what a stock Ubuntu 26.04.1 install is. curtin's initrd for it has been reproduced by `installed-boot.sh`, not observed in a real install.
* The top-level `README.md` still says that a clean ISO install ends up identical to running the provisioning and theming by hand; until an ISO has been installed and booted that sentence is a design intent, not an observation.

## 9. Files

| File | Role |
|---|---|
| `backends/ubuntu/iso/scripts/build-iso.sh` | `repack_squashfs`: calls the split, writes `install-sources.yaml` (`write_install_sources`), `SHA256SUMS`; `remove_esb_seed`, `restore_cdrom_source`, `remove_stock_layer_files`, `assert_casper_layer_files` |
| `backends/ubuntu/iso/scripts/lib/split-live-layer.sh` | the table, `ci_split_live_layer`, `ci_split_verify_layers`, `ci_split_write_metadata`, `ci_split_assert_base_tree` |
| `backends/ubuntu/iso/scripts/verify-iso.sh` | section 3g, section 3d (`install-sources.yaml`, the twelve casper files), section 9 (size), and the `casper.conf` checks that read the live layer |
| `backends/ubuntu/iso/scripts/md5sum-txt.sh` | the image's `md5sum.txt` (regenerate, check-stock, verify) |
| `backends/ubuntu/iso/tests/verify-installer-base.sh` | the mutation test of section 3g, with the drift guard against the library's lists |
| `backends/ubuntu/iso/tests/split-live-layer.sh` | the test of the split library: helpers on synthetic trees, the split on real data |
| `backends/ubuntu/iso/tests/placeholder-layer-modes.sh` | directory modes of the empty placeholder layer |
| `backends/ubuntu/iso/tests/installed-boot.sh`, `tests/lib/` | the installed-system boot test (`--quick`, `--no-boot`, `--selftest`) and its parts |
| `backends/ubuntu/chroot/payload/apt/etc/apt/preferences.d/ci-os-no-dracut` | the dracut pin (installed by `customize-chroot.sh` Step 1b) |
| `backends/ubuntu/iso/README.md` | build and test overview, the "Layers" section and the troubleshooting entry for the symptom |
| [ubuntu-2604-port-notes.md](ubuntu-2604-port-notes.md) | what changed from 24.04 to 26.04.1 and why |
