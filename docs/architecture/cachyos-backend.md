# Companion OS on CachyOS: architecture of `backends/cachyos/`

> Status (re-written 2026-10-18): the build system, overlay, installer overlay, provisioning and verifier exist and are unit-tested on fixtures.
> **Six Companion OS ISOs have been built from this overlay. ISO #4, ISO #5 and ISO #6 were each run end to end under QEMU/OVMF software emulation (TCG, no KVM): live boot to the Plasma
> desktop (first graphical frame 4 min 10 s, 4 min 05 s and 5 min 08 s after Enter in GRUB), the Calamares online install (47 jobs, 22 min 9 s on ISO #4, 23 min 20 s on ISO #5, 28 min 26 s on ISO #6), the installed boot
> and first-boot provisioning with three Ollama models pulled (16 min 4.6 s on ISO #4, which ended "degraded"; 21 min 49 s on ISO #5 and 21 min 19 s on ISO #6, which ended with status 0/SUCCESS and no "degraded")** [V].
> The defects the ISO #4 run exposed were fixed in commit `552063f`, and ISO #5 shows the first-boot, boot-target, log-size, update-notifier and most of the installer-look fixes working on an
> installed system [V]. The defects of the ISO #5 run were fixed in commit `ad37b64`, and **ISO #6, built from that clean commit, installed on its first attempt** (the keyring step took 32 s under its new
> explicit limit, KI-20), shows a clean installed GRUB menu, the "Companion OS" driver-job label and the zone popup and radio highlights, and passed `verify-iso.sh` with **215 passed, 0 failed** [V]. Open on the ISO #6 record: the keyring result
> is one run, three Calamares highlight gaps (KI-09), raw pacman output that names CachyOS packages and the splash wording (KI-08), and small log and copy leftovers (KI-26). Nothing has run on KVM or on real hardware.
> The ISO #6 records and its 29 frames are in `docs/evidence/2026-10-18-plasma-iso6/` and `docs/ui/companion-os/plasma/`. See [Test status](#test-status).
> Private & Confidential, Lifescope Inc. Entry points and commands: [`backends/cachyos/README.md`](../../backends/cachyos/README.md).
> Provenance and licences: [`backends/cachyos/NOTICE`](../../backends/cachyos/NOTICE).

Companion OS for CachyOS is a live and installer ISO built from the **pinned upstream profile**
([CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO): archiso, KDE Plasma, `plasma-login-manager`, the online
Calamares installer) plus a **Companion overlay**. It is the first archiso-based backend of this repository. It does not fork
the profile and does not run upstream's own build script.

## Contents

1. [Architecture: pinned upstream plus overlay](#architecture-pinned-upstream-plus-overlay)
2. [The three provisioning layers](#the-three-provisioning-layers)
3. [Identity: why `ID` stays `cachyos`](#identity-why-id-stays-cachyos)
4. [How branding survives `pacman -Syu`](#how-branding-survives-pacman--syu)
5. [Online installer: known external endpoints (not exhaustive)](#online-installer-known-external-endpoints-not-exhaustive)
6. [Secure Boot and the Companion Stick](#secure-boot-and-the-companion-stick)
7. [Building on Apple silicon: Rosetta limits](#building-on-apple-silicon-rosetta-limits)
8. [Booting under QEMU](#booting-under-qemu)
9. [Verification](#verification)
10. [Test status](#test-status)
11. [Risk register](#risk-register)
12. [What is not done](#what-is-not-done)

## Architecture: pinned upstream plus overlay

Why not the alternatives: a fork of the profile turns every upstream bump into a merge (9 commits since 2026-07-01 and 33 since
2026-04-01 at the time of the research); a profile of our own on archiso's `releng` would make us own about thirty files and the keyring,
autologin, nvidia and ZFS plumbing that moves with CachyOS; upstream's `buildiso.sh` rewrites its own source tree, runs `sudo sed`
on `/usr/bin/mkarchiso`, fetches an unpinned mirrorlist from `raw/master` and dies at `sudo chown $USER` in a container
(the research notes of 2026-10-15 and 2026-10-16, kept outside the repository, list thirteen such problems in their section 1.2).

```
host (macOS or Linux, only docker)                       throw-away privileged linux/amd64 container (Arch, archiso)
  build-iso.sh ------ docker cp (tar stream) ----------> /work/repo  (backends/cachyos core vendor assets)
                                                          10-bootstrap.sh   [cachyos] repo + key (fingerprint checked), render deps
                                                          20-build.sh       clone the pin, check commit and tree id
                                                            render-assets.sh   brand assets -> STAGING tree (nothing committed)
                                                            installer/render-installer-assets.sh   Calamares overlay + payload -> same tree
                                                            generators of upstream's util-iso.sh replayed into a GENERATED tree
                                                            apply-overlay.sh   copy upstream archiso/ -> patches -> generated ->
                                                                               overlay/files -> staging -> packages -> profiledef
                                                                               -> guards (a) to (e)
                                                            stock mkarchiso    (xz squashfs, hybrid BIOS + UEFI)
  output/ <---------- docker cp, sha256 re-checked ------ /work/out  iso, .sha256, .pkgs.txt, .build-info
  verify-iso.sh (in the builder image, ISO mounted read-only)
```

The build packs the **working tree**, not a commit (the container has no `.git`): every file under the subset in
`iso/scripts/repo-subset.txt` goes in as it is on disk, including untracked and ignored ones (the installer's payload staging
takes every file of `core/headless/payload` for the same reason). `build-iso.sh` therefore lists, before it starts, what in that
subset is not exactly what HEAD has; `--require-clean` turns that into an error (a release build), `--allow-dirty` says it is
intended. The build record carries `REPO_COMMIT`, `REPO_TREE` (`clean`, `dirty` or `unknown`), the counts of changed, untracked
and ignored files, a digest of what was copied and a digest of the payload file list; `verify-iso.sh` reports `REPO_TREE` and
fails on anything but `clean` under `VERIFY_REQUIRE_CLEAN=1`. The output directory is checked before the build starts, and a build
that finished but could not be copied out keeps its container and volume, with the recovery `docker cp` command printed.

The overlay has one format (decision D5), the same for every kind of change:

| Part | Meaning |
|---|---|
| `files/` | merged over the copy of upstream's `archiso/` (`files/airootfs/etc/...`, `files/grub/...`, `files/syslinux/...`) |
| `patches/NNNN-*.patch` | `git apply -p1`, exact context, no fuzz: upstream drift fails loudly instead of mis-applying |
| `packages.add`, `packages.remove` | one package per line, `#` comments; removing a package upstream lacks is fatal |
| `profiledef.append.sh` | appended to `profiledef.sh`: edition identity, and a `file_permissions` entry for every executable |
| staging tree (`CI_OS_STAGING_DIR`) | generated at build time by `render-assets.sh` and `installer/stage-installer.sh`, same shape as `files/`, merged after it |

Rules the engine enforces (`apply-overlay.sh`, guards (a) to (e)), because each is a failure that otherwise appears 20 minutes
into `mkarchiso`, or in the booted image:

* **(a)** the `linux` / `initrd` lines of the GRUB menus and the `LINUX` / `INITRD` / `APPEND` lines of the syslinux menus are
  byte-identical to upstream's unless a patch says `# ci-os: allow-kernel-line-change` (they decide whether the live system finds
  its medium). The marker licenses that patch and nothing else: what the generated layer, the overlay files and the staging tree
  add afterwards is compared with the state right after the patches, so a marked patch does not switch the guard off for the rest
  of the profile. Which lines a marked patch may change is not the engine's business: `iso/tests/overlay-brand.sh` pins the one
  change the real patch makes (the BIOS Memtest path, patch 0002) and fails on any other, and on a marker in any other patch;
* **(b)** no overlay file in a location a package owns: `pacstrap` aborts on a file that a package also ships, unless the package
  lists it in `backup=`. Our own names (`zz-ci-os-*`, `ci-os-*`, `companion*`) are listed with a justification in
  `overlay/package-owned-ok.txt`; anything else is done by a PostTransaction pacman hook, the pattern upstream's own
  `90-cachyos-live-kwin-keyboard.hook` uses;
* **(c)** every executable has a `file_permissions` entry (mkarchiso drops modes and keeps only the listed ones);
* **(d)** `iso_name`, `iso_label`, `iso_version`, `iso_publisher`, `iso_application` and `install_dir` match the edition identity
  in `upstream.lock`, and none contains `cachy`;
* **(e)** the package list still has `syslinux`, `grub` and `mkinitcpio-archiso`.

The package set is not pinned and cannot be: CachyOS has no snapshot service, and its packages are built against current Arch.
`<iso>.pkgs.txt` and `<iso>.build-info` (which holds the repository database hashes) are the record of a build.

## The three provisioning layers

The CachyOS installer builds the target with `pacstrap` plus a package transaction from the network; it does not unpack the live
squashfs (`unpackfs` exists only in an offline flow that upstream dropped). **What is baked into the live image does not reach the
installed system by itself.** Companion OS therefore provisions in three places:

| Layer | When | Mechanism | Holds |
|---|---|---|---|
| L1 live image | ISO build | airootfs overlay, pacman hooks, `packages.add`, render step | name and identity, boot menus, wallpaper, colour scheme, the launcher and `calamares-online.sh`, the Calamares overlay under `/usr/share/ci-os/calamares`, the carry-over manifest and the files it names (hooks, icon, themes) |
| L2 Calamares | install time, network up | `packages_online.conf` `operations`, `users.conf`, `services-systemd.conf`, the `ci_os_stage` shellprocess (`dontChroot`), the `ci_os_fixups` shellprocess (chroot) | Docker, compose, buildx, `jq`, the wireless-setup stack and the other core packages; the `docker` group; the setup-portal payload (`stage-headless.sh`); the first-boot unit and the provisioning tree under `/usr/lib/ci-os/bootstrap`; the identity (`/usr/share/ci-os/installed/carry-over`); unit enabling (`docker`, `setup-backend`, `setup-network-monitor`; `nginx`, `hostapd-setup` and `dnsmasq-setup` are not enabled, see below); GRUB, the Companion GRUB and Plymouth themes, the hostname |
| L3 first boot | first boot of the installed system, network up | `ci-os-first-boot-setup.service` and its timer, `first-boot-setup.sh`, `provision/provision.sh` | the Arch provisioner behind a wrapper: `ci` user, `uv`, Node.js through asdf, Ollama configuration and models, CI-Hub (needs registry credentials and pairing), at `--tier=core` by default |

L2 and L3 were run end to end three times, on ISO #4, ISO #5 and ISO #6 in QEMU/TCG ([Test status](#test-status)): all three installs succeeded and all three first boots pulled the three models; ISO #4 showed the defects listed there,
and ISO #5 and ISO #6, built with the fixes of `552063f`, ended their first boots cleanly [V]. The reasons the existing Arch scripts were not used as they are (decision D8: `backends/arch/**` is not edited):

* `backends/arch/headless-setup/install.sh` is not safe in an installer chroot: an unguarded `systemctl daemon-reload` aborts it
  under `set -e` when systemd is not PID 1, and it installs packages itself. `provision/stage-headless.sh` stages the same payload
  without pacman or systemctl, with every destination prefixed by `--root`. It also adds the include of `conf.d` that Arch's stock
  `nginx.conf` lacks, so the portal is actually served.
* `provision.sh`'s `detect_user()` falls back to `root` without `SUDO_USER`, which is the case under a systemd unit. The wrapper
  picks the first real account (UID 1000 to 59999, a login shell, an existing home, not `ci` / `liveuser`) and exits 75 when there
  is none yet, so the first-boot driver retries instead of provisioning root. It does not trust the Arch script's exit status for
  the Ollama models either: that script can print "Setup completed successfully!" with no model on the machine, so the wrapper reads
  the required models from `core/manifest/ecosystem.yaml` (`llm.models`), waits for the Ollama server and compares them with
  `ollama list`; a missing model is exit 74 ("degraded"), on which `first-boot-setup.sh` writes no done marker, records
  `first-boot-setup-status` and retries on the next boot or timer tick, up to three automatic attempts (the unit is `Type=exec` and has no `RuntimeMaxSec`:
  the largest model is 17.8 GB, so no finite limit is a promise anyone can keep, and the boot targets do not wait for the run; it was a `Type=oneshot` with
  `TimeoutStartSec=infinity` until `552063f`, which held `graphical.target` for 16 min 27 s on ISO #4). Its output goes through `provision/progress-filter.sh`, which collapses the
  redraws of `ollama pull` (14,052 log lines for three pulls on ISO #4; the filter's test collapses a 3000-redraw flood to 27 lines). It also defaults to `--tier=core`: the Arch
  provisioner's own default tier installs `rocm-hip-sdk` (several GB) and LACT whatever the GPU is.
* The stock flow enables UFW with `default deny incoming`, which would block the setup portal (nginx, DNS and DHCP of the setup
  access point). This edition installs no host firewall and drops the `enable_ufw` step; the reasoning is in
  `backends/cachyos/installer/`.
* The setup portal is not running on a desktop that has a network. Only `setup-backend` (gunicorn on `127.0.0.1:5000`, loopback)
  and the watcher `setup-network-monitor` are enabled at boot. `nginx`, `hostapd-setup` and `dnsmasq-setup` are started by name
  by `setup-device-hotspot-start.sh` when the watcher sees no default route; enabling them too would run an access point at every
  boot (the payload's static config names one vendor board's wireless interface and carries a committed WPA2 passphrase) and open
  port 80, with the setup API behind it, on every network the machine joins. The reasoning and the open issue in the shared payload
  are in `backends/cachyos/installer/README.md` (and `installer/modules/services-systemd.conf`).

**First boot as observed on ISO #4, ISO #5 and ISO #6** (installed system, QEMU/TCG; the last two rows are the unit as `552063f` changed it):

| Condition | What happened | Where it is recorded |
|---|---|---|
| Boot with no route out (a NIC without a network) | `ci-os-first-boot-setup.service` waited 3 min 31 s for the network (30 tries of a ping to 1.1.1.1 and then an HTTPS probe of archlinux.org), printed one warning and exited 0; no attempt was counted; the timer (`OnBootSec=15min`, `OnUnitInactiveSec=15min`) was due again 15 minutes later | `provision/first-boot-setup.sh`, the unit and timer in `provision/systemd/`; guest journal |
| Boot with NAT | The service started 46 s after power-on, `ollama pull` of `nomic-embed-text` and `gemma3:1b` took about a minute each, `qwen3.6:27b` (17.8 GB) about 10 minutes at 26 to 50 MB/s, then cloudflared, corepack/pnpm and tailscale; the CI-Hub deploy was skipped (it needs registry credentials or a pairing, see the endpoint table). The unit was `inactive (dead)` with status 0/SUCCESS after **16 min 4.6 s**; `/var/lib/ci-os/first-boot-setup-status` said `degraded: required Ollama models missing` although `ollama list` showed all three, `.first-boot-setup-done` was not written, and the next automatic run was scheduled (attempt 1 of 3 used). Cause and fix: finding 1 below | guest journal and `systemctl status`, capture notes |
| After the run | `systemctl is-system-running` was `running` (no failed unit), Docker enabled and running, the display manager `plasmalogin` themed with the Companion wallpaper | capture notes |
| ISO #5, boot with NAT (the fixes of `552063f`) | `ci-os-first-boot-setup.service` was `active (running)` from 09:17:42 to 09:39:31, **21 min 49 s**, then `code=exited, status=0/SUCCESS`; `.first-boot-setup-done` was written, there was no status file and no attempts file; `ollama list` showed all three models (the 17.8 GB pull took about 14 minutes at 20 to 29 MB/s plus about 3.5 minutes of digest check). The log has **367 lines** (ISO #4: 14,052) and the unit's journal 386 lines with no "blob data" entry; the closing lines are present. `graphical.target` was reached **37.8 s** after boot (ISO #4: 16 min 27 s) and `is-system-running` was `running` before, during and after the run | `shots/plasma-v5/CAPTURE.md` in the session scratch; [test-evidence.md](test-evidence.md#plasma-edition-iso-5-all-three-stages) |
| ISO #6, boot with NAT (the same unit, `ad37b64`) | The service ran **21 min 18.9 s** (2 min 57 s CPU, 618.7 MB peak) and ended with exit 0; `.first-boot-setup-done` was written; `ollama list` showed all three models (`qwen3.6:27b` 17 GB, `gemma3:1b` 806 MB, `nomic-embed-text` 274 MB; the pulls ran at 15 to 35 MB/s). The log has **301 lines** and the unit's journal 320 lines. `graphical.target` was reached after **43.9 s of userspace** (51.3 s in all) while the run was in progress, `systemctl --failed` was empty and `is-system-running` was `running`. The log still carries the corepack/pnpm stack trace, a `gdm not detected` warning and a Node maintenance warning, and notes that CI-Hub was not deployed for lack of registry credentials (KI-26) | [`docs/ui/companion-os/plasma/CAPTURE.md`](../ui/companion-os/plasma/CAPTURE.md), `docs/evidence/2026-10-18-plasma-iso6/run-record.txt`; [test-evidence.md](test-evidence.md#plasma-edition-iso-6-the-whole-path-on-the-first-attempt) |

The Arch provisioner is run at `--tier=core`, so ROCm and LACT are not installed on first boot; `sudo ci-os-setup --tier=core,hardware` does that on a machine that needs it.

Failure policy of the launcher (decision D6), because the installer package is whatever the repository holds on install day: the
package list and the payload staging **fail closed** (a dialog, exit status 1, nothing is installed); cosmetic strings **fail open**
with a loud log. Before the installer starts, `calamares-online.sh` downloads and unpacks the candidate `cachyos-calamares-next`
into a temporary directory and checks it against `installer/guards.list`; if a critical assumption no longer holds it keeps the
installer that is on the ISO and says so. What the guards compare, because the overlay freezes copies of the installer's own
configuration at the pin (`installer/lib/ci-guards.sh`): `settings-drift` finds a step the installer added to its install sequence
since the pin, and fails critical when the parsed sequence lacks the steps the overlay is built around (`partition`, `pacstrap`,
`packages@online`, `bootloader`), so a file the parser did not understand is not read as "no difference"; `list-drift` does the
same for the frozen `pacstrap` `basePackages` and `postInstallFiles`; `code-names` compares the packages `pacstrap/main.py` adds in
code with `installer/pacstrap-code-added.list`; and `keys` is critical for `pacstrap` and `bootloader`, whose Python modules read
keys directly, and cosmetic for the other module configs. After the guards, and before any disk is touched, the package preflight
asks pacman (`pacman -Si`) about every package the installer is certain to ask for: the base system (`pacstrap.conf`
`basePackages` plus the code-added names), `packages_online.conf`, and the netinstall groups selected by default; names that only
some installs need (a filesystem's tools, an opt-in group) are warned about, not blocking.

## Identity: why `ID` stays `cachyos`

`/etc/os-release` of the live and the installed system (decision D4):

```
NAME="Companion OS"
PRETTY_NAME="Companion OS <version>"
ID=cachyos                         # unchanged
ID_LIKE=arch                       # unchanged, exactly one token
BUILD_ID=rolling
VARIANT="Plasma (based on CachyOS)"
ANSI_COLOR="38;2;R;G;B"            # CI_DARK_PRIMARY of the brand tokens
HOME_URL="https://ci.computer"   SUPPORT_URL="https://ci.computer/support"   BUG_REPORT_URL, PRIVACY_POLICY_URL, DOCUMENTATION_URL
LOGO=ci-os-logo
CI_OS_ID=ci-os   CI_OS_VERSION="<version>"   CI_OS_BUILD="<yyyymmdd>"
IMAGE_ID=companion-os-plasma       # appended by mkarchiso on the live image
```

Why `ID` and `ID_LIKE` are not changed:

* CI-Hub's `scripts/install.sh` reads `ID` and `ID_LIKE` from every os-release-like file in `/etc` and dispatches on **exact
  string equality** with `arch` (first with `ID`, then with `ID_LIKE`). `ID=companion-os` would work only through `ID_LIKE`, and only if
  that is the single token `arch`; `ID_LIKE="cachyos arch"` fails the test. Keeping the base's machine identity keeps every such tool
  working, as the Ubuntu edition keeps `ID=ubuntu`.
* Third-party tools (fastfetch's logo choice, scripts that special-case CachyOS) key off `ID`. That is inference, not verified.
* The human-facing strings, which are what users read, are all Companion OS.

**Open cross-repo finding.** CI-Hub's `fleet-preflight.ts` recognises a Companion OS machine with the regular expression
`^(PRETTY_NAME|NAME)=["']?CI[ -]?OS\b`. `NAME="Companion OS"` does not match it (checked with a Node expression on 2026-10-15), and
this is already true of the Ubuntu edition. `CI_OS_ID=ci-os` is the marker a robust check should read. Not changed here.

## How branding survives `pacman -Syu`

CachyOS's `cachyos-hooks` package rewrites `/etc/os-release` after **every** transaction that touches `filesystem`, `lsb-release` or
`cachyos-hooks` itself (`os-release.hook`, `lsb-release.hook`, `cachyos-branding.hook`, which `sed` the file to
`NAME="CachyOS Linux"`). A file written once is CachyOS's again at the next update.

| Mechanism | Used for | Why it survives |
|---|---|---|
| A **later-sorting hook**: `zz-ci-os-os-release.hook` | `/etc/os-release` and `/etc/lsb-release`, rewritten whole | libalpm runs hooks in the alphabetical order of their file names, suffix ignored, across all hook directories; `zz-` sorts after `cachyos-branding`, `lsb-release` and `os-release`. It is a permanent hook: it is in the live image and is carried to the installed system |
| A **path nobody owns** | icon `ci-os-logo.svg`, `/etc/xdg/kcm-about-distrorc`, `/usr/share/color-schemes/CI-OS-Dark.colors`, `/usr/share/wallpapers/companion`, `/usr/share/grub/themes/companion-os`, `/usr/share/plymouth/themes/companion-os`, `/etc/plasmalogin.conf.d/10-companion-os.conf` | no package ships these paths, so no upgrade overwrites them |
| A **PostTransaction hook that edits a package's file after the package is installed** | `zz-ci-os-skel.hook` (start-button icon, wallpaper, colour scheme, no Breeze splash in `/etc/skel`), `ci-os-neutralise-hello.hook` (live only) | a file a package owns can not be shipped from the airootfs (`pacstrap` aborts), but it can be edited afterwards; the skel hook fires again whenever `cachyos-kde-settings` is upgraded |
| **Carry-over** | everything above, onto the installed system | `/usr/share/ci-os/installed/carry-over <target>` copies the paths of `carry-over.list` and runs the two hook scripts once, because a hook only fires when a package it watches changes. The Calamares step that runs it sits after the packages and before `plymouthcfg`, `initcpio`, `grubcfg` and `bootloader`, which read what it copies |
| **`backup=` files** | `/etc/issue` (`\S{PRETTY_NAME} \r (\l)`, so it follows os-release), `/etc/plymouth/plymouthd.conf`, `/etc/default/grub` | pacman keeps a modified `backup=` file and writes the package's copy as `.pacnew` |

`/usr/lib/os-release` is Arch's `filesystem` file and says Arch Linux; `/etc/os-release` must be a **regular file** (the hook
replaces the symlink, it does not write through it), which `verify-iso.sh` asserts.

What can not be changed and is disclosed instead: kernel and package names (`linux-cachyos`, `uname -r` ends in `-cachyos`),
the `[cachyos]` repository, Firefox's "for Arch Linux" distribution string (package-owned), the `cachyos-*` units and tools
(`cachyos-rate-mirrors`, ...), and `ID=cachyos` itself. `cachy-update` was on this list until the ISO #4 run showed it was the only CachyOS-named
entry in the installed desktop's menu and tray; since `552063f` it is not installed (`netinstall.yaml`), its user timer is not enabled, and
`ci-os-post-install-fixups.sh` removes it if it arrives anyway (hiding it when pacman refuses).

## Online installer: known external endpoints (not exhaustive)

These are the endpoints that were found by reading the pinned upstream, the installer package sources and our own scripts; the
last column says what this edition does with each. It is not a complete list: what `rate-mirrors` (the program) and Calamares'
stock `locale.conf` contact at run time was not read, and nothing here was observed on a running installed system. A host in
our own scripts and configs that is missing from this table fails `iso/tests/overlay-brand.sh` (part F), unless it is a link
that nothing contacts. Do not use the table as a firewall allow-list or a privacy statement without reading the sources again.

| Endpoint | Used by | When | Edition |
|---|---|---|---|
| the servers of the pinned `cachyos-mirrorlist` (34 active, the first `cdn77.cachyos.org`; `mirror.cachyos.org` is commented out in it) | the `[cachyos]` repository of the live and the installed `pacman.conf` (`Include = /etc/pacman.d/cachyos-mirrorlist`; `20-build.sh` generates the file from `MIRRORLIST_REF`, hash-checked) | live, install, every update | kept; it is the substance of the base |
| `mirror.cachyos.org/repo/$arch/$repo` | `[cachyos]` in the **build** `pacman.conf` only (`10-bootstrap.sh`) | build | by design; the live and installed systems do not use this single server |
| Arch mirrors (`/etc/pacman.d/mirrorlist`: `archlinux.cachyos.org`, `geo.mirror.pkgbuild.com`, ...) | `core`, `extra`, `multilib` | build, live, install | kept |
| `cachyos-rate-mirrors`: the script calls `geoip.kde.org/v1/ubiquity` for the country and then runs the `rate-mirrors` program (its sources: not read), and puts `archlinux.cachyos.org` first in the Arch mirrorlist | `update-mirrorlist` in the stock `initialize_pacman` step, and then the package's own `cachyos-rate-mirrors.timer` on the installed system: the 1st, 11th and 21st of a month plus a random delay of up to ten days, `Persistent=true` | install, then about every ten days | kept (stock). The timer is masked on the live medium (`20-build.sh`); this edition does not mask it on the installed system. From reading the package sources, not observed |
| `archlinux-keyring`, `cachyos-keyring` from the repositories | `calamares-online.sh` (keeps a working `/etc/pacman.d/gnupg` and populates it before the first sync; a missing one is created, an unusable one repaired in place and, as a last resort, emptied in place; upstream deleted it first: [incident F1](#f1-the-launcher-deleted-the-keyring-before-it-could-verify-anything)) | every launcher start | kept |
| `archive.archlinux.org` (the canonical Arch Linux Archive path of `boost-libs-1.91.0-2`, plus its `.sig`) | `iso/scripts/in-container/stage-compat-libs.sh`, the only external download of that step; sha256 and package signature are checked against `compat-libs.lock` | **build time only**; the live and installed systems never contact it | by design ([F2](#f2-calamares-did-not-start-a-boost-soname-skew-between-two-repositories)) |
| `https://cachyos.org` and `https://cachyos.org/versions.json` | `cachyos-hello`'s install gate (unreachable means the install is refused) | live | **removed**: `cachyos-hello` does not autostart and is hidden; the launcher does not call it |
| `https://wiki.cachyos.org` | Calamares welcome page internet check; `internetCheckUrl` is a `required` check | install | **replaced** by `https://example.com` (`installer/modules/welcome_online.conf`): a neutral host, so no project learns who installs when |
| `https://geoip.kde.org/v1/ubiquity` (the installer's own lookup also uses `/v1/calamares`, per `installer/README.md`; that path was not verified) | Calamares welcome page (time zone and locale guess) | install | kept |
| `raw.githubusercontent.com/CachyOS/cachyos-calamares/cachyos-dev/.../netinstall.yaml` | `netinstall.conf` `groupsUrl`, tried first, branch HEAD | install | **removed**: `groupsUrl` is the local file only |
| `https://paste.cachyos.org` | branding `uploadServer` (the failure page's "send log") | install failure | **removed**: no `uploadServer` is set |
| `raw.githubusercontent.com` pinned to `185.199.108.133` in the live `/etc/hosts` | upstream's workaround for mirrorlist fetches | live | kept: upstream's file, not touched by the overlay |
| `debuginfod.cachyos.org` | `cachyos-settings` (`/etc/debuginfod/cachyos.urls`) | on demand | kept (package-owned) |
| NTP servers | `timedatectl set-ntp true` in the launcher | live | kept |
| ICMP to `1.1.1.1`, then `https://archlinux.org/` | our own network probe, `provision/first-boot-setup.sh` | the installed system, on every boot and every 15 minutes until provisioning has succeeded or three automatic attempts have failed | ours (a connectivity test; some networks drop ping, hence the second probe) |
| `astral.sh` (`uv`), `github.com` (asdf and its Node.js plugin), `ollama.com/install.sh`, the Ollama registry (models); `nodejs.org` and `registry.npmjs.org` for the Node.js build and corepack (inferred) | `provision.sh` through the wrapper | first boot of the installed system | from reading `backends/arch/provision/provision.sh`. The ISO #4 first-boot run (QEMU, NAT) reached the Ollama registry (three models pulled) and ran the cloudflared, corepack/pnpm and tailscale steps; which other hosts it contacted was not logged |
| `hub.ci.computer` (CI-Hub registry and cloud URLs) | `core/lib/ci-hub.sh` | only after pairing, or when `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` are supplied: without them the step prints "CI-Hub not deployed" and exits before any network call | from reading; not run |
| build: Docker Hub (`archlinux` base image), `github.com` (the upstream clone), `raw.githubusercontent.com` (the pinned mirrorlist), Arch and CachyOS mirrors, `keyserver.ubuntu.com` / `keys.openpgp.org` (fallback only: the CachyOS key is committed and its fingerprint checked) | `build-iso.sh` | build | by design |

There is no offline install. An ISO built weeks ago installs whatever the repositories hold on install day, and fails if they can
not be reached. An offline Calamares edition (`unpackfs` of the live squashfs) is a follow-up.

## Secure Boot and the Companion Stick

* **Secure Boot is not available** for this ISO. `profiledef.sh` uses `bootmodes=('bios.syslinux' 'uefi.grub')`: an unsigned
  standalone GRUB (`--disable-shim-lock`), no shim, and unsigned CachyOS kernels. A machine with Secure Boot enforced must turn it
  off or enrol keys. CachyOS documents Secure Boot only for installed systems, with user keys through `sbctl` in Setup Mode; that
  is not wired here.
* **`ci-stick` can write this ISO but its boot menu can not start it.** `flash` streams the bundle's boot image byte for byte into
  `CI-BOOT-A`; an archiso hybrid ISO is only bytes to it. The generated menu, however, is built for casper:
  `linux .../casper/vmlinuz boot=casper live-media=... persistent` and `initrd /casper/initrd`
  (`DEFAULT_KERNEL`, `DEFAULT_INITRD` and the entry template in `stick/crates/ci-stick/src/bootcfg.rs`), persistence is an ext4 filesystem labelled `writable` that casper finds by
  label (`PERSIST_FS_LABEL` in `stick/crates/ci-stick/src/flash.rs`), and the signed chain is Microsoft shim, Canonical GRUB 2.14, a Canonical-signed kernel
  ([companion-stick.md](companion-stick.md#secure-boot): a custom or rebuilt kernel "won't boot under Secure Boot through this
  shim"; its 14 pinned GRUB modules and the 122 of the signed image are listed there). An archiso profile for the Stick would need a boot profile in `bootcfg.rs` with
  `archisodevice=/dev/disk/by-partlabel/CI-BOOT-A`, `cow_label=` and `cow_persistent=`, a `boot_profile` field in
  `bundle.schema.json` and the example, and an archiso-shaped boot image for `stick/tests/qemu/`. That is a design from reading
  the archiso hook (`mkinitcpio-archiso`), not built or booted. A CachyOS stick would use the development chain (unsigned
  `BOOTX64.EFI`, Secure Boot off) until the project runs its own MOK and shim.
* Nothing in `core/` or in this backend may depend on `stick/`.

## Building on Apple silicon: Rosetta limits

Docker Desktop on Apple silicon runs `linux/amd64` containers under Rosetta (`archlinux` on Docker Hub is amd64-only). Findings of
the emulated build probe of 2026-10-16 (host load average 49 to 95, so timings are pessimistic):

* The upstream profile as it is (generic `[cachyos]` repo plus Arch `core` / `extra`) builds under Rosetta: `pacstrap`,
  `mkinitcpio`, the kernel packages, `grub-mkstandalone`, `syslinux`, `mksquashfs` with upstream's options and `xorriso`.
* pacman's seccomp download sandbox can not install its filter under Rosetta (`error restricting syscalls via seccomp: 22!`); the
  build container sets `DisableSandboxSyscalls` only when pacman says it must.
* `--cap-add SYS_ADMIN` is necessary and was shown sufficient for a trimmed profile; the full desktop profile was built with
  `--privileged`, which is the default of `build-iso.sh` (`--unprivileged` selects the capability).
* The work directory must be in the container's filesystem. A macOS bind mount can not hold device nodes, root ownership, xattrs or
  case-distinct names.
* **The `cachyos-v3` repositories do not work under Rosetta.** x86-64-v3 instructions run, but CachyOS's glibc build
  (`2.44+r50-3`, shipped only in the v3 repository) does not tolerate Rosetta's missing `faccessat2` system call: `bash [ -r file ]`
  gives wrong answers and the `systemd-tmpfiles` pacman hook fails. x86-64-v4 is not offered by Rosetta at all. The live profile
  therefore stays baseline (decision D3). The installed system gets v3 and v4 repositories on the user's own hardware, added by the
  installer's `detect-architecture` script.
* Timing of the research demo (not of this overlay): 33 min 14 s, of which `pacstrap` hooks 11 min (`mkinitcpio` runs three times)
  and `mksquashfs` 16 min 24 s with no visible progress for about 10 of them.

## Booting under QEMU

What was observed on the **research demo ISO** (QEMU 11.1.2, TCG, no KVM; a 12-core Apple-silicon host at a load average of 13 to
96, guest `q35`, `-cpu max`, 4 vCPUs, 6 GiB, `-vga std`) and what the boot investigation of 2026-10-15 found (header of
[`iso/tests/qemu-boot.sh`](../../backends/cachyos/iso/tests/qemu-boot.sh)). Run names are those of the investigation's
`boot/TIMELINE.txt`; the timelines, serial logs and screenshots (`boot/runs/<run>/`, `boot/evidence/`) live in the research scratch
directory of the session that ran them, **not in this repository**, so the numbers below are a record, not something the
repository can re-check. Times are seconds after QEMU start.

* **The stock image does not finish booting under TCG.** `cachyos-settings` sets `DefaultTimeoutStartSec=15s` for the system and the
  user manager; `systemd-nsresourced` needs about 25 s of vCPU time under TCG to verify and load its BPF-LSM programs and is killed
  after 15 s, repeatedly; `systemd-tmpfiles` (which looks up a group through userdb, activating `nsresourced`) waits for it, so
  `systemd-udevd` does not start; the display driver never loads; and `cachyos-drm-awaiter`'s `drm-module-load.target` gives up 30 s
  after boot. The Plasma user units then miss the same 15 s limit and are killed and restarted. None of this is expected on KVM or
  on real hardware (not tested). Runs `r1` (direct kernel) and `n1` (through `qemu-boot.sh`): emergency mode at 67 to 78 s,
  `systemd-udevd` never started.
* **`qemu-boot.sh` has three modes:** `direct` (the default: QEMU starts the kernel and initramfs it extracts from the ISO with the
  exact kernel command line of the ISO's own `grub.cfg` plus `console=ttyS0`, so no firmware or bootloader is involved), `bios`
  (SeaBIOS and the syslinux menu) and `uefi` (OVMF and the GRUB menu). The serial log is the primary evidence.
* **The relief is in the overlay.** `companion-vm-timeouts` (`iso/overlay/files/airootfs/usr/lib/systemd/system-generators/`, listed
  in `profiledef.append.sh`) is a systemd generator that, when `systemd-detect-virt` reports a VM, gives `nsresourced` 5 minutes,
  `drm-module-load.target` 10 minutes and the user manager 3 minutes. Real hardware is left alone; a VM on KVM gets the longer
  limits too, which only matters when something is slow; the worst case is a VM whose display driver never appears, where the boot
  waits up to 10 minutes for `drm-module-load.target` before dropping to emergency mode instead of 30 seconds. `qemu-boot.sh --selftest` checks that the overlay's file is byte-identical
  to the generator `--vm-fixes` injects, and `verify-iso.sh` checks that an ISO carries it, executable. `--vm-fixes` is therefore
  redundant for an ISO built from the overlay; it still serves the stock research ISO.
* **With the relief the desktop is reached, in direct-kernel mode.** Runs `s1`, `s2`, `f1`, `c1` and `i1` (the stock research ISO,
  `--vm-fixes`): `plasmashell` and `kwin_wayland` up at 149 to 295 s, the first rendered frame at 312 to 526 s. In `f1`
  (`--vm-fixes --expect-screen --settle 120`) the plasma processes were up at 295 s, the first image at 499 s and the screen was
  100 % non-black by 620 s, with the panel, tray and clock drawn (screenshot `desktop-direct-tcg-full-desktop-with-panel.png`).
  `c1` used `-cpu qemu64`: the live image needs nothing beyond baseline x86-64. `i1` injected the in-progress overlay tree
  (`--inject iso/overlay/files/airootfs`; the login prompt read `companion-os login:`) and reached the desktop too. Where the time
  goes: `ldconfig.service` (about 68 s, a linker-cache rebuild on every live boot), `systemd-udev-settle` and the device wait
  (about 33 s each), the `nsresourced` start (about 21 s) and then Plasma itself (`plasmashell` 40 to 70 s after the display manager,
  the first drawn frame 150 to 200 s after that).
* **BIOS and UEFI were checked less far.** With `nsresourced` masked on the kernel command line, `b1` (BIOS, syslinux, LTS kernel)
  reached a serial login prompt at 211 s and `u9` (UEFI, OVMF and GRUB) at 214 s; the screen was black in both, so **the desktop
  was not reached in BIOS or UEFI mode**. `nm1` (BIOS, stock image, nothing typed, no serial console) failed at its 100 s timeout,
  as expected. The UEFI path through OVMF is slow under TCG (the kernel started about 50 s after power-on).
* **Not observed** (research demo): the desktop in `bios` or `uefi` mode. This changed for the Companion OS ISOs: ISO #4, #5 and #6 were booted through **real UEFI** (OVMF without Secure Boot
  and the ISO's GRUB, not direct-kernel mode) and reached the Plasma desktop, see [Test status](#test-status). **Still not observed:** BIOS (syslinux) mode for a Companion OS ISO, the generator on a VM with
  KVM, Secure Boot (the `.secboot` OVMF variant was not tried; the refusal of an unsigned GRUB is expected, not observed) and anything on real hardware. The upstream CI uses quickemu on KVM hosts.

## Verification

`backends/cachyos/iso/scripts/verify-iso.sh` (no root, no boot; `xorriso`, `unsquashfs`, `python3` + PyYAML) asserts, each check able
to fail and a missing file that another part of the edition owns being a **failure, not a skip**:

| Section | Checks |
|---|---|
| 1 medium | file name `companion-os-plasma-<YYYY.MM.DD>-x86_64.iso`; no `cachy` in it; volume label `COMPANION_<YYYYMM>`, at most 32 characters, same month as `/arch/version`; publisher and application strings (D1); El Torito BIOS and UEFI, MBR active and `0xef` partitions, GPT; size window; every file an archiso boot needs; exactly one `/boot/<uuid>.uuid`; the standalone GRUB (`BOOTx64.EFI`) embeds that file name |
| 2 boot menus | Companion titles and no CachyOS or Arch word in titles, labels and help text; no raw `GIT` version placeholder; `default=` and syslinux `DEFAULT` name an existing entry; `background_image` on the medium and menu colours set; syslinux background the size of the menu mode; every kernel line has `archisobasedir=arch` and `archisosearchuuid=<this medium>` (or `img_dev`/`img_loop` for loopback) and points at kernels on the medium; every file the syslinux menu loads exists; **parity** of every upstream `linux` / `initrd` / `APPEND` line with the pinned upstream (needs the checkout); no boot-menu image has the hash of upstream's artwork |
| 3 identity | the D4 keys of `/etc/os-release`, CachyOS named only in `ID` and `VARIANT`, `CI_DARK_PRIMARY` as `ANSI_COLOR`, `IMAGE_ID`/`IMAGE_VERSION`; `/etc/os-release` a regular file; `lsb-release` description; `zz-ci-os-os-release.hook` present, `PostTransaction`, `Target = filesystem`, sorts after the CachyOS hooks; hostname, issue, motd (and no block-letter art), `kcm-about-distrorc`; `sshd.service` masked, `sshd.socket` not enabled, and the `sshd_config.d` drop-ins forbid root and password logins (D7); `liveuser`, `NOPASSWD` sudo, `display-manager.service -> plasmalogin.service`, autologin; a wallpaper package of ours, the `ci-os-logo` icon, the colour scheme and its selection in `kdeglobals`; no CachyOS-named image that no package owns |
| 3b installer entry | an installer `.desktop` of ours that runs `calamares-online.sh`, visible, named for Companion OS; the script is executable, parses, installs `cachyos-calamares-next`, applies `/usr/share/ci-os/calamares` **after** that install, contacts no CachyOS host or GitHub raw, starts `calamares`; `cachyos-hello` absent, or neither autostarting nor in the menu |
| 3c carry-over | `usr/share/ci-os/release` agrees with `os-release`; every path of `carry-over.list` is in the image; the carry-over script is executable |
| 4 packages | the packages the live ISO needs; everything in `overlay/packages.add`; nothing from `overlay/packages.remove`; `pkglist.x86_64.txt` equals the image's own pacman database |
| 5 Calamares overlay | YAML parses; the branding component matches its directory and says Companion OS; no `uploadServer` to CachyOS; GRUB forced (`efiBootLoader: grub`, and a bootloader page that offers only GRUB if the variable is read), `efiBootloaderId: companion-os`; GRUB and Plymouth themes set and present in the image; `docker` in `defaultGroups`, hostname `companion-os`, internet check not a CachyOS host, local `groupsUrl`; the target gets `docker docker-compose docker-buildx jq` and the Arch `ARCH_DEPS`; docker enabled; every instance has a config; no module the package is built without; the staging step runs after `pacstrap`, and carry-over runs after the packages and before `plymouthcfg`, `initcpio`, `grubcfg`, `bootloader`; no CachyOS endpoint or GitHub-raw URL in a configuration file; the live-system paths the steps name exist |
| 6 modes | package-unowned `#!` scripts are executable (the installer overlay under `/usr/share/ci-os/calamares` is staged as data and started with `bash`); `/etc/shadow` and `/etc/gshadow` 0400; `/etc/sudoers.d` 0440; the VM slow-boot generator (`companion-vm-timeouts`) is in the image and executable; the scripts our hooks run exist |
| 7 provenance | `upstream.lock` names the D1 edition; the build record inside the image (`/usr/share/ci-os/iso-build-info`) and the one next to the ISO name the pinned commit, builder image, mirrorlist and key, record overlay and staging hashes, agree with each other and with `os-release` |
| 8 integrity | `<iso>.sha256` matches; `airootfs.sha512` matches the squashfs (what `checksum=y` verifies at boot) |

Since `552063f` the verifier also fails an image whose live package list contains `cachy-update` (or shows or starts it), whose Calamares overlay would install it, whose first-boot unit holds up the
boot targets (it must not be a `Type=oneshot` ordered ahead of them) or lacks `HOME`, whose installer stylesheet leaves the progress bar, the selected rows or the welcome links without a colour that reads, whose bootloader chooser
shows Calamares' placeholder picture, or whose package group descriptions the installer window would cut off. These are checks of the ISO's files; none of them says the installed desktop looks right.

Known residuals are printed, not failed: kernel, repository and package names, `/usr/lib/os-release` (Arch's), the `lsb-release`
`DISTRIB_ID`, the start-menu icon of the stock Plasma layout and Firefox's distribution string.

`backends/cachyos/iso/tests/verify-selftest.sh` tests the checks themselves: every check function runs on a good fixture that must
pass and on a broken one that must fail with the expected message (no Docker, bash 3.2). It found, among others, a check that
passed on CachyOS's own console colour and one that counted a `docker` group as "docker enabled". The first run of the verifier
on a real ISO added one more: two comparisons used `cmp`, which the Arch builder image does not have (no `diffutils`), so they
failed on identical files; the verifier now compares by hash, and the self-test shadows `cmp` and `diff` to keep it that way.

`backends/cachyos/iso/tests/verify-mini-iso.sh` runs the verifier on real overlay output without a 40 minute build: it fetches the
pinned upstream, renders the assets, merges the overlay with the build's own engine, runs the pacman hooks' scripts on the merged
root, writes a 15 MB hybrid BIOS + UEFI ISO with `mkarchiso`'s `xorriso` options and runs `verify-iso.sh` on it (about two
minutes, Docker and network). It stands in for the packages with names only, so it says nothing about the package set, the kernels
or a boot. It is what found two integration defects (the BIOS Memtest entry pointed at a file `mkarchiso` does not install, and
`20-build.sh` did not stage the installer overlay; both are fixed, in overlay patch 0002 and in `20-build.sh`, which now runs
`installer/render-installer-assets.sh`) and a false positive in the verifier (a path in a comment of `kcm-about-distrorc` counted
as a brand leak). It has not been re-run since those fixes; the first full build contains both.

## Test status

Honest columns. "Built" means `mkarchiso` finished; "booted" means a kernel started the system and it reached the stated point;
"installed" means Calamares ran to the end on a disk; "verified" means `verify-iso.sh` ran on the ISO. Logs and screenshots named
here are in the research scratch directory of the session that produced them, not in the repository, **except those of ISO #6**, whose records and frames are in `docs/evidence/2026-10-18-plasma-iso6/` and `docs/ui/companion-os/plasma/`. The numbering of the Companion
OS ISOs (#1 to #6) is the order of the builds below. Tags: **[V]** a log or capture record shows it, **[N]** not done.

| Artifact | Built | Booted | Installed | Verified |
|---|---|---|---|---|
| Research demo ISO (`companion-os-cachyos-2026.10.03-x86_64.iso`, 3,097,133,056 bytes: pinned upstream, one file, one patch, `docker` and `docker-compose` added, `occt` removed) | yes, 2026-10-16 (container clock), 33 min 14 s under Rosetta | partly, QEMU/TCG (see [Booting under QEMU](#booting-under-qemu)): the desktop is reached in direct-kernel mode with the VM relief (runs `s1`, `s2`, `f1`, `c1`, `i1`); BIOS and UEFI reach a serial login prompt only (`b1`, `u9`; desktop not reached); without the relief the boot drops to emergency mode (`r1`, `n1`) | no | `verify-iso.sh` against it: 58 passed, 50 failed, 3 groups skipped (no build record, `.pkgs.txt` or `.sha256` exists for the demo). The generic checks pass (label, El Torito, MBR and GPT, boot files, uuid search, kernel-line parity with the pin, package list against the pacman database, `airootfs.sha512`, modes); every Companion-specific one fails, which is what an ISO without the overlay should do |
| Companion OS ISO from this overlay (`companion-os-plasma-2026.10.16-x86_64.iso`, 3,217,129,472 bytes, 1006 packages, sha256 `19f0583e3760a8cf911467aaa6fb71e6a7ca1af78650927d9215010d71a442bf`; first full build, pin `3215497d`) | yes, 2026-10-16 (container clock): `mkarchiso` 32 min 46 s, about 37 min from the start of `build-iso.sh` to the copied ISO, under Rosetta on a loaded host | yes, `qemu-boot.sh --mode direct --expect-plasma --expect-screen`, QEMU TCG without KVM, no `--vm-fixes` (the overlay carries the generator): PASS. Guest agent and serial login at 138-141 s, plasmashell and kwin_wayland running at 149 s, first rendered desktop at 266 s, 357 s with the 90 s settle (host load 25-90). It showed the stock KDE "Next" wallpaper, not ours: Plasma ignores the saved desktop containment because its activity id differs; `apply-wallpaper` (autostart, once per user) is the fix and has not been booted yet. BIOS and UEFI menus of this ISO were not booted | no | `verify-iso.sh` in the builder image, run 1 (the first verifier): 180 passed, 3 failed; run 2 (verifier fixed): **182 passed, 1 failed**. The remaining failure is real: CachyOS Hello's application-menu entry is still visible, because the hook that hides it did not take effect in this ISO (the hook's `sed` quoting was wrong under pacman's parser; it is fixed in the tree, see the header of `ci-os-neutralise-hello.hook`, and shows only in a rebuild). The two other failures of run 1 were the verifier's, not the ISO's (`cmp` is not in the builder image). Sections 2 (boot menus: every file the syslinux menu loads, the Memtest binary included, is on the medium) and 5 (the Calamares overlay) pass |
| Companion OS ISO #2 (`companion-os-plasma-2026.10.16-x86_64.iso` rebuilt from the clean commit `16271e6`, 3,217,129,472 bytes, sha256 `9f0afab64be9cac10f199bffa9aa4851c33880623bf473838b4b137be60506d9`; includes every review fix, the Hello hook fix and `apply-wallpaper`) | yes, about 31 min under Rosetta on a loaded host; the build record says `REPO_TREE=clean`, `KERNEL_LINES_SHA256` as expected | yes, `qemu-boot.sh --mode direct --expect-plasma --expect-screen --settle 180`, QEMU TCG: PASS. plasmashell and kwin_wayland at 245 s, first drawn desktop at 421 s (host load 25-90). The desktop shows the Companion OS wallpaper and a teal panel; the stock "Next" wallpaper of ISO #1 is gone. BIOS and UEFI menus not booted | no | `verify-iso.sh` in the builder image: **187 passed, 0 failed** |
| Miniature ISO from the real overlay and renderer (`verify-mini-iso.sh`: 15 MB, no packages, no `mkarchiso`; `xorriso` and `mksquashfs` only) | n/a | no | no | run of 2026-10-16 (container clock), about 2 minutes: `apply-overlay.sh` guards (a) to (e) pass on the pinned upstream; `verify-iso.sh`: 182 passed, 1 failed, the failure being the BIOS Memtest path that overlay patch 0002 fixes. No log of that run is kept in the repository and it has **not been re-run** since the fixes (re-run needed) |
| Installer overlay (Calamares) | n/a | n/a | **run on ISOs #4, #5 and #6** (rows below); not run on #1 to #3 | `verify-iso.sh`'s static analysis of the overlay inside the built ISO passes (section 5 of runs 1 and 2); the installer tests run the guards and the launcher against stubs and a recorded copy of the pinned installer's shape. Before ISO #4, Calamares itself had never run: ISO #3 could not start it (incidents F1 and F2 below) |
| Companion OS ISO #3 (`companion-os-plasma-2026.10.18-x86_64.iso`, sha256 `607d678e910c68c2d1237c7d6584109c4ecbc53a22362a9e328295011be5c9e1`, built from the clean commit `6e7b0b5`) | yes, 2026-10-18 | yes, QEMU/OVMF: live desktop reached; "Install Companion OS" could not start the installer | no | the result at the time is not recorded in the notes I could find; with the compat-library checks added afterwards it fails 8 (`verify-v3.log` of the fix run: 182 passed, 8 failed; the failures are the three missing boost libraries and five missing `COMPAT_*` build-record keys), as intended. Two defects, F1 and F2, below |
| Companion OS ISO #4 (`companion-os-plasma-2026.10.18-x86_64.iso`, 3,217,129,472 bytes, sha256 `f5cda84f60b585e85895552c5738aaf2a3ddba381a838538ce5d58fe9cff8790`, clean commit `d7b3a7b`, upstream pin `3215497d`, 202 packages listed, `COMPAT_LIBS=3`) | yes; the installer gate passed inside `mkarchiso` (build log) | **yes, [V]**: real UEFI (OVMF, no Secure Boot), GRUB menu 2.2 s after power-on, first graphical frame 4 min 10 s after Enter in GRUB (4 min 35 s after power-on), desktop settled about 6 min 35 s, host load average 2.5 to 9 | **yes, [V]**: Calamares ran all 47 jobs to `completion: succeeded` on a 30 GiB NVMe disk (Erase disk, btrfs, GRUB); Install Now to finish 22 min 9 s (the whole stage with the page walk-through about 40 min); `pacstrap` 7 min 14 s, `packages` 8 min 16 s, `mkinitcpio` 1 min 50 s | `verify-iso.sh` result for #4: not in the capture notes [N]. **Installed boot [V]**: GRUB menu with the Companion theme, Plymouth, the Plasma Login Manager greeter at 113 s (offline boot), first login, desktop 55 s after login, `systemctl is-system-running` = `running` after provisioning; two boots, one offline (the unit waited 3 min 31 s, exited 0, no attempt counted) and one on NAT. **First boot with a network [V]**: 16 min 4.6 s, `ollama pull` of `nomic-embed-text`, `gemma3:1b` (about a minute each) and `qwen3.6:27b` (about 10 min at 26 to 50 MB/s), all three present in `ollama list`, but it ended **degraded (74)** because of a defect (below) |
| Companion OS ISO #5 (`companion-os-plasma-2026.10.18-x86_64.iso`, 3,217,129,472 bytes, sha256 `2e254487ba6a24d1602e2b7ab9163468170cb83e55d60498f4f14623a19e0b5e`, clean commit `552063f`, `COMPAT_LIBS=3`) | yes, 25 min; installer gate passed | **live yes, [V]**: GRUB 2.7 s, first frame 4 min 5 s after Enter, desktop settled 5 min 8 s; Calamares started from the menu entry without hand work (194 required packages found, guards passed, 7 of 7 requirements); the welcome page no longer shows the dark pictogram. **Installed boot yes, [V]** (NAT): greeter at 107 s, `graphical.target` after 37.8 s (ISO #4: 16 min 27 s), `is-system-running` = `running`, `systemctl --failed` empty | **yes, [V], on the third attempt**: all 47 jobs, `completion: succeeded`, 23 min 20 s on a 64 GiB virtual NVMe. Attempts 1 and 2 failed at job 13 (2 percent) with `Command bash /etc/calamares/scripts/create-pacman-keyring failed to finish in 30 seconds` (08:07:42 and 08:24:55 PDT), see item 10 of [the findings below](#what-the-full-run-of-iso-4-found-and-where-each-item-stands) and KI-20 | `verify-iso.sh` for this ISO: no log kept [N]. **First boot [V]**: 21 min 49 s, status 0/SUCCESS, marker written, no "degraded", 367-line log (see the first-boot table above). The re-verification list of the fixes: Support link, bootloader page, package descriptions, no Cachy-Update, first-boot unit and log are seen working; the progress bar, keyboard rows and package rows are visible; combo-box popups and the partition-page selection still have no highlight (KI-09) |
| Companion OS ISO #6 (`companion-os-plasma-2026.10.18-x86_64.iso`, 3,217,129,472 bytes, sha256 `5ab1fe2c422fb8960a0dfd0c2f12f70460d13fb3eb9e13febab5ef2a41802d20`, clean commit `ad37b64`, `COMPAT_LIBS=3`, 202 packages) | yes, about 26 minutes; installer gate passed | **live yes, [V]**: GRUB 2.6 s, first frame 5 min 8 s after Enter, desktop settled 6 min 38 s (host load 13 to 20); Calamares started from the menu entry without hand work (194 required packages found, guards passed with 0 cosmetic warnings, 7 of 7 requirements). **Installed boot yes, [V]** (NAT): greeter 1 min 32 s after Enter, `graphical.target` after 43.9 s of userspace, `is-system-running` = `running`, `systemctl --failed` empty, a GRUB menu with only Companion OS entries and UEFI Firmware Settings | **yes, [V], on the first attempt**: all 47 jobs, `completion: succeeded`, 28 min 26 s on a 64 GiB virtual NVMe; `create-pacman-keyring` 32 s under the explicit `timeout: 3600` (the stock 30 s default is what failed twice on ISO #5), see item 10 of [the findings below](#what-the-full-run-of-iso-4-found-and-where-each-item-stands) and KI-20; `pacstrap` 553 s, `packages` 717 s, `mkinitcpio` 120 s | **`verify-iso.sh`: 215 passed, 0 failed** (about 84 s, no skipped group, `docs/evidence/2026-10-18-plasma-iso6/verify.log`). **First boot [V]**: 21 min 19 s, exit 0, marker written, three models, 301-line log, no update notifier. Open: raw pacman output with `cachyos` names, splash wording, three highlight gaps, log and copy leftovers (KI-08, KI-09, KI-26). Virtual machine only: a second run, Secure Boot, KVM and real hardware were not run |
| `verify-selftest.sh` | n/a | n/a | n/a | **336 checks pass, 0 failed, 0 skipped** on bash 3.2.57 (macOS), run 2026-10-18 at HEAD `02c575e` (the earlier figure was 253 on bash 3.2.57; 242 of those also passed on bash 5.3.20 in the Arch builder container, not repeated). About 20 seconds |

Observed on the installed systems of ISO #4, ISO #5 and ISO #6 (QEMU/TCG): the `os-release` (`NAME="Companion OS"`, `ID=cachyos`, `VARIANT="Plasma (based on CachyOS)"`), the Companion GRUB theme and Plymouth lock-up, the Plasma Login
Manager, Docker enabled and running (`docker --version` 29.9.1), Ollama (`ollama version is 0.40.6` once provisioning had enabled the service), and first-boot provisioning including the three models. **Not observed:** the setup portal reachable
(no Wi-Fi interface in the VM), the `os-release` after a `pacman -Syu`, the setup portal's hotspot, BIOS (syslinux) boot, Secure Boot, KVM and real hardware.

### What the full run of ISO #4 found, and where each item stands

Source: the capture record of the ISO #4 run (live, install, installed boot A offline and B on NAT; `CAPTURE.md` and the guest logs, in the session scratch, not in the repository) and
the commit messages and tests of `552063f` and `ad37b64`. "Fixed" means the code and a test changed; items 1, 2, 3, 5 and, except for two highlight gaps, 6 are **shown working on the booted installed system of ISO #5** [V] (`shots/plasma-v5/CAPTURE.md`), and items 6 (partly), 7 and 10 are **shown working on ISO #6** [V] (`docs/ui/companion-os/plasma/CAPTURE.md`).

| # | Finding (evidence) | Fix, or status |
|---|---|---|
| 1 | **First-boot provisioning ended "degraded" (exit 74) every time although all three models were installed.** `ollama list` ran as root under a system unit with no `$HOME`; the CLI panics ("panic: $HOME is not defined", exit 2) and the wrapper read that as "server never answered" after 30 tries | Fixed: the unit sets `Environment=HOME=/root`, `provision/provision.sh` sets it when unset, and the failure message shows the last stderr of `ollama list`. Test: a stand-in `ollama` that panics without `HOME` (`installer-stage.sh`). Seen failing on ISO #4 [V]; passing on ISO #5: status 0/SUCCESS, marker written, no "degraded" [V] |
| 2 | **The oneshot held `graphical.target`:** `systemd-analyze` said "graphical.target reached after 16 min 27 s" with a network and 3 min 54 s without; `is-system-running` said `starting` for the whole run | Fixed: `Type=exec`, no `network-online.target` ordering (the script polls for the network itself: ping 1.1.1.1, then HTTPS to archlinux.org, 30 tries), `Nice=10`. The unit comment holds the mechanism (systemd.target(5)). Checked with `systemd-analyze verify` and a text test; **seen on ISO #5**: `graphical.target` after 37.8 s, `is-system-running` = `running` during the run [V] |
| 3 | **`ollama pull` redraws flooded the journal and the log:** 14,052 lines / 1.9 MB for three pulls, each redraw a "[147B blob data]" journal entry | Fixed: `provision/progress-filter.sh` (one awk program, a high-water mark per layer, prints each layer every 5 % or 30 s); the driver drains its output in an EXIT trap because `KillMode=control-group` otherwise cut the closing lines (0 of 40 runs lost against a real systemd manager with the fix, 16 of 40 with the awk filter without it, 40 of 40 for the first bash filter). Tests: `progress-filter.sh`, `first-boot-drain-container.sh`. **Seen on ISO #5**: 367 log lines, 386 journal lines with no "blob data" entry, closing lines present [V] |
| 4 | **Disk budget:** the model set took the 30 GiB target from 7.8 GiB (27 %) to 26 GiB (88 %) used | **Open [N].** The guard belongs in the shared gate `ci_os_model_gate_allows` (`core/lib/gpu-detect.sh`), which checks RAM and GPU memory only: [models-tooling.md](models-tooling.md#14-open-items), item 1 |
| 5 | **Cachy-Update** (menu entry and teal "C" in the tray) was the only CachyOS-named UI on the installed desktop | Fixed: not installed, timer not enabled, removed by `ci-os-post-install-fixups.sh` if it arrives. Live medium never had it. **Seen on ISO #5**: no menu entry and no `arch-update-tray` autostart on the installed desktop [V] |
| 6 | **Calamares looked unfinished:** the progress bar's fill had the window colour (inverted, low contrast), selected rows of the keyboard, bootloader, package and partition lists were invisible, dark pictograms on the teal welcome buttons, a zip-archive placeholder on the bootloader page, package descriptions cut off | Fixed in `branding/companion/stylesheet.qss` (colours from the brand tokens, contrast checked in `installer-config.py`), a Companion mark on the bootloader page, shorter descriptions. The stylesheet was rendered offscreen in Qt only. **Seen on ISO #5 [V]:** the Support link has no dark icon; progress bar, keyboard rows and package rows are visible; the bootloader page shows the Companion mark with the GRUB row highlighted; package descriptions are complete. **Not fixed on ISO #5:** combo-box popups and the partition-page selection showed no highlight. `ad37b64` paints the popups and radio buttons; **seen on ISO #6 [V]:** the zone popup and the radio buttons are fixed, three gaps remain (the right-hand column of the language popup, the filesystem drop-down, the selected partition row; KI-09) |
| 7 | **GRUB menu of the installed system lists the VM's firmware leftovers** ("UEFI Firmware Settings", "UiApp", the install DVD, the NVMe, "EFI Internal Shell", a second `companion-os` entry) captured by `grub-mkconfig` | **Fixed in `ad37b64`, seen on ISO #6 [V]** (frame 19 of `docs/ui/companion-os/plasma/`): the installed menu lists Companion OS Linux, Advanced options, UEFI Firmware Settings and Companion OS snapshots; `GRUB_DISABLE_BOOTNEXT` and `GRUB_DISABLE_OS_PROBER` are set in the installed `/etc/default/grub`. Trade-off: another OS next to Companion OS gets no GRUB entry. Not looked into whether real hardware shows the same [N] (KI-08) |
| 8 | **Boot splash (Plymouth) shows the company lock-up** "COMPANION INTELLIGENCE", while the login screen, desktop, About page and `os-release` say "Companion OS" | **Open, wording [N]** (an owner decision whether the splash should carry the product name); unchanged on ISO #6 (frame 20) (KI-08) |
| 9 | **`ollama.service` is installed but disabled until the first-boot run enables it:** `ollama --version` prints two "no server" warnings in that window | **Open, by design for now [N];** `services-systemd.conf` deliberately leaves `ollama` and `tailscaled` to `provision.sh`, which configures them first |
| 10 | **Calamares stopped at job 13 ("initialize pacman"): `Command bash /etc/calamares/scripts/create-pacman-keyring failed to finish in 30 seconds`**, on two of three install attempts of ISO #5 (08:07:42 and 08:24:55 PDT; the third reached job 47). The overlay uses the installer's own `shellprocess_initialize_pacman.conf`, whose command has no `timeout` key, so Calamares' default of 30 s applies; ISO #4 got through the same step. The cause of the failure is the missing `timeout` key (the step takes about 28 s under TCG, so it passes or fails by a margin of seconds); the log line is `Process "/bin/sh" timed out after 30000 ms` | **Fixed in `ad37b64`, seen working once on ISO #6 [V] (KI-20).** Overlay copies of `shellprocess_initialize_pacman.conf`, `shellprocess_modify_mk_hook.conf` and `shellprocess_reset_mk_hook.conf` give every command an explicit `timeout`, and a `shell-timeouts` guard (`installer/lib/ci-shellprocess.py`, a row in `installer/guards.list`) fails when any shellprocess command of the effective sequence has none. Test: `iso/tests/installer-launcher.sh`. **ISO #6 installed on its first attempt; `create-pacman-keyring` took 32 s, past the old 30 s default, and passed** (`docs/evidence/2026-10-18-plasma-iso6/calamares-keyring-excerpt.txt`). One run |
| 11 | Non-fatal Calamares log lines on ISO #4: a sleep-inhibit error (no `PowerManagement.Inhibit` service on the live session), `chcon` not found (8 times), the GRUB pacman hook running `grub-mkconfig` in the chroot before `/boot/grub` exists, a mirror in DE refusing a connection and one answering 404 for two packages, 11 "Unit ... does not exist" lines from the stock `services-systemd` list (cups, vboxservice, vmtoolsd, firewalld, zfs-* ...) | Open, cosmetic [N]; all tolerated by the installer; `grubcfg` and `bootloader` later wrote a good `grub.cfg` (verified on the installed disk). The ISO #6 log has 58 `WARNING` lines, 1 `ERROR` line, eight `chcon` lines and no "timed out" line (KI-26) |
| 12 | Minor, guest logs only: `systemd-time-wait-sync.service` fails on the live medium (the VM has no synchronising clock; `is-system-running` is `degraded` there, `running` on the installed system); `setup-hotspot-start` logs "no Wi-Fi interface found" about every 10 minutes on a machine without Wi-Fi; the corepack/pnpm step prints a harmless Node `MODULE_NOT_FOUND` stack trace into the provisioning log; the live `/usr/local/bin` lists upstream CachyOS helper names (`choose-mirror`, `remove-nvidia`, ...) | Open, cosmetic [N] |

Also seen: the session locks itself after about 13 idle minutes and the screen dims after about 5 (Plasma defaults); the stage-2 worry about `ly@tty2.service` was moot (the unit does not exist).

## Risk register

From the repo-reuse plan written before the build system existed, updated with what the build system and overlay now do about each.

| # | Risk | Status |
|---|---|---|
| R1 | **Rolling-release drift.** Packages are current at build and again at install (`update_system: true`). Observed skew on 2026-10-15: `nvidia-utils` differed between `[cachyos]`, Arch and `cachyos-v3`; Plasma moved to 6.8.0 on the day. On 2026-10-18 it broke the installer itself ([incident F1/F2](#rolling-release-drift-incident-2026-10-18-f1-f2): a boost soname skew; and our launcher's keyring ordering). | Open. Mitigations in place: repository database hashes in `.build-info`; for the one known skew, `compat-libs.lock` plus the build-time installer gate (`gate-calamares.sh`) and the launcher's link check of a newer installer. **Evidence:** ISOs #4, #5 and #6 started Calamares from the menu entry with no hand work [V]. Not done: a canary rebuild, an Arch Linux Archive date for the whole image, a check of every `[cachyos]` ELF. Keep ISOs short-lived. |
| R2 | **Online installer dependency.** Needs fast, stable internet; re-fetches the installer, keyrings and mirror ranking; our overlay sits on whatever installer version is current. | Mitigated, not removed. Guards before the installer starts (`guards.list`), fail closed for package list and payload, neutral internet check, local package groups. No offline path. |
| R3 | **Licensing and trademark.** Not legal advice: see `NOTICE`. No CachyOS artwork shipped; GPL source offer and NVIDIA userspace terms open. | Open; counsel and a written answer from CachyOS needed. |
| R4 | **Secure Boot** unavailable for the live ISO and the Stick. | Open, by design for now. |
| R5 | **No Companion Launcher build** (the only artifact is a `.deb`). | Open; the extended tier is stubbed as on every non-Ubuntu backend. |
| R6 | **NVIDIA open modules, ZFS and GPU stacks** add size and attack surface the appliance does not need but the partition and ZFS modules expect. | Open; the live package list is upstream's plus `kdialog`. ROCm, NVIDIA container toolkit and `ollama-cuda` are hardware-tier items, not in the default package list. |
| R7 | **UFW default-deny blocks the setup portal.** | Resolved by exclusion: no host firewall, `enable_ufw` dropped. A firewall policy that allows the portal is a follow-up; not tested. |
| R7b | **The shared setup portal API and Ollama are reachable on the LAN without a credential** once the portal's nginx has been started (it is not enabled at boot) and, for Ollama, after first boot. The cause is in `core/headless/payload` and `backends/arch/provision`, which every backend ships and this edition does not change. | Open; documented with a suggested fix in `backends/cachyos/installer/README.md`, "Known issue in the shared setup payload". Needs a human reviewer (steward skill: security-sensitive areas). |
| R8 | **Upstream layout changes** (`grub.cfg` shape, hook names). | Mitigated: exact-context patches, guard (a), the pin, and the parity check in `verify-iso.sh`. |
| R9 | **CachyOS repository trust in the live image**: upstream's live `pacman.conf` has `[cachyos] SigLevel = Optional TrustAll`. | Inherited, not changed. Replacing it with `Required` needs a test on the first `-Sy` of a live session. |
| R10 | **Emulated build.** `archlinux` is amd64-only, so a Mac builds under Rosetta. | Proven: six Companion ISOs were built that way (ISO #1 took about 37 minutes from the start of `build-iso.sh`, ISO #2 about 31, on a loaded host). Release builds belong on x86-64. |
| Launcher | Upstream's `calamares-online.sh` re-installs the installer package every time and overwrites `/etc/calamares`. | Addressed: our launcher downloads the candidate package, checks it against `installer/guards.list`, installs it only if it passes (otherwise it keeps the ISO's installer) and then applies the overlay; `verify-iso.sh` checks the order (heuristic). |
| Identity | `cachyos-hooks` rewrites `os-release` on every `filesystem` transaction. | Addressed: `zz-ci-os-os-release.hook`; verified on fixtures only. |
| Arch stager | `backends/arch/headless-setup/install.sh` is not chroot-safe. | Addressed by `provision/stage-headless.sh`; `backends/arch/**` untouched. |
| User detection | `detect_user()` falls back to `root` under a systemd unit. | Addressed by the wrapper's account scan. |
| Config leaks | CachyOS identity leaks in Calamares module configs (bootloader id, GRUB theme, Plymouth, hostname, internet check, upload). | Addressed in `installer/modules`; checked statically by `verify-iso.sh` section 5. |
| Carry-over paths | Carry-over writes files such as `/etc/xdg/kcm-about-distrorc` and `/usr/share/color-schemes/CI-OS-Dark.colors` into the installed system after its packages. `overlay/package-owned-ok.txt` records that nothing in core, extra or the CachyOS packages the live image installs ships them (`pacman -F`, 2026-10-15); the installed system's package set (the netinstall groups, KDE, later versions) was not checked. A package that starts shipping one of them makes `pacman -Syu` abort with "exists in filesystem" until the copy is removed by hand. | Open; the ownership check should also run against the netinstall closure. |
| Identity rewrite | `zz-ci-os-os-release` rewrites `/etc/os-release` and `/etc/lsb-release` whole on every trigger: a key added by an administrator or another tool is lost at the next `filesystem` update, and the ordering against CachyOS's hooks rests on file-name sort order and one build-time check. | Open; by design for now (decision D4 describes the files as ours). |

<!-- BEGIN rolling-release-drift-incident-2026-10-18: written by the fix of that day; the docs phase may move or fold this subsection, nothing else of it is load-bearing -->
### Rolling-release drift incident 2026-10-18 (F1, F2)

The third Companion OS ISO (`companion-os-plasma-2026.10.18-x86_64.iso`, built from the clean commit `6e7b0b5`) was booted under
QEMU/OVMF and its live desktop reached; the installer could not be started from it. Two defects, both found by clicking "Install
Companion OS", both of the ISO and not of the capture. F2 is risk R1 (rolling-release drift), but the skew is older than every Companion OS ISO: the installer was built on 2026-08-13 and `boost-libs` 1.92 reached `[extra]` the same day (`compat-libs.lock`), two months before the first Companion OS ISO was built on 2026-10-16. Nothing exposed it until the installer was first launched on a booted ISO, which was ISO #3 on 2026-10-18 [I: ISOs #1 and #2 carried the same boost 1.92 and were never taken as far as the installer]; F1 is an ordering bug of ours that F2 would have hidden. The capture record (screenshots, logs) is not in the repository.

#### F1: the launcher deleted the keyring before it could verify anything

`calamares-online.sh` ran `rm -rf /etc/pacman.d/gnupg`, then `pacman -Sy archlinux-keyring cachyos-keyring`, and only then
`pacman-key --init` and `--populate`. Without a keyring pacman cannot verify the `[cachyos]` database (`Public keyring not found`,
`cachyos: key "882DCFE4..." is unknown`, `keyring is not writable`, `failed to synchronize all databases`), so every click failed after
about 20 seconds with "The package repositories could not be reached or their keys could not be set up. Connect to the internet and
try again", although the network was fine, and every retry deleted the keyring again. It reproduces exactly with the real pacman in
the builder container: the launcher's old function exits 1 with those four lines; the new one exits 0 from the same start state.

**Fix** (`iso/overlay/files/airootfs/usr/local/bin/calamares-online.sh`, `refresh_keys`):

* A working keyring is never deleted. Missing or empty (`/etc/pacman.d/gnupg`): `pacman-key --init`, then `--populate archlinux
  cachyos`, **before** any database is synced. Present but unusable (no public keyring, or `pacman-key --list-keys` fails): repaired
  in place with the same two steps; only if that does not help are its contents cleared in place and a new keyring made (an earlier
  revision renamed the directory aside as `<dir>.broken.<epoch>`; see the follow-up fixes below). A dangerous directory (`/`, `/etc`, `/etc/pacman.d`) is refused.
* Then the clock (`timedatectl set-ntp true`), then `pacman -Sy` of both keyring packages as before, then `--populate` again.
* A failure is classified from pacman's own output as **keyring** (the dialog says it is not the internet connection), **network**
  ("could not be reached") or **other** ("could not be updated"). The log has the classification, pacman's exact last error line, and
  every `error:`/`warning:` line in order (the last line is usually the generic "failed to synchronize all databases"; the line above it says why).
* `CI_OS_SKIP_KEYRING=1` still skips the whole step.

Tests (`iso/tests/installer-launcher.sh`, section "the keyring"): the stubs **model the defect** (a `pacman -Sy` with no public keyring
fails with the four lines above), so the cases fail on the old code: no keyring, empty directory, working keyring (same files, no
`--init`), broken and repairable, broken and not repairable (cleared in place), network down, keyring error at the sync, `--init` failing,
an unclassified error, skip. Two mutants of the launcher, built from the real file by replacing only `refresh_keys` (the old order, and
the right steps with the init after the sync), must fail the no-keyring case; they do.

#### F2: Calamares did not start: a boost soname skew between two repositories

`cachyos-calamares-next` 3.4.2-13 (built 2026-08-13 00:24 UTC, still the current version in `[cachyos]`, depends on `boost-libs`
without a version) needs `libboost_python314.so.1.91.0`. `boost-libs` 1.92.0-1 reached `[extra]` the same day, eleven hours later, and the
image has 1.92. `calamares` exited 127 (`error while loading shared libraries`). Pointing the missing name at the 1.92 file (what the
capture tried) gives `symbol lookup error: ... undefined symbol: _ZN5boost6python6detail11init_moduleER11PyModuleDefPFvvE`: the ABI
changed. Reproduced without a VM: pacstrap of `cachyos-calamares-next` into a scratch root in the builder container, `ldd` and an offscreen
start (`QT_QPA_PLATFORM=offscreen`; Rosetta runs it) give both failures; `tests/compat-gate-container.sh` keeps the commands.

Options, with what was measured on 2026-10-18:

| Option | Verdict |
|---|---|
| **Older boost libraries next to the current ones, from the Arch Linux Archive, pinned** | **Chosen.** Smallest: three files (`libboost_python314.so.1.91.0` and the two boost libraries it needs, `container` and `graph`; `readelf -d` shows nothing else of boost is needed), under file names that no package ships, so nothing is downgraded and nothing conflicts. The installer stays exactly as CachyOS built it. It retires itself: see below. |
| Downgrade `boost-libs` to 1.91 | Rejected. `libtorrent-rasterbar`, pulled in by `clonezilla`, has a Python binding that needs `libboost_python314.so.1.92.0` (of the 1006 packages the 202 listed ones resolve to, only it and the installer depend on `boost-libs`). A downgrade would also need a local repository or a `pacman -U` step inside mkarchiso. |
| Another Calamares package of `[cachyos]` | Rejected. All 19 `cachyos-calamares*` packages were built before the 1.92 bump (the newest is 2026-08-13 00:24), so none links against 1.92; the overlay is written for `-next` anyway. |
| Pin `[core]`/`[extra]` to an Arch Linux Archive date (`archive.archlinux.org/repos/2026/08/12/` exists) | Rejected for this fix, still the long-term R1 mitigation. It makes the whole ISO months stale, and `[cachyos]` (829 packages) has no snapshots, so its newer packages would become the skewed side; the installed system and the launcher's `pacman -Sy` use the live repositories anyway. |
| Build Calamares ourselves against 1.92 | Rejected: a fork of a package we do not maintain. |

**Mechanism** (`backends/cachyos/compat-libs.lock`; one lock, its header says how to refresh it):

1. `iso/scripts/in-container/stage-compat-libs.sh` (step 2 of `20-build.sh`, before the staging digest) fetches `boost-libs-1.91.0-2` from
   `archive.archlinux.org` (the only external download source of this step; the URL must be exactly the canonical Archive path), checks
   the package's sha256 against the pin, verifies the signature with `pacman-key --verify` (a missing `.sig` fails: `pacman -U` would let
   an unsigned local file through), extracts only the three listed members (regular files, sha256 each), and writes them into the staging
   layer at `/usr/lib/<name>`, mode 0644 (a shared object needs no execute bit, so no `file_permissions` entry). Nothing reaches the
   staging tree unless everything verified. The build record gets `COMPAT_LIBS`, `COMPAT_PACKAGES`, `COMPAT_LOCK_SHA256`, `COMPAT_REVIEW_BY`.
2. `overlay/package-owned-ok.txt` exempts the three paths from guard (b); `check-owned.sh` proves per build, from the repositories' file lists,
   that no package of the image ships them. `ld.so` finds them in its default directory, no `ld.so.cache` entry is needed.
3. `review-by 2026-12-01` in the lock: a build after it warns and records `COMPAT_REVIEW_OVERDUE=1`; `CI_OS_COMPAT_REVIEW=error` makes it a failure (use it for
   a release). When `[cachyos]` rebuilds the installer against the boost of the day, the gate says so ("not needed by cachyos-calamares-next any more"):
   replace the records by one `retired YYYY-MM-DD` line (a lock with no records at all is refused) and delete the three exemption lines.
4. Refreshing (a different boost generation, a different installer): the gate names the missing soname; find the `boost-libs` of that generation in the
   Archive; `stage-compat-libs.sh propose boost-libs <version> <soname>` in the builder prints the lock records (it refuses a package whose signature does not verify);
   paste them, move `review-by`, add the exemption lines, run `iso/tests/installer-config.sh` and `build-iso.sh --stop-after validate`.

**The gate**, so that the next skew fails the build and not the person at the desktop (`gate-calamares.sh`, `mksquashfs-gate.sh`):

* Stock `mkarchiso` calls `mksquashfs <airootfs> <image>` by that bare name once the packages are installed, the profile's `airootfs/` is copied and the
  image is cleaned up. `20-build.sh` starts `mkarchiso` with a shim named `mksquashfs` first on its PATH (only for that call): the shim runs the gate on the finished tree and
  execs the real `mksquashfs` only if it passes. `mkarchiso` is not edited. `20-build.sh` fails the build if mkarchiso finishes without the gate's marker
  (an image type that no longer calls `mksquashfs`, such as erofs, would otherwise skip the gate silently; a first argument that is not a directory fails closed).
* The gate takes the ELF files that `cachyos-calamares-next` owns from the image's own pacman database (24 today, no hard-coded list) and runs `ldd -r` on each: no `not found`,
  no `undefined symbol`, no `version ... not found`; no library in two versions inside the process of `/usr/bin/calamares`; then an offscreen start of Calamares (20 s by default) that
  must still be running at the end, and in whose output a dynamic-linker error fails the gate even if the process survives. Everything that runs a program of the image runs in a read-only
  bind mount of it (the image is left byte-identical; under Rosetta even its translation cache would otherwise land in `/root/.cache/rosetta`). The pinned libraries in the image must
  still have their pinned sha256.
* A failure prints the missing library or symbol, the ELF files that need it, whether the lock lists it (the compat step did not run) and where to fix it, and says that mkarchiso was stopped before the image was squashed.

**Proof** (real packages, builder container, Rosetta; `iso/tests/compat-gate-container.sh` repeats it):

| Image | Gate |
|---|---|
| nothing staged (`CI_OS_COMPAT_LIBS=off` has this effect) | **fails** (about a minute): `missing library libboost_python314.so.1.91.0` (24 ELF files), 57 undefined symbols in `libcalamares.so.3.4`, and the hint that the lock lists the library |
| `libboost_python314.so.1.91.0` as a symlink to the 1.92 file | **fails**: `undefined symbol boost::python::detail::init_module(PyModuleDef&, void (*)())` from `ldd -r`, and the offscreen start's own `symbol lookup error` (exit 127) |
| the three pinned libraries, staged by the real stager from the Archive (sha256 and signature checked) | **passes** (about a minute): 24 ELF files resolve, Calamares stays up for the 20 s start, the image is untouched, no process is left |
| stock `mkarchiso` on a minimal profile (squashfs, `bios.syslinux`; `base`, `linux`, `mkinitcpio-archiso`, `syslinux`, `cachyos-calamares-next`), the shim first on PATH as `20-build.sh` sets it, **no** compat libraries | `mkarchiso` **exits 1** at the squash step with the gate's message in its output; no `airootfs.sfs`, no ISO, no marker |
| the same profile with the three libraries in its `airootfs/` (copied before the packages, as in the real build) | `mkarchiso` **exits 0**: the gate passed inside it, `airootfs.sfs` (651 MB) and the ISO were written, the marker is there; the squashfs holds `libboost_*.so.1.91.0` (mode 0644) next to the 1.92 files |

The offline tests (`iso/tests/compat-libs.sh`, `iso/tests/gate-calamares.sh`, run by `installer-config.sh` and so by `check-repo.sh`) cover the lock
validator (a URL outside the Archive, a member that is not a versioned shared object, a path that leaves `usr/lib`, a bad hash, an unknown record ...), the stager (a changed
package, a failed signature, a wrong member hash, a symlink, a missing member, a failed download each stage nothing), the shim, the wiring in `20-build.sh`, and every verdict of the gate on a fake image.
Each check was mutation-tested: the stager with the sha check, the signature check or the atomic staging removed, and the gate with each of its checks removed, fail the tests that name them.

**Install-day side.** The launcher's update step (`pacman -S cachyos-calamares-next` when the repository has a newer version) has the same hole in the other direction: the package
depends on `boost-libs` without a version, so a rebuild against a newer boost than the ISO's installs fine and does not start. The launcher now unpacks the candidate's `usr/bin/calamares` and
libraries too and runs `ldd -r` on it, with its own libraries first on `LD_LIBRARY_PATH`, before `pacman -S`; a candidate that does not link is not installed, the installer on the ISO (which the build gate proved) is kept, and the person is told.

**What is not verified.** The full ISO has not been rebuilt or booted since this change. The gate ran inside the stock `mkarchiso` only on the minimal profile above. `20-build.sh` ran in the builder container
as far as `CI_OS_STOP_AFTER=validate` (what `build-iso.sh --stop-after validate` runs inside; the container was ours and the repository was mounted read-only, because `build-iso.sh` has a fixed container name):
the real stager fetched `boost-libs-1.91.0-2`, matched its sha256 and verified its signature, the staging layer went from 157 to 160 files, guards (a) to (e) passed with the three exemptions,
`check-owned.sh` found no conflict among the 1006 packages the image installs, and stock `mkarchiso` accepted the profile with the shim first on PATH and stopped at the database sync. An offscreen start shows that Calamares starts and stays up; it does not drive its pages, and no Python job module is run.
The gate and the proof ran under Rosetta, not on native x86-64. The keyring repair-in-place, clear-in-place and retry paths and the candidate link check are tested on stubs only (the mount point is modelled by stubs
that answer EBUSY); the no-keyring path was also run against the real pacman. Only the installer is gated: other packages of `[cachyos]` built against older libraries would fail silently at their first use (a follow-up is to run `ldd -r` over every ELF of the `[cachyos]` packages in the
image and warn). The compat libraries are not carried to the installed system (it has no Calamares). The endpoint table above covers both: its `archlinux-keyring` row describes the launcher's repair-in-place and `archive.archlinux.org` is listed as a build-time host. An "Install Companion OS" icon on the live desktop and panel (the capture found the entry only in the
application menu) was not added: decision D6 says no desktop shortcut, and pinning it to the panel means patching the Plasma layout of `cachyos-kde-settings`; it is a follow-up.

#### Follow-up fixes to F1 and F2 (the verifier's non-blocking findings, same day)

Four changes to the above, each tested and each test made to fail on a broken copy first. (1) `keys_classify` strips URLs, package file names and the names of the two keyring
packages before it looks for a keyring word, and knows `failed to retrieve some files` and HTTP 404/5xx: a 404 on `archlinux-keyring-*.pkg.tar.zst` is a mirror problem, not
(as it was) a keyring problem. (2) A working keyring is also populated before the first `pacman -Sy`; a sync that fails with a keyring-class error repairs the keyring in
place and is retried once (a network or other failure is not); the dialog no longer advises a restart, which rebuilds the same keyring from the same ISO, and says that a
failure that persists means an ISO older than the repository keys, so a newer ISO. (3) A keyring that cannot be repaired has its contents cleared in place (`find`
`-exec rm -rf` of the children, dot files included; a stale `gpg-agent` stopped first; the public files copied to `/var/log` for diagnosis; never the directory itself, and a
path not ending in `/gnupg` or a symlink is refused) instead of being renamed aside, because the directory can be a mount point and `mv` then fails with EBUSY. As shipped it
probably is none: the pinned profile has `etc-pacman.d-gnupg.mount` (a tmpfs) but its `pacman-init.service` does not `Require=` it as archiso's releng profile does, nothing
else pulls it in, and the squashfs of the 2026-10-18 ISO has no such directory (`pacman-key --init` creates it); a one-line upstream change would make it one. (4)
`verify-iso.sh` checks that the lock's libraries are in the image (regular file, the pinned sha256) and that the build record carries the five `COMPAT_*` keys and they agree
with the lock, so that ISO (no keys, no libraries) fails it; the lock validator now accepts a lock whose records were replaced by one `retired YYYY-MM-DD` line (it refused
the documented "delete the records", which would have failed the build of the retirement itself; an empty or header-only lock is still refused) and the check passes for such a
lock with an image that has none. Not verified: no ISO was rebuilt or booted with these changes, and `findmnt /etc/pacman.d/gnupg` on a booted live system was not looked at
(the statement about the mount rests on the unit files and the squashfs listing).
<!-- END rolling-release-drift-incident-2026-10-18 -->

## What is not done

* The whole path (live boot, Calamares online install, installed boot, first-boot provisioning) ran three times, on ISO #4, ISO #5 and ISO #6 under QEMU/TCG; the fixes ISO #4 led to (`552063f`) are seen working in ISO #5,
  and the fixes ISO #5 led to (`ad37b64`) in ISO #6 ([Test status](#test-status)). The identity after a `pacman -Syu` on an installed system, the setup portal's
  hotspot, and anything on KVM, BIOS (syslinux) mode, Secure Boot or real hardware have not been observed.
* Open defects and cosmetic items of the full run: [the findings table](#what-the-full-run-of-iso-4-found-and-where-each-item-stands): the disk-space guard for the model pulls (item 4), the 30-second Calamares timeout of
  `create-pacman-keyring` (item 10; fixed in `ad37b64` and seen once on ISO #6, a second run is open), the GRUB menu clutter (item 7; fixed, seen on ISO #6), the splash wording (item 8, open), `ollama.service` enablement (item 9, open) and the remaining Calamares highlight gaps and raw pacman text naming CachyOS packages (items 6 and KI-08, KI-09, KI-26, open, Low).
* `verify-mini-iso.sh` has not been re-run since the BIOS Memtest path (overlay patch 0002) and the installer staging
  (`20-build.sh` runs `installer/render-installer-assets.sh`) were fixed, and no log of its earlier "182 passed, 1 failed" run is
  kept. The first full build contains both fixes.
* The builder image installs Python and PyYAML (`Dockerfile.builder`); an image built before that has neither, and `verify-iso.sh`
  then lists the Calamares YAML checks under SKIPPED.
* Docker is not part of the live session (the overlay adds only `kdialog` to the live list, and the storage and persistence units
  of the Ubuntu edition are not ported to archiso); the Companion Launcher has no build; the live medium has no Plymouth splash;
  there is no one-click automatic installer for this edition; there is no offline installer edition; there is no GNOME edition;
  Konsole, login-screen accent and Firefox policy branding are not done.
* `BUG_REPORT_URL` and `PRIVACY_POLICY_URL` of `/etc/os-release` (`https://ci.computer/bugs` and `/privacy`) were copied from the
  Ubuntu edition and returned HTTP 404 when requested on 2026-10-15 (`/support`, the home page and `docs.ci.computer` answered 200);
  the two pages do not exist yet.
* The Companion Stick has no archiso boot profile; Secure Boot and `sbctl` are not wired.
* The KDE mixin `backends/_mixins/kde-plasma/65-kde-theme.sh` still targets Plasma 5 tools (`kwriteconfig5`, `qdbus`); this edition
  does not use it (the skel hook writes the files).
* The package set is not reproducible (no Arch Linux Archive snapshot) and there is no scheduled canary rebuild.
* A source offer for the GPL content of the ISO, the licence of the repository as a whole, the header of `show.qml` against
  upstream's licence, and a written answer from CachyOS about the use of their name (`NOTICE` sections 2 and 6): whether "based on CachyOS" may appear in public
  materials (decision D1) is open. Public hosting of the ISO and the holder of its signing key are not decided either; the build writes a `.sha256` and no signature.
* This edition touches files outside `backends/cachyos/`: `docs/architecture/multi-distro-design.md`, `companion-stick.md`,
  `core/README.md`, `core/lib/check-repo.sh`, the root `README.md` and `CLAUDE.md`, and the steward skill's payload-dependency list.
