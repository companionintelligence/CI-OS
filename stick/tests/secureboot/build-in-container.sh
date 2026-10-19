#!/usr/bin/env bash
# Companion Stick Secure Boot test — build half. Runs inside Ubuntu 26.04 (the
# `ubuntu:26.04` container that run-on-mac.sh starts, or an Ubuntu 26.04 host directly).
#
#   stick/tests/secureboot/build-in-container.sh [--out DIR] [--iso PATH]
#
# Default mode writes to DIR (default stick/tests/secureboot/out/):
#   signed.qcow2     64 GB stick, Secure Boot chain (shim -> Canonical GRUB), test slot A
#   unsigned.qcow2   64 GB stick, development chain (unsigned standalone GRUB), same slot A
#   firmware/        OVMF_CODE_4M.secboot.fd + OVMF_VARS_4M.ms.fd (Microsoft keys enrolled)
#                    and the non-Secure-Boot OVMF_CODE_4M.fd + OVMF_VARS_4M.fd, with
#                    firmware.lock (ovmf-generic package version + sha256)
#   signed-boot/     shimx64.efi grubx64.efi mmx64.efi + signed-boot.lock (fetch-signed-boot.sh)
#   build-info.txt   package versions, kernel and its signature check, plans
#
# The test boot image is casper-shaped (stick/tests/qemu/build-test-boot-image.sh with
# CI_STICK_TEST_SB_PROBE=1): a Canonical-signed Ubuntu kernel (checked with sbverify
# against the Canonical CA embedded in shim) and a busybox initrd that prints
# "CI-STICK-SB secureboot=<0|1> slot=A cmdline_slot=A" and bumps a boot counter on the
# persistence partition.
#
# --iso PATH writes iso-signed.qcow2 instead: a Secure Boot chain stick with that ISO
# (Ubuntu 26.04 desktop or a CI-OS build) in slot A, for a manual boot on the Mac.
#
# The raw 64 GB images are sparse and built in $CI_STICK_SB_WORK (default DIR/work); only
# the qcow2 conversions are meant to leave a container (sparse files do not survive
# Docker Desktop's macOS file sharing well).
#
# Environment: CI_STICK_SB_WORK, CI_STICK_BIN (skip the cargo build), CARGO_TARGET_DIR,
# CI_STICK_TEST_CACHE (kernel cache), CARGO_HOME / RUSTUP_HOME (rustup is installed there
# when cargo is missing).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STICK="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/out"
ISO=""
# Device size the images are laid out for. 64GB by default; CI_STICK_SB_SIZE=123942731776 reproduces the
# 123.9 GB "128 GB" sticks (73 GiB CI-CACHE, 12.4 GiB CI-PERSIST).
STICK_SIZE="${CI_STICK_SB_SIZE:-64GB}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?}"; shift 2 ;;
    --iso) ISO="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="${CI_STICK_SB_WORK:-$OUT/work}"
mkdir -p "$WORK"
INFO="$OUT/build-info.txt"
log() { echo; echo "=== $*"; }
die() { echo "build-in-container.sh: $*" >&2; exit 1; }

codename="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
[ "$codename" = resolute ] || die "needs Ubuntu 26.04 (resolute); this is '${codename:-unknown}'. Use run-on-mac.sh, which runs this in ubuntu:26.04."

# Docker Desktop on Apple Silicon starts this container with --platform linux/amd64, i.e. under
# Rosetta. Seen with Docker Desktop 29 on macOS 27: Ubuntu 26.04's GNU tar then fails to create
# anything inside a directory it has just created ("Cannot mkdir/Cannot open: Function not
# implemented"; bsdtar and Python's tarfile work there), and `dpkg-deb -x` runs tar, so
# everything below would fail with confusing errors.
pf="$(mktemp -d)"
if ! { mkdir -p "$pf/a/d" "$pf/b" && echo x > "$pf/a/d/f" && tar -cf "$pf/t.tar" -C "$pf/a" . \
       && tar -xf "$pf/t.tar" -C "$pf/b" && [ -f "$pf/b/d/f" ]; } 2> "$pf/err"; then
  cat "$pf/err" >&2; rm -rf "$pf"
  die "tar cannot extract files in this container (see above). If this is Docker Desktop on Apple Silicon, the amd64 emulation (Rosetta) lacks a syscall Ubuntu 26.04 needs: try turning off 'Use Rosetta for x86_64/amd64 emulation' in Docker Desktop's settings (untested), or build on an x86_64 machine running Ubuntu 26.04."
fi
rm -rf "$pf"

# --- dependencies ---------------------------------------------------------------------
PKGS=(ca-certificates curl build-essential qemu-utils ovmf-generic grub-efi-amd64-bin grub-common
      gdisk dosfstools mtools exfatprogs e2fsprogs xorriso busybox-static cpio zstd
      sbsigntool binutils openssl python3)
need=()
for t in qemu-img sgdisk mkfs.vfat mkfs.exfat mkfs.ext4 mcopy xorriso cpio zstd sbverify \
         objcopy openssl grub-mkstandalone curl cc python3; do
  command -v "$t" >/dev/null 2>&1 || [ -x "/usr/sbin/$t" ] || [ -x "/sbin/$t" ] || need+=("$t")
done
[ -f /usr/share/OVMF/OVMF_VARS_4M.ms.fd ] || need+=(ovmf-generic)
{ command -v busybox >/dev/null && ! ldd "$(command -v busybox)" >/dev/null 2>&1; } || need+=(busybox-static)
if [ "$(id -u)" = 0 ]; then
  # Package lists are needed anyway (apt-get download of shim/grub/kernel).
  if [ -z "$(find /var/lib/apt/lists -maxdepth 1 -name "*Packages*" 2>/dev/null | head -n 1)" ] \
     || [ -n "$(find /var/lib/apt/lists -maxdepth 1 -name '*Packages*' -mmin +1440 2>/dev/null | head -n 1)" ] \
     || [ ${#need[@]} -gt 0 ]; then
    log "apt-get update"
    apt-get update -q >/dev/null
  fi
  if [ ${#need[@]} -gt 0 ]; then
    log "installing: ${PKGS[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${PKGS[@]}" >/dev/null
  fi
elif [ ${#need[@]} -gt 0 ]; then
  die "missing: ${need[*]} — as root: apt-get install ${PKGS[*]}"
fi

# Networks that intercept TLS: trust an extra CA bundle (run-on-mac.sh --ca-bundle).
if [ -n "${CI_STICK_SB_EXTRA_CA:-}" ]; then
  [ -f "$CI_STICK_SB_EXTRA_CA" ] || die "CI_STICK_SB_EXTRA_CA=$CI_STICK_SB_EXTRA_CA: no such file"
  export SSL_CERT_FILE="$CI_STICK_SB_EXTRA_CA" CURL_CA_BUNDLE="$CI_STICK_SB_EXTRA_CA" \
         CARGO_HTTP_CAINFO="$CI_STICK_SB_EXTRA_CA"
fi

# --- ci-stick -------------------------------------------------------------------------
if [ -n "${CI_STICK_BIN:-}" ]; then
  CI="$CI_STICK_BIN"
else
  if ! command -v cargo >/dev/null; then
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
    export PATH="$CARGO_HOME/bin:$PATH"
    if ! command -v cargo >/dev/null; then
      log "installing Rust (rustup, minimal profile) into $CARGO_HOME"
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --no-modify-path >/dev/null
    fi
  fi
  log "building ci-stick"
  target="${CARGO_TARGET_DIR:-$STICK/target}"
  CARGO_TARGET_DIR="$target" cargo build --release --locked --quiet --manifest-path "$STICK/Cargo.toml"
  CI="$target/release/ci-stick"
fi
"$CI" --version

# --- Secure Boot chain + firmware -------------------------------------------------------
log "fetching the signed boot chain (apt)"
"$STICK/scripts/fetch-signed-boot.sh" "$OUT/signed-boot"

log "copying OVMF firmware"
mkdir -p "$OUT/firmware"
# 26.04's `ovmf` is a metapackage; the firmware files are in ovmf-generic.
ovmf_ver="$(dpkg-query -W -f='${Version}' ovmf-generic)"
{
  echo "# OVMF firmware copied from Ubuntu 26.04's ovmf-generic package by build-in-container.sh."
  echo "ovmf-generic=$ovmf_ver"
  for f in OVMF_CODE_4M.secboot.fd OVMF_VARS_4M.ms.fd OVMF_CODE_4M.fd OVMF_VARS_4M.fd; do
    cp "/usr/share/OVMF/$f" "$OUT/firmware/$f"
    echo "$f.sha256=$(sha256sum < "$OUT/firmware/$f" | cut -d' ' -f1)"
  done
} > "$OUT/firmware/firmware.lock"

{
  echo "# Companion Stick Secure Boot test build — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ci-stick: $("$CI" --version)"
  echo "ovmf: $ovmf_ver"
  grep -E '^(shim-signed|grub-efi-amd64-signed)=' "$OUT/signed-boot/signed-boot.lock"
} > "$INFO"

KEY="$WORK/dev"
[ -f "$KEY.key" ] || "$CI" dev keygen --out "$KEY" >/dev/null 2>&1

# make_stick <name> <boot-image> <efi-dir-or-"dev"> <extra-cmdline>
make_stick() {
  local name="$1" boot="$2" efi="$3" cmdline="$4" stage="$WORK/stage-$1"
  rm -rf "$stage"; mkdir -p "$stage/boot" "$stage/efi"
  cp "$boot" "$stage/boot/$(basename "$boot")"
  if [ "$efi" = dev ]; then
    "$STICK/scripts/build-grub-efi.sh" "$stage/efi/BOOTX64.EFI" >/dev/null
  else
    cp "$efi"/shimx64.efi "$efi"/grubx64.efi "$efi"/mmx64.efi "$stage/efi/"
  fi
  "$CI" lock "$stage" --id "companion-stick-sb-$name" --version 0.0.0-test --size "$STICK_SIZE" \
    --created-at 2026-01-01T00:00:00Z >/dev/null
  "$CI" dev sign "$stage" --key "$KEY.key" >/dev/null
  "$CI" verify "$stage" --pubkey "$KEY.pub" | tee -a "$INFO" | grep -E '^(Boot|Result)'
  rm -f "$WORK/$name.img"
  "$CI" flash "$stage" --pubkey "$KEY.pub" --image "$WORK/$name.img" --size "$STICK_SIZE" \
    --dry-run > "$OUT/plan-$name.txt"
  "$CI" flash "$stage" --pubkey "$KEY.pub" --image "$WORK/$name.img" --size "$STICK_SIZE" \
    --extra-cmdline "$cmdline" --work-dir "$WORK" >/dev/null 2>"$WORK/flash-$name.log" \
    || { cat "$WORK/flash-$name.log" >&2; die "flash $name"; }
  echo "flashed $name.img: $(grep -m1 '^Boot' "$OUT/plan-$name.txt")"
  qemu-img convert -O qcow2 "$WORK/$name.img" "$OUT/$name.qcow2"
  rm -f "$WORK/$name.img"
  rm -rf "${stage:?}/boot"
  echo "wrote $OUT/$name.qcow2 ($(du -h "$OUT/$name.qcow2" | cut -f1) on disk, $STICK_SIZE virtual)"
}

if [ -n "$ISO" ]; then
  [ -f "$ISO" ] || die "--iso $ISO: no such file"
  log "Secure Boot chain stick with $(basename "$ISO") in slot A"
  make_stick iso-signed "$ISO" "$OUT/signed-boot" "console=ttyS0,115200 console=tty0"
  echo "done: $OUT/iso-signed.qcow2"
  exit 0
fi

# --- test boot image with a Canonical-signed kernel -------------------------------------
log "building the Secure Boot probe test image (slot A)"
export CI_STICK_TEST_CACHE="${CI_STICK_TEST_CACHE:-$HOME/.cache/ci-stick-test}"
CI_STICK_TEST_SB_PROBE=1 "$STICK/tests/qemu/build-test-boot-image.sh" A "$WORK/sb-test-A.iso"
kernel="$CI_STICK_TEST_CACHE/vmlinuz"
kver="$(cat "$CI_STICK_TEST_CACHE/kernel-version")"
sbverify --list "$kernel" | grep -q "^signature 1" || die "kernel $kver carries no signature"
sbverify --cert "$OUT/signed-boot/canonical-uefi-ca.pem" "$kernel" >/dev/null 2>&1 \
  || die "kernel $kver does not verify against the Canonical CA in shim"
echo "kernel linux-image-$kver: Authenticode signature verifies against the Canonical CA (from shim)"
echo "kernel: linux-image-$kver (verified against the Canonical CA embedded in shim)" >> "$INFO"

log "signed stick (shim -> Canonical GRUB)"
make_stick signed "$WORK/sb-test-A.iso" "$OUT/signed-boot" "console=ttyS0,115200 panic=5"
log "unsigned stick (development GRUB)"
make_stick unsigned "$WORK/sb-test-A.iso" dev "console=ttyS0,115200 panic=5"

log "done"
ls -la "$OUT"
