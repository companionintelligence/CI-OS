"""Regression tests for core/headless/payload/opt/setup-backend/setup_service.py (stdlib unittest, no network).

Each class names the finding it guards (report 02: S4, L7, I1, I2, I3, I4, I8, H2, U1) and, where the discovery
agent had a harness check (C1-C8), says which. The real service runs against a scratch root with a fake
subprocess (harness.py); with Flask missing, standin/flask.py stands in (the run prints which).

    python3 -B core/headless/tests/payload/test_setup_service.py
"""
import ast
import io
import json
import os
import random
import re
import signal
import stat
import sys
import tempfile
import unittest
import urllib.error
import warnings
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import harness  # noqa: E402
from harness import FakeHTTPResponse, loaded_service, remove_scratch  # noqa: E402

CANARY_PSK = 'Canary-PSK-7f3a9c'
CANARY_CODE = 'ZX81QK'
CANARY_API_KEY = 'ak_live_canary_4242'
CANARY_TUNNEL = 'tt_canary_9191'
JSON = {'Accept': 'application/json'}


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


class ValidatorTests(unittest.TestCase):
    """I1 / C7: SSID 1-32 BYTES without control characters; WPA PSK 8-63 printable ASCII or 64 hex."""

    @classmethod
    def setUpClass(cls):
        cls._ctx = loaded_service()
        cls.svc = cls._ctx.__enter__()
        cls.m = cls.svc.module

    @classmethod
    def tearDownClass(cls):
        cls._ctx.__exit__(None, None, None)

    def ssid_ok(self, s):
        try:
            self.m.validate_ssid(s)
            return True
        except self.m.InvalidInput:
            return False

    def psk_ok(self, s):
        try:
            self.m.validate_psk(s)
            return True
        except self.m.InvalidInput:
            return False

    def test_ssid_accepts(self):
        for s in ['a', 'x' * 32, 'café', '\U0001f600' * 8, 'My Wi-Fi 5G', ' leading', 'trailing ', '-dash', '--help', 'a:b', 'a\\b', "it's"]:
            with self.subTest(ssid=s):
                self.assertTrue(self.ssid_ok(s))

    def test_ssid_rejects(self):
        cases = {
            'empty': '', '33 bytes': 'x' * 33, 'nine 4-byte emoji = 36 bytes': '\U0001f600' * 9,
            'newline': 'a\nb', 'NUL': 'a\x00b', 'ESC': '\x1b[31mred', 'DEL': 'a\x7fb', 'C1 control (NEL)': 'a\u0085b',
            'line separator': 'a b', 'paragraph separator': 'a b', 'tab': 'a\tb', 'lone surrogate': '\ud800',
        }
        for label, s in cases.items():
            with self.subTest(case=label):
                self.assertFalse(self.ssid_ok(s))
        for bad in [None, 5, b'abc', ['a'], {'a': 1}]:
            with self.subTest(type=type(bad).__name__):
                self.assertFalse(self.ssid_ok(bad))

    def test_ssid_length_is_in_bytes_not_characters(self):
        self.assertEqual(len('\U0001f600' * 9), 9)       # 9 characters ...
        self.assertFalse(self.ssid_ok('\U0001f600' * 9))   # ... but 36 bytes
        self.assertTrue(self.ssid_ok('\U0001f600' * 8))    # 32 bytes exactly

    def test_psk_accepts(self):
        for s in ['12345678', 'p' * 63, '0' * 64, 'a' * 64, 'AbCdEf0123' * 6 + 'abcd', 'with spaces are ok 1', '!"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~']:
            with self.subTest(psk=s[:20]):
                self.assertTrue(self.psk_ok(s))

    def test_psk_rejects(self):
        cases = {
            '7 characters': '1234567', 'empty': '', '64 non-hex': 'p' * 64, '65 hex': '0' * 65, '64 chars with a g': '0' * 63 + 'g',
            'non-ASCII': 'pässwörd1', 'newline': 'pass\nword1', 'tab': 'pass\tword1', 'DEL': 'password\x7f', 'NUL': 'password\x00',
            'emoji': 'password\U0001f600',
        }
        for label, s in cases.items():
            with self.subTest(case=label):
                self.assertFalse(self.psk_ok(s))
        for bad in [None, 12345678, b'password1']:
            with self.subTest(type=type(bad).__name__):
                self.assertFalse(self.psk_ok(bad))

    def test_error_messages_do_not_echo_the_value(self):
        for fn, value in ((self.m.validate_ssid, 'x' * 40), (self.m.validate_psk, 'short')):
            with self.assertRaises(self.m.InvalidInput) as ctx:
                fn(value)
            self.assertNotIn(value, str(ctx.exception))

    # --- property test against an independently written oracle (the discovery run did 200 000 cases in 1.2 s) ----------
    @staticmethod
    def oracle_ssid(s):
        try:
            raw = s.encode('utf-8')
        except UnicodeEncodeError:
            return False
        if not 1 <= len(raw) <= 32:
            return False
        for ch in s:
            cp = ord(ch)
            if cp < 0x20 or 0x7f <= cp <= 0x9f or cp in (0x2028, 0x2029):
                return False
        return True

    @staticmethod
    def oracle_psk(s):
        if len(s) == 64 and all(c in '0123456789abcdefABCDEF' for c in s):
            return True
        return 8 <= len(s) <= 63 and all(0x20 <= ord(c) <= 0x7e for c in s)

    def test_fuzz_200k_cases_agree_with_the_oracle(self):
        rnd = random.Random(20261017)
        alphabet = ('abcXYZ019 -_.:;,\'"`$(){}[]|&<>%\\/\n\r\t\x00\x1b\x7f\x85'
                    'é€\U0001f600​  \ud800')
        hexdigits = '0123456789abcdefABCDEF'
        accepted_ssid = accepted_psk = 0
        for i in range(200_000):
            n = rnd.randint(0, 70)
            if i % 7 == 0:
                s = ''.join(rnd.choice(hexdigits) for _ in range(rnd.choice([63, 64, 64, 65])))
            else:
                s = ''.join(rnd.choice(alphabet) for _ in range(n))
            a = self.ssid_ok(s)
            b = self.psk_ok(s)
            self.assertEqual(a, self.oracle_ssid(s), repr(s))
            self.assertEqual(b, self.oracle_psk(s), repr(s))
            accepted_ssid += a
            accepted_psk += b
        # the generator really exercised both outcomes
        self.assertGreater(accepted_ssid, 1000)
        self.assertGreater(accepted_psk, 1000)


class ProfileDeletionTests(unittest.TestCase):
    """S4 / C3: only Wi-Fi profiles this service created (prefix + exact name) are ever deleted."""

    def setUp(self):
        self._ctx = loaded_service()
        self.svc = self._ctx.__enter__()
        self.m = self.svc.module
        self.sys = self.svc.system
        self.sys.profiles = [
            {'name': 'Wired connection 1', 'uuid': 'u-wired1', 'type': '802-3-ethernet'},
            {'name': 'Wired connection 1 2', 'uuid': 'u-wired2', 'type': '802-3-ethernet'},
            {'name': 'ci-setup-HomeWifi', 'uuid': 'u-own', 'type': '802-11-wireless'},
            {'name': 'HomeWifi', 'uuid': 'u-user', 'type': '802-11-wireless'},
            {'name': 'ci-setup-HomeWifi', 'uuid': 'u-own-but-wired', 'type': '802-3-ethernet'},
            {'name': 'tailscale0', 'uuid': 'u-vpn', 'type': 'wireguard'},
            {'name': 'ci-setup-Other', 'uuid': 'u-other', 'type': '802-11-wireless'},
            {'name': 'ci-setup-HomeWifi 1', 'uuid': 'u-variant', 'type': '802-11-wireless'},
        ]

    def tearDown(self):
        self._ctx.__exit__(None, None, None)

    def deleted(self):
        return [c.argv[-1] for c in self.sys.calls if c.argv[:3] == ['nmcli', 'connection', 'delete']]

    def test_only_the_own_wifi_profile_of_that_ssid_is_deleted(self):
        self.assertEqual(self.m.delete_owned_wifi_profiles('HomeWifi'), ['u-own'])
        self.assertEqual(self.deleted(), ['u-own'])
        left = {p['uuid'] for p in self.sys.profiles}
        for kept in ('u-wired1', 'u-wired2', 'u-user', 'u-own-but-wired', 'u-vpn', 'u-other', 'u-variant'):
            self.assertIn(kept, left)

    def test_posting_a_wired_profile_name_as_ssid_deletes_nothing(self):
        # C3 exactly: the old code deleted 'Wired connection 1' and 'Wired connection 1 2' for this SSID.
        self.assertEqual(self.m.delete_owned_wifi_profiles('Wired connection 1'), [])
        self.assertEqual(self.deleted(), [])

    def test_keep_uuid_is_never_deleted(self):
        self.assertEqual(self.m.delete_owned_wifi_profiles('HomeWifi', keep_uuid='u-own'), [])

    def test_the_listing_asks_for_the_type(self):
        self.m.delete_owned_wifi_profiles('HomeWifi')
        listing = [c.argv for c in self.sys.calls if c.argv[:2] == ['nmcli', '-t']][0]
        self.assertIn('NAME,UUID,TYPE', listing)

    def test_escaped_colons_and_backslashes_in_names(self):
        self.sys.profiles = [
            {'name': 'ci-setup-A:B', 'uuid': 'u-colon', 'type': '802-11-wireless'},
            {'name': 'ci-setup-C\\', 'uuid': 'u-backslash', 'type': '802-11-wireless'},
            {'name': 'ci-setup-A', 'uuid': 'u-prefix', 'type': '802-11-wireless'},
        ]
        self.assertEqual(self.m.delete_owned_wifi_profiles('A:B'), ['u-colon'])
        self.assertEqual(self.m.delete_owned_wifi_profiles('C\\'), ['u-backslash'])

    def test_terse_field_splitting(self):
        split = self.m._split_nmcli_t_fields
        self.assertEqual(split('a:b:c'), ['a', 'b', 'c'])
        self.assertEqual(split('a\\:b:c'), ['a:b', 'c'])
        self.assertEqual(split('a\\\\:b'), ['a\\', 'b'])          # escaped backslash, then a real separator
        self.assertEqual(split('a\\\\\\:b:c'), ['a\\:b', 'c'])
        self.assertEqual(split(''), [''])

    def test_end_to_end_through_the_route(self):
        client = self.svc.client()
        r = client.post('/api/configure', json={'ssid': 'Wired connection 1', 'password': 'password12'}, headers=JSON)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.deleted(), [])
        self.assertIn('u-wired1', {p['uuid'] for p in self.sys.profiles})

    def test_the_new_profile_is_created_before_the_old_one_is_removed_and_survives(self):
        self.svc.client().post('/api/configure', json={'ssid': 'HomeWifi', 'password': 'password12'}, headers=JSON)
        lines = self.sys.lines()
        add = next(i for i, l in enumerate(lines) if l.startswith('nmcli connection add'))
        delete = next(i for i, l in enumerate(lines) if l.startswith('nmcli connection delete'))
        self.assertLess(add, delete)
        own = [p for p in self.sys.profiles if p['name'] == 'ci-setup-HomeWifi' and p['type'] == '802-11-wireless']
        self.assertEqual(len(own), 1, 'exactly one profile of ours for the network is left')
        self.assertNotEqual(own[0]['uuid'], 'u-own', 'and it is the new one, not the old one')
        up = [c for c in self.sys.calls if c.argv[:3] == ['nmcli', 'connection', 'up']][0]
        self.assertEqual(up.argv[4], own[0]['uuid'], 'the profile that is activated is the one that survived')


class ConfigureRequestHandlingTests(unittest.TestCase):
    """L7 / C5: malformed bodies are a 400 with no side effects; an error never restarts the access point."""

    def setUp(self):
        self._ctx = loaded_service()
        self.svc = self._ctx.__enter__()
        self.m = self.svc.module
        self.sys = self.svc.system
        self.client = self.svc.client()
        self.hotspot_runs = []
        self.m._run_script = lambda argv, timeout: self.hotspot_runs.append(argv) or 0

    def tearDown(self):
        self._ctx.__exit__(None, None, None)

    def assertNoSideEffects(self):
        self.assertEqual(self.sys.lines(), [], 'a rejected request must not run any command')
        self.assertEqual(self.hotspot_runs, [], 'a rejected request must not touch the access point')
        self.assertFalse(self.m._configure_lock.locked(), 'the radio lock must be released')
        self.assertFalse((Path(self.m.DATA_DIR) / 'credentials.json').exists())

    def test_malformed_json_is_400_and_has_no_side_effects(self):
        r = self.client.post('/api/configure', data=b'{"ssid": ', content_type='application/json')
        self.assertEqual(r.status_code, 400)
        self.assertNoSideEffects()

    def test_json_that_is_not_an_object_is_400(self):
        for body in (b'[1,2]', b'"text"', b'42', b'null'):
            with self.subTest(body=body):
                r = self.client.post('/api/configure', data=body, content_type='application/json')
                self.assertEqual(r.status_code, 400)
                self.assertNoSideEffects()

    def test_empty_bodies_are_400(self):
        self.assertEqual(self.client.post('/api/configure', json={}).status_code, 400)
        self.assertEqual(self.client.post('/api/configure', data={}).status_code, 400)
        self.assertNoSideEffects()

    def test_invalid_ssid_and_psk_are_400_without_side_effects_and_without_echo(self):
        bad = [
            {'ssid': 'x' * 33, 'password': 'password12'},
            {'ssid': '\U0001f600' * 9, 'password': 'password12'},
            {'ssid': 'ab\ncd', 'password': 'password12'},
            {'ssid': '', 'password': 'password12'},
            {'password': 'password12'},
            {'ssid': 'Net', 'password': 'short'},
            {'ssid': 'Net', 'password': 'p' * 64},
            {'ssid': 'Net', 'password': 'pässwörd1'},
            {'ssid': 123, 'password': 'password12'},
            {'ssid': 'Net', 'password': ['password12']},
            {'ssid': 'Net', 'password': 'password12', 'pairing_code': 'X' * 65},
        ]
        for payload in bad:
            with self.subTest(payload=str(payload)[:60]):
                r = self.client.post('/api/configure', json=payload, headers=JSON)
                self.assertEqual(r.status_code, 400)
                self.assertNotIn('password12', r.text)
                self.assertNoSideEffects()

    def test_form_encoded_requests_are_validated_too(self):
        r = self.client.post('/api/configure', data={'ssid': 'Net', 'password': 'short'}, headers=JSON)
        self.assertEqual(r.status_code, 400)
        self.assertNoSideEffects()

    def test_an_error_inside_the_flow_does_not_restart_the_access_point(self):
        def boom(*_a, **_k):
            raise RuntimeError('simulated failure in the middle of configure()')
        self.m.create_wifi_connection = boom
        r = self.client.post('/api/configure', json={'ssid': 'Net', 'password': 'password12'}, headers=JSON)
        self.assertEqual(r.status_code, 500)
        self.assertEqual(self.hotspot_runs, [], 'the start script must not run from configure()\'s error path')
        self.assertFalse(any('hotspot-start' in l for l in self.sys.lines()))
        self.assertFalse(self.m._configure_lock.locked())

    def test_a_failure_after_the_hotspot_was_stopped_does_restore_it(self):
        # The one legitimate restart: _connect_and_pair took the access point down and then failed.
        def boom(timeout=20):
            raise RuntimeError('boom after stop')
        self.m.stop_hotspot_services = lambda: None
        self.m.wait_for_networkmanager_ready = boom
        with self.svc.module.app.app_context():
            result = self.m._connect_and_pair('Net', 'password12', '', 'uuid-1', False, {}, True)
        self.assertEqual(result[1], 500)
        self.assertEqual([a for a in self.hotspot_runs if a[-1] != 'stop'], [[self.m.HOTSPOT_SCRIPT]])

    def test_a_failure_before_the_hotspot_was_stopped_does_not_restart_it(self):
        def boom():
            raise RuntimeError('boom before stop')
        self.m.clear_pairing_failure = boom
        with self.svc.module.app.app_context():
            result = self.m._connect_and_pair('Net', 'password12', '', 'uuid-1', False, {}, True)
        self.assertEqual(result[1], 500)
        self.assertEqual(self.hotspot_runs, [])

    def test_oversized_bodies_are_refused_before_parsing(self):
        r = self.client.post('/api/configure', data=b'{"ssid":"' + b'x' * 70000 + b'"}', content_type='application/json')
        self.assertEqual(r.status_code, 413)
        self.assertNoSideEffects()

    def test_a_second_submit_while_the_first_owns_the_radio_is_409(self):
        self.m._configure_lock.acquire()
        try:
            r = self.client.post('/api/configure', json={'ssid': 'Net', 'password': 'password12'}, headers=JSON)
        finally:
            self.m._configure_lock.release()
        self.assertEqual(r.status_code, 409)
        self.assertEqual(self.sys.lines(), [])

    def test_stop_and_start_helpers_use_the_script_modes(self):
        self.m.stop_hotspot_services()
        self.assertEqual(self.hotspot_runs, [[self.m.HOTSPOT_SCRIPT, 'stop']])
        self.m.start_hotspot_services()
        self.assertEqual(self.hotspot_runs[-1], [self.m.HOTSPOT_SCRIPT])

    def test_stop_falls_back_to_the_units_when_the_script_is_missing(self):
        def missing(argv, timeout):
            raise FileNotFoundError(argv[0])
        self.m._run_script = missing
        self.assertTrue(self.m.stop_hotspot_services())
        self.assertEqual(
            [l for l in self.sys.lines() if l.startswith('systemctl stop')],
            ['systemctl stop dnsmasq-setup.service', 'systemctl stop hostapd-setup.service'])


class RunScriptTests(unittest.TestCase):
    """_run_script gives a script SIGTERM (so its cleanup trap runs) before it resorts to SIGKILL on a timeout."""

    @unittest.skipIf(os.name != 'posix', 'POSIX signals')
    def test_timeout_sends_sigterm_first(self):
        with loaded_service(real_subprocess=True, real_time=True) as svc:
            scratch = Path(tempfile.mkdtemp(prefix='setup-service-test-script-'))
            try:
                marker = scratch / 'got-term'
                script = scratch / 'slow.sh'
                script.write_text(f'#!/bin/bash\ntrap \'echo term > "{marker}"; exit 0\' TERM\nsleep 30 &\nwait\n')
                script.chmod(0o755)
                with self.assertRaises(svc.module.subprocess.TimeoutExpired):
                    svc.module._run_script([str(script)], timeout=0.5)
                self.assertTrue(marker.exists(), 'the script must have been asked to stop (SIGTERM), not killed')
            finally:
                remove_scratch(scratch)


class PskNeverOnTheCommandLineTests(unittest.TestCase):
    """I2 / C4: the passphrase reaches nmcli through its passwd-file, never through argv."""

    def setUp(self):
        self._ctx = loaded_service()
        self.svc = self._ctx.__enter__()
        self.m = self.svc.module
        self.sys = self.svc.system
        self.client = self.svc.client()
        self.m._run_script = lambda argv, timeout: 0

    def tearDown(self):
        self._ctx.__exit__(None, None, None)

    def configure(self, **extra):
        payload = {'ssid': 'HomeNet', 'password': CANARY_PSK}
        payload.update(extra)
        return self.client.post('/api/configure', json=payload, headers=JSON)

    def test_secret_is_in_no_argv(self):
        r = self.configure()
        self.assertEqual(r.status_code, 200)
        for call in self.sys.calls:
            for arg in call.argv:
                self.assertNotIn(CANARY_PSK, str(arg), call.line)
        self.assertFalse(any('wifi-sec.psk' in l for l in self.sys.lines()))

    def test_profile_is_created_with_key_management_but_no_secret(self):
        self.configure()
        add = self.sys.find('nmcli connection add')[0].argv
        self.assertIn('wifi-sec.key-mgmt', add)
        self.assertEqual(add[add.index('wifi-sec.key-mgmt') + 1], 'wpa-psk')
        self.assertEqual(add[add.index('con-name') + 1], 'ci-setup-HomeNet')

    def test_activation_gets_the_secret_through_a_private_passwd_file(self):
        self.configure()
        up = [c for c in self.sys.calls if c.argv[:3] == ['nmcli', 'connection', 'up']][0]
        self.assertIn('passwd-file', up.argv)
        self.assertEqual(up.extra['passwd_file_text'], f'802-11-wireless-security.psk:{CANARY_PSK}\n')
        self.assertEqual(up.extra['passwd_file_mode'], 0o600)
        self.assertEqual(up.extra['passwd_dir_mode'], 0o700)

    def test_the_passwd_file_is_gone_afterwards(self):
        self.configure()
        up = [c for c in self.sys.calls if c.argv[:3] == ['nmcli', 'connection', 'up']][0]
        self.assertFalse(Path(up.argv[up.argv.index('passwd-file') + 1]).exists())
        self.assertEqual([p.name for p in Path(self.m.RUN_DIR).glob('.passwd.*')], [])

    def test_the_passwd_file_is_gone_even_when_nmcli_fails(self):
        self.sys.up_status = (4, '', 'Error: Connection activation failed')
        with self.m._passwd_file(CANARY_PSK) as path:
            self.assertTrue(Path(path).exists())
        self.assertFalse(Path(path).exists())
        with self.assertRaises(RuntimeError):
            with self.m._passwd_file(CANARY_PSK) as path2:
                raise RuntimeError('x')
        self.assertFalse(Path(path2).exists())

    def test_open_network_needs_no_secret_and_no_passwd_file(self):
        r = self.client.post('/api/configure', json={'ssid': 'CafeOpen'}, headers=JSON)
        self.assertEqual(r.status_code, 200)
        up = [c for c in self.sys.calls if c.argv[:3] == ['nmcli', 'connection', 'up']][0]
        self.assertNotIn('passwd-file', up.argv)
        add = self.sys.find('nmcli connection add')[0].argv
        self.assertEqual(add[add.index('wifi-sec.key-mgmt') + 1], 'none')

    def test_a_passphrase_that_networkmanager_did_not_keep_is_reported(self):
        self.sys.psk_stored = False
        r = self.configure()
        self.assertEqual(r.status_code, 200)
        text = self.svc.log_text()
        self.assertIn('did not store the passphrase', text)
        self.assertNotIn(CANARY_PSK, text)

    def test_a_stored_passphrase_is_not_a_warning(self):
        self.configure()
        self.assertNotIn('did not store the passphrase', self.svc.log_text())

    def test_the_read_back_never_puts_the_secret_on_a_command_line(self):
        self.configure()
        readback = [c for c in self.sys.calls if '--show-secrets' in c.argv]
        self.assertEqual(len(readback), 1)
        self.assertNotIn(CANARY_PSK, readback[0].line)

    def test_missing_secrets_is_reported_as_such(self):
        self.sys.up_status = (4, '', 'Error: Connection activation failed: Secrets were required, but not provided. No secrets')
        connected, reason = self.m.connect_to_wifi('uuid-1', use_uuid=True, password=CANARY_PSK)
        self.assertEqual((connected, reason), (False, 'missing-secrets'))


class SecretFileTests(unittest.TestCase):
    """I3: credentials.json and the other secret files are root-only from the first byte and replaced atomically."""

    def setUp(self):
        self._ctx = loaded_service()
        self.svc = self._ctx.__enter__()
        self.m = self.svc.module
        self.dir = Path(tempfile.mkdtemp(prefix='secret-files-'))

    def tearDown(self):
        self._ctx.__exit__(None, None, None)
        remove_scratch(self.dir)

    def test_new_file_is_0600_and_holds_the_text(self):
        target = self.dir / 'credentials.json'
        self.m._write_secret_file(target, '{"a": 1}\n')
        self.assertEqual(mode(target), 0o600)
        self.assertEqual(target.read_text(), '{"a": 1}\n')

    def test_the_temporary_file_is_created_0600_not_narrowed_afterwards(self):
        target = self.dir / 'credentials.json'
        seen = {}
        real_replace = os.replace
        real_open = os.open

        def open_spy(path, flags, mode_=0o777, *a, **k):
            if '.tmp' in str(path):
                seen['create_mode'] = mode_
                seen['flags'] = flags
            return real_open(path, flags, mode_, *a, **k)

        def replace_spy(src, dst):
            seen['mode'] = mode(src)
            seen['text'] = Path(src).read_text()
            return real_replace(src, dst)
        with mock.patch.object(self.m.os, 'replace', replace_spy), mock.patch.object(self.m.os, 'open', open_spy):
            self.m._write_secret_file(target, 'secret')
        self.assertEqual(seen['create_mode'], 0o600, 'the file must be created root-only, not chmod-ed after a 0644 window')
        self.assertTrue(seen['flags'] & os.O_EXCL, 'O_EXCL: never write through an existing file or symlink')
        self.assertEqual(seen['mode'], 0o600)
        self.assertEqual(seen['text'], 'secret')

    def test_a_failed_write_leaves_the_old_file_intact_and_no_temporary_files(self):
        target = self.dir / 'credentials.json'
        target.write_text('old content')
        target.chmod(0o644)
        with mock.patch.object(self.m.os, 'replace', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.m._write_secret_file(target, 'NEW')
        self.assertEqual(target.read_text(), 'old content')
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ['credentials.json'])

    def test_an_existing_0644_file_ends_up_0600(self):
        target = self.dir / 'credentials.json'
        target.write_text('old')
        target.chmod(0o644)
        self.m._write_secret_file(target, 'new')
        self.assertEqual(mode(target), 0o600)

    def test_a_symlink_at_the_target_is_replaced_not_followed(self):
        victim = self.dir / 'victim'
        victim.write_text('untouched')
        target = self.dir / 'credentials.json'
        target.symlink_to(victim)
        self.m._write_secret_file(target, 'secret')
        self.assertEqual(victim.read_text(), 'untouched')
        self.assertFalse(target.is_symlink())
        self.assertEqual(target.read_text(), 'secret')

    def test_configure_writes_credentials_json_0600(self):
        self.m._run_script = lambda argv, timeout: 0
        r = self.svc.client().post('/api/configure', json={'ssid': 'HomeNet', 'password': CANARY_PSK}, headers=JSON)
        self.assertEqual(r.status_code, 200)
        creds = Path(self.m.CREDENTIALS_JSON)
        self.assertEqual(mode(creds), 0o600)
        self.assertEqual(json.loads(creds.read_text())['ssid'], 'HomeNet')
        self.assertEqual([p.name for p in creds.parent.glob('.*.tmp')], [])

    def test_pairing_code_file_and_failure_record_are_private(self):
        self.svc.client().get('/api/health')          # first request creates the local pairing code
        self.assertEqual(mode(self.m.PAIRING_CODE_JSON), 0o600)
        self.m.record_pairing_failure('X', 'could not join "Net"')
        self.assertEqual(mode(self.m.LAST_PAIRING_ERROR_JSON), 0o600)

    def test_the_secret_registry_forgets_the_oldest_first_not_everything(self):
        keep = 'newest-secret-value'
        self.m._register_secret('oldest-secret-value')
        for i in range(self.m._MAX_REGISTERED_SECRETS + 5):
            self.m._register_secret(f'filler-secret-{i:04d}')
        self.m._register_secret(keep)
        self.assertEqual(len(self.m._REGISTERED_SECRETS), self.m._MAX_REGISTERED_SECRETS)
        self.assertIn(keep, self.m._REGISTERED_SECRETS)
        self.assertIn(f'filler-secret-{self.m._MAX_REGISTERED_SECRETS + 4:04d}', self.m._REGISTERED_SECRETS)
        self.assertNotIn('oldest-secret-value', self.m._REGISTERED_SECRETS)


class LogHygieneTests(unittest.TestCase):
    """I4 / C6: no pairing code, passphrase, API key, tunnel token or raw cloud body in the log; the log is 0600."""

    def setUp(self):
        warnings.simplefilter('ignore', ResourceWarning)    # the fake HTTPError body is not closed
        self._ctx = loaded_service()
        self.svc = self._ctx.__enter__()
        self.m = self.svc.module
        self.sys = self.svc.system
        self.m._run_script = lambda argv, timeout: 0
        self.sys.launcher_running = True            # the Launcher runs: pairing is required
        self.requests = []

    def tearDown(self):
        self._ctx.__exit__(None, None, None)

    def urlopen(self, req, timeout=None):
        url = req.full_url if hasattr(req, 'full_url') else str(req)
        self.requests.append((req.get_method(), url))
        if url.endswith('/api/registration/status'):
            return FakeHTTPResponse({'registered': False})
        if 'registration/device-id' in url:
            return FakeHTTPResponse({'callback_url': 'http://127.0.0.1:5002/cb?state=nonce123456'})
        if 'registration/callback' in url:
            return FakeHTTPResponse({'success': True})
        if '/api/devices/pair' in url and req.get_method() == 'GET':
            if self.cloud_error:
                raise urllib.error.HTTPError(url, 500, 'boom', {}, io.BytesIO(
                    json.dumps({'error': f'bad {CANARY_CODE}', 'api_key': CANARY_API_KEY}).encode()))
            return FakeHTTPResponse({'deviceId': 'cloud-dev-1', 'pairingCode': CANARY_CODE})
        if '/api/devices/pair' in url and req.get_method() == 'POST':
            return FakeHTTPResponse({
                'device_id': 'local-dev-1', 'organization_id': 'o1', 'organization_name': 'Org', 'slug': 's',
                'subdomain': 'sub', 'tunnel_id': 't1', 'tunnel_token': CANARY_TUNNEL, 'api_key': CANARY_API_KEY,
                'domain': 'example.ci.computer'})
        raise AssertionError(f'unexpected request {url}')

    cloud_error = False

    def run_pairing(self):
        # The log's safety net (the scrubbing formatter) is switched off for these checks: they prove the code does not
        # LOG the secrets. With the net on, a log statement that leaked would be masked and the test could not see it.
        # (test_the_safety_net_... below proves the net separately.)
        with mock.patch.object(self.m.urllib.request, 'urlopen', self.urlopen), \
                mock.patch.object(self.m, '_scrub', lambda text: text):
            client = self.svc.client()
            return client.post('/api/configure', json={
                'ssid': 'HomeNet', 'password': CANARY_PSK, 'pairing_code': CANARY_CODE}, headers=JSON)

    def assertNoCanaries(self, text, where):
        for label, canary in (('passphrase', CANARY_PSK), ('pairing code', CANARY_CODE),
                              ('api key', CANARY_API_KEY), ('tunnel token', CANARY_TUNNEL)):
            self.assertNotIn(canary, text, f'{label} found in {where}')

    def test_a_full_pairing_flow_leaves_no_secret_in_the_log_or_on_stdout(self):
        r = self.run_pairing()
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(any('/api/devices/pair' in u for _m, u in self.requests), 'the pairing flow did not run')
        self.assertNoCanaries(self.svc.log_text(), 'the log file')
        self.assertNoCanaries(self.svc.stdout.getvalue(), 'stdout (the journal)')

    def test_the_local_pairing_code_is_not_logged(self):
        with mock.patch.object(self.m, '_scrub', lambda text: text):
            self.svc.client().get('/api/health')
        local_code = json.loads(Path(self.m.PAIRING_CODE_JSON).read_text())['code']
        self.assertRegex(local_code, r'^[A-Z0-9]{6}$')
        self.assertNotIn(local_code, self.svc.log_text())

    def test_cloud_error_bodies_are_not_logged(self):
        self.cloud_error = True
        self.run_pairing()
        text = self.svc.log_text()
        self.assertNoCanaries(text, 'the log after a cloud error')
        self.assertIn('HTTP Error 500', text)          # the status is still there; the body is not

    def test_the_log_file_is_private(self):
        self.assertEqual(mode(self.svc.log_path), 0o600)

    def test_an_older_world_readable_log_is_narrowed_at_start(self):
        # an existing 0644 file from a previous version
        root = Path(tempfile.mkdtemp(prefix='oldlog-'))
        try:
            (root / 'var' / 'log').mkdir(parents=True)
            old = root / 'var' / 'log' / 'setup-backend.log'
            old.write_text('previous run\n')
            old.chmod(0o644)
            saved = os.environ.get('SETUP_DEVICE_ROOT')
            os.environ['SETUP_DEVICE_ROOT'] = str(root)
            try:
                import importlib.util
                spec = importlib.util.spec_from_file_location('ss_oldlog', str(harness.SERVICE_PATH))
                mod = importlib.util.module_from_spec(spec)
                with mock.patch('sys.stdout', io.StringIO()):
                    spec.loader.exec_module(mod)
            finally:
                if saved is None:
                    os.environ.pop('SETUP_DEVICE_ROOT', None)
                else:
                    os.environ['SETUP_DEVICE_ROOT'] = saved
            self.assertEqual(mode(old), 0o600)
            for h in list(mod.logger.handlers):
                mod.logger.removeHandler(h)
                h.close()
        finally:
            remove_scratch(root)

    def test_the_safety_net_masks_a_registered_secret_that_reaches_the_log(self):
        self.m._register_secret(CANARY_PSK)
        self.m.logger.info('something went wrong with %s in a library message', CANARY_PSK)
        self.m.logger.warning('request failed: %s', f'GET /pair?pairing_code={CANARY_CODE}&x=1')
        self.m.logger.error('payload {"api_key": "%s", "tunnel_token": "%s"}', CANARY_API_KEY, CANARY_TUNNEL)
        try:
            raise RuntimeError(f'nmcli said {CANARY_PSK}')
        except RuntimeError:
            self.m.logger.exception('traceback follows')
        self.assertNoCanaries(self.svc.log_text(), 'the log')
        self.assertIn('***', self.svc.log_text())

    def test_describe_cloud_payload_reports_shape_not_content(self):
        d = self.m._describe_cloud_payload
        self.assertEqual(d(json.dumps({'api_key': CANARY_API_KEY, 'b': 1})), 'JSON object with fields: api_key, b')
        self.assertNotIn(CANARY_API_KEY, d(json.dumps({'api_key': CANARY_API_KEY})))
        self.assertIn('non-JSON', d(f'<html>{CANARY_CODE}</html>'))
        self.assertNotIn(CANARY_CODE, d(f'<html>{CANARY_CODE}</html>'))

    def test_redact_cloud_payload_still_masks_credentials(self):
        out = self.m._redact_cloud_payload({'api_key': CANARY_API_KEY, 'tunnelToken': CANARY_TUNNEL, 'ok': 1})
        self.assertNotIn(CANARY_API_KEY, out)
        self.assertNotIn(CANARY_TUNNEL, out)


class DeviceIdTests(unittest.TestCase):
    """I8 / C2: the dmidecode and machine-id probes used to raise ValueError and never ran."""

    def setUp(self):
        self._ctx = loaded_service()
        self.svc = self._ctx.__enter__()
        self.m = self.svc.module
        self.sys = self.svc.system
        # no sysfs DMI data, a machine-id file
        real_open = open

        def fake_open(path, *a, **k):
            if str(path).startswith('/sys/class/dmi/id/'):
                raise FileNotFoundError(path)
            if str(path) == '/etc/machine-id':
                return io.StringIO('machine-id-from-file\n')
            return real_open(path, *a, **k)
        self.m.open = fake_open
        self._env = mock.patch.dict(os.environ)
        self._env.start()
        os.environ.pop('DEVICE_ID', None)

    def tearDown(self):
        self._env.stop()
        self._ctx.__exit__(None, None, None)

    def test_dmidecode_serial_is_used_when_sysfs_has_nothing(self):
        self.sys.dmidecode_serial = 'SERIAL-XYZ-0001'
        self.assertEqual(self.m.get_device_id(), 'SERIAL-XYZ-0001')
        self.assertTrue(self.sys.find('dmidecode -s system-serial-number'))

    def test_placeholder_serials_are_skipped(self):
        self.sys.dmidecode_serial = 'To Be Filled By O.E.M.'
        # dmidecode -s system-uuid answers the same placeholder; the cat probe then supplies the machine-id
        self.assertEqual(self.m.get_device_id(), 'machine-id-from-cat')

    def test_machine_id_probe_runs_when_dmidecode_is_missing(self):
        self.sys.dmidecode_serial = None
        self.assertEqual(self.m.get_device_id(), 'machine-id-from-cat')

    def test_environment_override_wins(self):
        os.environ['DEVICE_ID'] = 'from-env'
        self.assertEqual(self.m.get_device_id(), 'from-env')

    def test_no_call_in_the_service_combines_capture_output_with_stdout_or_stderr(self):
        tree = ast.parse(harness.SERVICE_PATH.read_text())
        offenders = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                names = {k.arg for k in node.keywords}
                if 'capture_output' in names and names & {'stdout', 'stderr'}:
                    offenders.append(node.lineno)
        self.assertEqual(offenders, [], f'subprocess.run raises ValueError for these calls (lines {offenders})')


class HealthEndpointTests(unittest.TestCase):
    """U1 / C8: the portal polls /api/health. It must exist, answer without side effects, and carry no secrets."""

    ALLOWED = {'status', 'service', 'uptime_seconds', 'setup_complete', 'configuring', 'pairing_code_error'}

    def test_health(self):
        with loaded_service() as svc:
            client = svc.client()
            for path in ('/api/health', '/health'):
                r = client.get(path)
                self.assertEqual(r.status_code, 200, path)
                body = r.get_json()
                self.assertEqual(body['status'], 'ok')
                self.assertLessEqual(set(body), self.ALLOWED, 'unexpected field in the health response')
                self.assertIsInstance(body['uptime_seconds'], int)
                self.assertNotIn(str(svc.root), r.text)
            self.assertEqual(svc.system.lines(), [], 'health must not run any command')

    def test_health_carries_no_secret_even_when_secrets_exist(self):
        with loaded_service() as svc:
            svc.client().get('/api/health')
            code = json.loads(Path(svc.module.PAIRING_CODE_JSON).read_text())['code']
            svc.module._register_secret(CANARY_PSK)
            text = svc.client().get('/api/health').text
            self.assertNotIn(code, text)
            self.assertNotIn(CANARY_PSK, text)

    def test_the_portal_only_calls_endpoints_the_backend_serves(self):
        portal = (harness.PAYLOAD / 'var' / 'www' / 'setup-portal' / 'index.html').read_text()
        wanted = set(re.findall(r"fetch\('(/api/[^']+)'", portal))
        with loaded_service() as svc:
            served = {rule for (_m, rule) in svc.module.app._routes} if hasattr(svc.module.app, '_routes') else None
            if served is None:
                served = {r.rule for r in svc.module.app.url_map.iter_rules()}
        self.assertTrue(wanted, 'no fetch() calls found in the portal page')
        self.assertLessEqual(wanted, served, f'the portal calls {sorted(wanted - served)} but the backend does not serve it')


class SignalHandlerTests(unittest.TestCase):
    """H2: no signal handler at import time (it replaced gunicorn's worker handling and made stop slow)."""

    def test_import_registers_no_signal_handler(self):
        calls = []
        real = signal.signal
        with mock.patch('signal.signal', lambda *a, **k: calls.append(a[0]) or real(*a, **k)):
            with loaded_service():
                pass
        self.assertEqual(calls, [])

    def test_module_level_statements_do_not_call_signal(self):
        tree = ast.parse(harness.SERVICE_PATH.read_text())
        for node in tree.body:
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
                self.assertNotIn('signal', ast.dump(node.value.func), f'line {node.lineno}')

    def test_main_installs_the_handlers_for_the_standalone_server(self):
        with loaded_service() as svc:
            seen = []
            with mock.patch.object(svc.module.signal, 'signal', lambda sig, h: seen.append(sig)):
                with mock.patch.object(svc.module, 'make_server', side_effect=RuntimeError('stop here')):
                    with self.assertRaises(SystemExit):
                        svc.module.main()
            self.assertEqual(sorted(seen), sorted([signal.SIGTERM, signal.SIGINT]))


class HotspotStateInConfigureTests(unittest.TestCase):
    """The configure() paths that depend on whether the access point is up keep working."""

    def setUp(self):
        self._ctx = loaded_service()
        self.svc = self._ctx.__enter__()
        self.m = self.svc.module
        self.sys = self.svc.system
        self.runs = []
        self.m._run_script = lambda argv, timeout: self.runs.append(argv) or 0

    def tearDown(self):
        self._ctx.__exit__(None, None, None)

    def test_over_the_hotspot_the_answer_is_202_and_the_join_runs_in_the_background(self):
        self.sys.units_active.add('hostapd-setup.service')
        spawned = []
        self.m._spawn_background_configure = lambda *a: spawned.append(a)
        r = self.svc.client().post('/api/configure', json={'ssid': 'HomeNet', 'password': 'password12'}, headers=JSON)
        self.assertEqual(r.status_code, 202)
        self.assertEqual(len(spawned), 1)
        self.assertEqual(self.runs, [], 'the hotspot must not be touched before the response is written')
        # the lock stays held for the background thread
        self.assertTrue(self.m._configure_lock.locked())
        self.m._configure_lock.release()

    def test_connect_and_pair_ends_the_episode_with_the_stop_mode(self):
        with self.m.app.app_context():
            self.m._connect_and_pair('HomeNet', 'password12', '', 'uuid-1', False, {}, True)
        self.assertEqual(self.runs[0], [self.m.HOTSPOT_SCRIPT, 'stop'])


if __name__ == '__main__':
    print(f'flask: {harness.FLASK_KIND}' + (' (stand-in: real Flask is not installed here)' if harness.FLASK_KIND == 'standin' else ''))
    unittest.main(verbosity=2)
