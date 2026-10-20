#!/bin/sh
# Read-only facts about the LIVE session of Companion OS (second version: the dock and the desktop icons as well). POSTs to 10.0.2.2:8800.
H=10.0.2.2:8800
N=${1:-live2}
OUT=/tmp/ftue-$N.txt
{
echo "== date (UTC)"; date -u +%FT%TZ; uptime -p
echo "== appearance, for the live user"
for k in color-scheme accent-color gtk-theme; do printf "%s: " $k; gsettings get org.gnome.desktop.interface $k 2>&1; done
echo "== Canonical's installer unit in the user session"; systemctl --user is-enabled ubuntu-desktop-installer.service 2>&1; systemctl --user is-active ubuntu-desktop-installer.service 2>&1
ls -l /etc/systemd/user/graphical-session.target.wants 2>&1 | awk '{print $NF}' | tr '\n' ' '; echo
echo "== installer server unit (system)"; systemctl is-active snap.ubuntu-desktop-bootstrap.subiquity-server.service 2>&1
echo "== processes of the stock installer and of the one-click helper"; ps -eo pid,etime,comm,args | grep -E "ubuntu-desktop-boot|subiquity|ci-os-auto-install|zenity" | grep -v grep | cut -c1-150
echo "== dock settings"; for k in dock-fixed autohide intellihide intellihide-mode dock-position; do printf "%s: " $k; gsettings get org.gnome.shell.extensions.dash-to-dock $k 2>&1; done
echo "== extensions"; printf "enabled-extensions: "; gsettings get org.gnome.shell enabled-extensions 2>&1; printf "disabled-extensions: "; gsettings get org.gnome.shell disabled-extensions 2>&1
echo "== gnome-extensions list --enabled"; gnome-extensions list --enabled 2>&1
echo "== desktop-icons process"; ps -eo pid,etime,args | grep -E "ding" | grep -v grep | cut -c1-120
echo "== files on the desktop"; ls ~/Desktop 2>&1 | tr '\n' ' '; echo
echo "== dock favorites"; gsettings get org.gnome.shell favorite-apps 2>&1
echo "== failed units"; systemctl --failed --no-legend --no-pager 2>&1
} > "$OUT" 2>&1
if command -v curl >/dev/null 2>&1; then curl -s --data-binary @"$OUT" http://$H/up/$N >/dev/null
elif command -v wget >/dev/null 2>&1; then wget -q -O /dev/null --post-file="$OUT" http://$H/up/$N
fi
