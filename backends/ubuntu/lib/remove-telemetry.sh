#!/usr/bin/env bash
#=============================================================================
# Disable Ubuntu telemetry and Ubuntu Pro prompts: resolve the telemetry domains to localhost, purge and hold the telemetry packages,
# and quiet the Pro client and the other background callers of Canonical. System-wide effect, not per-user.
#
# Written for Ubuntu 26.04 (resolute): every package named below exists in its archive (a name that does not is skipped by
# the `|| true` calls, never an error).
#
# The lists (which packages, which hosts, which units, which autostart entries) and the steps after the purge are in
# backends/ubuntu/lib/quiet-canonical.sh: the image build (customize-chroot.sh Step 2c) runs the same code in the chroot, and
# verify-iso.sh audits the built image with it. A machine attached to an Ubuntu Pro subscription keeps its Pro client (see that file).
#
# Can be run standalone or invoked from provision.sh.
#
# Usage:
#   sudo ./backends/ubuntu/lib/remove-telemetry.sh
#
# Requires root. When run standalone without root, exits with error.
#=============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=quiet-canonical.sh
source "$HERE/quiet-canonical.sh"

if [[ $(id -u) -ne 0 ]]; then
  echo -e "[-] Missing privileges. Run with: sudo $0"
  exit 1
fi

# Only clear screen when running standalone interactively
# (Skip clear when invoked with --from-setup to avoid wiping setup output)
if [[ "${1:-}" != "--from-setup" ]] && [[ -t 1 ]]; then
  clear
fi

# The running system: no chroot, the root is "".
CI_QUIET_CHROOT=""

# == Resolve telemetry domains to localhost (idempotent) ==
echo "[*] Ensuring telemetry domains resolve to localhost"
ci_quiet_hosts "" || echo "[!] could not update /etc/hosts"

# == Remove and blacklist telemetry services ==
echo "[*] Removing telemetry services"
# shellcheck disable=SC2086
apt purge -y $CI_QUIET_PURGE_PACKAGES >/dev/null 2>&1 || true

# Hold packages to prevent reinstallation (ignore errors for packages not in repo)
# shellcheck disable=SC2086
apt-mark hold $CI_QUIET_PURGE_PACKAGES 2>/dev/null || true

# == Ubuntu Pro prompts, ubuntu-insights, motd-news, autostart entries ==
echo "[*] Quieting Ubuntu Pro prompts and the other Canonical background callers"
ci_quiet_apply_all "" || echo "[!] a quieting step failed (see above); the rest was done"

echo "[+] Telemetry services successfully removed and blacklisted."
