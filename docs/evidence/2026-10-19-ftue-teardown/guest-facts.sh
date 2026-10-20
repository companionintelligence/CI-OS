#!/bin/sh
# guest-facts.sh: the read-only script the guests of the first-run teardown ran (2026-10-19) to report facts about the installed system.
# It prints nothing; it writes its text to /tmp and POSTs it to a small loopback server on the host (10.0.2.2 is the host as QEMU user
# networking shows it). It was started from a terminal in the guest with:
#   (curl -s 10.0.2.2:8800/f.sh || wget -qO- 10.0.2.2:8800/f.sh) | sh -s <name>
# Read-only: it changes nothing in the guest.
# Read-only facts of a guest for the first-run teardown. Prints nothing; POSTs the text to the host (10.0.2.2:8800).
H=10.0.2.2:8800
N=${1:-facts}
OUT=/tmp/ftue-$N.txt
{
echo "== date (UTC)"; date -u +%FT%TZ
echo "== os-release"; . /etc/os-release; echo "$PRETTY_NAME"; echo "kernel $(uname -r) $(uname -m)"
echo "== uptime and boot time"; uptime; systemd-analyze 2>&1 | head -3
echo "== system state"; systemctl is-system-running 2>&1
echo "== failed units (system)"; systemctl --failed --no-legend --no-pager 2>&1
echo "== failed units (user)"; systemctl --user --failed --no-legend --no-pager 2>&1
echo "== locale, keyboard, time zone"; echo "LANG=$LANG"; localectl status 2>&1 | sed 's/^ *//'; timedatectl 2>&1 | sed 's/^ *//' | grep -E "Time zone|NTP|synchronized|RTC in local"
echo "== host name and user"; hostname; id -un
echo "== packages"; (dpkg -l 2>/dev/null | grep -c '^ii' | sed 's/^/dpkg installed: /'); (rpm -qa 2>/dev/null | wc -l | sed 's/^/rpm installed: /')
echo "== disk and memory"; df -h / | tail -1; free -m | sed -n 2p
echo "== firewall and mandatory access control"; for u in ufw firewalld nftables apparmor; do printf "%s: %s\n" $u "$(systemctl is-active $u 2>&1)"; done
echo "== listening TCP ports"; ss -tln 2>/dev/null | awk 'NR>1{print $4}' | sort -u | tr '\n' ' '; echo
echo "== journal lines at priority err or worse, this boot"; journalctl -b -p err --no-pager 2>/dev/null | wc -l
echo "== xdg autostart entries"; ls /etc/xdg/autostart 2>/dev/null | tr '\n' ' '; echo
echo "== first-run and update helpers running"; ps -eo comm= | sort -u | grep -E "firefox|gnome-initial|gnome-tour|initial-setup|software|update|packagekit|ubuntu-report|welcome|tour|libreoffice|thunderbird|abrt|whoopsie|apport" | tr '\n' ' '; echo
echo "== snap and flatpak counts"; (snap list 2>/dev/null | tail -n +2 | wc -l | sed 's/^/snaps: /'); (flatpak list 2>/dev/null | wc -l | sed 's/^/flatpaks: /')
} > "$OUT" 2>&1
if command -v curl >/dev/null 2>&1; then curl -s --data-binary @"$OUT" http://$H/up/$N >/dev/null
elif command -v wget >/dev/null 2>&1; then wget -q -O /dev/null --post-file="$OUT" http://$H/up/$N
fi
