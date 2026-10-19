#!/usr/bin/env bash
# gate-calamares.sh ROOT: the build-time gate for the installer. ROOT is the assembled airootfs (what mkarchiso is about to squash).
# The next rolling-release drift has to fail the BUILD, not the person who clicks "Install Companion OS" (risk R1, incident 2026-10-18:
# cachyos-calamares-next was linked against boost 1.91, the image had boost 1.92, Calamares exited with status 127).
#
# What it does, inside ROOT, without changing it:
#   1. finds cachyos-calamares-next in the image's own pacman database (var/lib/pacman/local/<pkg>-<ver>/files) and takes every ELF
#      file the package owns: /usr/bin/calamares, libcalamares*.so, every module .so. No hard-coded list: a new module is covered.
#   2. `ldd -r` on each: no "not found" (a library the image lacks), no "undefined symbol" (a library of another generation: the
#      second F2 failure was a boost.python symbol that the 1.92 file does not export), no "version ... not found" (a libstdc++ or
#      glibc that is older than the one the package was built with). `ldd -r` resolves every function relocation, not just the
#      ones that run first.
#   3. one library name in two versions inside the process of /usr/bin/calamares (libboost_graph.so.1.91.0 and .so.1.92.0 loaded
#      together) is a failure: both define the same C++ symbols and the first one wins.
#   4. a short start of the real Calamares, offscreen (QT_QPA_PLATFORM=offscreen, a read-only view of ROOT, HOME on a tmpfs, a
#      timeout): it must still be running when the time is up. It exercises the dynamic linker the way a click does, including the
#      Python initialisation that failed in F2. A linker or symbol error anywhere in its output fails the gate even when the
#      process survives.
#   5. the compatibility libraries of backends/cachyos/compat-libs.lock that are in the image have the pinned sha256, and each is
#      still NEEDED by the installer (otherwise it says so: the shim can be removed).
# Any failure prints what is wrong (the library or the symbol, which file needs it) and where to fix it (compat-libs.lock) and exits 1.
#
# Environment: CI_OS_COMPAT_LOCK (default backends/cachyos/compat-libs.lock), CI_OS_GATE_PACKAGE (default cachyos-calamares-next),
#   CI_OS_GATE_SMOKE_SECONDS (default 20; Rosetta needs about 5), CI_OS_GATE_STALE=warn|error (a compat library nothing needs).
# Test hook: CI_OS_GATE_EXEC=PROGRAM replaces the two things that need a Linux root and amd64 binaries. It is called as
#   PROGRAM ldd ROOT /path/in/root          prints what `ldd -r` prints
#   PROGRAM smoke ROOT SECONDS OUTFILE      writes the program's output to OUTFILE, exit status as `timeout` gives it
# Exit: 0 passed, 1 the installer cannot start in this image, 2 usage.
set -uo pipefail
export LC_ALL=C

export CI_PROG=gate-calamares
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/compat-lock.sh
. "$SCRIPT_DIR/../lib/compat-lock.sh"

case "${1:-}" in -h|--help) sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'; exit 0 ;; esac
ROOT="${1:-}"
[ -n "$ROOT" ] && [ -d "$ROOT/usr" ] || { ci_err "usage: gate-calamares.sh ROOT   (ROOT is the airootfs: it has no usr/ here: '${ROOT}')"; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"
PKG="${CI_OS_GATE_PACKAGE:-cachyos-calamares-next}"
LOCK="${CI_OS_COMPAT_LOCK:-$CACHYOS_DIR/compat-libs.lock}"
SECS="${CI_OS_GATE_SMOKE_SECONDS:-20}"
case "$SECS" in ''|*[!0-9]*|0) ci_err "CI_OS_GATE_SMOKE_SECONDS must be a positive number (got '$SECS')"; exit 2 ;; esac
LOCK_REL="backends/cachyos/compat-libs.lock"

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-calamares.XXXXXX")" || exit 2
RO=""
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() {
  if [ -n "$RO" ] && [ -d "$RO" ]; then umount "$RO" 2>/dev/null || umount -l "$RO" 2>/dev/null || true; rmdir "$RO" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap cleanup EXIT
: > "$T/missing"; : > "$T/undef"; : > "$T/other"; : > "$T/ldd.all"; : > "$T/fails"; : > "$T/warns"
fail() { printf '%s\n' "$*" >> "$T/fails"; }
warn() { printf '%s\n' "$*" >> "$T/warns"; ci_warn "$*"; }

# --- the things that need a Linux root ------------------------------------------------------------------------------------------
# Everything that runs a program of the image runs in a READ-ONLY bind mount of it: the gate must not leave a cache, a log or (under
# Rosetta, which keeps a translation cache in /root/.cache/rosetta) anything else in the tree that is about to be squashed.
gate_view_open() { # ROOT: sets RO, or returns 1 with the reason in $T/view.err
  RO="$(mktemp -d "${TMPDIR:-/tmp}/gate-ro.XXXXXX")" || { echo "no temporary directory" > "$T/view.err"; RO=""; return 1; }
  if ! mount --bind "$1" "$RO" 2>"$T/view.err" || ! mount -o remount,bind,ro "$RO" 2>>"$T/view.err"; then
    umount "$RO" 2>/dev/null; rmdir "$RO" 2>/dev/null; RO=""
    return 1
  fi
}
gate_ldd() { # ROOT PATH
  if [ -n "${CI_OS_GATE_EXEC:-}" ]; then "$CI_OS_GATE_EXEC" ldd "$1" "$2" 2>&1; return; fi
  chroot "$RO" /usr/bin/ldd -r "$2" 2>&1
}
gate_smoke() { # ROOT SECONDS OUTFILE: exit status of `timeout` (124 = still running when the time was up), 97 = could not run
  local root="$1" secs="$2" out="$3" rc=0
  if [ -n "${CI_OS_GATE_EXEC:-}" ]; then "$CI_OS_GATE_EXEC" smoke "$root" "$secs" "$out"; return; fi
  [ -x "$root/usr/bin/timeout" ] && [ -x "$root/usr/bin/bash" ] || { echo "the image has no usr/bin/timeout or usr/bin/bash: cannot run the smoke start" > "$out"; return 97; }
  command -v arch-chroot >/dev/null 2>&1 || { echo "arch-chroot (arch-install-scripts) is not installed in the builder" > "$out"; return 97; }
  # arch-chroot puts tmpfs on /tmp, /run and /dev and mounts proc and sys inside its own mount namespace, which a read-only root
  # does not prevent; HOME and the XDG directories point into the /tmp tmpfs.
  # shellcheck disable=SC2016  # $0 is the first argument of bash -c: the number of seconds
  arch-chroot "$RO" /usr/bin/env -i PATH=/usr/bin LANG=C.UTF-8 QT_QPA_PLATFORM=offscreen \
      HOME=/tmp/gate-home XDG_RUNTIME_DIR=/tmp/gate-xdg XDG_CACHE_HOME=/tmp/gate-cache XDG_CONFIG_HOME=/tmp/gate-config \
      /usr/bin/bash -c 'mkdir -p /tmp/gate-home /tmp/gate-cache /tmp/gate-config && mkdir -m 700 /tmp/gate-xdg && exec /usr/bin/timeout -k 5 "$0" /usr/bin/calamares -D6' "$secs" \
      > "$out" 2>&1 || rc=$?
  return "$rc"
}

# --- 1. the package and its ELF files ---------------------------------------------------------------------------------------------
PKGDB=""
for d in "$ROOT"/var/lib/pacman/local/"$PKG"-[0-9]*; do [ -d "$d" ] && PKGDB="$d"; done
if [ -z "$PKGDB" ] || [ ! -f "$PKGDB/files" ]; then
  fail "$PKG is not installed in this image (no var/lib/pacman/local/$PKG-*/files): the live image would have no installer. Check packages_desktop.x86_64 and overlay/packages.remove."
  ELFS=""
else
  # %FILES% section, files only, no directories
  sed -n '/^%FILES%$/,/^$/p' "$PKGDB/files" | sed -e '1d' -e '/^$/d' -e '/\/$/d' | LC_ALL=C sort > "$T/files"
  : > "$T/elfs"
  while IFS= read -r p; do
    [ -f "$ROOT/$p" ] && [ ! -L "$ROOT/$p" ] || continue
    [ "$(head -c4 "$ROOT/$p" 2>/dev/null | od -An -c | tr -d ' \n')" = '177ELF' ] || continue
    printf '%s\n' "$p" >> "$T/elfs"
  done < "$T/files"
  grep -qx 'usr/bin/calamares' "$T/elfs" || fail "usr/bin/calamares is not an ELF file of $PKG in this image: the package layout changed"
  ELFS="$(cat "$T/elfs")"
fi
NELF="$(printf '%s\n' "$ELFS" | awk 'NF { n++ } END { print n + 0 }')"
ci_log "$PKG: $NELF ELF file(s) to check in $ROOT"

# --- 2. ldd -r ----------------------------------------------------------------------------------------------------------------------
# scan_ldd ELF OUTPUT: record what is wrong in OUTPUT, the text `ldd -r` printed for ELF. Records are tab separated files in $T.
TAB="$(printf '\t')"
scan_ldd() {
  local elf="$1" out="$2" l
  printf '%s\n' "$out" >> "$T/ldd.all"
  printf '%s\n' "$out" | sed -n -E 's/^[[:space:]]*([^[:space:]]+) => not found.*$/\1/p' | while IFS= read -r l; do printf '%s\t%s\n' "$l" "/$elf" >> "$T/missing"; done
  printf '%s\n' "$out" | sed -n -E 's/^.*undefined symbol: ([^[:space:]]+)[[:space:]]*(\(([^)]*)\))?.*$/\1'"$TAB"'\3/p' | while IFS= read -r l; do printf '%s\t%s\n' "$l" "/$elf" >> "$T/undef"; done
  printf '%s\n' "$out" | grep -E "version .* not found|symbol lookup error|cannot open shared object|error while loading shared" | grep -v '=> not found' | while IFS= read -r l; do printf '%s\t%s\n' "$l" "/$elf" >> "$T/other"; done
  return 0
}
if [ -z "${CI_OS_GATE_EXEC:-}" ] && [ -n "$ELFS" ]; then
  gate_view_open "$ROOT" || { fail "cannot make a read-only view of $ROOT (mount --bind): the gate does not run programs of a writable image. $(tr '\n' ' ' < "$T/view.err")"; ELFS=""; }
fi
while IFS= read -r p; do
  [ -n "$p" ] || continue
  out="$(gate_ldd "$ROOT" "/$p")" || true
  scan_ldd "$p" "$out"
  if [ "$p" = usr/bin/calamares ]; then printf '%s\n' "$out" > "$T/ldd.calamares"; fi
done < <(printf '%s\n' "$ELFS")

# --- 3. one library, two versions, one process --------------------------------------------------------------------------------------
# From the libraries that /usr/bin/calamares loads: "libboost_graph.so.1.91.0" and "libboost_graph.so.1.92.0" share the stem
# "libboost_graph.so" and differ in the version.
if [ -s "$T/ldd.calamares" ]; then
  sed -n -E 's/^[[:space:]]*(lib[A-Za-z0-9_+.-]*\.so)\.([0-9][0-9.]*) => .*$/\1 \2/p' "$T/ldd.calamares" | LC_ALL=C sort -u \
    | awk '{ c[$1]++; v[$1] = (v[$1] ? v[$1] "," : "") $2 } END { for (k in c) if (c[k] > 1) print k, v[k] }' | LC_ALL=C sort > "$T/mixed"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    fail "the process of /usr/bin/calamares would load ${l%% *} in two versions (${l#* }): both define the same symbols, the first one wins and the second is half used"
  done < "$T/mixed"
fi

# --- reports of 2 -------------------------------------------------------------------------------------------------------------------
if [ -s "$T/missing" ]; then
  cut -f1 "$T/missing" | LC_ALL=C sort -u | while IFS= read -r lib; do
    users="$(awk -F'\t' -v l="$lib" '$1 == l { print $2 }' "$T/missing" | LC_ALL=C sort -u | head -n 3 | tr '\n' ' ')"
    n="$(awk -F'\t' -v l="$lib" '$1 == l' "$T/missing" | wc -l | tr -d ' ')"
    hint=""
    if [ -f "$LOCK" ] && compat_lock_basenames "$LOCK" | grep -qxF "$lib"; then
      hint=" -- $lib IS listed in $LOCK_REL, so the compat step did not run (CI_OS_COMPAT_LIBS=off?) or its file was taken out of the image"
    fi
    printf '%s\n' "missing library $lib: needed by ${users}($n ELF file(s)) and not in this image$hint" >> "$T/fails"
  done
fi
if [ -s "$T/undef" ]; then
  # `ldd -r` prints one line per unresolved symbol and per object that loads it (a library that is missing leaves hundreds). One
  # verdict line: how many symbols, in which files, the first few by their C++ names.
  nsym="$(cut -f1 "$T/undef" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  files="$(awk -F'\t' '{ print ($2 != "" ? $2 : $3) }' "$T/undef" | LC_ALL=C sort -u | head -n 4 | tr '\n' ' ')"
  first="$(cut -f1 "$T/undef" | LC_ALL=C sort -u | head -n 3)"
  if command -v c++filt >/dev/null 2>&1; then first="$(printf '%s\n' "$first" | c++filt)"; fi
  first="$(printf '%s' "$first" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
  hint="a library of another generation than the one the installer was built against"
  [ ! -s "$T/missing" ] || hint="most likely a consequence of the missing library above"
  printf '%s\n' "$nsym undefined symbol(s), in ${files}(first: $first): $hint" >> "$T/fails"
fi
if [ -s "$T/other" ]; then
  LC_ALL=C sort -u "$T/other" | while IFS="$TAB" read -r line elf; do
    printf '%s\n' "$elf: $line" >> "$T/fails"
  done
fi

# --- 4. the offscreen start ----------------------------------------------------------------------------------------------------------
if [ -n "$ELFS" ] && grep -qx 'usr/bin/calamares' "$T/elfs" 2>/dev/null; then
  # Also when the static check failed: it costs a second then, and it is the second, independent witness (the F2 start died at
  # once with "symbol lookup error"; the message of a failing build should say what a click would have said).
  ci_log "offscreen start of /usr/bin/calamares ($SECS s, read-only view of the image)"
  gate_smoke "$ROOT" "$SECS" "$T/smoke.out"; rc=$?
  linker_re='symbol lookup error|undefined symbol|error while loading shared libraries|cannot open shared object'
  if grep -qE "$linker_re" "$T/smoke.out" 2>/dev/null; then
    fail "the offscreen start of /usr/bin/calamares printed a dynamic-linker error (exit status $rc): $(grep -E "$linker_re" "$T/smoke.out" | head -n 1)"
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    ci_log "    still running after $SECS s: the installer starts"
  elif [ "$rc" -eq 0 ]; then
    ci_log "    exited 0 within $SECS s"
  elif [ "$rc" -eq 97 ]; then
    fail "the offscreen start could not be run: $(head -n 3 "$T/smoke.out" | tr '\n' ' ')"
  else
    fail "the offscreen start of /usr/bin/calamares exited with status $rc within $SECS s (127 = a library or the program is missing, 134 = abort, 139 = segmentation fault). Last lines: $(tail -n 8 "$T/smoke.out" 2>/dev/null | tr '\n' '|')"
  fi
fi

# --- 5. the compat libraries ----------------------------------------------------------------------------------------------------------
if [ -f "$LOCK" ]; then
  if ! problems="$(compat_lock_problems "$LOCK")"; then
    fail "$LOCK_REL is not a valid compat lock: $(printf '%s' "$problems" | tr '\n' ';')"
  else
    while read -r _ lpath lsha; do
      [ -n "$lpath" ] || continue
      base="${lpath##*/}"
      if [ -f "$ROOT/$lpath" ]; then
        have="$(ci_sha256_file "$ROOT/$lpath")"
        [ "$have" = "$lsha" ] || fail "/$lpath in the image has sha256 $have, $LOCK_REL pins $lsha: something replaced the staged file"
        if [ -n "$ELFS" ] && ! grep -qF "$base" "$T/ldd.all"; then
          if [ "${CI_OS_GATE_STALE:-warn}" = error ]; then fail "/$lpath is not needed by $PKG any more: remove it from $LOCK_REL (CI_OS_GATE_STALE=error)"
          else warn "/$lpath is not needed by $PKG any more: [cachyos] has probably rebuilt the installer. Remove the records of $LOCK_REL (replace them by one line: retired YYYY-MM-DD) and the matching lines of overlay/package-owned-ok.txt."; fi
        fi
      else
        ci_log "compat library /$lpath is not in the image (the compat step was off, or the installer does not need it)"
      fi
    done < <(compat_lock_libs "$LOCK")
  fi
fi

# --- verdict --------------------------------------------------------------------------------------------------------------------------
if [ -s "$T/fails" ]; then
  ci_err "THE CALAMARES GATE FAILED: the installer would not start from this image, so mkarchiso was stopped BEFORE it squashed the image."
  awk '!seen[$0]++' "$T/fails" | sed 's/^/    - /' >&2
  {
    echo "  What this is: the [cachyos] repository ships $PKG built against a library generation that [core] or [extra] no longer ship (risk R1, rolling-release drift)."
    echo "  Fix: add the older library, from the Arch Linux Archive, to $LOCK_REL (its header says how: stage-compat-libs.sh propose PKG VERSION SONAME), or wait for [cachyos] to rebuild the installer and build again."
    echo "  Background: docs/architecture/cachyos-backend.md, 'Rolling-release drift incident 2026-10-18 (F1, F2)'."
  } >&2
  exit 1
fi
ci_log "passed: $PKG starts in this image ($NELF ELF file(s) resolve every library and symbol; offscreen start ran $SECS s)"
exit 0
