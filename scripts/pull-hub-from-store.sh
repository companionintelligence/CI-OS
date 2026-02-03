#!/usr/bin/env bash
#=============================================================================
# Fetch CI-OS-Hub install payload in one request, then pull and run the stack.
#
# Single request: GET ${API_BASE_URL}/store/ci-os-hub/install (no auth required)
# returns compose + config. Image pull uses Docker Registry (multiple requests;
# auth = REGISTRY_USERNAME + REGISTRY_PASSWORD for docker login).
#
# Usage:
#   ./pull-hub-from-store.sh
#
# Required env (for docker pull):
#   REGISTRY_USERNAME  - registry Basic Auth user (staging registry)
#   REGISTRY_PASSWORD  - registry Basic Auth password
#
# Optional env:
#   API_BASE_URL       - store API base (default: https://setup.companionintel.com/api)
#   HUB_INSTALL_DIR    - where to write compose + config (default: ./ci-os-hub-install)
#   x-device-id        - set DEVICE_ID to send header X-Device-Id on the install request
#   DEVICE_ID          - if set, sent as X-Device-Id on GET install
#   CI_CLOUD_API_URL   - written into .env for the Hub (default: same host as API_BASE_URL)
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

API_BASE_URL="${API_BASE_URL:-https://setup.companionintel.com/api}"
HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-${SCRIPT_DIR}/ci-os-hub-install}"
# Registry host = API host (same origin for /api and /v2)
REGISTRY_HOST="${REGISTRY_HOST:-$(echo "${API_BASE_URL}" | sed -E 's|https?://([^/]+).*|\1|')}"

main() {
  log_info "Fetching CI-OS-Hub install payload (single GET request)..."
  local install_url="${API_BASE_URL}/store/ci-os-hub/install"
  local headers=()
  if [[ -n "${DEVICE_ID:-}" ]]; then
    headers+=(-H "x-device-id: ${DEVICE_ID}")
  fi
  local resp
  if [[ ${#headers[@]} -gt 0 ]]; then
    resp=$(curl -sS -w "\n%{http_code}" "${headers[@]}" "${install_url}")
  else
    resp=$(curl -sS -w "\n%{http_code}" "${install_url}")
  fi
  local http_code
  http_code=$(echo "${resp}" | tail -n1)
  local body
  body=$(echo "${resp}" | sed '$d')
  if [[ "${http_code}" != "200" ]]; then
    log_error "GET ${install_url} returned ${http_code}"
    echo "${body}" | head -c 500
    exit 1
  fi

  if ! command -v jq &>/dev/null; then
    log_error "jq is required to parse the install response. Install jq or set HUB_INSTALL_DIR and parse manually."
    exit 1
  fi
  mkdir -p "${HUB_INSTALL_DIR}"
  echo "${body}" | jq -r '.files["docker-compose.json"]' > "${HUB_INSTALL_DIR}/docker-compose.json"
  echo "${body}" | jq -r '.files["config.json"]'   > "${HUB_INSTALL_DIR}/config.json"
  log_success "Wrote docker-compose.json and config.json to ${HUB_INSTALL_DIR}"

  if [[ -z "${REGISTRY_USERNAME:-}" || -z "${REGISTRY_PASSWORD:-}" ]]; then
    log_warning "REGISTRY_USERNAME or REGISTRY_PASSWORD not set. Skipping docker login and compose."
    log_info "Set them and run: docker login ${REGISTRY_HOST} -u \$REGISTRY_USERNAME -p \$REGISTRY_PASSWORD"
    log_info "Then: docker compose -f ${HUB_INSTALL_DIR}/docker-compose.json --env-file ${HUB_INSTALL_DIR}/.env up -d"
    exit 0
  fi

  log_info "Logging into registry ${REGISTRY_HOST}..."
  echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password-stdin

  # Minimal .env for compose (paths and CI_CLOUD_API_URL)
  local internal="${HUB_INSTALL_DIR}/.internal"
  mkdir -p "${internal}"/{media,state,repos,apps,logs,user-config,app-data,backups,cache}
  local env_file="${HUB_INSTALL_DIR}/.env"
  local ci_cloud_api="${CI_CLOUD_API_URL:-${API_BASE_URL}}"
  # ENV_FILE=.env so compose (run from HUB_INSTALL_DIR) mounts .env into the container
  cat > "${env_file}" << EOF
RUNTIPI_MEDIA_PATH=${HUB_INSTALL_DIR}/.internal
RUNTIPI_STATE_PATH=${HUB_INSTALL_DIR}/.internal
RUNTIPI_REPOS_PATH=${HUB_INSTALL_DIR}/.internal
RUNTIPI_APPS_PATH=${HUB_INSTALL_DIR}/.internal
RUNTIPI_LOGS_PATH=${HUB_INSTALL_DIR}/.internal
RUNTIPI_USER_CONFIG_PATH=${HUB_INSTALL_DIR}/.internal
RUNTIPI_APP_DATA_PATH=${HUB_INSTALL_DIR}/.internal
RUNTIPI_BACKUPS_PATH=${HUB_INSTALL_DIR}/.internal
ENV_FILE=.env
ROOT_FOLDER_HOST=${HUB_INSTALL_DIR}/.internal
CI_CLOUD_API_URL=${ci_cloud_api}
POSTGRES_PASSWORD=postgres
POSTGRES_USERNAME=tipi
POSTGRES_DBNAME=tipi
RABBITMQ_USERNAME=tipi
RABBITMQ_PASSWORD=tipi
EOF
  if [[ -n "${DEVICE_ID:-}" ]]; then
    echo "DEVICE_ID=${DEVICE_ID}" >> "${env_file}"
  fi
  if [[ -n "${CI_HUB_API_KEY:-}" ]]; then
    echo "CI_HUB_API_KEY=${CI_HUB_API_KEY}" >> "${env_file}"
  fi
  log_info "Wrote ${env_file}"

  log_info "Starting stack with docker compose..."
  (cd "${HUB_INSTALL_DIR}" && docker compose -f docker-compose.json --env-file .env up -d)
  log_success "CI-OS-Hub stack is starting. Hub API: http://localhost:5002"
}

main "$@"
