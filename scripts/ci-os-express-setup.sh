#!/usr/bin/env bash
#=============================================================================
# CI-OS Express Setup
#
# Lightweight orchestrator for post-install setup verification and AI readiness.
#=============================================================================

set -euo pipefail

ASSUME_YES=0
SKIP_MODELS=0
SKIP_PRIVACY=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1; shift ;;
        --skip-models) SKIP_MODELS=1; shift ;;
        --skip-privacy) SKIP_PRIVACY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            cat <<'EOF'
Usage:
  sudo ci-os-express-setup [--yes] [--skip-models] [--skip-privacy] [--dry-run]

Runs privacy status/apply, AI benchmark, model recommendation/install, and
headless setup status when those commands are available. Writes a JSON report.
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if [[ "$(id -u)" -eq 0 ]]; then
    DATA_DIR="${CI_OS_DATA_DIR:-/var/lib/ci-os}"
else
    DATA_DIR="${CI_OS_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ci-os}"
fi
REPORT_JSON="$DATA_DIR/setup-report.json"
LOG_FILE="$DATA_DIR/express-setup.log"
mkdir -p "$DATA_DIR"

log() {
    printf '[CI-OS Express] %s\n' "$*" | tee -a "$LOG_FILE" >&2
}

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    printf '%s' "$value"
}

run_step() {
    local name="$1"
    shift
    log "== $name =="
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "dry-run: $*"
        return 0
    fi
    "$@" || {
        log "warning: $name failed"
        return 1
    }
}

maybe_command() {
    command -v "$1" >/dev/null 2>&1
}

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "Starting CI-OS Express Setup"

privacy_status="missing"
privacy_apply="skipped"
benchmark_status="missing"
recommend_status="missing"
model_install_status="skipped"
headless_status="missing"

if maybe_command ci-os-privacy-status; then
    run_step "privacy status" ci-os-privacy-status && privacy_status="ok" || privacy_status="failed"
fi

if [[ "$SKIP_PRIVACY" -eq 0 ]]; then
    if maybe_command ci-os-privacy-apply; then
        if [[ "$(id -u)" -eq 0 ]]; then
            run_step "privacy apply" ci-os-privacy-apply && privacy_apply="ok" || privacy_apply="failed"
        else
            log "privacy apply requires root; run with sudo for enforcement"
            privacy_apply="needs-root"
        fi
    else
        privacy_apply="missing"
    fi
fi

if maybe_command ci-os-benchmark; then
    run_step "AI benchmark" ci-os-benchmark && benchmark_status="ok" || benchmark_status="failed"
fi

if maybe_command ci-os-model-recommend; then
    run_step "AI model recommendation" ci-os-model-recommend && recommend_status="ok" || recommend_status="failed"
fi

if [[ "$SKIP_MODELS" -eq 0 ]]; then
    if maybe_command ci-os-model-install; then
        model_args=()
        [[ "$ASSUME_YES" -eq 1 ]] && model_args+=(--yes)
        [[ "$DRY_RUN" -eq 1 ]] && model_args+=(--dry-run)
        run_step "AI model install" ci-os-model-install "${model_args[@]}" && model_install_status="ok" || model_install_status="failed"
    else
        model_install_status="missing"
    fi
fi

if maybe_command ci-os-headless-status; then
    run_step "headless setup status" ci-os-headless-status && headless_status="ok" || headless_status="failed"
fi

cat > "$REPORT_JSON" <<EOF
{
  "created_at": "$created_at",
  "dry_run": $DRY_RUN,
  "privacy_status": "$(json_escape "$privacy_status")",
  "privacy_apply": "$(json_escape "$privacy_apply")",
  "benchmark": "$(json_escape "$benchmark_status")",
  "model_recommendation": "$(json_escape "$recommend_status")",
  "model_install": "$(json_escape "$model_install_status")",
  "headless_status": "$(json_escape "$headless_status")",
  "benchmark_file": "$(json_escape "$DATA_DIR/benchmark.json")",
  "model_recommendations_file": "$(json_escape "$DATA_DIR/model-recommendations.json")",
  "privacy_status_file": "$(json_escape "$DATA_DIR/privacy-status.json")",
  "headless_status_file": "$(json_escape "$DATA_DIR/headless-status.json")"
}
EOF

log "Express Setup report written to $REPORT_JSON"
cat "$REPORT_JSON"
