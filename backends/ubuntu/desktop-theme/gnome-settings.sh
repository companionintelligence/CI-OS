#!/usr/bin/env bash
# Apply CI GNOME session keys for the current user (e.g. Cubic chroot as desktop user).
# System-wide defaults + Plymouth: sudo ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh
# Validate: ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh --validate
set -euo pipefail
_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "$_REPO/backends/_mixins/gnome-dconf/25-session-gsettings.sh"
