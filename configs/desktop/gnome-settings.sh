#!/usr/bin/env bash
# Apply CI GNOME session keys for the current user (e.g. Cubic chroot as desktop user).
# System-wide defaults + Plymouth: sudo ./setup/os-changes/apply-ci-os-desktop.sh
# Validate: ./setup/os-changes/apply-ci-os-desktop.sh --validate
set -euo pipefail
_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$_REPO/setup/os-changes/common/25-session-gsettings.sh"
