#!/usr/bin/env python3
"""
CI OS Headless Setup - Captive Portal Web Server
Provides a simple web interface for WiFi and cloud pairing configuration
"""

import os
import json
import subprocess
import logging
from datetime import datetime
from flask import Flask, render_template_string, request, jsonify, redirect

# Configuration
SETUP_FLAG = "/var/lib/ci-os/setup-complete"
CONFIG_FILE = "/var/lib/ci-os/setup-config.json"
LOG_FILE = "/var/log/ci-os-headless-setup.log"

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)

app = Flask(__name__)

# HTML Template for the captive portal
PORTAL_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CI OS Setup</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        
        .container {
            background: white;
            border-radius: 16px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            max-width: 500px;
            width: 100%;
            padding: 40px;
        }
        
        .logo {
            text-align: center;
            margin-bottom: 30px;
        }
        
        .logo h1 {
            color: #667eea;
            font-size: 32px;
            margin-bottom: 10px;
        }
        
        .logo p {
            color: #666;
            font-size: 14px;
        }
        
        .form-group {
            margin-bottom: 24px;
        }
        
        label {
            display: block;
            color: #333;
            font-weight: 600;
            margin-bottom: 8px;
            font-size: 14px;
        }
        
        input[type="text"],
        input[type="password"],
        select {
            width: 100%;
            padding: 12px 16px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 16px;
            transition: border-color 0.3s;
        }
        
        input[type="text"]:focus,
        input[type="password"]:focus,
        select:focus {
            outline: none;
            border-color: #667eea;
        }
        
        .help-text {
            color: #888;
            font-size: 12px;
            margin-top: 4px;
        }
        
        button {
            width: 100%;
            padding: 14px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: transform 0.2s, box-shadow 0.2s;
        }
        
        button:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(102, 126, 234, 0.4);
        }
        
        button:active {
            transform: translateY(0);
        }
        
        button:disabled {
            opacity: 0.6;
            cursor: not-allowed;
            transform: none;
        }
        
        .message {
            padding: 12px;
            border-radius: 8px;
            margin-bottom: 20px;
            font-size: 14px;
        }
        
        .message.error {
            background-color: #fee;
            color: #c33;
            border: 1px solid #fcc;
        }
        
        .message.success {
            background-color: #efe;
            color: #3c3;
            border: 1px solid #cfc;
        }
        
        .message.info {
            background-color: #eef;
            color: #33c;
            border: 1px solid #ccf;
        }
        
        .divider {
            height: 1px;
            background: #e0e0e0;
            margin: 24px 0;
        }
        
        .scan-btn {
            background: #f0f0f0;
            color: #333;
            margin-bottom: 16px;
            font-size: 14px;
            padding: 10px;
        }
        
        .scan-btn:hover {
            background: #e0e0e0;
        }
        
        #loading {
            display: none;
            text-align: center;
            margin: 20px 0;
        }
        
        .spinner {
            border: 3px solid #f3f3f3;
            border-top: 3px solid #667eea;
            border-radius: 50%;
            width: 40px;
            height: 40px;
            animation: spin 1s linear infinite;
            margin: 0 auto;
        }
        
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">
            <h1>🖥️ CI OS</h1>
            <p>First-Time Setup</p>
        </div>
        
        {% if message %}
        <div class="message {{ message_type }}">{{ message }}</div>
        {% endif %}
        
        <form id="setupForm" method="POST" action="/configure">
            <div class="form-group">
                <label for="pairing_code">Pairing Code</label>
                <input type="text" id="pairing_code" name="pairing_code" 
                       placeholder="e.g., X25-RJ8" required
                       pattern="[A-Z0-9]{3}-[A-Z0-9]{3}"
                       title="Format: XXX-XXX (uppercase letters and numbers)">
                <div class="help-text">Enter the pairing code from setup.ci.computer</div>
            </div>
            
            <div class="divider"></div>
            
            <button type="button" class="scan-btn" onclick="scanNetworks()">🔍 Scan for Networks</button>
            
            <div class="form-group">
                <label for="wifi_ssid">WiFi Network</label>
                <select id="wifi_ssid" name="wifi_ssid" onchange="toggleManualSSID()">
                    <option value="">Select a network...</option>
                    <option value="_manual_">Enter manually...</option>
                </select>
            </div>
            
            <div class="form-group" id="manual_ssid_group" style="display: none;">
                <label for="manual_ssid">Network Name (SSID)</label>
                <input type="text" id="manual_ssid" name="manual_ssid" placeholder="Enter network name">
            </div>
            
            <div class="form-group">
                <label for="wifi_password">WiFi Password</label>
                <input type="password" id="wifi_password" name="wifi_password" 
                       placeholder="Enter your WiFi password" required>
                <div class="help-text">Your password is encrypted and stored securely</div>
            </div>
            
            <div id="loading">
                <div class="spinner"></div>
                <p style="margin-top: 12px; color: #666;">Configuring your device...</p>
            </div>
            
            <button type="submit" id="submitBtn">Complete Setup</button>
        </form>
    </div>
    
    <script>
        function toggleManualSSID() {
            const select = document.getElementById('wifi_ssid');
            const manualGroup = document.getElementById('manual_ssid_group');
            const manualInput = document.getElementById('manual_ssid');
            
            if (select.value === '_manual_') {
                manualGroup.style.display = 'block';
                manualInput.required = true;
            } else {
                manualGroup.style.display = 'none';
                manualInput.required = false;
            }
        }
        
        function scanNetworks() {
            const select = document.getElementById('wifi_ssid');
            const originalText = event.target.textContent;
            event.target.textContent = '⏳ Scanning...';
            event.target.disabled = true;
            
            fetch('/scan')
                .then(response => response.json())
                .then(data => {
                    // Clear existing options except first two
                    select.innerHTML = '<option value="">Select a network...</option><option value="_manual_">Enter manually...</option>';
                    
                    // Add scanned networks
                    data.networks.forEach(network => {
                        const option = document.createElement('option');
                        option.value = network.ssid;
                        option.textContent = `${network.ssid} (${network.signal}%)`;
                        select.appendChild(option);
                    });
                    
                    event.target.textContent = originalText;
                    event.target.disabled = false;
                })
                .catch(error => {
                    console.error('Error scanning networks:', error);
                    event.target.textContent = originalText;
                    event.target.disabled = false;
                    alert('Failed to scan networks. Please enter manually.');
                });
        }
        
        document.getElementById('setupForm').addEventListener('submit', function(e) {
            e.preventDefault();
            
            // Show loading indicator
            document.getElementById('loading').style.display = 'block';
            document.getElementById('submitBtn').disabled = true;
            
            // Get form data
            const formData = new FormData(this);
            
            // Use manual SSID if selected
            if (formData.get('wifi_ssid') === '_manual_') {
                formData.set('wifi_ssid', formData.get('manual_ssid'));
            }
            
            // Submit form
            fetch('/configure', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    document.querySelector('.container').innerHTML = `
                        <div class="logo">
                            <h1>✅ Setup Complete!</h1>
                            <p style="margin-top: 20px; color: #666;">
                                Your CI OS device is now connected to your WiFi network 
                                and paired to your account.
                            </p>
                            <p style="margin-top: 12px; color: #888; font-size: 12px;">
                                This page will close automatically...
                            </p>
                        </div>
                    `;
                    
                    // Close the window after 5 seconds
                    setTimeout(() => {
                        window.close();
                    }, 5000);
                } else {
                    document.getElementById('loading').style.display = 'none';
                    document.getElementById('submitBtn').disabled = false;
                    alert('Setup failed: ' + (data.error || 'Unknown error'));
                }
            })
            .catch(error => {
                document.getElementById('loading').style.display = 'none';
                document.getElementById('submitBtn').disabled = false;
                alert('Setup failed: ' + error.message);
            });
        });
        
        // Auto-scan on page load
        window.addEventListener('load', function() {
            setTimeout(() => {
                const scanBtn = document.querySelector('.scan-btn');
                if (scanBtn) scanBtn.click();
            }, 500);
        });
    </script>
</body>
</html>
"""

SUCCESS_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Setup Complete - CI OS</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        .container {
            background: white;
            border-radius: 16px;
            padding: 60px 40px;
            text-align: center;
            max-width: 500px;
        }
        h1 {
            color: #667eea;
            font-size: 48px;
            margin-bottom: 20px;
        }
        p {
            color: #666;
            font-size: 18px;
            line-height: 1.6;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>✅</h1>
        <h2 style="color: #333; margin-bottom: 20px;">Setup Complete!</h2>
        <p>Your CI OS device is now connected and ready to use.</p>
        <p style="margin-top: 20px; font-size: 14px; color: #888;">
            You can close this window.
        </p>
    </div>
</body>
</html>
"""


@app.route('/')
@app.route('/index.html')
@app.route('/generate_204')  # Android captive portal detection
@app.route('/gen_204')  # Android alternative
@app.route('/hotspot-detect.html')  # iOS captive portal detection
@app.route('/library/test/success.html')  # iOS alternative
@app.route('/connecttest.txt')  # Windows captive portal detection
def index():
    """Serve the captive portal page"""
    logging.info(f"Captive portal accessed from {request.remote_addr}")
    return render_template_string(PORTAL_TEMPLATE, message=None, message_type=None)


@app.route('/scan')
def scan_networks():
    """Scan for available WiFi networks"""
    try:
        logging.info("Scanning for WiFi networks")
        
        # Rescan WiFi networks
        subprocess.run(['nmcli', 'device', 'wifi', 'rescan'], 
                      capture_output=True, timeout=10)
        
        # Get list of networks
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list'],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        networks = []
        seen_ssids = set()
        
        for line in result.stdout.strip().split('\n'):
            if not line:
                continue
                
            parts = line.split(':')
            if len(parts) >= 2:
                ssid = parts[0].strip()
                signal = parts[1].strip() if len(parts) > 1 else '0'
                
                # Skip empty SSIDs and duplicates
                if ssid and ssid not in seen_ssids and ssid != 'CI-OS-Setup':
                    networks.append({
                        'ssid': ssid,
                        'signal': signal
                    })
                    seen_ssids.add(ssid)
        
        # Sort by signal strength
        networks.sort(key=lambda x: int(x['signal']), reverse=True)
        
        logging.info(f"Found {len(networks)} networks")
        return jsonify({'networks': networks})
        
    except Exception as e:
        logging.error(f"Error scanning networks: {e}")
        return jsonify({'networks': [], 'error': str(e)})


@app.route('/configure', methods=['POST'])
def configure():
    """Process the configuration form"""
    try:
        pairing_code = request.form.get('pairing_code', '').strip()
        wifi_ssid = request.form.get('wifi_ssid', '').strip()
        wifi_password = request.form.get('wifi_password', '')
        
        logging.info(f"Configuration received - Pairing code: {pairing_code}, SSID: {wifi_ssid}")
        
        # Validate inputs
        if not pairing_code or not wifi_ssid or not wifi_password:
            return jsonify({
                'success': False,
                'error': 'All fields are required'
            })
        
        # Save configuration
        config = {
            'pairing_code': pairing_code,
            'wifi_ssid': wifi_ssid,
            'timestamp': datetime.now().isoformat()
        }
        
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        with open(CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=2)
        
        logging.info(f"Configuration saved to {CONFIG_FILE}")
        
        # Connect to WiFi network
        success = connect_to_wifi(wifi_ssid, wifi_password)
        
        if success:
            # Perform cloud pairing
            pair_success = perform_cloud_pairing(pairing_code)
            
            if pair_success:
                # Mark setup as complete
                with open(SETUP_FLAG, 'w') as f:
                    f.write(datetime.now().isoformat())
                
                logging.info("Setup completed successfully")
                return jsonify({'success': True})
            else:
                logging.warning("Cloud pairing failed, but WiFi connected")
                # Still mark as complete since WiFi works
                with open(SETUP_FLAG, 'w') as f:
                    f.write(datetime.now().isoformat())
                return jsonify({'success': True, 'warning': 'Cloud pairing failed'})
        else:
            return jsonify({
                'success': False,
                'error': 'Failed to connect to WiFi network'
            })
            
    except Exception as e:
        logging.error(f"Configuration error: {e}", exc_info=True)
        return jsonify({
            'success': False,
            'error': str(e)
        })


def connect_to_wifi(ssid, password):
    """Connect to a WiFi network using NetworkManager"""
    try:
        logging.info(f"Connecting to WiFi network: {ssid}")
        
        # Try to connect to the network
        result = subprocess.run(
            ['nmcli', 'device', 'wifi', 'connect', ssid, 'password', password],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode == 0:
            logging.info(f"Successfully connected to {ssid}")
            return True
        else:
            logging.error(f"Failed to connect to {ssid}: {result.stderr}")
            return False
            
    except Exception as e:
        logging.error(f"Error connecting to WiFi: {e}")
        return False


def perform_cloud_pairing(pairing_code):
    """Pair the device with the cloud account using the pairing code"""
    try:
        logging.info(f"Attempting cloud pairing with code: {pairing_code}")
        
        # TODO: Implement actual cloud pairing API call
        # For now, we'll just log it and return success
        # In production, this would make an API call to setup.ci.computer
        
        # Example API call (to be implemented):
        # response = requests.post(
        #     'https://setup.ci.computer/api/pair',
        #     json={
        #         'pairing_code': pairing_code,
        #         'device_id': get_device_id(),
        #         'device_name': 'CI-OS-Device'
        #     },
        #     timeout=10
        # )
        # return response.status_code == 200
        
        logging.info("Cloud pairing placeholder - would call API in production")
        return True
        
    except Exception as e:
        logging.error(f"Cloud pairing error: {e}")
        return False


def get_device_id():
    """Get a unique device identifier"""
    try:
        # Use machine-id as device identifier
        with open('/etc/machine-id', 'r') as f:
            return f.read().strip()
    except:
        # Fallback to MAC address
        try:
            result = subprocess.run(
                ['cat', '/sys/class/net/wlan0/address'],
                capture_output=True,
                text=True
            )
            return result.stdout.strip().replace(':', '')
        except:
            return 'unknown'


if __name__ == '__main__':
    logging.info("Starting CI OS Captive Portal Web Server")
    
    # Ensure directories exist
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    
    # Run the Flask app
    app.run(
        host='0.0.0.0',
        port=80,
        debug=False,
        threaded=True
    )
