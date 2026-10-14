#!/bin/bash
# Companion Hub - Start after setup verification
# Reads /var/lib/setup-device/hub.env (CI_ZONE_ID, DEVICE_ID, API_KEY, CI_CLOUD_API_URL)
# and hands off to provision.sh --step=ci-hub — the single entrypoint every
# CI-Hub deploy path uses (first boot, manual run, and this one). Previously
# this script had its own 3-branch fallback cascade, including a check for a
# ci-os-hub.service systemd unit that nothing in the repo ever defined.
# After Hub starts, triggers post-validation (ROCm, Ollama models) once.

HUB_ENV="/var/lib/setup-device/hub.env"
POST_VALIDATION_FLAG="/var/lib/setup-device/post-validation-done"
PROVISION_SH="/usr/lib/ci-os/bootstrap/backends/ubuntu/provision/provision.sh"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t ci-os-hub-start -p info 2>/dev/null || true
}

[ ! -f "$HUB_ENV" ] && exit 0

if [ -x "$PROVISION_SH" ]; then
    log "Deploying CI-Hub via provision.sh --step=ci-hub"
    set -a
    # shellcheck source=/dev/null
    . "$HUB_ENV"
    set +a
    bash "$PROVISION_SH" --step=ci-hub 2>/dev/null || log "provision.sh --step=ci-hub reported issues"
else
    log "WARNING: $PROVISION_SH not found; cannot deploy CI-Hub"
fi

# After validation + Hub, run heavy setup (ROCm, Ollama models) once in background
if [ ! -f "$POST_VALIDATION_FLAG" ] && [ -x /usr/local/bin/ci-os-post-validation.sh ]; then
    log "Scheduling post-validation setup (ROCm, Ollama models)"
    nohup /usr/local/bin/ci-os-post-validation.sh >/var/log/ci-os-post-validation.log 2>&1 &
fi

exit 0
