#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [-d DEVICE_ID] [-k API_KEY] [-- pull-dev-args...]

Either set the environment variables DEVICE_ID and API_KEY, or pass them via flags.
Examples:
  DEVICE_ID=abc API_KEY=xyz ./pull-dev-manual.sh
  ./pull-dev-manual.sh -d abc -k xyz

Any arguments after -- are forwarded to pull-dev.sh.
EOF
  exit 2
}

DEVICE_ID="${DEVICE_ID:-}"
API_KEY="${API_KEY:-}"

# parse flags
while getopts "d:k:h" opt; do
  case "$opt" in
    d) DEVICE_ID="$OPTARG" ;;
    k) API_KEY="$OPTARG" ;;
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULL_DEV_SH="$SCRIPT_DIR/pull-dev.sh"

if [ ! -x "$PULL_DEV_SH" ] && [ -f "$PULL_DEV_SH" ]; then
  # try to make it executable for convenience
  chmod +x "$PULL_DEV_SH" || true
fi

if [ ! -f "$PULL_DEV_SH" ]; then
  echo "Error: pull-dev.sh not found at $PULL_DEV_SH"
  exit 1
fi

echo "Running pull-dev.sh with DEVICE_ID set."
exec "$PULL_DEV_SH" "$@"
