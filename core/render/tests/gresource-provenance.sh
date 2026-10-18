#!/usr/bin/env bash
#=============================================================================
# Test: core/render/render-gnome-shell-gresource.sh only builds from a theme it can identify as Ubuntu 26.04's, and says which
#
# The branded GNOME Shell theme is the Yaru theme recoloured. It used to be rebuilt from /usr/share/gnome-shell/theme/Yaru
# of whatever host ran the build, so a build on a machine of another Ubuntu release silently replaced the 26.04 blob (1.3 MB)
# with one of that release (6 MB, other resources). The script now reads the theme and its identity from SOURCE_ROOTFS (or the running
# system), refuses anything that is not Ubuntu 26.04 with a 26.04 yaru-theme-gnome-shell, prints a [PROVENANCE] block and
# builds the same bytes every time. This test stages small root filesystems and checks all of that:
#
#   - a 26.04 rootfs with a 26.04 Yaru package builds, writes PROVENANCE_FILE, and two builds are byte-identical;
#   - an os-release that is not 26.04, a Yaru package that is not 26.04, a package that is not installed (only
#     "config-files"), a missing dpkg database and a missing os-release are each refused, with no output file;
#   - SOURCE_REQUIRE_OS_VERSION_ID= / SOURCE_PACKAGE= turn the checks off, and the block says "not checked".
#
# Optional, with the real file: CI_TEST_REAL_YARU_ROOT=<a tree made with `dpkg -x yaru-theme-gnome-shell_26.04.5.1ubuntu_all.deb`>
# and CI_TEST_REAL_BLOB=<the tracked blob> rebuild the tracked blob from the real theme and compare the bytes (that is how
# backends/ubuntu/packages/PROVENANCE-gnome-shell-theme.txt was established).
#
# Needs glib-compile-resources, gresource, perl and python3 (libglib2.0-dev-bin, libglib2.0-bin; brew install glib).
# Exit 2 without them. Writes only to a temporary directory.
#   core/render/tests/gresource-provenance.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SCRIPT="$REPO/core/render/render-gnome-shell-gresource.sh"
for t in glib-compile-resources gresource perl python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "gresource-provenance test: cannot run here ($t not found)" >&2; exit 2; }
done
[[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/gres-prov.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

# shellcheck source=../../../vendor/brand/tokens/tokens.sh
source "$REPO/vendor/brand/tokens/tokens.sh"

# A small Yaru-shaped gresource (the real one has 11 resources; these are enough for the extract / recolour / compile path).
SRC="$W/src"; mkdir -p "$SRC"
printf 'a { color: #e95420; }\n' > "$SRC/gnome-shell.css"
printf 'b { color: #e95420; }\n' > "$SRC/gdm.css"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' > "$SRC/gnome-shell-start.svg"
cat > "$SRC/r.xml" <<'XML'
<gresources>
  <gresource prefix="/org/gnome/shell/theme/Yaru"><file>gnome-shell.css</file></gresource>
  <gresource prefix="/org/gnome/shell/theme"><file>gdm.css</file><file>gnome-shell-start.svg</file></gresource>
</gresources>
XML
glib-compile-resources --target="$W/yaru.gresource" --sourcedir="$SRC" "$SRC/r.xml"

# rootfs <name> <os VERSION_ID or -> <package version or -> [status]: a root with the theme, an os-release and a dpkg database.
rootfs() {
    local r="$W/root-$1" ver="$2" pkgver="$3" status="${4:-install ok installed}"
    mkdir -p "$r/usr/share/gnome-shell/theme/Yaru" "$r/usr/lib" "$r/etc" "$r/var/lib/dpkg"
    cp "$W/yaru.gresource" "$r/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
    if [[ "$ver" != "-" ]]; then
        printf 'NAME="Ubuntu"\nVERSION_ID="%s"\nVERSION_CODENAME=x\nID=ubuntu\nUBUNTU_CODENAME=x\n' "$ver" > "$r/usr/lib/os-release"
        ln -s ../usr/lib/os-release "$r/etc/os-release"
    fi
    if [[ "$pkgver" != "-" ]]; then
        printf 'Package: bash\nStatus: install ok installed\nVersion: 5.3-2ubuntu1\n\nPackage: yaru-theme-gnome-shell\nStatus: %s\nVersion: %s\nArchitecture: all\n\nPackage: zzz\nStatus: install ok installed\nVersion: 1\n\n' "$status" "$pkgver" > "$r/var/lib/dpkg/status"
    fi
    ROOT="$r"
}

# build <root> [extra VAR=value...]: runs the script; sets RC and OUT (output of the run), OUTFILE.
OUTFILE="$W/out.gresource"
build() {
    local root="$1"; shift
    rm -f "$OUTFILE" "$W/prov.txt"
    OUT="$(env THEME_NAME=Yaru COLOR_MAP_FILE="$REPO/backends/ubuntu/iso/scripts/yaru-color-map.pl" \
        ACCENT_PRIMARY="$CI_DARK_PRIMARY" ACCENT_SECONDARY="$CI_LIGHT_PRIMARY" \
        ACCENT_PRIMARY_RGB="$(ci_rgb "$CI_DARK_PRIMARY" | tr ' ' ',')" ACCENT_SECONDARY_RGB="$(ci_rgb "$CI_LIGHT_PRIMARY" | tr ' ' ',')" \
        THEME_ASSETS_DIR="$REPO/assets/package theme assets" LOGO_BANNER_FILE="$REPO/assets/logos/2024_CI__Logo_Banner_Color_small.svg" \
        OUTPUT_GRESOURCE="$OUTFILE" PROVENANCE_FILE="$W/prov.txt" SOURCE_ROOTFS="$root" "$@" bash "$SCRIPT" 2>&1)"
    RC=$?
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
out_has() { printf '%s\n' "$OUT" | grep -q -- "$1"; }

echo "== a 26.04 rootfs with a 26.04 Yaru package"
rootfs good 26.04 26.04.5.1ubuntu
build "$ROOT"
expect "builds (exit 0)" test "$RC" -eq 0
[[ "$RC" -eq 0 ]] || printf "%s\n" "$OUT" | sed "s/^/      /" | tail -15
expect "writes the branded gresource" test -s "$OUTFILE"
expect "prints the os-release it read" out_has '\[PROVENANCE\]   os-release: ubuntu 26.04'
expect "prints the package and version" out_has '\[PROVENANCE\]   package: yaru-theme-gnome-shell 26.04.5.1ubuntu'
expect "prints the sha256 of the source file" out_has "sha256 $(sha "$W/yaru.gresource")"
expect "prints the sha256 of the output" out_has "output: .* bytes, sha256 $(sha "$OUTFILE")"
expect "writes PROVENANCE_FILE without the tag" bash -c "grep -q '^gresource source: $ROOT' '$W/prov.txt' && ! grep -q 'PROVENANCE' '$W/prov.txt'"
first="$(sha "$OUTFILE")"
build "$ROOT"
second="$(sha "$OUTFILE")"
expect "a second build is byte-identical (reproducible)" bash -c '[[ -n "$1" && "$1" == "$2" ]]' _ "$first" "$second"
expect "the colour map was applied (the Ubuntu orange is gone from the CSS)" bash -c "! gresource extract '$OUTFILE' /org/gnome/shell/theme/Yaru/gnome-shell.css | grep -qi 'e95420'"

echo
echo "== sources it must refuse (no output file in any case)"
refuse() { # refuse <label> <rootfs> <message regexp>
    build "$2"
    expect "$1: refused (exit 1)" test "$RC" -eq 1
    expect "$1: no gresource written" test ! -e "$OUTFILE"
    expect "$1: the message says why" out_has "$3"
}
rootfs old 24.04 24.04.1ubuntu;       refuse "os-release 24.04" "$ROOT" 'says it is ubuntu 24.04'
rootfs xplus 26.10 26.10.1;           refuse "os-release 26.10" "$ROOT" 'says it is ubuntu 26.10'
rootfs oldpkg 26.04 24.04.2ubuntu;    refuse "26.04 system with a 24.04 Yaru package" "$ROOT" 'does not match'
rootfs gone 26.04 26.04.5.1ubuntu "deinstall ok config-files"; refuse "Yaru package only in config-files state" "$ROOT" 'no installed package yaru-theme-gnome-shell'
rootfs nodb 26.04 -;                  refuse "no dpkg database" "$ROOT" 'no installed package yaru-theme-gnome-shell'
rootfs noos - 26.04.5.1ubuntu;        refuse "no os-release" "$ROOT" 'no os-release'

echo
echo "== the checks can be turned off, and the block says so"
rootfs off 24.04 -
build "$ROOT" SOURCE_REQUIRE_OS_VERSION_ID= SOURCE_PACKAGE=
expect "both checks off: builds" test "$RC" -eq 0
expect "  and says the release was not checked" out_has 'release not checked'

echo
echo "== the real theme (CI_TEST_REAL_YARU_ROOT and CI_TEST_REAL_BLOB)"
if [[ -n "${CI_TEST_REAL_YARU_ROOT:-}" && -f "${CI_TEST_REAL_YARU_ROOT:-}/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource" && -n "${CI_TEST_REAL_BLOB:-}" && -f "${CI_TEST_REAL_BLOB:-}" ]]; then
    rootfs real 26.04 "${CI_TEST_REAL_YARU_VERSION:-26.04.5.1ubuntu}"
    rm -rf "${ROOT:?}/usr"; cp -a "$CI_TEST_REAL_YARU_ROOT/usr" "$ROOT/usr"
    printf 'NAME="Ubuntu"\nVERSION_ID="26.04"\nID=ubuntu\n' > "$ROOT/etc/os-release.new"; rm -f "$ROOT/etc/os-release"; mv "$ROOT/etc/os-release.new" "$ROOT/etc/os-release"
    build "$ROOT"
    expect "the real 26.04 Yaru theme builds" test "$RC" -eq 0
    expect "the rebuilt blob is byte-identical to the tracked one ($(sha "$CI_TEST_REAL_BLOB" | cut -c1-12)...)" test "$(sha "$OUTFILE")" = "$(sha "$CI_TEST_REAL_BLOB")"
else
    echo "SKIP  real-theme check (set CI_TEST_REAL_YARU_ROOT to a dpkg -x tree of yaru-theme-gnome-shell and CI_TEST_REAL_BLOB to the tracked blob)"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
