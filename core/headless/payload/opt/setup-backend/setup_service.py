#!/usr/bin/env python3
"""
Setup Device Backend Service
Flask-based API for headless device WiFi configuration
Daemon-safe with signal handling

DESIGN: NO WIFI SCANNING OR SYNC
- Single-radio chips (e.g. PCE-AX1800 / MT7921) cannot scan while in AP mode.
- This backend NEVER triggers nmcli wifi list/rescan, iw scan, or similar.
- /api/setup-data: single bootstrap endpoint (networks + SSID) from cache. Portal fetches once on load.
- No further backend/network activity until user hits submit (POST /api/configure).
- /api/networks and /api/scan-networks read only from last-scan.json (prescanned at hotspot start).
- nmcli usage: device status, connection add/up (configure flow only). No wifi scan subcommands.
- Cloud API calls (pairing) occur only after /api/configure: user has connected to their network.
"""

import contextlib
import os
import sys
import json
import subprocess
import re
import time
import threading
import signal
import logging
import secrets
import string
import unicodedata
from datetime import datetime, timedelta
from html import escape as html_escape
from pathlib import Path
from wsgiref.simple_server import make_server, WSGIRequestHandler
from flask import Flask, request, jsonify
import urllib.request
import urllib.error
import urllib.parse

# Configuration paths. SETUP_DEVICE_ROOT relocates every path this service reads or writes under a
# prefix; it exists so the tests (core/headless/tests/payload) can run the real code against a scratch
# directory. It is unset on a device (systemd gives the unit no such variable), which leaves '/'.
_ROOT = Path(os.environ.get('SETUP_DEVICE_ROOT') or '/')
CONFIG_DIR = _ROOT / 'etc' / 'setup-device'
DATA_DIR = _ROOT / 'var' / 'lib' / 'setup-device'
LOG_FILE = str(_ROOT / 'var' / 'log' / 'setup-backend.log')
RUN_DIR = _ROOT / 'run' / 'setup-device'
HOTSPOT_SCRIPT = str(_ROOT / 'usr' / 'local' / 'bin' / 'setup-device-hotspot-start.sh')
HUB_START_SCRIPT = str(_ROOT / 'usr' / 'local' / 'bin' / 'ci-os-hub-start.sh')
NETPLAN_SETUP_FILE = _ROOT / 'etc' / 'netplan' / '50-setup-mode.yaml'

PAIRING_CODE_JSON = CONFIG_DIR / 'pairing_code.json'
SETUP_COMPLETE_FILE = DATA_DIR / 'setup-complete'
CREDENTIALS_JSON = DATA_DIR / 'credentials.json'
CLOUD_CREDENTIALS_JSON = DATA_DIR / 'cloud_credentials.json'
HUB_ENV = DATA_DIR / 'hub.env'
LAST_PAIRING_ERROR_JSON = DATA_DIR / 'last_pairing_error.json'
SCAN_CACHE_TXT = DATA_DIR / 'last_scan_networks.txt'

def _read_env_file(path):
    """Parse a `KEY=value` file into a dict, the way `set -a; . file` reads it.

    Blank lines and `#` comments are skipped, an `export ` prefix is dropped, only
    the first `=` splits, and one layer of matching surrounding quotes is removed so
    a hand-edited `API_KEY="abc"` yields `abc` rather than `"abc"`. Later
    definitions win, matching what sourcing the file in a shell would leave behind.
    Returns an empty dict for a missing or unreadable file.
    """
    values = {}
    try:
        if not Path(path).exists():
            return values
        for line in Path(path).read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('export '):
                line = line[len('export '):].lstrip()
            name, sep, value = line.partition('=')
            if not sep:
                continue
            name = name.strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            if name:
                values[name] = value
    except Exception:
        return values
    return values


# Cloud API config - can be set via environment `CI_CLOUD_API_URL`
# or via `/etc/setup-device/device.conf` value `CI_CLOUD_API_URL`.
def _read_conf_value(key):
    return _read_env_file(CONFIG_DIR / 'device.conf').get(key)


def _read_int_env(name, default):
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default

CI_CLOUD_API_URL = os.environ.get('CI_CLOUD_API_URL') or _read_conf_value('CI_CLOUD_API_URL') or 'https://portal.companionintelligence.com/api/'
CI_ZONE_ID = os.environ.get('CI_ZONE_ID') or _read_conf_value('CI_ZONE_ID') or '2b77d4360dbd4a9ccdad5c8d947323c9'
CI_HUB_REGISTRATION_STATUS_URL = os.environ.get('CI_HUB_REGISTRATION_STATUS_URL', 'http://127.0.0.1:5002/api/registration/status')
CI_HUB_REGISTRATION_CALLBACK_URL = os.environ.get('CI_HUB_REGISTRATION_CALLBACK_URL', 'http://127.0.0.1:5002/api/registration/callback')
CI_HUB_REGISTRATION_DEVICE_ID_URL = os.environ.get('CI_HUB_REGISTRATION_DEVICE_ID_URL', 'http://127.0.0.1:5002/api/registration/device-id')
REGISTRATION_CONNECTIVITY_WINDOW_SECONDS = _read_int_env('SETUP_REGISTRATION_CONNECTIVITY_WINDOW_SECONDS', 20)
CLOUD_REQUEST_USER_AGENT = os.environ.get('SETUP_CLOUD_USER_AGENT', 'curl/8.5.0')
DEFAULT_PORTAL_REDIRECT_URL = 'https://portal.ci.computer'
DEFAULT_CLOUD_DOMAIN = 'ci.computer'


def _cloud_request_headers(extra_headers=None):
    headers = {
        'Accept': 'application/json',
        'User-Agent': CLOUD_REQUEST_USER_AGENT,
    }
    if extra_headers:
        headers.update(extra_headers)
    return headers


def _normalize_redirect_url(value):
    """Normalize a redirect hostname/URL to an https URL without trailing slash."""
    if not value:
        return None

    raw_value = str(value).strip()
    if not raw_value:
        return None

    candidate = raw_value if '://' in raw_value else f'https://{raw_value}'

    try:
        parsed = urllib.parse.urlparse(candidate)
    except Exception:
        return None

    hostname = (parsed.netloc or parsed.path or '').strip().strip('/')
    if not hostname or any(ch.isspace() for ch in hostname):
        return None

    path = parsed.path if parsed.netloc else ''
    normalized = urllib.parse.urlunparse((
        parsed.scheme or 'https',
        hostname,
        path.rstrip('/'),
        '',
        '',
        '',
    )).rstrip('/')
    return normalized or None


def _build_redirect_metadata(*cloud_payloads):
    """Build deterministic redirect metadata from cloud pairing responses."""
    candidates = []

    for payload in cloud_payloads:
        if not isinstance(payload, dict):
            continue

        domain_candidate = _normalize_redirect_url(payload.get('domain'))
        if domain_candidate and domain_candidate not in candidates:
            candidates.append(domain_candidate)

        subdomain = (payload.get('subdomain') or '').strip()
        if subdomain:
            subdomain_candidate = subdomain if '.' in subdomain else f'{subdomain}.{DEFAULT_CLOUD_DOMAIN}'
            normalized_subdomain = _normalize_redirect_url(subdomain_candidate)
            if normalized_subdomain and normalized_subdomain not in candidates:
                candidates.append(normalized_subdomain)

    if DEFAULT_PORTAL_REDIRECT_URL not in candidates:
        candidates.append(DEFAULT_PORTAL_REDIRECT_URL)

    return {
        'redirect_url': candidates[0],
        'redirect_candidates': candidates,
        'redirect_fallback_url': DEFAULT_PORTAL_REDIRECT_URL,
    }


# Process names of the Companion Launcher. The binary has been `companion-hub` since CI-Hub 2026-06-03;
# `ci-os-hub-desktop` is the name up to release v0.1.4 and is kept so an old install is still detected.
LAUNCHER_PROCESS_NAMES = ('companion-hub', 'ci-os-hub-desktop')


def _hub_running():
    """Detect whether Companion Launcher (companion-hub) is running on the device.

    Named _hub_running/get_hub_pairing_state for the pairing-state concept, not
    because this checks the CI Hub Service backend — it checks the desktop
    launcher process. See docs/architecture/multi-distro-design.md.

    `pgrep -x` matches the exact process name, so a shell command line that merely
    mentions the name (or this very service) is not mistaken for the launcher.
    """
    for name in LAUNCHER_PROCESS_NAMES:
        try:
            proc = subprocess.run(
                ['pgrep', '-x', name],
                capture_output=True,
                text=True,
                timeout=3
            )
            if proc.returncode == 0:
                return True
        except Exception:
            continue
    return False


def get_hub_pairing_state():
    """Return whether Hub is running and whether pairing should be required."""
    state = {
        'hub_running': False,
        'hub_registered': False,
        'require_pairing': False,
    }

    if not _hub_running():
        return state

    state['hub_running'] = True

    try:
        req = urllib.request.Request(CI_HUB_REGISTRATION_STATUS_URL, method='GET')
        with urllib.request.urlopen(req, timeout=4) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            parsed = json.loads(body)

            hub_registered = bool(parsed.get('registered', False))
            state['hub_registered'] = hub_registered
            state['require_pairing'] = not hub_registered
            return state
    except Exception as e:
        logger.warning(f"Could not query Hub registration status ({CI_HUB_REGISTRATION_STATUS_URL}): {e}")

    # Conservative fallback: if Hub is running but status is unknown, require pairing.
    state['require_pairing'] = True
    return state

def _cloud_pairing_url():
    """Get the cloud pairing endpoint URL"""
    base_url = CI_CLOUD_API_URL.rstrip('/')
    # Remove /api suffix if present, we'll add it back
    if base_url.endswith('/api'):
        base_url = base_url[:-4]
    return base_url + '/api/devices/pair'

def get_device_id():
    """Get a unique device identifier (serial number or hardware ID)"""
    env_device_id = os.environ.get('DEVICE_ID', '').strip()
    if env_device_id:
        logger.info(f"Device ID obtained via env DEVICE_ID: {env_device_id}")
        return env_device_id

    invalid_ids = {
        'not specified',
        'to be filled by o.e.m.',
        'default string',
        'system serial number',
        'chassis serial number',
        'none',
        'na',
        'n/a',
        '0',
        '',
    }

    # Try sysfs first (fast and no dmidecode dependency).
    for path, method_name in [
        ('/sys/class/dmi/id/product_serial', 'product-serial'),
        ('/sys/class/dmi/id/product_uuid', 'product-uuid'),
    ]:
        try:
            with open(path, 'r') as f:
                device_id = f.read().strip()
            if device_id and device_id.lower() not in invalid_ids:
                logger.info(f"Device ID obtained via {method_name}: {device_id}")
                return device_id
        except Exception:
            pass

    # Try multiple methods to get a unique device identifier
    methods = [
        # Try to get system serial number
        (['dmidecode', '-s', 'system-serial-number'], 'system-serial'),
        # Try to get product UUID
        (['dmidecode', '-s', 'system-uuid'], 'system-uuid'),
        # Try to get machine-id (fallback)
        (['cat', '/etc/machine-id'], 'machine-id'),
    ]
    
    for cmd, method_name in methods:
        try:
            # stdout=PIPE with stderr=DEVNULL, not capture_output=True: subprocess.run raises
            # ValueError("stdout and stderr arguments may not be used with capture_output")
            # for that combination, which the except below swallowed, so these probes
            # silently never ran.
            result = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                device_id = result.stdout.strip()
                if device_id and device_id.lower() not in invalid_ids:
                    logger.info(f"Device ID obtained via {method_name}: {device_id}")
                    return device_id
        except (subprocess.TimeoutExpired, FileNotFoundError, Exception) as e:
            logger.debug(f"Failed to get device ID via {method_name}: {e}")
            continue
    
    # Final fallback: use machine-id from systemd
    try:
        with open('/etc/machine-id', 'r') as f:
            device_id = f.read().strip()
            logger.info(f"Using machine-id as device ID: {device_id}")
            return device_id
    except Exception as e:
        logger.error(f"Failed to get machine-id: {e}")
        # Last resort: generate a hash from hostname
        import hashlib
        hostname = subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip()
        device_id = hashlib.sha256(hostname.encode()).hexdigest()[:16]
        logger.warning(f"Using hostname hash as device ID: {device_id}")
        return device_id

def check_internet_connectivity(timeout=5):
    """Check if device has internet connectivity including DNS resolution"""
    # Step 1: basic IP reachability
    ip_ok = False
    try:
        result = subprocess.run(
            ['ping', '-c', '1', '-W', str(timeout), '8.8.8.8'],
            capture_output=True,
            timeout=timeout + 1
        )
        ip_ok = result.returncode == 0
    except Exception as e:
        logger.debug(f"Internet connectivity IP check failed: {e}")

    if not ip_ok:
        logger.warning("Internet connectivity check: FAILED")
        return False

    # Step 2: verify DNS is also functional (needed for cloud API calls)
    try:
        result = subprocess.run(
            ['nslookup', 'google.com'],
            capture_output=True,
            timeout=timeout
        )
        if result.returncode == 0:
            logger.info("Internet connectivity check: OK")
            return True
    except Exception:
        pass

    logger.warning("Internet connectivity check: FAILED (DNS not ready)")
    return False

def get_pairing_info_from_cloud(pairing_code, timeout=10):
    """GET request to /api/devices/pair?pairing_code=XXX to validate pairing details.

    CI-Portal currently returns non-sensitive device metadata from GET /pair
    (for example `deviceId` / `pairingCode`) and omits `api_key` by design.
    """
    # Normalize to uppercase (removes non-alphanumeric characters)
    normalized_code = normalize_pairing_code(pairing_code)
    encoded_code = urllib.parse.quote(normalized_code)
    _register_secret(normalized_code)
    url = _cloud_pairing_url() + f'?pairing_code={encoded_code}'
    # The query string carries the pairing code: log the endpoint, never the full URL.
    logger.info(f"[CLOUD GET] Request: {_cloud_pairing_url()} (pairing code in the query string, not logged)")
    try:
        req = urllib.request.Request(url, headers=_cloud_request_headers(), method='GET')
        logger.info("[CLOUD GET] Sending GET request to cloud API...")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            logger.info(f"[CLOUD GET] Response status: {resp.status}; {_describe_cloud_payload(body)}")
            try:
                parsed = json.loads(body)
                if isinstance(parsed, dict):
                    device_id = parsed.get('device_id') or parsed.get('deviceId')
                    if device_id:
                        logger.info(f"Retrieved pairing info from cloud: device_id={device_id}")
                        return True, parsed
                    else:
                        logger.warning(f"Missing device_id in response ({_describe_cloud_payload(parsed)})")
                        return False, parsed
                return False, parsed
            except json.JSONDecodeError:
                logger.warning(f"Invalid JSON response ({_describe_cloud_payload(body)})")
                return False, body
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode('utf-8', errors='replace')
        except Exception:
            body = str(e)
        logger.error(f"[CLOUD GET] HTTP Error {e.code}: {_describe_cloud_payload(body)}")
        try:
            parsed = json.loads(body)
            return False, parsed
        except Exception:
            return False, body
    except Exception as e:
        logger.warning(f"Cloud pairing GET failed: {e}")
        return False, str(e)

# Response fields that are credentials rather than diagnostics. `api_key` is the
# device key this service stores and now presents back to the Portal as proof of
# possession, and `tunnel_token` authorizes the device's tunnel. Both arrive in the
# pair POST response, which used to be logged verbatim into
# /var/log/setup-backend.log -- a file gunicorn creates under the default umask, so
# mode 0644 and readable by every account on the appliance.
_SECRET_RESPONSE_FIELDS = ('api_key', 'apiKey', 'tunnel_token', 'tunnelToken', 'device_key', 'deviceKey')


def _redact_cloud_payload(payload):
    """Render a cloud response for the log with its credentials masked."""
    if isinstance(payload, str):
        try:
            payload = json.loads(payload)
        except Exception:
            return payload
    if not isinstance(payload, dict):
        return payload
    redacted = dict(payload)
    for field in _SECRET_RESPONSE_FIELDS:
        if redacted.get(field):
            redacted[field] = '***redacted***'
    return json.dumps(redacted)


def _describe_cloud_payload(payload):
    """What the log may say about a cloud response: its shape, never its contents.

    A cloud body can carry the pairing code, the device key or the tunnel token, and
    an error body can echo the request. The log records the field NAMES (which is
    what a support engineer needs to see that `device_id` was missing) and the size.
    """
    if isinstance(payload, (bytes, bytearray)):
        payload = payload.decode('utf-8', errors='replace')
    if isinstance(payload, str):
        try:
            parsed = json.loads(payload)
        except Exception:
            return f"non-JSON body of {len(payload)} characters"
        payload = parsed
    if isinstance(payload, dict):
        return "JSON object with fields: " + ", ".join(sorted(str(k) for k in payload)[:20])
    return f"JSON {type(payload).__name__}"


# Secrets that this process has handled (a Wi-Fi passphrase, a pairing code). The log
# formatter masks any of them that still reaches a log line by accident -- a library
# exception that quotes a command line, a future log statement. Not the primary defence:
# the code does not log these. It is the net under it, and the tests plant canaries to
# prove both layers.
_REGISTERED_SECRETS = {}   # value -> None, in insertion order: the oldest goes first when the table is full
_REGISTERED_SECRETS_LOCK = threading.Lock()
_MIN_SECRET_LENGTH = 6
_MAX_REGISTERED_SECRETS = 64


def _register_secret(value):
    if isinstance(value, str) and len(value) >= _MIN_SECRET_LENGTH:
        with _REGISTERED_SECRETS_LOCK:
            _REGISTERED_SECRETS.pop(value, None)          # re-registering makes it the newest
            while len(_REGISTERED_SECRETS) >= _MAX_REGISTERED_SECRETS:
                del _REGISTERED_SECRETS[next(iter(_REGISTERED_SECRETS))]
            _REGISTERED_SECRETS[value] = None


_SECRET_PATTERNS = (
    # ?pairing_code=ABC123 in a URL
    re.compile(r'(pairing_?code=)[A-Za-z0-9%_-]+', re.IGNORECASE),
    # "api_key": "..." / api_key=...
    re.compile(
        r'((?:api_?key|tunnel_?token|device_?key|psk|passphrase|password)["\']?\s*[:=]\s*["\']?)[^"\'\s,}&]+',
        re.IGNORECASE,
    ),
)


def _scrub(text):
    """Mask registered secrets and well-known credential patterns in a log line."""
    if not isinstance(text, str):
        return text
    with _REGISTERED_SECRETS_LOCK:
        secrets_now = sorted(_REGISTERED_SECRETS, key=len, reverse=True)
    for value in secrets_now:
        if value in text:
            text = text.replace(value, '***')
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub(r'\1***', text)
    return text


class _ScrubbingFormatter(logging.Formatter):
    """Formatter that runs the finished line (message plus traceback) through _scrub()."""

    def format(self, record):
        return _scrub(super().format(record))


# --- Wi-Fi input validation (IEEE 802.11) -----------------------------------------------------------------------------
class InvalidInput(ValueError):
    """A submitted SSID or passphrase that cannot be what the standard allows."""


_HEX_PSK = re.compile(r'[0-9A-Fa-f]{64}\Z')


def validate_ssid(ssid):
    """An SSID is 1 to 32 OCTETS (not characters) and, as typed into the portal, text
    without control characters (a newline would also forge log lines).

    Returns the SSID unchanged or raises InvalidInput with a message that does not
    repeat the value.
    """
    if not isinstance(ssid, str):
        raise InvalidInput('SSID must be text')
    try:
        raw = ssid.encode('utf-8')
    except UnicodeEncodeError:
        raise InvalidInput('SSID is not valid text')
    if not 1 <= len(raw) <= 32:
        raise InvalidInput('SSID must be 1 to 32 bytes long')
    for ch in ssid:
        if unicodedata.category(ch) in ('Cc', 'Zl', 'Zp'):
            raise InvalidInput('SSID must not contain control characters')
    return ssid


def validate_psk(psk):
    """A WPA2/WPA3-personal secret is 8 to 63 printable ASCII characters (a passphrase),
    or exactly 64 hex digits (the raw 256-bit PSK). Returns it unchanged or raises
    InvalidInput. An open network has no secret at all: the caller does not validate ''.
    """
    if not isinstance(psk, str):
        raise InvalidInput('Wi-Fi password must be text')
    if _HEX_PSK.match(psk):
        return psk
    if not 8 <= len(psk) <= 63 or any(not 0x20 <= ord(ch) <= 0x7e for ch in psk):
        raise InvalidInput('Wi-Fi password must be 8 to 63 printable ASCII characters, or 64 hex digits')
    return psk


def update_device_id_in_cloud(pairing_code, device_id, api_key=None, timeout=10):
    """POST request to /api/devices/pair to upsert device_id where pairing_code matches"""
    url = _cloud_pairing_url()
    
    # Normalize to uppercase (removes non-alphanumeric characters)
    normalized_code = normalize_pairing_code(pairing_code)
    
    payload = {
        'pairing_code': normalized_code,
        'device_id': device_id
    }

    # Proof of possession. A pairing code proves organization membership, not which
    # machine is calling, so the Portal will not re-key hardware it already knows
    # without this (CI-Portal#688). Omitted rather than blank on a genuine first
    # boot -- the Portal's schema rejects an empty string, and a device row it has
    # never seen is one it asks no proof for. Not the `api_key` argument below:
    # that one comes from GET /pair and belongs to the row the pairing code names,
    # not to this hardware.
    device_key = load_saved_device_key(device_id)
    if device_key:
        payload['device_key'] = device_key
        logger.info("Presenting the stored device key as proof of possession")
    else:
        logger.info("No stored device key for this hardware; pairing as first boot")
    
    data = json.dumps(payload).encode('utf-8')
    headers = _cloud_request_headers({
        'Content-Type': 'application/json',
    })
    # Older flows expected api_key from GET /pair; current portal no longer returns it there.
    # Keep header when available for backward compatibility.
    if api_key:
        headers['X-API-Key'] = api_key
    
    try:
        req = urllib.request.Request(url, data=data, headers=headers, method='POST')
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            logger.info(f"Device ID update response: {resp.status}; {_describe_cloud_payload(body)}")
            try:
                parsed = json.loads(body)
                return True, parsed
            except Exception:
                return True, body
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode('utf-8', errors='replace')
        except Exception:
            body = str(e)
        logger.warning(f"Device ID update HTTP error: {e.code}; {_describe_cloud_payload(body)}")
        try:
            parsed = json.loads(body)
            return False, parsed
        except Exception:
            return False, body
    except Exception as e:
        logger.warning(f"Device ID update failed: {e}")
        return False, str(e)


def _fetch_hub_callback_nonce(timeout=6):
    """Read the Hub's one-time registration nonce out of its own callback_url.

    Newer Hubs mint a nonce into `callback_url` and require it back on the
    callback. Older Hubs put no `state` there and accept the callback without
    one, so a missing nonce is not an error.
    """
    try:
        req = urllib.request.Request(CI_HUB_REGISTRATION_DEVICE_ID_URL, method='GET')
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            parsed = json.loads(resp.read().decode('utf-8', errors='replace'))

        callback_url = (parsed or {}).get('callback_url') or ''
        query = urllib.parse.urlparse(callback_url).query

        return urllib.parse.parse_qs(query).get('state', [None])[0]
    except Exception as e:
        logger.warning(f"Could not read Hub registration nonce: {e}")
        return None


def _notify_hub_registration_callback_get(payload, timeout=6):
    """Legacy query-string form, for a Hub too old to accept the POST."""
    query = urllib.parse.urlencode(payload)

    try:
        req = urllib.request.Request(f"{CI_HUB_REGISTRATION_CALLBACK_URL}?{query}", method='GET')
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            parsed = json.loads(resp.read().decode('utf-8', errors='replace'))
            if isinstance(parsed, dict) and parsed.get('success'):
                return True
            logger.warning(f"Legacy Hub callback returned non-success payload ({_describe_cloud_payload(parsed)})")
    except Exception as e:
        logger.warning(f"Legacy Hub callback failed: {e}")

    return False


def notify_hub_registration_callback(cloud_response, retries=10, retry_delay=2):
    """Forward finalized cloud registration payload to CI Hub callback endpoint.

    Sends the payload as a JSON body rather than a query string: it carries the
    Hub's `api_key` and `tunnel_token`, and a query string puts both into the
    Hub's request logs. Newer Hubs also require the one-time nonce they mint
    into `callback_url`, which `_fetch_hub_callback_nonce` reads back.
    """
    try:
        if not isinstance(cloud_response, dict):
            logger.warning("Skipping Hub callback: cloud response is not JSON object")
            return False

        required_fields = [
            'device_id',
            'organization_id',
            'organization_name',
            'slug',
            'subdomain',
            'tunnel_id',
            'tunnel_token',
            'api_key',
        ]
        missing = [k for k in required_fields if not cloud_response.get(k)]
        if missing:
            logger.warning(f"Skipping Hub callback: cloud response missing fields: {', '.join(missing)}")
            return False

        payload = {
            'device_id': cloud_response.get('device_id', ''),
            'organization_id': cloud_response.get('organization_id', ''),
            'organization_name': cloud_response.get('organization_name', ''),
            'slug': cloud_response.get('slug', ''),
            'subdomain': cloud_response.get('subdomain', ''),
            'tunnel_id': cloud_response.get('tunnel_id', ''),
            'tunnel_token': cloud_response.get('tunnel_token', ''),
            'api_key': cloud_response.get('api_key', ''),
            'domain': cloud_response.get('domain', ''),
        }

        for attempt in range(1, retries + 1):
            # Re-read the nonce each attempt: a Hub that restarted mid-pairing
            # mints a new one, and a Hub that is still up returns the same value.
            body = dict(payload)
            nonce = _fetch_hub_callback_nonce()
            if nonce:
                body['state'] = nonce

            try:
                req = urllib.request.Request(
                    CI_HUB_REGISTRATION_CALLBACK_URL,
                    data=json.dumps(body).encode('utf-8'),
                    headers={'Content-Type': 'application/json', 'Accept': 'application/json'},
                    method='POST',
                )
                with urllib.request.urlopen(req, timeout=6) as resp:
                    parsed = json.loads(resp.read().decode('utf-8', errors='replace'))
                    if isinstance(parsed, dict) and parsed.get('success'):
                        logger.info(f"Hub callback succeeded on attempt {attempt}: {CI_HUB_REGISTRATION_CALLBACK_URL}")
                        return True
                    logger.warning(f"Hub callback attempt {attempt} returned non-success payload ({_describe_cloud_payload(parsed)})")
            except urllib.error.HTTPError as e:
                if e.code in (404, 405):
                    logger.warning("Hub has no POST registration callback — falling back to the legacy GET")
                    if _notify_hub_registration_callback_get(payload):
                        return True
                else:
                    logger.warning(f"Hub callback attempt {attempt}/{retries} failed: HTTP {e.code}")
            except Exception as e:
                logger.warning(f"Hub callback attempt {attempt}/{retries} failed: {e}")

            if attempt < retries:
                time.sleep(retry_delay)

        return False
    except Exception as e:
        logger.warning(f"Failed to invoke Hub callback: {e}")
        return False

def _device_key_from_cloud_credentials():
    """(device_id, api_key) as last saved by save_cloud_credentials, or (None, None).

    Reads CLOUD_CREDENTIALS_JSON, not the similarly named CREDENTIALS_JSON, which
    holds the WiFi passphrase and never a device credential.
    """
    if not CLOUD_CREDENTIALS_JSON.exists():
        return None, None
    stored = json.loads(CLOUD_CREDENTIALS_JSON.read_text())
    return stored.get('device_id'), stored.get('api_key')

def _device_key_from_hub_env():
    """(DEVICE_ID, API_KEY) as last written by save_hub_env, or (None, None)."""
    values = _read_env_file(HUB_ENV)
    return values.get('DEVICE_ID'), values.get('API_KEY')

# Values a stringified absent key takes on the way to disk. `save_hub_env` renders
# whatever it is handed, and a Python `None` or a JS `null` reaches the file as text
# that a plain truthiness test would happily present to the Portal as proof.
_PLACEHOLDER_DEVICE_KEYS = {'none', 'null', 'undefined', 'nil', ''}

# A failed pair is otherwise invisible. The hotspot is stopped before the pairing
# request is made, so the client that submitted the form is off the access point
# long before the response is written and nothing reads the status code. Recording
# the refusal is what survives that: `/api/status` reports it, so the setup portal
# says what went wrong the next time it is reachable, and support can read one file
# instead of the whole log.
def record_pairing_failure(code, message):
    """Persist why the last pairing attempt was refused."""
    try:
        # The message names the user's SSID: root-only like every other file written here.
        _write_secret_file(LAST_PAIRING_ERROR_JSON, json.dumps({
            'code': (code or 'PAIRING_FAILED')[:64],
            'message': (message or 'Pairing failed.')[:512],
            'at': datetime.now().isoformat(),
        }, indent=2) + '\n')
    except Exception as e:
        logger.warning(f"Could not record the pairing failure: {e}")

def clear_pairing_failure():
    """Drop any recorded failure; the device has paired."""
    try:
        LAST_PAIRING_ERROR_JSON.unlink()
    except FileNotFoundError:
        pass
    except Exception as e:
        logger.warning(f"Could not clear the recorded pairing failure: {e}")

def load_pairing_failure():
    """The last recorded pairing failure, or None."""
    try:
        if not LAST_PAIRING_ERROR_JSON.exists():
            return None
        recorded = json.loads(LAST_PAIRING_ERROR_JSON.read_text())
        return recorded if isinstance(recorded, dict) else None
    except Exception as e:
        logger.warning(f"Could not read the recorded pairing failure: {e}")
        return None

def load_saved_device_key(device_id):
    """Return this hardware's current Portal device key, or None if it holds none.

    The Portal refuses to re-key a device row that already exists unless the caller
    also proves it holds that hardware (CI-Portal#688), and the key saved by the last
    successful pair is the only proof an appliance keeps. Returned only when the
    stored credential names the device we are about to pair, so a key left behind by
    other hardware is never offered as proof for this one.

    A stored value that is not a usable string is treated as no key at all: omitting
    the field is the Portal's ordinary first-boot request, while presenting `"None"`
    or a JSON number is a proof that can only be refused.
    """
    for source in (_device_key_from_cloud_credentials, _device_key_from_hub_env):
        try:
            stored_id, stored_key = source()
        except Exception as e:
            logger.warning(f"Could not read a stored device key from {source.__name__}: {e}")
            continue
        if not isinstance(stored_key, str) or stored_key.strip().lower() in _PLACEHOLDER_DEVICE_KEYS:
            if stored_key:
                logger.warning(
                    f"Ignoring an unusable stored device key from {source.__name__} "
                    f"(type {type(stored_key).__name__})"
                )
            continue
        if stored_id != device_id:
            if stored_id:
                logger.info(
                    f"Stored device key from {source.__name__} belongs to other hardware; not offering it"
                )
            continue
        logger.info(f"Using the device key stored by {source.__name__}")
        return stored_key.strip()
    return None

def _write_secret_file(path, text):
    """Write `text` to `path` so it is never readable by anyone but root, even briefly,
    and so a crash can never leave it half-written.

    The text goes to a sibling temporary file that is created with mode 0600 (O_EXCL, so
    an existing file or symlink of that name is never followed), flushed to disk, and then
    renamed over `path`. `open()` followed by `chmod()` publishes the file at the umask's
    0644 first and narrows it after; truncating the real file in place loses the old
    content when the write fails. The rename is atomic on one filesystem, so a reader sees
    either the old file or the new one. The final chmod narrows nothing that matters (the
    temporary file is already 0600) and keeps the intent visible.
    """
    path = Path(path)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        try:
            handle = os.fdopen(fd, 'w')
        except BaseException:
            os.close(fd)
            raise
        with handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise

def save_cloud_credentials(device_id, api_key):
    """Save device_id and api_key for later use (API key comes from GET response)"""
    try:
        credentials = {
            'device_id': device_id,
            'api_key': api_key,
            'saved_at': datetime.now().isoformat()
        }
        _write_secret_file(CLOUD_CREDENTIALS_JSON, json.dumps(credentials, indent=2) + '\n')
        # No fragment of the key: this log is /var/log/setup-backend.log, which
        # gunicorn creates under the default umask at mode 0644, and a prefix of a
        # credential is still part of a credential.
        logger.info(f"[CREDENTIALS] Saved device key for device_id={device_id}")
        return True
    except Exception as e:
        logger.error(f"Failed to save cloud credentials: {e}")
        return False

def save_hub_env(device_id, api_key):
    """Write hub.env with CI_ZONE_ID, DEVICE_ID, API_KEY, CI_CLOUD_API_KEY for Companion Hub to consume."""
    try:
        # An absent key is an empty value, never the text `None`. This file is
        # sourced by ci-os-hub-start.sh (which hands off to provision.sh
        # --step=ci-hub) and read back by load_saved_device_key,
        # and `API_KEY=None` is a string both of them would take for a real
        # credential -- the Hub would authenticate with it and the next pair would
        # present it to the Portal as proof of possession.
        key_value = api_key if isinstance(api_key, str) else ''
        if not api_key:
            logger.warning("[HUB] No API key available; writing hub.env with an empty API_KEY")
        lines = [
            f"CI_ZONE_ID={CI_ZONE_ID}",
            f"DEVICE_ID={device_id}",
            f"API_KEY={key_value}",
            f"CI_CLOUD_API_KEY={key_value}",
            f"CI_CLOUD_API_URL={CI_CLOUD_API_URL.rstrip('/')}",
        ]
        _write_secret_file(HUB_ENV, '\n'.join(lines) + '\n')
        logger.info(f"[HUB] Wrote hub.env with CI_ZONE_ID, DEVICE_ID, API_KEY for Companion Hub")
        return True
    except Exception as e:
        logger.error(f"Failed to write hub.env: {e}")
        return False

# Ensure directories exist
CONFIG_DIR.mkdir(parents=True, exist_ok=True)
DATA_DIR.mkdir(parents=True, exist_ok=True)
Path(LOG_FILE).parent.mkdir(parents=True, exist_ok=True)


def _private_log_file(path):
    """Create the log file root-only (0600) if it is missing and narrow it if an older
    version left it 0644. Done with an explicit mode rather than a process-wide umask:
    a umask of 077 would also be inherited by ci-os-hub-start.sh and everything it
    installs."""
    try:
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600))
        os.chmod(path, 0o600)
    except OSError:
        pass


# Configure logging. The module logger is configured explicitly (not via basicConfig, which
# is a no-op once anything has configured the root logger), every handler formats through
# _ScrubbingFormatter, and the file is private: it records SSIDs and the progress of
# pairing, and used to record the pairing code.
_private_log_file(LOG_FILE)
logger = logging.getLogger('setup_service')
logger.setLevel(logging.INFO)
logger.propagate = False
for _stale_handler in list(logger.handlers):
    logger.removeHandler(_stale_handler)
    _stale_handler.close()
for _handler in (logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)):
    _handler.setFormatter(_ScrubbingFormatter('%(asctime)s [%(levelname)s] %(message)s'))
    logger.addHandler(_handler)

app = Flask(__name__)
# The form is a few hundred bytes. Refuse anything larger before it is parsed.
app.config['MAX_CONTENT_LENGTH'] = 64 * 1024

# Ensure pairing code on first request (gunicorn does not call main())
_pairing_ensured = False
_pairing_code_error = False
@app.before_request
def _ensure_pairing_on_first_request():
    global _pairing_ensured, _pairing_code_error
    if not _pairing_ensured:
        if ensure_pairing_code() is None:
            # Fail closed: this device has no pairing code and must not pretend it
            # has one. _pairing_ensured stays False so a transient failure (for
            # example CONFIG_DIR not yet writable) is retried on the next request;
            # log once per transition so the retry does not flood the log.
            if not _pairing_code_error:
                logger.critical(
                    "No pairing code available; /api/status now reports "
                    "pairing_code_error and this device cannot be paired"
                )
            _pairing_code_error = True
            return
        _pairing_code_error = False
        _pairing_ensured = True

# Graceful shutdown for the stand-alone server of main() only. Under gunicorn (how the
# unit runs this module) the worker installs its own SIGTERM/SIGINT handling BEFORE it
# imports the application; registering handlers at import time replaced it, so the worker
# ignored the master's SIGTERM and `systemctl stop setup-backend` waited out
# TimeoutStopSec. Handlers belong in main(), which gunicorn never calls.
shutdown_flag = False

def signal_handler(signum, frame):
    """Handle SIGTERM and SIGINT gracefully"""
    global shutdown_flag
    logger.info(f"Received signal {signum}, shutting down gracefully...")
    shutdown_flag = True

def normalize_pairing_code(code):
    """Normalize pairing code: remove non-alphanumeric characters, convert to uppercase"""
    return re.sub(r'[^A-Z0-9]', '', code.upper())

# Development-only pairing bypass, opt-in and unset by default: with no value there
# is no bypass at all. An operator who needs one sets SETUP_TEST_PAIRING_CODE to a
# code of their own choosing; there is deliberately no built-in constant, because a
# constant compiled into the image is a fleet-wide backdoor that every unit shares.
TEST_PAIRING_CODE = normalize_pairing_code(os.environ.get('SETUP_TEST_PAIRING_CODE', ''))
if TEST_PAIRING_CODE:
    logger.warning(
        "SETUP_TEST_PAIRING_CODE is set: a fixed pairing code is accepted in addition "
        "to this device's own code. Device pairing is effectively bypassed. This must "
        "never be set on a shipped device."
    )

def generate_pairing_code():
    """Generate new pairing code (6 characters, A-Z0-9)

    Uses secrets (CSPRNG), not random: the pairing code authorizes claiming this
    device. random.choice draws from the Mersenne Twister, whose full internal
    state is recoverable from a modest amount of observed output, so anyone who
    has seen previous codes could predict the next one.
    """
    chars = string.ascii_uppercase + string.digits
    code = ''.join(secrets.choice(chars) for _ in range(6))  # No dash, just 6 characters

    pairing_data = {
        'code': code
    }

    return pairing_data

def ensure_pairing_code():
    """Ensure pairing code exists and is valid"""
    try:
        # Load existing code if present
        if PAIRING_CODE_JSON.exists():
            try:
                with open(PAIRING_CODE_JSON, 'r') as f:
                    pairing_data = json.load(f)
                
                # Migrate old pairing code files: remove all old fields (expires_at, expired_at, generated_at)
                # Handle both empty strings and actual values
                fields_to_remove = ['expires_at', 'expired_at', 'generated_at']
                removed_fields = []
                
                for field in fields_to_remove:
                    if field in pairing_data:
                        # Remove field even if it's an empty string
                        removed_fields.append(field)
                        pairing_data.pop(field, None)
                
                if removed_fields:
                    logger.info(f"Migrating pairing code file: removing old fields: {', '.join(removed_fields)}")
                    # Ensure we only keep the 'code' field
                    cleaned_data = {'code': pairing_data.get('code', '')}
                    # Rewrite file with only the code field
                    _write_secret_file(PAIRING_CODE_JSON, json.dumps(cleaned_data, indent=2))
                    # Update pairing_data for validation below
                    pairing_data = cleaned_data
                
                # Check if code exists and is valid
                if 'code' in pairing_data and pairing_data['code']:
                    logger.info("Using existing pairing code")
                    _register_secret(pairing_data['code'])
                    return pairing_data['code']
                else:
                    logger.warning("Pairing code file exists but has no valid code, regenerating...")
            except (json.JSONDecodeError, KeyError, ValueError) as e:
                logger.warning(f"Invalid pairing code file: {e}, regenerating...")
        
        # Generate new code
        pairing_data = generate_pairing_code()
        # Root-only from the first byte, written atomically (see _write_secret_file).
        _write_secret_file(PAIRING_CODE_JSON, json.dumps(pairing_data, indent=2))

        # The code itself is a secret and stays out of the log; it is in PAIRING_CODE_JSON.
        _register_secret(pairing_data['code'])
        logger.info("Generated a new pairing code")
        return pairing_data['code']
        
    except Exception as e:
        # Fail closed. Returning a constant here would hand every unit in the fleet
        # the same well-known code, and returning an unpersisted code would report one
        # that load_pairing_code() can never read back. Callers must handle None.
        logger.critical(
            f"Failed to ensure pairing code: {e}. This device has no usable pairing "
            "code and cannot be paired until the underlying failure is fixed.",
            exc_info=True
        )
        return None

def load_pairing_code():
    """Load pairing code from JSON file"""
    try:
        if PAIRING_CODE_JSON.exists():
            with open(PAIRING_CODE_JSON, 'r') as f:
                pairing_data = json.load(f)
            return pairing_data.get('code', '')
    except Exception as e:
        logger.error(f"Failed to load pairing code: {e}")
    return None

def validate_pairing_code(code):
    """Validate pairing code matches stored code (pairing codes don't expire)"""
    normalized = normalize_pairing_code(code)

    if TEST_PAIRING_CODE and secrets.compare_digest(normalized, TEST_PAIRING_CODE):
        logger.warning(
            "Accepted SETUP_TEST_PAIRING_CODE; this device is NOT securely paired"
        )
        return True

    stored_code = load_pairing_code()

    if not stored_code:
        logger.warning("No pairing code found")
        return False

    stored_normalized = normalize_pairing_code(stored_code)

    # compare_digest, not ==: both operands are ASCII [A-Z0-9] after normalization,
    # and a pairing code is a shared secret, so the compare should not be short-circuit.
    if not secrets.compare_digest(normalized, stored_normalized):
        logger.warning("Pairing code mismatch")
        return False

    return True

# No scan_wifi_networks - single-radio chips cannot scan while in AP mode. Use _get_cached_networks() only.

def get_wifi_interface():
    """Detect the WiFi interface (handles wlan0, wlp*, etc).
    Uses nmcli device (lists devices only). DO NOT use nmcli device wifi list - that would scan."""
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'DEVICE,TYPE', 'device'],
            capture_output=True,
            text=True,
            timeout=5
        )
        for line in result.stdout.strip().split('\n'):
            parts = line.split(':')
            if len(parts) >= 2 and parts[1].strip() == 'wifi':
                return parts[0]  # Return first WiFi device found
        return 'wlan0'  # Fallback
    except Exception as e:
        logger.error(f"Error detecting WiFi interface: {e}")
        return 'wlan0'  # Fallback

def _split_nmcli_t_fields(line):
    """Split one line of `nmcli -t` output into its fields.

    In terse mode nmcli escapes a literal ':' in a value as '\\:' and a literal backslash
    as '\\\\'. This undoes both while splitting on the unescaped colons only (a value that
    ends in a backslash, such as 'a\\\\', must not hide the separator after it).
    """
    fields, current, escaped = [], [], False
    for ch in line.strip():
        if escaped:
            current.append(ch)
            escaped = False
        elif ch == '\\':
            escaped = True
        elif ch == ':':
            fields.append(''.join(current))
            current = []
        else:
            current.append(ch)
    if escaped:
        current.append('\\')
    fields.append(''.join(current))
    return fields


# Profiles this service creates are named OWN_PROFILE_PREFIX + the SSID. Nothing else is ever
# deleted: the old rule deleted every NetworkManager profile whose NAME equalled the posted SSID
# (or "<SSID> <digits>"), of ANY type, so an unauthenticated POST with ssid "Wired connection 1"
# removed the machine's wired profiles. The rule now needs all of: Wi-Fi type, this prefix, an
# exact name match.
OWN_PROFILE_PREFIX = 'ci-setup-'
NM_WIFI_TYPE = '802-11-wireless'


def _own_profile_name(ssid):
    return OWN_PROFILE_PREFIX + ssid


def _connection_name_matches_ssid(connection_name, ssid):
    """True when an NM connection name is the profile this service keeps for `ssid`.

    Also accepts the bare SSID (and NetworkManager's "<SSID> <n>" variants): profiles that an
    earlier version of this service created were named that way, and a device already
    connected through one of them is reused rather than re-created.
    """
    name = connection_name or ''
    for base in (_own_profile_name(ssid), ssid):
        if re.match(rf"^{re.escape(base)}(?:\s+\d+)?$", name):
            return True
    return False


def get_active_wifi_connection():
    """Return active WiFi connection metadata (name/uuid/device), or None."""
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'NAME,UUID,TYPE,DEVICE', 'connection', 'show', '--active'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode != 0:
            return None

        for raw in (result.stdout or '').splitlines():
            if not raw.strip():
                continue
            parts = _split_nmcli_t_fields(raw)
            if len(parts) < 4:
                continue

            name, uuid, con_type, device = parts[0], parts[1], parts[2], parts[3]
            if con_type == '802-11-wireless' and uuid:
                return {
                    'name': name,
                    'uuid': uuid,
                    'device': device,
                }
    except Exception as e:
        logger.warning(f"Failed to inspect active WiFi connection: {e}")

    return None

def find_open_bssid_for_ssid(ssid):
    """Return strongest open BSSID for an SSID, or None if none found."""
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'SSID,BSSID,SIGNAL,SECURITY', 'device', 'wifi', 'list', '--rescan', 'no'],
            capture_output=True,
            text=True,
            timeout=10
        )

        if result.returncode != 0:
            logger.warning(f"Failed to query BSSIDs for SSID {ssid}: {result.stderr}")
            return None

        best_bssid = None
        best_signal = -1
        for raw in (result.stdout or '').splitlines():
            if not raw.strip():
                continue
            parts = _split_nmcli_t_fields(raw)
            if len(parts) < 4:
                continue

            row_ssid, bssid, signal_str, security = parts[0], parts[1], parts[2], parts[3]
            if row_ssid != ssid:
                continue

            # Empty SECURITY means open network in nmcli output.
            if security.strip():
                continue

            signal = int(signal_str) if signal_str.isdigit() else 0
            if signal > best_signal:
                best_signal = signal
                best_bssid = bssid

        if best_bssid:
            logger.info(f"Selected open BSSID for {ssid}: {best_bssid} (signal {best_signal})")
        else:
            logger.info(f"No explicitly open BSSID found for SSID: {ssid}")

        return best_bssid
    except Exception as e:
        logger.warning(f"Error selecting open BSSID for {ssid}: {e}")
        return None

def _nm_env():
    """Environment for nmcli calls whose output or error text is parsed: English, whatever
    the system locale is (the matching below is on nmcli's English messages)."""
    env = dict(os.environ)
    env['LC_ALL'] = 'C'
    return env


def delete_owned_wifi_profiles(ssid, keep_uuid=None):
    """Delete the profiles THIS SERVICE created earlier for `ssid`, so a stale one cannot win
    over the new one at activation. Returns the UUIDs it deleted.

    A profile is deleted only when ALL of these hold: its type is 802-11-wireless, its name is
    exactly OWN_PROFILE_PREFIX + ssid, and it is not `keep_uuid`. Wired, VPN, bridge and
    every Wi-Fi profile the user or the installer made (other names) are never touched, no
    matter what SSID was posted.
    """
    deleted = []
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'NAME,UUID,TYPE', 'connection', 'show'],
            capture_output=True,
            text=True,
            timeout=10,
            env=_nm_env()
        )
        if result.returncode != 0:
            logger.warning(f"Could not list existing connections: {result.stderr}")
            return deleted

        wanted_name = _own_profile_name(ssid)
        for raw in (result.stdout or '').splitlines():
            if not raw.strip():
                continue
            parts = _split_nmcli_t_fields(raw)
            if len(parts) < 3:
                continue
            name, uuid, con_type = parts[0], parts[1], parts[2]
            if con_type != NM_WIFI_TYPE or name != wanted_name or not uuid or uuid == keep_uuid:
                continue

            delete_result = subprocess.run(
                ['nmcli', 'connection', 'delete', 'uuid', uuid],
                capture_output=True,
                text=True,
                timeout=5,
                env=_nm_env()
            )
            if delete_result.returncode == 0:
                logger.info(f"Deleted the earlier profile {name} ({uuid})")
                deleted.append(uuid)
            else:
                logger.warning(
                    f"Failed to delete connection profile {name} ({uuid}): {delete_result.stderr}"
                )
    except Exception as e:
        logger.warning(f"Failed to clean up earlier profiles for the network: {e}")
    return deleted


def create_wifi_connection(ssid, password):
    """Create the NetworkManager profile for a Wi-Fi network and return its UUID.

    The passphrase is NOT given to nmcli here. `nmcli connection add ... wifi-sec.psk <value>`
    would put it on the command line, where every local account can read it from
    /proc/<pid>/cmdline and `ps` for as long as the call runs. nmcli's manual has no file or
    standard-input form for `connection add`, `connection modify` or `device wifi connect`
    (`--ask` is documented as not for scripts). It does have one for activation:
    `nmcli connection up ... passwd-file <file>`, with lines of the form
    `802-11-wireless-security.psk:<secret>`. So the profile is created with the key
    management set and no secret, and connect_to_wifi() hands the secret over through a
    root-only file that exists for the length of the call.
    """
    try:
        # Detect the actual WiFi interface on this system
        wifi_ifname = get_wifi_interface()
        logger.info(f"Using WiFi interface: {wifi_ifname}")

        # Create the new connection first, explicitly on the WiFi interface; only once it exists
        # are this service's earlier profiles for the same network removed.
        cmd = ['nmcli', 'connection', 'add', 'type', 'wifi',
               'con-name', _own_profile_name(ssid), 'ifname', wifi_ifname, 'ssid', ssid]

        if password:
            cmd.extend(['wifi-sec.key-mgmt', 'wpa-psk'])
        else:
            cmd.extend(['wifi-sec.key-mgmt', 'none'])
            # If SSID exists with mixed security variants, lock to an open BSSID.
            open_bssid = find_open_bssid_for_ssid(ssid)
            if open_bssid:
                cmd.extend(['802-11-wireless.bssid', open_bssid])

        # Always pin DNS servers so cloud registration works even when the
        # WiFi network does not hand out DNS via DHCP.
        cmd.extend(['ipv4.dns', '8.8.8.8 1.1.1.1', 'ipv4.ignore-auto-dns', 'no'])

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10, env=_nm_env())

        if result.returncode != 0:
            logger.error(f"Failed to create connection: {result.stderr}")
            return None

        match = re.search(r'\(([0-9a-fA-F-]{36})\)', result.stdout or '')
        connection_uuid = match.group(1) if match else None
        logger.info(f"Created WiFi connection: {ssid} (uuid={connection_uuid or 'unknown'})")
        # A stale profile of ours for the same network must not win at activation; the new one is
        # activated by UUID below, but NetworkManager would also pick between them at every boot.
        delete_owned_wifi_profiles(ssid, keep_uuid=connection_uuid)
        return connection_uuid

    except Exception as e:
        logger.error(f"Error creating WiFi connection: {e}")
        return None


@contextlib.contextmanager
def _passwd_file(secret):
    """Yield the path of a root-only file holding `secret` in nmcli's passwd-file format, or
    None when there is no secret. The file is removed when the block ends, however it ends."""
    if not secret:
        yield None
        return
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN_DIR, 0o700)
    path = RUN_DIR / f".passwd.{os.getpid()}.{secrets.token_hex(6)}"
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as handle:
            handle.write(f"802-11-wireless-security.psk:{secret}\n")
        yield str(path)
    finally:
        with contextlib.suppress(OSError):
            os.unlink(path)


def _passphrase_is_stored(connection_uuid):
    """Did NetworkManager keep the passphrase it was given at activation?

    True, False, or None when it cannot be told. The passphrase is handed over through
    nmcli's passwd-file at `connection up`; nmcli's manual does not say that a secret
    supplied that way is written into the profile, and a profile without it joins the
    network now and cannot rejoin after a reboot. This reads the profile's secret back
    (the value stays in this process and is never logged) so the journal says so on the
    first device where it happens, not after the first power cut.
    """
    try:
        result = subprocess.run(
            ['nmcli', '--show-secrets', '--get-values', '802-11-wireless-security.psk',
             'connection', 'show', 'uuid', connection_uuid],
            capture_output=True,
            text=True,
            timeout=5,
            env=_nm_env()
        )
    except Exception as e:
        logger.debug(f"Could not read back the stored passphrase: {e}")
        return None
    if result.returncode != 0:
        return None
    return bool((result.stdout or '').strip())


def connect_to_wifi(connection_target, use_uuid=False, password=None):
    """Activate NetworkManager connection by UUID (preferred) or by name.

    `password` (a validated passphrase or 64-digit hex PSK) reaches nmcli through its
    passwd-file option, never on the command line; see create_wifi_connection().
    """
    target_desc = f"uuid={connection_target}" if use_uuid else f"SSID: {connection_target}"
    logger.info(f"[WIFI CONNECT] Attempting to connect to {target_desc}")
    try:
        cmd = ['nmcli', 'connection', 'up']
        if use_uuid:
            cmd.extend(['uuid', connection_target])
        else:
            cmd.append(connection_target)

        with _passwd_file(password) as secrets_path:
            if secrets_path:
                cmd.extend(['passwd-file', secrets_path])
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30,
                env=_nm_env()
            )

        if result.returncode != 0:
            stderr_lower = (result.stderr or '').lower()
            # Missing secrets is not transient: retrying 30 times only adds delay and noise.
            if (
                'no secrets' in stderr_lower
                or 'cannot ask without' in stderr_lower
                or 'password for' in stderr_lower
            ):
                return False, 'missing-secrets'

            if 'networkmanager is not running' in stderr_lower:
                return False, 'networkmanager-not-ready'

            logger.error(f"[WIFI CONNECT] Failed to activate connection to {connection_target}")
            logger.error(f"[WIFI CONNECT] Return code: {result.returncode}")
            logger.error(f"[WIFI CONNECT] stderr: {result.stderr}")
            logger.error(f"[WIFI CONNECT] stdout: {result.stdout}")
            return False, None

        logger.info(f"[WIFI CONNECT] Successfully connected to WiFi: {connection_target}")
        if password and use_uuid and _passphrase_is_stored(connection_target) is False:
            logger.warning(
                "[WIFI CONNECT] NetworkManager joined the network but did not store the passphrase in the "
                "profile: this device will not rejoin it after a reboot (it will offer the setup hotspot again)"
            )
        # Verify connection status
        verify_result = subprocess.run(
            ['nmcli', '-t', '-f', 'NAME,DEVICE,TYPE,STATE', 'connection', 'show', '--active'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if verify_result.returncode == 0:
            logger.info(f"[WIFI CONNECT] Active connections: {verify_result.stdout.strip()}")
        return True, None

    except Exception as e:
        logger.error(f"[WIFI CONNECT] Exception connecting to WiFi {connection_target}: {e}", exc_info=True)
        return False, None

def disconnect_from_wifi():
    """Disconnect from current WiFi connection"""
    try:
        # Get the WiFi interface
        wifi_ifname = get_wifi_interface()
        logger.info(f"[WIFI DISCONNECT] Disconnecting WiFi interface: {wifi_ifname}")
        
        # Check current connection status before disconnecting
        status_result = subprocess.run(
            ['nmcli', '-t', '-f', 'DEVICE,STATE', 'device', 'status'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if status_result.returncode == 0:
            logger.info(f"[WIFI DISCONNECT] Device status before disconnect: {status_result.stdout.strip()}")
        
        # Disconnect the active connection
        result = subprocess.run(
            ['nmcli', 'device', 'disconnect', wifi_ifname],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            logger.warning(f"[WIFI DISCONNECT] Failed to disconnect WiFi: {result.stderr}")
            logger.warning(f"[WIFI DISCONNECT] stdout: {result.stdout}")
            # Try alternative method - down the interface
            logger.info(f"[WIFI DISCONNECT] Attempting alternative disconnect method...")
            subprocess.run(['ip', 'link', 'set', wifi_ifname, 'down'], timeout=5)
        else:
            logger.info(f"[WIFI DISCONNECT] Successfully disconnected from WiFi: {wifi_ifname}")
        
        # Verify disconnection
        verify_result = subprocess.run(
            ['nmcli', '-t', '-f', 'DEVICE,STATE', 'device', 'status'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if verify_result.returncode == 0:
            logger.info(f"[WIFI DISCONNECT] Device status after disconnect: {verify_result.stdout.strip()}")
        
        return True
        
    except Exception as e:
        logger.error(f"[WIFI DISCONNECT] Exception disconnecting WiFi: {e}", exc_info=True)
        return False

def _run_script(argv, timeout):
    """Run a helper script and return its exit status. On timeout the script gets SIGTERM
    first and a grace period, so the cleanup trap in setup-device-hotspot-start.sh runs;
    subprocess.run(timeout=...) would SIGKILL it halfway through an AP start and leave the
    radio unmanaged with an address on it."""
    proc = subprocess.Popen(argv)
    try:
        return proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        logger.warning(f"{argv[0]} did not finish within {timeout}s; asking it to stop")
        proc.terminate()
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        raise


def stop_hotspot_services():
    """End the access-point episode: stop hostapd, dnsmasq and the nginx portal, drop the
    AP address and give the radio back to NetworkManager. All of it is done by the hotspot
    script's `stop` mode, which undoes exactly what its start did."""
    try:
        logger.info("Stopping hotspot services...")
        try:
            status = _run_script([HOTSPOT_SCRIPT, 'stop'], timeout=60)
        except Exception as e:
            logger.warning(f"Hotspot teardown script could not run ({e})")
            status = None
        if status != 0:
            # Missing script, timeout or failure: at least stop the radio services, as the
            # service always did.
            logger.warning("Stopping the hotspot units directly")
            subprocess.run(['systemctl', 'stop', 'dnsmasq-setup.service'], timeout=5)
            subprocess.run(['systemctl', 'stop', 'hostapd-setup.service'], timeout=5)

        logger.info("Hotspot services stopped")
        return True

    except Exception as e:
        logger.error(f"Error stopping hotspot services: {e}")
        return False

def start_hotspot_services():
    """Start the setup hotspot again after a join attempt that stopped it and failed.

    Only for that case. Nothing triggered by a request's own content may call this: it
    drops every client off the access point. The start script takes its own lock, so a
    call that races the monitor's does nothing."""
    try:
        logger.info("Starting hotspot services...")
        status = _run_script([HOTSPOT_SCRIPT], timeout=120)
        if status != 0:
            logger.warning(f"Hotspot start exited with status {status}")
            return False
        logger.info("Hotspot services started")
        return True
    except Exception as e:
        logger.error(f"Error starting hotspot services: {e}")
        return False

def remove_setup_netplan_config():
    """Remove netplan static IP config to allow NetworkManager to take over"""
    try:
        netplan_file = NETPLAN_SETUP_FILE
        if netplan_file.exists():
            logger.info("Removing setup-mode netplan configuration...")
            netplan_file.unlink()
            
            # Apply netplan changes
            result = subprocess.run(
                ['netplan', 'apply'],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode != 0:
                logger.warning(f"netplan apply warning: {result.stderr}")
            else:
                logger.info("Netplan configuration removed and applied")
            
            return True
        else:
            logger.info("No setup-mode netplan config found (already removed)")
            return True
            
    except Exception as e:
        logger.error(f"Error removing netplan config: {e}")
        return False

def wait_for_networkmanager_ready(timeout=20):
    """Wait until NetworkManager is active and can answer nmcli queries."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            active = subprocess.run(
                ['systemctl', 'is-active', 'NetworkManager.service'],
                capture_output=True,
                text=True,
                timeout=3
            )
            if active.returncode != 0 or active.stdout.strip() != 'active':
                time.sleep(1)
                continue

            nmcli_ping = subprocess.run(
                ['nmcli', '-t', '-f', 'RUNNING', 'general'],
                capture_output=True,
                text=True,
                timeout=3
            )
            if nmcli_ping.returncode == 0 and 'running' in (nmcli_ping.stdout or '').lower():
                logger.info("NetworkManager is active and ready")
                return True
        except Exception:
            pass

        time.sleep(1)

    logger.warning("NetworkManager did not become ready within timeout")
    return False

_STARTED_AT = time.monotonic()

@app.route('/api/health', methods=['GET'])
@app.route('/health', methods=['GET'])
def health():
    """Liveness. The portal polls /api/health (nginx proxies only /api/, so /health was
    unreachable through it and every poll was a 404); /health stays for checks on loopback.

    Open to anyone who can reach the API, so it carries only fields that are no secret and
    no use to an attacker: no SSID, no pairing code, no paths, no versions of anything.
    """
    return jsonify({
        'status': 'ok',
        'service': 'setup-backend',
        'uptime_seconds': int(time.monotonic() - _STARTED_AT),
        'setup_complete': SETUP_COMPLETE_FILE.exists(),
        'configuring': CONFIGURING_FLAG.exists(),
        'pairing_code_error': _pairing_code_error,
    })

@app.route('/api/status', methods=['GET'])
def status():
    """Get setup status"""
    setup_complete = SETUP_COMPLETE_FILE.exists()
    pairing_code = load_pairing_code()
    hub_state = get_hub_pairing_state()
    
    return jsonify({
        'setup_complete': setup_complete,
        'pairing_code_available': pairing_code is not None,
        'pairing_code_error': _pairing_code_error,
        'last_pairing_error': load_pairing_failure(),
        'hub_running': hub_state['hub_running'],
        'hub_registered': hub_state['hub_registered'],
        'require_pairing': hub_state['require_pairing'],
    })

LAST_SCAN_FILE = DATA_DIR / 'last-scan.json'


def _get_cached_networks():
    """Read static network list from prescan (file only, no chip access)."""
    try:
        if LAST_SCAN_FILE.exists():
            data = json.loads(LAST_SCAN_FILE.read_text())
            return data.get('networks', [])
    except Exception as e:
        logger.warning(f"Could not read last-scan: {e}")
    return []


@app.route('/api/networks', methods=['GET'])
@app.route('/api/scan-networks', methods=['GET'])  # Legacy; same behavior
def get_networks():
    """Return static network list (prescanned at hotspot start). Never triggers a scan."""
    networks = _get_cached_networks()
    return jsonify({'networks': networks})

@app.route('/api/ssid-suffix', methods=['GET'])
def ssid_suffix():
    """Get current hotspot SSID suffix (e.g. XJ4T for Companion-Setup-XJ4T)"""
    try:
        suffix_file = DATA_DIR / 'ssid-suffix'
        if suffix_file.exists():
            suffix = suffix_file.read_text().strip()
            return jsonify({'ssid_suffix': suffix, 'ssid': f'Companion-Setup-{suffix}'})
    except Exception as e:
        logger.warning(f"Could not read SSID suffix: {e}")
    return jsonify({'ssid_suffix': '', 'ssid': 'Companion-Setup'})

@app.route('/api/setup-data', methods=['GET'])
def setup_data():
    """Single bootstrap endpoint: all cached data for the form (networks + SSID). One fetch on load, no scan."""
    networks = _get_cached_networks()
    ssid_suffix_val = ''
    ssid_val = 'Companion-Setup'
    try:
        suffix_file = DATA_DIR / 'ssid-suffix'
        if suffix_file.exists():
            ssid_suffix_val = suffix_file.read_text().strip()
            ssid_val = f'Companion-Setup-{ssid_suffix_val}' if ssid_suffix_val else 'Companion-Setup'
    except Exception as e:
        logger.warning(f"Could not read SSID suffix: {e}")
    return jsonify({'networks': networks, 'ssid_suffix': ssid_suffix_val, 'ssid': ssid_val})

def _hotspot_active():
    """True when the setup AP is up, i.e. a portal client may be connected through it."""
    try:
        return subprocess.run(
            ['systemctl', 'is-active', '--quiet', 'hostapd-setup.service'],
            timeout=5
        ).returncode == 0
    except Exception as e:
        logger.debug(f"Could not query hostapd-setup.service state: {e}")
        return False

# Present while _connect_and_pair() owns the radio (hotspot stopped, WiFi not yet up).
# setup-network-monitor.sh holds off restarting the hotspot while it exists and is
# recent. In /run so a crash-and-reboot never leaves it behind.
CONFIGURING_FLAG = RUN_DIR / 'configuring'

def _mark_configuring(active):
    try:
        if active:
            CONFIGURING_FLAG.parent.mkdir(parents=True, exist_ok=True)
            CONFIGURING_FLAG.touch()
        else:
            CONFIGURING_FLAG.unlink(missing_ok=True)
    except Exception as e:
        logger.warning(f"Could not update {CONFIGURING_FLAG}: {e}")

def _wants_json():
    """The portal posts FormData (not JSON) but asks for JSON back via Accept."""
    return request.is_json or 'application/json' in request.headers.get('Accept', '')

# One configure attempt at a time: a second submit while the first is still joining
# WiFi would race it for the same radio and NetworkManager profile. configure() takes
# it; whoever finishes the attempt (configure() itself, or the background thread it
# hands off to) releases it.
_configure_lock = threading.Lock()

def _spawn_background_configure(ssid, password, pairing_code, connection_uuid, require_pairing, hub_state):
    """Run _connect_and_pair() in a background thread. Caller holds _configure_lock;
    the thread releases it."""
    def run():
        try:
            # Let the response reach the client before the hotspot goes down
            # (_connect_and_pair waits a further 2s for the driver before stopping it).
            time.sleep(1)
            with app.app_context():
                result = _connect_and_pair(
                    ssid, password, pairing_code, connection_uuid, require_pairing, hub_state,
                    want_json=True
                )
            status_code = result[1] if isinstance(result, tuple) else 200
            logger.info(f"[CONFIGURE-BG] Finished with status {status_code}")
        except Exception as e:
            logger.error(f"[CONFIGURE-BG] Unexpected failure: {e}", exc_info=True)
        finally:
            _configure_lock.release()

    threading.Thread(target=run, name='configure-bg', daemon=True).start()

def _pending_response(ssid, require_pairing, want_json):
    """Reply for an attempt that continues in the background after the hotspot closes."""
    redirect_metadata = _build_redirect_metadata()
    message = (
        f'Settings saved. The setup hotspot will now close and the device will join "{ssid}". '
        'Reconnect this phone to your usual network to continue.'
    )
    if want_json:
        return jsonify({
            'status': 'pending',
            'message': message,
            'ssid': ssid,
            'pairing_required': require_pairing,
            **redirect_metadata,
        }), 202
    portal = html_escape(redirect_metadata['redirect_url'])
    return f'''
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Setup In Progress</title>
        <style>
            body {{ font-family: -apple-system, sans-serif; text-align: center; padding: 50px; background: #0d1f1b; color: #e8f4f2; }}
            .success {{ color: #72ddd4; font-size: 24px; margin-bottom: 16px; }}
            a {{ color: #00a9a7; }}
        </style>
    </head>
    <body>
        <div class="success">Settings saved</div>
        <p>{html_escape(message)}</p>
        <p style="margin-top: 24px;">Then open <a href="{portal}">{portal}</a>.</p>
    </body>
    </html>
    ''', 202

def _configure_wired(ssid, password, pairing_code, connection_uuid, hub_state, want_json):
    """Wired setup: pair over the uplink that already has internet, while the hotspot is up.

    The phone is still on the hotspot, so it gets the real pairing result (success with
    the device-domain redirect, or the exact refusal) instead of a "pending" guess. Only
    after a successful pair does the device close the hotspot and join WiFi -- without
    pairing again. On failure the hotspot and form stay up so the user can retry at once.

    Nothing is routed for hotspot clients: no NAT, no upstream DNS. The phone follows the
    redirect after it is back on its own network, so the setup AP never becomes a way
    onto the internet or the wired LAN.

    Returns (response, handed_off): handed_off means the background thread now owns
    _configure_lock.
    """
    logger.info("[CONFIGURE-WIRED] Wired uplink has internet; pairing before the hotspot closes")
    clear_pairing_failure()
    message = (
        f'Device paired. The setup hotspot will close in a few seconds and the device will '
        f'join "{ssid}". Reconnect this phone to your usual network to continue.'
    )
    response = _pair_with_cloud(
        pairing_code, hub_state, want_json,
        success_extra={'flow': 'wired', 'message': message},
    )
    status_code = response[1] if isinstance(response, tuple) else 200
    if status_code != 200:
        logger.info(f"[CONFIGURE-WIRED] Pairing did not succeed ({status_code}); hotspot stays up for a retry")
        return response, False
    _spawn_background_configure(ssid, password, pairing_code, connection_uuid, False, hub_state)
    return response, True

def _read_configure_request():
    """Parse and validate the body of POST /api/configure WITHOUT any side effect.

    Returns (fields, None) on success, where fields is a dict with the cleaned `ssid`,
    `password` and `pairing_code` strings, or (None, (response, status)) for the 400 to
    send. Everything that can be wrong with the request itself is decided here, before the
    radio lock is taken and before NetworkManager, the hotspot or the cloud is touched: a
    malformed body used to fall into configure()'s catch-all, which restarted the access
    point and dropped every connected client.
    """
    if request.is_json:
        # silent=True: a body that is not JSON gives None (-> 400 below), not an exception.
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            return None, (jsonify({'error': 'Request body must be a JSON object'}), 400)
    else:
        data = request.form.to_dict()

    if not data:
        return None, (jsonify({'error': 'No data provided'}), 400)

    raw_ssid = data.get('ssid', '')
    raw_password = data.get('password', '')
    raw_pairing_code = data.get('pairing_code', '')
    # An absent or null field is the empty string; anything else that is not text is a bad request.
    if raw_password is None:
        raw_password = ''
    if raw_pairing_code is None:
        raw_pairing_code = ''
    if raw_ssid is None:
        raw_ssid = ''
    for value in (raw_ssid, raw_password, raw_pairing_code):
        if not isinstance(value, str):
            return None, (jsonify({'error': 'ssid, password and pairing_code must be text'}), 400)
    if len(raw_pairing_code) > 64:
        return None, (jsonify({'error': 'Pairing code is too long'}), 400)

    if not raw_ssid:
        return None, (jsonify({'error': 'SSID required'}), 400)
    try:
        ssid = validate_ssid(raw_ssid)
        password = validate_psk(raw_password) if raw_password else ''
    except InvalidInput as e:
        return None, (jsonify({'error': str(e)}), 400)

    # From here the passphrase and the code are known secrets: keep them out of every log line.
    _register_secret(password)
    _register_secret(normalize_pairing_code(raw_pairing_code))
    return {'ssid': ssid, 'password': password, 'pairing_code': raw_pairing_code}, None


@app.route('/api/configure', methods=['POST'])
def configure():
    """Configure WiFi connection"""
    fields, bad_request = _read_configure_request()
    if bad_request is not None:
        return bad_request
    ssid = fields['ssid']
    password = fields['password']
    pairing_code = fields['pairing_code']

    if not _configure_lock.acquire(blocking=False):
        # Another attempt (possibly in the background) still owns the radio.
        return jsonify({'error': 'Setup is already in progress. Please wait.'}), 409
    handed_off = False
    try:
        hub_state = get_hub_pairing_state()
        require_pairing = hub_state['require_pairing']
        logger.info(
            f"[CONFIGURE] Hub state: running={hub_state['hub_running']}, "
            f"registered={hub_state['hub_registered']}, require_pairing={require_pairing}"
        )

        if require_pairing and not pairing_code:
            return jsonify({'error': 'Pairing code required for unregistered Hub'}), 400

        normalized_code = normalize_pairing_code(pairing_code) if pairing_code else ''
        if require_pairing and len(normalized_code) != 6:
            return jsonify({'error': 'Pairing code must be 6 characters'}), 400

        logger.info("[CONFIGURE] Starting WiFi configuration")
        logger.info(f"[CONFIGURE] SSID: {ssid}")
        if require_pairing:
            logger.info("[CONFIGURE] Pairing code required for this device state")
        else:
            logger.info("[CONFIGURE] Pairing code not required for this device state")
        logger.info(f"[CONFIGURE] Password provided: {'Yes' if password else 'No (open network)'}")

        active_wifi = get_active_wifi_connection()
        if active_wifi and _connection_name_matches_ssid(active_wifi.get('name', ''), ssid):
            connection_uuid = active_wifi['uuid']
            logger.info(
                f"[CONFIGURE] Device already connected to requested SSID via "
                f"{active_wifi.get('name')} (uuid={connection_uuid}); reusing existing profile"
            )
        else:
            # Create NetworkManager connection
            logger.info(f"[CONFIGURE] Creating NetworkManager connection for {ssid}...")
            connection_uuid = create_wifi_connection(ssid, password)
            if not connection_uuid:
                logger.error(f"[CONFIGURE] Failed to create WiFi connection for {ssid}")
                return jsonify({'error': 'Failed to create WiFi connection'}), 500
            logger.info(f"[CONFIGURE] NetworkManager connection created successfully (uuid={connection_uuid})")

        # Persist credentials securely (root-only from the first byte, replaced atomically)
        try:
            credentials = {
                'ssid': ssid,
                'password': password,
                'configured_at': datetime.now().isoformat()
            }
            _write_secret_file(CREDENTIALS_JSON, json.dumps(credentials, indent=2))
        except Exception as e:
            logger.error(f"Failed to save credentials: {e}")

        # NOTE: We do NOT create setup-complete flag - it should not gate hotspot operations
        # The network monitor runs independently and starts hotspot if no connectivity detected
        # Setup is complete when WiFi connection is active, not when the flag is written

        want_json = _wants_json()
        if _hotspot_active():
            # The client reached this form over the setup hotspot, and the radio serving
            # that hotspot is the one that must join the user's WiFi.
            if require_pairing and check_internet_connectivity(timeout=3):
                # Wired: another uplink already has internet, so pair now and answer
                # with the real result before touching the hotspot.
                response, handed_off = _configure_wired(
                    ssid, password, pairing_code, connection_uuid, hub_state, want_json
                )
                return response
            # WiFi only: anything done synchronously from here stops the hotspot before
            # the response is written. Answer first; finish (WiFi join, cloud pairing,
            # Hub hand-off) in the background. A failure is recorded for /api/status
            # (last_pairing_error) and shown on the next visit.
            _spawn_background_configure(
                ssid, password, pairing_code, connection_uuid, require_pairing, hub_state
            )
            handed_off = True
            return _pending_response(ssid, require_pairing, want_json)
        return _connect_and_pair(
            ssid, password, pairing_code, connection_uuid, require_pairing, hub_state, want_json
        )
    except Exception as e:
        # Nothing here touches the access point. This block runs BEFORE the join stops it, so
        # the hotspot is still up and the client can simply retry; restarting it from here
        # would drop every connected client for any request that merely failed. (Once
        # _connect_and_pair has stopped the hotspot, it restores it itself.)
        logger.error(f"Configuration error: {e}", exc_info=True)
        return jsonify({'error': 'Internal server error'}), 500
    finally:
        if not handed_off:
            _configure_lock.release()

def _connect_and_pair(ssid, password, pairing_code, connection_uuid, require_pairing, hub_state, want_json):
    """Stop the hotspot, join the configured WiFi, and pair with the cloud.

    Returns the Flask response for /api/configure. Runs inline when the client is not
    on the setup hotspot (it reached the portal over the LAN), and in a background
    thread -- whose return value nobody reads -- when it is; see configure().
    """
    _mark_configuring(True)
    hotspot_stopped = False
    try:
        # A new attempt: whatever failed last time is no longer the current state.
        clear_pairing_failure()

        # Stop hotspot services - allow time for driver to release AP mode
        time.sleep(2)
        hotspot_stopped = True
        stop_hotspot_services()
        time.sleep(3)  # Driver recovery: some chips need delay before station mode
        
        # Re-manage WiFi interface (hotspot script sets managed=no; NM needs it for connect)
        wifi_iface = get_wifi_interface()
        try:
            subprocess.run(['nmcli', 'device', 'set', wifi_iface, 'managed', 'yes'],
                          capture_output=True, timeout=5)
        except Exception as e:
            logger.debug(f"Could not set WiFi managed: {e}")
        
        # Unblock WiFi before NM connect
        try:
            subprocess.run(['rfkill', 'unblock', 'wifi'], capture_output=True, timeout=2)
        except Exception as e:
            logger.debug(f"rfkill unblock wifi failed (best-effort, non-fatal): {e}")
        
        # Remove netplan static IP config to allow NetworkManager to manage the interface
        time.sleep(1)
        remove_setup_netplan_config()

        # netplan apply may briefly restart NetworkManager; wait until it is ready.
        wait_for_networkmanager_ready(timeout=20)
        
        # Step 1: Connect to WiFi first
        logger.info(f"Connecting to WiFi network: {ssid} (uuid={connection_uuid})")
        wifi_connected = False
        max_wifi_wait = 30  # Wait up to 30 seconds for WiFi connection
        for i in range(max_wifi_wait):
            connected, failure_reason = connect_to_wifi(connection_uuid, use_uuid=True, password=password)
            if connected:
                wifi_connected = True
                logger.info("WiFi connection established")
                break

            if failure_reason == 'missing-secrets':
                if password:
                    # Password was provided but NM still reports missing credentials - tell user
                    logger.warning("Selected WiFi network requires additional credentials that were not provided")
                    record_pairing_failure(
                        'WIFI_CREDENTIALS',
                        f'WiFi network "{ssid}" rejected the credentials. Re-enter the WiFi details and try again.'
                    )
                    return jsonify({
                        'error': 'Selected WiFi network requires credentials that were not provided. Please re-enter WiFi details and try again.'
                    }), 400
                else:
                    # Open network: nmcli reports missing-secrets but the network may connect anyway
                    # Skip the nmcli check and proceed to the internet connectivity wait below
                    logger.info("Open network: nmcli reports missing-secrets, proceeding to connectivity wait")
                    wifi_connected = True
                    break

            if failure_reason == 'networkmanager-not-ready':
                logger.info("NetworkManager is restarting; retrying WiFi connection")
                time.sleep(1)
                continue

            logger.info(f"Waiting for WiFi connection... ({i+1}/{max_wifi_wait})")
            time.sleep(1)
        
        if wifi_connected:
            logger.info("WiFi connection successful")
        else:
            # Do not hard-fail here. The adapter can associate shortly after nmcli
            # reports failure; use the connectivity window as the source of truth.
            logger.warning(
                "WiFi did not report connected during initial activation window; "
                "continuing with registration connectivity window"
            )

        # Step 2: Wait for internet connectivity to be established.
        # This catches delayed association/DHCP after retries/fallbacks.
        max_wait = max(1, REGISTRATION_CONNECTIVITY_WINDOW_SECONDS)
        logger.info(
            "Waiting up to %ss for internet connectivity before cloud registration...",
            max_wait,
        )
        internet_available = False
        for i in range(max_wait):
            if check_internet_connectivity(timeout=3):
                internet_available = True
                logger.info("Internet connectivity confirmed")
                break
            if (i + 1) % 5 == 0:  # Log every 5 seconds
                logger.info(f"Waiting for internet connectivity... ({i+1}/{max_wait})")
            time.sleep(1)
        
        redirect_metadata = _build_redirect_metadata()

        if not internet_available:
            logger.warning("Internet connectivity not available within registration window. Cloud registration skipped.")
            if not wifi_connected:
                # Never associated: most often a wrong password that NetworkManager does
                # not report as missing-secrets. Say so on the next portal visit.
                record_pairing_failure(
                    'WIFI_CONNECT_FAILED',
                    f'Could not join WiFi network "{ssid}". Check the password and try again.'
                )
            # Setup may still be converging; cloud registration can happen later.
            # The device will work on local network, cloud registration can happen later
            if want_json:
                return jsonify({
                    'status': 'success',
                    'message': 'WiFi configuration submitted. Internet connectivity not yet available.',
                    'internet_available': False,
                    **redirect_metadata,
                })
            else:
                return '''
                <!DOCTYPE html>
                <html>
                <head>
                    <meta charset="UTF-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <title>Setup Complete</title>
                    <style>
                        body { font-family: sans-serif; text-align: center; padding: 50px; }
                        .success { color: green; font-size: 24px; margin-bottom: 20px; }
                        .info { color: #666; font-size: 14px; }
                    </style>
                </head>
                <body>
                    <div class="success">✓ WiFi configured successfully!</div>
                    <p class="info">Device is connected to WiFi. Internet connectivity will be available shortly.</p>
                </body>
                </html>
                ''', 200
        
        if not require_pairing:
            logger.info("Internet connectivity confirmed. Hub already registered (or not running), skipping pairing workflow.")
            if want_json:
                return jsonify({
                    'status': 'success',
                    'message': 'WiFi configured successfully',
                    'pairing_required': False,
                    **redirect_metadata,
                })
            return '''
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>Setup Complete</title>
                <style>
                    body { font-family: sans-serif; text-align: center; padding: 50px; }
                    .success { color: green; font-size: 24px; margin-bottom: 20px; }
                </style>
            </head>
            <body>
                <div class="success">✓ Device configured successfully!</div>
                <p>The device will connect to the network shortly.</p>
            </body>
            </html>
            ''', 200

        return _pair_with_cloud(pairing_code, hub_state, want_json)

    except Exception as e:
        logger.error(f"Configuration error: {e}", exc_info=True)
        if hotspot_stopped:
            # This attempt took the access point down and failed before it could finish:
            # restore it so the user can retry. (Never done for a failure before that point.)
            try:
                start_hotspot_services()
            except Exception as hotspot_err:
                logger.warning(
                    "Failed to restore hotspot services after configuration error: %s",
                    hotspot_err, exc_info=True
                )
        return jsonify({'error': 'Internal server error'}), 500
    finally:
        _mark_configuring(False)

def _pair_with_cloud(pairing_code, hub_state, want_json, success_extra=None):
    """Validate the pairing code with CI Portal, register this device, hand off to the Hub.

    Needs internet. Called by _connect_and_pair() once the device has joined WiFi, and by
    _configure_wired() straight away when a wired uplink already has internet. Returns the
    Flask response for /api/configure; `success_extra` is merged into the JSON success body.
    """
    redirect_metadata = _build_redirect_metadata()
    pairing_failure = None

    # Step 3: Now that we have internet, validate pairing code with cloud
    logger.info("Internet connectivity confirmed. Starting cloud device registration...")

    try:
        # Normalize pairing code to uppercase before cloud validation
        normalized_pairing_code = normalize_pairing_code(pairing_code)
        _register_secret(normalized_pairing_code)
        logger.info("Getting pairing info from cloud for the submitted pairing code")
        success, pairing_info = get_pairing_info_from_cloud(normalized_pairing_code)

        if not success:
            logger.error(f"Failed to get pairing info from cloud ({_describe_cloud_payload(pairing_info)})")
            # Keep WiFi connected. Registration can be retried without forcing users back to AP mode.
            error_msg = 'Failed to validate pairing code with cloud service. Device stayed connected; please verify pairing code and retry.'
            record_pairing_failure('CLOUD_VALIDATION_FAILED', 'CI Portal could not validate the pairing code. Check the code and try again.')
            if want_json:
                return jsonify({'error': error_msg, 'status': 'cloud_error', 'internet_available': True}), 500
            else:
                return f'''
                <!DOCTYPE html>
                <html>
                <head>
                    <meta charset="UTF-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <title>Setup Error</title>
                    <style>
                        body {{ font-family: sans-serif; text-align: center; padding: 50px; }}
                        .error {{ color: #ff4444; font-size: 18px; margin-bottom: 20px; }}
                    </style>
                </head>
                <body>
                    <div class="error">✗ {error_msg}</div>
                    <p>Please retry setup from your current network connection.</p>
                </body>
                </html>
                ''', 500
        else:
            # Extract pairing metadata from response (supports snake_case + camelCase)
            cloud_device_id = pairing_info.get('device_id') or pairing_info.get('deviceId')
            api_key = pairing_info.get('api_key')
            cloud_pairing_code = pairing_info.get('pairing_code') or pairing_info.get('pairingCode', '')
            _register_secret(api_key)
            _register_secret(normalize_pairing_code(cloud_pairing_code) if isinstance(cloud_pairing_code, str) else '')

            if not cloud_device_id:
                logger.warning(f"Missing device_id in cloud response ({_describe_cloud_payload(pairing_info)})")
            else:
                # Validate pairing code matches (case-insensitive comparison)
                user_code_normalized = normalize_pairing_code(pairing_code)
                cloud_code_normalized = normalize_pairing_code(cloud_pairing_code)

                logger.info("[PAIRING VALIDATION] Comparing pairing codes")

                if cloud_code_normalized and user_code_normalized != cloud_code_normalized:
                    # Neither code is logged: both are secrets, and the cloud's is the one that works.
                    logger.error("[PAIRING VALIDATION] MISMATCH between the submitted code and the cloud's")
                    logger.info("[PAIRING VALIDATION] Pairing mismatch detected; keeping WiFi connected for retry")
                    record_pairing_failure('PAIRING_MISMATCH', 'The pairing code did not match. Check the code and try again.')

                    # Return error response
                    if want_json:
                        return jsonify({
                            'error': 'Pairing code does not match. Please try again.',
                            'status': 'pairing_mismatch',
                            'internet_available': True
                        }), 400
                    else:
                        return '''
                            <!DOCTYPE html>
                            <html>
                            <head>
                                <meta charset="UTF-8">
                                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                                <title>Setup Error</title>
                                <style>
                                    body { font-family: sans-serif; text-align: center; padding: 50px; }
                                    .error { color: #ff4444; font-size: 18px; margin-bottom: 20px; }
                                </style>
                            </head>
                            <body>
                                <div class="error">✗ Pairing code does not match</div>
                                <p>Please retry setup from your current network connection.</p>
                            </body>
                            </html>
                            ''', 400

                if api_key:
                    logger.info(
                        f"Retrieved from cloud - device_id: {cloud_device_id}, "
                        "api_key: present, pairing_code matches"
                    )
                    logger.info("[CREDENTIALS] Saving API key from cloud GET response")
                    save_cloud_credentials(cloud_device_id, api_key)
                else:
                    logger.info(
                        f"Retrieved from cloud - device_id: {cloud_device_id}, "
                        "api_key not provided by GET /pair"
                    )

                # Step 3: Get the actual device ID from local machine (used for DB update and Hub)
                local_device_id = get_device_id()
                logger.info(f"Local device ID: {local_device_id}")

                # Step 4: POST to update device_id in cloud (upsert where pairing_code matches)
                logger.info("Updating device_id in cloud...")
                update_success, update_resp = update_device_id_in_cloud(
                    pairing_code=normalized_pairing_code,
                    device_id=local_device_id,
                    api_key=api_key
                )

                if update_success:
                    logger.info(f"Device ID updated successfully in cloud ({_describe_cloud_payload(update_resp)})")
                    clear_pairing_failure()
                    redirect_metadata = _build_redirect_metadata(update_resp, pairing_info)
                    # Persist api_key from POST response if it was not present in GET response.
                    post_api_key = None
                    if isinstance(update_resp, dict):
                        post_api_key = update_resp.get('api_key')
                        post_device_id = update_resp.get('device_id') or local_device_id
                        if post_api_key:
                            logger.info("[CREDENTIALS] Saving API key from cloud POST response")
                            save_cloud_credentials(post_device_id, post_api_key)
                    if hub_state.get('hub_running'):
                        callback_ok = notify_hub_registration_callback(update_resp)
                        if not callback_ok:
                            logger.warning(
                                "Cloud registration completed, but failed to forward callback to Hub. "
                                "Hub may remain on registration page until manual refresh/retry."
                            )
                    else:
                        # Hub not running yet: write hub.env (CI_ZONE_ID, DEVICE_ID, API_KEY) and
                        # trigger Hub download/start (no-op if Hub is not installed on this image).
                        # The POST response is the key's source of truth: GET /pair answers with
                        # only `deviceId` and `status`, so `api_key` from there is all but always
                        # absent and writing it would leave the Hub with no credential.
                        save_hub_env(local_device_id, post_api_key or api_key)
                        try:
                            subprocess.run(
                                [HUB_START_SCRIPT],
                                capture_output=True, timeout=30
                            )
                        except Exception as hub_err:
                            logger.debug(f"Hub start script not available or failed: {hub_err}")
                    # API key already saved from GET response, no need to save again
                else:
                    # The Portal names its own refusals -- DEVICE_PROOF_REQUIRED when it
                    # wants this hardware's key, DEVICE_REGISTERED_ELSEWHERE when another
                    # organization holds it. Carry its code and sentence through rather
                    # than flattening every cause into one message.
                    detail = update_resp if isinstance(update_resp, dict) else {}
                    pairing_failure = {
                        'code': detail.get('code') or 'PAIRING_FAILED',
                        'message': detail.get('error') or detail.get('message') or 'The device could not be paired.',
                    }
                    logger.warning(
                        f"Pairing refused by the Portal: {pairing_failure['code']} - {pairing_failure['message']}"
                    )
                    record_pairing_failure(pairing_failure['code'], pairing_failure['message'])
                    redirect_metadata = _build_redirect_metadata(pairing_info)

    except Exception as e:
        logger.error(f"Exception during cloud registration: {e}", exc_info=True)
        pairing_failure = {
            'code': 'PAIRING_ERROR',
            'message': 'The device could not reach CI Portal to complete pairing.',
        }
        record_pairing_failure(pairing_failure['code'], pairing_failure['message'])

    # A refused pair is not a successful setup. WiFi is up either way, so the
    # message says so -- the remedy is re-registration by an owner or admin, not
    # re-entering network credentials. No redirect metadata: there is no device
    # domain to send anyone to.
    if pairing_failure:
        if want_json:
            return jsonify({
                'status': 'pairing_failed',
                'code': pairing_failure['code'],
                'error': pairing_failure['message'],
                'wifi_configured': True,
            }), 502
        return f'''
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Pairing Failed</title>
            <style>
                body {{ font-family: -apple-system, sans-serif; text-align: center; padding: 50px; background: #0d1f1b; color: #e8f4f2; }}
                .error {{ color: #ffb4b4; font-size: 24px; margin-bottom: 16px; }}
                .info {{ color: #9fb8b4; font-size: 14px; }}
            </style>
        </head>
        <body>
            <div class="error">Device could not be paired</div>
            <p class="info">{html_escape(pairing_failure['message'])}</p>
            <p class="info">WiFi is configured and the device is online. Pairing can be retried once this is resolved.</p>
        </body>
        </html>
        ''', 502

    # Return HTML response for form submissions, JSON for API calls
    if want_json:
        return jsonify({
            'status': 'success',
            'message': 'WiFi configured successfully',
            **redirect_metadata,
            **(success_extra or {}),
        })
    else:
        # Return HTML success page for form submissions
        return '''
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Setup Complete</title>
            <style>
                body { font-family: -apple-system, sans-serif; text-align: center; padding: 50px; background: #0d1f1b; color: #e8f4f2; }
                .success { color: #72ddd4; font-size: 24px; margin-bottom: 16px; }
                a { color: #00a9a7; }
            </style>
        </head>
        <body>
            <div class="success">Device configured successfully!</div>
            <p>The device will connect to the network shortly.</p>
            <p style="margin-top: 24px;"><a href="http://localhost:5002">Open Companion Hub</a> (on the device)</p>
        </body>
        </html>
        ''', 200

def main():
    """Main entry point - daemon-safe"""
    logger.info("Starting setup-backend service")

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Ensure pairing code exists on first boot
    global _pairing_code_error
    if ensure_pairing_code() is None:
        _pairing_code_error = True
        logger.critical(
            "Startup: no pairing code could be established. The setup portal will "
            "report pairing_code_error and this device cannot be paired."
        )
    
    logger.info(f"Pairing code file: {PAIRING_CODE_JSON}")
    logger.info(f"Setup complete file: {SETUP_COMPLETE_FILE}")

    # Run Flask app (dev fallback; production uses gunicorn via systemd)
    try:
        # Use stdlib WSGI server to avoid Flask development-server warnings.
        class QuietHandler(WSGIRequestHandler):
            def log_message(self, format, *args):
                logger.info("HTTP %s", format % args)

        httpd = make_server('127.0.0.1', 5000, app, handler_class=QuietHandler)
        httpd.timeout = 1
        logger.info("WSGI server listening on http://127.0.0.1:5000")

        while not shutdown_flag:
            httpd.handle_request()

        logger.info("Shutting down WSGI server")
        httpd.server_close()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
    except Exception as e:
        logger.error(f"Service error: {e}", exc_info=True)
        sys.exit(1)

if __name__ == '__main__':
    main()
