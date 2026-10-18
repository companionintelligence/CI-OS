# Companion OS, CachyOS edition (`backends/cachyos/`)

> Status (2026-10-18): the build system, the brand and identity overlay, the installer overlay, the first-boot provisioning and the ISO
> verifier are written and unit-tested on fixtures. **Five Companion OS ISOs have been built from this overlay.** ISO #2
> (`companion-os-plasma-2026.10.16-x86_64.iso`, built from the clean commit `16271e6`) passed all 187 checks of `verify-iso.sh` and booted
> to the Plasma desktop in direct-kernel mode. **ISO #4 and ISO #5 were each run end to end under QEMU/OVMF software emulation (TCG, no KVM):** real UEFI
> GRUB boot to a drawn desktop (first graphical frame about 4 minutes after Enter in GRUB on a lightly loaded host), the Calamares online install (47 jobs, 22 min 9 s on ISO #4,
> 23 min 20 s on ISO #5), the installed boot, and first-boot provisioning with three Ollama models pulled. The ISO #4 run found defects (first boot ended
> "degraded" with all models present, a oneshot that held the boot targets for 16 minutes, a log flood, a visible Cachy-Update, an unreadable
> installer look), fixed in commit `552063f` and built as ISO #5. **ISO #5 shows those fixes working on an installed system:** `graphical.target` after 37.8 s,
> first boot 21 min 49 s with status 0/SUCCESS and no "degraded", a 367-line log, no Cachy-Update. Still open on that record: the Calamares keyring step's 30 second limit
> (two of three ISO #5 install attempts failed at 2 percent; a fix is in the working tree, not yet run on a built ISO; KI-20), two highlight gaps in the installer look (KI-09), and the
> missing `verify-iso.sh` log for ISO #4 and ISO #5. Nothing has run on KVM, in BIOS mode, under Secure Boot or on real
> hardware. Run names, timings and the status table are in
> [`docs/architecture/cachyos-backend.md`](../../docs/architecture/cachyos-backend.md#test-status); the evidence rows are in
> [`docs/architecture/test-evidence.md`](../../docs/architecture/test-evidence.md). Private & Confidential,
> Lifescope Inc.

A live and installer ISO of Companion OS, based on CachyOS. It is the pinned upstream profile
[CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO) (archiso, KDE Plasma, `plasma-login-manager`, the online
Calamares installer) plus an overlay: product name and identity, boot menus, wallpaper and colours, a Companion installer
entry point, and the packages and first-boot steps of the appliance. The upstream profile is never edited; a build copies it,
applies the overlay to the copy and runs the stock `mkarchiso`.

The CachyOS installer is **online**: the installed system is built from the CachyOS and Arch repositories at install time,
not copied from the live image. Anything baked into the live image therefore does not reach the installed machine; see the
three layers in the architecture document.

## Build

```bash
backends/cachyos/iso/scripts/build-iso.sh --version 1.0
```

| | |
|---|---|
| Prerequisites | Docker (Docker Desktop on macOS or Windows, the engine on Linux), bash 3.2 or newer, network. Nothing else on the host: the build runs in a throw-away privileged `linux/amd64` container. On Apple silicon the amd64 container runs under Rosetta. |
| Disk | About 25 GiB free in the Docker VM, plus about 3 GB for the output. |
| Memory and CPU | The container defaults to 8 CPUs and 16 GB (`--cpus`, `--memory`); `mksquashfs` peaks near 8 GiB. |
| Time | 25 to 26 minutes on a lightly loaded Apple-silicon host (ISO #4 26 minutes, ISO #5 25 minutes: packages about 12, `mksquashfs` about 11); 31 to 37 minutes on a loaded one (ISO #1 about 37 minutes from the start of `build-iso.sh`, ISO #2 about 31). The research demo (same upstream, trivial overlay) took 33 min 14 s under Rosetta at a host load average of 28 to 143 on 12 cores; upstream's own CI needs about 18 minutes on a native runner. `mksquashfs` writes nothing visible for about 10 minutes: that is not a hang. |
| Output | `output/` (override with `--out`; an unwritable directory is refused before the build starts): `companion-os-plasma-<YYYY.MM.DD>-x86_64.iso`, `.iso.sha256`, `.pkgs.txt` (the package list), `.build-info` (pins, hashes, tool versions, the repository commit and whether the tree was clean), `.build.log`. If the build finishes but the copy out fails, the container and its volume are kept with the ISO inside and the recovery `docker cp` command is printed. |
| Dry run | `--dry-run` prints every input and every `docker` command and runs nothing. |

Every environment variable of the build, the verifier, the installer launcher, first boot and the tests is in the
[environment reference](../../docs/guides/environment-reference.md) (`CI_OS_PIN`, `CI_OS_JOBS`, `CI_OS_UPSTREAM_REUSE`, `CI_OS_COMPAT_*`,
`VERIFY_*`, `SKIP_CACHYOS_TESTS`, ...).

The date in the file name is the date of `SOURCE_DATE_EPOCH`. By default that is the UTC build day (`--source-date-epoch now`).
`--source-date-epoch pin` uses the pinned upstream commit's date (2026.10.03), so a rebuild keeps its name and two builds can be
compared by name; an explicit number of seconds also works. `--help` lists every option (`--fallback-pin`, `--cpus`, `--jobs`,
`--memory`, `--unprivileged`, `--cache-volume`, `--keep-container`, `--force`, `--require-clean`, `--allow-dirty`).

The ISO is built from the **working tree**, not from a commit: the container has no `.git`, and the copy takes every file under
the subset in `iso/scripts/repo-subset.txt` as it is on disk. Before it starts, `build-iso.sh` lists what in that subset is not
exactly what HEAD has (edited, untracked, or ignored such as a stray `.env`) and builds anyway; `--require-clean` makes that an
error (use it for a release), `--allow-dirty` says it is intended and stays quiet. `.build-info` records the commit, whether the
tree was clean, and a digest of what was copied; `verify-iso.sh` reports it, and `VERIFY_REQUIRE_CLEAN=1` turns a dirty tree into a
failure.

What is pinned and what is not is in `upstream.lock`. The package set is **not** pinned: the live profile installs from the rolling
`[cachyos]`, `core`, `extra` and `multilib` repositories on the day of the build, and the installer does it again on the day of
the install. `.pkgs.txt` and `.build-info` record what a build got.

## Verify

`iso/scripts/verify-iso.sh` inspects a finished ISO without root and without booting it: the medium and its boot records, the
boot menus, the identity and branding inside `airootfs.sfs`, the installer entry point, the package list, the Calamares overlay,
file modes, the build record, the compatibility libraries of `compat-libs.lock` (in the image byte for byte, and the `COMPAT_*` keys of
the build record that says the step ran) and the checksums. It prints `PASS` / `FAIL` / `info`, lists skipped groups at the end, and exits
non-zero if anything failed. It needs `xorriso`, `unsquashfs` and, for the Calamares YAML checks, `python3` with PyYAML.

On a Mac, run it in the builder image; the ISO is bind-mounted read-only, the work directory stays in the container:

```bash
IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' ci-os-cachyos-builder | head -n 1)"
docker run --rm --platform linux/amd64 --cpus 4 --memory 8g \
  -v "$PWD:/repo:ro" -v "$PWD/output:/iso:ro" "$IMAGE" bash -c '
    VERIFY_FETCH_UPSTREAM=1 /repo/backends/cachyos/iso/scripts/verify-iso.sh "$(ls /iso/companion-os-plasma-*-x86_64.iso | head -n 1)"'
```

The builder image carries Python and PyYAML (`Dockerfile.builder`); an image built before that needs
`pacman -Sy --noconfirm python python-yaml` first. The verifier uses only what that image has: no `diffutils` (it compares by
hash, not with `cmp` or `diff`). `VERIFY_FETCH_UPSTREAM=1` fetches the pinned upstream commit for the kernel-line parity
checks, or mount a checkout and set `VERIFY_UPSTREAM_DIR=/upstream`. A run takes on the order of a minute (not timed precisely
on the full ISO). Useful switches (all in the script header): `VERIFY_KEEP=1`, `VERIFY_WORK=DIR`,
`VERIFY_GRUB_EXTRA_PARAMS="a=b"` (kernel parameters the overlay may add), `VERIFY_SKIP_SFS_HASH=1`, `VERIFY_REQUIRE_ALL=1` (a
skipped group fails the run), `VERIFY_REQUIRE_CLEAN=1` (the build record must say the ISO was built from a clean checkout).

The checks are tested against a bug each: `iso/tests/verify-selftest.sh` drives every check function on small synthetic inputs, a
good one that must pass and a broken one that must fail (see [Tests](#tests)).

Section 5 also reads the installer's own files out of the image (`/etc/calamares/{modules,scripts}`, `/usr/lib/calamares/modules`, `/etc/grub.d`) and judges the
**effective** result, the overlay laid over them the way `calamares-online.sh` does: the time limit of every `shellprocess` command of the install sequence (Calamares kills a command
after 30 s unless it has a `timeout`; ISO #5 died at 2 percent on the keyring step), the install page's job labels with the overlay's `patches.list` applied (no CachyOS), and the
`GRUB_DISABLE_BOOTNEXT` switch against the `31_efi_bootnext` of the image's grub. Details: `installer/README.md`, "What the ISO #5 install run changed".

## Boot test

`iso/tests/qemu-boot.sh ISO` boots the ISO in QEMU and waits for an expected state (a login prompt on the serial console, or the
Plasma session). Modes: `direct` (default; kernel and initramfs are taken from the ISO and started with the ISO's own kernel
command line), `bios` and `uefi` (through the real boot menus). Without KVM (Apple silicon, any host without `/dev/kvm`) QEMU
emulates the CPU in software, and the stock upstream image does not finish booting there: systemd gives up on services that
only need more time. The overlay ships a generator, `companion-vm-timeouts`, that gives any virtual machine that time, so an ISO
built from the overlay needs no flag; `--vm-fixes` injects the same generator into an ISO that lacks it (the research demo).
With it the research demo reached the Plasma desktop under QEMU/TCG in direct-kernel mode; the BIOS and UEFI modes reached a
login prompt on the serial console only. The evidence (run names, timings, screenshots) is in the header of the script and in
[Booting under QEMU](../../docs/architecture/cachyos-backend.md#booting-under-qemu); the logs and screenshots themselves are
not in the repository. The Companion OS ISOs #4 and #5 were booted through real UEFI (OVMF, GRUB) rather than the direct-kernel mode, and both were
installed and booted; BIOS (syslinux) mode, KVM and real hardware have not been exercised.

## Tests

Without Docker, root or network (bash 3.2 and standard tools; `python3` with PyYAML importable by the `python3` on your PATH, check
with `python3 -c 'import yaml'`: yamllint's own copy does not count, and Homebrew's Python has none). On bash 3.2 the evaluation of
`profiledef.append.sh` is skipped (it needs bash 4):

```bash
backends/cachyos/iso/tests/overlay-engine.sh      # upstream.lock, the overlay merge engine and its guards, the host entry point (fake docker)
backends/cachyos/iso/tests/overlay-brand.sh       # identity writer, pacman hooks, menus, profile permissions, the renderer, NOTICE and the documents against the tree
backends/cachyos/iso/tests/installer-config.sh    # installer overlay, launcher and guards, staging, first-boot provisioning
backends/cachyos/iso/tests/verify-selftest.sh     # every check of verify-iso.sh, on fixtures (a good one and a broken one each)
```

`installer-config.sh` also runs `progress-filter.sh` (the filter that keeps `ollama pull`'s redraws and colour codes out of the first-boot log and the journal, and the driver's hand-over of that output: the real recorded stream, floods, a layer that goes up and down, linear time on escape-heavy input, the tail of the output when the main process exits, streaming), `compat-libs.sh` (the compatibility-library lock, its stager and the `mksquashfs` shim, with the
network and the keyring stubbed) and `gate-calamares.sh` (the build-time installer gate, on a fake image with recorded `ldd` and
start output), and `installer-launcher.sh` holds the keyring cases of the launcher (see [Rolling-release drift](#rolling-release-drift-the-compat-lock-and-the-installer-gate)) and the cases of the `shell-timeouts` guard, which fails when a `shellprocess` command of the install sequence would run on Calamares' silent 30 second default.

`overlay-brand.sh` checks the patches against the pinned upstream only when it can see a checkout: set
`CACHYOS_UPSTREAM_ARCHISO=<CachyOS-Live-ISO checkout>/archiso` (or `CACHYOS_TEST_FETCH=1`, which fetches the pin); otherwise
that part prints `SKIP`.

Manual, with Docker and network:

```bash
backends/cachyos/iso/tests/verify-mini-iso.sh        # about 2 minutes: a 15 MB ISO from the REAL overlay and renderer, then verify-iso.sh on it
backends/cachyos/iso/tests/overlay-engine-container.sh   # the pipeline up to mkarchiso, against the real pinned upstream
backends/cachyos/iso/tests/overlay-pacstrap.sh       # does the identity survive the CachyOS hooks in a real pacstrap
backends/cachyos/iso/tests/overlay-hook-pacman.sh    # a real pacman runs the hook that hides CachyOS Hello (no network)
backends/cachyos/iso/tests/overlay-menu-shot.sh      # screenshots of the two boot menus in QEMU
backends/cachyos/iso/tests/compat-gate-container.sh  # the installer gate on the REAL packages: F2 reproduced, three mutations, the stock mkarchiso (about 10 minutes)
backends/cachyos/iso/tests/first-boot-units-container.sh  # systemd-analyze verify on the first-boot service and timer (Docker, no network; systemd is never PID 1)
backends/cachyos/iso/tests/first-boot-drain-container.sh  # the tail of the first-boot output survives the exit of the unit's main process, under a real systemd USER manager (Docker, no network; never PID 1)
```

`verify-mini-iso.sh` stops short of what takes the time (packages, `mkarchiso`): it fetches the pinned upstream, renders the assets,
merges the overlay with the build's own engine, runs the pacman hooks' scripts on the merged root, writes a hybrid BIOS + UEFI ISO
with `mkarchiso`'s options and runs `verify-iso.sh` on it. It shows that the verifier and the overlay agree on every file the
overlay and the renderer produce; it can not show that the packages, the kernels or a boot are right.

`core/lib/check-repo.sh` is the fast check before a push, as for every backend.

## Layout

```
backends/cachyos/
  README.md  NOTICE                      this file; provenance and what is not shipped
  upstream.lock                          every pin (upstream commit, builder image, key, mirrorlist) and the edition identity
  compat-libs.lock                       the older-generation libraries the installer still needs (Archive, sha256), with a review date
  iso/
    scripts/build-iso.sh                 host entry point: one container, copy in, build, copy out, hash check
    scripts/in-container/                10-bootstrap.sh (repo + key), 20-build.sh (fetch pin, render, overlay, mkarchiso),
                                         apply-overlay.sh (patches, files, packages, profiledef, guards),
                                         stage-compat-libs.sh (fetch, verify, stage the compat libraries), gate-calamares.sh and
                                         mksquashfs-gate.sh (the installer gate, run by mkarchiso just before it squashes the image)
    scripts/render-assets.sh             renders the brand assets from vendor/brand + core/render at build time
    scripts/verify-iso.sh                this README, "Verify"
    docker/                              builder image: pinned Arch base, archiso, the CachyOS key (fingerprint checked)
    overlay/                             files/ patches/ packages.add packages.remove profiledef.append.sh (decision D5)
    render-deps.txt                      packages the renderer needs in the build container
    tests/                               overlay-*.sh installer-*.sh verify-selftest.sh verify-mini-iso.sh qemu-boot.sh (see Tests)
  installer/                             Calamares overlay: settings, module configs, branding, guards, scripts; staged to
                                         /usr/share/ci-os/calamares in the live image by stage-installer.sh
  provision/                             first-boot wrapper around backends/arch/provision/provision.sh, systemd units, stagers
```

Nothing generated is committed: the rendered brand assets, the staged installer overlay and the ISO are produced by a build.

## Rolling-release drift: the compat lock and the installer gate

The package set is rolling, so the live image can contain a package of `[cachyos]` that was built against an older library than the
one `[extra]` has by now. On 2026-10-18 that was the installer itself: `cachyos-calamares-next` 3.4.2-13 needs
`libboost_python314.so.1.91.0`, the image had boost 1.92, and Calamares did not start (risk R1, the incident is written up in
[the architecture document](../../docs/architecture/cachyos-backend.md#rolling-release-drift-incident-2026-10-18-f1-f2)). Two mechanisms
keep that from reaching a person:

* **[`compat-libs.lock`](compat-libs.lock)** pins the old libraries (three `libboost_*.so.1.91.0` files from the Arch Linux Archive, by
  sha256 of the package and of each file, with a review date). `in-container/stage-compat-libs.sh` fetches the package, checks the
  hash and the package signature, and puts exactly those files into the staging layer, next to boost 1.92 and under other file names,
  so nothing is downgraded. `overlay/package-owned-ok.txt` lists them for guard (b). `stage-compat-libs.sh propose PKG VERSION SONAME`
  prints the records for a refresh; the header of the lock says how.
* **The gate**: `20-build.sh` runs `mkarchiso` with a `mksquashfs` in front of the real one on its PATH. When `mkarchiso` is about to
  squash the finished airootfs, `in-container/gate-calamares.sh` runs `ldd -r` on every ELF file of `cachyos-calamares-next` and starts
  Calamares offscreen for a few seconds, in a read-only view of the image. Any missing library, undefined symbol, two versions of one
  library in one process, or a start that does not stay up stops the build before the image is written, with a message that names the
  library or symbol and points at the lock. `20-build.sh` also fails if the gate never ran.

`CI_OS_COMPAT_LIBS=off` (environment of `20-build.sh`) stages nothing: it is how the gate was proven to fail. `CI_OS_COMPAT_REVIEW=error`
turns a passed review date into a failure; use it for a release. When `[cachyos]` has rebuilt the installer and the libraries are not
needed any more, replace the lock's records by one line, `retired YYYY-MM-DD` (a lock with no records at all is refused: that is what a
truncated file looks like); the stager, the gate and `verify-iso.sh` then accept an image without the libraries and a build record
that says `COMPAT_LIBS=0`.

## Pins and how to bump them

All pins are in [`upstream.lock`](upstream.lock) (plain `KEY=value`, read, never executed); its header has the bump procedure.
In short:

* **Upstream profile**: `UPSTREAM_SHA` (currently `3215497d2e8c5fea90e185affcf973dfa2cf790b`, 2026-10-03). The fallback pin
  `UPSTREAM_FALLBACK_SHA` (`4937780`, 2026-08-11) is an older commit that still has `nvidia-module-loader` (the pin replaced it by
  `cachyos-drm-awaiter`; commits in between were not enumerated); build it with `--fallback-pin`. The overlay patches are written against the primary pin, so on the fallback expect
  `apply-overlay.sh` to stop on a patch that no longer applies: that stop is intended. Port the patch, do not loosen the check.
* After a bump: re-read the diff of upstream's `archiso/` (menus, `packages_desktop.x86_64`, `airootfs/etc/pacman.d/hooks`,
  `airootfs/usr/local/bin/calamares-online.sh`), run `iso/tests/overlay-engine.sh`, build, run `verify-iso.sh`, boot.
* **Builder image**: `BASE_IMAGE` is the manifest-list digest of the official `archlinux` image (amd64 only).
* **Mirrorlist**: `MIRRORLIST_REF` and `MIRRORLIST_SHA256` (the file upstream fetches from `raw/master`, fetched at a fixed commit).
* **Compatibility libraries**: [`compat-libs.lock`](compat-libs.lock), its own file and format (see above). Not part of `upstream.lock`:
  it is about the package set, which `upstream.lock` says it cannot pin.
* **Installer**: the Calamares overlay is written against `cachyos-calamares-next 3.4.2-13` (branch `cachyos-dev` @ `199d715`).
  The launcher re-checks the package on install day (`installer/guards.list`) and keeps the ISO's own version if the new one no
  longer fits.

## Decisions

| | Decision | Where it shows |
|---|---|---|
| D1 | Product name "Companion OS"; "based on CachyOS" only as a fact in docs, `NOTICE` and the `VARIANT` field. The CachyOS mark stays out of the artifact: `iso_name=companion-os-plasma`, file `companion-os-plasma-<YYYY.MM.DD>-x86_64.iso`, label `COMPANION_<YYYYMM>` (the medium is found by `archisosearchuuid`, not by the label), publisher `Companion Intelligence <https://ci.computer>`, application `Companion OS Live/Installer`. | `upstream.lock` (EDITION_*), `overlay/profiledef.append.sh`, `verify-iso.sh` section 1 |
| D2 | KDE Plasma first, with `plasma-login-manager`. GNOME is a documented follow-up. | the live package list is upstream's plus `kdialog` (installer failure dialogs): `overlay/packages.add` |
| D3 | Pinned upstream commit `3215497` with `4937780` as the documented fallback. The builder image is pinned by digest. The live profile stays baseline x86-64 (generic `[cachyos]` repo only); the `cachyos-v3` repositories are never used in the build because they break under Rosetta. | `upstream.lock` |
| D4 | `/etc/os-release`: `NAME="Companion OS"`, `PRETTY_NAME="Companion OS <ver>"`, `LOGO=ci-os-logo`, `VARIANT="Plasma (based on CachyOS)"`, the `CI_OS_*` keys of the Ubuntu edition, URLs on `ci.computer`. **`ID=cachyos` and `ID_LIKE=arch` stay**: CI-Hub's installers string-match `ID_LIKE=arch`. A later-sorting pacman hook (`zz-ci-os-os-release.hook`) rewrites the whole file after `cachyos-hooks`' own hook does. | `overlay/files/.../zz-ci-os-os-release.*`, `verify-iso.sh` section 3 |
| D5 | Overlay format: `files/` merged onto a throw-away copy of upstream's `archiso/`, `patches/*.patch` (`git apply -p1`, exact context), `packages.add` / `packages.remove`, `profiledef.append.sh` (a `file_permissions` entry for every executable: mkarchiso drops modes). Files at paths a package owns need a PostTransaction hook or the package's `backup=`. | `iso/overlay/`, `in-container/apply-overlay.sh` |
| D6 | Installer: our own `/usr/local/bin/calamares-online.sh` (makes sure the pacman keyring exists, works and is populated before the first sync: a working one is kept, a broken one is repaired in place and, as a last resort, emptied in place (its contents; the directory itself is never removed or renamed, it can be a mount point); a sync that fails on a key repairs the keyring and is tried once more; a failure is told apart as keys, mirror or connection, or other; downloads the current `cachyos-calamares-next` and checks it against `installer/guards.list`, installs it only if it passes and links on this system (`ldd -r`) and otherwise keeps the installer on the ISO, then lays the Companion overlay from `/usr/share/ci-os/calamares` over it, guarded: fail closed for the package list and payload staging, fail open with a loud log for cosmetic strings), our own launcher entry (an Applications-menu entry "Install Companion OS": no autostart, no desktop shortcut), `cachyos-hello` hidden. GRUB forced, `efiBootloaderId=companion-os`, hostname `companion-os`, no `wiki.cachyos.org`, no upload to `paste.cachyos.org`, no GitHub-raw netinstall. | `installer/`, `verify-iso.sh` sections 3b and 5 |
| D7 | Live hardening, such as it is: `sshd.service` and `sshd.socket` masked and the `sshd_config.d` drop-in forbids root and password logins. The live session otherwise keeps upstream's posture: empty passwords for `root` and `liveuser`, passwordless sudo for `wheel` (the launcher uses it), a polkit rule that allows every action for `wheel`, user name `liveuser`. That is fine for a live medium and nothing here carries it to the installed system. The two masks do not cover the sockets that `systemd-ssh-generator` can create for sshd (a unix socket and, in a VM, AF_VSOCK); whether it creates them in this image was not checked, so the drop-in is the barrier. | `verify-iso.sh` section 3 |
| D8 | Installed system: Calamares installs `docker`, `docker-compose`, `docker-buildx`, `jq`, `curl`, `openssl`, `tailscale`, `cloudflared`, `github-cli`, `ollama` and `ollama-vulkan` and the wireless-setup stack (`hostapd`, `dnsmasq`, `nginx`, `python-flask`, `gunicorn`, `iw`; see `installer/modules/packages_online.conf`), adds the `docker` group, stages the setup-portal payload and enables `docker`, `setup-backend` and `setup-network-monitor` (`nginx`, `hostapd-setup` and `dnsmasq-setup` stay disabled: the watcher starts them when the machine has no network); first boot runs `backends/arch/provision/provision.sh` through a thin wrapper that supplies `SUDO_USER`. `backends/arch/**` is not edited. | `installer/`, `provision/` |
| D9 | Licensing: upstream scripts and profile are GPL-3.0. No CachyOS artwork, wallpaper, logo, GRUB theme or Plymouth animation enters this tree. Brand assets come from `vendor/brand` and `CI-Common` and are rendered at build time. | `NOTICE`, `verify-iso.sh` (artwork hashes) |

## Known limits

* **Proven twice, under emulation only**: ISO #4 and ISO #5 were installed and booted under QEMU/OVMF software emulation on an Apple-silicon host (the installs took
  22 min 9 s and 23 min 20 s with fast mirrors, not the hours that had been feared; ISO #5 needed three attempts, see the keyring-step point below). The fixes of ISO #4's
  defects are seen working on ISO #5's installed system. Nothing has run on KVM or real hardware.
* **Online only.** No install without a working internet connection; the live session also contacts the CachyOS and Arch
  mirrors. The architecture document lists the known external endpoints (not exhaustive: it says what was read and what was not).
* **First boot can end "degraded".** If a required Ollama model did not arrive (a failed pull, or a link too slow for the largest,
  17.8 GB), setup is not marked done: `/var/lib/ci-os/first-boot-setup-status` says `degraded`, and it retries on the next boot
  or timer tick, three automatic attempts in all, then `sudo ci-os-setup`. On ISO #4 it ended degraded with every model present (a missing `$HOME`
  made `ollama list` panic; fixed in `552063f`; on ISO #5 it ended with status 0 and the marker written). **The three models take about 18.8 GB, and nothing checks free disk space
  first**: on a 30 GiB disk they left 3.7 GiB free (see the architecture document, finding 4).
* **The Calamares keyring step had a 30 second limit.** The installer's `shellprocess_initialize_pacman.conf` gives the command `create-pacman-keyring` no `timeout`, so Calamares applied its 30 second default; under QEMU/TCG the step takes about 28 seconds, and two of three ISO #5 install attempts died at 2 percent (known issue KI-20, `docs/architecture/known-issues-and-decisions.md`). **[I]** A fix is in the working tree: overlay copies of three stock `shellprocess` configs with explicit time limits and a `shell-timeouts` guard (`installer/lib/ci-shellprocess.py`, `installer/guards.list`); it is covered by `iso/tests/installer-launcher.sh` and has not been run on a built ISO.
* **Two services are open to the LAN without a credential, both from shared code this edition does not change.** While the setup
  portal's nginx runs (it is not enabled at boot; the network watcher starts it when the machine has no network), `POST /api/configure`
  of the root-run setup backend can delete saved NetworkManager profiles and re-point the Wi-Fi, and the shared Arch provisioner makes
  Ollama listen on `0.0.0.0:11434` without authentication. This edition installs no host firewall. Details and a suggested fix:
  `installer/README.md`, "Known issue in the shared setup payload".
* **Rolling.** The package set differs from build to build and again at install time. An ISO built weeks ago installs whatever the
  repositories hold on install day. A skew inside the live image itself (the 2026-10-18 case) is now caught by the installer gate and
  bridged by `compat-libs.lock`; the installed system is not covered by either, and the gate checks the installer only.
* **No Secure Boot.** The standalone GRUB and the CachyOS kernels are unsigned. Installed systems can use user keys (`sbctl`); that
  is not wired.
* **The Companion Stick cannot boot this ISO.** `ci-stick` writes the ISO's bytes fine, but its boot menu is built for casper and
  Canonical's signed chain. See the architecture document.
* **Rosetta limits.** The `cachyos-v3` repositories fail under Rosetta (CachyOS's glibc needs `faccessat2`) and x86-64-v4 is not
  offered, so the live profile is baseline only; v3 and v4 packages reach the installed system on the user's own hardware.
* **Kernel names stay.** `uname -r` says `-cachyos`, and package, repository and unit names with `cachyos` stay: they are
  identifiers, not branding.
* **No Companion Launcher, no Plymouth on the live medium, no one-click installer, no Docker in the live session**, and the
  GNOME edition does not exist. See "What is not done" in the architecture document.
* **Trademark and licence review is open.** See `NOTICE`.
