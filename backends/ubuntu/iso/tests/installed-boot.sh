#!/usr/bin/env bash
#=============================================================================
# Test: the INSTALLED system boots (installed-system boot smoke test)
#
#   backends/ubuntu/iso/tests/installed-boot.sh [options] SOURCE
#
# Why: the live session and the installed system are built from the same layer, and a boot of the live ISO proves nothing about
# the installed one. In the v7 image the installer copied minimal.squashfs, which is the WHOLE merged rootfs and so carries the stock
# live layer's content: the package casper, /etc/casper.conf, /etc/initramfs-tools/conf.d/casperize.conf and default-layer.conf.
# Every initrd regenerated in the target then contains casper's scripts and a conf.d file that sets BOOT=casper, so a normal boot
# (root=UUID=..., no boot=) ran casper and dropped to "Unable to find a medium containing a live file system". It was found after a
# seven-hour GUI install. This test finds it in minutes, without a GUI and without installing anything.
#
# The base is Ubuntu 26.04.1 (the only release this repo builds). Its installed system is initramfs-tools based, as the merged build
# leaves it (build-iso.sh explains), which is what `update-initramfs -c -k all` below uses, as curtin does.
#
# What it does: takes the base layer an installer would install and builds a throw-away disk the way an install ends up
# (lib/installed-boot-disk.sh, in a privileged Docker container): GPT, ESP + ext4 root filled from the layer, fstab, a user, kernel +
# initrd regenerated in a chroot with update-initramfs -c -k all, UEFI GRUB through the shim (grub-install, update-grub), then
# checks the result (no casper in the base layer, in any regenerated initrd or in grub.cfg; root=UUID=...). Then it boots the disk in
# QEMU (TCG, on the host) and asserts that the GDM greeter comes up and the display shows it: serial-console markers from a
# test-only probe unit in the image, QMP screenshots, a result file. Exit 0 only when every check passed AND the greeter was reached.
#
# FAIL checks (the installed system cannot boot as it is): casper's package, /etc/casper.conf, casper settings in initramfs-tools conf.d,
# casper's initramfs scripts, casper in any regenerated initrd, no root=UUID= or a boot=casper on the grub.cfg linux lines, no shim on
# the ESP, a missing initrd. WARN checks (live-session leftovers that do not stop the boot, FAIL under --strict): the live gschema
# override, the installer snap, /etc/subiquity and friends, a cloud.cfg that makes the live user "installer" the first-boot default
# user. The probe also reports facts without judging them: restarted units, non-loopback listeners, accounts, masked units, journal errors
# (guest-report.txt), so a defect of the installed system that is not a boot failure can be read off one run.
#
# SOURCE, one of:
#   --iso FILE                a built ISO: the layers of the DEFAULT entry of its casper/install-sources.yaml, which is exactly
#                             what the installer installs (so a layer the installer would not install is not tested, and one it
#                             would is). The ISO is read through a loop mount in the container: nothing is extracted to the host.
#   --squashfs FILE           a base layer, e.g. casper/minimal.squashfs; repeat for a stack, bottom layer first
#   --chroot-volume VOL:PATH  an unpacked rootfs in a Docker volume, used read-only: the build's merged chroot as a stand-in for the
#                             layer (for the v7 work data: --chroot-volume ciosv5:w/chroot). The source is never written; every
#                             change (--apply-repair) lives in an overlayfs upper directory in scratch space.
#
# Options:
#   --work DIR            result directory (default: a new directory under $TMPDIR; kept). Holds result.txt, checks.txt, timeline.txt,
#                         serial.log, guest-report.txt, screenshots/, grub.cfg, build.log, the disk image if --keep-disk
#   --image IMAGE         builder image (default: $CI_OS_BOOT_TEST_IMAGE or ubuntu:26.04). Needs losetup, mount, mkfs.ext4, mkfs.vfat,
#                         sfdisk, blkid, e2fsck (+ python3 for --iso); on a stock ubuntu image the script apt-installs what is
#                         missing (network needed). The container runs --privileged --platform linux/amd64.
#   --docker-volume NAME  scratch volume for the disk image (default: a new one, removed at the end; a named one is kept)
#   --disk-size SIZE      disk image size, e.g. 20G (default auto: the unpacked layer + 15% + 3 GiB + the ESP; sparse in the container)
#   --kernels all|latest  initrds to regenerate and check (default all, like update-initramfs -c -k all)
#   --apply-repair        first apply the minimal known repair to the base layer's overlay view (purge casper, remove the two
#                         initramfs conf files and the live gschema override, recompile schemas): shows the test PASSES on a fixed layer
#   --quick               only audit the base layer (casper's package, files and initramfs scripts, the live leftovers): a verdict that
#                         names casper in seconds. No disk, no initramfs, no boot: PASS here means "no known live-session residue", not "boots"
#   --no-boot             build the disk and run all the static checks (the regenerated initrds, grub.cfg, the ESP), do not boot
#   --stop-after PHASE    debugging: view|copy|initrd|grub, stop the disk build after that phase
#   --always-boot         boot even when a static check FAILed (shows what the user would see)
#   --strict              WARN checks (live-session leftovers that do not stop the boot) fail the test too
#   --timeout SECS        give the boot this long (default 1800; TCG without KVM needs minutes)
#   --grace SECS          after the probe says the greeter is up, wait this long for a drawn picture on the screen (default 120)
#   --cpu MODEL           QEMU CPU (default Nehalem). Nehalem booted the Ubuntu 24.04.5 desktop under TCG here and Haswell crashed GNOME Shell
#                         there; NOT re-measured with Ubuntu 26.04.1's GNOME Shell 50 (no 26.04 image has been booted by this test yet)
#   --memory MIB / --smp N   guest memory and CPUs (default 4096 / 4)
#   --secure-boot         boot with the Secure Boot firmware and Microsoft keys enrolled (shim + signed GRUB + signed kernel)
#   --ovmf-code FILE --ovmf-vars FILE   firmware (default: $CI_OS_OVMF_DIR or stick/tests/secureboot/out/firmware/OVMF_{CODE,VARS}_4M*.fd)
#   --net                 give the guest the host's network. Default: none (restrict=on): the installed system's first-boot provisioning
#                         (ci-os-first-boot-setup.service) otherwise apt-installs and pulls GBs of Ollama models during the test
#   --keep-disk           keep disk.raw and the qcow2 overlay in --work (about the size of the installed system)
#   --boot-disk FILE      boot an existing raw disk image (e.g. one kept with --keep-disk) instead of building one: no source, no static
#                         checks, only the boot. The image is never written (a qcow2 overlay takes the guest's writes).
#   --selftest            run the test's own parts against a fake QEMU and synthetic initrds (no Docker, no QEMU; seconds), then exit
#
# Exit status: 0 passed; 1 the installed system is defective (a check FAILed, or the greeter was not reached); 2 cannot run here
# (a tool, the firmware or Docker is missing); 3 the harness itself failed (a build step failed: not a verdict).
#
# Host: macOS or Linux, bash 3.2+, docker, qemu-system-x86_64 + qemu-img, python3. Nothing here needs KVM; a TCG boot of the GNOME
# desktop takes several minutes.
#
# Manual: no workflow runs it (it needs Docker with --privileged, minutes and, for a real ISO, the ISO).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
# shellcheck disable=SC2054  # the commas in the QEMU argument arrays are QEMU's option syntax, not array separators
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lib"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

ISO="" CHROOT_VOL="" WORK="" IMAGE="${CI_OS_BOOT_TEST_IMAGE:-ubuntu:26.04}" VOLUME="" DISK_SIZE=auto KERNELS=all
APPLY_REPAIR=0 QUICK=0 NO_BOOT=0 ALWAYS_BOOT=0 STRICT=0 TIMEOUT=1800 GRACE=120 CPU=Nehalem MEMORY=4096 SMP=4 SECURE=0 KEEP_DISK=0
OVMF_CODE="" OVMF_VARS="" STOP_AFTER="" NET=0 BOOT_DISK=""
LAYERS=()

die() { printf 'installed-boot: %s\n' "$*" >&2; exit 3; }
need() { printf 'installed-boot: cannot run here: %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --iso) ISO="$2"; shift 2 ;;
        --squashfs) LAYERS+=("$2"); shift 2 ;;
        --chroot-volume) CHROOT_VOL="$2"; shift 2 ;;
        --work) WORK="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --docker-volume) VOLUME="$2"; shift 2 ;;
        --disk-size) DISK_SIZE="$2"; shift 2 ;;
        --kernels) KERNELS="$2"; shift 2 ;;
        --apply-repair) APPLY_REPAIR=1; shift ;;
        --quick) QUICK=1; shift ;;
        --no-boot) NO_BOOT=1; shift ;;
        --always-boot) ALWAYS_BOOT=1; shift ;;
        --strict) STRICT=1; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --grace) GRACE="$2"; shift 2 ;;
        --cpu) CPU="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --smp) SMP="$2"; shift 2 ;;
        --secure-boot) SECURE=1; shift ;;
        --ovmf-code) OVMF_CODE="$2"; shift 2 ;;
        --ovmf-vars) OVMF_VARS="$2"; shift 2 ;;
        --net) NET=1; shift ;;
        --keep-disk) KEEP_DISK=1; shift ;;
        --boot-disk) BOOT_DISK="$2"; shift 2 ;;
        --stop-after) STOP_AFTER="$2"; shift 2 ;;   # debugging: view|copy|initrd|grub, passed to the disk builder
        --selftest) exec bash "$LIB/selftest.sh" ;;   # the harness' own parts, no Docker, no QEMU, seconds
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

# ── what to test ─────────────────────────────────────────────────────────────────────────────────────────────────────
n=0
[ -n "$ISO" ] && n=$((n + 1))
[ -n "$CHROOT_VOL" ] && n=$((n + 1))
[ ${#LAYERS[@]} -gt 0 ] && n=$((n + 1))
if [ -n "$BOOT_DISK" ]; then
    [ "$n" -eq 0 ] || die "--boot-disk takes no source"
    [ -f "$BOOT_DISK" ] || die "no such disk image: $BOOT_DISK"
    [ "$QUICK" -eq 0 ] && [ "$NO_BOOT" -eq 0 ] || die "--boot-disk is for booting: it cannot be combined with --quick or --no-boot"
else
    [ "$n" -eq 1 ] || die "give exactly one source: --iso FILE, --squashfs FILE (repeatable) or --chroot-volume VOL:PATH (see --help)"
fi
case "$KERNELS" in all|latest) ;; *) die "--kernels takes all or latest" ;; esac

# ── prerequisites ────────────────────────────────────────────────────────────────────────────────────────────────────
if [ -z "$BOOT_DISK" ]; then
    command -v docker >/dev/null 2>&1 || need "docker is not installed"
    docker info >/dev/null 2>&1 || need "the Docker daemon is not running"
fi
if [ "$QUICK" -eq 0 ] && [ "$NO_BOOT" -eq 0 ]; then
    for t in qemu-system-x86_64 qemu-img python3; do
        command -v "$t" >/dev/null 2>&1 || need "missing tool: $t (macOS: brew install qemu; Debian/Ubuntu: apt-get install qemu-system-x86 qemu-utils)"
    done
    FWDIR="${CI_OS_OVMF_DIR:-$REPO_ROOT/stick/tests/secureboot/out/firmware}"
    if [ -z "$OVMF_CODE" ]; then
        if [ "$SECURE" -eq 1 ]; then OVMF_CODE="$FWDIR/OVMF_CODE_4M.secboot.fd"; else OVMF_CODE="$FWDIR/OVMF_CODE_4M.fd"; fi
    fi
    if [ -z "$OVMF_VARS" ]; then
        if [ "$SECURE" -eq 1 ]; then OVMF_VARS="$FWDIR/OVMF_VARS_4M.ms.fd"; else OVMF_VARS="$FWDIR/OVMF_VARS_4M.fd"; fi
    fi
    [ -f "$OVMF_CODE" ] || need "no UEFI firmware at $OVMF_CODE (set CI_OS_OVMF_DIR or --ovmf-code/--ovmf-vars; Ubuntu's ovmf package has OVMF_CODE_4M.fd, OVMF_VARS_4M.fd and the .secboot/.ms variants)"
    [ -f "$OVMF_VARS" ] || need "no UEFI variable store at $OVMF_VARS"
fi
[ -z "$ISO" ] || [ -f "$ISO" ] || die "no such ISO: $ISO"
for f in ${LAYERS[@]+"${LAYERS[@]}"}; do [ -f "$f" ] || die "no such layer: $f"; done

abspath() { ( cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")" ); }

if [ -z "$WORK" ]; then WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-installed-boot.XXXXXX")"; else mkdir -p "$WORK"; fi
WORK="$(cd "$WORK" && pwd)"
OUTD="$WORK/build"
mkdir -p "$OUTD" "$WORK/screenshots"
: > "$WORK/timeline.txt"
T0=$(date +%s)
tl() { printf 'T+%5ds  %s\n' "$(( $(date +%s) - T0 ))" "$*" | tee -a "$WORK/timeline.txt"; }

OWN_VOLUME=0
if [ -z "$VOLUME" ] && [ -z "$BOOT_DISK" ]; then VOLUME="ci-os-installed-boot-$$"; OWN_VOLUME=1; fi
CNAME="ci-os-installed-boot-$$"
QDIR=""
LIBSNAP=""
cleanup() {
    local rc=$?
    set +e
    [ -z "$LIBSNAP" ] || rm -rf "$LIBSNAP"
    if [ -z "$BOOT_DISK" ] && docker inspect "$CNAME" >/dev/null 2>&1; then docker stop -t 60 "$CNAME" >/dev/null 2>&1; docker rm -f "$CNAME" >/dev/null 2>&1; fi
    if [ "$OWN_VOLUME" -eq 1 ]; then docker volume rm -f "$VOLUME" >/dev/null 2>&1; fi
    [ -z "$QDIR" ] || rm -rf "$QDIR"
    # The disk image is removed unless --keep-disk (it is as large as the installed system); an image given with --boot-disk never is.
    if [ "$KEEP_DISK" -eq 0 ]; then
        rm -f "$OUTD/disk.raw" "$WORK/boot.qcow2" "$WORK/vars.fd"
        [ -n "$BOOT_DISK" ] || rm -f "$WORK/disk.raw"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

finish() { # finish <PASS|FAIL> <reason>
    local verdict="$1" reason="$2"
    {
        printf 'RESULT=%s\nREASON=%s\n' "$verdict" "$reason"
        printf 'STATIC_FAILS=%s\nSTATIC_WARNS=%s\nSECONDS=%s\nWORK=%s\n' "$(grep -c '^FAIL ' "$WORK/checks.txt" || true)" "$nwarn" "$(( $(date +%s) - T0 ))" "$WORK"
        [ ! -f "$WORK/boot-result.txt" ] || sed 's/^/BOOT_/' "$WORK/boot-result.txt"
    } > "$WORK/result.txt"
    printf '\n== %s: %s\n   (details in %s)\n' "$verdict" "$reason" "$WORK"
    [ "$verdict" = PASS ]
}

nfail=0 nwarn=0
if [ -z "$BOOT_DISK" ]; then
    # ── 1  build the disk in a privileged container ──────────────────────────────────────────────────────────────────────
    # The container runs a snapshot of lib/: bash reads a script while it runs, so an edit of the file during a (long) run would make the
    # running build execute the wrong lines. (/tmp is shared with Docker Desktop's VM by default.)
    LIBSNAP="$(mktemp -d /tmp/ci-ib-lib.XXXXXX)"
    cp -R "$LIB/." "$LIBSNAP/"
    DARGS=(run --name "$CNAME" --privileged --platform linux/amd64 --cpus 4 --memory 12g --entrypoint bash
           -v "$VOLUME:/work" -v "$OUTD:/out" -v "$LIBSNAP:/lib-ib:ro")
    BARGS=(--out /out --disk-size "$DISK_SIZE" --kernels "$KERNELS")
    if [ -n "$ISO" ]; then
        DARGS+=(-v "$(abspath "$ISO"):/in/base.iso:ro"); BARGS+=(--iso /in/base.iso)
    elif [ -n "$CHROOT_VOL" ]; then
        case "$CHROOT_VOL" in *:*) ;; *) die "--chroot-volume takes VOLUME:PATH, e.g. ciosv5:w/chroot" ;; esac
        DARGS+=(-v "${CHROOT_VOL%%:*}:/in:ro"); BARGS+=(--chroot "/in/${CHROOT_VOL#*:}")
    else
        i=0
        for f in "${LAYERS[@]}"; do DARGS+=(-v "$(abspath "$f"):/in/layer$i.squashfs:ro"); BARGS+=(--squashfs "/in/layer$i.squashfs"); i=$((i + 1)); done
    fi
    [ "$APPLY_REPAIR" -eq 0 ] || BARGS+=(--apply-repair)
    [ "$QUICK" -eq 0 ] || BARGS+=(--quick)
    [ -z "$STOP_AFTER" ] || BARGS+=(--stop-after "$STOP_AFTER")
    if [ "$NO_BOOT" -eq 1 ] || [ "$QUICK" -eq 1 ]; then BARGS+=(--emit-disk no)
    elif [ "$ALWAYS_BOOT" -eq 1 ]; then BARGS+=(--emit-disk yes); else BARGS+=(--emit-disk auto); fi

    tl "building the installed disk in a container ($IMAGE; scratch volume $VOLUME)"
    # The container's exit status is read back from docker (the pipe below only filters Docker Desktop's platform warning).
    nice -n 5 docker "${DARGS[@]}" "$IMAGE" /lib-ib/installed-boot-disk.sh "${BARGS[@]}" 2>&1 | { grep --line-buffered -v '^WARNING: The requested image' || true; } | tee "$WORK/build.log" || true
    crc="$(docker inspect -f '{{.State.ExitCode}}' "$CNAME" 2>/dev/null || echo 3)"
    oom="$(docker inspect -f '{{.State.OOMKilled}}' "$CNAME" 2>/dev/null || echo false)"
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    [ "$oom" != true ] || die "the build container was killed for lack of memory (it has 12 GB); close other work or lower the load"
    case "$crc" in
        0) ;;
        2) need "$(cat "$OUTD/need.txt" 2>/dev/null || printf 'the builder image %s cannot run the disk build (see build.log)' "$IMAGE")" ;;
        *) die "the disk build failed (container exit status $crc; see $WORK/build.log): this is not a verdict on the image" ;;
    esac
    cp "$OUTD/timeline.txt" "$WORK/build-timeline.txt" 2>/dev/null || true
    tl "disk build finished"

    # ── 2  static verdict ────────────────────────────────────────────────────────────────────────────────────────────────
    cp "$OUTD/checks.txt" "$WORK/checks.txt"
    for f in grub.cfg guest-user installed-report.txt initramfs.log grub.log repair.log e2fsck.log; do [ -f "$OUTD/$f" ] && cp "$OUTD/$f" "$WORK/$f"; done
    [ ! -f "$WORK/guest-user" ] || chmod 600 "$WORK/guest-user"
    nfail="$(grep -c '^FAIL ' "$WORK/checks.txt" || true)"
    nwarn="$(grep -c '^WARN ' "$WORK/checks.txt" || true)"
    if [ "$STRICT" -eq 1 ]; then nfail=$((nfail + nwarn)); fi
    printf '\n== Static checks of the installed system: %s FAIL, %s WARN, %s PASS\n' "$(grep -c '^FAIL ' "$WORK/checks.txt" || true)" "$nwarn" "$(grep -c '^PASS ' "$WORK/checks.txt" || true)"
    grep -E '^(FAIL|WARN) ' "$WORK/checks.txt" | cut -c1-400 || true

    if [ "$nfail" -gt 0 ] && [ "$ALWAYS_BOOT" -eq 0 ]; then
        first="$(grep -E '^FAIL ' "$WORK/checks.txt" | head -1 | cut -c1-300)"
        finish FAIL "$nfail static check(s) failed, the installed system cannot boot as it is. First: ${first#FAIL }" || exit 1
    fi
    if [ "$QUICK" -eq 1 ] || [ "$NO_BOOT" -eq 1 ] || [ -n "$STOP_AFTER" ]; then
        if [ "$nfail" -gt 0 ]; then finish FAIL "$nfail static check(s) failed" || exit 1; fi
        if [ "$QUICK" -eq 1 ]; then finish PASS "the base layer has no known live-session residue (--quick: the initramfs and the boot were NOT tested)" || exit 1
        else finish PASS "static checks passed (boot not run: --no-boot / --stop-after)" || exit 1; fi
        exit 0
    fi
else
    : > "$WORK/checks.txt"
fi
if [ -n "$BOOT_DISK" ]; then
    DISK="$(abspath "$BOOT_DISK")"
else
    [ -f "$OUTD/disk.raw" ] || die "the build left no disk image to boot"
    mv "$OUTD/disk.raw" "$WORK/disk.raw"
    DISK="$WORK/disk.raw"
fi

# ── 3  boot it ───────────────────────────────────────────────────────────────────────────────────────────────────────
tl "disk image on the host ($(du -h "$DISK" | cut -f1) on disk); booting it in QEMU (TCG, $CPU, $MEMORY MiB, $SMP CPUs)"
rm -f "$WORK/boot.qcow2"
qemu-img create -q -f qcow2 -F raw -b "$DISK" "$WORK/boot.qcow2"
cp "$OVMF_VARS" "$WORK/vars.fd"
QDIR="$(mktemp -d /tmp/ci-ib.XXXXXX)"   # short path: a unix socket path is limited to 104 bytes on macOS
: > "$WORK/serial.log"
# No outside network by default: the installed system provisions itself on first boot (ci-os-first-boot-setup: apt installs, Ollama
# model pulls of several GB), which a smoke test must neither wait for nor download. --net gives the guest the host's network (slirp NAT).
NIC="user,model=virtio-net-pci,restrict=on"
[ "$NET" -eq 0 ] || NIC="user,model=virtio-net-pci"
QARGS=(nice -n 5 qemu-system-x86_64 -accel tcg,thread=multi -cpu "$CPU" -m "$MEMORY" -smp "$SMP")
if [ "$SECURE" -eq 1 ]; then QARGS+=(-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on); else QARGS+=(-machine q35); fi
QARGS+=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,unit=1,file=$WORK/vars.fd"
        -drive "if=none,id=target,format=qcow2,file=$WORK/boot.qcow2" -device nvme,drive=target,serial=ci-target,bootindex=0
        -nic "$NIC" -display none -no-reboot
        -qmp "unix:$QDIR/qmp,server,nowait" -serial "file:$WORK/serial.log")
brc2=0
python3 -I "$LIB/boot-watch.py" --serial "$WORK/serial.log" --qmp "$QDIR/qmp" --shots "$WORK/screenshots" \
    --result "$WORK/boot-result.txt" --timeline "$WORK/boot-timeline.txt" --timeout "$TIMEOUT" --grace "$GRACE" -- "${QARGS[@]}" || brc2=$?
[ "$brc2" -ne 2 ] || need "QEMU could not be started"
reason="$(sed -n 's/^REASON=//p' "$WORK/boot-result.txt" 2>/dev/null | head -1)"
if [ -f "$WORK/guest-report.txt" ]; then
    printf '\n== Guest report (what the probe saw)\n'; cut -c1-300 "$WORK/guest-report.txt"
fi
if [ "$brc2" -eq 0 ] && [ "$nfail" -eq 0 ]; then
    finish PASS "installed system booted to the GDM greeter: $reason" || exit 1
elif [ "$brc2" -eq 0 ]; then
    finish FAIL "static checks failed ($nfail) although the boot reached the greeter: $reason" || exit 1
else
    finish FAIL "boot: ${reason:-did not reach the greeter}" || exit 1
fi
