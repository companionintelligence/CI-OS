#!/usr/bin/env bash
#=============================================================================
# Daemon: watch for user pairing code, run GET/POST verification, save
# credentials, then start CI-OS-Hub. Run as setup-pairing-verify-hub.service.
#
# Reads: /etc/setup-device/device.conf (CI_CLOUD_API_URL, REGISTRY_USERNAME,
#        REGISTRY_PASSWORD), /var/lib/setup-device/user_pairing_code.json
# Writes: /var/lib/setup-device/cloud_credentials.json
# Calls: /usr/local/bin/setup-start-ci-os-hub.sh after successful verification
#=============================================================================

set -euo pipefail

DATA_DIR="${DATA_DIR:-/var/lib/setup-device}"
USER_PAIRING_CODE_JSON="${DATA_DIR}/user_pairing_code.json"
CREDENTIALS_JSON="${DATA_DIR}/cloud_credentials.json"
CACHED_DEVICE_ID_FILE="${DATA_DIR}/cached_device_id"
CONFIG_FILE="${CONFIG_FILE:-/etc/setup-device/device.conf}"
PAIR_RETRIES=3
POLL_INTERVAL=10
CONNECTIVITY_WAIT_MAX=120
CONNECTIVITY_CHECK_INTERVAL=5
# After verification failure, wait this long before retrying same code (avoids hammering cloud every 10s)
FAILURE_BACKOFF=60

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-pairing-verify-hub -p info
}

log_err() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-pairing-verify-hub -p err
}

read_conf() {
  local key="$1"
  if [[ -f "${CONFIG_FILE}" ]]; then
    grep -E "^[[:space]]*${key}=.*" "${CONFIG_FILE}" 2>/dev/null | head -1 | sed -E "s/^[^=]+=[[:space]]*['\"]?([^'\"]*)['\"]?/\1/"
  fi
}

get_base_url() {
  local url
  url="${CI_CLOUD_API_URL:-$(read_conf CI_CLOUD_API_URL)}"
  url="${url:-https://setup.companionintel.com}"
  url="${url%/}"
  if [[ "${url}" == */api ]]; then
    url="${url%/api}"
  fi
  echo "${url}"
}

get_device_id() {
  # Use cached value if present (avoids repeated dmidecode/sudo every poll)
  if [[ -f "${CACHED_DEVICE_ID_FILE:-}" && -s "${CACHED_DEVICE_ID_FILE}" ]]; then
    cat "${CACHED_DEVICE_ID_FILE}"
    return
  fi
  local id
  id=$(sudo dmidecode -s system-serial-number 2>/dev/null || true)
  if [[ -n "${id:-}" && "${id}" != "Not Specified" && "${id}" != "To be filled by O.E.M." ]]; then
    mkdir -p "${DATA_DIR}"
    printf '%s' "${id}" > "${CACHED_DEVICE_ID_FILE}"
    echo "${id}"
    return
  fi
  id=$(sudo dmidecode -s system-uuid 2>/dev/null || true)
  if [[ -n "${id:-}" && "${id}" != "Not Specified" ]]; then
    mkdir -p "${DATA_DIR}"
    printf '%s' "${id}" > "${CACHED_DEVICE_ID_FILE}"
    echo "${id}"
    return
  fi
  if [[ -f /etc/machine-id ]]; then
    id=$(cat /etc/machine-id 2>/dev/null || true)
    if [[ -n "${id:-}" ]]; then
      mkdir -p "${DATA_DIR}"
      printf '%s' "${id}" > "${CACHED_DEVICE_ID_FILE}"
      echo "${id}"
      return
    fi
  fi
  id="unknown-device-$(hostname)"
  mkdir -p "${DATA_DIR}"
  printf '%s' "${id}" > "${CACHED_DEVICE_ID_FILE}"
  echo "${id}"
}

normalize_code() {
  echo "$1" | tr -dc 'A-Za-z0-9' | tr '[:lower:]' '[:upper:]'
}

# Wait for internet connectivity (device may be switching from captive hotspot to user WiFi).
# Returns 0 when connectivity is available, 1 if timeout.
wait_for_connectivity() {
  local waited=0
  while [[ "${waited}" -lt "${CONNECTIVITY_WAIT_MAX}" ]]; do
    if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
      log "Connectivity available (waited ${waited}s)"
      return 0
    fi
    sleep "${CONNECTIVITY_CHECK_INTERVAL}"
    waited=$((waited + CONNECTIVITY_CHECK_INTERVAL))
  done
  log_err "No connectivity after ${CONNECTIVITY_WAIT_MAX}s; will retry on next poll"
  return 1
}

run_verification() {
  local code="$1"
  local base_url="$2"
  local pair_url="${base_url}/api/devices/pair"
  local device_id
  local get_code get_status get_body post_status post_body i

  # GET: check device exists (log response body/snippet for troubleshooting)
  local get_url
  get_url="${pair_url}?pairing_code=${code}"
  get_body=$(curl -sS -w "\n%{http_code}" "${get_url}" 2>/dev/null || true)
  get_status=$(echo "${get_body}" | tail -n1)
  local get_body_json
  get_body_json=$(echo "${get_body}" | sed '$d' || true)
  log "GET ${get_url} returned ${get_status}"
  if [[ -n "${get_body_json}" ]]; then
    # Log a short snippet (first 1000 chars) to avoid huge logs
    local snippet
    snippet=$(echo "${get_body_json}" | tr '\n' ' ' | head -c 1000)
    log "GET response snippet: ${snippet}"
  fi
  if [[ "${get_status}" != "200" ]]; then
    log_err "GET ${get_url} returned ${get_status}; pairing code invalid or not found"
    return 1
  fi

  device_id=$(get_device_id)
  log "Device ID: ${device_id}"

  # POST: update device_id (retry up to 3 times)
  for i in $(seq 1 "${PAIR_RETRIES}"); do
    post_body=$(curl -sS -w "\n%{http_code}" -X POST "${pair_url}" \
      -H "Content-Type: application/json" \
      -d "{\"pairing_code\":\"${code}\",\"device_id\":\"${device_id}\"}" 2>/dev/null || true)
    post_status=$(echo "${post_body}" | tail -n1)
    if [[ "${post_status}" == "200" ]]; then
      break
    fi
    # Log status and snippet for debugging
    local post_body_json
    post_body_json=$(echo "${post_body}" | sed '$d' || true)
    local post_snippet
    post_snippet=$(echo "${post_body_json}" | tr '\n' ' ' | head -c 1000)
    log_err "POST ${pair_url} attempt ${i}/${PAIR_RETRIES} returned ${post_status}; response snippet: ${post_snippet}"
    if [[ "${i}" -eq "${PAIR_RETRIES}" ]]; then
      return 1
    fi
    sleep 2
  done

  # Parse apiKey from response (camelCase from cloud)
  local body_json
  body_json=$(echo "${post_body}" | sed '$d')
  local api_key
  api_key=$(echo "${body_json}" | jq -r '.apiKey // .api_key // empty' 2>/dev/null || true)
  if [[ -z "${api_key:-}" ]]; then
    log_err "POST response did not contain apiKey"
    # Log first 200 chars of response for debugging (e.g. wrong API version or proxy)
    local snippet
    snippet=$(echo "${body_json}" | tr '\n' ' ' | head -c 200)
    log_err "POST response snippet: ${snippet}"
    return 1
  fi

  mkdir -p "${DATA_DIR}"
  echo "{\"device_id\":\"${device_id}\",\"api_key\":\"${api_key}\"}" > "${CREDENTIALS_JSON}"
  chmod 600 "${CREDENTIALS_JSON}"
  log "Saved cloud_credentials.json (device_id, api_key)"

  export DEVICE_ID="${device_id}"
  export CI_HUB_API_KEY="${api_key}"
  export API_BASE_URL="${base_url}/api"
  export CI_CLOUD_API_URL="${base_url}"
  export REGISTRY_USERNAME="${REGISTRY_USERNAME:-$(read_conf REGISTRY_USERNAME)}"
  export REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-$(read_conf REGISTRY_PASSWORD)}"
  export HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-/var/lib/ci-os-hub-install}"

  if /usr/local/bin/setup-start-ci-os-hub.sh; then
    log "CI-OS-Hub started successfully"
    # Clear pairing code so we don't re-run until user submits again
    rm -f "${USER_PAIRING_CODE_JSON}"
    return 0
  else
    log_err "setup-start-ci-os-hub.sh failed"
    return 1
  fi
}

main() {
  log "Setup pairing verify and Hub daemon started (polling ${USER_PAIRING_CODE_JSON} every ${POLL_INTERVAL}s)"
  mkdir -p "${DATA_DIR}"
  local last_code_tried=""
  local last_failure_ts=0

  while true; do
    if [[ -f "${USER_PAIRING_CODE_JSON}" ]]; then
      code=$(jq -r '.code // empty' "${USER_PAIRING_CODE_JSON}" 2>/dev/null || true)
      code=$(normalize_code "${code}")
      if [[ -n "${code}" && "${#code}" -ge 4 ]]; then
        # Only run verification when code changed or FAILURE_BACKOFF seconds since last failure
        local now_ts
        now_ts=$(date +%s 2>/dev/null || echo 0)
        if [[ "${code}" != "${last_code_tried}" ]] || [[ $((now_ts - last_failure_ts)) -ge "${FAILURE_BACKOFF}" ]]; then
          base_url=$(get_base_url)
          if [[ "${code}" != "${last_code_tried}" ]]; then
            log "Pairing code found; waiting for connectivity before verification (base_url=${base_url})"
          fi
          if wait_for_connectivity; then
            if run_verification "${code}" "${base_url}"; then
              log "Verification and Hub start completed"
              last_code_tried=""
              last_failure_ts=0
            else
              log "Verification or Hub start failed; will retry in ${FAILURE_BACKOFF}s or when pairing code changes"
              last_code_tried="${code}"
              last_failure_ts=$(date +%s 2>/dev/null || echo 0)
            fi
          else
            last_code_tried="${code}"
            last_failure_ts=$(date +%s 2>/dev/null || echo 0)
          fi
        fi
      fi
    else
      last_code_tried=""
    fi
    sleep "${POLL_INTERVAL}"
  done
}

main "$@"
