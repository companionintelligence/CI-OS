# Quick Start: WiFi Setup Guide

## Device: Mediatek MT7925 WiFi 6

### What Happens on Boot

```
Device powers on without network connection
        ↓
Companion-Setup hotspot broadcasts
(Available immediately - usually within 5-10 seconds)
        ↓
You connect from phone/laptop
        ↓
Captive portal auto-opens on 192.168.99.1
        ↓
You enter setup form and submit
        ↓
Device connects to your WiFi network
        ↓
Setup services stop (hotspot disappears)
```

## Quick Setup (5 minutes)

### Step 1: Find the Hotspot
Look for WiFi network: **Companion-Setup**
- Password: **SetupDevice123**

### Step 2: Connect
Connect from your phone or computer to the hotspot.

### Step 3: Enter Setup Form
The captive portal should auto-open. If not, go to: **http://192.168.99.1**

Form fields:
- **Pairing Code**: Enter `abc-123` (test code) OR device-specific code
- **WiFi Network**: Select your WiFi network (or type manually)
- **WiFi Password**: Enter your WiFi password
- **Submit**: Click to configure

### Step 4: Wait for Connection
Device will:
1. Create WiFi connection
2. Connect to your network
3. Disable setup hotspot
4. Be ready to use

The setup hotspot will disappear once connection succeeds.

## Test Code

**For Development/Testing**: Use `abc-123`
- Always valid (no expiry)
- Case-insensitive: `abc-123`, `ABC-123`, `AbC-123` all work
- No hyphens needed: `abc123` works too

## Device-Generated Code

**For Production**: The device generates a unique code
```bash
# View the generated code (on the device):
sudo cat /etc/setup-device/pairing_code.json
```
- Expires after 24 hours
- Different each boot
- More secure than test code

## Network Details

| Setting | Value |
|---------|-------|
| **Hotspot SSID** | Companion-Setup |
| **Gateway IP** | 192.168.99.1 |
| **Portal URL** | http://192.168.99.1 |
| **DHCP Range** | 192.168.99.10 - 192.168.99.250 |
| **Hotspot Password** | SetupDevice123 |

## Troubleshooting

### Hotspot Not Showing
```bash
# Check if services are running (on device):
sudo systemctl status hostapd-setup.service
```
Wait 10-15 seconds after device boot.

### Can't Reach Portal
```bash
# From connected device, try:
ping 192.168.99.1
curl http://192.168.99.1
```

### Stuck on "Connecting to WiFi"
1. Check WiFi password is correct
2. Check WiFi network is in range
3. Check network doesn't require captive portal

### Portal Times Out After Form Submit
The device is connecting to WiFi. This is normal.
Setup hotspot will disappear once connected.

## Need Help?

See detailed docs:
- [INSTALL.md](INSTALL.md) - Full installation guide
- [README.md](README.md) - Architecture and service management
- [WIFI_CHIP_INFO.md](WIFI_CHIP_INFO.md) - Hardware details and specs
