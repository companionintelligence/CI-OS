#!/usr/bin/env bash
#=============================================================================
# Setup-mode netplan must leave NetworkManager in charge of wired devices
#
# netplan only writes NetworkManager's 10-globally-managed-devices.conf (the
# file that makes NM manage Ethernet NICs, which Ubuntu otherwise lists as
# unmanaged) when the effective GLOBAL renderer is NetworkManager. A top-level
# "renderer: networkd" in 50-setup-mode.yaml overrides the stock
# 01-network-manager-all.yaml and removes that file: no wired icon, no
# connection. This test generates the real netplan output for the stock file
# plus the repo's 50-setup-mode.yaml and asserts the file is still written and
# that eth0 still gets its networkd DHCP definition.
#
# Needs root and the Ubuntu archive (installs netplan.io), so run it in a
# throwaway container:
#   docker run --rm -v "$PWD":/repo:ro ubuntu:24.04 \
#       bash /repo/backends/ubuntu/headless-package/tests/netplan-keeps-networkmanager.sh
#
# Exit status is non-zero if any check fails.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_YAML="$HERE/../netplan/50-setup-mode.yaml"
[[ -f "$SETUP_YAML" ]] || { echo "not found: $SETUP_YAML" >&2; exit 2; }

if ! command -v netplan >/dev/null 2>&1; then
    [[ "$(id -u)" -eq 0 ]] || { echo "netplan is not installed and this is not root; run it in an ubuntu:24.04 container" >&2; exit 2; }
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends netplan.io >/dev/null
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/netplan-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

mkdir -p "$ROOT/etc/netplan"
# The file Ubuntu 24.04 Desktop ships (byte for byte what the ISO's rootfs has).
printf '# Let NetworkManager manage all devices on this system\nnetwork:\n  version: 2\n  renderer: NetworkManager\n' \
    > "$ROOT/etc/netplan/01-network-manager-all.yaml"
cp "$SETUP_YAML" "$ROOT/etc/netplan/50-setup-mode.yaml"
# postinst does the same; netplan warns about group/world-readable files.
chmod 600 "$ROOT"/etc/netplan/*.yaml

if netplan generate --root-dir "$ROOT" >"$ROOT/generate.log" 2>&1; then
    pass "netplan generate accepts 01-network-manager-all.yaml + 50-setup-mode.yaml"
else
    fail "netplan generate failed: $(tr '\n' ' ' < "$ROOT/generate.log")"
fi

NM_CONF="$ROOT/run/NetworkManager/conf.d/10-globally-managed-devices.conf"
if [[ -f "$NM_CONF" ]]; then
    pass "NetworkManager still manages all wired devices (10-globally-managed-devices.conf written)"
else
    fail "10-globally-managed-devices.conf is missing: the global renderer is no longer NetworkManager, so every Ethernet NIC would be unmanaged"
fi

if [[ -f "$ROOT/run/systemd/network/10-netplan-eth0.network" ]] \
   && grep -q '^DHCP=ipv4$' "$ROOT/run/systemd/network/10-netplan-eth0.network"; then
    pass "eth0 keeps its networkd DHCP definition (10-netplan-eth0.network)"
else
    fail "eth0 lost its networkd DHCP definition"
fi

# Guard the cause too, not just the symptom: nothing at the top level may pick networkd.
if grep -qE '^  renderer:[[:space:]]*networkd' "$SETUP_YAML"; then
    fail "50-setup-mode.yaml sets a global renderer: networkd"
else
    pass "50-setup-mode.yaml sets no global renderer"
fi

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
