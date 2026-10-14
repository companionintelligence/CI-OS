#!/usr/bin/env bash
# Shared context for the theming scripts under backends/ubuntu/desktop-theme/,
# backends/_mixins/{gnome-dconf,kde-plasma}/, and core/render/*.sh (sourced,
# not executed alone). Genuinely distro-portable: everything here is a logging
# helper, the canon tokens, ci_divert_file (which does nothing without dpkg), or
# a Plymouth theme-file writer (plain sed and cat).
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

# ci_plymouth_recolor <conf>
# Repaint a Plymouth theme file (bgrt.plymouth, spinner.plymouth) in the canon boot palette, in place: the
# ground is the dark background (navy), the progress bar's track the dark secondary and its fill the dark
# primary (sage). Only those four colour lines change. Fonts, image directory and alignment stay as the file
# has them, so the one call serves the rootfs copy (10-plymouth.sh) and the copy inside the casper initrd
# (build-iso.sh), which has to keep the Ubuntu fonts because they are the only fonts that initrd carries.
# The ground shows in the spinner theme. The bgrt theme (Ubuntu's default) does not use it while it draws the firmware
# logo or bgrt-fallback.png: the two-step plugin paints solid black behind either, so there only the progress bar
# colours are seen. Needs no root and no dpkg.
ci_plymouth_recolor() {
  local conf="$1" ground track fill
  ground="$(ci_hex0x "$CI_DARK_BACKGROUND")"
  track="$(ci_hex0x "$CI_DARK_SECONDARY")"
  fill="$(ci_hex0x "$CI_DARK_PRIMARY")"
  sed -i \
    -e "s/BackgroundStartColor=0x[0-9a-fA-F]*/BackgroundStartColor=$ground/" \
    -e "s/BackgroundEndColor=0x[0-9a-fA-F]*/BackgroundEndColor=$ground/" \
    -e "s/ProgressBarBackgroundColor=0x[0-9a-fA-F]*/ProgressBarBackgroundColor=$track/" \
    -e "s/ProgressBarForegroundColor=0x[0-9a-fA-F]*/ProgressBarForegroundColor=$fill/" \
    "$conf"
}

# ci_plymouth_text_theme <conf> <title>
# Write the ubuntu-text theme file (the text-mode splash: safe-graphics boot, and the fallback when no graphics
# come up) in the canon colours, titled <title>. The file is written whole, so it does not matter what the stock
# one said: white is the dark foreground, brown the dark primary, blue the light primary, black stays black.
# The ModuleName stays ubuntu-text: that is the Plymouth plugin the theme loads, not a name anybody reads.
ci_plymouth_text_theme() {
  local conf="$1" title="$2" white brown blue
  white="$(ci_hex0x "$CI_DARK_FOREGROUND")"
  brown="$(ci_hex0x "$CI_DARK_PRIMARY")"
  blue="$(ci_hex0x "$CI_LIGHT_PRIMARY")"
  cat > "$conf" <<PLYMOUTH_EOF
[Plymouth Theme]
Name=Companion OS Text
Description=Text mode theme with Companion OS branding
ModuleName=ubuntu-text

[ubuntu-text]
title=$title
black=0x000000
white=$white
brown=$brown
blue=$blue
PLYMOUTH_EOF
  chmod 644 "$conf"
}
