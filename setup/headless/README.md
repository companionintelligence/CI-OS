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
- ✅ Pairing code authentication (XXX-XXX format, 24-hour expiry)
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

This creates: `setup-device_<version>_arm64.deb`

## Installation

```bash
sudo dpkg -i setup-device_<version>_arm64.deb
```

The postinst script will:
- Enable all services for boot-time startup
- Start all services immediately
- Generate pairing code
- Configure permissions

## Usage

1. **Connect to hotspot**: `Setup-Device-<SERIAL>` (password: `SetupDevice123`)
2. **Access portal**: http://192.168.99.1 (or captive portal will auto-launch)
3. **Enter pairing code**: Found at `/var/lib/setup-device/pairing-code`
4. **Select WiFi network**: Choose from scanned networks
5. **Enter password**: WiFi password (leave blank for open networks)
6. **Submit**: Device configures and connects automatically

## Service Management

### Check Status
```bash
systemctl status hostapd.service
systemctl status dnsmasq-setup.service
systemctl status nginx.service
systemctl status setup-backend.service
```

### View Logs
```bash
journalctl -u setup-backend.service -f
journalctl -u hostapd.service -f
tail -f /var/log/setup-backend.log
```

### Disable Setup Mode (after configuration)
```bash
sudo systemctl disable hostapd.service
sudo systemctl disable dnsmasq-setup.service
```

## Files and Directories

- `/etc/hostapd/hostapd.conf`: Hotspot configuration
- `/etc/dnsmasq.d/setup-portal.conf`: DHCP/DNS configuration
- `/etc/nginx/sites-available/setup-portal`: Web server configuration
- `/etc/netplan/50-setup-mode.yaml`: Static IP configuration
- `/opt/setup-backend/setup_service.py`: Flask backend service
- `/var/www/setup-portal/index.html`: Web portal
- `/var/lib/setup-device/pairing-code`: Pairing code (root-only)
- `/var/lib/setup-device/setup-complete`: Setup completion flag
- `/var/lib/setup-device/credentials`: Stored WiFi credentials (root-only)
- `/var/log/setup-backend.log`: Backend service logs

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
