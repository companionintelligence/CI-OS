#!/usr/bin/env bash
#=============================================================================
# Test: the Hugging Face cache view (core/lib/ci-os-models.sh: ci_models_view_build, the lock reader, `view`)
#
# The view is a directory of symlinks in the layout huggingface_hub and llama.cpp read
# (hub/models--ORG--NAME/{refs/main,snapshots/<commit>/<file>}), each pointing at the one copy of the file in
# the Ollama-format store on the exFAT volume. What it proves, on a temp directory:
#   * the layout and the link targets; a second run changes nothing (the counters AND the inodes say so);
#   * odd file names (spaces, quotes, "$(...)", backticks, leading dashes, globs, brackets, unicode, sub-directories)
#     become exactly one link each, are never evaluated or word-split, and run no command;
#   * unsafe input is refused and creates nothing: newline, tab, backslash and other control characters, "..",
#     absolute paths, empty components, a repository or digest that is not what it says;
#   * it never writes through a symlink planted in its way, never replaces a real file or a link to somewhere
#     else, never links a blob that is itself a link, and prunes only links that point into the store;
#   * the lock reader finds the Hugging Face files in pretty or compact JSON, whatever the nesting, drops unsafe
#     entries, and is fast on a lock with hundreds of KB of inline base64;
#   * parallel builders end in a consistent tree.
# models-mutation.sh runs this file against broken copies of the code to prove it fails when the code is wrong.
#
#   bash backends/ubuntu/chroot/tests/models-view.sh        (bash 3.2 or 5; awk: BSD, mawk or gawk)
#
# Exit status: non-zero if any check fails; 2 if it cannot run here.
#
# (c) Companion Intelligence - Lifescope Inc
#=============================================================================
# shellcheck disable=SC1090,SC2034  # the library is sourced by a variable path; some variables are read only inside subshells
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models-testlib.sh
. "$HERE/lib/models-testlib.sh"
default_stubs

CASE=0
newcase() { # newcase: fresh T with store, view and spec; sets T STORE XDIR VIEW SPEC ROOT
  CASE=$((CASE + 1))
  T="$WORK/case$CASE"; ROOT="$T/cache"; STORE="$ROOT/models"; XDIR="$ROOT/ci-models"; VIEW="$T/view"; SPEC="$T/spec.tsv"
  mkdir -p "$T/cwd" "$T/outside"; cache_make "$ROOT"; : > "$SPEC"
}
spec() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$SPEC"; }
# build [prune]: run the builder in a fresh shell with the library sourced; prints its summary line
build() { (cd "$T/cwd" && . "$MODELS_SH" && ci_models_view_build "$STORE" "$XDIR" "$VIEW" "$SPEC" "${1:-1}" 2>"$T/err.log"); }
num() { # num "<summary>" <word>: the number in front of <word> ("1 linked", "(1 created", "0 refused")
  printf '%s' "$1" | sed -n "s/.*[( ]\\([0-9][0-9]*\\) $2.*/\\1/p" | head -1
}
snap() { printf '%s/hub/models--%s--%s/snapshots/%s' "$VIEW" "$1" "$2" "$3"; }
tree_of() { (cd "$1" && find . | LC_ALL=C sort); }
inode_of() { ls -di "$1" 2>/dev/null | awk '{print $1}'; }

echo "== layout"
newcase
blob_make "$ROOT" "$HEX64_A" "model-bytes-A"
spec unsloth/gemma-3-270m-it-GGUF "$REV_A" gemma-3-270m-it-Q4_K_M.gguf "$HEX64_A"
out="$(build)"
t_eq "one entry: one link created" "1" "$(num "$out" created)"
S="$(snap unsloth gemma-3-270m-it-GGUF "$REV_A")"
expect "the link exists and is a symlink" test -L "$S/gemma-3-270m-it-Q4_K_M.gguf"
t_eq "it points at the blob in the store, by absolute path" "$STORE/blobs/sha256-$HEX64_A" "$(readlink "$S/gemma-3-270m-it-Q4_K_M.gguf")"
t_eq "reading through the link gives the blob" "model-bytes-A" "$(cat "$S/gemma-3-270m-it-Q4_K_M.gguf")"
t_eq "refs/main holds the commit" "$REV_A" "$(cat "$VIEW/hub/models--unsloth--gemma-3-270m-it-GGUF/refs/main")"
expect "refs/main is a regular file (llama.cpp ignores anything else)" test -f "$VIEW/hub/models--unsloth--gemma-3-270m-it-GGUF/refs/main" -a ! -L "$VIEW/hub/models--unsloth--gemma-3-270m-it-GGUF/refs/main"
t_eq "nothing else is in the view" ".
./hub
./hub/models--unsloth--gemma-3-270m-it-GGUF
./hub/models--unsloth--gemma-3-270m-it-GGUF/refs
./hub/models--unsloth--gemma-3-270m-it-GGUF/refs/main
./hub/models--unsloth--gemma-3-270m-it-GGUF/snapshots
./hub/models--unsloth--gemma-3-270m-it-GGUF/snapshots/$REV_A
./hub/models--unsloth--gemma-3-270m-it-GGUF/snapshots/$REV_A/gemma-3-270m-it-Q4_K_M.gguf" "$(tree_of "$VIEW")"
expect "the view directories are readable by everyone" test "$(ls -ld "$VIEW/hub" | cut -c1-10)" = "drwxr-xr-x"

echo "== idempotence"
ino_link="$(inode_of "$S/gemma-3-270m-it-Q4_K_M.gguf")"; ino_ref="$(inode_of "$VIEW/hub/models--unsloth--gemma-3-270m-it-GGUF/refs/main")"
before="$(tree_of "$VIEW")"
out="$(build)"
t_eq "second run: 0 created" "0" "$(num "$out" created)"
t_eq "second run: 0 replaced" "0" "$(num "$out" replaced)"
t_eq "second run: 1 unchanged" "1" "$(num "$out" unchanged)"
t_eq "second run: the same tree" "$before" "$(tree_of "$VIEW")"
t_eq "second run: the link is the same inode (not rewritten)" "$ino_link" "$(inode_of "$S/gemma-3-270m-it-Q4_K_M.gguf")"
t_eq "second run: refs/main is the same inode (not rewritten)" "$ino_ref" "$(inode_of "$VIEW/hub/models--unsloth--gemma-3-270m-it-GGUF/refs/main")"
out="$(build)"; out2="$(build)"
t_eq "a third and fourth run say the same" "$out" "$out2"

echo "== odd file names: one link each, nothing evaluated"
newcase
blob_make "$ROOT" "$HEX64_A" "odd-bytes"
names_file="$T/names"
cat > "$names_file" <<'NEOF'
with space.gguf
it's.gguf
say "hi".gguf
-leading-dash.gguf
--double-dash.gguf
$(touch PWNED).gguf
`touch PWNED2`.gguf
${IFS}x.gguf
star*.gguf
qmark?.gguf
semi;amp&pipe|.gguf
sub dir/-nested $x.gguf
a/b/c/deep.gguf
[bracket].gguf
 leadingspace.gguf
trailingspace .gguf
{brace,expansion}.gguf
~tilde.gguf
!bang.gguf
#hash.gguf
%percent.gguf
é-ünicode.gguf
very-long-name-0123456789-0123456789-0123456789-0123456789-0123456789-0123456789-0123456789-0123456789-0123456789.gguf
NEOF
count=0
while IFS= read -r nm; do
  spec org/odd "$REV_A" "$nm" "$HEX64_A"; count=$((count + 1))
done < "$names_file"
out="$(build)"
t_eq "$count odd names: $count links created, none refused" "$count:0" "$(num "$out" created):$(num "$out" refused)"
S="$(snap org odd "$REV_A")"
bad=0
while IFS= read -r nm; do
  [ -L "$S/$nm" ] && [ "$(readlink "$S/$nm")" = "$STORE/blobs/sha256-$HEX64_A" ] && [ "$(cat "$S/$nm")" = "odd-bytes" ] || { bad=$((bad + 1)); t_info "not linked right: [$nm]"; }
done < "$names_file"
t_eq "every odd name is a link to the blob and reads back" 0 "$bad"
t_eq "no command in a name ran (PWNED, PWNED2 absent in the working directory and the view)" "" \
  "$(find "$T" -name 'PWNED*' -type f | head -1)"
t_eq "the number of links in the view is the number of names" "$count" "$(find "$VIEW" -type l | wc -l | tr -d ' ')"
out="$(build)"
t_eq "odd names: the second run changes nothing" "0:0:$count" "$(num "$out" created):$(num "$out" replaced):$(num "$out" unchanged)"

echo "== unsafe names are refused and create nothing"
refuse_one() { # refuse_one "<label>" <repo> <rev> <file> <sha> [expected refused >= n]
  newcase; blob_make "$ROOT" "$HEX64_A" x; blob_make "$ROOT" "$HEX64_B" y
  spec org/good "$REV_A" ok.gguf "$HEX64_B"
  spec "$2" "$3" "$4" "$5"
  local o; o="$(build)"
  if [ "$(num "$o" refused)" -ge "${6:-1}" ] && [ "$(num "$o" linked)" = 1 ] && [ "$(find "$VIEW" -type l | wc -l | tr -d ' ')" = 1 ]; then
    t_pass "refused: $1"
  else
    t_fail "not refused (or the good entry was lost): $1 -> $o"
  fi
  # nothing may appear outside the view: the case directory holds only what newcase made, plus view/ and the logs
  if [ -n "$(find "$T" -mindepth 1 -maxdepth 1 ! -name cache ! -name cwd ! -name outside ! -name view ! -name spec.tsv ! -name err.log | head -1)" ]; then
    t_fail "something was created outside the view: $1"
  fi
  if [ -n "$(find "$T/outside" "$T/cwd" -mindepth 1 2>/dev/null | head -1)" ]; then t_fail "something was written to the neighbouring directories: $1"; fi
}
refuse_one "dot-dot first"           org/bad "$REV_A" "../escape.gguf" "$HEX64_A"
refuse_one "dot-dot in the middle"   org/bad "$REV_A" "a/../../escape.gguf" "$HEX64_A"
refuse_one "dot-dot last"            org/bad "$REV_A" "a/.." "$HEX64_A"
refuse_one "a single dot"            org/bad "$REV_A" "." "$HEX64_A"
refuse_one "a dot component"         org/bad "$REV_A" "a/./b.gguf" "$HEX64_A"
refuse_one "absolute path"           org/bad "$REV_A" "/etc/escape.gguf" "$HEX64_A"
refuse_one "empty component"         org/bad "$REV_A" "a//b.gguf" "$HEX64_A"
refuse_one "trailing slash"          org/bad "$REV_A" "dir/" "$HEX64_A"
refuse_one "backslash"               org/bad "$REV_A" 'a\b.gguf' "$HEX64_A"
refuse_one "tab in the name"         org/bad "$REV_A" "$(printf 'tab\there.gguf')" "$HEX64_A"
refuse_one "newline in the name (splits the record: both halves refused)" org/bad "$REV_A" "$(printf 'new\nline.gguf')" "$HEX64_A" 1
refuse_one "carriage return"         org/bad "$REV_A" "$(printf 'cr\rname.gguf')" "$HEX64_A"
refuse_one "escape character"        org/bad "$REV_A" "$(printf 'esc\033name.gguf')" "$HEX64_A"
refuse_one "DEL"                     org/bad "$REV_A" "$(printf 'del\177name.gguf')" "$HEX64_A"
refuse_one "empty file name"         org/bad "$REV_A" "" "$HEX64_A"
refuse_one "repository with a dot-dot" "../x/y" "$REV_A" ok.gguf "$HEX64_A"
refuse_one "repository with three parts" a/b/c "$REV_A" ok.gguf "$HEX64_A"
refuse_one "repository without an owner" abc "$REV_A" ok.gguf "$HEX64_A"
refuse_one "repository with a double dash (the folder name could not be read back)" a--b/c "$REV_A" ok.gguf "$HEX64_A"
refuse_one "repository name with a double dash" a/b--c "$REV_A" ok.gguf "$HEX64_A"
refuse_one "repository starting with a dash" -a/b "$REV_A" ok.gguf "$HEX64_A"
refuse_one "repository with a space" "a b/c" "$REV_A" ok.gguf "$HEX64_A"
refuse_one "revision too short"      org/bad "${REV_A%??}" ok.gguf "$HEX64_A"
refuse_one "revision in capitals"    org/bad "$(printf '%s' "$REV_A" | tr 'a-f' 'A-F')" ok.gguf "$HEX64_A"
refuse_one "revision that is a branch name" org/bad main ok.gguf "$HEX64_A"
refuse_one "revision with a path in it" org/bad "../../../etc/passwd" ok.gguf "$HEX64_A"
refuse_one "digest too short"        org/bad "$REV_A" ok.gguf "${HEX64_A%??}"
refuse_one "digest in capitals"      org/bad "$REV_A" ok.gguf "$(printf '%s' "$HEX64_A" | tr 'a-f' 'A-F')"
refuse_one "digest with a prefix"    org/bad "$REV_A" ok.gguf "sha256:$HEX64_A"
refuse_one "digest with a path in it" org/bad "$REV_A" ok.gguf "../../etc/passwd"
refuse_one "name longer than 1024 bytes" org/bad "$REV_A" "$(awk 'BEGIN { s = ""; for (i = 0; i < 1100; i++) s = s "x"; print s }')" "$HEX64_A"

echo "== the name validator on its own (no files: the file system's own limits cannot hide a missing rule)"
v() { (. "$MODELS_SH"; ci_models_valid_relpath "$1") && echo ok || echo no; }
long() { awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) printf "x" }'; }
t_eq "a name of 1024 bytes is accepted" ok "$(v "$(long 1024)")"
t_eq "a name of 1025 bytes is refused" no "$(v "$(long 1025)")"
t_eq "a plain name is accepted" ok "$(v 'dir/file.gguf')"
t_eq "a name with spaces, quotes and a leading dash is accepted" ok "$(v "-a b/it's \"q\".gguf")"
for bad in "" "/abs.gguf" "a//b" "a/../b" "./a" "a/." "a/" 'a\b'; do
  t_eq "the validator refuses '$bad'" no "$(v "$bad")"
done
t_eq "the validator refuses a tab" no "$(v "$(printf 'a\tb')")"
t_eq "the validator refuses a newline" no "$(v "$(printf 'a\nb')")"
t_eq "the validator refuses DEL" no "$(v "$(printf 'a\177b')")"

echo "== it never touches what it did not make"
newcase
blob_make "$ROOT" "$HEX64_A" "A"; blob_make "$ROOT" "$HEX64_B" "B"; blob_make "$ROOT" "$HEX64_C" "C"
spec org/m "$REV_A" model.gguf "$HEX64_A"
S="$(snap org m "$REV_A")"
mkdir -p "$S"; printf 'precious' > "$S/model.gguf"
out="$(build)"
t_eq "a real file where the link goes: refused" "1" "$(num "$out" refused)"
t_eq "the real file is untouched" "precious" "$(cat "$S/model.gguf")"
expect_not "and is still not a link" test -L "$S/model.gguf"

newcase
blob_make "$ROOT" "$HEX64_A" "A"
echo "somewhere else" > "$T/outside/target"
spec org/m "$REV_A" model.gguf "$HEX64_A"
S="$(snap org m "$REV_A")"; mkdir -p "$S"; ln -s "$T/outside/target" "$S/model.gguf"
out="$(build)"
t_eq "a link to somewhere else: refused" "1" "$(num "$out" refused)"
t_eq "it still points there" "$T/outside/target" "$(readlink "$S/model.gguf")"
t_eq "and that file is unchanged" "somewhere else" "$(cat "$T/outside/target")"

newcase
blob_make "$ROOT" "$HEX64_A" "A"
spec org/m "$REV_A" model.gguf "$HEX64_A"
S="$(snap org m "$REV_A")"; mkdir -p "$S"; ln -s "$T/outside" "$S/model.gguf"
out="$(build)"
t_eq "the link position holds a symlink to a DIRECTORY elsewhere: refused" "1" "$(num "$out" refused)"
t_eq "ln was not allowed to drop a new link inside that directory" "" "$(find "$T/outside" -mindepth 1 | head -1)"
t_eq "and the symlink to the directory is untouched" "$T/outside" "$(readlink "$S/model.gguf")"

newcase
blob_make "$ROOT" "$HEX64_A" "A"
spec org/m "$REV_A" model.gguf "$HEX64_A"
S="$(snap org m "$REV_A")"; mkdir -p "$S/model.gguf"
out="$(build)"
t_eq "a real directory where the link goes: refused" "1" "$(num "$out" refused)"
t_eq "and nothing was put inside it" "" "$(find "$S/model.gguf" -mindepth 1 | head -1)"

newcase
blob_make "$ROOT" "$HEX64_A" "A"
spec org/m "$REV_A" model.gguf "$HEX64_A"
mkdir -p "$VIEW/hub/models--org--m"; ln -s "$T/outside" "$VIEW/hub/models--org--m/snapshots"
out="$(build)"
t_eq "snapshots/ is a symlink planted to another directory: refused" "1" "$(num "$out" refused)"
t_eq "nothing was written through it" "" "$(find "$T/outside" -mindepth 1 | head -1)"

newcase
blob_make "$ROOT" "$HEX64_A" "A"
spec org/m "$REV_A" model.gguf "$HEX64_A"
mkdir -p "$VIEW/hub/models--org--m/snapshots"; ln -s "$T/outside" "$VIEW/hub/models--org--m/refs"
out="$(build)"
t_eq "refs/ is a symlink to another directory: refused" "1" "$(num "$out" refused)"
t_eq "nothing was written through it" "" "$(find "$T/outside" -mindepth 1 | head -1)"

newcase
blob_make "$ROOT" "$HEX64_A" "A"
spec org/m "$REV_A" model.gguf "$HEX64_A"
mkdir -p "$VIEW/hub/models--org--m/refs"; echo "keep me" > "$T/outside/f"; ln -s "$T/outside/f" "$VIEW/hub/models--org--m/refs/main"
out="$(build)"
t_eq "refs/main is a symlink: refused" "1" "$(num "$out" refused)"
t_eq "the file it points at is unchanged" "keep me" "$(cat "$T/outside/f")"

newcase
blob_make "$ROOT" "$HEX64_A" "A"
spec org/m "$REV_A" sub/dir/model.gguf "$HEX64_A"
S="$(snap org m "$REV_A")"; mkdir -p "$S"; ln -s "$T/outside" "$S/sub"
out="$(build)"
t_eq "a symlink in the sub-directory part of the path: refused" "1" "$(num "$out" refused)"
t_eq "nothing was written through it" "" "$(find "$T/outside" -mindepth 1 | head -1)"

newcase
echo "not a blob" > "$T/outside/real"; ln -s "$T/outside/real" "$STORE/blobs/sha256-$HEX64_A"
spec org/m "$REV_A" model.gguf "$HEX64_A"
out="$(build)"
t_eq "a blob that is itself a symlink: refused, no link" "1:0" "$(num "$out" refused):$(find "$VIEW" -type l 2>/dev/null | wc -l | tr -d ' ')"

newcase
blob_make "$ROOT" "$HEX64_A" "A"
spec org/m "$REV_A" model.gguf "$HEX64_A"
mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$VIEW"
rc=0; out="$(build)" || rc=$?
t_eq "the view root is a symlink: the build fails (status 1)" "1" "$rc"
t_eq "and wrote nothing through it" "" "$(find "$T/elsewhere" -mindepth 1 | head -1)"
rm -f "$VIEW"; mkdir -p "$VIEW"; ln -s "$T/elsewhere" "$VIEW/hub"
rc=0; out="$(build)" || rc=$?
t_eq "hub/ is a symlink: the build fails (status 1)" "1" "$rc"
t_eq "and wrote nothing through it" "" "$(find "$T/elsewhere" -mindepth 1 | head -1)"

newcase
blob_make "$ROOT" "$HEX64_A" "A"; blob_make "$ROOT" "$HEX64_B" "B"
spec org/m "$REV_A" model.gguf "$HEX64_B"
S="$(snap org m "$REV_A")"; mkdir -p "$S"; ln -s "$STORE/blobs/sha256-$HEX64_A" "$S/model.gguf"
out="$(build)"
t_eq "a link into the store that points at the wrong blob is replaced" "1:0" "$(num "$out" replaced):$(num "$out" refused)"
t_eq "and now points at the right one" "$STORE/blobs/sha256-$HEX64_B" "$(readlink "$S/model.gguf")"

echo "== blobs that are not in the cache, and the second store"
newcase
spec org/m "$REV_A" model.gguf "$HEX64_A"
out="$(build)"
t_eq "no blob: counted, nothing created" "1:0" "$(num "$out" 'blobs not in'):$(find "$VIEW" -type l | wc -l | tr -d ' ')"
t_eq "no blob: no repository directory either" "" "$(find "$VIEW/hub" -mindepth 1 | head -1)"
d="${HEX64_A%"${HEX64_A#??}"}"
mkdir -p "$XDIR/blobs/$d"; printf 'in-ci-models' > "$XDIR/blobs/$d/$HEX64_A"
out="$(build)"
t_eq "the blob appears in ci-models/blobs/<hh>/<hex>: linked" "1" "$(num "$out" created)"
t_eq "the link points into ci-models" "$XDIR/blobs/$d/$HEX64_A" "$(readlink "$(snap org m "$REV_A")/model.gguf")"

echo "== pruning: only links into the store, only what the input no longer wants"
newcase
blob_make "$ROOT" "$HEX64_A" "A"; blob_make "$ROOT" "$HEX64_B" "B"
spec org/keep "$REV_A" model.gguf "$HEX64_A"
spec org/drop "$REV_B" model.gguf "$HEX64_B"
spec org/keep "$REV_A" extra.gguf "$HEX64_B"
build >/dev/null
S="$(snap org keep "$REV_A")"
ln -s /etc/hostname "$S/foreign-link"
printf 'mine' > "$S/real-file.txt"
nlname="$(printf 'stale\nlink')"
ln -s "$STORE/blobs/sha256-$HEX64_C" "$S/$nlname"
# the new input drops org/drop and org/keep's extra.gguf
: > "$SPEC"; spec org/keep "$REV_A" model.gguf "$HEX64_A"
out="$(build)"
t_eq "pruned: the dropped model's link, the dropped file's link, and the stale link with a newline in its name" "3" "$(num "$out" pruned)"
expect_not "org/drop is gone entirely (links, refs/main, directories)" test -e "$VIEW/hub/models--org--drop"
expect "org/keep/model.gguf is still linked" test -L "$S/model.gguf"
expect_not "extra.gguf is gone" test -e "$S/extra.gguf"
expect "a foreign link (not into the store) is left alone" test -L "$S/foreign-link"
t_eq "a real file is left alone" "mine" "$(cat "$S/real-file.txt")"
expect_not "the stale link with a newline in its name is gone" test -L "$S/$nlname"
out="$(build 0)"
: > "$SPEC"
out="$(build 0)"
expect "with pruning off (5th argument 0) nothing is removed" test -L "$S/model.gguf"
out="$(build 1)"
expect_not "an empty input prunes the links it made" test -L "$S/model.gguf"
expect "but still not the real file" test -f "$S/real-file.txt"
expect "nor the foreign link" test -L "$S/foreign-link"
# with an EMPTY second store the "$xdir"/* patterns must not turn into /* (every link would count as ours)
mkdir -p "$S"; ln -sf "$STORE/blobs/sha256-$HEX64_A" "$S/model.gguf"
: > "$SPEC"
out="$(cd "$T/cwd" && . "$MODELS_SH" && ci_models_view_build "$STORE" "" "$VIEW" "$SPEC" 1 2>/dev/null)"
expect "an empty second store does not make foreign links ours: the foreign link survives the prune" test -L "$S/foreign-link"
expect_not "...while the links into the store are still pruned" test -L "$S/model.gguf"
printf 'org/keep\t%s\tforeign-link\t%s\n' "$REV_A" "$HEX64_A" > "$SPEC"
out="$(cd "$T/cwd" && . "$MODELS_SH" && ci_models_view_build "$STORE" "" "$VIEW" "$SPEC" 1 2>/dev/null)"
t_eq "...and a foreign link at a link position is refused, not replaced, with an empty second store too" "/etc/hostname" "$(readlink "$S/foreign-link")"
: > "$SPEC"

echo "== several revisions of one repository"
newcase
blob_make "$ROOT" "$HEX64_A" "A"; blob_make "$ROOT" "$HEX64_B" "B"
spec org/m "$REV_A" model.gguf "$HEX64_A"
spec org/m "$REV_B" model.gguf "$HEX64_B"
out="$(build)"
t_eq "two snapshots, both linked" "2" "$(num "$out" created)"
t_eq "refs/main follows the last entry" "$REV_B" "$(cat "$VIEW/hub/models--org--m/refs/main")"
out="$(build)"
t_eq "and that is stable on the next run" "0" "$(num "$out" created)"

echo "== the lock reader (pretty, compact, nested, hostile, big)"
newcase
cat > "$T/lock-pretty.json" <<JEOF
{
  "schema_version": 1,
  "generated_at": "2026-10-17T18:40:00Z",
  "models": [
    {"ref": "qwen3.6:27b", "source": "ollama", "layers": [{"role": "model", "digest": "sha256:415aad60", "size": 16837919680}], "size_bytes": 17769076933},
    {
      "ref": "hf.co/unsloth/gemma-3-270m-it-GGUF:Q4_K_M",
      "source": "huggingface",
      "hf": {
        "repo": "unsloth/gemma-3-270m-it-GGUF",
        "revision": "$REV_A",
        "file": "gemma-3-270m-it-Q4_K_M.gguf",
        "sha256": "$HEX64_A",
        "size": 253115424, "gated": false, "license": "gemma"
      },
      "layers": [ {"role": "template", "inline_b64": "AAAA=="} ]
    }
  ],
  "blobs_inline": {"sha256:5f3a": "x}y,{z\"q"}
}
JEOF
exp="unsloth/gemma-3-270m-it-GGUF${TAB}$REV_A${TAB}gemma-3-270m-it-Q4_K_M.gguf${TAB}$HEX64_A"
t_eq "pretty JSON: one Hugging Face file found, the Ollama model ignored" "$exp" "$(. "$MODELS_SH"; ci_models_lock_hf_spec "$T/lock-pretty.json")"
tr -d '\n' < "$T/lock-pretty.json" | sed 's/  */ /g' > "$T/lock-compact.json"
t_eq "compact JSON on one line: the same" "$exp" "$(. "$MODELS_SH"; ci_models_lock_hf_spec "$T/lock-compact.json")"
printf '{"a":{"b":[{"c":{"repo":"o/r","commit":"%s","path":"d/f.gguf","sha256":"sha256:%s"}}]}}' "$REV_A" "$HEX64_A" > "$T/lock-alt.json"
t_eq "other key names (commit, path) and a sha256: prefix, nested deeper" "o/r${TAB}$REV_A${TAB}d/f.gguf${TAB}$HEX64_A" "$(. "$MODELS_SH"; ci_models_lock_hf_spec "$T/lock-alt.json")"
printf '{"x":{"repo":"o/r","revision":"%s","file":"a\\u0041b.gguf","sha256":"%s"}}' "$REV_A" "$HEX64_A" > "$T/lock-u.json"
t_eq "a \\u0041 escape in a name decodes to A" "o/r${TAB}$REV_A${TAB}aAb.gguf${TAB}$HEX64_A" "$(. "$MODELS_SH"; ci_models_lock_hf_spec "$T/lock-u.json")"
for esc in '\u00e9' '\u0000' '\n' '\t' '\u007f' '\r'; do
  printf '{"x":{"repo":"o/r","revision":"%s","file":"a%sb.gguf","sha256":"%s"}}' "$REV_A" "$esc" "$HEX64_A" > "$T/lock-bad.json"
  t_eq "an escape that is a control character or non-ASCII ($esc) drops the entry" "" "$(. "$MODELS_SH"; ci_models_lock_hf_spec "$T/lock-bad.json" 2>/dev/null)"
done
printf '{"x":{"repo":"o/r","revision":"%s","file":"../up.gguf","sha256":"%s"}}' "$REV_A" "$HEX64_A" > "$T/lock-trav.json"
t_eq "a path with .. is dropped by the reader (and reported on stderr)" "" "$(. "$MODELS_SH"; ci_models_lock_hf_spec "$T/lock-trav.json" 2>/dev/null)"
t_has "the drop is reported" "$(. "$MODELS_SH"; ci_models_lock_hf_spec "$T/lock-trav.json" 2>&1 >/dev/null)" "refused file name"
t_eq "not JSON at all: no output, no crash" "" "$(. "$MODELS_SH"; printf 'this is } not { json "' > "$T/junk.json"; ci_models_lock_hf_spec "$T/junk.json" 2>/dev/null)"
t_eq "an empty file: no output" "" "$(. "$MODELS_SH"; : > "$T/none.json"; ci_models_lock_hf_spec "$T/none.json")"
printf '{"x":{"repo":"o/r","revision":"%s","file":"f.gguf"}}' "$REV_A" > "$T/lock-nosha.json"
t_eq "an object with three of the four keys is not an entry" "" "$(. "$MODELS_SH"; ci_models_lock_hf_spec "$T/lock-nosha.json")"
# a lock with 300 KB of inline base64 in a hundred strings
awk -v rev="$REV_A" -v sha="$HEX64_A" 'BEGIN {
  printf "{\n  \"models\": [{\"hf\": {\"repo\": \"o/r\", \"revision\": \"%s\", \"file\": \"f.gguf\", \"sha256\": \"%s\"}}],\n  \"blobs_inline\": {\n", rev, sha
  chunk = ""; for (i = 0; i < 3000; i++) chunk = chunk "A"
  for (i = 0; i < 100; i++) printf "    \"sha256:%064d\": \"%s\"%s\n", i, chunk, (i < 99 ? "," : "")
  printf "  }\n}\n" }' > "$T/lock-big.json"
size="$(wc -c < "$T/lock-big.json" | tr -d ' ')"
start="$(date +%s)"
t_eq "a ${size}-byte lock: still finds the one entry" "1" "$(. "$MODELS_SH"; ci_models_lock_hf_spec "$T/lock-big.json" | wc -l | tr -d ' ')"
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le 5 ]; then t_pass "and does it in ${elapsed}s (limit 5 s)"; else t_fail "the reader took ${elapsed}s on a ${size}-byte lock"; fi

echo "== the view command: locks, discovery, quiet, strict"
newcase
blob_make "$ROOT" "$HEX64_A" "A"
cat > "$T/lock.json" <<JEOF
{"models": [
 {"hf": {"repo": "unsloth/gemma-3-270m-it-GGUF", "revision": "$REV_A", "file": "gemma-3-270m-it-Q4_K_M.gguf", "sha256": "$HEX64_A"}},
 {"hf": {"repo": "org/odd", "revision": "$REV_A", "file": "new\\nline.gguf", "sha256": "$HEX64_A"}},
 {"hf": {"repo": "org/trav", "revision": "$REV_A", "file": "../escape.gguf", "sha256": "$HEX64_A"}}
]}
JEOF
run_view() { (cd "$T/cwd" && bash "$MODELS_SH" view --cache "$ROOT" --out "$VIEW" "$@" 2>"$T/view.err"); }
out="$(run_view --lock "$T/lock.json")"
t_has "view --lock: one linked, none refused (the hostile entries never reach the builder)" "$out" "1 linked (1 created, 0 replaced, 0 unchanged), 0 pruned, 0 blobs not in the cache, 0 refused"
t_has "the reader's complaint reached stderr" "$(cat "$T/view.err")" "refused file name"
expect "the link exists" test -L "$(snap unsloth gemma-3-270m-it-GGUF "$REV_A")/gemma-3-270m-it-Q4_K_M.gguf"
t_eq "view --quiet prints nothing when nothing changed" "" "$(run_view --quiet --lock "$T/lock.json")"
cp "$T/lock.json" "$ROOT/ci-models/locks/pack-1234abcd.json"
t_has "with no --lock and no lock in the image, the copies in ci-models/locks are used" "$(run_view)" "1 linked (0 created, 0 replaced, 1 unchanged)"
cat > "$T/image.lock" <<JEOF
{"models": [{"hf": {"repo": "org/fromimage", "revision": "$REV_A", "file": "img.gguf", "sha256": "$HEX64_A"}}]}
JEOF
out="$(CI_OS_MODEL_LOCK_SEARCH="$T/image.lock" run_view)"
t_has "a lock in the image beats the one on the volume" "$out" "1 linked (1 created, 0 replaced, 0 unchanged), 1 pruned"
expect "the image's file is linked" test -L "$(snap org fromimage "$REV_A")/img.gguf"
expect_not "the volume's lock was not used" test -e "$(snap unsloth gemma-3-270m-it-GGUF "$REV_A")/gemma-3-270m-it-Q4_K_M.gguf"
out="$(CI_OS_MODEL_LOCK_FILE="$T/lock.json" CI_OS_MODEL_LOCK_SEARCH="$T/image.lock" run_view)"
t_has "CI_OS_MODEL_LOCK_FILE beats the image's lock" "$out" "1 linked (1 created, 0 replaced, 0 unchanged), 1 pruned"
rm -f "$ROOT/ci-models/locks/pack-1234abcd.json"
t_has "no lock anywhere: says so and does nothing (status 0)" "$(run_view 2>&1; echo "rc=$?")" "rc=0"
t_has "the message names where it looked" "$(cat "$T/view.err")" "no lock file found"
printf 'org/bad\t%s\t../x\t%s\n' "$REV_A" "$HEX64_A" > "$T/bad.spec"
rc=0; run_view --strict --spec "$T/bad.spec" >/dev/null || rc=$?
t_eq "--strict: a refused entry makes the status 1" "1" "$rc"
rc=0; run_view --spec "$T/bad.spec" >/dev/null || rc=$?
t_eq "without --strict a refused entry is reported but the status is 0" "0" "$rc"
rc=0; run_view --bogus >/dev/null || rc=$?
t_eq "an unknown option is a usage error (2)" "2" "$rc"

echo "== parallel builders"
newcase
blob_make "$ROOT" "$HEX64_A" "A"; blob_make "$ROOT" "$HEX64_B" "B"
i=0
while [ "$i" -lt 12 ]; do
  spec org/m$((i % 3)) "$REV_A" "file$i.gguf" "$HEX64_A"; i=$((i + 1))
done
pids=""
for _ in 1 2 3 4; do
  (cd "$T/cwd" && bash "$MODELS_SH" view --cache "$ROOT" --out "$VIEW" --spec "$SPEC" >/dev/null 2>>"$T/par.err"; echo $? >> "$T/par.rc") &
  pids="$pids $!"
done
# shellcheck disable=SC2086
wait $pids
t_eq "four builders at once: all exit 0" "0 0 0 0" "$(sort "$T/par.rc" | tr '\n' ' ' | sed 's/ $//')"
t_eq "and the tree is complete" 12 "$(find "$VIEW" -type l | wc -l | tr -d ' ')"
out="$(build)"
t_eq "a following run finds nothing to do" "0:0:12" "$(num "$out" created):$(num "$out" replaced):$(num "$out" unchanged)"

t_summary "models-view"
