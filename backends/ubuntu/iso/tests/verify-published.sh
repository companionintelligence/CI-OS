#!/usr/bin/env bash
#=============================================================================
# Test: scripts/verify-published.sh finds the difference between what was built and what is served
#
# A real HTTP server (python3 -m http.server on 127.0.0.1, a free port) serves a release laid out as the bucket is, made with release-manifest.py.
# The real script is run against it, then against the same release after each kind of damage:
#   untouched: every check passes (sizes, and with --full the bytes)     same size, different bytes: only --full sees it
#   a shorter file: the size check sees it                               SHA256SUMS that lists another hash, or none: refused
#   a manifest whose URL is not this release's path: refused             no latest.json, no manifest, an unusable version: a clear failure
#   signature: verified with the key given (stub gpg), refused when it does not verify    not https: refused unless localhost
#   a Plasma release (--edition plasma): found under os-plasma, --arch x86_64, the manifest must say the same edition as the one asked for,
#     and an architecture of the other edition is refused
#
# Pure bash 3.2, python3, curl, no network beyond 127.0.0.1, writes only to a temporary directory.
#   backends/ubuntu/iso/tests/verify-published.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../scripts/verify-published.sh"
MANIFEST="$HERE/../scripts/release-manifest.py"
[[ -f "$TOOL" ]] || { echo "missing $TOOL" >&2; exit 2; }
for t in python3 curl; do command -v "$t" >/dev/null 2>&1 || { echo "cannot run here: $t is missing" >&2; exit 2; }; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-published.XXXXXX")"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
has() { if grep -q -F -- "$2" <<<"$OUT"; then pass "$1"; else fail "$1 (no '$2' in the output)"; fi; }

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
BASE="http://127.0.0.1:$PORT"

mkdir -p "$WORK/bin"
cat >"$WORK/bin/gpg" <<'STUB'
#!/bin/sh
case "$*" in *--import*) exit 0 ;; esac
[ "${STUB_GPG:-good}" = good ]
STUB
chmod 755 "$WORK/bin/gpg"

# the release as the bucket holds it: root/os/1.0/{amd64,arm64}/..., root/os/1.0/{SHA256SUMS,manifest.json}, root/os/latest.json
build_release() {
  rm -rf "$WORK/out" "$WORK/root"; mkdir -p "$WORK/out" "$WORK/root/os/1.0/amd64" "$WORK/root/os/1.0/arm64"
  printf 'amd64 image bytes %.0s' $(seq 1 300) >"$WORK/out/companion-os-1.0-amd64.iso"
  printf 'arm64 image bytes %.0s' $(seq 1 350) >"$WORK/out/companion-os-1.0-arm64.iso"
  ( cd "$WORK/out" && { shasum -a 256 companion-os-1.0-*.iso 2>/dev/null || sha256sum companion-os-1.0-*.iso; } >SHA256SUMS )
  echo sig >"$WORK/out/SHA256SUMS.asc"
  python3 "$MANIFEST" --dir "$WORK/out" --out-dir "$WORK/mf" --version 1.0 --channel dev --base-url https://dl.ci.computer --prefix os >/dev/null
  cp "$WORK/out/companion-os-1.0-amd64.iso" "$WORK/root/os/1.0/amd64/"; cp "$WORK/out/companion-os-1.0-arm64.iso" "$WORK/root/os/1.0/arm64/"
  cp "$WORK/out/SHA256SUMS" "$WORK/out/SHA256SUMS.asc" "$WORK/root/os/1.0/"; cp "$WORK/mf/manifest.json" "$WORK/root/os/1.0/"; cp "$WORK/mf/latest.json" "$WORK/root/os/"
}
build_release
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/root" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -fsS -o /dev/null "$BASE/os/latest.json" 2>/dev/null && break; sleep 0.1; done

run() { OUT="$(env PATH="$WORK/bin:$PATH" bash "$TOOL" --base-url "$BASE" "$@" 2>&1)"; RC=$?; }

echo "== an untouched release"
run
eq "sizes only: exit 0" "$RC" "0"
has "it finds the version through latest.json" "latest.json names version 1.0"
has "  checks both images' sizes" "arm64: companion-os-1.0-arm64.iso is served at"
has "  and says it did not read the bytes" "run with --full for the bytes"
run --full
eq "--full: exit 0" "$RC" "0"
has "  the bytes of both images match" "amd64: downloaded and sha256"
run --arch arm64 --full
eq "--arch limits the check" "$(grep -c 'amd64:' <<<"$OUT" | tr -d ' ')" "0"
run --version 1.0 --prefix os
eq "an explicit version and prefix" "$RC" "0"
run --pubkey "$WORK/bin/gpg"
eq "with a public key and a good signature: exit 0" "$RC" "0"
has "  the signature check is reported" "SHA256SUMS.asc verifies against"

echo
echo "== damage"
build_release; printf 'X' | dd of="$WORK/root/os/1.0/amd64/companion-os-1.0-amd64.iso" bs=1 seek=100 conv=notrunc 2>/dev/null
run
eq "same size, different byte: the size check does not see it (exit 0)" "$RC" "0"
run --full
eq "  --full does (exit 1)" "$RC" "1"
has "  and says which image" "amd64: the downloaded file has sha256"
build_release; head -c 1000 "$WORK/out/companion-os-1.0-arm64.iso" >"$WORK/root/os/1.0/arm64/companion-os-1.0-arm64.iso"
run
eq "a shorter file: exit 1" "$RC" "1"
has "  the size check names it" "arm64: companion-os-1.0-arm64.iso is served at '1000' bytes"
build_release; grep -v 'arm64' "$WORK/out/SHA256SUMS" >"$WORK/root/os/1.0/SHA256SUMS"
run
eq "SHA256SUMS without an image: exit 1" "$RC" "1"
build_release; sed 's/^[0-9a-f]\{8\}/00000000/' "$WORK/out/SHA256SUMS" >"$WORK/root/os/1.0/SHA256SUMS"
run
eq "SHA256SUMS with another hash: exit 1" "$RC" "1"
build_release; python3 - "$WORK/root/os/1.0/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["images"]["amd64"]["iso"]["url"] = "https://evil.example/a.iso"; json.dump(d, open(p, "w"))
PY
run
eq "a manifest URL that is not this release's path: exit 1" "$RC" "1"
has "  and says so" "is not this release's path"
build_release; python3 - "$WORK/root/os/1.0/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["images"]["amd64"]["iso"]["name"] = "../../etc/passwd"; json.dump(d, open(p, "w"))
PY
run
eq "a file name that climbs: exit 1, never fetched" "$RC" "1"
has "  the entry is called malformed" "malformed"
build_release; rm "$WORK/root/os/latest.json"
run
eq "no latest.json: exit 1" "$RC" "1"
run --version 1.0
eq "  but an explicit version still verifies" "$RC" "0"
build_release; rm "$WORK/root/os/1.0/manifest.json"
run
eq "no manifest: exit 1" "$RC" "1"
build_release; python3 - "$WORK/root/os/latest.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["version"] = "../etc"; json.dump(d, open(p, "w"))
PY
run
eq "latest.json naming a version that climbs: exit 1" "$RC" "1"
build_release; rm "$WORK/root/os/1.0/SHA256SUMS"
run
eq "no SHA256SUMS served: exit 1" "$RC" "1"

echo
echo "== the signature"
build_release; STUB_GPG=bad run --pubkey "$WORK/bin/gpg"
eq "a signature that does not verify: exit 1" "$RC" "1"
build_release; rm "$WORK/root/os/1.0/SHA256SUMS.asc"; run --pubkey "$WORK/bin/gpg"
eq "no signature served while a key is given: exit 1" "$RC" "1"
build_release; run
has "no key given: says the signature was not checked" "signature not checked"

echo
echo "== the Plasma edition (--edition plasma)"
PBASE="companion-os-plasma-2026.10.18-x86_64"
build_plasma_release() { # the release as the bucket holds it: root/os-plasma/2026.10.18/x86_64/..., root/os-plasma/latest.json
  rm -rf "$WORK/out" "$WORK/root" "$WORK/mf"; mkdir -p "$WORK/out" "$WORK/root/os-plasma/2026.10.18/x86_64"
  printf 'plasma image bytes %.0s' $(seq 1 300) >"$WORK/out/$PBASE.iso"
  ( cd "$WORK/out" && { shasum -a 256 "$PBASE.iso" 2>/dev/null || sha256sum "$PBASE.iso"; } >SHA256SUMS )
  echo sig >"$WORK/out/SHA256SUMS.asc"
  python3 "$MANIFEST" --dir "$WORK/out" --out-dir "$WORK/mf" --version 2026.10.18 --channel dev --base-url https://dl.ci.computer --edition plasma >/dev/null
  cp "$WORK/out/$PBASE.iso" "$WORK/root/os-plasma/2026.10.18/x86_64/"
  cp "$WORK/out/SHA256SUMS" "$WORK/out/SHA256SUMS.asc" "$WORK/mf/manifest.json" "$WORK/root/os-plasma/2026.10.18/"; cp "$WORK/mf/latest.json" "$WORK/root/os-plasma/"
}
build_plasma_release
run --edition plasma
eq "an untouched Plasma release, found through latest.json under os-plasma: exit 0" "$RC" "0"
has "  the version is the image date" "latest.json names version 2026.10.18"
has "  the manifest says plasma, as asked" "manifest.json is the plasma edition"
has "  the image is checked at x86_64" "x86_64: $PBASE.iso is served at"
run --edition plasma --arch x86_64 --full
eq "--arch x86_64 --full: exit 0" "$RC" "0"
has "  the bytes of the image match" "x86_64: downloaded and sha256"
run --edition plasma --version 2026.10.18 --pubkey "$WORK/bin/gpg"
eq "an explicit version and a good signature: exit 0" "$RC" "0"
has "  the signature check is reported" "SHA256SUMS.asc verifies against"
run --prefix os-plasma --arch x86_64
eq "the prefix of a Plasma release without --edition plasma: the manifest says another edition, exit 1" "$RC" "1"
has "  and says which" "is the 'plasma' edition, and this check is for ubuntu"
run --edition plasma --arch amd64; eq "an Ubuntu architecture for a Plasma manifest: refused (exit 2)" "$RC" "2"
has "  and says why" "is not an architecture of the plasma edition"
run --edition plasma --arch arm64; eq "  arm64 too" "$RC" "2"
run --edition nope; eq "an edition that does not exist: refused" "$RC" "2"
run --edition; eq "--edition without its value" "$RC" "2"
run --prefix ''; eq "an empty --prefix is refused, not replaced by the edition's prefix" "$RC" "2"
printf 'X' | dd of="$WORK/root/os-plasma/2026.10.18/x86_64/$PBASE.iso" bs=1 seek=100 conv=notrunc 2>/dev/null
run --edition plasma --full
eq "a changed byte in the Plasma image: --full sees it (exit 1)" "$RC" "1"
has "  and says which image" "x86_64: the downloaded file has sha256"
build_plasma_release; head -c 1000 "$WORK/out/$PBASE.iso" >"$WORK/root/os-plasma/2026.10.18/x86_64/$PBASE.iso"
run --edition plasma
eq "a shorter Plasma image: the size check sees it (exit 1)" "$RC" "1"
build_release
run --arch x86_64; eq "an Ubuntu manifest with --arch x86_64: refused (exit 2)" "$RC" "2"
has "  and says why" "is not an architecture of the ubuntu edition"
run --edition plasma --prefix os; eq "an Ubuntu release checked as plasma: the manifest says another edition, exit 1" "$RC" "1"
has "  and says which" "is the 'ubuntu' edition, and this check is for plasma"
run --arch amd64; eq "the Ubuntu architectures are still accepted for an Ubuntu manifest" "$RC" "0"

echo
echo "== arguments"
build_release
run --base-url "http://dl.ci.computer"; eq "http for a real host: refused (exit 2)" "$RC" "2"
OUT="$(bash "$TOOL" --base-url "ftp://x" 2>&1)"; RC=$?; eq "another scheme: refused" "$RC" "2"
OUT="$(bash "$TOOL" 2>&1)"; RC=$?; eq "no --base-url: refused" "$RC" "2"
run --prefix '../x'; eq "a prefix that climbs: refused" "$RC" "2"
run --arch i386; eq "an unknown architecture: refused" "$RC" "2"
run --version '1.0/../x'; eq "a version that climbs: refused" "$RC" "2"
run --pubkey "$WORK/missing.asc"; eq "a missing public key file: refused" "$RC" "2"
run --nonsense; eq "an unknown argument: refused" "$RC" "2"

echo
echo "== the script itself"
if bash -n "$TOOL"; then pass "it parses"; else fail "it does not parse"; fi
if [[ -x "$TOOL" ]]; then pass "it is executable"; else fail "it is not executable"; fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
