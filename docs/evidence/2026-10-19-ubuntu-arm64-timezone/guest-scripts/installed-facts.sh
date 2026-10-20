#!/bin/sh
# read-only facts about the time zone of an installed system; prints nothing, POSTs the text to the host (10.0.2.2:8811)
H=10.0.2.2:8811
N=${1:-facts}
OUT=/tmp/tzfacts-$N.txt
{
echo "== date (UTC)"; date -u +%FT%TZ
echo "== os-release"; . /etc/os-release; echo "$PRETTY_NAME"; echo "kernel $(uname -r) $(uname -m)"
echo "== timedatectl"; timedatectl 2>&1 | sed 's/^ *//'
echo "== /etc/timezone"; cat /etc/timezone 2>&1
echo "== /etc/localtime"; readlink /etc/localtime 2>&1
echo "== uptime"; uptime
echo "== cloud-init"; cloud-init status 2>&1 | head -3
echo "== cloud-config files, timezone keys only"; sudo -n grep -rn -E "^ *timezone" /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d 2>&1 | head
echo "== files the installer left in /etc/cloud/cloud.cfg.d"; ls -l /etc/cloud/cloud.cfg.d 2>&1
echo "== the installer's own files in /var/log/installer"; sudo -n ls -l /var/log/installer 2>&1 | head -30
echo "== cloud-init log, lines about the time zone"; sudo -n grep -i -E "timezone|set-timezone" /var/log/cloud-init.log 2>&1 | cut -c1-220 | tail -12
echo "== installer server log, lines about the time zone or geoip (hashes filtered)"; sudo -n grep -i -E "timezone|geoip|time zone" /var/log/installer/subiquity-server-debug.log 2>&1 | grep -v '\$6\$' | cut -c1-220 | tail -40
} > "$OUT" 2>&1
curl -s --data-binary @"$OUT" http://$H/up/$N >/dev/null
