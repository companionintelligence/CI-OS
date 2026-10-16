#!/bin/bash
# ci-os-post-install-fixups.sh [login-name] -- run IN the installed system (Calamares chroot) after the stock final steps.
#
# The CachyOS hard-codes that no module configuration reaches (decision D6). Each step is guarded: it checks that the thing it
# fixes is there, changes it, and says what it did; a step that cannot do its job prints a "WARN:" line. The script always exits
# 0, because every step is cosmetic or a safety net -- an installation must not fail over a menu string. (The things that must
# not fail, the package list and the payload, are guarded before the installer starts and checked in ci-os-stage-target.sh.)
#
# Why each step exists:
#  1. cachyos-grub-theme: pacstrap/main.py installs it in CODE for every GRUB install (base_packages += ["grub", "grub-hook",
#     "cachyos-grub-theme", "os-prober"]); no setting avoids it. grubcfg.conf has already pointed GRUB_THEME at the Companion OS
#     theme and bootloader has written grub.cfg, so the CachyOS theme is dead weight with CachyOS artwork: remove it. pacman
#     refuses if another package depends on it, which is the right answer (a WARN line, the package stays).
#  2. /etc/os-release: cachyos-hooks rewrites it on every `filesystem` transaction. The identity hook of the brand overlay
#     runs after it; this checks the result once more and runs the writer if the file still says CachyOS.
#  3. /etc/default/grub: the theme and the distributor are what the menu shows; if always_use_defaults did not take, say so.
#  4. docker group: the users job was told to add the account (users.conf); verify, and add it if it is not a member.
#     (provision.sh adds it again at first boot.)
set -u
umask 022   # Calamares may run with a stricter umask; the directories created here are read by nginx, dnsmasq, systemd, ...

USER_NAME="${1:-}"
ROOT="${CI_OS_ROOT:-}"        # empty in the chroot; tests point it at a directory
WARNINGS=0

say() { printf 'ci-os-fixups: %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf 'ci-os-fixups: WARN: %s\n' "$*"; }

# 1. the CachyOS GRUB theme package
if command -v pacman >/dev/null 2>&1 && pacman -Q cachyos-grub-theme >/dev/null 2>&1; then
  if grep -q '^GRUB_THEME=.*companion-os' "$ROOT/etc/default/grub" 2>/dev/null; then
    if pacman -Rns --noconfirm cachyos-grub-theme; then say "removed cachyos-grub-theme (pacstrap installs it for GRUB; GRUB_THEME is the Companion OS theme)"
    else warn "could not remove cachyos-grub-theme; /usr/share/grub/themes/cachyos stays on disk (unused)"; fi
  else
    warn "GRUB_THEME in /etc/default/grub is not the Companion OS theme; keeping cachyos-grub-theme so GRUB still finds a theme"
  fi
fi

# 2. os-release
if ! grep -q '^NAME="Companion OS"' "$ROOT/etc/os-release" 2>/dev/null; then
  writer="$ROOT/usr/share/libalpm/scripts/zz-ci-os-os-release"
  if [ -f "$writer" ]; then
    CI_OS_ROOT="$ROOT" bash "$writer" && say "rewrote /etc/os-release" || warn "the os-release writer failed"
  else
    warn "/etc/os-release still names CachyOS and $writer is missing"
  fi
  grep -q '^NAME="Companion OS"' "$ROOT/etc/os-release" 2>/dev/null || warn "/etc/os-release does not say Companion OS"
fi

# 3. GRUB defaults
if [ -f "$ROOT/etc/default/grub" ]; then
  grep -q '^GRUB_THEME=.*companion-os' "$ROOT/etc/default/grub" || warn "GRUB_THEME in /etc/default/grub is not the Companion OS theme (grubcfg.conf always_use_defaults did not apply?)"
  if grep -q '^GRUB_DISTRIBUTOR=.*[Cc]achy' "$ROOT/etc/default/grub"; then warn "GRUB_DISTRIBUTOR still names CachyOS: boot menu entries will too"; fi
else
  warn "no /etc/default/grub in the installed system (bootloader other than GRUB?)"
fi

# 4. docker group membership
if [ -n "$USER_NAME" ] && getent passwd "$USER_NAME" >/dev/null 2>&1; then
  if getent group docker >/dev/null 2>&1; then
    if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
      say "$USER_NAME is in the docker group"
    elif usermod -aG docker "$USER_NAME"; then
      say "added $USER_NAME to the docker group (users.conf should have; first-boot provisioning would anyway)"
    else
      warn "could not add $USER_NAME to the docker group"
    fi
  else
    warn "no docker group in the installed system: the docker package is missing?"
  fi
fi

say "done ($WARNINGS warning(s))"
exit 0
