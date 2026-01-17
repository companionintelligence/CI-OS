#!/usr/bin/env python3
"""
CI-OS Captive Portal Web Server
================================

A lightweight HTTP server that implements captive portal detection for iOS,
Android, and Windows devices. Serves a configuration interface for Wi-Fi
credentials and cloud pairing token input.

Features:
- Automatic CPD (Captive Portal Detection) handling for all major platforms
- Responsive HTML interface for network configuration
- API endpoints for credential submission
- Integration with provisioning manager via shared configuration

Author: CI-OS Team
License: MIT
"""

import os
import json
import logging
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
from pathlib import Path
from typing import Dict, Any

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('/var/log/captive-portal.log')
    ]
)
logger = logging.getLogger(__name__)

# Constants
PORTAL_IP = "10.42.0.1"
PORTAL_PORT = 80
PORTAL_URL = f"http://{PORTAL_IP}/config"
SCAN_CACHE_PATH = '/run/provisioning/scan_results.json'
CONFIG_PATH = '/etc/provisioning/config.json'

# HTML template for the configuration page
CONFIG_PAGE_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CI-OS Device Setup</title>
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
        
        input, select {
            width: 100%;
            padding: 12px 16px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 16px;
            transition: border-color 0.3s;
        }
        
        input:focus, select:focus {
            outline: none;
            border-color: #667eea;
        }
        
        .btn {
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
        
        .btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 20px rgba(102, 126, 234, 0.4);
        }
        
        .btn:active {
            transform: translateY(0);
        }
        
        .btn:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }
        
        .help-text {
            font-size: 12px;
            color: #888;
            margin-top: 6px;
        }
        
        .error {
            background: #fee;
            border: 1px solid #fcc;
            color: #c33;
            padding: 12px;
            border-radius: 8px;
            margin-bottom: 20px;
            display: none;
        }
        
        .success {
            background: #efe;
            border: 1px solid #cfc;
            color: #3c3;
            padding: 12px;
            border-radius: 8px;
            margin-bottom: 20px;
            display: none;
        }
        
        .spinner {
            border: 3px solid #f3f3f3;
            border-top: 3px solid #667eea;
            border-radius: 50%;
            width: 40px;
            height: 40px;
            animation: spin 1s linear infinite;
            margin: 20px auto;
            display: none;
        }
        
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        
        .rescan-btn {
            background: #f0f0f0;
            color: #333;
            padding: 8px 16px;
            border: none;
            border-radius: 6px;
            font-size: 12px;
            cursor: pointer;
            margin-top: 8px;
        }
        
        .rescan-btn:hover {
            background: #e0e0e0;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">
            <h1>🔧 CI-OS</h1>
            <p>Device Configuration</p>
        </div>
        
        <div id="error" class="error"></div>
        <div id="success" class="success"></div>
        
        <form id="configForm">
            <div class="form-group">
                <label for="ssid">Wi-Fi Network</label>
                <select id="ssid" name="ssid" required>
                    <option value="">Select a network...</option>
                    <!-- Networks will be populated by JavaScript -->
                </select>
                <button type="button" class="rescan-btn" onclick="rescanNetworks()">
                    🔄 Rescan Networks
                </button>
                <p class="help-text">
                    Note: Rescanning will temporarily disconnect the setup network.
                </p>
            </div>
            
            <div class="form-group">
                <label for="password">Wi-Fi Password</label>
                <input 
                    type="password" 
                    id="password" 
                    name="password" 
                    placeholder="Enter network password"
                    autocomplete="off"
                >
                <p class="help-text">Leave blank for open networks</p>
            </div>
            
            <div class="form-group">
                <label for="token">Pairing Token</label>
                <input 
                    type="text" 
                    id="token" 
                    name="token" 
                    placeholder="e.g., XY78K2"
                    maxlength="6"
                    pattern="[A-Z0-9]{6}"
                    required
                    style="text-transform: uppercase"
                >
                <p class="help-text">
                    Get your 6-character token from your account dashboard
                </p>
            </div>
            
            <button type="submit" class="btn" id="submitBtn">
                Connect Device
            </button>
        </form>
        
        <div class="spinner" id="spinner"></div>
    </div>
    
    <script>
        // Load available networks
        async function loadNetworks() {
            try {
                const response = await fetch('/api/networks');
                const networks = await response.json();
                
                const select = document.getElementById('ssid');
                select.innerHTML = '<option value="">Select a network...</option>';
                
                networks.forEach(network => {
                    const option = document.createElement('option');
                    option.value = network.ssid;
                    
                    const security = network.security !== 'Open' ? '🔒' : '📡';
                    const strength = '▂'.repeat(Math.ceil(network.strength / 25));
                    
                    option.textContent = `${security} ${network.ssid} ${strength}`;
                    select.appendChild(option);
                });
            } catch (error) {
                console.error('Failed to load networks:', error);
                showError('Failed to load available networks');
            }
        }
        
        // Rescan networks
        async function rescanNetworks() {
            if (!confirm('Rescanning will temporarily disconnect you. Continue?')) {
                return;
            }
            
            try {
                const response = await fetch('/api/rescan', { method: 'POST' });
                if (response.ok) {
                    showSuccess('Rescanning... Please reconnect in a moment.');
                    setTimeout(() => {
                        window.location.reload();
                    }, 10000);
                }
            } catch (error) {
                showError('Failed to initiate rescan');
            }
        }
        
        // Handle form submission
        document.getElementById('configForm').addEventListener('submit', async (e) => {
            e.preventDefault();
            
            const ssid = document.getElementById('ssid').value;
            const password = document.getElementById('password').value;
            const token = document.getElementById('token').value.toUpperCase();
            
            if (!ssid) {
                showError('Please select a Wi-Fi network');
                return;
            }
            
            if (!token || token.length !== 6) {
                showError('Please enter a valid 6-character pairing token');
                return;
            }
            
            // Show spinner
            document.getElementById('submitBtn').disabled = true;
            document.getElementById('spinner').style.display = 'block';
            document.getElementById('configForm').style.display = 'none';
            
            try {
                const response = await fetch('/api/configure', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        ssid: ssid,
                        password: password,
                        token: token
                    })
                });
                
                if (response.ok) {
                    showSuccess('Configuration saved! Connecting to network...');
                    setTimeout(() => {
                        document.getElementById('spinner').style.display = 'none';
                        document.querySelector('.success').innerHTML = 
                            '✅ Device configured successfully!<br><br>' +
                            'You can now close this window.';
                    }, 3000);
                } else {
                    const error = await response.json();
                    throw new Error(error.message || 'Configuration failed');
                }
            } catch (error) {
                showError(error.message);
                document.getElementById('submitBtn').disabled = false;
                document.getElementById('spinner').style.display = 'none';
                document.getElementById('configForm').style.display = 'block';
            }
        });
        
        function showError(message) {
            const errorDiv = document.getElementById('error');
            errorDiv.textContent = message;
            errorDiv.style.display = 'block';
            setTimeout(() => {
                errorDiv.style.display = 'none';
            }, 5000);
        }
        
        function showSuccess(message) {
            const successDiv = document.getElementById('success');
            successDiv.textContent = message;
            successDiv.style.display = 'block';
        }
        
        // Load networks on page load
        loadNetworks();
        
        // Auto-uppercase token input
        document.getElementById('token').addEventListener('input', (e) => {
            e.target.value = e.target.value.toUpperCase();
        });
    </script>
</body>
</html>
"""


class CaptivePortalHandler(BaseHTTPRequestHandler):
    """HTTP request handler for captive portal"""
    
    def log_message(self, format, *args):
        """Override to use our logger"""
        logger.info(f"{self.address_string()} - {format % args}")
    
    def do_GET(self):
        """Handle GET requests"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        # 1. iOS Captive Portal Detection
        if path in ['/hotspot-detect.html', '/library/test/success.html']:
            self._send_redirect()
            return
        
        # 2. Android Captive Portal Detection
        if path in ['/generate_204', '/gen_204']:
            self._send_redirect()
            return
        
        # 3. Windows Captive Portal Detection
        if path in ['/connecttest.txt', '/ncsi.txt']:
            self._send_redirect()
            return
        
        # 4. Serve configuration page
        if path == '/config':
            self._serve_config_page()
            return
        
        # 5. API: Get available networks
        if path == '/api/networks':
            self._serve_networks()
            return
        
        # 6. Catch-all redirect for DNS hijacked requests
        host = self.headers.get('Host', '')
        if host and host != PORTAL_IP:
            self._send_redirect()
            return
        
        # Default: serve config page
        self._serve_config_page()
    
    def do_POST(self):
        """Handle POST requests"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        # API: Submit configuration
        if path == '/api/configure':
            self._handle_configure()
            return
        
        # API: Rescan networks
        if path == '/api/rescan':
            self._handle_rescan()
            return
        
        self.send_error(404)
    
    def _send_redirect(self):
        """Send redirect to configuration page"""
        self.send_response(302)
        self.send_header('Location', PORTAL_URL)
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        self.end_headers()
    
    def _serve_config_page(self):
        """Serve the configuration HTML page"""
        self.send_response(200)
        self.send_header('Content-type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.end_headers()
        self.wfile.write(CONFIG_PAGE_HTML.encode('utf-8'))
    
    def _serve_networks(self):
        """Serve cached network scan results"""
        try:
            if os.path.exists(SCAN_CACHE_PATH):
                with open(SCAN_CACHE_PATH, 'r') as f:
                    networks = json.load(f)
            else:
                networks = []
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(networks).encode('utf-8'))
            
        except Exception as e:
            logger.error(f"Error serving networks: {e}")
            self.send_error(500)
    
    def _handle_configure(self):
        """Handle configuration submission"""
        try:
            # Read request body
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8')
            data = json.loads(body)
            
            ssid = data.get('ssid', '').strip()
            password = data.get('password', '').strip()
            token = data.get('token', '').strip().upper()
            
            # Validate input
            if not ssid:
                raise ValueError("SSID is required")
            
            if not token or len(token) != 6:
                raise ValueError("Invalid pairing token")
            
            # Save configuration
            config = {
                'wifi_credentials': {
                    'ssid': ssid,
                    'password': password
                },
                'pairing_token': token,
                'new_credentials': True
            }
            
            os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
            with open(CONFIG_PATH, 'w') as f:
                json.dump(config, f, indent=2)
            
            logger.info(f"Configuration saved: SSID={ssid}, Token={token}")
            
            # Send success response
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'success'}).encode('utf-8'))
            
        except Exception as e:
            logger.error(f"Error handling configuration: {e}")
            self.send_response(400)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'status': 'error',
                'message': str(e)
            }).encode('utf-8'))
    
    def _handle_rescan(self):
        """Handle network rescan request"""
        try:
            # Signal to provisioning manager to rescan
            # For now, just acknowledge
            logger.info("Rescan requested")
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'rescanning'}).encode('utf-8'))
            
        except Exception as e:
            logger.error(f"Error handling rescan: {e}")
            self.send_error(500)


class CaptivePortalServer:
    """Captive portal web server"""
    
    def __init__(self, host=PORTAL_IP, port=PORTAL_PORT):
        self.host = host
        self.port = port
        self.server = None
        self.running = False
        
        # Setup signal handlers
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        logger.info(f"Received signal {signum}, shutting down...")
        self.stop()
        sys.exit(0)
    
    def start(self):
        """Start the server"""
        try:
            self.server = HTTPServer((self.host, self.port), CaptivePortalHandler)
            self.running = True
            
            logger.info(f"Captive Portal server started on {self.host}:{self.port}")
            logger.info(f"Portal URL: {PORTAL_URL}")
            
            self.server.serve_forever()
            
        except Exception as e:
            logger.error(f"Server error: {e}")
            raise
    
    def stop(self):
        """Stop the server"""
        if self.server:
            self.running = False
            self.server.shutdown()
            logger.info("Server stopped")


def main():
    """Main entry point"""
    # Ensure running as root (needed to bind to port 80)
    if os.geteuid() != 0:
        print("This server must be run as root to bind to port 80")
        sys.exit(1)
    
    server = CaptivePortalServer()
    server.start()


if __name__ == '__main__':
    main()
