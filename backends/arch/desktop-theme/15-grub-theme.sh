#!/usr/bin/env bash
# GRUB boot-menu theming for Arch — a detect-and-delegate wrapper, NOT a
# straight by-path reuse of backends/ubuntu/desktop-theme/15-grub-theme.sh
# the way this backend's 10-plymouth.sh/30-wallpaper.sh reuse is (see
# apply-ci-os-desktop.sh's header). That matters here specifically: Ubuntu's
# script treats a missing /etc/default/grub as a hard failure
# (`log_error ...; exit 1`), which is the correct behavior on Ubuntu/Mint/
# Fedora — GRUB is guaranteed present there (Ubuntu's installer always
# installs it; Fedora's kickstart/anaconda default to it too) — but is NOT
# correct on Arch.
#
# Arch has no "Workstation"/"Desktop" installer flavor the way Ubuntu/Fedora
# do (see docs/architecture/multi-distro-design.md and
# backends/arch/provision/provision.sh's header): a real Arch install is
# assembled manually or via archinstall, and a large and entirely normal
# fraction of real Arch systems boot via systemd-boot instead of GRUB —
# there is no reasonable way to assume GRUB is present the way the other
# three backends can. This script's job is therefore to tell the two cases
# apart and skip CLEANLY (exit 0, clear log message) on a systemd-boot-only
# system, rather than failing hard the way a bare call to Ubuntu's script
# would. Once GRUB presence is confirmed, this delegates the actual theming
# work to Ubuntu's script BY PATH (never copied) — GRUB2 itself is exactly
# as distro-portable on Arch as it already is on Fedora/Mint (uses
# grub-mkconfig, which Arch's `grub` package ships identically to Fedora's),
# so there is no Arch-specific theming logic to write, only the presence
# check Ubuntu's/Fedora's/Mint's callers never needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../core/lib/theme-lib.sh
source "$REPO_ROOT/core/lib/theme-lib.sh"
require_root

UBUNTU_GRUB_SCRIPT="$REPO_ROOT/backends/ubuntu/desktop-theme/15-grub-theme.sh"

# Detection order, most to least direct. systemd-boot is checked FIRST and
# wins on a conflict: bootctl reporting systemd-boot as the *installed*
# loader (or loader.conf existing) is a much stronger signal of what's
# actually active than the mere presence of GRUB's config files, which can
# legitimately linger after a system migrates from GRUB to systemd-boot
# (grub package still installed, /etc/default/grub never removed) — checking
# GRUB first would misdetect that case and run grub-mkconfig against a
# boot loader nothing reads config from.
#  1. bootctl (systemd's own tool) reports systemd-boot is the installed
#     boot loader — the clearest positive signal this is a systemd-boot
#     system, not a GRUB one.
#  2. /boot/loader/loader.conf existing is systemd-boot's own config file —
#     present only when systemd-boot has actually been installed there.
#  3. /etc/default/grub existing (or grub-mkconfig being on PATH) is the
#     positive GRUB signal Ubuntu's script itself already requires — only
#     consulted once neither systemd-boot signal above fired.
# A system with neither signal (freshly imaged, nothing installed yet) is
# treated as "no GRUB to theme" — same clean-skip outcome as systemd-boot,
# since there's nothing to theme either way.
systemd_boot_in_use() {
  if command -v bootctl >/dev/null 2>&1; then
    if bootctl status 2>/dev/null | grep -qi 'systemd-boot'; then
      return 0
    fi
  fi
  [[ -f /boot/loader/loader.conf ]]
}

grub_present() {
  [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null 2>&1
}

if systemd_boot_in_use; then
  log_info "systemd-boot detected (not GRUB) — this is a common and fully supported Arch configuration. Skipping GRUB theming cleanly; there is no GRUB boot menu to theme on this system. (No systemd-boot theming equivalent is implemented in this pass.)"
  exit 0
fi

if grub_present; then
  log_info "GRUB detected (/etc/default/grub + grub-mkconfig present); delegating to backends/ubuntu/desktop-theme/15-grub-theme.sh (fully distro-portable GRUB2 logic, reused by path)"
  exec bash "$UBUNTU_GRUB_SCRIPT"
fi

log_warn "Neither GRUB (/etc/default/grub) nor systemd-boot (/boot/loader/loader.conf, bootctl) was detected. This backend assumes a bootloader is already installed and configured (prerequisite, not installed by this script) — skipping GRUB theming cleanly rather than failing hard, since this may simply be an unbootstrapped or container/chroot environment."
exit 0
