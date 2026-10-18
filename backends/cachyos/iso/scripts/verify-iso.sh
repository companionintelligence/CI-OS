#!/usr/bin/env bash
#=============================================================================
# Verify a built Companion OS (CachyOS edition) ISO
#
# Inspects the ISO without root and without booting it. It extracts only what it needs (the boot menus, a handful of
# files, the root filesystem listing and a few directories of it) and asserts that
#
#   1.  the medium is what the decisions say: file name companion-os-plasma-<YYYY.MM.DD>-x86_64.iso, volume label
#       COMPANION_<YYYYMM> (<= 32 chars), publisher and application strings, El Torito BIOS + UEFI, MBR/GPT hybrid,
#       a sane size, and the files an archiso boot needs; the standalone GRUB (BOOTx64.EFI) searches for the medium by
#       the same /boot/<uuid>.uuid file the kernel lines name;
#   2.  the boot menus (GRUB grub.cfg + loopback.cfg, syslinux) carry Companion titles and no CachyOS or Arch product
#       string, keep archisobasedir / archisosearchuuid intact, point at kernels that are on the medium, and keep every
#       kernel / initrd line of the pinned upstream profile (drift guard; needs the upstream checkout, see below);
#       no CachyOS artwork is on the medium;
#   3.  airootfs.sfs: /etc/os-release has the Companion OS keys and ID=cachyos / ID_LIKE=arch unchanged (D4), the
#       os-release pacman hook is there, hostname, issue, motd, the About-System file, the wallpaper, the logo icon and
#       the colour scheme are Companion's, no CachyOS artwork came from our overlay, sshd is masked in the live
#       image and its drop-ins forbid root and password logins (D7), the live user is still liveuser with passwordless sudo;
#   3b. the installer entry point (D6): our launcher .desktop and /usr/local/bin/calamares-online.sh are there and
#       executable, the script applies the Companion overlay AFTER it reinstalls cachyos-calamares-next, and the
#       cachyos-hello install gate (cachyos.org/versions.json) cannot be reached from a default session;
#   4.  the package list contains what the live ISO needs and what overlay/packages.add adds, and none of what
#       overlay/packages.remove removes, and it equals the image's own pacman database;
#   5.  the Calamares overlay (/usr/share/ci-os/calamares) is consistent: YAML parses, branding says Companion OS,
#       GRUB (not Limine), efiBootloaderId, hostname, docker group, packages, no CachyOS endpoint, no GitHub-raw
#       dependency, no log upload, every instance has a config, every path it stages exists in the image;
#   6.  file modes: mkarchiso drops modes, so every file with a #! line that is not owned by a package must be
#       executable, sudoers drop-ins are 0440 and /etc/shadow is 0400; the slow-boot generator for virtual machines
#       (companion-vm-timeouts) is there and executable;
#   7.  build provenance (<iso>.build-info) when the build wrote it: upstream commit and base image digest equal
#       upstream.lock; whether the working tree it was built from was clean (REPO_TREE); the compatibility libraries of
#       compat-libs.lock (risk R1: the installer in the image needs older libraries than the repositories ship today) are in the
#       image byte for byte, and the build record carries the COMPAT_* keys of the step that put them there (a lock that lists no
#       library any more is satisfied by an image that has none and a record that says 0);
#   8.  integrity: the .sha256 next to the ISO matches it, and /arch/x86_64/airootfs.sha512 matches the squashfs.
#
# What is deliberately NOT asserted, because it is not ours to change (listed as KNOWN at the end): package, repository
# and kernel names (linux-cachyos, [cachyos] in pacman.conf, cachyos-* units), Arch strings inside Arch packages.
#
# Usage:
#   backends/cachyos/iso/scripts/verify-iso.sh path/to/companion-os-plasma-*.iso
#   VERIFY_KEEP=1 ...       keep the extracted files (printed at the end)
#   VERIFY_WORK=DIR ...     scratch space (needs about 4 GB free; must NOT be a macOS bind mount: the squashfs
#                           extraction needs root-owned files, device nodes are not touched)
#   VERIFY_REUSE=1 ...      with VERIFY_WORK: reuse an airootfs.sfs extracted by an earlier run of the same ISO
#   VERIFY_UPSTREAM_DIR=DIR a CachyOS-Live-ISO checkout at the pinned commit (upstream.lock): enables the kernel /
#                           initrd parity checks (section 2); without it they are listed under SKIPPED
#   VERIFY_FETCH_UPSTREAM=1 fetch the pinned commit with git (network) when VERIFY_UPSTREAM_DIR is not set
#   VERIFY_LOCK=FILE        upstream.lock (default: backends/cachyos/upstream.lock next to this script's repo)
#   VERIFY_COMPAT_LOCK=FILE compat-libs.lock (default: backends/cachyos/compat-libs.lock next to this script's repo)
#   VERIFY_GRUB_EXTRA_PARAMS="a=b c"  kernel parameters the overlay is allowed to ADD to the upstream kernel lines
#   VERIFY_MIN_MB / VERIFY_MAX_MB     size sanity window (default 1500 / 6144); VERIFY_MIN_ENTRIES the least files the squashfs may hold (1000)
#   VERIFY_SKIP_SFS_HASH=1  do not hash the squashfs against airootfs.sha512 (saves about 20 s)
#   VERIFY_REQUIRE_ALL=1    fail if any group of checks had to be skipped (use it where the tools and the checkout
#                           are expected to be there); without it they are listed under SKIPPED in the Summary
#   VERIFY_REQUIRE_CLEAN=1  fail unless the build record says the ISO was built from a clean checkout (REPO_TREE=clean); without
#                           it a dirty or unknown tree is only noted. Also fails a build whose compat-libs.lock review date had passed
#
# Needs: xorriso squashfs-tools (unsquashfs), awk sed grep od, sha256sum and sha512sum (or shasum);
#        python3 with PyYAML for the Calamares YAML checks (Arch: python python-yaml; listed under SKIPPED without);
#        git for the upstream checks. Inside the builder image on a Mac (the ISO is bind mounted read-only, the work
#        directory is the container's own filesystem):
#          docker run --rm --platform linux/amd64 --cpus 4 --memory 8g \
#              -v "$PWD:/repo:ro" -v /path/to/isodir:/iso:ro ci-cachyos-builder:latest \
#              /repo/backends/cachyos/iso/scripts/verify-iso.sh /iso/companion-os-plasma-2026.10.03-x86_64.iso
#        Exit status is non-zero if any check fails; 2 for a usage or tool error.
#
# Sourceable: with `source verify-iso.sh` nothing runs and the v_check_* functions can be called on fixtures
# (backends/cachyos/iso/tests/verify-selftest.sh does that). Written for bash 3.2 too.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

# The compat lock helpers (iso/scripts/lib/compat-lock.sh) are shared with the build, so the verifier reads the lock exactly as the stager does.
V_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$V_SCRIPT_DIR/lib/compat-lock.sh" ]; then
    # shellcheck source=lib/compat-lock.sh
    . "$V_SCRIPT_DIR/lib/compat-lock.sh"
    V_HAVE_COMPAT_LOCK=1
else
    V_HAVE_COMPAT_LOCK=0
fi

# ── decisions this script enforces (D1, D4, D6, D7) ─────────────────────────
V_ISO_NAME_RE='^companion-os-plasma-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-x86_64\.iso$'
V_LABEL_RE='^COMPANION_[0-9]{6}$'
V_PUBLISHER='Companion Intelligence <https://ci.computer>'
V_APPLICATION='Companion OS Live/Installer'
V_IMAGE_ID='companion-os-plasma'
# Brand words that must not appear in anything a user reads. The kernel (linux-cachyos), the [cachyos] repository and the
# cachyos-* package names are not "read" in this sense: they are identifiers, listed as KNOWN at the end.
V_BRAND_RE='cachy|arch[[:space:]]+linux|archlinux'
# Packages the live ISO cannot do without (kernels, boot modes, installer, desktop, network).
V_REQUIRED_PKGS="linux-cachyos linux-cachyos-lts mkinitcpio-archiso grub syslinux edk2-shell memtest86+ cachyos-calamares-next cachyos-keyring cachyos-hooks plasma-desktop plasma-login-manager networkmanager sudo polkit"
# sha256 of the CachyOS artwork the pinned upstream profile ships (archiso/grub/splash.png == archiso/syslinux/splash.png
# at 3215497, and archiso/syslinux/splash1.png): none of it may be on our medium (D9).
V_UPSTREAM_ART_SHA256="b5a6e75af70a2750438a780e68cc89f6106d205b88c79150db5686825420aa11 6d583d6dda3365e399dc15563c9a74a0eb259a6a07fe60e92e9acd15250febdf"
# Directories (inside the squashfs) whose package-unowned files must be executable when they start with #!.
V_EXEC_DIRS="/usr/local/bin /usr/local/sbin /usr/lib/ci-os /usr/libexec/ci-os /usr/share/ci-os /usr/share/libalpm/scripts"
# ...except these trees, which stage-installer.sh writes as data (mode 644) and which are started with `bash <file>`: the
# installer overlay and the provisioning tree it copies to the target.
V_EXEC_EXEMPT="/usr/share/ci-os/calamares/"

PASS=0; FAIL=0
SKIPPED=()
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
note() { printf 'info  %s\n' "$*"; }
# skip: a group of checks that did not run. It is a note where it happens AND a SKIPPED block in the Summary, so a run
# without the tools or the checkout cannot print "0 failed" with checks missing and nobody the wiser.
skip() { SKIPPED+=("$*"); printf 'info  SKIPPED: %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }

# ── small helpers (portable: no GNU-only options, bash 3.2) ─────────────────
v_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
v_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
v_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
v_sha512() { if command -v sha512sum >/dev/null 2>&1; then sha512sum "$1" | cut -d' ' -f1; else shasum -a 512 "$1" | cut -d' ' -f1; fi; }
# v_same_file A B: both files exist and have the same bytes, by hash. Not cmp or diff: they come from diffutils, which the Arch
# builder image does not have (a run in it printed "cmp: command not found" and failed two checks whose inputs were identical).
v_same_file() { [ -f "$1" ] && [ -f "$2" ] && [ "$(v_sha256 "$1")" = "$(v_sha256 "$2")" ]; }
v_git() { local d="$1"; shift; git -c "safe.directory=*" -C "$d" "$@"; }   # v_git DIR args: a bind-mounted checkout is owned by another uid
v_has() { grep -q -E -- "$2" "$1" 2>/dev/null; }                 # v_has FILE ERE
v_hasf() { grep -q -F -- "$2" "$1" 2>/dev/null; }                # v_hasf FILE FIXED
v_png_is() { [ "$(head -c8 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; }
# v_png_info FILE: "WIDTH HEIGHT BITDEPTH COLORTYPE", nothing (status 1) if it is not a PNG. IHDR: 8 byte signature, 4 length,
# "IHDR", width (16), height (20), bit depth (24), colour type (25).
v_png_info() {
    v_png_is "$1" || return 1
    od -An -tu1 -j16 -N10 "$1" 2>/dev/null | awk '{ print $1*16777216+$2*65536+$3*256+$4, $5*16777216+$6*65536+$7*256+$8, $9, $10 }'
}
# v_osrel_get FILE KEY: the value of KEY with one pair of quotes removed (first occurrence).
v_osrel_get() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

# ── listing helpers ─────────────────────────────────────────────────────────
# The squashfs listing is normalised once to TAB separated "mode size path target" (target only for symlinks), path
# starting with "/". Raw `unsquashfs -ll` lines look like:
#   lrwxrwxrwx root/root                 9 2026-10-03 15:31 squashfs-root/etc/foo -> /dev/null
v_normalise_listing() {
    awk '{
        mode = $1; size = $3
        i = index($0, "squashfs-root")
        if (i == 0) next
        rest = substr($0, i + 13)
        target = ""
        if (substr(mode, 1, 1) == "l") {
            j = index(rest, " -> ")
            if (j > 0) { target = substr(rest, j + 4); rest = substr(rest, 1, j - 1) }
        }
        if (rest == "") rest = "/"
        printf "%s\t%s\t%s\t%s\n", mode, size, rest, target
    }'
}
v_lst_has() { awk -F'\t' -v p="$2" '$3 == p { f = 1; exit } END { exit !f }' "$1"; }                # LISTING PATH
v_lst_mode() { awk -F'\t' -v p="$2" '$3 == p { print $1; exit }' "$1"; }
v_lst_size() { awk -F'\t' -v p="$2" '$3 == p { print $2; exit }' "$1"; }
v_lst_target() { awk -F'\t' -v p="$2" '$3 == p { print $4; exit }' "$1"; }
v_lst_prefix() { awk -F'\t' -v p="$2" 'index($3, p "/") == 1 { f = 1; exit } END { exit !f }' "$1"; }   # something below PATH
# v_mode_is_exec MODE: any execute bit of an `ls -l` style mode string ("-rwxr-xr-x"): positions 4, 7 and 10.
v_mode_is_exec() { case "$1" in ???[xs]*|??????[xs]*|?????????[xt]*) return 0 ;; *) return 1 ;; esac; }

#=============================================================================
# 1. The medium
#=============================================================================
# v_check_iso_name BASENAME: D1. A build in progress (.partial) or quarantined (.rejected) image is judged by its
# final name.
v_check_iso_name() {
    local n="$1"
    n="${n%.partial}"; n="${n%.rejected}"
    if [[ "$n" =~ $V_ISO_NAME_RE ]]; then
        pass "ISO file name follows D1: $n"
    else
        fail "ISO file name '$n' is not companion-os-plasma-<YYYY.MM.DD>-x86_64.iso (D1)"
    fi
    if printf '%s' "$n" | grep -qi 'cachy'; then fail "ISO file name contains the CachyOS mark (D1): $n"; else pass "ISO file name does not contain the CachyOS mark"; fi
}
# v_check_label LABEL [ISO_VERSION]: D1. The label's month must be the version's month when the version is given.
v_check_label() {
    local l="$1" ver="${2:-}" ym
    if [[ "$l" =~ $V_LABEL_RE ]]; then pass "volume label follows D1: $l"; else fail "volume label '$l' is not COMPANION_<YYYYMM> (D1)"; fi
    if [ "${#l}" -le 32 ] && [ -n "$l" ]; then pass "volume label is ${#l} characters (ISO 9660 allows 32)"; else fail "volume label is ${#l} characters (ISO 9660 allows 32)"; fi
    if [ -n "$ver" ]; then
        ym="$(printf '%s' "$ver" | sed -n -E 's/^([0-9]{4})\.([0-9]{2})\..*/\1\2/p')"
        if [ -n "$ym" ] && [ "$l" = "COMPANION_$ym" ]; then pass "volume label month equals the version's ($ver)"
        else fail "volume label '$l' does not carry the month of /arch/version ($ver)"; fi
    fi
}
# v_check_pvd PUBLISHER APPLICATION: compared as stored, which is upper case (ISO 9660 a-characters).
v_check_pvd() {
    local pub="$1" app="$2"
    if [ "$(v_upper "$pub")" = "$(v_upper "$V_PUBLISHER")" ]; then pass "publisher is '$V_PUBLISHER'"; else fail "publisher is '$pub', expected '$V_PUBLISHER' (D1; the field is stored upper case)"; fi
    if [ "$(v_upper "$app")" = "$(v_upper "$V_APPLICATION")" ]; then pass "application is '$V_APPLICATION'"; else fail "application is '$app', expected '$V_APPLICATION' (D1; the field is stored upper case)"; fi
    if printf '%s\n%s\n' "$pub" "$app" | grep -qi 'cachy'; then fail "publisher or application names CachyOS"; else pass "publisher and application do not name CachyOS"; fi
}
# v_check_boot_records ELTORITO_REPORT SYSAREA_REPORT: BIOS + UEFI El Torito, MBR active + EFI partition, GPT.
v_check_boot_records() {
    local et="$1" sa="$2"
    if grep -q -E 'El Torito boot img.*BIOS' "$et" 2>/dev/null; then pass "El Torito: BIOS boot image present"; else fail "El Torito: no BIOS boot image"; fi
    if grep -q -E 'El Torito boot img.*UEFI' "$et" 2>/dev/null; then pass "El Torito: UEFI boot image present"; else fail "El Torito: no UEFI boot image"; fi
    if grep -q -E 'MBR partition +:.* 0x80 ' "$sa" 2>/dev/null; then pass "MBR: an active (0x80) partition covers the ISO (isohybrid)"; else fail "MBR: no active partition (not isohybrid: a USB stick would not boot on BIOS)"; fi
    if grep -q -E 'MBR partition +:.* 0xef ' "$sa" 2>/dev/null; then pass "MBR: an EFI (0xef) partition is present"; else fail "MBR: no 0xef EFI partition (UEFI would not find the ESP on a USB stick)"; fi
    if grep -q -E '^GPT +:|GPT partition name' "$sa" 2>/dev/null; then pass "GPT is present (hybrid)"; else fail "no GPT in the system area"; fi
}
# v_check_size BYTES MIN_MB MAX_MB
v_check_size() {
    local bytes="$1" min="$2" max="$3" mb
    mb=$((bytes / 1048576))
    if [ $((bytes % 2048)) -eq 0 ]; then pass "ISO size is a whole number of 2048-byte sectors"; else fail "ISO size $bytes is not a multiple of 2048"; fi
    if [ "$mb" -ge "$min" ] && [ "$mb" -le "$max" ]; then pass "ISO size ${mb} MiB is within ${min}..${max} MiB"; else fail "ISO size ${mb} MiB is outside ${min}..${max} MiB (an empty or runaway build?)"; fi
}
# v_check_medium_files FILELIST: the files an archiso boot needs. FILELIST has one ISO path per line.
v_check_medium_files() {
    local fl="$1" f missing=0
    for f in /arch/x86_64/airootfs.sfs /arch/x86_64/airootfs.sha512 /arch/boot/x86_64/vmlinuz-linux-cachyos \
             /arch/boot/x86_64/initramfs-linux-cachyos.img /arch/boot/x86_64/vmlinuz-linux-cachyos-lts \
             /arch/boot/x86_64/initramfs-linux-cachyos-lts.img /arch/pkglist.x86_64.txt /arch/version \
             /EFI/BOOT/BOOTx64.EFI /boot/grub/grub.cfg /boot/grub/loopback.cfg /boot/syslinux/syslinux.cfg \
             /boot/syslinux/isolinux.bin /boot/syslinux/archiso_head.cfg /boot/syslinux/archiso_sys-linux.cfg; do
        if ! grep -Fxq -- "$f" "$fl" 2>/dev/null; then fail "MISSING on the medium: $f"; missing=$((missing + 1)); fi
    done
    [ "$missing" -eq 0 ] && pass "every file an archiso boot needs is on the medium"
    return 0
}
# v_uuid_of FILELIST: the one /boot/<uuid>.uuid search file; prints its uuid, status 1 unless there is exactly one.
v_uuid_of() {
    local u n
    u="$(grep -E '^/boot/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.uuid$' "$1" 2>/dev/null)"
    n="$(printf '%s\n' "$u" | grep -c . || true)"
    [ "$n" = 1 ] || return 1
    u="${u#/boot/}"; printf '%s\n' "${u%.uuid}"
}
# v_check_efi_search EFI_FILE UUID: the standalone GRUB carries the search file name as a plain string.
v_check_efi_search() {
    local efi="$1" uuid="$2"
    if [ "$(head -c2 "$efi" 2>/dev/null)" != "MZ" ]; then fail "BOOTx64.EFI is not a PE file (no MZ header)"; return 0; fi
    if grep -a -q -F -- "/boot/$uuid.uuid" "$efi" 2>/dev/null; then pass "BOOTx64.EFI searches for /boot/$uuid.uuid, the medium's own search file"
    else fail "BOOTx64.EFI does not mention /boot/$uuid.uuid: the UEFI GRUB would not find this medium"; fi
}

#=============================================================================
# 2. Boot menus
#=============================================================================
# v_grub_titles FILE: the text of every menuentry title (one per line).
v_grub_titles() { sed -n -E "s/^[[:space:]]*menuentry[[:space:]]+[\"']([^\"']*)[\"'].*/\\1/p" "$1" 2>/dev/null; }
# v_grub_ids FILE: the --id of every menuentry.
v_grub_ids() { sed -n -E "s/^[[:space:]]*menuentry[[:space:]].*--id[[:space:]]+[\"']?([^\"' ]+)[\"']?.*/\\1/p" "$1" 2>/dev/null; }

# v_check_grub_cfg FILE NAME FILELIST UUID [needs_background]: titles, default, background, kernel lines.
v_check_grub_cfg() {
    local f="$1" name="$2" fl="$3" uuid="$4" bg="${5:-1}" titles bad n d ids kern initrd line params
    if [ ! -s "$f" ]; then fail "$name is missing or empty"; return 0; fi
    titles="$(v_grub_titles "$f")"
    n="$(printf '%s\n' "$titles" | grep -c . || true)"
    if [ "$n" -ge 4 ]; then pass "$name has $n menu entries"; else fail "$name has only $n menu entries"; fi
    bad="$(printf '%s\n' "$titles" | grep -i -E "$V_BRAND_RE" || true)"
    if [ -z "$bad" ]; then pass "$name: no menu title names CachyOS or Arch"; else fail "$name: menu titles that still name CachyOS or Arch: $(printf '%s' "$bad" | tr '\n' '|')"; fi
    if printf '%s\n' "$titles" | grep -q -E '(^|[^A-Za-z])GIT([^A-Za-z]|$)'; then fail "$name: a menu title shows the raw upstream version placeholder 'GIT'"; fi
    if printf '%s\n' "$titles" | grep -q 'Companion OS'; then pass "$name: menu titles say Companion OS"; else fail "$name: no menu title says Companion OS"; fi
    # default= must name an entry that exists (by --id, by title or by index).
    d="$(sed -n -E 's/^[[:space:]]*default=["'"'"']?([^"'"'"' ]+).*/\1/p' "$f" | tail -n 1)"
    ids="$(v_grub_ids "$f")"
    if [ -z "$d" ]; then pass "$name: no default= (GRUB boots the first entry)"
    elif printf '%s\n' "$ids" | grep -Fxq -- "$d" || printf '%s\n' "$titles" | grep -Fxq -- "$d" || [[ "$d" =~ ^[0-9]+$ ]]; then pass "$name: default=$d names an existing entry"
    else fail "$name: default=$d names no menu entry (ids: $(printf '%s' "$ids" | tr '\n' ' '))"; fi
    if [ "$bg" = 1 ]; then
        d="$(sed -n -E 's/^[[:space:]]*background_image[[:space:]]+(-m[[:space:]]+[a-z]+[[:space:]]+)?["'"'"']?([^"'"'"' ]+).*/\2/p' "$f" | head -n 1)"
        d="$(printf '%s' "$d" | sed -E 's#^\([^)]*\)##')"
        if [ -z "$d" ]; then fail "$name: no background_image (the UEFI menu would be unthemed)"
        elif [[ "$d" == /* ]] && grep -Fxq -- "$d" "$fl"; then pass "$name: background_image $d is on the medium"
        elif [[ "$d" == /* ]]; then fail "$name: background_image $d is not on the medium"
        else fail "$name: background_image '$d' is not an absolute path on the medium"; fi
        if v_has "$f" '^[[:space:]]*(set[[:space:]]+)?menu_color_normal=' && v_has "$f" '^[[:space:]]*(set[[:space:]]+)?menu_color_highlight='; then pass "$name: menu colours are set"
        else fail "$name: menu_color_normal / menu_color_highlight are not set"; fi
    fi
    # kernel lines: structure
    n=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$((n + 1))
        kern="$(printf '%s\n' "$line" | awk '{print $2}')"
        params="$line"
        case "$name" in
            loopback.cfg)
                if ! printf '%s' "$params" | grep -q -E 'archisobasedir=arch' || ! printf '%s' "$params" | grep -q -E 'img_dev=.*img_loop='; then
                    fail "$name: a kernel line lacks archisobasedir=arch or img_dev=/img_loop=: $line"
                fi ;;
            *)
                if ! printf '%s' "$params" | grep -q -E 'archisobasedir=arch' || ! printf '%s' "$params" | grep -q -F "archisosearchuuid=$uuid"; then
                    fail "$name: a kernel line lacks archisobasedir=arch or archisosearchuuid=$uuid: $line"
                fi ;;
        esac
        case "$kern" in
            /boot/memtest86+/*|/shell*) ;;
            *) grep -Fxq -- "$kern" "$fl" || fail "$name: kernel $kern is not on the medium" ;;
        esac
    done <<EOF
$(grep -E '^[[:space:]]*linux[[:space:]]+/arch/' "$f" | sed -E 's/^[[:space:]]+//')
EOF
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        initrd="$(printf '%s\n' "$line" | awk '{print $2}')"
        grep -Fxq -- "$initrd" "$fl" || fail "$name: initrd $initrd is not on the medium"
    done <<EOF
$(grep -E '^[[:space:]]*initrd[[:space:]]+/arch/' "$f" | sed -E 's/^[[:space:]]+//')
EOF
    if [ "$n" -ge 1 ]; then pass "$name: $n kernel line(s) checked (archiso parameters, kernel and initrd on the medium)"; else fail "$name: no kernel line at all"; fi
    if grep -q -E 'archisolabel=' "$f"; then note "$name: uses archisolabel=; the label is then part of the boot path"; fi
    return 0
}

# v_boot_lines FILE ERE: kernel-ish lines, trimmed, in order.
v_boot_lines() { grep -E "$2" "$1" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
# v_subst_upstream FILE INSTALL_DIR ARCH UUID: the upstream template as mkarchiso writes it.
v_subst_upstream() { sed -e "s|%INSTALL_DIR%|$2|g" -e "s|%ARCH%|$3|g" -e "s|%ARCHISO_UUID%|$4|g" "$1"; }
# v_strip_params LINE "p1 p2": LINE without the given parameters.
v_strip_params() {
    local line="$1" p
    for p in $2; do line="$(printf '%s' "$line" | sed -e "s| $p\$||" -e "s| $p | |g")"; done
    printf '%s\n' "$line"
}
# v_check_parity ISO_CFG UPSTREAM_CFG LABEL ERE: every kernel / initrd line the pinned upstream has is in ISO_CFG,
# once the overlay's allowed extra parameters (VERIFY_GRUB_EXTRA_PARAMS) are removed from the ISO's line.
v_check_parity() {
    local iso="$1" up="$2" label="$3" ere="$4" u missing=0 n=0 extra
    local iso_lines up_lines
    iso_lines="$(v_boot_lines "$iso" "$ere")"
    up_lines="$(v_boot_lines "$up" "$ere")"
    if [ -z "$up_lines" ]; then fail "$label: the upstream file has no kernel / initrd lines to compare with"; return 0; fi
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        n=$((n + 1))
        if ! printf '%s\n' "$iso_lines" | while IFS= read -r l; do v_strip_params "$l" "${VERIFY_GRUB_EXTRA_PARAMS:-}"; done | grep -Fxq -- "$u"; then
            fail "$label: upstream line is not in the ISO (changed or removed): $u"; missing=$((missing + 1))
        fi
    done <<EOF
$up_lines
EOF
    [ "$missing" -eq 0 ] && pass "$label: all $n upstream kernel / initrd lines are in the ISO unchanged"
    extra="$(printf '%s\n' "$iso_lines" | while IFS= read -r l; do v_strip_params "$l" "${VERIFY_GRUB_EXTRA_PARAMS:-}"; done | grep -c -v -F -x -f <(printf '%s\n' "$up_lines") || true)"
    [ "${extra:-0}" -gt 0 ] && note "$label: $extra kernel / initrd line(s) in the ISO are not upstream's (Companion additions; their structure is checked above)"
    return 0
}

# v_check_syslinux DIR FILELIST UUID: BIOS menu.
v_check_syslinux() {
    local d="$1" fl="$2" uuid="$3" f title bad labels def bg w h info res p ref missing=0 n
    if [ ! -s "$d/archiso_head.cfg" ] || [ ! -s "$d/archiso_sys-linux.cfg" ]; then fail "syslinux: archiso_head.cfg / archiso_sys-linux.cfg are missing"; return 0; fi
    title="$(sed -n -E 's/^MENU TITLE[[:space:]]+//p' "$d/archiso_head.cfg" | head -n 1)"
    if printf '%s' "$title" | grep -q 'Companion OS' && ! printf '%s' "$title" | grep -qi -E "$V_BRAND_RE"; then pass "syslinux: MENU TITLE is '$title'"
    else fail "syslinux: MENU TITLE is '${title:-<none>}', expected Companion OS and no CachyOS/Arch"; fi
    bad=""
    for f in archiso_head.cfg archiso_sys.cfg archiso_sys-linux.cfg archiso_tail.cfg; do
        [ -f "$d/$f" ] || continue
        # Labels, help texts and titles: everything except the LINUX / INITRD / APPEND lines (identifiers).
        if grep -v -E '^[[:space:]]*(LINUX|INITRD|APPEND|KERNEL)[[:space:]]' "$d/$f" | grep -qi -E "$V_BRAND_RE"; then
            bad="$bad $f"
        fi
    done
    if [ -z "$bad" ]; then pass "syslinux: no label, title or help text names CachyOS or Arch"; else fail "syslinux: CachyOS or Arch words in:$bad"; fi
    labels="$(sed -n -E 's/^LABEL[[:space:]]+//p' "$d/archiso_sys-linux.cfg" "$d/archiso_tail.cfg" 2>/dev/null)"
    def="$(sed -n -E 's/^DEFAULT[[:space:]]+//p' "$d/archiso_sys.cfg" | head -n 1)"
    if [ -n "$def" ] && printf '%s\n' "$labels" | grep -Fxq -- "$def"; then pass "syslinux: DEFAULT $def names an existing LABEL"
    else fail "syslinux: DEFAULT '${def:-<none>}' names no LABEL (labels: $(printf '%s' "$labels" | tr '\n' ' '))"; fi
    # Every absolute path a menu entry loads is on the medium; relative COM32 / KERNEL names are in /boot/syslinux.
    for f in archiso_sys-linux.cfg archiso_tail.cfg; do
        [ -f "$d/$f" ] || continue
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            case "$p" in
                /*) ref="$p" ;;
                *)  ref="/boot/syslinux/$p" ;;
            esac
            if ! grep -Fxq -- "$ref" "$fl"; then fail "syslinux: $f loads $p, which is not on the medium ($ref)"; missing=$((missing + 1)); fi
        done <<EOF
$(sed -n -E 's/^[[:space:]]*(LINUX|INITRD|COM32|KERNEL)[[:space:]]+([^[:space:]]+).*/\2/p' "$d/$f")
EOF
    done
    [ "$missing" -eq 0 ] && pass "syslinux: every file the menu loads is on the medium"
    n=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        n=$((n + 1))
        printf '%s' "$p" | grep -q -E 'archisobasedir=arch' && printf '%s' "$p" | grep -q -F "archisosearchuuid=$uuid" || fail "syslinux: an APPEND line lacks archisobasedir=arch or archisosearchuuid=$uuid: $p"
    done <<EOF
$(grep -E '^[[:space:]]*APPEND[[:space:]]' "$d/archiso_sys-linux.cfg")
EOF
    [ "$n" -ge 1 ] && pass "syslinux: $n APPEND line(s) checked" || fail "syslinux: no APPEND line"
    # The background: the BIOS menu runs in a VESA mode (640x480 unless MENU RESOLUTION says otherwise); a boot test of the
    # research demo (QEMU, SeaBIOS, 2026-10-16) showed upstream's 1920x1080 splash.png as a black background there. Assumption: the image
    # must be the size of the mode.
    bg="$(sed -n -E 's/^MENU BACKGROUND[[:space:]]+//p' "$d/archiso_head.cfg" | head -n 1)"
    res="$(sed -n -E 's/^MENU RESOLUTION[[:space:]]+([0-9]+)[[:space:]]+([0-9]+).*/\1 \2/p' "$d/archiso_head.cfg" | head -n 1)"
    [ -n "$res" ] || res="640 480"
    if [ -z "$bg" ]; then fail "syslinux: no MENU BACKGROUND"
    elif [ ! -f "$d/$bg" ]; then fail "syslinux: MENU BACKGROUND $bg is not in /boot/syslinux"
    elif info="$(v_png_info "$d/$bg")" && [ -n "$info" ]; then
        w="${info%% *}"; h="${info#* }"; h="${h%% *}"
        if [ "$w $h" = "$res" ]; then pass "syslinux: background $bg is a ${w}x${h} PNG, the size of the menu mode"
        else fail "syslinux: background $bg is ${w}x${h} but the menu mode is ${res% *}x${res#* } (observed: a larger image showed as black)"; fi
    else fail "syslinux: background $bg is not a PNG"; fi
    return 0
}

# v_check_art_hashes FILE...: none of the given files is CachyOS artwork shipped by the pinned upstream profile (D9).
v_check_art_hashes() {
    local f h bad=0 n=0
    for f in "$@"; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        h="$(v_sha256 "$f")"
        case " $V_UPSTREAM_ART_SHA256 " in
            *" $h "*) fail "CachyOS artwork is on the medium: ${f#*/iso/} (sha256 $h is upstream's splash image; D9)"; bad=$((bad + 1)) ;;
        esac
    done
    [ "$bad" -eq 0 ] && [ "$n" -gt 0 ] && pass "none of the $n boot-menu images is CachyOS artwork (sha256 against upstream's)"
    [ "$n" -eq 0 ] && fail "no boot-menu image to look at (grub or syslinux splash missing)"
    return 0
}

#=============================================================================
# 3. Identity and live image
#=============================================================================
# v_token_ansi TOKENS_SH: the console colour D4 derives from the brand tokens (CI_DARK_PRIMARY as 38;2;R;G;B). The file is
# read, never sourced.
v_token_ansi() {
    local hex
    hex="$(sed -n 's/^CI_DARK_PRIMARY="#\([0-9a-fA-F]\{6\}\)".*/\1/p' "$1" 2>/dev/null | head -n 1)"
    [ -n "$hex" ] || return 1
    printf '38;2;%d;%d;%d\n' "0x${hex%????}" "0x$(printf '%s' "$hex" | cut -c3-4)" "0x${hex#????}"
}
# v_check_os_release FILE [IMAGE_VERSION] [EXPECTED_ANSI_COLOR]: D4.
v_check_os_release() {
    local f="$1" iver="${2:-}" want_ansi="${3:-}" k v bad
    if [ ! -s "$f" ]; then fail "os-release is missing or empty"; return 0; fi
    check_kv() { # key expected-regex description
        v="$(v_osrel_get "$f" "$1")"
        if [[ "$v" =~ $2 ]]; then pass "os-release $1=$v"; else fail "os-release $1='${v:-<missing>}' ($3)"; fi
    }
    check_kv NAME '^Companion OS$' 'expected Companion OS'
    check_kv PRETTY_NAME '^Companion OS .+$' 'expected "Companion OS <version>"'
    check_kv ID '^cachyos$' 'D4 keeps ID=cachyos: CI-Hub and CachyOS tools key off it'
    check_kv ID_LIKE '^arch$' 'D4: exactly one token, CI-Hub string-matches it'
    check_kv VARIANT '^Plasma \(based on CachyOS\)$' 'D4: Plasma (based on CachyOS)'
    check_kv HOME_URL '^https://ci\.computer$' 'D4'
    check_kv SUPPORT_URL '^https://ci\.computer/support$' 'D4'
    check_kv BUG_REPORT_URL '^https://ci\.computer/bugs$' 'as the Ubuntu edition'
    check_kv PRIVACY_POLICY_URL '^https://ci\.computer/privacy$' 'as the Ubuntu edition'
    check_kv LOGO '^ci-os-logo$' 'D4'
    check_kv ANSI_COLOR '^38;2;[0-9]{1,3};[0-9]{1,3};[0-9]{1,3}$' 'D4: a 24-bit colour from the brand tokens'
    v="$(v_osrel_get "$f" ANSI_COLOR)"
    if [ "$v" = "38;2;23;147;209" ]; then fail "os-release ANSI_COLOR is CachyOS's blue (38;2;23;147;209), not a brand-token colour (D4)"
    elif [ -n "$want_ansi" ]; then
        if [ "$v" = "$want_ansi" ]; then pass "os-release ANSI_COLOR equals the brand token CI_DARK_PRIMARY ($want_ansi)"; else fail "os-release ANSI_COLOR '${v:-<missing>}' is not the brand token CI_DARK_PRIMARY ($want_ansi)"; fi
    fi
    check_kv CI_OS_ID '^ci-os$' 'as the Ubuntu edition'
    check_kv CI_OS_VERSION '^[0-9]+(\.[0-9]+)*.*$' 'as the Ubuntu edition'
    check_kv CI_OS_BUILD '^[0-9]{8}$' 'as the Ubuntu edition: the build day'
    check_kv IMAGE_ID "^$V_IMAGE_ID\$" 'mkarchiso appends iso_name (D1)'
    if [ -n "$iver" ]; then check_kv IMAGE_VERSION "^$(printf '%s' "$iver" | sed 's/\./\\./g')\$" 'mkarchiso appends iso_version'; fi
    # CachyOS may appear in ID and VARIANT only (D4).
    bad="$(grep -i -E 'cachy' "$f" | grep -v -E '^(ID|VARIANT)=' || true)"
    if [ -z "$bad" ]; then pass "os-release names CachyOS only in ID and VARIANT"; else fail "os-release names CachyOS outside ID and VARIANT: $(printf '%s' "$bad" | tr '\n' '|')"; fi
    bad="$(grep -i -E 'arch linux|archlinux' "$f" | grep -v -E '^ID_LIKE=' || true)"
    if [ -z "$bad" ]; then pass "os-release has no Arch Linux product string"; else fail "os-release names Arch Linux: $(printf '%s' "$bad" | tr '\n' '|')"; fi
    return 0
}

# v_check_os_release_hook FILE: the later-sorting hook that rewrites the whole file (D4).
v_check_os_release_hook() {
    local f="$1" first
    if [ ! -s "$f" ]; then fail "zz-ci-os-os-release.hook is missing or empty"; return 0; fi
    v_has "$f" '^When[[:space:]]*=[[:space:]]*PostTransaction$' && pass "os-release hook runs PostTransaction" || fail "os-release hook is not When = PostTransaction"
    v_has "$f" '^Target[[:space:]]*=[[:space:]]*filesystem$' && pass "os-release hook triggers on the filesystem package (the transaction cachyos-hooks reacts to)" || fail "os-release hook has no Target = filesystem"
    v_has "$f" '^Type[[:space:]]*=[[:space:]]*Package$' && pass "os-release hook is Type = Package" || fail "os-release hook is not Type = Package"
    v_has "$f" '^Exec[[:space:]]*=' && pass "os-release hook has an Exec" || fail "os-release hook has no Exec"
    first="$(printf '%s\n%s\n%s\n%s\n' 'os-release.hook' 'lsb-release.hook' 'cachyos-branding.hook' "${f##*/}" | LC_ALL=C sort | tail -n 1)"
    [ "$first" = "${f##*/}" ] && pass "the hook name sorts after cachyos-hooks' os-release.hook, lsb-release.hook and cachyos-branding.hook" || fail "the hook name ${f##*/} sorts before one of cachyos-hooks' hooks, which would then rewrite our file"
    if grep -i -q 'sed -i' "$f" && ! grep -q -E 'cat|tee|install|printf|>' "$f"; then note "the hook seems to patch os-release with sed; D4 asks for a whole-file rewrite"; fi
    return 0
}

# v_check_hook_exec LISTING HOOKFILE NAME: the Exec line of one of our hooks. Every script of ours it names is in the image;
# the command itself (first word) must be executable. `/usr/bin/bash /usr/share/libalpm/scripts/x` runs x through bash, so x
# only has to exist, but a mode-less script is still listed by section 6.
v_check_hook_exec() {
    local l="$1" hook="$2" name="$3" line tok first=1 ok=1
    line="$(sed -n -E 's/^Exec[[:space:]]*=[[:space:]]*//p' "$hook" | head -n 1)"
    if [ -z "$line" ]; then fail "hook $name has no Exec line"; return 0; fi
    for tok in $line; do
        case "$tok" in
            /usr/local/*|/usr/lib/ci-os/*|/usr/libexec/ci-os/*|/usr/share/ci-os/*|/usr/share/libalpm/scripts/*ci-os*)
                if ! v_lst_has "$l" "$tok"; then fail "hook $name names $tok, which is not in the image"; ok=0
                elif [ "$first" -eq 1 ] && ! v_mode_is_exec "$(v_lst_mode "$l" "$tok")"; then fail "hook $name runs $tok directly, but it is not executable ($(v_lst_mode "$l" "$tok"))"; ok=0
                fi ;;
        esac
        first=0
    done
    [ "$ok" -eq 1 ] && pass "hook $name: the scripts of ours it runs are in the image"
    return 0
}

# v_check_lsb_release FILE: lsb_release -d is a surface too; the hook that writes os-release writes this file whole.
v_check_lsb_release() {
    local f="$1" d
    if [ ! -s "$f" ]; then fail "/etc/lsb-release is missing"; return 0; fi
    d="$(v_osrel_get "$f" DISTRIB_DESCRIPTION)"
    if [[ "$d" =~ ^Companion\ OS ]]; then pass "lsb-release DISTRIB_DESCRIPTION=$d"; else fail "lsb-release DISTRIB_DESCRIPTION='${d:-<missing>}', expected Companion OS... (cachyos-hooks writes CachyOS there)"; fi
}

# v_check_carryover LISTING LISTFILE ROOT: the manifest of what the installed system gets from the live image (one absolute
# path per line, # comments, a directory is copied whole): every path is in the image, the script that copies is executable.
v_check_carryover() {
    local l="$1" list="$2" path n=0 miss=0
    if [ ! -s "$list" ]; then fail "usr/share/ci-os/installed/carry-over.list is missing: nothing says what the installed system gets from this image"; return 0; fi
    while IFS= read -r path || [ -n "$path" ]; do
        case "$path" in ''|'#'*) continue ;; esac
        n=$((n + 1))
        if v_lst_has "$l" "${path%/}" || v_lst_prefix "$l" "${path%/}"; then :; else fail "carry-over.list names $path, which is not in the image"; miss=$((miss + 1)); fi
    done < "$list"
    if [ "$n" -eq 0 ]; then fail "carry-over.list names no path"
    elif [ "$miss" -eq 0 ]; then pass "all $n path(s) of carry-over.list are in the image"; fi
    if v_lst_has "$l" /usr/share/ci-os/installed/carry-over && v_mode_is_exec "$(v_lst_mode "$l" /usr/share/ci-os/installed/carry-over)"; then pass "/usr/share/ci-os/installed/carry-over is executable"
    else fail "/usr/share/ci-os/installed/carry-over is missing or not executable"; fi
    return 0
}

# v_check_release_stamp RELEASEFILE OSRELEASE: /usr/share/ci-os/release is what the os-release hook reads; the os-release in the
# image was written from it, so the two agree. Keys: CI_OS_VERSION, CI_OS_BUILD, CI_OS_ANSI_COLOR.
v_check_release_stamp() {
    local rf="$1" osr="$2" a b
    if [ ! -s "$rf" ]; then fail "usr/share/ci-os/release is missing: the os-release hook would write a PRETTY_NAME without a version"; return 0; fi
    a="$(v_osrel_get "$rf" CI_OS_VERSION)"; b="$(v_osrel_get "$osr" CI_OS_VERSION)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "usr/share/ci-os/release CI_OS_VERSION equals os-release's ($a)"; else fail "usr/share/ci-os/release CI_OS_VERSION '${a:-<missing>}' differs from os-release's '${b:-<missing>}'"; fi
    a="$(v_osrel_get "$rf" CI_OS_BUILD)"; b="$(v_osrel_get "$osr" CI_OS_BUILD)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "usr/share/ci-os/release CI_OS_BUILD equals os-release's ($a)"; else fail "usr/share/ci-os/release CI_OS_BUILD '${a:-<missing>}' differs from os-release's '${b:-<missing>}'"; fi
    a="$(v_osrel_get "$rf" CI_OS_ANSI_COLOR)"; b="$(v_osrel_get "$osr" ANSI_COLOR)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "usr/share/ci-os/release CI_OS_ANSI_COLOR equals os-release's ANSI_COLOR"; else fail "usr/share/ci-os/release CI_OS_ANSI_COLOR '${a:-<missing>}' differs from os-release's ANSI_COLOR '${b:-<missing>}'"; fi
}

# v_check_wallpaper_package LISTING DIR: a Plasma wallpaper package (KPackage) has a metadata.json and contents/images/.
v_check_wallpaper_package() {
    local l="$1" d="$2"
    if v_lst_has "$l" "$d/metadata.json"; then pass "wallpaper package $d has a metadata.json"; else fail "wallpaper package $d has no metadata.json: Plasma would not list it"; fi
    if v_lst_prefix "$l" "$d/contents/images"; then pass "wallpaper package $d has contents/images"; else fail "wallpaper package $d has no contents/images"; fi
}

# v_check_sshd_dropin DIR: DIR is etc/ssh/sshd_config.d of the image. sshd takes the FIRST value it reads for a keyword and reads
# the drop-ins in file-name order, so the first PermitRootLogin and PasswordAuthentication across them decide. This is the barrier
# that matters (D7): root and liveuser have empty passwords in the image, and the two masks above do not cover every way systemd
# can start sshd (systemd-ssh-generator makes sockets of its own, not checked here), so a reachable sshd must still refuse them.
v_check_sshd_dropin() {
    local d="$1" kw v bad=0
    if ! ls "$d"/*.conf >/dev/null 2>&1; then fail "no sshd drop-in in etc/ssh/sshd_config.d: sshd's own defaults would apply (password logins allowed, and root with a key), with empty root and liveuser passwords in the image (D7)"; return 0; fi
    for kw in PermitRootLogin PasswordAuthentication; do
        v="$(cat "$d"/*.conf 2>/dev/null | awk -v kw="$(v_lower "$kw")" 'tolower($1) == kw { print tolower($2); exit }')"
        if [ "$v" = no ]; then :; else fail "sshd drop-ins: the first $kw is '${v:-<not set>}', not 'no' (D7: the drop-in is the barrier if sshd is reached any way but the masked units)"; bad=1; fi
    done
    [ "$bad" -eq 0 ] && pass "sshd drop-ins forbid root and password logins (PermitRootLogin no, PasswordAuthentication no)"
    return 0
}

# v_check_sshd_masked LISTING: D7.
v_check_sshd_masked() {
    local l="$1" t s
    t="$(v_lst_target "$l" /etc/systemd/system/sshd.service)"
    if [ "$t" = "/dev/null" ]; then pass "sshd.service is masked in the live image (D7)"; else fail "sshd.service is not masked (/etc/systemd/system/sshd.service -> '${t:-<absent>}'); upstream ships it enabled with empty-password root login (D7)"; fi
    s="$(v_lst_target "$l" /etc/systemd/system/sshd.socket)"
    if [ "$s" = "/dev/null" ] || ! v_lst_has "$l" /etc/systemd/system/sockets.target.wants/sshd.socket; then pass "sshd.socket is not enabled"; else fail "sshd.socket is enabled in the live image"; fi
}

# v_check_about FILE OSRELEASE: /etc/xdg/kcm-about-distrorc (System Settings > About, KInfoCenter). KDE falls back to os-release
# for every key the file leaves out (Name, Website, Variant), so a missing key is fine when os-release has the right value; a key
# that is there must be Companion's.
v_check_about() {
    local f="$1" osr="${2:-}" k v want
    if [ ! -s "$f" ]; then fail "etc/xdg/kcm-about-distrorc is missing: System Settings > About would show the os-release logo path only"; return 0; fi
    v_has "$f" '^\[General\]' && pass "kcm-about-distrorc has a [General] group" || fail "kcm-about-distrorc has no [General] group"
    v_has "$f" '^LogoPath=ci-os-logo$' && pass "kcm-about-distrorc LogoPath=ci-os-logo" || fail "kcm-about-distrorc LogoPath is not ci-os-logo"
    for k in Name Website; do
        v="$(v_osrel_get "$f" "$k")"
        if [ "$k" = Name ]; then want='Companion OS'; else want='https://ci.computer'; fi
        if [ -n "$v" ]; then
            if [ "$v" = "$want" ] || [ "$v" = "$want/" ]; then pass "kcm-about-distrorc $k=$v"; else fail "kcm-about-distrorc $k='$v', expected $want"; fi
        elif [ -n "$osr" ]; then
            if [ "$k" = Name ]; then v="$(v_osrel_get "$osr" NAME)"; else v="$(v_osrel_get "$osr" HOME_URL)"; fi
            if [ "$v" = "$want" ]; then pass "kcm-about-distrorc leaves $k out and os-release gives $v (KDE's fallback)"; else fail "kcm-about-distrorc leaves $k out and os-release gives '${v:-<missing>}', expected $want"; fi
        fi
    done
    v="$(v_osrel_get "$f" Version)"
    if [ -n "$v" ] && [ -n "$osr" ]; then
        want="$(v_osrel_get "$osr" CI_OS_VERSION)"
        if [ "$v" = "$want" ]; then pass "kcm-about-distrorc Version=$v equals os-release CI_OS_VERSION"; else fail "kcm-about-distrorc Version='$v' differs from os-release CI_OS_VERSION '${want:-<missing>}'"; fi
    fi
    if grep -v '^[[:space:]]*#' "$f" | grep -qi 'cachy'; then fail "kcm-about-distrorc names CachyOS"; else pass "kcm-about-distrorc does not name CachyOS"; fi
    return 0
}

# v_check_text_clean LABEL FILE: a user-visible file does not name CachyOS or Arch.
v_check_text_clean() {
    if [ ! -s "$2" ]; then fail "$1 is missing or empty"; return 0; fi
    if grep -i -q -E "$V_BRAND_RE" "$2"; then fail "$1 still names CachyOS or Arch: $(grep -i -E "$V_BRAND_RE" "$2" | head -n 2 | tr '\n' '|')"; else pass "$1 does not name CachyOS or Arch"; fi
}

#=============================================================================
# 3b. Installer entry point (D6)
#=============================================================================
# v_check_no_block_art FILE: no full-block characters (U+2588). The repo bans them (core/lib/check-repo.sh) because block
# letters can spell a retired name that no text check can see; the MOTD is where upstream draws a banner.
v_check_no_block_art() {
    if [ -s "$1" ] && grep -q "$(printf '\342\226\210')" "$1"; then fail "${1##*/} contains block-letter art (U+2588), which can spell a name no text check sees"
    else pass "${1##*/} has no block-letter art"; fi
}

# v_check_launcher_desktop FILE: our installer launcher.
v_check_launcher_desktop() {
    local f="$1"
    v_has "$f" '^Type=Application$' && pass "launcher ${f##*/}: Type=Application" || fail "launcher ${f##*/}: not Type=Application"
    v_has "$f" '^Exec=.*/usr/local/bin/calamares-online\.sh' && pass "launcher ${f##*/} runs /usr/local/bin/calamares-online.sh" || fail "launcher ${f##*/} does not run /usr/local/bin/calamares-online.sh"
    v_has "$f" '^Name=.*Companion OS' && pass "launcher ${f##*/} is named for Companion OS ($(sed -n 's/^Name=//p' "$f" | head -n 1))" || fail "launcher ${f##*/} has no Name= with Companion OS"
    if grep -v '^#' "$f" | grep -qi -E "$V_BRAND_RE"; then fail "launcher ${f##*/} names CachyOS or Arch: $(grep -i -E "$V_BRAND_RE" "$f" | head -n 2 | tr '\n' '|')"; else pass "launcher ${f##*/} does not name CachyOS or Arch"; fi
    v_has "$f" '^(NoDisplay|Hidden)=true' && fail "launcher ${f##*/} is hidden (NoDisplay/Hidden)" || pass "launcher ${f##*/} is visible"
    return 0
}

# v_check_calamares_script FILE: D6 launcher script. Static: the real behaviour is tests/installer-*.sh with stubs.
v_check_calamares_script() {
    local f="$1" first inst ovl
    if [ ! -s "$f" ]; then fail "calamares-online.sh is missing or empty"; return 0; fi
    first="$(head -n 1 "$f")"
    case "$first" in '#!'*bash*) pass "calamares-online.sh has a bash shebang" ;; *) fail "calamares-online.sh has no bash shebang ($first)" ;; esac
    if bash -n "$f" 2>/dev/null; then pass "calamares-online.sh passes bash -n"; else fail "calamares-online.sh has a syntax error (bash -n)"; fi
    v_has "$f" 'pacman[^#]*-S[^#]*cachyos-calamares-next' && pass "calamares-online.sh installs cachyos-calamares-next (as upstream)" || fail "calamares-online.sh does not install cachyos-calamares-next"
    v_hasf "$f" '/usr/share/ci-os/calamares' && pass "calamares-online.sh applies the overlay from /usr/share/ci-os/calamares" || fail "calamares-online.sh does not reference /usr/share/ci-os/calamares"
    # The package reinstall overwrites /etc/calamares; the overlay must come after it. Line-order heuristic: the first
    # pacman install of the package precedes the last use of the overlay directory (the literal path, or a variable that was
    # assigned from it, directly or through another such variable).
    inst="$(grep -n -E 'pacman[^#]*-S[^#]*cachyos-calamares-next' "$f" | head -n 1 | cut -d: -f1)"
    ovl="$(awk -v p='/usr/share/ci-os/calamares' '
        { line[NR] = $0 }
        END {
            for (round = 0; round < 3; round++) for (i = 1; i <= NR; i++) {
                s = line[i]
                if (s ~ /^[ \t]*#/) continue
                if (match(s, /^[ \t]*((readonly|local|export)[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
                    decl = substr(s, RSTART, RLENGTH); sub(/^[ \t]*((readonly|local|export)[ \t]+)?/, "", decl); sub(/=$/, "", decl)
                    val = substr(s, RLENGTH + 1)
                    alias = (index(val, p) > 0)
                    if (!alias) for (v in known) if (index(val, "$" v) > 0) alias = 1
                    if (alias) { known[decl] = 1; assign[i] = 1 }
                }
            }
            last = 0
            for (i = 1; i <= NR; i++) {
                s = line[i]
                if (s ~ /^[ \t]*#/ || assign[i]) continue
                hit = (index(s, p) > 0)
                if (!hit) for (v in known) if (index(s, "$" v) > 0) hit = 1
                if (hit) last = i
            }
            if (last > 0) print last
        }' "$f")"
    if [ -n "$inst" ] && [ -n "$ovl" ] && [ "$inst" -lt "$ovl" ]; then pass "calamares-online.sh applies the overlay after the package reinstall (line $inst < line $ovl; heuristic)"
    else fail "calamares-online.sh does not appear to apply the overlay after the package reinstall (installs line ${inst:-none}, overlay last used line ${ovl:-none}); the reinstall would overwrite /etc/calamares"; fi
    if grep -v '^[[:space:]]*#' "$f" | grep -q -E 'cachyos\.org|paste\.cachyos|versions\.json'; then fail "calamares-online.sh contacts a CachyOS host: $(grep -v '^[[:space:]]*#' "$f" | grep -E 'cachyos\.org|paste\.cachyos|versions\.json' | head -n 1)"; else pass "calamares-online.sh contacts no CachyOS host (cachyos.org, paste.cachyos.org, versions.json)"; fi
    if grep -v '^[[:space:]]*#' "$f" | grep -q -E 'raw\.githubusercontent\.com'; then fail "calamares-online.sh depends on raw.githubusercontent.com"; else pass "calamares-online.sh has no GitHub-raw dependency"; fi
    v_has "$f" '(^|[[:space:];&|])calamares([[:space:]]|$)' && pass "calamares-online.sh starts calamares" || fail "calamares-online.sh never starts calamares"
    return 0
}

# v_check_hello_gate LISTING PKGLIST ROOT: D6, cachyos-hello's install gate (cachyos.org/versions.json) must not be what
# a default session leads to. Either the package is not in the image, or nothing starts or shows it.
v_check_hello_gate() {
    local l="$1" pl="$2" r="$3" f offenders=""
    if ! grep -q '^cachyos-hello ' "$pl" 2>/dev/null; then pass "cachyos-hello is not in the image (its cachyos.org install gate cannot be reached)"; return 0; fi
    note "cachyos-hello is in the image: checking that nothing starts or shows it"
    for f in "$r"/etc/skel/.config/autostart/cachyos-hello.desktop "$r"/home/*/.config/autostart/cachyos-hello.desktop "$r"/etc/xdg/autostart/cachyos-hello.desktop; do
        [ -f "$f" ] || continue
        if ! v_has "$f" '^Hidden=true'; then offenders="$offenders ${f#"$r"}"; fi
    done
    if [ -z "$offenders" ]; then pass "cachyos-hello does not autostart (no autostart entry, or Hidden=true)"; else fail "cachyos-hello autostarts, and its Install button runs the installer behind the cachyos.org/versions.json gate:$offenders"; fi
    f="$r/usr/share/applications/cachyos-hello.desktop"
    if [ ! -f "$f" ]; then pass "cachyos-hello has no application menu entry"
    elif v_has "$f" '^(NoDisplay|Hidden)=true'; then pass "cachyos-hello is hidden from the application menu"
    else fail "cachyos-hello is still in the application menu (usr/share/applications/cachyos-hello.desktop is not NoDisplay/Hidden)"; fi
    v_lst_has "$l" /usr/local/bin/calamares-online.sh || fail "/usr/local/bin/calamares-online.sh is absent, so cachyos-hello's Install button has nothing to run"
    return 0
}

#=============================================================================
# 4. Package list
#=============================================================================
# v_check_pkglist PKGLIST ADD_FILE REMOVE_FILE: names only; ADD / REMOVE are the overlay's lists (one per line, # comments).
v_check_pkglist() {
    local pl="$1" add="$2" rem="$3" names p miss=0 n=0 nrem=0 src f
    names="$(awk '{ print $1 }' "$pl" 2>/dev/null | sort -u)"
    if [ -z "$names" ]; then fail "the package list is missing or empty"; return 0; fi
    for p in $V_REQUIRED_PKGS; do
        n=$((n + 1))
        if ! printf '%s\n' "$names" | grep -Fxq -- "$p"; then fail "required package is not in the image: $p"; miss=$((miss + 1)); fi
    done
    [ "$miss" -eq 0 ] && pass "all $n packages the live ISO cannot do without are in the image"
    for src in add remove; do
        if [ "$src" = add ]; then f="$add"; else f="$rem"; fi
        if [ ! -f "$f" ]; then fail "overlay/packages.$src is missing: cannot tell what the overlay adds or removes (WP-B contract)"; continue; fi
    done
    n=0; miss=0
    if [ -f "$add" ]; then
        while IFS= read -r p; do
            p="${p%%#*}"; p="$(printf '%s' "$p" | tr -d '[:space:]')"
            [ -n "$p" ] || continue
            n=$((n + 1))
            if ! printf '%s\n' "$names" | grep -Fxq -- "$p"; then fail "overlay/packages.add names $p but it is not in the image (a package group or virtual name does not show up here)"; miss=$((miss + 1)); fi
        done < "$add"
        if [ "$n" -eq 0 ]; then note "overlay/packages.add lists no package: the overlay adds none, nothing to look for"
        elif [ "$miss" -eq 0 ]; then pass "all $n package(s) of overlay/packages.add are in the image"; fi
    fi
    if [ -f "$rem" ]; then
        while IFS= read -r p; do
            p="${p%%#*}"; p="$(printf '%s' "$p" | tr -d '[:space:]')"
            [ -n "$p" ] || continue
            nrem=$((nrem + 1))
            if printf '%s\n' "$names" | grep -Fxq -- "$p"; then fail "overlay/packages.remove removes $p but it is in the image"; miss=$((miss + 1)); fi
        done < "$rem"
        if [ "$nrem" -eq 0 ]; then note "overlay/packages.remove lists no package: the overlay removes none, nothing to look for"
        elif [ "$miss" -eq 0 ]; then pass "none of the $nrem package(s) of overlay/packages.remove is in the image"; fi
    fi
    return 0
}

# v_check_vm_generator LISTING: the slow-boot generator for virtual machines is in the image and executable. systemd runs only
# executable generators, mkarchiso keeps only the modes file_permissions lists, and nothing else would notice its absence: a VM
# without TCG-speed relief drops to emergency mode (measured on the research demo, docs/architecture/cachyos-backend.md).
V_VM_GENERATOR=/usr/lib/systemd/system-generators/companion-vm-timeouts
v_check_vm_generator() {
    local m
    if ! v_lst_has "$1" "$V_VM_GENERATOR"; then fail "the slow-boot generator $V_VM_GENERATOR is not in the image: a virtual machine without KVM drops to emergency mode (overlay/files/airootfs/usr/lib/systemd/system-generators/)"; return 0; fi
    m="$(v_lst_mode "$1" "$V_VM_GENERATOR")"
    if v_mode_is_exec "$m"; then pass "the slow-boot generator for virtual machines is in the image and executable ($V_VM_GENERATOR)"
    else fail "the slow-boot generator $V_VM_GENERATOR is not executable ($m): systemd skips it (add it to file_permissions)"; fi
}

# v_check_pkglist_vs_db ROOT PKGLIST WORKDIR: the package list on the medium (name and version per line) equals the image's own
# pacman database (/var/lib/pacman/local/NAME-VERSION-REL under ROOT). WORKDIR gets two sorted scratch files.
v_check_pkglist_vs_db() {
    local R="$1" list="$2" W="$3" f dbn pln
    for f in "$R"/var/lib/pacman/local/*; do
        [ -d "$f" ] && printf '%s\n' "${f##*/}"
    done | sed -E 's/-([^-]+-[^-]+)$/ \1/' | LC_ALL=C sort > "$W/db-pkgs.txt"
    LC_ALL=C sort "$list" > "$W/pkglist.sorted"
    dbn="$(grep -c . "$W/db-pkgs.txt")"; pln="$(grep -c . "$W/pkglist.sorted")"
    if [ "$dbn" -gt 0 ] && v_same_file "$W/db-pkgs.txt" "$W/pkglist.sorted"; then pass "pkglist.x86_64.txt equals the image's pacman database ($pln packages)"
    else fail "pkglist.x86_64.txt ($pln) and the image's pacman database ($dbn) differ: $(comm -3 "$W/db-pkgs.txt" "$W/pkglist.sorted" 2>/dev/null | head -n 4 | tr '\n\t' '| ')"; fi
}

# v_check_pkgs_txt PKGS_TXT ISO_PKGLIST: the package list published next to the ISO is the one inside it.
v_check_pkgs_txt() {
    if v_same_file "$1" "$2"; then pass "$(basename "$1") equals the package list inside the ISO"
    else fail "$(basename "$1") differs from /arch/pkglist.x86_64.txt inside the ISO"; fi
}

#=============================================================================
# 6. File modes
#=============================================================================
# v_check_modes LISTING ROOT OWNED: ROOT holds the extracted V_EXEC_DIRS, OWNED lists package-owned paths (one per line).
v_check_modes() {
    local l="$1" r="$2" owned="$3" d p m n=0 bad=0 first skipped=0 x exempt
    for d in $V_EXEC_DIRS; do
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            [ -f "$r$p" ] || continue
            exempt=0
            for x in $V_EXEC_EXEMPT; do case "$p" in "$x"*) exempt=1 ;; esac; done
            if grep -Fxq -- "$p" "$owned" 2>/dev/null; then continue; fi
            first="$(head -c2 "$r$p" 2>/dev/null)"
            [ "$first" = "#!" ] || continue
            if [ "$exempt" -eq 1 ]; then skipped=$((skipped + 1)); continue; fi
            n=$((n + 1))
            m="$(v_lst_mode "$l" "$p")"
            if ! v_mode_is_exec "$m"; then fail "script is not executable ($m): $p (mkarchiso drops modes; add it to file_permissions)"; bad=$((bad + 1)); fi
        done <<EOF
$(awk -F'\t' -v d="$d" 'substr($1,1,1) == "-" && index($3, d "/") == 1 { print $3 }' "$l")
EOF
    done
    [ "$bad" -eq 0 ] && pass "all $n package-unowned #! scripts under $V_EXEC_DIRS are executable"
    [ "$skipped" -gt 0 ] && note "$skipped #! script(s) under $V_EXEC_EXEMPT are staged as data and started with bash: their mode is not judged"
    return 0
}

# v_check_perm LISTING PATH EXPECTED_MODE_REGEX DESCRIPTION
v_check_perm() {
    local m
    m="$(v_lst_mode "$1" "$2")"
    if [ -z "$m" ]; then fail "$2 is missing"; elif [[ "$m" =~ $3 ]]; then pass "$2 is $m ($4)"; else fail "$2 is $m, expected $4"; fi
}

#=============================================================================
# 7. Provenance, 8. Integrity
#=============================================================================
# v_lock_get FILE KEY...: first KEY that is set in a KEY=value lock file (never sourced).
v_lock_get() {
    local f="$1" k v; shift
    for k in "$@"; do
        v="$(sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$k=(.*)\$/\\2/p" "$f" 2>/dev/null | head -n 1 | sed -e 's/[[:space:]]*#.*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"
        if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
    done
    return 1
}
# v_check_lock_identity LOCK: upstream.lock names the same edition as D1 (the build derives the file name and label from it).
v_check_lock_identity() {
    local lock="$1" n p arch
    n="$(v_lock_get "$lock" EDITION_ISO_NAME)" || n=""
    p="$(v_lock_get "$lock" EDITION_LABEL_PREFIX)" || p=""
    arch="$(v_lock_get "$lock" EDITION_ARCH)" || arch=""
    if [ "$n" = "$V_IMAGE_ID" ]; then pass "upstream.lock EDITION_ISO_NAME=$n (D1)"; else fail "upstream.lock EDITION_ISO_NAME='${n:-<missing>}', expected $V_IMAGE_ID (D1)"; fi
    if [ "$p" = "COMPANION_" ]; then pass "upstream.lock EDITION_LABEL_PREFIX=$p (D1)"; else fail "upstream.lock EDITION_LABEL_PREFIX='${p:-<missing>}', expected COMPANION_ (D1)"; fi
    if [ "$arch" = "x86_64" ]; then pass "upstream.lock EDITION_ARCH=x86_64"; else fail "upstream.lock EDITION_ARCH='${arch:-<missing>}', expected x86_64"; fi
}
# v_kv_get FILE KEY: the raw value of the first KEY=value line.
v_kv_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
# v_check_buildinfo FILE LOCK LABEL: the build record (KEY=VALUE lines written by in-container/20-build.sh) names the pins of
# upstream.lock. A fallback-pin build (UPSTREAM_PIN=fallback) is compared with UPSTREAM_FALLBACK_SHA.
v_check_buildinfo() {
    local bi="$1" lock="$2" label="${3:-build record}" pin sha want k v
    if [ ! -s "$bi" ]; then fail "$label is missing or empty"; return 0; fi
    pin="$(v_kv_get "$bi" UPSTREAM_PIN)"
    if [ "$pin" = fallback ]; then want="$(v_lock_get "$lock" UPSTREAM_FALLBACK_SHA)" || want=""; else want="$(v_lock_get "$lock" UPSTREAM_SHA CACHYOS_LIVE_ISO_COMMIT UPSTREAM_COMMIT)" || want=""; fi
    sha="$(v_kv_get "$bi" UPSTREAM_SHA)"
    if [ -z "$want" ]; then fail "upstream.lock has no upstream commit to compare the $label with ($lock)"
    elif [ "$sha" = "$want" ]; then pass "$label: UPSTREAM_SHA=$sha equals the lock's ${pin:-primary} pin"
    else fail "$label: UPSTREAM_SHA is '${sha:-<missing>}', the lock pins $want (built from another commit?)"; fi
    for k in BASE_IMAGE MIRRORLIST_SHA256 CACHYOS_KEY_FPR; do
        want="$(v_lock_get "$lock" "$k")" || want=""
        v="$(v_kv_get "$bi" "$k")"
        if [ -z "$want" ]; then note "upstream.lock has no $k to compare the $label with"
        elif [ "$v" = "$want" ]; then pass "$label: $k equals the lock's"
        else fail "$label: $k is '${v:-<missing>}', the lock pins '$want'"; fi
    done
    for k in OVERLAY_SHA256 STAGING_SHA256; do
        v="$(v_kv_get "$bi" "$k")"
        if [[ "$v" =~ ^[0-9a-f]{64}$ ]]; then pass "$label: $k is recorded"; else fail "$label: $k is '${v:-<missing>}', expected 64 hex digits"; fi
    done
    v="$(v_kv_get "$bi" CI_OS_VERSION)"
    if [ -n "$v" ]; then pass "$label: CI_OS_VERSION=$v"; else fail "$label: CI_OS_VERSION is not recorded"; fi
    v="$(v_kv_get "$bi" BUILD_DAY)"
    if [[ "$v" =~ ^[0-9]{8}$ ]]; then pass "$label: BUILD_DAY=$v"; else fail "$label: BUILD_DAY is '${v:-<missing>}', expected YYYYMMDD"; fi
    v="$(v_kv_get "$bi" KERNEL_LINES_CHANGED)"
    if [ "$v" = 1 ]; then note "$label: KERNEL_LINES_CHANGED=1: a patch changed kernel / initrd lines on purpose; the parity check needs VERIFY_GRUB_EXTRA_PARAMS for them"; fi
    # build-iso.sh packs the WORKING TREE, so the record says whether that was exactly the commit it names (REPO_TREE). A release
    # wants clean; VERIFY_REQUIRE_CLEAN=1 makes anything else a failure.
    v="$(v_kv_get "$bi" REPO_TREE)"
    case "$v" in
        clean) pass "$label: built from a clean checkout of commit $(v_kv_get "$bi" REPO_COMMIT | cut -c1-12)" ;;
        dirty) if [ "${VERIFY_REQUIRE_CLEAN:-0}" = 1 ]; then fail "$label: REPO_TREE=dirty (changed $(v_kv_get "$bi" REPO_TREE_CHANGED), untracked $(v_kv_get "$bi" REPO_TREE_UNTRACKED), ignored $(v_kv_get "$bi" REPO_TREE_IGNORED)): the ISO was built from files that are not commit $(v_kv_get "$bi" REPO_COMMIT | cut -c1-12)"
               else note "$label: REPO_TREE=dirty (changed $(v_kv_get "$bi" REPO_TREE_CHANGED), untracked $(v_kv_get "$bi" REPO_TREE_UNTRACKED), ignored $(v_kv_get "$bi" REPO_TREE_IGNORED)): not a release; VERIFY_REQUIRE_CLEAN=1 makes this a failure"; fi ;;
        '') if [ "${VERIFY_REQUIRE_CLEAN:-0}" = 1 ]; then fail "$label: no REPO_TREE: the record does not say what tree the ISO was built from"; else note "$label: no REPO_TREE (a record from a build that did not record its working tree)"; fi ;;
        *) if [ "${VERIFY_REQUIRE_CLEAN:-0}" = 1 ]; then fail "$label: REPO_TREE=$v: the build could not tell whether its tree was clean"; else note "$label: REPO_TREE=$v (the build could not tell whether its tree was clean)"; fi ;;
    esac
    return 0
}
# v_check_buildinfo_pair EMBEDDED SIDECAR OSRELEASE: the record inside the image and the one next to it describe the same
# build, and the identity file carries that build's version and day.
v_check_buildinfo_pair() {
    local emb="$1" side="$2" osr="$3" k a b
    for k in UPSTREAM_SHA BASE_IMAGE OVERLAY_SHA256 STAGING_SHA256 CI_OS_VERSION BUILD_DAY; do
        a="$(v_kv_get "$emb" "$k")"; b="$(v_kv_get "$side" "$k")"
        if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "the record inside the image and the one next to it agree on $k"; else fail "$k differs: inside the image '${a:-<missing>}', next to it '${b:-<missing>}'"; fi
    done
    a="$(v_kv_get "$emb" CI_OS_VERSION)"; b="$(v_osrel_get "$osr" CI_OS_VERSION)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "os-release CI_OS_VERSION equals the build record's ($a)"; else fail "os-release CI_OS_VERSION '${b:-<missing>}' differs from the build record's '${a:-<missing>}'"; fi
    a="$(v_kv_get "$emb" BUILD_DAY)"; b="$(v_osrel_get "$osr" CI_OS_BUILD)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "os-release CI_OS_BUILD equals the build record's BUILD_DAY ($a)"; else fail "os-release CI_OS_BUILD '${b:-<missing>}' differs from the build record's BUILD_DAY '${a:-<missing>}'"; fi
}
# v_check_buildinfo_iso SIDECAR ISO: ISO_BYTES and ISO_SHA256 of the sidecar record describe this file.
v_check_buildinfo_iso() {
    local bi="$1" iso="$2" bytes sha
    bytes="$(v_kv_get "$bi" ISO_BYTES)"; sha="$(v_kv_get "$bi" ISO_SHA256)"
    if [ "$bytes" = "$(wc -c < "$iso" | tr -d ' ')" ]; then pass "build record: ISO_BYTES equals the file's size"; else fail "build record: ISO_BYTES is '${bytes:-<missing>}', the file has $(wc -c < "$iso" | tr -d ' ') bytes"; fi
    if [ "$sha" = "$(v_sha256 "$iso")" ]; then pass "build record: ISO_SHA256 equals the file's"; else fail "build record: ISO_SHA256 '${sha:-<missing>}' is not this file's hash"; fi
}
# v_check_compat_libs LOCK LISTING ROOT RECORD [SIDECAR]: risk R1, rolling-release drift (incident 2026-10-18: cachyos-calamares-next
# was linked against boost 1.91 while the image had 1.92, and the installer did not start). compat-libs.lock names the older libraries
# the image has to carry next to the current ones. LISTING is the normalised squashfs listing; ROOT holds the extracted library files
# (v_sfs_extract_paths); RECORD is the build record inside the image, SIDECAR the one next to the ISO (optional).
#   * every library of the lock is in the image as a regular file (not a link), readable by everybody, with the lock's sha256;
#   * the record carries COMPAT_LIBS, COMPAT_PACKAGES, COMPAT_LOCK_SHA256, COMPAT_REVIEW_BY and COMPAT_REVIEW_OVERDUE, and they say
#     what the lock says: the number of libraries, the packages, the lock's own hash, its review date. COMPAT_LIBS=off (a build made to
#     prove the installer gate fails) and =unknown (no report of the step) are not an image to ship;
#   * a lock that lists no library any more (retired, because [cachyos] rebuilt the installer) needs none in the image: the record
#     then says COMPAT_LIBS=0.
# A record with none of the keys is an image built before the step existed: it fails, because it cannot be told from one that skipped it.
v_check_compat_libs() {
    local lock="$1" l="$2" r="$3" rec="$4" side="${5:-}" problems nlib=0 pkg path sha mode got k v a b exp bad=0 kbad=0 name
    name="$(basename "$lock")"
    if [ "${V_HAVE_COMPAT_LOCK:-0}" != 1 ]; then fail "lib/compat-lock.sh is not next to verify-iso.sh: the compatibility libraries cannot be checked"; return 0; fi
    if [ ! -f "$lock" ]; then fail "$name not found at $lock: cannot tell which compatibility libraries the image must carry"; return 0; fi
    if ! problems="$(compat_lock_problems "$lock")"; then fail "$name is not a valid compat lock: $(printf '%s' "$problems" | tr '\n' ';')"; return 0; fi
    nlib="$(compat_lock_libs "$lock" | grep -c .)"
    if [ "$nlib" -eq 0 ]; then
        pass "$name lists no compatibility library (retired): none is required in the image"
    else
        while read -r pkg path sha; do
            [ -n "$path" ] || continue
            mode="$(v_lst_mode "$l" "/$path")"
            if [ -z "$mode" ]; then fail "/$path ($pkg) is not in the image: the installer that needs it does not start (risk R1; $name pins it)"; bad=$((bad + 1)); continue; fi
            case "$mode" in
                -*) ;;
                *) fail "/$path is not a regular file in the image (mode $mode, target '$(v_lst_target "$l" "/$path")'): $name pins its bytes"; bad=$((bad + 1)); continue ;;
            esac
            if ! [[ "$mode" =~ ^-.{6}r ]]; then fail "/$path has mode $mode: not readable by every user, and the installer runs as one"; bad=$((bad + 1)); continue; fi
            if [ ! -f "$r/$path" ]; then fail "/$path could not be extracted from the squashfs, so its hash was not checked"; bad=$((bad + 1)); continue; fi
            got="$(v_sha256 "$r/$path")"
            if [ "$got" != "$sha" ]; then fail "/$path has sha256 $got, $name pins $sha"; bad=$((bad + 1)); continue; fi
        done <<EOF
$(compat_lock_libs "$lock")
EOF
        [ "$bad" -eq 0 ] && pass "all $nlib compatibility librar$([ "$nlib" = 1 ] && echo y || echo ies) of $name are in the image, regular files with the pinned sha256"
    fi
    # the build record
    if [ ! -s "$rec" ]; then fail "no build record inside the image: nothing says whether the compatibility step ran"; return 0; fi
    for k in COMPAT_LIBS COMPAT_PACKAGES COMPAT_LOCK_SHA256 COMPAT_REVIEW_BY COMPAT_REVIEW_OVERDUE; do
        if grep -q "^$k=" "$rec"; then :; else fail "the build record carries no $k: the image was built without the compatibility step, or before it existed"; kbad=$((kbad + 1)); fi
    done
    [ "$kbad" -eq 0 ] || return 0
    v="$(v_kv_get "$rec" COMPAT_LIBS)"
    case "$v" in
        off) fail "build record: COMPAT_LIBS=off: this image was built with CI_OS_COMPAT_LIBS=off (the switch that proves the installer gate), it is not one to ship" ;;
        unknown) fail "build record: COMPAT_LIBS=unknown: the compatibility step left no report" ;;
        *[!0-9]*|'') fail "build record: COMPAT_LIBS='$v' is not a number" ;;
        *) if [ "$v" = "$nlib" ]; then pass "build record: COMPAT_LIBS=$v equals the $nlib librar$([ "$nlib" = 1 ] && echo y || echo ies) of $name"
           else fail "build record: COMPAT_LIBS=$v, but $name lists $nlib librar$([ "$nlib" = 1 ] && echo y || echo ies) (built with another lock?)"; fi ;;
    esac
    v="$(v_kv_get "$rec" COMPAT_LOCK_SHA256)"
    if [ "$v" = "$(v_sha256 "$lock")" ]; then pass "build record: COMPAT_LOCK_SHA256 is the hash of $name"; else fail "build record: COMPAT_LOCK_SHA256 is '${v:-<empty>}', $name hashes to $(v_sha256 "$lock") (built with another lock?)"; fi
    exp="$(compat_lock_packages "$lock" | awk '{ printf "%s%s-%s-%s", (n++ ? "," : ""), $1, $2, $3 }')"
    v="$(v_kv_get "$rec" COMPAT_PACKAGES)"
    if [ "$v" = "$exp" ]; then pass "build record: COMPAT_PACKAGES=${v:-<none>} equals the lock's"; else fail "build record: COMPAT_PACKAGES is '${v:-<empty>}', $name pins '${exp:-<none>}'"; fi
    exp="$(compat_lock_review_by "$lock")"
    v="$(v_kv_get "$rec" COMPAT_REVIEW_BY)"
    if [ "$v" = "$exp" ]; then pass "build record: COMPAT_REVIEW_BY=${v:-<none>} equals the lock's"; else fail "build record: COMPAT_REVIEW_BY is '${v:-<empty>}', $name says '${exp:-<none>}'"; fi
    v="$(v_kv_get "$rec" COMPAT_REVIEW_OVERDUE)"
    case "$v" in
        0) pass "build record: the compat lock was within its review date when the image was built" ;;
        1) if [ "${VERIFY_REQUIRE_CLEAN:-0}" = 1 ]; then fail "build record: COMPAT_REVIEW_OVERDUE=1: $name was past its review date when this image was built (a release is built with CI_OS_COMPAT_REVIEW=error)"
           else note "build record: COMPAT_REVIEW_OVERDUE=1: $name was past its review date ($(v_kv_get "$rec" COMPAT_REVIEW_BY)) when this image was built; VERIFY_REQUIRE_CLEAN=1 makes this a failure"; fi ;;
        *) fail "build record: COMPAT_REVIEW_OVERDUE='$v' is neither 0 nor 1" ;;
    esac
    if [ -n "$side" ] && [ -s "$side" ]; then
        for k in COMPAT_LIBS COMPAT_PACKAGES COMPAT_LOCK_SHA256 COMPAT_REVIEW_BY COMPAT_REVIEW_OVERDUE; do
            a="$(v_kv_get "$rec" "$k")"; b="$(v_kv_get "$side" "$k")"
            if grep -q "^$k=" "$side" && [ "$a" = "$b" ]; then pass "the record inside the image and the one next to it agree on $k"; else fail "$k differs: inside the image '${a:-<empty>}', next to it '${b:-<missing>}'"; fi
        done
    fi
    return 0
}
# v_check_sha256_file SHAFILE ISO
v_check_sha256_file() {
    local sf="$1" iso="$2" want got
    want="$(awk '{ print $1; exit }' "$sf" 2>/dev/null | tr 'A-F' 'a-f')"
    if ! [[ "$want" =~ ^[0-9a-f]{64}$ ]]; then fail "$(basename "$sf") does not start with a sha256 hash"; return 0; fi
    got="$(v_sha256 "$iso")"
    if [ "$want" = "$got" ]; then pass "$(basename "$sf") matches the ISO ($got)"; else fail "$(basename "$sf") says $want but the ISO hashes to $got"; fi
}
# v_check_sfs_sha512 SHA512FILE SFS
v_check_sfs_sha512() {
    local sf="$1" sfs="$2" want got
    want="$(awk '{ print $1; exit }' "$sf" 2>/dev/null)"
    if ! [[ "$want" =~ ^[0-9a-f]{128}$ ]]; then fail "airootfs.sha512 does not start with a sha512 hash"; return 0; fi
    got="$(v_sha512 "$sfs")"
    if [ "$want" = "$got" ]; then pass "airootfs.sha512 matches the squashfs (what archiso's checksum=y verifies at boot)"; else fail "airootfs.sha512 says ${want%"${want#????????}"}... but the squashfs hashes to ${got%"${got#????????}"}..."; fi
}

#=============================================================================
# 5. Calamares overlay: static analysis (python3 + PyYAML)
#=============================================================================
# The analysis lives in a Python helper written next to the scratch files so this script stays one file. It prints one
# result per line: "PASS text", "FAIL text", "info text" or "SKIP text"; v_run_calamares_py turns them into our counters.
v_write_calamares_py() {
    cat > "$1" <<'PYEOF'
#!/usr/bin/env python3
"""Static checks of the Companion OS Calamares overlay (usr/share/ci-os/calamares in the image)."""
import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("SKIP PyYAML is not installed (Arch: python-yaml, Debian: python3-yaml): the Calamares YAML checks did not run")
    sys.exit(0)

ap = argparse.ArgumentParser()
ap.add_argument("tree")
ap.add_argument("--stock-modules", help="file: module names that exist under /usr/lib/calamares/modules")
ap.add_argument("--stock-confs", help="file: basenames under /etc/calamares/modules")
ap.add_argument("--image-paths", help="file: every path in the image, one per line")
ap.add_argument("--extra-packages", default="", help="space separated package names the target must get in addition")
args = ap.parse_args()

BANNED_HOSTS = ["paste.cachyos.org", "wiki.cachyos.org", "cachyos.org/versions.json", "raw.githubusercontent.com"]
# Modules the CachyOS package is built without (-DSKIP_MODULES in its PKGBUILD): naming one in a sequence fails at install time.
SKIPPED_MODULES = {"contextualprocess", "packagechooserq", "welcomeq", "usersq", "finishedq", "localeq", "keyboardq",
                   "summaryq", "oemid", "dracut", "mkinitfs", "rawfs", "fsresizer", "license", "tracking", "webview",
                   "interactiveterminal", "notesqml", "plasmalnf", "services-openrc", "openrcdmcryptcfg", "dracutlukscfg"}
REQUIRED_TARGET_PACKAGES = ["docker", "docker-compose", "docker-buildx", "jq"]

def say(kind, text):
    print("%s %s" % (kind, text))

def ok(text):
    say("PASS", text)

def bad(text):
    say("FAIL", text)

def info(text):
    say("info", text)

def read_lines(path):
    if not path or not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        return [ln.rstrip("\n") for ln in fh if ln.strip()]

tree = args.tree
if not os.path.isdir(tree):
    bad("%s does not exist: the image carries no Calamares overlay (D6)" % tree)
    sys.exit(0)

stock_modules = read_lines(args.stock_modules)
stock_confs = read_lines(args.stock_confs)
image_paths = read_lines(args.image_paths)

files = []
for dp, dn, fn in os.walk(tree):
    for f in sorted(fn):
        files.append(os.path.join(dp, f))
if not files:
    bad("%s is empty" % tree)
    sys.exit(0)

docs = {}
parse_bad = 0
# Calamares configuration is what stage-installer.sh puts at the top, in modules/ and in branding/. target/ is the provisioning tree
# that is copied to the installed system (its .conf files are hostapd, dnsmasq, ... formats), lib/ and scripts/ are code.
DATA_DIRS = ("target", "lib", "scripts")
def is_config_path(p):
    first = os.path.relpath(p, tree).split(os.sep)[0]
    return first not in DATA_DIRS

yaml_files = [p for p in files if p.endswith((".conf", ".yaml", ".yml", ".desc")) and is_config_path(p)]
for p in yaml_files:
    try:
        with open(p, encoding="utf-8") as fh:
            docs[p] = yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001 - any parse problem is the finding
        parse_bad += 1
        bad("YAML does not parse: %s (%s)" % (os.path.relpath(p, tree), str(exc).splitlines()[0] if str(exc) else exc))
if yaml_files and parse_bad == 0:
    ok("%d Calamares config files parse as YAML" % len(yaml_files))
elif not yaml_files:
    bad("no .conf / .yaml / .desc file in the overlay")

def rel(p):
    return os.path.relpath(p, tree)

def by_key(*keys):
    return [(p, d) for p, d in docs.items() if isinstance(d, dict) and any(k in d for k in keys)]

def text_of(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""

def names_of(entries):
    out = []
    for e in entries or []:
        if isinstance(e, str):
            out.append(e)
        elif isinstance(e, dict):
            for k in ("name", "pkg", "package"):
                if k in e:
                    out.append(str(e[k]))
                    break
    return out

# ── settings ────────────────────────────────────────────────────────────────
settings = [(p, d) for p, d in by_key("sequence") if isinstance(d.get("sequence"), list)]
if not settings:
    bad("no settings file (a conf with a 'sequence:' list) in the overlay")
brandings = [(p, d) for p, d in docs.items() if os.path.basename(p) == "branding.desc" and isinstance(d, dict)]
if not brandings:
    bad("no branding.desc in the overlay")

all_confs = {os.path.basename(p) for p in files}
stock_conf_names = set(stock_confs or [])
stock_module_names = set(stock_modules or [])

def flatten_sequence(seq):
    steps = []
    for blk in seq:
        if isinstance(blk, dict):
            for kind, items in blk.items():
                for it in items or []:
                    steps.append((kind, str(it)))
    return steps

def with_scripts(q):
    """The text of config file q followed by the text of every script of the overlay that it names by file name (a step
    usually calls one script that does the work)."""
    body = text_of(q)
    extra = [text_of(r) for r in files if r != q and r.endswith((".sh", ".py")) and os.path.basename(r) in body]
    return body + "\n" + "\n".join(extra)

def shellprocess_text(inst_id):
    """with_scripts() of the config of the shellprocess instance <inst_id>."""
    for p, d in settings:
        for inst in d.get("instances") or []:
            if isinstance(inst, dict) and inst.get("id") == inst_id and inst.get("module") == "shellprocess":
                for q in files:
                    if os.path.basename(q) == inst.get("config"):
                        return with_scripts(q)
    return ""

def shellprocess_live(inst_id):
    """True when the instance's config runs in the live system (dontChroot: true), i.e. its paths are paths of the image."""
    for p, d in settings:
        for inst in d.get("instances") or []:
            if isinstance(inst, dict) and inst.get("id") == inst_id and inst.get("module") == "shellprocess":
                for q in files:
                    if os.path.basename(q) == inst.get("config") and isinstance(docs.get(q), dict):
                        return docs[q].get("dontChroot") is True
    return False

for sp, sd in settings:
    name = rel(sp)
    instances = {}
    for inst in sd.get("instances") or []:
        if isinstance(inst, dict) and "id" in inst and "module" in inst:
            instances[(inst["module"], str(inst["id"]))] = inst.get("config")
    steps = flatten_sequence(sd["sequence"])
    # branding component
    comp = sd.get("branding")
    match = [d for p, d in brandings if d.get("componentName") == comp and os.path.basename(os.path.dirname(p)) == comp]
    if comp and match:
        ok("%s: branding '%s' is a component of the overlay (componentName equals its directory)" % (name, comp))
    else:
        bad("%s: branding '%s' is not a branding.desc whose componentName equals its directory name" % (name, comp))
    if comp and re.search(r"cachy", str(comp), re.I):
        bad("%s: branding component is named for CachyOS: %s" % (name, comp))
    # every instance has a config, every step resolves
    problems = 0
    for (mod, iid), cfg in sorted(instances.items()):
        if not cfg:
            bad("%s: instance %s@%s has no config:" % (name, mod, iid))
            problems += 1
        elif cfg not in all_confs and cfg not in stock_conf_names:
            if stock_confs is None:
                info("%s: instance %s@%s uses %s, not in the overlay (stock file list not available here)" % (name, mod, iid, cfg))
            else:
                bad("%s: instance %s@%s needs %s, which neither the overlay nor /etc/calamares/modules has" % (name, mod, iid, cfg))
                problems += 1
    for kind, step in steps:
        mod, _, iid = step.partition("@")
        if iid and (mod, iid) not in instances:
            bad("%s: %s step '%s' has no instance %s@%s in 'instances:'" % (name, kind, step, mod, iid))
            problems += 1
        if mod in SKIPPED_MODULES or mod.startswith("dummy"):
            bad("%s: %s step '%s' is a module the cachyos-calamares-next package is built without" % (name, kind, step))
            problems += 1
        elif stock_modules is not None and mod not in stock_module_names:
            bad("%s: %s step '%s' is not a module in /usr/lib/calamares/modules of this image" % (name, kind, step))
            problems += 1
    if problems == 0:
        ok("%s: %d sequence steps and %d instances resolve (modules exist, instances are defined, configs exist)" % (name, len(steps), len(instances)))
    execs = [s for k, s in steps if k == "exec"]
    shows = [s for k, s in steps if k == "show"]
    for need in ("pacstrap", "bootloader", "users", "grubcfg", "partition", "mount", "umount"):
        if need not in execs:
            bad("%s: exec sequence has no '%s'" % (name, need))
    if not any(s == "packages" or s.startswith("packages@") for s in execs):
        bad("%s: exec sequence has no packages step (nothing would install the Companion package list)" % name)
    # staging order: the payload goes into ${ROOT}, so after pacstrap; units are enabled after the packages exist
    stage = [s for s in execs if s.startswith("shellprocess@") and re.search(r"/ci-os|ci_os|target-payload", shellprocess_text(s.split("@", 1)[1]))]
    if stage:
        idx = execs.index(stage[0])
        if "pacstrap" in execs and idx > execs.index("pacstrap"):
            ok("%s: payload staging step %s runs after pacstrap" % (name, stage[0]))
        else:
            bad("%s: payload staging step %s runs before pacstrap (the target does not exist yet)" % (name, stage[0]))
    else:
        bad("%s: no shellprocess step stages the Companion payload (a shellprocess config that mentions ci-os / target-payload; D8)" % name)
    pk = [i for i, s in enumerate(execs) if s == "packages" or s.startswith("packages@")]
    for i, s in enumerate(execs):
        if s.startswith("shellprocess@") and "systemctl enable" in shellprocess_text(s.split("@", 1)[1]) and pk and i < pk[0]:
            bad("%s: %s enables units before the packages step installs them" % (name, s))

# ── branding ────────────────────────────────────────────────────────────────
for bp, bd in brandings:
    bn = rel(bp)
    bdir = os.path.dirname(bp)
    strings = bd.get("strings") or {}
    if strings.get("productName") == "Companion OS":
        ok("%s: productName is Companion OS" % bn)
    else:
        bad("%s: productName is '%s', expected Companion OS" % (bn, strings.get("productName")))
    leaks = {k: v for k, v in strings.items() if re.search(r"cachy|arch ?linux", str(v), re.I)}
    if leaks:
        bad("%s: branding strings still name CachyOS or Arch: %s" % (bn, leaks))
    else:
        ok("%s: no branding string names CachyOS or Arch" % bn)
    for key in ("shortProductName", "versionedName", "shortVersionedName", "bootloaderEntryName"):
        if key not in strings:
            bad("%s: strings.%s is not set (Calamares would fall back to a stock value)" % (bn, key))
    up = bd.get("uploadServer")
    if up:
        url = str(up.get("url", "")) if isinstance(up, dict) else str(up)
        if re.search(r"cachyos", url, re.I):
            bad("%s: uploadServer sends the install log to %s" % (bn, url))
        else:
            info("%s: uploadServer is set to %s (D6 asks for no CachyOS upload; a Companion server is a decision)" % (bn, url))
    else:
        ok("%s: no uploadServer (the install log is never uploaded)" % bn)
    missing = []
    for k, v in (bd.get("images") or {}).items():
        fp = os.path.join(bdir, str(v))
        if not os.path.isfile(fp):
            missing.append(str(v))
        else:
            with open(fp, "rb") as fh:
                head = fh.read(8)
            if str(v).lower().endswith(".png") and head != b"\x89PNG\r\n\x1a\n":
                missing.append("%s (not a PNG)" % v)
    show = bd.get("slideshow")
    if show and not os.path.isfile(os.path.join(bdir, str(show))):
        missing.append(str(show))
    if not (bd.get("images") or {}):
        bad("%s: no images: (logo, icon, welcome)" % bn)
    elif missing:
        bad("%s: files named by images:/slideshow: that are missing or not PNG: %s" % (bn, ", ".join(missing)))
    else:
        ok("%s: images and slideshow files exist" % bn)
    style = bd.get("style") or {}
    badcol = [k for k, v in style.items() if not re.fullmatch(r"#[0-9a-fA-F]{6}", str(v))]
    if badcol:
        bad("%s: style colours that are not #rrggbb: %s" % (bn, badcol))
    # user-visible text files in the branding directory
    for dp, dn, fn in os.walk(bdir):
        for f in fn:
            if f.endswith((".qml", ".qss", ".desc", ".txt", ".html")):
                body = "\n".join(ln for ln in text_of(os.path.join(dp, f)).splitlines() if not ln.strip().startswith(("//", "#")))
                if re.search(r"cachy", body, re.I):
                    bad("%s: %s names CachyOS" % (bn, os.path.relpath(os.path.join(dp, f), bdir)))

# ── module configs, found by what they configure ────────────────────────────
def chooser_offer(varname):
    """(set of item ids, default) of the packagechooser config that stores its answer in global storage key <varname>."""
    want = varname.replace("packagechooser_", "", 1)
    for sp, sd in settings:
        for inst in sd.get("instances") or []:
            if isinstance(inst, dict) and inst.get("module") == "packagechooser" and str(inst.get("id")) == want:
                for q in files:
                    if os.path.basename(q) == inst.get("config"):
                        d2 = docs.get(q)
                        if isinstance(d2, dict):
                            ids = {str(i.get("id")) for i in d2.get("items") or [] if isinstance(i, dict)}
                            return ids, str(d2.get("default", ""))
    return None, None

def one(kind, keys, fn):
    found = by_key(*keys)
    if not found:
        bad("no %s config in the overlay (a conf with %s)" % (kind, " or ".join(keys)))
        return
    for p, d in found:
        fn(rel(p), d)

def chk_bootloader(n, d):
    if d.get("efiBootLoader") == "grub":
        ok("%s: efiBootLoader is grub (D6)" % n)
    else:
        bad("%s: efiBootLoader is %r, not grub (D6 forces GRUB: Limine's entry name is hard-coded CachyOS)" % (n, d.get("efiBootLoader")))
    var = d.get("efiBootLoaderVar")
    if not var:
        ok("%s: efiBootLoaderVar is not set (no page can override GRUB)" % n)
    else:
        offered, default = chooser_offer(var)
        if offered is None:
            bad("%s: efiBootLoaderVar=%s reads a chooser page, but no packagechooser config offering it was found in the overlay or the image" % (n, var))
        elif offered == {"grub"} and default == "grub":
            ok("%s: efiBootLoaderVar=%s is answered by a chooser that offers only grub (default grub)" % (n, var))
        else:
            bad("%s: efiBootLoaderVar=%s lets the installer's bootloader page override efiBootLoader; it offers %s (default %s), expected only grub" % (n, var, sorted(offered), default))
    if d.get("efiBootloaderId") == "companion-os":
        ok("%s: efiBootloaderId is companion-os (D6)" % n)
    else:
        bad("%s: efiBootloaderId is %r, expected companion-os (D6)" % (n, d.get("efiBootloaderId")))
    if "limineSplashLogo" in d and re.search(r"cachy", str(d["limineSplashLogo"]), re.I):
        bad("%s: limineSplashLogo points at CachyOS artwork" % n)

def chk_grubcfg(n, d):
    defaults = d.get("defaults") or {}
    theme = str(defaults.get("GRUB_THEME", ""))
    if theme and not re.search(r"cachy", theme, re.I):
        ok("%s: GRUB_THEME is %s" % (n, theme))
    else:
        bad("%s: GRUB_THEME is '%s' (unset or CachyOS's theme; D6)" % (n, theme))
    if d.get("keep_distributor") is True:
        info("%s: keep_distributor is true" % n)

def chk_plymouth(n, d):
    for k in ("plymouth_theme", "plymouth_theme_amdgpu"):
        v = str(d.get(k, ""))
        if v and not re.search(r"cachy", v, re.I):
            ok("%s: %s is %s" % (n, k, v))
        else:
            bad("%s: %s is '%s' (unset or CachyOS's animation; D6)" % (n, k, v))

def chk_users(n, d):
    groups = names_of(d.get("defaultGroups"))
    if "docker" in groups:
        ok("%s: defaultGroups contains docker (D8)" % n)
    else:
        bad("%s: defaultGroups lacks docker (D8): %s" % (n, groups))
    host = d.get("hostname")
    tmpl = str(host.get("template", "")) if isinstance(host, dict) else ""
    if tmpl.startswith("companion-os") and "cachy" not in tmpl.lower():
        ok("%s: hostname template is %s (D6)" % (n, tmpl))
    else:
        bad("%s: hostname template is '%s', expected companion-os... (D6)" % (n, tmpl))

def chk_welcome(n, d):
    url = str((d.get("requirements") or {}).get("internetCheckUrl", ""))
    if url and not re.search(r"cachyos", url, re.I):
        ok("%s: internetCheckUrl is %s (not a CachyOS host)" % (n, url))
    else:
        bad("%s: internetCheckUrl is '%s' (unset or a CachyOS host; D6)" % (n, url))

target_packages = set()

def chk_packages(n, d):
    ops = d.get("operations") or []
    found = []
    for op in ops:
        if isinstance(op, dict):
            for k in ("install", "try_install"):
                found += names_of(op.get(k))
    target_packages.update(found)
    if not ops:
        info("%s: no operations (nothing is force-installed by this instance)" % n)
    else:
        ok("%s: operations install %d package(s)" % (n, len(found)))

one("welcome", ["requirements"], chk_welcome)
one("bootloader", ["efiBootloaderId", "efiBootLoader"], chk_bootloader)
one("grubcfg", ["always_use_defaults", "prefer_grub_d", "keep_distributor"], chk_grubcfg)
one("plymouthcfg", ["plymouth_theme"], chk_plymouth)
one("users", ["defaultGroups"], chk_users)
pkg_confs = by_key("operations", "update_system", "update_db")
for p, d in pkg_confs:
    chk_packages(rel(p), d)
if not pkg_confs:
    bad("no packages config in the overlay (a conf with operations:)")

# netinstall: the package groups must be local, and their selected groups count as installed packages
for p, d in by_key("groupsUrl"):
    n = rel(p)
    urls = d.get("groupsUrl")
    urls = [urls] if isinstance(urls, str) else (urls or [])
    remote = [u for u in urls if re.match(r"https?://", str(u))]
    if remote:
        bad("%s: groupsUrl fetches package groups over the network: %s (D6: no GitHub-raw netinstall dependency)" % (n, ", ".join(map(str, remote))))
    elif urls:
        ok("%s: groupsUrl is local only (%s)" % (n, ", ".join(map(str, urls))))
    else:
        bad("%s: groupsUrl is empty" % n)

def group_packages(groups, out):
    for g in groups or []:
        if not isinstance(g, dict):
            continue
        if g.get("selected") is True:
            out.update(names_of(g.get("packages")))
        group_packages(g.get("subgroups"), out)

for p, d in docs.items():
    if isinstance(d, list) and d and isinstance(d[0], dict) and ("packages" in d[0] or "subgroups" in d[0]):
        group_packages(d, target_packages)
for p, d in by_key("basePackages"):
    target_packages.update(names_of(d.get("basePackages")))

need = REQUIRED_TARGET_PACKAGES + [x for x in args.extra_packages.split() if x]
IMPLIED = {"python": ("python-flask", "gunicorn")}   # pulled in as a dependency; naming them is not needed
missing_pk = [x for x in need if x not in target_packages and not any(i in target_packages for i in IMPLIED.get(x, ()))]
if missing_pk:
    bad("the installed system does not get: %s (not in any operations list, selected netinstall group or basePackages; D8)" % ", ".join(missing_pk))
else:
    ok("the installed system gets all %d required packages (%s)" % (len(need), " ".join(need)))

for p, d in by_key("units"):
    names = [str(u.get("name")) if isinstance(u, dict) else str(u) for u in (d.get("units") or [])]
    info("%s: services-systemd units: %s" % (rel(p), " ".join(names)))
enable_docker = False
for p, d in docs.items():
    if isinstance(d, dict) and isinstance(d.get("units"), list):
        for u in d["units"]:
            if isinstance(u, dict) and "docker" in str(u.get("name", "")) and u.get("action", "enable") == "enable":
                enable_docker = True
    if isinstance(d, dict) and d.get("script") is not None:
        if re.search(r"systemctl[^\n]*\benable\b[^\n]*docker", with_scripts(p)):
            enable_docker = True
if enable_docker:
    ok("a Calamares step enables docker (D8)")
else:
    bad("no Calamares step enables docker (a shellprocess script with systemctl enable ... docker, or a services-systemd unit; D8)")

# ── interface-visible text and endpoints ────────────────────────────────────
def live_text(p):
    """The file without full-line comments (a comment may name a CachyOS host to explain what was replaced)."""
    return "\n".join(ln for ln in text_of(p).splitlines() if not ln.lstrip().startswith(("#", "//")))

CONFIG_EXT = (".conf", ".yaml", ".yml", ".desc", ".qml", ".qss")
hits = 0
for p in files:
    if not p.endswith(CONFIG_EXT):
        continue
    body = live_text(p)
    for host in BANNED_HOSTS:
        if host in body:
            bad("%s mentions %s (D6)" % (rel(p), host))
            hits += 1
for p, d in docs.items():
    if isinstance(d, dict) and isinstance(d.get("i18n"), dict):
        names = " ".join(str(v) for v in d["i18n"].values())
        if re.search(r"cachy", names, re.I):
            bad("%s: progress text names CachyOS: %s" % (rel(p), names[:80]))
if hits == 0:
    ok("scanned %d configuration files: no CachyOS endpoint (paste, wiki, versions.json) and no GitHub-raw URL" % len([p for p in files if p.endswith(CONFIG_EXT)]))

# ── paths the overlay stages must exist in the image ───────────────────────
if image_paths is not None:
    have = set(image_paths)
    prefixes = set()
    for q in image_paths:
        parts = q.split("/")
        for i in range(2, len(parts)):
            prefixes.add("/".join(parts[:i]))
    absent = []
    # Only commands that run in the live system name paths of the image; a chroot command or a script that writes to the target
    # names paths of the target.
    refs = set()
    for p, d in docs.items():
        if isinstance(d, dict) and d.get("dontChroot") is True and d.get("script") is not None:
            for m in re.finditer(r"(/usr/(?:lib|libexec|share)/ci-os/[A-Za-z0-9_./@+-]+)", live_text(p)):
                refs.add(m.group(1).rstrip(".,:;)\"'"))
    for r in sorted(refs):
        r2 = r.rstrip("/")
        if r2 not in have and r2 not in prefixes:
            absent.append(r2)
    if absent:
        bad("paths the overlay refers to are not in the image: %s" % " ".join(absent[:8]))
    else:
        ok("all %d /usr/(lib|libexec|share)/ci-os paths that live-system steps (dontChroot) refer to are in the image" % len(refs))

    def in_image(path):
        return path in have or any(q.endswith(path) for q in image_paths)

    for p, d in docs.items():
        if not isinstance(d, dict):
            continue
        theme = str((d.get("defaults") or {}).get("GRUB_THEME", "")) if isinstance(d.get("defaults"), dict) else ""
        if theme:
            if in_image(theme):
                ok("%s: the GRUB theme %s is in the image (to be carried to the target)" % (rel(p), theme))
            else:
                bad("%s: GRUB_THEME %s is not in the image: GRUB would start without a theme" % (rel(p), theme))
        for k in ("plymouth_theme", "plymouth_theme_amdgpu"):
            t = str(d.get(k, ""))
            if t:
                if in_image("/usr/share/plymouth/themes/%s/%s.plymouth" % (t, t)):
                    ok("%s: the Plymouth theme %s is in the image" % (rel(p), t))
                else:
                    bad("%s: %s=%s but /usr/share/plymouth/themes/%s/%s.plymouth is not in the image" % (rel(p), k, t, t, t))
    # The live image ships the script that puts the identity on the target: a step must run it, in the right place.
    if "/usr/share/ci-os/installed/carry-over" in have:
        for sp, sd in settings:
            name = rel(sp)
            steps = flatten_sequence(sd["sequence"])
            execs = [s_ for k, s_ in steps if k == "exec"]
            carry = [s_ for s_ in execs if s_.startswith("shellprocess@") and "installed/carry-over" in shellprocess_text(s_.split("@", 1)[1])]
            if not carry:
                bad("%s: the image ships /usr/share/ci-os/installed/carry-over but no shellprocess step runs it: the installed system would keep CachyOS's identity, skel and themes" % name)
                continue
            ci = execs.index(carry[0])
            late = [m for m in ("pacstrap",) if m in execs and execs.index(m) > ci]
            pk = [i for i, s_ in enumerate(execs) if s_ == "packages" or s_.startswith("packages@")]
            if late or (pk and ci < pk[0]):
                bad("%s: %s runs before the packages are installed (the target has no skel / os-release / grub yet)" % (name, carry[0]))
            early = [m for m in ("plymouthcfg", "initcpio", "grubcfg", "bootloader") if m in execs and execs.index(m) < ci]
            if early:
                bad("%s: %s runs after %s, which already read the themes it copies" % (name, carry[0], ", ".join(early)))
            if not late and not early and not (pk and ci < pk[0]):
                ok("%s: %s carries the identity to the target after the packages and before plymouthcfg, initcpio, grubcfg and bootloader" % (name, carry[0]))
PYEOF
}

# v_run_calamares_py TREE [options...]: runs the helper and folds its lines into pass / fail / note / skip.
v_run_calamares_py() {
    local py out line
    if ! command -v python3 >/dev/null 2>&1; then skip "Calamares overlay static analysis (python3 is not installed; Arch: python python-yaml)"; return 0; fi
    py="${V_WORKDIR:-${TMPDIR:-/tmp}}/calamares-check.$$.py"
    v_write_calamares_py "$py"
    out="$(python3 -I "$py" "$@" 2>&1)" || true
    rm -f "$py"
    if [ -z "$out" ]; then fail "the Calamares analysis printed nothing"; return 0; fi
    while IFS= read -r line; do
        case "$line" in
            "PASS "*) pass "${line#PASS }" ;;
            "FAIL "*) fail "${line#FAIL }" ;;
            "SKIP "*) skip "${line#SKIP }" ;;
            "info "*) note "${line#info }" ;;
            *) fail "Calamares analysis: $line" ;;
        esac
    done <<EOF
$out
EOF
}

#=============================================================================
# main
#=============================================================================
v_usage() { echo "usage: $0 path/to/companion-os-plasma-*.iso" >&2; }

v_cleanup() {
    [ -n "${VERIFY_KEEP:-}" ] && return 0
    [ -n "${V_WORKDIR:-}" ] && [ -d "$V_WORKDIR" ] || return 0
    chmod -R u+rwX "$V_WORKDIR" 2>/dev/null || true
    rm -rf "$V_WORKDIR"
}

# v_sfs_extract_paths SQUASHFS DESTDIR PATH...: extract these absolute paths (the leading / is removed).
v_sfs_extract_paths() {
    local sq="$1" dest="$2" p args=""
    shift 2
    for p in "$@"; do args="$args ${p#/}"; done
    # shellcheck disable=SC2086
    unsquashfs -no-xattrs -q -f -d "$dest" "$sq" $args >/dev/null 2>&1 || true
}

# v_iso_extract SRC DEST: one file or directory out of the ISO; a missing path must not abort the rest.
v_iso_extract() {
    xorriso -abort_on NEVER -osirrox on -indev "$ISO" -extract "$1" "$2" >/dev/null 2>&1 || true
}

verify_main() {
    # No pipefail on purpose: `grep -q` ends a pipeline early, and with pipefail a successful search then reads as a failure.
    set -u
    ISO="${1:-}"
    local here repo_guess missing t
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # backends/cachyos/iso/scripts is four levels below the repo root.
    VERIFY_REPO="$(cd "$here/../../../.." 2>/dev/null && pwd)"
    repo_guess="$VERIFY_REPO/backends/cachyos"
    [ -n "$ISO" ] && [ -f "$ISO" ] || { v_usage; return 2; }
    missing=""
    for t in xorriso unsquashfs awk sed grep od; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || missing="$missing sha256sum"
    if [ -n "$missing" ]; then echo "missing tools:$missing  (Arch: pacman -S libisoburn squashfs-tools; Debian: apt-get install xorriso squashfs-tools)" >&2; return 2; fi

    V_WORKDIR="${VERIFY_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/verify-iso.XXXXXX")}"
    mkdir -p "$V_WORKDIR"
    trap v_cleanup EXIT
    local W="$V_WORKDIR" ISOX="$V_WORKDIR/iso" R="$V_WORKDIR/root"
    mkdir -p "$ISOX" "$R"
    local iso_base iso_bytes
    iso_base="$(basename "$ISO")"
    iso_bytes="$(wc -c < "$ISO" | tr -d ' ')"
    echo "ISO: $ISO ($((iso_bytes / 1048576)) MiB)"
    local pyinfo="python3 not installed"
    if command -v python3 >/dev/null 2>&1; then pyinfo="$(python3 --version 2>&1 | head -n 1)$(python3 -c 'import yaml; print(" with PyYAML " + yaml.__version__)' 2>/dev/null || echo ' without PyYAML')"; fi
    note "tools: $(xorriso -version 2>&1 | sed -n 's/^xorriso \([0-9.a-z]*\).*/xorriso \1/p' | head -n 1), $(unsquashfs -version 2>&1 | sed -n 's/^unsquashfs version \([0-9.]*\).*/unsquashfs \1/p' | head -n 1), $pyinfo"

    # ── what to extract from the medium ─────────────────────────────────────
    local FL="$W/iso-files.txt" PVD="$W/pvd.txt" ET="$W/eltorito.txt" SA="$W/sysarea.txt"
    xorriso -indev "$ISO" -find / -type f 2>/dev/null | sed -n -E "s/^'(.*)'\$/\\1/p" > "$FL"
    xorriso -indev "$ISO" -pvd_info > "$PVD" 2>&1
    xorriso -indev "$ISO" -report_el_torito plain > "$ET" 2>&1
    xorriso -indev "$ISO" -report_system_area plain > "$SA" 2>&1
    v_iso_extract /boot/grub/grub.cfg "$ISOX/grub.cfg"
    v_iso_extract /boot/grub/loopback.cfg "$ISOX/loopback.cfg"
    v_iso_extract /boot/grub "$ISOX/grub"
    v_iso_extract /boot/syslinux "$ISOX/syslinux"
    v_iso_extract /arch/pkglist.x86_64.txt "$ISOX/pkglist.txt"
    v_iso_extract /arch/version "$ISOX/version"
    v_iso_extract /arch/x86_64/airootfs.sha512 "$ISOX/airootfs.sha512"
    v_iso_extract /EFI/BOOT/BOOTx64.EFI "$ISOX/BOOTx64.EFI"
    local UUID IVER
    UUID="$(v_uuid_of "$FL")" || UUID=""
    IVER="$(tr -d '\n' < "$ISOX/version" 2>/dev/null)"

    # ── 1. medium ───────────────────────────────────────────────────────────
    section "1. The medium (D1): name, label, publisher, boot records, size"
    v_check_iso_name "$iso_base"
    local label pub app
    label="$(sed -n 's/^Volume Id *: *//p' "$PVD" | head -n 1)"
    pub="$(sed -n 's/^Publisher Id *: *//p' "$PVD" | head -n 1)"
    app="$(sed -n 's/^App Id *: *//p' "$PVD" | head -n 1)"
    v_check_label "$label" "$IVER"
    v_check_pvd "$pub" "$app"
    v_check_boot_records "$ET" "$SA"
    v_check_size "$iso_bytes" "${VERIFY_MIN_MB:-1500}" "${VERIFY_MAX_MB:-6144}"
    v_check_medium_files "$FL"
    if [ -n "$UUID" ]; then pass "exactly one /boot/<uuid>.uuid search file: $UUID"; else fail "the medium does not have exactly one /boot/<YYYY-MM-DD-hh-mm-ss-00>.uuid search file"; fi
    if [ -n "$UUID" ] && [ -s "$ISOX/BOOTx64.EFI" ]; then v_check_efi_search "$ISOX/BOOTx64.EFI" "$UUID"; else fail "cannot check that BOOTx64.EFI searches for the medium's uuid file (BOOTx64.EFI or the uuid file is missing)"; fi

    # ── 2. boot menus ───────────────────────────────────────────────────────
    section "2. Boot menus: GRUB (UEFI, loopback) and syslinux (BIOS)"
    v_check_grub_cfg "$ISOX/grub.cfg" grub.cfg "$FL" "${UUID:-NONE}" 1
    v_check_grub_cfg "$ISOX/loopback.cfg" loopback.cfg "$FL" "${UUID:-NONE}" 0
    v_check_syslinux "$ISOX/syslinux" "$FL" "${UUID:-NONE}"
    v_check_art_hashes "$ISOX/grub/splash.png" "$ISOX/syslinux/splash.png" "$ISOX/syslinux/splash1.png"
    # Drift guard against the pinned upstream profile.
    local LOCK UP_SHA UPD="" up_cfg="" up_loop="" up_sys="" instdir=arch arch=x86_64
    LOCK="${VERIFY_LOCK:-$repo_guess/upstream.lock}"
    UP_SHA=""
    if [ -f "$LOCK" ]; then UP_SHA="$(v_lock_get "$LOCK" UPSTREAM_SHA CACHYOS_LIVE_ISO_COMMIT UPSTREAM_COMMIT)" || UP_SHA=""; fi
    if [ -n "${VERIFY_UPSTREAM_DIR:-}" ]; then UPD="$VERIFY_UPSTREAM_DIR"
    elif [ "${VERIFY_FETCH_UPSTREAM:-0}" = 1 ] && [ -n "$UP_SHA" ] && command -v git >/dev/null 2>&1; then
        UPD="$W/upstream"; mkdir -p "$UPD"
        local url
        url="$(v_lock_get "$LOCK" UPSTREAM_REPO CACHYOS_LIVE_ISO_REPO)" || url="https://github.com/CachyOS/CachyOS-Live-ISO.git"
        ( cd "$UPD" && git init -q . && git remote add origin "$url" && git fetch -q --depth 1 origin "$UP_SHA" && git checkout -q --detach FETCH_HEAD ) >"$W/upstream-fetch.log" 2>&1 \
            || { note "fetching the upstream commit failed: $(tail -n 1 "$W/upstream-fetch.log")"; UPD=""; }
    fi
    if [ -z "$UP_SHA" ]; then
        fail "no UPSTREAM_SHA in $LOCK: the pin is what the parity checks compare with (WP-A contract: backends/cachyos/upstream.lock)"
    fi
    if [ -n "$UPD" ] && [ -d "$UPD" ]; then
        local have_sha=""
        if [ -e "$UPD/.git" ] && command -v git >/dev/null 2>&1; then
            have_sha="$(v_git "$UPD" rev-parse HEAD 2>/dev/null || true)"
            if [ -n "$UP_SHA" ] && [ "$have_sha" = "$UP_SHA" ]; then pass "the upstream checkout is at the pinned commit $UP_SHA"
            elif [ -n "$UP_SHA" ]; then fail "the upstream checkout is at ${have_sha:-an unknown commit}, not the pinned $UP_SHA: the parity checks below are against the wrong profile"; fi
            v_git "$UPD" show "HEAD:archiso/grub/grub.cfg" > "$W/up-grub.cfg" 2>/dev/null && up_cfg="$W/up-grub.cfg"
            v_git "$UPD" show "HEAD:archiso/grub/loopback.cfg" > "$W/up-loop.cfg" 2>/dev/null && up_loop="$W/up-loop.cfg"
            v_git "$UPD" show "HEAD:archiso/syslinux/archiso_sys-linux.cfg" > "$W/up-sys.cfg" 2>/dev/null && up_sys="$W/up-sys.cfg"
        else
            note "$UPD is not a git checkout: its commit cannot be confirmed"
            [ -f "$UPD/archiso/grub/grub.cfg" ] && up_cfg="$UPD/archiso/grub/grub.cfg"
            [ -f "$UPD/archiso/grub/loopback.cfg" ] && up_loop="$UPD/archiso/grub/loopback.cfg"
            [ -f "$UPD/archiso/syslinux/archiso_sys-linux.cfg" ] && up_sys="$UPD/archiso/syslinux/archiso_sys-linux.cfg"
        fi
        if [ -n "$up_cfg" ] && [ -n "$UUID" ]; then
            v_subst_upstream "$up_cfg" "$instdir" "$arch" "$UUID" > "$W/up-grub.sub"
            v_check_parity "$ISOX/grub.cfg" "$W/up-grub.sub" "grub.cfg parity" '^[[:space:]]*(linux|initrd)[[:space:]]+/arch/'
        else fail "grub.cfg parity: the upstream grub.cfg could not be read from $UPD (or the medium has no uuid file)"; fi
        if [ -n "$up_loop" ]; then
            v_subst_upstream "$up_loop" "$instdir" "$arch" "${UUID:-NONE}" > "$W/up-loop.sub"
            v_check_parity "$ISOX/loopback.cfg" "$W/up-loop.sub" "loopback.cfg parity" '^[[:space:]]*(linux|initrd)[[:space:]]+/arch/'
        else fail "loopback.cfg parity: the upstream loopback.cfg could not be read from $UPD"; fi
        if [ -n "$up_sys" ] && [ -n "$UUID" ]; then
            v_subst_upstream "$up_sys" "$instdir" "$arch" "$UUID" > "$W/up-sys.sub"
            v_check_parity "$ISOX/syslinux/archiso_sys-linux.cfg" "$W/up-sys.sub" "syslinux parity" '^[[:space:]]*(LINUX|INITRD|APPEND)[[:space:]]'
        else fail "syslinux parity: the upstream archiso_sys-linux.cfg could not be read from $UPD"; fi
    else
        skip "kernel / initrd parity with the pinned upstream profile (set VERIFY_UPSTREAM_DIR to a CachyOS-Live-ISO checkout at the pin, or VERIFY_FETCH_UPSTREAM=1)"
    fi

    # ── the root filesystem ─────────────────────────────────────────────────
    local SQ="$W/airootfs.sfs" LRAW="$W/listing.raw" L="$W/listing.tsv" OWN="$W/pkg-owned.txt"
    if [ "${VERIFY_REUSE:-0}" = 1 ] && [ -s "$SQ" ] && [ "$(wc -c < "$SQ" | tr -d ' ')" -gt 1000000 ]; then
        note "reusing the squashfs already extracted in $W"
    else
        v_iso_extract /arch/x86_64/airootfs.sfs "$SQ"
    fi
    if [ ! -s "$SQ" ]; then
        section "3. airootfs.sfs"
        fail "could not extract /arch/x86_64/airootfs.sfs from the ISO: sections 3 to 6 cannot run"
        v_finish
        return $?
    fi
    unsquashfs -ll "$SQ" 2>/dev/null > "$LRAW" || true
    v_normalise_listing < "$LRAW" > "$L"
    if [ "$(grep -c . "$L")" -lt "${VERIFY_MIN_ENTRIES:-1000}" ]; then fail "the squashfs listing has fewer than ${VERIFY_MIN_ENTRIES:-1000} entries: unsquashfs could not read it, or this is not a full image"; fi

    # Package ownership: every path a package of the image's pacman database lists (to tell our files from packages').
    unsquashfs -no-xattrs -q -f -d "$R" "$SQ" 'var/lib/pacman/local/*/files' >/dev/null 2>&1 || true
    cat "$R"/var/lib/pacman/local/*/files 2>/dev/null | awk '/^%FILES%$/ { f = 1; next } /^%/ { f = 0 } f && NF { print "/" $0 }' | sed 's#/$##' | sort -u > "$OWN"

    # The small files and directories the checks read.
    unsquashfs -no-xattrs -q -f -d "$R" "$SQ" \
        etc/os-release usr/lib/os-release etc/lsb-release etc/issue etc/motd etc/hostname etc/hosts etc/cachyos-release \
        etc/version-tag etc/edition-tag etc/passwd etc/group etc/pacman.conf etc/pacman-more.conf \
        etc/pacman.d/hooks usr/share/libalpm/hooks etc/systemd/system \
        etc/skel/.config home etc/xdg/autostart etc/xdg/kcm-about-distrorc etc/xdg/kdeglobals \
        etc/sudoers.d etc/ssh/sshd_config.d etc/plasmalogin.conf etc/plasmalogin.conf.d \
        usr/local/bin usr/local/sbin usr/share/ci-os usr/lib/ci-os usr/libexec/ci-os etc/ci-os usr/share/libalpm/scripts \
        usr/share/applications usr/share/color-schemes \
        >/dev/null 2>&1 || true

    # ── 3. identity ─────────────────────────────────────────────────────────
    section "3. Identity of the live image (D4, D7, D9)"
    local OSR="$R/etc/os-release"
    if [ -L "$OSR" ] && [ ! -e "$OSR" ]; then OSR="$R/usr/lib/os-release"; fi
    local want_ansi=""
    want_ansi="$(v_token_ansi "$VERIFY_REPO/vendor/brand/tokens/tokens.sh")" || want_ansi=""
    [ -n "$want_ansi" ] || note "vendor/brand/tokens/tokens.sh not found: the console colour is only checked against CachyOS's"
    v_check_os_release "$OSR" "$IVER" "$want_ansi"
    v_check_lsb_release "$R/etc/lsb-release"
    case "$(v_lst_mode "$L" /etc/os-release)" in
        -*) pass "/etc/os-release is a regular file (the hook replaces Arch's symlink instead of writing through it)" ;;
        l*) fail "/etc/os-release is a symlink to $(v_lst_target "$L" /etc/os-release): that is Arch's file, which says Arch Linux" ;;
        *) fail "/etc/os-release is missing from the image" ;;
    esac
    # The os-release hook: shipped somewhere in the image (the live airootfs hooks are deleted at the end of the
    # build by upstream's zzzz99 hook when they carry its marker, so the installed system's copy is what counts).
    local hookpath
    hookpath="$(awk -F'\t' '$3 ~ /\/zz-ci-os-os-release\.hook$/ { print $3; exit }' "$L")"
    if [ -n "$hookpath" ]; then
        pass "zz-ci-os-os-release.hook is in the image: $hookpath"
        if [ ! -f "$R$hookpath" ]; then unsquashfs -no-xattrs -q -f -d "$R" "$SQ" "${hookpath#/}" >/dev/null 2>&1 || true; fi
        v_check_os_release_hook "$R$hookpath"
    else
        fail "zz-ci-os-os-release.hook is not anywhere in the image: cachyos-hooks would rewrite os-release to CachyOS on the first filesystem update (D4)"
    fi
    # hostname, issue, motd
    local hn
    hn="$(tr -d '\n' < "$R/etc/hostname" 2>/dev/null)"
    if [[ "$hn" =~ ^companion-os([-a-z0-9]*)$ ]]; then pass "live hostname is $hn"; else fail "live hostname is '${hn:-<missing>}', expected companion-os... (upstream: CachyOS)"; fi
    if [ -s "$R/etc/issue" ] && { v_hasf "$R/etc/issue" '\S{PRETTY_NAME}' || v_hasf "$R/etc/issue" 'Companion OS'; }; then
        v_check_text_clean "/etc/issue" "$R/etc/issue"
    else fail "/etc/issue names neither \\S{PRETTY_NAME} nor Companion OS"; fi
    v_check_text_clean "/etc/motd" "$R/etc/motd"
    if [ -s "$R/etc/motd" ] && v_has "$R/etc/motd" 'Companion OS'; then pass "/etc/motd names Companion OS"; else fail "/etc/motd does not name Companion OS"; fi
    v_check_no_block_art "$R/etc/motd"
    v_check_about "$R/etc/xdg/kcm-about-distrorc" "$OSR"

    # D7: sshd masked, liveuser, passwordless sudo
    v_check_sshd_masked "$L"
    v_check_sshd_dropin "$R/etc/ssh/sshd_config.d"
    if grep -q -E '^liveuser:x:1000:' "$R/etc/passwd" 2>/dev/null; then pass "the live user is still liveuser (uid 1000, D7)"; else fail "no liveuser (uid 1000) in /etc/passwd (D7)"; fi
    if v_has "$R/etc/sudoers.d/g_wheel" '^%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+NOPASSWD:[[:space:]]*ALL' ; then pass "wheel keeps passwordless sudo (D7: the installer launcher uses sudo)"; else fail "wheel has no NOPASSWD sudo rule in /etc/sudoers.d/g_wheel (D7; calamares-online.sh needs sudo)"; fi
    local dm
    dm="$(v_lst_target "$L" /etc/systemd/system/display-manager.service)"
    if [ "$dm" = "/usr/lib/systemd/system/plasmalogin.service" ]; then pass "display-manager.service -> plasmalogin.service (D2)"; else fail "display-manager.service -> '${dm:-<absent>}', expected plasmalogin.service (D2)"; fi
    if v_has "$R/etc/plasmalogin.conf.d/autologin.conf" '^User=liveuser$' && v_has "$R/etc/plasmalogin.conf.d/autologin.conf" '^Session=plasma'; then pass "plasmalogin autologin of liveuser into Plasma is intact"; else fail "plasmalogin autologin drop-in is missing or changed"; fi

    # Wallpaper, logo icon, colour scheme: ours (unowned by any package) and real images.
    local f info w h sz found
    found=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -Fxq -- "$f" "$OWN" && continue
        found="$found $f"
    done <<EOF
$(awk -F'\t' 'substr($1,1,1) == "-" && $3 ~ /^\/usr\/share\/wallpapers\/.*\.(png|jpg|jpeg|webp)$/ { print $3 }' "$L")
EOF
    local wall_ok="" cand
    if [ -n "$found" ]; then
        # shellcheck disable=SC2086
        v_sfs_extract_paths "$SQ" "$R" $found
        for cand in $found; do
            sz="$(v_lst_size "$L" "$cand")"
            if info="$(v_png_info "$R$cand")" && [ -n "$info" ]; then
                w="${info%% *}"; h="${info#* }"; h="${h%% *}"
                if [ "$w" -ge 1280 ] && [ "$h" -ge 720 ] && [ "${sz:-0}" -ge 20000 ]; then wall_ok="$wall_ok ${cand##*/}(${w}x${h})"; fi
            elif [ "$(head -c2 "$R$cand" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "ffd8" ] && [ "${sz:-0}" -ge 20000 ]; then wall_ok="$wall_ok ${cand##*/}(jpeg)"; fi
        done
    fi
    if [ -n "$wall_ok" ]; then
        for cand in $found; do
            case "$cand" in /usr/share/wallpapers/*/contents/*) v_check_wallpaper_package "$L" "$(printf '%s' "$cand" | sed -E 's#^(/usr/share/wallpapers/[^/]+)/.*#\1#')"; break ;; esac
        done
        pass "a Companion wallpaper (not from a package) is in /usr/share/wallpapers:$wall_ok"
    else fail "no wallpaper of ours in /usr/share/wallpapers (a package-unowned PNG/JPEG of at least 1280x720 and 20 kB; upstream's cachyos-wallpapers is not in the live list)"; fi
    found=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        found="$found $f"
    done <<EOF
$(awk -F'\t' '$3 ~ /^\/usr\/share\/(icons|pixmaps)\/.*\/ci-os-logo[^\/]*\.(svg|png)$/ && substr($1,1,1) == "-" { print $3 }' "$L")
EOF
    if [ -n "$found" ]; then
        # shellcheck disable=SC2086
        v_sfs_extract_paths "$SQ" "$R" $found
        local logo_ok=""
        for cand in $found; do
            sz="$(v_lst_size "$L" "$cand")"
            case "$cand" in
                *.svg) if grep -q '<svg' "$R$cand" 2>/dev/null && [ "${sz:-0}" -ge 200 ]; then logo_ok="$logo_ok ${cand##*/}"; fi ;;
                *.png) if v_png_is "$R$cand" && [ "${sz:-0}" -ge 500 ]; then logo_ok="$logo_ok ${cand##*/}"; fi ;;
            esac
        done
        if [ -n "$logo_ok" ]; then pass "the ci-os-logo icon (LOGO= in os-release) is installed:$logo_ok"; else fail "ci-os-logo files exist but are not real images (an svg without <svg>, a png below 500 bytes, or a bad signature):$found"; fi
    else
        fail "no ci-os-logo.svg / ci-os-logo.png in the image: LOGO=ci-os-logo in os-release resolves to nothing"
    fi
    if v_has "$R/usr/share/color-schemes/CI-OS-Dark.colors" '^Name=Companion OS Dark$'; then pass "the Companion OS Dark colour scheme is installed"; else fail "usr/share/color-schemes/CI-OS-Dark.colors is missing or not named Companion OS Dark"; fi
    if v_has "$R/etc/skel/.config/kdeglobals" '^ColorScheme=CI-OS-Dark$' || v_has "$R/home/liveuser/.config/kdeglobals" '^ColorScheme=CI-OS-Dark$' || v_has "$R/etc/xdg/kdeglobals" '^ColorScheme=CI-OS-Dark$' || v_has "$R/etc/skel/.config/kdedefaults/kdeglobals" '^ColorScheme=CI-OS-Dark$'; then
        pass "the live desktop selects the CI-OS-Dark colour scheme"
    else fail "no kdeglobals (skel, liveuser, /etc/xdg) selects ColorScheme=CI-OS-Dark: the live desktop would be Breeze Dark"; fi
    # D9: no CachyOS artwork came from our overlay = no package-unowned image whose name says cachy
    found="$(awk -F'\t' 'substr($1,1,1) == "-" && tolower($3) ~ /cachy/ && tolower($3) ~ /\.(png|svg|svgz|jpg|jpeg|jxl|webp)$/ { print $3 }' "$L" | while IFS= read -r f; do grep -Fxq -- "$f" "$OWN" || printf '%s ' "$f"; done)"
    if [ -z "$found" ]; then pass "no CachyOS-named artwork outside the packages (nothing of ours is CachyOS art; D9)"; else fail "CachyOS-named image(s) that no package owns, so they came from the overlay or a scriptlet (D9):$found"; fi

    section "3b. Installer entry point (D6)"
    local launcher="" lp
    while IFS= read -r lp; do
        [ -n "$lp" ] || continue
        if [ -f "$R$lp" ] && grep -q 'calamares-online\.sh' "$R$lp" && ! grep -Fxq -- "$lp" "$OWN"; then launcher="$lp"; break; fi
    done <<EOF
$(awk -F'\t' '$3 ~ /^\/usr\/share\/applications\/[^\/]+\.desktop$/ { print $3 }' "$L")
EOF
    if [ -n "$launcher" ]; then pass "an installer launcher of ours is in the image: $launcher"; v_check_launcher_desktop "$R$launcher"
    else fail "no package-unowned .desktop in /usr/share/applications runs calamares-online.sh (the live session would have no way to start the installer)"; fi
    if v_lst_has "$L" /usr/local/bin/calamares-online.sh; then
        v_mode_is_exec "$(v_lst_mode "$L" /usr/local/bin/calamares-online.sh)" && pass "/usr/local/bin/calamares-online.sh is executable" || fail "/usr/local/bin/calamares-online.sh is not executable ($(v_lst_mode "$L" /usr/local/bin/calamares-online.sh))"
        v_check_calamares_script "$R/usr/local/bin/calamares-online.sh"
    else fail "/usr/local/bin/calamares-online.sh is missing"; fi
    v_mode_is_exec "$(v_lst_mode "$L" /usr/local/bin/pkexec-wrapper)" && pass "/usr/local/bin/pkexec-wrapper is executable" || fail "/usr/local/bin/pkexec-wrapper is missing or not executable"
    v_check_hello_gate "$L" "$ISOX/pkglist.txt" "$R"

    section "3c. What the installed system gets from this image (carry-over)"
    v_check_release_stamp "$R/usr/share/ci-os/release" "$OSR"
    v_check_carryover "$L" "$R/usr/share/ci-os/installed/carry-over.list"

    # ── 4. packages ─────────────────────────────────────────────────────────
    section "4. Package list"
    local OV="$repo_guess/iso/overlay"
    if [ -d "$OV" ]; then
        v_check_pkglist "$ISOX/pkglist.txt" "$OV/packages.add" "$OV/packages.remove"
    else
        v_check_pkglist "$ISOX/pkglist.txt" "$OV/packages.add" "$OV/packages.remove"
        note "the overlay directory $OV is not there: running outside the repo checkout"
    fi
    # The list on the medium equals the image's own pacman database.
    v_check_pkglist_vs_db "$R" "$ISOX/pkglist.txt" "$W"

    # ── 5. Calamares overlay ────────────────────────────────────────────────
    section "5. Calamares overlay (usr/share/ci-os/calamares), static"
    local CT="$R/usr/share/ci-os/calamares"
    awk -F'\t' 'index($3, "/usr/lib/calamares/modules/") == 1 { n = $3; sub("^/usr/lib/calamares/modules/", "", n); if (n !~ /\//) print n }' "$L" > "$W/stock-modules.txt"
    unsquashfs -no-xattrs -q -f -d "$R" "$SQ" etc/calamares/modules >/dev/null 2>&1 || true
    ls "$R/etc/calamares/modules" 2>/dev/null > "$W/stock-confs.txt" || : > "$W/stock-confs.txt"
    awk -F'\t' '{ print $3 }' "$L" > "$W/image-paths.txt"
    local deps=""
    if [ -f "$VERIFY_REPO/backends/arch/headless-setup/install.sh" ]; then
        # ARCH_DEPS=(a b c ...) on one line in the Arch headless installer: the target gets them too (D8).
        deps="$(sed -n -E 's/^ARCH_DEPS=\((.*)\)[[:space:]]*(#.*)?$/\1/p' "$VERIFY_REPO/backends/arch/headless-setup/install.sh" | head -n 1)"
        [ -n "$deps" ] && note "also requiring the Arch headless installer's ARCH_DEPS: $deps"
    fi
    if [ ! -d "$CT" ]; then
        fail "usr/share/ci-os/calamares is not in the image: no Companion branding, module configuration or package list for the installer (D6)"
    else
        v_run_calamares_py "$CT" --stock-modules "$W/stock-modules.txt" --stock-confs "$W/stock-confs.txt" --image-paths "$W/image-paths.txt" --extra-packages "$deps"
    fi

    # ── 6. modes ────────────────────────────────────────────────────────────
    section "6. File modes (mkarchiso drops modes; file_permissions restores the listed ones)"
    v_check_modes "$L" "$R" "$OWN"
    v_check_perm "$L" /etc/shadow '^-r--------$' '0400'
    v_check_perm "$L" /etc/gshadow '^-r--------$' '0400'
    v_check_vm_generator "$L"
    local sf bad=0 m n=0
    while IFS= read -r sf; do
        [ -n "$sf" ] || continue
        n=$((n + 1))
        m="$(v_lst_mode "$L" "$sf")"
        case "$m" in -r--r-----|-r--------) ;; *) fail "$sf is $m, sudo wants 0440 (add it to file_permissions)"; bad=$((bad + 1)) ;; esac
    done <<EOF
$(awk -F'\t' 'substr($1,1,1) == "-" && index($3, "/etc/sudoers.d/") == 1 { print $3 }' "$L")
EOF
    [ "$bad" -eq 0 ] && [ "$n" -gt 0 ] && pass "all $n file(s) in /etc/sudoers.d are 0440"
    [ "$n" -eq 0 ] && fail "/etc/sudoers.d has no file: the live user would have no sudo"
    # A hook of ours must run something that exists (and, as the command itself, is executable).
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$R$f" ] || unsquashfs -no-xattrs -q -f -d "$R" "$SQ" "${f#/}" >/dev/null 2>&1 || true
        [ -f "$R$f" ] && v_check_hook_exec "$L" "$R$f" "${f##*/}"
    done <<EOF
$(awk -F'\t' '$3 ~ /ci-os[^\/]*\.hook$/ { print $3 }' "$L")
EOF

    # ── 7. provenance ───────────────────────────────────────────────────────
    section "7. Build provenance"
    if [ -f "$LOCK" ]; then v_check_lock_identity "$LOCK"; else fail "upstream.lock not found at $LOCK (WP-A contract: backends/cachyos/upstream.lock); cannot compare the build with its pin"; fi
    local bi="" cand2 dir
    dir="$(dirname "$ISO")"
    for cand2 in "${ISO%.iso}.build-info" "$ISO.build-info" "${ISO%.partial}.build-info" "$dir/build-info.txt" "$dir/build-info"; do
        if [ -s "$cand2" ]; then bi="$cand2"; break; fi
    done
    # The record inside the image (usr/share/ci-os/iso-build-info) is always there to check; the sidecar next to the ISO
    # exists once the build has finished.
    if [ -f "$LOCK" ]; then
        if [ -s "$R/usr/share/ci-os/iso-build-info" ]; then
            v_check_buildinfo "$R/usr/share/ci-os/iso-build-info" "$LOCK" "record inside the image"
        else
            fail "/usr/share/ci-os/iso-build-info is not in the image: nothing inside the ISO says which upstream commit and overlay it was built from"
        fi
    fi
    if [ -z "$bi" ]; then
        skip "the build record next to the ISO (${iso_base%.iso}.build-info; the build writes it once the ISO is finished)"
    elif [ -f "$LOCK" ]; then
        note "build record: $bi"
        v_check_buildinfo "$bi" "$LOCK" "record next to the ISO"
        v_check_buildinfo_iso "$bi" "$ISO"
        if [ -s "$R/usr/share/ci-os/iso-build-info" ]; then v_check_buildinfo_pair "$R/usr/share/ci-os/iso-build-info" "$bi" "$OSR"; fi
    else
        fail "a build record exists but $LOCK (upstream.lock) is missing: nothing to compare it with"
    fi
    # Risk R1: the compatibility libraries of compat-libs.lock are in the image, and the record says the step that put them there ran.
    local clock="${VERIFY_COMPAT_LOCK:-$repo_guess/compat-libs.lock}" clibs=""
    if [ "$V_HAVE_COMPAT_LOCK" = 1 ] && [ -f "$clock" ]; then clibs="$(compat_lock_libs "$clock" 2>/dev/null | awk '{ print "/" $2 }' | tr '\n' ' ')"; fi
    # shellcheck disable=SC2086
    [ -z "$clibs" ] || v_sfs_extract_paths "$SQ" "$R" $clibs
    v_check_compat_libs "$clock" "$L" "$R" "$R/usr/share/ci-os/iso-build-info" "$bi"
    local pk="${ISO%.iso}.pkgs.txt"
    if [ -s "$pk" ]; then
        v_check_pkgs_txt "$pk" "$ISOX/pkglist.txt"
    else skip "$(basename "$pk") (the package list published next to the ISO) is not there"; fi

    # ── 8. integrity ────────────────────────────────────────────────────────
    section "8. Integrity"
    local shaf=""
    for cand2 in "$ISO.sha256" "${ISO%.partial}.sha256" "${ISO%.iso}.sha256"; do
        if [ -s "$cand2" ]; then shaf="$cand2"; break; fi
    done
    if [ -n "$shaf" ]; then v_check_sha256_file "$shaf" "$ISO"; else skip "the .sha256 next to the ISO is not there ($iso_base.sha256)"; fi
    if [ "${VERIFY_SKIP_SFS_HASH:-0}" = 1 ]; then skip "airootfs.sha512 against the squashfs (VERIFY_SKIP_SFS_HASH=1)"
    elif [ -s "$ISOX/airootfs.sha512" ]; then v_check_sfs_sha512 "$ISOX/airootfs.sha512" "$SQ"
    else fail "/arch/x86_64/airootfs.sha512 is missing"; fi

    # ── known residuals ─────────────────────────────────────────────────────
    section "Known residual CachyOS / Arch strings (identifiers, not counted as failures)"
    note "kernels: $(awk '{ print $1 }' "$ISOX/pkglist.txt" 2>/dev/null | grep -E '^linux-cachyos' | tr '\n' ' ') (uname -r says -cachyos; disclose, do not hide)"
    note "repositories: [cachyos] and cachyos-mirrorlist in /etc/pacman.conf; installed systems keep them (the base is the substance of the edition)"
    note "package, unit and path names with cachyos- in them; the grub --id values and syslinux LABEL names"
    note "/usr/lib/os-release: $(v_osrel_get "$R/usr/lib/os-release" PRETTY_NAME) (Arch's filesystem package owns it; /etc/os-release is the file that counts)"
    note "/etc/lsb-release keeps DISTRIB_ID=$(v_osrel_get "$R/etc/lsb-release" DISTRIB_ID) (the base's machine identity, like ID in os-release)"
    note "/etc/cachyos-release: $(grep -c . "$R/etc/cachyos-release" 2>/dev/null) line(s) from the upstream airootfs (no user-visible surface found)"
    if grep -q -E 'icon=org\.cachyos\.hello' "$R"/etc/skel/.config/*appletsrc "$R"/home/*/.config/*appletsrc 2>/dev/null; then note "the Plasma start-menu icon is still org.cachyos.hello (long tail: the start-menu icon is a P2 item)"; fi
    note "Firefox: Arch's distribution.ini says 'for Arch Linux' (package-owned)"
    v_finish
    return $?
}

# v_finish: the summary and the exit status.
v_finish() {
    printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
    if [ "${#SKIPPED[@]}" -gt 0 ]; then
        printf '\n== SKIPPED: %d group(s) of checks did NOT run, so "%d failed" does not cover them:\n' "${#SKIPPED[@]}" "$FAIL"
        printf '   - %s\n' "${SKIPPED[@]}"
        if [ "${VERIFY_REQUIRE_ALL:-0}" = 1 ]; then
            echo "   VERIFY_REQUIRE_ALL=1: a run that skipped them fails."
            FAIL=$((FAIL + 1))
        fi
    fi
    [ -n "${VERIFY_KEEP:-}" ] && echo "scratch kept in $V_WORKDIR"
    [ "$FAIL" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    verify_main "$@"
    exit $?
fi
