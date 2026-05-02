#!/usr/bin/env bash
# /etc/os-release and /etc/lsb-release CI identity.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

OS_RELEASE="/etc/os-release"
OS_RELEASE_BACKUP="/etc/os-release.ubuntu-backup-$(date +%Y%m%d-%H%M%S)"

if [[ -f "$OS_RELEASE" ]]; then
  cp "$OS_RELEASE" "$OS_RELEASE_BACKUP"
  log_info "Backup: $OS_RELEASE_BACKUP"
fi

log_info "Updating $OS_RELEASE..."
cat > "$OS_RELEASE" <<'EOF'
NAME="CI OS"
VERSION="0.0.1 (Companion Intelligence)"
ID=ci-os
ID_LIKE=ubuntu
PRETTY_NAME="CI OS 0.0.1"
VERSION_ID="0.0.1"
HOME_URL="https://ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
VERSION_CODENAME=ci
UBUNTU_CODENAME=noble
LOGO=ci-os-logo

# CI OS - Companion Intelligence Operating System
# Based on Ubuntu 24.04 LTS (Noble Numbat)
# Official dark green color scheme: #066c80, #00a9a7, #72ddd4
EOF
chmod 644 "$OS_RELEASE"

LSB_RELEASE="/etc/lsb-release"
if [[ -f "$LSB_RELEASE" ]]; then
  LSB_RELEASE_BACKUP="/etc/lsb-release.ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
  cp "$LSB_RELEASE" "$LSB_RELEASE_BACKUP"
  cat > "$LSB_RELEASE" <<'EOF'
DISTRIB_ID=CI-OS
DISTRIB_RELEASE=0.0.1
DISTRIB_CODENAME=ci
DISTRIB_DESCRIPTION="CI OS 0.0.1 - Companion Intelligence"
EOF
  chmod 644 "$LSB_RELEASE"
fi

log_success "OS identity updated"
