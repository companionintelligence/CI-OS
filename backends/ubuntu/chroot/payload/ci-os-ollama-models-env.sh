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
#=============================================================================
set -u

OUT=/run/ollama/ci-models.env
STAMP=/run/ollama/ci-cache-mounted-by-us
LABEL="${CI_OS_CACHE_LABEL:-CI-CACHE}"
MNT="${CI_OS_CACHE_MOUNT:-/var/lib/ci-os/cache}"
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

mkdir -p /run/ollama 2>/dev/null || true
use_default() { : > "$OUT" 2>/dev/null || true; chmod 0644 "$OUT" 2>/dev/null || true; [ -z "${1:-}" ] || log "$1; using the default model directory"; exit 0; }

[ ! -e /etc/ci-os/ollama-no-cache ] || use_default "disabled by /etc/ci-os/ollama-no-cache"
id -u ollama >/dev/null 2>&1 || use_default "no ollama user"
command -v blkid >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 || use_default "blkid/runuser missing"

dev="$(blkid -L "$LABEL" 2>/dev/null | sed -n 1p)"
[ -n "$dev" ] && [ -b "$dev" ] || use_default ""                       # volume absent: the normal case, say nothing
[ "$(blkid -o value -s TYPE "$dev" 2>/dev/null)" = "exfat" ] || use_default "$dev is not exFAT"

target="$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null | sed -n 1p)"
if [ -z "$target" ]; then
    ouid="$(id -u ollama)"; ogid="$(id -g ollama)"
    mkdir -p "$MNT" || use_default "cannot create $MNT"
    # umask=0077: only 'ollama' (and root) can read the models. noexec/nosuid/nodev: the volume holds data only.
    if err="$(mount -t exfat -o "uid=$ouid,gid=$ogid,umask=0077,nosuid,nodev,noexec" "$dev" "$MNT" 2>&1)"; then
        : > "$STAMP"
        target="$MNT"
    else
        use_default "could not mount $dev on $MNT ($err)"
    fi
fi

dir="$target/$SUB"
runuser -u ollama -- mkdir -p "$dir" 2>/dev/null || use_default "$target is not writable by the ollama user"
runuser -u ollama -- test -w "$dir" 2>/dev/null || use_default "$dir is not writable by the ollama user"

printf 'OLLAMA_MODELS=%s\nOLLAMA_NOPRUNE=1\n' "$dir" > "$OUT"
chmod 0644 "$OUT"
log "models on $dir"
exit 0
