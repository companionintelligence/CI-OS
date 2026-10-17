#!/usr/bin/env bash
# shellcheck shell=bash
#=============================================================================
# ci-os-models - the OS-side adapter for model download and cache (Companion OS)
#
# One file, two uses: `source` it for the ci_models_* functions, or run it as the `ci-os-models` command.
# Written for bash 5 (the images) and kept bash 3.2 clean so its tests run on a stock Mac; awk programs are
# POSIX (BSD awk, mawk and gawk give the same output). No Python, no jq, no Rust: core/ and the shell backends
# never depend on ci-stick (steward rule), they only use it when it is there.
#
# DESIGN NOTE (the analysis behind it is docs/architecture/models-tooling.md; the decisions below were taken first)
#
#   Who does what.  `ci-stick models ...` (Rust, stick/) speaks the registry protocols, pins and verifies digests,
#   resumes, and writes the cache. This adapter does what only the OS knows: where the cache is, which
#   environment the consumers need, whether this machine can run a model, whether the network may be used, and
#   what to do when ci-stick is not on the machine. It never re-implements a download: the one other way to get
#   a model is `ollama pull`, and only for an Ollama reference when ci-stick is absent (or the cache it would
#   fill is one Ollama does not read).
#
#   The cache.  ONE content-addressed Ollama-format store on the stick's exFAT volume (CI-CACHE):
#       <root>/models/blobs/sha256-<hex>   <root>/models/manifests/...     = OLLAMA_MODELS
#       <root>/ci-models/blobs/<hh>/<hex>  <root>/ci-models/status.json    = files Ollama must not see, ci-stick state
#   <root> is: $CI_OS_MODELS_CACHE (explicit), else the CI-CACHE volume where it is mounted (by
#   ci-os-ollama-models-env, or by udisks), else /var/lib/ci-os (a plain directory: store /var/lib/ci-os/models).
#   Only the first two are wired to Ollama; the fallback is for ci-stick/HF use and is never exported as
#   OLLAMA_MODELS by anything here.
#
#   Consumers.  Ollama and CI-Hub read the store directly (their format). Hugging Face tools and llama.cpp want
#   the HF cache layout, and exFAT has no symlinks, so both would copy a 40 GB file. The view builder makes the
#   layout out of symlinks on a Linux-native directory instead (/var/lib/ci-os/hf-view/hub/models--ORG--NAME/
#   {refs/main,snapshots/<commit>/<file>}), each link pointing at the single exFAT blob. HF_HUB_CACHE and
#   LLAMA_CACHE point at it. Which file is which comes from the lock (repo, revision, file, sha256); a
#   file name that is not plain (control characters, "..", a leading "/", a backslash) is refused, never
#   escaped. The exFAT mount is owner-only (umask 0077, uid ollama): users other than ollama can read the
#   blobs only if the volume is mounted for them (CI_OS_CACHE_UMASK / CI_OS_CACHE_GROUP in the env script).
#
#   ci-stick contract (stick/crates/ci-stick/src/cmd_models.rs, read 2026-10-17):
#       models plan  --pack N [--cache D] [--lock F] [--accept-licenses] [--json]
#       models fetch (--pack N | --model REF) [--cache D] [--lock F] [--offline] [--accept-licenses]
#                    [--max-bytes-per-sec N] [--concurrency N] [--events FILE|-] [--json]
#       models cache-info [--cache D] [--lock F] [--json]
#   Exit codes: 0 ok, 1 error, 2 usage, 3 drift, 4 no space, 5 licence (the others were still fetched),
#   6 interrupted / network down after the retries / --offline with work left (partials kept, run again),
#   7 integrity. They are passed through unchanged and explained on stderr. This adapter adds 10 ci-stick not
#   installed (and no allowed fallback), 11 nothing fits this machine, 12 reference refused, 13 cache not writable.
#   --max-bytes-per-sec is used only if `ci-stick models fetch --help` mentions it (--limit-rate is tried
#   too); models.conf says `limit_rate=5MiB/s`, and ci-stick gets `5MiB`. Progress for the setup portal is
#   <cache>/ci-models/status.json, written by ci-stick itself. With no --lock, the first of
#   $CI_OS_MODEL_LOCK_FILE, /usr/share/ci-os/model-packs.lock.json, core/manifest/model-packs.lock.json
#   next to this file is passed; otherwise ci-stick looks for the lock above the working directory.
#
#   Fallback rules.  ci-stick absent: an Ollama reference is pulled with `ollama pull` (a pack is expanded from
#   model-packs.yaml); a Hugging Face reference (hf.co/...) is NEVER pulled any other way, because nothing else
#   pins its commit, refuses gated repos or checks the digest. ci-stick present: it is used, and a failure is a
#   failure (no silent retry through ollama, which would skip the lock). Ollama references go through ci-stick
#   only when Ollama reads that store (a stick or an explicit cache); otherwise `ollama pull` fills the
#   daemon's own store.
#
#   Hardware gate.  `ensure` and the prefetch ask ci_os_model_fits (core/lib/gpu-detect.sh) before downloading
#   a model: RAM and GPU memory against min_ram_gb / min_vram_gb of model-packs.yaml. `fetch` does not gate:
#   filling a stick is not about the machine it is plugged into.
#
#   Background prefetch (default OFF). ci-os-models-prefetch.path starts ci-os-models-prefetch.timer only when
#   the flag file /etc/ci-os/models-prefetch exists (the timer has no [Install]: nothing else enables it); the timer
#   wakes the service every few hours; the service's ExecCondition (`ci-os-models prefetch-check`) lets it run only
#   if ALL of these hold: the flag file exists, and in a live session the persistence volume is really in use (the
#   flag then lives on CI-PERSIST; a plain ISO session never prefetches); a pack is named in /etc/ci-os/models.conf;
#   ci-stick is installed; the cache is on a real filesystem (not tmpfs/overlay/ramfs); the default route's
#   NetworkManager metered state is "no"; no setup access point is up. Bandwidth is capped by `limit_rate`
#   (default 5MiB/s), niceness and I/O class come from the unit. Licences are never accepted unless
#   models.conf says accept_licenses=1.
#
#   Getting ci-stick into the image (WP7, not built here): see backends/ubuntu/chroot/payload/models/README.md.
#
# Return codes of the ci-os-models command: see the contract above; `ci-os-models help` lists the commands.
#
# (c) Companion Intelligence - Lifescope Inc
#=============================================================================

CI_MODELS_VERSION=1
CI_MODELS_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || CI_MODELS_LIBDIR=""

CI_MODELS_RC_NO_STICK=10
CI_MODELS_RC_UNFIT=11
CI_MODELS_RC_REFUSED=12
CI_MODELS_RC_NO_CACHE=13

# The hardware gate lives in gpu-detect.sh (which every provisioner already sources).
if ! declare -F ci_os_model_fits >/dev/null 2>&1; then
  for _ci_models_gd in "${CI_OS_GPU_DETECT:-}" "$CI_MODELS_LIBDIR/gpu-detect.sh" /usr/lib/ci-os/gpu-detect.sh \
                       /usr/lib/ci-os/bootstrap/core/lib/gpu-detect.sh; do
    if [ -n "$_ci_models_gd" ] && [ -f "$_ci_models_gd" ]; then
      # shellcheck source=gpu-detect.sh
      . "$_ci_models_gd"
      break
    fi
  done
  unset _ci_models_gd
fi

#--- small helpers ------------------------------------------------------------------------------------------------
ci_models_log() { printf 'ci-os-models: %s\n' "$*" >&2; }

# Quote one value for `eval` in a POSIX shell.
ci_models_shquote() {
  local s="$1" q="'"
  printf "'%s'" "${s//$q/$q\\$q$q}"
}

# ci_models_conf_get <key> [default]: value of key=value in /etc/ci-os/models.conf (CI_OS_MODELS_CONF). The file is
# data, never sourced: comments (#), blank lines, optional quotes, the last assignment wins.
ci_models_conf_get() {
  local key="$1" def="${2:-}" file="${CI_OS_MODELS_CONF:-/etc/ci-os/models.conf}" val=""
  if [ -r "$file" ]; then
    val="$(LC_ALL=C awk -v k="$key" '
      { line = $0; sub(/^[ \t]+/, "", line)
        if (line == "" || substr(line, 1, 1) == "#") next
        eq = index(line, "="); if (eq == 0) next
        name = substr(line, 1, eq - 1); sub(/[ \t]+$/, "", name)
        if (name != k) next
        v = substr(line, eq + 1); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v)
        q = sprintf("%c", 39)
        if (length(v) >= 2 && ((substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") || (substr(v, 1, 1) == q && substr(v, length(v), 1) == q))) v = substr(v, 2, length(v) - 2)
        val = v }
      END { print val }' "$file" 2>/dev/null)"
  fi
  if [ -n "$val" ]; then printf '%s\n' "$val"; else printf '%s\n' "$def"; fi
}

# ci_models_ref_kind <ref>: ollama | hf | invalid. A reference starts with a letter or digit (never "-": it
# must not be able to look like an option) and uses only the characters of Ollama names.
ci_models_ref_kind() {
  local ref="${1:-}"
  if [[ ! "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]] || [[ "$ref" == *..* ]] || [[ "$ref" == */ ]]; then
    echo invalid
    return 0
  fi
  case "$ref" in
    hf.co/*|huggingface.co/*) echo hf ;;
    *) echo ollama ;;
  esac
}

# A name or reference with a newline in it is refused outright: the item lists are newline separated.
ci_models_has_newline() { case "$1" in *$'\n'*) return 0 ;; esac; return 1; }

# ci_models_norm_ref <ref>: Ollama's default tag.
ci_models_norm_ref() {
  case "$1" in
    *:*) printf '%s\n' "$1" ;;
    *) printf '%s:latest\n' "$1" ;;
  esac
}

#--- the cache ----------------------------------------------------------------------------------------------------
# ci_models_cache_resolve: sets CI_MODELS_ROOT, CI_MODELS_STORE (= OLLAMA_MODELS), CI_MODELS_XDIR (ci-models/),
# CI_MODELS_KIND (override | stick | fallback) and CI_MODELS_NOTE.
# shellcheck disable=SC2034  # read by the callers and the tests
ci_models_cache_resolve() {
  local label="${CI_OS_CACHE_LABEL:-CI-CACHE}" mnt="${CI_OS_CACHE_MOUNT:-/var/lib/ci-os/cache}" t="" dev=""
  CI_MODELS_ROOT=""; CI_MODELS_KIND=""; CI_MODELS_NOTE=""
  if [ -n "${CI_OS_MODELS_CACHE:-}" ]; then
    CI_MODELS_ROOT="${CI_OS_MODELS_CACHE%/}"
    CI_MODELS_KIND=override
  else
    if command -v findmnt >/dev/null 2>&1; then
      t="$(findmnt -ln -S "LABEL=$label" -o TARGET 2>/dev/null | sed -n 1p)"
      [ -n "$t" ] || t="$(findmnt -ln -M "$mnt" -o TARGET 2>/dev/null | sed -n 1p)"
    fi
    if [ -n "$t" ] && [ -d "$t" ]; then
      CI_MODELS_ROOT="${t%/}"
      CI_MODELS_KIND=stick
    else
      CI_MODELS_ROOT="${CI_OS_MODELS_FALLBACK_ROOT:-/var/lib/ci-os}"
      CI_MODELS_KIND=fallback
      if command -v blkid >/dev/null 2>&1; then
        dev="$(blkid -L "$label" 2>/dev/null | sed -n 1p)"
        [ -z "$dev" ] || CI_MODELS_NOTE="$label is attached ($dev) but not mounted"
      fi
    fi
  fi
  CI_MODELS_STORE="$CI_MODELS_ROOT/models"
  CI_MODELS_XDIR="$CI_MODELS_ROOT/ci-models"
}

# Is the store one that the Ollama daemon reads? True for a stick or an explicit cache, or when OLLAMA_MODELS says so.
ci_models_ollama_reads_store() {
  case "$CI_MODELS_KIND" in
    stick|override) return 0 ;;
  esac
  [ -n "${OLLAMA_MODELS:-}" ] && [ "${OLLAMA_MODELS%/}" = "$CI_MODELS_STORE" ]
}

ci_models_view_dir() { printf '%s\n' "${CI_OS_HF_VIEW:-/var/lib/ci-os/hf-view}"; }

#--- network ------------------------------------------------------------------------------------------------------
# Interface of the default IPv4 route (lowest metric among the usable ones), from /proc/net/route.
ci_models_default_route_dev() {
  local f="${CI_OS_PROC_NET_ROUTE:-/proc/net/route}" dev=""
  [ -r "$f" ] || return 1
  dev="$(LC_ALL=C awk 'NR > 1 && $2 == "00000000" && $8 == "00000000" && substr($4, length($4), 1) ~ /[13579bdf]/ {
        if (best == "" || $7 + 0 < bm + 0) { best = $1; bm = $7 } }
      END { print best }' "$f" 2>/dev/null)"
  [ -n "$dev" ] || return 1
  printf '%s\n' "$dev"
}

# Is a setup access point (the headless captive portal) up? Then the radio is not an uplink and a phone is the "client".
ci_models_ap_active() {
  local m u
  # shellcheck disable=SC2086  # a space-separated list on purpose
  for m in ${CI_OS_AP_MARKERS:-/run/setup-device/configuring /run/ci-setup/hostapd.conf}; do
    [ -e "$m" ] && return 0
  done
  if command -v systemctl >/dev/null 2>&1; then
    for u in hostapd-setup.service ci-setup-hostapd.service ci-setup-ap.target; do
      systemctl is-active --quiet "$u" 2>/dev/null && return 0
    done
  fi
  if command -v iw >/dev/null 2>&1 && iw dev 2>/dev/null | grep -q 'type AP'; then
    return 0
  fi
  return 1
}

# NetworkManager's metered state of the default route's device: yes | no | unknown. nmcli prints "yes",
# "no", "yes (guessed)", "no (guessed)" or "unknown" (nmcli-common2.c, nmc_device_metered_to_string); LC_ALL=C
# because those words are translated. Per the NM docs a guess of "yes" counts as metered.
ci_models_metered_state() {
  local dev v=""
  command -v nmcli >/dev/null 2>&1 || { echo unknown; return 0; }
  dev="$(ci_models_default_route_dev)" || { echo unknown; return 0; }
  v="$(LC_ALL=C nmcli -t -g GENERAL.METERED device show "$dev" 2>/dev/null | sed -n 1p)"
  case "$v" in
    yes*) echo yes ;;
    no*) echo no ;;
    *) echo unknown ;;
  esac
}

# ap | offline | metered | unmetered | unknown
ci_models_network_state() {
  local m
  if ci_models_ap_active; then echo ap; return 0; fi
  if ! ci_models_default_route_dev >/dev/null; then echo offline; return 0; fi
  m="$(ci_models_metered_state)"
  case "$m" in
    yes) echo metered ;;
    no) echo unmetered ;;
    *) echo unknown ;;
  esac
}

# Offline for HF_HUB_OFFLINE: CI_OS_OFFLINE=1, or offline=1 in models.conf; offline=0 there means never; otherwise (auto)
# when there is no default route at the moment of asking. "forced" counts only an explicit setting: a login shell must
# not carry an automatic "offline" past the moment the network comes back (a stale HF_HUB_OFFLINE=1 makes every download
# fail), so only the daemon's environment file, which is rebuilt at every start, gets the automatic one.
ci_models_is_offline() {
  [ "${CI_OS_OFFLINE:-0}" = 1 ] && return 0
  case "$(ci_models_conf_get offline auto)" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ "${1:-}" != forced ] || return 1
  ci_models_default_route_dev >/dev/null && return 1
  return 0
}

#--- environment --------------------------------------------------------------------------------------------------
# ci_models_env_pairs [--user]: KEY=VALUE lines, nothing when there is no cache in use (so the daemon's environment
# file stays empty on a plain installation). --user leaves out the daemon's own OLLAMA_* variables.
#   OLLAMA_MODELS, OLLAMA_NOPRUNE=1   the store (stick or explicit cache only); NOPRUNE because Ollama deletes
#                                     unreferenced files in blobs/ at start-up and a seeded store is made offline
#   CI_STICK_CACHE                    the cache root, for ci-stick and scripts
#   HF_HUB_CACHE, HUGGINGFACE_HUB_CACHE, LLAMA_CACHE   the HF-layout view (llama.cpp uses LLAMA_CACHE as the hub dir)
#   HF_HOME                           only if set_hf_home=1 in models.conf: it also decides where the HF TOKEN lives
#   HF_HUB_OFFLINE=1                  when offline, so huggingface_hub answers from the view instead of waiting
ci_models_env_pairs() {
  local user=0 hub
  [ "${1:-}" != "--user" ] || user=1
  ci_models_cache_resolve
  case "$CI_MODELS_KIND" in
    stick|override)
      if [ "$user" = 0 ]; then
        printf 'OLLAMA_MODELS=%s\n' "$CI_MODELS_STORE"
        printf 'OLLAMA_NOPRUNE=1\n'
      fi
      ;;
    *)
      [ -d "$CI_MODELS_STORE" ] || return 0
      ;;
  esac
  hub="$(ci_models_view_dir)/hub"
  printf 'CI_STICK_CACHE=%s\n' "$CI_MODELS_ROOT"
  printf 'HF_HUB_CACHE=%s\n' "$hub"
  printf 'HUGGINGFACE_HUB_CACHE=%s\n' "$hub"
  printf 'LLAMA_CACHE=%s\n' "$hub"
  if [ "${CI_OS_MODELS_SET_HF_HOME:-$(ci_models_conf_get set_hf_home 0)}" = 1 ]; then
    printf 'HF_HOME=%s\n' "$(ci_models_view_dir)"
  fi
  if { [ "$user" = 1 ] && ci_models_is_offline forced; } || { [ "$user" = 0 ] && ci_models_is_offline; }; then
    printf 'HF_HUB_OFFLINE=1\n'
  fi
}

# ci_models_env_print <sh|systemd|raw> [--user]
#   sh       export KEY='value' lines for `eval "$(ci-os-models env)"`
#   systemd  KEY=value lines for an EnvironmentFile= (a value with a newline, quote or backslash is dropped: systemd
#            would read it differently)
#   raw      KEY=value
ci_models_env_print() {
  local fmt="${1:-sh}" line key val
  shift || true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$fmt" in
      sh) printf 'export %s=%s\n' "$key" "$(ci_models_shquote "$val")" ;;
      systemd)
        case "$val" in
          *\"*|*\\*|*$'\n'*) ci_models_log "not writing $key: its value has a quote or backslash" ;;
          *) printf '%s=%s\n' "$key" "$val" ;;
        esac
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < <(ci_models_env_pairs "$@")
}

#--- ci-stick -----------------------------------------------------------------------------------------------------
ci_models_stick_bin() {
  local c
  if [ -n "${CI_OS_CI_STICK:-}" ]; then
    [ -x "$CI_OS_CI_STICK" ] || return 1
    printf '%s\n' "$CI_OS_CI_STICK"
    return 0
  fi
  [ "${CI_OS_MODELS_NO_CISTICK:-0}" != 1 ] || return 1
  c="$(command -v ci-stick 2>/dev/null)" && { printf '%s\n' "$c"; return 0; }
  for c in /usr/lib/ci-os/ci-stick /usr/local/bin/ci-stick; do
    if [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

# Does `ci-stick models <subcommand> --help` mention <flag>? (optional flags are used only if they exist)
ci_models_stick_has_flag() {
  local bin help
  bin="$(ci_models_stick_bin)" || return 1
  help="$("$bin" models "$1" --help 2>&1 || true)"
  case "$help" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

# Explain a ci-stick exit code on stderr (the code itself is passed through by the callers).
ci_models_describe_exit() {
  local rc="$1" msg=""
  case "$rc" in
    0) return 0 ;;
    1) msg="ci-stick reported an error that retrying will not fix (a missing blob, a read-only cache, a disk error; its own output is above)" ;;
    2) msg="ci-stick rejected the command line or its input (usage error): this ci-stick may be older or newer than ci-os-models expects" ;;
    3) msg="drift: what the registry serves, the catalog and the lock no longer agree. Nothing was replaced. Re-lock (ci-stick models lock) and review the change before fetching" ;;
    4) msg="not enough free space on the cache${CI_MODELS_ROOT:+ ($CI_MODELS_ROOT)}. Partial downloads are kept; free space or pick a smaller pack and run it again" ;;
    5) msg="licence acceptance required for at least one model (the others were fetched). Read the licence ci-stick named, then run again with --accept-licenses if you accept it" ;;
    6) msg="interrupted, or the network stayed down, or --offline left work undone. Partial downloads are kept: run the same command again to resume" ;;
    7) msg="integrity check failed: a file does not match its pinned digest or size. Treat the cache as suspect until 'ci-stick models verify' is clean" ;;
    *) msg="ci-stick exited with the unexpected status $rc" ;;
  esac
  ci_models_log "$msg"
}

ci_models_stick_not_installed() {
  ci_models_log "ci-stick is not installed (looked for ci-stick in PATH, /usr/lib/ci-os/ci-stick, /usr/local/bin/ci-stick; set CI_OS_CI_STICK to point at it)"
}

# ci_models_stick_call <subcommand> [args...]: ci-stick models <subcommand> ..., exit code passed through and explained.
ci_models_stick_call() {
  local bin rc=0
  bin="$(ci_models_stick_bin)" || { ci_models_stick_not_installed; return "$CI_MODELS_RC_NO_STICK"; }
  "$bin" models "$@" || rc=$?
  ci_models_describe_exit "$rc"
  return "$rc"
}

#--- packs and references -----------------------------------------------------------------------------------------
# ci_models_pack_refs <pack>: name:tag of every model of the pack, in catalog order.
ci_models_pack_refs() {
  declare -F ci_os_model_packs_rows >/dev/null 2>&1 || return 1
  ci_os_model_packs_rows | LC_ALL=C awk -F'\t' -v p="$1" '$1 == p { print $2 ":" $3 }'
}

# Options shared by fetch and ensure, parsed into globals (arrays are avoided: bash 3.2 and set -u).
# CI_MODELS_O_* hold the values; the callers reset them with ci_models_opts_reset.
ci_models_opts_reset() {
  CI_MODELS_O_CACHE=""; CI_MODELS_O_LOCK=""; CI_MODELS_O_EVENTS=""; CI_MODELS_O_ACCEPT=0
  CI_MODELS_O_LIMIT=""; CI_MODELS_O_OFFLINE=0; CI_MODELS_O_NOGATE=0; CI_MODELS_O_UNKNOWN=0
  CI_MODELS_O_ITEMS=""   # newline-separated "pack NAME" / "model REF" lines
}

# ci_models_fetch_ref <ref>: one reference through ci-stick or the allowed fallback. No gate here.
ci_models_fetch_ref() {
  local ref kind bin rc=0
  ref="$1"
  kind="$(ci_models_ref_kind "$ref")"
  if [ "$kind" = invalid ]; then
    ci_models_log "refusing '$1': not a model reference"
    return "$CI_MODELS_RC_REFUSED"
  fi
  [ "$kind" = hf ] || ref="$(ci_models_norm_ref "$ref")"
  ci_models_cache_resolve
  bin="$(ci_models_stick_bin)" || bin=""
  if [ "$kind" = hf ]; then
    if [ -z "$bin" ]; then
      ci_models_stick_not_installed
      ci_models_log "$ref is a Hugging Face model: it is only ever fetched by ci-stick (pinned commit, no gated repos, digest checked), never through 'ollama pull'"
      return "$CI_MODELS_RC_NO_STICK"
    fi
    ci_models_run_stick_fetch --model "$ref"
    return $?
  fi
  if [ -n "$bin" ] && ci_models_ollama_reads_store; then
    ci_models_run_stick_fetch --model "$ref"
    return $?
  fi
  # ci-stick absent, or Ollama does not read the cache it would fill: the daemon pulls into its own store.
  if ! command -v ollama >/dev/null 2>&1; then
    if [ -z "$bin" ]; then ci_models_stick_not_installed; fi
    ci_models_log "ollama is not installed either: cannot fetch $ref"
    return "$CI_MODELS_RC_NO_STICK"
  fi
  if [ -z "$bin" ]; then
    ci_models_log "ci-stick is not installed: using 'ollama pull $ref' (no lock, no digest pinning)"
  else
    ci_models_log "Ollama does not read the cache at $CI_MODELS_ROOT: using 'ollama pull $ref'"
  fi
  ollama pull "$ref" || rc=$?
  [ "$rc" -eq 0 ] || ci_models_log "ollama pull $ref failed (status $rc)"
  return "$rc"
}

# A bandwidth limit as ci-stick parses sizes (plain bytes, or a number with B, KB/MB/GB/TB, KiB/MiB/GiB/TiB; single
# letters are ambiguous and refused there), optionally with "/s".
ci_models_rate_valid() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?(B|[KkMmGgTt][Bb]|[KkMmGgTt][Ii][Bb])?(/s)?$ ]]; }
# The ci-stick flag that limits the bandwidth, if this ci-stick has one.
ci_models_rate_flag() {
  local f
  for f in --max-bytes-per-sec --limit-rate; do
    if ci_models_stick_has_flag fetch "$f"; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}
# Where the image's (or the repository's) lock is looked for, one path per line. CI_OS_MODEL_LOCK_SEARCH (space
# separated) replaces the list: for a relocated image, and for tests.
ci_models_lock_candidates() {
  local f
  if [ -n "${CI_OS_MODEL_LOCK_SEARCH:-}" ]; then
    # shellcheck disable=SC2086  # a space-separated list on purpose
    for f in $CI_OS_MODEL_LOCK_SEARCH; do printf '%s\n' "$f"; done
  else
    printf '%s\n' /usr/share/ci-os/model-packs.lock.json "$CI_MODELS_LIBDIR/../manifest/model-packs.lock.json"
  fi
}
# The lock to hand to ci-stick when the caller gave none (see the header).
ci_models_default_lock() {
  local f
  if [ -n "${CI_OS_MODEL_LOCK_FILE:-}" ] && [ -f "$CI_OS_MODEL_LOCK_FILE" ]; then printf '%s\n' "$CI_OS_MODEL_LOCK_FILE"; return 0; fi
  while IFS= read -r f; do
    if [ -n "$f" ] && [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done < <(ci_models_lock_candidates)
  return 1
}

# ci_models_run_stick_fetch (--pack NAME | --model REF): builds the ci-stick command from CI_MODELS_O_* and runs it.
ci_models_run_stick_fetch() {
  local args=() rate flag lock
  args+=(fetch "$1" "$2")
  ci_models_cache_resolve
  if [ -d "$CI_MODELS_ROOT" ] && [ ! -w "$CI_MODELS_ROOT" ]; then
    ci_models_log "the cache at $CI_MODELS_ROOT is not writable by this user (the CI-CACHE volume is mounted for the 'ollama' user only: run this as root or as ollama)"
    return "$CI_MODELS_RC_NO_CACHE"
  fi
  args+=(--cache "$CI_MODELS_ROOT")
  lock="$CI_MODELS_O_LOCK"
  [ -n "$lock" ] || lock="$(ci_models_default_lock)" || lock=""
  [ -z "$lock" ] || args+=(--lock "$lock")
  [ -z "$CI_MODELS_O_EVENTS" ] || args+=(--events "$CI_MODELS_O_EVENTS")
  [ "$CI_MODELS_O_ACCEPT" != 1 ] || args+=(--accept-licenses)
  [ "$CI_MODELS_O_OFFLINE" != 1 ] || args+=(--offline)
  rate="$CI_MODELS_O_LIMIT"
  if [ -n "$rate" ] && [ "$rate" != 0 ]; then
    if ! ci_models_rate_valid "$rate"; then
      ci_models_log "'$rate' is not a rate (use 5MiB/s, 500KB or a number of bytes)"
      return "$CI_MODELS_RC_REFUSED"
    fi
    flag="$(ci_models_rate_flag)" || flag=""
    if [ -z "$flag" ]; then
      ci_models_log "this ci-stick has no bandwidth limit option: refusing to run without the limit that was asked for"
      return "$CI_MODELS_RC_REFUSED"
    fi
    args+=("$flag" "${rate%/s}")
  fi
  ci_models_stick_call "${args[@]}"
}

#--- the hardware gate --------------------------------------------------------------------------------------------
# ci_models_gate <ref>: 0 go ahead, 1 does not fit (CI_MODELS_O_NOGATE=1 skips the check), 2 nothing known about it.
ci_models_gate() {
  local rc=0
  [ "$CI_MODELS_O_NOGATE" != 1 ] || { CI_MODEL_GATE_REASON="gate disabled"; return 0; }
  if ! declare -F ci_os_model_fits >/dev/null 2>&1; then
    CI_MODEL_GATE_REASON="gpu-detect.sh (the hardware gate) was not found"
    return 2
  fi
  ci_os_model_fits "$1" || rc=$?
  # shellcheck disable=SC2034  # read by the callers
  CI_MODEL_GATE_REASON="${CI_OS_MODEL_FIT_REASON:-}"
  return "$rc"
}

# ci_models_ensure_list <newline-separated refs>: ci_models_ensure_refs without word splitting accidents
# (no globbing, no splitting on anything but the newline).
ci_models_ensure_list() {
  local had_f=0 rc=0 oldifs="$IFS"
  case $- in *f*) had_f=1 ;; esac
  set -f
  IFS=$'\n'
  # shellcheck disable=SC2086  # splitting on newlines is the point; globbing is off
  set -- $1
  IFS="$oldifs"              # restored before anything is called: IFS is dynamically scoped, and the gate splits words
  [ "$had_f" = 1 ] || set +f
  ci_models_ensure_refs "$@" || rc=$?
  return "$rc"
}

# ci_models_ensure_refs <ref>...: gate, then fetch each. Models that do not fit are skipped (not a failure);
# a model nothing is known about is skipped unless --allow-unknown. Returns the first failing status.
ci_models_ensure_refs() {
  local ref grc rc worst=0 done_n=0 skip_n=0 unfit_n=0 unknown_n=0
  for ref in "$@"; do
    if [ "$(ci_models_ref_kind "$ref")" = ollama ]; then ref="$(ci_models_norm_ref "$ref")"; fi
    if [ "$(ci_models_ref_kind "$ref")" = invalid ]; then
      ci_models_log "refusing '$ref': not a model reference"
      [ "$worst" -ne 0 ] || worst="$CI_MODELS_RC_REFUSED"
      continue
    fi
    grc=0
    ci_models_gate "$ref" || grc=$?
    case "$grc" in
      0) ;;
      1) ci_models_log "skipping $ref: $CI_MODEL_GATE_REASON"; skip_n=$((skip_n + 1)); unfit_n=$((unfit_n + 1)); continue ;;
      *)
        if [ "$CI_MODELS_O_UNKNOWN" != 1 ]; then
          ci_models_log "skipping $ref: $CI_MODEL_GATE_REASON (--allow-unknown downloads it anyway)"
          skip_n=$((skip_n + 1)); unknown_n=$((unknown_n + 1)); continue
        fi
        ;;
    esac
    rc=0
    ci_models_fetch_ref "$ref" || rc=$?
    if [ "$rc" -eq 0 ]; then
      done_n=$((done_n + 1))
    else
      [ "$worst" -ne 0 ] || worst="$rc"
      case "$rc" in 4|6|7) break ;; esac     # a full disk, an interrupt or a bad digest: stop, do not go on
    fi
  done
  ci_models_log "ensure: $done_n fetched or present, $skip_n skipped, status $worst"
  # Nothing was fetched and something was left out: say why with a status, 11 when the machine cannot run it,
  # 12 when nothing is known about it (--allow-unknown).
  if [ "$worst" -eq 0 ] && [ "$done_n" -eq 0 ]; then
    if [ "$unfit_n" -gt 0 ]; then return "$CI_MODELS_RC_UNFIT"; fi
    if [ "$unknown_n" -gt 0 ]; then return "$CI_MODELS_RC_REFUSED"; fi
  fi
  return "$worst"
}

#--- hugging face view --------------------------------------------------------------------------------------------
CI_MODELS_JSON_AWK=''
IFS= read -r -d '' CI_MODELS_JSON_AWK <<'AWKEOF' || true
function skipws() {
  while (pos <= n) {
    c = substr(buf, pos, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++
    else break
  }
}
function hexval(h,   i, v, d) {
  v = 0
  for (i = 1; i <= length(h); i++) {
    d = index("0123456789abcdef", tolower(substr(h, i, 1)))
    if (d == 0) return -1
    v = v * 16 + d - 1
  }
  return v
}
function readstr(   out, chunk, m, e, h, cp) {
  pos++
  out = ""
  while (pos <= n) {
    chunk = substr(buf, pos, 4096)
    m = match(chunk, /["\\]/)
    if (m == 0) { out = out chunk; pos += length(chunk); continue }
    out = out substr(chunk, 1, m - 1); pos += m - 1
    c = substr(buf, pos, 1)
    if (c == "\"") { pos++; break }
    e = substr(buf, pos + 1, 1); pos += 2
    if (e == "\"" || e == "\\" || e == "/") out = out e
    else if (e == "u") {
      h = substr(buf, pos, 4); pos += 4
      cp = hexval(h)
      if (cp >= 32 && cp < 127) out = out sprintf("%c", cp)
      else out = out "\001"
    } else out = out "\001"
  }
  if (length(out) > 2048) out = "\001"
  return out
}
function bad(s,   i, ch) {
  if (s == "") return 1
  for (i = 1; i <= length(s); i++) {
    ch = substr(s, i, 1)
    if (ch < " " || ch == "\177") return 1
  }
  return 0
}
function okfile(f,   rest, comp) {
  if (bad(f) || length(f) > 1024 || substr(f, 1, 1) == "/" || index(f, "\\") > 0) return 0
  rest = f
  while (1) {
    comp = rest; sub(/\/.*$/, "", comp)
    if (comp == "" || comp == "." || comp == "..") return 0
    if (index(rest, "/") == 0) break
    rest = substr(rest, index(rest, "/") + 1)
  }
  return 1
}
function evaluate(id,   r, rev, f, h) {
  r = val[id, "repo"]
  rev = val[id, "revision"]; if (rev == "") rev = val[id, "commit"]
  f = val[id, "file"]; if (f == "") f = val[id, "path"]; if (f == "") f = val[id, "filename"]
  h = val[id, "sha256"]; sub(/^sha256:/, "", h)
  if (r == "" || rev == "" || f == "" || h == "") return
  if (bad(r) || r !~ /^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/ || index(r, "--") > 0) { print "refused repo " r > "/dev/stderr"; return }
  if (length(rev) != 40 || rev !~ /^[0-9a-f]+$/) { print "refused revision of " r > "/dev/stderr"; return }
  if (length(h) != 64 || h !~ /^[0-9a-f]+$/) { print "refused sha256 of " r > "/dev/stderr"; return }
  if (!okfile(f)) { print "refused file name in " r > "/dev/stderr"; return }
  print r "\t" rev "\t" f "\t" h
}
{ buf = buf $0 "\n" }
END {
  n = length(buf); pos = 1; depth = 0; nobj = 0
  while (1) {
    skipws()
    if (pos > n) break
    c = substr(buf, pos, 1)
    if (c == "{") { depth++; kind[depth] = "O"; oid[depth] = ++nobj; wantkey[depth] = 1; pos++ }
    else if (c == "[") { depth++; kind[depth] = "A"; pos++ }
    else if (c == "}") { if (depth > 0 && kind[depth] == "O") evaluate(oid[depth]); depth--; pos++ }
    else if (c == "]") { depth--; pos++ }
    else if (c == ",") { if (depth > 0 && kind[depth] == "O") wantkey[depth] = 1; pos++ }
    else if (c == ":") { pos++ }
    else if (c == "\"") {
      s = readstr()
      if (depth > 0 && kind[depth] == "O") {
        if (wantkey[depth]) { curkey[depth] = s; wantkey[depth] = 0 }
        else val[oid[depth], curkey[depth]] = s
      }
    } else {
      m = match(substr(buf, pos, 64), /^[-+0-9.eEa-z]+/)
      if (m == 0) pos++; else pos += RLENGTH
    }
  }
}
AWKEOF

# ci_models_lock_hf_spec <lock.json>: repo<TAB>revision<TAB>file<TAB>sha256 for every object of the lock that
# names a Hugging Face file (the four keys side by side, wherever the lock nests them). Reads any layout of
# the JSON (pretty or compact); entries with an unsafe name are reported on stderr and left out.
ci_models_lock_hf_spec() {
  LC_ALL=C awk "$CI_MODELS_JSON_AWK" "$1"
}

ci_models_valid_repo() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *--* ]]; }
ci_models_valid_rev() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
ci_models_valid_sha() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
# A file name below a snapshot: no control characters (newline, tab...), no backslash, not absolute, no empty,
# "." or ".." component, at most 1024 bytes. Spaces, quotes, "$", leading dashes... are fine: nothing here
# is ever evaluated or word-split, and every path handed to a command is absolute.
ci_models_valid_relpath() {
  local p="$1" rest c
  [ -n "$p" ] && [ "${#p}" -le 1024 ] || return 1
  case "$p" in
    /*|*\\*) return 1 ;;
    *[[:cntrl:]]*) return 1 ;;
  esac
  rest="$p"
  while :; do
    c="${rest%%/*}"
    case "$c" in ''|.|..) return 1 ;; esac
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) break ;;
    esac
  done
  return 0
}

# ci_models_view_mkdir <base> <relative dir>: create the components below <base> one by one; fail if one of
# them is a symlink or a file (mkdir -p would follow a link planted in the way). mkdir comes first and the
# checks after: a check-then-create sequence loses against a second builder creating the same directory.
ci_models_view_mkdir() {
  local cur="$1" rel="$2" part
  while [ -n "$rel" ]; do
    part="${rel%%/*}"
    case "$rel" in
      */*) rel="${rel#*/}" ;;
      *) rel="" ;;
    esac
    cur="$cur/$part"
    if [ -L "$cur" ]; then return 1; fi
    mkdir -- "$cur" 2>/dev/null || true
    if [ -L "$cur" ] || [ ! -d "$cur" ]; then return 1; fi
  done
  return 0
}

# ci_models_view_build <store> <xdir> <view root> <spec file> [prune 1|0]
# Builds <view>/hub in the Hugging Face cache layout out of symlinks to the blobs of the store. Idempotent: a
# second run with the same input changes nothing (the summary says so). It only ever creates, replaces or
# removes symlinks that point into <store> or <xdir>; a real file in the way, a link pointing elsewhere, a
# symlinked directory in the path, a blob that is itself a symlink: refused and counted, never touched.
# Prints one summary line on stdout (counters: ok created replaced kept missing refused pruned).
# shellcheck disable=SC2034  # CI_MODELS_VIEW_* are the results for the callers
ci_models_view_build() {
  local store="${1%/}" xdir="${2%/}" view="${3%/}" spec="$4" prune="${5:-1}"
  local hub="$view/hub" repo rev file sha blob org nm mdir snap link sub cur p d found tmp desired wanted_repos=""
  local n_new=0 n_repl=0 n_keep=0 n_missing=0 n_refused=0 n_pruned=0
  [ -n "$store" ] && [ -n "$view" ] || return 1
  [ -n "$xdir" ] || xdir="$store/.no-second-store"     # an empty second store must not turn "$xdir"/* into /*, which matches every link
  desired="$(mktemp "${TMPDIR:-/tmp}/ci-models-view.XXXXXX")" || return 1
  if [ -L "$view" ] || [ -L "$hub" ]; then
    ci_models_log "view: $view is a symlink: refusing to build in it"
    rm -f -- "$desired"; return 1
  fi
  mkdir -p -- "$hub" 2>/dev/null || { ci_models_log "view: cannot create $hub"; rm -f -- "$desired"; return 1; }
  chmod 0755 "$view" "$hub" 2>/dev/null || true

  while IFS=$'\t' read -r repo rev file sha || [ -n "$repo" ]; do
    [ -n "$repo" ] || continue
    if ! ci_models_valid_repo "$repo" || ! ci_models_valid_rev "$rev" || ! ci_models_valid_sha "$sha" \
       || ! ci_models_valid_relpath "$file"; then
      ci_models_log "view: refusing an entry for '$repo' (unsafe repository, revision, digest or file name)"
      n_refused=$((n_refused + 1)); continue
    fi
    blob="$store/blobs/sha256-$sha"
    if [ ! -e "$blob" ] && [ -n "$xdir" ]; then
      d="${sha%"${sha#??}"}"
      blob="$xdir/blobs/$d/$sha"
    fi
    if [ -L "$blob" ]; then
      ci_models_log "view: refusing $sha: the blob is a symlink"
      n_refused=$((n_refused + 1)); continue
    fi
    if [ ! -f "$blob" ]; then
      n_missing=$((n_missing + 1)); continue
    fi
    org="${repo%%/*}"; nm="${repo#*/}"
    mdir="$hub/models--$org--$nm"
    snap="$mdir/snapshots/$rev"
    link="$snap/$file"
    sub=""
    case "$file" in */*) sub="${file%/*}" ;; esac
    if ! ci_models_view_mkdir "$hub" "models--$org--$nm/refs" \
       || ! ci_models_view_mkdir "$hub" "models--$org--$nm/snapshots/$rev${sub:+/$sub}"; then
      ci_models_log "view: refusing $repo/$file: a symlink or file is in the way of the directory"
      n_refused=$((n_refused + 1)); continue
    fi
    # refs/main: a regular file holding the commit (llama.cpp and huggingface_hub read exactly this)
    if [ -L "$mdir/refs/main" ] || { [ -e "$mdir/refs/main" ] && [ ! -f "$mdir/refs/main" ]; }; then
      ci_models_log "view: refusing $repo: refs/main is not a regular file"
      n_refused=$((n_refused + 1)); continue
    fi
    wanted_repos="$wanted_repos
models--$org--$nm"
    if [ "$(cat "$mdir/refs/main" 2>/dev/null)" != "$rev" ]; then
      tmp="$(mktemp "$mdir/refs/.main.XXXXXX" 2>/dev/null)" || tmp=""
      { [ -n "$tmp" ] && printf '%s\n' "$rev" > "$tmp" && chmod 0644 "$tmp" && mv -f -- "$tmp" "$mdir/refs/main"; } 2>/dev/null \
        || { [ -z "$tmp" ] || rm -f -- "$tmp"; ci_models_log "view: cannot write refs/main of $repo"; n_refused=$((n_refused + 1)); continue; }
    fi
    # The link. Look first: `ln -s TARGET LINK` where LINK is a symlink to a directory would create the new link
    # INSIDE that directory, so an existing link is never handed to ln. A second builder may create the link between
    # the checks and our ln; ln then fails, and what is there is looked at again (the same link is fine).
    if [ -L "$link" ]; then
      cur="$(readlink "$link")"
      if [ "$cur" = "$blob" ]; then
        n_keep=$((n_keep + 1))
      else
        case "$cur" in
          "$store"/*|"$xdir"/*)
            rm -f -- "$link" && ln -s -- "$blob" "$link" && n_repl=$((n_repl + 1)) \
              || { n_refused=$((n_refused + 1)); continue; }
            ;;
          *)
            ci_models_log "view: refusing $repo/$file: it is a link to somewhere else ($cur)"
            n_refused=$((n_refused + 1)); continue
            ;;
        esac
      fi
    elif [ -e "$link" ] && [ ! -L "$link" ]; then
      ci_models_log "view: refusing $repo/$file: a real file or directory is in the way"
      n_refused=$((n_refused + 1)); continue
    elif ln -s -- "$blob" "$link" 2>/dev/null; then
      n_new=$((n_new + 1))
    elif [ -L "$link" ] && [ "$(readlink "$link")" = "$blob" ]; then
      n_keep=$((n_keep + 1))
    else
      ci_models_log "view: cannot link $link"
      n_refused=$((n_refused + 1)); continue
    fi
    printf '%s\0' "$link" >> "$desired"
  done < "$spec"

  if [ "$prune" = 1 ]; then
    while IFS= read -r -d '' p; do
      cur="$(readlink "$p")"
      case "$cur" in
        "$store"/*|"$xdir"/*) ;;
        *) continue ;;                               # not ours: never touched
      esac
      found=0
      while IFS= read -r -d '' d; do
        if [ "$d" = "$p" ]; then found=1; break; fi
      done < "$desired"
      if [ "$found" = 0 ]; then
        rm -f -- "$p" && n_pruned=$((n_pruned + 1))
      fi
    done < <(find "$hub" -type l -print0 2>/dev/null)
    # a repository with no snapshot link left keeps nothing but its refs/main: remove both, then empty directories
    for mdir in "$hub"/models--*; do
      [ -d "$mdir" ] && [ ! -L "$mdir" ] || continue
      case "$wanted_repos
" in
        *"
${mdir##*/}
"*) continue ;;                                   # in this build's input: its directories are in use, even if still empty
      esac
      if [ -z "$(find "$mdir/snapshots" -type l 2>/dev/null | sed -n 1p)" ]; then
        if [ -f "$mdir/refs/main" ] && [ ! -L "$mdir/refs/main" ]; then rm -f -- "$mdir/refs/main"; fi
        find "$mdir" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true     # one by one: a parent is empty only after its children went
      fi
    done
  fi
  rm -f -- "$desired"
  CI_MODELS_VIEW_CHANGED=$((n_new + n_repl + n_pruned))
  CI_MODELS_VIEW_REFUSED=$n_refused
  printf 'view: %s linked (%s created, %s replaced, %s unchanged), %s pruned, %s blobs not in the cache, %s refused\n' \
    "$((n_new + n_repl + n_keep))" "$n_new" "$n_repl" "$n_keep" "$n_pruned" "$n_missing" "$n_refused"
  return 0
}

# ci_models_cmd_view [--cache DIR] [--out DIR] [--lock FILE]... [--spec FILE] [--quiet] [--no-prune] [--strict]
ci_models_cmd_view() {
  local out="" spec="" quiet=0 prune=1 strict=0 locks="" f tmp rc=0 line
  CI_MODELS_O_CACHE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cache) CI_MODELS_O_CACHE="${2:-}"; shift 2 || break ;;
      --out) out="${2:-}"; shift 2 || break ;;
      --lock) locks="$locks${locks:+$'\n'}${2:-}"; shift 2 || break ;;
      --spec) spec="${2:-}"; shift 2 || break ;;
      --quiet) quiet=1; shift ;;
      --no-prune) prune=0; shift ;;
      --strict) strict=1; shift ;;
      *) ci_models_log "view: unknown option '$1'"; return 2 ;;
    esac
  done
  [ -z "$CI_MODELS_O_CACHE" ] || CI_OS_MODELS_CACHE="$CI_MODELS_O_CACHE"
  ci_models_cache_resolve
  [ -n "$out" ] || out="$(ci_models_view_dir)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/ci-models-spec.XXXXXX")" || return 1
  if [ -n "$spec" ]; then
    [ -r "$spec" ] || { ci_models_log "view: cannot read $spec"; rm -f -- "$tmp"; return 2; }
    cat -- "$spec" > "$tmp"
  else
    if [ -z "$locks" ]; then
      # The image's lock first. A lock that lives on the (removable) cache volume is the least trusted one and is used
      # only when there is no other: whoever can write the volume can write it.
      locks="$(ci_models_default_lock)" || locks=""
      if [ -z "$locks" ]; then
        for f in "$CI_MODELS_XDIR"/locks/*.json; do
          [ -f "$f" ] && locks="$locks${locks:+$'\n'}$f"
        done
      fi
    fi
    if [ -z "$locks" ]; then
      [ "$quiet" = 1 ] || ci_models_log "view: no lock file found (looked in $CI_MODELS_XDIR/locks, /usr/share/ci-os): nothing to link"
      rm -f -- "$tmp"
      return 0
    fi
    while IFS= read -r f; do
      [ -r "$f" ] || { ci_models_log "view: cannot read lock $f"; continue; }
      ci_models_lock_hf_spec "$f" >> "$tmp" || true
    done <<EOF
$locks
EOF
    LC_ALL=C awk '!seen[$0]++' "$tmp" > "$tmp.u" && mv -f -- "$tmp.u" "$tmp"
  fi
  line="$(ci_models_view_build "$CI_MODELS_STORE" "$CI_MODELS_XDIR" "$out" "$tmp" "$prune")" || rc=$?
  rm -f -- "$tmp" "$tmp.u"
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  if [ "$quiet" = 0 ] || [ "$CI_MODELS_VIEW_CHANGED" -gt 0 ] || [ "$CI_MODELS_VIEW_REFUSED" -gt 0 ]; then
    printf '%s\n' "$line"
  fi
  if [ "$strict" = 1 ] && [ "$CI_MODELS_VIEW_REFUSED" -gt 0 ]; then return 1; fi
  return 0
}

#--- background prefetch ------------------------------------------------------------------------------------------
# A live session: the boot medium is mounted at /cdrom (casper), or boot=casper is on the command line.
ci_models_live_session() {
  [ -e "${CI_OS_CDROM_MARKER:-/cdrom/casper/vmlinuz}" ] && return 0
  case " $(cat "${CI_OS_CMDLINE_FILE:-/proc/cmdline}" 2>/dev/null) " in
    *" boot=casper "*) return 0 ;;
  esac
  return 1
}

# Is the persistence volume (ext4 label 'writable', legacy 'casper-rw' = CI-PERSIST) really the live root's upper
# layer? Same test as ci-os-live-container-storage: 'persistent' on the command line, the label exists, it is
# ext4 and casper mounted it (a /sys/fs/ext4/<dev> entry). Anything else means "/" is RAM.
ci_models_persistence_in_use() {
  local cmd lbl dev bylabel="${CI_OS_DISK_BY_LABEL:-/dev/disk/by-label}"
  cmd=" $(cat "${CI_OS_CMDLINE_FILE:-/proc/cmdline}" 2>/dev/null) "
  case "$cmd" in *" nopersistent "*) return 1 ;; esac
  case "$cmd" in *" persistent "*) ;; *) return 1 ;; esac
  for lbl in writable casper-rw; do
    [ -e "$bylabel/$lbl" ] || continue
    dev="$(readlink -f "$bylabel/$lbl" 2>/dev/null)"
    [ -n "$dev" ] || continue
    [ "$(blkid -o value -s TYPE "$dev" 2>/dev/null)" = ext4 ] || return 1
    [ -d "${CI_OS_SYS_EXT4:-/sys/fs/ext4}/$(basename "$dev")" ] && return 0
    return 1
  done
  return 1
}

ci_models_skip() { ci_models_log "prefetch skipped: $*"; return 1; }

# ci_models_prefetch_check: exit 0 = go, 1 = skip, with one line saying why on stderr. This is the unit's
# ExecCondition=, so a skip is "condition not met" in the journal, not a failure.
ci_models_prefetch_check() {
  local flag="${CI_OS_PREFETCH_FLAG:-/etc/ci-os/models-prefetch}" pack rate fstype state assume
  [ -e "$flag" ] || ci_models_skip "opt-in flag file $flag does not exist" || return 1
  if ci_models_live_session; then
    ci_models_persistence_in_use || ci_models_skip "live session without a persistence volume in use (the flag would live in RAM)" || return 1
  fi
  pack="$(ci_models_conf_get pack '')"
  [[ "$pack" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || ci_models_skip "no pack named in ${CI_OS_MODELS_CONF:-/etc/ci-os/models.conf} (pack=NAME)" || return 1
  ci_models_stick_bin >/dev/null || ci_models_skip "ci-stick is not installed" || return 1
  ci_models_cache_resolve
  case "$CI_MODELS_KIND" in
    stick|override) ;;
    *) ci_models_skip "no cache volume is mounted (a background download needs the stick's CI-CACHE)" || return 1 ;;
  esac
  [ -d "$CI_MODELS_ROOT" ] && [ -w "$CI_MODELS_ROOT" ] || ci_models_skip "the cache at $CI_MODELS_ROOT is not writable by $(id -un 2>/dev/null || echo this user)" || return 1
  fstype="$(findmnt -ln -T "$CI_MODELS_ROOT" -o FSTYPE 2>/dev/null | sed -n 1p)"
  case "$fstype" in
    ''|tmpfs|ramfs|overlay|overlayfs|aufs|squashfs|iso9660|fuse.overlayfs) ci_models_skip "the cache is on '${fstype:-an unknown filesystem}', which may be RAM" || return 1 ;;
  esac
  rate="$(ci_models_conf_get limit_rate 5MiB/s)"
  [ "$rate" = 0 ] || ci_models_rate_valid "$rate" || ci_models_skip "limit_rate '$rate' is not a rate such as 5MiB/s" || return 1
  if [ "$rate" != 0 ] && ! ci_models_rate_flag >/dev/null; then
    ci_models_skip "this ci-stick has no bandwidth limit option, and an unthrottled background download is not allowed" || return 1
  fi
  state="$(ci_models_network_state)"
  assume="$(ci_models_conf_get assume_unmetered 0)"
  case "$state" in
    unmetered) ;;
    unknown) [ "$assume" = 1 ] || ci_models_skip "the network's metered state is unknown (assume_unmetered=1 in models.conf allows it)" || return 1 ;;
    *) ci_models_skip "network state is '$state' (needs an unmetered uplink and no setup access point)" || return 1 ;;
  esac
  return 0
}

# ci_models_cmd_prefetch: the unit's ExecStart. Fill the configured pack with the models this machine can run.
# 3 drift, 4 no space and 5 licence are "nothing more to do until a person acts": status 0, said in the journal.
ci_models_cmd_prefetch() {
  local pack rc=0 refs
  pack="$(ci_models_conf_get pack '')"
  [[ "$pack" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { ci_models_log "prefetch: no pack configured"; return 2; }
  ci_models_opts_reset
  CI_MODELS_O_LIMIT="$(ci_models_conf_get limit_rate 5MiB/s)"
  CI_MODELS_O_ACCEPT="$(ci_models_conf_get accept_licenses 0)"
  [ "$CI_MODELS_O_ACCEPT" = 1 ] || CI_MODELS_O_ACCEPT=0
  CI_MODELS_O_EVENTS="${CI_OS_MODELS_EVENTS:-}"
  refs="$(ci_models_pack_refs "$pack")" || refs=""
  if [ -z "$refs" ]; then
    ci_models_log "prefetch: pack '$pack' not found in model-packs.yaml"
    return 2
  fi
  ci_models_ensure_list "$refs" || rc=$?
  case "$rc" in
    3|4|5) ci_models_log "prefetch: stopped with status $rc and will not retry by itself until the cause is dealt with"; return 0 ;;
    "$CI_MODELS_RC_UNFIT") ci_models_log "prefetch: nothing in pack '$pack' fits this machine"; return 0 ;;
  esac
  return "$rc"
}

#--- commands -----------------------------------------------------------------------------------------------------
ci_models_usage() {
  cat <<'EOF'
usage: ci-os-models <command> [options]

  cache [--root|--store|--kind|--view]   where the cache is (CI-CACHE volume, else /var/lib/ci-os)
  env [--format sh|systemd|raw] [--user] consumer environment (OLLAMA_MODELS, HF_HUB_CACHE, LLAMA_CACHE, ...)
  view [--cache D] [--out D] [--lock F] [--quiet]   build the Hugging Face cache view (symlinks)
  fits REF... | --pack NAME              does this machine have the memory for it? (status 0 yes, 1 no, 2 unknown)
  plan --pack NAME [--lock F] [--json]   ci-stick models plan, status codes explained
  fetch (--pack NAME | --model REF)... [--lock F] [--events F] [--accept-licenses] [--limit-rate R] [--offline]
                                         ci-stick models fetch; without ci-stick: ollama pull for Ollama refs only
  ensure [--allow-unknown] [--no-gate] [--accept-licenses] REF... | --pack NAME
                                         fetch what fits this machine
  info                                   cache location, ci-stick, and 'ci-stick models cache-info'
  prefetch-check | prefetch              the background prefetch unit's condition and job (opt-in)

status: ci-stick's (0 ok 1 error 2 usage 3 drift 4 no space 5 licence 6 interrupted 7 integrity) or
10 ci-stick not installed, 11 does not fit, 12 reference refused, 13 no usable cache.
EOF
}

ci_models_cmd_cache() {
  ci_models_cache_resolve
  case "${1:-}" in
    --root) printf '%s\n' "$CI_MODELS_ROOT" ;;
    --store) printf '%s\n' "$CI_MODELS_STORE" ;;
    --kind) printf '%s\n' "$CI_MODELS_KIND" ;;
    --view) ci_models_view_dir ;;
    '')
      printf 'root:  %s\nstore: %s\nextra: %s\nkind:  %s\nview:  %s\n' "$CI_MODELS_ROOT" "$CI_MODELS_STORE" "$CI_MODELS_XDIR" \
        "$CI_MODELS_KIND" "$(ci_models_view_dir)"
      [ -z "$CI_MODELS_NOTE" ] || printf 'note:  %s\n' "$CI_MODELS_NOTE"
      ;;
    *) ci_models_log "cache: unknown option '$1'"; return 2 ;;
  esac
}

ci_models_cmd_fits() {
  local refs="" pack="" ref rc=0 worst=0 verdict
  while [ $# -gt 0 ]; do
    case "$1" in
      --pack) pack="${2:-}"; shift 2 || break ;;
      -*) ci_models_log "fits: unknown option '$1'"; return 2 ;;
      *) refs="$refs${refs:+$'\n'}$1"; shift ;;
    esac
  done
  if [ -n "$pack" ]; then
    refs="$(ci_models_pack_refs "$pack")" || refs=""
    [ -n "$refs" ] || { ci_models_log "fits: pack '$pack' not found"; return 2; }
  fi
  [ -n "$refs" ] || { ci_models_log "fits: no model given"; return 2; }
  CI_MODELS_O_NOGATE=0
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    rc=0; ci_models_gate "$ref" || rc=$?
    case "$rc" in 0) verdict=fits ;; 1) verdict=no ;; *) verdict=unknown ;; esac
    printf '%s\t%s\t%s\n' "$ref" "$verdict" "$CI_MODEL_GATE_REASON"
    case "$rc" in
      1) worst=1 ;;
      0) ;;
      *) [ "$worst" -ne 0 ] || worst=2 ;;
    esac
  done <<EOF
$refs
EOF
  return "$worst"
}

ci_models_cmd_plan() {
  local args=() pack="" lock="" json=0 accept=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --pack) pack="${2:-}"; shift 2 || break ;;
      --lock) lock="${2:-}"; shift 2 || break ;;
      --cache) CI_OS_MODELS_CACHE="${2:-}"; shift 2 || break ;;
      --accept-licenses) accept=1; shift ;;
      --json) json=1; shift ;;
      *) ci_models_log "plan: unknown option '$1'"; return 2 ;;
    esac
  done
  [ -n "$pack" ] || { ci_models_log "plan: --pack NAME is required"; return 2; }
  if ! ci_models_stick_bin >/dev/null; then
    ci_models_stick_not_installed
    ci_models_log "without it there is no plan; 'ci-os-models fits --pack $pack' lists what this machine could run"
    return "$CI_MODELS_RC_NO_STICK"
  fi
  ci_models_cache_resolve
  args+=(plan --pack "$pack" --cache "$CI_MODELS_ROOT")
  [ -n "$lock" ] || lock="$(ci_models_default_lock)" || lock=""
  [ -z "$lock" ] || args+=(--lock "$lock")
  [ "$accept" != 1 ] || args+=(--accept-licenses)
  [ "$json" != 1 ] || args+=(--json)
  ci_models_stick_call "${args[@]}"
}

ci_models_cmd_fetch() {
  local item rc rr worst=0 kind name refs r
  ci_models_opts_reset
  while [ $# -gt 0 ]; do
    case "$1" in
      --pack|--model)
        if ci_models_has_newline "${2:-}"; then ci_models_log "fetch: a name with a newline in it is not accepted"; return 2; fi
        CI_MODELS_O_ITEMS="$CI_MODELS_O_ITEMS${CI_MODELS_O_ITEMS:+$'\n'}${1#--} ${2:-}"; shift 2 || break ;;
      --cache) CI_MODELS_O_CACHE="${2:-}"; CI_OS_MODELS_CACHE="${2:-}"; shift 2 || break ;;
      --lock) CI_MODELS_O_LOCK="${2:-}"; shift 2 || break ;;
      --events) CI_MODELS_O_EVENTS="${2:-}"; shift 2 || break ;;
      --limit-rate) CI_MODELS_O_LIMIT="${2:-}"; shift 2 || break ;;
      --offline) CI_MODELS_O_OFFLINE=1; shift ;;
      --accept-licenses) CI_MODELS_O_ACCEPT=1; shift ;;
      *) ci_models_log "fetch: unknown option '$1'"; return 2 ;;
    esac
  done
  [ -n "$CI_MODELS_O_ITEMS" ] || { ci_models_log "fetch: give --pack NAME or --model REF"; return 2; }
  while IFS= read -r item; do
    kind="${item%% *}"; name="${item#* }"
    rc=0
    case "$kind" in
      model) ci_models_fetch_ref "$name" || rc=$? ;;
      pack)
        [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { ci_models_log "fetch: '$name' is not a pack name"; rc=2; }
        if [ "$rc" -eq 0 ]; then
          if ci_models_stick_bin >/dev/null; then
            ci_models_run_stick_fetch --pack "$name" || rc=$?
          else
            # No ci-stick: expand the pack and pull the Ollama references; Hugging Face ones are refused, not pulled.
            refs="$(ci_models_pack_refs "$name")" || refs=""
            if [ -z "$refs" ]; then ci_models_log "fetch: pack '$name' not found in model-packs.yaml"; rc=2
            else
              while IFS= read -r r; do
                [ -n "$r" ] || continue
                rr=0
                ci_models_fetch_ref "$r" || rr=$?
                [ "$rc" -ne 0 ] || rc="$rr"
              done <<EOF
$refs
EOF
            fi
          fi
        fi
        ;;
    esac
    if [ "$rc" -ne 0 ]; then
      [ "$worst" -ne 0 ] || worst="$rc"
      case "$rc" in 4|6|7) break ;; esac
    fi
  done <<EOF
$CI_MODELS_O_ITEMS
EOF
  return "$worst"
}

ci_models_cmd_ensure() {
  local refs="" pack="" r
  ci_models_opts_reset
  while [ $# -gt 0 ]; do
    case "$1" in
      --pack) pack="${2:-}"; shift 2 || break ;;
      --cache) CI_MODELS_O_CACHE="${2:-}"; CI_OS_MODELS_CACHE="${2:-}"; shift 2 || break ;;
      --lock) CI_MODELS_O_LOCK="${2:-}"; shift 2 || break ;;
      --events) CI_MODELS_O_EVENTS="${2:-}"; shift 2 || break ;;
      --limit-rate) CI_MODELS_O_LIMIT="${2:-}"; shift 2 || break ;;
      --accept-licenses) CI_MODELS_O_ACCEPT=1; shift ;;
      --allow-unknown) CI_MODELS_O_UNKNOWN=1; shift ;;
      --no-gate) CI_MODELS_O_NOGATE=1; shift ;;
      -*) ci_models_log "ensure: unknown option '$1'"; return 2 ;;
      *)
        if ci_models_has_newline "$1"; then ci_models_log "ensure: a name with a newline in it is not accepted"; return 2; fi
        refs="$refs${refs:+$'\n'}$1"; shift ;;
    esac
  done
  if [ -n "$pack" ]; then
    [[ "$pack" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { ci_models_log "ensure: '$pack' is not a pack name"; return 2; }
    r="$(ci_models_pack_refs "$pack")" || r=""
    [ -n "$r" ] || { ci_models_log "ensure: pack '$pack' not found in model-packs.yaml"; return 2; }
    refs="$refs${refs:+$'\n'}$r"
  fi
  [ -n "$refs" ] || { ci_models_log "ensure: no model given"; return 2; }
  ci_models_ensure_list "$refs"
}

ci_models_cmd_info() {
  ci_models_cmd_cache
  local bin
  if bin="$(ci_models_stick_bin)"; then
    printf 'ci-stick: %s\n' "$bin"
    ci_models_stick_call cache-info --json --cache "$CI_MODELS_ROOT" || return $?
  else
    printf 'ci-stick: not installed\n'
  fi
  printf 'network: %s\n' "$(ci_models_network_state)"
}

ci_models_main() {
  local cmd="${1:-help}"
  [ $# -eq 0 ] || shift
  case "$cmd" in
    help|-h|--help) ci_models_usage ;;
    version|--version) printf 'ci-os-models %s\n' "$CI_MODELS_VERSION" ;;
    cache) ci_models_cmd_cache "$@" ;;
    env)
      local fmt=sh user=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --format) fmt="${2:-sh}"; shift 2 || break ;;
          --user) user="--user"; shift ;;
          *) ci_models_log "env: unknown option '$1'"; return 2 ;;
        esac
      done
      ci_models_env_print "$fmt" ${user:+"$user"}
      ;;
    view) ci_models_cmd_view "$@" ;;
    fits) ci_models_cmd_fits "$@" ;;
    plan) ci_models_cmd_plan "$@" ;;
    fetch) ci_models_cmd_fetch "$@" ;;
    ensure) ci_models_cmd_ensure "$@" ;;
    info) ci_models_cmd_info "$@" ;;
    prefetch-check) ci_models_prefetch_check ;;
    prefetch) ci_models_cmd_prefetch ;;
    *) ci_models_log "unknown command '$cmd' (try: ci-os-models help)"; return 2 ;;
  esac
}

ci_models_opts_reset        # defaults for the CI_MODELS_O_* option variables, so sourcing callers work under set -u

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  set -u
  ci_models_main "$@"
  exit $?
fi
