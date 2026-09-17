#!/usr/bin/env bash
# System-wide dconf defaults for Cinnamon (theme/background/panel/favorites),
# PLUS live gsettings application for the current desktop user.
#
# Ubuntu splits this into two files: 20-dconf-system.sh (system defaults,
# root-only) and 25-session-gsettings.sh (live apply, works either as the
# logged-in user with no sudo, or as root applying to $SUDO_USER). Mint folds
# both into this one file — the research for this backend found no genuine
# difference in *how* Cinnamon's live session is updated (same `gsettings set`
# over the user's D-Bus session bus GNOME uses; see
# docs/architecture/multi-distro-design.md), so a separate near-empty
# 25-cinnamon-session.sh would just be this file's live-apply half copy-pasted
# into its own file. The dual entry point Ubuntu's split gave callers (root:
# writes system defaults + live-applies; non-root: live-applies only, for
# "apply to just my own session" use) is preserved below via the EUID check.
#
# Also installs the CI wallpaper (Ubuntu does this in a separate
# 30-wallpaper.sh; here it's a few lines folded in since item 1 of this
# backend's brief scopes "background" settings to this file, and slot 30 is
# reserved for 30-slick-greeter.sh).
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../core/lib/theme-lib.sh
source "$(cd "$_SCRIPT_DIR/../../.." && pwd)/core/lib/theme-lib.sh"
# shellcheck source=cinnamon-defaults.inc.sh
source "$_SCRIPT_DIR/cinnamon-defaults.inc.sh"

CI_GTK_THEME="$(ci_select_cinnamon_gtk_theme)"
CI_ICON_THEME="$(ci_select_cinnamon_icon_theme)"

install_wallpaper() {
  local src="$ASSET_INPUTS_DIR/background.png"
  if [[ ! -f "$src" ]]; then
    # A missing packaged brand asset signals a broken checkout/build, not an
    # expected runtime condition — fail hard here, matching Ubuntu's own
    # 30-wallpaper.sh and this backend's own 30-slick-greeter.sh.
    log_error "Wallpaper input not found: $src"
    exit 1
  fi
  mkdir -p /usr/share/backgrounds
  cp "$src" /usr/share/backgrounds/ci-os-wallpaper.png
  chmod 644 /usr/share/backgrounds/ci-os-wallpaper.png
}

write_system_dconf_defaults() {
  local wall_uri
  wall_uri="$(ci_wallpaper_uri)"

  mkdir -p /etc/dconf/db/local.d
  cat > /etc/dconf/db/local.d/01-ci-os-cinnamon-defaults <<DCONF_EOF
[org/cinnamon/desktop/interface]
gtk-theme='$CI_GTK_THEME'
icon-theme='$CI_ICON_THEME'

[org/cinnamon/theme]
name='$CI_GTK_THEME'

[org/cinnamon/desktop/background]
primary-color='#$CI_THEME_PRIMARY_HEX'
secondary-color='#$CI_THEME_SECONDARY_HEX'
color-shading-type='solid'
DCONF_EOF

  if [[ -n "$wall_uri" ]]; then
    cat >> /etc/dconf/db/local.d/01-ci-os-cinnamon-defaults <<DCONF_EOF
picture-uri='$wall_uri'
picture-options='zoom'
DCONF_EOF
  fi

  cat >> /etc/dconf/db/local.d/01-ci-os-cinnamon-defaults <<DCONF_EOF

[org/cinnamon]
panels-autohide=$CI_CINNAMON_PANELS_AUTOHIDE
favorite-apps=$CI_FAVORITE_APPS

[org/cinnamon/desktop/wm/preferences]
button-layout='close,minimize,maximize:'
focus-mode='click'

[org/cinnamon/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=1800
DCONF_EOF

  dconf_update_safe
  log_success "System dconf defaults written (Cinnamon theme=$CI_GTK_THEME, panel $CI_CINNAMON_PANEL_ID autohide)"
}

_gs() {
  if [[ -n "${_GS_RUN[*]:-}" ]]; then
    "${_GS_RUN[@]}" gsettings set "$1" "$2" "$3" 2>/dev/null || true
  else
    gsettings set "$1" "$2" "$3" 2>/dev/null || true
  fi
}

apply_live_session() {
  local wall_uri
  wall_uri="$(ci_wallpaper_uri)"

  _gs org.cinnamon.desktop.interface gtk-theme "$CI_GTK_THEME"
  _gs org.cinnamon.desktop.interface icon-theme "$CI_ICON_THEME"
  _gs org.cinnamon.theme name "$CI_GTK_THEME"
  _gs org.cinnamon.desktop.background primary-color "#${CI_THEME_PRIMARY_HEX}"
  _gs org.cinnamon.desktop.background secondary-color "#${CI_THEME_SECONDARY_HEX}"
  _gs org.cinnamon.desktop.background color-shading-type "solid"
  if [[ -n "$wall_uri" ]]; then
    _gs org.cinnamon.desktop.background picture-uri "$wall_uri"
    _gs org.cinnamon.desktop.background picture-options "zoom"
  fi
  _gs org.cinnamon panels-autohide "$CI_CINNAMON_PANELS_AUTOHIDE"
  _gs org.cinnamon favorite-apps "$CI_FAVORITE_APPS"
  _gs org.cinnamon.desktop.wm.preferences button-layout "close,minimize,maximize:"
  _gs org.cinnamon.desktop.wm.preferences focus-mode "click"
  _gs org.cinnamon.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
  _gs org.cinnamon.settings-daemon.plugins.power sleep-inactive-battery-timeout 1800
}

if [[ ${EUID:-0} -ne 0 ]]; then
  # Non-root invocation: session-only, mirrors Ubuntu's
  # "run gnome-settings.sh yourself, no sudo" entry point. Can't write system
  # dconf defaults (needs root), so just live-apply to the caller's own session.
  if ! command -v gsettings >/dev/null 2>&1; then
    log_warn "gsettings not available; skipping live session apply"
    exit 0
  fi
  declare -a _GS_RUN=()
  log_info "Applying CI Cinnamon session defaults to current user ($(whoami))"
  apply_live_session
  log_success "Session gsettings applied"
  exit 0
fi

require_root

install_wallpaper
write_system_dconf_defaults

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
  log_warn "No session D-Bus for $ACTUAL_USER; Cinnamon settings will apply on next login from dconf defaults"
  exit 0
fi

declare -a _GS_RUN=(sudo -u "$ACTUAL_USER" env DISPLAY=:0 "XAUTHORITY=/home/${ACTUAL_USER}/.Xauthority" "DBUS_SESSION_BUS_ADDRESS=$DBUS_ADDRESS")

log_info "Applying CI Cinnamon session defaults to user: $ACTUAL_USER"
apply_live_session
log_success "Session gsettings applied for $ACTUAL_USER"
