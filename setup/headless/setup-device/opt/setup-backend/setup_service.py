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

def scan_wifi_networks():
    """Scan for available WiFi networks using nmcli"""
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list'],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            logger.error(f"WiFi scan failed: {result.stderr}")
            return []
        
        networks = []
        seen_ssids = set()
        
        for line in result.stdout.strip().split('\n'):
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
        
    except subprocess.TimeoutExpired:
        logger.error("WiFi scan timed out")
        return []
    except Exception as e:
        logger.error(f"WiFi scan error: {e}")
        return []

def get_device_ip_on_wifi():
    """Get device IP on the WiFi interface (for WiFi-only flow - user reconnects to home network)"""
    try:
        wifi_if = get_wifi_interface()
        result = subprocess.run(
            ['ip', '-4', '-o', 'addr', 'show', wifi_if],
            capture_output=True,
            text=True,
            timeout=3
        )
        if result.returncode == 0 and result.stdout:
            # Parse "2: wlan0 inet 192.168.1.50/24 ..."
            import re
            m = re.search(r'inet\s+(\d+\.\d+\.\d+\.\d+)', result.stdout)
            if m:
                return m.group(1)
    except Exception:
        pass
    return None

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
            logger.error(f"[WIFI CONNECT] Failed to activate connection to {ssid}")
            logger.error(f"[WIFI CONNECT] Return code: {result.returncode}")
            logger.error(f"[WIFI CONNECT] stderr: {result.stderr}")
            logger.error(f"[WIFI CONNECT] stdout: {result.stdout}")
            return False
        
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
        return True
        
    except Exception as e:
        logger.error(f"[WIFI CONNECT] Exception connecting to WiFi {ssid}: {e}", exc_info=True)
        return False

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

def _get_internet_interface():
    """Get the network interface that has the default route (usually eth0 or enp*)"""
    try:
        r = subprocess.run(
            ['ip', 'route', 'show', 'default'],
            capture_output=True, text=True, timeout=3
        )
        if r.returncode == 0 and r.stdout:
            # "default via 192.168.1.1 dev eth0 ..."
            parts = r.stdout.strip().split()
            for i, p in enumerate(parts):
                if p == 'dev' and i + 1 < len(parts):
                    return parts[i + 1]
    except Exception:
        pass
    return 'eth0'  # Fallback

def enable_ap_internet_sharing():
    """Enable IP forwarding and NAT so AP clients can reach internet.
    Required for keep-AP flow: user must reach setup.companionintelligence.com for registration."""
    try:
        subprocess.run(['sysctl', '-w', 'net.ipv4.ip_forward=1'], capture_output=True, timeout=5, check=False)
        iface = _get_internet_interface()
        check = subprocess.run(
            ['iptables', '-t', 'nat', '-C', 'POSTROUTING', '-s', '192.168.99.0/24',
             '-o', iface, '-j', 'MASQUERADE'],
            capture_output=True, timeout=5
        )
        if check.returncode != 0:
            subprocess.run(
                ['iptables', '-t', 'nat', '-A', 'POSTROUTING', '-s', '192.168.99.0/24',
                 '-o', iface, '-j', 'MASQUERADE'],
                capture_output=True, timeout=5, check=False
            )
        logger.info(f"AP internet sharing enabled (NAT for 192.168.99.0/24 -> {iface})")
        return True
    except Exception as e:
        logger.warning(f"Could not enable AP internet sharing: {e}")
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
    
    return jsonify({
        'setup_complete': setup_complete,
        'pairing_code_available': pairing_code is not None
    })

@app.route('/api/scan-networks', methods=['GET'])
def scan_networks():
    """Scan for available WiFi networks"""
    logger.info("WiFi scan requested")
    networks = scan_wifi_networks()
    return jsonify({'networks': networks})

LOGIN_SEEN_FILE = DATA_DIR / 'login-page-seen'

@app.route('/api/setup/login-seen', methods=['GET', 'POST', 'OPTIONS'])
def login_seen():
    """Signal that the Hub login page was loaded (called from Hub frontend). Enables closing AP only after user reaches /login."""
    if request.method == 'OPTIONS':
        resp = jsonify({'status': 'ok'})
        resp.headers['Access-Control-Allow-Origin'] = '*'
        resp.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
        resp.headers['Access-Control-Allow-Headers'] = 'Content-Type'
        return resp
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        LOGIN_SEEN_FILE.touch()
        logger.info("[LOGIN-SEEN] Hub login page loaded - setup can close AP")
    except Exception as e:
        logger.warning(f"Could not write login-seen flag: {e}")
    resp = jsonify({'status': 'ok'})
    resp.headers['Access-Control-Allow-Origin'] = '*'
    return resp

@app.route('/api/setup/hub-status', methods=['GET'])
def hub_status():
    """Check if CI OS Hub is ready and registration status (for portal polling)"""
    hub_ready = False
    registered = False
    try:
        req = urllib.request.Request('http://127.0.0.1:5002/api/registration/status')
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read().decode())
            hub_ready = True
            registered = data.get('registered', False)
    except Exception:
        pass
    return jsonify({'hub_ready': hub_ready, 'registered': registered})

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
        
        if not pairing_code:
            return jsonify({'error': 'Pairing code required'}), 400
        
        if not ssid:
            return jsonify({'error': 'SSID required'}), 400
        
        # Validate pairing code is 6 characters (after normalizing user input)
        normalized_code = normalize_pairing_code(pairing_code)
        if len(normalized_code) != 6:
            return jsonify({'error': 'Pairing code must be 6 characters'}), 400
        
        logger.info(f"[CONFIGURE] Starting WiFi configuration")
        logger.info(f"[CONFIGURE] SSID: {ssid}")
        logger.info(f"[CONFIGURE] Pairing code (normalized): {normalized_code}")
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
        
        # Check if we have internet NOW (e.g. via Ethernet) - if yes, keep AP open for Hub registration
        # Device has Ethernet (enp*) + WiFi (wlp*): Ethernet = internet, WiFi = AP. No conflict.
        internet_now = check_internet_connectivity(timeout=3)
        logger.info(f"[CONFIGURE] Internet available (keep AP possible): {internet_now}")
        
        if internet_now:
            # KEEP AP FLOW: Device has internet via Ethernet. AP stays alive - we never stop it here.
            # User stays connected to hotspot through: validate -> pull-dev -> redirect -> register -> login.
            # WiFi connection happens only at the end (in orchestrator, after login page seen).
            # Do cloud validation first, then spawn orchestrator to run pull-dev, wait for registration.
            logger.info("[CONFIGURE] Keep-AP flow: validating pairing with cloud...")
            try:
                normalized_pairing_code = normalize_pairing_code(pairing_code)
                success, pairing_info = get_pairing_info_from_cloud(normalized_pairing_code)
                if success:
                    cloud_device_id = pairing_info.get('device_id')
                    api_key = pairing_info.get('api_key')
                    cloud_pairing_code = pairing_info.get('pairing_code', '')
                    if cloud_device_id and api_key:
                        cloud_code_norm = normalize_pairing_code(cloud_pairing_code)
                        if cloud_code_norm and normalized_pairing_code != cloud_code_norm:
                            return jsonify({'error': 'Pairing code does not match. Please try again.'}), 400
                        save_cloud_credentials(cloud_device_id, api_key)
                        local_device_id = get_device_id()
                        update_device_id_in_cloud(
                            pairing_code=normalized_pairing_code,
                            device_id=local_device_id,
                            api_key=api_key
                        )
                    else:
                        return jsonify({'error': 'Cloud validation failed. Please try again.'}), 500
                else:
                    return jsonify({'error': 'Failed to validate pairing code with cloud service.'}), 500
            except Exception as e:
                logger.error(f"Cloud validation error: {e}", exc_info=True)
                return jsonify({'error': 'Cloud validation failed.'}), 500
            
            # Spawn orchestrator (runs pull-dev, waits for registration, then closes AP)
            orchestrator = Path('/opt/setup-device/scripts/setup-orchestrator.sh')
            keep_ap_flag = Path('/var/lib/setup-device/keep-ap-during-registration')
            if orchestrator.exists():
                keep_ap_flag.parent.mkdir(parents=True, exist_ok=True)
                keep_ap_flag.touch()
                # Enable internet for AP clients (NAT + forwarding) so user can reach CI Cloud
                enable_ap_internet_sharing()
                # Restart dnsmasq to use upstream DNS (allows setup.companionintelligence.com)
                subprocess.run(['systemctl', 'restart', 'dnsmasq-setup.service'], capture_output=True, timeout=10)
                logger.info("[CONFIGURE] Spawning setup orchestrator (background)...")
                subprocess.Popen(
                    [str(orchestrator), str(CREDENTIALS_JSON)],
                    start_new_session=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                hub_url = "http://192.168.99.1:5002"
                want_json = request.is_json or 'application/json' in request.headers.get('Accept', '')
                if want_json:
                    return jsonify({
                        'status': 'success',
                        'flow': 'keep_ap',
                        'redirect_url': hub_url,
                        'message': 'Redirecting to device registration...'
                    })
                return f'''
                <!DOCTYPE html>
                <html>
                <head><meta charset="UTF-8"><meta http-equiv="refresh" content="2;url={hub_url}"></head>
                <body style="font-family:sans-serif;text-align:center;padding:50px;">
                <div style="color:green;font-size:20px;">Device configured. Starting CI OS Hub...</div>
                <p>Redirecting to registration in 2 seconds. <a href="{hub_url}">Click here</a> if not redirected.</p>
                </body>
                </html>
                ''', 200
            else:
                logger.warning(f"Orchestrator not found at {orchestrator}, falling back to WiFi-only flow")
                internet_now = False
        
        # WIFI-ONLY FLOW: No internet via Ethernet. Must stop AP, connect WiFi.
        time.sleep(2)
        stop_hotspot_services()
        time.sleep(1)
        remove_setup_netplan_config()
        
        # Step 1: Connect to WiFi first
        logger.info(f"Connecting to WiFi network: {ssid}")
        wifi_connected = False
        max_wifi_wait = 30  # Wait up to 30 seconds for WiFi connection
        for i in range(max_wifi_wait):
            if connect_to_wifi(ssid):
                wifi_connected = True
                logger.info("WiFi connection established")
                break
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
        
        # WiFi-only: spawn pull-dev in background (user will reconnect to home WiFi and open device-ip:5002)
        pull_dev = Path('/opt/setup-device/scripts/pull-dev.sh')
        if pull_dev.exists():
            logger.info("[CONFIGURE] WiFi-only: spawning pull-dev in background...")
            subprocess.Popen(
                ['/usr/bin/bash', str(pull_dev)],
                env={**os.environ, 'HOME': '/root'},
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        
        # Return JSON if client accepts it, else HTML
        want_json = request.is_json or 'application/json' in request.headers.get('Accept', '')
        device_ip = get_device_ip_on_wifi()
        hub_url = f"http://{device_ip}:5002" if device_ip else "http://<device-ip>:5002"
        if want_json:
            return jsonify({
                'status': 'success',
                'flow': 'wifi_only',
                'message': 'WiFi configured successfully. Reconnect to your home WiFi and open the Hub to complete registration.',
                'hub_url': hub_url,
                'device_ip': device_ip
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
    
    # Run Flask app
    # Use waitress or similar for production, but for now Flask dev server
    # In production, this would be run via gunicorn or similar
    try:
        app.run(host='127.0.0.1', port=5000, debug=False, use_reloader=False)
    except KeyboardInterrupt:
        logger.info("Shutting down...")
    except Exception as e:
        logger.error(f"Service error: {e}", exc_info=True)
        sys.exit(1)

if __name__ == '__main__':
    main()
