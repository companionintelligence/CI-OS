#!/usr/bin/env bash
#=============================================================================
# Split the merged rootfs into the base layer the installer installs and the live-only delta
#
# Sourced by build-iso.sh (and by tests/split-live-layer.sh); never run on its own.
#
# The problem. build-iso.sh merges the three stock casper layers (minimal, minimal.standard,
# minimal.standard.live) into one rootfs C, customizes it, and has to put it back on the ISO. The live
# session stacks all three layers. The installer (subiquity, via curtin) installs ONE layer, the one
# install-sources.yaml names: minimal.squashfs. If the whole C goes into minimal.squashfs, everything the
# stock LIVE layer holds is copied to the installed disk: the casper package and its initramfs hook (every
# initrd curtin then regenerates carries casper's scripts and "export BOOT=casper", so the machine boots into
# "Unable to find a medium containing a live file system"), the live session's dconf overrides, the installer's
# own snap, a cloud-init default user "installer" with the shell /usr/bin/subiquity-shell, a getty@tty1 masked
# to /dev/null, an udisks2 automount inhibitor ... subiquity has no package-removal step, and the stock ISO
# ships no filesystem.manifest-remove: stock Ubuntu simply never installs the live layer.
#
# The fix. Split C into
#     B  what the installer installs                 -> casper/minimal.squashfs
#     L  exactly what must be stacked on B to give C -> casper/minimal.standard.live.squashfs
# minimal.standard.squashfs stays an empty placeholder (the caller makes it). The live session sees
# overlay(B, placeholder, L) == C, byte for byte, so nothing about it changes; the installer sees B alone.
#
# How. An overlayfs with C as its (read-only) lower directory and a scratch upper directory U. The rows of
# the table below are applied inside that merged view (a chroot for dpkg, glib-compile-schemas and
# apt-get check). B is packed from the merged view. L is derived from U, which holds exactly what changed:
#   - a path U whites out or replaces           -> L gets C's version (a whiteout in U: the whole C subtree);
#   - a path U created that C does not have     -> L gets a whiteout (character device 0:0) for it;
#   - a directory only copied up                -> nothing, unless its mode/owner differ from C's;
#   - a directory hidden without whiteouts      -> C's children that the merged view lost (opaque directory).
# L is staged as a plain directory with rsync from C (so modes, owners, symlinks and xattrs are C's), keeping
# the directory modes exactly: casper stacks layers with overlayfs and a directory present in several layers
# takes its mode from the topmost one (the trap make_placeholder_layer in build-iso.sh documents). Two details:
#   - C's directories carry trusted.overlay.* attributes (impure, origin) that the stock layers had on the builder's
#     overlay upper directories and unsquashfs restored. They mean nothing in a delta layer, and an "opaque" one
#     would hide B's files, so L does not take them over (rsync filter) and the comparison ignores them;
#   - hard links between names of C (the snap blobs under snaps/ and seed/snaps/) are not kept in L: they would not
#     survive a layer boundary anyway, and mksquashfs 4.6 does not keep links between directories in any layer.
#
# Nothing here is trusted until it is checked. ci_split_assert_base_tree is run on the merged view before B is
# packed and on the packed B afterwards, ci_split_verify_layers mounts the three real squashfs layers, stacks
# them the way casper does and compares the stack with C with rsync (content by checksum, modes, owners,
# symlinks, device nodes, xattrs). A `restore` row refuses to run over a path the build itself customized (the
# rootfs's copy must still be the stock live layer's), and dpkg/apt must find the database consistent after the
# removal. Any failure returns non-zero: the caller must stop the build.
#
# Interface (all return non-zero on failure and have logged why):
#   ci_split_live_layer   <chroot> <out-base.squashfs> <out-live.squashfs> <result-dir> [<stock-layer-dir>]
#   ci_split_verify_layers <chroot> <base.squashfs> <placeholder.squashfs> <live.squashfs> <result-dir>
#   ci_split_write_metadata <casper-dir> <result-dir>      the .size and .manifest files of the three layers
#   ci_split_assert_base_tree <root> [<installer-snap>...]  the invariants B must keep, on any directory tree
# Environment (all optional; the shipped build sets none of them):
#   CI_SPLIT_MKSQUASHFS_OPTS  mksquashfs options for both layers (default "-comp xz -b 1M", the build's own)
#   CI_SPLIT_VERIFY           full (default: the comparison checksums every file) or quick (sizes only; tests, never a release)
#   CI_SPLIT_TMPFS_SIZE       size of the tmpfs used where an overlay upper directory or the L stage cannot live on the work
#                             directory's filesystem (default 8g; only what is written counts against memory)
#   CI_SPLIT_KEEP             keep the scratch directories (and say where) instead of removing them, for a post-mortem
# Needs Linux, root, overlayfs, squashfs-tools, rsync >= 3 (-A -X and xattr filters), util-linux (mount), GNU coreutils/findutils.
# The pure helpers (table, excludes, snap and package parsing, manifests, the invariant checks) need only
# bash 3.2, awk, sed, find, sort and cmp, and run on a stock macOS: tests/split-live-layer.sh, Part A.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

# ── logging: build-iso.sh defines log_info/log_warn/log_error; standalone use gets plain ones ───────────────────
if ! declare -F log_info >/dev/null 2>&1; then log_info() { printf '[INFO] %s\n' "$*"; }; fi
if ! declare -F log_warn >/dev/null 2>&1; then log_warn() { printf '[WARN] %s\n' "$*" >&2; }; fi
if ! declare -F log_error >/dev/null 2>&1; then log_error() { printf '[ERROR] %s\n' "$*" >&2; }; fi

# What mksquashfs leaves out of a layer. The comparison in ci_split_verify_layers, the derivation of L and the
# packing all use THIS list, so "what the live session sees" is one definition. Paths are relative to the rootfs;
# a trailing /* excludes everything below that directory and keeps the (empty) directory itself.
CI_SPLIT_PACK_EXCLUDES=('var/cache/apt/archives/*' 'var/lib/apt/lists/*' 'tmp/*' 'root/.bash_history')

# The mksquashfs options both layers are packed with (the build's long-standing ones). Tests may set a faster
# compressor in CI_SPLIT_MKSQUASHFS_OPTS; the shipped build never does.
CI_SPLIT_MKSQUASHFS_OPTS="${CI_SPLIT_MKSQUASHFS_OPTS:--comp xz -b 1M}"

# Snap names that are the installer's whatever the seed comparison says (see ci_split_installer_snap_names).
CI_SPLIT_INSTALLER_SNAPS_FIXED="ubuntu-desktop-bootstrap"

#=============================================================================
# THE TABLE: what the stock live layer carries that the installed system must not have
#=============================================================================
# How it was derived (Ubuntu 24.04.5 base ISO, its three stock layers; tests/split-live-layer.sh group B1 repeats it):
#   1. minimal.standard.live.squashfs lists 56 270 paths (unsquashfs -ll). 55 994 exist in neither lower layer.
#   2. A package of the live layer owns all but 905 of those (the layer's /var/lib/dpkg/info/*.list, usr-merge aware).
#      Those ~115 packages are the kernel, firmware, microcode, grub, shim, zfs, lvm2, mdadm, cryptsetup, the btrfs/xfs/jfs
#      tools, gparted, bpf tools, input-method engines ... On a stock install curtin pulls the kernel and the bootloader
#      from the ISO's pool and the installer offers the storage tools; this image carries them already, they are useful
#      on the disk, and the design keeps them in B: nothing of them is in this table.
#   3. Of the 905 paths that no package owns, 781 are dpkg's own bookkeeping files and the state a package that stays
#      generated (modules.dep, /etc/default/grub, mdadm.conf, crypttab, the zfs rc links, alternatives, the deb-systemd-
#      helper state, the AppArmor cache, python caches). The other 124 are live-only: written by livecd-rootfs for the live
#      session or the installer, or the leftovers of casper and the installer snap. The rows below remove them.
#   4. 66 paths the live layer REWROTE (the same path in a lower layer, other content): 38 are generated state (caches,
#      the dpkg/debconf/ucf databases, logs) that the package scripts and triggers regenerate when the packages below are
#      purged, 2 are whiteouts, 24 are snapd's preseed state (every layer holds a complete, independent preseed run), and
#      two are live settings in files the installed system shares: /etc/cloud/cloud.cfg and systemd-networkd-wait-online.
#      Those are the `restore` rows: they take the stock standard layer's version.
# The packages the table purges are casper's own; no other installed package depends on them (dpkg --purge, run without
# --force-depends, refuses otherwise, and apt-get check must pass afterwards). casper's other two dependencies,
# user-setup and localechooser-data, are inert data (debconf templates; the live user's group list is a debconf answer of
# user-setup) and stay. The input-method engines (ibus-hangul, ibus-mozc, ibus-unikey, gtk-im-libthai and their libraries)
# are live-layer packages too; they stay because typing Korean, Japanese, Vietnamese or Thai works on the installed system
# without a network and without a language pack, and nothing breaks if they are there.
#
# Row format:  kind|argument[|argument]      '#' starts a comment line; the rows run top to bottom.
#   purge|<package>...         dpkg --purge in the chroot (no --force-depends); every package must be installed
#   rm|<path>                  remove, relative to /, globs allowed (>= 2 components, no '..'); absent is fine
#   rmdir|<path>               remove if empty (parents the rm rows leave behind)
#   rmgrep|<glob>|<text>       remove each directory matching the glob whose files mention <text>
#   restore|<path>             make <path> what the STOCK STANDARD stack (minimal + minimal.standard) has; absent there = removed.
#                              Guarded: the rootfs must still hold the stock LIVE stack's copy of <path> (so the build did not
#                              customize it); otherwise the restore would silently drop that from the installed system and the
#                              split stops (ci_split_row_restore)
#   installer-snaps|           delete every file of the installer-only snaps (names: ci_split_installer_snap_names)
#   schemas|                   glib-compile-schemas /usr/share/glib-2.0/schemas, then prove it is up to date
#   rmnew|<glob>               remove matching files the rows above CREATED (C does not have them)
ci_split_table() {
    cat <<'CI_SPLIT_TABLE'
# ── 1. casper ────────────────────────────────────────────────────────────────────────────────────────────────────
# The cause of the unbootable install. casper ships an initramfs hook and boot scripts; update-initramfs bakes them
# into every initrd, and the hook writes conf/conf.d/default-boot-to-casper.conf ("if [ -z "$BOOT" ]; then export
# BOOT=casper"), so a normal boot (root=UUID=..., no boot=) runs casper and looks for a live medium. Purging it also
# takes /etc/casper.conf (a conffile) and, through deb-systemd-helper, the enable links of casper.service and
# casper-md5check.service (the md5 check of the medium is a live feature; it stays in L).
# finalrd exists for casper (casper Depends on it): its finalrd.service is enabled at sysinit and, at every shutdown,
# builds a /run/initramfs for systemd-shutdown to pivot into. A live system needs that to unmount its squashfs root;
# an installed system has no such root and stock Ubuntu does not install it.
purge|casper finalrd
# livecd-rootfs wrote these two for the live initrd (casperize: a random medium UUID; default-layer: which layer the
# live session mounts last). Nothing but casper's hook reads them; update-initramfs on the installed system must not
# find them even if a casper hook ever came back.
rm|etc/initramfs-tools/conf.d/casperize.conf
rm|etc/initramfs-tools/conf.d/default-layer.conf

# ── 2. the live session's dconf overrides ────────────────────────────────────────────────────────────────────────
# livecd-rootfs.gschema.override makes an "installer only" session: universal-access status always shown, the dock
# not fixed, the desktop-icons extension disabled. Compiled into gschemas.compiled it would give the installed
# desktop those defaults, so it goes and the schemas are compiled again (the `schemas` row proves the result).
rm|usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override
schemas|

# ── 3. the installer: units, config, snap ────────────────────────────────────────────────────────────────────────
# ubuntu-desktop-installer.service starts /snap/bin/ubuntu-desktop-bootstrap at every graphical session start. The
# live layer enables it with a user-level wants link. subiquity_config.mount and the device drop-in that Wants= it
# mount the autoinstall config disk of the live medium. /etc/subiquity/kernel-meta-package is read by subiquity from
# the LIVE root (subiquity/server/controllers/kernel.py, base_model.root), never from the installed one.
rm|usr/lib/systemd/user/ubuntu-desktop-installer.service
rm|etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service
rmdir|etc/systemd/user/graphical-session.target.wants
rm|usr/lib/systemd/system/subiquity_config.mount
rmgrep|etc/systemd/system/dev-disk-by*.device.d|subiquity_config.mount
rm|etc/subiquity
# The installer snap and the snap it needs as a base (names: the live seed minus the standard seed; today
# ubuntu-desktop-bootstrap and core22), with everything snapd generated for them. The snapd state of the stock
# STANDARD layer is a complete, self-consistent preseed run of the snaps the installed system has (state.json,
# seed.yaml, the snap cookies that state.json maps, the mount and AppArmor files); the live layer's is another
# complete run that also covers the installer snap, with other cookies. Mixing them breaks the snap cookies, and
# a state.json that knows a snap whose file is gone makes snapd fail to seed. So B takes the standard layer's state
# as it is (restore rows: whole directories, not edited JSON) and loses the installer snap's blobs, mounts and units.
installer-snaps|
restore|var/lib/snapd/state.json
restore|var/lib/snapd/system-key
restore|var/lib/snapd/seed/seed.yaml
restore|var/lib/snapd/seed/assertions
restore|var/lib/snapd/assertions
restore|var/lib/snapd/apparmor/profiles
restore|var/lib/snapd/cgroup
restore|var/lib/snapd/cookie
restore|var/lib/snapd/desktop/applications
restore|var/lib/snapd/inhibit
restore|var/lib/snapd/mount
restore|var/lib/snapd/seccomp/bpf
restore|var/lib/snapd/sequence
restore|var/cache/snapd/aux

# ── 4. live settings in files the installed system shares ────────────────────────────────────────────────────────
# /etc/cloud/cloud.cfg of the live layer is the installer session's: default_user "installer" (unlocked, shell
# /usr/bin/subiquity-shell, NOPASSWD sudo), ssh_pwauth, a built-in DHCP network. With the nocloud seed below it
# would be a way in on the installed machine. The stock standard layer's file is what a stock install has.
restore|etc/cloud/cloud.cfg
# livecd-rootfs replaces the real systemd-networkd-wait-online by a symlink to /bin/true so the live boot never waits
# for a network; the installed system wants the real binary back.
restore|usr/lib/systemd/systemd-networkd-wait-online

# ── 5. the rest of livecd-rootfs's live-only writings ────────────────────────────────────────────────────────────
# NoCloud seed with empty meta-data/user-data (makes cloud-init pick a datasource in the live session), the quiet
# output config that goes with it, and the nested copy of the apt pin backup that livecd-rootfs made while the live image was
# built (/etc/apt/preferences.d.save/preferences.d; apt reads only /etc/apt/preferences.d). The stock STANDARD layer has
# /etc/apt/preferences.d.save with the two flat ubuntu-pro-esm-* files, so a stock install has them: they stay, the live layer's
# nested copy goes.
rm|var/lib/cloud/seed/nocloud
rmdir|var/lib/cloud/seed
rmdir|var/lib/cloud
rm|etc/cloud/cloud.cfg.d/06_quiet.cfg
rm|etc/apt/preferences.d.save/preferences.d
rm|root/packages.chroot
# getty@tty1 is masked (-> /dev/null) because the live session logs in on tty1 itself through casper-getty; masked
# on the installed system it leaves no login prompt on tty1.
rm|usr/lib/systemd/system/getty@tty1.service
# udisks2-inhibit.service writes a udev rule that sets UDISKS_IGNORE=1 on every block device, so the live session
# does not automount the medium it runs from. On the installed system no USB stick or disk would ever mount; its
# enable link and the dangling local-fs link to a media-filesystem.mount that does not exist go with it.
rm|usr/lib/systemd/system/udisks2-inhibit.service
rm|usr/lib/systemd/system/graphical.target.wants/udisks2-inhibit.service
rm|usr/lib/systemd/system/local-fs.target.wants/media-filesystem.mount
# SNAP_REEXEC=0: the live snapd never re-executes into the snapd snap (the installer runs from a read-only image);
# an installed snapd should (stock behaviour).
rm|usr/lib/systemd/system/snapd.service.d/no-reexec.conf
rmdir|usr/lib/systemd/system/snapd.service.d
rmdir|usr/lib/systemd/system/local-fs.target.wants
# journald settings that make the journal readable by the old libsystemd inside the installer snap, and stop the live
# session's log from being rate limited. The installed system has no such reader.
rm|etc/systemd/journald.conf.d/no-rate-limit.conf
rm|etc/systemd/system/systemd-journald.service.d/no-compact.conf
rm|etc/systemd/system/systemd-journald.service.d/no-hardening.conf
rmdir|etc/systemd/journald.conf.d
rmdir|etc/systemd/system/systemd-journald.service.d

# ── 6. things the rows above made as a side effect ───────────────────────────────────────────────────────────────
# dpkg's triggers may build an initrd for the kernel the BUILD HOST runs when it is the image's too (update-initramfs
# -u); the live layer ships no initrd (livecd-rootfs deletes them: the ISO's casper/initrd is the live one), and the
# installer's curtin generates the installed one. An initrd here would be built from the build host's state.
rmnew|boot/initrd.img-*
CI_SPLIT_TABLE
}

# The table without comments and blank lines, one row per line.
ci_split_table_rows() {
    ci_split_table | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d'
}

# ci_split_validate_table: every row has a known kind and arguments of the right shape; a path is relative, has at
# least two components and no '..' (a typo must not make the build delete /etc). Prints one line per problem.
ci_split_validate_table() {
    local row kind arg1 arg2 p bad=0 n=0 rest
    while IFS= read -r row; do
        n=$((n + 1))
        kind="${row%%|*}"
        if [[ "$row" == *"|"* ]]; then rest="${row#*|}"; else rest=""; fi
        arg1="${rest%%|*}"
        if [[ "$rest" == *"|"* ]]; then arg2="${rest#*|}"; else arg2=""; fi
        case "$kind" in
            purge)
                if [[ -z "$arg1" || "$arg1" == *[^a-z0-9.+\ -]* ]]; then echo "row $n: purge needs package names: $row"; bad=1; fi ;;
            rm|rmdir|rmnew|restore)
                p="$arg1"
                if [[ -z "$p" || "$p" == /* || "$p" == *..* || "$p" != */* || "$p" == *" "* || -n "$arg2" ]]; then
                    echo "row $n: $kind needs one relative path of at least two components, no '..': $row"; bad=1
                fi ;;
            rmgrep)
                p="$arg1"
                if [[ -z "$p" || "$p" == /* || "$p" == *..* || "$p" != */* || -z "$arg2" ]]; then
                    echo "row $n: rmgrep needs a path glob and a text: $row"; bad=1
                fi ;;
            installer-snaps|schemas)
                if [[ -n "$rest" ]]; then echo "row $n: $kind takes no argument: $row"; bad=1; fi ;;
            *) echo "row $n: unknown kind '$kind': $row"; bad=1 ;;
        esac
    done < <(ci_split_table_rows)
    [[ "$n" -gt 0 ]] || { echo "the table has no rows"; bad=1; }
    return "$bad"
}

#=============================================================================
# Pure helpers (no root, no mounts)
#=============================================================================

# ci_split_is_excluded <path relative to />: true when mksquashfs leaves it out of a layer (CI_SPLIT_PACK_EXCLUDES).
ci_split_is_excluded() {
    local rel="${1#/}" e
    for e in "${CI_SPLIT_PACK_EXCLUDES[@]}"; do
        # shellcheck disable=SC2053
        [[ "$rel" == $e ]] && return 0
    done
    return 1
}

# ci_split_status_pkgs <dpkg status file>: "name<TAB>version" of every installed package, sorted. A Multi-Arch: same
# package is "name:arch", as dpkg-query's ${binary:Package} (and the stock layer manifests) write it.
ci_split_status_pkgs() {
    awk 'BEGIN { RS = ""; FS = "\n" }
         { n = ""; v = ""; a = ""; m = ""; ok = 0
           for (i = 1; i <= NF; i++) {
               if ($i ~ /^Package: /) n = substr($i, 10)
               else if ($i ~ /^Version: /) v = substr($i, 10)
               else if ($i ~ /^Architecture: /) a = substr($i, 15)
               else if ($i ~ /^Multi-Arch: /) m = substr($i, 13)
               else if ($i == "Status: install ok installed") ok = 1
           }
           if (ok && n != "") { if (m == "same" && a != "") n = n ":" a; print n "\t" v } }' "$1" | LC_ALL=C sort -u
}

# ci_split_seed_snaps <seed.yaml>: "name<TAB>channel<TAB>revision" per seeded snap, in file order (the revision is the
# one in the snap's file name, name_<rev>.snap). The stock layer manifests list them as "+snap:<name><TAB>channel<TAB>rev".
ci_split_seed_snaps() {
    [[ -r "$1" ]] || return 0
    awk '
        function flush() { if (name != "") { rev = file; sub(/\.snap$/, "", rev); sub(/^.*_/, "", rev); print name "\t" channel "\t" rev } name = ""; channel = ""; file = "" }
        /^[[:space:]]*-[[:space:]]*$/ { flush(); next }
        /^[[:space:]]*name:/    { sub(/^[[:space:]]*name:[[:space:]]*/, ""); name = $0; next }
        /^[[:space:]]*channel:/ { sub(/^[[:space:]]*channel:[[:space:]]*/, ""); channel = $0; next }
        /^[[:space:]]*file:/    { sub(/^[[:space:]]*file:[[:space:]]*/, ""); file = $0; next }
        END { flush() }' "$1" | tr -d '\r"'"'"
}

# ci_split_installer_snap_names <live seed.yaml> <stock standard seed.yaml>: one snap name per line, the snaps the live
# layer seeds that the installed system (the standard stack) does not, plus CI_SPLIT_INSTALLER_SNAPS_FIXED.
# Dynamic, so a base ISO that moves the installer snap's base from core22 to something else needs no edit here.
ci_split_installer_snap_names() {
    local live="$1" std="$2" n
    {
        for n in $CI_SPLIT_INSTALLER_SNAPS_FIXED; do echo "$n"; done
        if [[ -r "$std" && -r "$live" ]]; then
            ci_split_seed_snaps "$live" | cut -f1 | LC_ALL=C sort -u > "${TMPDIR:-/tmp}/.ci-split-live-snaps.$$"
            ci_split_seed_snaps "$std" | cut -f1 | LC_ALL=C sort -u > "${TMPDIR:-/tmp}/.ci-split-std-snaps.$$"
            LC_ALL=C comm -23 "${TMPDIR:-/tmp}/.ci-split-live-snaps.$$" "${TMPDIR:-/tmp}/.ci-split-std-snaps.$$"
            rm -f "${TMPDIR:-/tmp}/.ci-split-live-snaps.$$" "${TMPDIR:-/tmp}/.ci-split-std-snaps.$$"
        fi
    } | LC_ALL=C sort -u
}

# ci_split_manifest_file <lower layer name> <this layer name> <package-lines-file> [<snap-lines-file>]
# The stock per-layer manifest: a unified-diff-shaped file, "+name<TAB>version" per package this layer adds (and "-" for
# one it takes away), then "+snap:name<TAB>channel<TAB>revision" lines. Prints it on stdout.
ci_split_manifest_file() {
    local lower="$1" this="$2" pkgs="$3" snaps="${4:-}" now
    now="$(date -u '+%Y-%m-%d %H:%M:%S.000000000 +0000')"
    if [[ -z "$lower" ]]; then
        printf -- '--- /build/livecd.ubuntu..manifest.full\t1970-01-01 00:00:00.000000000 +0000\n'
    else
        printf -- '--- /build/livecd.ubuntu.%s.manifest.full\t%s\n' "$lower" "$now"
    fi
    printf -- '+++ /build/livecd.ubuntu.%s.manifest.full\t%s\n' "$this" "$now"
    if [[ -s "$pkgs" ]]; then awk -F'\t' '{ print "+" $1 "\t" $2 }' "$pkgs"; fi
    if [[ -n "$snaps" && -s "$snaps" ]]; then awk -F'\t' '{ print "+snap:" $1 "\t" $2 "\t" $3 }' "$snaps"; fi
    return 0
}

# ci_split_diff_lines <old-file> <new-file> <sign-prefix-for-added-removed>: package lines (name<TAB>version) only in the
# new file as "+...", only in the old as "-...", sorted by name. Used for the live layer's manifest.
ci_split_diff_lines() {
    LC_ALL=C comm -13 "$1" "$2" | awk '{ print "+" $0 }'
    LC_ALL=C comm -23 "$1" "$2" | awk '{ print "-" $0 }'
}

# ci_split_assert_base_tree <root> [<installer snap name>...]: the invariants the installed system's base must keep, checked
# on any directory tree (the merged view, the mounted layer, a synthetic tree). Independent of the table on purpose: it
# is what B must never contain, not what the table happens to remove. Prints one line per violation; returns 1 if any.
ci_split_assert_base_tree() {
    local root="${1%/}" snap bad=0 f g status
    shift || true
    [[ -d "$root" ]] || { echo "not a directory: $root"; return 1; }

    # never present in the installed system's base (a glob matches or it does not). This array and CI_SPLIT_LIVE_REQUIRED
    # below are read by tests/verify-installer-base.sh, a drift guard against verify-iso.sh section 3g: it cuts them out by
    # their opening and closing lines, so keep both arrays in this layout and quote no such line in a comment.
    local -a gone=(
        etc/casper.conf
        etc/initramfs-tools/conf.d/casperize.conf etc/initramfs-tools/conf.d/default-layer.conf
        usr/share/initramfs-tools/hooks/casper 'usr/share/initramfs-tools/scripts/casper*'
        usr/lib/casper usr/share/casper usr/share/doc/casper 'usr/sbin/casper-*' 'sbin/casper-*'
        'usr/lib/systemd/system/casper*.service' 'etc/systemd/system/*/casper*.service' 'var/lib/dpkg/info/casper.*'
        'var/lib/systemd/deb-systemd-helper-enabled/*casper*' 'var/lib/systemd/deb-systemd-helper-enabled/*/casper*'
        usr/lib/finalrd usr/bin/finalrd 'etc/systemd/system/*/finalrd.service' 'var/lib/dpkg/info/finalrd.*'
        usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override
        etc/subiquity etc/cloud/cloud.cfg.d/06_quiet.cfg etc/apt/preferences.d.save/preferences.d var/lib/cloud/seed/nocloud
        root/packages.chroot
        usr/lib/systemd/user/ubuntu-desktop-installer.service
        etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service
        usr/lib/systemd/system/subiquity_config.mount
        usr/lib/systemd/system/udisks2-inhibit.service usr/lib/systemd/system/graphical.target.wants/udisks2-inhibit.service
        usr/lib/systemd/system/getty@tty1.service
        usr/lib/systemd/system/snapd.service.d/no-reexec.conf
        etc/systemd/journald.conf.d/no-rate-limit.conf
        etc/systemd/system/systemd-journald.service.d/no-compact.conf etc/systemd/system/systemd-journald.service.d/no-hardening.conf
    )
    for g in "${gone[@]}"; do
        # shellcheck disable=SC2231
        for f in $root/$g; do
            if [[ -e "$f" || -L "$f" ]]; then echo "live-only path in the base: /${f#"$root"/}"; bad=1; fi
        done
    done

    # the packages (in no state: a purged package leaves no stanza, a removed one with config files leaves one)
    status="$root/var/lib/dpkg/status"
    if [[ -r "$status" ]]; then
        for g in casper finalrd; do
            if awk -v p="$g" 'BEGIN { RS = ""; FS = "\n" } $1 == "Package: " p { f = 1 } END { exit !f }' "$status"; then
                echo "package $g is in the base's dpkg status"; bad=1
            fi
        done
    else
        echo "no var/lib/dpkg/status to check the packages against"; bad=1
    fi

    # the installer snaps: static name plus the ones the caller derived
    for snap in $CI_SPLIT_INSTALLER_SNAPS_FIXED "$@"; do
        [[ -n "$snap" ]] || continue
        for f in "$root"/var/lib/snapd/seed/seed.yaml "$root"/var/lib/snapd/state.json; do
            if [[ -r "$f" ]] && grep -q -F -- "$snap" "$f"; then echo "${f#"$root"/} still names the installer snap $snap"; bad=1; fi
        done
        for g in snap var/snap var/lib/snapd var/cache/apparmor var/cache/snapd; do
            [[ -d "$root/$g" ]] || continue
            f="$(find "$root/$g" \( -name "$snap" -o -name "${snap}_*" -o -name "${snap}.*" -o -name "snap.${snap}" -o -name "snap.${snap}.*" \
                  -o -name "snap-update-ns.${snap}" \) -print 2>/dev/null | head -n 3 | tr '\n' ' ')"
            if [[ -n "$f" ]]; then echo "installer snap $snap left in the base: ${f%% }"; bad=1; fi
        done
        # systemd unit names escape '-' as \x2d
        f="$(find "$root/etc/systemd/system" -maxdepth 2 \( -name "snap-${snap//-/\\\\x2d}-*" -o -name "snap-${snap}-*" -o -name "snap.${snap}.*" \) -print 2>/dev/null | head -n 3 | tr '\n' ' ')"
        if [[ -n "$f" ]]; then echo "installer snap $snap has systemd units in the base: ${f%% }"; bad=1; fi
    done

    # the snapd seed: every snap file seed.yaml names is in the base (snapd on the installed system refuses to seed otherwise, and a
    # restore row that took a seed.yaml from one layer and snaps from another would leave exactly this)
    if [[ -r "$root/var/lib/snapd/seed/seed.yaml" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            if [[ ! -f "$root/var/lib/snapd/seed/snaps/$f" ]]; then echo "var/lib/snapd/seed/seed.yaml names the snap file $f, which the base does not have"; bad=1; fi
        done < <(sed -n 's/^[[:space:]-]*file:[[:space:]]*//p' "$root/var/lib/snapd/seed/seed.yaml" | tr -d '\r"'"'"'')
    fi

    # cloud-init: the live copy creates the user "installer" with the installer's shell
    if [[ -r "$root/etc/cloud/cloud.cfg" ]] && grep -q 'subiquity-shell' "$root/etc/cloud/cloud.cfg"; then
        echo "etc/cloud/cloud.cfg is the live session's (subiquity-shell)"; bad=1
    fi
    if [[ -L "$root/usr/lib/systemd/systemd-networkd-wait-online" ]] \
       && [[ "$(readlink "$root/usr/lib/systemd/systemd-networkd-wait-online")" == /bin/true ]]; then
        echo "systemd-networkd-wait-online is the live session's symlink to /bin/true"; bad=1
    fi
    return "$bad"
}

#=============================================================================
# Mounts and cleanup (Linux, root)
#=============================================================================
CI_SPLIT_MOUNTS=()      # mount points to unmount on exit, in mount order
CI_SPLIT_LOOPS=()       # loop devices to detach on exit
CI_SPLIT_SCRATCH_DIRS=()  # scratch directories to remove on exit (only when nothing is mounted below them)
CI_SPLIT_TRAPS_SET=""

ci_split_cleanup() {
    local i d rc=0 errexit=0
    # Cleanup must go on after a failed umount, so errexit is off while it runs. `set` is global, not per function: the caller's
    # setting (build-iso.sh runs under `set -e`) has to be put back, or every step after the split would silently stop aborting.
    case "$-" in *e*) errexit=1 ;; esac
    set +e
    for ((i = ${#CI_SPLIT_MOUNTS[@]} - 1; i >= 0; i--)); do
        d="${CI_SPLIT_MOUNTS[$i]}"
        umount "$d" 2>/dev/null || umount -l "$d" 2>/dev/null || { log_warn "split: could not unmount $d"; rc=1; }
    done
    CI_SPLIT_MOUNTS=()
    for ((i = ${#CI_SPLIT_LOOPS[@]} - 1; i >= 0; i--)); do losetup -d "${CI_SPLIT_LOOPS[$i]}" 2>/dev/null; done
    CI_SPLIT_LOOPS=()
    for d in "${CI_SPLIT_SCRATCH_DIRS[@]}"; do
        [[ -n "$d" && -d "$d" ]] || continue
        if [[ -n "${CI_SPLIT_KEEP:-}" ]]; then log_info "split: keeping $d (CI_SPLIT_KEEP)"; continue; fi
        # Never remove a tree something is still mounted in (a bind of /dev would be followed): leave it and say so.
        if grep -q -F -- " $d/" /proc/self/mountinfo 2>/dev/null; then
            log_error "split: $d still has a mount below it; NOT removing it (unmount it by hand)"; rc=1; continue
        fi
        rm -rf --one-file-system -- "$d"
    done
    CI_SPLIT_SCRATCH_DIRS=()
    if [[ "$errexit" -eq 1 ]]; then set -e; fi
    return "$rc"
}

# Install the exit/INT/TERM traps once; they run ci_split_cleanup first and then whatever trap the caller had.
ci_split_traps_install() {
    local prev
    [[ -z "$CI_SPLIT_TRAPS_SET" ]] || return 0
    CI_SPLIT_PREV_EXIT=""
    # In a subshell (the caller captured our output with $(...)) `trap -p` still reports the PARENT's trap, which must not
    # be run, let alone re-armed, by the subshell.
    if [[ "${BASHPID:-$$}" == "$$" ]]; then
        prev="$(trap -p EXIT)"
        if [[ -n "$prev" ]]; then eval "set -- $prev"; CI_SPLIT_PREV_EXIT="${3:-}"; fi
    fi
    trap 'ci_split_cleanup; eval "${CI_SPLIT_PREV_EXIT:-:}"' EXIT
    trap 'ci_split_cleanup; exit 130' INT
    trap 'ci_split_cleanup; exit 143' TERM
    CI_SPLIT_TRAPS_SET=1
}

ci_split_traps_remove() {
    [[ -n "$CI_SPLIT_TRAPS_SET" ]] || return 0
    if [[ -n "${CI_SPLIT_PREV_EXIT:-}" ]]; then
        # shellcheck disable=SC2064
        trap "$CI_SPLIT_PREV_EXIT" EXIT
    else
        trap - EXIT
    fi
    trap - INT TERM
    CI_SPLIT_TRAPS_SET=""
}

ci_split_track_mount() { CI_SPLIT_MOUNTS+=("$1"); }

# ci_split_loop_mount <squashfs> <mountpoint>: read-only loop mount. Docker Desktop's VM allocates loop devices whose
# nodes the container's /dev does not have ("device node is lost"): create the node and try again.
ci_split_loop_mount() {
    local f="$1" d="$2" out="" dev="" next i
    mkdir -p "$d" || return 1
    if mount -t squashfs -o loop,ro "$f" "$d" 2>/dev/null; then ci_split_track_mount "$d"; return 0; fi
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        next="$(losetup -f 2>/dev/null)" || { out="no free loop device"; break; }
        [[ -b "$next" ]] || mknod "$next" b 7 "${next#/dev/loop}" 2>/dev/null || true
        if out="$(losetup -r "$next" "$f" 2>&1)"; then dev="$next"; break; fi
    done
    if [[ -z "$dev" ]]; then log_error "split: cannot attach a loop device for $f: $out"; return 1; fi
    CI_SPLIT_LOOPS+=("$dev")
    mount -t squashfs -o ro "$dev" "$d" || { log_error "split: cannot mount $f ($dev) on $d"; return 1; }
    ci_split_track_mount "$d"
}

# ci_split_overlay_mount <lowerdirs, topmost first> <mountpoint> [<upper> <work>]: read-only without an upper.
ci_split_overlay_mount() {
    local lower="$1" d="$2" upper="${3:-}" work="${4:-}" opts
    mkdir -p "$d" || return 1
    if [[ -n "$upper" ]]; then
        opts="lowerdir=$lower,upperdir=$upper,workdir=$work"
        # redirect_dir/metacopy/index off: a rename or a metadata-only copy-up would leave xattrs in U that L's derivation
        # does not model. (Most kernels already default to off; the options are refused only on very old ones.)
        mount -t overlay overlay -o "$opts,redirect_dir=off,metacopy=off,index=off" "$d" 2>/dev/null \
            || mount -t overlay overlay -o "$opts" "$d" 2>/dev/null || return 1
    else
        mount -t overlay overlay -o "lowerdir=$lower" "$d" 2>/dev/null || return 1
    fi
    ci_split_track_mount "$d"
}

# Run a command inside the chroot with a clean environment.
ci_split_chroot() {
    local root="$1"; shift
    chroot "$root" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 TERM=dumb \
        DEBIAN_FRONTEND=noninteractive "$@"
}

# The portable stat helpers (GNU on the build host, BSD for the pure tests).
ci_split_attrs() { stat -c '%a %u %g' "$1" 2>/dev/null || stat -f '%Lp %u %g' "$1"; }
ci_split_rdev() { stat -c '%t:%T' "$1" 2>/dev/null || stat -f '%Hr:%Lr' "$1"; }
ci_split_is_whiteout() { [[ -c "$1" ]] && [[ "$(ci_split_rdev "$1")" == "0:0" ]]; }

ci_split_require() {
    local t missing=""
    if [[ "$(uname -s)" != Linux ]]; then log_error "split: needs Linux (overlayfs, chroot, mount)"; return 1; fi
    if [[ "$(id -u)" -ne 0 ]]; then log_error "split: needs root"; return 1; fi
    for t in mksquashfs unsquashfs rsync mount umount chroot mknod find sort comm cmp awk sed du cut tr grep stat; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [[ -n "$missing" ]]; then log_error "split: missing tools:$missing"; return 1; fi
    if ! grep -qw overlay /proc/filesystems 2>/dev/null; then
        modprobe overlay >/dev/null 2>&1 || true
        grep -qw overlay /proc/filesystems 2>/dev/null || { log_error "split: this kernel has no overlayfs"; return 1; }
    fi
}

#=============================================================================
# The rows
#=============================================================================

ci_split_row_purge() { # <merged> <package>...
    local M="$1" p installed; shift
    installed="$(ci_split_status_pkgs "$M/var/lib/dpkg/status" | cut -f1)"
    for p in "$@"; do
        if ! printf '%s\n' "$installed" | grep -qx -- "$p"; then
            log_error "split: package $p is not installed in the rootfs: the table is stale for this base image"; return 1
        fi
    done
    log_info "split: dpkg --purge $*"
    ci_split_chroot "$M" dpkg --purge "$@" || {
        log_error "split: dpkg --purge $* failed (a package that stays depends on one of them, or a maintainer script failed)"; return 1; }
}

ci_split_row_rm() { # <merged> <path or glob>
    local M="$1" pat="$2" f n=0
    while IFS= read -r -d '' f; do
        if [[ -e "$M/$f" || -L "$M/$f" ]]; then rm -rf -- "$M/${f:?}" || return 1; n=$((n + 1)); fi
    done < <(cd "$M" && shopt -s nullglob dotglob && for f in $pat; do printf '%s\0' "$f"; done)
    [[ "$n" -gt 0 ]] && log_info "split: rm /$pat ($n)"
    return 0
}

ci_split_row_rmdir() { # <merged> <stock standard view or ""> <path>
    local M="$1" S="$2" rel="$3"
    # a directory the stock standard stack has stays, empty or not: it is the installed system's own
    if [[ -n "$S" && -d "$S/$rel" ]]; then return 0; fi
    if [[ -d "$M/$rel" && ! -L "$M/$rel" ]] && rmdir -- "$M/$rel" 2>/dev/null; then log_info "split: rmdir /$rel"; fi
    return 0
}

ci_split_row_rmgrep() { # <merged> <glob> <text>
    local M="$1" pat="$2" text="$3" d n=0
    while IFS= read -r -d '' d; do
        [[ -d "$M/$d" ]] || continue
        if grep -rqs -F -- "$text" "$M/$d"; then rm -rf -- "$M/${d:?}" || return 1; n=$((n + 1)); fi
    done < <(cd "$M" && shopt -s nullglob dotglob && for d in $pat; do printf '%s\0' "$d"; done)
    [[ "$n" -gt 0 ]] && log_info "split: rm /$pat naming $text ($n)"
    return 0
}

# ci_split_same_path <root A> <root B> <relative path>: 0 when the path is the same in both trees (both absent, or the same type,
# content by checksum, mode, owner, link target and xattrs, a directory entry for entry). Prints what differs on stdout.
ci_split_same_path() {
    local a="$1/$3" b="$2/$3" out
    if [[ ! -e "$a" && ! -L "$a" && ! -e "$b" && ! -L "$b" ]]; then return 0; fi
    if [[ -d "$a" && ! -L "$a" && -d "$b" && ! -L "$b" ]]; then
        out="$(rsync -rlpgoDAXc "--filter=-x trusted.overlay.*" --numeric-ids -n --delete -i "$a/" "$b/" 2>&1)" || { echo "rsync failed: $out"; return 1; }
    elif { [[ -e "$a" || -L "$a" ]] && [[ ! -d "$a" || -L "$a" ]]; } && { [[ -e "$b" || -L "$b" ]] && [[ ! -d "$b" || -L "$b" ]]; }; then
        out="$(rsync -lpgoDAXc "--filter=-x trusted.overlay.*" --numeric-ids -n -i "$a" "$b" 2>&1)" || { echo "rsync failed: $out"; return 1; }
    else
        echo "present on one side only, or a directory on one side and not on the other"; return 1
    fi
    [[ -z "$out" ]] || { printf '%s\n' "$out"; return 1; }
}

ci_split_row_restore() { # <merged> <stock standard view> <path> <original rootfs> <stock live view, the three stock layers stacked, or "">
    local M="$1" S="$2" rel="$3" C="${4:-}" LV="${5:-}" src dst diff
    if [[ -z "$S" ]]; then log_error "split: 'restore|$rel' needs the stock layers (pass the stock layer directory)"; return 1; fi
    # The guard. A restore row exists to undo what the stock LIVE layer did to a file the installed system shares. If the rootfs's
    # copy is not the stock live layer's, the build changed it as well (customize-chroot.sh, a package it installed), and putting
    # the stock standard copy back would drop that change from the installed system while the live session keeps it. Stop and
    # let a person decide, rather than ship a quietly different installed system.
    if [[ -n "$LV" && -n "$C" ]]; then
        if ! diff="$(ci_split_same_path "$C" "$LV" "$rel")"; then
            log_error "split: 'restore|$rel': the rootfs differs from the stock live layer's copy ($(printf '%s' "$diff" | head -n 3 | tr '\n' '|')): the build customized it, and the restore would drop that from the installed system while the live session keeps it. Add the change to the installed system's copy after the row, or remove the row"
            return 1
        fi
    else
        log_warn "split: 'restore|$rel': cannot check that the build left it alone (no stock live layer was given)"
    fi
    # -c: rsync's own quick check (same size and mtime means same file) would skip a file that differs in content only, which
    # is exactly the case when two layers were built with a clamped timestamp.
    src="$S/$rel"; dst="$M/$rel"
    if [[ -d "$src" && ! -L "$src" ]]; then
        if [[ -e "$dst" || -L "$dst" ]] && { [[ -L "$dst" ]] || [[ ! -d "$dst" ]]; }; then rm -rf -- "${dst:?}"; fi
        mkdir -p "$dst" || return 1
        rsync -aAXc --numeric-ids --delete "$src/" "$dst/" || { log_error "split: restore of /$rel failed"; return 1; }
    elif [[ -e "$src" || -L "$src" ]]; then
        if [[ -d "$dst" && ! -L "$dst" ]]; then rm -rf -- "${dst:?}"; fi
        mkdir -p "$(dirname "$dst")" || return 1
        rsync -aAXc --numeric-ids "$src" "$dst" || { log_error "split: restore of /$rel failed"; return 1; }
    else
        rm -rf -- "${dst:?}"
    fi
    log_info "split: restore /$rel from the stock standard stack"
}

ci_split_row_installer_snaps() { # <merged> <stock standard view or ""> <original rootfs>
    local M="$1" S="$2" C="$3" names n e root std_seed="" count=0
    [[ -n "$S" ]] && std_seed="$S/var/lib/snapd/seed/seed.yaml"
    if [[ -n "$S" && ! -r "$std_seed" ]]; then
        log_warn "split: the stock standard stack has no var/lib/snapd/seed/seed.yaml: only the fixed installer snap names are swept"
    fi
    names="$(ci_split_installer_snap_names "$C/var/lib/snapd/seed/seed.yaml" "$std_seed")"
    printf '%s\n' "$names" > "${CI_SPLIT_RESULT_DIR:-/dev/null}/installer-snaps.txt" 2>/dev/null || true
    for n in $names; do
        e="${n//-/\\\\x2d}"
        for root in snap var/snap var/lib/snapd var/cache/apparmor var/cache/snapd etc/systemd/system; do
            [[ -d "$M/$root" ]] || continue
            # shellcheck disable=SC2016
            count=$((count + $(cd "$M" && find "$root" \( -name "$n" -o -name "${n}_*" -o -name "${n}.*" -o -name "snap.${n}" \
                -o -name "snap.${n}.*" -o -name "snap-update-ns.${n}" -o -name "snap-${e}-*" -o -name "snap-${n}-*" \) \
                -prune -print -exec rm -rf -- {} + 2>/dev/null | wc -l)))
        done
    done
    log_info "split: installer snaps ($(printf '%s' "$names" | tr '\n' ' ' | sed 's/ $//')): $count paths removed"
}

ci_split_row_schemas() { # <merged>
    local M="$1"
    ci_split_chroot "$M" glib-compile-schemas /usr/share/glib-2.0/schemas \
        || { log_error "split: glib-compile-schemas failed"; return 1; }
    # Proof that gschemas.compiled matches the XML and overrides that are left: compile them again elsewhere and compare.
    ci_split_chroot "$M" sh -c 'd="$(mktemp -d)" && glib-compile-schemas --targetdir="$d" /usr/share/glib-2.0/schemas \
        && cmp -s "$d/gschemas.compiled" /usr/share/glib-2.0/schemas/gschemas.compiled; r=$?; rm -rf "$d"; exit $r' \
        || { log_error "split: gschemas.compiled is not what the schemas and overrides left in the rootfs compile to"; return 1; }
    log_info "split: glib schemas recompiled without the live overrides"
}

ci_split_row_rmnew() { # <merged> <original rootfs> <glob>
    local M="$1" C="$2" pat="$3" f n=0
    while IFS= read -r -d '' f; do
        if [[ ! -e "$C/$f" && ! -L "$C/$f" ]]; then rm -f -- "$M/${f:?}" && n=$((n + 1)); fi
    done < <(cd "$M" && shopt -s nullglob dotglob && for f in $pat; do printf '%s\0' "$f"; done)
    [[ "$n" -gt 0 ]] && log_info "split: removed $n byproduct(s) matching /$pat"
    return 0
}

# ci_split_apply_table <merged> <stock standard view or ""> <original rootfs> [<stock live view or "">]
ci_split_apply_table() {
    local M="$1" S="$2" C="$3" LV="${4:-}" row kind rest arg1 arg2
    local -a pk
    while IFS= read -r row; do
        kind="${row%%|*}"
        if [[ "$row" == *"|"* ]]; then rest="${row#*|}"; else rest=""; fi
        arg1="${rest%%|*}"
        if [[ "$rest" == *"|"* ]]; then arg2="${rest#*|}"; else arg2=""; fi
        case "$kind" in
            purge)           read -r -a pk <<<"$arg1"
                             ci_split_row_purge "$M" "${pk[@]}" || return 1 ;;
            rm)              ci_split_row_rm "$M" "$arg1" || return 1 ;;
            rmdir)           ci_split_row_rmdir "$M" "$S" "$arg1" ;;
            rmgrep)          ci_split_row_rmgrep "$M" "$arg1" "$arg2" || return 1 ;;
            restore)         ci_split_row_restore "$M" "$S" "$arg1" "$C" "$LV" || return 1 ;;
            installer-snaps) ci_split_row_installer_snaps "$M" "$S" "$C" || return 1 ;;
            schemas)         ci_split_row_schemas "$M" || return 1 ;;
            rmnew)           ci_split_row_rmnew "$M" "$C" "$arg1" || return 1 ;;
            *)               log_error "split: unknown table row: $row"; return 1 ;;
        esac
    done < <(ci_split_table_rows)
}

#=============================================================================
# Deriving L from the upper directory
#=============================================================================

# ci_split_emit_subtree <rootfs> <rel>: NUL-separated: rel and, for a real directory, everything below it that a layer keeps.
ci_split_emit_subtree() {
    local C="$1" rel="$2" f
    ci_split_is_excluded "$rel" && return 0
    printf '%s\0' "$rel"
    if [[ -d "$C/$rel" && ! -L "$C/$rel" ]]; then
        while IFS= read -r -d '' f; do
            f="${f#./}"
            ci_split_is_excluded "$f" || printf '%s\0' "$f"
        done < <(cd "$C" && find "./$rel" -mindepth 1 -print0)
    fi
}

# ci_split_emit_hidden <rootfs> <upper> <merged> <rel>: the children of the directory <rel> that C has, the merged view
# does not show and U does not whiteout: an opaque directory (removed and made again) hides them without a trace.
ci_split_emit_hidden() {
    local C="$1" U="$2" M="$3" rel="$4" f name
    while IFS= read -r -d '' f; do
        name="${f##*/}"
        [[ -e "$M/$rel/$name" || -L "$M/$rel/$name" ]] && continue
        [[ -c "$U/$rel/$name" ]] && continue
        ci_split_emit_subtree "$C" "$rel/$name"
    done < <(find "$C/$rel" -mindepth 1 -maxdepth 1 -print0)
}

# ci_split_plan_live <rootfs> <upper> <merged> <copy-list> <whiteout-list>: what L needs, as two NUL-separated lists of paths
# relative to /. copy-list: paths to take from C (a directory is listed with its whole subtree, or alone when only its mode
# has to be restored). whiteout-list: paths that exist in B but not in C.
ci_split_plan_live() {
    local C="$1" U="$2" M="$3" copy="$4" wh="$5" rel u c skip=""
    : > "$copy"; : > "$wh"
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        if [[ -n "$skip" ]] && { [[ "$rel" == "$skip" ]] || [[ "$rel" == "$skip"/* ]]; }; then continue; fi
        ci_split_is_excluded "$rel" && continue
        u="$U/$rel"; c="$C/$rel"
        if ci_split_is_whiteout "$u"; then
            # U only whites out what a lower layer has.
            if [[ -e "$c" || -L "$c" ]]; then ci_split_emit_subtree "$C" "$rel" >> "$copy"; fi
            continue
        fi
        if [[ -e "$c" || -L "$c" ]]; then
            if [[ -d "$u" && ! -L "$u" && -d "$c" && ! -L "$c" ]]; then
                # a directory on both sides: only its own mode/owner can differ, and the children are in U on their own
                [[ "$(ci_split_attrs "$u")" == "$(ci_split_attrs "$c")" ]] || printf '%s\0' "$rel" >> "$copy"
                ci_split_emit_hidden "$C" "$U" "$M" "$rel" >> "$copy"
            else
                # a file/symlink/node in U shadows C's entry (which may be a directory), or the other way round
                ci_split_emit_subtree "$C" "$rel" >> "$copy"; skip="$rel"
            fi
        else
            printf '%s\0' "$rel" >> "$wh"; skip="$rel"
        fi
    done < <(cd "$U" && find . -mindepth 1 -print0 | tr '/' '\001' | LC_ALL=C sort -z | tr '\001' '/')
}

# ci_split_build_live_tree <rootfs> <upper> <merged> <stage dir> <result dir>: the plain directory L is packed from.
ci_split_build_live_tree() {
    local C="$1" U="$2" M="$3" stage="$4" res="$5" w d
    local copy="$res/live-copy.list" wh="$res/live-whiteout.list" files
    ci_split_plan_live "$C" "$U" "$M" "$copy" "$wh" || return 1
    # a whiteout needs its parent directory in L, with C's mode and owner
    while IFS= read -r -d '' w; do
        d="$(dirname "$w")"; [[ "$d" == . ]] || printf '%s\0' "$d" >> "$copy"
    done < "$wh"
    LC_ALL=C sort -zu "$copy" -o "$copy.sorted" && mv -f "$copy.sorted" "$copy"
    mkdir -p "$stage" || return 1
    # Whiteouts are character devices 0:0, which overlayfs refuses to create: a stage directory on a container's overlay
    # root cannot hold them. Probe, and stage on a tmpfs if that is where the work directory is.
    if ! mknod -m 000 "$stage/.ci-split-probe" c 0 0 2>/dev/null; then
        log_warn "split: $stage cannot hold whiteout device nodes (an overlayfs?); staging L on a tmpfs of ${CI_SPLIT_TMPFS_SIZE:-8g}"
        mount -t tmpfs -o "size=${CI_SPLIT_TMPFS_SIZE:-8g}" tmpfs "$stage" || { log_error "split: cannot mount a tmpfs for L"; return 1; }
        ci_split_track_mount "$stage"
        mknod -m 000 "$stage/.ci-split-probe" c 0 0 || { log_error "split: cannot create a whiteout device node here either (needs CAP_MKNOD)"; return 1; }
    fi
    rm -f "$stage/.ci-split-probe"
    chmod --reference="$C" "$stage" && chown --reference="$C" "$stage" || return 1
    # No -H: a hard link between two names of C (the snap blobs under snaps/ and seed/snaps/) is not kept across
    # layers anyway, and the squashfs deduplicates identical files; two plain files make L's own size a true figure.
    rsync -aAX "--filter=-x trusted.overlay.*" --numeric-ids --from0 --files-from="$copy" "$C/" "$stage/" || { log_error "split: copying C's versions into L failed"; return 1; }
    while IFS= read -r -d '' w; do
        [[ ! -e "$stage/$w" && ! -L "$stage/$w" ]] || { log_error "split: /$w is both a whiteout and a copy in L"; return 1; }
        mknod -m 000 "$stage/$w" c 0 0 || { log_error "split: cannot make the whiteout /$w"; return 1; }
    done < "$wh"
    files="$(tr -cd '\0' < "$copy" | wc -c | tr -d ' ')"
    log_info "split: L staged: $files path(s) taken from C, $(tr -cd '\0' < "$wh" | wc -c | tr -d ' ') whiteout(s)"
}

ci_split_pack() { # <source dir> <output squashfs> <label>
    local src="$1" out="$2" label="$3" e t0="$SECONDS"
    local -a ex=()
    for e in "${CI_SPLIT_PACK_EXCLUDES[@]}"; do ex+=(-e "$e"); done
    rm -f -- "$out"
    # shellcheck disable=SC2086
    mksquashfs "$src" "$out" $CI_SPLIT_MKSQUASHFS_OPTS "${ex[@]}" -noappend -no-recovery -quiet >/dev/null \
        || { log_error "split: mksquashfs of $label failed"; return 1; }
    chmod 644 "$out"
    log_info "split: packed $label: $(stat -c%s "$out") bytes in $((SECONDS - t0)) s"
}

#=============================================================================
# The split
#=============================================================================

# ci_split_live_layer <chroot> <out-base.squashfs> <out-live.squashfs> <result-dir> [<stock-layer-dir>]
# Results in <result-dir>: base.pkgs, live.pkgs (name<TAB>version), base.snaps, live.snaps, installer-snaps.txt, and the
# lists live-copy.list / live-whiteout.list. <stock-layer-dir> holds the base ISO's minimal.squashfs and
# minimal.standard.squashfs (the build keeps them in $WORK_DIR/squashfs); the `restore` and `installer-snaps` rows read them.
ci_split_live_layer() {
    local rc=0
    ci_split_traps_install
    _ci_split_live_layer "$@" || rc=$?
    ci_split_cleanup || true
    ci_split_traps_remove
    return "$rc"
}

_ci_split_live_layer() {
    local C="${1%/}" out_b="$2" out_l="$3" res="$4" stock="${5:-}"
    local T U W M SV STD="" STDL="" lower t0="$SECONDS" expected got row snaps
    CI_SPLIT_RESULT_DIR="$res"
    ci_split_require || return 1
    ci_split_validate_table > "${TMPDIR:-/tmp}/.ci-split-table.$$" || { log_error "split: the table is invalid:"; cat "${TMPDIR:-/tmp}/.ci-split-table.$$" >&2; rm -f "${TMPDIR:-/tmp}/.ci-split-table.$$"; return 1; }
    rm -f "${TMPDIR:-/tmp}/.ci-split-table.$$"
    [[ -d "$C/etc" && -f "$C/var/lib/dpkg/status" ]] || { log_error "split: $C is not a rootfs"; return 1; }
    case "$C$res" in *[,:]*) log_error "split: overlayfs cannot take a comma or colon in a path ($C, $res)"; return 1 ;; esac
    mkdir -p "$res" "$(dirname "$out_b")" "$(dirname "$out_l")" || return 1
    res="$(cd "$res" && pwd)"; CI_SPLIT_RESULT_DIR="$res"

    T="$(mktemp -d "$res/scratch.XXXXXX")" || return 1
    CI_SPLIT_SCRATCH_DIRS+=("$T")
    mkdir -p "$T/up" "$T/wk" "$T/merged" "$T/stock" || return 1
    U="$T/up"; W="$T/wk"; M="$T/merged"; SV="$T/stock"
    chmod --reference="$C" "$U" && chown --reference="$C" "$U" || return 1

    # overlay: C is the read-only lower directory. The upper and work directories must be on a filesystem overlayfs accepts
    # (not itself an overlay: the root of a container without a volume); fall back to a tmpfs.
    if ! ci_split_overlay_mount "$C" "$M" "$U" "$W"; then
        log_warn "split: overlayfs would not take $T as upper directory; using a tmpfs of ${CI_SPLIT_TMPFS_SIZE:-8g}"
        mkdir -p "$T/tmpfs" || return 1
        mount -t tmpfs -o "size=${CI_SPLIT_TMPFS_SIZE:-8g}" tmpfs "$T/tmpfs" || { log_error "split: cannot mount a tmpfs for the upper directory"; return 1; }
        ci_split_track_mount "$T/tmpfs"
        rm -rf "$U" "$W"; U="$T/tmpfs/up"; W="$T/tmpfs/wk"
        mkdir -p "$U" "$W" || return 1
        chmod --reference="$C" "$U" && chown --reference="$C" "$U" || return 1
        ci_split_overlay_mount "$C" "$M" "$U" "$W" || { log_error "split: overlayfs mount of $C failed (kernel without overlay, or a lower directory it refuses)"; return 1; }
    fi

    # the stock standard stack (minimal + minimal.standard), read-only, for the restore rows; and the stock live stack (all three
    # layers) for the guard of the restore rows: where the rootfs still equals it, the build did not customize the path
    if [[ -n "$stock" && -f "$stock/minimal.squashfs" ]]; then
        ci_split_loop_mount "$stock/minimal.squashfs" "$SV/min" || return 1
        if [[ -f "$stock/minimal.standard.squashfs" ]]; then
            ci_split_loop_mount "$stock/minimal.standard.squashfs" "$SV/std" || return 1
            ci_split_overlay_mount "$SV/std:$SV/min" "$SV/view" || { log_error "split: cannot stack the stock layers"; return 1; }
            STD="$SV/view"
        else
            STD="$SV/min"
        fi
        if [[ -f "$stock/minimal.standard.live.squashfs" ]]; then
            ci_split_loop_mount "$stock/minimal.standard.live.squashfs" "$SV/live" || return 1
            # the three squashfs mounts directly, not the standard stack's overlay: overlayfs stacks only two levels deep
            lower="$SV/live:$SV/min"
            if [[ -f "$stock/minimal.standard.squashfs" ]]; then lower="$SV/live:$SV/std:$SV/min"; fi
            ci_split_overlay_mount "$lower" "$SV/liveview" || { log_error "split: cannot stack the stock live layer"; return 1; }
            STDL="$SV/liveview"
        fi
    elif [[ -n "$stock" ]]; then
        log_error "split: no minimal.squashfs in $stock"; return 1
    else
        log_warn "split: no stock layers given: the restore and installer-snap rows cannot run"
    fi
    if [[ -z "$STD" ]]; then
        while IFS= read -r row; do
            case "$row" in restore\|* | installer-snaps\|*) log_error "split: the table needs the stock layers ($row) and none were given"; return 1 ;; esac
        done < <(ci_split_table_rows)
    fi

    # the chroot environment dpkg and the maintainer scripts need; a PRIVATE /run, never the host's (see setup_chroot)
    mount --bind /dev "$M/dev" || { log_error "split: cannot bind /dev"; return 1; }; ci_split_track_mount "$M/dev"
    mount -t proc proc "$M/proc" || return 1;   ci_split_track_mount "$M/proc"
    mount -t sysfs sysfs "$M/sys" || return 1;  ci_split_track_mount "$M/sys"
    mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$M/run" || return 1; ci_split_track_mount "$M/run"
    mkdir -p "$M/run/lock"

    log_info "split: applying the table to a copy-on-write view of the rootfs..."
    ci_split_apply_table "$M" "$STD" "$C" "$STDL" || return 1

    # the removal must leave a consistent dpkg database: no package left with a dependency that is gone
    # (empty cache paths: apt must not write its 50 MB binary caches into the layer)
    local -a aptcheck=(apt-get -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= check)
    ci_split_chroot "$M" "${aptcheck[@]}" >/dev/null 2>&1 || { log_error "split: apt-get check fails after the removal (a kept package depends on a removed one):"; ci_split_chroot "$M" "${aptcheck[@]}" 2>&1 | tail -n 8 >&2; return 1; }
    ci_split_chroot "$M" dpkg --audit >"$T/audit.txt" 2>&1; if [[ -s "$T/audit.txt" ]]; then log_error "split: dpkg --audit reports problems after the removal:"; head -n 8 "$T/audit.txt" >&2; return 1; fi

    # unmount /dev /proc /sys /run again: B must not be packed through them
    local i
    for ((i = ${#CI_SPLIT_MOUNTS[@]} - 1; i >= 0; i--)); do
        case "${CI_SPLIT_MOUNTS[$i]}" in "$M/run" | "$M/sys" | "$M/proc" | "$M/dev") umount "${CI_SPLIT_MOUNTS[$i]}" || { log_error "split: cannot unmount ${CI_SPLIT_MOUNTS[$i]}"; return 1; }; unset 'CI_SPLIT_MOUNTS[i]' ;; esac
    done
    CI_SPLIT_MOUNTS=("${CI_SPLIT_MOUNTS[@]}")

    # B's own invariants, on the merged view (the packed layer is checked again by ci_split_verify_layers)
    snaps="$(cat "$res/installer-snaps.txt" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    if ! got="$(ci_split_assert_base_tree "$M" $snaps)"; then
        log_error "split: the base layer still has live-only content:"; printf '%s\n' "$got" | head -n 20 >&2; return 1
    fi

    # package lists, and the proof that the removal removed exactly what the table says and nothing else
    ci_split_status_pkgs "$M/var/lib/dpkg/status" > "$res/base.pkgs"
    ci_split_status_pkgs "$C/var/lib/dpkg/status" > "$res/live.pkgs"
    ci_split_seed_snaps "$M/var/lib/snapd/seed/seed.yaml" > "$res/base.snaps"
    ci_split_seed_snaps "$C/var/lib/snapd/seed/seed.yaml" > "$res/live.snaps"
    expected="$(ci_split_table_rows | sed -n 's/^purge|//p' | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
    got="$(LC_ALL=C comm -13 "$res/base.pkgs" "$res/live.pkgs" | cut -f1 | LC_ALL=C sort | tr '\n' ' ')"
    if [[ "$got" != "$expected" ]]; then log_error "split: the packages gone from B are [$got] but the table purges [$expected]"; return 1; fi
    if [[ -n "$(LC_ALL=C comm -23 "$res/base.pkgs" "$res/live.pkgs")" ]]; then log_error "split: B has a package (or version) C does not have"; return 1; fi
    log_info "split: base layer B has $(wc -l < "$res/base.pkgs" | tr -d ' ') packages, C has $(wc -l < "$res/live.pkgs" | tr -d ' ')"

    ci_split_build_live_tree "$C" "$U" "$M" "$T/live" "$res" || return 1
    ci_split_pack "$M" "$out_b" "B (base, from the merged view)" || return 1
    ci_split_pack "$T/live" "$out_l" "L (live delta)" || return 1
    log_info "split: B and L written in $((SECONDS - t0)) s"
}

#=============================================================================
# Verifying the real layers
#=============================================================================

# Files the live layer must hold: casper itself, so the layer is not a placeholder and the live session keeps the md5 check, and one
# witness for each group of live-only pieces the base had taken out (finalrd, the initramfs configuration, the installer's user service,
# subiquity's kernel-meta-package file): they are in the live layer and not simply gone. The installer snap's file in the seed
# (name_<revision>.snap) has no fixed name; section 3g of verify-iso.sh checks that one.
CI_SPLIT_LIVE_REQUIRED=(
    etc/casper.conf
    usr/lib/casper/casper-md5check
    usr/lib/systemd/system/casper.service
    usr/lib/systemd/system/casper-md5check.service
    etc/systemd/system/multi-user.target.wants/casper-md5check.service
    usr/share/initramfs-tools/scripts/casper
    usr/share/initramfs-tools/hooks/casper
    var/lib/dpkg/info/casper.list
    usr/lib/systemd/system/finalrd.service
    etc/initramfs-tools/conf.d/casperize.conf
    etc/initramfs-tools/conf.d/default-layer.conf
    usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override
    usr/lib/systemd/user/ubuntu-desktop-installer.service
    etc/subiquity/kernel-meta-package
)

# ci_split_verify_layers <chroot> <base.squashfs> <placeholder.squashfs> <live.squashfs> <result-dir>
# Mounts the three real layers, checks B's invariants on the mounted layer, checks that L carries casper, stacks them
# the way casper does (the topmost layer first) and compares the stack with the chroot. Sets CI_SPLIT_SIZE_BASE,
# CI_SPLIT_SIZE_LIVE and CI_SPLIT_SIZE_TOTAL (bytes, du of the mounted layers and of the stack) and writes them to <result-dir>/sizes.
ci_split_verify_layers() {
    local rc=0
    ci_split_traps_install
    _ci_split_verify_layers "$@" || rc=$?
    ci_split_cleanup || true
    ci_split_traps_remove
    return "$rc"
}

_ci_split_verify_layers() {
    local C="${1%/}" b="$2" ph="$3" l="$4" res="$5" T mode out rc=0 f missing="" t0="$SECONDS" snaps
    local -a ex=() rs=()
    ci_split_require || return 1
    T="$(mktemp -d "$res/verify.XXXXXX")" || return 1
    CI_SPLIT_SCRATCH_DIRS+=("$T")
    ci_split_loop_mount "$b" "$T/b" && ci_split_loop_mount "$ph" "$T/ph" && ci_split_loop_mount "$l" "$T/l" || return 1
    ci_split_overlay_mount "$T/l:$T/ph:$T/b" "$T/stack" || { log_error "split: cannot stack the three layers"; return 1; }

    snaps="$(cat "$res/installer-snaps.txt" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    if ! out="$(ci_split_assert_base_tree "$T/b" $snaps)"; then
        log_error "split: the PACKED base layer has live-only content:"; printf '%s\n' "$out" | head -n 20 >&2; return 1
    fi
    for f in "${CI_SPLIT_LIVE_REQUIRED[@]}"; do [[ -e "$T/l/$f" || -L "$T/l/$f" ]] || missing="$missing /$f"; done
    if [[ -n "$missing" ]]; then log_error "split: the live layer lacks:$missing"; return 1; fi
    if [[ -n "$(find "$T/ph" -mindepth 1 ! -type d -print -quit)" ]]; then log_error "split: the standard placeholder is not empty"; return 1; fi

    # the stack must be C, minus what mksquashfs leaves out: content by checksum, modes, owners, links, devices, xattrs
    for f in "${CI_SPLIT_PACK_EXCLUDES[@]}"; do ex+=("--exclude=/$f"); done
    mode="${CI_SPLIT_VERIFY:-full}"
    if [[ "$mode" == quick ]]; then rs=(--size-only); else rs=(-c); fi
    log_info "split: comparing the stack of the three layers with the rootfs ($mode; this reads both trees)..."
    out="$(rsync -rlpgoDAX "--filter=-x trusted.overlay.*" --numeric-ids -n --delete -i "${rs[@]}" "${ex[@]}" "$C/" "$T/stack/" 2>&1)" || rc=$?
    out="$(printf '%s\n' "$out" | grep -v -E '^(sending incremental file list|$)' || true)"
    if [[ "$rc" -ne 0 || -n "$out" ]]; then
        printf '%s\n' "$out" > "$res/verify-diff.txt"
        log_error "split: overlay(B + placeholder + L) is NOT the rootfs (rsync exit $rc; all $(printf '%s\n' "$out" | wc -l | tr -d ' ') differences in $res/verify-diff.txt), the first ones:"
        printf '%s\n' "$out" | head -n 25 >&2
        return 1
    fi
    log_info "split: overlay(B + placeholder + L) == rootfs (checked in $((SECONDS - t0)) s)"

    CI_SPLIT_SIZE_BASE="$(du -sx --block-size=1 "$T/b" | cut -f1)"
    CI_SPLIT_SIZE_LIVE="$(du -sx --block-size=1 "$T/l" | cut -f1)"
    # no -x on the stack: an overlay over several filesystems reports the lower layers' st_dev, and du -x would stop at the root
    CI_SPLIT_SIZE_TOTAL="$(du -s --block-size=1 "$T/stack" | cut -f1)"
    printf 'base %s\nlive %s\ntotal %s\n' "$CI_SPLIT_SIZE_BASE" "$CI_SPLIT_SIZE_LIVE" "$CI_SPLIT_SIZE_TOTAL" > "$res/sizes"
    log_info "split: sizes (du): B ${CI_SPLIT_SIZE_BASE} bytes, L ${CI_SPLIT_SIZE_LIVE} bytes, whole live stack ${CI_SPLIT_SIZE_TOTAL} bytes"
    if [[ "${CI_SPLIT_SIZE_TOTAL:-0}" -lt "$((CI_SPLIT_SIZE_BASE))" ]]; then log_error "split: the stack is smaller than its base layer (${CI_SPLIT_SIZE_TOTAL} < ${CI_SPLIT_SIZE_BASE} bytes)"; return 1; fi
}

# ci_split_write_metadata <casper dir> <result dir>: the per-layer .size files and the stock-shaped .manifest files, true for
# the layers this image has. Needs the result dir of ci_split_live_layer and ci_split_verify_layers.
ci_split_write_metadata() {
    local casper="$1" res="$2" empty
    [[ -s "$res/sizes" && -s "$res/base.pkgs" && -s "$res/live.pkgs" ]] || { log_error "split: no results in $res to write metadata from"; return 1; }
    printf '%s\n' "$(awk '$1 == "base" {print $2}' "$res/sizes")" > "$casper/minimal.size"
    printf '0\n' > "$casper/minimal.standard.size"
    printf '%s\n' "$(awk '$1 == "live" {print $2}' "$res/sizes")" > "$casper/minimal.standard.live.size"
    printf '%s\n' "$(awk '$1 == "total" {print $2}' "$res/sizes")" > "$casper/filesystem.size"
    empty="$res/empty"; : > "$empty"
    ci_split_manifest_file "" minimal "$res/base.pkgs" "$res/base.snaps" > "$casper/minimal.manifest"
    ci_split_manifest_file minimal minimal.standard "$empty" > "$casper/minimal.standard.manifest"
    {
        ci_split_manifest_file minimal.standard minimal.standard.live "$empty"
        ci_split_diff_lines "$res/base.pkgs" "$res/live.pkgs"
        # snaps the live layer seeds that the base does not
        LC_ALL=C awk -F'\t' 'NR == FNR { have[$1] = 1; next } !($1 in have) { print "+snap:" $1 "\t" $2 "\t" $3 }' "$res/base.snaps" "$res/live.snaps"
    } > "$casper/minimal.standard.live.manifest"
    log_info "split: wrote minimal/minimal.standard/minimal.standard.live .size and .manifest and filesystem.size"
}
