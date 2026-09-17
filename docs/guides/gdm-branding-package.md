# GDM Branding Package (dpkg-divert)

This guide defines the enterprise-safe CI-OS login-screen branding architecture for Ubuntu 24.04.

## Goal

Override Yaru GNOME Shell resources for GDM in a package-managed, update-safe, reversible way.

Target file:

- `/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource`

## Package

The package lives at:

- `backends/ubuntu/packages/ci-os-branding`

It depends on:

- `yaru-theme-gnome-shell`

Maintainer scripts use `dpkg-divert` so upstream Yaru upgrades install to:

- `gnome-shell-theme.gresource.distrib`

while `ci-os-branding` owns:

- `gnome-shell-theme.gresource`

## Branding Inputs

Accent colors, sourced from `vendor/brand/tokens/tokens.sh` (not hardcoded — see
`backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh`):

- `$CI_DARK_PRIMARY` (canon sage) — was hardcoded `#00a9a7`
- `$CI_LIGHT_PRIMARY` (canon phthalo) — was hardcoded `#066c80`

Only these two anchor colors are token-sourced; the ~28 intermediate hex values in the
Yaru accent remap table are a hand-tuned luminance ramp between them, left as literals —
see `docs/architecture/multi-distro-design.md`.

Asset replacements:

- `assets/package theme assets/checkbox-focused-light.svg`
- `assets/package theme assets/checkbox-light.svg`
- `assets/package theme assets/checkbox-off-focused-light.svg`
- `assets/package theme assets/toggle-on-light.svg`

Symbolic banner/logo/wallpaper replacement source:

- `assets/logos/2024_CI__Logo_Banner_Color_small.svg`

## Build Flow

1. Build branded gresource from upstream Yaru:

```bash
./backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh
```

2. Build packages (includes `ci-os-branding`):

```bash
./backends/ubuntu/iso/scripts/build-packages.sh ./output/packages
```

**This is as far as the primary ISO-build path (`build-iso.sh`) goes.** It does not
install `ci-os-branding` as a `.deb` at all — `backends/ubuntu/chroot/customize-chroot.sh` Step 2b copies
the compiled `.gresource` file directly into the chroot's `/usr/share/gnome-shell/...`
(no package, no postinst, no diversion), since the ISO's own squashfs already ships the
final file layout and doesn't need dpkg-divert's update-time reversibility.

The steps below (3–4) are for a **different, optional use case**: installing the
branding as a standalone, reversible `.deb` on a system that isn't being built via
`build-iso.sh` — e.g. staging it into a separate live-build pipeline, or `dpkg -i`'ing it
onto an already-running Ubuntu install. `backends/ubuntu/iso/scripts/
stage-live-build-branding-package.sh` and the `config/packages.chroot` staging path it
targets are explicitly **not part of the active `build-iso.sh` pipeline** — see
`backends/ubuntu/iso/README.md`.

3. (Optional) Stage package for a separate live-build flow:

```bash
./backends/ubuntu/iso/scripts/stage-live-build-branding-package.sh \
  ./output/packages \
  ./config/packages.chroot
```

4. (Optional) Install directly via dpkg, for the standalone/reversible use case:

```bash
sudo dpkg -i ./output/packages/ci-os-branding_*.deb
```

## Validation

After installation on target system:

```bash
dpkg-divert --list | grep gnome-shell-theme.gresource
dpkg -S /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource
ls /usr/share/gnome-shell/theme/Yaru/*.distrib
```

Expected:

- diversion owned by `ci-os-branding`
- branded file owned by `ci-os-branding`
- upstream Yaru file present as `.distrib`

Note: this validation applies to the standalone `.deb` install path (steps 3–4 above),
not to an ISO built via `build-iso.sh` — that path never registers a diversion, since it
copies the gresource directly rather than installing a package.

## Rollback

```bash
sudo apt remove ci-os-branding
```

This removes diversion and restores upstream behavior.
