#!/usr/bin/env bash
# Single source for GNOME / Dash-to-Dock defaults (dconf + live gsettings).
# shellcheck shell=bash

# CI color scheme
# The brand primary (phthalo) from the canon tokens; the old literal was the logo ramp's #066c80,
# which is part of the mark artwork and retired everywhere else.
export CI_THEME_PRIMARY_HEX="${CI_LIGHT_PRIMARY#\#}"
# Deep phthalo variant for the background gradient's second stop — was a bare
# literal ("1b4332") not derived from any canon token. CI_ACCENT_PHTHALO_DEEP
# is the token this was standing in for: a darker phthalo, meant for exactly
# this kind of gradient/depth use per the canon's own naming.
export CI_THEME_SECONDARY_HEX="${CI_ACCENT_PHTHALO_DEEP#\#}"

# Dock: stay on the left like default Ubuntu, but unfixed + autohide so it
# dismisses / slides away similarly to a bottom dock that is not "always on screen".
export CI_DOCK_POSITION="LEFT"
export CI_DOCK_FIXED="false"
export CI_DOCK_AUTOHIDE="true"
export CI_DOCK_EXTEND_HEIGHT="false"
export CI_DOCK_MAX_ICON="48"

# Default browser .desktop (Chromium when installed from setup-fresh / ISO seed)
export CI_DEFAULT_BROWSER_DESKTOP="chromium_chromium.desktop"

export CI_FAVORITE_APPS="['org.gnome.Nautilus.desktop', 'chromium_chromium.desktop', 'org.gnome.Terminal.desktop', 'code.desktop', 'steam.desktop', 'org.gnome.Settings.desktop']"

ci_select_gtk_theme() {
  if [[ -d /usr/share/themes/Yaru-prussiangreen-dark ]]; then
    echo "Yaru-prussiangreen-dark"
  elif [[ -d /usr/share/themes/Yaru-sage-dark ]]; then
    echo "Yaru-sage-dark"
  elif [[ -d /usr/share/themes/Yaru-viridian-dark ]]; then
    echo "Yaru-viridian-dark"
  else
    echo "Yaru-dark"
  fi
}

ci_wallpaper_uri() {
  if [[ -f /usr/share/backgrounds/ci-os-wallpaper.png ]]; then
    echo "file:///usr/share/backgrounds/ci-os-wallpaper.png"
  elif [[ -f /usr/share/backgrounds/ci-os-wallpaper.svg ]]; then
    echo "file:///usr/share/backgrounds/ci-os-wallpaper.svg"
  elif [[ -f /usr/share/backgrounds/ci-os-wallpaper.jpg ]]; then
    echo "file:///usr/share/backgrounds/ci-os-wallpaper.jpg"
  else
    echo ""
  fi
}
