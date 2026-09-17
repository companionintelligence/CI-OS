#!/usr/bin/env bash
# Shared context for the theming scripts under backends/ubuntu/desktop-theme/,
# backends/_mixins/{gnome-dconf,kde-plasma}/, and core/render/*.sh (sourced,
# not executed alone). Genuinely distro-portable: everything here is either a
# logging helper or sourcing the canon tokens, no apt/dpkg assumptions.
# shellcheck shell=bash

# Callers at a known depth from the repo root may already export REPO_ROOT
# before sourcing this file; if not, derive it from this file's own location
# (core/lib/ -> repo root is two levels up).
if [[ -z "${REPO_ROOT:-}" ]]; then
  _theme_lib_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export REPO_ROOT="$(cd "${_theme_lib_here}/../.." && pwd)"
fi

# Raw PNG/SVG inputs the render scripts and theming steps consume (Plymouth
# watermark, wallpaper, start-icon source) — distro-agnostic, brand-specific.
export ASSET_INPUTS_DIR="${REPO_ROOT}/core/render/inputs"

# The Companion Intelligence canon, vendored from the brand bundle (core/lib/vendor-brand.sh).
# Every colour a theming script needs is a CI_* variable from here — never a literal.
# shellcheck source=../../vendor/brand/tokens/tokens.sh
source "${REPO_ROOT}/vendor/brand/tokens/tokens.sh"

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
