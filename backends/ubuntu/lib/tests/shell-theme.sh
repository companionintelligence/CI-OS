#!/usr/bin/env bash
#=============================================================================
# Test: ci_os_install_shell_theme (backends/ubuntu/lib/shell-theme.sh) never takes a stylesheet away from GNOME Shell
#
# Ubuntu 26.04 has two gnome-shell-theme.gresource files. The branded theme is the Yaru theme recoloured, so it has Yaru's
# resources and not the upstream ones (gnome-shell-light.css, gnome-shell-dark.css ... at the top level). customize-chroot.sh
# used to copy it over both; over the upstream file that removes the stylesheets the session modes without a theme of their
# own load (see the header of shell-theme.sh). This test builds small gresources with glib-compile-resources and checks:
#
#   - the Yaru file always gets the branded blob;
#   - the upstream file gets it only when the blob provides every resource of that file; otherwise it is left byte for byte;
#   - an upstream file that does not exist is created, a symlink is left alone, no gresource tool means "keep";
#   - a missing blob changes nothing and returns 1.
#
# Optional, for the real files: CI_TEST_REAL_UPSTREAM=<gnome-shell-theme.gresource of gnome-shell-common> and
# CI_TEST_REAL_BLOB=<the tracked blob> check that the tracked blob is NOT installed over the real upstream file.
#
# Needs gresource and glib-compile-resources (libglib2.0-bin, libglib2.0-dev-bin; brew install glib). Exit 2 without them.
#   backends/ubuntu/lib/tests/shell-theme.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../shell-theme.sh"
[[ -f "$LIB" ]] || { echo "missing $LIB" >&2; exit 2; }
for t in gresource glib-compile-resources; do
    command -v "$t" >/dev/null 2>&1 || { echo "shell-theme test: cannot run here ($t not found)" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shell-theme.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

# shellcheck source=../shell-theme.sh
source "$LIB"
set +e

# make_gresource <out> <resource path>...: a .gresource holding one small file per path (prefix and name split at the last /).
make_gresource() {
    local out="$1" d="$WORK/src.$$.$RANDOM" xml p dir base
    shift
    mkdir -p "$d"
    xml="$d/r.xml"
    echo '<gresources>' >"$xml"
    for p in "$@"; do
        dir="${p%/*}"; base="${p##*/}"
        printf '  <gresource prefix="%s"><file>%s</file></gresource>\n' "$dir" "$base" >>"$xml"
        printf 'content of %s\n' "$p" >"$d/$base"
    done
    echo '</gresources>' >>"$xml"
    glib-compile-resources --target="$out" --sourcedir="$d" "$xml"
}

T=/org/gnome/shell/theme
make_gresource "$WORK/stock-upstream.gresource" $T/gnome-shell-light.css $T/gnome-shell-dark.css $T/gdm.css
make_gresource "$WORK/stock-yaru.gresource"     $T/Yaru/gnome-shell.css $T/gdm.css
make_gresource "$WORK/branded-yaru-shaped.gresource" $T/Yaru/gnome-shell.css $T/gdm.css $T/running-indicator.svg
make_gresource "$WORK/branded-superset.gresource"    $T/Yaru/gnome-shell.css $T/gdm.css $T/gnome-shell-light.css $T/gnome-shell-dark.css

# new_root <name>: a root with the two stock files in place; sets ROOT.
new_root() {
    ROOT="$WORK/root-$1"
    mkdir -p "$ROOT/usr/share/gnome-shell/theme/Yaru"
    cp "$WORK/stock-upstream.gresource" "$ROOT/usr/share/gnome-shell/gnome-shell-theme.gresource"
    cp "$WORK/stock-yaru.gresource" "$ROOT/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
}
TOP="usr/share/gnome-shell/gnome-shell-theme.gresource"
YARU="usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"

echo "== a Yaru-shaped blob (what the tracked one is): the upstream file keeps its stylesheets"
new_root yaru
OUT="$(ci_os_install_shell_theme "$WORK/branded-yaru-shaped.gresource" "$ROOT" 2>&1)"; RC=$?
expect "returns 0" test "$RC" -eq 0
expect "the Yaru file is the branded blob" cmp -s "$ROOT/$YARU" "$WORK/branded-yaru-shaped.gresource"
expect "the upstream file is byte for byte what it was" cmp -s "$ROOT/$TOP" "$WORK/stock-upstream.gresource"
expect "  and still lists gnome-shell-light.css" bash -c "gresource list '$ROOT/$TOP' | grep -q gnome-shell-light.css"
expect "the output says it was kept, and how many resources the blob lacks" bash -c "printf '%s\n' \"\$1\" | grep -q 'kept as Ubuntu ships it: the branded theme lacks 2 of its resources'" _ "$OUT"

echo
echo "== a blob that provides everything the upstream file does"
new_root superset
OUT="$(ci_os_install_shell_theme "$WORK/branded-superset.gresource" "$ROOT" 2>&1)"; RC=$?
expect "returns 0" test "$RC" -eq 0
expect "the Yaru file is the blob" cmp -s "$ROOT/$YARU" "$WORK/branded-superset.gresource"
expect "the upstream file is the blob too" cmp -s "$ROOT/$TOP" "$WORK/branded-superset.gresource"

echo
echo "== an upstream file that is not there / is a symlink"
new_root absent; rm -f "$ROOT/$TOP"
ci_os_install_shell_theme "$WORK/branded-yaru-shaped.gresource" "$ROOT" >/dev/null 2>&1
expect "absent: it is created from the blob" cmp -s "$ROOT/$TOP" "$WORK/branded-yaru-shaped.gresource"
new_root link; rm -f "$ROOT/$TOP"; cp "$WORK/stock-upstream.gresource" "$ROOT/elsewhere.gresource"; ln -s ../../../elsewhere.gresource "$ROOT/$TOP"
OUT="$(ci_os_install_shell_theme "$WORK/branded-superset.gresource" "$ROOT" 2>&1)"
expect "symlink: still a symlink" test -L "$ROOT/$TOP"
expect "symlink: its target is unchanged" cmp -s "$ROOT/elsewhere.gresource" "$WORK/stock-upstream.gresource"

echo
echo "== no gresource tool on PATH: cannot compare, so keep"
new_root notool
mkdir -p "$WORK/bin"
for t in install mkdir dirname comm sort wc tr head cmp; do ln -sf "$(command -v $t)" "$WORK/bin/$t"; done
OUT="$(PATH="$WORK/bin" ci_os_install_shell_theme "$WORK/branded-superset.gresource" "$ROOT" 2>&1)"; RC=$?
expect "returns 0" test "$RC" -eq 0
expect "the Yaru file still gets the blob" cmp -s "$ROOT/$YARU" "$WORK/branded-superset.gresource"
expect "the upstream file is left alone" cmp -s "$ROOT/$TOP" "$WORK/stock-upstream.gresource"
expect "it says why" bash -c "printf '%s\n' \"\$1\" | grep -q 'gresource (libglib2.0-bin) is missing'" _ "$OUT"

echo
echo "== no blob"
new_root noblob
OUT="$(ci_os_install_shell_theme "$WORK/does-not-exist.gresource" "$ROOT" 2>&1)"; RC=$?
expect "returns 1" test "$RC" -eq 1
expect "nothing was changed" bash -c "cmp -s '$ROOT/$YARU' '$WORK/stock-yaru.gresource' && cmp -s '$ROOT/$TOP' '$WORK/stock-upstream.gresource'"

echo
echo "== the real files (CI_TEST_REAL_UPSTREAM and CI_TEST_REAL_BLOB)"
if [[ -n "${CI_TEST_REAL_UPSTREAM:-}" && -f "${CI_TEST_REAL_UPSTREAM:-}" && -n "${CI_TEST_REAL_BLOB:-}" && -f "${CI_TEST_REAL_BLOB:-}" ]]; then
    new_root real
    cp "$CI_TEST_REAL_UPSTREAM" "$ROOT/$TOP"
    OUT="$(ci_os_install_shell_theme "$CI_TEST_REAL_BLOB" "$ROOT" 2>&1)"
    expect "the real tracked blob is installed as the Yaru theme" cmp -s "$ROOT/$YARU" "$CI_TEST_REAL_BLOB"
    expect "the real upstream gnome-shell-theme.gresource ($(wc -c <"$CI_TEST_REAL_UPSTREAM" | tr -d ' ') B) is NOT replaced by it" cmp -s "$ROOT/$TOP" "$CI_TEST_REAL_UPSTREAM"
    expect "  and still has gnome-shell-light.css" bash -c "gresource list '$ROOT/$TOP' | grep -q '/gnome-shell-light.css'"
else
    echo "SKIP  real-file check (set CI_TEST_REAL_UPSTREAM to gnome-shell-common's gnome-shell-theme.gresource and CI_TEST_REAL_BLOB to the tracked blob)"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
