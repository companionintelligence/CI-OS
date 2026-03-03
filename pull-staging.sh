#!/usr/bin/env bash
# CI OS Hub Staging Installer
# Uses portal.companionintel.com registry. Sets config and runs shared installer logic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load staging env first if available
for ENV_FILE in \
  "${CI_OS_HUB_REPO_PATH:-${SCRIPT_DIR}/../CI-OS-Hub}/.env.staging" \
  "${SCRIPT_DIR}/../CI-Cloud/apps/hono-app/.env.staging" \
  "${SCRIPT_DIR}/../ci-os-hub/.env.staging"; do
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
    break
  fi
done

export REGISTRY_DOMAIN="${REGISTRY_DOMAIN:-portal.companionintel.com}"
export INSTALL_DIR="${INSTALL_DIR:-${HOME}/ci-os-hub-staging}"
export CI_CLOUD_URL="${CI_CLOUD_URL:-https://portal.companionintel.com}"
export CI_CLOUD_API_URL="${CI_CLOUD_API_URL:-https://portal.companionintel.com/api}"
export CI_CLOUD_FRONTEND_URL="${CI_CLOUD_FRONTEND_URL:-https://portal.companionintel.com}"
export HUB_INSTALL_ENV="staging"

exec "$SCRIPT_DIR/pull-dev.sh" "$@"
