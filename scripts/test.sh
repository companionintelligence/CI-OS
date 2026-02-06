#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    return 1
  fi
}

collect_shell_files() {
  find "$REPO_ROOT" \
    -type f \
    -name "*.sh" \
    -not -path "*/.git/*" \
    -not -path "*/build/*" \
    -not -path "*/dist/*" \
    -not -path "*/scripts/old scripts/*"
}

run_bash_n() {
  echo "Running bash -n on shell scripts"
  while IFS= read -r file; do
    bash -n "$file"
  done < <(collect_shell_files)
}

run_shellcheck() {
  echo "Running shellcheck"
  shellcheck --version >/dev/null
  while IFS= read -r file; do
    shellcheck "$file"
  done < <(collect_shell_files)
}

run_shfmt() {
  echo "Running shfmt -d"
  while IFS= read -r file; do
    shfmt -d -i 2 -ci -sr "$file"
  done < <(collect_shell_files)
}

run_bash_n

if require_cmd shellcheck; then
  run_shellcheck
else
  echo "shellcheck not found. Install it or run ./scripts/ci.sh" >&2
  exit 1
fi

if require_cmd shfmt; then
  run_shfmt
else
  echo "shfmt not found. Install it or run ./scripts/ci.sh" >&2
  exit 1
fi

if [ -x "$REPO_ROOT/scripts/test-iso.sh" ]; then
  "$REPO_ROOT/scripts/test-iso.sh"
fi

echo "All checks passed"
