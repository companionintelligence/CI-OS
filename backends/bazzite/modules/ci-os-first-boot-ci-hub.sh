#!/usr/bin/env bash
#=============================================================================
# CI-OS Bazzite backend — first-boot module: deploy CI Hub Service
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
#
# WHAT THIS FILE IS PART OF
# --------------------------
# backends/bazzite/modules/ is the FIRST-BOOT runtime half of the Bazzite
# (Phase 5) backend. Bazzite is Fedora Atomic (bootc/rpm-ostree): the OS root
# is an immutable, publicly-shared OCI image built from a Containerfile
# (backends/bazzite/image/ — a SIBLING piece of work, not this one). Nothing
# in this file bakes anything into that image. This file, and its sibling
# ci-os-first-boot-ollama-models.sh, are the two things this phase's research
# identified as genuinely UNABLE to be baked into a shared image and that
# must instead run once, at first boot, on the already-deployed appliance:
#
#   (a) core/lib/ci-hub.sh's deploy step — needs REGISTRY_USERNAME/
#       REGISTRY_PASSWORD (private-registry credentials) and, ideally,
#       DEVICE_ID/API_KEY from device pairing. Baking real credentials into
#       a publicly-distributed base image would leak them to every user of
#       that image — this must run per-device, after the fact.
#   (b) Ollama's model weights (the fixed 3-model set in
#       core/manifest/ecosystem.yaml's `llm.models`) — multi-gigabyte
#       downloads that would bloat every user's image identically whether
#       they want them pulled yet or not. The plan's own recommendation,
#       reconfirmed by this phase's research, is first-boot pull, not
#       image-baked — see docs/architecture/multi-distro-design.md's
#       Rollout table ("Bazzite model-baking into the image (default: pull
#       at first boot, not baked in)").
#
# THIS file is (a). See ci-os-first-boot-ollama-models.sh for (b).
#
# Ollama itself (the `ollama` binary + its systemd unit) is a BUILD-TIME
# concern, already baked into the image per this phase's research
# ("install_ollama()'s binary+systemd-unit installer is package-manager-
# agnostic — bake the binary and unit... `systemctl enable` at build time").
# This module does not install or configure Ollama — only pull models, in
# its own sibling script. Likewise Docker/Podman itself is assumed already
# present from the image (Bazzite ships Podman + Distrobox by default) —
# see lib/podman-docker-compat.sh for exactly what this module adapts
# versus what it assumes.
#
# WHY TWO SEPARATE UNITS INSTEAD OF ONE
# --------------------------------------
# CI-Hub deploy and Ollama model pull are independent, separately-failable,
# separately-expensive pieces of work (registry auth may be absent for
# weeks after a device ships; a slow first-boot network may finish pulling
# small models but time out on a large one). Splitting them into two
# oneshot services with two independent marker files means a failure or
# skip in one never blocks progress already made in the other, and a
# manual retry of just the failed half doesn't redo the half that already
# succeeded. See ci-os-first-boot-ollama-models.sh for the same pattern
# applied to model pulling.
#
# THE MARKER-FILE / IDEMPOTENCY DESIGN (read this before editing either
# first-boot script or its .service unit)
# ------------------------------------------------------------------------
# On a traditional (non-image-based) backend, a provisioning script can
# often get away with treating "the filesystem already looks installed" as
# its own idempotency check (e.g. `command -v docker` before installing
# docker). On an image-based OS that model breaks down for exactly the two
# things this module handles: CI-Hub deploy and model pulling are
# NETWORKED, potentially slow, side-effecting operations with no cheap
# "is this already done" filesystem probe that's both fast and correct on
# every boot — so instead of re-deriving that from state, each first-boot
# script uses an explicit marker file:
#
#   - The systemd unit gates itself with `ConditionPathExists=!<marker>`.
#     If the marker exists, systemd skips the unit at boot ENTIRELY (no
#     process is even started — this shows up in `systemctl status` as
#     "skipped", not as a successful no-op run) — so a provisioned
#     appliance's later boots do zero extra work, not even a fast check.
#   - The marker itself lives under /var/lib/ci-os/ — /var is real,
#     writable, persistent storage on an ostree/bootc root (unlike /run,
#     which is tmpfs and is wiped every boot — see
#     lib/podman-docker-compat.sh's header for a concrete case where that
#     distinction matters). This mirrors the *existing*, non-Bazzite
#     precedent already in this repo: backends/ubuntu/chroot/
#     customize-chroot.sh's ci-os-first-boot-setup.service uses the exact
#     same `ConditionPathExists=!/var/lib/ci-os/.first-boot-setup-done`
#     pattern — this module reuses that convention rather than inventing a
#     new one, just split into two markers instead of Ubuntu's one, per the
#     "why two separate units" note above.
#   - The marker is written UNCONDITIONALLY at the end of a run, whether or
#     not the underlying deploy/pull fully succeeded — matching Ubuntu's
#     own first-boot-setup.sh design (see its header: failures are logged,
#     not treated as reasons to retry every boot forever). This is a
#     deliberate choice: an appliance with, say, no registry credentials
#     yet would otherwise attempt (and log noise from) a doomed deploy on
#     every single boot indefinitely. Recovery is manual and explicit —
#     the log line each script prints on completion says exactly how:
#         sudo rm <marker> && sudo systemctl start <unit>.service
#
# WRITABLE-LOCATIONS CONSTRAINT
# -------------------------------
# Everything this file (and its sibling) does writes only to /var, /etc, or
# talks to already-running services over sockets — never to /usr, which is
# the image-managed, read-only-at-runtime path on this backend. See
# lib/podman-docker-compat.sh for the one place that needs an /etc write
# (a systemd-tmpfiles rule) and why /etc, not /run, was chosen for it.
#
# COORDINATION NOTE FOR THE SIBLING IMAGE-DEFINITION AGENT
# ------------------------------------------------------------
# This script (and its sibling + lib/ helper) must be COPY'd into the image
# preserving this directory's relative layout, e.g.:
#   COPY backends/bazzite/modules/ /usr/lib/ci-os/modules/
# and core/lib/ci-hub.sh (unmodified — this backend does not fork it) must
# also be staged into the image at the fixed path this script references
# below (CI_HUB_SH), the same way backends/ubuntu/chroot/customize-chroot.sh
# already stages it to /usr/lib/ci-os/bootstrap/core/lib/ for the Ubuntu ISO
# — reusing that exact staging path/convention here too, not inventing a
# second one. The two .service files next to this script must be COPY'd to
# /usr/lib/systemd/system/ and `systemctl enable`'d at IMAGE BUILD time
# (a Containerfile `RUN systemctl enable ci-os-first-boot-ci-hub.service
# ci-os-first-boot-ollama-models.service` step) — enabling a systemd unit is
# just creating a symlink, which `systemctl enable` can do against an
# image root with no running systemd, the same way Ubuntu's chroot script
# creates that symlink by hand (see customize-chroot.sh's
# `ln -sf .../ci-os-first-boot-setup.service .../multi-user.target.wants/`).
# This script cannot do that enablement itself — it has no access to the
# image build — so it is flagged here explicitly rather than silently
# assumed. Podman itself, and `podman compose`'s provider (docker-compose or
# podman-compose) need to be present in the image for
# lib/podman-docker-compat.sh's shim to be useful — verify a compose
# provider is actually baked; this module only adapts the CLI *name*
# (docker -> podman), it does not install anything.
#=============================================================================

set -o nounset
set -o pipefail
# Deliberately NOT `set -e`: a failed deploy attempt must still fall through
# to the unconditional marker-write below (see header) instead of aborting
# mid-script and leaving the marker missing (which would re-attempt, and
# re-log, on every subsequent boot).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MARKER_FILE="/var/lib/ci-os/.first-boot-ci-hub-done"
LOG_FILE="/var/log/ci-os-first-boot-ci-hub.log"
# Staged into the image by the sibling image-definition agent — see the
# coordination note above. NOT the live repo path (there is no repo
# checkout on a deployed appliance).
CI_HUB_SH="/usr/lib/ci-os/bootstrap/core/lib/ci-hub.sh"
# Written by the WiFi/pairing captive-portal flow (core/headless/payload/
# opt/setup-backend/setup_service.py's save_hub_env()) once the device is
# paired: CI_ZONE_ID, DEVICE_ID, API_KEY, CI_CLOUD_API_URL. Sourced here so
# ci-hub.sh sees them, exactly like backends/ubuntu's
# core/headless/payload/usr/local/bin/ci-os-hub-start.sh already does for
# every other backend — same convention, reused, not reinvented. Note this
# does NOT include REGISTRY_USERNAME/REGISTRY_PASSWORD — nothing in this
# repo currently wires those from the pairing flow, on ANY backend; that is
# a pre-existing, cross-backend gap, not something introduced or silently
# worked around here. ci-hub.sh itself already handles their absence
# gracefully (prints one clear message, exits 0) — see its header.
HUB_ENV="/var/lib/setup-device/hub.env"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[CI-OS] Bazzite first-boot CI-Hub deploy starting at $(date -u)"

if [[ -f "$MARKER_FILE" ]]; then
    echo "[CI-OS] CI-Hub first-boot deploy already completed ($(cat "$MARKER_FILE" 2>/dev/null)). To re-run: sudo rm $MARKER_FILE && sudo systemctl start ci-os-first-boot-ci-hub.service"
    exit 0
fi

# shellcheck source=lib/podman-docker-compat.sh
if [[ -f "$SCRIPT_DIR/lib/podman-docker-compat.sh" ]]; then
    . "$SCRIPT_DIR/lib/podman-docker-compat.sh"
    if ! ensure_podman_docker_compat; then
        echo "[CI-OS] WARNING: podman-docker-compat setup failed; ci-hub.sh's own 'docker' checks will likely fail below."
    fi
else
    echo "[CI-OS] WARNING: $SCRIPT_DIR/lib/podman-docker-compat.sh not found — proceeding without the Docker/Podman shim (only works if a real 'docker' CLI is already on PATH)."
fi

if [[ -f "$HUB_ENV" ]]; then
    echo "[CI-OS] Loading device pairing env from $HUB_ENV"
    set -a
    # shellcheck source=/dev/null
    . "$HUB_ENV"
    set +a
else
    echo "[CI-OS] No $HUB_ENV yet (device not paired) — proceeding; ci-hub.sh will fall back to its own DEVICE_ID/API_KEY defaults."
fi

if [[ -f "$CI_HUB_SH" ]]; then
    echo "[CI-OS] Deploying CI Hub Service via $CI_HUB_SH ..."
    bash "$CI_HUB_SH" || echo "[CI-OS] ci-hub.sh reported issues (see above) — this is often expected (e.g. no registry credentials yet). Re-run later with: sudo rm $MARKER_FILE && sudo systemctl start ci-os-first-boot-ci-hub.service"
else
    echo "[CI-OS] WARNING: $CI_HUB_SH not found; skipping CI-Hub deploy. (Expected to be staged into the image at build time — see this script's header 'COORDINATION NOTE'.)"
fi

mkdir -p "$(dirname "$MARKER_FILE")"
date -u > "$MARKER_FILE"

echo "[CI-OS] CI-Hub first-boot deploy step finished at $(date -u)"
echo "[CI-OS] Log saved to $LOG_FILE"
