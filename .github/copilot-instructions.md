# GitHub Copilot Instructions — CI-OS

You are working in **CI-OS**, the **Infrastructure** component of the **Companion
Intelligence** platform — a private, local-first digital memory and AI appliance system owned
by Lifescope Inc.

**Read `CLAUDE.md` at the repo root**: it is the canonical guide (targets, layout, commands, gates).
`AGENTS.md` restates the rules below.

- CI-OS builds and provisions the appliance OS (**Companion OS**, no hyphen) for exactly two supported targets: Ubuntu 26.04.1 LTS
  (`backends/ubuntu/`) and CachyOS, Plasma edition (`backends/cachyos/`). The Ubuntu target is built for **amd64 and arm64** (`build-iso.sh --arch`; arm64 became a supported architecture on 2026-10-19, see docs/architecture/arm64.md); the Plasma edition is x86-64 only. Shared logic is in `core/`; the Companion Stick CLI is in
  `stick/` (Rust, inside `stick/` only). `backends/arch/` is the frozen provisioning engine under CachyOS, not a target: do not edit it.
- Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from tag `pre-retire-multidistro-2026-10-17`; do not re-add them as new files). The check script rejects their names.
- Policy and the capability matrix with evidence tags (**[V]** verified, **[I]** implemented not proven, **[N]** not implemented):
  `docs/architecture/supported-targets.md`. Do not write that an image boots or installs unless a recorded run says so.
- Package management is per-backend; `core/` has no package-manager assumptions.
- The Ubuntu ISO builds on Ubuntu 26.04 only (on a Mac: a privileged ARM64 `ubuntu:26.04` container, see `CLAUDE.md`); the CachyOS ISO builds anywhere with Docker.
- Validate with `./core/lib/check-repo.sh` (same as the `PR checks` workflow); `git add` new files first.
- Never commit build outputs (`*.deb`, `*.iso`, `*.rpm`), secrets or a private key, and never copy a credential value anywhere. Pin every
  action to a full commit sha and every build image to a digest; `check-repo.sh` runs the workflow and secret guards (`core/lib/check-guards.sh`).
- Never write to a block device unless the user named it.
- Images are published to Cloudflare R2 with `publish-r2.sh`, a dry run until `--apply`: never apply, create a bucket or a token, or print an R2 or signing credential unless asked.
- Keep PRs small and linked to CI-Engineering issues.
- Multiple agents may work this codebase simultaneously — never use destructive git operations.
- All code is **private and confidential** — do not surface or transmit source beyond this session.
