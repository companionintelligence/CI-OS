# CI OS Headless Setup - System Architecture

## Overview Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          HEADLESS SETUP WORKFLOW                         │
└─────────────────────────────────────────────────────────────────────────┘

┌──────────────┐
│ Device Boot  │
└──────┬───────┘
       │
       ▼
┌──────────────────────────────────────────┐
│ Check: WiFi Configured?                  │
│ File: /var/lib/ci-os/setup-complete      │
└──────┬───────────────────────────────────┘
       │
       ├─── YES ──▶ Exit (Normal Boot)
       │
       └─── NO ───▶ Continue Setup
                    │
                    ▼
           ┌────────────────────────┐
           │ Create WiFi Hotspot    │
           │ SSID: CI-OS-Setup      │
           │ IP: 10.42.0.1/24       │
           └────────┬───────────────┘
                    │
                    ▼
           ┌────────────────────────┐
           │ Start dnsmasq          │
           │ (DNS + DHCP Server)    │
           └────────┬───────────────┘
                    │
                    ▼
           ┌────────────────────────┐
           │ Configure iptables     │
           │ (Port Forwarding)      │
           └────────┬───────────────┘
                    │
                    ▼
           ┌────────────────────────┐
           │ Start Flask Web Server │
           │ Port: 80               │
           └────────┬───────────────┘
                    │
                    ▼
           ┌────────────────────────┐
           │ Wait for User          │
           │ to Connect             │
           └────────┬───────────────┘
                    │
                    ▼

┌─────────────────────────────────────────────────────────────────────────┐
│                            USER INTERACTION                              │
└─────────────────────────────────────────────────────────────────────────┘

    [User's Phone/Laptop]
            │
            ▼
    ┌───────────────────┐
    │ Connect to WiFi   │
    │ "CI-OS-Setup"     │
    └────────┬──────────┘
             │
             ▼
    ┌───────────────────────────┐
    │ Captive Portal Detection  │
    │ (Automatic Redirect)      │
    └────────┬──────────────────┘
             │
             ▼
    ┌───────────────────────────┐
    │ Display Setup Form        │
    │ - Pairing Code            │
    │ - WiFi Network Select     │
    │ - WiFi Password           │
    └────────┬──────────────────┘
             │
             ▼
    ┌───────────────────────────┐
    │ Submit Form               │
    └────────┬──────────────────┘
             │
             ▼

┌─────────────────────────────────────────────────────────────────────────┐
│                         CONFIGURATION PROCESS                            │
└─────────────────────────────────────────────────────────────────────────┘

    [Server Receives Data]
            │
            ├─────────────────────┐
            │                     │
            ▼                     ▼
    ┌───────────────┐    ┌──────────────────┐
    │ Validate Data │    │ Save to Config   │
    │               │    │ File             │
    └───────┬───────┘    └──────────────────┘
            │
            ▼
    ┌──────────────────────────┐
    │ Connect to WiFi Network  │
    │ using NetworkManager     │
    │ (nmcli)                  │
    └────────┬─────────────────┘
             │
             ├─── FAIL ──▶ Return Error to User
             │
             └─── SUCCESS
                    │
                    ▼
           ┌────────────────────────┐
           │ Cloud Pairing API Call │
           │ (setup.ci.computer)    │
           └────────┬───────────────┘
                    │
                    ├─── FAIL ──▶ Log Warning (Continue)
                    │
                    └─── SUCCESS
                           │
                           ▼
                  ┌──────────────────┐
                  │ Create Flag File │
                  │ setup-complete   │
                  └────────┬─────────┘
                           │
                           ▼
                  ┌──────────────────┐
                  │ Cleanup          │
                  │ - Stop Hotspot   │
                  │ - Stop dnsmasq   │
                  │ - Clear iptables │
                  │ - Stop Web Server│
                  └────────┬─────────┘
                           │
                           ▼
                  ┌──────────────────┐
                  │ Success Response │
                  │ to User          │
                  └────────┬─────────┘
                           │
                           ▼
                    [ Setup Complete ]
```

## Component Interaction

```
┌──────────────────────────────────────────────────────────────┐
│                    SYSTEM COMPONENTS                          │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  Systemd Service                                              │
│  ┌────────────────────────────────────────────────┐          │
│  │ ci-os-headless-setup.service                   │          │
│  │ - Starts on boot (if setup not complete)      │          │
│  │ - Manages daemon lifecycle                     │          │
│  └───────────────────┬────────────────────────────┘          │
│                      │                                        │
│                      ▼                                        │
│  Main Daemon                                                  │
│  ┌────────────────────────────────────────────────┐          │
│  │ ci-os-headless-setup.sh                        │          │
│  │ - Checks setup status                          │          │
│  │ - Creates hotspot via NetworkManager           │          │
│  │ - Configures DNS/DHCP via dnsmasq              │          │
│  │ - Sets up port forwarding via iptables         │          │
│  │ - Launches web server                          │          │
│  │ - Monitors for completion                      │          │
│  │ - Performs cleanup                             │          │
│  └───────────────────┬────────────────────────────┘          │
│                      │                                        │
│                      ▼                                        │
│  Web Server                                                   │
│  ┌────────────────────────────────────────────────┐          │
│  │ captive-portal.py (Flask)                      │          │
│  │                                                 │          │
│  │ Routes:                                         │          │
│  │ - GET  /          → Portal HTML                │          │
│  │ - GET  /scan      → WiFi Network List          │          │
│  │ - POST /configure → Process Setup Form         │          │
│  │                                                 │          │
│  │ Functions:                                      │          │
│  │ - scan_networks()      → nmcli scan            │          │
│  │ - connect_to_wifi()    → nmcli connect         │          │
│  │ - perform_cloud_pairing() → API call           │          │
│  └─────────────────────────────────────────────────┘          │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

## Network Flow

```
┌─────────────────────────────────────────────────────────────┐
│                      NETWORK TOPOLOGY                        │
└─────────────────────────────────────────────────────────────┘

Internet
   │
   │ (Pairing API)
   │
   ▼
┌──────────────────┐
│ setup.ci.computer│
│ (Cloud Service)  │
└──────────────────┘
        ▲
        │ HTTPS
        │ (After WiFi Connected)
        │
┌───────┴──────────────────────────────────────────────────────┐
│                     Home WiFi Router                          │
│                     (User's Network)                          │
└───────┬──────────────────────────────────────────────────────┘
        │
        │ WiFi Connection
        │ (After Setup)
        │
        ▼
┌─────────────────────────────────┐
│     CI OS Device                │
│                                 │
│  WiFi Adapter (wlan0)           │
│  ┌───────────────────────────┐ │
│  │                           │ │
│  │  Mode: AP (During Setup)  │ │
│  │  SSID: CI-OS-Setup        │ │
│  │  IP: 10.42.0.1            │ │
│  │                           │ │
│  │  ┌─────────────────────┐ │ │
│  │  │   dnsmasq           │ │ │
│  │  │   - DHCP Server     │ │ │
│  │  │   - DNS Hijacking   │ │ │
│  │  └─────────────────────┘ │ │
│  │                           │ │
│  │  ┌─────────────────────┐ │ │
│  │  │   Flask Server      │ │ │
│  │  │   Port 80           │ │ │
│  │  └─────────────────────┘ │ │
│  │                           │ │
│  └───────────────────────────┘ │
│         ▲                       │
└─────────┼───────────────────────┘
          │
          │ WiFi
          │
  ┌───────┴────────┐
  │ User's Device  │
  │ (Phone/Laptop) │
  │                │
  │ IP: 10.42.0.x  │
  │ (DHCP Assigned)│
  └────────────────┘
```

## DNS Hijacking Flow

```
┌──────────────────────────────────────────────────────────────┐
│                  CAPTIVE PORTAL DETECTION                     │
└──────────────────────────────────────────────────────────────┘

User Device Connects
        │
        ▼
Device Makes Captive Portal Check
(Different per OS)
        │
        ├─ Android: GET http://connectivitycheck.gstatic.com/generate_204
        ├─ iOS:     GET http://captive.apple.com/hotspot-detect.html
        ├─ Windows: GET http://www.msftconnecttest.com/connecttest.txt
        └─ Linux:   Various (depends on distro)
        │
        ▼
DNS Query
        │
        ▼
┌───────────────────┐
│    dnsmasq        │
│ (Our DNS Server)  │
│                   │
│ address=/#/       │
│ 10.42.0.1         │
└────────┬──────────┘
         │
         │ All domains → 10.42.0.1
         ▼
HTTP Request to 10.42.0.1
         │
         ▼
┌───────────────────┐
│   iptables        │
│ (Port Forwarding) │
│                   │
│ Port 80  → Flask  │
│ Port 443 → Flask  │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│  Flask Server     │
│  Serves Portal    │
└───────────────────┘
         │
         ▼
Captive Portal Opens!
```

## File System Layout

```
/usr/local/
├── bin/
│   └── ci-os-headless-setup.sh          # Main daemon script
└── share/
    └── ci-os-headless-setup/
        ├── web/
        │   └── captive-portal.py         # Flask web server
        └── lib/
            └── utils.sh                  # Utility functions

/etc/
├── systemd/
│   └── system/
│       └── ci-os-headless-setup.service # Systemd service
└── dnsmasq.d/
    └── ci-os-captive-portal.conf        # Created at runtime

/var/
├── lib/
│   └── ci-os/
│       ├── setup-complete               # Flag file (setup done)
│       ├── setup-config.json            # Configuration data
│       └── nm-backups/                  # NetworkManager backups
└── log/
    └── ci-os-headless-setup.log         # Setup logs
```

## State Machine

```
┌──────────────────────────────────────────────────────────────┐
│                    SETUP STATE MACHINE                        │
└──────────────────────────────────────────────────────────────┘

    [BOOT]
      │
      ▼
┌─────────────┐
│   CHECKING  │ ← Check if setup is needed
└──────┬──────┘
       │
       ├─ Setup Complete → [EXIT]
       │
       └─ Setup Needed
           │
           ▼
    ┌──────────────┐
    │  INITIALIZING│ ← Create hotspot, start services
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │   WAITING    │ ← Waiting for user connection
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │ CONFIGURING  │ ← User submits form, processing
    └──────┬───────┘
           │
           ├─ Error → Return to WAITING
           │
           └─ Success
               │
               ▼
        ┌──────────────┐
        │  CONNECTING  │ ← Connecting to WiFi
        └──────┬───────┘
               │
               ├─ Failed → Return to WAITING
               │
               └─ Connected
                   │
                   ▼
            ┌──────────────┐
            │   PAIRING    │ ← Cloud API call
            └──────┬───────┘
                   │
                   ├─ Failed → Log warning, continue
                   │
                   └─ Success or Continue
                       │
                       ▼
                ┌──────────────┐
                │  CLEANING UP │ ← Stop hotspot, cleanup
                └──────┬───────┘
                       │
                       ▼
                ┌──────────────┐
                │   COMPLETE   │ ← Mark as done
                └──────┬───────┘
                       │
                       ▼
                    [EXIT]
```

## Security Boundaries

```
┌──────────────────────────────────────────────────────────────┐
│                    SECURITY BOUNDARIES                        │
└──────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│  User Device (Untrusted)                               │
│                                                         │
│  Can access:                                            │
│  ✓ Captive portal web interface (HTTP)                │
│  ✓ WiFi network scanning results                      │
│  ✓ Form submission                                     │
│                                                         │
│  Cannot access:                                         │
│  ✗ System files                                        │
│  ✗ Other network interfaces                           │
│  ✗ Saved WiFi passwords                               │
│  ✗ Device system configuration                        │
└────────────────┬───────────────────────────────────────┘
                 │
                 │ HTTP (Port 80)
                 │ Captive Portal Traffic Only
                 │
┌────────────────┴───────────────────────────────────────┐
│  Flask Web Server (Application Layer)                  │
│                                                         │
│  - Input validation                                     │
│  - WiFi password encryption before storage             │
│  - No shell injection in nmcli commands                │
│  - Limited file system access                          │
└────────────────┬───────────────────────────────────────┘
                 │
                 │ Function Calls
                 │
┌────────────────┴───────────────────────────────────────┐
│  System Services (Privileged)                          │
│                                                         │
│  NetworkManager (root)                                  │
│  - WiFi connection management                          │
│  - Secure credential storage                           │
│                                                         │
│  dnsmasq (dedicated user)                              │
│  - DNS/DHCP service                                    │
│  - Isolated network namespace                          │
│                                                         │
│  iptables (root)                                       │
│  - Port forwarding rules                               │
│  - Traffic filtering                                   │
└─────────────────────────────────────────────────────────┘

Data Flow Security:
- WiFi Password: User → Flask → nmcli → NetworkManager → Encrypted Storage
- Pairing Code:  User → Flask → Cloud API → Verified & Linked
```

This architecture ensures separation of concerns and minimizes attack surface.
