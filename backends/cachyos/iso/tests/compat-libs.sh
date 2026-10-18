#!/usr/bin/env bash
#=============================================================================
# Test: the compatibility libraries (backends/cachyos/compat-libs.lock) and everything that handles them before the gate:
#   lock      the real lock is valid, and every way of writing a lock that would let something else in is refused (a URL outside
#             the Arch Linux Archive, a member that is not a versioned shared object, a path that leaves usr/lib, a bad hash, an
#             unknown record kind, a lib of an undeclared package, a missing review date ...)
#   ownership every lib of the real lock has its guard-(b) exemption in overlay/package-owned-ok.txt, and nothing else does a job there
#   stage     stage-compat-libs.sh on a fixture package, the network and the keyring stubbed (compat_download and
#             compat_verify_signature are the only impure steps): staged mode 0644 at the pinned path and nowhere else; a changed
#             package, a failed signature, a wrong member hash, a symlink or a missing member, a failed download each fail and leave
#             the staging tree EMPTY; CI_OS_COMPAT_LIBS=off stages nothing and says so; an overdue review warns (and fails under
#             CI_OS_COMPAT_REVIEW=error); the REAL compat_verify_signature refuses a package without a .sig
#   propose   the maintainer helper prints lock records, with the closure of the libraries a listed one needs (readelf stubbed)
#   shim      mksquashfs-gate.sh: gate passed -> the real mksquashfs runs with the same arguments and the marker is written; gate
#             failed, a source that is not a directory, a misconfigured shim -> exit 1, the real program is not run, no marker
#   wiring    20-build.sh stages the libs before the staging digest, puts the shim first on mkarchiso's PATH only, and fails the build
#             when the marker is missing; the build record carries the COMPAT_ lines
#
#   backends/cachyos/iso/tests/compat-libs.sh
#
# Needs bash 3.2+, awk, sed, bsdtar (macOS has it), a sha256 tool. No Docker, no root, no network. Exit: non-zero when any check
# fails, 2 when it cannot run.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail
export COPYFILE_DISABLE=1     # macOS tar: no AppleDouble (._) members in the fixture package

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS="$(cd "$HERE/../.." && pwd)"
SCRIPTS="$CACHYOS/iso/scripts"
LOCK="$CACHYOS/compat-libs.lock"
# CI_OS_TEST_STAGER / CI_OS_TEST_SHIM: a mutated copy of the script (a copy of the whole scripts/ tree, so its lib/ resolves): see the
# "mutation" notes in docs/architecture/cachyos-backend.md; the tests below must fail on it.
STAGER="${CI_OS_TEST_STAGER:-$SCRIPTS/in-container/stage-compat-libs.sh}"
SHIM="${CI_OS_TEST_SHIM:-$SCRIPTS/in-container/mksquashfs-gate.sh}"
BUILD="$SCRIPTS/in-container/20-build.sh"
OKFILE="$CACHYOS/iso/overlay/package-owned-ok.txt"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
for f in "$LOCK" "$STAGER" "$SHIM" "$BUILD" "$SCRIPTS/lib/compat-lock.sh" "$SCRIPTS/lib/common.sh" "$OKFILE"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
command -v bsdtar >/dev/null 2>&1 || { echo "bsdtar is needed to build the fixture package" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/compat-libs-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# shellcheck source=../scripts/lib/common.sh
. "$SCRIPTS/lib/common.sh"
# shellcheck source=../scripts/lib/compat-lock.sh
. "$SCRIPTS/lib/compat-lock.sh"
sha() { ci_sha256_file "$1"; }
# stderr of the sourced scripts is noise here
export CI_PROG=compat-test

# --- lock ------------------------------------------------------------------------------------------------------------------------
echo "== lock: the real file, and the ways a lock could let something else in"
DESC="the real compat-libs.lock is valid"
if out="$(compat_lock_problems "$LOCK")"; then t_pass "$DESC"; else t_fail "$DESC: $out"; fi

SHA_A=0000000000000000000000000000000000000000000000000000000000000001
SHA_B=0000000000000000000000000000000000000000000000000000000000000002
URL_OK=https://archive.archlinux.org/packages/f/foo-libs/foo-libs-1.2.3-1-x86_64.pkg.tar.zst
good_lock() {
  cat <<EOF
# a comment
review-by 2030-01-01
package foo-libs 1.2.3-1 x86_64 $URL_OK $SHA_A
lib     foo-libs usr/lib/libfoo.so.1.2.3 $SHA_B
EOF
}
# bad_lock NAME SED-EXPRESSION EXPECTED-TEXT: the good lock with one edit must be refused, and the problem must say why.
bad_lock() {
  local name="$1" expr="$2" want="$3" out
  good_lock | sed -e "$expr" > "$W/lock.$name"
  if out="$(compat_lock_problems "$W/lock.$name")"; then t_fail "lock: $name was ACCEPTED"; return; fi
  if printf '%s' "$out" | grep -qF -- "$want"; then t_pass "lock: $name is refused ('$want')"; else t_fail "lock: $name refused for another reason: $out"; fi
}
good_lock > "$W/lock.good"
DESC="lock: the fixture lock used below is valid"
if out="$(compat_lock_problems "$W/lock.good")"; then t_pass "$DESC"; else t_fail "$DESC: $out"; fi
bad_lock host 's|https://archive.archlinux.org/|https://example.org/|' 'the URL must be exactly'
bad_lock plain-http 's|https://archive|http://archive|' 'the URL must be exactly'
bad_lock other-file 's|foo-libs-1.2.3-1-x86_64.pkg.tar.zst|evil-1.0-1-x86_64.pkg.tar.zst|' 'the URL must be exactly'
bad_lock other-dir 's|/packages/f/foo-libs/|/packages/g/foo-libs/|' 'the URL must be exactly'
bad_lock pkg-sha 's|^\(package .* \)[0-9a-f]*$|\1abc|' 'sha256 must be 64 lowercase hex digits'
bad_lock lib-sha 's|^\(lib .* \)[0-9a-f]*$|\1ABC|' 'sha256 must be 64 lowercase hex digits'
bad_lock upper-sha "s|$SHA_B|$(printf '%s' "$SHA_B" | tr 0-9 A-J)|" 'sha256 must be 64 lowercase hex digits'
bad_lock unknown-record 's|^review-by 2030-01-01$|review-by 2030-01-01\nignore foo|' 'unknown record "ignore"'
bad_lock no-review '/^review-by/d' 'exactly one review-by'
bad_lock two-reviews 's|^review-by 2030-01-01$|review-by 2030-01-01\nreview-by 2031-01-01|' 'exactly one review-by'
bad_lock bad-date 's|2030-01-01|2030-13-01|' 'is not a calendar date'
bad_lock bad-date-fmt 's|2030-01-01|soon|' 'review-by needs one YYYY-MM-DD'
bad_lock not-versioned 's|usr/lib/libfoo.so.1.2.3|usr/lib/libfoo.so|' 'is not a versioned shared object'
bad_lock not-lib 's|usr/lib/libfoo.so.1.2.3|usr/lib/foo.so.1|' 'is not a versioned shared object'
bad_lock other-dir-lib 's|usr/lib/libfoo.so.1.2.3|usr/bin/libfoo.so.1.2.3|' 'is not a versioned shared object'
bad_lock traversal 's|usr/lib/libfoo.so.1.2.3|usr/lib/../../etc/libfoo.so.1|' 'is not a versioned shared object'
bad_lock nested 's|usr/lib/libfoo.so.1.2.3|usr/lib/x/libfoo.so.1|' 'is not a versioned shared object'
bad_lock undeclared-pkg 's|^lib     foo-libs|lib     bar-libs|' 'has no package record above it'
bad_lock no-libs '/^lib /d' 'has no lib record'
bad_lock dup-lib 's|^lib \(.*\)$|lib \1\nlib \1|' 'is listed twice'
bad_lock bad-arch 's|x86_64 https|aarch64 https|' 'arch "aarch64" must be x86_64 or any'
bad_lock short-record 's|^package foo-libs 1.2.3-1 x86_64 |package foo-libs 1.2.3-1 |' 'package needs: NAME VERSION ARCH URL SHA256'
printf '' > "$W/lock.empty"
if compat_lock_problems "$W/lock.empty" >/dev/null; then t_fail "lock: an empty file was accepted"; else t_pass "lock: an empty file is refused (no package, no review date)"; fi
if compat_lock_problems "$W/does-not-exist" >/dev/null; then t_fail "lock: a missing file was accepted"; else t_pass "lock: a missing file is refused"; fi

# A lock that needs nothing any more says so with ONE line (retired YYYY-MM-DD). Not with no records: that is what a truncated file looks like.
printf '# the header stays\n\nretired 2026-12-03\n' > "$W/lock.retired"
DESC="lock: a retired lock (the header and one 'retired YYYY-MM-DD' line) is valid, lists no library, and says when it was retired"
if out="$(compat_lock_problems "$W/lock.retired")" && [ -z "$(compat_lock_libs "$W/lock.retired")" ] && [ -z "$(compat_lock_packages "$W/lock.retired")" ] && [ "$(compat_lock_retired "$W/lock.retired")" = 2026-12-03 ]; then t_pass "$DESC"; else t_fail "$DESC: $out"; fi
DESC="lock: a lock that is not retired reports no retirement date"
if [ -z "$(compat_lock_retired "$W/lock.good")" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
refused() { # NAME 'file content' 'expected text'
  printf '%b' "$2" > "$W/lock.$1"
  if out="$(compat_lock_problems "$W/lock.$1")"; then t_fail "lock: $1 was ACCEPTED"; return; fi
  if printf '%s' "$out" | grep -qF -- "$3"; then t_pass "lock: $1 is refused ('$3')"; else t_fail "lock: $1 refused for another reason: $out"; fi
}
refused comments-only '# only the header\n\n' 'retired YYYY-MM-DD'
refused retired-and-package "retired 2026-12-03\npackage foo-libs 1.2.3-1 x86_64 $URL_OK $SHA_A\nlib foo-libs usr/lib/libfoo.so.1.2.3 $SHA_B\n" 'a retired lock holds no package, lib or review-by record'
refused retired-and-review 'retired 2026-12-03\nreview-by 2030-01-01\n' 'a retired lock holds no package, lib or review-by record'
refused retired-twice 'retired 2026-12-03\nretired 2026-12-04\n' 'at most one retired record'
refused retired-no-date 'retired\n' 'retired needs one YYYY-MM-DD date'
refused retired-bad-date 'retired soon\n' 'retired needs one YYYY-MM-DD date'
refused retired-not-a-date 'retired 2026-13-40\n' 'is not a calendar date'

echo "== ownership: the real lock and overlay/package-owned-ok.txt"
miss=""
while read -r _ path _; do
  [ -n "$path" ] || continue
  grep -qF "/$path |" "$OKFILE" || miss="$miss /$path"
done < <(compat_lock_libs "$LOCK")
DESC="every lib of the real lock has its guard-(b) exemption in package-owned-ok.txt"
if [ -z "$miss" ]; then t_pass "$DESC"; else t_fail "$DESC (missing:$miss)"; fi
extra=""
while IFS= read -r line; do
  case "$line" in /usr/lib/libboost_*) ;; *) continue ;; esac
  p="${line%% |*}"; p="${p#/}"
  compat_lock_libs "$LOCK" | awk -v p="$p" '$2 == p { f = 1 } END { exit !f }' || extra="$extra /$p"
done < "$OKFILE"
DESC="... and package-owned-ok.txt has no boost exemption that the lock does not list (a stale one would hide a conflict)"
if [ -z "$extra" ]; then t_pass "$DESC"; else t_fail "$DESC ($extra)"; fi
DESC="the real lock names only the Arch Linux Archive and only packages whose URL carries their own version"
if compat_lock_packages "$LOCK" | awk '{ if (index($4, "https://archive.archlinux.org/packages/") != 1) bad = 1 } END { exit bad }'; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="the real lock's review date is a real date and not in the distant future (a pin should be re-read within a few months)"
by="$(compat_lock_review_by "$LOCK")"
if [ -n "$by" ] && [ "$by" \< "2028-01-01" ]; then t_pass "$DESC ($by)"; else t_fail "$DESC ($by)"; fi

# --- stage --------------------------------------------------------------------------------------------------------------------------
echo "== stage: stage-compat-libs.sh on a fixture package (download and signature stubbed)"
mkdir -p "$W/pkgsrc/usr/lib"
printf 'pkgname = foo-libs\npkgver = 1.2.3-1\n' > "$W/pkgsrc/.PKGINFO"
printf 'FAKE-SHARED-OBJECT-ONE' > "$W/pkgsrc/usr/lib/libfoo.so.1.2.3"
printf 'FAKE-SHARED-OBJECT-TWO' > "$W/pkgsrc/usr/lib/libbar.so.1.0.0"
chmod 755 "$W/pkgsrc/usr/lib/libfoo.so.1.2.3" "$W/pkgsrc/usr/lib/libbar.so.1.0.0"   # the package ships them executable; the stage must not
ln -s libfoo.so.1.2.3 "$W/pkgsrc/usr/lib/libfoo.so"
ln -s libbar.so.1.0.0 "$W/pkgsrc/usr/lib/libbar.so.1"
( cd "$W/pkgsrc" && tar -cf "$W/foo-libs.pkg.tar" .PKGINFO usr )
PKG_SHA="$(sha "$W/foo-libs.pkg.tar")"
FOO_SHA="$(sha "$W/pkgsrc/usr/lib/libfoo.so.1.2.3")"
BAR_SHA="$(sha "$W/pkgsrc/usr/lib/libbar.so.1.0.0")"
mklock() { # NAME [PKG_SHA] [FOO_SHA] [REVIEW]
  cat > "$W/lock.$1" <<EOF
review-by ${4:-2030-01-01}
package foo-libs 1.2.3-1 x86_64 $URL_OK ${2:-$PKG_SHA}
lib foo-libs usr/lib/libfoo.so.1.2.3 ${3:-$FOO_SHA}
lib foo-libs usr/lib/libbar.so.1.0.0 $BAR_SHA
EOF
}

# run_stage NAME [ENV=VAL ...] runs the stager in a subshell where compat_download copies the fixture and compat_verify_signature
# answers from $SIG_RC; prints nothing, sets S_RC, S_OUT. The staging directory is $W/s-NAME.
run_stage() {
  local name="$1"; shift
  mkdir -p "$W/s-$name"
  S_OUT="$W/s-$name.out"
  (
    # shellcheck source=../scripts/in-container/stage-compat-libs.sh
    . "$STAGER"
    set +e
    compat_download() {
      [ "${STDIN_HUNGRY:-0}" != 1 ] || cat > /dev/null
      case "$1" in
        *.sig) [ "${DL_SIG:-ok}" = missing ] || printf 'SIG' > "$2" ;;
        *) [ "${DL_RC:-0}" = 0 ] || return "$DL_RC"; cp "${DL_FILE:-$W/foo-libs.pkg.tar}" "$2" ;;
      esac
    }
    # not "$name": compat_stage_into has a local of that name (dynamic scope), which is the package, not this run
    CALLS_FILE="$W/s-$name.calls"
    compat_verify_signature() { [ "${STDIN_HUNGRY:-0}" != 1 ] || cat > /dev/null; echo "verify-signature called for $(basename "$1")" >> "$CALLS_FILE"; return "${SIG_RC:-0}"; }
    CI_OS_STAGING_DIR="$W/s-$name" CI_OS_COMPAT_LOCK="$W/lock.${LOCK_NAME:-$name}" CI_OS_COMPAT_REPORT_FILE="$W/s-$name.report" \
      CI_OS_COMPAT_WORK="$W/s-$name.work" CI_OS_COMPAT_TODAY="${TODAY:-2026-10-18}" \
      main stage
  ) > "$S_OUT" 2>&1
  S_RC=$?
}
staged_count() { find "$W/s-$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

mklock ok
run_stage ok
DESC="stage: the pinned members land at /usr/lib/<name>, nothing else is written"
if [ "$S_RC" = 0 ] && [ "$(staged_count ok)" = 2 ] && [ "$(sha "$W/s-ok/airootfs/usr/lib/libfoo.so.1.2.3")" = "$FOO_SHA" ] && [ "$(sha "$W/s-ok/airootfs/usr/lib/libbar.so.1.0.0")" = "$BAR_SHA" ] \
  && [ ! -e "$W/s-ok/airootfs/usr/lib/libfoo.so" ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 5 "$S_OUT")"; fi
DESC="stage: the files are mode 0644 (a shared object needs no execute bit, so guard (c) has nothing to say), whatever the package's mode"
if [ "$(find "$W/s-ok" -type f -perm 644 | wc -l | tr -d ' ')" = 2 ] && [ -z "$(find "$W/s-ok" -type f -perm -100)" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="stage: the signature was verified (and after the sha256 check: the call is recorded)"
if grep -q 'verify-signature called for foo-libs-1.2.3-1-x86_64.pkg.tar.zst' "$W/s-ok.calls" 2>/dev/null; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="stage: the report for the build record carries the lock hash, the package and the review date"
if grep -qx 'COMPAT_LIBS=2' "$W/s-ok.report" && grep -qx 'COMPAT_PACKAGES=foo-libs-1.2.3-1-x86_64' "$W/s-ok.report" && grep -qx "COMPAT_LOCK_SHA256=$(sha "$W/lock.ok")" "$W/s-ok.report" \
  && grep -qx 'COMPAT_REVIEW_BY=2030-01-01' "$W/s-ok.report" && grep -qx 'COMPAT_REVIEW_OVERDUE=0' "$W/s-ok.report"; then t_pass "$DESC"; else t_fail "$DESC: $(cat "$W/s-ok.report" 2>&1 | tr '\n' ' ')"; fi
DESC="stage: every report line is KEY=VALUE of the shape 20-build.sh copies into the build record"
if ! grep -vE '^COMPAT_[A-Z0-9_]+=[A-Za-z0-9._,:+@/-]*$' "$W/s-ok.report" | grep -q .; then t_pass "$DESC"; else t_fail "$DESC"; fi

# two packages in one lock: a command that reads stdin must not eat the second record (the stubs below read stdin on purpose)
cat > "$W/lock.two" <<EOF
review-by 2030-01-01
package foo-libs 1.2.3-1 x86_64 $URL_OK $PKG_SHA
lib foo-libs usr/lib/libfoo.so.1.2.3 $FOO_SHA
package bar-libs 1.2.3-1 x86_64 https://archive.archlinux.org/packages/b/bar-libs/bar-libs-1.2.3-1-x86_64.pkg.tar.zst $PKG_SHA
lib bar-libs usr/lib/libbar.so.1.0.0 $BAR_SHA
EOF
STDIN_HUNGRY=1 run_stage two
DESC="stage: two packages in one lock are both staged, even when the download and signature commands read stdin"
if [ "$S_RC" = 0 ] && [ "$(staged_count two)" = 2 ] && [ -f "$W/s-two/airootfs/usr/lib/libfoo.so.1.2.3" ] && [ -f "$W/s-two/airootfs/usr/lib/libbar.so.1.0.0" ] \
  && [ "$(grep -c 'verify-signature called' "$W/s-two.calls")" = 2 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 4 "$S_OUT")"; fi

mklock badpkg 1111111111111111111111111111111111111111111111111111111111111111
run_stage badpkg
DESC="stage: a package whose sha256 is not the pinned one stops the build, names both hashes and stages NOTHING"
if [ "$S_RC" != 0 ] && grep -q "sha256 of the archive file is $PKG_SHA" "$S_OUT" && grep -q 'pins 1111111111' "$S_OUT" && [ "$(staged_count badpkg)" = 0 ] && [ ! -e "$W/s-badpkg.calls" ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 3 "$S_OUT")"; fi

mklock badsig
SIG_RC=1 run_stage badsig
DESC="stage: a package whose signature does not verify stops the build and stages NOTHING"
if [ "$S_RC" != 0 ] && grep -q 'signature could not be verified' "$S_OUT" && [ "$(staged_count badsig)" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC)"; fi

mklock badmember "$PKG_SHA" 2222222222222222222222222222222222222222222222222222222222222222
run_stage badmember
DESC="stage: a member whose sha256 is not the pinned one stops the build; the OTHER member, which was fine, is not left behind either"
if [ "$S_RC" != 0 ] && grep -q "libfoo.so.1.2.3: sha256 is $FOO_SHA" "$S_OUT" && [ "$(staged_count badmember)" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 3 "$S_OUT")"; fi

mklock symlink
sed -i.bak 's|usr/lib/libbar.so.1.0.0|usr/lib/libbar.so.1|' "$W/lock.symlink"; rm -f "$W/lock.symlink.bak"
run_stage symlink
DESC="stage: a member that is a symlink in the package (libbar.so.1) is refused, nothing staged"
if [ "$S_RC" != 0 ] && grep -q 'is not a regular file' "$S_OUT" && [ "$(staged_count symlink)" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 3 "$S_OUT")"; fi

mklock missing
sed -i.bak 's|usr/lib/libbar.so.1.0.0|usr/lib/libgone.so.9.9.9|' "$W/lock.missing"; rm -f "$W/lock.missing.bak"
run_stage missing
DESC="stage: a member the package does not contain is refused, nothing staged"
if [ "$S_RC" != 0 ] && grep -q 'cannot extract usr/lib/libgone.so.9.9.9' "$S_OUT" && [ "$(staged_count missing)" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 3 "$S_OUT")"; fi

mklock dl
DL_RC=22 run_stage dl
DESC="stage: a failed download stops the build and names the URL"
if [ "$S_RC" != 0 ] && grep -q "download failed: $URL_OK" "$S_OUT" && [ "$(staged_count dl)" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC)"; fi

mklock off
CI_OS_COMPAT_LIBS=off run_stage off
DESC="stage: CI_OS_COMPAT_LIBS=off stages nothing, says so loudly, and records 'off' (the switch the gate was proven with)"
if [ "$S_RC" = 0 ] && [ "$(staged_count off)" = 0 ] && grep -q 'CI_OS_COMPAT_LIBS=off' "$S_OUT" && grep -qx 'COMPAT_LIBS=off' "$W/s-off.report"; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 3 "$S_OUT")"; fi

mklock stale "$PKG_SHA" "$FOO_SHA" 2026-10-01
run_stage stale
DESC="stage: a review date in the past only WARNS by default (the build goes on) and is recorded as overdue"
if [ "$S_RC" = 0 ] && grep -q 'was due for review on 2026-10-01' "$S_OUT" && grep -qx 'COMPAT_REVIEW_OVERDUE=1' "$W/s-stale.report" && [ "$(staged_count stale)" = 2 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 3 "$S_OUT")"; fi
mklock stale2 "$PKG_SHA" "$FOO_SHA" 2026-10-01
CI_OS_COMPAT_REVIEW=error run_stage stale2
DESC="stage: ... and CI_OS_COMPAT_REVIEW=error makes it a failure that stages nothing (for a release build)"
if [ "$S_RC" != 0 ] && grep -q 'CI_OS_COMPAT_REVIEW=error' "$S_OUT" && [ "$(staged_count stale2)" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 3 "$S_OUT")"; fi

mklock conflict
mkdir -p "$W/s-conflict/airootfs/usr/lib"; : > "$W/s-conflict/airootfs/usr/lib/libfoo.so.1.2.3"
run_stage conflict
DESC="stage: a path that another producer already put in the staging tree is refused (two producers for one path)"
if [ "$S_RC" != 0 ] && grep -q 'already exists in the staging tree' "$S_OUT"; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC)"; fi

# a retired lock: the stager stages nothing, downloads nothing, and the build record still carries every COMPAT_* key
cp "$W/lock.retired" "$W/lock.retiredstage"
run_stage retiredstage
DESC="stage: a retired lock stages nothing, fetches nothing, and the build goes on (exit 0)"
if [ "$S_RC" = 0 ] && [ "$(staged_count retiredstage)" = 0 ] && [ ! -e "$W/s-retiredstage.calls" ] && [ -z "$(ls "$W/s-retiredstage.work" 2>/dev/null)" ] && grep -q 'is retired (2026-12-03)' "$S_OUT"; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC): $(tail -n 4 "$S_OUT")"; fi
DESC="stage: ... and the report for the build record carries all five keys: COMPAT_LIBS=0, no packages, the lock hash, no review date, not overdue"
if grep -qx 'COMPAT_LIBS=0' "$W/s-retiredstage.report" && grep -qx 'COMPAT_PACKAGES=' "$W/s-retiredstage.report" && grep -qx "COMPAT_LOCK_SHA256=$(sha "$W/lock.retiredstage")" "$W/s-retiredstage.report" \
  && grep -qx 'COMPAT_REVIEW_BY=' "$W/s-retiredstage.report" && grep -qx 'COMPAT_REVIEW_OVERDUE=0' "$W/s-retiredstage.report" && ! grep -vE '^COMPAT_[A-Z0-9_]+=[A-Za-z0-9._,:+@/-]*$' "$W/s-retiredstage.report" | grep -q .; then t_pass "$DESC"; else t_fail "$DESC: $(cat "$W/s-retiredstage.report" 2>&1 | tr '\n' ' ')"; fi
printf '# only a header\n' > "$W/lock.headeronly"
run_stage headeronly
DESC="stage: a lock with a header and no records at all (what a truncated file looks like) stops the build instead of staging nothing"
if [ "$S_RC" != 0 ] && grep -q 'is not a valid compat lock' "$S_OUT" && grep -q 'retired YYYY-MM-DD' "$S_OUT"; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC)"; fi

printf 'review-by 2030-01-01\n' > "$W/lock.invalid"
run_stage invalid
DESC="stage: an invalid lock is refused before anything is downloaded"
if [ "$S_RC" != 0 ] && grep -q 'is not a valid compat lock' "$S_OUT" && [ ! -e "$W/s-invalid.calls" ]; then t_pass "$DESC"; else t_fail "$DESC (rc $S_RC)"; fi

# the real verification step, with a pacman-key stub on PATH: a missing .sig is a failure whatever pacman-key says
mkdir -p "$W/fakebin"
printf '#!/bin/sh\necho "pacman-key $*" >> "%s/pk.calls"\nexit "${PK_RC:-0}"\n' "$W" > "$W/fakebin/pacman-key"; chmod +x "$W/fakebin/pacman-key"
printf 'PKG' > "$W/real.pkg"
real_verify() { # [sig present?] ; env PK_RC
  # shellcheck source=/dev/null
  ( . "$STAGER"; set +e; PATH="$W/fakebin:$PATH" compat_verify_signature "$W/real.pkg" ) > "$W/rv.out" 2>&1
}
rm -f "$W/real.pkg.sig" "$W/pk.calls"; real_verify; rc=$?
DESC="stage: the REAL compat_verify_signature refuses a package with no .sig, without even asking pacman-key"
if [ "$rc" != 0 ] && grep -q 'no signature next to' "$W/rv.out" && [ ! -e "$W/pk.calls" ]; then t_pass "$DESC"; else t_fail "$DESC (rc $rc)"; fi
printf 'SIG' > "$W/real.pkg.sig"; PK_RC=0 real_verify; rc=$?
DESC="stage: ... passes it to pacman-key --verify when it is there, and trusts that verdict (0 = accepted)"
if [ "$rc" = 0 ] && grep -q "pacman-key --verify $W/real.pkg.sig" "$W/pk.calls"; then t_pass "$DESC"; else t_fail "$DESC (rc $rc)"; fi
PK_RC=1 real_verify; rc=$?
DESC="stage: ... and a refusal by pacman-key is a refusal"
if [ "$rc" != 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
rc=0
(
  # shellcheck source=/dev/null
  . "$STAGER"; set +e; PATH="/usr/bin:/bin"
  command -v pacman-key >/dev/null 2>&1 && exit 9
  compat_verify_signature "$W/real.pkg"
) > "$W/rv.out" 2>&1 || rc=$?
DESC="stage: ... and without pacman-key installed it fails closed instead of skipping the check"
if [ "$rc" = 9 ]; then t_pass "$DESC (this machine has pacman-key: skipped)"; elif [ "$rc" != 0 ] && grep -q 'pacman-key is not installed' "$W/rv.out"; then t_pass "$DESC"; else t_fail "$DESC (rc $rc)"; fi

echo "== propose: the maintainer helper (readelf and the network stubbed)"
mkdir -p "$W/propsrc/usr/lib"
for l in libroot.so.1 libmid.so.1 libleaf.so.1 libother.so.1; do printf 'FAKE-%s' "$l" > "$W/propsrc/usr/lib/$l"; done
ln -s libroot.so.1 "$W/propsrc/usr/lib/libroot.so"
( cd "$W/propsrc" && tar -cf "$W/prop.pkg.tar" usr )
printf '#!/bin/sh\n# stub readelf -d FILE: NEEDED lines from the fixture graph root -> mid, leaf; mid -> leaf, libc\nf=$(basename "$2")\ncase "$f" in\n  libroot.so.1) printf " 0x1 (NEEDED)  Shared library: [libmid.so.1]\\n 0x1 (NEEDED)  Shared library: [libleaf.so.1]\\n 0x1 (NEEDED)  Shared library: [libc.so.6]\\n" ;;\n  libmid.so.1) printf " 0x1 (NEEDED)  Shared library: [libleaf.so.1]\\n" ;;\nesac\n' > "$W/fakebin/readelf"; chmod +x "$W/fakebin/readelf"
(
  # shellcheck source=/dev/null
  . "$STAGER"; set +e
  compat_download() { case "$1" in *.sig) printf SIG > "$2" ;; *) cp "$W/prop.pkg.tar" "$2" ;; esac; }
  compat_verify_signature() { return 0; }
  PATH="$W/fakebin:$PATH" main propose foo-libs 1.2.3-1 libroot.so.1
) > "$W/prop.out" 2> "$W/prop.err"; rc=$?
DESC="propose: prints a valid package record and the lib records of the closure (root, mid, leaf), not the unrelated library or libc"
if [ "$rc" = 0 ] && grep -q '^package foo-libs 1.2.3-1 x86_64 https://archive.archlinux.org/packages/f/foo-libs/foo-libs-1.2.3-1-x86_64.pkg.tar.zst ' "$W/prop.out" \
  && grep -q 'usr/lib/libroot.so.1 ' "$W/prop.out" && grep -q 'usr/lib/libmid.so.1 ' "$W/prop.out" && grep -q 'usr/lib/libleaf.so.1 ' "$W/prop.out" \
  && ! grep -q 'libother' "$W/prop.out" && ! grep -q 'libc.so' "$W/prop.out" && [ "$(grep -c '^lib ' "$W/prop.out")" = 3 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $rc): $(cat "$W/prop.out" "$W/prop.err" | tail -n 6)"; fi
DESC="propose: its output is a lock the validator accepts (once a review date is added)"
{ echo 'review-by 2030-01-01'; cat "$W/prop.out"; } > "$W/lock.proposed"
# the fixture URL is the canonical one, and the sha256 values are real hashes
if out="$(compat_lock_problems "$W/lock.proposed")"; then t_pass "$DESC"; else t_fail "$DESC: $out"; fi
(
  # shellcheck source=/dev/null
  . "$STAGER"; set +e
  compat_download() { case "$1" in *.sig) printf SIG > "$2" ;; *) cp "$W/prop.pkg.tar" "$2" ;; esac; }
  compat_verify_signature() { return 1; }
  PATH="$W/fakebin:$PATH" main propose foo-libs 1.2.3-1 libroot.so.1
) > "$W/prop2.out" 2> "$W/prop2.err"; rc=$?
DESC="propose: a package whose signature does not verify yields no records at all"
if [ "$rc" != 0 ] && ! grep -q '^package' "$W/prop2.out" && grep -q 'do not pin this file' "$W/prop2.err"; then t_pass "$DESC"; else t_fail "$DESC (rc $rc)"; fi

echo "== check and help"
rc=0; CI_OS_COMPAT_LOCK="$LOCK" bash "$STAGER" check > "$W/check.out" 2>&1 || rc=$?
DESC="check: the real lock validates through the command line"
if [ "$rc" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC: $(cat "$W/check.out")"; fi
rc=0; CI_OS_COMPAT_LOCK="$W/lock.empty" bash "$STAGER" check > "$W/check.out" 2>&1 || rc=$?
DESC="check: an invalid lock exits non-zero"
if [ "$rc" != 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; fi

# --- shim ----------------------------------------------------------------------------------------------------------------------------
echo "== shim: mksquashfs-gate.sh"
printf '#!/bin/sh\n[ -f "%s/gate.calls" ] || echo "NO-GATE-BEFORE-REAL" >> "%s/real.calls"\necho "REAL $*" >> "%s/real.calls"\nexit "${REAL_RC:-0}"\n' "$W" "$W" "$W" > "$W/real-mksquashfs"; chmod +x "$W/real-mksquashfs"
printf '#!/bin/sh\necho "GATE $*" >> "%s/gate.calls"\nexit "${GATE_RC:-0}"\n' "$W" > "$W/gate.sh"
mkdir -p "$W/airootfs"
run_shim() { # [args...]; env GATE_RC; sets H_RC and H_OUT
  rm -f "$W/real.calls" "$W/gate.calls" "$W/marker"
  CI_OS_REAL_MKSQUASHFS="${SHIM_REAL-$W/real-mksquashfs}" CI_OS_GATE_SCRIPT="${SHIM_GATE-$W/gate.sh}" CI_OS_GATE_MARKER="${SHIM_MARK-$W/marker}" \
    bash "$SHIM" "$@" > "$W/shim.out" 2>&1
  H_RC=$?
}
GATE_RC=0 run_shim "$W/airootfs" "$W/image.sfs" -noappend -comp xz
DESC="shim: gate passed: the real mksquashfs runs with EXACTLY the arguments mkarchiso gave, and the marker is written"
if [ "$H_RC" = 0 ] && [ "$(cat "$W/real.calls")" = "REAL $W/airootfs $W/image.sfs -noappend -comp xz" ] && [ "$(cat "$W/gate.calls")" = "GATE $W/airootfs" ] && grep -q "^passed .* airootfs=$W/airootfs\$" "$W/marker"; then t_pass "$DESC"; else t_fail "$DESC (rc $H_RC): $(cat "$W/shim.out")"; fi
DESC="shim: ... and the gate ran BEFORE the real program (the stub records it if gate.calls did not exist yet)"
if [ -f "$W/gate.calls" ] && [ -f "$W/real.calls" ] && ! grep -q NO-GATE-BEFORE-REAL "$W/real.calls"; then t_pass "$DESC"; else t_fail "$DESC"; fi

GATE_RC=1 run_shim "$W/airootfs" "$W/image.sfs" -noappend
DESC="shim: gate failed: exit 1, the real mksquashfs is NOT run, no marker, and the message says no image was written"
if [ "$H_RC" = 1 ] && [ ! -e "$W/real.calls" ] && [ ! -e "$W/marker" ] && grep -q 'mksquashfs was NOT run and no image was written' "$W/shim.out"; then t_pass "$DESC"; else t_fail "$DESC (rc $H_RC)"; fi

GATE_RC=0 run_shim "$W/image.img" "$W/image.sfs"
DESC="shim: a first argument that is not a directory (an ext4 image) cannot be checked: exit 1 and the real program is not run (fail closed)"
if [ "$H_RC" = 1 ] && [ ! -e "$W/real.calls" ] && [ ! -e "$W/gate.calls" ] && grep -q 'not a directory' "$W/shim.out"; then t_pass "$DESC"; else t_fail "$DESC (rc $H_RC)"; fi

SHIM_REAL='' run_shim "$W/airootfs" "$W/image.sfs"
DESC="shim: without the real mksquashfs configured it refuses to squash an unchecked image"
if [ "$H_RC" = 1 ] && [ ! -e "$W/real.calls" ] && grep -q 'Refusing to squash an unchecked image' "$W/shim.out"; then t_pass "$DESC"; else t_fail "$DESC (rc $H_RC)"; fi
SHIM_GATE="$W/nogate.sh" run_shim "$W/airootfs" "$W/image.sfs"
DESC="shim: a gate script that does not exist is a refusal, not a pass"
if [ "$H_RC" = 1 ] && [ ! -e "$W/real.calls" ]; then t_pass "$DESC"; else t_fail "$DESC (rc $H_RC)"; fi
SHIM_MARK='' run_shim "$W/airootfs" "$W/image.sfs"
DESC="shim: no marker path configured is a refusal"
if [ "$H_RC" = 1 ] && [ ! -e "$W/real.calls" ]; then t_pass "$DESC"; else t_fail "$DESC (rc $H_RC)"; fi

printf 'stale\n' > "$W/marker2"
rm -f "$W/real.calls"; GATE_RC=1 CI_OS_REAL_MKSQUASHFS="$W/real-mksquashfs" CI_OS_GATE_SCRIPT="$W/gate.sh" CI_OS_GATE_MARKER="$W/marker2" bash "$SHIM" "$W/airootfs" "$W/x" >/dev/null 2>&1; rc=$?
DESC="shim: a marker left by an earlier run is removed before the gate runs, so a failing gate cannot inherit a pass"
if [ "$rc" = 1 ] && [ ! -e "$W/marker2" ]; then t_pass "$DESC"; else t_fail "$DESC (rc $rc)"; fi

# --- wiring --------------------------------------------------------------------------------------------------------------------------
echo "== wiring: 20-build.sh"
site() { # DESC FILE FIXED-STRING
  if grep -qF -- "$3" "$2"; then t_pass "$1"; else t_fail "$1 (no line contains: $3)"; fi
}
site "20-build.sh runs stage-compat-libs.sh (stage) from the in-container script directory" "$BUILD" 'bash "$SCRIPT_DIR/stage-compat-libs.sh" stage'
site "20-build.sh hands the staging tree, the lock and a report file to it" "$BUILD" 'CI_OS_STAGING_DIR="$STAGING" CI_OS_COMPAT_LOCK="$COMPAT_LOCK" CI_OS_COMPAT_REPORT_FILE="$COMPAT_REPORT"'
# the staging digest is computed AFTER the compat step, so STAGING_SHA256 of the build record covers the libraries
awk '/stage-compat-libs.sh" stage/ { s = NR } /^STAGING_DIGEST=/ { d = NR } END { exit !(s && d && s < d) }' "$BUILD" \
  && t_pass "20-build.sh computes STAGING_DIGEST after the compat step (the record covers the libraries)" || t_fail "20-build.sh computes STAGING_DIGEST before the compat step"
awk '/stage-compat-libs.sh" stage/ { s = NR } /CI_OS_STOP_AFTER=overlay: stopping before mkarchiso/ { o = NR } END { exit !(s && o && s < o) }' "$BUILD" \
  && t_pass "20-build.sh stages the compat libs before the overlay-only stop (the engine's guards (b) and (c) see them)" || t_fail "20-build.sh stages the compat libs after the overlay-only stop"
site "20-build.sh copies the COMPAT_ lines of the report into the build record" "$BUILD" "grep -E '^COMPAT_[A-Z0-9_]+="
if [ "$(grep -cF 'PATH="$GATE_BIN:$PATH"' "$BUILD")" -ge 2 ]; then t_pass "20-build.sh puts the shim first on PATH for both mkarchiso calls (validate and the real build)"; else t_fail "20-build.sh must use the shim PATH for both mkarchiso calls"; fi
if ! grep -qE '^[[:space:]]*export[[:space:]]+PATH' "$BUILD"; then t_pass "20-build.sh never exports the shim PATH: only the mkarchiso calls see it"; else t_fail "20-build.sh exports PATH"; fi
site "20-build.sh finds the real mksquashfs (before the shim is on any PATH)" "$BUILD" 'REAL_MKSQUASHFS="$(command -v mksquashfs'
awk '/REAL_MKSQUASHFS="\$\(command -v mksquashfs/ { r = NR } /PATH="\$GATE_BIN:\$PATH"/ { if (!p) p = NR } END { exit !(r && p && r < p) }' "$BUILD" \
  && t_pass "20-build.sh looks up the real mksquashfs before any PATH carries the shim" || t_fail "20-build.sh looks up mksquashfs after the shim is on PATH (it would find itself)"
site "20-build.sh fails the build when the gate marker is missing after mkarchiso" "$BUILD" '[ -s "$GATE_MARKER" ] || ci_die "mkarchiso finished but the installer gate never ran'
site "20-build.sh names the gate when mkarchiso failed because of it" "$BUILD" 'THE CALAMARES GATE FAILED'
site "20-build.sh installs the shim as the program named mksquashfs" "$BUILD" 'install -m 0755 "$SCRIPT_DIR/mksquashfs-gate.sh" "$GATE_BIN/mksquashfs"'

# mkarchiso's own contract, from its source when this machine has it (the builder container always does)
if [ -r /usr/bin/mkarchiso ]; then
  if grep -qE '_unshare mksquashfs "\$\{image_source\}"' /usr/bin/mkarchiso; then t_pass "mkarchiso calls mksquashfs by its bare name (so a shim first on PATH is what runs)"; else t_fail "mkarchiso no longer calls 'mksquashfs' by that name: the shim is bypassed, re-read mksquashfs-gate.sh"; fi
else
  echo "info  /usr/bin/mkarchiso is not here: the bare-name contract is checked by compat-gate-container.sh in the builder"
fi

echo
printf '== %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
