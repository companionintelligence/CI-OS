# CI-OS design: a shared core and one backend per edition

> Private & Confidential. Property of Lifescope Inc. Do not distribute.
> The file name is historical: scripts, comments and documents all over the tree cite `docs/architecture/multi-distro-design.md`
> (`git grep multi-distro-design` lists them), so the path stays. The design it describes is no longer "multi-distro".
> Last checked against the tree on 2026-10-18.

CI-OS builds and provisions Companion OS, the Companion Intelligence appliance operating system, for exactly two supported targets:
Companion OS on Ubuntu 26.04.1 LTS and Companion OS on CachyOS (Plasma edition). The policy, the capability matrix and the
evidence tags are in [`supported-targets.md`](supported-targets.md); this page is about how the repository is built to serve them.

Evidence tags are the ones defined there: **[V]** verified, **[I]** implemented, not proven end to end, **[N]** not implemented.

## 1. Retirement notice

On 2026-10-17 the owner decided to support only Ubuntu 26.04 and CachyOS. Linux Mint, Fedora, Bazzite and NixOS were retired and
their backends removed (commit `6e7b0b5`; restore tag `pre-retire-multidistro-2026-10-17`); Ubuntu 24.04 was retired by the
26.04.1 port. The earlier text of this page described seven targets; it is kept in git history under that tag. What is still
true of it, and what frozen code comments cite by name, is kept below: the Ubuntu gresource mechanic (section 5), the CachyOS
backend (section 6), the Arch provisioning engine with its findings (section 7), the ecosystem manifest (section 9) and the
rollout history (section 11).

Restore a retired backend with `git checkout pre-retire-multidistro-2026-10-17 -- backends/<name>`; the full recipe, including
the case where the tag is not in your clone, is in [`supported-targets.md`](supported-targets.md#7-retired-targets-and-the-restore-recipe).

This page supersedes two statements that were true and are no longer the goal: the old README's claim that CI-OS is "Companion
Ubuntu ... not a from-scratch or shipped OS", and its claim that "there is no Nix, no build system to learn". The repository now
builds shipped images, and the build systems are `backends/ubuntu/iso/scripts/build-iso.sh` and
`backends/cachyos/iso/scripts/build-iso.sh`.

## 2. Why `core/` plus `backends/<name>/`

Two layers of "theming and provisioning a Linux appliance" behave differently from one edition to the next:

* **Primitives** are shared. Plymouth's theme file format, GRUB's `/etc/default/grub`, the token to colour math that turns the
  brand tokens into rendered artefacts, the manifest of what gets installed, the headless setup payload, the CI-Hub deploy. These
  live in `core/`. Theming is **colours-only**: a script reads `CI_*` token variables from `vendor/brand/tokens/tokens.sh` and
  renders the same GRUB background, Plymouth palette and MOTD for every backend; a colour is never a literal in a backend.
* **The delivery mechanism** is not shared. Ubuntu remasters the layers of the stock desktop ISO and customises them in a chroot
  with apt. CachyOS applies an overlay to a pinned archiso profile in a container and provisions the installed system at install
  time and on first boot. These live in `backends/<name>/` and cannot be unified into one script.

## 3. Directory layout

```
core/
  manifest/        ecosystem.yaml (what gets installed), role-map/{apt,pacman}.yaml, model-packs.yaml (+ lock), tier-b-pins.env, licenses.yaml
  render/          tokens + assets -> portable artefacts: GRUB background, Plymouth inputs, MOTD, mark PNGs, the GNOME Shell gresource
  lib/             distro-portable bash: theme-lib.sh, grub-merge.sh, gpu-detect.sh, ci-os-models.sh, ci-hub.sh, vendor-brand.sh,
                   check-brand-mirrors.sh, check-repo.sh, check-untracked-deps.sh, retired-names.allow
  headless/        payload/ (setup backend, portal, hostapd/dnsmasq/nginx config, units), ci_setup/ (tested library), tests/

backends/
  _mixins/{gnome-dconf,kde-plasma}/   shared building blocks; the GNOME dconf steps serve Ubuntu, the Plasma colour scheme serves CachyOS
  ubuntu/    {iso, chroot, provision, desktop-theme, lib, packages, headless-package}/      Companion OS on Ubuntu 26.04.1
  cachyos/   {iso, installer, provision}/ + upstream.lock, compat-libs.lock, NOTICE          Companion OS on CachyOS
  arch/      {provision, desktop-theme, headless-setup}/                                     NOT a target: the engine under CachyOS, frozen

stick/       Rust workspace: ci-stick (bundle lock, verify, flash, slots, model packs). Serves both editions; Ubuntu boots from it.
vendor/brand/   the pinned brand bundle (ci-brand 1.0.0): tokens, logos, Manrope font
```

`stick/` is deliberately not depended on by `core/` or by any shell backend. Rust is first-class inside `stick/` only.

## 4. The Ubuntu backend

**Execution model.** Ubuntu is a remaster, not an install-time provision. `build-iso.sh` extracts the stock Ubuntu 26.04.1 Desktop
ISO, merges its three squashfs layers into one rootfs, runs `backends/ubuntu/chroot/customize-chroot.sh` on it, splits the result
back into an **installer base layer** (what the installer copies to the disk) and a **live-only layer**, brands the boot media and
repacks a bootable ISO with xorriso, keeping BIOS, UEFI and Secure Boot from the base. It does not use debootstrap. The same
theming runs on a machine you already have through `desktop-theme/apply-ci-os-desktop.sh`, and the same provisioning through
`provision/provision.sh`; a clean ISO install ends up identical to running both by hand.

| Part | Path | Notes |
|---|---|---|
| ISO build, verify, tests | `backends/ubuntu/iso/` | [`backends/ubuntu/iso/README.md`](../../backends/ubuntu/iso/README.md) is the script reference |
| Customisation | `backends/ubuntu/chroot/` | identity, telemetry removal, branding, Docker, the optional tools (pinned), the one-click installer, first-boot units |
| Provisioning | `backends/ubuntu/provision/` | `provision.sh --tier=core[,extended][,hardware]`, `bootstrap-ci-os.sh`, `install-models.sh` |
| Desktop theme | `backends/ubuntu/desktop-theme/` | fixed order: plymouth, grub, dconf, terminal, wallpaper, session, start-icon, about-logo, os-release, names, motd |
| Helpers | `backends/ubuntu/lib/` | os-release writer, ROCm and LACT installers, telemetry removal, Strix Halo boot parameters |
| Packages | `backends/ubuntu/packages/ci-os-branding/` | the GNOME Shell theme `.deb` (see section 5) |
| Headless package | `backends/ubuntu/headless-package/` | `build.sh` assembles the `setup-device` `.deb` from `core/headless/payload/` and the apt-specific control scripts and netplan file |

Why the root filesystem is split, and which tests prove it: [`ubuntu-iso-layers.md`](ubuntu-iso-layers.md). What changed from
24.04 to 26.04.1 and why: [`ubuntu-2604-port-notes.md`](ubuntu-2604-port-notes.md). One-click install: [`one-click-install.md`](one-click-install.md).

## 5. GNOME Shell and GDM gresource rebranding

`core/render/render-gnome-shell-gresource.sh` is the generic mechanic behind rebranding a compiled GNOME Shell theme: extract a
theme's `.gresource`, swap widget and logo SVG assets by resource file name, remap accent-colour hex literals through a
caller-supplied Perl substitution file, optionally audit the recompiled CSS for regressions, then recompile with
`glib-compile-resources`. It used to be Yaru-hardcoded logic inside `build-gdm-branding-gresource.sh`; that script is now a thin
caller that exports the Yaru-specific data and `exec`s into the generic script:

* `THEME_NAME=Yaru`;
* `COLOR_MAP_FILE` pointing at `yaru-color-map.pl`: a ~30-entry orange to teal **luminance ramp** between two anchor tokens
  (`CI_DARK_PRIMARY` and `CI_LIGHT_PRIMARY`). The intermediate values are hand-tuned, not a 1:1 token mapping;
* `AUDIT_PATTERNS_FILE` pointing at `yaru-audit-patterns.txt`: `grep -E` regression guards for pre-rebrand Yaru and Ubuntu colours
  (comment lines use a `## ` prefix, because the patterns are hex colours that start with a bare `#`).

**Ubuntu is this script's only caller**, and the generalisation is kept for a future backend whose distribution ships a separate,
add-alongside GNOME Shell theme package, the way Yaru is one. It is not a building block for every GNOME-based backend: a
distribution that compiles the shell theme into the `gnome-shell` package itself (Arch is one, see section 7) cannot use it,
because overwriting the file is undone by the next package update.

**Provenance.** The tracked blob `backends/ubuntu/packages/ci-os-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource`
is built from the Yaru theme of Ubuntu 26.04.1 (`yaru-theme-gnome-shell 26.04.5.1ubuntu`), not from whatever the build host has.
The script refuses a source that is not Ubuntu 26.04 with a 26.04 Yaru package, prints a `[PROVENANCE]` block, and builds the same
bytes every time; `backends/ubuntu/packages/PROVENANCE-gnome-shell-theme.txt` records the input and output hashes, and
`core/render/tests/gresource-provenance.sh` (run by `check-repo.sh` where the glib tools exist) pins the behaviour **[V]**.

## 6. The CachyOS backend

```
backends/cachyos/
  upstream.lock     every pin: upstream commit and fallback, builder image digest, CachyOS key fingerprint, mirrorlist, edition identity
  compat-libs.lock  the older-generation libraries the installer still needs (Arch Linux Archive, sha256), with a review date
  iso/              scripts/build-iso.sh (host: only Docker), in-container build and overlay engine, verify-iso.sh; docker/; overlay/; tests/
  installer/        Calamares overlay: settings, module configs, branding, guards, scripts
  provision/        first-boot wrapper around backends/arch/provision/provision.sh, systemd units, setup-portal stager
```

A live and installer ISO of Companion OS based on CachyOS, and the only archiso-based backend. It does not write an Arch-native
archiso profile (that stays deferred, section 11): it consumes a **pinned upstream profile** (CachyOS-Live-ISO: KDE Plasma,
`plasma-login-manager`, the online Calamares installer), applies an **overlay** (`files/`, `patches/`, `packages.add|remove`,
`profiledef.append.sh`) to a throw-away copy of it and runs the stock `mkarchiso` in a privileged amd64 container. The host
needs only Docker. Upstream is never edited.

* **Three layers**, because the CachyOS installer builds the target from the network and does not copy the live image: the live
  image (identity, menus, launcher), Calamares (package list, payload staging, unit enabling, identity carry-over) and first boot
  (`backends/arch/provision/provision.sh` behind a wrapper).
* **Identity.** `NAME="Companion OS"`; `ID=cachyos` and `ID_LIKE=arch` stay, because CI-Hub string-matches `ID_LIKE=arch`; a
  later-sorting pacman hook rewrites the whole `os-release` after `cachyos-hooks`' own hook.
* **Reuse.** The Arch `provision.sh` behind a thin wrapper, `core/headless/payload` through its own stager, `core/render/*`,
  `vendor/brand`. Nothing in `backends/arch/` is edited (decision D8).
* **Rolling-release drift.** The package set is not pinned. A skew between two repositories (installer built against boost 1.91, `[extra]` at
  1.92 since 2026-08-13) made the installer fail to start on the first booted ISO that launched it (2026-10-18); a pinned, signature-checked
  compatibility library and a build-time gate now guard it.
  See `backends/cachyos/README.md` and the incident write-up in [`cachyos-backend.md`](cachyos-backend.md).
* **Limits.** Online install only; no Secure Boot; the Companion Stick cannot boot it (casper is hard-coded in
  `stick/crates/ci-stick/src/bootcfg.rs:44-45,188`); the live profile is baseline x86-64 (the `cachyos-v3` repositories fail under
  Rosetta).
* **Status.** Built five times **[V]**; the static verifier passed on ISO #2 with 187 checks **[V]**. ISO #4 and ISO #5 each ran from a fresh boot
  through the Calamares online install, the first boot of the installed system and first-boot provisioning in QEMU **[V]**; the defects the ISO #4
  run found were fixed in `552063f` and are seen working on ISO #5 **[V]** (first boot 21 min 49 s, status 0, no "degraded"). Open: the keyring step's
  30 second limit (KI-20, fix in the working tree **[I]**) and two installer highlight gaps (KI-09). No run on real hardware is recorded **[N]**.
  [`test-evidence.md`](test-evidence.md) owns the status of every run.

## 7. The Arch provisioning engine (frozen, not a target)

`backends/arch/` is the pacman provisioning engine that the CachyOS edition runs on first boot. It offers users no entry point,
and it is frozen: change it only on an explicit decision. Its code comments cite this page for the findings below, so they stay.

**Shape.** `provision/provision.sh` is a genuine pacman implementation with the tier gating and function-per-tool structure of the
Ubuntu script, not a wrapper. It runs one `pacman -Syu` up front and then `pacman -S --needed` per tool, because a scattered
`pacman -Sy` is Arch's documented "partial upgrade" failure mode. Every daemon-installing function calls an explicit
`systemctl enable --now`, since pacman packages never start services themselves. `headless-setup/install.sh` is a plain installer
for `core/headless/payload/`; the CachyOS edition does not run it (it is not chroot-safe) but the payload tests and the CachyOS
ISO verifier read its `ARCH_DEPS` as the dependency oracle.

**Why a plain installer and not a PKGBUILD.** A real Arch package needs a PKGBUILD (`pkgname`, `pkgver`, `depends`, `source`,
`sha256sums`, a `package()` function installing into `$pkgdir`) plus a `.install` file, and install, upgrade and remove cycles
that could not be tested without a live Arch box when the backend was written. Pacman's differently-named-function `.install`
model is safer than RPM's numeric-`$1` scriptlet overload in principle; it was still deferred.

**Package findings** (`core/manifest/role-map/pacman.yaml` is the data, documentation-only like `apt.yaml`):

* `docker`, `github-cli`, `cloudflared`, `tailscale` and `chromium` are official `extra` packages needing no third-party repository;
  `rocm-hip-sdk` and `lact` are also official `extra` packages.
* `gunicorn` is `gunicorn`, **not** `python-gunicorn`: a correction to the assumption that Arch prefixes every Python package.
* **Arch AUR-helper automation (manual/documented first)** is a deliberate deferral. VS Code (Microsoft's build) exists on Arch only
  as the AUR package `visual-studio-code-bin`; Companion Launcher has no Arch build, official or AUR. `provision.sh` never invokes
  an AUR helper (yay, paru) and never assumes one is installed: `install_vscode()` and `install_companion_launcher()` log a clear
  message and return 0. The native `code` package (Code - OSS, no Microsoft branding or Marketplace) is a **different product** and
  is not silently substituted. The role map marks such rows `aur_deferred`.
* The hardware tier installs `rocm-hip-sdk` and LACT **without detecting a GPU**. That is why the CachyOS wrapper defaults to
  `--tier=core` and a machine that needs the rest asks for it with `sudo ci-os-setup --tier=core,hardware`.
* `install_rocm_driver_arch()` adds the desktop and `ci` users to the `render` and `video` groups, a step the Ubuntu installer had
  and the first Arch pass missed.

**GNOME theming findings** (the Arch `desktop-theme/` is unused under CachyOS, which brands itself through its overlay; the
findings stand because frozen scripts cite them):

* Arch does not use the gresource mechanic of section 5. Its `gnome-shell` package compiles the theme into
  `gnome-shell-theme.gresource` with no add-alongside theme package and no separate `gdm.css`; that is upstream GNOME's own
  packaging since GNOME 3.16, not a distribution patch. Arch's step uses the GNOME 47+ `org.gnome.desktop.interface accent-color`
  setting (a locked nine-value enum) for the session and for GDM's dconf profile instead. The trade-off: the nearest named colour,
  not an exact hex match, and no hook for GDM's logo assets.
* **The `/etc/dconf/profile/gdm` finding.** On some distributions that file ships with the `gdm` package and a guard that only
  checks for it is sufficient. It does **not** hold on Arch: the ArchWiki states the file is "no longer shipped upstream" and "must
  be created manually". `28-gdm-accent-branding.sh` therefore creates it, when missing, with the ArchWiki-documented
  `user-db:user`, `system-db:gdm`, `file-db:/usr/share/gdm/greeter-dconf-defaults` content before writing the `gdm.d` override.
  A step-order bug found in review: the profile must exist **before** the `dconf` step runs, because
  `backends/_mixins/gnome-dconf/20-dconf-system.sh` gates its own GDM fragment (background colours, remote-desktop keys) on the
  profile existing. `apply-ci-os-desktop.sh` now calls `28-gdm-accent-branding.sh --ensure-gdm-profile-only` first.
* **GRUB or systemd-boot.** Arch has no installer flavour that guarantees GRUB, and a large and normal share of Arch systems boot
  systemd-boot. `15-grub-theme.sh` is therefore a detect-and-delegate wrapper (`bootctl` and `/boot/loader/loader.conf`, or
  `/etc/default/grub` and `grub-mkconfig`): it execs into Ubuntu's portable GRUB2 logic or skips cleanly with a log line, where the
  Ubuntu script would fail hard on a missing `/etc/default/grub`. `80-validate-ci-theme.sh` treats systemd-boot as a pass.
* The GNOME mixin steps are GNOME-Shell specific, which is what the Arch dispatcher targeted by design.

**Known gaps** stated in the code's own headers: whether Arch's login shell renders `/etc/update-motd.d/*`; the nginx
`default_server` collision fix and NetworkManager enable in `install.sh`; Companion Launcher and Microsoft VS Code stubs.

**Evidence.** The provisioner ran on an installed CachyOS system in QEMU (ISO #4): it pulled the three models, ran its remaining
core steps (cloudflared, corepack and pnpm, Tailscale), skipped the CI-Hub deploy for want of credentials, and ended "degraded"
because of a defect in the CachyOS wrapper that `552063f` fixes **[V]**. On ISO #5, with that fix, the same run ended with status 0 and no
"degraded" **[V]**. The hardware tier and `--step=ci-hub` with credentials
were not exercised **[I]**.

## 8. Naming: three things called "Hub"

Before the manifest existed, three things were called "Hub". User-facing text now uses:

| Name | What it is |
|---|---|
| **CI Hub Service** | the Docker backend (container `ci-os-hub`, port 5002), deployed by `core/lib/ci-hub.sh` and gated on registry credentials and device pairing |
| **Companion Launcher** | the desktop GUI app (Debian package and binary `companion-hub`; formerly "Companion Hub Desktop"). `setup_service.py` detects it by process name to decide whether pairing is required |
| **Companion Hub (browser)** | the desktop entry from the setup payload (`ci-os-hub.desktop`) that opens a browser tab to the service |

`core/lib/ci-hub.sh` lives in `core/`, not in a backend, because once Docker is present everything in it is docker-compose with no
package-manager assumption. The Ubuntu `deploy_ci_hub()` and the headless setup flow both call it. Its inputs, ports, security notes and the
runbook are in [`../guides/ci-hub-deploy.md`](../guides/ci-hub-deploy.md).

## 9. The ecosystem manifest

`core/manifest/ecosystem.yaml` (schema: `ecosystem.schema.json`) is the single source of truth for what gets installed: dev tools,
the fixed three-model Ollama set (`nomic-embed-text`, `gemma3:1b`, `qwen3.6:27b`) and the CI-Hub deploy. Each entry is tagged:

| Tier | Meaning |
|---|---|
| `core` | runs on first boot and by default when a person runs `provision.sh` with no flags |
| `extended` | opt-in developer and workstation tooling (Homebrew, VS Code, Chromium, Companion Launcher) |
| `hardware` | auto-detected and never flag-gated (ROCm, LACT, Strix Halo tuning); gated by `core/lib/gpu-detect.sh` |
| `reserved` | documented but not implemented here; today only CI-Server, which belongs to its own repository |

An investigation before the manifest found **six independently drifted Ubuntu provisioning entrypoints** doing overlapping versions
of "install the ecosystem" (`setup-fresh-ubuntu.sh`, a first-boot heredoc in `customize-chroot.sh`, an undocumented
`ci-os-setup.sh`, `bootstrap-ci-os.sh`, `pull-dev.sh`, an orphaned preseed `late_command`) and five of nine files in the old
`scripts/lib/` with no caller. The manifest plus one `provision.sh --tier=core[,extended][,hardware]` replaced them. A backend
resolves manifest roles through `core/manifest/role-map/<package manager>.yaml` (`apt.yaml`, `pacman.yaml`), documentation-only
and not parsed at run time.

Where a tool is baked into the Ubuntu image (`baked_in_iso: true`: Docker, `gh`, `cloudflared`, Tailscale, Ollama, the launcher),
`provision.sh` finds it installed and skips it. Third-party keys and downloads are pinned in `core/manifest/tier-b-pins.env`
([`tier-b-tools.md`](tier-b-tools.md)). The models are never baked; they are pulled at first boot, gated by the hardware-fit
rule in `core/lib/gpu-detect.sh` (`ci_os_model_gate_allows`). There is no disk-space check in that gate yet
([`known-issues-and-decisions.md`](known-issues-and-decisions.md)).

CI Hub Service is a first-class `core` step, gated on registry authentication and device pairing by design (a legitimate business
requirement) and invoked from one fixed place instead of a disk search.

## 10. Per-backend contract

Every `backends/<name>/` that is a supported target implements the first six of these, which are the design of the repository, and the
last four, which the two editions both needed and a new edition would otherwise find out about late. The steward skill treats item 7 as
mandatory for any change of the shared payload.

1. **A manifest consumer.** Resolves `core/manifest/ecosystem.yaml` through a role map.
2. **A theme-render consumer.** Installs the `core/render/*` outputs through its native mechanism.
3. **An identity writer.** `os-release` and the user-visible name "Companion OS".
4. **A declared output mode.** A bootable image built from an upstream image, or an idempotent provisioning script, or a
   theme-only script. Implementing only modes 2 and 3 is compliant.
5. **A validation hook.** A `verify-iso.sh` or `80-validate-ci-theme.sh` whose checks can fail, with a self-test that feeds each check a
   good and a broken fixture.
6. **A lint or smoke test** wired into `core/lib/check-repo.sh`.
7. **The headless setup payload, wrapped for this target.** `core/headless/payload/` is shared; the packaging is not. Ubuntu wraps it as the
   `setup-device` `.deb` (`backends/ubuntu/headless-package/`: `DEBIAN/control` for runtime dependencies, `build.sh` with `REQUIRED_FILES` for
   every payload file); CachyOS installs the packages through `installer/modules/packages_online.conf` and copies the files with
   `provision/stage-headless.sh`, which needs a placement rule for every payload file (an uncovered file stops it). A new target registers its
   installer in `core/headless/tests/payload/test_static.py` (`BootEnablingTests.installers()`, the dependency and executable-bit tests) and in
   the mutation check (`core/headless/tests/payload/mutation-check.py`); the tests assert that no installer enables the access-point stack at
   boot and that the dependencies `iw`, `iproute2` and `rfkill` are declared. A payload change ships on every target.
8. **First-boot provisioning.** A unit that runs the provisioner until it has succeeded once (at every boot and on a timer while pending, with
   a bounded number of failed automatic runs), a done marker written only on success (on the Plasma edition only when the models are on the machine), a status file for "degraded", and a
   re-run command (`sudo ci-os-setup`). The unit must not hold the boot targets (the ISO #4 defect: `Type=oneshot` held `graphical.target` for
   16 min 27 s). See [`cachyos-backend.md`](cachyos-backend.md#the-three-provisioning-layers) and
   [`one-click-install.md`](one-click-install.md) for the two shapes.
9. **The model gate.** Models are never baked into an image. A target pulls them through the shared gate `ci_os_model_gate_allows`
   (`core/lib/gpu-detect.sh`), which needs `core/manifest/model-packs.yaml` on the installed machine to have data: stage it (KI-01, where the
   CachyOS edition does not), and know that the gate checks RAM and GPU memory and **not disk space**.
10. **A Stick and Secure Boot stance, written down.** Whether the image can be carried by `ci-stick` (Ubuntu: yes, casper and Canonical's signed
    chain; CachyOS: no, the boot menu is built for casper, `stick/crates/ci-stick/src/bootcfg.rs`) and whether it boots with Secure Boot on
    (Ubuntu: inherited, `verify-iso.sh` compares the binaries; CachyOS: no, unsigned GRUB and kernels). A target that says yes to the Stick adds a
    boot profile to `bootcfg.rs` and a `boot_profile` field to the bundle schema, and an archiso-shaped boot image for `stick/tests/qemu/`.

Evidence for a new target goes into [`test-evidence.md`](test-evidence.md) with the tags, its text records into
[`../evidence/`](../evidence/README.md), and the new rows into the capability matrix of [`supported-targets.md`](supported-targets.md).

## 11. Rollout history

| Phase | Backend | Outcome |
|---|---|---|
| 1 | Ubuntu | Reference implementation; refactor, provisioning consolidation. **Supported**, ported to 26.04.1 on 2026-10-17 and 2026-10-18. |
| 2 | Linux Mint | Thin wrapper over the Ubuntu backend. Retired (tag `pre-retire-multidistro-2026-10-17`). |
| 3a | Fedora provisioning and theming | dnf reimplementation; showed that the gresource mechanic does not apply to a distribution that compiles the shell theme in. Retired (tag `pre-retire-multidistro-2026-10-17`). |
| 3b | Fedora ISO | Never built. |
| 4 | Arch | pacman reimplementation. **Kept as the frozen engine under CachyOS**, not a target. |
| 5 | Bazzite | OCI image layering with bootc. Retired (tag `pre-retire-multidistro-2026-10-17`). |
| 6 | NixOS | A flake of importable modules; never evaluated with a real Nix toolchain. Retired (tag `pre-retire-multidistro-2026-10-17`). |
| 7 | CachyOS | Pinned CachyOS-Live-ISO profile plus a Companion overlay. **Supported.** |
| 8 | Consolidation (2026-10-17) | Owner decision: only Ubuntu 26.04 and CachyOS; four backends removed; Ubuntu 24.04 retired. |

**Deferred, tracked, not committed:**

* Arch archiso profile-building (out of scope for phase 4: no default desktop, no shared code with the Ubuntu remaster, low payoff;
  phase 7 builds from a pinned CachyOS profile instead).
* **Arch AUR-helper automation (manual/documented first).** `install_vscode()` and `install_companion_launcher()` stay stubs
  rather than invoke yay or paru.
* An offline CachyOS installer (`unpackfs` of the live squashfs), a GNOME edition of CachyOS, and an archiso boot profile for the
  Companion Stick.
* Secure Boot for the CachyOS edition (`sbctl` user keys on the installed system).

## 12. Security note

An earlier audit of the provisioning scripts found and removed three checked-in credential leaks (a live Cloudflare API token, a
shared tunnel token and a development registry credential fallback); see the commit history. `core/manifest/ecosystem.yaml`'s
`requires_secrets` and `requires_pairing` fields exist so that CI-Hub's credential requirements stay documented and explicit
rather than defaulting to something checked into source again. Credentials named by the repository review of 2026-10-12 are still
to be rotated; that is tracked in [`known-issues-and-decisions.md`](known-issues-and-decisions.md), and no document in this
repository copies a credential value.
