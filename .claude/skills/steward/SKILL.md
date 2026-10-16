---
name: steward
description: CI-OS conventions for driving a PR to mergeable — validation to run before pushing, where code lives after the core/ + backends/ reorganization, what never gets committed, and how to handle stale branches. Read before acting on CI or review events on a CI-OS PR, or before porting an old branch.
---

# CI-OS PR steward

## Before every push

```bash
./core/lib/check-repo.sh
```

It is exactly what the `PR checks` workflow runs (bash -n, `shellcheck -S error`,
`py_compile`, yamllint, no tracked build artifacts, no retired product name such as "CI OS" or
"Companion Ubuntu" back in `backends/`, `core/` or `.github/`: the name is "Companion OS"; and no block-letter banner art, which can spell one in a way a text grep cannot read). If it fails locally, don't push. The
other workflows (`build-companion-os-iso.yml`, `style-canon-lint.yml`) are manual-only
(`ci-local:gated` markers) — don't restore their triggers in a PR; that's a maintainer call.

Touching `backends/ubuntu/iso/scripts/md5sum-txt.sh` or the md5sum.txt part of `build-iso.sh` → the
`check-repo.sh` run above already includes `backends/ubuntu/iso/tests/md5sum-txt.sh` (with `xorriso` and GNU `dd` installed it
also builds a mini ISO; PR checks install `xorriso`). The other ISO tests (`boot-media-plymouth.sh`,
`plymouth-ground-render.sh`, `desktop-theme/tests/plymouth-theme.sh`, `placeholder-layer-modes.sh`,
`verify-logo-surfaces.sh`) need a container and are **manual**: no workflow runs them, so before you push a change to
`core/lib/theme-lib.sh` (`ci_plymouth_recolor`), `brand_boot_media` or the logo steps, run the ones that cover it (the
commands are in each file's header; the table is in `backends/ubuntu/iso/README.md`, "Script tests").

Touching brand assets or the setup portal's logo/font → also run
`core/lib/check-brand-mirrors.sh` and `core/lib/vendor-brand.sh --check`.

## Where things live (post Phase 1a, `11634eb`)

Branches cut before the reorganization use the old paths. Map them:

| Old path | Now |
|---|---|
| `setup/headless/setup-device/opt/setup-backend/`, `usr/local/bin/`, `var/www/setup-portal/`, `etc/systemd/system/`, `etc/dnsmasq.d/` | `core/headless/payload/…` (shared by every backend) |
| `setup/headless/setup-device/DEBIAN/`, `setup/headless/build.sh` | `backends/ubuntu/headless-package/` (and `backends/mint/headless-package/`) |
| `setup/headless/setup-device/etc/netplan/` | `backends/ubuntu/headless-package/netplan/` |
| `pull-dev.sh`, CI-Hub install helpers | `core/lib/ci-hub.sh` |
| `scripts/*.sh`, `setup-fresh-ubuntu.sh`, `bootstrap-ci-os.sh` | `backends/ubuntu/provision/provision.sh` (tier-gated) + `backends/ubuntu/lib/` |
| `configs/scripts/`, Cubic/preseed tree | removed — don't resurrect |

Touching `backends/cachyos/`: run the no-Docker tests in `backends/cachyos/iso/tests` (check-repo.sh runs them); after an overlay, renderer, installer or `verify-iso.sh` change run the manual `iso/tests/verify-mini-iso.sh` (about 2 minutes, Docker + network); `build-iso.sh --stop-after validate` checks an overlay change against the real pinned upstream (about 2 minutes, Docker). A patch that touches a kernel, initrd, append or memtest line of a boot menu needs `# ci-os: allow-kernel-line-change`.

**Companion Stick** lives in `stick/`, a Rust Cargo workspace whose binary crate is
`crates/ci-stick`; see `docs/architecture/companion-stick.md`. Rust is first-class inside
`stick/` only, the same way Nix is inside `backends/nixos/`. Never make `core/` or the
shell backends depend on it. Touching `stick/` → run
`(cd stick && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)`,
which is the `stick` job in PR checks. Touching `flash`/`slot`/`target`/`bootcfg`/`grubenv`,
`stick/scripts/` or `stick/tests/qemu/` → also run `stick/tests/qemu/run.sh` (the
`stick-qemu` job; TCG works without `/dev/kvm`, just slower). Device-safety rules in
`target.rs` are security-sensitive: keep them pure and fixture-tested, never add bypasses. Commit `stick/Cargo.lock`, never `stick/target/`. When
you change `manifest.rs` or `layout.rs`, update `stick/schema/bundle.schema.json` and the
example too; a test enforces this. `core/manifest/model-packs.yaml` is provisional, and its
`digest` fields stay `null` until they are resolved by tooling. Never hand-write digests.

A change to `core/headless/payload/` ships on **every** backend. When it adds a runtime
dependency (a new binary, e.g. `iptables`), add it to each backend that installs the payload:
`backends/{ubuntu,mint}/headless-package/DEBIAN/control`, `backends/fedora/headless-setup/install.sh`,
`backends/arch/headless-setup/install.sh`, `backends/cachyos/installer/modules/packages_online.conf` (Calamares installs the packages; `provision/stage-headless.sh` only copies files), `backends/nixos/modules/headless-setup.nix`.
Package names per distro: `core/manifest/role-map/*.yaml`. (Bazzite deliberately doesn't ship
the captive portal — see the end of its `Containerfile`.)

Adding a **new payload file**: the backends don't all copy the payload wholesale. Check each
one's explicit file lists — `REQUIRED_FILES` in `backends/ubuntu/headless-package/build.sh`,
the required-file list in the Fedora/Arch `install.sh`, and the per-file `install` lines in
the NixOS module (`ciOsHeadlessBin`) — and add it wherever it has to be present. Also `backends/cachyos/provision/stage-headless.sh`: every payload file needs a placement rule there (an uncovered file stops it); `backends/cachyos/iso/tests/installer-stage.sh` is the parity test.

## Never commit

- Build outputs: `*.deb`, `*.iso`, `*.rpm`, `.pkgroot/` — `.gitignore` excludes them and the
  check fails on force-adds.
- Secrets, device keys, tunnel tokens, `env.*` files with real values — templates only.
- "stashed changes" / WIP commits on a branch meant for review.

## Stale branches

A branch whose merge-base predates `11634eb` doesn't merge cleanly — conflicts are mostly
old-vs-new file locations, not logic. Don't hand-resolve 20 location conflicts. Instead:

1. `git log --oneline --no-merges origin/main..<branch>` — only these commits are unported.
2. Re-implement their intent on a fresh branch off `main` at the new paths, preserving later
   hardening on `main` (e.g. `setup_service.py`'s CSPRNG pairing code, the POST registration
   callback, stored device key).
3. Link the original PR; close it only with the author's/maintainer's say-so.

## Security-sensitive areas (need a human reviewer, not just green CI)

- `core/headless/payload/opt/setup-backend/setup_service.py` — the pairing/registration flow
  runs on an open setup hotspot before the device is claimed.
- `core/headless/payload/dnsmasq.d/`, hostapd, and any iptables/NAT rule — what an
  unauthenticated client on the setup AP can reach.
- Anything that writes to `/etc/sudoers*`, systemd units running as root, or tunnel config.

## Merge vs rebase

Someone else's branch: merge `main` in, never rebase or force-push. A branch you created:
either is fine; prefer a merge once reviewers have commented.
