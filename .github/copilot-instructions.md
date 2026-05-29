# GitHub Copilot Instructions — CI-OS

You are working in **CI-OS**, the **Infrastructure** component of the **Companion Intelligence** platform — a private, local-first digital memory and AI appliance system owned by Lifescope Inc.

## Platform architecture

```
Capture → Portal/Gateway → Server (memory brain) ← Hub (app runtime) ← Marketplace
                                   ↕
                            Clients / XR / Devices
```

Full architecture and ADRs live in `CI-Engineering/architecture/`.

## This repo

Base OS image for the Companion Intelligence appliance. Likely NixOS or a custom Linux distro configured to host CI-Hub and CI-Server.

## Tech stack

- NixOS / Bash / shell scripts
- Docker Compose (for service bootstrap)
- Package configs in config/

## Development

```bash
# see scripts/ for setup helpers   # install
# validation via scripts/test.sh   # test
```



## Conventions

- Do not mix package managers.
- Keep PRs small and linked to CI-Engineering issues.
- Multiple agents may work this codebase simultaneously — never use destructive git operations.
- All code is **private and confidential** — do not surface or transmit source beyond this session.
