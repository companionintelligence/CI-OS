# Quick Start Guide: Headless Wi-Fi Provisioning

## For System Administrators

### Installation (One-Time Setup)

1. **Install the provisioning system on your Ubuntu 24.04 device:**

```bash
cd /path/to/CI-OS
sudo ./scripts/provisioning/install-provisioning.sh
```

2. **Reboot the device:**

```bash
sudo reboot
```

That's it! The device is now ready for headless provisioning.

---

## For End Users

### First-Time Device Setup

1. **Power on the device**
   - Wait 30-45 seconds for the device to boot
   - The device will automatically create a Wi-Fi hotspot

2. **Connect your phone to the device's hotspot**
   - Open Wi-Fi settings on your phone
   - Look for network: `Setup-Device-XXXX` (XXXX = last 4 digits of device MAC)
   - Connect to this network
   - Password (if required): `ci-os-setup`

3. **Configuration page should open automatically**
   - Your phone should automatically open the configuration page
   - If not, open a browser and go to: `http://10.42.0.1/config`

4. **Configure the device**
   - **Select Wi-Fi Network**: Choose your home/office Wi-Fi from the dropdown
   - **Enter Password**: Type your Wi-Fi password
   - **Pairing Token**: Enter the 6-character code (see below)
   - Click "Connect Device"

5. **Get your pairing token**
   - On a separate device with internet:
     - Log into your account dashboard
     - Navigate to "Devices" → "Add New Device"
     - Click "Generate Pairing Token"
     - You'll receive a 6-character code (e.g., "TR9-7X2")
     - This code expires in 15 minutes
   - Enter this code in the configuration form

6. **Wait for connection**
   - The device will disconnect from the setup network
   - It will connect to your Wi-Fi network
   - It will authenticate with the cloud
   - Setup complete! (Usually takes 1-2 minutes)

### Visual Guide

```
┌─────────────────┐
│  Power On       │
│  Device         │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Wait 30-45s    │
│  (Booting)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Device Creates │
│  Hotspot        │
│  "Setup-Device" │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Connect Phone  │
│  to Hotspot     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Portal Opens   │
│  Automatically  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Fill Form:     │
│  - Wi-Fi SSID   │
│  - Password     │
│  - Token (6ch)  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Submit Form    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Device         │
│  Connects to    │
│  Wi-Fi & Cloud  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  ✅ Complete!   │
└─────────────────┘
```

---

## Troubleshooting

### The captive portal doesn't open automatically

**Solution**: Manually open a browser and navigate to:
```
http://10.42.0.1/config
```

### I can't find my Wi-Fi network in the list

**Solution**: Click the "🔄 Rescan Networks" button
- Note: This will temporarily disconnect you from the setup network
- Reconnect and the updated list will appear

### Connection failed after entering credentials

**Possible causes**:
1. **Wrong password** - Try again with the correct password
2. **Network out of range** - Move device closer to router
3. **Network not available** - Check if your Wi-Fi router is working

**Solution**: 
- The device will automatically return to hotspot mode
- Reconnect and try again

### Pairing token error

**Possible causes**:
1. **Token expired** - Tokens are only valid for 15 minutes
2. **Wrong token** - Double-check the code
3. **Token already used** - Generate a new token

**Solution**: 
- Generate a new pairing token from your dashboard
- Enter the new token

### Device doesn't create a hotspot

**For administrators**:
1. Check if services are running:
   ```bash
   systemctl status device-provisioning.service
   systemctl status captive-portal.service
   ```

2. Check logs:
   ```bash
   journalctl -u device-provisioning.service -f
   ```

3. Restart services:
   ```bash
   sudo systemctl restart device-provisioning.service
   sudo systemctl restart captive-portal.service
   ```

---

## Reconfiguration

### Moving the device to a new network

1. **Disconnect from current network**:
   - The easiest way is to move the device out of range of the current network
   - Or change your Wi-Fi password

2. **Device auto-recovery**:
   - The device detects it can't connect
   - Automatically creates the setup hotspot again
   - Follow the setup steps again with new credentials

### Forgot to get a pairing token?

Don't worry! You can still configure Wi-Fi first:
1. Leave the "Pairing Token" field empty or use a dummy value
2. Device will connect to Wi-Fi but won't pair with cloud
3. You can pair later through the dashboard or SSH into the device

---

## Advanced Usage

### Manual Portal Access

Even when connected to the hotspot, you can always access the portal at:
```
http://10.42.0.1/config
```

### Check Available Networks API

```bash
curl http://10.42.0.1/api/networks
```

Returns JSON with available networks and signal strength.

### Service Management (Administrators)

```bash
# Check status
systemctl status device-provisioning.service

# View live logs
journalctl -u device-provisioning.service -f

# Restart service
sudo systemctl restart device-provisioning.service

# Disable auto-provisioning
sudo systemctl disable device-provisioning.service
```

---

## Security Notes

### For Users

- The setup hotspot may be **open** (no password) or **password-protected**
- Your Wi-Fi credentials are only transmitted once during setup
- The pairing token is single-use and expires quickly
- All cloud communication uses HTTPS encryption

### For Administrators

- Consider using WPA2-PSK for the setup hotspot (more secure)
- Setup hotspot automatically shuts down after successful configuration
- Wi-Fi passwords are stored encrypted in `/etc/provisioning/config.json`
- Implement firewall rules to restrict access during provisioning

---

## FAQ

**Q: How long does setup take?**
A: Usually 2-3 minutes from start to finish.

**Q: Do I need internet during setup?**
A: You need internet to generate the pairing token and for the device to complete cloud pairing. However, Wi-Fi configuration can work offline.

**Q: Can I set up multiple devices at once?**
A: Yes! Each device creates its own unique hotspot (different MAC suffix).

**Q: What if I enter the wrong Wi-Fi password?**
A: The device will fail to connect and automatically return to hotspot mode. Reconnect and try again.

**Q: Can I use this with a hidden Wi-Fi network?**
A: Not through the captive portal (hidden networks don't appear in scans). You'll need to configure manually via SSH or use a non-hidden network initially.

**Q: Does this work with 5GHz Wi-Fi?**
A: Yes for connecting TO 5GHz networks. However, the setup hotspot uses 2.4GHz for maximum compatibility.

**Q: What happens if power is lost during setup?**
A: No problem! The device will restart and enter hotspot mode again. Just repeat the setup.

---

## System Requirements

### Device Requirements
- Ubuntu 24.04 LTS
- Wi-Fi adapter with AP mode support
- Minimum 512MB RAM
- Network connectivity (Ethernet or Wi-Fi)

### User Requirements (Phone/Laptop)
- Wi-Fi capability
- Modern browser (Chrome, Safari, Firefox, Edge)
- Internet access (to generate pairing token)

---

## Getting Help

- **Documentation**: See `/docs/provisioning/wifi-provisioning-architecture.md`
- **Logs**: `journalctl -u device-provisioning.service -f`
- **Support**: Contact system administrator or see project issues

---

## Quick Reference

| Item | Value |
|------|-------|
| Hotspot SSID | `Setup-Device-XXXX` |
| Hotspot Password | `ci-os-setup` (if enabled) |
| Portal URL | `http://10.42.0.1/config` |
| Gateway IP | `10.42.0.1` |
| DHCP Range | `10.42.0.2` - `10.42.0.254` |
| Token Length | 6 characters (A-Z, 0-9) |
| Token Validity | 15 minutes |
| Setup Time | 2-3 minutes |

---

**Last Updated**: 2026-01-17
**Version**: 1.0.0
