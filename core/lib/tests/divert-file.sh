#!/usr/bin/env bash
#=============================================================================
# Test: ci_divert_file / ci_install_file are safe to repeat, also across a rebuild without --clean
#
# build-iso.sh re-extracts the stock squashfs layers over $WORK_DIR/chroot every time and wipes that
# directory only with --clean. The re-extraction puts back the stock files AND the stock
# /var/lib/dpkg/diversions, so every dpkg-diverts an earlier run registered are forgotten, but the
# <path>.ubuntu-stock files that run created stay on disk (they are in no layer). The next
# `dpkg-divert --rename --add` then refuses ("rename involves overwriting ... with different file",
# not allowed even for identical content) and, under set -e, aborts the build at Step 5b.
#
# This test builds a throw-away package that owns two files, and drives the real helpers through:
#
#   fresh       first run: file diverted to .ubuntu-stock, ours installed;
#   repeat      second run on the same tree: no-op, still diverted, .ubuntu-stock still the stock file;
#   re-extract  stock files and stock diversions registry put back over the tree (what unsquashfs -f does),
#               then the helper again, as an image build (CI_BRAND_IMAGE_BUILD=1): must succeed and
#               divert again; the same on a live system when the leftover equals the file;
#   foreign     a leftover that differs on a live system is never overwritten (warn, still install ours);
#   unowned     a file no package owns is not diverted.
#
# It installs a fake package into the dpkg database of the machine it runs on and diverts its files, so
# run it in a throw-away container, with the repo mounted read-only:
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:26.04 bash /repo/core/lib/tests/divert-file.sh
#
# (CI_TEST_ALLOW_HOST=1 overrides the container check on a disposable VM.) It removes the package again
# on exit. Exit status is non-zero if any check fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then echo "needs root (dpkg): run it in a throw-away container" >&2; exit 2; fi
for t in dpkg dpkg-deb dpkg-divert; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t (a Debian or Ubuntu system is required)" >&2; exit 2; }
done
if [[ ! -e /.dockerenv && ! -e /run/.containerenv && "${CI_TEST_ALLOW_HOST:-0}" != 1 ]]; then
    echo "refusing to change this machine's dpkg database: run it in a throw-away container (or set CI_TEST_ALLOW_HOST=1)" >&2
    exit 2
fi

# shellcheck source=../theme-lib.sh
source "$REPO_ROOT/core/lib/theme-lib.sh"

WORK="$(mktemp -d)"
PKG=ci-divert-test
DIR=/usr/share/ci-divert-test
A="$DIR/a.png"
B="$DIR/sub/b.svg"
cleanup() {
    local f
    for f in "$A" "$B"; do
        if [[ -n "$(dpkg-divert --list "$f" 2>/dev/null)" ]]; then dpkg-divert --local --rename --remove "$f" >/dev/null 2>&1 || true; fi
    done
    dpkg -P "$PKG" >/dev/null 2>&1 || true
    rm -rf "$WORK" "$DIR"
}
trap cleanup EXIT

# ── a package that owns the two "stock" files ───────────────────────────────
mkdir -p "$WORK/pkg/DEBIAN" "$WORK/pkg$DIR/sub"
cat > "$WORK/pkg/DEBIAN/control" <<EOF
Package: $PKG
Version: 1
Architecture: all
Maintainer: test <test@example.invalid>
Description: stock files for the ci_divert_file test
EOF
printf 'STOCK-A\n' > "$WORK/pkg$A"
printf 'STOCK-B\n' > "$WORK/pkg$B"
dpkg-deb --root-owner-group --build "$WORK/pkg" "$WORK/pkg.deb" >/dev/null
dpkg -i "$WORK/pkg.deb" >/dev/null

# The "stock layer": the package's files and the dpkg diversions registry before any run diverted anything.
mkdir -p "$WORK/stock$DIR/sub"
cp -a "$A" "$WORK/stock$A"
cp -a "$B" "$WORK/stock$B"
cp -a /var/lib/dpkg/diversions "$WORK/stock/diversions"
printf 'OURS-A\n' > "$WORK/ours-a"
printf 'OURS-B\n' > "$WORK/ours-b"

# What `unsquashfs -f` of the stock layers over an existing chroot does: stock files and the stock
# diversions registry come back; nothing that is not in the layers (the .ubuntu-stock files) is removed.
re_extract() {
    cp -a "$WORK/stock$A" "$A"
    cp -a "$WORK/stock$B" "$B"
    cp -a "$WORK/stock/diversions" /var/lib/dpkg/diversions
}

OUT=""; RC=0
run_install() { # run_install <image|live> <src> <dest>
    local mode="$1"; shift
    set +e
    if [[ "$mode" == image ]]; then
        OUT="$( ( export CI_BRAND_IMAGE_BUILD=1; set -e; ci_install_file "$@" ) 2>&1 )"
    else
        OUT="$( ( unset CI_BRAND_IMAGE_BUILD; set -e; ci_install_file "$@" ) 2>&1 )"
    fi
    RC=$?
    set -e
}
diverted() { [[ -n "$(dpkg-divert --list "$1" 2>/dev/null)" ]]; }
same() { cmp -s "$1" "$2"; }
expect() { # expect "<label>" <command...>
    local label="$1"; shift
    if "$@"; then t_pass "$label"; else t_fail "$label"; fi
}
expect_rc0() { # expect_rc0 "<what>"
    if [[ "$RC" -eq 0 ]]; then t_pass "$1: exit status 0"; else t_fail "$1: exit status $RC"; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
}

# ── fresh ───────────────────────────────────────────────────────────────────
run_install image "$WORK/ours-a" "$A"
expect_rc0 "fresh: ci_install_file"
expect "fresh: $A is ours" same "$WORK/ours-a" "$A"
expect "fresh: $A.ubuntu-stock is the stock file" same "$WORK/stock$A" "$A.ubuntu-stock"
expect "fresh: $A is diverted" diverted "$A"

# ── repeat on the same tree ─────────────────────────────────────────────────
run_install image "$WORK/ours-a" "$A"
expect_rc0 "repeat: ci_install_file"
expect "repeat: $A.ubuntu-stock is still the stock file" same "$WORK/stock$A" "$A.ubuntu-stock"
expect "repeat: $A is still diverted" diverted "$A"
run_install live "$WORK/ours-a" "$A"
expect_rc0 "repeat on a live system: ci_install_file"
expect "repeat on a live system: $A.ubuntu-stock is still the stock file" same "$WORK/stock$A" "$A.ubuntu-stock"

# ── re-extraction of the stock layers over the chroot, then the next image build ──
re_extract
expect "re-extract: the stock file is back at $A" same "$WORK/stock$A" "$A"
expect "re-extract: the registry forgot the diversion" bash -c "! [[ -n \"\$(dpkg-divert --list '$A')\" ]]"
run_install image "$WORK/ours-a" "$A"
expect_rc0 "rebuild without --clean: ci_install_file"
expect "rebuild without --clean: $A is ours" same "$WORK/ours-a" "$A"
expect "rebuild without --clean: $A.ubuntu-stock is the stock file" same "$WORK/stock$A" "$A.ubuntu-stock"
expect "rebuild without --clean: $A is diverted again" diverted "$A"

# A second file (in a sub directory), and a second rebuild.
run_install image "$WORK/ours-b" "$B"
expect_rc0 "fresh second file: ci_install_file"
re_extract
run_install image "$WORK/ours-a" "$A"
expect_rc0 "second rebuild: first file"
run_install image "$WORK/ours-b" "$B"
expect_rc0 "second rebuild: second file"
expect "second rebuild: both files diverted" bash -c "[[ -n \"\$(dpkg-divert --list '$A')\" && -n \"\$(dpkg-divert --list '$B')\" ]]"
expect "second rebuild: .ubuntu-stock files are the stock files" bash -c "cmp -s '$WORK/stock$A' '$A.ubuntu-stock' && cmp -s '$WORK/stock$B' '$B.ubuntu-stock'"

# A package upgrade after all this still unpacks the stock file to the diverted name, not over ours.
dpkg -i "$WORK/pkg.deb" >/dev/null 2>&1 || true
expect "package reinstall leaves ours at $A" same "$WORK/ours-a" "$A"

# ── a live system (no image build) with a leftover that equals the file ─────
re_extract
run_install live "$WORK/ours-a" "$A"
expect_rc0 "live system, identical leftover: ci_install_file"
expect "live system, identical leftover: $A is ours and diverted" bash -c "cmp -s '$WORK/ours-a' '$A' && [[ -n \"\$(dpkg-divert --list '$A')\" ]]"

# ── a live system with a leftover that differs: never overwritten ───────────
re_extract
printf 'SOMEONE-ELSES\n' > "$A.ubuntu-stock"
run_install live "$WORK/ours-a" "$A"
expect_rc0 "live system, foreign leftover: ci_install_file"
expect "live system, foreign leftover: kept untouched" bash -c "[[ \"\$(cat '$A.ubuntu-stock')\" == SOMEONE-ELSES ]]"
expect "live system, foreign leftover: ours is still installed" same "$WORK/ours-a" "$A"
expect "live system, foreign leftover: the helper warned" bash -c "printf '%s' \"\$1\" | grep -q WARN" _ "$OUT"

# ── a file no package owns is not diverted ──────────────────────────────────
UNOWNED="$DIR/unowned.svg"
run_install image "$WORK/ours-a" "$UNOWNED"
expect_rc0 "unowned file: ci_install_file"
expect "unowned file: installed" same "$WORK/ours-a" "$UNOWNED"
expect "unowned file: not diverted, no .ubuntu-stock" bash -c "[[ -z \"\$(dpkg-divert --list '$UNOWNED')\" && ! -e '$UNOWNED.ubuntu-stock' ]]"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
