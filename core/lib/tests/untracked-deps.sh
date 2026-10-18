#!/usr/bin/env bash
# Test: core/lib/check-untracked-deps.sh finds the untracked file a tracked file needs, and only that.
#
# The defect it guards (found in review, 2026-10-18): a port added customize-chroot.sh lines that `source` and `install` new files, new tests
# and fixtures, and `include_str!` of a new list, none of them `git add`ed. check-repo.sh and the unit tests passed on the working tree
# while a commit of the tracked files was broken: the image build, test_auto_install.py and `cargo test` all failed on a clean checkout.
#
# Each case builds a throw-away git repository and runs the real script on it:
#   T1  nothing untracked                                  -> 0
#   T2  a tracked script sources an untracked helper by base name -> 1, both names printed
#   T3  the same after `git add`, and after `git add -N`   -> 0 (a commit made with `git add -u` or `commit -a` has the file)
#   T4  a tracked file names the untracked file's full path -> 1; only prose (README.md, docs/) names it -> 0
#   T5  an untracked scratch note that nothing names         -> 0
#   T6  a generic base name (metadata.json, README) that a tracked file mentions for another reason -> 0, but its full path is still caught
#   T7  an ignored file that a tracked file names           -> 0 (it is not going to be committed on purpose)
#   T8  not a git work tree                                  -> 2
#   T9  mutation: a copy of the script that never looks at base names, and one that never looks at full paths, each miss a case
#
# Needs bash 3.2+, git, awk, sort, tr (a stock macOS is enough). Exit status: non-zero if any check fails.
#
# © Companion Intelligence — Lifescope Inc
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../check-untracked-deps.sh"
[ -f "$TOOL" ] || { echo "run it from the repo checkout (no $TOOL)" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is not installed" >&2; exit 2; }

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/untracked-deps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# new_repo <name>: a repository with one tracked script that sources a helper from its own directory (by base name only: the helper's
# repo-relative path, deep/dir/shell-theme.sh, is not in the text) and one tracked README
new_repo() {
  local r="$WORK/$1"
  rm -rf "$r"; mkdir -p "$r/deep/dir" "$r/tests/fixtures"
  git -C "$r" init -q . 2>/dev/null
  git -C "$r" config user.email t@example.invalid; git -C "$r" config user.name t
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/shell-theme.sh"\n' > "$r/deep/dir/build.sh"
  printf 'See the docs.\n' > "$r/README.md"
  git -C "$r" add . >/dev/null 2>&1; git -C "$r" commit -q -m init >/dev/null 2>&1
  printf '%s' "$r"
}
# run_tool <script> <repo>: sets OUT and RC
run_tool() { OUT="$(bash "$1" "$2" 2>&1)"; RC=$?; }

echo "== T1: nothing untracked"
R="$(new_repo t1)"
run_tool "$TOOL" "$R"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then t_pass "T1 a clean tree passes silently"; else t_fail "T1 rc=$RC out=$OUT"; fi

echo "== T2/T3: a tracked script sources an untracked helper"
R="$(new_repo t2)"
printf 'echo helper\n' > "$R/deep/dir/shell-theme.sh"
run_tool "$TOOL" "$R"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'deep/dir/shell-theme.sh.*deep/dir/build.sh'; then t_pass "T2 a script sources shell-theme.sh from its own directory and the helper is untracked: found, both named"
else t_fail "T2 rc=$RC out=$OUT"; fi
git -C "$R" add -N deep/dir/shell-theme.sh
run_tool "$TOOL" "$R"
if [ "$RC" -eq 0 ]; then t_pass "T3 after git add -N the file counts as tracked (git add -u / commit -a will take it)"; else t_fail "T3 add -N: rc=$RC out=$OUT"; fi
git -C "$R" reset -q deep/dir/shell-theme.sh 2>/dev/null
run_tool "$TOOL" "$R"
[ "$RC" -eq 1 ] || t_fail "T3 control: after reset the file is untracked again and must be found (rc=$RC)"
git -C "$R" add deep/dir/shell-theme.sh
run_tool "$TOOL" "$R"
if [ "$RC" -eq 0 ]; then t_pass "T3 after git add the file counts as tracked"; else t_fail "T3 add: rc=$RC out=$OUT"; fi
# the commit made with `git commit -a` has it (the intent-to-add case is the one `commit -a` and `add -u` must cover)
R3="$(new_repo t3)"
printf 'echo helper\n' > "$R3/deep/dir/shell-theme.sh"; git -C "$R3" add -N deep/dir/shell-theme.sh
git -C "$R3" add -u >/dev/null 2>&1; git -C "$R3" commit -q -m "u" >/dev/null 2>&1
if git -C "$R3" cat-file -e HEAD:deep/dir/shell-theme.sh 2>/dev/null; then t_pass "T3 git add -u after git add -N puts the file in the commit"; else t_fail "T3 the intent-to-add file is not in the commit made with add -u"; fi

echo "== T4: a tracked file names the full path"
R="$(new_repo t4)"
printf 'FIXTURE=tests/fixtures/zenity.txt\n' > "$R/deep/dir/settings.env"; git -C "$R" add . >/dev/null 2>&1; git -C "$R" commit -q -m cfg >/dev/null 2>&1
printf 'x\n' > "$R/tests/fixtures/zenity.txt"
run_tool "$TOOL" "$R"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'tests/fixtures/zenity.txt.*settings.env'; then t_pass "T4 a name by full path is found (a base name this short is not needed)"
else t_fail "T4 rc=$RC out=$OUT"; fi
R="$(new_repo t4b)"
mkdir -p "$R/docs"; printf 'The evidence is in tests/fixtures/zenity.txt and notes-evidence.md\n' > "$R/docs/notes.md"; printf 'See tests/fixtures/zenity.txt\n' >> "$R/README.md"
git -C "$R" add . >/dev/null 2>&1; git -C "$R" commit -q -m docs >/dev/null 2>&1
printf 'x\n' > "$R/tests/fixtures/zenity.txt"; printf 'x\n' > "$R/notes-evidence.md"
run_tool "$TOOL" "$R"
if [ "$RC" -eq 0 ]; then t_pass "T4 prose (README.md, docs/) that names an untracked file is not a dependency and is not reported"; else t_fail "T4 prose only: rc=$RC out=$OUT"; fi

echo "== T5/T6/T7: what is not reported"
R="$(new_repo t5)"
printf 'scratch\n' > "$R/notes-scratch.md"
run_tool "$TOOL" "$R"
if [ "$RC" -eq 0 ]; then t_pass "T5 an untracked scratch note that nothing names is not reported"; else t_fail "T5 rc=$RC out=$OUT"; fi
R="$(new_repo t6)"
mkdir -p "$R/tests/fixtures/ext"; printf '{}\n' > "$R/tests/fixtures/ext/metadata.json"; printf 'x\n' > "$R/tests/fixtures/README"
printf 'echo every extension has a metadata.json and a README\n' >> "$R/deep/dir/build.sh"; git -C "$R" commit -q -am doc >/dev/null 2>&1
run_tool "$TOOL" "$R"
if [ "$RC" -eq 0 ]; then t_pass "T6 a generic base name (metadata.json, README) mentioned elsewhere is not enough"; else t_fail "T6 rc=$RC out=$OUT"; fi
printf 'echo the fixture is tests/fixtures/ext/metadata.json\n' >> "$R/deep/dir/build.sh"; git -C "$R" commit -q -am doc2 >/dev/null 2>&1
run_tool "$TOOL" "$R"
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'tests/fixtures/ext/metadata.json'; then t_pass "T6 ...but the same file named by its full path is found"; else t_fail "T6 full path: rc=$RC out=$OUT"; fi
R="$(new_repo t7)"
printf 'out/\n' > "$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -q -m ignore >/dev/null 2>&1
mkdir -p "$R/out"; printf 'x\n' > "$R/out/build-result.log"
printf 'echo the result is out/build-result.log\n' >> "$R/deep/dir/build.sh"; git -C "$R" commit -q -am doc >/dev/null 2>&1
run_tool "$TOOL" "$R"
if [ "$RC" -eq 0 ]; then t_pass "T7 an ignored file that a tracked file names is not reported"; else t_fail "T7 rc=$RC out=$OUT"; fi

echo "== T8: not a git work tree"
mkdir -p "$WORK/plain"
run_tool "$TOOL" "$WORK/plain"
if [ "$RC" -eq 2 ]; then t_pass "T8 a directory that is not a git work tree exits 2"; else t_fail "T8 rc=$RC out=$OUT"; fi

echo "== T9: mutation proof"
# without the base-name patterns T2 is missed; without the full-path patterns T4 is missed (each case is caught by the other pattern only
# when the names agree, which is why both are tested)
sed 's/^  case "\$b" in .*$/  :/' "$TOOL" > "$WORK/mut-base.sh"
sed 's/^  printf .%s\\n. "\$u" >> "\$tmp\/patterns"$/  :/' "$TOOL" > "$WORK/mut-path.sh"
if cmp -s "$WORK/mut-base.sh" "$TOOL" || cmp -s "$WORK/mut-path.sh" "$TOOL"; then t_fail "T9 a mutation changed nothing (the script was reshaped; adjust the sed)"
else
  R="$(new_repo t9a)"; printf 'echo helper\n' > "$R/deep/dir/shell-theme.sh"
  run_tool "$WORK/mut-base.sh" "$R"
  # (the mutant sits in $WORK, so give it the repo as an argument; its default root would be wrong)
  if [ "$RC" -eq 0 ]; then t_pass "T9 without the base-name patterns the sourced helper is missed (the real script finds it)"; else t_fail "T9 base-name mutant still found it (rc=$RC): the base-name rule is not what finds T2"; fi
  R="$(new_repo t9b)"; printf 'FIXTURE=tests/fixtures/zenity.txt\n' > "$R/deep/dir/settings.env"; git -C "$R" add . >/dev/null 2>&1; git -C "$R" commit -q -m cfg >/dev/null 2>&1; printf 'x\n' > "$R/tests/fixtures/zenity.txt"
  run_tool "$WORK/mut-path.sh" "$R"
  if [ "$RC" -eq 0 ]; then t_pass "T9 without the full-path patterns a fixture named by its path is missed (the real script finds it)"; else t_fail "T9 path mutant still found it (rc=$RC)"; fi
fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
