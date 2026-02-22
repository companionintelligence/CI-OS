#!/usr/bin/env python3
"""
Pre-scan WiFi networks before starting the hotspot.
Run when the interface is up but NOT yet in AP mode - the only time we can scan
on single-radio chips (MediaTek MT7921, etc.) that cannot scan while in AP mode.

Usage: setup-device-prescan.py <interface>
Writes JSON to /var/lib/setup-device/last-scan.json
"""

import json
import subprocess
import sys
import time
from pathlib import Path

DATA_DIR = Path('/var/lib/setup-device')
SCAN_FILE = DATA_DIR / 'last-scan.json'


def scan_with_iw(iface: str) -> list[dict]:
    """Scan using iw (works when interface is up, not in AP mode). Only safe before AP starts."""
    try:
        time.sleep(2)  # Let interface settle after ip link up
        result = subprocess.run(
            ['iw', 'dev', iface, 'scan'],
            capture_output=True,
            text=True,
            timeout=15
        )
        if result.returncode != 0:
            return []
        return parse_iw_scan(result.stdout)
    except (subprocess.TimeoutExpired, FileNotFoundError, Exception):
        return []


def parse_iw_scan(output: str) -> list[dict]:
    """Parse 'iw dev X scan' output into network list."""
    networks = []
    seen = set()
    current = {}

    for line in output.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith('BSS '):
            if current.get('ssid') and current['ssid'] not in seen:
                networks.append(dict(current))
                seen.add(current['ssid'])
            current = {'ssid': '', 'signal': 0, 'security': 'none'}
        elif s.startswith('signal:'):
            try:
                current['signal'] = int(float(s.split()[1]))
            except (ValueError, IndexError):
                pass
        elif s.startswith('SSID:'):
            current['ssid'] = s[5:].strip() or '(hidden)'
        elif s.startswith('RSN:') or s.startswith('WPA:'):
            current['security'] = 'wpa-psk'  # Secured; portal will require password

    if current.get('ssid') and current['ssid'] not in seen:
        networks.append(current)
        seen.add(current['ssid'])

    # Sort by signal strength (higher dBm = better; -45 > -67)
    networks.sort(key=lambda x: x['signal'], reverse=True)
    return networks


def main():
    if len(sys.argv) < 2:
        print("Usage: setup-device-prescan.py <interface>", file=sys.stderr)
        sys.exit(1)

    iface = sys.argv[1]
    networks = scan_with_iw(iface)

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with open(SCAN_FILE, 'w') as f:
        json.dump({'networks': networks}, f, indent=2)

    sys.exit(0)


if __name__ == '__main__':
    main()
