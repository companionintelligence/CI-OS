#!/usr/bin/env bash
# Build a tiny *test* boot image that mimics Ubuntu's live-ISO (casper) layout, so the
# stick's real grub.cfg boots it unchanged:
#
#   stick/tests/qemu/build-test-boot-image.sh <slot-id> <out.iso>
#
#   /casper/vmlinuz  a real Ubuntu x86_64 kernel (linux-image-*-generic, extracted with dpkg-deb)
#   /casper/initrd   gzip'd newc cpio: static busybox + USB storage modules + /init below
#
# /init prints "CI-STICK-TEST slot=<slot-id> cmdline_slot=<ci_stick.slot from the kernel
# command line>", finds the ext4 filesystem labelled "writable" (exactly how casper finds
# its persistence), increments /boot-count on it, prints "CI-STICK-TEST boot-count=<n>"
# and powers off. The harness (run.sh) asserts on those lines from the serial console.
#
# CI_STICK_TEST_SB_PROBE=1 (used by stick/tests/secureboot/) additionally prints
# "CI-STICK-SB secureboot=<0|1> slot=<slot-id> cmdline_slot=<...>" from the SecureBoot EFI
# variable, the kernel's lockdown mode and its Secure Boot/lockdown log lines. Unset, the
# image is exactly what run.sh has always booted.
#
# Needs: apt-get (download only), dpkg-deb, zstd, cpio, gzip, xorriso, busybox-static.
# No root. Kernel packages are cached in $CI_STICK_TEST_CACHE (default ~/.cache/ci-stick-test).
set -euo pipefail

slot="${1:?usage: build-test-boot-image.sh <slot-id> <out.iso>}"
out="${2:?usage: build-test-boot-image.sh <slot-id> <out.iso>}"
case "$slot" in *[!A-Za-z0-9_-]*|'') echo "slot id must be alphanumeric" >&2; exit 2 ;; esac

for t in apt-get dpkg-deb zstd cpio gzip xorriso; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }
done
busybox_bin="$(command -v busybox || true)"
# A dynamically linked busybox cannot run in an initrd with no libc; ldd succeeds on those.
if [ -z "$busybox_bin" ] || ldd "$busybox_bin" >/dev/null 2>&1; then
  echo "need a static busybox on PATH (apt-get install busybox-static)" >&2; exit 2
fi

cache="${CI_STICK_TEST_CACHE:-$HOME/.cache/ci-stick-test}"
mkdir -p "$cache"

# --- kernel + modules (cached) -------------------------------------------------------
kver_file="$cache/kernel-version"
if [ ! -s "$cache/vmlinuz" ] || [ ! -s "$kver_file" ]; then
  # linux-image-generic -> linux-image-<ver>-generic; the modules package holds the
  # USB host/storage drivers that the generic kernel builds as modules.
  pkg="$(apt-cache depends linux-image-generic 2>/dev/null \
    | awk '/Depends: linux-image-[0-9]/ {print $2; exit}')"
  [ -n "$pkg" ] || { echo "cannot resolve linux-image-generic (apt-get update?)" >&2; exit 2; }
  kver="${pkg#linux-image-}"
  dl="$cache/dl"
  rm -rf "$dl"; mkdir -p "$dl"
  (cd "$dl" && apt-get download "linux-image-$kver" "linux-modules-$kver" >/dev/null)
  mkdir -p "$dl/x"
  for deb in "$dl"/*.deb; do dpkg-deb -x "$deb" "$dl/x"; done
  cp "$dl/x/boot/vmlinuz-$kver" "$cache/vmlinuz"
  rm -rf "$cache/modules"; mkdir -p "$cache/modules"
  kd="$dl/x/lib/modules/$kver/kernel/drivers/usb"
  # Load order matters: dependencies first.
  for m in host/xhci-pci-renesas host/xhci-pci storage/usb-storage; do
    src="$kd/$m.ko.zst"
    if [ -f "$src" ]; then
      zstd -q -d -f "$src" -o "$cache/modules/$(basename "$m").ko"
    elif [ -f "$kd/$m.ko" ]; then
      cp "$kd/$m.ko" "$cache/modules/"
    fi   # built into this kernel: nothing to load
  done
  echo "$kver" > "$kver_file"
  rm -rf "$dl"
fi
kver="$(cat "$kver_file")"

# --- initrd -------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/initrd"
mkdir -p "$root"/{bin,dev,proc,sys,mnt,lib/modules}
cp "$busybox_bin" "$root/bin/busybox"
cp "$cache"/modules/*.ko "$root/lib/modules/" 2>/dev/null || true
: > "$root/lib/modules/order"
for m in xhci-pci-renesas xhci-pci usb-storage; do
  [ -f "$root/lib/modules/$m.ko" ] && echo "$m.ko" >> "$root/lib/modules/order"
done

cat > "$root/init" <<EOF
#!/bin/busybox sh
# Companion Stick QEMU test init (slot $slot, kernel $kver). Not a real OS.
/bin/busybox --install -s /bin
export PATH=/bin
mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo 0 > /proc/sys/kernel/printk 2>/dev/null
SLOT="$slot"
EOF
cat >> "$root/init" <<'EOF'
CMD_SLOT=none
for arg in $(cat /proc/cmdline); do
  case "$arg" in ci_stick.slot=*) CMD_SLOT="${arg#ci_stick.slot=}" ;; esac
done
echo "CI-STICK-TEST slot=$SLOT cmdline_slot=$CMD_SLOT"
EOF
if [ "${CI_STICK_TEST_SB_PROBE:-0}" = "1" ]; then
  # Secure Boot probe (stick/tests/secureboot/): the SecureBoot EFI variable (4 attribute
  # bytes, then the value), what the kernel logged about it, and the lockdown mode.
  cat >> "$root/init" <<'EOF'
mkdir -p /sys/firmware/efi/efivars /sys/kernel/security
mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null
mount -t securityfs securityfs /sys/kernel/security 2>/dev/null
SBVAR=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
if [ ! -d /sys/firmware/efi ]; then
  SB=no-efi; SBSRC=no-efi
elif [ -r "$SBVAR" ]; then
  # Read the whole variable (efivarfs does not seek): 4 attribute bytes, then the value.
  # shellcheck disable=SC2046
  set -- $(od -An -t u1 "$SBVAR")
  SB="${5:-unknown}"; SBSRC="efivar"
else
  # No SecureBoot variable: firmware without Secure Boot support, i.e. not enforcing.
  SB=0; SBSRC="efivar-absent"
fi
echo "CI-STICK-SB secureboot=$SB slot=$SLOT cmdline_slot=$CMD_SLOT"
echo "CI-STICK-SB secureboot-source=$SBSRC"
echo "CI-STICK-SB lockdown=$(cat /sys/kernel/security/lockdown 2>/dev/null | tr ' ' ',')"
dmesg | grep -i -E 'secureboot:|locked down|lockdown:' | head -n 8 | sed 's/^/CI-STICK-SB dmesg: /'
EOF
fi
cat >> "$root/init" <<'EOF'
while read -r m; do insmod "/lib/modules/$m" 2>/dev/null; done < /lib/modules/order
dev=
i=0
while [ $i -lt 120 ]; do
  dev="$(findfs LABEL=writable 2>/dev/null)" && [ -n "$dev" ] && break
  i=$((i + 1)); sleep 1
done
if [ -z "$dev" ]; then
  echo "CI-STICK-TEST error=no-writable-filesystem"
  cat /proc/partitions
else
  if mount -t ext4 "$dev" /mnt; then
    n="$(cat /mnt/boot-count 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" > /mnt/boot-count
    sync
    umount /mnt
    echo "CI-STICK-TEST boot-count=$n dev=$dev"
  else
    echo "CI-STICK-TEST error=mount-failed dev=$dev"
  fi
fi
sync
echo "CI-STICK-TEST done"
poweroff -f
EOF
chmod 0755 "$root/init"

mkdir -p "$tmp/iso/casper"
cp "$cache/vmlinuz" "$tmp/iso/casper/vmlinuz"
(cd "$root" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet | gzip -9 -n) \
  > "$tmp/iso/casper/initrd"
echo "ci-stick test boot image, slot $slot, kernel $kver" > "$tmp/iso/CI-STICK-TEST.txt"

mkdir -p "$(dirname "$out")"
xorriso -as mkisofs -quiet -r -J -V "CI_TEST_$slot" -o "$out" "$tmp/iso"
echo "built $out (slot $slot, kernel $kver, $(stat -c %s "$out") bytes)"
