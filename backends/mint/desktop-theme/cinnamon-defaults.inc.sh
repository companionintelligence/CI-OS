#!/usr/bin/env bash
# Single source for Cinnamon defaults (dconf + live gsettings + slick-greeter),
# the Mint analog of backends/_mixins/gnome-dconf/gnome-defaults.inc.sh. Not
# placed under backends/_mixins/ and not sourcing that file: the brief for this
# backend is explicit that the GNOME mixin is GNOME-Shell-specific and must not
# be reused by Mint, so the handful of canon-token-derived values every
# Cinnamon-theming script needs (colors, theme name, panel/favorites defaults)
# are re-derived here instead of shared with GNOME.
# shellcheck shell=bash

# CI color scheme — same derivation as gnome-defaults.inc.sh's
# CI_THEME_PRIMARY_HEX/CI_THEME_SECONDARY_HEX (duplicated, not sourced, per the
# no-gnome-mixin-reuse rule above): the brand primary (phthalo) from the canon
# tokens for the background's first stop, and the darker phthalo variant the
# canon reserves for gradient/depth use as the second stop.
export CI_THEME_PRIMARY_HEX="${CI_LIGHT_PRIMARY#\#}"
export CI_THEME_SECONDARY_HEX="${CI_ACCENT_PHTHALO_DEEP#\#}"

# Cinnamon/Mint-Y theme selection. Package names per the Mint packaging
# research: base "Mint-Y", dark variant "Mint-Y-Dark", accent+dark combined as
# "Mint-Y-Dark-<Accent>". Accent-name existence wasn't independently verified
# against a live package listing (see docs/architecture/multi-distro-design.md
# / this backend's implementation notes) — prefer an accent close to the CI
# teal/phthalo primary, falling back through progressively safer bets down to
# the plain dark theme every Mint install ships.
ci_select_cinnamon_gtk_theme() {
  if [[ -d /usr/share/themes/Mint-Y-Dark-Aqua ]]; then
    echo "Mint-Y-Dark-Aqua"
  elif [[ -d /usr/share/themes/Mint-Y-Dark-Teal ]]; then
    echo "Mint-Y-Dark-Teal"
  else
    echo "Mint-Y-Dark"
  fi
}

# Icon theme: unlike Yaru (which ships one theme with light/dark handled by
# GTK), mint-y-icons ships separate base/dark packages. Prefer the dark
# variant when present, otherwise the base theme every Mint install has.
ci_select_cinnamon_icon_theme() {
  if [[ -d /usr/share/icons/Mint-Y-Dark ]]; then
    echo "Mint-Y-Dark"
  else
    echo "Mint-Y"
  fi
}

# Deliberately no ci_select_cinnamon_cursor_theme(): Yaru bundles its own
# cursor theme so Ubuntu's mixin can force "Yaru" unconditionally, but Mint
# does not ship a "Mint-Y" cursor theme (its stock cursor themes are
# DMZ-White/DMZ-Black or Bibata, unrelated to the CI brand). Forcing a
# fabricated cursor-theme name would silently fail to apply, so cursor-theme
# is left at the distro default everywhere in this backend.

# Wallpaper: same $ASSET_INPUTS_DIR/background.png input Ubuntu's
# 30-wallpaper.sh installs, just resolved from wherever this backend ends up
# installing it (20-cinnamon-dconf.sh, since Mint has no separate wallpaper
# step — see that file's header comment).
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

# Favorites (org/cinnamon favorite-apps): mirrors Ubuntu's favorite-apps list,
# swapped to Cinnamon-native equivalents — Nemo (Cinnamon's default file
# manager) instead of Nautilus, cinnamon-settings.desktop instead of GNOME
# Settings. GNOME Terminal keeps its upstream .desktop id (org.gnome.Terminal)
# since Mint Cinnamon ships the same GNOME Terminal package Ubuntu does
# (confirmed in this backend's implementation research). Chromium is
# deliberately NOT included here: Ubuntu's mixin uses the snap desktop-file id
# "chromium_chromium.desktop", but Mint pins out snapd by default (see
# backends/mint/provision/provision.sh's header note), so that id would
# resolve to nothing. Chromium is extended-tier in
# provision.sh anyway (not installed by default) and no verified Mint-native
# Chromium .desktop id was found — pin it manually if you install one.
export CI_FAVORITE_APPS="['nemo.desktop', 'org.gnome.Terminal.desktop', 'code.desktop', 'steam.desktop', 'cinnamon-settings.desktop']"

# Panel: Cinnamon has no dash-to-dock analog — panels are first-class,
# addressed as "panelId:monitorIndex:position" list entries under the plain
# org/cinnamon schema (not org/cinnamon/desktop/...). A fresh Mint Cinnamon
# install ships exactly one panel, id 1, at the bottom. Rather than relocate
# it to a left-side dock (a much bigger behavioral change than "small" scope
# for a first Mint pass, and not requested), this backend only applies the
# same autohide *policy* Ubuntu's dock gets, to the stock panel in its stock
# position. These are dconf DEFAULTS, not forced values — like the Ubuntu
# dock settings, they only take effect for a user who has never touched their
# own panel settings, so this can't clobber someone else's panel layout.
export CI_CINNAMON_PANEL_ID="1"
export CI_CINNAMON_PANELS_AUTOHIDE="['${CI_CINNAMON_PANEL_ID}:true']"
