#!/usr/bin/env bash
# Replace Yaru start-here / Show Apps icon with the canon mark.
#
# The dock's bottom "Show Applications" button is view-app-grid-ubuntu-symbolic.svg, a symlink to Yaru's
# places/start-here-symbolic.svg, so replacing that one file brands the button. yaru-theme-icon
# owns it: ci_install_file diverts the stock file first, so an upgrade of the package cannot restore it.
#
# The icon is generated from the vendored one-colour mark (vendor/brand/logos/mark-mono.svg) every time,
# not kept as a second copy of the artwork: the path data is the mark's own, `currentColor` is the only
# fill (GTK repaints a -symbolic icon in the foreground colour anyway, so no brand colour ships in it), and
# only the viewBox is cropped to the mark plus a margin so it fills the dock button like Yaru's own glyph.
# A re-vendored mark therefore reaches the dock with the rest of the logo surfaces, as long as it keeps the geometry the
# crop was cut for: the crop box is a constant, measured on the 1.0.0 mark (its ink spans about 51 to 196 units of the
# 247.182-unit canvas, the box leaves a margin of 15 or more), not computed from it, because the stock desktop chroot
# has no renderer to measure with. A mark with another viewBox stops this step, so the box is re-derived and not
# applied to art it was not cut for; a mark that moves inside the same viewBox is caught by verify-iso.sh, which
# renders the icon and the whole mark and requires the crop to keep the ink.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

MARK_SVG="$REPO_ROOT/vendor/brand/logos/mark-mono.svg"
# x y width height, in the mark's own 247.182-unit coordinate system (its full viewBox is "0 0 247.182 247.182").
START_ICON_VIEWBOX="34.60548 36.582936 178.465404 175.004856"
START_ICON_SOURCE_VIEWBOX="0 0 247.182 247.182"

if [[ ! -f "$MARK_SVG" ]]; then
  log_error "Logo mark not found: $MARK_SVG (expected from the vendored brand bundle)"
  exit 1
fi

MARK_VIEWBOX="$(sed -n 's/.*viewBox="\([^"]*\)".*/\1/p' "$MARK_SVG" | head -1 | tr -s ' ,' ' ')"
if [[ "$MARK_VIEWBOX" != "$START_ICON_SOURCE_VIEWBOX" ]]; then
  log_error "$MARK_SVG has viewBox \"${MARK_VIEWBOX:-none}\", but START_ICON_VIEWBOX was cut for \"$START_ICON_SOURCE_VIEWBOX\": applying it would clip or offset the mark. Re-derive START_ICON_VIEWBOX (and START_ICON_SOURCE_VIEWBOX) for the new mark."
  exit 1
fi

read -r _ _ VB_W VB_H <<<"$START_ICON_VIEWBOX"
GEN_DIR="$(mktemp -d)"
trap 'rm -rf "$GEN_DIR"' EXIT
CUSTOM_ICON_PATH="$GEN_DIR/start-here-symbolic.svg"
sed "s/viewBox=\"[^\"]*\"/viewBox=\"$START_ICON_VIEWBOX\" width=\"$VB_W\" height=\"$VB_H\"/" "$MARK_SVG" > "$CUSTOM_ICON_PATH"
if ! grep -q "viewBox=\"$START_ICON_VIEWBOX\"" "$CUSTOM_ICON_PATH"; then
  log_error "Could not set the start icon viewBox: no viewBox attribute in $MARK_SVG"
  exit 1
fi

# An image build starts from the stock ISO every time; only a live system keeps a backup.
BACKUP_DIR=""
if ! ci_image_build; then
  BACKUP_DIR="/usr/share/icons/ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
fi

REPLACED=0
for THEME_DIR in /usr/share/icons/Yaru*/scalable/places; do
  [[ -d "$THEME_DIR" ]] || continue
  ACTIVITIES_ICON="$THEME_DIR/start-here-symbolic.svg"
  THEME_NAME="$(basename "$(dirname "$(dirname "$(dirname "$THEME_DIR")")")")"

  if [[ ! -f "$ACTIVITIES_ICON" ]]; then
    log_warn "Icon not found in theme $THEME_NAME, skipping: $ACTIVITIES_ICON"
    continue
  fi

  if [[ -n "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR/$THEME_NAME/scalable/places"
    cp "$ACTIVITIES_ICON" "$BACKUP_DIR/$THEME_NAME/scalable/places/start-here-symbolic.svg.bak"
  fi

  ci_install_file "$CUSTOM_ICON_PATH" "$ACTIVITIES_ICON"
  chmod 644 "$ACTIVITIES_ICON"
  REPLACED=$((REPLACED + 1))
done

if [[ $REPLACED -eq 0 ]]; then
  log_error "No Yaru theme icon was replaced."
  exit 1
fi

for CACHE_DIR in /usr/share/icons/Yaru*; do
  [[ -d "$CACHE_DIR" ]] || continue
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f "$CACHE_DIR" 2>/dev/null || true
  fi
done

if [[ -n "$BACKUP_DIR" ]]; then
  log_success "Start icon replaced in $REPLACED Yaru theme(s). Backup: $BACKUP_DIR"
else
  log_success "Start icon replaced in $REPLACED Yaru theme(s). Stock files kept as start-here-symbolic.svg.ubuntu-stock."
fi
