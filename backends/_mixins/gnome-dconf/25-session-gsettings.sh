#!/usr/bin/env bash
# Apply GNOME session settings for the active desktop user (or current user if non-root).
# Intended to mirror /etc/dconf defaults so logged-in users see changes immediately.
set -euo pipefail
_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../core/lib/theme-lib.sh
source "$(cd "$_COMMON/../../.." && pwd)/core/lib/theme-lib.sh"
# shellcheck source=gnome-defaults.inc.sh
source "$_COMMON/gnome-defaults.inc.sh"

CI_GTK_THEME="$(ci_select_gtk_theme)"
WALL_URI="$(ci_wallpaper_uri)"

_gs() {
  if [[ -n "${_GS_RUN[@]:-}" ]]; then
    "${_GS_RUN[@]}" gsettings set "$1" "$2" "$3" 2>/dev/null || true
  else
    gsettings set "$1" "$2" "$3" 2>/dev/null || true
  fi
}

_run_block() {
  _gs org.gnome.desktop.interface gtk-theme "$CI_GTK_THEME"
  _gs org.gnome.desktop.interface icon-theme "Yaru"
  _gs org.gnome.desktop.interface cursor-theme "Yaru"
  _gs org.gnome.desktop.background primary-color "#${CI_THEME_PRIMARY_HEX}"
  _gs org.gnome.desktop.background secondary-color "#${CI_THEME_SECONDARY_HEX}"
  if [[ -n "$WALL_URI" ]]; then
    _gs org.gnome.desktop.background picture-uri "$WALL_URI"
    _gs org.gnome.desktop.background picture-uri-dark "$WALL_URI"
  fi
  _gs org.gnome.shell.extensions.dash-to-dock dock-fixed "$CI_DOCK_FIXED"
  _gs org.gnome.shell.extensions.dash-to-dock dock-position "$CI_DOCK_POSITION"
  _gs org.gnome.shell.extensions.dash-to-dock extend-height "$CI_DOCK_EXTEND_HEIGHT"
  _gs org.gnome.shell.extensions.dash-to-dock dash-max-icon-size "$CI_DOCK_MAX_ICON"
  _gs org.gnome.shell.extensions.dash-to-dock autohide "$CI_DOCK_AUTOHIDE"
  _gs org.gnome.desktop.wm.preferences button-layout "close,minimize,maximize:"
  _gs org.gnome.desktop.wm.preferences focus-mode "click"
  _gs org.gnome.shell favorite-apps "$CI_FAVORITE_APPS"
  _gs org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
  _gs org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 1800
  _gs org.gnome.desktop.privacy disable-microphone false
  _gs org.gnome.desktop.privacy disable-camera false
  _gs org.gnome.Terminal.Legacy.Settings default-show-menubar false
  _gs org.gnome.Terminal.Legacy.Settings theme-variant "dark"
  _gs com.ubuntu.update-notifier no-show-notifications false
  _gs org.gnome.desktop.remote-desktop screen-sharing-enabled true
  _gs org.gnome.desktop.remote-desktop remote-control-enabled true
  _gs org.gnome.desktop.remote-desktop.rdp enabled true
  _gs org.gnome.desktop.remote-desktop.rdp view-only false
  if ((${#_GS_RUN[@]})); then
    sudo -u "$ACTUAL_USER" env DISPLAY=:0 "XAUTHORITY=/home/${ACTUAL_USER}/.Xauthority" \
      "DBUS_SESSION_BUS_ADDRESS=${DBUS_ADDRESS}" xdg-settings set default-web-browser "$CI_DEFAULT_BROWSER_DESKTOP" 2>/dev/null || true
  else
    xdg-settings set default-web-browser "$CI_DEFAULT_BROWSER_DESKTOP" 2>/dev/null || true
  fi
}

if [[ ${EUID:-0} -ne 0 ]]; then
  if ! command -v gsettings >/dev/null 2>&1; then
    log_warn "gsettings not available; skipping live session apply"
    exit 0
  fi
  declare -a _GS_RUN=()
  log_info "Applying CI GNOME session defaults to current user ($(whoami))"
  _run_block
  log_success "Session gsettings applied"
  exit 0
fi

require_root

ACTUAL_USER="${SUDO_USER:-}"
[[ -z "$ACTUAL_USER" || "$ACTUAL_USER" == "root" ]] && ACTUAL_USER="$(who -u 2>/dev/null | awk '{print $1; exit}' || true)"

if ! command -v gsettings >/dev/null 2>&1; then
  log_warn "gsettings not installed; skipping live session apply"
  exit 0
fi

if [[ -z "$ACTUAL_USER" || "$ACTUAL_USER" == "root" ]]; then
  log_warn "No non-root desktop user detected; session gsettings skipped (defaults apply on next login)"
  exit 0
fi

UID_NUM="$(id -u "$ACTUAL_USER" 2>/dev/null || true)"
RUNTIME_DIR="/run/user/${UID_NUM}"
DBUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus"

if [[ ! -S "${RUNTIME_DIR}/bus" ]]; then
  log_warn "No session D-Bus for $ACTUAL_USER; GNOME settings will apply on next login from dconf defaults"
  exit 0
fi

declare -a _GS_RUN=(sudo -u "$ACTUAL_USER" env DISPLAY=:0 "XAUTHORITY=/home/${ACTUAL_USER}/.Xauthority" "DBUS_SESSION_BUS_ADDRESS=$DBUS_ADDRESS")

log_info "Applying CI GNOME session defaults to user: $ACTUAL_USER"
_run_block
log_success "Session gsettings applied for $ACTUAL_USER"
