#!/usr/bin/env bash
# CI OS Hub Production Installer
# Uses portal.ci.computer registry. Sets config and runs shared installer logic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load prod env first if available
for ENV_FILE in \
  "${CI_OS_HUB_REPO_PATH:-${SCRIPT_DIR}/../CI-OS-Hub}/.env.prod" \
  "${SCRIPT_DIR}/../CI-Cloud/apps/hono-app/.env.prod" \
  "${SCRIPT_DIR}/../ci-os-hub/.env.prod"; do
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
    break
  fi
done

export REGISTRY_DOMAIN="${REGISTRY_DOMAIN:-portal.ci.computer}"
export INSTALL_DIR="${INSTALL_DIR:-${HOME}/ci-os-hub}"
export CI_CLOUD_URL="${CI_CLOUD_URL:-https://portal.ci.computer}"
export CI_CLOUD_API_URL="${CI_CLOUD_API_URL:-https://portal.ci.computer/api}"
export CI_CLOUD_FRONTEND_URL="${CI_CLOUD_FRONTEND_URL:-https://portal.ci.computer}"
export HUB_INSTALL_ENV="prod"

exec "$SCRIPT_DIR/pull-dev.sh" "$@"
