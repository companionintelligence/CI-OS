#!/bin/sh
# What `apt-get update` prints on the installed system, for the lines about Ubuntu Pro, ESM and news. Run as root: sudo -S sh -c '...' | sh -s NAME is not used;
# the guest types: sudo -S apt-get update > /tmp/ftue-apt-raw.txt 2>&1, then this script reads that file. POSTs to 10.0.2.2:8800.
H=10.0.2.2:8800
N=${1:-apt}
OUT=/tmp/ftue-$N.txt
{
echo "== date (UTC)"; date -u +%FT%TZ
echo "== lines of apt-get update"; wc -l < /tmp/ftue-apt-raw.txt
echo "== lines that mention Pro, ESM, news or Canonical's adverts (none expected)"; grep -i -E "ubuntu pro|esm|apt news|pro attach|ubuntu.com/pro|advantage" /tmp/ftue-apt-raw.txt || echo "(none)"
echo "== the last lines"; tail -n 8 /tmp/ftue-apt-raw.txt
} > "$OUT" 2>&1
if command -v curl >/dev/null 2>&1; then curl -s --data-binary @"$OUT" http://$H/up/$N >/dev/null
elif command -v wget >/dev/null 2>&1; then wget -q -O /dev/null --post-file="$OUT" http://$H/up/$N
fi
