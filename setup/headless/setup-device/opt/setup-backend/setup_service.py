#!/usr/bin/env python3
"""
Setup Device Backend Service
Flask-based API for headless device WiFi configuration
Daemon-safe with signal handling
"""

import os
import sys
import json
import subprocess
import re
import time
import signal
import logging
import threading
from datetime import datetime, timedelta
from pathlib import Path
from wsgiref.simple_server import make_server, WSGIRequestHandler
from flask import Flask, request, jsonify
import urllib.request
import urllib.error
import urllib.parse

# Configuration paths
CONFIG_DIR = Path('/etc/setup-device')
DATA_DIR = Path('/var/lib/setup-device')
LOG_FILE = '/var/log/setup-backend.log'

USER_PAIRING_CODE_JSON = DATA_DIR / 'user_pairing_code.json'
SETUP_COMPLETE_FILE = DATA_DIR / 'setup-complete'
CREDENTIALS_JSON = DATA_DIR / 'credentials.json'
SCAN_CACHE_TXT = DATA_DIR / 'last_scan_networks.txt'

# CI-OS-Hub app install (after pairing)
HUB_APP_DIR = Path('/var/lib/ci-os-hub/app')
HUB_ENV_FILE = Path('/var/lib/ci-os-hub/.env')

# Cloud API config - can be set via environment `CI_CLOUD_API_URL`
# or via `/etc/setup-device/device.conf` value `CI_CLOUD_API_URL`.
def _read_conf_value(key):
    conf_file = CONFIG_DIR / 'device.conf'
    if not conf_file.exists():
        return None
    try:
        with open(conf_file, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if '=' in line:
                    k, v = line.split('=', 1)
                    if k.strip() == key:
                        return v.strip()
    except Exception:
        return None
    return None


def _read_int_env(name, default):
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default

CI_CLOUD_API_URL = os.environ.get('CI_CLOUD_API_URL') or _read_conf_value('CI_CLOUD_API_URL') or 'https://portal.companionintelligence.com/api/'
CI_HUB_REGISTRATION_STATUS_URL = os.environ.get('CI_HUB_REGISTRATION_STATUS_URL', 'http://127.0.0.1:5002/api/registration/status')
CI_HUB_REGISTRATION_CALLBACK_URL = os.environ.get('CI_HUB_REGISTRATION_CALLBACK_URL', 'http://127.0.0.1:5002/api/registration/callback')
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


def _hub_running():
    """Detect whether Companion Hub is running on the device."""
    try:
        proc = subprocess.run(
            ['pgrep', '-f', 'ci-os-hub-desktop'],
            capture_output=True,
            text=True,
            timeout=3
        )
        return proc.returncode == 0
    except Exception:
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
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=5,
                stderr=subprocess.DEVNULL
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
    url = _cloud_pairing_url() + f'?pairing_code={encoded_code}'
    logger.info(f"[CLOUD GET] Request URL: {url}")
    logger.info(f"[CLOUD GET] Pairing code (normalized): {normalized_code}")
    try:
        req = urllib.request.Request(url, headers=_cloud_request_headers(), method='GET')
        logger.info(f"[CLOUD GET] Sending GET request to cloud API...")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            logger.info(f"[CLOUD GET] Response status: {resp.status}")
            logger.info(f"[CLOUD GET] Response body: {body}")
            try:
                parsed = json.loads(body)
                if isinstance(parsed, dict):
                    device_id = parsed.get('device_id') or parsed.get('deviceId')
                    cloud_pairing_code = parsed.get('pairing_code') or parsed.get('pairingCode', '')
                    if device_id:
                        logger.info(
                            f"Retrieved pairing info from cloud: device_id={device_id}, "
                            f"pairing_code={cloud_pairing_code}"
                        )
                        return True, parsed
                    else:
                        logger.warning(f"Missing device_id in response: {parsed}")
                        return False, parsed
                return False, parsed
            except json.JSONDecodeError:
                logger.warning(f"Invalid JSON response: {body}")
                return False, body
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode('utf-8', errors='replace')
        except Exception:
            body = str(e)
        logger.error(f"[CLOUD GET] HTTP Error {e.code}: {body}")
        logger.error(f"[CLOUD GET] Request URL was: {url}")
        try:
            parsed = json.loads(body)
            return False, parsed
        except Exception:
            return False, body
    except Exception as e:
        logger.warning(f"Cloud pairing GET failed: {e}")
        return False, str(e)

def update_device_id_in_cloud(pairing_code, device_id, api_key=None, timeout=10):
    """POST request to /api/devices/pair to upsert device_id where pairing_code matches"""
    url = _cloud_pairing_url()
    
    # Normalize to uppercase (removes non-alphanumeric characters)
    normalized_code = normalize_pairing_code(pairing_code)
    
    payload = {
        'pairing_code': normalized_code,
        'device_id': device_id
    }
    
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
            logger.info(f"Device ID update response: {resp.status} {body}")
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
        logger.warning(f"Device ID update HTTP error: {e.code} {body}")
        try:
            parsed = json.loads(body)
            return False, parsed
        except Exception:
            return False, body
    except Exception as e:
        logger.warning(f"Device ID update failed: {e}")
        return False, str(e)


def notify_hub_registration_callback(cloud_response, retries=10, retry_delay=2):
    """Forward finalized cloud registration payload to CI Hub callback endpoint."""
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

        query = urllib.parse.urlencode({
            'device_id': cloud_response.get('device_id', ''),
            'organization_id': cloud_response.get('organization_id', ''),
            'organization_name': cloud_response.get('organization_name', ''),
            'slug': cloud_response.get('slug', ''),
            'subdomain': cloud_response.get('subdomain', ''),
            'tunnel_id': cloud_response.get('tunnel_id', ''),
            'tunnel_token': cloud_response.get('tunnel_token', ''),
            'api_key': cloud_response.get('api_key', ''),
            'domain': cloud_response.get('domain', ''),
        })

        callback_url = f"{CI_HUB_REGISTRATION_CALLBACK_URL}?{query}"

        for attempt in range(1, retries + 1):
            try:
                req = urllib.request.Request(callback_url, method='GET')
                with urllib.request.urlopen(req, timeout=6) as resp:
                    body = resp.read().decode('utf-8', errors='replace')
                    parsed = json.loads(body)
                    if isinstance(parsed, dict) and parsed.get('success'):
                        logger.info(f"Hub callback succeeded on attempt {attempt}: {CI_HUB_REGISTRATION_CALLBACK_URL}")
                        return True
                    logger.warning(f"Hub callback attempt {attempt} returned non-success payload: {parsed}")
            except Exception as e:
                logger.warning(f"Hub callback attempt {attempt}/{retries} failed: {e}")

            if attempt < retries:
                time.sleep(retry_delay)

        return False
    except Exception as e:
        logger.warning(f"Failed to invoke Hub callback: {e}")
        return False

def save_cloud_credentials(device_id, api_key):
    """Save device_id and api_key for later use (API key comes from GET response)"""
    try:
        credentials_file = DATA_DIR / 'cloud_credentials.json'
        credentials = {
            'device_id': device_id,
            'api_key': api_key,
            'saved_at': datetime.now().isoformat()
        }
        with open(credentials_file, 'w') as f:
            json.dump(credentials, f, indent=2)
        os.chmod(credentials_file, 0o600)
        logger.info(f"[CREDENTIALS] Saved: device_id={device_id}, api_key={api_key[:8]}...")
        return True
    except Exception as e:
        logger.error(f"Failed to save cloud credentials: {e}")
        return False


def _install_url():
    """Base URL for store install (no trailing slash)."""
    base = (os.environ.get('CI_CLOUD_API_URL') or _read_conf_value('CI_CLOUD_API_URL') or 'https://setup.companionintel.com').rstrip('/')
    if base.endswith('/api'):
        base = base[:-4]
    return f"{base}/api/store/ci-os-hub/install"


def install_and_start_ci_os_hub(device_id, api_key):
    """
    Fetch compose + config from store install, write to HUB_APP_DIR,
    docker login if image is from our registry, then docker compose up -d.
    Runs the whole app (one container from our registry).
    """
    try:
        url = _install_url()
        logger.info(f"[CI-OS-HUB] Fetching install from {url}")
        req = urllib.request.Request(url, headers={
            'x-device-id': device_id,
            'x-api-key': api_key,
        })
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
        files = data.get('files') or {}
        compose_str = files.get('docker-compose.json')
        config_str = files.get('config.json')
        if not compose_str:
            logger.error("[CI-OS-HUB] No docker-compose.json in install response")
            return False
        compose = json.loads(compose_str)
        # Docker Compose expects services to be a dict (name -> config), not array
        services = compose.get('services') or []
        if isinstance(services, list):
            compose['services'] = { (s.get('name') or f'svc_{i}'): {k: v for k, v in s.items() if k != 'name'} for i, s in enumerate(services) }
            services = compose['services']
        first_svc = next(iter(services.values()), {}) if isinstance(services, dict) and services else {}
        image = first_svc.get('image', '')
        # Our registry hosts (device_id / api_key login)
        registry_hosts = ('setup.companionintel.com', 'app.ci.computer', 'setup.companionintelligence.com')
        registry_host = None
        for h in registry_hosts:
            if image.startswith(h + '/') or image.startswith(h + ':'):
                registry_host = h
                break
        if registry_host:
            logger.info(f"[CI-OS-HUB] Logging into registry {registry_host}")
            try:
                proc = subprocess.run(
                    ['docker', 'login', registry_host, '--username', device_id, '--password-stdin'],
                    input=api_key.encode(),
                    capture_output=True,
                    timeout=15,
                )
                if proc.returncode != 0:
                    logger.warning(f"[CI-OS-HUB] docker login failed: {proc.stderr.decode()}")
            except Exception as e:
                logger.warning(f"[CI-OS-HUB] docker login error: {e}")
        HUB_APP_DIR.mkdir(parents=True, exist_ok=True)
        (HUB_APP_DIR / 'docker-compose.json').write_text(json.dumps(compose, indent=2), encoding='utf-8')
        if config_str:
            (HUB_APP_DIR / 'config.json').write_text(config_str, encoding='utf-8')
        # Write .env so the Hub container gets device_id and api_key
        HUB_ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
        HUB_ENV_FILE.write_text(f"DEVICE_ID={device_id}\nCI_HUB_API_KEY={api_key}\n", encoding='utf-8')
        logger.info("[CI-OS-HUB] Running docker compose up -d")
        subprocess.run(
            ['docker', 'compose', '-f', str(HUB_APP_DIR / 'docker-compose.json'), '--env-file', str(HUB_ENV_FILE), 'up', '-d'],
            cwd=str(HUB_APP_DIR),
            timeout=300,
            check=False,
        )
        logger.info("[CI-OS-HUB] Install and start completed")
        return True
    except Exception as e:
        logger.error(f"[CI-OS-HUB] Install/start failed: {e}", exc_info=True)
        return False

# Ensure directories exist
CONFIG_DIR.mkdir(parents=True, exist_ok=True)
DATA_DIR.mkdir(parents=True, exist_ok=True)
Path(LOG_FILE).parent.mkdir(parents=True, exist_ok=True)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Signal handling for graceful shutdown
shutdown_flag = False

def signal_handler(signum, frame):
    """Handle SIGTERM and SIGINT gracefully"""
    global shutdown_flag
    logger.info(f"Received signal {signum}, shutting down gracefully...")
    shutdown_flag = True

signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)

def normalize_pairing_code(code):
    """Normalize pairing code: remove non-alphanumeric characters, convert to uppercase"""
    return re.sub(r'[^A-Z0-9]', '', code.upper())

def save_user_pairing_code(code):
    """Save the user-entered pairing code to file"""
    try:
        pairing_data = {
            'code': normalize_pairing_code(code),
            'entered_at': datetime.now().isoformat()
        }
        with open(USER_PAIRING_CODE_JSON, 'w') as f:
            json.dump(pairing_data, f, indent=2)
        os.chmod(USER_PAIRING_CODE_JSON, 0o600)
        logger.info(f"Saved user pairing code")
        return True
    except Exception as e:
        logger.error(f"Failed to save user pairing code: {e}")
        return False

def _parse_nmcli_scan_lines(raw_lines):
    """Parse nmcli -t SSID,SIGNAL,SECURITY lines into unique network objects."""
    networks = []
    seen_ssids = set()

    for line in (raw_lines or '').strip().split('\n'):
        if not line:
            continue
        parts = line.split(':')
        if len(parts) >= 2:
            ssid = parts[0]
            signal = parts[1] if len(parts) > 1 else '0'
            security = parts[2] if len(parts) > 2 else ''

            if ssid and ssid not in seen_ssids:
                networks.append({
                    'ssid': ssid,
                    'signal': int(signal) if signal.isdigit() else 0,
                    'security': security if security else 'none'
                })
                seen_ssids.add(ssid)

    networks.sort(key=lambda x: x['signal'], reverse=True)
    return networks


def load_cached_wifi_networks():
    """Load cached pre-AP scan output captured before hotspot starts."""
    try:
        if not SCAN_CACHE_TXT.exists():
            return []

        with open(SCAN_CACHE_TXT, 'r') as f:
            cached = f.read()

        networks = _parse_nmcli_scan_lines(cached)
        if networks:
            logger.info(f"Using cached WiFi scan results ({len(networks)} networks)")
        return networks
    except Exception as e:
        logger.warning(f"Failed to load cached WiFi scan results: {e}")
        return []


def scan_wifi_networks():
    """Scan for available WiFi networks using nmcli with cached fallback in AP mode."""
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list'],
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode != 0:
            logger.error(f"WiFi scan failed: {result.stderr}")
            return load_cached_wifi_networks()

        networks = _parse_nmcli_scan_lines(result.stdout)
        if not networks:
            return load_cached_wifi_networks()

        return networks

    except subprocess.TimeoutExpired:
        logger.error("WiFi scan timed out")
        return load_cached_wifi_networks()
    except Exception as e:
        logger.error(f"WiFi scan error: {e}")
        return load_cached_wifi_networks()

def get_wifi_interface():
    """Detect the WiFi interface (handles wlan0, wlp*, etc)"""
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


def get_security_for_ssid(ssid):
    """
    Run a WiFi scan and return the SECURITY value for the given SSID (e.g. 'WEP', 'WPA2').
    Returns None if SSID not found or scan fails. Used to choose WEP vs WPA key format.
    """
    try:
        # Rescan so we have fresh results (interface may have just left hotspot mode)
        subprocess.run(
            ['nmcli', 'device', 'wifi', 'rescan'],
            capture_output=True,
            timeout=15
        )
        time.sleep(2)
    except Exception as e:
        logger.debug(f"WiFi rescan before security lookup failed, continuing with existing scan results: {e}")
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list'],
            capture_output=True,
            text=True,
            timeout=25
        )
        if result.returncode != 0:
            return None
        for line in result.stdout.strip().split('\n'):
            if not line:
                continue
            # Format: SSID:SIGNAL:SECURITY (SSID may contain colons in theory)
            parts = line.split(':')
            if len(parts) >= 3 and parts[0] == ssid:
                return (parts[-1] or '').strip()
            # If SSID contains ':', match by joining first N-2 parts
            if len(parts) >= 3 and ':'.join(parts[:-2]) == ssid:
                return (parts[-1] or '').strip()
        return None
    except Exception as e:
        logger.debug(f"get_security_for_ssid failed: {e}")
        return None


def _split_nmcli_t_fields(line):
    """Split nmcli -t fields while preserving escaped colons (\\:)."""
    parts = re.split(r'(?<!\\):', line.strip())
    return [p.replace('\\:', ':') for p in parts]


def _connection_name_matches_ssid(connection_name, ssid):
    """Return True when NM connection name maps to SSID or its numeric suffix variants."""
    escaped_name = re.escape(ssid)
    return bool(re.match(rf"^{escaped_name}(?:\s+\d+)?$", connection_name or ''))


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
            ['nmcli', '-t', '-f', 'SSID,BSSID,SIGNAL,SECURITY', 'device', 'wifi', 'list'],
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

def delete_wifi_connections_by_name(connection_name):
    """Delete SSID profile variants (e.g. `SSID`, `SSID 1`, `SSID 2`) to avoid stale duplicates."""
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'NAME,UUID', 'connection', 'show'],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode != 0:
            logger.warning(f"Could not list existing connections: {result.stderr}")
            return

        # NetworkManager auto-creates suffix variants like "<ssid> 1" when name collisions occur.
        escaped_name = re.escape(connection_name)
        name_pattern = re.compile(rf"^{escaped_name}(?:\s+\d+)?$")

        for raw in (result.stdout or '').splitlines():
            if not raw.strip():
                continue
            parts = _split_nmcli_t_fields(raw)
            if len(parts) < 2:
                continue
            name, uuid = parts[0], parts[1]
            if not name_pattern.match(name) or not uuid:
                continue

            delete_result = subprocess.run(
                ['nmcli', 'connection', 'delete', 'uuid', uuid],
                capture_output=True,
                text=True,
                timeout=5
            )
            if delete_result.returncode == 0:
                logger.info(f"Deleted existing connection profile {name} ({uuid})")
            else:
                logger.warning(
                    f"Failed to delete connection profile {name} ({uuid}): {delete_result.stderr}"
                )
    except Exception as e:
        logger.warning(f"Failed to cleanup connection profiles for {connection_name}: {e}")


def create_wifi_connection(ssid, password, security=None):
    """
    Create NetworkManager connection for WiFi and return its UUID.
    Supports WPA/WPA2 (wpa-psk), WEP (wep-key0), and open networks.
    security: optional string from scan (e.g. 'WEP', 'WPA2'); if None, detected from scan.
    """
    try:
        # Remove duplicate profile names so activation cannot pick stale credentials.
        delete_wifi_connections_by_name(ssid)

        # Detect the actual WiFi interface on this system
        wifi_ifname = get_wifi_interface()
        logger.info(f"Using WiFi interface: {wifi_ifname}")

        if security is None:
            security = get_security_for_ssid(ssid)
            if security:
                logger.info(f"Detected security for {ssid}: {security}")

        is_wep = security and 'WEP' in security.upper()
        is_open = not security or security.lower() == 'none'

        cmd = ['nmcli', 'connection', 'add', 'type', 'wifi',
               'con-name', ssid, 'ifname', wifi_ifname, 'ssid', ssid]

        if password:
            if is_wep:
                cmd.extend(['wifi-sec.key-mgmt', 'none', 'wifi-sec.wep-key0', password])
                logger.info(f"Creating connection with WEP key for {ssid}")
            else:
                cmd.extend(['wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk', password])
                logger.info(f"Creating connection with WPA-PSK for {ssid}")
        else:
            # For open networks (no password), do NOT add a PSK/WEP key.
            # NetworkManager will treat the profile as open.
            cmd.extend(['wifi-sec.key-mgmt', 'none'])
            if is_open:
                logger.info(f"Creating connection for open network {ssid}")
            else:
                # Network appears to have security but no password provided - try open,
                # NetworkManager/the AP will reject if a key is actually required.
                logger.info(f"Creating connection for {ssid} (no password for secured network)")
            # If SSID exists with mixed security variants, lock to an open BSSID.
            open_bssid = find_open_bssid_for_ssid(ssid)
            if open_bssid:
                cmd.extend(['802-11-wireless.bssid', open_bssid])

        # Always pin DNS servers so cloud registration works even when the
        # WiFi network does not hand out DNS via DHCP.
        cmd.extend(['ipv4.dns', '8.8.8.8 1.1.1.1', 'ipv4.ignore-auto-dns', 'no'])

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)

        if result.returncode != 0:
            logger.error(f"Failed to create connection: {result.stderr}")
            return None

        match = re.search(r'\(([0-9a-fA-F-]{36})\)', result.stdout or '')
        connection_uuid = match.group(1) if match else None
        security_desc = 'WEP' if is_wep else ('Open' if is_open else 'WPA/WPA2')
        logger.info(
            f"Created WiFi connection: {ssid} (uuid={connection_uuid or 'unknown'}, security={security_desc})"
        )
        return connection_uuid

    except Exception as e:
        logger.error(f"Error creating WiFi connection: {e}")
        return None

def connect_to_wifi(connection_target, use_uuid=False):
    """Activate NetworkManager connection by UUID (preferred) or by name."""
    target_desc = f"uuid={connection_target}" if use_uuid else f"SSID: {connection_target}"
    logger.info(f"[WIFI CONNECT] Attempting to connect to {target_desc}")
    try:
        cmd = ['nmcli', 'connection', 'up']
        if use_uuid:
            cmd.extend(['uuid', connection_target])
        else:
            cmd.append(connection_target)

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30
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

            # Don't attempt fallback here - connection should be created beforehand by create_wifi_connection()
            return False, None
        
        logger.info(f"[WIFI CONNECT] Successfully connected to WiFi: {connection_target}")
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

def stop_hotspot_services():
    """Stop hotspot services after successful configuration"""
    try:
        logger.info("Stopping hotspot services...")
        
        subprocess.run(['systemctl', 'stop', 'hostapd-setup.service'], timeout=5)
        subprocess.run(['systemctl', 'stop', 'dnsmasq-setup.service'], timeout=5)
        
        logger.info("Hotspot services stopped")
        return True
        
    except Exception as e:
        logger.error(f"Error stopping hotspot services: {e}")
        return False

def remove_setup_netplan_config():
    """Remove netplan static IP config to allow NetworkManager to take over"""
    try:
        netplan_file = Path('/etc/netplan/50-setup-mode.yaml')
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

def trigger_hub_pull():
    """Trigger CI-OS-Hub pull and startup (run in background)"""
    try:
        # Find the pull-and-run-ci-os-hub.sh script
        pull_script = Path('/home/companion/Development/CI-OS/scripts/pull-and-run-ci-os-hub.sh')

        # Look in common locations
        if not pull_script.exists():
            pull_script = Path('/opt/ci-os/scripts/pull-and-run-ci-os-hub.sh')

        if not pull_script.exists():
            pull_script = Path('/usr/local/bin/pull-and-run-ci-os-hub.sh')

        if not pull_script.exists():
            logger.warning(f"CI-OS-Hub pull script not found at expected locations")
            return False

        logger.info(f"Running CI-OS-Hub pull script: {pull_script}")

        # Run in background so the HTTP response returns immediately
        subprocess.Popen(
            [str(pull_script)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True  # Detach from parent process
        )

        logger.info("CI-OS-Hub pull triggered in background")
        return True

    except Exception as e:
        logger.error(f"Failed to trigger CI-OS-Hub pull: {e}")
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

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({'status': 'ok', 'service': 'setup-backend'})

@app.route('/api/status', methods=['GET'])
def status():
    """Get setup status"""
    setup_complete = SETUP_COMPLETE_FILE.exists()
    hub_state = get_hub_pairing_state()

    return jsonify({
        'setup_complete': setup_complete,
        'message': 'Waiting for user pairing code and WiFi credentials',
        'hub_running': hub_state['hub_running'],
        'hub_registered': hub_state['hub_registered'],
        'require_pairing': hub_state['require_pairing'],
    })

@app.route('/api/scan-networks', methods=['GET'])
def scan_networks():
    """Scan for available WiFi networks"""
    logger.info("WiFi scan requested")
    networks = scan_wifi_networks()
    return jsonify({'networks': networks})

def _apply_wifi_and_connect(ssid, password):
    """
    Background task: stop hotspot, remove setup netplan, create WiFi connection, connect.
    Called after the configure endpoint has returned success so the user is ejected from
    the captive portal. Pairing verification and Hub start are handled by the daemon
    once the device has connectivity.
    """
    try:
        time.sleep(2)  # Give client time to receive the HTTP response
        logger.info("[CONFIGURE-BG] Stopping hotspot services...")
        stop_hotspot_services()
        time.sleep(1)
        logger.info("[CONFIGURE-BG] Removing setup netplan config...")
        remove_setup_netplan_config()
        time.sleep(3)  # Allow interface to leave AP mode and be ready for scan/connect
        logger.info(f"[CONFIGURE-BG] Creating NetworkManager connection for {ssid}...")
        if not create_wifi_connection(ssid, password):
            logger.error(f"[CONFIGURE-BG] Failed to create WiFi connection for {ssid}")
            return
        logger.info(f"[CONFIGURE-BG] Connecting to WiFi: {ssid}")
        for i in range(30):
            if connect_to_wifi(ssid):
                logger.info("[CONFIGURE-BG] WiFi connection established; daemon will verify pairing and start Hub.")
                return
            time.sleep(1)
        # Fallback: if WPA connection failed (e.g. network is WEP and scan didn't find it), retry with WEP
        if password:
            logger.info("[CONFIGURE-BG] Retrying with WEP security...")
            if create_wifi_connection(ssid, password, security='WEP'):
                for i in range(20):
                    if connect_to_wifi(ssid):
                        logger.info("[CONFIGURE-BG] WiFi connection established (WEP); daemon will verify pairing and start Hub.")
                        return
                    time.sleep(1)
        logger.warning("[CONFIGURE-BG] WiFi connection did not establish within 30s; daemon will retry when connectivity appears.")
    except Exception as e:
        logger.error(f"[CONFIGURE-BG] Background WiFi apply failed: {e}", exc_info=True)


@app.route('/api/configure', methods=['POST'])
def configure():
    """
    Save pairing code and WiFi credentials, return success immediately so the user
    is ejected from the captive portal. WiFi connection and pairing/Hub steps run
    in the background (backend thread) and via the daemon (setup-pairing-verify-hub).
    """
    try:
        # Accept both JSON and form-encoded data
        if request.is_json:
            data = request.get_json()
        else:
            data = request.form.to_dict()
        
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        pairing_code = data.get('pairing_code', '')
        ssid = data.get('ssid', '')
        password = data.get('password', '')

        hub_state = get_hub_pairing_state()
        require_pairing = hub_state['require_pairing']
        logger.info(
            f"[CONFIGURE] Hub state: running={hub_state['hub_running']}, "
            f"registered={hub_state['hub_registered']}, require_pairing={require_pairing}"
        )
        
        if require_pairing and not pairing_code:
            return jsonify({'error': 'Pairing code required for unregistered Hub'}), 400
        
        if not ssid:
            return jsonify({'error': 'SSID required'}), 400

        normalized_code = normalize_pairing_code(pairing_code) if pairing_code else ''
        if require_pairing and len(normalized_code) != 6:
            return jsonify({'error': 'Pairing code must be 6 characters'}), 400

        logger.info(f"[CONFIGURE] Starting WiFi configuration")
        logger.info(f"[CONFIGURE] SSID: {ssid}")
        if require_pairing:
            logger.info(f"[CONFIGURE] Pairing code (normalized): {normalized_code}")
        else:
            logger.info("[CONFIGURE] Pairing code not required for this device state")
        logger.info(f"[CONFIGURE] Password provided: {'Yes' if password else 'No (open network)'}")

        # Persist the user-entered pairing code so the setup-pairing-verify-hub daemon can
        # independently retry cloud verification + Hub startup in the background, as a
        # safety net if the inline registration below doesn't complete (e.g. dropped request).
        if pairing_code:
            if not save_user_pairing_code(pairing_code):
                return jsonify({'error': 'Failed to save pairing code'}), 500

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
        
        # 2. Save WiFi credentials (used by background task to connect)
        try:
            credentials = {
                'ssid': ssid,
                'password': password or '',
                'configured_at': datetime.now().isoformat()
            }
            with open(CREDENTIALS_JSON, 'w') as f:
                json.dump(credentials, f, indent=2)
            os.chmod(CREDENTIALS_JSON, 0o600)
        except Exception as e:
            logger.error(f"Failed to save credentials: {e}")
        
        # NOTE: We do NOT create setup-complete flag - it should not gate hotspot operations
        # The network monitor runs independently and starts hotspot if no connectivity detected
        # Setup is complete when WiFi connection is active, not when the flag is written
        
        # Stop hotspot services
        time.sleep(2)
        stop_hotspot_services()
        
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
            connected, failure_reason = connect_to_wifi(connection_uuid, use_uuid=True)
            if connected:
                wifi_connected = True
                logger.info("WiFi connection established")
                break

            if failure_reason == 'missing-secrets':
                if password:
                    # Password was provided but NM still reports missing credentials - tell user
                    logger.warning("Selected WiFi network requires additional credentials that were not provided")
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
            # Setup may still be converging; cloud registration can happen later.
            # The device will work on local network, cloud registration can happen later
            if request.is_json:
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
            if request.is_json:
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

        # Step 3: Now that we have internet, validate pairing code with cloud
        logger.info("Internet connectivity confirmed. Starting cloud device registration...")
        
        try:
            # Normalize pairing code to uppercase before cloud validation
            normalized_pairing_code = normalize_pairing_code(pairing_code)
            logger.info(f"Getting pairing info from cloud for pairing code: {normalized_pairing_code} (normalized from: {pairing_code})")
            success, pairing_info = get_pairing_info_from_cloud(normalized_pairing_code)
            
            if not success:
                logger.error(f"Failed to get pairing info from cloud: {pairing_info}")
                # Keep WiFi connected. Registration can be retried without forcing users back to AP mode.
                error_msg = 'Failed to validate pairing code with cloud service. Device stayed connected; please verify pairing code and retry.'
                if request.is_json:
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

                if not cloud_device_id:
                    logger.warning(f"Missing device_id in cloud response: {pairing_info}")
                else:
                    # Validate pairing code matches (case-insensitive comparison)
                    user_code_normalized = normalize_pairing_code(pairing_code)
                    cloud_code_normalized = normalize_pairing_code(cloud_pairing_code)
                    
                    logger.info(f"[PAIRING VALIDATION] Comparing pairing codes")
                    logger.info(f"[PAIRING VALIDATION] User entered (original): {pairing_code}")
                    logger.info(f"[PAIRING VALIDATION] User entered (normalized): {user_code_normalized}")
                    logger.info(f"[PAIRING VALIDATION] Cloud returned (original): {cloud_pairing_code}")
                    logger.info(f"[PAIRING VALIDATION] Cloud returned (normalized): {cloud_code_normalized}")
                    
                    if cloud_code_normalized and user_code_normalized != cloud_code_normalized:
                        logger.error(f"[PAIRING VALIDATION] MISMATCH! User: {user_code_normalized} != Cloud: {cloud_code_normalized}")
                        logger.error(f"[PAIRING VALIDATION] Original user input: {pairing_code}, Cloud response: {cloud_pairing_code}")
                        logger.info("[PAIRING VALIDATION] Pairing mismatch detected; keeping WiFi connected for retry")

                        # Return error response
                        if request.is_json:
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
                            f"api_key: {api_key[:8]}..., pairing_code matches"
                        )
                        logger.info("[CREDENTIALS] Saving API key from cloud GET response")
                        save_cloud_credentials(cloud_device_id, api_key)
                    else:
                        logger.info(
                            f"Retrieved from cloud - device_id: {cloud_device_id}, "
                            "api_key not provided by GET /pair"
                        )
                    
                    # Step 3: Get the actual device ID from local machine
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
                        logger.info(f"Device ID updated successfully in cloud: {update_resp}")
                        redirect_metadata = _build_redirect_metadata(update_resp, pairing_info)
                        # Persist api_key from POST response if it was not present in GET response.
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
                        # API key already saved from GET response, no need to save again
                    else:
                        logger.warning(f"Device ID update failed: {update_resp}")
                        redirect_metadata = _build_redirect_metadata(pairing_info)

                    # Start CI-OS-Hub from store install (fetch compose + config, then docker compose up)
                    def _run_install():
                        install_and_start_ci_os_hub(local_device_id, api_key)
                    t = threading.Thread(target=_run_install, daemon=True)
                    t.start()
                    logger.info("[CI-OS-HUB] Started install-and-run in background")

        except Exception as e:
            logger.error(f"Exception during cloud registration: {e}", exc_info=True)
        
        # Return HTML response for form submissions, JSON for API calls
        if request.is_json:
            return jsonify({
                'status': 'success',
                'message': 'WiFi configured successfully',
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
                </style>
            </head>
            <body>
                <div class="success">✓ Device configured!</div>
                <p>The device will connect to your WiFi and complete setup. You can disconnect from this network.</p>
            </body>
            </html>
            ''', 200
        
    except Exception as e:
        logger.error(f"[CONFIGURE] Configuration error: {e}", exc_info=True)
        return jsonify({'error': 'Internal server error'}), 500

def main():
    """Main entry point - daemon-safe"""
    logger.info("Starting setup-backend service")
    
    logger.info(f"User pairing code file: {USER_PAIRING_CODE_JSON}")
    logger.info(f"Setup complete file: {SETUP_COMPLETE_FILE}")
    logger.info("Waiting for user to submit pairing code and WiFi credentials...")
    
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
