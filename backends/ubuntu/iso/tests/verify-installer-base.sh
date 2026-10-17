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
#                profile, mount unit or seed entry, none of the other live-image files in its table;
#   live layer   not a placeholder: casper's files, a dpkg status that lists casper, its .size true;
#   standard     still the empty placeholder;
#   metadata     the .size and .manifest files describe the layers this image has;
#   boot menus   the kernel lines are the stock ones (and, given VERIFY_BASE_ISO, the base ISO's).
#
# This test builds a small image (real squashfs layers in a real ISO, the shapes `unsquashfs -ll` and xorriso give
# for the real one), runs the WHOLE verify-iso.sh on it and reads only the lines of section 3g (and, for the
# re-pointed casper.conf checks, the lines with their labels). The other sections fail on such a small image, by
# design. It expects
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

build_good() { # build_good <dir>: dir/{base,standard,live}, dir/meta, dir/iso-tree
    local g="$1" b="$1/base" s="$1/standard" l="$1/live" m="$1/meta" i
    mk_layer_root "$b"; mk_layer_root "$s"; mk_layer_root "$l"; mkdir -p "$m"
    rmdir "$l/tmp"   # a live delta has /tmp only if something under it changed; the layers below provide it

    # base: the installed system (a dpkg database without casper, a snapd seed with one snap that is there)
    mkdir -p "$b/var/lib/dpkg/info" "$b/var/lib/snapd/seed/snaps" "$b/usr/share/glib-2.0/schemas" "$b/etc/dconf/db/local.d" "$b/usr/lib/ci-os"
    { status_para base-files 13ubuntu10; status_para bash 5.2.21-2ubuntu4; status_para docker-ce 5:27.3.1-1; status_para setup-device 1.0.0; } > "$b/var/lib/dpkg/status"
    printf '/etc/hostname\n' > "$b/var/lib/dpkg/info/base-files.list"
    printf 'companion-os\n' > "$b/etc/hostname"
    printf 'snaps:\n  - name: firefox\n    channel: latest/stable/ubuntu-24.04\n    file: firefox_6000.snap\n' > "$b/var/lib/snapd/seed/seed.yaml"
    printf 'fixture snap\n' > "$b/var/lib/snapd/seed/snaps/firefox_6000.snap"
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
    printf 'fixture snap\n' > "$l/var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_680.snap"
    printf 'snaps:\n  - name: ubuntu-desktop-bootstrap\n    file: ubuntu-desktop-bootstrap_680.snap\n' > "$l/var/lib/snapd/seed/seed.yaml"
    printf 'kernel-meta\n' > "$l/etc/subiquity/kernel-meta-package"
    { cat "$b/var/lib/dpkg/status"; status_para casper 1.498; status_para finalrd 0.3; } > "$l/var/lib/dpkg/status"
    head -c 90000 /dev/zero | tr '\0' 'y' > "$l/usr/lib/casper/data"

    # metadata: sizes as `du -sx --block-size=1` of each tree, manifests in the stock "diff" shape
    for i in "base:minimal" "standard:minimal.standard" "live:minimal.standard.live"; do
        du -sx --block-size=1 "$g/${i%%:*}" | cut -f1 > "$m/${i##*:}.size"
    done
    manifest_file "" minimal "base-files	13ubuntu10" "bash	5.2.21-2ubuntu4" "docker-ce	5:27.3.1-1" "setup-device	1.0.0" > "$m/minimal.manifest"
    manifest_file minimal minimal.standard > "$m/minimal.standard.manifest"
    manifest_file minimal.standard minimal.standard.live "casper	1.498" "finalrd	0.3" "snap:core22	stable	2955" > "$m/minimal.standard.live.manifest"

    # boot menus as the build leaves them: the stock kernel lines, plus the automatic-install copy of the first entry
    mkdir -p "$g/menus"
    cat > "$g/menus/grub.cfg" <<'EOF'
set timeout=30
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
}

# pack <good dir> <out dir> <menus dir> [base ISO]: the three squashfs layers, the metadata and the menus into an ISO
pack_iso() {
    local g="$1" o="$2" t="$2/tree"
    mkdir -p "$t/casper" "$t/boot/grub" "$t/.disk"
    mksquashfs "$g/base" "$t/casper/minimal.squashfs" -comp gzip -noappend -no-recovery -quiet >/dev/null 2>&1 || return 1
    mksquashfs "$g/standard" "$t/casper/minimal.standard.squashfs" -comp gzip -noappend -no-recovery -quiet >/dev/null 2>&1 || return 1
    mksquashfs "$g/live" "$t/casper/minimal.standard.live.squashfs" -comp gzip -noappend -no-recovery -quiet >/dev/null 2>&1 || return 1
    local f; for f in "$g"/meta/*; do cp "$f" "$t/casper/"; done
    cp "$g/menus/grub.cfg" "$g/menus/loopback.cfg" "$t/boot/grub/"
    printf 'Companion OS 1.0 "Fixture" - Release amd64\n' > "$t/.disk/info"
    printf 'initrd\n' > "$t/casper/initrd"
    printf -- '- id: ubuntu-desktop-minimal\n  path: minimal.squashfs\n' > "$t/casper/install-sources.yaml"
    xorriso -as mkisofs -r -V FIXTURE -o "$o/image.iso" "$t" >/dev/null 2>&1
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
        base-snap-update-ns)     plant "$b" var/lib/snapd/apparmor/profiles/snap-update-ns.ubuntu-desktop-bootstrap; echo "base layer ships installer snap files, snapd state" ;;
        base-snap-dir)           plant "$b" snap/ubuntu-desktop-bootstrap/current; echo "base layer ships installer snap files, snapd state" ;;
        base-snap-bin)           plant "$b" snap/bin/ubuntu-desktop-bootstrap; echo "base layer ships installer snap files, snapd state" ;;
        base-snap-file)          plant "$b" var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_680.snap; echo "base layer ships installer snap files, snapd state" ;;
        base-core22-blob)        plant "$b" var/lib/snapd/snaps/core22_2955.snap; echo "base layer ships installer snap files, snapd state" ;;
        base-core22-cookie)      plant "$b" var/lib/snapd/cookie/snap.core22; echo "base layer ships installer snap files, snapd state" ;;
        base-core22-sequence)    plant "$b" var/lib/snapd/sequence/core22.json; echo "base layer ships installer snap files, snapd state" ;;
        base-snap-mount-unit)    plant "$b" 'etc/systemd/system/snap-ubuntu\x2ddesktop\x2dbootstrap-680.mount'; echo "base layer ships installer snap mount units and service units" ;;
        base-core22-mount-unit)  plant "$b" etc/systemd/system/snap-core22-2955.mount; echo "base layer ships installer snap mount units and service units" ;;
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
        base-snapd-no-reexec)    plant "$b" usr/lib/systemd/system/snapd.service.d/no-reexec.conf; echo "base layer ships live-session systemd settings" ;;
        base-media-fs-link)      mkdir -p "$b/usr/lib/systemd/system/local-fs.target.wants"; ln -s ../media-filesystem.mount "$b/usr/lib/systemd/system/local-fs.target.wants/media-filesystem.mount"; echo "base layer ships live-session systemd settings" ;;
        base-journald-dropin)    plant "$b" etc/systemd/journald.conf.d/no-rate-limit.conf; echo "base layer ships live-session journald drop-ins" ;;
        base-cloud-cfg-live)     cp "$l/etc/cloud/cloud.cfg" "$b/etc/cloud/cloud.cfg"; echo "base layer's /etc/cloud/cloud.cfg is the live session's" ;;
        base-networkd-wait)      rm "$b/usr/lib/systemd/systemd-networkd-wait-online"; ln -s /bin/true "$b/usr/lib/systemd/systemd-networkd-wait-online"; echo "base layer's systemd-networkd-wait-online is the live session's symlink" ;;
        base-seed-installer)     printf 'snaps:\n  - name: ubuntu-desktop-bootstrap\n    file: ubuntu-desktop-bootstrap_680.snap\n' > "$b/var/lib/snapd/seed/seed.yaml"; echo "base layer's snapd seed.yaml names the installer snap" ;;
        base-seed-missing-file)  printf 'snaps:\n  - name: firefox\n    file: firefox_6000.snap\n  - name: snap-store\n    file: snap-store_1000.snap\n' > "$b/var/lib/snapd/seed/seed.yaml"; echo "names snap files that are not in the base layer: snap-store_1000.snap" ;;
        base-state-installer)    printf '{"data": {"snaps": {"ubuntu-desktop-bootstrap": {"type": "app"}}}}\n' > "$b/var/lib/snapd/state.json"; echo "base layer's snapd state.json knows an installer snap" ;;
        base-state-core22)       printf '{"data": {"snaps": {"core22": {"type": "base"}}}}\n' > "$b/var/lib/snapd/state.json"; echo "base layer's snapd state.json knows an installer snap" ;;
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
        live-no-kmp)             rm "$l/etc/subiquity/kernel-meta-package"; echo "[subiquity's kernel-meta-package file]" ;;
        live-no-installer-snap)  rm "$l/var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_680.snap"; echo "[the installer snap file in the seed]" ;;
        live-seed-no-installer)  printf 'snaps:\n  - name: firefox\n    file: firefox_6000.snap\n' > "$l/var/lib/snapd/seed/seed.yaml"; echo "live layer's snapd seed.yaml does not name the installer snap" ;;
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
        manifest-base-casper)    manifest_file "" minimal "base-files	13ubuntu10" "bash	5.2.21-2ubuntu4" "casper	1.498" "docker-ce	5:27.3.1-1" "setup-device	1.0.0" > "$m/minimal.manifest"; echo "minimal.manifest lists casper (the base layer has none)" ;;
        manifest-base-stale)     manifest_file "" minimal "base-files	13ubuntu10" > "$m/minimal.manifest"; echo "minimal.manifest is not the base layer's package list" ;;
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

CORE_VARIANTS="good base-casper-conf base-casperize base-default-layer base-initramfs-script base-initramfs-hook base-usr-lib-casper base-sbin-casper base-doc-casper base-casper-unit base-casper-enable-link base-dpkg-list base-status-casper base-status-casper-rc base-status-finalrd base-finalrd-file base-finalrd-enable base-finalrd-doc base-finalrd-unit base-livecd-gschema base-snap-desktop-entry base-snap-apparmor base-snap-update-ns base-snap-dir base-snap-bin base-snap-file base-core22-blob base-core22-cookie base-core22-sequence base-snap-mount-unit base-core22-mount-unit base-snap-service base-installer-service base-installer-wants base-subiquity-kmp base-subiquity-mount base-subiquity-dropin base-cloud-quiet base-cloud-nocloud base-apt-prefs-save base-packages-chroot base-getty-mask base-udisks-inhibit base-snapd-no-reexec base-media-fs-link base-journald-dropin base-cloud-cfg-live base-networkd-wait base-seed-installer base-seed-missing-file base-state-installer base-state-core22 base-unreadable live-placeholder live-no-md5check live-no-enable-link live-no-hook live-no-unit live-no-script live-no-casper-conf live-no-finalrd live-no-casperize live-no-default-layer live-no-livecd-override live-no-installer-svc live-no-kmp live-no-installer-snap live-seed-no-installer live-cloud-cfg-stock live-status-no-casper live-status-casper-rc live-conf-ubuntu-user live-tmp-wrong-mode live-root-mode standard-no-tmp standard-has-files size-live-zero size-live-huge size-live-garbage size-live-missing size-base-wrong size-standard-wrong manifest-live-stock manifest-live-version manifest-live-empty manifest-base-casper manifest-base-stale manifest-base-missing manifest-standard-missing manifest-standard-stock kernel-layerfs kernel-boot-casper kernel-extra-param kernel-no-lines kernel-vs-base"
if [[ -n "${VERIFY_TEST_ONLY:-}" ]]; then VARIANTS="$VERIFY_TEST_ONLY"
else
    DRIFT="$(drift_variants)"
    VARIANTS="$CORE_VARIANTS $(printf '%s ' "$DRIFT")"
    if [[ -z "$DRIFT" ]]; then echo "info  drift guard skipped: no invariant list found in $SPLITLIB"; fi
fi

section_3g() { awk '/^== 3g\./ { f = 1; next } /^== / { f = 0 } f' "$1"; }

GOOD="$WORK/good"
build_good "$GOOD" || { echo "could not build the fixture" >&2; exit 2; }

# The "base ISO" (VERIFY_BASE_ISO): the stock menus, i.e. the good image's without the automatic-install entry. Only the
# two menus are read from it by section 3g; the rest of verify-iso.sh reports what it cannot compare, which is not read here.
BASEISO_DIR="$WORK/baseiso"; mkdir -p "$BASEISO_DIR/tree/boot/grub"
awk '/^menuentry "Install Companion OS \(automatic\)"/{skip=1} !skip{print} skip&&/^}/{skip=0}' "$GOOD/menus/grub.cfg" > "$BASEISO_DIR/tree/boot/grub/grub.cfg"
cp "$GOOD/menus/loopback.cfg" "$BASEISO_DIR/tree/boot/grub/"
xorriso -as mkisofs -r -V BASE -o "$BASEISO_DIR/base.iso" "$BASEISO_DIR/tree" >/dev/null 2>&1 || { echo "could not build the base ISO fixture" >&2; exit 2; }

BAD=0; N=0
for variant in $VARIANTS; do
    N=$((N + 1))
    vdir="$WORK/v-$N"; mkdir -p "$vdir"
    cp -a "$GOOD" "$vdir/img"
    want="$(mutate "$variant" "$vdir/img")" || { echo "FAIL  $variant: unknown variant"; BAD=$((BAD + 1)); continue; }
    pack_iso "$vdir/img" "$vdir" || { echo "FAIL  $variant: could not pack the image"; BAD=$((BAD + 1)); continue; }
    VERIFY_BASE_ISO="$BASEISO_DIR/base.iso" VERIFY_WORK="$vdir/verify" bash "$VERIFY" "$vdir/image.iso" > "$vdir/out.txt" 2>&1
    section_3g "$vdir/out.txt" > "$vdir/3g.txt"
    nfail="$(grep -c '^FAIL' "$vdir/3g.txt" || true)"; npass="$(grep -c '^PASS' "$vdir/3g.txt" || true)"
    if [[ "$variant" == good ]]; then
        ok=1
        [[ "$nfail" -eq 0 ]] || ok=0
        # section 3e (directory modes of the stacked layers) has no failure for a live delta without /tmp
        if awk '/^== 3e\./ { f = 1; next } /^== / { f = 0 } f' "$vdir/out.txt" | grep -q '^FAIL'; then
            ok=0; echo "        section 3e fails on the good image:"; awk '/^== 3e\./ { f = 1; next } /^== / { f = 0 } f' "$vdir/out.txt" | grep '^FAIL' | sed 's/^/          /'
        fi
        # every group ran: the base checks, the package check, the live layer, the standard layer, sizes, manifests, menus
        for need in "base layer has no /etc/casper.conf" "base layer's dpkg status has no live-only package casper" \
                    "base layer's dpkg status has no live-only package finalrd" "base layer's /etc/cloud/cloud.cfg is not the live session's" \
                    "base layer's systemd-networkd-wait-online is not replaced by a symlink" "base layer's snapd seed.yaml names only snap files" \
                    "live layer is not a placeholder" "live layer holds what the base had taken out" "live layer's snapd seed.yaml still names the installer snap" \
                    "live layer carries the live session's /etc/cloud/cloud.cfg" "live layer's dpkg status lists casper as installed" \
                    "minimal.standard.squashfs is still the empty placeholder" "layer minimal.standard.live: .size" \
                    "minimal.manifest lists exactly" "minimal.standard.live.manifest lists exactly" "grub.cfg: all 3 kernel lines are the stock ones" \
                    "loopback.cfg: all 2 kernel lines are the stock ones" "grub.cfg: the kernel lines equal the base ISO's" \
                    "loopback.cfg: the kernel lines equal the base ISO's"; do
            grep -q "^PASS  .*$need" "$vdir/3g.txt" || { ok=0; echo "        missing PASS: $need"; }
        done
        # the re-pointed checks read the live layer's casper.conf
        for need in "live session user is not 'ubuntu'" "live session host name is not 'ubuntu'" "casper keeps BUILD_SYSTEM=Ubuntu"; do
            grep -q "^PASS  $need" "$vdir/out.txt" || { ok=0; echo "        missing PASS: $need"; }
        done
        if [[ "$ok" -eq 1 ]]; then echo "PASS  good image: section 3g has no failure ($npass checks passed)"
        else echo "FAIL  good image: section 3g reports $nfail failure(s) or lacks a group"; grep '^FAIL' "$vdir/3g.txt" | sed 's/^/        /'; BAD=$((BAD + 1)); fi
    else
        src="$vdir/3g.txt"; case "$variant" in live-conf-ubuntu-user | live-tmp-wrong-mode | live-root-mode | standard-no-tmp) src="$vdir/out.txt" ;; esac
        [[ -z "${VERIFY_TEST_VERBOSE:-}" ]] || { grep '^FAIL' "$vdir/3g.txt" | sed 's/^/        3g: /'; }
        if grep '^FAIL' "$src" | grep -qF -- "$want"; then
            echo "PASS  $variant: rejected ($(grep -cF -- "$want" "$src") FAIL line(s) say: $want)"
        else
            echo "FAIL  $variant: expected a FAIL saying '$want'"
            grep '^FAIL' "$vdir/3g.txt" | sed 's/^/        got: /' | head -n 5; BAD=$((BAD + 1))
        fi
    fi
    rm -rf "$vdir"
done

echo
if [[ "$BAD" -eq 0 ]]; then echo "all $N variants behaved"; else echo "$BAD of $N variant(s) misbehaved"; fi
[[ "$BAD" -eq 0 ]]
