#!/usr/bin/env bash
# Fast repo checks, run on every PR (.github/workflows/pr-checks.yml) and before any push.
# Needs: bash, shellcheck, python3, yamllint. Exits non-zero on the first failing category.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
rc=0

# Shell sources: *.sh plus extensionless maintainer scripts and payload bins with a shell shebang.
# vendor/ is generated (vendor-brand.sh) and linted upstream.
mapfile -t SH < <(
  { git ls-files '*.sh'
    git ls-files | grep -E '(^|/)DEBIAN/(preinst|postinst|prerm|postrm)$'
    git ls-files 'core/headless/payload/usr/local/bin/*' | while read -r f; do
      head -1 "$f" | grep -qE '^#!.*\b(ba)?sh\b' && echo "$f"; done
  } | grep -v '^vendor/' | sort -u)

echo "── bash -n (${#SH[@]} files)"
for f in "${SH[@]}"; do bash -n "$f" || { echo "✖ syntax: $f"; rc=1; }; done

echo "── shellcheck -S error"
LC_ALL=C.UTF-8 shellcheck -x -S error "${SH[@]}" || rc=1

echo "── python3 py_compile"
mapfile -t PY < <(git ls-files '*.py')
if [ ${#PY[@]} -gt 0 ]; then
  PYTHONPYCACHEPREFIX="$(mktemp -d)" python3 -m py_compile "${PY[@]}" || rc=1
fi

echo "── yamllint (relaxed)"
mapfile -t YML < <(git ls-files '*.yml' '*.yaml')
yamllint -d relaxed --no-warnings "${YML[@]}" || rc=1

echo "── no committed build artifacts"
# .gitignore already excludes these; this catches force-adds and old branches that predate it.
if art="$(git ls-files | grep -E '\.(deb|rpm|iso|squashfs|dsc|changes|buildinfo)$')"; then
  echo "✖ build artifacts are tracked — build them in CI, don't commit them:"; echo "$art"; rc=1
fi

[ $rc -eq 0 ] && echo "✔ all checks passed"
exit $rc
