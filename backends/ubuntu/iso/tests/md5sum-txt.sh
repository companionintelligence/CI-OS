#!/usr/bin/env bash
#=============================================================================
# Test: md5sum-txt.sh writes a correct md5sum.txt for a remastered image, and verify catches a stale one
#
# build-iso.sh used to copy the stock md5sum.txt into the image unchanged. casper-md5check ("Check disc for defects")
# then reported a mismatch for every file the remaster changed and an error for every file it deleted. The
# regeneration is checked on a synthetic mini tree that has one of each kind of file:
#
#   changed    a mapped file whose content differs from the stock one (and one whose content is the same)
#   new        a mapped file the stock image does not have (with a space in its name), appended in sorted order
#   removed    a stock file under a removed directory; its entry has to go
#   excluded   /md5sum.txt, /EFI, the subdirectories of /boot/grub: never listed, also when a map adds one
#   unchanged  a stock file no map touches: its stock hash is kept, at its stock position
#
# Part A drives the awk logic with hand-written lists (no xorriso; runs on a stock macOS under bash 3.2). Part B builds a
# real mini ISO, remasters it with the same xorriso arguments as build-iso.sh and runs `verify` on the result, then
# repeats the remaster with the OLD behaviour (the stock md5sum.txt, untouched) and shows that verify fails on it; that
# control is what proves the check can see the bug. A file over 4 GiB (several extents) is not made here; verify's
# extent reading was checked on a real image (see the commit message).
#
#   backends/ubuntu/iso/tests/md5sum-txt.sh
#   docker run --rm -v "$PWD:/repo:ro" <image with xorriso> bash /repo/backends/ubuntu/iso/tests/md5sum-txt.sh
#
# Exit status is non-zero if any check fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$HERE/../scripts/md5sum-txt.sh"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

for t in awk find sort cut cmp diff; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done
command -v md5sum >/dev/null 2>&1 || command -v md5 >/dev/null 2>&1 || { echo "missing tool: md5sum or md5" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/md5sum-txt-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

hash_of() { # hash_of "<content>": the md5 of the exact bytes (no newline added)
    if command -v md5sum >/dev/null 2>&1; then printf '%s' "$1" | md5sum | cut -d' ' -f1; else printf '%s' "$1" | md5 -q; fi
}

#=== Part A: the logic, on lists ================================================================================================
# The stock image: path | content. The listing order of the stock md5sum.txt is deliberately NOT sorted.
STOCK_CONTENT() { # path -> content (the stock bytes)
    case "$1" in
        /casper/vmlinuz)              printf 'kernel-bytes' ;;
        /casper/initrd)               printf 'stock-initrd' ;;
        /casper/minimal.squashfs)     printf 'stock-minimal' ;;
        /casper/minimal.standard.squashfs) printf 'stock-standard' ;;
        /casper/SHA256SUMS)           printf 'stock-sums' ;;
        /casper/SHA256SUMS.gpg)       printf 'stock-sig' ;;
        /casper/minimal.de.squashfs)  printf 'stock-de' ;;
        /boot/grub/grub.cfg)          printf 'stock-grub' ;;
        /boot/grub/loopback.cfg)      printf 'stock-loopback' ;;
        /boot/memtest86+x64.bin)      printf 'memtest' ;;
        /.disk/info)                  printf 'Ubuntu 24.04' ;;
        /pool/main/a/a.deb)           printf 'deb-a' ;;
        /preseed/ubuntu.seed)         printf 'seed' ;;
        *)                            printf 'excluded-%s' "$1" ;;
    esac
}
ORDER=(/pool/main/a/a.deb /preseed/ubuntu.seed /boot/grub/grub.cfg /boot/grub/loopback.cfg /boot/memtest86+x64.bin
       /casper/minimal.de.squashfs /casper/SHA256SUMS.gpg /casper/SHA256SUMS /casper/initrd /casper/minimal.squashfs
       /casper/minimal.standard.squashfs /casper/vmlinuz /.disk/info)
EXCLUDED=(/md5sum.txt /EFI/boot/bootx64.efi /boot/grub/fonts/unicode.pf2 /boot/grub/i386-pc/normal.mod /boot/grub/x86_64-efi/normal.mod)

A="$WORK/a"; mkdir -p "$A"
: > "$A/stock.md5"; : > "$A/stock.files"
for p in "${ORDER[@]}"; do
    printf '%s  .%s\n' "$(hash_of "$(STOCK_CONTENT "$p")")" "$p" >> "$A/stock.md5"
    printf '%s\n' "$p" >> "$A/stock.files"
done
for p in "${EXCLUDED[@]}"; do printf '%s\n' "$p" >> "$A/stock.files"; done

# What build-iso.sh maps: the casper directory, grub.cfg, a new GRUB background, .disk/info, plus an excluded new file.
N="$WORK/a/new"; mkdir -p "$N/casper" "$N/grub-themes"
printf 'kernel-bytes' > "$N/casper/vmlinuz"                 # same content as the stock file
printf 'initrd+overlay' > "$N/casper/initrd"
printf 'merged-rootfs' > "$N/casper/minimal.squashfs"
printf 'placeholder' > "$N/casper/minimal.standard.squashfs"
printf 'new-sums' > "$N/casper/SHA256SUMS"
printf 'a manifest' > "$N/casper/filesystem.manifest"       # new
printf 'odd' > "$N/casper/odd name.txt"                     # new, with a space
printf 'new-grub' > "$N/grub.cfg"
printf 'png-bytes' > "$N/ci-os-bg.png"
printf 'Companion-OS 24.04' > "$N/info"
printf 'theme' > "$N/grub-themes/theme.txt"

# The expected md5sum.txt, written out by hand from the facts above (not by the code under test).
{
    printf '%s  ./pool/main/a/a.deb\n'              "$(hash_of deb-a)"
    printf '%s  ./preseed/ubuntu.seed\n'            "$(hash_of seed)"
    printf '%s  ./boot/grub/grub.cfg\n'             "$(hash_of new-grub)"          # changed
    printf '%s  ./boot/grub/loopback.cfg\n'         "$(hash_of stock-loopback)"    # unchanged: stock hash, stock place
    printf '%s  ./boot/memtest86+x64.bin\n'         "$(hash_of memtest)"
    #                                               ./casper/minimal.de.squashfs and SHA256SUMS.gpg: removed, no line
    printf '%s  ./casper/SHA256SUMS\n'              "$(hash_of new-sums)"
    printf '%s  ./casper/initrd\n'                  "$(hash_of initrd+overlay)"
    printf '%s  ./casper/minimal.squashfs\n'        "$(hash_of merged-rootfs)"
    printf '%s  ./casper/minimal.standard.squashfs\n' "$(hash_of placeholder)"
    printf '%s  ./casper/vmlinuz\n'                 "$(hash_of kernel-bytes)"
    printf '%s  ./.disk/info\n'                     "$(hash_of 'Companion-OS 24.04')"
    # new files, sorted by path
    printf '%s  ./boot/grub/ci-os-bg.png\n'         "$(hash_of png-bytes)"
    printf '%s  ./casper/filesystem.manifest\n'     "$(hash_of 'a manifest')"
    printf '%s  ./casper/odd name.txt\n'            "$(hash_of odd)"
} > "$A/expected.md5"

regen() { # regen <out> [extra args...]: the maps of build-iso.sh over the synthetic stock
    local out="$1"; shift
    bash "$H" regenerate --stock-md5 "$A/stock.md5" --stock-files "$A/stock.files" --out "$out" \
        --rm /casper \
        --map "$N/casper" /casper --map "$N/grub.cfg" /boot/grub/grub.cfg --map "$N/ci-os-bg.png" /boot/grub/ci-os-bg.png \
        --map "$N/grub-themes" /boot/grub/themes --map "$N/info" /.disk/info "$@"
}

if bash "$H" check-stock --stock-md5 "$A/stock.md5" --stock-files "$A/stock.files" >/dev/null 2>&1; then
    t_pass "check-stock: the synthetic stock follows the convention"
else t_fail "check-stock rejected the synthetic stock"; fi

if regen "$A/out.md5" 2> "$A/regen.err"; then
    if cmp -s "$A/expected.md5" "$A/out.md5"; then
        t_pass "regenerate: changed, new, removed, excluded and unchanged files all come out as expected (stock order kept, new files sorted)"
    else
        t_fail "regenerate: the md5sum.txt differs from the expected one:"; diff -u "$A/expected.md5" "$A/out.md5" || true
    fi
else t_fail "regenerate failed: $(tail -n 3 "$A/regen.err")"; fi

if ! cmp -s "$A/stock.md5" "$A/out.md5"; then t_pass "control: the regenerated file is not the stock one (the old behaviour would have shipped the stock file)"
else t_fail "control: the regenerated file equals the stock one, the test cannot tell the two apart"; fi

grep -q -F -- 'md5sum.txt' "$A/out.md5" && t_fail "md5sum.txt lists itself" || t_pass "md5sum.txt does not list itself"
grep -q -E '\./(EFI|boot/grub/(fonts|i386-pc|x86_64-efi|themes))/' "$A/out.md5" && t_fail "an excluded path is listed (EFI or a boot/grub subdirectory)" \
    || t_pass "nothing under /EFI or a boot/grub subdirectory is listed, also the file a map added there"
grep -q -E 'minimal\.de\.squashfs|SHA256SUMS\.gpg' "$A/out.md5" && t_fail "an entry for a deleted file is still listed" || t_pass "entries of deleted files are dropped"
awk '{print $2}' "$A/out.md5" | sort | uniq -d | grep -q . && t_fail "a path is listed twice" || t_pass "no path is listed twice"
if grep -q -v -E '^[0-9a-f]{32}  \./.' "$A/out.md5"; then t_fail "a line is not '<md5>  ./<path>'"; else t_pass "every line is '<md5>  ./<path>'"; fi
[[ "$(tail -c1 "$A/out.md5" | od -An -c | tr -d ' ')" == '\n' ]] && t_pass "the file ends with a newline" || t_fail "the file does not end with a newline"

# Running it twice gives the same bytes.
regen "$A/out2.md5" 2>/dev/null && cmp -s "$A/out.md5" "$A/out2.md5" && t_pass "deterministic: a second run writes the same bytes" || t_fail "a second run wrote different bytes"

# Failures are loud and leave no file behind: nothing falls back to the stale md5sum.txt.
expect_fail() { # expect_fail "<label>" "<substring of the error>" <command...>
    local label="$1" want="$2" rc=0; shift 2
    rm -f "$A/fail.md5"
    "$@" > "$A/fail.out" 2> "$A/fail.err" || rc=$?
    if [[ "$rc" -ne 0 && ! -e "$A/fail.md5" ]] && grep -q -F -- "$want" "$A/fail.err"; then t_pass "fails loudly: $label"
    else t_fail "$label: exit $rc, output file $([[ -e "$A/fail.md5" ]] && echo present || echo absent), stderr: $(head -c 300 "$A/fail.err")"; fi
}
R() { bash "$H" regenerate --stock-md5 "$A/stock.md5" --stock-files "$A/stock.files" --out "$A/fail.md5" "$@"; }

expect_fail "a map source that does not exist" "not found" R --map "$A/no-such-file" /x
expect_fail "a relative image path" "absolute" R --map "$N/info" relative/path
expect_fail "removing the whole image" "whole image" R --rm /
ln -s "$N/info" "$N/casper/link"
expect_fail "a symlink in a mapped tree" "neither a regular file" R --map "$N/casper" /casper
rm -f "$N/casper/link"
expect_fail "no --out" "needs --out" bash "$H" regenerate --stock-md5 "$A/stock.md5" --stock-files "$A/stock.files"

# A base ISO that does not follow the convention is refused (an unlisted file, a ghost entry, an excluded path that is listed,
# a malformed line, a duplicate).
try_stock() { # try_stock "<label>" "<error substring>" <md5 file content> <files extra lines>
    local label="$1" want="$2" md5="$3" extra="$4"
    { cat "$A/stock.md5"; printf '%s' "$md5"; } > "$A/bad.md5"
    { cat "$A/stock.files"; printf '%s' "$extra"; } > "$A/bad.files"
    expect_fail "$label" "$want" bash "$H" regenerate --stock-md5 "$A/bad.md5" --stock-files "$A/bad.files" --out "$A/fail.md5"
}
try_stock "a stock file its md5sum.txt does not list" "/extra.bin" "" $'/extra.bin\n'
try_stock "a stock entry whose file is not in the image" "/ghost.bin" "$(hash_of g)  ./ghost.bin"$'\n' ""
try_stock "a stock entry for a path this script treats as excluded" "/EFI/boot/bootx64.efi" "$(hash_of g)  ./EFI/boot/bootx64.efi"$'\n' ""
try_stock "a malformed stock line" "line 14" "$(hash_of g) ./one-space.bin"$'\n' $'/one-space.bin\n'
try_stock "a stock path listed twice" "twice" "$(hash_of d)  ./pool/main/a/a.deb"$'\n' ""
{ cat "$A/stock.files"; echo /extra.bin; } > "$A/extra.files"
expect_fail "check-stock on the same problem" "/extra.bin" bash "$H" check-stock --stock-md5 "$A/stock.md5" --stock-files "$A/extra.files"

#=== Part B: a real mini ISO ====================================================================================================
for t in xorriso dd; do
    command -v "$t" >/dev/null 2>&1 || { printf 'info  %s is not installed: Part B (a real ISO through xorriso and verify) skipped\n' "$t"; SKIP_B=1; }
done
if [[ -z "${SKIP_B:-}" ]] && command -v md5sum >/dev/null 2>&1; then
    B="$WORK/b"; mkdir -p "$B/tree"
    # The stock tree: every stock file, plus the stock md5sum.txt, plus a disc-sized-looking pool entry for good measure.
    for p in "${ORDER[@]}" "${EXCLUDED[@]}"; do
        [[ "$p" == /md5sum.txt ]] && continue
        mkdir -p "$B/tree$(dirname "$p")"; STOCK_CONTENT "$p" > "$B/tree$p"
    done
    : > "$B/tree/.disk/base_installable"   # an empty file, like the real one
    { cat "$A/stock.md5"; printf '%s  ./.disk/base_installable\n' "$(hash_of '')"; } > "$B/tree/md5sum.txt"
    # check-stock needs the listed set to equal the file set: base_installable is now both in the tree and in md5sum.txt.
    xorriso -as mkisofs -r -iso-level 3 -V MINI -o "$B/stock.iso" "$B/tree" >/dev/null 2>&1 \
        || { t_fail "could not build the mini stock ISO"; }
    if [[ -s "$B/stock.iso" ]]; then
        if bash "$H" check-stock --base-iso "$B/stock.iso" > "$B/cs.out" 2> "$B/cs.err"; then t_pass "check-stock --base-iso: the mini ISO follows the convention"
        else t_fail "check-stock --base-iso on the mini ISO: $(head -c 300 "$B/cs.err")"; fi
        if bash "$H" verify "$B/stock.iso" > "$B/vs.out" 2>&1; then t_pass "verify: the untouched mini stock ISO is consistent ($(grep SUMMARY "$B/vs.out"))"
        else t_fail "verify rejected the untouched mini stock ISO: $(head -c 400 "$B/vs.out")"; fi

        # The remaster, with the arguments build-iso.sh gives xorriso (generate_iso).
        remaster() { # remaster <out iso> [extra xorriso args]
            local out="$1"; shift
            rm -f "$out"
            xorriso -indev "$B/stock.iso" -outdev "$out" -volid MINI -boot_image any keep -pathspecs on \
                -rm_r /casper -- \
                -map "$N/casper" /casper -map "$N/grub.cfg" /boot/grub/grub.cfg -map "$N/ci-os-bg.png" /boot/grub/ci-os-bg.png \
                -map "$N/info" /.disk/info "$@" -commit_eject all >/dev/null 2>&1
        }
        # The new behaviour: md5sum.txt regenerated from the stock ISO and mapped in the same xorriso run.
        bash "$H" regenerate --base-iso "$B/stock.iso" --out "$B/new.md5" --rm /casper \
            --map "$N/casper" /casper --map "$N/grub.cfg" /boot/grub/grub.cfg --map "$N/ci-os-bg.png" /boot/grub/ci-os-bg.png \
            --map "$N/info" /.disk/info 2> "$B/regen.err" || t_fail "regenerate --base-iso failed: $(tail -n 3 "$B/regen.err")"
        if remaster "$B/new.iso" -map "$B/new.md5" /md5sum.txt && bash "$H" verify "$B/new.iso" > "$B/vn.out" 2>&1; then
            t_pass "verify: the remastered image's md5sum.txt matches every file in it ($(grep SUMMARY "$B/vn.out"))"
        else t_fail "verify rejected the remastered image: $(head -c 600 "$B/vn.out" 2>/dev/null)"; fi

        # The old behaviour: the stock md5sum.txt stays in the image.
        if remaster "$B/stale.iso"; then
            if bash "$H" verify "$B/stale.iso" > "$B/vz.out" 2>&1; then t_fail "control: verify accepted an image that kept the STOCK md5sum.txt"
            else
                t_pass "control: verify fails on the stale (stock) md5sum.txt"
                for want in 'MISMATCH /casper/initrd' 'MISMATCH /casper/minimal.squashfs' 'MISMATCH /boot/grub/grub.cfg' 'MISMATCH /.disk/info' \
                            'MISSING /casper/minimal.de.squashfs' 'MISSING /casper/SHA256SUMS.gpg' \
                            'UNLISTED /boot/grub/ci-os-bg.png' 'UNLISTED /casper/filesystem.manifest'; do
                    if grep -q -F -- "$want" "$B/vz.out"; then t_pass "control: the stale file is reported ($want)"; else t_fail "control: verify did not report '$want'"; fi
                done
                if grep -q -E '(MISMATCH|MISSING|UNLISTED) /(pool|preseed|boot/grub/loopback)' "$B/vz.out"; then t_fail "control: verify blames a file that did not change"
                else t_pass "control: files the remaster did not touch are not blamed"; fi
            fi
        else t_fail "could not build the stale mini ISO"; fi

        # One wrong hash among correct ones is found, alone.
        sed "s/^[0-9a-f]\{32\}  \.\/casper\/initrd\$/$(hash_of wrong)  .\/casper\/initrd/" "$B/new.md5" > "$B/one.md5"
        if remaster "$B/one.iso" -map "$B/one.md5" /md5sum.txt && ! bash "$H" verify "$B/one.iso" > "$B/vo.out" 2>&1 \
           && [[ "$(grep -c -E '^(MISMATCH|MISSING|UNLISTED)' "$B/vo.out")" == 1 ]] && grep -q 'MISMATCH /casper/initrd' "$B/vo.out"; then
            t_pass "verify: a single wrong hash is reported, and only that one"
        else t_fail "verify did not isolate the single wrong hash: $(head -c 400 "$B/vo.out" 2>/dev/null)"; fi

        # build-iso.sh's glue: write_md5sum_txt turns the xorriso operations into the same call (sourcing build-iso.sh only
        # defines its functions), and check_base_md5sum stops a base ISO that does not follow the convention before any build work.
        if ( source "$HERE/../scripts/build-iso.sh"; BASE_ISO="$B/stock.iso"
             write_md5sum_txt "$B/glue.md5" -rm_r /casper -- -map "$N/casper" /casper -map "$N/grub.cfg" /boot/grub/grub.cfg \
                 -map "$N/ci-os-bg.png" /boot/grub/ci-os-bg.png -map "$N/info" /.disk/info ) > "$B/glue.out" 2>&1 \
           && cmp -s "$B/new.md5" "$B/glue.md5"; then
            t_pass "build-iso.sh write_md5sum_txt: the xorriso operations give the md5sum.txt the CLI writes"
        else t_fail "build-iso.sh write_md5sum_txt did not produce the CLI's md5sum.txt: $(tail -n 3 "$B/glue.out")"; fi
        if ( source "$HERE/../scripts/build-iso.sh"; BASE_ISO="$B/stock.iso"
             write_md5sum_txt "$B/glue2.md5" -map "$N/info" ) > "$B/glue2.out" 2>&1; then
            t_fail "write_md5sum_txt accepted a -map without an image path"
        elif [[ ! -e "$B/glue2.md5" ]]; then t_pass "write_md5sum_txt fails on an incomplete -map and writes nothing"; else t_fail "write_md5sum_txt left a file behind"; fi
        if ( source "$HERE/../scripts/build-iso.sh"; BASE_ISO="$B/stock.iso"
             write_md5sum_txt "$B/glue3.md5" -boot_image any keep ) > "$B/glue3.out" 2>&1; then
            t_fail "write_md5sum_txt accepted an xorriso operation it does not model"
        else t_pass "write_md5sum_txt refuses an xorriso operation it does not model (-boot_image)"; fi
        if ( source "$HERE/../scripts/build-iso.sh"; BASE_ISO="$B/stock.iso"; check_base_md5sum ) > "$B/cb.out" 2>&1; then
            t_pass "build-iso.sh check_base_md5sum accepts a base ISO that follows the convention"
        else t_fail "check_base_md5sum rejected the mini stock ISO: $(tail -n 3 "$B/cb.out")"; fi
        mkdir -p "$B/tree2"; cp -R "$B/tree/." "$B/tree2/"; printf 'unlisted' > "$B/tree2/surprise.bin"
        if xorriso -as mkisofs -r -iso-level 3 -V MINI -o "$B/odd.iso" "$B/tree2" >/dev/null 2>&1; then
            rc=0; ( source "$HERE/../scripts/build-iso.sh"; BASE_ISO="$B/odd.iso"; check_base_md5sum ) > "$B/odd.out" 2>&1 || rc=$?
            if [[ "$rc" -ne 0 ]] && grep -q -F -- 'surprise.bin' "$B/odd.out"; then
                t_pass "check_base_md5sum stops a base ISO with a file its md5sum.txt does not list (names it, exit $rc)"
            else t_fail "check_base_md5sum let a base ISO with an unlisted file through (exit $rc): $(tail -n 3 "$B/odd.out")"; fi
        else t_fail "could not build the odd mini ISO"; fi
    fi
fi

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
