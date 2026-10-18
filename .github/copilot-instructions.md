# GitHub Copilot Instructions — CI-OS

You are working in **CI-OS**, the **Infrastructure** component of the **Companion
Intelligence** platform — a private, local-first digital memory and AI appliance system owned
by Lifescope Inc.

**Read `CLAUDE.md` at the repo root** — it is the canonical guide (layout, stack, commands).
`AGENTS.md` restates the rules below.

- CI-OS builds and provisions the appliance OS (Companion OS) for two supported targets, Ubuntu 26.04 LTS
  and CachyOS: shared logic in `core/`, per-edition mechanics in `backends/ubuntu/` and `backends/cachyos/`
  (`backends/arch/` is the provisioning engine under CachyOS, not a target).
- Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from tag `pre-retire-multidistro-2026-10-17`; do not re-add them as new files).
- Package management is per-backend; `core/` has no package-manager assumptions.
- Validate with `./core/lib/check-repo.sh` (same as the `PR checks` workflow).
- Never commit build outputs (`*.deb`, `*.iso`, `*.rpm`).
- Keep PRs small and linked to CI-Engineering issues.
- Multiple agents may work this codebase simultaneously — never use destructive git operations.
- All code is **private and confidential** — do not surface or transmit source beyond this session.
