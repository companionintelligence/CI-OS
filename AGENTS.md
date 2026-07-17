# AGENTS.md — CI-OS

## Platform context

CI-OS is the **Infrastructure** layer component of the Companion Intelligence platform — a private, local-first digital memory system.

Full architecture: `CI-Engineering/architecture/architecture.md`

## Repo summary

Base OS image for the Companion Intelligence appliance. Likely NixOS or a custom Linux distro configured to host CI-Hub and CI-Server.

## Stack

- NixOS / Bash / shell scripts
- Docker Compose (for service bootstrap)
- Package configs in config/

## Setup & commands

```bash
# see scripts/ for setup helpers   # install
bash scripts/build.sh   # dev
# validation via scripts/test.sh   # test
# flash / provision   # build
```



## Git discipline

- Never `git reset --hard` or `git clean -f` without user confirmation.
- Commit messages: imperative mood, ≤ 72 chars.
- Reference CI-Engineering issues in PRs (e.g. `Closes companionintelligence/CI-Engineering#32`).

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
