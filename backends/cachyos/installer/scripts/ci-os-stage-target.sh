#!/bin/bash
# ci-os-stage-target.sh <target-root> -- put the Companion OS parts on the installed system.
#
# Run by Calamares (modules/shellprocess_ci_os_stage.conf, instance ci_os_stage) in the LIVE system, with the target mounted
# at <target-root>, right after packages@online: the packages exist, and plymouthcfg / initcpio / grubcfg / bootloader /
# services-systemd still have to run. It reads the overlay (/usr/share/ci-os/calamares, built by installer/stage-installer.sh)
# and writes under <target-root> only. No chroot, no pacman, no systemctl: it works on a directory.
#
# Failure policy (decision D6):
#   payload and provisioning  FAIL CLOSED. Anything that is missing or does not copy ends in `exit 1`, and Calamares aborts the
#                             installation with this script's output. calamares-online.sh has already refused to start the
#                             installer when the overlay lacks these files (guards.list, "payload staging"), so this is the
#                             second line, not the first.
#   identity and brand        FAIL OPEN. The carry-over command of the brand overlay (iso/overlay/INSTALLED.md) is cosmetic: a
#                             failure is a loud "WARN:" line and the installation goes on with CachyOS' defaults for what it
#                             could not set.
#
# What is staged:
#   /usr/lib/ci-os/bootstrap/...          provisioning, in the repository's own layout so provision.sh's REPO_ROOT-relative paths
#                                         resolve unmodified: backends/{arch,cachyos}/provision, core/lib, core/manifest,
#                                         core/headless/payload, vendor/brand/tokens (the Ubuntu edition does the same)
#   the setup-portal payload              stage-headless.sh --root <target-root>  (the copy under bootstrap/ above)
#   /usr/lib/ci-os/first-boot-setup.sh, /usr/lib/systemd/system/ci-os-first-boot-setup.{service,timer}, /usr/local/bin/ci-os-setup
#                                         enabled by modules/services-systemd.conf
#   /usr/lib/ci-os/ci-os-post-install-fixups.sh   run by the ci_os_fixups instance
#   identity and brand                    /usr/share/ci-os/installed/carry-over <target-root>: os-release hook, skel hook,
#                                         wallpapers, GRUB and Plymouth themes
#
# Environment (tests): CI_OS_OVERLAY_DIR (default /usr/share/ci-os/calamares), CI_OS_CARRY_OVER (default
# /usr/share/ci-os/installed/carry-over).
set -euo pipefail
umask 022   # Calamares may run with a stricter umask; the directories created here are read by nginx, dnsmasq, systemd, ...

SRC="${CI_OS_OVERLAY_DIR:-/usr/share/ci-os/calamares}"
CARRY="${CI_OS_CARRY_OVER:-/usr/share/ci-os/installed/carry-over}"
ROOT="${1:-}"
WARNINGS=0

say() { printf 'ci-os-stage: %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf 'ci-os-stage: WARN: %s\n' "$*"; }
die() { printf 'ci-os-stage: ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "$ROOT" ] || die "usage: ci-os-stage-target.sh <target-root>"
[ -d "$ROOT" ] || die "target root is not a directory: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
[ "$ROOT" != / ] || die "refusing to stage into the running system (/)"
[ -d "$ROOT/usr" ] || die "$ROOT has no /usr: the base system was not installed there"

put() {  # MODE SRC DEST(relative to the root)
  local mode="$1" src="$2" dest="$ROOT/$3"
  [ -f "$src" ] || die "missing in the overlay: $src"
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  chmod "$mode" "$dest"
}

# --- 1. provisioning bootstrap tree ----------------------------------------------------------------------------------------
BOOT_SRC="$SRC/target/bootstrap"
[ -d "$BOOT_SRC" ] || die "no $BOOT_SRC in the overlay"
BOOT_DST="$ROOT/usr/lib/ci-os/bootstrap"
mkdir -p "$BOOT_DST"
cp -R "$BOOT_SRC/." "$BOOT_DST/"
find "$BOOT_DST" -type d -exec chmod 755 {} +
find "$BOOT_DST" -type f -exec chmod 644 {} +
find "$BOOT_DST" -type f -name '*.sh' -exec chmod 755 {} +
say "staged the provisioning bootstrap tree in /usr/lib/ci-os/bootstrap"

# --- 2. setup-portal payload (copy only: the packages job installed hostapd, dnsmasq, nginx, gunicorn, ...) -------------------
STAGER="$BOOT_DST/backends/cachyos/provision/stage-headless.sh"
[ -f "$STAGER" ] || die "missing $STAGER"
bash "$STAGER" --root "$ROOT"

# --- 3. first-boot provisioning ---------------------------------------------------------------------------------------------
put 755 "$BOOT_SRC/backends/cachyos/provision/first-boot-setup.sh" usr/lib/ci-os/first-boot-setup.sh
put 644 "$SRC/target/units/ci-os-first-boot-setup.service" usr/lib/systemd/system/ci-os-first-boot-setup.service
put 644 "$SRC/target/units/ci-os-first-boot-setup.timer" usr/lib/systemd/system/ci-os-first-boot-setup.timer
put 755 "$SRC/target/ci-os-setup" usr/local/bin/ci-os-setup
mkdir -p "$ROOT/var/lib/ci-os"
put 755 "$SRC/scripts/ci-os-post-install-fixups.sh" usr/lib/ci-os/ci-os-post-install-fixups.sh
say "installed the first-boot service, its retry timer and the ci-os-setup command"

# --- 4. identity and brand (fail open) ----------------------------------------------------------------------------------------
if [ -f "$CARRY" ]; then
  rc=0
  bash "$CARRY" "$ROOT" || rc=$?
  case "$rc" in
    0) say "identity and brand carried over" ;;
    1) warn "carry-over could not copy every listed path (see its output above); the installed system keeps CachyOS' look for those" ;;
    *) warn "carry-over failed with status $rc; the installed system keeps CachyOS' os-release, skeleton and boot themes" ;;
  esac
else
  warn "$CARRY is not in this live image: the installed system keeps CachyOS' os-release, skeleton and boot themes"
fi

# What the later jobs rely on; each is cosmetic.
[ -f "$ROOT/usr/share/grub/themes/companion-os/theme.txt" ] \
  || warn "no Companion OS GRUB theme in the target: grubcfg.conf points GRUB_THEME at it, GRUB shows its plain text menu"
[ -f "$ROOT/usr/share/plymouth/themes/companion-os/companion-os.plymouth" ] \
  || warn "no Companion OS Plymouth theme in the target: plymouthcfg falls back to Plymouth's stock theme, which carries the Arch wordmark"
if ! grep -q '^NAME="Companion OS"' "$ROOT/etc/os-release" 2>/dev/null; then
  warn "/etc/os-release does not say Companion OS; ci-os-post-install-fixups.sh tries again"
fi

say "done ($WARNINGS warning(s))"
