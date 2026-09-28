#!/usr/bin/env bash
# Build the Companion Stick bootloader: a standalone x86_64 UEFI GRUB (BOOTX64.EFI).
#
#   stick/scripts/build-grub-efi.sh <out/BOOTX64.EFI>
#
# Needs grub-mkstandalone and the x86_64-efi modules (Debian/Ubuntu: grub-efi-amd64-bin,
# grub-common). No root.
#
# The binary embeds (in a memdisk) only the GRUB modules below and a tiny loader config.
# That config works out which partition the firmware loaded us from ($cmdpath, e.g.
# "(hd1,gpt1)/EFI/BOOT") and hands over to ci-stick/grub.cfg on that same ESP, which
# `ci-stick flash` generates from the layout plan. Everything stick-specific (slots,
# kernel command lines, the A/B pointer in ci-stick/grubenv) lives in that file, so this
# binary does not change when the layout or the boot entries do.
#
# NOT SECURE BOOT SIGNED. This is the *development* boot chain (QEMU tests, development
# sticks): firmware with Secure Boot enabled refuses it, and `ci-stick flash --device`
# needs --allow-unsigned-bootloader for it. Real sticks use the Secure Boot chain (shim ->
# Canonical GRUB) from stick/scripts/fetch-signed-boot.sh; see
# docs/architecture/companion-stick.md, "Secure Boot".
set -euo pipefail

out="${1:?usage: build-grub-efi.sh <out/BOOTX64.EFI>}"
command -v grub-mkstandalone >/dev/null \
  || { echo "grub-mkstandalone not found (apt-get install grub-common grub-efi-amd64-bin)" >&2; exit 2; }
moddir=/usr/lib/grub/x86_64-efi
[ -d "$moddir" ] || { echo "$moddir missing (apt-get install grub-efi-amd64-bin)" >&2; exit 2; }

modules=(part_gpt part_msdos fat iso9660 ext2 search search_label search_fs_file regexp
         loadenv linux normal configfile echo test all_video gfxterm sleep)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/embedded.cfg" <<'EOF'
# Companion Stick loader (embedded in BOOTX64.EFI). Finds the ESP we were loaded from
# and runs its ci-stick/grub.cfg. Built by stick/scripts/build-grub-efi.sh.
insmod part_gpt
insmod fat
insmod regexp
insmod configfile
set ci_esp=
regexp --set=1:ci_esp '^(\([^)]+\))' "$cmdpath"
if [ -z "$ci_esp" -o ! -f "$ci_esp/ci-stick/grub.cfg" ]; then
  search --no-floppy --label CI-EFI --set=ci_esp_dev
  if [ -n "$ci_esp_dev" ]; then set ci_esp="($ci_esp_dev)"; fi
fi
if [ -f "$ci_esp/ci-stick/grub.cfg" ]; then
  configfile "$ci_esp/ci-stick/grub.cfg"
fi
echo "Companion Stick: ci-stick/grub.cfg not found (cmdpath=$cmdpath)."
sleep 30
EOF

mkdir -p "$(dirname "$out")"
# SOURCE_DATE_EPOCH keeps the memdisk tar timestamps stable where grub supports it.
grub-mkstandalone -O x86_64-efi \
  --modules="${modules[*]}" \
  --install-modules="${modules[*]}" \
  --locales="" --themes="" --fonts="" \
  -o "$out" \
  "boot/grub/grub.cfg=$tmp/embedded.cfg"

echo "built $out ($(stat -c %s "$out") bytes, NOT Secure Boot signed)"
