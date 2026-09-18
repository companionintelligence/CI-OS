#!/usr/bin/env bash
#=============================================================================
# CI-OS Bazzite backend — first-boot module: pull the Ollama model set
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
# Sibling of ci-os-first-boot-ci-hub.sh — read THAT file's header first for
# the full marker-file/idempotency design and why this is split into its
# own unit/marker rather than folded into the CI-Hub deploy step. Summary:
# multi-gigabyte model downloads are exactly the "would bloat every user's
# image identically" case the plan flags for first-boot pull instead of
# image-baking (docs/architecture/multi-distro-design.md's Rollout table).
#
# WHAT IS ALREADY BAKED (assumed, not done here)
# -------------------------------------------------
# Per this phase's research, the Ollama BINARY and its systemd unit are a
# build-time concern — `curl -fsSL https://ollama.com/install.sh | sh`'s
# installer is package-manager-agnostic (confirmed by reading
# backends/fedora/provision/provision.sh's install_ollama()), so the
# sibling image-definition agent bakes it and runs `systemctl enable
# ollama.service` at build time. This script does NOT install Ollama,
# does NOT touch GPU/context systemd drop-ins (backends/fedora/provision/
# provision.sh's configure_ollama_gpu()/write_ollama_context_dropin() —
# those are also a build-time concern for this backend, baked once into
# the image rather than regenerated every first boot), and does NOT set
# OLLAMA_HOST — all of that is assumed already correct from the image by
# the time this runs. This script's ONLY job is the model weights.
#
# The fixed 3-model set below is core/manifest/ecosystem.yaml's
# `llm.models` list, ported unchanged from backends/fedora/provision/
# provision.sh's pull_ollama_models() (itself ported unchanged from
# Ubuntu's) — keep this list in sync with that manifest if it ever changes.
#=============================================================================

set -o nounset
set -o pipefail
# No `set -e` — same reasoning as ci-os-first-boot-ci-hub.sh: a failed pull
# of one model must not skip the unconditional marker-write, and must not
# skip attempting the remaining models.

MARKER_FILE="/var/lib/ci-os/.first-boot-ollama-models-done"
LOG_FILE="/var/log/ci-os-first-boot-ollama-models.log"
OLLAMA_WAIT_SECONDS=120
OLLAMA_WAIT_INTERVAL=5

# core/manifest/ecosystem.yaml's llm.models, verbatim.
MODELS=(
    "nomic-embed-text"
    "gemma3:1b"
    "qwen3.6:27b"
)

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[CI-OS] Bazzite first-boot Ollama model pull starting at $(date -u)"

if [[ -f "$MARKER_FILE" ]]; then
    echo "[CI-OS] Ollama model pull already completed ($(cat "$MARKER_FILE" 2>/dev/null)). To re-run: sudo rm $MARKER_FILE && sudo systemctl start ci-os-first-boot-ollama-models.service"
    exit 0
fi

if ! command -v ollama >/dev/null 2>&1; then
    echo "[CI-OS] WARNING: 'ollama' not found on PATH — expected to be baked into the image (see this script's header). Skipping model pull."
    mkdir -p "$(dirname "$MARKER_FILE")"
    date -u > "$MARKER_FILE"
    exit 0
fi

# Ollama's systemd unit is baked/enabled at build time (see header) — it
# should already be starting on its own. Poll rather than assume it has
# finished coming up yet by the time this unit runs.
echo "[CI-OS] Waiting for ollama.service to become active (up to ${OLLAMA_WAIT_SECONDS}s)..."
waited=0
ollama_ready=false
while (( waited < OLLAMA_WAIT_SECONDS )); do
    if systemctl is-active --quiet ollama.service 2>/dev/null || ollama list >/dev/null 2>&1; then
        ollama_ready=true
        break
    fi
    sleep "$OLLAMA_WAIT_INTERVAL"
    waited=$(( waited + OLLAMA_WAIT_INTERVAL ))
done

if [[ "$ollama_ready" != "true" ]]; then
    echo "[CI-OS] WARNING: ollama.service did not become ready within ${OLLAMA_WAIT_SECONDS}s. Attempting model pulls anyway; they will fail fast if the server truly isn't up."
fi

any_failed=false
for model in "${MODELS[@]}"; do
    if ollama list 2>/dev/null | grep -q -- "$model"; then
        echo "[CI-OS] ${model} already installed, skipping."
        continue
    fi
    echo "[CI-OS] Pulling ${model} ..."
    if ! ollama pull "$model"; then
        echo "[CI-OS] WARNING: failed to pull ${model}."
        any_failed=true
    fi
done

mkdir -p "$(dirname "$MARKER_FILE")"
date -u > "$MARKER_FILE"

if [[ "$any_failed" == "true" ]]; then
    echo "[CI-OS] One or more models failed to pull. Re-run with: sudo rm $MARKER_FILE && sudo systemctl start ci-os-first-boot-ollama-models.service"
fi

echo "[CI-OS] Ollama model pull step finished at $(date -u)"
echo "[CI-OS] Log saved to $LOG_FILE"
