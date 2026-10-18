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
"Companion Ubuntu" back in `backends/`, `core/` or `.github/`: the name is "Companion OS"; no retired distro name back outside `core/lib/retired-names.allow`: a retired target is restored from tag `pre-retire-multidistro-2026-10-17`, not re-described; and no block-letter banner art, which can spell one in a way a text grep cannot read; and **no tracked file that names an untracked one** (`core/lib/check-untracked-deps.sh`: check-repo and the unit tests run on the working tree, so a new script, fixture or payload file that was never `git add`ed passes them and is missing from the commit; `git add -N <path>` is enough for `git add -u` / `git commit -a` to take it). If it fails locally, don't push. The
other workflows (`build-companion-os-iso.yml`, `style-canon-lint.yml`) are manual-only
(`ci-local:gated` markers) — don't restore their triggers in a PR; that's a maintainer call.

Touching `backends/ubuntu/iso/scripts/md5sum-txt.sh` or the md5sum.txt part of `build-iso.sh` → the
`check-repo.sh` run above already includes `backends/ubuntu/iso/tests/md5sum-txt.sh` (with `xorriso` and GNU `dd` installed it
also builds a mini ISO; PR checks install `xorriso`). It also runs the Ubuntu 26.04 backend's host suites: `iso/tests/grub-live-menu-modules.sh`
(the live GRUB menu insmods only modules the signed GRUB has built in), `backends/ubuntu/lib/tests/{os-release-golden,install-rocm-driver,lact-release,shell-theme}.sh`,
`chroot/tests/customize-chroot-checks.sh`, `headless-package/tests/control-depends.sh` and `core/render/tests/gresource-provenance.sh`
(a suite that needs a tool the host lacks exits 2 and is reported, not failed). The ISO tests that need a container are **manual**: no
workflow runs them (`iso/tests/{boot-media-plymouth,plymouth-ground-render,placeholder-layer-modes,verify-logo-surfaces,verify-installer-base}.sh`,
`split-live-layer.sh` Part B, `chroot/tests/no-dracut-pin.sh`, `desktop-theme/tests/{plymouth-theme,about-logo-svg,visible-names,about-logo-no-renderer,start-icon-from-mark}.sh`,
`chroot/tests/render-preflight.sh`, `headless-package/tests/netplan-keeps-networkmanager.sh`, `core/lib/tests/divert-file.sh`), so before you push a change to
`core/lib/theme-lib.sh` (`ci_plymouth_recolor`), `brand_boot_media`, `brand_live_grub`, `verify-iso.sh`, the split library, the logo or visible-name steps, or
the dracut pin, run the ones that cover it in an `ubuntu:26.04` container (the commands are in each file's header; the table is in
`backends/ubuntu/iso/README.md`, "Script tests"). A new stock base ISO is a port, not a pin bump: see the comment next to `BASE_ISO_SHA256`
in `build-companion-os-iso.yml`.

Touching brand assets or the setup portal's logo/font → also run
`core/lib/check-brand-mirrors.sh` and `core/lib/vendor-brand.sh --check`.

## Where things live (post Phase 1a, `11634eb`)

Branches cut before the reorganization use the old paths. Map them:

| Old path | Now |
|---|---|
| `setup/headless/setup-device/opt/setup-backend/`, `usr/local/bin/`, `var/www/setup-portal/`, `etc/systemd/system/`, `etc/dnsmasq.d/` | `core/headless/payload/…` (shared by both editions) |
| `setup/headless/setup-device/DEBIAN/`, `setup/headless/build.sh` | `backends/ubuntu/headless-package/` |
| `setup/headless/setup-device/etc/netplan/` | `backends/ubuntu/headless-package/netplan/` |
| `pull-dev.sh`, CI-Hub install helpers | `core/lib/ci-hub.sh` |
| `scripts/*.sh`, `setup-fresh-ubuntu.sh`, `bootstrap-ci-os.sh` | `backends/ubuntu/provision/provision.sh` (tier-gated) + `backends/ubuntu/lib/` |
| `configs/scripts/`, Cubic/preseed tree | removed — don't resurrect |

Touching `backends/cachyos/`: run the no-Docker tests in `backends/cachyos/iso/tests` (check-repo.sh runs them); after an overlay, renderer, installer or `verify-iso.sh` change run the manual `iso/tests/verify-mini-iso.sh` (about 2 minutes, Docker + network); `build-iso.sh --stop-after validate` checks an overlay change against the real pinned upstream (about 2 minutes, Docker). A patch that touches a kernel, initrd, append or memtest line of a boot menu needs `# ci-os: allow-kernel-line-change`.

**Companion Stick** lives in `stick/`, a Rust Cargo workspace whose binary crate is
`crates/ci-stick`; see `docs/architecture/companion-stick.md`. Rust is first-class inside
`stick/` only. Never make `core/` or the
shell backends depend on it. Touching `stick/` → run
`(cd stick && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)`,
which is the `stick` job in PR checks. Touching `flash`/`slot`/`target`/`bootcfg`/`grubenv`,
`stick/scripts/` or `stick/tests/qemu/` → also run `stick/tests/qemu/run.sh` (the
`stick-qemu` job; TCG works without `/dev/kvm`, just slower). Device-safety rules in
`target.rs` are security-sensitive: keep them pure and fixture-tested, never add bypasses. Commit `stick/Cargo.lock`, never `stick/target/`. When
you change `manifest.rs` or `layout.rs`, update `stick/schema/bundle.schema.json` and the
example too; a test enforces this. `core/manifest/model-packs.yaml` is provisional, and its
`digest` fields stay `null` until they are resolved by tooling. Never hand-write digests.

A change to `core/headless/payload/` ships on **both** editions. When it adds a runtime
dependency (a new binary, e.g. `iptables`), add it to each place that installs the payload:
`backends/ubuntu/headless-package/DEBIAN/control`, `backends/cachyos/installer/modules/packages_online.conf` (Calamares installs the packages; `provision/stage-headless.sh` only copies files),
and `backends/arch/headless-setup/install.sh` (not a target and frozen, but the payload tests and the CachyOS ISO verifier read its `ARCH_DEPS` as the dependency oracle, so it needs an explicit decision).
Package names per distro: `core/manifest/role-map/apt.yaml` and `pacman.yaml`.

Adding a **new payload file**: the editions don't all copy the payload wholesale. Check each
one's explicit file lists — `REQUIRED_FILES` in `backends/ubuntu/headless-package/build.sh` and
the required-file list in the Arch `install.sh` (the oracle) — and add it wherever it has to be present. Also `backends/cachyos/provision/stage-headless.sh`: every payload file needs a placement rule there (an uncovered file stops it); `backends/cachyos/iso/tests/installer-stage.sh` is the parity test.

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
