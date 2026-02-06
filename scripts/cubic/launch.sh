#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_env.sh
source "$SCRIPT_DIR/_env.sh"

if ! command -v cubic >/dev/null 2>&1; then
  echo "Cubic is not installed. Install it first (apt install cubic)." >&2
  exit 1
fi

"$SCRIPT_DIR/prepare.sh"

cat << INSTR

Launching Cubic...
Use the instructions at:
  $CUBIC_WORKDIR/INSTRUCTIONS.txt
INSTR

cubic
