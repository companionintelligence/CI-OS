#!/usr/bin/env bash
#
# Fedora headless-setup installer: plain, UNPACKAGED install of the
# setup-device captive-portal payload (core/headless/payload/ — hostapd
# hotspot, dnsmasq DHCP/DNS, nginx + Flask/gunicorn backend, static portal).
# Modeled structurally on backends/mint/headless-package/{build.sh,DEBIAN/*}
# (read in full before writing this), which builds a real .deb; this Fedora
# backend deliberately does NOT build a .rpm.
#
# Real RPM packaging (.spec file, rpmbuild, %post/%preun/%postun
# scriptlets) is DEFERRED follow-up work, not attempted here — the same way
# ISO/kickstart-lorax building (Phase 3b) is already deferred for this whole
# pass. The scoping research done for this task found RPM scriptlets carry
# a specific, non-cosmetic correctness trap unsafe to author blind: Debian's
# postrm receives a NAMED action word as $1 (upgrade/purge/abort-install/...
# — exactly what backends/mint/headless-package/DEBIAN/postrm switches on to
# skip cleanup during upgrades), while RPM's %post/%preun/%postun instead
# receive a NUMERIC install-count as $1 (0 = final removal, 1 = upgrade in
# progress), and the old/new package's scriptlets interleave differently
# across an upgrade. Getting that translation wrong fails SILENTLY —
# services wrongly disabled on a routine upgrade, or units removed that
# shouldn't be — and is normally caught by running real `dnf install` /
# `upgrade` / `remove` cycles on an actual Fedora box, which wasn't
# available for this pass. A plain shell installer sidesteps that risk
# entirely, at the cost of no real upgrade/purge lifecycle: rerun this
# script to "upgrade" (it's idempotent — see the config-file guards below),
# and nothing here uninstalls anything.
#
# core/headless/payload/ is reused BYTE FOR BYTE — nothing in it is copied
# into this directory or modified for this pass; only ITS OWN Fedora
# install mechanics live in this file, same division of responsibility as
# build.sh/DEBIAN/ on the Mint/Ubuntu side. Two genuine Fedora-specific gaps
# were found while writing this (not cosmetic dnf-vs-apt renames) and are
# handled explicitly inline below: the payload's nginx config ships under a
# Debian sites-available/sites-enabled convention Fedora's stock nginx.conf
# doesn't use, and Fedora's stock nginx.conf also ships its own inline
# `default_server` welcome-page block that collides with the payload's.
# SELinux (enforcing by default on Fedora Workstation) and firewalld
# (active by default) are also Fedora-only concerns with no Debian/Ubuntu
# counterpart; both are handled best-effort and flagged as unverified
# against a live enforcing-mode Fedora box — see their own comments below.
#
# No netplan handling here (unlike backends/ubuntu/headless-package, which
# ships one, and unlike backends/mint/headless-package, which explains why
# it deliberately doesn't): Fedora's native network backend IS
# NetworkManager, with no netplan translation layer in front of it at all,
# so there is nothing to generate or omit either way. The payload's own
# scripts (e.g. usr/local/bin/setup-network-monitor.sh) already talk to
# NetworkManager directly via nmcli.
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
# Mirrors backends/mint/headless-package/build.sh's REQUIRED_FILES gate —
# refuse to touch a live system at all rather than partially install.
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
  "usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
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

# --- dnf package equivalents of Mint's DEBIAN/control Depends: line --------
# hostapd, dnsmasq: same names. nginx-light -> nginx (Fedora ships one
# nginx package, no light/full split). python3, python3-flask,
# python3-gunicorn: same naming convention as Debian/Ubuntu.
# network-manager -> NetworkManager (different capitalization, no hyphen;
# usually already present by default on Fedora Workstation, installed here
# anyway for headless/minimal installs where it might not be).
FEDORA_DEPS=(hostapd dnsmasq nginx python3 python3-flask python3-gunicorn NetworkManager)

if ! command -v dnf >/dev/null 2>&1; then
  log_error "dnf not found — this installer is Fedora/dnf-specific"
  exit 1
fi

log_info "Installing package dependencies via dnf: ${FEDORA_DEPS[*]}"
dnf install -y "${FEDORA_DEPS[@]}"

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
# The launcher entry above names the ci-os-logo icon: ship it, or the entry shows a missing-icon placeholder.
# GTK trusts icon-theme.cache over the directory, so refresh the cache where the tool exists.
mkdir -p /usr/share/icons/hicolor/scalable/apps
cp -r "$PAYLOAD_DIR/usr/share/icons/hicolor/scalable/apps/." /usr/share/icons/hicolor/scalable/apps/
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi
cp -r "$PAYLOAD_DIR/var/www/setup-portal/." /var/www/setup-portal/
cp -r "$PAYLOAD_DIR/systemd/system/." /etc/systemd/system/

# Config files: install only if not already present, so rerunning this
# script doesn't clobber a configured device.conf / pairing state — same
# restore-if-missing behavior as Ubuntu/Mint's DEBIAN/postinst.
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
# The payload ships its nginx config as a "sites-available" file, activated
# on Ubuntu/Mint by symlinking into sites-enabled/ — a directory layout and
# an `include` line that Debian/Ubuntu's nginx package maintainer scripts
# set up. Fedora's nginx RPM ships NEITHER directory, and its stock
# /etc/nginx/nginx.conf instead includes only `/etc/nginx/conf.d/*.conf`.
# The file's own contents (plain top-level `server { ... }` blocks, no
# surrounding `http {}`) are exactly what conf.d expects, so it's installed
# there directly rather than symlinked. A copy is also kept at
# sites-available/ purely for parity/reference with the payload's own
# layout — it is NOT the one nginx actually loads on Fedora.
mkdir -p /etc/nginx/sites-available
cp "$PAYLOAD_DIR/nginx/sites-available/setup-portal" /etc/nginx/sites-available/setup-portal
mkdir -p /etc/nginx/conf.d
cp "$PAYLOAD_DIR/nginx/sites-available/setup-portal" /etc/nginx/conf.d/setup-portal.conf
chmod 644 /etc/nginx/sites-available/setup-portal /etc/nginx/conf.d/setup-portal.conf

# --- nginx gap #2: Fedora's stock nginx.conf ships its OWN inline
# default_server, which collides with ours -------------------------------
# Fedora's nginx RPM embeds a `server { listen 80 default_server; ... }`
# welcome-page block directly inside /etc/nginx/nginx.conf itself (there is
# no separate sites-enabled/default file to just `rm -f`, unlike
# Debian/Ubuntu). Two `default_server` directives on the same port make
# `nginx -t` fail outright ("duplicate default server"), so the stock one
# is neutralized here in favor of the captive-portal config this installer
# owns — our config needs to be the default so captive-portal detection
# probes (which hit arbitrary hostnames/IPs, not setup.ci.computer by name)
# land on it. Backed up first. This targets the exact wording of the
# Fedora nginx RPM's shipped default file; it is a no-op (guarded by the
# grep below) if that wording isn't present, and was NOT independently
# verified against a live Fedora install for this pass.
NGINX_CONF="/etc/nginx/nginx.conf"
if [[ -f "$NGINX_CONF" ]] && grep -q "default_server" "$NGINX_CONF" 2>/dev/null; then
  cp "$NGINX_CONF" "${NGINX_CONF}.ci-os-backup-$(date +%Y%m%d-%H%M%S)"
  sed -i -E 's/(listen[^;]+) default_server;/\1;/g' "$NGINX_CONF"
  log_info "Neutralized Fedora's stock inline default_server in $NGINX_CONF (backup written alongside it)"
fi

rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

echo "Configuring hosts mapping..."
if ! grep -q "setup.ci.computer" /etc/hosts; then
  echo "192.168.99.1 setup.ci.computer" >> /etc/hosts
fi

# --- SELinux: unverified-but-plausible requirement --------------------------
# Fedora Workstation runs SELinux in enforcing mode by default; Debian/Ubuntu
# have no equivalent concern, so this has no counterpart in
# backends/mint/headless-package/DEBIAN/postinst. nginx's /api/
# proxy_pass to 127.0.0.1 needs the standard `httpd_can_network_connect`
# boolean under enforcing SELinux, and files placed outside their package's
# normal locations (/var/www/setup-portal, our conf.d file) may need their
# contexts restored. Both are applied here best-effort (skipped cleanly if
# the tools aren't present) — NEITHER was verified against a real
# enforcing-mode Fedora install for this pass. If the portal/API don't come
# up, `journalctl -u setup-backend -u nginx` and `ausearch -m avc -ts
# recent` are the first things to check.
if command -v restorecon >/dev/null 2>&1; then
  log_info "Restoring SELinux file contexts (best effort)..."
  restorecon -RF /var/www/setup-portal /etc/nginx/conf.d/setup-portal.conf 2>/dev/null || true
fi
if command -v setsebool >/dev/null 2>&1 && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  log_info "Enabling httpd_can_network_connect SELinux boolean (best effort, for nginx proxy_pass)..."
  setsebool -P httpd_can_network_connect on 2>/dev/null || log_warn "setsebool httpd_can_network_connect failed — proxy_pass may be blocked under enforcing SELinux"
fi

# --- firewalld: best-effort, unverified -------------------------------------
# Fedora Workstation ships firewalld active by default; Debian/Ubuntu ship
# no firewall active out of the box, so this also has no Mint counterpart.
# This opens the standard http/dns/dhcp SERVICES in firewalld's default
# zone as a best-effort convenience. It does NOT scope them to only the
# hotspot interface (that would need a dedicated firewalld zone bound to
# the AP interface named in hostapd-setup.conf, which was not built or
# tested here). If the captive portal is unreachable from a connected
# client, `firewall-cmd --list-all` is the first thing to check.
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
  log_info "Opening http/dns/dhcp services in firewalld's default zone (best effort)..."
  firewall-cmd --add-service=http --permanent 2>/dev/null || true
  firewall-cmd --add-service=dns --permanent 2>/dev/null || true
  firewall-cmd --add-service=dhcp --permanent 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || log_warn "firewall-cmd --reload failed"
fi

# --- systemd: reload, enable, start -----------------------------------------
log_info "Reloading systemd daemon..."
systemctl daemon-reload

log_info "Enabling services for boot-time startup..."
systemctl enable hostapd-setup.service 2>/dev/null || true
systemctl enable dnsmasq-setup.service 2>/dev/null || true
systemctl enable nginx.service 2>/dev/null || true
systemctl enable setup-backend.service 2>/dev/null || true
systemctl enable setup-network-monitor.service 2>/dev/null || true

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
log_success "Fedora headless setup-device install complete"
log_info "hostapd-setup/dnsmasq-setup only start once setup-network-monitor detects no connectivity"
log_info "Known gaps: no real RPM packaging (see header), no interface-scoped firewalld zone, SELinux booleans/contexts applied best-effort and unverified on a live box"
