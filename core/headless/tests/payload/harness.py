"""Shared fixtures for the setup_service.py tests. TEST-ONLY.

What it gives the tests:
  - loaded_service(): imports a FRESH copy of the real setup_service.py with SETUP_DEVICE_ROOT set to a scratch
    directory, so every path the service touches is inside it, and with a fake `subprocess` (FakeSystem) wired in;
  - FakeSystem: records every command the service would run and answers like NetworkManager, systemd and friends
    would, enough for the configure/pairing flows. It enforces the same argument rules as the real
    subprocess.run (stdout/stderr may not be combined with capture_output), which is how the get_device_id bug
    hid for so long: the tests used to run a fake that accepted anything;
  - the Flask choice: real Flask when importable, otherwise standin/flask.py (a message says which).

PAYLOAD_DIR (environment) points the tests at another copy of the payload; the mutation checker uses that.

Deletion rule of this module: it only ever removes the directory tempfile.mkdtemp() returned to it.
"""
import contextlib
import importlib.util
import io
import itertools
import json
import logging
import os
import shutil
import subprocess as _real_subprocess
import sys
import tempfile
import threading
import types
import uuid as _uuid
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ in the payload tree

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
PAYLOAD = Path(os.environ.get('PAYLOAD_DIR') or (REPO / 'core' / 'headless' / 'payload'))
SERVICE_PATH = PAYLOAD / 'opt' / 'setup-backend' / 'setup_service.py'
PRESCAN_PATH = PAYLOAD / 'usr' / 'local' / 'bin' / 'setup-device-prescan.py'


def _select_flask():
    try:
        import flask  # noqa: F401
        return 'real'
    except ImportError:
        sys.path.insert(0, str(HERE / 'standin'))
        import flask  # noqa: F401
        return 'standin'


FLASK_KIND = _select_flask()

_counter = itertools.count()


class Completed:
    """What subprocess.run returns, as far as the service reads it."""

    def __init__(self, returncode=0, stdout='', stderr='', args=None):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.args = args


class Call:
    def __init__(self, argv, kwargs, extra=None):
        self.argv = list(argv)
        self.kwargs = dict(kwargs)
        self.extra = extra or {}

    @property
    def line(self):
        return ' '.join(str(a) for a in self.argv)

    def __repr__(self):
        return f'Call({self.line!r})'


class FakeSystem:
    """A scriptable world: NetworkManager profiles, systemd units, processes. Thread-safe enough for the tests."""

    def __init__(self, root):
        self.root = Path(root)
        self.calls = []
        self.lock = threading.Lock()
        self.profiles = []            # dicts: name, uuid, type
        self.active_connections = []  # dicts: name, uuid, type, device
        self.units_active = set()
        self.launcher_running = False
        self.internet = True
        self.wifi_device = 'wlan0'
        self.dmidecode_serial = None  # None: command missing
        self.script_status = 0
        self.up_status = (0, '', '')
        self.psk_stored = True        # does NetworkManager report a stored passphrase after activation
        self.fail = []                # substrings of a command line that must fail (rc 1)

    # --- subprocess module surface ---------------------------------------------------------------------------------
    PIPE = _real_subprocess.PIPE
    DEVNULL = _real_subprocess.DEVNULL
    STDOUT = _real_subprocess.STDOUT
    TimeoutExpired = _real_subprocess.TimeoutExpired
    CalledProcessError = _real_subprocess.CalledProcessError
    SubprocessError = _real_subprocess.SubprocessError

    def run(self, cmd, *args, **kwargs):
        # The same rule CPython enforces; the service once passed both and swallowed the ValueError.
        if kwargs.get('capture_output') and ('stdout' in kwargs or 'stderr' in kwargs):
            raise ValueError('stdout and stderr arguments may not be used with capture_output.')
        extra = {}
        argv = list(cmd)
        passwd = _passwd_file_arg(argv)
        if passwd:
            path = Path(passwd)
            try:
                extra['passwd_file_text'] = path.read_text()
                extra['passwd_file_mode'] = path.stat().st_mode & 0o777
                extra['passwd_dir_mode'] = path.parent.stat().st_mode & 0o777
            except OSError as e:
                extra['passwd_file_error'] = str(e)
        call = Call(argv, kwargs, extra)
        with self.lock:
            self.calls.append(call)
        return self._answer(call)

    def Popen(self, argv, *args, **kwargs):  # noqa: N802 - mirrors subprocess.Popen
        call = Call(argv, kwargs, {'popen': True})
        with self.lock:
            self.calls.append(call)
        outer = self

        class _Proc:
            returncode = outer.script_status

            def wait(self, timeout=None):
                return outer.script_status

            def terminate(self):
                pass

            def kill(self):
                pass

        return _Proc()

    # --- the world ---------------------------------------------------------------------------------------------------
    def _answer(self, call):
        argv = call.argv
        line = call.line
        for needle in self.fail:
            if needle in line:
                return Completed(1, '', f'fake failure for {needle}')
        name = os.path.basename(argv[0])
        if name == 'pgrep':
            return Completed(0 if self.launcher_running else 1)
        if name == 'ping' or name == 'nslookup':
            return Completed(0 if self.internet else 1)
        if name == 'systemctl':
            return self._systemctl(argv)
        if name == 'nmcli':
            return self._nmcli(argv)
        if name == 'dmidecode':
            if self.dmidecode_serial is None:
                raise FileNotFoundError('dmidecode')
            return Completed(0, self.dmidecode_serial + '\n')
        if name == 'cat' and argv[1:] == ['/etc/machine-id']:
            return Completed(0, 'machine-id-from-cat\n')
        if name == 'hostname':
            return Completed(0, 'fake-host\n')
        return Completed(0)

    def _systemctl(self, argv):
        if argv[1:2] == ['is-active']:
            unit = argv[-1]
            if unit == 'NetworkManager.service':
                return Completed(0, 'active\n')
            return Completed(0 if unit in self.units_active else 3, '')
        return Completed(0)

    def _nmcli(self, argv):
        rest = argv[1:]
        if rest[:4] == ['-t', '-f', 'NAME,UUID,TYPE', 'connection'] and rest[-1] == 'show':
            return Completed(0, ''.join(f"{_esc(p['name'])}:{p['uuid']}:{p['type']}\n" for p in self.profiles))
        if rest[:3] == ['connection', 'add', 'type']:
            return self._connection_add(rest)
        if rest[:3] == ['connection', 'delete', 'uuid']:
            before = len(self.profiles)
            self.profiles = [p for p in self.profiles if p['uuid'] != rest[3]]
            return Completed(0 if len(self.profiles) < before else 10, '', '' if len(self.profiles) < before else 'not found')
        if '--show-secrets' in rest and '802-11-wireless-security.psk' in rest:
            return Completed(0, 'stored-secret\n' if self.psk_stored else '\n')
        if rest[:2] == ['connection', 'up']:
            rc, out, err = self.up_status
            return Completed(rc, out, err)
        if rest[:3] == ['-t', '-f', 'DEVICE,TYPE']:
            return Completed(0, f'{self.wifi_device}:wifi\neth0:ethernet\n')
        if rest[:3] == ['-t', '-f', 'NAME,UUID,TYPE,DEVICE'] and rest[-1] == '--active':
            return Completed(0, ''.join(
                f"{_esc(c['name'])}:{c['uuid']}:{c['type']}:{c['device']}\n" for c in self.active_connections))
        if rest[:3] == ['-t', '-f', 'RUNNING']:
            return Completed(0, 'running\n')
        return Completed(0)

    def _connection_add(self, rest):
        # nmcli connection add type wifi KEY VALUE KEY VALUE ...
        opts = {'type': rest[3]}
        i = 4
        while i + 1 < len(rest):
            opts[rest[i]] = rest[i + 1]
            i += 2
        new_uuid = str(_uuid.uuid4())
        self.profiles.append({'name': opts.get('con-name', ''), 'uuid': new_uuid, 'type': '802-11-wireless'})
        return Completed(0, f"Connection '{opts.get('con-name', '')}' ({new_uuid}) successfully added.\n")

    # --- helpers for assertions --------------------------------------------------------------------------------------
    def lines(self):
        return [c.line for c in self.calls]

    def find(self, prefix):
        return [c for c in self.calls if c.line.startswith(prefix)]

    def any_line_contains(self, text):
        return any(text in c.line for c in self.calls)


def _esc(value):
    return value.replace('\\', '\\\\').replace(':', '\\:')


def _passwd_file_arg(argv):
    if 'passwd-file' in argv:
        idx = argv.index('passwd-file')
        if idx + 1 < len(argv):
            return argv[idx + 1]
    return None


class _NoSleepTime:
    """`time` for the service: sleeping is instant, everything else is real."""

    def __getattr__(self, name):
        return getattr(__import__('time'), name)

    @staticmethod
    def sleep(_seconds):
        return None


class LoadedService:
    def __init__(self, module, system, root, stdout):
        self.module = module
        self.system = system
        self.root = Path(root)
        self.stdout = stdout

    @property
    def log_path(self):
        return Path(self.module.LOG_FILE)

    def log_text(self):
        for handler in logging.getLogger('setup_service').handlers:
            handler.flush()
        return self.log_path.read_text()

    def client(self):
        self.module.app.config['PROPAGATE_EXCEPTIONS'] = False
        return self.module.app.test_client()

    def close(self):
        logger = logging.getLogger('setup_service')
        for handler in list(logger.handlers):
            logger.removeHandler(handler)
            handler.close()


def remove_scratch(path):
    """Remove a directory that tempfile.mkdtemp() made for a test, and nothing else."""
    path = Path(path).resolve()
    if path.name.startswith(('setup-service-test-', 'secret-files-', 'oldlog-')) and path.is_dir() \
            and Path(tempfile.gettempdir()).resolve() in path.parents:
        shutil.rmtree(path, ignore_errors=True)


@contextlib.contextmanager
def loaded_service(prefix='setup-service-test-', real_subprocess=False, real_time=False, seed=None):
    """A fresh setup_service module in a scratch root. Yields LoadedService.

    `seed` maps a path under the root to its text, e.g. {'etc/setup-device/device.conf': 'KEY=value\\n'}. The files exist
    before the module is imported, which is when it reads its configuration."""
    root = Path(tempfile.mkdtemp(prefix=prefix)).resolve()
    for rel, text in (seed or {}).items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    saved_env = os.environ.get('SETUP_DEVICE_ROOT')
    os.environ['SETUP_DEVICE_ROOT'] = str(root)
    stdout = io.StringIO()
    system = FakeSystem(root)
    try:
        name = f'setup_service_under_test_{next(_counter)}'
        spec = importlib.util.spec_from_file_location(name, str(SERVICE_PATH))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        with contextlib.redirect_stdout(stdout):
            spec.loader.exec_module(module)
        if not real_subprocess:
            shim = types.SimpleNamespace(
                run=system.run, Popen=system.Popen, PIPE=system.PIPE, DEVNULL=system.DEVNULL, STDOUT=system.STDOUT,
                TimeoutExpired=system.TimeoutExpired, CalledProcessError=system.CalledProcessError,
                SubprocessError=system.SubprocessError)
            module.subprocess = shim
        if not real_time:
            module.time = _NoSleepTime()
        service = LoadedService(module, system, root, stdout)
        try:
            yield service
        finally:
            service.close()
            sys.modules.pop(name, None)
    finally:
        if saved_env is None:
            os.environ.pop('SETUP_DEVICE_ROOT', None)
        else:
            os.environ['SETUP_DEVICE_ROOT'] = saved_env
        remove_scratch(root)


def load_prescan():
    spec = importlib.util.spec_from_file_location(f'prescan_under_test_{next(_counter)}', str(PRESCAN_PATH))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeHTTPResponse:
    """What urllib.request.urlopen returns (a context manager with .status and .read())."""

    def __init__(self, body, status=200):
        self._body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.status = status

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False
