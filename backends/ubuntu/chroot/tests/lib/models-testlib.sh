# shellcheck shell=bash disable=SC2034
#=============================================================================
# Shared helpers of the model-tooling tests (backends/ubuntu/chroot/tests/models-*.sh). Sourced, never run.
#
# Everything runs without root, without Docker, without a network, on a stock Mac (bash 3.2, BSD awk) as well as
# on Linux (bash 5, mawk or gawk). The tools the code under test calls (ollama, ci-stick, nmcli, findmnt, blkid,
# lsblk, nvidia-smi, rocm-smi, lscpu, id, mount, runuser...) are shell scripts in a PATH directory ($STUBS) that read
# their behaviour from small files in $FAKE; every call is appended to $FAKE/<tool>.log.
#
# CI_MODELS_TEST_LIBDIR points the tests at another copy of core/lib (the mutation proofs use it).
#=============================================================================

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
# CI_MODELS_TEST_FAILFAST=1 stops at the first failed check (the mutation proofs only need to know that it fails)
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; if [ "${CI_MODELS_TEST_FAILFAST:-0}" = 1 ]; then printf '== stopped at the first failure\n'; exit 1; fi; }
t_skip() { printf 'SKIP  %s\n' "$*"; }
t_info() { printf 'info  %s\n' "$*"; }
# expect "<label>" <command...>: passes when the command succeeds
expect() { local label="$1"; shift; if "$@"; then t_pass "$label"; else t_fail "$label"; fi; }
# expect_not "<label>" <command...>: passes when the command fails
expect_not() { local label="$1"; shift; if "$@"; then t_fail "$label"; else t_pass "$label"; fi; }
# t_eq "<label>" <expected> <actual>
t_eq() {
  if [ "$2" = "$3" ]; then t_pass "$1"; else t_fail "$1 (expected '$2', got '$3')"; fi
}
# t_has "<label>" <haystack> <needle>
t_has() {
  case "$2" in *"$3"*) t_pass "$1" ;; *) t_fail "$1 (no '$3' in: $(printf '%s' "$2" | head -c 300))" ;; esac
}
t_lacks() {
  case "$2" in *"$3"*) t_fail "$1 (found '$3' in: $(printf '%s' "$2" | head -c 300))" ;; *) t_pass "$1" ;; esac
}
t_summary() {
  printf '== %s: %s passed, %s failed\n' "${1:-summary}" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../../.." && pwd)"
LIBDIR="${CI_MODELS_TEST_LIBDIR:-$REPO_ROOT/core/lib}"
PACKS_FILE="$LIBDIR/../manifest/model-packs.yaml"
MODELS_SH="$LIBDIR/ci-os-models.sh"
GPU_SH="$LIBDIR/gpu-detect.sh"

for _f in "$MODELS_SH" "$GPU_SH" "$PACKS_FILE"; do
  [ -f "$_f" ] || { echo "missing $_f" >&2; exit 2; }
done
unset _f

SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-models-test.XXXXXX")"
STUBS="$WORK/stubs"
FAKE="$WORK/fake"
mkdir -p "$STUBS" "$FAKE"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# Forget anything the caller's environment could change.
for _v in $(env | sed -n 's/^\(CI_OS_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
unset _v OLLAMA_MODELS OLLAMA_NOPRUNE HF_HUB_CACHE HF_HOME HUGGINGFACE_HUB_CACHE LLAMA_CACHE HF_HUB_OFFLINE CI_STICK_CACHE
export CI_MODELS_TEST_LIBDIR="$LIBDIR"
export LC_ALL=C

# mkstub <name> <body>: an executable /bin/sh script in $STUBS that first logs its arguments to $FAKE/<name>.log.
mkstub() {
  local name="$1" body="$2"
  {
    printf '#!/bin/sh\n'
    printf 'FAKE="%s"\n' "$FAKE"
    # shellcheck disable=SC2016  # the dollar signs are for the stub
    printf 'printf "%%s\\n" "$*" >> "$FAKE/%s.log"\n' "$name"
    printf '%s\n' "$body"
  } > "$STUBS/$name"
  chmod +x "$STUBS/$name"
}
rmstub() { rm -f "$STUBS/$1"; }
# fake <name> <content>: a behaviour file
fake() { printf '%s' "$2" > "$FAKE/$1"; }
unfake() { rm -f "$FAKE/$1"; }
stub_log() { cat "$FAKE/$1.log" 2>/dev/null || true; }
clear_logs() { rm -f "$FAKE"/*.log; }

# The stub set every test starts from. Behaviour files in $FAKE:
#   ollama.rc, ci-stick.rc, ci-stick.help, nmcli.metered, findmnt.{label,mnt,fstype,dev}, blkid.label, blkid.type,
#   lscpu.model, nvidia-smi.out, rocm-smi.csv, rocm-smi.plain, systemctl.active (list of active units)
default_stubs() {
  rm -rf "$STUBS" "$FAKE"; mkdir -p "$STUBS" "$FAKE"
  mkstub ollama 'case "$1" in pull) exit "$(cat "$FAKE/ollama.rc" 2>/dev/null || echo 0)" ;; list) exit 0 ;; esac; exit 0'
  mkstub ci-stick 'case " $* " in *" --help "*) cat "$FAKE/ci-stick.help" 2>/dev/null || echo "  --pack --model --cache --lock --events --offline --accept-licenses --max-bytes-per-sec --concurrency --json"; exit 0 ;; esac
exit "$(cat "$FAKE/ci-stick.rc" 2>/dev/null || echo 0)"'
  mkstub nmcli 'case "$*" in *GENERAL.METERED*) cat "$FAKE/nmcli.metered" 2>/dev/null || echo "no (guessed)" ;; esac; exit 0'
  mkstub findmnt 'case "$*" in
  *"-S LABEL="*) cat "$FAKE/findmnt.label" 2>/dev/null ;;
  *"-M "*) cat "$FAKE/findmnt.mnt" 2>/dev/null ;;
  *"-T "*) cat "$FAKE/findmnt.fstype" 2>/dev/null ;;
  *"-S "*) cat "$FAKE/findmnt.dev" 2>/dev/null ;;
esac
exit 0'
  mkstub blkid 'case "$*" in
  *"-L "*) cat "$FAKE/blkid.label" 2>/dev/null ;;
  *"-s TYPE"*) cat "$FAKE/blkid.type" 2>/dev/null ;;
esac
exit 0'
  mkstub lscpu 'echo "Model name:                      $(cat "$FAKE/lscpu.model" 2>/dev/null || echo "Test CPU")"'
  mkstub systemctl 'case "$1" in is-active) shift; for a in "$@"; do case "$a" in -*) ;; *) grep -qx "$a" "$FAKE/systemctl.active" 2>/dev/null && exit 0 ;; esac; done; exit 3 ;; esac; exit 0'
  # a route table with one default route on eth0, and a metered state of "no (guessed)"
  printf 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\neth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n' > "$FAKE/proc-net-route"
  export CI_OS_PROC_NET_ROUTE="$FAKE/proc-net-route"
  export PATH="$STUBS:$SYS_PATH"
  # no lock in the image or the repository, whatever the repository holds today (the tests supply their own)
  export CI_OS_MODEL_LOCK_SEARCH="$WORK/no-image-lock"
}

# A cache on disk: cache_make <root> creates root/models/blobs and root/ci-models/{blobs,locks}.
cache_make() { mkdir -p "$1/models/blobs" "$1/ci-models/blobs" "$1/ci-models/locks"; }
HEX64_A=b1baabd6b729e4041822220d3e648e00d99cac5df86b10dffb77bcccf0688e39
HEX64_B=e00cf79514204dfe2f4d6943f277ffea7fd8a4c8e955b4b7a869cfc157694881
HEX64_C=0d29b1a23a4cb1f14fda28c9e63563fa4bbefb6f34db4f7e873bb72edd932b00
REV_A=c90975dbd40c0c7b275fefaae758c3415c906238
REV_B=360e988e0000000000000000000000000000abcd
blob_make() { # blob_make <root> <hex> [content]
  printf '%s' "${3:-GGUF-$2}" > "$1/models/blobs/sha256-$2"
}
TAB="$(printf '\t')"

# bash major version, for the checks that need ${var,,} (bash 4+)
BASH_MAJOR="${BASH_VERSINFO[0]:-3}"
