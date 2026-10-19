# shellcheck shell=bash
# Helpers for backends/cachyos/compat-libs.lock. Sourced, never executed (bash 3.2 and BSD userland safe: the tests run on macOS).
#
# The lock names the few shared libraries that the live image must carry SIDE BY SIDE with the ones the repositories ship today,
# because a package of the image (cachyos-calamares-next) was built against the previous generation (incident 2026-10-18, risk R1).
# Format, one record per line, '#' starts a comment, fields separated by blanks:
#
#   review-by YYYY-MM-DD
#   package   NAME VERSION ARCH URL SHA256
#   lib       NAME PATH-IN-PACKAGE SHA256
#   retired   YYYY-MM-DD        instead of all of the above: no compatibility library is needed any more (see below)
#
# A lock with no records at all is NOT valid (a truncated or emptied file must not read as "nothing is needed"). When the repository's
# own packages no longer need the libraries, the lock says so on purpose: its records are replaced by one `retired` line with the
# date. That lock is valid, lists no library, and the build, the gate and verify-iso.sh all accept an image that has none.
#
# The URL is not free text: it must be exactly the Arch Linux Archive path of NAME-VERSION-ARCH.pkg.tar.zst (the only download source
# this build accepts besides its own repositories). A lib is a versioned shared object below usr/lib, nothing else.

CI_COMPAT_ARCHIVE_PREFIX='https://archive.archlinux.org/packages/'

# compat_lock_records FILE: the meaningful lines, comments and blank lines removed, blanks squeezed to one space.
compat_lock_records() {
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g' -e '/^$/d' "$1"
}

# compat_lock_problems FILE: one line per problem on stdout; exit status 1 if there is any. An unknown record kind is a problem
# (fail closed: a typo must not silently drop a pin).
compat_lock_problems() {
  local out
  [ -f "$1" ] || { printf 'the compat lock %s does not exist\n' "$1"; return 1; }
  out="$(compat_lock_records "$1" | awk -v prefix="$CI_COMPAT_ARCHIVE_PREFIX" '
    function bad(m) { print "line " NR ": " m; n++ }
    function hex64(s) { return (length(s) == 64 && s ~ /^[0-9a-f]+$/) }
    $1 == "review-by" {
      nrev++
      if (NF != 2 || $2 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) bad("review-by needs one YYYY-MM-DD date")
      else if (substr($2, 6, 2) + 0 < 1 || substr($2, 6, 2) + 0 > 12 || substr($2, 9, 2) + 0 < 1 || substr($2, 9, 2) + 0 > 31) bad("review-by " $2 " is not a calendar date")
      next
    }
    $1 == "retired" {
      nret++
      if (NF != 2 || $2 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) bad("retired needs one YYYY-MM-DD date")
      else if (substr($2, 6, 2) + 0 < 1 || substr($2, 6, 2) + 0 > 12 || substr($2, 9, 2) + 0 < 1 || substr($2, 9, 2) + 0 > 31) bad("retired " $2 " is not a calendar date")
      next
    }
    $1 == "package" {
      if (NF != 6) { bad("package needs: NAME VERSION ARCH URL SHA256"); next }
      name = $2; ver = $3; arch = $4; url = $5
      if (name !~ /^[a-z0-9@._+][a-z0-9@._+-]*$/) bad("package name \"" name "\" is not a package name")
      if (ver !~ /^[0-9A-Za-z._+:~-]+$/) bad("package version \"" ver "\" is not a package version")
      if (arch != "x86_64" && arch != "any") bad("package arch \"" arch "\" must be x86_64 or any")
      want = prefix substr(name, 1, 1) "/" name "/" name "-" ver "-" arch ".pkg.tar.zst"
      if (url != want) bad("package " name ": the URL must be exactly " want " (got " url ")")
      if (!hex64($6)) bad("package " name ": sha256 must be 64 lowercase hex digits")
      if (name in pkg) bad("package " name " is listed twice")
      pkg[name] = 1; libs[name] = 0
      npkg++
      next
    }
    $1 == "lib" {
      if (NF != 4) { bad("lib needs: PACKAGE-NAME PATH SHA256"); next }
      p = $2; path = $3
      if (!(p in pkg)) bad("lib " path ": package " p " has no package record above it")
      else libs[p]++
      if (path !~ /^usr\/lib\/lib[A-Za-z0-9_+.-]*\.so(\.[0-9]+)+$/) bad("lib path \"" path "\" is not a versioned shared object (usr/lib/libNAME.so.N...)")
      if (!hex64($4)) bad("lib " path ": sha256 must be 64 lowercase hex digits")
      if (path in seen) bad("lib " path " is listed twice")
      seen[path] = 1
      nlib++
      next
    }
    { bad("unknown record \"" $1 "\" (expected review-by, package, lib or retired)") }
    END {
      if (nret > 1) { print "at most one retired record is allowed (found " nret ")"; n++ }
      if (nret >= 1) {
        if (npkg > 0 || nlib > 0 || nrev > 0) { print "a retired lock holds no package, lib or review-by record"; n++ }
        exit (n > 0)
      }
      if (nrev != 1) { print "exactly one review-by record is required (found " nrev + 0 ")"; n++ }
      if (npkg == 0) { print "no package record (a lock that needs no library any more says so with one line: retired YYYY-MM-DD)"; n++ }
      for (p in pkg) if (libs[p] == 0) { print "package " p " has no lib record"; n++ }
      exit (n > 0)
    }')" || { printf '%s\n' "$out"; return 1; }
  [ -z "$out" ] || { printf '%s\n' "$out"; return 1; }
  return 0
}

# compat_lock_packages FILE: "NAME VERSION ARCH URL SHA256" per package.
compat_lock_packages() { compat_lock_records "$1" | awk '$1 == "package" { print $2, $3, $4, $5, $6 }'; }
# compat_lock_libs FILE [PACKAGE]: "PACKAGE PATH SHA256" per lib (of PACKAGE when given).
compat_lock_libs() { compat_lock_records "$1" | awk -v p="${2:-}" '$1 == "lib" && (p == "" || $2 == p) { print $2, $3, $4 }'; }
# compat_lock_retired FILE: the YYYY-MM-DD of the retired record, empty when the lock is not retired.
compat_lock_retired() { compat_lock_records "$1" | awk '$1 == "retired" { print $2; exit }'; }
# compat_lock_review_by FILE: the YYYY-MM-DD of the review-by record.
compat_lock_review_by() { compat_lock_records "$1" | awk '$1 == "review-by" { print $2; exit }'; }
# compat_lock_basenames FILE: the file name of every lib, one per line.
compat_lock_basenames() { compat_lock_libs "$1" | awk '{ n = split($2, a, "/"); print a[n] }'; }

# compat_review_overdue FILE [TODAY]: prints the review date and returns 0 when TODAY (default: today, UTC) is after it.
compat_review_overdue() {
  local by today
  by="$(compat_lock_review_by "$1")"
  today="${2:-${CI_OS_COMPAT_TODAY:-$(date -u +%Y-%m-%d)}}"
  printf '%s\n' "$by"
  [ -n "$by" ] && [ "$today" \> "$by" ]
}
