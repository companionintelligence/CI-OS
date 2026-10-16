#!/usr/bin/env bash
# capture-upstream-facts.sh <root> -- record what the Companion OS overlay assumes about the CachyOS installer, from a real tree.
#
# Maintainer tool. <root> is a directory that holds the installer's files at their installed paths: an unpacked
# cachyos-calamares-next package (bsdtar -xf cachyos-calamares-next-*.pkg.tar.zst -C <root>), or the unpacked squashfs of a built
# ISO. It prints the "facts" file that iso/tests/installer-launcher.sh turns back into a fake installer tree, so the guards are
# tested offline against the SHAPE of the pinned installer without shipping any of its files:
#
#   backends/cachyos/installer/packages/capture-upstream-facts.sh <root> [<root>/var/lib/pacman/local] \
#       > backends/cachyos/iso/tests/installer-fixtures/upstream-3.4.2-13.facts
#
# When the pinned installer changes (a new cachyos-calamares-next on a pin bump), run it again, read the diff, and fix
# guards.list / settings.conf / the module configs for whatever the diff shows. That diff IS the review of the new installer.
#
# Line kinds (one fact per line, fields separated by single spaces; strings may contain spaces after the path):
#   version PKG VERSION        from <local-db>/PKG-VERSION/desc when a pacman local database directory is given
#   module NAME                usr/lib/calamares/modules/NAME/module.desc exists
#   modfile NAME FILE          a file in a module directory (main.py, *.schema.yaml)
#   conf NAME                  etc/calamares/modules/NAME exists
#   script NAME                etc/calamares/scripts/NAME exists
#   file PATH                  other paths the guards look at exist
#   marker PATH STRING         the file contains the string (the strings guards.list `contains` rows look for, and the lines of
#                              pacstrap/main.py that add packages in code, for the `code-names` row)
#   keys NAME KEY KEY ...      top-level keys of etc/calamares/modules/NAME.conf (the module configs the overlay replaces)
#   list NAME KEY ITEM ...     the items of the block list KEY of etc/calamares/modules/NAME.conf, for every `list-drift` row of guards.list
#   seq show:X | exec:X        the install sequence of usr/share/calamares/settings_online.conf
#   owned PKG PATH             a path the named package owns (from the local database), for the hooks that edit package files
#
# Plain bash 3.2, sed, grep, awk, find. Writes only to stdout.
set -euo pipefail
LC_ALL=C
export LC_ALL

ROOT="${1:-}"
LOCALDB="${2:-}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { printf 'usage: capture-upstream-facts.sh <root> [<pacman local db dir>]\n' >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$(cd "$HERE/.." && pwd)"

echo "# Facts about the pinned CachyOS installer, captured by backends/cachyos/installer/packages/capture-upstream-facts.sh."
echo "# Read by iso/tests/installer-launcher.sh and installer-config.py. Regenerate on a pin bump and review the diff."

if [ -n "$LOCALDB" ]; then
  for d in "$LOCALDB"/cachyos-calamares-next-[0-9]*; do
    [ -f "$d/desc" ] || continue
    printf 'version cachyos-calamares-next %s\n' "$(awk '/^%VERSION%/{getline; print; exit}' "$d/desc")"
  done
fi

if [ -d "$ROOT/usr/lib/calamares/modules" ]; then
  for d in "$ROOT"/usr/lib/calamares/modules/*/; do
    [ -f "${d}module.desc" ] || continue
    n="$(basename "$d")"
    echo "module $n"
    for f in main.py "$n.schema.yaml"; do [ -f "$d$f" ] && echo "modfile $n $f"; done
  done
fi
for f in "$ROOT"/etc/calamares/modules/*; do [ -f "$f" ] && echo "conf $(basename "$f")"; done
for f in "$ROOT"/etc/calamares/scripts/*; do [ -f "$f" ] && echo "script $(basename "$f")"; done

# Paths the guards look at (kept in step with guards.list by the test that builds the fake tree).
for p in /usr/share/calamares/settings_online.conf /usr/share/calamares/qml/calamares/slideshow/Presentation.qml; do
  [ -e "$ROOT$p" ] && echo "file $p"
done

# Every `contains` row of guards.list: record whether the real file has the string.
grep -E '^(critical|cosmetic)[[:space:]]*\|[[:space:]]*contains[[:space:]]*\|' "$INSTALLER/guards.list" | while IFS='|' read -r _sev _kind path str _why; do
  path="$(printf '%s' "$path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  str="$(printf '%s' "$str" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -f "$ROOT$path" ] && grep -qF -- "$str" "$ROOT$path"; then printf 'marker %s %s\n' "$path" "$str"; fi
done

# The statements of pacstrap/main.py that add packages in code (the `code-names` guard of guards.list reads them): recorded as marker
# lines, a statement that spans lines as several, in file order, through the guard library's own extraction.
# shellcheck source=../lib/ci-guards.sh
. "$INSTALLER/lib/ci-guards.sh"
PM=/usr/lib/calamares/modules/pacstrap/main.py
if [ -f "$ROOT$PM" ]; then
  ci_g_code_statements "$ROOT$PM" | while IFS= read -r l; do printf 'marker %s %s\n' "$PM" "$l"; done
fi

# Top-level keys of the module configs the overlay replaces.
for c in bootloader grubcfg plymouthcfg users packages_online netinstall welcome_online pacstrap services-systemd packagechooser_bootloader; do
  f="$ROOT/etc/calamares/modules/$c.conf"
  [ -f "$f" ] || continue
  printf 'keys %s %s\n' "$c" "$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*:' "$f" | sed 's/:$//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
done

# The install sequence (the guard library's own parser, so the facts and the guard agree on what a sequence is).
SO="$ROOT/usr/share/calamares/settings_online.conf"
if [ -f "$SO" ]; then
  ci_g_sequence "$SO" | sed 's/^/seq /'
fi

# The lists the `list-drift` rows of guards.list compare: the installer's items, so the fake tree holds real list content.
grep -E '^(critical|cosmetic)[[:space:]]*\|[[:space:]]*list-drift[[:space:]]*\|' "$INSTALLER/guards.list" | while IFS='|' read -r _sev _kind spec _rest; do
  spec="$(printf '%s' "$spec" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  f="$ROOT/etc/calamares/modules/${spec%%:*}.conf"
  [ -f "$f" ] || continue
  printf 'list %s %s %s\n' "${spec%%:*}" "${spec#*:}" "$(ci_g_list "$f" "${spec#*:}" | tr '\n' ' ' | sed 's/ $//')"
done

# Package-owned paths the overlay edits after install (hooks): the two files of cachyos-hello.
if [ -n "$LOCALDB" ]; then
  for d in "$LOCALDB"/cachyos-hello-[0-9]*; do
    [ -f "$d/files" ] || continue
    grep -E '^(etc/skel/\.config/autostart/cachyos-hello\.desktop|usr/share/applications/cachyos-hello\.desktop)$' "$d/files" | sed 's|^|owned cachyos-hello /|'
  done
fi
