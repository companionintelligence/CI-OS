#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ISO_PATH=""

if ls "$REPO_ROOT/dist"/*.iso >/dev/null 2>&1; then
  ISO_PATH=$(ls -1 "$REPO_ROOT/dist"/*.iso | head -n 1)
elif ls "$REPO_ROOT/build/cubic/iso/output"/*.iso >/dev/null 2>&1; then
  ISO_PATH=$(ls -1 "$REPO_ROOT/build/cubic/iso/output"/*.iso | head -n 1)
fi

if [ -z "$ISO_PATH" ]; then
  echo "No ISO found; skipping ISO checks"
  exit 0
fi

if ! command -v file >/dev/null 2>&1; then
  echo "file command not found; skipping ISO checks" >&2
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "sudo not available; skipping ISO mount checks" >&2
    SUDO=""
  fi
else
  SUDO=""
fi

echo "Running ISO checks for: $ISO_PATH"

FILE_INFO=$(file "$ISO_PATH" || true)
if ! echo "$FILE_INFO" | grep -q "ISO 9660"; then
  echo "ISO format check failed" >&2
  echo "$FILE_INFO" >&2
  exit 1
fi

echo "ISO format OK"

if [ -n "$SUDO" ]; then
  MOUNT_POINT="/tmp/ci-os-test-mount"
  $SUDO mkdir -p "$MOUNT_POINT"
  $SUDO mount -o loop "$ISO_PATH" "$MOUNT_POINT"

  ESSENTIAL_FILES=(
    "casper/vmlinuz"
    "casper/initrd"
    "casper/filesystem.squashfs"
    ".disk/info"
  )

  for file_path in "${ESSENTIAL_FILES[@]}"; do
    if [ -f "$MOUNT_POINT/$file_path" ]; then
      echo "Found: $file_path"
    else
      echo "Missing: $file_path" >&2
      $SUDO umount "$MOUNT_POINT" || true
      exit 1
    fi
  done

  $SUDO umount "$MOUNT_POINT"
  $SUDO rmdir "$MOUNT_POINT" || true
else
  echo "Skipping mount-based checks (no sudo)"
fi

echo "ISO checks passed"
