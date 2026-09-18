#!/usr/bin/env bash
# Fedora-specific companion to backends/_mixins/gnome-dconf/gnome-defaults.inc.sh
# (sourced, not executed alone). Not placed under backends/_mixins/ and not
# edited into that file — see the header of
# backends/fedora/desktop-theme/28-gdm-accent-branding.sh for why this can't
# just be "sourced after the mixin to override one function" the way the
# brief for this backend first suggested, and what this file is used for
# instead.
#
# Why this exists: backends/_mixins/gnome-dconf/gnome-defaults.inc.sh's
# ci_select_gtk_theme() is hardcoded to Yaru-* theme-directory names
# (Yaru-prussiangreen-dark / Yaru-sage-dark / Yaru-viridian-dark / Yaru-dark),
# and backends/_mixins/gnome-dconf/20-dconf-system.sh separately hardcodes
# icon-theme='Yaru' / cursor-theme='Yaru' as bare literals in its dconf
# heredoc (not even routed through a function). None of those exist on
# Fedora Workstation, which is Adwaita-based and ships no Yaru packages.
# shellcheck shell=bash

# Fedora has no CI-branded GTK theme variant in this repo (unlike Yaru's
# accent-colored variants Ubuntu ships/rebrands). Stock Adwaita is the
# correct, present-on-every-install choice — echoed explicitly (rather than
# left unset) so callers and the validator have a concrete value to check.
ci_select_gtk_theme() {
  echo "Adwaita"
}

ci_select_icon_theme() {
  echo "Adwaita"
}

ci_select_cursor_theme() {
  echo "Adwaita"
}

# GNOME 47+ (current on any Fedora release this backend targets in 2026)
# exposes org.gnome.desktop.interface accent-color: a LOCKED enum of nine
# named colors (blue [default] / teal / green / yellow / orange / red /
# pink / purple / slate) that Shell CSS and libadwaita apps derive their
# accent styling from — see this backend's GDM/GNOME-Shell research (in the
# implementation report) for why this, not a gresource recolor, is the
# mechanism used for Fedora.
#
# CI's brand primary is #0a6358 (light) / #c5e8dc (dark) — the codebase's
# own comments consistently call this "teal/phthalo" (e.g.
# backends/mint/desktop-theme/cinnamon-defaults.inc.sh: "prefer an accent
# close to the CI teal/phthalo primary"; backends/_mixins/gnome-dconf/
# 27-terminal-theme.sh's "CI-OS Blue Teal" terminal profile). A raw RGB
# distance from #0a6358 to libadwaita's two closest named swatches (teal
# #2190a4, green #3a944a) is numerically slightly closer to "green"
# (~4900 vs ~8300 squared distance) — but "teal" is the name this brand
# uses for itself everywhere else in this repo, so teal is picked here for
# cross-backend naming consistency over a marginal RGB-distance tiebreak.
# This is a judgment call, not a verified design decision — flagged as such
# in the implementation report.
ci_select_accent_color() {
  echo "teal"
}

# CI-OS is themed dark everywhere else (Yaru-*-dark on Ubuntu, Mint-Y-Dark on
# Mint, the dark Plymouth/GRUB palette shared by every backend) — GNOME's
# supported dark-mode toggle since 42 is this key, not a theme-name swap.
ci_select_color_scheme() {
  echo "prefer-dark"
}
