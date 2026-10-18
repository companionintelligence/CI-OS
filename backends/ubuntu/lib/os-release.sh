#!/usr/bin/env bash
# Shared Companion OS ↔ Ubuntu identity helpers for setup scripts.
# Branding lives in NAME/PRETTY_NAME/CI_OS_*; apt/AMD/Docker expect ID=ubuntu + real codename.

# shellcheck shell=bash

# The one Ubuntu release Companion OS is built on: Ubuntu 26.04 LTS (resolute). Every earlier release was retired on
# 2026-10-17. These are also the last-resort answers of ci_os_ubuntu_codename / ci_os_ubuntu_version_id below, for a
# machine whose os-release, backup and lsb_release all fail to say.
CI_OS_UBUNTU_VERSION_ID="26.04"
CI_OS_UBUNTU_CODENAME="resolute"
# The running system's os-release, read after the saved Ubuntu base file. A variable only so that the golden test can
# point it somewhere else; nothing sets it in production.
CI_OS_SYSTEM_OS_RELEASE="/etc/os-release"

ci_os__strip_quotes() {
  local v="$1"
  v="${v#\"}"
  v="${v%\"}"
  echo "$v"
}

# Load key fields from an os-release file into the caller's environment.
ci_os_load_os_release_file() {
  local file="$1"
  local line key val
  [[ -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    val="$(ci_os__strip_quotes "$val")"
    case "$key" in
      ID) ID="$val" ;;
      ID_LIKE) ID_LIKE="$val" ;;
      NAME) NAME="$val" ;;
      PRETTY_NAME) PRETTY_NAME="$val" ;;
      VERSION_ID) VERSION_ID="$val" ;;
      VERSION_CODENAME) VERSION_CODENAME="$val" ;;
      UBUNTU_CODENAME) UBUNTU_CODENAME="$val" ;;
      CI_OS_VERSION) CI_OS_VERSION="$val" ;;
      CI_OS_ID) CI_OS_ID="$val" ;;
    esac
  done <"$file"
}

# ci_os_base_is_supported <VERSION_ID> <codename>: 0 when this is the Ubuntu release Companion OS is built on (26.04,
# resolute), otherwise 1 with the reason on stderr. Callers that would change a system (customize-chroot.sh on an
# extracted base image) call it first and stop on 1, so a base of another release is refused and not half-converted.
ci_os_base_is_supported() {
  local version_id="${1:-}" codename="${2:-}"
  if [[ "$version_id" == "$CI_OS_UBUNTU_VERSION_ID" && "$codename" == "$CI_OS_UBUNTU_CODENAME" ]]; then
    return 0
  fi
  echo "[ERROR] This is Ubuntu ${version_id:-?} (${codename:-?}); Companion OS is built on Ubuntu ${CI_OS_UBUNTU_VERSION_ID} LTS (${CI_OS_UBUNTU_CODENAME}) only." >&2
  echo "[ERROR] Earlier Ubuntu releases were retired on 2026-10-17. Use ubuntu-26.04.1-desktop-amd64.iso as the base image." >&2
  return 1
}

CI_OS_UBUNTU_BASE_OS_RELEASE="/etc/os-release.ubuntu-base"

ci_os_find_ubuntu_base_os_release() {
  local f id=""

  if [[ -f "$CI_OS_UBUNTU_BASE_OS_RELEASE" ]]; then
    echo "$CI_OS_UBUNTU_BASE_OS_RELEASE"
    return 0
  fi

  # Oldest Ubuntu backup is usually the pristine upstream os-release before Companion OS branding.
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    id="$(grep -E '^ID=' "$f" | head -1 | cut -d= -f2 | tr -d '"')"
    if [[ "$id" == "ubuntu" ]]; then
      install -m 644 "$f" "$CI_OS_UBUNTU_BASE_OS_RELEASE"
      echo "$CI_OS_UBUNTU_BASE_OS_RELEASE"
      return 0
    fi
  done < <(ls -tr /etc/os-release.ubuntu-backup-* 2>/dev/null || true)

  if [[ -f /usr/lib/os-release ]] && grep -qE '^ID=ubuntu' /usr/lib/os-release 2>/dev/null; then
    echo "/usr/lib/os-release"
    return 0
  fi
  return 1
}

ci_os_latest_ubuntu_os_release_backup() {
  ci_os_find_ubuntu_base_os_release
}

# Ubuntu suite codename for apt/AMD repos (never the marketing "ci" codename).
ci_os_ubuntu_codename() {
  local codename="" backup_file=""

  if backup_file="$(ci_os_find_ubuntu_base_os_release)"; then
    UBUNTU_CODENAME="" VERSION_CODENAME=""
    ci_os_load_os_release_file "$backup_file" || true
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  fi

  if [[ -z "$codename" || "$codename" == "ci" ]] && [[ -f "$CI_OS_SYSTEM_OS_RELEASE" ]]; then
    # shellcheck disable=SC1090
    source "$CI_OS_SYSTEM_OS_RELEASE"
    if [[ -n "${UBUNTU_CODENAME:-}" && "${UBUNTU_CODENAME}" != "ci" ]]; then
      codename="${UBUNTU_CODENAME}"
    elif [[ -n "${VERSION_CODENAME:-}" && "${VERSION_CODENAME}" != "ci" ]]; then
      codename="${VERSION_CODENAME}"
    fi
  fi

  if [[ -z "$codename" || "$codename" == "ci" ]] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -cs 2>/dev/null || true)"
  fi

  if [[ -z "$codename" || "$codename" == "ci" ]]; then
    codename="$CI_OS_UBUNTU_CODENAME"
  fi

  echo "$codename"
}

ci_os_ubuntu_version_id() {
  local version_id="" backup_file=""

  if backup_file="$(ci_os_find_ubuntu_base_os_release)"; then
    VERSION_ID=""
    ci_os_load_os_release_file "$backup_file" || true
    version_id="${VERSION_ID:-}"
    if [[ "$version_id" =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "$version_id"
      return 0
    fi
  fi

  if [[ -f "$CI_OS_SYSTEM_OS_RELEASE" ]]; then
    # shellcheck disable=SC1090
    source "$CI_OS_SYSTEM_OS_RELEASE"
    version_id="${VERSION_ID:-}"
    if [[ "$version_id" =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "$version_id"
      return 0
    fi
  fi

  if command -v lsb_release >/dev/null 2>&1; then
    version_id="$(lsb_release -sr 2>/dev/null || true)"
    if [[ "$version_id" =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "$version_id"
      return 0
    fi
  fi

  echo "$CI_OS_UBUNTU_VERSION_ID"
}

# An exported CI_OS_VERSION wins: while an image is built /etc/os-release is still Ubuntu's own and carries none.
ci_os_marketing_version() {
  if [[ -n "${CI_OS_VERSION:-}" ]]; then
    echo "${CI_OS_VERSION}"
    return 0
  fi
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ -n "${CI_OS_VERSION:-}" ]]; then
      echo "${CI_OS_VERSION}"
      return 0
    fi
  fi
  echo "0.0.1"
}

# CI_OS_BUILD: the UTC day the image was built. A rewrite keeps the stamp already in the target file, so
# first-boot-rebrand.sh does not re-date the image to the day it first booted; a file without one gets today's.
ci_os_build_stamp() {
  local os_path="${1:-/etc/os-release}" stamp=""
  if [[ -r "$os_path" ]]; then
    stamp="$(sed -n 's/^CI_OS_BUILD="\{0,1\}\([0-9]\{8\}\)"\{0,1\}$/\1/p' "$os_path" | head -1 || true)"
  fi
  echo "${stamp:-$(date -u +%Y%m%d)}"
}

# Write Companion OS branding with Ubuntu-compatible machine identity (safe for apt/AMD/Docker). This is the
# only writer of the file: the image build (customize-chroot.sh, via 50-os-release.sh), the first-boot rebrand
# and the post-install re-skin all call it. Its output is pinned byte-for-byte (modulo the CI_OS_BUILD value)
# by tests/os-release-golden.sh, and a built ISO is checked against it by verify-iso.sh.
ci_os_write_branded_os_release() {
  local os_path="${1:-/etc/os-release}"
  local ci_version ubuntu_ver ubuntu_codename build
  ci_version="$(ci_os_marketing_version)"
  ubuntu_ver="$(ci_os_ubuntu_version_id)"
  ubuntu_codename="$(ci_os_ubuntu_codename)"
  build="$(ci_os_build_stamp "$os_path")"

  cat >"$os_path" <<EOF
NAME="Companion OS"
VERSION="${ubuntu_ver} LTS (Companion OS ${ci_version})"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Companion OS ${ci_version}"
VERSION_ID="${ubuntu_ver}"
HOME_URL="https://ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
UBUNTU_CODENAME=${ubuntu_codename}
VERSION_CODENAME=${ubuntu_codename}
CI_OS_ID=ci-os
CI_OS_VERSION="${ci_version}"
CI_OS_BUILD="${build}"
LOGO=ci-os-logo
EOF
  chmod 644 "$os_path"
}

# DISTRIB_ID stays Ubuntu: unattended-upgrades matches its allowed origins on ${distro_id} (which comes
# from this field), so any other value silently stops automatic security updates.
ci_os_write_branded_lsb_release() {
  local lsb_path="${1:-/etc/lsb-release}"
  local ci_version ubuntu_ver ubuntu_codename
  ci_version="$(ci_os_marketing_version)"
  ubuntu_ver="$(ci_os_ubuntu_version_id)"
  ubuntu_codename="$(ci_os_ubuntu_codename)"

  cat >"$lsb_path" <<EOF
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=${ubuntu_ver}
DISTRIB_CODENAME=${ubuntu_codename}
DISTRIB_DESCRIPTION="Companion OS ${ci_version}"
EOF
  chmod 644 "$lsb_path"
}
