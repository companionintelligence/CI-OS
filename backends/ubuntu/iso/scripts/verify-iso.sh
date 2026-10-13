#!/usr/bin/env bash
#=============================================================================
# Verify a built Companion OS ISO
#
# Inspects the ISO without root and without booting it: it extracts only what
# it needs (the merged root squashfs listing, a handful of files, the initrd)
# and asserts that
#
#   1. every CI-Hub and wireless-setup tool is PRE-INSTALLED (packages, files,
#      enabled systemd units), and the hotspot stack is guarded so it cannot
#      start inside a live session;
#   2. the user-visible branding is Companion OS, while the identifiers that
#      apt, casper, the installer and Secure Boot depend on are untouched.
#
# What is deliberately NOT asserted, because it cannot be changed by remastering:
# the installer window's own text (a Canonical snap with a fixed flavour list)
# and the ISO volume id (casper and the EFI boot path rely on it). They are
# listed as KNOWN at the end so nobody mistakes them for oversights.
#
# Usage:
#   backends/ubuntu/iso/scripts/verify-iso.sh path/to/companion-os-*.iso
#   VERIFY_KEEP=1 ...      keep the extracted files (printed at the end)
#   VERIFY_WORK=DIR ...    use DIR for scratch space (needs ~8 GB free)
#
# Needs: xorriso squashfs-tools zstd cpio (Ubuntu: apt-get install xorriso squashfs-tools zstd cpio).
#        Exit status is
#        non-zero if any check fails.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

ISO="${1:-}"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "usage: $0 path/to/companion-os.iso" >&2; exit 2; }

missing=()
for t in xorriso unsquashfs zstd cpio; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "missing tools: ${missing[*]}  (apt-get install xorriso squashfs-tools zstd cpio)" >&2
    exit 2
fi

WORK="${VERIFY_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/verify-iso.XXXXXX")}"
mkdir -p "$WORK"
cleanup() { [[ -n "${VERIFY_KEEP:-}" ]] || rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
note() { printf 'info  %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
check() { # check "<label>" <command...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

# ── extract what we need ────────────────────────────────────────────────────
echo "ISO: $ISO ($(du -h "$ISO" | cut -f1))"
ISOX="$WORK/iso"; mkdir -p "$ISOX"
xorriso -osirrox on -indev "$ISO" \
    -extract /boot/grub/grub.cfg "$ISOX/grub.cfg" \
    -extract /boot/grub/loopback.cfg "$ISOX/loopback.cfg" \
    -extract /.disk/info "$ISOX/disk-info" \
    -extract /casper/initrd "$ISOX/initrd" \
    -extract /casper/minimal.squashfs "$ISOX/minimal.squashfs" >/dev/null 2>&1
[[ -s "$ISOX/minimal.squashfs" ]] || { echo "could not extract /casper/minimal.squashfs from $ISO" >&2; exit 2; }
PVD_VOLID="$(xorriso -indev "$ISO" -pvd_info 2>&1 | sed -n 's/^Volume Id *: *//p' | head -1)"

SQ="$ISOX/minimal.squashfs"
LISTING="$WORK/listing.txt"
unsquashfs -ll "$SQ" 2>/dev/null | sed 's#squashfs-root##' > "$LISTING"
R="$WORK/root"; mkdir -p "$R"
# Extract the small files we read. Missing ones are fine here; the checks report them.
# -no-xattrs: an unprivileged run cannot write trusted.overlay.* and unsquashfs aborts on the first failure.
unsquashfs -no-xattrs -q -f -d "$R" "$SQ" \
    etc/os-release usr/lib/os-release etc/lsb-release etc/issue etc/issue.net etc/hostname \
    etc/casper.conf etc/default/grub var/lib/dpkg/status \
    etc/dconf/profile/user etc/dconf/db/local.d \
    usr/share/glib-2.0/schemas \
    usr/share/gnome-background-properties \
    etc/update-motd.d etc/systemd/system etc/sudoers.d \
    usr/lib/ci-os usr/local/bin/ci-os-info \
    usr/share/applications/ci-os-hub.desktop \
    usr/share/plymouth/themes/spinner/watermark.png usr/share/plymouth/themes/bgrt \
    >/dev/null 2>&1 || true

in_listing() { grep -q -E "$1" "$LISTING"; }
pkg_ok() { # package installed ("install ok installed" in dpkg status)
    awk -v p="$1" 'BEGIN{RS=""; FS="\n"} $1=="Package: " p {for(i=1;i<=NF;i++) if($i=="Status: install ok installed") {found=1}} END{exit !found}' "$R/var/lib/dpkg/status" 2>/dev/null
}
file_has() { grep -q -E -- "$2" "$1" 2>/dev/null; }
unit_enabled() { # a symlink to the unit exists under some *.wants directory
    in_listing "etc/systemd/system/[a-z.-]+\.wants/$1 -> "
}

# ── 1. pre-installed packages ───────────────────────────────────────────────
section "1. Pre-installed packages (wireless setup + CI-Hub tooling)"
for p in setup-device hostapd dnsmasq nginx-light python3-flask gunicorn network-manager iw \
         curl jq openssl ufw rfkill wpasupplicant \
         docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin; do
    if pkg_ok "$p"; then pass "package installed: $p"; else fail "package NOT installed: $p"; fi
done

section "2. Pre-installed files (wireless setup payload + CI-Hub tooling)"
for f in /usr/local/bin/setup-network-monitor.sh /usr/local/bin/setup-device-hotspot-start.sh \
         /usr/local/bin/setup-device-prescan.py /usr/local/bin/setup-wifi-recover \
         /usr/local/bin/setup-hotspot-reset.sh /usr/local/bin/ci-os-hub-start.sh \
         /usr/local/bin/ci-os-post-validation.sh /opt/setup-backend/setup_service.py \
         /var/www/setup-portal/index.html /etc/hostapd/hostapd-setup.conf \
         /etc/dnsmasq.d/setup-portal.conf /etc/nginx/sites-available/setup-portal \
         /etc/systemd/system/hostapd-setup.service /etc/systemd/system/dnsmasq-setup.service \
         /etc/systemd/system/setup-backend.service /etc/systemd/system/setup-network-monitor.service \
         /usr/share/applications/ci-os-hub.desktop \
         /usr/lib/ci-os/bootstrap/core/lib/ci-hub.sh \
         /usr/lib/ci-os/bootstrap/backends/ubuntu/provision/provision.sh \
         /usr/bin/docker /usr/local/bin/ci-os-info; do
    if in_listing " ${f}( ->|\$)"; then pass "present: $f"; else fail "MISSING: $f"; fi
done

section "3. Services: enabled where they should be, guarded where they must not run live"
# The guard is ConditionPathExists=!/cdrom/casper/vmlinuz, not boot=casper: casper does not put boot=casper on
# the command line of the plain ISO, but the live medium is always mounted at /cdrom (also on a Companion Stick).
for u in hostapd-setup.service dnsmasq-setup.service setup-backend.service setup-network-monitor.service; do
    if unit_enabled "$u"; then pass "enabled for the installed system: $u"; else fail "NOT enabled: $u"; fi
    d="etc/systemd/system/$u.d/10-not-live.conf"
    if file_has "$R/$d" '^ConditionPathExists=!/cdrom/casper/vmlinuz'; then
        pass "never starts in a live session (casper): $u"
    else
        fail "no live-session guard (would start a hotspot stack in the live ISO): $u"
    fi
done
for u in docker.service containerd.service; do
    if in_listing "etc/systemd/system/[a-z.-]+\.wants/$u -> "; then pass "enabled: $u"; else fail "NOT enabled: $u"; fi
done
if in_listing 'etc/systemd/system/multi-user\.target\.wants/dnsmasq\.service -> '; then
    fail "distro dnsmasq.service is enabled (conflicts with systemd-resolved on port 53; only dnsmasq-setup should run)"
else
    pass "distro dnsmasq.service is not enabled"
fi
if file_has "$R/etc/systemd/system/nginx.service.d/10-not-live.conf" '^ConditionPathExists=!/cdrom/casper/vmlinuz'; then
    pass "distro nginx.service is guarded against live sessions"
else
    fail "distro nginx.service has no live-session guard"
fi

# ── 4. branding ─────────────────────────────────────────────────────────────
section "4. Branding: user-visible identity is Companion OS"
check "os-release NAME is Companion OS" file_has "$R/usr/lib/os-release" '^NAME="Companion OS"$'
check "os-release PRETTY_NAME starts with Companion OS" file_has "$R/usr/lib/os-release" '^PRETTY_NAME="Companion OS '
check "os-release keeps ID=ubuntu (apt and the installer rely on it)" file_has "$R/usr/lib/os-release" '^ID=ubuntu$'
check "os-release keeps VERSION_CODENAME (apt sources)" file_has "$R/usr/lib/os-release" '^VERSION_CODENAME=[a-z]+$'
check "lsb-release description is Companion OS" file_has "$R/etc/lsb-release" '^DISTRIB_DESCRIPTION="Companion OS'
check "lsb-release keeps DISTRIB_ID=Ubuntu (tools key off it)" file_has "$R/etc/lsb-release" '^DISTRIB_ID=Ubuntu$'
check "/etc/issue is Companion OS" file_has "$R/etc/issue" 'Companion OS'
check "installed-system hostname is companion-os" file_has "$R/etc/hostname" '^companion-os$'
check "GRUB_DISTRIBUTOR is Companion OS" file_has "$R/etc/default/grub" '^GRUB_DISTRIBUTOR="Companion OS"'
check "live session host name is not 'ubuntu'" bash -c "! grep -q -E '^export HOST=\"ubuntu\"' '$R/etc/casper.conf'"
check "live session user is not 'ubuntu'" bash -c "! grep -q -E '^export USERNAME=\"ubuntu\"' '$R/etc/casper.conf'"
check "casper keeps BUILD_SYSTEM=Ubuntu (casper logic depends on it)" file_has "$R/etc/casper.conf" '^export BUILD_SYSTEM="Ubuntu"'
check "MOTD header is Companion OS" bash -c "grep -q 'Companion OS' '$R'/etc/update-motd.d/00-ci-os-header"
if in_listing '^-rw-r--r-- .* /etc/update-motd\.d/00-header$'; then pass "Ubuntu's own MOTD welcome (00-header) is disabled"; else fail "Ubuntu's own MOTD welcome (00-header) is still executable"; fi

section "5. Branding: boot menu"
check "GRUB menu says Companion OS" file_has "$ISOX/grub.cfg" 'menuentry "Try or Install Companion OS"'
check "/.disk/info starts with Companion-OS (launcher label 'Install Companion OS ...')" bash -c "head -1 '$ISOX/disk-info' | grep -q -E '^Companion-OS [0-9.]+ LTS '"
check "/.disk/info keeps the (serial) suffix pollinate parses" bash -c "head -1 '$ISOX/disk-info' | grep -q -E '\\([0-9.]+\\)\\s*\$'"
check "no Ubuntu in any GRUB menu entry title" bash -c "! grep -E '^\s*menuentry' '$ISOX/grub.cfg' '$ISOX/loopback.cfg' | grep -q -i ubuntu"

section "6. Branding: desktop defaults (wallpaper / picker)"
check "dconf user profile reads the system 'local' db (without it local.d is ignored)" file_has "$R/etc/dconf/profile/user" '^system-db:local$'
check "wallpaper default comes from a schema override that sorts after Ubuntu's" bash -c "ls '$R'/usr/share/glib-2.0/schemas/ | grep -q -E '^9[0-9]_.*companion.*\.gschema\.override$'"
check "wallpaper override points at the Companion wallpaper" bash -c "grep -h picture-uri '$R'/usr/share/glib-2.0/schemas/9*_*companion*.override | grep -q ci-os-wallpaper"
# GNOME only loads *.xml; a dpkg-diverted "*.xml.disabled" is not offered.
check "Ubuntu wallpaper collections are not offered in Settings" bash -c "! ls '$R'/usr/share/gnome-background-properties 2>/dev/null | grep -E '\\.xml\$' | grep -q -i -E 'ubuntu|noble|resolute'"

section "7. Branding: live boot splash and live identity (initrd)"
# build-iso.sh appends a small zstd-compressed cpio overlay to casper/initrd (the kernel unpacks concatenated
# archives in order and later files win). unmkinitramfs stops after the first compressed segment, so it cannot
# see the overlay; find and unpack it the way the kernel will: the last zstd frame that decodes to a cpio.
OVL="$WORK/overlay.cpio"; OVLX="$WORK/overlay"; mkdir -p "$OVLX"
found_overlay=""
while read -r off; do
    [[ -n "$off" ]] || continue
    if tail -c +$((off + 1)) "$ISOX/initrd" | zstd -dc > "$OVL" 2>/dev/null \
       && [[ "$(head -c6 "$OVL")" == "070701" ]] \
       && cpio -t < "$OVL" 2>/dev/null | grep -q '^etc/casper\.conf$'; then
        found_overlay=1; break
    fi
done < <(LC_ALL=C grep -obUaP '\x28\xb5\x2f\xfd' "$ISOX/initrd" 2>/dev/null | cut -d: -f1 | sort -rn | head -40)
if [[ -n "$found_overlay" ]]; then
    ( cd "$OVLX" && cpio -id --quiet < "$OVL" )
    pass "initrd carries the Companion OS overlay (appended archive)"
else
    fail "initrd has no Companion OS overlay (live splash and live identity are still stock Ubuntu)"
fi
WM_INITRD="$OVLX/usr/share/plymouth/themes/spinner/watermark.png"
WM_ROOT="$R/usr/share/plymouth/themes/spinner/watermark.png"
if [[ -f "$WM_INITRD" && -f "$WM_ROOT" ]]; then
    if [[ "$(sha256sum "$WM_INITRD" | cut -d' ' -f1)" == "$(sha256sum "$WM_ROOT" | cut -d' ' -f1)" ]]; then
        pass "live splash logo (initrd overlay) is the same branded image as the installed system"
    else
        fail "live splash logo in the initrd differs from the branded one in the rootfs"
    fi
else
    fail "branded Plymouth watermark missing (initrd overlay: $([[ -f "$WM_INITRD" ]] && echo present || echo missing), rootfs: $([[ -f "$WM_ROOT" ]] && echo present || echo missing))"
fi
png_width() { od -An -tu1 -j16 -N4 "$1" 2>/dev/null | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}'; }
if [[ -f "$WM_ROOT" ]]; then
    w="$(png_width "$WM_ROOT")"
    # Ubuntu's own watermark is 248 px wide; the design is the banner at 50% (512 px). A 1024 px logo means
    # the scaling step was skipped (no ImageMagick on the build host).
    if [[ -n "$w" && "$w" -le 600 ]]; then pass "Plymouth logo is splash-sized (${w}px wide)"; else fail "Plymouth logo is ${w:-unknown}px wide (full-size banner; install imagemagick on the build host)"; fi
fi
# The no-tool fallback in render-grub-background.sh leaves a ~17 byte placeholder, so check the size too.
grub_bg_size="$(awk '$NF == "/usr/share/pixmaps/ci-os-grub-bg.png" {print $3; exit}' "$LISTING")"
if [[ -n "$grub_bg_size" && "$grub_bg_size" -ge 5000 ]]; then
    pass "GRUB background image is installed (${grub_bg_size} bytes)"
else
    fail "GRUB background image is missing or a placeholder (${grub_bg_size:-absent} bytes): build host lacks rsvg-convert/imagemagick?"
fi
CC_INITRD="$OVLX/etc/casper.conf"
if [[ -f "$CC_INITRD" ]]; then
    check "live session user is not 'ubuntu' (initrd casper.conf)" bash -c "! grep -q -E '^export USERNAME=\"ubuntu\"' '$CC_INITRD'"
    check "live session host name is not 'ubuntu' (initrd casper.conf)" bash -c "! grep -q -E '^export HOST=\"ubuntu\"' '$CC_INITRD'"
    check "FLAVOUR is set so casper does not re-derive user/host from /.disk/info (initrd casper.conf)" file_has "$CC_INITRD" '^export FLAVOUR="[^"]+"'
else
    fail "no etc/casper.conf in the initrd overlay"
fi
note "the kernel's acceptance of the appended archive is only proven by booting the ISO (see the QEMU boot check)"

# ── known, unfixable by remastering ─────────────────────────────────────────
section "Known residual Ubuntu strings (cannot be changed by remastering; not counted as failures)"
note "ISO volume id: '${PVD_VOLID:-unknown}' (casper/EFI rely on it)"
note "/.disk/info is now: $(tr -d '\n' < "$ISOX/disk-info" 2>/dev/null) (field layout kept: casper, subiquity and pollinate parse it)"
note "installer window text ('Welcome to Ubuntu'): Canonical snap ubuntu-desktop-bootstrap; flavour list is fixed (Ubuntu/Kubuntu/Lubuntu/Xubuntu/Edubuntu)"
note "ID=ubuntu / DISTRIB_ID=Ubuntu / UBUNTU_CODENAME: required by apt, curtin and tooling"

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ -n "${VERIFY_KEEP:-}" ]] && echo "scratch kept in $WORK"
[[ "$FAIL" -eq 0 ]]
