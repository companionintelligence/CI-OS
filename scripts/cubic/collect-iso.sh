#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_env.sh
source "$SCRIPT_DIR/_env.sh"

DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"

ISO_PATH=$(ls -1 "$CUBIC_ISO_OUTPUT_DIR"/*.iso 2>/dev/null | head -n 1 || true)
if [ -z "$ISO_PATH" ]; then
  echo "No ISO found in $CUBIC_ISO_OUTPUT_DIR" >&2
  exit 1
fi

ISO_NAME="$(basename "$ISO_PATH")"
cp -a "$ISO_PATH" "$DIST_DIR/$ISO_NAME"

( cd "$DIST_DIR" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256" )

printf "Collected ISO: %s\n" "$DIST_DIR/$ISO_NAME"
printf "Checksum: %s\n" "$DIST_DIR/$ISO_NAME.sha256"
