#!/usr/bin/env bash
# ci_grub_merge_key <default-grub-file> <KEY> <value>
#
# Sets KEY="value" in a /etc/default/grub-format file, replacing an existing
# line for that key or appending one if it's absent. Never touches any other
# key — used instead of a full-file overwrite so branding steps (GRUB theme)
# can't clobber unrelated distro-specific settings (kernel cmdline params,
# etc.) a user or the installer has already set.
#
# Shared between the post-install re-skin path (backends/ubuntu/desktop-theme/
# 15-grub-theme.sh, operating on the live /etc/default/grub) and the ISO
# chroot build path (backends/ubuntu/chroot/customize-chroot.sh, operating on
# $CHROOT_PATH/etc/default/grub from outside the chroot) — same logic, two
# different files, kept in one place instead of drifting into two copies.
# shellcheck shell=bash

ci_grub_merge_key() {
  local file="$1" key="$2" value="$3"
  if [[ ! -f "$file" ]]; then
    echo "Error: $file does not exist" >&2
    return 1
  fi
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
  else
    echo "${key}=\"${value}\"" >> "$file"
  fi
}

# ci_grub_nearest_color <#rrggbb>
#
# Prints the name of the GRUB terminal colour nearest to a hex colour, by squared RGB distance (a tie
# goes to the earlier row). menu_color_normal and menu_color_highlight take only names from GRUB's
# fixed 16-colour VGA table, never hex, so a menu that follows the brand tokens has to be derived:
#   menu_color_normal=$(ci_grub_nearest_color "$CI_DARK_FOREGROUND")/black
#   menu_color_highlight=black/$(ci_grub_nearest_color "$CI_ACCENT_AQUA")
# The names are color_list in grub-core/normal/color.c and the RGB values are the palette gfxterm
# paints (grub_video_fbstd_colors in grub-core/video/fb/video_fb.c), both from GRUB 2.12.
# Pure bash 3.2: no associative arrays, no external commands.
ci_grub_nearest_color() {
  local hex="${1:-}" r g b best="" best_d=-1 d name cr cg cb
  hex="${hex#\#}"
  if [[ ! "$hex" =~ ^[0-9a-fA-F]{6}$ ]]; then
    echo "Error: not a #rrggbb colour: ${1:-}" >&2
    return 1
  fi
  r=$((16#${hex:0:2})); g=$((16#${hex:2:2})); b=$((16#${hex:4:2}))
  while read -r name cr cg cb; do
    d=$(( (r - cr) * (r - cr) + (g - cg) * (g - cg) + (b - cb) * (b - cb) ))
    if (( best_d < 0 || d < best_d )); then best="$name"; best_d=$d; fi
  done <<'GRUB_COLORS'
black 0 0 0
blue 0 0 168
green 0 168 0
cyan 0 168 168
red 168 0 0
magenta 168 0 168
brown 168 84 0
light-gray 168 168 168
dark-gray 84 84 84
light-blue 84 84 254
light-green 84 254 84
light-cyan 84 254 254
light-red 254 84 84
light-magenta 254 84 254
yellow 254 254 84
white 254 254 254
GRUB_COLORS
  echo "$best"
}
