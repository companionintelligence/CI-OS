#!/usr/bin/env bash
# KDE Plasma: CI-OS-Dark color scheme (+ optional wallpaper). GNOME users: skip this step.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
_klog_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
_klog_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
_klog_err() { echo -e "${RED}[ERROR]${NC} $*"; }
_klog_ok() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

if [[ -z "${KDE_FULL_SESSION:-}" ]] && [[ ! -f /usr/bin/kwriteconfig5 ]] && [[ ! -d /usr/share/plasma ]]; then
  _klog_err "KDE Plasma not detected (no kwriteconfig5 / plasma)."
  _klog_info "For GNOME: sudo $REPO_ROOT/backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh"
  exit 1
fi

COLOR_SCHEME_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/CI-OS-Dark.colors"
COLOR_SCHEME_DEST_GLOBAL="/usr/share/color-schemes/CI-OS-Dark.colors"
COLOR_SCHEME_DEST_USER="${HOME}/.local/share/color-schemes/CI-OS-Dark.colors"

if [[ ! -f "$COLOR_SCHEME_SOURCE" ]]; then
  _klog_err "Color scheme not found: $COLOR_SCHEME_SOURCE"
  exit 1
fi

if [[ ${EUID:-0} -eq 0 ]]; then
  _klog_info "Installing Companion OS color scheme globally..."
  mkdir -p "$(dirname "$COLOR_SCHEME_DEST_GLOBAL")"
  cp "$COLOR_SCHEME_SOURCE" "$COLOR_SCHEME_DEST_GLOBAL"
  chmod 644 "$COLOR_SCHEME_DEST_GLOBAL"
  _klog_ok "Installed: $COLOR_SCHEME_DEST_GLOBAL"
else
  _klog_info "Installing Companion OS color scheme for current user..."
  mkdir -p "$(dirname "$COLOR_SCHEME_DEST_USER")"
  cp "$COLOR_SCHEME_SOURCE" "$COLOR_SCHEME_DEST_USER"
  _klog_ok "Installed: $COLOR_SCHEME_DEST_USER"
fi

if command -v kwriteconfig5 >/dev/null 2>&1; then
  _klog_info "Applying color scheme to session..."
  kwriteconfig5 --file kdeglobals --group General --key ColorScheme "CI-OS-Dark"
  kwriteconfig5 --file breezerc --group Common --key OutlineCloseButton true

  WALLPAPER_SOURCE="$ASSET_INPUTS_DIR/background.png"
  if [[ -f "$WALLPAPER_SOURCE" ]] && command -v qdbus >/dev/null 2>&1; then
    qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
      var allDesktops = desktops();
      for (i=0;i<allDesktops.length;i++) {
        d = allDesktops[i];
        d.wallpaperPlugin = 'org.kde.image';
        d.currentConfigGroup = Array('Wallpaper', 'org.kde.image', 'General');
        d.writeConfig('Image', 'file://$WALLPAPER_SOURCE');
      }
    " 2>/dev/null && _klog_ok "KDE wallpaper set" || _klog_warn "Could not set KDE wallpaper via qdbus"
  fi
  _klog_ok "KDE theme applied (log out/in if colors do not refresh)"
else
  _klog_warn "kwriteconfig5 not found. Install scheme manually: System Settings → Appearance → Colors → Companion OS Dark"
fi
