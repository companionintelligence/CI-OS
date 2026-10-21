#!/bin/sh
# Read-only facts about the LIVE session of Companion OS (third version: what is on the desktop, and the stock launcher snapd exports). POSTs to 10.0.2.2:8800.
H=10.0.2.2:8800
N=${1:-live3}
OUT=/tmp/ftue-$N.txt
{
echo "== date (UTC)"; date -u +%FT%TZ; uptime -p
echo "== appearance, for the live user"
for k in color-scheme accent-color; do printf "%s: " $k; gsettings get org.gnome.desktop.interface $k 2>&1; done
echo "== dock and extensions"
for k in dock-fixed intellihide; do printf "%s: " $k; gsettings get org.gnome.shell.extensions.dash-to-dock $k 2>&1; done
printf "disabled-extensions: "; gsettings get org.gnome.shell disabled-extensions 2>&1
echo "== desktop-icons process"; ps -eo pid,etime,args | grep -E "ding" | grep -v grep | cut -c1-100
echo "== files on the desktop (ls -la ~/Desktop)"; ls -la ~/Desktop 2>&1 | sed 's/^/  /'
echo "== installer launchers on the desktop (any file that names the stock installer)"; grep -l -E "ubuntu-desktop-bootstrap|ubuntu_bootstrap|ubiquity" ~/Desktop/*.desktop 2>/dev/null || echo "(none)"
echo "== the stock launcher that snapd exports and casper copies to the desktop at boot"
f=/var/lib/snapd/desktop/applications/ubuntu-desktop-bootstrap_ubuntu-desktop-bootstrap.desktop
if [ -f "$f" ]; then grep -E "^(Name|Exec|Icon|Type)=" "$f"; else echo "(not there)"; fi
echo "== the same launcher among the applications of the session (gtk-launch needs it by id)"; ls /var/lib/snapd/desktop/applications 2>/dev/null | grep -i bootstrap || echo "(none)"
echo "== dock favorites"; gsettings get org.gnome.shell favorite-apps 2>&1
echo "== helper messages of this session (journal, user)"; journalctl --user -b --no-pager 2>/dev/null | grep -i "ci-os-auto-install" | tail -n 6 || true
} > "$OUT" 2>&1
if command -v curl >/dev/null 2>&1; then curl -s --data-binary @"$OUT" http://$H/up/$N >/dev/null
elif command -v wget >/dev/null 2>&1; then wget -q -O /dev/null --post-file="$OUT" http://$H/up/$N
fi
