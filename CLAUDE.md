# CLAUDE.md — CI-OS

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

## Platform role

**CI-OS** sits in the **Infrastructure** layer of the Companion Intelligence platform.

Architecture: `CI-Engineering/architecture/architecture.md`
Roadmap: `CI-Engineering/architecture/roadmap.md`
Issues: <https://github.com/companionintelligence/CI-Engineering/issues>

## What this repo does

Base OS for the Companion Intelligence appliance. **Not a from-scratch distro** — it is
**Ubuntu 24.04 LTS (Noble)** rebranded as CI-OS, with telemetry removed, AMD/ROCm support,
and the CI stack (Docker, Node, Ollama, CI-Hub, CI-Server) installed on first boot. The repo
builds branded installer ISOs and provisions machines/devices via Bash scripts.

## Stack

- **Ubuntu 24.04 (Noble)** base — no Nix
- **Bash** scripts for everything (ISO build, provisioning, branding)
- ISO tooling: `debootstrap`, `squashfs-tools`, `xorriso`; `.deb` packaging; systemd first-boot services
- Docker Compose for service bootstrap

## Key commands

```bash
# Build a branded CI-OS ISO (on an Ubuntu 24.04 build host, as root)
sudo ./tools/iso-build/scripts/build-iso.sh --base-iso ./ubuntu-24.04.4-desktop-amd64.iso

# Provision a fresh/existing Ubuntu into a CI appliance (idempotent)
sudo ./scripts/setup-fresh-ubuntu.sh

# Apply CI desktop branding only (no packages)
sudo ./setup/os-changes/apply-ci-os-desktop.sh

# See README.md for the four customization entry points.
```

## Package manager

**apt / dpkg** plus plain Bash. There is no Nix here — do not introduce it.

## Cross-repo connections

- Hosts: CI-Hub, CI-Server, CI-Gateway
- Boot config in configs/
- Assets in assets/



## Multi-agent safety

Multiple AI agents work these repos in parallel. Never use `git reset --hard`, `git clean -f`, or any destructive git command without explicit confirmation from the user.

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
