#!/usr/bin/env bash
# Thin Ubuntu-specific caller for core/render/render-gnome-shell-gresource.sh
# (the generic mechanic — extract/replace-assets/recolor/recompile), passing
# Yaru as the source theme and this directory's Yaru-specific color-map and
# audit-patterns data files. See docs/architecture/multi-distro-design.md.
set -euo pipefail

# SCRIPT_DIR is backends/ubuntu/iso/scripts/ — four levels below the repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../vendor/brand/tokens/tokens.sh
source "$REPO_ROOT/vendor/brand/tokens/tokens.sh"

export THEME_NAME="Yaru"
export COLOR_MAP_FILE="$SCRIPT_DIR/yaru-color-map.pl"
export AUDIT_PATTERNS_FILE="$SCRIPT_DIR/yaru-audit-patterns.txt"
export OUTPUT_GRESOURCE="${OUTPUT_GRESOURCE:-$REPO_ROOT/backends/ubuntu/packages/ci-os-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource}"
export THEME_ASSETS_DIR="${THEME_ASSETS_DIR:-$REPO_ROOT/assets/package theme assets}"
export LOGO_BANNER_FILE="${LOGO_BANNER_FILE:-$REPO_ROOT/assets/logos/2024_CI__Logo_Banner_Color_small.svg}"

# Canon primary tokens (phthalo/sage), not the old logo-ramp literals. The
# color map's two anchor substitutions use these; the ~28 intermediate hex
# values in yaru-color-map.pl are a hand-tuned luminance ramp between them,
# not a 1:1 token mapping — see docs/architecture/multi-distro-design.md.
export ACCENT_PRIMARY="$CI_DARK_PRIMARY"
export ACCENT_SECONDARY="$CI_LIGHT_PRIMARY"
export ACCENT_PRIMARY_RGB="$(ci_rgb "$ACCENT_PRIMARY" | tr ' ' ',')"
export ACCENT_SECONDARY_RGB="$(ci_rgb "$ACCENT_SECONDARY" | tr ' ' ',')"

exec bash "$REPO_ROOT/core/render/render-gnome-shell-gresource.sh"
