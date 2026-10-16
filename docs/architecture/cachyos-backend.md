# Companion OS on CachyOS: architecture of `backends/cachyos/`

> Status: the build system, overlay, installer overlay, provisioning and verifier exist and are unit-tested on fixtures;
> **a Companion OS ISO from this overlay has been built and statically verified, but no boot of it is recorded and it has not been installed** (see [Test status](#test-status)).
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

Wired and tested on fixtures, **not run end to end**: all of L2 and L3. The reasons the existing Arch scripts were not used as
they are (decision D8: `backends/arch/**` is not edited):

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
  `first-boot-setup-status` and retries on the next boot or timer tick, up to three automatic attempts (`TimeoutStartSec=infinity`:
  the largest model is 17.8 GB, so no finite limit is a promise anyone can keep). It also defaults to `--tier=core`: the Arch
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
(`cachyos-rate-mirrors`, `cachy-update`, ...), and `ID=cachyos` itself.

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
| `archlinux-keyring`, `cachyos-keyring` from the repositories | `calamares-online.sh` (removes `/etc/pacman.d/gnupg` and re-initialises it, as upstream does) | every launcher start | kept |
| `https://cachyos.org` and `https://cachyos.org/versions.json` | `cachyos-hello`'s install gate (unreachable means the install is refused) | live | **removed**: `cachyos-hello` does not autostart and is hidden; the launcher does not call it |
| `https://wiki.cachyos.org` | Calamares welcome page internet check; `internetCheckUrl` is a `required` check | install | **replaced** by `https://example.com` (`installer/modules/welcome_online.conf`): a neutral host, so no project learns who installs when |
| `https://geoip.kde.org/v1/ubiquity` (the installer's own lookup also uses `/v1/calamares`, per `installer/README.md`; that path was not verified) | Calamares welcome page (time zone and locale guess) | install | kept |
| `raw.githubusercontent.com/CachyOS/cachyos-calamares/cachyos-dev/.../netinstall.yaml` | `netinstall.conf` `groupsUrl`, tried first, branch HEAD | install | **removed**: `groupsUrl` is the local file only |
| `https://paste.cachyos.org` | branding `uploadServer` (the failure page's "send log") | install failure | **removed**: no `uploadServer` is set |
| `raw.githubusercontent.com` pinned to `185.199.108.133` in the live `/etc/hosts` | upstream's workaround for mirrorlist fetches | live | kept: upstream's file, not touched by the overlay |
| `debuginfod.cachyos.org` | `cachyos-settings` (`/etc/debuginfod/cachyos.urls`) | on demand | kept (package-owned) |
| NTP servers | `timedatectl set-ntp true` in the launcher | live | kept |
| ICMP to `1.1.1.1`, then `https://archlinux.org/` | our own network probe, `provision/first-boot-setup.sh` | the installed system, on every boot and every 15 minutes until provisioning has succeeded or three automatic attempts have failed | ours (a connectivity test; some networks drop ping, hence the second probe) |
| `astral.sh` (`uv`), `github.com` (asdf and its Node.js plugin), `ollama.com/install.sh`, the Ollama registry (models); `nodejs.org` and `registry.npmjs.org` for the Node.js build and corepack (inferred, not run) | `provision.sh` through the wrapper | first boot of the installed system | from reading `backends/arch/provision/provision.sh`; not run |
| `portal.companionintelligence.com` (CI-Hub registry and cloud URLs) | `core/lib/ci-hub.sh` | only after pairing, or when `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` are supplied: without them the step prints "CI-Hub not deployed" and exits before any network call | from reading; not run |
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
  (`stick/crates/ci-stick/src/bootcfg.rs:44-45,182`), persistence is an ext4 filesystem labelled `writable` that casper finds by
  label (`flash.rs:49,466-468`), and the signed chain is Microsoft shim, Canonical GRUB, a Canonical-signed kernel
  (`docs/architecture/companion-stick.md:324-360,450-454`: a custom or rebuilt kernel "won't boot under Secure Boot through this
  shim"). An archiso profile for the Stick would need a boot profile in `bootcfg.rs` with
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
* **Not observed:** the desktop in `bios` or `uefi` mode; a boot of a Companion OS ISO (the first one is built, see
  [Test status](#test-status)); the generator on a VM with KVM; anything on real hardware; Calamares, ever. The upstream CI uses
  quickemu on KVM hosts.

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
here are in the research scratch directory of the session that produced them, not in the repository.

| Artifact | Built | Booted | Installed | Verified |
|---|---|---|---|---|
| Research demo ISO (`companion-os-cachyos-2026.10.03-x86_64.iso`, 3,097,133,056 bytes: pinned upstream, one file, one patch, `docker` and `docker-compose` added, `occt` removed) | yes, 2026-10-16 (container clock), 33 min 14 s under Rosetta | partly, QEMU/TCG (see [Booting under QEMU](#booting-under-qemu)): the desktop is reached in direct-kernel mode with the VM relief (runs `s1`, `s2`, `f1`, `c1`, `i1`); BIOS and UEFI reach a serial login prompt only (`b1`, `u9`; desktop not reached); without the relief the boot drops to emergency mode (`r1`, `n1`) | no | `verify-iso.sh` against it: 58 passed, 50 failed, 3 groups skipped (no build record, `.pkgs.txt` or `.sha256` exists for the demo). The generic checks pass (label, El Torito, MBR and GPT, boot files, uuid search, kernel-line parity with the pin, package list against the pacman database, `airootfs.sha512`, modes); every Companion-specific one fails, which is what an ISO without the overlay should do |
| Companion OS ISO from this overlay (`companion-os-plasma-2026.10.16-x86_64.iso`, 3,217,129,472 bytes, 1006 packages, sha256 `19f0583e3760a8cf911467aaa6fb71e6a7ca1af78650927d9215010d71a442bf`; first full build, pin `3215497d`) | yes, 2026-10-16 (container clock): `mkarchiso` 32 min 46 s, about 37 min from the start of `build-iso.sh` to the copied ISO, under Rosetta on a loaded host | yes, `qemu-boot.sh --mode direct --expect-plasma --expect-screen`, QEMU TCG without KVM, no `--vm-fixes` (the overlay carries the generator): PASS. Guest agent and serial login at 138-141 s, plasmashell and kwin_wayland running at 149 s, first rendered desktop at 266 s, 357 s with the 90 s settle (host load 25-90). It showed the stock KDE "Next" wallpaper, not ours: Plasma ignores the saved desktop containment because its activity id differs; `apply-wallpaper` (autostart, once per user) is the fix and has not been booted yet. BIOS and UEFI menus of this ISO were not booted | no | `verify-iso.sh` in the builder image, run 1 (the first verifier): 180 passed, 3 failed; run 2 (verifier fixed): **182 passed, 1 failed**. The remaining failure is real: CachyOS Hello's application-menu entry is still visible, because the hook that hides it did not take effect in this ISO (the hook's `sed` quoting was wrong under pacman's parser; it is fixed in the tree, see the header of `ci-os-neutralise-hello.hook`, and shows only in a rebuild). The two other failures of run 1 were the verifier's, not the ISO's (`cmp` is not in the builder image). Sections 2 (boot menus: every file the syslinux menu loads, the Memtest binary included, is on the medium) and 5 (the Calamares overlay) pass |
| Companion OS ISO #2 (`companion-os-plasma-2026.10.16-x86_64.iso` rebuilt from the clean commit `16271e6`, 3,217,129,472 bytes, sha256 `9f0afab64be9cac10f199bffa9aa4851c33880623bf473838b4b137be60506d9`; includes every review fix, the Hello hook fix and `apply-wallpaper`) | yes, about 31 min under Rosetta on a loaded host; the build record says `REPO_TREE=clean`, `KERNEL_LINES_SHA256` as expected | yes, `qemu-boot.sh --mode direct --expect-plasma --expect-screen --settle 180`, QEMU TCG: PASS. plasmashell and kwin_wayland at 245 s, first drawn desktop at 421 s (host load 25-90). The desktop shows the Companion OS wallpaper and a teal panel; the stock "Next" wallpaper of ISO #1 is gone. BIOS and UEFI menus not booted | no | `verify-iso.sh` in the builder image: **187 passed, 0 failed** |
| Miniature ISO from the real overlay and renderer (`verify-mini-iso.sh`: 15 MB, no packages, no `mkarchiso`; `xorriso` and `mksquashfs` only) | n/a | no | no | run of 2026-10-16 (container clock), about 2 minutes: `apply-overlay.sh` guards (a) to (e) pass on the pinned upstream; `verify-iso.sh`: 182 passed, 1 failed, the failure being the BIOS Memtest path that overlay patch 0002 fixes. No log of that run is kept in the repository and it has **not been re-run** since the fixes (re-run needed) |
| Installer overlay (Calamares) | n/a | n/a | **not run** | `verify-iso.sh`'s static analysis of the overlay inside the built ISO passes (section 5 of runs 1 and 2); the installer tests run the guards and the launcher against stubs and a recorded copy of the pinned installer's shape. Calamares itself has never run |
| `verify-selftest.sh` | n/a | n/a | n/a | 253 checks pass on bash 3.2.57 (macOS); the 242 checks that existed before the last additions also passed on bash 5.3.20 in the Arch builder container. About 20 seconds |

Nothing about the installed system (Docker working, the setup portal reachable, first-boot provisioning completing, the
`os-release` after an update, the GRUB and Plymouth themes) has been observed on a running machine.

## Risk register

From the repo-reuse plan written before the build system existed, updated with what the build system and overlay now do about each.

| # | Risk | Status |
|---|---|---|
| R1 | **Rolling-release drift.** Packages are current at build and again at install (`update_system: true`). Observed skew on 2026-10-15: `nvidia-utils` differed between `[cachyos]`, Arch and `cachyos-v3`; Plasma moved to 6.8.0 on the day. | Open. Mitigation in place: repository database hashes in `.build-info`. Not done: a canary rebuild, an Arch Linux Archive date. Keep ISOs short-lived. |
| R2 | **Online installer dependency.** Needs fast, stable internet; re-fetches the installer, keyrings and mirror ranking; our overlay sits on whatever installer version is current. | Mitigated, not removed. Guards before the installer starts (`guards.list`), fail closed for package list and payload, neutral internet check, local package groups. No offline path. |
| R3 | **Licensing and trademark.** Not legal advice: see `NOTICE`. No CachyOS artwork shipped; GPL source offer and NVIDIA userspace terms open. | Open; counsel and a written answer from CachyOS needed. |
| R4 | **Secure Boot** unavailable for the live ISO and the Stick. | Open, by design for now. |
| R5 | **No Companion Launcher build** (the only artifact is a `.deb`). | Open; the extended tier is stubbed as on every non-Ubuntu backend. |
| R6 | **NVIDIA open modules, ZFS and GPU stacks** add size and attack surface the appliance does not need but the partition and ZFS modules expect. | Open; the live package list is upstream's plus `kdialog`. ROCm, NVIDIA container toolkit and `ollama-cuda` are hardware-tier items, not in the default package list. |
| R7 | **UFW default-deny blocks the setup portal.** | Resolved by exclusion: no host firewall, `enable_ufw` dropped. A firewall policy that allows the portal is a follow-up; not tested. |
| R7b | **The shared setup portal API and Ollama are reachable on the LAN without a credential** once the portal's nginx has been started (it is not enabled at boot) and, for Ollama, after first boot. The cause is in `core/headless/payload` and `backends/arch/provision`, which every backend ships and this edition does not change. | Open; documented with a suggested fix in `backends/cachyos/installer/README.md`, "Known issue in the shared setup payload". Needs a human reviewer (steward skill: security-sensitive areas). |
| R8 | **Upstream layout changes** (`grub.cfg` shape, hook names). | Mitigated: exact-context patches, guard (a), the pin, and the parity check in `verify-iso.sh`. |
| R9 | **CachyOS repository trust in the live image**: upstream's live `pacman.conf` has `[cachyos] SigLevel = Optional TrustAll`. | Inherited, not changed. Replacing it with `Required` needs a test on the first `-Sy` of a live session. |
| R10 | **Emulated build.** `archlinux` is amd64-only, so a Mac builds under Rosetta. | Proven for the demo. A proof build of the Companion ISO is still to be made; release builds belong on x86-64. |
| Launcher | Upstream's `calamares-online.sh` re-installs the installer package every time and overwrites `/etc/calamares`. | Addressed: our launcher downloads the candidate package, checks it against `installer/guards.list`, installs it only if it passes (otherwise it keeps the ISO's installer) and then applies the overlay; `verify-iso.sh` checks the order (heuristic). |
| Identity | `cachyos-hooks` rewrites `os-release` on every `filesystem` transaction. | Addressed: `zz-ci-os-os-release.hook`; verified on fixtures only. |
| Arch stager | `backends/arch/headless-setup/install.sh` is not chroot-safe. | Addressed by `provision/stage-headless.sh`; `backends/arch/**` untouched. |
| User detection | `detect_user()` falls back to `root` under a systemd unit. | Addressed by the wrapper's account scan. |
| Config leaks | CachyOS identity leaks in Calamares module configs (bootloader id, GRUB theme, Plymouth, hostname, internet check, upload). | Addressed in `installer/modules`; checked statically by `verify-iso.sh` section 5. |
| Carry-over paths | Carry-over writes files such as `/etc/xdg/kcm-about-distrorc` and `/usr/share/color-schemes/CI-OS-Dark.colors` into the installed system after its packages. `overlay/package-owned-ok.txt` records that nothing in core, extra or the CachyOS packages the live image installs ships them (`pacman -F`, 2026-10-15); the installed system's package set (the netinstall groups, KDE, later versions) was not checked. A package that starts shipping one of them makes `pacman -Syu` abort with "exists in filesystem" until the copy is removed by hand. | Open; the ownership check should also run against the netinstall closure. |
| Identity rewrite | `zz-ci-os-os-release` rewrites `/etc/os-release` and `/etc/lsb-release` whole on every trigger: a key added by an administrator or another tool is lost at the next `filesystem` update, and the ordering against CachyOS's hooks rests on file-name sort order and one build-time check. | Open; by design for now (decision D4 describes the files as ours). |

## What is not done

* A Companion OS ISO has been built from this overlay and inspected statically (see [Test status](#test-status)); it has not been
  booted or installed. The installed path (Calamares, payload staging, first boot, the identity after an update) has never run.
* No boot of a Companion OS ISO. Under QEMU/TCG the research demo reached its desktop in direct-kernel mode with the VM relief,
  and BIOS and UEFI reached a login prompt only (see [Booting under QEMU](#booting-under-qemu)). Calamares, the installed path and
  any claim about real hardware need a KVM host or real hardware.
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
  does not use it (the skel hook writes the files), and Bazzite's stale comment about it is not updated.
* The package set is not reproducible (no Arch Linux Archive snapshot) and there is no scheduled canary rebuild.
* A source offer for the GPL content of the ISO, the licence of the repository as a whole, the header of `show.qml` against
  upstream's licence, and a written answer from CachyOS about the use of their name (`NOTICE` sections 2 and 6).
* This edition touches files outside `backends/cachyos/`: `docs/architecture/multi-distro-design.md`, `companion-stick.md`,
  `core/README.md`, `core/lib/check-repo.sh`, the root `README.md` and `CLAUDE.md`, and the steward skill's payload-dependency list.
