# Setup Device - AP Mode Manual Setup Guide

**Use this guide when disconnected from WiFi/Ethernet to manually start AP (Access Point) mode.**

## Prerequisites
- Device is powered on but disconnected from all networks (WiFi + Ethernet)
- You can access the device via local console or SSH (if still connected)
- All setup-device package files are installed

## Step-by-Step AP Mode Activation

### Step 1: Disconnect from WiFi
```bash
sudo nmcli device disconnect wlp192s0
```
This disconnects the interface from any connected WiFi network.

### Step 2: Wait for Network Monitor to Detect (Automatic)
The `setup-network-monitor.service` will detect loss of connectivity after ~30 seconds and automatically start the hotspot. 

**To check if monitor detected it:**
```bash
sudo journalctl -u setup-network-monitor.service -n 5 --no-pager
```
Look for message: `Lost connectivity` or `Starting hotspot services`

### Step 3: If Auto-Detection Fails - Manual Startup

If the hotspot doesn't start automatically after 1 minute, manually start it:

#### 3a. Copy config files (if missing)
```bash
sudo cp /home/companion/devel/companion/CI-OS/setup/headless/setup-device/etc/hostapd/hostapd-setup.conf /etc/hostapd/
sudo cp /home/companion/devel/companion/CI-OS/setup/headless/setup-device/etc/dnsmasq.d/setup-portal.conf /etc/dnsmasq.d/
```

#### 3b. Disconnect interface from any existing connections
```bash
sudo ip link set wlp192s0 down
sudo ip addr flush dev wlp192s0
sudo ip link set wlp192s0 up
```

#### 3c. Assign static IP to interface
```bash
sudo ip addr add 192.168.99.1/24 dev wlp192s0
```

#### 3d. Start hotspot services (in order)
```bash
sudo systemctl start hostapd-setup.service
sleep 2
sudo systemctl start dnsmasq-setup.service
```

#### 3e. Verify services are running
```bash
sudo systemctl status hostapd-setup.service
sudo systemctl status dnsmasq-setup.service
```
Both should show: `Active: active (running)`

### Step 4: Verify WiFi Network is Broadcasting

From another device (phone, laptop, tablet):
1. Open WiFi settings
2. Look for network named: **`Companion-Setup`**
3. Password: **`SetupDevice123`**

If you don't see the network:
```bash
sudo journalctl -u hostapd-setup.service -n 10 --no-pager
```
Check for errors in the logs.

### Step 5: Connect and Access Setup Portal

From the device that can see `Companion-Setup`:

1. **Connect to WiFi:**
   - Network: `Companion-Setup`
   - Password: `SetupDevice123`
   - IP will auto-assign via DHCP (192.168.99.0/24)

2. **Open setup portal** (choose one):
   - **HTTPS (Recommended)**: `https://setup.ci.computer`
   - **HTTPS (by IP)**: `https://192.168.99.1`
   - **HTTP (will redirect)**: `http://192.168.99.1` → redirects to HTTPS

3. **Browser warning:**
   - Self-signed certificate warning is NORMAL
   - Click "Advanced" → "Proceed to setup.ci.computer"

### Step 6: Complete Setup Form

Fill in the form:

1. **Pairing Code:** (check device logs for generated code)
   ```bash
   cat /etc/setup-device/pairing_code.json | grep '"code"'
   ```
   - Format accepted: `ABC-123`, `ABC123`, `ABC 123`, or lowercase

2. **WiFi Network:**
   - Click **Scan** to list available networks
   - Or select **"Enter network manually..."** for hidden networks

3. **WiFi Password:**
   - Leave blank for open networks
   - Enter password for secured networks

4. **Click Configure**

### Step 7: Verify Setup Success

Device will:
1. Connect to your home WiFi network
2. Write `/var/lib/setup-device/setup-complete` flag
3. Stop hotspot services automatically
4. Network monitor exits

**Check completion:**
```bash
ls -la /var/lib/setup-device/setup-complete
```
If file exists, setup is complete!

## Troubleshooting

### WiFi Network Not Appearing
**Check hostapd status:**
```bash
sudo systemctl status hostapd-setup.service --no-pager
sudo journalctl -u hostapd-setup.service -n 20 --no-pager
```

**Restart hotspot:**
```bash
sudo systemctl stop hostapd-setup.service dnsmasq-setup.service
sleep 2
sudo systemctl start hostapd-setup.service
sleep 2
sudo systemctl start dnsmasq-setup.service
```

### Can't Connect to Portal
**Check interface IP:**
```bash
ip addr show wlp192s0
```
Should show: `inet 192.168.99.1/24`

**Check dnsmasq:**
```bash
sudo systemctl status dnsmasq-setup.service --no-pager
sudo journalctl -u dnsmasq-setup.service -n 10 --no-pager
```

**Check nginx:**
```bash
sudo systemctl status nginx.service --no-pager
curl -sk https://setup.ci.computer/ | head -20
```

### Backend API Not Responding
**Check backend:**
```bash
sudo systemctl status setup-backend.service --no-pager
curl http://127.0.0.1:5000/api/status
```

**Restart:**
```bash
sudo systemctl restart setup-backend.service
```

### Monitor Not Auto-Starting Hotspot
**Check monitor service:**
```bash
sudo systemctl status setup-network-monitor.service --no-pager
sudo journalctl -u setup-network-monitor.service -n 20 --no-pager
```

**Check connectivity detection:**
```bash
ip route
```
If no `default` route shows, monitor should start hotspot after 30 seconds.

## Reset / Start Over

If you need to restart the entire process:

```bash
# Remove setup-complete flag
sudo rm -f /var/lib/setup-device/setup-complete

# Restart all services
sudo systemctl restart setup-network-monitor.service
sudo systemctl restart nginx.service
sudo systemctl restart setup-backend.service

# Wait ~30 seconds, then hotspot should auto-start if disconnected
```

## Service Dependencies

```
setup-network-monitor.service (monitors connectivity)
  ↓
  └─→ hostapd-setup.service (broadcasts WiFi AP)
       └─→ dnsmasq-setup.service (DHCP + DNS)
            ↓
  setup-backend.service (Flask API)
  nginx.service (Web server + reverse proxy)
```

All services auto-start on boot if `setup-complete` doesn't exist.

## File Locations

- **Config files:** `/etc/hostapd/`, `/etc/dnsmasq.d/`, `/etc/nginx/`
- **SSL certs:** `/etc/nginx/ssl/setup-device.{crt,key}`
- **Setup flag:** `/var/lib/setup-device/setup-complete`
- **Pairing code:** `/etc/setup-device/pairing_code.json`
- **Backend script:** `/opt/setup-backend/setup_service.py`
- **Monitor script:** `/usr/local/bin/setup-network-monitor.sh`
- **Portal files:** `/var/www/setup-portal/index.html`

## Key Commands Reference

```bash
# Check all services
sudo systemctl status setup-backend.service nginx.service hostapd-setup.service dnsmasq-setup.service setup-network-monitor.service

# View logs
sudo journalctl -u hostapd-setup.service -n 20 --no-pager
sudo journalctl -u setup-network-monitor.service -n 20 --no-pager

# Check WiFi status
iwconfig wlp192s0
ip addr show wlp192s0

# Test connectivity
ip route  # Should show "default" when connected to router

# Get pairing code
cat /etc/setup-device/pairing_code.json

# Test portal
curl -sk https://setup.ci.computer/
curl http://127.0.0.1:5000/api/status
```

---

**Expected Timeline:**
- Power on → Services start
- Disconnect WiFi/Ethernet → Network monitor running
- ~30 seconds → Hotspot auto-starts (if disconnected)
- Connect to `Companion-Setup` → Portal accessible
- Complete form → Setup finishes, hotspot stops
- ~Total: 2-3 minutes for full setup
