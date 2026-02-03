#!/usr/bin/env bash
#=============================================================================
# Fetch CI-OS-Hub install payload, write .env (device_id, api_key, JWT_SECRET,
# defaults with device paths), docker login, and docker compose up.
#
# Expects env: DEVICE_ID, CI_HUB_API_KEY, API_BASE_URL (or CI_CLOUD_API_URL),
#             REGISTRY_USERNAME, REGISTRY_PASSWORD (for docker pull),
#             HUB_INSTALL_DIR (default: /var/lib/ci-os-hub-install)
# Or reads: /var/lib/setup-device/cloud_credentials.json, /etc/setup-device/device.conf
#=============================================================================

set -euo pipefail

DATA_DIR="${DATA_DIR:-/var/lib/setup-device}"
CREDENTIALS_JSON="${DATA_DIR}/cloud_credentials.json"
CONFIG_FILE="${CONFIG_FILE:-/etc/setup-device/device.conf}"
HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-/var/lib/ci-os-hub-install}"
HUB_DATA_DIR="${HUB_DATA_DIR:-/var/lib/ci-os-hub}"
INTERNAL="${HUB_DATA_DIR}/.internal"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-start-ci-os-hub -p info
}

log_err() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | systemd-cat -t setup-start-ci-os-hub -p err
}

read_conf() {
  local key="$1"
  if [[ -f "${CONFIG_FILE}" ]]; then
    grep -E "^[[:space]]*${key}=.*" "${CONFIG_FILE}" 2>/dev/null | head -1 | sed -E "s/^[^=]+=[[:space]]*['\"]?([^'\"]*)['\"]?/\1/"
  fi
}

# Load credentials from file if not in env
if [[ -z "${DEVICE_ID:-}" || -z "${CI_HUB_API_KEY:-}" ]]; then
  if [[ -f "${CREDENTIALS_JSON}" ]]; then
    if command -v jq &>/dev/null; then
      DEVICE_ID="${DEVICE_ID:-$(jq -r '.device_id // empty' "${CREDENTIALS_JSON}")}"
      CI_HUB_API_KEY="${CI_HUB_API_KEY:-$(jq -r '.api_key // empty' "${CREDENTIALS_JSON}")}"
    fi
  fi
fi

API_BASE_URL="${API_BASE_URL:-${CI_CLOUD_API_URL:-$(read_conf CI_CLOUD_API_URL)}}"
API_BASE_URL="${API_BASE_URL:-https://setup.companionintel.com}"
API_BASE_URL="${API_BASE_URL%/}"
if [[ "${API_BASE_URL}" != */api ]]; then
  API_BASE_URL="${API_BASE_URL}/api"
fi
REGISTRY_HOST="${REGISTRY_HOST:-$(echo "${API_BASE_URL}" | sed -E 's|https?://([^/]+).*|\1|')}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-$(read_conf REGISTRY_USERNAME)}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-$(read_conf REGISTRY_PASSWORD)}"
CI_CLOUD_API_URL="${CI_CLOUD_API_URL:-${API_BASE_URL%/api}}"
CI_CLOUD_URL="${CI_CLOUD_URL:-${CI_CLOUD_API_URL}}"

if [[ -z "${DEVICE_ID:-}" || -z "${CI_HUB_API_KEY:-}" ]]; then
  log_err "DEVICE_ID and CI_HUB_API_KEY required (from env or ${CREDENTIALS_JSON})"
  exit 1
fi

# JWT_SECRET: generate once per device (from machine-id or api_key)
if [[ -z "${JWT_SECRET:-}" ]]; then
  if [[ -f /etc/machine-id ]]; then
    JWT_SECRET=$(cat /etc/machine-id | tr -d '\n' | openssl dgst -sha256 -binary 2>/dev/null | base64 | tr -d '\n' | head -c 64) || true
  fi
  if [[ -z "${JWT_SECRET:-}" ]]; then
    JWT_SECRET=$(echo -n "${CI_HUB_API_KEY}" | openssl dgst -sha256 -binary 2>/dev/null | base64 | tr -d '\n' | head -c 64) || true
  fi
  JWT_SECRET="${JWT_SECRET:-857ad2225d62961ba24b12ee88b4a628e1647a0c61d5113f313f56f22461d0c3}"
fi

# Detect architecture
ARCH=$(uname -m)
if [[ "${ARCH}" == "aarch64" || "${ARCH}" == "arm64" ]]; then
  TARGETARCH=arm64
  DOCKER_PLATFORM=linux/arm64
else
  TARGETARCH=amd64
  DOCKER_PLATFORM=linux/amd64
fi

log "Fetching CI-OS-Hub install payload from ${API_BASE_URL}/store/ci-os-hub/install"
install_url="${API_BASE_URL}/store/ci-os-hub/install"
resp=$(curl -sS -w "\n%{http_code}" -H "x-device-id: ${DEVICE_ID}" "${install_url}" 2>/dev/null || true)
http_code=$(echo "${resp}" | tail -n1)
body=$(echo "${resp}" | sed '$d')
if [[ "${http_code}" != "200" ]]; then
  log_err "GET ${install_url} returned ${http_code}"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  log_err "jq is required"
  exit 1
fi

mkdir -p "${HUB_INSTALL_DIR}"
echo "${body}" | jq -r '.files["docker-compose.json"]' > "${HUB_INSTALL_DIR}/docker-compose.json"
echo "${body}" | jq -r '.files["config.json"]' > "${HUB_INSTALL_DIR}/config.json"
log "Wrote docker-compose.json and config.json to ${HUB_INSTALL_DIR}"

# Registry auth: optional. If REGISTRY_USERNAME/PASSWORD are set (env or device.conf), use them for docker login.
# If not set, skip login and try pull anyway (registry may allow anonymous pull).
if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
  log "Logging into registry ${REGISTRY_HOST}"
  if ! echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password-stdin 2>/dev/null; then
    log_err "docker login failed for ${REGISTRY_HOST}"
    exit 1
  fi
else
  log "No REGISTRY_USERNAME/PASSWORD set; attempting pull without login (anonymous pull if registry allows)"
fi

mkdir -p "${INTERNAL}"/{media,state,repos,apps,logs,user-config,app-data,backups,cache}
env_file="${HUB_INSTALL_DIR}/.env"

# Default env for Hub (device paths and user-provided defaults)
cat > "${env_file}" << EOF
LOG_LEVEL=info
NODE_ENV=development
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
CLOUDFLARE_TUNNEL_ID=
CLOUDFLARE_ZONE_ID=
CI_CLOUD_APP_STORE_URL=${CI_CLOUD_URL}/web/download-app-store
CI_CLOUD_FRONTEND_URL=${CI_CLOUD_URL}
ORGANIZATION_SUBDOMAIN=b2
PLATFORM=linux
DOCKER_PLATFORM=${DOCKER_PLATFORM}
TARGETARCH=${TARGETARCH}
ROOT_FOLDER_HOST=${INTERNAL}
INTERNAL_IP=0.0.0.0
RUNTIPI_MEDIA_PATH=${INTERNAL}
RUNTIPI_STATE_PATH=${INTERNAL}
RUNTIPI_REPOS_PATH=${INTERNAL}
RUNTIPI_APPS_PATH=${INTERNAL}
RUNTIPI_LOGS_PATH=${INTERNAL}
RUNTIPI_USER_CONFIG_PATH=${INTERNAL}
RUNTIPI_APP_DATA_PATH=${INTERNAL}
RUNTIPI_BACKUPS_PATH=${INTERNAL}
APPS_REPO_ID=29ca930bfdaffa1dfabf5726336380ede7066bc53297e3c0c868b27c97282903
APPS_REPO_URL=https://github.com/runtipi/runtipi-appstore
TZ=UTC
DNS_IP=9.9.9.9
ARCHITECTURE=${TARGETARCH}
JWT_SECRET=${JWT_SECRET}
DOMAIN=setup.companionintel.com
LOCAL_DOMAIN=setup.companionintel.com
POSTGRES_HOST=ci-hub-db
POSTGRES_DBNAME=tipi
POSTGRES_USERNAME=tipi
POSTGRES_PASSWORD=postgres
POSTGRES_PORT=6543
RABBITMQ_HOST=ci-os-hub-queue
RABBITMQ_USERNAME=tipi
RABBITMQ_PASSWORD=tipi
RUNTIPI_FORWARD_AUTH_URL=http://ci-os-hub:3000/api/auth/traefik
DEMO_MODE=false
GUEST_DASHBOARD=false
ALLOW_AUTO_THEMES=true
ALLOW_ERROR_MONITORING=false
PERSIST_TRAEFIK_CONFIG=true
QUEUE_TIMEOUT_IN_MINUTES=5
MAX_BACKUPS=10
ADVANCED_SETTINGS=true
EXPERIMENTAL_INSECURE_COOKIE=false
THEME_BASE=stone
THEME_COLOR=teal
TIPI_VERSION=4.5.0
LOCAL=false
DISABLE_PASSWORD_RESET=true
CI_CLOUD_API_URL=${CI_CLOUD_API_URL}
CI_CLOUD_URL=${CI_CLOUD_URL}
CI_HUB_ORGANIZATION_ID=
CI_HUB_API_KEY=${CI_HUB_API_KEY}
DEVICE_ID=${DEVICE_ID}
MAX_BACKUPS=0
NGINX_PORT=80
NGINX_PORT_SSL=443
ENV_FILE=.env
EOF

chmod 600 "${env_file}"
log "Wrote ${env_file}"

log "Starting CI-OS-Hub stack with docker compose..."
(cd "${HUB_INSTALL_DIR}" && docker compose -f docker-compose.json --env-file .env up -d)
log "CI-OS-Hub stack started. Hub API: http://localhost:5002"
