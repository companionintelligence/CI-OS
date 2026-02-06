#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_env.sh
source "$SCRIPT_DIR/_env.sh"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd sha256sum
require_cmd awk
require_cmd grep

mkdir -p "$CUBIC_ISO_BASE_DIR" "$CUBIC_ISO_OUTPUT_DIR" "$CUBIC_PROJECT_DIR" "$CUBIC_STAGING_DIR"

ISO_PATH="$CUBIC_ISO_BASE_DIR/$UBUNTU_ISO_NAME"

if [ ! -f "$ISO_PATH" ]; then
  echo "Downloading Ubuntu ISO: $UBUNTU_ISO_URL"
  curl -L "$UBUNTU_ISO_URL" -o "$ISO_PATH"
else
  echo "Ubuntu ISO already present: $ISO_PATH"
fi

if [ "${CUBIC_SKIP_VERIFY:-}" != "1" ]; then
  echo "Verifying ISO checksum against: $UBUNTU_ISO_SHA256SUMS_URL"
  curl -L "$UBUNTU_ISO_SHA256SUMS_URL" -o "$CUBIC_ISO_BASE_DIR/SHA256SUMS"
  (cd "$CUBIC_ISO_BASE_DIR" && grep " $UBUNTU_ISO_NAME$" SHA256SUMS > SHA256SUMS.filtered)
  (cd "$CUBIC_ISO_BASE_DIR" && sha256sum -c SHA256SUMS.filtered)
else
  echo "Skipping ISO checksum verification (CUBIC_SKIP_VERIFY=1)"
fi

# Prepare a staging bundle to copy into the Cubic chroot
STAGING_ROOT="$CUBIC_STAGING_DIR"
rm -rf "$STAGING_ROOT"
mkdir -p "$STAGING_ROOT"

cp -a "$REPO_ROOT/configs" "$STAGING_ROOT/"
cp -a "$REPO_ROOT/scripts" "$STAGING_ROOT/"
cp -a "$REPO_ROOT/setup/os-changes" "$STAGING_ROOT/"
cp -a "$REPO_ROOT/assets" "$STAGING_ROOT/"

cat > "$STAGING_ROOT/README.txt" << 'STAGE'
CI OS Cubic staging bundle

Copy this folder into the Cubic chroot during customization, then run:
  sudo /path/to/ci-os/configs/scripts/ci-os-customization.sh

This bundle includes configs/, scripts/, setup/os-changes/, and assets/.
STAGE

cat > "$CUBIC_WORKDIR/INSTRUCTIONS.txt" << INSTR
CI OS Cubic build instructions

1) Launch Cubic and create/open the project directory:
   $CUBIC_PROJECT_DIR

2) Choose the base ISO:
   $ISO_PATH

3) In the Cubic terminal (chroot), copy the staging bundle:
   $CUBIC_STAGING_DIR
   Then run:
     sudo /path/to/ci-os/configs/scripts/ci-os-customization.sh

4) On the Generate page, set the output directory to:
   $CUBIC_ISO_OUTPUT_DIR
INSTR

printf "\nPrepared Cubic workspace at: %s\n" "$CUBIC_WORKDIR"
printf "Staging bundle: %s\n" "$CUBIC_STAGING_DIR"
printf "Instructions: %s\n" "$CUBIC_WORKDIR/INSTRUCTIONS.txt"
