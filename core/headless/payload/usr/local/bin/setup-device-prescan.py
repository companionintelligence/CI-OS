#!/usr/bin/env python3
"""
Pre-scan WiFi networks before starting the hotspot.
Run when the interface is up but NOT yet in AP mode - the only time we can scan
on single-radio chips (MediaTek MT7921, etc.) that cannot scan while in AP mode.

Usage: setup-device-prescan.py <interface>
Writes JSON to /var/lib/setup-device/last-scan.json
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

DATA_DIR = Path(os.environ.get('SETUP_DEVICE_ROOT') or '/') / 'var' / 'lib' / 'setup-device'
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


# Weakest signal there is: what a BSS that reports none sorts as. (The old default of 0 is the
# STRONGEST possible dBm value, so a line iw printed in a form we cannot read put its network first.)
NO_SIGNAL = -100

_HEX_ESCAPE = re.compile(r'\\x([0-9a-fA-F]{2})')


def decode_iw_ssid(raw: str):
    """Turn the SSID text of `iw scan` into the name a person types, or None for a hidden network.

    iw prints every byte that is not a printable ASCII character as \\xNN (so "café" arrives as
    caf\\xc3\\xa9, a backslash as \\x5c, and a hidden network as nothing at all or as a run of
    \\x00). The escapes are undone and the bytes read as UTF-8; a name that is not UTF-8 cannot be
    typed into the portal and is left out.
    """
    if not raw or not raw.strip():
        return None
    data = bytearray()
    pos = 0
    for match in _HEX_ESCAPE.finditer(raw):
        data.extend(raw[pos:match.start()].encode('utf-8'))
        data.append(int(match.group(1), 16))
        pos = match.end()
    data.extend(raw[pos:].encode('utf-8'))
    if not data or all(b == 0 for b in data):
        return None
    try:
        return data.decode('utf-8')
    except UnicodeDecodeError:
        return None


def classify_security(akms: set, has_rsn_or_wpa: bool, privacy: bool) -> str:
    """The label the portal uses to decide whether to ask for a password.

    wpa-psk     joinable with a passphrase (WPA/WPA2-PSK, also a WPA2/WPA3 transition network, which
                advertises PSK and SAE together)
    sae         WPA3-Personal only
    enterprise  802.1X: needs a user name and a certificate policy this portal does not collect
    owe         Enhanced Open (opportunistic encryption, no password)
    wep         pre-WPA; the Privacy capability bit is set and there is no RSN/WPA element
    none        open
    The old parser labelled everything with an RSN or WPA element wpa-psk, and WEP none.
    """
    if has_rsn_or_wpa:
        if 'psk' in akms:
            return 'wpa-psk'
        if 'sae' in akms:
            return 'sae'
        if 'ieee8021x' in akms:
            return 'enterprise'
        if 'owe' in akms:
            return 'owe'
        return 'wpa-psk'  # an element we cannot classify is still a secured network
    if privacy:
        return 'wep'
    return 'none'


def _akms_from_line(text: str) -> set:
    """Authentication suite names from the text after "Authentication suites:" (e.g. "PSK SAE",
    "IEEE 802.1X", "FT/PSK", "PSK/SHA-256", "OWE")."""
    akms = set()
    upper = text.upper()
    if '802.1X' in upper:
        akms.add('ieee8021x')
    if 'SAE' in upper:
        akms.add('sae')
    if 'OWE' in upper:
        akms.add('owe')
    if 'PSK' in upper:
        akms.add('psk')
    return akms


def parse_iw_scan(output: str) -> list[dict]:
    """Parse 'iw dev X scan' output into a network list: one entry per SSID, taken from the
    strongest BSS that advertises it, strongest first. Hidden networks are left out."""
    best = {}      # ssid -> entry of its strongest BSS so far
    current = None
    section = None  # 'rsn' / 'wpa' while inside that information element's bullet list

    def finish(bss):
        if bss is None or bss['ssid'] is None:
            return
        entry = {
            'ssid': bss['ssid'],
            'signal': bss['signal'],
            'security': classify_security(bss['akms'], bss['secured'], bss['privacy']),
        }
        known = best.get(entry['ssid'])
        if known is None or entry['signal'] > known['signal']:
            best[entry['ssid']] = entry

    for line in output.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith('BSS '):
            finish(current)
            current = {'ssid': None, 'signal': NO_SIGNAL, 'akms': set(), 'secured': False, 'privacy': False}
            section = None
            continue
        if current is None:
            continue
        if s.startswith('signal:'):
            try:
                current['signal'] = int(float(s.split()[1]))
            except (ValueError, IndexError):
                # Malformed or missing signal token on this line is expected for some
                # scan entries (some drivers print "52/100"); keep the weakest default.
                pass
            section = None
        elif s.startswith('SSID:'):
            current['ssid'] = decode_iw_ssid(s[5:].strip())
            section = None
        elif s.startswith('capability:'):
            current['privacy'] = 'Privacy' in s.split('(')[0].split()
            section = None
        elif s.startswith('RSN:') or s.startswith('WPA:'):
            current['secured'] = True
            section = 'rsn' if s.startswith('RSN:') else 'wpa'
            rest = s[4:].strip()
            if 'Authentication suites:' in rest:
                current['akms'] |= _akms_from_line(rest.split('Authentication suites:', 1)[1])
        elif section is not None and s.startswith('*'):
            if 'Authentication suites:' in s:
                current['akms'] |= _akms_from_line(s.split('Authentication suites:', 1)[1])
        else:
            section = None

    finish(current)

    networks = list(best.values())
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
