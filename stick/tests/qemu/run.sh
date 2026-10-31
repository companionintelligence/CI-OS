#!/usr/bin/env bash
# Companion Stick QEMU boot test — one command, root-free, PASS/FAIL summary at the end.
#
#   stick/tests/qemu/run.sh
#
# 1. builds ci-stick, the standalone GRUB (BOOTX64.EFI) and two casper-shaped test boot
#    images (slot A and slot B), then locks and dev-signs a bundle;
# 2. `ci-stick flash --image stick.img --size 64GB` (sparse) with the B image in slot B;
# 3. boots stick.img in QEMU as a USB mass-storage device under UEFI (OVMF), three times:
#      boot 1  slot=A cmdline_slot=A, boot-count=1
#      boot 2  boot-count=2                         (persistence survives a reboot)
#      `ci-stick slot set B`
#      boot 3  slot=B cmdline_slot=B, boot-count=3  (same persistence from the other slot)
# 4. negative safety tests: a tampered bundle, a rolled-back or expired schema 2 bundle,
#    --allow-unsigned with --device, a regular file as --device, and a non-removable disk
#    as --device must all be refused without writing anything. The bundle of steps 1 to 3
#    is schema 1 (no sequence, no expiry); a schema 2 variant of it is checked in step 4.
#
# The sequence floors this script creates live in "$WORK/state" (CI_STICK_STATE_DIR is set
# below), never in the state directory of the machine running it.
#
# Environment:
#   CI_STICK_BIN          use this ci-stick binary instead of building one
#   CI_STICK_QEMU_WORK    work directory (default: a new temp dir, kept for inspection)
#   CI_STICK_TEST_CACHE   kernel download cache (default ~/.cache/ci-stick-test)
#   CI_STICK_QEMU_TIMEOUT seconds per boot (default 120 with KVM, 480 with TCG)
#
# Needs: qemu-system-x86 ovmf grub-efi-amd64-bin gdisk dosfstools mtools exfatprogs
#        e2fsprogs xorriso busybox-static cpio zstd (and cargo unless CI_STICK_BIN is set).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STICK="$(cd "$HERE/../.." && pwd)"
WORK="${CI_STICK_QEMU_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/ci-stick-qemu.XXXXXX")}"
mkdir -p "$WORK"
# Absolute, so that CI_STICK_STATE_DIR (below) is too: ci-stick refuses a relative one.
WORK="$(cd "$WORK" && pwd)"

declare -a RESULTS=()
FAILED=0
pass() { RESULTS+=("PASS  $*"); echo "PASS: $*"; }
fail() { RESULTS+=("FAIL  $*"); echo "FAIL: $*" >&2; FAILED=1; }
die()  { fail "$*"; summary; exit 1; }
log()  { echo; echo "=== $*"; }

summary() {
  echo
  echo "================ Companion Stick QEMU test summary ================"
  printf '%s\n' "${RESULTS[@]}"
  echo "work dir: $WORK"
  if [ "$FAILED" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
}

# --- prerequisites --------------------------------------------------------------------
missing=()
for t in qemu-system-x86_64 sgdisk mkfs.vfat mkfs.exfat mkfs.ext4 mcopy mmd xorriso cpio \
         zstd gzip grub-mkstandalone apt-get dpkg-deb; do
  command -v "$t" >/dev/null 2>&1 || [ -x "/usr/sbin/$t" ] || [ -x "/sbin/$t" ] || missing+=("$t")
done
[ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]} (see the header of this script)"

OVMF_CODE=""; OVMF_VARS=""
for pair in /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd \
            /usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd \
            /usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd \
            /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd; do
  if [ -f "${pair%%:*}" ] && [ -f "${pair##*:}" ]; then
    OVMF_CODE="${pair%%:*}"; OVMF_VARS="${pair##*:}"; break
  fi
done
[ -n "$OVMF_CODE" ] || die "no OVMF firmware found (apt-get install ovmf)"

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  ACCEL=(-accel kvm -cpu host); ACCEL_NAME=kvm; DEFAULT_TIMEOUT=120
else
  ACCEL=(-accel tcg); ACCEL_NAME=tcg; DEFAULT_TIMEOUT=480
fi
TIMEOUT="${CI_STICK_QEMU_TIMEOUT:-$DEFAULT_TIMEOUT}"
echo "work dir $WORK, accel $ACCEL_NAME, ${TIMEOUT}s per boot, firmware $OVMF_CODE"

if [ -n "${CI_STICK_BIN:-}" ]; then
  CI="$CI_STICK_BIN"
else
  log "building ci-stick"
  (cd "$STICK" && cargo build --release --locked --quiet) || die "cargo build"
  CI="$STICK/target/release/ci-stick"
fi

# Keep the sequence floors of this run in its own work directory.
export CI_STICK_STATE_DIR="$WORK/state"

# --- 1. artifacts, bundle, signature ---------------------------------------------------
log "building BOOTX64.EFI and test boot images"
STAGE="$WORK/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/boot" "$STAGE/efi"
"$STICK/scripts/build-grub-efi.sh" "$STAGE/efi/BOOTX64.EFI" || die "build-grub-efi.sh"
"$HERE/build-test-boot-image.sh" A "$STAGE/boot/companion-test-x86_64.iso" || die "test image A"
"$HERE/build-test-boot-image.sh" B "$WORK/slot-b.iso" || die "test image B"

log "lock + dev sign + verify"
"$CI" lock "$STAGE" --id companion-stick-qemu-test --version 0.0.0-test --size 64GB \
  --created-at 2026-01-01T00:00:00Z >/dev/null || die "lock"
"$CI" dev keygen --out "$WORK/dev" >/dev/null 2>&1 || die "dev keygen"
"$CI" dev sign "$STAGE" --key "$WORK/dev.key" >/dev/null || die "dev sign"
"$CI" verify "$STAGE" --pubkey "$WORK/dev.pub" >/dev/null || die "verify"
pass "bundle locked, signed and verified"

# --- 2. flash ------------------------------------------------------------------------
log "flash --image stick.img --size 64GB"
IMG="$WORK/stick.img"
rm -f "$IMG"
"$CI" flash "$STAGE" --pubkey "$WORK/dev.pub" --image "$IMG" --size 64GB --dry-run \
  > "$WORK/plan.txt" || die "flash --dry-run"
[ ! -e "$IMG" ] && pass "dry run wrote nothing" || fail "dry run created $IMG"
"$CI" flash "$STAGE" --pubkey "$WORK/dev.pub" --image "$IMG" --size 64GB \
  --slot-b-from "$WORK/slot-b.iso" --extra-cmdline "console=ttyS0,115200 panic=5" \
  --work-dir "$WORK" || die "flash"
apparent=$(stat -c %s "$IMG"); used=$(( $(stat -c %b "$IMG") * 512 ))
echo "stick.img: apparent $apparent bytes, allocated $used bytes"
[ "$apparent" -eq 64000000000 ] && [ "$used" -lt $((2 * 1024 * 1024 * 1024)) ] \
  && pass "flash wrote a sparse 64 GB image (allocated $((used / 1048576)) MiB)" \
  || fail "image is not a sparse 64 GB file (apparent $apparent, allocated $used)"
sgdisk -p "$IMG" | tail -n 8
# Capture the whole report. `slot show | grep -q` closes stdout early, and with
# pipefail a writer that then hits EPIPE fails the check even when the slot is right.
show=$("$CI" slot show --image "$IMG") || show=""
grep -q "active slot A" <<<"$show" \
  && pass "slot show: A after flash" || fail "slot show after flash (${show:-no output})"

# --- 3. boots ------------------------------------------------------------------------
boot() { # boot <n>: runs QEMU, leaves the serial log in $WORK/boot<n>.log
  local n="$1" log="$WORK/boot$1.log" vars="$WORK/OVMF_VARS.fd"
  [ -f "$vars" ] || cp "$OVMF_VARS" "$vars"
  rm -f "$log"
  echo "boot $n: qemu ($ACCEL_NAME, timeout ${TIMEOUT}s), serial -> $log"
  local start=$SECONDS
  timeout --foreground -k 10 "$TIMEOUT" qemu-system-x86_64 \
    -machine q35 -m 1024 -smp 2 "${ACCEL[@]}" \
    -display none -monitor none -no-reboot -net none \
    -serial "file:$log" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$vars" \
    -device qemu-xhci,id=xhci \
    -drive "if=none,id=stick,format=raw,file=$IMG" \
    -device usb-storage,bus=xhci.0,drive=stick,bootindex=0
  local rc=$?
  echo "boot $n: qemu exited $rc after $((SECONDS - start))s"
  tr -d '\r' < "$log" | grep -a 'CI-STICK-TEST' | sed "s/^/  boot $n serial: /"
  [ $rc -eq 124 ] && echo "boot $n: TIMED OUT" && tail -c 3000 "$log" | tr -d '\r'
  return 0
}
expect() { # expect <n> <text>
  if tr -d '\r' < "$WORK/boot$1.log" | grep -aqF -- "$2"; then pass "boot $1: $2"
  else fail "boot $1: expected '$2' on the serial console"; fi
}

log "boot 1 (slot A)"
boot 1
expect 1 "CI-STICK-TEST slot=A cmdline_slot=A"
expect 1 "CI-STICK-TEST boot-count=1 "

log "boot 2 (slot A again: persistence)"
boot 2
expect 2 "CI-STICK-TEST slot=A cmdline_slot=A"
expect 2 "CI-STICK-TEST boot-count=2 "

log "slot set B"
show=""
if "$CI" slot set B --image "$IMG"; then
  show=$("$CI" slot show --image "$IMG") || show=""
fi
if grep -q "active slot B" <<<"$show"; then
  pass "slot set B (grubenv active_slot=B)"
else
  fail "slot set B (${show:-no output})"
fi

log "boot 3 (slot B, same persistence)"
boot 3
expect 3 "CI-STICK-TEST slot=B cmdline_slot=B"
expect 3 "CI-STICK-TEST boot-count=3 "

# --- 4. negative safety tests --------------------------------------------------------
refused() { # refused <description> <expected exit> <expected text> -- cmd...
  local what="$1" want_rc="$2" want_text="$3"; shift 4
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want_text" <<<"$out"; then
    pass "refused: $what"
  else
    fail "not refused as expected: $what (exit $rc, want $want_rc / '$want_text'): $(tail -n 3 <<<"$out")"
  fi
}

log "negative: tampered bundle"
TAMPER="$WORK/stage-tampered"
rm -rf "$TAMPER"; cp -r "$STAGE" "$TAMPER"
printf 'X' | dd of="$TAMPER/boot/companion-test-x86_64.iso" bs=1 seek=40000 conv=notrunc status=none
rm -f "$WORK/tampered.img"
refused "flash of a tampered bundle" 1 "sha256" -- \
  "$CI" flash "$TAMPER" --pubkey "$WORK/dev.pub" --image "$WORK/tampered.img" --size 64GB
[ ! -e "$WORK/tampered.img" ] && pass "tampered bundle: no image written" \
  || fail "tampered bundle: $WORK/tampered.img exists"
cp "$STAGE/bundle.json" "$TAMPER/bundle.json"
sed -i 's/0.0.0-test/0.0.1-test/' "$TAMPER/bundle.json"
refused "flash of a bundle whose manifest no longer matches its signature" 1 "signature" -- \
  "$CI" flash "$TAMPER" --pubkey "$WORK/dev.pub" --image "$WORK/tampered.img" --size 64GB

log "schema 2: a current bundle is accepted, an older and an expired one are refused"
V2="$WORK/stage-v2"
rm -rf "$V2"; cp -r "$STAGE" "$V2"
rm -f "$V2/bundle.json" "$V2/bundle.json.sig" "$WORK/v2.img"
lock_v2() { # lock_v2 <sequence> <created_at> <valid days>: re-lock and re-sign the schema 2 copy
  "$CI" lock "$V2" --id companion-stick-qemu-test --version 0.0.0-test --size 64GB \
    --sequence "$1" --created-at "$2" --valid-days "$3" >/dev/null \
    && "$CI" dev sign "$V2" --key "$WORK/dev.key" >/dev/null
}
if lock_v2 2 2090-01-01T00:00:00Z 3650 \
   && "$CI" verify "$V2" --pubkey "$WORK/dev.pub" >/dev/null \
   && "$CI" flash "$V2" --pubkey "$WORK/dev.pub" --image "$WORK/v2.img" --size 64GB --dry-run \
        > "$WORK/plan-v2.txt" \
   && grep -qF "sequence 2" "$WORK/plan-v2.txt"; then
  pass "schema 2 bundle (sequence 2) verified and planned"
else
  fail "schema 2 bundle (sequence 2) was not accepted"
fi
lock_v2 1 2090-01-02T00:00:00Z 3650 || die "lock schema 2, sequence 1"
refused "flash of a bundle below the sequence floor" 1 "bundle-rollback" -- \
  "$CI" flash "$V2" --pubkey "$WORK/dev.pub" --image "$WORK/v2.img" --size 64GB
lock_v2 3 2020-01-01T00:00:00Z 30 || die "lock schema 2, expired"
refused "flash of an expired bundle" 1 "bundle-expired" -- \
  "$CI" flash "$V2" --pubkey "$WORK/dev.pub" --image "$WORK/v2.img" --size 64GB
[ ! -e "$WORK/v2.img" ] && pass "refused schema 2 bundles: no image written" \
  || fail "refused schema 2 bundles: $WORK/v2.img exists"

log "negative: device safety"
refused "--allow-unsigned with --device" 2 "--allow-unsigned is refused with --device" -- \
  "$CI" flash "$STAGE" --allow-unsigned --device /dev/null --dry-run

FAKE="$WORK/not-a-disk.bin"
head -c 1048576 /dev/urandom > "$FAKE"
before=$(sha256sum < "$FAKE")
refused "a regular file as --device" 2 "not a block device" -- \
  "$CI" flash "$STAGE" --pubkey "$WORK/dev.pub" --device "$FAKE" --confirm "$FAKE"
[ "$(sha256sum < "$FAKE")" = "$before" ] && pass "regular file untouched" || fail "regular file changed"

# A real, non-removable disk (TRAN last: it is empty for some disks).
# lsblk can name a disk whose node is absent (a container that sees host sysfs
# but not the host's /dev). That is not a disk we can refuse, so skip it.
sysdisk="$(lsblk -dnbpo PATH,RM,TYPE,SIZE,TRAN 2>/dev/null \
  | awk '$3 == "disk" && $2 == "0" && $4 > 0 && $5 != "usb" && $1 !~ /zram|loop/ {print $1; exit}')"
if [ -n "$sysdisk" ] && [ ! -e "$sysdisk" ]; then
  echo "(lsblk listed $sysdisk but the device node is absent; skipping that case)"
elif [ -n "$sysdisk" ]; then
  first_before=""; [ -r "$sysdisk" ] && first_before="$(head -c 1048576 "$sysdisk" | sha256sum)"
  refused "non-removable disk $sysdisk as --device (dry run)" 2 "refusing to write" -- \
    "$CI" flash "$STAGE" --pubkey "$WORK/dev.pub" --device "$sysdisk" --dry-run
  # The two cases below go past the dry run and would write if the safety checks ever
  # regressed, so they aim a real write at this machine's own disk. Only run them where
  # that is acceptable: CI's throwaway runner sets CI_STICK_TEST_SYSDISK_WRITE_REFUSAL=1.
  # Everywhere else (a developer laptop) they are skipped; the same decisions are covered
  # by the device-safety unit tests.
  if [ "${CI_STICK_TEST_SYSDISK_WRITE_REFUSAL:-}" = "1" ]; then
    refused "non-removable disk $sysdisk as --device (with --confirm)" 2 "refusing to write" -- \
      "$CI" flash "$STAGE" --pubkey "$WORK/dev.pub" --device "$sysdisk" --confirm "$sysdisk"
    refused "slot set on non-removable disk $sysdisk" 2 "refusing to write" -- \
      "$CI" slot set B --device "$sysdisk" --confirm "$sysdisk"
  else
    echo "(skipping write-attempt refusals against $sysdisk; set CI_STICK_TEST_SYSDISK_WRITE_REFUSAL=1 on a disposable machine)"
  fi
  if [ -n "$first_before" ]; then
    [ "$(head -c 1048576 "$sysdisk" | sha256sum)" = "$first_before" ] \
      && pass "$sysdisk first MiB unchanged" || fail "$sysdisk first MiB CHANGED"
  fi
else
  echo "(no non-removable disk visible to lsblk; skipping that case)"
fi

summary
exit "$FAILED"
