#!/bin/sh
H=10.0.2.2:8800
N=${1:-dock}
OUT=/tmp/ftue-$N.txt
{
echo "== enabled extensions"; gsettings get org.gnome.shell enabled-extensions 2>&1
echo "== disabled extensions"; gsettings get org.gnome.shell disabled-extensions 2>&1
echo "== gnome-extensions list (enabled)"; gnome-extensions list --enabled 2>&1
echo "== dock settings"
for k in dock-fixed autohide intellihide intellihide-mode dock-position extend-height show-apps-at-top; do printf "%s: " $k; gsettings get org.gnome.shell.extensions.dash-to-dock $k 2>&1; done
echo "== favorites"; gsettings get org.gnome.shell favorite-apps 2>&1
echo "== session"; echo "$XDG_CURRENT_DESKTOP $XDG_SESSION_TYPE $XDG_SESSION_DESKTOP"
echo "== dconf profile and local.d"; cat /etc/dconf/profile/user 2>&1; ls /etc/dconf/db/local.d 2>&1
echo "== shell errors about the dock (journal, this boot)"; journalctl --user -b --no-pager 2>/dev/null | grep -i -E "dock|extension" | tail -12 | cut -c1-200
} > "$OUT" 2>&1
if command -v curl >/dev/null 2>&1; then curl -s --data-binary @"$OUT" http://$H/up/$N >/dev/null
elif command -v wget >/dev/null 2>&1; then wget -q -O /dev/null --post-file="$OUT" http://$H/up/$N
fi
