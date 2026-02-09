#!/usr/bin/env bash
#=============================================================================
# Download and install ROCm: AMD GPU driver (amdgpu-dkms), ROCm stack, and
# ROCm container image. Must run with sudo/root.
#
# - AMD GPU: amdgpu-install .deb, linux-headers, amdgpu-dkms
# - ROCm Linux: python3-setuptools, python3-wheel, rocm; add user to render,video
# - ROCm container: docker pull rocm/dev-ubuntu-24.04:7.1.1-complete
#
# Can be run standalone or invoked from setup-fresh-ubuntu.sh.
#
# Usage:
#   sudo ./scripts/install-rocm-driver.sh
#
# When run standalone without sudo, re-execs with sudo.
#=============================================================================

set -euo pipefail

# Re-exec with sudo if not root (so all apt/docker/usermod run with sudo)
if [[ ${EUID:-0} -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

ROCM_IMAGE="${ROCM_IMAGE:-rocm/dev-ubuntu-24.04:7.1.1-complete}"
AMGPU_INSTALL_DEB="amdgpu-install_7.2.70200-1_all.deb"
AMGPU_INSTALL_URL="https://repo.radeon.com/amdgpu-install/7.2/ubuntu/noble/${AMGPU_INSTALL_DEB}"

# User to add to render,video (person who ran sudo, or current user)
ACTUAL_USER="${SUDO_USER:-${LOGNAME:-$(logname 2>/dev/null || whoami)}}"
export DEBIAN_FRONTEND=noninteractive

echo "[ROCm] Installing AMD GPU driver and ROCm stack (running as root)."

# --- AMD GPU installer .deb ---
TMP_DEB=$(mktemp -d)
trap 'rm -rf "$TMP_DEB"' EXIT
echo "[ROCm] Downloading ${AMGPU_INSTALL_DEB}..."
wget -q -O "${TMP_DEB}/${AMGPU_INSTALL_DEB}" "${AMGPU_INSTALL_URL}"
echo "[ROCm] Installing amdgpu-install package..."
apt install -y "${TMP_DEB}/${AMGPU_INSTALL_DEB}"

# --- Apt update and common deps ---
echo "[ROCm] Running apt update..."
apt update -y
echo "[ROCm] Installing python3-setuptools, python3-wheel..."
apt install -y python3-setuptools python3-wheel

# --- Kernel headers and AMD GPU kernel driver ---
echo "[ROCm] Installing linux-headers and linux-modules-extra for current kernel..."
apt install -y "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"
echo "[ROCm] Installing amdgpu-dkms..."
apt install -y amdgpu-dkms

# --- Add user to render and video groups ---
echo "[ROCm] Adding user ${ACTUAL_USER} to render and video groups..."
usermod -a -G render,video "${ACTUAL_USER}"

# --- ROCm stack ---
echo "[ROCm] Installing rocm..."
apt install -y rocm

# --- ROCm container image (optional if docker not installed yet) ---
if command -v docker &>/dev/null; then
  echo "[ROCm] Pulling ROCm container image: ${ROCM_IMAGE}..."
  docker pull "${ROCM_IMAGE}"
  echo "[ROCm] Done: ROCm image ${ROCM_IMAGE} is available."
else
  echo "[ROCm] Docker not found; skipping container image pull. Run 'docker pull ${ROCM_IMAGE}' later if needed."
fi

echo "[ROCm] ROCm driver and stack installation finished."
echo "  User ${ACTUAL_USER} was added to render and video groups; log out and back in for that to take effect."
