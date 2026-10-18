# The Companion OS installer (CachyOS edition)

The live ISO installs Companion OS with Calamares, CachyOS' online installer (`cachyos-calamares-next`). The installed system
is not a copy of the ISO: Calamares `pacstrap`s it from the CachyOS and Arch repositories at install time. So everything
that makes the result Companion OS has to be put there by the installer, and this directory is how.

Status: written and unit-tested against the SHAPE of the pinned installer (3.4.2-13) and its real files. **Three full installations
were run end to end (ISO #4, ISO #5 and ISO #6, QEMU/OVMF software emulation, 2026-10-18) and succeeded** (ISO #5 on its third attempt: the first two
died on the keyring step's 30 second limit, see "What is not tested"; ISO #6 on its first). The fixes ISO #4 led to are seen working on ISO #5's installed system [V];
the fixes for the keyring limit and the driver-job label (commit `ad37b64`) are seen working on ISO #6 [V], in one run in a virtual machine (see "What is not tested"
and `docs/architecture/cachyos-backend.md`, "Test status").

## What is where

| Path | What it is | Where it ends up |
|---|---|---|
| `settings.conf` | the install sequence (derived from the installer's `settings_online.conf`) | `/etc/calamares/settings.conf` |
| `modules/*.conf`, `modules/netinstall.yaml` | module configs that replace the installer's: bootloader (GRUB, `companion-os`), grubcfg, plymouthcfg, users (docker group, hostname), packages_online (the core package list), netinstall (local file only), welcome, pacstrap, services-systemd, the bootloader chooser, two `shellprocess` instances of ours, and copies of three stock `shellprocess` configs that differ from the installer's only in explicit time limits (`shellprocess_initialize_pacman.conf`, `shellprocess_modify_mk_hook.conf`, `shellprocess_reset_mk_hook.conf`) | `/etc/calamares/modules/` |
| `branding/companion/` | the Calamares branding component: names, colours from the brand tokens, the slideshow | `/usr/share/calamares/branding/companion/` |
| `guards.list`, `lib/ci-guards.sh`, `lib/ci-shellprocess.py` | what the overlay assumes about the installer, the code that checks it, and the reader behind the `shell-timeouts` guard (every `shellprocess` command has an explicit time limit) | read from `/usr/share/ci-os/calamares/` |
| `pacstrap-code-added.list` | the packages the installer's `pacstrap/main.py` adds to the base system IN CODE (grub, the microcode, the kernels, ...), which no config can change | read by `lib/ci-pkglist.py` and the `code-names` guard |
| `patches.list` | cosmetic one-line edits to installer files the overlay does not replace (the bootloader script's OS name, the btrfs snapshot text, the `before-online` progress text, the driver job's label "Installing needed drivers for CachyOS...") | applied by the launcher |
| `scripts/ci-os-stage-target.sh` | the Calamares step that puts Companion OS on the target (payload, first-boot, identity) | run from `/usr/share/ci-os/calamares/scripts/` |
| `scripts/ci-os-post-install-fixups.sh` | fix-ups of CachyOS hard-codes, run in the target | copied to `/usr/lib/ci-os/` of the target |
| `lib/ci-pkglist.py` | reads the package names the installer will ask pacman for: `basePackages`, `pacstrap-code-added.list`, the package job's operations, the netinstall groups. One definition for the launcher's preflight, `check-packages.py` and the tests | used by the launcher and the tests |
| `stage-installer.sh`, `render-installer-assets.sh` | assemble the above into the ISO build's staging tree (`$CI_OS_STAGING_DIR`), render the four branding pictures (logo, icon, welcome, bootloader) | build time |
| `packages/` | `check-packages.py` (names exist?), `capture-upstream-facts.sh` (the installer's shape), `validate-module-schemas.py`, `live-extra.list` | maintainer tools |
| `contract.env` | values shared with the brand overlay (`iso/overlay/INSTALLED.md`); the test fails if a config disagrees | tests |
| `../provision/` | first-boot provisioning wrapper and service, `stage-headless.sh`, `progress-filter.sh` (keeps terminal redraws out of the log and the journal) | staged into the target |
| `../iso/overlay/files/airootfs/usr/local/bin/calamares-online.sh` | the launcher (replaces upstream's script of the same name) | live ISO |
| `../iso/overlay/files/airootfs/usr/share/applications/ci-os-install.desktop` | "Install Companion OS" | live ISO |
| `../iso/overlay/files/airootfs/etc/pacman.d/hooks/ci-os-neutralise-hello.hook` | hides CachyOS Hello in the live session | build time only |

Nothing generated is committed: the overlay at `/usr/share/ci-os/calamares` is assembled by `stage-installer.sh`.

## The flow

```
desktop icon "Install Companion OS"
  -> /usr/local/bin/calamares-online.sh                    (liveuser; log: /home/liveuser/companion-install.log, mode 600)
       1 live medium?                          no  -> stop (the installer repartitions disks)
       2 keyring, then sync                    no keyring -> pacman-key --init and --populate BEFORE the first sync; a working one is
                                               kept (never deleted) and populated; an unusable one is repaired in place, or as a last
                                               resort its CONTENTS are cleared in place (the directory is never removed or renamed: it
                                               can be a mount point; public files are kept under /var/log for diagnosis).
                                               Then pacman -Sy of both keyring packages; a keyring-class failure repairs the keyring
                                               in place and tries the sync ONCE more. fail-> dialog that says keyring problem (a
                                               restart does not help: download a newer ISO if it persists), mirror or connection
                                               problem, or other; pacman's last error in the log, stop (incident 2026-10-18, F1)
       3 newer cachyos-calamares-next?         download (pacman -Sw), unpack to a temp dir, run the guards on THAT and `ldd -r` on its
                                               binary; passes -> pacman -S it;  fails -> keep the installer already on the ISO, say why
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
  complete and names `sudo ci-os-setup`. Nothing in the unit may kill the run half way (no `RuntimeMaxSec`; it was a `Type=oneshot`
  with `TimeoutStartSec=infinity` until the ISO #4 run, see below): `qwen3.6:27b` alone is 17.8 GB, and fetching
  that in 1800 s takes 79 Mbit/s sustained, with a systemd kill half way using up an attempt. The download is about
  18.8 GB in all on every install (nomic-embed-text 0.27 GB, gemma3:1b 0.81 GB, qwen3.6:27b 17.8 GB; `core/manifest/model-packs.yaml`);
  the Arch script does not gate the large model on RAM, VRAM or disk the
  way the Ubuntu one does (`ci_os_hardware_supported`), so **a machine that cannot hold `qwen3.6:27b` ends in "degraded" for good**:
  that gate belongs in the shared provisioner, which this change does not edit. An interrupted boot (power off during the
  download) uses up one of the three automatic attempts because a run is counted when it starts.
- **What the ISO #4 install run changed (full run on the 30 GiB NVMe target: live, Calamares online install, installed boot, first boot).**
  Each item has a test. On ISO #5's booted system the first-boot, boot-target, log, Cachy-Update and look items are seen working [V]; the exceptions are named in the items (`docs/architecture/test-evidence.md`).
  - `ollama list` ran as root under a unit with no `$HOME`, the CLI panics without one (exit 2), and the wrapper read that as "server
    never answered": all three models were installed and the run ended "degraded" (74) every time. Now the unit sets `HOME=/root`,
    `provision.sh` sets it when it is unset, and the failure message shows the last stderr of `ollama list`. The Arch script's own
    calls run through `sudo -u "$ACTUAL_USER"`, where sudo supplies that user's HOME, so they needed nothing.
  - The first-boot oneshot held `graphical.target` (16 min 27 s with a network): a target is ordered after what it wants, and a
    oneshot's start job lasts as long as the script. The unit is `Type=exec` now, with no `network-online.target` ordering (the
    script polls for the network itself), `Nice=10`; retries stay with the timer and the attempt counter.
  - `ollama pull` redraws its progress block ten times a second: 14,052 log lines (1.9 MB) and `[147B blob data]` in the journal for
    three pulls. `progress-filter.sh` (in front of the log and the journal; the terminal of `sudo ci-os-setup` keeps the raw stream)
    prints each layer every 5% or 30 s and strips the colour codes of the Arch script. A `PATH` shim around `ollama` does not work:
    the pulls run under `sudo -u`, and Arch's sudoers sets `secure_path`. The filter is ONE awk program (linear: its bash first
    version needed 35 s for a line of 15,000 ESC and the provisioner blocked in `write()` meanwhile), with a high-water mark per layer
    (a retry that goes 41, 39, 41 ... is one line per window, not one per sample) and a clamp for absurd percentages.
  - The tail of the first-boot output was lost when the main process exited: the filter and the `tee` live in a process substitution,
    and with the unit's default `KillMode=control-group` systemd SIGTERMs them the moment the script is done (measured under a real
    systemd manager, 300-redraw run, 40 runs each: the bash filter lost the closing lines 40 times, the awk filter without the fix 16
    times, with it 0). `first-boot-setup.sh` now closes its stdout and stderr in an EXIT trap and waits, at most 5 s, for the
    substitution (`$!`), so a background child that keeps the pipe open cannot keep the unit up either.
  - `cachy-update` (a "Cachy-Update" menu entry and a teal C in the tray of the installed desktop; the live image never had it) is no
    longer in the Plasma group, its user timer is no longer enabled, and `ci-os-post-install-fixups.sh` removes it if it arrives anyway
    (hiding it when pacman refuses). Nothing requires it; the update path of this edition is `sudo pacman -Syu`.
  - The installer's look: the colour scheme paints Highlight like the window, so the progress bar's fill, the selected rows of the
    keyboard, bootloader, package and partition lists were invisible. `branding/companion/stylesheet.qss` sets those colours from the
    brand tokens (contrast checked by `installer-config.py`), removes the Welcome page's dark stock pictograms, the bootloader
    chooser shows the Companion mark instead of Calamares' zip-archive placeholder, and the package descriptions are short enough
    for the window.
  - **Still open:** the model set takes the 30 GiB target from 7.8 GiB to 26 GiB used; a smaller disk fails a pull for lack of
    space. The guard (skip a model when the free space of the model directory is below its `size_bytes` plus a margin, and do not
    count it as missing) belongs in the shared gate `ci_os_model_gate_allows` in `core/lib/gpu-detect.sh`, which the Arch script and
    this wrapper both call; it cannot be done here without editing `backends/arch/**`.
- **What the ISO #5 install run changed (full run on the 64 GiB NVMe target; its three Calamares sessions and the installed boot are the evidence).**
  Each item has a test; none has run on a built ISO yet. The Calamares analysis of `iso/scripts/verify-iso.sh`, run on the real files of ISO #5 with the new overlay staged
  over them, passes; the whole script on the unchanged ISO #5 fails exactly on the five defects below (10 FAIL lines, no other, 204 PASS).
  - **Calamares' 30 s default killed the install at job 13 of 47 (twice).** Only `shellprocess` has that default: the process calls of Calamares'
    own C++ and Python job modules default to `timeoutSec = 0`, no limit (`System.h`), which is why `pacstrap` (442 s), `packages` (586 s), `chwd` (132 s) and
    `initcpio` (93 s) ran long without a limit on the same install. The overlay therefore ships copies of the three stock `shellprocess` configs that have
    no complete set of limits (`shellprocess_initialize_pacman.conf`, `shellprocess_modify_mk_hook.conf`, `shellprocess_reset_mk_hook.conf`), identical to the
    installer's apart from `timeout:` keys (3600 s on `update-mirrorlist` and `create-pacman-keyring`, 600 s for the rest of those files). The audit
    of every `shellprocess*.conf` of the pinned installer: `shellprocess.conf` 3600 s, `shellprocess_btrfs_snapshot.conf` 300 s, `shellprocess-before-online.conf`
    and `shellprocess_cleanup_calamares.conf` 10 s each (a `cp` of one file, `ld.so --help | grep`, two `rmdir`: 1 s on ISO #5), and the two scripts
    of ours (`ci_os_stage` 1800 s, `ci_os_fixups` 900 s) carry limits; the overlay ships no job module of its own. The durations of the 47 jobs on the run that passed
    are the evidence for the numbers (job 13: 68 s, of which the keyring command 28 s; pacstrap 442 s; chwd 132 s; packages 586 s; mkinitcpio 93 s;
    bootloader 15 s; localecfg 10 s; every other job under 10 s). The `shell-timeouts` guard (`lib/ci-shellprocess.py`, three rules in its header) runs in the launcher
    before the overlay is applied and judges the EFFECTIVE config of every `shellprocess` step, including a newer installer package's own files and the
    scripts they run, so an update that gives a stock step a heavy command without a limit is not taken (the ISO's installer is kept, as for any critical
    guard). `verify-iso.sh` holds a character-for-character copy of the same rules (`installer-config.py` compares them) and applies them to the image.
  - **The install page said "Installing needed drivers for CachyOS..." at 35 percent.** It is the label of the `chwd` job, a Python module's `pretty_name()`; no
    config reaches it, so `patches.list` rewrites it (the table below). The new wording has no translation in the installer's catalogs, so it shows in
    English in every language. `verify-iso.sh` applies the overlay's patches to the image's own modules and fails when any job label still names CachyOS.
  - **The installed GRUB menu listed the firmware's leftovers** (UiApp, a DVD drive that was no longer attached, the NVMe disk, EFI Shell, a second
    `companion-os`, each ending in "(EFI BootNext)"). They are not os-prober's: the grub package of the image has `/etc/grub.d/31_efi_bootnext`, which turns every entry of
    `efibootmgr -v` into a menu entry, and whose own switch is `GRUB_DISABLE_BOOTNEXT` ("intentionally independent of `GRUB_DISABLE_OS_PROBER`"), so
    `GRUB_DISABLE_OS_PROBER=true` alone would not have removed one of them. `modules/grubcfg.conf` now sets both to `true` (the job writes them quoted, which both scripts
    compare with; the stock `grubcfg` module, run with this file, was seen to replace an existing `false` and to uncomment a commented key), and it runs before `bootloader`, whose
    `grub-mkconfig` writes the menu, so they are in force when it is generated. The post-install fix-ups only check (it is too late to set them there) and warn about a
    `grub.cfg` that still holds `efi-bootnext-` entries. What stays: the Companion OS entries, "Advanced options", "Companion OS snapshots" on Btrfs and the
    firmware-setup entry. **The cost, on purpose:** with `GRUB_DISABLE_OS_PROBER=true` another system on the machine (Windows, another Linux) gets no GRUB entry; the installer's
    "alongside" choice is not removed. It stays reachable from the firmware's boot menu and from "UEFI Firmware Settings", and `GRUB_DISABLE_OS_PROBER=false` in
    `/etc/default/grub` plus `grub-mkconfig -o /boot/grub/grub.cfg` brings the scan back. That is a product decision (the open question is in `docs/architecture/known-issues-and-decisions.md`);
    setting only `GRUB_DISABLE_BOOTNEXT` would clean the menu and keep the scan. Seen: the real `31_efi_bootnext` of ISO #5, fed the VM's five firmware entries through a stand-in `efibootmgr`,
    prints exactly the five "(EFI BootNext)" entries of the ISO #5 frame, and none with `GRUB_DISABLE_BOOTNEXT=true`. **Seen on ISO #6 [V]** (commit `ad37b64`): the installed menu lists
    exactly Companion OS Linux, Advanced options, UEFI Firmware Settings and Companion OS snapshots (frame 19 of `docs/ui/companion-os/plasma/`), although the virtual machine's firmware still held a UiApp, an EFI shell and an NVMe entry.
  - **The installer's look, two gaps left by ISO #5's stylesheet.** (1) The popups of the combo boxes (the zone list) showed no highlight for the current entry or under the
    pointer: the list-style popup is painted by a delegate that ignores every item rule of a stylesheet and draws focus with a translucent wash that is invisible on this
    window colour; no `QAbstractItemView` selection or hover rule changes it (offscreen, Qt 6.12, Breeze). The stylesheet switches the combo boxes to the menu-style popup (`combobox-popup: 1`), which it
    paints itself: a transparent base rule per entry (else Breeze draws an empty check box on every other row), sage on dark text for the entry under the pointer or the keyboard, a check mark on
    the current one. The popup scrolls with arrows and the wheel instead of a scroll bar. (2) The checked radio button of the partition page was a bare white dot: the indicator is drawn by
    the sheet now (a ring in the muted outline colour, a sage ring with a sage dot and a gap when checked). The selected row of the partition choices is not highlighted: those rows are
    widgets (`PrettyRadioButton`), not an item view, and a stylesheet cannot colour a parent by the state of its child; the manual partition table (an item view) is highlighted.
    Frames to re-shoot after a rebuild: `install/02b` (zone popup), `install/05a` and `install/05b` (partition page: every radio button changed), `install/11b` (the 35 percent status line)
    and `installed/01` (GRUB menu); the failure frame `install/09b` needs none. **Re-shot on ISO #6 [V]** (`docs/ui/companion-os/plasma/CAPTURE.md`): the zone popup shows the current entry with a check mark and
    the hovered entry highlighted, the radio buttons show a ring and a ring plus a dot when selected (frame 11), the status line reads "Installing needed drivers for Companion OS..." and the GRUB menu is clean. **Three gaps
    remain (KI-09):** the right-hand column of the language popup is nearly unreadable on the highlighted row, the filesystem drop-down has no highlight, and the selected partition row has none (frame 11).
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
   `dnsmasq-setup` (the same idea as the gates that two retired backends shipped; recover them with
   `git show pre-retire-multidistro-2026-10-17:backends/nixos/modules/headless-setup.nix` and `...:backends/bazzite/modules/ci-os-first-boot-setup-portal-gate.sh`).
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
| "Installing needed drivers for CachyOS..." (the label of the driver job, from 35 percent on) | `/usr/lib/calamares/modules/chwd/main.py` | `patches.list` **[V]**: added in `ad37b64`; ISO #6 reads "Installing needed drivers for Companion OS..." at 35 percent; the new text has no translation, so it shows in English in every language |
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
backends/cachyos/iso/tests/installer-config.sh        # runs the parts below; no root, no Docker, no network (bash 3.2+, python3 + PyYAML, git)
  installer-config.py       YAML and text invariants, contract.env, the package fixture, the sequence order, the units (which run at
                            boot and which the hotspot script starts), the guards.list policy, the first-boot unit's shape (does not hold
                            the boot targets, HOME), the installer stylesheet's contrast (progress bar, selected rows, combo popup, radio indicator), the bootloader
                            picture, the package descriptions, the `shellprocess` time limits (rules R1 to R3 on the overlay's configs and on the installer's recorded
                            ones, a matrix of heavy and light commands), the install page label patch and the grubcfg switches; with CI_OS_REAL_CALAMARES_ROOT
                            the same audit on the real files and the REAL grubcfg module run on this overlay's grubcfg.conf
  installer-launcher.sh     guard library (unparseable sequences and lists, frozen-list drift, code-added packages, the `shell-timeouts` guard)
                            and launcher (package preflight of the whole base system) against a fake Calamares tree and stubbed
                            pacman/bsdtar/pkexec/dialogs; the tree holds the installer's real shellprocess commands and time limits
                            (the `spconf` lines of the facts file), including the keyring command that has none
  installer-stage.sh        stager, payload PARITY, Calamares staging step, fix-ups (incl. cachy-update), first-boot driver (incl. degraded
                            runs and the output filter), provisioning wrapper (incl. the Ollama model check against a stand-in `ollama`
                            that panics without HOME)
  progress-filter.sh        the output filter on the real recorded stream of `ollama pull`, a 3000-redraw flood, a layer that goes up and
                            down (20,000 samples), plain output, consecutive pulls, the time rule, escape-heavy newline-free input
                            (each case under 2 s), percentages, binary junk, no awk; and the driver's hand-over of the output: the
                            tail survives the exit of the main process (200 runs with its process group killed at once, a slow
                            filter as the sensitive case, a background child that holds the pipe)
```

## What is not tested

- Calamares has run on this overlay on three ISOs (#4, #5 and #6). On ISO #4 it ran 47 jobs to `completion: succeeded`; the frames and the session log of that run are in the capture scratch, not in the
  repository. What that run shows about the open questions of the first draft: the target holds the staged payload, the first-boot unit and the
  carry-over (so `shellprocess` expanded `${ROOT}`/`${USER}` in these commands); `file://` as the only `groupsUrl` loaded and the always-on Plasma
  group installed (1148 packages on the target, including `plasma-desktop`, `docker`, `ollama`, `tailscale`); `services-systemd` enabled the units an
  earlier job staged (`ci-os-first-boot-setup.service`; Docker was running on the first boot). **Not shown:** that the `users` job creates the `docker`
  group before the packages job (not checked separately).
- ISO #5 (with the fixes of `552063f`) ran all 47 jobs on its third attempt (23 min 20 s, `completion: succeeded`) [V]. The first two attempts stopped at
  job 13, `bash /etc/calamares/scripts/create-pacman-keyring` "failed to finish in 30 seconds": the stock `shellprocess_initialize_pacman.conf`
  gives its command no `timeout`, so Calamares' default of 30 s applies, and the step takes about 28 s under QEMU/TCG (KI-20). **The fix is in `ad37b64`:** overlay copies of the three stock `shellprocess` configs with an explicit `timeout` on every command (3600 s for the two commands that
  talk to mirrors, 600 s for the file's other commands), and the `shell-timeouts` guard, which judges the effective config of every `shellprocess` step
  of the sequence (rules in the header of `lib/ci-shellprocess.py`: an explicit limit on every command, at least 600 s for network and package tools and
  300 s for disk and initramfs tools, and a frozen copy still runs every command of the installer's file, in its order and with its `dontChroot`). It is covered by `iso/tests/installer-launcher.sh`
  against a fake tree that holds the installer's real commands. **[V] once:** ISO #6 (built from `ad37b64`) ran all 47 jobs on its first attempt in 28 min 26 s; `create-pacman-keyring` took 32 s and passed under the explicit limit, and the session log has no "timed out" line (`docs/evidence/2026-10-18-plasma-iso6/`). **Not run:** a second install of ISO #6, or one on a slow physical machine.
- Installed systems booted four times (ISO #4 twice, offline and on NAT; ISO #5 and ISO #6 once each, on NAT): GRUB, Plymouth and the greeter themes were seen working.
  Nothing was booted on KVM or real hardware, in BIOS mode or under Secure Boot.
- `pacman -Sw` / `bsdtar` / `pacman -S` of a real newer installer package, and `pkexec-wrapper` with a real desktop.
- `kdialog` is not in the live package list (checked in the built demo ISO: `libnotify` is). The launcher falls back to
  `notify-send` (critical urgency), which is easy to miss. Add `kdialog` to `iso/overlay/packages.add`.
- The Arch provisioner itself (`backends/arch/provision/provision.sh`) had not run on CachyOS when the model check was written, so the check was
  tested against a stand-in `ollama` (its `list` output and a server that comes up late or never). It has since run on the installed systems of ISO #4,
  ISO #5 and ISO #6, against a real server: `ollama list` as root answered once `HOME` was set and the three models were found (status 0 on ISO #5 and ISO #6) [V]. Still
  from the documentation and not seen: that a pull resumes after `systemctl stop`.
  The first-boot unit and the retry timer were checked with `systemd-analyze verify` (systemd 262 in the builder image: nothing but the
  emulation artefact below) and by the tests of their text. They have since run under systemd on ISO #5's installed system: `Type=exec` kept
  `graphical.target` from waiting (reached after 37.8 s with the unit running) [V].
- The installer stylesheet was rendered offscreen with PySide6, the Breeze style and the CI-OS-Dark palette (the selected rows, the progress
  bar with its text, the netinstall tree, the bootloader page with the real picture), not in Calamares itself: the widget names come from the
  pinned package's strings and its stock stylesheet, not from a run. The same holds for the popup and radio rules of ISO #5's second look (the harness is not Calamares: the real
  popup showed no highlight at all, the harness a faint one, so the fix is the menu-style popup that the stylesheet paints itself). The real window of ISO #6 answers it: the zone popup reads (check mark and highlight) and the
  radio buttons show their ring and dot, while the language popup's right-hand column and the filesystem drop-down still do not (KI-09).
- The `settings-drift`, `list-drift` and `code-names` guards were tested on the recorded SHAPE of 3.4.2-13 and on edited copies of
  it (empty file, flow style, renamed key, comment on the header, added and removed items), with BSD awk 20200816 and gawk 5.4.1;
  not on a newer upstream release.
- nginx and the units were checked once by hand in a throw-away builder container (Arch, nginx 1.30.5, systemd 262), not by the
  tests: after `stage-headless.sh --root /` on the package's stock `nginx.conf`, `nginx -t` succeeds (one `types_hash` warning,
  harmless) and `nginx -T` shows both the stock `localhost` server and the portal's `listen 80 default_server`;
  `systemd-analyze verify` reports nothing about the first-boot service and timer except "Command ... is not executable: Invalid
  argument", which it prints for `/usr/bin/true` too (an artefact of the emulated container). No daemon was started.
- The drain of the output (the EXIT trap of `first-boot-setup.sh`) is tested without systemd (`progress-filter.sh`, section M: a process
  group that is SIGTERMed when the main process exits, which is what `KillMode=control-group` does) and, by hand, under a real systemd USER
  manager (`first-boot-drain-container.sh`; the control without the trap loses the tail 10 of 10 runs there). That script needs a
  container where `systemd --user` starts: in the amd64 builder image under Rosetta it stops with "Failed to pin executor binary ...
  Invalid argument" (the same artefact as above), so its run here was in an arm64 Ubuntu 26.04 container (systemd 259) with gawk. It is
  not the unit on a booted CachyOS.
