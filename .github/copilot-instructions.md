# GitHub Copilot Instructions — CI-OS

You are working in **CI-OS**, the **Infrastructure** component of the **Companion
Intelligence** platform — a private, local-first digital memory and AI appliance system owned
by Lifescope Inc.

**Read `CLAUDE.md` at the repo root** — it is the canonical guide (layout, stack, commands).
`AGENTS.md` restates the rules below.

- CI-OS builds and provisions the appliance OS across multiple distros: shared logic in
  `core/`, per-distro mechanics in `backends/<distro>/` (Ubuntu is the reference backend).
- Package management is per-backend; `core/` has no package-manager assumptions.
- Validate with `./core/lib/check-repo.sh` (same as the `PR checks` workflow).
- Never commit build outputs (`*.deb`, `*.iso`, `*.rpm`).
- Keep PRs small and linked to CI-Engineering issues.
- Multiple agents may work this codebase simultaneously — never use destructive git operations.
- All code is **private and confidential** — do not surface or transmit source beyond this session.
