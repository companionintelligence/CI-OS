#!/bin/bash
# calamares-online.sh -- start the Companion OS installer from the live session.
#
# This file REPLACES the script of the same name in upstream's airootfs (CachyOS-Live-ISO). cachyos-hello, which used to run
# it, is out of the picture (iso/overlay/.../etc/pacman.d/hooks/ci-os-neutralise-hello.hook); the desktop entry
# ci-os-install.desktop starts it. What it does, in order, and why (decision D6):
#
#  1. Refuse to run outside the live medium (the installer repartitions disks).
#  2. Make sure the pacman keyring exists and works, THEN sync the databases and bring archlinux-keyring and cachyos-keyring up to
#     date (Arch and CachyOS re-sign their keyrings often, and an ISO built weeks ago would otherwise fail the install on a
#     signature error). Upstream deleted the keyring first and synced before it ran pacman-key --init; without a keyring pacman
#     cannot verify the [cachyos] database, so on this live image that order failed every time, about 20 s after the click, with a
#     dialog that blamed the network (incident 2026-10-18, F1). A working keyring is never deleted and is re-populated (idempotent)
#     before the first sync; a missing or empty one is created (pacman-key --init, --populate archlinux cachyos) BEFORE the first
#     sync; an unusable one is repaired in place and, only if that fails, its CONTENTS are cleared in place and it is created anew
#     (the directory itself is never removed or renamed: on a live medium it can be a mount point, see keyring_clear). A sync that
#     fails with a keyring-class error repairs the keyring in place and is retried once. A failure is classified, in the dialog and
#     in the log (with pacman's own last error line), as a keyring problem, a network/mirror problem or something else: a repository
#     that cannot be reached is reported here instead of 40 minutes into the install.
#  3. Bring cachyos-calamares-next up to date as upstream does -- but only when the NEW package passes the guards below and
#     links on this system. The candidate is downloaded and unpacked into a temporary directory first (pacman -Sw, bsdtar); if its
#     layout no longer matches what the overlay assumes, or `ldd -r` says that a library or symbol it needs is not here (the
#     package depends on boost-libs without a version, so a rebuild against a newer boost than the ISO has would install
#     fine and then not start: incident 2026-10-18, F2, on the install-day side), the installer that is already on this ISO,
#     which the build gate proved to start, is kept and the reason is logged and shown.
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
#   CI_OS_PACMAN_GNUPG_DIR   the pacman keyring directory (looked at, repaired in place, and as a last resort its CONTENTS are cleared;
#                            the directory itself is never removed or renamed)  (default /etc/pacman.d/gnupg)
#   CI_OS_KEYRING_DIAG_DIR   where the public parts of a keyring that had to be cleared are kept for diagnosis  (default /var/log)
#   CI_OS_PKG_CACHE          pacman package cache                    (default /var/cache/pacman/pkg)
#   CI_OS_LOCK_FILE          single-instance lock                    (default $XDG_RUNTIME_DIR/ci-os-installer.lock, else /tmp)
#   CI_OS_SKIP_KEYRING=1     skip step 2 completely (no keyring work, no database sync, no NTP): for a machine whose keyring and
#                            databases are already in order, and for tests
#   CI_OS_ALLOW_NON_LIVE=1, CI_OS_NONINTERACTIVE=1   test switches
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

# --- step 2: the keyring ----------------------------------------------------------------------------------------------------------
# What went wrong when refresh_keys returns 1 (the dialog text and the log line are chosen from these):
KEYS_KIND=""     # keyring | network | other
KEYS_LAST=""     # the last error line pacman or pacman-key printed, verbatim

# keys_strip TEXT: pacman's output without the NAMES that merely contain a keyring word: URLs, package file names
# (archlinux-keyring-20261015-1-any.pkg.tar.zst) and the names of the keyring packages themselves (archlinux-keyring,
# cachyos-keyring). Incident follow-up 2026-10-18: a 404 on the archlinux-keyring package file was reported as a keyring problem
# because the file name has the word in it, and the person was told that their internet connection was fine.
keys_strip() {
  printf '%s\n' "$1" | sed -E \
    -e 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*##g' \
    -e 's#[A-Za-z0-9@._+:~-]*-keyring[A-Za-z0-9@._+:~-]*##g' \
    -e 's#[A-Za-z0-9@._+:~-]+\.pkg\.tar\.[A-Za-z0-9]+(\.sig)?##g'
}

# keys_classify TEXT: sets KEYS_KIND and KEYS_LAST from what pacman or pacman-key printed. KEYS_LAST is pacman's own last error
# line, untouched. The kind is decided on the text WITHOUT file and package names (keys_strip): a keyring word that is left decides
# (a transport failure never prints one, and a real keyring failure must not be called a network problem because a mirror also
# timed out once on the way); then a transport word (no connection, a 404 or 5xx from the mirror: the mirror lacks a file it
# should have) is a network/mirror problem; everything else is "other".
keys_classify() {
  local stripped re_keyring re_network
  re_keyring='keyring|key "?[0-9A-F]{8,}"? is unknown|unknown trust|signature from .* is (invalid|unknown|marginal)|invalid or corrupted (database|package) \(PGP signature\)|PGP signature|trustdb|public key|gpg: '
  re_network='could not resolve|could not connect|failed to connect|connection (timed out|refused|reset)|network is unreachable|temporary failure in name resolution|name or service not known|failed retrieving file|failed to retrieve some files|returned error|HTTP/[0-9.]+ (404|5[0-9][0-9])|error:? (404|5[0-9][0-9])|operation (too slow|timed out)|timeout was reached|empty reply|ssl|tls'
  KEYS_LAST="$(printf '%s\n' "$1" | grep -E '^(error|warning|==> ERROR|gpg:)' | tail -n 1)"
  [ -n "$KEYS_LAST" ] || KEYS_LAST="$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | tail -n 1)"
  stripped="$(keys_strip "$1")"
  if printf '%s\n' "$stripped" | grep -qiE "$re_keyring"; then
    KEYS_KIND=keyring
  elif printf '%s\n' "$stripped" | grep -qiE "$re_network"; then
    KEYS_KIND=network
  else
    KEYS_KIND=other
  fi
}

# keys_text: what to tell the person for KEYS_KIND. Advice that matches the cause: a restart gives the same keyring again (the live
# system builds it from this ISO's own keyring packages), so it is not offered; a keyring failure that survives a repair means the
# ISO is older than the keys the repositories use now.
keys_text() {
  case "$KEYS_KIND" in
    keyring) printf '%s' "The package signing keys on this live system could not be set up or verified. This is a problem with the keys, not with your internet connection. Restarting the computer does not help: the live system builds the same keys again from this ISO. Make sure the computer is online (it sets its clock from the internet) and start the installer again. If it fails again, this ISO is older than the keys the package repositories use now: download a newer Companion OS ISO." ;;
    network) printf '%s' "The package repositories could not be reached, or a mirror did not have the files it should. Check the internet connection and try again in a few minutes." ;;
    *)       printf '%s' "The package repositories could not be updated. Try again in a few minutes." ;;
  esac
}

keyring_priv() { # PRIV prefix, may be empty
  # shellcheck disable=SC2086
  $PRIV "$@"
}
# keyring_missing DIR: nothing there to work with (no directory, or an empty one). The trailing slash makes find look INSIDE a
# symbolic link to a directory instead of at the link.
keyring_missing() {
  keyring_priv test -d "$1" || return 0
  [ -z "$(keyring_priv find "$1/" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}
# keyring_usable DIR: a public keyring that pacman-key can list.
keyring_usable() {
  { keyring_priv test -s "$1/pubring.gpg" || keyring_priv test -s "$1/pubring.kbx"; } || return 1
  keyring_priv pacman-key --list-keys >/dev/null 2>&1
}
# keyring_populate: load the Arch and CachyOS master and packager keys of the installed keyring packages. Idempotent.
keyring_populate() {
  local out
  out="$(keyring_priv pacman-key --populate archlinux cachyos 2>&1)" || { printf '%s\n' "$out" >> "$LOG"; keys_classify "$out"; KEYS_KIND=keyring; log "pacman-key --populate failed: $KEYS_LAST"; return 1; }
  printf '%s\n' "$out" >> "$LOG"
  return 0
}
# keyring_init: create a keyring (or finish an existing one) and load the keys, BEFORE anything verifies a signature.
keyring_init() {
  local out
  out="$(keyring_priv pacman-key --init 2>&1)" || { printf '%s\n' "$out" >> "$LOG"; keys_classify "$out"; KEYS_KIND=keyring; log "pacman-key --init failed: $KEYS_LAST"; return 1; }
  printf '%s\n' "$out" >> "$LOG"
  keyring_populate
}

# keyring_diag_copy DIR: keep the PUBLIC parts of the keyring that is about to be cleared (public keyring, trust database, config
# files) and a listing, for diagnosis only. Private keys, sockets and random seeds are never copied. Best effort: a failure is a
# warning, never a reason to stop.
keyring_diag_copy() {
  local g="$1" d f n=0
  d="${CI_OS_KEYRING_DIAG_DIR:-/var/log}/ci-os-keyring-cleared.$(date +%s)"
  keyring_priv ls -la "$g" 2>&1 | log_block
  if ! keyring_priv mkdir -p -m 700 "$d" >> "$LOG" 2>&1; then log "WARN: no diagnostic copy of the old keyring (cannot create $d)"; return 0; fi
  for f in pubring.gpg pubring.kbx 'pubring.gpg~' 'pubring.kbx~' trustdb.gpg gpg.conf gpg-agent.conf dirmngr.conf; do
    if keyring_priv test -f "$g/$f" && keyring_priv cp -p -- "$g/$f" "$d/" >> "$LOG" 2>&1; then n=$((n + 1)); fi
  done
  log "kept $n public file(s) of the old keyring in $d, for diagnosis (private keys are not copied)"
  return 0
}

# keyring_clear DIR: empty the keyring directory IN PLACE: remove everything inside it, never the directory itself. Why not rename
# it aside (mv) or remove it (rm -rf DIR): the directory can be a mount point. The pinned upstream profile ships
# etc-pacman.d-gnupg.mount (a tmpfs), archiso's own releng profile pulls it in from pacman-init.service (Requires=), and an upstream
# change to that service would make this directory a mount point without a line of ours changing; rename and rmdir of a mount
# point fail with EBUSY. Clearing what is inside works whether it is a mount point, a directory of the live overlay or a plain
# directory. Dot files go too (find, not a glob). Refuses anything that is not an absolute path ending in /gnupg, and a symlink:
# this deletes, so it must not be possible to point it at /home. Returns 0 when the directory is left empty.
keyring_clear() {
  local g="$1"
  case "$g" in
    /*/gnupg|/*/gnupg/) ;;
    *) log "refusing to clear '$g': the keyring directory must be an absolute path ending in /gnupg"; return 1 ;;
  esac
  if keyring_priv test -L "$g"; then log "refusing to clear '$g': it is a symbolic link"; return 1; fi
  keyring_priv test -d "$g" || return 0
  # a gpg-agent left over from the old keyring would keep its sockets and caches; stop it (best effort)
  if command -v gpgconf >/dev/null 2>&1; then keyring_priv gpgconf --homedir "$g" --kill all >> "$LOG" 2>&1 || true; fi
  keyring_diag_copy "$g"
  keyring_priv find "$g" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + >> "$LOG" 2>&1 || { log "could not remove everything inside $g"; return 1; }
  keyring_missing "$g" || { log "$g still holds files after it was cleared"; return 1; }
  log "cleared the contents of $g (the directory itself was left in place)"
  return 0
}

# keyring_repair DIR: for a keyring that is not usable, or that pacman rejected. 1. repair in place (pacman-key --init and --populate
# keep what is there); 2. only if that does not give a usable keyring, clear the directory's contents (keyring_clear) and create a
# new one. Sets KEYS_KIND=keyring when it fails.
keyring_repair() {
  local g="$1"
  if keyring_init && keyring_usable "$g"; then log "the pacman keyring was repaired in place"; return 0; fi
  log "WARN: could not repair the keyring in place; clearing the contents of $g and creating a new one"
  if ! keyring_clear "$g"; then KEYS_KIND=keyring; KEYS_LAST="cannot clear the contents of $g"; log "$KEYS_LAST"; return 1; fi
  keyring_init || return 1
  if ! keyring_usable "$g"; then KEYS_KIND=keyring; KEYS_LAST="the new keyring in $g is not usable"; log "$KEYS_LAST"; return 1; fi
  return 0
}

# keyring_prepare DIR: a keyring that works has to exist, with the keys of both keyring packages loaded, before pacman verifies the
# first database or package. Never deletes a working one.
keyring_prepare() {
  local g="$1"
  if keyring_missing "$g"; then
    log "no pacman keyring in $g: creating it (pacman-key --init, --populate archlinux cachyos) before any database is synced"
    keyring_init || return 1
  elif keyring_usable "$g"; then
    log "the pacman keyring in $g works: keeping it, loading the keys of the keyring packages into it before the first sync"
    if ! keyring_populate; then
      log "the working keyring could not load the keys of the keyring packages: repairing it"
      keyring_repair "$g" || return 1
    fi
  else
    log "the pacman keyring in $g is not usable (no public keyring, or pacman-key cannot list it): repairing it in place"
    keyring_repair "$g" || return 1
  fi
  return 0
}

# keyring_sync: pacman -Sy of both keyring packages. On failure sets KEYS_KIND and KEYS_LAST and logs what pacman said.
keyring_sync() {
  local out rc=0
  out="$(keyring_priv pacman -Sy --noconfirm archlinux-keyring cachyos-keyring 2>&1)" || rc=$?
  printf '%s\n' "$out" >> "$LOG"
  if [ "$rc" -ne 0 ]; then
    keys_classify "$out"
    log "pacman -Sy failed (exit $rc), classified as: $KEYS_KIND. Last pacman error: ${KEYS_LAST:-<none>}"
    # the last line is often pacman's generic "failed to synchronize all databases"; the line that says why is above it
    log "pacman's error and warning lines, in order: $(printf '%s\n' "$out" | grep -E '^(error|warning):' | tr '\n' '|' | sed 's/|$//; s/|/ | /g')"
    return 1
  fi
  return 0
}

# keyring_sync_retry DIR: the sync; a keyring-class failure (an unknown key, a signature that does not verify: often a keyring made
# before the clock was right) gets ONE repair in place and ONE more try. A network or other failure is not retried here: a new
# keyring does not help against a missing mirror.
keyring_sync_retry() {
  local g="$1"
  keyring_sync && return 0
  [ "$KEYS_KIND" = keyring ] || return 1
  log "the sync failed with a keyring error: repairing the keyring in place and trying the sync once more"
  keyring_repair "$g" || return 1
  keyring_sync
}

refresh_keys() {
  local gnupg="${CI_OS_PACMAN_GNUPG_DIR:-/etc/pacman.d/gnupg}"
  [ "${CI_OS_SKIP_KEYRING:-0}" = 1 ] && return 0
  case "$gnupg" in ''|/|/etc|/etc/|/etc/pacman.d|/etc/pacman.d/) fatal "refusing to use '$gnupg' as the pacman keyring directory" ;; esac
  KEYS_KIND=""; KEYS_LAST=""

  # (1) a keyring that works has to exist, with the keys loaded, before pacman verifies the first database or package
  keyring_prepare "$gnupg" || return 1

  # (2) signatures have validity periods: a wrong clock makes good signatures look expired or not yet valid
  timedatectl set-ntp true 2>/dev/null || log "WARN: could not enable NTP (timedatectl); a wrong clock can make signatures look invalid"

  # (3) databases, and both keyring packages, as upstream does
  log "syncing the package databases and updating archlinux-keyring and cachyos-keyring"
  keyring_sync_retry "$gnupg" || return 1

  # (4) the keyring packages populate on install; this makes certain, and is idempotent
  keyring_populate || return 1
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

# candidate_links DIR: the unpacked candidate's /usr/bin/calamares resolves every library and symbol it needs against THIS system
# (its own libraries from DIR/usr/lib first). `ldd -r` also reports undefined symbols, the second F2 failure. No usr/bin/calamares in
# DIR means nothing to check (returns 0, says so); the guards cover the package layout.
candidate_links() {
  local dir="$1" bin out bad
  bin="$dir/usr/bin/calamares"
  if [ ! -f "$bin" ]; then log "the candidate has no usr/bin/calamares: its linkage was not checked"; return 0; fi
  if ! command -v ldd >/dev/null 2>&1; then log "WARN: ldd is not installed: the candidate's linkage was not checked"; return 0; fi
  out="$(LD_LIBRARY_PATH="$dir/usr/lib" ldd -r "$bin" 2>&1)" || true
  bad="$(printf '%s\n' "$out" | grep -E 'not found|undefined symbol|symbol lookup error|cannot open shared object' | head -n 6)"
  if [ -n "$bad" ]; then
    log "the candidate installer does not link on this system:"
    printf '%s\n' "$bad" | log_block
    return 1
  fi
  log "the candidate installer links on this system"
  return 0
}

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
  # the program and its own libraries, for the link check below (a package without them is simply not checked)
  bsdtar -xf "$pkg" -C "$tmp" usr/bin/calamares 'usr/lib/libcalamares*' >/dev/null 2>&1 || true
  if ! candidate_links "$tmp"; then
    log "WARN: cachyos-calamares-next $want does not link on this system (see above); KEEPING the installer on this ISO ($have)"
    ci_ui_message info "$TITLE" "The online installer package ($want) needs libraries that this live system does not have, so the installer that came with the ISO ($have) is used. Nothing is wrong with your computer. Details: $LOG"
    rm -rf "$tmp"; return 0
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

  refresh_keys || fatal "$(keys_text)"
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
