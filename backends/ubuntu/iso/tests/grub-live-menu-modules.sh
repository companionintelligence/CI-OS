#!/usr/bin/env bash
#=============================================================================
# Test: the live GRUB menu insmods only modules that Canonical's signed GRUB has built in
#
# Under Secure Boot shim's lock refuses every module GRUB would load from disk, so a grub.cfg line `insmod X` for a module that is not
# compiled into EFI/boot/grubx64.efi is refused at every boot (GRUB prints an error; whether it also stops for a keypress was not
# tested). build-iso.sh (brand_live_grub) used to insmod all_video, which the 24.04 image had built in and Ubuntu 26.04.1's GRUB 2.14 CD
# image does not (95 built-in modules; the text "feature_all_video_module" in the binary is a feature flag). The producer and
# verify-iso.sh agreed with each other and not with the binary, and nothing could tell until a built ISO was booted.
#
# This test holds the producer to the real image's module list, which is committed (fixtures/grub-cd-builtin-modules-26.04.1.txt, read from
# the stock ISO's EFI/boot/grubx64.efi with stick/scripts/grub-builtin-modules.py):
#
#   G1  the heredoc block in build-iso.sh (the text brand_live_grub inserts) names modules, and every one is in the list   (any shell)
#   G2  control: the list does not hold all_video, and the checker used for G1 rejects the old block (it can fail)         (any shell)
#   G3  the real brand_live_grub on the real stock grub.cfg: every insmod of the result is in the list, and the menu       (GNU sed and stat:
#       still has its background and gfxterm                                                                                a Linux container)
#   G4  the committed list is what the stock image has: with CI_TEST_STOCK_ISO=<ubuntu-26.04.1-desktop-amd64.iso> (7z or
#       xorriso, python3) the list is re-read from the ISO's own binary and must equal the file
#
# Run: bash backends/ubuntu/iso/tests/grub-live-menu-modules.sh        (G1, G2 on a stock macOS; G3 in an Ubuntu 26.04 container)
# Exit status: non-zero if any check fails.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
BUILD="$REPO/backends/ubuntu/iso/scripts/build-iso.sh"
LIST="$HERE/fixtures/grub-cd-builtin-modules-26.04.1.txt"
STOCK_CFG="$HERE/fixtures/stock-26.04.1-grub.cfg"
TOOL="$REPO/stick/scripts/grub-builtin-modules.py"
for f in "$BUILD" "$LIST" "$STOCK_CFG"; do
    [[ -f "$f" ]] || { echo "missing $f (run it from the repo checkout)" >&2; exit 2; }
done

PASS=0; FAIL=0; SKIP=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/grub-live-menu-modules.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# the built-in module names, one per line (comments dropped)
grep -v '^#' "$LIST" | grep -v '^[[:space:]]*$' > "$WORK/builtin.txt"

# modules_of <grub.cfg or block on stdin>: the module names of the `insmod` lines, one per line, sorted, unique
modules_of() {
    awk '$1 == "insmod" { for (i = 2; i <= NF; i++) print $i }' | LC_ALL=C sort -u
}
# not_builtin: modules on stdin that are not in the built-in list
not_builtin() {
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        grep -q -x -F -- "$m" "$WORK/builtin.txt" || printf '%s\n' "$m"
    done
}
# block_of_build_iso <file>: the text of the GRUB_GFX_BLOCK heredoc brand_live_grub inserts
block_of_build_iso() {
    awk '/<<.GRUB_GFX_BLOCK.$/ { f = 1; next } /^GRUB_GFX_BLOCK$/ { f = 0 } f' "$1"
}

echo "== G1/G2: the block build-iso.sh inserts"
block_of_build_iso "$BUILD" > "$WORK/block.cfg"
n_block="$(wc -l < "$WORK/block.cfg" | tr -d ' ')"
if [[ "$n_block" -ge 3 ]] && grep -q '^if loadfont unicode' "$WORK/block.cfg" && grep -q 'terminal_output gfxterm' "$WORK/block.cfg"; then
    t_pass "G1: found the GRUB_GFX_BLOCK heredoc in build-iso.sh ($n_block lines)"
else
    t_fail "G1: could not find the GRUB_GFX_BLOCK heredoc in build-iso.sh (renamed? this test would pass for nothing)"
fi
modules_of < "$WORK/block.cfg" > "$WORK/block.modules"
if [[ -s "$WORK/block.modules" ]]; then t_pass "G1: the block insmods: $(tr '\n' ' ' < "$WORK/block.modules")"
else t_fail "G1: the block has no insmod line, so nothing is checked against the built-in list"; fi
bad="$(not_builtin < "$WORK/block.modules" | tr '\n' ' ')"
if [[ -z "$bad" ]]; then t_pass "G1: every module the block insmods is built into the signed GRUB CD image (26.04.1, 95 modules)"
else t_fail "G1: the block insmods module(s) that are NOT built into the signed GRUB: ${bad% } (Secure Boot refuses a module loaded from disk)"; fi

if grep -q -x all_video "$WORK/builtin.txt"; then t_fail "G2: the committed list holds all_video: the fixture was edited, it must be the image's own list"
else t_pass "G2: control: the list does not hold all_video (the old block would be refused)"; fi
printf 'insmod all_video\ninsmod gfxterm\ninsmod png\n' | modules_of | not_builtin > "$WORK/old.bad"
if [[ "$(tr -d '\n' < "$WORK/old.bad")" == all_video ]]; then t_pass "G2: control: the checker rejects the old block (all_video) and only it"
else t_fail "G2: the checker does not reject exactly all_video in the old block: '$(tr '\n' ' ' < "$WORK/old.bad")'"; fi
if [[ "$(wc -l < "$WORK/builtin.txt" | tr -d ' ')" -eq 95 ]] && grep -q -x gfxterm "$WORK/builtin.txt" && grep -q -x png "$WORK/builtin.txt" && grep -q -x efi_gop "$WORK/builtin.txt"; then
    t_pass "G2: the list has the 95 modules of the 26.04.1 CD image, among them gfxterm, png and efi_gop"
else t_fail "G2: the committed list is not the 95-module list (gfxterm, png, efi_gop among them): $LIST"; fi

echo "== G3: the real brand_live_grub on the real stock grub.cfg"
gnu=1
sed --version 2>/dev/null | grep -q GNU || gnu=0
stat -c%s /dev/null >/dev/null 2>&1 || gnu=0
if [[ "$gnu" -eq 0 ]]; then
    t_skip "G3: needs GNU sed and stat (brand_live_grub uses sed -i and stat -c): run it in an Ubuntu 26.04 container"
else
    # a repo root whose renderer is a stub: the rest of brand_live_grub (grub-merge.sh, the brand tokens) is the real one
    FAKE="$WORK/repo"; mkdir -p "$FAKE/core/render" "$FAKE/work/custom-iso/boot/grub"
    ln -s "$REPO/core/lib" "$FAKE/core/lib"; ln -s "$REPO/vendor" "$FAKE/vendor"
    printf '#!/usr/bin/env bash\nprintf "\\211PNG\\r\\n\\032\\nstub" > "$1"\n' > "$FAKE/core/render/render-grub-background.sh"
    cp "$STOCK_CFG" "$FAKE/work/custom-iso/boot/grub/grub.cfg"
    if ( set +e +u; source "$BUILD"; REPO_ROOT="$FAKE"; WORK_DIR="$FAKE/work"; brand_live_grub ) > "$WORK/g3.out" 2>&1; then
        t_pass "G3: brand_live_grub themed the real stock grub.cfg"
        new="$FAKE/work/custom-iso/boot/grub/grub.cfg"
        modules_of < "$new" > "$WORK/real.modules"
        bad="$(not_builtin < "$WORK/real.modules" | tr '\n' ' ')"
        if [[ -s "$WORK/real.modules" && -z "$bad" ]]; then t_pass "G3: every insmod of the themed grub.cfg is built in: $(tr '\n' ' ' < "$WORK/real.modules")"
        else t_fail "G3: the themed grub.cfg insmods ${bad:-nothing (no insmod line at all)}"; fi
        if grep -q '^[[:space:]]*background_image /boot/grub/ci-os-bg\.png$' "$new" && grep -q '^[[:space:]]*terminal_output gfxterm$' "$new"; then
            t_pass "G3: the themed menu still loads its background and draws with gfxterm without any all_video"
        else t_fail "G3: the themed grub.cfg lost its background_image or terminal_output gfxterm"; fi
        if grep -q all_video "$new"; then t_fail "G3: the themed grub.cfg mentions all_video"; else t_pass "G3: the themed grub.cfg does not mention all_video"; fi
    else
        t_fail "G3: brand_live_grub failed on the real stock grub.cfg: $(tail -n 3 "$WORK/g3.out" | tr '\n' ' ')"
    fi
fi

echo "== G4: the committed list is the stock image's own"
if [[ -z "${CI_TEST_STOCK_ISO:-}" ]]; then
    t_skip "G4: set CI_TEST_STOCK_ISO=<ubuntu-26.04.1-desktop-amd64.iso> to re-read the list from the ISO's EFI/boot/grubx64.efi"
elif [[ ! -f "$CI_TEST_STOCK_ISO" ]]; then
    t_fail "G4: CI_TEST_STOCK_ISO is not a file: $CI_TEST_STOCK_ISO"
elif ! command -v python3 >/dev/null 2>&1; then
    t_skip "G4: needs python3"
else
    mkdir -p "$WORK/iso"
    if command -v xorriso >/dev/null 2>&1; then xorriso -osirrox on -indev "$CI_TEST_STOCK_ISO" -extract /EFI/boot/grubx64.efi "$WORK/iso/grubx64.efi" >/dev/null 2>&1
    elif command -v 7z >/dev/null 2>&1; then ( cd "$WORK/iso" && 7z e -y "$CI_TEST_STOCK_ISO" EFI/boot/grubx64.efi >/dev/null 2>&1 )
    fi
    if [[ ! -s "$WORK/iso/grubx64.efi" ]]; then t_skip "G4: neither xorriso nor 7z could extract EFI/boot/grubx64.efi"
    elif python3 -I "$TOOL" "$WORK/iso/grubx64.efi" > "$WORK/iso.modules" 2>"$WORK/iso.err"; then
        if cmp -s "$WORK/iso.modules" "$WORK/builtin.txt"; then t_pass "G4: the list equals the module list read from the ISO's own EFI/boot/grubx64.efi ($(wc -l < "$WORK/iso.modules" | tr -d ' ') modules)"
        else t_fail "G4: the committed list differs from the ISO's own: $(diff "$WORK/builtin.txt" "$WORK/iso.modules" | head -n 6 | tr '\n' ' ')"; fi
    else t_fail "G4: grub-builtin-modules.py could not read the ISO's grubx64.efi: $(head -n 2 "$WORK/iso.err" | tr '\n' ' ')"; fi
fi

echo
echo "== Summary: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
