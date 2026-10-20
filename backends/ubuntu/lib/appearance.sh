#!/usr/bin/env bash
#=============================================================================
# The GNOME appearance defaults of Companion OS on Ubuntu: dark, with a green accent
#
# Sourced (never run) by customize-chroot.sh (Step 3 writes the defaults), by verify-iso.sh (section 6c reads them back from the built
# image) and by backends/ubuntu/lib/tests/appearance.sh. One place for the two values, so that the dconf default, the schema override
# and the check on the finished image cannot disagree. bash 3.2 safe.
#
# What they are:
#   org.gnome.desktop.interface color-scheme   prefer-dark   libadwaita and GTK 4 apps, the portal that Firefox and Chrome read, and
#                                                             GNOME Shell's own dark stylesheet follow it. (default | prefer-dark | prefer-light)
#   org.gnome.desktop.interface accent-color   green         GNOME 47 and later: blue teal green yellow orange red pink purple slate. libadwaita
#                                                             apps take it directly; Yaru, Ubuntu's theme, is told to follow it (the owner's
#                                                             instruction, 2026-10-19; whether Yaru's GTK 3 theme does is [I] until a booted image shows it).
#
# Why green and not teal. The brand's colours (assets/branding/brand-guidelines.md, vendor/brand/tokens) are phthalo #0a6358 (light
# primary) and sage #c5e8dc (dark primary) on navy #041620. Neither is a GNOME accent. The accents that share its hue are green (libadwaita
# #3a944a) and teal (#2190a4): in CIELAB the brand's hue is 181 degrees, green's 144 and teal's 220, so it sits between them, 37 degrees from
# green and 39 from teal. The two distances disagree about which is nearer: Euclidean RGB says green (70 against 91 for teal), CIELAB
# says teal (dE 26; slate 32; green 40, because phthalo is far darker than any accent). The frozen Arch override
# (backends/arch/desktop-theme/gnome-defaults-arch-overrides.inc.sh) and the backends retired on 2026-10-17 picked teal for naming consistency, and
# the retired override file called that "a judgment call, not a verified design decision" (tag pre-retire-multidistro-2026-10-17). The owner asked
# for green, and green is the pick; backends/ubuntu/lib/tests/appearance.sh keeps the choice to the accents within 45 degrees of the brand's hue
# (those two), and changing CI_OS_ACCENT_COLOR to teal here is the whole edit.
#
# What they do not touch: the GNOME Shell theme (the recoloured Yaru gresource, phthalo and sage, built by core/render), the greeter's own
# dconf database (gdm.d), Plymouth and GRUB (static images and colours, navy ground), the wallpaper (picture-uri-dark is the same file as
# picture-uri).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
# shellcheck shell=bash

CI_OS_COLOR_SCHEME="prefer-dark"
CI_OS_ACCENT_COLOR="green"

# The values GNOME's schemas accept (gsettings-desktop-schemas 47 and later).
CI_OS_COLOR_SCHEMES="default prefer-dark prefer-light"
CI_OS_ACCENT_COLORS="blue teal green yellow orange red pink purple slate"

# ci_os_appearance_valid: both values are ones the schema accepts. A value outside the enum would make glib-compile-schemas ignore the
# override and dconf store a string gsettings then rejects, with no error at build time. Prints the problem and returns 1.
ci_os_appearance_valid() {
    local v ok=0
    for v in $CI_OS_COLOR_SCHEMES; do [ "$v" != "$CI_OS_COLOR_SCHEME" ] || ok=1; done
    if [ "$ok" -ne 1 ]; then echo "color-scheme '$CI_OS_COLOR_SCHEME' is not one of: $CI_OS_COLOR_SCHEMES"; return 1; fi
    ok=0
    for v in $CI_OS_ACCENT_COLORS; do [ "$v" != "$CI_OS_ACCENT_COLOR" ] || ok=1; done
    if [ "$ok" -ne 1 ]; then echo "accent-color '$CI_OS_ACCENT_COLOR' is not one of: $CI_OS_ACCENT_COLORS"; return 1; fi
    return 0
}

# ci_os_appearance_dconf: the dconf keyfile text (a file of /etc/dconf/db/local.d).
ci_os_appearance_dconf() {
    printf "[org/gnome/desktop/interface]\ncolor-scheme='%s'\naccent-color='%s'\n" "$CI_OS_COLOR_SCHEME" "$CI_OS_ACCENT_COLOR"
}

# ci_os_appearance_override: the same as a glib schema override (a file of /usr/share/glib-2.0/schemas); the stanza is appended to
# 90_companion-os.gschema.override. It sorts after Ubuntu's 10_ override but loses to an Ubuntu override scoped to the ubuntu session
# (`[org.gnome.desktop.interface:ubuntu]`), which is why the dconf default above is the one that counts: a system database value beats every
# schema default.
ci_os_appearance_override() {
    printf "[org.gnome.desktop.interface]\ncolor-scheme='%s'\naccent-color='%s'\n" "$CI_OS_COLOR_SCHEME" "$CI_OS_ACCENT_COLOR"
}
