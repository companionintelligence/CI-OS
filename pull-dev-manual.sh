#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [-d DEVICE_ID] [-k API_KEY] [-t TUNNEL_TOKEN] [-- pull-dev-args...]

Either set the environment variables DEVICE_ID, API_KEY, and optionally
TUNNEL_TOKEN, or pass them via flags.
Examples:
  DEVICE_ID=abc API_KEY=xyz ./pull-dev-manual.sh
  ./pull-dev-manual.sh -d abc -k xyz
  ./pull-dev-manual.sh -d abc -k xyz -t eyJ...  (enables Cloudflare tunnel)

Any arguments after -- are forwarded to core/lib/ci-hub.sh.
EOF
  exit 2
}

DEVICE_ID="${DEVICE_ID:-}"
API_KEY="${API_KEY:-}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"

# parse flags
while getopts "d:k:t:h" opt; do
  case "$opt" in
    d) DEVICE_ID="$OPTARG" ;;
    k) API_KEY="$OPTARG" ;;
    t) TUNNEL_TOKEN="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

# shift parsed options
shift $((OPTIND-1))

# If values still empty, prompt briefly and fail
if [ -z "$DEVICE_ID" ] || [ -z "$API_KEY" ]; then
  echo "Error: DEVICE_ID and API_KEY must be provided via flags or environment variables."
  usage
fi

export DEVICE_ID
export API_KEY
export TUNNEL_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_HUB_SH="$SCRIPT_DIR/core/lib/ci-hub.sh"

if [ ! -x "$CI_HUB_SH" ] && [ -f "$CI_HUB_SH" ]; then
  # try to make it executable for convenience
  chmod +x "$CI_HUB_SH" || true
fi

if [ ! -f "$CI_HUB_SH" ]; then
  echo "Error: core/lib/ci-hub.sh not found at $CI_HUB_SH"
  exit 1
fi

echo "Running core/lib/ci-hub.sh with DEVICE_ID set."
exec "$CI_HUB_SH" "$@"
