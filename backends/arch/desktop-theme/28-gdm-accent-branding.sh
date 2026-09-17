#!/usr/bin/env bash
# Arch GDM/GNOME-Shell branding step — accent-color + color-scheme, NOT a
# gresource rebuild. This file is deliberately near-identical to
# backends/fedora/desktop-theme/28-gdm-accent-branding.sh (read in full
# before writing this) — the underlying GNOME packaging fact it depends on
# is not Fedora-specific, and this backend's own research independently
# confirmed it holds for Arch too rather than assuming Fedora's finding
# transfers for free. Summary:
#
# On Arch (extra/x86_64/gnome-shell), GNOME Shell's theme is NOT a separate,
# add-alongside package the way Ubuntu's yaru-theme-gnome-shell is — like
# Fedora, it's compiled directly into the gnome-shell package's own build,
# landing at /usr/share/gnome-shell/gnome-shell-theme.gresource with no
# theme-name subdirectory. This is upstream GNOME's own packaging shape
# (data/gnome-shell-theme.gresource.xml in the gnome-shell source tree
# itself, present since GNOME 3.16), not a Fedora-specific patch — Arch
# tracks upstream even more closely than Fedora (fewer distro patches), so
# there was no reason to expect Arch to differ here, and it doesn't.
# Overwriting that file (the approach core/render/render-gnome-shell-gresource.sh
# implements, and that backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh
# drives for Yaru) would be silently clobbered by every `pacman -Syu` that
# touches gnome-shell — a frequent event on a rolling-release distro, if
# anything more frequent than Fedora's own update cadence — because there is
# no separate package to pin or reinstall against. GNOME 47+ instead ships a
# supported org.gnome.desktop.interface accent-color enum (nine named
# colors) that Shell CSS and libadwaita apps derive their accent styling
# from directly, with no recompiling. GDM needs no separate handling either:
# GDM *is* gnome-shell running in "gdm" mode, styled by the same interface
# schema via a dconf profile for the gdm user — there is no separate
# gdm.css/gresource to extract on Arch either. core/render/render-gnome-shell-gresource.sh
# is therefore intentionally NOT invoked anywhere in this backend, same as Fedora.
#
# --- Corrective role -------------------------------------------------------
# This step also fixes up two hardcoded-Yaru values left behind by
# backends/_mixins/gnome-dconf/20-dconf-system.sh and 25-session-gsettings.sh,
# which this backend reuses BY PATH ahead of this step (see
# apply-ci-os-desktop.sh) for the same reason Fedora does: everything else in
# them — token-derived background colors, dock/power/privacy settings, GDM
# dconf-profile plumbing — is genuinely distro-portable. Their gtk-theme
# comes from gnome-defaults.inc.sh's ci_select_gtk_theme(), hardcoded to
# Yaru-* names; their dconf heredoc separately hardcodes icon-theme='Yaru' /
# cursor-theme='Yaru' as bare literals (not even routed through a function).
# None of those names exist on Arch.
#
# Per Fedora's own header (re-verified, not re-litigated, for this backend):
# a small Arch .inc.sh "sourced AFTER the mixin so it overrides just that one
# function" does NOT work — 20-dconf-system.sh and 25-session-gsettings.sh
# each unconditionally re-source backends/_mixins/gnome-dconf/gnome-defaults.inc.sh
# from their OWN hardcoded relative path as their first act, which redefines
# ci_select_gtk_theme() back to the Yaru version no matter what a caller
# sourced beforehand. `readonly -f` to block that redefinition doesn't
# silently no-op either — it makes the mixin's own `source` line fail
# outright under `set -e`. Editing backends/_mixins/ content is out of scope
# for this pass regardless.
#
# So instead: this step runs AFTER those mixin steps (see
# apply-ci-os-desktop.sh's fixed step order) and layers a HIGHER-NUMBERED
# dconf fragment on top of theirs — dconf's db/*.d directories merge every
# fragment file in a directory in filename sort order, per key, with a later
# file winning ties on the same key (the same convention
# backends/_mixins/gnome-dconf/27-terminal-theme.sh already relies on,
# numbered 03-, alongside 20-dconf-system.sh's 01- and Ubuntu's
# 30-wallpaper.sh's 02-, and Fedora's own 05- override). This file writes
# 05-ci-os-arch-overrides, which redeclares gtk-theme/icon-theme/cursor-theme
# with Arch-correct values and adds accent-color/color-scheme, then
# reapplies the same values live via gsettings.
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$_SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../core/lib/theme-lib.sh
source "$REPO_ROOT/core/lib/theme-lib.sh"
# shellcheck source=gnome-defaults-arch-overrides.inc.sh
source "$_SCRIPT_DIR/gnome-defaults-arch-overrides.inc.sh"

CI_GTK_THEME="$(ci_select_gtk_theme)"
CI_ICON_THEME="$(ci_select_icon_theme)"
CI_CURSOR_THEME="$(ci_select_cursor_theme)"
CI_ACCENT="$(ci_select_accent_color)"
CI_COLOR_SCHEME="$(ci_select_color_scheme)"

DCONF_FRAGMENT_NAME="05-ci-os-arch-overrides"

write_system_override() {
  mkdir -p /etc/dconf/db/local.d
  cat > "/etc/dconf/db/local.d/${DCONF_FRAGMENT_NAME}" <<DCONF_EOF
[org/gnome/desktop/interface]
gtk-theme='$CI_GTK_THEME'
icon-theme='$CI_ICON_THEME'
cursor-theme='$CI_CURSOR_THEME'
accent-color='$CI_ACCENT'
color-scheme='$CI_COLOR_SCHEME'
DCONF_EOF

  # Same GDM-profile guard 20-dconf-system.sh uses: only write a gdm.d
  # fragment if the gdm user actually has its own dconf system-db profile.
  # Arch's gdm package ships /etc/dconf/profile/gdm the same way Fedora's
  # does (both follow upstream GDM's own packaging convention) — not
  # independently re-verified against a live Arch box for this pass.
  if [[ -f /etc/dconf/profile/gdm ]] && grep -q "system-db:gdm" /etc/dconf/profile/gdm 2>/dev/null; then
    mkdir -p /etc/dconf/db/gdm.d
    cat > "/etc/dconf/db/gdm.d/${DCONF_FRAGMENT_NAME}" <<DCONF_EOF
[org/gnome/desktop/interface]
gtk-theme='$CI_GTK_THEME'
accent-color='$CI_ACCENT'
color-scheme='$CI_COLOR_SCHEME'
DCONF_EOF
  fi

  dconf_update_safe
  log_success "Arch dconf overrides written (accent=$CI_ACCENT, color-scheme=$CI_COLOR_SCHEME, gtk/icon/cursor-theme=$CI_GTK_THEME)"
}

_gs() {
  if [[ -n "${_GS_RUN[*]:-}" ]]; then
    "${_GS_RUN[@]}" gsettings set "$1" "$2" "$3" 2>/dev/null || true
  else
    gsettings set "$1" "$2" "$3" 2>/dev/null || true
  fi
}

apply_live_session() {
  _gs org.gnome.desktop.interface gtk-theme "$CI_GTK_THEME"
  _gs org.gnome.desktop.interface icon-theme "$CI_ICON_THEME"
  _gs org.gnome.desktop.interface cursor-theme "$CI_CURSOR_THEME"
  _gs org.gnome.desktop.interface accent-color "$CI_ACCENT"
  _gs org.gnome.desktop.interface color-scheme "$CI_COLOR_SCHEME"
}

if [[ ${EUID:-0} -ne 0 ]]; then
  # Non-root invocation: session-only, mirroring the mixin's own
  # 25-session-gsettings.sh non-root path.
  if ! command -v gsettings >/dev/null 2>&1; then
    log_warn "gsettings not available; skipping live session apply"
    exit 0
  fi
  declare -a _GS_RUN=()
  log_info "Applying CI Arch accent-color session defaults to current user ($(whoami))"
  apply_live_session
  log_success "Session gsettings applied"
  exit 0
fi

require_root

write_system_override

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
  log_warn "No session D-Bus for $ACTUAL_USER; Arch accent-color settings will apply on next login from dconf defaults"
  exit 0
fi

declare -a _GS_RUN=(sudo -u "$ACTUAL_USER" env DISPLAY=:0 "XAUTHORITY=/home/${ACTUAL_USER}/.Xauthority" "DBUS_SESSION_BUS_ADDRESS=$DBUS_ADDRESS")

log_info "Applying CI Arch accent-color session defaults to user: $ACTUAL_USER"
apply_live_session
log_success "Session gsettings applied for $ACTUAL_USER"
