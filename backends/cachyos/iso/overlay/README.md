# Brand and identity overlay (live medium and installed-system hooks)

Everything a person sees in the first minute of the Companion OS edition that is not the installer, plus the files that
keep the installed system's identity ours. The overlay engine (`../scripts/in-container/apply-overlay.sh`) merges it over
a copy of the pinned upstream `archiso/` profile; `../scripts/render-assets.sh` writes the generated half of it into a
staging tree the engine merges afterwards. Nothing here copies CachyOS or Arch artwork (decision D9).

## What it does, surface by surface

| Surface | How | Where |
|---|---|---|
| UEFI boot menu | upstream's `grub.cfg` and `loopback.cfg` patched: Companion OS entry titles and ids, a GRUB theme (`set theme`) with the plain background as the fallback, token-derived menu colours; every `linux`/`initrd` line untouched | `patches/0001-*`, generated `grub/theme/`, `grub/splash.png`, `grub/companion-os-theme.cfg` |
| BIOS boot menu | `archiso_head.cfg`, `archiso_sys*.cfg`, `archiso_pxe-linux.cfg` patched: title, labels, help text, the `DEFAULT` label that upstream left dangling, colours from a generated include. `archiso_tail.cfg`: the Memtest86+ entry loads `/boot/memtest86+/memtest`, where `mkarchiso` installs it (upstream names `/%INSTALL_DIR%/boot/memtest`, which does not exist); that is the **one** kernel line the overlay changes, under the `# ci-os: allow-kernel-line-change` marker | `patches/0002-*`, generated `syslinux/splash.png` (640x480), `syslinux/companion_colors.cfg` |
| Image name and volume | `iso_name`, `iso_label`, `iso_publisher`, `iso_application`; `file_permissions` for what the overlay adds | `profiledef.append.sh` |
| `/etc/os-release`, `/etc/lsb-release` | a static file for the first moment and a **pacman hook that rewrites both after every `filesystem`, `lsb-release` or `cachyos-hooks` transaction**, sorted after the CachyOS hooks that would otherwise win; `ID=cachyos` and `ID_LIKE=arch` stay | `files/airootfs/etc/os-release`, `usr/share/libalpm/{hooks,scripts}/zz-ci-os-os-release*`, generated `usr/share/ci-os/release` |
| Hostname, issue, motd, `/etc/cachyos-release` | static files | `files/airootfs/etc/` |
| Plasma defaults for the live user and every new user | a second hook edits the skeleton that `cachyos-kde-settings` owns: start button icon, desktop wallpaper (the package puts it under a containment that does not exist), colour scheme with its colours, no Breeze splash, lock-screen wallpaper | `usr/share/libalpm/{hooks,scripts}/zz-ci-os-skel*` |
| Wallpaper on a fresh profile | the skeleton (`cachyos-kde-settings`) binds the desktop containment to one fixed activity id, and a new profile's default activity has another, so Plasma ignores the saved wallpaper and builds a default desktop with the stock "Next" image. A Plasma autostart entry therefore asks the running `plasmashell` to set the Companion OS wallpaper on every desktop it actually has, once per user (a stamp file in the user's state directory; the user's own later choice is never overwritten) | `usr/libexec/ci-os/apply-wallpaper`, `etc/xdg/autostart/ci-os-wallpaper.desktop` (both carried to the installed system) |
| Wallpaper, icon, colour scheme, About This System | generated | `usr/share/wallpapers/companion/`, `usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg`, `usr/share/color-schemes/CI-OS-Dark.colors`, `etc/xdg/kcm-about-distrorc` |
| Slow-boot relief for virtual machines | a systemd generator that, when `systemd-detect-virt` reports a VM (KVM included), gives `systemd-nsresourced` 5 minutes, `drm-module-load.target` 10 minutes and the user manager 3 minutes; real hardware is left alone. Without it the stock image drops into emergency mode under software emulation. `qemu-boot.sh --selftest` checks it is byte-identical to the one `--vm-fixes` injects; `verify-iso.sh` checks the ISO carries it, executable | `files/airootfs/usr/lib/systemd/system-generators/companion-vm-timeouts` (listed in `profiledef.append.sh`) |
| Login screen (installed system) | drop-in for the Plasma Login Manager greeter's wallpaper | `files/airootfs/etc/plasmalogin.conf.d/10-companion-os.conf` |
| sshd on the live medium | masked, and the drop-in no longer allows root or password logins (decision D7) | `files/airootfs/etc/systemd/system/sshd.{service,socket}`, `etc/ssh/sshd_config.d/10-archiso.conf` |
| Installed system | the live image holds every file; one command copies them over and runs the hooks once | `usr/share/ci-os/installed/`, [`INSTALLED.md`](INSTALLED.md) |

## Why hooks and not files for the Plasma defaults and the identity

`pacstrap` aborts when an overlay file sits at a path a package also ships, and a package upgrade would put the package's
file back. The skeleton files belong to `cachyos-kde-settings` and `/etc/os-release` is rewritten by `cachyos-hooks`
whenever `filesystem` is upgraded. So the overlay edits after the fact, in PostTransaction hooks whose names sort last:
the same pattern upstream's own `90-cachyos-live-kwin-keyboard.hook` uses, but permanent (the installed system needs it
too), so the hooks carry no `remove from airootfs` marker. `package-owned-ok.txt` lists the few paths the engine's guard
(b) would otherwise question, each with the reason no package owns it.

## Generated, not committed

`render-assets.sh` writes: the GRUB and syslinux backgrounds and theme, the wallpaper package, the icon, the colour
scheme (copied from `backends/_mixins/kde-plasma/`), `kcm-about-distrorc`, the release stamp, and (with the installed-system
part) the GRUB and Plymouth themes. It reads only `vendor/brand`, `core/render` and `core/lib`; the Plymouth theme starts
from the `plymouth` package's stock spinner animation (the one file that names a distribution, `watermark.png`, is replaced).
The staging tree is not part of the repository.

## Tests (`../tests/`)

| Test | Needs | What |
|---|---|---|
| `overlay-brand.sh` | git, awk, python3, ImageMagick; the pinned upstream `archiso/` for part B (`CACHYOS_UPSTREAM_ARCHISO` or `CACHYOS_TEST_FETCH=1`; skipped without); the builder container for the Plymouth and GRUB-theme part | the overlay; the patches against pristine upstream, whose only kernel-line difference must be the Memtest path (the assertion itself is tested on fixtures without upstream); both scripts on fixtures; the renderer's output; `NOTICE` against the files' own licence lines; the documents against the tree |
| `overlay-image-check.sh <root>` | nothing | the identity and desktop defaults of any root tree: the build, an unpacked squashfs, a target |
| `overlay-hook-pacman.sh` | docker (the builder image), no network | a real `pacman` runs `ci-os-neutralise-hello.hook` on a fake `cachyos-hello` package: a text test cannot see how pacman's hook parser treats backslashes |
| `overlay-pacstrap.sh` | docker, network | a real `pacstrap` with `cachyos-hooks` and `cachyos-kde-settings`: a control without our hooks, then the overlay, then the image check |
| `overlay-menu-shot.sh` | docker, QEMU, OVMF | boots both menus from tiny media built from the merged profile and checks the screenshots |

The `# ci-os: allow-kernel-line-change` marker that patch 0002 carries licenses that patch only: the engine's guard (a) compares
everything it adds after the patches (the generated layer, `files/`, the staging tree) with the state right after them, so a
marked patch does not switch the check off for the rest of the profile. What the marked patch itself may change is pinned by
`overlay-brand.sh`: the Memtest path is the only kernel-line difference from upstream, and no other patch may carry the marker.

## Not in this overlay

A live boot splash (the upstream kernel lines carry no `quiet splash` and the engine guards them; also no plymouth in
the live initramfs), a custom Plasma splash and look-and-feel package, a lock-screen layout, a fastfetch logo for the
installed shell greeting, Firefox's "for Arch Linux" about text, and the UEFI menu's missing Memtest86+ entry (upstream's
`memtest.efi` name no longer matches the package). The BIOS Memtest86+ path is fixed by patch 0002 (see the table above).
