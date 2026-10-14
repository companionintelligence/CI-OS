#!/usr/bin/env bash
#=============================================================================
# md5sum.txt of a remastered Ubuntu live ISO: write it, check the base ISO's convention, verify an image.
#
# Why this exists. The live medium carries /md5sum.txt, and "Check disc for defects" runs
# `/usr/lib/casper/casper-md5check /cdrom /cdrom/md5sum.txt` (casper): for every line "<md5>  ./<path>" it opens the
# path under the medium's root, hashes it and prints "<path>: OK" or "<path>: mismatch", then reports "errors found
# in N files". build-iso.sh replaces the casper layers, the initrd, grub.cfg, loopback.cfg and .disk/info and adds a GRUB
# background, so the stock md5sum.txt, copied through unchanged, is wrong for every one of them: the check failed on every
# Companion OS image, and it would name files that the remaster deleted. This script rewrites it from the stock one.
#
# The convention of a stock Ubuntu md5sum.txt (24.04.5.1, read off the ISO: 448 entries, 1019 regular files):
#   * a line is "<32 hex>  ./<path>", two spaces, LF-terminated, the order is the order `find` left (not sorted);
#   * it lists every regular file EXCEPT: /md5sum.txt itself, everything under /EFI/, and everything in a SUBDIRECTORY of
#     /boot/grub/ (fonts/, i386-pc/, x86_64-efi/); /boot/grub/grub.cfg and loopback.cfg are listed.
# `check-stock` proves a base ISO still follows exactly that, so a changed Ubuntu does not slip through unnoticed.
#
# Usage:
#   md5sum-txt.sh check-stock (--base-iso ISO | --stock-md5 FILE --stock-files FILE)
#       Exit 1, naming the files, unless the stock md5sum.txt lists exactly the regular files that are not excluded.
#   md5sum-txt.sh regenerate  (--base-iso ISO | --stock-md5 FILE --stock-files FILE) --out FILE
#                             [--rm ISOPATH]... [--map SRC ISOPATH]...
#       Write the md5sum.txt of the image that results from taking the base ISO, deleting every --rm path (recursively),
#       then mapping every --map (a file, or a directory with all it holds) in, in that order: the same order as
#       `xorriso -rm_r ... -map ...`. The stock hash is kept for every file the maps do not touch, the hash is computed from
#       SRC for every mapped file, entries of deleted files are dropped, new files are appended in sorted order and the
#       excluded paths stay out. Stock order is kept. It runs check-stock first and exits non-zero without writing FILE on
#       any problem: there is no fallback to the stale file. --stock-files is a list of /path lines (the regular files).
#   md5sum-txt.sh verify ISO
#       Read the image's /md5sum.txt and hash every listed file by STREAMING it out of the image (xorriso -find ... report_lba
#       for the extents, then dd | md5sum; nothing is extracted to disk, so a 7.7 GB ISO needs no scratch space and a minute or
#       two). Prints one line per problem (MISMATCH / MISSING / UNLISTED / DUPLICATE / BADLINE) and a final SUMMARY line;
#       exit 1 if there was any problem. Needs xorriso, dd (GNU), md5sum.
#
# Needs: bash 3.2+, awk, find, sort, md5sum (or md5 on macOS: regenerate only); xorriso for --base-iso and verify.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

PROG="md5sum-txt.sh"
err() { printf '%s: ERROR: %s\n' "$PROG" "$*" >&2; }
die() { err "$*"; exit 1; }
usage() { sed -n '/^# Usage:/,/^# Needs:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# The awk the three commands share. excluded(): the paths a stock md5sum.txt leaves out (see the header).
# parse_md5_line(): "<md5>  ./<path>" -> P_HASH, P_PATH ("/<path>"), or 0 when the line has another shape. A path with a
# backslash is refused: md5sum -c writes such names escaped, and casper-md5check does not read that form.
AWK_COMMON='
function excluded(p) {
    if (p == "/md5sum.txt") return 1
    if (p ~ /^\/EFI\//) return 1
    if (p ~ /^\/boot\/grub\/[^\/]+\/./) return 1
    return 0
}
function parse_md5_line(line,    h, sep, p) {
    h = substr(line, 1, 32); sep = substr(line, 33, 2); p = substr(line, 35)
    if (length(line) < 37 || h !~ /^[0-9a-f]+$/ || sep != "  " || substr(p, 1, 2) != "./") return 0
    if (index(p, "\\") > 0) return 0
    P_HASH = h; P_PATH = substr(p, 2)
    return 1
}'

md5_of() { # md5_of FILE: the hash alone
    local out
    if command -v md5sum >/dev/null 2>&1; then out="$(md5sum < "$1")"
    elif command -v md5 >/dev/null 2>&1; then out="$(md5 -q "$1")"
    else die "neither md5sum nor md5 is installed"; fi
    printf '%s\n' "${out%% *}"
}

need_xorriso() { command -v xorriso >/dev/null 2>&1 || die "xorriso is not installed (needed for --base-iso and verify)"; }

# iso_table ISO OUT: one line per regular file of the image, "<path> TAB <size> TAB <lba:blocks[,lba:blocks...]>",
# from `xorriso -find / -type f -exec report_lba`. A file over 4 GiB has several extents (xt 0, 1, ...), one line each,
# all carrying the whole file size; an empty file has none. ISO 9660 blocks are 2048 bytes.
iso_table() {
    local iso="$1" out="$2" raw
    raw="$out.raw"
    need_xorriso
    if ! xorriso -indev "$iso" -find / -type f -exec report_lba -- > "$raw" 2> "$raw.err"; then
        die "xorriso could not read $iso: $(tail -n 3 "$raw.err" | tr '\n' ' ')"
    fi
    awk '
    /^File data lba:/ {
        n = split($0, f, / , /)
        if (n < 5) next
        lba = f[2]; blocks = f[3]; size = f[4]
        gsub(/ /, "", lba); gsub(/ /, "", blocks); gsub(/ /, "", size)
        path = f[5]
        for (k = 6; k <= n; k++) path = path " , " f[k]
        if (substr(path, 1, 1) != "\047" || substr(path, length(path), 1) != "\047") next
        path = substr(path, 2, length(path) - 2)
        if (index(path, "\047") > 0) { printf "unsupported file name (quote) in the image: %s\n", path > "/dev/stderr"; bad = 1; next }
        ext = (blocks + 0 > 0) ? lba ":" blocks : ""
        if (path == prev) { cur = cur (ext == "" ? "" : "," ext); next }
        if (prev != "") printf "%s\t%s\t%s\n", prev, psize, cur
        prev = path; psize = size; cur = ext
    }
    END { if (prev != "") printf "%s\t%s\t%s\n", prev, psize, cur; if (bad) exit 1 }' "$raw" > "$out" \
        || die "could not read the file table of $iso"
    [[ -s "$out" ]] || die "$iso holds no regular file (is it an ISO image?)"
}

# extract_stock_md5 ISO OUT: /md5sum.txt of the image.
extract_md5sum_txt() {
    need_xorriso
    rm -f "$2"
    xorriso -osirrox on -indev "$1" -extract /md5sum.txt "$2" >/dev/null 2>&1 && [[ -s "$2" ]] \
        || die "$1 has no /md5sum.txt"
}

# iso_stream_hash ISO SIZE EXTENTS [HASHCMD]: the hash of one file, read straight from the image by its extents.
# Fails (non-zero, no hash) if an extent cannot be read or the extents do not add up to SIZE.
iso_stream_hash() {
    local iso="$1" size="$2" extents="$3" hashcmd="${4:-md5sum}"
    (
        remaining="$size"
        IFS=','
        for e in $extents; do
            lba="${e%%:*}"; blocks="${e##*:}"
            take=$(( blocks * 2048 ))
            if (( take > remaining )); then take="$remaining"; fi
            if (( take > 0 )); then
                dd if="$iso" bs=4M iflag=skip_bytes,count_bytes skip=$(( lba * 2048 )) count="$take" status=none || exit 1
            fi
            remaining=$(( remaining - take ))
        done
        [[ "$remaining" -eq 0 ]] || exit 1
    ) | "$hashcmd" | cut -d' ' -f1
}

#--- stock inputs ---------------------------------------------------------------------------------------------------------
STOCK_MD5=""; STOCK_FILES=""; BASE_ISO=""; OUT=""
load_stock() { # fills $T/stock.md5 and $T/stock.files from --base-iso or the two files
    if [[ -n "$BASE_ISO" ]]; then
        [[ -f "$BASE_ISO" ]] || die "base ISO not found: $BASE_ISO"
        [[ -z "$STOCK_MD5$STOCK_FILES" ]] || die "give --base-iso, or --stock-md5 with --stock-files, not both"
        extract_md5sum_txt "$BASE_ISO" "$T/stock.md5"
        iso_table "$BASE_ISO" "$T/stock.table"
        cut -f1 "$T/stock.table" > "$T/stock.files"
    else
        [[ -n "$STOCK_MD5" && -n "$STOCK_FILES" ]] || die "give --base-iso, or both --stock-md5 and --stock-files"
        [[ -f "$STOCK_MD5" ]] || die "stock md5sum.txt not found: $STOCK_MD5"
        [[ -f "$STOCK_FILES" ]] || die "stock file list not found: $STOCK_FILES"
        cp "$STOCK_MD5" "$T/stock.md5"; cp "$STOCK_FILES" "$T/stock.files"
    fi
}

# The awk both check-stock and regenerate run: load the stock md5sum.txt and file list, prove the convention, then (mode
# regenerate) merge the changes. Retained and re-hashed lines go to stdout in stock order, new lines to $newf.
STOCK_AWK="$AWK_COMMON"'
function problem(msg) { nbad++; if (nbad <= 25) printf "%s: ERROR: %s\n", prog, msg > "/dev/stderr" }
function gone(p,    i) {
    for (i = 1; i <= nr; i++) if (p == rms[i] || index(p, rms[i] "/") == 1) return 1
    return 0
}
BEGIN {
    nbad = 0; n = 0; ns = 0; nc = 0; nr = 0
    lineno = 0
    while ((getline line < md5f) > 0) {
        lineno++
        if (!parse_md5_line(line)) { problem("the base ISO md5sum.txt line " lineno " is not \"<md5>  ./<path>\": " line); continue }
        if (P_PATH in smd5) { problem("the base ISO md5sum.txt lists " P_PATH " twice"); continue }
        smd5[P_PATH] = P_HASH; sorder[++n] = P_PATH
    }
    close(md5f)
    if (n == 0) problem("the base ISO md5sum.txt is empty or unreadable")
    while ((getline p < filesf) > 0) {
        if (p == "") continue
        if (substr(p, 1, 1) != "/" || index(p, "\\") > 0 || index(p, "\t") > 0) { problem("unsupported file name in the base ISO: " p); continue }
        stock[p] = 1; sfiles[++ns] = p
    }
    close(filesf)
    # The convention: the stock md5sum.txt lists exactly the regular files that are not excluded.
    for (i = 1; i <= ns; i++) {
        p = sfiles[i]
        if (!excluded(p) && !(p in smd5)) problem("the base ISO has " p ", which its md5sum.txt does not list and this script does not know as an exclusion")
        if (excluded(p) && (p in smd5)) problem("the base ISO md5sum.txt lists " p ", which this script treats as an exclusion")
    }
    for (i = 1; i <= n; i++) if (!(sorder[i] in stock)) problem("the base ISO md5sum.txt lists " sorder[i] ", which is not a file of the base ISO")
    if (nbad > 0) {
        if (nbad > 25) printf "%s: ERROR: ... and %d more\n", prog, nbad - 25 > "/dev/stderr"
        printf "%s: ERROR: the base ISO does not follow the md5sum.txt convention this script was written against (see its header); review before remastering it\n", prog > "/dev/stderr"
        exit 1
    }
    if (mode == "check") { printf "stock md5sum.txt convention holds: %d entries, %d regular files, %d excluded\n", n, ns, ns - n; exit 0 }

    while ((getline line < chf) > 0) { split(line, t, "\t"); if (!(t[2] in changed)) corder[++nc] = t[2]; changed[t[2]] = t[1] }
    close(chf)
    while ((getline p < rmf) > 0) if (p != "") rms[++nr] = p
    close(rmf)
    # The image after the removals and the maps.
    for (i = 1; i <= ns; i++) { p = sfiles[i]; if (!gone(p) && !(p in changed)) final[p] = 1 }
    for (i = 1; i <= nc; i++) final[corder[i]] = 1
    kept = 0; rehashed = 0; dropped = 0; added = 0
    for (i = 1; i <= n; i++) {
        p = sorder[i]
        if (!(p in final)) { dropped++; continue }
        if (p in changed) { h = changed[p]; rehashed++ } else { h = smd5[p]; kept++ }
        print h "  ." p
        seen[p] = 1
    }
    for (i = 1; i <= nc; i++) {
        p = corder[i]
        if ((p in seen) || excluded(p)) continue
        print changed[p] "  ." p > newf
        seen[p] = 1; added++
    }
    close(newf)
    want = 0
    for (p in final) if (!excluded(p)) want++
    if (want != kept + rehashed + added) { printf "%s: ERROR: internal: %d files need a line, %d were written\n", prog, want, kept + rehashed + added > "/dev/stderr"; exit 1 }
    printf "%s: md5sum.txt: %d stock hashes kept, %d recomputed, %d new, %d dropped, %d lines\n", prog, kept, rehashed, added, dropped, want > "/dev/stderr"
}'

cmd_check_stock() {
    load_stock
    awk -v prog="$PROG" -v mode=check -v md5f="$T/stock.md5" -v filesf="$T/stock.files" "$STOCK_AWK" \
        || die "check-stock failed"
}

cmd_regenerate() {
    local rm_list="$T/rm.list" changed="$T/changed.tsv" src dest f rel
    : > "$rm_list"; : > "$changed"
    [[ -n "$OUT" ]] || die "regenerate needs --out FILE"
    load_stock
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rm)
                [[ $# -ge 2 && "$2" == /* ]] || die "--rm needs an absolute ISO path"
                dest="${2%/}"; [[ -n "$dest" ]] || die "--rm / would delete the whole image"
                printf '%s\n' "$dest" >> "$rm_list"; shift 2 ;;
            --map)
                [[ $# -ge 3 && "$3" == /* ]] || die "--map needs SRC and an absolute ISO path"
                src="${2%/}"; dest="${3%/}"
                if [[ -L "$src" ]]; then die "--map $src: a symlink is mapped as a link, not as the file it points to (unsupported)"; fi
                if [[ -d "$src" ]]; then
                    if [[ -n "$(find "$src" ! -type f ! -type d -print -quit)" ]]; then
                        die "--map $src: it holds something that is neither a regular file nor a directory ($(find "$src" ! -type f ! -type d -print -quit))"
                    fi
                    while IFS= read -r -d '' f; do
                        rel="${f#"$src"/}"
                        case "$rel" in *$'\t'*|*\\*|*$'\n'*) die "--map $src: unsupported file name: $rel" ;; esac
                        printf '%s\t%s\n' "$(md5_of "$f")" "$dest/$rel" >> "$changed"
                    done < <(find "$src" -type f -print0)
                elif [[ -f "$src" ]]; then
                    [[ -n "$dest" ]] || die "--map $src /: the destination has to be a path"
                    printf '%s\t%s\n' "$(md5_of "$src")" "$dest" >> "$changed"
                else
                    die "--map source not found: $src"
                fi
                shift 3 ;;
            *) die "regenerate: unknown argument: $1" ;;
        esac
    done
: > "$T/new.lines"
    awk -v prog="$PROG" -v mode=regenerate -v md5f="$T/stock.md5" -v filesf="$T/stock.files" \
        -v chf="$changed" -v rmf="$rm_list" -v newf="$T/new.lines" "$STOCK_AWK" > "$T/out.retained" \
        || die "could not write the md5sum.txt (nothing was written to $OUT)"
    { cat "$T/out.retained"; LC_ALL=C sort -k 2 "$T/new.lines"; } > "$T/out.final"
    [[ -s "$T/out.final" ]] || die "the regenerated md5sum.txt is empty (nothing was written to $OUT)"
    chmod 644 "$T/out.final"
    cp "$T/out.final" "$OUT"
}

cmd_verify() {
    local iso="${1:-}" kind a b c d got t
    local ok=0 mismatch=0 missing=0 unlisted=0 dup=0 badline=0 entries=0
    [[ -n "$iso" && -f "$iso" ]] || die "verify needs the path of an ISO image"
    for t in dd md5sum cut; do command -v "$t" >/dev/null 2>&1 || die "$t is not installed"; done
    dd if=/dev/null of=/dev/null iflag=skip_bytes,count_bytes count=0 status=none 2>/dev/null \
        || die "dd here lacks iflag=skip_bytes,count_bytes and status=none: GNU coreutils dd is needed to read files out of the image"
    iso_table "$iso" "$T/iso.table"
    extract_md5sum_txt "$iso" "$T/image.md5"
    awk -v md5f="$T/image.md5" -v tablef="$T/iso.table" "$AWK_COMMON"'
    BEGIN {
        nt = 0
        while ((getline line < tablef) > 0) { split(line, t, "\t"); size[t[1]] = t[2]; ext[t[1]] = t[3]; order[++nt] = t[1] }
        lineno = 0
        while ((getline line < md5f) > 0) {
            lineno++
            if (!parse_md5_line(line)) { print "BADLINE\t" lineno "\t" line; continue }
            if (P_PATH in listed) { print "DUPLICATE\t" P_PATH; continue }
            listed[P_PATH] = 1
            if (!(P_PATH in size)) { print "MISSING\t" P_PATH; continue }
            print "ENTRY\t" P_HASH "\t" P_PATH "\t" size[P_PATH] "\t" ext[P_PATH]
        }
        for (i = 1; i <= nt; i++) if (!(order[i] in listed) && !excluded(order[i])) print "UNLISTED\t" order[i]
    }' > "$T/join.tsv"
    while IFS=$'\t' read -r kind a b c d; do
        case "$kind" in
            ENTRY)
                entries=$((entries + 1))
                if got="$(iso_stream_hash "$iso" "$c" "$d")" && [[ -n "$got" ]]; then
                    if [[ "$got" == "$a" ]]; then ok=$((ok + 1)); else mismatch=$((mismatch + 1)); printf 'MISMATCH %s listed=%s actual=%s\n' "$b" "$a" "$got"; fi
                else
                    mismatch=$((mismatch + 1)); printf 'MISMATCH %s listed=%s actual=unreadable\n' "$b" "$a"
                fi ;;
            MISSING) entries=$((entries + 1)); missing=$((missing + 1)); printf 'MISSING %s (listed in md5sum.txt, not in the image)\n' "$a" ;;
            UNLISTED) unlisted=$((unlisted + 1)); printf 'UNLISTED %s (a regular file of the image, not listed in md5sum.txt)\n' "$a" ;;
            DUPLICATE) dup=$((dup + 1)); printf 'DUPLICATE %s (listed twice)\n' "$a" ;;
            BADLINE) badline=$((badline + 1)); printf 'BADLINE %s: %s\n' "$a" "$b" ;;
        esac
    done < "$T/join.tsv"
    printf 'SUMMARY entries=%d matched=%d mismatched=%d missing=%d unlisted=%d duplicate=%d malformed=%d\n' \
        "$entries" "$ok" "$mismatch" "$missing" "$unlisted" "$dup" "$badline"
    [[ "$entries" -gt 0 ]] || return 1
    [[ "$((mismatch + missing + unlisted + dup + badline))" -eq 0 ]]
}

main() {
    local cmd="${1:-}"
    [[ -n "$cmd" ]] || usage
    shift
    T="$(mktemp -d "${TMPDIR:-/tmp}/md5sum-txt.XXXXXX")"
    trap 'rm -rf "$T"' EXIT
    case "$cmd" in
        check-stock|regenerate)
            local -a rest=()
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --base-iso)    [[ $# -ge 2 ]] || usage; BASE_ISO="$2"; shift 2 ;;
                    --stock-md5)   [[ $# -ge 2 ]] || usage; STOCK_MD5="$2"; shift 2 ;;
                    --stock-files) [[ $# -ge 2 ]] || usage; STOCK_FILES="$2"; shift 2 ;;
                    --out)         [[ $# -ge 2 ]] || usage; OUT="$2"; shift 2 ;;
                    --rm)          [[ $# -ge 2 ]] || usage; rest+=("$1" "$2"); shift 2 ;;
                    --map)         [[ $# -ge 3 ]] || usage; rest+=("$1" "$2" "$3"); shift 3 ;;
                    *) err "unknown argument: $1"; usage ;;
                esac
            done
            if [[ "$cmd" == check-stock ]]; then cmd_check_stock; else cmd_regenerate ${rest[@]+"${rest[@]}"}; fi ;;
        verify) cmd_verify "$@" ;;
        -h|--help) usage ;;
        *) err "unknown command: $cmd"; usage ;;
    esac
}

# Run unless this file is being sourced (a test sources it for iso_stream_hash).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
