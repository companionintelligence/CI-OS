# AGENTS.md — CI-OS

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

**`CLAUDE.md` is the canonical agent guide for this repo**: read it first. It covers the
two supported targets, what is frozen, where things live, the build and check commands (including the Mac container recipe)
and the gates. This file only restates the rules every agent tool must follow.

## What this repo is (in short)

Builds, themes and provisions **Companion OS**, the Companion Intelligence appliance OS, for exactly two supported targets:
**Companion OS on Ubuntu 26.04.1 LTS (resolute)**, in `backends/ubuntu/`, and **Companion OS on CachyOS (Plasma edition)**, in
`backends/cachyos/`. The Ubuntu target is built for **amd64 and arm64** (`build-iso.sh --arch`; arm64 became a supported architecture on 2026-10-19, see `docs/architecture/arm64.md`); the Plasma edition is x86-64 only. Shared logic is in `core/`; the Companion Stick CLI is in `stick/` (Rust, first-class inside `stick/` only).
`backends/arch/` is **not a target**: it is the frozen pacman provisioning engine under CachyOS (change it only on an explicit
decision). Policy, capability matrix and evidence tags: `docs/architecture/supported-targets.md`. Documentation index:
`docs/README.md`. Design: `docs/architecture/multi-distro-design.md`.

**Retired 2026-10-17:** Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS. Restore from tag `pre-retire-multidistro-2026-10-17`
(`git checkout pre-retire-multidistro-2026-10-17 -- backends/<name>`); do not re-add them as new files. The retired-name guard in
`core/lib/check-repo.sh` rejects their names outside `core/lib/retired-names.allow`.

## Validate before every push

```bash
./core/lib/check-repo.sh   # bash -n, shellcheck (errors), py_compile, yamllint, retired-name guards, untracked-file guard, release names and claims, fast suites
(cd stick && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)   # when you touched stick/
```

The same script is the `PR checks` GitHub workflow. A new file must be `git add`ed (or `git add -N`) before you trust the result:
`core/lib/check-untracked-deps.sh` fails when a tracked file names an untracked one.

## Build host rules

- The Ubuntu ISO builds as root on **Ubuntu 26.04** only (`build-iso.sh` stops elsewhere). On Apple silicon use a privileged
  **ARM64** `ubuntu:26.04` container, the route that built the verified image; an amd64 one may fail (tar "Function not implemented"
  under Rosetta, cause not isolated). Recipe: `CLAUDE.md`, or `backends/ubuntu/iso/scripts/build-in-docker.sh` (the same steps as one command; it refuses a
  dirty tree and an unpinned base ISO).
- The CachyOS ISO builds on any host with Docker.
- Images are published to Cloudflare R2, never to a GitHub release asset (2 GiB limit). `publish-r2.sh` is a dry run until `--apply`: never apply, create a
  bucket or a token, or print an R2 or signing credential unless the owner asked for that exact action (`docs/guides/release-checklist.md`).
- Never run systemd as PID 1 in a privileged container or with `CAP_SYS_ADMIN`, and never touch `/proc/sys/fs/binfmt_misc`: a
  privileged one wipes Docker Desktop's Rosetta registrations, and the capability alone lets a container mount the shared
  `binfmt_misc` itself. A test that must boot systemd follows `backends/ubuntu/chroot/tests/first-boot-units-boot.sh`, the
  reference implementation (unprivileged, no added capability, a gate that refuses first).

## Git discipline

- Never `git reset --hard`, `git clean -f`, or force-push someone else's branch without user
  confirmation: multiple agents work this repo in parallel. Never use a bare `git stash`.
- Never commit build outputs (`*.deb`, `*.iso`, `*.rpm`); build them. Never commit secrets or copy a credential value anywhere.
- Never write to a block device unless the user named it; `--dry-run` first.
- Claims about behaviour carry an evidence tag: **[V]** verified, **[I]** implemented not proven, **[N]** not implemented.
- Commit messages: imperative mood, ≤ 72 chars.
- Reference CI-Engineering issues in PRs (e.g. `Closes companionintelligence/CI-Engineering#32`).

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
