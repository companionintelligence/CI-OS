"""Static checks on the payload and on every backend that installs it (stdlib unittest, no root, no network).

These pin the properties that no runtime test of one backend can see: what ships in the nginx site, which units the
installers enable at boot, which packages they depend on. Each test names the finding (report 02) it guards.

    python3 -B core/headless/tests/payload/test_static.py
"""
import os
import re
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
PAYLOAD = Path(os.environ.get('PAYLOAD_DIR') or (REPO / 'core' / 'headless' / 'payload'))
BACKENDS = Path(os.environ.get('BACKENDS_DIR') or (REPO / 'backends'))

BIN = PAYLOAD / 'usr' / 'local' / 'bin'
HOSTAPD_CONFS = [PAYLOAD / 'hostapd' / 'hostapd-setup.conf', PAYLOAD / 'usr' / 'share' / 'setup-device' / 'defaults' / 'hostapd-setup.conf']
UBUNTU_POSTINST = BACKENDS / 'ubuntu' / 'headless-package' / 'DEBIAN' / 'postinst'
MINT_POSTINST = BACKENDS / 'mint' / 'headless-package' / 'DEBIAN' / 'postinst'
FEDORA_INSTALL = BACKENDS / 'fedora' / 'headless-setup' / 'install.sh'
ARCH_INSTALL = BACKENDS / 'arch' / 'headless-setup' / 'install.sh'
NIXOS_MODULE = BACKENDS / 'nixos' / 'modules' / 'headless-setup.nix'
CACHYOS_SERVICES = BACKENDS / 'cachyos' / 'installer' / 'modules' / 'services-systemd.conf'
CACHYOS_PACKAGES = BACKENDS / 'cachyos' / 'installer' / 'modules' / 'packages_online.conf'


def code_lines(path):
    """The non-comment, non-blank lines of a shell/nix/conf file."""
    out = []
    for raw in Path(path).read_text().splitlines():
        s = raw.strip()
        if s and not s.startswith('#'):
            out.append(s)
    return out


def code_text(path):
    return '\n'.join(code_lines(path))


class NginxSiteTests(unittest.TestCase):
    """S3: the API listens on every interface and has no credential: only the setup network and loopback may use it."""

    def api_block(self):
        text = (PAYLOAD / 'nginx' / 'sites-available' / 'setup-portal').read_text()
        m = re.search(r'location\s+/api/\s*\{(.*?)\n    \}', text, re.S)
        self.assertIsNotNone(m, 'no "location /api/" block in the nginx site')
        return [l.strip() for l in m.group(1).splitlines() if l.strip() and not l.strip().startswith('#')]

    def test_allow_setup_subnet_and_loopback_then_deny_all_before_proxy_pass(self):
        lines = self.api_block()
        allows = [l for l in lines if l.startswith('allow ')]
        self.assertIn('allow 192.168.99.0/24;', allows)
        self.assertTrue({'allow 127.0.0.0/8;', 'allow 127.0.0.1;'} & set(allows), 'loopback (IPv4) not allowed')
        self.assertIn('allow ::1;', allows, 'loopback (IPv6) not allowed: nginx also listens on [::]:80')
        self.assertEqual(lines.count('deny all;'), 1)
        deny = lines.index('deny all;')
        proxy = next(i for i, l in enumerate(lines) if l.startswith('proxy_pass '))
        self.assertTrue(all(lines.index(a) < deny for a in allows), 'every allow must come before deny all (first match wins)')
        self.assertLess(deny, proxy)

    def test_nothing_in_the_api_block_allows_everyone(self):
        lines = self.api_block()
        self.assertFalse([l for l in lines if re.match(r'allow\s+(all|0\.0\.0\.0/0|::/0)\s*;', l)])
        self.assertFalse([l for l in lines if l.startswith('satisfy ')], '"satisfy any" would let a client skip the allow list')

    def test_the_api_only_proxies_to_loopback(self):
        proxies = [l for l in self.api_block() if l.startswith('proxy_pass ')]
        self.assertEqual(proxies, ['proxy_pass http://127.0.0.1:5000;'])

    def test_no_second_listener_in_the_site(self):
        text = code_text(PAYLOAD / 'nginx' / 'sites-available' / 'setup-portal')
        self.assertEqual(sorted(re.findall(r'listen\s+([^;]+);', text)), ['80 default_server', '[::]:80 default_server'])


class AccessPointConfigTests(unittest.TestCase):
    """R3 / R1: clients are isolated, only CCMP, and no country is hard-coded."""

    def test_static_hostapd_configs(self):
        for conf in HOSTAPD_CONFS:
            with self.subTest(conf=str(conf.relative_to(PAYLOAD))):
                lines = code_lines(conf)
                self.assertIn('ap_isolate=1', lines)
                self.assertNotIn('TKIP', code_text(conf))
                self.assertFalse([l for l in lines if l.startswith('country_code=')], 'a constant country_code is back')

    def test_the_shipped_default_is_the_same_file(self):
        self.assertEqual(HOSTAPD_CONFS[0].read_text(), HOSTAPD_CONFS[1].read_text(),
                         'the postinst restores the default when the config is missing: the two copies must not drift')

    def test_dnsmasq_configs_are_marked_as_defaults_with_the_interface_note(self):
        for conf in (PAYLOAD / 'dnsmasq.d' / 'setup-portal.conf', PAYLOAD / 'usr' / 'share' / 'setup-device' / 'defaults' / 'setup-portal.conf'):
            self.assertIn('DEFAULT ONLY', conf.read_text(), str(conf))

    def test_the_wifi_interface_is_not_pinned_in_any_script(self):
        for script in list(BIN.iterdir()) + [PAYLOAD / 'opt' / 'setup-backend' / 'setup_service.py']:
            if script.is_file() and script.suffix != '.pyc':
                self.assertNotIn('wlp192s0', code_text(script), script.name)


class NoDockerOrTraefikTests(unittest.TestCase):
    """L3: the payload never stops, starts or looks at Docker/Traefik (it used to `docker stop traefik` and never undo it)."""

    def test_payload_scripts_do_not_touch_docker(self):
        # ci-os-hub-start.sh / ci-os-post-validation.sh are the Hub hand-off, a different concern: they are excluded
        for name in ('setup-device-hotspot-start.sh', 'setup-network-monitor.sh', 'setup-hotspot-reset.sh', 'setup-wifi-recover', 'setup-device-prescan.py'):
            with self.subTest(script=name):
                self.assertNotRegex(code_text(BIN / name), r'(?i)docker|traefik')
        self.assertNotRegex(code_text(PAYLOAD / 'opt' / 'setup-backend' / 'setup_service.py').replace('docker/', ''), r'(?i)traefik')

    def test_nixos_monitor_path_has_no_docker(self):
        text = NIXOS_MODULE.read_text()
        m = re.search(r'systemd\.services\.setup-network-monitor = \{.*?path = with pkgs; \[(.*?)\];', text, re.S)
        self.assertIsNotNone(m)
        self.assertNotIn('docker', m.group(1))


class UnitFileTests(unittest.TestCase):
    """H4: a daemon that cannot start must not restart for ever."""

    def test_access_point_units_have_a_start_limit(self):
        for unit in ('hostapd-setup.service', 'dnsmasq-setup.service'):
            text = (PAYLOAD / 'systemd' / 'system' / unit).read_text()
            unit_section = text.split('[Service]')[0]
            self.assertRegex(unit_section, r'(?m)^StartLimitIntervalSec=\d+', unit)
            self.assertRegex(unit_section, r'(?m)^StartLimitBurst=\d+', unit)


class BootEnablingTests(unittest.TestCase):
    """L2 / WP-B: nothing enables hostapd-setup, dnsmasq-setup or nginx at boot; they are started on demand."""

    ENABLE = re.compile(r'systemctl\s+(?:enable|reenable)\s+(?:--now\s+)?[^\n]*?(hostapd-setup|dnsmasq-setup|nginx)')

    def installers(self):
        return {'ubuntu postinst': UBUNTU_POSTINST, 'mint postinst': MINT_POSTINST, 'fedora install.sh': FEDORA_INSTALL, 'arch install.sh': ARCH_INSTALL}

    def test_no_installer_enables_the_access_point_stack(self):
        for label, path in self.installers().items():
            with self.subTest(installer=label):
                self.assertIsNone(self.ENABLE.search(code_text(path)), f'{label} enables an on-demand unit at boot')

    def test_no_installer_starts_nginx_at_install_time(self):
        for label, path in self.installers().items():
            with self.subTest(installer=label):
                self.assertNotRegex(code_text(path), r'systemctl\s+start\s+nginx')

    def test_installers_still_enable_what_must_run_at_boot(self):
        for label, path in self.installers().items():
            with self.subTest(installer=label):
                text = code_text(path)
                self.assertRegex(text, r'systemctl enable setup-backend\.service')
                self.assertRegex(text, r'systemctl enable setup-network-monitor\.service')

    def test_installers_turn_off_an_older_install_s_boot_enabling(self):
        for label, path in self.installers().items():
            with self.subTest(installer=label):
                text = code_text(path)
                self.assertRegex(text, r'systemctl disable hostapd-setup\.service')
                self.assertRegex(text, r'systemctl disable dnsmasq-setup\.service')
                self.assertRegex(text, r'systemctl disable nginx\.service')

    def test_nixos_does_not_start_nginx_or_the_access_point_at_boot(self):
        text = NIXOS_MODULE.read_text()
        self.assertRegex(text, r'systemd\.services\.nginx\.wantedBy\s*=\s*lib\.mkIf cfg\.portalOnDemand \(lib\.mkForce \[ \]\)')
        for unit in ('hostapd-setup', 'dnsmasq-setup'):
            block = re.search(rf'systemd\.services\.{unit} = \{{(.*?)\n    \}};', text, re.S)
            self.assertIsNotNone(block, unit)
            self.assertNotIn('wantedBy', block.group(1), unit)

    def test_cachyos_enables_exactly_the_boot_units(self):
        enabled = set()
        name = None
        for line in CACHYOS_SERVICES.read_text().splitlines():
            m = re.match(r'\s+- name: "([^"]+)"', line)
            if m:
                name = m.group(1)
            if re.match(r'\s+action: "enable"', line) and name:
                enabled.add(name)
        self.assertFalse(enabled & {'hostapd-setup', 'dnsmasq-setup', 'nginx'})
        self.assertLessEqual({'setup-backend', 'setup-network-monitor'}, enabled)


class DependencyTests(unittest.TestCase):
    """K2: iw, iproute2 and rfkill/util-linux are used by the payload and were declared nowhere."""

    def test_deb_depends(self):
        for control in (BACKENDS / 'ubuntu' / 'headless-package' / 'DEBIAN' / 'control', BACKENDS / 'mint' / 'headless-package' / 'DEBIAN' / 'control'):
            depends = re.search(r'(?m)^Depends:\s*(.*)$', control.read_text()).group(1)
            names = {d.strip().split()[0] for d in depends.split(',')}
            with self.subTest(control=str(control.relative_to(BACKENDS))):
                self.assertLessEqual({'iw', 'iproute2', 'rfkill'}, names)
                self.assertLessEqual({'hostapd', 'dnsmasq', 'nginx-light', 'network-manager'}, names)

    def test_fedora_and_arch_dependency_lists(self):
        fedora = re.search(r'FEDORA_DEPS=\((.*?)\)', FEDORA_INSTALL.read_text()).group(1).split()
        arch = re.search(r'ARCH_DEPS=\((.*?)\)', ARCH_INSTALL.read_text()).group(1).split()
        self.assertLessEqual({'iw', 'iproute', 'util-linux'}, set(fedora))      # util-linux: flock, rfkill
        self.assertLessEqual({'iw', 'iproute2', 'util-linux'}, set(arch))

    def test_nixos_paths(self):
        text = NIXOS_MODULE.read_text()
        monitor = re.search(r'systemd\.services\.setup-network-monitor = \{.*?path = with pkgs; \[(.*?)\];', text, re.S).group(1).split()
        backend = re.search(r'systemd\.services\.setup-backend = \{.*?path = with pkgs; \[(.*?)\];', text, re.S).group(1).split()
        self.assertLessEqual({'iw', 'iproute2', 'rfkill', 'util-linux', 'networkmanager'}, set(monitor))
        self.assertLessEqual({'iproute2', 'util-linux', 'procps', 'networkmanager', 'iw', 'gawk'}, set(backend))

    def test_cachyos_installs_iw(self):
        names = set(re.findall(r'(?m)^\s*-\s+([A-Za-z0-9._+-]+)\s*$', CACHYOS_PACKAGES.read_text()))
        self.assertIn('iw', names)

    def test_the_commands_the_hotspot_scripts_rely_on_are_declared_somewhere(self):
        """If the hotspot start script calls one of these, the package that provides it must be in the Debian Depends line
        (the other backends are checked above). A new command is a new line here and in every backend's list."""
        wanted = {'iw': 'iw', 'ip': 'iproute2', 'ss': 'iproute2', 'rfkill': 'rfkill', 'nmcli': 'network-manager'}
        depends = re.search(r'(?m)^Depends:\s*(.*)$', (BACKENDS / 'ubuntu' / 'headless-package' / 'DEBIAN' / 'control').read_text()).group(1)
        declared = {d.strip().split()[0] for d in depends.split(',')}
        script = code_text(BIN / 'setup-device-hotspot-start.sh')
        for command, package in wanted.items():
            if re.search(rf'(?:^|[|;&(`\s]){re.escape(command)}\s', script):
                self.assertIn(package, declared, f'the hotspot script calls {command} but {package} is not in Depends')


class ExecutableBitTests(unittest.TestCase):
    """Files that start with #! must be executable (check-repo.sh enforces it on the git mode; this checks the tree)."""

    def test_payload_bin_scripts_and_maintainer_scripts(self):
        paths = list(BIN.iterdir())
        paths += [BACKENDS / 'ubuntu' / 'headless-package' / 'DEBIAN' / n for n in ('postinst', 'prerm', 'postrm')]
        paths += [BACKENDS / 'mint' / 'headless-package' / 'DEBIAN' / n for n in ('postinst', 'prerm', 'postrm')]
        paths += [FEDORA_INSTALL, ARCH_INSTALL]
        for path in paths:
            if path.is_file() and path.read_bytes()[:2] == b'#!':
                with self.subTest(path=str(path)):
                    self.assertTrue(os.access(path, os.X_OK), f'{path} starts with #! but is not executable')


class PostinstBehaviourTests(unittest.TestCase):
    """The postinst only stops nginx when the portal is the only site it serves."""

    def test_the_only_site_check_exists_and_guards_the_disable(self):
        for postinst in (UBUNTU_POSTINST, MINT_POSTINST):
            text = postinst.read_text()
            self.assertIn('nginx_serves_only_the_portal', text)
            guarded = re.search(r'if nginx_serves_only_the_portal; then(.*?)\nelse', text, re.S)
            self.assertIsNotNone(guarded, str(postinst))
            self.assertIn('systemctl disable nginx.service', guarded.group(1))


if __name__ == '__main__':
    unittest.main(verbosity=2)
