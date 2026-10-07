#!/usr/bin/env bash
#=============================================================================
# Install ROCm on Companion Ubuntu. Must run with sudo/root.
#
# Support rule (core/lib/gpu-detect.sh): a Strix Halo-class APU (Ryzen AI Max /
# gfx1151 / Radeon 8060S) with at least ~32 GB of RAM. Anything else exits 0
# without downloading or installing a driver.
#
# Ubuntu 26.04 (resolute): `apt install rocm` from the Ubuntu archive. ROCm 7.1
# is in that archive, and the inbox amdgpu driver is used. This script does not
# install amdgpu-dkms (it fails to build on the 26.04 kernel) and does not
# install Ubuntu 24.04 noble packages onto 26.04.
#
# Ubuntu 24.04 (noble): newest Ryzen-compatible ROCm apt line, 7.2.4, via
# amdgpu-install --usecase=rocm --no-dkms. Discovery ignores 30.x/31.x Radeon
# graphics installer lines.
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

if [[ ${EUID:-0} -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

if ! ci_os_hardware_supported; then
  echo "[ROCm] Unsupported hardware: ${CI_OS_HARDWARE_SUPPORT_REASON}."
  echo "[ROCm] Not installing ROCm. The desktop is unchanged."
  ci_os_record_hardware_support || true
  exit 0
fi
echo "[ROCm] Supported hardware: ${CI_OS_HARDWARE_SUPPORT_REASON}."
ci_os_record_hardware_support || true

# Newest Ryzen-compatible ROCm apt line on Ubuntu 24.04 (noble) as of 2026-07.
FALLBACK_AMDGPU_LINE="7.2.4"
FALLBACK_AMDGPU_DEB="amdgpu-install_7.2.4.70204-1_all.deb"
FALLBACK_CODENAMES=(noble jammy)

ACTUAL_USER="${SUDO_USER:-${LOGNAME:-$(logname 2>/dev/null || whoami)}}"
export DEBIAN_FRONTEND=noninteractive

# The support gate above already required a Strix Halo-class APU. The only
# install path is the inbox driver (--no-dkms). DKMS is not used.
STRIX_HALO=1

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

pkg_installed() {
  local pkg="$1"
  local st
  st=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
  echo "$st" | grep -q 'ok installed'
}

# Prints: line<TAB>deb filename for the first matching codename in the list.
# Only considers ROCm 7.x installer lines — never 30.x/31.x graphics lines.
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
    # ROCm apt installer lines only (7.2.4, 7.2.3, …). Skip 30.x/31.x graphics.
    [[ "$line" =~ ^7\. ]] || continue
    versions+=("$line")
  done < <(echo "$index" | grep -oE 'href="[0-9][^"/]+/' | sed 's/href="//;s/\/$//' | sort -uV)

  if ((${#versions[@]} == 0)); then
    echo "[ROCm] No ROCm 7.x amdgpu-install lines in repo index; using fallback ${FALLBACK_AMDGPU_DEB}." >&2
    printf '%s\t%s\n' "$FALLBACK_AMDGPU_LINE" "$FALLBACK_AMDGPU_DEB"
    return 0
  fi

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

  echo "[ROCm] No ROCm 7.x amdgpu-install .deb found for codenames: ${codenames[*]}; using fallback ${FALLBACK_AMDGPU_DEB}." >&2
  printf '%s\t%s\n' "$FALLBACK_AMDGPU_LINE" "$FALLBACK_AMDGPU_DEB"
}

# Satisfied when amdgpu-install + rocm are present at/above target.
# Strix Halo / Ryzen uses inbox amdgpu (--no-dkms); discrete GPUs also expect amdgpu-dkms.
rocm_stack_satisfied() {
  local target_ver="$1"
  local st inst

  if ! pkg_installed rocm; then
    return 1
  fi

  st=$(dpkg-query -W -f='${Status}' amdgpu-install 2>/dev/null || true)
  if ! echo "$st" | grep -q 'ok installed'; then
    return 1
  fi

  inst=$(dpkg-query -W -f='${Version}' amdgpu-install 2>/dev/null || true)
  [[ -n "$inst" ]] || return 1
  dpkg --compare-versions "$inst" ge "$target_ver" 2>/dev/null || return 1

  if (( STRIX_HALO == 0 )) && ! pkg_installed amdgpu-dkms; then
    return 1
  fi

  return 0
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

warn_strix_halo_kernel() {
  local kver major minor patch rest
  kver="$(uname -r)"
  # Strip Ubuntu suffix (e.g. 6.17.0-19-generic → 6.17.0)
  rest="${kver%%-*}"
  IFS=. read -r major minor patch <<<"${rest}"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"

  # AMD Strix Halo matrix: Ubuntu HWE >= 6.17.0-19…, OEM >= 6.14.0-1018, else >= 6.18.4.
  # We only warn; we do not auto-install an OEM/HWE kernel.
  local ok=0
  if [[ "$kver" == *"-oem"* ]]; then
    # OEM track: accept 6.14.0-1018+ heuristically (package version in uname)
    if (( major > 6 )) || (( major == 6 && minor > 14 )) || (( major == 6 && minor == 14 )); then
      ok=1
    fi
  elif (( major > 6 )) || (( major == 6 && minor > 17 )) || (( major == 6 && minor == 17 )); then
    ok=1
  elif (( major == 6 && minor == 18 )) || (( major == 6 && minor > 18 )); then
    ok=1
  fi

  if (( ok == 0 )); then
    echo "[ROCm] WARN: Kernel ${kver} may be below AMD Strix Halo (gfx1151) requirements." >&2
    echo "[ROCm] WARN: Prefer Ubuntu 24.04 HWE >= 6.17.0-19… or OEM >= 6.14.0-1018 (e.g. linux-oem-24.04c)." >&2
  else
    echo "[ROCm] Kernel ${kver} looks acceptable for Strix Halo inbox amdgpu."
  fi
}

remove_amdgpu_dkms_for_strix() {
  if ! pkg_installed amdgpu-dkms && ! pkg_installed dkms; then
    return 0
  fi
  echo "[ROCm] Strix Halo / Ryzen requires inbox amdgpu (--no-dkms); removing amdgpu-dkms if present..."
  apt autoremove -y amdgpu-dkms dkms 2>/dev/null || apt remove -y amdgpu-dkms 2>/dev/null || true
  if command -v dkms >/dev/null 2>&1; then
    local status
    status="$(dkms status 2>/dev/null || true)"
    if [[ -n "$status" ]]; then
      echo "[ROCm] WARN: dkms status still reports modules; review with: dkms status" >&2
      echo "$status" >&2
    fi
  fi
}

run_amdgpu_install_rocm() {
  if (( STRIX_HALO == 1 )); then
    echo "[ROCm] Strix Halo / Ryzen AI Max detected — installing with --usecase=rocm --no-dkms (inbox driver)."
    if ci_os_with_ubuntu_toolchain_id amdgpu-install -y --usecase=rocm --no-dkms; then
      return 0
    fi
    echo "[ROCm] WARN: amdgpu-install --usecase=rocm --no-dkms failed; falling back to package installs." >&2
    return 1
  fi

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

install_rocm_packages_no_dkms() {
  echo "[ROCm] Installing rocm packages without amdgpu-dkms (inbox driver path)..."
  apt install -y rocm rocminfo rocm-smi-lib 2>/dev/null || apt install -y rocm
}

# Ubuntu 26.04 ships ROCm in the archive. Stay on that suite: a noble
# amdgpu-install package is built for 24.04 and is the wrong driver here.
if [[ "$UBUNTU_CODENAME" == "resolute" || "$UBUNTU_VERSION_ID" == "26.04" ]]; then
  echo "[ROCm] Ubuntu ${UBUNTU_VERSION_ID} (${UBUNTU_CODENAME}): installing ROCm from the Ubuntu archive."
  echo "[ROCm] Inbox amdgpu only. amdgpu-dkms is not installed on this release."
  apt-get update -y
  if ! apt-cache show rocm >/dev/null 2>&1; then
    echo "[ROCm] ERROR: package 'rocm' is not in the Ubuntu ${UBUNTU_CODENAME} archive." >&2
    echo "[ROCm] Not falling back to another release's amdgpu-install packages." >&2
    exit 1
  fi
  apt-get install -y rocm rocminfo rocm-smi-lib
  ensure_video_groups
  warn_strix_halo_kernel
  verify_rocm_after_install || true
  echo "[ROCm] Installed from the Ubuntu archive. Log out and back in if group membership changed."
  exit 0
fi

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

echo "[ROCm] Companion Ubuntu provisioning (CI-OS scripts on Ubuntu ${UBUNTU_VERSION_ID})"
echo "[ROCm] Marketing version: $(ci_os_marketing_version)"
echo "[ROCm] Ubuntu base: ${UBUNTU_VERSION_ID} (${UBUNTU_CODENAME}); AMDGPU repo suite: ${INSTALL_CODENAME}"
echo "[ROCm] Using AMDGPU installer: ${AMGPU_INSTALL_DEB} (package version ${TARGET_PKG_VER}; line ${AMDGPU_LINE})"
if (( STRIX_HALO == 1 )); then
  echo "[ROCm] Hardware path: Strix Halo / Ryzen AI Max (gfx1151) — --no-dkms"
  warn_strix_halo_kernel
else
  echo "[ROCm] Refusing to install: only the Strix Halo inbox-driver path is supported." >&2
  exit 0
fi

if rocm_stack_satisfied "$TARGET_PKG_VER"; then
  inst=$(dpkg-query -W -f='${Version}' amdgpu-install)
  if (( STRIX_HALO == 1 )); then
    echo "[ROCm] Stack already satisfies target (amdgpu-install ${inst} >= ${TARGET_PKG_VER}; rocm present; inbox amdgpu)."
    remove_amdgpu_dkms_for_strix
  else
    echo "[ROCm] Stack already satisfies target (amdgpu-install ${inst} >= ${TARGET_PKG_VER}; amdgpu-dkms and rocm present)."
  fi
  ensure_video_groups
  verify_rocm_after_install || true
  echo "[ROCm] Complete. Log out and back in if group membership changed."
  exit 0
fi

echo "[ROCm] Installing AMD GPU driver and ROCm stack (target ROCm ${AMDGPU_LINE})..."

TMP_DEB=$(mktemp -d)
trap 'rm -rf "$TMP_DEB"' EXIT

echo "[ROCm] Downloading ${AMGPU_INSTALL_DEB}..."
wget -q -O "${TMP_DEB}/${AMGPU_INSTALL_DEB}" "${AMGPU_INSTALL_URL}"

echo "[ROCm] Installing amdgpu-install package (Ubuntu toolchain ID for strict postinst checks)..."
ci_os_with_ubuntu_toolchain_id apt install -y "${TMP_DEB}/${AMGPU_INSTALL_DEB}"

echo "[ROCm] Running apt update..."
apt update -y
apt install -y python3-setuptools python3-wheel

if (( STRIX_HALO == 1 )); then
  # Inbox driver path: headers are still useful; skip forcing DKMS-oriented modules-extra.
  apt install -y "linux-headers-$(uname -r)" 2>/dev/null || true
  remove_amdgpu_dkms_for_strix
else
  install_kernel_build_deps
fi

ensure_video_groups

if run_amdgpu_install_rocm; then
  :
elif (( STRIX_HALO == 1 )); then
  if install_rocm_packages_no_dkms; then
    :
  else
    echo "[ROCm] WARN: Strix Halo package install failed; trying Ubuntu rocm metapackage..." >&2
    if try_ubuntu_rocm_metapackage; then
      ensure_video_groups
      verify_rocm_after_install || true
      echo "[ROCm] Installed via Ubuntu rocm metapackage."
      exit 0
    fi
    exit 1
  fi
else
  echo "[ROCm] Refusing amdgpu-dkms. The supported path is the inbox amdgpu driver." >&2
  exit 1
fi

if (( STRIX_HALO == 1 )); then
  remove_amdgpu_dkms_for_strix
fi

verify_rocm_after_install || true

echo "[ROCm] ROCm driver and stack installation finished."
echo "  Users were added to render and video groups; log out and back in for that to take effect."
