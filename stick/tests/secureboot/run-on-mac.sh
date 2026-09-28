#!/usr/bin/env bash
# Companion Stick Secure Boot test — one command on a Mac (Apple Silicon or Intel).
# Also runs on Linux. Local only: this is deliberately not part of any GitHub workflow.
#
#   stick/tests/secureboot/run-on-mac.sh               build (in Docker) + boot tests A/B/C
#   stick/tests/secureboot/run-on-mac.sh --show        same, with a QEMU window per boot
#   stick/tests/secureboot/run-on-mac.sh --skip-build  boot tests only, reusing out/
#   stick/tests/secureboot/run-on-mac.sh --iso ~/Downloads/ubuntu-24.04.4-desktop-amd64.iso
#                                                      real ISO in slot A, SB on, in a window
#
# Prerequisites (macOS):
#   Docker Desktop, running:   brew install --cask docker   (then open Docker.app once)
#   QEMU:                      brew install qemu
# About 3 GB free disk (the Docker image, a Rust toolchain cache volume, two small qcow2
# sticks); --iso needs ~8 GB more.
#
# 1. Build, inside `docker run --platform linux/amd64 ubuntu:24.04`
#    (build-in-container.sh): ci-stick, the signed chain from Ubuntu's archive via apt
#    (fetch-signed-boot.sh), a test boot image with a Canonical-signed kernel, then two
#    64 GB sticks as qcow2: signed.qcow2 (shim -> Canonical GRUB) and unsigned.qcow2
#    (unsigned development GRUB), plus Ubuntu's OVMF firmware (Secure Boot build with
#    Microsoft keys enrolled, and the plain build). Rust and the kernel download are cached
#    in the Docker volume "ci-stick-sb-cache", so re-runs are much faster.
# 2. Boot natively with Homebrew's qemu-system-x86_64 (HVF on Intel Macs, TCG on Apple
#    Silicon), the stick attached as a USB mass-storage device:
#      A  Secure Boot ON,  signed chain:   boots, secureboot=1, slot A, boot-count=1;
#                                          boots again -> boot-count=2 (persistence)
#      B  Secure Boot ON,  unsigned chain: must NOT reach the kernel (firmware refuses it)
#      C  Secure Boot OFF, signed chain:   still boots, secureboot=0
#    Results: a PASS/FAIL table, serial logs in stick/tests/secureboot/out/run/.
#
# Options:
#   --show            open a QEMU window for every boot (cocoa on macOS) — slower
#   --skip-build      reuse stick/tests/secureboot/out/ from an earlier build
#   --iso PATH        build a signed-chain stick with PATH in slot A and boot it, SB on
#   --accel NAME      force hvf, kvm or tcg
#   --timeout SECS    per-boot limit (default 240 with hvf/kvm, 900 with tcg)
#   --docker          on Linux, build in Docker even on an Ubuntu 24.04 host
#   --ca-bundle FILE  extra PEM CA bundle to trust inside the build container, for
#                     networks that intercept TLS (corporate proxies)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="$HERE/out"
RUN="$OUT/run"
SHOW=0; SKIP_BUILD=0; ISO=""; ACCEL_NAME=""; TIMEOUT=""; FORCE_DOCKER=0; CA_BUNDLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --show) SHOW=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --iso) ISO="${2:?--iso needs a path}"; shift 2 ;;
    --accel) ACCEL_NAME="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --docker) FORCE_DOCKER=1; shift ;;
    --ca-bundle) CA_BUNDLE="${2:?--ca-bundle needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

OS="$(uname -s)"; ARCH="$(uname -m)"
say() { echo "==> $*"; }
die() { echo "run-on-mac.sh: $*" >&2; exit 2; }

# --- prerequisites --------------------------------------------------------------------
QEMU="$(command -v qemu-system-x86_64 || true)"
if [ -z "$QEMU" ]; then
  if [ "$OS" = Darwin ]; then
    die "qemu-system-x86_64 not found. Install it with:  brew install qemu"
  else
    die "qemu-system-x86_64 not found. Install it with:  sudo apt-get install qemu-system-x86"
  fi
fi

use_docker=0
if [ "$SKIP_BUILD" = 0 ]; then
  codename="$( (. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}") || true)"
  if [ "$OS" = Darwin ] || [ "$FORCE_DOCKER" = 1 ] || [ "$codename" != noble ]; then
    use_docker=1
    command -v docker >/dev/null 2>&1 || die "docker not found. On macOS install Docker Desktop:
    brew install --cask docker
  then start Docker.app once (whale icon in the menu bar) and re-run."
    docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker Desktop
  (open -a Docker), wait for it to say 'running', then re-run."
  fi
fi

# --- 1. build ------------------------------------------------------------------------
if [ "$SKIP_BUILD" = 0 ]; then
  build_args=(--out "$OUT")
  docker_extra=()
  if [ -n "$CA_BUNDLE" ]; then
    [ -f "$CA_BUNDLE" ] || die "--ca-bundle $CA_BUNDLE: no such file"
    CA_BUNDLE="$(cd "$(dirname "$CA_BUNDLE")" && pwd)/$(basename "$CA_BUNDLE")"
    docker_extra+=(-v "$CA_BUNDLE:/extra-ca.pem:ro" -e CI_STICK_SB_EXTRA_CA=/extra-ca.pem)
  fi
  if [ -n "$ISO" ]; then
    [ -f "$ISO" ] || die "--iso $ISO: no such file"
    ISO="$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")"
    if [ "$use_docker" = 1 ]; then
      docker_extra+=(-v "$(dirname "$ISO"):/iso:ro")
      build_args=(--out /src/stick/tests/secureboot/out --iso "/iso/$(basename "$ISO")")
    else
      build_args+=(--iso "$ISO")
    fi
  elif [ "$use_docker" = 1 ]; then
    build_args=(--out /src/stick/tests/secureboot/out)
  fi
  if [ "$use_docker" = 1 ]; then
    say "building in Docker (ubuntu:24.04, linux/amd64) — first run takes a while (Rust toolchain, kernel download)"
    docker run --rm --platform linux/amd64 \
      -v "$REPO":/src \
      -v ci-stick-sb-cache:/cache \
      ${docker_extra[@]+"${docker_extra[@]}"} \
      -e CARGO_HOME=/cache/cargo -e RUSTUP_HOME=/cache/rustup \
      -e CARGO_TARGET_DIR=/cache/target -e CI_STICK_TEST_CACHE=/cache/kernel \
      -e CI_STICK_SB_WORK=/work \
      ubuntu:24.04 bash /src/stick/tests/secureboot/build-in-container.sh "${build_args[@]}" \
      || die "the Docker build failed (see above)"
  else
    say "building natively (Ubuntu 24.04 host)"
    "$HERE/build-in-container.sh" "${build_args[@]}" || die "build-in-container.sh failed"
  fi
fi

FW="$OUT/firmware"
for f in OVMF_CODE_4M.secboot.fd OVMF_VARS_4M.ms.fd OVMF_CODE_4M.fd OVMF_VARS_4M.fd; do
  [ -f "$FW/$f" ] || die "$FW/$f missing — run without --skip-build first"
done

# --- accelerator ----------------------------------------------------------------------
if [ -z "$ACCEL_NAME" ]; then
  if [ "$OS" = Darwin ] && [ "$ARCH" = x86_64 ]; then ACCEL_NAME=hvf
  elif [ "$OS" = Linux ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL_NAME=kvm
  else ACCEL_NAME=tcg
  fi
fi
set_accel() {
  case "$1" in
    hvf|kvm) ACCEL=(-accel "$1" -cpu host) ;;
    tcg) ACCEL=(-accel tcg) ;;
    *) die "unknown accelerator $1" ;;
  esac
  ACCEL_NAME="$1"
  if [ -z "$TIMEOUT" ]; then
    if [ "$1" = tcg ]; then BOOT_TIMEOUT=900; else BOOT_TIMEOUT=240; fi
  else
    BOOT_TIMEOUT="$TIMEOUT"
  fi
}
set_accel "$ACCEL_NAME"
if [ "$SHOW" = 1 ] || [ -n "$ISO" ]; then
  if [ "$OS" = Darwin ]; then DISPLAY_ARGS=(-display cocoa)
  elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then DISPLAY_ARGS=()
  else
    DISPLAY_ARGS=(-display none)
    say "no graphical display here: running headless, follow the serial log instead"
  fi
else
  DISPLAY_ARGS=(-display none)
fi

mkdir -p "$RUN"

# boot_vm <name> <qcow2> <sb|nosb> <timeout> <stop-regex>
# Runs QEMU with the stick as USB storage, serial console -> $RUN/<name>.log. Stops when
# QEMU exits (the test init powers off), on timeout, or a few seconds after the serial
# log matches <stop-regex> (firmware refusal, GRUB shell).
boot_vm() {
  local name="$1" disk="$2" fw="$3" limit="$4" stop="$5"
  local log="$RUN/$name.log" vars="$RUN/$name-vars.fd" code machine
  local extra=()
  if [ "$fw" = sb ]; then
    code="$FW/OVMF_CODE_4M.secboot.fd"; cp "$FW/OVMF_VARS_4M.ms.fd" "$vars"
    machine="q35,smm=on"; extra=(-global "driver=cfi.pflash01,property=secure,value=on")
  else
    code="$FW/OVMF_CODE_4M.fd"; cp "$FW/OVMF_VARS_4M.fd" "$vars"
    machine="q35"
  fi
  rm -f "$log"; : > "$log"
  local mem=1024 smp=2
  if [ -n "$ISO" ]; then mem=4096; smp=4; fi
  echo "    qemu: $name, accel $ACCEL_NAME, firmware $(basename "$code"), limit ${limit}s, serial -> $log"
  "$QEMU" -machine "$machine" "${ACCEL[@]}" -m "$mem" -smp "$smp" \
    ${extra[@]+"${extra[@]}"} \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$code" \
    -drive "if=pflash,format=raw,unit=1,file=$vars" \
    -device qemu-xhci,id=xhci \
    -drive "if=none,id=stick,format=qcow2,file=$disk" \
    -device usb-storage,bus=xhci.0,drive=stick,bootindex=0 \
    -net none -no-reboot -monitor none -serial "file:$log" \
    ${DISPLAY_ARGS[@]+"${DISPLAY_ARGS[@]}"} 2> "$RUN/$name.qemu.err" &
  local pid=$! start=$SECONDS seen=""
  BOOT_TIMED_OUT=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$limit" -gt 0 ] && [ $((SECONDS - start)) -ge "$limit" ]; then
      BOOT_TIMED_OUT=1; kill "$pid" 2>/dev/null; break
    fi
    if [ -n "$stop" ] && [ -z "$seen" ] && grep -aEq "$stop" "$log" 2>/dev/null; then
      seen=$SECONDS
    fi
    if [ -n "$seen" ] && [ $((SECONDS - seen)) -ge 5 ]; then kill "$pid" 2>/dev/null; break; fi
    sleep 1
  done
  wait "$pid" 2>/dev/null
  BOOT_SECONDS=$((SECONDS - start))
  echo "    $name: finished after ${BOOT_SECONDS}s$([ "$BOOT_TIMED_OUT" = 1 ] && echo ' (TIMED OUT)')"
  # Only the interesting part of each line (GRUB's menu redraws are escape-code soup).
  tr -d '\r' < "$log" | tr '\033' '\n' \
    | grep -a -o -E 'CI-STICK-[A-Z]+ [^[:cntrl:]]*|[^[:cntrl:]]*(Access Denied|Security Violation)|grub> ?$' \
    | sed "s/^/      serial: /" | head -n 12
  if [ -s "$RUN/$name.qemu.err" ]; then sed 's/^/      qemu: /' "$RUN/$name.qemu.err" | head -n 5; fi
}

# --- ISO mode ---------------------------------------------------------------------------
if [ -n "$ISO" ]; then
  [ -f "$OUT/iso-signed.qcow2" ] || die "$OUT/iso-signed.qcow2 missing (build failed?)"
  cat <<EOF

Booting $(basename "$ISO") from a Companion Stick (Secure Boot chain) with Secure Boot ON.
The stick is $OUT/iso-signed.qcow2 (persistence is kept across runs of this command).
Under TCG (Apple Silicon) the desktop takes many minutes to appear; be patient.

What to look for:
  * The GRUB menu says "Companion OS (slot A)" — that is Canonical's signed GRUB, loaded by
    the Microsoft-signed shim, reading the stick's own grub.cfg.
  * The desktop comes up. In a terminal:  mokutil --sb-state   ->  "SecureBoot enabled"
    (also: sudo dmesg | grep -i secure  ->  "Secure boot enabled", lockdown lines).
  * Persistence: create a file in ~, power off from the menu, run this command again with
    --skip-build --iso <same path>; the file must still be there.
  * Serial log: $RUN/iso.log (firmware + GRUB; the kernel boots with "quiet", so only
    its warnings show there — watch the window)
Close the QEMU window (or power off the guest) to finish.

EOF
  boot_vm iso "$OUT/iso-signed.qcow2" sb 0 ""
  exit 0
fi

# --- A/B/C ----------------------------------------------------------------------------
for f in signed.qcow2 unsigned.qcow2; do
  [ -f "$OUT/$f" ] || die "$OUT/$f missing — run without --skip-build first"
  cp "$OUT/$f" "$RUN/$f"   # fresh persistence for every run
done

RESULTS=()
FAILED=0
check() { # check <label> <log> <fixed-string> [absent]
  local label="$1" log="$2" want="$3" mode="${4:-present}"
  if tr -d '\r' < "$log" | grep -aqF -- "$want"; then found=1; else found=0; fi
  if { [ "$mode" = present ] && [ $found = 1 ]; } || { [ "$mode" = absent ] && [ $found = 0 ]; }; then
    RESULTS+=("PASS  $label"); return 0
  fi
  RESULTS+=("FAIL  $label"); FAILED=1; return 1
}

FAIL_EARLY='Access Denied|Security Violation|grub> ?$'
echo
say "A1: Secure Boot ON, signed chain (shim -> Canonical GRUB)"
boot_vm A1 "$RUN/signed.qcow2" sb "$BOOT_TIMEOUT" "$FAIL_EARLY"
# HVF on some Intel Macs cannot run the SMM Secure Boot firmware: fall back to TCG once.
if [ "$ACCEL_NAME" != tcg ] && [ "$BOOT_SECONDS" -lt 15 ] && ! grep -aq . "$RUN/A1.log"; then
  say "QEMU with $ACCEL_NAME produced no output; retrying A1 with TCG"
  set_accel tcg
  cp "$OUT/signed.qcow2" "$RUN/signed.qcow2"
  boot_vm A1 "$RUN/signed.qcow2" sb "$BOOT_TIMEOUT" "$FAIL_EARLY"
fi
check "A  SB on,  signed chain: secureboot=1 slot=A cmdline_slot=A" "$RUN/A1.log" \
  "CI-STICK-SB secureboot=1 slot=A cmdline_slot=A"
check "A  SB on,  signed chain: boot-count=1" "$RUN/A1.log" "CI-STICK-TEST boot-count=1 "

say "A2: reboot, same stick (persistence)"
boot_vm A2 "$RUN/signed.qcow2" sb "$BOOT_TIMEOUT" "$FAIL_EARLY"
check "A  SB on,  signed chain, reboot: secureboot=1 slot=A" "$RUN/A2.log" \
  "CI-STICK-SB secureboot=1 slot=A cmdline_slot=A"
check "A  SB on,  signed chain, reboot: boot-count=2 (persistence)" "$RUN/A2.log" \
  "CI-STICK-TEST boot-count=2 "

say "B: Secure Boot ON, unsigned development chain (must be refused)"
b_limit="$BOOT_TIMEOUT"; [ "$b_limit" -gt 300 ] && b_limit=300
boot_vm B "$RUN/unsigned.qcow2" sb "$b_limit" "No bootable option|Access Denied|Security Violation"
if check "B  SB on,  unsigned chain: kernel NOT reached (correctly rejected)" "$RUN/B.log" \
     "CI-STICK-" absent; then
  if tr -d '\r' < "$RUN/B.log" | grep -aq "Access Denied"; then
    RESULTS+=("PASS  B  firmware refused the unsigned loader: \"Access Denied\" on the serial console")
  else
    RESULTS+=("note  B  no 'Access Denied' line in the serial log (firmware may not print it)")
  fi
fi

say "C: Secure Boot OFF (non-SB firmware), signed chain"
boot_vm C "$RUN/signed.qcow2" nosb "$BOOT_TIMEOUT" "grub> ?$"
check "C  SB off, signed chain: secureboot=0 slot=A cmdline_slot=A" "$RUN/C.log" \
  "CI-STICK-SB secureboot=0 slot=A cmdline_slot=A"
check "C  SB off, signed chain: boot-count=3" "$RUN/C.log" "CI-STICK-TEST boot-count=3 "

{
  echo
  echo "================ Companion Stick Secure Boot test ================"
  echo "host: $OS $ARCH, qemu: $("$QEMU" --version | head -n 1), accel: $ACCEL_NAME"
  [ -f "$OUT/build-info.txt" ] && grep -E '^(shim-signed|grub-efi-amd64-signed|ovmf|kernel)' "$OUT/build-info.txt" | sed 's/^/build: /'
  printf '%s\n' "${RESULTS[@]}"
  echo "serial logs: $RUN/{A1,A2,B,C}.log"
  if [ "$FAILED" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
} | tee "$RUN/results.txt"
exit "$FAILED"
