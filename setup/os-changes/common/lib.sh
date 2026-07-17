#!/usr/bin/env bash
# Shared context for setup/os-changes/common/*.sh (sourced, not executed alone).
# shellcheck shell=bash

if [[ -z "${OS_CHANGES_DIR:-}" ]]; then
  _lib_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export OS_CHANGES_DIR="$(cd "${_lib_here}/.." && pwd)"
fi
export REPO_ROOT="$(cd "${OS_CHANGES_DIR}/../.." && pwd)"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $*"; }

require_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    log_error "This step must be run as root (use sudo)"
    exit 1
  fi
}

dconf_update_safe() {
  if command -v dconf >/dev/null 2>&1; then
    dconf update 2>/dev/null || true
  fi
}
