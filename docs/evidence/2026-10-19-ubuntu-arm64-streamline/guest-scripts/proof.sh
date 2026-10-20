#!/bin/sh
# Read-only facts about Ubuntu Pro, telemetry and appearance on an installed Companion OS or stock Ubuntu. Prints nothing; POSTs to 10.0.2.2:8800.
H=10.0.2.2:8800
N=${1:-proof}
OUT=/tmp/ftue-$N.txt
{
echo "== date (UTC)"; date -u +%FT%TZ
echo "== appearance, for the signed-in user"
for k in color-scheme accent-color gtk-theme icon-theme; do printf "%s: " $k; gsettings get org.gnome.desktop.interface $k 2>&1; done
for k in report-technical-problems send-software-usage-stats; do printf "privacy %s: " $k; gsettings get org.gnome.desktop.privacy $k 2>&1; done
echo "== dconf system database files"; ls /etc/dconf/db/local.d 2>&1
echo "== 04-ci-os-appearance"; cat /etc/dconf/db/local.d/04-ci-os-appearance 2>&1
echo "== Pro and telemetry unit files"
systemctl list-unit-files 'ua-timer*' 'apt-news*' 'esm-cache*' 'motd-news*' 'ubuntu-insights*' 'ubuntu-advantage*' 'ua-reboot*' --no-pager 2>&1 | head -20
echo "== timers that exist"; systemctl list-timers --all --no-pager 2>&1 | head -24
echo "== failed units"; systemctl --failed --no-legend --no-pager 2>&1; systemctl --user --failed --no-legend --no-pager 2>&1
echo "== system state"; systemctl is-system-running 2>&1
echo "== autostart entries"; ls /etc/xdg/autostart 2>&1 | tr '\n' ' '; echo; ls /etc/xdg/autostart/*.disabled 2>/dev/null | tr '\n' ' '; echo
echo "== login text scripts"; ls -l /etc/update-motd.d 2>&1 | awk '{print $1, $NF}'
echo "== hosts"; grep -n "127.0.0.1" /etc/hosts 2>&1
echo "== Pro client"; (pro status 2>&1 | head -14)
echo "== uaclient.conf keys"; grep -E "apt_news|update_messaging_timer|update_status_timer|metering_timer" /etc/ubuntu-advantage/uaclient.conf 2>&1
echo "== apt hooks"; ls /etc/apt/apt.conf.d 2>&1 | tr '\n' ' '; echo
echo "== telemetry packages"; dpkg -l ubuntu-report apport whoopsie popularity-contest ubuntu-insights landscape-common 2>&1 | awk 'NR>5{print $1, $2, $3}'
echo "== first-run state"; ls -a ~/.config 2>/dev/null | grep -i -E "initial|gnome-initial|setup" | tr '\n' ' '; echo; ps -eo comm= | grep -E "gnome-initial|update-notifier|ubuntu-report|snap-store|software" | sort -u | tr '\n' ' '; echo
echo "== disk, packages, time"; df -h / | tail -1; (dpkg -l | grep -c '^ii' | sed 's/^/dpkg installed: /'); uptime -p; systemd-analyze 2>&1 | head -2
} > "$OUT" 2>&1
if command -v curl >/dev/null 2>&1; then curl -s --data-binary @"$OUT" http://$H/up/$N >/dev/null
elif command -v wget >/dev/null 2>&1; then wget -q -O /dev/null --post-file="$OUT" http://$H/up/$N
fi
