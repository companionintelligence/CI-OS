# GDM and GNOME Shell branding package (dpkg-divert)

Private & Confidential. Property of Lifescope Inc. Do not distribute.

How the Companion OS login screen and GNOME Shell theme are branded on the Ubuntu 26.04.1 edition in a package-managed, update-safe, reversible way. The Plasma edition does not use this package; it themes through its own overlay (`backends/cachyos/iso/overlay`).

Supported targets: Companion OS on Ubuntu 26.04.1 LTS and Companion OS on CachyOS. Retired 2026-10-17: Ubuntu 24.04, Linux Mint, Fedora, Bazzite, NixOS (restore from the tag `pre-retire-multidistro-2026-10-17`). The theme blob is built from Ubuntu 26.04's Yaru only; a blob built from another release's Yaru is wrong for the GNOME Shell the image ships (retired baseline (24.04.5): the older blob was 5.9 MB, the 26.04 one is 1.3 MB).

Evidence tags: **[V]** verified in a run, **[I]** read from the code and not run.

## Two files, two jobs

Ubuntu 26.04 has two files called `gnome-shell-theme.gresource`, and they are different things (`backends/ubuntu/lib/shell-theme.sh`, read from the 26.04.1 files):

| File | Owner | Size on 26.04.1 | Used by |
|---|---|---|---|
| `/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource` | `yaru-theme-gnome-shell` | 1,320,373 bytes | The Ubuntu session (`modes/ubuntu.json`) and the GDM greeter (`gdm-theme.gresource` resolves to it through the alternatives system) |
| `/usr/share/gnome-shell/gnome-shell-theme.gresource` | `gnome-shell-common` | 811,524 bytes | The upstream GNOME theme, loaded by session modes with no theme of their own (the built-in `restrictive`, `user` and `unlock-dialog`, and `initial-setup`) |

The branded blob is the Yaru theme recoloured, so it has Yaru's resources and **not** the upstream theme's `gnome-shell-light.css` and top-level `gnome-shell-dark.css`. Copied over the upstream file it would remove the stylesheets the built-in modes load, and GNOME Shell would fail to load a theme ("No valid stylesheet found"). So:

- the Yaru file **always** gets the blob;
- the upstream file gets it **only if** the blob provides every resource path that file provides. On 26.04.1 it does not, so that file stays Ubuntu's own and the build says so.

[V] The blob was rebuilt from `yaru-theme-gnome-shell 26.04.5.1ubuntu` and matched the tracked file byte for byte, twice; `core/render/tests/gresource-provenance.sh` (31 checks with the real files) and `backends/ubuntu/lib/tests/shell-theme.sh` (20 checks with the real files) pass.

## Package

The package source is `backends/ubuntu/packages/ci-os-branding` (`Architecture: all`, `Depends: yaru-theme-gnome-shell`). Its `postinst` runs `dpkg-divert --add --rename` on the Yaru file so that an upstream Yaru upgrade installs to `gnome-shell-theme.gresource.distrib` while `ci-os-branding` owns `gnome-shell-theme.gresource`; its `prerm` removes the diversion (`--remove --rename`) before the package's file goes.

## Inputs

Accent colours come from `vendor/brand/tokens/tokens.sh` and are not hard-coded (`backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh`):

- `$CI_DARK_PRIMARY` (canon sage, `#c5e8dc`) for the dark mode accent;
- `$CI_LIGHT_PRIMARY` (canon phthalo, `#0a6358`) for the light mode accent.

Only these two anchor colours are token-sourced; the roughly 28 intermediate hex values in the Yaru accent remap table (`backends/ubuntu/iso/scripts/yaru-color-map.pl`) are a hand-tuned luminance ramp between them, kept as literals. A pattern file (`yaru-audit-patterns.txt`) audits what orange, purple and blue values remain.

Logo: `assets/logos/2024_CI__Logo_Banner_Color_small.svg` replaces Yaru's banner and logo SVGs.

Widget assets: the build still tries to replace four named SVGs from `assets/package theme assets/` (`checkbox-focused-light.svg`, `checkbox-light.svg`, `checkbox-off-focused-light.svg`, `toggle-on-light.svg`). **They are not resources of 26.04's Yaru**: the build prints `No Yaru resource named ... found` for each, and the checkbox and switch recolour is done by the CSS colour map alone [V] (four warnings in the first 26.04.1 build log). The warnings are expected.

## Provenance and the source rule

`core/render/render-gnome-shell-gresource.sh` refuses a source it cannot identify as Ubuntu 26.04 with a 26.04 `yaru-theme-gnome-shell`. Two ways to give it a source:

- `SOURCE_ROOTFS=/path/to/rootfs`: a root filesystem such as the base ISO's extracted layers or a `dpkg -x` tree with `etc/os-release` and `var/lib/dpkg/status`;
- nothing: the running system, whose `/etc/os-release` and dpkg database must say Ubuntu 26.04.

It prints a `[PROVENANCE]` block (os-release, package and version, size and sha256 of the source) and writes it to `PROVENANCE_FILE` when set. The record of what the tracked blob was built from is `backends/ubuntu/packages/PROVENANCE-gnome-shell-theme.txt` (source sha256 `da1d2019...84ac`, output 1,325,684 bytes, sha256 `0a0ec5cd...c2f1`). It sits next to the package directory on purpose, because `build-packages.sh` walks `packages/*/`.

## Build flow

1. Build the branded gresource, in an Ubuntu 26.04 environment with `yaru-theme-gnome-shell` installed (on a Mac, the arm64 container of [Building on a Mac](building-on-a-mac.md)):

```bash
./backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh
```

2. Build the packages, which includes `ci-os-branding`:

```bash
./backends/ubuntu/iso/scripts/build-packages.sh ./output/packages
```

**This is as far as the ISO build goes.** `build-iso.sh` does not install `ci-os-branding` as a `.deb`. Step 2b of `backends/ubuntu/chroot/customize-chroot.sh` calls `ci_os_install_shell_theme` (`backends/ubuntu/lib/shell-theme.sh`), which copies the compiled blob into the image's Yaru path with no package, no postinst and no diversion, because the image's squashfs already has the final file layout and does not need dpkg-divert's update-time reversibility. [V] The first 26.04.1 build passed `verify-iso.sh` section 4d: the Ubuntu session's and the greeter's gresource is the branded blob of the checkout, and the upstream gresource still lists `gnome-shell-light.css`.

Steps 3 and 4 are for a **different, optional use**: installing the branding as a standalone, reversible `.deb` on a running Ubuntu 26.04 machine, or staging it into a separate live-build pipeline. `backends/ubuntu/iso/scripts/stage-live-build-branding-package.sh` and the `config/packages.chroot` path it targets are **not part of the active `build-iso.sh` pipeline**.

3. (Optional) Stage the package for a separate live-build flow:

```bash
./backends/ubuntu/iso/scripts/stage-live-build-branding-package.sh \
  ./output/packages \
  ./config/packages.chroot
```

4. (Optional) Install directly, for the standalone and reversible use case (this changes only the Yaru file, which is the right one for the session and the greeter):

```bash
sudo dpkg -i ./output/packages/ci-os-branding_*.deb
```

## Validation

On a system where the package was installed (steps 3 and 4). All of the behaviour below was run for this guide in a throwaway `ubuntu:26.04` container with `yaru-theme-gnome-shell` installed (**[V]**, 2026-10-18):

```bash
dpkg-divert --list | grep gnome-shell-theme.gresource
dpkg -S /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource
sha256sum /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource      # 0a0ec5cd... is the branded blob
ls /usr/share/gnome-shell/theme/Yaru/*.distrib
```

What you will see:

- the diversion is listed and owned by `ci-os-branding`; the branded file is owned by `ci-os-branding` and has the branded sha256;
- **right after `dpkg -i` there is no `.distrib` file.** dpkg prints "Ignoring request to rename file ... owned by diverting package": the package replaces Yaru's file (`Replaces: yaru-theme-gnome-shell`) and the `postinst` diversion then has nothing to move;
- the `.distrib` file appears the next time Yaru's package is installed or upgraded: Yaru's file goes to `gnome-shell-theme.gresource.distrib` and the branded file stays. That is the update safety the package exists for, and it works.

For an ISO, run `verify-iso.sh` ([ISO build guide](iso-build-guide.md#verify)); section 4d covers this theme and the checks need no boot. How the greeter and the desktop actually look under GNOME Shell 50 has **not** been seen on a booted 26.04.1 image: the analysis that only the Yaru file matters comes from reading the shell's code (**[I]**). The frames that settle it are the pending rows U3 and U4 of [test-evidence.md](../architecture/test-evidence.md#pending-evidence-for-the-ubuntu-2604-image). An ISO built with `build-iso.sh` registers no diversion for this file (the other branding files, such as the Settings About logo and the Plymouth files, are diverted by the theme steps, and `verify-iso.sh` checks them).

## Rollback

`sudo apt remove ci-os-branding` is **not** a clean rollback today (known defect of the package scripts, KI-16 in [known-issues-and-decisions.md](../architecture/known-issues-and-decisions.md)). Two cases were run:

1. **Removed before Yaru was ever updated** (no `.distrib` exists): the removal succeeds and deletes the branded file, leaving **no** `gnome-shell-theme.gresource` at all. Restore Yaru's own file with `sudo apt install --reinstall yaru-theme-gnome-shell`.
2. **Removed after a Yaru update** (a `.distrib` exists): the `prerm` fails with "dpkg-divert: error: rename involves overwriting ... with different file ... not allowed" (exit status 2) and the package **stays installed**. Remove the branded file first, then the package, then restore Yaru's:

```bash
sudo rm /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource
sudo dpkg -r ci-os-branding
sudo apt install --reinstall yaru-theme-gnome-shell
```

In both cases the last command ends with Yaru's own file in place (sha256 `da1d2019...84ac` on 26.04.1) and no diversion left. The ISO build is unaffected: it copies the blob directly and never installs this package.

© Companion Intelligence, Lifescope Inc
