#!/usr/bin/env bash
#=============================================================================
# Unlock large unified GPU memory (GTT) on AMD Strix Halo-class APUs by
# setting kernel boot parameters:
#
#   iommu=pt amdgpu.gttsize=<N> ttm.pages_limit=<M>
#
# and, on a machine that has AMD's out-of-tree DKMS amdgpu driver, also
#
#   amdttm.pages_limit=<M>
#
# Without these, the amdgpu driver only exposes a small fixed VRAM carve-out
# to the GPU instead of letting it address the bulk of system RAM as
# GPU-visible GTT memory (needed for local-LLM / ROCm / Vulkan compute
# workloads on unified-memory APUs like Ryzen AI Max ("Strix Halo", gfx1151,
# Radeon 8060S)).
#
# GATING: ci_os_hardware_supported in core/lib/gpu-detect.sh. Both must be
# true, or this script leaves GRUB alone:
#   1. Confident Strix Halo-class APU (Ryzen AI Max / gfx1151 / Radeon 8060S).
#      Bare "Ryzen AI" (Strix Point, e.g. HX 370) does not match.
#   2. Total RAM at or above CI_OS_MIN_SUPPORTED_RAM_MIB (the 32 GB floor).
#
# SIZING: gttsize (MiB) and pages_limit (4 KiB pages) are computed from total
# system RAM rather than hard-coded to one machine's numbers:
#   reserve_mib = max(4096, total_mib / 8)   # keep >=12.5% (>=4 GiB) for the OS
#   gttsize_mib = total_mib - reserve_mib
#   pages_limit = gttsize_mib * 256          # MiB -> 4 KiB pages
# This reproduces the values used by both reference setups (sypherin/
# strix-halo-setup and hec-ovi/llama-vulkan-strix) on their respective total
# RAM sizes.
#
# THE DKMS DRIVER NEEDS ITS OWN PARAMETER: AMD's amdgpu-dkms package is a
# complete out-of-tree amdgpu that carries a private copy of the kernel's TTM
# memory manager, built as the module "amdttm". That amdgpu uses amdttm and
# never the kernel's "ttm", so ttm.pages_limit does not reach it: amdgpu.gttsize
# promises 107 GiB of GTT while amdttm still lets the GPU pin only its default,
# half of RAM (61 GiB). Measured on core-7 (125,780 MiB, amdgpu-dkms 6.19.4) on
# 2026-10-19: the command line had gttsize=110058 and ttm.pages_limit=28174848,
# /sys/module/ttm/parameters/pages_limit read 28174848 and
# /sys/module/amdttm/parameters/pages_limit read 16099952. The inbox amdgpu (the
# supported setup on Ubuntu 26.04) reads ttm.pages_limit, so a node without the
# DKMS driver gets exactly the parameters it always got.
#
# The DKMS driver counts as present when ANY of these holds (amdgpu_dkms_present
# below). A false positive adds a parameter the kernel ignores; a false negative
# leaves the GPU capped, so the check leans toward "present":
#   1. /sys/module/amdttm exists: the DKMS TTM is loaded right now.
#   2. A built amdttm module exists under /lib/modules/*/updates/dkms/ for any
#      installed kernel: true once DKMS has built the driver, so also BEFORE the
#      first boot into that build, which a loaded-module check cannot see.
#   3. dpkg reports the amdgpu-dkms package as "installed". A removed package
#      that kept its config files is "config-files" (fzzy, 2026-10-19) and does
#      not count; plain "does dpkg know the package" would say yes there.
# After installing or removing the DKMS driver, re-run this script.
#
# NOT SET HERE (firmware, not software): the BIOS-side UMA/VGM integrated-
# graphics framebuffer size also affects how much RAM is available. Set it to
# its smallest option (e.g. 1 GiB) in firmware setup rather than a large
# static carve-out — this script cannot do that for you.
#
# Idempotent: safe to re-run (e.g. every first-boot provisioning run, or
# after a RAM upgrade). Re-running strips any previously-applied iommu=pt /
# amdgpu.gttsize= / ttm.pages_limit= / amdttm.pages_limit= tokens before
# appending freshly computed ones, and only rewrites /etc/default/grub + runs
# update-grub when the resulting line actually changes.
#
# THE OTHER PARAMETERS ON THE LINE ARE DATA: they come back exactly as they
# were, and the line is written by grub_default_with_line below, which hands
# it to printf as an argument, so no tool reads anything in it as syntax. It
# used to be written by sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${new_line}|",
# where & stands for the matched text, a backslash escapes and | ends the
# expression. Reproduced with GNU sed 4.9 on 2026-10-19: foo=a&b corrupted the
# line while the script still exited 0 and ran update-grub; foo=a|b made sed
# fail; a backslash-n split the line in two; and an escaped \` or \$ lost its
# backslash, so an escaped backtick became a command that update-grub (it
# sources this file as root) would run.
#
# Can be run standalone or invoked from provision.sh.
#
# Usage:
#   sudo ./backends/ubuntu/lib/strix-halo-boot-params.sh
#
# Requires root. When run standalone without root, exits with error.
#
# Test hooks: the three paths below default to the real ones and are set only by
# backends/ubuntu/lib/tests/strix-halo-boot-params.sh, which rehearses this
# script against throwaway files (it never touches /etc/default/grub).
#   CI_OS_GRUB_DEFAULT_FILE  /etc/default/grub
#   CI_OS_MODULES_DIR        /lib/modules
#   CI_OS_SYSFS_MODULE_DIR   /sys/module
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../core/lib/gpu-detect.sh
source "${SCRIPT_DIR}/../../../core/lib/gpu-detect.sh"

GRUB_DEFAULT_FILE="${CI_OS_GRUB_DEFAULT_FILE:-/etc/default/grub}"
MODULES_DIR="${CI_OS_MODULES_DIR:-/lib/modules}"
SYSFS_MODULE_DIR="${CI_OS_SYSFS_MODULE_DIR:-/sys/module}"

# Returns 0 when AMD's out-of-tree DKMS amdgpu driver is, or on the next boot
# will be, the one the GPU uses; sets DKMS_WHY to the first sign found. The three
# signs and why each is there are in the header ("THE DKMS DRIVER NEEDS ITS OWN
# PARAMETER"). Nothing here writes anything.
DKMS_WHY=""
amdgpu_dkms_present() {
  local module pkg_status
  if [[ -d "${SYSFS_MODULE_DIR}/amdttm" ]]; then
    DKMS_WHY="the module amdttm is loaded"
    return 0
  fi
  for module in "${MODULES_DIR}"/*/updates/dkms/amdttm.ko*; do
    if [[ -e "$module" ]]; then
      DKMS_WHY="amdttm is built at ${module}"
      return 0
    fi
  done
  # ${db:Status-Status} is dpkg-query's own format string, not a shell expansion.
  # shellcheck disable=SC2016
  pkg_status="$(dpkg-query -W -f '${db:Status-Status}' amdgpu-dkms 2>/dev/null || true)"
  if [[ "$pkg_status" == "installed" ]]; then
    DKMS_WHY="the package amdgpu-dkms is installed"
    return 0
  fi
  return 1
}

# Prints the file $1 with every line that sets GRUB_CMDLINE_LINUX_DEFAULT replaced by the line $2 and every other line as it was,
# a last line without a newline included. A line reaches printf only as an argument and is read with IFS= and -r, so nothing in
# it (& | \ $ ` " ' % *) is read as syntax. read drops a NUL byte, which this shell fragment does not have. Returns 1 when a
# write fails.
grub_default_with_line() {
  local line eol
  while :; do
    if IFS= read -r line; then
      eol=$'\n'
    elif [[ -n "$line" ]]; then
      eol=""
    else
      return 0
    fi
    case "$line" in
      GRUB_CMDLINE_LINUX_DEFAULT=*) printf '%s%s' "$2" "$eol" || return 1 ;;
      *) printf '%s%s' "$line" "$eol" || return 1 ;;
    esac
  done <"$1"
}

if [[ $(id -u) -ne 0 ]]; then
  echo "[-] Missing privileges. Run with: sudo $0"
  exit 1
fi

if ! ci_os_hardware_supported; then
  echo "[*] Unsupported hardware (${CI_OS_HARDWARE_SUPPORT_REASON}) — skipping GTT boot-param tuning."
  exit 0
fi

TOTAL_MIB="$(ci_os_total_ram_mib)"

RESERVE_MIB=$(( TOTAL_MIB / 8 ))
if (( RESERVE_MIB < 4096 )); then
  RESERVE_MIB=4096
fi
GTT_MIB=$(( TOTAL_MIB - RESERVE_MIB ))
PAGES_LIMIT=$(( GTT_MIB * 256 ))

echo "[*] Strix Halo-class APU detected with ${TOTAL_MIB} MiB total RAM — targeting amdgpu.gttsize=${GTT_MIB} ttm.pages_limit=${PAGES_LIMIT}"

if [[ ! -f "$GRUB_DEFAULT_FILE" ]]; then
  echo "[-] ${GRUB_DEFAULT_FILE} not found; cannot set kernel boot parameters." >&2
  exit 1
fi

STRIX_PARAMS="iommu=pt amdgpu.gttsize=${GTT_MIB} ttm.pages_limit=${PAGES_LIMIT}"
STRIX_PARAM_NAMES="iommu=pt, amdgpu.gttsize, ttm.pages_limit"
if amdgpu_dkms_present; then
  echo "[*] DKMS amdgpu driver found (${DKMS_WHY}). Its TTM is the module amdttm, which ignores ttm.pages_limit; also targeting amdttm.pages_limit=${PAGES_LIMIT}"
  STRIX_PARAMS="${STRIX_PARAMS} amdttm.pages_limit=${PAGES_LIMIT}"
  STRIX_PARAM_NAMES="${STRIX_PARAM_NAMES}, amdttm.pages_limit"
fi

current_line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_FILE" | tail -n1 || true)"
if [[ -z "$current_line" ]]; then
  echo "[-] No GRUB_CMDLINE_LINUX_DEFAULT line found in ${GRUB_DEFAULT_FILE}; refusing to guess a format." >&2
  exit 1
fi

current_value="$(sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/' <<< "$current_line")"

# Guard against formats the extraction above can't actually handle (e.g.
# single-quoted GRUB_CMDLINE_LINUX_DEFAULT='...'). If the line isn't in the
# expected double-quoted form, the sed above is a no-op and current_value
# would silently become the entire raw line, which we must not tokenize and
# re-wrap. Refuse to guess, same as the missing-line case above.
if [[ "$current_line" != "GRUB_CMDLINE_LINUX_DEFAULT=\"${current_value}\"" ]]; then
  echo "[-] ${GRUB_DEFAULT_FILE}'s GRUB_CMDLINE_LINUX_DEFAULT line is not in the expected double-quoted format; refusing to guess a format: ${current_line}" >&2
  exit 1
fi

# Idempotent rebuild: drop any tokens we manage (from a prior run, possibly
# with stale RAM-based values), keep everything else untouched, then append
# the freshly computed set.
cleaned_value=""
for tok in $current_value; do
  case "$tok" in
    iommu=pt|amdgpu.gttsize=*|ttm.pages_limit=*|amdttm.pages_limit=*) continue ;;
    *) cleaned_value="${cleaned_value:+$cleaned_value }${tok}" ;;
  esac
done

if [[ -n "$cleaned_value" ]]; then
  new_value="${cleaned_value} ${STRIX_PARAMS}"
else
  new_value="${STRIX_PARAMS}"
fi

if [[ "$current_value" == "$new_value" ]]; then
  echo "[*] GRUB_CMDLINE_LINUX_DEFAULT already has the correct Strix Halo boot params; nothing to do."
  exit 0
fi

cp "$GRUB_DEFAULT_FILE" "${GRUB_DEFAULT_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
new_line="GRUB_CMDLINE_LINUX_DEFAULT=\"${new_value}\""

# Swap the file in one rename, as sed -i did, so a failure leaves the old one as it was: the new content is written to a file
# beside it that starts as a copy of it (cp -p, so the mode and owner carry over) and is renamed over it.
grub_tmp="${GRUB_DEFAULT_FILE}.tmp.$$"
if ! { cp -p -- "$GRUB_DEFAULT_FILE" "$grub_tmp" \
       && grub_default_with_line "$GRUB_DEFAULT_FILE" "$new_line" >"$grub_tmp" \
       && mv -f -- "$grub_tmp" "$GRUB_DEFAULT_FILE"; }; then
  rm -f -- "$grub_tmp"
  echo "[-] Could not rewrite ${GRUB_DEFAULT_FILE}; the file was left as it was and update-grub was not run." >&2
  exit 1
fi
echo "[+] Updated ${GRUB_DEFAULT_FILE}: ${new_line}"

if command -v update-grub >/dev/null 2>&1; then
  update-grub
  echo "[+] Ran update-grub."
else
  echo "[-] update-grub not found; boot params written to ${GRUB_DEFAULT_FILE} but GRUB config was NOT regenerated. Run update-grub manually." >&2
fi

echo "[*] Reboot required for the new kernel boot parameters (${STRIX_PARAM_NAMES}) to take effect."
