#!/usr/bin/env bash
#=============================================================================
# Gate 14 of docs/guides/release-checklist.md, as a command: is what is served at the public URL what was built?
#
#   verify-published.sh --base-url https://dl.ci.computer [--version 1.0] [--edition ubuntu|plasma] [--prefix os] [--arch amd64|arm64|x86_64]
#                       [--full] [--pubkey FILE]
#
# --edition (default ubuntu) says which release is checked: the default prefix is os for ubuntu and os-plasma for plasma, and the manifest must say
# the same edition (its "edition" key; absent means ubuntu), or the check fails. --arch is amd64 or arm64 for an Ubuntu manifest and x86_64 for a
# Plasma one. The manifest is a served file, so every key of its "images" is held to that table before it is used, with or without --arch: a key
# outside it fails the check, and so does a manifest that lists no image of its edition.
#
# Reads <base>/<prefix>/latest.json (or the version you name), then <base>/<prefix>/<version>/manifest.json, and for every image (or the one --arch)
#   - HEAD: the served size equals the manifest's size;
#   - with --full: downloads the image and checks its sha256 against the manifest (5.6 GB each: this is the check that matters, run it from a
#     machine that is not the builder, ideally the one the user will use);
# then fetches SHA256SUMS, checks that it lists exactly the manifest's hashes, and, with --pubkey, that SHA256SUMS.asc verifies against that public
# key in a throw-away keyring (the key is the one published by the release key's holder, not whatever is in your keyring).
# It builds every URL itself from --base-url, the prefix, the version, the architecture and a file name that matches ^[A-Za-z0-9._-]+$; a URL inside
# the manifest is only compared with that, never followed. https only (http is accepted for localhost, for the test of this script).
#
# Prints one line per check, then a line to paste into the release record. Exit status: 0 every check passed, 1 a check failed, 2 a usage problem.
#
# Needs bash 3.2+, curl, python3, shasum or sha256sum (gpg for --pubkey).      © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

die() { echo "verify-published: $*" >&2; exit 2; }
BASE="" VERSION="" EDITION="ubuntu" ARCH="" FULL=0 PUBKEY=""
PREFIX="" PREFIX_GIVEN=0      # only --prefix or the edition sets the prefix: a PREFIX exported in the environment is ignored
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) [ $# -ge 2 ] || die "$1 needs a value"; BASE="$2"; shift 2 ;;
    --version) [ $# -ge 2 ] || die "$1 needs a value"; VERSION="$2"; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "$1 needs a value"; PREFIX="$2"; PREFIX_GIVEN=1; shift 2 ;;
    --edition) [ $# -ge 2 ] || die "$1 needs a value"; EDITION="$2"; shift 2 ;;
    --arch) [ $# -ge 2 ] || die "$1 needs a value"; ARCH="$2"; shift 2 ;;
    --pubkey) [ $# -ge 2 ] || die "$1 needs a value"; PUBKEY="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    -h|--help) sed -n '2,/^# Needs /p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
BASE="${BASE%/}"
case "$BASE" in
  https://*) ;;
  http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*) ;;
  *) die "--base-url must be an https URL" ;;
esac
case "$EDITION" in ubuntu|plasma) ;; *) die "--edition must be ubuntu or plasma" ;; esac
[ "$PREFIX_GIVEN" = 1 ] || { [ "$EDITION" = plasma ] && PREFIX="os-plasma" || PREFIX="os"; }
echo "$PREFIX" | grep -q -E '^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*$' || die "--prefix is not a plain key prefix"
[ -z "$ARCH" ] || case "$ARCH" in amd64|arm64|x86_64) ;; *) die "--arch must be amd64 or arm64 (ubuntu) or x86_64 (plasma)" ;; esac
[ -z "$VERSION" ] || echo "$VERSION" | grep -q -E '^[0-9]+(\.[0-9]+)*([-.][0-9A-Za-z]+)*$' || die "--version is not a version"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-published.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
ok() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
get() { curl -fsSL --retry 2 --max-time "${3:-120}" "$1" -o "$2" 2>/dev/null; }
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1" 2>/dev/null; }
clean() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '?' | cut -c1-60; }      # a value from a served file, made safe to print

if [ -z "$VERSION" ]; then
  get "$BASE/$PREFIX/latest.json" "$WORK/latest.json" 60 || { bad "$BASE/$PREFIX/latest.json does not answer"; echo "verify-published: FAILED"; exit 1; }
  VERSION="$(json "$WORK/latest.json" "d['version']")"
  echo "$VERSION" | grep -q -E '^[0-9]+(\.[0-9]+)*([-.][0-9A-Za-z]+)*$' || { bad "latest.json names no usable version"; exit 1; }
  ok "latest.json names version $VERSION ($(json "$WORK/latest.json" "d.get('channel','?')"))"
fi
MURL="$BASE/$PREFIX/$VERSION/manifest.json"
get "$MURL" "$WORK/manifest.json" 60 || { bad "$MURL does not answer"; echo "verify-published: FAILED"; exit 1; }
[ "$(json "$WORK/manifest.json" "d['product']")" = "companion-os" ] && [ "$(json "$WORK/manifest.json" "d['version']")" = "$VERSION" ] \
  && ok "manifest.json is Companion OS $VERSION" || bad "manifest.json is not Companion OS $VERSION"

# the manifest's own edition decides which architectures are valid; the edition asked for must be the same (absent in the manifest means ubuntu)
MED="$(json "$WORK/manifest.json" "d.get('edition', 'ubuntu')")"
[ "$MED" = "$EDITION" ] && ok "manifest.json is the $EDITION edition" || bad "manifest.json is the '$(clean "${MED:-unknown}")' edition, and this check is for $EDITION (--edition, --prefix)"
case "$MED" in ubuntu) VALID="amd64 arm64" ;; plasma) VALID="x86_64" ;; *) VALID="" ;; esac
is_arch() { local w; for w in $VALID; do [ "$w" = "$1" ] && return 0; done; return 1; }      # exact match against the table of the manifest's edition
[ -z "$ARCH" ] || is_arch "$ARCH" || die "--arch $ARCH is not an architecture of the $(clean "${MED:-unknown}") edition (ubuntu: amd64 or arm64; plasma: x86_64)"
# Every key of "images" is held to that table, with or without --arch, before it is used for anything: the keys come from a served file, they end up in
# the expressions that read the manifest below, and only a word of the table may. A key outside the table is a failure (and is only ever printed cleaned),
# and so is a manifest that lists no image of its edition. With --arch, that one image is the one checked.
ARCHES=""
while IFS= read -r a; do
  [ -n "$a" ] || continue
  if is_arch "$a"; then
    [ -z "$ARCH" ] || [ "$a" = "$ARCH" ] || continue
    ARCHES="$ARCHES $a"
  else
    bad "manifest.json lists an image for '$(clean "$a")', which is not an architecture of the $(clean "${MED:-unknown}") edition (ubuntu: amd64 or arm64; plasma: x86_64)"
  fi
done <<<"$(json "$WORK/manifest.json" "'\n'.join(sorted(d['images']))")"
[ -z "$ARCH" ] || ARCHES="$ARCH"                                    # an image the manifest does not list is found by the loop below
[ -n "$ARCHES" ] || bad "manifest.json lists no image of the $(clean "${MED:-unknown}") edition"
for a in $ARCHES; do
  name="$(json "$WORK/manifest.json" "d['images']['$a']['iso']['name']")"
  size="$(json "$WORK/manifest.json" "d['images']['$a']['iso']['size']")"
  want="$(json "$WORK/manifest.json" "d['images']['$a']['iso']['sha256']")"
  murl="$(json "$WORK/manifest.json" "d['images']['$a']['iso']['url']")"
  if ! echo "$name" | grep -q -E '^[A-Za-z0-9._-]+$' || ! echo "$want" | grep -q -E '^[0-9a-f]{64}$' || ! echo "$size" | grep -q -E '^[0-9]+$'; then
    bad "$a: the manifest's entry is malformed"; continue
  fi
  url="$BASE/$PREFIX/$VERSION/$a/$name"
  case "$murl" in */"$PREFIX/$VERSION/$a/$name") ok "$a: the manifest's URL ends in $PREFIX/$VERSION/$a/$name" ;; *) bad "$a: the manifest's URL ($murl) is not this release's path" ;; esac
  served="$(curl -fsSIL --retry 2 --max-time 60 "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:" {n=$2} END {print n}')"
  if [ "$served" = "$size" ]; then ok "$a: $name is served at $size bytes"; else bad "$a: $name is served at '${served:-nothing}' bytes, the manifest says $size"; fi
  if [ "$FULL" = 1 ]; then
    if get "$url" "$WORK/$a.iso" 7200; then
      got="$(sha_of "$WORK/$a.iso")"
      if [ "$got" = "$want" ]; then ok "$a: downloaded and sha256 $got matches"; else bad "$a: the downloaded file has sha256 $got, the manifest says $want"; fi
      rm -f "$WORK/$a.iso"
    else
      bad "$a: the download from $url failed"
    fi
  fi
done

if get "$BASE/$PREFIX/$VERSION/SHA256SUMS" "$WORK/SHA256SUMS" 60; then
  for a in $ARCHES; do
    name="$(json "$WORK/manifest.json" "d['images']['$a']['iso']['name']")"
    want="$(json "$WORK/manifest.json" "d['images']['$a']['iso']['sha256']")"
    if grep -q -E "^$want [ *]$name\$" "$WORK/SHA256SUMS"; then ok "$a: SHA256SUMS lists the manifest's hash"; else bad "$a: SHA256SUMS does not list the manifest's hash for $name"; fi
  done
  if [ -n "$PUBKEY" ]; then
    command -v gpg >/dev/null 2>&1 || die "--pubkey needs gpg"
    [ -f "$PUBKEY" ] || die "--pubkey $PUBKEY does not exist"
    if get "$BASE/$PREFIX/$VERSION/SHA256SUMS.asc" "$WORK/SHA256SUMS.asc" 60; then
      export GNUPGHOME="$WORK/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
      gpg --batch --quiet --import "$PUBKEY" 2>/dev/null
      if gpg --batch --verify "$WORK/SHA256SUMS.asc" "$WORK/SHA256SUMS" >/dev/null 2>&1; then ok "SHA256SUMS.asc verifies against $(basename "$PUBKEY")"; else bad "SHA256SUMS.asc does not verify against $(basename "$PUBKEY")"; fi
    else
      bad "SHA256SUMS.asc is not served"
    fi
  else
    echo "note  signature not checked (give --pubkey with the release key's public key)"
  fi
else
  bad "SHA256SUMS is not served at $BASE/$PREFIX/$VERSION/SHA256SUMS"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "verify-published: $VERSION at $BASE/$PREFIX: all checks passed$([ "$FULL" = 1 ] || echo ' (sizes only: run with --full for the bytes)')"
  echo "release record: re-verified from $(hostname -s 2>/dev/null || echo this machine) on $(date -u +%Y-%m-%d), $([ "$FULL" = 1 ] && echo 'sha256 of the downloaded bytes' || echo 'served sizes')"
  exit 0
fi
echo "verify-published: FAILED ($FAILS)"
exit 1
