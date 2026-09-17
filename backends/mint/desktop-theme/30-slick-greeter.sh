#!/usr/bin/env bash
# Slick-Greeter (LightDM) branding: renders a transparent CI mark PNG from the
# canon logo, writes /etc/lightdm/slick-greeter.conf (background/logo/theme),
# and drops a lightdm.conf.d file selecting slick-greeter as the active
# greeter. This is Mint's login-screen equivalent of Ubuntu's GDM/GNOME-Shell
# gresource branding — genuinely simpler, since slick-greeter reads its plain
# INI config live on every greeter launch (no glib-compile-resources, no
# gresource extraction/rebuild — see docs/architecture/multi-distro-design.md
# and this backend's implementation research).
#
# Unlike core/render/render-grub-background.sh, the logo is rendered as its
# OWN transparent PNG rather than flattened onto a CI_DARK_BACKGROUND canvas:
# slick-greeter composites `background=`/`background-color=` and `logo=` as
# independent keys itself, so painting a canvas here would just be thrown
# away. That's the one place this script's rendering step deliberately
# diverges from render-grub-background.sh's pattern rather than calling it.
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../core/lib/theme-lib.sh
source "$(cd "$_SCRIPT_DIR/../../.." && pwd)/core/lib/theme-lib.sh"
# shellcheck source=cinnamon-defaults.inc.sh
source "$_SCRIPT_DIR/cinnamon-defaults.inc.sh"
require_root

LOGO_SVG="$REPO_ROOT/vendor/brand/logos/mark.svg"
LOGO_DEST="/usr/share/pixmaps/ci-os-slick-greeter-logo.png"
# Not documented anywhere upstream (slick-greeter's man page and README are
# both silent on recommended logo dimensions) — 480px is a reasonable guess
# matching the scale other rendered CI marks use, not a verified value.
# TODO: verify visually on an actual Mint/slick-greeter login screen and
# adjust if the mark reads too large/small at typical display resolutions.
LOGO_PX=480

SLICK_CONF="/etc/lightdm/slick-greeter.conf"
LIGHTDM_DROPIN_DIR="/etc/lightdm/lightdm.conf.d"
LIGHTDM_DROPIN="$LIGHTDM_DROPIN_DIR/51-ci-os-greeter.conf"

if [[ ! -f "$LOGO_SVG" ]]; then
  log_error "Logo mark not found: $LOGO_SVG (expected from the vendored brand bundle)"
  exit 1
fi

if [[ ! -d /etc/lightdm ]]; then
  log_error "/etc/lightdm not found — is lightdm/slick-greeter installed?"
  exit 1
fi

mkdir -p "$(dirname "$LOGO_DEST")"

log_info "Rendering slick-greeter logo from the canon mark (transparent PNG, ${LOGO_PX}px)..."
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w "$LOGO_PX" -h "$LOGO_PX" -o "$LOGO_DEST" "$LOGO_SVG"
elif command -v magick >/dev/null 2>&1; then
  magick -background none -size "${LOGO_PX}x${LOGO_PX}" "$LOGO_SVG" "$LOGO_DEST"
elif command -v convert >/dev/null 2>&1; then
  convert -background none -size "${LOGO_PX}x${LOGO_PX}" "$LOGO_SVG" "$LOGO_DEST"
else
  log_error "Neither rsvg-convert nor ImageMagick found; cannot render the slick-greeter logo. Install rsvg-convert or imagemagick."
  exit 1
fi
chmod 644 "$LOGO_DEST"
log_success "Slick-greeter logo rendered: $LOGO_DEST"

CI_GTK_THEME="$(ci_select_cinnamon_gtk_theme)"
CI_ICON_THEME="$(ci_select_cinnamon_icon_theme)"
BG_HEX="$CI_DARK_BACKGROUND"

log_info "Writing $SLICK_CONF..."
cat > "$SLICK_CONF" <<EOF
[Greeter]
background=$BG_HEX
background-color=$BG_HEX
logo=$LOGO_DEST
theme-name=$CI_GTK_THEME
icon-theme-name=$CI_ICON_THEME
draw-user-backgrounds=false
EOF
chmod 644 "$SLICK_CONF"
log_success "slick-greeter.conf written (theme=$CI_GTK_THEME, icons=$CI_ICON_THEME)"

# Package-owned default lives at
# /usr/share/lightdm/lightdm.conf.d/50-slick-greeter.conf (lower priority,
# not touched here). Adding our own numerically-later file under /etc/ takes
# precedence via LightDM's standard conf.d merge order without editing
# anything the slick-greeter package ships.
mkdir -p "$LIGHTDM_DROPIN_DIR"
cat > "$LIGHTDM_DROPIN" <<EOF
[Seat:*]
greeter-session=slick-greeter
EOF
chmod 644 "$LIGHTDM_DROPIN"
log_success "LightDM greeter selection written: $LIGHTDM_DROPIN"

log_success "Slick-Greeter branding applied"
