#!/usr/bin/env bash
#=============================================================================
# Test: the dock list (backends/ubuntu/chroot/dock-favorites.txt) and the reader that turns it into a dconf value
#
# Part A drives backends/ubuntu/lib/dock-favorites.sh with small lists, including the ones that must be refused (an id that
# could change what the dconf keyfile means, a duplicate, an empty list). Part B pins the committed list: the apps the dock
# must hold, the ones Ubuntu's default dock has that Companion OS removes, and the order.
#
# The ids were read from the Companion OS 26.04.1 image (/usr/share/applications and /var/lib/snapd/desktop/applications of a
# running live session, and 10_ubuntu-settings.gschema.override), not guessed.
#
# Needs python3 (to parse the value the way a GVariant text parser would read it) and bash. No network, no root.
#   backends/ubuntu/lib/tests/dock-favorites.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../dock-favorites.sh"
LIST="$HERE/../../chroot/dock-favorites.txt"
[[ -f "$LIB" && -f "$LIST" ]] || { echo "missing $LIB or $LIST" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is needed" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dock-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=../dock-favorites.sh
source "$LIB"
set +e +u

# refused LABEL CONTENT: the reader must exit non-zero, say something on stderr and print no id.
refused() {
  local label="$1" f="$TMP/refused.txt" out err
  printf '%s' "$2" >"$f"
  out="$(dock_favorites_ids "$f" 2>"$TMP/err")"; local rc=$?
  err="$(cat "$TMP/err")"
  if [[ $rc -ne 0 && -n "$err" && -z "$out" ]]; then pass "refused: $label"; else fail "not refused: $label (rc=$rc out='$out' err='$err')"; fi
}

echo "== Part A: the reader"
f="$TMP/ok.txt"
printf '# a comment\n\n  a.desktop  \nCompanion Hub.desktop\n\t# indented comment\nb-c_d.1.desktop\n' >"$f"
eq "comments and blank lines are skipped, blanks around an id trimmed" "$(dock_favorites_ids "$f" | tr '\n' '|')" "a.desktop|Companion Hub.desktop|b-c_d.1.desktop|"
eq "the value is a GVariant string array, a space inside an id kept" "$(dock_favorites_value "$f")" "['a.desktop', 'Companion Hub.desktop', 'b-c_d.1.desktop']"
printf 'one.desktop\r\ntwo.desktop\r\n' >"$TMP/crlf.txt"
eq "a CRLF list reads the same as an LF one" "$(dock_favorites_value "$TMP/crlf.txt")" "['one.desktop', 'two.desktop']"
printf 'last.desktop' >"$TMP/nonl.txt"
eq "a last line without a newline is read" "$(dock_favorites_value "$TMP/nonl.txt")" "['last.desktop']"
printf 'x.desktop\n' >"$TMP/one.txt"
eq "a single id" "$(dock_favorites_value "$TMP/one.txt")" "['x.desktop']"

refused "a single quote (would end the string)" "a'b.desktop
"
refused "a double quote" 'a"b.desktop
'
refused "a comma (would split the entry)" "a,b.desktop
"
refused "a closing bracket" "a].desktop
"
refused "a backslash" 'a\b.desktop
'
refused "a dollar sign" 'a$b.desktop
'
refused "no .desktop suffix" "firefox
"
refused "the suffix only" ".desktop
"
refused "a leading dash" "-a.desktop
"
refused "a slash (a path, not an id)" "/usr/share/applications/a.desktop
"
refused "the same id twice" "a.desktop
b.desktop
a.desktop
"
refused "an empty list" ""
refused "only comments and blank lines" "# nothing

   # nothing
"
if dock_favorites_ids "$TMP/does-not-exist" >/dev/null 2>"$TMP/err"; then fail "a missing file was accepted"; else pass "refused: a missing file ($(cat "$TMP/err" | cut -c1-40)...)"; fi

echo
echo "== Part B: the committed list"
ids="$(dock_favorites_ids "$LIST")"; rc=$?
eq "the committed list is accepted by the reader" "$rc" "0"
value="$(dock_favorites_value "$LIST")"
parsed="$(python3 -c '
import ast, sys
v = ast.literal_eval(sys.argv[1])
assert isinstance(v, list) and all(isinstance(x, str) for x in v)
print("|".join(v))
' "$value" 2>&1)"
eq "the value parses as a list of strings, one per id" "$parsed" "$(printf '%s' "$ids" | tr '\n' '|')"

has() { grep -qxF "$1" <<<"$ids"; }
for want in "Companion Hub.desktop" "companion-capture.desktop" "companion-docs.desktop" "org.gnome.Ptyxis.desktop" \
            "org.gnome.Nautilus.desktop" "ubuntu-desktop-bootstrap_ubuntu-desktop-bootstrap.desktop"; do
  if has "$want"; then pass "dock holds $want"; else fail "dock is missing $want"; fi
done
# The five Ubuntu removes from its default dock (10_ubuntu-settings.gschema.override), by the ids that file uses.
for gone in "firefox_firefox.desktop" "thunderbird_thunderbird.desktop" "libreoffice-writer.desktop" "snap-store_snap-store.desktop" \
            "org.gnome.Yelp.desktop" "firefox.desktop" "org.gnome.Evolution.desktop" "org.gnome.Software.desktop" \
            "org.gnome.Rhythmbox3.desktop" "net.nokyan.Resources.desktop"; do
  if has "$gone"; then fail "dock still holds $gone"; else pass "dock does not hold $gone"; fi
done

pos() { grep -nxF "$1" <<<"$ids" | head -n 1 | cut -d: -f1; }
if [[ "$(pos 'ubuntu-desktop-bootstrap_ubuntu-desktop-bootstrap.desktop')" == 1 ]]; then pass "the live installer is first, so the live-session launcher sits in front of it"; else fail "the installer is not the first entry"; fi
if [[ "$(pos 'Companion Hub.desktop')" -lt "$(pos 'org.gnome.Nautilus.desktop')" && "$(pos 'companion-capture.desktop')" -lt "$(pos 'org.gnome.Nautilus.desktop')" ]]; then
  pass "the Companion apps come before the stock apps"
else
  fail "the Companion apps do not come before Files"
fi
if [[ "$(pos 'org.gnome.Ptyxis.desktop')" == "$(printf '%s\n' "$ids" | wc -l | tr -d '[:space:]')" ]]; then pass "the terminal is last"; else fail "the terminal is not last"; fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
