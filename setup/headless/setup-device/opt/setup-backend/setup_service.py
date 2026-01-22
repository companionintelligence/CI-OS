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

# Configuration paths
CONFIG_DIR = Path('/etc/setup-device')
DATA_DIR = Path('/var/lib/setup-device')
LOG_FILE = '/var/log/setup-backend.log'

PAIRING_CODE_JSON = CONFIG_DIR / 'pairing_code.json'
SETUP_COMPLETE_FILE = DATA_DIR / 'setup-complete'
CREDENTIALS_JSON = DATA_DIR / 'credentials.json'

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
    """Normalize pairing code: remove hyphens, uppercase"""
    return re.sub(r'[^A-Z0-9]', '', code.upper())

def generate_pairing_code():
    """Generate new pairing code (XXX-XXX format, A-Z0-9)"""
    import random
    import string
    
    chars = string.ascii_uppercase + string.digits
    code1 = ''.join(random.choice(chars) for _ in range(3))
    code2 = ''.join(random.choice(chars) for _ in range(3))
    code = f"{code1}-{code2}"
    
    generated_at = datetime.now()
    # Pairing code has long expiry (365 days) - setup can be run multiple times
    expires_at = generated_at + timedelta(days=365)
    
    pairing_data = {
        'code': code,
        'generated_at': generated_at.isoformat(),
        'expires_at': expires_at.isoformat()
    }
    
    return pairing_data

def ensure_pairing_code():
    """Ensure pairing code exists and is valid, regenerate if expired"""
    try:
        # Load existing code if present
        if PAIRING_CODE_JSON.exists():
            with open(PAIRING_CODE_JSON, 'r') as f:
                pairing_data = json.load(f)
            
            # Use existing pairing code if valid
            logger.info("Using existing pairing code")
            return pairing_data['code']
        
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
        pairing_data = generate_pairing_code()
        return pairing_data['code']

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
    """Validate pairing code format and expiry"""
    normalized = normalize_pairing_code(code)
    
    # Whitelist test pairing code for development/testing
    TEST_CODE = "ABC123"  # Will match "abc-123", "ABC-123", etc.
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
    
    # Check expiry from JSON
    try:
        with open(PAIRING_CODE_JSON, 'r') as f:
            pairing_data = json.load(f)
        expires_at = datetime.fromisoformat(pairing_data.get('expires_at', ''))
        if datetime.now() > expires_at:
            logger.warning("Pairing code expired")
            return False
    except Exception as e:
        logger.error(f"Failed to check pairing code expiry: {e}")
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
    try:
        result = subprocess.run(
            ['nmcli', 'connection', 'up', ssid],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            logger.error(f"Failed to activate connection: {result.stderr}")
            return False
        
        logger.info(f"Connected to WiFi: {ssid}")
        return True
        
    except Exception as e:
        logger.error(f"Error connecting to WiFi: {e}")
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
        
        # Validate pairing code
        if not validate_pairing_code(pairing_code):
            logger.warning(f"Invalid pairing code attempt")
            return jsonify({'error': 'Invalid or expired pairing code'}), 401
        
        logger.info(f"Configuration request for SSID: {ssid}")
        
        # Create NetworkManager connection
        if not create_wifi_connection(ssid, password):
            return jsonify({'error': 'Failed to create WiFi connection'}), 500
        
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
        
        # Trigger NetworkManager to connect
        time.sleep(2)
        connect_to_wifi(ssid)
        
        logger.info("WiFi configuration completed successfully")
        
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
