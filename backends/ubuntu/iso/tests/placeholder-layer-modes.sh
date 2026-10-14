#!/usr/bin/env bash
#=============================================================================
# Test: the placeholder casper layers keep the rootfs directory modes
#
# build-iso.sh packs the whole rootfs into minimal.squashfs and adds two empty placeholder layers
# (minimal.standard.squashfs, minimal.standard.live.squashfs) on top of it. casper stacks the
# layers with overlayfs, and a directory present in several layers takes its mode from the
# topmost one. A placeholder made with a plain `mkdir -p` has /tmp as drwxr-xr-x, so the live
# session lost its sticky world-writable /tmp (untrusted desktop launcher, installer that does
# not start). make_placeholder_layer() must prevent that. This test builds the real overlay:
#
#   control   a plain-mkdir placeholder DOES break /tmp (proves the test can see the bug);
#   fixed     a make_placeholder_layer placeholder leaves /tmp 1777 and a non-root user can
#             create a file in it, also when the overlay has no upper layer (how an installer
#             that reads the layers sees the root directory);
#   listing   every directory in the placeholder squashfs has the mode of the rootfs one;
#   forced    /tmp stays 1777 even when the rootfs it mirrors has a different mode.
#
# Needs root, squashfs-tools and overlayfs (mount -t overlay), so run it in a privileged Linux
# container (the Docker Desktop VM is fine), with the repo mounted read-only:
#
#   docker run --rm --privileged -v "$PWD:/repo:ro" <image with squashfs-tools> \
#       bash /repo/backends/ubuntu/iso/tests/placeholder-layer-modes.sh
#
# Exit status is non-zero if any check fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourcing build-iso.sh only defines its functions (main runs only when it is executed).
# shellcheck source=../scripts/build-iso.sh
source "$HERE/../scripts/build-iso.sh"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then echo "needs root (mount): run it in a privileged container" >&2; exit 2; fi
for t in mksquashfs unsquashfs mount umount setpriv; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t (apt-get install squashfs-tools mount util-linux)" >&2; exit 2; }
done

WORK="$(mktemp -d)"
chmod 755 "$WORK"   # the non-root probe has to traverse it
MOUNTS=()
cleanup() {
    local i
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do umount "${MOUNTS[$i]}" 2>/dev/null || umount -l "${MOUNTS[$i]}" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT
mnt() { # mnt <dir> <mount args...>
    local dir="$1"; shift
    mkdir -p "$dir"
    mount "$@" "$dir"
    MOUNTS+=("$dir")
}

# The rootfs the way build-iso.sh leaves it: /tmp is 1777, root 0755.
ROOTFS="$WORK/rootfs"
mkdir -p "$ROOTFS"/{etc,var,tmp,usr}
chmod 755 "$ROOTFS" "$ROOTFS"/{etc,var,usr}
chmod 1777 "$ROOTFS/tmp"
mksquashfs "$ROOTFS" "$WORK/base.sqsh" -comp xz -noappend -no-recovery -quiet >/dev/null 2>&1

# The placeholder as build-iso.sh used to make it, and as it makes it now. mktemp -d, like the build.
OLD="$(mktemp -d "$WORK/old.XXXXXX")"
mkdir -p "$OLD"/{etc,var,tmp}
NEW="$(mktemp -d "$WORK/new.XXXXXX")"
make_placeholder_layer "$ROOTFS" "$NEW"
for p in old new; do
    d="$OLD"; [[ "$p" == new ]] && d="$NEW"
    mksquashfs "$d" "$WORK/$p.sqsh" -comp xz -noappend -no-recovery -quiet >/dev/null 2>&1
done

mnt "$WORK/m-base" -t squashfs -o loop,ro "$WORK/base.sqsh"
mnt "$WORK/m-old" -t squashfs -o loop,ro "$WORK/old.sqsh"
mnt "$WORK/m-new" -t squashfs -o loop,ro "$WORK/new.sqsh"
# overlayfs upper and work dirs must not live on the container's own overlay filesystem.
mnt "$WORK/upper" -t tmpfs tmpfs

# stack <name> <placeholder mount>: the live layout, placeholder on top of the root layer, with a writable upper.
stack() {
    mkdir -p "$WORK/upper/$1/up" "$WORK/upper/$1/wk" "$WORK/merged-$1"
    chmod 755 "$WORK/upper/$1/up"
    mnt "$WORK/merged-$1" -t overlay overlay \
        -o "lowerdir=$2:$WORK/m-base,upperdir=$WORK/upper/$1/up,workdir=$WORK/upper/$1/wk"
}
probe() { # can an unprivileged user create a file in <dir>?
    setpriv --reuid=65534 --regid=65534 --clear-groups touch "$1/probe.$$" 2>/dev/null
}

stack old "$WORK/m-old"
old_mode="$(stat -c %a "$WORK/merged-old/tmp")"
if [[ "$old_mode" != 1777 ]] && ! probe "$WORK/merged-old/tmp"; then
    t_pass "control: a plain-mkdir placeholder breaks /tmp (mode $old_mode, unprivileged user cannot create files)"
else
    t_fail "control: the old placeholder did not break /tmp here (mode $old_mode); this environment cannot show the bug"
fi

stack new "$WORK/m-new"
new_mode="$(stat -c %a "$WORK/merged-new/tmp")"
if [[ "$new_mode" == 1777 ]]; then t_pass "overlay with the placeholder on top: /tmp is 1777"; else t_fail "overlay with the placeholder on top: /tmp is $new_mode, expected 1777"; fi
if probe "$WORK/merged-new/tmp"; then t_pass "overlay: an unprivileged user can create a file in /tmp"; else t_fail "overlay: an unprivileged user cannot create a file in /tmp"; fi
for d in etc var; do
    if [[ "$(stat -c %a "$WORK/merged-new/$d")" == 755 ]]; then t_pass "overlay: /$d is 755"; else t_fail "overlay: /$d is $(stat -c %a "$WORK/merged-new/$d"), expected 755"; fi
done

# No upper layer: the root of the stack is the root of the topmost layer.
for p in old new; do
    mkdir -p "$WORK/merged-ro-$p"
    if mount -t overlay overlay -o "lowerdir=$WORK/m-$p:$WORK/m-base" "$WORK/merged-ro-$p" 2>/dev/null; then
        MOUNTS+=("$WORK/merged-ro-$p")
        root_mode="$(stat -c %a "$WORK/merged-ro-$p")"
        if [[ "$p" == new ]]; then
            if [[ "$root_mode" == 755 ]]; then t_pass "read-only stack: its root is 755"; else t_fail "read-only stack: its root is $root_mode, expected 755"; fi
        else
            printf 'info  control: with the plain-mkdir placeholder the read-only stack root is %s\n' "$root_mode"
        fi
    else
        printf 'info  overlay without an upper layer is not supported here; root mode of the stack not checked (%s)\n' "$p"
    fi
done

# The listing view that verify-iso.sh section 3e uses: same modes as the rootfs, root included.
bad=0
while read -r mode _ _ _ _ path; do
    path="${path#squashfs-root}"
    want="$(stat -c %A "$ROOTFS$path")"
    if [[ "$mode" != "$want" ]]; then bad=1; t_fail "placeholder layer: ${path:-/} is $mode, the rootfs has $want"; fi
done < <(unsquashfs -ll "$WORK/new.sqsh" | grep '^d')
[[ "$bad" -eq 0 ]] && t_pass "placeholder layer: every directory (root included) has the mode of the rootfs"

# /tmp is forced to 1777 even if the rootfs it mirrors says otherwise; the other modes are mirrored.
ODD="$WORK/odd-rootfs"; ODDLAYER="$WORK/odd-layer"
mkdir -p "$ODD"/{etc,var,tmp} "$ODDLAYER"
chmod 750 "$ODD/etc"; chmod 711 "$ODD/var"; chmod 755 "$ODD/tmp"
make_placeholder_layer "$ODD" "$ODDLAYER"
layer_modes() { stat -c %a "$ODDLAYER/etc" "$ODDLAYER/var" "$ODDLAYER/tmp" | paste -sd' ' -; }
got="$(layer_modes)"
if [[ "$got" == "750 711 1777" ]]; then t_pass "other modes are mirrored (etc 750, var 711) and /tmp is forced to 1777"; else t_fail "mirror/force: got '$got', expected '750 711 1777'"; fi
make_placeholder_layer "$ODD" "$ODDLAYER"   # running it again on the same directory is harmless
if [[ "$(layer_modes)" == "$got" ]]; then t_pass "make_placeholder_layer is idempotent"; else t_fail "make_placeholder_layer changed modes when run twice"; fi

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
