#!/usr/bin/env bash
#=============================================================================
# Test: core/lib/ci-os-models.sh (the OS-side model adapter) - cache resolution, environment, ci-stick exit codes,
# the fallbacks, the hardware gate in `ensure`, the opt-in background prefetch
#
# Every external tool is a stub in a PATH directory (ollama, ci-stick, nmcli, findmnt, blkid, systemctl, lscpu...) that
# logs its arguments and takes its behaviour from files, so each rule is checked by what the code did:
#   * the cache is found in the order override > CI-CACHE mount > fallback, and the environment follows from it;
#   * every ci-stick exit code (0..7) comes back unchanged with a message that says what to do, and a failing
#     ci-stick is never answered with `ollama pull`;
#   * without ci-stick an Ollama reference is pulled with `ollama pull`, a Hugging Face reference NEVER is;
#   * `ensure` skips what the machine cannot run (and says so with status 11 when nothing was left to do);
#   * the prefetch condition lets a run through only when every one of its conditions holds, one at a time.
# models-mutation.sh breaks the code on purpose to prove these checks can fail.
#
#   bash backends/ubuntu/chroot/tests/models-lib.sh        (bash 3.2 or 5; awk: BSD, mawk or gawk)
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

CASE=0
newcase() { # fresh T, stubs, a fallback root, and a pack catalog with known needs
  CASE=$((CASE + 1))
  T="$WORK/lib$CASE"; mkdir -p "$T/cwd" "$T/fb"
  default_stubs
  export CI_OS_MODELS_FALLBACK_ROOT="$T/fb" CI_OS_HF_VIEW="$T/view" CI_OS_MODELS_CONF="$T/models.conf"
  export CI_OS_MODEL_PACKS_FILE="$T/packs.yaml"
  unset CI_OS_MODELS_CACHE CI_OS_OFFLINE CI_OS_PREFETCH_FLAG CI_OS_AP_MARKERS CI_OS_CDROM_MARKER CI_OS_CMDLINE_FILE \
        CI_OS_FIT_RAM_MIB CI_OS_FIT_VRAM_MIB CI_OS_FIT_UNIFIED CI_OS_MODEL_FIT_OVERRIDE CI_OS_MODELS_EVENTS \
        CI_OS_CI_STICK CI_OS_MODELS_NO_CISTICK CI_OS_MODELS_SET_HF_HOME CI_OS_MODEL_LOCK_FILE OLLAMA_MODELS
  cat > "$T/packs.yaml" <<'YEOF'
packs:
  - name: t1
    models:
      - &tiny {name: tiny, tag: 1b, min_ram_gb: 4, min_vram_gb: null}
      - &mid {name: mid, tag: 8b, min_ram_gb: 16, min_vram_gb: null}
      - &big {name: big, tag: 27b, min_ram_gb: 32, min_vram_gb: 24}
  - name: t2
    models:
      - *tiny
  - name: nothing
    models:
      - *big
YEOF
  export CI_OS_FIT_RAM_MIB=16384 CI_OS_FIT_VRAM_MIB=0 CI_OS_FIT_UNIFIED=0
}
cli() { (cd "$T/cwd" && bash "$MODELS_SH" "$@"); }
# run <args...>: sets rc, out, err
run() { rc=0; out="$(cli "$@" 2>"$T/err")" || rc=$?; err="$(cat "$T/err")"; }
src() { # src <code>: run code with the library sourced, in a subshell
  (cd "$T/cwd" && . "$MODELS_SH" && eval "$1")
}
use_cache() { cache_make "$T/cache"; export CI_OS_MODELS_CACHE="$T/cache"; }
stick_calls() { stub_log ci-stick | grep -v -- '--help' || true; }

echo "== references"
newcase
for pair in "gemma3:1b=ollama" "nomic-embed-text=ollama" "library/gemma3:1b=ollama" "localhost:5000/x/y:z=ollama" \
            "hf.co/unsloth/GLM-5.2-GGUF:UD-Q4_K_XL=hf" "hf.co/org/repo=hf" "huggingface.co/org/repo:Q4=hf" \
            "-rf=invalid" "--help=invalid" "a b=invalid" "x;id=invalid" 'x$(id)=invalid' "../x=invalid" "a/../b=invalid" "hf.co/../x=invalid" \
            "a/=invalid" "=invalid" "a|b=invalid" "a\`b=invalid" ".hidden=invalid" "ü=invalid"; do
  ref="${pair%=*}"; want="${pair##*=}"
  got="$(cd "$T/cwd" && . "$MODELS_SH" && ci_models_ref_kind "$ref")"
  t_eq "kind of '$ref'" "$want" "$got"
done
t_eq "an Ollama reference without a tag gets :latest" "gemma3:latest" "$(. "$MODELS_SH"; ci_models_norm_ref gemma3)"
t_eq "with a tag it is left alone" "gemma3:1b" "$(. "$MODELS_SH"; ci_models_norm_ref gemma3:1b)"

echo "== models.conf (data, never sourced)"
newcase
cat > "$T/models.conf" <<'CEOF'
# a comment
pack = stick-128
  limit_rate=10MiB/s
quoted="a value with spaces"
single='x y'
assume_unmetered=0
assume_unmetered=1
$(touch PWNED)=1
evil=$(touch PWNED2)
=noname
CEOF
t_eq "key = value with spaces around =" "stick-128" "$(src 'ci_models_conf_get pack')"
t_eq "leading and trailing blanks are trimmed" "10MiB/s" "$(src 'ci_models_conf_get limit_rate')"
t_eq "double quotes are removed" "a value with spaces" "$(src 'ci_models_conf_get quoted')"
t_eq "single quotes are removed" "x y" "$(src 'ci_models_conf_get single')"
t_eq "the last assignment wins" "1" "$(src 'ci_models_conf_get assume_unmetered')"
t_eq "a missing key gives the default" "dflt" "$(src 'ci_models_conf_get nothere dflt')"
t_eq "a missing file gives the default" "dflt" "$(CI_OS_MODELS_CONF="$T/nofile" src 'ci_models_conf_get pack dflt')"
t_eq "the value of a command substitution is text, not executed" '$(touch PWNED2)' "$(src 'ci_models_conf_get evil')"
t_eq "nothing was executed" "" "$(find "$T" -name 'PWNED*' | head -1)"

echo "== where the cache is"
newcase
t_eq "nothing mounted: the fallback root, kind fallback" "$T/fb|$T/fb/models|fallback" "$(src 'ci_models_cache_resolve; echo "$CI_MODELS_ROOT|$CI_MODELS_STORE|$CI_MODELS_KIND"')"
mkdir -p "$T/mnt"
fake findmnt.label "$T/mnt/
"
t_eq "CI-CACHE mounted (found by label): kind stick, trailing slash dropped" "$T/mnt|$T/mnt/models|$T/mnt/ci-models|stick" "$(src 'ci_models_cache_resolve; echo "$CI_MODELS_ROOT|$CI_MODELS_STORE|$CI_MODELS_XDIR|$CI_MODELS_KIND"')"
fake findmnt.label "$T/does-not-exist"
t_eq "a label target that is not a directory is ignored" "fallback" "$(src 'ci_models_cache_resolve; echo "$CI_MODELS_KIND"')"
unfake findmnt.label
fake findmnt.mnt "$T/mnt"
t_eq "mounted where ci-os-ollama-models-env mounts it (CI_OS_CACHE_MOUNT): kind stick" "stick:$T/mnt" "$(CI_OS_CACHE_MOUNT="$T/mnt" src 'ci_models_cache_resolve; echo "$CI_MODELS_KIND:$CI_MODELS_ROOT"')"
unfake findmnt.mnt
fake blkid.label "/dev/sdb2"
t_eq "attached but not mounted: a note says so" "fallback:CI-CACHE is attached (/dev/sdb2) but not mounted" "$(src 'ci_models_cache_resolve; echo "$CI_MODELS_KIND:$CI_MODELS_NOTE"')"
fake findmnt.label "$T/mnt"
t_eq "an explicit cache wins over the mount" "override:$T/explicit" "$(CI_OS_MODELS_CACHE="$T/explicit/" src 'ci_models_cache_resolve; echo "$CI_MODELS_KIND:$CI_MODELS_ROOT"')"
rmstub findmnt; rmstub blkid
t_eq "without findmnt and blkid: still the fallback, no error" "fallback" "$(src 'ci_models_cache_resolve; echo "$CI_MODELS_KIND"')"
unfake findmnt.label; unfake blkid.label

echo "== the environment"
newcase
run env --format raw
t_eq "no cache anywhere: the environment is empty (the daemon's file stays empty as before)" "" "$out"
use_cache
run env --format raw
t_has "a cache: OLLAMA_MODELS is its models directory" "$out" "OLLAMA_MODELS=$T/cache/models"
t_has "OLLAMA_NOPRUNE=1 (a seeded store has files Ollama would otherwise delete at start)" "$out" "OLLAMA_NOPRUNE=1"
t_has "CI_STICK_CACHE is the cache root" "$out" "CI_STICK_CACHE=$T/cache"
t_has "HF_HUB_CACHE is the view" "$out" "HF_HUB_CACHE=$T/view/hub"
t_has "HUGGINGFACE_HUB_CACHE too" "$out" "HUGGINGFACE_HUB_CACHE=$T/view/hub"
t_has "LLAMA_CACHE is the same directory (llama.cpp uses it as the hub directory itself)" "$out" "LLAMA_CACHE=$T/view/hub"
t_lacks "HF_HOME is NOT set by default (it also decides where a login token is stored)" "$out" "HF_HOME"
t_has "no default route in the fixture: HF_HUB_OFFLINE=1" "$(CI_OS_PROC_NET_ROUTE="$T/none" cli env --format raw)" "HF_HUB_OFFLINE=1"
t_lacks "a default route: HF_HUB_OFFLINE is not set" "$out" "HF_HUB_OFFLINE"
t_has "CI_OS_OFFLINE=1 forces it" "$(CI_OS_OFFLINE=1 cli env --format raw)" "HF_HUB_OFFLINE=1"
printf 'offline=1\n' > "$T/models.conf"
t_has "offline=1 in models.conf forces it" "$(cli env --format raw)" "HF_HUB_OFFLINE=1"
printf 'offline=0\n' > "$T/models.conf"
t_lacks "offline=0 in models.conf means never, even with no route at all" "$(CI_OS_PROC_NET_ROUTE="$T/none" cli env --format raw)" "HF_HUB_OFFLINE"
printf 'offline=auto\n' > "$T/models.conf"
t_has "offline=auto is the default: no route, offline" "$(CI_OS_PROC_NET_ROUTE="$T/none" cli env --format raw)" "HF_HUB_OFFLINE=1"
t_lacks "offline=auto with a route: online" "$(cli env --format raw)" "HF_HUB_OFFLINE"
t_has "CI_OS_OFFLINE=1 beats offline=0" "$(printf 'offline=0\n' > "$T/models.conf"; CI_OS_OFFLINE=1 cli env --format raw)" "HF_HUB_OFFLINE=1"
printf 'set_hf_home=1\n' > "$T/models.conf"
t_has "set_hf_home=1 in models.conf exports HF_HOME (the view root)" "$(cli env --format raw)" "HF_HOME=$T/view"
t_has "CI_OS_MODELS_SET_HF_HOME=1 does too" "$(CI_OS_MODELS_SET_HF_HOME=1 cli env --format raw)" "HF_HOME=$T/view"
rm -f "$T/models.conf"
run env --user --format raw
t_lacks "--user (for login shells) leaves out OLLAMA_MODELS" "$out" "OLLAMA_MODELS"
t_lacks "--user does not carry an automatic offline into a login shell (no route, nothing forced)" "$(CI_OS_PROC_NET_ROUTE="$T/none" cli env --user --format raw)" "HF_HUB_OFFLINE"
t_has "--user does carry a forced one (CI_OS_OFFLINE=1)" "$(CI_OS_OFFLINE=1 cli env --user --format raw)" "HF_HUB_OFFLINE=1"
t_has "--user does carry offline=1 from models.conf" "$(printf 'offline=1\n' > "$T/models.conf"; cli env --user --format raw; rm -f "$T/models.conf")" "HF_HUB_OFFLINE=1"
t_lacks "--user leaves out OLLAMA_NOPRUNE" "$out" "OLLAMA_NOPRUNE"
t_has "--user keeps the Hugging Face variables" "$out" "HF_HUB_CACHE="
unset CI_OS_MODELS_CACHE
t_eq "the fallback root without a store directory: empty" "" "$(cli env --format raw)"
mkdir -p "$T/fb/models"
run env --format raw
t_lacks "a store at the fallback root: no OLLAMA_MODELS (nothing makes Ollama read it)" "$out" "OLLAMA_MODELS"
t_has "but the Hugging Face variables are there" "$out" "HF_HUB_CACHE=$T/view/hub"
t_has "and CI_STICK_CACHE is the fallback root" "$out" "CI_STICK_CACHE=$T/fb"
# quoting
mkdir -p "$T/we ird'dir/cache"
sh_out="$(cd "$T/cwd" && CI_OS_MODELS_CACHE="$T/we ird'dir/cache" bash "$MODELS_SH" env --format sh)"
t_has "sh format: export KEY='value'" "$sh_out" "export OLLAMA_NOPRUNE='1'"
got="$(eval "$sh_out"; printf '%s' "$CI_STICK_CACHE")"
t_eq "sh format: a path with a space and a quote survives eval" "$T/we ird'dir/cache" "$got"
sd_out="$(cd "$T/cwd" && CI_OS_MODELS_CACHE="$T/we ird'dir/cache" bash "$MODELS_SH" env --format systemd)"
t_has "systemd format: KEY=value, spaces fine" "$sd_out" "CI_STICK_CACHE=$T/we ird'dir/cache"
mkdir -p "$T/q\"uote"
sd_out="$(cd "$T/cwd" && CI_OS_MODELS_CACHE="$T/q\"uote" bash "$MODELS_SH" env --format systemd 2>"$T/err")"
t_lacks "systemd format: a value with a double quote is dropped, not written wrong" "$sd_out" "CI_STICK_CACHE"
t_has "and the reason is on stderr" "$(cat "$T/err")" "not writing"
run env --bogus
t_eq "env with an unknown option: usage error" "2" "$rc"

echo "== ci-stick exit codes 0..7 come back unchanged, with a message that says what to do"
newcase; use_cache
for pair in "1:reported an error" "2:usage error" "3:drift" "4:free space" "5:licence acceptance required" "6:interrupted" "7:integrity"; do
  code="${pair%%:*}"; word="${pair#*:}"
  fake ci-stick.rc "$code"; clear_logs
  run fetch --model gemma3:1b
  t_eq "fetch: ci-stick status $code is returned as $code" "$code" "$rc"
  t_has "status $code is explained ('$word')" "$err" "$word"
  t_eq "status $code: ollama pull was NOT run as a second try" "" "$(stub_log ollama)"
done
fake ci-stick.rc 0; clear_logs
run fetch --model gemma3:1b
t_eq "status 0 is 0" "0" "$rc"
t_eq "ci-stick was called with the model, the cache, and nothing else" "models fetch --model gemma3:1b --cache $T/cache" "$(stick_calls)"
fake ci-stick.rc 42
run fetch --model gemma3:1b
t_eq "an unknown status is passed through" "42" "$rc"
t_has "and called unexpected" "$err" "unexpected status 42"
fake ci-stick.rc 7; clear_logs
run fetch --model gemma3:1b --model tiny:1b
t_eq "fetch of two models stops at an integrity failure (7)" "1" "$(stick_calls | wc -l | tr -d ' ')"
fake ci-stick.rc 5; clear_logs
run fetch --model gemma3:1b --model tiny:1b
t_eq "but a licence refusal (5) lets the others go on, and 5 is the result" "5:2" "$rc:$(stick_calls | wc -l | tr -d ' ')"
fake ci-stick.rc 4; clear_logs
run fetch --model gemma3:1b --model tiny:1b
t_eq "a full disk (4) stops the run" "4:1" "$rc:$(stick_calls | wc -l | tr -d ' ')"
fake ci-stick.rc 0; clear_logs
run fetch --pack t1
t_eq "fetch --pack goes to ci-stick as one call" "models fetch --pack t1 --cache $T/cache" "$(stick_calls)"
run fetch --pack 'bad pack'
t_eq "a pack name with a space is refused (2)" "2" "$rc"
clear_logs; run fetch --model "$(printf 'gemma3:1b\nmodel tiny:1b')"
t_eq "a name with a newline in it (it would add a second item to the list) is refused (2), nothing runs" "2:" "$rc:$(stick_calls)$(stub_log ollama)"
run fetch --pack "$(printf 't1\npack t2')"
t_eq "...also for a pack" "2" "$rc"
run fetch
t_eq "fetch with nothing to fetch: usage (2)" "2" "$rc"
run fetch --bogus
t_eq "fetch with an unknown option: usage (2)" "2" "$rc"

echo "== optional ci-stick flags and licences"
newcase; use_cache; clear_logs
run fetch --model gemma3:1b --accept-licenses --lock "$T/lock.json" --events "$T/ev"
t_eq "--accept-licenses, --lock and --events are passed on" "models fetch --model gemma3:1b --cache $T/cache --lock $T/lock.json --events $T/ev --accept-licenses" "$(stick_calls)"
clear_logs
run fetch --model gemma3:1b
t_lacks "without --accept-licenses ci-stick is not told to accept anything" "$(stick_calls)" "accept"
clear_logs
run fetch --model gemma3:1b --limit-rate 2MiB/s
t_has "--limit-rate 2MiB/s becomes ci-stick's --max-bytes-per-sec 2MiB" "$(stick_calls)" "--max-bytes-per-sec 2MiB"
t_lacks "(no '/s' reaches ci-stick, which does not parse it)" "$(stick_calls)" "/s"
clear_logs
run fetch --model gemma3:1b --limit-rate 1048576
t_has "a plain number of bytes is passed as it is" "$(stick_calls)" "--max-bytes-per-sec 1048576"
clear_logs
run fetch --model gemma3:1b --limit-rate 500KB
t_has "500KB (decimal) is a rate" "$(stick_calls)" "--max-bytes-per-sec 500KB"
for bad in fast 500K 5M "5 MiB" '$(id)' "-1" "5MiB/h"; do
  clear_logs; run fetch --model gemma3:1b --limit-rate "$bad"
  t_eq "a rate ci-stick would not parse ('$bad') is refused (12) before ci-stick is called" "12:" "$rc:$(stick_calls)"
done
clear_logs; run fetch --model gemma3:1b --offline
t_has "--offline is passed on" "$(stick_calls)" "--cache $T/cache --offline"
fake ci-stick.help "  --pack --model --cache --lock --events --limit-rate"; clear_logs
run fetch --model gemma3:1b --limit-rate 2MiB/s
t_has "a ci-stick that spells it --limit-rate gets --limit-rate" "$(stick_calls)" "--limit-rate 2MiB"
fake ci-stick.help "  --pack --model --cache --lock --events --accept-licenses"; clear_logs
run fetch --model gemma3:1b --limit-rate 2MiB/s
t_eq "a bandwidth limit asked for but not supported: refused (12), nothing downloaded" "12:" "$rc:$(stick_calls)"
t_has "and it says why" "$err" "no bandwidth limit option"
run fetch --model gemma3:1b --limit-rate 0
t_eq "--limit-rate 0 means unlimited: allowed, no flag passed" "0" "$rc"
clear_logs; echo '{}' > "$T/lock-default.json"
CI_OS_MODEL_LOCK_FILE="$T/lock-default.json" run fetch --model gemma3:1b
t_has "with no --lock the default lock is handed to ci-stick" "$(stick_calls)" "--lock $T/lock-default.json"
clear_logs; echo '{}' > "$T/image.lock"
CI_OS_MODEL_LOCK_SEARCH="$T/missing.lock $T/image.lock" run fetch --model gemma3:1b
t_has "...or the first existing lock of the image's search list" "$(stick_calls)" "--lock $T/image.lock"
clear_logs; run fetch --model gemma3:1b
t_lacks "no lock anywhere: none is passed (ci-stick then looks above the working directory)" "$(stick_calls)" "--lock"
clear_logs; run fetch --model gemma3:1b --lock "$T/mine.json"
t_has "an explicit --lock wins" "$(stick_calls)" "--lock $T/mine.json"

echo "== no ci-stick: Ollama references fall back to 'ollama pull', Hugging Face references never do"
newcase; use_cache; rmstub ci-stick; clear_logs
run fetch --model gemma3:1b
t_eq "ollama pull is used" "pull gemma3:1b" "$(stub_log ollama)"
t_eq "status 0" "0" "$rc"
t_has "and it says it is a fallback without a lock" "$err" "ci-stick is not installed: using 'ollama pull gemma3:1b'"
clear_logs
run fetch --model nomic-embed-text
t_eq "a bare name gets :latest" "pull nomic-embed-text:latest" "$(stub_log ollama)"
clear_logs
run fetch --model hf.co/unsloth/gemma-3-270m-it-GGUF:Q4_K_M
t_eq "a Hugging Face reference: status 10, ollama never called" "10:" "$rc:$(stub_log ollama)"
t_has "and the message explains why" "$err" "never through 'ollama pull'"
run fetch --model huggingface.co/org/repo:Q4_K_M
t_eq "huggingface.co/... is a Hugging Face reference too" "10:" "$rc:$(stub_log ollama)"
fake ollama.rc 3
run fetch --model gemma3:1b
t_eq "ollama pull failing: its status comes back" "3" "$rc"
unfake ollama.rc
rmstub ollama; clear_logs
run fetch --model gemma3:1b
t_eq "no ci-stick and no ollama: status 10 and a message" "10" "$rc"
t_has "naming both" "$err" "ollama is not installed either"
default_stubs; rmstub ci-stick; use_cache; clear_logs
run fetch --pack t2
t_eq "a pack without ci-stick is expanded from model-packs.yaml: its models are pulled one by one" "pull tiny:1b" "$(stub_log ollama)"
run fetch --pack t1
t_eq "t1 pulls its three models in catalog order" "pull tiny:1b
pull mid:8b
pull big:27b" "$(stub_log ollama | tail -3)"
clear_logs
run fetch --pack nonesuch
t_eq "an unknown pack: usage (2), nothing pulled" "2:" "$rc:$(stub_log ollama)"

echo "== ci-stick present but a failure is a failure"
newcase; use_cache; fake ci-stick.rc 7; clear_logs
run fetch --model gemma3:1b
t_eq "no 'ollama pull' after a ci-stick failure" "" "$(stub_log ollama)"
t_eq "and the status is ci-stick's" "7" "$rc"

echo "== ci-stick present, but Ollama does not read the cache that would be filled"
newcase; clear_logs      # no CI-CACHE, no override: the fallback root
run fetch --model gemma3:1b
t_eq "an Ollama reference goes to 'ollama pull' (the daemon's own store)" "pull gemma3:1b" "$(stub_log ollama)"
t_eq "ci-stick was not asked to fill a store Ollama does not read" "" "$(stick_calls)"
t_has "and the log says why" "$err" "Ollama does not read the cache"
clear_logs
run fetch --model hf.co/unsloth/gemma-3-270m-it-GGUF:Q4_K_M
t_has "a Hugging Face reference goes to ci-stick, into the fallback root" "$(stick_calls)" "models fetch --model hf.co/unsloth/gemma-3-270m-it-GGUF:Q4_K_M --cache $T/fb"
t_eq "and never to ollama" "" "$(stub_log ollama)"
clear_logs
OLLAMA_MODELS="$T/fb/models" run fetch --model gemma3:1b
t_has "OLLAMA_MODELS pointing at the store means Ollama does read it: ci-stick is used" "$(stick_calls)" "models fetch --model gemma3:1b --cache $T/fb"

echo "== references that are refused, never run"
newcase; use_cache; clear_logs
for bad in "-rf" "--help" "a b" 'x$(touch PWNED)' "x;touch PWNED" "../x" "hf.co/../x" "x|y"; do
  run fetch --model "$bad"
  t_eq "fetch --model '$bad': refused (12)" "12" "$rc"
done
t_eq "nothing was run for them" "" "$(stub_log ollama)$(stick_calls)"
t_eq "and no command in them ran" "" "$(find "$T" -name 'PWNED*' | head -1)"

echo "== the cache must be writable by the caller"
newcase; use_cache; clear_logs
if [ "$(id -u)" -eq 0 ]; then
  t_skip "running as root: a read-only directory is writable for root (run this test as a normal user, e.g. docker run --user 1000)"
else
  chmod 0555 "$T/cache"
  run fetch --model gemma3:1b
  t_eq "a cache directory the caller cannot write: status 13, ci-stick not called" "13:" "$rc:$(stick_calls)"
  t_has "the message names the ollama user" "$err" "'ollama' user"
  chmod 0755 "$T/cache"
fi

echo "== ensure: the hardware gate, then fetch"
newcase; use_cache; export CI_OS_FIT_RAM_MIB=16384; clear_logs
run ensure tiny:1b mid:8b big:27b
t_eq "16 GB, no GPU: tiny and mid are fetched, big (32 GB RAM, 24 GB VRAM) is skipped" "models fetch --model tiny:1b --cache $T/cache
models fetch --model mid:8b --cache $T/cache" "$(stick_calls)"
t_eq "status 0 (something was fetched)" "0" "$rc"
t_has "the skip is explained" "$err" "skipping big:27b: needs 32 GB of RAM"
clear_logs
run ensure big:27b
t_eq "only a model that does not fit: status 11, nothing fetched" "11:" "$rc:$(stick_calls)"
clear_logs
run ensure nope:1b
t_eq "a model nothing is known about is skipped (12), not downloaded blind" "12:" "$rc:$(stick_calls)"
t_has "and --allow-unknown is offered" "$err" "--allow-unknown"
run ensure --allow-unknown nope:1b
t_eq "--allow-unknown downloads it" "0:models fetch --model nope:1b --cache $T/cache" "$rc:$(stick_calls | tail -1)"
clear_logs
run ensure --no-gate big:27b
t_eq "--no-gate downloads it anyway" "0:models fetch --model big:27b --cache $T/cache" "$rc:$(stick_calls)"
clear_logs
CI_OS_FIT_RAM_MIB=65536 CI_OS_FIT_VRAM_MIB=24564 run ensure big:27b
t_eq "64 GB with a 24 GB card: big is fetched" "0:models fetch --model big:27b --cache $T/cache" "$rc:$(stick_calls)"
clear_logs
CI_OS_FIT_RAM_MIB=30500 CI_OS_FIT_VRAM_MIB=512 CI_OS_FIT_UNIFIED=1 run ensure big:27b
t_eq "a 32 GB unified-memory machine: big is fetched" "0:models fetch --model big:27b --cache $T/cache" "$rc:$(stick_calls)"
clear_logs
run ensure --pack t1
t_eq "ensure --pack expands the pack and gates each model" "models fetch --model tiny:1b --cache $T/cache
models fetch --model mid:8b --cache $T/cache" "$(stick_calls)"
fake ci-stick.rc 7; clear_logs
run ensure tiny:1b mid:8b
t_eq "ensure stops at an integrity failure (7) and returns it" "7:1" "$rc:$(stick_calls | wc -l | tr -d ' ')"
fake ci-stick.rc 3; clear_logs
run ensure tiny:1b mid:8b
t_eq "but drift (3) on one model does not stop the others; the first failure is the result" "3:2" "$rc:$(stick_calls | wc -l | tr -d ' ')"
fake ci-stick.rc 0
run ensure
t_eq "ensure with nothing: usage (2)" "2" "$rc"
run ensure --pack nonesuch
t_eq "ensure --pack with an unknown pack: usage (2)" "2" "$rc"
run ensure -x tiny:1b
t_eq "ensure with an unknown option: usage (2)" "2" "$rc"
run ensure '-rf'
t_eq "ensure with an option-looking reference: usage (2)" "2" "$rc"
clear_logs; run ensure "$(printf 'tiny:1b\nmid:8b')"
t_eq "ensure with a newline inside one argument: refused (2), nothing runs" "2:" "$rc:$(stick_calls)"
clear_logs
run ensure 'tiny:1b;touch PWNED'
t_eq "ensure with a hostile reference: refused (12), nothing run" "12:" "$rc:$(stick_calls)$(stub_log ollama)"
t_eq "no command ran" "" "$(find "$T" -name 'PWNED*' | head -1)"
# the gate without ci-stick: still gated, then ollama pull
rmstub ci-stick; clear_logs
run ensure tiny:1b big:27b
t_eq "without ci-stick the gate still applies; the rest is pulled" "pull tiny:1b" "$(stub_log ollama)"
clear_logs
run ensure hf.co/org/repo:Q4_K_M --allow-unknown
t_eq "an unknown Hugging Face reference without ci-stick: refused (10), never pulled" "10:" "$rc:$(stub_log ollama)"

echo "== fits"
newcase; use_cache
run fits tiny:1b mid:8b big:27b
t_eq "fits: one line per model, status 1 when one does not fit" "1" "$rc"
t_eq "the table" "tiny:1b${TAB}fits${TAB}fits: 16384 MiB of RAM, no GPU requirement
mid:8b${TAB}fits${TAB}fits: 16384 MiB of RAM, no GPU requirement
big:27b${TAB}no${TAB}needs 32 GB of RAM (29818 MiB); this machine has 16384 MiB" "$out"
run fits tiny:1b nope:1
t_eq "an unknown model: status 2" "2" "$rc"
run fits --pack t2
t_eq "fits --pack" "0" "$rc"
run fits
t_eq "fits with nothing: usage (2)" "2" "$rc"

echo "== plan"
newcase; use_cache; clear_logs
run plan --pack stick-128 --lock "$T/l.json" --json
t_eq "plan passes pack, cache, lock and --json to ci-stick" "models plan --pack stick-128 --cache $T/cache --lock $T/l.json --json" "$(stick_calls)"
fake ci-stick.rc 4; run plan --pack stick-128
t_eq "and its status (4) comes back explained" "4" "$rc"
t_has "explained" "$err" "free space"
rmstub ci-stick; run plan --pack stick-128
t_eq "plan without ci-stick: 10, pointing at 'fits --pack'" "10" "$rc"
t_has "the pointer" "$err" "fits --pack stick-128"
run plan
t_eq "plan without --pack: usage (2)" "2" "$rc"

echo "== info and cache"
newcase; use_cache; clear_logs
run info
t_has "info shows the cache" "$out" "root:  $T/cache"
t_has "and asks ci-stick for cache-info" "$(stub_log ci-stick)" "models cache-info --json --cache $T/cache"
rmstub ci-stick; run info
t_has "info without ci-stick says so" "$out" "ci-stick: not installed"
run cache --root
t_eq "cache --root" "$T/cache" "$out"
run cache --store
t_eq "cache --store" "$T/cache/models" "$out"
run cache --kind
t_eq "cache --kind" "override" "$out"
run cache --view
t_eq "cache --view" "$T/view" "$out"
run cache --nonsense
t_eq "cache with an unknown option: usage (2)" "2" "$rc"

echo "== the command line"
newcase
run help
t_has "help lists the commands" "$out" "prefetch-check"
run version
t_eq "version" "ci-os-models 1" "$out"
run nonsense
t_eq "an unknown command: usage (2)" "2" "$rc"
t_eq "sourcing the file defines functions and prints nothing" "" "$(cd "$T/cwd" && . "$MODELS_SH" 2>&1 && declare -F ci_models_main >/dev/null && true)"
t_eq "sourcing does not run main" "ok" "$(cd "$T/cwd" && . "$MODELS_SH"; echo ok)"

echo "== the prefetch condition: all conditions, one at a time"
base() { # base: everything right
  newcase; use_cache
  mkdir -p "$T/cache"; touch "$T/flag"
  export CI_OS_PREFETCH_FLAG="$T/flag" CI_OS_AP_MARKERS="$T/ap1 $T/ap2" CI_OS_CDROM_MARKER="$T/no-cdrom"
  printf 'quiet splash\n' > "$T/cmdline"; export CI_OS_CMDLINE_FILE="$T/cmdline"
  printf 'pack=t1\n' > "$T/models.conf"
  fake findmnt.fstype "exfat"
  fake nmcli.metered "no (guessed)"
}
chk() { run prefetch-check; }
base; chk
t_eq "everything right: go (0)" "0" "$rc"
base; rm -f "$T/flag"; chk
t_eq "no flag file: skip (1)" "1" "$rc"; t_has "and it says the flag is the reason" "$err" "opt-in flag file"
base; printf '' > "$T/models.conf"; chk
t_eq "no pack in models.conf: skip" "1" "$rc"; t_has "named" "$err" "no pack named"
base; printf 'pack=Bad Pack\n' > "$T/models.conf"; chk
t_eq "a pack name with a space: skip" "1" "$rc"
base; printf 'pack=../x\n' > "$T/models.conf"; chk
t_eq "a pack name with a path in it: skip" "1" "$rc"
base; rmstub ci-stick; chk
t_eq "no ci-stick: skip" "1" "$rc"; t_has "named" "$err" "ci-stick is not installed"
base; unset CI_OS_MODELS_CACHE; chk
t_eq "no cache volume (only the fallback root): skip" "1" "$rc"; t_has "named" "$err" "no cache volume is mounted"
for fs in tmpfs ramfs overlay overlayfs aufs squashfs iso9660 fuse.overlayfs ""; do
  base; fake findmnt.fstype "$fs"; chk
  t_eq "cache on '${fs:-an unknown filesystem}': skip (RAM or read-only)" "1" "$rc"
done
for fs in exfat ext4 xfs btrfs; do
  base; fake findmnt.fstype "$fs"; chk
  t_eq "cache on $fs: fine" "0" "$rc"
done
base; printf 'pack=t1\nlimit_rate=fast\n' > "$T/models.conf"; chk
t_eq "limit_rate that is not a rate: skip" "1" "$rc"
base; printf 'pack=t1\nlimit_rate=$(id)\n' > "$T/models.conf"; chk
t_eq "limit_rate with a substitution: skip" "1" "$rc"
base; fake ci-stick.help "--pack --model"; chk
t_eq "ci-stick without a bandwidth option: skip (no unthrottled background download)" "1" "$rc"; t_has "named" "$err" "no bandwidth limit option"
base; fake ci-stick.help "--pack --model"; printf 'pack=t1\nlimit_rate=0\n' > "$T/models.conf"; chk
t_eq "...unless the limit is explicitly 0 (unlimited)" "0" "$rc"
base; printf 'pack=t1\nlimit_rate=500KB\n' > "$T/models.conf"; chk
t_eq "limit_rate=500KB is a rate" "0" "$rc"
base; printf 'pack=t1\nlimit_rate=500K\n' > "$T/models.conf"; chk
t_eq "limit_rate=500K is not one ci-stick can parse (single letters are ambiguous): skip" "1" "$rc"
base; fake nmcli.metered "yes"; chk
t_eq "metered: skip" "1" "$rc"; t_has "named" "$err" "network state is 'metered'"
base; fake nmcli.metered "yes (guessed)"; chk
t_eq "metered (guessed): skip - NetworkManager's docs say to treat a guessed yes as metered" "1" "$rc"
base; fake nmcli.metered "yes (guessed)"; printf 'pack=t1\nassume_unmetered=1\n' > "$T/models.conf"; chk
t_eq "...and assume_unmetered=1 does not change that: a guessed yes is metered, not unknown" "1" "$rc"; t_has "named" "$err" "'metered'"
base; fake nmcli.metered "no"; chk
t_eq "unmetered: go" "0" "$rc"
base; fake nmcli.metered "unknown"; chk
t_eq "metered state unknown: skip" "1" "$rc"; t_has "named" "$err" "unknown"
base; fake nmcli.metered "unknown"; printf 'pack=t1\nassume_unmetered=1\n' > "$T/models.conf"; chk
t_eq "...unless assume_unmetered=1" "0" "$rc"
base; rmstub nmcli; chk
t_eq "no nmcli: unknown, skip" "1" "$rc"
base; rm -f "$T/proc-net-route"; export CI_OS_PROC_NET_ROUTE="$T/none"; chk
t_eq "no default route (offline): skip" "1" "$rc"; t_has "named" "$err" "'offline'"
base; touch "$T/ap1"; chk
t_eq "a setup access point marker: skip" "1" "$rc"; t_has "named" "$err" "'ap'"
base; touch "$T/ap2"; chk
t_eq "the second marker too" "1" "$rc"
base; printf 'hostapd-setup.service\n' > "$FAKE/systemctl.active"; chk
t_eq "hostapd-setup.service active: skip" "1" "$rc"
base; printf 'ci-setup-ap.target\n' > "$FAKE/systemctl.active"; chk
t_eq "ci-setup-ap.target active: skip" "1" "$rc"
base; mkstub iw 'echo "Interface wlan0"; echo "        type AP"'; chk
t_eq "an interface in AP mode: skip" "1" "$rc"
base; mkstub iw 'echo "Interface wlan0"; echo "        type managed"'; chk
t_eq "an interface in managed mode: fine" "0" "$rc"
if [ "$(id -u)" -ne 0 ]; then
  base; chmod 0555 "$T/cache"; chk
  t_eq "a cache the unit's user cannot write: skip" "1" "$rc"; t_has "named" "$err" "not writable"
  chmod 0755 "$T/cache"
fi
# live sessions
base; touch "$T/cdrom"; export CI_OS_CDROM_MARKER="$T/cdrom"; chk
t_eq "live session (the medium is mounted), no persistence: skip" "1" "$rc"; t_has "named" "$err" "persistence"
base; printf 'boot=casper quiet splash\n' > "$T/cmdline"; chk
t_eq "live session by boot=casper, no persistence: skip" "1" "$rc"
persist_ok() {
  printf 'boot=casper persistent quiet splash\n' > "$T/cmdline"
  mkdir -p "$T/bylabel" "$T/sysext4/sdz1"; : > "$T/sdz1"
  ln -sf "$T/sdz1" "$T/bylabel/writable"
  fake blkid.type ext4
  export CI_OS_DISK_BY_LABEL="$T/bylabel" CI_OS_SYS_EXT4="$T/sysext4"
}
base; touch "$T/cdrom"; export CI_OS_CDROM_MARKER="$T/cdrom"; persist_ok; chk
t_eq "live session with the persistence volume really in use: go" "0" "$rc"
base; touch "$T/cdrom"; export CI_OS_CDROM_MARKER="$T/cdrom"; persist_ok; printf 'boot=casper persistent nopersistent\n' > "$T/cmdline"; chk
t_eq "...but nopersistent on the command line: skip" "1" "$rc"
base; touch "$T/cdrom"; export CI_OS_CDROM_MARKER="$T/cdrom"; persist_ok; fake blkid.type vfat; chk
t_eq "...the volume is not ext4: skip" "1" "$rc"
base; touch "$T/cdrom"; export CI_OS_CDROM_MARKER="$T/cdrom"; persist_ok; rmdir "$T/sysext4/sdz1"; chk
t_eq "...casper did not mount it (no /sys/fs/ext4 entry): skip" "1" "$rc"
base; touch "$T/cdrom"; export CI_OS_CDROM_MARKER="$T/cdrom"; persist_ok; rm -f "$T/bylabel/writable"; chk
t_eq "...no volume labelled writable: skip" "1" "$rc"
base; touch "$T/cdrom"; export CI_OS_CDROM_MARKER="$T/cdrom"; persist_ok; mv "$T/bylabel/writable" "$T/bylabel/casper-rw"; chk
t_eq "...the legacy casper-rw label works too" "0" "$rc"
base; touch "$T/cdrom"; export CI_OS_CDROM_MARKER="$T/cdrom"; persist_ok; printf 'boot=casper quiet\n' > "$T/cmdline"; chk
t_eq "...a volume exists but 'persistent' is not on the command line: skip" "1" "$rc"

echo "== the prefetch job"
pbase() { newcase; use_cache; printf 'pack=t1\n' > "$T/models.conf"; export CI_OS_MODELS_EVENTS="$T/events"; }
pf() { run prefetch; }
pbase; export CI_OS_FIT_RAM_MIB=16384; clear_logs; pf
t_eq "prefetch: the models that fit are fetched, with the default 5MiB limit and the events file, no licences" "models fetch --model tiny:1b --cache $T/cache --events $T/events --max-bytes-per-sec 5MiB
models fetch --model mid:8b --cache $T/cache --events $T/events --max-bytes-per-sec 5MiB" "$(stick_calls)"
t_eq "status 0" "0" "$rc"
pbase; printf 'pack=t1\nlimit_rate=1MiB/s\naccept_licenses=1\n' > "$T/models.conf"; clear_logs; pf
t_has "limit_rate and accept_licenses from models.conf are used" "$(stick_calls | head -1)" "--events $T/events --accept-licenses --max-bytes-per-sec 1MiB"
pbase; printf 'pack=t1\naccept_licenses=yes\n' > "$T/models.conf"; clear_logs; pf
t_lacks "accept_licenses must be exactly 1" "$(stick_calls)" "accept"
pbase; clear_logs; CI_OS_FIT_RAM_MIB=1024 pf
t_eq "nothing fits: status 0 and a message, nothing fetched" "0:" "$rc:$(stick_calls)"
t_has "the message" "$err" "nothing in pack 't1' fits"
for pair in "3:0" "4:0" "5:0" "6:6" "7:7" "1:1"; do
  code="${pair%%:*}"; want="${pair##*:}"
  pbase; fake ci-stick.rc "$code"; pf
  t_eq "prefetch: ci-stick status $code gives $want" "$want" "$rc"
done
pbase; printf 'pack=nonesuch\n' > "$T/models.conf"; pf
t_eq "a pack the catalog does not have: 2" "2" "$rc"
pbase; printf '' > "$T/models.conf"; pf
t_eq "no pack configured: 2" "2" "$rc"
pbase; fake ci-stick.help "--pack --model"; pf
t_eq "ci-stick without a bandwidth option: refused (12), nothing downloaded" "12:" "$rc:$(stick_calls)"

t_summary "models-lib"
