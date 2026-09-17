#!/usr/bin/env bash
# Render a GRUB boot-menu background from the canon logo mark on a
# CI_DARK_BACKGROUND-colored canvas. Distro-portable: every backend that
# themes GRUB (Ubuntu/Mint today; Fedora/Arch later) calls this and installs
# the resulting PNG via its own mechanism — this script only renders it.
#
# Usage:
#   core/render/render-grub-background.sh [output_path] [width] [height]
#   Defaults: $REPO_ROOT/core/render/output/ci-os-grub-bg.png, 1920x1080
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/core/lib/theme-lib.sh"

OUTPUT_PATH="${1:-$REPO_ROOT/core/render/output/ci-os-grub-bg.png}"
WIDTH="${2:-1920}"
HEIGHT="${3:-1080}"
LOGO_SVG="$REPO_ROOT/vendor/brand/logos/mark.svg"

if [[ ! -f "$LOGO_SVG" ]]; then
  log_error "Logo mark not found: $LOGO_SVG (expected from the vendored brand bundle)"
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

# GRUB_GFXMODE=auto in configs/boot/grub-default means GRUB negotiates the
# actual display resolution at boot; 1920x1080 is a reasonable fixed canvas
# GRUB will scale as needed, matching how the rest of the canon's rendered
# assets (wallpaper, Plymouth watermark) are produced at a fixed size too.
BG_HEX="$CI_DARK_BACKGROUND"
# Logo sized to roughly a fifth of the canvas height, centered.
LOGO_PX=$(( HEIGHT / 5 ))

if command -v rsvg-convert >/dev/null 2>&1; then
  log_info "Rendering GRUB background with rsvg-convert..."
  tmp_logo="$(mktemp --suffix=.png 2>/dev/null || mktemp -t cios-logo).png"
  rsvg-convert -w "$LOGO_PX" -h "$LOGO_PX" -o "$tmp_logo" "$LOGO_SVG"
  if command -v magick >/dev/null 2>&1; then
    magick -size "${WIDTH}x${HEIGHT}" "xc:${BG_HEX}" "$tmp_logo" -gravity center -composite "$OUTPUT_PATH"
  elif command -v convert >/dev/null 2>&1; then
    convert -size "${WIDTH}x${HEIGHT}" "xc:${BG_HEX}" "$tmp_logo" -gravity center -composite "$OUTPUT_PATH"
  else
    log_error "rsvg-convert produced the logo, but neither 'magick' nor 'convert' (ImageMagick) is available to compose the background."
    rm -f "$tmp_logo"
    exit 1
  fi
  rm -f "$tmp_logo"
elif command -v magick >/dev/null 2>&1; then
  log_info "Rendering GRUB background with ImageMagick (magick)..."
  magick -background "$BG_HEX" -size "${LOGO_PX}x${LOGO_PX}" "$LOGO_SVG" -gravity center -extent "${WIDTH}x${HEIGHT}" "$OUTPUT_PATH"
elif command -v convert >/dev/null 2>&1; then
  log_info "Rendering GRUB background with ImageMagick (convert)..."
  convert -background "$BG_HEX" -size "${LOGO_PX}x${LOGO_PX}" "$LOGO_SVG" -gravity center -extent "${WIDTH}x${HEIGHT}" "$OUTPUT_PATH"
else
  log_warn "Neither rsvg-convert nor ImageMagick found — writing a solid-color background with no logo."
  printf 'P6\n%d %d\n255\n' "$WIDTH" "$HEIGHT" > "$OUTPUT_PATH"
  log_error "No image tool available; GRUB background will not have the logo mark. Install rsvg-convert or imagemagick."
  exit 1
fi

log_success "GRUB background rendered: $OUTPUT_PATH"
