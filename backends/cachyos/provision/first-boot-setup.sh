#!/bin/bash
# First-boot provisioning for the CachyOS edition: runs backends/cachyos/provision/provision.sh (the wrapper around the Arch
# provisioner) once the installed system has a network. Installed as /usr/lib/ci-os/first-boot-setup.sh by the installer
# (installer/scripts/ci-os-stage-target.sh), started by ci-os-first-boot-setup.service and retried by its timer.
#
# A port of the Ubuntu edition's first-boot script (backends/ubuntu/chroot/customize-chroot.sh, "Step 10c") with the casper and
# apt assumptions taken out:
#   - live session = the kernel command line has archisobasedir (archiso's boot parameter) or /run/archiso exists; the unit also
#     says ConditionKernelCommandLine=!archisobasedir. The Ubuntu script looked for /cdrom/casper.
#   - network probe = ICMP to 1.1.1.1, then HTTPS to archlinux.org: the hosts provisioning needs first are the pacman mirrors.
#   - no snap removal.
# Runs until it has completed once: at every boot and every 15 minutes (the timer) while pending, with at most
# MAX_AUTO_ATTEMPTS failed provisioning runs. `sudo ci-os-setup` (passes --manual) re-runs it at any time, finished or not, and
# forwards further arguments to provision.sh: sudo ci-os-setup --tier=core,hardware.
#
# "Completed" means provision.sh exited 0, which includes that the Ollama models in core/manifest/ecosystem.yaml (llm.models) are on
# the machine (provision.sh checks, see its header). Exit 74 is "degraded": the run went to the end but a model is missing (a pull
# failed, or the link was too slow to finish). No done marker is written, the attempt stays counted, and the timer tries again, up
# to MAX_AUTO_ATTEMPTS; a retry only pulls what is missing (the Arch script skips models that are installed). The state of the last
# run is in $STATE_DIR/first-boot-setup-status. A run is counted when it STARTS, so a boot that is interrupted (power off in the
# middle of a download) uses up one of the attempts; `sudo ci-os-setup` always works.
#
# No `set -e`: provision.sh tolerates individual network failures itself, and a hard exit here would skip the marker bookkeeping.
#
# Output. Everything this script and the provisioners print goes through progress-filter.sh (next to provision.sh in the bootstrap
# tree) before it reaches the journal and the log: Ollama redraws its progress block ten times a second, and ISO #4's log grew to
# 14,052 lines / 1.9 MB for three pulls, each redraw a "[147B blob data]" journal entry, while the Arch provisioner's colour codes made
# every ordinary line a blob too. When a person runs `sudo ci-os-setup` in a terminal they keep the raw stream on the screen (colours,
# the live progress bar) and only the log copy is filtered. A missing or failing filter degrades to `cat`, never to lost output.
#
# The tail of the output. The filter and the tee live in a process substitution, which is not a child bash waits for, and the unit has
# the default KillMode=control-group: systemd SIGTERMs whatever is still in the cgroup the moment the main process exits. A pipeline
# that is a little slower than a plain `tee` then loses the last lines of the run ("First-boot setup completed", "NOTE: Log out ...",
# "Will retry automatically ...": measured under a real systemd manager with a byte-at-a-time filter, 24 to 40 runs in 40, and 16 in 40
# with the awk filter; KillMode=mixed made no difference). So
# the EXIT trap (drain_output) closes this script's stdout and stderr, which gives the pipeline its end of input, and waits for the
# substitution to finish, for at most 5 s: a background child of the provisioner that still holds the pipe cannot keep the unit up.
#
# Environment (tests; the defaults are the installed system): CI_OS_BOOTSTRAP_ROOT, CI_OS_STATE_DIR, CI_OS_LOG_FILE,
# CI_OS_LOCK_FILE, CI_OS_CMDLINE_FILE, CI_OS_RUN_ARCHISO, CI_OS_NETWORK_TRIES, CI_OS_NETWORK_SLEEP, CI_OS_NETWORK_PROBE (an executable),
# CI_OS_FORCE_TTY=1 (take the interactive branch of the output set-up without a terminal).
set -u

BOOTSTRAP_ROOT="${CI_OS_BOOTSTRAP_ROOT:-/usr/lib/ci-os/bootstrap}"
PROVISION_SH="$BOOTSTRAP_ROOT/backends/cachyos/provision/provision.sh"
PROGRESS_FILTER="$BOOTSTRAP_ROOT/backends/cachyos/provision/progress-filter.sh"
STATE_DIR="${CI_OS_STATE_DIR:-/var/lib/ci-os}"
LOG_FILE="${CI_OS_LOG_FILE:-/var/log/ci-os-first-boot-setup.log}"
# Written ONLY when provisioning succeeded, models included. The unit and the timer are gated on it.
MARKER_FILE="$STATE_DIR/.first-boot-setup-done"
# One line about the last run that did not complete ("degraded" = models missing, "failed"); removed on success.
STATUS_FILE="$STATE_DIR/first-boot-setup-status"
# Failed automatic provisioning runs so far. An offline boot is not a run: waiting for the network is cheap, downloading again is not.
ATTEMPTS_FILE="$STATE_DIR/first-boot-setup-attempts"
MAX_AUTO_ATTEMPTS=3
LOCK_FILE="${CI_OS_LOCK_FILE:-/run/ci-os-first-boot-setup.lock}"
CMDLINE_FILE="${CI_OS_CMDLINE_FILE:-/proc/cmdline}"
NETWORK_TRIES="${CI_OS_NETWORK_TRIES:-30}"
NETWORK_SLEEP="${CI_OS_NETWORK_SLEEP:-2}"

MANUAL=false
if [[ "${1:-}" == "--manual" ]]; then
    MANUAL=true
    shift
fi
PROVISION_ARGS=("$@")
if [[ ${#PROVISION_ARGS[@]} -eq 0 ]]; then
    PROVISION_ARGS=(--tier=core)
fi

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true
# The stream a log and the journal can take. Used inside the process substitutions below, which run in subshells of this script and
# see this function. `|| cat`: a filter that died must not take the output (and, through SIGPIPE, the provisioning) with it.
log_stream() {
    if [[ -r "$PROGRESS_FILTER" ]]; then bash "$PROGRESS_FILTER" || cat; else cat; fi
}
if [[ -t 1 || "${CI_OS_FORCE_TTY:-}" == 1 ]]; then
    # The inner substitution is the filtered copy for the log; the outer shell waits for it, so that waiting for the outer one (LOG_PID)
    # is waiting for both. (`wait` of a substitution's pid needs bash 4.4; without it the log copy may finish a moment after the script.)
    exec > >(tee >({ log_stream >> "$LOG_FILE"; } 2>/dev/null; cat >/dev/null); p=$!; [[ -z "$p" ]] || wait "$p" 2>/dev/null) 2>&1
else
    exec > >(log_stream | tee -a "$LOG_FILE") 2>&1
fi
# The pid of the substitution just made (empty where bash does not set $!, and then there is nothing to wait for; set -u would abort).
set +u; LOG_PID=$!; set -u
drain_output() {
    [[ -n "${LOG_PID:-}" ]] || return 0
    exec >&- 2>&-
    local t0=$SECONDS
    # A wall-clock bound (SECONDS), not a count of sleeps: where a process start is slow a count would take far longer than 5 s.
    while kill -0 "$LOG_PID" 2>/dev/null && (( SECONDS - t0 < 5 )); do sleep 0.05; done
    return 0
}
trap drain_output EXIT

echo "[CI-OS] First-boot setup starting at $(date -u)$([[ "$MANUAL" == true ]] && echo ' (manual)')"

# Safety net: never provision a live session.
if grep -q 'archisobasedir' "$CMDLINE_FILE" 2>/dev/null || [[ -d "${CI_OS_RUN_ARCHISO:-/run/archiso}" ]]; then
    echo "[CI-OS] Live session detected; skipping first-boot setup."
    exit 0
fi

# One run at a time: the timer and a manual `ci-os-setup` can overlap.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[CI-OS] First-boot setup is already running (see $LOG_FILE)."
    exit 0
fi

if [[ "$MANUAL" != true ]]; then
    if [[ -f "$MARKER_FILE" ]]; then
        echo "[CI-OS] First-boot setup already completed ($(cat "$MARKER_FILE")). To re-run: sudo ci-os-setup"
        exit 0
    fi
    attempts=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
    if [[ "$attempts" =~ ^[0-9]+$ ]] && (( attempts >= MAX_AUTO_ATTEMPTS )); then
        echo "[CI-OS] Provisioning failed $attempts times; not retrying automatically. See $LOG_FILE, then run: sudo ci-os-setup"
        exit 0
    fi
fi

# ICMP first, then HTTPS: some networks drop ping but allow the downloads provisioning needs.
network_up() {
    # Tests point CI_OS_NETWORK_PROBE at an executable that stands in for the network.
    if [[ -n "${CI_OS_NETWORK_PROBE:-}" ]]; then "$CI_OS_NETWORK_PROBE"; return; fi
    ping -c1 -W2 1.1.1.1 &>/dev/null && return 0
    command -v curl >/dev/null 2>&1 && curl -fsS -o /dev/null --max-time 5 https://archlinux.org/ &>/dev/null
}

NETWORK_OK=false
echo "[CI-OS] Waiting for network..."
for ((i = 1; i <= NETWORK_TRIES; i++)); do
    if network_up; then
        echo "[CI-OS] Network available."
        NETWORK_OK=true
        break
    fi
    echo "[CI-OS] Waiting for network... ($i/$NETWORK_TRIES)"
    sleep "$NETWORK_SLEEP"
done

if [[ "$NETWORK_OK" != "true" ]]; then
    # No marker: the next boot, or the timer within 15 minutes, tries again. Not counted as a failed attempt.
    echo "[CI-OS] WARNING: Network not available. Setup will retry automatically (next boot, or within 15 minutes); or run once online: sudo ci-os-setup"
    exit 0
fi

if [[ ! -r "$PROVISION_SH" ]]; then
    # A broken image, not a transient failure: retrying cannot help.
    echo "[CI-OS] WARNING: $PROVISION_SH not found; skipping provisioning."
    echo "no provisioner - $(date -u)" > "$MARKER_FILE"
    exit 0
fi

if [[ "$MANUAL" != true ]]; then
    # Count the run before starting it, so one that is killed (a shutdown or `systemctl stop` in the middle of a model pull) still counts toward the limit.
    attempts=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    attempts=$((attempts + 1))
    echo "$attempts" > "$ATTEMPTS_FILE"
    echo "[CI-OS] Running provision.sh ${PROVISION_ARGS[*]} (automatic attempt $attempts/$MAX_AUTO_ATTEMPTS)..."
else
    echo "[CI-OS] Running provision.sh ${PROVISION_ARGS[*]}..."
fi

bash "$PROVISION_SH" "${PROVISION_ARGS[@]}"
rc=$?
if [[ $rc -eq 75 ]]; then
    # No desktop account yet: nothing was provisioned, nothing is wrong. Give the attempt back.
    if [[ "$MANUAL" != true ]]; then echo $((attempts - 1)) > "$ATTEMPTS_FILE"; fi
    echo "[CI-OS] No desktop account yet; will retry (next boot, or within 15 minutes)."
    exit 0
fi
if [[ $rc -eq 74 ]]; then
    # Degraded, not failed: everything else is installed, but a required Ollama model is not (provision.sh printed which). No marker.
    echo "degraded: required Ollama models missing - $(date -u)" > "$STATUS_FILE"
    if [[ "$MANUAL" == true ]]; then
        echo "[CI-OS] Provisioning finished, but required Ollama models are missing (see above). Check the network and the free disk space, then re-run: sudo ci-os-setup"
    elif (( attempts < MAX_AUTO_ATTEMPTS )); then
        echo "[CI-OS] Provisioning finished, but required Ollama models are missing (see above). Will retry automatically (attempt $attempts/$MAX_AUTO_ATTEMPTS done; next boot, or within 15 minutes): only the missing models are pulled again."
    else
        echo "[CI-OS] Provisioning finished, but required Ollama models are STILL missing after $attempts automatic attempts, so setup is NOT marked complete and is no longer retried automatically. The local AI features need them. Check the network and the free disk space, then run: sudo ci-os-setup"
    fi
    exit 0
fi
if [[ $rc -ne 0 ]]; then
    echo "failed (status $rc) - $(date -u)" > "$STATUS_FILE"
    if [[ "$MANUAL" == true ]]; then
        echo "[CI-OS] provision.sh reported issues (see above). Fix them and re-run: sudo ci-os-setup"
    elif (( attempts < MAX_AUTO_ATTEMPTS )); then
        echo "[CI-OS] provision.sh reported issues (see above). Will retry automatically (next boot, or within 15 minutes)."
    else
        echo "[CI-OS] provision.sh reported issues (see above). Automatic retries exhausted; run: sudo ci-os-setup"
    fi
    exit 0
fi

date -u > "$MARKER_FILE"
rm -f "$ATTEMPTS_FILE" "$STATUS_FILE"

echo "[CI-OS] First-boot setup completed at $(date -u)"
echo "[CI-OS] Log saved to $LOG_FILE"
echo "[CI-OS] NOTE: Log out and back in for Docker group and PATH changes."
