## Companion Intelligence OS
### UnCloud Linux · a multi-distro Companion Intelligence appliance builder

![CI OS Logo](assets/logos/ci-holo-depth.png)

**© Companion Intelligence — Lifescope Inc**  
Companion OS uses the [PolyForm Noncommercial License 1.0.0](LICENSE.md). See the [License FAQ](License-FAQ.md).

---

## Contents

1. [Interface](#interface)
2. [What this repo is](#what-this-repo-is)
3. [One-command setup (flashed Ubuntu)](#one-command-setup-flashed-ubuntu)
4. [Four ways to customize Ubuntu](#four-ways-to-customize-ubuntu)
5. [Build a branded CI-OS ISO](#build-a-branded-ci-os-iso)
6. [Provision a fresh / existing Ubuntu](#provision-a-fresh--existing-ubuntu)
7. [Apply CI desktop branding to a running system](#apply-ci-desktop-branding-to-a-running-system)
8. [Headless device WiFi setup](#headless-device-wifi-setup)
9. [Repo layout](#repo-layout)
10. [Documentation](#documentation)

---

## One-command setup (flashed Ubuntu)

On a machine freshly flashed with Ubuntu, `scripts/bootstrap-ci-os.sh` wraps the
[fresh-Ubuntu provisioning](#provision-a-fresh--existing-ubuntu) and
[desktop branding](#apply-ci-desktop-branding-to-a-running-system) steps below,
plus the [headless WiFi setup](#headless-device-wifi-setup) package, into a single
command:

```bash
git clone https://github.com/companionintelligence/CI-OS.git && cd CI-OS && sudo ./scripts/bootstrap-ci-os.sh --yes
```

Then **reboot** to see the Plymouth boot splash and full branding. Run without
`--yes` for an interactive mode that prompts before each step and the reboot.

| Option | Description |
|--------|-------------|
| `--no-headless` | Skip headless WiFi setup |
| `--no-rebrand` | Skip branding |
| `--yes`, `-y` | Non-interactive (skip prompts, no reboot) |
| `--no-reboot` | Skip reboot prompt |

Steps are idempotent, so a failed run (e.g. no internet for the headless step's
`apt` dependencies) can simply be re-run.

---

## Interface

The only user-facing surface CI-OS ships is **"Connect Companion Core"**, the headless
WiFi setup portal — the captive page a new appliance serves over its own access point on
first boot, so you can hand it your WiFi credentials and pairing code from any phone or
laptop. It is one page whose several states are driven entirely by the on-device setup
backend (`/opt/setup-backend/setup_service.py`); the gallery below walks through each of
them, captured at phone width since that's how this page is actually seen.

It is a **single-theme (dark) captive portal by design** — there is no light mode and no
theme toggle. It's built on the
[Companion Intelligence design system](https://github.com/companionintelligence/CI-Common/tree/main/style)'s
canonical dark tokens (`@companionintelligence/tokens` `tokens.css`) and the self-hosted
**Manrope** variable font (`@companionintelligence/fonts`) — Montserrat and the retired
teal `--primary` (`#0f717a`) are gone. Text and the primary buttons are pushed to pure
white on top of that base, with the canonical phthalo→aqua brand gradient reserved for a
top accent strip, an ambient background glow, and colored focus rings, and a card
entrance transition on load (all motion respects `prefers-reduced-motion`).

> **How these were captured.** The portal HTML/CSS/JS in
> [`setup/.../var/www/setup-portal/`](setup/headless/setup-device/var/www/setup-portal/)
> renders offline; each screen was shot headlessly with Playwright at an iPhone-width
> viewport. The states below the first one are normally reached in response to the setup
> backend (`/api/status`, `/api/scan-networks`, `/api/configure`). To capture them without
> a live appliance, those backend responses were stubbed **only to trigger the portal's
> own rendering code paths** — the layout, styling, and copy are exactly what the shipped
> page produces. Sample network names (`Companion-Home`, `Studio-5G`, …) stand in for a
> real `nmcli` scan. No pixels are hand-drawn or faked. A short walkthrough video (9:16)
> of the golden path — pairing code → network scan → password → success — is linked from
> the PR that introduced this gallery.

### First-boot form (pairing required)

The default state on first boot: a pairing-code field, the WiFi-network selector, a
password field, and **Configure Device**. A background scan runs on load, so the network
count populates automatically.

<p align="center">
  <img src="docs/ui/setup-portal-dark.png" alt="CI-OS setup portal — first-boot pairing form (dark)" width="320">
</p>

### Network scan results

Tapping **Scan** (or the automatic scan on load) fills the selector with nearby networks,
sorted by signal strength, with the signal percentage beside each SSID.

<p align="center">
  <img src="docs/ui/setup-portal-networks-dark.png" alt="CI-OS setup portal — expanded scanned-network list (dark)" width="320">
</p>

### Manual network entry

Choosing **Enter network manually…** reveals a free-text field for hidden or
out-of-range SSIDs.

<p align="center">
  <img src="docs/ui/setup-portal-manual-dark.png" alt="CI-OS setup portal — manual SSID entry (dark)" width="320">
</p>

### No-pairing variant

When the backend reports `require_pairing: false` (via `/api/status`), the pairing-code
field is hidden and the flow drops straight to network selection.

<p align="center">
  <img src="docs/ui/setup-portal-nopairing-dark.png" alt="CI-OS setup portal — pairing-not-required variant (dark)" width="320">
</p>

### Success

After the backend accepts the configuration, the portal shows a success banner and
counts down to the redirect target (the Portal, `https://portal.ci.computer`) while the
button shows a **Configuring…** spinner.

<p align="center">
  <img src="docs/ui/setup-portal-success-dark.png" alt="CI-OS setup portal — configuration success (dark)" width="320">
</p>

### Error

If configuration fails (bad pairing code, wrong password, backend/network error) the
portal surfaces an inline error and re-enables the form for another attempt.

<p align="center">
  <img src="docs/ui/setup-portal-error-dark.png" alt="CI-OS setup portal — configuration error (dark)" width="320">
</p>

> **Backend-gated / not shown.** CI-OS ships no other rendered UI. Everything else the OS
> does — the ISO build, the branding scripts, the setup service itself — is CLI/systemd
> with no graphical surface, so there are no additional screens to capture. The scan-list,
> success, and error states above require the on-device setup backend at runtime; they are
> reproduced here from the portal's own render paths, not from a live appliance.

---

## What this repo is

CI-OS builds and themes the Companion Intelligence appliance **across multiple Linux
distros** — Ubuntu (the reference implementation today), Linux Mint, Fedora, Arch, Bazzite,
and NixOS — and provisions the CI ecosystem (Docker, dev tooling, local LLMs, CI-Hub) on top
of each. Shared theming/provisioning logic lives in `core/`; each distro's actual
build/install mechanism lives in `backends/<distro>/`. See
[`docs/architecture/multi-distro-design.md`](docs/architecture/multi-distro-design.md) for the
full design and rollout plan.

An earlier version of this repo described itself as "Companion Ubuntu" — provisioning and
branding scripts that only ran on stock Ubuntu 24.04 LTS. That framing is superseded: Ubuntu
is still the most mature, reference backend, but it's one of six, not the whole project.

Scripts typically apply:

- a CI-OS identity and teal/phthalo/sage rebrand (GRUB, Plymouth, GDM/GNOME Shell or the
  distro's native DE, MOTD, wallpaper, `os-release`),
- distro telemetry and bloatware removed,
- AMD GPU / ROCm support where applicable (Strix Halo / gfx1151 via ROCm **7.2.4**), and
- the full CI developer + appliance stack (Docker, Node, Ollama, CI-Hub, …), driven by one
  shared manifest (`core/manifest/ecosystem.yaml`) instead of per-distro hardcoded tool lists.

`core/` and the manifest are plain Bash + YAML with no distro assumptions. Individual
backends use their native tooling — **`backends/nixos/` is Nix by design**; the rest are not.
See the Stack section of `CLAUDE.md` for exactly which backend uses what.

---

## Four ways to customize Ubuntu

> The table below describes the **Ubuntu backend** specifically — still the most complete
> today. As other backends (`backends/mint/`, `backends/fedora/`, ...) land, each gets its own
> equivalent table in its own README; see
> [`docs/architecture/multi-distro-design.md`](docs/architecture/multi-distro-design.md) for
> the full per-backend rollout status. These paths are pre-refactor and still accurate; they
> are moving into `backends/ubuntu/` as that work lands.

| Goal | Entry point | Run on |
|------|-------------|--------|
| **A. Ship a branded installer ISO** | [`tools/iso-build/scripts/build-iso.sh`](tools/iso-build/scripts/build-iso.sh) | An Ubuntu 24.04 *build host* |
| **B. Turn a fresh/existing Ubuntu into a CI appliance** (dev + service stack) | [`scripts/setup-fresh-ubuntu.sh`](scripts/setup-fresh-ubuntu.sh) | The *target* machine, as root |
| **C. Re-skin a running Ubuntu desktop** (branding only, no packages) | [`setup/os-changes/apply-ci-os-desktop.sh`](setup/os-changes/apply-ci-os-desktop.sh) | The *target* machine, as root |
| **D. First-time headless WiFi onboarding** (captive portal) | [`setup/headless/build.sh`](setup/headless/build.sh) → `.deb` | The *target* device |

**How A relates to B and C:** the ISO builder (A) bakes the branding (C) directly
into the squashfs and embeds the provisioning script (B) at
`/usr/lib/ci-os/bootstrap/`. When someone installs the ISO, two systemd units fire
on first boot:

- `ci-os-first-boot-rebrand.service` — rewrites `os-release` IDs to `ci-os`.
- `ci-os-first-boot-setup.service` — runs the embedded `setup-fresh-ubuntu.sh` once (idempotent, network-failure-tolerant) to install the full stack.

So a clean ISO install ends up identical to running B + C by hand. Use B/C directly
when you want to convert a machine you already have without reimaging it.

---

## Build a branded CI-OS ISO

Produces a bootable, installable `companion-os-<version>-amd64.iso` from a stock
Ubuntu 24.04 Desktop ISO. This is the primary "customize Ubuntu" workflow.

### Build-host requirements

The build host **must be Ubuntu 24.04 (Noble) with the Yaru theme installed** — the
branding step extracts the Yaru GNOME Shell gresource from the host, so its version
must match the target. You also need **~30 GB free** and **root**.

```bash
sudo apt-get install \
  squashfs-tools xorriso glib2.0-bin libglib2.0-bin \
  yaru-theme-gnome-shell debootstrap rsync gpg
```

### Quick start

```bash
# 1. Download the Ubuntu 24.04 base ISO (any 24.04.x point release works)
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso

# 2. Build — single entry point, runs as root
sudo ./tools/iso-build/scripts/build-iso.sh \
  --base-iso ./ubuntu-24.04.4-desktop-amd64.iso
```

Output: `./output/companion-os-1.0-amd64.iso` (+ `SHA256SUMS` / `MD5SUMS`).

`build-iso.sh` runs in two steps: it first builds the `.deb` packages and the
branded GNOME Shell gresource (`build-packages.sh`), then extracts the base ISO,
runs [`scripts/customize-chroot.sh`](scripts/customize-chroot.sh) on the rootfs
(identity, telemetry removal, branding, GRUB, ROCm helper, installer whitelabel,
MOTD, first-boot bootstrap), and repacks a bootable ISO with `xorriso`.

### Common flags

| Flag | Default | Description |
|------|---------|-------------|
| `--base-iso PATH` | *(required)* | Path to the Ubuntu 24.04 Desktop ISO |
| `--output-dir PATH` | `./output` | Where the finished ISO is written |
| `--work-dir PATH` | `./work` | Scratch space (~25 GB) |
| `--version VERSION` | `1.0` | CI-OS version embedded in the ISO |
| `--skip-packages` | off | Reuse existing `.deb`s/gresource (fast iteration on chroot changes only) |
| `--clean` | off | Wipe the work directory first |
| `--sign` | off | GPG-sign `SHA256SUMS` / `MD5SUMS` |

Full reference, branding color map, and iterative-dev tips:
**[`tools/iso-build/README.md`](tools/iso-build/README.md)** and the
**[ISO Build Guide](docs/guides/iso-build-guide.md)**.

### Features baked into the ISO

✅ **Ubuntu rebranded as CI-OS** — GRUB, Plymouth, GDM/GNOME Shell, MOTD, `os-release`  
✅ **Privacy first** — telemetry removed, metric endpoints blocked  
✅ **AMD GPU ready** — ROCm 7.2.4 helper (`--no-dkms` on Strix Halo / gfx1151) 
✅ **CI teal / dark-green theme** — `#00a9a7`, `#066c80`, `#72ddd4`, `#1b4332`  
✅ **Full stack on first boot** — Docker, Node (asdf), Ollama, VS Code, Companion Hub  
✅ **Bootable** — inherits BIOS + UEFI + Secure Boot from the base ISO

### CI/CD

ISOs build automatically via [`.github/workflows/build-companion-os-iso.yml`](.github/workflows/build-companion-os-iso.yml):

- **Weekly** — Sundays at 2 AM UTC
- **On tags** — push a `v*` tag to trigger a release
- **Manual** — Workflow dispatch (choose version + optional GPG signing)

---

## Provision a fresh / existing Ubuntu

Convert any Ubuntu 24.04 machine into a CI appliance without reimaging. This is the
same script the ISO runs on first boot, so it is **idempotent** — safe to re-run.

For a typical desktop machine, the full setup flow is:

1. Run `scripts/setup-fresh-ubuntu.sh` with `sudo` (this section)
2. Run `setup/os-changes/apply-ci-os-desktop.sh` with `sudo` ([next section](#apply-ci-desktop-branding-to-a-running-system))
3. Reboot after both scripts complete

```bash
chmod +x ./scripts/setup-fresh-ubuntu.sh
sudo ./scripts/setup-fresh-ubuntu.sh
```

Requires root. Installs and configures (in order):

- **Docker** (engine + compose, adds your user to the `docker` group)
- **uv** (Python), **Homebrew**, **make**
- **Node.js via asdf** (with corepack/pnpm), sets a global Node version
- a dedicated **`ci`** service user
- **GitHub CLI**, **cloudflared**, **Tailscale**
- **Ollama** (service + pulls default models)
- **Chromium** and **VS Code** (Snap fallback if apt fails)
- **Companion Hub** (+ autostart)
- **telemetry removal** (`scripts/lib/remove-telemetry.sh`)
- **ROCm 7.2.4** (`scripts/install-rocm-driver.sh`, non-fatal) — Strix Halo / Ryzen AI Max uses official `--no-dkms` inbox amdgpu; other AMD GPUs may use DKMS — and **LACT** GPU monitor
- **Strix Halo unified-memory boot params** (`scripts/lib/strix-halo-boot-params.sh`, non-fatal) — see note below
- GNOME power profile set to *performance*

After it finishes, log out/in (or `newgrp docker`) so group changes take effect.
Shared helpers live in [`scripts/lib/`](scripts/lib/); package/tooling details are
in the script header.

> **Note:** Bun is no longer installed by this script.

> **AMD Strix Halo (Ryzen AI Max) unified memory.** On confidently-detected
> Strix Halo-class hardware (Ryzen AI Max / gfx1151 / Radeon 8060S) with a
> large-RAM configuration, setup adds `iommu=pt amdgpu.gttsize=<N>
> ttm.pages_limit=<M>` to `GRUB_CMDLINE_LINUX_DEFAULT` so the amdgpu driver
> can address most of system RAM as GPU-visible GTT memory instead of a small
> fixed VRAM carve-out — needed for local-LLM/ROCm/Vulkan workloads on these
> unified-memory APUs. `<N>`/`<M>` scale with total RAM; see the script
> header for the exact formula. It's a no-op on everything else, and a
> **reboot is required** for the new boot params to take effect. This only
> covers the OS/kernel side — the BIOS-side integrated-graphics UMA/VGM
> framebuffer size also matters and can't be set from software; set it to
> its smallest option (e.g. 1 GiB) in firmware setup rather than a large
> static carve-out.

---

## Apply CI desktop branding to a running system

Branding only — no packages, no stack. Use this to re-skin a desktop you already
have. All steps live under `setup/os-changes/common/*.sh` and run in a fixed order:
**plymouth → dconf → terminal → wallpaper → session → start-icon → os-release → motd** (+ optional **kde**).
Assets sit beside the script. Dock defaults: **left**, **autohide** (dismissable).
Reboot once after applying for Plymouth to take effect.

```bash
# Full apply
chmod +x ./setup/os-changes/apply-ci-os-desktop.sh
sudo ./setup/os-changes/apply-ci-os-desktop.sh

# Reboot after both main setup scripts finish
sudo reboot

# Interactive: prompts, optional KDE, validation, optional reboot
sudo ./setup/os-changes/apply-ci-os-desktop.sh --wizard

# CI / non-interactive: full apply + validate (no KDE, no reboot prompt)
sudo ./setup/os-changes/apply-ci-os-desktop.sh --wizard --yes

# Run only specific steps
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only wallpaper,session
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only plymouth,dconf
sudo ./setup/os-changes/apply-ci-os-desktop.sh --wizard --yes --with-kde

# Read-only checks (no sudo)
./setup/os-changes/apply-ci-os-desktop.sh --validate
```

Session-only tweaks for the current user (no sudo, no system changes):
[`configs/desktop/gnome-settings.sh`](configs/desktop/gnome-settings.sh).

**Palette:** `#00a9a7`, `#066c80`, `#72ddd4`, `#1b4332` — see the
**[Dark Green Theme Guide](docs/dark-green-theme-guide.md)**.
**Assets:** `LogoMark_Color_StartIcon-cropped.svg` (start icon),
`background.png` → `/usr/share/backgrounds/ci-os-wallpaper.*`,
`Logo_Banner_Color.png` (Plymouth). The icon/wallpaper steps back up the Ubuntu
originals under `/usr/share/icons/ubuntu-backup-*` and `/usr/share/backgrounds/ubuntu-backup-*`.

---

## Headless device WiFi setup

First-time WiFi onboarding for a headless device via a **captive portal**: the
device broadcasts a hotspot when it has no network; you connect, open the portal,
enter a pairing code + WiFi credentials, and the device joins your network and
stops the hotspot.

### Stack

- **hostapd** — WiFi AP (SSID: `Companion-Setup`)
- **dnsmasq** — DHCP (192.168.99.0/24) + DNS redirect for the captive portal
- **nginx** — serves the portal and proxies the API
- **Flask backend** — WiFi scan, validation, NetworkManager integration
- **setup-network-monitor** — starts the hotspot when **both** Ethernet and WiFi are down

### Build and install

```bash
cd setup/headless
./build.sh
sudo dpkg -i setup-device_*.deb
```

Verify:

```bash
systemctl status setup-backend.service setup-network-monitor.service \
  hostapd-setup.service dnsmasq-setup.service nginx.service
sudo cat /etc/setup-device/pairing_code.json
```

### Quick usage

1. **Hotspot:** `Companion-Setup` — password: `SetupDevice123`
2. **Portal:** https://setup.ci.computer or http://192.168.99.1 (may open automatically)
3. **Pairing code:** from `/etc/setup-device/pairing_code.json` (root-only). There is no
   built-in test code. For development only, set `SETUP_TEST_PAIRING_CODE=<your code>`
   in the `setup-backend` unit; the service logs a warning at startup while it is set,
   and it must never be set on a shipped device.
4. **Form:** pick WiFi, enter password, submit. The device connects and stops the hotspot.

| Setting | Value |
|---------|-------|
| Gateway | 192.168.99.1 |
| DHCP range | 192.168.99.10–250 |
| Portal URL | https://setup.ci.computer |

**Key paths:** config in `/etc/{hostapd,dnsmasq.d,nginx,setup-device}/`;
backend `/opt/setup-backend/setup_service.py`; portal `/var/www/setup-portal/`;
completion flag `/var/lib/setup-device/setup-complete`.

**When the hotspot starts:** `setup-network-monitor.service` checks every ~3 s and
brings the hotspot up ~6 s after both interfaces disconnect. To trigger manually:

```bash
sudo nmcli connection down --active      # wait ~10 s for the monitor, or:
sudo systemctl start hostapd-setup.service dnsmasq-setup.service
```

**Reset and re-run:** `sudo rm /var/lib/setup-device/setup-complete`, restart
`setup-network-monitor.service`, then disconnect the network. Full walkthrough:
[`docs/Create-headless-setup.md`](docs/Create-headless-setup.md).

### What a printed QR code may carry

No sticker ships today. This is the rule for when one does, because a QR printed
on an appliance is unlike every other QR we render: **it cannot rotate and it
cannot expire.** Whatever is in the ink stays valid for the life of the box, on
every unit that rolled off the same run, readable by anyone who gets a look at
the case — a courier, a housemate, a photo posted online.

**A printed code MAY carry:**

- A non-secret per-unit serial.
- A Portal claim URL for that serial (`https://portal.companionintelligence.com/...`).

**A printed code MUST NOT carry:**

- Any long-lived key, API token, or device secret.
- Wi-Fi credentials. The setup hotspot PSK is the shared default `SetupDevice123`
  (`etc/hostapd/hostapd-setup.conf:12`, whose own comment says "change password
  for production" — and `setup-device-hotspot-start.sh` regenerates the same
  constant at runtime). Printing it on every box turns a default credential into
  a *physically permanent* fleet-wide one: you cannot recall ink, so no later
  rotation can ever fully retire it.
- Anything still valid after the first claim. The claim must burn the payload.

**Do not ship a hotspot QR until the SSID is per-device.** `device.conf:5`
reserves `SERIAL_SUFFIX` for exactly this and is currently empty and read by
nothing; the live SSID suffix is instead drawn fresh from `/dev/urandom` on
*every boot* (`Companion-Setup-XXXX`), so no printed label can name the network
it is supposed to join. Ship the hotspot QR only together with the stable
per-device SSID that `SERIAL_SUFFIX` was reserved for.

**Always print the URL in human-readable text beside the code**, on a domain the
user can verify by eye. A QR is opaque to the person scanning it, so an attacker
who sticks their own label over ours redirects the scan and nobody can tell —
that swap is the whole of the "quishing" attack. Legible text next to the code is
what lets a user notice the destination is wrong.

Changing the hostapd defaults is a separate product decision with fleet
implications and is deliberately **not** made here.

---

## Repo layout

```
├── .github/workflows/        # CI/CD: build-companion-os-iso.yml
├── assets/                    # Logos, wallpapers, theme assets
├── config/
│   └── packages.chroot/       # Legacy live-build staging (stale — see tools README)
├── configs/                   # Boot, desktop, packages, preseed, post-install scripts
│   ├── boot/                  # grub-default
│   ├── desktop/               # CI-OS-Dark.colors, gnome-settings.sh (session-only)
│   ├── packages/              # package-list.txt
│   ├── preseed/               # ci-os.preseed
│   └── scripts/               # ci-os-customization.sh (Cubic-style post-install)
├── docs/
│   ├── guides/                # ISO build, installation, quick start, repo setup, GDM branding
│   └── *.md                   # theme guide, headless setup, quick reference, impl summary
├── packages/                  # .deb sources
│   ├── ci-os-branding/        # Branded GNOME Shell gresource (regenerated by build)
│   ├── companion-os-base/
│   ├── companion-os-keyring/
│   ├── companion-agents/
│   └── companion-memory/
├── scripts/
│   ├── setup-fresh-ubuntu.sh  # B: provision a machine / first-boot bootstrap
│   ├── customize-chroot.sh    # called by the ISO builder against the rootfs
│   ├── install-rocm-driver.sh # AMD ROCm/amdgpu (standalone or hooked)
│   └── lib/                   # shared helpers (docker, nodejs, ollama, postgres, os-release, telemetry)
├── setup/
│   ├── os-changes/            # C: apply-ci-os-desktop.sh + common/*.sh + assets
│   ├── headless/              # D: captive-portal WiFi onboarding (build.sh → .deb)
│   ├── CI-OS-Hub-Setup/       # install-or-update-hub.sh + staging env notes
│   └── CI-Server/             # Server staging env notes
└── tools/
    └── iso-build/             # A: build-iso.sh, build-packages.sh, gresource + repo helpers
        ├── scripts/
        └── README.md          # ISO build + branding reference
```

---

## Documentation

### Building & installing
- **[ISO Build Guide](docs/guides/iso-build-guide.md)** — build custom ISOs
- **[Tools README](tools/iso-build/README.md)** — script reference, branding color map, iterative dev
- **[Installation Guide](docs/guides/installation-guide.md)** — install CI-OS
- **[Quick Start Guide](docs/guides/quick-start-guide.md)** — get going fast

### Branding & theming
- **[Dark Green Theme Guide](docs/dark-green-theme-guide.md)** — palette, assets, dconf
- **[GDM Branding Package](docs/guides/gdm-branding-package.md)** — how the gresource is built

### Devices & packages
- **[Headless Setup Guide](docs/Create-headless-setup.md)** — captive-portal onboarding
- **[Package Repository Setup](docs/guides/package-repository-setup.md)** — host your own `.deb` repo

---

## Support

- **Issues**: https://github.com/companionintelligence/CI-OS/issues
- **Website**: https://ci.computer

© Companion Intelligence — Lifescope Inc
</content>
</invoke>
