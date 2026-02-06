#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update
  $SUDO apt-get install -y shellcheck shfmt
else
  echo "apt-get not found. Please install shellcheck and shfmt manually." >&2
  exit 1
fi

"$(dirname "$0")/test.sh"
