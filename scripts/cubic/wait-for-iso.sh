#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_env.sh
source "$SCRIPT_DIR/_env.sh"

mkdir -p "$CUBIC_ISO_OUTPUT_DIR"

SECONDS_LEFT=$((CUBIC_WAIT_MINUTES * 60))
SLEEP_SECONDS=10

printf "Waiting for ISO in %s (timeout: %s minutes)\n" "$CUBIC_ISO_OUTPUT_DIR" "$CUBIC_WAIT_MINUTES"

while [ "$SECONDS_LEFT" -gt 0 ]; do
  ISO_FOUND=$(ls -1 "$CUBIC_ISO_OUTPUT_DIR"/*.iso 2>/dev/null | head -n 1 || true)
  if [ -n "$ISO_FOUND" ]; then
    echo "Found ISO: $ISO_FOUND"
    exit 0
  fi
  sleep "$SLEEP_SECONDS"
  SECONDS_LEFT=$((SECONDS_LEFT - SLEEP_SECONDS))
done

echo "Timed out waiting for ISO in $CUBIC_ISO_OUTPUT_DIR" >&2
exit 1
