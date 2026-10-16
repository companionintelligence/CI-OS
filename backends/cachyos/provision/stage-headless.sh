#!/usr/bin/env bash
# stage-headless.sh -- copy the setup-portal payload (core/headless/payload) into a root directory, and nothing else.
#
# Why a second stager when backends/arch/headless-setup/install.sh exists. That script is written for a RUNNING Arch system
# and cannot be used from an installer, so backends/arch/** is left untouched (decision D8) and this one covers the CachyOS
# case. The differences, each one a bug when the Arch script runs in a chroot or against a mounted target:
#   - no `pacman -S`: the packages are installed by Calamares' packages job (modules/packages_online.conf), in one transaction;
#   - no `systemctl daemon-reload`, `enable` or `start`: unguarded under `set -e` the first one aborts the script when systemd
#     is not PID 1. Units are enabled by the services-systemd job (modules/services-systemd.conf), after this ran;
#   - the nginx wiring is different (below): the Arch script's does not load the portal on Arch's stock nginx.conf;
#   - every destination is prefixed with --root, so it can write into a mounted target, and --root is mandatory (no default).
#
# nginx. Arch's nginx package (1.30.5-1, /etc/nginx/nginx.conf read from the package) has NO `include conf.d/*.conf` or
# sites-enabled line: its http block holds one inline `server { listen 80; server_name localhost; }` and nothing else. The
# payload's server block therefore only becomes active if nginx.conf includes the directory it is copied to; the Arch script
# copies it to conf.d/ and never adds the include, so the portal would never be served. This script adds
# `include /etc/nginx/conf.d/*.conf;` as the last line of the http block when no include of conf.d is there (nginx.conf is a
# `backup=` file of the package, so the edit survives upgrades as a .pacnew). The payload's own `default_server` then wins
# port 80 for every Host but `localhost`. If the target has no nginx.conf yet the include cannot be added, and the run fails
# (the packages job installs nginx before this runs).
#
# Every file of the payload must be covered by a rule below. A new payload file that no rule places is an ERROR, not a silent
# omission: the parity test (iso/tests/installer-stage-headless.sh) and this script both stop, so the CachyOS edition cannot ship
# a payload that differs from the one the other backends ship.
#
# Usage: stage-headless.sh --root DIR [--payload DIR] [--print-units]
#   --root DIR      the root to stage into: a mounted target, or / on the running system (explicit on purpose)
#   --payload DIR   default: <repo>/core/headless/payload, i.e. the same relative path in the repository and in the
#                   /usr/lib/ci-os/bootstrap copy the installer leaves on the target
#   --print-units   print the systemd units the payload ships (what services-systemd.conf must enable) and exit
# Exit: 0 staged, 1 payload incomplete / unplaceable file / nginx not wired, 2 usage.
set -euo pipefail
umask 022   # Calamares may run with a stricter umask; the directories created here are read by nginx, dnsmasq, systemd, ...

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PAYLOAD="$REPO_ROOT/core/headless/payload"
ROOT=""
PRINT_UNITS=0

say() { printf 'stage-headless: %s\n' "$*"; }
die() { printf 'stage-headless: ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root)        ROOT="${2:-}"; [ $# -ge 2 ] || { usage >&2; exit 2; }; shift 2 ;;
    --payload)     PAYLOAD="${2:-}"; [ $# -ge 2 ] || { usage >&2; exit 2; }; shift 2 ;;
    --print-units) PRINT_UNITS=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             printf 'stage-headless: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -d "$PAYLOAD" ] || die "payload directory not found: $PAYLOAD"

if [ "$PRINT_UNITS" -eq 1 ]; then
  for f in "$PAYLOAD"/systemd/system/*.service; do basename "$f" .service; done
  exit 0
fi

[ -n "$ROOT" ] || { printf 'stage-headless: --root is required (use --root / to stage into the running system)\n' >&2; exit 2; }
[ -d "$ROOT" ] || die "root is not a directory: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
[ "$ROOT" = / ] && ROOT=""   # "/x" below, not "//x"

# --- 1. the same required-file gate as backends/{arch,fedora}/headless-setup/install.sh ---------------------------------------
REQUIRED_FILES="
hostapd/hostapd-setup.conf
dnsmasq.d/setup-portal.conf
nginx/sites-available/setup-portal
setup-device-defaults/device.conf
systemd/system/hostapd-setup.service
systemd/system/dnsmasq-setup.service
systemd/system/setup-backend.service
systemd/system/setup-network-monitor.service
opt/setup-backend/setup_service.py
opt/setup-backend/scripts/get-device-id.ts
usr/local/bin/setup-device-prescan.py
usr/share/setup-device/defaults/hostapd-setup.conf
usr/share/setup-device/defaults/setup-portal.conf
usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg
var/www/setup-portal/index.html
"
missing=""
for f in $REQUIRED_FILES; do [ -f "$PAYLOAD/$f" ] || missing="$missing $f"; done
[ -z "$missing" ] || die "required payload file(s) missing from $PAYLOAD:$missing"
GPU_DETECT="$PAYLOAD/../../lib/gpu-detect.sh"
[ -f "$GPU_DETECT" ] || die "core/lib/gpu-detect.sh not found next to the payload ($GPU_DETECT)"

# --- 2. placement rules --------------------------------------------------------------------------------------------------------
# rule REL -> prints one "DEST|MODE|IF_MISSING" line per destination of the payload file REL; returns 1 when no rule covers it.
# DEST is relative to the root; IF_MISSING=1 keeps an existing file (a configured device.conf is never overwritten).
rule() {
  case "$1" in
    opt/setup-backend/setup_service.py)   echo "$1|755|0" ;;
    opt/setup-backend/*)                  echo "$1|644|0" ;;
    usr/local/bin/*)                      echo "$1|755|0" ;;
    usr/share/setup-device/defaults/*)    echo "$1|644|0" ;;
    usr/share/applications/*)             echo "$1|644|0" ;;
    usr/share/icons/hicolor/scalable/apps/*) echo "$1|644|0" ;;
    var/www/setup-portal/*)               echo "$1|644|0" ;;
    systemd/system/*)                     echo "etc/systemd/system/${1#systemd/system/}|644|0" ;;
    hostapd/hostapd-setup.conf)           echo "etc/hostapd/hostapd-setup.conf|644|1" ;;
    dnsmasq.d/setup-portal.conf)          echo "etc/dnsmasq.d/setup-portal.conf|644|1" ;;
    setup-device-defaults/device.conf)    echo "etc/setup-device/device.conf|600|1" ;;
    nginx/sites-available/setup-portal)   echo "etc/nginx/sites-available/setup-portal|644|0"
                                          echo "etc/nginx/conf.d/setup-portal.conf|644|0" ;;
    *) return 1 ;;
  esac
}

place() {  # SRC DEST MODE IF_MISSING
  local src="$1" dest="$ROOT/$2" mode="$3" keep="$4"
  if [ "$keep" = 1 ] && [ -e "$dest" ]; then say "kept existing /$2"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  chmod "$mode" "$dest"
}

count=0
unplaced=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if lines="$(rule "$rel")"; then
    while IFS='|' read -r dest mode keep; do
      place "$PAYLOAD/$rel" "$dest" "$mode" "$keep"
    done <<EOF
$lines
EOF
    count=$((count + 1))
  else
    unplaced="$unplaced $rel"
  fi
done <<EOF
$(cd "$PAYLOAD" && find . -type f ! -name .DS_Store ! -path '*/__pycache__/*' ! -name '*.pyc' | sed 's|^\./||' | LC_ALL=C sort)
EOF
[ -z "$unplaced" ] || die "payload file(s) that no placement rule covers:$unplaced (add a rule to stage-headless.sh and to its parity test)"

# --- 3. what backends/arch/headless-setup/install.sh also does ---------------------------------------------------------------------
mkdir -p "$ROOT/usr/lib/ci-os" "$ROOT/var/lib/setup-device"
cp "$GPU_DETECT" "$ROOT/usr/lib/ci-os/gpu-detect.sh"
chmod 644 "$ROOT/usr/lib/ci-os/gpu-detect.sh"
# A stale flag would stop the hotspot from starting on a fresh device.
rm -f "$ROOT/var/lib/setup-device/setup-complete"

# --- 4. nginx must load conf.d ----------------------------------------------------------------------------------------------------
NGINX_CONF="$ROOT/etc/nginx/nginx.conf"
[ -f "$NGINX_CONF" ] || die "no /etc/nginx/nginx.conf in the target: the nginx package is not installed, so the portal cannot be wired"
if grep -Eq '^[[:space:]]*include[[:space:]]+(/etc/nginx/)?conf\.d/\*\.conf[[:space:]]*;' "$NGINX_CONF"; then
  say "nginx.conf already includes conf.d"
else
  tmp="$(mktemp "${TMPDIR:-/tmp}/nginx-conf.XXXXXX")"
  # Insert before the closing brace of the top-level http block (brace counting, comments and strings are not special-cased: the
  # stock file has braces only as block delimiters).
  awk '
    function delta(s,   t, o, c) { t = s; sub(/#.*/, "", t); o = gsub(/\{/, "{", t); c = gsub(/\}/, "}", t); return o - c }
    !seen && /^[[:space:]]*http[[:space:]]*\{/ { seen = 1; inhttp = 1; depth = delta($0); print; next }
    inhttp {
      d = delta($0)
      if (depth + d <= 0) { print "    include /etc/nginx/conf.d/*.conf;"; done = 1; inhttp = 0 } else { depth += d }
    }
    { print }
    END { if (!done) exit 3 }
  ' "$NGINX_CONF" > "$tmp" || { rm -f "$tmp"; die "could not find the end of the http block in $NGINX_CONF"; }
  cp "$NGINX_CONF" "$NGINX_CONF.ci-os-backup"
  cat "$tmp" > "$NGINX_CONF"
  rm -f "$tmp"
  say "added 'include /etc/nginx/conf.d/*.conf;' to the http block of /etc/nginx/nginx.conf (backup: nginx.conf.ci-os-backup)"
fi
# The only default_server must be the portal's. A distro nginx.conf that marks its own is made plain (Debian-style stock configs).
if grep -Eq 'listen[^;]*default_server' "$NGINX_CONF"; then
  sed -E -i.ci-os-default-server 's/(listen[^;]*) default_server;/\1;/' "$NGINX_CONF"
  rm -f "$NGINX_CONF.ci-os-default-server"
  say "removed default_server from the stock server blocks of /etc/nginx/nginx.conf"
fi

# --- 5. the portal's host name -------------------------------------------------------------------------------------------------------
mkdir -p "$ROOT/etc"
touch "$ROOT/etc/hosts"
if ! grep -q 'setup\.ci\.computer' "$ROOT/etc/hosts"; then
  echo "192.168.99.1 setup.ci.computer" >> "$ROOT/etc/hosts"
fi

say "staged $count payload file(s) into ${ROOT:-/}; enable these units afterwards (services-systemd.conf does): nginx $(for f in "$PAYLOAD"/systemd/system/*.service; do printf '%s ' "$(basename "$f" .service)"; done)"
