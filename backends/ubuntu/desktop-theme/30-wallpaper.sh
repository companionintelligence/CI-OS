#!/usr/bin/env bash
# Install CI wallpaper to /usr/share/backgrounds and dconf defaults for new users.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

WALLPAPER_PATH="$ASSET_INPUTS_DIR/background.png"
if [[ ! -f "$WALLPAPER_PATH" ]]; then
  log_error "Wallpaper not found: $WALLPAPER_PATH"
  exit 1
fi

WALLPAPER_EXT="${WALLPAPER_PATH##*.}"
WALLPAPER_NAME="ci-os-wallpaper"
DEST_WALLPAPER="/usr/share/backgrounds/${WALLPAPER_NAME}.${WALLPAPER_EXT}"

mkdir -p /usr/share/backgrounds
cp "$WALLPAPER_PATH" "$DEST_WALLPAPER"
chmod 644 "$DEST_WALLPAPER"

# Retire legacy dconf filename to avoid overlapping keys
rm -f /etc/dconf/db/local.d/00-wallpaper

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/02-ci-os-wallpaper <<EOF
[org/gnome/desktop/background]
picture-uri='file://$DEST_WALLPAPER'
picture-uri-dark='file://$DEST_WALLPAPER'

[org/gnome/desktop/screensaver]
picture-uri='file://$DEST_WALLPAPER'
EOF

dconf_update_safe
log_success "Wallpaper installed to $DEST_WALLPAPER and dconf defaults updated"
