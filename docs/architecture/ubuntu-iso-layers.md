# Ubuntu ISO layers: what the installer installs, what only the live session sees

> Private & Confidential — Property of Lifescope Inc. Do not distribute.

Scope: the Ubuntu backend's ISO (`backends/ubuntu/iso/`). This page explains the three-layer root filesystem of the Ubuntu 24.04
desktop ISO, why packing the whole customized rootfs into the first layer made the **installed** system unbootable, how the build
now splits the rootfs into an installer base layer and a live-only layer, what is in each, how to extend the list, and which tests
prove what. The other backends (CachyOS, Fedora, Arch, Bazzite, NixOS) do not use these layers.

**Status of this page: 2026-10-17.** The defect and its cause were found by a complete GUI install of the v7 image in QEMU followed by
offline inspection of the installed disk (section 2). The split (section 4) is in `build-iso.sh` and `scripts/lib/split-live-layer.sh`;
section 7 says, column by column, what has been run and what has not. What has been shown: the split library, run on the saved work
data of the v7 build, produced three layers whose stack equals the v7 rootfs (checked by checksum, apart from the few paths `mksquashfs`
leaves out), and `verify-iso.sh` passes all of section 3g on an
ISO carrying those layers (it fails 31 of its 40 checks on the v7 ISO itself). What has **not** been shown: **no ISO built with the split
has been installed and booted, and none has been built by the whole `build-iso.sh`** (the stock base ISO was not available where this was
written, so the split was exercised on the saved work data of the v7 build and its layers were put into a copy of the v7 ISO).
Everything else the split is said to do is what its code and its tests do, not something seen on a booted, really installed image.

## 1. In one paragraph

subiquity installs exactly one stack of layers, the one named by the chosen entry of `casper/install-sources.yaml`
(`minimal.squashfs` for the entry the Companion ISO defaults to). On a stock Ubuntu ISO everything that belongs to the live session
alone (the `casper` package and its initramfs hook, the live session's dconf overrides, the installer's own snap, the live image's
cloud-init, getty and udisks settings) sits in a third layer, `minimal.standard.live.squashfs`, that the installer never copies.
Until the split, `build-iso.sh` packed the whole merged rootfs (all three stock layers plus the Companion customization) into
`minimal.squashfs` and shipped two empty placeholders for the other two layers. The installer therefore copied the live-only content
to the disk, and `casper`'s initramfs hook made every initrd regenerated on the installed system boot the live medium: **the installed
system stops at "Unable to find a medium containing a live file system".** A boot of the live ISO cannot show this, because the live
session never looks at the installed disk.

## 2. Evidence (2026-10-15 and 16, v7 image)

A complete GUI install of the v7 ISO (`companion-os-1.0-amd64.iso`, 7,692,484,608 bytes, `casper/minimal.squashfs` 5,640,392,704
bytes) into a QEMU NVMe disk, then offline inspection of the installed disk and of the build's merged chroot:

| Observation | Where it was seen |
|---|---|
| The first boot of the installed disk loops on `/init: line 38: can't open /dev/sr0: No medium found` and ends at "Unable to find a medium containing a live file system / Attempt interactive netboot from a URL? yes no (default yes)" | screenshot of the installed boot |
| The installer installed from one layer only: curtin's source stack was `['///cdrom/casper/minimal.squashfs']` | installer log |
| The installed disk has the `casper` package in `var/lib/dpkg/status`, `/etc/casper.conf`, `/etc/initramfs-tools/conf.d/casperize.conf` (`export CASPER_GENERATE_UUID=1`) and `default-layer.conf` (`LAYERFS_PATH=minimal.standard.live.squashfs`) | offline inspection |
| Every initrd regenerated in the target holds casper's scripts and `conf/conf.d/default-boot-to-casper.conf` (`if [ -z "$BOOT" ]; then export BOOT=casper`). casper's hook writes that file when `CASPER_GENERATE_UUID` is set, which `casperize.conf` does | the regenerated initrds; `usr/share/initramfs-tools/hooks/casper` of the merged chroot |
| Also on the disk, from the same layer: `livecd-rootfs.gschema.override` (the live session's dconf overrides, compiled into `gschemas.compiled`); the installer snap `ubuntu-desktop-bootstrap` and `core22` with AppArmor profiles, a desktop entry, mount and service units and seed entries; `/etc/subiquity/kernel-meta-package`; `/etc/cloud/cloud.cfg.d/06_quiet.cfg`; `/etc/apt/preferences.d.save` (the stock standard layer has this directory too, with two flat `ubuntu-pro-esm-*` files; the live-only part is the nested `preferences.d` copy the live layer adds) | offline inspection |
| The merged chroot also carries the live image's rewrites of files the installed system shares: `/etc/cloud/cloud.cfg` creates a user `installer` (shell `/usr/bin/subiquity-shell`, `NOPASSWD:ALL`) and sets `ssh_pwauth: yes`; `getty@tty1.service` is masked to `/dev/null`; `systemd-networkd-wait-online` is a symlink to `/bin/true`; `udisks2-inhibit.service` is present | `/v/w/chroot` of the v7 build volume |
| subiquity's `install.py` has no package-removal step | the installer snap, rev 680 |
| A copy of the installed disk repaired offline (purge `casper`, delete the two initramfs configuration files and the livecd override, recompile the schemas, `update-initramfs -u -k all` in a chroot) reached the GDM greeter in QEMU: the user's login screen with the Companion mark, one frame. Whether the session is entered was not looked at here | screenshot of the repaired boot |
| `verify-iso.sh` before section 3g passed this image: it asserted that Companion content was present, not that live-only content was absent | rerun with section 3g on the v7 ISO: 3g fails 31 checks, see section 7 |

The logs and screenshots are in the research scratch directory of the session that produced them, not in the repository.

### Why the build did not see it

`build-iso.sh` carried a comment in `main` saying that a `filesystem.manifest-remove` is not needed for Ubuntu 24.04 because the
original ISO ships none and "subiquity handles package removal internally". Both halves are wrong for the merged design. Subiquity
has no removal step (above). The stock ISO needs no removal list because it never installs the live layer; once the live layer's
content is merged into the layer the installer does install, nothing removes it. The comment was true of the stock layout and false of
the layout this build made. It has been rewritten.

## 3. The stock layer model (Ubuntu 24.04.5)

casper and curtin stack layers by the same rule: a layer path such as `minimal.standard.live.squashfs` stands for the stack of the
prefixes of its dotted name, bottom first: `minimal.squashfs`, `minimal.standard.squashfs`, `minimal.standard.live.squashfs`
(`LAYERFS_PATH` handling in `usr/share/initramfs-tools/scripts/casper`; `_get_image_stack` in curtin's `commands/extract.py`, read in the
24.04.5.1 installer snap).

| Layer | What the stock ISO keeps in it | Packages (24.04.5) | Compressed | Seen by |
|---|---|---|---|---|
| `minimal.squashfs` | the minimal desktop: GNOME, the system, the snap seed (firefox, snap-store, firmware-updater, gnome-46-2404, mesa-2404, gtk-common-themes, core24, bare, snapd-desktop-integration) | 1,488 | 2.24 GB | live session, **installer** |
| `minimal.standard.squashfs` | the standard desktop apps (deja-dup, file-roller, duplicity, thunderbird seed, ...) | +222 | 0.56 GB | live session, installer (only for the entry "Ubuntu"/"Companion OS", not for the minimized one) |
| `minimal.standard.live.squashfs` | what exists to run the live session and the installer: `casper` and `finalrd`, `user-setup`, `localechooser-data`, the kernel (`linux-image-7.0.0-31-generic`, modules, headers, tools), `linux-firmware*`, the bootloaders (`grub-pc`, `grub-efi-amd64-signed`, `shim-signed`, `efibootmgr`), the disk tools (`zfsutils-linux`, `lvm2`, `mdadm`, `cryptsetup`, `btrfs-progs`, `xfsprogs`, `gparted`), the ibus engines, microcode, the installer snap `ubuntu-desktop-bootstrap` with `core22`, and the live image's settings (section 4.3) | +113 packages, +2 snaps | 1.22 GB | **live session only** |

(Counts from the layers' own dpkg status files and manifests, extracted from the 24.04.5 base ISO. Each layer carries a full
`var/lib/dpkg/status` and its own snapd `seed.yaml` and `state.json`; the topmost layer's copy is what a stacked system shows.)

**Live session.** casper reads `LAYERFS_PATH` (the `layerfs-path=` kernel parameter, or the default in the initrd's
`conf/conf.d/default-layer.conf`, a copy of `/etc/initramfs-tools/conf.d/default-layer.conf` of the image the initrd was built in:
`LAYERFS_PATH=minimal.standard.live.squashfs`) and mounts the layers with overlayfs. The stock boot menus carry no layer parameter: their
kernel lines are `linux /casper/vmlinuz  --- quiet splash`. The v7 initrd's stock part holds the three conf.d files above. The live initrd
is the stock one plus a small cpio overlay with Companion's `casper.conf` and Plymouth files, so the live boot does not depend on casper
inside the squashfs.

**Installer.** subiquity (the `ubuntu-desktop-bootstrap` snap) reads `casper/install-sources.yaml`. For the chosen entry curtin builds
the stack from the entry's `path` by the same prefix rule, mounts it read-only with overlayfs and copies it to the target with
`rsync -aXHAS --one-file-system`. The live layer is named by no entry, so it is never installed. On a stock install curtin then installs the
kernel and the bootloader from the ISO's apt pool (the live layer carries its own copies for the live boot).

That is the whole reason the stock layout is safe: **nothing in the live layer can reach the disk, whatever it contains.**

## 4. The split

### 4.1 What the merged design did

`extract_squashfs` unpacks the three stock layers, in order, into one chroot `C`. `customize-chroot.sh` customizes `C`. The old
`repack_squashfs` packed all of `C` into `minimal.squashfs` and wrote two empty placeholder layers (directories only, modes copied from
`C`, see `make_placeholder_layer`). That is right for the live session (the placeholders add nothing, so the stack is `C`) and for the
Companion content, which belongs in both. It also put everything the stock ISO keeps in the live layer into the layer the installer copies.

### 4.2 What the build does now

Let `C` be the customized merged rootfs. `repack_squashfs` calls `ci_split_live_layer` (`scripts/lib/split-live-layer.sh`), which produces:

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

How, in the library's words: mount an overlayfs with `C` as the read-only lower directory and a scratch directory `U` as the upper one;
apply the rows of the table (section 4.3) inside the merged view (a chroot for `dpkg --purge`, `glib-compile-schemas` and `apt-get check`);
pack `B` from the merged view with the build's long-standing `mksquashfs` options; derive `L` from `U`: for every path the removal
changed or deleted, `L` carries `C`'s version, for every path the removal created that `C` lacks, `L` carries a whiteout (a character
device 0:0); `L` is staged with rsync from `C` so modes, owners, symlinks and extended attributes are `C`'s. Directory modes are kept
exactly: a directory present in several layers takes its mode from the topmost one (the `/tmp` trap that `make_placeholder_layer` and
verify-iso section 3e guard against).

The build then refuses to continue unless two checks pass (`ci_split_verify_layers`, run on the three **packed** layers): the
base layer holds none of the live-only content (`ci_split_assert_base_tree`, an independent list of paths and packages), and the stack
`L` over `S` over `B`, mounted the way casper does, equals `C` (rsync comparison by checksum: content, modes, owners, symlinks, device
nodes, extended attributes). Two more guards stop the build: a `restore` row refuses to run over a path the build itself customized (the
rootfs's copy must still be the stock live layer's, or restoring the stock standard copy would silently drop the customization from the
installed system while the live session kept it), and dpkg and apt must find the package database consistent after the removal
(`apt-get check`, `dpkg --audit`). Then `ci_split_write_metadata` writes the true `.size` and `.manifest` files (4.4).

The kernels and the bootloader stay in `B`: the merged design already ships the kernels (7.0.0-31 and 7.0.0-38) and GRUB in `C`, and the
installer finds a kernel installed and only has curtin generate the initrd, which now has no casper in it.

### 4.3 What is live-only (the table to extend)

The authoritative table is `ci_split_table` in `scripts/lib/split-live-layer.sh`: one row per package to purge or path to remove or
restore, with the reason beside it. `verify-iso.sh` section 3g keeps its own copy as data (`BASE_FORBIDDEN`, `LIVE_ONLY_PKGS`,
`LIVE_REQUIRED`), the library's invariant list (`ci_split_assert_base_tree`) a third. They are written independently on purpose and
`tests/verify-installer-base.sh` fails if the library lists a path that section 3g does not. By group:

| Group | What | Why it must not be in `B` |
|---|---|---|
| casper | packages `casper` and `finalrd` (the directory `/usr/share/finalrd` is shared with `mdadm`, which stays, and is not on the list); `/etc/casper.conf`, `/usr/lib/casper`, `/usr/share/casper`, `/usr/sbin/casper-*`, `casper.service`, `casper-md5check.service` and their enable links, `/usr/share/initramfs-tools/{scripts,hooks}/casper*` | the hook turns every regenerated initrd into a live boot; `finalrd` exists for casper (a live system needs it to unmount its squashfs root at shutdown) |
| casper initramfs configuration | `/etc/initramfs-tools/conf.d/casperize.conf` and `default-layer.conf` | written by livecd-rootfs for the live initrd; the hook reads them. Removed even though the package is gone, so a returning hook finds nothing |
| live dconf overrides | `usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override`, then `glib-compile-schemas` (the `schemas` row proves the compiled file is current) | an "installer only" session: universal-access status always shown, dock not fixed, desktop-icons extension disabled |
| the installer | `ubuntu-desktop-installer.service` (user unit and its enable link), `subiquity_config.mount` and the device drop-in that wants it, `/etc/subiquity` (`kernel-meta-package` is read by subiquity from the live root only), the installer snap `ubuntu-desktop-bootstrap` and its base `core22` with everything snapd generated for them (the names are the live seed minus the standard seed, plus `ubuntu-desktop-bootstrap`) | a launcher, mounts and profiles for an installer that is not installed |
| snapd state | `var/lib/snapd/{state.json,system-key,seed/seed.yaml,seed/assertions,assertions,apparmor/profiles,cgroup,cookie,desktop/applications,inhibit,mount,seccomp/bpf,sequence}` and `var/cache/snapd/aux`: **restored** to what the stock standard stack (minimal + standard) has | each stock layer holds a complete, self-consistent snapd preseed run; the live layer's covers the installer snap with other cookies. Mixing them breaks the cookies, and a `state.json` that knows a snap whose file is gone makes snapd fail to seed |
| settings in shared files | `/etc/cloud/cloud.cfg` and `/usr/lib/systemd/systemd-networkd-wait-online`: **restored** to the stock standard stack's | the live copy of `cloud.cfg` creates the user `installer` (shell `subiquity-shell`, `NOPASSWD:ALL`) with `ssh_pwauth: yes`; the live image replaces the real `systemd-networkd-wait-online` with a symlink to `/bin/true` |
| other live-image files | `/var/lib/cloud/seed/nocloud`, `/etc/cloud/cloud.cfg.d/06_quiet.cfg`, `/etc/apt/preferences.d.save/preferences.d`, `/root/packages.chroot`, `getty@tty1.service` (masked to `/dev/null` for casper's own login), `udisks2-inhibit.service` (a udev rule that makes every block device ignored by udisks, so the live session does not automount its own medium) and its links, `snapd.service.d/no-reexec.conf`, the journald drop-ins that make the journal readable inside the installer snap | written by livecd-rootfs for the live session; on the installed system they hide devices, remove the tty1 login prompt or leave a way in |

What stays in `B` although the stock live layer carries it: **kernels, firmware, microcode, bootloader and disk-tool packages** (a disk
install must boot without the network, and the tools are useful on the disk), and the paths that belong to those kept packages or are
state their scripts generated (modules.dep, `/etc/default/grub`, `mdadm.conf`, crypttab, the zfs rc links, alternatives, caches).

Why the table is believed complete for the 24.04.5 live layer (the derivation is in the library's header, and `tests/split-live-layer.sh`
group B1 repeats it on the real layers). The stock live layer lists 56,271 entries, the root among them. 55,994 exist in neither lower
layer. The packages of the live layer own all of those but 905 (their `var/lib/dpkg/info/*.list`, usr-merge aware). Of the 905 the header
counts 781 as dpkg's own bookkeeping and the generated state of packages that stay, and 124 as live-only: the `rm` rows. The layer also
rewrote 66 paths that a lower layer has: 38 generated state that the package scripts and triggers regenerate, 2 whiteouts, 24 of
snapd's preseed state, and the two live settings `/etc/cloud/cloud.cfg` and `systemd-networkd-wait-online`, which the `restore` rows
take back. The figures 56,271, 55,994, 905 and 66 (and, in the 66, the 24 snapd paths and the 2 whiteouts) were recounted on 2026-10-17
from the saved `unsquashfs -ll` listings and dpkg file lists of the three stock layers; the 781/124 split and the 38 are the library
header's figures and were not recomputed. That the derivation found everything is an argument, not a proof (section 8).

The apt pin backup row is narrow on purpose, in the library and in section 3g alike: the stock **standard** layer (installed by a stock
"Ubuntu" install) carries `/etc/apt/preferences.d.save/ubuntu-pro-esm-*`, so those flat files stay; only the live layer's nested
`preferences.d.save/preferences.d` is live-only. (An earlier version of the library removed the whole directory while section 3g flagged
only the nested copy; they agree now, and the drift guard of `tests/verify-installer-base.sh` is what would show them disagreeing again.)

### 4.4 Metadata that must stay true

| File | Rule | Written by | Checked by |
|---|---|---|---|
| `casper/minimal.size`, `minimal.standard.size`, `minimal.standard.live.size` | the size of the layer's tree, `du -sx --block-size=1` (`0` for the placeholder) | `ci_split_write_metadata` | 3g: a plausibility interval from the layer's own listing |
| `casper/filesystem.size`, `install-sources.yaml` `size:` | whole live stack, and the installed base | the same, `repack_squashfs` | (not checked) |
| `casper/minimal.manifest`, `minimal.standard.manifest`, `minimal.standard.live.manifest` | the stock "diff" shape: `+package<TAB>version` lines (and `+snap:name<TAB>channel<TAB>revision`); `B`'s packages, none, and the packages `L` adds | `ci_split_write_metadata` | 3g: set equality with the dpkg status files |
| `casper/install-sources.yaml` | both entries, `preinstalled_langs: []`, no enhanced-secureboot variations, every named path exists | `repack_squashfs` | 3d |
| `casper/SHA256SUMS`, `/md5sum.txt` | regenerated after the layers are written | `repack_squashfs`, `md5sum-txt.sh` | 8 |

The `.size` check is deliberately an interval, not an equality. The number the build writes is `du -sx --block-size=1` of the mounted
layer (`ci_split_verify_layers`), and a listing cannot reproduce `du` exactly (a hard link is listed once per name, directories and
symlinks are counted by the filesystem). On the real split layers of the v7 work data the two agree closely: `du` of the base layer is
12,728,797,184 bytes against 12,689,013,551 bytes of regular-file sizes in its listing (+0.3 %), the live layer 398,956,544 against
398,900,210. The interval (80 % of the listed bytes up to the block-rounded sizes plus 20 %) is much wider than that on purpose. The
v7 image's own `.size`, which the old build took with `du` of the build directory instead of the layer, was 11.58 GB against 13.08 GB
listed, and the interval had to accept that shape of error to be able to read an old image at all. It catches `0` for a layer that is not
empty and another layer's number; it cannot catch a few per cent of drift.

## 5. How to extend the live-only table

1. Find the content. List the stock live layer (`unsquashfs -ll casper/minimal.standard.live.squashfs`) and the built base layer;
   anything the live layer ships that the installed system should not have goes on the table. The installed-boot test (section 6)
   shows what an installed system really got.
2. Add the row to `ci_split_table` with its reason: `purge|<package>` for a package (a removed package must leave no dpkg stanza),
   `rm|<path>` for a path, `restore|<path>` for a file the live image rewrote in place (the stock standard stack's copy comes back).
3. Add the path or package to the library's invariant list (the `gone` array in `ci_split_assert_base_tree`; the packages are named in its
   loop; `CI_SPLIT_LIVE_REQUIRED` for something the live layer must now hold). Keep both arrays in the layout they have: `tests/verify-installer-base.sh`
   (the drift guard) and group A4 of `tests/split-live-layer.sh` cut them out by their opening and closing lines, and the library's comment says why
   no comment may quote those lines.
4. Add the same row to `verify-iso.sh` section 3g: a `BASE_FORBIDDEN` row (`label|extended regex` matched against the whole path of a
   listing entry), an entry in `LIVE_ONLY_PKGS`, or a `LIVE_REQUIRED` row if the live layer must now carry something. Run the row
   against the stock layers (the three `.ll` listings of a base ISO) to see that it matches nothing in the stock minimal and standard
   layers: a row that does is not live-only.
5. Add a variant to `tests/verify-installer-base.sh` (a `mutate` case that plants the path in the base tree and names the text of
   the FAIL line it must produce) and run the test. Every entry of the library's two lists becomes a variant of its own without any
   edit (`drift:<path>` for the base, `driftlive:<path>` for the live layer), so a path the library calls live-only that section 3g
   lacks makes the test fail at once. The reverse is allowed: section 3g may be stricter than the library.
6. Update the table in 4.3.

If the content is owned by a package, purging the package is the removal; deleting only its files leaves dpkg's database listing it.

## 6. How to test

| What | Command | Needs | Time |
|---|---|---|---|
| section 3g can fail | `docker run --rm -v "$PWD:/repo:ro" <image with xorriso squashfs-tools zstd cpio python3> bash /repo/backends/ubuntu/iso/tests/verify-installer-base.sh` (`VERIFY_TEST_ONLY="good base-casper-conf"` runs chosen variants) | Docker | 139 variants, 1 to 3 minutes depending on host load |
| verify a built ISO | `backends/ubuntu/iso/scripts/verify-iso.sh ISO` (`VERIFY_BASE_ISO=<stock ISO>` also compares the boot menus' kernel lines and the Secure Boot files with it) | `xorriso squashfs-tools zstd cpio python3` | minutes, 8 GB scratch |
| the base layer an installer would install is free of casper | `backends/ubuntu/iso/tests/installed-boot.sh --iso ISO --quick` (or `--squashfs minimal.squashfs`): the static audit of the base layer, no disk, no boot | Docker (privileged) | about a minute, per its header |
| the installed system boots | `backends/ubuntu/iso/tests/installed-boot.sh --iso ISO` (sources: `--iso`, `--squashfs`, `--chroot-volume VOL:PATH`; `--apply-repair` shows the test passing on a repaired layer; `--no-boot` stops after the static checks) | Docker (privileged), QEMU, OVMF | minutes without a boot, tens of minutes with TCG |
| the installed-boot test's own parts | `backends/ubuntu/iso/tests/installed-boot.sh --selftest` (a fake QEMU and synthetic initrds) | bash, python3 | seconds |
| the split adds up | the build itself (`ci_split_verify_layers`), and `backends/ubuntu/iso/tests/split-live-layer.sh`: Part A (the helpers, on synthetic trees) runs anywhere, Part B (the whole split on a real merged rootfs and the stock layers, with the installed-initrd probe and mutation proofs) in a privileged container with the saved build volume mounted read-only | root, overlayfs (Part B) | Part A about 20 s on a Mac; for Part B see the test's header (`SPLIT_TEST_*`) |

What each proves, and what it does not:

* `verify-installer-base.sh` proves that every check of section 3g fails on the defect it is for, on a small synthetic image (real
  squashfs layers in a real ISO). It also checks that the library's lists are a subset of section 3g's. It proves nothing about the real
  image, and it can only find defects someone put in the table. The test itself is tested by running it against weakened copies of
  `verify-iso.sh` (`VERIFY_ISO_SCRIPT`).
* `verify-iso.sh` on a built ISO proves that the base layer holds none of the table's rows and that the live layer is not a placeholder.
  It is static: it does not boot anything and cannot know about a live-only file that is not in the table.
* The installed-boot test builds a disk the way an install ends up (the base layer copied, kernel and initrd regenerated in a chroot, GRUB
  installed), audits it (no casper in the base layer, in any regenerated initrd or in `grub.cfg`; `root=UUID=...`) and boots it to the
  GDM greeter. It is the only test of the thing that failed. It is not the installer: subiquity's partitioning, curtin's other steps,
  the first-boot units and the user's account are not exercised unless its output says so. Its verdict is in `result.txt` of its work
  directory.
* `split-live-layer.sh` is the test of the split itself: its header lists what Part A and Part B prove (overlay of the three packed layers
  equal to the rootfs by checksum, the base free of casper and the installer snap, the true `.size` and `.manifest` files, an initrd
  regenerated on the base without casper and the same on the unsplit rootfs with it as the control, mutation proofs). This page records no result of it.
* No test replaces one real GUI install of a freshly built ISO. That has not been repeated since the split.

## 7. Test status

Honest columns. "Ran" is a command that was executed on 2026-10-15, 16 or 17 and what it printed (the containers' clock is UTC, the
host's is Pacific time, so a log can show a date a few hours ahead of the host's). "Not run" means exactly that. Logs named here are in
the research scratch directory of the session, not in the repository. The split library was still being edited while this page was
written; a row says which copy of it, and of the other files, it ran on.

| Check | Ran | Result | Not proven |
|---|---|---|---|
| `verify-iso.sh` (final script) on the **v7 ISO** (`companion-os-1.0-amd64.iso`, the image that failed the install), Ubuntu 24.04 container, no `VERIFY_BASE_ISO` | yes, 2026-10-17 (section 3g gave the same result on 2026-10-15 with the script before the finalrd fix below; the whole run then was 303 passed, 40 failed, with one group skipped) | section 3g: 9 passed, 31 failed: all 16 `BASE_FORBIDDEN` rows (casper, its initramfs files, units and dpkg lists, finalrd, the livecd override, the installer snaps' files, profiles, mount units and seed, the subiquity, cloud-init, apt, getty, udisks and journald files), the packages `casper` and `finalrd` in the base's dpkg status, a seed and a `state.json` that know the installer snap, the live `cloud.cfg`, the `/bin/true` symlink, the empty live layer and the live layer's missing pieces, three stale manifests. Whole run: 302 passed, 41 failed; the other 10 failures are older than this work (the image predates the one-click option, still lists enhanced-secureboot variations, and the unit tests of the one-click helper, which ran this time because `python3-yaml` was installed, fail because the helper is not in the image). The first version of the section failed 24 of its 33 checks the same way | the image fails for the reason it should; it says nothing about a corrected image |
| the section's tables against the **real stock layers**: the final `BASE_FORBIDDEN` and `LIVE_REQUIRED` rows against the `unsquashfs -ll` listings of the three stock 24.04.5 layers | yes, 2026-10-17 | stock minimal and standard (177,367 paths) match none of the 16 `BASE_FORBIDDEN` rows; the stock live layer matches all 16 and has every `LIVE_REQUIRED` path | |
| **an ISO carrying the real output of the split**: `ci_split_live_layer`, `make_placeholder_layer`, `ci_split_verify_layers` and `ci_split_write_metadata` run on the v7 build's merged chroot (`/v/w/chroot`, mounted read-only) with the stock layers (`/v/w/squashfs`) in a privileged `linux/amd64` Ubuntu 24.04 container, with the build's own `mksquashfs` options (`-comp xz -b 1M`); the three layers, the `.size` and `.manifest` files, `casper/SHA256SUMS` and `md5sum.txt` then written into a copy of the v7 ISO with xorriso (`-boot_image any replay`, as `generate_iso` does) | yes, 2026-10-17, on the library as last modified 2026-10-16 00:13 (62,193 bytes, md5 `fda0804e2bdf5927925f1322450bffa8`); today's differs from it (a `restore` guard, the narrower `preferences.d.save` row, more invariants, `errexit` restored after cleanup) | the split took 1,316 s: `B` = 5,445,337,088 bytes (1,941 packages), `L` = 196,075,520 bytes (259 paths taken from `C`, no whiteouts), the placeholder 4,096 bytes; the library's comparison "overlay(B + placeholder + L) == rootfs" (by checksum: content, modes, owners, symlinks, device nodes, xattrs) passed (444 s); `du` of the mounted layers: `B` 12,728,797,184, `L` 398,956,544, the stack 13,121,503,744 bytes. `md5sum-txt.sh verify` on the new ISO: 394 entries, 394 matched. Then `verify-iso.sh` **section 3g: 40 passed, 0 failed**, and section 3e (directory modes) passed (the live layer has 134 directories, all with the root layer's mode, and no `/tmp`). Whole run: 333 passed, 10 failed, the 10 being the v7 base image's own (above). The first run of this ISO failed one check of 3g: the finalrd row flagged `/usr/share/finalrd/mdadm.finalrd`, a file of the kept package `mdadm`. That was a defect in the row (a broad path), now fixed, and the test fixture has the file | not built by `build-iso.sh` as a whole: `install-sources.yaml`, the initrd, GRUB and the rest are the v7 image's; the layers' compressor was the build's, the library copy is not today's; nothing was installed or booted |
| `tests/verify-installer-base.sh`, a frozen copy of the tree (2026-10-17), Ubuntu 24.04 container | yes | **144 variants behaved** (1:13 for 133 variants on a quiet host, 5:48 for 144 while a large job ran): 1 good image (no failure in 3g or 3e, a PASS from every group, the re-pointed `casper.conf` checks reading the live layer, a kept package's finalrd hook in the base), 94 hand-written defects (every `BASE_FORBIDDEN` row and most of their alternatives, the casper package in any dpkg state, finalrd, the rewritten shared files, the snapd seed and state, every `LIVE_REQUIRED` row, the live layer as a placeholder or with the wrong `/tmp` or root mode, the standard layer with a file or without `/tmp`, wrong, missing and non-numeric `.size` files, wrong or missing manifests, extra kernel parameters, a different menu than the base ISO's), 35 base-layer paths and 14 live-layer paths taken from `lib/split-live-layer.sh`'s own lists (the drift guard); each produced the FAIL line it is for. Run against the script from before the finalrd fix, the good image misbehaves, as it should | real-image behaviour beyond the one image above (the fixture is small); a defect nobody wrote a variant for |
| the same test against 13 deliberately weakened copies of `verify-iso.sh` (forbidden-path loop disabled; kernel-line test always true; size test always true; placeholder test always true; `casper.conf` read from the base again; required-live-paths loop disabled; base manifest comparison disabled; package check disabled; `systemd-networkd-wait-online` check disabled; `cloud.cfg` check disabled; seed-names-installer check disabled; seed-missing-file check disabled; the live layer's `/tmp` allowance widened to the placeholder), only the variants that depend on each plus the good image | yes, 2026-10-17 (the copies regenerated from the current script) | each copy made exactly its dependent variants misbehave and the good image still behaved, except where the good image depends on the check: 44, 3, 4, 1, 2 (the good image and the `casper.conf` variant), 13, 1, 3, 1, 1, 1, 1 and 1 variants | the weakened copies are one-line edits, not a complete mutation analysis |
| `tests/split-live-layer.sh`, Part A, on the Mac (bash 3.2, no container) | yes, 2026-10-17, on the library copy of that moment | 107 passed, 0 failed, 3 skipped (A5 whiteouts, A9 and Part B need Linux and root); the run included the mutation proofs of Part A and a check that its two invariant lists are still cut out by the markers `verify-installer-base.sh` uses | Part B (the whole split on the saved data with the initrd probe, mutation proofs and the audit B1) was **not** run by this page's author; the run of the split above is the library's own functions, not that test |
| `tests/installed-boot.sh --selftest` on the Mac | yes, 2026-10-17 | 18 passed, 0 failed (a fake QEMU, synthetic initrds, the install-sources layer rule) | |
| `tests/installed-boot.sh --iso <the split ISO above> --quick` (builder image `civerify-tools`, `linux/amd64`) | yes, 2026-10-17 | verdict PASS in 38 s: the default install source is `minimal.squashfs` alone; 8 static checks, 0 FAIL, 0 WARN (no casper package, no `/etc/casper.conf`, no casper settings in `initramfs-tools/conf.d`, no casper initramfs scripts, no live gschema override, no installer snap, no installer or live-session leftovers, a `cloud.cfg` that does not name the live user). It says itself that `--quick` does not test the initramfs or the boot | the same run on the unsplit v7 ISO was not made here; the initramfs regeneration and the boot of the split base are **not run** |
| full GUI install of a split ISO, then boot to the greeter | **not run** | | everything above is a model of this |

## 8. Known gaps

* The table is hand-made. A live-only file nobody put in it is invisible to every check on this page. The derivation in the library's
  header (905 paths owned by no package, 66 rewritten) is the evidence that the table is complete for the 24.04.5 live layer; it is not a proof.
  Group B1 of `tests/split-live-layer.sh` repeats the audit on real layers, so a new base ISO that adds live-only files fails there.
* A path that looks live-only may belong to a package the base keeps. The finalrd row of section 3g was written as "everything under
  `/usr/share/finalrd`" and failed on the first real split because `mdadm`, which stays, puts a hook there. The stock minimal and standard
  layers cannot show this kind of mistake, since the kept packages are in the stock live layer; a real base layer can. Run section 3g on every
  built image, and write a row for what the live-only package owns, not for a directory it shares.
* The `.size` and `.manifest` checks are consistency checks against the same layer's own listing and dpkg status. A manifest that is wrong
  in the same way as the status passes.
* Section 3g trusts `unsquashfs -ll`: it sees paths, not contents, except for the files it extracts (dpkg status, `seed.yaml`, `state.json`,
  `cloud.cfg`, `casper.conf`). A base layer whose `gschemas.compiled` still contains the livecd overrides passes the path checks if the
  override file is gone; the build's `schemas` row proves the compiled file is current, section 3g does not look at it.
* Section 3g cannot prove that the stack of the three layers equals `C`: it has no `C`. That comparison is made by the build
  (`ci_split_verify_layers`) while `C` exists.
* Section 3g names the installer snap and its base statically (`ubuntu-desktop-bootstrap`, `core22`). The library derives the names from
  the difference between the live and the standard snapd seed, so a base ISO whose installer snap moves to another base is handled by
  the build but not by the `BASE_FORBIDDEN` row, which then needs the new name.
* The kernel-line check is an allow-list (`nomodeset`, `iso-scan/filename=${iso_path}`, `ci.autoinstall=1`, then `--- quiet splash`). A
  parameter someone adds on purpose fails it until the list in `verify-iso.sh` (`stock_kernel_line`) is edited; that is the point.
* Companion's own live-session pieces are not split out. The one-click helper (`/usr/libexec/ci-os/ci-os-auto-install`, its launcher and
  autostart hook) and `ci-os-live-container-storage.service` are in the base layer, as is everything `customize-chroot.sh` adds; they guard
  themselves (the helper exits with code 4 outside a live session, the units test for `/cdrom/casper/vmlinuz`). The table lists only what
  the **stock** live layer carries, which has no such guards. Whether the installed system should carry those inert files at all is a
  separate decision.
* The repair that was tried on the installed disk shows a greeter, not a working session.
* The top-level `README.md` still says that a clean ISO install ends up identical to running the provisioning and theming by hand; until a
  split ISO has been installed and booted that sentence is a design intent, not an observation.

## 9. Files

| File | Role |
|---|---|
| `backends/ubuntu/iso/scripts/build-iso.sh` | `repack_squashfs`: calls the split, writes `install-sources.yaml`, `SHA256SUMS` |
| `backends/ubuntu/iso/scripts/lib/split-live-layer.sh` | the table, `ci_split_live_layer`, `ci_split_verify_layers`, `ci_split_write_metadata`, `ci_split_assert_base_tree` |
| `backends/ubuntu/iso/scripts/verify-iso.sh` | section 3g, and the `casper.conf` checks that now read the live layer |
| `backends/ubuntu/iso/scripts/md5sum-txt.sh` | the image's `md5sum.txt` (regenerate, verify) |
| `backends/ubuntu/iso/tests/verify-installer-base.sh` | the mutation test of section 3g, with the drift guard against the library's lists |
| `backends/ubuntu/iso/tests/split-live-layer.sh` | the test of the split library: helpers on synthetic trees, the split on real data |
| `backends/ubuntu/iso/tests/placeholder-layer-modes.sh` | directory modes of the empty placeholder layer |
| `backends/ubuntu/iso/tests/installed-boot.sh`, `tests/lib/` | the installed-system boot test (`--quick`, `--no-boot`, `--selftest`) and its parts |
| `backends/ubuntu/iso/README.md` | build and test overview, the "Layers" section and the troubleshooting entry for the symptom |
