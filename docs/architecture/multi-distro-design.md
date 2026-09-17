# CI-OS multi-distro architecture

CI-OS is moving from Ubuntu-only rebrand scripts to a monorepo that builds a themed,
ecosystem-provisioned Companion Intelligence appliance image across six distro targets:
Ubuntu, Linux Mint, Fedora Workstation, Arch Linux, Bazzite, and NixOS.

This supersedes two statements that used to be true and are no longer the goal:
`CI-OS/README.md`'s *"CI-OS is Companion Ubuntu... not a from-scratch or shipped OS"* and
*"there is no Nix, no build system to learn."*

## Why `core/` + `backends/<distro>/`, not six parallel copies

Two layers of "theming a Linux appliance" behave very differently across distros:

- **Theming primitives** — Plymouth's theme file format, GRUB2's `/etc/default/grub`, the
  token→color math that turns brand tokens into rendered artifacts — are shared across every
  traditional distro. These live in `core/render/`.
- **The delivery mechanism** — apt+chroot, dnf+kickstart, pacman+archiso,
  Containerfile+bootc image layering, declarative Nix modules — is fundamentally
  distro-specific and cannot be unified into one script. These live in `backends/<distro>/`.

Today's Ubuntu-only scripts already conflate the two (e.g. the old
`build-gdm-branding-gresource.sh` mixed reusable gresource-hacking logic with Ubuntu-specific
paths). The refactor separates them so the reusable half doesn't have to be reinvented per
distro.

## Directory layout

```
core/
  manifest/      # ecosystem.yaml — single source of truth for "what gets installed"
    role-map/    # apt.yaml, dnf.yaml, pacman.yaml, nix.yaml, bootc.yaml
  render/        # tokens + assets -> portable rendered artifacts (Plymouth, GRUB bg, icons, ...)
  lib/           # genuinely distro-portable bash helpers
  validate/      # portable half of theme validation
  headless/payload/   # captive-portal WiFi onboarding: Flask backend + static portal + hostapd/dnsmasq configs

backends/
  _mixins/{gnome-dconf,kde-plasma}/    # shared building blocks (Ubuntu + Fedora, optionally Arch)
  ubuntu/    {iso, chroot, provision, desktop-theme, lib, packages, headless-package}/
  mint/      {provision, desktop-theme, headless-package}/            # no ISO-build mode
  fedora/    {iso (kickstart/lorax), provision, desktop-theme, packages, headless-package}/
  arch/      {provision, desktop-theme, headless-package}/            # archiso deferred
  bazzite/   {image/Containerfile, image/build.just, modules/}/       # OCI image, not chroot
  nixos/     {flake.nix, modules/{branding.nix, ecosystem.nix, headless-setup.nix}}/
```

## The ecosystem manifest

`core/manifest/ecosystem.yaml` (schema: `ecosystem.schema.json`) is the single source of truth
for what gets installed — dev tools, the fixed 3-model Ollama/LLM set
(`nomic-embed-text`, `gemma3:1b`, `qwen3.6:27b`), and the CI-Hub deploy — tagged `core`
(auto-run), `extended` (opt-in), `hardware` (auto-detected, never flag-gated), or `reserved`
(documented but not implemented here — currently just CI-Server, which has no real
implementation in CI-OS and belongs to its own repo).

Investigation before this design found **six independently-drifted Ubuntu provisioning
entrypoints** doing overlapping-but-different versions of "install the ecosystem"
(`setup-fresh-ubuntu.sh`, an embedded first-boot heredoc in `customize-chroot.sh`, an
undocumented `ci-os-setup.sh`, `bootstrap-ci-os.sh`, `pull-dev.sh`, and an orphaned preseed
`late_command`), plus 5 of 9 files in the old `scripts/lib/` with zero callers. The manifest
plus one canonical `provision.sh` entrypoint (`--tier=core[,extended][,hardware]`) replaces all
of them. Bash backends resolve manifest roles through their `role-map/<pkgmgr>.yaml`; NixOS
consumes a `yq`-generated `ecosystem.generated.json` via `builtins.fromJSON` — the same
json-alongside-yaml pattern `vendor/brand/tokens/` already uses for `tokens.sh`/`tokens.json`.

CI-Hub (the Docker/Runtipi backend, `ci-os-hub` container, port 5002) is a first-class `core`
step, gated on registry auth + device pairing by design (a legitimate business requirement) but
invoked from one fixed place instead of a fragile disk-search. It was renamed in docs/UX from
being one of three things confusingly called "Hub" — the Electron GUI launcher app is now
"Companion Launcher"; the backend itself is "CI Hub Service" in user-facing text.

## Per-backend contract

Every `backends/<distro>/` implements: **(1)** manifest-consumer, **(2)** theme-render-consumer
(installs `core/render/*` outputs via its native mechanism), **(3)** identity-writer,
**(4)** a declared output mode (bootable image / idempotent provisioning script / theme-only
script / OCI image / Nix flake — not every backend needs every mode), **(5)** a validation
hook, **(6)** a CI lint/smoke test. Implementing only modes 2-3 (no image build) is fully
compliant, not a shortcut — CI-OS's own README already treats the Ubuntu ISO path as
"secondary, not the product path."

## Rollout

| Phase | Backend | Effort | Notes |
|---|---|---|---|
| 1 | Ubuntu | L (baseline) | Reference implementation; full refactor + close theming gaps + provisioning consolidation |
| 2 | Mint | S | Reuses Ubuntu's apt role-map; new work is Cinnamon + Slick-Greeter theming only. No ISO mode. |
| 3a | Fedora (provisioning+theming) | M | Reuses the GNOME-Shell/GDM-gresource pattern against Adwaita |
| 3b | Fedora ISO (kickstart/lorax) | L | Zero reuse from debootstrap/squashfs/xorriso; can slip independently |
| 4 | Arch | M | pacman role-map, GNOME theming; archiso deferred |
| 5 | Bazzite | L/XL | Containerfile + bootc image layering, zero bash-script reuse |
| 6 | NixOS | L | Declarative flake/modules; requires reversing CI-OS's former "no Nix" rule |

Deferred, tracked but not committed: Mint ISO-building, Arch archiso, Fedora kickstart/lorax
(can slip past 3a), Bazzite model-baking into the image (default: pull at first boot, not
baked in), Arch AUR-helper automation.

## Security note

An earlier audit of the provisioning scripts found and removed three checked-in credential
leaks (a live Cloudflare API token, a shared tunnel token, and a dev registry credential
fallback) — see the repo's commit history for the fix. `core/manifest/ecosystem.yaml`'s
`requires_secrets`/`requires_pairing` fields exist specifically so CI-Hub's credential
requirements stay documented and explicit rather than defaulting to something checked into
source again.
