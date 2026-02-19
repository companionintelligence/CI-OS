# CI OS

**Custom Linux distribution for AI companions and development.**  
Based on Ubuntu 24.04.

![CI OS Logo](assets/logos/ci-holo-depth.png)

**© Companion Intelligence — Lifescope Inc**  
*In development. Do not distribute. Private and confidential.*

---

## Contents

1. [Fresh Ubuntu setup](#fresh-ubuntu-setup)
2. [Headless device WiFi setup](#headless-device-wifi-setup)
3. [Ubuntu branding (wallpaper & start icon)](#ubuntu-branding-wallpaper--start-icon)
4. [Repo layout](#repo-layout)

---

## Fresh Ubuntu setup

Use the main setup script to prepare a fresh Ubuntu system with Docker, Node.js (via asdf), Bun, Ollama, GitHub CLI, VS Code, and related tooling:

```bash
sudo ./scripts/setup-fresh-ubuntu.sh
```

Requires root. See script header and `configs/` for package lists and options.

---

## Headless device WiFi setup

Headless first-time WiFi setup via a **captive portal**: device broadcasts a hotspot when it has no network; you connect, open the portal, enter a pairing code and WiFi credentials; the device then joins your network and stops the hotspot.

### Stack

- **hostapd** — WiFi AP (SSID: `Companion-Setup`)
- **dnsmasq** — DHCP (192.168.99.0/24) and DNS redirect for captive portal
- **nginx** — Serves portal and proxies API
- **Flask backend** — WiFi scan, config validation, NetworkManager integration
- **setup-network-monitor** — Starts hotspot when **both** Ethernet and WiFi are disconnected

### Build and install

```bash
cd setup/headless
./build.sh
sudo dpkg -i setup-device_*.deb
```

Verify:

```bash
systemctl status setup-backend.service setup-network-monitor.service hostapd-setup.service dnsmasq-setup.service nginx.service
sudo cat /etc/setup-device/pairing_code.json
```

### Quick usage

1. **Hotspot:** `Companion-Setup` — password: `SetupDevice123`
2. **Portal:** https://setup.ci.computer or http://192.168.99.1 (captive portal may open automatically)
3. **Pairing code:** Device code in `/etc/setup-device/pairing_code.json`, or test code `abc-123` (always accepted)
4. **Form:** Select WiFi, enter password, submit. Device connects and stops the hotspot.

| Setting        | Value                    |
|----------------|--------------------------|
| Gateway        | 192.168.99.1             |
| DHCP range     | 192.168.99.10–250        |
| Portal URL     | https://setup.ci.computer |

### When the hotspot starts

- **Automatic:** `setup-network-monitor.service` starts the hotspot when **both** Ethernet and WiFi are disconnected (checks every ~3 s; typically ~6 s after disconnect).
- **Manual trigger:** Disconnect all connections, wait ~10 s, or start services by hand:

```bash
sudo nmcli connection down --active
# wait ~10 s for monitor to start hotspot

# Or manual start (if config already in place):
sudo systemctl start hostapd-setup.service
sudo systemctl start dnsmasq-setup.service
```

### Key paths

- Config: `/etc/hostapd/`, `/etc/dnsmasq.d/`, `/etc/nginx/`, `/etc/setup-device/`
- Backend: `/opt/setup-backend/setup_service.py`
- Portal: `/var/www/setup-portal/`
- Completion flag: `/var/lib/setup-device/setup-complete`
- Pairing code: `/etc/setup-device/pairing_code.json`

### Troubleshooting

- **Hotspot not visible:** Ensure both Ethernet and WiFi are disconnected; check `journalctl -u setup-network-monitor.service -u hostapd-setup.service -n 30`.
- **Portal unreachable:** Confirm `192.168.99.1` on the WiFi interface (`ip addr`), and that `dnsmasq-setup` and `nginx` are running.
- **Reset and re-run setup:** `sudo rm /var/lib/setup-device/setup-complete` then restart `setup-network-monitor.service` (and optionally nginx, setup-backend). Disconnect network and wait for hotspot.

---

## Ubuntu branding (wallpaper & start icon)

Scripts in `setup/os-changes/` apply CI OS branding on Ubuntu (GNOME/Yaru). They use files in the same directory; the repo is intended to be moved as a whole, so no path prompts.

### Complete system branding (recommended)

Applies comprehensive CI OS branding including Plymouth boot splash, login screen, wallpaper, start icon, and dark green theme throughout the system.

```bash
sudo ./setup/os-changes/set-ci-branding.sh
```

**Official CI Dark Green Color Scheme:**
- Primary Dark Green: `#066c80` (backgrounds, window frames, selection)
- Medium Green: `#00a9a7` (highlights, links, buttons)
- Light Green: `#72ddd4` (accents, text highlights)

**What it does:**
- Replaces Plymouth boot splash with CI logo and dark green colors
- Updates GRUB theme with CI colors
- Sets GDM (login screen) to dark green theme
- Configures desktop environment with CI branding
- Removes Ubuntu branding from boot messages
- Sets wallpaper and applies CI color scheme system-wide
- **Requires reboot** for Plymouth/boot changes to take effect

### Start icon (Show Apps button)

Replaces the Ubuntu “Show Apps” / Activities icon with the CI OS icon in all Yaru theme variants.

```bash
sudo ./setup/os-changes/replace-start-icon.sh
```

- Uses: `setup/os-changes/LogoMark_Color_StartIcon-cropped.svg`
- Target: `start-here-symbolic.svg` in each `/usr/share/icons/Yaru*/scalable/places/`
- **Apply changes:** Log out and back in, or Alt+F2 → `r` → Enter to restart GNOME Shell

### Wallpaper

Sets the current user’s desktop background and system-wide default for new users.

```bash
sudo ./setup/os-changes/replace-wallpaper.sh
```

- Uses: `setup/os-changes/background.png`
- Copies to: `/usr/share/backgrounds/ci-os-wallpaper.png`
- Sets `picture-uri` and `picture-uri-dark` via gsettings (and dconf for new users)

Both scripts create timestamped backups under `/usr/share/icons/ubuntu-backup-*` and `/usr/share/backgrounds/ubuntu-backup-*`.

---

## Repo layout

```
├── assets/           # Logos, wallpapers, branding
├── configs/          # Boot, desktop, packages, preseed, scripts
├── docs/              # Installation and headless setup notes
├── scripts/           # setup-fresh-ubuntu.sh, libs
├── setup/
│   ├── headless/      # Headless WiFi setup: build, deb, portal, backend
│   └── os-changes/    # replace-start-icon.sh, replace-wallpaper.sh, assets
└── README.md          # This file
```
