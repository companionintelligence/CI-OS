#!/bin/sh
# Read-only facts about the LIVE session of Companion OS: what opened by itself, and the appearance. POSTs to 10.0.2.2:8800.
H=10.0.2.2:8800
N=${1:-liveproof}
OUT=/tmp/ftue-$N.txt
{
echo "== date (UTC)"; date -u +%FT%TZ; uptime -p
echo "== appearance, for the live user"
for k in color-scheme accent-color gtk-theme; do printf "%s: " $k; gsettings get org.gnome.desktop.interface $k 2>&1; done
echo "== Canonical's installer unit in the user session"; systemctl --user is-enabled ubuntu-desktop-installer.service 2>&1; systemctl --user is-active ubuntu-desktop-installer.service 2>&1
ls -l /etc/systemd/user/graphical-session.target.wants 2>&1 | awk '{print $NF}' | tr '\n' ' '; echo
echo "== installer server unit (system)"; systemctl is-active snap.ubuntu-desktop-bootstrap.subiquity-server.service 2>&1
echo "== processes of the stock installer and of the one-click helper"; ps -eo pid,etime,comm,args | grep -E "ubuntu-desktop-boot|subiquity|ci-os-auto-install|zenity" | grep -v grep | cut -c1-150
echo "== windows of the session (wmctrl or gdbus)"; (wmctrl -l 2>/dev/null || echo "wmctrl not installed")
echo "== dock favorites"; gsettings get org.gnome.shell favorite-apps 2>&1
echo "== failed units"; systemctl --failed --no-legend --no-pager 2>&1
} > "$OUT" 2>&1
if command -v curl >/dev/null 2>&1; then curl -s --data-binary @"$OUT" http://$H/up/$N >/dev/null
elif command -v wget >/dev/null 2>&1; then wget -q -O /dev/null --post-file="$OUT" http://$H/up/$N
fi
