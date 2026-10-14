#!/usr/bin/env bash
# Shared context for the theming scripts under backends/ubuntu/desktop-theme/,
# backends/_mixins/{gnome-dconf,kde-plasma}/, and core/render/*.sh (sourced,
# not executed alone). Genuinely distro-portable: everything here is a logging
# helper, the canon tokens, or ci_divert_file, which does nothing without dpkg.
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

# True while backends/ubuntu/chroot/customize-chroot.sh drives a step to build an image
# (run_theme_step exports CI_BRAND_IMAGE_BUILD=1). The image is rebuilt from the stock ISO
# every time, so steps skip the timestamped backup directories they keep on a live system.
ci_image_build() { [[ "${CI_BRAND_IMAGE_BUILD:-0}" == 1 ]]; }

# ci_divert_file <path>
# Move a package-owned stock file aside (dpkg-divert --local --rename, to <path>.ubuntu-stock) so a
# later upgrade of the owning package unpacks the stock file to the diverted name instead of over
# ours. A no-op where dpkg-divert is missing, where no package owns <path>, or where <path> is
# already diverted, so a step can call it on every run. Needs root.
# For base-files' pixmaps dpkg-divert prints "diverting ... from an Essential package with rename is
# dangerous". It is about files an Essential package needs while it unpacks; these are plain data, and
# reinstalling base-files was tested to leave our file in place and the stock one at <path>.ubuntu-stock.
ci_divert_file() {
  local path="$1"
  command -v dpkg-divert >/dev/null 2>&1 || return 0
  dpkg -S "$path" >/dev/null 2>&1 || return 0
  [[ -z "$(dpkg-divert --list "$path" 2>/dev/null)" ]] || return 0
  dpkg-divert --local --rename --divert "${path}.ubuntu-stock" --add "$path" >/dev/null
  log_info "Diverted stock file: $path -> ${path}.ubuntu-stock"
}

# ci_install_file <src> <dest> [mode]
# Install a branded file over <dest>, diverting the stock one first (ci_divert_file). Creates
# missing parent directories; mode defaults to 644.
ci_install_file() {
  local src="$1" dest="$2" mode="${3:-644}"
  ci_divert_file "$dest"
  install -D -m "$mode" "$src" "$dest"
}
