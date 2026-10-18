#!/usr/bin/env bash
# Install the branded GNOME Shell theme into an Ubuntu 26.04 root filesystem. Sourced by customize-chroot.sh (Step 2b).
#
# Two files on Ubuntu 26.04 hold a "gnome-shell-theme.gresource", and they are different things:
#
#   /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource   (yaru-theme-gnome-shell, 1,320,373 B on 26.04.1)
#       The Ubuntu session's theme: modes/ubuntu.json names it ("themeResourceName", stylesheet "Yaru/gnome-shell.css"),
#       and /usr/share/gnome-shell/gdm-theme.gresource (the GDM greeter) resolves to it through the alternatives system.
#   /usr/share/gnome-shell/gnome-shell-theme.gresource               (gnome-shell-common, 811,524 B)
#       The upstream GNOME theme. A session mode with no theme of its own (GNOME Shell 50's built-in "restrictive", "user"
#       and "unlock-dialog", and modes/initial-setup.json) loads it, and from it gnome-shell-light.css /
#       gnome-shell-dark.css / gnome-shell-high-contrast.css. Read from
#       libshell-18.so: _getDefaultStylesheet() looks for <stylesheetName minus .css>-high-contrast.css, then -<variant>.css,
#       then the plain name, and loadTheme() throws "No valid stylesheet found" if none exists.
#
# The branded blob (backends/ubuntu/packages/ci-os-branding/.../Yaru/gnome-shell-theme.gresource) is the Yaru theme
# recoloured, so it has Yaru's resources: Yaru/gnome-shell*.css, gdm.css and a few SVGs. It has NO gnome-shell-light.css
# and no top-level gnome-shell-dark.css. It used to be copied over BOTH files; over the upstream one that removes the
# stylesheets the built-in modes load. So the Yaru file always gets the blob, and the upstream file gets it only when the
# blob provides every resource path that file provides (then nothing can go missing); otherwise the upstream file stays
# Ubuntu's own and the step says so.
# shellcheck shell=bash

# ci_os_gresource_paths <file>: the resource paths inside a .gresource, sorted, one per line (empty on failure).
ci_os_gresource_paths() {
  gresource list "$1" 2>/dev/null | LC_ALL=C sort
}

# ci_os_install_shell_theme <branded.gresource> <root>
# Prints what it installed. Returns 1 when the blob is missing, or the Yaru directory cannot be written.
ci_os_install_shell_theme() {
  local blob="$1" root="$2"
  local yaru_dst="$root/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
  local top_dst="$root/usr/share/gnome-shell/gnome-shell-theme.gresource"

  if [[ ! -f "$blob" ]]; then
    echo "[!] CI-OS gresource not found at $blob — skipping theme"
    return 1
  fi

  mkdir -p "$(dirname "$yaru_dst")"
  install -m 644 "$blob" "$yaru_dst"
  echo "[+] GDM/GNOME Shell theme applied: /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource (ubuntu session, GDM greeter)"

  if [[ ! -e "$top_dst" ]]; then
    install -m 644 "$blob" "$top_dst"
    echo "[+] /usr/share/gnome-shell/gnome-shell-theme.gresource did not exist; installed the branded theme there too"
    return 0
  fi
  if [[ -L "$top_dst" ]]; then
    # A symlink (an alternatives link) leads to a file this step does not own: writing through it would change that.
    echo "[!] /usr/share/gnome-shell/gnome-shell-theme.gresource is a symlink; left as it is"
    return 0
  fi
  if ! command -v gresource >/dev/null 2>&1; then
    echo "[!] gresource (libglib2.0-bin) is missing on this host: cannot tell whether the branded theme can replace the upstream"
    echo "[!] /usr/share/gnome-shell/gnome-shell-theme.gresource, so it is left as Ubuntu ships it"
    return 0
  fi

  local missing
  missing="$(comm -13 <(ci_os_gresource_paths "$blob") <(ci_os_gresource_paths "$top_dst"))"
  if [[ -z "$(ci_os_gresource_paths "$top_dst")" ]]; then
    echo "[!] could not list the resources of $top_dst; left as Ubuntu ships it"
  elif [[ -z "$missing" ]]; then
    install -m 644 "$blob" "$top_dst"
    echo "[+] the branded theme provides every resource of the upstream theme; installed over /usr/share/gnome-shell/gnome-shell-theme.gresource too"
  else
    echo "[+] /usr/share/gnome-shell/gnome-shell-theme.gresource kept as Ubuntu ships it: the branded theme lacks $(printf '%s\n' "$missing" | wc -l | tr -d ' ') of its resources"
    echo "    (e.g. $(printf '%s\n' "$missing" | head -n 1)) that the session modes without a theme of their own load, so they keep Ubuntu's stock look"
  fi
  return 0
}
