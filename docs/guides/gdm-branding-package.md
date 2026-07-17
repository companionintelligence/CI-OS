# GDM Branding Package (dpkg-divert)

This guide defines the enterprise-safe CI-OS login-screen branding architecture for Ubuntu 24.04.

## Goal

Override Yaru GNOME Shell resources for GDM in a package-managed, update-safe, reversible way.

Target file:

- `/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource`

## Package

The package lives at:

- `packages/mydistro-branding`

It depends on:

- `yaru-theme-gnome-shell`

Maintainer scripts use `dpkg-divert` so upstream Yaru upgrades install to:

- `gnome-shell-theme.gresource.distrib`

while `mydistro-branding` owns:

- `gnome-shell-theme.gresource`

## Branding Inputs

Accent colors (only accents remapped; greys preserved):

- `#00a9a7`
- `#066c80`

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
./tools/iso-build/scripts/build-gdm-branding-gresource.sh
```

2. Build packages (includes `mydistro-branding`):

```bash
./tools/iso-build/scripts/build-packages.sh ./output/packages
```

3. Stage package for live-build:

```bash
./tools/iso-build/scripts/stage-live-build-branding-package.sh \
  ./output/packages \
  ./config/packages.chroot
```

4. Build ISO (live-build flow):

```bash
lb clean
lb config
lb build
```

## Validation

After installation on target system:

```bash
dpkg-divert --list | grep gnome-shell-theme.gresource
dpkg -S /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource
ls /usr/share/gnome-shell/theme/Yaru/*.distrib
```

Expected:

- diversion owned by `mydistro-branding`
- branded file owned by `mydistro-branding`
- upstream Yaru file present as `.distrib`

## Rollback

```bash
sudo apt remove mydistro-branding
```

This removes diversion and restores upstream behavior.
