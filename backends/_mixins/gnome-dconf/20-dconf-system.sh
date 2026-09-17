#!/usr/bin/env bash
# System-wide dconf defaults for GNOME + GDM (no per-user gsettings here).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gnome-defaults.inc.sh"
require_root

CI_GTK_THEME="$(ci_select_gtk_theme)"

# Remove legacy fragments from older runs to avoid duplicate keys / confusion
rm -f /etc/dconf/db/local.d/01-ci-theme /etc/dconf/db/gdm.d/01-ci-theme

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/01-ci-os-gnome-defaults <<DCONF_EOF
[org/gnome/desktop/interface]
gtk-theme='$CI_GTK_THEME'
icon-theme='Yaru'
cursor-theme='Yaru'

[org/gnome/desktop/background]
primary-color='#$CI_THEME_PRIMARY_HEX'
secondary-color='#$CI_THEME_SECONDARY_HEX'

[org/gnome/shell/extensions/dash-to-dock]
dock-fixed=$CI_DOCK_FIXED
dock-position='$CI_DOCK_POSITION'
extend-height=$CI_DOCK_EXTEND_HEIGHT
dash-max-icon-size=$CI_DOCK_MAX_ICON
autohide=$CI_DOCK_AUTOHIDE

[org/gnome/desktop/wm/preferences]
button-layout='close,minimize,maximize:'
focus-mode='click'

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=1800

[org/gnome/desktop/privacy]
disable-microphone=false
disable-camera=false
report-technical-problems=false

[org/gnome/desktop/remote-desktop]
screen-sharing-enabled=true
remote-control-enabled=true

[org/gnome/desktop/remote-desktop/rdp]
enabled=true
view-only=false

[org/gnome/shell]
favorite-apps=['org.gnome.Nautilus.desktop', 'chromium_chromium.desktop', 'org.gnome.Terminal.desktop', 'code.desktop', 'steam.desktop', 'org.gnome.Settings.desktop']
DCONF_EOF

GDM_DB="/etc/dconf/db/gdm.d"
if [[ -f /etc/dconf/profile/gdm ]] && grep -q "system-db:gdm" /etc/dconf/profile/gdm 2>/dev/null; then
  mkdir -p "$GDM_DB"
  cat > "$GDM_DB/01-ci-os-gdm" <<GDM_EOF
[org/gnome/desktop/interface]
gtk-theme='$CI_GTK_THEME'

[org/gnome/desktop/background]
primary-color='#$CI_THEME_PRIMARY_HEX'
secondary-color='#$CI_THEME_SECONDARY_HEX'

[org/gnome/desktop/remote-desktop]
screen-sharing-enabled=true
remote-control-enabled=true

[org/gnome/desktop/remote-desktop/rdp]
enabled=true
view-only=false
GDM_EOF
fi

dconf_update_safe
log_success "System dconf defaults written (GNOME + dock on $CI_DOCK_POSITION, autohide=$CI_DOCK_AUTOHIDE)"
