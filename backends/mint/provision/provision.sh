#!/usr/bin/env bash
# Mint's ecosystem-provisioning entrypoint is a thin wrapper around Ubuntu's,
# not a fork. Mint packaging research for this backend found the apt
# role-map (core/manifest/role-map/apt.yaml) is directly usable unchanged:
# Mint 22.x ("Wilma"/"Xia"/"Zara", current) is built on Ubuntu 24.04 Noble —
# the same base CI-OS already targets — so package names, repo URLs keyed off
# `. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}"`, and
# tier gating all resolve correctly on Mint with zero changes. Per the brief
# for this backend, that means NOT duplicating provision.sh's ~1700 lines —
# exec straight into the Ubuntu script.
#
# Note: install_tailscale()'s apt-fallback path used to resolve its repo
# codename with `lsb_release -cs`, which returns Mint's own codename (e.g.
# "zara") instead of the Ubuntu base codename pkgs.tailscale.com's repo
# actually needs — a real bug for Mint (which pins snapd out by default, so
# Tailscale falls back to this apt path on most Mint installs). Fixed
# upstream in backends/ubuntu/provision/provision.sh itself (now uses the
# same /etc/os-release-based codename resolution install_docker already
# used), rather than forked here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

exec bash "$REPO_ROOT/backends/ubuntu/provision/provision.sh" "$@"
