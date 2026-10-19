#!/usr/bin/env bash
# Report untracked files that tracked files name: a commit made from this working tree would be broken.
#
# check-repo.sh, shellcheck and the unit tests run on the WORKING TREE, so a new helper script, a fixture or a payload file that was never
# `git add`ed is there for every local run and absent from the commit: the build (`source lib/new.sh`, `install payload/.../new`),
# `cargo test` (`include_str!("fixtures/new.txt")`) and the unit tests then fail on a clean checkout, after a green local check-repo. CI checks
# out the commit, where nothing is untracked and this script has nothing to say; it exists for the run before the push.
#
# For every untracked, not ignored file it asks `git grep` (one run) whether a tracked file contains the file's repo-relative path or, when
# the name is distinctive (8 or more characters with a `-` or `_` in them: `shell-theme.sh`, not `metadata.json` or `README`), its base
# name, which is how a script names the helper it sources from its own directory. A file nothing names (a scratch note, an evidence
# directory) is none of its business. Documentation (*.md, docs/) that names a file does not count: a dangling mention in prose breaks no
# build and no test, and a local evidence directory that is deliberately never committed may well be cited there.
#
# Usage: core/lib/check-untracked-deps.sh [repo dir]   (default: the repository this script is in)
# Exit status: 0 nothing found, 1 at least one untracked file is named by a tracked file (listed), 2 not a git work tree or git is missing.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
command -v git >/dev/null 2>&1 || { echo "check-untracked-deps: git is not installed" >&2; exit 2; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "check-untracked-deps: $ROOT is not a git work tree" >&2; exit 2; }
cd "$ROOT" || exit 2

untracked="$(git -c core.quotepath=false ls-files --others --exclude-standard)"
[ -n "$untracked" ] || exit 0

tmp="$(mktemp -d "${TMPDIR:-/tmp}/untracked-deps.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/patterns"
while IFS= read -r u; do
  [ -n "$u" ] || continue
  printf '%s\n' "$u" >> "$tmp/patterns"
  b="${u##*/}"
  case "$b" in *[-_]*) [ "${#b}" -ge 8 ] && printf '%s\n' "$b" >> "$tmp/patterns" ;; esac
done <<EOF
$untracked
EOF
sort -u "$tmp/patterns" -o "$tmp/patterns"

# "tracked file<TAB>matched text", one per occurrence (-o), tracked files only (git grep never reads untracked ones by default)
git grep -I -o -F -w -f "$tmp/patterns" --no-color -z -- . 2>/dev/null | tr '\0' '\t' | awk -F'\t' 'NF >= 2 { print $1 "\t" $2 }' | sort -u > "$tmp/hits" || true
[ -s "$tmp/hits" ] || exit 0

found=0
while IFS= read -r u; do
  [ -n "$u" ] || continue
  b="${u##*/}"
  # a tracked file that contains the path, or the base name, of this file; an untracked file does not count itself
  refs="$(awk -F'\t' -v p="$u" -v b="$b" '($2 == p || $2 == b) && $1 !~ /\.md$/ && $1 !~ /^docs\// { print $1 }' "$tmp/hits" | sort -u | head -n 3 | tr '\n' ' ')"
  if [ -n "$refs" ]; then
    if [ "$found" -eq 0 ]; then
      echo "✖ untracked files that tracked files name (a commit without them is broken; git add them, or stop naming them):"
    fi
    found=1
    echo "  $u   <- ${refs% }"
  fi
done <<EOF
$untracked
EOF
[ "$found" -eq 0 ]
