#!/usr/bin/env bash
# /etc/os-release and /etc/lsb-release — Companion OS branding + Ubuntu-compatible machine identity.
# Also what the image build runs for both files: customize-chroot.sh calls this through run_theme_step.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

OS_RELEASE="/etc/os-release"
OS_RELEASE_BACKUP="/etc/os-release.ubuntu-backup-$(date +%Y%m%d-%H%M%S)"

# An image is rebuilt from the stock ISO every time, and customize-chroot.sh has already saved the stock
# file as /etc/os-release.ubuntu-base, so only a live system keeps a timestamped backup.
if [[ -f "$OS_RELEASE" ]] && ! ci_image_build; then
  cp "$OS_RELEASE" "$OS_RELEASE_BACKUP"
  log_info "Backup: $OS_RELEASE_BACKUP"
fi

# shellcheck source=../lib/os-release.sh
source "${REPO_ROOT}/backends/ubuntu/lib/os-release.sh"

log_info "Updating $OS_RELEASE (Companion OS branding, Ubuntu-compatible ID for apt/ROCm)..."
ci_os_write_branded_os_release "$OS_RELEASE"
ci_os_write_branded_lsb_release "/etc/lsb-release"

log_success "OS identity updated (PRETTY_NAME=Companion OS $(ci_os_marketing_version), ID=ubuntu, UBUNTU_CODENAME=$(ci_os_ubuntu_codename))"
