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
# Part A drives the awk logic with hand-written lists (no xorriso; runs on a stock macOS under bash 3.2), including the
# cases where a hash or a file listing FAILS (a read error must stop `regenerate`, never write a blank hash or drop a file).
# Part A2 covers the extents of a file over 4 GiB, which is too big to build here: report_to_table reads a report written by
# hand in xorriso's format (the "xt 0" / "xt 1" rows of one file) and iso_stream_hash reads a fake image by those extents
# (needs GNU dd). Part B builds a real mini ISO with an El Torito boot image, remasters it with the same xorriso arguments
# as build-iso.sh (`-boot_image any replay`) and runs `verify` on the result, then repeats the remaster with the OLD
# behaviour (the stock md5sum.txt, untouched) and shows that verify fails on it; that control is what proves the check can
# see the bug. It also runs build-iso.sh's own check_base_md5sum and generate_iso on the mini image, with xorriso recorded and
# md5sum-txt.sh shimmed, to show the new md5sum.txt is the last map of the xorriso run, that the finished image is read
# back, and that a rejected image is quarantined. core/lib/check-repo.sh runs this file.
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

# Fail closed: a hash or a file listing that fails inside $(...) must stop regenerate. Bash clears errexit there, so the old code
# wrote a line with a BLANK hash for a file md5sum could not read, and silently dropped the files a failing find did not reach.
# md5sum and find are replaced by stubs that fail the way a read error does (a real chmod 000 only fails for a non-root user).
STUB_HASH="$WORK/stub-md5sum"; STUB_FIND="$WORK/stub-find"; mkdir -p "$STUB_HASH" "$STUB_FIND"
REAL_HASH="$(command -v md5sum 2>/dev/null || true)"; [[ -n "$REAL_HASH" ]] || REAL_HASH="$(command -v md5) -q"
REAL_FIND="$(command -v find)"
cat > "$STUB_HASH/md5sum" <<'STUBEOF'
#!/bin/sh
# md5sum for a test: input starting BOOM fails like a read error, input starting BLANK prints nothing and "succeeds".
d="$(cat)"
case "$d" in BOOM*) echo "md5sum: simulated read error" >&2; exit 1 ;; BLANK*) exit 0 ;; esac
printf '%s' "$d" | ${CI_TEST_REAL_HASH:?}
STUBEOF
cat > "$STUB_FIND/find" <<'STUBEOF'
#!/bin/sh
# find for a test: a listing (-print0) prints what it can and then fails, like find on an unreadable subdirectory.
for a in "$@"; do
    if [ "$a" = -print0 ]; then "${CI_TEST_REAL_FIND:?}" "$@"; echo "find: simulated: Permission denied" >&2; exit 1; fi
done
exec "${CI_TEST_REAL_FIND:?}" "$@"
STUBEOF
chmod +x "$STUB_HASH/md5sum" "$STUB_FIND/find"
FC="$WORK/failclosed"; mkdir -p "$FC/boom" "$FC/blank" "$FC/ok"
printf 'BOOM-read-error' > "$FC/boom/unreadable.bin"; printf 'fine' > "$FC/boom/fine.bin"
printf 'BLANK-hash' > "$FC/blank/empty-answer.bin"
printf 'fine' > "$FC/ok/changed.bin"
RSTUB() { local stub="$1"; shift  # RSTUB <stub dir> <regenerate args>: regenerate with that stub first in PATH
          env CI_TEST_REAL_HASH="$REAL_HASH" CI_TEST_REAL_FIND="$REAL_FIND" PATH="$stub:$PATH" \
              bash "$H" regenerate --stock-md5 "$A/stock.md5" --stock-files "$A/stock.files" --out "$A/fail.md5" "$@"; }
expect_fail "a mapped file md5sum cannot read (was: a line with a blank hash, exit 0)" "cannot hash" RSTUB "$STUB_HASH" --map "$FC/boom" /casper
expect_fail "a single mapped file md5sum cannot read" "cannot hash" RSTUB "$STUB_HASH" --map "$FC/boom/unreadable.bin" /x
expect_fail "a hash tool that exits 0 without a hash" "cannot hash" RSTUB "$STUB_HASH" --map "$FC/blank" /casper
expect_fail "a file listing that fails half way (was: the files it did not reach were dropped, exit 0)" "could not list" \
    RSTUB "$STUB_FIND" --rm /casper --map "$FC/ok" /casper
expect_fail "an image path no md5sum.txt line can carry (the output is checked line by line)" "malformed line" R --map "$N/info" $'/bad\nname'
if [[ "$(id -u)" != 0 ]]; then
    mkdir -p "$FC/perm"; printf 'secret' > "$FC/perm/locked.bin"; chmod 000 "$FC/perm/locked.bin"
    if [[ ! -r "$FC/perm/locked.bin" ]]; then
        expect_fail "a mapped file with mode 000 (a real read error)" "cannot hash" R --map "$FC/perm" /casper
    fi
    chmod 644 "$FC/perm/locked.bin"
fi

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

#=== Part A2: the extent logic, on a report written by hand ====================================================================
# The biggest md5sum.txt entry of the real image is casper/minimal.squashfs, 5.6 GB, which ISO level 3 stores in two extents
# ("xt 0" and "xt 1" rows of `report_lba`, each carrying the whole size). Building such a file is too big for a test, so
# the report is written by hand in xorriso's format and the real functions read it.
RAW="$WORK/report.raw"
cat > "$RAW" <<'RAWEOF'
Report layout: xt , Startlba ,   Blocks , Filesize , ISO image path
File data lba:  0 ,       34 ,        2 ,     4096 , '/boot/grub/a b.img'
File data lba:  0 ,      100 ,  2097152 , 5640392704 , '/casper/minimal.squashfs'
File data lba:  1 ,  2097252 ,   656946 , 5640392704 , '/casper/minimal.squashfs'
File data lba:  0 ,      200 ,        0 ,          0 , '/.disk/base_installable'
File data lba:  0 ,      201 ,        1 ,          3 , '/x , y'
RAWEOF
{
    printf '/boot/grub/a b.img\t4096\t34:2\n'
    printf '/casper/minimal.squashfs\t5640392704\t100:2097152,2097252:656946\n'   # one line, both extents, in order
    printf '/.disk/base_installable\t0\t\n'                                       # empty file: no extent
    printf '/x , y\t3\t201:1\n'                                                    # a path that holds the field separator
} > "$WORK/report.expected"
if ( source "$H"; report_to_table "$RAW" "$WORK/report.tsv" ) 2> "$WORK/report.err" && cmp -s "$WORK/report.expected" "$WORK/report.tsv"; then
    t_pass "report_to_table: a two-extent file is one table line with both extents, an empty file has none, a path with ' , ' survives"
else t_fail "report_to_table did not give the expected table: $(diff "$WORK/report.expected" "$WORK/report.tsv" 2>&1 | head -c 400)"; fi
printf "File data lba:  0 ,  300 ,  1 ,  3 , '/it's.bin'\n" > "$WORK/report.quote"
if ( source "$H"; report_to_table "$WORK/report.quote" "$WORK/report.q.tsv" ) > /dev/null 2>&1; then t_fail "report_to_table accepted a file name with a quote"
else t_pass "report_to_table refuses a file name with a quote (md5sum.txt could not carry it)"; fi

# iso_stream_hash reads the extents in order and stops at the file size. It needs GNU dd (iflag=skip_bytes,count_bytes).
if dd if=/dev/null of=/dev/null iflag=skip_bytes,count_bytes count=0 status=none 2>/dev/null; then
    FAKE="$WORK/fake.img"; : > "$FAKE"
    for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do   # 20 blocks, block N filled with the letter 'A'+N
        letter="$(printf "\\$(printf '%03o' $((65 + i)))")"; head -c 2048 /dev/zero | tr '\0' "$letter" >> "$FAKE"
    done
    block_bytes() { head -c $((($1 + 1) * 2048)) "$FAKE" | tail -c 2048; }     # block_bytes N: block N
    # The file: blocks 3 and 4, then the first 904 bytes of block 12 (5000 bytes). Hashed from the pieces, not by the code under test.
    want="$({ block_bytes 3; block_bytes 4; block_bytes 12 | head -c 904; } | if command -v md5sum >/dev/null 2>&1; then md5sum; else md5 -q; fi | cut -d' ' -f1)"
    got="$( source "$H"; iso_stream_hash "$FAKE" 5000 3:2,12:1 )" || got="(failed)"
    if [[ "$got" == "$want" ]]; then t_pass "iso_stream_hash: two extents are read in order and the last one stops at the file size"
    else t_fail "iso_stream_hash over two extents: got $got, want $want"; fi
    # Through the table: the hand-written report of that same file gives the extents iso_stream_hash is handed in verify.
    printf "File data lba:  0 ,  3 ,  2 ,  5000 , '/big.bin'\nFile data lba:  1 ,  12 ,  1 ,  5000 , '/big.bin'\n" > "$WORK/big.raw"
    row="$( source "$H"; report_to_table "$WORK/big.raw" "$WORK/big.tsv"; cat "$WORK/big.tsv" )"
    IFS=$'\t' read -r _ bsize bext <<< "$row"
    got="$( source "$H"; iso_stream_hash "$FAKE" "$bsize" "$bext" )" || got="(failed)"
    if [[ "$bext" == "3:2,12:1" && "$got" == "$want" ]]; then t_pass "report -> table -> iso_stream_hash: the extents of a split file hash to the file's md5"
    else t_fail "a two-extent report did not hash to the file's md5 (extents '$bext', got $got, want $want)"; fi
    if ( source "$H"; iso_stream_hash "$FAKE" 5000 3:2 ) > /dev/null 2>&1; then t_fail "iso_stream_hash accepted extents shorter than the file"
    else t_pass "iso_stream_hash fails when the extents do not add up to the file size"; fi
else printf 'info  GNU dd is not installed: the iso_stream_hash extent tests are skipped\n'; fi

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
    # A BIOS El Torito image where Ubuntu has it (under a /boot/grub subdirectory, so md5sum.txt leaves it out), so that the
    # remaster below runs with a boot image to carry over, as it does for the real image with `-boot_image any replay`.
    head -c 4096 /dev/zero | tr '\0' 'E' > "$B/tree/boot/grub/i386-pc/eltorito.img"
    { cat "$A/stock.md5"; printf '%s  ./.disk/base_installable\n' "$(hash_of '')"; } > "$B/tree/md5sum.txt"
    # check-stock needs the listed set to equal the file set: base_installable is now both in the tree and in md5sum.txt.
    xorriso -as mkisofs -r -iso-level 3 -V MINI -b boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 \
        -o "$B/stock.iso" "$B/tree" >/dev/null 2>&1 \
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
            xorriso -indev "$B/stock.iso" -outdev "$out" -volid MINI -boot_image any replay -pathspecs on \
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

        # The boot image survives the remaster: the same `-boot_image any replay` as build-iso.sh, on an image that has one.
        el_torito() { xorriso -indev "$1" -report_el_torito plain 2>/dev/null | grep -F 'El Torito img path' | grep -c -F '/boot/grub/i386-pc/eltorito.img' || true; }
        if [[ "$(el_torito "$B/stock.iso")" == 1 && "$(el_torito "$B/new.iso")" == 1 ]]; then
            t_pass "the remastered image keeps the El Torito boot image of the stock one (-boot_image any replay)"
        else t_fail "the El Torito boot image is not in both the stock mini ISO and the remastered one (stock $(el_torito "$B/stock.iso"), new $(el_torito "$B/new.iso"))"; fi

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

        # A base ISO whose md5sum.txt follows the convention but is WRONG about a file the build never touches: check-stock reads
        # names only and passes it; the stock hash would be copied into the new image, so check_base_md5sum has to read the content.
        mkdir -p "$B/tree3"; cp -R "$B/tree/." "$B/tree3/"
        sed "s/^[0-9a-f]\{32\}  \.\/pool\/main\/a\/a\.deb\$/$(hash_of wrong)  .\/pool\/main\/a\/a.deb/" "$B/tree/md5sum.txt" > "$B/tree3/md5sum.txt"
        if xorriso -as mkisofs -r -iso-level 3 -V MINI -o "$B/badhash.iso" "$B/tree3" >/dev/null 2>&1; then
            if bash "$H" check-stock --base-iso "$B/badhash.iso" >/dev/null 2>&1; then t_pass "control: check-stock alone passes a base ISO with a wrong hash for an untouched file (it reads names)"
            else t_fail "control: check-stock rejected the wrong-hash base ISO, the test cannot show what check_base_md5sum adds"; fi
            rc=0; ( source "$HERE/../scripts/build-iso.sh"; BASE_ISO="$B/badhash.iso"; check_base_md5sum ) > "$B/bh.out" 2>&1 || rc=$?
            if [[ "$rc" -ne 0 ]] && grep -q -F -- 'MISMATCH /pool/main/a/a.deb' "$B/bh.out"; then
                t_pass "check_base_md5sum stops a base ISO whose md5sum.txt has a wrong hash (names the file, exit $rc)"
            else t_fail "check_base_md5sum let a base ISO with a wrong hash through (exit $rc): $(tail -n 3 "$B/bh.out")"; fi
        else t_fail "could not build the wrong-hash mini ISO"; fi

        # generate_iso, the real function, end to end on the mini image. xorriso is wrapped by a recorder that runs the real
        # one, and md5sum-txt.sh by a shim that records the sub-commands and can be told to fail `verify`. Sourcing build-iso.sh
        # only defines functions. This is what tells that the new md5sum.txt is the LAST map of the xorriso run (a later map of
        # the same path would win), that the image is read back, and that a rejected image does not stay under its real name.
        G="$B/gen"; mkdir -p "$G/work/custom-iso/boot/grub" "$G/work/custom-iso/.disk" "$G/out" "$G/shim"
        cp -R "$N/casper" "$G/work/custom-iso/casper"; cp "$N/grub.cfg" "$G/work/custom-iso/boot/grub/grub.cfg"
        cp "$N/info" "$G/work/custom-iso/.disk/info"; cp "$N/ci-os-bg.png" "$G/work/ci-os-bg.png"
        cat > "$G/shim/md5sum-txt.sh" <<'SHIMEOF'
#!/usr/bin/env bash
# Records "<sub-command> <last argument>", then runs the real script; CI_TEST_VERIFY_FAIL=1 makes `verify` fail.
printf '%s %s\n' "$1" "${*: -1}" >> "${CI_TEST_SHIM_LOG:?}"
if [[ "$1" == verify && "${CI_TEST_VERIFY_FAIL:-}" == 1 ]]; then echo "verify: simulated mismatch" >&2; exit 1; fi
exec bash "${CI_TEST_REAL_MD5SUM_TXT:?}" "$@"
SHIMEOF
        chmod +x "$G/shim/md5sum-txt.sh"
        run_generate() { # run_generate: build-iso.sh's generate_iso over $G (brand_live_grub is not under test: it needs the renderers)
            ( source "$HERE/../scripts/build-iso.sh"
              BASE_ISO="$B/stock.iso"; WORK_DIR="$G/work"; OUTPUT_DIR="$G/out"; CI_OS_VERSION=0.0-test; SCRIPT_DIR="$G/shim"
              export CI_TEST_SHIM_LOG="$G/shim.log" CI_TEST_REAL_MD5SUM_TXT="$H"
              brand_live_grub() { :; }
              xorriso() { printf '%s\n' "$*" >> "$G/xorriso.log"; command xorriso "$@"; }
              generate_iso )
        }
        GISO="$G/out/companion-os-0.0-test-amd64.iso"
        if run_generate > "$G/gen1.out" 2>&1; then
            [[ -s "$GISO" && -s "$G/out/SHA256SUMS" && -s "$G/out/MD5SUMS" ]] && t_pass "generate_iso: writes the image and its checksums" \
                || t_fail "generate_iso succeeded but the image or a checksum file is missing: $(ls "$G/out")"
            build_line="$(grep -F -- '-outdev' "$G/xorriso.log" | tail -n 1)"
            case "$build_line" in
                *'-boot_image any replay'*) t_pass "generate_iso: remasters with -boot_image any replay (boot setup inherited from the base ISO)" ;;
                *) t_fail "generate_iso: the xorriso run does not use -boot_image any replay: $build_line" ;;
            esac
            case "$build_line" in
                *'/md5sum.txt.new /md5sum.txt -commit_eject all') t_pass "generate_iso: the new md5sum.txt is mapped in, as the last map of the xorriso run" ;;
                *) t_fail "generate_iso: /md5sum.txt is not the last map of the xorriso run: $build_line" ;;
            esac
            if grep -q '^regenerate ' "$G/shim.log"; then t_pass "generate_iso: the md5sum.txt is regenerated for the image"
            else t_fail "generate_iso did not call md5sum-txt.sh regenerate"; fi
            if grep -q -x -F -- "verify $GISO" "$G/shim.log"; then t_pass "generate_iso: the finished image is read back with md5sum-txt.sh verify"
            else t_fail "generate_iso did not run md5sum-txt.sh verify on the finished image (log: $(tr '\n' '|' < "$G/shim.log"))"; fi
            if bash "$H" verify "$GISO" > "$G/gen1.verify" 2>&1; then t_pass "generate_iso: the image's md5sum.txt matches every file in it ($(grep SUMMARY "$G/gen1.verify"))"
            else t_fail "generate_iso wrote an image that fails verify: $(head -c 400 "$G/gen1.verify")"; fi
            # The checksums of this run are in out/ now. A second run whose verify fails must neither keep the image under its
            # name nor leave these checksums beside a different image.
            rc=0; CI_TEST_VERIFY_FAIL=1 run_generate > "$G/gen2.out" 2>&1 || rc=$?
            if [[ "$rc" -ne 0 ]]; then t_pass "generate_iso: fails when the finished image does not verify (exit $rc)"; else t_fail "generate_iso succeeded although verify failed"; fi
            [[ ! -e "$GISO" && -s "$GISO.rejected" ]] && t_pass "generate_iso: a rejected image is renamed to .rejected, not left under its real name" \
                || t_fail "generate_iso: the rejected image is not quarantined (files: $(ls "$G/out" | tr '\n' ' '))"
            [[ ! -e "$G/out/SHA256SUMS" && ! -e "$G/out/MD5SUMS" ]] && t_pass "generate_iso: the checksums of the earlier run are removed, none are written for the rejected image" \
                || t_fail "generate_iso left checksums beside a rejected image (files: $(ls "$G/out" | tr '\n' ' '))"
        else t_fail "generate_iso failed on the mini image: $(tail -n 5 "$G/gen1.out")"; fi
    fi
fi

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
