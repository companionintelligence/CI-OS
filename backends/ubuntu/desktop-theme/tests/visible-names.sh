#!/usr/bin/env bash
#=============================================================================
# Test: 60-visible-names.sh renames the Ubuntu display names and nothing else
#
# The session picker (ubuntu*.desktop in xsessions and wayland-sessions), the Settings sidebar entry
# (gnome-ubuntu-panel.desktop) and the shell extensions' names (metadata.json) are rewritten from the stock text of
# Ubuntu 24.04. A bad edit on a session file is a login that does not start, so this stages the real files, owned by
# fake packages like the real ones (ubuntu-session, gnome-control-center, the extension packages), runs the real step as
# an image build, and checks that
#
#   - the names read Companion OS, and every other line of every file is byte for byte the stock one (Exec=, TryExec=,
#     DesktopNames=, OnlyShowIn=, Keywords=, uuid, the descriptions, X-Ubuntu-Gettext-Domain), and no file is renamed;
#   - Name[xx]=/Comment[xx]= lines are left alone, and a name the step does not know is not touched or diverted;
#   - all eight stock files are dpkg-diverted to *.ubuntu-stock with their stock bytes, and a package upgrade leaves
#     our file in place;
#   - a second run changes nothing, and a live system without one of the packages (or with a name the step does not
#     know) still finishes, while an IMAGE build in the same state fails, since the base ISO's eight files must all
#     read Companion OS;
#   - a pattern that would change anything but a display name stops the step before it installs.
#
# It changes /usr/share of the machine it runs on, so run it in a throw-away container, with the repo mounted
# read-only:
#
#   docker run --rm -v "$PWD:/repo:ro" ubuntu:24.04 bash /repo/backends/ubuntu/desktop-theme/tests/visible-names.sh
#
# (CI_TEST_ALLOW_HOST=1 overrides the container check on a disposable VM.) Exit status is non-zero if any check
# fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"

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

WORK="$(mktemp -d)"
STOCK="$WORK/stock"

XS=/usr/share/xsessions
WS=/usr/share/wayland-sessions
PANEL=/usr/share/applications/gnome-ubuntu-panel.desktop
EXT=/usr/share/gnome-shell/extensions
DOCK="$EXT/ubuntu-dock@ubuntu.com/metadata.json"
APPIND="$EXT/ubuntu-appindicators@ubuntu.com/metadata.json"
TILING="$EXT/tiling-assistant@ubuntu.com/metadata.json"
ALL=("$XS/ubuntu.desktop" "$XS/ubuntu-xorg.desktop" "$WS/ubuntu.desktop" "$WS/ubuntu-wayland.desktop" "$PANEL" "$DOCK" "$APPIND" "$TILING")

# ── the stock files, as Ubuntu 24.04 ships them (ubuntu-session 46.0-1ubuntu4, gnome-control-center 46.7,
# gnome-shell-extension-ubuntu-dock 90ubuntu3, -appindicator 58-1ubuntu24.04.1, -ubuntu-tiling-assistant 46-1ubuntu1.1)
mkdir -p "$STOCK$XS" "$STOCK$WS" "$STOCK/usr/share/applications" "$STOCK${DOCK%/*}" "$STOCK${APPIND%/*}" "$STOCK${TILING%/*}"
cat > "$STOCK$XS/ubuntu.desktop" <<'EOF'
[Desktop Entry]
Name=Ubuntu
Comment=This session logs you into Ubuntu
Exec=env GNOME_SHELL_SESSION_MODE=ubuntu /usr/bin/gnome-session --session=ubuntu
TryExec=/usr/bin/gnome-shell
Type=Application
DesktopNames=ubuntu;GNOME
X-GDM-SessionRegisters=true
X-GDM-CanRunHeadless=true
X-Ubuntu-Gettext-Domain=gnome-session-46
EOF
cp "$STOCK$XS/ubuntu.desktop" "$STOCK$WS/ubuntu.desktop"
cat > "$STOCK$XS/ubuntu-xorg.desktop" <<'EOF'
[Desktop Entry]
Name=Ubuntu on Xorg
Comment=This session logs you into Ubuntu
Exec=env GNOME_SHELL_SESSION_MODE=ubuntu /usr/bin/gnome-session --session=ubuntu
TryExec=/usr/bin/gnome-shell
Type=Application
DesktopNames=ubuntu;GNOME;
X-GDM-SessionRegisters=true
X-Ubuntu-Gettext-Domain=gnome-session-46
EOF
cat > "$STOCK$WS/ubuntu-wayland.desktop" <<'EOF'
[Desktop Entry]
Name=Ubuntu on Wayland
Comment=This session logs you into Ubuntu
Exec=env GNOME_SHELL_SESSION_MODE=ubuntu /usr/bin/gnome-session --session=ubuntu
TryExec=/usr/bin/gnome-shell
Type=Application
DesktopNames=ubuntu;GNOME;
X-GDM-SessionRegisters=true
X-GDM-CanRunHeadless=true
X-Ubuntu-Gettext-Domain=gnome-session-46
EOF
cat > "$STOCK$PANEL" <<'EOF'
[Desktop Entry]
Name=Ubuntu Desktop
Comment=Ubuntu Desktop Appearance Settings
Exec=gnome-control-center ubuntu
Icon=preferences-ubuntu-panel
Terminal=false
Type=Application
NoDisplay=true
StartupNotify=true
Categories=GNOME;GTK;Settings;DesktopSettings;X-GNOME-Settings-Panel;X-GNOME-PersonalSettings;X-GNOME-PersonalizationSettings;
OnlyShowIn=ubuntu;
# Translators: those are keywords for the ubuntu control-center panel
Keywords=Dock;Launcher;Theme;Ubuntu;Dark;icons;Yaru;Accent;
X-Ubuntu-Gettext-Domain=gnome-control-center-2.0
EOF
cat > "$STOCK$DOCK" <<'EOF'
{
"shell-version": [
    "45",
    "46"
],
"uuid": "ubuntu-dock@ubuntu.com",
"name": "Ubuntu Dock",
"description": "A dock for the Gnome Shell, default Ubuntu experience. This extension is a modified version of Dash To Dock with different defaults. Dash To Dock can be installed to replace it and give more (but unsupported) configuration options.",
"original-author": "micxgx@gmail.com",
"url": "https://micheleg.github.io/dash-to-dock/",
"gettext-domain": "dashtodock",
"version": 90
}
EOF
cat > "$STOCK$APPIND" <<'EOF'
{
    "shell-version": [
        "45",
        "46"
    ],
    "gettext-domain": "AppIndicatorExtension",
    "settings-schema": "org.gnome.shell.extensions.appindicator",
    "uuid": "ubuntu-appindicators@ubuntu.com",
    "name": "Ubuntu AppIndicators",
    "description": "Support app indicators and legacy tray icons in top panel, as the default Ubuntu experience. System update of AppIndicator and KStatusNotifierItem Support extension.",
    "url": "https://github.com/ubuntu/gnome-shell-extension-appindicator"
}
EOF
cat > "$STOCK$TILING" <<'EOF'
{
  "description": "Expand GNOME's 2 column tiling and add a Windows-snap-assist-inspired popup...",
  "name": "Ubuntu Tiling Assistant",
  "shell-version": [
    "45",
    "46"
  ],
  "url": "https://launchpad.net/ubuntu/+source/gnome-shell-extension-tiling-assistant",
  "uuid": "tiling-assistant@ubuntu.com",
  "gettext-domain": "tiling-assistant@leleat-on-github",
  "settings-schema": "org.gnome.shell.extensions.tiling-assistant",
  "version": 46
}
EOF
# Translations normally come from the gettext domain, but a file may carry Name[xx]= lines: they must survive.
printf 'Name[de]=Ubuntu auf Wayland\nComment[de]=Diese Sitzung meldet Sie bei Ubuntu an\n' >> "$STOCK$WS/ubuntu-wayland.desktop"

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
install_all() {
    build_pkg ci-fake-ubuntu-session 1 "$XS/ubuntu.desktop" "$XS/ubuntu-xorg.desktop" "$WS/ubuntu.desktop" "$WS/ubuntu-wayland.desktop"
    build_pkg ci-fake-control-center 1 "$PANEL"
    build_pkg ci-fake-ext-dock 1 "$DOCK"
    build_pkg ci-fake-ext-appindicator 1 "$APPIND"
    build_pkg ci-fake-ext-tiling 1 "$TILING"
}
# Put the machine back: our files go, the diversions are lifted (dpkg-divert --rename refuses to move the stock file
# over ours), the fake packages are purged.
cleanup_machine() {
    local f
    for f in "${ALL[@]}"; do
        rm -f "$f"
        dpkg-divert --remove --rename "$f" >/dev/null 2>&1 || true
    done
    dpkg --purge ci-fake-ubuntu-session ci-fake-control-center ci-fake-ext-dock ci-fake-ext-appindicator ci-fake-ext-tiling >/dev/null 2>&1 || true
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
# changed_lines <path> : the lines that differ between the stock file and the installed one, as "<" / ">" diff lines
changed_lines() { diff "$STOCK$1" "$1" | grep -E '^[<>]' || true; }

install_all

# ── the real repo ───────────────────────────────────────────────────────────
run_step "$REPO"
expect "step exits 0" test "$RC" -eq 0

expect "ubuntu.desktop (xsessions) is named Companion OS" grep -q -x 'Name=Companion OS' "$XS/ubuntu.desktop"
expect "ubuntu.desktop (wayland-sessions) is named Companion OS" grep -q -x 'Name=Companion OS' "$WS/ubuntu.desktop"
expect "ubuntu-xorg.desktop is named Companion OS on Xorg" grep -q -x 'Name=Companion OS on Xorg' "$XS/ubuntu-xorg.desktop"
expect "ubuntu-wayland.desktop is named Companion OS on Wayland" grep -q -x 'Name=Companion OS on Wayland' "$WS/ubuntu-wayland.desktop"
for f in "$XS/ubuntu.desktop" "$XS/ubuntu-xorg.desktop" "$WS/ubuntu.desktop" "$WS/ubuntu-wayland.desktop"; do
    expect "the session comment reads Companion OS in $f" grep -q -x 'Comment=This session logs you into Companion OS' "$f"
done
expect "the Settings sidebar entry is Companion OS Desktop" grep -q -x 'Name=Companion OS Desktop' "$PANEL"
expect "the Settings entry comment is Companion OS Desktop Appearance Settings" grep -q -x 'Comment=Companion OS Desktop Appearance Settings' "$PANEL"
expect "the dock extension is named Companion OS Dock" grep -q '^"name": "Companion OS Dock",$' "$DOCK"
expect "the appindicators extension is named Companion OS AppIndicators" grep -q '^    "name": "Companion OS AppIndicators",$' "$APPIND"
expect "the tiling extension is named Companion OS Tiling Assistant" grep -q '^  "name": "Companion OS Tiling Assistant",$' "$TILING"

# Everything but the display lines is the stock file: the identifiers GDM, gnome-session and gnome-shell find these by.
for f in "${ALL[@]}"; do
    expect "only display lines differ from stock in $f" bash -c "! diff '$STOCK$f' '$f' | grep -E '^[<>]' | grep -v -E '^[<>] ([[:space:]]*\"name\"[[:space:]]*:|Name=|Comment=)'"
done
expect "ubuntu-xorg.desktop changes exactly its Name= and Comment=" bash -c "[[ \$(diff '$STOCK$XS/ubuntu-xorg.desktop' '$XS/ubuntu-xorg.desktop' | grep -c -E '^[<>]') -eq 4 ]]"
expect "a Name[xx]=/Comment[xx]= line is left alone" grep -q -x 'Name\[de\]=Ubuntu auf Wayland' "$WS/ubuntu-wayland.desktop"
for f in "$XS/ubuntu.desktop" "$XS/ubuntu-xorg.desktop" "$WS/ubuntu.desktop" "$WS/ubuntu-wayland.desktop"; do
    expect "session id lines stay in $f" bash -c "grep -q -x 'Exec=env GNOME_SHELL_SESSION_MODE=ubuntu /usr/bin/gnome-session --session=ubuntu' '$f' && grep -q -x 'TryExec=/usr/bin/gnome-shell' '$f' && grep -q -E '^DesktopNames=ubuntu;GNOME;?\$' '$f'"
done
expect "the Settings panel keeps its id (Exec=, OnlyShowIn=)" bash -c "grep -q -x 'Exec=gnome-control-center ubuntu' '$PANEL' && grep -q -x 'OnlyShowIn=ubuntu;' '$PANEL'"
expect "the extension uuids are unchanged" bash -c "grep -q 'ubuntu-dock@ubuntu.com' '$DOCK' && grep -q 'ubuntu-appindicators@ubuntu.com' '$APPIND' && grep -q 'tiling-assistant@ubuntu.com' '$TILING'"
expect "no stock Ubuntu name is left in a Name=, Comment= or \"name\" line" bash -c "! grep -h -E '^(Name|Comment)=.*Ubuntu|^[[:space:]]*\"name\"[[:space:]]*:.*Ubuntu' '$XS/ubuntu.desktop' '$XS/ubuntu-xorg.desktop' '$WS/ubuntu.desktop' '$WS/ubuntu-wayland.desktop' '$PANEL' '$DOCK' '$APPIND' '$TILING'"

# ── diversions: every stock file is kept aside under its own name ───────────
for f in "${ALL[@]}"; do
    expect "$f is diverted and the stock bytes are at $f.ubuntu-stock" bash -c "[[ -n \"\$(dpkg-divert --list '$f')\" ]] && cmp -s '$STOCK$f' '$f.ubuntu-stock'"
done
expect "nothing but the session files and their .ubuntu-stock copies sits in the session directories" bash -c "! find '$XS' '$WS' -mindepth 1 -printf '%f\\n' | grep -v -x -E 'ubuntu(-xorg|-wayland)?\\.desktop(\\.ubuntu-stock)?'"

# A package upgrade unpacks its stock file to the diverted name and leaves ours.
sed -i 's/^Type=Application$/Type=Application\nX-Test-Upgrade=1/' "$STOCK$XS/ubuntu-xorg.desktop"
build_pkg ci-fake-ubuntu-session 2 "$XS/ubuntu.desktop" "$XS/ubuntu-xorg.desktop" "$WS/ubuntu.desktop" "$WS/ubuntu-wayland.desktop"
expect "after a package upgrade the session file is still ours" grep -q -x 'Name=Companion OS on Xorg' "$XS/ubuntu-xorg.desktop"
expect "after a package upgrade the new stock file sits at .ubuntu-stock" grep -q -x 'X-Test-Upgrade=1' "$XS/ubuntu-xorg.desktop.ubuntu-stock"
sed -i '/^X-Test-Upgrade=1$/d' "$STOCK$XS/ubuntu-xorg.desktop"

# ── a second run changes nothing ────────────────────────────────────────────
H1="$(hashes)"; D1="$(dpkg-divert --list | sort)"
run_step "$REPO"
expect "second run exits 0" test "$RC" -eq 0
expect "second run changes no file" test "$(hashes)" = "$H1"
expect "second run diverts nothing more" test "$(dpkg-divert --list | sort)" = "$D1"

# ── a system without one of the packages (not every desktop has the tiling extension) ───
cleanup_machine
install_all
dpkg --purge ci-fake-ext-tiling >/dev/null
run_step "$REPO" live
expect "live step without the tiling extension still exits 0" test "$RC" -eq 0
expect "live step without the tiling extension warns about it" bash -c "grep -q 'Not installed, nothing to rename: $TILING' <<<\"\$1\"" _ "$OUT"
expect "live step without the tiling extension still renames the others" grep -q -x 'Name=Companion OS' "$XS/ubuntu.desktop"
install_all
# An image build starts from the base ISO, which has all eight files: a missing one is a base ISO that changed shape.
cleanup_machine
install_all
dpkg --purge ci-fake-ext-tiling >/dev/null
run_step "$REPO"
expect "an image build without the tiling extension fails" test "$RC" -ne 0
expect "...and names the file that does not read Companion OS" bash -c "grep -q 'do not read Companion OS.*tiling-assistant@ubuntu.com' <<<\"\$1\"" _ "$OUT"
install_all

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
expect "the refused session file is still the stock one" cmp -s "$STOCK$XS/ubuntu.desktop" "$XS/ubuntu.desktop"
expect "the refused session file is not diverted" test -z "$(dpkg-divert --list "$XS/ubuntu.desktop")"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
