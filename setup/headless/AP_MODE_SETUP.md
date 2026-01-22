# Setup Device - AP Mode Manual Setup Guide

**Use this guide when disconnected from WiFi/Ethernet to manually start AP (Access Point) mode.**

## Prerequisites
- Device is powered on and has no active wired or wireless connections
- Both Ethernet and WiFi interfaces must be disconnected
- You can access the device via local console or SSH (if still connected)
- All setup-device package files are installed

**Important:** The hotspot will automatically start when **both Ethernet AND WiFi are disconnected**. This is the trigger condition - when the device has no active network connections, it needs the hotspot to be configured.

## Step-by-Step AP Mode Activation

### Step 1: Check Device Connection Status

First, verify the current WiFi connection state:
```bash
# Check device status
nmcli device status

# Check for active connections
nmcli connection show --active
```

### Step 2: Disconnect WiFi (if currently connected)

If the device is already connected to a WiFi network, disconnect it:

```bash
# Disconnect from any WiFi network
sudo nmcli device disconnect wlp192s0
```

**If you get error "This device is not active":**
- This is normal if the device is already disconnected
- Proceed to Step 3 - hotspot will start automatically

**If connection fails to disconnect:**
```bash
# Alternative: Force disconnect
sudo nmcli connection down $(nmcli -t -f NAME connection show --active | head -1)
```

### Step 2: Wait for Network Monitor to Detect (Automatic - ~6 seconds)

The `setup-network-monitor.service` continuously monitors network connections and will automatically start the hotspot when:
- **Ethernet is disconnected (enp*, eth* devices show "disconnected")** AND
- **WiFi is disconnected (wlp* devices show "disconnected")**

The monitor checks every 3 seconds and starts the hotspot after ~6 seconds of detecting both interfaces disconnected (FAILURE_THRESHOLD=2 checks).

**This means:**
- ✅ Hotspot starts when both Ethernet and WiFi are disconnected
- ✅ Hotspot starts regardless of Docker bridges or other interfaces
- ❌ Hotspot does NOT start if Ethernet is still connected
- ❌ Hotspot does NOT start if WiFi is still connected

**To verify monitor is running and checking:**
```bash
sudo systemctl status setup-network-monitor.service
```

Should show: `Active: active (running)`

**To check monitor's detection status:**
```bash
sudo journalctl -u setup-network-monitor.service -n 10 --no-pager
```

Look for messages like:
- `Setup network monitor started` - Monitor initialized
- `Initial check: No connectivity detected` - Device already disconnected
- `Lost connectivity` - Just lost connection (will start hotspot soon)
- `Hotspot started successfully` - AP mode is now active

### Step 3: If Auto-Detection Fails - Manual Startup

**First, verify both Ethernet and WiFi are disconnected:**
```bash
# Check all network interfaces
nmcli device status

# Verify Ethernet is disconnected
nmcli device show enp191s0 | grep -i "connected:"

# Verify WiFi is disconnected  
nmcli device show wlp192s0 | grep -i "connected:"
```

Both should show `connected: no`

If Ethernet or WiFi is still showing "connected", disconnect them:

```bash
# Disconnect all active connections
sudo nmcli connection down --active

# Or disconnect specific interfaces
sudo nmcli device disconnect enp191s0  # Ethernet
sudo nmcli device disconnect wlp192s0  # WiFi
```

---

If the hotspot doesn't start automatically after 10 seconds with both interfaces disconnected, manually start it:

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

**Check both interfaces are disconnected:**
```bash
nmcli device status
```

Look for:
```
enp191s0  ethernet  disconnected  --
wlp192s0  wifi      disconnected  --
```

**⚠️ If Ethernet or WiFi still shows "connected":**
- Disconnect it:
```bash
sudo nmcli connection down --active
```

Then wait 6-10 seconds and check monitor:
```bash
sudo journalctl -u setup-network-monitor.service -n 5 --no-pager
# Should show: "Lost connectivity" then "Hotspot started successfully"
```

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

## Quick Test: Trigger Hotspot Now

To immediately test hotspot startup:

```bash
# Step 1: Check current connection status
echo "=== Current connection status ==="
nmcli device status | grep -E "enp|wlp"

# Step 2: Disconnect all active connections
sudo nmcli connection down --active

# Step 3: Verify both are disconnected
echo "=== Verifying disconnection ==="
nmcli device status | grep -E "enp|wlp"
# Should show both as "disconnected"

# Step 4: Wait 6-10 seconds for monitor to detect
sleep 10

# Step 5: Check if hotspot started
echo "=== Check hotspot status ==="
sudo systemctl status hostapd-setup.service --no-pager | head -3
sudo systemctl status dnsmasq-setup.service --no-pager | head -3

# Step 6: Verify from another device
# Connect to "Companion-Setup" WiFi (password: SetupDevice123)
# Check if 192.168.99.0/24 IP is assigned via DHCP
```

**Monitor logs while it's happening (real-time):**
```bash
# Terminal 1: Watch monitor logs
sudo journalctl -u setup-network-monitor.service -f

# Terminal 2: In another shell, disconnect all connections
sudo nmcli connection down --active
```

**Expected log sequence:**
```
Initial check: Internet connectivity detected - hotspot will start if connectivity is lost
Lost connectivity (check 1/2)
Lost connectivity (check 2/2)
No connectivity detected. Starting hotspot via startup script...
Hotspot started successfully
```
