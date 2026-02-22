#!/usr/bin/env bash

# CI OS Hub Staging Installer
# This script downloads and installs CI OS Hub from the CI Cloud staging registry.

set -o errexit
set -o nounset
set -o pipefail

# Ensure we use the default context if Desktop is broken
export DOCKER_CONTEXT=default

# Optionally load REGISTRY_USERNAME/PASSWORD (same env as hub:publish:dev)
if [ -z "${REGISTRY_USERNAME:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Configuration - always use dev registry (setup.companionintelligence.com)
REGISTRY_DOMAIN="portal.companionintelligence.com"
IMAGE_NAME="${REGISTRY_DOMAIN}/ci-os-hub:latest"
INSTALL_DIR="${HOME}/ci-os-hub-staging"
# CI Cloud URLs (user-facing setup/API)
CI_CLOUD_URL="${CI_CLOUD_URL:-https://setup.companionintelligence.com}"
CI_CLOUD_API_URL="${CI_CLOUD_API_URL:-https://setup.companionintelligence.com/api}"
CI_CLOUD_FRONTEND_URL="${CI_CLOUD_FRONTEND_URL:-https://setup.companionintelligence.com}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Starting CI OS Hub Staging Installation...${NC}"
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

# Registry Login (required for private registry)
if [ -z "${REGISTRY_USERNAME:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
    echo -e "${YELLOW}Note: Set REGISTRY_USERNAME and REGISTRY_PASSWORD for registry auth.${NC}"
    echo -e "${YELLOW}Example: export REGISTRY_USERNAME=xxx REGISTRY_PASSWORD=xxx${NC}"
fi
echo -e "${YELLOW}Logging in to the staging registry (${REGISTRY_DOMAIN})...${NC}"
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
        address: "http://ci-os-hub:5002/api/auth/traefik"
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
if SERIAL=$(sudo dmidecode -s system-serial-number 2>/dev/null) && [ -n "$SERIAL" ] && [ "$SERIAL" != "Not Specified" ]; then
    DEVICE_ID="$SERIAL"
    echo -e "${GREEN}DEVICE_ID from system serial: ${DEVICE_ID}${NC}"
else
    DEVICE_ID="staging-$(hostname)-$(date +%s)"
    echo -e "${YELLOW}No DMI serial; using fallback DEVICE_ID: ${DEVICE_ID}${NC}"
fi

CI_CLOUD_API_KEY=${CI_CLOUD_API_KEY:-""}

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
ROOT_FOLDER_HOST=${INSTALL_DIR}
RUNTIPI_APP_DATA_PATH=${INSTALL_DIR}
RUNTIPI_MEDIA_PATH=${INSTALL_DIR}
RUNTIPI_STATE_PATH=${INSTALL_DIR}
RUNTIPI_REPOS_PATH=${INSTALL_DIR}
RUNTIPI_APPS_PATH=${INSTALL_DIR}
RUNTIPI_LOGS_PATH=${INSTALL_DIR}
RUNTIPI_USER_CONFIG_PATH=${INSTALL_DIR}
RUNTIPI_BACKUPS_PATH=${INSTALL_DIR}
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
POSTGRES_DBNAME=tipi
POSTGRES_USERNAME=tipi
POSTGRES_USER=tipi
POSTGRES_PASSWORD=postgres
POSTGRES_PORT=6543

# RabbitMQ Configuration
RABBITMQ_HOST=ci-os-hub-queue
RABBITMQ_USERNAME=tipi
RABBITMQ_PASSWORD=tipi

# Traefik Configuration (ci-os-hub uses port 5002 in this setup)
RUNTIPI_FORWARD_AUTH_URL=http://ci-os-hub:5002/api/auth/traefik

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
JWT_SECRET=857ad2225d62961ba24b12ee88b4a628e1647a0c61d5113f313f56f22461d0c3

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
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      traefik.enable: true
      ci-os-hub.managed: true
      traefik.http.middlewares.runtipi.forwardauth.address: "http://ci-os-hub:5002/api/auth/traefik"
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
      - tunnel
    restart: unless-stopped
    command: tunnel run --token-file /home/nonroot/.cloudflared/token
    volumes:
      - ./tunnel:/home/nonroot/.cloudflared:ro
    depends_on:
      - ci-os-hub
      - traefik

volumes:
  ci_hub_pgdata:
EOF

# Pull images (ci-os-hub from our registry, others from Docker Hub)
echo -e "${YELLOW}Pulling images (including ${IMAGE_NAME})...${NC}"
cd "${INSTALL_DIR}"
if ! docker compose pull; then
    echo -e "${RED}Error: Failed to pull the image. Check registry credentials and network.${NC}"
    exit 1
fi

echo -e "${GREEN}Installation prepared at ${INSTALL_DIR}${NC}"
echo -e "Starting services..."
(cd "${INSTALL_DIR}" && docker compose down --remove-orphans 2>/dev/null || true)
if ! (cd "${INSTALL_DIR}" && docker compose up -d); then
    echo -e "${RED}Error: Failed to start services.${NC}"
    exit 1
fi

echo -e "${GREEN}CI OS Hub staging is running.${NC}"
echo -e "Hub UI: http://localhost:5002"
