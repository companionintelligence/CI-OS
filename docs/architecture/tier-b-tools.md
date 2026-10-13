# Optional tools in the Companion OS ISO: tailscale, cloudflared, gh, Ollama, Companion Launcher

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

Review date 2026-10-13. Status: **implemented** in `backends/ubuntu/chroot/customize-chroot.sh` (Step 10e), `core/manifest/tier-b-pins.env`, `backends/ubuntu/chroot/payload/ci-os-ollama-models-env.sh` and `backends/ubuntu/iso/scripts/verify-iso.sh` (section 3c). The step was exercised in an amd64 Ubuntu 24.04 container (debootstrap chroot), **not yet in a full ISO build or a boot**. The vendor pins were re-checked independently on 2026-10-13 (Ollama tarball sha256 and size from the release's `sha256sum.txt`, the Launcher sha256 and size, and the GitHub CLI keyring fingerprints).

## 1. Summary

* All five tools can be baked with every key/hash pinned and checked before the chroot is touched. The step (Step 10e) was **run end to end** in an amd64 Ubuntu 24.04 container (debootstrap chroot, private `/run` tmpfs, `policy-rc.d`, real vendor repos): it installed all five, enabled only `tailscaled` and `ollama`, started nothing, left no `policy-rc.d`, no `/tmp` files and no apt lists, and the `verify-iso.sh` optional-tools section passed 48/48 checks against a squashfs/ISO made from that chroot.
* **Measured ISO impact (real `mksquashfs -comp xz -b 1M`, the flags in `build-iso.sh:364-365`): about +1.62 GB total.** Of that, Ollama's CUDA runtimes are 1.49 GB (92%). With `CI_OS_OLLAMA_CUDA=none` the total is about +0.13 GB. Table in section 6.
* Three findings change the existing repo, independent of Tier B:
 1. **The Launcher binary is `companion-hub`, not `ci-os-hub-desktop`.** Verified inside the real v0.3.5 `.deb` (`/usr/bin/companion-hub`). The pairing gate `pgrep -f ci-os-hub-desktop` (`setup_service.py:189`) and every autostart/dock reference never match. Also, the v0.1.4 `.deb` that `provision.sh:1357` falls back to ships `/usr/bin/ci-os-hub-desktop`, has no sha256 in its manifest, and its desktop file is `Companion Hub.desktop`, so `ci-os-hub-desktop.desktop` (`provision.sh:1481`) never existed in either version.
 2. **cloudflared's signing key was rolled on 2025-10-30**; Cloudflare's page calls the old key deprecated. `apt.yaml:49-50` and `provision.sh:1065-1071` still use the old file name `cloudflare-public-v2.gpg`. Today that URL serves the byte-identical new key (same sha256), so nothing is broken yet, but the file name is on a removal path.
 3. **GitHub CLI's keyring has two primary keys and the expired one comes first.** A naive "first `fpr:` line equals X" check (the pattern in `customize-chroot.sh`'s Docker block) would pin the dead key `2C61...` and fail on the live `7F38...`. Step 10e checks all primary keys and installs a keyring holding only the live one.
* Defaults: all three knobs ON as decided. Two further knobs I added: `CI_OS_OLLAMA_CUDA=all|none` (default `all`) and `CI_OS_LAUNCHER_AUTOSTART` (default **0**, see risk R3: the Launcher's own Hub stack publishes the same host port 5002 as `ci-hub.sh`).

## 2. Vendor evidence per tool

All "computed" fingerprints come from `gpg --show-keys --with-colons` in a throwaway `GNUPGHOME` under `keys/` (never the user's keyring). "Signed" = I verified the vendor's current `InRelease` with that key (`gpg --verify`, throwaway keyring).

| Tool | Repo / suite (noble) | Key URL | Declared fingerprint | Computed from downloaded key | Match | Other independent evidence |
|---|---|---|---|---|---|---|
| Tailscale | `deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main` (served by `https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list`) | `https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg` (binary, 2288 B) | **Not published.** The vendor's `install.sh` (lines 559-562) gives only the two URLs; the docs pages I fetched (`/kb/1187/install-ubuntu-2404`, `/docs/install/linux`) print no fingerprint. | `2596A99EAAB33821893C0A79458CA832957F5868` (RSA4096, created 2020-02-25, no expiry; sub `2F625B3A774B946822EDDBEEB1547A3DDAAF03C6`) | n/a | keyserver.ubuntu.com returns a key with the same fingerprint for `0x2596...5868`; `InRelease` (dated 2026-10-07) verifies "Good signature" with it. Trust root is therefore HTTPS to the vendor plus the keyserver, not a vendor-printed value. |
| cloudflared | `deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main` (page also lists `noble`; both suites verified) | `https://pkg.cloudflare.com/cloudflare-main.gpg` (binary, 2279 B, sha256 `1bd95f40...721d`) | **Not published.** `https://pkg.cloudflare.com/index.html` shows URLs and the 2025-10-30 rollover warning only; the developers.cloudflare.com downloads page links to it. | `CC94B39C77AE7342A68B89628A682D308D4E5E73` ("CloudFlare Software Packaging 2025", RSA4096, created 2025-10-23, no expiry; sub `06C89DB3B80A8F4349697C76029E1444B7D9F50F`) | n/a | keyserver.ubuntu.com and keys.openpgp.org both serve this fingerprint. `InRelease` for `noble` and `any` is dual-signed by `FBA8C0EE63617C5EED695C43254B391D8CACCBF8` (old, not in our keyring) and `CC94...` (Good). `cloudflare-public-v2.gpg` and `cloudflare-main.gpg` have the same sha256. |
| GitHub CLI | `deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main` (suite `stable`, not per codename) | `https://cli.github.com/packages/githubcli-archive-keyring.gpg` (4528 B) and `.asc` (6294 B) | **Published** in `cli/cli` `docs/install_linux.md` (trunk): `2C6106201985B60E6C7AC87323F3D4EA75716059` and `7F38BBB59D064DBCB3D84D725612B36462313325`; keyring sha256 `6084d5d7...811b` (.gpg) and `cec6e9ed...bbfd` (.asc) | primary 1 `2C61...6059`, created 2022-09-06, **expired 2026-09-05** (sub `5700BAB2...4157` also expired); primary 2 `7F38...3325`, created 2026-04-07, no expiry (sub `B84252FA...E579`). Both files hash to the published sha256. | **yes, both fingerprints and both file hashes** | `InRelease` (dated 2026-09-30) is signed by `7F38...`, Good. |

Pin decision: Tailscale `2596...5868`, cloudflared `CC94...5E73`, gh `7F38...3325` (the expired `2C61...` is tolerated in the download and dropped from the installed keyring). Only GitHub's pin has a vendor-published value; the other two rest on HTTPS to the vendor host, an independent keyserver and a verified signed `InRelease`. Treat a change in either as a reviewed event (pins live in one file, section 7).

### 2.1 Package facts (read from each repo's `Packages`, and from the real `.deb`s I downloaded and unpacked)

| Package | Version today | Arch | Download | Installed-Size | Depends | Recommends (skipped by `--no-install-recommends`) | Service / maintainer scripts |
|---|---|---|---|---|---|---|---|
| `tailscale` | 1.104.1 | amd64 (also arm64, armhf, i386, riscv64, mips*) | 40,512,672 B, sha256 `509753a4...700f` (matches the signed `Packages`) | 75,966 KB | `iptables` | `tailscale-archive-keyring (>= 1.35.181)`, `iproute2` | Ships `/usr/lib/systemd/system/tailscaled.service` (`Type=notify`, `WantedBy=multi-user.target`). postinst runs `deb-systemd-helper enable tailscaled.service` and, only `if [ -d /run/systemd/system ]`, `daemon-reload` and `deb-systemd-invoke restart`. prerm/postrm only touch the unit; purge deletes `/var/lib/tailscale`. |
| `cloudflared` | 2026.10.0 | amd64, 386, arm64, arm, armhf | 19,316,284 B, sha256 `9721287c...d548` | 39,189 KB | none | none | **No systemd unit.** postinst: `ln -sf /usr/bin/cloudflared /usr/local/bin/cloudflared`, `mkdir -p /usr/local/etc/cloudflared`, `touch .installedFromPackageManager`. Nothing to start. |
| `gh` | 2.102.0 | i386, amd64, armhf, arm64 | 15,392,446 B, sha256 `7e54a307...a5b0` (I re-downloaded the `.deb`; it matches) | 41,507 KB | `git` | none | None. (Ubuntu's own archive has an older `gh`; the vendor repo must win, enforced in the script with `apt-cache madison`.) |
| `companion-hub` | 0.3.5 | amd64 (arm64 also published) | 39,402,584 B, sha256 `f0403c6d...daa8` | 105,223 KB | `libayatana-appindicator3-1, libwebkit2gtk-4.1-0, libgtk-3-0` | n/a | No unit, no `/etc` files. postinst only symlinks `/usr/bin/cihub`. See 3.5 for postrm. |

In the stock 24.04.5.1 desktop manifest (`https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.manifest`, fetched) already present: `libwebkit2gtk-4.1-0`, `libjavascriptcoregtk-4.1-0`, `libayatana-appindicator3-1`, `libgtk-3-0t64` (Provides `libgtk-3-0`), `libsoup-3.0-0`, `iptables`, `iproute2`, `gnupg`, `zstd`, `bubblewrap`, `xdg-dbus-proxy`. Not present: `git`, `curl` (Step 10d installs them). So the only new files for tailscale/gh/Launcher are the packages themselves.

## 3. Per-tool findings

### 3.1 Tailscale
* Install with `--no-install-recommends`. `tailscale-archive-keyring` is then not installed; the baked key file sits at that package's own path, so installing the package later just overwrites it.
* The postinst **enables** `tailscaled` (symlink `/etc/systemd/system/multi-user.target.wants/tailscaled.service`, confirmed in the container run). In the chroot nothing is started because `/run/systemd/system` does not exist (`build-iso.sh` gives the chroot a private `/run` tmpfs) and `policy-rc.d` returns 101. Live-session guard: `tailscaled.service.d/10-not-live.conf` with `ConditionPathExists=!/cdrom/casper/vmlinuz` + `ConditionKernelCommandLine=!boot=casper` (the same pattern as the setup-stack units).
* CI-Hub can use the host client: `CI-Hub/docs/private-vpn.md:7` ("If the host already has Tailscale installed and the Hub can reach `tailscaled.sock`, CI-Hub can use the host client instead of the sidecar").

### 3.2 cloudflared
* Binary only, no unit. `ci-hub.sh` runs cloudflared as a container (`core/lib/ci-hub.sh:441-449`), so the host binary is for operators; nothing in CI-OS calls it.
* The script writes `/etc/apt/sources.list.d/cloudflared.list` with the **vendor's current key file name** `cloudflare-main.gpg`.

### 3.3 GitHub CLI
* See the two-key table. The script exports only `7F38...` (`gpg --export --export-options export-minimal`) into `/usr/share/keyrings/githubcli-archive-keyring.gpg` (same path `provision.sh:1037` and `apt.yaml:43` use) and fails if that file holds anything else.
* Negative tests (run2): pinning the expired key only, or not tolerating it in the download, both abort with `contains an unpinned key`.

### 3.4 Ollama (release `v0.40.3`, published 2026-10-11, `https://github.com/ollama/ollama/releases/tag/v0.40.3`)
* Linux asset names in this release: `ollama-linux-amd64.tar.zst` (**no `.tgz` any more**; the vendor's `install.sh` falls back to `.tgz` only for old versions), `ollama-linux-amd64-rocm.tar.zst` (1,052,180,143 B), `ollama-linux-amd64-mlx.tar.zst` (1,293,480,374 B), arm64 and jetpack variants. The vendor publishes **no signature**, only `sha256sum.txt` (itself unsigned).
* `ollama-linux-amd64.tar.zst`: 1,437,349,190 B, sha256 `ce6f8b671a699bf1ebafb28d60dbbabf4f37b30b499145fa308a8ba72de021d6`. Three sources agree: `sha256sum.txt` from the release, the GitHub API asset `digest`, and my own `shasum -a 256` of the 1.4 GB download. `ollama.com/install.sh` and the release's `install.sh` are byte-identical (sha256 `25f64b81...82c9`).
* Layout (full listing in `ollama/listing.txt`; 65 entries, no `./` prefix, no absolute names, no `..`, no absolute symlinks, only files/dirs/symlinks, all root:root): `bin/ollama` (29.8 MB Go ELF; NEEDED `libresolv libdl libpthread libstdc++ libc`, GLIBC <= 2.28), `lib/ollama/` with `libllama*.so`, `libggml*.so` (CPU variants `x64 sse42 sandybridge haswell skylakex icelake alderlake cascadelake cooperlake cannonlake sapphirerapids zen4 piledriver ivybridge`), `vulkan/libggml-vulkan.so` (41.9 MiB), `cuda_v12/` (1230.9 MiB) and `cuda_v13/` (814.8 MiB). Uncompressed total 2,252,680,202 B (2.10 GiB). The vendor's manual-install docs extract it with `tar x -C /usr` (`docs/linux.mdx`), which is what the script does.
* CUDA/ROCm sub-bundles: CUDA 12 and 13 runtimes are **inside** the main tarball (`cuda_v12`, `cuda_v13`). The ROCm bundle is a separate asset that `install.sh` adds only when an AMD GPU is detected; I did **not** download it (layout UNVERIFIED, expected `lib/ollama/rocm`). The tarball contains no NVIDIA *driver*; `install.sh` installs `cuda-drivers` from NVIDIA's repo when absent. Baking Ollama therefore removes that driver path and nothing replaces it (open question Q1).
* Without running `install.sh`: user/group/units are created exactly as `install.sh configure_systemd` does: `useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama`, add to `render` and `video` if those groups exist, unit `User=ollama Group=ollama ExecStart=/usr/bin/ollama serve Restart=always RestartSec=3`. (`install.sh` writes `WantedBy=default.target`; the docs say `multi-user.target`; I use the latter.) The Debian-style `render` group did not exist in my minbase chroot (only `video` was added); on the real desktop rootfs it does.
* Default bind is `127.0.0.1:11434` (`docs/faq.mdx:185`). Do **not** set `OLLAMA_HOST` in the image. Note `provision.sh:940-946` later writes `OLLAMA_HOST=0.0.0.0` in `override.conf` (risk R4).
* Boot policy: **enable at boot on the installed system, guard against live sessions.** Socket activation is not supported by Ollama; an idle daemon is cheap and models unload after idle, and `provision.sh:924-932` and `ci-os-post-validation.sh:80` already assume an enabled unit. The "on demand" part is handled by the models-dir selector below, not by a path unit.

### 3.5 Companion Launcher
* Source: `https://dl.ci.computer/latest.json` -> `{"version":"v0.3.5","date":"2026-10-13T15:30:59Z"}`; `https://dl.ci.computer/v0.3.5/manifest.json` has per-platform `url`, `size`, `sha256` (documented in `CI-Hub/docs/DESKTOP-AUTO-UPDATE.md:15-17`). **No credentials needed** (plain GET, HTTP 200). Old versions are retained (`v0.3.4`, `v0.3.3`, `v0.2.61`, `v0.1.4` manifests all return 200).
* Linux amd64: `https://dl.ci.computer/v0.3.5/linux/deb/x64/Companion%20Hub_0.3.5_amd64.deb`, 39,402,584 B, sha256 `f0403c6d5881a6b54be1d11b6b034b0adfaf31f328d35b8f57b7bcac500bdaa8`. I downloaded it and my `shasum -a 256` and byte count equal the manifest. The `.deb` has **no detached signature**; the manifest sha256 comes from the same origin, so the repo pin is the real control.
* `.deb` contents (`ar`/`zstd`/`tar`, in `launcher/x/`): `/usr/bin/companion-hub` (14.9 MB stripped PIE; NEEDED `libgtk-3 libwebkit2gtk-4.1 libsoup-3.0 libgdk_pixbuf libcairo libgio libglib libdbus-1 libjavascriptcoregtk-4.1 ...`), `/usr/lib/Companion Hub/resources/{cihub (92.5 MB), docker-compose.prod.yml, README.cihub.md, uninstall-cleanup.ps1}`, `/usr/share/applications/Companion Hub.desktop` (`Exec=companion-hub %u`, `MimeType=x-scheme-handler/cihub;x-scheme-handler/cihub-dev;`), icons, metainfo. Depends and scripts: table in 2.1.
* **Drift, fully characterised**
 * CI-Hub `packages/desktop/src-tauri/tauri.conf.json:4` and `tauri.linux.conf.json:4`: `"mainBinaryName": "companion-hub"`; added in CI-Hub commit `552f5eb5d` (2026-06-03). The Cargo crate is still named `ci-os-hub-desktop` (`Cargo.toml:2`); that is the only place the old name survives. (The sibling checkout `/Users/liam/devel/ci/CI-Hub` is at 0.2.61, behind the published 0.3.5; the conclusion is taken from the real 0.3.5 `.deb`, not from the stale tree.)
 * v0.1.4 `.deb` (downloaded, 7,723,220 B): `/usr/bin/ci-os-hub-desktop`, `Companion Hub.desktop`, manifest has no sha256 for it (`jq` yields empty).
 * CI-OS references to fix: `core/headless/payload/opt/setup-backend/setup_service.py:181,189`; `backends/ubuntu/provision/provision.sh:1352,1363,1437,1452,1481`; `backends/fedora/provision/provision.sh:1224,1237`; `backends/arch/provision/provision.sh:1139,1152`; prose in `core/manifest/ecosystem.yaml:105-113` and the generated `backends/nixos/manifest/ecosystem.generated.json:45`. Exact edits in section 8.
* Services: none shipped. Autostart (optional, default off): `/etc/xdg/autostart/companion-launcher.desktop` (same file name `provision.sh:1447` writes) whose `Exec` is a wrapper that exits 0 when `/cdrom/casper/vmlinuz` exists, so the Launcher never starts in a live session.
* **Removal is destructive.** The `.deb` `postrm` (control.tar, lines ~145-170) on `remove`/`purge` runs `cleanup_docker` (removes Hub containers, images, networks, volumes) and deletes per-user data dirs (`rm -rf "$xdg_data_home/$name"` ...). `upgrade`/`failed-upgrade` are skipped. Never put `companion-hub` in a package-removal list or `apt autoremove` path.

## 4. Service and live-session matrix (as built and tested)

| Unit | Enabled in image | Started by maintainer script in chroot | Live-session guard | How verified |
|---|---|---|---|---|
| `tailscaled.service` | yes (postinst symlink) | no (no `/run/systemd/system`, `policy-rc.d`=101) | `tailscaled.service.d/10-not-live.conf` | container run; `verify-iso.sh` section 3c |
| `ollama.service` | yes (`systemctl enable`, `SYSTEMD_OFFLINE=1`) | no | `ollama.service.d/10-not-live.conf` | same; `systemd-analyze verify` printed no diagnostics (Ubuntu 24.04 userland) |
| cloudflared | n/a, no unit | n/a | n/a | asserted: no `cloudflared*.service` anywhere |
| gh | n/a | n/a | n/a | n/a |
| Launcher | n/a, no unit | n/a | autostart wrapper (only if knob on) | verify section 3c |

Not tested: an actual boot of the image (live and installed). The guard is the same `ConditionPathExists=!/cdrom/casper/vmlinuz` pattern as the setup-stack units and is UNVERIFIED until a built ISO is booted live and the units are seen inactive.

## 5. Ollama models on the Stick's CI-CACHE exFAT volume

Design (files: section 7.3 and the unit inside Step 10e):
* `ollama.service` has `RuntimeDirectory=ollama`, `ExecStartPre=-+/usr/libexec/ci-os/ollama-models-env` (runs as root, failure ignored), `ExecStopPost=-+... release`, `EnvironmentFile=-/run/ollama/ci-models.env` (the leading `-` makes the file optional; systemd reads `EnvironmentFile=` right before each command is forked, so the file written by `ExecStartPre` is seen: `systemd.exec(5)`).
* The selector finds `blkid -L CI-CACHE`, requires `TYPE=exfat`, and mounts it itself on `/var/lib/ci-os/cache` with `uid=<ollama>,gid=<ollama>,umask=0077,nosuid,nodev,noexec`, then makes `models` (the stick bundle layout `models/blobs` + `models/manifests`) as the `ollama` user and writes `OLLAMA_MODELS=...` and `OLLAMA_NOPRUNE=1` (Ollama otherwise deletes unreferenced files under `blobs/` at start-up). exFAT has no permissions, so ownership has to come from mount options; a volume already mounted by udisks (owned by the desktop user) is used only if `ollama` can write to it, else the default `/usr/share/ollama/.ollama/models` is used. Absent volume, wrong filesystem, mount failure, opt-out file `/etc/ci-os/ollama-no-cache`: writes an **empty** env file, logs one line, exits 0, so the unit always starts. This matches the vendor requirement that "the `ollama` user needs read and write access to the specified directory" (`docs/faq.mdx:239-247`).
* `ExecStopPost ... release` unmounts only what the script itself mounted (stamp file), so a stick the desktop is using is left alone.
* **Tested on a real exFAT image** (128 MB loop device, `mkfs.exfat -L CI-CACHE`, Docker Desktop privileged amd64 container): absent -> empty env; present -> mounted with the options above, `ollama` can create/rename files, other users get `Permission denied`; second run while mounted reuses it; `release` unmounts; mounted elsewhere by root -> falls back; ext4 under the label -> falls back; opt-out file works. Correction found by the test: the exFAT driver has **no `quiet` option** (mount failed), and `chmod` on exFAT already returns success silently, so no option is needed.
* Not tested: real systemd running the unit, udisks interplay on a desktop, the Ubuntu 6.8 kernel (the test used Docker Desktop's kernel), Ollama itself writing blobs to exFAT. Hot-plug: the daemon picks the volume at (re)start only. If wanted, add a udev rule `ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="CI-CACHE", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ci-os-ollama-cache.service"` plus a oneshot that runs `systemctl try-restart ollama.service`; I did not build it (restarting a busy daemon and racing udisks' automount are open decisions).
* Models already pulled into the default directory become invisible while the stick is attached (by design; `OLLAMA_MODELS` is a single path).

## 6. ISO size impact (measured)

Method: unpack each download's data payload to a directory and run `mksquashfs DIR out.sq -comp xz -b 1M` (identical to `build-iso.sh:364-365`) in a native arm64 Ubuntu 24.04 container (`measure/m.log`). The real image compresses files in one tree, so expect small differences.

| Component | Download | Installed (du) | xz squashfs delta |
|---|---|---|---|
| tailscale 1.104.1 | 40.5 MB | 75 MiB | **35.5 MB** (35,536,896) |
| cloudflared 2026.10.0 | 19.3 MB | 39 MiB | **17.0 MB** (16,998,400) |
| gh 2.102.0 | 15.4 MB | 42 MiB | **11.8 MB** (11,771,904) |
| Companion Launcher 0.3.5 (deps already in stock ISO) | 39.4 MB | 103 MiB | **39.6 MB** (39,600,128) |
| Ollama 0.40.3, `CUDA=all` | 1.437 GB | 2,148 MiB (2.10 GiB) | **1,518 MB** (1,518,223,360) |
| Ollama 0.40.3, `CUDA=none` (CPU + Vulkan) | 1.437 GB (still downloaded) | 103 MiB | **24.1 MB** (24,076,288) |
| **Total, all on** | | about 2.4 GiB | **about +1.62 GB** |
| Total with `CUDA=none` | | about 0.4 GiB | **about +0.13 GB** |

Stock `ubuntu-24.04.5.1-desktop-amd64.iso` is 6,250,332,160 B (HTTP HEAD). Estimated Companion OS ISO with everything on: about 7.9 GB (before the Docker/wireless Step 10d additions, roughly 0.3 GB, which are unmeasured). That fits the planned 11 GiB `CI-BOOT-A`/`CI-BOOT-B` slots (about 7.4 GiB used). Build-host disk: the tarball cache (1.44 GB) and the extra 2.25 GB in the chroot are additional to what the workflow already needs; `build-companion-os-iso.yml:60-77` frees space first, but I did not measure the total (UNVERIFIED).

## 7. Where the code is

| What | File |
|---|---|
| Every pin (key fingerprints, Ollama and Launcher URL/sha256/size), one reviewed place | `core/manifest/tier-b-pins.env` |
| The build step: downloads and verifies everything on the build host first, then installs in the chroot | `backends/ubuntu/chroot/customize-chroot.sh`, Step 10e |
| Models-directory selector for the Stick's `CI-CACHE` volume | `backends/ubuntu/chroot/payload/ci-os-ollama-models-env.sh` (installed as `/usr/libexec/ci-os/ollama-models-env`) |
| Assertions on a built ISO | `backends/ubuntu/iso/scripts/verify-iso.sh`, section 3c (`VERIFY_TIERB=0` skips it) |
| Knobs | `CI_OS_BAKE_THIRD_PARTY`, `CI_OS_BAKE_OLLAMA`, `CI_OS_BAKE_LAUNCHER` (default 1), `CI_OS_OLLAMA_CUDA=all|none`, `CI_OS_LAUNCHER_AUTOSTART` (default 0), `CI_OS_CACHE_DIR`, `CI_OS_TIERB_PINS` |

To bump a pin: redo the check in section 2 (or 3.4 for Ollama, 3.5 for the Launcher), change the value in `tier-b-pins.env` in the same commit, run `verify-iso.sh` on a build.

## 8. First-boot and drift fixes (done)

### 8.1 What `provision.sh` already does with baked tools (no fight)
`install_tailscale` (`:252`), `install_github_cli` (`:1029`), `install_cloudflared` (`:1056`), `install_ollama` (`:783`) all start with `command_exists X` and return, so the baked copies are left alone. `configure_ollama` (`:908-957`) sees `ollama_systemd_unit_exists`, finds the unit already enabled, then writes `override.conf` and the GPU/context drop-ins **into the same `ollama.service.d/` directory** as our `10-not-live.conf` (different file names, so both apply) and restarts the service if active. `repo_configured` file names match ours (`github-cli.list`, `cloudflared.list`; tailscale writes `tailscale.list`), so no second source with another `Signed-By` appears. The one real fight is the Launcher (next).

### 8.2 Launcher binary-name drift (fixed)
`setup_service.py` now looks for `companion-hub` (and the legacy `ci-os-hub-desktop`) with `pgrep -x`; `provision.sh` (Ubuntu), the Fedora and Arch provisioners detect, launch and pin `companion-hub` (legacy name still accepted), keep a baked autostart entry that goes through the live-session wrapper, and verify the download's sha256 against the release manifest when it lists one. The pin dialog id is `Companion Hub.desktop`.

### 8.3 Manifests (done)
* `core/manifest/role-map/apt.yaml`: cloudflared `key_url`/`list` -> `cloudflare-main.gpg`; add `key_fingerprint` fields (tailscale `2596...`, cloudflared `CC94...`, gh `7F38...`); `ollama:` -> `install_method: release_tarball` with a pointer to `tier-b-pins.env` (the `curl_script` entry is what the first-boot path would use otherwise). `ecosystem.yaml:105-113` `companion_launcher.installer`: add `package: companion-hub`, `binary: companion-hub`, and fix the note ("`ci-os-hub-desktop` is the crate name"). `dev_tools` items allow extra keys, so `baked_in_iso: true` can be added for gh/cloudflared/tailscale (`llm` is `additionalProperties:false`, do not touch it). Regenerate `backends/nixos/manifest/ecosystem.generated.json`.

## 9. How this was tested (evidence)

| Run | What | Result |
|---|---|---|
| container run 1 | Full Step 10e in an amd64 Ubuntu 24.04 container: debootstrap minbase noble chroot, `/dev` bind, proc/sys, private `/run` tmpfs, real vendor repos, pinned artifacts from cache | rc=0; tailscale 1.104.1, cloudflared 2026.10.0, gh 2.102.0, companion-hub 0.3.5, ollama 0.40.3 installed; `tailscaled.service` and `ollama.service` enabled, no other new enables; no `policy-rc.d`, empty `/tmp`, empty apt lists; `ollama --version` ran in the chroot ("client version is 0.40.3") |
| container run 2 | Negative/knob tests with `CHROOT_PATH=/` | all-zero knobs no-op; bad knob/CUDA values, missing pins file, wrong Tailscale/Cloudflare/gh fingerprints, gh pinned to the expired key only, wrong launcher/Ollama sha256: each aborts with the intended message and rc=1. Hostile tarballs: absolute member, absolute and escaping symlinks, char device, `etc/cron.d/x`: refused. **A `lib/ollama/../../etc/evil` member was NOT refused** (my regex allowed `..` as a path component; GNU tar later errored but after extracting `bin/ollama`). Fixed with the `(^|/)\.{1,2}(/|$)` check in Step 10e and re-tested |
| container run 3 | Hostile `..` and `./` members after the fix; picker script on a real exFAT loop device | both refused, nothing extracted; picker scenarios in section 5. First picker run failed because of the invalid `quiet` option; fixed and re-run |
| container run 5 | Step 10e again (autostart on) -> `mksquashfs` -> ISO -> patched `verify-iso.sh` | section 3c: all 48 checks PASS (other sections fail by design: minimal rootfs, no branding) |
| `measure/m.log` | xz squashfs size per component | section 6 table |
| host | `bash -n`, `shellcheck -S warning` on step, picker and patched verify script | clean |

Test limits: emulated amd64 on an Apple-silicon Docker VM; minbase chroot, not the Ubuntu desktop rootfs; no systemd PID 1; no boot of the result.

## 10. Risks and caveats

* **R1 Ollama staleness.** The baked copy is pinned (0.40.3) and `install_ollama` skips when `ollama` exists, so nothing upgrades it. Ollama releases frequently and new models need new engines. Decide an update path (re-run the same verified-tarball logic from `provision.sh` when online, or rebuild monthly).
* **R2 Pin rotation.** GitHub's key already rotated once (expiry 2026-09-05); Cloudflare rolled in Oct 2025. A scheduled CI job that re-runs the key checks and fails when a vendor key changes would catch this before a release build does.
* **R3 Launcher autostart vs `ci-hub.sh`.** CI-Hub's bundled stack (`CI-Hub/docker-compose.prod.yml:139-140` `${API_PORT:-5002}:5002`; `:322-324` Traefik `80:80`/`443:443`) and CI-OS's `ci-hub.sh` (`core/lib/ci-hub.sh:397-398` `5002:3000`, Traefik on 18080/18443) both publish host port 5002, and the bundled stack's Traefik takes :80 that the setup portal's nginx also wants (the Traefik pause in `setup-device-hotspot-start.sh`). `companion-hub --detached` starts that stack (`CI-Hub/docs/CLI.md:33`). I did not run it, so the collision is inferred. Default autostart is therefore OFF.
* **R4 Ollama listening on all interfaces.** `provision.sh:940-946` writes `OLLAMA_HOST=0.0.0.0` and ufw is installed but disabled (there are no interface-scoped ufw rules for docker0 to port 11434). Baked Ollama itself binds 127.0.0.1.
* **R5 Launcher `postrm` deletes Hub containers/volumes/data on remove/purge** (see 3.5).
* **R6 NVIDIA/AMD GPU stacks.** CUDA user-space libs are in the tarball but not the NVIDIA kernel driver; the ROCm bundle (1.05 GB) is not baked. `provision.sh:841-857` sets `OLLAMA_VULKAN=1` only when `/dev/kfd` exists; the Vulkan backend is in the main tarball.
* **R7 Download integrity ceilings.** Ollama: pinned sha256 only (no vendor signature). Launcher `.deb`: pinned sha256 only (unsigned). Tailscale and Cloudflare fingerprints are not vendor-published.
* **R8 UNVERIFIED:** boot-time behaviour of every guard; real systemd handling of `ExecStartPre=-+`/`EnvironmentFile` ordering for `ollama.service`; the GNOME favourite-apps id `Companion Hub.desktop`; ROCm/MLX tarball layouts; total build-disk headroom on the hosted runner; that Ollama can write its blob files to exFAT (chmod is silently ignored per the test, hard links/symlinks are not used as far as I know).
