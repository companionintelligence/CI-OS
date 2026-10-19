#!/usr/bin/env bash
#=============================================================================
# Install ROCm on Companion OS. Must run with sudo/root.
#
# Support rule (core/lib/gpu-detect.sh): a Strix Halo-class APU (Ryzen AI Max /
# gfx1151 / Radeon 8060S) with at least ~32 GB of RAM. Anything else exits 0
# without downloading or installing a driver.
#
# Ubuntu 26.04 (resolute) is the only release Companion OS is built on, and its own
# archive carries ROCm: `apt install rocm rocminfo rocm-smi` (ROCm 7.1 at the time of
# writing: rocm 7.1.0, rocminfo and rocm-smi 7.1.1). The inbox amdgpu driver of the
# kernel is used. This script installs nothing from repo.radeon.com: no
# amdgpu-install, no amdgpu-dkms, and no packages built for another Ubuntu release.
# The three package names were checked against the resolute amd64 archive on
# 2026-10-17. `rocm-smi-lib` is NOT a package there (the command-line tool is
# `rocm-smi`, which pulls librocm-smi64-7); naming it made `apt-get install` fail as
# a whole ("Unable to locate package"), so nothing was installed.
#
# On any other Ubuntu release the script stops with an error and changes nothing.
#
# Usage:
#   sudo ./backends/ubuntu/lib/install-rocm-driver.sh
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=os-release.sh
source "${SCRIPT_DIR}/os-release.sh"
# shellcheck source=../../../core/lib/gpu-detect.sh
source "${SCRIPT_DIR}/../../../core/lib/gpu-detect.sh"

# What `apt install` is asked for. Every name exists in the Ubuntu 26.04 archive for amd64.
ROCM_PACKAGES=(rocm rocminfo rocm-smi)

# The first kernel whose inbox amdgpu/KFD supports Strix Halo (gfx1151) is Linux 6.17. Ubuntu 26.04 ships 7.0.
ROCM_MIN_KERNEL_MAJOR=6
ROCM_MIN_KERNEL_MINOR=17

ensure_video_groups() {
  local users=("$ACTUAL_USER")
  if id -u ci >/dev/null 2>&1; then
    users+=("ci")
  fi

  local u
  for u in "${users[@]}"; do
    echo "[ROCm] Adding user ${u} to render and video groups (if needed)..."
    usermod -a -G render,video "${u}" 2>/dev/null || true
  done
}

# True when "uname -r" style text names Linux 6.17 or newer.
kernel_is_new_enough() {
  local kver="$1" major minor rest
  rest="${kver%%-*}"                       # 7.0.0-30-generic -> 7.0.0
  IFS=. read -r major minor _ <<<"${rest}"
  major="${major:-0}"
  minor="${minor:-0}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > ROCM_MIN_KERNEL_MAJOR )) || (( major == ROCM_MIN_KERNEL_MAJOR && minor >= ROCM_MIN_KERNEL_MINOR ))
}

# Only warns: this script does not install a different kernel.
warn_strix_halo_kernel() {
  local kver
  kver="$(uname -r)"
  if kernel_is_new_enough "$kver"; then
    echo "[ROCm] Kernel ${kver} looks acceptable for Strix Halo inbox amdgpu."
  else
    echo "[ROCm] WARN: Kernel ${kver} is older than Linux ${ROCM_MIN_KERNEL_MAJOR}.${ROCM_MIN_KERNEL_MINOR}, which AMD Strix Halo (gfx1151) needs." >&2
    echo "[ROCm] WARN: Ubuntu 26.04 ships Linux 7.0: boot the stock kernel of this release." >&2
  fi
}

verify_rocm_after_install() {
  local needs_reboot=0

  if [[ ! -e /dev/kfd ]] || [[ ! -d /dev/dri ]]; then
    echo "[ROCm] WARN: /dev/kfd or /dev/dri not ready — reboot required before ROCm Docker workloads (e.g. ComfyUI)." >&2
    needs_reboot=1
  fi

  if command -v rocminfo >/dev/null 2>&1; then
    echo "[ROCm] rocminfo: $(rocminfo 2>/dev/null | grep -E 'Marketing Name|Name:' | head -n4 | tr '\n' ' ')"
  else
    echo "[ROCm] WARN: rocminfo not available after install." >&2
    needs_reboot=1
  fi

  if is_strix_halo_from_system; then
    print_comfyui_strix_halo_hint
  fi

  if (( needs_reboot != 0 )); then
    echo "[ROCm] Reboot your system, then verify ROCm in Companion Launcher before running GPU apps."
    return 1
  fi

  echo "[ROCm] ROCm stack appears ready (/dev/kfd and /dev/dri present)."
  return 0
}

# Install the ROCm packages from the Ubuntu archive. Checks every name first and names the missing ones, so a
# renamed package is a clear message and not an apt error that drops the whole install.
install_rocm_from_archive() {
  local pkg missing=()
  apt-get update -y
  for pkg in "${ROCM_PACKAGES[@]}"; do
    apt-cache show "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "[ROCm] ERROR: not in the Ubuntu ${UBUNTU_CODENAME} archive: ${missing[*]}" >&2
    echo "[ROCm] Nothing was installed. Packages from another release's repositories are not used." >&2
    return 1
  fi
  apt-get install -y "${ROCM_PACKAGES[@]}"
}

# Re-run through sudo when not root. A function, so the test can replace it.
require_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    exec sudo "$0" "$@"
  fi
}

main() {
  require_root "$@"

  if ! ci_os_hardware_supported; then
    echo "[ROCm] Unsupported hardware: ${CI_OS_HARDWARE_SUPPORT_REASON}."
    echo "[ROCm] Not installing ROCm. The desktop is unchanged."
    ci_os_record_hardware_support || true
    exit 0
  fi
  echo "[ROCm] Supported hardware: ${CI_OS_HARDWARE_SUPPORT_REASON}."
  ci_os_record_hardware_support || true

  ACTUAL_USER="${SUDO_USER:-${LOGNAME:-$(logname 2>/dev/null || whoami)}}"
  export DEBIAN_FRONTEND=noninteractive

  UBUNTU_CODENAME="$(ci_os_ubuntu_codename)"
  UBUNTU_VERSION_ID="$(ci_os_ubuntu_version_id)"
  if ! ci_os_base_is_supported "$UBUNTU_VERSION_ID" "$UBUNTU_CODENAME"; then
    echo "[ROCm] Not installing ROCm: the packages are taken from the Ubuntu ${CI_OS_UBUNTU_VERSION_ID} archive only." >&2
    exit 1
  fi

  echo "[ROCm] Ubuntu ${UBUNTU_VERSION_ID} (${UBUNTU_CODENAME}): installing ROCm from the Ubuntu archive (${ROCM_PACKAGES[*]})."
  echo "[ROCm] Marketing version: $(ci_os_marketing_version)"
  echo "[ROCm] Inbox amdgpu only. amdgpu-dkms is not installed."
  if [[ ! -e /dev/kfd ]]; then
    echo "[ROCm] WARN: /dev/kfd not present. Ensure amdgpu is loaded (modprobe amdgpu) before GPU workloads." >&2
  fi

  warn_strix_halo_kernel
  # The groups first: they matter for GPU access whether or not the packages install.
  ensure_video_groups
  install_rocm_from_archive
  verify_rocm_after_install || true
  echo "[ROCm] Installed from the Ubuntu archive. Log out and back in if group membership changed."
}

# Run only when executed; a test sources this file to call the functions above.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
