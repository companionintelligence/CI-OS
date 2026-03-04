#!/usr/bin/env bash

# CI OS Hub Staging Installer
# This script downloads and installs CI OS Hub from the CI Cloud staging registry.

set -o errexit
set -o nounset
set -o pipefail

# Ensure we use the default context if Desktop is broken
export DOCKER_CONTEXT=default

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optionally load REGISTRY_USERNAME/PASSWORD (same env as hub:publish:dev)
if [ -z "${REGISTRY_USERNAME:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
  for ENV_DEV in \
    "${CI_OS_HUB_REPO_PATH:-${SCRIPT_DIR}/../CI-OS-Hub}/.env.dev" \
    "${SCRIPT_DIR}/../CI-Cloud/apps/hono-app/.env.dev" \
    "${SCRIPT_DIR}/../CI-Cloud/apps/hono-app/.env"; do
    if [ -f "$ENV_DEV" ]; then
      set -a
      # shellcheck source=/dev/null
      . "$ENV_DEV"
      set +a
      break
    fi
  done
fi

# Hardcoded fallback credentials for dev registry (override with env if needed)
REGISTRY_USERNAME="${REGISTRY_USERNAME:-Abcde12345}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-Abcde12345}"

# Configuration - per-environment when HUB_INSTALL_ENV is set (by pull-staging/pull-prod)
case "${HUB_INSTALL_ENV:-dev}" in
  staging)
    REGISTRY_DOMAIN="${REGISTRY_DOMAIN:-portal.companionintel.com}"
    INSTALL_DIR="${INSTALL_DIR:-${HOME}/ci-os-hub-staging}"
    CI_CLOUD_URL="${CI_CLOUD_URL:-https://portal.companionintel.com}"
    CI_CLOUD_API_URL="${CI_CLOUD_API_URL:-https://portal.companionintel.com/api}"
    CI_CLOUD_FRONTEND_URL="${CI_CLOUD_FRONTEND_URL:-https://portal.companionintel.com}"
    ;;
  prod)
    REGISTRY_DOMAIN="${REGISTRY_DOMAIN:-portal.ci.computer}"
    INSTALL_DIR="${INSTALL_DIR:-${HOME}/ci-os-hub}"
    CI_CLOUD_URL="${CI_CLOUD_URL:-https://portal.ci.computer}"
    CI_CLOUD_API_URL="${CI_CLOUD_API_URL:-https://portal.ci.computer/api}"
    CI_CLOUD_FRONTEND_URL="${CI_CLOUD_FRONTEND_URL:-https://portal.ci.computer}"
    ;;
  *)
    REGISTRY_DOMAIN="${REGISTRY_DOMAIN:-portal.companionintelligence.com}"
    INSTALL_DIR="${INSTALL_DIR:-${HOME}/ci-os-hub-staging}"
    CI_CLOUD_URL="${CI_CLOUD_URL:-https://portal.companionintelligence.com}"
    CI_CLOUD_API_URL="${CI_CLOUD_API_URL:-https://portal.companionintelligence.com/api}"
    CI_CLOUD_FRONTEND_URL="${CI_CLOUD_FRONTEND_URL:-https://portal.companionintelligence.com}"
    ;;
esac

IMAGE_NAME="${IMAGE_NAME:-${REGISTRY_DOMAIN}/ci-os-hub:latest}"
INTERNAL_DIR="${INSTALL_DIR}/.internal"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

HUB_ENV_LABEL="${HUB_INSTALL_ENV:-Staging}"
echo -e "${GREEN}Starting CI OS Hub ${HUB_ENV_LABEL} Installation...${NC}"
echo -e "Registry: ${REGISTRY_DOMAIN}"
echo -e "Image: ${IMAGE_NAME}"
echo ""

# Check prerequisites
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: docker is not installed.${NC}"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo -e "${RED}Error: docker compose is not available.${NC}"
    exit 1
fi

# Prepare Installation Directory
echo -e "${YELLOW}Creating installation directory at ${INSTALL_DIR}...${NC}"
mkdir -p "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/data/media"
mkdir -p "${INSTALL_DIR}/data/state/traefik/config"
mkdir -p "${INSTALL_DIR}/data/state/traefik/dynamic"
mkdir -p "${INSTALL_DIR}/data/state/traefik/tls"
mkdir -p "${INSTALL_DIR}/data/repos"
mkdir -p "${INSTALL_DIR}/data/apps"
mkdir -p "${INSTALL_DIR}/data/logs"
mkdir -p "${INSTALL_DIR}/data/user-config"
mkdir -p "${INSTALL_DIR}/data/backups"
mkdir -p "${INSTALL_DIR}/app-data"
mkdir -p "${INSTALL_DIR}/tunnel"
mkdir -p "${INSTALL_DIR}/tunnel/certs"

# Prepare absolute .internal host paths for Hub/app runtime data
mkdir -p "${INTERNAL_DIR}"
mkdir -p "${INTERNAL_DIR}/media"
mkdir -p "${INTERNAL_DIR}/state"
mkdir -p "${INTERNAL_DIR}/repos"
mkdir -p "${INTERNAL_DIR}/apps"
mkdir -p "${INTERNAL_DIR}/logs"
mkdir -p "${INTERNAL_DIR}/user-config"
mkdir -p "${INTERNAL_DIR}/backups"
mkdir -p "${INTERNAL_DIR}/app-data"

# Cloudflare tunnel prerequisites (token + local CA certs)
TUNNEL_TOKEN_FILE="${INSTALL_DIR}/tunnel/token"
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
  printf '%s\n' "${CLOUDFLARE_TUNNEL_TOKEN}" > "${TUNNEL_TOKEN_FILE}"
  chmod 600 "${TUNNEL_TOKEN_FILE}"
  echo -e "${GREEN}Cloudflare tunnel token written to ${TUNNEL_TOKEN_FILE}${NC}"
elif [ -f "${TUNNEL_TOKEN_FILE}" ] && [ -s "${TUNNEL_TOKEN_FILE}" ]; then
  echo -e "${GREEN}Using existing Cloudflare tunnel token at ${TUNNEL_TOKEN_FILE}${NC}"
else
  echo -e "${YELLOW}No Cloudflare tunnel token found.${NC}"
  echo -e "${YELLOW}To enable tunnel, set CLOUDFLARE_TUNNEL_TOKEN or create ${TUNNEL_TOKEN_FILE}.${NC}"
  echo -e "${YELLOW}Creating placeholder token so cloudflared container exists for later restart during registration.${NC}"
  printf '%s\n' "pending-registration-token" > "${TUNNEL_TOKEN_FILE}"
  chmod 600 "${TUNNEL_TOKEN_FILE}"
fi

if [ ! -f "${INSTALL_DIR}/tunnel/certs/custom-ca.pem" ] || [ ! -f "${INSTALL_DIR}/tunnel/certs/custom-ca.key" ]; then
  if command -v openssl >/dev/null 2>&1; then
    # Try to use generate-tunnel-certs.sh from ci-os-hub when available (same logic, single source of truth)
    CERT_SCRIPT=""
    for candidate in \
      "${CI_OS_HUB_REPO_PATH:-${SCRIPT_DIR}/../CI-OS-Hub}/scripts/generate-tunnel-certs.sh" \
      "${SCRIPT_DIR}/../ci-os-hub/scripts/generate-tunnel-certs.sh"; do
      if [ -f "$candidate" ]; then
        CERT_SCRIPT="$candidate"
        break
      fi
    done
    if [ -n "${CERT_SCRIPT}" ]; then
      echo -e "${YELLOW}Generating tunnel certificates via ${CERT_SCRIPT}...${NC}"
      bash "$CERT_SCRIPT" "${INSTALL_DIR}" && echo -e "${GREEN}Tunnel certificates generated.${NC}"
    else
      echo -e "${YELLOW}Generating tunnel certificates in ${INSTALL_DIR}/tunnel/certs...${NC}"
      openssl genrsa -out "${INSTALL_DIR}/tunnel/certs/custom-ca.key" 2048
      openssl req -x509 -new -nodes \
        -key "${INSTALL_DIR}/tunnel/certs/custom-ca.key" \
        -sha256 -days 3650 \
        -out "${INSTALL_DIR}/tunnel/certs/custom-ca.pem" \
        -subj "/C=US/ST=State/L=City/O=CompanionIntelligence/OU=LocalDev/CN=CI-Local-Root-CA"
      chmod 644 "${INSTALL_DIR}/tunnel/certs/custom-ca.pem"
      chmod 600 "${INSTALL_DIR}/tunnel/certs/custom-ca.key"
      echo -e "${GREEN}Tunnel certificates generated.${NC}"
    fi
  else
    echo -e "${YELLOW}openssl not found. Skipping tunnel certificate generation.${NC}"
  fi
else
  echo -e "${GREEN}Using existing tunnel certificates in ${INSTALL_DIR}/tunnel/certs.${NC}"
fi

# Registry Login (required for private registry)
if [ -z "${REGISTRY_USERNAME:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
    echo -e "${YELLOW}Note: Set REGISTRY_USERNAME and REGISTRY_PASSWORD for registry auth.${NC}"
    echo -e "${YELLOW}Example: export REGISTRY_USERNAME=xxx REGISTRY_PASSWORD=xxx${NC}"
fi
echo -e "${YELLOW}Logging in to registry (${REGISTRY_DOMAIN})...${NC}"
if [ -n "${REGISTRY_USERNAME:-}" ] && [ -n "${REGISTRY_PASSWORD:-}" ]; then
    echo "Configuring docker auth manually to bypass registry root 404 issue..."
    # Calculate base64 auth string (user:pass)
    AUTH_STRING=$(echo -n "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" | base64)
    mkdir -p "${HOME}/.docker"
    if [ ! -f "${HOME}/.docker/config.json" ]; then
        echo '{"auths":{}}' > "${HOME}/.docker/config.json"
    fi
    
    # Use jq to update config safely
    if command -v jq >/dev/null; then
        # We delete credsStore to ensure the plain auth is used and not ignored
        jq --arg domain "${REGISTRY_DOMAIN}" --arg auth "${AUTH_STRING}" \
           'del(.credsStore) | .auths[$domain] = { "auth": $auth }' \
           "${HOME}/.docker/config.json" > "${HOME}/.docker/config.json.tmp" && \
           mv "${HOME}/.docker/config.json.tmp" "${HOME}/.docker/config.json"
        echo "Docker auth configured for ${REGISTRY_DOMAIN}"
    else
        echo -e "${RED}Error: jq is required for manual auth configuration.${NC}"
        exit 1
    fi
else
    echo "If you are already logged in, this step will just verify credentials."
    # We attempt docker login, but warn it might fail
    if ! docker login "${REGISTRY_DOMAIN}"; then
        echo -e "${YELLOW}Warning: docker login failed. This might be due to a server issue.${NC}"
        echo -e "${YELLOW}Attempting to proceed anyway (assuming pre-existing credentials works for pull)...${NC}"
    fi
fi

# Generate Traefik Configs
echo -e "${YELLOW}Generating Traefik configuration...${NC}"

# traefik.yml
cat > "${INSTALL_DIR}/data/state/traefik/config/traefik.yml" <<EOF
api:
  dashboard: true
  insecure: true

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    watch: true
    exposedByDefault: false
    useBindPortIP: false
  file:
    directory: /etc/traefik/dynamic
    watch: true

entryPoints:
  web:
    address: ":80"
    transport:
      respondingTimeouts:
        readTimeout: 300s
        writeTimeout: 300s
        idleTimeout: 300s
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: myresolver
    transport:
      respondingTimeouts:
        readTimeout: 300s
        writeTimeout: 300s
        idleTimeout: 300s

certificatesResolvers:
  myresolver:
    acme:
      email: admin@localhost
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web

log:
  level: INFO
  format: json
EOF

# dynamic.yml
cat > "${INSTALL_DIR}/data/state/traefik/dynamic/dynamic.yml" <<EOF
http:
  serversTransports:
    insecuretransport:
      insecureSkipVerify: true

  middlewares:
    runtipi:
      forwardAuth:
        address: "http://ci-os-hub:3000/api/auth/traefik"
        trustForwardHeader: true
        authResponseHeaders:
          - "X-Runtipi-User"
EOF

# acme.json setup
touch "${INSTALL_DIR}/data/state/traefik/acme_storage.json"
chmod 600 "${INSTALL_DIR}/data/state/traefik/acme_storage.json"

# Generate .env file
echo -e "${YELLOW}Generating configuration...${NC}"
if [ -f "${INSTALL_DIR}/.env" ]; then
    echo "Existing .env found, backing up to .env.bak"
    cp "${INSTALL_DIR}/.env" "${INSTALL_DIR}/.env.bak"
fi

# DEVICE_ID: always from system serial (sudo dmidecode -s system-serial-number)
# Try DMI serial, machine-id, or generate a stable fallback
DEVICE_ID=""
if SERIAL=$(sudo dmidecode -s system-serial-number 2>/dev/null); then
    # Filter out placeholder values that aren't real serial numbers
    case "$SERIAL" in
      ""|"Not Specified"|"System Serial Number"|"To be filled by O.E.M."|"Default string"|"None"|"0")
        ;;
      *)
        DEVICE_ID="$SERIAL"
        echo -e "${GREEN}DEVICE_ID from system serial: ${DEVICE_ID}${NC}"
        ;;
    esac
fi
if [ -z "$DEVICE_ID" ] && [ -f /etc/machine-id ]; then
    DEVICE_ID=$(cat /etc/machine-id)
    echo -e "${GREEN}DEVICE_ID from /etc/machine-id: ${DEVICE_ID}${NC}"
fi
if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID="staging-$(hostname)-$(date +%s)"
    echo -e "${YELLOW}No DMI serial or machine-id; using fallback DEVICE_ID: ${DEVICE_ID}${NC}"
fi

CI_CLOUD_API_KEY=${CI_CLOUD_API_KEY:-""}

# Always use user-specific absolute paths under the install .internal directory
ROOT_FOLDER_HOST="${INTERNAL_DIR}"
RUNTIPI_APP_DATA_PATH="${INTERNAL_DIR}"
RUNTIPI_MEDIA_PATH="${INTERNAL_DIR}/media"
RUNTIPI_STATE_PATH="${INTERNAL_DIR}/state"
RUNTIPI_REPOS_PATH="${INTERNAL_DIR}/repos"
RUNTIPI_APPS_PATH="${INTERNAL_DIR}/apps"
RUNTIPI_LOGS_PATH="${INTERNAL_DIR}/logs"
RUNTIPI_USER_CONFIG_PATH="${INTERNAL_DIR}/user-config"
RUNTIPI_BACKUPS_PATH="${INTERNAL_DIR}/backups"

# Service credentials (allow override, enforce sane defaults)
POSTGRES_DBNAME="${POSTGRES_DBNAME:-tipi}"
POSTGRES_USERNAME="${POSTGRES_USERNAME:-tipi}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
RABBITMQ_USERNAME="${RABBITMQ_USERNAME:-tipi}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-tipi}"

# Preserve existing JWT secret if present, otherwise use env or generate securely
EXISTING_JWT_SECRET=""
if [ -f "${INSTALL_DIR}/.env" ]; then
  EXISTING_JWT_SECRET=$(grep -E '^JWT_SECRET=' "${INSTALL_DIR}/.env" | tail -n 1 | cut -d '=' -f2- || true)
fi
JWT_SECRET="${JWT_SECRET:-${EXISTING_JWT_SECRET:-}}"
if [ -z "${JWT_SECRET}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    JWT_SECRET=$(openssl rand -hex 32)
  else
    JWT_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
fi

# Full .env matching production CI OS Hub configuration
cat > "${INSTALL_DIR}/.env" <<ENVEOF
# Application Configuration
LOG_LEVEL=info
NODE_ENV=production
TIPI_VERSION=4.7.0
LOCAL=false

# Docker Compose Override Variables
DB_CONTAINER_NAME=ci-hub-db
QUEUE_CONTAINER_NAME=ci-os-hub-queue
HUB_CONTAINER_NAME=ci-os-hub
TRAEFIK_CONTAINER_NAME=traefik
CLOUDFLARED_CONTAINER_NAME=cloudflared
NETWORK_NAME=ci-os-hub_network
DB_VOLUME_NAME=ci_hub_pgdata
ENV_FILE=.env

# Paths (staging install directory)
ROOT_FOLDER_HOST=${ROOT_FOLDER_HOST}
RUNTIPI_APP_DATA_PATH=${RUNTIPI_APP_DATA_PATH}
RUNTIPI_MEDIA_PATH=${RUNTIPI_MEDIA_PATH}
RUNTIPI_STATE_PATH=${RUNTIPI_STATE_PATH}
RUNTIPI_REPOS_PATH=${RUNTIPI_REPOS_PATH}
RUNTIPI_APPS_PATH=${RUNTIPI_APPS_PATH}
RUNTIPI_LOGS_PATH=${RUNTIPI_LOGS_PATH}
RUNTIPI_USER_CONFIG_PATH=${RUNTIPI_USER_CONFIG_PATH}
RUNTIPI_BACKUPS_PATH=${RUNTIPI_BACKUPS_PATH}
INTERNAL_IP=0.0.0.0

# CI Cloud Integration
CI_CLOUD_URL=${CI_CLOUD_URL}
CI_CLOUD_API_URL=${CI_CLOUD_API_URL}
CI_CLOUD_FRONTEND_URL=${CI_CLOUD_FRONTEND_URL}
CI_CLOUD_API_KEY=${CI_CLOUD_API_KEY}

# Domain Configuration
DOMAIN=companionintelligence.com
LOCAL_DOMAIN=tipi.lan
DNS_IP=9.9.9.9

# Database Configuration
POSTGRES_HOST=ci-hub-db
POSTGRES_DBNAME=${POSTGRES_DBNAME}
POSTGRES_USERNAME=${POSTGRES_USERNAME}
POSTGRES_USER=${POSTGRES_USERNAME}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_PORT=6543

# RabbitMQ Configuration
RABBITMQ_HOST=ci-os-hub-queue
RABBITMQ_USERNAME=${RABBITMQ_USERNAME}
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}

# Traefik Configuration (ci-os-hub uses port 5002 in this setup)
RUNTIPI_FORWARD_AUTH_URL=http://ci-os-hub:3000/api/auth/traefik

# Application Settings
DEMO_MODE=false
GUEST_DASHBOARD=false
ALLOW_AUTO_THEMES=true
ALLOW_ERROR_MONITORING=false
PERSIST_TRAEFIK_CONFIG=false
QUEUE_TIMEOUT_IN_MINUTES=5
MAX_BACKUPS=0
ADVANCED_SETTINGS=false
EXPERIMENTAL_INSECURE_COOKIE=false
THEME_BASE=gray
THEME_COLOR=blue
DISABLE_PASSWORD_RESET=true

# Security
JWT_SECRET=${JWT_SECRET}

# Timezone
TZ=UTC

# Architecture
ARCHITECTURE=amd64

# Device ID
DEVICE_ID=${DEVICE_ID}
ENVEOF

# Generate docker-compose.yml
echo -e "${YELLOW}Generating docker-compose.yml...${NC}"
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  ci-hub-db:
    container_name: \${DB_CONTAINER_NAME:-ci-hub-db}
    image: postgres:14
    restart: unless-stopped
    volumes:
      - ci_hub_pgdata:/var/lib/postgresql/data
    command: -p 6543
    ports:
      - 6543:6543
    environment:
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-postgres}
      POSTGRES_USER: \${POSTGRES_USER:-tipi}
      POSTGRES_DB: \${POSTGRES_DBNAME:-tipi}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d tipi -U tipi -p 6543"]
      interval: 5s
      timeout: 20s
      retries: 10

  ci-os-hub-queue:
    container_name: \${QUEUE_CONTAINER_NAME:-ci-os-hub-queue}
    image: rabbitmq:4-alpine
    restart: unless-stopped
    ports:
      - "5001:5672"
    environment:
      RABBITMQ_DEFAULT_USER: \${RABBITMQ_USERNAME:-tipi}
      RABBITMQ_DEFAULT_PASS: \${RABBITMQ_PASSWORD:-tipi}
      RABBITMQ_FEATURE_FLAGS: ""
    healthcheck:
      test: ["CMD-SHELL", "rabbitmq-diagnostics -q check_running"]
      interval: 15s
      timeout: 30s
      retries: 20
      start_period: 30s

  ci-os-hub:
    container_name: \${HUB_CONTAINER_NAME:-ci-os-hub}
    image: ${IMAGE_NAME}
    restart: unless-stopped
    env_file: .env
    depends_on:
      ci-hub-db:
        condition: service_healthy
      ci-os-hub-queue:
        condition: service_healthy
    ports:
      - "5002:3000"
    volumes:
      - ./tunnel:/app/tunnel
      - ./data/media:/data/media
      - ./data/state:/data/state
      - ./data/repos:/data/repos
      - ./data/apps:/data/apps
      - ./data/logs:/data/logs
      - ./data/user-config:/data/user-config
      - ./app-data:/app-data
      - ./data/backups:/data/backups
      - ./.env:/data/.env:ro
      - ./docker-compose.yml:/app/docker-compose.prod.yml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      traefik.enable: true
      ci-os-hub.managed: true
      traefik.http.middlewares.runtipi.forwardauth.address: "http://ci-os-hub:3000/api/auth/traefik"
      traefik.http.middlewares.runtipi.forwardauth.trustForwardHeader: "true"
      traefik.http.middlewares.runtipi.forwardauth.authResponseHeaders: "X-Runtipi-User"
      traefik.http.routers.ci-os-hub.entrypoints: "web"
      traefik.http.routers.ci-os-hub.rule: "Host(\`ci-os-hub.local\`)"

  traefik:
    image: traefik:v3.6.7
    container_name: \${TRAEFIK_CONTAINER_NAME:-traefik}
    restart: unless-stopped
    command:
      - --configfile=/etc/traefik/traefik.yml
    ports:
      - "18080:80"
      - "18443:443"
      - "18081:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./data/state/traefik/config/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./data/state/traefik/dynamic:/etc/traefik/dynamic:ro
      - ./data/state/traefik/acme_storage.json:/etc/traefik/acme.json:rw
      - ./data/state/traefik/tls:/etc/traefik/tls:ro
    depends_on:
      - ci-os-hub
    labels:
      ci-os-hub.managed: true

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: \${CLOUDFLARED_CONTAINER_NAME:-cloudflared}
    profiles:
      - cloudflare
      - tunnel
    restart: unless-stopped
    command: tunnel run --token-file /home/nonroot/.cloudflared/token
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./tunnel:/home/nonroot/.cloudflared:ro
    depends_on:
      - ci-os-hub
      - traefik

volumes:
  ci_hub_pgdata:
EOF

stop_conflicting_containers() {
  local port="$1"
  local ids
  ids=$(docker ps -q --filter "publish=${port}" | tr '\n' ' ' | xargs -r echo || true)
  if [ -n "${ids:-}" ]; then
    echo -e "${YELLOW}Stopping/removing containers using host port ${port}: ${ids}${NC}"
    # shellcheck disable=SC2086
    docker rm -f ${ids} >/dev/null 2>&1 || true
  fi
}

stop_managed_containers() {
  local names=(ci-os-hub ci-os-hub-queue ci-hub-db traefik cloudflared)
  local cid
  for name in "${names[@]}"; do
    cid=$(docker ps -aq --filter "name=^/${name}$" | head -n1 || true)
    if [ -n "${cid:-}" ]; then
      echo -e "${YELLOW}Removing existing container ${name} (${cid})...${NC}"
      docker rm -f "${cid}" >/dev/null 2>&1 || true
    fi
  done
}

cleanup_stale_networks() {
  local compose_network
  local network

  compose_network="$(basename "${INSTALL_DIR}")_default"

  for network in "${NETWORK_NAME:-ci-os-hub_network}" "${compose_network}"; do
    if docker network inspect "${network}" >/dev/null 2>&1; then
      echo -e "${YELLOW}Removing stale docker network ${network}...${NC}"
      docker network rm "${network}" >/dev/null 2>&1 || true
    fi
  done
}

show_port_owners() {
  local port="$1"
  echo -e "${YELLOW}Diagnostics for host port ${port}:${NC}"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :${port}" 2>/dev/null || true
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
  fi
}

nginx_is_on_port() {
  local port="$1"
  ss -ltnp "sport = :${port}" 2>/dev/null | grep -q "nginx"
}

stop_nginx_if_conflicting() {
  local port="$1"

  if ! nginx_is_on_port "$port"; then
    return 0
  fi

  echo -e "${YELLOW}Detected nginx listening on port ${port}.${NC}"

  if [ "${EUID}" -ne 0 ]; then
    echo -e "${RED}Cannot stop nginx without root privileges.${NC}"
    echo -e "${YELLOW}Please re-run this script with sudo, or run: sudo systemctl stop nginx${NC}"
    return 1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    echo -e "${YELLOW}Stopping nginx service to free port ${port}...${NC}"
    systemctl stop nginx >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    echo -e "${YELLOW}Stopping nginx service to free port ${port}...${NC}"
    service nginx stop >/dev/null 2>&1 || true
  fi

  sleep 1

  if nginx_is_on_port "$port"; then
    echo -e "${RED}nginx is still using port ${port}.${NC}"
    echo -e "${YELLOW}Please run: sudo systemctl stop nginx${NC}"
    return 1
  fi

  echo -e "${GREEN}nginx stopped; port ${port} is now available.${NC}"
  return 0
}

recover_port_conflict() {
  local port="$1"
  echo -e "${YELLOW}Attempting aggressive recovery for port ${port} conflict...${NC}"
  stop_nginx_if_conflicting "$port" || true
  stop_managed_containers
  cleanup_stale_networks
  stop_conflicting_containers "$port"
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${port}/tcp" >/dev/null 2>&1 || true
  fi
  sleep 2
}

port_is_listening() {
  local port="$1"
  ss -ltn "sport = :${port}" 2>/dev/null | awk 'NR>1 {print; found=1} END {exit found ? 0 : 1}'
}

free_host_port() {
  local port="$1"
  stop_conflicting_containers "$port"
  stop_nginx_if_conflicting "$port" || true

  if port_is_listening "$port" >/dev/null; then
    if command -v fuser >/dev/null 2>&1; then
      echo -e "${YELLOW}Killing non-Docker process on port ${port}...${NC}"
      fuser -k "${port}/tcp" >/dev/null 2>&1 || true
      sleep 1
    fi
  fi

  if port_is_listening "$port" >/dev/null; then
    echo -e "${RED}Error: Host port ${port} is still in use.${NC}"
    echo -e "${RED}Please stop the process using port ${port}, then re-run this script.${NC}"
    exit 1
  fi
}

# Build or Pull the Hub image
if [ "${BUILD_LOCAL:-false}" = "true" ]; then
  HUB_REPO_PATH="${CI_OS_HUB_REPO_PATH:-${SCRIPT_DIR}/../CI-OS-Hub}"
  if [ ! -f "${HUB_REPO_PATH}/Dockerfile" ]; then
    echo -e "${RED}Error: CI-OS-Hub repo not found at ${HUB_REPO_PATH}. Set CI_OS_HUB_REPO_PATH.${NC}"
    exit 1
  fi
  echo -e "${YELLOW}Building Hub image locally from ${HUB_REPO_PATH}...${NC}"
  (cd "${HUB_REPO_PATH}" && docker build -t "${IMAGE_NAME}" .)
else
  echo -e "${YELLOW}Pulling images (including ${IMAGE_NAME})...${NC}"
  cd "${INSTALL_DIR}"
  if ! docker compose pull; then
      echo -e "${RED}Error: Failed to pull the image. Check registry credentials and network.${NC}"
      exit 1
  fi
fi

echo -e "${GREEN}Installation prepared at ${INSTALL_DIR}${NC}"
echo -e "Starting services..."
(cd "${INSTALL_DIR}" && docker compose down --remove-orphans 2>/dev/null || true)
stop_managed_containers
cleanup_stale_networks

# Ensure all required host ports are free before starting
for PORT in 5002 5001 6543 18080 18443 18081; do
  free_host_port "$PORT"
done

if [ "${ENABLE_CLOUDFLARE_TUNNEL:-false}" = "true" ]; then
  echo -e "${GREEN}Cloudflare tunnel profile enabled (default).${NC}"
  COMPOSE_UP_CMD=(docker compose --profile cloudflare up -d)
else
  echo -e "${YELLOW}Cloudflare tunnel profile disabled via ENABLE_CLOUDFLARE_TUNNEL=false.${NC}"
  COMPOSE_UP_CMD=(docker compose up -d)
fi

if ! (cd "${INSTALL_DIR}" && "${COMPOSE_UP_CMD[@]}"); then
    echo -e "${YELLOW}Initial startup failed. Checking for port conflicts...${NC}"
    show_port_owners 5002
    recover_port_conflict 5002

    # Re-check all required ports after aggressive cleanup
    for PORT in 5002 5001 6543 18080 18443 18081; do
      free_host_port "$PORT"
    done

    echo -e "${YELLOW}Retrying service startup once...${NC}"
    if ! (cd "${INSTALL_DIR}" && "${COMPOSE_UP_CMD[@]}"); then
      echo -e "${RED}Error: Failed to start services after retry.${NC}"
      show_port_owners 5002
      exit 1
    fi
fi

echo -e "${GREEN}CI OS Hub ${HUB_ENV_LABEL} is running.${NC}"
echo -e "Hub UI: http://localhost:5002"
