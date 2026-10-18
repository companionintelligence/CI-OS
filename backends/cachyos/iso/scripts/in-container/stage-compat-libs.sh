#!/usr/bin/env bash
# stage-compat-libs.sh: put the shared libraries that backends/cachyos/compat-libs.lock names into the STAGING layer of the image, so
# that apply-overlay.sh merges them like every other build-time file. Risk R1 (rolling-release drift), incident 2026-10-18: the
# [cachyos] repository still ships cachyos-calamares-next built against boost 1.91, while [extra] had moved to 1.92, so the installer
# on the ISO did not start. The libraries of the older generation are fetched from the Arch Linux Archive, the one external source this
# build accepts besides its own repositories, and installed NEXT TO the current ones (different file names: libboost_*.so.1.91.0 and
# libboost_*.so.1.92.0 never collide). Nothing is downgraded, no package is replaced.
#
#   stage-compat-libs.sh [stage]            fetch, verify, extract the lock's libraries into $CI_OS_STAGING_DIR/airootfs/usr/lib
#   stage-compat-libs.sh propose PKG VERSION SONAME...
#                                           maintainer helper: fetch PKG-VERSION from the archive, verify its signature and print the
#                                           lock records for SONAME... and every library of the same package they need (readelf)
#   stage-compat-libs.sh check              only validate the lock file (no network)
#
# What is checked, in this order, and every failure stops the build with the file name and the two hashes:
#   1. the lock itself (lib/compat-lock.sh: URL must be the canonical archive path, members versioned shared objects below usr/lib)
#   2. sha256 of the downloaded package equals the pin in the lock
#   3. the package signature, with pacman's own keyring (pacman-key --verify): a missing .sig is a failure, unlike `pacman -U`, whose
#      default LocalFileSigLevel lets an unsigned local file through
#   4. every member is a regular file whose sha256 equals its pin; it is written 0644 (a shared object needs no execute bit, so the
#      engine's guard (c) and file_permissions are not involved)
#
# Environment: CI_OS_STAGING_DIR (required to stage), CI_OS_COMPAT_LOCK (default backends/cachyos/compat-libs.lock),
#   CI_OS_COMPAT_LIBS=on|off (off: stage nothing and say so loudly; this is the switch the mutation test uses, the gate then has to
#   fail), CI_OS_COMPAT_REVIEW=warn|error (what a passed review-by date does; default warn), CI_OS_COMPAT_REPORT_FILE (KEY=VALUE
#   lines for the build record), CI_OS_COMPAT_TODAY (test hook), CI_OS_COMPAT_WORK (download directory).
# Test hooks: the three functions compat_download, compat_verify_signature and compat_extract are the only ones that touch the
# network, the keyring or an archive; tests/compat-libs.sh sources this file and replaces them.
set -euo pipefail
export LC_ALL=C

export CI_PROG=stage-compat-libs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/compat-lock.sh
. "$SCRIPT_DIR/../lib/compat-lock.sh"

# --- the three impure steps ---------------------------------------------------------------------------------------------------
# compat_download URL DEST: https only, three tries from curl itself.
compat_download() {
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 3 -o "$2" "$1"
}
# compat_verify_signature PKGFILE: the detached signature PKGFILE.sig is valid and made by a key the pacman keyring trusts.
compat_verify_signature() {
  command -v pacman-key >/dev/null 2>&1 || { ci_err "pacman-key is not installed: cannot verify the signature of $1"; return 1; }
  [ -s "$1.sig" ] || { ci_err "no signature next to $1"; return 1; }
  pacman-key --verify "$1.sig"
}
# compat_extract PKGFILE MEMBER DEST: write one member of the package to DEST. The member must be a regular file (a symlink or a
# directory of that name is refused), so what lands in the image is exactly the bytes the lock pins.
compat_extract() {
  local pkg="$1" member="$2" dest="$3" kind
  kind="$(bsdtar -tvf "$pkg" "$member" 2>/dev/null | head -n 1 | cut -c1)"
  [ "$kind" = "-" ] || { ci_err "$member is not a regular file in $(basename "$pkg") (type '${kind:-missing}')"; return 1; }
  bsdtar -xOf "$pkg" "$member" > "$dest"
}

# --- staging --------------------------------------------------------------------------------------------------------------------
compat_report() { # KEY VALUE: collected, written at the end
  COMPAT_REPORT_LINES="${COMPAT_REPORT_LINES:-}$1=$2
"
}

compat_stage() {
  local lock="${CI_OS_COMPAT_LOCK:-$CACHYOS_DIR/compat-libs.lock}"
  local staging="${CI_OS_STAGING_DIR:-}" work own=0 rc=0 problems
  COMPAT_REPORT_LINES=""
  [ -n "$staging" ] || { ci_err "CI_OS_STAGING_DIR is not set"; return 2; }
  [ -d "$staging" ] || { ci_err "CI_OS_STAGING_DIR is not a directory: $staging"; return 2; }

  if [ "${CI_OS_COMPAT_LIBS:-on}" = off ]; then
    ci_warn "CI_OS_COMPAT_LIBS=off: the compatibility libraries of $lock are NOT staged. The Calamares gate is expected to fail on an image that needs them."
    compat_report COMPAT_LIBS off
    compat_write_report
    return 0
  fi
  [ "${CI_OS_COMPAT_LIBS:-on}" = on ] || { ci_err "CI_OS_COMPAT_LIBS must be on or off (got '${CI_OS_COMPAT_LIBS}')"; return 2; }

  problems="$(compat_lock_problems "$lock")" || { ci_err "$lock is not a valid compat lock:"; printf '%s\n' "$problems" | sed 's/^/    /' >&2; return 1; }

  work="${CI_OS_COMPAT_WORK:-}"
  if [ -z "$work" ]; then work="$(mktemp -d "${TMPDIR:-/tmp}/compat-libs.XXXXXX")" || return 1; own=1; else mkdir -p "$work" || return 1; fi
  compat_stage_into "$lock" "$work/stage" "$work" || rc=$?
  # Atomic: everything is verified into $work/stage first; the real staging tree only receives the result of a run that passed.
  if [ "$rc" -eq 0 ] && [ -d "$work/stage" ]; then cp -R "$work/stage/." "$staging/" || { ci_err "cannot copy the verified libraries into $staging"; rc=1; }; fi
  [ "$own" -eq 0 ] || rm -rf "$work"
  [ "$rc" -eq 0 ] || return "$rc"
  ci_log "staged ${COMPAT_NLIB:-0} compatibility librar$([ "${COMPAT_NLIB:-0}" = 1 ] && echo y || echo ies) into $staging/airootfs"
  compat_write_report
}

# compat_stage_into LOCK STAGING WORK: the work proper. Called under `||`, where `set -e` does not apply, so every step is checked.
compat_stage_into() {
  local lock="$1" staging="$2" work="$3" name ver arch url want file have lib_pkg path sha got dest nlib=0 pkgs="" by
  # Every command inside the two read loops gets </dev/null: a program that read the loop's stdin would eat the next record.
  by="$(compat_lock_retired "$lock")"
  if [ -n "$by" ]; then ci_log "$(basename "$lock") is retired ($by): no compatibility library is needed, none is staged"; by=""; fi
  while read -r name ver arch url want; do
    [ -n "$name" ] || continue
    file="$work/$(basename "$url")"
    ci_log "fetching $name $ver ($arch) from the Arch Linux Archive"
    compat_download "$url" "$file" </dev/null || { ci_err "download failed: $url"; return 1; }
    compat_download "$url.sig" "$file.sig" </dev/null || { ci_err "download failed: $url.sig"; return 1; }
    have="$(ci_sha256_file "$file")" || return 1
    if [ "$have" != "$want" ]; then
      ci_err "$name $ver: sha256 of the archive file is $have, $(basename "$lock") pins $want. The archive file changed or the lock is wrong; nothing was staged."
      return 1
    fi
    ci_log "    sha256 matches the pin ($have)"
    compat_verify_signature "$file" </dev/null || { ci_err "$name $ver: the package signature could not be verified; nothing was staged."; return 1; }
    ci_log "    signature verified with the pacman keyring"
    while read -r lib_pkg path sha; do
      [ -n "$lib_pkg" ] || continue
      got="$work/member.$$"
      compat_extract "$file" "$path" "$got" </dev/null || { ci_err "cannot extract $path from $(basename "$file")"; rm -f "$got"; return 1; }
      have="$(ci_sha256_file "$got")" || return 1
      if [ "$have" != "$sha" ]; then
        ci_err "$path: sha256 is $have, $(basename "$lock") pins $sha"
        rm -f "$got"; return 1
      fi
      dest="$staging/airootfs/$path"
      if [ -e "$dest" ] || [ -L "$dest" ]; then ci_err "$path is listed twice in the lock"; rm -f "$got"; return 1; fi
      if [ -e "${CI_OS_STAGING_DIR:-/nonexistent}/airootfs/$path" ] || [ -L "${CI_OS_STAGING_DIR:-/nonexistent}/airootfs/$path" ]; then
        ci_err "/$path already exists in the staging tree: two producers for one path"; rm -f "$got"; return 1
      fi
      if ! { mkdir -p "$(dirname "$dest")" && cp "$got" "$dest" && chmod 0644 "$dest"; }; then ci_err "cannot write $dest"; rm -f "$got"; return 1; fi
      rm -f "$got"
      nlib=$((nlib + 1))
      ci_log "    verified /$path (sha256 equals the pin)"
    done < <(compat_lock_libs "$lock" "$name")
    pkgs="${pkgs:+$pkgs,}$name-$ver-$arch"
  done < <(compat_lock_packages "$lock")

  compat_report COMPAT_LIBS "$nlib"
  compat_report COMPAT_PACKAGES "$pkgs"
  compat_report COMPAT_LOCK_SHA256 "$(ci_sha256_file "$lock")"
  by="$(compat_lock_review_by "$lock")"
  compat_report COMPAT_REVIEW_BY "$by"
  if compat_review_overdue "$lock" >/dev/null; then
    compat_report COMPAT_REVIEW_OVERDUE 1
    if [ "${CI_OS_COMPAT_REVIEW:-warn}" = error ]; then
      ci_err "$(basename "$lock") was due for review on $by (CI_OS_COMPAT_REVIEW=error). Check whether the installer package still needs these libraries, then refresh or remove the pins."
      return 1
    fi
    ci_warn "$(basename "$lock") was due for review on $by. Check whether [cachyos] has rebuilt cachyos-calamares-next against the current boost; if so, remove the compatibility libraries (docs/architecture/cachyos-backend.md, 'Rolling-release drift incident 2026-10-18')."
  else
    compat_report COMPAT_REVIEW_OVERDUE 0
  fi
  COMPAT_NLIB="$nlib"
  ci_log "$nlib compatibility librar$([ "$nlib" = 1 ] && echo y || echo ies) verified${by:+ (review by $by)}"
}

compat_write_report() {
  [ -z "${CI_OS_COMPAT_REPORT_FILE:-}" ] || printf '%s' "$COMPAT_REPORT_LINES" > "$CI_OS_COMPAT_REPORT_FILE"
  return 0
}

# --- the maintainer helper -----------------------------------------------------------------------------------------------------
# compat_propose PKG VERSION SONAME...: prints the lock records. The closure is every usr/lib/lib*.so.N file of the same package that
# a listed library NEEDs (readelf -d), repeated until nothing new appears.
compat_propose() {
  local work rc=0
  [ "$#" -ge 3 ] || { ci_err "usage: propose PKG VERSION SONAME..."; return 2; }
  command -v readelf >/dev/null 2>&1 || { ci_err "readelf (binutils) is needed to compute the dependency closure"; return 2; }
  work="$(mktemp -d "${TMPDIR:-/tmp}/compat-propose.XXXXXX")" || return 1
  compat_propose_into "$work" "$@" || rc=$?
  rm -rf "$work"
  return "$rc"
}
compat_propose_into() {
  local work="$1" name="$2" ver="$3" arch=x86_64 url file have todo seen cur n dep sha
  shift 3
  url="${CI_COMPAT_ARCHIVE_PREFIX}$(printf '%s' "$name" | cut -c1)/$name/$name-$ver-$arch.pkg.tar.zst"
  file="$work/$(basename "$url")"
  ci_log "fetching $url" >&2
  if ! { compat_download "$url" "$file" && compat_download "$url.sig" "$file.sig"; }; then ci_err "download failed"; return 1; fi
  compat_verify_signature "$file" >&2 || { ci_err "signature not verified: do not pin this file"; return 1; }
  have="$(ci_sha256_file "$file")" || return 1
  if ! { mkdir -p "$work/x" && bsdtar -xf "$file" -C "$work/x"; }; then ci_err "cannot unpack $file"; return 1; fi
  todo="$*"; seen=""
  while [ -n "$todo" ]; do
    # shellcheck disable=SC2086  # a list of file names without blanks
    set -- $todo; cur="$1"; shift; todo="$*"
    case " $seen " in *" $cur "*) continue ;; esac
    [ -f "$work/x/usr/lib/$cur" ] && [ ! -L "$work/x/usr/lib/$cur" ] || { ci_err "usr/lib/$cur is not a regular file of $name $ver"; return 1; }
    seen="$seen $cur"
    for dep in $(readelf -d "$work/x/usr/lib/$cur" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
      if [ -f "$work/x/usr/lib/$dep" ] && [ ! -L "$work/x/usr/lib/$dep" ]; then todo="$todo $dep"; fi
    done
  done
  printf 'package %s %s %s %s %s\n' "$name" "$ver" "$arch" "$url" "$have"
  for n in $seen; do
    sha="$(ci_sha256_file "$work/x/usr/lib/$n")" || return 1
    printf 'lib     %s usr/lib/%s %s\n' "$name" "$n" "$sha"
  done
}

main() {
  case "${1:-stage}" in
    stage) compat_stage ;;
    check)
      local lock="${CI_OS_COMPAT_LOCK:-$CACHYOS_DIR/compat-libs.lock}" problems
      problems="$(compat_lock_problems "$lock")" || { ci_err "$lock is not a valid compat lock:"; printf '%s\n' "$problems" | sed 's/^/    /' >&2; return 1; }
      ci_log "$lock is valid" ;;
    propose) shift; compat_propose "$@" ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//' ;;
    *) ci_err "unknown command '$1' (stage, propose, check)"; return 2 ;;
  esac
}

# Run only when executed; tests source this file to replace the impure functions above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
