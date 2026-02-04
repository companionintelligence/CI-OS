#!/usr/bin/env bash
#=============================================================================
# Install and run CI-OS-Hub from the store (recommended) or pull image and prepare env.
#
# Install mode (default): GET store/ci-os-hub/install with device_id + api_key,
# write docker-compose.json + config.json, docker login if needed, then docker compose up -d.
#
# Requires: device_id and api_key from headless setup (cloud_credentials.json).
#
# Usage:
#   ./pull-and-run-ci-os-hub.sh              # install from store, then start (default)
#   ./pull-and-run-ci-os-hub.sh --pull-only  # legacy: pull image + write env only
#
# Optional env:
#   CREDENTIALS_PATH   - path to cloud_credentials.json
#                        (default: /var/lib/setup-device/cloud_credentials.json)
#   CI_CLOUD_URL       - store base URL for install (default: https://setup.companionintel.com)
#   CI_REGISTRY_HOST   - registry host for docker login (default: app.ci.computer)
#   HUB_ENV_FILE       - path to .env for DEVICE_ID and CI_HUB_API_KEY
#                        (default: /var/lib/ci-os-hub/.env)
#   HUB_APP_DIR        - where to write compose + config and run from (default: /var/lib/ci-os-hub/app)
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CREDENTIALS_PATH="${CREDENTIALS_PATH:-/var/lib/setup-device/cloud_credentials.json}"
CI_CLOUD_URL="${CI_CLOUD_URL:-https://setup.companionintel.com}"
CI_REGISTRY_HOST="${CI_REGISTRY_HOST:-app.ci.computer}"
HUB_IMAGE="${CI_REGISTRY_HOST}/ci-os-hub:latest"
HUB_ENV_FILE="${HUB_ENV_FILE:-/var/lib/ci-os-hub/.env}"
HUB_APP_DIR="${HUB_APP_DIR:-/var/lib/ci-os-hub/app}"
CI_CLOUD_BASE="${CI_CLOUD_URL%/api}"
INSTALL_URL="${CI_CLOUD_BASE}/api/store/ci-os-hub/install"

pull_only=false
for arg in "$@"; do
  if [[ "$arg" == "--pull-only" ]]; then pull_only=true; break; fi
done

read_credentials() {
  if [[ ! -f "${CREDENTIALS_PATH}" ]]; then
    log_error "Credentials file not found: ${CREDENTIALS_PATH}"
    log_info "Run headless setup first so device_id and api_key are saved here."
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
  echo "${device_id}"
  echo "${api_key}"
}

install_from_store() {
  local device_id="$1" api_key="$2"
  log_info "Fetching install from ${INSTALL_URL}"
  local resp
  resp=$(curl -sS -f -H "x-device-id: ${device_id}" -H "x-api-key: ${api_key}" "${INSTALL_URL}") || {
    log_error "Install request failed (check device_id and api_key)"
    exit 1
  }
  local compose_str config_str
  compose_str=$(echo "${resp}" | jq -r '.files["docker-compose.json"] // empty')
  config_str=$(echo "${resp}" | jq -r '.files["config.json"] // empty')
  if [[ -z "${compose_str}" || "${compose_str}" == "null" ]]; then
    log_error "No docker-compose.json in install response"
    exit 1
  fi
  # Docker Compose expects services to be object (name -> config), not array; convert if needed
  compose_str=$(echo "${compose_str}" | jq '
    if .services | type == "array" then
      .services |= ([.services | to_entries[] | {key: (.value.name // "svc_\(.key)"), value: (.value | del(.name))}] | from_entries)
    else . end
  ')
  mkdir -p "${HUB_APP_DIR}"
  echo "${compose_str}" > "${HUB_APP_DIR}/docker-compose.json"
  if [[ -n "${config_str}" && "${config_str}" != "null" ]]; then
    echo "${config_str}" > "${HUB_APP_DIR}/config.json"
  fi
  # Detect registry host from first service image (compose already converted to object)
  local image
  image=$(echo "${compose_str}" | jq -r '.services | to_entries[0].value.image // empty')
  if [[ -n "${image}" ]]; then
    if [[ "${image}" == setup.companionintel.com/* ]] || [[ "${image}" == app.ci.computer/* ]] || [[ "${image}" == setup.companionintelligence.com/* ]]; then
      local reg_host="${image%%/*}"
      log_info "Logging into registry ${reg_host}"
      echo "${api_key}" | docker login "${reg_host}" --username "${device_id}" --password-stdin
    fi
  fi
  mkdir -p "$(dirname "${HUB_ENV_FILE}")"
  echo "DEVICE_ID=${device_id}" > "${HUB_ENV_FILE}"
  echo "CI_HUB_API_KEY=${api_key}" >> "${HUB_ENV_FILE}"
  log_info "Starting stack with docker compose in ${HUB_APP_DIR}"
  (cd "${HUB_APP_DIR}" && docker compose -f docker-compose.json --env-file "${HUB_ENV_FILE}" up -d)
  log_success "CI-OS-Hub started from store install."
}

main() {
  local creds
  creds=$(read_credentials)
  local device_id api_key
  device_id=$(echo "${creds}" | sed -n '1p')
  api_key=$(echo "${creds}" | sed -n '2p')

  if [[ "$pull_only" == "true" ]]; then
    log_info "Pull-only mode: pull image and write env (no install from store)"
    if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
      echo "${REGISTRY_PASSWORD}" | docker login "${CI_REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password-stdin
    else
      echo "${api_key}" | docker login "${CI_REGISTRY_HOST}" --username "${device_id}" --password-stdin
    fi
    docker pull "${HUB_IMAGE}"
    mkdir -p "$(dirname "${HUB_ENV_FILE}")"
    if [[ -f "${HUB_ENV_FILE}" ]]; then
      sed -i '/^DEVICE_ID=/d' "${HUB_ENV_FILE}" 2>/dev/null || true
      sed -i '/^CI_HUB_API_KEY=/d' "${HUB_ENV_FILE}" 2>/dev/null || true
    fi
    echo "DEVICE_ID=${device_id}" >> "${HUB_ENV_FILE}"
    echo "CI_HUB_API_KEY=${api_key}" >> "${HUB_ENV_FILE}"
    log_success "Image pulled and env prepared. Run with: HUB_APP_DIR=/path $0 (install mode) or use your compose."
    return 0
  fi

  install_from_store "${device_id}" "${api_key}"
}

main "$@"
