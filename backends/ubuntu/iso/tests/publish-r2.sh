#!/usr/bin/env bash
#=============================================================================
# Test: scripts/publish-r2.sh uploads a release in the order that keeps `latest` honest, and refuses what it must
#
# The real script, with stub `aws`, `gpg` and `curl` on PATH (the stub aws keeps objects in a directory, so a second run can see the first):
#   a dry run uploads nothing and needs no credentials          credentials are required, used and never printed
#   --apply order: images, small files, manifest.json, latest.json last   multipart settings reach the AWS CLI (64 MB parts, R2 endpoint)
#   changed bytes after the checksums were made: refused before any upload   production without a good signature: refused
#   a version that exists: refused without --overwrite          a size that does not match after the upload: latest.json is NOT written
#   a version, bucket or channel that could point elsewhere: refused          --check-public compares the served manifest with the written one
#   --edition plasma: the prefix os-plasma, the image date as the version, the image's .pkgs.txt and .build-info beside the checksums, the
#     checksums made from the edition's own images, and the other edition's image in the directory refused
#
# Pure bash 3.2 (run it with /bin/bash on a Mac), python3, no network, writes only to a temporary directory.
#   backends/ubuntu/iso/tests/publish-r2.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../scripts/publish-r2.sh"
[[ -f "$TOOL" ]] || { echo "missing $TOOL" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "cannot run here: python3 is missing" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-r2.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
has() { if grep -q -F -- "$2" <<<"$OUT"; then pass "$1"; else fail "$1 (no '$2' in the output)"; fi; }
lacks() { if grep -q -F -- "$2" <<<"$OUT"; then fail "$1 (found '$2')"; else pass "$1"; fi; }

SECRET="s3cr3t-key-that-must-never-be-printed-0123456789"
KEYID="AKIDEXAMPLE-must-not-be-printed"
ACCOUNT="0123456789abcdef0123456789abcdef"

# --- the stubs -------------------------------------------------------------------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/aws" <<'STUB'
#!/bin/sh
# s3 cp FILE s3://BUCKET/KEY ...       -> store the file, log "cp BUCKET/KEY"
# s3api head-object --bucket B --key K -> print the size, or exit 254 when there is no such object
echo "ENV $AWS_DEFAULT_REGION $AWS_REQUEST_CHECKSUM_CALCULATION $(grep -c multipart_chunksize "$AWS_CONFIG_FILE" 2>/dev/null) key=$AWS_ACCESS_KEY_ID secret=$AWS_SECRET_ACCESS_KEY" >> "$STUB_ENV"
case "$1 $2" in
  "s3 cp")
    src="$3"; dst="$4"; path="${dst#s3://}"
    case "$*" in *"--endpoint-url https://${EXPECT_ACCOUNT}.r2.cloudflarestorage.com"*) ;; *) echo "wrong endpoint: $*" >> "$STUB_LOG"; exit 1 ;; esac
    echo "cp $path ct=$(echo "$*" | sed -n 's/.*--content-type \([^ ]*\).*/\1/p')" >> "$STUB_LOG"
    [ -n "${STUB_FAIL_PUT:-}" ] && [ "$path" = "$STUB_FAIL_PUT" ] && exit 1
    mkdir -p "$STUB_STORE/$(dirname "$path")"; cp "$src" "$STUB_STORE/$path" ;;
  "s3api head-object")
    bucket=""; key=""
    while [ $# -gt 0 ]; do case "$1" in --bucket) bucket="$2"; shift 2 ;; --key) key="$2"; shift 2 ;; *) shift ;; esac; done
    f="$STUB_STORE/$bucket/$key"
    echo "head $bucket/$key" >> "$STUB_LOG"
    [ -f "$f" ] || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254; }
    n=$(wc -c < "$f" | tr -d ' ')
    [ -n "${STUB_SHORT:-}" ] && [ "$bucket/$key" = "$STUB_SHORT" ] && n=$((n - 1))
    echo "$n" ;;
  *) echo "unexpected aws call: $*" >> "$STUB_LOG"; exit 1 ;;
esac
STUB
cat >"$BIN/gpg" <<'STUB'
#!/bin/sh
echo "gpg $*" >> "$STUB_LOG"
case "$*" in *--import*) exit 0 ;; esac
[ "${STUB_GPG:-good}" = good ]
STUB
cat >"$BIN/curl" <<'STUB'
#!/bin/sh
# curl -fsSL --max-time 60 URL -o OUT : serve the manifest from the store, unless STUB_PUBLIC_DOWN
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
echo "curl $url" >> "$STUB_LOG"
[ -n "${STUB_PUBLIC_DOWN:-}" ] && exit 22
rel="${url#https://dl.ci.computer/}"; rel="${rel#https://dl-dev.ci.computer/}"
if [ -n "${STUB_PUBLIC_WRONG:-}" ]; then echo '{"wrong": true}' > "$out"; exit 0; fi
cp "$STUB_STORE/dl-dev/$rel" "$out" 2>/dev/null || cp "$STUB_STORE/dl-prod/$rel" "$out"
STUB
chmod 755 "$BIN"/*

# --- scenarios ---------------------------------------------------------------------------------------------------------------------------
fresh() { # a new build directory, store and logs
  rm -rf "$WORK/out" "$WORK/store" "$WORK/log" "$WORK/env"; mkdir -p "$WORK/out" "$WORK/store"; : >"$WORK/log"; : >"$WORK/env"
  printf 'amd64 image bytes %.0s' $(seq 1 400) >"$WORK/out/companion-os-1.0-amd64.iso"
  printf 'arm64 image bytes %.0s' $(seq 1 500) >"$WORK/out/companion-os-1.0-arm64.iso"
  ( cd "$WORK/out" && { shasum -a 256 companion-os-1.0-*.iso 2>/dev/null || sha256sum companion-os-1.0-*.iso; } >SHA256SUMS )
  echo "sbom" >"$WORK/out/SBOM.txt"
}
run() { # args for the script; OUT holds stdout+stderr, RC the exit status
  OUT="$(env PATH="$BIN:$PATH" STUB_STORE="$WORK/store" STUB_LOG="$WORK/log" STUB_ENV="$WORK/env" EXPECT_ACCOUNT="$ACCOUNT" \
      R2_ACCOUNT_ID="$ACCOUNT" R2_ACCESS_KEY_ID="$KEYID" R2_SECRET_ACCESS_KEY="$SECRET" "$@" 2>&1)"; RC=$?
}
pub() { run bash "$TOOL" --dir "$WORK/out" --version 1.0 "$@"; }
puts() { grep '^cp ' "$WORK/log" | sed 's/ ct=.*//; s/^cp //'; }

echo "== a dry run"
fresh; pub
eq "exit 0" "$RC" "0"
has "it says it is a dry run" "DRY RUN: nothing is uploaded"
has "it lists the images" "os/1.0/amd64/companion-os-1.0-amd64.iso"
has "  and the pointer last" "latest.json moves last"
eq "no aws call at all" "$(grep -c . "$WORK/log" | tr -d ' ')" "0"
fresh; OUT="$(env PATH="$BIN:$PATH" STUB_STORE="$WORK/store" STUB_LOG="$WORK/log" STUB_ENV="$WORK/env" bash "$TOOL" --dir "$WORK/out" --version 1.0 2>&1)"; RC=$?
eq "a dry run needs no credentials" "$RC" "0"
eq "the bucket for dev is dl-dev" "$(grep -c 'bucket dl-dev' <<<"$OUT" | tr -d ' ')" "1"
echo sig >"$WORK/out/SHA256SUMS.asc"; pub --channel production; has "  production would use dl-prod" "bucket dl-prod"

echo
echo "== --apply: order, endpoint, multipart settings, credentials"
fresh; pub --apply
eq "exit 0" "$RC" "0"
eq "the objects went up in the order that keeps latest honest" "$(puts | tr '\n' ' ')" \
   "dl-dev/os/1.0/amd64/companion-os-1.0-amd64.iso dl-dev/os/1.0/arm64/companion-os-1.0-arm64.iso dl-dev/os/1.0/SHA256SUMS dl-dev/os/1.0/SBOM.txt dl-dev/os/1.0/manifest.json dl-dev/os/latest.json "
eq "the image content type" "$(grep 'amd64.iso' "$WORK/log" | grep '^cp' | sed -n 's/.*ct=//p')" "application/x-iso9660-image"
eq "sizes were checked after the upload (head-object for each, 5 objects)" "$(grep -c '^head dl-dev/os/1.0/' "$WORK/log" | tr -d ' ')" "6"
eq "the S3 region is auto and 64 MB parts are configured" "$(head -1 "$WORK/env" | cut -d' ' -f2-4)" "auto when_required 1"
eq "the AWS CLI got the key pair (as environment, not arguments)" "$(head -1 "$WORK/env" | sed -n 's/.*key=\([^ ]*\) secret=\(.*\)/\1 \2/p')" "$KEYID $SECRET"
lacks "the secret is not printed" "$SECRET"
lacks "the key id is not printed" "$KEYID"
has "it ends by naming the feed, at the dev origin" "https://dl-dev.ci.computer/os/latest.json"
eq "manifest.json in the store is the one for this release" "$(python3 -c "import json,sys; print(json.load(open('$WORK/store/dl-dev/os/1.0/manifest.json'))['images']['arm64']['iso']['size'])")" "$(wc -c < "$WORK/out/companion-os-1.0-arm64.iso" | tr -d ' ')"
eq "the manifest in the dev bucket names the dev origin" "$(python3 -c "import json; print(json.load(open('$WORK/store/dl-dev/os/1.0/manifest.json'))['images']['amd64']['iso']['url'])")" "https://dl-dev.ci.computer/os/1.0/amd64/companion-os-1.0-amd64.iso"
eq "latest.json names the version" "$(python3 -c "import json; print(json.load(open('$WORK/store/dl-dev/os/latest.json'))['version'])")" "1.0"
eq "the build directory gained no manifest.json (it is written beside, not into, the output)" "$([[ -e "$WORK/out/manifest.json" ]] && echo yes || echo no)" "no"

echo
echo "== production: dl-prod, dl.ci.computer, and only with a good signature"
fresh; echo sig >"$WORK/out/SHA256SUMS.asc"; pub --apply --channel production
eq "exit 0" "$RC" "0"
eq "the objects went to dl-prod" "$(puts | grep -c '^dl-prod/os/1.0/')" "6"
eq "  and none to dl-dev" "$(puts | grep -c '^dl-dev/')" "0"
eq "the manifest names the production origin and channel" "$(python3 -c "import json; d=json.load(open('$WORK/store/dl-prod/os/1.0/manifest.json')); print(d['channel'], d['images']['arm64']['iso']['url'])")" "production https://dl.ci.computer/os/1.0/arm64/companion-os-1.0-arm64.iso"
eq "the signature is published beside the checksums" "$([[ -e "$WORK/store/dl-prod/os/1.0/SHA256SUMS.asc" ]] && echo yes || echo no)" "yes"
fresh; echo sig >"$WORK/out/SHA256SUMS.asc"; pub --apply --channel production --bucket dl-staging --base-url https://staging.example.com
eq "--bucket and --base-url override the defaults" "$(puts | grep -c '^dl-staging/os/1.0/')" "6"

echo
echo "== credentials"
fresh; run env -u R2_ACCESS_KEY_ID bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply
eq "no key id: refused (exit 2) before any upload" "$RC/$(grep -c '^cp ' "$WORK/log" | tr -d ' ')" "2/0"
has "  and says which" "R2_ACCESS_KEY_ID"
fresh; run env -u R2_SECRET_ACCESS_KEY bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply
eq "no secret: refused" "$RC" "2"
fresh; run env -u R2_ACCOUNT_ID bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply
eq "no account id: refused" "$RC" "2"
fresh; run env CLOUDFLARE_ACCOUNT_ID="$ACCOUNT" R2_ACCOUNT_ID= bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply
eq "CLOUDFLARE_ACCOUNT_ID works as the account id" "$RC" "0"

echo
echo "== the files must be the ones that were checksummed"
fresh; printf 'tampered' >>"$WORK/out/companion-os-1.0-amd64.iso"; pub --apply
eq "changed bytes: refused (exit 2), nothing uploaded" "$RC/$(grep -c '^cp ' "$WORK/log" | tr -d ' ')" "2/0"
has "  and says so" "does not match"
fresh; rm "$WORK/out/SHA256SUMS"; pub
eq "no SHA256SUMS: refused" "$RC" "2"
fresh; ( cd "$WORK/out" && { shasum -a 256 companion-os-1.0-arm64.iso 2>/dev/null || sha256sum companion-os-1.0-arm64.iso; } >SHA256SUMS ); pub --apply
eq "a SHA256SUMS that leaves out an image (two builds on two machines): refused, nothing uploaded" "$RC/$(grep -c '^cp ' "$WORK/log" | tr -d ' ')" "2/0"
has "  and names the image and the remedy" "no line for companion-os-1.0-amd64.iso"
fresh; rm "$WORK/out/SHA256SUMS"; pub --make-checksums
eq "--make-checksums writes it, and the dry run passes" "$RC" "0"
fresh; pub --version 2.0
eq "a version that is not in the file names: refused" "$RC" "2"

echo
echo "== the signature"
fresh; pub --channel production
eq "production without SHA256SUMS.asc: refused" "$RC" "2"
has "  and says why" "production needs SHA256SUMS.asc"
fresh; echo sig >"$WORK/out/SHA256SUMS.asc"; pub --channel production
eq "production with a good signature: passes" "$RC" "0"
has "  and says it verified" "SHA256SUMS.asc verifies"
fresh; echo sig >"$WORK/out/SHA256SUMS.asc"; run env STUB_GPG=bad bash "$TOOL" --dir "$WORK/out" --version 1.0 --channel production
eq "a bad signature: refused, in production" "$RC" "2"
fresh; echo sig >"$WORK/out/SHA256SUMS.asc"; run env STUB_GPG=bad bash "$TOOL" --dir "$WORK/out" --version 1.0 --channel dev
eq "a bad signature: refused in dev too (a signature that is there must be good)" "$RC" "2"
fresh; pub
has "dev without a signature is allowed, and says so" "none (allowed for --channel dev)"
fresh; echo sig >"$WORK/out/SHA256SUMS.asc"; echo key >"$WORK/pub.asc"; pub --pubkey "$WORK/pub.asc"
eq "--pubkey: imported into a throw-away keyring, then verified" "$RC/$(grep -c 'gpg.*--import' "$WORK/log" | tr -d ' ')" "0/1"
fresh; pub --pubkey "$WORK/nope.asc"; echo sig >/dev/null
eq "a missing --pubkey file is refused only when there is a signature to check" "$RC" "0"

echo
echo "== a version that exists, and an upload that does not verify"
fresh; pub --apply; pub --apply
eq "the same version twice: refused (exit 2)" "$RC" "2"
has "  and says how to replace it" "--overwrite"
pub --apply --overwrite
eq "--overwrite replaces it" "$RC" "0"
has "  and warns" "replacing the existing"
fresh; run env STUB_SHORT="dl-dev/os/1.0/arm64/companion-os-1.0-arm64.iso" bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply
eq "a size mismatch after the upload: exit 1" "$RC" "1"
has "  and says latest is not updated" "latest.json is NOT updated"
eq "  and latest.json is not in the bucket" "$([[ -e "$WORK/store/dl-dev/os/latest.json" ]] && echo yes || echo no)" "no"
fresh; run env STUB_FAIL_PUT="dl-dev/os/1.0/arm64/companion-os-1.0-arm64.iso" bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply
eq "a failed upload: exit 1, and no latest.json" "$RC/$([[ -e "$WORK/store/dl-dev/os/latest.json" ]] && echo yes || echo no)" "1/no"
fresh; run env STUB_FAIL_PUT="dl-dev/os/latest.json" bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply
eq "a failed pointer upload: exit 1, with a message that the images are in place" "$RC" "1"
has "  and what latest.json still names" "still names the previous version"

echo
echo "== --check-public"
fresh; pub --apply --check-public
eq "the served manifest equals the written one: exit 0" "$RC" "0"
has "  and says so" "serves the manifest just written"
fresh; run env STUB_PUBLIC_DOWN=1 bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply --check-public
eq "a public URL that does not answer: exit 1" "$RC" "1"
fresh; run env STUB_PUBLIC_WRONG=1 bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply --check-public
eq "a different manifest served: exit 1" "$RC" "1"

echo
echo "== refusals before anything happens"
fresh; pub --channel staging; eq "an unknown channel" "$RC" "2"
fresh; pub --bucket 'Bad_Bucket'; eq "a bucket name that is not one" "$RC" "2"
fresh; pub --prefix '../x'; eq "a prefix that climbs" "$RC" "2"
fresh; pub --base-url 'http://dl.ci.computer'; eq "a base URL that is not https" "$RC" "2"
fresh; run bash "$TOOL" --version 1.0; eq "no --dir" "$RC" "2"
fresh; run bash "$TOOL" --dir "$WORK/out"; eq "no --version" "$RC" "2"
fresh; pub --nonsense; eq "an unknown argument" "$RC" "2"
fresh; run bash "$TOOL" --dir "$WORK/out" --version; eq "an option without its value" "$RC" "2"

echo
echo "== the Plasma edition (--edition plasma): its own prefix, version and side files"
PBASE="companion-os-plasma-2026.10.18-x86_64"
fresh_plasma() { # a new build directory of one Plasma image with its package list and build record, checksummed
  rm -rf "$WORK/out" "$WORK/store" "$WORK/log" "$WORK/env"; mkdir -p "$WORK/out" "$WORK/store"; : >"$WORK/log"; : >"$WORK/env"
  printf 'plasma image bytes %.0s' $(seq 1 300) >"$WORK/out/$PBASE.iso"
  echo "packages" >"$WORK/out/$PBASE.pkgs.txt"; echo "KEY=VALUE" >"$WORK/out/$PBASE.build-info"
  ( cd "$WORK/out" && { shasum -a 256 "$PBASE.iso" 2>/dev/null || sha256sum "$PBASE.iso"; } >SHA256SUMS )
}
pubp() { run bash "$TOOL" --dir "$WORK/out" --version 2026.10.18 --edition plasma "$@"; }

fresh_plasma; pubp
eq "a dry run of the Plasma image: exit 0" "$RC" "0"
has "  lists the image under the plasma prefix and the image date" "os-plasma/2026.10.18/x86_64/$PBASE.iso"
has "  and the package list beside the checksums" "os-plasma/2026.10.18/$PBASE.pkgs.txt"
has "  and the build record" "os-plasma/2026.10.18/$PBASE.build-info"
has "  and the pointer last, under the same prefix" "os-plasma/latest.json moves last"
eq "  and nothing listed under the Ubuntu prefix" "$(grep -c '^  os/' <<<"$OUT" | tr -d ' ')" "0"
eq "no aws call at all" "$(grep -c . "$WORK/log" | tr -d ' ')" "0"

fresh_plasma; pubp --apply
eq "--apply: exit 0" "$RC" "0"
eq "the objects went up in the order that keeps latest honest" "$(puts | tr '\n' ' ')" \
   "dl-dev/os-plasma/2026.10.18/x86_64/$PBASE.iso dl-dev/os-plasma/2026.10.18/SHA256SUMS dl-dev/os-plasma/2026.10.18/$PBASE.pkgs.txt dl-dev/os-plasma/2026.10.18/$PBASE.build-info dl-dev/os-plasma/2026.10.18/manifest.json dl-dev/os-plasma/latest.json "
eq "the side files are plain text" "$(grep -E "pkgs.txt|build-info" "$WORK/log" | grep '^cp' | sed -n 's/.*ct=//p' | sort -u | tr '\n' ' ')" "text/plain "
eq "the manifest in the bucket says which edition it is" "$(python3 -c "import json; d=json.load(open('$WORK/store/dl-dev/os-plasma/2026.10.18/manifest.json')); print(d['edition'], d['product'], list(d['images']))")" "plasma companion-os ['x86_64']"
eq "  and so does the feed" "$(python3 -c "import json; d=json.load(open('$WORK/store/dl-dev/os-plasma/latest.json')); print(d['edition'], d['version'])")" "plasma 2026.10.18"
eq "nothing was written under the Ubuntu prefix" "$(puts | grep -c '^dl-dev/os/')" "0"

fresh_plasma; pubp --apply --check-public
eq "--check-public finds the Plasma manifest at the plasma prefix" "$RC" "0"
has "  and says so" "os-plasma/2026.10.18/manifest.json serves the manifest just written"

fresh_plasma; echo sig >"$WORK/out/SHA256SUMS.asc"; pubp --apply --channel production
eq "production, signed: the objects went to dl-prod under the plasma prefix" "$RC/$(puts | grep -c '^dl-prod/os-plasma/2026.10.18/')" "0/6"
fresh_plasma; pubp --channel production
eq "production without a signature: refused, for this edition too" "$RC" "2"
fresh_plasma; pubp --prefix os-plasma/preview
has "--prefix still overrides the edition's prefix" "os-plasma/preview/2026.10.18/x86_64/$PBASE.iso"

echo
echo "== --make-checksums writes the checksums of the edition's own images"
fresh_plasma; rm "$WORK/out/SHA256SUMS"; pubp --make-checksums
eq "plasma: written from the Plasma image, and the dry run passes" "$RC/$(awk '{print $2}' "$WORK/out/SHA256SUMS" | tr '\n' ' ')" "0/$PBASE.iso "
fresh; rm "$WORK/out/SHA256SUMS"; pub --make-checksums
eq "ubuntu: written from both Ubuntu images" "$RC/$(awk '{print $2}' "$WORK/out/SHA256SUMS" | tr '\n' ' ')" "0/companion-os-1.0-amd64.iso companion-os-1.0-arm64.iso "
fresh_plasma; printf 'u' >"$WORK/out/companion-os-1.0-amd64.iso"; rm "$WORK/out/SHA256SUMS"; pubp --make-checksums
eq "plasma, with an Ubuntu image in the directory: the checksums name only the Plasma image" "$(awk '{print $2}' "$WORK/out/SHA256SUMS" | tr '\n' ' ')" "$PBASE.iso "
eq "  and the release is refused (exit 2), nothing uploaded" "$RC/$(grep -c '^cp ' "$WORK/log" | tr -d ' ')" "2/0"
has "  with the reason" "image of the ubuntu edition"
fresh; printf 'p' >"$WORK/out/$PBASE.iso"; rm "$WORK/out/SHA256SUMS"; pub --make-checksums
eq "ubuntu, with a Plasma image in the directory: the checksums name only the Ubuntu images" "$(awk '{print $2}' "$WORK/out/SHA256SUMS" | tr '\n' ' ')" "companion-os-1.0-amd64.iso companion-os-1.0-arm64.iso "
eq "  and the release is refused (exit 2)" "$RC" "2"
has "  with the reason" "image of the plasma edition"

echo
echo "== no empty SHA256SUMS is left behind, and an empty one is refused"
# the slip that matters: the edition does not fit the directory, so the glob matches nothing; a zero-byte SHA256SUMS left by that run would be
# taken for the list by the next one, and some checksum tools accept a list that names no file
nofile() { [[ -e "$WORK/out/SHA256SUMS" ]] && echo yes || echo no; }
fresh_plasma; rm "$WORK/out/SHA256SUMS"; pub --version 2026.10.18 --make-checksums
eq "a Plasma directory published with the edition forgotten: refused (exit 2), and no SHA256SUMS is left behind" "$RC/$(nofile)" "2/no"
has "  and it says the edition may be the wrong one" "is --edition right for this directory"
pubp --make-checksums
eq "  the corrected run then writes the list from the Plasma image and passes" "$RC/$(awk '{print $2}' "$WORK/out/SHA256SUMS" | tr '\n' ' ')" "0/$PBASE.iso "
eq "  and the dry run lists a SHA256SUMS that has bytes" "$(grep -c 'SHA256SUMS  *0 bytes' <<<"$OUT" | tr -d ' ')" "0"
fresh; rm "$WORK/out/SHA256SUMS"; pub --edition plasma --make-checksums
eq "an Ubuntu directory published as plasma: refused (exit 2), and no SHA256SUMS is left behind" "$RC/$(nofile)" "2/no"
fresh; rm "$WORK/out/SHA256SUMS" "$WORK/out"/companion-os-1.0-*.iso; pub --make-checksums
eq "a directory with no image at all: refused (exit 2), and no SHA256SUMS is left behind" "$RC/$(nofile)" "2/no"
fresh; : >"$WORK/out/SHA256SUMS"; pub --apply
eq "an empty SHA256SUMS: refused (exit 2), nothing uploaded" "$RC/$(grep -c '^cp ' "$WORK/log" | tr -d ' ')" "2/0"
has "  and says it is empty" "SHA256SUMS is empty"
fresh; : >"$WORK/out/SHA256SUMS"; pub --make-checksums
eq "  --make-checksums does not replace an empty list (it writes one only when there is none)" "$RC" "2"
fresh; printf '\n' >"$WORK/out/SHA256SUMS"; pub --apply
eq "a SHA256SUMS that holds only a blank line: refused (exit 2), nothing uploaded" "$RC/$(grep -c '^cp ' "$WORK/log" | tr -d ' ')" "2/0"
fresh_plasma; : >"$WORK/out/SHA256SUMS"; pubp --apply
eq "an empty SHA256SUMS for the Plasma edition: refused (exit 2), nothing uploaded" "$RC/$(grep -c '^cp ' "$WORK/log" | tr -d ' ')" "2/0"

echo
echo "== the edition is checked before anything else"
fresh_plasma; pub --version 2026.10.18
eq "a Plasma directory published as the default edition: refused (exit 2)" "$RC" "2"
has "  with the reason" "image of the plasma edition"
fresh; pub --edition plasma
eq "an Ubuntu directory published as plasma: refused (exit 2)" "$RC" "2"
fresh_plasma; pubp --version 2026.10.19
eq "a Plasma version that is not the image date: refused" "$RC" "2"
fresh_plasma; pubp --edition nope; eq "an edition that does not exist: refused" "$RC/$(grep -c '^cp ' "$WORK/log" | tr -d ' ')" "2/0"
has "  and says which" "--edition must be ubuntu or plasma"
fresh_plasma; run bash "$TOOL" --dir "$WORK/out" --version 2026.10.18 --edition; eq "--edition without its value" "$RC" "2"
fresh_plasma; pubp --prefix ''; eq "an empty --prefix is refused, not replaced by the edition's prefix" "$RC" "2"
OUT="$(bash "$TOOL" --help 2>&1)"; has "--help documents the edition" "--edition E"

echo
echo "== a PREFIX in the environment is ignored: only --prefix and the edition choose the key prefix"
fresh; run env PREFIX=zzz bash "$TOOL" --dir "$WORK/out" --version 1.0
eq "an exported PREFIX does not move an Ubuntu release (exit 0)" "$RC" "0"
has "  the keys are under os/" "os/1.0/amd64/companion-os-1.0-amd64.iso"
lacks "  and none under the exported value" "zzz"
has "  and the pointer is os/latest.json" "/os/latest.json moves last"
fresh_plasma; run env PREFIX=zzz bash "$TOOL" --dir "$WORK/out" --version 2026.10.18 --edition plasma
has "  nor a Plasma release: its keys are under os-plasma/" "os-plasma/2026.10.18/x86_64/$PBASE.iso"
lacks "  and none under the exported value" "zzz"
fresh; run env PREFIX=/usr/local bash "$TOOL" --dir "$WORK/out" --version 1.0
eq "an exported PREFIX that is no key prefix at all is not a refusal either (exit 0)" "$RC" "0"
fresh; run env PREFIX=zzz bash "$TOOL" --dir "$WORK/out" --version 1.0 --prefix os/preview
has "--prefix still decides when it is given" "os/preview/1.0/amd64/companion-os-1.0-amd64.iso"
lacks "  and the environment still does not" "zzz"
fresh; run env PREFIX=zzz bash "$TOOL" --dir "$WORK/out" --version 1.0 --apply
eq "--apply puts the objects under os/ too (five under os/1.0/ and the pointer)" "$RC/$(puts | grep -c '^dl-dev/os/1.0/')/$(puts | grep -c '^dl-dev/os/latest.json$')/$(puts | grep -c zzz)" "0/5/1/0"

echo
echo "== the script itself"
if bash -n "$TOOL"; then pass "it parses"; else fail "it does not parse"; fi
if [[ -x "$TOOL" ]]; then pass "it is executable"; else fail "it is not executable"; fi
if grep -n -E 'set -x|xtrace|wrangler r2 object put' "$TOOL" | grep -v '^[0-9]*:#' | grep -q .; then fail "set -x (it would print the credentials) or wrangler for an image (315 MB limit)"; else pass "no xtrace, and no wrangler for the images"; fi
if grep -n -E '(echo|printf)[^#]*\$\{?(R2_SECRET_ACCESS_KEY|R2_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID)' "$TOOL" | grep -v '^[0-9]*:#' | grep -q .; then fail "a credential variable's value is echoed"; else pass "no credential value is echoed"; fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
