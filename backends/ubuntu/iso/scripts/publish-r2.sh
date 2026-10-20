#!/usr/bin/env bash
#=============================================================================
# Publish a built Companion OS release to Cloudflare R2: the shared dl-dev / dl-prod buckets, served from dl.ci.computer
#
#   publish-r2.sh --dir output --version 1.0 [--channel dev|production] [--apply] [options]
#
# A DRY RUN UNTIL --apply, like `ci-local`: without it the script checks everything it can (the files, SHA256SUMS, the signature, the manifest)
# and prints what it would upload, with no credentials and no network. With --apply it uploads the images, then the small files, then manifest.json,
# checks every object's size against the file on disk, and only then writes latest.json: the pointer moves last, so a failed upload never leaves
# "latest" naming files that are not there.
#
# WHY NOT `wrangler r2 object put` (what CI-Capture and CI-Hub use for their installers): Cloudflare documents it as limited to 315 MB and one
# object at a time. An image is 5.6 GB. The S3 API takes a multipart upload (parts of 5 MiB to 5 GiB, up to 10,000, objects up to 5 TiB), so this
# uses the AWS CLI against R2's S3 endpoint, with 64 MB parts. Nor GitHub Releases: an asset is limited to 2 GiB.
#
# Layout under the bucket:  <prefix>/<version>/<arch>/companion-os-<version>-<arch>.iso
#                           <prefix>/<version>/{SHA256SUMS,SHA256SUMS.asc,SBOM.txt,manifest.json}      <prefix>/latest.json
# Default prefix "os"; default bucket and public origin by channel: dev is dl-dev at https://dl-dev.ci.computer, production is dl-prod at
# https://dl.ci.computer (the pairs CI-Capture's release workflow also uses, with its own prefix "applet"). A version that already exists is refused unless --overwrite: a published image is not replaced by accident.
#
# Options
#   --dir DIR            the build output: companion-os-<version>-<arch>.iso and SHA256SUMS (required); SHA256SUMS.asc and SBOM.txt are published
#                        when present. --make-checksums writes SHA256SUMS from the images when there is none
#   --version V          1.0, 1.0-rc1 ... (required; must be the version in the image names)
#   --channel C          dev (default) or production. Production REQUIRES a good signature on SHA256SUMS
#   --bucket B           override the bucket        --prefix P   override the prefix (default os)
#   --base-url URL       the public origin (default by channel, see above)
#   --pubkey FILE        verify SHA256SUMS.asc against this public key in a throw-away keyring, instead of the user's keyring
#   --repository R --commit SHA --run-url URL      recorded in manifest.json
#   --check-public       after the upload, fetch manifest.json from the public URL and compare it with the one written (needs the bucket's domain)
#   --apply              really upload       --overwrite   replace a version that exists
#
# Environment (--apply only; never printed, never put on a command line):
#   R2_ACCOUNT_ID (or CLOUDFLARE_ACCOUNT_ID), R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY    an R2 S3 API token's key pair (R2 > Manage API tokens)
#
# Needs bash 3.2+, python3, shasum or sha256sum, and for --apply the AWS CLI (v2) and for --check-public curl. Exit status: 0 done (or a clean dry
# run), 1 the upload failed or did not verify, 2 a refusal or a usage problem before anything was uploaded.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_TOOL="$HERE/release-manifest.py"

die() { echo "publish-r2: $*" >&2; exit 2; }
fail() { echo "publish-r2: $*" >&2; exit 1; }

DIR="" VERSION="" CHANNEL="dev" BUCKET="" PREFIX="os" BASE_URL="" PUBKEY=""
REPOSITORY="" COMMIT="" RUN_URL="" APPLY=0 OVERWRITE=0 CHECK_PUBLIC=0 MAKE_SUMS=0

need_value() { [ $# -ge 2 ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) need_value "$@"; DIR="$2"; shift 2 ;;
    --version) need_value "$@"; VERSION="$2"; shift 2 ;;
    --channel) need_value "$@"; CHANNEL="$2"; shift 2 ;;
    --bucket) need_value "$@"; BUCKET="$2"; shift 2 ;;
    --prefix) need_value "$@"; PREFIX="$2"; shift 2 ;;
    --base-url) need_value "$@"; BASE_URL="$2"; shift 2 ;;
    --pubkey) need_value "$@"; PUBKEY="$2"; shift 2 ;;
    --repository) need_value "$@"; REPOSITORY="$2"; shift 2 ;;
    --commit) need_value "$@"; COMMIT="$2"; shift 2 ;;
    --run-url) need_value "$@"; RUN_URL="$2"; shift 2 ;;
    --check-public) CHECK_PUBLIC=1; shift ;;
    --make-checksums) MAKE_SUMS=1; shift ;;
    --apply) APPLY=1; shift ;;
    --overwrite) OVERWRITE=1; shift ;;
    -h|--help) sed -n '2,/^# © /p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$DIR" ] && [ -d "$DIR" ] || die "--dir must name the build output directory"
[ -n "$VERSION" ] || die "--version is required"
case "$CHANNEL" in dev|production) ;; *) die "--channel must be dev or production" ;; esac
[ -n "$BUCKET" ] || { [ "$CHANNEL" = production ] && BUCKET="dl-prod" || BUCKET="dl-dev"; }
[ -n "$BASE_URL" ] || { [ "$CHANNEL" = production ] && BASE_URL="https://dl.ci.computer" || BASE_URL="https://dl-dev.ci.computer"; }
echo "$BUCKET" | grep -q -E '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' || die "bucket name '$BUCKET' is not a bucket name"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
sha_check() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$@"; else shasum -a 256 -c "$@"; fi; }
sha_make() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# --- 1. the images and SHA256SUMS agree --------------------------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-r2.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
if [ ! -f "$DIR/SHA256SUMS" ]; then
  [ "$MAKE_SUMS" = 1 ] || die "$DIR/SHA256SUMS is missing (the build writes it; --make-checksums writes it from the images)"
  ( cd "$DIR" && sha_make companion-os-*.iso > SHA256SUMS ) || die "could not write SHA256SUMS"
  echo "wrote $DIR/SHA256SUMS"
fi
( cd "$DIR" && sha_check --quiet SHA256SUMS >/dev/null 2>&1 ) || die "SHA256SUMS does not match the files in $DIR (the bytes changed after the checksums were made)"
echo "checksums: every file in SHA256SUMS matches"

# --- 2. the signature ----------------------------------------------------------------------------------------------------------------
if [ -f "$DIR/SHA256SUMS.asc" ]; then
  command -v gpg >/dev/null 2>&1 || die "SHA256SUMS.asc is there but gpg is not installed to check it"
  if [ -n "$PUBKEY" ]; then
    [ -f "$PUBKEY" ] || die "--pubkey $PUBKEY does not exist"
    export GNUPGHOME="$WORK/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    gpg --batch --quiet --import "$PUBKEY" 2>/dev/null || die "could not import $PUBKEY"
  fi
  gpg --batch --verify "$DIR/SHA256SUMS.asc" "$DIR/SHA256SUMS" >/dev/null 2>&1 || die "the signature on SHA256SUMS does not verify"
  echo "signature: SHA256SUMS.asc verifies"
elif [ "$CHANNEL" = production ]; then
  die "production needs SHA256SUMS.asc: a release a user cannot check is not published (sign with the release key; KI-12)"
else
  echo "signature: none (allowed for --channel dev)"
fi

# --- 3. the manifest and the list of uploads -----------------------------------------------------------------------------------------
LIST="$WORK/uploads.tsv"
python3 "$MANIFEST_TOOL" --dir "$DIR" --out-dir "$WORK" --version "$VERSION" --channel "$CHANNEL" --base-url "$BASE_URL" --prefix "$PREFIX" \
  --repository "$REPOSITORY" --commit "$COMMIT" --run-url "$RUN_URL" > "$LIST" || die "could not describe the release (see above)"
COUNT="$(grep -c . "$LIST" | tr -d ' ')"
TAB="$(printf '\t')"

if [ "$APPLY" != 1 ]; then
  echo
  echo "DRY RUN: nothing is uploaded. Would put $COUNT objects in bucket $BUCKET, in this order:"
  while IFS="$TAB" read -r path key ctype; do
    size="$(wc -c < "$path" | tr -d ' ')"
    printf '  %-62s %12s bytes  %s\n' "$key" "$size" "$ctype"
  done < "$LIST"
  echo "  ($BASE_URL/$PREFIX/latest.json moves last, only after every size has been checked)"
  echo "Pass --apply, with R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY set, to upload."
  exit 0
fi

# --- 4. the upload --------------------------------------------------------------------------------------------------------------------
ACCOUNT="${R2_ACCOUNT_ID:-${CLOUDFLARE_ACCOUNT_ID:-}}"
[ -n "$ACCOUNT" ] || die "--apply needs R2_ACCOUNT_ID (or CLOUDFLARE_ACCOUNT_ID)"
[ -n "${R2_ACCESS_KEY_ID:-}" ] || die "--apply needs R2_ACCESS_KEY_ID"
[ -n "${R2_SECRET_ACCESS_KEY:-}" ] || die "--apply needs R2_SECRET_ACCESS_KEY"
echo "$ACCOUNT" | grep -q -E '^[0-9a-f]{32}$|^[A-Za-z0-9_-]{8,}$' || die "R2_ACCOUNT_ID does not look like an account id"
command -v aws >/dev/null 2>&1 || die "the AWS CLI (v2) is required for --apply"

ENDPOINT="https://${ACCOUNT}.r2.cloudflarestorage.com"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION="auto"
# R2 is S3-compatible but not every default of a recent client is: send checksums only where the API requires them.
export AWS_REQUEST_CHECKSUM_CALCULATION="when_required" AWS_RESPONSE_CHECKSUM_VALIDATION="when_required"
unset AWS_SESSION_TOKEN AWS_PROFILE
cat > "$WORK/aws-config" <<'CFG'
[default]
s3 =
  multipart_threshold = 64MB
  multipart_chunksize = 64MB
  max_concurrent_requests = 8
CFG
export AWS_CONFIG_FILE="$WORK/aws-config" AWS_SHARED_CREDENTIALS_FILE=/dev/null

s3api() { aws s3api "$@" --endpoint-url "$ENDPOINT"; }
object_size() { s3api head-object --bucket "$BUCKET" --key "$1" --query ContentLength --output text 2>/dev/null; }

MANIFEST_KEY="$PREFIX/$VERSION/manifest.json"
if object_size "$MANIFEST_KEY" >/dev/null 2>&1; then
  [ "$OVERWRITE" = 1 ] || die "$BUCKET/$MANIFEST_KEY already exists: a published version is not replaced (use --overwrite, or a new version)"
  echo "warning: replacing the existing $PREFIX/$VERSION (--overwrite)"
fi

# everything but the last line (latest.json) first
LAST="$(tail -n 1 "$LIST")"
HEAD_LIST="$WORK/head.tsv"
sed '$d' "$LIST" > "$HEAD_LIST"
echo "uploading $((COUNT - 1)) objects to $BUCKET/$PREFIX/$VERSION (images in 64 MB parts)..."
while IFS="$TAB" read -r path key ctype; do
  echo "  put $key"
  aws s3 cp "$path" "s3://$BUCKET/$key" --endpoint-url "$ENDPOINT" --content-type "$ctype" --no-progress >/dev/null || fail "upload of $key failed"
done < "$HEAD_LIST"

echo "checking sizes..."
while IFS="$TAB" read -r path key ctype; do
  want="$(wc -c < "$path" | tr -d ' ')"
  got="$(object_size "$key" || true)"
  [ "$got" = "$want" ] || fail "$key is $got bytes in the bucket, $want on disk: latest.json is NOT updated"
done < "$HEAD_LIST"
echo "sizes: all $((COUNT - 1)) objects match"

lpath="$(printf '%s' "$LAST" | cut -f1)"; lkey="$(printf '%s' "$LAST" | cut -f2)"; lctype="$(printf '%s' "$LAST" | cut -f3)"
aws s3 cp "$lpath" "s3://$BUCKET/$lkey" --endpoint-url "$ENDPOINT" --content-type "$lctype" --cache-control "no-cache" --no-progress >/dev/null \
  || fail "upload of $lkey failed (the images are in place; latest.json still names the previous version)"
echo "  put $lkey (the pointer, last)"

if [ "$CHECK_PUBLIC" = 1 ]; then
  command -v curl >/dev/null 2>&1 || fail "--check-public needs curl"
  curl -fsSL --max-time 60 "${BASE_URL%/}/$MANIFEST_KEY" -o "$WORK/public-manifest.json" || fail "the public URL ${BASE_URL%/}/$MANIFEST_KEY does not answer (is the bucket's domain mapped?)"
  cmp -s "$WORK/public-manifest.json" "$WORK/manifest.json" || fail "the manifest served at ${BASE_URL%/}/$MANIFEST_KEY is not the one just written"
  echo "public: ${BASE_URL%/}/$MANIFEST_KEY serves the manifest just written"
fi

echo
echo "Published Companion OS $VERSION ($CHANNEL) to $BUCKET/$PREFIX. Feed: ${BASE_URL%/}/$PREFIX/latest.json"
