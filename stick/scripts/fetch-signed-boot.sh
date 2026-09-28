#!/usr/bin/env bash
# Fetch the Companion Stick Secure Boot chain from Ubuntu's archive, through apt only.
#
#   stick/scripts/fetch-signed-boot.sh <out-dir> [--expect <signed-boot.lock>]
#
# Writes <out-dir>/shimx64.efi, grubx64.efi, mmx64.efi, signed-boot.lock and
# canonical-uefi-ca.pem. Copy only the three .efi files into <staging>/efi/ (ci-stick lock
# records them as the Secure Boot chain); keep the lock file with your build records.
#
# Trust chain on a real PC:
#   firmware db (Microsoft UEFI CA 2011) -> shimx64.efi (Microsoft-signed, shim-signed)
#   -> grubx64.efi (Canonical-signed, grub-efi-amd64-signed) -> Canonical-signed kernel
#   in the boot slot's ISO. mmx64.efi (MokManager, Canonical-signed) is for recovery.
#
# How the binaries are obtained and checked:
#   1. `apt-get download shim-signed grub-efi-amd64-signed` on Ubuntu 24.04 (noble). apt
#      only accepts a .deb whose hash matches the Packages index, which is authenticated by
#      the archive's signed InRelease — no curl, no unauthenticated mirrors.
#   2. `dpkg-deb -x`, then pick:
#        shimx64.efi <- /usr/lib/shim/shimx64.efi.signed.latest
#          (shim 15.8, SBAT "shim,4", Microsoft-signed. NOT .signed.previous: that is shim
#          15.4, SBAT "shim,1", which current SBAT revocations — shipped by Windows updates
#          and by shim 15.8 itself — reject. Not .dualsigned either: it adds a Canonical
#          signature we do not need and that some firmware mishandles.)
#        grubx64.efi <- /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed
#          (the monolithic *disk* image, prefix /EFI/ubuntu, no embedded config. NOT
#          gcdx64.efi.signed: the CD image's embedded config searches for /.disk/info,
#          which every boot slot's ISO has, so it could boot the wrong slot's grub.cfg.)
#        mmx64.efi   <- /usr/lib/shim/mmx64.efi
#      fbx64.efi (shim's fallback loader) is deliberately not shipped: shim would run it
#      from a removable path and it writes boot entries into the host's NVRAM.
#   3. `sbverify --list`: each binary must carry an Authenticode signature, shim's from
#      Microsoft's UEFI CA, grub's and mm's from Canonical.
#   4. `sbverify --cert`: grubx64.efi and mmx64.efi must verify against the Canonical CA
#      certificate embedded in that shim (.vendor_cert) — exactly the check shim makes at
#      boot. The CA is also written out (canonical-uefi-ca.pem) for checking kernels.
#   5. signed-boot.lock records the package versions and every sha256. With
#      --expect <lock>, the same versions are requested and every sha256 must match.
#
# Needs: Ubuntu 24.04 with apt lists (apt-get update), dpkg-deb, sbsigntool (sbverify),
# binutils (objcopy), openssl, coreutils. No root needed.
set -euo pipefail

usage() { echo "usage: fetch-signed-boot.sh <out-dir> [--expect <signed-boot.lock>]" >&2; exit 2; }
[ $# -ge 1 ] || usage
out="$1"; shift
expect=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect) expect="${2:?--expect needs a file}"; shift 2 ;;
    *) usage ;;
  esac
done

SERIES=noble
for t in apt-get apt-cache dpkg-deb sbverify objcopy openssl sha256sum od dd; do
  command -v "$t" >/dev/null || {
    echo "missing tool: $t (apt-get install sbsigntool binutils openssl)" >&2; exit 2; }
done
codename="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
if [ "$codename" != "$SERIES" ]; then
  echo "fetch-signed-boot.sh runs on Ubuntu 24.04 ($SERIES), this is '${codename:-unknown}'." >&2
  echo "Run it in a container: docker run --rm -v \"\$PWD\":/src ubuntu:24.04 ..." >&2
  echo "(stick/tests/secureboot/build-in-container.sh does exactly that)." >&2
  exit 2
fi

lock_get() { # lock_get <key> -> value of "key=value" in the expected lock
  sed -n "s/^$1=//p" "$expect" | head -n 1
}
pkg_spec() { # pkg_spec <package> -> package or package=version (pinned by --expect)
  local v=""
  [ -n "$expect" ] && v="$(lock_get "$1")"
  if [ -n "$v" ]; then echo "$1=$v"; else echo "$1"; fi
}

for p in shim-signed grub-efi-amd64-signed; do
  cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2}')"
  if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
    echo "apt knows no candidate for $p — run apt-get update first" >&2; exit 2
  fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 0755 "$tmp"   # lets apt's sandbox user write there when run as root
(cd "$tmp" && apt-get download -q "$(pkg_spec shim-signed)" "$(pkg_spec grub-efi-amd64-signed)" \
  2> >(grep -v "couldn't be accessed by user '_apt'" >&2))
shim_deb="$(ls "$tmp"/shim-signed_*.deb)"
grub_deb="$(ls "$tmp"/grub-efi-amd64-signed_*.deb)"
shim_ver="$(dpkg-deb -f "$shim_deb" Version)"
grub_ver="$(dpkg-deb -f "$grub_deb" Version)"
mkdir -p "$tmp/x"
dpkg-deb -x "$shim_deb" "$tmp/x"
dpkg-deb -x "$grub_deb" "$tmp/x"

mkdir -p "$out"
declare -A SRC=(
  [shimx64.efi]=/usr/lib/shim/shimx64.efi.signed.latest
  [grubx64.efi]=/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed
  [mmx64.efi]=/usr/lib/shim/mmx64.efi
)
declare -A PKG=([shimx64.efi]=shim-signed [grubx64.efi]=grub-efi-amd64-signed [mmx64.efi]=shim-signed)
declare -A SIGNER=(
  [shimx64.efi]="Microsoft Corporation UEFI CA 2011"
  [grubx64.efi]="Canonical Ltd. Secure Boot Signing"
  [mmx64.efi]="Canonical Ltd. Secure Boot Signing"
)

for f in shimx64.efi grubx64.efi mmx64.efi; do
  src="$tmp/x${SRC[$f]}"
  [ -f "$src" ] || { echo "${PKG[$f]} no longer ships ${SRC[$f]} — re-check this script" >&2; exit 1; }
  listing="$(sbverify --list "$src" 2>&1)"
  if ! grep -q "^signature 1" <<<"$listing"; then
    echo "$f (${SRC[$f]}) carries no Authenticode signature — refusing" >&2; exit 1
  fi
  if ! grep -qF "${SIGNER[$f]}" <<<"$listing"; then
    echo "$f is not signed via '${SIGNER[$f]}':" >&2; echo "$listing" >&2; exit 1
  fi
  cp "$src" "$out/$f"
done

# Canonical's CA as embedded in shim's .vendor_cert section:
#   u32 authorized_size, u32 deauthorized_size, u32 authorized_offset, u32 deauthorized_offset
objcopy -O binary --only-section=.vendor_cert "$out/shimx64.efi" "$tmp/vendor_cert.bin"
read -r cert_size _ cert_off _ < <(od -An -t u4 -N 16 "$tmp/vendor_cert.bin")
dd if="$tmp/vendor_cert.bin" of="$tmp/vendor.der" bs=1 skip="$cert_off" count="$cert_size" status=none
openssl x509 -inform DER -in "$tmp/vendor.der" -out "$out/canonical-uefi-ca.pem"
ca_subject="$(openssl x509 -in "$out/canonical-uefi-ca.pem" -noout -subject)"
case "$ca_subject" in
  *"Canonical Ltd. Master Certificate Authority"*) ;;
  *) echo "unexpected vendor certificate in shim: $ca_subject" >&2; exit 1 ;;
esac
for f in grubx64.efi mmx64.efi; do
  if ! sbverify --cert "$out/canonical-uefi-ca.pem" "$out/$f" >/dev/null 2>&1; then
    echo "$f does not verify against the Canonical CA embedded in shim — refusing" >&2; exit 1
  fi
done

sbat() { objcopy -O binary --only-section=.sbat "$1" "$tmp/sbat" && tr -d '\0' < "$tmp/sbat" \
  | awk -F, 'NR > 1 && $1 !~ /\./ {printf "%s%s,%s", sep, $1, $2; sep=" "}'; }

lock="$out/signed-boot.lock"
{
  echo "# Companion Stick Secure Boot chain — written by stick/scripts/fetch-signed-boot.sh."
  echo "# Obtained with apt-get download (archive-signed InRelease -> Packages -> .deb hash)."
  echo "series=$SERIES"
  echo "shim-signed=$shim_ver"
  echo "grub-efi-amd64-signed=$grub_ver"
  echo "shim-signed.deb.sha256=$(sha256sum < "$shim_deb" | cut -d' ' -f1)"
  echo "grub-efi-amd64-signed.deb.sha256=$(sha256sum < "$grub_deb" | cut -d' ' -f1)"
  echo "canonical-uefi-ca.pem.sha256=$(sha256sum < "$out/canonical-uefi-ca.pem" | cut -d' ' -f1)"
  for f in shimx64.efi grubx64.efi mmx64.efi; do
    echo "$f.sha256=$(sha256sum < "$out/$f" | cut -d' ' -f1)"
    echo "$f.from=${PKG[$f]}:${SRC[$f]}"
    echo "$f.sbat=$(sbat "$out/$f")"
  done
} > "$lock"

if [ -n "$expect" ]; then
  for f in shimx64.efi grubx64.efi mmx64.efi; do
    want="$(lock_get "$f.sha256")"
    got="$(sed -n "s/^$f.sha256=//p" "$lock")"
    [ "$want" = "$got" ] || { echo "$f sha256 $got != expected $want ($expect)" >&2; exit 1; }
  done
fi

echo "fetched the Secure Boot chain into $out:"
echo "  shim-signed $shim_ver, grub-efi-amd64-signed $grub_ver"
for f in shimx64.efi grubx64.efi mmx64.efi; do
  printf '  %-12s sha256 %s  (%s)\n' "$f" "$(sed -n "s/^$f.sha256=//p" "$lock")" "${SIGNER[$f]}"
done
echo "  lock file: $lock"
