#!/bin/bash
# Cloud-session setup: install what ./core/lib/check-repo.sh needs (shellcheck, yamllint;
# bash and python3 ship with the image). Idempotent — skips anything already present,
# and the container is cached after this runs, so later sessions pay nothing.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

missing=()
command -v shellcheck >/dev/null 2>&1 || missing+=(shellcheck)
command -v yamllint >/dev/null 2>&1 || missing+=(yamllint)
[ ${#missing[@]} -eq 0 ] && exit 0

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 \
    || { $SUDO apt-get update -qq >/dev/null 2>&1 && $SUDO apt-get install -y -qq "${missing[@]}" >/dev/null; }
else
  # No apt: both tools are on PyPI (shellcheck-py bundles the binary).
  pkgs=()
  for m in "${missing[@]}"; do [ "$m" = shellcheck ] && pkgs+=(shellcheck-py) || pkgs+=("$m"); done
  python3 -m pip install -q "${pkgs[@]}"
fi

for m in "${missing[@]}"; do
  command -v "$m" >/dev/null 2>&1 || { echo "session-start: failed to install $m" >&2; exit 1; }
done
