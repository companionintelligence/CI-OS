# The Companion OS installer (CachyOS edition)

The live ISO installs Companion OS with Calamares, CachyOS' online installer (`cachyos-calamares-next`). The installed system
is not a copy of the ISO: Calamares `pacstrap`s it from the CachyOS and Arch repositories at install time. So everything
that makes the result Companion OS has to be put there by the installer, and this directory is how.

Status: written and unit-tested against the SHAPE of the pinned installer (3.4.2-13) and its real files; **no installation
has been run end to end** (see "What is not tested").

## What is where

| Path | What it is | Where it ends up |
|---|---|---|
| `settings.conf` | the install sequence (derived from the installer's `settings_online.conf`) | `/etc/calamares/settings.conf` |
| `modules/*.conf`, `modules/netinstall.yaml` | module configs that replace the installer's: bootloader (GRUB, `companion-os`), grubcfg, plymouthcfg, users (docker group, hostname), packages_online (the core package list), netinstall (local file only), welcome, pacstrap, services-systemd, the bootloader chooser, two `shellprocess` instances | `/etc/calamares/modules/` |
| `branding/companion/` | the Calamares branding component: names, colours from the brand tokens, the slideshow | `/usr/share/calamares/branding/companion/` |
| `guards.list`, `lib/ci-guards.sh` | what the overlay assumes about the installer, and the code that checks it | read from `/usr/share/ci-os/calamares/` |
| `pacstrap-code-added.list` | the packages the installer's `pacstrap/main.py` adds to the base system IN CODE (grub, the microcode, the kernels, ...), which no config can change | read by `lib/ci-pkglist.py` and the `code-names` guard |
| `patches.list` | cosmetic one-line edits to installer files the overlay does not replace | applied by the launcher |
| `scripts/ci-os-stage-target.sh` | the Calamares step that puts Companion OS on the target (payload, first-boot, identity) | run from `/usr/share/ci-os/calamares/scripts/` |
| `scripts/ci-os-post-install-fixups.sh` | fix-ups of CachyOS hard-codes, run in the target | copied to `/usr/lib/ci-os/` of the target |
| `lib/ci-pkglist.py` | reads the package names the installer will ask pacman for: `basePackages`, `pacstrap-code-added.list`, the package job's operations, the netinstall groups. One definition for the launcher's preflight, `check-packages.py` and the tests | used by the launcher and the tests |
| `stage-installer.sh`, `render-installer-assets.sh` | assemble the above into the ISO build's staging tree (`$CI_OS_STAGING_DIR`), render the three branding pictures | build time |
| `packages/` | `check-packages.py` (names exist?), `capture-upstream-facts.sh` (the installer's shape), `validate-module-schemas.py`, `live-extra.list` | maintainer tools |
| `contract.env` | values shared with the brand overlay (`iso/overlay/INSTALLED.md`); the test fails if a config disagrees | tests |
| `../provision/` | first-boot provisioning wrapper and service, `stage-headless.sh` | staged into the target |
| `../iso/overlay/files/airootfs/usr/local/bin/calamares-online.sh` | the launcher (replaces upstream's script of the same name) | live ISO |
| `../iso/overlay/files/airootfs/usr/share/applications/ci-os-install.desktop` | "Install Companion OS" | live ISO |
| `../iso/overlay/files/airootfs/etc/pacman.d/hooks/ci-os-neutralise-hello.hook` | hides CachyOS Hello in the live session | build time only |

Nothing generated is committed: the overlay at `/usr/share/ci-os/calamares` is assembled by `stage-installer.sh`.

## The flow

```
desktop icon "Install Companion OS"
  -> /usr/local/bin/calamares-online.sh                    (liveuser; log: /home/liveuser/companion-install.log, mode 600)
       1 live medium?                          no  -> stop (the installer repartitions disks)
       2 keyring re-init, exactly as upstream  fail-> dialog "package repositories could not be reached", stop
       3 newer cachyos-calamares-next?         download (pacman -Sw), unpack to a temp dir, run the guards on THAT;
                                               passes -> pacman -S it;  fails -> keep the installer already on the ISO, say why
       4 guards on the installer in use        critical fail -> dialog, stop, nothing changed;  cosmetic -> WARN in the log
       5 overlay copied in (staged, then one cp), cosmetic patches, files compared back byte for byte
       6 pacman -Si of every required package  the base system (pacstrap.conf basePackages + the packages pacstrap adds in code,
                                               pacstrap-code-added.list) and the package job's list; missing -> dialog naming
                                               them, stop (before any disk is touched). Names only some installs need (a
                                               filesystem's tools, an opt-in group) warn only
       7 pkexec-wrapper calamares -D6
  -> Calamares: welcome (neutral internet check) / locale / keyboard / bootloader (GRUB, preselected) / partition /
                additional packages (opt-in groups) / users / summary
  -> install: partition mount ... pacstrap -> users -> packages@online (the core list: Docker, setup-portal stack, tailscale, ...)
              -> shellprocess@ci_os_stage -> plymouthcfg, initcpio, grubcfg, bootloader -> services-systemd
              -> stock shellprocess (home from /etc/skel) -> shellprocess@ci_os_fixups -> ... umount
```

`shellprocess@ci_os_stage` (`scripts/ci-os-stage-target.sh <target>`) does, with no chroot, no pacman and no systemctl:

1. copy the provisioning tree to `/usr/lib/ci-os/bootstrap/` (the repository layout, so `backends/arch/provision/provision.sh` finds
   `core/lib/ci-hub.sh` unmodified);
2. `stage-headless.sh --root <target>`: the setup-portal payload (`core/headless/payload`) to its places;
3. the first-boot service and timer, `/usr/lib/ci-os/first-boot-setup.sh`, `/usr/local/bin/ci-os-setup`;
4. `/usr/share/ci-os/installed/carry-over <target>` (the brand overlay's command: `os-release` and `lsb-release` hook, skeleton
   hook, wallpapers, colour scheme, GRUB and Plymouth themes).

Failure policy (decision D6), applied in two places that agree:

| | critical: fail closed | cosmetic: fail open, loud |
|---|---|---|
| launcher | a script, a code marker or a module the package list/base system depends on is gone; a step appeared in the installer's sequence, or the sequence cannot be read or lacks the steps the overlay is built around (`partition`, `pacstrap`, `packages@online`, `bootloader`); an item appeared in the installer's `basePackages` or `postInstallFiles`, or a key in its `pacstrap.conf` or `bootloader.conf`, that the overlay's frozen copy lacks; the packages the installer adds in code differ from `pacstrap-code-added.list`; `settings.conf` does not resolve; a payload file is missing from the overlay; a required package vanished | a Plymouth/slideshow marker, a key the other overlay configs lack (users, grubcfg, ...: optional keys with defaults), a missing GRUB/Plymouth theme or carry-over command in the live image, a patch whose marker is gone |
| staging step | the bootstrap tree, the payload, the first-boot files are missing or do not copy: exit 1, Calamares aborts with the output | `carry-over` exits non-zero or is absent: `WARN:` and on |
| fix-ups | none | everything (always exit 0) |

"Fail closed" for an update of the installer means: the update is not taken. The launcher judges the new package BEFORE
installing it and keeps the one on the ISO when it fails the guards. This refines decision D6 (which reads "reinstall, then
guard"): the same safety, but an incompatible CachyOS release does not turn the ISO into a brick.
`ci_os.installer_update=0` on the kernel command line (or `CI_OS_INSTALLER_UPDATE=0`) never takes an update.

## Decisions made here

- **GRUB only, chooser kept.** `pacstrap/main.py` stops with "No bootloader selected" when the `packagechooser@bootloader` page left
  no value, and `bootloader/main.py` reads the same global-storage key, so the page stays, with one preselected item. Limine's menu
  name is hard-coded in the installer's Python (`/+CachyOS`) and no config reaches it.
- **Plasma only.** No desktop chooser; the Plasma packages are an always-on netinstall group. GNOME is a follow-up (D2).
- **Packages.** `modules/packages_online.conf` `operations` (always installed, one pacman transaction): `docker docker-compose
  docker-buildx`, the setup-portal stack `hostapd dnsmasq nginx python-flask gunicorn iw`, `jq curl openssl`, `tailscale
  cloudflared github-cli`, `ollama ollama-vulkan`. Opt-in on the netinstall page: Chromium, Ollama with CUDA (+ NVIDIA container
  toolkit), Ollama with ROCm, printing, accessibility. Every name was checked against archlinux.org and the CachyOS database
  (`iso/tests/installer-fixtures/packages.json`). `networkmanager-wifi-tools`, named in the brief, is not an Arch package;
  `iw` and NetworkManager's own `nmcli` are what the payload calls. `dnsutils` (in CachyOS' own list) exists only as a
  `provides` of `bind`, so the list says `bind`.
- **Docker is enabled at install.** `provision.sh install_docker()` returns early when Docker is already installed, without
  enabling it; `services-systemd.conf` does. `tailscaled` and `ollama` are left to `provision.sh`, which configures them first.
- **The setup portal runs only when it is needed.** `services-systemd.conf` enables `setup-backend` (gunicorn on `127.0.0.1:5000`,
  loopback only, idle until a request comes) and `setup-network-monitor`, and does NOT enable `nginx`, `hostapd-setup` or
  `dnsmasq-setup`. The monitor runs `setup-device-hotspot-start.sh` when there has been no default route for two checks after
  the 45 s boot grace; that script starts `nginx`, `hostapd-setup` and `dnsmasq-setup` itself (`systemctl start`), after writing
  their configs for the Wi-Fi interface it detected, and the test `iso/tests/installer-stage.sh` derives this from the payload on
  every run (a unit is either enabled or started by that script, never both, never neither). Before this, all three were enabled
  too, so every boot started an access point (SSID `Companion-Setup-XXXX`, the committed passphrase) on whatever the static
  `hostapd-setup.conf` named (`interface=wlp192s0`, one vendor board: on any other machine `hostapd` failed and restarted every
  5 s) and opened port 80 with the setup API behind it on every network the desktop joined. What stays, because it is the payload's
  design and the monitor is the only way the portal comes up: **a desktop with no default route (no cable, no known Wi-Fi in range,
  also after waking from sleep away from home) has its Wi-Fi radio switched into that access point**, NetworkManager is told
  to leave the interface alone (`nmcli device set ... managed no`), and the monitor never turns it back (only a completed portal
  run does). `docker stop traefik` runs at the same moment and nothing in the payload starts it again. A person with a keyboard
  does not need that; the alternative, not enabling `setup-network-monitor` either and making it an opt-in (`systemctl enable --now
  setup-network-monitor`), would remove all of it for desktops and is a decision for the lead (it narrows decision D8). See "Known
  issue in the shared setup payload" below for the API behind it.
- **First boot runs `--tier=core`.** The Arch provisioner's default tier `core,hardware` installs `rocm-hip-sdk` (several GB) and
  LACT unconditionally (`install_rocm_driver_arch`, `install_lact` do no hardware detection). Use `sudo ci-os-setup
  --tier=core,hardware` on a machine that needs them.
- **First boot is complete only when the Ollama models are on the machine.** The Arch provisioner exits 0 after a failed model
  pull (`pull_ollama_models()` ends in `|| log_warning` after a heredoc whose status is its last command, so a failed pull of the
  first two models is not even reported), and `first-boot-setup.sh` used to write the done marker for any exit 0. Now
  `provision.sh` (the CachyOS wrapper, not the Arch script) reads `llm.models` from `core/manifest/ecosystem.yaml` after the Arch
  script succeeded, polls `ollama list` until the server answers (30 x 2 s, not a fixed pause) and exits **74** when a model is
  missing (`name` also matches `name:latest`; another tag does not count). `first-boot-setup.sh` treats 74 as *degraded*: no done
  marker, the attempt stays counted (three automatic ones), `/var/lib/ci-os/first-boot-setup-status` says why, the timer tries
  again in 15 minutes and `ollama pull` is only repeated for what is missing, and the last attempt says that setup is NOT marked
  complete and names `sudo ci-os-setup`. The unit has `TimeoutStartSec=infinity`: `qwen3.6:27b` alone is 17.8 GB, and fetching
  that in the former 1800 s takes 79 Mbit/s sustained, with a systemd kill half way using up an attempt. The download is about
  18.8 GB in all on every install (nomic-embed-text 0.27 GB, gemma3:1b 0.81 GB, qwen3.6:27b 17.8 GB; `core/manifest/model-packs.yaml`);
  the Arch script does not gate the large model on RAM, VRAM or disk the
  way the Ubuntu one does (`ci_os_hardware_supported`), so **a machine that cannot hold `qwen3.6:27b` ends in "degraded" for good**:
  that gate belongs in the shared provisioner, which this change does not edit. An interrupted boot (power off during the
  download) uses up one of the three automatic attempts because a run is counted when it starts.
- **No host firewall (UFW is not installed, the `enable-ufw` step is dropped).** Reasons: the Ubuntu edition ships `ufw` installed
  but disabled (`docs/architecture/tier-b-tools.md`, risk R4: CI-Hub's containers reach the host's Ollama on `0.0.0.0:11434`
  through the docker bridge, which a default-deny INPUT policy would block); the stock `enable-ufw` sets `default deny incoming`,
  which also blocks the setup portal's DHCP, DNS and HTTP on the hotspot subnet. If you want one anyway, add `ufw`, and these rules
  (syntax read from the `ufw(8)` page and executed with `ufw --dry-run` on ufw 0.36.2 from the Arch package; each printed the
  iptables rule shown):

  ```
  ufw allow in proto tcp from 192.168.99.0/24 to any port 80 comment 'Companion OS setup portal: HTTP'   # -A ufw-user-input -p tcp --dport 80 -s 192.168.99.0/24 -j ACCEPT
  ufw allow from 192.168.99.0/24 to any port 53                                                           # tcp and udp: DNS
  ufw allow in proto udp from any port 68 to any port 67 comment 'Companion OS setup portal: DHCP'       # -A ufw-user-input -p udp --dport 67 --sport 68 -j ACCEPT
  ```

  The DHCP rule is not keyed on the subnet because a DHCPDISCOVER comes from 0.0.0.0. Still needed for CI-Hub: allow the docker
  bridge to port 11434 (`ufw allow in on docker0 to any port 11434 proto tcp`; not run). The package's own defaults are
  `ENABLED=no`, `DEFAULT_INPUT_POLICY="DROP"`, `DEFAULT_FORWARD_POLICY="DROP"`.
  Leaving the firewall out is not "resolved": port 11434 (Ollama, no authentication) is open to the LAN once Ollama is installed, and
  port 80 is too while the setup portal's nginx runs (see "Known issue in the shared setup payload"). The Ubuntu edition's `ufw` is
  installed but disabled, so it has the same two ports open.
- **Neutral internet check.** `https://example.com` instead of `wiki.cachyos.org`: nothing of the project's own would learn who
  installs, and no CachyOS host can block an install.
- **Hostname `companion-os`**, UEFI entry `companion-os`, GRUB distributor `Companion OS`.
- **cachyos-hello.** It gates the installer on `cachyos.org/versions.json`. The package stays in the live image (decision of
  the brand overlay), a `PostTransaction` hook removes its skeleton autostart and hides its menu entry, and the launcher starts
  the script directly. Not installed on the target.

## Network endpoints the installer contacts

| Host | For | Notes |
|---|---|---|
| Arch and CachyOS mirrors (`/etc/pacman.d/mirrorlist`, `cachyos-mirrorlist`) | packages, keyrings | inherent to the base |
| whatever `cachyos-rate-mirrors` queries (`scripts/update-mirrorlist`; the earlier research read that it uses CachyOS' mirror list API, not re-verified) | ranking mirrors at install time | upstream's step, kept |
| `https://example.com` | welcome page internet check | ours (D6) |
| `https://geoip.kde.org/v1/ubiquity`, `/v1/calamares` | language and time zone preselection | the installer's default, KDE's service |
| first boot: pacman mirrors, GitHub (asdf), `ollama.com`, registries | `provision.sh --tier=core` | see `backends/arch/provision/provision.sh` |

Not contacted any more: `cachyos.org` (`versions.json`, CachyOS Hello's connectivity check), `wiki.cachyos.org`, `paste.cachyos.org`
(log upload: no `uploadServer`), `raw.githubusercontent.com` (netinstall list). The live image's `/etc/hosts` still pins
`raw.githubusercontent.com` (upstream; the brand overlay's business).

## Known issue in the shared setup payload

Found by an independent review of this edition; the cause is in `core/headless/payload`, which every backend ships and which is
not changed here. Documented so it is not mistaken for something this edition decided.

**Claim.** `POST /api/configure` of the setup backend (`opt/setup-backend/setup_service.py`, gunicorn as `root`) needs no
credential on this edition, and the portal's nginx server block (`nginx/sites-available/setup-portal`: `listen 80 default_server`,
`[::]:80`, `location /api/` proxies to the backend with no `allow`/`deny`) offers it on every interface. `get_hub_pairing_state()`
asks for a pairing code only when `_hub_running()` finds a process named `companion-hub` or `ci-os-hub-desktop` (the Companion
Launcher), and this edition ships no Launcher. Even with one, the code is a cloud-pairing gate, not authentication, and goes
away once the Hub is registered.

**Scenario.** While nginx runs (here: from the first time the monitor starts the hotspot after a boot, until the next reboot;
nothing in the payload stops it), a host that can reach port 80 (a peer on the same Wi-Fi or LAN, or anyone who joined the
`Companion-Setup-XXXX` access point, whose WPA2 passphrase is the constant `SetupDevice123` written by
`setup-device-hotspot-start.sh`) sends
`curl -H 'Content-Type: application/json' -d '{"ssid":"Wired connection 1","password":"x"}' http://<device>/api/configure`.
`configure()` calls `create_wifi_connection()`, which first calls `delete_wifi_connections_by_name()`: it runs `nmcli connection
delete` for every NetworkManager profile of any type (wired, VPN, Wi-Fi) named like the posted SSID or `<ssid> N`, then adds a
Wi-Fi profile with the caller's passphrase; `_connect_and_pair()` stops the hotspot, hands the radio to NetworkManager and
tries to join. The device loses a saved connection, and joins a network of the caller's choosing if its SSID is in range. A
reviewer reproduced the first part on a scratch copy with Flask stubbed and `nmcli`/`pgrep` faked (the deletion of both
`Wired connection 1` and `Wired connection 1 2`, but not of `HomeWifi` or a VPN profile, and the creation of the profile with the
caller's key); nothing was run against a real NetworkManager, so the effect on a live link is inferred. No shell injection was
found (argument lists, `re.escape`).

**What this edition does.** `nginx` is not enabled at boot (port 80 is closed until the hotspot starts it, see "The setup portal runs
only when it is needed"), and `setup-backend` binds the loopback only. It does not install a firewall (see below), so once nginx
is up the port is open to the LAN. Separately, the shared Arch provisioner makes Ollama listen on `0.0.0.0:11434` without
authentication (`configure_ollama()`, so that CI-Hub's containers reach it through the docker bridge): the same kind of exposure,
a different fix.

**Suggested fix (shared payload, for the lead).**
1. `configure()` refuses (403) unless the hotspot is active (`_hotspot_active()`), the host has no working uplink, or the request
   comes from the loopback; add `allow 192.168.99.0/24; allow 127.0.0.1; deny all;` to `location /api/` as a second layer. The
   hotspot flow keeps working and the LAN reach goes.
2. Stop the portal once it has done its job: `systemctl stop nginx` next to the two `systemctl stop` calls of
   `stop_hotspot_services()`, or `ConditionPathExists=!<paired marker>` drop-ins on `nginx`, `setup-backend`, `hostapd-setup`,
   `dnsmasq-setup` (the NixOS backend already does this, `ConditionPathExists=!<hub.env>` on the four portal units in
   `modules/headless-setup.nix`; Bazzite has a first-boot gate, `ci-os-first-boot-setup-portal-gate.sh`).
3. A per-device access point passphrase instead of the committed constant.
4. Ollama: bind the docker bridge address (for example `OLLAMA_HOST=172.17.0.1:11434`) or accept port 11434 only from `docker0`
   (`backends/arch/provision/provision.sh`, so a follow-up for all editions).

Related defects read in the same payload, not run on a device: `wifi_link_active_or_connecting()` in `setup-network-monitor.sh`
matches only the bare state words, while `nmcli` prints `connecting (getting IP configuration)` and `connected (site only)`, so
"do not tear down a link that is still negotiating" mostly does not fire; `hostapd-setup.conf` and `setup-portal.conf` name
`interface=wlp192s0` until the hotspot script rewrites them; the monitor's comment says it never stops the access point.

## CachyOS hard-codes that stay (and what handles them)

| Hard-code | Where | Handling |
|---|---|---|
| `cachyos-grub-theme` installed for GRUB | `pacstrap/main.py` | removed again by `ci-os-post-install-fixups.sh` (only when `GRUB_THEME` is the Companion OS theme) |
| kernels `linux-cachyos`, `-lts` | `pacstrap/main.py` | kept: the base's kernels, named as such (`uname -r`) |
| Limine entry `/+CachyOS`, palette | `bootloader/main.py` | Limine is not offered |
| `TARGET_OS_NAME="CachyOS"`, snapshot text | `scripts/*` | `patches.list` |
| "... of CachyOS" in progress text | `modules/shellprocess-before-online.conf` | `patches.list` |
| `cachyos-hooks` rewrites `/etc/os-release` | pacman hook | `zz-ci-os-os-release` (brand overlay), re-checked by the fix-ups |
| `cachyos-kde-settings` skeleton | package | `zz-ci-os-skel` (brand overlay) |

## Bumping the installer pin

1. Unpack the new `cachyos-calamares-next` (`bsdtar -xf ... -C <dir>`) or an ISO's squashfs.
2. `installer/packages/capture-upstream-facts.sh <dir> [<dir>/var/lib/pacman/local] > iso/tests/installer-fixtures/upstream-<ver>.facts`;
   read the diff against the old facts: that is the review of the new installer. Update `guards.list`, `settings.conf`, the module
   configs, and `pacstrap-code-added.list` (the facts hold the `base_packages` statements of `pacstrap/main.py` as written, and the
   items of the lists the `list-drift` rows compare; the `code-names` guard names every difference).
3. `check-packages.py --cachyos-db <url or path> --write iso/tests/installer-fixtures/packages.json` (network).
4. `validate-module-schemas.py <dir>` (needs python-jsonschema, e.g. in the builder container): the overlay's module configs against the
   JSON schemas the installer ships. Run on 3.4.2-13: bootloader, packages, pacstrap, plymouthcfg, services-systemd valid; grubcfg is
   invalid (`defaults.GRUB_DEFAULT` required) exactly as the installer's own grubcfg.conf is, so that is the installer's schema being
   ahead of its config, not an overlay error. Several C++ modules (users, welcome, netinstall, shellprocess) ship no schema.
5. `iso/tests/installer-config.sh` (set `CI_OS_REAL_CALAMARES_ROOT=<dir>` to run the guards on the real files too).

## Tests

```
backends/cachyos/iso/tests/installer-config.sh        # runs the three below; no root, no Docker, no network (bash 3.2+, python3 + PyYAML, git)
  installer-config.py       YAML and text invariants, contract.env, the package fixture, the sequence order, the units (which run at
                            boot and which the hotspot script starts), the guards.list policy, the first-boot unit's timeout
  installer-launcher.sh     guard library (unparseable sequences and lists, frozen-list drift, code-added packages) and launcher
                            (package preflight of the whole base system) against a fake Calamares tree and stubbed pacman/bsdtar/pkexec/dialogs
  installer-stage.sh        stager, payload PARITY, Calamares staging step, fix-ups, first-boot driver (incl. degraded runs),
                            provisioning wrapper (incl. the Ollama model check against a stand-in `ollama`)
```

## What is not tested

- No Calamares run: that `shellprocess` expands `${ROOT}`/`${USER}` in these commands (it does in the installer's own configs, which
  are the model), that `file://` as the only `groupsUrl` loads, that a hidden netinstall group installs, that `services-systemd`
  enables units staged by an earlier job, that the `users` job creates `docker` before the packages job.
- No boot of an installed system; GRUB and Plymouth themes are the brand overlay's and are marked not boot-tested there.
- `pacman -Sw` / `bsdtar` / `pacman -S` of a real newer installer package, and `pkexec-wrapper` with a real desktop.
- `kdialog` is not in the live package list (checked in the built demo ISO: `libnotify` is). The launcher falls back to
  `notify-send` (critical urgency), which is easy to miss. Add `kdialog` to `iso/overlay/packages.add`.
- The Arch provisioner itself (`backends/arch/provision/provision.sh`) has never run on CachyOS here, so the model check was tested
  against a stand-in `ollama` (its `list` output and a server that comes up late or never), not a real server: that `ollama list` as
  root reaches a server bound to `0.0.0.0`, and that a pull resumes after `systemctl stop`, are from the documentation, not seen.
  `TimeoutStartSec=infinity` and the retry timer were not run under systemd either.
- The `settings-drift`, `list-drift` and `code-names` guards were tested on the recorded SHAPE of 3.4.2-13 and on edited copies of
  it (empty file, flow style, renamed key, comment on the header, added and removed items), with BSD awk 20200816 and gawk 5.4.1;
  not on a newer upstream release.
- nginx and the units were checked once by hand in a throw-away builder container (Arch, nginx 1.30.5, systemd 262), not by the
  tests: after `stage-headless.sh --root /` on the package's stock `nginx.conf`, `nginx -t` succeeds (one `types_hash` warning,
  harmless) and `nginx -T` shows both the stock `localhost` server and the portal's `listen 80 default_server`;
  `systemd-analyze verify` reports nothing about the first-boot service and timer except "Command ... is not executable: Invalid
  argument", which it prints for `/usr/bin/true` too (an artefact of the emulated container). No daemon was started.
