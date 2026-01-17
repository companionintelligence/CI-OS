# Headless Wi-Fi Provisioning System Architecture

## Overview

This document describes the comprehensive headless Wi-Fi provisioning system for CI-OS based on Ubuntu 24.04 LTS. The system implements a "soft AP" (Access Point) provisioning workflow with automatic Ethernet fallback, a captive portal compatible with modern mobile operating systems, and a secure token-based cloud pairing mechanism.

## System Architecture

### Components

1. **Netplan Configuration** - Network abstraction layer using NetworkManager renderer
2. **Provisioning Manager** - Python FSM daemon for connectivity orchestration
3. **Captive Portal Server** - HTTP server for device configuration
4. **Cloud Pairing API** - Token-based device authentication

### Technology Stack

- **OS**: Ubuntu 24.04 LTS (Noble Numbat) on amd64 architecture
- **Network Configuration**: Netplan with NetworkManager renderer
- **Programming Language**: Python 3.12+
- **D-Bus**: NetworkManager control and monitoring
- **DNS**: dnsmasq for DNS hijacking
- **HTTP Server**: Python http.server for captive portal
- **Process Management**: systemd

## Network Configuration

### Netplan Setup

The system uses Netplan as the configuration abstraction layer with NetworkManager as the backend renderer. This enables programmatic control of network interfaces via D-Bus API.

**Configuration File**: `/etc/netplan/01-ci-os-provisioning.yaml`

```yaml
network:
  version: 2
  renderer: NetworkManager
  
  ethernets:
    enp3s0:
      dhcp4: true
      dhcp6: true
      optional: true  # Prevents boot blocking
  
  wifis:
    wlan0:
      dhcp4: true
      dhcp6: true
      optional: true
      access-points: {}
```

**Key Features**:
- `renderer: NetworkManager` - Enables D-Bus control for dynamic AP/Station switching
- `optional: true` - Prevents systemd-networkd-wait-online from blocking boot
- Empty `access-points` - NetworkManager manages connections dynamically

### NetworkManager Renderer Benefits

NetworkManager provides:
- Rich D-Bus API (`org.freedesktop.NetworkManager`)
- Programmatic wireless network scanning
- Dynamic hotspot creation with built-in hostapd and dnsmasq
- Automatic connection priority management
- Support for connection profiles

## Finite State Machine (FSM)

The provisioning manager implements a comprehensive FSM to handle all connectivity scenarios.

### States

| State | Description | Next States |
|-------|-------------|-------------|
| `BOOT_INIT` | System initialization, verify hardware | `ETHERNET_VERIFY` |
| `ETHERNET_VERIFY` | Check for active wired connection | `INTERNET_CHECK`, `WIFI_CONNECT` |
| `WIFI_CONNECT` | Attempt connection to known Wi-Fi | `INTERNET_CHECK`, `HOTSPOT_MODE` |
| `INTERNET_CHECK` | Validate end-to-end connectivity | `PAIRING`, `OPERATIONAL`, `WIFI_CONNECT` |
| `HOTSPOT_MODE` | Activate Access Point mode | `PROVISIONING` |
| `PROVISIONING` | Wait for user configuration input | `WIFI_CONNECT` |
| `PAIRING` | Perform cloud authentication | `OPERATIONAL` |
| `OPERATIONAL` | Normal operation, monitor connectivity | `ETHERNET_VERIFY` |

### State Transition Logic

```
BOOT_INIT
    ↓
ETHERNET_VERIFY
    ├─ Ethernet Active → INTERNET_CHECK
    └─ No Ethernet → WIFI_CONNECT
                        ├─ Known Network → INTERNET_CHECK
                        └─ No Network → HOTSPOT_MODE
                                            ↓
                                        PROVISIONING
                                            ↓
                                        (User Input)
                                            ↓
                                        WIFI_CONNECT → INTERNET_CHECK → PAIRING → OPERATIONAL
```

### Implementation

The FSM is implemented in `/usr/local/bin/provisioning_manager.py`:

- **D-Bus Integration**: Uses `dbus-python` and `PyGObject` for NetworkManager control
- **Non-blocking**: State transitions occur every 5 seconds
- **Self-healing**: Automatically recovers from network failures
- **Logging**: Comprehensive logging to `/var/log/device-provisioning.log`

## Single Radio Constraint

### Challenge

Most Wi-Fi hardware has a single physical radio that cannot simultaneously:
- Operate as an Access Point (fixed channel)
- Scan for networks (multiple channels)

### Solution: Cache-then-Broadcast

1. **Pre-AP Scan**: Before activating hotspot, perform Wi-Fi scan
2. **Cache Results**: Save scan results to `/run/provisioning/scan_results.json`
3. **Activate AP**: Switch to Access Point mode
4. **Serve Cached Data**: Captive portal displays cached network list
5. **Rescan on Request**: Teardown AP, rescan, restart AP (user acknowledges disconnection)

## Captive Portal

### Purpose

Provides a web interface for users to configure Wi-Fi credentials and pairing token when connected to the device's hotspot.

### Captive Portal Detection (CPD)

Modern operating systems use specific heuristics to detect captive portals:

#### iOS/macOS Detection

- **Probe URL**: `http://captive.apple.com/hotspot-detect.html`
- **Expected Response**: Page containing "Success"
- **Action**: Return `302 Redirect` to configuration page

#### Android Detection

- **Probe URL**: `http://connectivitycheck.gstatic.com/generate_204`
- **Expected Response**: `204 No Content`
- **Action**: Return `302 Redirect` to configuration page

#### Windows Detection

- **Probe URL**: `http://www.msftconnecttest.com/connecttest.txt`
- **Expected Response**: "Microsoft Connect Test"
- **Action**: Return `302 Redirect` to configuration page

### DNS Hijacking

**Mechanism**: dnsmasq resolves ALL DNS queries to the gateway IP (10.42.0.1)

**Configuration**: `/etc/NetworkManager/dnsmasq-shared.d/captive.conf`

```
address=/#/10.42.0.1
no-resolv
```

This ensures any HTTP request from connected clients is routed to the captive portal web server.

### Web Server Implementation

**File**: `/usr/local/bin/captive_portal.py`

**Features**:
- Lightweight Python `http.server` based implementation
- No external dependencies required
- Handles CPD probes for all major platforms
- Serves responsive HTML configuration page
- RESTful API endpoints for configuration

**API Endpoints**:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/config` | GET | Serve configuration HTML page |
| `/api/networks` | GET | Return cached Wi-Fi scan results |
| `/api/configure` | POST | Submit Wi-Fi credentials and pairing token |
| `/api/rescan` | POST | Trigger network rescan |

### Configuration UI

The captive portal serves a responsive HTML interface with:
- Network selection dropdown (populated from scan cache)
- Wi-Fi password input
- 6-character pairing token input
- Network strength indicators
- Security type indicators (🔒 for encrypted, 📡 for open)
- Rescan functionality with user acknowledgment

## Hotspot Configuration

### Parameters

- **SSID Format**: `Setup-Device-{MAC_SUFFIX}`
  - Example: `Setup-Device-A1B2`
  - MAC_SUFFIX: Last 4 hex digits of MAC address
- **Band**: 2.4 GHz (bg) - Better range and compatibility
- **Channel**: 6 (2.437 GHz)
- **Security**: WPA2-PSK with password (configurable)
- **IPv4 Method**: shared (10.42.0.1/24)
- **DHCP**: Automatic via dnsmasq (10.42.0.2-254)

### Creation

NetworkManager's D-Bus API or `nmcli` command:

```bash
nmcli device wifi hotspot \
  ifname wlan0 \
  ssid "Setup-Device-XXXX" \
  band bg \
  channel 6 \
  password "ci-os-setup"
```

This automatically:
- Configures hostapd for AP mode
- Starts dnsmasq for DHCP and DNS
- Enables NAT forwarding (though not used during setup)
- Assigns gateway IP 10.42.0.1

## Cloud Pairing System

### 6-Character Token Mechanism

**Purpose**: Securely associate device with user account without transmitting account credentials

**Security Properties**:
- **Entropy**: 36^6 ≈ 2.1 billion combinations
- **Time-to-Live**: 10-15 minutes
- **One-Time Use**: Token invalidated after successful pairing
- **Rate Limiting**: API enforces strict rate limits per IP/MAC

### Workflow

1. **Token Generation**:
   - User logs into account dashboard (on separate device)
   - Dashboard calls Cloud API: `POST /api/v1/provisioning/tokens`
   - API generates random 6-character token (A-Z, 0-9)
   - Token stored with user_id and expiry timestamp

2. **Device Configuration**:
   - User connects to device hotspot
   - Enters Wi-Fi credentials and pairing token in captive portal
   - Portal submits to device: `POST /api/configure`
   - Device saves credentials and token to `/etc/provisioning/config.json`

3. **Cloud Pairing**:
   - Device connects to internet via Wi-Fi
   - Device calls Cloud API: `POST /api/v1/devices/claim`
   - API validates token (not expired, exists)
   - API links device to token's user_id
   - API returns device access token (JWT)
   - Device transitions to OPERATIONAL state

### Cloud API Specification

#### Generate Token (User-Facing)

```
POST /api/v1/provisioning/tokens
Authorization: Bearer {user_jwt}

Response:
{
  "token": "XY78K2",
  "expires_at": "2026-01-17T15:00:00Z",
  "ttl_seconds": 900
}
```

#### Claim Device (Device-Facing)

```
POST /api/v1/devices/claim
Content-Type: application/json

Request:
{
  "pairing_token": "XY78K2",
  "mac_address": "aa:bb:cc:dd:ee:ff",
  "firmware_version": "1.0.0",
  "ip_address": "203.0.113.55"
}

Response (200 OK):
{
  "status": "success",
  "device_id": "uuid-here",
  "access_token": "jwt-token-here",
  "mqtt_endpoint": "mqtts://iot-hub.example.com"
}

Error Responses:
- 400: Invalid token format
- 404: Token not found
- 410: Token expired
- 429: Rate limit exceeded
```

## Security Considerations

### Network Security

1. **Firewall Rules** (UFW/nftables):
   ```bash
   # Allow only essential ports on hotspot interface
   ufw allow from 10.42.0.0/24 to any port 80 proto tcp   # HTTP
   ufw allow from 10.42.0.0/24 to any port 53 proto udp   # DNS
   ufw allow from 10.42.0.0/24 to any port 67 proto udp   # DHCP
   
   # Block all other incoming connections
   ufw default deny incoming
   ufw default allow outgoing
   ```

2. **Hotspot Security**:
   - **WPA2-PSK**: Encrypts link layer (L2) traffic
   - **Alternative**: Open network (no password) - Simpler but less secure
   - **Recommendation**: WPA2-PSK with password printed on device label

3. **Service Isolation**:
   - Provisioning manager runs as root (required for NetworkManager control)
   - Captive portal runs with restricted permissions
   - systemd security features: `ProtectSystem=strict`, `ProtectHome=yes`

### Data Security

1. **Credentials in Transit**:
   - **Risk**: If using open hotspot, credentials sent in plaintext over Wi-Fi
   - **Mitigation Window**: Exposure limited to seconds during configuration
   - **Best Practice**: Use WPA2-PSK for hotspot

2. **Cloud Communication**:
   - **Requirement**: All API calls use HTTPS (TLS 1.2+)
   - **Verification**: Validate server certificates
   - **Token Transmission**: Pairing token only sent over encrypted connection

3. **Local Storage**:
   - **Config File**: `/etc/provisioning/config.json` (mode 600, root-only)
   - **Contains**: Wi-Fi password and pairing token (temporarily)
   - **Cleanup**: Token deleted after successful pairing

### Rate Limiting

Cloud API must implement:
- **Per IP**: Max 10 pairing attempts per hour
- **Per MAC**: Max 5 pairing attempts per hour
- **Global**: Max 1000 token generations per user per day

## systemd Integration

### Service Ordering

**device-provisioning.service**:
- `After=NetworkManager.service` - Ensures NetworkManager is available
- `Wants=NetworkManager.service` - Declares dependency
- `Before=network-online.target` - Runs before network online state

**captive-portal.service**:
- `After=device-provisioning.service` - Starts after provisioning manager
- `BindsTo=device-provisioning.service` - Stops if provisioning manager stops

### Service Management

```bash
# Check status
systemctl status device-provisioning.service
systemctl status captive-portal.service

# View logs
journalctl -u device-provisioning.service -f
journalctl -u captive-portal.service -f

# Restart services
systemctl restart device-provisioning.service

# Enable/disable
systemctl enable device-provisioning.service
systemctl disable device-provisioning.service
```

## Installation

### Prerequisites

- Ubuntu 24.04 LTS
- Wi-Fi hardware with AP mode support
- Root/sudo access
- Internet connection (for initial setup)

### Installation Script

```bash
cd /path/to/CI-OS
sudo ./scripts/provisioning/install-provisioning.sh
```

The script:
1. Installs dependencies (Python, NetworkManager, dnsmasq)
2. Configures Netplan with NetworkManager renderer
3. Installs provisioning scripts to `/usr/local/bin/`
4. Creates required directories
5. Installs and enables systemd services
6. Configures firewall (if UFW installed)
7. Starts services

### Manual Installation

```bash
# Install dependencies
sudo apt install python3 python3-dbus python3-gi network-manager dnsmasq curl netplan.io

# Copy configuration
sudo cp configs/network/01-netcfg.yaml /etc/netplan/
sudo netplan apply

# Copy scripts
sudo cp scripts/provisioning/provisioning_manager.py /usr/local/bin/
sudo cp scripts/provisioning/captive_portal.py /usr/local/bin/
sudo chmod +x /usr/local/bin/provisioning_manager.py
sudo chmod +x /usr/local/bin/captive_portal.py

# Install systemd services
sudo cp configs/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable device-provisioning.service captive-portal.service
sudo systemctl start device-provisioning.service captive-portal.service
```

## User Experience Flow

### Initial Setup

1. **Power On**: User powers on unconfigured device
2. **LED Indicator**: Status LED blinks (indicates Hotspot Mode)
3. **Network Discovery**: User opens Wi-Fi settings on phone
4. **Connect**: User sees `Setup-Device-XXXX` and connects
5. **Portal Launch**: Phone automatically opens captive portal
6. **Configuration**: User fills form:
   - Selects Wi-Fi network from dropdown
   - Enters Wi-Fi password
   - Enters 6-character pairing token (from account dashboard)
7. **Submit**: User clicks "Connect Device"
8. **Transition**: Device disconnects hotspot, connects to Wi-Fi
9. **Pairing**: Device authenticates with cloud
10. **Complete**: LED turns solid green, setup complete

### Reconfiguration

If user changes Wi-Fi password or moves device:

1. Device detects connection failure
2. Automatically reverts to Hotspot Mode
3. User reconnects and provides new credentials
4. Device reconnects to network

### Token Acquisition

On separate device (laptop/phone with cellular):

1. User logs into account dashboard
2. Navigates to "Add Device" section
3. Clicks "Generate Pairing Token"
4. Dashboard displays 6-character code (e.g., "TR9-7X2")
5. Code valid for 15 minutes
6. User enters code in captive portal

## Troubleshooting

### Common Issues

**Problem**: Device doesn't create hotspot
- **Check**: NetworkManager status: `systemctl status NetworkManager`
- **Check**: Provisioning manager logs: `journalctl -u device-provisioning.service`
- **Solution**: Restart provisioning: `systemctl restart device-provisioning.service`

**Problem**: Captive portal doesn't appear
- **Check**: Connected to correct SSID
- **Check**: Captive portal service running: `systemctl status captive-portal.service`
- **Solution**: Manually navigate to `http://10.42.0.1/config`

**Problem**: Wi-Fi connection fails after configuration
- **Check**: Correct password entered
- **Check**: Network in range and operational
- **View**: Provisioning logs for connection errors

**Problem**: Cloud pairing fails
- **Check**: Internet connectivity: `ping 8.8.8.8`
- **Check**: Token validity (not expired)
- **Check**: Cloud API status

### Debug Mode

Enable verbose logging:

```bash
# Edit service file
sudo systemctl edit device-provisioning.service

# Add:
[Service]
Environment=LOG_LEVEL=DEBUG

# Restart
sudo systemctl restart device-provisioning.service

# View detailed logs
journalctl -u device-provisioning.service -f
```

## File Locations

| Path | Purpose |
|------|---------|
| `/etc/netplan/01-ci-os-provisioning.yaml` | Network configuration |
| `/usr/local/bin/provisioning_manager.py` | Provisioning FSM daemon |
| `/usr/local/bin/captive_portal.py` | Captive portal web server |
| `/etc/systemd/system/device-provisioning.service` | Provisioning systemd service |
| `/etc/systemd/system/captive-portal.service` | Portal systemd service |
| `/etc/provisioning/config.json` | Device configuration (credentials, token) |
| `/run/provisioning/scan_results.json` | Cached Wi-Fi scan results |
| `/var/log/device-provisioning.log` | Provisioning manager logs |
| `/var/log/captive-portal.log` | Captive portal logs |
| `/etc/NetworkManager/dnsmasq-shared.d/captive.conf` | DNS hijacking config |

## Performance Characteristics

- **Boot to Hotspot**: ~30-45 seconds (if no network available)
- **Configuration Time**: 2-3 minutes (user input + connection)
- **Memory Usage**: 
  - Provisioning Manager: ~50-100 MB
  - Captive Portal: ~20-40 MB
- **CPU Usage**: Minimal (<5% on modern hardware)
- **Network Scan Time**: 3-5 seconds
- **Hotspot Range**: 50-100 meters (2.4 GHz)

## Future Enhancements

1. **Bluetooth Provisioning**: Alternative provisioning via BLE
2. **QR Code Setup**: Generate QR code with Wi-Fi credentials
3. **Multi-Language Support**: Localized captive portal
4. **Advanced Diagnostics**: Network speed testing, signal strength monitoring
5. **Mesh Networking**: Automatic mesh formation with multiple devices
6. **Offline Pairing**: Pairing without internet (local verification)
7. **Voice Guidance**: Audio feedback during setup process
8. **Mobile App**: Dedicated configuration app (alternative to captive portal)

## License

MIT License - See LICENSE.md for details

## References

1. [Netplan Documentation](https://netplan.io/reference)
2. [NetworkManager D-Bus API](https://networkmanager.dev/docs/api/latest/)
3. [Captive Portal Detection - Apple](https://support.apple.com/en-us/HT204497)
4. [Captive Portal Detection - Android](https://android.googlesource.com/platform/frameworks/base/+/master/services/core/java/com/android/server/connectivity/NetworkMonitor.java)
5. [RFC 8628 - OAuth 2.0 Device Authorization Grant](https://tools.ietf.org/html/rfc8628)
6. [systemd Service Units](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
