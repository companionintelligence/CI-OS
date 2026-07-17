# ANTIGRAVITY.md — CI-OS

## Context

**CI-OS** — **Infrastructure** layer of the Companion Intelligence platform (Lifescope Inc).

Architecture: `CI-Engineering/architecture/architecture.md`
Roadmap: `CI-Engineering/architecture/roadmap.md`

## Purpose

Base OS image for the Companion Intelligence appliance. Likely NixOS or a custom Linux distro configured to host CI-Hub and CI-Server.

## Stack

- NixOS / Bash / shell scripts
- Docker Compose (for service bootstrap)
- Package configs in config/

## Commands

```bash
# see scripts/ for setup helpers
bash scripts/build.sh
# validation via scripts/test.sh
```

## Rules

- Package manager: do not switch or mix.
- Destructive git operations (`reset --hard`, `clean -f`) require explicit user confirmation.
- Commits reference CI-Engineering issues.
- All content is **private and confidential** — Property of Lifescope Inc.
