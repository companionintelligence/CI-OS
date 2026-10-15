#!/usr/bin/env bash
#=============================================================================
# CI-OS Bazzite backend — first-boot module: conditionally enable the
# WiFi-onboarding captive portal (core/headless/payload/)
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
# SCOPE NOTE: core/headless/payload/ (the captive-portal WiFi onboarding
# payload — hostapd/dnsmasq configs, the setup-backend Flask service, the
# static setup-portal site, and their four systemd units) is core/ content,
# owned by the sibling image-definition agent, NOT this module. This script
# does not modify, COPY, or duplicate any of it. Its only job is the one
# piece of logic that is genuinely first-boot/device-state-dependent rather
# than static: WHETHER the captive-portal unit set should be enabled at all
# on this particular device.
#
# WHY THIS EXISTS (vs. Ubuntu's ISO, which just always enables these units)
# ------------------------------------------------------------------------
# backends/ubuntu/chroot/customize-chroot.sh bakes hostapd-setup.service,
# dnsmasq-setup.service, setup-backend.service and setup-network-monitor.service
# as unconditionally enabled at ISO-build time (symlinked straight into
# multi-user.target.wants/) — reasonable there, because every Ubuntu ISO
# install is a fresh, never-before-paired device by construction.
#
# A Bazzite image is different: it's a shared, publicly-distributed base
# image that could be `bootc switch`ed onto hardware that was ALREADY
# provisioned out-of-band (e.g. a device imaged with pairing credentials
# pre-injected — /var/lib/setup-device/hub.env written by some other
# mechanism before first boot). Unconditionally enabling a WiFi hotspot +
# captive portal on such a device on every boot would be wrong — it should
# never broadcast a setup network it doesn't need. So the DESIGN calls for
# the image-definition agent to COPY the unit FILES into the image (they
# need to exist) but NOT `systemctl enable` them at build time the way it
# does for this module's own two units — enablement decided here, once,
# based on real device state.
#
# CURRENT STATUS (disclosed, not silently assumed): as of this backend's
# first pass, backends/bazzite/image/Containerfile does NOT actually COPY
# core/headless/payload/'s captive-portal subsystem (hostapd/dnsmasq/nginx/
# Flask setup-backend, the static portal site, or their four systemd units)
# into the image at all — see that Containerfile's own "NOT IN THIS FILE, ON
# PURPOSE" closing comment. Wiring that subsystem in was never in scope for
# this pass (it needs several more unresearched package layers). This
# script's own PORTAL_UNITS-presence check below (`any_unit_present`) means
# that gap is harmless here specifically: on the current image none of the
# four units exist, so this script logs "nothing to gate," writes its
# marker, and exits 0 — it does NOT fail or block. The design above is
# forward-compatible for whenever a later pass adds that subsystem for
# real; it does not describe what already ships today.
#
# WHAT THIS DOES NOT DO
# -----------------------
# This is a ONE-TIME, first-boot decision (see the marker-file design in
# ci-os-first-boot-ci-hub.sh's header, reused here identically) — it does
# NOT continuously re-evaluate pairing state on every boot. That ongoing
# job (turn the hotspot off once a live connection exists, regardless of
# how it got there) already belongs to setup-network-monitor.sh's own
# connectivity polling loop (core/headless/payload/usr/local/bin/
# setup-network-monitor.sh, unmodified) — this script does not duplicate
# that. This script only answers: "on this device's very first boot, was it
# already paired before it ever got here, or not" — and enables or leaves
# disabled accordingly, once.
#=============================================================================

set -o nounset
set -o pipefail

MARKER_FILE="/var/lib/ci-os/.first-boot-setup-portal-gate-done"
LOG_FILE="/var/log/ci-os-first-boot-setup-portal-gate.log"
# Same pairing-state file core/headless/payload's setup_service.py writes
# and ci-os-first-boot-ci-hub.sh already sources — see that script's header.
HUB_ENV="/var/lib/setup-device/hub.env"

# The captive-portal unit set — must match core/headless/payload/systemd/
# system/*.service exactly. Listed here (not derived) because this script
# only enables/disables units by name; it does not read core/ content.
PORTAL_UNITS=(
    hostapd-setup.service
    dnsmasq-setup.service
    setup-backend.service
    setup-network-monitor.service
)

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[CI-OS] Bazzite first-boot setup-portal gate starting at $(date -u)"

if [[ -f "$MARKER_FILE" ]]; then
    echo "[CI-OS] Setup-portal gate decision already made ($(cat "$MARKER_FILE" 2>/dev/null)). To re-decide: sudo rm $MARKER_FILE && sudo systemctl start ci-os-first-boot-setup-portal-gate.service"
    exit 0
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "[CI-OS] WARNING: systemctl not available; cannot gate the setup-portal units. Skipping."
    mkdir -p "$(dirname "$MARKER_FILE")"
    date -u > "$MARKER_FILE"
    exit 0
fi

any_unit_present=false
for unit in "${PORTAL_UNITS[@]}"; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        any_unit_present=true
        break
    fi
done

if [[ "$any_unit_present" != "true" ]]; then
    echo "[CI-OS] None of the setup-portal units (${PORTAL_UNITS[*]}) are present on this system — nothing to gate. (Expected to be baked into the image as unit files, unenabled — see this script's header.)"
    mkdir -p "$(dirname "$MARKER_FILE")"
    date -u > "$MARKER_FILE"
    exit 0
fi

if [[ -f "$HUB_ENV" ]]; then
    echo "[CI-OS] $HUB_ENV already present — this device is already paired. Leaving the setup-portal units disabled."
    decision="already-paired: left disabled"
    for unit in "${PORTAL_UNITS[@]}"; do
        systemctl disable --now "$unit" 2>/dev/null || true
    done
else
    echo "[CI-OS] $HUB_ENV not present — this device is not yet paired. Enabling the setup-portal units so onboarding can begin."
    decision="not-yet-paired: enabled"
    for unit in "${PORTAL_UNITS[@]}"; do
        if ! systemctl enable --now "$unit" 2>/dev/null; then
            echo "[CI-OS] WARNING: could not enable/start $unit."
        fi
    done
fi

mkdir -p "$(dirname "$MARKER_FILE")"
echo "$(date -u) - ${decision}" > "$MARKER_FILE"

echo "[CI-OS] Setup-portal gate decision finished at $(date -u): ${decision}"
echo "[CI-OS] Log saved to $LOG_FILE"
