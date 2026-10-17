#!/usr/bin/env bash
#=============================================================================
# Test: the split of the merged rootfs into the installer's base layer and the live-only layer
#
# build-iso.sh merges the three stock casper layers, customizes the result and has to put it back on the ISO. The installer
# installs ONE layer (minimal.squashfs); the live session stacks all three. Before the split the whole rootfs went into
# minimal.squashfs, so the installed system had casper's initramfs hook and every initrd the installer regenerated booted
# into "Unable to find a medium containing a live file system" (QEMU install of the v7 ISO, 2026-10-15), plus the installer's
# snap, the live dconf overrides, a live cloud-init default user ... lib/split-live-layer.sh splits the rootfs C into
#   B  the installed system      -> minimal.squashfs
#   L  what must be stacked on B to give C -> minimal.standard.live.squashfs
# This test proves it in three parts.
#
#   Part A  no container needed.
#     A1-A8   the pure helpers on synthetic trees and files (bash 3.2 is enough, so a stock macOS runs them): the table
#             and its validator, the pack excludes, dpkg status / snap seed / manifest parsing, the invariant checks of B
#             (each planted defect must be reported), and the derivation plan of L (which paths are copied, which whited out,
#             opaque directories). Each of them also runs against a deliberately broken copy of the library and must FAIL there.
#     A6      what the library leaves in the caller's shell: errexit (build-iso.sh runs under `set -e`; ci_split_cleanup used to
#             switch it off for the rest of the build), the caller's EXIT trap, INT/TERM.
#     A7      the guard of the `restore` rows (rsync with -A -X; Linux): a path the build customized is not restored over.
#     A9      (Linux, root, overlayfs, squashfs-tools, rsync) a synthetic rootfs goes through the real derivation, packing and
#             verification: every branch of the plan (deleted, changed, new, replaced, opaque, excluded ...) in one pass, then
#             a sabotaged L must be rejected by the verification. Skipped with a visible message elsewhere.
#   Part B  real data: the saved work tree of a build (a customized merged rootfs and the stock layers of the base ISO). In a
#           privileged Linux container (the Docker Desktop VM will do), with the work volume mounted READ-ONLY:
#     B1      every path the stock live layer holds that belongs to no package is either removed by the table or is the
#             generated state of a package that stays (an audit: a new live-only file in a new base ISO fails here).
#     B2-B3   the whole split on the real rootfs, then the verification: overlay(B + placeholder + L) == rootfs, by checksum.
#     B4      B: no casper (package, files, units, initramfs scripts), no installer snap, snapd state = the stock standard
#             layer's, stock cloud.cfg, schemas recompiled without the live override (also by running gsettings), the kernels,
#             the bootloader and the storage tools still there, dpkg consistent (apt-get check, dpkg --audit).
#     B5      L: casper's files, the live cloud.cfg, whiteouts only for what B alone has.
#     B6      the .size and .manifest files are true, and pass the plausibility formulas verify-iso.sh section 3g applies.
#     B7      the bug itself: an initrd regenerated in a chroot on B has no casper scripts and no "BOOT=casper"; the same on
#             the unsplit rootfs (control) has them, so the probe can see the defect.
#     B8      mutation proof: with the removal table or the derivation of L broken in a scratch copy of the library, the
#             split or its verification must fail; and a rootfs whose cloud.cfg the build customized must be refused by the
#             guard of the `restore` rows.
#     B9      build-iso.sh's own repack_squashfs end to end on the real data (what it writes into casper/, the .size and .manifest
#             files, install-sources.yaml, SHA256SUMS, the log lines, errexit still on, no mount left behind).
#     B10     (SPLIT_TEST_ISO = the v7 ISO, xorriso, python3) the casper directory of B9 in a small ISO, and verify-iso.sh's
#             sections 3e and 3g on it: the library and the verifier agree on what a clean base layer is.
#
# Run (Part A only, anywhere):
#   bash backends/ubuntu/iso/tests/split-live-layer.sh
# Run everything, in a privileged container; /work is a volume (the layers are GBs, and an overlayfs upper directory cannot
# live on a container's own overlay root); the saved build volume is mounted read-only at /v:
#   docker run --rm --privileged --platform linux/amd64 -v "$PWD:/repo:ro" -v ciosv5:/v:ro -v ci-os-split-work:/work \
#       -e SPLIT_TEST_WORK=/work -e SPLIT_TEST_CHROOT=/v/w/chroot -e SPLIT_TEST_STOCK=/v/w/squashfs ubuntu:24.04 \
#       bash -c 'apt-get update -qq && apt-get install -y -qq squashfs-tools rsync xorriso initramfs-tools-core libglib2.0-bin \
#                zstd cpio util-linux >/dev/null && bash /repo/backends/ubuntu/iso/tests/split-live-layer.sh'
#
# Environment:
#   SPLIT_TEST_CHROOT   the merged, customized rootfs of a build (default /v/w/chroot); no such directory: Part B is skipped
#   SPLIT_TEST_STOCK    the directory with the base ISO's minimal.squashfs, minimal.standard.squashfs and
#                       minimal.standard.live.squashfs (default /v/w/squashfs)
#   SPLIT_TEST_WORK     scratch directory for B and L (about 7 GB), on a real filesystem (default: mktemp under /var/tmp)
#   SPLIT_TEST_COMP     mksquashfs options for Part B: "prod" = the build's (-comp xz -b 1M, slow), anything else is passed on
#                       (default "-comp zstd -Xcompression-level 3 -b 256K": same layout, 10 times faster)
#   SPLIT_TEST_VERIFY   full (default; the comparison reads both trees and checksums them) or quick (sizes only)
#   SPLIT_TEST_INITRD   0 skips B7 (about 5 minutes per initrd under emulation)
#   SPLIT_TEST_MUTATIONS 0 skips B8
#   SPLIT_TEST_ISO      an ISO whose boot files and metadata the small B10 image takes (the v7 ISO, /v/out/companion-os-1.0-amd64.iso);
#                       unset: B10 is skipped
#   SPLIT_TEST_KEEP     keep the scratch directory (and its mounts) for a post-mortem
#   SPLIT_TEST_ONLY     a list of groups to run, e.g. "A1 A9 B2" (B2 stands for B2-B6); default all that can run
#
# Exit status is non-zero if any check fails; a group that cannot run here is reported as SKIP (never a pass).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../scripts/lib/split-live-layer.sh"
BUILD="$HERE/../scripts/build-iso.sh"
[[ -f "$LIB" ]] || { echo "run it from the repo checkout (no $LIB)" >&2; exit 2; }

# shellcheck source=../scripts/lib/split-live-layer.sh
source "$LIB"

PASS=0; FAIL=0; SKIP=0; GROUP_FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); GROUP_FAIL=1; printf 'FAIL  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
t_info() { printf 'info  %s\n' "$*"; }
chk() { # chk "<label>" <status of the check: 0 = pass>
    if [[ "$2" -eq 0 ]]; then t_pass "$1"; else t_fail "$1"; fi
}
wanted() { # wanted <group>: is this group selected?
    [[ -z "${SPLIT_TEST_ONLY:-}" ]] && return 0
    case " $SPLIT_TEST_ONLY " in *" $1 "*) return 0 ;; esac
    return 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/split-live-layer.XXXXXX")"
IS_LINUX_ROOT=0
if [[ "$(uname -s)" == Linux && "$(id -u)" -eq 0 ]]; then IS_LINUX_ROOT=1; fi
if [[ "$IS_LINUX_ROOT" -eq 1 ]]; then
    # Part A's scratch space on a tmpfs: a container's own root is an overlayfs, which cannot hold whiteout device nodes or an
    # overlay upper directory. (Part B's big files go to SPLIT_TEST_WORK.)
    mount -t tmpfs -o size=3g tmpfs "$WORK" 2>/dev/null || true
fi
cleanup_test() {
    ci_split_cleanup >/dev/null 2>&1 || true
    if [[ -n "${SPLIT_TEST_KEEP:-}" ]]; then printf 'info  keeping %s (SPLIT_TEST_KEEP)\n' "$WORK" >&2; return 0; fi
    if [[ "$IS_LINUX_ROOT" -eq 1 ]] && grep -q -F -- " $WORK " /proc/self/mountinfo 2>/dev/null; then umount "$WORK" 2>/dev/null || umount -l "$WORK" 2>/dev/null || true; fi
    if grep -q -F -- " $WORK/" /proc/self/mountinfo 2>/dev/null; then
        printf 'info  NOT removing %s: something is still mounted below it\n' "$WORK" >&2
    else
        rm -rf --one-file-system "$WORK" 2>/dev/null || rm -rf "$WORK"
    fi
}
trap cleanup_test EXIT

#=============================================================================
# Part A: the pure helpers
#=============================================================================

# ── A1: the table ───────────────────────────────────────────────────────────────────────────────────────────────────
g_table() {
    local n out bad row p
    n="$(ci_split_table_rows | wc -l | tr -d ' ')"
    if out="$(ci_split_validate_table)"; then t_pass "A1 the table is valid ($n rows)"; else t_fail "A1 the table is invalid: $out"; fi
    # The validator must refuse a row that could delete the wrong thing or that it does not know. (The row goes through a
    # variable named t_row: the library's own functions use plain names such as bad, and bash scoping is dynamic.)
    for t_row in 'rm|/etc/passwd' 'rm|etc' 'rm|etc/../usr/bin' 'frobnicate|usr/share/x' 'purge|' 'purge|Casper' 'purge|casper;halt' \
                 'restore|' 'schemas|x' 'rmgrep|etc/x*' 'rmgrep|etc/x*|' 'rm|usr/share/a b' 'rm|usr/share/a|b' 'installer-snaps|x' 'rmdir|usr'; do
        out="$(ci_split_table_rows() { printf '%s\n' "$t_row"; }; ci_split_validate_table)"
        if [[ -n "$out" && "$out" != *"unknown kind '0'"* ]]; then t_pass "A1 the validator refuses the row '$t_row'"; else t_fail "A1 the validator accepts the row '$t_row' ($out)"; fi
    done
    out="$(ci_split_table_rows() { :; }; ci_split_validate_table)"
    if [[ -n "$out" ]]; then t_pass "A1 an empty table is refused"; else t_fail "A1 an empty table is accepted"; fi
    # What the design says must be in it, and must not be.
    if ci_split_table_rows | grep -q -x 'purge|casper finalrd'; then t_pass "A1 the table purges casper and finalrd"; else t_fail "A1 the table does not purge casper and finalrd"; fi
    for p in etc/initramfs-tools/conf.d/casperize.conf etc/initramfs-tools/conf.d/default-layer.conf \
             usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override etc/subiquity etc/cloud/cloud.cfg.d/06_quiet.cfg; do
        if ci_split_table_rows | grep -q -x "rm|$p"; then t_pass "A1 the table removes /$p"; else t_fail "A1 the table does not remove /$p"; fi
    done
    for row in schemas\| installer-snaps\| restore\|var/lib/snapd/state.json restore\|var/lib/snapd/seed/seed.yaml restore\|etc/cloud/cloud.cfg; do
        if ci_split_table_rows | grep -q -x -F "$row"; then t_pass "A1 the table has the row '$row'"; else t_fail "A1 the table lacks the row '$row'"; fi
    done
    # kernels, firmware, bootloader and storage tools stay in B (the design rule): no purge row may name one
    bad="$(ci_split_table_rows | sed -n 's/^purge|//p' | tr ' ' '\n' | grep -E '^(linux|grub|shim|zfs|lvm|mdadm|cryptsetup|gparted|btrfs|xfs|efibootmgr|mokutil|intel-microcode|amd64-microcode|firmware|thermald)' || true)"
    if [[ -z "$bad" ]]; then t_pass "A1 no purge row names a kernel, firmware, bootloader or storage package"; else t_fail "A1 purge rows name packages that must stay: $bad"; fi
    return "$GROUP_FAIL"
}

# ── A2: the pack excludes ───────────────────────────────────────────────────────────────────────────────────────────
g_excludes() {
    local p
    for p in var/cache/apt/archives/x var/cache/apt/archives/partial/y var/lib/apt/lists/foo tmp/a tmp/a/b root/.bash_history; do
        if ci_split_is_excluded "$p"; then t_pass "A2 left out of a layer: $p"; else t_fail "A2 not excluded: $p"; fi
    done
    for p in var/cache/apt/archives var/lib/apt/lists tmp root/.bashrc usr/tmp/x var/tmp/x etc/tmp var/cache/apt/pkgcache.bin; do
        if ci_split_is_excluded "$p"; then t_fail "A2 wrongly excluded: $p"; else t_pass "A2 kept in a layer: $p"; fi
    done
    return "$GROUP_FAIL"
}

# ── A3: dpkg status, snap seed, manifests ───────────────────────────────────────────────────────────────────────────
mk_status() { # mk_status <file>
    cat > "$1" <<'EOF'
Package: alpha
Status: install ok installed
Architecture: amd64
Version: 1.0-1

Package: beta
Status: deinstall ok config-files
Architecture: amd64
Version: 2.0-1

Package: libgamma1
Status: install ok installed
Architecture: amd64
Multi-Arch: same
Version: 3.1-2ubuntu1

Package: casper
Status: install ok installed
Architecture: amd64
Version: 1.498

Package: delta
Status: purge ok not-installed
Architecture: all
Version: 9
EOF
}
mk_seed() { # mk_seed <file> <name[:channel[:file]]>...
    local f="$1" s name rest ch file; shift
    printf 'snaps:\n' > "$f"
    for s in "$@"; do
        name="${s%%:*}"; rest=""; [[ "$s" == *:* ]] && rest="${s#*:}"
        ch="${rest%%:*}"; [[ -n "$ch" ]] || ch=stable
        file=""; [[ "$rest" == *:* ]] && file="${rest#*:}"; [[ -n "$file" ]] || file="${name}_100.snap"
        printf '  -\n    name: %s\n    channel: %s\n    file: %s\n' "$name" "$ch" "$file" >> "$f"
    done
}
g_parse() {
    local d="$WORK/parse" got want
    mkdir -p "$d"
    mk_status "$d/status"
    got="$(ci_split_status_pkgs "$d/status" | tr '\t\n' ' |')"
    want="alpha 1.0-1|casper 1.498|libgamma1:amd64 3.1-2ubuntu1|"
    if [[ "$got" == "$want" ]]; then t_pass "A3 status: installed packages only, Multi-Arch same as name:arch"; else t_fail "A3 status parsing: got '$got'"; fi

    mk_seed "$d/live.yaml" core24:stable:core24_2124.snap firefox:stable/ubuntu-24.04:firefox_8863.snap core22:stable:core22_2955.snap ubuntu-desktop-bootstrap:24.04/stable/ubuntu-24.04.5:ubuntu-desktop-bootstrap_680.snap
    mk_seed "$d/std.yaml" core24:stable:core24_2124.snap firefox:stable/ubuntu-24.04:firefox_8863.snap
    got="$(ci_split_seed_snaps "$d/live.yaml" | tr '\t\n' ' |')"
    want="core24 stable 2124|firefox stable/ubuntu-24.04 8863|core22 stable 2955|ubuntu-desktop-bootstrap 24.04/stable/ubuntu-24.04.5 680|"
    if [[ "$got" == "$want" ]]; then t_pass "A3 seed: name, channel and revision per snap"; else t_fail "A3 seed parsing: got '$got'"; fi
    got="$(ci_split_installer_snap_names "$d/live.yaml" "$d/std.yaml" | tr '\n' ' ')"
    if [[ "$got" == "core22 ubuntu-desktop-bootstrap " ]]; then t_pass "A3 installer snaps = the live seed minus the standard seed"; else t_fail "A3 installer snap names: got '$got'"; fi
    got="$(ci_split_installer_snap_names /nonexistent /nonexistent | tr '\n' ' ')"
    if [[ "$got" == "ubuntu-desktop-bootstrap " ]]; then t_pass "A3 without seeds the fixed installer snap is still named"; else t_fail "A3 fixed installer snap: got '$got'"; fi

    # the manifest shape the stock layers have, and the parsing verify-iso.sh section 3g applies to it
    printf 'alpha\t1.0-1\nlibgamma1:amd64\t3.1-2ubuntu1\n' > "$d/base.pkgs"
    printf 'core24\tstable\t2124\n' > "$d/base.snaps"
    ci_split_manifest_file "" minimal "$d/base.pkgs" "$d/base.snaps" > "$d/minimal.manifest"
    if [[ "$(sed -n 1p "$d/minimal.manifest")" == "--- /build/livecd.ubuntu..manifest.full"* && "$(sed -n 2p "$d/minimal.manifest")" == "+++ /build/livecd.ubuntu.minimal.manifest.full"* ]]; then
        t_pass "A3 manifest: the stock diff header"; else t_fail "A3 manifest header: $(head -n 2 "$d/minimal.manifest" | tr '\n' '|')"; fi
    # the same sed/awk as verify-iso.sh manifest_pkgs: name without :arch, version
    got="$(sed -n 's/^+\([^+].*\)$/\1/p' "$d/minimal.manifest" | grep -v '^snap:' | awk -F'\t' '{ n = $1; sub(/:[^:]*$/, "", n); print n "\t" $2 }' | LC_ALL=C sort -u | tr '\t\n' ' |')"
    if [[ "$got" == "alpha 1.0-1|libgamma1 3.1-2ubuntu1|" ]]; then t_pass "A3 manifest: verify-iso.sh's reading of it gives the packages back"; else t_fail "A3 manifest packages read back as '$got'"; fi
    if grep -q -P '^\+snap:core24\tstable\t2124$' "$d/minimal.manifest" 2>/dev/null || grep -q "$(printf '^+snap:core24\tstable\t2124$')" "$d/minimal.manifest"; then
        t_pass "A3 manifest: snaps as +snap:name<TAB>channel<TAB>revision"; else t_fail "A3 manifest has no +snap line"; fi
    # the live delta
    printf 'alpha\t1.0-1\ncasper\t1.498\nlibgamma1:amd64\t3.1-2ubuntu1\n' > "$d/live.pkgs"
    got="$(ci_split_diff_lines "$d/base.pkgs" "$d/live.pkgs" | tr '\t\n' ' |')"
    if [[ "$got" == "+casper 1.498|" ]]; then t_pass "A3 live delta: only what C adds, with a +"; else t_fail "A3 live delta: '$got'"; fi
    got="$(ci_split_diff_lines "$d/live.pkgs" "$d/base.pkgs" | tr '\t\n' ' |')"
    if [[ "$got" == "-casper 1.498|" ]]; then t_pass "A3 live delta: what C lacks, with a -"; else t_fail "A3 live delta (reversed): '$got'"; fi
    return "$GROUP_FAIL"
}

# ── A4: B's invariants ──────────────────────────────────────────────────────────────────────────────────────────────
mk_good_base() { # mk_good_base <dir>: a base tree with none of the live-only content
    local d="$1"
    rm -rf "$d"
    mkdir -p "$d/var/lib/dpkg" "$d/etc/cloud" "$d/var/lib/snapd/seed" "$d/usr/lib/systemd/system" "$d/etc/systemd/system" \
             "$d/usr/share/glib-2.0/schemas" "$d/etc/initramfs-tools/conf.d" "$d/usr/share/initramfs-tools/scripts" "$d/snap/bin" \
             "$d/var/snap" "$d/usr/lib/systemd/system/getty.target.wants"
    mk_status "$d/var/lib/dpkg/status"
    # drop the casper stanza from the good tree's status
    awk 'BEGIN { RS = ""; ORS = "\n\n" } $0 !~ /Package: casper/' "$d/var/lib/dpkg/status" > "$d/var/lib/dpkg/status.new" && mv "$d/var/lib/dpkg/status.new" "$d/var/lib/dpkg/status"
    mk_seed "$d/var/lib/snapd/seed/seed.yaml" core24:stable:core24_2124.snap firefox:stable:firefox_8863.snap
    mkdir -p "$d/var/lib/snapd/seed/snaps"; : > "$d/var/lib/snapd/seed/snaps/core24_2124.snap"; : > "$d/var/lib/snapd/seed/snaps/firefox_8863.snap"
    printf '{"data":{"snaps":{"firefox":{},"core24":{}}}}\n' > "$d/var/lib/snapd/state.json"
    printf 'users:\n- default\n' > "$d/etc/cloud/cloud.cfg"
    printf 'ELF\n' > "$d/usr/lib/systemd/systemd-networkd-wait-online"
    # what the stock STANDARD layer has, so a stock install has it too: not a defect
    mkdir -p "$d/etc/apt/preferences.d.save"; printf 'Package: *\n' > "$d/etc/apt/preferences.d.save/ubuntu-pro-esm-apps"
}
plant() { # plant <dir> <kind> : add one live-only defect to a good base tree
    local d="$1"
    case "$2" in
        casper.conf)        printf 'x\n' > "$d/etc/casper.conf" ;;
        casperize)          printf 'x\n' > "$d/etc/initramfs-tools/conf.d/casperize.conf" ;;
        default-layer)      printf 'x\n' > "$d/etc/initramfs-tools/conf.d/default-layer.conf" ;;
        casper-hook)        mkdir -p "$d/usr/share/initramfs-tools/hooks"; printf 'x\n' > "$d/usr/share/initramfs-tools/hooks/casper" ;;
        casper-scripts)     mkdir -p "$d/usr/share/initramfs-tools/scripts/casper-bottom"; printf 'x\n' > "$d/usr/share/initramfs-tools/scripts/casper-bottom/25adduser" ;;
        casper-lib)         mkdir -p "$d/usr/lib/casper"; printf 'x\n' > "$d/usr/lib/casper/casper-md5check" ;;
        casper-unit)        printf 'x\n' > "$d/usr/lib/systemd/system/casper-md5check.service" ;;
        casper-link)        mkdir -p "$d/etc/systemd/system/multi-user.target.wants"; ln -s /usr/lib/systemd/system/casper-md5check.service "$d/etc/systemd/system/multi-user.target.wants/casper-md5check.service" ;;
        casper-dpkg)        mkdir -p "$d/var/lib/dpkg/info"; printf 'x\n' > "$d/var/lib/dpkg/info/casper.list" ;;
        casper-status)      printf 'Package: casper\nStatus: install ok installed\nVersion: 1.498\n\n' >> "$d/var/lib/dpkg/status" ;;
        casper-status-cfg)  printf 'Package: casper\nStatus: deinstall ok config-files\nVersion: 1.498\n\n' >> "$d/var/lib/dpkg/status" ;;
        finalrd-status)     printf 'Package: finalrd\nStatus: install ok installed\nVersion: 9\n\n' >> "$d/var/lib/dpkg/status" ;;
        finalrd-link)       mkdir -p "$d/etc/systemd/system/sysinit.target.wants"; ln -s /lib/systemd/system/finalrd.service "$d/etc/systemd/system/sysinit.target.wants/finalrd.service" ;;
        gschema)            printf 'x\n' > "$d/usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override" ;;
        subiquity)          mkdir -p "$d/etc/subiquity"; printf 'linux-generic-hwe-24.04\n' > "$d/etc/subiquity/kernel-meta-package" ;;
        quiet)              mkdir -p "$d/etc/cloud/cloud.cfg.d"; printf 'x\n' > "$d/etc/cloud/cloud.cfg.d/06_quiet.cfg" ;;
        prefs-save)         mkdir -p "$d/etc/apt/preferences.d.save/preferences.d"; printf 'x\n' > "$d/etc/apt/preferences.d.save/preferences.d/ubuntu-pro-esm-apps" ;;
        nocloud)            mkdir -p "$d/var/lib/cloud/seed/nocloud"; : > "$d/var/lib/cloud/seed/nocloud/user-data" ;;
        packages-chroot)    mkdir -p "$d/root"; printf 'x\n' > "$d/root/packages.chroot" ;;
        installer-unit)     mkdir -p "$d/usr/lib/systemd/user"; printf 'x\n' > "$d/usr/lib/systemd/user/ubuntu-desktop-installer.service" ;;
        installer-link)     mkdir -p "$d/etc/systemd/user/graphical-session.target.wants"; ln -s /usr/lib/systemd/user/ubuntu-desktop-installer.service "$d/etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service" ;;
        subiquity-mount)    printf 'x\n' > "$d/usr/lib/systemd/system/subiquity_config.mount" ;;
        udisks-inhibit)     printf 'x\n' > "$d/usr/lib/systemd/system/udisks2-inhibit.service" ;;
        getty-mask)         ln -s /dev/null "$d/usr/lib/systemd/system/getty@tty1.service" ;;
        no-reexec)          mkdir -p "$d/usr/lib/systemd/system/snapd.service.d"; printf '[Service]\n' > "$d/usr/lib/systemd/system/snapd.service.d/no-reexec.conf" ;;
        journald)           mkdir -p "$d/etc/systemd/journald.conf.d"; printf '[Journal]\n' > "$d/etc/systemd/journald.conf.d/no-rate-limit.conf" ;;
        snap-dir)           mkdir -p "$d/snap/ubuntu-desktop-bootstrap/680" ;;
        snap-bin)           ln -s /usr/bin/snap "$d/snap/bin/ubuntu-desktop-bootstrap.probert" ;;
        snap-blob)          mkdir -p "$d/var/lib/snapd/snaps"; : > "$d/var/lib/snapd/snaps/ubuntu-desktop-bootstrap_680.snap" ;;
        snap-profile)       mkdir -p "$d/var/lib/snapd/apparmor/profiles"; : > "$d/var/lib/snapd/apparmor/profiles/snap.ubuntu-desktop-bootstrap.probert" ;;
        snap-mount-unit)    : > "$d/etc/systemd/system/$(printf 'snap-ubuntu\\x2ddesktop\\x2dbootstrap-680.mount')" ;;
        snap-seed)          mk_seed "$d/var/lib/snapd/seed/seed.yaml" core24 ubuntu-desktop-bootstrap ;;
        seed-missing-file)  rm -f "$d/var/lib/snapd/seed/snaps/firefox_8863.snap" ;;
        snap-state)         printf '{"data":{"snaps":{"ubuntu-desktop-bootstrap":{}}}}\n' > "$d/var/lib/snapd/state.json" ;;
        core22-dir)         mkdir -p "$d/snap/core22/2955" ;;
        core22-mount-unit)  : > "$d/etc/systemd/system/snap-core22-2955.mount" ;;
        cloud-cfg)          printf 'default_user:\n  shell: /usr/bin/subiquity-shell\n' > "$d/etc/cloud/cloud.cfg" ;;
        wait-online)        rm -f "$d/usr/lib/systemd/systemd-networkd-wait-online"; ln -s /bin/true "$d/usr/lib/systemd/systemd-networkd-wait-online" ;;
        *)                  echo "plant: unknown defect $2" >&2; return 1 ;;
    esac
}
PLANTS="casper.conf casperize default-layer casper-hook casper-scripts casper-lib casper-unit casper-link casper-dpkg casper-status casper-status-cfg
finalrd-status finalrd-link gschema subiquity quiet prefs-save nocloud packages-chroot installer-unit installer-link subiquity-mount udisks-inhibit
getty-mask no-reexec journald snap-dir snap-bin snap-blob snap-profile snap-mount-unit snap-seed seed-missing-file snap-state core22-dir core22-mount-unit cloud-cfg wait-online"
g_assert_tree() {
    local d="$WORK/base" out p
    mk_good_base "$d"
    if out="$(ci_split_assert_base_tree "$d")"; then t_pass "A4 a base tree without live-only content passes"; else t_fail "A4 a clean base tree is rejected: $out"; fi
    for p in $PLANTS; do
        mk_good_base "$d"; plant "$d" "$p" || { t_fail "A4 cannot plant $p"; continue; }
        # core22-* defects are the installer snap the CALLER derives: pass the name like the build does
        if out="$(ci_split_assert_base_tree "$d" core22)"; then t_fail "A4 not reported: $p"; else t_pass "A4 reported: $p"; fi
    done
    # tests/verify-installer-base.sh cuts the library's two invariant lists out by their opening and closing lines: they must
    # stay findable (one opening line each, entries between them)
    local n_gone n_live
    n_gone="$(sed -n '/local -a gone=(/,/^    )$/p' "$LIB" | sed '1d;$d' | tr -s ' \t' '\n' | grep -c -v '^$' || true)"
    n_live="$(sed -n '/^CI_SPLIT_LIVE_REQUIRED=(/,/^)$/p' "$LIB" | sed '1d;$d' | grep -c . || true)"
    if [[ "$(grep -c 'local -a gone=(' "$LIB")" == 1 && "$(grep -c '^CI_SPLIT_LIVE_REQUIRED=(' "$LIB")" == 1 && "$n_gone" -ge 30 && "$n_live" -ge 8 ]]; then
        t_pass "A4 the invariant lists are still cut out by tests/verify-installer-base.sh's markers ($n_gone paths, $n_live live-layer paths)"
    else t_fail "A4 the layout of the library's invariant lists changed ($n_gone, $n_live): tests/verify-installer-base.sh would not find them"; fi
    # a derived snap name the fixed list does not know
    mk_good_base "$d"; mkdir -p "$d/snap/core22/2955"
    if out="$(ci_split_assert_base_tree "$d")"; then t_pass "A4 an installer snap the caller did not name is not a defect (it is the caller's list)"; else t_fail "A4 core22 reported without being named: $out"; fi
    return "$GROUP_FAIL"
}

# ── A5: the plan that derives L from the upper directory ────────────────────────────────────────────────────────────
# C, U and M are built by hand: M is what the merged view would show, U what the overlay's upper directory holds.
mk_plan_trees() { # mk_plan_trees <dir>: <dir>/{c,u,m}
    local d="$1" c="$1/c" u="$1/u" m="$1/m"
    rm -rf "$d"; mkdir -p "$c" "$u" "$m"
    # C
    mkdir -p "$c/keep/sub" "$c/mod" "$c/dirattr" "$c/rdbf/inner" "$c/op" "$c/tmp" "$c/var/lib/apt/lists" "$c/sw"
    printf 'a\n' > "$c/keep/a"; printf 'b\n' > "$c/keep/sub/b"; printf 'm\n' > "$c/mod/file"; printf 'd\n' > "$c/dirattr/f"
    printf 'x\n' > "$c/rdbf/inner/y"; printf 'k1\n' > "$c/op/k1"; printf 'k2\n' > "$c/op/k2"; printf 'old\n' > "$c/tmp/old"
    printf 'l\n' > "$c/var/lib/apt/lists/foo"; printf 'file-in-c\n' > "$c/rfbd"; ln -s target-a "$c/sw/link"
    chmod 755 "$c/dirattr" "$c/mod" "$c/keep"
    # U: the changes (no whiteouts: those need root, see g_plan_whiteouts)
    mkdir -p "$u/mod" "$u/keep" "$u/newdir/sub" "$u/dirattr" "$u/op" "$u/rfbd" "$u/tmp" "$u/var/lib/apt/lists" "$u/sw"
    printf 'changed\n' > "$u/mod/file"                       # modified file in a copied-up directory
    printf 'new\n' > "$u/keep/newfile"                       # a file only B has, in a directory C has
    printf 'f\n' > "$u/newdir/sub/f"                          # a directory only B has
    chmod 700 "$u/dirattr"                                    # a directory whose mode changed
    chmod 755 "$u/mod" "$u/keep"
    printf 'not a dir any more\n' > "$u/rdbf"                 # C has a directory, B a file
    printf 'c\n' > "$u/rfbd/c"                                # C has a file, B a directory
    printf 'n1\n' > "$u/op/n1"                                # an opaque directory: replaced, only n1 in it
    ln -s target-b "$u/sw/link"                               # a symlink with another target
    printf 'junk\n' > "$u/tmp/junk"; printf 'n\n' > "$u/var/lib/apt/lists/n"   # left out of a layer anyway
    # M: the merged view as it would look
    cp -R "$c/." "$m/"
    rm -rf "$m/op" "$m/rdbf" "$m/rfbd" "$m/sw/link"; mkdir -p "$m/op" "$m/rfbd"
    printf 'n1\n' > "$m/op/n1"; printf 'c\n' > "$m/rfbd/c"; printf 'not a dir any more\n' > "$m/rdbf"; ln -s target-b "$m/sw/link"
}
plan_lists() { # plan_lists <copy list> : the NUL lists as sorted lines
    tr '\0' '\n' < "$1" | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' '
}
g_plan() {
    local d="$WORK/plan" got want
    mk_plan_trees "$d"
    if ! ci_split_plan_live "$d/c" "$d/u" "$d/m" "$d/copy" "$d/wh"; then t_fail "A5 the plan could not be made"; return 1; fi
    got="$(plan_lists "$d/copy")"
    want="dirattr mod/file op/k1 op/k2 rdbf rdbf/inner rdbf/inner/y rfbd sw/link "
    if [[ "$got" == "$want" ]]; then t_pass "A5 copy list: changed file, mode-changed directory, replaced directory with its subtree, replaced file, opaque directory's hidden children, symlink"; else t_fail "A5 copy list is [$got], expected [$want]"; fi
    got="$(plan_lists "$d/wh")"
    want="keep/newfile newdir op/n1 "
    if [[ "$got" == "$want" ]]; then t_pass "A5 whiteout list: what only B has (the new directory once, not its children)"; else t_fail "A5 whiteout list is [$got], expected [$want]"; fi
    if cat "$d/copy" "$d/wh" | tr '\0' '\n' | grep -q -E '^(tmp|var/lib/apt/lists)/'; then t_fail "A5 the plan lists a path that is left out of a layer"; else t_pass "A5 paths left out of a layer (tmp/*, var/lib/apt/lists/*) are not in the plan"; fi
    if tr '\0' '\n' < "$d/copy" | grep -q -x -e 'mod' -e 'keep'; then t_fail "A5 a directory with unchanged mode is listed"; else t_pass "A5 copied-up directories with C's mode are not listed"; fi
    return "$GROUP_FAIL"
}
# deleted paths need character-device whiteouts in U: root on Linux only
g_plan_whiteouts() {
    local d="$WORK/planw" got want
    rm -rf "$d"; mkdir -p "$d/c/del/dir" "$d/u" "$d/m"
    printf 'x\n' > "$d/c/del/file"; printf 'y\n' > "$d/c/del/dir/g"; mkdir -p "$d/c/del/emptydir"
    mkdir -p "$d/u/del"
    if ! mknod -m 000 "$d/u/del/file" c 0 0 2>/dev/null; then t_skip "A5 whiteouts: cannot mknod a character device here (needs root on Linux)"; return 0; fi
    mknod -m 000 "$d/u/del/dir" c 0 0; mknod -m 000 "$d/u/del/stale" c 0 0     # stale: C does not have it
    chmod 755 "$d/c/del" "$d/u/del"; mkdir -p "$d/m/del/emptydir"
    ci_split_plan_live "$d/c" "$d/u" "$d/m" "$d/copy" "$d/wh" || { t_fail "A5 whiteouts: the plan failed"; return 1; }
    got="$(plan_lists "$d/copy")"; want="del/dir del/dir/g del/file "
    if [[ "$got" == "$want" ]]; then t_pass "A5 whiteouts: a deleted file and a deleted directory come back from C (a stale whiteout is ignored)"; else t_fail "A5 whiteouts: copy list [$got], expected [$want]"; fi
    # del/emptydir is hidden by nothing: M shows it; it must not appear
    if [[ -z "$(plan_lists "$d/wh")" ]]; then t_pass "A5 whiteouts: nothing is whited out"; else t_fail "A5 whiteouts: unexpected whiteout list [$(plan_lists "$d/wh")]"; fi
    return "$GROUP_FAIL"
}

# ── A6: what the library leaves in the caller's shell ───────────────────────────────────────────────────────────────
# build-iso.sh runs under `set -e` and the split runs inside it. ci_split_cleanup has to go on after a failed umount, so it turns errexit
# off; `set` is global, not per function, so unless it puts the caller's setting back every step after the split (brand_boot_media,
# generate_iso) silently stops aborting the build. Each probe is a fresh `bash -c`; LIB_UNDER_TEST is the library (a mutant, in A8).
LIB_UNDER_TEST=""
g_shell_state() {
    local lib="${LIB_UNDER_TEST:-$LIB}" out rc
    out="$(bash -c 'set -e; source "$1"; ci_split_cleanup >/dev/null 2>&1 || true; case "$-" in *e*) echo errexit-on ;; *) echo errexit-off ;; esac' _ "$lib" 2>&1)"
    if [[ "$out" == errexit-on ]]; then t_pass "A6 ci_split_cleanup leaves the caller's errexit on (build-iso.sh runs under set -e)"; else t_fail "A6 ci_split_cleanup changed the caller's errexit: $out"; fi
    out="$(bash -c 'source "$1"; ci_split_cleanup >/dev/null 2>&1 || true; case "$-" in *e*) echo errexit-on ;; *) echo errexit-off ;; esac' _ "$lib" 2>&1)"
    if [[ "$out" == errexit-off ]]; then t_pass "A6 ci_split_cleanup does not switch errexit on for a caller that has it off"; else t_fail "A6 ci_split_cleanup switched errexit on: $out"; fi
    # the whole cycle under errexit, as build-iso.sh uses it: a failing step after the traps are installed ends the shell, the library's
    # cleanup runs first and the caller's own EXIT trap after it, with the exit status of the failure
    out="$(bash -c 'set -e; trap "echo caller-exit" EXIT; source "$1"; ci_split_cleanup() { echo cleaned; }; ci_split_traps_install; false; echo not-reached' _ "$lib" 2>&1)"; rc=$?
    if [[ "$rc" -eq 1 && "$out" == "cleaned
caller-exit" ]]; then t_pass "A6 a failure while the traps are installed runs the cleanup, then the caller's EXIT trap, and keeps the exit status"; else t_fail "A6 EXIT chain (rc=$rc): $(printf '%s' "$out" | tr '\n' '|')"; fi
    out="$(bash -c 'trap "echo caller-exit" EXIT; source "$1"; ci_split_traps_install; ci_split_traps_remove; trap -p EXIT; trap -p INT TERM; trap - EXIT' _ "$lib" 2>&1)"
    if [[ "$out" == *caller-exit* && "$out" != *ci_split* && "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ]]; then t_pass "A6 after the split the caller's EXIT trap is back and INT/TERM have none of ours"; else t_fail "A6 traps after traps_remove: $(printf '%s' "$out" | tr '\n' '|')"; fi
    out="$(bash -c 'trap "echo caller-exit" EXIT; source "$1"; ci_split_cleanup() { echo cleaned; }; ci_split_traps_install; kill -TERM $$; echo not-reached' _ "$lib" 2>&1)"; rc=$?
    if [[ "$rc" -eq 143 && "$out" == *cleaned* && "$out" == *caller-exit* && "$out" != *not-reached* ]]; then t_pass "A6 SIGTERM runs the cleanup and the caller's EXIT trap, exit status 143"; else t_fail "A6 SIGTERM (rc=$rc): $(printf '%s' "$out" | tr '\n' '|')"; fi
    return "$GROUP_FAIL"
}

# ── A7: the guard of the restore rows ───────────────────────────────────────────────────────────────────────────────
# A restore row undoes what the stock LIVE layer did to a file the installed system shares. If the build changed the file too, the rootfs
# no longer equals the stock live layer's copy and the restore would silently drop that change from the installed system: the split must stop.
rsync_has_ax() { # rsync >= 3 with -A and -X (a stock macOS has neither)
    local d="$WORK/rsync-probe"; mkdir -p "$d/a" "$d/b"; : > "$d/a/f"
    rsync -rlpgoDAXc --numeric-ids -n -i "$d/a/" "$d/b/" >/dev/null 2>&1
}
mk_guard_trees() { # mk_guard_trees <dir>: <dir>/{c,lv,s,m}: rootfs, the stock live stack, the stock standard stack, the merged view
    local d="$1"
    rm -rf "$d"; mkdir -p "$d"/{c,lv,s,m}/etc/cloud "$d"/{c,lv,s,m}/var/lib/snapd/cookie
    printf 'default_user: installer\n' > "$d/lv/etc/cloud/cloud.cfg"; printf 'default_user: ubuntu123\n' > "$d/s/etc/cloud/cloud.cfg"
    printf 'k1\n' > "$d/lv/var/lib/snapd/cookie/snap.a"; printf 'k2\n' > "$d/s/var/lib/snapd/cookie/snap.a"
    ln -s target "$d/lv/etc/link"
    cp -R "$d/lv/." "$d/c/"; cp -R "$d/lv/." "$d/m/"
    # same mtimes everywhere, so only the checksum can tell a changed file of the same size
    find "$d" -exec touch -h -t 202601010000 {} + 2>/dev/null
}
g_restore_guard() {
    local lib="${LIB_UNDER_TEST:-$LIB}" d="$WORK/guard" out rc=0 probe kind
    if ! rsync_has_ax; then t_skip "A7 restore guard: needs rsync >= 3 with -A -X (a Linux host or container)"; return 0; fi
    # shellcheck disable=SC1090
    ( source "$lib"; mk_guard_trees "$d"
      # the same everywhere: ok
      ci_split_same_path "$d/c" "$d/lv" etc/cloud/cloud.cfg >/dev/null || exit 1
      ci_split_same_path "$d/c" "$d/lv" var/lib/snapd/cookie >/dev/null || exit 2
      ci_split_same_path "$d/c" "$d/lv" etc/link >/dev/null || exit 3
      ci_split_same_path "$d/c" "$d/lv" etc/absent-in-both >/dev/null || exit 4
      exit 0 ) || rc=$?
    case "${rc:-0}" in
        0) t_pass "A7 same_path: identical files, directories, symlinks and absent paths are the same" ;;
        *) t_fail "A7 same_path rejects an identical path (probe $rc)" ;;
    esac
    # every kind of difference must be reported
    for kind in content-same-size dir-content-same-size content-longer mode owner extra-file missing-file link-target absent-in-c absent-in-lv file-vs-dir; do
        mk_guard_trees "$d"
        case "$kind" in
            content-same-size) printf 'default_user: Xnstaller\n' > "$d/c/etc/cloud/cloud.cfg"; touch -t 202601010000 "$d/c/etc/cloud/cloud.cfg"; probe=etc/cloud/cloud.cfg ;;
            dir-content-same-size) printf 'kX\n' > "$d/c/var/lib/snapd/cookie/snap.a"; touch -t 202601010000 "$d/c/var/lib/snapd/cookie/snap.a"; probe=var/lib/snapd/cookie ;;
            content-longer)    printf 'default_user: installer\nssh_pwauth: true\n' > "$d/c/etc/cloud/cloud.cfg"; probe=etc/cloud/cloud.cfg ;;
            mode)              chmod 600 "$d/c/etc/cloud/cloud.cfg"; probe=etc/cloud/cloud.cfg ;;
            owner)             if [[ "$(id -u)" -eq 0 ]]; then chown 1234:1234 "$d/c/etc/cloud/cloud.cfg"; else t_skip "A7 same_path: an owner difference needs root"; continue; fi; probe=etc/cloud/cloud.cfg ;;
            extra-file)        printf 'x\n' > "$d/c/var/lib/snapd/cookie/snap.extra"; probe=var/lib/snapd/cookie ;;
            missing-file)      rm -f "$d/c/var/lib/snapd/cookie/snap.a"; probe=var/lib/snapd/cookie ;;
            link-target)       rm -f "$d/c/etc/link"; ln -s other "$d/c/etc/link"; probe=etc/link ;;
            absent-in-c)       rm -f "$d/c/etc/cloud/cloud.cfg"; probe=etc/cloud/cloud.cfg ;;
            absent-in-lv)      rm -f "$d/lv/etc/cloud/cloud.cfg"; probe=etc/cloud/cloud.cfg ;;
            file-vs-dir)       rm -rf "$d/c/var/lib/snapd/cookie"; printf 'x\n' > "$d/c/var/lib/snapd/cookie"; probe=var/lib/snapd/cookie ;;
        esac
        # shellcheck disable=SC1090
        out="$( source "$lib"; ci_split_same_path "$d/c" "$d/lv" "$probe" )"; rc=$?
        if [[ "$rc" -ne 0 && -n "$out" ]]; then t_pass "A7 same_path reports a difference: $kind"; else t_fail "A7 same_path misses a difference: $kind (rc=$rc, '$out')"; fi
    done
    # the row itself: restores when the build left the path alone, refuses (and leaves the merged view alone) when it did not
    mk_guard_trees "$d"
    # shellcheck disable=SC1090
    out="$( source "$lib"; log_info() { :; }; ci_split_row_restore "$d/m" "$d/s" etc/cloud/cloud.cfg "$d/c" "$d/lv" 2>&1 )"; rc=$?
    if [[ "$rc" -eq 0 && "$(cat "$d/m/etc/cloud/cloud.cfg")" == "default_user: ubuntu123" ]]; then t_pass "A7 restore row: an untouched path gets the stock standard copy (same size and mtime as the live copy)"; else t_fail "A7 restore row did not restore (rc=$rc): $out"; fi
    mk_guard_trees "$d"; printf 'default_user: installer\nmy_setting: 1\n' > "$d/c/etc/cloud/cloud.cfg"
    # shellcheck disable=SC1090
    out="$( source "$lib"; log_info() { :; }; ci_split_row_restore "$d/m" "$d/s" etc/cloud/cloud.cfg "$d/c" "$d/lv" 2>&1 )"; rc=$?
    if [[ "$rc" -ne 0 && "$out" == *"restore|etc/cloud/cloud.cfg"* && "$out" == *customized* && "$(cat "$d/m/etc/cloud/cloud.cfg")" == "default_user: installer" ]]; then
        t_pass "A7 restore row: a path the build customized stops the split, names the row, and is not overwritten"
    else t_fail "A7 restore row accepted a customized path (rc=$rc): $out"; fi
    mk_guard_trees "$d"
    # shellcheck disable=SC1090
    out="$( source "$lib"; log_info() { :; }; ci_split_row_restore "$d/m" "$d/s" var/lib/snapd/cookie "$d/c" "$d/lv" 2>&1 )"; rc=$?
    if [[ "$rc" -eq 0 && "$(cat "$d/m/var/lib/snapd/cookie/snap.a")" == k2 ]]; then t_pass "A7 restore row: a directory is restored entry for entry"; else t_fail "A7 restore row did not restore a directory (rc=$rc): $out"; fi
    mk_guard_trees "$d"
    # shellcheck disable=SC1090
    out="$( source "$lib"; log_info() { :; }; ci_split_row_restore "$d/m" "$d/s" etc/cloud/cloud.cfg "$d/c" "" 2>&1 )"; rc=$?
    if [[ "$rc" -eq 0 && "$out" == *"cannot check"* ]]; then t_pass "A7 restore row: without the stock live layer it still restores and says that the guard could not run"; else t_fail "A7 restore row without a live stack (rc=$rc): $out"; fi
    return "$GROUP_FAIL"
}

#=============================================================================
# The mutation helper: run a group against a broken copy of the library
#=============================================================================
# mutant <name> <fixed string in the library> <replacement> <group function>
# The group must report a failure with the broken copy (its GROUP_FAIL becomes 1); if it passes, the test would not have
# noticed that defect, which is a failure of the test.
MUT_N=0
mutant() {
    local name="$1" from="$2" to="$3" fn="$4" m rc
    MUT_N=$((MUT_N + 1))
    m="$WORK/mutant.$MUT_N.sh"
    if ! grep -q -F -- "$from" "$LIB"; then t_fail "mutation '$name': the line to break is not in the library any more ($from)"; return; fi
    # (ENVIRON, not -v: awk -v would process backslash escapes in the strings)
    FROM="$from" TO="$to" awk 'BEGIN { from = ENVIRON["FROM"]; to = ENVIRON["TO"]; n = length(from) }
        { i = index($0, from); if (i > 0) $0 = substr($0, 1, i - 1) to substr($0, i + n); print }' "$LIB" > "$m"
    if cmp -s "$m" "$LIB"; then t_fail "mutation '$name' changed nothing"; return; fi
    rc=0
    # shellcheck disable=SC1090
    ( source "$m"; LIB_UNDER_TEST="$m"; PASS=0; FAIL=0; GROUP_FAIL=0; "$fn" >/dev/null 2>&1; exit "$GROUP_FAIL" ) || rc=$?
    if [[ "$rc" -ne 0 ]]; then t_pass "mutation '$name': the check fails on the broken library"; else t_fail "mutation '$name' SURVIVED: $fn passes on a broken library"; fi
}

#=============================================================================
# A9: a synthetic rootfs through the real derivation, packing and verification (Linux, root)
#=============================================================================
syn_have_tools() {
    local t
    for t in mksquashfs unsquashfs rsync mount umount mknod chroot; do command -v "$t" >/dev/null 2>&1 || return 1; done
    grep -qw overlay /proc/filesystems 2>/dev/null
}
mk_syn_rootfs() { # mk_syn_rootfs <dir>
    local c="$1"
    rm -rf "$c"; mkdir -p "$c"/{etc,var,tmp,usr,dev,proc,sys,run,root,boot}
    chmod 755 "$c" "$c"/{etc,var,usr,root,boot}; chmod 1777 "$c/tmp"
    mkdir -p "$c/var/lib/dpkg" "$c/del/dir" "$c/del/emptydir" "$c/mod" "$c/keep/sub" "$c/dirattr" "$c/rdbf/inner" "$c/op" "$c/sw" \
             "$c/var/cache/apt/archives" "$c/var/lib/apt/lists" "$c/lnk"
    mk_status "$c/var/lib/dpkg/status"
    awk 'BEGIN { RS = ""; ORS = "\n\n" } $0 !~ /Package: casper/' "$c/var/lib/dpkg/status" > "$c/var/lib/dpkg/status.new" && mv "$c/var/lib/dpkg/status.new" "$c/var/lib/dpkg/status"
    printf 'x\n' > "$c/del/file1"; printf 'y\n' > "$c/del/dir/g"; printf 'm\n' > "$c/mod/file"; printf 'm2\n' > "$c/mod/file2"; chmod 644 "$c/mod/file2"
    printf 'a\n' > "$c/keep/a"; printf 'b\n' > "$c/keep/sub/b"; printf 'd\n' > "$c/dirattr/f"; chmod 755 "$c/dirattr"
    printf 'x\n' > "$c/rdbf/inner/y"; printf 'k1\n' > "$c/op/k1"; printf 'k2\n' > "$c/op/k2"; printf 'file-in-c\n' > "$c/rfbd"
    ln -s target-a "$c/sw/link"; printf 'old\n' > "$c/tmp/old"; printf 'l\n' > "$c/var/lib/apt/lists/foo"; printf 'z\n' > "$c/var/cache/apt/archives/pkg.deb"
    printf 'h\n' > "$c/lnk/one"; ln "$c/lnk/one" "$c/lnk/two"
    printf '#!/bin/sh\n' > "$c/keep/exec"; chmod 4755 "$c/keep/exec"
    mkfifo "$c/keep/fifo-c" 2>/dev/null || true
}
syn_change() { # syn_change <merged dir>: one change of every kind
    local m="$1"
    rm -f "$m/del/file1"; rm -rf "$m/del/dir"                                   # deleted file, deleted directory
    printf 'changed\n' > "$m/mod/file"; chmod 600 "$m/mod/file2"                # content change; mode change
    printf 'new\n' > "$m/keep/newfile"; mkdir -p "$m/newdir/sub"; printf 'f\n' > "$m/newdir/sub/f"   # new file, new directory
    chmod 700 "$m/dirattr"                                                       # directory mode
    rm -rf "$m/rdbf"; printf 'not a dir any more\n' > "$m/rdbf"                  # directory replaced by a file
    rm -f "$m/rfbd"; mkdir "$m/rfbd"; printf 'c\n' > "$m/rfbd/c"                 # file replaced by a directory
    rm -rf "$m/op"; mkdir "$m/op"; printf 'n1\n' > "$m/op/n1"                    # opaque directory
    rm -f "$m/sw/link"; ln -s target-b "$m/sw/link"                              # symlink with another target
    printf 'junk\n' > "$m/tmp/junk"; rm -f "$m/tmp/old"                          # changes in paths no layer keeps
    printf 'n\n' > "$m/var/lib/apt/lists/n"; printf 'q\n' > "$m/var/cache/apt/archives/new.deb"
    mkfifo "$m/keep/fifo-new" 2>/dev/null || true
    printf 'status changed\n' >> "$m/var/lib/dpkg/status"
}
g_synthetic() {
    local s="$WORK/syn" c rc out placeholder
    if [[ "$IS_LINUX_ROOT" -ne 1 ]]; then t_skip "A9 synthetic rootfs through derive/pack/verify: needs Linux and root (run it in a privileged container)"; return 0; fi
    if ! syn_have_tools; then t_skip "A9 synthetic rootfs: needs mksquashfs, unsquashfs, rsync, mount, chroot and overlayfs"; return 0; fi
    # make_placeholder_layer is build-iso.sh's; sourcing it defines the functions only and turns on set -e: undo that
    # shellcheck source=../scripts/build-iso.sh
    source "$BUILD"; set +e; set -u
    rm -rf "$s"; mkdir -p "$s"; c="$s/c"
    mk_syn_rootfs "$c"
    # (both are the library's variables: a fast compressor, and no casper to require in a synthetic live layer)
    # shellcheck disable=SC2034
    CI_SPLIT_MKSQUASHFS_OPTS="-comp gzip -b 128K"
    # shellcheck disable=SC2034
    CI_SPLIT_LIVE_REQUIRED=()
    local u="$s/up" w="$s/wk" m="$s/m" res="$s/res" stage="$s/stage"
    mkdir -p "$u" "$w" "$m" "$res"
    chmod --reference="$c" "$u"; chown --reference="$c" "$u"
    ci_split_traps_install
    if ! ci_split_overlay_mount "$c" "$m" "$u" "$w"; then
        # the upper directory may not live on an overlay root: use a tmpfs
        mkdir -p "$s/tmpfs"; mount -t tmpfs tmpfs "$s/tmpfs" && ci_split_track_mount "$s/tmpfs" || { t_skip "A9 cannot mount an overlay here"; ci_split_cleanup; ci_split_traps_remove; return 0; }
        u="$s/tmpfs/up"; w="$s/tmpfs/wk"; mkdir -p "$u" "$w"; chmod --reference="$c" "$u"; chown --reference="$c" "$u"
        ci_split_overlay_mount "$c" "$m" "$u" "$w" || { t_skip "A9 this kernel does not give an overlayfs mount"; ci_split_cleanup; ci_split_traps_remove; return 0; }
    fi
    syn_change "$m"
    if ci_split_build_live_tree "$c" "$u" "$m" "$stage" "$res"; then t_pass "A9 L is derived from the upper directory"; else t_fail "A9 deriving L failed"; ci_split_cleanup; ci_split_traps_remove; return 1; fi
    ci_split_pack "$m" "$s/B.sqsh" "synthetic B" >/dev/null || { t_fail "A9 cannot pack B"; ci_split_cleanup; ci_split_traps_remove; return 1; }
    ci_split_pack "$stage" "$s/L.sqsh" "synthetic L" >/dev/null || { t_fail "A9 cannot pack L"; ci_split_cleanup; ci_split_traps_remove; return 1; }
    placeholder="$(mktemp -d "$s/ph.XXXXXX")"; make_placeholder_layer "$c" "$placeholder"
    mksquashfs "$placeholder" "$s/PH.sqsh" -comp gzip -noappend -no-recovery -quiet >/dev/null 2>&1
    ci_split_cleanup
    ci_split_traps_remove

    rc=0; out="$(ci_split_verify_layers "$c" "$s/B.sqsh" "$s/PH.sqsh" "$s/L.sqsh" "$res" 2>&1)" || rc=$?
    if [[ "$rc" -eq 0 ]]; then t_pass "A9 overlay(B + placeholder + L) == rootfs for every kind of change (deleted, changed, new, replaced, opaque, fifo, symlink, excluded)"
    else t_fail "A9 the stack of the synthetic layers is not the rootfs: $(printf '%s\n' "$out" | tail -n 12 | tr '\n' '|')"; fi
    # L must hold the right things, and no more
    local lt="$s/lt"; mkdir -p "$lt"
    unsquashfs -n -q -f -d "$lt" "$s/L.sqsh" > "$s/lt.log" 2>&1
    if [[ -f "$lt/del/file1" && -f "$lt/del/dir/g" && -f "$lt/mod/file" && "$(cat "$lt/mod/file")" == m ]]; then t_pass "A9 L carries C's version of the deleted and the changed files"; else t_fail "A9 L lacks C's versions of deleted/changed files ($(head -n 3 "$s/lt.log" | tr '\n' '|'))"; fi
    if [[ -c "$lt/keep/newfile" && -c "$lt/newdir" && ! -e "$lt/newdir/sub" ]]; then t_pass "A9 L whites out what only B has (a new directory as one whiteout)"; else t_fail "A9 L's whiteouts are not as expected"; fi
    if [[ ! -e "$lt/tmp/junk" && ! -e "$lt/var/lib/apt/lists/n" ]]; then t_pass "A9 nothing of the paths that no layer keeps is in L"; else t_fail "A9 L carries a path no layer keeps"; fi
    # a defect in L must be caught: the same B with a file missing from L
    rm -f "$lt/mod/file"
    rm -f "$s/L2.sqsh"
    ci_split_traps_install
    ci_split_pack "$lt" "$s/L2.sqsh" "broken L" >/dev/null
    ci_split_traps_remove
    rc=0; out="$(ci_split_verify_layers "$c" "$s/B.sqsh" "$s/PH.sqsh" "$s/L2.sqsh" "$res" 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'mod/file'; then t_pass "A9 the verification rejects an L that lacks a file (and names it)"; else t_fail "A9 the verification accepted a broken L (rc=$rc)"; fi
    # and a base layer that still carries casper is rejected before the comparison
    local bt="$s/bt"; mkdir -p "$bt"; unsquashfs -n -q -f -d "$bt" "$s/B.sqsh" >/dev/null 2>&1
    mkdir -p "$bt/usr/lib/casper"; : > "$bt/usr/lib/casper/casper-md5check"
    rm -f "$s/B2.sqsh"; ci_split_traps_install; ci_split_pack "$bt" "$s/B2.sqsh" "B with casper" >/dev/null; ci_split_traps_remove
    rc=0; out="$(ci_split_verify_layers "$c" "$s/B2.sqsh" "$s/PH.sqsh" "$s/L.sqsh" "$res" 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'live-only'; then t_pass "A9 the verification rejects a base layer with casper in it"; else t_fail "A9 the verification accepted a base with casper (rc=$rc)"; fi
    return "$GROUP_FAIL"
}

#=============================================================================
# Run part A
#=============================================================================
run_group() { # run_group <id> <function>
    local id="$1" fn="$2"
    wanted "$id" || return 0
    GROUP_FAIL=0
    "$fn" || true
}

run_group A1 g_table
run_group A2 g_excludes
run_group A3 g_parse
run_group A4 g_assert_tree
run_group A5 g_plan
run_group A5 g_plan_whiteouts
run_group A6 g_shell_state
run_group A7 g_restore_guard

if wanted A8; then
    # Each pure check must notice the defect it exists for: break the library, run the check, require a failure.
    mutant "assert_tree ignores live-only paths" 'if [[ -e "$f" || -L "$f" ]]; then echo "live-only path in the base' 'if false; then echo "live-only path in the base' g_assert_tree
    mutant "assert_tree ignores the casper package" 'for g in casper finalrd; do' 'for g in ; do' g_assert_tree
    mutant "assert_tree ignores installer snaps" 'if [[ -r "$f" ]] && grep -q -F -- "$snap" "$f"; then' 'if false; then' g_assert_tree
    mutant "assert_tree ignores a seed that names a snap file the base lacks" 'if [[ ! -f "$root/var/lib/snapd/seed/snaps/$f" ]]; then echo' 'if false; then echo' g_assert_tree
    mutant "assert_tree ignores the live cloud.cfg" "grep -q 'subiquity-shell' \"\$root/etc/cloud/cloud.cfg\"" 'false' g_assert_tree
    mutant "the plan loses the whiteouts of new paths" '"$rel" >> "$wh"; skip="$rel"' '"$rel" > /dev/null; skip="$rel"' g_plan
    mutant "the plan loses replaced paths" 'ci_split_emit_subtree "$C" "$rel" >> "$copy"; skip="$rel"' 'skip="$rel"' g_plan
    mutant "the plan forgets opaque directories" 'ci_split_emit_hidden "$C" "$U" "$M" "$rel" >> "$copy"' ':' g_plan
    mutant "the plan lists paths no layer keeps" 'ci_split_is_excluded "$rel" && continue' ':' g_plan
    mutant "the excludes are gone" "CI_SPLIT_PACK_EXCLUDES=('var/cache/apt/archives/*' 'var/lib/apt/lists/*' 'tmp/*' 'root/.bash_history')" "CI_SPLIT_PACK_EXCLUDES=('x/y/z')" g_excludes
    mutant "the installer snap names are not derived" 'LC_ALL=C comm -23' 'LC_ALL=C comm -12' g_parse
    mutant "cleanup leaves errexit off" 'if [[ "$errexit" -eq 1 ]]; then set -e; fi' ':' g_shell_state
    mutant "traps_remove forgets the caller's EXIT trap" '        trap "$CI_SPLIT_PREV_EXIT" EXIT' '        trap - EXIT' g_shell_state
    if rsync_has_ax; then
        mutant "the restore guard is off" 'if ! diff="$(ci_split_same_path "$C" "$LV" "$rel")"; then' 'if false; then' g_restore_guard
        mutant "the restore guard compares sizes, not content" 'rsync -rlpgoDAXc "--filter=-x trusted.overlay.*" --numeric-ids -n --delete -i "$a/" "$b/"' 'rsync -rlpgoDAX "--filter=-x trusted.overlay.*" --numeric-ids -n --delete -i "$a/" "$b/"' g_restore_guard
        mutant "the restore guard compares single files by size, not content" 'rsync -lpgoDAXc "--filter=-x trusted.overlay.*" --numeric-ids -n -i "$a" "$b"' 'rsync -lpgoDAX "--filter=-x trusted.overlay.*" --numeric-ids -n -i "$a" "$b"' g_restore_guard
        mutant "the restore trusts rsync's size-and-mtime quick check (directory)" 'rsync -aAXc --numeric-ids --delete "$src/" "$dst/"' 'rsync -aAX --numeric-ids --delete "$src/" "$dst/"' g_restore_guard
        mutant "the restore trusts rsync's size-and-mtime quick check (file)" 'rsync -aAXc --numeric-ids "$src" "$dst"' 'rsync -aAX --numeric-ids "$src" "$dst"' g_restore_guard
        mutant "the restore guard ignores a file the build left of another kind" 'echo "present on one side only, or a directory on one side and not on the other"; return 1' 'return 0' g_restore_guard
    else t_skip "A8 restore-guard mutants: need rsync >= 3 with -A -X (a Linux host or container)"; fi
    mutant "the table validator accepts '..'" '"$p" == *..* || "$p" != */* || "$p" == *" "* || -n "$arg2"' '"$p" != */* || "$p" == *" "* || -n "$arg2"' g_table
fi

run_group A9 g_synthetic

#=============================================================================
# Part B: real data
#=============================================================================
B_C="${SPLIT_TEST_CHROOT:-/v/w/chroot}"
B_STOCK="${SPLIT_TEST_STOCK:-/v/w/squashfs}"
B_WORK="${SPLIT_TEST_WORK:-}"
B_COMP="${SPLIT_TEST_COMP:--comp zstd -Xcompression-level 3 -b 256K}"
if [[ "$B_COMP" == prod ]]; then B_COMP="-comp xz -b 1M"; fi
B_RES=""; B_OUT=""      # result dir, layer output dir (set by b_prepare)

b_prepare() { # decide whether Part B can run here; say why not
    local tool lack=""
    if [[ "$IS_LINUX_ROOT" -ne 1 ]]; then t_skip "B real-data groups: need Linux and root (a privileged container); Part A ran"; return 1; fi
    if [[ ! -d "$B_C/etc" || ! -f "$B_C/var/lib/dpkg/status" ]]; then t_skip "B real-data groups: no merged rootfs at $B_C (set SPLIT_TEST_CHROOT)"; return 1; fi
    if [[ ! -f "$B_STOCK/minimal.squashfs" || ! -f "$B_STOCK/minimal.standard.live.squashfs" ]]; then
        t_skip "B real-data groups: no stock layers in $B_STOCK (set SPLIT_TEST_STOCK)"; return 1
    fi
    for tool in mksquashfs unsquashfs rsync mount chroot unmkinitramfs; do command -v "$tool" >/dev/null 2>&1 || lack="$lack $tool"; done
    if [[ -n "$lack" ]]; then t_skip "B real-data groups: missing tools:$lack"; return 1; fi
    if ! syn_have_tools; then t_skip "B real-data groups: no overlayfs"; return 1; fi
    if [[ -z "$B_WORK" ]]; then
        B_WORK="$(mktemp -d /var/tmp/split-live-layer-real.XXXXXX)"
        t_info "SPLIT_TEST_WORK is not set: using $B_WORK (on a container's own root an overlayfs upper directory is refused and a tmpfs is used instead; give it a volume)"
    fi
    mkdir -p "$B_WORK" || return 1
    B_RES="$B_WORK/res"; B_OUT="$B_WORK/out"
    export CI_SPLIT_VERIFY="${SPLIT_TEST_VERIFY:-full}"
    # shellcheck source=../scripts/build-iso.sh
    source "$BUILD"; set +e; set -u     # make_placeholder_layer; sourcing turns on set -e
    return 0
}

b_mount() { # b_mount <squashfs> <mountpoint>
    mkdir -p "$2" && ci_split_loop_mount "$1" "$2"
}
b_dirs_equal() { # b_dirs_equal <a> <b>: same names, types, modes, owners, link targets, contents and xattrs; both absent counts as equal
    local a="$1" d="$2" out
    if [[ ! -e "$a" && ! -L "$a" && ! -e "$d" && ! -L "$d" ]]; then return 0; fi
    if [[ ! -d "$a" || ! -d "$d" ]]; then return 1; fi
    out="$(rsync -rlpgoDAXc "--filter=-x trusted.overlay.*" --numeric-ids -n --delete -i "$a/" "$d/" 2>&1)" || return 1
    [[ -z "$out" ]]
}

# ── B1: the audit of the stock live layer ───────────────────────────────────────────────────────────────────────────
# Every path of the stock live layer that neither lower layer has and no package owns must be accounted for: removed by a
# row of the table, or the generated state of a package that stays (the keep patterns below). A new live-only file in a new
# base ISO fails here until somebody decides which it is.
KEEP_PATTERNS=(
    'var/lib/dpkg/*'                                  # dpkg's own files: info/, alternatives/, triggers/ (casper's go with its purge)
    'var/cache/apparmor/*'                            # AppArmor's compiled-profile cache (the installer snap's entries: the sweep)
    'var/lib/systemd/deb-systemd-helper-*/*'          # enable state of the units of kept packages (casper's, finalrd's: purge)
    'usr/lib/python3/*' 'usr/share/ibus-hangul/*'     # byte-compiled caches of kept packages
    'etc/rc?.d/*' 'etc/rcS.d/*'                       # SysV links of zfs, cryptsetup (kept)
    'etc/zfs/zed.d/*' 'usr/lib/modules/*' 'boot/*' 'etc/alternatives/*' 'etc/cifs-utils/*' 'usr/share/man/man8/idmap-plugin.8.gz'
    'etc/crypttab' 'etc/default/grub' 'etc/default/mdadm' 'etc/mdadm/*'
    'etc/hostid'                                      # zfsutils-linux's postinst wrote ONE hostid into the image: every install shares it (not touched here)
    'etc/systemd/system/dbus-org.freedesktop.thermald.service' 'etc/systemd/system/mdmonitor.service.wants'
    'etc/systemd/system/mdmonitor.service.wants/*' 'etc/systemd/system/multi-user.target.wants/thermald.service'
    'etc/systemd/system/multi-user.target.wants/zfs.target' 'etc/systemd/system/sockets.target.wants/dm-event.socket'
    'etc/systemd/system/sysinit.target.wants/blk-availability.service' 'etc/systemd/system/sysinit.target.wants/lvm2-*'
    'etc/systemd/system/zed.service' 'etc/systemd/system/zfs*'
    'run/*' 'usr/lib/shim/*' 'var/lib/grub/*' 'var/lib/ucf/*'
)
b_audit_match() { # b_audit_match <relative path> <installer snap names>: prints how the path is accounted for, or nothing
    local q="$1" snaps="$2" row kind arg g n e root b anc
    case "$q" in *casper* | *finalrd*) echo purge; return 0 ;; esac
    while IFS= read -r row; do
        kind="${row%%|*}"; arg="${row#*|}"; arg="${arg%%|*}"
        case "$kind" in
            rm | rmdir | rmnew | rmgrep | restore)
                # shellcheck disable=SC2053
                if [[ "$q" == $arg || "$q" == $arg/* ]]; then echo "$kind"; return 0; fi ;;
        esac
    done < <(ci_split_table_rows)
    b="${q##*/}"
    for n in $snaps; do
        e="${n//-/\\x2d}"
        for root in snap var/snap var/lib/snapd var/cache/apparmor var/cache/snapd etc/systemd/system; do
            [[ "$q" == "$root"/* ]] || continue
            anc="$q"
            while [[ "$anc" == "$root"/* ]]; do
                b="${anc##*/}"
                case "$b" in
                    "$n" | "$n"_* | "$n".* | "snap.$n" | "snap.$n".* | "snap-update-ns.$n" | "snap-$n-"* | "snap-$e-"*) echo snap; return 0 ;;
                esac
                anc="${anc%/*}"
            done
        done
    done
    for g in "${KEEP_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$q" == $g ]]; then echo keep; return 0; fi
    done
    return 1
}
g_b_audit() {
    local d="$B_WORK/audit" live="$B_STOCK/minimal.standard.live.squashfs" q cls n_unowned=0 n_un=0 snaps
    local -a unclassified=()
    rm -rf "$d"; mkdir -p "$d/std" "$d/min"
    # the stock standard stack, for "does a lower layer have it"
    ci_split_loop_mount "$B_STOCK/minimal.squashfs" "$d/min" || { t_fail "B1 cannot mount the stock minimal layer"; return 1; }
    if [[ -f "$B_STOCK/minimal.standard.squashfs" ]]; then
        ci_split_loop_mount "$B_STOCK/minimal.standard.squashfs" "$d/std" && ci_split_overlay_mount "$d/std:$d/min" "$d/view" || { t_fail "B1 cannot stack the stock layers"; ci_split_cleanup; return 1; }
    else
        mkdir -p "$d/view" && mount --bind "$d/min" "$d/view" && ci_split_track_mount "$d/view"
    fi
    unsquashfs -ll "$live" 2>/dev/null | sed -E 's/^[^ ]+ +[^ ]+ +[0-9, ]+ +[0-9-]+ +[0-9:]+ ?//; s/ -> .*$//; s#^squashfs-root##; /^$/d' | LC_ALL=C sort -u > "$d/live.paths"
    unsquashfs -n -q -f -d "$d/dpkg" "$live" var/lib/dpkg/info >/dev/null 2>&1
    cat "$d"/dpkg/var/lib/dpkg/info/*.list 2>/dev/null | sed -E 's#^/(bin|sbin|lib|lib64)(/|$)#/usr/\1\2#' | LC_ALL=C sort -u > "$d/owned.paths"
    # live-only: no lower layer has the path
    while IFS= read -r q; do
        [[ -n "$q" ]] || continue
        [[ -e "$d/view$q" || -L "$d/view$q" ]] || printf '%s\n' "$q"
    done < "$d/live.paths" | LC_ALL=C sort -u > "$d/liveonly.paths"
    LC_ALL=C comm -23 "$d/liveonly.paths" "$d/owned.paths" > "$d/unowned.paths"
    n_un="$(wc -l < "$d/liveonly.paths" | tr -d ' ')"; n_unowned="$(wc -l < "$d/unowned.paths" | tr -d ' ')"
    t_info "B1 the stock live layer has $(wc -l < "$d/live.paths" | tr -d ' ') paths, $n_un of them in neither lower layer, $n_unowned of those owned by no package"
    snaps="$(ci_split_installer_snap_names "$B_C/var/lib/snapd/seed/seed.yaml" "$d/view/var/lib/snapd/seed/seed.yaml" | tr '\n' ' ')"
    local n_rm=0 n_keep=0
    while IFS= read -r q; do
        q="${q#/}"
        if cls="$(b_audit_match "$q" "$snaps")"; then
            case "$cls" in keep) n_keep=$((n_keep + 1)) ;; *) n_rm=$((n_rm + 1)) ;; esac
        else
            unclassified+=("/$q")
        fi
    done < "$d/unowned.paths"
    t_info "B1 of those: $n_rm are removed or restored by the table, $n_keep are the generated state of packages that stay, ${#unclassified[@]} unaccounted for"
    if [[ "${#unclassified[@]}" -eq 0 ]]; then t_pass "B1 every live-only path outside a package is accounted for (table or kept package state)"
    else t_fail "B1 live-only paths neither in the table nor in the keep list: ${unclassified[*]:0:12}"; fi
    # the owned live-only paths belong to packages that must stay, except the purged ones
    local purged own_bad
    purged="$(ci_split_table_rows | sed -n 's/^purge|//p' | tr ' ' '\n')"
    own_bad=0
    for q in $purged; do
        if [[ -f "$d/dpkg/var/lib/dpkg/info/$q.list" ]]; then t_pass "B1 the table's purge package $q is part of the stock live layer"; else t_fail "B1 $q is not a package of the stock live layer"; own_bad=1; fi
    done
    ci_split_cleanup
    return "$own_bad"
}

# ── B2/B3: the split and its verification on the real rootfs ────────────────────────────────────────────────────────
B_SPLIT_RC=1
g_b_split() {
    local t0 rc tp n_restore
    rm -rf "$B_RES" "$B_OUT"; mkdir -p "$B_RES" "$B_OUT"
    CI_SPLIT_MKSQUASHFS_OPTS="$B_COMP"
    t_info "B2 mksquashfs options: $CI_SPLIT_MKSQUASHFS_OPTS"
    t0=$SECONDS; rc=0
    ci_split_live_layer "$B_C" "$B_OUT/minimal.squashfs" "$B_OUT/minimal.standard.live.squashfs" "$B_RES" "$B_STOCK" > "$B_WORK/split.log" 2>&1 || rc=$?
    tp=$((SECONDS - t0))
    if [[ "$rc" -eq 0 ]]; then t_pass "B2 the split of the real rootfs succeeds ($tp s)"; else t_fail "B2 the split failed (rc=$rc, $tp s): $(tail -n 8 "$B_WORK/split.log" | tr '\n' '|')"; return 1; fi
    B_SPLIT_RC=0
    t_info "B2 B = $(stat -c%s "$B_OUT/minimal.squashfs") bytes, L = $(stat -c%s "$B_OUT/minimal.standard.live.squashfs") bytes (compressed)"
    grep -E 'split: (base layer|L staged|packed|installer snaps|dpkg --purge)' "$B_WORK/split.log" | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r l; do t_info "B2 $l"; done
    # the restore rows ran with their guard (the rootfs is still the stock live layer's copy of every restored path), for every row
    n_restore="$(ci_split_table_rows | grep -c '^restore|')"
    if [[ "$n_restore" -gt 0 && "$(grep -c 'split: restore /' "$B_WORK/split.log")" == "$n_restore" ]] && ! grep -q 'cannot check that the build left it alone' "$B_WORK/split.log"; then
        t_pass "B2 all $n_restore restore rows ran, each after the guard had found the rootfs's copy equal to the stock live layer's (the build customized none of them)"
    else t_fail "B2 restore rows: $(grep -c 'split: restore /' "$B_WORK/split.log") of $n_restore ran, or the guard could not run"; fi
    # the placeholder, as build-iso.sh makes it
    local ph; ph="$(mktemp -d "$B_WORK/ph.XXXXXX")"
    make_placeholder_layer "$B_C" "$ph"
    mksquashfs "$ph" "$B_OUT/minimal.standard.squashfs" -comp xz -noappend -no-recovery -quiet >/dev/null 2>&1
    rm -rf "$ph"
    t0=$SECONDS; rc=0
    ci_split_verify_layers "$B_C" "$B_OUT/minimal.squashfs" "$B_OUT/minimal.standard.squashfs" "$B_OUT/minimal.standard.live.squashfs" "$B_RES" > "$B_WORK/verify.log" 2>&1 || rc=$?
    tp=$((SECONDS - t0))
    if [[ "$rc" -eq 0 ]]; then t_pass "B3 overlay(B + placeholder + L) == the real rootfs: content by checksum, modes, owners, symlinks, devices, xattrs (${CI_SPLIT_VERIFY:-full} comparison, $tp s)"
    else t_fail "B3 the stack of the real layers is not the rootfs (rc=$rc): $(tail -n 12 "$B_WORK/verify.log" | tr '\n' '|')"; fi
    grep -E 'split: (comparing|overlay|sizes)' "$B_WORK/verify.log" | sed 's/\x1b\[[0-9;]*m//g' | while IFS= read -r l; do t_info "B3 $l"; done
    return "$GROUP_FAIL"
}

# ── B4/B5: what B and L hold ────────────────────────────────────────────────────────────────────────────────────────
# A shell in a chroot on an overlay of <lowerdir>: b_chroot_open <name> <lowerdir> sets $BCH (the merged dir) and mounts /dev ...
b_chroot_open() {
    local name="$1" lower="$2" t="$B_WORK/ch-$1"
    rm -rf "$t"; mkdir -p "$t/up" "$t/wk" "$t/m" "$t/x"
    ci_split_overlay_mount "$lower" "$t/m" "$t/up" "$t/wk" || return 1
    mount --bind /dev "$t/m/dev" && ci_split_track_mount "$t/m/dev" || return 1
    mount -t proc proc "$t/m/proc" && ci_split_track_mount "$t/m/proc" || return 1
    mount -t sysfs sysfs "$t/m/sys" && ci_split_track_mount "$t/m/sys" || return 1
    mount -t tmpfs -o mode=0755 tmpfs "$t/m/run" && ci_split_track_mount "$t/m/run" || return 1
    BCH="$t/m"; BCHX="$t/x"
}
g_b_base() {
    local m="$B_WORK/mnt" base out pkgs p snaps f n
    [[ "$B_SPLIT_RC" -eq 0 ]] || { t_skip "B4 B5 need the split (B2 failed or was not selected)"; return 0; }
    mkdir -p "$m/b" "$m/l" "$m/std" "$m/min" "$m/view"
    b_mount "$B_OUT/minimal.squashfs" "$m/b" && b_mount "$B_OUT/minimal.standard.live.squashfs" "$m/l" \
        && b_mount "$B_STOCK/minimal.squashfs" "$m/min" || { t_fail "B4 cannot mount the layers"; return 1; }
    if [[ -f "$B_STOCK/minimal.standard.squashfs" ]]; then
        b_mount "$B_STOCK/minimal.standard.squashfs" "$m/std" && ci_split_overlay_mount "$m/std:$m/min" "$m/view" || { t_fail "B4 cannot stack the stock layers"; return 1; }
    else mount --bind "$m/min" "$m/view" && ci_split_track_mount "$m/view"; fi
    base="$m/b"
    snaps="$(cat "$B_RES/installer-snaps.txt" 2>/dev/null | tr '\n' ' ')"
    t_info "B4 installer snaps named by the build: $snaps"

    # -- casper, in every shape
    # shellcheck disable=SC2086
    if out="$(ci_split_assert_base_tree "$base" $snaps)"; then t_pass "B4 the packed B passes every invariant (no casper, no live dconf override, no installer snap, no live units ...)"; else t_fail "B4 live-only content in the packed B: $(printf '%s' "$out" | head -n 6 | tr '\n' '|')"; fi
    out="$(find "$base" -xdev -iname '*casper*' 2>/dev/null | head -n 5 | tr '\n' ' ')"
    if [[ -z "$out" ]]; then t_pass "B4 not one path in B has 'casper' in its name"; else t_fail "B4 paths named after casper in B: $out"; fi
    # (assignments, not mentions: busybox-initramfs's own hook reads $CASPER_GENERATE_UUID in a stock `if`)
    out="$(grep -rIlE '^[[:space:]]*(export[[:space:]]+)?(CASPER_GENERATE_UUID|LAYERFS_PATH)=|BOOT=casper' "$base/etc/initramfs-tools" "$base/usr/share/initramfs-tools" "$base/usr/lib/initramfs-tools" 2>/dev/null | head -n 5 | tr '\n' ' ')"
    if [[ -z "$out" ]]; then t_pass "B4 nothing in the initramfs-tools trees sets BOOT=casper, CASPER_GENERATE_UUID or LAYERFS_PATH"; else t_fail "B4 casper settings left in: $out"; fi
    # (the stanza, and anything that depends on it; another package's Breaks: casper (<< 1.361) is stock and harmless)
    if ! awk 'BEGIN { RS = ""; FS = "\n" } $1 == "Package: casper" { f = 1 } /\n(Pre-)?Depends:[^\n]*[ ,]casper([ ,(]|$)/ { f = 1 } END { exit !f }' "$base/var/lib/dpkg/status"; then
        t_pass "B4 B's dpkg status has no casper stanza and nothing depends on casper"; else t_fail "B4 B's dpkg status has casper or a dependency on it"; fi
    if grep -q -F 'Package: casper' "$m/l/var/lib/dpkg/status" 2>/dev/null; then t_pass "B5 L's dpkg status (the live session's) has casper"; else t_fail "B5 L's dpkg status lacks casper"; fi
    # -- the packages that stay
    pkgs="linux-image-generic-hwe-24.04 grub-efi-amd64-signed grub-pc shim-signed zfsutils-linux lvm2 mdadm cryptsetup gparted linux-firmware btrfs-progs intel-microcode amd64-microcode efibootmgr mokutil thermald ubuntu-desktop-minimal snapd cloud-init"
    for p in $pkgs; do
        if awk -v p="$p" 'BEGIN { RS = ""; FS = "\n" } $1 == "Package: " p { for (i = 1; i <= NF; i++) if ($i == "Status: install ok installed") f = 1 } END { exit !f }' "$base/var/lib/dpkg/status"; then
            t_pass "B4 $p is still installed in B"; else t_fail "B4 $p is gone from B (it must stay)"; fi
    done
    if ls "$base"/boot/vmlinuz-*-generic >/dev/null 2>&1 && ls "$base"/usr/lib/modules/*/modules.dep >/dev/null 2>&1; then t_pass "B4 B has a kernel image and its modules ($(ls "$base"/boot/vmlinuz-*-generic | sed 's#.*/vmlinuz-##' | tr '\n' ' '))"; else t_fail "B4 B has no kernel image or modules"; fi
    # -- the snapd state is the stock standard layer's, whole
    for f in var/lib/snapd/state.json var/lib/snapd/system-key var/lib/snapd/seed/seed.yaml; do
        if cmp -s "$base/$f" "$m/view/$f"; then t_pass "B4 /$f is the stock standard stack's"; else t_fail "B4 /$f differs from the stock standard stack's"; fi
    done
    for f in var/lib/snapd/seed/assertions var/lib/snapd/assertions var/lib/snapd/apparmor/profiles var/lib/snapd/cgroup var/lib/snapd/cookie \
             var/lib/snapd/desktop/applications var/lib/snapd/inhibit var/lib/snapd/mount var/lib/snapd/seccomp/bpf var/lib/snapd/sequence var/cache/snapd/aux; do
        if b_dirs_equal "$m/view/$f" "$base/$f" 2>/dev/null; then t_pass "B4 /$f is the stock standard stack's, entry for entry"; else t_fail "B4 /$f differs from the stock standard stack's"; fi
    done
    # every snap the seed names has its file in B, and B holds no other blob
    local seed_missing="" blob_extra=""
    while IFS= read -r f; do [[ -n "$f" ]] || continue; [[ -f "$base/var/lib/snapd/seed/snaps/$f" ]] || seed_missing="$seed_missing $f"; done \
        < <(sed -n 's/^[[:space:]-]*file:[[:space:]]*//p' "$base/var/lib/snapd/seed/seed.yaml" | tr -d '\r"'"'")
    for f in "$base"/var/lib/snapd/seed/snaps/*.snap "$base"/var/lib/snapd/snaps/*.snap; do
        [[ -e "$f" ]] || continue
        n="${f##*/}"; grep -q -F "file: $n" "$base/var/lib/snapd/seed/seed.yaml" || blob_extra="$blob_extra $n"
    done
    if [[ -z "$seed_missing" ]]; then t_pass "B4 every snap file seed.yaml names is in B"; else t_fail "B4 seed.yaml names snap files B lacks:$seed_missing"; fi
    if [[ -z "$blob_extra" ]]; then t_pass "B4 B holds no snap file that seed.yaml does not name"; else t_fail "B4 snap files in B that no seed entry names:$blob_extra"; fi
    # -- the apt pin backup: the stock standard layer's flat files stay (a stock install has them), livecd-rootfs's nested copy goes
    if b_dirs_equal "$m/view/etc/apt/preferences.d.save" "$base/etc/apt/preferences.d.save" 2>/dev/null && [[ ! -e "$base/etc/apt/preferences.d.save/preferences.d" ]]; then
        t_pass "B4 /etc/apt/preferences.d.save is the stock standard stack's (the flat ubuntu-pro-esm-* files), without the live layer's nested preferences.d"
    else t_fail "B4 /etc/apt/preferences.d.save differs from the stock standard stack's"; fi
    # -- cloud-init, networkd
    if cmp -s "$base/etc/cloud/cloud.cfg" "$m/view/etc/cloud/cloud.cfg"; then t_pass "B4 /etc/cloud/cloud.cfg is the stock one (no live default user)"; else t_fail "B4 /etc/cloud/cloud.cfg is not the stock one"; fi
    if cmp -s "$base/usr/lib/systemd/systemd-networkd-wait-online" "$m/view/usr/lib/systemd/systemd-networkd-wait-online" && [[ ! -L "$base/usr/lib/systemd/systemd-networkd-wait-online" ]]; then t_pass "B4 systemd-networkd-wait-online is the real binary"; else t_fail "B4 systemd-networkd-wait-online is not the stock binary"; fi
    # -- no dangling units the removal introduced
    local dang_b dang_c
    dang_b="$(cd "$base" && find etc/systemd usr/lib/systemd -xtype l 2>/dev/null | LC_ALL=C sort)"
    dang_c="$(cd "$B_C" && find etc/systemd usr/lib/systemd -xtype l 2>/dev/null | LC_ALL=C sort)"
    out="$(LC_ALL=C comm -23 <(printf '%s\n' "$dang_b") <(printf '%s\n' "$dang_c") | head -n 5 | tr '\n' ' ')"
    if [[ -z "$out" ]]; then t_pass "B4 the removal left no dangling systemd link that C did not already have"; else t_fail "B4 dangling systemd links introduced: $out"; fi
    # -- B and C: what differs is what the table says
    ( cd "$B_C" && find . -xdev -print | LC_ALL=C sort ) > "$B_WORK/paths.c"
    ( cd "$base" && find . -xdev -print | LC_ALL=C sort ) > "$B_WORK/paths.b"
    t_info "B4 B has $(wc -l < "$B_WORK/paths.b" | tr -d ' ') entries, the rootfs $(wc -l < "$B_WORK/paths.c" | tr -d ' '); $(LC_ALL=C comm -23 "$B_WORK/paths.c" "$B_WORK/paths.b" | wc -l | tr -d ' ') only in the rootfs"
    out="$(LC_ALL=C comm -13 "$B_WORK/paths.c" "$B_WORK/paths.b" | while IFS= read -r f; do ci_split_is_excluded "${f#./}" || printf '%s ' "$f"; done)"
    if [[ -z "$out" ]]; then t_pass "B4 B has no path the rootfs does not have (so L needs no whiteouts)"; else t_info "B4 paths only in B (L whites them out): ${out:0:300}"; fi

    # -- L
    local live="$m/l" nolive=""
    for f in "${CI_SPLIT_LIVE_REQUIRED[@]}"; do [[ -e "$live/$f" || -L "$live/$f" ]] || nolive="$nolive /$f"; done
    if [[ -z "$nolive" ]]; then t_pass "B5 L holds casper (casper-md5check and its units, the initramfs hook and scripts, casper.conf, the dpkg list) and the live dconf override"; else t_fail "B5 L lacks:$nolive"; fi
    if cmp -s "$live/etc/casper.conf" "$B_C/etc/casper.conf" && grep -q 'FLAVOUR="Companion"' "$live/etc/casper.conf"; then t_pass "B5 L's casper.conf is the build's (the live user and host name)"; else t_fail "B5 L's casper.conf is not the rootfs's"; fi
    if cmp -s "$live/etc/cloud/cloud.cfg" "$B_C/etc/cloud/cloud.cfg" && grep -q subiquity-shell "$live/etc/cloud/cloud.cfg"; then t_pass "B5 L carries the live session's cloud.cfg unchanged"; else t_fail "B5 L's cloud.cfg is not the live session's"; fi
    if cmp -s "$live/var/lib/snapd/state.json" "$B_C/var/lib/snapd/state.json" && cmp -s "$live/var/lib/snapd/seed/seed.yaml" "$B_C/var/lib/snapd/seed/seed.yaml"; then t_pass "B5 L carries the live session's own snapd state (the installer snap runs from it)"; else t_fail "B5 L's snapd state is not the live session's"; fi
    out="$(find "$live" -xdev -type c 2>/dev/null | head -n 6 | tr '\n' ' ')"
    t_info "B5 whiteouts in L: ${out:-none} (what B alone has; the real removal creates none beyond these)"

    # -- dpkg and the schemas, in a chroot on an overlay of the packed B
    if b_chroot_open B-dpkg "$base"; then
        if ci_split_chroot "$BCH" apt-get -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= check >/dev/null 2>&1; then t_pass "B4 apt-get check: B's dpkg database is consistent"; else t_fail "B4 apt-get check fails on B"; fi
        out="$(ci_split_chroot "$BCH" dpkg --audit 2>&1)"
        if [[ -z "$out" ]]; then t_pass "B4 dpkg --audit has nothing to report"; else t_fail "B4 dpkg --audit: $(printf '%s' "$out" | head -n 3 | tr '\n' '|')"; fi
        out="$(ci_split_chroot "$BCH" dpkg-query -W -f='${db:Status-Status}' casper 2>/dev/null || true)"
        if [[ "$out" != installed ]]; then t_pass "B4 dpkg-query: casper is not installed in B (${out:-unknown to dpkg})"; else t_fail "B4 dpkg-query says casper is installed in B"; fi
        if ci_split_chroot "$BCH" sh -c 'd="$(mktemp -d)" && glib-compile-schemas --targetdir="$d" /usr/share/glib-2.0/schemas && cmp -s "$d/gschemas.compiled" /usr/share/glib-2.0/schemas/gschemas.compiled'; then
            t_pass "B4 gschemas.compiled is exactly what B's schemas and overrides compile to"; else t_fail "B4 gschemas.compiled is stale in B"; fi
        local a11y_b shell_b a11y_c shell_c
        a11y_b="$(ci_split_chroot "$BCH" env GSETTINGS_BACKEND=memory gsettings get org.gnome.desktop.a11y always-show-universal-access-status 2>&1)"
        shell_b="$(ci_split_chroot "$BCH" env GSETTINGS_BACKEND=memory gsettings get org.gnome.shell disabled-extensions 2>&1)"
        if [[ "$a11y_b" == false && "$shell_b" != *ding@rastersoft.com* ]]; then t_pass "B4 gsettings in B: the live session's overrides are gone (always-show-universal-access-status=$a11y_b, disabled-extensions=$shell_b)"; else t_fail "B4 gsettings in B still show the live overrides ($a11y_b / $shell_b)"; fi
        a11y_c="$(chroot "$B_C" /usr/bin/env -i PATH=/usr/bin:/bin GSETTINGS_BACKEND=memory gsettings get org.gnome.desktop.a11y always-show-universal-access-status 2>&1)"
        shell_c="$(chroot "$B_C" /usr/bin/env -i PATH=/usr/bin:/bin GSETTINGS_BACKEND=memory gsettings get org.gnome.shell disabled-extensions 2>&1)"
        if [[ "$a11y_c" == true && "$shell_c" == *ding@rastersoft.com* ]]; then t_pass "B4 control: the unsplit rootfs shows the overrides (true / $shell_c), so the probe can see them"; else t_fail "B4 control: the unsplit rootfs does not show the overrides ($a11y_c / $shell_c)"; fi
    else
        t_fail "B4 cannot open a chroot on B"
    fi
    ci_split_cleanup
    return "$GROUP_FAIL"
}

# ── B6: sizes and manifests ─────────────────────────────────────────────────────────────────────────────────────────
b_size_bounds() { # the formula of verify-iso.sh layer_size_bounds: "lo hi" from an unsquashfs -ll listing
    awk '{ t = substr($1, 1, 1)
           if (t == "-") { app += $3; blk += int(($3 + 4095) / 4096) * 4096 } else other++ }
         END { printf "%.0f %.0f\n", app * 0.8, (blk + other * 4096) * 1.2 + 1048576 }' "$1"
}
b_manifest_pkgs() { # the verify-iso.sh manifest_pkgs reading of a layer manifest
    sed -n 's/^+\([^+].*\)$/\1/p' "$1" 2>/dev/null | grep -v '^snap:' | awk -F'\t' '{ n = $1; sub(/:[^:]*$/, "", n); print n "\t" $2 }' | LC_ALL=C sort -u
}
b_status_pkgs() { # the verify-iso.sh status_pkgs
    awk 'BEGIN{RS=""; FS="\n"} { n = ""; v = ""; ok = 0
             for (i = 1; i <= NF; i++) { if ($i ~ /^Package: /) n = substr($i, 10); else if ($i ~ /^Version: /) v = substr($i, 10); else if ($i == "Status: install ok installed") ok = 1 }
             if (ok && n != "") print n "\t" v }' "$1" 2>/dev/null | LC_ALL=C sort -u
}
g_b_meta() {
    local cd="$B_WORK/casper" l f size lo hi sz
    [[ "$B_SPLIT_RC" -eq 0 && -s "$B_RES/sizes" ]] || { t_skip "B6 needs the split and its verification"; return 0; }
    rm -rf "$cd"; mkdir -p "$cd"
    if ci_split_write_metadata "$cd" "$B_RES" >/dev/null 2>&1; then t_pass "B6 the .size and .manifest files are written"; else t_fail "B6 ci_split_write_metadata failed"; return 1; fi
    local tmp="$B_WORK/meta"; rm -rf "$tmp"; mkdir -p "$tmp"
    for l in minimal minimal.standard minimal.standard.live; do
        case "$l" in minimal) f="$B_OUT/minimal.squashfs" ;; minimal.standard) f="$B_OUT/minimal.standard.squashfs" ;; *) f="$B_OUT/minimal.standard.live.squashfs" ;; esac
        unsquashfs -ll "$f" 2>/dev/null | sed 's#squashfs-root##' > "$tmp/$l.ll"
        size="$(tr -d '[:space:]' < "$cd/$l.size")"
        read -r lo hi < <(b_size_bounds "$tmp/$l.ll")
        if [[ "$size" =~ ^[0-9]+$ ]] && ((size >= lo && size <= hi)); then t_pass "B6 $l.size ($size) passes verify-iso.sh's plausibility range ($lo to $hi)"; else t_fail "B6 $l.size ($size) is outside verify-iso.sh's plausibility range ($lo to $hi)"; fi
    done
    sz="$(tr -d '[:space:]' < "$cd/minimal.size")"
    if [[ "$sz" == "$(awk '$1 == "base" {print $2}' "$B_RES/sizes")" ]]; then t_pass "B6 minimal.size is the measured size of B ($sz bytes)"; else t_fail "B6 minimal.size is not the measured size of B"; fi
    if [[ "$(cat "$cd/minimal.standard.size")" == 0 ]]; then t_pass "B6 minimal.standard.size is 0 (the empty placeholder)"; else t_fail "B6 minimal.standard.size is not 0"; fi
    if [[ "$(cat "$cd/filesystem.size")" == "$(awk '$1 == "total" {print $2}' "$B_RES/sizes")" && "$(cat "$cd/filesystem.size")" -ge "$sz" ]]; then t_pass "B6 filesystem.size is the whole live stack's measured size ($(cat "$cd/filesystem.size") bytes)"; else t_fail "B6 filesystem.size is not the live stack's measured size"; fi
    # the manifests against the dpkg status of the layers
    b_status_pkgs "$B_C/var/lib/dpkg/status" > "$tmp/live.status"
    # B's status: from the packed layer
    mkdir -p "$tmp/bmnt"; b_mount "$B_OUT/minimal.squashfs" "$tmp/bmnt" || { t_fail "B6 cannot mount B"; return 1; }
    b_status_pkgs "$tmp/bmnt/var/lib/dpkg/status" > "$tmp/base.status"
    ci_split_cleanup
    b_manifest_pkgs "$cd/minimal.manifest" > "$tmp/minimal.pk"
    if cmp -s "$tmp/minimal.pk" "$tmp/base.status"; then t_pass "B6 minimal.manifest lists exactly the packages of B ($(wc -l < "$tmp/base.status" | tr -d ' '))"; else t_fail "B6 minimal.manifest is not B's package list ($(LC_ALL=C comm -3 "$tmp/minimal.pk" "$tmp/base.status" | wc -l | tr -d ' ') lines differ)"; fi
    if [[ -z "$(b_manifest_pkgs "$cd/minimal.standard.manifest")" ]]; then t_pass "B6 minimal.standard.manifest lists no package (the layer is empty)"; else t_fail "B6 minimal.standard.manifest lists packages"; fi
    LC_ALL=C comm -13 "$tmp/base.status" "$tmp/live.status" > "$tmp/delta"
    b_manifest_pkgs "$cd/minimal.standard.live.manifest" > "$tmp/live.pk"
    if cmp -s "$tmp/live.pk" "$tmp/delta" && [[ -s "$tmp/delta" ]]; then t_pass "B6 minimal.standard.live.manifest lists exactly what the live layer adds to B ($(wc -l < "$tmp/delta" | tr -d ' ') packages: $(cut -f1 "$tmp/delta" | tr '\n' ' '))"; else t_fail "B6 minimal.standard.live.manifest is not the live delta"; fi
    if awk -F'\t' '$1 == "casper" {f = 1} END {exit !f}' "$tmp/live.pk" && ! awk -F'\t' '$1 == "casper" {f = 1} END {exit !f}' "$tmp/minimal.pk"; then t_pass "B6 casper is in the live manifest and not in the base one"; else t_fail "B6 casper is not where the manifests should have it"; fi
    if grep -q "$(printf '^+snap:core22\t')" "$cd/minimal.standard.live.manifest" && grep -q "$(printf '^+snap:ubuntu-desktop-bootstrap\t')" "$cd/minimal.standard.live.manifest" && ! grep -q 'ubuntu-desktop-bootstrap' "$cd/minimal.manifest"; then
        t_pass "B6 the installer snaps are in the live manifest, not in the base one"; else t_fail "B6 the installer snaps are not where the manifests should have them"; fi
    if [[ "$(sed -n 1p "$cd/minimal.standard.live.manifest")" == "--- /build/livecd.ubuntu.minimal.standard.manifest.full"* ]]; then t_pass "B6 the manifests have the stock diff header"; else t_fail "B6 the live manifest has no stock diff header"; fi
    return "$GROUP_FAIL"
}

# ── B7: the bug itself ──────────────────────────────────────────────────────────────────────────────────────────────
b_initrd_probe() { # b_initrd_probe <name> <lowerdir>: regenerates the initrd of the first kernel; prints casper findings
    local name="$1" lower="$2" ver t0 main hits scripts conf
    b_chroot_open "$name" "$lower" || { echo "no-chroot"; return 1; }
    ver="$(ls "$BCH"/boot/vmlinuz-*-generic 2>/dev/null | head -n 1 | sed 's#.*/vmlinuz-##')"
    [[ -n "$ver" ]] || { echo "no-kernel"; return 1; }
    t0=$SECONDS
    ci_split_chroot "$BCH" update-initramfs -c -k "$ver" >"$B_WORK/initrd-$name.log" 2>&1 || { echo "update-initramfs-failed: $(tail -n 3 "$B_WORK/initrd-$name.log" | tr '\n' '|')"; return 1; }
    unmkinitramfs "$BCH/boot/initrd.img-$ver" "$BCHX" >/dev/null 2>&1 || { echo "unmkinitramfs-failed"; return 1; }
    main="$BCHX/main"; [[ -d "$main" ]] || main="$BCHX"
    scripts="$(find "$main/scripts" -maxdepth 1 -iname 'casper*' 2>/dev/null | wc -l | tr -d ' ')"
    conf="$(ls "$main/conf/conf.d" 2>/dev/null | tr '\n' ' ')"
    hits="$(grep -rl 'BOOT=casper' "$main/conf" "$main/scripts" 2>/dev/null | wc -l | tr -d ' ')"
    [[ -f "$main/init" && -d "$main/scripts/local-top" ]] || { echo "initrd-looks-wrong"; return 1; }
    echo "kernel=$ver took=$((SECONDS - t0))s size=$(stat -c%s "$BCH/boot/initrd.img-$ver") casper-script-dirs=$scripts BOOT=casper-files=$hits conf.d=[${conf% }]"
}
g_b_initrd() {
    local r_ctl r_b
    if [[ "${SPLIT_TEST_INITRD:-1}" == 0 ]]; then t_skip "B7 initrd probes (SPLIT_TEST_INITRD=0)"; return 0; fi
    [[ "$B_SPLIT_RC" -eq 0 ]] || { t_skip "B7 needs the split"; return 0; }
    mkdir -p "$B_WORK/mnt/b7"
    r_ctl="$(b_initrd_probe control "$B_C")"; ci_split_cleanup
    t_info "B7 control, the unsplit rootfs: $r_ctl"
    if [[ "$r_ctl" == *casper-script-dirs=[1-9]* && "$r_ctl" == *BOOT=casper-files=[1-9]* && "$r_ctl" == *default-boot-to-casper.conf* ]]; then
        t_pass "B7 control: an initrd regenerated on the unsplit rootfs has casper's scripts and default-boot-to-casper.conf (the defect is visible to this probe)"
    else t_fail "B7 control: the unsplit rootfs's regenerated initrd does not show the defect ($r_ctl)"; fi
    b_mount "$B_OUT/minimal.squashfs" "$B_WORK/mnt/b7" || { t_fail "B7 cannot mount B"; return 1; }
    r_b="$(b_initrd_probe base "$B_WORK/mnt/b7")"; ci_split_cleanup
    t_info "B7 the split base layer B: $r_b"
    if [[ "$r_b" == *casper-script-dirs=0* && "$r_b" == *BOOT=casper-files=0* && "$r_b" != *default-boot-to-casper.conf* && "$r_b" != *casperize.conf* && "$r_b" != *default-layer.conf* ]]; then
        t_pass "B7 an initrd regenerated on B has no casper scripts, no default-boot-to-casper.conf and no BOOT=casper"
    else t_fail "B7 the initrd regenerated on B still carries casper ($r_b)"; fi
    return "$GROUP_FAIL"
}

# ── B8: mutation proof on the real data ─────────────────────────────────────────────────────────────────────────────
# b_mut_run <name> <stage: split|verify> <extended regex the refusal must match> <awk program that breaks the library, or "" for the
#           library as it is> [<rootfs to split instead of the real one>]
# Runs the whole split (and, for the verify stage, the verification) with a broken copy of the library in a separate shell. The
# build-time checks must refuse it: the shell exits with 11 (the split refused) or 12 (the verification refused), and the log
# has an [ERROR] line and a line matching the regex that is not an [INFO] line.
b_mut_run() {
    local name="$1" stage="$2" pat="$3" prog="$4" rootfs="${5:-$B_C}" rc=0 want=11 evidence
    local lib="$B_WORK/mut-$name.sh" res="$B_WORK/mut-res-$name" out="$B_WORK/mut-out-$name" log="$B_WORK/mut-$name.log"
    if [[ -n "$prog" ]]; then
        awk "$prog" "$LIB" > "$lib"
        if cmp -s "$lib" "$LIB"; then t_fail "B8 mutation '$name' changed nothing"; return; fi
    else
        cp "$LIB" "$lib"
    fi
    rm -rf "$res" "$out"; mkdir -p "$res" "$out"
    SPLIT_MUT_LIB="$lib" SPLIT_MUT_C="$rootfs" SPLIT_MUT_STOCK="$B_STOCK" SPLIT_MUT_RES="$res" SPLIT_MUT_OUT="$out" SPLIT_MUT_BUILD="$BUILD" \
    CI_SPLIT_MKSQUASHFS_OPTS="$B_COMP" CI_SPLIT_VERIFY=quick bash -c '
        set -uo pipefail
        source "$SPLIT_MUT_BUILD"; set +e; set -u
        source "$SPLIT_MUT_LIB"
        ci_split_live_layer "$SPLIT_MUT_C" "$SPLIT_MUT_OUT/minimal.squashfs" "$SPLIT_MUT_OUT/minimal.standard.live.squashfs" "$SPLIT_MUT_RES" "$SPLIT_MUT_STOCK" || exit 11
        ph="$(mktemp -d)"; make_placeholder_layer "$SPLIT_MUT_C" "$ph"; mksquashfs "$ph" "$SPLIT_MUT_OUT/minimal.standard.squashfs" -comp xz -noappend -no-recovery -quiet >/dev/null 2>&1; rm -rf "$ph"
        ci_split_verify_layers "$SPLIT_MUT_C" "$SPLIT_MUT_OUT/minimal.squashfs" "$SPLIT_MUT_OUT/minimal.standard.squashfs" "$SPLIT_MUT_OUT/minimal.standard.live.squashfs" "$SPLIT_MUT_RES" || exit 12
        exit 0' > "$log" 2>&1 || rc=$?
    rm -rf "$out"
    if [[ "$rc" -eq 0 ]]; then t_fail "B8 mutation '$name' SURVIVED: the split and its verification accepted a broken library or rootfs"; return; fi
    [[ "$stage" == verify ]] && want=12
    sed 's/\x1b\[[0-9;]*m//g' "$log" > "$log.plain"
    evidence="$(grep -v -F '[INFO]' "$log.plain" | grep -E -- "$pat" | head -n 1 | cut -c1-170)"
    if [[ "$rc" -eq "$want" && -n "$evidence" ]] && grep -q -F '[ERROR]' "$log.plain"; then
        t_pass "B8 mutation '$name': refused at the $stage stage (exit $rc): $evidence"
    else
        t_fail "B8 mutation '$name': exit $rc (expected $want) and no refusal matching /$pat/ in the log: $(grep -F '[ERROR]' "$log.plain" | head -n 2 | tr '\n' '|')"
    fi
}
g_b_mut() {
    if [[ "${SPLIT_TEST_MUTATIONS:-1}" == 0 ]]; then t_skip "B8 mutation proof (SPLIT_TEST_MUTATIONS=0)"; return 0; fi
    ci_split_cleanup
    # 1. the removal table has no casper row at all: the base would carry the package and its hook
    b_mut_run no-casper-row split 'live-only path in the base|package casper is in the base|casper' \
        '$0 == "purge|casper finalrd" { next } { print }'
    # 1b. the row names finalrd only: dpkg itself refuses to leave casper without its dependency
    b_mut_run casper-kept-finalrd-purged split 'casper depends on finalrd|dependency problems' \
        '$0 == "purge|casper finalrd" { print "purge|finalrd"; next } { print }'
    # 2. the stock snapd state is not restored: state.json would still know the installer snap
    b_mut_run no-snapd-restore split 'state\.json still names the installer snap|seed\.yaml still names the installer snap' \
        '$0 == "restore|var/lib/snapd/state.json" || $0 == "restore|var/lib/snapd/seed/seed.yaml" { next } { print }'
    # 3. the installer snaps are not swept
    b_mut_run no-installer-snap-sweep split 'installer snap [a-z0-9-]+ left in the base|installer snap [a-z0-9-]+ has systemd units' \
        '$0 == "installer-snaps|" { next } { print }'
    # 4. the live cloud.cfg is not restored
    b_mut_run no-cloud-restore split 'cloud\.cfg is the live session' \
        '$0 == "restore|etc/cloud/cloud.cfg" { next } { print }'
    # 5. the derivation of L loses one file: B and L are fine on their own, the stack is not the rootfs
    b_mut_run l-loses-a-file verify 'overlay\(B \+ placeholder \+ L\) is NOT the rootfs' \
        '{ if (index($0, "rsync -aAX \"--filter=-x trusted.overlay.*\" --numeric-ids --from0 --files-from=\"$copy\"") > 0) sub(/--from0/, "--exclude=/var/lib/dpkg/status --from0"); print }'
    # 6. the derivation forgets what the removal deleted: L would not carry casper
    b_mut_run l-loses-casper-files verify 'live layer lacks|overlay\(B \+ placeholder \+ L\) is NOT the rootfs' \
        '{ i = index($0, "if [[ -e \"$c\" || -L \"$c\" ]]; then ci_split_emit_subtree \"$C\" \"$rel\" >> \"$copy\"; fi"); if (i > 0) $0 = substr($0, 1, i - 1) ":"; print }'
    # 7. the guard of the restore rows, on the real rootfs and the real stock layers: a build step that edited /etc/cloud/cloud.cfg (the
    #    live session's copy is the stock live layer's, and the restore would put the stock standard copy back over the edit)
    local cz="$B_WORK/customized"
    rm -rf "$cz"; mkdir -p "$cz/up/etc/cloud" "$cz/m"
    chmod --reference="$B_C/etc" "$cz/up/etc"; chown --reference="$B_C/etc" "$cz/up/etc"
    chmod --reference="$B_C/etc/cloud" "$cz/up/etc/cloud"; chown --reference="$B_C/etc/cloud" "$cz/up/etc/cloud"
    { cat "$B_C/etc/cloud/cloud.cfg"; printf '# edited by a build step\n'; } > "$cz/up/etc/cloud/cloud.cfg"
    chmod --reference="$B_C/etc/cloud/cloud.cfg" "$cz/up/etc/cloud/cloud.cfg"; chown --reference="$B_C/etc/cloud/cloud.cfg" "$cz/up/etc/cloud/cloud.cfg"
    if ci_split_overlay_mount "$cz/up:$B_C" "$cz/m"; then
        b_mut_run customized-cloud-cfg split "restore\\|etc/cloud/cloud\\.cfg.*customized" "" "$cz/m"
        ci_split_cleanup
    else
        t_fail "B8 cannot mount the read-only overlay of the rootfs with an edited cloud.cfg"
    fi
    return "$GROUP_FAIL"
}

# ── B9: build-iso.sh's own repack_squashfs, end to end ──────────────────────────────────────────────────────────────
# The real function on the saved work data: a WORK_DIR whose chroot is the (read-only) merged rootfs, whose squashfs directory holds the
# stock layers, and whose custom-iso/casper holds stand-ins for what the stock casper directory has (the layers and metadata the function
# replaces, language layers it drops, files it must leave alone). Run under `set -euo pipefail` like build-iso.sh itself.
B_REPACK="$B_WORK/repack"
g_b_repack() {
    local w="$B_REPACK" cd f rc=0 log="$B_WORK/repack.log" t0=$SECONDS
    local base live total n_sq n_sum m
    rm -rf "$w"; mkdir -p "$w/custom-iso/casper" "$w/squashfs"
    ln -s "$B_C" "$w/chroot"
    for f in "$B_STOCK"/*.squashfs; do [[ -e "$f" ]] && ln -s "$f" "$w/squashfs/${f##*/}"; done
    cd="$w/custom-iso/casper"
    for f in minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs minimal.de.squashfs minimal.standard.fr.squashfs \
             minimal.no-languages.squashfs minimal.de.size minimal.standard.fr.manifest minimal.size minimal.standard.size minimal.standard.live.size \
             minimal.manifest minimal.standard.manifest minimal.standard.live.manifest SHA256SUMS SHA256SUMS.gpg install-sources.yaml filesystem.size \
             vmlinuz initrd; do
        printf 'stock %s\n' "$f" > "$cd/$f"
    done
    dpkg-query --admindir="$B_C/var/lib/dpkg" -W --showformat='${Package} ${Version}\n' > "$cd/filesystem.manifest"
    # (WORK_DIR and the functions are build-iso.sh's; CI_SPLIT_MKSQUASHFS_OPTS, the fast compressor, is the library's)
    (   set -euo pipefail
        # shellcheck disable=SC2034
        WORK_DIR="$w"
        repack_squashfs
        case "$-" in *e*) echo "ERREXIT-ON-AFTER-REPACK" ;; *) echo "ERREXIT-OFF-AFTER-REPACK" ;; esac
    ) > "$log" 2>&1 || rc=$?
    sed -i 's/\x1b\[[0-9;]*m//g' "$log"
    t_info "B9 repack_squashfs took $((SECONDS - t0)) s (exit $rc)"
    if [[ "$rc" -eq 0 ]]; then t_pass "B9 repack_squashfs succeeds on the real rootfs and the stock layers"; else t_fail "B9 repack_squashfs failed (rc=$rc): $(tail -n 6 "$log" | tr '\n' '|')"; return 1; fi
    if grep -q '^ERREXIT-ON-AFTER-REPACK$' "$log"; then t_pass "B9 errexit is still on after repack_squashfs (the rest of the build still aborts on a failure)"; else t_fail "B9 repack_squashfs switched the caller's errexit off"; fi
    for f in minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs; do
        if [[ -s "$cd/$f" ]] && ! grep -q '^stock ' "$cd/$f" 2>/dev/null; then t_pass "B9 casper/$f is a new squashfs ($(stat -c%s "$cd/$f") bytes)"; else t_fail "B9 casper/$f is missing or still the stand-in for the stock one"; fi
    done
    if ls "$cd"/minimal.de.* "$cd"/minimal.standard.fr.* "$cd"/minimal.no-languages.* >/dev/null 2>&1; then t_fail "B9 stock language layers are still in casper/"; else t_pass "B9 the stock language layers, with their .size and .manifest files, are gone"; fi
    if [[ "$(cat "$cd/vmlinuz")" == "stock vmlinuz" && "$(cat "$cd/initrd")" == "stock initrd" ]]; then t_pass "B9 files the function must leave alone (vmlinuz, initrd) are untouched"; else t_fail "B9 vmlinuz or initrd was changed"; fi
    if [[ ! -e "$cd/SHA256SUMS.gpg" ]]; then t_pass "B9 the stale SHA256SUMS.gpg is removed"; else t_fail "B9 SHA256SUMS.gpg is still there"; fi
    n_sq="$(ls "$cd"/*.squashfs | wc -l | tr -d ' ')"; n_sum="$(wc -l < "$cd/SHA256SUMS" | tr -d ' ')"
    if [[ "$n_sq" == 3 && "$n_sum" == 3 ]] && (cd "$cd" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then t_pass "B9 SHA256SUMS lists exactly the 3 layers and every checksum is right"; else t_fail "B9 SHA256SUMS: $n_sum entries for $n_sq layers, or a wrong checksum"; fi
    # sizes: the .size files are the measured sizes of the mounted layers
    mkdir -p "$w/mnt/b" "$w/mnt/l"
    if b_mount "$cd/minimal.squashfs" "$w/mnt/b" && b_mount "$cd/minimal.standard.live.squashfs" "$w/mnt/l"; then
        base="$(du -sx --block-size=1 "$w/mnt/b" | cut -f1)"; live="$(du -sx --block-size=1 "$w/mnt/l" | cut -f1)"
        total="$(tr -d '[:space:]' < "$cd/filesystem.size")"
        if [[ "$(tr -d '[:space:]' < "$cd/minimal.size")" == "$base" ]]; then t_pass "B9 minimal.size is the measured size of the installed base ($base bytes)"; else t_fail "B9 minimal.size ($(cat "$cd/minimal.size")) is not the base layer's size ($base)"; fi
        if [[ "$(tr -d '[:space:]' < "$cd/minimal.standard.live.size")" == "$live" && "$live" -gt 1000000 ]]; then t_pass "B9 minimal.standard.live.size is the measured size of the live layer ($live bytes; not 0)"; else t_fail "B9 minimal.standard.live.size ($(cat "$cd/minimal.standard.live.size")) is not the live layer's size ($live)"; fi
        if [[ "$(tr -d '[:space:]' < "$cd/minimal.standard.size")" == 0 ]]; then t_pass "B9 minimal.standard.size is 0 (the empty placeholder)"; else t_fail "B9 minimal.standard.size is not 0"; fi
        if [[ "$total" =~ ^[0-9]+$ && "$total" -gt "$base" && "$total" -le $((base + live)) ]]; then t_pass "B9 filesystem.size ($total) is the live stack's: more than the base ($base), not more than base + live"; else t_fail "B9 filesystem.size ($total) is not between the base ($base) and base + live ($((base + live)))"; fi
        # install-sources.yaml: the installer's size is the installed (base) size, both entries, no language layers, no enhanced-secureboot
        m="$cd/install-sources.yaml"
        if [[ "$(grep -c "^  size: $base\$" "$m")" == 2 ]]; then t_pass "B9 install-sources.yaml: both entries carry the installed size of the base layer ($base)"; else t_fail "B9 install-sources.yaml: the entries' size is not $base: $(grep -E '^  size:' "$m" | tr '\n' ' ')"; fi
        if [[ "$(grep -c '^  preinstalled_langs: \[\]$' "$m")" == 2 && "$(grep -c '^  id: ' "$m")" == 2 ]] && ! grep -q enhanced-secureboot "$m"; then t_pass "B9 install-sources.yaml: both entries, preinstalled_langs [], no enhanced-secureboot"; else t_fail "B9 install-sources.yaml has the wrong shape"; fi
        if [[ "$(sed -n 's/^ *path: *//p' "$m" | sort -u | tr '\n' ' ')" == "minimal.squashfs minimal.standard.squashfs " && "$(grep -c '^      size: '"$(stat -c%s "$cd/minimal.squashfs")"'$' "$m")" == 2 ]]; then
            t_pass "B9 install-sources.yaml: the installer installs minimal.squashfs (file size $(stat -c%s "$cd/minimal.squashfs")) and the empty standard placeholder, nothing else"
        else t_fail "B9 install-sources.yaml names other layers or the wrong file size"; fi
    else
        t_fail "B9 cannot mount the new layers"
    fi
    ci_split_cleanup
    # manifests: the stock diff shape and the packages (the exact set is B6's job; here: the files are the function's, not the stand-ins)
    for f in minimal.manifest minimal.standard.manifest minimal.standard.live.manifest; do
        if [[ "$(sed -n 1p "$cd/$f")" == "--- /build/livecd.ubuntu."* ]]; then t_pass "B9 casper/$f is written by the split (stock diff shape)"; else t_fail "B9 casper/$f is still the stand-in"; fi
    done
    if grep -q -E '^\+casper	' "$cd/minimal.standard.live.manifest" && ! grep -q -E '^\+casper	' "$cd/minimal.manifest"; then t_pass "B9 casper is in the live manifest, not in the base one"; else t_fail "B9 casper is not where the manifests should have it"; fi
    if [[ "$(sed 's/ .*//' "$cd/filesystem.manifest" | grep -c -x casper)" == 1 ]]; then t_pass "B9 filesystem.manifest (the live system's packages) still lists casper"; else t_fail "B9 filesystem.manifest lost casper"; fi
    # the log lines the maintainer reads
    if grep -q 'split: overlay(B + placeholder + L) == rootfs' "$log" && grep -q 'Layer sizes (du): installed base [0-9]* bytes, live-only layer [0-9]* bytes, whole live stack [0-9]* bytes' "$log" \
       && grep -q 'Layer files: minimal.squashfs [0-9]* bytes, minimal.standard.live.squashfs [0-9]* bytes' "$log" && grep -q 'Squashfs repacked successfully' "$log"; then
        t_pass "B9 the log says what was verified and shows the sizes of B and L"
        grep -E 'Layer (sizes|files)|split: (base layer|packed)' "$log" | while IFS= read -r l; do t_info "B9 $l"; done
    else t_fail "B9 the log lacks the verification or size lines: $(grep -c . "$log") lines"; fi
    if [[ ! -e "$w/split-result" ]]; then t_pass "B9 the scratch directory of the split is removed"; else t_fail "B9 split-result is still there"; fi
    if grep -q -F -- " $w/" /proc/self/mountinfo 2>/dev/null; then t_fail "B9 a mount is left below $w"; else t_pass "B9 no mount is left behind"; fi
    return "$GROUP_FAIL"
}

# ── B10: the casper directory of B9 in an ISO, and verify-iso.sh on it ──────────────────────────────────────────────
# verify-iso.sh (section 3d: the installer's sources, 3e: directory modes of the upper layers, 3g: the installer base is clean, the live layer is
# real, .size and .manifest are true) and the library keep separate lists on purpose. This is the proof that they agree on a real image: a small ISO
# with the boot files of the v7 ISO and the layers B9 wrote. The other sections fail on such a small image by design and are not read.
g_b_miniiso() {
    local iso="${SPLIT_TEST_ISO:-}" w="$B_REPACK" t="$B_WORK/mini" tool out sec n_pass n_fail verify="$HERE/../scripts/verify-iso.sh"
    if [[ -z "$iso" ]]; then t_skip "B10 verify-iso.sh on the split layers: set SPLIT_TEST_ISO to the v7 ISO (its boot files go into the small image)"; return 0; fi
    [[ -f "$iso" ]] || { t_skip "B10 SPLIT_TEST_ISO=$iso does not exist"; return 0; }
    for tool in xorriso python3 unsquashfs zstd cpio; do command -v "$tool" >/dev/null 2>&1 || { t_skip "B10 needs $tool"; return 0; }; done
    [[ -s "$w/custom-iso/casper/minimal.squashfs" ]] || { t_skip "B10 needs the casper directory of B9"; return 0; }
    rm -rf "$t"; mkdir -p "$t/tree/boot/grub" "$t/tree/.disk" "$t/tree/EFI/boot" "$t/tree/casper"
    xorriso -osirrox on -indev "$iso" \
        -extract /boot/grub/grub.cfg "$t/tree/boot/grub/grub.cfg" -extract /boot/grub/loopback.cfg "$t/tree/boot/grub/loopback.cfg" \
        -extract /boot/grub/ci-os-bg.png "$t/tree/boot/grub/ci-os-bg.png" -extract /.disk/info "$t/tree/.disk/info" \
        -extract /EFI/boot/bootx64.efi "$t/tree/EFI/boot/bootx64.efi" -extract /EFI/boot/grubx64.efi "$t/tree/EFI/boot/grubx64.efi" \
        -extract /EFI/boot/mmx64.efi "$t/tree/EFI/boot/mmx64.efi" -extract /casper/initrd "$t/tree/casper/initrd" \
        -extract /casper/vmlinuz "$t/tree/casper/vmlinuz" >/dev/null 2>&1
    for tool in "$w"/custom-iso/casper/*; do [[ "${tool##*/}" == initrd || "${tool##*/}" == vmlinuz ]] || ln -s "$tool" "$t/tree/casper/${tool##*/}"; done
    # (-f: follow the symlinks, so the 5 GB of layers are not copied; -iso-level 3: a file of more than 4 GiB)
    if ! xorriso -as mkisofs -r -f -iso-level 3 -V "Ubuntu 24.04.5 LTS amd64" -o "$t/mini.iso" "$t/tree" >"$t/xorriso.log" 2>&1; then t_fail "B10 cannot build the small ISO: $(tail -n 3 "$t/xorriso.log" | tr '\n' '|')"; return 1; fi
    t_info "B10 small ISO: $(stat -c%s "$t/mini.iso") bytes"
    VERIFY_WORK="$t/vw" bash "$verify" "$t/mini.iso" > "$t/verify.out" 2>&1
    for sec in 3d 3e 3g; do
        out="$(sed -n "/^== $sec\./,/^== [0-9]/p" "$t/verify.out" | sed '$d')"
        # One known disagreement, named here so that it cannot hide anything else: the finalrd row of verify-iso.sh's BASE_FORBIDDEN matches
        # every path below /usr/share/finalrd, and /usr/share/finalrd/mdadm.finalrd belongs to mdadm, a package the base keeps (the design
        # keeps the disk tools). The file is inert without finalrd. While verify-iso.sh has the broad pattern, that one FAIL line (and only it)
        # is reported as information; when the row is narrowed, nothing matches here and the section simply passes.
        known="$(printf '%s\n' "$out" | grep -E '^FAIL  base layer ships finalrd .*: /usr/share/finalrd /usr/share/finalrd/mdadm\.finalrd *$' || true)"
        if [[ -n "$known" ]]; then
            t_info "B10 KNOWN: verify-iso.sh flags mdadm's own /usr/share/finalrd/mdadm.finalrd as finalrd content (its pattern ^/usr/(lib|share)/finalrd is too broad; mdadm stays in the base): not counted"
            out="$(printf '%s\n' "$out" | grep -v -F -x -- "$known" || true)"
        fi
        n_pass="$(printf '%s\n' "$out" | grep -c '^PASS' || true)"; n_fail="$(printf '%s\n' "$out" | grep -c '^FAIL' || true)"
        if [[ "$n_pass" -gt 0 && "$n_fail" -eq 0 ]]; then t_pass "B10 verify-iso.sh section $sec on the split layers: $n_pass checks pass, none fails"
        else t_fail "B10 verify-iso.sh section $sec: $n_pass pass, $n_fail fail: $(printf '%s\n' "$out" | grep '^FAIL' | head -n 4 | cut -c1-160 | tr '\n' '|')"; fi
    done
    out="$(grep -E '^(PASS|FAIL)  .*(casper\.conf|USERGROUPS)' "$t/verify.out" || true)"
    if [[ -n "$out" ]] && ! printf '%s\n' "$out" | grep -q '^FAIL'; then t_pass "B10 the checks that read casper.conf follow it into the live layer ($(printf '%s\n' "$out" | grep -c '^PASS') pass)"
    else t_fail "B10 the casper.conf checks of verify-iso.sh: ${out:-none found}"; fi
    rm -rf "$t/vw"
    return "$GROUP_FAIL"
}

run_b() {
    local any=0 g
    for g in B1 B2 B7 B8 B9 B10; do wanted "$g" && any=1; done
    wanted B3 && any=1; wanted B4 && any=1; wanted B6 && any=1
    [[ "$any" -eq 1 ]] || return 0
    b_prepare || return 0
    t_info "Part B: rootfs $B_C, stock layers $B_STOCK, scratch $B_WORK"
    if wanted B1; then GROUP_FAIL=0; g_b_audit || true; fi
    if wanted B2 || wanted B3 || wanted B4 || wanted B6 || wanted B7; then
        GROUP_FAIL=0; g_b_split || true
        GROUP_FAIL=0; g_b_base || true
        GROUP_FAIL=0; g_b_meta || true
        GROUP_FAIL=0; g_b_initrd || true
    fi
    if wanted B8; then GROUP_FAIL=0; g_b_mut || true; fi
    if wanted B9 || wanted B10; then
        CI_SPLIT_MKSQUASHFS_OPTS="$B_COMP"
        GROUP_FAIL=0; g_b_repack || true
        if wanted B10; then GROUP_FAIL=0; g_b_miniiso || true; fi
        if [[ -z "${SPLIT_TEST_KEEP:-}" ]]; then rm -rf "$B_REPACK"; fi
    fi
    ci_split_cleanup
    if [[ -z "${SPLIT_TEST_KEEP:-}" && -z "${SPLIT_TEST_WORK:-}" ]]; then rm -rf "$B_WORK"; fi
}
run_b

printf '\n== Summary: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
