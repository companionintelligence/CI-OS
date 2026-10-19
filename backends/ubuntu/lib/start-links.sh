#!/usr/bin/env bash
# The Companion links of the Ubuntu edition, read from one list: backends/ubuntu/chroot/start-links.txt.
# Sourced by customize-chroot.sh (writes the application-menu entries and the new-user desktop shortcuts from it) and by
# verify-iso.sh (checks the built image against the same list).
#
# Why a strict reader: a name, comment or URL ends up in a .desktop file that GNOME runs (Exec=) or shows, so the accepted
# alphabets are small and a line that does not fit is refused, not repaired. An id may not take the place of an app that
# another part of the image owns (Companion Hub, Capture, the installer).
# bash 3.2 safe.
# shellcheck shell=bash

# ids owned elsewhere: dock-favorites.txt and the Hub/Capture packages use these desktop-file names
START_LINKS_RESERVED_IDS="companion-capture companion-hub ci-os-hub ci-os-auto-install"

# start_links_rows FILE: print the rows as "id|name|url|comment|icon|desktop", in order, one per line. Blank lines and lines
# starting with # are skipped. Status 1 with a message on stderr and nothing on stdout for a missing file, a row that is not
# six fields, an id or icon outside [a-z0-9-], a name or comment outside printable ASCII without | and quotes of either kind,
# a URL that is not plain https (no query, fragment, credentials or port), an unknown desktop value, a reserved or repeated id,
# or a list with no row. All or nothing.
start_links_rows() {
  local file="$1" line n=0 out="" seen=$'\n' lineno=0
  local id name url comment icon desktop extra
  local re_id='^companion-[a-z0-9]+(-[a-z0-9]+)*$' re_icon='^[a-z0-9]+(-[a-z0-9]+)*$'
  local re_text='^[A-Za-z0-9][A-Za-z0-9 .,:()/+-]*$'
  local re_url='^https://[a-z0-9]+([.-][a-z0-9]+)*\.[a-z]{2,}(/[A-Za-z0-9._~%/-]*)?$'
  if [[ ! -f "$file" ]]; then
    echo "start links list not found: $file" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    case "$line" in '' | '#'*) continue ;; esac
    IFS='|' read -r id name url comment icon desktop extra <<<"$line"
    if [[ -n "$extra" ]] || [[ -z "$desktop" ]] || [[ "$line" != *'|'*'|'*'|'*'|'*'|'* ]]; then
      echo "start links list $file:$lineno: expected 6 fields (id|name|url|comment|icon|desktop)" >&2
      return 1
    fi
    [[ "$id" =~ $re_id ]] || { echo "start links list $file:$lineno: bad id '$id' (companion-<words>, lower case)" >&2; return 1; }
    case " $START_LINKS_RESERVED_IDS " in *" $id "*) echo "start links list $file:$lineno: '$id' belongs to another part of the image" >&2; return 1 ;; esac
    case "$seen" in *$'\n'"$id"$'\n'*) echo "start links list $file:$lineno: id listed twice: $id" >&2; return 1 ;; esac
    [[ "$name" =~ $re_text ]] || { echo "start links list $file:$lineno: bad name '$name'" >&2; return 1; }
    [[ "$comment" =~ $re_text ]] || { echo "start links list $file:$lineno: bad comment '$comment'" >&2; return 1; }
    [[ "$url" =~ $re_url ]] || { echo "start links list $file:$lineno: not a plain https URL: $url" >&2; return 1; }
    [[ "$icon" =~ $re_icon ]] || { echo "start links list $file:$lineno: bad icon '$icon'" >&2; return 1; }
    case "$desktop" in yes | no) ;; *) echo "start links list $file:$lineno: desktop must be yes or no, not '$desktop'" >&2; return 1 ;; esac
    seen="$seen$id"$'\n'
    n=$((n + 1))
    out="$out$id|$name|$url|$comment|$icon|$desktop"$'\n'
  done <"$file"
  if [[ "$n" -eq 0 ]]; then
    echo "start links list $file: no link in it" >&2
    return 1
  fi
  printf '%s' "$out"
}

# start_links_entry NAME URL COMMENT ICON: the text of the .desktop file for one link. It opens the URL in the user's default
# browser through xdg-open; the URL passed the reader's alphabet, so it needs no quoting.
start_links_entry() {
  printf '[Desktop Entry]\nType=Application\nName=%s\nComment=%s\nExec=xdg-open %s\nIcon=%s\nTerminal=false\nCategories=Network;\nStartupNotify=false\nX-CI-OS-Link=true\n' "$1" "$3" "$2" "$4"
}
