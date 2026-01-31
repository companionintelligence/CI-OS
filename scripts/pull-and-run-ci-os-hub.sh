#!/usr/bin/env bash
#=============================================================================
# Pull CI-OS-Hub image from Cloudflare registry (device-authenticated) and
# prepare env with device_id and api_key from headless setup.
#
# Requires: device_id and api_key in devices table (same as installing apps).
# Reads credentials from headless setup cloud_credentials.json.
#
# Usage:
#   ./pull-and-run-ci-os-hub.sh
#
# Optional env:
#   CREDENTIALS_PATH   - path to cloud_credentials.json
#                        (default: /var/lib/setup-device/cloud_credentials.json)
#   CI_REGISTRY_HOST   - registry host for docker login/pull
#                        (default: app.ci.computer)
#   HUB_ENV_FILE       - path to .env to write DEVICE_ID and CI_HUB_API_KEY
#                        (default: /var/lib/ci-os-hub/.env). Use .env.dev to
#                        match Hub start:dev (ENV_FILE=.env.dev).
#   HUB_COMPOSE_PATH   - if set, run docker-compose -f "$HUB_COMPOSE_PATH" up -d
#                        after pull (optional)
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CREDENTIALS_PATH="${CREDENTIALS_PATH:-/var/lib/setup-device/cloud_credentials.json}"
CI_REGISTRY_HOST="${CI_REGISTRY_HOST:-app.ci.computer}"
HUB_IMAGE="${CI_REGISTRY_HOST}/ci-os-hub:latest"
HUB_ENV_FILE="${HUB_ENV_FILE:-/var/lib/ci-os-hub/.env}"
HUB_DATA_DIR="${HUB_DATA_DIR:-/var/lib/ci-os-hub}"

main() {
  log_info "Pull CI-OS-Hub from registry (device-authenticated) and prepare env"

  if [[ ! -f "${CREDENTIALS_PATH}" ]]; then
    log_error "Credentials file not found: ${CREDENTIALS_PATH}"
    log_info "Run headless setup first so device_id and api_key are in the devices table and saved here."
    exit 1
  fi

  local device_id api_key
  if command -v jq &>/dev/null; then
    device_id=$(jq -r '.device_id // empty' "${CREDENTIALS_PATH}")
    api_key=$(jq -r '.api_key // empty' "${CREDENTIALS_PATH}")
  else
    log_warning "jq not found; trying grep/sed to read credentials"
    device_id=$(grep -o '"device_id"[[:space:]]*:[[:space:]]*"[^"]*"' "${CREDENTIALS_PATH}" | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
    api_key=$(grep -o '"api_key"[[:space:]]*:[[:space:]]*"[^"]*"' "${CREDENTIALS_PATH}" | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
  fi

  if [[ -z "${device_id:-}" || -z "${api_key:-}" ]]; then
    log_error "Could not read device_id and api_key from ${CREDENTIALS_PATH}"
    exit 1
  fi

  log_info "Using device_id from headless setup (must exist in devices table)"

  # Docker login: username=device_id, password=api_key (validated by registry)
  log_info "Logging into registry ${CI_REGISTRY_HOST} with device credentials..."
  echo "${api_key}" | docker login "${CI_REGISTRY_HOST}" --username "${device_id}" --password-stdin

  log_info "Pulling ${HUB_IMAGE}..."
  docker pull "${HUB_IMAGE}"

  # Ensure env file directory exists and write device env
  mkdir -p "$(dirname "${HUB_ENV_FILE}")"
  if [[ -f "${HUB_ENV_FILE}" ]]; then
    # Remove existing DEVICE_ID and CI_HUB_API_KEY lines so we can append fresh
    sed -i '/^DEVICE_ID=/d' "${HUB_ENV_FILE}" 2>/dev/null || true
    sed -i '/^CI_HUB_API_KEY=/d' "${HUB_ENV_FILE}" 2>/dev/null || true
  fi
  echo "DEVICE_ID=${device_id}" >> "${HUB_ENV_FILE}"
  echo "CI_HUB_API_KEY=${api_key}" >> "${HUB_ENV_FILE}"
  log_success "Wrote DEVICE_ID and CI_HUB_API_KEY to ${HUB_ENV_FILE}"

  if [[ -n "${HUB_COMPOSE_PATH:-}" && -f "${HUB_COMPOSE_PATH}" ]]; then
    log_info "Starting stack with docker-compose: ${HUB_COMPOSE_PATH}"
    # Ensure compose uses our env file
    export ENV_FILE="${HUB_ENV_FILE}"
    docker compose -f "${HUB_COMPOSE_PATH}" --env-file "${HUB_ENV_FILE}" up -d
    log_success "Stack started. Hub will use DEVICE_ID and CI_HUB_API_KEY from env."
  else
    log_success "Image pulled and env prepared."
    log_info "To run the Hub, use a compose file that mounts ENV_FILE=${HUB_ENV_FILE} or pass:"
    log_info "  -e DEVICE_ID=${device_id} -e CI_HUB_API_KEY=<redacted>"
    log_info "Example (if you have a compose file):"
    log_info "  HUB_COMPOSE_PATH=/path/to/docker-compose.yml $0"
    log_info "Or run the container manually with the above -e flags and your existing compose stack."
    log_info "When running from source (not Docker), set DEVICE_ID and CI_HUB_API_KEY in env then: bun run start:prod"
  fi
}

main "$@"
