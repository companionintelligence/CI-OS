#!/usr/bin/env bash
# The Ubuntu display names that are still on screen after the other steps and are safe to rename: the session
# picker, the Settings sidebar entry and the names of the shell extensions.
#
# GDM's gear menu lists a session by the Name= of its file in /usr/share/wayland-sessions ("Ubuntu"), with Comment=
# under it. Ubuntu 26.04 ships exactly one: wayland-sessions/ubuntu.desktop. There is no /usr/share/xsessions, no
# ubuntu-xorg.desktop, no ubuntu-wayland.desktop and no Xorg server (read from the 26.04.1 desktop image), so there is
# only one entry to rename and no "on Xorg" / "on Wayland" variants. gnome-control-center labels its sidebar entries from
# the panels' own .desktop files: gnome-ubuntu-panel.desktop ("Ubuntu Desktop", NoDisplay, so it is no launcher but
# still the sidebar label). The Extensions app lists the "name" of each metadata.json ("Ubuntu Dock", ...).
#
# Only those strings change, and only where they still read the stock text. What the system finds these things by is
# never touched: the file names (the session id IS the file name; GDM and AccountsService remember it), uuid, Exec=,
# TryExec=, DesktopNames=, OnlyShowIn=, X-Ubuntu-Gettext-Domain, Keywords=, the extensions' descriptions, and every
# Name[xx]=/Comment[xx]= line. software-properties-livepatch.desktop and ubuntu-advantage-notification.desktop are
# NoDisplay entries nobody sees, so they stay too.
#
# Each file is owned by a package (ubuntu-session, gnome-control-center, gnome-shell-ubuntu-extensions): ci_install_file
# diverts the stock file to <path>.ubuntu-stock first, so an upgrade of the package unpacks Ubuntu's file to the
# diverted name and ours stays. The edit is made on a copy before anything is diverted, so a file that needs no
# change (renamed already, or a stock text this step does not know) is left alone and not diverted.
#
# On a live system any of the packages may be absent (a desktop without the tiling extension) or newer than the
# stock text known here, so a file this step cannot rename is reported and the step goes on. An image build is the base
# ISO's own files, all of which verify-iso.sh requires to read Companion OS, so there the step ends by checking that every
# one of them does, and fails if one is missing or kept a name it did not recognise: a "success" that ships Ubuntu's name
# is found only after the whole build otherwise.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

# Display lines only, each anchored to the whole stock text so that nothing else can match.
SESSION_SED='s/^Name=Ubuntu$/Name=Companion OS/;s/^Comment=This session logs you into Ubuntu$/Comment=This session logs you into Companion OS/'
PANEL_SED='s/^Name=Ubuntu Desktop$/Name=Companion OS Desktop/;s/^Comment=Ubuntu Desktop Appearance Settings$/Comment=Companion OS Desktop Appearance Settings/'
EXTENSION_SED='s/^([[:space:]]*"name"[[:space:]]*:[[:space:]]*")Ubuntu /\1Companion OS /'

SESSION_FILES=(/usr/share/wayland-sessions/ubuntu.desktop)
PANEL_FILES=(/usr/share/applications/gnome-ubuntu-panel.desktop)
EXTENSION_FILES=(
  /usr/share/gnome-shell/extensions/ubuntu-dock@ubuntu.com/metadata.json
  /usr/share/gnome-shell/extensions/ubuntu-appindicators@ubuntu.com/metadata.json
  /usr/share/gnome-shell/extensions/tiling-assistant@ubuntu.com/metadata.json
)

TMP_FILES=()
cleanup() {
  if [[ ${#TMP_FILES[@]} -gt 0 ]]; then rm -f "${TMP_FILES[@]}"; fi
}
trap cleanup EXIT

RENAMED=0
KEPT=0

# rename_in <file> <sed script>
# A session file that lost its Exec= line is a login that does not start, so the result is compared with the original
# before it is installed: the only lines that may differ are Name=, Comment= and a JSON "name". The step stops if any
# other line does, which is what a pattern widened by mistake would do.
rename_in() {
  local file="$1" script="$2" tmp stray
  if [[ ! -f "$file" ]]; then
    log_warn "Not installed, nothing to rename: $file"
    return 0
  fi
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  sed -E "$script" "$file" >"$tmp"
  if cmp -s "$file" "$tmp"; then
    KEPT=$((KEPT + 1))
    log_info "No stock Ubuntu name to rename in $file"
    return 0
  fi
  stray="$(diff "$file" "$tmp" | grep -E '^[<>]' | grep -v -E '^[<>] ([[:space:]]*"name"[[:space:]]*:|Name=|Comment=)' || true)"
  if [[ -n "$stray" ]]; then
    log_error "The rename would change more than a display name in $file; not installing it:"
    echo "$stray" >&2
    exit 1
  fi
  ci_install_file "$tmp" "$file"
  RENAMED=$((RENAMED + 1))
  log_info "Renamed: $file"
}

for f in "${SESSION_FILES[@]}"; do rename_in "$f" "$SESSION_SED"; done
for f in "${PANEL_FILES[@]}"; do rename_in "$f" "$PANEL_SED"; done
for f in "${EXTENSION_FILES[@]}"; do rename_in "$f" "$EXTENSION_SED"; done

if ci_image_build; then
  UNNAMED=()
  for f in "${SESSION_FILES[@]}" "${PANEL_FILES[@]}"; do
    grep -q -E '^Name=Companion OS( |$)' "$f" 2>/dev/null || UNNAMED+=("$f")
  done
  for f in "${EXTENSION_FILES[@]}"; do
    grep -q -E '^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"Companion OS ' "$f" 2>/dev/null || UNNAMED+=("$f")
  done
  if [[ ${#UNNAMED[@]} -gt 0 ]]; then
    log_error "These do not read Companion OS after the rename (missing, or a stock text this step does not know): ${UNNAMED[*]}"
    log_error "The base ISO changed shape; review the new text before branding it."
    exit 1
  fi
fi

log_success "Companion OS display names: $RENAMED file(s) renamed, $KEPT already done or without a stock name (the session picker and the Settings entry change at the next login)"
