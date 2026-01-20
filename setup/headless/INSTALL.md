# Installation and Usage Guide

## Prerequisites

- Ubuntu Server (or Debian-based Linux)
- Root/sudo access
- WiFi adapter (wlan0)
- Required packages will be installed automatically via dependencies

## Step 1: Transfer Files to Linux Machine

If you're building on a different machine, transfer the `setup/headless/` directory to your Linux machine:

```bash
# From your Mac/Windows machine, copy the directory
scp -r setup/headless user@linux-machine:/path/to/destination/

# Or use git if the repo is available
git clone <repo-url>
cd CI-OS/setup/headless
```

## Step 2: Install Build Tools

On the Linux machine, ensure you have `dpkg-deb`:

```bash
sudo apt update
sudo apt install -y dpkg-dev
```

## Step 3: Build the Package

```bash
cd /path/to/setup/headless
chmod +x build.sh
./build.sh
```

This will create: `setup-device_1.0.0_amd64.deb`

## Step 4: Install the Package

```bash
sudo dpkg -i setup-device_1.0.0_amd64.deb
```

If there are dependency issues, fix them:

```bash
sudo apt-get install -f
```

## Step 5: Verify Installation

Check that services are enabled and running:

```bash
# Check service status
systemctl status setup-backend.service
systemctl status hostapd-setup.service
systemctl status dnsmasq-setup.service
systemctl status nginx.service

# Check if services are enabled for boot
systemctl is-enabled setup-backend.service
systemctl is-enabled hostapd-setup.service
systemctl is-enabled dnsmasq-setup.service
```

## Step 6: Get Pairing Code

```bash
# View pairing code (requires sudo)
sudo cat /etc/setup-device/pairing_code.json | grep -o '"code": "[^"]*"' | cut -d'"' -f4

# Or view full JSON
sudo cat /etc/setup-device/pairing_code.json
```

## Step 7: Connect to Setup Hotspot

1. Look for WiFi network: `Setup-Device-XXXX` (password: `SetupDevice123`)
2. Connect from your phone/computer
3. Captive portal should auto-launch, or navigate to: http://192.168.99.1

## Step 8: Configure WiFi

1. Enter the pairing code (from Step 6)
2. Enter WiFi network SSID (or it will be detected automatically)
3. Enter WiFi password
4. Submit the form

The device will:
- Create NetworkManager connection
- Connect to your WiFi
- Stop the hotspot services
- Mark setup as complete

## Step 9: Verify Setup Complete

```bash
# Check if setup is complete
test -f /var/lib/setup-device/setup-complete && echo "Setup complete" || echo "Setup not complete"

# Check WiFi connection
nmcli connection show --active

# Verify hotspot services are stopped
systemctl status hostapd-setup.service  # Should show inactive
systemctl status dnsmasq-setup.service  # Should show inactive
```

## Troubleshooting

### Services Not Starting

```bash
# Check logs
journalctl -u setup-backend.service -n 50
journalctl -u hostapd-setup.service -n 50
journalctl -u dnsmasq-setup.service -n 50

# Check backend log file
sudo tail -f /var/log/setup-backend.log

# Reload systemd
sudo systemctl daemon-reload
```

### Hotspot Not Appearing

```bash
# Check if wlan0 exists
ip link show wlan0

# Check hostapd status
systemctl status hostapd-setup.service

# Check hostapd config
sudo cat /etc/hostapd/hostapd-setup.conf

# Manually test hostapd
sudo hostapd /etc/hostapd/hostapd-setup.conf
```

### Netplan Issues

```bash
# Check netplan config
cat /etc/netplan/50-setup-mode.yaml

# Apply netplan
sudo netplan apply

# Check network status
ip addr show wlan0
```

### Portal Not Accessible

```bash
# Check nginx status
systemctl status nginx.service

# Check nginx config
sudo nginx -t

# Check if site is enabled
ls -la /etc/nginx/sites-enabled/

# Test nginx
curl http://192.168.99.1
```

### Pairing Code Issues

```bash
# Regenerate pairing code (backend will do this automatically if expired)
sudo rm /etc/setup-device/pairing_code.json
sudo systemctl restart setup-backend.service

# Check pairing code
sudo cat /etc/setup-device/pairing_code.json
```

### Reset Setup (Start Over)

```bash
# Remove setup-complete flag
sudo rm /var/lib/setup-device/setup-complete

# Restart services
sudo systemctl restart hostapd-setup.service
sudo systemctl restart dnsmasq-setup.service
```

## Uninstallation

```bash
sudo dpkg -r setup-device
```

This will:
- Stop all services
- Disable services from boot
- Remove configuration files
- Restore wlan0 to DHCP

## Manual Testing

### Test Backend API Directly

```bash
# Health check
curl http://127.0.0.1:5000/health

# Status
curl http://127.0.0.1:5000/api/status

# Scan networks (requires WiFi adapter)
curl http://127.0.0.1:5000/api/scan-networks
```

### Test Form Submission

```bash
# Get pairing code first
PAIRING_CODE=$(sudo cat /etc/setup-device/pairing_code.json | grep -o '"code": "[^"]*"' | cut -d'"' -f4)

# Submit configuration
curl -X POST http://192.168.99.1/api/configure \
  -d "pairing_code=$PAIRING_CODE" \
  -d "ssid=YourWiFiNetwork" \
  -d "password=YourPassword"
```

## Next Boot Behavior

After setup is complete:
- Hotspot services (`hostapd-setup`, `dnsmasq-setup`) will NOT start (gated by `setup-complete` file)
- Backend service will start but remain idle
- Device will connect to configured WiFi automatically
- Setup portal will not be accessible

To reset and start setup again, remove the `/var/lib/setup-device/setup-complete` file.
