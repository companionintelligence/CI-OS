#!/usr/bin/env bash
#=============================================================================
# Test: brand_boot_media paints the live initrd's Plymouth themes and only APPENDS to the stock initrd
#
# The live session's splash is drawn from Plymouth files inside casper/initrd, and until this step the overlay
# build-iso.sh appends carried only watermark.png, ubuntu-logo.png and casper.conf: the live boot kept the stock
# black ground, white progress bar, the text splash "Ubuntu 24.04" on aubergine and Ubuntu's firmware-logo fallback.
# brand_boot_media now also puts the initrd's own bgrt.plymouth, spinner.plymouth and ubuntu-text.plymouth, repainted
# with the shared helpers, and the rootfs bgrt-fallback.png into the overlay. The overlay layout is delicate (the
# kernel unpacks concatenated archives in order, and verify-iso.sh finds ours by its zstd magic), so this test builds a
# stock-SHAPED initrd (an uncompressed early microcode archive, then a zstd cpio, as Ubuntu's, plus a variant with the
# single archive unmkinitramfs unpacks straight into its target), runs the real function and checks that
#
#   layout      the first bytes of the new initrd ARE the stock initrd, then NUL padding to 4 bytes, then one zstd
#               cpio frame to the end of the file (the kernel skips the NULs and unpacks the frame over the stock
#               files; unmkinitramfs, which decodes a zstd stream with the padding in it as garbage, is not asked);
#   overlay     the archive holds exactly the branded files, every directory entry in it is mode 755 (also when the
#               build runs under umask 077: the kernel applies directory modes from later archives);
#   themes      bgrt.plymouth and spinner.plymouth carry the canon ground and progress colours and differ from the
#               stock files in no other line (the initrd's fonts stay), ubuntu-text.plymouth is the Companion OS
#               theme titled with CI_OS_VERSION, and the fallback and watermark are the chroot's files;
#   failure     an initrd that cannot be unpacked, has no bgrt.plymouth, has a theme without colour lines to repaint,
#               or a chroot without the branded fallback all fail the function and leave the initrd untouched.
#
# With CI_TEST_STOCK_INITRD=<path to a real stock casper/initrd> the same checks also run on it.
#
# Needs root-free tools only: unmkinitramfs (initramfs-tools-core), cpio, zstd. Run it in a throw-away container,
# with the repo mounted read-only:
#
#   docker run --rm -v "$PWD:/repo:ro" <ubuntu:24.04 image with initramfs-tools-core cpio zstd> \
#       bash /repo/backends/ubuntu/iso/tests/boot-media-plymouth.sh
#
# Exit status is non-zero if any check fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sourcing build-iso.sh only defines its functions (main runs only when it is executed).
# shellcheck source=../scripts/build-iso.sh
source "$HERE/../scripts/build-iso.sh"
# shellcheck source=../../../../vendor/brand/tokens/tokens.sh
source "$REPO_ROOT/vendor/brand/tokens/tokens.sh"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { # expect "<label>" <command...>
    local label="$1"; shift
    if "$@"; then t_pass "$label"; else t_fail "$label"; fi
}

for t in unmkinitramfs cpio zstd cmp; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t (apt-get install initramfs-tools-core cpio zstd)" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CI_OS_VERSION=7.3

# ── a stock-shaped initrd ───────────────────────────────────────────────────
# The three theme files have the shape (keys, order, fonts, colours) of the ones in Ubuntu 24.04's casper initrd.
write_stock_themes() { # write_stock_themes <root>
    local t="$1/usr/share/plymouth/themes"
    mkdir -p "$t/bgrt" "$t/spinner" "$t/ubuntu-text"
    cat > "$t/bgrt/bgrt.plymouth" <<'EOF'
[Plymouth Theme]
Name=BGRT
Description=Jimmac's spinner theme using the ACPI BGRT graphics as background
ModuleName=two-step

[two-step]
Font=Ubuntu 12
TitleFont=Ubuntu Light 30
ImageDir=/usr/share/plymouth/themes//spinner
DialogHorizontalAlignment=.5
WatermarkVerticalAlignment=.96
Transition=none
TransitionDuration=0.0
BackgroundStartColor=0x000000
BackgroundEndColor=0x000000
ProgressBarBackgroundColor=0x606060
ProgressBarForegroundColor=0xffffff
DialogClearsFirmwareBackground=false
MessageBelowAnimation=true

[boot-up]
UseEndAnimation=false
UseFirmwareBackground=true

[updates]
SuppressMessages=true
Title=Installing Updates...
EOF
    cat > "$t/spinner/spinner.plymouth" <<'EOF'
[Plymouth Theme]
Name=Spinner
Description=A theme designed by jimmac that features a simple spinner.
ModuleName=two-step

[two-step]
Font=Cantarell 12
TitleFont=Cantarell Light 30
ImageDir=/usr/share/plymouth/themes//spinner
WatermarkVerticalAlignment=.96
Transition=none
BackgroundStartColor=0x000000
BackgroundEndColor=0x000000
ProgressBarBackgroundColor=0x606060
ProgressBarForegroundColor=0xffffff
MessageBelowAnimation=true

[boot-up]
UseEndAnimation=false
EOF
    cat > "$t/ubuntu-text/ubuntu-text.plymouth" <<'EOF'
[Plymouth Theme]
Name=Ubuntu Text
Description=Text mode theme based on ubuntu-logo theme
ModuleName=ubuntu-text

[ubuntu-text]
title=Ubuntu 24.04
black=0x2c001e
white=0xffffff
brown=0xff4012
blue=0x988592
EOF
    printf 'stock watermark\n' > "$t/spinner/watermark.png"
    printf 'stock ubuntu fallback logo\n' > "$t/spinner/bgrt-fallback.png"
    printf 'stock frame\n' > "$t/spinner/animation-0001.png"
    mkdir -p "$1/etc" "$1/scripts"
    printf 'export USERNAME="ubuntu"\nexport HOST="ubuntu"\n' > "$1/etc/casper.conf"
    printf '#!/bin/sh\n' > "$1/scripts/casper"
}
cpio_of() { ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc -R 0:0 ); } # cpio_of <dir>
make_initrd() { # make_initrd <out> <early|plain> <root>: early microcode archive + zstd main, or the one zstd archive
    # Ubuntu's initrd is not 4-byte aligned (the one this was written against is 90956673 bytes, so the overlay needs 3
    # NULs of padding): grow a junk file in a copy of the root until the result is unaligned too, so the padding is tested.
    local out="$1" kind="$2" root="$3" early n=0 copy="$TMP/root-copy.$$"
    while :; do
        rm -rf "$copy"; cp -a "$root" "$copy"; mkdir -p "$copy/etc"; head -c "$n" /dev/urandom > "$copy/etc/zz-pad"
        if [[ "$kind" == early ]]; then
            early="$TMP/early.$$"; rm -rf "$early"; mkdir -p "$early/kernel/x86/microcode"
            head -c 2048 /dev/zero | tr '\0' 'M' > "$early/kernel/x86/microcode/GenuineIntel.bin"
            cpio_of "$early" > "$out"
            cpio_of "$copy" | zstd -q -3 >> "$out"
        else
            cpio_of "$copy" | zstd -q -3 > "$out"
        fi
        if [[ $(( $(size_of "$out") % 4 )) -ne 0 ]]; then break; fi
        n=$((n + 7))
    done
    rm -rf "$copy"
}

# ── a build work directory around one initrd ────────────────────────────────
new_work() { # new_work <name> <initrd-source>: sets WORK_DIR for brand_boot_media
    WORK_DIR="$TMP/$1"
    rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR/custom-iso/casper" "$WORK_DIR/chroot/etc" "$WORK_DIR/chroot/usr/share/plymouth/themes/spinner"
    cp "$2" "$WORK_DIR/custom-iso/casper/initrd"; chmod 444 "$WORK_DIR/custom-iso/casper/initrd"   # copied from a read-only ISO
    printf 'branded watermark\n' > "$WORK_DIR/chroot/usr/share/plymouth/themes/spinner/watermark.png"
    printf 'branded canon mark fallback\n' > "$WORK_DIR/chroot/usr/share/plymouth/themes/spinner/bgrt-fallback.png"
    printf 'export USERNAME="companion"\nexport HOST="companion-os"\nexport BUILD_SYSTEM="Ubuntu"\nexport FLAVOUR="Companion"\n' > "$WORK_DIR/chroot/etc/casper.conf"
}
OUT=""; RC=0
run_brand() { # run_brand [umask]: captured output and status, without tripping set -e
    set +e
    OUT="$( umask "${1:-022}"; brand_boot_media 2>&1 )"; RC=$?
    set -e
}
size_of() { wc -c < "$1" | tr -d ' '; }
overlay_of() { # overlay_of <initrd> <stock-size> <outdir>: unpack the frame after the stock bytes and its NUL padding
    local initrd="$1" size="$2" out="$3" pad
    pad=$(( (4 - size % 4) % 4 ))
    rm -rf "$out"; mkdir -p "$out"
    tail -c +$((size + pad + 1)) "$initrd" | zstd -dc > "$out.cpio" 2>/dev/null || return 1
    ( cd "$out" && cpio -id --quiet < "$out.cpio" )
}
changed_keys() { # changed_keys <old> <new>: the keys of the lines that differ, sorted
    diff <(sort "$1") <(sort "$2") | sed -n 's/^[<>] \([A-Za-z]*\)=.*/\1/p' | sort -u | paste -sd' ' -
}
nul_only() { [[ -z "$(tail -c +$(($2 + 1)) "$1" | head -c "$3" | tr -d '\0')" ]]; } # nul_only <file> <from> <len>

# check_case <label> <stock initrd>: run the function on a copy of the initrd and check everything about the result
check_case() {
    local label="$1" stock="$2" w size pad ov xs ground track fill theme conf t
    new_work "case-$label" "$stock"
    w="$WORK_DIR"; size="$(size_of "$stock")"; pad=$(( (4 - size % 4) % 4 ))
    run_brand 077
    expect "[$label] brand_boot_media succeeds (also under umask 077)" test "$RC" -eq 0
    if [[ "$RC" -ne 0 ]]; then printf '%s\n' "$OUT" | tail -5; return; fi
    expect "[$label] precondition: the stock initrd is not 4-byte aligned ($size bytes), so the padding is exercised" test "$pad" -ne 0
    expect "[$label] the new initrd starts with the stock initrd, byte for byte" cmp -s -n "$size" "$w/custom-iso/casper/initrd" "$stock"
    expect "[$label] ...then $pad NUL padding bytes, then the overlay frame to the end of the file" \
        bash -c "$(declare -f nul_only); nul_only '$w/custom-iso/casper/initrd' $size $pad"
    ov="$TMP/ov-$label"
    expect "[$label] the bytes after the padding are one zstd cpio archive" overlay_of "$w/custom-iso/casper/initrd" "$size" "$ov"
    expect "[$label] the overlay holds exactly the branded files" \
        test "$(cd "$ov" && find . -type f | LC_ALL=C sort | paste -sd' ' -)" = \
             "./etc/casper.conf ./usr/share/plymouth/themes/bgrt/bgrt.plymouth ./usr/share/plymouth/themes/spinner/bgrt-fallback.png ./usr/share/plymouth/themes/spinner/spinner.plymouth ./usr/share/plymouth/themes/spinner/watermark.png ./usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth ./usr/share/plymouth/ubuntu-logo.png"
    expect "[$label] every directory entry in the overlay is drwxr-xr-x (built under umask 077)" \
        bash -c "! cpio -tv < '$ov.cpio' 2>/dev/null | grep '^d' | grep -v -q '^drwxr-xr-x' && cpio -tv < '$ov.cpio' 2>/dev/null | grep -q '^drwxr-xr-x'"
    # The stock tree, as unmkinitramfs unpacks it: early*/ and main/, or the one archive straight into the target.
    xs="$TMP/x-stock-$label"; rm -rf "$xs"; mkdir -p "$xs"
    unmkinitramfs "$stock" "$xs" >/dev/null 2>&1
    [[ -d "$xs/main" ]] && xs="$xs/main"

    ground="$(ci_hex0x "$CI_DARK_BACKGROUND")"; track="$(ci_hex0x "$CI_DARK_SECONDARY")"; fill="$(ci_hex0x "$CI_DARK_PRIMARY")"
    t="usr/share/plymouth/themes"
    for theme in bgrt spinner; do
        conf="$ov/$t/$theme/$theme.plymouth"
        expect "[$label] $theme.plymouth: canon ground $ground, progress $fill on $track" \
            bash -c "grep -q -x 'BackgroundStartColor=$ground' '$conf' && grep -q -x 'BackgroundEndColor=$ground' '$conf' && grep -q -x 'ProgressBarForegroundColor=$fill' '$conf' && grep -q -x 'ProgressBarBackgroundColor=$track' '$conf'"
        expect "[$label] $theme.plymouth differs from the stock file in the four colour lines only (fonts stay)" \
            test "$(changed_keys "$xs/$t/$theme/$theme.plymouth" "$conf")" = \
                 "BackgroundEndColor BackgroundStartColor ProgressBarBackgroundColor ProgressBarForegroundColor"
    done
    expect "[$label] the initrd's bgrt keeps its Ubuntu font" grep -q -x 'Font=Ubuntu 12' "$ov/$t/bgrt/bgrt.plymouth"
    expect "[$label] text splash: Companion OS $CI_OS_VERSION on the ubuntu-text module, no aubergine" \
        bash -c "grep -q -x 'title=Companion OS $CI_OS_VERSION' '$ov/$t/ubuntu-text/ubuntu-text.plymouth' && grep -q -x 'ModuleName=ubuntu-text' '$ov/$t/ubuntu-text/ubuntu-text.plymouth' && ! grep -qi '0x2c001e' '$ov/$t/ubuntu-text/ubuntu-text.plymouth'"
    expect "[$label] fallback logo is the chroot's branded file" cmp -s "$ov/$t/spinner/bgrt-fallback.png" "$w/chroot/$t/spinner/bgrt-fallback.png"
    expect "[$label] watermark and ubuntu-logo.png are the chroot's branded watermark" \
        bash -c "cmp -s '$ov/$t/spinner/watermark.png' '$w/chroot/$t/spinner/watermark.png' && cmp -s '$ov/usr/share/plymouth/ubuntu-logo.png' '$w/chroot/$t/spinner/watermark.png'"
    expect "[$label] casper.conf is the chroot's" cmp -s "$ov/etc/casper.conf" "$w/chroot/etc/casper.conf"
}

ROOT="$TMP/root"; mkdir -p "$ROOT"; write_stock_themes "$ROOT"
make_initrd "$TMP/initrd-early" early "$ROOT"
make_initrd "$TMP/initrd-plain" plain "$ROOT"
check_case early "$TMP/initrd-early"
check_case plain "$TMP/initrd-plain"
if [[ -n "${CI_TEST_STOCK_INITRD:-}" ]]; then
    if [[ -f "$CI_TEST_STOCK_INITRD" ]]; then check_case real "$CI_TEST_STOCK_INITRD"; else t_fail "CI_TEST_STOCK_INITRD is not a file: $CI_TEST_STOCK_INITRD"; fi
fi

# ── failures leave the initrd untouched ─────────────────────────────────────
fails_untouched() { # fails_untouched <label> <initrd> [what to break: fallback]
    local label="$1" initrd="$2" before
    new_work "fail-$label" "$initrd"
    if [[ "${3:-}" == fallback ]]; then rm -f "$WORK_DIR/chroot/usr/share/plymouth/themes/spinner/bgrt-fallback.png"; fi
    before="$(sha256sum "$WORK_DIR/custom-iso/casper/initrd" | cut -d' ' -f1)"
    run_brand
    expect "$label: brand_boot_media fails" test "$RC" -ne 0
    expect "$label: ...and appended nothing to the initrd" test "$(sha256sum "$WORK_DIR/custom-iso/casper/initrd" | cut -d' ' -f1)" = "$before"
}
head -c 3000 /dev/urandom > "$TMP/initrd-garbage"
fails_untouched "garbage initrd (unmkinitramfs cannot unpack it)" "$TMP/initrd-garbage"
expect "...and the error names unmkinitramfs" bash -c "grep -q 'unmkinitramfs could not unpack' <<<\"\$1\"" _ "$OUT"

NOBGRT="$TMP/root-nobgrt"; mkdir -p "$NOBGRT"; write_stock_themes "$NOBGRT"; rm -rf "$NOBGRT/usr/share/plymouth/themes/bgrt"
make_initrd "$TMP/initrd-nobgrt" early "$NOBGRT"
fails_untouched "initrd with no bgrt.plymouth" "$TMP/initrd-nobgrt"
expect "...and the error names the missing file" bash -c "grep -q 'has no usr/share/plymouth/themes/bgrt/bgrt.plymouth' <<<\"\$1\"" _ "$OUT"

NOCOL="$TMP/root-nocol"; mkdir -p "$NOCOL"; write_stock_themes "$NOCOL"
sed -i '/^BackgroundStartColor=/d;/^BackgroundEndColor=/d' "$NOCOL/usr/share/plymouth/themes/bgrt/bgrt.plymouth"
make_initrd "$TMP/initrd-nocol" early "$NOCOL"
fails_untouched "initrd whose bgrt.plymouth has no colour lines to repaint" "$TMP/initrd-nocol"
expect "...and the error says to review the base ISO" bash -c "grep -q 'has no BackgroundStartColor / ProgressBarForegroundColor line to repaint' <<<\"\$1\"" _ "$OUT"

fails_untouched "chroot without the branded fallback logo" "$TMP/initrd-early" fallback
expect "...and the error names the fallback" bash -c "grep -q 'firmware-logo fallback' <<<\"\$1\"" _ "$OUT"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
