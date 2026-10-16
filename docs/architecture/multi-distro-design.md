# CI-OS multi-distro architecture

CI-OS is moving from Ubuntu-only rebrand scripts to a monorepo that builds a themed,
ecosystem-provisioned Companion Intelligence appliance image across seven targets:
Ubuntu, Linux Mint, Fedora Workstation, Arch Linux, Bazzite, NixOS, and a CachyOS-based live and installer ISO.

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

This split has since been carried out for real for the GNOME Shell/GDM rebranding mechanic —
see [GNOME Shell / GDM gresource rebranding](#gnome-shell--gdm-gresource-rebranding) below. It
was built anticipating Fedora's Adwaita-based branding (Phase 3a) would reuse it with different
data inputs; research for that phase found Fedora's GNOME Shell theme isn't structured the way
Yaru is, so Fedora ended up using a different (and simpler) supported mechanism instead — see
that section for what Fedora does and why.

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
  mint/      {provision, desktop-theme, headless-package}/            # no ISO-build mode — implemented (Phase 2)
  fedora/    {provision, desktop-theme, headless-setup}/               # no ISO-build mode yet — implemented (Phase 3a);
                                                                        # iso/ (kickstart/lorax) is Phase 3b, deferred
  arch/      {provision, desktop-theme, headless-setup}/               # no ISO-build mode — implemented (Phase 4);
                                                                        # archiso profile-building deferred (see below)
  cachyos/   {iso, installer, provision}/                             # Phase 7: pinned CachyOS-Live-ISO profile + overlay; archiso ISO build,
                                                                        # online Calamares installer; implemented, not yet booted or installed
  bazzite/   {image/Containerfile, image/build.just, modules/}/       # OCI image, not chroot
  nixos/     {flake.nix, modules/{branding.nix, ecosystem.nix, headless-setup.nix}}/
```

### `backends/mint/` (Phase 2, implemented)

```
backends/mint/
  provision/
    provision.sh                 # thin wrapper: exec's backends/ubuntu/provision/provision.sh
                                  # unchanged (Mint 22.x shares Ubuntu Noble's apt role-map)
  desktop-theme/
    cinnamon-defaults.inc.sh     # shared Cinnamon values (theme/icon selection, favorites,
                                  # panel, wallpaper) — the Mint analog of gnome-defaults.inc.sh;
                                  # not shared with the GNOME mixin, deliberately
    20-cinnamon-dconf.sh         # system dconf defaults + live gsettings apply (folded — see
                                  # its header for why this isn't split into a 25- file like
                                  # Ubuntu's), plus wallpaper install
    30-slick-greeter.sh          # renders the CI mark as a transparent PNG, writes
                                  # /etc/lightdm/slick-greeter.conf + a lightdm.conf.d drop-in
    apply-ci-os-desktop.sh       # dispatcher: reuses Ubuntu's 10-plymouth.sh/15-grub-theme.sh
                                  # and core/render/render-motd.sh directly by path; --only/
                                  # --validate only, no --wizard yet
    80-validate-ci-theme.sh      # Cinnamon/slick-greeter checks; Plymouth/GRUB/brand-asset
                                  # checks kept identical to Ubuntu's
  headless-package/
    build.sh, DEBIAN/{control,postinst,prerm,postrm}   # same payload as Ubuntu's, no netplan
                                                        # config (see build.sh's header)
```

Deliberately NOT ported from Ubuntu in this phase (see `apply-ci-os-desktop.sh`'s header
comment for the full reasoning on each): GNOME Terminal theming (lives under the excluded
`backends/_mixins/gnome-dconf/`), the Yaru-specific start-icon swap, and the `os-release`
`ID=ubuntu` rewrite (Mint keeps its own `ID=linuxmint` identity; its apt role-map resolution
doesn't need the rewrite since Mint's stock `os-release` already carries `UBUNTU_CODENAME`).

### `backends/fedora/` (Phase 3a, implemented)

```
backends/fedora/
  provision/
    provision.sh                 # genuine dnf reimplementation of Ubuntu's provision.sh —
                                  # NOT a thin wrapper (dnf syntax/package names differ too
                                  # much from apt); same --tier=/--step=ci-hub flags, same
                                  # tier_requested()/function-per-tool structure
  desktop-theme/
    gnome-defaults-fedora-overrides.inc.sh  # Adwaita theme/icon/cursor + accent-color/
                                             # color-scheme selection (the Fedora analog of
                                             # gnome-defaults.inc.sh — not sourced-after-mixin,
                                             # see the header for why that approach doesn't
                                             # work against 20-dconf-system.sh's own re-source)
    28-gdm-accent-branding.sh    # sets org.gnome.desktop.interface accent-color for the live
                                  # session + GDM's dconf profile — see the gresource-rebranding
                                  # note below for why this isn't a gresource-based step
    apply-ci-os-desktop.sh       # dispatcher: reuses Ubuntu's 10-plymouth.sh/15-grub-theme.sh/
                                  # 30-wallpaper.sh, the gnome-dconf mixin, and
                                  # core/render/render-motd.sh directly by path
    80-validate-ci-theme.sh      # GNOME/GDM-accent checks; Plymouth/GRUB/brand-asset checks
                                  # kept identical to Ubuntu's
  headless-setup/
    install.sh                   # plain, unpackaged installer for core/headless/payload/ —
                                  # real RPM packaging (.spec, rpmbuild) is deferred, see its
                                  # own header for the scriptlet-semantics risk that motivated
                                  # deferring rather than guessing
```

Known gaps, disclosed in the code's own headers rather than silently assumed: whether Fedora's
stock login shell actually renders `/etc/update-motd.d/*` (a Debian/PAM convention, unverified
on Fedora); GDM dconf-profile existence assumed but not independently verified on a live box;
SELinux (`restorecon`, `httpd_can_network_connect`) and firewalld handling in `install.sh` are
best-effort and untested in enforcing mode; ROCm, LACT, and Companion Launcher are all
intentionally stubbed (see `provision.sh`'s own header for why each was stubbed rather than
guessed at) rather than silently broken.

### `backends/arch/` (Phase 4, implemented)

```
backends/arch/
  provision/
    provision.sh                 # genuine pacman reimplementation, same tier-gating/
                                  # function-per-tool shape as Ubuntu's/Fedora's — NOT a thin
                                  # wrapper. Runs one `pacman -Syu` up front, then
                                  # `pacman -S --needed` per tool (see its own header's
                                  # "ROLLING-RELEASE CORRECTNESS NOTE" for why a scattered
                                  # `pacman -Sy` the way apt/dnf refresh metadata would risk
                                  # Arch's own documented "partial upgrade" failure mode).
                                  # Every daemon-installing function calls an explicit
                                  # `systemctl enable --now` — pacman packages never
                                  # auto-start services the way Debian's postinst (and even
                                  # Fedora's docker-ce.rpm) do.
  desktop-theme/
    gnome-defaults-arch-overrides.inc.sh  # Adwaita theme/icon/cursor + accent-color/
                                           # color-scheme selection — near-identical to
                                           # Fedora's override file; this backend's own
                                           # research independently re-confirmed Arch's
                                           # GNOME Shell theme is compiled in too, not a
                                           # separate package, rather than assuming Fedora's
                                           # finding transfers for free.
    28-gdm-accent-branding.sh    # same accent-color + corrective-dconf-overlay mechanism
                                  # as Fedora's step of the same name, for the same reason
                                  # (20-dconf-system.sh's own internal re-source of
                                  # gnome-defaults.inc.sh defeats a simple sourced-after
                                  # override — see that script's header).
    15-grub-theme.sh              # Arch-only: a detect-and-delegate wrapper, not a straight
                                  # by-path reuse of Ubuntu's script. Arch has no installer
                                  # flavor guaranteeing GRUB is present the way Ubuntu/Mint/
                                  # Fedora do — a real fraction of Arch systems boot
                                  # systemd-boot instead. This step detects which is in use
                                  # (bootctl / /boot/loader/loader.conf for systemd-boot;
                                  # /etc/default/grub + grub-mkconfig for GRUB) and either
                                  # execs into Ubuntu's fully-portable GRUB2 logic or skips
                                  # cleanly (exit 0, clear log message) rather than the hard
                                  # failure Ubuntu's own script gives a missing
                                  # /etc/default/grub.
    apply-ci-os-desktop.sh       # dispatcher: reuses Ubuntu's 10-plymouth.sh/30-wallpaper.sh,
                                  # the gnome-dconf mixin, and core/render/render-motd.sh
                                  # directly by path, plus this backend's own 15-grub-theme.sh
                                  # (not Ubuntu's directly, for the reason above)
    80-validate-ci-theme.sh      # GNOME/GDM-accent checks identical in shape to Fedora's;
                                  # the GRUB check branches on GRUB-vs-systemd-boot instead
                                  # of assuming GRUB, treating systemd-boot as a pass, not a
                                  # warning
  headless-setup/
    install.sh                   # plain, unpackaged installer for core/headless/payload/ —
                                  # real Arch packaging (PKGBUILD + pkgname.install) is
                                  # deferred; see its own header for why pacman's
                                  # differently-named-function .install model is actually
                                  # SAFER than RPM's numeric-$1 scriptlet overload in
                                  # principle, but was still deferred for this pass (no live
                                  # Arch box available to test install/upgrade/remove
                                  # cycles against, mirroring Fedora's and the ISO passes'
                                  # own deferrals)
```

`core/manifest/role-map/pacman.yaml` documents the package-level detail (same
documentation-only, not-runtime-parsed status as `apt.yaml`/`dnf.yaml`). Notable findings from
this backend's own packaging research, none inherited uncritically from Fedora's: `docker`,
`github-cli`, `cloudflared`, `tailscale`, and `chromium` are all official `extra`-repo packages
needing no third-party repo at all (simpler than both apt's and dnf's repo-add mechanics);
`rocm-hip-sdk` and `lact` are ALSO official `extra` packages — genuine, non-stubbed
implementations where Fedora's dnf.yaml had to stub both for lack of an official RPM; VS Code
(the Microsoft-branded build) has no official package at all, only the AUR's
`visual-studio-code-bin` — stubbed per the plan's AUR-helper-automation deferral, distinct from
the native but different `code` (Code-OSS) package that does exist in `extra`; and `gunicorn`'s
Arch package name is plainly `gunicorn`, NOT `python-gunicorn` — a correction to the
"Arch always prefixes Python packages with `python-`" assumption that motivated checking it.

Known gaps, disclosed in the code's own headers rather than silently assumed: whether Arch's
stock login shell renders `/etc/update-motd.d/*` (unverified here for the same reason it's
unverified on Fedora); unlike Fedora, `28-gdm-accent-branding.sh` does not just check for
`/etc/dconf/profile/gdm` — ArchWiki documents it as "no longer shipped upstream" on Arch, so the
script creates it (when missing) with the ArchWiki-documented `user-db:user` / `system-db:gdm` /
`file-db:/usr/share/gdm/greeter-dconf-defaults` content before writing the `gdm.d` override, but
this was not independently verified against a live Arch box. A follow-up fix corrected a
step-order bug an independent adversarial review caught in this same mechanism: the profile must
exist *before* `apply-ci-os-desktop.sh`'s `dconf` step runs, not just before `accent`'s own later
write — `backends/_mixins/gnome-dconf/20-dconf-system.sh` gates its own GDM fragment
(background colors, remote-desktop/RDP-for-GDM keys) on the profile already existing, and on a
first run it didn't yet, so that fragment was silently skipped even though `accent` created the
profile moments later for its own narrower fragment. `apply-ci-os-desktop.sh` now invokes
`28-gdm-accent-branding.sh --ensure-gdm-profile-only` before the `dconf` step specifically to
close that gap. The same review also found `install_rocm_driver_arch()` never added the desktop
or `ci` user to the `render`/`video` groups the way Ubuntu's working ROCm installer does — fixed
by porting that installer's `ensure_video_groups()` logic. The nginx `default_server` collision fix and NetworkManager enable in
`headless-setup/install.sh` are untested on a live install; Companion Launcher has no Arch build
(official or AUR) and is intentionally stubbed; VS Code (Microsoft's build) is intentionally
stubbed rather than AUR-installed or silently substituted with Code-OSS; and this backend
assumes GNOME Shell + GDM and a bootloader are already present (Arch has no installer flavor
guaranteeing either) — `provision.sh`'s `check_desktop_prereqs()` warns rather than fails when
GNOME/GDM aren't detected, and `15-grub-theme.sh` is the one step that actively detects and
branches on GRUB-vs-systemd-boot instead of assuming.

### `backends/cachyos/` (Phase 7, ISO build implemented; not yet booted or installed)

```
backends/cachyos/
  upstream.lock   every pin: upstream commit and fallback, builder image digest, CachyOS key fingerprint, mirrorlist, edition identity
  iso/            scripts/build-iso.sh (host: only Docker), in-container build and overlay engine, verify-iso.sh; docker/; overlay/; tests/
  installer/      Calamares overlay: settings, module configs, branding, guards, scripts
  provision/      first-boot wrapper around backends/arch/provision/provision.sh, systemd units, setup-portal stager
```

A live and installer ISO of Companion OS based on CachyOS, and the first archiso-based backend. It does not write an Arch-native
archiso profile (that stays deferred, below): it consumes a **pinned upstream profile** (CachyOS-Live-ISO: KDE Plasma,
plasma-login-manager, the online Calamares installer), applies an **overlay** (`files/`, `patches/`, `packages.add|remove`,
`profiledef.append.sh`) to a throw-away copy of it and runs the stock `mkarchiso` in a privileged amd64 container; the host needs
only Docker. Upstream is never edited.

* **Three layers**, because the CachyOS installer builds the target from the network and does not copy the live image: the live
  image (identity, menus, launcher), Calamares (package list, payload staging, unit enabling, identity carry-over) and first boot
  (`backends/arch/provision/provision.sh` behind a wrapper).
* **Identity**: `NAME="Companion OS"`; `ID=cachyos` and `ID_LIKE=arch` stay (CI-Hub string-matches `ID_LIKE=arch`); a later-sorting
  pacman hook rewrites the whole os-release after `cachyos-hooks`' own hook.
* **Reuse**: the Arch `provision.sh` behind a thin wrapper (as Mint wraps Ubuntu's), `core/headless/payload`, `core/render/*`,
  `vendor/brand`. Nothing in `backends/arch/` is edited.
* **Limits**: online install only; rolling package set; no Secure Boot; the Companion Stick can not boot it (casper is hard-coded);
  the live profile is baseline x86-64 (the `cachyos-v3` repositories fail under Rosetta).
* **Status**: unit-tested on fixtures and on a miniature ISO; no Companion ISO has been built, booted or installed.

See [`cachyos-backend.md`](cachyos-backend.md) and `backends/cachyos/README.md`.

## GNOME Shell / GDM gresource rebranding

`core/render/render-gnome-shell-gresource.sh` is the generic mechanic behind rebranding a
compiled GNOME Shell theme: extract a theme's `.gresource` file, swap widget/logo SVG assets by
resource filename, remap accent-color hex literals via a caller-supplied Perl substitution
file, optionally audit the recompiled CSS for regressions, then recompile with
`glib-compile-resources`. It used to be Ubuntu/Yaru-hardcoded logic living directly in
`build-gdm-branding-gresource.sh`; that script is now a thin caller that exports Yaru-specific
data — `THEME_NAME=Yaru`, `COLOR_MAP_FILE` pointing at `yaru-color-map.pl` (Yaru's ~30-entry
orange→teal luminance ramp), `AUDIT_PATTERNS_FILE` pointing at `yaru-audit-patterns.txt`
(regression-guard `grep -E` patterns for pre-rebrand Yaru/Ubuntu colors; comment lines use a
`## ` prefix, since the patterns themselves are hex colors starting with a bare `#`) — and
`exec`s into the generic script.

This generalization was built as the anticipated prerequisite for Fedora's GDM/GNOME-Shell
branding (Phase 3a) — but Fedora research found the gresource-extraction approach doesn't
actually apply there, so `backends/fedora/` never calls this script. **Ubuntu remains this
script's only caller.** Backward compatibility with Ubuntu's existing caller (no-argument
invocation from `build-packages.sh`, `SOURCE_GRESOURCE`/`SOURCE_XML` env var overrides
propagating through `exec`) was verified when the split was made, and the generalization is
kept — a future backend on a distro that *does* ship a separate, add-alongside GNOME Shell
theme package (the way Yaru is one) can still reuse it — but it is no longer a promised
building block for every GNOME-Shell-based backend.

**Why Fedora doesn't use it**: unlike Yaru, Fedora Workstation ships no separate,
add-alongside GNOME Shell theme package. The shell's default theme is compiled directly into
the `gnome-shell` package's own build, landing flat at
`/usr/share/gnome-shell/gnome-shell-theme.gresource` (no `theme/<name>/` subdirectory, no
`gdm.css` — GDM is just gnome-shell running in `gdm` mode, styled by the same
`gnome-shell-dark.css`/`gnome-shell-light.css`). Overwriting it would be silently clobbered by
every `dnf update gnome-shell`. Fedora also has a real *supported* alternative that Ubuntu/Yaru
predates: GNOME 47+'s `org.gnome.desktop.interface accent-color`, a locked 9-value named enum
(blue/teal/green/yellow/orange/red/pink/purple/slate) that shell CSS and libadwaita apps derive
their accent styling from, rather than the ~30 scattered hex literals Yaru's SCSS has. Fedora's
`backends/fedora/desktop-theme/28-gdm-accent-branding.sh` sets the nearest named color (`teal`,
to the CI canon primary) via `gsettings`/dconf for both the live user session and GDM's dconf
profile — no gresource surgery, no recompile, and it survives package updates. The tradeoff:
it's locked to those 9 named values, not an exact hex match, and there's no equivalent hook yet
for swapping GDM's logo/icon assets (left as a known, deferred gap).

**Arch doesn't use it either, for the same reason — independently re-confirmed, not assumed**:
this backend's own research (not a copy-paste of Fedora's) checked Arch's `gnome-shell` package
directly and found the identical shape — the shell theme is compiled into
`gnome-shell-theme.gresource` inside the `gnome-shell` package's own build, no separate
add-alongside theme package, no distinct `gdm.css`. This is upstream GNOME's own packaging
layout (the gresource is generated from `data/gnome-shell-theme.gresource.xml` in the
`gnome-shell` source tree itself, unchanged since GNOME 3.16), not a Fedora-specific patch, so
there was good reason to expect Arch — which tracks upstream even more closely than Fedora, with
fewer distro patches — to match, and it does. `backends/arch/desktop-theme/28-gdm-accent-branding.sh`
uses the same `org.gnome.desktop.interface accent-color` mechanism as Fedora's step of the same
name.

## Bazzite: an image-based backend, not a provisioning script

Every backend through Phase 4 shares one execution model: a script runs ON an
already-installed, already-running system and imperatively installs packages / edits
config files in place. Bazzite (Phase 5) breaks that model entirely — it's Fedora Atomic
(bootc/rpm-ostree), where the OS root filesystem is built as an OCI container image via a
`Containerfile`, then `bootc switch`ed onto hardware. `/usr` (and `/etc`'s *defaults*) is
what a `podman build` durably produces; `/usr` is read-only at runtime; `/var` (and
therefore `/home`, a symlink into `/var/home`) is excluded from the image commit
entirely — it's machine-local state seeded at first boot, not something a shared,
publicly-distributed image can contain.

That last fact shapes almost everything about `backends/bazzite/`:

- **`backends/bazzite/image/{Containerfile,build.just,.env,files/}`** — the image
  definition. `FROM ghcr.io/ublue-os/bazzite:stable@<pinned digest>` (KDE Plasma — Bazzite
  ships ~10 variants across two DE families; the unqualified `bazzite` tag is unambiguously
  the flagship, breaking the GNOME pattern every prior backend followed). Bakes: Plymouth
  (token-derived colors, replicating — not sourcing — Ubuntu's 4-key sed transform, since
  Ubuntu's script also does interactive-upgrade bookkeeping that makes no sense for a
  from-scratch image build), GRUB background + `ci_grub_merge_key()`, MOTD
  (`core/render/render-motd.sh`, unmodified), the KDE color-scheme file (reusing
  `backends/_mixins/kde-plasma/CI-OS-Dark.colors` as-is — this is the first backend to
  actually exercise that scaffolding, written in Phase 0/1a and unused until now), plus
  `gh`/`cloudflared`/`chromium`/VS Code/Tailscale/LACT and the Ollama binary+unit via plain
  `dnf5 install` RUN steps (Bazzite shares Fedora's RPM/repo universe). Token-derived PNGs
  (GRUB background, Plymouth watermark) are rendered by `build.just`'s own `render` recipe
  into a local staging directory *before* the image build starts, then `COPY`'d in — a
  Containerfile build context needs files already present on disk, it can't invoke a repo
  script mid-build the way every prior backend's live-system scripts can.
- **Docker vs. Podman — resolved as Podman**, not Docker CE, even though layering Docker CE
  is a proven pattern elsewhere in Universal Blue (ublue-os's own `bazzite-dx` variant does
  exactly that with no reported conflict). Podman + Distrobox is Bazzite's own stock
  default; fighting it purely for cross-backend naming consistency adds image weight the
  bake-vs-first-boot discipline elsewhere argues against, and Podman exposes a
  Docker-API-compatible socket that needs only a small, mechanical adapter, not a rewrite.
  `backends/bazzite/modules/lib/podman-docker-compat.sh` implements that adapter — a
  `docker() { podman "$@"; }` shell-function shim plus a persistent `/etc/tmpfiles.d/` rule
  aliasing `/run/docker.sock` to Podman's socket — so `core/lib/ci-hub.sh` runs completely
  unmodified. Unverified: whether `podman compose`'s fidelity to the specific Compose-v2
  features ci-hub.sh's generated YAML uses (`depends_on: condition: service_healthy`,
  `env_file`, Traefik forwardauth labels) actually holds — the shim mechanism itself is
  sound, but nothing in this project's development so far has exercised it against a live
  Podman host.
- **`backends/bazzite/modules/`** — the first-boot half, for whatever genuinely can't be
  baked: `ci-os-first-boot-ci-hub` (needs registry credentials/device pairing — secrets
  never belong in a publicly-distributed image layer) and `ci-os-first-boot-ollama-models`
  (the plan's own explicit first-boot decision, to avoid multi-GB image bloat) were part of
  the original brief; `ci-os-first-boot-core-tools` (the `ci` system user, `uv`, asdf/Node —
  all core-tier, all writing into `$HOME`) was added in a follow-up fix after an adversarial
  review caught that the role-map documented these as first-boot but no script implemented
  any of them — a real functional regression versus every prior backend. Each first-boot
  unit uses `ConditionPathExists=!<marker>` so systemd skips it entirely (not "runs and
  no-ops") on every later boot, reusing the exact marker-file convention
  `backends/ubuntu/chroot/customize-chroot.sh`'s own first-boot service already established,
  just split into independent per-concern units instead of Ubuntu's one. `ci-os-first-boot-
  core-tools.sh` detects the real desktop user differently from every other backend too —
  there's no `$SUDO_USER` in a systemd-unit context — by scanning `/etc/passwd` for the
  first real (UID 1000-59999, real shell/home) account, and deliberately drops the
  `usermod -aG docker ci` step every other backend's `create_ci_user()` has, since there's
  no verified Podman-socket group-access equivalent to grant on this backend.
- **Not baked at all** (a disclosed scope boundary, not an oversight): `core/headless/
  payload/`'s captive-portal subsystem (hostapd/dnsmasq/nginx/Flask setup-backend) — never
  in this phase's research or brief, would need several more unresearched package layers.
  `ci-os-first-boot-setup-portal-gate` (a conditional-enablement decision for those units,
  based on whether the device was already paired before this boot) is still staged and
  enabled, forward-compatible with a later pass adding the subsystem for real; its own
  presence-check degrades to a harmless no-op today, since none of the units it looks for
  exist yet. Homebrew is also not implemented — but that's true on every backend (tier:
  extended, always opt-in), so leaving it out here doesn't regress anything.
- **ROCm** stays unresolved, inheriting Fedora's gap (no official Fedora ROCm repo), though
  Bazzite's own base images bundle a meaningfully better Mesa/Vulkan baseline than stock
  Fedora Workstation, partially offsetting it. **LACT**, by contrast, genuinely un-stubs
  here — it publishes a real Fedora COPR, independently confirmed by this phase's research
  (not inherited from Fedora's own unverified stub).

This backend cannot be build-tested in this environment (no bootc/podman build host
available) — `build.just`'s header discloses this plainly rather than claiming a working
build; what *was* verified: `docker build --check` against the complete Containerfile,
`bash -n` on every RUN block individually, every `COPY` source path resolving on disk, the
base image digest resolved live against GHCR, and the token-derived PNGs genuinely rendered
and checked (not placeholders).

## NixOS: a flake of reusable modules, not a script or an image

Phase 6 is a *second* fundamentally different execution model — distinct from both the
traditional provisioning-script backends (Ubuntu/Mint/Fedora/Arch) and from Bazzite's
Containerfile/bootc image build. NixOS's configuration model is declarative: this backend
does not produce a script that runs on an already-installed system, and does not produce a
bootable image either. It produces a Nix **flake** (`backends/nixos/flake.nix`) exposing
**NixOS modules** — `nixosModules.default` (and the three underlying modules individually)
— that a *consumer* imports into their *own* system configuration flake:

```nix
nixosSystem {
  modules = [
    ci-os-nixos.nixosModules.default
    ./hardware-configuration.nix
    { services.ci-os.ecosystem.enable = true; services.ci-os.headlessSetup.enable = true; }
  ];
}
```

The deliverable is reusable Nix code, not an artifact built once and distributed — that
distinction shapes almost everything about `backends/nixos/`:

- **`modules/branding.nix`** — Plymouth, GRUB background, GNOME/GDM accent-color, MOTD.
  Split by what each artifact actually needs, not one uniform approach: PNG rendering
  (the GRUB background, the Plymouth watermark) isn't expressible in pure Nix evaluation —
  it genuinely needs `rsvg-convert`/ImageMagick — so those invoke
  `core/render/render-grub-background.sh` **unmodified**, by path, inside a
  `runCommand`-style derivation with the right build inputs declared; everything that's a
  plain value lookup (the dconf accent-color string, MOTD text, Plymouth's four config
  colors) is reimplemented **natively in Nix**, reading `vendor/brand/tokens/tokens.json`
  directly via `builtins.fromJSON`, with `tokens.sh`'s `ci_rgb()`/`ci_hex0x()` ported as a
  ~5-line Nix hex-digit lookup (exactly the size the plan anticipated). GDM's accent-color
  default uses NixOS's genuine **system-level** `programs.dconf` module — confirmed
  distinct from home-manager's per-user `dconf.settings`, which this backend does *not*
  depend on — wiring a `system-db:gdm` profile/database declaratively, the same outcome
  Fedora's and Arch's research had to hand-write a `/etc/dconf/profile/gdm` file to
  achieve imperatively. GRUB theming is gated on `config.boot.loader.grub.enable` (visible
  at evaluation time from the consumer's own declared config, not a runtime filesystem
  probe the way Arch's `15-grub-theme.sh` needs) — NixOS itself defaults new installs to
  systemd-boot, not GRUB, and nixpkgs exposes no themed-splash option for systemd-boot, so
  a themed systemd-boot menu is a disclosed, out-of-scope gap rather than an oversight.
- **`modules/ecosystem.nix` + `manifest/{ecosystem.generated.json,gen-ecosystem-json.sh}`**
  — tier-gated (core/extended/hardware) ecosystem tools. Unlike every bash backend's
  `role-map/<pkgmgr>.yaml`, this backend consumes a **committed, regeneratable JSON file**
  (`gen-ecosystem-json.sh` regenerates it from `core/manifest/ecosystem.yaml` via `yq`,
  same manual-regen contract as `tokens.sh`/`tokens.json`) read via `builtins.fromJSON` —
  not an Import-From-Derivation build-time YAML→JSON step, which nixpkgs's own
  contribution guidance treats as something to avoid at evaluation time. Most tools map to
  real, current nixpkgs modules/packages: `virtualisation.docker`, `services.tailscale`,
  `services.ollama` (with acceleration options — confirmed to actually resolve to the
  genuine Microsoft-branded `pkgs.vscode`, not an unrelated OSS build, the same
  distinction Arch's research had to draw for the AUR), `rocmPackages` and `services.lact`
  for the hardware tier (both **real** here, unlike Fedora's stub — nixpkgs' ROCm package
  set is substantial). `users.users.ci` bakes `render`/`video` group membership in from
  the start — a fix that had to be *found twice* on the bash backends (Fedora's provision
  script never needed it since ROCm was stubbed there; Arch's initial pass missed it and
  needed a follow-up fix) ships correct from day one here, since there's no equivalent of
  forgetting a step when the whole configuration is declared together. `core/lib/ci-hub.sh`
  runs unmodified from a systemd oneshot; unlike Bazzite's first-boot-only marker file, this
  unit deliberately re-runs every boot (ci-hub.sh is already idempotent by design), with a
  `systemd.paths` watcher on the pairing-env file so a device paired later in its life gets
  CI-Hub deployed within seconds, not on next reboot — a real advantage the declarative
  model gets for free that Bazzite's imperative first-boot model doesn't.
- **`modules/headless-setup.nix`** — the captive-portal WiFi onboarding payload, wired via
  native `hostapd`/`dnsmasq`/`nginx` NixOS modules (raw `systemd.services`, not the
  higher-level module wrappers, where the payload's own runtime interface-autodetection
  would otherwise be lost) plus the existing Flask setup-backend reused by path. The
  "already paired, don't enable the portal" decision uses systemd's own
  `ConditionPathExists`, re-evaluated on every start attempt — the NixOS-idiomatic
  replacement for Bazzite's one-time marker-file gate, since Nix modules re-evaluate
  against declared configuration rather than tracking "first boot" as its own state.
- **Companion Launcher** stays unavailable (no NixOS/Nix package anywhere, confirmed) —
  represented by omitting the option entirely rather than defining a no-op `enable` flag,
  since a Nix option a user can flip that silently does nothing has no equivalent of
  bash's log-message stub and would be a real footgun. **Homebrew** and **Bun** are
  likewise deliberately unwired (both extended-tier and unimplemented on every backend,
  and philosophically redundant with Nix's own package management in Homebrew's case).

This backend cannot be evaluated with a real Nix toolchain in this environment (no `nix`
binary available, same constraint noted honestly rather than worked around) — verified
instead via grammar-based Nix syntax parsing (0 errors across all four files) and manual
line-by-line cross-referencing against fetched nixpkgs source for every module/option
claimed, not guesswork. A genuine `nix flake check` against a real nixpkgs revision
remains open follow-up work for whoever has a working Nix toolchain.

This completes backends 1 to 6 of the rollout table; Phase 7 (CachyOS) is described after the Arch section.

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
| 2 | Mint | S | **Implemented.** Reuses Ubuntu's apt role-map (`provision.sh` is a thin wrapper) and Ubuntu's Plymouth/GRUB/MOTD steps by path; new work is Cinnamon dconf/session theming + Slick-Greeter login branding. No ISO mode. Known gap: no Mint-specific terminal theming or start-icon/os-release branding yet — see `backends/mint/desktop-theme/apply-ci-os-desktop.sh`'s header. |
| 3a | Fedora (provisioning+theming) | M | **Implemented.** `provision.sh` is a genuine dnf reimplementation (dnf syntax/package names differ too much from apt for a thin wrapper). GDM/GNOME-Shell branding does *not* use the gresource pattern after all — see the note below. |
| 3b | Fedora ISO (kickstart/lorax) | L | Zero reuse from debootstrap/squashfs/xorriso; can slip independently |
| 4 | Arch | M | **Implemented.** `provision.sh` is a genuine pacman reimplementation (rolling-release partial-upgrade and no-autostart conventions have no apt/dnf analog — see its own header). GNOME Shell/GDM branding reuses the same accent-color mechanism Fedora uses (independently re-confirmed for Arch, not assumed). `15-grub-theme.sh` is the one new structural piece: a GRUB-vs-systemd-boot detect-and-delegate wrapper, since Arch has no installer flavor guaranteeing GRUB is present. |
| 5 | Bazzite | L/XL | **Implemented.** Fundamentally different execution model — see the section below. Targets KDE Plasma (Bazzite's flagship variant), adapts to Podman rather than Docker CE, bakes theming + most ecosystem tools into the image, defers $HOME-writing tools (uv/asdf/Node/the `ci` user) and credential-gated deploys (CI-Hub, Ollama models) to first-boot systemd units. |
| 6 | NixOS | L | **Implemented.** A second fundamentally different execution model — see the section below. A Nix flake exposing importable `nixosModules`, not a provisioning script or an image build. Requires reversing CI-OS's former "no Nix" rule (scoped to this one backend). |
| 7 | CachyOS ISO | L | **ISO build implemented; not yet booted or installed.** A pinned CachyOS-Live-ISO profile plus a Companion OS overlay, built with the stock `mkarchiso` in a container; the online Calamares installer with a Companion overlay; first-boot provisioning reuses the Arch `provision.sh` behind a wrapper. No Secure Boot, and the Companion Stick can not boot it; see `docs/architecture/cachyos-backend.md`. |

Deferred, tracked but not committed: Mint ISO-building, Arch archiso profile-building (explicitly
out of scope for Phase 4 — no default DE, no shared code with kickstart/debootstrap, low payoff
relative to effort; Phase 7 builds an ISO from a pinned CachyOS profile instead, not an Arch-native one), Fedora kickstart/lorax (can slip past 3a), Bazzite model-baking into the
image (default: pull at first boot, not baked in), Arch AUR-helper automation (Phase 4's
`install_vscode()`/`install_companion_launcher()` stub rather than invoke yay/paru, per this
deferral).

## Security note

An earlier audit of the provisioning scripts found and removed three checked-in credential
leaks (a live Cloudflare API token, a shared tunnel token, and a dev registry credential
fallback) — see the repo's commit history for the fix. `core/manifest/ecosystem.yaml`'s
`requires_secrets`/`requires_pairing` fields exist specifically so CI-Hub's credential
requirements stay documented and explicit rather than defaulting to something checked into
source again.
