# Companion OS identity on the installed system: contract for the installer overlay

The live image is a pinned CachyOS live profile plus this overlay. The system the installer writes to disk is
not that image: Calamares `pacstrap`s and `netinstall`s it from the CachyOS repositories at install time, so
`cachyos-hooks` writes CachyOS's `os-release`, `cachyos-kde-settings` lays down CachyOS's Plasma skeleton, and the
CachyOS GRUB and Plymouth themes are pulled in by the stock module configuration. This file lists what the live
image already holds for the installed system, the one command that puts it there, and the settings the
installer overlay (`../../installer/`, `/usr/share/ci-os/calamares/`) has to point at it.

## What the installed system gets

Everything is a file in the live image at its final path; the manifest
`/usr/share/ci-os/installed/carry-over.list` names them (source of truth: `files/airootfs/usr/share/ci-os/installed/carry-over.list`).

| Path in the live image (and on the target) | Origin | Purpose |
|---|---|---|
| `/usr/share/libalpm/hooks/zz-ci-os-os-release.hook`, `/usr/share/libalpm/scripts/zz-ci-os-os-release` | overlay | Rewrites `/etc/os-release` and `/etc/lsb-release` whole after every upgrade of `filesystem`, `lsb-release` or `cachyos-hooks`. The name sorts after every CachyOS hook, so Companion OS is what is left. |
| `/usr/share/libalpm/hooks/zz-ci-os-skel.hook`, `/usr/share/libalpm/scripts/zz-ci-os-skel` | overlay | After `cachyos-kde-settings` is installed or upgraded: start-button icon, desktop wallpaper, colour scheme, no Breeze splash, lock-screen wallpaper, all by editing `/etc/skel/.config/*`. |
| `/usr/share/ci-os/release` | generated | Version, build day and console colour that the identity script writes into `os-release`. |
| `/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg` | generated (copy of `vendor/brand/logos/mark.svg`) | `LOGO=` of `os-release`, the start button, About This System. |
| `/etc/xdg/kcm-about-distrorc` | generated | About This System: logo and version. |
| `/usr/share/color-schemes/CI-OS-Dark.colors` | generated (copy of `backends/_mixins/kde-plasma/CI-OS-Dark.colors`) | The colour scheme `zz-ci-os-skel` merges into `kdeglobals`. |
| `/usr/share/wallpapers/companion/` | generated | Plasma wallpaper package (1920x1080 and 3840x2160). |
| `/usr/libexec/ci-os/apply-wallpaper`, `/etc/xdg/autostart/ci-os-wallpaper.desktop` | overlay | Once per user, asks the running `plasmashell` to put that wallpaper on every desktop it has: the skeleton's saved desktop is bound to an activity id that a new profile does not have, so without this Plasma shows its stock image. |
| `/etc/plasmalogin.conf.d/10-companion-os.conf` | overlay | Wallpaper behind the Plasma Login Manager greeter. |
| `/usr/share/grub/themes/companion-os/` (`theme.txt`, `background.png`, `select_c.png`) | generated | GRUB theme, byte-identical to the one the live medium's menu uses (`/boot/grub/theme/`), which was booted under OVMF in QEMU at 800x600 and 1920x1080. On the installed system `grub-mkconfig` has to load it (`GRUB_THEME`): that part is **not tested**; GRUB falls back to its text menu if the theme does not load. |
| `/usr/share/plymouth/themes/companion-os/` (`companion-os.plymouth` and the images) | generated | Plymouth theme: the stock spinner animation, recoloured with `ci_plymouth_recolor`, our watermark; no CachyOS animation. |

`/etc/issue` needs nothing: it is `\S{PRETTY_NAME} \r (\l)` on the live image and on Arch's `filesystem`, so it follows `os-release`.
The installed system gets `/etc/motd` (from `/usr/share/ci-os/installed/etc-motd`) only if the target has none.

## The one command

```bash
/usr/share/ci-os/installed/carry-over "${ROOT}"      # from the live system; no chroot, no mounts needed
```

It copies each path of the manifest into `${ROOT}`, installs `/etc/motd`, then runs the two hook scripts once against
`${ROOT}` (`CI_OS_ROOT=${ROOT}`), because a hook only fires when a package it watches changes. Exit status: `0`
done; `1` a listed path is missing from the live image (everything else is still done); `2` bad usage (no such
directory, or `/`). It is idempotent.

**Where it goes in the Calamares sequence** (a `shellprocess` with `dontChroot: true`):

1. **After** the package installation (`pacstrap` and `netinstall`/`packages`): `cachyos-kde-settings` must have laid
   down `/etc/skel`, `filesystem` its `os-release`, and `plymouth` and `grub` must be there.
2. **Before** `plymouthcfg` (it needs the theme directory), `initcpio` (the Plymouth theme goes into the initramfs),
   `grubcfg` and `bootloader` (they read the GRUB theme and the distributor name).
3. **Before** the step that copies `/etc/skel` into the new user's home (`cp -rf /etc/skel/. /home/${USER}/.` in the
   stock `shellprocess.conf`): a home that already exists is not edited. If that cannot be arranged, run
   `CI_OS_ROOT=${ROOT} /usr/share/libalpm/scripts/zz-ci-os-skel ${ROOT}/home/<user>` as root and `chown -R` the result;
   the script takes any directory that holds a `.config`.

Failure policy suggested by the brief: these are cosmetic. A non-zero exit should log loudly and let the
installation go on (fail open); `carry-over` has already done everything it could.

## Settings the installer overlay must point at these files

| Module / file | Setting | Value |
|---|---|---|
| `plymouthcfg.conf` | `plymouth_theme`, and `plymouth_theme_amdgpu` (CachyOS special-cases AMD GPUs) | `companion-os` |
| `pacstrap.conf` / `netinstall.yaml` | drop | `cachyos-plymouth-bootanimation`, `cachyos-plymouth-theme`, `cachyos-grub-theme`, and the CachyOS-named global themes (`cachyos-*-kde*`, `char-white`) |
| `grubcfg.conf` | `GRUB_THEME` (with `always_use_defaults: true`) | `/usr/share/grub/themes/companion-os/theme.txt` |
| branding `branding.desc` | `bootloaderEntryName` (becomes `GRUB_DISTRIBUTOR`) | `Companion OS` |
| `bootloader.conf` | `efiBootloaderId` | `companion-os` |
| `users.conf` | `hostname.template` | `companion-os` |

## What the identity files say (for the installer's own checks)

`/etc/os-release` after `carry-over` (values in `<>` come from `/usr/share/ci-os/release`):

```
NAME="Companion OS"
PRETTY_NAME="Companion OS <version>"
ID=cachyos                       # the base's machine identity, deliberately unchanged
ID_LIKE=arch                     # exactly one token: CI-Hub's installer string-compares it with "arch"
BUILD_ID=rolling
VARIANT="Plasma (based on CachyOS)"
ANSI_COLOR="38;2;<r>;<g>;<b>"    # CI_DARK_PRIMARY
HOME_URL="https://ci.computer"  DOCUMENTATION_URL="https://docs.ci.computer"
SUPPORT_URL="https://ci.computer/support"  BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
LOGO=ci-os-logo
CI_OS_ID=ci-os  CI_OS_VERSION="<version>"  CI_OS_BUILD="<yyyymmdd>"
```

`/etc/lsb-release`: `DISTRIB_ID=cachyos`, `DISTRIB_RELEASE=rolling`, `DISTRIB_DESCRIPTION="Companion OS <version>"`.
`/usr/lib/os-release` (owned by `filesystem`) is left alone and still says Arch; `/etc/os-release` takes precedence
for everything that follows the os-release(5) lookup order.

Checks to run on a finished installation:

```bash
grep -E '^(NAME|PRETTY_NAME|ID|ID_LIKE|LOGO|VARIANT)=' /etc/os-release
grep -E '^(icon|Image)=' /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc   # ci-os-logo, file:///usr/share/wallpapers/companion/...
grep -E '^ColorScheme=' /etc/skel/.config/kdeglobals                                  # CI-OS-Dark
test -d /usr/share/plymouth/themes/companion-os && grep -E '^Theme=' /etc/plymouth/plymouthd.conf
grep -E '^GRUB_(THEME|DISTRIBUTOR)=' /etc/default/grub
```

`backends/cachyos/iso/tests/overlay-image-check.sh <root>` runs the identity part of these against any root
directory (an unpacked squashfs, the mkarchiso work tree, a mounted target).

## Not covered here (installer overlay or follow-up)

The Calamares branding component, the installer launcher, the welcome checks and the `cachyos-hello` gate, Limine
(its entry name is hard-coded in Calamares' Python; the overlay forces GRUB), the Firefox "for Arch Linux" about
string, and CachyOS-named applications that remain installed (`cachyos-kernel-manager`, `cachyos-packageinstaller`,
`cachy-update`). The kernel keeps its name (`linux-cachyos`, `uname -r` ends in `-cachyos`): it is the base's kernel and
is disclosed rather than hidden.
