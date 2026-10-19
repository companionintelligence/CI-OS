#!/usr/bin/env bash
# The member names of a .deb, normalised. Sourced by customize-chroot.sh (Step 10e checks what a downloaded .deb ships before it is
# installed). Needs dpkg-deb.
#
# Why: `dpkg-deb -c` prints the names as the package stores them, and packages differ. The Companion Hub .deb stores "./usr/bin/x",
# the Companion Capture .deb stores "usr/bin/x". A check written for one style never matches the other, and a refusal check
# ("nothing under /etc or systemd") that never matches passes silently. Both styles come out the same here.
# shellcheck shell=bash

# deb_members FILE: the names in the data archive, one per line, without a leading "./" and without a symlink target. The root
# entry ("./") comes out as an empty line, which no check should match. Status 1 when dpkg-deb cannot list the file.
deb_members() {
  local listing
  listing="$(dpkg-deb -c "$1")" || return 1
  printf '%s\n' "$listing" | sed -E -e 's/^[^ ]+ +[^ ]+ +[0-9]+ +[0-9-]+ +[0-9:]+ +//' -e 's/ -> .*$//' -e 's|^\./||'
}
