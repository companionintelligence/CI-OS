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

# ===========================================================================
# Hardware-fit gate for model downloads
#
# "Does THIS machine have the memory to run model X?" answered from the data in core/manifest/model-packs.yaml
# (min_ram_gb / min_vram_gb, the same numbers `ci-stick models list` shows) against the RAM and GPU memory
# found here. The Strix Halo rule above (ci_os_hardware_supported) stays what it was: the vendor/class gate for
# the headless GPU install. This is the data-driven gate every provisioner can ask about any model, so a 16 GB
# laptop booted from a Companion Stick is not offered a 70B model, and Arch gets the protection that only
# Ubuntu's qwen3.6:27b pull had.
#
#   ci_os_model_fits <name[:tag]>        0 fits, 1 does not fit, 2 no data (unknown model, no model-packs.yaml)
#   ci_os_model_gate_allows <name[:tag]> for provisioners: 0 = go ahead, 1 = skip. "No data" never blocks a pull
#                                        (the file cannot be found on a stripped-down image): it is reported only.
#   ci_os_model_fit_decide ...           the pure decision, facts in, one reason line out (unit-tested)
#
# Both set CI_OS_MODEL_FIT_REASON. Facts come from /proc/meminfo, nvidia-smi, rocm-smi and amdgpu sysfs; every
# one of them is optional (a missing detector means "no GPU memory here", i.e. CPU-only, never an error).
#
# The rules, and why:
#   RAM     needs >= min_ram_gb GiB x CI_OS_MODEL_RAM_PCT %. A "32 GB" machine reports about 30,000 MiB of MemTotal
#           after firmware reservations (that is why CI_OS_MIN_SUPPORTED_RAM_MIB is 30000), so the floor for a
#           32 GB model is 29,818 MiB: whatever the Strix Halo rule accepted still passes this one.
#   VRAM    min_vram_gb null = no GPU requirement. A number is the practical minimum of discrete-GPU memory
#           (model-packs.yaml header): GPU memory >= min_vram_gb GiB x CI_OS_MODEL_VRAM_PCT % (a 24 GB card
#           reports 24,564 of 24,576 MiB). A CPU-only machine therefore does not fit those models, however much
#           RAM it has. CI_OS_FIT_CPU_OK=1 relaxes that for someone who accepts CPU speed.
#   Unified memory machines (Strix Halo: the GPU shares system RAM) have no separate pool: the pool is MemTotal
#           plus the BIOS carve-out (a 128 GB machine with a large carve-out shows a small MemTotal), and it has
#           to cover max(min_ram_gb, min_vram_gb) at the RAM percentage. CI-Hub applies a 0.7 fraction to
#           unified memory for footprints; these thresholds are already practical minimums, so a second
#           fraction here would reject the 32 GB class the hardware rule above exists to support.
#
# Overrides (tests, support): CI_OS_FIT_RAM_MIB, CI_OS_FIT_VRAM_MIB, CI_OS_FIT_UNIFIED=0|1, CI_OS_FIT_CPU_OK=1,
# CI_OS_MODEL_FIT_OVERRIDE=allow|deny, CI_OS_MODEL_PACKS_FILE, CI_OS_PROC_MEMINFO, CI_OS_SYSFS_DRM.
# Written for bash 5 (the images) and kept bash 3.2 clean so the host-side tests can run it on a stock Mac.
# ===========================================================================

CI_OS_MODEL_RAM_PCT=91
CI_OS_MODEL_VRAM_PCT=95
CI_OS_GPU_DETECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || CI_OS_GPU_DETECT_DIR=""

# Reads model-packs.yaml (flow-style model entries with anchors and aliases) and prints one row per model:
#   pack <TAB> name <TAB> tag <TAB> min_ram_gb <TAB> min_vram_gb ("-" = null)
# Identical output under BSD awk, mawk and gawk, and identical to Ruby's YAML parser on the checked-in file (tested).
CI_OS_PACKS_AWK=''
IFS= read -r -d '' CI_OS_PACKS_AWK <<'AWKEOF' || true
function trimq(s,   q) {
  q = sprintf("%c", 39)
  gsub("^[ \t\"" q "]+", "", s); gsub("[ \t\"" q "]+$", "", s)
  return s
}
function field(b, key,   re, v) {
  re = "(^|[{,[:space:]])" key ":[[:space:]]*"
  if (!match(b, re)) return ""
  v = substr(b, RSTART + RLENGTH)
  sub(/[,}].*$/, "", v)
  return trimq(v)
}
function row(b,   n, t, r, v) {
  n = field(b, "name"); t = field(b, "tag"); r = field(b, "min_ram_gb"); v = field(b, "min_vram_gb")
  if (t == "") t = "latest"
  if (v == "" || v == "null" || v == "~") v = "-"
  return pack "\t" n "\t" t "\t" r "\t" v
}
{
  line = $0
  sub(/\r$/, "", line)
  sub(/(^|[ \t])#.*$/, "", line)
  if (line ~ /^[ \t]*$/) next
  if (collecting) {
    buf = buf " " line
    nopen += gsub(/\{/, "{", line); nclose += gsub(/\}/, "}", line)
    if (nopen <= nclose) { collecting = 0; rec = row(buf); if (anchor != "") anchors[anchor] = rec; print rec }
    next
  }
  if (line ~ /^[ \t]*-[ \t]+name:[ \t]*[^ \t{]/) {
    p = line; sub(/^[ \t]*-[ \t]+name:[ \t]*/, "", p); pack = trimq(p); next
  }
  if (line ~ /^[ \t]*-[ \t]+\*[A-Za-z0-9_]+[ \t]*$/) {
    a = line; sub(/^[ \t]*-[ \t]+\*/, "", a); sub(/[ \t]+$/, "", a)
    if (a in anchors) { rec = anchors[a]; sub(/^[^\t]*/, pack, rec); print rec }
    next
  }
  if (line ~ /^[ \t]*-[ \t]+(&[A-Za-z0-9_]+[ \t]+)?\{/) {
    anchor = ""
    if (match(line, /&[A-Za-z0-9_]+/)) anchor = substr(line, RSTART + 1, RLENGTH - 1)
    buf = line; nopen = gsub(/\{/, "{", line); nclose = gsub(/\}/, "}", line)
    if (nopen <= nclose) { rec = row(buf); if (anchor != "") anchors[anchor] = rec; print rec }
    else collecting = 1
  }
}
AWKEOF

# Path of model-packs.yaml: $CI_OS_MODEL_PACKS_FILE, the repo/bootstrap tree next to this library, then the image.
ci_os_model_packs_file() {
  local f
  for f in "${CI_OS_MODEL_PACKS_FILE:-}" \
           "${CI_OS_GPU_DETECT_DIR}/../manifest/model-packs.yaml" \
           /usr/share/ci-os/model-packs.yaml \
           /etc/ci-os/model-packs.yaml; do
    if [[ -n "$f" && -f "$f" ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# ci_os_model_packs_rows [file]: every model of every pack (see CI_OS_PACKS_AWK).
ci_os_model_packs_rows() {
  local file="${1:-}"
  [[ -n "$file" ]] || file="$(ci_os_model_packs_file)" || return 1
  LC_ALL=C awk "$CI_OS_PACKS_AWK" "$file"
}

# ci_os_model_requirements <name:tag> [file]: prints "min_ram_gb min_vram_gb" ("-" = no GPU requirement).
# A model that appears in several packs is listed at one size (model-packs.yaml rule); if the rows ever
# disagree, the larger number wins, which can only make the gate stricter.
ci_os_model_requirements() {
  local ref="$1" file="${2:-}" name tag
  name="${ref%%:*}"
  tag="${ref#*:}"
  [[ "$tag" != "$ref" ]] || tag=latest
  ci_os_model_packs_rows "$file" | LC_ALL=C awk -F'\t' -v n="$name" -v t="$tag" '
    $2 == n && $3 == t {
      found = 1
      if ($4 + 0 > ram + 0) ram = $4
      if ($5 != "-" && (vram == "" || $5 + 0 > vram + 0)) vram = $5
    }
    END { if (found) print ram, (vram == "" ? "-" : vram) }'
}

# ci_os_fit_ram_mib: MemTotal in MiB (or the override). Prints nothing when it cannot be read.
ci_os_fit_ram_mib() {
  if [[ -n "${CI_OS_FIT_RAM_MIB:-}" ]]; then
    printf '%s\n' "$CI_OS_FIT_RAM_MIB"
    return 0
  fi
  LC_ALL=C awk '/^MemTotal:/ { print int($2 / 1024); exit }' "${CI_OS_PROC_MEMINFO:-/proc/meminfo}" 2>/dev/null
}

# ci_os_fit_vram_mib: dedicated GPU memory in MiB, summed over GPUs: NVIDIA (nvidia-smi), then AMD (rocm-smi,
# else the amdgpu sysfs files). Prints 0 when there is none or no detector works. On a unified-memory machine
# this is only the BIOS carve-out.
ci_os_fit_vram_mib() {
  if [[ -n "${CI_OS_FIT_VRAM_MIB:-}" ]]; then
    printf '%s\n' "$CI_OS_FIT_VRAM_MIB"
    return 0
  fi
  local nv=0 amd=0 out f v drm="${CI_OS_SYSFS_DRM:-/sys/class/drm}"
  if command -v nvidia-smi >/dev/null 2>&1; then
    out="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
    nv="$(printf '%s\n' "$out" | LC_ALL=C awk '$1 ~ /^[0-9]+$/ { s += $1 } END { print s + 0 }')"
  fi
  if command -v rocm-smi >/dev/null 2>&1; then
    out="$(rocm-smi --showmeminfo vram --csv 2>/dev/null || true)"
    [[ -n "$out" ]] || out="$(rocm-smi --showmeminfo vram 2>/dev/null || true)"
    amd="$(printf '%s\n' "$out" | LC_ALL=C awk -F, '
      NR == 1 && index($0, ",") > 0 && tolower($0) ~ /vram total memory \(b\)/ { for (i = 1; i <= NF; i++) if (tolower($i) ~ /vram total memory \(b\)/) col = i; csv = 1; next }
      csv && col && $col ~ /^[0-9]+$/ { s += $col; next }
      !csv && tolower($0) ~ /vram total memory \(b\)/ { v = $0; sub(/^.*:/, "", v); gsub(/[^0-9]/, "", v); if (v != "") s += v }
      END { printf "%d\n", s / 1048576 }')"
  fi
  if [[ "${amd:-0}" -eq 0 ]]; then
    for f in "$drm"/card*/device/mem_info_vram_total; do
      [[ -r "$f" ]] || continue
      [[ "$(cat "${f%/mem_info_vram_total}/vendor" 2>/dev/null)" == 0x1002 ]] || continue
      v="$(cat "$f" 2>/dev/null)"
      [[ "$v" =~ ^[0-9]+$ ]] && amd=$((amd + v / 1048576))
    done
  fi
  printf '%s\n' "$(( ${nv:-0} + ${amd:-0} ))"
}

# ci_os_fit_unified: 1 on a unified-memory machine (the GPU draws from system RAM), else 0. Today that is the
# Strix Halo class the hardware rule above already names (same strings as is_confidently_strix_halo_cpu_string,
# repeated here without ${var,,} so it also runs on bash 3.2; a test keeps the two in step).
ci_os_fit_unified() {
  case "${CI_OS_FIT_UNIFIED:-}" in
    0|1) printf '%s\n' "$CI_OS_FIT_UNIFIED"; return 0 ;;
  esac
  local cpu
  if rocminfo_shows_strix_halo; then
    echo 1
    return 0
  fi
  cpu="$(ci_os_cpu_model | tr '[:upper:]' '[:lower:]')"
  case "$cpu" in
    *"ryzen ai max"*|*8060s*|*"strix halo"*) echo 1 ;;
    *) echo 0 ;;
  esac
}

# ci_os_model_fit_decide <min_ram_gb> <min_vram_gb|-> <ram_mib> <vram_mib> <unified 0|1>
# Pure: prints one reason line, returns 0 fits / 1 does not fit / 2 unusable requirement data.
ci_os_model_fit_decide() {
  local min_ram="${1:-}" min_vram="${2:--}" ram="${3:-}" vram="${4:-0}" unified="${5:-0}"
  local ram_floor vram_floor pool need

  if [[ ! "$min_ram" =~ ^[0-9]+$ ]] || { [[ "$min_vram" != "-" ]] && [[ ! "$min_vram" =~ ^[0-9]+$ ]]; }; then
    printf 'unusable requirements (min_ram_gb=%s, min_vram_gb=%s)\n' "$min_ram" "$min_vram"
    return 2
  fi
  if [[ ! "$ram" =~ ^[0-9]+$ ]] || (( ram == 0 )); then
    printf 'cannot determine this machine'"'"'s RAM\n'
    return 1
  fi
  [[ "$vram" =~ ^[0-9]+$ ]] || vram=0

  ram_floor=$(( min_ram * 1024 * CI_OS_MODEL_RAM_PCT / 100 ))
  pool="$ram"
  if [[ "$unified" == 1 ]]; then
    pool=$(( ram + vram ))
    need="$min_ram"
    if [[ "$min_vram" != "-" ]] && (( min_vram > need )); then need="$min_vram"; fi
    ram_floor=$(( need * 1024 * CI_OS_MODEL_RAM_PCT / 100 ))
    if (( pool < ram_floor )); then
      printf 'needs about %s GB of unified memory (%s MiB); this machine has %s MiB\n' "$need" "$ram_floor" "$pool"
      return 1
    fi
    printf 'unified-memory machine with %s MiB covers %s GB\n' "$pool" "$need"
    return 0
  fi

  if (( ram < ram_floor )); then
    printf 'needs %s GB of RAM (%s MiB); this machine has %s MiB\n' "$min_ram" "$ram_floor" "$ram"
    return 1
  fi
  if [[ "$min_vram" == "-" ]]; then
    printf 'fits: %s MiB of RAM, no GPU requirement\n' "$ram"
    return 0
  fi
  vram_floor=$(( min_vram * 1024 * CI_OS_MODEL_VRAM_PCT / 100 ))
  if (( vram >= vram_floor )); then
    printf 'fits: %s MiB of RAM and %s MiB of GPU memory\n' "$ram" "$vram"
    return 0
  fi
  if [[ "${CI_OS_FIT_CPU_OK:-0}" == 1 ]]; then
    printf 'fits on the CPU (CI_OS_FIT_CPU_OK=1): %s MiB of RAM; the model wants %s GB of GPU memory\n' "$ram" "$min_vram"
    return 0
  fi
  if (( vram == 0 )); then
    printf 'needs %s GB of GPU memory (%s MiB); none detected, this machine would run it on the CPU\n' "$min_vram" "$vram_floor"
  else
    printf 'needs %s GB of GPU memory (%s MiB); this machine has %s MiB\n' "$min_vram" "$vram_floor" "$vram"
  fi
  return 1
}

# ci_os_model_fits <name[:tag]>: look the model up, collect the facts, decide. Sets CI_OS_MODEL_FIT_REASON.
# shellcheck disable=SC2034  # read by the callers
ci_os_model_fits() {
  local ref="${1:-}" file req rc=0 ram vram unified
  CI_OS_MODEL_FIT_REASON=""
  if [[ -z "$ref" || ! "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]]; then
    CI_OS_MODEL_FIT_REASON="not a model reference: '${ref}'"
    return 2
  fi
  case "${CI_OS_MODEL_FIT_OVERRIDE:-}" in
    allow) CI_OS_MODEL_FIT_REASON="allowed by CI_OS_MODEL_FIT_OVERRIDE"; return 0 ;;
    deny)  CI_OS_MODEL_FIT_REASON="refused by CI_OS_MODEL_FIT_OVERRIDE"; return 1 ;;
  esac
  [[ "$ref" == *:* ]] || ref="$ref:latest"
  if ! file="$(ci_os_model_packs_file)"; then
    CI_OS_MODEL_FIT_REASON="model-packs.yaml not found"
    return 2
  fi
  req="$(ci_os_model_requirements "$ref" "$file")"
  if [[ -z "$req" ]]; then
    CI_OS_MODEL_FIT_REASON="${ref} is not listed in model-packs.yaml"
    return 2
  fi
  ram="$(ci_os_fit_ram_mib)"
  vram="$(ci_os_fit_vram_mib)"
  unified="$(ci_os_fit_unified)"
  local need_ram need_vram
  IFS=' ' read -r need_ram need_vram <<< "$req"         # not an unquoted $req: the caller's IFS must not matter
  CI_OS_MODEL_FIT_REASON="$(ci_os_model_fit_decide "$need_ram" "$need_vram" "$ram" "$vram" "$unified")" || rc=$?
  return "$rc"
}

# shellcheck disable=SC2034  # read by the callers
ci_os_model_gate_allows() {
  local rc=0
  ci_os_model_fits "$1" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) CI_OS_MODEL_FIT_REASON="no fit data (${CI_OS_MODEL_FIT_REASON}); not blocking"; return 0 ;;
  esac
}
