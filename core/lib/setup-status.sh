#!/usr/bin/env bash
#=============================================================================
# setup-status.sh: what the first-boot setup is doing, in a file a person's desktop can read
#
# The first-boot setup (first-boot-setup.sh, which runs provision.sh) takes minutes to an hour and says nothing on screen: it logs to the
# journal. This writes its progress to one small world-readable file, /var/lib/ci-os/setup-status, that the desktop's setup-progress
# script (payload/start/usr/libexec/ci-os/setup-progress) turns into a notification, and that ci-os-info can read.
#
#   state=running        waiting (for the network) | running | done | failed
#   step=3               the step that is running now (0 before the first one)
#   steps=7              how many there are (0 when not known yet)
#   title=Installing the AI runtime
#   detail=              optional second line
#   time=1760900000      epoch seconds of the write
#
# Sourced, not run. It does nothing unless CI_OS_SETUP_STATUS names the file, so provision.sh run by hand (on any Ubuntu, with sudo) writes
# nothing; only first-boot-setup.sh sets the variable. Every function returns 0 whatever happens: progress is a courtesy and must never
# stop an install. The file is replaced atomically (a reader never sees half of it). Bash 3.2-clean.
#
#   ci_os_status_set STATE STEP STEPS TITLE [DETAIL]   write the file
#   ci_os_status_begin STEPS                           the total, and the counter back to 0
#   ci_os_status_step TITLE                            the next step: counter + 1, state running
#   ci_os_status_state STATE TITLE [DETAIL]            a new state at the current step (done, failed, waiting)
#   ci_os_status_reload                                take step, steps and the step's title (CI_OS_STATUS_TITLE) back from the file:
#                                                      for the caller whose steps ran in a child process (provision.sh)
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

CI_OS_STATUS_STEP=0
CI_OS_STATUS_STEPS=0
CI_OS_STATUS_TITLE=""

# one line, no control characters: the file is read by a shell with sed and must stay one key=value per line
_ci_os_status_clean() { printf '%s' "$1" | tr -d '\000-\037\177'; }

ci_os_status_set() {
    local f="${CI_OS_SETUP_STATUS:-}" tmp
    [[ -n "$f" ]] || return 0
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    tmp="$(mktemp "$f.XXXXXX" 2>/dev/null)" || return 0
    {
        printf 'state=%s\n' "$(_ci_os_status_clean "${1:-}")"
        printf 'step=%s\n' "$(_ci_os_status_clean "${2:-0}")"
        printf 'steps=%s\n' "$(_ci_os_status_clean "${3:-0}")"
        printf 'title=%s\n' "$(_ci_os_status_clean "${4:-}")"
        printf 'detail=%s\n' "$(_ci_os_status_clean "${5:-}")"
        printf 'time=%s\n' "$(date +%s)"
    } >"$tmp" 2>/dev/null && chmod 0644 "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 0
}

ci_os_status_begin() {
    CI_OS_STATUS_STEP=0
    CI_OS_STATUS_STEPS="${1:-0}"
    return 0
}

ci_os_status_step() {
    CI_OS_STATUS_STEP=$((CI_OS_STATUS_STEP + 1))
    ci_os_status_set running "$CI_OS_STATUS_STEP" "$CI_OS_STATUS_STEPS" "${1:-}"
}

ci_os_status_state() {
    ci_os_status_set "${1:-running}" "$CI_OS_STATUS_STEP" "$CI_OS_STATUS_STEPS" "${2:-}" "${3:-}"
}

ci_os_status_reload() {
    local f="${CI_OS_SETUP_STATUS:-}" v
    [[ -n "$f" && -r "$f" ]] || return 0
    v="$(sed -n 's/^step=//p' "$f" 2>/dev/null | head -n 1)"; [[ "$v" =~ ^[0-9]+$ ]] && CI_OS_STATUS_STEP="$v"
    v="$(sed -n 's/^steps=//p' "$f" 2>/dev/null | head -n 1)"; [[ "$v" =~ ^[0-9]+$ ]] && CI_OS_STATUS_STEPS="$v"
    CI_OS_STATUS_TITLE="$(sed -n 's/^title=//p' "$f" 2>/dev/null | head -n 1)"
    return 0
}
