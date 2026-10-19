#!/usr/bin/env bash
#=============================================================================
# Test: the Companion links list, its reader, the desktop entries made from it, and the first-login welcome script
#
# Part A drives backends/ubuntu/lib/start-links.sh with small lists, including every kind of line it must refuse (a URL that
# is not plain https, an id that belongs to another part of the image, a name that could change what the .desktop file means).
# Part B checks the text of one entry. Part C pins the committed list (backends/ubuntu/chroot/start-links.txt): the links a
# new user must find, that every URL is on a Companion-owned host, and that the dock list and this list agree. Part D runs
# backends/ubuntu/chroot/payload/start/usr/libexec/ci-os/welcome-once with a stub curl and a stub xdg-open: never in a live
# session, never twice, never without a network.
#
# The URLs were fetched on 2026-10-19 and answered 200 (that is a manual check, not part of this test: it needs a network).
# Needs bash and sh. No network, no root. bash 3.2 safe.
#   backends/ubuntu/lib/tests/start-links.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../start-links.sh"
LIST="$HERE/../../chroot/start-links.txt"
DOCK="$HERE/../../chroot/dock-favorites.txt"
WELCOME="$HERE/../../chroot/payload/start/usr/libexec/ci-os/welcome-once"
AUTOSTART="$HERE/../../chroot/payload/start/etc/xdg/autostart/ci-os-welcome.desktop"
for f in "$LIB" "$LIST" "$DOCK" "$WELCOME" "$AUTOSTART"; do [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }; done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/links-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=../start-links.sh
source "$LIB"
set +e +u

GOOD='companion-docs|Companion Docs|https://docs.ci.computer|Guides and reference|accessories-dictionary|yes'

# refused LABEL CONTENT: non-zero status, a message on stderr, nothing on stdout.
refused() {
  local label="$1" f="$TMP/refused.txt" out err rc
  printf '%s' "$2" >"$f"
  out="$(start_links_rows "$f" 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"
  if [[ $rc -ne 0 && -n "$err" && -z "$out" ]]; then pass "refused: $label"; else fail "not refused: $label (rc=$rc out='$out' err='$err')"; fi
}

echo "== Part A: the reader"
printf '# a comment\n\n%s\ncompanion-two|Two|https://ci.computer/support|Second|help-browser|no\n' "$GOOD" >"$TMP/ok.txt"
eq "comments and blank lines are skipped, rows kept in order" "$(start_links_rows "$TMP/ok.txt" | cut -d'|' -f1 | tr '\n' ' ')" "companion-docs companion-two "
eq "a row comes back unchanged" "$(start_links_rows "$TMP/ok.txt" | head -n 1)" "$GOOD"
printf '%s\r\n' "$GOOD" >"$TMP/crlf.txt"
eq "a CRLF list reads the same as an LF one" "$(start_links_rows "$TMP/crlf.txt")" "$GOOD"
printf '%s' "$GOOD" >"$TMP/nonl.txt"
eq "a last line without a newline is read" "$(start_links_rows "$TMP/nonl.txt")" "$GOOD"

refused "five fields" 'companion-docs|Companion Docs|https://docs.ci.computer|Guides|accessories-dictionary
'
refused "seven fields" 'companion-docs|Companion Docs|https://docs.ci.computer|Guides|accessories-dictionary|yes|extra
'
refused "an id without the companion- prefix" 'docs|Companion Docs|https://docs.ci.computer|Guides|accessories-dictionary|yes
'
refused "an upper-case id" 'companion-Docs|Companion Docs|https://docs.ci.computer|Guides|accessories-dictionary|yes
'
refused "an id with a slash (a path)" 'companion-../x|Companion Docs|https://docs.ci.computer|Guides|accessories-dictionary|yes
'
for rid in companion-capture companion-hub ci-os-hub ci-os-auto-install; do
  refused "reserved id $rid" "$rid|Name|https://docs.ci.computer|Guides|accessories-dictionary|yes
"
done
refused "the same id twice" "$GOOD
$GOOD
"
refused "http instead of https" 'companion-docs|Companion Docs|http://docs.ci.computer|Guides|accessories-dictionary|yes
'
refused "a URL with a query" 'companion-docs|Companion Docs|https://docs.ci.computer/a?b=c|Guides|accessories-dictionary|yes
'
refused "a URL with a fragment" 'companion-docs|Companion Docs|https://docs.ci.computer/a#b|Guides|accessories-dictionary|yes
'
refused "a URL with credentials" 'companion-docs|Companion Docs|https://user@docs.ci.computer|Guides|accessories-dictionary|yes
'
refused "a URL with a port" 'companion-docs|Companion Docs|https://docs.ci.computer:8443|Guides|accessories-dictionary|yes
'
refused "a URL with a shell metacharacter" 'companion-docs|Companion Docs|https://docs.ci.computer/a;b|Guides|accessories-dictionary|yes
'
refused "a URL with a dollar sign" 'companion-docs|Companion Docs|https://docs.ci.computer/$x|Guides|accessories-dictionary|yes
'
refused "a URL with a space" 'companion-docs|Companion Docs|https://docs.ci.computer/a b|Guides|accessories-dictionary|yes
'
refused "a host with no top-level domain" 'companion-docs|Companion Docs|https://localhost|Guides|accessories-dictionary|yes
'
refused "a name with a quote" "companion-docs|Companion's Docs|https://docs.ci.computer|Guides|accessories-dictionary|yes
"
refused "a name with an ampersand" 'companion-docs|Docs & Help|https://docs.ci.computer|Guides|accessories-dictionary|yes
'
refused "a name with angle brackets" 'companion-docs|<b>Docs</b>|https://docs.ci.computer|Guides|accessories-dictionary|yes
'
refused "a comment with a percent sign (a desktop-entry field code)" 'companion-docs|Companion Docs|https://docs.ci.computer|100% Guides|accessories-dictionary|yes
'
refused "an empty name" 'companion-docs||https://docs.ci.computer|Guides|accessories-dictionary|yes
'
refused "an icon with a path" 'companion-docs|Companion Docs|https://docs.ci.computer|Guides|/usr/share/x|yes
'
refused "desktop value other than yes or no" 'companion-docs|Companion Docs|https://docs.ci.computer|Guides|accessories-dictionary|maybe
'
refused "an empty list" ""
refused "only comments and blank lines" "# nothing

"
if start_links_rows "$TMP/does-not-exist" >/dev/null 2>"$TMP/err"; then fail "a missing file was accepted"; else pass "refused: a missing file"; fi
refused "one bad row after good ones prints none of them" "$GOOD
companion-bad|Bad|http://x.example.com|C|help-browser|yes
"

echo
echo "== Part B: one entry"
entry="$(start_links_entry "Companion Docs" "https://docs.ci.computer" "Guides" "accessories-dictionary")"
eq "the entry is exactly the keys the image relies on" "$(printf '%s\n' "$entry" | cut -d= -f1 | tr '\n' ' ')" "[Desktop Entry] Type Name Comment Exec Icon Terminal Categories StartupNotify X-CI-OS-Link "
eq "it opens the URL with xdg-open, unquoted (the reader's alphabet needs none)" "$(printf '%s\n' "$entry" | grep '^Exec=')" "Exec=xdg-open https://docs.ci.computer"
eq "it is an application, not a terminal program" "$(printf '%s\n' "$entry" | grep -c -E '^(Type=Application|Terminal=false)$')" "2"

echo
echo "== Part C: the committed list"
rows="$(start_links_rows "$LIST")"; rc=$?
eq "the committed list is accepted by the reader" "$rc" "0"
ids="$(printf '%s\n' "$rows" | cut -d'|' -f1)"
for want in companion-docs companion-getting-started companion-app-store companion-support companion-community; do
  if grep -qx "$want" <<<"$ids"; then pass "list holds $want"; else fail "list is missing $want"; fi
done
eq "the desktop gets at least the five links a new user needs" "$(printf '%s\n' "$rows" | grep -c '|yes$' | tr -d ' ')" "5"
bad_host=0
while IFS='|' read -r id _name url _c _i _d; do
  host="${url#https://}"; host="${host%%/*}"
  case "$host" in
    docs.ci.computer | hub.ci.computer | ci.computer | discord.com) ;;
    *) bad_host=1; fail "$id: $host is not a host the Companion site itself links to" ;;
  esac
  [[ "$host" == discord.com && "$url" != "https://discord.com/invite/yQp9hwpzAa" ]] && { bad_host=1; fail "$id: the Discord link is not the invite ci.computer shows"; }
done <<<"$rows"
[[ $bad_host -eq 0 ]] && pass "every URL is on a host the ci.computer site itself links to (and the Discord one is its invite)"
# the dock may pin a link by id: it must exist in this list (Capture and Hub are apps, owned elsewhere)
dock_bad=""
while IFS= read -r line; do
  case "$line" in '' | '#'*) continue ;; esac
  case "$line" in
    companion-capture.desktop) ;;
    companion-*.desktop) grep -qx "${line%.desktop}" <<<"$ids" || dock_bad="$dock_bad $line" ;;
  esac
done <"$DOCK"
eq "every companion-* entry the dock pins is a link in this list (or Capture)" "${dock_bad:-none}" "none"

echo
echo "== Part D: the first-login welcome"
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/apps"
cat >"$BIN/curl" <<'EOF'
#!/bin/sh
exit "${STUB_CURL_RC:-0}"
EOF
cat >"$BIN/xdg-open" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_OPEN_LOG:?}"
EOF
# xdg-mime names the default https handler; "none" answers with nothing, like a system with no handler set
cat >"$BIN/xdg-mime" <<'EOF'
#!/bin/sh
[ "${STUB_MIME:-firefox_firefox.desktop}" = none ] || printf '%s\n' "${STUB_MIME:-firefox_firefox.desktop}"
EOF
# a sleep that records itself and, when asked, makes the browser "appear" (the snap seeding finishing)
cat >"$BIN/sleep" <<'EOF'
#!/bin/sh
printf 's\n' >> "${STUB_SLEEP_LOG:?}"
[ -n "${STUB_APPEAR_AFTER:-}" ] && [ "$(grep -c . "$STUB_SLEEP_LOG")" -ge "$STUB_APPEAR_AFTER" ] && : > "$STUB_APPDIR/firefox_firefox.desktop"
exit 0
EOF
chmod +x "$BIN"/*
: > "$TMP/apps/firefox_firefox.desktop"
run_welcome() { # CURL_RC LIVE_PATH [extra env assignments...] -> runs with the stamp under $TMP/w
  local rc="$1" livep="$2"; shift 2
  : > "$TMP/open.log"; : > "$TMP/sleep.log"
  env PATH="$BIN:$PATH" STUB_CURL_RC="$rc" STUB_OPEN_LOG="$TMP/open.log" STUB_SLEEP_LOG="$TMP/sleep.log" STUB_APPDIR="$TMP/apps" \
    CI_OS_WELCOME_STAMP="$TMP/w/stamp" CI_OS_WELCOME_LIVE="$livep" CI_OS_WELCOME_APPDIRS="$TMP/apps" CI_OS_WELCOME_TRIES=3 \
    CI_OS_WELCOME_URL="https://docs.ci.computer/docs/getting-started" "$@" sh "$WELCOME"
}
opens() { grep -c . "$TMP/open.log" | tr -d ' '; }
sleeps() { grep -c . "$TMP/sleep.log" | tr -d ' '; }
stamp_state() { test -e "$TMP/w/stamp" && echo yes || echo no; }
rm -rf "$TMP/w"; mkdir -p "$TMP/w"; touch "$TMP/w/live-marker"
run_welcome 0 "$TMP/w/live-marker"
eq "in a live session it opens nothing" "$(opens)" "0"
eq "  and does not wait" "$(sleeps)" "0"
eq "  and leaves no stamp (the installed system must still show it)" "$(stamp_state)" "no"
rm -rf "$TMP/w"; mkdir -p "$TMP/w"
run_welcome 6 "$TMP/w/no-live-marker"
eq "with no network it waits, gives up after the tries, and opens nothing" "$(opens)/$(sleeps)" "0/2"
eq "  and leaves no stamp, so the next login tries again" "$(stamp_state)" "no"
run_welcome 0 "$TMP/w/no-live-marker" STUB_MIME=none
eq "with no default browser it waits, gives up, and opens nothing" "$(opens)/$(sleeps)" "0/2"
eq "  and leaves no stamp" "$(stamp_state)" "no"
run_welcome 0 "$TMP/w/no-live-marker" STUB_MIME=missing_browser.desktop
eq "a default browser whose desktop file is not installed yet (snap still seeding) does not count" "$(opens)/$(sleeps)" "0/2"
rm -f "$TMP/apps/firefox_firefox.desktop"
run_welcome 0 "$TMP/w/no-live-marker" STUB_APPEAR_AFTER=1
eq "when the browser appears while it waits, it opens the page then" "$(cat "$TMP/open.log")" "https://docs.ci.computer/docs/getting-started"
eq "  after one wait" "$(sleeps)" "1"
eq "  and writes the stamp" "$(stamp_state)" "yes"
run_welcome 0 "$TMP/w/no-live-marker"
eq "the next login opens nothing and does not wait" "$(opens)/$(sleeps)" "0/0"
rm -f "$TMP/w/stamp"
run_welcome 0 "$TMP/w/no-live-marker"
eq "online with a browser, at once: it opens the page without waiting" "$(opens)/$(sleeps)" "1/0"
rm -f "$TMP/w/stamp"
: > "$TMP/open.log"
if env CI_OS_WELCOME_STAMP="/proc/none/x/stamp" PATH="$BIN:$PATH" STUB_OPEN_LOG="$TMP/open.log" STUB_SLEEP_LOG="$TMP/sleep.log" CI_OS_WELCOME_APPDIRS="$TMP/apps" \
     CI_OS_WELCOME_LIVE="$TMP/w/no-live-marker" CI_OS_WELCOME_URL="https://docs.ci.computer" sh "$WELCOME"; then pass "an unwritable stamp location ends quietly (exit 0)"; else fail "an unwritable stamp location made the script fail"; fi
eq "  and opens nothing, so a broken home cannot make it open on every login" "$(opens)" "0"
eq "the script checks reachability over https only" "$(grep -c -F -- "--proto '=https'" "$WELCOME")" "1"
eq "the autostart entry runs the script, hidden, for GNOME only" "$(grep -c -E '^(Exec=/usr/libexec/ci-os/welcome-once|NoDisplay=true|OnlyShowIn=GNOME;)$' "$AUTOSTART")" "3"

echo
echo "== Part E: trusting the desktop shortcuts (first login, installed system only)"
cat >"$BIN/gio" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_GIO_LOG:?}"
EOF
chmod +x "$BIN/gio"
SYS="$TMP/sysapps"; DESK="$TMP/Desktop"; rm -rf "$SYS" "$DESK" "$TMP/w"; mkdir -p "$SYS" "$DESK" "$TMP/w"
start_links_entry "Companion Docs" https://docs.ci.computer "Guides" accessories-dictionary > "$SYS/companion-docs.desktop"
start_links_entry "Companion Support" https://ci.computer/support "Help" system-help > "$SYS/companion-support.desktop"
cp "$SYS/companion-docs.desktop" "$DESK/companion-docs.desktop"                       # identical to the system copy
cp "$SYS/companion-support.desktop" "$DESK/companion-support.desktop"
printf 'Exec=evil\n' >> "$DESK/companion-support.desktop"                             # edited by the user
printf '[Desktop Entry]\nName=Other\n' > "$DESK/other.desktop"                       # not ours
run_trust() { # LIVE_PATH
  : > "$TMP/gio.log"; : > "$TMP/open.log"; : > "$TMP/sleep.log"
  env PATH="$BIN:$PATH" STUB_CURL_RC=0 STUB_OPEN_LOG="$TMP/open.log" STUB_SLEEP_LOG="$TMP/sleep.log" STUB_GIO_LOG="$TMP/gio.log" STUB_APPDIR="$TMP/apps" \
    CI_OS_WELCOME_STAMP="$TMP/w/stamp" CI_OS_WELCOME_LIVE="$1" CI_OS_WELCOME_APPDIRS="$TMP/apps" CI_OS_WELCOME_TRIES=1 \
    CI_OS_WELCOME_DESKTOP="$DESK" CI_OS_WELCOME_SYSAPPS="$SYS" CI_OS_WELCOME_URL="https://docs.ci.computer" sh "$WELCOME"
}
: > "$TMP/apps/firefox_firefox.desktop"
touch "$TMP/w/live-marker"; run_trust "$TMP/w/live-marker"
eq "in a live session the unchanged shortcut is marked trusted too (an untrusted one shows as a red cross and a file name)" "$(cat "$TMP/gio.log")" "set $DESK/companion-docs.desktop metadata::trusted true"
eq "  but the page is not opened there" "$(grep -c . "$TMP/open.log" | tr -d ' ')" "0"
rm -f "$TMP/w/desktop-trusted"
run_trust "$TMP/w/no-live-marker"
eq "on an installed system the unchanged shortcut is marked trusted" "$(cat "$TMP/gio.log")" "set $DESK/companion-docs.desktop metadata::trusted true"
eq "  the edited one and the foreign file are not" "$(grep -c -E 'support|other' "$TMP/gio.log" | tr -d ' ')" "0"
eq "  and the stamp is written" "$(test -e "$TMP/w/desktop-trusted" && echo yes || echo no)" "yes"
rm -f "$TMP/w/stamp"; run_trust "$TMP/w/no-live-marker"
eq "the next login does not mark anything again" "$(grep -c . "$TMP/gio.log" | tr -d ' ')" "0"
rm -f "$TMP/w/desktop-trusted" "$TMP/w/stamp"
printf '#!/bin/sh\nexit 1\n' > "$BIN/gio"
run_trust "$TMP/w/no-live-marker"
eq "a gio that fails does not stop the page from opening" "$(opens)" "1"

echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
