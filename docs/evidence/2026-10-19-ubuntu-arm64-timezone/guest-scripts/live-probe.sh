#!/bin/sh
# read-only probe of the installer's server in the live session (the time zone only); prints nothing, POSTs the text to the host (10.0.2.2:8811)
H=10.0.2.2:8811
N=${1:-probe}
OUT=/tmp/probe-$N.txt
API="sudo -n curl -sS --unix-socket /run/subiquity/socket"
{
echo "== date (UTC)"; date -u +%FT%TZ
echo "== installer snap"; snap list ubuntu-desktop-bootstrap 2>&1
echo "== the zone geoip.ubuntu.com gives this guest (the service the installer asks)"; curl -fsS --max-time 10 https://geoip.ubuntu.com/lookup 2>&1 | grep -o '<TimeZone>[^<]*</TimeZone>'
echo "== installer state"; $API http://a/meta/status 2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k: d.get(k) for k in ("state","interactive")})'
echo "== GET /timezone: what the installer answers now"; $API http://a/timezone 2>&1; echo
echo "== time zone of the live system"; timedatectl 2>&1 | grep "Time zone" | sed 's/^ *//'
echo "== autoinstall file, timezone line"; sudo -n grep -n -E "^ *timezone" /autoinstall.yaml 2>&1
echo "== the helper's own line in the journal"; sudo -n journalctl -b --no-pager 2>/dev/null | grep -F "ci-os-auto-install: time zone" | sed "s/^.*ci-os-auto-install/ci-os-auto-install/" | tail -3
echo "== server log, lines about the time zone or geoip (hashes filtered)"; sudo -n grep -i -E "timezone|geoip|time zone" /var/log/installer/subiquity-server-debug.log 2>&1 | grep -v '\$6\$' | cut -c1-220 | tail -40
} > "$OUT" 2>&1
curl -s --data-binary @"$OUT" http://$H/up/$N >/dev/null
