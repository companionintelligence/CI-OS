#!/usr/bin/env bash
#=============================================================================
# Test: the hardware-fit gate for model downloads (core/lib/gpu-detect.sh: ci_os_model_fits and friends)
#
# What it proves, on fixtures and PATH stubs (no root, no Docker, no network, no GPU):
#   * model-packs.yaml is read correctly by the awk reader: every pack and model, aliases resolved, identical to
#     what Ruby's YAML parser says about the same file (when Ruby is installed), and the reader's edge cases;
#   * the decision table: RAM and GPU memory against min_ram_gb / min_vram_gb, to the megabyte at each boundary,
#     CPU-only machines, unified-memory machines (Strix Halo), a missing or broken detector, and the property that
#     nothing the old rule (Strix Halo with 30,000 MiB) accepted for the 32 GB model is refused now;
#   * the detectors: nvidia-smi, rocm-smi (CSV and plain), amdgpu sysfs, /proc/meminfo, lscpu/rocminfo;
#   * ci_os_model_fits / ci_os_model_gate_allows end to end, including "no data never blocks";
#   * the wiring in the Ubuntu and Arch provisioners: their real pull_ollama_models functions, run against stubs,
#     do or do not pull qwen3.6:27b.
# models-mutation.sh runs this file against deliberately broken copies of the code to prove it can fail.
#
#   bash backends/ubuntu/chroot/tests/models-gate.sh        (bash 3.2 or 5; awk: BSD, mawk or gawk)
#
# Exit status: non-zero if any check fails; 2 if it cannot run here.
#
# (c) Companion Intelligence - Lifescope Inc
#=============================================================================
# shellcheck disable=SC1090,SC2034  # the library is sourced by a variable path; some variables are read only inside subshells
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models-testlib.sh
. "$HERE/lib/models-testlib.sh"

default_stubs
# shellcheck source=/dev/null
. "$GPU_SH"

echo "== the YAML reader"
rows="$(ci_os_model_packs_rows "$PACKS_FILE")"
# The catalog grows (other work adds packs), so the checks are: the packs this file has always had keep their sizes,
# and every row of every pack is well formed. The exact comparison with a real YAML parser covers the rest.
for spec in starter:4 balanced:5 coding:5 vision:4 large:5 stick-128:21 stick-128-oci:19; do
  t_eq "pack ${spec%%:*} has ${spec##*:} models" "${spec##*:}" "$(printf '%s\n' "$rows" | awk -F'\t' -v p="${spec%%:*}" '$1 == p' | wc -l | tr -d ' ')"
done
t_eq "every row has a pack, a name, a tag, a whole min_ram_gb and a whole min_vram_gb or '-'" 0 \
  "$(printf '%s\n' "$rows" | awk -F'\t' 'NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 !~ /^[0-9]+$/ || ($5 != "-" && $5 !~ /^[0-9]+$/)' | wc -l | tr -d ' ')"
if command -v ruby >/dev/null 2>&1; then
  ruby -ryaml -e '
    d = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0])
    d["packs"].each { |p| p["models"].each { |m| puts [p["name"], m["name"], m["tag"], m["min_ram_gb"], m["min_vram_gb"].nil? ? "-" : m["min_vram_gb"]].join("\t") } }
  ' "$PACKS_FILE" > "$WORK/ruby.tsv" 2>/dev/null
  if [ -s "$WORK/ruby.tsv" ]; then
    printf '%s\n' "$rows" > "$WORK/awk.tsv"
    if cmp -s "$WORK/ruby.tsv" "$WORK/awk.tsv"; then
      t_pass "the awk reader and Ruby's YAML parser agree on all $(wc -l < "$WORK/awk.tsv" | tr -d ' ') rows"
    else
      t_fail "the awk reader differs from Ruby's YAML parser: $(diff "$WORK/ruby.tsv" "$WORK/awk.tsv" | head -5)"
    fi
  else
    t_skip "Ruby on this machine could not load the file (too old for YAML aliases?): the cross-check against a real YAML parser is skipped"
  fi
else
  t_skip "no Ruby here: the cross-check against a real YAML parser is skipped"
fi
t_eq "alias lines resolve (stick-128-oci: qwen3.6:27b needs 32 GB RAM and 24 GB VRAM)" "stick-128-oci${TAB}qwen3.6${TAB}27b${TAB}32${TAB}24" \
  "$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "stick-128-oci" && $2 == "qwen3.6"')"
t_eq "a null min_vram_gb is '-'" "starter${TAB}gemma3${TAB}1b${TAB}4${TAB}-" "$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "starter" && $2 == "gemma3" && $3 == "1b"')"

cat > "$WORK/edge.yaml" <<'YEOF'
# a comment, and a pack with every awkward spelling
packs:
  - name: odd      # trailing comment
    description: "quoted: with colon"
    models:
      - {name: "quoted-name", tag: '7b', digest: null, license: Gemma Terms of Use,
         min_ram_gb: 12, min_vram_gb: 8, platforms: *all}
      - &first {name: plain, digest: null, min_ram_gb: 3, min_vram_gb: ~}
      - {name: onelineA, tag: x, min_ram_gb: 5, min_vram_gb: null}  # comment after
      -   {name: spaced,   tag: y,   min_ram_gb:   6 ,  min_vram_gb: 2}
  - name: second
    models:
      - *first
      - *missing
YEOF
edge="$(ci_os_model_packs_rows "$WORK/edge.yaml")"
t_eq "edge: quotes, multi-line entry, null/~, default tag latest, odd spacing, alias, unknown alias dropped" \
"odd${TAB}quoted-name${TAB}7b${TAB}12${TAB}8
odd${TAB}plain${TAB}latest${TAB}3${TAB}-
odd${TAB}onelineA${TAB}x${TAB}5${TAB}-
odd${TAB}spaced${TAB}y${TAB}6${TAB}2
second${TAB}plain${TAB}latest${TAB}3${TAB}-" "$edge"
printf 'packs:\r\n  - name: crlf\r\n    models:\r\n      - {name: m, tag: t, min_ram_gb: 4, min_vram_gb: null}\r\n' > "$WORK/crlf.yaml"
t_eq "edge: CRLF line endings" "crlf${TAB}m${TAB}t${TAB}4${TAB}-" "$(ci_os_model_packs_rows "$WORK/crlf.yaml")"
: > "$WORK/empty.yaml"
t_eq "edge: an empty file has no rows" "" "$(ci_os_model_packs_rows "$WORK/empty.yaml")"

echo "== requirements lookup"
t_eq "qwen3.6:27b -> 32 24" "32 24" "$(ci_os_model_requirements qwen3.6:27b "$PACKS_FILE")"
t_eq "no tag means :latest" "2 -" "$(ci_os_model_requirements nomic-embed-text "$PACKS_FILE")"
t_eq "gpt-oss:120b -> 80 80" "80 80" "$(ci_os_model_requirements gpt-oss:120b "$PACKS_FILE")"
t_eq "an unknown model prints nothing" "" "$(ci_os_model_requirements nope:1b "$PACKS_FILE")"
t_eq "the tag is part of the key (qwen3:7b is not listed)" "" "$(ci_os_model_requirements qwen3:7b "$PACKS_FILE")"
cat > "$WORK/dup.yaml" <<'YEOF'
packs:
  - name: a
    models:
      - {name: m, tag: t, min_ram_gb: 8, min_vram_gb: null}
  - name: b
    models:
      - {name: m, tag: t, min_ram_gb: 16, min_vram_gb: 12}
YEOF
t_eq "a model listed twice with different needs: the larger numbers win (stricter)" "16 12" "$(ci_os_model_requirements m:t "$WORK/dup.yaml")"

echo "== the pure decision (min_ram, min_vram, ram MiB, vram MiB, unified) - boundaries to the MiB"
decide() { # decide <min_ram> <min_vram> <ram> <vram> <unified> -> rc
  ci_os_model_fit_decide "$@" >/dev/null; echo $?
}
check() { # check "<label>" <expected rc> <args...>
  local label="$1" want="$2"; shift 2
  t_eq "$label" "$want" "$(decide "$@")"
}
check "2 GB model: 1863 MiB fits"                                   0 2 - 1863 0 0
check "2 GB model: 1862 MiB does not (floor is 91 % of 2048)"       1 2 - 1862 0 0
check "32 GB model, no GPU need: 29818 MiB fits"                    0 32 - 29818 0 0
check "32 GB model, no GPU need: 29817 MiB does not"                1 32 - 29817 0 0
check "a 16 GB laptop is not offered a 32 GB model"                 1 32 - 16384 0 0
check "needs a GPU: 64 GB RAM + 23347 MiB VRAM fits (95 % of 24 GB)" 0 32 24 65536 23347 0
check "needs a GPU: 23346 MiB VRAM does not"                        1 32 24 65536 23346 0
check "a real 24 GB card reports 24564 MiB and fits"                0 32 24 65536 24564 0
check "needs a GPU: plenty of RAM but CPU-only does not fit"        1 32 24 262144 0 0
check "RAM short even with a big GPU"                               1 32 24 16384 24564 0
check "unified memory: 30000 MiB + 512 MiB carve-out covers 32 GB"  0 32 24 30000 512 1
check "unified memory: the old rule's floor (30000 MiB) passes"     0 32 24 30000 0 1
check "unified memory: 29000 MiB is too little for 32 GB"           1 32 24 29000 0 1
check "unified 128 GB machine, large carve-out: 31000 + 96000 covers an 80 GB model" 0 80 80 31000 96000 1
check "unified: 31000 + 512 does not cover an 80 GB model"          1 80 80 31000 512 1
check "unified memory: GPU need larger than RAM need is honoured"   1 16 40 20000 0 1
check "RAM unknown (empty) does not fit"                            1 2 - "" 0 0
check "RAM zero does not fit"                                       1 2 - 0 0 0
check "RAM not a number does not fit"                               1 2 - "lots" 0 0
check "VRAM not a number counts as none"                            1 32 24 65536 "x" 0
check "unusable requirement: min_ram_gb not a number -> status 2"   2 "x" - 65536 0 0
check "unusable requirement: min_vram_gb not a number -> status 2"  2 8 "x" 65536 0 0
check "unusable requirement: empty min_ram_gb -> status 2"          2 "" - 65536 0 0
t_eq "CPU_OK relaxes only the VRAM leg" "0 1" "$(CI_OS_FIT_CPU_OK=1 decide 32 24 65536 0 0) $(CI_OS_FIT_CPU_OK=1 decide 32 24 16384 0 0)"

reason="$(ci_os_model_fit_decide 32 24 65536 0 0)"
t_has "the reason names a CPU-only machine" "$reason" "CPU"
reason="$(ci_os_model_fit_decide 32 - 16384 0 0)"
t_has "the reason for too little RAM says what is needed and what is there" "$reason" "needs 32 GB of RAM (29818 MiB); this machine has 16384 MiB"

echo "== nothing the old rule accepted is refused now (Strix Halo + >= 30000 MiB, the 32 GB model)"
bad=0; n=0
for ram in 30000 30001 30500 31000 32000 32768 40000 65536 98304 131072; do
  n=$((n + 1))
  ci_os_model_fit_decide 32 24 "$ram" 512 1 >/dev/null || bad=$((bad + 1))
done
t_eq "all $n RAM sizes >= 30000 MiB pass on a unified-memory machine" 0 "$bad"

echo "== the facts: /proc/meminfo, nvidia-smi, rocm-smi, amdgpu sysfs, lscpu, rocminfo"
printf 'MemTotal:       32749820 kB\nMemFree:         1 kB\n' > "$WORK/meminfo"
t_eq "MemTotal from a meminfo file, in MiB" 31982 "$(CI_OS_PROC_MEMINFO="$WORK/meminfo" ci_os_fit_ram_mib)"
t_eq "an unreadable meminfo prints nothing" "" "$(CI_OS_PROC_MEMINFO="$WORK/none" ci_os_fit_ram_mib)"
t_eq "CI_OS_FIT_RAM_MIB overrides" 123 "$(CI_OS_FIT_RAM_MIB=123 ci_os_fit_ram_mib)"

t_eq "no detector at all: 0 MiB (CPU-only), not an error" 0 "$(CI_OS_SYSFS_DRM="$WORK/nodrm" ci_os_fit_vram_mib)"
mkstub nvidia-smi 'cat "$FAKE/nvidia-smi.out" 2>/dev/null; exit "$(cat "$FAKE/nvidia-smi.rc" 2>/dev/null || echo 0)"'
fake nvidia-smi.out "24564
24564
"
t_eq "nvidia-smi: two GPUs are summed" 49128 "$(CI_OS_SYSFS_DRM="$WORK/nodrm" ci_os_fit_vram_mib)"
fake nvidia-smi.out "garbage
8192
[N/A]
12abc
"
t_eq "nvidia-smi: lines that are not numbers are ignored" 8192 "$(CI_OS_SYSFS_DRM="$WORK/nodrm" ci_os_fit_vram_mib)"
fake nvidia-smi.out ""; fake nvidia-smi.rc 9
t_eq "nvidia-smi present but failing (no driver): 0" 0 "$(CI_OS_SYSFS_DRM="$WORK/nodrm" ci_os_fit_vram_mib)"
rmstub nvidia-smi; unfake nvidia-smi.rc

mkstub rocm-smi 'case "$*" in *--csv*) cat "$FAKE/rocm-smi.csv" 2>/dev/null ;; *) cat "$FAKE/rocm-smi.plain" 2>/dev/null ;; esac; exit 0'
fake rocm-smi.csv "device,VRAM Total Memory (B),VRAM Total Used Memory (B)
card0,17163091968,123456
card1,17163091968,0
"
t_eq "rocm-smi --csv: two cards, bytes -> MiB" 32736 "$(CI_OS_SYSFS_DRM="$WORK/nodrm" ci_os_fit_vram_mib)"
fake rocm-smi.csv ""
fake rocm-smi.plain "GPU[0]		: VRAM Total Memory (B): 25753026560
GPU[0]		: VRAM Total Used Memory (B): 11
"
t_eq "rocm-smi plain output when --csv prints nothing" 24560 "$(CI_OS_SYSFS_DRM="$WORK/nodrm" ci_os_fit_vram_mib)"
rmstub rocm-smi; unfake rocm-smi.csv; unfake rocm-smi.plain

mkdir -p "$WORK/drm/card0/device" "$WORK/drm/card1/device" "$WORK/drm/card2/device"
printf '0x1002\n' > "$WORK/drm/card0/device/vendor"; printf '17163091968\n' > "$WORK/drm/card0/device/mem_info_vram_total"
printf '0x10de\n' > "$WORK/drm/card1/device/vendor"; printf '99999999999\n' > "$WORK/drm/card1/device/mem_info_vram_total"
printf '0x1002\n' > "$WORK/drm/card2/device/vendor"; printf 'nonsense\n' > "$WORK/drm/card2/device/mem_info_vram_total"
t_eq "amdgpu sysfs: only AMD cards, only numbers" 16368 "$(CI_OS_SYSFS_DRM="$WORK/drm" ci_os_fit_vram_mib)"
t_eq "CI_OS_FIT_VRAM_MIB overrides" 77 "$(CI_OS_FIT_VRAM_MIB=77 ci_os_fit_vram_mib)"

fake lscpu.model "AMD RYZEN AI MAX+ 395 w/ Radeon 8060S"
t_eq "unified: Ryzen AI Max (case-insensitive)" 1 "$(ci_os_fit_unified)"
fake lscpu.model "AMD Ryzen AI 9 HX 370 w/ Radeon 890M"
t_eq "not unified: bare Ryzen AI (Strix Point) is not enough" 0 "$(ci_os_fit_unified)"
fake lscpu.model "Intel(R) Core(TM) i7-1260P"
t_eq "not unified: an Intel CPU" 0 "$(ci_os_fit_unified)"
fake lscpu.model "Something with 8060S in it"
t_eq "unified: Radeon 8060S" 1 "$(ci_os_fit_unified)"
fake lscpu.model "Test CPU"
mkstub rocminfo 'echo "  Name:                    gfx1151"'
t_eq "unified: rocminfo shows gfx1151" 1 "$(ci_os_fit_unified)"
# The real rocminfo prints the agent names early and a long property dump after them. Under pipefail (the provisioners set
# it) `rocminfo | grep -q` read that as "not detected": grep stops at the match and rocminfo dies of SIGPIPE on the rest.
mkstub rocminfo 'echo "  Name:                    gfx1151"; i=0; while [ "$i" -lt 4000 ]; do echo "  Property $i:  a line of the dump that follows the agent names"; i=$((i + 1)); done'
t_eq "unified: rocminfo shows gfx1151 before a long dump, under pipefail" 1 "$(set -o pipefail; ci_os_fit_unified)"
rmstub rocminfo
t_eq "CI_OS_FIT_UNIFIED=1 overrides" 1 "$(CI_OS_FIT_UNIFIED=1 ci_os_fit_unified)"
fake lscpu.model 'AMD Ryzen AI Max+ 395'
t_eq "CI_OS_FIT_UNIFIED=0 overrides" 0 "$(CI_OS_FIT_UNIFIED=0 ci_os_fit_unified)"
fake lscpu.model "Test CPU"
if [ "$BASH_MAJOR" -ge 4 ]; then
  same=1
  for cpu in "AMD Ryzen AI Max+ 395" "AMD Ryzen AI 9 HX 370" "Radeon 8060S" "Strix Halo" "Ryzen 9 7950X" "" "ryzen ai max" "RYZEN AI MAX PRO 390"; do
    old=0; is_confidently_strix_halo_cpu_string "$cpu" && old=1
    fake lscpu.model "$cpu"
    new="$(ci_os_fit_unified)"
    [ "$old" = "$new" ] || { same=0; t_info "differs for '$cpu': old rule $old, gate $new"; }
  done
  fake lscpu.model "Test CPU"
  t_eq "ci_os_fit_unified agrees with is_confidently_strix_halo_cpu_string on a list of CPU names" 1 "$same"
else
  t_skip "bash $BASH_MAJOR has no \${var,,}: the parity check against is_confidently_strix_halo_cpu_string runs on bash 4+"
fi

echo "== ci_os_model_fits end to end (facts from the environment)"
fits() { # fits <ram> <vram> <unified> <ref> -> rc
  CI_OS_FIT_RAM_MIB="$1" CI_OS_FIT_VRAM_MIB="$2" CI_OS_FIT_UNIFIED="$3" ci_os_model_fits "$4"; echo $?
}
t_eq "gemma3:1b on a 4 GB machine" 0 "$(fits 4096 0 0 gemma3:1b | tail -1)"
t_eq "qwen3.6:27b on a 16 GB laptop: does not fit" 1 "$(fits 16384 0 0 qwen3.6:27b | tail -1)"
t_eq "qwen3.6:27b on 64 GB + a 24 GB card: fits" 0 "$(fits 65536 24564 0 qwen3.6:27b | tail -1)"
t_eq "qwen3.6:27b on a 32 GB Strix Halo: fits" 0 "$(fits 30500 512 1 qwen3.6:27b | tail -1)"
t_eq "llama3.3:70b on a 32 GB Strix Halo: does not fit" 1 "$(fits 30500 512 1 llama3.3:70b | tail -1)"
t_eq "a bare name means :latest" 0 "$(fits 4096 0 0 nomic-embed-text | tail -1)"
t_eq "an unknown model: no data, status 2" 2 "$(fits 99999 99999 0 nope:1 | tail -1)"
for bad in "" "-rf" "a b" 'x$(touch PWNED)' "../x" ";id" "a|b" 'a`b'; do
  t_eq "a malformed reference is status 2, never evaluated: '$bad'" 2 "$(fits 99999 99999 0 "$bad" | tail -1)"
  t_has "...and the reason says it is not a model reference: '$bad'" "$(CI_OS_FIT_RAM_MIB=1 ci_os_model_fits "$bad"; printf '%s' "$CI_OS_MODEL_FIT_REASON")" "not a model reference"
done
t_eq "nothing was executed by a malformed reference" "no" "$([ -e PWNED ] && echo yes || echo no)"
(
  CI_OS_MODEL_PACKS_FILE="$WORK/none.yaml"; export CI_OS_MODEL_PACKS_FILE
  CI_OS_GPU_DETECT_DIR="$WORK/nowhere"
  ci_os_model_fits gemma3:1b; echo "rc=$? reason=$CI_OS_MODEL_FIT_REASON"
) > "$WORK/nofile.out" 2>&1
t_has "a missing model-packs.yaml is status 2 with a reason" "$(cat "$WORK/nofile.out")" "rc=2 reason=model-packs.yaml not found"
t_eq "CI_OS_MODEL_FIT_OVERRIDE=allow" 0 "$(CI_OS_MODEL_FIT_OVERRIDE=allow fits 1 0 0 llama3.3:70b | tail -1)"
t_eq "CI_OS_MODEL_FIT_OVERRIDE=deny" 1 "$(CI_OS_MODEL_FIT_OVERRIDE=deny fits 99999 99999 0 gemma3:1b | tail -1)"

echo "== ci_os_model_gate_allows (what the provisioners call)"
gate() { CI_OS_FIT_RAM_MIB="$1" CI_OS_FIT_VRAM_MIB="$2" CI_OS_FIT_UNIFIED="$3" ci_os_model_gate_allows "$4"; echo "$?:$CI_OS_MODEL_FIT_REASON"; }
t_has "fits -> go ahead" "$(gate 65536 24564 0 qwen3.6:27b)" "0:fits"
t_has "does not fit -> skip, with the reason" "$(gate 16384 0 0 qwen3.6:27b)" "1:needs 32 GB of RAM"
t_has "no fit data -> go ahead, and say so" "$(gate 16384 0 0 nope:1)" "0:no fit data (nope:1 is not listed in model-packs.yaml); not blocking"

echo "== the provisioners: their real pull_ollama_models functions against stubs"
# Extract the function text, point it at a temporary copy of the repo's core/ (so gpu-detect.sh and
# model-packs.yaml are the real ones, with /proc/meminfo redirected to a fixture), and run it with sudo, ollama
# and the helpers stubbed. The heredoc inside is the part that decides whether qwen3.6:27b is pulled.
FAKE_REPO="$WORK/repo"
mkdir -p "$FAKE_REPO/core/lib" "$FAKE_REPO/core/manifest"
sed "s|/proc/meminfo|$WORK/meminfo-prov|g" "$GPU_SH" > "$FAKE_REPO/core/lib/gpu-detect.sh"
cp "$PACKS_FILE" "$FAKE_REPO/core/manifest/model-packs.yaml"
mkstub ollama 'case "$1" in list) exit 0 ;; pull) exit 0 ;; esac; exit 0'
prov_run() { # prov_run <ubuntu|arch> <ram MiB> <vram MiB> <cpu model> -> prints the models ollama was asked to pull
  local which="$1" ram="$2" vram="$3" cpu="$4" script fn
  printf 'MemTotal:       %s kB\n' "$((ram * 1024))" > "$WORK/meminfo-prov"
  fake lscpu.model "$cpu"
  clear_logs
  script="$REPO_ROOT/backends/$which/provision/provision.sh"
  fn="$WORK/fn-$which.sh"
  awk '/^pull_ollama_models\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$script" > "$fn"
  [ -s "$fn" ] || { echo "no pull_ollama_models in $script"; return 1; }
  if [ "$which" = ubuntu ]; then
    # the function finds core/lib/gpu-detect.sh relative to the script; make it find the fixture tree instead
    needle='$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)'
    text="$(cat "$fn")"
    text="${text//"$needle"/$FAKE_REPO}"
    printf '%s\n' "$text" > "$fn"
    grep -q "$FAKE_REPO" "$fn" || { echo "could not redirect the repo root in the ubuntu function"; return 1; }
  fi
  (
    set -euo pipefail
    REPO_ROOT="$FAKE_REPO"; ACTUAL_USER=tester
    log_info() { :; }; log_warning() { :; }; log_success() { :; }
    command_exists() { command -v "$1" >/dev/null 2>&1; }
    ollama_systemd_unit_exists() { return 1; }
    pgrep() { return 0; }
    sudo() { shift 2; "$@"; }
    sleep() { :; }
    # shellcheck disable=SC1090
    . "$fn"
    pull_ollama_models >/dev/null 2>&1
  ) || { echo "function failed"; return 1; }
  grep -h '^pull ' "$FAKE/ollama.log" 2>/dev/null | sed 's/^pull //' | tr '\n' ' '
}
t_eq "arch: a 16 GB laptop pulls the small models and NOT qwen3.6:27b" "nomic-embed-text gemma3:1b " "$(prov_run arch 16384 0 'Intel(R) Core(TM) i5')"
t_eq "arch: 64 GB with a 24 GB card pulls qwen3.6:27b too" "nomic-embed-text gemma3:1b qwen3.6:27b " "$(CI_OS_FIT_VRAM_MIB=24564 prov_run arch 65536 24564 'Intel(R) Core(TM) i9')"
t_eq "arch: a 32 GB Strix Halo pulls qwen3.6:27b" "nomic-embed-text gemma3:1b qwen3.6:27b " "$(prov_run arch 30500 0 'AMD RYZEN AI MAX+ 395 w/ Radeon 8060S')"
t_eq "ubuntu: a 16 GB laptop does NOT pull qwen3.6:27b (class gate, as before)" "nomic-embed-text gemma3:1b " "$(prov_run ubuntu 16384 0 'Intel(R) Core(TM) i5')"
t_eq "ubuntu: a 64 GB workstation with a big card is still not Strix Halo: no qwen3.6:27b (class gate stays)" "nomic-embed-text gemma3:1b " "$(CI_OS_FIT_VRAM_MIB=24564 prov_run ubuntu 65536 24564 'Intel(R) Core(TM) i9')"
if [ "$BASH_MAJOR" -ge 4 ]; then
  # the Strix Halo class rule (gpu-detect.sh, unchanged) lower-cases with ${var,,}, which is bash 4+; the images have bash 5
  t_eq "ubuntu: a 32 GB Strix Halo pulls qwen3.6:27b" "nomic-embed-text gemma3:1b qwen3.6:27b " "$(prov_run ubuntu 30500 0 'AMD RYZEN AI MAX+ 395 w/ Radeon 8060S')"
else
  t_skip "ubuntu: Strix Halo cases need the old class rule, which needs bash 4+ (this is bash $BASH_MAJOR)"
fi
# The new gate applies on top of the class gate: a Strix Halo class machine whose memory is too small for the model.
t_eq "ubuntu: Strix Halo-class CPU but only 20 GB of RAM: the old rule already refuses (30000 floor)" "nomic-embed-text gemma3:1b " "$(prov_run ubuntu 20000 0 'AMD RYZEN AI MAX+ 395 w/ Radeon 8060S')"
rm -f "$FAKE_REPO/core/manifest/model-packs.yaml"
t_eq "arch: without model-packs.yaml (no fit data) the old behaviour stays: qwen3.6:27b is pulled" "nomic-embed-text gemma3:1b qwen3.6:27b " "$(CI_OS_MODEL_PACKS_FILE="$WORK/none.yaml" prov_run arch 16384 0 'Intel(R) Core(TM) i5')"
if [ "$BASH_MAJOR" -ge 4 ]; then
  t_eq "ubuntu: without model-packs.yaml the class gate alone decides: Strix Halo pulls" "nomic-embed-text gemma3:1b qwen3.6:27b " "$(CI_OS_MODEL_PACKS_FILE="$WORK/none.yaml" prov_run ubuntu 30500 0 'AMD RYZEN AI MAX+ 395 w/ Radeon 8060S')"
fi

t_summary "models-gate"
