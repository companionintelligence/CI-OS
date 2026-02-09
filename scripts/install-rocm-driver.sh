#!/usr/bin/env bash
#=============================================================================
# Download and install ROCm driver (pull ROCm dev image for kernel/GPU stack).
#
# Pulls rocm/dev-ubuntu-24.04:7.1.1-complete so the image is available for
# containers that need ROCm. Can be run standalone or invoked from
# setup-fresh-ubuntu.sh.
#
# Usage:
#   ./scripts/install-rocm-driver.sh
#   sudo ./scripts/install-rocm-driver.sh   # if Docker requires root
#
# Requires: Docker (running and available to the current user).
#=============================================================================

set -euo pipefail

ROCM_IMAGE="${ROCM_IMAGE:-rocm/dev-ubuntu-24.04:7.1.1-complete}"

if ! command -v docker &>/dev/null; then
  echo "Error: docker not found. Install Docker first (e.g. run setup-fresh-ubuntu.sh)." >&2
  exit 1
fi

echo "Pulling ROCm image: ${ROCM_IMAGE}"
docker pull "${ROCM_IMAGE}"
echo "Done: ROCm image ${ROCM_IMAGE} is available."
