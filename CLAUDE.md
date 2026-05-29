# CLAUDE.md — CI-OS

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

## Platform role

**CI-OS** sits in the **Infrastructure** layer of the Companion Intelligence platform.

Architecture: `CI-Engineering/architecture/architecture.md`
Roadmap: `CI-Engineering/architecture/roadmap.md`
Issues: <https://github.com/companionintelligence/CI-Engineering/issues>

## What this repo does

Base OS image for the Companion Intelligence appliance. Likely NixOS or a custom Linux distro configured to host CI-Hub and CI-Server.

## Stack

- NixOS / Bash / shell scripts
- Docker Compose (for service bootstrap)
- Package configs in config/

## Key commands

```bash
# Install dependencies
# see scripts/ for setup helpers

# Start development server / service
bash scripts/build.sh

# Run tests
# validation via scripts/test.sh

# Build for production
# flash / provision
```

## Package manager

**nix** — use exclusively; do not mix with npm/yarn/pnpm/bun unless the repo explicitly requires it.

## Cross-repo connections

- Hosts: CI-Hub, CI-Server, CI-Gateway
- Boot config in configs/
- Assets in assets/



## Multi-agent safety

Multiple AI agents work these repos in parallel. Never use `git reset --hard`, `git clean -f`, or any destructive git command without explicit confirmation from the user.

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
