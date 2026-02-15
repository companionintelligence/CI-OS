#!/usr/bin/env bash
#=============================================================================
# Disable Ubuntu telemetry: resolve domains to localhost and remove/blacklist
# telemetry services. System-wide effect, not per-user.
#
# Tested on Ubuntu 22.04 (Jammy) and 24.04 (Noble).
#
# Can be run standalone or invoked from setup-fresh-ubuntu.sh.
#
# Usage:
#   sudo ./scripts/remove-telemetry.sh
#
# Requires root. When run standalone without root, exits with error.
#=============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

if [[ $(id -u) -ne 0 ]]; then
  echo -e "[-] Missing privileges. Run with: sudo $0"
  exit 1
fi

# Only clear screen when running standalone interactively
# (Skip clear when invoked with --from-setup to avoid wiping setup output)
if [[ "${1:-}" != "--from-setup" ]] && [[ -t 1 ]]; then
  clear
fi

# == Resolve telemetry domains to localhost (idempotent) ==
add_host_if_missing() {
  local domain="$1"
  if ! grep -qF "127.0.0.1 $domain" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 $domain" >> /etc/hosts
    echo "[*] Added $domain to /etc/hosts"
  else
    echo "[*] $domain already in /etc/hosts, skipping"
  fi
}

echo "[*] Ensuring telemetry domains resolve to localhost"
add_host_if_missing "www.metrics.ubuntu.com"
add_host_if_missing "metrics.ubuntu.com"
add_host_if_missing "www.popcon.ubuntu.com"
add_host_if_missing "popcon.ubuntu.com"

# == Remove and blacklist telemetry services ==
TELEMETRY_PACKAGES="ubuntu-report popularity-contest apport whoopsie apport-symptoms"
echo "[*] Removing telemetry services"
apt purge -y $TELEMETRY_PACKAGES >/dev/null 2>&1 || true

# Hold packages to prevent reinstallation (ignore errors for packages not in repo)
apt-mark hold $TELEMETRY_PACKAGES 2>/dev/null || true

echo "[+] Telemetry services successfully removed and blacklisted."
