#!/usr/bin/env bash
# render-installer-assets.sh -- the hook the ISO build calls to put the installer overlay into the staging tree.
#
#   CI_OS_STAGING_DIR=<dir> backends/cachyos/installer/render-installer-assets.sh
#
# Two steps: stage-installer.sh (assembles the overlay: configs, scripts, token-filled branding, the target payload), then the
# pictures the Calamares branding component needs, rendered from the brand canon with the shared renderer (core/render/*, not
# duplicated here) and never committed:
#   branding/companion/logo.png     128x128, the sidebar logo (Calamares draws it at 80x80)
#   branding/companion/icon.png     128x128, the window icon
#   branding/companion/welcome.png  192x192, the picture on the welcome page
# All three are the colour logo mark (vendor/brand/logos/mark.svg), whose three teals read on the dark sidebar and on a light or
# dark welcome page alike. No CachyOS image is read or copied (decision D9).
#
# Called by the ISO build (iso/scripts/render-assets.sh or its caller) after the packages named in iso/render-deps.txt are
# installed: needs librsvg or ImageMagick, as core/render/render-mark-png.sh does.
# Environment: as stage-installer.sh (CI_OS_STAGING_DIR, CI_OS_REPO_ROOT, CI_OS_VERSION).
set -euo pipefail
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${CI_OS_REPO_ROOT:-$(cd "$HERE/../../.." && pwd)}"

bash "$HERE/stage-installer.sh"

OUT="$(cd "$CI_OS_STAGING_DIR" && pwd)"
B="$OUT/airootfs/usr/share/ci-os/calamares/branding/companion"
[ -d "$B" ] || { printf 'render-installer-assets: %s was not created by stage-installer.sh\n' "$B" >&2; exit 1; }

MARK="$REPO/core/render/render-mark-png.sh"
[ -f "$MARK" ] || { printf 'render-installer-assets: %s not found\n' "$MARK" >&2; exit 1; }
for spec in logo.png:128 icon.png:128 welcome.png:192; do
  bash "$MARK" "$B/${spec%%:*}" "${spec##*:}" > /dev/null
  chmod 644 "$B/${spec%%:*}"
done
printf 'render-installer-assets: rendered logo.png, icon.png and welcome.png into %s\n' "${B#"$OUT"/}"
