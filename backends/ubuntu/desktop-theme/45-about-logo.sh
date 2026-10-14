#!/usr/bin/env bash
# Settings > About logo, the os-release LOGO= icon and the Hub launcher icon, from the vendored canon mark.
#
# gnome-control-center hard-codes /usr/share/pixmaps/ubuntu-logo-text.png (light mode) and
# ubuntu-logo-text-dark.png (dark mode) for the logo at the top of Settings > About and ignores the
# LOGO= key of os-release. base-files owns both files, so ci_install_file diverts the stock ones first
# and a base-files upgrade cannot bring the Ubuntu wordmark back.
#
# The PNGs are the one-colour mark (vendor/brand/logos/mark-mono.svg) at 192 px, filled with the canon
# primary of each mode (CI_LIGHT_PRIMARY, CI_DARK_PRIMARY). The stock desktop image has no rsvg-convert,
# so an image build renders them on the build host (core/render/render-mark-png.sh) and stages them in
# core/render/output/; with nothing staged (a live system) this step renders them itself.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

ABOUT_LOGO_PX=192
LIGHT_PNG_NAME="ci-os-about-logo.png"
DARK_PNG_NAME="ci-os-about-logo-dark.png"
PNG_DIR="$REPO_ROOT/core/render/output"
MARK_SVG="$REPO_ROOT/vendor/brand/logos/mark.svg"
RENDER_MARK="$REPO_ROOT/core/render/render-mark-png.sh"
ICON_DEST="/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
HUB_DESKTOP="/usr/share/applications/ci-os-hub.desktop"

if [[ ! -f "$MARK_SVG" ]]; then
  log_error "Logo mark not found: $MARK_SVG (expected from the vendored brand bundle)"
  exit 1
fi

RENDER_TMP=""
cleanup() {
  if [[ -n "$RENDER_TMP" ]]; then rm -rf "$RENDER_TMP"; fi
}
trap cleanup EXIT

if [[ ! -f "$PNG_DIR/$LIGHT_PNG_NAME" || ! -f "$PNG_DIR/$DARK_PNG_NAME" ]]; then
  if [[ ! -f "$RENDER_MARK" ]]; then
    log_error "No pre-rendered About logo in $PNG_DIR and no $RENDER_MARK to render one"
    exit 1
  fi
  RENDER_TMP="$(mktemp -d)"
  PNG_DIR="$RENDER_TMP"
  log_info "Rendering the About logo..."
  bash "$RENDER_MARK" "$PNG_DIR/$LIGHT_PNG_NAME" "$ABOUT_LOGO_PX" "$CI_LIGHT_PRIMARY"
  bash "$RENDER_MARK" "$PNG_DIR/$DARK_PNG_NAME" "$ABOUT_LOGO_PX" "$CI_DARK_PRIMARY"
fi

ci_install_file "$PNG_DIR/$LIGHT_PNG_NAME" /usr/share/pixmaps/ubuntu-logo-text.png
ci_install_file "$PNG_DIR/$DARK_PNG_NAME" /usr/share/pixmaps/ubuntu-logo-text-dark.png

# os-release says LOGO=ci-os-logo: give that name an icon the theme lookup can resolve.
ci_install_file "$MARK_SVG" "$ICON_DEST"

# The Hub launcher entry (shipped by setup-device, whose payload now says Icon=ci-os-logo) on a system
# that installed it before this icon existed.
if [[ -f "$HUB_DESKTOP" ]] && grep -q '^Icon=application-x-executable$' "$HUB_DESKTOP"; then
  sed -i 's/^Icon=application-x-executable$/Icon=ci-os-logo/' "$HUB_DESKTOP"
fi

# GTK trusts icon-theme.cache: without a refresh the new ci-os-logo name is invisible in hicolor. The Yaru
# themes are refreshed too, so a stale cache cannot mask the start icon 40-start-icon.sh replaced either.
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  for CACHE_DIR in /usr/share/icons/hicolor /usr/share/icons/Yaru*; do
    [[ -d "$CACHE_DIR" ]] || continue
    gtk-update-icon-cache -f "$CACHE_DIR" 2>/dev/null || true
  done
fi

log_success "About logo (light + dark) and ci-os-logo icon installed from the canon mark"
