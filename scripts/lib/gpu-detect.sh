#!/usr/bin/env bash
# Strix Halo / gfx1151 detection for CI-OS post-install messaging.
# shellcheck shell=bash

is_strix_halo_cpu_string() {
  local normalized="${1,,}"
  [[ -z "$normalized" ]] && return 1
  [[ "$normalized" == *"ryzen ai"* ]] || [[ "$normalized" == *"8060s"* ]] || [[ "$normalized" == *"strix halo"* ]]
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

print_comfyui_strix_halo_hint() {
  echo "[ROCm] Strix Halo (gfx1151) detected — ComfyUI ROCm apps require /dev/kfd and /dev/dri passthrough."
  echo "[ROCm] Prefer bf16/fp16 or GGUF Wan 2.2 weights; fp8_scaled models are unstable on gfx1151."
  echo "[ROCm] Troubleshooting: https://github.com/companionintelligence/CI-Marketplace/issues/615"
}
