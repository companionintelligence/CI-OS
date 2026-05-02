#!/usr/bin/env bash
#=============================================================================
# Download and install ROCm: AMD GPU driver (amdgpu-dkms) and ROCm stack.
# Must run with sudo/root.
#
# - Picks the newest amdgpu-install line for this Ubuntu release by probing
#   repo.radeon.com (override with CI_OS_ROCM_DISABLE_REPO_PROBE=1 to use the
#   bundled fallback: amdgpu-install 7.2 / noble or jammy paths).
# - If amdgpu-install (>= target), amdgpu-dkms, and rocm are already installed,
#   exits successfully without downloading (still ensures render,video groups).
#
# Can be run standalone or invoked from setup-fresh-ubuntu.sh.
#
# Usage:
#   sudo ./scripts/install-rocm-driver.sh
#
# When run standalone without sudo, re-execs with sudo.
#=============================================================================

set -euo pipefail

# Re-exec with sudo if not root (so all apt/usermod run with sudo)
if [[ ${EUID:-0} -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

# Fallback when the index cannot be fetched or no directory matches this Ubuntu
FALLBACK_AMDGPU_LINE="7.2"
FALLBACK_AMDGPU_DEB="amdgpu-install_7.2.70200-1_all.deb"

ACTUAL_USER="${SUDO_USER:-${LOGNAME:-$(logname 2>/dev/null || whoami)}}"
export DEBIAN_FRONTEND=noninteractive

if [[ ! -f /etc/os-release ]]; then
  echo "[ROCm] ERROR: /etc/os-release missing; cannot determine Ubuntu codename." >&2
  exit 1
fi
# shellcheck source=/dev/null
source /etc/os-release
UBUNTU_CODENAME="${VERSION_CODENAME:-}"
if [[ -z "$UBUNTU_CODENAME" ]]; then
  echo "[ROCm] ERROR: VERSION_CODENAME not set in /etc/os-release." >&2
  exit 1
fi

pkg_ver_from_amdgpu_deb() {
  local deb="$1"
  if [[ "$deb" =~ amdgpu-install_(.+)_all\.deb ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Prints: $'\t' separated line and deb filename (e.g. 31.20<TAB>amdgpu-install_31.20.312000-1_all.deb)
discover_amdgpu_install_for_codename() {
  local codename="$1"

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

  deb_found=""
  local i
  for (( i=${#versions[@]}-1; i>=0; i-- )); do
    v="${versions[i]}"
    body=$(curl -fsSL --connect-timeout 15 "https://repo.radeon.com/amdgpu-install/${v}/ubuntu/${codename}/" 2>/dev/null) || continue
    deb_found=$(echo "$body" | grep -oE 'amdgpu-install_[^"<>[:space:]]+_all\.deb' | head -n1)
    [[ -n "$deb_found" ]] && break
  done

  if [[ -z "$deb_found" ]]; then
    echo "[ROCm] No amdgpu-install .deb found for Ubuntu ${codename}; using fallback ${FALLBACK_AMDGPU_DEB}." >&2
    printf '%s\t%s\n' "$FALLBACK_AMDGPU_LINE" "$FALLBACK_AMDGPU_DEB"
    return 0
  fi

  printf '%s\t%s\n' "$v" "$deb_found"
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
  echo "[ROCm] Adding user ${ACTUAL_USER} to render and video groups (if needed)..."
  usermod -a -G render,video "${ACTUAL_USER}" 2>/dev/null || true
}

# --- Resolve installer .deb for this Ubuntu codename ---
IFS=$'\t' read -r AMDGPU_LINE AMGPU_INSTALL_DEB < <(discover_amdgpu_install_for_codename "$UBUNTU_CODENAME")
AMGPU_INSTALL_URL="https://repo.radeon.com/amdgpu-install/${AMDGPU_LINE}/ubuntu/${UBUNTU_CODENAME}/${AMGPU_INSTALL_DEB}"

TARGET_PKG_VER=$(pkg_ver_from_amdgpu_deb "$AMGPU_INSTALL_DEB") || {
  echo "[ROCm] ERROR: Could not parse version from deb name: ${AMGPU_INSTALL_DEB}" >&2
  exit 1
}

echo "[ROCm] Ubuntu codename: ${UBUNTU_CODENAME}"
echo "[ROCm] Using AMDGPU installer: ${AMGPU_INSTALL_DEB} (package version ${TARGET_PKG_VER}; line ${AMDGPU_LINE})"

if rocm_stack_satisfied "$TARGET_PKG_VER"; then
  inst=$(dpkg-query -W -f='${Version}' amdgpu-install)
  echo "[ROCm] Stack already satisfies target (amdgpu-install ${inst} >= ${TARGET_PKG_VER}; amdgpu-dkms and rocm present). Nothing to install."
  ensure_video_groups
  echo "[ROCm] Complete. Log out and back in if group membership changed."
  exit 0
fi

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

ensure_video_groups

# --- ROCm stack ---
echo "[ROCm] Installing rocm..."
apt install -y rocm

echo "[ROCm] ROCm driver and stack installation finished."
echo "  User ${ACTUAL_USER} was added to render and video groups; log out and back in for that to take effect."
