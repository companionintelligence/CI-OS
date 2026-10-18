#!/usr/bin/env bash
#=============================================================================
# Test: gate-calamares.sh, the build-time gate that stops mkarchiso before it squashes an image whose installer cannot start (risk R1,
# incident 2026-10-18). It runs on a FAKE airootfs with a stub for the two things that need a Linux root and amd64 binaries
# (CI_OS_GATE_EXEC: `ldd -r` and the offscreen start), so every verdict is driven by recorded output of the real tools:
#
#   pass         ldd clean, offscreen start still running at the timeout (also: it exited 0)
#   ldd          a missing library, one that the lock lists and one it does not (the second F2 hint differs), an undefined symbol (the
#                boost.python init_module of F2's second failure, with the real mangled name), a "version ... not found" (a libstdc++
#                older than the one the installer was built with), one library in two versions inside the process of /usr/bin/calamares
#   smoke        a dynamic-linker error in the output of the start fails the gate even when ldd was clean and the process survived;
#                a crash (139), an abort, an early exit with status 1, a start that cannot be run (97)
#   image        no cachyos-calamares-next in the image, no ELF /usr/bin/calamares in its file list
#   compat       a staged compat library whose sha256 differs from the pin ("something replaced it"); one that nothing needs any more
#                (a warning, or a failure under CI_OS_GATE_STALE=error: the shim can be removed); an invalid lock
#   message      names the library or symbol and the file that needs it, points at compat-libs.lock and says mkarchiso was stopped
#   hygiene      the gate leaves the image byte-identical, and exits 2 on bad usage
#
#   backends/cachyos/iso/tests/gate-calamares.sh
#
# The proof on the REAL packages (the F2 mismatch, the symlink attempt, the pass with the pinned libraries, the stock mkarchiso and the
# shim) needs Docker and the network: tests/compat-gate-container.sh. Needs bash 3.2+, awk, sed, od. Exit: non-zero when any check
# fails, 2 when it cannot run.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail
export COPYFILE_DISABLE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS="$(cd "$HERE/../.." && pwd)"
# CI_OS_TEST_GATE: a mutated copy of the gate (a copy of the whole scripts/ tree); the tests below must fail on it.
GATE="${CI_OS_TEST_GATE:-$CACHYOS/iso/scripts/in-container/gate-calamares.sh}"
SCRIPTS="$CACHYOS/iso/scripts"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
[ -f "$GATE" ] || { echo "missing: $GATE" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/gate-calamares-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# shellcheck source=../scripts/lib/common.sh
. "$SCRIPTS/lib/common.sh"
export CI_PROG=gate-test

# --- fixtures ----------------------------------------------------------------------------------------------------------------------
# The fake image. The files list is what pacman's local database has for the package; ELF files carry the ELF magic.
PKGDIR=var/lib/pacman/local/cachyos-calamares-next-3.4.2-13
ELF_FILES="usr/bin/calamares usr/lib/libcalamares.so.3.4.1 usr/lib/libcalamaresui.so.3.4.1 usr/lib/calamares/modules/partition/libcalamares_viewmodule_partition.so"
mkroot() { # DIR
  local d="$1" f
  mkdir -p "$d/$PKGDIR" "$d/usr/bin" "$d/usr/lib/calamares/modules/partition" "$d/usr/share/calamares" "$d/etc/calamares"
  for f in $ELF_FILES; do printf '\177ELF fake %s' "$f" > "$d/$f"; chmod 755 "$d/$f"; done
  ln -s libcalamares.so.3.4.1 "$d/usr/lib/libcalamares.so.3.4"
  printf 'branding: cachyos\n' > "$d/etc/calamares/settings.conf"
  printf 'text, not ELF\n' > "$d/usr/share/calamares/qml.txt"
  {
    printf '%%FILES%%\n'
    printf 'etc/\netc/calamares/\netc/calamares/settings.conf\nusr/\nusr/bin/\nusr/bin/calamares\nusr/lib/\nusr/lib/libcalamares.so.3.4\nusr/lib/libcalamares.so.3.4.1\n'
    printf 'usr/lib/libcalamaresui.so.3.4.1\nusr/lib/calamares/\nusr/lib/calamares/modules/\nusr/lib/calamares/modules/partition/\nusr/lib/calamares/modules/partition/libcalamares_viewmodule_partition.so\n'
    printf 'usr/share/\nusr/share/calamares/\nusr/share/calamares/qml.txt\n\n%%BACKUP%%\netc/calamares/settings.conf\tabc\n'
  } > "$d/$PKGDIR/files"
}

# The stub: what `ldd -r PATH` printed, per ELF (a file in $FAKE_LDD_DIR named like the path, / as _), else the default; and the start.
cat > "$W/fake-exec" <<'STUB'
#!/bin/bash
case "$1" in
  ldd)
    f="$FAKE_LDD_DIR/$(printf '%s' "$3" | tr / _)"
    echo "ldd $3" >> "$FAKE_CALLS"
    if [ -f "$f" ]; then cat "$f"; else cat "$FAKE_LDD_DIR/default"; fi ;;
  smoke)
    echo "smoke $3" >> "$FAKE_CALLS"
    if [ -f "$FAKE_SMOKE_OUT" ]; then cat "$FAKE_SMOKE_OUT" > "$4"; else : > "$4"; fi
    exit "${FAKE_SMOKE_RC:-124}" ;;
esac
exit 99
STUB
chmod +x "$W/fake-exec"
mkdir -p "$W/ldd"
cat > "$W/ldd/default" <<'EOF'
	linux-vdso.so.1 (0x0000ffff7f9e0000)
	libQt6Core.so.6 => /usr/lib/libQt6Core.so.6 (0x0000ffff7f200000)
	libboost_python314.so.1.91.0 => /usr/lib/libboost_python314.so.1.91.0 (0x0000ffff7f1a0000)
	libboost_container.so.1.91.0 => /usr/lib/libboost_container.so.1.91.0 (0x0000ffff7f180000)
	libboost_graph.so.1.91.0 => /usr/lib/libboost_graph.so.1.91.0 (0x0000ffff7f120000)
	libstdc++.so.6 => /usr/lib/libstdc++.so.6 (0x0000ffff7ef00000)
	libc.so.6 => /usr/lib/libc.so.6 (0x0000ffff7ed00000)
	/lib64/ld-linux-x86-64.so.2 (0x0000ffff7f9e2000)
EOF
: > "$W/smoke.out"; export FAKE_SMOKE_OUT="$W/smoke.out"

# The fixture lock and its compat libraries (content is arbitrary; what matters is the sha256 pin).
printf 'FAKE-BOOST-PYTHON' > "$W/lib-python"; printf 'FAKE-BOOST-CONTAINER' > "$W/lib-container"
SHA_PY="$(ci_sha256_file "$W/lib-python")"; SHA_CT="$(ci_sha256_file "$W/lib-container")"
cat > "$W/lock" <<EOF
review-by 2030-01-01
package boost-libs 1.91.0-2 x86_64 https://archive.archlinux.org/packages/b/boost-libs/boost-libs-1.91.0-2-x86_64.pkg.tar.zst 0000000000000000000000000000000000000000000000000000000000000001
lib boost-libs usr/lib/libboost_python314.so.1.91.0 $SHA_PY
lib boost-libs usr/lib/libboost_container.so.1.91.0 $SHA_CT
EOF
with_compat() { cp "$W/lib-python" "$1/usr/lib/libboost_python314.so.1.91.0"; cp "$W/lib-container" "$1/usr/lib/libboost_container.so.1.91.0"; }

# run_gate DIR [ENV=VAL ...]: sets G_RC and G_OUT (stdout and stderr together)
run_gate() {
  local d="$1"; shift
  : > "$W/calls"
  env CI_OS_GATE_EXEC="$W/fake-exec" FAKE_LDD_DIR="$W/ldd" FAKE_CALLS="$W/calls" CI_OS_COMPAT_LOCK="$W/lock" CI_OS_GATE_SMOKE_SECONDS=7 "$@" \
    bash "$GATE" "$d" > "$W/gate.out" 2>&1
  G_RC=$?
  G_OUT="$(cat "$W/gate.out")"
}
says() { printf '%s\n' "$G_OUT" | grep -qF -- "$1"; }
ldd_for() { printf '%s\n' "$2" > "$W/ldd/$(printf '%s' "$1" | tr / _)"; }   # ldd_for /usr/bin/calamares TEXT
ldd_reset() { rm -f "$W"/ldd/_usr_*; }

echo "== pass"
mkroot "$W/good"; with_compat "$W/good"
run_gate "$W/good"
DESC="a clean image passes: exit 0, every ELF file of the package was checked (4), the start ran for the configured time"
if [ "$G_RC" = 0 ] && says '4 ELF file(s) to check' && says 'passed: cachyos-calamares-next starts in this image' && [ "$(grep -c '^ldd ' "$W/calls")" = 4 ] && grep -q '^smoke ' "$W/calls" && says 'offscreen start of /usr/bin/calamares (7 s'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; printf '%s\n' "$G_OUT" | sed 's/^/      /' | tail -n 8; fi
DESC="only ELF files are checked: not the symlink libcalamares.so.3.4, the config or the text file"
if ! grep -q 'libcalamares.so.3.4$' "$W/calls" && ! grep -q 'settings.conf' "$W/calls" && ! grep -q 'qml.txt' "$W/calls"; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="the package's ELF list comes from the image's own pacman database (a new module is covered without a list in the repository)"
mkroot "$W/mod"; with_compat "$W/mod"; mkdir -p "$W/mod/usr/lib/calamares/modules/newmod"
printf '\177ELF fake newmod' > "$W/mod/usr/lib/calamares/modules/newmod/libcalamares_job_newmod.so"
awk '/^usr\/share\/$/ { print "usr/lib/calamares/modules/newmod/libcalamares_job_newmod.so" } { print }' "$W/mod/$PKGDIR/files" > "$W/mod/files.new" && mv "$W/mod/files.new" "$W/mod/$PKGDIR/files"
run_gate "$W/mod"
if [ "$G_RC" = 0 ] && grep -q 'libcalamares_job_newmod.so$' "$W/calls"; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
DESC="the start exiting 0 within the time is also a pass"
run_gate "$W/good" FAKE_SMOKE_RC=0
if [ "$G_RC" = 0 ] && says 'exited 0 within'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi

echo "== ldd -r: what F2 looked like"
mkroot "$W/m1"      # the compat libraries are NOT in the image: what the gate says when ldd reports the first F2 failure
ldd_for /usr/bin/calamares "$(cat "$W/ldd/default" | sed 's|libboost_python314.so.1.91.0 => /usr/lib/libboost_python314.so.1.91.0.*|libboost_python314.so.1.91.0 => not found|')"
ldd_for /usr/lib/libcalamares.so.3.4.1 "$(cat "$W/ldd/default" | sed 's|libboost_python314.so.1.91.0 => /usr/lib/libboost_python314.so.1.91.0.*|libboost_python314.so.1.91.0 => not found|')"
run_gate "$W/m1"
DESC="F2, first failure: a missing library fails the gate (exit 1), the message names it and the ELF files that need it"
if [ "$G_RC" = 1 ] && says 'missing library libboost_python314.so.1.91.0: needed by /usr/bin/calamares' && says '(2 ELF file(s))'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; printf '%s\n' "$G_OUT" | sed 's/^/      /' | tail -n 8; fi
DESC="... and it points at the lock and says that the library IS listed there, so the compat step did not run (the mutation: CI_OS_COMPAT_LIBS=off)"
if says 'IS listed in backends/cachyos/compat-libs.lock' && says 'CI_OS_COMPAT_LIBS=off'; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="... and it says mkarchiso was stopped before it squashed the image, and where the background is written"
if says 'mkarchiso was stopped BEFORE it squashed the image' && says 'Rolling-release drift incident 2026-10-18' && says 'backends/cachyos/compat-libs.lock'; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="the offscreen start still runs after a failed static check (the second, independent witness)"
if grep -q '^smoke ' "$W/calls"; then t_pass "$DESC"; else t_fail "$DESC"; fi
ldd_reset

mkroot "$W/m2"
ldd_for /usr/bin/calamares "$(cat "$W/ldd/default" | sed 's|libstdc++.so.6 => .*|libfoo.so.9 => not found|')"
run_gate "$W/m2"
DESC="a missing library that the lock does NOT list is reported without the compat hint (nothing to refresh: it is a different problem)"
if [ "$G_RC" = 1 ] && says 'missing library libfoo.so.9' && ! says 'IS listed in'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
ldd_reset

mkroot "$W/u1"; with_compat "$W/u1"
SYM='_ZN5boost6python6detail11init_moduleER11PyModuleDefPFvvE'
ldd_for /usr/lib/libcalamares.so.3.4.1 "$(cat "$W/ldd/default"; printf 'undefined symbol: %s\t(/usr/lib/libcalamares.so.3.4)\n' "$SYM")"
run_gate "$W/u1"
DESC="F2, second failure: an undefined symbol (boost.python init_module) fails the gate; the message has the symbol and the file"
if [ "$G_RC"  = 1 ] && says '1 undefined symbol(s)' && says '/usr/lib/libcalamares.so.3.4' && { says "$SYM" || says 'init_module'; }; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; printf '%s\n' "$G_OUT" | sed 's/^/      /' | tail -n 6; fi
DESC="... and it says what an undefined symbol means (a library of another generation than the installer was built against)"
if says 'a library of another generation than the one the installer was built against'; then t_pass "$DESC"; else t_fail "$DESC"; fi
ldd_reset

mkroot "$W/u2"; with_compat "$W/u2"
ldd_for /usr/lib/libcalamaresui.so.3.4.1 "$(cat "$W/ldd/default"; printf "\t./libcalamaresui.so: /usr/lib/libstdc++.so.6: version 'GLIBCXX_3.4.34' not found (required by ./libcalamaresui.so)\n")"
run_gate "$W/u2"
DESC="a libstdc++/glibc older than the one the installer was built with (version 'GLIBCXX_3.4.34' not found) fails the gate"
if [ "$G_RC" = 1 ] && says "GLIBCXX_3.4.34' not found" && says '/usr/lib/libcalamaresui.so.3.4.1'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
ldd_reset

mkroot "$W/mix"; with_compat "$W/mix"
ldd_for /usr/bin/calamares "$(cat "$W/ldd/default"; printf '\tlibboost_graph.so.1.92.0 => /usr/lib/libboost_graph.so.1.92.0 (0x0000ffff71000000)\n')"
run_gate "$W/mix"
DESC="one library in two versions inside the process of /usr/bin/calamares (graph 1.91.0 and 1.92.0) fails the gate and names both"
if [ "$G_RC" = 1 ] && says 'would load libboost_graph.so in two versions (1.91.0,1.92.0)'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; printf '%s\n' "$G_OUT" | sed 's/^/      /' | tail -n 4; fi
ldd_reset
DESC="... but two different libraries (python314 1.91.0 and graph 1.91.0) are not a mixture: the clean default passes"
run_gate "$W/good"
if [ "$G_RC" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; fi

echo "== the offscreen start"
printf '/usr/bin/calamares: symbol lookup error: /usr/lib/libcalamares.so.3.4: undefined symbol: %s\n' "$SYM" > "$W/smoke.f2b"
run_gate "$W/good" FAKE_SMOKE_RC=127 FAKE_SMOKE_OUT="$W/smoke.f2b"
DESC="ldd clean but the start dies with F2's 'symbol lookup error' (exit 127): the gate fails and quotes the linker's line"
if [ "$G_RC" = 1 ] && says 'printed a dynamic-linker error (exit status 127)' && says "symbol lookup error: /usr/lib/libcalamares.so.3.4: undefined symbol: $SYM"; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; printf '%s\n' "$G_OUT" | sed 's/^/      /' | tail -n 5; fi
DESC="... and the same line fails it when the process SURVIVES (exit 124): a linker error in the output is never ignored"
run_gate "$W/good" FAKE_SMOKE_RC=124 FAKE_SMOKE_OUT="$W/smoke.f2b"
if [ "$G_RC" = 1 ] && says 'printed a dynamic-linker error'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
printf '/usr/bin/calamares: error while loading shared libraries: libboost_python314.so.1.91.0: cannot open shared object file: No such file or directory\n' > "$W/smoke.f2a"
run_gate "$W/good" FAKE_SMOKE_RC=127 FAKE_SMOKE_OUT="$W/smoke.f2a"
DESC="F2's first failure text ('error while loading shared libraries') from the start fails it too"
if [ "$G_RC" = 1 ] && says 'error while loading shared libraries: libboost_python314.so.1.91.0'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
printf 'Calamares: some qt message\nQFatal\n' > "$W/smoke.crash"
run_gate "$W/good" FAKE_SMOKE_RC=139 FAKE_SMOKE_OUT="$W/smoke.crash"
DESC="a crash (segmentation fault, 139) fails the gate with the last lines of the output"
if [ "$G_RC" = 1 ] && says 'exited with status 139 within 7 s' && says 'QFatal'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
run_gate "$W/good" FAKE_SMOKE_RC=1 FAKE_SMOKE_OUT="$W/smoke.crash"
DESC="an early exit with status 1 and no linker message also fails (the installer must stay up)"
if [ "$G_RC" = 1 ] && says 'exited with status 1 within 7 s'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
printf 'cannot make a read-only view\n' > "$W/smoke.97"
run_gate "$W/good" FAKE_SMOKE_RC=97 FAKE_SMOKE_OUT="$W/smoke.97"
DESC="a start that could not be run (97: no read-only view, no arch-chroot) is a failure, never a silent skip"
if [ "$G_RC" = 1 ] && says 'the offscreen start could not be run: cannot make a read-only view'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
run_gate "$W/good" FAKE_SMOKE_RC=137
DESC="killed by the timeout's -k (137) counts as still running"
if [ "$G_RC" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi

echo "== the image"
mkdir -p "$W/nopkg/usr"
run_gate "$W/nopkg"
DESC="an image without cachyos-calamares-next fails: the live system would have no installer"
if [ "$G_RC" = 1 ] && says 'cachyos-calamares-next is not installed in this image'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
mkroot "$W/nobin"; with_compat "$W/nobin"; rm "$W/nobin/usr/bin/calamares"
run_gate "$W/nobin"
DESC="an image whose package no longer ships an ELF /usr/bin/calamares fails (the package layout changed)"
if [ "$G_RC" = 1 ] && says 'usr/bin/calamares is not an ELF file of cachyos-calamares-next'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
DESC="CI_OS_GATE_PACKAGE selects another package of the image to gate"
mkroot "$W/other"; with_compat "$W/other"; mv "$W/other/$PKGDIR" "$W/other/var/lib/pacman/local/cachyos-calamares-qt6-3.3.15-16"
run_gate "$W/other" CI_OS_GATE_PACKAGE=cachyos-calamares-qt6
if [ "$G_RC" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
DESC="the package name is matched exactly: cachyos-calamares-next-deckify is not cachyos-calamares-next"
mkroot "$W/deck"; with_compat "$W/deck"; mv "$W/deck/$PKGDIR" "$W/deck/var/lib/pacman/local/cachyos-calamares-next-deckify-3.4.1-2"
run_gate "$W/deck"
if [ "$G_RC" = 1 ] && says 'is not installed in this image'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi

echo "== the compat libraries"
mkroot "$W/c1"; with_compat "$W/c1"; printf 'REPLACED' > "$W/c1/usr/lib/libboost_python314.so.1.91.0"
run_gate "$W/c1"
DESC="a staged compat library whose sha256 is not the pin fails ('something replaced the staged file'), with both hashes"
if [ "$G_RC" = 1 ] && says 'something replaced the staged file' && says "pins $SHA_PY"; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
mkroot "$W/c2"; with_compat "$W/c2"
sed 's|libboost_python314.so.1.91.0 => .*||; s|libboost_container.so.1.91.0 => .*||' "$W/ldd/default" > "$W/ldd/_usr_bin_calamares"
for f in usr/lib/libcalamares.so.3.4.1 usr/lib/libcalamaresui.so.3.4.1 usr/lib/calamares/modules/partition/libcalamares_viewmodule_partition.so; do cp "$W/ldd/_usr_bin_calamares" "$W/ldd/_$(printf '%s' "$f" | tr / _)"; done
run_gate "$W/c2"
DESC="a compat library that no ELF file needs any more (the installer was rebuilt) is a WARNING that says it can be removed; the gate passes"
if [ "$G_RC" = 0 ] && says '/usr/lib/libboost_python314.so.1.91.0 is not needed by cachyos-calamares-next any more' && says 'Remove the records of backends/cachyos/compat-libs.lock'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; printf '%s\n' "$G_OUT" | sed 's/^/      /' | tail -n 6; fi
run_gate "$W/c2" CI_OS_GATE_STALE=error
DESC="... and CI_OS_GATE_STALE=error makes it a failure"
if [ "$G_RC" = 1 ] && says 'remove it from backends/cachyos/compat-libs.lock'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
ldd_reset
mkroot "$W/c3"
run_gate "$W/c3"
DESC="the compat libraries not being in the image at all is not a failure by itself when nothing needs them (a clean ldd)"
if [ "$G_RC" = 0 ] && says 'is not in the image'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi
printf 'review-by soon\n' > "$W/lock.bad"
mkroot "$W/c4"; with_compat "$W/c4"
run_gate "$W/c4" CI_OS_COMPAT_LOCK="$W/lock.bad"
DESC="an invalid lock fails the gate (it cannot say what the image should hold)"
if [ "$G_RC" = 1 ] && says 'is not a valid compat lock'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; fi

# a retired lock (nothing is needed any more): the gate accepts the lock, and still fails an installer that cannot load a library
printf '# the header\nretired 2026-12-03\n' > "$W/lock.retired"
ldd_reset
mkroot "$W/c5"
run_gate "$W/c5" CI_OS_COMPAT_LOCK="$W/lock.retired"
DESC="a retired compat lock passes the gate on an image that has no compat library and an installer that links"
if [ "$G_RC" = 0 ] && ! says 'is not a valid compat lock'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; printf '%s\n' "$G_OUT" | sed 's/^/      /' | tail -n 5; fi
mkroot "$W/c6"
ldd_for /usr/bin/calamares "	libboost_python314.so.1.93.0 => not found"
run_gate "$W/c6" CI_OS_COMPAT_LOCK="$W/lock.retired"
DESC="... and a retired lock does not blind it: an installer that needs a library the image lacks still fails the gate"
if [ "$G_RC" = 1 ] && says 'missing library libboost_python314.so.1.93.0'; then t_pass "$DESC"; else t_fail "$DESC (rc $G_RC)"; printf '%s\n' "$G_OUT" | sed 's/^/      /' | tail -n 6; fi
ldd_reset

echo "== hygiene"
tree_digest() { ci_tree_digest "$1"; }
mkroot "$W/h1"; with_compat "$W/h1"
before="$(tree_digest "$W/h1")"
run_gate "$W/h1"
after="$(tree_digest "$W/h1")"
DESC="the gate leaves the image byte-identical (no file added, none changed)"
if [ "$G_RC" = 0 ] && [ "$before" = "$after" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
rc=0; bash "$GATE" > "$W/u.out" 2>&1 || rc=$?
DESC="usage: no argument exits 2"
if [ "$rc" = 2 ] && grep -q 'usage: gate-calamares.sh ROOT' "$W/u.out"; then t_pass "$DESC"; else t_fail "$DESC (rc $rc)"; fi
rc=0; bash "$GATE" "$W" > "$W/u.out" 2>&1 || rc=$?
DESC="usage: a directory without usr/ (not an airootfs) exits 2"
if [ "$rc" = 2 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $rc)"; fi
rc=0; CI_OS_GATE_SMOKE_SECONDS=abc bash "$GATE" "$W/good" > "$W/u.out" 2>&1 || rc=$?
DESC="usage: CI_OS_GATE_SMOKE_SECONDS that is not a positive number exits 2"
if [ "$rc" = 2 ]; then t_pass "$DESC"; else t_fail "$DESC (rc $rc)"; fi
DESC="--help prints the header"
if bash "$GATE" --help | grep -q 'the build-time gate for the installer'; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="the real, unstubbed gate on a fake root fails closed instead of passing (no chroot or no amd64 binaries here: it must not report a pass)"
if [ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ]; then
  t_pass "$DESC (skipped: this is a root Linux host, where the real chroot would be tried)"
else
  rc=0; CI_OS_COMPAT_LOCK="$W/lock" bash "$GATE" "$W/good" > "$W/real.out" 2>&1 || rc=$?
  if [ "$rc" != 0 ] && ! grep -q 'passed: cachyos-calamares-next starts' "$W/real.out"; then t_pass "$DESC"; else t_fail "$DESC (rc $rc)"; fi
fi

echo
printf '== %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
