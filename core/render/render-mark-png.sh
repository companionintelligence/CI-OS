#!/usr/bin/env bash
# Render the canon logo mark to a square 8-bit RGBA PNG (no interlace, transparent background).
# Distro-portable, and meant to run on the BUILD HOST: the stock Ubuntu desktop image has neither
# rsvg-convert nor ImageMagick, so customize-chroot.sh renders here and installs the PNGs inside
# the chroot (Settings > About logo, greeter logo).
#
# Usage:
#   core/render/render-mark-png.sh <out.png> <px> [fill-hex]
#   No fill-hex: the three-tone colour mark (vendor/brand/logos/mark.svg).
#   fill-hex (#rrggbb): the one-colour mark (vendor/brand/logos/mark-mono.svg, whose
#   `currentColor` is replaced by fill-hex). Pass a CI_* token from tokens.sh, never a literal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/core/lib/theme-lib.sh"

OUT_PNG="${1:-}"
PX="${2:-}"
FILL_HEX="${3:-}"

if [[ -z "$OUT_PNG" || ! "$PX" =~ ^[0-9]+$ || "$PX" -lt 1 ]]; then
  log_error "usage: $0 <out.png> <px> [fill-hex]"
  exit 2
fi

HEX_RE='^#[0-9a-fA-F]{6}$'
if [[ -n "$FILL_HEX" ]]; then
  if [[ ! "$FILL_HEX" =~ $HEX_RE ]]; then
    log_error "fill must be #rrggbb, got: $FILL_HEX"
    exit 2
  fi
  SRC_SVG="$REPO_ROOT/vendor/brand/logos/mark-mono.svg"
else
  SRC_SVG="$REPO_ROOT/vendor/brand/logos/mark.svg"
fi

if [[ ! -f "$SRC_SVG" ]]; then
  log_error "Logo mark not found: $SRC_SVG (expected from the vendored brand bundle)"
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/ci-mark.XXXXXX")"
trap 'rm -rf "$work"' EXIT

svg="$work/mark.svg"
if [[ -n "$FILL_HEX" ]]; then
  sed "s/currentColor/${FILL_HEX}/g" "$SRC_SVG" > "$svg"
else
  cp "$SRC_SVG" "$svg"
fi

# ImageMagick's built-in SVG renderer ignores <style> class rules and paints every path black (librsvg
# honours them). Fold each ".cls-N{fill:X;}" rule into fill attributes so either renderer gives the same pixels.
inline_class_fills() {
  local rules n fill sedscript=""
  rules="$(tr -d '\n' < "$svg" | sed -n 's/.*<style>\(.*\)<\/style>.*/\1/p' | tr '}' '\n' | awk -F'{' '
    NF == 2 && match($2, /fill:[^;]+/) {
      fill = substr($2, RSTART + 5, RLENGTH - 5)
      n = split($1, sel, ",")
      for (i = 1; i <= n; i++) { sub(/^\.cls-/, "", sel[i]); print sel[i], fill }
    }')"
  while read -r n fill; do
    [[ -n "$n" ]] && sedscript="${sedscript}s/class=\"cls-${n}\"/fill=\"${fill}\"/g;"
  done <<< "$rules"
  if [[ -n "$sedscript" ]]; then
    sed "$sedscript" "$svg" > "$svg.inlined" && mv "$svg.inlined" "$svg"
  fi
}

mkdir -p "$(dirname "$OUT_PNG")"
png="$work/mark.png"

if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w "$PX" -h "$PX" -f png -o "$png" "$svg"
elif command -v magick >/dev/null 2>&1; then
  inline_class_fills
  # Rasterise well above the target, then scale down, so edges stay crisp whichever SVG delegate ImageMagick has.
  magick -background none -density 384 "$svg" -resize "${PX}x${PX}" -depth 8 -interlace none PNG32:"$png"
elif command -v convert >/dev/null 2>&1; then
  inline_class_fills
  convert -background none -density 384 "$svg" -resize "${PX}x${PX}" -depth 8 -interlace none PNG32:"$png"
else
  log_error "Neither rsvg-convert nor ImageMagick (magick/convert) found; cannot render the logo mark. Install librsvg2-bin or imagemagick."
  exit 1
fi

# Not mv: $work and the destination may be on different filesystems (a chroot or a bind mount).
cp "$png" "$OUT_PNG"
chmod 644 "$OUT_PNG"
log_info "Rendered ${PX}px ${FILL_HEX:+${FILL_HEX} }logo mark: $OUT_PNG"
