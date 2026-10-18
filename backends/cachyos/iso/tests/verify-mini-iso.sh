#!/usr/bin/env bash
#=============================================================================
# Test: build a miniature ISO from the REAL overlay and run verify-iso.sh on it (minutes instead of a 40 minute build)
#
# A full build takes 35 to 60 minutes and 25 GiB, so a wrong assumption in the overlay, the renderer, the installer overlay or
# the verifier is found late. This test stops short of the part that takes the time: no package is installed and mkarchiso is
# not run. Everything else is the real thing:
#
#   1. the pinned upstream commit is fetched (the same fetch and tree-id check as in-container/20-build.sh)
#   2. render-assets.sh and installer/render-installer-assets.sh render the staging tree (real rsvg-convert / ImageMagick), and the real
#      stage-compat-libs.sh puts the compatibility libraries of compat-libs.lock into it (Arch Linux Archive; sha256 and signature checked)
#   3. in-container/apply-overlay.sh merges patches, overlay files and staging onto upstream's archiso/ (guards (a) to (e))
#   4. the merged airootfs becomes the root of a small squashfs: the pacman hooks' scripts are RUN on it (the os-release writer
#      and the skel editor), file_permissions of the merged profiledef.sh are applied the way mkarchiso applies them, the
#      stock Calamares module names and a package database stand in for the packages that are not installed
#   5. the merged GRUB and syslinux menus get mkarchiso's substitutions; the boot files come from the syslinux package
#   6. xorriso writes a hybrid BIOS + UEFI ISO with mkarchiso's options; checksum and build record go next to it
#   7. verify-iso.sh runs on it
#
# What this can not show: anything that needs the real packages (the CachyOS hooks racing the identity hook, cachyos-hello's
# real files, the package list's content), the kernels, or a boot. Its result is therefore "the checks and the overlay agree on
# the files the overlay and the renderer produce", not "the ISO is right". Exit status is verify-iso.sh's: 0 when nothing failed.
#
#   backends/cachyos/iso/tests/verify-mini-iso.sh [--image IMAGE] [--out DIR]
#       --image IMAGE   the builder image to run in (default: the newest ci-os-cachyos-builder:* image, built by build-iso.sh)
#       --out DIR       keep the miniature ISO, its checksum and build record, and the verify log in DIR
#   Inside a Linux with pacman, xorriso, squashfs-tools, mtools, dosfstools, git and root, run it with CI_OS_MINI_INSIDE=1.
#
# Needs: docker and network (pacman installs librsvg, imagemagick, plymouth, syslinux, python-yaml; git fetches the pin).
# Runs on a stock macOS (bash 3.2) for the host part; the container part uses bash 5.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

die() { echo "verify-mini-iso: $*" >&2; exit 2; }

#=== host part =================================================================================================================
if [ "${CI_OS_MINI_INSIDE:-}" != 1 ]; then
    IMAGE=""; OUT=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --image) [ $# -ge 2 ] || die "--image needs a value"; IMAGE="$2"; shift 2 ;;
            --out) [ $# -ge 2 ] || die "--out needs a value"; OUT="$2"; shift 2 ;;
            -h|--help) sed -n '2,/^# Runs on/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done
    command -v docker >/dev/null 2>&1 || die "docker not found (this test runs in the builder image)"
    docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"
    if [ -z "$IMAGE" ]; then
        IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' ci-os-cachyos-builder 2>/dev/null | head -n 1)"
        [ -n "$IMAGE" ] || die "no ci-os-cachyos-builder image: run backends/cachyos/iso/scripts/build-iso.sh once (it builds the image), or pass --image"
    fi
    args=(run --rm --platform linux/amd64 --cpus 4 --memory 8g -v "$REPO_ROOT:/repo:ro" -e CI_OS_MINI_INSIDE=1)
    [ -z "${CI_OS_MINI_NAME:-}" ] || args+=(--name "$CI_OS_MINI_NAME")   # optional: name the container, so that it can be found and removed
    if [ -n "$OUT" ]; then mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"; args+=(-v "$OUT:/out"); fi
    echo "verify-mini-iso: running in $IMAGE (network needed: pacman and git)"
    exec docker "${args[@]}" "$IMAGE" bash /repo/backends/cachyos/iso/tests/verify-mini-iso.sh
fi

#=== container part ============================================================================================================
[ "$(id -u)" -eq 0 ] || die "run as root inside the builder container"
REPO=/repo
CACHYOS="$REPO/backends/cachyos"
LOCK="$CACHYOS/upstream.lock"
[ -f "$LOCK" ] || die "no $LOCK"
kv() { sed -n "s/^$1=//p" "$LOCK" | head -n 1; }
say() { printf '== %s\n' "$*"; }

W=/work/mini; rm -rf "$W"; mkdir -p "$W"
UP="$W/upstream"; STAGING="$W/staging"; PROFILE="$W/profile"; ROOT="$W/root"; ISOT="$W/iso"; R2="$W/repo"
UUID="$(date -u -d "@$(kv UPSTREAM_COMMIT_EPOCH)" +%Y-%m-%d-%H-%M-%S-00)"
EPOCH="$(kv UPSTREAM_COMMIT_EPOCH)"; DAY="$(date -u -d "@$EPOCH" +%Y%m%d)"; VERSION=0.1.0
ISO_NAME="$(kv EDITION_ISO_NAME)-$(date -u -d "@$EPOCH" +%Y.%m.%d)-$(kv EDITION_ARCH).iso"

say "1/7 tools and fetching the pinned upstream commit"
render_deps="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$CACHYOS/iso/render-deps.txt" | tr '\n' ' ')"
# shellcheck disable=SC2086
pacman -Sy --noconfirm --needed $render_deps syslinux python python-yaml mtools dosfstools git >/dev/null
git config --global --add safe.directory '*'
mkdir -p "$UP"; git -C "$UP" init -q; git -C "$UP" remote add origin "$(kv UPSTREAM_REPO)"
git -C "$UP" fetch -q --depth 1 origin "$(kv UPSTREAM_SHA)"; git -C "$UP" checkout -q --detach "$(kv UPSTREAM_SHA)"
[ "$(git -C "$UP" rev-parse HEAD)" = "$(kv UPSTREAM_SHA)" ] || die "upstream HEAD is not the pin"
[ "$(git -C "$UP" rev-parse HEAD:archiso)" = "$(kv UPSTREAM_ARCHISO_TREE)" ] || die "upstream archiso/ tree is not the pinned one"

say "2/7 the repository subset the build copies (no .git), then the renderers"
mkdir -p "$R2"
# the paths build-iso.sh copies in: iso/scripts/repo-subset.txt (one repo-relative path per line, # comments, missing ones skipped)
while IFS= read -r d; do
    case "$d" in ''|'#'*) continue ;; esac
    [ -d "$REPO/$d" ] && tar -C "$REPO" -cf - "$d" | tar -C "$R2" -xf -
done < "$CACHYOS/iso/scripts/repo-subset.txt"
mkdir -p "$STAGING"
CI_OS_STAGING_DIR="$STAGING" CI_OS_REPO_ROOT="$R2" CI_OS_VERSION="$VERSION" CI_OS_BUILD_DAY="$DAY" SOURCE_DATE_EPOCH="$EPOCH" \
    bash "$R2/backends/cachyos/iso/scripts/render-assets.sh" >"$W/render.log" 2>&1 || { tail -n 20 "$W/render.log"; die "render-assets.sh failed"; }
# The installer overlay (Calamares branding, module configs, guards, the first-boot payload) is staged into the same tree by
# the second call below, exactly as in-container/20-build.sh does it right after render-assets.sh (and stops if the script is
# missing). Keep the two calls in step with 20-build.sh; overlay-brand.sh checks that the build still makes both.
CI_OS_STAGING_DIR="$STAGING" CI_OS_REPO_ROOT="$R2" CI_OS_VERSION="$VERSION" CI_OS_BUILD_DAY="$DAY" \
    bash "$R2/backends/cachyos/installer/render-installer-assets.sh" >"$W/render-installer.log" 2>&1 || { tail -n 20 "$W/render-installer.log"; die "render-installer-assets.sh failed"; }
[ -d "$STAGING/airootfs/usr/share/ci-os/calamares" ] || die "render-installer-assets.sh left no usr/share/ci-os/calamares in the staging tree"
# The compatibility libraries of compat-libs.lock, staged by the REAL stager as 20-build.sh does right after the two calls above: the
# real lock, the Arch Linux Archive, the package's sha256 and signature. verify-iso.sh then has to find them in the image byte for
# byte, and the build record below carries the COMPAT_* lines of this report (network: archive.archlinux.org).
CI_OS_STAGING_DIR="$STAGING" CI_OS_COMPAT_LOCK="$R2/backends/cachyos/compat-libs.lock" CI_OS_COMPAT_REPORT_FILE="$W/compat-report.env" \
    bash "$R2/backends/cachyos/iso/scripts/in-container/stage-compat-libs.sh" stage >"$W/compat.log" 2>&1 || { tail -n 20 "$W/compat.log"; die "stage-compat-libs.sh failed"; }

say "3/7 apply-overlay.sh onto the pinned archiso/ (guards a to e)"
UPSTREAM_ARCHISO_DIR="$UP/archiso" OVERLAY_DIR="$R2/backends/cachyos/iso/overlay" WORK_ARCHISO_DIR="$PROFILE" SOURCE_DATE_EPOCH="$EPOCH" \
CI_OS_STAGING_DIR="$STAGING" CI_OS_LOCK="$R2/backends/cachyos/upstream.lock" bash "$R2/backends/cachyos/iso/scripts/in-container/apply-overlay.sh" 2>&1 | tail -n 4

say "4/7 the root file system"
mkdir -p "$ROOT"; cp -a "$PROFILE/airootfs/." "$ROOT/"
# What a real build gets from packages: the Calamares modules, the module configs, a package database. Names only.
for m in bootloader chwd displaymanager finished fstab grubcfg hostinfo hwclock initcpio initcpiocfg keyboard locale localecfg luksbootkeyfile \
         luksopenswaphookcfg machineid mount netinstall networkcfg packagechooser packages pacstrap partition plymouthcfg preservefiles removeuser \
         services-systemd shellprocess summary umount unpackfs users welcome zfs zfshostid; do mkdir -p "$ROOT/usr/lib/calamares/modules/$m"; done
mkdir -p "$ROOT/etc/calamares/modules" "$ROOT/var/lib/pacman/local"
for c in bootloader displaymanager grubcfg netinstall packagechooser_bootloader packages_online pacstrap plymouthcfg services-systemd shellprocess \
         shellprocess-before-online shellprocess_initialize_pacman shellprocess_modify_mk_hook shellprocess_reset_mk_hook shellprocess_btrfs_snapshot \
         shellprocess_cleanup_calamares users welcome_online; do : > "$ROOT/etc/calamares/modules/$c.conf"; done
# shellcheck disable=SC1090
( . "$CACHYOS/iso/scripts/verify-iso.sh"; for p in $V_REQUIRED_PKGS cachyos-hello cachyos-kde-settings; do echo "$p 1.0-1"; done ) | sort -u > "$W/pkglist.txt"
while read -r n v; do d="$ROOT/var/lib/pacman/local/$n-$v"; mkdir -p "$d"; printf '%%NAME%%\n%s\n' "$n" > "$d/desc"; printf '%%FILES%%\n' > "$d/files"; done < "$W/pkglist.txt"
# the symlinks upstream's own build generates
mkdir -p "$ROOT/etc/systemd/system"
ln -sf /usr/lib/systemd/system/plasmalogin.service "$ROOT/etc/systemd/system/display-manager.service"
# mkarchiso appends IMAGE_ID / IMAGE_VERSION; then the pacman hook scripts run, as they do in the transaction
printf 'IMAGE_ID=%s\nIMAGE_VERSION=%s\n' "$(kv EDITION_ISO_NAME)" "$(date -u -d "@$EPOCH" +%Y.%m.%d)" >> "$ROOT/etc/os-release"
CI_OS_ROOT="$ROOT" bash "$ROOT/usr/share/libalpm/scripts/zz-ci-os-os-release" 2>&1 | tail -n 1
mkdir -p "$ROOT/etc/skel/.config"; printf '[General]\nColorScheme=BreezeDark\n' > "$ROOT/etc/skel/.config/kdeglobals"
CI_OS_ROOT="$ROOT" bash "$ROOT/usr/share/libalpm/scripts/zz-ci-os-skel" 2>&1 | tail -n 1
mkdir -p "$ROOT/home/liveuser"; cp -a "$ROOT/etc/skel/." "$ROOT/home/liveuser/"
# the build record, as 20-build.sh embeds it
{ echo CI_OS_EDITION=cachyos-plasma; echo "CI_OS_VERSION=$VERSION"; echo "BUILD_DAY=$DAY"; echo "SOURCE_DATE_EPOCH=$EPOCH"
  echo UPSTREAM_PIN=primary; for k in UPSTREAM_REPO UPSTREAM_SHA UPSTREAM_ARCHISO_TREE BASE_IMAGE MIRRORLIST_REF MIRRORLIST_SHA256 CACHYOS_KEY_FPR; do echo "$k=$(kv "$k")"; done
  echo "OVERLAY_SHA256=$(find "$R2/backends/cachyos/iso/overlay" -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"
  echo "STAGING_SHA256=$(find "$STAGING" -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"
  grep -E '^COMPAT_[A-Z0-9_]+=[A-Za-z0-9._,:+@/-]*$' "$W/compat-report.env"; } > "$ROOT/usr/share/ci-os/iso-build-info"
# modes: mkarchiso keeps 644 / 755 and only what file_permissions lists
find "$ROOT" -type f -exec chmod 644 {} +
declare -A file_permissions=()
# shellcheck disable=SC1091,SC2034
( export SOURCE_DATE_EPOCH="$EPOCH"; . "$PROFILE/profiledef.sh"; for p in "${!file_permissions[@]}"; do echo "$p ${file_permissions[$p]}"; done ) > "$W/perms.txt"
while read -r p spec; do IFS=: read -r _o _g mode <<< "$spec"; [ -e "$ROOT$p" ] && chmod "$mode" "$ROOT$p"; done < "$W/perms.txt"
mksquashfs "$ROOT" "$W/airootfs.sfs" -comp xz -no-xattrs -all-root -quiet -noappend >/dev/null

say "5/7 the medium"
mkdir -p "$ISOT/arch/x86_64" "$ISOT/arch/boot/x86_64" "$ISOT/boot/grub" "$ISOT/boot/syslinux" "$ISOT/boot/memtest86+" "$ISOT/EFI/BOOT"
cp "$W/airootfs.sfs" "$ISOT/arch/x86_64/airootfs.sfs"; (cd "$ISOT/arch/x86_64" && sha512sum airootfs.sfs > airootfs.sha512)
cp "$W/pkglist.txt" "$ISOT/arch/pkglist.x86_64.txt"; date -u -d "@$EPOCH" +%Y.%m.%d > "$ISOT/arch/version"
for f in vmlinuz-linux-cachyos vmlinuz-linux-cachyos-lts initramfs-linux-cachyos.img initramfs-linux-cachyos-lts.img; do head -c 4096 /dev/urandom > "$ISOT/arch/boot/x86_64/$f"; done
: > "$ISOT/boot/$UUID.uuid"; echo memtest > "$ISOT/boot/memtest86+/memtest"
cp /usr/lib/syslinux/bios/*.c32 /usr/lib/syslinux/bios/isolinux.bin /usr/lib/syslinux/bios/isohdpfx.bin "$ISOT/boot/syslinux/"
subst() { sed -e "s|%INSTALL_DIR%|arch|g" -e "s|%ARCH%|x86_64|g" -e "s|%ARCHISO_UUID%|$UUID|g" "$1"; }
for f in "$PROFILE"/syslinux/*.cfg; do subst "$f" > "$ISOT/boot/syslinux/$(basename "$f")"; done
[ -f "$PROFILE/syslinux/splash.png" ] && cp "$PROFILE/syslinux/splash.png" "$ISOT/boot/syslinux/splash.png"
for f in "$PROFILE"/grub/*; do
    case "$(basename "$f")" in *.cfg) subst "$f" > "$ISOT/boot/grub/$(basename "$f")" ;; *) [ -f "$f" ] && cp "$f" "$ISOT/boot/grub/" ;; esac
done
[ -d "$PROFILE/grub/theme" ] && cp -r "$PROFILE/grub/theme" "$ISOT/boot/grub/theme"
printf 'MZ\000\000 search --file /boot/%s.uuid \000' "$UUID" > "$ISOT/EFI/BOOT/BOOTx64.EFI"; head -c 6000 /dev/zero >> "$ISOT/EFI/BOOT/BOOTx64.EFI"
truncate -s 8M "$W/efiboot.img"; mkfs.vfat -n ARCHISO_EFI "$W/efiboot.img" >/dev/null
mmd -i "$W/efiboot.img" ::/EFI ::/EFI/BOOT; mcopy -i "$W/efiboot.img" "$ISOT/EFI/BOOT/BOOTx64.EFI" ::/EFI/BOOT/BOOTx64.EFI

say "6/7 xorriso with mkarchiso's options, checksum and build record"
mkdir -p "$W/out"; ISO="$W/out/$ISO_NAME"; BASE="${ISO%.iso}"
LABEL="$(kv EDITION_LABEL_PREFIX)$(date -u -d "@$EPOCH" +%Y%m)"
xorriso -no_rc -as mkisofs -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock -volid "$LABEL" \
    -appid "Companion OS Live/Installer" -publisher "Companion Intelligence <https://ci.computer>" -preparer "prepared by mkarchiso" -partition_offset 16 \
    -eltorito-boot boot/syslinux/isolinux.bin -eltorito-catalog boot/syslinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-mbr "$ISOT/boot/syslinux/isohdpfx.bin" \
    -eltorito-alt-boot -e --interval:appended_partition_2:all:: -no-emul-boot -isohybrid-gpt-basdat \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$W/efiboot.img" -output "$ISO" "$ISOT" >/dev/null 2>&1
cp "$W/pkglist.txt" "$BASE.pkgs.txt"
(cd "$W/out" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256")
{ cat "$ROOT/usr/share/ci-os/iso-build-info"; echo "ISO_FILE=$ISO_NAME"; echo "ISO_BYTES=$(stat -c %s "$ISO")"; echo "ISO_SHA256=$(cut -d' ' -f1 "$ISO.sha256")"; } > "$BASE.build-info"
ls -l "$W/out" | sed 's/^/   /'

say "7/7 verify-iso.sh on the miniature ISO"
rc=0
VERIFY_MIN_MB=1 VERIFY_MIN_ENTRIES=100 VERIFY_UPSTREAM_DIR="$UP" VERIFY_LOCK="$LOCK" VERIFY_WORK="$W/verify" bash "$CACHYOS/iso/scripts/verify-iso.sh" "$ISO" > "$W/verify.log" 2>&1 || rc=$?
cat "$W/verify.log"
if [ -d /out ]; then cp "$W/out/"* /out/ && cp "$W/verify.log" /out/verify-mini-iso.log && echo "kept in /out: the miniature ISO, its checksum, the build record and verify-mini-iso.log"; fi
exit "$rc"
