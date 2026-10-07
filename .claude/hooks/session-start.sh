#!/bin/bash
# Cloud-session setup: install what ./core/lib/check-repo.sh needs (shellcheck, yamllint;
# bash and python3 ship with the image) and, where apt exists, what the Companion Stick
# flash tests and QEMU harness need (stick/tests/qemu/run.sh). Idempotent — skips anything
# already present, and the container is cached after this runs, so later sessions pay nothing.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

missing=()
command -v shellcheck >/dev/null 2>&1 || missing+=(shellcheck)
command -v yamllint >/dev/null 2>&1 || missing+=(yamllint)

# Companion Stick (apt only): binary -> package. sbin tools may be off a user's PATH.
stick=()
if command -v apt-get >/dev/null 2>&1; then
  for pair in sgdisk:gdisk mkfs.vfat:dosfstools mkfs.exfat:exfatprogs mkfs.ext4:e2fsprogs \
              mcopy:mtools xorriso:xorriso cpio:cpio zstd:zstd grub-mkstandalone:grub-common \
              qemu-system-x86_64:qemu-system-x86; do
    bin="${pair%%:*}"
    command -v "$bin" >/dev/null 2>&1 || [ -x "/usr/sbin/$bin" ] || [ -x "/sbin/$bin" ] \
      || stick+=("${pair##*:}")
  done
  [ -d /usr/lib/grub/x86_64-efi ] || stick+=(grub-efi-amd64-bin)
  [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || stick+=(ovmf)
  { [ -x /bin/busybox ] && ! ldd /bin/busybox >/dev/null 2>&1; } || stick+=(busybox-static)
fi
[ ${#missing[@]} -eq 0 ] && [ ${#stick[@]} -eq 0 ] && exit 0

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

if [ ${#missing[@]} -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 \
      || { $SUDO apt-get update -qq >/dev/null 2>&1 && $SUDO apt-get install -y -qq "${missing[@]}" >/dev/null; }
  else
    # No apt: both tools are on PyPI (shellcheck-py bundles the binary).
    pkgs=()
    for m in "${missing[@]}"; do [ "$m" = shellcheck ] && pkgs+=(shellcheck-py) || pkgs+=("$m"); done
    python3 -m pip install -q "${pkgs[@]}"
  fi
fi

if [ ${#stick[@]} -gt 0 ]; then
  # Best effort: the stick tests skip (cargo) or report missing tools (run.sh) without them.
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get install -y -qq "${stick[@]}" >/dev/null 2>&1 \
    || { $SUDO apt-get update -qq >/dev/null 2>&1 \
         && $SUDO apt-get install -y -qq "${stick[@]}" >/dev/null 2>&1; } \
    || echo "session-start: could not install ${stick[*]} (Companion Stick tests)" >&2
fi

for m in "${missing[@]}"; do
  command -v "$m" >/dev/null 2>&1 || { echo "session-start: failed to install $m" >&2; exit 1; }
done
