#!/usr/bin/env bash
# The logo/font files the image build copies into place are mirrors of vendor/brand/*
# (the org origin, via the brand bundle). --write rewrites them; default verifies.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# dest|src pairs (bash 3 compatible — no associative arrays)
PAIRS="
assets/logos/2024_CI__LogoMark_Color_med.svg|vendor/brand/logos/mark.svg
assets/logos/2024_CI__Logo_Banner_Color_small.svg|vendor/brand/logos/lockup.svg
core/headless/payload/var/www/setup-portal/logo.svg|vendor/brand/logos/mark.svg
core/headless/payload/var/www/setup-portal/fonts/manrope-latin-var.woff2|vendor/brand/fonts/manrope-latin-var.woff2
"
rc=0
for pair in $PAIRS; do
  dest="${pair%%|*}"; src="${pair##*|}"
  if [ "${1:-}" = "--write" ]; then cp "$ROOT/$src" "$ROOT/$dest"; continue; fi
  if ! cmp -s "$ROOT/$src" "$ROOT/$dest"; then echo "✖ $dest differs from $src"; rc=1; fi
done
if [ "${1:-}" = "--write" ]; then echo "brand mirrors rewritten from vendor/brand"; elif [ $rc -eq 0 ]; then echo "✔ brand mirrors match vendor/brand"; fi
exit $rc
