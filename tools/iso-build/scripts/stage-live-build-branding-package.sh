#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/output/packages}"
LIVE_BUILD_PACKAGES_DIR="${2:-$REPO_ROOT/config/packages.chroot}"

mkdir -p "$LIVE_BUILD_PACKAGES_DIR"

shopt -s nullglob
matches=("$OUTPUT_DIR"/mydistro-branding_*.deb)
shopt -u nullglob

if [[ ${#matches[@]} -eq 0 ]]; then
    echo "[ERROR] No mydistro-branding package found in: $OUTPUT_DIR"
    echo "[HINT] Run: ./tools/iso-build/scripts/build-packages.sh $OUTPUT_DIR"
    exit 1
fi

latest_deb="$(ls -1t "${matches[@]}" | head -n 1)"
cp "$latest_deb" "$LIVE_BUILD_PACKAGES_DIR/"

echo "[+] Staged package for live-build: $LIVE_BUILD_PACKAGES_DIR/$(basename "$latest_deb")"
