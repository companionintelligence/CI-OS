#!/bin/bash
# calamares-online.sh -- start the Companion OS installer from the live session.
#
# This file REPLACES the script of the same name in upstream's airootfs (CachyOS-Live-ISO). cachyos-hello, which used to run
# it, is out of the picture (iso/overlay/.../etc/pacman.d/hooks/ci-os-neutralise-hello.hook); the desktop entry
# ci-os-install.desktop starts it. What it does, in order, and why (decision D6):
#
#  1. Refuse to run outside the live medium (the installer repartitions disks).
#  2. Re-initialise the pacman keyring, exactly as upstream does: Arch and CachyOS re-sign their keyrings often, and an ISO
#     built weeks ago would otherwise fail the install on a signature error. A repository that cannot be reached is reported
#     here, in a dialog, instead of 40 minutes into the install.
#  3. Bring cachyos-calamares-next up to date as upstream does -- but only when the NEW package passes the guards below. The
#     candidate is downloaded and unpacked into a temporary directory first (pacman -Sw, bsdtar); if its layout no longer
#     matches what the overlay assumes, the installer that is already on this ISO is kept and the reason is logged and shown.
#  4. Lay the overlay (/usr/share/ci-os/calamares: settings.conf, module configs, branding "companion") over the installer.
#     Guards (installer/lib/ci-guards.sh, installer/guards.list) decide first: a critical one (package list, payload) stops
#     the launcher with a dialog and exit status 1; a cosmetic one is logged loudly and the run continues.
#  5. Check that every package the installer is certain to ask for exists NOW (pacman -Si): the base system that pacstrap installs
#     (modules/pacstrap.conf basePackages, plus the packages pacstrap/main.py adds in code, listed in pacstrap-code-added.list)
#     and the package job's list (packages_online.conf, the netinstall groups that are selected by default). A name that vanished
#     from the repositories would otherwise abort the install after the disk has been written. Names only some installs need (a
#     filesystem's tools, an opt-in group) are checked too, but only warned about.
#  6. Start Calamares through pkexec-wrapper (upstream's helper that carries the desktop environment into pkexec).
#
# It never reads cachyos.org or wiki.cachyos.org. Output goes to the terminal when there is one and always to
# /home/liveuser/companion-install.log (mode 600). It prints no passwords and handles none.
#
# Environment (all optional; the defaults are the live system; the tests set the others):
#   CI_OS_OVERLAY_DIR        overlay directory                       (default /usr/share/ci-os/calamares)
#   CI_OS_CALAMARES_ROOT     prefix of the installer tree            (default none, i.e. the live system)
#   CI_OS_INSTALL_LOG        log file                                (default /home/liveuser/companion-install.log)
#   CI_OS_INSTALLER_UPDATE   auto (default: take a newer installer when it passes the guards) | 0 (keep the ISO's installer).
#                            The kernel parameter ci_os.installer_update=0 does the same from the boot menu.
#   CI_OS_SUDO               privilege prefix                        (default sudo; empty = none)
#   CI_OS_PACMAN_GNUPG_DIR   keyring directory that is re-created    (default /etc/pacman.d/gnupg)
#   CI_OS_PKG_CACHE          pacman package cache                    (default /var/cache/pacman/pkg)
#   CI_OS_LOCK_FILE          single-instance lock                    (default $XDG_RUNTIME_DIR/ci-os-installer.lock, else /tmp)
#   CI_OS_SKIP_KEYRING=1, CI_OS_ALLOW_NON_LIVE=1, CI_OS_NONINTERACTIVE=1   test switches
set -u

PROGNAME="$(basename "$0")"
OVERLAY="${CI_OS_OVERLAY_DIR:-/usr/share/ci-os/calamares}"
LOG="${CI_OS_INSTALL_LOG:-/home/liveuser/companion-install.log}"
PRIV="${CI_OS_SUDO-sudo}"
CACHE="${CI_OS_PKG_CACHE:-/var/cache/pacman/pkg}"
TITLE="Companion OS installer"
export CI_OS_OVERLAY_DIR="$OVERLAY"
PREFLIGHT_MSG=""

log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  printf '%s\n' "$line" >&2
  printf '%s\n' "$line" >> "$LOG" 2>/dev/null || true
}
log_block() {  # indent a multi-line message into the log
  local l
  while IFS= read -r l; do [ -n "$l" ] && log "$l"; done
  return 0
}

# fatal TEXT: tell the person at the desktop, log it, stop. Used for everything that must not be skipped.
fatal() {
  log "FATAL: $*"
  ci_ui_message error "$TITLE" "$* (Details: $LOG)"
  exit 1
}

# Source the guard library. It lives in the overlay so the same file is unit-tested in the repository.
load_library() {
  # shellcheck source=/dev/null
  if [ -r "$OVERLAY/lib/ci-guards.sh" ]; then . "$OVERLAY/lib/ci-guards.sh"; return 0; fi
  ci_ui_message() { printf '%s: %s\n' "$2" "$3" >&2; }
  fatal "The installer overlay is missing from this image ($OVERLAY/lib/ci-guards.sh). Re-download the Companion OS ISO."
}

ci_is_live() {
  [ "${CI_OS_ALLOW_NON_LIVE:-0}" = 1 ] && return 0
  [ -d /run/archiso ] && return 0
  grep -q 'archisobasedir=' /proc/cmdline 2>/dev/null
}

update_mode() {
  local m="${CI_OS_INSTALLER_UPDATE:-}"
  if [ -z "$m" ]; then
    m="$(sed -n 's/.*ci_os\.installer_update=\([a-z0-9]*\).*/\1/p' /proc/cmdline 2>/dev/null | head -n 1)"
  fi
  case "$m" in 0) printf '0' ;; *) printf 'auto' ;; esac
}

# Upstream's order, kept: remove the keyring, install both keyrings, init, populate, sync the clock.
refresh_keys() {
  local gnupg="${CI_OS_PACMAN_GNUPG_DIR:-/etc/pacman.d/gnupg}"
  [ "${CI_OS_SKIP_KEYRING:-0}" = 1 ] && return 0
  case "$gnupg" in ''|/|/etc|/etc/|/etc/pacman.d|/etc/pacman.d/) fatal "refusing to delete '$gnupg' as the pacman keyring directory" ;; esac
  log "re-initialising the pacman keyring ($gnupg)"
  # shellcheck disable=SC2086  # $PRIV is "sudo" or empty
  $PRIV rm -rf "$gnupg"
  # shellcheck disable=SC2086
  $PRIV pacman -Sy --noconfirm archlinux-keyring cachyos-keyring >> "$LOG" 2>&1 || return 1
  # shellcheck disable=SC2086
  $PRIV pacman-key --init >> "$LOG" 2>&1 || return 1
  # shellcheck disable=SC2086
  $PRIV pacman-key --populate archlinux cachyos >> "$LOG" 2>&1 || return 1
  timedatectl set-ntp true 2>/dev/null || log "WARN: could not enable NTP (timedatectl); a wrong clock can make signatures look invalid"
  return 0
}

check_installer() {  # prints the report into the log; returns 1 when a critical guard failed
  ci_g_reset
  ci_g_run_table "$OVERLAY/guards.list"
  ci_g_report | log_block
  [ "$CI_G_CRIT_COUNT" -eq 0 ]
}

installed_version() { pacman -Q cachyos-calamares-next 2>/dev/null | awk '{print $2; exit}'; }
repo_version() { pacman -Si cachyos-calamares-next 2>/dev/null | awk -F': *' '$1 ~ /^Version/ { print $2; exit }'; }

# Step 3. Always returns 0: the worst case is "keep the installer that is on the ISO".
maybe_update_installer() {
  local mode have want pkg tmp keep_root f
  mode="$(update_mode)"
  if [ "$mode" = 0 ]; then log "installer update disabled (ci_os.installer_update=0): using the installer on this ISO"; return 0; fi
  have="$(installed_version)"; want="$(repo_version)"
  if [ -z "$want" ]; then log "WARN: cannot read cachyos-calamares-next from the repositories; using the installer on this ISO ($have)"; return 0; fi
  if [ "$have" = "$want" ]; then log "installer is current ($have)"; return 0; fi
  log "installer on this ISO: $have; repository: $want"

  # shellcheck disable=SC2086
  if ! $PRIV pacman -Sw --noconfirm cachyos-calamares-next >> "$LOG" 2>&1; then
    log "WARN: could not download cachyos-calamares-next $want; using the installer on this ISO ($have)"; return 0
  fi
  pkg=""
  for f in "$CACHE"/cachyos-calamares-next-"$want"-*.pkg.tar.*; do
    case "$f" in *.sig) continue ;; esac
    [ -f "$f" ] || continue
    if [ -z "$pkg" ] || [ "$f" -nt "$pkg" ]; then pkg="$f"; fi
  done
  if [ -z "$pkg" ]; then log "WARN: downloaded package not found in $CACHE; using the installer on this ISO ($have)"; return 0; fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ci-calamares-candidate.XXXXXX")" || { log "WARN: no temporary directory; using the installer on this ISO ($have)"; return 0; }
  if ! bsdtar -xf "$pkg" -C "$tmp" etc/calamares usr/share/calamares usr/lib/calamares/modules; then
    log "WARN: cannot unpack $pkg; using the installer on this ISO ($have)"; rm -rf "$tmp"; return 0
  fi
  keep_root="${CI_OS_CALAMARES_ROOT:-}"
  CI_OS_CALAMARES_ROOT="$tmp"; export CI_OS_CALAMARES_ROOT
  if check_installer; then
    CI_OS_CALAMARES_ROOT="$keep_root"; export CI_OS_CALAMARES_ROOT
    log "cachyos-calamares-next $want passed the guards; installing it"
    # shellcheck disable=SC2086
    $PRIV pacman -S --noconfirm cachyos-calamares-next >> "$LOG" 2>&1 || log "WARN: installing $want failed; the installer on this ISO ($have) stays"
  else
    CI_OS_CALAMARES_ROOT="$keep_root"; export CI_OS_CALAMARES_ROOT
    log "WARN: cachyos-calamares-next $want does not match what the Companion OS overlay expects; KEEPING the installer on this ISO ($have)"
    ci_ui_message info "$TITLE" "The online installer package ($want) changed in a way this ISO does not support yet, so the installer that came with the ISO ($have) is used. Nothing is wrong with your computer. Details: $LOG"
  fi
  rm -rf "$tmp"
  return 0
}

verify_applied() {  # the files the installer will read are byte-identical to the overlay's
  local ov root f rel bad=0
  ov="$OVERLAY"; root="$(ci_g_root)"
  cmp -s "$ov/settings.conf" "$root/etc/calamares/settings.conf" || { log "applied file differs: /etc/calamares/settings.conf"; bad=1; }
  for f in "$ov"/modules/*; do
    cmp -s "$f" "$root/etc/calamares/modules/$(basename "$f")" || { log "applied file differs: /etc/calamares/modules/$(basename "$f")"; bad=1; }
  done
  while IFS= read -r f; do
    rel="${f#"$ov"/}"
    cmp -s "$f" "$root/usr/share/calamares/$rel" || { log "applied file differs: /usr/share/calamares/$rel"; bad=1; }
  done < <(find "$ov/branding" -type f | LC_ALL=C sort)
  [ "$bad" -eq 0 ]
}

apply_overlay() {
  check_installer || return 1
  ci_g_apply_overlay || { log "could not copy the overlay into the installer tree"; return 1; }
  ci_g_reset
  ci_g_apply_cosmetic_patches "$OVERLAY/patches.list"
  ci_g_report | log_block
  verify_applied || return 1
  log "overlay applied: settings.conf, $(find "$OVERLAY/modules" -type f | wc -l | tr -d ' ') module file(s), branding $(ci_g_value "$OVERLAY/settings.conf" branding)"
}

# Step 5. Names come from the overlay's own YAML and pacstrap-code-added.list (lib/ci-pkglist.py), so the list that is checked is the list
# that is installed.
# Sets PREFLIGHT_MSG (what to tell the person) when it returns 1.
preflight_packages() {
  local always optional out rc=0 missing
  always="$(python3 -I "$OVERLAY/lib/ci-pkglist.py" "$OVERLAY" always)" || { log "cannot read the package list from $OVERLAY"; PREFLIGHT_MSG="The installer's package list could not be read."; return 1; }
  [ -n "$always" ] || { log "the package list is empty"; PREFLIGHT_MSG="The installer's package list is empty."; return 1; }
  # shellcheck disable=SC2086  # word splitting of the name list is the point
  out="$($PRIV pacman -Si $always 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    missing="$(printf '%s\n' "$out" | sed -n "s/^error: package '\\(.*\\)' was not found.*/\\1/p" | tr '\n' ' ')"
    log "package preflight failed: not in the repositories right now: ${missing:-see below}"
    printf '%s\n' "$out" | log_block
    PREFLIGHT_MSG="These packages are no longer available from the repositories: ${missing:-unknown}."
    return 1
  fi
  optional="$(python3 -I "$OVERLAY/lib/ci-pkglist.py" "$OVERLAY" optional)" || optional=""
  if [ -n "$optional" ]; then
    # shellcheck disable=SC2086
    out="$($PRIV pacman -Si $optional 2>&1 >/dev/null)" || log "WARN: optional package(s) missing from the repositories (only matters if ticked, or for a Btrfs/ZFS/bcachefs/handheld install): $(printf '%s' "$out" | sed -n "s/^error: package '\\(.*\\)' was not found.*/\\1/p" | tr '\n' ' ')"
  fi
  log "package preflight: $(printf '%s\n' "$always" | wc -l | tr -d ' ') required package(s) found"
  return 0
}

main() {
  # The log is private (it holds hardware information and the installer's debug output). Only the log: pkexec starts Calamares with
  # this process' umask, and a root installer under 077 would create the target's directories unreadable for the daemons that run later.
  ( umask 077; touch "$LOG" ) 2>/dev/null || true
  chmod 600 "$LOG" 2>/dev/null || true
  printf -- '---- %s ----\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$LOG" 2>/dev/null || true
  load_library
  log "$PROGNAME started (ISO version: $(cat /etc/version-tag 2>/dev/null || echo unknown))"
  ci_is_live || fatal "This installer only runs from the Companion OS live medium."
  # A second click on the desktop icon while the first run is still preparing must not start a second one.
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${CI_OS_LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/ci-os-installer.lock}"
    if ! flock -n 9; then
      log "another instance of the installer launcher is already running"
      ci_ui_message info "$TITLE" "The installer is already starting. Its window opens in a minute."
      exit 0
    fi
  fi
  ci_ui_notify "$TITLE" "Preparing the installer (checking the package repositories). The installer window opens in a minute."
  if [ -d /sys/firmware/efi ]; then log "System: UEFI"; else log "System: BIOS/MBR"; fi
  if command -v inxi >/dev/null 2>&1; then inxi -F >> "$LOG" 2>&1 || true; fi

  refresh_keys || fatal "The package repositories could not be reached or their keys could not be set up. Connect to the internet and try again."
  maybe_update_installer

  if ! apply_overlay; then
    fatal "The Companion OS installer overlay does not fit the installer on this system, so the installer was NOT started (nothing was changed on your disks). Re-download a newer Companion OS ISO."
  fi
  if ! preflight_packages; then
    fatal "${PREFLIGHT_MSG:-The package list could not be checked.} The installer was NOT started (nothing was changed on your disks). Try again later, or use a newer Companion OS ISO."
  fi

  log "starting Calamares"
  pkexec-wrapper calamares -D6 >> "$LOG" 2>&1
  local rc=$?
  log "Calamares exited with status $rc"
  exit "$rc"
}

main "$@"
