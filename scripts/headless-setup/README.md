# CI OS Headless First-Time Setup System

## Overview

The CI OS Headless Setup System provides a seamless, out-of-box experience for configuring WiFi and pairing CI OS devices without requiring a keyboard, mouse, or display. Similar to IoT devices and smart home gadgets, the system automatically creates a WiFi hotspot with a captive portal interface for easy configuration.

## How It Works

### 1. First Boot Detection

On first boot (or when no WiFi network is configured):
- The system detects that no WiFi connection exists
- Automatically starts the headless setup service
- Creates a temporary WiFi access point

### 2. WiFi Hotspot

The device broadcasts a WiFi network:
- **SSID**: `CI-OS-Setup`
- **Security**: Open (no password required)
- **IP Range**: 10.42.0.1/24
- **DHCP**: Enabled (10.42.0.10 - 10.42.0.100)

### 3. Captive Portal

When a user connects to the hotspot:
- **Automatic Redirect**: Most devices automatically detect the captive portal and open it
- **Manual Access**: Users can also navigate to any website (e.g., http://example.com)
- **Portal Interface**: Clean, mobile-friendly web interface for configuration

### 4. Configuration Process

The captive portal allows users to:
1. **Enter Pairing Code**: One-time code from setup.ci.computer
2. **Select WiFi Network**: Scan for available networks or enter manually
3. **Enter WiFi Password**: Secure password input
4. **Submit**: Automatic configuration and connection

### 5. Automatic Transition

After configuration:
- WiFi credentials are securely stored
- Device connects to the home WiFi network
- Hotspot is automatically disabled
- Device pairs with cloud account using pairing code
- Setup completion flag prevents re-running

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                    CI OS Headless Setup                      │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  ci-os-headless-setup.service (systemd)            │   │
│  │  - Runs on boot if setup not complete               │   │
│  │  - Creates WiFi hotspot                             │   │
│  │  - Manages DNS hijacking                            │   │
│  │  - Monitors for completion                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  ci-os-headless-setup.sh (main daemon)             │   │
│  │  - Hotspot creation (NetworkManager)                │   │
│  │  - DNS hijacking (dnsmasq)                          │   │
│  │  - Port forwarding (iptables)                       │   │
│  │  - Web server management                            │   │
│  │  - Cleanup and transition                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  captive-portal.py (Flask web server)              │   │
│  │  - Serves captive portal UI                         │   │
│  │  - WiFi network scanning                            │   │
│  │  - Configuration processing                         │   │
│  │  - WiFi connection (nmcli)                          │   │
│  │  - Cloud pairing API                                │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### File Structure

```
scripts/headless-setup/
├── ci-os-headless-setup.sh       # Main daemon script
├── install.sh                     # Installation script
├── web/
│   └── captive-portal.py         # Flask web server
├── lib/
│   └── utils.sh                  # Utility functions
├── systemd/
│   └── ci-os-headless-setup.service  # Systemd service file
└── README.md                      # This file

Installation locations:
/usr/local/bin/
└── ci-os-headless-setup.sh       # Main executable

/usr/local/share/ci-os-headless-setup/
├── web/
│   └── captive-portal.py
└── lib/
    └── utils.sh

/etc/systemd/system/
└── ci-os-headless-setup.service

/var/lib/ci-os/
├── setup-complete                # Flag file (setup done)
└── setup-config.json             # Configuration data

/var/log/
└── ci-os-headless-setup.log      # Log file
```

## Installation

### Automated Installation (Recommended)

```bash
cd scripts/headless-setup
sudo ./install.sh
```

### Manual Installation

```bash
# Install dependencies
sudo apt-get install python3 python3-flask dnsmasq iptables network-manager

# Copy files
sudo cp ci-os-headless-setup.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/ci-os-headless-setup.sh

sudo mkdir -p /usr/local/share/ci-os-headless-setup/web
sudo cp web/captive-portal.py /usr/local/share/ci-os-headless-setup/web/
sudo chmod +x /usr/local/share/ci-os-headless-setup/web/captive-portal.py

# Install systemd service
sudo cp systemd/ci-os-headless-setup.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ci-os-headless-setup.service
```

### Integration with CI OS Build

Add to `configs/scripts/ci-os-customization.sh`:

```bash
# Install headless setup system
cd /tmp/headless-setup
./install.sh

# Ensure it runs on first boot
systemctl enable ci-os-headless-setup.service
```

## Usage

### For End Users

1. **Power on the CI OS device**
2. **Wait 30-60 seconds** for the hotspot to appear
3. **Connect to WiFi network**: `CI-OS-Setup`
4. **Captive portal opens automatically** (or navigate to any website)
5. **Enter your pairing code** from setup.ci.computer
6. **Select your WiFi network** from the scanned list
7. **Enter WiFi password** and click "Complete Setup"
8. **Wait for confirmation** - device will connect to your network

### For Administrators

#### Check Setup Status

```bash
# Check if setup is complete
ls -la /var/lib/ci-os/setup-complete

# View setup logs
sudo journalctl -u ci-os-headless-setup.service -f
sudo tail -f /var/log/ci-os-headless-setup.log
```

#### Manual Testing

```bash
# Reset setup for testing
sudo rm -f /var/lib/ci-os/setup-complete

# Start setup service manually
sudo systemctl start ci-os-headless-setup.service

# Check service status
sudo systemctl status ci-os-headless-setup.service
```

#### Troubleshooting

```bash
# Check NetworkManager status
sudo systemctl status NetworkManager

# Check dnsmasq status
sudo systemctl status dnsmasq

# View active connections
nmcli connection show

# View WiFi networks
nmcli device wifi list

# Check iptables rules
sudo iptables -t nat -L -n -v
```

## Security Considerations

### Network Security

- **Open Hotspot**: The setup hotspot is intentionally open (no password) for ease of use
- **Time-Limited**: Hotspot only runs until setup is complete
- **Local Only**: All configuration happens locally on the device
- **Encrypted Storage**: WiFi passwords stored securely by NetworkManager

### Best Practices

1. **Physical Security**: Only run setup in a trusted environment
2. **Quick Setup**: Complete setup promptly to minimize exposure
3. **Unique Pairing Codes**: Each device requires a unique pairing code
4. **HTTPS (Future)**: Consider adding SSL/TLS for the captive portal

## Cloud Pairing

### Pairing Code Flow

1. User creates account at **setup.ci.computer**
2. System generates unique pairing code (e.g., `X25-RJ8`)
3. User enters code during device setup
4. Device sends pairing request to cloud API
5. Account linked to device by device ID

### API Integration (To Be Implemented)

```python
def perform_cloud_pairing(pairing_code):
    response = requests.post(
        'https://setup.ci.computer/api/pair',
        json={
            'pairing_code': pairing_code,
            'device_id': get_device_id(),
            'device_name': get_device_hostname()
        },
        timeout=10
    )
    return response.status_code == 200
```

## Supported Platforms

### Operating Systems

- **Primary**: Ubuntu 24.04 LTS (amd64)
- **Base**: Any Ubuntu/Debian-based system with NetworkManager

### Tested Devices

- **Desktop/Laptop**: x86_64 systems with WiFi
- **Single-Board Computers**: Raspberry Pi 4, similar SBCs
- **Virtual Machines**: Testing only (requires WiFi passthrough)

### WiFi Hardware

- Devices with standard WiFi adapters supported by Linux
- AP mode support required (most modern WiFi cards)
- Check compatibility: `iw list | grep "Supported interface modes" -A 8`

## Captive Portal Detection

### Supported Platforms

The captive portal is detected automatically on:

- **iOS/iPadOS**: Uses `hotspot-detect.html`
- **Android**: Uses `generate_204` endpoint
- **Windows**: Uses `connecttest.txt` endpoint
- **macOS**: Uses `hotspot-detect.html` (same as iOS)
- **Linux**: Varies by distribution

### Manual Access

If automatic detection fails, users can manually navigate to:
- `http://10.42.0.1`
- Any HTTP website (e.g., `http://example.com`)

## Customization

### Change Hotspot SSID

Edit `ci-os-headless-setup.sh`:

```bash
HOTSPOT_SSID="MyDevice-Setup"
```

### Change Hotspot Password

To add password protection:

```bash
nmcli connection add type wifi ifname "$HOTSPOT_INTERFACE" \
    con-name "$HOTSPOT_SSID" \
    autoconnect yes \
    ssid "$HOTSPOT_SSID" \
    mode ap \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "YourPassword123" \
    ipv4.method shared \
    ipv4.addresses "$HOTSPOT_IP/24"
```

### Customize Web Interface

Edit `web/captive-portal.py` to modify:
- Portal design (CSS in `PORTAL_TEMPLATE`)
- Branding and logos
- Text and instructions
- Additional form fields

## Testing

### Unit Testing

```bash
# Test WiFi scanning
sudo python3 -c "from web.captive_portal import scan_networks; print(scan_networks())"

# Test NetworkManager
nmcli device wifi list
```

### Integration Testing

```bash
# Full workflow test
sudo rm -f /var/lib/ci-os/setup-complete
sudo systemctl restart ci-os-headless-setup.service

# Connect from another device
# - Join "CI-OS-Setup" network
# - Open browser (captive portal should appear)
# - Complete setup form
# - Verify WiFi connection
```

### Automated Testing

```bash
# Reset setup
sudo rm -f /var/lib/ci-os/setup-complete

# Start service
sudo systemctl start ci-os-headless-setup.service

# Wait for hotspot
sleep 10

# Verify hotspot exists
nmcli connection show | grep "CI-OS-Setup"

# Check web server is running
curl -I http://10.42.0.1

# Cleanup
sudo systemctl stop ci-os-headless-setup.service
```

## Known Limitations

1. **Single WiFi Interface**: Requires dedicated WiFi adapter for hotspot
2. **No Concurrent Mode**: Cannot be hotspot and client simultaneously (most hardware)
3. **HTTP Only**: Captive portal uses HTTP (HTTPS requires valid certificates)
4. **Limited Browser**: Captive portal browsers have reduced functionality
5. **Network Dependency**: Requires NetworkManager (not compatible with netplan alone)

## Future Enhancements

- [ ] HTTPS support with self-signed certificates
- [ ] Bluetooth pairing as alternative to WiFi
- [ ] Multi-language support
- [ ] QR code scanning for WiFi credentials
- [ ] Ethernet fallback option
- [ ] Progress indicators for long operations
- [ ] Detailed error messages and troubleshooting
- [ ] Configuration backup and restore
- [ ] Remote management capabilities

## Contributing

Contributions are welcome! Areas for improvement:

- Better error handling
- Additional WiFi hardware support
- UI/UX improvements
- Security enhancements
- Documentation updates

## License

Part of CI OS - See main project license

## Support

- **GitHub Issues**: https://github.com/companionintelligence/ci-os/issues
- **Documentation**: https://github.com/companionintelligence/ci-os/wiki
- **Logs**: `/var/log/ci-os-headless-setup.log`

## Acknowledgments

- NetworkManager for robust network management
- Flask for the web server framework
- dnsmasq for DNS and DHCP services
- The Ubuntu/Debian community for excellent documentation
