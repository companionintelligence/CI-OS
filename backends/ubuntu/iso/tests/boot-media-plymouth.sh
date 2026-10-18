#!/usr/bin/env bash
#=============================================================================
# Test: brand_boot_media paints the live initrd's Plymouth themes and only APPENDS to the stock initrd
#
# The live session's splash is drawn from Plymouth files inside casper/initrd, and until this step the overlay
# build-iso.sh appends carried only the watermark and casper.conf: the live boot kept the stock
# black ground, white progress bar, the text splash "Ubuntu 26.04" on aubergine and Ubuntu's firmware-logo fallback.
# brand_boot_media now also puts the initrd's own bgrt.plymouth, spinner.plymouth and ubuntu-text.plymouth, repainted
# with the shared helpers, and the rootfs bgrt-fallback.png into the overlay. The overlay layout is delicate (the
# kernel unpacks concatenated archives in order, and verify-iso.sh finds ours by its zstd magic), so this test builds a
# stock-SHAPED initrd (Ubuntu 26.04.1's: three uncompressed early archives, AMD microcode, Intel microcode and the firmware
# files, then a zstd cpio; plus a variant with the single archive), runs the real function and checks that
#
#   layout      the first bytes of the new initrd ARE the stock initrd, then NUL padding to 4 bytes, then one zstd
#               cpio frame to the end of the file (the kernel skips the NULs and unpacks the frame over the stock
#               files; unmkinitramfs, which decodes a zstd stream with the padding in it as garbage, is not asked);
#   overlay     the archive holds exactly the branded files, every directory entry in it is mode 755 (also when the
#               build runs under umask 077: the kernel applies directory modes from later archives);
#   themes      bgrt.plymouth and spinner.plymouth carry the canon ground and progress colours and differ from the
#               stock files in no other line (the initrd's fonts stay) but UseFirmwareBackground: the stock bgrt asks for
#               the firmware background in every mode, which makes the two-step plugin paint black whatever the ground
#               says (see ci_plymouth_recolor), so all three sections say false and no `true` is left; ubuntu-text.plymouth
#               is the Companion OS theme titled with CI_OS_VERSION, and the fallback and watermark are the chroot's files;
#   merge       the way the kernel unpacks it (the stock archives, then the overlay over them: later files win) the tree
#               differs from the stock tree in exactly the overlay's files and nowhere else;
#   spelling    Plymouth's parser takes blanks around "=" and 1/y/yes/true in any case: a bgrt that spells the key that way
#               is switched off too (a build that left one on would ship a black splash);
#   failure     an initrd that cannot be unpacked, has no bgrt.plymouth, has a theme without colour lines to repaint,
#               or a chroot without the branded fallback all fail the function and leave the initrd untouched.
#
# With CI_TEST_STOCK_INITRD=<path to a real stock casper/initrd> the same checks also run on it.
#
# Needs root-free tools only: unmkinitramfs (initramfs-tools-core), cpio, zstd. Run it in a throw-away container,
# with the repo mounted read-only:
#
#   docker run --rm -v "$PWD:/repo:ro" <ubuntu:26.04 image with initramfs-tools-core cpio zstd> \
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
# The three theme files have the shape (keys, order, fonts, colours) of the ones in Ubuntu 26.04.1's casper initrd (read off the real one).
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

[shutdown]
UseEndAnimation=false
UseFirmwareBackground=true

[reboot]
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
title=Ubuntu 26.04
black=0x2c001e
white=0xffffff
brown=0xff4012
blue=0x988592
EOF
    # (26.04.1: the initrd's watermark.png is a SYMLINK to ../../../pixmaps/ubuntu-logo-text-dark.png, and there is no usr/share/plymouth/ubuntu-logo.png;
    # the overlay's regular file replaces the link)
    ln -s ../../../pixmaps/ubuntu-logo-text-dark.png "$t/spinner/watermark.png"
    mkdir -p "$1/usr/share/pixmaps"; printf 'stock wordmark\n' > "$1/usr/share/pixmaps/ubuntu-logo-text-dark.png"
    printf 'stock ubuntu fallback logo\n' > "$t/spinner/bgrt-fallback.png"
    printf 'stock frame\n' > "$t/spinner/animation-0001.png"
    mkdir -p "$1/etc" "$1/scripts"
    printf 'export USERNAME="ubuntu"\nexport HOST="ubuntu"\n' > "$1/etc/casper.conf"
    printf '#!/bin/sh\n' > "$1/scripts/casper"
}
cpio_of() { ( cd "$1" && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc -R 0:0 ); } # cpio_of <dir>
make_initrd() { # make_initrd <out> <early|plain> <root>: three early archives + zstd main, or the one zstd archive
    # Ubuntu's initrd is not 4-byte aligned (26.04.1's is 95487354 bytes, so the overlay needs 2 NULs of padding): grow a junk file
    # in a copy of the root until the result is unaligned too, so the padding is tested. The early archives are 26.04.1's: AMD microcode,
    # Intel microcode (with its alignment pad file) and the firmware files, each uncompressed.
    local out="$1" kind="$2" root="$3" early n=0 copy="$TMP/root-copy.$$"
    while :; do
        rm -rf "$copy"; cp -a "$root" "$copy"; mkdir -p "$copy/etc"; head -c "$n" /dev/urandom > "$copy/etc/zz-pad"
        if [[ "$kind" == early ]]; then
            early="$TMP/early.$$"; rm -rf "$early"; mkdir -p "$early/kernel/x86/microcode"
            head -c 1024 /dev/zero | tr '\0' 'A' > "$early/kernel/x86/microcode/AuthenticAMD.bin"
            cpio_of "$early" > "$out"
            rm -rf "$early"; mkdir -p "$early/kernel/x86/microcode"
            head -c 2048 /dev/zero | tr '\0' 'M' > "$early/kernel/x86/microcode/GenuineIntel.bin"
            : > "$early/kernel/x86/microcode/.enuineIntel.align.0123456789abc"
            cpio_of "$early" >> "$out"
            rm -rf "$early"; mkdir -p "$early/usr/lib/firmware"
            head -c 4096 /dev/zero | tr '\0' 'F' > "$early/usr/lib/firmware/fixture.bin.zst"
            cpio_of "$early" >> "$out"
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
tree_sums() { # tree_sums <dir>: "<path><TAB><sha256 of the content, or the link target>" per file and link, sorted
    ( cd "$1" && find . \( -type f -o -type l \) | while IFS= read -r f; do
        if [[ -L "$f" ]]; then printf '%s\tlink:%s\n' "$f" "$(readlink "$f")"; else printf '%s\t%s\n' "$f" "$(sha256sum < "$f" | cut -d' ' -f1)"; fi
    done ) | LC_ALL=C sort
}
firmware_modes() { # firmware_modes <theme>: UseFirmwareBackground of the boot-up, shutdown and reboot sections
    awk '/^\[/ { sec = substr($0, 2, length($0) - 2); next } /^UseFirmwareBackground=/ { v[sec] = substr($0, index($0, "=") + 1) }
         END { printf "%s %s %s\n", v["boot-up"], v["shutdown"], v["reboot"] }' "$1"
}

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
             "./etc/casper.conf ./usr/share/plymouth/themes/bgrt/bgrt.plymouth ./usr/share/plymouth/themes/spinner/bgrt-fallback.png ./usr/share/plymouth/themes/spinner/spinner.plymouth ./usr/share/plymouth/themes/spinner/watermark.png ./usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth"
    expect "[$label] every directory entry in the overlay is drwxr-xr-x (built under umask 077)" \
        bash -c "! cpio -tv < '$ov.cpio' 2>/dev/null | grep '^d' | grep -v -q '^drwxr-xr-x' && cpio -tv < '$ov.cpio' 2>/dev/null | grep -q '^drwxr-xr-x'"
    # The stock tree, as initramfs-tools 0.151's unmkinitramfs unpacks it: every segment flat into the target (no early/ and main/).
    xs="$TMP/x-stock-$label"; rm -rf "$xs"; mkdir -p "$xs"
    unmkinitramfs "$stock" "$xs" >/dev/null 2>&1

    ground="$(ci_hex0x "$CI_DARK_BACKGROUND")"; track="$(ci_hex0x "$CI_DARK_SECONDARY")"; fill="$(ci_hex0x "$CI_DARK_PRIMARY")"
    t="usr/share/plymouth/themes"
    for theme in bgrt spinner; do
        conf="$ov/$t/$theme/$theme.plymouth"
        expect "[$label] $theme.plymouth: canon ground $ground, progress $fill on $track" \
            bash -c "grep -q -x 'BackgroundStartColor=$ground' '$conf' && grep -q -x 'BackgroundEndColor=$ground' '$conf' && grep -q -x 'ProgressBarForegroundColor=$fill' '$conf' && grep -q -x 'ProgressBarBackgroundColor=$track' '$conf'"
        if [[ "$theme" == bgrt ]]; then
            expect "[$label] bgrt.plymouth differs from the stock file in the four colour lines and UseFirmwareBackground only (fonts stay)" \
                test "$(changed_keys "$xs/$t/$theme/$theme.plymouth" "$conf")" = \
                     "BackgroundEndColor BackgroundStartColor ProgressBarBackgroundColor ProgressBarForegroundColor UseFirmwareBackground"
            # In the early and plain cases the "stock" file is this test's own write_stock_themes text, so this only keeps the
            # fixture honest (the change below would otherwise prove nothing). That Ubuntu's own file asks for it is shown by the
            # [real] case (CI_TEST_STOCK_INITRD), desktop-theme/tests/plymouth-theme.sh and tests/plymouth-ground-render.sh.
            expect "[$label] stock bgrt asks for the firmware background in boot-up, shutdown and reboot (fixture-only unless [real]; the precondition of the fix)" \
                test "$(firmware_modes "$xs/$t/$theme/$theme.plymouth")" = "true true true"
            expect "[$label] bgrt.plymouth switches it off in boot-up, shutdown and reboot, so the plugin draws the ground, not black" \
                test "$(firmware_modes "$conf")" = "false false false"
        else
            expect "[$label] spinner.plymouth differs from the stock file in the four colour lines only (fonts stay)" \
                test "$(changed_keys "$xs/$t/$theme/$theme.plymouth" "$conf")" = \
                     "BackgroundEndColor BackgroundStartColor ProgressBarBackgroundColor ProgressBarForegroundColor"
        fi
        expect "[$label] $theme.plymouth has no UseFirmwareBackground=true left" bash -c "! grep -q -E '^UseFirmwareBackground=true' '$conf'"
    done
    expect "[$label] the initrd's bgrt keeps its Ubuntu font" grep -q -x 'Font=Ubuntu 12' "$ov/$t/bgrt/bgrt.plymouth"
    expect "[$label] text splash: Companion OS $CI_OS_VERSION on the ubuntu-text module, no aubergine" \
        bash -c "grep -q -x 'title=Companion OS $CI_OS_VERSION' '$ov/$t/ubuntu-text/ubuntu-text.plymouth' && grep -q -x 'ModuleName=ubuntu-text' '$ov/$t/ubuntu-text/ubuntu-text.plymouth' && ! grep -qi '0x2c001e' '$ov/$t/ubuntu-text/ubuntu-text.plymouth'"
    expect "[$label] text splash: ground is the canon dark background $ground" \
        grep -q -x "black=$ground" "$ov/$t/ubuntu-text/ubuntu-text.plymouth"
    expect "[$label] fallback logo is the chroot's branded file" cmp -s "$ov/$t/spinner/bgrt-fallback.png" "$w/chroot/$t/spinner/bgrt-fallback.png"
    expect "[$label] the watermark is the chroot's branded watermark, as a regular file (the stock one is a symlink into pixmaps)" \
        bash -c "cmp -s '$ov/$t/spinner/watermark.png' '$w/chroot/$t/spinner/watermark.png' && [ ! -L '$ov/$t/spinner/watermark.png' ]"
    expect "[$label] there is no ubuntu-logo.png in the overlay (the 26.04.1 initrd has none to replace)" test ! -e "$ov/usr/share/plymouth/ubuntu-logo.png"
    expect "[$label] casper.conf is the chroot's" cmp -s "$ov/etc/casper.conf" "$w/chroot/etc/casper.conf"
    # What the kernel ends up with: the stock archives unpacked, then the overlay over them (cpio -u: later files win). The
    # tree must differ from the stock tree in the overlay's files and in nothing else.
    local merged="$TMP/merged-$label" changed want
    rm -rf "$merged"; mkdir -p "$merged"; cp -a "$xs/." "$merged/"
    ( cd "$merged" && cpio -idu --quiet < "$ov.cpio" )
    changed="$(LC_ALL=C comm -3 <(tree_sums "$xs") <(tree_sums "$merged") | sed -e 's/^\t//' | cut -f1 | LC_ALL=C sort -u | paste -sd' ' -)"
    want="$(cd "$ov" && find . \( -type f -o -type l \) | LC_ALL=C sort | paste -sd' ' -)"
    expect "[$label] merged the way the kernel does, the tree differs from the stock tree in the overlay's files only" test "$changed" = "$want"
    expect "[$label] ...and every overlay file is what ends up in the merged tree" \
        bash -c "cd '$ov' && find . -type f | while IFS= read -r f; do cmp -s \"\$f\" '$merged'/\"\$f\" || exit 1; done"
}

ROOT="$TMP/root"; mkdir -p "$ROOT"; write_stock_themes "$ROOT"
make_initrd "$TMP/initrd-early" early "$ROOT"
make_initrd "$TMP/initrd-plain" plain "$ROOT"
check_case early "$TMP/initrd-early"
check_case plain "$TMP/initrd-plain"
SPACED="$TMP/root-spaced"; mkdir -p "$SPACED"; write_stock_themes "$SPACED"
sed -i -e '0,/^UseFirmwareBackground=true/s//UseFirmwareBackground = True/' -e '0,/^UseFirmwareBackground=true/s//  UseFirmwareBackground=yes/' \
    "$SPACED/usr/share/plymouth/themes/bgrt/bgrt.plymouth"
make_initrd "$TMP/initrd-spaced" early "$SPACED"
new_work spelling "$TMP/initrd-spaced"; run_brand
expect "[spelling] brand_boot_media succeeds on a bgrt that spells UseFirmwareBackground with blanks, 'True' and 'yes'" test "$RC" -eq 0
sp_size="$(size_of "$TMP/initrd-spaced")"
overlay_of "$WORK_DIR/custom-iso/casper/initrd" "$sp_size" "$TMP/ov-spelling" || true
expect "[spelling] all three sections end up as UseFirmwareBackground=false" \
    test "$(firmware_modes "$TMP/ov-spelling/usr/share/plymouth/themes/bgrt/bgrt.plymouth")" = "false false false"
if [[ -n "${CI_TEST_STOCK_INITRD:-}" ]]; then
    if [[ -f "$CI_TEST_STOCK_INITRD" ]]; then check_case real "$CI_TEST_STOCK_INITRD"; else t_fail "CI_TEST_STOCK_INITRD is not a file: $CI_TEST_STOCK_INITRD"; fi
fi

# ── /.disk/info ──────────────────────────────────────────────────────────────
# The product is spelt "Companion OS" in this data file, with a blank, because ONE of its readers shows it: the installer's last page says
# "<name> is installed and ready to use" with the text before the codename's quote (the recorded 24.04.5 run, written with a hyphen, shows
# "Companion-OS 24.04.5 LTS is installed and ready to use"). What the blank costs the others, measured on 26.04.1's own scripts and asserted
# below: casper's 25adduser (fields 1-2 with "-" as a blank, plus " LTS" when field 3 is LTS) then labels the launcher "Install Companion OS"
# (no release: field 3 is the release, not LTS), and subiquity's refresh.py takes "OS" for the release its snap channel is named after
# (latent only: configure_snapd returns early because the installer snap tracks 26.04/stable/ubuntu-26.04.1, not stable/ubuntu-26.04; verify-iso.sh
# section 5 reads that channel from the image's seed.yaml). This is the stock 26.04.1 line.
info_case() { # info_case <label> <stock first line>: run brand_boot_media over a .disk/info with that line; sets INFO_AFTER
    new_work "info-$1" "$TMP/initrd-early"
    mkdir -p "$WORK_DIR/custom-iso/.disk"
    printf '%s\n' "$2" > "$WORK_DIR/custom-iso/.disk/info"
    run_brand
    INFO_AFTER="$(head -n 1 "$WORK_DIR/custom-iso/.disk/info")"
}
STOCK_INFO='Ubuntu 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)'
info_case stock "$STOCK_INFO"
expect "[disk/info] brand_boot_media succeeds on the 26.04.1 stock line" test "$RC" -eq 0
expect "[disk/info] the line becomes 'Companion OS 26.04.1 LTS \"Resolute Raccoon\" - Release amd64 (20260826)': the product's name with a blank, rest untouched" \
    test "$INFO_AFTER" = 'Companion OS 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)'
expect "[disk/info] the line has no hyphen before the release: the installer's last page shows the text before the codename's quote" \
    test "$(printf '%s\n' "$INFO_AFTER" | sed 's/[[:space:]]*".*$//')" = 'Companion OS 26.04.1 LTS'
expect "[disk/info] subiquity's 'release' (the second whitespace-separated word) is now 'OS' (latent: verify-iso.sh section 5 checks the guard that keeps it unused)" \
    test "$(printf '%s\n' "$INFO_AFTER" | awk '{ print $2 }')" = OS
expect "[disk/info] pollinate's serial (the trailing parentheses) is intact" test "$(printf '%s\n' "$INFO_AFTER" | sed -e 's/.*(\(.*\))$/\1/')" = 20260826
expect "[disk/info] the stock line is kept as .disk/info.orig" test "$(head -n 1 "$WORK_DIR/custom-iso/.disk/info.orig")" = "$STOCK_INFO"
# what is NOT accepted: a base ISO whose first line has another shape is refused, and the file is not rewritten blindly
for bad in 'Kubuntu 26.04 LTS "Resolute Raccoon" - Release amd64 (20260826)' 'Ubuntu 26.04.1 "Resolute Raccoon" - Release amd64 (20260826)' \
           'Ubuntu 26.04.1 LTS "Resolute Raccoon" - Release amd64'; do
    info_case bad "$bad"
    expect "[disk/info] a line the build does not know is refused: $bad" test "$RC" -ne 0
    expect "[disk/info] ...and left as it was" test "$INFO_AFTER" = "$bad"
done
# control: the earlier spelling, with a hyphen, would have put 'Companion-OS' on the installer's last page (the recorded 24.04.5 run shows it)
expect "[disk/info] control: written with a hyphen, the name before the quote would be 'Companion-OS 26.04.1 LTS' (on the installer's last page)" \
    test "$(printf '%s\n' 'Companion-OS 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)' | sed 's/[[:space:]]*".*$//')" = 'Companion-OS 26.04.1 LTS'
# The launcher label, computed with casper's own two lines (casper-bottom/25adduser of casper 26.04.2, in the stock initrd), end to end: what
# the user reads on the installer icon is "Install RELEASE" with RELEASE replaced.
casper_release() { # casper_release <first line of .disk/info>: what 25adduser puts where the launcher's "RELEASE" is
    local f="$TMP/disk-info-line" LTS RELEASE
    printf '%s\n' "$1" > "$f"
    LTS="$(cut -d' ' -f3 "$f" 2>/dev/null)" || LTS=
    RELEASE="$(cut -d' ' -f1-2 "$f" 2>/dev/null | sed 's/-/ /')" || RELEASE=
    if [ "$LTS" = "LTS" ] && [ -n "$RELEASE" ]; then RELEASE="$RELEASE LTS"; fi
    printf '%s\n' "$RELEASE"
}
info_case stock-again "$STOCK_INFO"   # (INFO_AFTER now holds the last refused line of the loop above)
expect "[disk/info] the installer launcher reads 'Install Companion OS' (casper's own label logic over the rewritten line: field 3 is the release, so no ' LTS')" \
    test "$(casper_release "$INFO_AFTER")" = 'Companion OS'
expect "[disk/info] control: written with a hyphen the launcher would read 'Install Companion OS 26.04.1 LTS' (the release and LTS the blank spelling gives up)" \
    test "$(casper_release 'Companion-OS 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)')" = 'Companion OS 26.04.1 LTS'
if [[ -n "${CI_TEST_STOCK_INITRD:-}" && -f "${CI_TEST_STOCK_INITRD:-}" ]]; then
    # the two lines above are copies of the real script's: they must still be there in the initrd of the base ISO
    rm -rf "$TMP/real-initrd-x"
    if unmkinitramfs "$CI_TEST_STOCK_INITRD" "$TMP/real-initrd-x" >/dev/null 2>&1 && adduser_script="$(find "$TMP/real-initrd-x" -path '*scripts/casper-bottom/25adduser' | head -n 1)" && [[ -n "$adduser_script" ]]; then
        cat > "$TMP/casper-label-lines" <<'EOF_LINES'
LTS="$(cut -d' ' -f3 /root/cdrom/.disk/info 2>/dev/null)" || LTS=
RELEASE="$(cut -d' ' -f1-2 /root/cdrom/.disk/info 2>/dev/null | sed 's/-/ /')" || RELEASE=
if [ "$LTS" = "LTS" ] && [ -n "$RELEASE" ]; then
	RELEASE="$RELEASE LTS"
EOF_LINES
        expect "[disk/info] the stock initrd's 25adduser still computes LTS from field 3 and RELEASE from fields 1-2 with the hyphen as a blank" \
            bash -c 'while IFS= read -r l; do grep -q -x -F -- "$l" "$1" || exit 1; done < "$2"' _ "$adduser_script" "$TMP/casper-label-lines"
    else
        t_fail "[disk/info] could not read casper-bottom/25adduser from CI_TEST_STOCK_INITRD"
    fi
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
