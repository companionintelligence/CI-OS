#!/bin/bash
#=============================================================================
# ci-os-ollama-models-env - choose OLLAMA_MODELS for ollama.service
#
# Installed as /usr/libexec/ci-os/ollama-models-env and run by ollama.service as
#   ExecStartPre=-+/usr/libexec/ci-os/ollama-models-env          (root, failure ignored)
#   ExecStopPost=-+/usr/libexec/ci-os/ollama-models-env release  (root, failure ignored)
#
# When a Companion Stick's CI-CACHE exFAT volume is attached, point Ollama at
# <volume>/models (the bundle layout: models/blobs/sha256-<hex> and
# models/manifests/registry.ollama.ai/library/<name>/<tag>) and set OLLAMA_NOPRUNE=1,
# because Ollama deletes unreferenced files under blobs/ at start-up and a stick's store
# is seeded offline. When it is absent, or cannot be used by the 'ollama'
# user, write an EMPTY environment file: Ollama then uses its default
# (/usr/share/ollama/.ollama/models). This script never makes the unit fail.
#
# The volume is mounted by this script (not by udisks) so that it can be owned by
# the 'ollama' user: exFAT has no permissions, ownership comes from the mount
# options. A volume that something else already mounted is used only if 'ollama'
# can write to it.
#
# Opt-out: touch /etc/ci-os/ollama-no-cache
# Override: CI_OS_CACHE_LABEL (default CI-CACHE), CI_OS_CACHE_MOUNT (default /var/lib/ci-os/cache)
#
# Hugging Face and llama.cpp (added with core/lib/ci-os-models.sh): when /usr/bin/ci-os-models is installed, the
# same environment file also carries what those tools need to find the stick's models: HF_HUB_CACHE,
# HUGGINGFACE_HUB_CACHE and LLAMA_CACHE (the symlink view under /var/lib/ci-os/hf-view, built here, best
# effort), CI_STICK_CACHE, and HF_HUB_OFFLINE=1 when there is no default route. Ollama ignores them; the OLLAMA_*
# lines are exactly what they were. Without ci-os-models the file is the two OLLAMA_* lines, as before.
# The exFAT mount is owner-only (umask 0077, uid ollama): tools running as another user cannot read the blobs
# through the view unless the volume is mounted for them: CI_OS_CACHE_UMASK (e.g. 0027) and CI_OS_CACHE_GROUP
# (a group name, becomes gid=) change the mount options; the defaults are the old ones.
# Test overrides: CI_OS_OLLAMA_RUN_DIR (default /run/ollama), CI_OS_ETC_DIR (default /etc/ci-os), CI_OS_MODELS_BIN.
#=============================================================================
set -u

RUN_DIR="${CI_OS_OLLAMA_RUN_DIR:-/run/ollama}"
ETC_DIR="${CI_OS_ETC_DIR:-/etc/ci-os}"
OUT="$RUN_DIR/ci-models.env"
STAMP="$RUN_DIR/ci-cache-mounted-by-us"
LABEL="${CI_OS_CACHE_LABEL:-CI-CACHE}"
MNT="${CI_OS_CACHE_MOUNT:-/var/lib/ci-os/cache}"
MODELS_BIN="${CI_OS_MODELS_BIN:-/usr/bin/ci-os-models}"
SUB="models"

log() { echo "ci-os-ollama-models-env: $*" >&2; }

if [ "${1:-start}" = "release" ]; then
    # Unmount only what this script mounted, so a stick that is still in use by the desktop is left alone.
    if [ -f "$STAMP" ]; then
        umount "$MNT" 2>/dev/null || log "could not unmount $MNT (busy); leaving it mounted"
        rm -f "$STAMP"
    fi
    exit 0
fi

mkdir -p "$RUN_DIR" 2>/dev/null || true
use_default() { : > "$OUT" 2>/dev/null || true; chmod 0644 "$OUT" 2>/dev/null || true; [ -z "${1:-}" ] || log "$1; using the default model directory"; exit 0; }

[ ! -e "$ETC_DIR/ollama-no-cache" ] || use_default "disabled by $ETC_DIR/ollama-no-cache"
id -u ollama >/dev/null 2>&1 || use_default "no ollama user"
command -v blkid >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 || use_default "blkid/runuser missing"

dev="$(blkid -L "$LABEL" 2>/dev/null | sed -n 1p)"
[ -n "$dev" ] && [ -b "$dev" ] || use_default ""                       # volume absent: the normal case, say nothing
[ "$(blkid -o value -s TYPE "$dev" 2>/dev/null)" = "exfat" ] || use_default "$dev is not exFAT"

target="$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null | sed -n 1p)"
if [ -z "$target" ]; then
    ouid="$(id -u ollama)"; ogid="$(id -g ollama)"
    umask_opt="${CI_OS_CACHE_UMASK:-0077}"
    case "$umask_opt" in [0-7][0-7][0-7]|0[0-7][0-7][0-7]) ;; *) log "CI_OS_CACHE_UMASK '$umask_opt' is not an octal mask; using 0077"; umask_opt=0077 ;; esac
    if [ -n "${CI_OS_CACHE_GROUP:-}" ]; then
        gid_opt="$(getent group "$CI_OS_CACHE_GROUP" 2>/dev/null | cut -d: -f3)"
        case "$gid_opt" in ''|*[!0-9]*) log "no group '$CI_OS_CACHE_GROUP'; using the ollama group"; gid_opt="" ;; esac
        [ -z "$gid_opt" ] || ogid="$gid_opt"
    fi
    mkdir -p "$MNT" || use_default "cannot create $MNT"
    # umask=0077 (the default): only 'ollama' (and root) can read the models. noexec/nosuid/nodev: the volume holds data only.
    if err="$(mount -t exfat -o "uid=$ouid,gid=$ogid,umask=$umask_opt,nosuid,nodev,noexec" "$dev" "$MNT" 2>&1)"; then
        : > "$STAMP"
        target="$MNT"
    else
        use_default "could not mount $dev on $MNT ($err)"
    fi
fi

dir="$target/$SUB"
runuser -u ollama -- mkdir -p "$dir" 2>/dev/null || use_default "$target is not writable by the ollama user"
runuser -u ollama -- test -w "$dir" 2>/dev/null || use_default "$dir is not writable by the ollama user"

# What the selection means for every consumer, from the one place that knows (core/lib/ci-os-models.sh). The
# helper is told which cache this script chose, so the two cannot disagree; its output is used only if it is
# well-formed and agrees about OLLAMA_MODELS. Anything else: the two lines that have always been written.
env_text=""
if [ -x "$MODELS_BIN" ]; then
    env_text="$(CI_OS_MODELS_CACHE="$target" "$MODELS_BIN" env --format systemd 2>/dev/null | grep -E '^[A-Z][A-Z0-9_]*=[^[:cntrl:]]*$')" || env_text=""
    case "
$env_text
" in
        *"
OLLAMA_MODELS=$dir
"*) ;;
        *) env_text="" ;;
    esac
fi
if [ -n "$env_text" ]; then
    printf '%s\n' "$env_text" > "$OUT"
    # the symlink view for Hugging Face / llama.cpp; a few links, built as root, never allowed to hold the unit up
    if command -v timeout >/dev/null 2>&1; then
        CI_OS_MODELS_CACHE="$target" timeout 20 "$MODELS_BIN" view --quiet >/dev/null 2>&1 || log "could not build the Hugging Face view (not fatal)"
    else
        CI_OS_MODELS_CACHE="$target" "$MODELS_BIN" view --quiet >/dev/null 2>&1 || log "could not build the Hugging Face view (not fatal)"
    fi
else
    printf 'OLLAMA_MODELS=%s\nOLLAMA_NOPRUNE=1\n' "$dir" > "$OUT"
fi
chmod 0644 "$OUT"
log "models on $dir"
exit 0
