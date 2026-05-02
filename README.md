## Companion Intelligence OS
### UnCloud Debian Linux

![CI OS Logo](assets/logos/ci-holo-depth.png)

**© Companion Intelligence — Lifescope Inc**  
*In development. Do not distribute. Private and confidential.*

---

## Contents

1. [Building CI-OS ISOs](#building-ci-os-isos)
2. [Fresh Ubuntu setup](#fresh-ubuntu-setup)
3. [Headless device WiFi setup](#headless-device-wifi-setup)
4. [Ubuntu branding (wallpaper & start icon)](#ubuntu-branding-wallpaper--start-icon)
5. [Repo layout](#repo-layout)
6. [Documentation](#documentation)

---

## Building CI-OS ISOs

Create custom CI-OS ISOs from Ubuntu 24.04 with complete branding, privacy features, and AMD GPU support.

### Quick Start

```bash
# Download Ubuntu 24.04 base ISO
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso

# Build CI-OS ISO
sudo ./tools/iso-build/scripts/build-iso.sh \
  --base-iso ubuntu-24.04.1-desktop-amd64.iso \
  --version 1.0
```

Output: `./output/companion-os-1.0-amd64.iso`

### Features

✅ **Complete Ubuntu Rebrand** - All Ubuntu identity replaced with CI-OS  
✅ **Privacy First** - Telemetry removed, metrics blocked  
✅ **AMD GPU Ready** - ROCm installation helper included  
✅ **Custom Branding** - Dark green theme (#066c80, #00a9a7, #72ddd4)  
✅ **Developer Tools** - Pre-configured for Docker, Node.js, VS Code  
✅ **Bootable ISO** - BIOS + UEFI + Secure Boot compatible

### Documentation

- **[ISO Build Guide](docs/guides/iso-build-guide.md)** - Complete build documentation
- **[Installation Guide](docs/guides/installation-guide.md)** - End-user installation steps
- **[Quick Start Guide](docs/guides/quick-start-guide.md)** - Get started fast
- **[Package Repository Setup](docs/guides/package-repository-setup.md)** - Host your own packages
- **[Tools README](tools/iso-build/README.md)** - Script reference

### CI/CD

ISOs are automatically built via GitHub Actions:
- **Weekly**: Sundays at 2 AM UTC
- **On Tags**: Push `v*` tag to trigger release
- **Manual**: Workflow dispatch in Actions tab

See `.github/workflows/build-companion-os-iso.yml` for configuration.

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

## Ubuntu branding (GNOME / Plymouth / MOTD)

Only **`setup/os-changes/apply-ci-os-desktop.sh`** lives beside `common/`; all steps are **`setup/os-changes/common/*.sh`**. Assets stay next to the script (`background.png`, logos, SVG). Dock defaults: **left**, **autohide** (dismissable). Reboot once for Plymouth.

```bash
# Full apply (Plymouth → dconf → wallpaper → session → start icon → os-release → MOTD)
sudo ./setup/os-changes/apply-ci-os-desktop.sh

# Interactive: prompts, optional KDE, validation, optional reboot
sudo ./setup/os-changes/apply-ci-os-desktop.sh --wizard

# CI / non-interactive: full apply + validate (no KDE / no reboot prompt)
sudo ./setup/os-changes/apply-ci-os-desktop.sh --wizard --yes

# Subset only
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only plymouth,dconf,session
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only wallpaper
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only kde

# Read-only checks (no sudo)
./setup/os-changes/apply-ci-os-desktop.sh --validate
```

**Official CI Dark Green Color Scheme:** `#066c80`, `#00a9a7`, `#72ddd4`, `#1b4332`

**Assets:** `LogoMark_Color_StartIcon-cropped.svg` (start icon), `background.png` → `/usr/share/backgrounds/ci-os-wallpaper.*`, `Logo_Banner_Color.png` (Plymouth). Icon and wallpaper steps create backups under `/usr/share/icons/ubuntu-backup-*` and `/usr/share/backgrounds/ubuntu-backup-*` where applicable.

---

## Repo layout

```
├── .github/
│   └── workflows/         # CI/CD: build-companion-os-iso.yml
├── assets/                # Logos, wallpapers, branding
├── configs/               # Boot, desktop, packages, preseed, scripts
├── docs/
│   └── guides/            # ISO build, installation, quick start, repository setup
├── packages/              # .deb package sources
│   ├── companion-os-base/
│   ├── companion-os-keyring/
│   ├── companion-agents/
│   └── companion-memory/
├── scripts/               # setup-fresh-ubuntu.sh, customize-chroot.sh, libs
├── setup/
│   ├── headless/          # Headless WiFi setup: build, deb, portal, backend
│   └── os-changes/        # apply-ci-os-desktop.sh, common/*.sh, assets
├── tools/
│   └── iso-build/         # ISO building tools and scripts
│       ├── scripts/       # build-iso.sh, build-packages.sh, …
│       └── README.md      # Tools documentation
└── README.md              # This file
```

---

## Documentation

### For Users

- **[Installation Guide](docs/guides/installation-guide.md)** - How to install CI-OS
- **[Quick Start Guide](docs/guides/quick-start-guide.md)** - Get up and running fast

### For Developers

- **[ISO Build Guide](docs/guides/iso-build-guide.md)** - Build custom ISOs
- **[Package Repository Setup](docs/guides/package-repository-setup.md)** - Host package repo
- **[Tools README](tools/iso-build/README.md)** - Script reference and customization

### Features

- **No Ads, No Surveillance** - Privacy-first computing
- **AMD GPU Support** - ROCm 7.2+ for AI workloads
- **Developer Ready** - Docker, Node.js, VS Code, Ollama included
- **Sovereign Computing** - Your data, your control

---

## Support

- **Issues**: https://github.com/companionintelligence/CI-OS/issues
- **Website**: https://ci.computer

© Companion Intelligence — Lifescope Inc
