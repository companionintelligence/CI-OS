#!/usr/bin/env bash
#=============================================================================
# Test: 60-visible-names.sh renames the Ubuntu display names and nothing else
#
# The session picker (the one session of Ubuntu 26.04, wayland-sessions/ubuntu.desktop), the Settings sidebar entry
# (gnome-ubuntu-panel.desktop) and the shell extensions' names (metadata.json) are rewritten from the stock text of
# Ubuntu 26.04.1: the five files are in fixtures/stock-26.04.1, byte for byte as the desktop image ships them. A bad edit
# on a session file is a login that does not start, so this stages the real files, owned by fake packages like the real
# ones (ubuntu-session, gnome-control-center, gnome-shell-ubuntu-extensions), runs the real step as an image build, and
# checks that
#
#   - the names read Companion OS, and every other line of every file is byte for byte the stock one (Exec=, TryExec=,
#     DesktopNames=, OnlyShowIn=, Keywords=, uuid, the descriptions, X-Ubuntu-Gettext-Domain), and no file is renamed;
#   - there is exactly one session file, nothing named "on Xorg" or "on Wayland" is created, and the step does not
#     look for the xsessions directory that 26.04 does not have;
#   - Name[xx]=/Comment[xx]= lines are left alone, and a name the step does not know is not touched or diverted;
#   - all five stock files are dpkg-diverted to *.ubuntu-stock with their stock bytes, and a package upgrade leaves
#     our file in place;
#   - a second run changes nothing, and a live system without one of the packages (or with a name the step does not
#     know) still finishes, while an IMAGE build in the same state fails, since the base ISO's five files must all
#     read Companion OS;
#   - a pattern that would change anything but a display name stops the step before it installs.
#
# It changes /usr/share of the machine it runs on, so run it in a throw-away container, with the repo mounted
# read-only:
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:26.04 bash /repo/backends/ubuntu/desktop-theme/tests/visible-names.sh
#
# (CI_TEST_ALLOW_HOST=1 overrides the container check on a disposable VM.) Exit status is non-zero if any check
# fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
FIXTURES="$HERE/fixtures/stock-26.04.1"

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { # expect "<label>" <command...>
    local label="$1"; shift
    if "$@"; then t_pass "$label"; else t_fail "$label"; fi
}

if [[ "$(id -u)" -ne 0 ]]; then echo "needs root: run it in a throw-away container" >&2; exit 2; fi
if [[ ! -e /.dockerenv && ! -e /run/.containerenv && "${CI_TEST_ALLOW_HOST:-0}" != 1 ]]; then
    echo "refusing to change this machine's session files: run it in a throw-away container (or set CI_TEST_ALLOW_HOST=1)" >&2
    exit 2
fi
[[ -d "$FIXTURES" ]] || { echo "missing $FIXTURES" >&2; exit 2; }

WORK="$(mktemp -d)"
STOCK="$WORK/stock"

WS=/usr/share/wayland-sessions
PANEL=/usr/share/applications/gnome-ubuntu-panel.desktop
EXT=/usr/share/gnome-shell/extensions
DOCK="$EXT/ubuntu-dock@ubuntu.com/metadata.json"
APPIND="$EXT/ubuntu-appindicators@ubuntu.com/metadata.json"
TILING="$EXT/tiling-assistant@ubuntu.com/metadata.json"
SESSION="$WS/ubuntu.desktop"
ALL=("$SESSION" "$PANEL" "$DOCK" "$APPIND" "$TILING")

# ── the stock files: the real ones of the Ubuntu 26.04.1 desktop image (fixtures/stock-26.04.1) ──────────────────────
mkdir -p "$STOCK"
cp -a "$FIXTURES/usr" "$STOCK/usr"
# Translations normally come from the gettext domain, but a file may carry Name[xx]= lines: they must survive.
printf 'Name[de]=Ubuntu\nComment[de]=Diese Sitzung meldet Sie bei Ubuntu an\n' >> "$STOCK$SESSION"

# build_pkg <name> <version> <stock-file>... : a package that owns those files, installed over the machine
build_pkg() {
    local name="$1" ver="$2" f; shift 2
    rm -rf "$WORK/pkg-$name"
    mkdir -p "$WORK/pkg-$name/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: test <test@example.invalid>\nDescription: test\n' "$name" "$ver" > "$WORK/pkg-$name/DEBIAN/control"
    for f in "$@"; do install -D -m 644 "$STOCK$f" "$WORK/pkg-$name$f"; done
    dpkg-deb --root-owner-group --build "$WORK/pkg-$name" "$WORK/$name-$ver.deb" >/dev/null
    dpkg -i "$WORK/$name-$ver.deb" >/dev/null
}
# The owners are the real packages' roles: ubuntu-session, gnome-control-center, and ONE package for the three extensions
# (gnome-shell-ubuntu-extensions on 26.04.1; the three used to be separate packages).
install_all() {
    build_pkg ci-fake-ubuntu-session 1 "$SESSION"
    build_pkg ci-fake-control-center 1 "$PANEL"
    build_pkg ci-fake-ubuntu-extensions 1 "$DOCK" "$APPIND" "$TILING"
}
# The same without the tiling extension (a desktop that does not have it): its package ships two files.
install_without_tiling() {
    build_pkg ci-fake-ubuntu-session 1 "$SESSION"
    build_pkg ci-fake-control-center 1 "$PANEL"
    build_pkg ci-fake-ubuntu-extensions 1 "$DOCK" "$APPIND"
}
# Put the machine back: our files go, the diversions are lifted (dpkg-divert --rename refuses to move the stock file
# over ours), the fake packages are purged.
cleanup_machine() {
    local f
    for f in "${ALL[@]}"; do
        rm -f "$f"
        dpkg-divert --remove --rename "$f" >/dev/null 2>&1 || true
    done
    dpkg --purge ci-fake-ubuntu-session ci-fake-control-center ci-fake-ubuntu-extensions >/dev/null 2>&1 || true
    rm -f "${ALL[@]/%/.ubuntu-stock}"
}
trap 'cleanup_machine; rm -rf "$WORK"' EXIT

OUT=""; RC=0
run_step() { # run_step <repo> [live]: as an image build, or as a live system with "live"
    set +e
    if [[ "${2:-}" == live ]]; then
        OUT="$(env -u CI_BRAND_IMAGE_BUILD bash "$1/backends/ubuntu/desktop-theme/60-visible-names.sh" 2>&1)"; RC=$?
    else
        OUT="$(CI_BRAND_IMAGE_BUILD=1 bash "$1/backends/ubuntu/desktop-theme/60-visible-names.sh" 2>&1)"; RC=$?
    fi
    set -e
}
hashes() { sha256sum "${ALL[@]}" 2>/dev/null; }

install_all

# ── the real repo ───────────────────────────────────────────────────────────
run_step "$REPO"
expect "step exits 0" test "$RC" -eq 0

expect "the one session (wayland-sessions/ubuntu.desktop) is named Companion OS" grep -q -x 'Name=Companion OS' "$SESSION"
expect "the session comment reads Companion OS" grep -q -x 'Comment=This session logs you into Companion OS' "$SESSION"
expect "the step did not look for the xsessions directory (it does not exist on 26.04)" bash -c "[[ ! -e /usr/share/xsessions ]] && ! grep -q 'xsessions' <<<\"\$1\"" _ "$OUT"
expect "no \"on Xorg\" or \"on Wayland\" entry was made" bash -c "! grep -r -l -E 'Companion OS on (Xorg|Wayland)' /usr/share/wayland-sessions"
expect "the Settings sidebar entry is Companion OS Desktop" grep -q -x 'Name=Companion OS Desktop' "$PANEL"
expect "the Settings entry comment is Companion OS Desktop Appearance Settings" grep -q -x 'Comment=Companion OS Desktop Appearance Settings' "$PANEL"
expect "the dock extension is named Companion OS Dock" grep -q '^"name": "Companion OS Dock",$' "$DOCK"
expect "the appindicators extension is named Companion OS AppIndicators" grep -q '^    "name": "Companion OS AppIndicators",$' "$APPIND"
expect "the tiling extension is named Companion OS Tiling Assistant" grep -q '^  "name": "Companion OS Tiling Assistant",$' "$TILING"

# Everything but the display lines is the stock file: the identifiers GDM, gnome-session and gnome-shell find these by.
for f in "${ALL[@]}"; do
    expect "only display lines differ from stock in $f" bash -c "! diff '$STOCK$f' '$f' | grep -E '^[<>]' | grep -v -E '^[<>] ([[:space:]]*\"name\"[[:space:]]*:|Name=|Comment=)'"
done
expect "the session file changes exactly its Name= and Comment= (two lines out, two in)" bash -c "[[ \$(diff '$STOCK$SESSION' '$SESSION' | grep -c -E '^[<>]') -eq 4 ]]"
expect "a Name[xx]=/Comment[xx]= line is left alone" bash -c "grep -q -x 'Name\[de\]=Ubuntu' '$SESSION' && grep -q -x 'Comment\[de\]=Diese Sitzung meldet Sie bei Ubuntu an' '$SESSION'"
expect "session id lines stay (Exec=, TryExec=, DesktopNames=) as the 26.04.1 image has them" bash -c "grep -q -x 'Exec=/usr/bin/gnome-session --session=ubuntu' '$SESSION' && grep -q -x 'TryExec=/usr/bin/gnome-session' '$SESSION' && grep -q -x 'DesktopNames=ubuntu;GNOME' '$SESSION'"
expect "the Settings panel keeps its id (Exec=, OnlyShowIn=)" bash -c "grep -q -x 'Exec=gnome-control-center ubuntu' '$PANEL' && grep -q -x 'OnlyShowIn=ubuntu;' '$PANEL'"
expect "the extension uuids are unchanged" bash -c "grep -q 'ubuntu-dock@ubuntu.com' '$DOCK' && grep -q 'ubuntu-appindicators@ubuntu.com' '$APPIND' && grep -q 'tiling-assistant@ubuntu.com' '$TILING'"
expect "no stock Ubuntu name is left in a Name=, Comment= or \"name\" line" bash -c "! grep -h -E '^(Name|Comment)=.*Ubuntu|^[[:space:]]*\"name\"[[:space:]]*:.*Ubuntu' '$SESSION' '$PANEL' '$DOCK' '$APPIND' '$TILING'"

# ── diversions: every stock file is kept aside under its own name ───────────
for f in "${ALL[@]}"; do
    expect "$f is diverted and the stock bytes are at $f.ubuntu-stock" bash -c "[[ -n \"\$(dpkg-divert --list '$f')\" ]] && cmp -s '$STOCK$f' '$f.ubuntu-stock'"
done
expect "nothing but the session file and its .ubuntu-stock copy sits in the session directory" bash -c "! find '$WS' -mindepth 1 -printf '%f\\n' | grep -v -x -E 'ubuntu\\.desktop(\\.ubuntu-stock)?'"

# A package upgrade unpacks its stock file to the diverted name and leaves ours.
sed -i 's/^Type=Application$/Type=Application\nX-Test-Upgrade=1/' "$STOCK$SESSION"
build_pkg ci-fake-ubuntu-session 2 "$SESSION"
expect "after a package upgrade the session file is still ours" grep -q -x 'Name=Companion OS' "$SESSION"
expect "after a package upgrade the new stock file sits at .ubuntu-stock" grep -q -x 'X-Test-Upgrade=1' "$SESSION.ubuntu-stock"
sed -i '/^X-Test-Upgrade=1$/d' "$STOCK$SESSION"

# ── a second run changes nothing ────────────────────────────────────────────
H1="$(hashes)"; D1="$(dpkg-divert --list | sort)"
run_step "$REPO"
expect "second run exits 0" test "$RC" -eq 0
expect "second run changes no file" test "$(hashes)" = "$H1"
expect "second run diverts nothing more" test "$(dpkg-divert --list | sort)" = "$D1"

# ── a system without the tiling extension ───────────────────────────────────
cleanup_machine
install_without_tiling
run_step "$REPO" live
expect "live step without the tiling extension still exits 0" test "$RC" -eq 0
expect "live step without the tiling extension warns about it" bash -c "grep -q 'Not installed, nothing to rename: $TILING' <<<\"\$1\"" _ "$OUT"
expect "live step without the tiling extension still renames the others" grep -q -x 'Name=Companion OS' "$SESSION"
# An image build starts from the base ISO, which has all five files: a missing one is a base ISO that changed shape.
cleanup_machine
install_without_tiling
run_step "$REPO"
expect "an image build without the tiling extension fails" test "$RC" -ne 0
expect "...and names the file that does not read Companion OS" bash -c "grep -q 'do not read Companion OS.*tiling-assistant@ubuntu.com' <<<\"\$1\"" _ "$OUT"
# The case this port exists for: an image whose session is not where 26.04 puts it (an xsessions-only layout).
cleanup_machine
install_all
dpkg --purge ci-fake-ubuntu-session >/dev/null
run_step "$REPO"
expect "an image build with no wayland-sessions/ubuntu.desktop fails (the base changed shape)" test "$RC" -ne 0
expect "...and names the session file" bash -c "grep -q 'do not read Companion OS.*wayland-sessions/ubuntu.desktop' <<<\"\$1\"" _ "$OUT"

# ── a stock text this step does not know is left alone, and not diverted ─────
cleanup_machine
sed -i 's/^"name": "Ubuntu Dock",$/"name": "Dock",/' "$STOCK$DOCK"
install_all
run_step "$REPO" live
expect "live step exits 0 with an extension name it does not know" test "$RC" -eq 0
expect "an unknown extension name stays as shipped" grep -q '^"name": "Dock",$' "$DOCK"
expect "a file that needed no change is not diverted" test -z "$(dpkg-divert --list "$DOCK")"
cleanup_machine
install_all
run_step "$REPO"
expect "an image build with an extension name it does not know fails" test "$RC" -ne 0
expect "...and names the dock extension" bash -c "grep -q 'do not read Companion OS.*ubuntu-dock@ubuntu.com' <<<\"\$1\"" _ "$OUT"
expect "...but the unknown name is still not touched or diverted" bash -c "grep -q '^\"name\": \"Dock\",\$' '$DOCK' && [[ -z \"\$(dpkg-divert --list '$DOCK')\" ]]"

# ── the tripwire: a pattern that touches anything but a display name stops the step ───
cleanup_machine
install_all
mkdir -p "$WORK/repo/backends/ubuntu" "$WORK/repo/core"
cp -a "$REPO/backends/ubuntu/desktop-theme" "$WORK/repo/backends/ubuntu/"
cp -a "$REPO/core/lib" "$WORK/repo/core/"
cp -a "$REPO/vendor" "$WORK/repo/"
sed -i "s|^SESSION_SED=.*|SESSION_SED='s/^Exec=.*/Exec=false/;s/^Name=Ubuntu\$/Name=Companion OS/'|" "$WORK/repo/backends/ubuntu/desktop-theme/60-visible-names.sh"
run_step "$WORK/repo"
expect "a pattern that rewrites Exec= makes the step fail" test "$RC" -ne 0
expect "the step says which file it refused" bash -c "grep -q 'would change more than a display name' <<<\"\$1\"" _ "$OUT"
expect "the refused session file is still the stock one" cmp -s "$STOCK$SESSION" "$SESSION"
expect "the refused session file is not diverted" test -z "$(dpkg-divert --list "$SESSION")"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
