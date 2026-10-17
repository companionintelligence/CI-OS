"""Tests for usr/local/bin/setup-device-prescan.py: the `iw dev X scan` parser (stdlib unittest).

R4 (report 02): the old parser kept the FIRST BSS of an SSID, called SAE, OWE and 802.1X networks "wpa-psk"
and WEP networks "none", and gave an unreadable signal the strongest possible value (0 dBm). The sample text
below follows the format of iw's output (it is written from the format, not captured from a chip: no
hardware here); every BSS block has the fields the parser reads, and the RSN/WPA blocks have the bullet layout
iw prints.

    python3 -B core/headless/tests/payload/test_prescan.py
"""
import json
import random
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import harness  # noqa: E402


def bss(mac, ssid, signal, akm=None, wpa_akm=None, privacy=False, freq=2437, signal_text=None):
    lines = [
        f'BSS {mac}(on wlan0)',
        '\tTSF: 123456789 usec (1d, 10:17:36)',
        f'\tfreq: {freq}',
        '\tbeacon interval: 100 TUs',
        '\tcapability: ESS %s(0x%04x)' % ('Privacy ShortSlotTime ' if privacy else 'ShortSlotTime ', 0x0411 if privacy else 0x0401),
        f'\tsignal: {signal_text or ("%.2f dBm" % signal)}',
        '\tlast seen: 120 ms ago',
        f'\tSSID: {ssid}',
        '\tSupported rates: 1.0* 2.0* 5.5* 11.0* 6.0 9.0 12.0 18.0',
        '\tDS Parameter set: channel 6',
    ]
    if akm is not None:
        lines += [
            '\tRSN:\t * Version: 1',
            '\t\t * Group cipher: CCMP',
            '\t\t * Pairwise ciphers: CCMP',
            f'\t\t * Authentication suites: {akm}',
            '\t\t * Capabilities: 1-PTKSA-RC 1-GTKSA-RC (0x0000)',
        ]
    if wpa_akm is not None:
        lines += [
            '\tWPA:\t * Version: 1',
            '\t\t * Group cipher: TKIP',
            '\t\t * Pairwise ciphers: TKIP CCMP',
            f'\t\t * Authentication suites: {wpa_akm}',
        ]
    lines += [
        '\tExtended capabilities:',
        '\t\t * HT Information Exchange Supported',
        '\t\t * Authentication suites: PSK',   # a decoy bullet outside any RSN/WPA element must be ignored
    ]
    return '\n'.join(lines) + '\n'


class ParseIwScanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p = harness.load_prescan()

    def parse(self, *blocks):
        return {n['ssid']: n for n in self.p.parse_iw_scan(''.join(blocks))}

    def test_security_labels(self):
        nets = self.parse(
            bss('aa:00:00:00:00:01', 'Wpa2Home', -50, akm='PSK'),
            bss('aa:00:00:00:00:02', 'Wpa2Ft', -51, akm='FT/PSK'),
            bss('aa:00:00:00:00:03', 'Wpa2Sha256', -52, akm='PSK/SHA-256'),
            bss('aa:00:00:00:00:04', 'Transition', -53, akm='PSK SAE'),
            bss('aa:00:00:00:00:05', 'Wpa3Only', -54, akm='SAE'),
            bss('aa:00:00:00:00:06', 'Wpa3Ft', -55, akm='FT/SAE'),
            bss('aa:00:00:00:00:07', 'CorpWifi', -56, akm='IEEE 802.1X'),
            bss('aa:00:00:00:00:08', 'CorpFt', -57, akm='FT/IEEE 802.1X'),
            bss('aa:00:00:00:00:09', 'CorpSha256', -58, akm='IEEE 802.1X/SHA-256'),
            bss('aa:00:00:00:00:0a', 'CafeOwe', -59, akm='OWE'),
            bss('aa:00:00:00:00:0b', 'Open', -60),
            bss('aa:00:00:00:00:0c', 'OldWep', -61, privacy=True),
            bss('aa:00:00:00:00:0d', 'OldWpa1', -62, wpa_akm='PSK', privacy=True),
        )
        expected = {
            'Wpa2Home': 'wpa-psk', 'Wpa2Ft': 'wpa-psk', 'Wpa2Sha256': 'wpa-psk', 'Transition': 'wpa-psk',
            'Wpa3Only': 'sae', 'Wpa3Ft': 'sae', 'CorpWifi': 'enterprise', 'CorpFt': 'enterprise',
            'CorpSha256': 'enterprise', 'CafeOwe': 'owe', 'Open': 'none', 'OldWep': 'wep', 'OldWpa1': 'wpa-psk',
        }
        self.assertEqual({k: v['security'] for k, v in nets.items()}, expected)

    def test_the_decoy_bullet_outside_an_rsn_element_is_ignored(self):
        nets = self.parse(bss('aa:00:00:00:00:01', 'Open', -50))
        self.assertEqual(nets['Open']['security'], 'none')

    def test_strongest_bss_wins_whatever_the_order(self):
        for blocks in (
            (bss('aa:00:00:00:00:01', 'Home', -80, akm='PSK'), bss('aa:00:00:00:00:02', 'Home', -40, akm='PSK')),
            (bss('aa:00:00:00:00:02', 'Home', -40, akm='PSK'), bss('aa:00:00:00:00:01', 'Home', -80, akm='PSK')),
        ):
            nets = self.p.parse_iw_scan(''.join(blocks))
            self.assertEqual(len(nets), 1)
            self.assertEqual(nets[0]['signal'], -40)

    def test_the_label_comes_from_the_strongest_bss(self):
        nets = self.parse(
            bss('aa:00:00:00:00:01', 'Mixed', -80, akm='PSK'),
            bss('aa:00:00:00:00:02', 'Mixed', -45, akm='SAE'),
        )
        self.assertEqual(nets['Mixed']['security'], 'sae')

    def test_sorted_strongest_first_and_one_entry_per_ssid(self):
        nets = self.p.parse_iw_scan(''.join([
            bss('aa:00:00:00:00:01', 'B', -70, akm='PSK'), bss('aa:00:00:00:00:02', 'A', -30, akm='PSK'),
            bss('aa:00:00:00:00:03', 'C', -55), bss('aa:00:00:00:00:04', 'C', -56)]))
        self.assertEqual([n['ssid'] for n in nets], ['A', 'C', 'B'])

    def test_hidden_networks_are_left_out(self):
        nets = self.parse(
            bss('aa:00:00:00:00:01', '', -50, akm='PSK'),
            bss('aa:00:00:00:00:02', r'\x00\x00\x00\x00', -51, akm='PSK'),
            bss('aa:00:00:00:00:03', 'Visible', -52, akm='PSK'),
        )
        self.assertEqual(list(nets), ['Visible'])

    def test_escaped_ssids_are_decoded(self):
        nets = self.parse(
            bss('aa:00:00:00:00:01', r'caf\xc3\xa9', -50, akm='PSK'),
            bss('aa:00:00:00:00:02', r'back\x5cslash', -51, akm='PSK'),
            bss('aa:00:00:00:00:03', r'\x20padded\x20', -52, akm='PSK'),
            bss('aa:00:00:00:00:04', r'not\xffutf8', -53, akm='PSK'),
        )
        self.assertEqual(set(nets), {'café', 'back\\slash', ' padded '})

    def test_an_unreadable_signal_is_the_weakest_not_the_strongest(self):
        nets = self.p.parse_iw_scan(''.join([
            bss('aa:00:00:00:00:01', 'Strange', 0, akm='PSK', signal_text='52/100'),
            bss('aa:00:00:00:00:02', 'Normal', -90, akm='PSK'),
        ]))
        self.assertEqual([n['ssid'] for n in nets], ['Normal', 'Strange'])

    def test_empty_and_garbage_input(self):
        self.assertEqual(self.p.parse_iw_scan(''), [])
        self.assertEqual(self.p.parse_iw_scan('not iw output\nSSID: orphan\nsignal: -40.00 dBm\n'), [])

    def test_fuzz_never_crashes_and_keeps_its_invariants(self):
        rnd = random.Random(7)
        pieces = ['BSS aa:bb:cc:dd:ee:ff(on wlan0)', '\tsignal: -42.00 dBm', '\tsignal: x', '\tSSID: Net', '\tSSID: ',
                  '\tSSID: \\x00\\x00', '\tcapability: ESS Privacy (0x0011)', '\tRSN:\t * Version: 1',
                  '\t\t * Authentication suites: PSK', '\t\t * Authentication suites: SAE', '\t\t * Authentication suites: IEEE 802.1X',
                  '\tWPA:\t * Version: 1', '\tExtended capabilities:', '\t\t * foo', '', 'junk', '\tSSID: \\xc3\\xa9', '\tSSID: \\xff']
        labels = {'wpa-psk', 'sae', 'enterprise', 'owe', 'wep', 'none'}
        for _ in range(5000):
            text = '\n'.join(rnd.choice(pieces) for _ in range(rnd.randint(0, 25)))
            nets = self.p.parse_iw_scan(text)
            ssids = [n['ssid'] for n in nets]
            self.assertEqual(len(ssids), len(set(ssids)))
            self.assertEqual([n['signal'] for n in nets], sorted((n['signal'] for n in nets), reverse=True))
            for n in nets:
                self.assertIn(n['security'], labels)
                self.assertTrue(n['ssid'])
                self.assertIsInstance(n['signal'], int)
                json.dumps(n)


if __name__ == '__main__':
    unittest.main(verbosity=2)
