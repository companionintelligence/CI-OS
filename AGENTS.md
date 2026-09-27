# AGENTS.md — CI-OS

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

**`CLAUDE.md` is the canonical agent guide for this repo** — read it first. It covers the
repo's purpose, the `core/` + `backends/<distro>/` layout, the stack per backend, and the
key commands. This file only restates the rules every agent tool must follow.

## What this repo is (one line)

Builds, themes and provisions the Companion Intelligence appliance OS across multiple Linux
distros (Ubuntu reference backend, plus Mint, Fedora, Arch, Bazzite, NixOS). Shared logic in
`core/`, per-distro mechanics in `backends/<distro>/`. Design:
`docs/architecture/multi-distro-design.md`.

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
