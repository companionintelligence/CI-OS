#!/usr/bin/env bash
#=============================================================================
# Test: verify-iso.sh restore_drift compares what Canonical's installer unit undoes with what the one-click helper undoes
#
# The live layer starts the live session in "installer mode" (no dock, no desktop icons) and the stock unit ubuntu-desktop-installer.service undoes it
# when its window closes (ExecStopPost). This image does not start that unit (customize-chroot.sh Step 7b), so the helper's live_setup() runs the same
# commands (RESTORE_SESSION). The helper's own tests (test_auto_install.py, RestoreSessionTests) pin the three commands; they cannot see the unit change
# in a point release. verify-iso.sh restore_drift can, and this test cuts that function out of the real script and runs it with the real helper
# against unit files: the stock ExecStopPost (it passes), a unit that now restores one more key or extension (it fails and names it), a helper that
# lacks one of the three (it fails and names it), and units that name nothing (a note, no failure).
#
# It cannot say that verify-iso.sh brings the unit file out of the live layer's squashfs (that is a run on an ISO); it checks by text that the
# extraction list and the call are there.
#
# Pure bash (3.2 safe), no root, no network, no xorriso or squashfs-tools.
#   backends/ubuntu/iso/tests/verify-restore-drift.sh
# VERIFY_ISO_SCRIPT=<path> runs it against another copy of verify-iso.sh (a copy with the check weakened must fail it).
# CI_OS_AI_HELPER=<path> runs it against another copy of the helper (the one inside an ISO, or a mutant).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
VERIFY="${VERIFY_ISO_SCRIPT:-$REPO/backends/ubuntu/iso/scripts/verify-iso.sh}"
HELPER="${CI_OS_AI_HELPER:-$REPO/backends/ubuntu/chroot/payload/live-start/usr/libexec/ci-os/ci-os-auto-install}"
for f in "$VERIFY" "$HELPER"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-restore.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# ── the function, cut out of verify-iso.sh together with the three output helpers it uses ──────────────────────────────────────────────
FUNC="$WORK/func.sh"
{ sed -n '/^pass() {/p;/^fail() {/p;/^note() {/p' "$VERIFY"; sed -n '/^restore_drift() {/,/^}/p' "$VERIFY"; } > "$FUNC"
[[ "$(grep -c '^restore_drift() {' "$FUNC")" == 1 && "$(grep -c '^pass() {\|^fail() {\|^note() {' "$FUNC")" == 3 ]] \
    || { echo "could not cut restore_drift and its helpers out of $VERIFY" >&2; exit 2; }

# run_drift <unit file> <helper>: the verify-iso.sh function in a subshell; its output in OUT, its PASS and FAIL counts in P and F
run_drift() {
    # shellcheck disable=SC1090
    OUT="$( PASS=0; FAIL=0; . "$FUNC"; restore_drift "$1" "$2"; echo "COUNTS $PASS $FAIL" )"
    P="$(sed -n 's/^COUNTS \([0-9]*\) [0-9]*$/\1/p' <<<"$OUT")"; F="$(sed -n 's/^COUNTS [0-9]* \([0-9]*\)$/\1/p' <<<"$OUT")"
}

# unit files: the stock one has the ExecStopPost that the 26.04.1 live layer carries (read from the real image, 2026-10-20)
unit() { # unit <file> [ExecStopPost value]: no second argument means no such line
    {
        printf '# start the installer on session start, restore normal session on close\n[Unit]\nDescription=Ubuntu Desktop Installer\nPartOf=graphical-session.target\n\n[Service]\nType=oneshot\n'
        printf 'ExecStart=/snap/bin/ubuntu-desktop-bootstrap --try-or-install\n'
        [[ $# -lt 2 ]] || printf 'ExecStopPost=%s\n' "$2"
        printf 'Restart=no\n'
    } > "$1"
}
DOCK='gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed true; gsettings set org.gnome.shell.extensions.dash-to-dock intellihide true; gnome-extensions enable ding@rastersoft.com'
unit "$WORK/stock.service" "sh -c \"$DOCK\""

echo "== 1. the stock unit and the real helper"
run_drift "$WORK/stock.service" "$HELPER"
eq "one PASS, no FAIL" "$P $F" "1 0"
expect "  the PASS names the three things the stock unit restores (the extension and the two dock keys)" \
    bash -c 'grep -q -F "ding@rastersoft.com dock-fixed intellihide" <<<"$1"' _ "$OUT"

unit "$WORK/single-quoted.service" "sh -c '$DOCK'"
run_drift "$WORK/single-quoted.service" "$HELPER"
eq "the same commands in single quotes read the same (one PASS, no FAIL)" "$P $F" "1 0"
expect "  and the closing quote is not part of the extension's name" bash -c '! grep -q "ding@rastersoft.com'"'"'" <<<"$1"' _ "$OUT"

echo
echo "== 2. the unit restores something more: the helper must too"
unit "$WORK/more-key.service" "sh -c \"$DOCK; gsettings set org.gnome.shell favorite-apps '[]'\""
run_drift "$WORK/more-key.service" "$HELPER"
eq "a new dconf key: no PASS, one FAIL" "$P $F" "0 1"
expect "  and the FAIL names it" bash -c 'grep "^FAIL" <<<"$1" | grep -q -F "restores favorite-apps when"' _ "$OUT"
unit "$WORK/more-ext.service" "sh -c \"$DOCK; gnome-extensions enable ubuntu-dock@ubuntu.com\""
run_drift "$WORK/more-ext.service" "$HELPER"
eq "a second extension: no PASS, one FAIL" "$P $F" "0 1"
expect "  and the FAIL names it" bash -c 'grep "^FAIL" <<<"$1" | grep -q -F "ubuntu-dock@ubuntu.com"' _ "$OUT"
unit "$WORK/disable-ext.service" "sh -c \"$DOCK; gnome-extensions disable tiling-assistant@ubuntu.com\""
run_drift "$WORK/disable-ext.service" "$HELPER"
eq "an extension the unit turns off is a name the helper must also handle (one FAIL)" "$P $F" "0 1"

echo
echo "== 3. the helper lacks one of the three"
for gone in dock-fixed intellihide ding@rastersoft.com; do
    sed "s/\"$gone\"/\"x-$gone\"/" "$HELPER" > "$WORK/helper-lacks-$gone"
    run_drift "$WORK/stock.service" "$WORK/helper-lacks-$gone"
    eq "a helper without $gone: no PASS, one FAIL" "$P $F" "0 1"
    expect "  and the FAIL names it" bash -c 'grep "^FAIL" <<<"$1" | grep -q -F -- "restores $2 when"' _ "$OUT" "$gone"
done
: > "$WORK/empty-helper"
run_drift "$WORK/stock.service" "$WORK/empty-helper"
eq "an empty helper: one FAIL that names all three" "$P $F" "0 1"
expect "  (names in sorted order)" bash -c 'grep "^FAIL" <<<"$1" | grep -q -F "restores ding@rastersoft.com dock-fixed intellihide when"' _ "$OUT"

echo
echo "== 4. a unit that names nothing is a note, not a failure"
unit "$WORK/no-stop.service"
run_drift "$WORK/no-stop.service" "$HELPER"
eq "no ExecStopPost: no PASS, no FAIL" "$P $F" "0 0"
expect "  and one note that says so" bash -c 'grep -c "^info  installer unit: ExecStopPost names no dconf key" <<<"$1" | grep -q "^1$"' _ "$OUT"
unit "$WORK/other-stop.service" "/bin/true"
run_drift "$WORK/other-stop.service" "$HELPER"
eq "an ExecStopPost that runs something else: no PASS, no FAIL" "$P $F" "0 0"
expect "  and it says what it read" bash -c 'grep -q "(read: /bin/true)" <<<"$1"' _ "$OUT"
run_drift "$WORK/does-not-exist.service" "$HELPER"
eq "a unit file that is not there: no FAIL" "$P $F" "0 0"

echo
echo "== 5. verify-iso.sh brings the unit out of the live layer and calls the check"
expect "the extraction list of the live layer has the unit" \
    bash -c 'grep -F unsquashfs "$1" | grep -F -- "-d \"\$LR\" \"\$LIVESQ\"" | grep -q -F usr/lib/systemd/user/ubuntu-desktop-installer.service' _ "$VERIFY"
expect "restore_drift is called with the extracted unit and the helper of the installed layer (\$AI)" \
    bash -c 'grep -F "restore_drift \"\$LR/usr/lib/systemd/user/ubuntu-desktop-installer.service\" \"\$AI\"" "$1" >/dev/null' _ "$VERIFY"
expect "AI is defined before section 3g reads it" \
    bash -c 'a="$(grep -n "^AI=" "$1" | head -n 1 | cut -d: -f1)"; b="$(grep -n "restore_drift \"\$LR" "$1" | head -n 1 | cut -d: -f1)"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$VERIFY"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
