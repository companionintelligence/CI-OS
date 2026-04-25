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

PAIRING_CODE_JSON = CONFIG_DIR / 'pairing_code.json'
SETUP_COMPLETE_FILE = DATA_DIR / 'setup-complete'
CREDENTIALS_JSON = DATA_DIR / 'credentials.json'
SCAN_CACHE_TXT = DATA_DIR / 'last_scan_networks.txt'

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

CI_CLOUD_API_URL = os.environ.get('CI_CLOUD_API_URL') or _read_conf_value('CI_CLOUD_API_URL') or 'https://setup.companionintel.com'
CI_HUB_REGISTRATION_STATUS_URL = os.environ.get('CI_HUB_REGISTRATION_STATUS_URL', 'http://127.0.0.1:5002/registration/status')


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
                if device_id and device_id != 'Not Specified' and device_id != 'To be filled by O.E.M.':
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
    """Check if device has internet connectivity"""
    try:
        # Try pinging a public DNS server
        result = subprocess.run(
            ['ping', '-c', '1', '-W', str(timeout), '8.8.8.8'],
            capture_output=True,
            timeout=timeout + 1
        )
        if result.returncode == 0:
            logger.info("Internet connectivity check: OK")
            return True
    except Exception as e:
        logger.debug(f"Internet connectivity check failed: {e}")
    
    # Also check if we can resolve DNS
    try:
        result = subprocess.run(
            ['nslookup', 'google.com'],
            capture_output=True,
            timeout=timeout
        )
        if result.returncode == 0:
            logger.info("Internet connectivity check: OK (DNS resolution)")
            return True
    except Exception:
        pass
    
    logger.warning("Internet connectivity check: FAILED")
    return False

def get_pairing_info_from_cloud(pairing_code, timeout=10):
    """GET request to /api/devices/pair?pairing_code=XXX to get device_id and api_key"""
    # Normalize to uppercase (removes non-alphanumeric characters)
    normalized_code = normalize_pairing_code(pairing_code)
    encoded_code = urllib.parse.quote(normalized_code)
    url = _cloud_pairing_url() + f'?pairing_code={encoded_code}'
    logger.info(f"[CLOUD GET] Request URL: {url}")
    logger.info(f"[CLOUD GET] Pairing code (normalized): {normalized_code}")
    try:
        req = urllib.request.Request(url, method='GET')
        logger.info(f"[CLOUD GET] Sending GET request to cloud API...")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            logger.info(f"[CLOUD GET] Response status: {resp.status}")
            logger.info(f"[CLOUD GET] Response body: {body}")
            try:
                parsed = json.loads(body)
                if isinstance(parsed, dict):
                    device_id = parsed.get('device_id')
                    api_key = parsed.get('api_key')
                    cloud_pairing_code = parsed.get('pairing_code', '')
                    if device_id and api_key:
                        logger.info(f"Retrieved device_id: {device_id}, api_key: {api_key[:8]}..., pairing_code: {cloud_pairing_code}")
                        return True, parsed
                    else:
                        logger.warning(f"Missing device_id or api_key in response: {parsed}")
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

def update_device_id_in_cloud(pairing_code, device_id, api_key, timeout=10):
    """POST request to /api/devices/pair to upsert device_id where pairing_code matches"""
    url = _cloud_pairing_url()
    
    # Normalize to uppercase (removes non-alphanumeric characters)
    normalized_code = normalize_pairing_code(pairing_code)
    
    payload = {
        'pairing_code': normalized_code,
        'device_id': device_id
    }
    
    data = json.dumps(payload).encode('utf-8')
    headers = {
        'Content-Type': 'application/json',
        'X-API-Key': api_key  # Use api_key from GET response for authentication
    }
    
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

def generate_pairing_code():
    """Generate new pairing code (6 characters, A-Z0-9)"""
    import random
    import string
    
    chars = string.ascii_uppercase + string.digits
    code1 = ''.join(random.choice(chars) for _ in range(3))
    code2 = ''.join(random.choice(chars) for _ in range(3))
    code = f"{code1}{code2}"  # No dash, just 6 characters
    
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
                    with open(PAIRING_CODE_JSON, 'w') as f:
                        json.dump(cleaned_data, f, indent=2)
                    os.chmod(PAIRING_CODE_JSON, 0o600)
                    # Update pairing_data for validation below
                    pairing_data = cleaned_data
                
                # Check if code exists and is valid
                if 'code' in pairing_data and pairing_data['code']:
                    logger.info("Using existing pairing code")
                    return pairing_data['code']
                else:
                    logger.warning("Pairing code file exists but has no valid code, regenerating...")
            except (json.JSONDecodeError, KeyError, ValueError) as e:
                logger.warning(f"Invalid pairing code file: {e}, regenerating...")
        
        # Generate new code
        pairing_data = generate_pairing_code()
        with open(PAIRING_CODE_JSON, 'w') as f:
            json.dump(pairing_data, f, indent=2)
        
        # Set root-only permissions
        os.chmod(PAIRING_CODE_JSON, 0o600)
        
        logger.info(f"Generated new pairing code: {pairing_data['code']}")
        return pairing_data['code']
        
    except Exception as e:
        logger.error(f"Failed to ensure pairing code: {e}", exc_info=True)
        # Generate fallback code
        try:
            pairing_data = generate_pairing_code()
            return pairing_data['code']
        except Exception as fallback_error:
            logger.error(f"Failed to generate fallback pairing code: {fallback_error}")
            # Return a test code as last resort
            return "ABC123"

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
    
    # Whitelist test pairing code for development/testing
    TEST_CODE = "ABC123"
    if normalized == TEST_CODE:
        logger.info(f"Test pairing code accepted: {code}")
        return True
    
    stored_code = load_pairing_code()
    
    if not stored_code:
        logger.warning("No pairing code found")
        return False
    
    stored_normalized = normalize_pairing_code(stored_code)
    
    if normalized != stored_normalized:
        logger.warning(f"Pairing code mismatch")
        return False
    
    return True

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

def create_wifi_connection(ssid, password):
    """Create NetworkManager connection for WiFi"""
    try:
        # Delete existing connection if it exists
        subprocess.run(['nmcli', 'connection', 'delete', ssid], 
                      capture_output=True, timeout=5)
        
        # Detect the actual WiFi interface on this system
        wifi_ifname = get_wifi_interface()
        logger.info(f"Using WiFi interface: {wifi_ifname}")
        
        # Create new connection - explicitly specify the WiFi interface
        cmd = ['nmcli', 'connection', 'add', 'type', 'wifi', 
               'con-name', ssid, 'ifname', wifi_ifname, 'ssid', ssid]
        
        if password:
            cmd.extend(['wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk', password])
        else:
            cmd.extend(['wifi-sec.key-mgmt', 'none'])
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        
        if result.returncode != 0:
            logger.error(f"Failed to create connection: {result.stderr}")
            return False
        
        logger.info(f"Created WiFi connection: {ssid}")
        return True
        
    except Exception as e:
        logger.error(f"Error creating WiFi connection: {e}")
        return False

def connect_to_wifi(ssid):
    """Activate NetworkManager connection"""
    logger.info(f"[WIFI CONNECT] Attempting to connect to SSID: {ssid}")
    try:
        result = subprocess.run(
            ['nmcli', 'connection', 'up', ssid],
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

            logger.error(f"[WIFI CONNECT] Failed to activate connection to {ssid}")
            logger.error(f"[WIFI CONNECT] Return code: {result.returncode}")
            logger.error(f"[WIFI CONNECT] stderr: {result.stderr}")
            logger.error(f"[WIFI CONNECT] stdout: {result.stdout}")
            return False, None
        
        logger.info(f"[WIFI CONNECT] Successfully connected to WiFi: {ssid}")
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
        logger.error(f"[WIFI CONNECT] Exception connecting to WiFi {ssid}: {e}", exc_info=True)
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

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({'status': 'ok', 'service': 'setup-backend'})

@app.route('/api/status', methods=['GET'])
def status():
    """Get setup status"""
    setup_complete = SETUP_COMPLETE_FILE.exists()
    pairing_code = load_pairing_code()
    hub_state = get_hub_pairing_state()
    
    return jsonify({
        'setup_complete': setup_complete,
        'pairing_code_available': pairing_code is not None,
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

@app.route('/api/configure', methods=['POST'])
def configure():
    """Configure WiFi connection"""
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
        
        # Create NetworkManager connection
        logger.info(f"[CONFIGURE] Creating NetworkManager connection for {ssid}...")
        if not create_wifi_connection(ssid, password):
            logger.error(f"[CONFIGURE] Failed to create WiFi connection for {ssid}")
            return jsonify({'error': 'Failed to create WiFi connection'}), 500
        logger.info(f"[CONFIGURE] NetworkManager connection created successfully")
        
        # Persist credentials securely (root-only, JSON format)
        try:
            credentials = {
                'ssid': ssid,
                'password': password,
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
        
        # Step 1: Connect to WiFi first
        logger.info(f"Connecting to WiFi network: {ssid}")
        wifi_connected = False
        max_wifi_wait = 30  # Wait up to 30 seconds for WiFi connection
        for i in range(max_wifi_wait):
            connected, failure_reason = connect_to_wifi(ssid)
            if connected:
                wifi_connected = True
                logger.info("WiFi connection established")
                break

            if failure_reason == 'missing-secrets':
                logger.warning("Selected WiFi network requires additional credentials that were not provided")
                return jsonify({
                    'error': 'Selected WiFi network requires credentials that were not provided. Please re-enter WiFi details and try again.'
                }), 400

            logger.info(f"Waiting for WiFi connection... ({i+1}/{max_wifi_wait})")
            time.sleep(1)
        
        if not wifi_connected:
            logger.error("Failed to connect to WiFi network")
            return jsonify({'error': 'Failed to connect to WiFi network. Please check your credentials and try again.'}), 500
        
        logger.info("WiFi connection successful")
        
        # Step 2: Wait for internet connectivity to be established
        logger.info("Waiting for internet connectivity before cloud registration...")
        max_wait = 45  # Wait up to 45 seconds for internet (longer since WiFi just connected)
        internet_available = False
        for i in range(max_wait):
            if check_internet_connectivity(timeout=3):
                internet_available = True
                logger.info("Internet connectivity confirmed")
                break
            if (i + 1) % 5 == 0:  # Log every 5 seconds
                logger.info(f"Waiting for internet connectivity... ({i+1}/{max_wait})")
            time.sleep(1)
        
        if not internet_available:
            logger.warning("Internet connectivity not available after WiFi connection. Cloud registration skipped.")
            # WiFi is connected but no internet - this is OK, return success
            # The device will work on local network, cloud registration can happen later
            if request.is_json:
                return jsonify({
                    'status': 'success',
                    'message': 'WiFi configured successfully. Internet connectivity not yet available.',
                    'internet_available': False
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
                    'pairing_required': False
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
                # Disconnect from WiFi to restart hotspot
                logger.info("Disconnecting from WiFi to restart setup process...")
                disconnect_from_wifi()
                
                error_msg = 'Failed to validate pairing code with cloud service. Please reconnect to setup network and try again.'
                if request.is_json:
                    return jsonify({'error': error_msg, 'status': 'cloud_error'}), 500
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
                        <p>Please reconnect to the setup network and try again.</p>
                    </body>
                    </html>
                    ''', 500
            else:
                # Extract device_id, api_key, and pairing_code from response
                cloud_device_id = pairing_info.get('device_id')
                api_key = pairing_info.get('api_key')
                cloud_pairing_code = pairing_info.get('pairing_code', '')
                
                if not cloud_device_id or not api_key:
                    logger.warning(f"Missing device_id or api_key in cloud response: {pairing_info}")
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
                        logger.info("[PAIRING VALIDATION] Disconnecting from WiFi to restart hotspot setup process...")
                        
                        # Disconnect from WiFi - this will trigger network monitor to restart hotspot
                        disconnect_from_wifi()
                        
                        # Return error response
                        if request.is_json:
                            return jsonify({
                                'error': 'Pairing code does not match. Please try again.',
                                'status': 'pairing_mismatch'
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
                                    <p>Please reconnect to the setup network and try again.</p>
                                </body>
                                </html>
                                ''', 400
                    
                    logger.info(f"Retrieved from cloud - device_id: {cloud_device_id}, api_key: {api_key[:8]}..., pairing_code matches")
                    
                    # Step 2: Save API key from GET response for later use
                    logger.info(f"[CREDENTIALS] Saving API key from cloud response for later use")
                    save_cloud_credentials(cloud_device_id, api_key)
                    
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
                        # API key already saved from GET response, no need to save again
                    else:
                        logger.warning(f"Device ID update failed: {update_resp}")
                        
        except Exception as e:
            logger.error(f"Exception during cloud registration: {e}", exc_info=True)
        
        # Return HTML response for form submissions, JSON for API calls
        if request.is_json:
            return jsonify({
                'status': 'success',
                'message': 'WiFi configured successfully'
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
        
    except Exception as e:
        logger.error(f"Configuration error: {e}", exc_info=True)
        return jsonify({'error': 'Internal server error'}), 500

def main():
    """Main entry point - daemon-safe"""
    logger.info("Starting setup-backend service")
    
    # Ensure pairing code exists on first boot
    ensure_pairing_code()
    
    logger.info(f"Pairing code file: {PAIRING_CODE_JSON}")
    logger.info(f"Setup complete file: {SETUP_COMPLETE_FILE}")
    
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
