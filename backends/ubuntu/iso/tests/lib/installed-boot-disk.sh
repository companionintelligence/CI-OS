#!/usr/bin/env bash
#=============================================================================
# Build a throw-away bootable disk the way an installer leaves one, from the base layer the installer would install.
# Part of tests/installed-boot.sh: that script starts this one in a privileged Linux container and boots the result.
#
#   installed-boot-disk.sh --out DIR (--squashfs FILE... | --iso FILE | --chroot DIR) [options]
#
# Source (the "base layer"):
#   --squashfs FILE   a layer; repeat for a stack, bottom first (what curtin stacks with overlayfs)
#   --iso FILE        a built ISO: the layers of the default entry of casper/install-sources.yaml, exactly what the
#                     installer installs (minimal.squashfs, or minimal.standard.squashfs = minimal + minimal.standard)
#   --chroot DIR      an unpacked rootfs, used read-only (a stand-in for the layer, e.g. the build's merged chroot)
# The source is never written: it is the lower layer of an overlayfs whose upper layer is scratch space.
#
# What it does, in the order an install does it:
#   1  view      overlay of the source (read-only lower, scratch upper)
#   2  repair    only with --apply-repair: the minimal known fix, in the overlay (never in the source)
#   3  disk      sparse raw image, GPT, 512 MiB ESP (vfat) + ext4 root, root filled from the view
#   4  target    /etc/fstab (UUIDs), hostname, empty machine-id, a user (random password, see below)
#   5  initrd    update-initramfs -c -k all in a chroot (curtin does the same), then every initrd is parsed (initrd-audit.py) and checked
#   6  grub      grub-install --target=x86_64-efi --uefi-secure-boot (the shim path of a real install) + update-grub,
#                then the generated grub.cfg is checked: root=UUID=, nothing live
#   7  probe     a test-only systemd unit that reports the boot state on the serial console (conditional on ci.bootprobe)
# Every check goes to OUT/checks.txt as "PASS|FAIL|WARN|INFO <id> <text>"; a FAIL is a defect of the installed system.
#
# Options: --out DIR (required; bind-mounted from the host) --work DIR (scratch, default /work: use a Docker volume,
#   not the container's own filesystem) --disk-size SIZE|auto (default auto: the view's size + 15% + 3 GiB, sparse) --user NAME (default citest)
#   --kernels all|latest (default all) --apply-repair --emit-disk yes|no|auto (auto: only when no check FAILed)
#   --stop-after view|copy|initrd|grub (debugging) --keep (keep the scratch directory) --no-probe --quick
#   (the residue audit of the view and nothing else: the cheap check that names casper, a few seconds; no disk, no initramfs, no boot loader)
#
# The test user's password is random, written to OUT/guest-user (mode 600) and never printed.
#
# Needs root in a privileged container (mount -o loop, overlayfs, chroot), and: mount umount awk sed cp; for a disk also mkfs.ext4
# mkfs.vfat sfdisk e2fsck chroot truncate python3 zstd (a stock ubuntu image gets what is missing through apt-get, which needs network).
# Exit: 0 built (checks may still FAIL: read checks.txt), 2 cannot run here, 3 a build step failed.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

OUT="" WORKROOT=/work DISK_SIZE=auto USERNAME_T=citest KERNELS=all APPLY_REPAIR=0 EMIT=auto STOP_AFTER="" KEEP=0 PROBE=1 QUICK=0
MODE="" ISO="" CHROOT_SRC=""
SQUASHFS=()
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'installed-boot-disk: %s\n' "$*" >&2; exit 3; }
need() { # the wrapper prints need.txt as its reason (the container's own stderr is only in build.log)
    printf 'installed-boot-disk: cannot run here: %s\n' "$*" >&2
    if [[ -n "${OUT:-}" && -d "$OUT" ]]; then printf '%s\n' "$*" > "$OUT/need.txt"; fi
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --work) WORKROOT="$2"; shift 2 ;;
        --squashfs) SQUASHFS+=("$2"); MODE=squashfs; shift 2 ;;
        --iso) ISO="$2"; MODE=iso; shift 2 ;;
        --chroot) CHROOT_SRC="$2"; MODE=chroot; shift 2 ;;
        --disk-size) DISK_SIZE="$2"; shift 2 ;;
        --user) USERNAME_T="$2"; shift 2 ;;
        --kernels) KERNELS="$2"; shift 2 ;;
        --apply-repair) APPLY_REPAIR=1; shift ;;
        --emit-disk) EMIT="$2"; shift 2 ;;
        --stop-after) STOP_AFTER="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --no-probe) PROBE=0; shift ;;
        --quick) QUICK=1; shift ;;
        -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
[[ -n "$OUT" && -n "$MODE" ]] || die "--out and one of --squashfs/--iso/--chroot are required"
case "$KERNELS" in all|latest) ;; *) die "--kernels takes all or latest" ;; esac
case "$EMIT" in yes|no|auto) ;; *) die "--emit-disk takes yes, no or auto" ;; esac

[[ "$(id -u)" -eq 0 ]] || need "root is needed (loop devices, mount, chroot): run it in a privileged container"
TOOLS=(mount umount awk sed cp)
[[ "$MODE" != iso ]] || TOOLS+=(python3)
[[ "$APPLY_REPAIR" -eq 0 ]] || TOOLS+=(chroot)
[[ "$QUICK" -eq 1 ]] || TOOLS+=(mkfs.ext4 mkfs.vfat sfdisk e2fsck chroot truncate python3 zstd)   # --quick builds no disk
missing=()
for t in "${TOOLS[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if [[ ${#missing[@]} -gt 0 ]] && command -v apt-get >/dev/null 2>&1; then
    # A stock ubuntu image has no dosfstools, fdisk, zstd or python3: install what the build needs (network).
    printf 'installing missing tools with apt-get: %s\n' "${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    { apt-get update -qq && apt-get install -y -qq --no-install-recommends e2fsprogs dosfstools fdisk util-linux mount python3 zstd coreutils gawk sed; } >&2 || true
    missing=()
    for t in "${TOOLS[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
fi
[[ ${#missing[@]} -eq 0 ]] || need "missing tool(s): ${missing[*]}"
mkdir -p "$OUT"
: > "$OUT/timeline.txt"; : > "$OUT/checks.txt"

T0=$(date +%s)
phase() { printf 'T+%5ds  %s\n' "$(( $(date +%s) - T0 ))" "$*" | tee -a "$OUT/timeline.txt"; }
check() { printf '%s %s %s\n' "$1" "$2" "$3" | tee -a "$OUT/checks.txt"; }
fails() { grep -c '^FAIL ' "$OUT/checks.txt" || true; }

RUN="$WORKROOT/run.$$"
MOUNTS=()
cleanup() {
    local rc=$? i
    set +e
    # Every loop device here comes from `mount -o loop`, which sets autoclear: the device goes away with its mount, also when this
    # script is killed (the kernel unmounts a dead container's mounts). Nothing is ever attached with losetup.
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
        umount "${MOUNTS[$i]}" 2>/dev/null || { printf 'WARNING: lazy unmount of %s\n' "${MOUNTS[$i]}" >&2; umount -l "${MOUNTS[$i]}" 2>/dev/null; }
    done
    # Never remove anything while a mount is still under it (a bind-mounted /dev would be emptied).
    if [[ -d "$RUN" ]] && ! grep -q " $RUN" /proc/mounts; then
        if [[ "$KEEP" -eq 1 ]]; then printf 'kept scratch directory %s\n' "$RUN"; else rm -rf --one-file-system "$RUN"; fi
    elif [[ -d "$RUN" ]]; then
        printf 'WARNING: mounts remain under %s, not removing it\n' "$RUN" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT

# Docker Desktop's privileged containers often lack the /dev/loopN nodes (mount reports "device node /dev/loopN is lost"):
# make a generous set up front, and make more when mount names a missing one.
for n in $(seq 0 63); do [[ -e "/dev/loop$n" ]] || mknod "/dev/loop$n" b 7 "$n" 2>/dev/null || true; done
mnt() { # mnt <dir> <mount args...>: mount and remember
    local dir="$1"; shift
    local out n i
    mkdir -p "$dir"
    for i in 1 2 3 4 5 6 7 8; do
        if out="$(mount "$@" "$dir" 2>&1)"; then MOUNTS+=("$dir"); return 0; fi
        n="$(printf '%s' "$out" | sed -n 's#.*/dev/loop\([0-9][0-9]*\).*#\1#p' | head -1)"
        if [[ -n "$n" && ! -e "/dev/loop$n" ]]; then mknod "/dev/loop$n" b 7 "$n" 2>/dev/null || true; else break; fi
    done
    printf 'mount %s %s failed: %s\n' "$*" "$dir" "$out" >&2
    return 1
}

CHROOT_ENV=(env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive)
chroot_up() { # chroot_up <root>: the mounts a maintainer script expects (a private /run, never the host's)
    local r="$1"
    mnt "$r/dev" --bind /dev
    mnt "$r/dev/pts" -t devpts devpts
    mnt "$r/proc" -t proc proc
    mnt "$r/sys" -t sysfs sysfs
    mnt "$r/run" -t tmpfs -o mode=0755,nosuid,nodev tmpfs
}
chroot_down() { # chroot_down <root>: unmount what chroot_up mounted (and anything mounted since under those)
    local r="$1" i keep=() m
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
        m="${MOUNTS[$i]}"
        case "$m" in "$r/dev/pts"|"$r/dev"|"$r/proc"|"$r/sys"|"$r/run"|"$r/boot/efi") umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true ;; *) keep+=("$m") ;; esac
    done
    MOUNTS=()
    for ((i = ${#keep[@]} - 1; i >= 0; i--)); do MOUNTS+=("${keep[$i]}"); done
}
in_chroot() { local r="$1"; shift; chroot "$r" "${CHROOT_ENV[@]}" "$@"; }

# dpkg status without dpkg: the version of an installed package ("" when not installed). Works on any root directory.
pkg_version() { # pkg_version <root> <package>
    awk -v p="$2" 'BEGIN { RS = ""; FS = "\n" }
        { n = ""; s = ""; v = ""
          for (i = 1; i <= NF; i++) { if ($i ~ /^Package: /) n = substr($i, 10); else if ($i ~ /^Status: /) s = substr($i, 9); else if ($i ~ /^Version: /) v = substr($i, 10) }
          if (n == p && s ~ / installed$/) print v }' "$1/var/lib/dpkg/status" 2>/dev/null | head -1
}

# ── 1  the source view ───────────────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$RUN"/{up,wk,view,layers}
chmod 755 "$RUN"
LOWER=()   # top first, as overlayfs wants it
case "$MODE" in
    chroot)
        [[ -d "$CHROOT_SRC/etc" ]] || die "--chroot $CHROOT_SRC is not a root directory"
        LOWER=("$CHROOT_SRC")
        SRC_DESC="chroot $CHROOT_SRC"
        ;;
    squashfs)
        i=0
        for f in "${SQUASHFS[@]}"; do
            [[ -f "$f" ]] || die "no such layer: $f"
            mnt "$RUN/layers/$i" -t squashfs -o loop,ro "$f" || die "cannot mount the layer $f"
            LOWER=("$RUN/layers/$i" ${LOWER[@]+"${LOWER[@]}"})
            i=$((i + 1))
        done
        SRC_DESC="squashfs stack of ${#SQUASHFS[@]}: ${SQUASHFS[*]}"
        ;;
    iso)
        [[ -f "$ISO" ]] || die "no such ISO: $ISO"
        mnt "$RUN/iso" -t iso9660 -o loop,ro "$ISO" || die "cannot mount $ISO"
        [[ -f "$RUN/iso/casper/install-sources.yaml" ]] || die "the ISO has no casper/install-sources.yaml"
        # The default entry's path, and the layer stack curtin builds from it: a.b.squashfs = a.squashfs + a.b.squashfs.
        layer_list="$(python3 -I "$HERE/install-source-layers.py" "$RUN/iso/casper/install-sources.yaml")" \
            || die "cannot read the default install source of the ISO"
        i=0
        while IFS= read -r l; do
            [[ -n "$l" ]] || continue
            [[ -f "$RUN/iso/casper/$l" ]] || die "install-sources.yaml names casper/$l, which the ISO does not have"
            mnt "$RUN/layers/$i" -t squashfs -o loop,ro "$RUN/iso/casper/$l" || die "cannot mount casper/$l"
            LOWER=("$RUN/layers/$i" ${LOWER[@]+"${LOWER[@]}"})
            check INFO source-layer "the installer's layer $((i + 1)): casper/$l"
            i=$((i + 1))
        done <<<"$layer_list"
        SRC_DESC="ISO $ISO, default install source: $(printf '%s ' $layer_list)"
        ;;
esac
lowerdir="$(IFS=:; printf '%s' "${LOWER[*]}")"
mnt "$RUN/view" -t overlay overlay -o "lowerdir=$lowerdir,upperdir=$RUN/up,workdir=$RUN/wk"
VIEW="$RUN/view"
phase "view ready: $SRC_DESC"
check INFO source "$SRC_DESC"

# ── 2  the minimal repair (only to prove the test can pass; it changes the overlay, never the source) ─────────────────
if [[ "$APPLY_REPAIR" -eq 1 ]]; then
    phase "applying the minimal repair in the overlay (purge casper, drop the casper initramfs conf, drop the live gschema override)"
    chroot_up "$VIEW"
    in_chroot "$VIEW" /bin/bash -euc '
        dpkg --purge --force-depends casper
        rm -f /etc/casper.conf /etc/initramfs-tools/conf.d/casperize.conf /etc/initramfs-tools/conf.d/default-layer.conf
        rm -f /usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override
        glib-compile-schemas /usr/share/glib-2.0/schemas
    ' >"$OUT/repair.log" 2>&1 || { tail -20 "$OUT/repair.log" >&2; die "the minimal repair failed (see repair.log)"; }
    chroot_down "$VIEW"
    check INFO repair "the minimal repair was applied to the view before the copy (--apply-repair)"
    phase "repair applied"
fi

# ── the audits ───────────────────────────────────────────────────────────────────────────────────────────────────────
# Residue of the live session in a root directory: what stops an installed system from booting (FAIL) and what only
# leaks live-session settings into it (WARN). <where> says which tree was looked at in the message.
audit_residue() { # audit_residue <root> <where>
    local r="$1" where="$2" v f hits
    v="$(pkg_version "$r" casper)"
    if [[ -n "$v" ]]; then check FAIL casper-package "$where: the package casper $v is installed (its initramfs scripts make a normal boot look for a live medium)"
    else check PASS casper-package "$where: the package casper is not installed"; fi
    if [[ -e "$r/etc/casper.conf" ]]; then check FAIL casper-conf "$where: /etc/casper.conf exists (casper's live-session configuration)"
    else check PASS casper-conf "$where: no /etc/casper.conf"; fi
    hits=""
    for f in "$r"/etc/initramfs-tools/conf.d/*; do
        [[ -f "$f" ]] || continue
        if [[ "$(basename "$f")" == *casper* ]] || grep -qiE 'casper|LAYERFS_PATH|BOOT=live' "$f" 2>/dev/null; then hits="$hits ${f#"$r"}"; fi
    done
    if [[ -n "$hits" ]]; then check FAIL casper-initramfs-conf "$where: initramfs-tools conf.d holds casper settings:$hits"
    else check PASS casper-initramfs-conf "$where: no casper settings in /etc/initramfs-tools/conf.d"; fi
    hits=""
    for f in "$r"/usr/share/initramfs-tools/scripts/casper* "$r"/usr/share/initramfs-tools/hooks/casper*; do
        [[ -e "$f" ]] && hits="$hits ${f#"$r"}"
    done
    if [[ -n "$hits" ]]; then check FAIL casper-initramfs-scripts "$where: casper's initramfs scripts are installed:$hits"
    else check PASS casper-initramfs-scripts "$where: no casper initramfs scripts"; fi
    # Live-session leftovers that do not stop the boot but are wrong in an installed system (found in the v7 install).
    hits=""
    for f in "$r"/usr/share/glib-2.0/schemas/*livecd-rootfs*.override; do [[ -e "$f" ]] && hits="$hits ${f#"$r"}"; done
    if [[ -n "$hits" ]]; then check WARN live-gschema "$where: live-session dconf overrides (e.g. no lock screen) are compiled into the installed system:$hits"
    else check PASS live-gschema "$where: no live-session gschema override"; fi
    hits=""
    for f in "$r"/var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_*.snap "$r"/var/lib/snapd/snaps/ubuntu-desktop-bootstrap_*.snap \
             "$r"/var/lib/snapd/desktop/applications/ubuntu-desktop-bootstrap_*.desktop; do
        [[ -e "$f" ]] && hits="$hits ${f#"$r"}"
    done
    if [[ -n "$hits" ]]; then check WARN installer-snap "$where: the installer snap ubuntu-desktop-bootstrap is in the installed system:$hits"
    else check PASS installer-snap "$where: no installer snap"; fi
    hits=""
    # (/etc/apt/preferences.d.save is in the stock layers too: not a leftover of the live session)
    for f in "$r"/etc/subiquity "$r"/etc/cloud/cloud.cfg.d/06_quiet.cfg; do
        [[ -e "$f" ]] && hits="$hits ${f#"$r"}"
    done
    if [[ -n "$hits" ]]; then check WARN installer-leftovers "$where: installer/live-session files in the installed system:$hits"
    else check PASS installer-leftovers "$where: no installer/live-session files"; fi
    # The live image's /etc/cloud/cloud.cfg names the live session's user as cloud-init's default user, with passwordless sudo: cloud-init
    # (enabled in the installed system) creates it on the first boot. The stock installed system has the stock cloud.cfg.
    if grep -qE '^[[:space:]]+name:[[:space:]]+installer[[:space:]]*$' "$r/etc/cloud/cloud.cfg" 2>/dev/null; then
        check WARN cloud-init-installer-user "$where: /etc/cloud/cloud.cfg makes the live session's user \"installer\" cloud-init's default user (passwordless sudo, created on the installed system's first boot)"
    else check PASS cloud-init-installer-user "$where: cloud.cfg does not name the live session's user"; fi
    return 0
}

audit_residue "$VIEW" "base layer"
if [[ "$QUICK" -eq 1 ]]; then
    phase "quick mode: the base layer was audited; no disk, no initramfs and no boot (run without --quick for those)"
    exit 0
fi
[[ "$STOP_AFTER" != view ]] || { phase "stopped after view (--stop-after)"; exit 0; }

# ── 3  the disk ──────────────────────────────────────────────────────────────────────────────────────────────────────
IMG="$RUN/disk.raw"
if [[ "$DISK_SIZE" == auto ]]; then
    # No -x: on an overlay whose lower layers are squashfs mounts, every file of a layer carries that layer's st_dev, and du -x then skips
    # them all (it measured 1 MiB for a 5.9 GiB stack and made a 4 GiB disk that the copy overflowed). Nothing else is mounted in the view yet.
    used_mib="$(du -s --block-size=1M "$VIEW" | cut -f1)"
    [[ "$used_mib" -ge 8 ]] || die "the source view measures only ${used_mib} MiB: cannot size the disk (is the layer empty?); give --disk-size"
    # the unpacked layer + 15% (ext4 overhead, the initramfs, first-boot writes) + 3 GiB free + the 512 MiB ESP + 2 MiB for the GPT, in whole GiB
    DISK_SIZE="$(( (used_mib * 115 / 100 + 3072 + 512 + 2 + 1023) / 1024 ))G"
fi
phase "creating a $DISK_SIZE sparse disk, GPT, 512 MiB ESP + ext4 root"
truncate -s "$DISK_SIZE" "$IMG"
# Geometry in 512-byte sectors, 1 MiB aligned: ESP at 1 MiB (512 MiB), root after it up to 1 MiB before the end.
ESP_START=2048
ESP_SIZE=1048576
ROOT_START=$((ESP_START + ESP_SIZE))
TOTAL_SECTORS=$(( $(stat -c %s "$IMG") / 512 ))
ROOT_SIZE=$(( (TOTAL_SECTORS - ROOT_START - 2048) / 2048 * 2048 ))
[[ "$ROOT_SIZE" -gt 4194304 ]] || die "--disk-size $DISK_SIZE is too small"
sfdisk -q "$IMG" >/dev/null <<EOF
label: gpt
unit: sectors
first-lba: 2048

start=$ESP_START, size=$ESP_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System"
start=$ROOT_START, size=$ROOT_SIZE, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="Companion OS root"
EOF
# No loop device is set up by hand: mkfs writes into the image at the partition offset, and mount -o loop,offset attaches (and
# later frees) the loop devices itself. The UUIDs are chosen here so that fstab does not depend on reading them back.
ROOT_UUID="$(cat /proc/sys/kernel/random/uuid)"
ESP_ID="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')"
ESP_UUID="${ESP_ID:0:4}-${ESP_ID:4:4}"
# -s 8: 4 KiB clusters. Left alone, mkfs.fat sizes the clusters by the whole image file (32 sectors for a 24 GiB file), a 512 MiB
# FAT32 then has fewer than 65525 clusters and UEFI firmware reads it as FAT16 and does not mount it (seen: OVMF drops to its shell).
mkfs.vfat --offset "$ESP_START" -F 32 -s 8 -h "$ESP_START" -n ESP -i "$ESP_ID" "$IMG" $((ESP_SIZE / 2)) >/dev/null
python3 -I - "$IMG" $((ESP_START * 512)) <<'PY' || die "the ESP is not a valid FAT32 for UEFI firmware (too few clusters)"
import struct, sys
with open(sys.argv[1], 'rb') as f:
    f.seek(int(sys.argv[2]))
    b = f.read(512)
spc, rsv, nfat = b[13], struct.unpack('<H', b[14:16])[0], b[16]
total, fatsz = struct.unpack('<I', b[32:36])[0], struct.unpack('<I', b[36:40])[0]
clusters = (total - rsv - nfat * fatsz) // spc
sys.exit(0 if clusters >= 65525 else 1)
PY
# orphan_file is new in e2fsprogs 1.47; leave it off like the installer's mkfs of the day, so every GRUB can read the filesystem.
mkfs.ext4 -F -q -L companion-root -U "$ROOT_UUID" -O ^orphan_file -E "offset=$((ROOT_START * 512)),lazy_itable_init=1,lazy_journal_init=1" "$IMG" $((ROOT_SIZE / 2)) 2>/dev/null \
    || mkfs.ext4 -F -q -L companion-root -U "$ROOT_UUID" -E "offset=$((ROOT_START * 512)),lazy_itable_init=1,lazy_journal_init=1" "$IMG" $((ROOT_SIZE / 2))
T="$RUN/target"
mnt "$T" -t ext4 -o "loop,offset=$((ROOT_START * 512)),sizelimit=$((ROOT_SIZE * 512))" "$IMG" || die "cannot mount the root partition"
phase "disk formatted: root UUID $ROOT_UUID, ESP UUID $ESP_UUID"

# ── 3b  fill the root from the view (what curtin does with the layer stack) ──────────────────────────────────────────
phase "copying the root filesystem (this is the slow part)"
cp -ax --reflink=never "$VIEW"/. "$T"/
# The squashfs the build packs leaves these out (mksquashfs -e); a stand-in chroot has them, so drop them like the pack does.
rm -rf --one-file-system "$T"/var/cache/apt/archives/* "$T"/var/lib/apt/lists/* "$T"/tmp/* "$T"/root/.bash_history 2>/dev/null || true
mkdir -p "$T"/{dev,proc,sys,run,tmp,boot/efi}
chmod 1777 "$T/tmp"
phase "root filesystem copied ($(du -sx --block-size=1M "$T" | cut -f1) MiB)"
[[ "$STOP_AFTER" != copy ]] || { phase "stopped after copy (--stop-after)"; exit 0; }

# ── 4  the target configuration ──────────────────────────────────────────────────────────────────────────────────────
mnt "$T/boot/efi" -t vfat -o "loop,offset=$((ESP_START * 512)),sizelimit=$((ESP_SIZE * 512))" "$IMG" || die "cannot mount the ESP"
cat > "$T/etc/fstab" <<EOF
# /etc/fstab: throw-away image of tests/installed-boot.sh (the installer writes the same UUID entries)
UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1
UUID=$ESP_UUID /boot/efi vfat umask=0077 0 1
EOF
printf 'companion-os-test\n' > "$T/etc/hostname"
if grep -q '^127.0.1.1' "$T/etc/hosts" 2>/dev/null; then sed -i 's/^127\.0\.1\.1.*/127.0.1.1 companion-os-test/' "$T/etc/hosts"; else printf '127.0.1.1 companion-os-test\n' >> "$T/etc/hosts"; fi
: > "$T/etc/machine-id"
rm -f "$T/var/lib/dbus/machine-id"
printf 'throw-away image built by backends/ubuntu/iso/tests/installed-boot.sh; not an installer product, do not ship\n' > "$T/etc/ci-os-installed-boot-test"

USER_PW="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
chroot_up "$T"
in_chroot "$T" /bin/bash -euc '
    u="$1"
    grps=""
    for g in adm cdrom sudo dip plugdev lpadmin sambashare; do getent group "$g" >/dev/null && grps="$grps,$g"; done
    id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash -G "${grps#,}" -c "Installed-boot test user" "$u"
' _ "$USERNAME_T" || die "could not create the user"
printf '%s:%s\n' "$USERNAME_T" "$USER_PW" | in_chroot "$T" chpasswd
umask 077; printf 'user=%s\npassword=%s\n' "$USERNAME_T" "$USER_PW" > "$OUT/guest-user"; umask 022
phase "target configured: fstab, hostname, machine-id, user $USERNAME_T"

# The probe: reports on the serial console, and only when the kernel command line carries ci.bootprobe.
if [[ "$PROBE" -eq 1 ]]; then
    install -m 0755 "$HERE/installed-boot-probe.sh" "$T/usr/local/sbin/ci-installed-boot-probe"
    cat > "$T/etc/systemd/system/ci-installed-boot-probe.service" <<'EOF'
[Unit]
Description=Installed-boot smoke test probe (test harness only: reports the boot state on the serial console)
ConditionKernelCommandLine=ci.bootprobe
After=basic.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/ci-installed-boot-probe
TimeoutStartSec=infinity

[Install]
WantedBy=basic.target
EOF
    mkdir -p "$T/etc/systemd/system/basic.target.wants"
    ln -sf /etc/systemd/system/ci-installed-boot-probe.service "$T/etc/systemd/system/basic.target.wants/ci-installed-boot-probe.service"
fi

# Kernel command line additions that exist for the test only: a serial console (the last console= is /dev/console, so the
# initramfs and systemd messages reach the serial log), systemd status lines, the probe's condition. The distribution's own
# /etc/default/grub is read first and untouched. os-prober stays off: in a container it would scan the HOST's loop devices.
mkdir -p "$T/etc/default/grub.d"
cat > "$T/etc/default/grub.d/99-ci-installed-boot-test.cfg" <<'EOF'
# tests/installed-boot.sh only
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX console=tty0 console=ttyS0,115200 ci.bootprobe systemd.show_status=1 plymouth.ignore-serial-consoles"
GRUB_TIMEOUT=1
GRUB_RECORDFAIL_TIMEOUT=1
GRUB_DISABLE_OS_PROBER=true
EOF

# ── 5  the initramfs, regenerated the way curtin does ────────────────────────────────────────────────────────────────
KLIST=()
for f in "$T"/boot/vmlinuz-*; do [[ -e "$f" ]] && KLIST+=("${f##*/vmlinuz-}"); done
[[ ${#KLIST[@]} -gt 0 ]] || need "the base layer carries no kernel (no /boot/vmlinuz-*), so there is nothing to boot: a stock Ubuntu minimal.squashfs gets its kernel from the ISO's apt pool at install time, which this test does not do. Give it a layer stack that has the kernel (the Companion layers do), or use --quick for the static audit of the layer"
# Newest first (version sort), so "latest" is the first one.
SORTED=()
while IFS= read -r k; do SORTED+=("$k"); done < <(printf '%s\n' "${KLIST[@]}" | sort -rV)
check INFO kernels "kernels in the installed system: ${SORTED[*]}"
phase "update-initramfs -c -k $KERNELS (kernels: ${SORTED[*]})"
if [[ "$KERNELS" == all ]]; then
    in_chroot "$T" update-initramfs -c -k all >"$OUT/initramfs.log" 2>&1 || { tail -30 "$OUT/initramfs.log" >&2; die "update-initramfs failed (see initramfs.log)"; }
    TESTED=("${SORTED[@]}")
else
    in_chroot "$T" update-initramfs -c -k "${SORTED[0]}" >"$OUT/initramfs.log" 2>&1 || { tail -30 "$OUT/initramfs.log" >&2; die "update-initramfs failed (see initramfs.log)"; }
    TESTED=("${SORTED[0]}")
fi
phase "initramfs generated"

# Every initrd, parsed the way the kernel does (early microcode archives, then the compressed main archive) and searched for casper.
# initrd-audit.py instead of unmkinitramfs: that finds the archive borders with `dd bs=1` loops and takes tens of minutes in an
# emulated (Rosetta / QEMU user mode) container.
for k in "${TESTED[@]}"; do
    if [[ ! -s "$T/boot/initrd.img-$k" ]]; then check FAIL initrd-missing "initrd.img-$k was not generated"; continue; fi
    res="$(python3 -I "$HERE/initrd-audit.py" "$T/boot/initrd.img-$k" 2>&1 || true)"
    if printf '%s\n' "$res" | grep -q '^error '; then
        check FAIL initrd-unreadable "initrd.img-$k could not be read: $(printf '%s\n' "$res" | sed -n 's/^error //p' | head -1)"; continue
    fi
    total="$(printf '%s\n' "$res" | awk '$1 == "total" { print $2 }')"
    if [[ "${total:-0}" -gt 0 ]]; then
        sample="$(printf '%s\n' "$res" | awk '$1 == "conf" { $1 = ""; print }' | head -3 | tr '\n' ';' | sed 's/  */ /g')"
        paths="$(printf '%s\n' "$res" | awk '$1 == "path" { print $2 }' | head -4 | tr '\n' ' ')"
        check FAIL initrd-casper "initrd.img-$k contains casper ($total paths, e.g. $paths; conf.d:$sample): a normal boot runs casper and looks for a live medium instead of mounting the root"
    else
        check PASS initrd-casper "initrd.img-$k has no casper scripts or configuration ($(printf '%s\n' "$res" | awk '$1 == "entries" { print $2 }') entries)"
    fi
done
[[ "$STOP_AFTER" != initrd ]] || { phase "stopped after initrd (--stop-after)"; exit 0; }

# ── 6  the boot loader, the way curtin sets it up for UEFI ───────────────────────────────────────────────────────────
phase "grub-install (UEFI, shim path) and update-grub"
if ! in_chroot "$T" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=companion --uefi-secure-boot --no-nvram >"$OUT/grub.log" 2>&1; then
    tail -20 "$OUT/grub.log" >&2; die "grub-install failed (see grub.log)"
fi
# grub-mkconfig writes root=UUID=... only when /dev/disk/by-uuid/<uuid> exists (udev makes it on a real system; a container has no udev).
ROOTLOOP="$(findmnt -no SOURCE "$T")"
mkdir -p /dev/disk/by-uuid
ln -sf "$ROOTLOOP" "/dev/disk/by-uuid/$ROOT_UUID"
in_chroot "$T" update-grub >>"$OUT/grub.log" 2>&1 || { tail -20 "$OUT/grub.log" >&2; die "update-grub failed (see grub.log)"; }
rm -f "/dev/disk/by-uuid/$ROOT_UUID"
phase "boot loader installed"
GCFG="$T/boot/grub/grub.cfg"
[[ -s "$GCFG" ]] || die "update-grub wrote no /boot/grub/grub.cfg"
cp "$GCFG" "$OUT/grub.cfg"
mkdir -p "$OUT/esp"; (cd "$T/boot/efi" && find . -type f | sort) > "$OUT/esp/files.txt"

lines="$(grep -E '^[[:space:]]*linux[[:space:]]' "$GCFG" || true)"
if [[ -z "$lines" ]]; then check FAIL grub-no-linux "grub.cfg has no linux line: nothing to boot"
elif printf '%s\n' "$lines" | grep -q "root=UUID=$ROOT_UUID"; then check PASS grub-root-uuid "grub.cfg boots with root=UUID=$ROOT_UUID"
else check FAIL grub-root-uuid "no linux line of grub.cfg has root=UUID=$ROOT_UUID: $(printf '%s\n' "$lines" | head -1)"; fi
if printf '%s\n' "$lines" | grep -qiE 'boot=casper|boot=live|layerfs|casper'; then
    check FAIL grub-casper "grub.cfg boots the installed kernel in live mode (boot=casper / layerfs-path): $(printf '%s\n' "$lines" | grep -iE 'boot=casper|boot=live|layerfs|casper' | head -1)"
else check PASS grub-casper "grub.cfg has no boot=casper"; fi
if [[ -e "$T/boot/efi/EFI/BOOT/BOOTX64.EFI" && -e "$T/boot/efi/EFI/companion/shimx64.efi" ]]; then check PASS esp-files "the ESP has the shim (EFI/companion/shimx64.efi and the removable-path fallback EFI/BOOT/BOOTX64.EFI)"
else check FAIL esp-files "the ESP lacks EFI/BOOT/BOOTX64.EFI or EFI/companion/shimx64.efi ($(tr '\n' ' ' < "$OUT/esp/files.txt"))"; fi
audit_residue "$T" "installed system"
[[ "$STOP_AFTER" != grub ]] || { phase "stopped after grub (--stop-after)"; }

# ── 7  finish ────────────────────────────────────────────────────────────────────────────────────────────────────────
{
    printf 'root_uuid=%s\nesp_uuid=%s\nkernels=%s\nsource=%s\n' "$ROOT_UUID" "$ESP_UUID" "${SORTED[*]}" "$SRC_DESC"
    printf 'cmdline_example=%s\n' "$(printf '%s\n' "$lines" | head -1 | sed 's/^[[:space:]]*//')"
    for k in "${SORTED[@]}"; do ls -l "$T/boot/initrd.img-$k" 2>/dev/null | awk '{ print "initrd " $9 " " $5 " bytes" }'; done
} > "$OUT/installed-report.txt"
sync
chroot_down "$T"
for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do [[ "${MOUNTS[$i]}" == "$T" ]] && { umount "$T" && unset 'MOUNTS[i]'; }; done
MOUNTS=("${MOUNTS[@]:-}")
if e2fsck -fn "$IMG?offset=$((ROOT_START * 512))" >"$OUT/e2fsck.log" 2>&1; then check PASS fsck "e2fsck: the installed root filesystem is clean"; else check WARN fsck "e2fsck reported problems (see e2fsck.log)"; fi
phase "build done; FAILs: $(fails)"

want=0
case "$EMIT" in yes) want=1 ;; auto) [[ "$(fails)" -eq 0 ]] && want=1 ;; esac
if [[ "$want" -eq 1 && -z "$STOP_AFTER" ]]; then
    phase "copying the disk image out ($(du -h "$IMG" | cut -f1) on disk)"
    cp --sparse=always "$IMG" "$OUT/disk.raw"
    phase "disk image copied"
fi
exit 0
