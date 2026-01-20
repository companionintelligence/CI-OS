Apt-Installed, Daemonized Headless Setup System
Role

You are a senior Linux systems engineer implementing a production-grade, daemonized first-time WiFi setup system for a headless Ubuntu-based device.

The system is distributed as an APT-installable package and runs entirely via systemd services.

There is:

No UI beyond a captive portal

No interactive installer

No SSH requirement

No manual configuration after install

Once installed, the system must work automatically on next boot.

0. Core Principles (Non-Negotiable)

Daemon-first: Everything runs under systemd

Idempotent: Reboots are safe

CDC-compliant: Works with Apple / Google / Microsoft captive detection

Fail-closed: No WAN access during setup

Self-disabling: Hotspot automatically shuts down after success

Apt-native: Installed and removed cleanly via apt

1. Package Identity

Package name:

setup-device


Target:

Ubuntu Server

arm64 (but architecture-agnostic configs)

Installed via:

apt install setup-device

2. Installed Filesystem Layout (Authoritative)

When installed, files must land exactly here:

/etc/setup-device/
│   └── device.conf
│   └── pairing_code.json

/etc/hostapd/
│   └── hostapd-setup.conf

/etc/dnsmasq.d/
│   └── setup-portal.conf

/etc/nginx/sites-available/
│   └── setup-portal

/etc/netplan/
│   └── 50-setup-mode.yaml

/etc/systemd/system/
│   ├── hostapd-setup.service
│   ├── dnsmasq-setup.service
│   └── setup-backend.service

/opt/setup-backend/
│   └── setup_service.py

/var/www/setup-portal/
│   └── index.html

/var/lib/setup-device/
│   ├── credentials.json
│   └── setup-complete

/var/log/
│   └── setup-backend.log


No files go into /usr/local.

3. systemd Service Model (Critical)
3.1 Setup State Gate

All hotspot-related services must be gated by:

ConditionPathExists=!/var/lib/setup-device/setup-complete


Once setup is complete, hotspot services never start again.

3.2 hostapd-setup.service

Responsibilities:

Broadcast Setup-Device-XXXX

Bind to wlan0

WPA2 only

Restart on failure

Requirements:

Starts early

Stops permanently after setup

Never blocks boot

3.3 dnsmasq-setup.service

Responsibilities:

DHCP on 192.168.99.0/24

DNS redirect to captive portal

No upstream resolvers

Interface-scoped to wlan0

Dependencies:

Requires hostapd

Stops after setup completion

3.4 setup-backend.service

Responsibilities:

Always running

Generates pairing code on first boot

Validates pairing code

Scans WiFi (nmcli)

Creates NetworkManager connection

Disables hotspot after success

Writes setup-complete flag

Properties:

Runs as root

Restart=on-failure

Never exits on success

Signal-safe (SIGTERM, SIGINT)

4. Networking Model
Setup Mode

wlan0: 192.168.99.1/24

No default route

DNS forced to self

WAN traffic blocked implicitly

Post-Setup

wlan0 connects to user WiFi

DHCP from router

hostapd + dnsmasq disabled

Backend remains idle

Netplan must be reversible on package removal.

5. Captive Portal Stack
5.1 nginx

HTTP only (port 80)

Default server

Serves /var/www/setup-portal

Proxies /api/* → 127.0.0.1:5000

No HTTPS

Strong security headers

No reload loops

5.2 Portal HTML

Requirements:

Pure HTML + CSS

No JS reliance for submission

Mobile-first

Dark-mode aware

Works inside:

iOS captive browser

Android captive browser

Windows captive browser

Form fields:

Pairing code (XXX-XXX)

SSID

Password

No external assets.

6. Backend (Flask, Daemonized)
6.1 Pairing Code

Format: XXX-XXX

Charset: A–Z, 0–9

Entropy ≈ 36⁶

Stored root-only

24-hour expiry

Regenerated if expired

6.2 API Surface
GET  /api/scan-networks
POST /api/configure
GET  /api/status
GET  /health


On /api/configure success:

Validate pairing code

Create NetworkManager connection

Persist credentials securely

Write setup-complete flag

Stop hostapd + dnsmasq

Leave backend running

7. APT Lifecycle Scripts
7.1 postinst

Must:

Reload systemd

Enable services

Apply netplan

Generate pairing code if missing

Start backend first

Start hotspot stack

Fail loudly on error.

7.2 prerm / postrm

Must:

Stop all services

Disable all services

Remove configs

Restore wlan0 to DHCP

Reload systemd

Leave system clean

8. Security Constraints

No WAN during setup

No DNS leakage

Root-only secrets (0600)

No JavaScript dependency

No analytics

No SSH enablement

9. Validation Targets

System must pass:

iOS captive auto-popup

Android captive auto-popup

Windows captive detection

Manual access at 192.168.99.1

Hotspot shuts down after success

No regression on reboot

10. Output Requirements

When complete, output:

systemd unit files

Flask backend (daemon-safe)

nginx config

netplan config

APT control + lifecycle scripts

Boot + teardown checklist

No marketing language.
No explanations beyond execution details.