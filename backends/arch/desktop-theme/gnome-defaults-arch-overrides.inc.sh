#!/usr/bin/env bash
# Arch-specific companion to backends/_mixins/gnome-dconf/gnome-defaults.inc.sh
# (sourced, not executed alone). Deliberately a near-duplicate of
# backends/fedora/desktop-theme/gnome-defaults-fedora-overrides.inc.sh, not a
# shared file — see backends/arch/desktop-theme/28-gdm-accent-branding.sh's
# header for why "source an override file after the mixin" doesn't work
# (20-dconf-system.sh/25-session-gsettings.sh unconditionally re-source their
# own gnome-defaults.inc.sh internally, silently redefining any function a
# caller tried to override beforehand) and what this file is used for
# instead.
#
# Why this exists: backends/_mixins/gnome-dconf/gnome-defaults.inc.sh's
# ci_select_gtk_theme() is hardcoded to Yaru-* theme-directory names, and
# 20-dconf-system.sh separately hardcodes icon-theme='Yaru' / cursor-theme='Yaru'
# as bare literals in its dconf heredoc. None of those exist on Arch, which
# ships stock upstream GNOME (Adwaita) with no Yaru packages, official or AUR.
# shellcheck shell=bash

# Arch has no CI-branded GTK theme variant in this repo (same situation as
# Fedora — see that file's header). Stock Adwaita is the correct,
# present-on-every-GNOME-install choice, echoed explicitly rather than left
# unset so callers and the validator have a concrete value to check.
ci_select_gtk_theme() {
  echo "Adwaita"
}

ci_select_icon_theme() {
  echo "Adwaita"
}

ci_select_cursor_theme() {
  echo "Adwaita"
}

# Research for this backend (see docs/architecture/multi-distro-design.md)
# confirmed the same finding Fedora's research made: Arch's `gnome-shell`
# package (extra/x86_64/gnome-shell) compiles its theme directly into
# gnome-shell-theme.gresource with no separate, add-alongside theme package
# the way Ubuntu's Yaru is one — this is upstream GNOME's own packaging
# shape since GNOME 3.16 (the gresource lives at
# data/gnome-shell-theme.gresource.xml in the gnome-shell source tree
# itself), not something either distro's packagers changed, so it was
# expected to hold for Arch too and did. Arch tracks upstream GNOME closely
# (arguably closer than Fedora, which carries some Red Hat-specific
# patches), so GNOME 47+'s org.gnome.desktop.interface accent-color enum —
# the same supported mechanism Fedora uses — is the mechanism here too. See
# 28-gdm-accent-branding.sh's header for the full reasoning and the fix for
# the mixin's own hardcoded-Yaru values.
#
# CI's brand primary is #0a6358 (light) / #c5e8dc (dark) — called
# "teal/phthalo" throughout this repo (see Fedora's identical override file
# for the RGB-distance-vs-naming-consistency tradeoff this judgment call
# involves). "teal" is picked here for the same cross-backend naming
# consistency reason, not re-litigated per backend.
ci_select_accent_color() {
  echo "teal"
}

# CI-OS is themed dark everywhere else (see Fedora's identical override file
# for the enumeration) — GNOME's supported dark-mode toggle since 42 is this
# key, not a theme-name swap.
ci_select_color_scheme() {
  echo "prefer-dark"
}
