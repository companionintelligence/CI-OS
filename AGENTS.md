# AGENTS.md — CI-OS

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

**`CLAUDE.md` is the canonical agent guide for this repo** — read it first. It covers the
repo's purpose, the `core/` + `backends/<name>/` layout, the stack per backend, and the
key commands. This file only restates the rules every agent tool must follow.

## What this repo is (one line)

Builds, themes and provisions the Companion Intelligence appliance OS. Supported targets:
Companion OS on Ubuntu 26.04 LTS (resolute) and Companion OS on CachyOS. Shared logic in `core/`,
per-edition mechanics in `backends/ubuntu/` and `backends/cachyos/` (`backends/arch/` is the
provisioning engine under CachyOS, not a target). Design: `docs/architecture/multi-distro-design.md`.

Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from tag `pre-retire-multidistro-2026-10-17`; do not re-add them as new files).

## Validate before every push

```bash
./core/lib/check-repo.sh   # bash -n, shellcheck (errors), py_compile, yamllint, no build artifacts
```

The same script is the `PR checks` GitHub workflow.

## Git discipline

- Never `git reset --hard`, `git clean -f`, or force-push someone else's branch without user
  confirmation — multiple agents work this repo in parallel.
- Never commit build outputs (`*.deb`, `*.iso`, `*.rpm`); build them.
- Commit messages: imperative mood, ≤ 72 chars.
- Reference CI-Engineering issues in PRs (e.g. `Closes companionintelligence/CI-Engineering#32`).

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
