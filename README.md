# Companion Intelligence OS
### UnCloud Debian Linux

![CI OS Logo](assets/logos/ci-holo-depth.png)

**Companion Intelligence OS (CI-OS)** is a repository for building and applying a branded Ubuntu 24.04 based operating system image. It is not a single application. It is a collection of ISO build tooling, Debian package sources, desktop branding scripts, first-boot setup automation, and a headless WiFi setup portal for devices that may ship without a keyboard or display.

**Status:** in development. Private and confidential.

---

## What This Folder Does

At a high level, this repo turns Ubuntu 24.04 Desktop into CI-OS by:

- Building a custom bootable ISO from an Ubuntu Desktop ISO.
- Repacking Ubuntu's `casper` squashfs layers after applying CI-OS branding and system customizations.
- Building local `.deb` packages for OS branding, base metadata, package repository keyring, and future companion services.
- Applying desktop and OS branding to installed Ubuntu systems.
- Installing a first-boot bootstrap service that configures developer and AI tooling after installation.
- Providing a headless first-time WiFi setup package with a captive portal.
- Running a GitHub Actions workflow that builds and publishes ISO artifacts.

The detailed architecture, data flows, and improvement assessment are in [architecture.MD](architecture.MD).

---

## Major Capabilities

| Capability | Entry Point | Result |
|---|---|---|
| Build CI-OS ISO | `tools/iso-build/scripts/build-iso.sh` | Produces `output/companion-os-<version>-amd64.iso` plus checksums |
| Customize extracted rootfs | `scripts/customize-chroot.sh` | Applies CI-OS identity, branding, packages, first-boot services, and cleanup |
| Build local packages | `tools/iso-build/scripts/build-packages.sh` | Builds `.deb` files from `packages/*` |
| Apply desktop branding to an existing install | `setup/os-changes/apply-ci-os-desktop.sh` | Rebrands Plymouth, GNOME/GDM, wallpaper, start icon, MOTD, and OS identity |
| Prepare a fresh Ubuntu install | `scripts/setup-fresh-ubuntu.sh` | Installs Docker, Node/asdf, UV, Homebrew, Ollama, GitHub CLI, cloudflared, VS Code, Chromium, Companion Hub, telemetry removal, and LACT |
| Run Express Setup | `scripts/ci-os-express-setup.sh` | Orchestrates privacy checks, AI benchmark/model setup, and headless status reporting |
| Apply privacy controls | `scripts/ci-os-privacy.sh` | Reports or applies Canonical telemetry package/domain/MOTD controls |
| Benchmark AI readiness | `scripts/ci-os-ai-setup.sh` | Writes hardware benchmark and Ollama model recommendation JSON |
| Build headless setup package | `setup/headless/build.sh` | Produces `setup-device_<version>_amd64.deb` |
| Headless WiFi setup | `setup/headless/setup-device/` | Installs hotspot, captive portal, Flask API, and network monitor services |

---

## Repository Layout

```text
.
├── .github/
│   └── workflows/build-companion-os-iso.yml
├── assets/
│   ├── branding/
│   ├── logos/
│   └── wallpapers/
├── configs/
│   ├── boot/
│   ├── desktop/
│   ├── packages/
│   ├── preseed/
│   └── scripts/
├── docs/
│   └── guides/
├── packages/
│   ├── ci-os-branding/
│   ├── companion-agents/
│   ├── companion-memory/
│   ├── companion-os-base/
│   └── companion-os-keyring/
├── scripts/
│   ├── customize-chroot.sh
│   ├── setup-fresh-ubuntu.sh
│   └── lib/
├── setup/
│   ├── headless/
│   └── os-changes/
├── tools/
│   └── iso-build/
├── architecture.MD
└── README.md
```

---

## Build a CI-OS ISO

Use this path when you want a bootable CI-OS installer image.

### Requirements

- Ubuntu 24.04 build host
- Root privileges
- Ubuntu 24.04 Desktop ISO
- `debootstrap`, `squashfs-tools`, `xorriso`, `rsync`, `gpg`
- Yaru GNOME Shell theme assets for the branded GDM resource build

### Quick Start

```bash
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso

sudo ./tools/iso-build/scripts/build-iso.sh \
  --base-iso ubuntu-24.04.1-desktop-amd64.iso \
  --version 1.0 \
  --clean
```

Output:

```text
output/companion-os-1.0-amd64.iso
output/SHA256SUMS
output/MD5SUMS
```

### What Happens During the ISO Build

1. `.deb` packages are built from `packages/*`.
2. The base Ubuntu ISO is mounted and copied into a working directory.
3. The main Ubuntu squashfs layers are extracted and merged into a chroot.
4. `scripts/customize-chroot.sh` applies CI-OS identity, branding, package changes, first-boot services, and helper commands.
5. The merged rootfs is repacked into `casper/minimal.squashfs`.
6. Placeholder upper squashfs layers are generated so Ubuntu's layered installer expectations remain intact.
7. `install-sources.yaml`, manifests, and `casper/SHA256SUMS` are regenerated.
8. `xorriso` builds the new ISO while preserving the original Ubuntu volume ID for EFI boot compatibility.

---

## Apply Branding to an Existing Ubuntu Install

Use this path when the OS is already installed and you only want desktop and system branding.

```bash
sudo ./setup/os-changes/apply-ci-os-desktop.sh
```

Useful modes:

```bash
./setup/os-changes/apply-ci-os-desktop.sh --validate
sudo ./setup/os-changes/apply-ci-os-desktop.sh --wizard
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only wallpaper,session
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only plymouth,dconf,start-icon
```

This script orchestrates numbered steps in `setup/os-changes/common/`:

| Step | Purpose |
|---|---|
| `10-plymouth.sh` | Boot splash branding |
| `20-dconf-system.sh` | System GNOME/GDM defaults |
| `25-session-gsettings.sh` | Current-session GNOME settings |
| `30-wallpaper.sh` | CI-OS wallpaper install |
| `40-start-icon.sh` | Start icon replacement |
| `50-os-release.sh` | OS identity files |
| `60-motd.sh` | Login message |
| `65-kde-theme.sh` | Optional KDE color scheme |
| `80-validate-ci-theme.sh` | Read-only validation |

Official CI dark green palette:

| Token | Hex |
|---|---|
| Primary dark green | `#066c80` |
| Medium green | `#00a9a7` |
| Light green | `#72ddd4` |
| Deep green | `#1b4332` |

---

## Fresh Ubuntu Setup

Use this path to configure an already-installed Ubuntu machine with CI-OS tooling:

```bash
sudo ./scripts/setup-fresh-ubuntu.sh
```

The script is root-oriented and performs user-specific work as the real desktop user. It installs or configures:

- Docker CE and Docker group membership
- UV
- Homebrew
- asdf and Node.js `22.15.1`
- pnpm through Corepack
- Ollama and selected local models
- GitHub CLI
- cloudflared
- Chromium
- VS Code
- Companion Hub
- Ubuntu telemetry removal
- Tailscale when available
- LACT GPU tooling

When `scripts/ci-os-ai-setup.sh` is present, fresh setup benchmarks the machine and pulls a recommended Ollama model set instead of blindly pulling a large default model.

Important: this script downloads software from third-party repositories and modifies APT sources, user shell configuration, sudoers, services, groups, and installed desktop applications. Review it before running on production machines.

---

## Express Setup

CI-OS now has a lightweight Express Setup orchestrator that ties the privacy, AI benchmark, model recommendation, model install, and headless status surfaces together.

Local development usage:

```bash
./scripts/ci-os-express-setup.sh --dry-run --yes
```

Installed-system usage:

```bash
sudo ci-os-express-setup --yes
```

It writes:

| File | Purpose |
|---|---|
| `/var/lib/ci-os/setup-report.json` | Express Setup summary |
| `/var/lib/ci-os/express-setup.log` | Step-by-step setup log |
| `/var/lib/ci-os/privacy-status.json` | Telemetry/privacy status |
| `/var/lib/ci-os/benchmark.json` | AI hardware benchmark |
| `/var/lib/ci-os/model-recommendations.json` | Ollama model recommendations |
| `/var/lib/ci-os/headless-status.json` | Headless setup service/network status |

Useful options:

| Option | Effect |
|---|---|
| `--yes` | Pull recommended Ollama models without prompting |
| `--dry-run` | Show the orchestration plan and write a report without making changes |
| `--skip-models` | Skip model installation |
| `--skip-privacy` | Skip privacy enforcement |

---

## Privacy and Telemetry

CI-OS privacy controls are exposed as installed commands:

| Command | Purpose |
|---|---|
| `ci-os-privacy-status` | Reports telemetry package, hold, domain-block, and MOTD news state |
| `sudo ci-os-privacy-apply` | Removes/holds telemetry packages, blocks telemetry domains, and disables MOTD news/help text |

Local development usage:

```bash
./scripts/ci-os-privacy.sh status
```

Installed-system usage:

```bash
ci-os-privacy-status
sudo ci-os-privacy-apply
```

The privacy layer targets `ubuntu-report`, `popularity-contest`, `apport`, `whoopsie`, `apport-symptoms`, `landscape-common`, Ubuntu metrics/popcon domains, and MOTD news/help scripts.

---

## AI Benchmark and Model Recommendations

CI-OS now includes the first piece of the smart AI setup path: a hardware-aware benchmark and Ollama model recommendation helper. The ISO builder installs it into the image as:

| Command | Purpose |
|---|---|
| `ci-os-benchmark` | Collect CPU, RAM, disk, GPU, VRAM, OS, kernel, and Ollama readiness into `benchmark.json` |
| `ci-os-model-recommend` | Convert benchmark results into a model tier and recommended Ollama model list |
| `ci-os-model-install` | Pull the default recommended Ollama model set; supports `--dry-run`, `--yes`, and `--include-optional` |

Local development usage:

```bash
./scripts/ci-os-ai-setup.sh benchmark
./scripts/ci-os-ai-setup.sh recommend
./scripts/ci-os-ai-setup.sh install --dry-run
```

Installed-system usage:

```bash
ci-os-benchmark
ci-os-model-recommend
sudo ci-os-model-install --yes
```

Output files:

| File | Purpose |
|---|---|
| `/var/lib/ci-os/benchmark.json` | Root/system benchmark output |
| `/var/lib/ci-os/model-recommendations.json` | Root/system recommendation output |
| `~/.local/state/ci-os/benchmark.json` | Non-root benchmark output |
| `~/.local/state/ci-os/model-recommendations.json` | Non-root recommendation output |

Recommendation tiers are intentionally conservative:

| Tier | Typical Hardware | Default Model Set |
|---|---|---|
| Small | Less than 12 GB RAM | `nomic-embed-text`, `gemma3:1b`, `qwen2.5:1.5b` |
| Balanced | 12-23 GB RAM | `nomic-embed-text`, `gemma3:1b`, `llama3.2:3b`, `qwen2.5:3b` |
| Workstation | 24-47 GB RAM | `nomic-embed-text`, `gemma3:1b`, `llama3.1:8b`, `qwen2.5:7b` |
| Large | 48 GB+ RAM | `nomic-embed-text`, `gemma3:1b`, `llama3.1:8b`, `qwen2.5:14b` |

Optional models are kept out of the default install unless `--include-optional` is passed.

---

## Headless Device WiFi Setup

Use this path to create a setup-mode package for devices that need first-time WiFi configuration through a captive portal.

### Build and Install

```bash
cd setup/headless
./build.sh
sudo dpkg -i setup-device_*.deb
```

### Runtime Stack

| Component | Purpose |
|---|---|
| `setup-network-monitor.service` | Watches connectivity and starts setup mode when internet is unavailable |
| `setup-device-hotspot-start.sh` | Switches WiFi adapter into AP mode and starts the portal stack |
| `hostapd-setup.service` | Broadcasts `Companion-Setup` hotspot |
| `dnsmasq-setup.service` | Provides DHCP/DNS and captive DNS redirect |
| `nginx.service` | Serves the setup portal and proxies `/api/*` |
| `setup-backend.service` | Flask backend for status, WiFi scan, and WiFi configuration |
| NetworkManager | Creates and activates the selected WiFi profile |
| `ci-os-headless-status` | Reports service, route, WiFi interface, gateway, and portal state |

Default setup network:

| Setting | Value |
|---|---|
| SSID | `Companion-Setup` |
| AP password | `SetupDevice123` |
| Gateway | `192.168.99.1` |
| DHCP range | `192.168.99.10` - `192.168.99.250` |
| Portal | `http://setup.ci.computer` or `http://192.168.99.1` |
| Assumed WiFi interface | `wlp192s0` |

Key API endpoints:

| Endpoint | Method | Purpose |
|---|---|---|
| `/health` | `GET` | Backend health check |
| `/api/status` | `GET` | Setup and Hub registration status |
| `/api/scan-networks` | `GET` | Nearby WiFi scan results |
| `/api/configure` | `POST` | Submit SSID, password, and optional pairing code |

Installed status command:

```bash
ci-os-headless-status
ci-os-headless-status --json
```

---

## CI/CD

The GitHub Actions workflow at `.github/workflows/build-companion-os-iso.yml` builds ISO artifacts:

- Manually through workflow dispatch
- On `v*` tags
- Weekly on Sunday at 02:00 UTC

The workflow downloads the Ubuntu base ISO, installs build dependencies, runs `build-iso.sh`, generates checksums and a simple SBOM, uploads artifacts, and creates a GitHub release for tags or manual runs.

---

## Ubuntu 26.04 Planning

CI-OS currently targets Ubuntu 24.04 Noble. Ubuntu 26.04 LTS is Resolute Raccoon, released on April 23, 2026, and listed as a supported LTS release by Ubuntu. Updating CI-OS for Ubuntu 26.04 should be treated as a compatibility project, not a simple version string bump, because the ISO builder depends on Ubuntu Desktop installer behavior, casper layer names, Subiquity/curtin assumptions, Yaru/GDM resources, snap seed behavior, and first-boot service timing.

Official references:

| Reference | Use |
|---|---|
| [Ubuntu 26.04 LTS release notes](https://documentation.ubuntu.com/release-notes/26.04/) | Release date, codename, support lifecycle, requirements, upgrade guidance |
| [Ubuntu releases index](https://releases.ubuntu.com/releases/) | Current ISO availability and release directory names |

Recommended migration phases:

| Phase | Work | Exit Criteria |
|---|---|---|
| Discovery | Compare Ubuntu 26.04 Desktop ISO layout, `casper/` layers, manifests, installer config, boot entries, Yaru resources, and package names | Documented diff against Ubuntu 24.04 assumptions |
| Build tooling | Update `BASE_ISO_URL`, default ISO names, dependency list, layer extraction/repack logic, and `install-sources.yaml` generation | ISO builds locally from Ubuntu 26.04 base media |
| Chroot customization | Validate identity handling, snap seed constraints, first-boot rebrand, first-boot setup, package installs, and desktop-provision whitelabel paths | Customized rootfs boots live session and launches installer |
| Branding | Rebuild GDM/Yaru gresource patches for Ubuntu 26.04 assets and verify Plymouth, GNOME, GDM, wallpaper, start icon, KDE, MOTD | Visual branding passes validation on live and installed systems |
| Headless setup | Re-test NetworkManager, hostapd, dnsmasq, nginx, Flask backend, captive portal detection, Hub registration, and WiFi interface configuration | Headless device can provision WiFi on Ubuntu 26.04 |
| Release assurance | Add checksum verification, VM boot smoke tests, install smoke tests, package build checks, and rollback notes | CI can produce a signed, boot-tested Ubuntu 26.04 CI-OS artifact |

Primary files likely to change:

| Area | Files |
|---|---|
| ISO defaults and CI | `tools/iso-build/scripts/build-iso.sh`, `.github/workflows/build-companion-os-iso.yml`, `docs/guides/iso-build-guide.md` |
| Rootfs customization | `scripts/customize-chroot.sh`, `configs/packages/package-list.txt`, `configs/preseed/ci-os.preseed` |
| Branding | `setup/os-changes/`, `packages/ci-os-branding/`, `tools/iso-build/scripts/build-gdm-branding-gresource.sh`, `assets/` |
| First-boot tooling | `scripts/setup-fresh-ubuntu.sh`, `scripts/lib/`, generated first-boot setup in `scripts/customize-chroot.sh` |
| Headless setup | `setup/headless/setup-device/`, especially service units, netplan, hostapd/dnsmasq config, and backend assumptions |

See [architecture.MD](architecture.MD#ubuntu-2604-upgrade-plan) for the full architecture-level upgrade plan.

---

## Assessment and Improvements

This repo has useful separation between ISO orchestration, chroot customization, installed-system branding, headless setup, and packaging. The strongest parts are the comments around Ubuntu installer compatibility, the preservation of Ubuntu IDs during installation, and the careful handling of layered squashfs metadata.

Recommended improvements:

| Area | Current State | Improvement |
|---|---|---|
| Hardware assumptions | Headless setup hardcodes `wlp192s0` | Detect WiFi interface dynamically or set it in `/etc/setup-device/device.conf` |
| Setup hotspot security | Fixed AP password `SetupDevice123` | Generate per-device SSID/password and print or display it during provisioning |
| Secrets | `scripts/lib/postgresql-setup.sh` contains a hardcoded password | Move secrets to env/config files and document rotation |
| Privilege scope | Several services and scripts run as root | Add least-privilege service users where possible |
| Script duplication | Fresh setup logic appears both in `setup-fresh-ubuntu.sh` and generated first-boot setup | Consolidate shared install functions or generate from one source |
| Testing | Mostly manual validation scripts | Add shellcheck, package-build checks, Python tests for setup backend, and ISO smoke tests |
| Package maturity | `companion-agents` and `companion-memory` are placeholder metapackages | Document roadmap or remove until real dependencies exist |
| Runtime configuration | Cloud endpoints and setup constants are partly embedded | Centralize in `device.conf` and systemd environment files |
| Artifact integrity | Checksums are generated; signing is optional | Make signing and base ISO checksum verification standard in release builds |
| Documentation drift | Multiple docs overlap | Keep README as overview and architecture.MD as the canonical system map |

---

## Documentation

- [architecture.MD](architecture.MD) - system assessment, architecture diagrams, flow charts, tables, and improvement plan
- [docs/guides/iso-build-guide.md](docs/guides/iso-build-guide.md) - ISO build details
- [docs/guides/installation-guide.md](docs/guides/installation-guide.md) - end-user installation guide
- [docs/guides/quick-start-guide.md](docs/guides/quick-start-guide.md) - quick operator guide
- [docs/guides/package-repository-setup.md](docs/guides/package-repository-setup.md) - package repository setup
- [docs/guides/gdm-branding-package.md](docs/guides/gdm-branding-package.md) - GDM branding package guide
- [tools/iso-build/README.md](tools/iso-build/README.md) - ISO build script reference

---

## Support

- Issues: https://github.com/companionintelligence/CI-OS/issues
- Website: https://ci.computer

© Companion Intelligence — Lifescope Inc
