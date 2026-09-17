#!/usr/bin/env bash
# /etc/os-release and /etc/lsb-release — CI OS branding + Ubuntu-compatible machine identity.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

OS_RELEASE="/etc/os-release"
OS_RELEASE_BACKUP="/etc/os-release.ubuntu-backup-$(date +%Y%m%d-%H%M%S)"

if [[ -f "$OS_RELEASE" ]]; then
  cp "$OS_RELEASE" "$OS_RELEASE_BACKUP"
  log_info "Backup: $OS_RELEASE_BACKUP"
fi

# shellcheck source=../lib/os-release.sh
source "${REPO_ROOT}/backends/ubuntu/lib/os-release.sh"

log_info "Updating $OS_RELEASE (CI OS branding, Ubuntu-compatible ID for apt/ROCm)..."
ci_os_write_branded_os_release "$OS_RELEASE"
ci_os_write_branded_lsb_release "/etc/lsb-release"

log_success "OS identity updated (PRETTY_NAME=CI OS, ID=ubuntu, UBUNTU_CODENAME=$(ci_os_ubuntu_codename))"
