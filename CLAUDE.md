# CLAUDE.md — CI-OS

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

## Platform role

**CI-OS** sits in the **Infrastructure** layer of the Companion Intelligence platform.

Architecture: `CI-Engineering/architecture/architecture.md`
Roadmap: `CI-Engineering/architecture/roadmap.md`
Issues: <https://github.com/companionintelligence/CI-Engineering/issues>

## What this repo does

Builds and themes the Companion Intelligence appliance base OS and provisions the CI ecosystem
(Docker, dev tooling, local LLMs via Ollama, CI-Hub) on top of it. See
`docs/architecture/multi-distro-design.md` for the design and rollout plan.

**Supported targets: Companion OS on Ubuntu 26.04 LTS (resolute) and Companion OS on CachyOS.**
Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from tag `pre-retire-multidistro-2026-10-17`, e.g. `git checkout pre-retire-multidistro-2026-10-17 -- backends/<name>`; do not re-add them as new files).
`backends/arch/` is **not** a target: it is the provisioning engine under CachyOS (frozen; change it only on an explicit decision).

Architecture: shared brand-theming and ecosystem-provisioning logic lives in `core/`
(distro-portable); each edition's actual build/install mechanism lives in
`backends/ubuntu/` or `backends/cachyos/`.

**Companion Stick** (`stick/`): a Rust CLI, `ci-stick`, that turns CI-OS into a
multi-function USB stick. The stick boots Companion OS, installs Hub/Memory/models onto a
running host, carries signed model packs offline and updates itself (A/B). `backends/`
stay the OS image adapters; `ci-stick` packages, signs, verifies, flashes and (later)
updates what they build. Today it has `lock`, `verify`, `layout plan`, `models list`, a
read-only `doctor`, and `flash` / `slot` (safe Ubuntu x86_64 flashing, A/B via grubenv,
QEMU boot tests in `stick/tests/qemu/run.sh`). See `docs/architecture/companion-stick.md`
and `stick/README.md`.

## Stack

- **Shared** (`core/`): plain Bash + a declarative `core/manifest/ecosystem.yaml` (the single
  source of truth for what gets installed — see its own comments) — no distro assumptions here.
- **`backends/ubuntu/`**: apt/dpkg + Bash. `squashfs-tools` and `xorriso` for ISO building
  (it repacks the layers of the stock Ubuntu 26.04.1 Desktop ISO and does not build a rootfs from scratch);
  `.deb` packaging; systemd first-boot services.
- **`backends/arch/`**: pacman + Bash. The provisioning engine under CachyOS, not a target:
  `backends/cachyos/provision/provision.sh` wraps its `provision/provision.sh`, and
  `headless-setup/install.sh` is the dependency oracle the payload tests and the CachyOS ISO verifier read.
- Docker Compose for service bootstrap (CI-Hub), distro-agnostic once Docker itself is present.
- **`stick/`**: Rust (Cargo workspace, MSRV 1.75, `Cargo.lock` committed). **Rust is
  first-class inside `stick/` only**. Don't introduce it into `core/` or the backends.
- **`backends/cachyos/`**: bash + Docker (host) and bash 5 (container); a pinned upstream archiso profile plus an overlay. archiso gives files modes only from `file_permissions` (mkarchiso drops modes), so every executable the overlay adds needs an entry in `overlay/profiledef.append.sh`.

## Key commands

```bash
# Build a branded Companion OS ISO (as root, on an Ubuntu 26.04 build host: build-iso.sh stops on any other host)
sudo ./backends/ubuntu/iso/scripts/build-iso.sh --base-iso ./ubuntu-26.04.1-desktop-amd64.iso
# From a Mac or any non-26.04 host: the same build inside a privileged ubuntu:26.04 container
# (docker run --privileged --platform linux/amd64 ... ubuntu:26.04; see backends/ubuntu/iso/README.md)

# Provision a fresh/existing Ubuntu into a CI appliance (idempotent)
# --tier=core,hardware is the default; add "extended" for VS Code/Chromium/Homebrew/Launcher
sudo ./backends/ubuntu/provision/provision.sh --tier=core,extended,hardware

# Apply CI desktop branding only (no packages)
sudo ./backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh

# Fast checks — run before every push (same as the "PR checks" workflow)
./core/lib/check-repo.sh

# Companion Stick CLI (stick/) — same as the "stick" job in PR checks
(cd stick && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)

# See README.md for the four customization entry points.
```

> PR conventions for agents (validation, layout, what not to commit) live in
> `.claude/skills/steward/SKILL.md`.

> The Ubuntu backend lives under `backends/ubuntu/{iso,provision,desktop-theme}/`. All
> ecosystem provisioning goes through the single `provision.sh` entrypoint (tier-gated —
> see its own header) — this replaced `setup-fresh-ubuntu.sh`, `bootstrap-ci-os.sh`'s own
> tool list, and the undocumented `ci-os-setup.sh` as separate things. See
> `docs/architecture/multi-distro-design.md`.

## Package manager

No single one — package management is backend-specific (see Stack above): apt/dpkg on Ubuntu,
pacman on CachyOS (through `backends/arch/`). `core/` itself has no package-manager assumptions;
each `backends/<name>/` uses its distro's native tooling.

## Cross-repo connections

- Hosts: CI-Hub (local TLS/routing is the Hub-managed Traefik stack; the former CI-Gateway repo
  was retired). **CI-Server has no implementation in this repo** — it's tracked only as a
  `reserved` entry in `core/manifest/ecosystem.yaml`, pointing at its own repo.
- Desktop and boot theming lives in `backends/ubuntu/desktop-theme/`; CachyOS themes through its
  overlay (`backends/cachyos/iso/overlay`). The legacy `configs/` Cubic/preseed customization tree
  was removed as dead code.
- Assets in assets/



## Multi-agent safety

Multiple AI agents work these repos in parallel. Never use `git reset --hard`, `git clean -f`, or any destructive git command without explicit confirmation from the user.

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
