#!/usr/bin/env bash
#
# Arch headless-setup installer: plain, UNPACKAGED install of the
# setup-device captive-portal payload (core/headless/payload/ — hostapd
# hotspot, dnsmasq DHCP/DNS, nginx + Flask/gunicorn backend, static portal).
# Modeled structurally on backends/fedora/headless-setup/install.sh (read in
# full before writing this, itself modeled on
# backends/mint/headless-package/{build.sh,DEBIAN/*}); this Arch backend
# deliberately does NOT build a real .pkg.tar.zst package.
#
# --- Why a plain installer, not a real PKGBUILD (scoping research for this
# task; see docs/architecture/multi-distro-design.md for the full writeup) ---
# A genuine Arch package needs: a PKGBUILD (pkgname/pkgver/pkgrel/depends/
# source/sha256sums, a package() function that installs into $pkgdir), and —
# if any first-boot systemd-enable logic is needed, which it is here — a
# separate pkgname.install file with pre_install/post_install/pre_upgrade/
# post_upgrade/pre_remove/post_remove functions that pacman calls at the
# matching lifecycle stage.
#
# Compared to the two correctness traps this exact scoping question already
# hit on Fedora and Ubuntu/Mint: RPM's %post/%preun/%postun receive a
# NUMERIC install-count as $1 (0 = final removal, 1 = upgrade in progress) —
# the same physical scriptlet fires for both a fresh install and an upgrade,
# disambiguated only by that number — which is exactly the kind of thing
# that fails SILENTLY if translated wrong and normally gets caught by
# running real `dnf install`/`upgrade`/`remove` cycles on a live box, not
# available for this pass either. pacman's .install model is DIFFERENT, and
# genuinely simpler/safer in the way that matters here: pacman calls a
# DIFFERENTLY-NAMED function for each lifecycle stage
# (pre_install/post_install vs. pre_upgrade/post_upgrade vs.
# pre_remove/post_remove) instead of overloading one scriptlet name with a
# numeric code to distinguish them — there is no numeric argument to decode
# at all. pre_install/post_install receive the new package's version as
# their one argument; pre_upgrade/post_upgrade receive (new version, old
# version); pre_remove/post_remove receive the version being removed. This
# is closer to dpkg's NAMED-action-word model (which backends/mint's real
# .deb package already uses correctly — DEBIAN/postrm's `case "$1" in
# upgrade|failed-upgrade|...)` skip-cleanup-during-upgrade logic) than to
# RPM's numeric-decoding trap, and arguably clearer than dpkg's too, since
# there's no dispatch inside one script at all — you just define the
# function for the stage you care about.
#
# So the correctness risk RPM packaging carried (get the number wrong, break
# upgrade/purge silently) does NOT carry over identically to a hypothetical
# Arch PKGBUILD/.install — but the research recommendation for THIS pass is
# still (b), a plain unpackaged installer, not (a) a real PKGBUILD, for a
# different reason: there is still no live Arch system available in this
# pass to run a real makepkg/pacman -U install → upgrade → remove cycle
# against and confirm the .install hooks actually fire as expected (a stale
# systemd unit left enabled after a hypothetical `-R`, or a first-boot
# post_install hook that silently no-ops, would both fail just as quietly
# as an RPM mistake would, only discovered by testing, not by reading the
# spec). Real PKGBUILD/.install packaging is DEFERRED follow-up work,
# exactly mirroring Fedora's RPM deferral and Phase 3b/archiso's own
# deferral in this same rollout — not attempted here.
#
# core/headless/payload/ is reused BYTE FOR BYTE — nothing in it is copied
# into this directory or modified for this pass; only ITS OWN Arch install
# mechanics live in this file, same division of responsibility as
# build.sh/DEBIAN/ on the Mint/Ubuntu side and install.sh on the Fedora
# side. Arch-specific gaps found while writing this (not cosmetic
# pacman-vs-apt/dnf renames) are handled explicitly inline below: nginx's
# sites-available/sites-enabled convention has no Arch equivalent (same gap
# Fedora found), and Arch's stock nginx.conf also ships its own inline
# default_server block. Unlike Fedora, Arch ships NO SELinux and NO
# firewalld by default (a plain iptables/nftables ruleset, if any, is
# whatever the specific install has configured) — this installer does not
# touch either, since there is nothing standard to configure and guessing
# at a specific nftables/iptables setup would be exactly the kind of
# "commands that could partially apply" this task's brief says to avoid.
#
# No netplan handling here (same reasoning as Fedora's install.sh): Arch's
# native network backend is whatever was chosen at install time —
# NetworkManager is what this installer requires (see REQUIRED_DEPS below)
# and is what the payload's own scripts (e.g.
# usr/local/bin/setup-network-monitor.sh) talk to directly via nmcli, same
# as Fedora. If a target system uses a different network stack
# (systemd-networkd, plain netctl), this installer does not attempt to
# detect or support that — NetworkManager is a documented requirement, not
# silently assumed compatible with everything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../core/lib/theme-lib.sh
source "$REPO_ROOT/core/lib/theme-lib.sh"
require_root

PAYLOAD_DIR="$REPO_ROOT/core/headless/payload"

if [[ ! -d "$PAYLOAD_DIR" ]]; then
  log_error "Payload directory not found: $PAYLOAD_DIR"
  exit 1
fi

# --- Fail hard on missing required assets -----------------------------------
# Mirrors backends/mint/headless-package/build.sh's and
# backends/fedora/headless-setup/install.sh's REQUIRED_FILES gate — refuse
# to touch a live system at all rather than partially install.
REQUIRED_FILES=(
  "hostapd/hostapd-setup.conf"
  "dnsmasq.d/setup-portal.conf"
  "nginx/sites-available/setup-portal"
  "setup-device-defaults/device.conf"
  "systemd/system/hostapd-setup.service"
  "systemd/system/dnsmasq-setup.service"
  "systemd/system/setup-backend.service"
  "systemd/system/setup-network-monitor.service"
  "opt/setup-backend/setup_service.py"
  "opt/setup-backend/scripts/get-device-id.ts"
  "usr/local/bin/setup-device-prescan.py"
  "usr/share/setup-device/defaults/hostapd-setup.conf"
  "usr/share/setup-device/defaults/setup-portal.conf"
  "var/www/setup-portal/index.html"
)

MISSING_FILES=()
for f in "${REQUIRED_FILES[@]}"; do
  [[ -f "$PAYLOAD_DIR/$f" ]] || MISSING_FILES+=("$f")
done

if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
  log_error "Missing required payload files:"
  for f in "${MISSING_FILES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
log_success "All required payload files present"

# --- pacman package equivalents of Mint's DEBIAN/control Depends: line -----
# hostapd, dnsmasq, nginx: same names as apt/dnf, all official `extra`
# packages, no split (Arch, like Fedora, ships ONE nginx package — no
# nginx-vs-nginx-light distinction exists there either, same finding Fedora's
# research made, independently confirmed for Arch here).
# python: Arch's package for the python3 interpreter is just "python" (Arch
# only ever shipped a python3-compatible line since the py2/py3 split
# happened upstream, so there is no separate "python3" name to disambiguate
# the way Debian/Fedora need).
# python-flask: matches Arch's own python-* prefix convention.
# gunicorn: NOT "python-gunicorn" — CONFIRMED via direct archlinux.org
# package search, Arch's official package is plainly named "gunicorn" (no
# python- prefix), unlike Debian/Ubuntu's python3-gunicorn and Fedora's
# python3-gunicorn. This is a genuine naming exception, not a typo — the
# "Arch always prefixes Python packages with python-" assumption this task
# asked to verify does NOT hold for gunicorn specifically.
# networkmanager: the pacman PACKAGE name is lowercase "networkmanager"
# (Arch's own naming convention, unlike Fedora's "NetworkManager" package
# name) — but the systemd UNIT it ships keeps upstream's own capitalization,
# NetworkManager.service, which is what gets enabled below.
ARCH_DEPS=(hostapd dnsmasq nginx python python-flask gunicorn networkmanager)

if ! command -v pacman >/dev/null 2>&1; then
  log_error "pacman not found — this installer is Arch/pacman-specific"
  exit 1
fi

log_info "Installing package dependencies via pacman: ${ARCH_DEPS[*]}"
pacman -S --needed --noconfirm "${ARCH_DEPS[@]}"

# --- Stage the payload into place -------------------------------------------
log_info "Staging setup-device files into /etc, /opt, /usr, /var..."
mkdir -p /etc/hostapd /etc/dnsmasq.d /etc/setup-device
mkdir -p /opt/setup-backend/scripts /usr/local/bin /usr/share/setup-device/defaults
mkdir -p /usr/share/applications /var/www/setup-portal /var/lib/setup-device

cp -r "$PAYLOAD_DIR/opt/setup-backend/." /opt/setup-backend/
cp -r "$PAYLOAD_DIR/usr/local/bin/." /usr/local/bin/
mkdir -p /usr/lib/ci-os
cp "$REPO_ROOT/core/lib/gpu-detect.sh" /usr/lib/ci-os/gpu-detect.sh
chmod 644 /usr/lib/ci-os/gpu-detect.sh
cp -r "$PAYLOAD_DIR/usr/share/setup-device/defaults/." /usr/share/setup-device/defaults/
if [[ -d "$PAYLOAD_DIR/usr/share/applications" ]]; then
  cp -r "$PAYLOAD_DIR/usr/share/applications/." /usr/share/applications/
fi
cp -r "$PAYLOAD_DIR/var/www/setup-portal/." /var/www/setup-portal/
cp -r "$PAYLOAD_DIR/systemd/system/." /etc/systemd/system/

# Config files: install only if not already present, so rerunning this
# script doesn't clobber a configured device.conf / pairing state — same
# restore-if-missing behavior as Ubuntu/Mint/Fedora's installers.
[[ -f /etc/hostapd/hostapd-setup.conf ]] || cp "$PAYLOAD_DIR/hostapd/hostapd-setup.conf" /etc/hostapd/hostapd-setup.conf
[[ -f /etc/dnsmasq.d/setup-portal.conf ]] || cp "$PAYLOAD_DIR/dnsmasq.d/setup-portal.conf" /etc/dnsmasq.d/setup-portal.conf
[[ -f /etc/setup-device/device.conf ]] || cp "$PAYLOAD_DIR/setup-device-defaults/device.conf" /etc/setup-device/device.conf

chmod 600 /etc/setup-device/device.conf 2>/dev/null || true
chmod 644 /etc/hostapd/hostapd-setup.conf /etc/dnsmasq.d/setup-portal.conf 2>/dev/null || true
chmod 755 /opt/setup-backend/setup_service.py 2>/dev/null || true
chmod 755 /usr/local/bin/setup-device-prescan.py \
  /usr/local/bin/setup-network-monitor.sh \
  /usr/local/bin/setup-device-hotspot-start.sh \
  /usr/local/bin/setup-wifi-recover \
  /usr/local/bin/setup-hotspot-reset.sh \
  /usr/local/bin/ci-os-hub-start.sh \
  /usr/local/bin/ci-os-post-validation.sh 2>/dev/null || true

# --- nginx gap #1: sites-available/sites-enabled is a Debian convention ----
# Same gap Fedora's install.sh found and fixed the same way: the payload
# ships its nginx config as a "sites-available" file, activated on
# Ubuntu/Mint by symlinking into sites-enabled/ — a directory layout and
# `include` line that Debian/Ubuntu's nginx package maintainer scripts set
# up. Arch's nginx package ships NEITHER directory (confirmed by inspecting
# its own default nginx.conf), and its stock /etc/nginx/nginx.conf instead
# includes only `/etc/nginx/conf.d/*.conf` — the same convention Fedora's
# stock nginx.conf uses. The file's own contents (plain top-level
# `server { ... }` blocks, no surrounding `http {}`) are exactly what
# conf.d expects, so it's installed there directly rather than symlinked. A
# copy is also kept at sites-available/ purely for parity/reference with
# the payload's own layout — it is NOT the one nginx actually loads here.
mkdir -p /etc/nginx/sites-available
cp "$PAYLOAD_DIR/nginx/sites-available/setup-portal" /etc/nginx/sites-available/setup-portal
mkdir -p /etc/nginx/conf.d
cp "$PAYLOAD_DIR/nginx/sites-available/setup-portal" /etc/nginx/conf.d/setup-portal.conf
chmod 644 /etc/nginx/sites-available/setup-portal /etc/nginx/conf.d/setup-portal.conf

# --- nginx gap #2: Arch's stock nginx.conf ships its OWN inline
# default_server, which collides with ours -------------------------------
# Same gap Fedora's install.sh found: Arch's nginx package embeds a
# `server { listen 80 default_server; ... }` welcome-page block directly
# inside /etc/nginx/nginx.conf itself (no separate sites-enabled/default
# file to just `rm -f`, unlike Debian/Ubuntu). Two `default_server`
# directives on the same port make `nginx -t` fail outright ("duplicate
# default server"), so the stock one is neutralized here in favor of the
# captive-portal config this installer owns. Backed up first. This targets
# the exact wording of Arch's shipped default nginx.conf; it is a no-op
# (guarded by the grep below) if that wording isn't present, and was NOT
# independently verified against a live Arch install for this pass.
NGINX_CONF="/etc/nginx/nginx.conf"
if [[ -f "$NGINX_CONF" ]] && grep -q "default_server" "$NGINX_CONF" 2>/dev/null; then
  cp "$NGINX_CONF" "${NGINX_CONF}.ci-os-backup-$(date +%Y%m%d-%H%M%S)"
  sed -i -E 's/(listen[^;]+) default_server;/\1;/g' "$NGINX_CONF"
  log_info "Neutralized Arch's stock inline default_server in $NGINX_CONF (backup written alongside it)"
fi

rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

echo "Configuring hosts mapping..."
if ! grep -q "setup.ci.computer" /etc/hosts; then
  echo "192.168.99.1 setup.ci.computer" >> /etc/hosts
fi

# --- No SELinux, no firewalld on Arch (unlike Fedora) -----------------------
# Arch ships neither enabled by default — there is no standard mandatory
# access control layer or firewall daemon to configure here the way
# Fedora's install.sh has to (restorecon/setsebool/firewall-cmd). If a
# target system has iptables/nftables/ufw configured, that is site-specific
# and out of scope for this installer to guess at; the captive-portal ports
# (80, 53, 67/68) may need to be opened manually on such a system.

# --- systemd: reload, enable, start -----------------------------------------
log_info "Reloading systemd daemon..."
systemctl daemon-reload

log_info "Enabling services for boot-time startup..."
systemctl enable hostapd-setup.service 2>/dev/null || true
systemctl enable dnsmasq-setup.service 2>/dev/null || true
systemctl enable nginx.service 2>/dev/null || true
systemctl enable setup-backend.service 2>/dev/null || true
systemctl enable setup-network-monitor.service 2>/dev/null || true
# NetworkManager: pacman never auto-enables services it installs (see
# backends/arch/provision/provision.sh's header for the same convention) —
# the payload's own scripts talk to it via nmcli, so it must be running.
systemctl enable --now NetworkManager.service 2>/dev/null || log_warn "Could not enable/start NetworkManager.service — setup-network-monitor.sh's nmcli calls will fail without it"

# Remove any stale setup-complete flag so the hotspot can start fresh if
# there's no connectivity.
rm -f /var/lib/setup-device/setup-complete

log_info "Validating nginx configuration..."
if nginx -t; then
  log_success "nginx configuration is valid"
  if systemctl start nginx.service; then
    log_success "nginx service started"
  else
    log_warn "Failed to start nginx.service — portal UI may be unavailable until fixed"
  fi
else
  log_warn "nginx configuration test failed — portal UI may be unavailable until /etc/nginx/conf.d/setup-portal.conf is fixed"
fi

log_info "Starting backend service..."
if systemctl start setup-backend.service; then
  log_success "setup-backend.service started"
else
  log_warn "Failed to start setup-backend.service (continuing — network monitor is independent)"
fi

log_info "Starting network monitor service..."
if systemctl start setup-network-monitor.service; then
  log_success "setup-network-monitor.service started"
else
  log_warn "Failed to start setup-network-monitor.service"
fi

echo ""
log_success "Arch headless setup-device install complete"
log_info "hostapd-setup/dnsmasq-setup only start once setup-network-monitor detects no connectivity"
log_info "Known gaps: no real pacman packaging (see header), no SELinux/firewalld equivalent handling needed but also no iptables/nftables port-opening attempted, nginx default_server neutralization unverified on a live box"
