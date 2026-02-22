#!/bin/bash
#
# Update OS Release Information for CI OS
#
# Replaces Ubuntu branding in /etc/os-release with CI OS identity.
# This should be run during ISO customization or on first boot.
#
# Usage: sudo ./update-os-release.sh
# Requirements: Root/sudo access
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

OS_RELEASE="/etc/os-release"
OS_RELEASE_BACKUP="/etc/os-release.ubuntu-backup-$(date +%Y%m%d-%H%M%S)"

# Backup original file
if [[ -f "$OS_RELEASE" ]]; then
    cp "$OS_RELEASE" "$OS_RELEASE_BACKUP"
    log_info "Backup created: $OS_RELEASE_BACKUP"
fi

log_info "Updating $OS_RELEASE with CI OS branding..."

# Create new os-release with CI OS branding
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
log_success "OS release information updated"

# Also update lsb-release if it exists
LSB_RELEASE="/etc/lsb-release"
if [[ -f "$LSB_RELEASE" ]]; then
    LSB_RELEASE_BACKUP="/etc/lsb-release.ubuntu-backup-$(date +%Y%m%d-%H%M%S)"
    cp "$LSB_RELEASE" "$LSB_RELEASE_BACKUP"
    log_info "Backup created: $LSB_RELEASE_BACKUP"
    
    cat > "$LSB_RELEASE" <<'EOF'
DISTRIB_ID=CI-OS
DISTRIB_RELEASE=0.0.1
DISTRIB_CODENAME=ci
DISTRIB_DESCRIPTION="CI OS 0.0.1 - Companion Intelligence"
EOF
    
    chmod 644 "$LSB_RELEASE"
    log_success "LSB release information updated"
fi

log_success "CI OS identity applied"
log_info ""
log_info "Verify with:"
log_info "  cat /etc/os-release"
log_info "  lsb_release -a"
log_info "  hostnamectl"
