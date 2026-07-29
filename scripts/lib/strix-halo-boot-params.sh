#!/usr/bin/env bash
#=============================================================================
# Unlock large unified GPU memory (GTT) on AMD Strix Halo-class APUs by
# setting kernel boot parameters:
#
#   iommu=pt amdgpu.gttsize=<N> ttm.pages_limit=<M>
#
# Without these, the amdgpu driver only exposes a small fixed VRAM carve-out
# to the GPU instead of letting it address the bulk of system RAM as
# GPU-visible GTT memory (needed for local-LLM / ROCm / Vulkan compute
# workloads on unified-memory APUs like Ryzen AI Max ("Strix Halo", gfx1151,
# Radeon 8060S)).
#
# GATING: only applies when BOTH are true, so unrelated hardware (non-AMD,
# AMD-but-not-Strix-Halo, or Strix-Halo-class CPUs in low-RAM SKUs) is left
# alone:
#   1. is_confidently_strix_halo() (below) detects a Strix Halo-class APU via
#      rocminfo (reusing gpu-detect.sh's rocminfo_shows_strix_halo, which
#      already requires gfx1151/8060S/"Strix Halo"/"RYZEN AI MAX" — already
#      tight), or via the same lscpu Model-name probe gpu-detect.sh uses,
#      narrowed to "ryzen ai max"/"8060s"/"strix halo". This intentionally
#      does NOT reuse gpu-detect.sh's is_strix_halo_from_system() as-is: that
#      function's lscpu fallback matches the bare substring "ryzen ai", which
#      also matches non-Halo chips (e.g. "AMD Ryzen AI 9 HX 370", Strix
#      Point). That looseness is fine for its actual job — printing a
#      troubleshooting hint — but is not confident enough to gate a kernel
#      boot-parameter change, which this task's constraints call out
#      explicitly ("Ryzen AI Max series + large RAM", "confidently
#      detected"). Same tool/field, same repo convention, tighter pattern.
#   2. Total system RAM is at or above MIN_TOTAL_RAM_MIB — Strix Halo ships
#      in 32/64/128 GB unified-memory configs, so this floor (just under a
#      nominal 32 GB after firmware/kernel reservations) filters out
#      unrelated small-RAM AMD laptops that could otherwise match #1 loosely.
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
# NOT SET HERE (firmware, not software): the BIOS-side UMA/VGM integrated-
# graphics framebuffer size also affects how much RAM is available. Set it to
# its smallest option (e.g. 1 GiB) in firmware setup rather than a large
# static carve-out — this script cannot do that for you.
#
# Idempotent: safe to re-run (e.g. every first-boot provisioning run, or
# after a RAM upgrade). Re-running strips any previously-applied iommu=pt /
# amdgpu.gttsize= / ttm.pages_limit= tokens before appending freshly computed
# ones, and only rewrites /etc/default/grub + runs update-grub when the
# resulting line actually changes.
#
# Can be run standalone or invoked from setup-fresh-ubuntu.sh.
#
# Usage:
#   sudo ./scripts/lib/strix-halo-boot-params.sh
#
# Requires root. When run standalone without root, exits with error.
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gpu-detect.sh
source "${SCRIPT_DIR}/gpu-detect.sh"

GRUB_DEFAULT_FILE="/etc/default/grub"
# ~29.3 GiB: below a nominal 32 GB Strix Halo SKU, but comfortably above
# what /proc/meminfo reports for a real 32 GB system after reservations.
MIN_TOTAL_RAM_MIB=30000

if [[ $(id -u) -ne 0 ]]; then
  echo "[-] Missing privileges. Run with: sudo $0"
  exit 1
fi

total_ram_mib() {
  awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

# Stricter sibling of gpu-detect.sh's is_strix_halo_from_system() — see the
# GATING note in the file header for why this doesn't just call that
# function directly.
is_confidently_strix_halo() {
  if rocminfo_shows_strix_halo; then
    return 0
  fi
  if command -v lscpu >/dev/null 2>&1; then
    local cpu_model normalized
    cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name/ {sub(/^ +/, "", $2); print $2; exit}')"
    normalized="${cpu_model,,}"
    [[ -n "$normalized" ]] || return 1
    [[ "$normalized" == *"ryzen ai max"* ]] || [[ "$normalized" == *"8060s"* ]] || [[ "$normalized" == *"strix halo"* ]]
    return
  fi
  return 1
}

if ! is_confidently_strix_halo; then
  echo "[*] No AMD Strix Halo-class APU detected (Ryzen AI Max / gfx1151 / Radeon 8060S) — skipping GTT boot-param tuning."
  exit 0
fi

TOTAL_MIB="$(total_ram_mib)"
if (( TOTAL_MIB < MIN_TOTAL_RAM_MIB )); then
  echo "[*] Strix Halo-class CPU detected, but system RAM (${TOTAL_MIB} MiB) is below the ${MIN_TOTAL_RAM_MIB} MiB large-unified-memory floor — skipping GTT boot-param tuning."
  exit 0
fi

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
    iommu=pt|amdgpu.gttsize=*|ttm.pages_limit=*) continue ;;
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
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${new_line}|" "$GRUB_DEFAULT_FILE"
echo "[+] Updated ${GRUB_DEFAULT_FILE}: ${new_line}"

if command -v update-grub >/dev/null 2>&1; then
  update-grub
  echo "[+] Ran update-grub."
else
  echo "[-] update-grub not found; boot params written to ${GRUB_DEFAULT_FILE} but GRUB config was NOT regenerated. Run update-grub manually." >&2
fi

echo "[*] Reboot required for the new kernel boot parameters (iommu=pt, amdgpu.gttsize, ttm.pages_limit) to take effect."
