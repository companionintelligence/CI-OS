## Companion OS
### UnCloud Linux · the Companion Intelligence appliance OS, for Ubuntu 26.04 LTS and CachyOS

![Companion OS logo](assets/logos/2024_CI__LogoMark_Color_med.svg)

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

On a machine freshly flashed with Ubuntu, `backends/ubuntu/provision/bootstrap-ci-os.sh` wraps the
[fresh-Ubuntu provisioning](#provision-a-fresh--existing-ubuntu) and
[desktop branding](#apply-ci-desktop-branding-to-a-running-system) steps below,
plus the [headless WiFi setup](#headless-device-wifi-setup) package, into a single
command:

```bash
git clone https://github.com/companionintelligence/CI-OS.git && cd CI-OS && sudo ./backends/ubuntu/provision/bootstrap-ci-os.sh --yes
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
> [`core/headless/payload/var/www/setup-portal/`](core/headless/payload/var/www/setup-portal/)
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

CI-OS builds and themes the Companion Intelligence appliance and provisions the CI ecosystem
(Docker, dev tooling, local LLMs, CI-Hub) on top of it. Shared theming/provisioning logic lives
in `core/`; each edition's actual build/install mechanism lives in `backends/<name>/`. See
[`docs/architecture/multi-distro-design.md`](docs/architecture/multi-distro-design.md) for the
design and rollout plan.

**Supported targets: Companion OS on Ubuntu 26.04 LTS (resolute) and Companion OS on CachyOS.**

Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from tag `pre-retire-multidistro-2026-10-17`, e.g. `git checkout pre-retire-multidistro-2026-10-17 -- backends/<name>`).

`backends/arch/` is **not** a supported target: it is the provisioning engine under CachyOS (see
[Arch provisioning engine](#arch-provisioning-engine-under-cachyos-not-a-supported-target)).

Scripts typically apply:

- a CI-OS identity and teal/phthalo/sage rebrand (GRUB, Plymouth, GDM/GNOME Shell or the
  distro's native DE, MOTD, wallpaper, `os-release`),
- distro telemetry and bloatware removed,
- AMD GPU / ROCm support where applicable (Strix Halo / gfx1151, with ROCm from the distribution's own
  package archive: Ubuntu 26.04's on the Ubuntu edition, Arch's `extra` repo on CachyOS), and
- the full CI developer + appliance stack (Docker, Node, Ollama, CI-Hub, …), driven by one
  shared manifest (`core/manifest/ecosystem.yaml`) instead of per-distro hardcoded tool lists.

`core/` and the manifest are plain Bash + YAML with no distro assumptions. Individual
backends use their native tooling (apt/dpkg on Ubuntu, pacman on CachyOS).
See the Stack section of `CLAUDE.md` for exactly which backend uses what.

---

## Four ways to customize Ubuntu

> The table below describes the **Ubuntu edition** (Companion OS on Ubuntu 26.04 LTS). The
> CachyOS edition has its own table in its own section further down; see
> [`docs/architecture/multi-distro-design.md`](docs/architecture/multi-distro-design.md) for the
> per-edition rollout status.

| Goal | Entry point | Run on |
|------|-------------|--------|
| **A. Ship a branded installer ISO** | [`backends/ubuntu/iso/scripts/build-iso.sh`](backends/ubuntu/iso/scripts/build-iso.sh) | An Ubuntu 26.04 *build host* (or a privileged `ubuntu:26.04` container) |
| **B. Turn a fresh/existing Ubuntu into a CI appliance** (dev + service stack) | [`backends/ubuntu/provision/provision.sh`](backends/ubuntu/provision/provision.sh) | The *target* machine, as root |
| **C. Re-skin a running Ubuntu desktop** (branding only, no packages) | [`backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh`](backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh) | The *target* machine, as root |
| **D. First-time headless WiFi onboarding** (captive portal) | [`backends/ubuntu/headless-package/build.sh`](backends/ubuntu/headless-package/build.sh) → `.deb` | The *target* device |

**How A relates to B and C:** the ISO builder (A) bakes the branding (C) directly
into the squashfs and embeds the provisioning script (B) at
`/usr/lib/ci-os/bootstrap/`. When someone installs the ISO, two systemd units fire
on first boot:

- `ci-os-first-boot-rebrand.service` — rewrites `os-release` IDs to `ci-os`.
- `ci-os-first-boot-setup.service` + `.timer` — runs the staged `provision.sh --tier=core` until it succeeds once: at every boot and every 15 minutes while pending (an offline first boot just waits for network), with at most 3 failed automatic provisioning runs. `sudo ci-os-setup` re-runs it at any time. Extended-tier tools (VS Code, Chromium, Homebrew, Companion Launcher) are not installed at first boot — run B manually with `--tier=extended` added for those.

So a clean ISO install ends up identical to running B + C by hand. Use B/C directly
when you want to convert a machine you already have without reimaging it.

### Arch provisioning engine (under CachyOS, not a supported target)

`backends/arch/` is not an edition of Companion OS and offers users no entry points of its own. It is
the pacman provisioning engine that the CachyOS edition reuses unchanged:

| What | Path | Used by |
|------|------|---------|
| **Provision the ecosystem** (pacman-native; same `--tier=`/`--step=ci-hub` flags as Ubuntu's) | [`backends/arch/provision/provision.sh`](backends/arch/provision/provision.sh) | Run at first boot by [`backends/cachyos/provision/provision.sh`](backends/cachyos/provision/provision.sh), a thin wrapper |
| **Headless WiFi dependency oracle** | [`backends/arch/headless-setup/install.sh`](backends/arch/headless-setup/install.sh) | Read, not run, by the setup-portal payload tests and the CachyOS ISO verifier; CachyOS installs the payload through `backends/cachyos/provision/stage-headless.sh` |

Package names live in [`core/manifest/role-map/pacman.yaml`](core/manifest/role-map/pacman.yaml). Only VS Code
(Microsoft's build is AUR-only) and Companion Launcher (no Arch build at all) stay stubbed, per the
platform's AUR-helper-automation deferral. `backends/arch/desktop-theme/` is unused: CachyOS is KDE Plasma
and brands itself through its own overlay (`backends/cachyos/iso/overlay`), so it is not an entry point.
The whole `backends/arch/` tree is frozen; change it only on an explicit decision.

### CachyOS edition (second supported target)

A live and installer ISO of Companion OS based on CachyOS: the pinned CachyOS-Live-ISO profile (archiso, KDE Plasma, online Calamares) plus a Companion OS overlay, built with the stock `mkarchiso` in a container. The installed system is built from the repositories at install time, so provisioning has three layers (live image, Calamares, first boot).

| Goal | Entry point | Run on |
|------|-------------|--------|
| **Build the ISO** | [`backends/cachyos/iso/scripts/build-iso.sh`](backends/cachyos/iso/scripts/build-iso.sh) | Any host with Docker (35 to 60 minutes) |
| **Verify an ISO** | [`backends/cachyos/iso/scripts/verify-iso.sh`](backends/cachyos/iso/scripts/verify-iso.sh) (run in the builder image) | The ISO, no root, no boot |
| **Provision the installed system** | [`backends/cachyos/provision/provision.sh`](backends/cachyos/provision/provision.sh) (wrapper around the Arch one) | The *target* machine, first boot |

See [`backends/cachyos/README.md`](backends/cachyos/README.md) and [`docs/architecture/cachyos-backend.md`](docs/architecture/cachyos-backend.md) for the decisions, the known limits (no Secure Boot, online install only, the Companion Stick can not boot it) and the test status.


---

## Build a branded CI-OS ISO

Produces a bootable, installable `companion-os-<version>-amd64.iso` from the stock
Ubuntu 26.04.1 LTS Desktop ISO. This is the primary "customize Ubuntu" workflow.

### Build-host requirements

The build host **must be Ubuntu 26.04 (Resolute) with the Yaru theme installed** — the
branding step extracts the Yaru GNOME Shell gresource from the host, so it has to be the
Yaru of the GNOME Shell 50 the image carries. `build-iso.sh` stops at the start on any other
host. You also need **~30 GB free** and **root**.

```bash
sudo apt-get install \
  squashfs-tools xorriso libglib2.0-bin libglib2.0-dev-bin \
  yaru-theme-gnome-shell rsync gpg cpio zstd initramfs-tools-core imagemagick librsvg2-bin curl
```

> **On a Mac or any other host that is not Ubuntu 26.04:** run the whole build inside a
> privileged `ubuntu:26.04` container (`docker run --privileged --platform linux/amd64 ...`)
> with the repo and the base ISO mounted. The requirements are in
> [`backends/ubuntu/iso/README.md`](backends/ubuntu/iso/README.md), and
> [`.github/workflows/build-companion-os-iso.yml`](.github/workflows/build-companion-os-iso.yml)
> does the same in CI, in a privileged `ubuntu:26.04` container. An older Ubuntu host or container
> is not a build host.

The build also needs network access (it installs the CI-Hub and wireless setup tools into the image).
After a build, `backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-*.iso` checks that they are
all there and that the branding is applied (see [`backends/ubuntu/iso/README.md`](backends/ubuntu/iso/README.md)).

### Quick start

```bash
# 1. Download the Ubuntu 26.04.1 base ISO (take the .1 file, not the 26.04.0 image listed next to it;
#    its SHA-256 is in backends/ubuntu/iso/README.md)
wget https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso

# 2. Build — single entry point, runs as root, on Ubuntu 26.04
sudo ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso ./ubuntu-26.04.1-desktop-amd64.iso
```

Output: `./output/companion-os-1.0-amd64.iso` (+ `SHA256SUMS` / `MD5SUMS`).

`build-iso.sh` runs in two steps: it first builds the `.deb` packages and the
branded GNOME Shell gresource (`build-packages.sh`), then extracts the base ISO,
runs [`backends/ubuntu/chroot/customize-chroot.sh`](backends/ubuntu/chroot/customize-chroot.sh) on the rootfs
(identity, telemetry removal, branding, GRUB, ROCm helper, installer whitelabel,
MOTD, first-boot bootstrap), and repacks a bootable ISO with `xorriso`.

### Common flags

| Flag | Default | Description |
|------|---------|-------------|
| `--base-iso PATH` | `./ubuntu-26.04.1-desktop-amd64.iso` | Path to the Ubuntu 26.04.1 Desktop ISO |
| `--output-dir PATH` | `./output` | Where the finished ISO is written |
| `--work-dir PATH` | `./work` | Scratch space (~25 GB) |
| `--version VERSION` | `1.0` | CI-OS version embedded in the ISO |
| `--skip-packages` | off | Reuse existing `.deb`s/gresource (fast iteration on chroot changes only) |
| `--clean` | off | Wipe the work directory first |
| `--sign` | off | GPG-sign `SHA256SUMS` / `MD5SUMS` |

Full reference, branding color map, and iterative-dev tips:
**[`backends/ubuntu/iso/README.md`](backends/ubuntu/iso/README.md)** and the
**[ISO Build Guide](docs/guides/iso-build-guide.md)**.

### Features baked into the ISO

✅ **Ubuntu rebranded as CI-OS** — GRUB, Plymouth, GDM/GNOME Shell, MOTD, `os-release`  
✅ **Privacy first** — telemetry removed, metric endpoints blocked  
✅ **AMD GPU ready** — `ci-os-install-rocm` installs ROCm from the Ubuntu 26.04 archive on Strix Halo / gfx1151, with the kernel's inbox amdgpu driver (no amdgpu-dkms)  
✅ **CI canon theme** — navy/phthalo/sage, sourced from `vendor/brand/tokens/tokens.sh`  
✅ **Core stack on first boot** — Docker, Node (asdf), Ollama+models, CI-Hub (`provision.sh --tier=core`); VS Code/Chromium/Homebrew/Companion Launcher are opt-in (`--tier=extended`)  
✅ **Bootable** — inherits BIOS + UEFI + Secure Boot from the base ISO

### CI/CD

ISOs build automatically via [`.github/workflows/build-companion-os-iso.yml`](.github/workflows/build-companion-os-iso.yml):

- **Weekly** — Sundays at 2 AM UTC
- **On tags** — push a `v*` tag to trigger a release
- **Manual** — Workflow dispatch (choose version + optional GPG signing)

---

## Provision a fresh / existing Ubuntu

Convert an Ubuntu 26.04 machine into a CI appliance without reimaging. This is the
same script the ISO runs on first boot (as `--tier=core`), so it is **idempotent** —
safe to re-run. What gets installed is controlled by `--tier` — see
`provision.sh`'s own header for the full core/extended/hardware breakdown; default
(no flags) is `--tier=core,hardware`.

For a typical desktop machine, the full setup flow is:

1. Run `backends/ubuntu/provision/provision.sh --tier=core,extended,hardware` with `sudo` (this section)
2. Run `backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh` with `sudo` ([next section](#apply-ci-desktop-branding-to-a-running-system))
3. Reboot after both scripts complete

```bash
chmod +x ./backends/ubuntu/provision/provision.sh
sudo ./backends/ubuntu/provision/provision.sh --tier=core,extended,hardware
```

Requires root. Installs and configures (in order), tagged by tier — see
[`core/manifest/ecosystem.yaml`](core/manifest/ecosystem.yaml) for the single source of
truth this list mirrors:

- **[core]** **Docker** (engine + compose, adds your user to the `docker` group), **make**
- **[core]** **uv** (Python)
- **[core]** **Node.js via asdf** (with corepack/pnpm), sets a global Node version
- **[core]** a dedicated **`ci`** service user
- **[core]** **GitHub CLI**, **cloudflared**, **Tailscale**
- **[core]** **Ollama** (service + pulls default models)
- **[core]** **CI Hub Service** — the Docker/Runtipi backend, gated on registry credentials (see `core/lib/ci-hub.sh`); reports a clear skip message and continues if unpaired
- **[core]** **telemetry removal** (`backends/ubuntu/lib/remove-telemetry.sh`)
- **[extended]** **Homebrew**
- **[extended]** **Chromium** and **VS Code** (Snap fallback if apt fails)
- **[extended]** **Companion Launcher** (+ autostart) — the desktop GUI app, distinct from the CI Hub Service backend above
- **[hardware, supported machines only]** **ROCm** (`backends/ubuntu/lib/install-rocm-driver.sh`, non-fatal) and **LACT**. The support rule is a Strix Halo-class APU (Ryzen AI Max / gfx1151 / Radeon 8060S) with at least ~32 GB of RAM. It installs `rocm`, `rocminfo` and `rocm-smi` from the Ubuntu 26.04 archive and uses the kernel's inbox amdgpu driver: no `amdgpu-dkms`, nothing from `repo.radeon.com`, and on any other Ubuntu release it stops with an error and installs nothing. Other hardware is left alone.
- **[hardware, auto-detected]** **Strix Halo unified-memory boot params** (`backends/ubuntu/lib/strix-halo-boot-params.sh`, non-fatal) — see note below
- GNOME power profile set to *performance*

After it finishes, log out/in (or `newgrp docker`) so group changes take effect.
Shared helpers live in [`backends/ubuntu/lib/`](backends/ubuntu/lib/); package/tooling details are
in the script header.

> **Note:** Bun is no longer installed by this script.

> **AMD Strix Halo (Ryzen AI Max) unified memory.** On hardware that passes
> the support rule (Ryzen AI Max / gfx1151 / Radeon 8060S, at least ~32 GB),
> setup adds `iommu=pt amdgpu.gttsize=<N>
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
have. All steps live under `backends/ubuntu/desktop-theme/*.sh` and run in a fixed order:
**plymouth → dconf → terminal → wallpaper → session → start-icon → about-logo → os-release → names → motd** (+ optional **kde**).
Assets sit beside the script. Dock defaults: **left**, **autohide** (dismissable).
Reboot once after applying for Plymouth to take effect.

The **about-logo** step (Settings > About) draws its two PNGs from the brand mark, so a stock desktop
needs `librsvg2-bin` (or `imagemagick`) installed first. Without either it warns, leaves the Ubuntu
wordmark in place and carries on with the other steps; install the package and run
`--only about-logo` to finish it.

The **names** step renames the Ubuntu display names that are still on screen: the sessions in
GDM's gear menu, the Settings sidebar entry (`gnome-ubuntu-panel.desktop`) and the dock, AppIndicators and
Tiling Assistant extension names. It edits only the `Name=`/`Comment=` (or JSON `"name"`) line, diverts the stock
file so an upgrade cannot bring it back, and leaves every file name, id and `Exec=` alone. The session
picker and the Settings entry change at the next login.

```bash
# Full apply
chmod +x ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh
sudo ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh

# Reboot after both main setup scripts finish
sudo reboot

# Interactive: prompts, optional KDE, validation, optional reboot
sudo ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh --wizard

# CI / non-interactive: full apply + validate (no KDE, no reboot prompt)
sudo ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh --wizard --yes

# Run only specific steps
sudo ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh --only wallpaper,session
sudo ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh --only plymouth,dconf
sudo ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh --wizard --yes --with-kde

# Read-only checks (no sudo)
./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh --validate
```

Session-only tweaks for the current user (no sudo, no system changes):
[`backends/ubuntu/desktop-theme/gnome-settings.sh`](backends/ubuntu/desktop-theme/gnome-settings.sh).

**Palette:** navy/phthalo/sage from the CI-Common canon
(`CI_LIGHT_PRIMARY`/`CI_DARK_PRIMARY`/`CI_DARK_BACKGROUND`, …) — see
**[assets/branding/brand-guidelines.md](assets/branding/brand-guidelines.md)**, the
canonical token table (the old dark-green `#00a9a7`/`#066c80`/`#72ddd4` "logo ramp"
palette this line used to list was replaced org-wide by CI-Common canon 1.0).
**Assets:** `vendor/brand/logos/mark-mono.svg` (the start icon is generated from it),
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
cd backends/ubuntu/headless-package
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

`core/` is distro-portable; each edition's actual build/install mechanism lives under
`backends/<name>/`. See
[`docs/architecture/multi-distro-design.md`](docs/architecture/multi-distro-design.md) for
the full rationale.

```
├── .github/workflows/          # CI/CD: build-companion-os-iso.yml, style-canon-lint.yml
├── assets/                     # Logos, wallpapers, brand-guidelines.md (raw design sources)
├── vendor/brand/                # Vendored CI-Common brand bundle: tokens, fonts, logos
├── core/                       # Distro-portable — no apt/dpkg (or any package manager) assumptions
│   ├── manifest/                # ecosystem.yaml: single source of truth for what gets installed
│   │   └── role-map/            # per-package-manager translations (apt.yaml, pacman.yaml)
│   ├── render/                  # tokens + assets -> rendered artifacts (Plymouth, GRUB bg, ...)
│   │   └── inputs/               # raw PNG/SVG inputs the render scripts consume
│   ├── lib/                     # theme-lib.sh, vendor-brand.sh, check-brand-mirrors.sh, ...
│   ├── validate/                 # portable half of theme validation (currently empty — see below)
│   └── headless/payload/         # captive-portal Flask backend, static portal, hostapd/dnsmasq configs
├── backends/
│   ├── _mixins/                  # Shared building blocks
│   │   ├── gnome-dconf/           # GNOME dconf/session/terminal theming (ubuntu)
│   │   └── kde-plasma/            # KDE Plasma color scheme (cachyos, ubuntu)
│   ├── ubuntu/                   # Companion OS on Ubuntu 26.04 LTS — apt/dpkg + Bash
│   │   ├── iso/scripts/           # A: build-iso.sh, build-packages.sh, gresource + repo helpers
│   │   ├── chroot/                # customize-chroot.sh — called by the ISO builder against the rootfs
│   │   ├── provision/             # B: provision.sh, bootstrap-ci-os.sh, install-models.sh
│   │   ├── desktop-theme/         # C: apply-ci-os-desktop.sh + Plymouth/GRUB/wallpaper/etc. steps
│   │   ├── lib/                   # apt-specific helpers (os-release, ROCm, telemetry removal, ...)
│   │   ├── packages/              # .deb sources: ci-os-branding (GNOME Shell branding)
│   │   └── headless-package/      # D: build.sh, DEBIAN/ control scripts, netplan (apt packaging only)
│   ├── arch/                     # NOT a target: the pacman provisioning engine under CachyOS (frozen)
│   │   ├── provision/             # provision.sh — run by backends/cachyos/provision/provision.sh
│   │   ├── desktop-theme/         # unused (CachyOS themes through its own overlay); not an entry point
│   │   └── headless-setup/        # install.sh — dependency oracle read by the tests and the CachyOS ISO verifier
│   └── cachyos/                  # Companion OS on CachyOS — pinned CachyOS-Live-ISO profile + overlay, built with mkarchiso in a container
│       ├── iso/                   # scripts/build-iso.sh, overlay/, verify-iso.sh, tests/
│       ├── installer/             # Calamares overlay (settings, modules, branding, guards)
│       └── provision/             # first-boot wrapper around backends/arch/provision/provision.sh
└── docs/
    ├── architecture/             # design docs, incl. multi-distro-design.md (the core/ + backends/ layout)
    └── guides/                   # ISO build, installation, quick start, repo setup, GDM branding
```

`pull-dev-manual.sh` at the repo root is a thin CLI-flags wrapper around
`core/lib/ci-hub.sh` for manual CI-Hub deploys — the only top-level script left
outside `core/`/`backends/` now that ecosystem provisioning has been
consolidated into `provision.sh`.

`core/validate/` is currently empty — the theme-validation logic
(`backends/ubuntu/desktop-theme/80-validate-ci-theme.sh`) hasn't yet had its portable half
extracted out, since only one backend exists to validate against so far.

---

## Documentation

### Building & installing
- **[ISO Build Guide](docs/guides/iso-build-guide.md)** — build custom ISOs
- **[Tools README](backends/ubuntu/iso/README.md)** — script reference, branding color map, iterative dev
- **[Installation Guide](docs/guides/installation-guide.md)** — install CI-OS
- **[Quick Start Guide](docs/guides/quick-start-guide.md)** — get going fast

### Branding & theming
- **[Brand Guidelines](assets/branding/brand-guidelines.md)** — canon token table, pointer to CI-Common
- **[Core and backends design](docs/architecture/multi-distro-design.md)** — the core/ + backends/ architecture, token→artifact rendering
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
