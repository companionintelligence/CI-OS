#!/usr/bin/env bash
#=============================================================================
# Test: the checks of verify-iso.sh can fail, and pass when they should
#
# verify-iso.sh needs a 3 GB ISO, xorriso and unsquashfs, so nothing could catch a check that is vacuous (always passes)
# or broken (always fails) until a build had finished. This test sources the script and drives each check function on
# small synthetic inputs, in pairs: a GOOD fixture that must produce no FAIL and at least one PASS, then the same fixture
# with one thing wrong that must produce a FAIL naming it. The pair is what proves a check can see its bug.
#
# Covered: ISO file name, volume label, publisher / application, El Torito and MBR/GPT reports, size, the files an archiso
# boot needs, the search uuid and the standalone GRUB, GRUB and syslinux menus (titles, default, background, kernel lines,
# parity with the pinned upstream), artwork hashes, os-release (D4) and its pacman hook, lsb-release, sshd mask (D7), the
# About-System file, the installer launcher and calamares-online.sh (D6), the cachyos-hello gate, the cachy-update check, the package list, file
# modes, the build record, sha256 / sha512 files, the squashfs listing parser, and the Calamares overlay analysis (a
# fixture tree and thirteen mutations of it; needs python3 with PyYAML, otherwise listed as SKIPPED).
#
# No Docker, no root, no network, no xorriso: awk, sed, grep, od, a hash tool and bash 3.2 are enough, so core/lib/check-repo.sh
# can run it on a stock macOS. A real ISO is the job of verify-iso.sh itself (backends/cachyos/README.md).
#
#   backends/cachyos/iso/tests/verify-selftest.sh
#
# Exit status is non-zero if any check fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
# No pipefail on purpose, as in verify-iso.sh: grep -q ends pipelines early.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$HERE/../scripts/verify-iso.sh"
[ -f "$VERIFY" ] || { echo "verify-iso.sh not found next to the tests: $VERIFY" >&2; exit 2; }
for t in awk sed grep od tr head cut sort comm; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || { echo "missing tool: sha256sum or shasum" >&2; exit 2; }
command -v sha512sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || { echo "missing tool: sha512sum or shasum" >&2; exit 2; }

T_PASS=0; T_FAIL=0; T_SKIP=0
t_pass() { T_PASS=$((T_PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { T_FAIL=$((T_FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { T_SKIP=$((T_SKIP + 1)); printf 'info  SKIPPED: %s\n' "$*"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# shellcheck source=../scripts/verify-iso.sh
. "$VERIFY"
if [ "${BASH_SOURCE[0]}" != "$0" ]; then :; fi
# Sourcing must not have run anything: no counters, no output of its own.
[ "$PASS$FAIL" = "00" ] && t_pass "sourcing verify-iso.sh runs nothing" || t_fail "sourcing verify-iso.sh ran checks (PASS=$PASS FAIL=$FAIL)"

OUT=""; V_P=0; V_F=0
# vrun fn args...: run a verify-iso.sh function in this shell (its counters are the result) and keep its output.
vrun() {
    PASS=0; FAIL=0; SKIPPED=()
    "$@" > "$WORK/vrun.out" 2>&1
    V_P=$PASS; V_F=$FAIL
    OUT="$(cat "$WORK/vrun.out")"
}
# env_require_clean fn args...: run fn with VERIFY_REQUIRE_CLEAN=1 (a function runs in this shell, so set and unset the variable).
# shellcheck disable=SC2034  # read by v_check_buildinfo
env_require_clean() { local rc; VERIFY_REQUIRE_CLEAN=1; "$@"; rc=$?; unset VERIFY_REQUIRE_CLEAN; return $rc; }
# good LABEL fn args...: no FAIL and at least one PASS.
good() {
    local label="$1"; shift
    vrun "$@"
    if [ "$V_F" -eq 0 ] && [ "$V_P" -ge 1 ]; then t_pass "good: $label ($V_P checks passed)"
    else t_fail "good: $label expected no FAIL and a PASS, got $V_P passed, $V_F failed:"; printf '%s\n' "$OUT" | grep -E '^FAIL' | head -n 8 | sed 's/^/      /'; fi
}
# bad LABEL REGEX fn args...: at least one FAIL line that matches REGEX.
bad() {
    local label="$1" re="$2"; shift 2
    vrun "$@"
    if [ "$V_F" -ge 1 ] && printf '%s\n' "$OUT" | grep -E '^FAIL' | grep -q -E "$re"; then t_pass "bites: $label"
    else t_fail "bites: $label expected a FAIL matching /$re/, got $V_P passed, $V_F failed:"; printf '%s\n' "$OUT" | head -n 8 | sed 's/^/      /'; fi
}
# ok_out LABEL REGEX: the last vrun produced a line matching REGEX (any kind).
ok_out() {
    if printf '%s\n' "$OUT" | grep -q -E "$2"; then t_pass "$1"; else t_fail "$1 (no line matches /$2/):"; printf '%s\n' "$OUT" | head -n 6 | sed 's/^/      /'; fi
}
# mut FILE SED-EXPR: edit a fixture in place (BSD and GNU sed both accept -i with a backup suffix).
mut() { sed -i.bak "$2" "$1" && rm -f "$1.bak"; }

be32() { printf '\\%03o\\%03o\\%03o\\%03o' $(($1 >> 24 & 255)) $(($1 >> 16 & 255)) $(($1 >> 8 & 255)) $(($1 & 255)); }
# mk_png FILE WIDTH HEIGHT [DEPTH] [PADDING_BYTES]: a PNG header that v_png_info reads (the image data is padding).
mk_png() {
    {
        printf '\211PNG\r\n\032\n'
        printf '\000\000\000\015IHDR'
        # shellcheck disable=SC2059
        printf "$(be32 "$2")"
        # shellcheck disable=SC2059
        printf "$(be32 "$3")"
        # shellcheck disable=SC2059
        printf "\\$(printf '%03o' "${4:-8}")\\002\\000\\000\\000"
        head -c "${5:-6000}" /dev/zero | tr '\0' 'x'
    } > "$1"
}

#=== names, label, publisher =====================================================================================
good "ISO file name companion-os-plasma-<date>-x86_64.iso" v_check_iso_name companion-os-plasma-2026.10.14-x86_64.iso
good "a .partial image is judged by its final name" v_check_iso_name companion-os-plasma-2026.10.14-x86_64.iso.partial
bad "the research demo's name (CachyOS mark, no plasma)" "not companion-os-plasma" v_check_iso_name companion-os-cachyos-2026.10.03-x86_64.iso
bad "the CachyOS mark in the name is called out" "CachyOS mark" v_check_iso_name companion-os-cachyos-2026.10.03-x86_64.iso
bad "a name without the date" "not companion-os-plasma" v_check_iso_name companion-os-plasma-x86_64.iso
bad "an upper-case name" "not companion-os-plasma" v_check_iso_name Companion-OS-plasma-2026.10.14-x86_64.iso

good "label COMPANION_202610, version 2026.10.03" v_check_label COMPANION_202610 2026.10.03
bad "upstream's label COS_202610" "not COMPANION_" v_check_label COS_202610 2026.10.03
bad "a label of the wrong month" "month" v_check_label COMPANION_202609 2026.10.03
bad "a 33 character label" "33 characters" v_check_label COMPANION_20261012345678901234567 2026.10.03
bad "a 4 digit date in the label" "not COMPANION_" v_check_label COMPANION_2026 2026.10.03

good "publisher and application as D1 (stored upper case)" v_check_pvd 'COMPANION INTELLIGENCE <HTTPS://CI.COMPUTER>' 'COMPANION OS LIVE/INSTALLER'
good "publisher and application as D1 (mixed case)" v_check_pvd 'Companion Intelligence <https://ci.computer>' 'Companion OS Live/Installer'
bad "the demo's publisher" "publisher is" v_check_pvd 'COMPANION INTELLIGENCE <HTTPS://COMPANIONINTELLIGENCE.EXAMPLE>' 'COMPANION OS LIVE/INSTALLER'
bad "the demo's application names CachyOS" "names CachyOS" v_check_pvd 'COMPANION INTELLIGENCE <HTTPS://CI.COMPUTER>' 'COMPANION OS (CACHYOS EDITION) LIVE/INSTALL'

#=== boot records, size, files, uuid =============================================================================
cat > "$WORK/et.good" <<'EOF'
El Torito catalog  : 106  1
El Torito images   :   N  Pltf  B   Emul  Ld_seg  Hdpt  Ldsiz         LBA
El Torito boot img :   1  BIOS  y   none  0x0000  0x00      4         107
El Torito boot img :   2  UEFI  y   none  0x0000  0x00  49152     1499968
El Torito img path :   1  /boot/syslinux/isolinux.bin
EOF
cat > "$WORK/sa.good" <<'EOF'
System area summary: MBR isohybrid cyl-align-off GPT
MBR partition table:   N Status  Type        Start       Blocks
MBR partition      :   1   0x80  0x00           64      5999808
MBR partition      :   2   0x00  0xef      5999872        49152
GPT                :   N  Info
GPT partition name :   1  490053004f00480079006200720069006400
EOF
good "El Torito BIOS + UEFI, MBR active + 0xef, GPT (report text from the demo ISO)" v_check_boot_records "$WORK/et.good" "$WORK/sa.good"
grep -v 'UEFI' "$WORK/et.good" > "$WORK/et.nouefi"
bad "no UEFI El Torito image" "no UEFI boot image" v_check_boot_records "$WORK/et.nouefi" "$WORK/sa.good"
grep -v 'BIOS' "$WORK/et.good" > "$WORK/et.nobios"
bad "no BIOS El Torito image" "no BIOS boot image" v_check_boot_records "$WORK/et.nobios" "$WORK/sa.good"
sed 's/0x80/0x00/' "$WORK/sa.good" > "$WORK/sa.noactive"
bad "no active MBR partition (not isohybrid)" "no active" v_check_boot_records "$WORK/et.good" "$WORK/sa.noactive"
grep -v '^GPT\|GPT partition' "$WORK/sa.good" > "$WORK/sa.nogpt"
bad "no GPT" "no GPT" v_check_boot_records "$WORK/et.good" "$WORK/sa.nogpt"

good "size 2953 MiB in 1500..6144" v_check_size 3096576000 1500 6144
bad "size 100 MiB" "outside" v_check_size 104857600 1500 6144
bad "size 9 GiB" "outside" v_check_size 9663676416 1500 6144
bad "size not a multiple of 2048" "multiple of 2048" v_check_size 3096576001 1500 6144

: > "$WORK/fl.good"
for p in /arch/x86_64/airootfs.sfs /arch/x86_64/airootfs.sha512 /arch/boot/x86_64/vmlinuz-linux-cachyos /arch/boot/x86_64/initramfs-linux-cachyos.img \
         /arch/boot/x86_64/vmlinuz-linux-cachyos-lts /arch/boot/x86_64/initramfs-linux-cachyos-lts.img /arch/pkglist.x86_64.txt /arch/version \
         /EFI/BOOT/BOOTx64.EFI /boot/grub/grub.cfg /boot/grub/loopback.cfg /boot/syslinux/syslinux.cfg /boot/syslinux/isolinux.bin \
         /boot/syslinux/archiso_head.cfg /boot/syslinux/archiso_sys-linux.cfg /boot/syslinux/splash.png /boot/syslinux/chain.c32 \
         /boot/syslinux/reboot.c32 /boot/syslinux/poweroff.c32 /boot/memtest86+/memtest /boot/grub/companion-bg.png /boot/2026-10-03-15-31-30-00.uuid; do
    echo "$p" >> "$WORK/fl.good"
done
good "every file an archiso boot needs" v_check_medium_files "$WORK/fl.good"
grep -v 'initramfs-linux-cachyos-lts' "$WORK/fl.good" > "$WORK/fl.noinitrd"
bad "the LTS initramfs is missing" "initramfs-linux-cachyos-lts" v_check_medium_files "$WORK/fl.noinitrd"
if [ "$(v_uuid_of "$WORK/fl.good")" = "2026-10-03-15-31-30-00" ]; then t_pass "v_uuid_of reads the one search file"; else t_fail "v_uuid_of did not return 2026-10-03-15-31-30-00"; fi
{ cat "$WORK/fl.good"; echo /boot/2026-10-04-00-00-00-00.uuid; } > "$WORK/fl.twouuid"
if v_uuid_of "$WORK/fl.twouuid" >/dev/null; then t_fail "v_uuid_of accepted two search files"; else t_pass "v_uuid_of refuses two search files"; fi
grep -v '\.uuid$' "$WORK/fl.good" > "$WORK/fl.nouuid"
if v_uuid_of "$WORK/fl.nouuid" >/dev/null; then t_fail "v_uuid_of accepted no search file"; else t_pass "v_uuid_of refuses no search file"; fi

printf 'MZ\000\000padding /boot/2026-10-03-15-31-30-00.uuid more' > "$WORK/efi.good"
good "BOOTx64.EFI embeds the uuid file name" v_check_efi_search "$WORK/efi.good" 2026-10-03-15-31-30-00
bad "BOOTx64.EFI searches for another uuid" "does not mention" v_check_efi_search "$WORK/efi.good" 2026-10-04-00-00-00-00
printf 'ELF\000 /boot/2026-10-03-15-31-30-00.uuid' > "$WORK/efi.notpe"
bad "BOOTx64.EFI that is not a PE file" "not a PE" v_check_efi_search "$WORK/efi.notpe" 2026-10-03-15-31-30-00

#=== GRUB menus ===================================================================================================
UUID=2026-10-03-15-31-30-00
KP="archisobasedir=arch archisosearchuuid=$UUID cow_spacesize=10G copytoram=auto module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 nvme_load=yes"
mk_grub() { # mk_grub OUT
    cat > "$1" <<EOF
COMPANION_VERSION="2026.10.14"
set menu_color_normal=white/black
set menu_color_highlight=black/cyan
background_image /boot/grub/companion-bg.png
default=companion
timeout=10
menuentry "Welcome to Companion OS \$COMPANION_VERSION Live ISO" {
insmod ext2
}
menuentry "Companion OS" --class gnu-linux --id 'companion' {
    set gfxpayload=keep
    linux /arch/boot/x86_64/vmlinuz-linux-cachyos $KP
    initrd /arch/boot/x86_64/initramfs-linux-cachyos.img
}
menuentry "Companion OS (LTS kernel)" --class gnu-linux --id 'companion-lts' {
    linux /arch/boot/x86_64/vmlinuz-linux-cachyos-lts $KP
    initrd /arch/boot/x86_64/initramfs-linux-cachyos-lts.img
}
menuentry "Companion OS (legacy hardware, nomodeset)" --class gnu-linux --id 'companion-fallback' {
    linux /arch/boot/x86_64/vmlinuz-linux-cachyos-lts archisobasedir=arch archisosearchuuid=$UUID nomodeset
    initrd /arch/boot/x86_64/initramfs-linux-cachyos-lts.img
}
menuentry 'System restart' --class reboot {
    reboot
}
EOF
}
mk_grub "$WORK/grub.good"
good "a Companion grub.cfg" v_check_grub_cfg "$WORK/grub.good" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g1"; mut "$WORK/g1" 's/menuentry "Companion OS" /menuentry "CachyOS" /'
bad "a menu title that says CachyOS" "still name CachyOS" v_check_grub_cfg "$WORK/g1" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g2"; mut "$WORK/g2" 's/Companion OS//g'
bad "no title says Companion OS" "no menu title says Companion OS" v_check_grub_cfg "$WORK/g2" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g3"; mut "$WORK/g3" '/^background_image/d'
bad "no background_image" "no background_image" v_check_grub_cfg "$WORK/g3" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g3b"; mut "$WORK/g3b" 's#/boot/grub/companion-bg.png#/boot/grub/missing.png#'
bad "background_image names a file that is not on the medium" "not on the medium" v_check_grub_cfg "$WORK/g3b" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g4"; mut "$WORK/g4" 's/^default=companion$/default=cachyos/'
bad "default= names no entry" "names no menu entry" v_check_grub_cfg "$WORK/g4" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g5"; mut "$WORK/g5" 's/archisosearchuuid=[0-9-]*/archisosearchuuid=1999-01-01-00-00-00-00/'
bad "kernel lines with another uuid" "lacks archisobasedir=arch or archisosearchuuid" v_check_grub_cfg "$WORK/g5" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g6"; mut "$WORK/g6" 's/archisobasedir=arch //'
bad "kernel lines without archisobasedir" "lacks archisobasedir=arch" v_check_grub_cfg "$WORK/g6" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g7"; mut "$WORK/g7" 's#vmlinuz-linux-cachyos-lts#vmlinuz-gone#'
bad "a kernel that is not on the medium" "is not on the medium" v_check_grub_cfg "$WORK/g7" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g8"; mut "$WORK/g8" 's/COMPANION_VERSION="2026.10.14"/COMPANION_VERSION="GIT"/; s/Live ISO/GIT Live ISO/'
bad "the raw upstream placeholder GIT in a title" "placeholder" v_check_grub_cfg "$WORK/g8" grub.cfg "$WORK/fl.good" $UUID 1
cp "$WORK/grub.good" "$WORK/g9"; mut "$WORK/g9" '/^set menu_color_/d'
bad "no menu colours" "menu_color" v_check_grub_cfg "$WORK/g9" grub.cfg "$WORK/fl.good" $UUID 1
sed -e '/^background_image/d' -e '/^set menu_color/d' "$WORK/grub.good" > "$WORK/loop.good"
mut "$WORK/loop.good" 's/archisosearchuuid=[0-9-]*/img_dev=UUID=${archiso_img_dev_uuid} img_loop="${iso_path}"/'
good "a Companion loopback.cfg (no background needed)" v_check_grub_cfg "$WORK/loop.good" loopback.cfg "$WORK/fl.good" $UUID 0
cp "$WORK/loop.good" "$WORK/loop.bad"; mut "$WORK/loop.bad" 's/img_loop="${iso_path}"//'
bad "loopback.cfg without img_loop" "img_dev=/img_loop" v_check_grub_cfg "$WORK/loop.bad" loopback.cfg "$WORK/fl.good" $UUID 0

#=== kernel line parity with the upstream ==========================================================================
cat > "$WORK/up.tmpl" <<'EOF'
menuentry "CachyOS" --id 'cachyos' {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux-cachyos archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% cow_spacesize=10G copytoram=auto module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 nvme_load=yes
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux-cachyos.img
}
menuentry "CachyOS LTS Kernel" --id 'cachyos-lts' {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux-cachyos-lts archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% cow_spacesize=10G copytoram=auto module_blacklist=pcspkr i915.modeset=1 amdgpu.modeset=1 nvme_load=yes
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux-cachyos-lts.img
}
EOF
v_subst_upstream "$WORK/up.tmpl" arch x86_64 $UUID > "$WORK/up.sub"
if grep -q '%' "$WORK/up.sub"; then t_fail "v_subst_upstream left a % placeholder"; else t_pass "v_subst_upstream resolves INSTALL_DIR, ARCH and ARCHISO_UUID"; fi
GRE='^[[:space:]]*(linux|initrd)[[:space:]]+/arch/'
good "all upstream kernel lines are in the ISO (extra Companion entries allowed)" v_check_parity "$WORK/grub.good" "$WORK/up.sub" parity "$GRE"
ok_out "the extra Companion lines are reported, not failed" "Companion additions"
cp "$WORK/grub.good" "$WORK/p1"; mut "$WORK/p1" 's/ copytoram=auto//'
bad "an upstream kernel line changed (copytoram removed)" "upstream line is not in the ISO" v_check_parity "$WORK/p1" "$WORK/up.sub" parity "$GRE"
cp "$WORK/grub.good" "$WORK/p2"; mut "$WORK/p2" 's/ nvme_load=yes/ nvme_load=yes quiet splash/'
bad "a parameter added to an upstream line" "upstream line is not in the ISO" v_check_parity "$WORK/p2" "$WORK/up.sub" parity "$GRE"
VERIFY_GRUB_EXTRA_PARAMS="quiet splash" good "the added parameters are allowed by VERIFY_GRUB_EXTRA_PARAMS" v_check_parity "$WORK/p2" "$WORK/up.sub" parity "$GRE"
: > "$WORK/empty.cfg"
bad "an upstream file without kernel lines" "no kernel / initrd lines" v_check_parity "$WORK/grub.good" "$WORK/empty.cfg" parity "$GRE"

#=== syslinux ======================================================================================================
SD="$WORK/syslinux"
mk_syslinux() { # mk_syslinux DIR
    mkdir -p "$1"
    cat > "$1/archiso_head.cfg" <<'EOF'
SERIAL 0 115200
UI vesamenu.c32
MENU TITLE Companion OS
MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
EOF
    cat > "$1/archiso_sys.cfg" <<'EOF'
INCLUDE archiso_head.cfg

DEFAULT cos64
TIMEOUT 150

INCLUDE archiso_sys-linux.cfg

INCLUDE archiso_tail.cfg
EOF
    cat > "$1/archiso_sys-linux.cfg" <<EOF
LABEL cos64
TEXT HELP
Boot the Companion OS install medium on BIOS.
ENDTEXT
MENU LABEL Companion OS (x86_64, BIOS)
LINUX /arch/boot/x86_64/vmlinuz-linux-cachyos-lts
INITRD /arch/boot/x86_64/initramfs-linux-cachyos-lts.img
APPEND $KP
EOF
    cat > "$1/archiso_tail.cfg" <<'EOF'
LABEL memtest
MENU LABEL Run Memtest86+ (RAM test)
LINUX /boot/memtest86+/memtest

LABEL hdt
MENU LABEL Hardware Information (HDT)
COM32 chain.c32

LABEL reboot
MENU LABEL Reboot
COM32 reboot.c32
EOF
    mk_png "$1/splash.png" 640 480
}
mk_syslinux "$SD"
good "a Companion syslinux menu (640x480 background)" v_check_syslinux "$SD" "$WORK/fl.good" $UUID
cp -R "$SD" "$WORK/sl1"; mut "$WORK/sl1/archiso_head.cfg" 's/^MENU TITLE .*/MENU TITLE CachyOS/'
bad "MENU TITLE CachyOS" "MENU TITLE is" v_check_syslinux "$WORK/sl1" "$WORK/fl.good" $UUID
cp -R "$SD" "$WORK/sl2"; mut "$WORK/sl2/archiso_sys-linux.cfg" 's/^MENU LABEL .*/MENU LABEL CachyOS default/'
bad "a MENU LABEL that says CachyOS" "CachyOS or Arch words" v_check_syslinux "$WORK/sl2" "$WORK/fl.good" $UUID
cp -R "$SD" "$WORK/sl3"; mut "$WORK/sl3/archiso_sys.cfg" 's/^DEFAULT .*/DEFAULT arch64/'
bad "DEFAULT names a label that does not exist (upstream's defect)" "DEFAULT 'arch64' names no LABEL" v_check_syslinux "$WORK/sl3" "$WORK/fl.good" $UUID
cp -R "$SD" "$WORK/sl4"; mut "$WORK/sl4/archiso_tail.cfg" 's#/boot/memtest86+/memtest#/arch/boot/memtest#'
bad "the memtest path that does not exist on the medium (upstream's defect)" "memtest" v_check_syslinux "$WORK/sl4" "$WORK/fl.good" $UUID
cp -R "$SD" "$WORK/sl5"; mk_png "$WORK/sl5/splash.png" 1920 1080
bad "a 1920x1080 background in the 640x480 menu" "menu mode is 640x480" v_check_syslinux "$WORK/sl5" "$WORK/fl.good" $UUID
cp -R "$SD" "$WORK/sl6"; mk_png "$WORK/sl6/splash.png" 1920 1080; printf 'MENU RESOLUTION 1920 1080\n' >> "$WORK/sl6/archiso_head.cfg"
good "a 1920x1080 background with MENU RESOLUTION 1920 1080" v_check_syslinux "$WORK/sl6" "$WORK/fl.good" $UUID
cp -R "$SD" "$WORK/sl7"; mut "$WORK/sl7/archiso_sys-linux.cfg" 's/archisosearchuuid=[0-9-]*/archisosearchuuid=1999-01-01-00-00-00-00/'
bad "an APPEND line with another uuid" "APPEND line lacks" v_check_syslinux "$WORK/sl7" "$WORK/fl.good" $UUID
cp -R "$SD" "$WORK/sl8"; printf 'not a png' > "$WORK/sl8/splash.png"
bad "a background that is not a PNG" "not a PNG" v_check_syslinux "$WORK/sl8" "$WORK/fl.good" $UUID

#=== artwork ======================================================================================================
mk_png "$WORK/art.ours" 640 480 8 3000
cp "$WORK/art.ours" "$WORK/art.ours2"
good "boot-menu images that are not upstream's" v_check_art_hashes "$WORK/art.ours" "$WORK/art.ours2"
# The check compares hashes with the pinned upstream splash; plant a file with that hash by overriding the list.
V_UPSTREAM_ART_SHA256_SAVE="$V_UPSTREAM_ART_SHA256"
V_UPSTREAM_ART_SHA256="$V_UPSTREAM_ART_SHA256 $(v_sha256 "$WORK/art.ours")"
bad "an image whose hash is upstream's CachyOS artwork" "CachyOS artwork is on the medium" v_check_art_hashes "$WORK/art.ours"
V_UPSTREAM_ART_SHA256="$V_UPSTREAM_ART_SHA256_SAVE"
bad "no image to look at" "no boot-menu image" v_check_art_hashes "$WORK/does-not-exist"

#=== os-release, hook, lsb-release ===================================================================================
cat > "$WORK/osr.good" <<'EOF'
NAME="Companion OS"
PRETTY_NAME="Companion OS 0.1.0"
ID=cachyos
ID_LIKE=arch
BUILD_ID=rolling
VARIANT="Plasma (based on CachyOS)"
ANSI_COLOR="38;2;197;232;220"
HOME_URL="https://ci.computer"
DOCUMENTATION_URL="https://docs.ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
LOGO=ci-os-logo
CI_OS_ID=ci-os
CI_OS_VERSION="0.1.0"
CI_OS_BUILD="20261014"
IMAGE_ID=companion-os-plasma
IMAGE_VERSION=2026.10.14
EOF
good "a D4 os-release" v_check_os_release "$WORK/osr.good" 2026.10.14
osr_bad() { # osr_bad LABEL REGEX SED-EXPR
    cp "$WORK/osr.good" "$WORK/osr.bad"; mut "$WORK/osr.bad" "$3"
    bad "os-release: $1" "$2" v_check_os_release "$WORK/osr.bad" 2026.10.14
}
osr_bad "NAME CachyOS Linux (what cachyos-hooks writes)" "NAME=" 's/^NAME=.*/NAME="CachyOS Linux"/'
osr_bad "PRETTY_NAME without the version" "PRETTY_NAME=" 's/^PRETTY_NAME=.*/PRETTY_NAME="Companion OS"/'
osr_bad "ID changed to companion-os (D4 keeps cachyos)" "ID='companion-os'|os-release ID=" 's/^ID=cachyos$/ID=companion-os/'
osr_bad "ID_LIKE with two tokens (CI-Hub string-matches it)" "ID_LIKE=" 's/^ID_LIKE=arch$/ID_LIKE="cachyos arch"/'
osr_bad "VARIANT missing" "VARIANT=" '/^VARIANT=/d'
osr_bad "HOME_URL on cachyos.org" "HOME_URL=" 's#^HOME_URL=.*#HOME_URL="https://cachyos.org/"#'
osr_bad "SUPPORT_URL missing" "SUPPORT_URL=" '/^SUPPORT_URL=/d'
osr_bad "LOGO=cachyos" "LOGO=" 's/^LOGO=.*/LOGO=cachyos/'
osr_bad "ANSI_COLOR in the wrong form" "ANSI_COLOR=" 's/^ANSI_COLOR=.*/ANSI_COLOR="blue"/'
osr_bad "ANSI_COLOR is CachyOS's blue" "CachyOS's blue" 's/^ANSI_COLOR=.*/ANSI_COLOR="38;2;23;147;209"/'
printf 'CI_DARK_PRIMARY="#c5e8dc"\nCI_DARK_GROUND="#041620"\n' > "$WORK/tokens.sh"
if [ "$(v_token_ansi "$WORK/tokens.sh")" = "38;2;197;232;220" ]; then t_pass "v_token_ansi converts CI_DARK_PRIMARY #c5e8dc to 38;2;197;232;220"; else t_fail "v_token_ansi returned '$(v_token_ansi "$WORK/tokens.sh")'"; fi
if v_token_ansi "$WORK/no-tokens.sh" >/dev/null; then t_fail "v_token_ansi accepted a missing tokens file"; else t_pass "v_token_ansi fails for a missing tokens file"; fi
good "os-release ANSI_COLOR equals the token colour" v_check_os_release "$WORK/osr.good" 2026.10.14 "38;2;197;232;220"
bad "os-release ANSI_COLOR differs from the token colour" "not the brand token" v_check_os_release "$WORK/osr.good" 2026.10.14 "38;2;1;2;3"
osr_bad "CI_OS_ID missing" "CI_OS_ID=" '/^CI_OS_ID=/d'
osr_bad "CI_OS_BUILD not a day" "CI_OS_BUILD=" 's/^CI_OS_BUILD=.*/CI_OS_BUILD="soon"/'
osr_bad "IMAGE_ID of the demo (CachyOS in the name)" "IMAGE_ID=" 's/^IMAGE_ID=.*/IMAGE_ID=companion-os-cachyos/'
osr_bad "IMAGE_VERSION of another build" "IMAGE_VERSION=" 's/^IMAGE_VERSION=.*/IMAGE_VERSION=2026.01.01/'
osr_bad "CachyOS in DOCUMENTATION_URL" "outside ID and VARIANT" 's#^DOCUMENTATION_URL=.*#DOCUMENTATION_URL="https://wiki.cachyos.org/"#'
osr_bad "Arch Linux in a field" "Arch Linux" 's/^BUILD_ID=rolling$/BUILD_ID=rolling\nDOCUMENTATION_URL2="https:\/\/wiki.archlinux.org\/ Arch Linux"/'
: > "$WORK/osr.empty"
bad "an empty os-release" "missing or empty" v_check_os_release "$WORK/osr.empty"
if [ "$(v_osrel_get "$WORK/osr.good" VARIANT)" = "Plasma (based on CachyOS)" ]; then t_pass "v_osrel_get removes the quotes"; else t_fail "v_osrel_get returned '$(v_osrel_get "$WORK/osr.good" VARIANT)'"; fi

cat > "$WORK/zz.hook" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = filesystem
Target = lsb-release
Target = cachyos-hooks

[Action]
Description = Writing the Companion OS identity...
When = PostTransaction
Exec = /usr/bin/bash /usr/share/libalpm/scripts/zz-ci-os-os-release
EOF
cp "$WORK/zz.hook" "$WORK/zz-ci-os-os-release.hook"
good "the os-release hook" v_check_os_release_hook "$WORK/zz-ci-os-os-release.hook"
cp "$WORK/zz.hook" "$WORK/aa-ci-os-os-release.hook"
bad "a hook that sorts before cachyos-hooks' (it would be overwritten)" "sorts before" v_check_os_release_hook "$WORK/aa-ci-os-os-release.hook"
cp "$WORK/zz.hook" "$WORK/zz-ci-os-os-release.hook"; mut "$WORK/zz-ci-os-os-release.hook" 's/^Target = filesystem$/Target = nothing/'
bad "a hook that does not trigger on filesystem" "Target = filesystem" v_check_os_release_hook "$WORK/zz-ci-os-os-release.hook"
cp "$WORK/zz.hook" "$WORK/zz-ci-os-os-release.hook"; mut "$WORK/zz-ci-os-os-release.hook" 's/^When = PostTransaction$/When = PreTransaction/'
bad "a hook that runs before the transaction" "PostTransaction" v_check_os_release_hook "$WORK/zz-ci-os-os-release.hook"
bad "a missing hook" "missing or empty" v_check_os_release_hook "$WORK/no-such.hook"

printf 'LSB_VERSION=1.4\nDISTRIB_ID=cachyos\nDISTRIB_RELEASE=rolling\nDISTRIB_DESCRIPTION="Companion OS 0.1.0"\n' > "$WORK/lsb.good"
good "lsb-release says Companion OS" v_check_lsb_release "$WORK/lsb.good"
printf 'DISTRIB_ID=cachyos\nDISTRIB_DESCRIPTION="CachyOS"\n' > "$WORK/lsb.bad"
bad "lsb-release says CachyOS (cachyos-hooks' text)" "DISTRIB_DESCRIPTION" v_check_lsb_release "$WORK/lsb.bad"

#=== the squashfs listing, sshd, modes, hook exec =====================================================================
cat > "$WORK/raw.lst" <<'EOF'
dr-xr-xr-x root/root               271 2026-10-03 15:31 squashfs-root
lrwxrwxrwx root/root                 7 2025-10-12 16:21 squashfs-root/bin -> usr/bin
lrwxrwxrwx root/root                 9 2026-10-03 15:31 squashfs-root/etc/systemd/system/sshd.service -> /dev/null
-rwxr-xr-x root/root              1812 2026-10-03 15:31 squashfs-root/usr/local/bin/calamares-online.sh
-rw-r--r-- root/root               356 2026-10-03 15:31 squashfs-root/usr/local/bin/pkexec-wrapper
-rw-r--r-- root/root                12 2026-10-03 15:31 squashfs-root/usr/share/applications/with space.desktop
crw-rw-rw- root/root               1,3 2026-10-03 15:31 squashfs-root/dev/null
EOF
v_normalise_listing < "$WORK/raw.lst" > "$WORK/L"
if v_lst_has "$WORK/L" /usr/local/bin/calamares-online.sh && ! v_lst_has "$WORK/L" /usr/local/bin/nothing; then t_pass "listing: exact path lookup"; else t_fail "listing: exact path lookup"; fi
if [ "$(v_lst_target "$WORK/L" /etc/systemd/system/sshd.service)" = "/dev/null" ] && [ "$(v_lst_target "$WORK/L" /bin)" = "usr/bin" ]; then t_pass "listing: symlink targets"; else t_fail "listing: symlink targets"; fi
if [ "$(v_lst_mode "$WORK/L" /usr/local/bin/pkexec-wrapper)" = "-rw-r--r--" ] && [ "$(v_lst_size "$WORK/L" /usr/local/bin/calamares-online.sh)" = 1812 ]; then t_pass "listing: mode and size"; else t_fail "listing: mode and size"; fi
if v_lst_has "$WORK/L" "/usr/share/applications/with space.desktop"; then t_pass "listing: a path with a space"; else t_fail "listing: a path with a space"; fi
if v_lst_prefix "$WORK/L" /usr/local && ! v_lst_prefix "$WORK/L" /opt; then t_pass "listing: v_lst_prefix"; else t_fail "listing: v_lst_prefix"; fi
for m in -rwxr-xr-x -rwx------ -r-xr-xr-x -rwsr-xr-x -rw-r-xr-- -rw-rw-r-x; do
    if v_mode_is_exec "$m"; then t_pass "v_mode_is_exec $m"; else t_fail "v_mode_is_exec $m should be executable"; fi
done
for m in -rw-r--r-- -r--r----- -rw------- drwxr-xr-x-nope-; do
    case "$m" in drwxr-xr-x-nope-) continue ;; esac
    if v_mode_is_exec "$m"; then t_fail "v_mode_is_exec $m should not be executable"; else t_pass "v_mode_is_exec $m is not executable"; fi
done

good "sshd.service masked" v_check_sshd_masked "$WORK/L"
printf -- '-rw-r--r--\t1\t/etc/systemd/system/multi-user.target.wants/sshd.service\t\n' > "$WORK/L.sshd"
bad "sshd not masked" "not masked" v_check_sshd_masked "$WORK/L.sshd"
printf -- 'lrwxrwxrwx\t9\t/etc/systemd/system/sshd.service\t/dev/null\nlrwxrwxrwx\t9\t/etc/systemd/system/sockets.target.wants/sshd.socket\t/usr/lib/systemd/system/sshd.socket\n' > "$WORK/L.sock"
bad "sshd.socket enabled although the service is masked" "sshd.socket is enabled" v_check_sshd_masked "$WORK/L.sock"

# modes: package-unowned scripts must be executable
mkdir -p "$WORK/rootm/usr/local/bin" "$WORK/rootm/usr/share/libalpm/scripts"
printf '#!/bin/bash\necho hi\n' > "$WORK/rootm/usr/local/bin/ours"
printf '#!/bin/bash\necho hi\n' > "$WORK/rootm/usr/local/bin/theirs"
printf '#!/bin/bash\necho hi\n' > "$WORK/rootm/usr/share/libalpm/scripts/zz-ci-os-os-release"
printf 'plain data\n' > "$WORK/rootm/usr/local/bin/data.txt"
printf '/usr/local/bin/theirs\n' > "$WORK/owned.txt"
printf -- '-rwxr-xr-x\t20\t/usr/local/bin/ours\t\n-rw-r--r--\t20\t/usr/local/bin/theirs\t\n-rw-r--r--\t11\t/usr/local/bin/data.txt\t\n-rwxr-xr-x\t20\t/usr/share/libalpm/scripts/zz-ci-os-os-release\t\n' > "$WORK/Lm.good"
good "our scripts are executable; a package's mode and plain data are left alone" v_check_modes "$WORK/Lm.good" "$WORK/rootm" "$WORK/owned.txt"
printf -- '-rw-r--r--\t20\t/usr/local/bin/ours\t\n-rw-r--r--\t20\t/usr/local/bin/theirs\t\n-rw-r--r--\t11\t/usr/local/bin/data.txt\t\n-rwxr-xr-x\t20\t/usr/share/libalpm/scripts/zz-ci-os-os-release\t\n' > "$WORK/Lm.bad"
bad "a #! script of ours without the exec bit (mkarchiso dropped the mode)" "script is not executable.*usr/local/bin/ours" v_check_modes "$WORK/Lm.bad" "$WORK/rootm" "$WORK/owned.txt"
printf -- '-rwxr-xr-x\t20\t/usr/local/bin/ours\t\n-rw-r--r--\t20\t/usr/local/bin/theirs\t\n-rw-r--r--\t11\t/usr/local/bin/data.txt\t\n-rw-r--r--\t20\t/usr/share/libalpm/scripts/zz-ci-os-os-release\t\n' > "$WORK/Lm.bad2"
bad "the os-release hook script without the exec bit" "zz-ci-os-os-release" v_check_modes "$WORK/Lm.bad2" "$WORK/rootm" "$WORK/owned.txt"
mkdir -p "$WORK/rootm/usr/share/ci-os/calamares/scripts"
printf '#!/bin/bash\necho staged\n' > "$WORK/rootm/usr/share/ci-os/calamares/scripts/ci-os-stage-target.sh"
{ cat "$WORK/Lm.good"; printf -- '-rw-r--r--\t20\t/usr/share/ci-os/calamares/scripts/ci-os-stage-target.sh\t\n'; } > "$WORK/Lm.staged"
good "scripts staged as data under /usr/share/ci-os/calamares are not judged" v_check_modes "$WORK/Lm.staged" "$WORK/rootm" "$WORK/owned.txt"
ok_out "...and the exemption is announced" "info  1 #! script"
good "v_check_perm: /etc/shadow 0400" v_check_perm <(printf -- '-r--------\t100\t/etc/shadow\t\n') /etc/shadow '^-r--------$' 0400
bad "v_check_perm: /etc/shadow world readable" "expected 0400" v_check_perm <(printf -- '-rw-r--r--\t100\t/etc/shadow\t\n') /etc/shadow '^-r--------$' 0400
# sshd drop-ins: the first value of each keyword decides
mkdir -p "$WORK/sshd.good" "$WORK/sshd.root" "$WORK/sshd.pw" "$WORK/sshd.none" "$WORK/sshd.first" "$WORK/sshd.later" "$WORK/sshd.empty"
printf '# live medium\nPermitRootLogin no\nPasswordAuthentication no\n' > "$WORK/sshd.good/10-archiso.conf"
printf 'PermitRootLogin yes\nPasswordAuthentication no\n' > "$WORK/sshd.root/10-archiso.conf"
printf 'PermitRootLogin no\nPasswordAuthentication yes\n' > "$WORK/sshd.pw/10-archiso.conf"
printf '# nothing set\n' > "$WORK/sshd.none/10-archiso.conf"
cp "$WORK/sshd.good/10-archiso.conf" "$WORK/sshd.first/10-archiso.conf"; printf 'PermitRootLogin yes\n' > "$WORK/sshd.first/05-early.conf"
cp "$WORK/sshd.good/10-archiso.conf" "$WORK/sshd.later/10-archiso.conf"; printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > "$WORK/sshd.later/99-late.conf"
good "sshd drop-ins forbid root and password logins" v_check_sshd_dropin "$WORK/sshd.good"
bad "sshd drop-in allows root login" "PermitRootLogin is 'yes'|first PermitRootLogin is 'yes'" v_check_sshd_dropin "$WORK/sshd.root"
bad "sshd drop-in allows password logins" "first PasswordAuthentication is 'yes'" v_check_sshd_dropin "$WORK/sshd.pw"
bad "sshd drop-in sets neither keyword" "first PermitRootLogin is '<not set>'" v_check_sshd_dropin "$WORK/sshd.none"
bad "an earlier drop-in wins over ours (sshd takes the first value)" "first PermitRootLogin is 'yes'" v_check_sshd_dropin "$WORK/sshd.first"
good "a later drop-in cannot override ours (the first value wins)" v_check_sshd_dropin "$WORK/sshd.later"
bad "no sshd drop-in at all" "no sshd drop-in" v_check_sshd_dropin "$WORK/sshd.empty"
printf -- '-rwxr-xr-x\t900\t/usr/lib/systemd/system-generators/companion-vm-timeouts\t\n' > "$WORK/Lgen.ok"
printf -- '-rw-r--r--\t900\t/usr/lib/systemd/system-generators/companion-vm-timeouts\t\n' > "$WORK/Lgen.mode"
printf -- '-rwxr-xr-x\t900\t/usr/lib/systemd/system-generators/other-generator\t\n' > "$WORK/Lgen.none"
good "the slow-boot generator for VMs is in the image and executable" v_check_vm_generator "$WORK/Lgen.ok"
bad "the slow-boot generator lost its mode (mkarchiso drops it without a file_permissions entry)" "not executable" v_check_vm_generator "$WORK/Lgen.mode"
bad "the slow-boot generator is missing" "not in the image" v_check_vm_generator "$WORK/Lgen.none"

mkdir -p "$WORK/roothk"; printf '[Action]\nExec = /usr/bin/bash /usr/share/libalpm/scripts/zz-ci-os-os-release\n' > "$WORK/roothk/a.hook"
good "hook runs bash on a script that exists" v_check_hook_exec "$WORK/Lm.good" "$WORK/roothk/a.hook" zz-ci-os-os-release.hook
printf '[Action]\nExec = /usr/bin/bash /usr/share/libalpm/scripts/zz-ci-os-gone\n' > "$WORK/roothk/b.hook"
bad "hook runs a script that is not in the image" "not in the image" v_check_hook_exec "$WORK/Lm.good" "$WORK/roothk/b.hook" zz-ci-os-gone.hook
printf '[Action]\nExec = /usr/share/libalpm/scripts/zz-ci-os-os-release\n' > "$WORK/roothk/c.hook"
bad "hook runs a script directly that is not executable" "not executable" v_check_hook_exec "$WORK/Lm.bad2" "$WORK/roothk/c.hook" zz-ci-os-os-release.hook
printf '[Action]\nWhen = PostTransaction\n' > "$WORK/roothk/d.hook"
bad "hook without Exec" "no Exec" v_check_hook_exec "$WORK/Lm.good" "$WORK/roothk/d.hook" d.hook

#=== About, text, launcher =============================================================================================
printf '[General]\nName=Companion OS\nLogoPath=ci-os-logo\nWebsite=https://ci.computer\n' > "$WORK/about.good"
good "kcm-about-distrorc with every key" v_check_about "$WORK/about.good"
printf '[General]\nLogoPath=ci-os-logo\nVersion=0.1.0\n' > "$WORK/about.min"
good "kcm-about-distrorc that leaves Name and Website to os-release" v_check_about "$WORK/about.min" "$WORK/osr.good"
ok_out "...and says that os-release supplies them" "KDE's fallback"
sed 's/^NAME=.*/NAME="CachyOS Linux"/' "$WORK/osr.good" > "$WORK/osr.cachy"
bad "kcm-about-distrorc leaves Name out and os-release says CachyOS" "leaves Name out" v_check_about "$WORK/about.min" "$WORK/osr.cachy"
printf '# Generated by backends/cachyos/iso/scripts/render-assets.sh\n[General]\nLogoPath=ci-os-logo\nVersion=0.1.0\n' > "$WORK/about.comment"
good "a comment that names the tool's path (cachyos in a directory name) is not a brand leak" v_check_about "$WORK/about.comment" "$WORK/osr.good"
printf '[General]\nLogoPath=ci-os-logo\nVersion=9.9.9\n' > "$WORK/about.ver"
bad "kcm-about-distrorc Version differs from os-release" "Version='9.9.9'" v_check_about "$WORK/about.ver" "$WORK/osr.good"
printf '[General]\nName=CachyOS\nLogoPath=cachyos\nWebsite=https://cachyos.org\n' > "$WORK/about.bad"
bad "kcm-about-distrorc for CachyOS" "Name='CachyOS'" v_check_about "$WORK/about.bad"
bad "kcm-about-distrorc LogoPath of CachyOS" "LogoPath is not ci-os-logo" v_check_about "$WORK/about.bad"
bad "no kcm-about-distrorc" "missing" v_check_about "$WORK/no-about"

printf 'Companion OS\nhttps://ci.computer\n' > "$WORK/motd.good"
good "a motd without the brand words" v_check_text_clean motd "$WORK/motd.good"
printf 'This ISO is based on ArchLinux ISO modified for CachyOS.\n' > "$WORK/motd.bad"
bad "upstream's motd" "still names CachyOS or Arch" v_check_text_clean motd "$WORK/motd.bad"
bad "a missing motd" "missing or empty" v_check_text_clean motd "$WORK/no-motd"
good "a motd without block art" v_check_no_block_art "$WORK/motd.good"
printf 'Companion OS %s\n' "$(printf '\342\226\210\342\226\210\342\226\210')" > "$WORK/motd.art"
bad "a motd with block-letter art" "block-letter art" v_check_no_block_art "$WORK/motd.art"

cat > "$WORK/launcher.good" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Companion OS
Exec=/usr/local/bin/calamares-online.sh
Icon=ci-os-logo
Terminal=false
EOF
good "the installer launcher" v_check_launcher_desktop "$WORK/launcher.good"
cp "$WORK/launcher.good" "$WORK/l1"; mut "$WORK/l1" 's/^Name=.*/Name=Install CachyOS/'
bad "a launcher named for CachyOS" "no Name= with Companion OS|names CachyOS" v_check_launcher_desktop "$WORK/l1"
cp "$WORK/launcher.good" "$WORK/l2"; mut "$WORK/l2" 's#^Exec=.*#Exec=/usr/bin/calamares#'
bad "a launcher that does not run calamares-online.sh" "does not run" v_check_launcher_desktop "$WORK/l2"
cp "$WORK/launcher.good" "$WORK/l3"; printf 'NoDisplay=true\n' >> "$WORK/l3"
bad "a hidden launcher" "hidden" v_check_launcher_desktop "$WORK/l3"

#=== calamares-online.sh ===========================================================================================
cat > "$WORK/cal.good" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
OVERLAY=/usr/share/ci-os/calamares
main() {
    sudo pacman -Sy --noconfirm archlinux-keyring cachyos-keyring
    sudo pacman -Sy --noconfirm cachyos-calamares-next
    sudo cp -a "$OVERLAY/modules/." /etc/calamares/modules/
    sudo cp -a "$OVERLAY/branding/companion" /usr/share/calamares/branding/
    exec pkexec-wrapper calamares -D6
}
main "$@"
EOF
good "a launcher script that applies the overlay after the reinstall" v_check_calamares_script "$WORK/cal.good"
cat > "$WORK/cal.upstream" <<'EOF'
#!/bin/bash
main() {
    sudo pacman -Sy --noconfirm cachyos-calamares-next
    sudo cp "/usr/share/calamares/settings_online.conf" /etc/calamares/settings.conf
    exec pkexec-wrapper calamares -D6
}
main "$@"
EOF
bad "upstream's script (no overlay)" "does not reference /usr/share/ci-os/calamares" v_check_calamares_script "$WORK/cal.upstream"
cat > "$WORK/cal.order" <<'EOF'
#!/usr/bin/env bash
sudo cp -a /usr/share/ci-os/calamares/modules/. /etc/calamares/modules/
sudo pacman -Sy --noconfirm cachyos-calamares-next
exec pkexec-wrapper calamares -D6
EOF
bad "the overlay applied BEFORE the reinstall (it would be overwritten)" "after the package reinstall" v_check_calamares_script "$WORK/cal.order"
cp "$WORK/cal.good" "$WORK/cal.gate"; printf 'curl -fsS https://cachyos.org/versions.json >/dev/null\n' >> "$WORK/cal.gate"
bad "a launcher that calls cachyos.org" "contacts a CachyOS host" v_check_calamares_script "$WORK/cal.gate"
cp "$WORK/cal.good" "$WORK/cal.raw"; printf 'curl -fsS https://raw.githubusercontent.com/x/y/z >/dev/null\n' >> "$WORK/cal.raw"
bad "a launcher with a GitHub-raw dependency" "raw.githubusercontent.com" v_check_calamares_script "$WORK/cal.raw"
cp "$WORK/cal.good" "$WORK/cal.syn"; printf 'if then fi done\n' >> "$WORK/cal.syn"
bad "a launcher with a syntax error" "syntax error" v_check_calamares_script "$WORK/cal.syn"
cp "$WORK/cal.good" "$WORK/cal.nocalamares"; mut "$WORK/cal.nocalamares" 's/exec pkexec-wrapper calamares -D6/exec pkexec-wrapper true/'
bad "a launcher that never starts calamares" "never starts calamares" v_check_calamares_script "$WORK/cal.nocalamares"

#=== cachyos-hello gate ============================================================================================
mkdir -p "$WORK/hello/etc/skel/.config/autostart" "$WORK/hello/home/liveuser/.config/autostart" "$WORK/hello/usr/share/applications"
printf 'cachyos-kde-settings 4.9-8\nplasma-desktop 6.8.0-1\n' > "$WORK/pk.nohello"
good "cachyos-hello is not in the image" v_check_hello_gate "$WORK/Lm.good" "$WORK/pk.nohello" "$WORK/hello"
printf 'cachyos-hello 0.28.1-1\nplasma-desktop 6.8.0-1\n' > "$WORK/pk.hello"
printf '[Desktop Entry]\nExec=cachyos-hello\n' > "$WORK/hello/etc/skel/.config/autostart/cachyos-hello.desktop"
cp "$WORK/hello/etc/skel/.config/autostart/cachyos-hello.desktop" "$WORK/hello/home/liveuser/.config/autostart/"
printf '[Desktop Entry]\nExec=cachyos-hello\n' > "$WORK/hello/usr/share/applications/cachyos-hello.desktop"
printf -- '-rwxr-xr-x\t10\t/usr/local/bin/calamares-online.sh\t\n' > "$WORK/Lh"
bad "cachyos-hello still autostarts" "autostarts" v_check_hello_gate "$WORK/Lh" "$WORK/pk.hello" "$WORK/hello"
bad "cachyos-hello is still in the application menu" "application menu" v_check_hello_gate "$WORK/Lh" "$WORK/pk.hello" "$WORK/hello"
printf '[Desktop Entry]\nExec=cachyos-hello\nHidden=true\n' > "$WORK/hello/etc/skel/.config/autostart/cachyos-hello.desktop"
cp "$WORK/hello/etc/skel/.config/autostart/cachyos-hello.desktop" "$WORK/hello/home/liveuser/.config/autostart/"
printf '[Desktop Entry]\nExec=cachyos-hello\nNoDisplay=true\n' > "$WORK/hello/usr/share/applications/cachyos-hello.desktop"
good "cachyos-hello is in the image but hidden everywhere" v_check_hello_gate "$WORK/Lh" "$WORK/pk.hello" "$WORK/hello"

#=== cachy-update (the CachyOS-named update notifier of ISO #4's installed desktop) ============================================
mkdir -p "$WORK/cu/etc/xdg/autostart" "$WORK/cu/usr/share/applications" "$WORK/cu/etc/skel/.config/autostart"
good "cachy-update is not in the image" v_check_cachy_update "$WORK/pk.nohello" "$WORK/cu"
printf 'cachy-update 4.4.3-1\nplasma-desktop 6.8.0-1\n' > "$WORK/pk.cu"
printf '[Desktop Entry]\nName=Cachy-Update Systray Applet\nExec=/bin/sh -c "sleep 3 && arch-update --tray"\nNoDisplay=true\n' > "$WORK/cu/etc/xdg/autostart/arch-update-tray.desktop"
printf '[Desktop Entry]\nName=Cachy-Update\nComment=An interactive update notifier & applier for CachyOS\nExec=arch-update\n' > "$WORK/cu/usr/share/applications/arch-update.desktop"
bad "cachy-update is in the image and its tray applet autostarts (NoDisplay does not stop an autostart entry)" "tray applet autostarts" v_check_cachy_update "$WORK/pk.cu" "$WORK/cu"
bad "cachy-update is in the image and its menu entry is shown" "menu entry is shown" v_check_cachy_update "$WORK/pk.cu" "$WORK/cu"
printf '[Desktop Entry]\nName=Cachy-Update Systray Applet\nHidden=true\n' > "$WORK/cu/etc/xdg/autostart/arch-update-tray.desktop"
printf '[Desktop Entry]\nName=Cachy-Update\nNoDisplay=true\nExec=arch-update\n' > "$WORK/cu/usr/share/applications/arch-update.desktop"
good "cachy-update is in the image but neither autostarts nor shows" v_check_cachy_update "$WORK/pk.cu" "$WORK/cu"
rm -f "$WORK/cu/etc/xdg/autostart/arch-update-tray.desktop"
good "cachy-update is in the image, hidden, with no tray autostart file at all" v_check_cachy_update "$WORK/pk.cu" "$WORK/cu"
printf '[Desktop Entry]\nName=Cachy-Update Systray Applet\nExec=arch-update --tray\n' > "$WORK/cu/etc/skel/.config/autostart/arch-update-tray.desktop"
bad "an autostart entry in the user skeleton counts too" "tray applet autostarts" v_check_cachy_update "$WORK/pk.cu" "$WORK/cu"

#=== package list ==================================================================================================
: > "$WORK/pk.list"
for p in $V_REQUIRED_PKGS docker docker-compose; do echo "$p 1.0-1" >> "$WORK/pk.list"; done
printf '# nothing the image lacks\ndocker\ndocker-compose  # compose\n' > "$WORK/pk.add"
printf '# gone\nocct\n' > "$WORK/pk.rem"
good "package list: required, added, removed" v_check_pkglist "$WORK/pk.list" "$WORK/pk.add" "$WORK/pk.rem"
grep -v '^plasma-login-manager ' "$WORK/pk.list" > "$WORK/pk.nolm"
bad "a required package is missing" "plasma-login-manager" v_check_pkglist "$WORK/pk.nolm" "$WORK/pk.add" "$WORK/pk.rem"
printf 'docker\nnot-in-the-image\n' > "$WORK/pk.add2"
bad "packages.add names a package the image lacks" "not-in-the-image" v_check_pkglist "$WORK/pk.list" "$WORK/pk.add2" "$WORK/pk.rem"
{ cat "$WORK/pk.list"; echo "occt 2.0-1"; } > "$WORK/pk.occt"
bad "a package that packages.remove removes is in the image" "occt" v_check_pkglist "$WORK/pk.occt" "$WORK/pk.add" "$WORK/pk.rem"
printf '# comments only\n' > "$WORK/pk.add0"
printf '# comments only\n' > "$WORK/pk.rem0"
vrun v_check_pkglist "$WORK/pk.list" "$WORK/pk.add0" "$WORK/pk.rem0"
ok_out "empty packages.add / packages.remove lists are a note, not a pass" "info  overlay/packages.add lists no package"
if printf '%s\n' "$OUT" | grep -q "^PASS.*packages.add"; then t_fail "an empty packages.add produced a PASS (vacuous)"; else t_pass "an empty packages.add produces no PASS"; fi
bad "no packages.add file" "packages.add is missing" v_check_pkglist "$WORK/pk.list" "$WORK/no-add" "$WORK/pk.rem"
: > "$WORK/pk.empty"
bad "an empty package list" "missing or empty" v_check_pkglist "$WORK/pk.empty" "$WORK/pk.add" "$WORK/pk.rem"

#=== package list against the image's pacman database, and the copy next to the ISO ====================================
# The Arch builder image has no diffutils, and the verifier runs there (backends/cachyos/README.md): a first run printed
# "cmp: command not found" and failed both checks on identical inputs. A shell function shadows a command of the same name, so
# these two stand in for the missing tools and fail as they do; the checks must not need them.
cmp() { echo "cmp: command not found" >&2; return 127; }
diff() { echo "diff: command not found" >&2; return 127; }
mkdir -p "$WORK/pdbw"
mk_pacman_db() { # mk_pacman_db DIR LIST: DIR/var/lib/pacman/local/NAME-VERSION for every "NAME VERSION" line of LIST
    rm -rf "$1"; mkdir -p "$1/var/lib/pacman/local"
    while read -r n v; do [ -n "$n" ] && mkdir -p "$1/var/lib/pacman/local/$n-$v"; done < "$2"
}
mk_pacman_db "$WORK/pdb" "$WORK/pk.list"
good "the package list equals the pacman database (no cmp, no diff on this machine)" v_check_pkglist_vs_db "$WORK/pdb" "$WORK/pk.list" "$WORK/pdbw"
{ cat "$WORK/pk.list"; echo "extra-pkg 1.0-1"; } > "$WORK/pk.extra"
bad "a package in the list but not in the database" "extra-pkg" v_check_pkglist_vs_db "$WORK/pdb" "$WORK/pk.extra" "$WORK/pdbw"
mk_pacman_db "$WORK/pdb2" "$WORK/pk.extra"
bad "a package in the database but not in the list" "extra-pkg" v_check_pkglist_vs_db "$WORK/pdb2" "$WORK/pk.list" "$WORK/pdbw"
sed 's/^docker 1.0-1$/docker 1.0-2/' "$WORK/pk.list" > "$WORK/pk.ver"
bad "the same package in another version" "differ" v_check_pkglist_vs_db "$WORK/pdb" "$WORK/pk.ver" "$WORK/pdbw"
mkdir -p "$WORK/pdb0/var/lib/pacman/local"
bad "an image with no pacman database is not an equal one" "differ" v_check_pkglist_vs_db "$WORK/pdb0" "$WORK/pk.list" "$WORK/pdbw"
cp "$WORK/pk.list" "$WORK/pk.copy"
good "the package list next to the ISO is the one inside it (no cmp, no diff)" v_check_pkgs_txt "$WORK/pk.copy" "$WORK/pk.list"
bad "the package list next to the ISO differs from the one inside it" "differs from" v_check_pkgs_txt "$WORK/pk.extra" "$WORK/pk.list"
bad "no package list next to the ISO" "differs from" v_check_pkgs_txt "$WORK/no-such-pkgs.txt" "$WORK/pk.list"
unset -f cmp diff

#=== lock, build record, checksums =====================================================================================
cat > "$WORK/upstream.lock" <<'EOF'
# a lock file: KEY=VALUE, comments allowed
UPSTREAM_REPO=https://github.com/CachyOS/CachyOS-Live-ISO.git
UPSTREAM_SHA=3215497d2e8c5fea90e185affcf973dfa2cf790b
UPSTREAM_FALLBACK_SHA=4937780541814b4b0ec7c212c00fe06299f799b6
BASE_IMAGE=archlinux@sha256:3c64b538588416593f69a1aebd2f2ec0f2541b29159f32556fa7def2167147a0
MIRRORLIST_SHA256=7145812bba2491155f9b004129ee858ec1449ca2dd381a1ce3442b67807c7918
CACHYOS_KEY_FPR=882DCFE48E2051D48E2562ABF3B607488DB35A47
EDITION_ISO_NAME=companion-os-plasma
EDITION_LABEL_PREFIX=COMPANION_
EDITION_ARCH=x86_64
EOF
if [ "$(v_lock_get "$WORK/upstream.lock" UPSTREAM_SHA)" = "3215497d2e8c5fea90e185affcf973dfa2cf790b" ]; then t_pass "v_lock_get reads KEY=value without sourcing"; else t_fail "v_lock_get did not read UPSTREAM_SHA"; fi
if [ "$(v_lock_get "$WORK/upstream.lock" NOPE UPSTREAM_SHA)" = "3215497d2e8c5fea90e185affcf973dfa2cf790b" ]; then t_pass "v_lock_get tries the next key name"; else t_fail "v_lock_get did not fall through to the second key"; fi
if v_lock_get "$WORK/upstream.lock" NOPE >/dev/null; then t_fail "v_lock_get returned success for a missing key"; else t_pass "v_lock_get fails for a missing key"; fi
good "the lock names the D1 edition" v_check_lock_identity "$WORK/upstream.lock"
sed 's/^EDITION_ISO_NAME=.*/EDITION_ISO_NAME=companion-os-cachyos/' "$WORK/upstream.lock" > "$WORK/lock.bad"
bad "the lock names the CachyOS mark" "EDITION_ISO_NAME" v_check_lock_identity "$WORK/lock.bad"

cat > "$WORK/bi.good" <<'EOF'
CI_OS_EDITION=cachyos-plasma
CI_OS_VERSION=0.1.0
BUILD_DAY=20261014
UPSTREAM_PIN=primary
UPSTREAM_SHA=3215497d2e8c5fea90e185affcf973dfa2cf790b
BASE_IMAGE=archlinux@sha256:3c64b538588416593f69a1aebd2f2ec0f2541b29159f32556fa7def2167147a0
MIRRORLIST_SHA256=7145812bba2491155f9b004129ee858ec1449ca2dd381a1ce3442b67807c7918
CACHYOS_KEY_FPR=882DCFE48E2051D48E2562ABF3B607488DB35A47
OVERLAY_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
STAGING_SHA256=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
KERNEL_LINES_CHANGED=0
EOF
good "a build record that matches the lock" v_check_buildinfo "$WORK/bi.good" "$WORK/upstream.lock" "record"
sed 's/^UPSTREAM_SHA=.*/UPSTREAM_SHA=4937780541814b4b0ec7c212c00fe06299f799b6/' "$WORK/bi.good" > "$WORK/bi.sha"
bad "a build from another upstream commit" "UPSTREAM_SHA is" v_check_buildinfo "$WORK/bi.sha" "$WORK/upstream.lock" "record"
sed -e 's/^UPSTREAM_SHA=.*/UPSTREAM_SHA=4937780541814b4b0ec7c212c00fe06299f799b6/' -e 's/^UPSTREAM_PIN=.*/UPSTREAM_PIN=fallback/' "$WORK/bi.good" > "$WORK/bi.fb"
good "a build of the fallback pin is compared with UPSTREAM_FALLBACK_SHA" v_check_buildinfo "$WORK/bi.fb" "$WORK/upstream.lock" "record"
sed 's/sha256:3c64/sha256:0000/' "$WORK/bi.good" > "$WORK/bi.img"
bad "a build in another base image" "BASE_IMAGE is" v_check_buildinfo "$WORK/bi.img" "$WORK/upstream.lock" "record"
sed 's/^MIRRORLIST_SHA256=.*/MIRRORLIST_SHA256=0000/' "$WORK/bi.good" > "$WORK/bi.ml"
bad "a build with another mirrorlist" "MIRRORLIST_SHA256 is" v_check_buildinfo "$WORK/bi.ml" "$WORK/upstream.lock" "record"
grep -v '^OVERLAY_SHA256' "$WORK/bi.good" > "$WORK/bi.noov"
bad "a build record without an overlay hash" "OVERLAY_SHA256 is" v_check_buildinfo "$WORK/bi.noov" "$WORK/upstream.lock" "record"
sed 's/^BUILD_DAY=.*/BUILD_DAY=soon/' "$WORK/bi.good" > "$WORK/bi.day"
bad "a build record with no build day" "BUILD_DAY is" v_check_buildinfo "$WORK/bi.day" "$WORK/upstream.lock" "record"
bad "an empty build record" "missing or empty" v_check_buildinfo "$WORK/no-bi" "$WORK/upstream.lock" "record"
# build-iso.sh packs the working tree: the record says whether it was the commit (REPO_TREE), and a release can insist on clean
{ cat "$WORK/bi.good"; printf 'REPO_COMMIT=0123456789abcdef0123456789abcdef01234567\nREPO_TREE=clean\n'; } > "$WORK/bi.clean"
{ cat "$WORK/bi.good"; printf 'REPO_COMMIT=0123456789abcdef0123456789abcdef01234567\nREPO_TREE=dirty\nREPO_TREE_CHANGED=2\nREPO_TREE_UNTRACKED=1\nREPO_TREE_IGNORED=0\n'; } > "$WORK/bi.dirty"
{ cat "$WORK/bi.good"; printf 'REPO_TREE=unknown\n'; } > "$WORK/bi.unknown"
good "a build from a clean checkout" v_check_buildinfo "$WORK/bi.clean" "$WORK/upstream.lock" "record"
ok_out "...and the commit is named" "PASS  record: built from a clean checkout of commit 0123456789ab"
good "a dirty tree is noted, not failed, by default" v_check_buildinfo "$WORK/bi.dirty" "$WORK/upstream.lock" "record"
ok_out "...and the note says what was dirty" "info  record: REPO_TREE=dirty \(changed 2, untracked 1, ignored 0\)"
bad "a dirty tree fails when a release is required" "REPO_TREE=dirty" env_require_clean v_check_buildinfo "$WORK/bi.dirty" "$WORK/upstream.lock" "record"
bad "an unknown tree fails when a release is required" "REPO_TREE=unknown" env_require_clean v_check_buildinfo "$WORK/bi.unknown" "$WORK/upstream.lock" "record"
bad "a record without REPO_TREE fails when a release is required" "no REPO_TREE" env_require_clean v_check_buildinfo "$WORK/bi.good" "$WORK/upstream.lock" "record"
good "a clean checkout passes when a release is required" env_require_clean v_check_buildinfo "$WORK/bi.clean" "$WORK/upstream.lock" "record"
cp "$WORK/bi.good" "$WORK/bi.side"
good "the record inside the image, the one next to it and os-release agree" v_check_buildinfo_pair "$WORK/bi.good" "$WORK/bi.side" "$WORK/osr.good"
sed 's/^OVERLAY_SHA256=.*/OVERLAY_SHA256=1111111111111111111111111111111111111111111111111111111111111111/' "$WORK/bi.good" > "$WORK/bi.side2"
bad "the two build records describe different overlays" "OVERLAY_SHA256 differs" v_check_buildinfo_pair "$WORK/bi.good" "$WORK/bi.side2" "$WORK/osr.good"
sed 's/^CI_OS_VERSION=.*/CI_OS_VERSION=9.9.9/' "$WORK/bi.good" > "$WORK/bi.ver"
bad "os-release carries another version than the build record" "os-release CI_OS_VERSION" v_check_buildinfo_pair "$WORK/bi.ver" "$WORK/bi.ver" "$WORK/osr.good"
sed 's/^BUILD_DAY=.*/BUILD_DAY=20250101/' "$WORK/bi.good" > "$WORK/bi.bday"
bad "os-release carries another build day than the build record" "os-release CI_OS_BUILD" v_check_buildinfo_pair "$WORK/bi.bday" "$WORK/bi.bday" "$WORK/osr.good"
printf 'some iso bytes\n' > "$WORK/x.iso"
{ printf 'ISO_BYTES=%s\n' "$(wc -c < "$WORK/x.iso" | tr -d ' ')"; printf 'ISO_SHA256=%s\n' "$(v_sha256 "$WORK/x.iso")"; } > "$WORK/bi.iso"
good "the build record's ISO size and hash describe the file" v_check_buildinfo_iso "$WORK/bi.iso" "$WORK/x.iso"
printf 'ISO_BYTES=1\nISO_SHA256=00\n' > "$WORK/bi.iso2"
bad "the build record's ISO size and hash describe another file" "ISO_BYTES is" v_check_buildinfo_iso "$WORK/bi.iso2" "$WORK/x.iso"

#=== compatibility libraries (risk R1: compat-libs.lock, the image, the build record) ===========================================
CL="$WORK/compat"; mkdir -p "$CL/root/usr/lib"
printf 'FAKE-PYTHON' > "$CL/root/usr/lib/libboost_python314.so.1.91.0"
printf 'FAKE-CONTAINER' > "$CL/root/usr/lib/libboost_container.so.1.91.0"
printf 'FAKE-GRAPH' > "$CL/root/usr/lib/libboost_graph.so.1.91.0"
cl_url=https://archive.archlinux.org/packages/b/boost-libs/boost-libs-1.91.0-2-x86_64.pkg.tar.zst
cat > "$CL/compat-libs.lock" <<EOF
# a compat lock
review-by 2030-01-01
package boost-libs 1.91.0-2 x86_64 $cl_url 62cfd278b0260bd2ce5c93f6ab4669d2eefe840eab19e2c3854762f295924655
lib boost-libs usr/lib/libboost_python314.so.1.91.0 $(v_sha256 "$CL/root/usr/lib/libboost_python314.so.1.91.0")
lib boost-libs usr/lib/libboost_container.so.1.91.0 $(v_sha256 "$CL/root/usr/lib/libboost_container.so.1.91.0")
lib boost-libs usr/lib/libboost_graph.so.1.91.0 $(v_sha256 "$CL/root/usr/lib/libboost_graph.so.1.91.0")
EOF
for n in python314 container graph; do printf '%s\t%s\t%s\t%s\n' '-rw-r--r--' 10 "/usr/lib/libboost_$n.so.1.91.0" ''; done > "$CL/listing.good"
printf '%s\t%s\t%s\t%s\n' 'drwxr-xr-x' 0 /usr/lib '' >> "$CL/listing.good"
# the record the compat step writes into the build record (stage-compat-libs.sh report; 20-build.sh copies the five lines)
cl_rec() { # FILE LOCK LIBS PACKAGES REVIEW_BY OVERDUE
  printf 'CI_OS_VERSION=0.1.0\nCOMPAT_LIBS=%s\nCOMPAT_PACKAGES=%s\nCOMPAT_LOCK_SHA256=%s\nCOMPAT_REVIEW_BY=%s\nCOMPAT_REVIEW_OVERDUE=%s\n' "$3" "$4" "$(v_sha256 "$2")" "$5" "$6" > "$1"
}
cl_rec "$CL/rec.good" "$CL/compat-libs.lock" 3 boost-libs-1.91.0-2-x86_64 2030-01-01 0
good "the three pinned compatibility libraries are in the image, byte for byte, and the build record says the step ran" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.good"
ok_out "...and says how many" "PASS  all 3 compatibility libraries of compat-libs.lock are in the image"
good "the record next to the ISO agrees with the one inside it" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.good" "$CL/rec.good"

grep -v graph "$CL/listing.good" > "$CL/listing.nograph"
bad "a pinned library missing from the image (the installer would not start)" "libboost_graph.so.1.91.0 \(boost-libs\) is not in the image" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.nograph" "$CL/root" "$CL/rec.good"
sed 's|^-rw-r--r--\(.*\)libboost_graph.so.1.91.0\t$|lrwxrwxrwx\1libboost_graph.so.1.91.0\tlibboost_graph.so.1.92.0|' "$CL/listing.good" > "$CL/listing.link"
bad "a pinned library that is a symlink to the current one (the failed attempt of 2026-10-18)" "libboost_graph.so.1.91.0 is not a regular file" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.link" "$CL/root" "$CL/rec.good"
sed 's|^-rw-r--r--\(.*\)libboost_container|-rw-------\1libboost_container|' "$CL/listing.good" > "$CL/listing.mode"
bad "a pinned library nobody but root can read" "libboost_container.so.1.91.0 has mode -rw-------" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.mode" "$CL/root" "$CL/rec.good"
mkdir -p "$CL/root2/usr/lib"; cp "$CL/root/usr/lib/"* "$CL/root2/usr/lib/"; printf 'TAMPERED' > "$CL/root2/usr/lib/libboost_python314.so.1.91.0"
bad "a pinned library with other bytes than the lock pins" "libboost_python314.so.1.91.0 has sha256 .*, compat-libs.lock pins" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root2" "$CL/rec.good"
mkdir -p "$CL/root3/usr/lib"; cp "$CL/root/usr/lib/libboost_graph.so.1.91.0" "$CL/root/usr/lib/libboost_container.so.1.91.0" "$CL/root3/usr/lib/"
bad "a library that was listed but could not be extracted (its hash was not checked)" "libboost_python314.so.1.91.0 could not be extracted" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root3" "$CL/rec.good"

# the build record: ISO #3 of 2026-10-18 has none of the keys, and is the image whose installer did not start
printf 'CI_OS_VERSION=0.1.0\nBUILD_DAY=20261018\n' > "$CL/rec.old"
bad "a build record with no COMPAT_* keys (an image built before the step existed)" "carries no COMPAT_LIBS" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.old"
grep -v COMPAT_REVIEW_OVERDUE "$CL/rec.good" > "$CL/rec.nooverdue"
bad "a build record that lacks one of the five keys" "carries no COMPAT_REVIEW_OVERDUE" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.nooverdue"
bad "no build record inside the image at all" "no build record inside the image" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/no-such-record"
sed 's/^COMPAT_LIBS=.*/COMPAT_LIBS=off/' "$CL/rec.good" > "$CL/rec.off"
bad "COMPAT_LIBS=off (the build that proves the gate fails)" "COMPAT_LIBS=off" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.off"
sed 's/^COMPAT_LIBS=.*/COMPAT_LIBS=unknown/' "$CL/rec.good" > "$CL/rec.unknown"
bad "COMPAT_LIBS=unknown (the step left no report)" "COMPAT_LIBS=unknown" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.unknown"
sed 's/^COMPAT_LIBS=.*/COMPAT_LIBS=2/' "$CL/rec.good" > "$CL/rec.two"
bad "COMPAT_LIBS says 2, the lock lists 3" "COMPAT_LIBS=2, but compat-libs.lock lists 3" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.two"
sed 's/^COMPAT_LIBS=.*/COMPAT_LIBS=many/' "$CL/rec.good" > "$CL/rec.many"
bad "COMPAT_LIBS that is not a number" "COMPAT_LIBS='many' is not a number" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.many"
sed 's/^COMPAT_LOCK_SHA256=.*/COMPAT_LOCK_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' "$CL/rec.good" > "$CL/rec.lockhash"
bad "an image built with another lock than the repository's" "COMPAT_LOCK_SHA256 is '0000" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.lockhash"
sed 's/^COMPAT_PACKAGES=.*/COMPAT_PACKAGES=boost-libs-1.90.0-1-x86_64/' "$CL/rec.good" > "$CL/rec.pkgs"
bad "a record that names another package version than the lock" "COMPAT_PACKAGES is 'boost-libs-1.90.0-1-x86_64'" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.pkgs"
sed 's/^COMPAT_REVIEW_BY=.*/COMPAT_REVIEW_BY=2029-01-01/' "$CL/rec.good" > "$CL/rec.by"
bad "a record with another review date than the lock" "COMPAT_REVIEW_BY is '2029-01-01'" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.by"
sed 's/^COMPAT_REVIEW_OVERDUE=.*/COMPAT_REVIEW_OVERDUE=1/' "$CL/rec.good" > "$CL/rec.overdue"
good "a build past the review date is noted, not failed, by default" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.overdue"
ok_out "...and the note says how to make it a failure" "info  build record: COMPAT_REVIEW_OVERDUE=1: compat-libs.lock was past its review date"
bad "...and fails when a release is required" "COMPAT_REVIEW_OVERDUE=1" env_require_clean v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.overdue"
sed 's/^COMPAT_REVIEW_OVERDUE=.*/COMPAT_REVIEW_OVERDUE=maybe/' "$CL/rec.good" > "$CL/rec.maybe"
bad "COMPAT_REVIEW_OVERDUE that is neither 0 nor 1" "COMPAT_REVIEW_OVERDUE='maybe'" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.maybe"
bad "the record next to the ISO disagrees with the one inside it" "COMPAT_LOCK_SHA256 differs" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.good" "$CL/rec.lockhash"
bad "the record next to the ISO has no COMPAT_* keys" "COMPAT_LIBS differs" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.good" "$CL/rec.old"
bad "no compat lock to compare with" "no-such.lock not found at" v_check_compat_libs "$CL/no-such.lock" "$CL/listing.good" "$CL/root" "$CL/rec.good"
printf 'review-by soon\n' > "$CL/bad.lock"
bad "an invalid compat lock" "is not a valid compat lock" v_check_compat_libs "$CL/bad.lock" "$CL/listing.good" "$CL/root" "$CL/rec.good"
# shellcheck disable=SC2034  # read by v_check_compat_libs
V_HAVE_COMPAT_LOCK=0
bad "the lock helpers missing next to the verifier (never silently skipped)" "lib/compat-lock.sh is not next to verify-iso.sh" v_check_compat_libs "$CL/compat-libs.lock" "$CL/listing.good" "$CL/root" "$CL/rec.good"
# shellcheck disable=SC2034  # read by v_check_compat_libs
V_HAVE_COMPAT_LOCK=1

# a lock that says no library is needed any more: an image with none, and a record that says 0, must PASS
printf '# the header stays\nretired 2026-12-03\n' > "$CL/retired.lock"
grep -v 'libboost' "$CL/listing.good" > "$CL/listing.none"
cl_rec "$CL/rec.retired" "$CL/retired.lock" 0 "" "" 0
good "a RETIRED lock (no library needed any more) passes with an image that has none and a record that says COMPAT_LIBS=0" v_check_compat_libs "$CL/retired.lock" "$CL/listing.none" "$CL/root3" "$CL/rec.retired" "$CL/rec.retired"
ok_out "...and says so" "PASS  retired.lock lists no compatibility library \(retired\)"
cl_rec "$CL/rec.retired3" "$CL/retired.lock" 3 boost-libs-1.91.0-2-x86_64 2030-01-01 0
bad "a retired lock, but the record claims three libraries" "COMPAT_LIBS=3, but retired.lock lists 0" v_check_compat_libs "$CL/retired.lock" "$CL/listing.none" "$CL/root3" "$CL/rec.retired3"
bad "a retired lock, but the record carries no COMPAT_* keys at all" "carries no COMPAT_LIBS" v_check_compat_libs "$CL/retired.lock" "$CL/listing.none" "$CL/root3" "$CL/rec.old"
cl_rec "$CL/rec.retiredoff" "$CL/retired.lock" off "" "" 0
bad "a retired lock, but the image was built with the step switched off" "COMPAT_LIBS=off" v_check_compat_libs "$CL/retired.lock" "$CL/listing.none" "$CL/root3" "$CL/rec.retiredoff"
echo "$(v_sha256 "$WORK/x.iso")  x.iso" > "$WORK/x.iso.sha256"
good "the .sha256 matches the ISO" v_check_sha256_file "$WORK/x.iso.sha256" "$WORK/x.iso"
echo "0000000000000000000000000000000000000000000000000000000000000000  x.iso" > "$WORK/y.sha256"
bad "a .sha256 of another file" "hashes to" v_check_sha256_file "$WORK/y.sha256" "$WORK/x.iso"
echo "garbage" > "$WORK/z.sha256"
bad "a .sha256 that holds no hash" "does not start with a sha256" v_check_sha256_file "$WORK/z.sha256" "$WORK/x.iso"
echo "$(v_sha512 "$WORK/x.iso")  airootfs.sfs" > "$WORK/x.sha512"
good "airootfs.sha512 matches the squashfs" v_check_sfs_sha512 "$WORK/x.sha512" "$WORK/x.iso"
sed 's/^./0/' "$WORK/x.sha512" > "$WORK/y.sha512"
bad "airootfs.sha512 of another squashfs" "hashes to" v_check_sfs_sha512 "$WORK/y.sha512" "$WORK/x.iso"

#=== carry-over, release stamp, wallpaper package ===================================================================
printf -- '-rwxr-xr-x\t900\t/usr/share/ci-os/installed/carry-over\t\n-rw-r--r--\t100\t/usr/share/libalpm/hooks/zz-ci-os-os-release.hook\t\ndrwxr-xr-x\t3\t/usr/share/wallpapers/companion\t\n-rw-r--r--\t900\t/usr/share/wallpapers/companion/metadata.json\t\n-rw-r--r--\t90000\t/usr/share/wallpapers/companion/contents/images/1920x1080.jpg\t\n-rw-r--r--\t900\t/usr/share/ci-os/release\t\n' > "$WORK/Lc"
printf '# manifest\n\n/usr/share/libalpm/hooks/zz-ci-os-os-release.hook\n/usr/share/wallpapers/companion\n' > "$WORK/co.list"
good "carry-over: every listed path is in the image (a directory by its contents)" v_check_carryover "$WORK/Lc" "$WORK/co.list"
printf '/usr/share/libalpm/hooks/zz-ci-os-os-release.hook\n/usr/share/grub/themes/companion-os\n' > "$WORK/co.bad"
bad "carry-over: a listed path is not in the image" "not in the image" v_check_carryover "$WORK/Lc" "$WORK/co.bad"
printf '# only a comment\n' > "$WORK/co.none"
bad "carry-over: a manifest that lists nothing" "names no path" v_check_carryover "$WORK/Lc" "$WORK/co.none"
bad "carry-over: no manifest" "carry-over.list is missing" v_check_carryover "$WORK/Lc" "$WORK/no-manifest"
sed 's/-rwxr-xr-x\t900\t\/usr\/share\/ci-os\/installed\/carry-over/-rw-r--r--\t900\t\/usr\/share\/ci-os\/installed\/carry-over/' "$WORK/Lc" > "$WORK/Lc2"
bad "carry-over: the script lost its exec bit" "missing or not executable" v_check_carryover "$WORK/Lc2" "$WORK/co.list"

printf 'CI_OS_VERSION="0.1.0"\nCI_OS_BUILD="20261014"\nCI_OS_ANSI_COLOR="38;2;197;232;220"\n' > "$WORK/release.good"
good "release stamp equals os-release" v_check_release_stamp "$WORK/release.good" "$WORK/osr.good"
sed 's/0.1.0/0.2.0/' "$WORK/release.good" > "$WORK/release.v"
bad "release stamp with another version than os-release" "CI_OS_VERSION" v_check_release_stamp "$WORK/release.v" "$WORK/osr.good"
sed 's/38;2;197;232;220/38;2;1;2;3/' "$WORK/release.good" > "$WORK/release.c"
bad "release stamp with another colour than os-release" "ANSI_COLOR" v_check_release_stamp "$WORK/release.c" "$WORK/osr.good"
bad "no release stamp" "release is missing" v_check_release_stamp "$WORK/no-release" "$WORK/osr.good"

good "wallpaper package with metadata.json and images" v_check_wallpaper_package "$WORK/Lc" /usr/share/wallpapers/companion
grep -v 'metadata.json' "$WORK/Lc" > "$WORK/Lc3"
bad "wallpaper package without metadata.json" "no metadata.json" v_check_wallpaper_package "$WORK/Lc3" /usr/share/wallpapers/companion

#=== Calamares overlay (python3 + PyYAML) ==============================================================================
mk_cal_tree() { # mk_cal_tree DIR: a tree that satisfies every static check
    local d="$1"
    mkdir -p "$d/modules" "$d/branding/companion"
    cat > "$d/settings_companion.conf" <<'EOF'
---
modules-search: [ local ]
instances:
- id: online
  module: packages
  config: packages_online.conf
- id: online
  module: welcome
  config: welcome_online.conf
- id: ci_os_stage
  module: shellprocess
  config: shellprocess_ci_os_stage.conf
- id: bootloader
  module: packagechooser
  config: packagechooser_bootloader.conf
sequence:
- show:
  - welcome@online
  - locale
  - keyboard
  - packagechooser@bootloader
  - partition
  - users
  - summary
- exec:
  - partition
  - mount
  - pacstrap
  - users
  - packages@online
  - shellprocess@ci_os_stage
  - plymouthcfg
  - initcpio
  - grubcfg
  - bootloader
  - umount
- show:
  - finished
branding: companion
EOF
    cat > "$d/modules/packages_online.conf" <<'EOF'
---
backend: pacman
update_db: true
update_system: true
operations:
  - install:
      - docker
      - docker-compose
      - docker-buildx
      - jq
      - hostapd
      - dnsmasq
EOF
    cat > "$d/modules/welcome_online.conf" <<'EOF'
---
requirements:
    requiredStorage: 8.0
    internetCheckUrl: https://ci.computer
    check: [ storage, ram, internet ]
EOF
    cat > "$d/modules/shellprocess_ci_os_stage.conf" <<'EOF'
---
dontChroot: true
script:
    - command: "cp -a /usr/lib/ci-os/target-payload/. ${ROOT}/"
    - command: "/usr/share/ci-os/installed/carry-over ${ROOT}"
    - command: "chroot ${ROOT} systemctl enable docker.service"
EOF
    cat > "$d/modules/bootloader.conf" <<'EOF'
---
efiBootLoader: "grub"
efiBootloaderId: "companion-os"
installEFIFallback: true
EOF
    cat > "$d/modules/grubcfg.conf" <<'EOF'
---
overwrite: false
keep_distributor: false
defaults:
    GRUB_THEME: "/usr/share/grub/themes/companion-os/theme.txt"
always_use_defaults: true
EOF
    cat > "$d/modules/packagechooser_bootloader.conf" <<'EOF'
---
mode: required
method: legacy
default: grub
items:
    - id: grub
      name: "GRUB"
      screenshot: "/usr/share/calamares/branding/companion/bootloader.png"
EOF
    cat > "$d/modules/plymouthcfg.conf" <<'EOF'
---
plymouth_theme: companion-os
plymouth_theme_amdgpu: companion-os
EOF
    cat > "$d/modules/users.conf" <<'EOF'
---
defaultGroups:
    - wheel
    - name: docker
      must_exist: false
      system: true
hostname:
    location: EtcFile
    template: "companion-os"
EOF
    cat > "$d/branding/companion/branding.desc" <<'EOF'
---
componentName: companion
strings:
    productName:         Companion OS
    shortProductName:    Companion OS
    version:             0.1.0
    shortVersion:        0.1.0
    versionedName:       Companion OS 0.1.0
    shortVersionedName:  Companion OS
    bootloaderEntryName: Companion OS
images:
    productLogo: "logo.png"
    productIcon: "icon.png"
    productWelcome: "welcome.png"
style:
    SidebarBackground: "#041620"
    SidebarText: "#c5e8dc"
slideshow: "show.qml"
slideshowAPI: 2
EOF
    mk_png "$d/branding/companion/logo.png" 64 64
    mk_png "$d/branding/companion/icon.png" 128 128
    mk_png "$d/branding/companion/welcome.png" 900 516
    printf 'import QtQuick 2.0\nText { text: "Welcome to Companion OS" }\n' > "$d/branding/companion/show.qml"
    # the stylesheet as stage-installer.sh resolves it: the brand tokens in place of the CTRL_* placeholders
    cat > "$d/branding/companion/stylesheet.qss" <<'EOF'
QWidget { font: 13px; }
QProgressBar { background-color: #041620; border: 1px solid #a3babf; border-radius: 4px; color: #e8f2f4; text-align: center; min-height: 18px; max-height: 18px; }
QProgressBar::chunk { background-color: #0d7a6e; border-radius: 3px; }
QAbstractItemView { selection-background-color: #c5e8dc; selection-color: #041620; }
#supportButton,
#donateButton,
#releaseNotesButton,
#knownIssuesButton { icon-size: 0px; qproperty-iconSize: 0px 0px; }
EOF
    mk_png "$d/branding/companion/bootloader.png" 384 384
    # the provisioning tree staged for the installed system: the output filter of the first-boot driver
    mkdir -p "$d/target/bootstrap/backends/cachyos/provision"
    printf '#!/bin/bash\ncat\n' > "$d/target/bootstrap/backends/cachyos/provision/progress-filter.sh"
    # the first-boot unit the installed system gets (target/units is data for the stager, not Calamares YAML)
    mkdir -p "$d/target/units"
    cat > "$d/target/units/ci-os-first-boot-setup.service" <<'EOF'
[Unit]
Description=Companion OS first-boot setup
ConditionPathExists=!/var/lib/ci-os/.first-boot-setup-done
[Service]
Type=exec
ExecStart=/usr/lib/ci-os/first-boot-setup.sh
Environment=HOME=/root
RemainAfterExit=no
Nice=10
[Install]
WantedBy=multi-user.target
EOF
}
printf 'partition\nmount\npacstrap\nusers\npackages\nwelcome\nshellprocess\ngrubcfg\nbootloader\numount\nlocale\nkeyboard\nsummary\nfinished\nplymouthcfg\ninitcpio\npackagechooser\n' > "$WORK/stock-modules.txt"
: > "$WORK/stock-confs.txt"
printf '/usr/lib/ci-os/target-payload/etc/x\n/usr/share/ci-os/installed/carry-over\n/usr/share/grub/themes/companion-os/theme.txt\n/usr/share/plymouth/themes/companion-os/companion-os.plymouth\n' > "$WORK/image-paths.txt"
calrun() { v_run_calamares_py "$1" --stock-modules "$WORK/stock-modules.txt" --stock-confs "$WORK/stock-confs.txt" --image-paths "$WORK/image-paths.txt" --extra-packages "hostapd dnsmasq"; }

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    t_skip "the Calamares overlay analysis (needs python3 with PyYAML; pip install pyyaml)"
    if [ "${VERIFY_SELFTEST_REQUIRE_ALL:-0}" = 1 ]; then t_fail "VERIFY_SELFTEST_REQUIRE_ALL=1 and python3/PyYAML are missing"; fi
else
    # shellcheck disable=SC2034
    V_WORKDIR="$WORK"   # read by v_run_calamares_py
    mk_cal_tree "$WORK/caltree.good"
    good "a Calamares overlay tree that satisfies the static checks" calrun "$WORK/caltree.good"
    cal_mut() { # cal_mut LABEL REGEX FILE SED-EXPR [extra file to create: path|content]
        rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
        if [ -n "$3" ]; then mut "$WORK/caltree.m/$3" "$4"; fi
        bad "calamares: $1" "$2" calrun "$WORK/caltree.m"
    }
    cal_mut "bootloader limine instead of grub" "efiBootLoader is 'limine'" modules/bootloader.conf 's/"grub"/"limine"/'
    cal_mut "efiBootloaderId cachyos" "efiBootloaderId is 'cachyos'" modules/bootloader.conf 's/companion-os/cachyos/'
    cal_mut "no docker group" "lacks docker" modules/users.conf '/- name: docker/,/system: true/d'
    cal_mut "hostname template cachyos-\${cpu}" "hostname template" modules/users.conf 's/template: .*/template: "cachyos-${cpu}"/'
    cal_mut "internetCheckUrl wiki.cachyos.org" "internetCheckUrl is" modules/welcome_online.conf 's#https://ci.computer#https://wiki.cachyos.org#'
    cal_mut "productName CachyOS" "productName is 'CachyOS'|still name CachyOS" branding/companion/branding.desc 's/productName:         Companion OS/productName:         CachyOS/'
    cal_mut "uploadServer to paste.cachyos.org" "uploadServer sends the install log" branding/companion/branding.desc 's/^slideshowAPI: 2/slideshowAPI: 2\nuploadServer:\n    type: "http"\n    url: "https:\/\/paste.cachyos.org"/'
    cal_mut "GRUB_THEME of CachyOS" "GRUB_THEME" modules/grubcfg.conf 's#companion-os#cachyos#'
    cal_mut "Plymouth animation of CachyOS" "plymouth_theme" modules/plymouthcfg.conf 's/companion-os/cachyos-bootanimation/'
    cal_mut "docker-buildx not installed" "does not get: docker-buildx" modules/packages_online.conf '/docker-buildx/d'
    cal_mut "a required ARCH_DEPS package (dnsmasq) not installed" "does not get: dnsmasq" modules/packages_online.conf '/dnsmasq/d'
    cal_mut "a module the package is built without" "built without" settings_companion.conf 's/  - summary/  - summary\n  - contextualprocess/'
    cal_mut "an instance without its config" "needs .*which neither" settings_companion.conf 's/config: welcome_online.conf/config: welcome_gone.conf/'
    cal_mut "a step whose instance is not defined" "has no instance" settings_companion.conf 's/  - shellprocess@ci_os_stage/  - shellprocess@nowhere/'
    cal_mut "staging before pacstrap" "before pacstrap" settings_companion.conf 's/  - pacstrap/  - shellprocess@ci_os_stage\n  - pacstrap/; 0,/  - shellprocess@ci_os_stage$/!{/  - shellprocess@ci_os_stage$/d;}'
    cal_mut "branding that is not a component" "not a branding.desc whose componentName" settings_companion.conf 's/^branding: companion/branding: elsewhere/'
    cal_mut "YAML that does not parse" "does not parse" modules/grubcfg.conf 's/^defaults:/defaults: [unclosed/'
    cal_mut "a GitHub-raw URL in a script" "raw.githubusercontent.com" modules/shellprocess_ci_os_stage.conf 's#cp -a#curl https://raw.githubusercontent.com/x/y -o /tmp/y; cp -a#'
    cal_mut "paste.cachyos.org in a script" "paste.cachyos.org" modules/shellprocess_ci_os_stage.conf 's#cp -a#curl https://paste.cachyos.org -o /tmp/y; cp -a#'
    cal_mut "no step enables docker" "enables docker" modules/shellprocess_ci_os_stage.conf '/systemctl enable/d'
    cal_mut "a progress text that names CachyOS" "progress text names CachyOS" modules/shellprocess_ci_os_stage.conf 's/^dontChroot: true/dontChroot: true\ni18n:\n    name: "Preparing CachyOS"/'
    cal_mut "a path the overlay stages that is not in the image" "not in the image" modules/shellprocess_ci_os_stage.conf 's#/usr/lib/ci-os/target-payload/#/usr/lib/ci-os/missing-payload/#'
    cal_mut "a missing welcome image" "missing or not PNG" branding/companion/branding.desc 's/welcome.png/gone.png/'
    cal_mut "sidebar colour that is not #rrggbb" "not #rrggbb" branding/companion/branding.desc 's/#041620/dark/'
    cal_mut "GRUB theme that is not in the image" "GRUB_THEME .* is not in the image" modules/grubcfg.conf 's#companion-os/theme.txt#companion-os/gone.txt#'
    cal_mut "Plymouth theme that is not in the image" "plymouth_theme=other" modules/plymouthcfg.conf 's/plymouth_theme: companion-os/plymouth_theme: other/'
    cal_mut "no step runs the carry-over script the image ships" "no shellprocess step runs it" modules/shellprocess_ci_os_stage.conf '/installed\/carry-over/d'
    cal_mut "carry-over after the bootloader (it already read the themes)" "already read the themes" settings_companion.conf '/^  - shellprocess@ci_os_stage$/d; s/^  - umount$/  - shellprocess@ci_os_stage\n  - umount/'
    cal_mut "carry-over before the packages" "before the packages are installed" settings_companion.conf '/^  - shellprocess@ci_os_stage$/d; s/^  - packages@online$/  - shellprocess@ci_os_stage\n  - packages@online/'
    # --- the first-boot unit must not hold the boot targets (ISO #4: graphical.target after 16 min 27 s) and must have HOME ---
    U=target/units/ci-os-first-boot-setup.service
    cal_mut "the ISO #4 first-boot unit: a oneshot linked into multi-user.target" "holds up the boot targets.*Type=oneshot" "$U" 's/^Type=exec/Type=oneshot/'
    cal_mut "a first-boot unit ordered after network-online.target while linked into multi-user.target" "holds up the boot targets.*network-online" "$U" 's/^Description=.*/Description=x\nAfter=network-online.target/'
    cal_mut "a first-boot unit with Wants=network-online.target while linked into multi-user.target" "holds up the boot targets.*network-online" "$U" 's/^Description=.*/Description=x\nWants=network-online.target/'
    cal_mut "a first-boot unit that runs Before=graphical.target" "holds up the boot targets.*Before=graphical.target" "$U" 's/^Description=.*/Description=x\nBefore=graphical.target/'
    cal_mut "a first-boot unit of Type=notify" "holds up the boot targets.*Type=notify" "$U" 's/^Type=exec/Type=notify/'
    cal_mut "a first-boot unit without HOME" "does not set HOME" "$U" '/^Environment=HOME/d'
    cal_mut "a first-boot unit with Restart=" "has Restart=" "$U" 's/^Nice=10/Nice=10\nRestart=on-failure/'
    cal_mut "a first-boot unit that is killed after 5 minutes" "RuntimeMaxSec=300" "$U" 's/^Nice=10/Nice=10\nRuntimeMaxSec=300/'
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"; rm "$WORK/caltree.m/$U"
    bad "calamares: no first-boot unit in the overlay" "no target/units/ci-os-first-boot-setup.service" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    sed -i.bak 's/^Type=exec/Type=simple/' "$WORK/caltree.m/$U" && rm "$WORK/caltree.m/$U.bak"
    good "calamares: Type=simple is fine too (the start job is done when the process has been forked)" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    sed -i.bak 's/^Type=exec/Type=oneshot/; s/^WantedBy=.*/WantedBy=timers.target/' "$WORK/caltree.m/$U" && rm "$WORK/caltree.m/$U.bak"
    good "calamares: a oneshot is fine when it is not linked into a boot target (timer-started)" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"; rm "$WORK/caltree.m/target/bootstrap/backends/cachyos/provision/progress-filter.sh"
    bad "calamares: the provisioning tree without progress-filter.sh (the first-boot log floods with redraws again)" "progress-filter.sh is not in the overlay" calrun "$WORK/caltree.m"
    # --- the installer's stylesheet: the colour scheme's Highlight equals the window colour, so the stock widgets are invisible ---
    Q=branding/companion/stylesheet.qss
    cal_mut "a stylesheet without the progress bar rules" "progress bar is not styled" "$Q" '/^QProgressBar/d'
    cal_mut "a progress bar whose fill is the colour of its track" "progress bar is not styled" "$Q" 's/QProgressBar::chunk { background-color: #0d7a6e/QProgressBar::chunk { background-color: #041620/'
    cal_mut "progress bar text that does not read on the fill (muted green on green)" "progress bar is not styled" "$Q" 's/color: #e8f2f4/color: #409b9b/'
    cal_mut "a progress bar fill too close to its track (below 3:1)" "progress bar is not styled" "$Q" 's/QProgressBar::chunk { background-color: #0d7a6e/QProgressBar::chunk { background-color: #0a2e38/'
    cal_mut "no selection colours for item views" "no selection colours" "$Q" '/^QAbstractItemView/d'
    cal_mut "selection text that is not 7:1 on its row" "no selection colours" "$Q" 's/selection-color: #041620/selection-color: #0d7a6e/'
    cal_mut "the Welcome link buttons keep their stock pictogram" "link buttons keep" "$Q" '/^#supportButton,$/,/^#knownIssuesButton/d'
    cal_mut "a placeholder that stage-installer.sh did not fill" "unfilled placeholder" "$Q" 's/#041620; border/@CTRL_TRACK@; border/'
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"; rm "$WORK/caltree.m/$Q"
    bad "calamares: no stylesheet at all" "no branding/companion/stylesheet.qss" calrun "$WORK/caltree.m"
    # --- the bootloader chooser: a picture of ours, not Calamares' zip-archive placeholder ---
    cal_mut "a chooser item with Calamares' built-in placeholder" "built-in picture" modules/packagechooser_bootloader.conf 's#screenshot: .*#screenshot: ":/images/no-selection.png"#'
    cal_mut "a chooser item without a screenshot" "has no screenshot" modules/packagechooser_bootloader.conf '/screenshot:/d'
    cal_mut "a chooser picture that is not in the overlay's branding directory" "not in the overlay's branding directory" modules/packagechooser_bootloader.conf 's#bootloader.png#gone.png#'
    # --- what the installed system gets, and the package pages ---
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    cat > "$WORK/caltree.m/modules/netinstall.yaml" <<'EOF'
- name: "Plasma desktop (hidden)"
  description: "KDE Plasma, the Companion OS desktop, with everything that a long hidden description may say, because nobody ever sees it on a page"
  hidden: true
  selected: true
  critical: true
  packages:
    - plasma-desktop
    - konsole
- name: "Firefox and language package"
  description: "Web browser for the Companion OS apps, in your language"
  hidden: false
  selected: true
  packages:
    - firefox
EOF
    good "calamares: a package page whose visible descriptions are short (a long hidden one is never shown)" calrun "$WORK/caltree.m"
    sed -i.bak 's/^    - konsole/    - konsole\n    - cachy-update/' "$WORK/caltree.m/modules/netinstall.yaml" && rm "$WORK/caltree.m/modules/netinstall.yaml.bak"
    bad "calamares: cachy-update in a selected package group (ISO #4: a Cachy-Update menu entry and a tray icon)" "does not get cachy-update|gets cachy-update" calrun "$WORK/caltree.m"
    sed -i.bak '/cachy-update/d' "$WORK/caltree.m/modules/netinstall.yaml" && rm "$WORK/caltree.m/modules/netinstall.yaml.bak"
    sed -i.bak 's/^  description: "Web browser for the Companion OS apps, in your language"/  description: "Web browser (the Companion OS apps are web based) with the language pack of the language you chose"/' "$WORK/caltree.m/modules/netinstall.yaml" && rm "$WORK/caltree.m/modules/netinstall.yaml.bak"
    bad "calamares: a visible package group description of 98 characters (cut off at the window edge on ISO #4)" "cut off at the edge of the installer window" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    printf -- '---\nunits:\n  - name: "docker"\n    action: "enable"\n    mandatory: false\n  - name: "arch-update.timer"\n    action: "enable"\n    mandatory: false\n    user: true\n' > "$WORK/caltree.m/modules/services-systemd.conf"
    bad "calamares: services-systemd enables arch-update.timer (the user timer of cachy-update)" "enables arch-update.timer" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    sed -i.bak 's/^efiBootLoader: "grub"/efiBootLoader: "grub"\nefiBootLoaderVar: "packagechooser_bootloader"/' "$WORK/caltree.m/modules/bootloader.conf" && rm "$WORK/caltree.m/modules/bootloader.conf.bak"
    good "calamares: efiBootLoaderVar is fine when the page offers only grub" calrun "$WORK/caltree.m"
    sed -i.bak 's/^items:/items:\n    - id: limine\n      name: "Limine"/' "$WORK/caltree.m/modules/packagechooser_bootloader.conf" && rm "$WORK/caltree.m/modules/packagechooser_bootloader.conf.bak"
    bad "calamares: bootloader var answered by a page that also offers limine" "expected only grub" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    sed -i.bak 's/^efiBootLoader: "grub"/efiBootLoader: "grub"\nefiBootLoaderVar: "packagechooser_bootloader"/' "$WORK/caltree.m/modules/bootloader.conf" && rm "$WORK/caltree.m/modules/bootloader.conf.bak"
    sed -i.bak 's/^default: grub/default: limine/' "$WORK/caltree.m/modules/packagechooser_bootloader.conf" && rm "$WORK/caltree.m/modules/packagechooser_bootloader.conf.bak"
    bad "calamares: bootloader var answered by a page whose default is not grub" "expected only grub" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    sed -i.bak 's/^efiBootLoader: "grub"/efiBootLoader: "grub"\nefiBootLoaderVar: "packagechooser_bootloader"/' "$WORK/caltree.m/modules/bootloader.conf" && rm "$WORK/caltree.m/modules/bootloader.conf.bak"
    rm "$WORK/caltree.m/modules/packagechooser_bootloader.conf"
    bad "calamares: efiBootLoaderVar with no page that answers it" "no packagechooser config offering it" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    printf '# the upstream value was https://wiki.cachyos.org and https://paste.cachyos.org\n' >> "$WORK/caltree.m/modules/welcome_online.conf"
    good "calamares: a comment may name the CachyOS host it replaced" calrun "$WORK/caltree.m"
    printf 'guards: wiki.cachyos.org\n' > "$WORK/caltree.m/guards.list"
    good "calamares: guards.list is data for the launcher, not configuration" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"; rm "$WORK/caltree.m/modules/bootloader.conf"
    bad "calamares: no bootloader config at all" "no bootloader config" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    printf -- '---\ngroupsUrl:\n  - https://raw.githubusercontent.com/CachyOS/cachyos-calamares/cachyos-dev/netinstall.yaml\n  - file:///etc/calamares/modules/netinstall.yaml\nrequired: true\n' > "$WORK/caltree.m/modules/netinstall.conf"
    bad "calamares: netinstall that fetches package groups from GitHub" "groupsUrl fetches" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    printf -- '---\ngroupsUrl:\n  - file:///etc/calamares/modules/netinstall.yaml\nrequired: true\n' > "$WORK/caltree.m/modules/netinstall.conf"
    good "calamares: netinstall with a local groups file only" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"; cp -R "$WORK/caltree.good" "$WORK/caltree.m"
    mkdir -p "$WORK/caltree.m/target/bootstrap/payload" "$WORK/caltree.m/scripts"
    printf '[global]\ninterface=wlan0\nssid=Companion\n' > "$WORK/caltree.m/target/bootstrap/payload/hostapd-setup.conf"
    good "calamares: the provisioning tree copied to the target (target/) is data, not Calamares YAML" calrun "$WORK/caltree.m"
    # the step runs a script of the overlay, and that script runs carry-over (how stage-installer.sh arranges it)
    printf '#!/bin/bash\n/usr/share/ci-os/installed/carry-over "$1"\ncp -a /usr/lib/ci-os/target-payload/. "$1"/\nchroot "$1" systemctl enable docker.service\n' > "$WORK/caltree.m/scripts/ci-os-stage-target.sh"
    printf -- '---\ndontChroot: true\nscript:\n    - command: "bash /usr/share/ci-os/calamares/scripts/ci-os-stage-target.sh ${ROOT}"\n' > "$WORK/caltree.m/modules/shellprocess_ci_os_stage.conf"
    printf '/usr/share/ci-os/calamares/scripts/ci-os-stage-target.sh\n' >> "$WORK/image-paths.txt"
    good "calamares: a step that reaches carry-over and the payload through a script of the overlay" calrun "$WORK/caltree.m"
    # a chroot step names paths of the target, which are not in the live image
    printf -- '---\ndontChroot: false\nscript:\n    - command: "/usr/lib/ci-os/ci-os-post-install-fixups.sh ${USER}"\n' > "$WORK/caltree.m/modules/shellprocess_ci_os_fixups.conf"
    sed -i.bak 's/^  module: shellprocess\n  config: shellprocess_ci_os_stage.conf//' "$WORK/caltree.m/settings_companion.conf" && rm -f "$WORK/caltree.m/settings_companion.conf.bak"
    good "calamares: a chroot step may name paths that only the target has" calrun "$WORK/caltree.m"
    rm -rf "$WORK/caltree.m"
    bad "calamares: a tree that does not exist" "does not exist" calrun "$WORK/no-such-tree"
    mkdir "$WORK/caltree.empty"
    bad "calamares: an empty tree" "is empty" calrun "$WORK/caltree.empty"
    # Without python the helper reports a visible skip, never a pass.
    mkdir -p "$WORK/nopython"
    PATH_SAVE="$PATH"; PASS=0; FAIL=0; SKIPPED=()
    # shellcheck disable=SC2123
    PATH="$WORK/nopython"
    v_run_calamares_py "$WORK/caltree.good" > "$WORK/nopy.out" 2>&1
    PATH="$PATH_SAVE"
    if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ] && [ "${#SKIPPED[@]}" -eq 1 ]; then t_pass "without python3 the Calamares analysis is a visible SKIP, not a pass"; else t_fail "without python3 the Calamares analysis gave PASS=$PASS FAIL=$FAIL skipped=${#SKIPPED[@]}"; fi
fi

#=== the whole script, on the demo ISO's own report text ================================================================
# (the real run is: verify-iso.sh on an ISO; see backends/cachyos/README.md)
if [ "$("$VERIFY" 2>&1 | head -n 1 | grep -c usage)" = 1 ]; then t_pass "verify-iso.sh without arguments prints usage"; else t_fail "verify-iso.sh without arguments did not print usage"; fi
"$VERIFY" "$WORK/does-not-exist.iso" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then t_pass "verify-iso.sh exits 2 for a missing ISO"; else t_fail "verify-iso.sh exited $rc for a missing ISO, expected 2"; fi

# The wiring of the compat check in verify_main (the functions above are driven on fixtures; this is the one line that runs them on a real
# image, and verify-mini-iso.sh is the only run that goes through it): the lock's libraries are extracted from the squashfs, then the check
# gets the listing, the extraction root, the record inside the image and the one next to the ISO.
DESC="verify_main extracts the lock's libraries from the squashfs and runs v_check_compat_libs on the record inside the image and the one next to the ISO"
if grep -q 'v_sfs_extract_paths "\$SQ" "\$R" \$clibs' "$VERIFY" && grep -q 'v_check_compat_libs "\$clock" "\$L" "\$R" "\$R/usr/share/ci-os/iso-build-info" "\$bi"' "$VERIFY" \
  && [ "$(grep -n 'v_sfs_extract_paths "\$SQ" "\$R" \$clibs' "$VERIFY" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'v_check_compat_libs "\$clock"' "$VERIFY" | head -n 1 | cut -d: -f1)" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="verify_main looks for compat-libs.lock next to upstream.lock's directory (backends/cachyos) unless VERIFY_COMPAT_LOCK says otherwise"
if grep -q 'clock="\${VERIFY_COMPAT_LOCK:-\$repo_guess/compat-libs.lock}"' "$VERIFY"; then t_pass "$DESC"; else t_fail "$DESC"; fi

printf '\n== Summary: %d passed, %d failed, %d skipped\n' "$T_PASS" "$T_FAIL" "$T_SKIP"
[ "$T_FAIL" -eq 0 ]
