# Companion OS ISO build guide

Private & Confidential. Property of Lifescope Inc. Do not distribute.

How to build the two supported Companion OS ISOs, check them, and where the build fits into a release. For the Mac-specific recipe see [Building on a Mac](building-on-a-mac.md); for booting what you built see [Testing in QEMU](testing-in-qemu.md); before publishing anything read the [release checklist](release-checklist.md).

Supported targets: Companion OS on Ubuntu 26.04.1 LTS (resolute) and Companion OS on CachyOS (the "Plasma" edition). Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from the tag `pre-retire-multidistro-2026-10-17`). Numbers measured on the retired Ubuntu 24.04.5 base appear only where they explain a design decision and are labelled "retired baseline (24.04.5)".

Evidence tags: **[V]** verified in a run, **[I]** read from the code and not run, **[N]** not checked.

## Contents

1. [The two editions](#the-two-editions)
2. [Ubuntu edition](#ubuntu-edition)
3. [Plasma edition (CachyOS-based)](#plasma-edition-cachyos-based)
4. [CI workflows](#ci-workflows)
5. [Recording a build](#recording-a-build)

## The two editions

| | Ubuntu 26.04.1 edition | Plasma edition |
|---|---|---|
| What it is | The stock Ubuntu 26.04.1 Desktop ISO remastered: its layers are repacked, customized and re-signed into a hybrid ISO | The pinned CachyOS-Live-ISO archiso profile plus a Companion OS overlay, built with stock `mkarchiso` |
| Entry point | `backends/ubuntu/iso/scripts/build-iso.sh` | `backends/cachyos/iso/scripts/build-iso.sh` |
| Build host | Root on Ubuntu **26.04**, or a privileged `ubuntu:26.04` container; the script stops on any other host | Any host with Docker and bash 3.2+, as a normal user |
| Output | `output/companion-os-<version>-amd64.iso`, `SHA256SUMS`, `MD5SUMS` | `output/companion-os-plasma-<YYYY.MM.DD>-x86_64.iso`, `.sha256`, `.pkgs.txt`, `.build-info` |
| Measured build time | 12 min 52 s in an arm64 container on an Apple-silicon Mac [V]; retired baseline (24.04.5): about 27 min | 25 to 26 min on the same Mac [V]; 31 to 37 min on a loaded host |
| Measured size | 7,076,577,280 bytes with everything baked in [V] | 3,217,129,472 bytes [V] |
| Verifier | `backends/ubuntu/iso/scripts/verify-iso.sh` | `backends/cachyos/iso/scripts/verify-iso.sh` |
| Secure Boot | Canonical's signed chain is kept | Not supported |
| Installer | Canonical's `ubuntu-desktop-bootstrap` plus a one-click automatic path | Calamares (online) through a launcher |

## Ubuntu edition

### Prerequisites

- **Host:** Ubuntu 26.04 as root, or a privileged `ubuntu:26.04` container. `check_build_host` stops the build on anything else (`CI_OS_ALLOW_OTHER_BUILD_HOST=1` overrides it for a host you have verified yourself). The branded GNOME Shell theme is built from the host's Yaru, which has to be the GNOME Shell 50 one, and `unmkinitramfs` has to be initramfs-tools 0.151's (it unpacks the four-segment 26.04 initrd). On a Mac use the arm64 container recipe in [Building on a Mac](building-on-a-mac.md).
- **Disk:** at least 35 GB free for the work directory and the output, plus the 1.4 GB Ollama tarball cache in `~/.cache/ci-os` (`CI_OS_CACHE_DIR` overrides it).
- **Network:** the build runs apt inside the image (Ubuntu's archive and Docker's, Tailscale's, Cloudflare's and GitHub's apt repositories) and downloads the Ollama release tarball and the Companion Launcher `.deb`. Every key fingerprint and download hash is pinned in `core/manifest/tier-b-pins.env`; a mismatch fails the build.
- **Packages:**

```bash
sudo apt-get install -y \
  squashfs-tools xorriso libglib2.0-bin libglib2.0-dev-bin yaru-theme-gnome-shell \
  rsync gpg cpio zstd initramfs-tools-core imagemagick librsvg2-bin curl
```

  The stock desktop image has no image renderer, so the logo PNGs are rendered on the build host from the vendored SVG marks (`rsvg-convert`, ImageMagick). `build-iso.sh` stops at the start if either is missing. To verify a built ISO you only need `xorriso squashfs-tools zstd cpio python3`.

### Get and check the base ISO

The base is **Ubuntu 26.04.1** (`ubuntu-26.04.1-desktop-amd64.iso`, sha256 `601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f`). The 26.04 directory also lists the GA 26.04.0 image (`ubuntu-26.04-desktop-amd64.iso`); take the `.1` file.

```bash
wget https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso
wget https://releases.ubuntu.com/26.04/SHA256SUMS https://releases.ubuntu.com/26.04/SHA256SUMS.gpg

# The sums file must be signed by Ubuntu's CD image key (fingerprint pinned in the workflow).
export GNUPGHOME="$(mktemp -d)" && chmod 700 "$GNUPGHOME"      # a throwaway keyring
gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys 843938DF228D22F7B3742BC0D94AA3F0EFE21092
gpg --batch --verify SHA256SUMS.gpg SHA256SUMS                 # expect "Good signature from Ubuntu CD Image Automatic Signing Key (2012)"

# The line for exactly this ISO, then the bytes.
grep -F -- ' *ubuntu-26.04.1-desktop-amd64.iso' SHA256SUMS | sha256sum -c -      # shasum -a 256 -c - on macOS
```

The signature verification and the checksum line were run for this guide against the real 26.04 files [V].

### Build

```bash
sudo ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso ./ubuntu-26.04.1-desktop-amd64.iso \
  --output-dir ./output \
  --version 1.0
```

| Flag | Default | Meaning |
|---|---|---|
| `--base-iso PATH` | `./ubuntu-26.04.1-desktop-amd64.iso` | The Ubuntu 26.04.1 Desktop ISO |
| `--output-dir PATH` | `./output` | Where the ISO and checksums are written |
| `--work-dir PATH` | `./work` | Scratch space, about 25 GB |
| `--version VERSION` | `1.0` | Version string in the ISO file name and in `os-release` |
| `--clean` | off | Wipe the work directory first. Without it the previous chroot is reused and every step must be repeat-safe |
| `--skip-packages` | off | Skip `build-packages.sh` (iterative builds when packages and the gresource did not change) |
| `--sign` | off | Sign `SHA256SUMS` and `MD5SUMS` with your default GPG key |

Environment knobs (all default to baked in): `CI_OS_BAKE_THIRD_PARTY`, `CI_OS_BAKE_OLLAMA`, `CI_OS_BAKE_LAUNCHER`, `CI_OS_BAKE_CAPTURE` (0 or 1; Capture's release is private, so the build needs the `.deb` in `CI_OS_CACHE_DIR` or a signed-in `gh`: see [environment-reference.md](environment-reference.md)), `CI_OS_OLLAMA_CUDA=all|none` (`none` drops about 1.5 GB), `CI_OS_LAUNCHER_AUTOSTART`, `CI_OS_CACHE_DIR`, `CI_OS_TIERB_PINS`. See the header of `build-iso.sh` and [tier-b-tools.md](../architecture/tier-b-tools.md).

**Output** (default version): `output/companion-os-1.0-amd64.iso`, `SHA256SUMS`, `MD5SUMS`, and with `--sign` the two `.gpg` signatures. The build reads the finished image back against its own `md5sum.txt` before it reports success. These checksum the ISO file as a whole; the image also carries `/md5sum.txt`, which the live session's `casper-md5check.service` verifies file by file at every boot.

### What the build does

1. `build-packages.sh` builds `backends/ubuntu/packages/*` and the branded GNOME Shell gresource (see [GDM branding package](gdm-branding-package.md)).
2. The base ISO is mounted and extracted; the three stock casper layers (`minimal`, `minimal.standard`, `minimal.standard.live`) are merged into one root filesystem.
3. `backends/ubuntu/chroot/customize-chroot.sh` customizes it: OS identity, telemetry removal, GNOME theme, GRUB and Plymouth, the Companion branding, AMD helper scripts, the pre-installed wireless setup stack, Docker and CI-Hub tooling, the optional tools (tailscale, cloudflared, gh, Ollama, the Launcher), the one-click installer and the first-boot service. Step 1 refuses any base that is not 26.04 (resolute) before it touches anything.
4. The rootfs is split back into the layer the installer copies (`minimal.squashfs`) and the live-only layer (`minimal.standard.live.squashfs`), the build checks that the stack equals the rootfs, and the stock language and TPM-encryption layers are removed. `install-sources.yaml` is written as the 26.04.1 version 2 mapping with the stock `kernel:` block.
5. The live boot media is branded (an appended initrd overlay for the Plymouth theme, the GRUB menu and its automatic-install entry, `/.disk/info`), the ISO is generated with `xorriso` replaying the stock boot records, and `/md5sum.txt` is regenerated and checked.
6. Checksums are written.

Details of each step, the layer design and the live-only table are in [backends/ubuntu/iso/README.md](../../backends/ubuntu/iso/README.md) and [ubuntu-iso-layers.md](../architecture/ubuntu-iso-layers.md).

### Size and the Stick boot slot

A 64 GB Companion Stick has an 8 GiB boot slot (8,589,934,592 bytes) and `ci-stick flash` refuses an image that does not fit. The first complete 26.04.1 image is 7,076,577,280 bytes, so 1,513,357,312 bytes are spare [V]; `verify-iso.sh` section 9 fails an image above 8 GiB. The stock ISO is 6,482,409,472 bytes. With `CI_OS_OLLAMA_CUDA=none` expect about 1.5 GB less (measured as an estimate, not a build).

### Verify

```bash
VERIFY_BASE_ISO=./ubuntu-26.04.1-desktop-amd64.iso VERIFY_REQUIRE_CANON=1 \
  ./backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-1.0-amd64.iso
```

No root and no boot needed. With `VERIFY_BASE_ISO` the Secure Boot binaries, the initrd's stock bytes, the kernel block and the volume id are compared with the stock ISO's; `VERIFY_REQUIRE_CANON=1` fails the run if the brand checks that need the repository checkout could not run. On the first complete image: **393 passed, 0 failed** in 34 seconds [V]. The verifier cannot prove that the image boots; for that run `backends/ubuntu/iso/tests/installed-boot.sh` ([Testing in QEMU](testing-in-qemu.md#the-installed-boot-test-ubuntu-edition)) and boot the live ISO.

### Customizing

Edit the source, not the image. Where things live now:

| To change | Edit |
|---|---|
| OS identity files (`/etc/os-release`, `lsb-release`, `/etc/issue`) | `backends/ubuntu/lib/os-release.sh` (one writer, used by the build and the post-install re-skin) |
| Branding, wallpapers, the dock's start icon, Plymouth, MOTD | `backends/ubuntu/desktop-theme/*.sh` and `vendor/brand/` (tokens and logos); assets in `assets/` and `core/render/inputs/` |
| Packages installed into the image | Step 10b (development packages), 10d (wireless stack, Docker, CI-Hub tooling) and 10e (optional tools) of `backends/ubuntu/chroot/customize-chroot.sh`; the tool list and versions in `core/manifest/ecosystem.yaml` and `core/manifest/tier-b-pins.env` |
| Which apps are pinned in the dock (the left GNOME bar) | `backends/ubuntu/chroot/dock-favorites.txt`, one desktop-file id per line; `customize-chroot.sh` writes it to `/etc/dconf/db/local.d/02-ci-os-dock` and `verify-iso.sh` checks the image against the same list. The test is `backends/ubuntu/lib/tests/dock-favorites.sh` |
| Telemetry removal | `backends/ubuntu/lib/remove-telemetry.sh` |
| The GNOME Shell theme | [GDM branding package](gdm-branding-package.md) |
| The one-click installer | `backends/ubuntu/chroot/payload/live-start/` and [one-click-install.md](../architecture/one-click-install.md) |
| What a live session has that the installed system must not | the table in `backends/ubuntu/iso/scripts/lib/split-live-layer.sh` and [ubuntu-iso-layers.md](../architecture/ubuntu-iso-layers.md) |

There is no installer whitelabel step: the installer is Canonical's snap and its text is fixed; only the launcher label and the last page's product name come from `/.disk/info`. `verify-iso.sh` lists the Ubuntu strings that cannot change.

To add a `.deb` of your own, create `backends/ubuntu/packages/<name>/DEBIAN/control` and the file tree, run `./backends/ubuntu/iso/scripts/build-packages.sh ./output/packages`, and install the package from `customize-chroot.sh` (the build does not install packages from that directory by itself, except through the gresource copy of Step 2b).

### Changing the base ISO

A bump of the base (a point release such as 26.04.2) is **not** a one-line change of `BASE_ISO_SHA256`: the layer-split table and
`verify-iso.sh` name stock paths literally, and nothing fails by itself when a new stock live layer gains a live-only file (that is how the
polkit rule, the sysctl file and the encryption seed went unnoticed on 26.04.1). The same list is a comment in
`.github/workflows/build-companion-os-iso.yml` next to the pin; this section is the maintained copy, so change both together. Before changing the pin, on the
**new** ISO, in a throw-away `ubuntu:26.04` container (the commands are in the header of each test):

| # | Check | Command | What it proves |
|---|---|---|---|
| 1 | Every live-only path of the new live layer is accounted for | `SPLIT_TEST_ONLY="B1"` `backends/ubuntu/iso/tests/split-live-layer.sh` (Part B, group B1) on the new stock layers | each live-only path is in the removal table of `scripts/lib/split-live-layer.sh` or is generated state of a package that stays |
| 2 | The signed GRUB's built-in modules are still the committed list | `CI_TEST_STOCK_ISO=<new ISO> backends/ubuntu/iso/tests/grub-live-menu-modules.sh` (check G4) | the live menu's `insmod` lines still name only built-in modules (`tests/fixtures/grub-cd-builtin-modules-*.txt`) |
| 3 | The `md5sum.txt` convention is unchanged | `CI_TEST_STOCK_ISO=<new ISO> backends/ubuntu/iso/tests/md5sum-txt.sh` | the stock file's sorting and exclusions are still the ones `md5sum-txt.sh` writes; `stick/scripts/fetch-signed-boot.sh` re-reads the disk image's modules |
| 4 | The initrd shape and the casper launcher-label lines are unchanged | `CI_TEST_STOCK_INITRD=<new casper/initrd> backends/ubuntu/iso/tests/boot-media-plymouth.sh` | the appended Plymouth overlay, the `.disk/info` line and casper's launcher-label lines still fit |
| 5 | One real build | the Mac or host recipe, then `VERIFY_BASE_ISO=<new ISO> VERIFY_REQUIRE_CANON=1 verify-iso.sh` | the whole image, including that it fits the 8 GiB Stick slot |

Then change `BASE_ISO_SHA256`, `BASE_ISO_URL` and the base-ISO pin in the guides together, and record the new run in
[`docs/evidence/`](../evidence/README.md).

### Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `The build host must be Ubuntu 26.04 (found ...)` | Run on Ubuntu 26.04 or in a privileged `ubuntu:26.04` container |
| `Missing required commands: ...` | Install the packages above; the message prints the full `apt-get install` line |
| `Base ISO not found` | Pass `--base-iso` with the real path |
| `the base ISO's md5sum.txt is not what md5sum-txt.sh expects` or `the base ISO does not match its own md5sum.txt` | A different point release than 26.04.1, or a damaged download. Re-check the sha256 |
| `casper/install-sources.yaml is not the version 2 mapping ...: the base ISO changed shape` | The base is not the 26.04.1 layout. Do not edit around it: a new base needs the review in [Changing the base ISO](#changing-the-base-iso) |
| `unmkinitramfs could not unpack ...` | The host's `initramfs-tools-core` is not 0.151 (not a 26.04 host) |
| `split: overlay(B + placeholder + L) is NOT the rootfs` or `live-only path in the base: ...` | A change put live-session content in the installed layer or lost a file from the live layer; the message names the path. Fix the table, not the check |
| `No space left on device` | Free 35 GB or more; on Docker Desktop also raise the virtual disk limit |
| A failed run leaves mounts under `work/chroot` | The build unmounts on exit (`trap cleanup_chroot`). After a hard kill: `sudo umount -lf work/chroot/dev/pts work/chroot/sys work/chroot/proc work/chroot/run work/chroot/dev`, then `--clean` |
| An installed system stops at `Unable to find a medium containing a live file system` | The v7 image of the retired 24.04 baseline did this: live-only content reached the installed layer. The layer split and `installed-boot.sh` exist to prevent it |
| The ISO does not boot | Run `verify-iso.sh`; boot it in QEMU ([Testing in QEMU](testing-in-qemu.md)); test the USB write with `dd ... conv=fsync` or `ci-stick` |
| Debug a step | `sudo bash -x ./backends/ubuntu/iso/scripts/build-iso.sh ...`; the build log is the primary evidence |

## Plasma edition (CachyOS-based)

The build needs only Docker on the host. Docker Desktop on Apple silicon runs the amd64 builder under Rosetta; a native x86-64 Linux host works too. It runs as a normal user and builds from the **working tree** (the container has no `.git`); the build record says whether the tree was clean.

```bash
backends/cachyos/iso/scripts/build-iso.sh --dry-run                    # every input and docker command, nothing run
backends/cachyos/iso/scripts/build-iso.sh --stop-after validate        # about 2 minutes, no ISO: check an overlay change
caffeinate -i backends/cachyos/iso/scripts/build-iso.sh --out ./output --require-clean     # the real build
```

| Option | Meaning |
|---|---|
| `--out DIR` | Output directory (default `<repo>/output`) |
| `--version VER` | Version for `os-release` and the build record (default `$CI_OS_VERSION`, else 1.0) |
| `--stop-after STAGE` | `overlay` or `validate` |
| `--require-clean` / `--allow-dirty` | Refuse a dirty tree / build one on purpose |
| `--source-date-epoch E` | `now` (default), `pin` or seconds: the instant behind the date in the ISO name |
| `--cpus N`, `--jobs N`, `--memory SIZE` | Container resources (defaults 8, `--cpus`, 16g; `mksquashfs` peaks near 8 GiB) |
| `--unprivileged` | `--cap-add SYS_ADMIN` instead of `--privileged`; proven only for a trimmed profile |
| `--cache-volume NAME`, `--rebuild-image`, `--keep-container`, `--force` | See `--help` |

**Output:** `companion-os-plasma-<YYYY.MM.DD>-x86_64.iso`, `.iso.sha256`, `.pkgs.txt` (the packages of the live image) and `.build-info` (commit, tree state, upstream pin, builder image digest, repository database hashes, overlay and payload digests, compatibility libraries). Time: 25 to 26 minutes for ISO #4, #5 and #6 [V]; the squashfs step prints nothing for about 11 minutes, which is not a hang. Disk: 25 GiB.

**Verify** (needs `xorriso`, `unsquashfs` and Python with PyYAML, so on a Mac run it in the builder image, with the ISO mounted read-only):

```bash
IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' ci-os-cachyos-builder | head -n 1)"
docker run --rm --platform linux/amd64 --cpus 4 --memory 8g \
  -v "$PWD:/repo:ro" -v "$PWD/output:/iso:ro" "$IMAGE" bash -c '
    VERIFY_FETCH_UPSTREAM=1 /repo/backends/cachyos/iso/scripts/verify-iso.sh "$(ls /iso/companion-os-plasma-*-x86_64.iso | head -n 1)"'
```

For a release add `VERIFY_REQUIRE_CLEAN=1 VERIFY_REQUIRE_ALL=1`. The latest recorded run is **215 passed, 0 failed on ISO #6** (`docs/evidence/2026-10-18-plasma-iso6/verify.log`), then 187 passed, 0 failed (ISO #2) and 182 passed, 1 failed (the first full build) [V]; no log of a run on ISO #4 or #5 was kept.

**Rolling-release drift.** This edition is a rolling release: packages are current at build time and again at install time, so an ISO ages. The installer package of the day may need libraries the image does not have; the build therefore ships three pinned compatibility libraries (`backends/cachyos/compat-libs.lock`, review by 2026-12-01) and fails the build when the installer no longer links (`ldd -r` on every ELF of the Calamares package plus a 20 second offscreen start). Use `CI_OS_COMPAT_REVIEW=error` for a release build so an overdue review fails. Background and the incident: [cachyos-backend.md](../architecture/cachyos-backend.md#rolling-release-drift-incident-2026-10-18-f1-f2).

**Naming rule.** The CachyOS name stays out of file names, titles, the volume label and the publisher string (`verify-iso.sh` section 1). Build the file as `companion-os-plasma-*`.

### Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `error restricting syscalls via seccomp: 22!` | pacman's download sandbox under Rosetta; the build container disables it only when pacman says it must. Do not turn it off by hand |
| The build stops at "the squashfs step prints nothing for ~10 minutes" | Not a hang; wait |
| `missing library libboost_python314.so.1.91.0` (named by the build gate) | The repositories moved past the installer's libraries. Refresh `compat-libs.lock` as its header describes, then `build-iso.sh --stop-after validate` |
| The build finished but copying out failed | The container and work volume are kept with the ISO inside, and the `docker cp` command that recovers it is printed |
| `--require-clean` refuses the tree | Commit or stash; the message lists uncommitted, untracked and ignored files under the copied subset |
| `verify-iso.sh` skips Calamares YAML checks | The builder image lacks Python and PyYAML; `pacman -Sy --noconfirm python python-yaml` in it, or rebuild the image with `--rebuild-image` |

## CI workflows

All four workflows in `.github/workflows/` are **gated to manual dispatch** (`ci-local:gated`): a push or pull request starts nothing. Checks run locally with `./core/lib/check-repo.sh`. The workflow list in `docs/CI.md` is generated by `ci-local docs` and does not list all four, so use this table.

| Workflow | Starts | What it does |
|---|---|---|
| `build-companion-os-iso.yml` (Build Companion OS ISO) | manual; inputs `version` (required) and `sign` | Starts a privileged `ubuntu:26.04` container on the runner, installs the build dependencies in it, downloads the base ISO and verifies it (signed `SHA256SUMS` with the pinned key, exactly one line for this ISO, the pinned sha256), builds with `build-iso.sh`, runs `verify-iso.sh` with `VERIFY_BASE_ISO`, writes checksums, an SBOM and release notes, uploads an artifact (7-day retention), and creates a GitHub release. **The release step is not safe for ISOs** (it is not a draft and GitHub allows 2 GiB per asset): see [Known issues](../architecture/known-issues-and-decisions.md) KI-12 |
| `pr-checks.yml` (PR checks) | manual | `check-repo` (the same script as local), `stick` (cargo fmt, clippy, tests), `stick-qemu` (boots the Stick test image in a privileged `ubuntu:26.04` container) |
| `stick-real-iso.yml` (Companion Stick real-ISO smoke test) | manual | Flashes a real Ubuntu 26.04 desktop ISO (or a Companion OS ISO from a build run) into a sparse 64 GB stick image with the production `grub.cfg` and boots it until casper has started; the ISO is used only after its `SHA256SUMS` signature and sha256 verify |
| `style-canon-lint.yml` (Style canon lint) | manual | The brand canon lint, `vendor-brand.sh --check`, `check-brand-mirrors.sh` and `bash -n` over the theme scripts |

Starting a gated workflow needs the `gh` CLI and push access:

```bash
gh workflow run build-companion-os-iso.yml --repo companionintelligence/CI-OS --ref main -f version=1.0 -f sign=false
```

`--ref` matters: the workflow file is read from that branch. **No workflow has run on GitHub since the 26.04 port** [N]; the pieces were exercised separately (the signature and pin logic against the real files, the container steps on a Mac). To sign in CI add the repository secrets `GPG_PRIVATE_KEY` and `GPG_PASSPHRASE` and set `sign=true`; never commit a key. Who holds the release key is open ([Known issues](../architecture/known-issues-and-decisions.md) KI-12).

## Recording a build

For every build you intend to test or publish, keep: the commit and tree state, the base ISO sha256, the output file name, size and sha256, the verifier's summary line, the build time and the host (a Mac or a Linux machine, and its load). The Plasma build writes most of this into `.build-info`; for the Ubuntu edition copy the build log's last lines and the verifier's summary. Put the record next to the evidence in [test-evidence.md](../architecture/test-evidence.md), **and copy the text records into [`docs/evidence/`](../evidence/README.md)** so that they outlive the session scratch directory:

```bash
RUN="docs/evidence/$(date +%Y-%m-%d)-ubuntu-clean-$(git rev-parse --short HEAD)"      # or -plasma-isoN
mkdir -p "$RUN" && (cd output && shasum -a 256 companion-os-*.iso) > "$RUN/SHA256SUMS"
cp build.log "$RUN/" && git add "$RUN"          # also verify.log, the exit status and the build record; strip host paths and credentials first
```

The directory name, the size bound and the rules for what may be copied are in the evidence README.

## Related

- [Building on a Mac](building-on-a-mac.md), [Testing in QEMU](testing-in-qemu.md), [Release checklist](release-checklist.md)
- [Installation guide](installation-guide.md), [Quick start](quick-start-guide.md)
- [backends/ubuntu/iso/README.md](../../backends/ubuntu/iso/README.md), [backends/cachyos/README.md](../../backends/cachyos/README.md)
- [Known issues and decisions](../architecture/known-issues-and-decisions.md), [Test evidence](../architecture/test-evidence.md)

Support: https://github.com/companionintelligence/CI-OS/issues

© Companion Intelligence, Lifescope Inc
