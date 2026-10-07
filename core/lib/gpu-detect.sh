#!/usr/bin/env bash
# Strix Halo / gfx1151 detection, and the CI-OS hardware support rule.
# shellcheck shell=bash
#
# The headless GPU install (ROCm, Strix Halo GTT boot params, LACT, and the
# qwen3.6:27b model) runs only when ci_os_hardware_supported is true:
#   1. A confidently detected Strix Halo-class APU — Ryzen AI Max, gfx1151,
#      or Radeon 8060S. Bare "Ryzen AI" (Strix Point, for example the HX 370)
#      is not enough.
#   2. At least CI_OS_MIN_SUPPORTED_RAM_MIB of RAM (the 32/64/128 GB unified-
#      memory SKUs; just under a nominal 32 GB after firmware reservations).
# Anything else is unsupported. Callers skip the install and leave the desktop
# usable. is_strix_halo_from_system stays looser: it only prints a hint.

CI_OS_MIN_SUPPORTED_RAM_MIB=30000
CI_OS_HARDWARE_SUPPORT_FILE="/var/lib/setup-device/hardware-support"

is_strix_halo_cpu_string() {
  local normalized="${1,,}"
  [[ -z "$normalized" ]] && return 1
  [[ "$normalized" == *"ryzen ai"* ]] || [[ "$normalized" == *"8060s"* ]] || [[ "$normalized" == *"strix halo"* ]]
}

# Tight CPU match for the support rule. Does not match bare "ryzen ai".
is_confidently_strix_halo_cpu_string() {
  local normalized="${1,,}"
  [[ -z "$normalized" ]] && return 1
  [[ "$normalized" == *"ryzen ai max"* ]] || [[ "$normalized" == *"8060s"* ]] || [[ "$normalized" == *"strix halo"* ]]
}

rocminfo_shows_strix_halo() {
  if ! command -v rocminfo >/dev/null 2>&1; then
    return 1
  fi
  rocminfo 2>/dev/null | grep -qiE 'gfx1151|8060S|Strix Halo|RYZEN AI MAX'
}

is_strix_halo_from_system() {
  if rocminfo_shows_strix_halo; then
    return 0
  fi
  if command -v lscpu >/dev/null 2>&1; then
    local cpu_model
    cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name/ {sub(/^ +/, "", $2); print $2; exit}')"
    is_strix_halo_cpu_string "$cpu_model"
    return
  fi
  return 1
}

ci_os_total_ram_mib() {
  awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

ci_os_cpu_model() {
  if ! command -v lscpu >/dev/null 2>&1; then
    return 0
  fi
  lscpu 2>/dev/null | awk -F: '/Model name/ {sub(/^ +/, "", $2); print $2; exit}'
}

# Decide support from already-collected facts. Prints one reason line.
# rocminfo_hit is 1 when rocminfo already showed gfx1151 / 8060S / Strix Halo.
# Returns 0 when supported.
ci_os_hardware_support_decide() {
  local cpu_model="$1" ram_mib="$2" rocminfo_hit="$3"
  local reason

  if [[ "$rocminfo_hit" != 1 ]] && ! is_confidently_strix_halo_cpu_string "$cpu_model"; then
    reason="not a Strix Halo-class APU (need Ryzen AI Max / gfx1151 / Radeon 8060S)"
    printf '%s\n' "$reason"
    return 1
  fi
  if [[ ! "$ram_mib" =~ ^[0-9]+$ ]] || (( ram_mib < CI_OS_MIN_SUPPORTED_RAM_MIB )); then
    reason="Strix Halo-class APU with ${ram_mib:-0} MiB RAM, below the ${CI_OS_MIN_SUPPORTED_RAM_MIB} MiB floor"
    printf '%s\n' "$reason"
    return 1
  fi
  reason="Strix Halo-class APU with ${ram_mib} MiB RAM"
  printf '%s\n' "$reason"
  return 0
}

# Sets CI_OS_HARDWARE_SUPPORT_REASON. Returns 0 when this machine is supported.
ci_os_hardware_supported() {
  local cpu="" hit=0 ram rc=0
  if rocminfo_shows_strix_halo; then
    hit=1
  fi
  cpu="$(ci_os_cpu_model)"
  ram="$(ci_os_total_ram_mib)"
  CI_OS_HARDWARE_SUPPORT_REASON="$(ci_os_hardware_support_decide "$cpu" "$ram" "$hit")" || rc=$?
  return "$rc"
}

# Record the decision for the headless setup. Returns the same status as
# ci_os_hardware_supported. A machine that cannot be classified is unsupported.
ci_os_record_hardware_support() {
  local status="yes" rc=0
  if ! ci_os_hardware_supported; then
    status="no"
    rc=1
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "$(dirname "$CI_OS_HARDWARE_SUPPORT_FILE")"
    cat >"$CI_OS_HARDWARE_SUPPORT_FILE" <<EOF
supported=${status}
reason=${CI_OS_HARDWARE_SUPPORT_REASON}
checked=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    chmod 644 "$CI_OS_HARDWARE_SUPPORT_FILE"
  fi
  return "$rc"
}

print_comfyui_strix_halo_hint() {
  echo "[ROCm] Strix Halo (gfx1151) detected — ComfyUI ROCm apps require /dev/kfd and /dev/dri passthrough."
  echo "[ROCm] Prefer bf16/fp16 or GGUF Wan 2.2 weights; fp8_scaled models are unstable on gfx1151."
  echo "[ROCm] Troubleshooting: https://github.com/companionintelligence/CI-Marketplace/issues/615"
}
