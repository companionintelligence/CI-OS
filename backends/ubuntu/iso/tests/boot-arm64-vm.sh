#!/usr/bin/env bash
#=============================================================================
# Boot a Companion OS arm64 ISO in a QEMU virtual machine at near-native speed, photograph it and stop it.
#
# The harness of the arm64 runs of 2026-10-19 (docs/architecture/arm64.md, docs/evidence/2026-10-19-ubuntu-arm64/): a display-less
# QEMU with the machine's own accelerator (HVF on an Apple-silicon Mac), Homebrew's edk2 firmware, the ISO attached as a USB
# mass-storage drive (what a flashed stick looks like to the firmware) and, optionally, an NVMe disk to install to. The guest is
# driven over QMP: screenshots, keys and the mouse with lib/qmp-drive.py, the serial console in a log file.
#
#   boot-arm64-vm.sh start ISO [DISK.qcow2]   start the VM (ISO "-" boots the install target alone, with no medium)
#   boot-arm64-vm.sh shot FILE.png            screendump of the guest as PNG
#   boot-arm64-vm.sh status                   run state
#   boot-arm64-vm.sh stop                     power the VM off at once
#   boot-arm64-vm.sh info                     print the state directory, QMP socket and serial log
#
# DISK is created (sparse, 64 GiB) when it does not exist. It must be a file: a block or character device is refused, because a
# test must never be able to write to a real disk. Environment: CI_VM_DIR (state directory, keep the path short: a QMP socket path
# is limited to 104 bytes on macOS; default /tmp/ci-arm64-vm), CI_VM_CPUS (6), CI_VM_MEM (MiB, 8192), CI_VM_ACCEL (hvf on
# macOS, kvm on Linux, else tcg: software emulation, an order of magnitude slower).
#
# Needs qemu-system-aarch64, qemu-img, python3 and the edk2 aarch64 firmware (macOS: `brew install qemu`; Debian and Ubuntu:
# qemu-system-arm, qemu-efi-aarch64). There is no Secure Boot firmware with Homebrew's qemu, so this boots without Secure Boot.
# Exit 2 ("cannot run here") where a tool or the firmware is missing. Verified on an Apple-silicon Mac with HVF [V]; the Linux
# paths (kvm, AAVMF firmware) are read from the packages' documentation and were not run [I].
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVE="$HERE/lib/qmp-drive.py"
DIR="${CI_VM_DIR:-/tmp/ci-arm64-vm}"
SOCK="$DIR/qmp.sock"
PIDFILE="$DIR/qemu.pid"
SERIAL="$DIR/serial.log"

die() { echo "boot-arm64-vm: $*" >&2; exit 1; }
cannot() { echo "cannot run here: $*" >&2; exit 2; }

usage() { sed -n '/^#   boot-arm64-vm.sh/p' "${BASH_SOURCE[0]}" | sed 's/^#//' >&2; exit 64; }

firmware() {
  # sets CODE and VARS_TEMPLATE
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null 2>&1 || cannot "Homebrew is missing (brew install qemu)"
      local q; q="$(brew --prefix qemu 2>/dev/null)/share/qemu"
      CODE="$q/edk2-aarch64-code.fd"; VARS_TEMPLATE="$q/edk2-arm-vars.fd" ;;
    *)
      CODE="/usr/share/AAVMF/AAVMF_CODE.fd"; VARS_TEMPLATE="/usr/share/AAVMF/AAVMF_VARS.fd" ;;
  esac
  [ -f "$CODE" ] || cannot "the edk2 aarch64 firmware is missing: $CODE"
  [ -f "$VARS_TEMPLATE" ] || cannot "the edk2 variable store is missing: $VARS_TEMPLATE"
}

accel() {
  if [ -n "${CI_VM_ACCEL:-}" ]; then echo "$CI_VM_ACCEL"; return; fi
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) echo hvf ;;
    Linux/aarch64|Linux/arm64) echo kvm ;;
    *) echo tcg ;;
  esac
}

alive() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

cmd_start() {
  local iso="${1:-}" disk="${2:-}"
  [ -n "$iso" ] || usage
  command -v qemu-system-aarch64 >/dev/null 2>&1 || cannot "qemu-system-aarch64 is missing"
  command -v qemu-img >/dev/null 2>&1 || cannot "qemu-img is missing"
  command -v python3 >/dev/null 2>&1 || cannot "python3 is missing"
  firmware
  [ "$iso" = "-" ] || [ -f "$iso" ] || die "no such ISO: $iso"
  [ -n "$disk" ] || [ "$iso" != "-" ] || die "ISO \"-\" needs a DISK to boot"
  if [ -n "$disk" ]; then
    if [ -b "$disk" ] || [ -c "$disk" ]; then die "$disk is a device; only a file is accepted (a test must never write to a real disk)"; fi
    [ -f "$disk" ] || qemu-img create -q -f qcow2 "$disk" 64G
  fi
  if alive; then die "a VM is already running (pid $(cat "$PIDFILE")); stop it first: $0 stop"; fi
  mkdir -p "$DIR"
  [ -f "$DIR/vars.fd" ] || cp "$VARS_TEMPLATE" "$DIR/vars.fd"
  rm -f "$SOCK"
  local acc; acc="$(accel)"
  local cpu="host"; [ "$acc" = tcg ] && cpu="max"
  # The ISO is a USB drive (bootindex 0); the install target an NVMe disk (bootindex 1, or 0 when it boots alone).
  local media=() target=() idx=1
  if [ "$iso" != "-" ]; then
    media=(-drive "if=none,id=iso,format=raw,readonly=on,file=$iso" -device "usb-storage,drive=iso,bootindex=0")
  else
    idx=0
  fi
  if [ -n "$disk" ]; then
    target=(-drive "if=none,id=target,format=qcow2,file=$disk" -device "nvme,drive=target,serial=ci-target,bootindex=$idx")
  fi
  qemu-system-aarch64 -name ci-arm64 -pidfile "$PIDFILE" -daemonize \
    -machine virt,gic-version=3 -accel "$acc" -cpu "$cpu" -smp "${CI_VM_CPUS:-6}" -m "${CI_VM_MEM:-8192}" \
    -drive "if=pflash,format=raw,readonly=on,file=$CODE" -drive "if=pflash,format=raw,file=$DIR/vars.fd" \
    -device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet \
    -nic user,model=virtio-net-pci \
    -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
    -qmp "unix:$SOCK,server=on,wait=off" -serial "file:$SERIAL" -display none \
    ${media[@]+"${media[@]}"} ${target[@]+"${target[@]}"}
  local i=0
  while [ ! -S "$SOCK" ]; do
    i=$((i + 1)); [ "$i" -le 50 ] || die "the QMP socket did not appear: $SOCK"; sleep 0.2
  done
  echo "started: pid $(cat "$PIDFILE"), accelerator $acc, ISO $iso${disk:+, disk $disk}"
  echo "state: $DIR   qmp: $SOCK   serial: $SERIAL"
  echo "drive it with: $DRIVE $SOCK shot|key|type|click|status|quit"
}

cmd_shot() {
  [ -n "${1:-}" ] || usage
  [ -S "$SOCK" ] || die "no VM is running (no $SOCK)"
  python3 -I "$DRIVE" "$SOCK" shot "$1"
}

cmd_status() {
  [ -S "$SOCK" ] || die "no VM is running (no $SOCK)"
  python3 -I "$DRIVE" "$SOCK" status
}

cmd_stop() {
  if [ -S "$SOCK" ]; then python3 -I "$DRIVE" "$SOCK" quit >/dev/null 2>&1 || true; fi
  local i=0
  while alive && [ "$i" -lt 25 ]; do i=$((i + 1)); sleep 0.2; done
  if alive; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
  rm -f "$SOCK" "$PIDFILE"
  echo "stopped"
}

case "${1:-}" in
  start)  shift; cmd_start "$@" ;;
  shot)   shift; cmd_shot "$@" ;;
  status) cmd_status ;;
  stop)   cmd_stop ;;
  info)   echo "state: $DIR"; echo "qmp: $SOCK"; echo "serial: $SERIAL" ;;
  *) usage ;;
esac
