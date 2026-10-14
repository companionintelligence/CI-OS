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
# watermark, wallpaper) — distro-agnostic, brand-specific.
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
#
# A <path>.ubuntu-stock with NO diversion registered is a leftover, and dpkg-divert refuses to rename over
# it (even when the content is identical). It happens when build-iso.sh rebuilds without --clean: it
# re-extracts the stock layers over the chroot of the previous run, which puts back the stock file AND the
# stock /var/lib/dpkg/diversions (so the registry forgets the diversion) but cannot remove a file that is in
# no layer. In an image build <path> is then the freshly extracted stock file and the leftover is stale, so it
# is replaced. On a live system the leftover might be somebody's only copy of the stock file: it is removed
# only when it equals <path>, otherwise it is left alone, the file is not diverted, and the caller still
# installs its file over <path>.
ci_divert_file() {
  local path="$1" stock="${1}.ubuntu-stock"
  command -v dpkg-divert >/dev/null 2>&1 || return 0
  dpkg -S "$path" >/dev/null 2>&1 || return 0
  [[ -z "$(dpkg-divert --list "$path" 2>/dev/null)" ]] || return 0
  if [[ -e "$stock" || -L "$stock" ]]; then
    if ci_image_build || cmp -s "$path" "$stock"; then
      rm -f "$stock"
    else
      log_warn "$stock exists but $path is not diverted, and the two differ: leaving it alone and not diverting (a package upgrade can restore the stock file)"
      return 0
    fi
  fi
  dpkg-divert --local --rename --divert "$stock" --add "$path" >/dev/null
  log_info "Diverted stock file: $path -> $stock"
}

# ci_install_file <src> <dest> [mode]
# Install a branded file over <dest>, diverting the stock one first (ci_divert_file). Creates
# missing parent directories; mode defaults to 644.
ci_install_file() {
  local src="$1" dest="$2" mode="${3:-644}"
  ci_divert_file "$dest"
  install -D -m "$mode" "$src" "$dest"
}
