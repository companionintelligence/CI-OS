#!/usr/bin/env bash
# The CachyOS edition's ecosystem-provisioning entrypoint: a thin wrapper around backends/arch/provision/provision.sh, not a
# fork. CachyOS is Arch with its own repositories on top: the same pacman, the same package names, so the Arch script's
# tier gating and install functions apply unchanged (core/manifest/role-map/pacman.yaml is its data).
#
# What the wrapper adds is the one thing the Arch script cannot do when it is started by systemd instead of by a person with
# sudo: know who the desktop user is. provision.sh's detect_user() reads $SUDO_USER and, without it, falls back to the
# current user -- root, under a first-boot unit -- and would then install uv, asdf and Node into /root. So the wrapper scans
# /etc/passwd for the desktop user: the first account with UID 1000-59999, a real shell and an existing home that is not `ci`,
# `liveuser` or `nobody`. A SUDO_USER that is already set (a person ran `sudo`) is respected.
#
# Default tier. Started without --tier=, this passes --tier=core, as the Ubuntu first-boot service does -- NOT the Arch
# script's own default (core,hardware): the Arch hardware tier installs rocm-hip-sdk (several GB) and LACT unconditionally,
# whatever GPU the machine has (install_rocm_driver_arch() and install_lact() do no hardware detection). Ask for it
# explicitly on a machine that needs it: sudo ci-os-setup --tier=core,hardware.
#
# The Ollama models are checked here, not trusted to the Arch script. pull_ollama_models() ends in `|| log_warning` after a heredoc
# whose status is that of its LAST command, so a failed pull of nomic-embed-text or gemma3:1b is not even reported, and a failed
# pull of the last model only logs a warning: the Arch script then prints "Setup completed successfully!" and exits 0 with no model
# on the machine. When the run asked for the core tier (the one that pulls) and the Arch script succeeded, the wrapper therefore
# reads the required models from core/manifest/ecosystem.yaml (llm.models), waits for the Ollama server to answer, and compares them
# with `ollama list`. Any model missing: exit 74. backends/arch/** stays untouched (decision D8).
#
# HOME. A system unit without User= has no $HOME (systemd sets it only for a unit that names a user), and the ollama CLI panics without
# one ("panic: $HOME is not defined", exit 2) even when it only talks to the server. The first-boot run of ISO #4 read that panic as
# "the server never answered", treated all three installed models as missing and ended "degraded" (exit 74) every time. The unit
# now sets HOME=/root, and this wrapper makes sure of it too (a person who runs `sudo -E` from a stripped environment, a test, or a
# unit written by someone else). The Arch script's own ollama calls all run as `sudo -u "$ACTUAL_USER" bash`, and sudo sets HOME to
# that user's home there (verified on Arch's sudo 1.9 with env_reset: HOME=/home/<user> although root's HOME was unset), so they need no
# help; the only ollama call made as root is the check below.
#
# Exit status: the Arch script's, unless it succeeded and a required model is missing: 74 ("degraded": everything else is installed,
# and first-boot-setup.sh does not write its done marker, so the timer retries and only the missing models are pulled again);
# 75 (EX_TEMPFAIL) when no desktop user exists yet and nobody ran sudo, so the first-boot driver retries later instead of
# provisioning root.
#
# Environment (tests): CI_OS_PASSWD_FILE (default /etc/passwd), CI_OS_ARCH_PROVISION (default ../../arch/provision/provision.sh),
# CI_OS_ECOSYSTEM_MANIFEST (default ../../../core/manifest/ecosystem.yaml, which the installer stages next to this tree),
# CI_OS_OLLAMA_TRIES / CI_OS_OLLAMA_SLEEP (readiness poll: 30 x 2 s), CI_OS_FALLBACK_HOME (default /root: the HOME used when none is set).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH_PROVISION="${CI_OS_ARCH_PROVISION:-$SCRIPT_DIR/../../arch/provision/provision.sh}"
PASSWD_FILE="${CI_OS_PASSWD_FILE:-/etc/passwd}"
MANIFEST="${CI_OS_ECOSYSTEM_MANIFEST:-$SCRIPT_DIR/../../../core/manifest/ecosystem.yaml}"
OLLAMA_TRIES="${CI_OS_OLLAMA_TRIES:-30}"
OLLAMA_SLEEP="${CI_OS_OLLAMA_SLEEP:-2}"

# See "HOME" in the header: the ollama CLI refuses to start without one.
if [ -z "${HOME:-}" ]; then
  HOME="${CI_OS_FALLBACK_HOME:-/root}"
  export HOME
fi

detect_desktop_user() {
  local name uid home shell
  while IFS=: read -r name _ uid _ _ home shell; do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] || continue
    case "$name" in ci|liveuser|nobody) continue ;; esac
    case "$shell" in */nologin|*/false) continue ;; esac
    [ -d "$home" ] || continue
    printf '%s' "$name"
    return 0
  done < "$PASSWD_FILE"
  return 1
}

if [ -z "${SUDO_USER:-}" ]; then
  if user="$(detect_desktop_user)"; then
    SUDO_USER="$user"
    export SUDO_USER
    echo "[CI-OS] No SUDO_USER; provisioning for the first desktop account: $SUDO_USER"
  else
    echo "[CI-OS] No SUDO_USER and no desktop account in $PASSWD_FILE yet; not provisioning root. Will retry." >&2
    exit 75
  fi
fi

have_tier=0
for arg in "$@"; do
  case "$arg" in --tier=*|--light|--step=*) have_tier=1 ;; esac
done
if [ "$have_tier" -eq 0 ]; then
  set -- --tier=core "$@"
fi

# Does this run pull the Ollama models? The same reading of the arguments as the Arch script's (the last --tier= / --light wins; only
# --step=ci-hub skips the tiers), and the pull belongs to the core tier.
wants_models() {
  local arg tiers="core,hardware" step=""
  for arg in "$@"; do
    case "$arg" in --tier=*) tiers="${arg#--tier=}" ;; --step=*) step="${arg#--step=}" ;; --light) tiers="core" ;; esac
  done
  [ "$step" != ci-hub ] || return 1
  case ",$tiers," in *,core,*) return 0 ;; esac
  return 1
}

# llm.models of the manifest, one per line: `models: [a, "b"]` or a block list under `models:`.
llm_models() {
  awk '
    function emit(m) { gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", m); if (m != "") print m }
    /^llm:[[:space:]]*(#.*)?$/ { inllm = 1; next }
    inllm && /^[A-Za-z_]/ { inllm = 0 }
    !inllm { next }
    /^[[:space:]]+models:/ {
      line = $0; sub(/^[[:space:]]+models:[[:space:]]*/, "", line); sub(/[[:space:]]+#.*$/, "", line)
      if (line ~ /^\[/) {
        sub(/^\[/, "", line); sub(/\].*$/, "", line); n = split(line, a, ","); for (i = 1; i <= n; i++) emit(a[i])
        inblock = 0
      } else { inblock = 1 }
      next
    }
    inblock && /^[[:space:]]+-[[:space:]]+/ { line = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", line); sub(/[[:space:]]+#.*$/, "", line); emit(line); next }
    inblock && !/^[[:space:]]*(#.*)?$/ { inblock = 0 }
  ' "$MANIFEST"
}

# `ollama list`, bounded: a server that accepts the connection and never answers must not hang the first boot. Sets OLLAMA_LISTING
# (stdout) and OLLAMA_ERR (the first lines of stderr, one line) instead of printing them: a command substitution would lose the
# second one, and an error that is thrown away is how "the server did not answer" once hid a panic that had nothing to do with the
# server (see "HOME" in the header).
OLLAMA_LISTING=""
OLLAMA_ERR=""
ollama_list() {
  local errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/ci-os-ollama-list.XXXXXX" 2>/dev/null)" || errf=/dev/null
  if command -v timeout >/dev/null 2>&1; then OLLAMA_LISTING="$(timeout 30 ollama list 2>"$errf")" || rc=$?; else OLLAMA_LISTING="$(ollama list 2>"$errf")" || rc=$?; fi
  OLLAMA_ERR="$(sed -n '1,3p' "$errf" 2>/dev/null | cut -c1-200 | tr '\n' ' ' | sed 's/ *$//')"
  [ "$errf" = /dev/null ] || rm -f "$errf"
  [ "$rc" -ne 124 ] || OLLAMA_ERR="${OLLAMA_ERR:+$OLLAMA_ERR; }ollama list did not finish within 30 s"
  return "$rc"
}

# 0 when every llm.models entry is installed. A model name without a tag means ":latest", as for `ollama pull`.
check_models() {
  local want m listing="" have i=0 missing=""
  [ -r "$MANIFEST" ] || { echo "[CI-OS] Cannot check the Ollama models: $MANIFEST is not readable." >&2; return 2; }
  want="$(llm_models)"
  [ -n "$want" ] || { echo "[CI-OS] Cannot check the Ollama models: no llm.models list in $MANIFEST." >&2; return 2; }
  if ! command -v ollama >/dev/null 2>&1; then
    echo "[CI-OS] Ollama is not installed, so the models it should hold are missing: $(printf '%s' "$want" | tr '\n' ' ')" >&2
    return 1
  fi
  # `ollama list` succeeds as soon as the server answers (an empty list is an answer): the server started by provision.sh may need a
  # while, and a fixed pause is not a readiness check.
  until ollama_list; do
    i=$((i + 1))
    if [ "$i" -ge "$OLLAMA_TRIES" ]; then
      echo "[CI-OS] The Ollama server did not answer after $OLLAMA_TRIES tries: its models cannot be checked, so they are treated as missing: $(printf '%s' "$want" | tr '\n' ' ')" >&2
      echo "[CI-OS] Last error of 'ollama list': ${OLLAMA_ERR:-(it printed nothing)}" >&2
      return 1
    fi
    sleep "$OLLAMA_SLEEP"
  done
  listing="$OLLAMA_LISTING"
  have="$(printf '%s\n' "$listing" | awk 'NR > 1 { print $1 }')"
  # The same hardware-fit gate the Arch provisioner applies before it pulls (core/lib/gpu-detect.sh): a model the machine cannot
  # hold was skipped on purpose and is not "missing", otherwise a small machine would end "degraded" for good.
  # shellcheck source=../../../core/lib/gpu-detect.sh
  [ -r "$SCRIPT_DIR/../../../core/lib/gpu-detect.sh" ] && . "$SCRIPT_DIR/../../../core/lib/gpu-detect.sh"
  for m in $want; do
    case "$m" in *:*) ;; *) m="$m:latest" ;; esac
    if declare -F ci_os_model_gate_allows >/dev/null 2>&1 && ! ci_os_model_gate_allows "$m"; then
      echo "[CI-OS] $m skipped on purpose: ${CI_OS_MODEL_FIT_REASON:-the machine is below the RAM/VRAM budget of the model}" >&2
      continue
    fi
    printf '%s\n' "$have" | grep -qxF -- "$m" || missing="$missing ${m%:latest}"
  done
  [ -z "$missing" ] || { echo "[CI-OS] Required Ollama model(s) missing after provisioning:$missing" >&2; return 1; }
  echo "[CI-OS] Ollama models present: $(printf '%s' "$want" | tr '\n' ' ')"
}

[ -f "$ARCH_PROVISION" ] || { echo "[CI-OS] $ARCH_PROVISION not found" >&2; exit 1; }
# Not `exec`: the result has to be looked at afterwards.
rc=0
bash "$ARCH_PROVISION" "$@" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
if wants_models "$@"; then
  crc=0
  check_models || crc=$?
  case "$crc" in
    0) ;;
    1) echo "[CI-OS] Provisioning finished, but the models above are not on this machine yet; exiting 74 (degraded) so that it is tried again." >&2; exit 74 ;;
    *) exit 1 ;;
  esac
fi
exit 0
