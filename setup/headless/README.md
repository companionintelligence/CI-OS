# Headless Device Setup System

Production-grade headless device first-time WiFi setup system for Ubuntu Server.

## Overview

This system provides a captive portal-based WiFi configuration interface for headless devices. It uses:

- **hostapd**: Creates WiFi hotspot (Setup-Device-<SERIAL>)
- **dnsmasq**: Provides DHCP and DNS redirection for captive portal detection
- **nginx**: Serves the web portal and proxies API requests
- **Flask**: Backend API for WiFi scanning and configuration
- **NetworkManager**: Manages WiFi connections

## Features

- ✅ CDC-compliant captive portal (Apple/Google/Microsoft detection)
- ✅ Works without JavaScript (form submission works without JS)
- ✅ Automatic boot-time activation via systemd
- ✅ Pairing code authentication (6-character format)
- ✅ Mobile-first responsive design with dark mode support
- ✅ Secure credential storage (root-only permissions)

## Architecture

All services run as daemonized systemd services that automatically start on device boot:

1. **hostapd.service**: Creates WiFi hotspot
2. **dnsmasq-setup.service**: Provides DHCP/DNS (depends on hostapd)
3. **nginx.service**: Serves web portal (standard nginx)
4. **setup-backend.service**: Flask API (depends on nginx)

### Service Lifecycle

- **On boot**: All services start automatically if enabled
- **After configuration**: Hotspot services (hostapd, dnsmasq-setup) are disabled
- **Backend service**: Remains active for status monitoring

## Building

```bash
cd setup/headless
./build.sh
```

This creates: `setup-device_<version>_amd64.deb`

## Installation & Setup

### Full Installation Workflow

```bash
# 1. Build the package
cd setup/headless
./build.sh

# 2. Stop any running old services (if upgrading)
sudo systemctl stop setup-backend.service 2>/dev/null || true
sudo systemctl stop setup-network-monitor.service 2>/dev/null || true
sudo systemctl stop hostapd-setup.service 2>/dev/null || true
sudo systemctl stop dnsmasq-setup.service 2>/dev/null || true
sudo pkill -9 -f "setup_service.py" 2>/dev/null || true
sudo pkill -9 -f "setup-network-monitor.sh" 2>/dev/null || true

# 3. Install the package
sudo dpkg -i setup-device_*.deb

# 4. Verify services are installed and enabled
systemctl list-unit-files | grep setup-

# 5. Check service status
systemctl status setup-backend.service
systemctl status setup-network-monitor.service
systemctl status hostapd-setup.service
systemctl status dnsmasq-setup.service
systemctl status nginx.service
```

### What postinst Installation Does

The postinst script automatically:
- Stops any old services from previous installation
- Reloads systemd daemon with new service definitions
- Kills lingering background processes
- Enables all services for boot-time startup
- Generates initial pairing code
- Configures file permissions (600 for secrets, 755 for scripts)
- Sets up nginx site configuration
- Applies netplan network configuration
- Generates self-signed SSL certificate
- Starts all services immediately:
  - `setup-backend.service` (Flask API)
  - `setup-network-monitor.service` (connectivity monitor)
  - `nginx.service` (web portal)
  - `hostapd-setup.service` & `dnsmasq-setup.service` (started if no connectivity detected)

### Manual Service Management

If you need to manually control services:

```bash
# Enable services for boot startup
sudo systemctl enable setup-backend.service
sudo systemctl enable setup-network-monitor.service
sudo systemctl enable hostapd-setup.service
sudo systemctl enable dnsmasq-setup.service
sudo systemctl enable nginx.service

# Start services
sudo systemctl start setup-backend.service
sudo systemctl start setup-network-monitor.service
sudo systemctl start nginx.service
# Note: hostapd and dnsmasq start automatically if device loses connectivity

# Restart all services
sudo systemctl restart setup-backend.service
sudo systemctl restart nginx.service
sudo systemctl restart setup-network-monitor.service

# Disable services (prevent startup on boot)
sudo systemctl disable setup-backend.service
sudo systemctl disable setup-network-monitor.service
sudo systemctl disable hostapd-setup.service
sudo systemctl disable dnsmasq-setup.service
```

### Checking Installation Success

After installation, verify everything is running:

```bash
# Check all services are enabled
systemctl is-enabled setup-backend.service && echo "✓ setup-backend enabled"
systemctl is-enabled setup-network-monitor.service && echo "✓ setup-network-monitor enabled"
systemctl is-enabled hostapd-setup.service && echo "✓ hostapd-setup enabled"
systemctl is-enabled dnsmasq-setup.service && echo "✓ dnsmasq-setup enabled"

# Check services are active
systemctl is-active setup-backend.service && echo "✓ setup-backend active"
systemctl is-active setup-network-monitor.service && echo "✓ setup-network-monitor active"
systemctl is-active nginx.service && echo "✓ nginx active"

# View pairing code
sudo cat /etc/setup-device/pairing_code.json | grep code

# Check hotspot status (should be inactive until connectivity is lost)
systemctl is-active hostapd-setup.service && echo "✓ Hotspot active" || echo "ℹ Hotspot waiting for connectivity loss"

# Test backend API
curl http://localhost:5000/health
```

## Usage

1. **Connect to hotspot**: `Companion-Setup` (password: `SetupDevice123`)
2. **Access portal**: http://192.168.99.1 (or captive portal will auto-launch)
3. **Enter pairing code**: Use the device-generated code OR use test code `abc-123`
   - Device code: Found in `/etc/setup-device/pairing_code.json`
   - Test code: `abc-123` (always valid, for testing/demos)
4. **Select WiFi network**: Choose from scanned networks
5. **Enter password**: WiFi password (leave blank for open networks)
6. **Submit**: Device configures and connects automatically

## Service Management

### Quick Status Check
```bash
sudo systemctl status setup-backend.service
sudo systemctl status setup-network-monitor.service
sudo systemctl status hostapd-setup.service
sudo systemctl status dnsmasq-setup.service
```

### View Logs
```bash
# Backend service logs
journalctl -u setup-backend.service -f
journalctl -u setup-network-monitor.service -f

# System logs
tail -f /var/log/setup-backend.log
journalctl -u hostapd-setup.service -f
journalctl -u dnsmasq-setup.service -f
```

### Manually Stop/Start Services
```bash
# Stop all setup services
sudo systemctl stop setup-backend.service
sudo systemctl stop setup-network-monitor.service
sudo systemctl stop hostapd-setup.service
sudo systemctl stop dnsmasq-setup.service

# Start services again
sudo systemctl start setup-backend.service
sudo systemctl start setup-network-monitor.service

# Restart specific service
sudo systemctl restart setup-backend.service
```

### Disable Setup Mode Permanently
After device is configured and on WiFi, prevent hotspot from restarting:
```bash
# Disable hotspot services from auto-starting
sudo systemctl disable hostapd-setup.service
sudo systemctl disable dnsmasq-setup.service

# Stop them if currently running
sudo systemctl stop hostapd-setup.service
sudo systemctl stop dnsmasq-setup.service
```

## Files and Directories

### Configuration Files
- `/etc/hostapd/hostapd-setup.conf`: Hotspot (AP) configuration
- `/etc/dnsmasq.d/setup-portal.conf`: DHCP/DNS configuration
- `/etc/nginx/sites-available/setup-portal`: Web server configuration
- `/etc/netplan/50-setup-mode.yaml`: Static IP configuration for setup mode
- `/etc/setup-device/device.conf`: Device configuration
- `/etc/setup-device/pairing_code.json`: Pairing code (root-only, 600 perms)

### Application Files
- `/opt/setup-backend/setup_service.py`: Flask backend API service
- `/var/www/setup-portal/index.html`: Web portal HTML/CSS/JS

### Runtime/Data Files
- `/var/lib/setup-device/setup-complete`: Setup completion flag (created after WiFi config)
- `/var/lib/setup-device/credentials.json`: Stored WiFi credentials (root-only, 600 perms)
- `/var/log/setup-backend.log`: Backend service logs

### SSL/Security
- `/etc/nginx/ssl/setup-device.crt`: Self-signed SSL certificate
- `/etc/nginx/ssl/setup-device.key`: SSL private key (root-only, 600 perms)

### Service Files
- `/etc/systemd/system/setup-backend.service`: Backend API service definition
- `/etc/systemd/system/setup-network-monitor.service`: Network connectivity monitor
- `/etc/systemd/system/hostapd-setup.service`: Hotspot AP service
- `/etc/systemd/system/dnsmasq-setup.service`: DHCP/DNS service

### Scripts
- `/usr/local/bin/setup-network-monitor.sh`: Connectivity monitor script
- `/usr/local/bin/setup-device-hotspot-start.sh`: Hotspot startup script

## API Endpoints

- `GET /health`: Health check
- `GET /api/status`: Get setup status
- `GET /api/scan-networks`: Scan for WiFi networks
- `POST /api/configure`: Configure WiFi (accepts JSON or form-encoded)

## Security

- No WAN access during setup mode
- No DNS leakage (all DNS redirected to gateway)
- Root-only credential files (600 permissions)
- No external HTTP calls
- Static gateway (no default route to WAN)
- SSH not enabled by default

## Troubleshooting

### Services not starting
```bash
# Check service status
systemctl status <service-name>

# Check logs
journalctl -u <service-name> -n 50

# Reload systemd
sudo systemctl daemon-reload
```

### Pairing code issues
```bash
# View pairing code
sudo cat /var/lib/setup-device/pairing-code

# Regenerate (if needed)
sudo rm /var/lib/setup-device/pairing-code
sudo systemctl restart setup-backend.service
```

### WiFi not connecting
```bash
# Check NetworkManager connections
nmcli connection show

# Check active connections
nmcli connection show --active

# Manual connection test
nmcli device wifi connect <SSID> password <PASSWORD>
```

## Uninstallation

```bash
sudo dpkg -r setup-device
```

The prerm script will stop and disable all services.
