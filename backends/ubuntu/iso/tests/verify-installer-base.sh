#!/usr/bin/env bash
#=============================================================================
# Test: verify-iso.sh section 3g ("Installer base layer is clean") fails on every defect it is there to catch
#
# The installer copies casper/minimal.squashfs to the disk and nothing else. The stock ISO keeps everything that
# belongs to the live session alone (the casper package, the live dconf overrides, the installer's own snap) in a
# separate layer, minimal.standard.live.squashfs, that the installer never installs. A base layer that carries it
# gives the installed system casper's initramfs hook: every initrd regenerated on the disk then boots the live
# medium and the machine stops at "Unable to find a medium containing a live file system".
# docs/architecture/ubuntu-iso-layers.md has the story; section 3g of verify-iso.sh asserts:
#
#   base layer   no casper file or package, no live dconf override, no installer-snap desktop entry, AppArmor
#                profile, mount unit or seed entry, none of the other live-image files in its table (the polkit rule and the
#                AppArmor sysctl file of 26.04.1's live layer, the TPM-encryption snapd seed, a snap file its seed.yaml does not
#                name); initramfs-tools installed, no dracut, dracut pinned out; the ISO pool's cdrom.sources still there;
#   live layer   not a placeholder: casper's files, a dpkg status that lists casper, its .size true; no wants link or autostart entry that opens
#                Canonical's installer window by itself (it would open in front of the Companion one-click dialog);
#   standard     still the empty placeholder;
#   metadata     the .size, .manifest and .manifest.full files describe the layers this image has, and /casper holds the
#                three layers' twelve files and no stock language or enhanced-secureboot file;
#   install      install-sources.yaml is the version 2 mapping with the stock kernel: block, naming a kernel package the
#                base layer has (section 3d);
#   boot menus   the kernel lines are the stock ones (and, given VERIFY_BASE_ISO, the base ISO's).
#
# This test builds a small image (real squashfs layers in a real ISO, the shapes `unsquashfs -ll` and xorriso give
# for the real one), runs the WHOLE verify-iso.sh on it and reads only the lines of section 3g, and of 3d for the variants
# named sources-* and casper-* (and, for the re-pointed casper.conf checks, the lines with their labels). The other sections
# fail on such a small image, by design. It expects
#
#   good                   no FAIL in section 3g, PASS lines from every group (so a section that did not run cannot pass);
#   every other variant    the one FAIL line it is meant to produce (one defect each, matched by its text, so a
#                          variant cannot be rejected for some other reason).
#
# Needs xorriso, squashfs-tools (mksquashfs, unsquashfs), zstd, cpio, python3 and GNU coreutils, awk and du;
# run it in a throw-away container, with the repo mounted read-only, e.g.
#
#   docker run --rm -v "$PWD:/repo:ro" <ubuntu image with xorriso squashfs-tools zstd cpio python3> \
#       bash /repo/backends/ubuntu/iso/tests/verify-installer-base.sh
#
# VERIFY_TEST_ONLY="good base-casper-conf" runs just those variants. About 1 s per variant.
# VERIFY_ISO_SCRIPT=<path> runs the variants against another copy of verify-iso.sh. That is how the test itself is tested:
# a copy with one check weakened (the forbidden-path loop disabled, the kernel-line test always true, ...) must make the
# variants that depend on it misbehave.
# VERIFY_TEST_VERBOSE=1 prints every FAIL line of section 3g for each variant (a variant should produce its own line and,
# at most, the ones that follow from the same defect).
# Exit status is non-zero if any expectation fails; 2 if it cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
VERIFY="${VERIFY_ISO_SCRIPT:-$REPO/backends/ubuntu/iso/scripts/verify-iso.sh}"   # another copy of it: see "weakened copies" below

for t in xorriso mksquashfs unsquashfs zstd cpio python3 awk du sed; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t (apt-get install xorriso squashfs-tools zstd cpio python3)" >&2; exit 2; }
done
[[ -f "$VERIFY" ]] || { echo "run it from the repo checkout" >&2; exit 2; }
# unmkinitramfs (initramfs-tools-core) unpacks the stock part of the fixture initrd for section 7's plymouthd.conf check; without it verify-iso.sh skips that
# check (and says so under SKIPPED), so the variants that need it are left out here and said so.
HAVE_UNMK=0; command -v unmkinitramfs >/dev/null 2>&1 && HAVE_UNMK=1
FIXTURE_VOLID='Ubuntu 26.04.1 LTS amd64'   # the volume id of the base ISO and of the good image: the signed GRUB and casper find the medium by it
BRANDED_BLOB="$REPO/backends/ubuntu/packages/ci-os-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
[[ -f "$BRANDED_BLOB" ]] || { echo "the branded gresource is not in the checkout: $BRANDED_BLOB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-installer-base.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── the good image ───────────────────────────────────────────────────────────────────────────────────────────────
# Three trees (base, standard placeholder, live delta), the casper metadata files and the two boot menus.

status_para() { # status_para <package> <version> [state]
    printf 'Package: %s\nStatus: %s\nPriority: optional\nArchitecture: amd64\nVersion: %s\nDescription: fixture\n\n' \
        "$1" "${3:-install ok installed}" "$2"
}
manifest_file() { # manifest_file <name of the lower layer> <name of this layer> <package<TAB>version lines...>
    local lower="$1" this="$2"; shift 2
    printf -- '--- /build/livecd.ubuntu.%s.manifest.full\t2026-09-14 19:24:22.933962140 +0000\n' "$lower"
    printf -- '+++ /build/livecd.ubuntu.%s.manifest.full\t2026-09-14 19:28:02.198865252 +0000\n' "$this"
    local l; for l in "$@"; do printf '+%s\n' "$l"; done
}
mk_layer_root() { # the three directories every layer carries, modes as the rootfs has them
    local d="$1"
    mkdir -p "$d/etc" "$d/var" "$d/tmp"
    chmod 755 "$d" "$d/etc" "$d/var"; chmod 1777 "$d/tmp"
}

make_upstream_gresource() { # make_upstream_gresource <out>: gnome-shell-common's theme, the stylesheets the built-in session modes load (a real gresource where glib-compile-resources exists)
    local out="$1" d="$WORK/gres-src.$$"
    rm -rf "$d"; mkdir -p "$d"
    printf '/* light */\n' > "$d/gnome-shell-light.css"; printf '/* dark */\n' > "$d/gnome-shell-dark.css"; printf '/* contrast */\n' > "$d/gnome-shell-high-contrast.css"
    if command -v glib-compile-resources >/dev/null 2>&1; then
        printf '<?xml version="1.0"?>\n<gresources><gresource prefix="/org/gnome/shell/theme"><file>gnome-shell-light.css</file><file>gnome-shell-dark.css</file><file>gnome-shell-high-contrast.css</file></gresource></gresources>\n' > "$d/t.gresource.xml"
        glib-compile-resources --sourcedir="$d" --target="$out" "$d/t.gresource.xml" || return 1
    else
        printf 'GVariant fixture: /org/gnome/shell/theme/gnome-shell-light.css gnome-shell-dark.css gnome-shell-high-contrast.css\n' > "$out"
    fi
    rm -rf "$d"
}
add_base_extras() { # add_base_extras <base dir>: what the sections after 3g read from the base layer, shaped like the real files
    local b="$1" t=usr/share/plymouth/themes f
    # the one-click launcher's desktop entry: it is in usr/share/ci-os, which the extraction list of verify-iso.sh once left out (a good image failed its two checks)
    mkdir -p "$b/usr/share/ci-os/live"
    printf '[Desktop Entry]\nType=Application\nName=Install Companion OS (automatic)\nExec=/usr/libexec/ci-os/ci-os-auto-install\n' > "$b/usr/share/ci-os/live/ci-os-auto-install.desktop"
    # the release the live system says it is: the /.disk/info chain compares the installer snap's channel with it
    printf 'DISTRIB_ID=Ubuntu\nDISTRIB_RELEASE=26.04\nDISTRIB_CODENAME=resolute\nDISTRIB_DESCRIPTION="Companion OS 26.04.1 LTS"\n' > "$b/etc/lsb-release"
    # the five Plymouth files the build diverts: the diversions database (three lines per entry) and the .ubuntu-stock copies. The stock copy of
    # spinner/watermark.png is a SYMLINK, as on 26.04.1 (-> ../../../pixmaps/ubuntu-logo-text-dark.png): `unsquashfs -ll` ends its line in " -> target"
    mkdir -p "$b/$t/spinner" "$b/$t/bgrt" "$b/$t/ubuntu-text" "$b/var/lib/dpkg"
    : > "$b/var/lib/dpkg/diversions"
    for f in spinner/bgrt-fallback.png spinner/watermark.png bgrt/bgrt.plymouth spinner/spinner.plymouth ubuntu-text/ubuntu-text.plymouth.in; do
        printf '/%s/%s\n/%s/%s.ubuntu-stock\n:\n' "$t" "$f" "$t" "$f" >> "$b/var/lib/dpkg/diversions"
        if [[ "$f" == spinner/watermark.png ]]; then ln -s ../../../pixmaps/ubuntu-logo-text-dark.png "$b/$t/$f.ubuntu-stock"
        else printf 'stock %s\n' "$f" > "$b/$t/$f.ubuntu-stock"; fi
    done
    # the GNOME Shell theme: the Yaru file the Ubuntu session and the greeter load carries the branded blob (the checkout's own), the top-level file is the
    # upstream theme with its stylesheets, and the greeter's gdm-theme.gresource leads to the Yaru file through /etc/alternatives, as on 26.04.1
    mkdir -p "$b/usr/share/gnome-shell/theme/Yaru" "$b/etc/alternatives"
    cp "$BRANDED_BLOB" "$b/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
    make_upstream_gresource "$b/usr/share/gnome-shell/gnome-shell-theme.gresource" || return 1
    ln -s /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource "$b/etc/alternatives/gdm-theme.gresource"
    ln -s /etc/alternatives/gdm-theme.gresource "$b/usr/share/gnome-shell/gdm-theme.gresource"
}
make_fixture_initrd() { # make_fixture_initrd <out> <plymouthd.conf text, or NONE for no file> [omit-text-theme]
    # An initrd shaped the way section 7 reads it: Ubuntu 26.04.1's stock part as far as that section looks (default.plymouth -> bgrt, a plymouthd.conf, a
    # two-step plugin that mentions UseFirmwareBackground; one zstd cpio, which is what unmkinitramfs unpacks), then the Companion OS overlay appended the way
    # build-iso.sh's brand_boot_media does it: NUL padding to 4 bytes, then one zstd cpio frame to the end of the file.
    local out="$1" conf="$2" omit="${3:-}" r="$WORK/fi-root" o="$WORK/fi-overlay" t=usr/share/plymouth/themes size pad
    rm -rf "$r" "$o"
    mkdir -p "$r/$t/bgrt" "$r/etc/plymouth" "$r/usr/lib/x86_64-linux-gnu/plymouth" "$o/$t/bgrt" "$o/$t/spinner" "$o/$t/ubuntu-text" "$o/etc"
    ln -s /usr/share/plymouth/themes/bgrt/bgrt.plymouth "$r/$t/default.plymouth"
    printf '[Plymouth Theme]\nName=BGRT\n' > "$r/$t/bgrt/bgrt.plymouth"
    if [[ "$conf" != NONE ]]; then printf '%s' "$conf" > "$r/etc/plymouth/plymouthd.conf"; fi
    printf 'two-step plugin: UseFirmwareBackground\n' > "$r/usr/lib/x86_64-linux-gnu/plymouth/two-step.so"
    printf 'export USERNAME="ubuntu"\n' > "$r/etc/casper.conf"
    ( cd "$r" && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc -R 0:0 ) | zstd -q -3 > "$out" || return 1
    printf 'export USERNAME="companion"\nexport HOST="companion-os"\nexport BUILD_SYSTEM="Ubuntu"\nexport FLAVOUR="Companion"\n' > "$o/etc/casper.conf"
    printf '[Plymouth Theme]\nName=BGRT\n' > "$o/$t/bgrt/bgrt.plymouth"; printf '[Plymouth Theme]\nName=Spinner\n' > "$o/$t/spinner/spinner.plymouth"
    printf 'watermark\n' > "$o/$t/spinner/watermark.png"; printf 'fallback\n' > "$o/$t/spinner/bgrt-fallback.png"
    if [[ "$omit" != omit-text-theme ]]; then printf '[Plymouth Theme]\nName=Companion OS Text\nModuleName=ubuntu-text\n\n[ubuntu-text]\ntitle=Companion OS 7.3\nblack=0x0b1d33\n' > "$o/$t/ubuntu-text/ubuntu-text.plymouth"; fi
    size="$(wc -c < "$out" | tr -d ' ')"; pad=$(( (4 - size % 4) % 4 ))
    if (( pad > 0 )); then head -c "$pad" /dev/zero >> "$out"; fi
    ( cd "$o" && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc -R 0:0 ) | zstd -q -19 >> "$out"
    rm -rf "$r" "$o"
}

build_good() { # build_good <dir>: dir/{base,standard,live}, dir/meta, dir/iso-tree
    local g="$1" b="$1/base" s="$1/standard" l="$1/live" m="$1/meta" i
    mk_layer_root "$b"; mk_layer_root "$s"; mk_layer_root "$l"; mkdir -p "$m"
    rmdir "$l/tmp"   # a live delta has /tmp only if something under it changed; the layers below provide it

    # base: the installed system (a dpkg database without casper, a snapd seed with one snap that is there)
    mkdir -p "$b/var/lib/dpkg/info" "$b/var/lib/snapd/seed/snaps" "$b/usr/share/glib-2.0/schemas" "$b/etc/dconf/db/local.d" "$b/usr/lib/ci-os"
    # (initramfs-tools stays in the base: the installed system is initramfs-tools based, see build-iso.sh; linux-generic-hwe-24.04 is the
    # kernel meta-package 26.04.1's install-sources.yaml names)
    { status_para base-files 14ubuntu1; status_para bash 5.3-2ubuntu1; status_para docker-ce 5:27.3.1-1; status_para setup-device 1.0.0
      status_para initramfs-tools 0.151ubuntu1; status_para linux-generic-hwe-24.04 7.0.0.30.30; } > "$b/var/lib/dpkg/status"
    printf '/etc/hostname\n' > "$b/var/lib/dpkg/info/base-files.list"
    printf 'companion-os\n' > "$b/etc/hostname"
    printf 'snaps:\n  - name: firefox\n    channel: stable/ubuntu-26.04\n    file: firefox_6000.snap\n' > "$b/var/lib/snapd/seed/seed.yaml"
    # a snap blob is one inode under two names, in seed/snaps and in snaps (26.04.1's layers, and mksquashfs keeps the link): the size
    # check has to count it once (a link that the size formula forgot would put the layer's .size below the lower bound)
    mkdir -p "$b/var/lib/snapd/snaps"
    head -c 3000000 /dev/zero | tr '\0' 's' > "$b/var/lib/snapd/seed/snaps/firefox_6000.snap"
    ln "$b/var/lib/snapd/seed/snaps/firefox_6000.snap" "$b/var/lib/snapd/snaps/firefox_6000.snap"
    # the pin that keeps apt from swapping initramfs-tools for dracut, and the ISO pool's apt source (subiquity 26.04 expects it in the layer)
    mkdir -p "$b/etc/apt/preferences.d" "$b/etc/apt/sources.list.d"
    printf 'Package: dracut dracut-core\nPin: release *\nPin-Priority: -1\n' > "$b/etc/apt/preferences.d/ci-os-no-dracut"
    printf 'Types: deb\nURIs: file:///cdrom\nSuites: resolute\nComponents: main restricted\nCheck-Date: no\n' > "$b/etc/apt/sources.list.d/cdrom.sources"
    printf '{"data": {"snaps": {"firefox": {"type": "app"}}}}\n' > "$b/var/lib/snapd/state.json"
    printf '[org.gnome.desktop.background]\npicture-uri=%s\n' "'file:///usr/share/backgrounds/companion.png'" > "$b/usr/share/glib-2.0/schemas/90_companion-wallpaper.gschema.override"
    printf 'payload\n' > "$b/usr/lib/ci-os/payload"
    # mdadm stays in the base and ships a hook for finalrd, which does not: /usr/share/finalrd is the kept package's directory
    # (found on the first image built with the split; a row for the whole directory had flagged it)
    mkdir -p "$b/usr/share/finalrd"; printf '#!/bin/sh\n' > "$b/usr/share/finalrd/mdadm.finalrd"
    mkdir -p "$b/etc/cloud" "$b/usr/lib/systemd"
    printf 'users:\n  - default\n' > "$b/etc/cloud/cloud.cfg"                       # the stock file: no installer user
    printf '#!/bin/sh\nexit 0\n' > "$b/usr/lib/systemd/systemd-networkd-wait-online"; chmod 755 "$b/usr/lib/systemd/systemd-networkd-wait-online"   # the real binary
    head -c 40000 /dev/zero | tr '\0' 'x' > "$b/usr/lib/ci-os/big"

    # live: what must be stacked on the base to get the merged rootfs: casper and the live-image files, and the whole
    # dpkg database of the merged rootfs (its status file is the merged one)
    mkdir -p "$l/usr/lib/casper" "$l/usr/lib/systemd/system" "$l/etc/systemd/system/multi-user.target.wants" \
             "$l/usr/share/initramfs-tools/scripts/casper-bottom" "$l/usr/share/initramfs-tools/hooks" \
             "$l/var/lib/dpkg/info" "$l/usr/share/glib-2.0/schemas" "$l/var/lib/snapd/desktop/applications" \
             "$l/var/lib/snapd/seed/snaps" "$l/etc/subiquity" "$l/etc/initramfs-tools/conf.d" "$l/usr/lib/systemd/user" "$l/etc/cloud"
    printf '[Unit]\nDescription=finalrd\n' > "$l/usr/lib/systemd/system/finalrd.service"
    printf 'export CASPER_GENERATE_UUID=1\n' > "$l/etc/initramfs-tools/conf.d/casperize.conf"
    printf '[Unit]\nDescription=installer\n' > "$l/usr/lib/systemd/user/ubuntu-desktop-installer.service"
    printf 'users:\n  - name: installer\n    shell: /usr/bin/subiquity-shell\n' > "$l/etc/cloud/cloud.cfg"                     # the live session's file
    printf '#!/bin/sh\nexit 0\n' > "$l/usr/lib/casper/casper-md5check"; chmod 755 "$l/usr/lib/casper/casper-md5check"
    printf '[Unit]\nDescription=casper\n' > "$l/usr/lib/systemd/system/casper.service"
    printf '[Unit]\nDescription=casper md5 check\n' > "$l/usr/lib/systemd/system/casper-md5check.service"
    ln -s /usr/lib/systemd/system/casper-md5check.service "$l/etc/systemd/system/multi-user.target.wants/casper-md5check.service"
    printf 'script\n' > "$l/usr/share/initramfs-tools/scripts/casper"
    printf 'script\n' > "$l/usr/share/initramfs-tools/scripts/casper-bottom/25adduser"
    printf '#!/bin/sh\n' > "$l/usr/share/initramfs-tools/hooks/casper"; chmod 755 "$l/usr/share/initramfs-tools/hooks/casper"
    printf '/usr/lib/casper/casper-md5check\n' > "$l/var/lib/dpkg/info/casper.list"
    printf 'export USERNAME="companion"\nexport HOST="companion-os"\nexport BUILD_SYSTEM="Ubuntu"\nexport FLAVOUR="Companion OS"\n' > "$l/etc/casper.conf"
    printf 'export LAYERFS_PATH=minimal.standard.live.squashfs\n' > "$l/etc/initramfs-tools/conf.d/default-layer.conf"
    printf '[org.gnome.desktop.screensaver]\nlock-enabled=false\n' > "$l/usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override"
    printf '[Desktop Entry]\nName=Install\n' > "$l/var/lib/snapd/desktop/applications/ubuntu-desktop-bootstrap_ubuntu-desktop-bootstrap.desktop"
    printf 'fixture snap\n' > "$l/var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_665.snap"
    printf 'snaps:\n  - name: firefox\n    file: firefox_6000.snap\n  - name: ubuntu-desktop-bootstrap\n    channel: 26.04/stable/ubuntu-26.04.1\n    file: ubuntu-desktop-bootstrap_665.snap\n' > "$l/var/lib/snapd/seed/seed.yaml"
    # what 26.04.1's live layer has beyond 24.04's: the polkit rule and the sysctl file for the installer. (It also has the TPM-encryption snapd
    # seed, seed/systems/enhanced-secureboot-desktop and the pc-kernel, pc and second firefox snap files: build-iso.sh's remove_esb_seed takes it
    # out of the rootfs before the split, so the image under test has none; the live-esb-* variants plant it again.)
    mkdir -p "$l/etc/polkit-1/rules.d" "$l/etc/sysctl.d"
    printf '// ONLY AVAILABLE ON THE LIVE SYSTEM\npolkit.addRule(function() {});\n' > "$l/etc/polkit-1/rules.d/10-allow-installer-wait-on-snap.rules"
    printf 'kernel.apparmor_restrict_unprivileged_userns = 0\n' > "$l/etc/sysctl.d/20-apparmor.conf"
    { cat "$b/var/lib/dpkg/status"; status_para casper 1.498; status_para finalrd 0.3; } > "$l/var/lib/dpkg/status"
    head -c 90000 /dev/zero | tr '\0' 'y' > "$l/usr/lib/casper/data"

    add_base_extras "$b"

    # metadata: sizes as `du -sx --block-size=1` of each tree, manifests in the stock "diff" shape
    for i in "base:minimal" "standard:minimal.standard" "live:minimal.standard.live"; do
        du -sx --block-size=1 "$g/${i%%:*}" | cut -f1 > "$m/${i##*:}.size"
    done
    manifest_file "" minimal "base-files	14ubuntu1" "bash	5.3-2ubuntu1" "docker-ce	5:27.3.1-1" "initramfs-tools	0.151ubuntu1" "linux-generic-hwe-24.04	7.0.0.30.30" "setup-device	1.0.0" > "$m/minimal.manifest"
    manifest_file minimal minimal.standard > "$m/minimal.standard.manifest"
    manifest_file minimal.standard minimal.standard.live "casper	1.498" "finalrd	0.3" "snap:ubuntu-desktop-bootstrap	26.04/stable/ubuntu-26.04.1	665" > "$m/minimal.standard.live.manifest"
    # the full manifests: the stack up to each layer, packages then snaps
    printf 'base-files\t14ubuntu1\nbash\t5.3-2ubuntu1\ndocker-ce\t5:27.3.1-1\ninitramfs-tools\t0.151ubuntu1\nlinux-generic-hwe-24.04\t7.0.0.30.30\nsetup-device\t1.0.0\nsnap:firefox\tstable/ubuntu-26.04\t6000\n' > "$m/minimal.manifest.full"
    cp "$m/minimal.manifest.full" "$m/minimal.standard.manifest.full"
    # install-sources.yaml as the build writes it: the version 2 mapping, the stock kernel: block, both entries, no variations but the two layers
    cat > "$m/install-sources.yaml" <<'EOF_IS'
kernel:
  default: linux-generic-hwe-24.04
sources:
- default: true
  description:
    en: Companion OS (minimized)
  id: ubuntu-desktop-minimal
  locale_support: langpack
  name:
    en: Companion OS (minimized)
  path: minimal.squashfs
  preinstalled_langs: []
  size: 1
  type: fsimage-layered
  variant: desktop
  variations:
    minimal:
      path: minimal.squashfs
      size: 1
- default: false
  description:
    en: Companion OS
  id: ubuntu-desktop
  locale_support: langpack
  name:
    en: Companion OS
  path: minimal.standard.squashfs
  preinstalled_langs: []
  size: 1
  type: fsimage-layered
  variant: desktop
  variations:
    standard:
      path: minimal.standard.squashfs
      size: 1
version: 2
EOF_IS
    printf 'base-files\t14ubuntu1\nbash\t5.3-2ubuntu1\ncasper\t1.498\ndocker-ce\t5:27.3.1-1\nfinalrd\t0.3\ninitramfs-tools\t0.151ubuntu1\nlinux-generic-hwe-24.04\t7.0.0.30.30\nsetup-device\t1.0.0\nsnap:firefox\tstable/ubuntu-26.04\t6000\nsnap:ubuntu-desktop-bootstrap\t26.04/stable/ubuntu-26.04.1\t665\n' > "$m/minimal.standard.live.manifest.full"

    # boot menus as the build leaves them: the stock kernel lines, plus the automatic-install copy of the first entry
    mkdir -p "$g/menus"
    cat > "$g/menus/grub.cfg" <<'EOF'
set timeout=30
loadfont unicode
if loadfont unicode ; then
  set gfxmode=auto
  insmod gfxterm
  insmod png
  terminal_output gfxterm
  background_image /boot/grub/ci-os-bg.png
fi
menuentry "Try or Install Companion OS" {
	set gfxpayload=keep
	linux	/casper/vmlinuz  --- quiet splash
	initrd	/casper/initrd
}
menuentry "Install Companion OS (automatic)" {
	set gfxpayload=keep
	linux	/casper/vmlinuz  ci.autoinstall=1 --- quiet splash
	initrd	/casper/initrd
}
menuentry "Companion OS (safe graphics)" {
	set gfxpayload=keep
	linux	/casper/vmlinuz nomodeset  --- quiet splash
	initrd	/casper/initrd
}
EOF
    cat > "$g/menus/loopback.cfg" <<'EOF'
menuentry "Try or Install Companion OS" {
	set gfxpayload=keep
	linux	/casper/vmlinuz  iso-scan/filename=${iso_path} --- quiet splash
	initrd	/casper/initrd
}
menuentry "Companion OS (safe graphics)" {
	set gfxpayload=keep
	linux	/casper/vmlinuz nomodeset  iso-scan/filename=${iso_path} --- quiet splash
	initrd	/casper/initrd
}
EOF
    # the signed GRUB the ISO boots through shim (/EFI/boot/grubx64.efi): a synthetic image whose built-in modules are the ones of
    # Ubuntu 26.04.1's CD image that matter to the live menu (efi_gop, gfxterm, jpeg, png, video, video_fb) and, as there, NOT all_video
    mkdir -p "$g/efi"
    python3 -I "$HERE/lib/make-grub-image.py" "$g/efi/grubx64.efi" efi_gop gfxterm jpeg png video video_fb || return 1
    # (verify-iso.sh extracts the three EFI files with one xorriso command, which stops at the first one that is missing)
    printf 'shim\n' > "$g/efi/bootx64.efi"; printf 'mok manager\n' > "$g/efi/mmx64.efi"
    # /.disk/info as build-iso.sh writes it (the product spelt Companion OS), the volume id (the base ISO's, untouched), the initrd with its overlay
    printf 'Companion OS 26.04.1 LTS "Fixture" - Release amd64 (20260826)\n' > "$g/disk-info"
    printf '%s\n' "$FIXTURE_VOLID" > "$g/volid"
    make_fixture_initrd "$g/initrd" $'# Administrator customizations go in this file\n#[Daemon]\n' || return 1   # (26.04.1's own plymouthd.conf: comments only)
}

# pack <good dir> <out dir> <menus dir> [base ISO]: the three squashfs layers, the metadata and the menus into an ISO
pack_iso() {
    local g="$1" o="$2" t="$2/tree" volid
    volid="$(cat "$g/volid")"
    mkdir -p "$t/casper" "$t/boot/grub" "$t/.disk"
    mksquashfs "$g/base" "$t/casper/minimal.squashfs" -comp gzip -noappend -no-recovery -quiet >/dev/null 2>&1 || return 1
    mksquashfs "$g/standard" "$t/casper/minimal.standard.squashfs" -comp gzip -noappend -no-recovery -quiet >/dev/null 2>&1 || return 1
    mksquashfs "$g/live" "$t/casper/minimal.standard.live.squashfs" -comp gzip -noappend -no-recovery -quiet >/dev/null 2>&1 || return 1
    local f; for f in "$g"/meta/*; do cp "$f" "$t/casper/"; done
    cp "$g/menus/grub.cfg" "$g/menus/loopback.cfg" "$t/boot/grub/"
    if [[ -d "$g/efi" ]]; then mkdir -p "$t/EFI/boot"; cp "$g"/efi/* "$t/EFI/boot/"; fi
    cp "$g/disk-info" "$t/.disk/info"
    cp "$g/initrd" "$t/casper/initrd"
    xorriso -as mkisofs -r -V "$volid" -o "$o/image.iso" "$t" >/dev/null 2>&1
}

# ── the variants: one defect each ────────────────────────────────────────────────────────────────────────────────
# mutate <variant> <dir>: edit the trees, the metadata or the menus under <dir>. Prints the text the FAIL line must contain.
plant() { # plant <tree> <relative path>: a file at that path (parents created)
    mkdir -p "$1/$(dirname "$2")"; echo x > "$1/$2"
}
mutate() {
    local v="$1" g="$2" b="$2/base" s="$2/standard" l="$2/live" m="$2/meta" mn="$2/menus"
    case "$v" in
        good) ;;
        # the casper package and its files in the base
        base-casper-conf)        cp "$l/etc/casper.conf" "$b/etc/casper.conf"; echo "base layer ships /etc/casper.conf" ;;
        base-casperize)          plant "$b" etc/initramfs-tools/conf.d/casperize.conf; echo "base layer ships casper initramfs configuration" ;;
        base-default-layer)      plant "$b" etc/initramfs-tools/conf.d/default-layer.conf; echo "base layer ships casper initramfs configuration" ;;
        base-initramfs-script)   plant "$b" usr/share/initramfs-tools/scripts/casper-bottom/25adduser; echo "base layer ships casper initramfs scripts and hook" ;;
        base-initramfs-hook)     plant "$b" usr/share/initramfs-tools/hooks/casper; echo "base layer ships casper initramfs scripts and hook" ;;
        base-usr-lib-casper)     plant "$b" usr/lib/casper/casper-md5check; echo "base layer ships casper programs, data and documentation" ;;
        base-sbin-casper)        plant "$b" usr/sbin/casper-getty; echo "base layer ships casper programs, data and documentation" ;;
        base-doc-casper)         plant "$b" usr/share/doc/casper/copyright; echo "base layer ships casper programs, data and documentation" ;;
        base-casper-unit)        plant "$b" usr/lib/systemd/system/casper-md5check.service; echo "base layer ships casper systemd units" ;;
        base-casper-enable-link) mkdir -p "$b/etc/systemd/system/final.target.wants"; ln -s /usr/lib/systemd/system/casper.service "$b/etc/systemd/system/final.target.wants/casper.service"; echo "base layer ships casper systemd units" ;;
        base-dpkg-list)          plant "$b" var/lib/dpkg/info/casper.list; echo "base layer ships casper dpkg file lists" ;;
        base-status-casper)      status_para casper 1.498 >> "$b/var/lib/dpkg/status"; echo "base layer's dpkg status lists the live-only package casper" ;;
        base-status-casper-rc)   status_para casper 1.498 "deinstall ok config-files" >> "$b/var/lib/dpkg/status"; echo "base layer's dpkg status lists the live-only package casper" ;;
        base-status-finalrd)     status_para finalrd 0.3 >> "$b/var/lib/dpkg/status"; echo "base layer's dpkg status lists the live-only package finalrd" ;;
        base-finalrd-file)       plant "$b" usr/lib/finalrd/finalrd-static.conf; echo "base layer ships finalrd" ;;
        base-finalrd-enable)     mkdir -p "$b/etc/systemd/system/sysinit.target.wants"; ln -s /usr/lib/systemd/system/finalrd.service "$b/etc/systemd/system/sysinit.target.wants/finalrd.service"; echo "base layer ships finalrd" ;;
        base-finalrd-doc)        plant "$b" usr/share/doc/finalrd/copyright; echo "base layer ships finalrd" ;;
        base-finalrd-unit)       plant "$b" usr/lib/systemd/system/finalrd.service; echo "base layer ships finalrd" ;;
        # the rest of the live image
        base-livecd-gschema)     plant "$b" usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override; echo "base layer ships live-session dconf overrides" ;;
        base-snap-desktop-entry) plant "$b" var/lib/snapd/desktop/applications/ubuntu-desktop-bootstrap_ubuntu-desktop-bootstrap.desktop; echo "base layer ships installer snap files, snapd state" ;;
        base-snap-apparmor)      plant "$b" var/lib/snapd/apparmor/profiles/snap.ubuntu-desktop-bootstrap.subiquity-server; echo "base layer ships installer snap files, snapd state" ;;
        base-polkit-rule)        plant "$b" etc/polkit-1/rules.d/10-allow-installer-wait-on-snap.rules; echo "base layer ships live-session security settings" ;;
        base-sysctl-apparmor)    plant "$b" etc/sysctl.d/20-apparmor.conf; echo "base layer ships live-session security settings" ;;
        base-display-manager)    plant "$b" etc/systemd/system/display-manager.service.d/wait-for-snapd-seeding.conf; echo "base layer ships live-session systemd settings" ;;
        base-snapd-reexec)       plant "$b" etc/systemd/system/snapd.service.d/snapd-snap-reexec.conf; echo "base layer ships live-session systemd settings" ;;
        base-esb-seed-system)    plant "$b" var/lib/snapd/seed/systems/enhanced-secureboot-desktop/model; echo "base layer ships the snapd seed of the TPM full-disk-encryption variant" ;;
        base-seed-orphan)        plant "$b" var/lib/snapd/seed/snaps/pc-kernel_3672.snap; echo "base layer's seed/snaps holds snap files that its seed.yaml does not name" ;;
        base-seed-orphan-comp)   plant "$b" 'var/lib/snapd/seed/snaps/pc-kernel+nvidia-590-uda-ko_90.comp'; echo "base layer's seed/snaps holds snap files that its seed.yaml does not name" ;;
        base-dracut)             status_para dracut 110-11 >> "$b/var/lib/dpkg/status"; echo "base layer's dpkg status lists dracut" ;;
        base-dracut-core)        status_para dracut-core 110-11 >> "$b/var/lib/dpkg/status"; echo "base layer's dpkg status lists dracut-core" ;;
        base-no-initramfs-tools) awk 'BEGIN { RS = ""; ORS = "\n\n" } $0 !~ /Package: initramfs-tools\n/' "$b/var/lib/dpkg/status" > "$b/var/lib/dpkg/status.x" && mv "$b/var/lib/dpkg/status.x" "$b/var/lib/dpkg/status"; echo "base layer: initramfs-tools is not installed" ;;
        base-pin-missing)        rm "$b/etc/apt/preferences.d/ci-os-no-dracut"; echo "ci-os-no-dracut is missing" ;;
        base-pin-weak)           printf 'Package: dracut dracut-core\nPin: release *\nPin-Priority: 100\n' > "$b/etc/apt/preferences.d/ci-os-no-dracut"; echo "does not pin to Pin-Priority -1: dracut dracut-core" ;;
        base-pin-partial)        printf 'Package: dracut\nPin: release *\nPin-Priority: -1\n' > "$b/etc/apt/preferences.d/ci-os-no-dracut"; echo "does not pin to Pin-Priority -1: dracut-core" ;;
        base-pin-no-pin-line)    printf 'Package: dracut dracut-core\nPin-Priority: -1\n' > "$b/etc/apt/preferences.d/ci-os-no-dracut"; echo "does not pin to Pin-Priority -1: dracut dracut-core" ;;
        ok-pin-with-install)     printf 'Package: dracut dracut-core dracut-install\nPin: release *\nPin-Priority: -1\n' > "$b/etc/apt/preferences.d/ci-os-no-dracut"; echo "(no failure expected: a pin file that lists dracut-install too is accepted)" ;;
        base-cdrom-missing)      rm "$b/etc/apt/sources.list.d/cdrom.sources"; echo "cdrom.sources is missing or is not the ISO pool's source" ;;
        base-cdrom-both)         cp "$b/etc/apt/sources.list.d/cdrom.sources" "$b/etc/apt/sources.list.d/cdrom.sources.disabled"; echo "a cdrom.sources.disabled is left over from the build's apt-get update" ;;
        base-cdrom-disabled)     mv "$b/etc/apt/sources.list.d/cdrom.sources" "$b/etc/apt/sources.list.d/cdrom.sources.disabled"; echo "cdrom.sources is missing or is not the ISO pool's source" ;;
        base-snap-update-ns)     plant "$b" var/lib/snapd/apparmor/profiles/snap-update-ns.ubuntu-desktop-bootstrap; echo "base layer ships installer snap files, snapd state" ;;
        base-snap-dir)           plant "$b" snap/ubuntu-desktop-bootstrap/current; echo "base layer ships installer snap files, snapd state" ;;
        base-ssh-hostkey)        plant "$b" etc/ssh/ssh_host_ed25519_key; echo "base layer ships SSH host keys, the same on every install" ;;
        base-ssh-hostkey-pub)    plant "$b" etc/ssh/ssh_host_rsa_key.pub; echo "base layer ships SSH host keys, the same on every install" ;;
        base-snap-bin)           plant "$b" snap/bin/ubuntu-desktop-bootstrap; echo "base layer ships installer snap files, snapd state" ;;
        base-snap-file)          plant "$b" var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_665.snap; echo "base layer ships installer snap files, snapd state" ;;
        ok-core24-in-base)       plant "$b" var/lib/snapd/snaps/core24_1643.snap; plant "$b" snap/core24/1643/x; printf 'snaps:\n  - name: firefox\n    file: firefox_6000.snap\n  - name: core24\n    file: core24_1643.snap\n' > "$b/var/lib/snapd/seed/seed.yaml"; plant "$b" var/lib/snapd/seed/snaps/core24_1643.snap; printf 'snap:core24\tstable\t1643\n' | tee -a "$m/minimal.manifest.full" >> "$m/minimal.standard.manifest.full"; echo "(no failure expected: core24 is the system's own base, the installer snap's base is shared with it)" ;;
        base-snap-mount-unit)    plant "$b" 'etc/systemd/system/snap-ubuntu\x2ddesktop\x2dbootstrap-680.mount'; echo "base layer ships installer snap mount units and service units" ;;
        base-snap-service)       plant "$b" etc/systemd/system/snap.ubuntu-desktop-bootstrap.subiquity-server.service; echo "base layer ships installer snap mount units and service units" ;;
        base-installer-service)  plant "$b" usr/lib/systemd/user/ubuntu-desktop-installer.service; echo "base layer ships installer user service" ;;
        base-installer-wants)    mkdir -p "$b/etc/systemd/user/graphical-session.target.wants"; ln -s ../../../../lib/systemd/user/ubuntu-desktop-installer.service "$b/etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service"; echo "base layer ships installer user service" ;;
        base-subiquity-kmp)      plant "$b" etc/subiquity/kernel-meta-package; echo "base layer ships subiquity live-session files" ;;
        base-subiquity-mount)    plant "$b" usr/lib/systemd/system/subiquity_config.mount; echo "base layer ships subiquity live-session files" ;;
        base-subiquity-dropin)   plant "$b" 'etc/systemd/system/dev-disk-by\x2duuid-1234.device.d/override.conf'; echo "base layer ships subiquity live-session files" ;;
        base-cloud-quiet)        plant "$b" etc/cloud/cloud.cfg.d/06_quiet.cfg; echo "base layer ships live-image cloud-init files" ;;
        base-cloud-nocloud)      plant "$b" var/lib/cloud/seed/nocloud/user-data; echo "base layer ships live-image cloud-init files" ;;
        base-apt-prefs-save)     plant "$b" etc/apt/preferences.d.save/preferences.d/ubuntu-pro-esm-apps; echo "base layer ships live-image apt preferences backup" ;;
        base-packages-chroot)    plant "$b" root/packages.chroot/x; echo "base layer ships live-image apt preferences backup" ;;
        base-getty-mask)         mkdir -p "$b/usr/lib/systemd/system"; ln -s /dev/null "$b/usr/lib/systemd/system/getty@tty1.service"; echo "base layer ships live-session systemd settings" ;;
        base-udisks-inhibit)     plant "$b" usr/lib/systemd/system/udisks2-inhibit.service; echo "base layer ships live-session systemd settings" ;;
        base-media-fs-link)      mkdir -p "$b/usr/lib/systemd/system/local-fs.target.wants"; ln -s ../media-filesystem.mount "$b/usr/lib/systemd/system/local-fs.target.wants/media-filesystem.mount"; echo "base layer ships live-session systemd settings" ;;
        base-journald-dropin)    plant "$b" etc/systemd/journald.conf.d/no-rate-limit.conf; echo "base layer ships live-session journald drop-ins" ;;
        base-cloud-cfg-live)     cp "$l/etc/cloud/cloud.cfg" "$b/etc/cloud/cloud.cfg"; echo "base layer's /etc/cloud/cloud.cfg is the live session's" ;;
        base-networkd-wait)      rm "$b/usr/lib/systemd/systemd-networkd-wait-online"; ln -s /bin/true "$b/usr/lib/systemd/systemd-networkd-wait-online"; echo "base layer's systemd-networkd-wait-online is the live session's symlink" ;;
        base-seed-installer)     printf 'snaps:\n  - name: ubuntu-desktop-bootstrap\n    file: ubuntu-desktop-bootstrap_680.snap\n' > "$b/var/lib/snapd/seed/seed.yaml"; echo "base layer's snapd seed.yaml names the installer snap" ;;
        base-seed-missing-file)  printf 'snaps:\n  - name: firefox\n    file: firefox_6000.snap\n  - name: snap-store\n    file: snap-store_1000.snap\n' > "$b/var/lib/snapd/seed/seed.yaml"; echo "names snap files that are not in the base layer: snap-store_1000.snap" ;;
        base-state-installer)    printf '{"data": {"snaps": {"ubuntu-desktop-bootstrap": {"type": "app"}}}}\n' > "$b/var/lib/snapd/state.json"; echo "base layer's snapd state.json knows the installer snap" ;;
        base-unreadable)         rm "$b/var/lib/dpkg/status"; echo "base layer: could not read its listing or var/lib/dpkg/status" ;;
        # the live layer
        live-placeholder)        rm -rf "$l"; mk_layer_root "$l"; du -sx --block-size=1 "$l" | cut -f1 > "$m/minimal.standard.live.size"; echo "live layer is an empty placeholder" ;;
        live-no-md5check)        rm -rf "$l/usr/lib/casper"; echo "[casper-md5check (the checker)]" ;;
        live-no-enable-link)     rm "$l/etc/systemd/system/multi-user.target.wants/casper-md5check.service"; echo "[the enable link of casper-md5check.service]" ;;
        live-no-hook)            rm "$l/usr/share/initramfs-tools/hooks/casper"; echo "[casper initramfs hook]" ;;
        live-no-unit)            rm "$l/usr/lib/systemd/system/casper-md5check.service"; echo "[casper-md5check.service (its unit)]" ;;
        live-no-script)          rm "$l/usr/share/initramfs-tools/scripts/casper"; echo "[casper initramfs script]" ;;
        live-no-casper-conf)     rm "$l/etc/casper.conf"; echo "[/etc/casper.conf]" ;;
        live-no-finalrd)         rm "$l/usr/lib/systemd/system/finalrd.service"; echo "[finalrd.service]" ;;
        live-no-casperize)       rm "$l/etc/initramfs-tools/conf.d/casperize.conf"; echo "[casper initramfs configuration (casperize.conf, default-layer.conf)]" ;;
        live-no-default-layer)   rm "$l/etc/initramfs-tools/conf.d/default-layer.conf"; echo "[default-layer.conf (the live initrd's layer path)]" ;;
        live-no-livecd-override) rm "$l/usr/share/glib-2.0/schemas/livecd-rootfs.gschema.override"; echo "[livecd-rootfs.gschema.override]" ;;
        live-no-installer-svc)   rm "$l/usr/lib/systemd/user/ubuntu-desktop-installer.service"; echo "[the installer's user service]" ;;
        # the live session opens Canonical's installer window by itself again (the stock layer's wants link, or an autostart entry for it)
        live-installer-wants)    mkdir -p "$l/etc/systemd/user/graphical-session.target.wants"; ln -s /usr/lib/systemd/user/ubuntu-desktop-installer.service "$l/etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service"; echo "live layer starts Canonical's installer window by itself" ;;
        live-installer-requires) mkdir -p "$l/usr/lib/systemd/user/default.target.requires"; ln -s ../ubuntu-desktop-installer.service "$l/usr/lib/systemd/user/default.target.requires/ubuntu-desktop-installer.service"; echo "live layer starts Canonical's installer window by itself" ;;
        live-installer-autostart) mkdir -p "$l/etc/xdg/autostart"; printf '[Desktop Entry]\nType=Application\nName=Installer\nExec=/snap/bin/ubuntu-desktop-bootstrap\n' > "$l/etc/xdg/autostart/ubuntu-desktop-bootstrap.desktop"; echo "live layer starts Canonical's installer window by itself" ;;
        live-no-installer-snap)  rm "$l/var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_665.snap"; echo "[the installer snap file in the seed]" ;;
        live-seed-no-installer)  printf 'snaps:\n  - name: firefox\n    file: firefox_6000.snap\n' > "$l/var/lib/snapd/seed/seed.yaml"; echo "live layer's snapd seed.yaml does not name the installer snap" ;;
        live-esb-seed-system)    plant "$l" var/lib/snapd/seed/systems/enhanced-secureboot-desktop/model; echo "live layer ships the snapd seed of the TPM full-disk-encryption variant" ;;
        live-esb-seed-orphan)    plant "$l" var/lib/snapd/seed/snaps/pc-kernel_3672.snap; echo "live layer's seed/snaps holds snap files that its seed.yaml does not name" ;;
        live-esb-seed-orphan-comp) plant "$l" 'var/lib/snapd/seed/snaps/pc-kernel+nvidia-590-uda-ko_90.comp'; echo "live layer's seed/snaps holds snap files that its seed.yaml does not name" ;;
        live-cloud-cfg-stock)    cp "$b/etc/cloud/cloud.cfg" "$l/etc/cloud/cloud.cfg"; echo "live layer does not carry the live session's /etc/cloud/cloud.cfg" ;;
        live-status-no-casper)   cp "$b/var/lib/dpkg/status" "$l/var/lib/dpkg/status"; echo "live layer's dpkg status does not list casper as installed" ;;
        live-status-casper-rc)   { cat "$b/var/lib/dpkg/status"; status_para casper 1.498 "deinstall ok config-files"; } > "$l/var/lib/dpkg/status"; echo "live layer's dpkg status does not list casper as installed" ;;
        live-conf-ubuntu-user)   sed -i 's/^export USERNAME=.*/export USERNAME="ubuntu"/' "$l/etc/casper.conf"; echo "live session user is not 'ubuntu'" ;;
        live-tmp-wrong-mode)     mkdir "$l/tmp"; chmod 755 "$l/tmp"; echo "layer minimal.standard.live: /tmp is drwxr-xr-x but the root layer has drwxrwxrwt" ;;
        live-root-mode)          chmod 700 "$l"; echo "layer minimal.standard.live: / (layer root) is drwx------ but the root layer has drwxr-xr-x" ;;
        standard-no-tmp)         rmdir "$s/tmp"; echo "layer minimal.standard: /tmp is missing, must be drwxrwxrwt" ;;
        standard-has-files)      echo x > "$s/etc/leftover"; echo "minimal.standard.squashfs holds 1 entries that are not directories" ;;
        # sizes
        size-live-zero)          echo 0 > "$m/minimal.standard.live.size"; echo "layer minimal.standard.live: .size is 0" ;;
        size-live-huge)          echo 11581571072 > "$m/minimal.standard.live.size"; echo "layer minimal.standard.live: .size is 11581571072" ;;
        size-live-garbage)       echo "about 2 GB" > "$m/minimal.standard.live.size"; echo "layer minimal.standard.live: its .size file is not a number" ;;
        size-live-missing)       rm "$m/minimal.standard.live.size"; echo "layer minimal.standard.live: its .size file is missing or empty" ;;
        size-base-wrong)         echo 1234 > "$m/minimal.size"; echo "layer minimal: .size is 1234" ;;
        size-standard-wrong)     echo 7777777777 > "$m/minimal.standard.size"; echo "layer minimal.standard: .size is 7777777777" ;;
        # manifests
        manifest-live-stock)     manifest_file minimal.standard minimal.standard.live "adcli	0.9.2-1ubuntu2" "zfsutils-linux	2.2.2-0ubuntu9.5" > "$m/minimal.standard.live.manifest"; echo "minimal.standard.live.manifest is not the live layer's package delta" ;;
        manifest-live-version)   manifest_file minimal.standard minimal.standard.live "casper	1.400" "finalrd	0.3" > "$m/minimal.standard.live.manifest"; echo "minimal.standard.live.manifest does not list casper at the version the live layer has" ;;
        manifest-live-empty)     : > "$m/minimal.standard.live.manifest"; echo "minimal.standard.live.manifest is missing or empty" ;;
        manifest-base-casper)    manifest_file "" minimal "base-files	14ubuntu1" "bash	5.3-2ubuntu1" "casper	1.498" "docker-ce	5:27.3.1-1" "initramfs-tools	0.151ubuntu1" "linux-generic-hwe-24.04	7.0.0.30.30" "setup-device	1.0.0" > "$m/minimal.manifest"; echo "minimal.manifest lists casper (the base layer has none)" ;;
        manifest-base-stale)     manifest_file "" minimal "base-files	14ubuntu1" > "$m/minimal.manifest"; echo "minimal.manifest is not the base layer's package list" ;;
        manifest-full-base-stale) printf 'adduser\t3.153ubuntu1\nsnap:firefox\tstable/ubuntu-26.04\t6000\n' > "$m/minimal.manifest.full"; echo "minimal.manifest.full is not the package list of the stack up to that layer" ;;
        manifest-full-std-stale) printf 'adduser\t3.153ubuntu1\n' > "$m/minimal.standard.manifest.full"; echo "minimal.standard.manifest.full is not the package list of the stack up to that layer" ;;
        manifest-full-live-base) cp "$m/minimal.manifest.full" "$m/minimal.standard.live.manifest.full"; echo "minimal.standard.live.manifest.full is not the package list of the stack up to that layer" ;;
        manifest-full-missing)   rm "$m/minimal.standard.live.manifest.full"; echo "minimal.standard.live.manifest.full is missing or empty" ;;
        manifest-full-snaps)     grep -v '^snap:' "$m/minimal.manifest.full" > "$m/minimal.manifest.full.x" && mv "$m/minimal.manifest.full.x" "$m/minimal.manifest.full"; echo "minimal.manifest.full's snap lines are not the snaps of that stack's seed.yaml" ;;
        manifest-base-missing)   rm "$m/minimal.manifest"; echo "minimal.manifest is missing or empty" ;;
        manifest-standard-missing) rm "$m/minimal.standard.manifest"; echo "minimal.standard.manifest is missing" ;;
        manifest-standard-stock) manifest_file minimal minimal.standard "deja-dup	45.2-1build2" > "$m/minimal.standard.manifest"; echo "minimal.standard.manifest still lists 1 package(s)" ;;
        # boot menus
        kernel-layerfs)          sed -i '0,/linux.*vmlinuz/s//linux\t\/casper\/vmlinuz layerfs-path=minimal.standard.live.squashfs/' "$mn/grub.cfg"; echo "grub.cfg: kernel line is not the stock one" ;;
        kernel-boot-casper)      sed -i 's#vmlinuz nomodeset  iso-scan#vmlinuz boot=casper nomodeset  iso-scan#' "$mn/loopback.cfg"; echo "loopback.cfg: kernel line is not the stock one" ;;
        kernel-extra-param)      sed -i 's/--- quiet splash/--- quiet splash vt.handoff=7/' "$mn/grub.cfg"; echo "grub.cfg: kernel line is not the stock one" ;;
        kernel-no-lines)         sed -i '/linux/d' "$mn/grub.cfg"; echo "grub.cfg: 0 kernel lines found" ;;
        kernel-vs-base)          # passes the allow-list, but drops the safe-graphics entry the base ISO has
                                 awk '/^menuentry "Companion OS \(safe graphics\)"/{skip=1} !skip{print} skip&&/^}/{skip=0}' "$mn/grub.cfg" > "$mn/grub.cfg.x" && mv "$mn/grub.cfg.x" "$mn/grub.cfg"
                                 echo "grub.cfg: the kernel lines differ from the base ISO's" ;;
        # section 3d: the installer's sources and the casper directory
        sources-list-form)       printf -- '- default: true\n  id: ubuntu-desktop-minimal\n  path: minimal.squashfs\n  preinstalled_langs: []\n- id: ubuntu-desktop\n  path: minimal.standard.squashfs\n  preinstalled_langs: []\n' > "$m/install-sources.yaml"; echo "install-sources.yaml is the version 2 mapping" ;;
        sources-no-kernel)       sed -i '/^kernel:/,/^sources:/{/^sources:/!d;}' "$m/install-sources.yaml"; echo "install-sources.yaml is the version 2 mapping" ;;
        sources-no-version)      sed -i '/^version: 2$/d' "$m/install-sources.yaml"; echo "install-sources.yaml is the version 2 mapping" ;;
        sources-kernel-absent)   sed -i 's/^  default: linux-generic-hwe-24.04$/  default: linux-generic/' "$m/install-sources.yaml"; echo "the kernel meta-package linux-generic that install-sources.yaml names is not installed in the base layer" ;;
        sources-kernel-vs-base)  sed -i 's/^  default: linux-generic-hwe-24.04$/  default: linux-image-generic-hwe-26.04/' "$m/install-sources.yaml"; status_para linux-image-generic-hwe-26.04 7.0.0.30.30 >> "$b/var/lib/dpkg/status"; echo "install-sources.yaml's kernel: block differs from the base ISO's" ;;
        sources-esb-variation)   awk '{print} /^      size: 1$/ && !d { print "    minimal-enhanced-secureboot:"; print "      path: minimal.enhanced-secureboot.squashfs"; print "      size: 1"; d = 1 }' "$m/install-sources.yaml" > "$m/install-sources.yaml.x" && mv "$m/install-sources.yaml.x" "$m/install-sources.yaml"; echo "install-sources.yaml still lists enhanced-secureboot variations" ;;
        sources-missing-layer)   sed -i 's#^  path: minimal.standard.squashfs$#  path: minimal.standard.zz.squashfs#' "$m/install-sources.yaml"; echo "install-sources.yaml names layers that are not on the ISO" ;;
        sources-langs)           sed -i '0,/^  preinstalled_langs: \[\]$/s//  preinstalled_langs:\n  - en/' "$m/install-sources.yaml"; echo "install-sources.yaml lists no preinstalled_langs" ;;
        casper-lang-layer)       : > "$m/minimal.de.squashfs"; : > "$m/minimal.de.size"; echo "stock language layers still on the ISO" ;;
        casper-esb-layer)        : > "$m/minimal.enhanced-secureboot.squashfs"; : > "$m/minimal.enhanced-secureboot.size"; echo "enhanced-secureboot files still in /casper" ;;
        casper-esb-lang-layer)   : > "$m/minimal.standard.enhanced-secureboot.en.manifest.full"; echo "enhanced-secureboot files still in /casper" ;;
        casper-stale-extra)      : > "$m/minimal.live.size"; echo "/casper's minimal* files are not the three layers' twelve" ;;
        casper-missing-size)     rm "$m/minimal.standard.size"; echo "/casper's minimal* files are not the three layers' twelve" ;;
        # section 9: the image against the smallest Stick boot slot (the limit comes from the environment, see the loop below)
        iso-over-limit)          echo "over 1000 (the 8 GiB boot slot of a 64 GB Companion Stick): ci-stick flash would refuse it" ;;
        iso-limit-garbage)       echo "VERIFY_MAX_ISO_BYTES is not a number: 'lots'" ;;
        ok-iso-limit-off)        echo "(no failure expected: VERIFY_MAX_ISO_BYTES=0 skips the size check)" ;;
        # section 2c: every insmod of the live menu against the module list of the signed GRUB on the ISO (EFI/boot/grubx64.efi).
        # all_video is not built into Ubuntu 26.04.1's GRUB 2.14 (the 24.04 image had it); under Secure Boot an insmod of it is refused.
        grub-insmod-all-video)   sed -i 's/^  insmod gfxterm$/  insmod all_video\n  insmod gfxterm/' "$mn/grub.cfg"; echo "NOT built into the signed GRUB on the ISO (all_video)" ;;
        grub-insmod-other)       sed -i 's/^  insmod gfxterm$/  insmod gfxterm\n  insmod jpeg/' "$mn/grub.cfg"; echo "grub.cfg insmod set is 'gfxterm jpeg png '" ;;
        grub-insmod-not-builtin) python3 -I "$HERE/lib/make-grub-image.py" "$g/efi/grubx64.efi" efi_gop gfxterm jpeg video video_fb; echo "NOT built into the signed GRUB on the ISO (png)" ;;
        grub-efi-unreadable)     echo "this is not a PE image" > "$g/efi/grubx64.efi"; echo "could not be read" ;;
        grub-efi-missing)        rm "$g/efi/grubx64.efi"; echo "/EFI/boot/grubx64.efi is missing from the ISO" ;;
        ok-grub-insmod-one-line) sed -i 's/^  insmod gfxterm$/  insmod gfxterm png/; /^  insmod png$/d' "$mn/grub.cfg"; echo "(no failure expected: two modules on one insmod line are the same set)" ;;
        # the sections after 3g, on the same fixture. Each variant is one defect; "ok-" ones are accepted spellings (a "PASS:<text>" says which PASS line must appear).
        # the one-click launcher (usr/share/ci-os; verify-iso.sh's extraction list once left that directory out, so a good image failed both checks)
        launcher-missing)        rm "$b/usr/share/ci-os/live/ci-os-auto-install.desktop"; echo "launcher .desktop missing or runs something else" ;;
        launcher-wrong-exec)     sed -i 's#^Exec=.*#Exec=/bin/true#' "$b/usr/share/ci-os/live/ci-os-auto-install.desktop"; echo "launcher .desktop missing or runs something else" ;;
        launcher-wrong-name)     sed -i 's/^Name=.*/Name=Install Ubuntu/' "$b/usr/share/ci-os/live/ci-os-auto-install.desktop"; echo "launcher has the wrong name" ;;
        # the Plymouth files the build diverts (section 7): the stock copy of spinner/watermark.png is a symlink on 26.04.1, which a match anchored at the end of the listing line missed
        ply-divert-no-entry)     awk 'NR % 3 == 1 { keep = ($0 !~ /spinner\/watermark\.png$/) } keep' "$b/var/lib/dpkg/diversions" > "$b/var/lib/dpkg/diversions.x" && mv "$b/var/lib/dpkg/diversions.x" "$b/var/lib/dpkg/diversions"
                                 echo "spinner/watermark.png is not dpkg-diverted to spinner/watermark.png.ubuntu-stock" ;;
        ply-divert-no-stock-link) rm "$b/usr/share/plymouth/themes/spinner/watermark.png.ubuntu-stock"; echo "spinner/watermark.png is not dpkg-diverted to spinner/watermark.png.ubuntu-stock" ;;
        ply-divert-no-stock-file) rm "$b/usr/share/plymouth/themes/spinner/bgrt-fallback.png.ubuntu-stock"; echo "spinner/bgrt-fallback.png is not dpkg-diverted to spinner/bgrt-fallback.png.ubuntu-stock" ;;
        ok-ply-stock-regular)    rm "$b/usr/share/plymouth/themes/spinner/watermark.png.ubuntu-stock"; printf 'stock\n' > "$b/usr/share/plymouth/themes/spinner/watermark.png.ubuntu-stock"
                                 echo "PASS:spinner/watermark.png is dpkg-diverted" ;;
        # exactly one session (26.04.1 has the one Wayland session, no Xorg)
        session-extra-xorg)      plant "$b" usr/share/xsessions/ubuntu-xorg.desktop; echo "other session files exist: /usr/share/xsessions/ubuntu-xorg.desktop" ;;
        session-extra-wayland)   plant "$b" usr/share/wayland-sessions/ubuntu-wayland.desktop; echo "other session files exist: /usr/share/wayland-sessions/ubuntu-wayland.desktop" ;;
        # section 4d: the GNOME Shell theme
        shell-yaru-missing)      rm "$b/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"; echo "gnome-shell-theme.gresource is missing (the Ubuntu session and the greeter have no theme)" ;;
        shell-yaru-other)        printf 'a recoloured theme of another checkout\n' > "$b/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"; echo "is not the branded blob of this checkout" ;;
        shell-yaru-stock)        printf 'the stock Yaru theme of the fixture\n' > "$b/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"; echo "is Ubuntu's stock Yaru theme, byte for byte" ;;
        shell-top-is-blob)       cp "$b/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource" "$b/usr/share/gnome-shell/gnome-shell-theme.gresource"; echo "lost gnome-shell-light.css gnome-shell-dark.css" ;;
        shell-top-no-light)      sed -i 's/gnome-shell-light\.css/gnome-shell-lxght.css/g' "$b/usr/share/gnome-shell/gnome-shell-theme.gresource"; echo "lost gnome-shell-light.css" ;;
        shell-top-missing)       rm "$b/usr/share/gnome-shell/gnome-shell-theme.gresource"; echo "(the upstream theme, gnome-shell-common's) is missing" ;;
        shell-gdm-alternative)   ln -sf /usr/share/gnome-shell/gnome-shell-theme.gresource "$b/etc/alternatives/gdm-theme.gresource"; echo "gdm-theme.gresource no longer leads, through /etc/alternatives" ;;
        shell-gdm-link-gone)     rm "$b/usr/share/gnome-shell/gdm-theme.gresource"; echo "gdm-theme.gresource no longer leads, through /etc/alternatives" ;;
        # section 5: /.disk/info (the product is spelt Companion OS; the installer's last page shows it), the volume id
        disk-info-hyphen)        printf 'Companion-OS 26.04.1 LTS "Fixture" - Release amd64 (20260826)\n' > "$g/disk-info"; echo "the product name before the codename is 'Companion-OS 26.04.1 LTS'" ;;
        disk-info-stock)         printf 'Ubuntu 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)\n' > "$g/disk-info"; echo "casper would label the installer launcher 'Install Ubuntu 26.04.1 LTS'" ;;
        disk-info-tight-quote)   printf 'Companion OS 26.04.1 LTS"Fixture" - Release amd64 (20260826)\n' > "$g/disk-info"; echo "/.disk/info starts with 'Companion OS', the release and LTS" ;;
        disk-info-no-serial)     printf 'Companion OS 26.04.1 LTS "Fixture" - Release amd64\n' > "$g/disk-info"; echo "/.disk/info keeps the (serial) suffix pollinate parses" ;;
        disk-info-guard-stable)  sed -i 's#channel: 26.04/stable/ubuntu-26.04.1#channel: stable/ubuntu-26.04#' "$l/var/lib/snapd/seed/seed.yaml"; echo "the installer snap tracks stable/ubuntu-26.04: subiquity's refresh.py would switch it to the channel stable/ubuntu-OS" ;;
        disk-info-guard-latest)  sed -i 's#channel: 26.04/stable/ubuntu-26.04.1#channel: latest/stable/ubuntu-26.04#' "$l/var/lib/snapd/seed/seed.yaml"; echo "the installer snap tracks latest/stable/ubuntu-26.04: subiquity's refresh.py would switch it to the channel stable/ubuntu-OS" ;;
        disk-info-guard-no-channel) sed -i '/channel: 26.04\/stable\/ubuntu-26.04.1/d' "$l/var/lib/snapd/seed/seed.yaml"; echo "cannot be read, so it is not shown that subiquity never acts on it" ;;
        disk-info-guard-no-lsb)  rm "$b/etc/lsb-release"; echo "cannot be read, so it is not shown that subiquity never acts on it" ;;
        volid-changed)           printf 'COMPANION_OS\n' > "$g/volid"; echo "the ISO volume id 'COMPANION_OS' is not the base ISO's" ;;
        sources-base-unreadable) echo "could not read /casper/install-sources.yaml from VERIFY_BASE_ISO" ;;   # (the loop below hands it a base ISO without that file)
        # section 7: the initrd (the overlay, and the stock part's plymouthd.conf; 26.04.1's has comments only)
        initrd-no-text-theme)    make_fixture_initrd "$g/initrd" $'# Administrator customizations go in this file\n#[Daemon]\n' omit-text-theme || return 1; echo "no ubuntu-text.plymouth in the initrd overlay" ;;
        initrd-plymouthd-other)  make_fixture_initrd "$g/initrd" $'[Daemon]\nTheme=spinner\n' || return 1; echo "the initrd's plymouthd.conf selects a theme other than bgrt: Theme=spinner" ;;
        initrd-plymouthd-empty)  make_fixture_initrd "$g/initrd" $'[Daemon]\nTheme=\n' || return 1; echo "the initrd's plymouthd.conf selects a theme other than bgrt: Theme=" ;;
        initrd-plymouthd-spaced) make_fixture_initrd "$g/initrd" $'[Daemon]\n  Theme = details  \n' || return 1; echo "the initrd's plymouthd.conf selects a theme other than bgrt: Theme=details" ;;
        initrd-plymouthd-second) make_fixture_initrd "$g/initrd" $'[Daemon]\nTheme=bgrt\nTheme=text\n' || return 1; echo "the initrd's plymouthd.conf selects a theme other than bgrt: Theme=text" ;;
        ok-initrd-plymouthd-bgrt) make_fixture_initrd "$g/initrd" $'[Daemon]\nTheme=bgrt\n' || return 1; echo "PASS:nothing in the initrd selects another Plymouth theme than bgrt (its plymouthd.conf says Theme=bgrt)" ;;
        ok-initrd-plymouthd-none) make_fixture_initrd "$g/initrd" NONE || return 1; echo "PASS:nothing in the initrd selects another Plymouth theme than bgrt (the initrd has no plymouthd.conf)" ;;
        ok-initrd-plymouthd-commented) make_fixture_initrd "$g/initrd" $'[Daemon]\n#Theme=spinner\n' || return 1; echo "PASS:nothing in the initrd selects another Plymouth theme than bgrt (its plymouthd.conf names no theme" ;;
        # drift guard: a path the split library's own invariant list calls live-only (see below)
        drift:*)                 local p="${v#drift:}" c
                                 p="${p//%/*}"; c="${p//\*/x}"
                                 case "$p" in
                                     etc/apt/preferences.d.save) c="etc/apt/preferences.d.save/preferences.d/x" ;;   # the stock standard layer has the flat files: only the nested ones are live-only
                                 esac
                                 plant "$b" "$c"; echo "/$c" ;;
        driftlive:*)             local q="${v#driftlive:}"
                                 [[ -e "$l/$q" || -L "$l/$q" ]] || { echo "the live fixture has no $q" >&2; return 2; }
                                 rm -rf "${l:?}/$q"; echo "live layer lacks:" ;;
        *) echo "unknown variant $v" >&2; return 2 ;;
    esac
}

# The split library (scripts/lib/split-live-layer.sh) keeps its own lists: the paths the base layer must never contain
# (ci_split_assert_base_tree, written independently of its removal table on purpose) and the files the live layer must hold
# (CI_SPLIT_LIVE_REQUIRED). Section 3g keeps its own tables (BASE_FORBIDDEN, LIVE_REQUIRED). Every path on the library's
# lists must also be a failure of section 3g, or the two have drifted: each becomes a "drift:<path>" (base) or
# "driftlive:<path>" (live) variant. The reverse (a row of 3g that the library lacks) is allowed: 3g works on a listing and
# is allowed to be stricter or to know the stock layers.
SPLITLIB="$REPO/backends/ubuntu/iso/scripts/lib/split-live-layer.sh"
drift_variants() {
    [[ -r "$SPLITLIB" ]] || return 0
    # one word per line, quotes dropped, '*' written as '%' so that a variant name never holds a glob character
    sed -n '/local -a gone=(/,/^    )$/p' "$SPLITLIB" | sed '1d;$d' | tr -s ' \t' '\n' | sed "s/^'//; s/'\$//" | grep -v '^$' | tr '*' '%' | sed 's/^/drift:/'
    sed -n '/^CI_SPLIT_LIVE_REQUIRED=(/,/^)$/p' "$SPLITLIB" | sed '1d;$d' | tr -s ' \t' '\n' | grep -v '^$' | sed 's/^/driftlive:/'
}

CORE_VARIANTS="good base-ssh-hostkey base-ssh-hostkey-pub base-casper-conf base-casperize base-default-layer base-initramfs-script base-initramfs-hook base-usr-lib-casper base-sbin-casper base-doc-casper base-casper-unit base-casper-enable-link base-dpkg-list base-status-casper base-status-casper-rc base-status-finalrd base-finalrd-file base-finalrd-enable base-finalrd-doc base-finalrd-unit base-livecd-gschema base-snap-desktop-entry base-snap-apparmor base-snap-update-ns base-snap-dir base-snap-bin base-snap-file base-snap-mount-unit base-snap-service base-installer-service base-installer-wants base-subiquity-kmp base-subiquity-mount base-subiquity-dropin base-cloud-quiet base-cloud-nocloud base-apt-prefs-save base-packages-chroot base-getty-mask base-udisks-inhibit base-media-fs-link base-journald-dropin base-cloud-cfg-live base-networkd-wait base-seed-installer base-seed-missing-file base-state-installer base-unreadable live-placeholder live-no-md5check live-no-enable-link live-no-hook live-no-unit live-no-script live-no-casper-conf live-no-finalrd live-no-casperize live-no-default-layer live-no-livecd-override live-no-installer-svc live-installer-wants live-installer-requires live-installer-autostart live-no-installer-snap live-seed-no-installer live-cloud-cfg-stock live-status-no-casper live-status-casper-rc live-conf-ubuntu-user live-tmp-wrong-mode live-root-mode standard-no-tmp standard-has-files size-live-zero size-live-huge size-live-garbage size-live-missing size-base-wrong size-standard-wrong manifest-live-stock manifest-live-version manifest-live-empty manifest-base-casper manifest-base-stale manifest-base-missing manifest-standard-missing manifest-standard-stock kernel-layerfs kernel-boot-casper kernel-extra-param kernel-no-lines kernel-vs-base ok-core24-in-base base-polkit-rule base-sysctl-apparmor base-display-manager base-snapd-reexec base-esb-seed-system base-seed-orphan base-seed-orphan-comp base-dracut base-dracut-core base-no-initramfs-tools base-pin-missing base-pin-weak base-pin-partial base-pin-no-pin-line ok-pin-with-install base-cdrom-missing base-cdrom-disabled base-cdrom-both manifest-full-base-stale manifest-full-std-stale manifest-full-live-base manifest-full-missing manifest-full-snaps sources-list-form sources-no-kernel sources-no-version sources-kernel-absent sources-kernel-vs-base sources-esb-variation sources-missing-layer sources-langs casper-lang-layer casper-esb-layer casper-esb-lang-layer casper-stale-extra casper-missing-size grub-insmod-all-video grub-insmod-other grub-insmod-not-builtin grub-efi-unreadable grub-efi-missing ok-grub-insmod-one-line live-esb-seed-system live-esb-seed-orphan live-esb-seed-orphan-comp iso-over-limit iso-limit-garbage ok-iso-limit-off"
# the sections after 3g (launcher, Plymouth diversions, sessions, the GNOME Shell theme, /.disk/info, the volume id, the initrd)
NEW_VARIANTS="launcher-missing launcher-wrong-exec launcher-wrong-name ply-divert-no-entry ply-divert-no-stock-link ply-divert-no-stock-file ok-ply-stock-regular session-extra-xorg session-extra-wayland shell-yaru-missing shell-yaru-other shell-yaru-stock shell-top-is-blob shell-top-no-light shell-top-missing shell-gdm-alternative shell-gdm-link-gone disk-info-hyphen disk-info-stock disk-info-tight-quote disk-info-no-serial disk-info-guard-stable disk-info-guard-latest disk-info-guard-no-channel disk-info-guard-no-lsb volid-changed sources-base-unreadable"
if [[ "$HAVE_UNMK" -eq 1 ]]; then
    NEW_VARIANTS="$NEW_VARIANTS initrd-no-text-theme initrd-plymouthd-other initrd-plymouthd-empty initrd-plymouthd-spaced initrd-plymouthd-second ok-initrd-plymouthd-bgrt ok-initrd-plymouthd-none ok-initrd-plymouthd-commented"
else
    echo "info  the initrd-* variants are left out: unmkinitramfs is not here (apt-get install initramfs-tools-core)"
fi
if [[ -n "${VERIFY_TEST_ONLY:-}" ]]; then VARIANTS="$VERIFY_TEST_ONLY"
else
    DRIFT="$(drift_variants)"
    VARIANTS="$CORE_VARIANTS $NEW_VARIANTS $(printf '%s ' "$DRIFT")"
    if [[ -z "$DRIFT" ]]; then echo "info  drift guard skipped: no invariant list found in $SPLITLIB"; fi
fi

section_3g() { awk '/^== 3g\./ { f = 1; next } /^== / { f = 0 } f' "$1"; }
section_3d() { awk '/^== 3d\./ { f = 1; next } /^== / { f = 0 } f' "$1"; }

GOOD="$WORK/good"
build_good "$GOOD" || { echo "could not build the fixture" >&2; exit 2; }

# The "base ISO" (VERIFY_BASE_ISO): the stock menus, i.e. the good image's without the automatic-install entry. Only the
# two menus are read from it by section 3g; the rest of verify-iso.sh reports what it cannot compare, which is not read here.
BASEISO_DIR="$WORK/baseiso"; mkdir -p "$BASEISO_DIR/tree/boot/grub"
awk '/^menuentry "Install Companion OS \(automatic\)"/{skip=1} !skip{print} skip&&/^}/{skip=0}' "$GOOD/menus/grub.cfg" > "$BASEISO_DIR/tree/boot/grub/grub.cfg"
cp "$GOOD/menus/loopback.cfg" "$BASEISO_DIR/tree/boot/grub/"
mkdir -p "$BASEISO_DIR/tree/casper"
cat > "$BASEISO_DIR/tree/casper/install-sources.yaml" <<'EOF_BASEIS'
kernel:
  default: linux-generic-hwe-24.04
sources:
- default: true
  id: ubuntu-desktop-minimal
  path: minimal.squashfs
  variations:
    minimal:
      path: minimal.squashfs
      size: 1
    minimal-enhanced-secureboot:
      path: minimal.enhanced-secureboot.squashfs
      size: 1
      snapd_system_label: enhanced-secureboot-desktop
version: 2
EOF_BASEIS
xorriso -as mkisofs -r -V "$FIXTURE_VOLID" -o "$BASEISO_DIR/base.iso" "$BASEISO_DIR/tree" >/dev/null 2>&1 || { echo "could not build the base ISO fixture" >&2; exit 2; }
# a base ISO whose /casper/install-sources.yaml cannot be read (section 3d says so instead of passing the comparison silently)
mkdir -p "$BASEISO_DIR/tree-nosources/boot/grub" "$BASEISO_DIR/tree-nosources/casper"
cp "$BASEISO_DIR/tree/boot/grub/grub.cfg" "$BASEISO_DIR/tree/boot/grub/loopback.cfg" "$BASEISO_DIR/tree-nosources/boot/grub/"
xorriso -as mkisofs -r -V "$FIXTURE_VOLID" -o "$BASEISO_DIR/base-nosources.iso" "$BASEISO_DIR/tree-nosources" >/dev/null 2>&1 || { echo "could not build the second base ISO fixture" >&2; exit 2; }

# weak_copy <vdir> <sed expression>: a copy of verify-iso.sh with a line changed, in a directory tree that looks like the repo to it (it finds the repo, the brand
# tokens and its helper scripts relative to its own location), so the repo-dependent checks still run. Used where a check compares with a constant of the script
# (Ubuntu's stock Yaru file: the real one is not in the repo). Prints the path of the copy.
weak_copy() {
    local d="$1/repo" x
    mkdir -p "$d/backends/ubuntu/iso/scripts"
    for x in core vendor stick; do ln -s "$REPO/$x" "$d/$x"; done
    for x in lib chroot packages desktop-theme; do ln -s "$REPO/backends/ubuntu/$x" "$d/backends/ubuntu/$x"; done
    ln -s "$REPO/backends/ubuntu/iso/scripts/md5sum-txt.sh" "$d/backends/ubuntu/iso/scripts/md5sum-txt.sh"
    ln -s "$REPO/backends/ubuntu/iso/scripts/lib" "$d/backends/ubuntu/iso/scripts/lib"
    sed "$2" "$VERIFY" > "$d/backends/ubuntu/iso/scripts/verify-iso.sh"
    echo "$d/backends/ubuntu/iso/scripts/verify-iso.sh"
}

BAD=0; N=0
for variant in $VARIANTS; do
    N=$((N + 1))
    vdir="$WORK/v-$N"; mkdir -p "$vdir"
    cp -a "$GOOD" "$vdir/img"
    want="$(mutate "$variant" "$vdir/img")" || { echo "FAIL  $variant: unknown variant"; BAD=$((BAD + 1)); continue; }
    pack_iso "$vdir/img" "$vdir" || { echo "FAIL  $variant: could not pack the image"; BAD=$((BAD + 1)); continue; }
    vmax=""; case "$variant" in iso-over-limit) vmax=1000 ;; iso-limit-garbage) vmax=lots ;; ok-iso-limit-off) vmax=0 ;; esac   # (section 9's limit; empty = its default)
    vbase="$BASEISO_DIR/base.iso"; vscript="$VERIFY"
    case "$variant" in
        sources-base-unreadable) vbase="$BASEISO_DIR/base-nosources.iso" ;;
        shell-yaru-stock) vscript="$(weak_copy "$vdir" "s/^STOCK_YARU_GRES_SHA=[0-9a-f]*/STOCK_YARU_GRES_SHA=$(sha256sum "$vdir/img/base/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource" | cut -d' ' -f1)/")" ;;
    esac
    VERIFY_MAX_ISO_BYTES="$vmax" VERIFY_BASE_ISO="$vbase" VERIFY_WORK="$vdir/verify" bash "$vscript" "$vdir/image.iso" > "$vdir/out.txt" 2>&1
    section_3g "$vdir/out.txt" > "$vdir/3g.txt"
    section_3d "$vdir/out.txt" > "$vdir/3d.txt"
    nfail="$(grep -c '^FAIL' "$vdir/3g.txt" || true)"; npass="$(grep -c '^PASS' "$vdir/3g.txt" || true)"
    if [[ "$variant" == good || "$variant" == ok-* ]]; then
        ok=1
        [[ "$nfail" -eq 0 ]] || ok=0
        # section 3d (the installer's sources, the casper directory) has no failure either, and its checks ran
        if grep -q '^FAIL' "$vdir/3d.txt"; then ok=0; echo "        section 3d fails on the $variant image:"; grep '^FAIL' "$vdir/3d.txt" | cut -c1-200 | sed 's/^/          /'; fi
        for need in "install-sources.yaml is the version 2 mapping" "the kernel meta-package linux-generic-hwe-24.04 is installed in the base layer" \
                    "install-sources.yaml carries the stock ISO's kernel: block" "/casper holds exactly the three layers"; do
            grep -q "^PASS  .*$need" "$vdir/3d.txt" || { ok=0; echo "        missing PASS (3d): $need"; }
        done
        # section 3e (directory modes of the stacked layers) has no failure for a live delta without /tmp
        if awk '/^== 3e\./ { f = 1; next } /^== / { f = 0 } f' "$vdir/out.txt" | grep -q '^FAIL'; then
            ok=0; echo "        section 3e fails on the good image:"; awk '/^== 3e\./ { f = 1; next } /^== / { f = 0 } f' "$vdir/out.txt" | grep '^FAIL' | sed 's/^/          /'
        fi
        # every group ran: the base checks, the package check, the live layer, the standard layer, sizes, manifests, menus
        for need in "base layer has no /etc/casper.conf" "base layer's dpkg status has no live-only package casper" \
                    "base layer's dpkg status has no live-only package finalrd" "base layer's /etc/cloud/cloud.cfg is not the live session's" \
                    "base layer's systemd-networkd-wait-online is not replaced by a symlink" "base layer's snapd seed.yaml names only snap files" \
                    "live layer is not a placeholder" "live layer holds what the base had taken out" "live layer does not start Canonical's installer by itself" "live layer's snapd seed.yaml still names the installer snap" \
                    "live layer has no snapd seed of the TPM full-disk-encryption variant" "live layer's seed/snaps holds only snap files its seed.yaml names" \
                    "live layer carries the live session's /etc/cloud/cloud.cfg" "live layer's dpkg status lists casper as installed" \
                    "minimal.standard.squashfs is still the empty placeholder" "layer minimal.standard.live: .size" \
                    "minimal.manifest lists exactly" "minimal.standard.live.manifest lists exactly" "grub.cfg: all 3 kernel lines are the stock ones" \
                    "loopback.cfg: all 2 kernel lines are the stock ones" "grub.cfg: the kernel lines equal the base ISO's" \
                    "loopback.cfg: the kernel lines equal the base ISO's" \
                    "base layer: initramfs-tools is installed" "base layer's dpkg status has no dracut" "pins dracut and dracut-core to Pin-Priority -1" \
                    "base layer: /etc/apt/sources.list.d/cdrom.sources is there" "base layer: no cdrom.sources.disabled" "base layer's seed/snaps holds only snap files" \
                    "minimal.manifest.full lists exactly" "minimal.standard.manifest.full lists exactly" "minimal.standard.live.manifest.full lists exactly" \
                    "minimal.manifest.full lists the snaps of that stack's seed" "layer minimal: .size"; do
            grep -q "^PASS  .*$need" "$vdir/3g.txt" || { ok=0; echo "        missing PASS: $need"; }
        done
        # the re-pointed checks read the live layer's casper.conf
        for need in "live session user is not 'ubuntu'" "live session host name is not 'ubuntu'" "casper keeps BUILD_SYSTEM=Ubuntu" \
                    "grub.cfg insmods exactly gfxterm and png" "every module grub.cfg insmods (gfxterm png) is built into the signed GRUB on the ISO"; do
            grep -q "^PASS  $need" "$vdir/out.txt" || { ok=0; echo "        missing PASS: $need"; }
        done
        # the sections after 3g: every new group ran (a PASS line each) and none of their checks fails on the good image
        for need in "launcher .desktop runs the helper" "launcher is named \"Install Companion OS (automatic)\"" \
                    "spinner/watermark.png is dpkg-diverted" "spinner/bgrt-fallback.png is dpkg-diverted" "bgrt/bgrt.plymouth is dpkg-diverted" \
                    "spinner/spinner.plymouth is dpkg-diverted" "ubuntu-text/ubuntu-text.plymouth.in is dpkg-diverted" "exactly one session file exists" \
                    "GNOME Shell theme: the Ubuntu session's gresource (theme/Yaru/gnome-shell-theme.gresource) is not Ubuntu's stock Yaru theme" \
                    "GNOME Shell theme: theme/Yaru/gnome-shell-theme.gresource is the branded blob of this checkout, byte for byte" \
                    "GNOME Shell theme: the upstream gnome-shell-theme.gresource still has gnome-shell-light.css and gnome-shell-dark.css" \
                    "GNOME Shell theme: the greeter's gdm-theme.gresource still resolves" \
                    "/.disk/info starts with 'Companion OS', the release and LTS" "/.disk/info keeps the (serial) suffix pollinate parses" \
                    "/.disk/info: the installer's last page reads 'Companion OS 26.04.1 LTS is installed and ready to use'" \
                    "/.disk/info: casper's launcher label reads 'Install Companion OS'" \
                    "/.disk/info: the second word is 'OS' and subiquity's refresh.py never uses it: the installer snap tracks 26.04/stable/ubuntu-26.04.1" \
                    "the ISO volume id is the base ISO's ('$FIXTURE_VOLID')"; do
            grep -q "^PASS  $need" "$vdir/out.txt" || { ok=0; echo "        missing PASS: $need"; }
        done
        if [[ "$HAVE_UNMK" -eq 1 ]]; then
            for need in "initrd carries the Companion OS overlay (appended archive)" "text splash (initrd overlay) is titled Companion OS" \
                        "the initrd's default Plymouth theme is bgrt" "nothing in the initrd selects another Plymouth theme than bgrt"; do
                grep -q "^PASS  $need" "$vdir/out.txt" || { ok=0; echo "        missing PASS: $need"; }
            done
        fi
        newfail="$(grep '^FAIL' "$vdir/out.txt" | grep -E "is not dpkg-diverted to (spinner|bgrt|ubuntu-text)|launcher \.desktop missing|launcher has the wrong name|GNOME Shell theme|/\.disk/info|ISO volume id|other session files|plymouthd\.conf|no ubuntu-text\.plymouth in the initrd overlay|could not read /casper/install-sources" || true)"
        if [[ -n "$newfail" ]]; then ok=0; echo "        the good image fails a check of the sections after 3g:"; printf '%s\n' "$newfail" | cut -c1-200 | sed 's/^/          /'; fi
        case "$want" in PASS:*) grep -q "^PASS  ${want#PASS:}" "$vdir/out.txt" || { ok=0; echo "        missing PASS: ${want#PASS:}"; } ;; esac
        # section 9 ran: it passed against the default limit, or noted that it was switched off
        case "$variant" in
            ok-iso-limit-off) grep -q '^info  the image size ([0-9]* bytes) is not compared with a Stick boot slot' "$vdir/out.txt" || { ok=0; echo "        missing note: the size check switched off"; } ;;
            *) grep -q '^PASS  the image is [0-9]* bytes, within 8589934592 (the 8 GiB boot slot' "$vdir/out.txt" || { ok=0; echo "        missing PASS: the image fits the Stick boot slot"; } ;;
        esac
        if [[ "$ok" -eq 1 ]]; then echo "PASS  $variant image: sections 3g and 3d have no failure ($npass checks passed in 3g)"
        else echo "FAIL  $variant image: section 3g reports $nfail failure(s) or lacks a group"; grep '^FAIL' "$vdir/3g.txt" | cut -c1-240 | sed 's/^/        /'; BAD=$((BAD + 1)); fi
    else
        src="$vdir/3g.txt"; case "$variant" in live-conf-ubuntu-user | live-tmp-wrong-mode | live-root-mode | standard-no-tmp) src="$vdir/out.txt" ;; sources-* | casper-*) src="$vdir/3d.txt" ;; grub-* | iso-* | launcher-* | ply-* | session-* | shell-* | disk-info-* | volid-* | initrd-*) src="$vdir/out.txt" ;; esac
        [[ -z "${VERIFY_TEST_VERBOSE:-}" ]] || { grep '^FAIL' "$vdir/3g.txt" | sed 's/^/        3g: /'; }
        src_fails="$(grep '^FAIL' "$src" || true)"   # (a variable and a here-string: `grep | grep -q` under pipefail dies of SIGPIPE when the first match comes before the end of a long output)
        if grep -qF -- "$want" <<<"$src_fails"; then
            echo "PASS  $variant: rejected ($(grep -cF -- "$want" <<<"$src_fails") FAIL line(s) say: $want)"
        else
            echo "FAIL  $variant: expected a FAIL saying '$want'"
            grep '^FAIL' "$vdir/3g.txt" | sed 's/^/        got: /' | head -n 5; BAD=$((BAD + 1))
        fi
    fi
    if [[ -n "${VERIFY_TEST_KEEP:-}" ]]; then mkdir -p "$VERIFY_TEST_KEEP"; cp "$vdir/out.txt" "$VERIFY_TEST_KEEP/${variant//[:\/]/_}.out.txt"; fi
    rm -rf "$vdir"
done

echo
if [[ "$BAD" -eq 0 ]]; then echo "all $N variants behaved"; else echo "$BAD of $N variant(s) misbehaved"; fi
[[ "$BAD" -eq 0 ]]
