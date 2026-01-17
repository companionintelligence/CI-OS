# Headless First-Time Setup - Integration Guide

## Overview

This guide explains how to integrate the headless first-time WiFi setup system into the CI OS build process using Cubic.

## Integration Steps

### 1. Copy Headless Setup Files to ISO

During the Cubic customization process, copy the headless setup system into the chroot environment:

```bash
# In Cubic terminal (chroot environment)
cd /tmp
cp -r /path/to/ci-os/scripts/headless-setup ./
cd headless-setup
```

### 2. Run Installation Script

Execute the installation script within the Cubic chroot environment:

```bash
# Install the headless setup system
sudo ./install.sh
```

This will:
- Install required packages (Python, Flask, dnsmasq, NetworkManager)
- Copy scripts to system directories
- Install systemd service
- Configure automatic startup

### 3. Update CI OS Customization Script

Add the following to `configs/scripts/ci-os-customization.sh`:

```bash
#!/bin/bash
# ... existing content ...

echo "=== Installing Headless Setup System ==="

# Copy headless setup directory
cp -r /path/to/scripts/headless-setup /tmp/

# Run installation
cd /tmp/headless-setup
./install.sh

# Verify installation
if [ -f /usr/local/bin/ci-os-headless-setup.sh ]; then
    echo "✓ Headless setup installed successfully"
else
    echo "✗ Headless setup installation failed"
    exit 1
fi

# Ensure service is enabled for first boot
systemctl enable ci-os-headless-setup.service

echo "=== Headless Setup System Installed ==="
```

### 4. Verify in Cubic

Before generating the ISO, verify the installation:

```bash
# Check files are in place
ls -la /usr/local/bin/ci-os-headless-setup.sh
ls -la /usr/local/share/ci-os-headless-setup/
ls -la /etc/systemd/system/ci-os-headless-setup.service

# Check service is enabled
systemctl is-enabled ci-os-headless-setup.service

# Run test script
cd /tmp/headless-setup
./test-headless-setup.sh
```

### 5. Generate ISO

After verification, proceed with Cubic ISO generation as normal.

## Post-Installation Behavior

### First Boot

When a user boots CI OS for the first time:

1. System starts normally
2. `ci-os-headless-setup.service` starts automatically
3. Service checks if WiFi is configured
4. If no WiFi: Creates hotspot and launches captive portal
5. If WiFi exists: Marks setup as complete and exits

### Subsequent Boots

On subsequent boots:
- Setup service checks for `/var/lib/ci-os/setup-complete`
- If flag exists: Service exits immediately (no overhead)
- If flag missing: Setup process runs again

## Testing the Integration

### In Virtual Machine

1. **Build ISO** with headless setup integrated
2. **Create VM** with WiFi adapter passthrough
3. **Boot ISO** in VM
4. **Wait 60 seconds** for hotspot to appear
5. **Connect to "CI-OS-Setup"** from another device
6. **Test captive portal** workflow

### On Physical Hardware

1. **Prepare bootable USB** with custom ISO
2. **Boot on device with WiFi**
3. **Remove all WiFi configurations** (for testing)
4. **Reboot** to trigger setup
5. **Complete setup** via captive portal

## Customization for CI OS

### Branding

Update captive portal branding in `web/captive-portal.py`:

```python
PORTAL_TEMPLATE = """
<!DOCTYPE html>
...
<div class="logo">
    <h1>🖥️ CI OS</h1>  <!-- Update this -->
    <p>First-Time Setup</p>
</div>
...
"""
```

### Logo Integration

To add CI OS logo to the captive portal:

1. Copy logo to `/usr/share/pixmaps/ci-os-logo.png` in Cubic
2. Update `PORTAL_TEMPLATE` to reference the logo:

```html
<div class="logo">
    <img src="/static/logo.png" alt="CI OS" style="max-width: 200px;">
    <h1>CI OS</h1>
    <p>First-Time Setup</p>
</div>
```

3. Add Flask static file serving in `captive-portal.py`

### Custom Hotspot SSID

To use a custom SSID (e.g., including device serial number):

Edit `/usr/local/bin/ci-os-headless-setup.sh`:

```bash
# Get device serial or hostname
DEVICE_ID=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || hostname)
HOTSPOT_SSID="CI-OS-${DEVICE_ID}"
```

## Package Requirements

The following packages must be included in CI OS:

### Required Packages

```bash
# Core networking
network-manager
wireless-tools
iw

# DNS and DHCP
dnsmasq

# Web server
python3
python3-pip
python3-flask

# Firewall
iptables

# System tools
systemd
```

### Python Dependencies

```bash
pip3 install flask
```

Or add to `configs/packages/python-packages.txt`:
```
flask>=2.0.0
```

## Directory Structure in ISO

After integration, the ISO should contain:

```
/usr/local/bin/
└── ci-os-headless-setup.sh

/usr/local/share/ci-os-headless-setup/
├── web/
│   └── captive-portal.py
└── lib/
    └── utils.sh

/etc/systemd/system/
└── ci-os-headless-setup.service

/var/lib/ci-os/
(created on first run)

/var/log/
(log file created on first run)
```

## Troubleshooting Integration

### Issue: Service doesn't start on first boot

**Solution:**
```bash
# In Cubic, verify service is enabled
systemctl is-enabled ci-os-headless-setup.service

# If not enabled:
systemctl enable ci-os-headless-setup.service
```

### Issue: Python script fails to run

**Solution:**
```bash
# Verify Python and Flask are installed
python3 --version
python3 -c "import flask; print(flask.__version__)"

# If Flask is missing:
pip3 install flask
```

### Issue: NetworkManager not available

**Solution:**
```bash
# Ensure NetworkManager is installed and enabled
apt install network-manager
systemctl enable NetworkManager
systemctl start NetworkManager
```

### Issue: WiFi hotspot won't create

**Solution:**
```bash
# Check if WiFi interface supports AP mode
iw list | grep "Supported interface modes" -A 8

# Look for "AP" in the output
# If not present, hardware doesn't support hotspot
```

## Security Considerations

### Production Deployment

For production deployments, consider:

1. **Add hotspot password** (optional, reduces convenience)
2. **Implement HTTPS** for captive portal (requires certificates)
3. **Rate limiting** on API endpoints
4. **Timeout** for setup process (auto-disable after X hours)
5. **Logging** of setup attempts

### Recommended Settings

```bash
# In ci-os-headless-setup.sh
HOTSPOT_TIMEOUT=3600  # 1 hour timeout
MAX_ATTEMPTS=5        # Maximum setup attempts
```

## Documentation for End Users

Include in CI OS user manual:

### Quick Start - Headless Setup

1. **Power on your CI OS device**
2. **Wait 1-2 minutes** for the setup WiFi to appear
3. **On your phone or laptop:**
   - Connect to WiFi network: **CI-OS-Setup**
   - Captive portal should open automatically
   - If not, open a web browser and visit any website
4. **In the setup portal:**
   - Enter your pairing code from setup.ci.computer
   - Select your WiFi network (or enter manually)
   - Enter your WiFi password
   - Click "Complete Setup"
5. **Wait for confirmation**
   - Your device will connect to your WiFi
   - Setup portal will confirm success
6. **Done!** Your CI OS device is now connected

## Maintenance

### Updating the Headless Setup System

To update in an existing CI OS installation:

```bash
# Download latest version
git clone https://github.com/companionintelligence/ci-os.git
cd ci-os/scripts/headless-setup

# Stop service
sudo systemctl stop ci-os-headless-setup.service

# Reinstall
sudo ./install.sh

# Restart service (if setup not complete)
sudo systemctl start ci-os-headless-setup.service
```

### Version Tracking

Add version number to scripts:

```bash
# In ci-os-headless-setup.sh
VERSION="1.0.0"
log "CI OS Headless Setup v${VERSION}"
```

## Future Enhancements

Consider for future versions:

- [ ] Bluetooth pairing as alternative
- [ ] QR code for WiFi credentials
- [ ] Multiple language support
- [ ] Setup wizard for additional configuration
- [ ] Remote diagnostics during setup
- [ ] Automatic troubleshooting
- [ ] Setup via ethernet with web UI

## Support

For issues with integration:

- Check Cubic logs
- Review systemd journal: `journalctl -u ci-os-headless-setup.service`
- Consult main README: `scripts/headless-setup/README.md`
- GitHub Issues: https://github.com/companionintelligence/ci-os/issues
