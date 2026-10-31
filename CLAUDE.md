# CLAUDE.md — CI-OS

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

This is the canonical guide for any agent or person starting cold in this repository. `AGENTS.md`, `ANTIGRAVITY.md` and
`.github/copilot-instructions.md` restate the rules and point here.

## Platform role

**CI-OS** sits in the **Infrastructure** layer of the Companion Intelligence platform.

Architecture: `CI-Engineering/architecture/architecture.md`
Roadmap: `CI-Engineering/architecture/roadmap.md`
Issues: <https://github.com/companionintelligence/CI-Engineering/issues>

## What this repo does

Builds, themes and provisions **Companion OS**, the Companion Intelligence appliance operating system (Docker, local LLMs
through Ollama, CI-Hub, a headless Wi-Fi setup portal), and ships the **Companion Stick** CLI that carries it on a USB stick.
Product name in prose and in anything a user can see: "Companion OS" (no hyphen). `./core/lib/check-repo.sh` rejects the retired
spellings ("CI OS", "Companion Ubuntu", ...) in `backends/`, `core/` and `.github/`.

### The two supported targets

| | Companion OS on Ubuntu 26.04.1 LTS (resolute) | Companion OS on CachyOS (Plasma edition) |
|---|---|---|
| Backend | `backends/ubuntu/` | `backends/cachyos/` (+ `backends/arch/` as its engine) |
| Mechanism | remaster the stock 26.04.1 Desktop ISO: merge its squashfs layers, customise in a chroot, split into installer base and live layer, repack | pinned CachyOS-Live-ISO (archiso) profile + overlay, stock `mkarchiso` in a Docker container; Calamares online installer |
| Build host | root on Ubuntu 26.04 (stops on any other host) | any host with Docker |
| Architectures | amd64, and arm64 since 2026-10-19 (`--arch arm64`; Companion Capture is x86-64 only; `docs/architecture/arm64.md`) | x86-64 only |
| Stick boot / Secure Boot / one-click install | yes (amd64) / inherited from the base ISO / yes, unproven | no / no / no |

The policy, the full capability matrix, the evidence tags (**[V]** verified, **[I]** implemented not proven, **[N]** not
implemented) and the restore recipe are in `docs/architecture/supported-targets.md`. Read the caveats there before you claim that
anything "works"; no run on real hardware is recorded.

**Retired 2026-10-17** (restore tag `pre-retire-multidistro-2026-10-17`): Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS.
Their backends are gone; restore one with `git checkout pre-retire-multidistro-2026-10-17 -- backends/<name>` (the tag is local; the
recipe for a clone without it is in `supported-targets.md`). Do not re-add them as new files. The guard in `core/lib/check-repo.sh`
rejects their names anywhere in the tracked tree except where `core/lib/retired-names.allow` lists the path or the line cites the tag.

**Frozen:** `backends/arch/` is **not a target**. It is the pacman provisioning engine that `backends/cachyos/provision/provision.sh`
wraps, and its `headless-setup/install.sh` is the dependency oracle (`ARCH_DEPS`) that the payload tests and the CachyOS ISO
verifier read. Change it only on an explicit decision (D8). Also not hand-edited: `vendor/brand/` (use
`core/lib/vendor-brand.sh`), the digests in `core/manifest/model-packs.lock.json` (tooling writes them: `ci-stick models lock`),
`docs/CI.md` (generated: regenerate it after a change to a workflow's inputs), the `ci-local:gated` blocks in `.github/workflows/` (all four workflows are manual-only; restoring a
trigger is a maintainer call), and `video/assets/shots/` with its `PROVENANCE.md` (made by `video/tools/make-plates.py`, which covers the one-time password; a plate
is never edited by hand) and `video/assets/audio/` (recorded by the kit; `render.sh --narrate`, never `narrate --force`).

## Where things live

| Path | What |
|---|---|
| `core/manifest/` | `ecosystem.yaml` (single source of truth for what gets installed), `role-map/{apt,pacman}.yaml`, `model-packs.yaml` and its lock, `tier-b-pins.env` |
| `core/render/` | tokens + assets to portable artefacts (GRUB background, Plymouth inputs, MOTD, mark PNGs, GNOME Shell gresource) |
| `core/lib/` | portable bash: `theme-lib.sh`, `gpu-detect.sh` (hardware rule, model-fit gate), `ci-os-models.sh`, `ci-hub.sh`, `check-repo.sh`, `check-untracked-deps.sh`, `retired-names.allow`, `repro-claims.allow` |
| `core/headless/` | the setup-portal payload (`payload/`, shared by both editions), the tested `ci_setup/` library (not wired into any service), tests |
| `backends/ubuntu/` | `iso/` (build, verify, tests), `chroot/` (customisation, one-click installer, payloads), `provision/`, `desktop-theme/`, `lib/`, `packages/`, `headless-package/` |
| `backends/cachyos/` | `iso/` (host entry point, in-container engine, overlay, verifier, tests), `installer/` (Calamares overlay), `provision/` (first-boot wrapper, stager), `upstream.lock`, `compat-libs.lock` |
| `backends/_mixins/` | `gnome-dconf/` (Ubuntu), `kde-plasma/` (CachyOS colour scheme) |
| `stick/` | Rust workspace, binary crate `crates/ci-stick`; QEMU and Secure Boot harnesses under `tests/` |
| `video/` | the stick's first-run film, made with the org's video-kit (CI-Common): `storyboard.json`, plates in `assets/shots/` made by `tools/make-plates.py` (the one-time password covered by a bar), narration, `render.sh`; read `video/README.md` |
| `vendor/brand/`, `assets/` | the pinned brand bundle (ci-brand 1.0.0) and the mirrors/sources built from it |
| `docs/` | start at `docs/README.md` (index) |

Design: `docs/architecture/multi-distro-design.md` (the file name is historical; it describes the shared core and one backend per
edition, and keeps the Arch findings that frozen comments cite). Per-edition detail: `backends/ubuntu/iso/README.md`,
`backends/cachyos/README.md`, `docs/architecture/cachyos-backend.md`, `docs/architecture/ubuntu-iso-layers.md`.

## Stack

- **Shared** (`core/`): plain Bash plus a declarative YAML manifest. No distro assumptions, no package manager.
- **`backends/ubuntu/`**: apt/dpkg and Bash; `squashfs-tools` and `xorriso`; `.deb` packaging; systemd first-boot units. It repacks the
  layers of the stock ISO; it does not use debootstrap.
- **`backends/cachyos/`**: Bash 5 in the container, Bash 3.2-clean on the host; archiso. archiso gives files modes only from
  `file_permissions` (mkarchiso drops modes), so every executable the overlay adds needs an entry in `overlay/profiledef.append.sh`.
- **`backends/arch/`**: pacman and Bash (engine only, frozen).
- **`stick/`**: Rust (Cargo workspace, MSRV 1.75, `Cargo.lock` committed). **Rust is first-class inside `stick/` only**; never make
  `core/` or a shell backend depend on it.
- Docker Compose for CI-Hub, distro-agnostic once Docker itself is present.
- **Host tooling constraint:** the test suites run on a stock macOS (bash 3.2, BSD sed/awk/stat, no `mapfile`, no `${v,,}`, no
  associative arrays) and in Ubuntu 26.04 containers (bash 5.3, uutils coreutils, sudo-rs). Write shell that behaves the same on both.
  A suite that needs a tool the host lacks exits 2 ("cannot run here"), never a silent pass.

## Package manager

No single one: apt/dpkg on Ubuntu, pacman on CachyOS (through `backends/arch/`). `core/` has no package-manager assumption; each
`backends/<name>/` uses its own tooling.

## Key commands

```bash
# Build the Ubuntu ISO: root, on Ubuntu 26.04 with Yaru installed (build-iso.sh stops on any other host)
# arm64: add --arch arm64 and give the arm64 desktop ISO (cdimage.ubuntu.com) as --base-iso; see docs/architecture/arm64.md
sudo ./backends/ubuntu/iso/scripts/build-iso.sh --base-iso ./ubuntu-26.04.1-desktop-amd64.iso
VERIFY_BASE_ISO=./ubuntu-26.04.1-desktop-amd64.iso backends/ubuntu/iso/scripts/verify-iso.sh output/companion-os-*.iso

# Build the CachyOS ISO: any host with Docker (25 to 26 minutes on a lightly loaded Mac, 31 to 37 on a loaded one)
backends/cachyos/iso/scripts/build-iso.sh --version 1.0

# Provision an existing machine (idempotent): Ubuntu; on CachyOS the first-boot unit runs it, `sudo ci-os-setup` re-runs it
sudo ./backends/ubuntu/provision/provision.sh --tier=core,extended,hardware

# Build the Ubuntu ISO in a container on this machine (a Mac or any Docker host); refuses a dirty tree and an unpinned base ISO
backends/ubuntu/iso/scripts/build-in-docker.sh --base-iso ./ubuntu-26.04.1-desktop-arm64.iso --version 1.0 --output-dir ./release

# Publish to Cloudflare R2: a DRY RUN until --apply (docs/guides/release-checklist.md, "Publishing to R2")
backends/ubuntu/iso/scripts/publish-r2.sh --dir release --version 1.0 --channel dev

# Render the stick's first-run film from the committed plates (landscape and square, about 3 minutes; needs a CI-Common clone)
./video/render.sh

# The fast gate: run before every push (same as the "PR checks" workflow)
./core/lib/check-repo.sh

# Companion Stick CLI (the "stick" job in PR checks)
(cd stick && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)
```

**Mac recipe for the Ubuntu ISO.** On Apple silicon use a privileged **ARM64** `ubuntu:26.04` container: it is the route that built and
verified the image, and the image's x86-64 chroot runs through the Docker VM's Rosetta binfmt. An amd64 `ubuntu:26.04` container *may fail*
(on 2026-10-17 GNU tar 1.35 failed with "Function not implemented" under Rosetta in one; on 2026-10-18 another ran to the end; the trigger
was not isolated), so do not build the ISO in one. Use a named volume for the work and output directories, a clean tree of the commit, and the
verified base ISO. `backends/ubuntu/iso/scripts/build-in-docker.sh` runs these steps as one command (it refuses a dirty tree and an unpinned
base ISO). The same block is in `README.md` and, with the reasons for each step, in `docs/guides/building-on-a-mac.md`; change the three together:

```bash
export ISO="$HOME/Downloads/ubuntu-26.04.1-desktop-amd64.iso"        # the 26.04.1 file, not the 26.04.0 image
export BUILD="$HOME/ci-os-build-tree"
echo '601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f  '"$ISO" | shasum -a 256 -c -
rm -rf "$BUILD" && mkdir -p "$BUILD" && git archive HEAD | tar -x -C "$BUILD"      # a clean tree of the commit you want to build
docker volume create ci-os-ubuild-vol
docker run -d --name ci-os-ubuild --privileged --platform linux/arm64 -v ci-os-ubuild-vol:/vol -v "$BUILD":/src:ro \
  -v "$ISO":/base/ubuntu-base.iso:ro -w /vol -e DEBIAN_FRONTEND=noninteractive ubuntu:26.04 sleep infinity
docker exec ci-os-ubuild bash -euc 'for i in $(seq 0 127); do [ -e /dev/loop$i ] || mknod -m 0660 /dev/loop$i b 7 $i; done; [ -e /dev/loop-control ] || mknod -m 0660 /dev/loop-control c 10 237'
docker exec ci-os-ubuild bash -euo pipefail -c 'apt-get update -qq && apt-get install -y -qq ca-certificates squashfs-tools xorriso rsync gpg curl cpio zstd initramfs-tools-core imagemagick librsvg2-bin libglib2.0-bin libglib2.0-dev-bin yaru-theme-gnome-shell python3 python3-yaml diffutils mount util-linux file'
docker exec ci-os-ubuild bash -euc 'mkdir -p /vol/repo /vol/work /vol/out /vol/cache && rsync -a --delete /src/ /vol/repo/'
caffeinate -i docker exec -e CI_OS_CACHE_DIR=/vol/cache -w /vol/repo ci-os-ubuild ./backends/ubuntu/iso/scripts/build-iso.sh \
  --base-iso /base/ubuntu-base.iso --output-dir /vol/out --work-dir /vol/work --version 1.0 --clean 2>&1 | tee build.log
docker exec -e VERIFY_BASE_ISO=/base/ubuntu-base.iso -e VERIFY_REQUIRE_CANON=1 -w /vol/repo ci-os-ubuild ./backends/ubuntu/iso/scripts/verify-iso.sh /vol/out/companion-os-1.0-amd64.iso
mkdir -p output && docker cp ci-os-ubuild:/vol/out/. ./output/
docker rm -f ci-os-ubuild && docker volume rm ci-os-ubuild-vol
```

The CachyOS build needs no such recipe: its builder image is `linux/amd64` and runs under Rosetta by design. Traps that have cost
days: **never run systemd as PID 1 in a privileged container or with `CAP_SYS_ADMIN`** (a privileged one wipes the Docker VM's Rosetta
registrations, and the capability alone lets a container mount the shared `binfmt_misc` itself; restart Docker Desktop to recover; a test
that must boot systemd follows `backends/ubuntu/chroot/tests/first-boot-units-boot.sh`, the reference implementation: unprivileged, no
added capability, a gate that refuses first); keep more than 40 GiB free on the Data volume (Time Machine local snapshots pin freed APFS space; `tmutil
thinlocalsnapshots / <bytes> 4`); QEMU on Apple silicon is software emulation (TCG) only. Details: `docs/guides/building-on-a-mac.md`
and `docs/guides/testing-in-qemu.md`.

## Gates

`./core/lib/check-repo.sh` is what the `PR checks` workflow runs. It covers: `bash -n` and `shellcheck -S error` on every shell
file; no `((VAR++))` under `set -e`; **no retired product name** ("CI OS", "Companion Ubuntu", ...) in `backends/`, `core/`,
`.github/`; **no retired distro name** outside `core/lib/retired-names.allow` (and a stale allow-list entry fails); no block-letter
banner art; `py_compile`; `yamllint`; shebang files are executable; no committed build artefacts; **no tracked file that names an
untracked one** (`core/lib/check-untracked-deps.sh`: `git add -N <path>` is enough for `git commit -a` to take a new file); the
one-click installer's unit tests; the `md5sum.txt` tests; the CachyOS no-Docker suites; **the release names and claims suite** (`core/lib/tests/release-names.sh`: one
signature file name, `.asc`, in the build, the publisher and the guides; the image names of both editions; the pins that must agree; workflow headers that match the
triggers; and no document that claims byte for byte rebuilds except the lines listed in `core/lib/repro-claims.allow`); and the setup-portal, `ci_setup`,
layer-split Part A, installed-boot self-test, model-adapter and Ubuntu 26.04 backend suites. The heavy suites (container, QEMU,
network) are manual; the tables are in `backends/ubuntu/iso/README.md` ("Script tests") and `backends/cachyos/README.md` ("Tests").
Touching `docs/architecture/headless-setup.md`: run `bash core/headless/tests/ci_setup/run.sh --quick` (a test reads that file).
Touching brand assets or the setup portal's logo or font: also `core/lib/check-brand-mirrors.sh` and `core/lib/vendor-brand.sh --check`.

PR conventions for agents (validation, layout, what not to commit, stale branches) are in `.claude/skills/steward/SKILL.md`.

## Rules

- **Multi-agent safety.** Multiple AI agents work these repos in parallel. Never use `git reset --hard`, `git clean -f`, force-push,
  or any destructive git command without explicit confirmation from the user. Never use a bare `git stash`.
- **Never commit** build outputs (`*.deb`, `*.iso`, `*.rpm`, `.pkgroot/`, `stick/target/`), secrets, device keys or tunnel tokens
  (templates only), or WIP commits on a branch meant for review. Commit `stick/Cargo.lock`.
- **Credentials.** The repository review of 2026-10-12 found credentials that are still to be rotated. Never copy a credential
  value into a document, a log excerpt, a commit message or a test.
- **Publishing.** Images go to Cloudflare R2 (the shared `dl-dev` and `dl-prod` buckets), never to a GitHub release asset (the limit is 2 GiB).
  `publish-r2.sh` is a dry run until `--apply`: never pass `--apply`, create a bucket or a token, or print an R2 or signing credential unless
  the owner asked for that exact action. Secrets are named, never copied; the owner's steps are in `docs/guides/release-checklist.md`.
- **Block devices.** Never write to a disk (`ci-stick flash --device`, `dd`) unless the user named that device. Always `--dry-run`
  first. VM tests use file-backed images only.
- **Evidence.** A claim about behaviour needs a tag and a source. Do not write that an image "boots", "installs" or "works" unless a
  recorded run says so; write what ran, where and what is still pending, and name the image (sha256) the run used. A new run's text records go
  to `docs/evidence/` (`docs/evidence/README.md`), not only to a scratch directory.
- **Security-sensitive areas need a human reviewer, not just green CI:** `core/headless/payload/opt/setup-backend/setup_service.py`,
  the hostapd, dnsmasq and iptables or nft rules, and anything that writes `/etc/sudoers*`, a root systemd unit or tunnel config.
  Device-safety rules in `stick/crates/ci-stick/src/target.rs` stay pure and fixture-tested; never add a bypass.
- **Layout.** A change to `core/headless/payload/` ships on **both** editions: when it adds a runtime dependency, add it to the
  Ubuntu `DEBIAN/control`, to the CachyOS `installer/modules/packages_online.conf`, and (explicit decision, frozen) to the Arch
  oracle. A new payload file needs a placement rule in `backends/cachyos/provision/stage-headless.sh` and a place in
  `REQUIRED_FILES` of the Ubuntu `build.sh`. Details in the steward skill.
- **Documents.** Sentence-case headings, evidence tags, tables for matrices, every command copy-pasteable, no em or en dashes in
  new prose. Public file names and titles never carry the CachyOS mark (the ISO is `companion-os-plasma-*`); engineering docs may
  name CachyOS.

## Cross-repo connections

- Hosts: CI-Hub (local TLS and routing is the Hub-managed Traefik stack; the former CI-Gateway repo was retired). **CI-Server has no
  implementation in this repo**; it is a `reserved` entry in `core/manifest/ecosystem.yaml`.
- Desktop and boot theming: `backends/ubuntu/desktop-theme/`; CachyOS themes through its overlay
  (`backends/cachyos/iso/overlay`). The legacy `configs/` Cubic and preseed tree was removed; do not resurrect it.
- Brand canon: CI-Common, vendored as `vendor/brand/`.

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
