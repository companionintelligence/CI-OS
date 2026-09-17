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
