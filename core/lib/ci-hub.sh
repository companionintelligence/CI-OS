#!/usr/bin/env bash

# CI Hub Service deploy — the Docker/Runtipi backend (ci-os-hub container,
# port 5002), gated on private-registry credentials by design. This is a
# core/ script (not backends/ubuntu/) because it's genuinely distro-portable:
# once Docker is present, everything here is docker-compose, no apt/dpkg
# assumptions. Called by backends/ubuntu/provision/provision.sh's
# deploy_ci_hub() and by the headless captive-portal flow — see
# docs/architecture/multi-distro-design.md.
#
# Was pull-dev.sh at the repo root; renamed and moved here as part of
# consolidating six independently-drifted provisioning entrypoints into one.

set -o errexit
set -o nounset
set -o pipefail

# Ensure we use the default context if Desktop is broken
export DOCKER_CONTEXT=default

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_PARENT="$(cd "$REPO_ROOT/.." && pwd)"

# Optionally load REGISTRY_USERNAME/PASSWORD (same env as hub:publish:dev) from
# a sibling checkout, for local development only — not present on a deployed
# appliance, where these must come from the environment.
if [ -z "${REGISTRY_USERNAME:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
  for ENV_DEV in \
    "${CI_OS_HUB_REPO_PATH:-${WORKSPACE_PARENT}/CI-OS-Hub}/.env.dev" \
    "${WORKSPACE_PARENT}/CI-Cloud/apps/hono-app/.env.dev" \
    "${WORKSPACE_PARENT}/CI-Cloud/apps/hono-app/.env"; do
    if [ -f "$ENV_DEV" ]; then
      set -a
      # shellcheck source=/dev/null
      . "$ENV_DEV"
      set +a
      break
    fi
  done
fi

# Registry credentials must come from the environment or a sourced .env.dev file above.
# No hardcoded fallback — a shared default here is a checked-in credential.
REGISTRY_USERNAME="${REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"

# Hard requirement: docker compose pull against the private registry below
# will fail without these. Report once, clearly, and exit 0 (not a hard
# provisioning failure — CI-Hub deploy is expected to be skipped until the
# device is paired) rather than failing partway through image pull.
if [ -z "$REGISTRY_USERNAME" ] || [ -z "$REGISTRY_PASSWORD" ]; then
  echo "CI-Hub registry deploy skipped: no REGISTRY_USERNAME/REGISTRY_PASSWORD set (not needed when Companion Hub is installed from its package)."
  exit 0
fi

# Configuration - the production Portal and its registry (hub.ci.computer). The registry host is fixed;
# the three CI Cloud URLs below can be overridden from the environment (staging, dev).
REGISTRY_DOMAIN="hub.ci.computer"
IMAGE_NAME="${REGISTRY_DOMAIN}/ci-os-hub:latest"
INSTALL_DIR="${HOME}/ci-os-hub-staging"
# CI Cloud URLs (user-facing setup/API)
CI_CLOUD_URL="${CI_CLOUD_URL:-https://hub.ci.computer}"
CI_CLOUD_API_URL="${CI_CLOUD_API_URL:-https://hub.ci.computer/api}"
CI_CLOUD_FRONTEND_URL="${CI_CLOUD_FRONTEND_URL:-https://hub.ci.computer}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Starting Companion Hub Staging Installation...${NC}"
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

# Tunnel Setup — no default token. Set TUNNEL_TOKEN in env or pass -t to
# pull-dev-manual.sh. A shared hardcoded token here was a checked-in credential;
# the tunnel profile is now skipped (not silently defaulted) when unset.
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
COMPOSE_PROFILES=()
if [ -n "$TUNNEL_TOKEN" ]; then
  echo -e "${YELLOW}Setting up Cloudflare tunnel...${NC}"
  printf '%s' "$TUNNEL_TOKEN" > "${INSTALL_DIR}/tunnel/token"
  chmod 600 "${INSTALL_DIR}/tunnel/token"
  TUNNEL_DIR="${INSTALL_DIR}/tunnel" bash "${SCRIPT_DIR}/generate-tunnel-certs.sh"
  COMPOSE_PROFILES=(--profile tunnel)
  echo -e "${GREEN}Tunnel token and certs configured.${NC}"
else
  echo -e "${YELLOW}No TUNNEL_TOKEN set — skipping Cloudflare tunnel setup (the 'tunnel' compose profile will not run).${NC}"
  echo -e "${YELLOW}Set TUNNEL_TOKEN in env, or pass -t, to enable it.${NC}"
fi

# Registry Login (required for private registry)
if [ -z "${REGISTRY_USERNAME:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
    echo -e "${YELLOW}Note: Set REGISTRY_USERNAME and REGISTRY_PASSWORD for registry auth.${NC}"
    echo -e "${YELLOW}Example: export REGISTRY_USERNAME=xxx REGISTRY_PASSWORD=xxx${NC}"
fi
echo -e "${YELLOW}Logging in to the registry (${REGISTRY_DOMAIN})...${NC}"
if [ -n "${REGISTRY_USERNAME:-}" ] && [ -n "${REGISTRY_PASSWORD:-}" ]; then
    echo "Configuring docker auth manually to bypass registry root 404 issue..."
    # Calculate base64 auth string (user:pass)
    AUTH_STRING=$(echo -n "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" | base64)
    # Owner-only (umask 077) while the Docker config is written: it holds the registry login. jq writes a new file that
    # replaces the old one, so a config an older run left readable is tightened too. Restored right after this block.
    saved_umask="$(umask)"
    umask 077
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
    umask "$saved_umask"
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

# Generate .env file. .env and .env.bak are written owner-only: umask 077 from here to the end of the .env, and chmod 600
# for a file an older run created with a wider mode. They hold JWT_SECRET, the API key and the database and queue logins.
# The umask is restored before docker-compose.yml; the files written above keep the caller's umask.
echo -e "${YELLOW}Generating configuration...${NC}"
saved_umask="$(umask)"
umask 077
if [ -f "${INSTALL_DIR}/.env" ]; then
    echo "Existing .env found, backing up to .env.bak"
    cp "${INSTALL_DIR}/.env" "${INSTALL_DIR}/.env.bak"
    chmod 600 "${INSTALL_DIR}/.env.bak"
fi

# DEVICE_ID: respect a caller-provided value (e.g. pull-dev-manual.sh -d, or
# device pairing) before falling back to system serial / a generated one.
if [ -n "${DEVICE_ID:-}" ]; then
    echo -e "${GREEN}DEVICE_ID from environment: ${DEVICE_ID}${NC}"
elif SERIAL=$(sudo dmidecode -s system-serial-number 2>/dev/null) && [ -n "$SERIAL" ] && [ "$SERIAL" != "Not Specified" ]; then
    DEVICE_ID="$SERIAL"
    echo -e "${GREEN}DEVICE_ID from system serial: ${DEVICE_ID}${NC}"
else
    DEVICE_ID="staging-$(hostname)-$(date +%s)"
    echo -e "${YELLOW}No DMI serial; using fallback DEVICE_ID: ${DEVICE_ID}${NC}"
fi

# API_KEY (e.g. from pull-dev-manual.sh -k, or device pairing) maps to
# CI_CLOUD_API_KEY unless that's already set directly.
CI_CLOUD_API_KEY="${CI_CLOUD_API_KEY:-${API_KEY:-}}"

# JWT_SECRET: generate a fresh random secret on first install; reuse the
# existing one on re-runs (from the .bak taken above) so re-running this
# script doesn't invalidate every existing session. A shared hardcoded value
# here was a checked-in credential — every deployment must get its own.
if [ -f "${INSTALL_DIR}/.env.bak" ] && grep -q '^JWT_SECRET=' "${INSTALL_DIR}/.env.bak" 2>/dev/null; then
    JWT_SECRET="$(grep '^JWT_SECRET=' "${INSTALL_DIR}/.env.bak" | head -n1 | cut -d= -f2-)"
    echo -e "${GREEN}Reusing existing JWT_SECRET from previous install${NC}"
else
    JWT_SECRET="$(openssl rand -hex 32)"
    echo -e "${GREEN}Generated a new random JWT_SECRET${NC}"
fi

# Full .env matching production Companion Hub configuration
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
JWT_SECRET=${JWT_SECRET}

# Timezone
TZ=UTC

# Architecture
ARCHITECTURE=amd64

# Device ID
DEVICE_ID=${DEVICE_ID}
ENVEOF
chmod 600 "${INSTALL_DIR}/.env"
umask "$saved_umask"

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
    # The Hub reaches the database over the compose network. The host port is for tools on this machine only.
    ports:
      - "127.0.0.1:6543:6543"
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
    # Like the database: the Hub uses the compose network, the host port is for this machine only.
    ports:
      - "127.0.0.1:5001:5672"
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
    # The two entrypoints only. Port 8080 belonged to the API's insecure mode, which traefik.yml no longer turns on.
    ports:
      - "18080:80"
      - "18443:443"
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
if ! docker compose "${COMPOSE_PROFILES[@]}" pull; then
    echo -e "${RED}Error: Failed to pull the image. Check registry credentials and network.${NC}"
    exit 1
fi

echo -e "${GREEN}Installation prepared at ${INSTALL_DIR}${NC}"
echo -e "Starting services..."
(cd "${INSTALL_DIR}" && docker compose "${COMPOSE_PROFILES[@]}" down --remove-orphans 2>/dev/null || true)
if ! (cd "${INSTALL_DIR}" && docker compose "${COMPOSE_PROFILES[@]}" up -d); then
    echo -e "${RED}Error: Failed to start services.${NC}"
    exit 1
fi

echo -e "${GREEN}Companion Hub staging is running.${NC}"
echo -e "Hub UI: http://localhost:5002"
if [ ${#COMPOSE_PROFILES[@]} -gt 0 ]; then
  echo -e "Cloudflare tunnel: active (token loaded from TUNNEL_TOKEN)"
fi
