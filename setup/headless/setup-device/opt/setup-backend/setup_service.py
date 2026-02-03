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

USER_PAIRING_CODE_JSON = DATA_DIR / 'user_pairing_code.json'
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

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({'status': 'ok', 'service': 'setup-backend'})

@app.route('/api/status', methods=['GET'])
def status():
    """Get setup status"""
    setup_complete = SETUP_COMPLETE_FILE.exists()
    
    return jsonify({
        'setup_complete': setup_complete,
        'message': 'Waiting for user pairing code and WiFi credentials'
    })

@app.route('/api/scan-networks', methods=['GET'])
def scan_networks():
    """Scan for available WiFi networks"""
    logger.info("WiFi scan requested")
    networks = scan_wifi_networks()
    return jsonify({'networks': networks})

@app.route('/api/configure', methods=['POST'])
def configure():
    """Configure WiFi connection and validate pairing code"""
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
        
        # Normalize and validate pairing code
        normalized_code = normalize_pairing_code(pairing_code)
        if len(normalized_code) < 4:
            return jsonify({'error': 'Pairing code must be at least 4 characters'}), 400
        
        logger.info(f"[CONFIGURE] Starting setup flow")
        logger.info(f"[CONFIGURE] SSID: {ssid}")
        logger.info(f"[CONFIGURE] Pairing code (normalized): {normalized_code}")
        logger.info(f"[CONFIGURE] Password provided: {'Yes' if password else 'No (open network)'}")
        
        # Save user pairing code so daemon (setup-pairing-verify-and-hub) can run GET/POST and start Hub
        save_user_pairing_code(pairing_code)
        
        # Check internet connectivity before WiFi connect
        logger.info("[CONFIGURE] Checking internet connectivity...")
        max_wait = 15
        internet_available = False
        for i in range(max_wait):
            if check_internet_connectivity(timeout=3):
                internet_available = True
                logger.info("[CONFIGURE] Internet connectivity confirmed")
                break
            if (i + 1) % 3 == 0:
                logger.info(f"[CONFIGURE] Waiting for internet... ({i+1}/{max_wait})")
            time.sleep(1)
        
        if not internet_available:
            logger.error("[CONFIGURE] No internet connectivity - cannot connect to WiFi")
            return jsonify({
                'error': 'No internet connectivity. Please connect to a network with internet access.',
                'status': 'no_internet'
            }), 500
        
        # Proceed with WiFi configuration (daemon handles cloud verification and Hub start)
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
            logger.error(f"Failed to save WiFi credentials: {e}")
        
        # Stop hotspot services
        time.sleep(2)
        stop_hotspot_services()
        
        # Remove netplan static IP config to allow NetworkManager to manage the interface
        time.sleep(1)
        remove_setup_netplan_config()
        
        # Step 7: Connect to WiFi
        logger.info(f"[CONFIGURE] Connecting to WiFi network: {ssid}")
        wifi_connected = False
        max_wifi_wait = 30  # Wait up to 30 seconds for WiFi connection
        for i in range(max_wifi_wait):
            if connect_to_wifi(ssid):
                wifi_connected = True
                logger.info("[CONFIGURE] WiFi connection established")
                break
            logger.info(f"[CONFIGURE] Waiting for WiFi connection... ({i+1}/{max_wifi_wait})")
            time.sleep(1)
        
        if not wifi_connected:
            logger.error("[CONFIGURE] Failed to connect to WiFi network")
            return jsonify({'error': 'Failed to connect to WiFi network. Please check your credentials and try again.'}), 500
        
        logger.info("[CONFIGURE] WiFi connection successful")
        
        # Daemon (setup-pairing-verify-hub) will pick up user_pairing_code.json and run verification + Hub start
        
        # Return success response
        if request.is_json:
            return jsonify({
                'status': 'success',
                'message': 'Device configured successfully'
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
                <div class="success">✓ Device configured successfully!</div>
                <p>The device is now set up. Pairing verification and CI-OS-Hub will start automatically.</p>
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
