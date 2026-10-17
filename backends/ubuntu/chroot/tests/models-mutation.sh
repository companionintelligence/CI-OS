#!/usr/bin/env bash
#=============================================================================
# Test: mutation proofs for the hardware-fit gate, the Hugging Face view builder, the ci-os-models rules and the models
# env script - the tests must FAIL when the code is wrong
#
# A test suite that has never been seen to fail proves little. This script copies core/lib/gpu-detect.sh,
# core/lib/ci-os-models.sh, core/manifest/model-packs.yaml and ci-os-ollama-models-env.sh to a temporary tree, breaks
# one rule at a time with a literal text replacement, and runs the test file that is meant to guard that rule against the
# broken copy (CI_MODELS_TEST_LIBDIR / CI_MODELS_TEST_ENV_SCRIPT point the tests at it). Every mutant must make that
# test exit 1. It also runs each guarding test once against an UNBROKEN copy (the control: it must pass) and checks that
# every replacement really changed the file (a mutation that matches nothing proves nothing).
#
#   bash backends/ubuntu/chroot/tests/models-mutation.sh [name-filter]      (bash 3.2 or 5)
#
# The mutants that are probabilistic by nature (a race between parallel builders) are not included.
# Exit status: non-zero if a mutant survives or the control fails; 2 if it cannot run here.
#
# (c) Companion Intelligence - Lifescope Inc
#=============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
FILTER="${1:-}"
NL='
'

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

SRC_GPU="$REPO_ROOT/core/lib/gpu-detect.sh"
SRC_MODELS="$REPO_ROOT/core/lib/ci-os-models.sh"
SRC_PACKS="$REPO_ROOT/core/manifest/model-packs.yaml"
SRC_ENV="$REPO_ROOT/backends/ubuntu/chroot/payload/ci-os-ollama-models-env.sh"
for f in "$SRC_GPU" "$SRC_MODELS" "$SRC_PACKS" "$SRC_ENV"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 2; }
done

# replace_in <file> <old> <new>: literal, first occurrence only; fails if <old> is not there. awk (ENVIRON keeps backslashes
# as they are, index() is a literal search) with LC_ALL=C: bash 3.2's ${text/pattern/new} is quadratic on a 50 KB text in a
# UTF-8 locale and took minutes per mutant on a busy machine.
replace_in() {
  local file="$1"
  OLD_TEXT="$2" NEW_TEXT="$3" LC_ALL=C awk 'BEGIN { RS = "\001"; old = ENVIRON["OLD_TEXT"]; new = ENVIRON["NEW_TEXT"] }
    { i = index($0, old); if (i == 0) { missing = 1; exit 1 } ; printf "%s%s%s", substr($0, 1, i - 1), new, substr($0, i + length(old)) }
    END { if (missing) exit 1 }' "$file" > "$file.new" || { rm -f "$file.new"; return 1; }
  mv -f "$file.new" "$file"
}
readf() { local t; t="$(cat "$1"; printf x)"; printf '%s' "${t%x}"; }

# ---- the worker: one mutant (or one control run) in its own copy of the tree, result in $dir/r<n> -------------------
worker_main() { # worker_main <dir> <n>
  local dir="$1" n="$2" w="$1/w$2" name test which old new file orig rc=0 first
  name="$(readf "$dir/m$n.name")"; test="$(readf "$dir/m$n.test")"; which="$(readf "$dir/m$n.which")"
  mkdir -p "$w/core/lib" "$w/core/manifest"
  cp "$SRC_GPU" "$SRC_MODELS" "$w/core/lib/"; cp "$SRC_PACKS" "$w/core/manifest/"; cp "$SRC_ENV" "$w/env.sh"
  if [ "$which" != control ]; then
    old="$(readf "$dir/m$n.old")"; new="$(readf "$dir/m$n.new")"
    case "$which" in gpu) file="$w/core/lib/gpu-detect.sh"; orig="$SRC_GPU" ;; models) file="$w/core/lib/ci-os-models.sh"; orig="$SRC_MODELS" ;; env) file="$w/env.sh"; orig="$SRC_ENV" ;; esac
    if ! replace_in "$file" "$old" "$new"; then printf 'badtext' > "$dir/r$n"; rm -rf "$w"; return 0; fi
    if cmp -s "$file" "$orig"; then printf 'nochange' > "$dir/r$n"; rm -rf "$w"; return 0; fi
  fi
  CI_MODELS_TEST_LIBDIR="$w/core/lib" CI_MODELS_TEST_ENV_SCRIPT="$w/env.sh" CI_MODELS_TEST_FAILFAST=1 \
    bash "$HERE/models-$test.sh" > "$dir/o$n" 2>&1 || rc=$?
  first="$(grep -E '^FAIL' "$dir/o$n" | head -n 1 | cut -c1-110)"
  printf 'rc=%s\n%s\n' "$rc" "$first" > "$dir/r$n"
  rm -rf "$w"
}
if [ "${1:-}" = --worker ]; then worker_main "$2" "$3"; exit 0; fi

M="$(mktemp -d "${TMPDIR:-/tmp}/ci-models-mutation.XXXXXX")"
trap 'rm -rf "$M"' EXIT
COUNT=0
# add <name> <test> <which: gpu|models|env|control> [<old> <new>]
add() {
  COUNT=$((COUNT + 1))
  printf '%s' "$1" > "$M/m$COUNT.name"; printf '%s' "$2" > "$M/m$COUNT.test"; printf '%s' "$3" > "$M/m$COUNT.which"
  printf '%s' "${4:-}" > "$M/m$COUNT.old"; printf '%s' "${5:-}" > "$M/m$COUNT.new"
}
mutant() { case "$1" in *"$FILTER"*) add "$@" ;; esac; }

if [ "${CI_MODELS_MUTATION_NOCONTROL:-0}" != 1 ]; then
  for t in gate view lib env; do add "control: models-$t.sh on an unbroken copy" "$t" control; done
fi

echo "== the hardware-fit gate (core/lib/gpu-detect.sh) - guarded by models-gate.sh"
mutant "gate: RAM floor 91 % -> 100 %"              gate gpu 'CI_OS_MODEL_RAM_PCT=91'  'CI_OS_MODEL_RAM_PCT=100'
mutant "gate: RAM floor 91 % -> 50 %"               gate gpu 'CI_OS_MODEL_RAM_PCT=91'  'CI_OS_MODEL_RAM_PCT=50'
mutant "gate: VRAM floor 95 % -> 100 %"             gate gpu 'CI_OS_MODEL_VRAM_PCT=95' 'CI_OS_MODEL_VRAM_PCT=100'
mutant "gate: VRAM floor 95 % -> 10 %"              gate gpu 'CI_OS_MODEL_VRAM_PCT=95' 'CI_OS_MODEL_VRAM_PCT=10'
mutant "gate: the VRAM comparison always passes"    gate gpu 'if (( vram >= vram_floor )); then' 'if (( 1 )); then'
mutant "gate: the RAM comparison never fails"       gate gpu 'if (( ram < ram_floor )); then' 'if (( 0 )); then'
mutant "gate: CPU-only allowed by default"          gate gpu '[[ "${CI_OS_FIT_CPU_OK:-0}" == 1 ]]' '[[ "${CI_OS_FIT_CPU_OK:-1}" == 1 ]]'
mutant "gate: every machine is unified memory"      gate gpu '    *) echo 0 ;;' '    *) echo 1 ;;'
mutant "gate: the BIOS carve-out is not added to unified memory" gate gpu 'pool=$(( ram + vram ))' 'pool="$ram"'
mutant "gate: unified memory ignores the GPU need"  gate gpu 'if [[ "$min_vram" != "-" ]] && (( min_vram > need )); then need="$min_vram"; fi' ':'
mutant "gate: an unknown model is allowed"          gate gpu "is not listed in model-packs.yaml\"${NL}    return 2" "is not listed in model-packs.yaml\"${NL}    return 0"
mutant "gate: a missing model-packs.yaml is allowed" gate gpu "CI_OS_MODEL_FIT_REASON=\"model-packs.yaml not found\"${NL}    return 2" "CI_OS_MODEL_FIT_REASON=\"model-packs.yaml not found\"${NL}    return 0"
mutant "gate: no fit data blocks the provisioner"   gate gpu 'not blocking"; return 0 ;;' 'not blocking"; return 1 ;;'
mutant "gate: a malformed reference is accepted"    gate gpu 'if [[ -z "$ref" || ! "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]]; then' 'if [[ -z "$ref" ]]; then'
mutant "gate: the override cannot deny"             gate gpu 'deny)  CI_OS_MODEL_FIT_REASON="refused by CI_OS_MODEL_FIT_OVERRIDE"; return 1 ;;' 'deny)  CI_OS_MODEL_FIT_REASON="refused by CI_OS_MODEL_FIT_OVERRIDE"; return 0 ;;'
mutant "gate: unusable requirements are not detected" gate gpu 'if [[ ! "$min_ram" =~ ^[0-9]+$ ]] ||' 'if false ||'
mutant "reader: alias lines are not resolved"       gate gpu 'if (a in anchors)' 'if (0)'
mutant "reader: a null min_vram_gb is not '-'"      gate gpu 'if (v == "" || v == "null" || v == "~") v = "-"' 'if (v == "") v = "-"'
mutant "reader: the default tag is not 'latest'"    gate gpu 'if (t == "") t = "latest"' 'if (t == "") t = ""'
mutant "reader: the larger of two needs does not win" gate gpu 'if ($4 + 0 > ram + 0) ram = $4' 'if ($4 + 0 < ram + 0) ram = $4'
mutant "detector: rocm-smi plain output is lost"    gate gpu 'NR == 1 && index($0, ",") > 0 &&' 'NR == 1 &&'
mutant "detector: non-AMD cards counted from sysfs" gate gpu '[[ "$(cat "${f%/mem_info_vram_total}/vendor" 2>/dev/null)" == 0x1002 ]] || continue' ':'
mutant "detector: nvidia-smi garbage lines counted" gate gpu "'\$1 ~ /^[0-9]+\$/ { s += \$1 }" "'{ s += \$1 }"

echo "== the view builder and lock reader (core/lib/ci-os-models.sh) - guarded by models-view.sh"
mutant "view: '..' components are allowed"          view models "case \"\$c\" in ''|.|..) return 1 ;; esac" "case \"\$c\" in '') return 1 ;; esac"
mutant "view: control characters are allowed"       view models '*[[:cntrl:]]*) return 1 ;;' '*NEVER_MATCHES_ANYTHING*) return 1 ;;'
mutant "view: backslashes are allowed"              view models '/*|*\\*) return 1 ;;' '/*) return 1 ;;'
# (no mutant for the "/*" rule alone: an absolute name also fails the empty-first-component rule, so removing one of the two changes nothing)
mutant "view: no length limit on names"             view models '[ -n "$p" ] && [ "${#p}" -le 1024 ] || return 1' '[ -n "$p" ] || return 1'
mutant "view: a double dash in a repository is allowed" view models '[[ "$1" != *--* ]]; }' 'true; }'
mutant "view: a short revision is accepted"         view models '[[ "$1" =~ ^[0-9a-f]{40}$ ]]' '[[ "$1" =~ ^[0-9a-f]+$ ]]'
mutant "view: an uppercase digest is accepted"      view models '[[ "$1" =~ ^[0-9a-f]{64}$ ]]' '[[ "$1" =~ ^[0-9A-Fa-f]{64}$ ]]'
mutant "view: a link to somewhere else is replaced" view models "          \"\$store\"/*|\"\$xdir\"/*)
            rm -f" "          *)
            rm -f"
mutant "view: prune removes links that are not ours" view models "        \"\$store\"/*|\"\$xdir\"/*) ;;
        *) continue ;;" "        \"\$store\"/*|\"\$xdir\"/*) ;;
        *) ;;"
mutant "view: an unchanged link is rewritten every run" view models 'if [ "$cur" = "$blob" ]; then' 'if false; then'
mutant "view: ln is handed a symlink to a directory"   view models '    if [ -L "$link" ]; then
      cur="$(readlink "$link")"
      if [ "$cur" = "$blob" ]; then
        n_keep' '    if false; then
      cur="$(readlink "$link")"
      if [ "$cur" = "$blob" ]; then
        n_keep'
mutant "view: a real directory at the link position is linked into" view models 'elif [ -e "$link" ] && [ ! -L "$link" ]; then' 'elif false; then'
mutant "view: a symlinked directory in the path is followed" view models '    if [ -L "$cur" ]; then return 1; fi
    mkdir -- "$cur" 2>/dev/null || true
    if [ -L "$cur" ] || [ ! -d "$cur" ]; then return 1; fi' '    mkdir -- "$cur" 2>/dev/null || true
    if [ ! -d "$cur" ]; then return 1; fi'
mutant "view: a blob that is a symlink is linked"   view models 'if [ -L "$blob" ]; then' 'if false; then'
mutant "view: a symlinked hub is used"              view models 'if [ -L "$view" ] || [ -L "$hub" ]; then' 'if false; then'
mutant "view: refs/main may be a symlink"           view models 'if [ -L "$mdir/refs/main" ] || { [ -e "$mdir/refs/main" ] && [ ! -f "$mdir/refs/main" ]; }; then' 'if false; then'
mutant "view: refs/main is not updated"             view models 'if [ "$(cat "$mdir/refs/main" 2>/dev/null)" != "$rev" ]; then' 'if [ -e "$mdir/refs/main" ]; then : ; elif true; then'
mutant "view: emptied repositories are left behind" view models 'if [ -f "$mdir/refs/main" ] && [ ! -L "$mdir/refs/main" ]; then rm -f -- "$mdir/refs/main"; fi' ':'
mutant "view: a missing blob is linked anyway"      view models 'if [ ! -f "$blob" ]; then' 'if false; then'
mutant "view: the second store is not searched"     view models 'if [ ! -e "$blob" ] && [ -n "$xdir" ]; then' 'if false; then'
mutant "view: pruning is always on"                 view models 'if [ "$prune" = 1 ]; then' 'if true; then'
mutant "reader: '..' accepted in the lock"          view models 'if (comp == "" || comp == "." || comp == "..") return 0' 'if (comp == "") return 0'
mutant "reader: control characters accepted in the lock" view models 'if (ch < " " || ch == "\177") return 1' 'if (0) return 1'
mutant "reader: a \\n escape is decoded as text"    view models 'else out = out "\001"
  }
  if (length(out) > 2048)' 'else out = out "n"
  }
  if (length(out) > 2048)'
mutant "view: the lock on the volume beats the image's" view models 'locks="$(ci_models_default_lock)" || locks=""
      if [ -z "$locks" ]; then' 'locks=""
      if true; then'
mutant "view: an empty second store matches every link"  view models '[ -n "$xdir" ] || xdir="$store/.no-second-store"' ':'
mutant "view: --strict ignores refusals"            view models 'if [ "$strict" = 1 ] && [ "$CI_MODELS_VIEW_REFUSED" -gt 0 ]; then return 1; fi' ':'

echo "== the adapter's rules (core/lib/ci-os-models.sh) - guarded by models-lib.sh"
mutant "lib: Hugging Face references may fall back to ollama pull" lib models 'if [ "$kind" = hf ]; then
    if [ -z "$bin" ]; then' 'if false; then
    if [ -z "$bin" ]; then'
mutant "lib: a failing ci-stick is answered with ollama pull" lib models 'if [ -n "$bin" ] && ci_models_ollama_reads_store; then' 'if false; then'
mutant "lib: ci-stick is used for a store Ollama does not read" lib models 'if [ -n "$bin" ] && ci_models_ollama_reads_store; then' 'if [ -n "$bin" ]; then'
mutant "lib: option-looking references pass"        lib models '|| [[ "$ref" == *..* ]]' ''
mutant "lib: references may start with a dash"      lib models 'if [[ ! "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]]' 'if [[ ! "$ref" =~ ^[-A-Za-z0-9][A-Za-z0-9._/:-]*$ ]]'
mutant "lib: the hardware gate is switched off"     lib models '[ "$CI_MODELS_O_NOGATE" != 1 ] || { CI_MODEL_GATE_REASON="gate disabled"; return 0; }' '{ CI_MODEL_GATE_REASON="gate disabled"; return 0; }'
mutant "lib: unknown models are downloaded blind"   lib models 'if [ "$CI_MODELS_O_UNKNOWN" != 1 ]; then' 'if false; then'
mutant "lib: nothing-fits is not reported (status 11)" lib models 'if [ "$unfit_n" -gt 0 ]; then return "$CI_MODELS_RC_UNFIT"; fi' ':'
mutant "lib: ensure goes on after a bad digest"     lib models 'case "$rc" in 4|6|7) break ;; esac     # a full disk' 'case "$rc" in 4|6) break ;; esac     # a full disk'
mutant "lib: integrity failures are not explained"  lib models '7) msg="integrity check failed' '7) msg="check failed'
mutant "lib: licence refusals are not explained"    lib models '5) msg="licence acceptance required for at least one model' '5) msg="refused for at least one model'
mutant "lib: --accept-licenses always passed"       lib models '[ "$CI_MODELS_O_ACCEPT" != 1 ] || args+=(--accept-licenses)' 'args+=(--accept-licenses)'
mutant "lib: the bandwidth flag is used without asking ci-stick" lib models 'flag="$(ci_models_rate_flag)" || flag=""' 'flag="--max-bytes-per-sec"'
mutant "lib: '/s' is passed to ci-stick"            lib models 'args+=("$flag" "${rate%/s}")' 'args+=("$flag" "$rate")'
mutant "lib: any text is a rate"                    lib models '[[ "$1" =~ ^[0-9]+(\.[0-9]+)?(B|[KkMmGgTt][Bb]|[KkMmGgTt][Ii][Bb])?(/s)?$ ]]' '[[ -n "$1" ]]'
mutant "lib: the default lock is not handed on"     lib models '[ -n "$lock" ] || lock="$(ci_models_default_lock)" || lock=""
  [ -z "$lock" ] || args+=(--lock "$lock")
  [ -z "$CI_MODELS_O_EVENTS" ]' '[ -z "$CI_MODELS_O_EVENTS" ]'
mutant "lib: an unwritable cache is not detected"   lib models 'if [ -d "$CI_MODELS_ROOT" ] && [ ! -w "$CI_MODELS_ROOT" ]; then' 'if false; then'
mutant "lib: OLLAMA_NOPRUNE is not exported"        lib models "        printf 'OLLAMA_NOPRUNE=1\\n'" '        :'
mutant "lib: --user still exports OLLAMA_MODELS"    lib models '      if [ "$user" = 0 ]; then' '      if true; then'
mutant "lib: HF_HOME is exported by default"        lib models '"${CI_OS_MODELS_SET_HF_HOME:-$(ci_models_conf_get set_hf_home 0)}" = 1' '"${CI_OS_MODELS_SET_HF_HOME:-$(ci_models_conf_get set_hf_home 1)}" = 1'
mutant "lib: CI_OS_OFFLINE is ignored"              lib models '[ "${CI_OS_OFFLINE:-0}" = 1 ] && return 0' ':'
mutant "lib: a login shell gets the automatic offline"   lib models '  if { [ "$user" = 1 ] && ci_models_is_offline forced; } || { [ "$user" = 0 ] && ci_models_is_offline; }; then' '  if ci_models_is_offline; then'
mutant "lib: offline=0 does not mean never"        lib models '    1) return 0 ;;
    0) return 1 ;;' '    1) return 0 ;;'
mutant "lib: a newline inside a name is accepted by fetch" lib models 'if ci_models_has_newline "${2:-}"; then ci_models_log "fetch: a name with a newline in it is not accepted"; return 2; fi' ':'
mutant "lib: a newline inside a name is accepted by ensure" lib models 'if ci_models_has_newline "$1"; then ci_models_log "ensure: a name with a newline in it is not accepted"; return 2; fi' ':'
mutant "lib: the cache fallback needs a store to export" lib models '      [ -d "$CI_MODELS_STORE" ] || return 0' '      :'
mutant "lib: an explicit cache does not win"        lib models 'if [ -n "${CI_OS_MODELS_CACHE:-}" ]; then' 'if false; then'
mutant "lib: models.conf quotes are kept"           lib models 'v = substr(v, 2, length(v) - 2)' 'v = v'
mutant "lib: systemd values with quotes are written" lib models '*\"*|*\\*|*$'"'"'\n'"'"'*) ci_models_log' '*NEVER*) ci_models_log'
mutant "prefetch: no flag file needed"              lib models '[ -e "$flag" ] || ci_models_skip' 'true || ci_models_skip'
mutant "prefetch: a live session without persistence runs" lib models 'ci_models_persistence_in_use || ci_models_skip' 'true || ci_models_skip'
mutant "prefetch: no pack needed"                   lib models '[[ "$pack" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || ci_models_skip "no pack named' 'true || ci_models_skip "no pack named'
mutant "prefetch: runs without ci-stick"            lib models 'ci_models_stick_bin >/dev/null || ci_models_skip "ci-stick is not installed"' 'true || ci_models_skip "ci-stick is not installed"'
mutant "prefetch: a cache that is not a stick runs" lib models '    *) ci_models_skip "no cache volume is mounted' '    *) true || ci_models_skip "no cache volume is mounted'
mutant "prefetch: a RAM-backed cache runs"          lib models "''|tmpfs|ramfs|overlay|overlayfs|aufs|squashfs|iso9660|fuse.overlayfs)" "''|ramfs|overlay|overlayfs|aufs|squashfs|iso9660|fuse.overlayfs)"
mutant "prefetch: an unknown filesystem runs"       lib models "''|tmpfs|ramfs|overlay" "tmpfs|ramfs|overlay"
mutant "prefetch: an unwritable cache runs"         lib models '[ -d "$CI_MODELS_ROOT" ] && [ -w "$CI_MODELS_ROOT" ] || ci_models_skip' 'true || ci_models_skip'
mutant "prefetch: any limit_rate text is accepted"  lib models 'ci_models_rate_valid "$rate" || ci_models_skip "limit_rate' 'true || ci_models_skip "limit_rate'
mutant "prefetch: runs unthrottled"                 lib models 'if [ "$rate" != 0 ] && ! ci_models_rate_flag >/dev/null; then' 'if false; then'
mutant "prefetch: a metered link is used"           lib models "    *) ci_models_skip \"network state is '\$state'" "    *) true || ci_models_skip \"network state is '\$state'"
mutant "prefetch: an unknown metered state is used" lib models '[ "$assume" = 1 ] || ci_models_skip "the network' 'true || ci_models_skip "the network'
mutant "prefetch: an access point does not stop it" lib models 'if ci_models_ap_active; then echo ap; return 0; fi' ':'
mutant "prefetch: a guessed 'yes' is not metered"   lib models '    yes*) echo yes ;;' '    yes) echo yes ;;'
mutant "prefetch: offline does not stop it"         lib models 'if ! ci_models_default_route_dev >/dev/null; then echo offline; return 0; fi' ':'
mutant "prefetch: licences accepted by default"     lib models 'CI_MODELS_O_ACCEPT="$(ci_models_conf_get accept_licenses 0)"' 'CI_MODELS_O_ACCEPT=1'
mutant "prefetch: drift is a failure of the unit"   lib models '    3|4|5) ci_models_log "prefetch: stopped' '    4|5) ci_models_log "prefetch: stopped'
mutant "persistence: nopersistent is ignored"       lib models 'case "$cmd" in *" nopersistent "*) return 1 ;; esac' ':'
mutant "persistence: ext4 is not required"          lib models '[ "$(blkid -o value -s TYPE "$dev" 2>/dev/null)" = ext4 ] || return 1' ':'
mutant "persistence: casper does not have to have mounted it" lib models '[ -d "${CI_OS_SYS_EXT4:-/sys/fs/ext4}/$(basename "$dev")" ] && return 0' 'return 0'

echo "== the models env script (ci-os-ollama-models-env.sh) - guarded by models-env.sh"
mutant "env: a bad umask is passed to mount"        env env 'umask_opt=0077 ;; esac' ': ;; esac'
mutant "env: the default umask is no longer 0077"   env env 'umask_opt="${CI_OS_CACHE_UMASK:-0077}"' 'umask_opt="${CI_OS_CACHE_UMASK:-0022}"'
mutant "env: a helper that disagrees is believed"   env env '        *) env_text="" ;;' '        *) : ;;'
mutant "env: junk lines from the helper are written" env env "grep -E '^[A-Z][A-Z0-9_]*=[^[:cntrl:]]*\$'" "cat"
mutant "env: the helper is not told which cache was chosen" env env 'env_text="$(CI_OS_MODELS_CACHE="$target" "$MODELS_BIN" env' 'env_text="$("$MODELS_BIN" env'
mutant "env: the OLLAMA_MODELS agreement check is removed" env env '*"
OLLAMA_MODELS=$dir
"*) ;;' '*) ;;'
mutant "env: the view is never built"               env env 'timeout 20 "$MODELS_BIN" view --quiet >/dev/null 2>&1 || log "could not build the Hugging Face view (not fatal)"' 'true'
mutant "env: a non-numeric gid is used"             env env "case \"\$gid_opt\" in ''|*[!0-9]*) log" "case \"\$gid_opt\" in ''|NEVER) log"
mutant "env: the opt-out file is ignored"           env env '[ ! -e "$ETC_DIR/ollama-no-cache" ] ||' 'true ||'
mutant "env: the exFAT check is removed"            env env '[ "$(blkid -o value -s TYPE "$dev" 2>/dev/null)" = "exfat" ] ||' 'true ||'
mutant "env: release unmounts what it did not mount" env env 'if [ -f "$STAMP" ]; then' 'if true; then'

JOBS="${CI_MODELS_MUTATION_JOBS:-4}"
echo "== running $COUNT copies, $JOBS at a time (each stops at its first failed check)"
i=1; list=""
while [ "$i" -le "$COUNT" ]; do list="$list $i"; i=$((i + 1)); done
# shellcheck disable=SC2086
printf '%s\n' $list | xargs -n 1 -P "$JOBS" sh -c 'nice bash "$0" --worker "$1" "$2"' "$HERE/models-mutation.sh" "$M" 

survivors=0
i=1
while [ "$i" -le "$COUNT" ]; do
  name="$(readf "$M/m$i.name")"; test="$(readf "$M/m$i.test")"; which="$(readf "$M/m$i.which")"
  res="$(readf "$M/r$i")"; rc="$(printf '%s' "$res" | sed -n 's/^rc=//p' | head -n 1)"; first="$(printf '%s' "$res" | sed -n 2p)"
  if [ "$which" = control ]; then
    if [ "$rc" = 0 ]; then t_pass "$name passes"; else t_fail "$name exits ${rc:-?}: $first"; fi
  else
    case "$res" in
      badtext) t_fail "mutant '$name': the text to replace is not in $which (it proves nothing; update this list)" ;;
      nochange) t_fail "mutant '$name': the replacement changed nothing" ;;
      *)
        if [ "$rc" = 1 ]; then t_pass "killed: $name  [models-$test.sh: ${first:-failed}]"
        elif [ "$rc" = 0 ]; then t_fail "SURVIVED: $name (models-$test.sh still passes)"; survivors=$((survivors + 1))
        else t_fail "mutant '$name': models-$test.sh exited ${rc:-?} (neither pass nor fail)"; fi
        ;;
    esac
  fi
  i=$((i + 1))
done
printf '== models-mutation: %s checks passed, %s failed, %s mutants survived\n' "$PASS" "$FAIL" "$survivors"
[ "$FAIL" -eq 0 ]
