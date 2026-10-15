#!/usr/bin/env bash
# Fast repo checks, run on every PR (.github/workflows/pr-checks.yml) and before any push.
# Needs: bash 3.2+ (so it runs on a stock macOS too), git, shellcheck, python3, yamllint.
# Runs every category and exits non-zero if any of them failed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
rc=0

missing=()
for tool in git shellcheck python3 yamllint; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "✖ missing tools: ${missing[*]}" >&2
  echo "  macOS:         brew install shellcheck yamllint" >&2
  echo "  Debian/Ubuntu: sudo apt-get install shellcheck yamllint python3" >&2
  exit 2
fi

# Shell sources: *.sh plus extensionless maintainer scripts and payload bins with a shell shebang.
# vendor/ is generated (vendor-brand.sh) and linted upstream.
# (Arrays are filled with read loops, not mapfile: macOS ships bash 3.2, which has no mapfile.)
SH=()
while IFS= read -r f; do SH+=("$f"); done < <(
  { git ls-files '*.sh'
    git ls-files | grep -E '(^|/)DEBIAN/(preinst|postinst|prerm|postrm)$'
    git ls-files 'core/headless/payload/usr/local/bin/*' | while read -r f; do
      head -1 "$f" | grep -qE '^#!.*\b(ba)?sh\b' && echo "$f"; done
  } | grep -v '^vendor/' | sort -u)

echo "── bash -n (${#SH[@]} files)"
for f in "${SH[@]}"; do bash -n "$f" || { echo "✖ syntax: $f"; rc=1; }; done

echo "── shellcheck -S error"
LC_ALL=C.UTF-8 shellcheck -x -S error "${SH[@]}" || rc=1

echo "── no ((VAR++)) statements in shell scripts"
# ((n++)) and ((n--)) exit with status 1 while n is 0, so under `set -e` the first increment ends the
# script: the Fedora, Arch and Mint 80-validate-ci-theme.sh did exactly that and printed one check.
# Use n=$((n + 1)).
post_incr="$(git grep -nE '^[[:space:]]*\(\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\+\+|--)[[:space:]]*\)\)' -- '*.sh' ':(exclude)vendor' 2>/dev/null || true)"
if [ -n "$post_incr" ]; then
  echo "✖ a ((VAR++)) statement aborts a set -e script while VAR is 0; write VAR=\$((VAR + 1)):"; echo "$post_incr"; rc=1
fi

echo "── no retired product names in backends/, core/ and .github/"
# The product is "Companion OS". "CI OS", "CI-OS Desktop", "CI-OS Blue Teal", "Companion Ubuntu", "Companion Intelligence OS",
# "Companion Intelligence Operating System" and "Companion Intelligence <version>" (os-release VERSION=) were earlier
# spellings of it (the GRUB distributor, the text splash, the installer's source names, the MOTD banner, the Hub launcher
# entry, the terminal and KDE profiles, release notes, the os-release version string), and the
# image checks of verify-iso.sh would only catch a return after a full build. The repo name "CI-OS", the CI_OS_* variables and
# ci-os-* paths are not product names and do not match. Three places spell the old names on purpose and are not scanned:
# this file, verify-iso.sh (it asserts they are absent from a built image) and iso/tests (a test plants one to see that it
# is caught). docs/ keeps the history and stick/ is a separate change.
old_names="$(git grep -nE 'CI OS|CI-OS Desktop|CI-OS Blue Teal|Companion Ubuntu|Intelligence Operating System|Companion Intelligence OS|Companion Intelligence [0-9$]' -- backends core .github ':(exclude)core/lib/check-repo.sh' ':(exclude)backends/ubuntu/iso/scripts/verify-iso.sh' ':(exclude)backends/ubuntu/iso/tests' 2>/dev/null || true)"
if [ -n "$old_names" ]; then
  echo "✖ a retired product name is back; the name is \"Companion OS\":"; echo "$old_names"; rc=1
fi

echo "── no block-letter banner art in backends/, core/ and .github/"
# A grep for the retired names reads text, not pictures: the MOTD banner drew the letters C, I, O, S in full-block
# characters, which spelled "CI OS" and passed every check above. Draw no names; write them.
block_art="$(git grep -InF '█' -- backends core .github ':(exclude)core/lib/check-repo.sh' 2>/dev/null || true)"
if [ -n "$block_art" ]; then
  echo "✖ block-letter art (U+2588) is back; it can spell a retired name that no text check can see:"; echo "$block_art"; rc=1
fi

echo "── python3 py_compile"
PY=()
while IFS= read -r f; do PY+=("$f"); done < <(git ls-files '*.py')
if [ ${#PY[@]} -gt 0 ]; then
  PYTHONPYCACHEPREFIX="$(mktemp -d)" python3 -m py_compile "${PY[@]}" || rc=1
fi

echo "── yamllint (relaxed)"
YML=()
while IFS= read -r f; do YML+=("$f"); done < <(git ls-files '*.yml' '*.yaml')
yamllint -d relaxed --no-warnings "${YML[@]}" || rc=1

echo "── shebang files are executable"
# A file that starts with #! but is stored as mode 100644 fails with "Permission denied" when
# run as ./script. Fix with `chmod +x` (git records it), or drop the shebang if it is only
# ever sourced. vendor/ is generated.
noexec=""
while IFS=$' \t' read -r mode _ _ f; do
  [ "$mode" = 100644 ] || continue
  case "$f" in vendor/*) continue ;; esac
  if [ -f "$f" ] && head -c 2 "$f" | grep -q '^#!'; then noexec="$noexec$f"$'\n'; fi
done < <(git ls-files -s)
if [ -n "$noexec" ]; then
  echo "✖ these files start with #! but are not executable (chmod +x):"; printf '%s' "$noexec"; rc=1
fi

echo "── no committed build artifacts"
# .gitignore already excludes these; this catches force-adds and old branches that predate it.
if art="$(git ls-files | grep -E '\.(deb|rpm|iso|squashfs|dsc|changes|buildinfo)$')"; then
  echo "✖ build artifacts are tracked — build them in CI, don't commit them:"; echo "$art"; rc=1
fi

echo "── ISO md5sum.txt tests (backends/ubuntu/iso/tests/md5sum-txt.sh)"
# The one ISO test that needs no container: it checks how the image's md5sum.txt is written and verified on a synthetic tree
# (awk, find, a hash tool; bash 3.2 is enough). With xorriso and GNU dd on the machine it also remasters a mini ISO and runs
# build-iso.sh's generate_iso on it, so a change that breaks the md5sum.txt wiring fails here and not after a one-hour build.
# The other ISO tests need a container or Plymouth; they are manual, see the "Tests" section of backends/ubuntu/iso/README.md.
md5_out="$(mktemp)"; md5_rc=0
bash backends/ubuntu/iso/tests/md5sum-txt.sh > "$md5_out" 2>&1 || md5_rc=$?
if [ "$md5_rc" -eq 0 ]; then
  grep -E '^(info|== Summary)' "$md5_out" || true
elif [ "$md5_rc" -eq 2 ]; then
  echo "! cannot run here: $(head -n 1 "$md5_out")"
else
  grep -E '^(FAIL|info|== Summary)' "$md5_out" || tail -n 10 "$md5_out"; rc=1
fi
rm -f "$md5_out"

[ $rc -eq 0 ] && echo "✔ all checks passed"
exit $rc
