#!/usr/bin/env bash
# Replace Yaru start-here / Show Apps icon with CI mark.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

CUSTOM_ICON_PATH="$ASSET_INPUTS_DIR/LogoMark_Color_StartIcon-cropped.svg"
if [[ ! -f "$CUSTOM_ICON_PATH" ]]; then
  log_error "Icon file not found: $CUSTOM_ICON_PATH"
  exit 1
fi

ICON_EXT="${CUSTOM_ICON_PATH##*.}"
ICON_NAME="ci-os-activities-icon"
BACKUP_DIR="/usr/share/icons/ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

REPLACED=0
for THEME_DIR in /usr/share/icons/Yaru*/scalable/places; do
  [[ -d "$THEME_DIR" ]] || continue
  ACTIVITIES_ICON="$THEME_DIR/start-here-symbolic.svg"
  THEME_NAME="$(basename "$(dirname "$(dirname "$(dirname "$THEME_DIR")")")")"

  if [[ ! -f "$ACTIVITIES_ICON" ]]; then
    log_warn "Icon not found in theme $THEME_NAME, skipping: $ACTIVITIES_ICON"
    continue
  fi

  mkdir -p "$BACKUP_DIR/$THEME_NAME/scalable/places"
  cp "$ACTIVITIES_ICON" "$BACKUP_DIR/$THEME_NAME/scalable/places/start-here-symbolic.svg.bak"

  if [[ "$ICON_EXT" =~ ^(svg|SVG)$ ]]; then
    cp "$CUSTOM_ICON_PATH" "$ACTIVITIES_ICON"
  else
    PIXMAP_DEST="/usr/share/pixmaps/${ICON_NAME}.png"
    mkdir -p /usr/share/pixmaps
    cp "$CUSTOM_ICON_PATH" "$PIXMAP_DEST"
    cat > "$ACTIVITIES_ICON" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="24" height="24" viewBox="0 0 24 24">
  <image xlink:href="file://$PIXMAP_DEST" width="24" height="24"/>
</svg>
EOF
  fi
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

log_success "Start icon replaced in $REPLACED Yaru theme(s). Backup: $BACKUP_DIR"
