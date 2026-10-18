#!/usr/bin/env bash
# Settings > About logo, the os-release LOGO= icon and the Hub launcher icon, from the vendored canon mark.
#
# gnome-control-center hard-codes the logo at the top of Settings > About (light mode and dark mode) and ignores the
# LOGO= key of os-release. GNOME 50 (Ubuntu 26.04, gnome-control-center 50.3) reads
# /usr/share/pixmaps/ubuntu-logo-text.svg and ubuntu-logo-text-dark.svg (strings in the binary; there is no .png
# name in it any more); the .png pair of the same names is still shipped (187x72 in 26.04.1) and read by older
# versions. base-files owns all four files, so ci_install_file diverts the stock ones first and a base-files
# upgrade cannot bring the Ubuntu wordmark back. BOTH pairs are replaced: with only the PNGs replaced, About kept
# Ubuntu's wordmark on 26.04 and nothing failed.
#
# The SVGs are the vendored one-colour mark (vendor/brand/logos/mark-mono.svg) with its currentColor set to the canon
# primary of each mode (CI_LIGHT_PRIMARY, CI_DARK_PRIMARY): a text substitution, so they need no renderer and are
# always installed. The PNGs are the same mark at 192 px (core/render/render-mark-png.sh). The stock desktop image has
# no rsvg-convert or ImageMagick, so an image build renders them on the build host and stages them in
# core/render/output/; with nothing staged (a live system) this step renders them itself.
#
# On a live system with neither renderer installed (apt-get install librsvg2-bin) the PNGs cannot be drawn: the step
# warns, replaces the SVG pair (which is what GNOME 50 shows) and leaves the PNG pair, still installs the ci-os-logo
# icon and the Hub launcher icon, then exits 0 so apply-ci-os-desktop.sh goes on to os-release and motd. An image
# build never degrades like that: without the staged PNGs it fails instead of shipping Ubuntu's wordmark.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

ABOUT_LOGO_PX=192
LIGHT_PNG_NAME="ci-os-about-logo.png"
DARK_PNG_NAME="ci-os-about-logo-dark.png"
PNG_DIR="$REPO_ROOT/core/render/output"
MARK_SVG="$REPO_ROOT/vendor/brand/logos/mark.svg"
MARK_MONO_SVG="$REPO_ROOT/vendor/brand/logos/mark-mono.svg"
RENDER_MARK="$REPO_ROOT/core/render/render-mark-png.sh"
ICON_DEST="/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
HUB_DESKTOP="/usr/share/applications/ci-os-hub.desktop"

for _mark in "$MARK_SVG" "$MARK_MONO_SVG"; do
  if [[ ! -f "$_mark" ]]; then
    log_error "Logo mark not found: $_mark (expected from the vendored brand bundle)"
    exit 1
  fi
done

RENDER_TMP=""
SVG_TMP=""
cleanup() {
  if [[ -n "$RENDER_TMP" ]]; then rm -rf "$RENDER_TMP"; fi
  if [[ -n "$SVG_TMP" ]]; then rm -rf "$SVG_TMP"; fi
}
trap cleanup EXIT

# --- the About PNGs: staged (image build) or rendered here (live system) -------------------------------
HAVE_PNGS=1
if [[ ! -f "$PNG_DIR/$LIGHT_PNG_NAME" || ! -f "$PNG_DIR/$DARK_PNG_NAME" ]]; then
  if ci_image_build; then
    log_error "No pre-rendered About logo in $PNG_DIR: customize-chroot.sh renders it on the build host and stages it"
    exit 1
  fi
  HAVE_PNGS=0
  if [[ ! -f "$RENDER_MARK" ]]; then
    log_warn "No pre-rendered About logo in $PNG_DIR and no $RENDER_MARK to render one"
  elif ! command -v rsvg-convert >/dev/null 2>&1 && ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
    log_warn "Neither rsvg-convert nor ImageMagick is installed, so the About logo cannot be drawn (apt-get install librsvg2-bin)"
  else
    RENDER_TMP="$(mktemp -d)"
    log_info "Rendering the About logo..."
    if bash "$RENDER_MARK" "$RENDER_TMP/$LIGHT_PNG_NAME" "$ABOUT_LOGO_PX" "$CI_LIGHT_PRIMARY" &&
      bash "$RENDER_MARK" "$RENDER_TMP/$DARK_PNG_NAME" "$ABOUT_LOGO_PX" "$CI_DARK_PRIMARY"; then
      PNG_DIR="$RENDER_TMP"
      HAVE_PNGS=1
    else
      log_warn "Rendering the About logo failed"
    fi
  fi
  if [[ $HAVE_PNGS -eq 0 ]]; then
    log_warn "The About PNG pair keeps Ubuntu's wordmark (the SVG pair, which GNOME 50 shows, is replaced below); the rest of this step still applies. Re-run: apply-ci-os-desktop.sh --only about-logo"
  fi
fi

# --- the About SVGs: the one-colour mark with the canon primary of each mode (a text substitution: no renderer) ---------
SVG_TMP="$(mktemp -d)"
sed "s/currentColor/${CI_LIGHT_PRIMARY}/g" "$MARK_MONO_SVG" > "$SVG_TMP/ubuntu-logo-text.svg"
sed "s/currentColor/${CI_DARK_PRIMARY}/g" "$MARK_MONO_SVG" > "$SVG_TMP/ubuntu-logo-text-dark.svg"
for _svg in "$SVG_TMP"/ubuntu-logo-text.svg "$SVG_TMP"/ubuntu-logo-text-dark.svg; do
  if grep -q 'currentColor' "$_svg" || ! grep -q '<svg' "$_svg"; then
    log_error "Could not set the About logo colour in $MARK_MONO_SVG (no currentColor to replace, or not an SVG)"
    exit 1
  fi
done
ci_install_file "$SVG_TMP/ubuntu-logo-text.svg" /usr/share/pixmaps/ubuntu-logo-text.svg
ci_install_file "$SVG_TMP/ubuntu-logo-text-dark.svg" /usr/share/pixmaps/ubuntu-logo-text-dark.svg

if [[ $HAVE_PNGS -eq 1 ]]; then
  ci_install_file "$PNG_DIR/$LIGHT_PNG_NAME" /usr/share/pixmaps/ubuntu-logo-text.png
  ci_install_file "$PNG_DIR/$DARK_PNG_NAME" /usr/share/pixmaps/ubuntu-logo-text-dark.png
fi

# os-release says LOGO=ci-os-logo: give that name an icon the theme lookup can resolve. Plain install, not
# ci_install_file: no Ubuntu package ships this name, and setup-device ships the same bytes (its Hub launcher
# entry names the icon; core/lib/check-brand-mirrors.sh keeps them equal to the vendored mark), so there is no
# stock file to divert.
install -D -m 644 "$MARK_SVG" "$ICON_DEST"

# The Hub launcher entry (shipped by setup-device, whose payload says Icon=ci-os-logo and ships the icon) on a
# system that installed it before that.
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

if [[ $HAVE_PNGS -eq 1 ]]; then
  log_success "About logo (SVG and PNG, light + dark) and ci-os-logo icon installed from the canon mark"
else
  log_success "About logo (SVG, light + dark) and ci-os-logo icon installed from the canon mark (the PNG pair NOT replaced: no renderer)"
fi
