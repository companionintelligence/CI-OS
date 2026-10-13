#!/usr/bin/env bash
# Prove `docker run hello-world` works OFFLINE as the unprivileged live user in a Companion OS live boot.
#   docker-live.sh iso   companion-os.iso              plain ISO live session   -> Docker data on tmpfs
#   docker-live.sh stick companion-os.iso stick.img    Companion Stick (boot=casper persistent) -> ext4, survives reboot
# Needs: qemu-system-x86_64 xorriso (and a hello-world tarball: docker pull --platform linux/amd64 hello-world &&
#        docker save hello-world -o hello-world-amd64.tar). Boots kernel+initrd straight from the ISO with the SAME
#        kernel arguments GRUB gives them (stick/crates/ci-stick/src/bootcfg.rs:182); GRUB and Secure Boot are covered
#        by stick/tests/secureboot.
set -uo pipefail
MODE="${1:?iso|stick}"; ISO="${2:?path to companion-os.iso}"; IMG="${3:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${CI_DOCKER_TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/ci-docker-live.XXXXXX")}"; mkdir -p "$W/t"
HW="${CI_HELLO_WORLD_TAR:-$HERE/hello-world-amd64.tar}"; [ -f "$HW" ] || { echo "missing $HW" >&2; exit 2; }
TIMEOUT="${CI_DOCKER_TEST_TIMEOUT:-1800}"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL=(-accel kvm -cpu host); else ACCEL=(-accel tcg,thread=multi -cpu Haswell); fi

xorriso -osirrox on -indev "$ISO" -extract /casper/vmlinuz "$W/vmlinuz" -extract /casper/initrd "$W/initrd" >/dev/null 2>&1 || exit 2
cp "$HERE/guest-docker-test.sh" "$W/t/guest-test.sh"; cp "$HW" "$W/t/hello-world.tar"
xorriso -as mkisofs -V CI_TEST -o "$W/ci-test.iso" "$W/t" >/dev/null 2>&1

FAILED=0; fail() { echo "FAIL: $*"; FAILED=1; }; ok() { echo "PASS: $*"; }
boot() { # boot <n> <guest-mode> <phase>
  local log="$W/boot$1.log" run
  run="systemd.run=\"/bin/sh -c 'mkdir -p /mnt/t && mount -o ro /dev/disk/by-label/CI_TEST /mnt/t && /bin/sh /mnt/t/guest-test.sh $2 companion $3'\""
  local append="console=ttyS0 systemd.show_status=0 systemd.run_success_action=poweroff systemd.run_failure_action=poweroff $run"
  local -a disk=()
  if [ "$MODE" = stick ]; then
    append="boot=casper live-media=/dev/disk/by-partlabel/CI-BOOT-A persistent ci_stick.slot=A $append"
    disk=(-drive if=none,id=stick,format=raw,file="$W/stick.img" -device usb-storage,bus=xhci.0,drive=stick,bootindex=0)
  else
    disk=(-cdrom "$ISO")
  fi
  : > "$log"
  timeout --foreground -k 10 "$TIMEOUT" qemu-system-x86_64 -machine q35 "${ACCEL[@]}" -m 6144 -smp 4 \
    -display none -monitor none -no-reboot -nic none -serial "file:$log" \
    -kernel "$W/vmlinuz" -initrd "$W/initrd" -append "$append" \
    -device qemu-xhci,id=xhci "${disk[@]}" \
    -drive if=none,id=t,format=raw,readonly=on,file="$W/ci-test.iso" -device usb-storage,bus=xhci.0,drive=t
  echo "boot $1 qemu exit $?"
  tr -d '\r' < "$log" | grep -a '^CI-DOCKER-TEST' | tee "$W/boot$1.results"
  grep -aq '^CI-DOCKER-TEST DONE PASS' "$W/boot$1.results" || fail "boot $1: no 'DONE PASS' (see $log)"
  grep -a ' FAIL ' "$W/boot$1.results" && fail "boot $1: failing assertions above"
}
if [ "$MODE" = stick ]; then
  [ -f "$IMG" ] || { echo "stick image missing" >&2; exit 2; }
  cp --sparse=always "$IMG" "$W/stick.img"       # never write to the artefact under test
  boot 1 live-stick first; boot 2 live-stick second     # second boot proves CI-PERSIST really holds Docker's data
else
  boot 1 live-iso first
fi
echo "work dir: $W"; [ "$FAILED" = 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
