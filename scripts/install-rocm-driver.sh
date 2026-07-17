#!/usr/bin/env bash
#=============================================================================
# Install ROCm: AMD GPU driver (amdgpu-dkms) and ROCm stack on CI OS (Ubuntu base).
# Must run with sudo/root.
#
# - Resolves the real Ubuntu suite codename (not the marketing "ci" codename).
# - Probes repo.radeon.com for the newest amdgpu-install line (with codename fallbacks).
# - Temporarily sets ID=ubuntu while running strict AMD tooling when needed.
#
# Usage:
#   sudo ./scripts/install-rocm-driver.sh
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os-release.sh
source "${SCRIPT_DIR}/lib/os-release.sh"

if [[ ${EUID:-0} -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

FALLBACK_AMDGPU_LINE="7.2"
FALLBACK_AMDGPU_DEB="amdgpu-install_7.2.70200-1_all.deb"
FALLBACK_CODENAMES=(noble jammy)

ACTUAL_USER="${SUDO_USER:-${LOGNAME:-$(logname 2>/dev/null || whoami)}}"
export DEBIAN_FRONTEND=noninteractive

if [[ ! -e /dev/kfd ]]; then
  echo "[ROCm] WARN: /dev/kfd not present. Ensure amdgpu is loaded (modprobe amdgpu) before GPU workloads." >&2
fi

UBUNTU_CODENAME="$(ci_os_ubuntu_codename)"
UBUNTU_VERSION_ID="$(ci_os_ubuntu_version_id)"

pkg_ver_from_amdgpu_deb() {
  local deb="$1"
  if [[ "$deb" =~ amdgpu-install_(.+)_all\.deb ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Prints: line<TAB>deb filename for the first matching codename in the list.
discover_amdgpu_install_for_codename() {
  local primary="$1"
  shift
  local codenames=("$primary" "$@")
  local codename

  if [[ "${CI_OS_ROCM_DISABLE_REPO_PROBE:-}" == "1" ]]; then
    printf '%s\t%s\n' "$FALLBACK_AMDGPU_LINE" "$FALLBACK_AMDGPU_DEB"
    return 0
  fi

  local index body deb_found v
  index=$(curl -fsSL --connect-timeout 25 'https://repo.radeon.com/amdgpu-install/' 2>/dev/null) || {
    echo "[ROCm] Repo index fetch failed; using fallback ${FALLBACK_AMDGPU_DEB}." >&2
    printf '%s\t%s\n' "$FALLBACK_AMDGPU_LINE" "$FALLBACK_AMDGPU_DEB"
    return 0
  }

  local versions=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && versions+=("$line")
  done < <(echo "$index" | grep -oE 'href="[0-9][^"/]+/' | sed 's/href="//;s/\/$//' | sort -uV)

  for codename in "${codenames[@]}"; do
    for (( i=${#versions[@]}-1; i>=0; i-- )); do
      v="${versions[i]}"
      body=$(curl -fsSL --connect-timeout 15 "https://repo.radeon.com/amdgpu-install/${v}/ubuntu/${codename}/" 2>/dev/null) || continue
      deb_found=$(echo "$body" | grep -oE 'amdgpu-install_[^"<>[:space:]]+_all\.deb' | head -n1)
      if [[ -n "$deb_found" ]]; then
        echo "[ROCm] Matched amdgpu-install ${deb_found} for Ubuntu ${codename} (line ${v})." >&2
        printf '%s\t%s\n' "$v" "$deb_found"
        return 0
      fi
    done
  done

  echo "[ROCm] No amdgpu-install .deb found for codenames: ${codenames[*]}; using fallback ${FALLBACK_AMDGPU_DEB}." >&2
  printf '%s\t%s\n' "$FALLBACK_AMDGPU_LINE" "$FALLBACK_AMDGPU_DEB"
}

rocm_stack_satisfied() {
  local target_ver="$1"
  local st inst

  for pkg in amdgpu-dkms rocm; do
    st=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    if ! echo "$st" | grep -q 'ok installed'; then
      return 1
    fi
  done

  st=$(dpkg-query -W -f='${Status}' amdgpu-install 2>/dev/null || true)
  if ! echo "$st" | grep -q 'ok installed'; then
    return 1
  fi

  inst=$(dpkg-query -W -f='${Version}' amdgpu-install 2>/dev/null || true)
  [[ -n "$inst" ]] || return 1
  dpkg --compare-versions "$inst" ge "$target_ver" 2>/dev/null
}

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

run_amdgpu_install_rocm() {
  echo "[ROCm] Running amdgpu-install --usecase=rocm (unified driver + ROCm stack)..."
  if ci_os_with_ubuntu_toolchain_id amdgpu-install -y --usecase=rocm; then
    return 0
  fi
  echo "[ROCm] WARN: amdgpu-install --usecase=rocm failed; falling back to package installs." >&2
  return 1
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

  # shellcheck source=lib/gpu-detect.sh
  source "${SCRIPT_DIR}/lib/gpu-detect.sh"
  if is_strix_halo_from_system; then
    print_comfyui_strix_halo_hint
  fi

  if (( needs_reboot != 0 )); then
    echo "[ROCm] Reboot your system, then verify ROCm in Companion Hub before running GPU apps."
    return 1
  fi

  echo "[ROCm] ROCm stack appears ready (/dev/kfd and /dev/dri present)."
  return 0
}

install_kernel_build_deps() {
  local kver
  kver="$(uname -r)"
  echo "[ROCm] Installing kernel build deps for ${kver}..."

  apt install -y "linux-headers-${kver}"

  if apt-cache show "linux-modules-extra-${kver}" >/dev/null 2>&1; then
    apt install -y "linux-modules-extra-${kver}"
  elif apt-cache show "linux-modules-${kver}" >/dev/null 2>&1; then
    echo "[ROCm] linux-modules-extra not published for ${kver}; installing linux-modules instead." >&2
    apt install -y "linux-modules-${kver}" || true
  else
    echo "[ROCm] WARN: No linux-modules-extra/linux-modules package for ${kver}; continuing (in-tree amdgpu may suffice)." >&2
  fi
}

try_ubuntu_rocm_metapackage() {
  if ! apt-cache show rocm >/dev/null 2>&1; then
    return 1
  fi
  echo "[ROCm] Installing from Ubuntu archive (rocm metapackage)..."
  apt update -y
  install_kernel_build_deps || true
  apt install -y rocm rocminfo rocm-smi-lib || apt install -y rocm
  command -v rocminfo >/dev/null 2>&1
}

IFS=$'\t' read -r AMDGPU_LINE AMGPU_INSTALL_DEB < <(discover_amdgpu_install_for_codename "$UBUNTU_CODENAME" "${FALLBACK_CODENAMES[@]}")
# Prefer the codename that actually matched in the URL path (may differ from primary on new Ubuntu releases).
INSTALL_CODENAME="$UBUNTU_CODENAME"
if ! curl -fsSL --connect-timeout 10 "https://repo.radeon.com/amdgpu-install/${AMDGPU_LINE}/ubuntu/${UBUNTU_CODENAME}/${AMGPU_INSTALL_DEB}" >/dev/null 2>&1; then
  for fb in "${FALLBACK_CODENAMES[@]}"; do
    if curl -fsSL --connect-timeout 10 "https://repo.radeon.com/amdgpu-install/${AMDGPU_LINE}/ubuntu/${fb}/${AMGPU_INSTALL_DEB}" >/dev/null 2>&1; then
      INSTALL_CODENAME="$fb"
      echo "[ROCm] Using Ubuntu ${INSTALL_CODENAME} AMDGPU repo (no build for ${UBUNTU_CODENAME} yet)." >&2
      break
    fi
  done
fi

AMGPU_INSTALL_URL="https://repo.radeon.com/amdgpu-install/${AMDGPU_LINE}/ubuntu/${INSTALL_CODENAME}/${AMGPU_INSTALL_DEB}"

TARGET_PKG_VER=$(pkg_ver_from_amdgpu_deb "$AMGPU_INSTALL_DEB") || {
  echo "[ROCm] ERROR: Could not parse version from deb name: ${AMGPU_INSTALL_DEB}" >&2
  exit 1
}

echo "[ROCm] CI OS marketing version: $(ci_os_marketing_version)"
echo "[ROCm] Ubuntu base: ${UBUNTU_VERSION_ID} (${UBUNTU_CODENAME}); AMDGPU repo suite: ${INSTALL_CODENAME}"
echo "[ROCm] Using AMDGPU installer: ${AMGPU_INSTALL_DEB} (package version ${TARGET_PKG_VER}; line ${AMDGPU_LINE})"

if rocm_stack_satisfied "$TARGET_PKG_VER"; then
  inst=$(dpkg-query -W -f='${Version}' amdgpu-install)
  echo "[ROCm] Stack already satisfies target (amdgpu-install ${inst} >= ${TARGET_PKG_VER}; amdgpu-dkms and rocm present)."
  ensure_video_groups
  verify_rocm_after_install || true
  echo "[ROCm] Complete. Log out and back in if group membership changed."
  exit 0
fi

echo "[ROCm] Installing AMD GPU driver and ROCm stack..."

TMP_DEB=$(mktemp -d)
trap 'rm -rf "$TMP_DEB"' EXIT

echo "[ROCm] Downloading ${AMGPU_INSTALL_DEB}..."
wget -q -O "${TMP_DEB}/${AMGPU_INSTALL_DEB}" "${AMGPU_INSTALL_URL}"

echo "[ROCm] Installing amdgpu-install package (Ubuntu toolchain ID for strict postinst checks)..."
ci_os_with_ubuntu_toolchain_id apt install -y "${TMP_DEB}/${AMGPU_INSTALL_DEB}"

echo "[ROCm] Running apt update..."
apt update -y
apt install -y python3-setuptools python3-wheel

install_kernel_build_deps

ensure_video_groups

if run_amdgpu_install_rocm; then
  :
elif apt install -y amdgpu-dkms; then
  echo "[ROCm] Installing rocm packages after amdgpu-dkms..."
  apt install -y rocm rocminfo rocm-smi-lib 2>/dev/null || apt install -y rocm
else
  echo "[ROCm] WARN: amdgpu-dkms install failed; trying Ubuntu rocm metapackage..." >&2
  if try_ubuntu_rocm_metapackage; then
    ensure_video_groups
    verify_rocm_after_install || true
    echo "[ROCm] Installed via Ubuntu rocm metapackage."
    exit 0
  fi
  exit 1
fi

verify_rocm_after_install || true

echo "[ROCm] ROCm driver and stack installation finished."
echo "  Users were added to render and video groups; log out and back in for that to take effect."
