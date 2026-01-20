# System Architecture & WiFi Setup Flow

## Hardware Stack

```
┌─────────────────────────────────────────────────┐
│ HOST SYSTEM (Ubuntu Server)                     │
├─────────────────────────────────────────────────┤
│ Linux Kernel 5.10+                              │
│ └─ mt7921e driver (WiFi 6 support)              │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ MEDIATEK MT7925 WiFi 6 Module                   │
├─────────────────────────────────────────────────┤
│ • Dual-band: 2.4 GHz & 5 GHz                   │
│ • 802.11ax (WiFi 6)                             │
│ • Max 10+ simultaneous clients                  │
│ • OFDMA + MU-MIMO                               │
│ • Part: T99H493.03 / RZ717                      │
│ • MAC: F4289D0524DF (WiFi)                      │
│         F4289D0524E0 (Bluetooth)                │
└─────────────────────────────────────────────────┘
```

## Service Stack

```
┌──────────────────────────────────────────────────────────┐
│                    SYSTEMD SERVICES                      │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  hostapd-setup.service (WiFi AP)                        │
│  ├─ Status: Runs on boot if no WiFi connected           │
│  ├─ SSID: Companion-Setup                               │
│  ├─ Interface: wlan0                                    │
│  ├─ Config: /etc/hostapd/hostapd-setup.conf             │
│  └─ Stops: After device configuration                   │
│                                                          │
│  dnsmasq-setup.service (DHCP + DNS)                     │
│  ├─ Depends on: hostapd-setup.service                   │
│  ├─ Function: DHCP server (192.168.99.10-250)           │
│  ├─ DNS: Redirects all domains to 192.168.99.1          │
│  ├─ Config: /etc/dnsmasq.d/setup-portal.conf            │
│  └─ Stops: After device configuration                   │
│                                                          │
│  nginx.service (Web Server)                             │
│  ├─ Function: Serves captive portal                     │
│  ├─ Listen: 192.168.99.1:80                             │
│  ├─ Portal: /var/www/setup-portal/index.html            │
│  ├─ Config: /etc/nginx/sites-available/setup-portal     │
│  └─ Status: Continues running for monitoring             │
│                                                          │
│  setup-backend.service (Flask API)                      │
│  ├─ Language: Python 3                                  │
│  ├─ Service: Flask REST API                             │
│  ├─ Listen: 127.0.0.1:5000 (proxied via nginx)          │
│  ├─ Functions:                                          │
│  │  • WiFi network scanning                             │
│  │  • Configuration validation                          │
│  │  • NetworkManager integration                        │
│  │  • Credential persistence                            │
│  ├─ Code: /opt/setup-backend/setup_service.py           │
│  ├─ Logs: /var/log/setup-backend.log                    │
│  └─ Status: Continues running for status monitoring     │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

## Network Configuration

```
┌─────────────────────────────────────────────────────┐
│          SETUP MODE NETWORK LAYOUT                 │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Gateway/Portal: 192.168.99.1 (wlan0)             │
│  │                                                 │
│  ├─ HTTP Portal: http://192.168.99.1              │
│  │  └─ Served by nginx                             │
│  │                                                 │
│  ├─ DNS: All domains → 192.168.99.1               │
│  │  └─ Managed by dnsmasq                          │
│  │                                                 │
│  └─ DHCP Range: 192.168.99.10 - 192.168.99.250   │
│     └─ Managed by dnsmasq                          │
│                                                     │
│  Connecting Device:                               │
│  ├─ Receives IP from DHCP (e.g., .50)             │
│  ├─ Tries to connect to Apple/Google captive      │
│  │  portal detection                              │
│  ├─ All DNS requests redirected to 192.168.99.1  │
│  ├─ Browser auto-opens http://192.168.99.1       │
│  └─ User sees setup form                          │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## Pairing Code Validation Flow

```
┌──────────────────────────────────────┐
│   User Submits Setup Form            │
│   • Pairing Code: "abc-123"          │
│   • SSID: "MyWiFi"                   │
│   • Password: "mypassword"           │
└─────────────────┬────────────────────┘
                  │
                  ▼
        ┌─────────────────────┐
        │ Normalize Code      │
        │ "abc-123" → "ABC123"│
        └─────────┬───────────┘
                  │
         ┌────────┴─────────┐
         │                  │
         ▼                  ▼
    ┌─────────┐    ┌──────────────────┐
    │ Is "ABC123"?       │ Check Device │
    │ (Test Code)        │ Code in JSON │
    │ ✓ YES → Accept │ │ Match?       │
    │                │ │ ✓ YES → OK  │
    │                │ │ ✗ NO → Fail  │
    └─────────┬──────┘ └──────┬───────┘
              │               │
              └───────┬───────┘
                      │
                      ▼
         ┌────────────────────────┐
         │ Check Expiry           │
         │ (Device code only)     │
         │ ✓ Valid → Continue    │
         │ ✗ Expired → Fail      │
         └────────────┬───────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │ Create WiFi Connection │
         │ • Add to NetworkManager│
         │ • Set credentials      │
         └────────────┬───────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │ Store Credentials      │
         │ /var/lib/.../.json     │
         │ (root-only, 0600)      │
         └────────────┬───────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │ Mark Setup Complete    │
         │ Create setup-complete  │
         └────────────┬───────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │ Stop Hotspot Services  │
         │ • systemctl stop       │
         │   hostapd-setup        │
         │ • systemctl stop       │
         │   dnsmasq-setup        │
         └────────────┬───────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │ Connect to WiFi        │
         │ nmcli connection up    │
         │ {SSID}                 │
         └────────────┬───────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │ Return Success         │
         │ Portal shows: ✓ Done   │
         │ Hotspot disappears     │
         └────────────────────────┘
```

## Boot Sequence Decision Tree

```
                    DEVICE BOOTS
                        │
                        ▼
        ┌───────────────────────────┐
        │ Check Network Status      │
        │ (wlan0, eth0, tun, etc.)  │
        └───────────────┬───────────┘
                        │
            ┌───────────┴───────────┐
            │                       │
            ▼                       ▼
      ┌─────────────┐        ┌─────────────┐
      │ Network     │        │ No Network  │
      │ Connected?  │        │ Available   │
      │ YES → Boot  │        │ (setup mode)│
      │ Normally    │        └──────┬──────┘
      └─────────────┘               │
                                    ▼
                        ┌──────────────────────┐
                        │ Load Netplan Config  │
                        │ Set wlan0 static IP  │
                        │ 192.168.99.1/24      │
                        └──────────┬───────────┘
                                   │
                                   ▼
                        ┌──────────────────────┐
                        │ Start hostapd        │
                        │ Broadcast AP:        │
                        │ Companion-Setup      │
                        └──────────┬───────────┘
                                   │
                                   ▼
                        ┌──────────────────────┐
                        │ Start dnsmasq        │
                        │ DHCP + DNS redirect  │
                        │ All → 192.168.99.1   │
                        └──────────┬───────────┘
                                   │
                                   ▼
                        ┌──────────────────────┐
                        │ Start nginx          │
                        │ Serve captive portal │
                        │ Listen on 192.168... │
                        └──────────┬───────────┘
                                   │
                                   ▼
                        ┌──────────────────────┐
                        │ Start Flask backend  │
                        │ WiFi scan API        │
                        │ Config validation    │
                        └──────────┬───────────┘
                                   │
                                   ▼
                        ┌──────────────────────┐
                        │ READY FOR SETUP      │
                        │ Waiting for user...  │
                        └──────────────────────┘
```

## File Structure

```
setup/headless/
├── README.md                          # Overview & architecture
├── INSTALL.md                         # Installation guide
├── QUICK_START.md                     # 5-minute setup guide
├── WIFI_CHIP_INFO.md                 # Hardware specs & docs
├── IMPLEMENTATION_SUMMARY.md          # Changes & features
├── build.sh                           # Build script
│
└── setup-device/                      # .deb package content
    ├── DEBIAN/
    │   ├── control                    # Package metadata
    │   ├── postinst                   # Post-install script
    │   ├── prerm                      # Pre-remove script
    │   └── postrm                     # Post-remove script
    │
    ├── etc/
    │   ├── hostapd/
    │   │   └── hostapd-setup.conf     # WiFi AP config
    │   ├── dnsmasq.d/
    │   │   └── setup-portal.conf      # DHCP/DNS config
    │   ├── nginx/
    │   │   └── sites-available/
    │   │       └── setup-portal       # Web server config
    │   ├── netplan/
    │   │   └── 50-setup-mode.yaml     # Network config
    │   ├── setup-device/
    │   │   ├── device.conf            # Device settings
    │   │   └── pairing_code.json      # Pairing code
    │   └── systemd/system/
    │       ├── hostapd-setup.service  # Service def
    │       ├── dnsmasq-setup.service  # Service def
    │       ├── setup-backend.service  # Service def
    │       └── nginx.service          # Service def (std)
    │
    ├── opt/
    │   └── setup-backend/
    │       └── setup_service.py       # Flask backend
    │           ├── validate_pairing_code()
    │           │  └─ Test code: abc-123 ✅
    │           ├── scan_wifi_networks()
    │           ├── create_wifi_connection()
    │           ├── connect_to_wifi()
    │           └── /api/configure endpoint
    │
    └── var/
        └── www/
            └── setup-portal/
                └── index.html         # Captive portal UI
                    └─ Dark mode support
                    └─ Mobile responsive
                    └─ No JavaScript needed
```

## Key Timestamps

```
Boot Start: T+0s
    ├─ T+1-2s: Systemd starts services
    ├─ T+5-10s: hostapd broadcasts hotspot
    ├─ T+10-15s: dnsmasq ready, nginx ready
    ├─ T+15-20s: Flask backend ready
    └─ T+20s: READY (user can connect)

User Connects: T+30s (example)
    ├─ T+30s: Device joins hotspot
    ├─ T+31s: Receives DHCP IP
    ├─ T+32s: Captive portal detects (Apple/Google/MS)
    ├─ T+33s: Browser auto-opens portal
    └─ T+35s: User sees setup form

User Submits: T+45s (example)
    ├─ T+45s: Form submitted (abc-123, WiFi, password)
    ├─ T+46s: Code validated
    ├─ T+47s: WiFi connection created
    ├─ T+48s: Credentials stored
    ├─ T+49s: Hotspot services stop
    ├─ T+50s: Device connects to WiFi
    ├─ T+55s: Connection established
    └─ T+60s: Device on main network
```

## Security Model

```
┌────────────────────────────────────────┐
│        PAIRING CODE VALIDATION         │
├────────────────────────────────────────┤
│                                        │
│ DEVICE-GENERATED CODE                 │
│ • Format: ABC-DEF (3+3, A-Z0-9)      │
│ • Generated on first boot              │
│ • Stored in /etc/setup-device/         │
│   pairing_code.json                   │
│ • Expires: 24 hours                    │
│ • Regenerated on each boot             │
│ • Different each time                  │
│ • More secure                          │
│                                        │
│ TEST CODE (Development Only)           │
│ • Code: abc-123                        │
│ • Always valid (no expiry)             │
│ • Case-insensitive                     │
│ • For demos/development/testing        │
│ • Should be removed for production     │
│                                        │
│ CREDENTIAL STORAGE                     │
│ • Location: /var/lib/setup-device/    │
│   credentials.json                    │
│ • Permissions: 0600 (root-only)       │
│ • Format: JSON (ssid, password, date) │
│ • Encrypted on disk: /var via dm-crypt│
│ • Never transmitted in plain text      │
│                                        │
└────────────────────────────────────────┘
```

---

**For detailed technical information, see:**
- [WIFI_CHIP_INFO.md](WIFI_CHIP_INFO.md) - Hardware specifications
- [README.md](README.md) - Service architecture
- [INSTALL.md](INSTALL.md) - Installation procedures
- [QUICK_START.md](QUICK_START.md) - User guide
- [IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md) - Changes made
