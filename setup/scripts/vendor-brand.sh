#!/usr/bin/env bash
# vendor-brand.sh — pull the pinned Companion Intelligence brand bundle into vendor/brand/.
#
# CI-OS is bash + image overlays, no npm: it consumes the canon as the brand bundle
# CI-Common attaches to every @companionintelligence/tokens release (CI-Common
# CONSUMING.md, Route B). tokens/tokens.sh is sourced by the desktop/boot theming
# scripts; tokens.css + the Manrope woff2 serve the captive setup portal; the logos
# feed Plymouth, the start icon and the portal.
#
#   setup/scripts/vendor-brand.sh [version]   # default: vendor/brand/.version
#   setup/scripts/vendor-brand.sh --check     # verify against SHA256SUMS (CI + 80-validate)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/../../vendor/brand"
if [ "${1:-}" = "--check" ]; then
  ( cd "$OUT" && shasum -a 256 -c SHA256SUMS --quiet ) && echo "✔ brand assets match ci-brand $(cat "$OUT/.version")"
  exit $?
fi
VERSION="${1:-$(cat "$OUT/.version")}"
TAG="@companionintelligence/tokens@${VERSION}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
gh release download "$TAG" --repo companionintelligence/CI-Common --pattern "ci-brand-${VERSION}.tar.gz*" --dir "$tmp"
( cd "$tmp" && shasum -a 256 -c "ci-brand-${VERSION}.tar.gz.sha256" --quiet )
tar -xzf "$tmp/ci-brand-${VERSION}.tar.gz" -C "$tmp"
B="$tmp/ci-brand-${VERSION}"
mkdir -p "$OUT/tokens" "$OUT/fonts" "$OUT/logos"
cp "$B/tokens/tokens.sh" "$B/tokens/tokens.css" "$B/tokens/tokens.json" "$OUT/tokens/"
cp "$B/fonts/manrope-latin-var.woff2" "$B/fonts/LICENSE-Manrope.txt" "$OUT/fonts/"
cp "$B/logos/mark.svg" "$B/logos/lockup.svg" "$B/logos/mark-mono.svg" "$OUT/logos/"
grep -E 'tokens/tokens\.(sh|css|json)|fonts/manrope-latin-var\.woff2|LICENSE-Manrope|logos/(mark|lockup|mark-mono)\.svg' "$B/SHA256SUMS" > "$OUT/SHA256SUMS"
echo "$VERSION" > "$OUT/.version"
( cd "$OUT" && shasum -a 256 -c SHA256SUMS --quiet )
echo "vendored ci-brand ${VERSION} into vendor/brand"
