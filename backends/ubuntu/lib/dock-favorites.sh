#!/usr/bin/env bash
# The dock ("favourites", the left GNOME bar) of the Ubuntu edition, read from one list:
# backends/ubuntu/chroot/dock-favorites.txt. Sourced by customize-chroot.sh, which writes the dconf default from it, and by
# verify-iso.sh, which checks the built image against the same list.
#
# Why a validator: an id ends up inside a GVariant string in a dconf keyfile, so a quote, a comma or a bracket in it would
# change what the file means. Ids are desktop-file names, so the accepted alphabet is small.
# bash 3.2 safe.
# shellcheck shell=bash

# dock_favorites_ids FILE: print the desktop-file ids, one per line, in order. Comment lines (#) and blank lines are
# skipped and surrounding blanks trimmed. Status 1 with a message on stderr, and nothing on stdout, for a missing file, an
# id outside [A-Za-z0-9._ -] ending in .desktop, a duplicate, or a list with no id.
dock_favorites_ids() {
  local file="$1" line id n=0 seen=$'\n'
  local re='^[A-Za-z0-9][A-Za-z0-9._ -]*\.desktop$'
  if [[ ! -f "$file" ]]; then
    echo "dock favourites list not found: $file" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    id="${line#"${line%%[![:space:]]*}"}"
    id="${id%"${id##*[![:space:]]}"}"
    case "$id" in '' | '#'*) continue ;; esac
    if ! [[ "$id" =~ $re ]]; then
      echo "dock favourites list $file: not a desktop-file id: $id" >&2
      return 1
    fi
    case "$seen" in
      *$'\n'"$id"$'\n'*)
        echo "dock favourites list $file: listed twice: $id" >&2
        return 1
        ;;
    esac
    seen="$seen$id"$'\n'
    n=$((n + 1))
  done <"$file"
  if [[ "$n" -eq 0 ]]; then
    echo "dock favourites list $file: no desktop-file id in it" >&2
    return 1
  fi
  # All or nothing: nothing is printed unless every line was valid, so a caller that reads the output through a pipe
  # cannot act on half a list.
  printf '%s' "${seen#$'\n'}"
}

# dock_favorites_value FILE: the list as a GVariant string array, the value of org.gnome.shell favorite-apps,
# for example ['a.desktop', 'Companion Hub.desktop']. Same status rules as dock_favorites_ids.
dock_favorites_value() {
  local ids id out=""
  ids="$(dock_favorites_ids "$1")" || return 1
  while IFS= read -r id; do
    out="${out:+$out, }'$id'"
  done <<<"$ids"
  printf '[%s]\n' "$out"
}
