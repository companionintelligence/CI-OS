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
#   1b. Docker works in every boot mode (installed, plain live ISO, Companion Stick
#      live boot) and the live and installed users end up in the docker group;
#   1c. the optional tools (tailscale, cloudflared, gh, Ollama, Companion Launcher)
#      are pre-installed from the pinned vendor sources (core/manifest/tier-b-pins.env);
#   2. the user-visible branding is Companion OS, while the identifiers that
#      apt, casper, the installer and Secure Boot depend on are untouched, and the
#      identity files are exactly what the shared writer (backends/ubuntu/lib/os-release.sh)
#      produces for the ISO's own Ubuntu base; the product is named Companion OS everywhere a
#      user reads it (installer source names, text splash title, Hub entry) and no retired
#      spelling (CI OS, Companion Ubuntu, Intelligence Operating System) is left in those files;
#   2b. the Settings > About logo, the dock start icon, the LOGO= icon and the greeter logo
#      are the canon mark: their pixels and paths are checked against the vendored mark and the
#      brand tokens (the About PNGs hold only the mode's primary colour, the greeter only the mark's
#      three tones, the start icon every path of the mark and no brand hex, ci-os-logo.svg is the
#      vendored file), and the stock files are dpkg-diverted so an upgrade cannot restore them;
#   2c. the live GRUB menu is themed: an 8-bit PNG background, menu colours derived from the brand
#      tokens, and only modules the signed GRUB has built in (gfxterm, png; each is looked up in the module list of the
#      /EFI/boot/grubx64.efi on the ISO itself, read with stick/scripts/grub-builtin-modules.py; all_video is NOT built into
#      26.04.1's GRUB, so an insmod of it would be refused under Secure Boot); and, given VERIFY_BASE_ISO, the Secure Boot
#      EFI binaries are byte-identical to the stock ISO's;
#   2d. the Ubuntu display names that were still on screen read Companion OS: the one session in GDM's gear menu
#      (Ubuntu 26.04.1 ships a Wayland session only), the Settings sidebar entry and the three shell extensions; while the
#      identifiers behind them (session file name, Exec=, TryExec=, DesktopNames=, OnlyShowIn=, extension uuids) are untouched
#      and the stock files are dpkg-diverted;
#   2e. the live boot's Plymouth (section 7): the initrd overlay carries the canon-painted bgrt, spinner and text-splash
#      themes and the firmware-logo fallback, only those files, appended after a stock initrd that is byte-identical
#      to the base ISO's (given VERIFY_BASE_ISO); the splash GROUND is canon navy: no section of the bgrt or spinner theme
#      asks for the firmware background (which makes the plugin paint black), in the overlay and in the rootfs, and the two
#      copies agree key by key apart from the fonts; the initrd's default theme is the bgrt one the overlay repaints
#      (needs unmkinitramfs); the installed system's fallback logo is the same file, and every package-owned
#      Plymouth file the build rewrites (the watermark, the bgrt and spinner themes, the text theme's template) is dpkg-diverted
#      (the stock copy of a diverted file may be a symlink: 26.04.1's spinner/watermark.png is one); the initrd's plymouthd.conf
#      selects no other theme than bgrt (the stock one has comments only);
#   4d. the GNOME Shell theme: the Ubuntu session's and the greeter's gresource (theme/Yaru/gnome-shell-theme.gresource) is the
#      branded blob of the checkout, not Ubuntu's stock Yaru file, and the upstream gnome-shell-theme.gresource, which the built-in
#      session modes load, still has the stylesheets the branded blob lacks (gnome-shell-light.css);
#   6b. Ubuntu Pro does not prompt and nothing reports to Canonical: the Pro client's apt news and timers are off in uaclient.conf, its apt
#      hook is diverted aside, the login-text scripts that advertise it are non-executable and kept so by dpkg-statoverride, the timers and
#      services that call Canonical (ua-timer, apt-news, esm-cache, motd-news) and every unit of ubuntu-insights are masked (or that package
#      is gone), no autostart entry of the Pro client or of a telemetry service is active, the telemetry packages are not installed, the
#      telemetry hosts resolve to localhost, and GNOME's error-report and usage-statistics switches default to off. The properties are the
#      audit ci_quiet_audit of backends/ubuntu/lib/quiet-canonical.sh, run on the files extracted from the installed layer;
#   5.  the boot menu names, /.disk/info (the product is spelt Companion OS in it, as the installer's last page shows it: the
#      launcher label, the product name and the subiquity channel chain are asserted from casper's and the installer's own logic);
#   3e. the casper layers stacked on the base keep the rootfs directory modes (/tmp stays 1777);
#   3f. NetworkManager still manages wired devices (no netplan file overrides the
#      global NetworkManager renderer, which would leave every Ethernet NIC unmanaged);
#   3g. the installer base layer is clean: the layer the installer copies to the disk (minimal.squashfs) carries
#      nothing that belongs to the live session only (the casper package and its files, the live dconf overrides,
#      the installer's own snap, the live session's polkit rule and sysctl file, the encryption variant's snapd seed, which is
#      in neither layer: build-iso.sh deletes it from the rootfs before the split), and
#      the live layer (minimal.standard.live.squashfs) is the real live delta, not a placeholder: casper's files, a dpkg
#      status that lists casper, true .size, .manifest and .manifest.full files, while minimal.standard.squashfs stays the empty
#      placeholder and the boot menus' kernel lines are the stock ones (given VERIFY_BASE_ISO, equal to the base ISO's). The
#      installed base is initramfs-tools based (the live layer whites out dracut) and apt is told never to swap it for dracut
#      (/etc/apt/preferences.d/ci-os-no-dracut: dracut and dracut-core at Pin-Priority -1).
#      Why: docs/architecture/ubuntu-iso-layers.md;
#   8. the medium's /md5sum.txt, which the live system's casper-md5check.service verifies on every boot, is correct: every entry matches the
#      file in the image (each file is hashed by streaming it out of the ISO, nothing is extracted), no entry names a file that is
#      gone, and every regular file the stock convention lists (all but /md5sum.txt, /boot.catalog and the BIOS boot image
#      /boot/grub/i386-pc/eltorito.img) is listed. It is rewritten by build-iso.sh (md5sum-txt.sh); the stock file is wrong for every
#      file the remaster changes.
#   9. the image is no larger than the smallest Companion Stick boot slot (8 GiB, a 64 GB stick), which ci-stick flash enforces.
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
#   VERIFY_TIERB=0 ...     skip section 3c (an ISO built with CI_OS_BAKE_THIRD_PARTY=0
#                          CI_OS_BAKE_OLLAMA=0 CI_OS_BAKE_LAUNCHER=0 CI_OS_BAKE_CAPTURE=0)
#   VERIFY_MAX_ISO_BYTES=N the image must be at most N bytes (default 8589934592, the 8 GiB boot slot of a 64 GB Companion
#                          Stick, which ci-stick flash enforces); 0 skips the check
#   VERIFY_REQUIRE_CANON=1 fail if the canon content checks (they need the repo checkout, see below) had to be
#                          skipped; without it they are listed under SKIPPED in the Summary and the status is unchanged
#   VERIFY_BASE_ISO=ISO .. the stock Ubuntu 26.04.1 ISO this one was built from: also assert that
#                          /EFI/boot/{bootx64,grubx64,mmx64}.efi are byte-identical to it
#                          (the Secure Boot chain is intact) and that casper/initrd starts with the
#                          stock initrd, byte for byte, that the md5sum.txt exclusions are the stock ISO's own, that the
#                          kernel lines of grub.cfg and loopback.cfg are the stock ISO's (section 3g), that the ISO volume id
#                          is the stock one, and that install-sources.yaml carries the stock ISO's `kernel:` block;
#                          without it those checks are skipped
#
# Needs: xorriso squashfs-tools zstd cpio python3 (Ubuntu: apt-get install xorriso squashfs-tools zstd cpio python3), and
#        unmkinitramfs (initramfs-tools-core) for the initrd's default-theme check (listed under SKIPPED without it), and
#        md5sum-txt.sh next to this script, which needs awk, dd and md5sum (section 8 is skipped without it);
#        gpg is optional (without it the keyring fingerprints are reported as skipped), and so is a logo
#        renderer (rsvg-convert or ImageMagick): with one, the logo shapes are also compared with a fresh
#        render of the vendored mark. Run it from the repo checkout: the logo content is checked against its
#        vendor/brand.
#        Exit status is non-zero if any check fails.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

ISO="${1:-}"
# The repo this script lives in (backends/ubuntu/iso/scripts is four levels below it): the menu colours are
# re-derived from its brand tokens. A copy of this script outside the repo skips that one check.
VERIFY_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." 2>/dev/null && pwd)"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "usage: $0 path/to/companion-os.iso" >&2; exit 2; }

missing=()
for t in xorriso unsquashfs zstd cpio python3; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "missing tools: ${missing[*]}  (apt-get install xorriso squashfs-tools zstd cpio python3)" >&2
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
# skip: a group of checks that did not run. It is a note where it happens AND a SKIPPED block in the Summary, so a
# copy of this script that is not in the repo cannot print "0 failed" with the canon content checks missing and nobody
# the wiser. VERIFY_REQUIRE_CANON=1 turns such a run into a failure (use it where the checkout is expected to be there).
SKIPPED=()
skip() { SKIPPED+=("$*"); printf 'info  SKIPPED: %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
check() { # check "<label>" <command...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

# ── extract what we need ────────────────────────────────────────────────────
echo "ISO: $ISO ($(du -h "$ISO" | cut -f1))"
ISOX="$WORK/iso"; mkdir -p "$ISOX"
# loopback.cfg in its own run: the arm64 ISO has none, and an -extract of an absent path aborts the rest of its xorriso command line
# (the first arm64 verify stopped with "could not extract /casper/minimal.squashfs" for this reason).
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/loopback.cfg "$ISOX/loopback.cfg" >/dev/null 2>&1
xorriso -osirrox on -indev "$ISO" \
    -extract /boot/grub/grub.cfg "$ISOX/grub.cfg" \
    -extract /.disk/info "$ISOX/disk-info" \
    -extract /casper/initrd "$ISOX/initrd" \
    -extract /casper/install-sources.yaml "$ISOX/install-sources.yaml" \
    -extract /casper/minimal.squashfs "$ISOX/minimal.squashfs" \
    -extract /casper/minimal.standard.squashfs "$ISOX/minimal.standard.squashfs" \
    -extract /casper/minimal.standard.live.squashfs "$ISOX/minimal.standard.live.squashfs" >/dev/null 2>&1
[[ -s "$ISOX/minimal.squashfs" ]] || { echo "could not extract /casper/minimal.squashfs from $ISO" >&2; exit 2; }
# The boot-menu extras, each in its own run: an -extract of a path that is absent (an ISO built before the GRUB
# theming has no ci-os-bg.png) is a FAILURE that aborts the rest of that xorriso command line, and must not hide
# the files after it.
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/ci-os-bg.png "$ISOX/ci-os-bg.png" >/dev/null 2>&1
# The per-layer .size and .manifest files (section 3g), one run each for the same reason.
for f in minimal.size minimal.standard.size minimal.standard.live.size \
         minimal.manifest minimal.standard.manifest minimal.standard.live.manifest \
         minimal.manifest.full minimal.standard.manifest.full minimal.standard.live.manifest.full; do
    xorriso -osirrox on -indev "$ISO" -extract "/casper/$f" "$ISOX/$f" >/dev/null 2>&1
done
# The architecture of the image: VERIFY_ARCH, else read from the volume id ("Ubuntu 26.04.1 LTS amd64" / "... arm64"). It decides the
# firmware file names (bootx64/grubx64/mmx64 or bootaa64/grubaa64/mmaa64), which Ollama files a build must have and whether
# Companion Capture (x86-64 only) is expected.
VARCH="${VERIFY_ARCH:-}"
if [[ -z "$VARCH" ]]; then
    case "$(xorriso -indev "$ISO" -pvd_info 2>&1 | sed -n 's/^Volume Id *: *//p' | head -1)" in
        *arm64) VARCH=arm64 ;;
        *) VARCH=amd64 ;;
    esac
fi
case "$VARCH" in amd64) EFIS=x64 ;; arm64) EFIS=aa64 ;; *) echo "VERIFY_ARCH must be amd64 or arm64 (got '$VARCH')" >&2; exit 2 ;; esac
echo "Architecture: $VARCH (EFI files: boot$EFIS.efi, grub$EFIS.efi, mm$EFIS.efi)"
xorriso -osirrox on -indev "$ISO" \
    -extract "/EFI/boot/boot$EFIS.efi" "$ISOX/bootx64.efi" \
    -extract "/EFI/boot/grub$EFIS.efi" "$ISOX/grubx64.efi" \
    -extract "/EFI/boot/mm$EFIS.efi" "$ISOX/mmx64.efi" >/dev/null 2>&1
PVD_VOLID="$(xorriso -indev "$ISO" -pvd_info 2>&1 | sed -n 's/^Volume Id *: *//p' | head -1)"

SQ="$ISOX/minimal.squashfs"
LISTING="$WORK/listing.txt"
unsquashfs -ll "$SQ" 2>/dev/null | sed 's#squashfs-root##' > "$LISTING"
R="$WORK/root"; mkdir -p "$R"
# Extract the small files we read. Missing ones are fine here; the checks report them.
# -no-xattrs: an unprivileged run cannot write trusted.overlay.* and unsquashfs aborts on the first failure.
unsquashfs -no-xattrs -q -f -d "$R" "$SQ" \
    etc/os-release usr/lib/os-release etc/os-release.ubuntu-base etc/lsb-release etc/issue etc/issue.net etc/hostname \
    etc/casper.conf etc/default/grub var/lib/dpkg/status var/lib/snapd/seed/seed.yaml var/lib/snapd/state.json etc/cloud/cloud.cfg \
    etc/dconf/profile/user etc/dconf/db/local.d etc/dconf/db/local etc/skel etc/legal var/lib/dpkg/statoverride usr/share/applications usr/lib/systemd/user/gnome-initial-setup-upgrade-login.service usr/lib/systemd/user/gnome-initial-setup-first-login.service etc/firefox \
    usr/share/glib-2.0/schemas \
    usr/share/gnome-background-properties \
    etc/update-motd.d etc/systemd/system etc/sudoers.d etc/netplan \
    etc/hosts etc/default/motd-news etc/apt/apt.conf.d etc/ubuntu-advantage etc/systemd/user usr/lib/systemd/system usr/lib/systemd/user \
    var/lib/dpkg/info/ubuntu-insights.list var/lib/dpkg/info/ubuntu-pro-client.list var/lib/dpkg/info/ubuntu-advantage-tools.list \
    var/lib/dpkg/info/ubuntu-advantage-desktop-daemon.list var/lib/dpkg/info/ubuntu-report.list \
    usr/lib/ci-os usr/local/bin/ci-os-info \
    etc/group etc/gshadow etc/passwd var/cache/debconf/config.dat etc/ci-os \
    usr/lib/systemd/system/docker.service usr/lib/systemd/system/docker.socket \
    usr/lib/systemd/system/containerd.service usr/lib/systemd/system/ci-os-docker-group.service \
    usr/lib/systemd/system/ci-os-live-container-storage.service \
    usr/lib/systemd/system/ci-os-first-boot-setup.service usr/lib/systemd/system/ci-os-first-boot-setup.timer \
    etc/apt/sources.list.d etc/apt/preferences.d usr/share/keyrings etc/xdg/autostart usr/libexec/ci-os usr/share/ci-os \
    usr/bin/ollama usr/lib/systemd/system/tailscaled.service var/lib/tailscale usr/share/ollama \
    usr/share/applications/ci-os-hub.desktop \
    usr/share/plymouth/themes/spinner/watermark.png usr/share/plymouth/themes/spinner/bgrt-fallback.png \
    usr/share/plymouth/themes/spinner/spinner.plymouth usr/share/plymouth/themes/bgrt usr/share/plymouth/themes/ubuntu-text \
    etc/alternatives/default.plymouth etc/plymouth \
    usr/share/icons/Yaru/scalable/places usr/share/icons/hicolor/scalable/apps usr/share/icons/hicolor/icon-theme.cache \
    usr/share/pixmaps var/lib/dpkg/diversions etc/dconf/db/gdm.d \
    usr/share/xsessions usr/share/wayland-sessions usr/share/applications/gnome-ubuntu-panel.desktop \
    usr/share/gnome-shell/extensions/ubuntu-dock@ubuntu.com/metadata.json \
    usr/share/gnome-shell/extensions/ubuntu-appindicators@ubuntu.com/metadata.json \
    usr/share/gnome-shell/extensions/tiling-assistant@ubuntu.com/metadata.json \
    usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource usr/share/gnome-shell/gnome-shell-theme.gresource \
    >/dev/null 2>&1 || true

# The live layer is what casper stacks on top of the base in a live session and the installer never installs
# (section 3g). What is live-only is read from it, not from the base: casper.conf is in this layer.
LIVESQ="$ISOX/minimal.standard.live.squashfs"
LIVELIST="$WORK/minimal.standard.live.listing.txt"
LR="$WORK/live-root"; mkdir -p "$LR"
: > "$LIVELIST"
if [[ -s "$LIVESQ" ]]; then
    unsquashfs -ll "$LIVESQ" 2>/dev/null | sed 's#squashfs-root##' > "$LIVELIST"
    unsquashfs -no-xattrs -q -f -d "$LR" "$LIVESQ" etc/casper.conf var/lib/dpkg/status var/lib/snapd/seed/seed.yaml etc/cloud/cloud.cfg >/dev/null 2>&1 || true
fi
# casper.conf belongs to the live session, so the build keeps it out of the base layer. An image built before the
# layers were split still has it there: the checks that read it follow it.
CASPER_CONF="$LR/etc/casper.conf"
[[ -f "$CASPER_CONF" ]] || CASPER_CONF="$R/etc/casper.conf"

in_listing() { grep -q -E "$1" "$LISTING"; }
pkg_ok() { # package installed ("install ok installed" in dpkg status)
    awk -v p="$1" 'BEGIN{RS=""; FS="\n"} $1=="Package: " p {for(i=1;i<=NF;i++) if($i=="Status: install ok installed") {found=1}} END{exit !found}' "$R/var/lib/dpkg/status" 2>/dev/null
}
file_has() { grep -q -E -- "$2" "$1" 2>/dev/null; }
png_width() { od -An -tu1 -j16 -N4 "$1" 2>/dev/null | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}'; }
png_is() { [[ "$(head -c8 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "89504e470d0a1a0a" ]]; }
png_height() { od -An -tu1 -j20 -N4 "$1" 2>/dev/null | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}'; }
png_depth() { od -An -tu1 -j24 -N1 "$1" 2>/dev/null | tr -d ' \n'; } # IHDR bit depth: byte 24 (8-byte signature, 4 length, "IHDR", width, height)
divert_ok() { # <path> is dpkg-diverted (local) to <path>.ubuntu-stock; /var/lib/dpkg/diversions has 3 lines per entry
    awk -v p="$1" 'NR%3==1{o=$0} NR%3==2{d=$0} NR%3==0{if (o==p && d==p".ubuntu-stock") f=1} END{exit !f}' "$R/var/lib/dpkg/diversions" 2>/dev/null
}
# stock_copy_listed <path>: the diverted original is in the image, at <path>.ubuntu-stock. It is a regular file for nearly everything this build diverts,
# but a SYMLINK for Ubuntu 26.04.1's spinner/watermark.png (-> ../../../pixmaps/ubuntu-logo-text-dark.png): dpkg-divert --rename moves the link itself, and
# `unsquashfs -ll` ends the line of a link in " -> target", so a match anchored at the end of the line never saw it (the first verify of a real 26.04.1
# image failed on exactly this; every fixture had regular files). The optional " -> target" is the whole difference.
stock_copy_listed() { in_listing " ${1//./\\.}\\.ubuntu-stock( -> .*)?\$"; }
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

section "3. Services: enabled / on demand, guarded where they must not run live"
# The guard is ConditionPathExists=!/cdrom/casper/vmlinuz, not boot=casper: casper does not put boot=casper on
# the command line of the plain ISO, but the live medium is always mounted at /cdrom (also on a Companion Stick).
# Boot-enabled: the backend (loopback only) and the monitor that decides whether the portal is needed. ON DEMAND (not
# enabled): hostapd-setup, dnsmasq-setup and nginx, which setup-device-hotspot-start.sh starts by name when the monitor
# sees no connectivity: enabling them ran an access point at every boot and crash-looped on any machine whose Wi-Fi is
# not named wlp192s0 (found by the installed-boot test, 2026-10-17).
for u in setup-backend.service setup-network-monitor.service; do
    if unit_enabled "$u"; then pass "enabled for the installed system: $u"; else fail "NOT enabled: $u"; fi
done
for u in hostapd-setup.service dnsmasq-setup.service nginx.service; do
    if unit_enabled "$u"; then fail "boot-enabled (must be on demand: started by setup-device-hotspot-start.sh): $u"; else pass "on demand, not enabled at boot: $u"; fi
done
for u in hostapd-setup.service dnsmasq-setup.service setup-backend.service setup-network-monitor.service; do
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

section "3b. Docker works in every boot mode (installed, plain-ISO live, Companion Stick live)"
for u in docker.service containerd.service; do
    unit_enabled "$u" && pass "enabled: $u" || fail "NOT enabled: $u"
done
in_listing 'etc/systemd/system/sockets\.target\.wants/docker\.socket -> ' \
    && pass "enabled: docker.socket" || fail "NOT enabled: docker.socket"
# Docker must NOT be guarded against live sessions (decision: Docker runs in the Stick live boot and the plain ISO).
for u in docker.service docker.socket containerd.service; do
    if grep -rqsE '/cdrom/casper|boot=casper' "$R/etc/systemd/system/$u.d" "$R/usr/lib/systemd/system/$u" 2>/dev/null; then
        fail "live-session guard found on $u (Docker must run in a live boot)"
    else
        pass "no live-session guard on $u"
    fi
done
for u in docker containerd; do
    f="$R/etc/systemd/system/$u.service.d/20-ci-os-live.conf"
    if file_has "$f" '^Requires=ci-os-live-container-storage\.service$' && file_has "$f" '^After=ci-os-live-container-storage\.service$'; then
        pass "$u waits for the live storage unit"
    else fail "$u has no 20-ci-os-live.conf ordering on the live storage unit"; fi
done
S="$R/usr/lib/systemd/system/ci-os-live-container-storage.service"
file_has "$S" '^ConditionPathExists=/cdrom/casper/vmlinuz$' && pass "live storage unit runs only in live sessions" || fail "live storage unit is not live-only"
file_has "$S" '^Before=.*docker\.service' && pass "live storage unit runs before docker.service" || fail "live storage unit not ordered before docker.service"
[[ -x "$R/usr/lib/ci-os/ci-os-live-container-storage" ]] && pass "live storage script present and executable" || fail "live storage script missing"
G="$R/usr/lib/systemd/system/ci-os-docker-group.service"
file_has "$G" '^ConditionPathExists=!/cdrom/casper/vmlinuz$' && pass "docker-group unit is installed-system only" || fail "docker-group unit missing its not-live condition"
unit_enabled ci-os-docker-group.service && pass "enabled: ci-os-docker-group.service" || fail "NOT enabled: ci-os-docker-group.service"
[[ -x "$R/usr/lib/ci-os/ci-os-docker-group" ]] && pass "docker-group script present and executable" || fail "docker-group script missing"
# Group and the live user's group list.
grep -qE '^docker:x:[0-9]+:' "$R/etc/group" && pass "group docker exists in the image" || fail "group docker missing from /etc/group"
if awk 'BEGIN{RS=""} /Name: passwd\/user-default-groups/' "$R/var/cache/debconf/config.dat" 2>/dev/null | grep -Eq '^Value: .*(^| )docker( |$)'; then
    pass "debconf passwd/user-default-groups contains docker (casper live user gets it)"
else fail "debconf passwd/user-default-groups lacks docker (live user would not be in docker)"; fi
# user-setup-apply skips creating the live user if any 1000-59999 account exists in the image.
if awk -F: '$3>=1000 && $3<=59999 {f=1} END{exit !f}' "$R/etc/passwd"; then
    fail "image has a UID 1000-59999 account: casper will NOT create the live user"
else pass "no UID 1000-59999 account in the image (casper creates the live user)"; fi
# casper has no USERGROUPS; do not cargo-cult it.
check "casper.conf does not pretend to set USERGROUPS (casper ignores it)" bash -c "! grep -q USERGROUPS '$CASPER_CONF'"
check "docker.io is not installed (conflicts with docker-ce)" bash -c "! awk 'BEGIN{RS=\"\"} \$1==\"Package: docker.io\"' '$R/var/lib/dpkg/status' | grep -q 'install ok installed'"

# 1d. One-click automatic install (customize-chroot.sh Step 10f; docs/architecture/one-click-install.md).
section "One-click automatic install"
AI="$R/usr/libexec/ci-os/ci-os-auto-install"
[[ -x "$AI" ]] && pass "ci-os-auto-install is present and executable" || fail "ci-os-auto-install is missing or not executable"
head -n 1 "$AI" 2>/dev/null | grep -qx '#!/usr/bin/env python3' && pass "ci-os-auto-install runs under python3" || fail "ci-os-auto-install has no python3 shebang"
file_has "$R/usr/share/ci-os/live/ci-os-auto-install.desktop" '^Exec=/usr/libexec/ci-os/ci-os-auto-install$' \
    && pass "launcher .desktop runs the helper" || fail "launcher .desktop missing or runs something else"
file_has "$R/usr/share/ci-os/live/ci-os-auto-install.desktop" '^Name=Install Companion OS \(automatic\)$' \
    && pass "launcher is named \"Install Companion OS (automatic)\"" || fail "launcher has the wrong name"
file_has "$R/etc/xdg/autostart/ci-os-live-setup.desktop" '^Exec=/usr/libexec/ci-os/ci-os-auto-install --live-setup$' \
    && pass "autostart hook places the launcher in live sessions" || fail "autostart hook missing"
for f in zenity curl openssl lsblk findmnt; do
    in_listing "(usr/)?s?bin/$f( |\$)" && pass "image ships $f (the helper needs it)" || fail "image lacks $f"
done
in_listing 'usr/lib/python3/dist-packages/yaml/__init__\.py' && pass "image ships python3-yaml" || fail "image lacks python3-yaml"
# The safety rules are properties of the script text; the behaviour is the unit tests, run against THIS copy.
check "helper never shells out with shell=True" bash -c "! grep -q 'shell=True' '$AI'"
check "helper never partitions or formats a disk itself" bash -c "! grep -qE '\b(mkfs|wipefs|sgdisk|parted)\b|\bdd +if=' '$AI'"
if [[ -f "$VERIFY_REPO/backends/ubuntu/chroot/tests/test_auto_install.py" ]] && python3 -c 'import yaml' 2>/dev/null; then
    if CI_OS_AI_HELPER="$AI" python3 "$VERIFY_REPO/backends/ubuntu/chroot/tests/test_auto_install.py" >"$WORK/auto-install-tests.log" 2>&1; then
        pass "disk-selection unit tests pass against the image's helper ($(grep -E '^Ran ' "$WORK/auto-install-tests.log"))"
    else
        fail "disk-selection unit tests FAIL against the image's helper (see $WORK/auto-install-tests.log)"; tail -n 15 "$WORK/auto-install-tests.log"
    fi
else
    skip "disk-selection unit tests (need the repo checkout and python3-yaml)"
fi
# The boot menu's extra entry: one, a copy of the first entry, carrying ci.autoinstall=1, nothing else changed.
check "GRUB menu has exactly one 'Install Companion OS (automatic)' entry" bash -c "[[ \$(grep -c '^menuentry \"Install Companion OS (automatic)\"' '$ISOX/grub.cfg') == 1 ]]"
check "only that entry's kernel line carries ci.autoinstall=1" bash -c "[[ \$(grep -c 'ci\\.autoinstall=1' '$ISOX/grub.cfg') == 1 ]] && awk '/^menuentry \"Install Companion OS \(automatic\)\"/{f=1} f&&/ci\\.autoinstall=1/{ok=1} /^}/{f=0} END{exit !ok}' '$ISOX/grub.cfg'"
check "no entry boots the installer unattended (no 'autoinstall' word without the ci. prefix)" bash -c "! grep -E '^[[:space:]]*linux' '$ISOX/grub.cfg' | grep -qE '(^|[[:space:]])autoinstall([[:space:]]|=|\$)'"

section "3c. Optional tools (Tier B): tailscale, cloudflared, gh, Ollama, Companion Launcher, Companion Capture"
if [[ "${VERIFY_TIERB:-1}" == 0 ]]; then
    note "skipped (VERIFY_TIERB=0)"
else
    PINS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../core/manifest/tier-b-pins.env"
    # shellcheck source=../../../../core/manifest/tier-b-pins.env
    if [[ -f "$PINS" ]]; then source "$PINS"; else fail "pins file not found: $PINS"; fi
    # The pins of an arm64 image carry the suffix _ARM64 (core/manifest/tier-b-pins.env).
    PIN_SUF=""; [[ "$VARCH" == arm64 ]] && PIN_SUF="_ARM64"
    pin_of() { local n="${1}${PIN_SUF}"; printf '%s' "${!n:-}"; }
    PIN_OLLAMA_SHA256="$(pin_of OLLAMA_SHA256)"
    PIN_CAPTURE_URL="$(pin_of CAPTURE_URL)"
    BAKED="$R/usr/lib/ci-os/baked-hub-tools.txt"
    baked_has() { grep -q -E -- "$1" "$BAKED" 2>/dev/null; }
    guarded() { file_has "$R/etc/systemd/system/$1.d/10-not-live.conf" '^ConditionPathExists=!/cdrom/casper/vmlinuz'; }

    # 8.1 what was baked is recorded, and the knobs were all on
    for k in bake-third-party bake-ollama bake-launcher bake-capture; do
        want=1
        [[ "$k" == bake-capture && -z "$PIN_CAPTURE_URL" ]] && want=0   # no Companion Capture build for this architecture
        if baked_has "^${k}=${want}\$"; then pass "baked-hub-tools.txt: ${k}=${want}"; else fail "baked-hub-tools.txt does not say ${k}=${want} (rebuild, or run with VERIFY_TIERB=0)"; fi
    done

    # 8.2 apt-installed third-party tools: package, binary, source list with Signed-By, keyring on disk
    for p in tailscale cloudflared gh; do
        if pkg_ok "$p"; then pass "package installed: $p"; else fail "package NOT installed: $p"; fi
        if baked_has "^${p}=[0-9]"; then pass "version recorded: $(grep -E "^${p}=" "$BAKED" | head -1)"; else fail "no version recorded for $p"; fi
    done
    for f in /usr/sbin/tailscaled /usr/bin/tailscale /usr/bin/cloudflared /usr/bin/gh; do
        if in_listing " ${f}( ->|\$)"; then pass "present: $f"; else fail "MISSING: $f"; fi
    done
    # list file -> keyring it must point at (the vendors' own names, so their instructions rewrite the same files)
    while IFS='|' read -r list ring url; do
        lf="$R/etc/apt/sources.list.d/$list"
        ring_re="${ring//./\\.}"; url_re="${url//./\\.}"
        if file_has "$lf" "^deb \\[[^]]*signed-by=${ring_re}(\\]| ).*${url_re}"; then
            pass "apt source $list is signed-by ${ring}"
        else
            fail "apt source $list missing or without the expected Signed-By (${ring})"
        fi
        if in_listing " ${ring//./\\.}( ->|\$)"; then pass "keyring present: $ring"; else fail "keyring MISSING: $ring"; fi
    done <<'EOF_LISTS'
tailscale.list|/usr/share/keyrings/tailscale-archive-keyring.gpg|pkgs.tailscale.com/stable/ubuntu
cloudflared.list|/usr/share/keyrings/cloudflare-main.gpg|pkg.cloudflare.com/cloudflared
github-cli.list|/usr/share/keyrings/githubcli-archive-keyring.gpg|cli.github.com/packages
EOF_LISTS
    # no unsigned / trusted=yes / legacy apt-key source slipped in
    if grep -r -l -E 'trusted=yes|allow-insecure' "$R/etc/apt/sources.list.d" 2>/dev/null | grep -q .; then fail "an apt source uses trusted=yes/allow-insecure"; else pass "no apt source disables signature checks"; fi
    # the keyring fingerprints equal the pins (host gpg, throwaway home; skipped without gpg)
    if command -v gpg >/dev/null 2>&1; then
        GPG_TMP="$WORK/gnupg"; mkdir -p "$GPG_TMP"; chmod 700 "$GPG_TMP"
        prim() { GNUPGHOME="$GPG_TMP" gpg --batch --no-tty --show-keys --with-colons "$1" 2>/dev/null |
                 awk -F: '$1=="pub"{w=1; next} $1=="sub"||$1=="sec"||$1=="ssb"{w=0} $1=="fpr"&&w{print $10; w=0}'; }
        for pair in "usr/share/keyrings/tailscale-archive-keyring.gpg:${TAILSCALE_KEY_FPR:-}" \
                    "usr/share/keyrings/cloudflare-main.gpg:${CLOUDFLARED_KEY_FPR:-}" \
                    "usr/share/keyrings/githubcli-archive-keyring.gpg:${GH_KEY_FPR:-}"; do
            kf="${pair%%:*}"; want="${pair##*:}"; got="$(prim "$R/$kf")"
            if [[ -n "$want" && "$got" == "$want" ]]; then pass "keyring ${kf##*/} holds exactly the pinned key ($want)"; else fail "keyring ${kf##*/}: expected only $want, found: ${got:-nothing}"; fi
        done
    else
        note "gpg not installed: keyring fingerprints not checked"
    fi

    # 8.3 services: tailscaled enabled + guarded; cloudflared and gh ship no unit
    if unit_enabled tailscaled.service; then pass "enabled for the installed system: tailscaled.service"; else fail "tailscaled.service NOT enabled"; fi
    if guarded tailscaled.service; then pass "never starts in a live session (casper): tailscaled.service"; else fail "tailscaled.service has no live-session guard"; fi
    if in_listing 'wants/cloudflared[^ ]*\.service -> ' || in_listing 'system/cloudflared[^ ]*\.service( ->|$)'; then
        fail "a cloudflared systemd unit exists; it needs a live-session guard and a decision"
    else
        pass "cloudflared installs no systemd unit (nothing to start)"
    fi
    if in_listing ' /var/lib/tailscale/tailscaled\.state$'; then fail "tailscaled ran during the build (state file in the image)"; else pass "no tailscaled state in the image"; fi

    # 8.4 Ollama: binary, libs, user, unit (enabled + guarded), no models, binary checksum equals the recorded one
    # The Vulkan runner is in the x86-64 tarball only (the arm64 one has CPU, CUDA and Jetson runners).
    OLLAMA_FILES=(/usr/bin/ollama /usr/lib/ollama/libggml-base.so.0 /etc/systemd/system/ollama.service /usr/libexec/ci-os/ollama-models-env)
    [[ "$VARCH" == amd64 ]] && OLLAMA_FILES+=(/usr/lib/ollama/vulkan/libggml-vulkan.so)
    for f in "${OLLAMA_FILES[@]}"; do
        if in_listing " ${f}( ->|\$)"; then pass "present: $f"; else fail "MISSING: $f"; fi
    done
    if file_has "$R/etc/passwd" '^ollama:x:[0-9]{2,3}:[0-9]+:[^:]*:/usr/share/ollama:/bin/false$'; then pass "system user 'ollama' (uid < 1000, home /usr/share/ollama, no login)"; else fail "no suitable 'ollama' system user"; fi
    check "group 'ollama' exists" file_has "$R/etc/group" '^ollama:'
    if unit_enabled ollama.service; then pass "enabled for the installed system: ollama.service"; else fail "ollama.service NOT enabled"; fi
    if guarded ollama.service; then pass "never starts in a live session (casper): ollama.service"; else fail "ollama.service has no live-session guard"; fi
    check "ollama.service uses the models-dir selector (safe when CI-CACHE is absent)" file_has "$R/etc/systemd/system/ollama.service" '^ExecStartPre=-\+/usr/libexec/ci-os/ollama-models-env$'
    check "ollama.service reads the selector's optional env file" file_has "$R/etc/systemd/system/ollama.service" '^EnvironmentFile=-/run/ollama/ci-models\.env$'
    if in_listing ' /usr/share/ollama/\.ollama(/| ->|$)'; then fail "model data is baked into the image"; else pass "no models in the image (they live on CI-CACHE or are pulled at first boot)"; fi
    if [[ -f "$R/usr/bin/ollama" ]]; then
        rec="$(sed -n 's/^ollama-bin-sha256=//p' "$BAKED" | head -1)"; act="$(sha256sum "$R/usr/bin/ollama" | cut -d' ' -f1)"
        if [[ -n "$rec" && "$rec" == "$act" ]]; then pass "usr/bin/ollama sha256 equals the one recorded at build time"; else fail "usr/bin/ollama sha256 ($act) differs from the recorded one (${rec:-none})"; fi
        if [[ "$(head -c4 "$R/usr/bin/ollama" | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]]; then pass "usr/bin/ollama is an ELF binary"; else fail "usr/bin/ollama is not an ELF binary"; fi
    else
        fail "usr/bin/ollama could not be extracted"
    fi
    if baked_has "^ollama=${OLLAMA_VERSION:-x}\$" && baked_has "^ollama-tarball-sha256=${PIN_OLLAMA_SHA256:-x}\$"; then pass "baked Ollama is the pinned release (${OLLAMA_VERSION:-?})"; else fail "baked Ollama version/tarball hash differs from core/manifest/tier-b-pins.env"; fi

    # 8.5 Companion Launcher: right package and binary name (drift: ci-os-hub-desktop is the CRATE name, not the binary)
    if pkg_ok "${LAUNCHER_PACKAGE:-companion-hub}"; then pass "package installed: ${LAUNCHER_PACKAGE:-companion-hub}"; else fail "package NOT installed: ${LAUNCHER_PACKAGE:-companion-hub}"; fi
    for f in /usr/bin/companion-hub /usr/bin/cihub; do
        if in_listing " ${f}( ->|\$)"; then pass "present: $f"; else fail "MISSING: $f"; fi
    done
    if in_listing ' /usr/bin/ci-os-hub-desktop( ->|$)'; then fail "unexpected /usr/bin/ci-os-hub-desktop: the Launcher binary is companion-hub; fix the references"; else pass "no stale ci-os-hub-desktop binary"; fi
    if baked_has "^${LAUNCHER_PACKAGE:-companion-hub}=${LAUNCHER_VERSION:-x}\$"; then pass "baked Launcher is the pinned release (${LAUNCHER_VERSION:-?})"; else fail "baked Launcher version differs from the pin"; fi
    if in_listing ' /etc/xdg/autostart/companion-launcher\.desktop$'; then
        check "Launcher autostart goes through the live-session guard wrapper" file_has "$R/etc/xdg/autostart/companion-launcher.desktop" '^Exec=/usr/libexec/ci-os/launcher-autostart$'
    else
        note "Launcher autostart not baked (CI_OS_LAUNCHER_AUTOSTART=0, the default)"
    fi

    # 8.5b Companion Capture: the pinned .deb, its binary and dock entry; and nothing that starts it. It records the screen,
    # so the image must not run it for the user (no autostart, no service).
    if [[ -n "$PIN_CAPTURE_URL" ]]; then
        if pkg_ok "${CAPTURE_PACKAGE:-companion-capture}"; then pass "package installed: ${CAPTURE_PACKAGE:-companion-capture}"; else fail "package NOT installed: ${CAPTURE_PACKAGE:-companion-capture}"; fi
        for f in "/usr/bin/${CAPTURE_BINARY:-companion-capture}" /usr/share/applications/companion-capture.desktop; do
            if in_listing " ${f}( ->|\$)"; then pass "present: $f"; else fail "MISSING: $f"; fi
        done
        if baked_has "^${CAPTURE_PACKAGE:-companion-capture}=${CAPTURE_VERSION:-x}\$"; then pass "baked Capture is the pinned release (${CAPTURE_VERSION:-?})"; else fail "baked Capture version differs from the pin"; fi
    else
        note "Companion Capture has no $VARCH build: not expected in this image (the checks below, that nothing starts it, still run)"
        if pkg_ok "${CAPTURE_PACKAGE:-companion-capture}"; then fail "package installed although Capture has no $VARCH build: ${CAPTURE_PACKAGE:-companion-capture}"; else pass "Capture is not installed (no $VARCH build exists)"; fi
    fi
    if in_listing ' /etc/xdg/autostart/companion-capture\.desktop$'; then fail "Capture has an XDG autostart entry: it must not start by itself"; else pass "no Capture autostart entry"; fi
    if in_listing ' /(usr/lib|etc)/systemd/system/companion-capture[^ ]*\.service( ->|$)'; then fail "a companion-capture systemd unit is present: Capture must not run as a service"; else pass "no Capture systemd unit"; fi

    # 8.6 size report (informational)
    note "root squashfs: $(du -h "$SQ" | cut -f1)"
fi

section "3d. Installed system: one layer, so the package database stays ours"
# Stock language layers carry a stock var/lib/dpkg/status and gschemas.compiled; subiquity stacks
# <base>.<lang>.squashfs on top whenever install-sources.yaml lists preinstalled_langs, which would give an
# installed system all our files but a dpkg database without docker-ce, setup-device, tailscale, ...
# Ubuntu 26.04.1's install-sources.yaml is a version 2 MAPPING (kernel:, sources:, version: 2), not the bare list of earlier releases.
# Read as a list, subiquity assumes the kernel meta-package "linux-generic", which is installed neither in the base layer nor in the
# ISO's pool (subiquity/models/source.py): the kernel step would need the network and may remove the preinstalled kernel.
if [[ -s "$ISOX/install-sources.yaml" ]]; then
    check "install-sources.yaml lists no preinstalled_langs (installer uses minimal.squashfs alone)" \
        bash -c "grep -c '^  preinstalled_langs: \[\]\$' '$ISOX/install-sources.yaml' | grep -qx 2"
    check "install-sources.yaml keeps both entries (ubuntu-desktop-minimal, ubuntu-desktop)" \
        bash -c "grep -q '^  id: ubuntu-desktop-minimal\$' '$ISOX/install-sources.yaml' && grep -q '^  id: ubuntu-desktop\$' '$ISOX/install-sources.yaml'"
    check "install-sources.yaml is the version 2 mapping (kernel:, sources:, version: 2), not a bare list" \
        bash -c "grep -q '^kernel:\$' '$ISOX/install-sources.yaml' && grep -q '^sources:\$' '$ISOX/install-sources.yaml' && grep -q '^version: 2\$' '$ISOX/install-sources.yaml' && ! head -n 1 '$ISOX/install-sources.yaml' | grep -q '^- '"
    kernel_block() { awk '/^kernel:[[:space:]]*$/ { f = 1; print; next } f && /^[[:space:]]/ { print; next } f { exit }' "$1"; }
    ISRC_KERNEL="$(kernel_block "$ISOX/install-sources.yaml" | sed -n 's/^  default:[[:space:]]*//p' | head -n 1 | tr -d '\r"'"'"' ')"
    if [[ -n "$ISRC_KERNEL" && "$ISRC_KERNEL" =~ ^[a-z0-9][a-z0-9.+-]*$ ]]; then
        pass "install-sources.yaml names the kernel meta-package $ISRC_KERNEL"
        # curtin installs that package: if the base layer already has it, nothing new is installed and no kernel is removed.
        if pkg_ok "$ISRC_KERNEL"; then pass "the kernel meta-package $ISRC_KERNEL is installed in the base layer (curtin finds no new kernel to install and removes none)"
        else fail "the kernel meta-package $ISRC_KERNEL that install-sources.yaml names is not installed in the base layer (the installer would need the network for it)"; fi
    else
        fail "install-sources.yaml has no kernel: block with a default: meta-package"
    fi
    if [[ -n "${VERIFY_BASE_ISO:-}" && -f "$VERIFY_BASE_ISO" ]]; then
        xorriso -osirrox on -indev "$VERIFY_BASE_ISO" -extract /casper/install-sources.yaml "$WORK/base-install-sources.yaml" >/dev/null 2>&1
        if [[ -s "$WORK/base-install-sources.yaml" ]]; then
            if [[ -n "$(kernel_block "$WORK/base-install-sources.yaml")" && "$(kernel_block "$WORK/base-install-sources.yaml")" == "$(kernel_block "$ISOX/install-sources.yaml")" ]]; then
                pass "install-sources.yaml carries the stock ISO's kernel: block, verbatim"
            else
                fail "install-sources.yaml's kernel: block differs from the base ISO's (copy it, do not retype it)"
            fi
        else
            fail "could not read /casper/install-sources.yaml from VERIFY_BASE_ISO"
        fi
    fi
else
    fail "could not read /casper/install-sources.yaml"
fi
# Every layer install-sources.yaml names must exist on the ISO, or the installer crashes when it examines the
# variations ("Failed to use fsimage ... doesn't exist or is invalid").
CASPER_LS="$(xorriso -indev "$ISO" -ls /casper/ 2>/dev/null | tr -d "'" | tr ' ' '\n')"
if [[ -s "$ISOX/install-sources.yaml" ]]; then
    missing_layers=""
    while read -r lp; do
        grep -qxF "$lp" <<<"$CASPER_LS" || missing_layers="$missing_layers $lp"
    done < <(sed -n 's/^ *path: *//p' "$ISOX/install-sources.yaml" | sort -u)
    if [[ -z "$missing_layers" ]]; then
        pass "every layer named in install-sources.yaml exists on the ISO"
    else
        fail "install-sources.yaml names layers that are not on the ISO (the installer will crash):$missing_layers"
    fi
    if grep -q 'enhanced-secureboot' "$ISOX/install-sources.yaml"; then
        fail "install-sources.yaml still lists enhanced-secureboot variations (no such layers are shipped)"
    else
        pass "install-sources.yaml lists no enhanced-secureboot variations"
    fi
fi
LANGLAYERS="$(grep -E '^minimal(\.standard)?(\.enhanced-secureboot)?\.(de|en|es|fr|it|pt|ru|zh|no-languages)\.' <<<"$CASPER_LS" || true)"
if [[ -z "$LANGLAYERS" ]]; then pass "no stock language layers on the ISO"; else fail "stock language layers still on the ISO: $(printf '%s' "$LANGLAYERS" | tr '\n' ' ' | cut -c1-600)"; fi
ESBFILES="$(grep -E 'enhanced-secureboot' <<<"$CASPER_LS" || true)"
if [[ -z "$ESBFILES" ]]; then pass "no enhanced-secureboot layer, size or manifest file on the ISO (this image ships no TPM full-disk-encryption variant)"
else fail "enhanced-secureboot files still in /casper: $(printf '%s' "$ESBFILES" | tr '\n' ' ' | cut -c1-600)"; fi
# Nothing of the stock layer family but the three layers this image has: their .squashfs, .size, .manifest and .manifest.full, and no
# other minimal* file (a stale stock .manifest.full or .size would describe a layer that is not there).
CASPER_WANT="minimal.manifest minimal.manifest.full minimal.size minimal.squashfs minimal.standard.live.manifest minimal.standard.live.manifest.full minimal.standard.live.size minimal.standard.live.squashfs minimal.standard.manifest minimal.standard.manifest.full minimal.standard.size minimal.standard.squashfs"
CASPER_HAVE="$(grep -E '^minimal' <<<"$CASPER_LS" | LC_ALL=C sort | paste -sd' ' -)"
if [[ "$CASPER_HAVE" == "$CASPER_WANT" ]]; then pass "/casper holds exactly the three layers' .squashfs, .size, .manifest and .manifest.full files and no other minimal* file"
else fail "/casper's minimal* files are not the three layers' twelve: extra [$(LC_ALL=C comm -13 <(tr ' ' '\n' <<<"$CASPER_WANT") <(tr ' ' '\n' <<<"$CASPER_HAVE") | tr '\n' ' ' | cut -c1-300)] missing [$(LC_ALL=C comm -23 <(tr ' ' '\n' <<<"$CASPER_WANT") <(tr ' ' '\n' <<<"$CASPER_HAVE") | tr '\n' ' ' | cut -c1-300)]"; fi

section "3e. Casper overlay layers must not change directory modes"
# casper stacks minimal.squashfs, minimal.standard.squashfs and minimal.standard.live.squashfs with overlayfs, and a
# directory that exists in several layers takes its mode from the TOPMOST one. The upper layers are the empty placeholder
# (standard) and the live-only delta (live); made with a plain mkdir, or packed from a scratch directory whose own
# mode is not the rootfs's, they turn /tmp (or the root) into drwxr-xr-x for the whole live session, and then the
# installer and the desktop launcher (shown as untrusted) cannot write their temp files. So every directory in an
# upper layer must carry the same mode as the same path in the root layer, and /tmp must be sticky and world-writable in
# the root layer and in every layer that has one (the placeholder always does; the live delta only if something under it
# changed, and a layer without /tmp does not override it).
LL_PREFIX='^[^ ]+ +[^ ]+ +[0-9]+ +[0-9-]+ +[0-9:]+ ?' # "mode owner/group size date time " in front of the path
dir_mode() { # dir_mode <listing> <path>: mode of that directory in an `unsquashfs -ll` listing; "" = the layer root
    awk -v want="$2" -v pre="$LL_PREFIX" '$1 ~ /^d/ { p = $0; sub(pre, "", p); if (p == want) { print $1; exit } }' "$1"
}
tmp_root="$(dir_mode "$LISTING" /tmp)"
if [[ "$tmp_root" == drwxrwxrwt ]]; then pass "root layer: /tmp is drwxrwxrwt"; else fail "root layer: /tmp is ${tmp_root:-missing}, must be drwxrwxrwt"; fi
for layer in minimal.standard minimal.standard.live; do
    LSQ="$ISOX/$layer.squashfs"
    if [[ ! -s "$LSQ" ]]; then fail "could not extract /casper/$layer.squashfs"; continue; fi
    LAYERLIST="$WORK/$layer.listing.txt"
    # The live layer's listing was made when the files were extracted (it is a big layer since the layers were split).
    [[ -s "$LAYERLIST" ]] || unsquashfs -ll "$LSQ" 2>/dev/null | sed 's#squashfs-root##' > "$LAYERLIST"
    ndirs=0; nbad=0
    while IFS=$'\t' read -r mode path; do
        ndirs=$((ndirs + 1))
        base="$(dir_mode "$LISTING" "$path")"
        # A directory the root layer does not have cannot change one of its modes.
        [[ -n "$base" ]] || continue
        if [[ "$mode" != "$base" ]]; then
            nbad=$((nbad + 1))
            fail "layer $layer: ${path:-/ (layer root)} is $mode but the root layer has $base"
        fi
    done < <(awk -v pre="$LL_PREFIX" '$1 ~ /^d/ { p = $0; sub(pre, "", p); print $1 "\t" p }' "$LAYERLIST")
    if [[ "$ndirs" -eq 0 ]]; then
        fail "layer $layer: no directories found in its listing (unreadable squashfs?)"
    elif [[ "$nbad" -eq 0 ]]; then
        pass "layer $layer: all $ndirs directories have the same mode as in the root layer"
    fi
    tmp_layer="$(dir_mode "$LAYERLIST" /tmp)"
    if [[ "$tmp_layer" == drwxrwxrwt ]]; then pass "layer $layer: /tmp is drwxrwxrwt"
    elif [[ -z "$tmp_layer" && "$layer" == minimal.standard.live ]]; then
        # The live layer is a delta, not a placeholder: it has /tmp only if something under it changed. A layer without
        # the directory does not override it, and the layers below (checked above and for the placeholder) are drwxrwxrwt.
        pass "layer $layer: has no /tmp, so the layers below provide it (drwxrwxrwt)"
    else fail "layer $layer: /tmp is ${tmp_layer:-missing}, must be drwxrwxrwt"; fi
done

section "3f. NetworkManager still manages wired devices"
# netplan writes NetworkManager's 10-globally-managed-devices.conf only while the effective GLOBAL renderer is
# NetworkManager. A top-level "renderer: networkd" in any etc/netplan file (the setup-mode profile used to have
# one) overrides Ubuntu's 01-network-manager-all.yaml and leaves every Ethernet NIC unmanaged: no wired icon in
# the top bar, no connection. Global keys sit at two-space indent; a per-device renderer is deeper and is fine.
check "no etc/netplan file sets a global renderer other than NetworkManager" \
    bash -c "! grep -hE '^  renderer:' '$R'/etc/netplan/*.yaml | grep -qvE 'NetworkManager'"
check "01-network-manager-all.yaml still has renderer: NetworkManager" \
    file_has "$R/etc/netplan/01-network-manager-all.yaml" '^  renderer:[[:space:]]*NetworkManager[[:space:]]*$'

section "3g. Installer base layer is clean: nothing live-only reaches the installed system"
# subiquity installs the layer install-sources.yaml names (minimal.squashfs) and nothing else; casper stacks all the
# layers only in a live session. The stock ISO keeps everything that belongs to the live session alone in a separate
# layer, minimal.standard.live.squashfs. A base layer that carries it copies it to the installed disk: the casper
# package with its initramfs hook (every initrd the installer then regenerates boots the live medium, "Unable to find a
# medium containing a live file system"), the live session's dconf overrides, the installer's own snap. build-iso.sh
# therefore splits the merged rootfs into that base and a live-only delta (docs/architecture/ubuntu-iso-layers.md); the
# checks below keep the split honest, and tests/verify-installer-base.sh shows each of them failing on a broken image.
#
# The rows of BASE_FORBIDDEN are "label|extended regular expression", matched against the whole path of every entry of an
# `unsquashfs -ll` listing (a symlink's " -> target" removed).
# Paths that look live-only but belong to a package the base keeps are NOT rows. The one that was: /usr/share/finalrd, a directory
# that mdadm (kept: the disk tools stay) fills with /usr/share/finalrd/mdadm.finalrd, a hook that is inert without finalrd. A row
# for it failed on the first image built with the split (2026-10-17), which no synthetic fixture had shown. The same table, with the reason for each row, is in
# docs/architecture/ubuntu-iso-layers.md: change them together.
BASE_FORBIDDEN=(
    "/etc/casper.conf|^/etc/casper\\.conf\$"
    "casper initramfs configuration (casperize.conf, default-layer.conf)|^/etc/initramfs-tools/conf\\.d/(casperize|default-layer)\\.conf\$"
    "casper initramfs scripts and hook (the hook is what makes every initrd boot casper)|^/usr/share/initramfs-tools/(scripts|hooks)/casper"
    "casper programs, data and documentation|^/usr/(lib|share)/casper(/|\$)|^/usr/share/doc/casper(/|\$)|^/usr/sbin/casper-|^/sbin/casper-"
    "casper dpkg file lists and helper state|^/var/lib/dpkg/info/casper\\.|^/var/lib/systemd/deb-systemd-helper-enabled/.*casper"
    "casper systemd units and their enable links|^/usr/lib/systemd/system/casper[^/]*\\.service\$|^/etc/systemd/system/.*casper[^/]*\\.service\$"
    "finalrd (casper's shutdown helper) files, unit and enable links|^/usr/lib/finalrd(/|\$)|^/usr/bin/finalrd\$|^/usr/share/doc/finalrd(/|\$)|^/usr/share/man/man1/finalrd\\.|^/usr/lib/systemd/system/finalrd\\.service\$|^/etc/systemd/system/.*finalrd\\.service\$|^/var/lib/dpkg/info/finalrd\\."
    "live-session dconf overrides (livecd-rootfs.gschema.override)|^/usr/share/glib-2\\.0/schemas/livecd-rootfs\\.gschema\\.override\$"
    "installer snap files, snapd state, AppArmor and seccomp profiles (ubuntu-desktop-bootstrap; its base core24 is the system's own and stays)|^/(snap|var/snap|var/lib/snapd|var/cache/snapd|var/cache/apparmor)/(.*/)?(snap\\.|snap-update-ns\\.)?(ubuntu-desktop-bootstrap)([_./-]|\$)"
    "installer snap mount units and service units|^/etc/systemd/system/(.*/)?snap[.-](ubuntu(-|\\\\x2d)desktop(-|\\\\x2d)bootstrap)[.-]"
    "installer user service (ubuntu-desktop-installer.service)|ubuntu-desktop-installer\\.service\$"
    "subiquity live-session files (/etc/subiquity, subiquity_config.mount and the device drop-in that wants it)|^/etc/subiquity(/|\$)|^/usr/lib/systemd/system/subiquity_config\\.mount\$|^/etc/systemd/system/dev-disk-by[^/]*\\.device\\.d(/|\$)"
    "live-image cloud-init files (06_quiet.cfg, the NoCloud seed)|^/etc/cloud/cloud\\.cfg\\.d/06_quiet\\.cfg\$|^/var/lib/cloud/seed/nocloud(/|\$)"
    "live-image apt preferences backup (preferences.d.save/preferences.d; the stock standard layer has the flat files) and packages.chroot|^/etc/apt/preferences\\.d\\.save/preferences\\.d(/|\$)|^/root/packages\\.chroot(/|\$)"
    "live-session systemd settings (masked getty@tty1, udisks2-inhibit, media-filesystem.mount link, snapd re-exec drop-in, display-manager wait for snapd seeding)|^/usr/lib/systemd/system/getty@tty1\\.service\$|^/usr/lib/systemd/system/(.*/)?udisks2-inhibit\\.service\$|^/usr/lib/systemd/system/local-fs\\.target\\.wants/media-filesystem\\.mount\$|^/etc/systemd/system/snapd\\.service\\.d/snapd-snap-reexec\\.conf\$|^/etc/systemd/system/display-manager\\.service\\.d/wait-for-snapd-seeding\\.conf\$"
    "live-session security settings (the polkit rule that grants snapd's configuration to every subject, the sysctl file that switches off AppArmor's unprivileged-userns restriction)|^/etc/polkit-1/rules\\.d/10-allow-installer-wait-on-snap\\.rules\$|^/etc/sysctl\\.d/20-apparmor\\.conf\$"
    "the snapd seed of the TPM full-disk-encryption variant (seed/systems/enhanced-secureboot-desktop; no such layer is shipped)|^/var/lib/snapd/seed/systems(/|\$)"
    "live-session journald drop-ins|^/etc/systemd/journald\\.conf\\.d/no-rate-limit\\.conf\$|^/etc/systemd/system/systemd-journald\\.service\\.d/no-(compact|hardening)\\.conf\$"
)
# Packages that belong to the live layer only: not in the base layer's dpkg status in any state (a purged package that
# left its configuration files shows up there as "deinstall ok config-files"). finalrd exists for casper (Depends).
LIVE_ONLY_PKGS=(casper finalrd)
# Paths the live layer must contain, as "label|extended regular expression" (as above, matched against the live layer's
# listing): casper's own files, so that the layer is not a placeholder and the live session keeps the md5 check of the medium
# (casper-md5check.service, enabled on every live boot), and the live-session pieces that the build takes out of the base, so
# that they are in the live layer and not simply gone.
LIVE_REQUIRED=(
    "/etc/casper.conf|^/etc/casper\\.conf\$"
    "casper-md5check (the checker)|^/usr/lib/casper/casper-md5check\$"
    "casper-md5check.service (its unit)|^/usr/lib/systemd/system/casper-md5check\\.service\$"
    "casper.service|^/usr/lib/systemd/system/casper\\.service\$"
    "the enable link of casper-md5check.service|^/etc/systemd/system/multi-user\\.target\\.wants/casper-md5check\\.service\$"
    "casper initramfs script|^/usr/share/initramfs-tools/scripts/casper\$"
    "casper initramfs hook|^/usr/share/initramfs-tools/hooks/casper\$"
    "casper dpkg file list|^/var/lib/dpkg/info/casper\\.list\$"
    "finalrd.service|^/usr/lib/systemd/system/finalrd\\.service\$"
    "casper initramfs configuration (casperize.conf, default-layer.conf)|^/etc/initramfs-tools/conf\\.d/casperize\\.conf\$"
    "default-layer.conf (the live initrd's layer path)|^/etc/initramfs-tools/conf\\.d/default-layer\\.conf\$"
    "livecd-rootfs.gschema.override|^/usr/share/glib-2\\.0/schemas/livecd-rootfs\\.gschema\\.override\$"
    "the installer's user service|^/usr/lib/systemd/user/ubuntu-desktop-installer\\.service\$"
    "the installer snap file in the seed|^/var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_[0-9]+\\.snap\$"
)

LL_ANY='^[^ ]+ +[^ ]+ +[0-9]+(, *[0-9]+)? +[0-9-]+ +[0-9:]+ ?' # the same prefix as LL_PREFIX, also for device nodes ("0,  0")
listing_paths() { # listing_paths <listing>: the path of every entry, one per line, a symlink's " -> target" dropped
    awk -v pre="$LL_ANY" '{ p = $0; sub(pre, "", p); sub(/ -> .*$/, "", p); print p }' "$1"
}
status_pkgs() { # status_pkgs <dpkg status>: "name<TAB>version" of every installed package, sorted
    awk 'BEGIN{RS=""; FS="\n"} { n = ""; v = ""; ok = 0
             for (i = 1; i <= NF; i++) { if ($i ~ /^Package: /) n = substr($i, 10); else if ($i ~ /^Version: /) v = substr($i, 10); else if ($i == "Status: install ok installed") ok = 1 }
             if (ok && n != "") print n "\t" v }' "$1" 2>/dev/null | sort -u
}
manifest_pkgs() { # manifest_pkgs <layer manifest>: the same from a layer manifest (the "+name[:arch]<TAB>version" lines of a diff)
    sed -n 's/^+\([^+].*\)$/\1/p' "$1" 2>/dev/null | grep -v '^snap:' \
        | awk -F'\t' '{ n = $1; sub(/:[^:]*$/, "", n); print n "\t" $2 }' | sort -u
}
pkg_present() { # pkg_present <dpkg status> <package>: a paragraph for it, in whatever state
    awk -v p="$2" 'BEGIN{RS=""; FS="\n"} $1 == "Package: " p {f = 1} END{exit !f}' "$1" 2>/dev/null
}
layer_size_bounds() { # layer_size_bounds <listing>: "lo hi", the range a true `du -sx --block-size=1` of the layer's tree falls in
    # An `unsquashfs -ll` listing shows a hard link once per name, but du counts the inode once. Ubuntu 26.04.1 stores every snap blob
    # under two names that are ONE inode, /var/lib/snapd/snaps/X.snap and /var/lib/snapd/seed/snaps/X.snap, and mksquashfs 4.6.1 keeps
    # such links: in the stock minimal layer the listing says 9.06 GB and du 6.16 GB. So the lower bound leaves out the bytes of the
    # files directly in /var/lib/snapd/snaps (one name of every pair; a layer that lost a link has more du than that, never less).
    # lo: 80% of the remaining regular-file bytes (the rest of the slack is for sparse files and compressing filesystems).
    # hi: every regular file rounded up to 4 KiB, 4 KiB for every other entry, +20%, +1 MiB (both names counted: the upper bound allows a
    # layer whose links were lost).
    awk -v pre="$LL_PREFIX" '{ t = substr($1, 1, 1)
           if (t == "-") { app += $3; blk += int(($3 + 4095) / 4096) * 4096
                           p = $0; sub(pre, "", p); sub(/ -> .*$/, "", p)
                           if (p ~ /^\/var\/lib\/snapd\/snaps\/[^\/]+$/) twin += $3 } else other++ }
         END { printf "%.0f %.0f\n", (app - twin) * 0.8, (blk + other * 4096) * 1.2 + 1048576 }' "$1"
}
check_layer_size() { # check_layer_size <layer> <listing> <size file>: the size file is a number the layer's own listing allows
    local layer="$1" lst="$2" sf="$3" size lo hi
    if [[ ! -s "$sf" ]]; then fail "layer $layer: its .size file is missing or empty"; return; fi
    size="$(tr -d '[:space:]' < "$sf")"
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then fail "layer $layer: its .size file is not a number ('$size')"; return; fi
    size=$((10#$size))
    read -r lo hi < <(layer_size_bounds "$lst")
    if ((size >= lo && size <= hi)); then
        pass "layer $layer: .size ($size) is plausible for what the layer holds ($lo to $hi bytes)"
    else
        fail "layer $layer: .size is $size but the layer holds $lo to $hi bytes (a copy of another layer's number, or 0 for a layer that is not empty)"
    fi
}
casper_kernel_lines() { # casper_kernel_lines <menu>: the `linux /casper/vmlinuz` lines, blanks squeezed, one per line
    grep -E '^[[:space:]]*linux[[:space:]]+/casper/vmlinuz' "$1" 2>/dev/null | tr -s ' \t' ' ' | sed 's/^ //; s/ $//'
}
stock_kernel_line() { # a squeezed kernel line on stdin is the stock shape: only the words the stock menus use, and the one Companion adds
    awk '{ bad = ($1 != "linux" || $2 != "/casper/vmlinuz")
           for (i = 3; i <= NF && $i != "---"; i++) if ($i != "nomodeset" && $i != "$cmdline" && $i != "iso-scan/filename=${iso_path}" && $i != "ci.autoinstall=1") bad = 1
           # after the "---": quiet splash, and on the arm64 stock menu also console=tty0
           if ($i != "---" || $(i + 1) != "quiet" || $(i + 2) != "splash") bad = 1
           else if (NF != i + 2 && !(NF == i + 3 && $(i + 3) == "console=tty0")) bad = 1
           exit bad }'
}

BASE_PATHS="$WORK/base-paths.txt"
listing_paths "$LISTING" > "$BASE_PATHS"
BASE_STATUS="$R/var/lib/dpkg/status"
# A listing that could not be read makes every "has no" check below pass for nothing.
if grep -qxF /var/lib/dpkg/status "$BASE_PATHS" && [[ -s "$BASE_STATUS" ]]; then
    pass "base layer: listing and dpkg status are readable ($(wc -l < "$BASE_PATHS") entries)"
    for row in "${BASE_FORBIDDEN[@]}"; do
        label="${row%%|*}"; re="${row#*|}"
        hits="$(grep -E -e "$re" "$BASE_PATHS" | head -n 3 | tr '\n' ' ')"
        if [[ -z "$hits" ]]; then pass "base layer has no $label"; else fail "base layer ships $label: ${hits% }"; fi
    done
    # SSH host keys in the base would be the same private keys on every install made from this ISO (and on every copy of the ISO).
    # openssh-server's postinst generates them in the chroot; customize-chroot.sh removes them, and 26.04's sshd-keygen.service makes a fresh set on the first boot.
    hits="$(grep -E '^/etc/ssh/ssh_host_[A-Za-z0-9_]+_key(\.pub)?$' "$BASE_PATHS" | head -n 3 | tr '\n' ' ')"
    if [[ -z "$hits" ]]; then pass "base layer has no SSH host keys (generated on the first boot)"; else fail "base layer ships SSH host keys, the same on every install: ${hits% }"; fi
    for p in "${LIVE_ONLY_PKGS[@]}"; do
        if pkg_present "$BASE_STATUS" "$p"; then fail "base layer's dpkg status lists the live-only package $p"
        else pass "base layer's dpkg status has no live-only package $p"; fi
    done
    # The installer snap is seeded by the live layer's snapd files. If the base kept them, snapd on the installed system
    # would try to seed a snap whose file is not there, and know about an installer it does not have.
    SEEDY="$R/var/lib/snapd/seed/seed.yaml"
    if [[ -s "$SEEDY" ]]; then
        if grep -q 'ubuntu-desktop-bootstrap' "$SEEDY"; then fail "base layer's snapd seed.yaml names the installer snap (ubuntu-desktop-bootstrap)"
        else pass "base layer's snapd seed.yaml names no installer snap"; fi
        seed_missing=""
        while read -r sf; do
            [[ -n "$sf" ]] || continue
            grep -qxF "/var/lib/snapd/seed/snaps/$sf" "$BASE_PATHS" || seed_missing="$seed_missing $sf"
        done < <(sed -n 's/^[[:space:]-]*file:[[:space:]]*//p' "$SEEDY" | tr -d '\r"'"'")
        if [[ -z "$seed_missing" ]]; then pass "base layer's snapd seed.yaml names only snap files the base layer holds"
        else fail "base layer's snapd seed.yaml names snap files that are not in the base layer:$seed_missing"; fi
        # The converse: 26.04.1's live layer drops the snap files of its TPM-encryption seed (pc-kernel, pc, a second firefox revision,
        # nvidia components, 0.66 GB) into seed/snaps. The installed system's seed.yaml does not name them, so they are dead weight.
        seed_extra=""
        seed_names="$(sed -n 's/^[[:space:]-]*file:[[:space:]]*//p' "$SEEDY" | tr -d '\r"'"'")"
        while IFS= read -r sf; do
            [[ -n "$sf" ]] || continue
            grep -qxF -- "$sf" <<<"$seed_names" || seed_extra="$seed_extra $sf"   # (a here-string: a pipe into grep -q can die of SIGPIPE under pipefail)
        done < <(grep -E '^/var/lib/snapd/seed/snaps/[^/]+$' "$BASE_PATHS" | sed 's#^/var/lib/snapd/seed/snaps/##')
        if [[ -z "$seed_extra" ]]; then pass "base layer's seed/snaps holds only snap files its seed.yaml names"
        else fail "base layer's seed/snaps holds snap files that its seed.yaml does not name (the installed system's snapd never seeds them):$seed_extra"; fi
    else
        note "base layer has no var/lib/snapd/seed/seed.yaml (no snaps seeded)"
    fi
    if [[ -s "$R/var/lib/snapd/state.json" ]]; then
        if grep -Eq 'ubuntu-desktop-bootstrap' "$R/var/lib/snapd/state.json"; then fail "base layer's snapd state.json knows the installer snap (ubuntu-desktop-bootstrap)"
        else pass "base layer's snapd state.json knows no installer snap"; fi
    fi
    # Files the live image rewrote in place (the same path as in the stock layers below it): the base takes the stock ones back.
    if [[ -s "$R/etc/cloud/cloud.cfg" ]]; then
        if grep -q 'subiquity-shell' "$R/etc/cloud/cloud.cfg"; then fail "base layer's /etc/cloud/cloud.cfg is the live session's (it creates the installer user with /usr/bin/subiquity-shell)"
        else pass "base layer's /etc/cloud/cloud.cfg is not the live session's"; fi
    fi
    if grep -E -q '^l.* /usr/lib/systemd/systemd-networkd-wait-online -> ' "$LISTING"; then
        fail "base layer's systemd-networkd-wait-online is the live session's symlink ($(grep -E ' /usr/lib/systemd/systemd-networkd-wait-online -> ' "$LISTING" | sed 's/.* -> //' | head -n 1)), not the real binary"
    else
        pass "base layer's systemd-networkd-wait-online is not replaced by a symlink"
    fi
    # The installed system's initramfs generator. Ubuntu 26.04.1's minimal layer (the stock installed system) is dracut based; the live
    # layer swaps it for initramfs-tools by whiting dracut out (75 whiteout devices) and installing initramfs-tools. This build merges
    # all three layers, so the base it splits back out is initramfs-tools based: curtin then regenerates the initrd with
    # update-initramfs, which is initramfs-tools' (dracut's wrapper would run `dracut --force`; a base with neither would get no
    # initrd, because curtin does nothing when only dracut exists). That is on purpose and it is pinned: ubuntu-desktop-minimal
    # recommends dracut, which conflicts with initramfs-tools, so apt could later try to swap the generator under the system.
    if pkg_ok initramfs-tools; then pass "base layer: initramfs-tools is installed (update-initramfs is the real one curtin calls)"
    else fail "base layer: initramfs-tools is not installed (curtin would find no update-initramfs, or dracut's wrapper, and the installed system might get no initrd)"; fi
    for p in dracut dracut-core; do
        if pkg_present "$BASE_STATUS" "$p"; then fail "base layer's dpkg status lists $p (the base must be initramfs-tools based: dracut conflicts with initramfs-tools)"
        else pass "base layer's dpkg status has no $p"; fi
    done
    PIN="$R/etc/apt/preferences.d/ci-os-no-dracut"
    if [[ -f "$PIN" ]]; then
        pin_missing=""
        # The two generator packages. (dracut-install is NOT required: it is the helper initramfs-tools-core depends on, so pinning it to -1 would
        # freeze it at the installed version and keep its updates out; customize-chroot.sh's payload/apt file pins dracut and dracut-core only,
        # measured with apt-get -s dist-upgrade on 26.04. A pin file that lists it too is accepted.)
        for p in dracut dracut-core; do
            # a stanza of apt_preferences(5): a Package: line naming p, a Pin: line and Pin-Priority: -1 (apt never installs it)
            awk -v want="$p" 'BEGIN { RS = ""; FS = "\n" }
                { pk = 0; pn = 0; pr = 0
                  for (i = 1; i <= NF; i++) {
                      if ($i ~ /^Package:/) { line = $i; sub(/^Package:[[:space:]]*/, "", line); n = split(line, a, /[[:space:],]+/); for (j = 1; j <= n; j++) if (a[j] == want) pk = 1 }
                      else if ($i ~ /^Pin:[[:space:]]*[a-z]+[[:space:]]/) pn = 1
                      else if ($i ~ /^Pin-Priority:[[:space:]]*-1[[:space:]]*$/) pr = 1
                  }
                  if (pk && pn && pr) f = 1 }
                END { exit !f }' "$PIN" || pin_missing="$pin_missing $p"
        done
        if [[ -z "$pin_missing" ]]; then pass "/etc/apt/preferences.d/ci-os-no-dracut pins dracut and dracut-core to Pin-Priority -1 (apt cannot swap the initramfs generator)"
        else fail "/etc/apt/preferences.d/ci-os-no-dracut does not pin to Pin-Priority -1:$pin_missing"; fi
    else
        fail "/etc/apt/preferences.d/ci-os-no-dracut is missing (apt could install dracut, which conflicts with initramfs-tools, over the initramfs-tools based base)"
    fi
    # Ubuntu 26.04's subiquity expects the ISO pool's apt source IN the layer it installs (apt.py: "an /etc/apt/sources.list.d/cdrom.sources
    # file is present since Ubuntu 26.04") and deletes it from the installed system itself. The build disables it in the chroot only
    # for apt-get update and has to put it back; a renamed copy makes subiquity write an unsigned sources.list entry for the pool.
    if in_listing ' /etc/apt/sources\.list\.d/cdrom\.sources$' && file_has "$R/etc/apt/sources.list.d/cdrom.sources" '^URIs:[[:space:]]*file:///cdrom[[:space:]]*$'; then
        pass "base layer: /etc/apt/sources.list.d/cdrom.sources is there, for the ISO pool (subiquity 26.04 relies on it and removes it from the installed system)"
    else fail "base layer: /etc/apt/sources.list.d/cdrom.sources is missing or is not the ISO pool's source"; fi
    if in_listing 'cdrom\.sources\.disabled'; then fail "base layer: a cdrom.sources.disabled is left over from the build's apt-get update"; else pass "base layer: no cdrom.sources.disabled left over"; fi
else
    fail "base layer: could not read its listing or var/lib/dpkg/status, so none of the live-only checks could run"
fi

# The live layer: the real live delta, not an empty placeholder.
LIVE_PATHS="$WORK/live-paths.txt"
listing_paths "$LIVELIST" > "$LIVE_PATHS"
LIVE_STATUS="$LR/var/lib/dpkg/status"
if [[ ! -s "$LIVELIST" ]]; then
    fail "live layer: could not list /casper/minimal.standard.live.squashfs"
else
    live_files="$(awk '$1 !~ /^d/' "$LIVELIST" | wc -l | tr -d ' ')"
    if [[ "$live_files" -gt 0 ]]; then pass "live layer is not a placeholder ($live_files entries that are not directories)"
    else fail "live layer is an empty placeholder (directories only): casper is in no layer the live session sees"; fi
    live_missing=""
    for row in "${LIVE_REQUIRED[@]}"; do
        grep -E -q -e "${row#*|}" "$LIVE_PATHS" || live_missing="$live_missing [${row%%|*}]"
    done
    if [[ -z "$live_missing" ]]; then pass "live layer holds what the base had taken out: casper's files, casper-md5check and its enable link, the installer's pieces"
    else fail "live layer lacks:$live_missing"; fi
    # Canonical's installer window must not open by itself in the live session: it would open in front of the Companion one-click dialog and show
    # Canonical's 13-page wizard first. The stock live layer enables ubuntu-desktop-installer.service with a user-level wants link (and the unit file,
    # required above, stays so that `systemctl --user start ubuntu-desktop-installer` still works); customize-chroot.sh Step 7b removes the link. Any
    # wants or requires link of that unit, or an autostart entry that names the installer, in the live layer starts the window again.
    hits="$(grep -E '^/(etc|usr/lib|lib)/systemd/user/[^/]+\.(wants|requires)/ubuntu-desktop-installer\.service$|^/etc/xdg/autostart/.*(ubuntu-desktop-(installer|bootstrap)|subiquity)' "$LIVE_PATHS" | head -n 3 | tr '\n' ' ')"
    if [[ -z "$hits" ]]; then pass "live layer does not start Canonical's installer by itself (no wants link for ubuntu-desktop-installer.service, no autostart entry for it)"
    else fail "live layer starts Canonical's installer window by itself (it opens in front of the Companion dialog): ${hits% }"; fi
    if [[ -s "$LR/var/lib/snapd/seed/seed.yaml" ]] && grep -q 'ubuntu-desktop-bootstrap' "$LR/var/lib/snapd/seed/seed.yaml"; then pass "live layer's snapd seed.yaml still names the installer snap"
    else fail "live layer's snapd seed.yaml does not name the installer snap (the live session cannot seed it)"; fi
    # Ubuntu 26.04.1's live layer carries the snapd seed of its TPM full-disk-encryption variant (seed/systems/enhanced-secureboot-desktop, and in
    # seed/snaps a pc-kernel, a pc gadget, a second firefox revision and two nvidia components that seed.yaml does not name: 0.66 GB). This image ships
    # none of the enhanced-secureboot layers and offers no such variation, so build-iso.sh (remove_esb_seed) deletes the seed from the rootfs before the
    # split and it is in neither layer. Still there, it is weight on a medium that must fit the smallest Stick boot slot (see the size check below).
    hits="$(grep -E '^/var/lib/snapd/seed/systems(/|$)' "$LIVE_PATHS" | head -n 3 | tr '\n' ' ')"
    if [[ -z "$hits" ]]; then pass "live layer has no snapd seed of the TPM full-disk-encryption variant (seed/systems)"
    else fail "live layer ships the snapd seed of the TPM full-disk-encryption variant (no such layer is shipped): ${hits% }"; fi
    live_seed_names="$(sed -n 's/^[[:space:]-]*file:[[:space:]]*//p' "$LR/var/lib/snapd/seed/seed.yaml" 2>/dev/null | tr -d '\r"'"'")"
    live_seed_extra=""
    while IFS= read -r sf; do
        [[ -n "$sf" ]] || continue
        grep -qxF -- "$sf" <<<"$live_seed_names" || live_seed_extra="$live_seed_extra $sf"   # (a here-string: a pipe into grep -q can die of SIGPIPE under pipefail)
    done < <(grep -E '^/var/lib/snapd/seed/snaps/[^/]+$' "$LIVE_PATHS" | sed 's#^/var/lib/snapd/seed/snaps/##')
    if [[ -z "$live_seed_extra" ]]; then pass "live layer's seed/snaps holds only snap files its seed.yaml names"
    else fail "live layer's seed/snaps holds snap files that its seed.yaml does not name (the encryption variant's pc-kernel, pc, second firefox, nvidia components; dead weight):$live_seed_extra"; fi
    if [[ -s "$LR/etc/cloud/cloud.cfg" ]] && grep -q 'subiquity-shell' "$LR/etc/cloud/cloud.cfg"; then pass "live layer carries the live session's /etc/cloud/cloud.cfg"
    else fail "live layer does not carry the live session's /etc/cloud/cloud.cfg (the base's stock copy would apply in the live session too)"; fi
    if [[ -s "$LIVE_STATUS" ]] && awk 'BEGIN{RS=""; FS="\n"} $1 == "Package: casper" { for (i = 1; i <= NF; i++) if ($i == "Status: install ok installed") f = 1 } END{exit !f}' "$LIVE_STATUS"; then
        pass "live layer's dpkg status lists casper as installed"
    else
        fail "live layer's dpkg status does not list casper as installed (or has none)"
    fi
fi
# minimal.standard.squashfs sits between the two and stays the empty placeholder the stock ISO's install-sources.yaml entry needs.
STDSQ="$ISOX/minimal.standard.squashfs"; STDLIST="$WORK/minimal.standard.listing.txt"
[[ -s "$STDLIST" ]] || { [[ -s "$STDSQ" ]] && unsquashfs -ll "$STDSQ" 2>/dev/null | sed 's#squashfs-root##' > "$STDLIST"; }
if [[ -s "$STDLIST" ]]; then
    std_files="$(awk '$1 !~ /^d/' "$STDLIST" | wc -l | tr -d ' ')"
    if [[ "$std_files" -eq 0 ]]; then pass "minimal.standard.squashfs is still the empty placeholder"
    else fail "minimal.standard.squashfs holds $std_files entries that are not directories (it must stay an empty placeholder)"; fi
else
    fail "could not list /casper/minimal.standard.squashfs"
fi

# The per-layer .size and .manifest files describe the layers this image has, not the stock ones.
check_layer_size minimal "$LISTING" "$ISOX/minimal.size"
check_layer_size minimal.standard "${STDLIST:-/dev/null}" "$ISOX/minimal.standard.size"
check_layer_size minimal.standard.live "$LIVELIST" "$ISOX/minimal.standard.live.size"
PK="$WORK/pkgs"; mkdir -p "$PK"
status_pkgs "$BASE_STATUS" > "$PK/base.status"
status_pkgs "$LIVE_STATUS" > "$PK/live.status"
for m in minimal minimal.standard minimal.standard.live; do manifest_pkgs "$ISOX/$m.manifest" > "$PK/$m.manifest"; done
comm -13 "$PK/base.status" "$PK/live.status" > "$PK/live.delta"
if [[ ! -s "$ISOX/minimal.manifest" ]]; then fail "minimal.manifest is missing or empty"
elif cmp -s "$PK/minimal.manifest" "$PK/base.status"; then pass "minimal.manifest lists exactly the packages of the base layer ($(wc -l < "$PK/base.status"))"
else fail "minimal.manifest is not the base layer's package list ($(comm -23 "$PK/minimal.manifest" "$PK/base.status" | wc -l | tr -d ' ') only in the manifest, $(comm -13 "$PK/minimal.manifest" "$PK/base.status" | wc -l | tr -d ' ') only in the layer)"; fi
if [[ ! -e "$ISOX/minimal.standard.manifest" ]]; then fail "minimal.standard.manifest is missing"
elif [[ ! -s "$PK/minimal.standard.manifest" ]]; then pass "minimal.standard.manifest lists no package (the layer is empty)"
else fail "minimal.standard.manifest still lists $(wc -l < "$PK/minimal.standard.manifest" | tr -d ' ') package(s) (the stock list; the layer is empty)"; fi
if [[ ! -s "$ISOX/minimal.standard.live.manifest" ]]; then fail "minimal.standard.live.manifest is missing or empty"
elif cmp -s "$PK/minimal.standard.live.manifest" "$PK/live.delta" && [[ -s "$PK/live.delta" ]]; then
    pass "minimal.standard.live.manifest lists exactly the packages the live layer adds to the base ($(wc -l < "$PK/live.delta" | tr -d ' '))"
else
    fail "minimal.standard.live.manifest is not the live layer's package delta ($(comm -23 "$PK/minimal.standard.live.manifest" "$PK/live.delta" | wc -l | tr -d ' ') only in the manifest, $(comm -13 "$PK/minimal.standard.live.manifest" "$PK/live.delta" | wc -l | tr -d ' ') only in the layer)"
fi
# The full manifests describe the whole stack up to a layer: "name<TAB>version" per package, then "snap:name<TAB>channel<TAB>revision". The
# stock ISO ships one per layer; the stock ones describe the stock layers, so a stale one would list packages this image does not have.
full_pkgs() { # the package lines of a .manifest.full, name:arch reduced to name like manifest_pkgs does, sorted like status_pkgs
    grep -v '^snap:' "$1" 2>/dev/null | awk -F'\t' '{ n = $1; sub(/:[^:]*$/, "", n); print n "\t" $2 }' | sort -u
}
for m in minimal minimal.standard minimal.standard.live; do
    case "$m" in minimal.standard.live) want_status="$PK/live.status" ;; *) want_status="$PK/base.status" ;; esac
    full_pkgs "$ISOX/$m.manifest.full" > "$PK/$m.full"
    if [[ ! -s "$ISOX/$m.manifest.full" ]]; then fail "$m.manifest.full is missing or empty"
    elif cmp -s "$PK/$m.full" "$want_status"; then pass "$m.manifest.full lists exactly the packages of the stack up to that layer ($(wc -l < "$want_status" | tr -d ' '))"
    else fail "$m.manifest.full is not the package list of the stack up to that layer ($(comm -23 "$PK/$m.full" "$want_status" | wc -l | tr -d ' ') only in the manifest, $(comm -13 "$PK/$m.full" "$want_status" | wc -l | tr -d ' ') only in the layer)"; fi
done
# ...and the snap lines are the snaps of that stack's seed (the base's seed.yaml for the first two, the live layer's for the last)
for pair in "minimal:$R/var/lib/snapd/seed/seed.yaml" "minimal.standard.live:$LR/var/lib/snapd/seed/seed.yaml"; do
    m="${pair%%:*}"; sy="${pair#*:}"
    [[ -s "$sy" && -s "$ISOX/$m.manifest.full" ]] || continue
    seed_snap_names="$(sed -n 's/^[[:space:]-]*name:[[:space:]]*//p' "$sy" | tr -d '\r"'"'" | sort -u)"
    full_snap_names="$(sed -n 's/^snap:\([^[:space:]]*\)[[:space:]].*/\1/p' "$ISOX/$m.manifest.full" | sort -u)"
    if [[ "$seed_snap_names" == "$full_snap_names" ]]; then pass "$m.manifest.full lists the snaps of that stack's seed ($(printf '%s\n' "$full_snap_names" | grep -c .))"
    else fail "$m.manifest.full's snap lines are not the snaps of that stack's seed.yaml (manifest: $(printf '%s' "$full_snap_names" | tr '\n' ' '); seed: $(printf '%s' "$seed_snap_names" | tr '\n' ' '))"; fi
done
live_casper_ver="$(awk -F'\t' '$1 == "casper" {print $2}' "$PK/live.status")"
if [[ -n "$live_casper_ver" && "$(awk -F'\t' '$1 == "casper" {print $2}' "$PK/minimal.standard.live.manifest")" == "$live_casper_ver" ]]; then
    pass "minimal.standard.live.manifest lists casper $live_casper_ver, the version the live layer has"
else
    fail "minimal.standard.live.manifest does not list casper at the version the live layer has (${live_casper_ver:-none})"
fi
if awk -F'\t' '$1 == "casper" {f = 1} END{exit !f}' "$PK/minimal.manifest"; then fail "minimal.manifest lists casper (the base layer has none)"
else pass "minimal.manifest does not list casper"; fi

# The boot menus keep the stock kernel lines. The live boot needs no kernel parameter to find its layers (the stock initrd
# carries the layer path in its own configuration), and a parameter such as boot= or layerfs-path= is how a change to
# the layer layout gets "fixed" in the menu instead of in the layers. The one Companion addition is ci.autoinstall=1.
for menu in grub.cfg loopback.cfg; do
    if [[ ! -s "$ISOX/$menu" && "$menu" == loopback.cfg && "$VARCH" == arm64 ]]; then
        note "$menu: the arm64 ISO has none (it is a GRUB-from-a-file feature of the x86-64 image)"; continue
    fi
    if [[ ! -s "$ISOX/$menu" ]]; then fail "could not extract $menu from the ISO"; continue; fi
    klines="$(casper_kernel_lines "$ISOX/$menu")"
    nk="$(printf '%s\n' "$klines" | grep -c . || true)"; nbad=0
    while IFS= read -r kl; do
        [[ -n "$kl" ]] || continue
        printf '%s\n' "$kl" | stock_kernel_line || { nbad=$((nbad + 1)); fail "$menu: kernel line is not the stock one: $kl"; }
    done <<<"$klines"
    if [[ "$nk" -lt 2 ]]; then fail "$menu: $nk kernel lines found, expected the stock entries"
    elif [[ "$nbad" -eq 0 ]]; then pass "$menu: all $nk kernel lines are the stock ones (no boot=, layerfs-path= or other added parameter)"; fi
done
if [[ -n "${VERIFY_BASE_ISO:-}" && -f "$VERIFY_BASE_ISO" ]]; then
    BASEMENU="$WORK/base-menus"; mkdir -p "$BASEMENU"
    for menu in grub.cfg loopback.cfg; do
        xorriso -osirrox on -indev "$VERIFY_BASE_ISO" -extract "/boot/grub/$menu" "$BASEMENU/$menu" >/dev/null 2>&1
        if [[ -s "$BASEMENU/$menu" && -s "$ISOX/$menu" ]]; then
            ours="$(casper_kernel_lines "$ISOX/$menu" | sed 's/ ci\.autoinstall=1//' | sort -u)"
            stock="$(casper_kernel_lines "$BASEMENU/$menu" | sort -u)"
            if [[ "$ours" == "$stock" ]]; then pass "$menu: the kernel lines equal the base ISO's (apart from ci.autoinstall=1)"
            else fail "$menu: the kernel lines differ from the base ISO's"; fi
        elif [[ "$menu" == loopback.cfg && "$VARCH" == arm64 && ! -s "$BASEMENU/$menu" && ! -s "$ISOX/$menu" ]]; then
            note "$menu: neither the base ISO nor this one has it (arm64): nothing to compare"
        else
            fail "$menu: could not compare the kernel lines with the base ISO's"
        fi
    done
else
    note "kernel lines not compared with a stock ISO's (skipped: set VERIFY_BASE_ISO=<stock Ubuntu ISO>)"
fi

# ── 4. branding ─────────────────────────────────────────────────────────────
section "4. Branding: user-visible identity is Companion OS"
check "os-release NAME is Companion OS" file_has "$R/usr/lib/os-release" '^NAME="Companion OS"$'
check "os-release PRETTY_NAME starts with Companion OS" file_has "$R/usr/lib/os-release" '^PRETTY_NAME="Companion OS '
check "os-release VERSION names the product Companion OS (not the company)" file_has "$R/usr/lib/os-release" '^VERSION="[0-9.]+ LTS \(Companion OS [^)]+\)"$'
check "os-release keeps ID=ubuntu (apt and the installer rely on it)" file_has "$R/usr/lib/os-release" '^ID=ubuntu$'
check "os-release keeps VERSION_CODENAME (apt sources)" file_has "$R/usr/lib/os-release" '^VERSION_CODENAME=[a-z]+$'
check "lsb-release description is Companion OS" file_has "$R/etc/lsb-release" '^DISTRIB_DESCRIPTION="Companion OS'
check "lsb-release keeps DISTRIB_ID=Ubuntu (tools key off it)" file_has "$R/etc/lsb-release" '^DISTRIB_ID=Ubuntu$'

# Identity: apt, curtin/subiquity and unattended-upgrades key off these, so they stay Ubuntu's. The stock file is
# saved on the image as /etc/os-release.ubuntu-base (customize-chroot.sh), and the branded one must agree with it.
check "os-release keeps ID_LIKE=debian" file_has "$R/usr/lib/os-release" '^ID_LIKE=debian$'
check "os-release keeps VERSION_ID (apt sources, installer)" file_has "$R/usr/lib/os-release" '^VERSION_ID="[0-9]+\.[0-9]+"$'
check "os-release keeps UBUNTU_CODENAME (apt sources)" file_has "$R/usr/lib/os-release" '^UBUNTU_CODENAME=[a-z]+$'
check "os-release has CI_OS_ID=ci-os, CI_OS_VERSION and a CI_OS_BUILD day" bash -c "grep -q '^CI_OS_ID=ci-os\$' '$R/usr/lib/os-release' && grep -q -E '^CI_OS_VERSION=\".+\"\$' '$R/usr/lib/os-release' && grep -q -E '^CI_OS_BUILD=\"[0-9]{8}\"\$' '$R/usr/lib/os-release'"
if in_listing ' /etc/os-release -> \.\./usr/lib/os-release$'; then pass "/etc/os-release is still the symlink to ../usr/lib/os-release (the writer writes through it)"; else fail "/etc/os-release is not a symlink to ../usr/lib/os-release"; fi
BASE_OSREL="$R/etc/os-release.ubuntu-base"
if file_has "$BASE_OSREL" '^ID=ubuntu$'; then
    pass "the stock Ubuntu identity is saved at /etc/os-release.ubuntu-base (apt, ROCm and the first-boot rebrand read it)"
    for key in VERSION_ID VERSION_CODENAME UBUNTU_CODENAME; do
        base_val="$(grep -E "^${key}=" "$BASE_OSREL" | head -1 | cut -d= -f2- | tr -d '"')"
        iso_val="$(grep -E "^${key}=" "$R/usr/lib/os-release" | head -1 | cut -d= -f2- | tr -d '"')"
        if [[ -n "$base_val" && "$base_val" == "$iso_val" ]]; then pass "os-release $key=$iso_val matches the stock Ubuntu base"; else fail "os-release $key=${iso_val:-<missing>} differs from the stock Ubuntu base (${base_val:-<missing>})"; fi
    done
else
    fail "/etc/os-release.ubuntu-base is missing or not Ubuntu's (the stock identity was not saved before branding)"
fi

# Golden: regenerate both files with the one shared writer, from this ISO's own base and CI_OS_VERSION, and require an
# exact match apart from the CI_OS_BUILD day. tests/os-release-golden.sh pins that writer to the text the image build
# wrote before the writer was shared, so the two together catch any drift in the file a built ISO ships.
OSREL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" 2>/dev/null && pwd)/os-release.sh"
ISO_CI_VERSION="$(sed -n 's/^CI_OS_VERSION="\(.*\)"$/\1/p' "$R/usr/lib/os-release" 2>/dev/null | head -1)"
if [[ ! -f "$OSREL_LIB" ]]; then
    fail "cannot compare os-release with the shared writer: backends/ubuntu/lib/os-release.sh not found next to this script"
elif [[ ! -s "$BASE_OSREL" || -z "$ISO_CI_VERSION" ]]; then
    fail "cannot compare os-release with the shared writer: the ISO has no /etc/os-release.ubuntu-base or no CI_OS_VERSION"
else
    (
        # shellcheck source=../../lib/os-release.sh
        source "$OSREL_LIB"
        CI_OS_UBUNTU_BASE_OS_RELEASE="$BASE_OSREL"
        export CI_OS_VERSION="$ISO_CI_VERSION"
        ci_os_write_branded_os_release "$WORK/os-release.golden"
        ci_os_write_branded_lsb_release "$WORK/lsb-release.golden"
    ) >/dev/null 2>&1
    stamp_masked() { sed 's/^CI_OS_BUILD=.*/CI_OS_BUILD=<day>/' "$1"; }
    stamp_masked "$WORK/os-release.golden" > "$WORK/os-release.golden.masked" 2>/dev/null
    stamp_masked "$R/usr/lib/os-release" > "$WORK/os-release.iso.masked" 2>/dev/null
    if [[ -s "$WORK/os-release.golden.masked" ]] && diff -u "$WORK/os-release.golden.masked" "$WORK/os-release.iso.masked" > "$WORK/os-release.diff" 2>&1; then
        pass "os-release equals the shared writer's output for this base (apart from the CI_OS_BUILD day)"
    else
        fail "os-release differs from the shared writer's output for this base:"; sed 's/^/      /' "$WORK/os-release.diff" 2>/dev/null | head -30
    fi
    if [[ -s "$WORK/lsb-release.golden" ]] && diff -u "$WORK/lsb-release.golden" "$R/etc/lsb-release" > "$WORK/lsb-release.diff" 2>&1; then
        pass "lsb-release equals the shared writer's output for this base"
    else
        fail "lsb-release differs from the shared writer's output for this base:"; sed 's/^/      /' "$WORK/lsb-release.diff" 2>/dev/null | head -30
    fi
fi
check "/etc/issue is Companion OS" file_has "$R/etc/issue" 'Companion OS'
check "installed-system hostname is companion-os" file_has "$R/etc/hostname" '^companion-os$'
if [[ "$VARCH" == arm64 && ! -e "$R/etc/default/grub" ]]; then
    note "GRUB_DISTRIBUTOR: the arm64 base image has no /etc/default/grub (the installer installs GRUB); the installed GRUB names itself from os-release: $(sed -n 's/^NAME=//p' "$R/etc/os-release" | head -1)"
    check "arm64: os-release NAME is Companion OS (what the installed GRUB's GRUB_DISTRIBUTOR reads)" grep -q -x 'NAME="Companion OS"' "$R/etc/os-release"
else
    check "GRUB_DISTRIBUTOR is Companion OS" file_has "$R/etc/default/grub" '^GRUB_DISTRIBUTOR="Companion OS"'
fi
check "live session host name is not 'ubuntu'" bash -c "! grep -q -E '^export HOST=\"ubuntu\"' '$CASPER_CONF'"
check "live session user is not 'ubuntu'" bash -c "! grep -q -E '^export USERNAME=\"ubuntu\"' '$CASPER_CONF'"
check "casper keeps BUILD_SYSTEM=Ubuntu (casper logic depends on it)" file_has "$CASPER_CONF" '^export BUILD_SYSTEM="Ubuntu"'
check "MOTD header is Companion OS" bash -c "grep -q 'Companion OS' '$R'/etc/update-motd.d/00-ci-os-header"
if in_listing '^-rw-r--r-- .* /etc/update-motd\.d/00-header$'; then pass "Ubuntu's own MOTD welcome (00-header) is disabled"; else fail "Ubuntu's own MOTD welcome (00-header) is still executable"; fi

# The product name in the rest of what a user reads. The product is "Companion OS"; "CI OS", "CI-OS Desktop", "Companion
# Ubuntu" and "Intelligence Operating System" were earlier spellings of it. The installer lists the sources in
# install-sources.yaml by their en: names ("Companion OS (minimized)" and "Companion OS"), and the text-mode splash (the
# safe-graphics boot) is titled with the product and the version os-release carries.
ISRC="$ISOX/install-sources.yaml"
check "install-sources.yaml names every source Companion OS (each en: line starts with it)" \
    awk '/^[[:space:]]+en:/ { n++; if ($0 !~ /en: Companion OS( |$)/) bad++ } END { exit !(n >= 2 && !bad) }' "$ISRC"
check "install-sources.yaml has no CI-OS or CI OS spelling" bash -c "[[ -s '$ISRC' ]] && ! grep -q -E 'CI[ -]OS' '$ISRC'"
TEXT_PLYMOUTH="$R/usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth"
check "Plymouth text theme is named Companion OS Text" file_has "$TEXT_PLYMOUTH" '^Name=Companion OS Text$'
check "Plymouth text theme description says Companion OS" file_has "$TEXT_PLYMOUTH" '^Description=.*Companion OS'
if [[ -n "$ISO_CI_VERSION" ]]; then
    check "Plymouth text splash title is 'Companion OS $ISO_CI_VERSION' (the version os-release carries)" \
        grep -q -x -F -- "title=Companion OS $ISO_CI_VERSION" "$TEXT_PLYMOUTH"
else
    check "Plymouth text splash title is 'Companion OS <version>'" file_has "$TEXT_PLYMOUTH" '^title=Companion OS [0-9][^ ]*$'
fi
check "Plymouth text splash title is not the 0.0.1 placeholder" bash -c "[[ -s '$TEXT_PLYMOUTH' ]] && ! grep -q -E '^title=.* 0\\.0\\.1\$' '$TEXT_PLYMOUTH'"
OLD_NAMES='CI OS|Companion Ubuntu|Intelligence Operating System|Companion Intelligence OS|Companion Intelligence [0-9]'
old_name_hits=""
for f in "$R/usr/lib/os-release" "$R/etc/lsb-release" "$R/etc/issue" "$R/etc/issue.net" "$R/etc/default/grub" "$R"/etc/update-motd.d/* \
         "$R/usr/share/applications/ci-os-hub.desktop" "$TEXT_PLYMOUTH" "$ISRC" "$ISOX/disk-info" "$ISOX/grub.cfg" "$ISOX/loopback.cfg"; do
    if [[ -f "$f" ]] && grep -q -E -- "$OLD_NAMES" "$f"; then old_name_hits="$old_name_hits ${f#"$WORK"/}"; fi
done
if [[ -z "$old_name_hits" ]]; then
    pass "no retired product name (CI OS, Companion Ubuntu, Intelligence Operating System, Companion Intelligence <version>) in os-release, issue, GRUB, MOTD, the Hub entry, the splash or the installer sources"
else
    fail "a retired product name is still in:$old_name_hits"
fi
# A name drawn in block letters is invisible to the grep above (the old MOTD banner spelled "CI OS" that way), so the
# MOTD carries words only. U+2588 is written as bytes so this file holds no block art itself.
BLOCK_ART=$'\xe2\x96\x88'
block_art_hits=""
for f in "$R"/etc/update-motd.d/* "$R/etc/issue" "$R/etc/issue.net"; do
    if [[ -f "$f" ]] && grep -q -F -- "$BLOCK_ART" "$f"; then block_art_hits="$block_art_hits ${f#"$WORK"/}"; fi
done
if [[ -z "$block_art_hits" ]]; then
    pass "the MOTD and issue banners are words only (no block-letter art that could spell a retired name)"
else
    fail "block-letter banner art in:$block_art_hits"
fi

section "4b. About logo, dock start icon, LOGO icon, greeter logo"
# The canon comes from the repo this script lives in (vendor/brand: the tokens and the vendored marks), never from a
# value copied out of an image: the colours are the CI_* tokens, the artwork is vendor/brand/logos/mark.svg. A copy of
# this script outside the repo cannot derive them, and skips the content checks with a note.
CANON_TOKENS="$VERIFY_REPO/vendor/brand/tokens/tokens.sh"
CANON_MARK="$VERIFY_REPO/vendor/brand/logos/mark.svg"
PNGTOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" 2>/dev/null && pwd)/png-colours.py"
RENDER_MARK="$VERIFY_REPO/core/render/render-mark-png.sh"
CANON_OK=0
if [[ -f "$CANON_TOKENS" && -f "$CANON_MARK" && -f "$PNGTOOL" && -f "$RENDER_MARK" ]]; then
    # shellcheck source=../../../../vendor/brand/tokens/tokens.sh
    source "$CANON_TOKENS"
    CANON_OK=1
else
    skip "the canon content checks (logo shapes and colours, Plymouth colours, text splash ground): run this script from the repo checkout (vendor/brand, core/render, backends/ubuntu/lib/png-colours.py)"
fi
png_tool() { python3 -I "$PNGTOOL" "$@"; }
can_render() { command -v rsvg-convert >/dev/null 2>&1 || command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; }
logo_ramp() { # the three fill colours of the vendored colour mark, lower case, no '#', comma separated
    grep -o 'fill:#[0-9a-fA-F]\{6\}' "$CANON_MARK" | sed 's/fill:#//' | tr 'A-F' 'a-f' | sort -u | paste -sd, -
}
# canon_png <label> <png> <solid|palette> <colours> <fill>
# The opaque pixels must be exactly those colours and the mark must cover a sensible part of the image (png-colours.py:
# a red square, an empty or a black render fails). Then, where a renderer exists on this machine, the shape is compared
# with a fresh render of the vendored mark at the same width: IoU of the alpha masks, about 0.98 between rsvg-convert and
# ImageMagick, far lower for any other artwork. fill is the token the one-colour mark is filled with, "" for the colour mark.
canon_png() {
    local label="$1" f="$2" mode="$3" colours="$4" fill="$5" msg w ref iou
    if msg="$(png_tool "$mode" "$f" "$colours" 2>&1)"; then pass "$label: $msg"; else fail "$label: $msg"; fi
    if can_render; then
        w="$(png_width "$f")"; ref="$WORK/ref-$(basename "$f")"
        if bash "$RENDER_MARK" "$ref" "$w" ${fill:+"$fill"} >/dev/null 2>&1 && iou="$(png_tool iou "$f" "$ref" 2>&1)"; then
            if awk -v v="$iou" 'BEGIN { exit !(v >= 0.93) }'; then
                pass "$label: shape matches a fresh render of the vendored mark (IoU $iou)"
            else
                fail "$label: shape differs from a fresh render of the vendored mark (IoU $iou, want >= 0.93)"
            fi
        else
            fail "$label: could not compare it with a fresh render of the vendored mark (${iou:-render failed})"
        fi
    fi
}
if [[ $CANON_OK -eq 1 ]] && ! can_render; then note "no rsvg-convert or ImageMagick here: logo shapes are not compared with a fresh render of the mark"; fi

# Settings > About (gnome-control-center) hard-codes two base-files pixmaps, light and dark, and ignores LOGO=. GNOME 50's
# gnome-control-center 50.3 names the SVGs (/usr/share/pixmaps/ubuntu-logo-text.svg and ubuntu-logo-text-dark.svg: the strings are in the
# binary, and no .png variant is); the PNGs are still shipped by base-files 26.04.1 and older consumers read them, so both pairs are
# replaced. 45-about-logo.sh installs the one-colour mark in the canon primary of each mode, as PNG and as SVG.
# The stock sha256 values below are Ubuntu 26.04.1's own files (read off the base ISO; the PNGs are 187x72, the wordmark in Ubuntu
# orange; 24.04.5's pair was different, 260 and 256 px wide).
STOCK_ABOUT_LIGHT_SHA=5f8a4779510b8eb5dfe40b7f5526945105e0788cd9577472894fef3c22d7ce2b
STOCK_ABOUT_DARK_SHA=63c599f9b4ad9938161f996b9eac4be3634e9af26f25f32c4be8bcff2ac45f1e
STOCK_ABOUT_LIGHT_SVG_SHA=351337c2bcd8b0eb9450aa47ea65fed87d92088298c8900c98fdb815c682c433
STOCK_ABOUT_DARK_SVG_SHA=bc60770f29cda9e8d78809e25d6dfb8824efc29b4788ca9b1379054db0d48119
for pair in "ubuntu-logo-text.png:$STOCK_ABOUT_LIGHT_SHA:light" "ubuntu-logo-text-dark.png:$STOCK_ABOUT_DARK_SHA:dark"; do
    name="${pair%%:*}"; rest="${pair#*:}"; stock="${rest%%:*}"; mode="${rest##*:}"; f="$R/usr/share/pixmaps/$name"
    if [[ ! -f "$f" ]]; then fail "Settings > About logo missing: /usr/share/pixmaps/$name"; continue; fi
    if [[ "$(head -c8 "$f" | od -An -tx1 | tr -d ' \n')" == "89504e470d0a1a0a" ]]; then
        w="$(png_width "$f")"
        if [[ -n "$w" && "$w" -ge 1 && "$w" -le 300 ]]; then pass "$name is a PNG, ${w}px wide"; else fail "$name is ${w:-unknown}px wide (expected 1-300)"; fi
    else
        fail "$name is not a PNG"
    fi
    if [[ "$(sha256sum "$f" | cut -d' ' -f1)" != "$stock" ]]; then pass "$name is not Ubuntu's stock file"; else fail "$name is still Ubuntu's stock wordmark"; fi
    if divert_ok "/usr/share/pixmaps/$name" && stock_copy_listed "/usr/share/pixmaps/$name"; then
        pass "$name is dpkg-diverted (base-files cannot restore Ubuntu's)"
    else
        fail "$name is not dpkg-diverted to $name.ubuntu-stock (a base-files upgrade would restore Ubuntu's wordmark)"
    fi
    if [[ $CANON_OK -eq 1 ]] && png_is "$f"; then
        if [[ "$mode" == light ]]; then fill="$CI_LIGHT_PRIMARY"; else fill="$CI_DARK_PRIMARY"; fi
        canon_png "$name ($mode mode)" "$f" solid "${fill#\#}" "$fill"
    fi
done
# The SVG pair gnome-control-center 50 actually reads. Branded means: not Ubuntu's file, no Ubuntu orange, and (given the repo's canon)
# the vendored one-colour mark filled with the mode's primary token, exactly what the PNG of the same mode is drawn from: every path of
# mark-mono.svg is in the file, with fill:<the primary>, and the dock/start-icon colours of the three-tone artwork are not.
for pair in "ubuntu-logo-text.svg:$STOCK_ABOUT_LIGHT_SVG_SHA:light" "ubuntu-logo-text-dark.svg:$STOCK_ABOUT_DARK_SVG_SHA:dark"; do
    name="${pair%%:*}"; rest="${pair#*:}"; stock="${rest%%:*}"; mode="${rest##*:}"; f="$R/usr/share/pixmaps/$name"
    if [[ ! -f "$f" ]]; then fail "Settings > About SVG logo missing: /usr/share/pixmaps/$name (GNOME 50 reads this file, not the PNG)"; continue; fi
    if grep -q -a '<svg' "$f"; then pass "$name is an SVG"; else fail "$name is not an SVG"; fi
    if [[ "$(sha256sum "$f" | cut -d' ' -f1)" != "$stock" ]]; then pass "$name is not Ubuntu's stock file"; else fail "$name is still Ubuntu's stock wordmark (GNOME 50's Settings > About shows it)"; fi
    if grep -q -i -a '#e95420' "$f"; then fail "$name still has Ubuntu orange (#e95420) in it"; else pass "$name has no Ubuntu orange"; fi
    if divert_ok "/usr/share/pixmaps/$name" && stock_copy_listed "/usr/share/pixmaps/$name"; then
        pass "$name is dpkg-diverted (base-files cannot restore Ubuntu's)"
    else
        fail "$name is not dpkg-diverted to $name.ubuntu-stock (a base-files upgrade would restore Ubuntu's wordmark)"
    fi
    if [[ $CANON_OK -eq 1 ]]; then
        MONO_ABOUT="${CANON_MARK%/*}/mark-mono.svg"
        if [[ "$mode" == light ]]; then fill="$CI_LIGHT_PRIMARY"; else fill="$CI_DARK_PRIMARY"; fi
        n_paths=0; n_missing=0
        while IFS= read -r dattr; do
            n_paths=$((n_paths + 1))
            grep -q -F -a -- "$dattr" "$f" || n_missing=$((n_missing + 1))
        done < <(grep -o ' d="[^"]*"' "$MONO_ABOUT")
        if [[ $n_paths -ge 1 && $n_missing -eq 0 ]]; then pass "$name carries all $n_paths paths of the vendored one-colour mark"
        else fail "$name lacks $n_missing of the $n_paths paths of the vendored one-colour mark (vendor/brand/logos/mark-mono.svg)"; fi
        if grep -q -i -a -- "${fill}" "$f" && ! grep -q -a 'currentColor' "$f"; then pass "$name is filled with the canon primary of $mode mode ($fill)"
        else fail "$name is not filled with the canon primary of $mode mode ($fill), or still says currentColor"; fi
    fi
done

# An image build keeps no backup directories of the stock files (10-plymouth.sh and 40-start-icon.sh skip them
# under CI_BRAND_IMAGE_BUILD=1): they would ship Ubuntu's watermark, Plymouth configs and icons inside the image,
# and their timestamped names make the squashfs differ from build to build.
if in_listing ' /usr/share/(plymouth/ci-branding-backup-|icons/ubuntu-backup-|backgrounds/ubuntu-backup-)'; then
    fail "the image ships a backup directory of stock Ubuntu files (plymouth/ci-branding-backup-*, icons/ubuntu-backup-*): an image build keeps none"
else
    pass "the image ships no backup directories of stock Ubuntu files"
fi

# The dock's bottom button is view-app-grid-ubuntu-symbolic.svg, a symlink to Yaru's start-here-symbolic.svg.
# 40-start-icon.sh generates it from the vendored one-colour mark: the mark's own path data, currentColor, no brand hex.
YARU_START="$R/usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg"
if [[ ! -f "$YARU_START" ]]; then
    fail "Yaru start-here-symbolic.svg missing"
elif file_has "$YARU_START" 'viewBox="0 0 16 16"'; then
    fail "Yaru start-here-symbolic.svg is still Ubuntu's (viewBox 0 0 16 16)"
elif [[ $CANON_OK -eq 1 ]]; then
    n_paths=0; n_missing=0
    while IFS= read -r dattr; do
        n_paths=$((n_paths + 1))
        grep -qF -- "$dattr" "$YARU_START" || n_missing=$((n_missing + 1))
    done < <(grep -o ' d="[^"]*"' "$CANON_MARK")
    if [[ $n_paths -ge 1 && $n_missing -eq 0 ]]; then
        pass "Yaru start-here-symbolic.svg carries all $n_paths paths of the vendored mark (dock Show Applications button)"
    else
        fail "Yaru start-here-symbolic.svg lacks $n_missing of the $n_paths paths of the vendored mark (vendor/brand/logos/mark.svg)"
    fi
    # The crop (40-start-icon.sh's START_ICON_VIEWBOX is a constant cut for the 1.0.0 mark) must lie inside the mark's own
    # canvas and keep its ink. The path check above cannot see a clipped icon: all the paths are there, only part of
    # them is inside the viewBox.
    MONO_MARK="${CANON_MARK%/*}/mark-mono.svg"
    icon_vb="$(sed -n 's/.*viewBox="\([^"]*\)".*/\1/p' "$YARU_START" | head -1 | tr -s ' ,' ' ')"
    mark_vb="$(sed -n 's/.*viewBox="\([^"]*\)".*/\1/p' "$MONO_MARK" 2>/dev/null | head -1 | tr -s ' ,' ' ')"
    if awk -v i="$icon_vb" -v m="$mark_vb" 'BEGIN { na = split(i, a, " "); nb = split(m, b, " ");
           exit !(na == 4 && nb == 4 && a[3] > 0 && a[4] > 0 && a[1] >= b[1] && a[2] >= b[2] && a[1] + a[3] <= b[1] + b[3] + 0.001 && a[2] + a[4] <= b[2] + b[4] + 0.001) }'; then
        pass "Yaru start-here-symbolic.svg crop ($icon_vb) lies inside the vendored mark's canvas ($mark_vb)"
    else
        fail "Yaru start-here-symbolic.svg viewBox '${icon_vb:-none}' is not inside the vendored mark's canvas '${mark_vb:-none}' (START_ICON_VIEWBOX in 40-start-icon.sh was cut for another mark)"
    fi
    if command -v rsvg-convert >/dev/null 2>&1 && [[ -f "$PNGTOOL" && -f "$MONO_MARK" ]] && [[ -n "$icon_vb" && -n "$mark_vb" ]]; then
        ink_dir="$WORK/start-icon-ink"; mkdir -p "$ink_dir"
        read -r _ _ mark_w _ <<<"$mark_vb"; read -r _ _ icon_w _ <<<"$icon_vb"
        # the same pixels per unit for both renders, so the opaque pixel counts are comparable
        icon_px="$(awk -v w="$icon_w" -v m="$mark_w" 'BEGIN { printf "%d", 1024 * w / m + 0.5 }')"
        if rsvg-convert -w 1024 -f png -o "$ink_dir/mark.png" "$MONO_MARK" 2>/dev/null \
           && rsvg-convert -w "$icon_px" -f png -o "$ink_dir/icon.png" "$YARU_START" 2>/dev/null; then
            mark_ink="$(png_tool info "$ink_dir/mark.png" 2>/dev/null | awk '$1 == "opaque" { print $2 }')"
            icon_ink="$(png_tool info "$ink_dir/icon.png" 2>/dev/null | awk '$1 == "opaque" { print $2 }')"
            if [[ "${mark_ink:-0}" -gt 0 && "${icon_ink:-0}" -gt 0 ]] && (( icon_ink * 100 >= mark_ink * 99 )); then
                pass "Yaru start-here-symbolic.svg keeps the whole mark inside its crop (${icon_ink} of ${mark_ink} opaque pixels at the same scale)"
            else
                fail "Yaru start-here-symbolic.svg clips the mark: ${icon_ink:-0} of ${mark_ink:-0} opaque pixels survive its crop (re-derive START_ICON_VIEWBOX in 40-start-icon.sh)"
            fi
        else
            note "the start icon crop was not rendered (rsvg-convert could not draw the icon or the mark)"
        fi
    else
        note "start icon crop not rendered: needs rsvg-convert and the repo checkout (the viewBox containment above is still checked)"
    fi
    ramp_found=""
    while IFS= read -r hex; do
        if grep -qi -- "$hex" "$YARU_START"; then ramp_found="$ramp_found $hex"; fi
    done < <(grep -o 'fill:#[0-9a-fA-F]\{6\}' "$CANON_MARK" | sed 's/fill://')
    if [[ -z "$ramp_found" ]]; then
        pass "Yaru start-here-symbolic.svg ships none of the logo artwork's colours (GTK repaints a symbolic icon; brand hexes belong in the artwork only)"
    else
        fail "Yaru start-here-symbolic.svg ships logo artwork colours:$ramp_found (40-start-icon.sh builds it from mark-mono.svg, currentColor)"
    fi
fi
if divert_ok /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg; then
    pass "Yaru start-here-symbolic.svg is dpkg-diverted (yaru-theme-icon cannot restore Ubuntu's)"
else
    fail "Yaru start-here-symbolic.svg is not dpkg-diverted (a yaru-theme-icon upgrade would restore Ubuntu's)"
fi
if in_listing ' /usr/share/icons/Yaru/scalable/actions/view-app-grid-ubuntu-symbolic\.svg -> \.\./places/start-here-symbolic\.svg$'; then
    pass "the dock button icon (view-app-grid-ubuntu-symbolic.svg) still points at start-here-symbolic.svg"
else
    fail "view-app-grid-ubuntu-symbolic.svg no longer points at places/start-here-symbolic.svg (the dock button would not show the mark)"
fi

# os-release says LOGO=ci-os-logo, so that name must resolve to an icon, and the icon cache must know it.
check "os-release has LOGO=ci-os-logo" file_has "$R/usr/lib/os-release" '^LOGO=ci-os-logo$'
LOGO_ICON="$R/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
if [[ -s "$LOGO_ICON" ]] && in_listing ' /usr/share/icons/hicolor/scalable/apps/ci-os-logo\.svg$'; then pass "icon ci-os-logo exists (hicolor scalable apps)"; else fail "icon ci-os-logo.svg missing: LOGO=ci-os-logo resolves to nothing"; fi
if [[ -f "$R/usr/share/icons/hicolor/icon-theme.cache" ]]; then
    if grep -q -a 'ci-os-logo' "$R/usr/share/icons/hicolor/icon-theme.cache"; then pass "hicolor icon-theme.cache lists ci-os-logo"; else fail "hicolor icon-theme.cache is stale: it does not list ci-os-logo (gtk-update-icon-cache did not run)"; fi
else
    note "hicolor has no icon-theme.cache (GTK scans the directory)"
fi
# The icon is the vendored canon mark itself (45-about-logo.sh installs mark.svg verbatim, and setup-device ships the
# same bytes for its launcher entry), so compare it with the vendored file, not with a literal copied from the image.
if [[ -s "$LOGO_ICON" && $CANON_OK -eq 1 ]]; then
    if cmp -s "$LOGO_ICON" "$CANON_MARK"; then
        pass "icon ci-os-logo.svg is the vendored canon mark (vendor/brand/logos/mark.svg), byte for byte"
    else
        fail "icon ci-os-logo.svg differs from vendor/brand/logos/mark.svg"
    fi
fi

# The Hub launcher entry (setup-device's payload): the canon icon, and the canon product name as its label. The
# Companion Launcher .deb ships its own plain "Companion Hub" entry, so this browser entry is "Companion Hub (browser)".
HUB_DESKTOP="$R/usr/share/applications/ci-os-hub.desktop"
check "Hub launcher entry uses the ci-os-logo icon" file_has "$HUB_DESKTOP" '^Icon=ci-os-logo$'
check "Hub launcher entry is labelled Companion Hub (Name=)" file_has "$HUB_DESKTOP" '^Name=Companion Hub( \(browser\))?$'
check "Hub launcher entry text has no 'CI OS' spelling (Name= and Comment=)" \
    bash -c "grep -E '^(Name|Comment)(\[[^]]*\])?=' '$HUB_DESKTOP' | grep -q . && ! grep -E '^(Name|Comment)(\[[^]]*\])?=' '$HUB_DESKTOP' | grep -qiE 'CI[ -]?OS'"

# The greeter reads logo= from the gdm dconf database; the file is the 256 px colour mark, not the 1.6 MB hologram.
check "GDM login dconf points the greeter logo at companion-logo.png" file_has "$R/etc/dconf/db/gdm.d/01-ci-os-login" "^logo='/usr/share/pixmaps/companion-logo\\.png'\$"
GREETER_LOGO="$R/usr/share/pixmaps/companion-logo.png"
if [[ -f "$GREETER_LOGO" ]]; then
    w="$(png_width "$GREETER_LOGO")"; sz="$(wc -c < "$GREETER_LOGO")"
    if [[ "$w" == 256 && "$sz" -lt 200000 ]]; then
        pass "greeter logo companion-logo.png is 256px wide, ${sz} bytes"
    else
        fail "greeter logo companion-logo.png is ${w:-unknown}px wide and ${sz} bytes (want 256px, the old ci-holo-depth.png is 1597257 bytes)"
    fi
    # The colour mark: the opaque pixels are exactly the three tones of the vendored mark.svg.
    if [[ $CANON_OK -eq 1 ]] && png_is "$GREETER_LOGO"; then
        canon_png "greeter logo companion-logo.png" "$GREETER_LOGO" palette "$(logo_ramp)" ""
    elif ! png_is "$GREETER_LOGO"; then
        fail "greeter logo companion-logo.png is not a PNG"
    fi
else
    fail "greeter logo /usr/share/pixmaps/companion-logo.png missing"
fi

section "4c. Visible names (sessions, Settings panel, extensions)"
# 60-visible-names.sh renames the display strings Ubuntu still showed after the logos: the session in GDM's gear menu,
# the Settings sidebar entry (gnome-ubuntu-panel.desktop) and the names of three shell extensions. Ubuntu 26.04.1 has exactly one
# session, /usr/share/wayland-sessions/ubuntu.desktop (no /usr/share/xsessions, no ubuntu-xorg.desktop, no ubuntu-wayland.desktop, no
# Xorg server): this build must not make a second one up, and a stray file would be a way to log in to a session nobody tested. What the session and
# the shell find them by must stay Ubuntu's, and is asserted as hard as the names: a session whose file name, Exec= or
# DesktopNames= changed does not log in, a panel without OnlyShowIn=ubuntu; vanishes, and an extension whose uuid no
# longer matches its directory is not loaded. The stock files are diverted so a package upgrade cannot restore them.
listed() { grep -q -x -F -- "$1" "$BASE_PATHS"; } # a file at exactly this path in the image (BASE_PATHS: every path of the listing, a link's " -> target" dropped)
has_line() { grep -q -x -F -- "$2" "$1" 2>/dev/null; }                     # has_line <file> <whole line>
json_field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2" 2>/dev/null; }
SESSION_ENTRIES=(
    "/usr/share/wayland-sessions/ubuntu.desktop|Companion OS"
)
session_name_bad=""
for entry in "${SESSION_ENTRIES[@]}"; do
    f="${entry%%|*}"; want="${entry#*|}"
    if ! listed "$f"; then fail "session file missing (its file name is the session id, so it must stay): $f"; continue; fi
    grep -E '^Name=' "$R$f" 2>/dev/null | grep -q -v -E '^Name=Companion OS( |$)' && session_name_bad="$session_name_bad $f"
    if has_line "$R$f" "Name=$want" && [[ "$(grep -c -E '^Name=' "$R$f")" == 1 ]] && has_line "$R$f" "Comment=This session logs you into Companion OS"; then
        pass "$f is named '$want' (Name=, Comment=)"
    else
        fail "$f is not named '$want': $(grep -E '^(Name|Comment)=' "$R$f" 2>/dev/null | tr '\n' '|')"
    fi
    # GNOME 50 / Ubuntu 26.04.1: the session starts gnome-session directly (no env GNOME_SHELL_SESSION_MODE wrapper any more) and is
    # tried by gnome-session, not gnome-shell.
    if has_line "$R$f" "Exec=/usr/bin/gnome-session --session=ubuntu" \
       && has_line "$R$f" "TryExec=/usr/bin/gnome-session" && file_has "$R$f" '^DesktopNames=ubuntu;GNOME;?$'; then
        pass "$f keeps its session identifiers (Exec=/usr/bin/gnome-session --session=ubuntu, TryExec=/usr/bin/gnome-session, DesktopNames=ubuntu;GNOME)"
    else
        fail "$f lost an identifier the session starts by: $(grep -E '^(Exec|TryExec|DesktopNames)=' "$R$f" 2>/dev/null | tr '\n' '|')"
    fi
    if divert_ok "$f" && listed "$f.ubuntu-stock"; then
        pass "$f is dpkg-diverted (an ubuntu-session upgrade cannot restore Ubuntu's name)"
    else
        fail "$f is not dpkg-diverted to $f.ubuntu-stock (an ubuntu-session upgrade would restore Ubuntu's name)"
    fi
done
if [[ -z "$session_name_bad" ]]; then
    pass "every Name= in the session file starts with 'Companion OS'"
else
    fail "a Name= in a session file does not start with 'Companion OS':$session_name_bad"
fi
# exactly one selectable session: the file above (and its diverted stock copy), nothing in xsessions, no other wayland session
session_extra="$(listing_paths "$LISTING" | grep -E '^/usr/share/(xsessions|wayland-sessions)/[^/]+$' | grep -v -x -e '/usr/share/wayland-sessions/ubuntu.desktop' -e '/usr/share/wayland-sessions/ubuntu.desktop.ubuntu-stock' | tr '\n' ' ' || true)"
if [[ -z "$session_extra" ]]; then pass "exactly one session file exists (/usr/share/wayland-sessions/ubuntu.desktop; Ubuntu 26.04.1 has no Xorg session)"
else fail "other session files exist: ${session_extra% } (26.04.1 has the one Wayland session only)"; fi

PANEL="/usr/share/applications/gnome-ubuntu-panel.desktop"
if ! listed "$PANEL"; then
    fail "Settings sidebar entry file missing: $PANEL"
else
    if has_line "$R$PANEL" "Name=Companion OS Desktop" && has_line "$R$PANEL" "Comment=Companion OS Desktop Appearance Settings"; then
        pass "Settings sidebar entry is 'Companion OS Desktop' (gnome-ubuntu-panel.desktop Name=, Comment=)"
    else
        fail "Settings sidebar entry is not 'Companion OS Desktop': $(grep -E '^(Name|Comment)=' "$R$PANEL" 2>/dev/null | tr '\n' '|')"
    fi
    if has_line "$R$PANEL" "Exec=gnome-control-center ubuntu" && has_line "$R$PANEL" "OnlyShowIn=ubuntu;"; then
        pass "Settings panel keeps its id (Exec=gnome-control-center ubuntu, OnlyShowIn=ubuntu;)"
    else
        fail "Settings panel lost its id (Exec= or OnlyShowIn=): $(grep -E '^(Exec|OnlyShowIn)=' "$R$PANEL" 2>/dev/null | tr '\n' '|')"
    fi
    if divert_ok "$PANEL" && listed "$PANEL.ubuntu-stock"; then
        pass "$PANEL is dpkg-diverted (a gnome-control-center upgrade cannot restore Ubuntu's name)"
    else
        fail "$PANEL is not dpkg-diverted to $PANEL.ubuntu-stock (a gnome-control-center upgrade would restore Ubuntu's name)"
    fi
fi

for entry in "ubuntu-dock@ubuntu.com|Companion OS Dock" "ubuntu-appindicators@ubuntu.com|Companion OS AppIndicators" "tiling-assistant@ubuntu.com|Companion OS Tiling Assistant"; do
    uuid="${entry%%|*}"; want="${entry#*|}"; f="/usr/share/gnome-shell/extensions/$uuid/metadata.json"
    if ! listed "$f"; then fail "extension metadata missing: $f"; continue; fi
    got_name="$(json_field "$R$f" name)"; got_uuid="$(json_field "$R$f" uuid)"
    if [[ "$got_name" == "$want" ]]; then
        pass "extension $uuid is named '$want' (metadata.json is valid JSON)"
    else
        fail "extension $uuid is named '${got_name:-<unreadable: not valid JSON or no name>}', want '$want'"
    fi
    if [[ "$got_uuid" == "$uuid" ]]; then
        pass "extension $uuid keeps its uuid (it matches the directory name)"
    else
        fail "extension uuid in $f is '${got_uuid:-<unreadable>}', must equal its directory name '$uuid'"
    fi
    if divert_ok "$f" && listed "$f.ubuntu-stock"; then
        pass "$f is dpkg-diverted (an extension package upgrade cannot restore Ubuntu's name)"
    else
        fail "$f is not dpkg-diverted to $f.ubuntu-stock (an extension package upgrade would restore Ubuntu's name)"
    fi
done

section "4d. GNOME Shell theme (the Ubuntu session and the GDM greeter)"
# Two files on Ubuntu 26.04.1 are called gnome-shell-theme.gresource and they are different things (backends/ubuntu/lib/shell-theme.sh has the story):
#   theme/Yaru/gnome-shell-theme.gresource   what the Ubuntu session (modes/ubuntu.json) and the GDM greeter (gdm-theme.gresource -> /etc/alternatives
#                                            -> this file) load: it must be the branded blob, which is the Yaru theme recoloured;
#   gnome-shell-theme.gresource (top level)  the UPSTREAM theme, which the session modes without a theme of their own load (GNOME Shell 50's built-in
#                                            modes, initial-setup): it must keep gnome-shell-light.css, which the branded blob does not have, or those
#                                            modes throw "No valid stylesheet found".
# The build used to copy the one blob over both. Step 2b of customize-chroot.sh installs the branded one over the Yaru file always and over the upstream one
# only when it provides every resource, and a missing blob is only a warning there, so nothing but this section notices an image that is unthemed or that has
# lost the stylesheets (found by the review of the port: neither state failed the build or the verify).
YARU_GRES="$R/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
TOP_GRES="$R/usr/share/gnome-shell/gnome-shell-theme.gresource"
BRANDED_GRES="$VERIFY_REPO/backends/ubuntu/packages/ci-os-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
STOCK_YARU_GRES_SHA=da1d2019b8f5c498d1d5570e8bfd0ef33445153095ebad77ba34802b29e384ac   # yaru-theme-gnome-shell 26.04.5.1: the file of the 26.04.1 ISO
gres_lists() { # gres_lists <gresource> <file name>: the gresource has a theme resource of that name. A gresource keeps its resource names as plain
               # text, so without the gresource tool (libglib2.0-bin) the name is looked up in the bytes (weaker: it also matches the Yaru/ copy of a name)
    local out
    if command -v gresource >/dev/null 2>&1 && out="$(gresource list "$1" 2>/dev/null)" && [[ -n "$out" ]]; then
        grep -q -x -F -- "/org/gnome/shell/theme/$2" <<<"$out"
    else
        grep -a -q -F -- "$2" "$1" 2>/dev/null
    fi
}
if [[ ! -s "$YARU_GRES" ]]; then
    fail "GNOME Shell theme: /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource is missing (the Ubuntu session and the greeter have no theme)"
else
    yaru_sha="$(sha256sum "$YARU_GRES" | cut -d' ' -f1)"
    if [[ "$yaru_sha" == "$STOCK_YARU_GRES_SHA" ]]; then
        fail "GNOME Shell theme: the Ubuntu session's gresource is Ubuntu's stock Yaru theme, byte for byte: the branded theme was not installed (Step 2b of customize-chroot.sh only warns when the blob is missing)"
    else
        pass "GNOME Shell theme: the Ubuntu session's gresource (theme/Yaru/gnome-shell-theme.gresource) is not Ubuntu's stock Yaru theme"
    fi
    if [[ -f "$BRANDED_GRES" ]]; then
        if [[ "$yaru_sha" == "$(sha256sum "$BRANDED_GRES" | cut -d' ' -f1)" ]]; then
            pass "GNOME Shell theme: theme/Yaru/gnome-shell-theme.gresource is the branded blob of this checkout, byte for byte ($yaru_sha)"
        else
            fail "GNOME Shell theme: theme/Yaru/gnome-shell-theme.gresource ($yaru_sha) is not the branded blob of this checkout (ci-os-branding/.../Yaru/gnome-shell-theme.gresource, $(sha256sum "$BRANDED_GRES" | cut -d' ' -f1)): built from another checkout, or replaced after the theme step"
        fi
    else
        skip "the check that the Yaru gresource is this checkout's branded blob: run this script from the repo checkout (backends/ubuntu/packages/ci-os-branding)"
    fi
fi
if [[ ! -s "$TOP_GRES" ]]; then
    fail "GNOME Shell theme: /usr/share/gnome-shell/gnome-shell-theme.gresource (the upstream theme, gnome-shell-common's) is missing"
else
    top_missing=""
    for css in gnome-shell-light.css gnome-shell-dark.css; do gres_lists "$TOP_GRES" "$css" || top_missing="$top_missing $css"; done
    if [[ -z "$top_missing" ]]; then
        pass "GNOME Shell theme: the upstream gnome-shell-theme.gresource still has gnome-shell-light.css and gnome-shell-dark.css (the built-in session modes load them)"
    else
        fail "GNOME Shell theme: the upstream gnome-shell-theme.gresource lost${top_missing} (the branded Yaru blob was copied over it): the built-in session modes and initial-setup would throw 'No valid stylesheet found'"
    fi
fi
if in_listing ' /usr/share/gnome-shell/gdm-theme\.gresource -> /etc/alternatives/gdm-theme\.gresource$' \
   && in_listing ' /etc/alternatives/gdm-theme\.gresource -> /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme\.gresource$'; then
    pass "GNOME Shell theme: the greeter's gdm-theme.gresource still resolves, through /etc/alternatives, to the Yaru file that carries the branded theme"
else
    fail "GNOME Shell theme: gdm-theme.gresource no longer leads, through /etc/alternatives, to theme/Yaru/gnome-shell-theme.gresource (the greeter would not show the branded theme)"
fi

section "5. Branding: boot menu"
check "GRUB menu says Companion OS" file_has "$ISOX/grub.cfg" 'menuentry "Try or Install Companion OS"'
# /.disk/info is data that several readers take apart, and one of them puts it on a screen. The stock line is
# `Ubuntu 26.04.1 LTS "Resolute Raccoon" - Release amd64 (20260826)`; the build writes `Companion OS 26.04.1 LTS "Resolute Raccoon" - Release amd64 (...)`.
# What each reader does with it (read from the 26.04.1 stock initrd and the installer snap, rev 665):
#   the installer's last page   ubuntu_bootstrap's ProductService reads /cdrom/.disk/info and the page says "<name> is installed and ready to use": the text
#                               before the quote is on screen ("Companion-OS 24.04.5 LTS is installed and ready to use" in the recorded 24.04.5 run, written
#                               with a hyphen in this file). So the name is spelt "Companion OS" here, the product's name. (The first page and the review page
#                               say "Ubuntu" whatever this file says: the known residue below.)
#   casper 25adduser            the installer launcher's label "Install RELEASE": fields 1-2 with `-` as a blank, plus " LTS" if field 3 is "LTS". With a
#                               blank in the name, field 3 is the release, so the launcher reads "Install Companion OS" (no release, no LTS: shorter, nothing lost).
#   casper scripts/casper       field 1 lower-cased is the live user and host unless casper.conf sets FLAVOUR, which this image's does (section 7).
#   subiquity refresh.py        the SECOND word is "the release" its snap channel is named after: "OS" gives stable/ubuntu-OS. configure_snapd switches the
#                               channel only when the installer snap tracks stable/ubuntu-<release of the live system>; the 26.04.1 seed has it on
#                               26.04/stable/ubuntu-26.04.1, so it returns before it uses the word. That is asserted below from the image's own seed.yaml.
#   pollinate                   the trailing "(serial)".
check "/.disk/info starts with 'Companion OS', the release and LTS (no hyphen: the installer's last page shows this text)" bash -c "head -1 '$ISOX/disk-info' | grep -q -E '^Companion OS [0-9]+\\.[0-9]+(\\.[0-9]+)? LTS '"
check "/.disk/info keeps the (serial) suffix pollinate parses" bash -c "head -1 '$ISOX/disk-info' | grep -q -E '\\([0-9.]+\\)\\s*\$'"
disk_info_first="$(head -n 1 "$ISOX/disk-info" 2>/dev/null)"
# the product name the installer's last page shows: everything before the codename's quote
disk_name="$(printf '%s\n' "$disk_info_first" | sed 's/[[:space:]]*".*$//')"
if [[ "$disk_name" =~ ^Companion\ OS\ [0-9]+\.[0-9]+(\.[0-9]+)?\ LTS$ ]]; then pass "/.disk/info: the installer's last page reads '$disk_name is installed and ready to use' (Companion OS, no hyphen on screen)"
else fail "/.disk/info: the product name before the codename is '${disk_name:-nothing}': the installer's last page would show it as '<that> is installed and ready to use' (want 'Companion OS <release> LTS')"; fi
# the installer launcher's label, computed the way casper's 25adduser does (LTS from field 3, RELEASE from fields 1-2 with `-` as a blank)
disk_lts="$(printf '%s\n' "$disk_info_first" | cut -d' ' -f3)"
disk_label="$(printf '%s\n' "$disk_info_first" | cut -d' ' -f1-2 | sed 's/-/ /')"
if [[ "$disk_lts" == LTS && -n "$disk_label" ]]; then disk_label="$disk_label LTS"; fi
if [[ "$disk_label" =~ ^Companion\ OS(\ [0-9]+\.[0-9]+(\.[0-9]+)?(\ LTS)?)?$ ]]; then pass "/.disk/info: casper's launcher label reads 'Install $disk_label' (Companion OS, no hyphen on screen)"
else fail "/.disk/info: casper would label the installer launcher 'Install ${disk_label:-nothing}' (want 'Install Companion OS')"; fi
# subiquity: the second word of the line is "the release". If it is one, the channel it names is right; if it is not ("OS"), the channel logic must never get that far.
disk_info_word2="$(printf '%s\n' "$disk_info_first" | awk '{ print $2 }')"
live_release="$(sed -n 's/^DISTRIB_RELEASE=//p' "$R/etc/lsb-release" 2>/dev/null | head -n 1 | tr -d '"')"
installer_channel="$(awk '
    function flush() { if (nm == "ubuntu-desktop-bootstrap") print ch; nm = ""; ch = "" }
    /^[[:space:]]*-[[:space:]]*($|[A-Za-z])/ { flush() }
    { line = $0; sub(/^[[:space:]]*-?[[:space:]]*/, "", line) }
    line ~ /^name:/    { nm = line; sub(/^name:[[:space:]]*/, "", nm); gsub(/["'\''[:space:]]/, "", nm) }
    line ~ /^channel:/ { ch = line; sub(/^channel:[[:space:]]*/, "", ch); gsub(/["'\''[:space:]]/, "", ch) }
    END { flush() }' "$LR/var/lib/snapd/seed/seed.yaml" 2>/dev/null | head -n 1)"
if [[ "$disk_info_word2" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    pass "/.disk/info: the second word is the release ($disk_info_word2), which subiquity names its snap channel after (stable/ubuntu-$disk_info_word2)"
elif [[ -z "$live_release" || -z "$installer_channel" ]]; then
    fail "/.disk/info: the second word is '${disk_info_word2:-nothing}', not a release, and the installer snap's channel (live layer seed.yaml: '${installer_channel:-none}') or the release (lsb-release: '${live_release:-none}') cannot be read, so it is not shown that subiquity never acts on it"
elif [[ "$installer_channel" == "stable/ubuntu-$live_release" || "$installer_channel" == "latest/stable/ubuntu-$live_release" ]]; then
    fail "/.disk/info: the second word is '$disk_info_word2' and the installer snap tracks $installer_channel: subiquity's refresh.py would switch it to the channel stable/ubuntu-$disk_info_word2 (it only leaves the channel alone when the snap tracks something else)"
else
    pass "/.disk/info: the second word is '$disk_info_word2' and subiquity's refresh.py never uses it: the installer snap tracks $installer_channel, not stable/ubuntu-$live_release, and it switches channel only for the latter"
fi
check "no Ubuntu in any GRUB menu entry title" bash -c "! grep -E '^\s*menuentry' '$ISOX/grub.cfg' '$ISOX/loopback.cfg' | grep -q -i ubuntu"
# The ISO volume id is NOT renamed: the signed GRUB and casper find the medium by it (renaming it stops the EFI boot). It is also what
# the user sees as the medium's label, so it stays "Ubuntu 26.04.1 LTS amd64" on purpose (listed under the known residues below).
if [[ -n "${VERIFY_BASE_ISO:-}" && -f "$VERIFY_BASE_ISO" ]]; then
    BASE_VOLID="$(xorriso -indev "$VERIFY_BASE_ISO" -pvd_info 2>&1 | sed -n 's/^Volume Id *: *//p' | head -1)"
    if [[ -n "$BASE_VOLID" && "$PVD_VOLID" == "$BASE_VOLID" ]]; then pass "the ISO volume id is the base ISO's ('$PVD_VOLID'), which the signed GRUB and casper look for"
    else fail "the ISO volume id '$PVD_VOLID' is not the base ISO's '${BASE_VOLID:-?}' (a changed label stops the medium from being found)"; fi
fi

# The live menu is themed (build-iso.sh brand_live_grub): the navy background with the mark, colours derived from
# the tokens, and only the modules the signed GRUB has built in (any other insmod is refused under Secure Boot).
BG_ISO="$ISOX/ci-os-bg.png"
if [[ -s "$BG_ISO" ]] && png_is "$BG_ISO"; then
    d="$(png_depth "$BG_ISO")"; w="$(png_width "$BG_ISO")"
    if [[ "$d" == 8 ]]; then pass "live GRUB background /boot/grub/ci-os-bg.png is a PNG with 8-bit depth"; else fail "live GRUB background has IHDR bit depth ${d:-unknown} (want 8)"; fi
    if [[ -n "$w" && "$w" -ge 1280 ]]; then pass "live GRUB background is ${w}px wide"; else fail "live GRUB background is ${w:-unknown}px wide (want >= 1280)"; fi
else
    fail "live GRUB background /boot/grub/ci-os-bg.png is missing or not a PNG (the live menu is still stock text GRUB)"
fi
check "grub.cfg loads the background (background_image /boot/grub/ci-os-bg.png)" file_has "$ISOX/grub.cfg" '^[[:space:]]*background_image /boot/grub/ci-os-bg\.png$'
check "grub.cfg draws the menu with gfxterm (terminal_output gfxterm)" file_has "$ISOX/grub.cfg" '^[[:space:]]*terminal_output gfxterm$'
# Exactly the modules build-iso.sh's block names (gfxterm, png) ...
insmods="$(grep -E '^[[:space:]]*insmod[[:space:]]' "$ISOX/grub.cfg" | awk '{ for (i = 2; i <= NF; i++) print $i }' | sort -u | tr '\n' ' ')"
if [[ "$insmods" == "gfxterm png " ]]; then
    pass "grub.cfg insmods exactly gfxterm and png"
else
    fail "grub.cfg insmod set is '${insmods:-none}' (want 'gfxterm png': build-iso.sh's block; all_video is NOT among them, Ubuntu 26.04.1's signed GRUB does not have it built in)"
fi
# ... and every one of them is compiled into the signed GRUB this ISO boots (the CD image, /EFI/boot/grubx64.efi: Secure Boot refuses a
# module loaded from disk, so GRUB prints an error at every boot). Read from the binary on the ISO itself, with the same tool that
# fetch-signed-boot.sh uses for the stick; given VERIFY_BASE_ISO that binary is the stock one (byte-identical, below), so this is the stock
# image's list. The producer and this check once agreed on all_video while the real binary has no such module.
GRUB_MODS_TOOL="$VERIFY_REPO/stick/scripts/grub-builtin-modules.py"
if [[ ! -s "$ISOX/grubx64.efi" ]]; then
    fail "grub.cfg's insmod modules could not be compared with the signed GRUB: /EFI/boot/grub$EFIS.efi is missing from the ISO"
elif [[ ! -f "$GRUB_MODS_TOOL" ]] || ! command -v python3 >/dev/null 2>&1; then
    skip "the grub.cfg insmod modules are not compared with the signed GRUB's built-in list: run this script from the repo checkout (stick/scripts/grub-builtin-modules.py) with python3"
elif [[ -z "$insmods" ]]; then
    note "grub.cfg has no insmod line: nothing to compare with the signed GRUB's built-in modules"
else
    mods_out="$(python3 -I "$GRUB_MODS_TOOL" "$ISOX/grubx64.efi" --require "$(printf '%s' "${insmods% }" | tr ' ' ',')" 2>&1)"; mods_rc=$?
    if [[ "$mods_rc" -eq 0 ]]; then
        mods_n="$(sed -n 's/.*(\([0-9][0-9]*\) in total).*/\1/p' <<<"$mods_out")"
        pass "every module grub.cfg insmods (${insmods% }) is built into the signed GRUB on the ISO (/EFI/boot/grub$EFIS.efi has ${mods_n:-?} built-in modules)"
    elif [[ "$mods_rc" -eq 1 ]]; then
        fail "grub.cfg insmods a module that is NOT built into the signed GRUB on the ISO (${mods_out##*: }); under Secure Boot shim refuses a module loaded from disk"
    else
        fail "the built-in modules of /EFI/boot/grub$EFIS.efi could not be read: ${mods_out}"
    fi
fi
if [[ -f "$VERIFY_REPO/core/lib/grub-merge.sh" && -f "$VERIFY_REPO/vendor/brand/tokens/tokens.sh" ]]; then
    # shellcheck source=../../../../core/lib/grub-merge.sh
    source "$VERIFY_REPO/core/lib/grub-merge.sh"
    # shellcheck source=../../../../vendor/brand/tokens/tokens.sh
    source "$VERIFY_REPO/vendor/brand/tokens/tokens.sh"
    # menu_color_normal is white/black, which the stock ISO's grub.cfg already had, so it passes on an unthemed menu and
    # shows nothing by itself; the highlight, background_image, gfxterm and insmod checks above and below are what tell a
    # themed menu from a stock one. And both sides use ci_grub_nearest_color, so core/lib/tests/grub-nearest-color.sh is
    # what checks that function's table.
    want_normal="$(ci_grub_nearest_color "$CI_DARK_FOREGROUND")/black"
    want_highlight="black/$(ci_grub_nearest_color "$CI_ACCENT_AQUA")"
    have_normal="$(sed -n 's/^set menu_color_normal=//p' "$ISOX/grub.cfg" | head -1)"
    have_highlight="$(sed -n 's/^set menu_color_highlight=//p' "$ISOX/grub.cfg" | head -1)"
    if [[ "$have_highlight" == "$want_highlight" ]]; then pass "menu_color_highlight is $have_highlight (nearest GRUB colour to the accent aqua)"; else fail "menu_color_highlight is '${have_highlight:-unset}', the tokens give $want_highlight"; fi
    if [[ "$have_normal" == "$want_normal" ]]; then pass "menu_color_normal is $have_normal (nearest GRUB colour to the dark foreground)"; else fail "menu_color_normal is '${have_normal:-unset}', the tokens give $want_normal"; fi
else
    skip "the GRUB menu colour checks (re-derived from the tokens): run this script from the repo checkout (core/lib/grub-merge.sh, vendor/brand/tokens/tokens.sh)"
fi

# The installed system's GRUB background is rendered by the same script and must be the same kind of file.
GRUB_BG_ROOT="$R/usr/share/pixmaps/ci-os-grub-bg.png"
if [[ "$VARCH" == arm64 && ! -e "$R/etc/default/grub" ]]; then
    note "installed-system GRUB background: not made on arm64 (no GRUB in the base image to configure)"
elif [[ -f "$GRUB_BG_ROOT" ]] && png_is "$GRUB_BG_ROOT"; then
    d="$(png_depth "$GRUB_BG_ROOT")"
    if [[ "$d" == 8 ]]; then pass "installed-system GRUB background (/usr/share/pixmaps/ci-os-grub-bg.png) has 8-bit depth"; else fail "installed-system GRUB background has IHDR bit depth ${d:-unknown} (want 8)"; fi
else
    fail "installed-system GRUB background /usr/share/pixmaps/ci-os-grub-bg.png is missing or not a PNG"
fi

# Secure Boot: theming edits grub.cfg and adds one data file; the signed binaries must be the stock bytes.
if [[ -n "${VERIFY_BASE_ISO:-}" && -f "$VERIFY_BASE_ISO" ]]; then
    BASEX="$WORK/base"; mkdir -p "$BASEX"
    xorriso -osirrox on -indev "$VERIFY_BASE_ISO" \
        -extract "/EFI/boot/boot$EFIS.efi" "$BASEX/bootx64.efi" \
        -extract "/EFI/boot/grub$EFIS.efi" "$BASEX/grubx64.efi" \
        -extract "/EFI/boot/mm$EFIS.efi" "$BASEX/mmx64.efi" >/dev/null 2>&1
    for f in bootx64.efi grubx64.efi mmx64.efi; do
        if [[ -s "$ISOX/$f" && -s "$BASEX/$f" && "$(sha256sum < "$ISOX/$f")" == "$(sha256sum < "$BASEX/$f")" ]]; then
            pass "Secure Boot chain: /EFI/boot/$f is byte-identical to the base ISO's"
        else
            fail "Secure Boot chain: /EFI/boot/$f differs from the base ISO's, or is missing from one of them"
        fi
    done
elif [[ -n "${VERIFY_BASE_ISO:-}" ]]; then
    fail "VERIFY_BASE_ISO is set but is not a file: $VERIFY_BASE_ISO"
else
    note "Secure Boot chain not compared with a stock ISO (skipped: set VERIFY_BASE_ISO=<stock Ubuntu ISO>)"
fi

section "6. Branding: desktop defaults (wallpaper / picker)"
check "dconf user profile reads the system 'local' db (without it local.d is ignored)" file_has "$R/etc/dconf/profile/user" '^system-db:local$'
check "wallpaper default comes from a schema override that sorts after Ubuntu's" bash -c "ls '$R'/usr/share/glib-2.0/schemas/ | grep -q -E '^9[0-9]_.*companion.*\.gschema\.override$'"
check "wallpaper override points at the Companion wallpaper" bash -c "grep -h picture-uri '$R'/usr/share/glib-2.0/schemas/9*_*companion*.override | grep -q ci-os-wallpaper"
# GNOME only loads *.xml; a dpkg-diverted "*.xml.disabled" is not offered.
check "Ubuntu wallpaper collections are not offered in Settings" bash -c "! ls '$R'/usr/share/gnome-background-properties 2>/dev/null | grep -E '\\.xml\$' | grep -q -i -E 'ubuntu|resolute'"

# The dock (the left GNOME bar): the image's default is the list in backends/ubuntu/chroot/dock-favorites.txt, written by
# customize-chroot.sh into the local dconf db. Checked against the same list, so editing the list and not rebuilding fails here.
DOCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../chroot"
DOCK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/dock-favorites.sh"
if [[ -f "$DOCK_DIR/dock-favorites.txt" && -f "$DOCK_LIB" ]]; then
    # shellcheck source=../../lib/dock-favorites.sh
    source "$DOCK_LIB"
    DOCK_WANT="$(dock_favorites_value "$DOCK_DIR/dock-favorites.txt" 2>/dev/null || true)"
    DOCK_FILE="$R/etc/dconf/db/local.d/02-ci-os-dock"
    check "dock default is written to the local dconf db (02-ci-os-dock)" test -s "$DOCK_FILE"
    dock_file_is_the_list() { [[ -n "$DOCK_WANT" ]] && grep -qxF -- "favorite-apps=$DOCK_WANT" "$DOCK_FILE"; }
    check "dock default is exactly the committed list" dock_file_is_the_list
    # dconf compiles local.d into one binary file; the ids are stored as plain strings, so a stale or failed
    # 'dconf update' (the build tolerates its failure) shows up as a missing id here.
    for _d in 'Companion Hub.desktop' 'companion-capture.desktop' 'companion-docs.desktop' 'org.gnome.Ptyxis.desktop'; do
        check "dock default is compiled into the local dconf db: $_d" grep -aqF "$_d" "$R/etc/dconf/db/local"
    done
    # Canonical's installer is not in the dock: "Install Companion OS (automatic)" is the only installer there (the live-session hook pins it first);
    # the stock one is in the application grid and behind the dialog's "Use the normal installer" button.
    for _d in ubuntu-desktop-bootstrap_ubuntu-desktop-bootstrap.desktop firefox_firefox.desktop thunderbird_thunderbird.desktop libreoffice-writer.desktop snap-store_snap-store.desktop org.gnome.Yelp.desktop org.gnome.Rhythmbox3.desktop net.nokyan.Resources.desktop; do
        check "dock default does not pin $_d" bash -c "! grep -qF '$_d' '$DOCK_FILE'"
    done
else
    skip "dock default (backends/ubuntu/chroot/dock-favorites.txt or backends/ubuntu/lib/dock-favorites.sh not found next to this script)"
fi

# The Companion links (backends/ubuntu/chroot/start-links.txt): an application-menu entry for each, a desktop shortcut in
# /etc/skel/Desktop for each "yes" row (executable, as the desktop only launches executable shortcuts), and the one-time welcome.
LINKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../chroot"
LINKS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/start-links.sh"
if [[ -f "$LINKS_DIR/start-links.txt" && -f "$LINKS_LIB" ]]; then
    # shellcheck source=../../lib/start-links.sh
    source "$LINKS_LIB"
    LINKS_ROWS="$(start_links_rows "$LINKS_DIR/start-links.txt" 2>/dev/null || true)"
    check "the links list is valid" test -n "$LINKS_ROWS"
    while IFS='|' read -r _id _name _url _comment _icon _desktop; do
        [[ -n "$_id" ]] || continue
        check "link entry /usr/share/applications/$_id.desktop opens $_url" grep -qxF "Exec=xdg-open $_url" "$R/usr/share/applications/$_id.desktop"
        if [[ "$_desktop" == yes ]]; then
            check "desktop shortcut /etc/skel/Desktop/$_id.desktop exists and is executable" test -x "$R/etc/skel/Desktop/$_id.desktop"
        else
            check "no desktop shortcut for $_id (menu only)" test ! -e "$R/etc/skel/Desktop/$_id.desktop"
        fi
    done <<<"$LINKS_ROWS"
    check "first-login welcome script is installed and executable" test -x "$R/usr/libexec/ci-os/welcome-once"
    check "first-login welcome script skips a live session" grep -qF 'CI_OS_WELCOME_LIVE:-/cdrom/casper/vmlinuz' "$R/usr/libexec/ci-os/welcome-once"
    check "first-login welcome autostart entry runs it, hidden, for GNOME" bash -c "grep -qx 'Exec=/usr/libexec/ci-os/welcome-once' '$R/etc/xdg/autostart/ci-os-welcome.desktop' && grep -qx 'NoDisplay=true' '$R/etc/xdg/autostart/ci-os-welcome.desktop'"
else
    skip "Companion links (backends/ubuntu/chroot/start-links.txt or backends/ubuntu/lib/start-links.sh not found next to this script)"
fi

# The first run and the login text are Companion OS's. Canonical's first-run (gnome-initial-setup) is skipped by a stamp in
# /etc/skel; the motd scripts that advertise Ubuntu Pro are held off by dpkg-statoverride (an upgrade restores a plain chmod -x);
# /etc/legal says Companion OS; the first-boot setup is started by its timer, not at boot, and waits for a quiet machine.
check "first-run: /etc/skel/.config/gnome-initial-setup-done exists (no Canonical first-run for a new user)" test -e "$R/etc/skel/.config/gnome-initial-setup-done"
# gnome-initial-setup-upgrade-login.service shows "Welcome to <release>!" (the raccoon) when the stamp above exists and the stamp it
# names itself does not: found on the first installed arm64 image, 2026-10-19. The stamp's name is read from the unit in the image.
_gis_unit="$R/usr/lib/systemd/user/gnome-initial-setup-upgrade-login.service"
if [[ -f "$_gis_unit" ]]; then
    _gis_stamp="$(sed -n 's|^ConditionPathExists=!%E/\(gnome-initial-setup/upgrade-[0-9.]*-done\)$|\1|p' "$_gis_unit" | head -n 1)"
    check "first-run: the upgrade-login unit names a stamp (${_gis_stamp:-none})" test -n "$_gis_stamp"
    check "first-run: /etc/skel/.config/${_gis_stamp:-<none>} exists (no 'Welcome to Companion OS' page after the first sign-in)" test -n "$_gis_stamp" -a -e "$R/etc/skel/.config/$_gis_stamp"
else
    note "gnome-initial-setup-upgrade-login.service is not in this image: no upgrade-welcome stamp is needed"
fi

# The first-login unit is the one that shows Canonical's wizard (welcome, Ubuntu Pro, Location Services, Help improve Ubuntu, Appearance, Ready to go): it
# is skipped by the stamp its own ConditionPathExists=! names. The stamp is written into /etc/skel by customize-chroot.sh as a literal; reading the name from
# the unit in the image makes a base that renames it fail here instead of at the first sign-in.
_gis_first="$R/usr/lib/systemd/user/gnome-initial-setup-first-login.service"
if [[ -f "$_gis_first" ]]; then
    _gis_first_stamps="$(sed -n 's|^ConditionPathExists=!%E/\(.*\)$|\1|p' "$_gis_first" | tr '\n' ' ')"
    check "first-run: gnome-initial-setup-first-login.service is skipped by a stamp (${_gis_first_stamps% })" test -n "$_gis_first_stamps"
    _gis_first_missing=""
    for _s in $_gis_first_stamps; do [[ -e "$R/etc/skel/.config/$_s" ]] || _gis_first_missing="$_gis_first_missing $_s"; done
    check "first-run: /etc/skel/.config holds every stamp that unit names (so Canonical's Ubuntu Pro, location and usage pages are not shown)${_gis_first_missing:+ - missing:$_gis_first_missing}" test -z "$_gis_first_missing" -a -n "$_gis_first_stamps"
else
    note "gnome-initial-setup-first-login.service is not in this image: no first-run wizard to skip"
fi

# The rest of a quiet first sign-in (found on the first installed arm64 image, 2026-10-19): Firefox opens no "Firefox Privacy Notice" tab
# (an enterprise policy, which the snap reads through its etc-firefox interface), the update notifier does not announce the build day's
# pending packages, and ci-os-info offers the ROCm command only where that command exists.
check "quiet first sign-in: /etc/firefox/policies/policies.json is JSON with the four policies" python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))["policies"]
assert p == {"DisableTelemetry": True, "OverrideFirstRunPage": "", "OverridePostUpdatePage": "", "DontCheckDefaultBrowser": True}, p
' "$R/etc/firefox/policies/policies.json"
check "quiet first sign-in: the update notifier's pop-ups are off by default (dconf local.d)" grep -q -F 'no-show-notifications=true' "$R/etc/dconf/db/local.d/03-ci-os-quiet-first-run"
check "ci-os-info: reports the setup, Hub, models and health, not only the GPU" grep -q -F 'Hub:      answering at' "$R/usr/local/bin/ci-os-info"
check "ci-os-info: the ROCm command is offered only behind a check for it (arm64 has none)" bash -c 'grep -q "command -v ci-os-install-rocm" "$1" && ! grep -q "^echo \"For ROCm installation" "$1"' _ "$R/usr/local/bin/ci-os-info"
for _m in 00-header 10-help-text 50-motd-news 91-contract-ua-esm-status; do
    check "login text: motd script $_m is held off by dpkg-statoverride" grep -q -E "^root root 644 /etc/update-motd\\.d/$_m\$" "$R/var/lib/dpkg/statoverride"
done
check "login text: /etc/legal names Companion OS" grep -q -F 'Companion OS comes with ABSOLUTELY NO WARRANTY' "$R/etc/legal"
check "login text: /etc/legal no longer says 'Ubuntu comes with'" bash -c "! grep -q 'Ubuntu comes with' '$R/etc/legal'"
check "login text: the stock /etc/legal is diverted aside (a base-files upgrade cannot bring it back)" grep -q -F '/etc/legal' "$R/var/lib/dpkg/diversions"
check "login text: the Ubuntu Pro autostart notification is diverted aside" bash -c "grep -q 'ubuntu-advantage-notification.desktop' '$R/var/lib/dpkg/diversions' && test ! -e '$R/etc/xdg/autostart/ubuntu-advantage-notification.desktop'"
check "first boot: the setup is started by its timer at 3 minutes, not linked into multi-user.target" bash -c "grep -q -x 'OnBootSec=3min' '$R/usr/lib/systemd/system/ci-os-first-boot-setup.timer' && test ! -e '$R/etc/systemd/system/multi-user.target.wants/ci-os-first-boot-setup.service'"
check "first boot: wait-quiet is installed and executable" test -x "$R/usr/libexec/ci-os/wait-quiet"
check "first boot progress: setup-progress is installed, executable, and skips a live session" bash -c "test -x '$R/usr/libexec/ci-os/setup-progress' && grep -qF 'CI_OS_PROGRESS_LIVE:-/cdrom/casper/vmlinuz' '$R/usr/libexec/ci-os/setup-progress'"
check "first boot progress: its autostart entry runs it, hidden, for GNOME" bash -c "grep -qx 'Exec=/usr/libexec/ci-os/setup-progress' '$R/etc/xdg/autostart/ci-os-setup-progress.desktop' && grep -qx 'NoDisplay=true' '$R/etc/xdg/autostart/ci-os-setup-progress.desktop' && grep -qx 'OnlyShowIn=GNOME;' '$R/etc/xdg/autostart/ci-os-setup-progress.desktop'"
check "first boot progress: the status library is in the bootstrap tree, and the wrapper and provision.sh use it" bash -c "test -f '$R/usr/lib/ci-os/bootstrap/core/lib/setup-status.sh' && grep -qF 'export CI_OS_SETUP_STATUS=\"/var/lib/ci-os/setup-status\"' '$R/usr/lib/ci-os/first-boot-setup.sh' && grep -qF 'ci_os_status_step \"Downloading the AI models' '$R/usr/lib/ci-os/bootstrap/backends/ubuntu/provision/provision.sh'"
# The library is run here, on the host that built and verifies the image (Ubuntu 26.04: uutils tr and date), against the file the first boot writes.
_ss="$WORK/setup-status-check"; rm -rf "$_ss"; mkdir -p "$_ss"
check "first boot progress: the library writes the status file the desktop reads (state, step, steps, title; world-readable; one line each)" bash -c "
  export CI_OS_SETUP_STATUS='$_ss/status'; . '$R/usr/lib/ci-os/bootstrap/core/lib/setup-status.sh' && ci_os_status_begin 7 && ci_os_status_step 'Installing Docker' &&
  grep -qx 'state=running' '$_ss/status' && grep -qx 'step=1' '$_ss/status' && grep -qx 'steps=7' '$_ss/status' && grep -qx 'title=Installing Docker' '$_ss/status' &&
  test \"\$(grep -c . '$_ss/status')\" = 6 && test \"\$(stat -c %a '$_ss/status')\" = 644"

section "6b. Ubuntu Pro does not prompt, and nothing reports to Canonical"
# The properties live in backends/ubuntu/lib/quiet-canonical.sh (ci_quiet_audit), next to the code that makes them true, and
# backends/ubuntu/lib/tests/quiet-canonical.sh shows each of them failing on a root that lacks it. They are read here from the files extracted
# from the installed layer (the paths are in the extraction list above). An image is never attached to a subscription: a machine token baked
# into it would be a credential in the image, and would make the audit leave the Pro client alone as it does on an attached machine.
QUIET_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/quiet-canonical.sh"
if [[ -f "$QUIET_LIB" ]]; then
    # shellcheck source=../../lib/quiet-canonical.sh
    source "$QUIET_LIB"
    check "no Ubuntu Pro machine token is baked into the image (an image is never attached)" bash -c "! grep -q -E 'var/lib/ubuntu-advantage/private/machine-token\\.json' '$LISTING'"
    while IFS= read -r _q; do
        case "$_q" in
            "ok "*) pass "${_q#ok }" ;;
            "bad "*) fail "${_q#bad }" ;;
            "info "*) note "${_q#info }" ;;
        esac
    done < <(ci_quiet_audit "$R")
    if in_listing ' /etc/apt/apt.conf.d/20apt-esm-hook\.conf\.disabled$'; then
        check "Canonical: the Pro client's apt hook is a registered local diversion (an upgrade of the package cannot bring it back)" \
            grep -q -x '/etc/apt/apt.conf.d/20apt-esm-hook.conf' "$R/var/lib/dpkg/diversions"
    else
        note "the Pro client's apt hook (20apt-esm-hook.conf.disabled) is not in this image: nothing was diverted"
    fi
else
    skip "Ubuntu Pro and telemetry audit (backends/ubuntu/lib/quiet-canonical.sh not found next to this script)"
fi

section "7. Branding: live boot splash and live identity (initrd)"
# build-iso.sh appends a small zstd-compressed cpio overlay to casper/initrd (the kernel unpacks concatenated
# archives in order and later files win). unmkinitramfs stops after the first compressed segment, so it cannot
# see the overlay; find and unpack it the way the kernel will: the last zstd frame that decodes to a cpio.
OVL="$WORK/overlay.cpio"; OVLX="$WORK/overlay"; mkdir -p "$OVLX"
found_overlay=""; OVL_OFF=""
while read -r off; do
    [[ -n "$off" ]] || continue
    if tail -c +$((off + 1)) "$ISOX/initrd" | zstd -dc > "$OVL" 2>/dev/null \
       && [[ "$(head -c6 "$OVL")" == "070701" ]] \
       && cpio -t < "$OVL" 2>/dev/null | grep -q '^etc/casper\.conf$'; then
        found_overlay=1; OVL_OFF="$off"; break
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
if [[ -f "$WM_ROOT" ]]; then
    w="$(png_width "$WM_ROOT")"
    # Ubuntu's own watermark is 248 px wide; the design is the banner at 50% (512 px). A 1024 px logo means
    # the scaling step was skipped (no ImageMagick on the build host).
    if [[ -n "$w" && "$w" -le 600 ]]; then pass "Plymouth logo is splash-sized (${w}px wide)"; else fail "Plymouth logo is ${w:-unknown}px wide (full-size banner; install imagemagick on the build host)"; fi
fi
# The live session's splash is drawn from the Plymouth files INSIDE the initrd, which never reads the rootfs copies, so the
# overlay carries its own: bgrt.plymouth and spinner.plymouth (the ground and the progress bar), ubuntu-text.plymouth (the
# safe-graphics splash) and bgrt-fallback.png (installed and diverted; the plugin only draws it if a theme asks for the firmware
# background again, which ci_plymouth_recolor switches off, see below). They are the
# initrd's own files repainted (build-iso.sh brand_initrd_plymouth), so the Font= lines are still Ubuntu's, the only fonts
# that initrd carries. The colours are the canon's, derived from the repo's tokens like the logo checks above. The files
# are checked, not a screen: that the plugin then DRAWS the ground is shown by tests/plymouth-ground-render.sh (the real
# plugin rendering in an X server) and, on the live framebuffer, only by a boot of the ISO.
PLY_T="usr/share/plymouth/themes"
if [[ -n "$found_overlay" ]]; then
    ovl_files="$(cd "$OVLX" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | paste -sd' ' -)"
    ovl_want="etc/casper.conf $PLY_T/bgrt/bgrt.plymouth $PLY_T/spinner/bgrt-fallback.png $PLY_T/spinner/spinner.plymouth $PLY_T/spinner/watermark.png $PLY_T/ubuntu-text/ubuntu-text.plymouth"
    ovl_want="$(printf '%s\n' $ovl_want | LC_ALL=C sort | paste -sd' ' -)"
    if [[ "$ovl_files" == "$ovl_want" ]]; then
        pass "initrd overlay carries exactly the branded files: casper.conf, the bgrt, spinner and text-splash themes, the watermark and bgrt-fallback.png (the 26.04.1 initrd has no ubuntu-logo.png to replace)"
    else
        fail "initrd overlay files are not the expected set (have: ${ovl_files:-none}; want: $ovl_want)"
    fi
fi
if [[ $CANON_OK -eq 1 ]]; then
    ply_ground="$(ci_hex0x "$CI_DARK_BACKGROUND")"; ply_fill="$(ci_hex0x "$CI_DARK_PRIMARY")"
    ply_track="$(ci_hex0x "$CI_DARK_SECONDARY")"
    for where in "initrd overlay:$OVLX" "rootfs:$R"; do
        for theme in bgrt spinner; do
            conf="${where#*:}/$PLY_T/$theme/$theme.plymouth"; label="$theme.plymouth (${where%%:*})"
            if [[ ! -f "$conf" ]]; then fail "$label missing"; continue; fi
            if grep -q -x "BackgroundStartColor=$ply_ground" "$conf" && grep -q -x "BackgroundEndColor=$ply_ground" "$conf"; then
                pass "$label: ground is the canon dark background ($ply_ground)"
            else
                fail "$label: ground is not the canon dark background $ply_ground ($(grep -h '^BackgroundStartColor=' "$conf" | head -1))"
            fi
            if grep -q -x "ProgressBarForegroundColor=$ply_fill" "$conf" && grep -q -x "ProgressBarBackgroundColor=$ply_track" "$conf"; then
                pass "$label: progress bar is the canon primary on the canon secondary ($ply_fill on $ply_track)"
            else
                fail "$label: progress bar is not the canon primary $ply_fill on $ply_track ($(grep -h '^ProgressBarForegroundColor=' "$conf" | head -1))"
            fi
        done
    done
    check "bgrt.plymouth (initrd overlay) keeps the stock font, the only one the initrd carries" \
        file_has "$OVLX/$PLY_T/bgrt/bgrt.plymouth" '^Font=Ubuntu 12$'
else
    note "Plymouth colours not checked against the canon: run this script from the repo checkout (vendor/brand/tokens)"
fi
# What the plugin DRAWS. BackgroundStartColor is only the ground if no section of the theme asks for the firmware
# background: the two-step plugin then paints a hard-coded black behind the firmware's boot logo (or bgrt-fallback.png), so
# an image with the navy colour lines above and UseFirmwareBackground=true in [boot-up], [shutdown] and [reboot] (what was built
# before 4382caa) showed black.
# ci_plymouth_recolor switches the key off in every section, for the overlay's copy and the rootfs copy alike.
# Plymouth's parser accepts blanks around the "=" and the values 1, y, yes and true (any case) as "on".
ply_asks_firmware() { grep -q -i -E '^[[:space:]]*UseFirmwareBackground[[:space:]]*=[[:space:]]*(1|y|yes|true)[[:space:]]*$' "$1"; }
ply_fw_modes() { # ply_fw_modes <theme file>: the value of UseFirmwareBackground in the three sections stock bgrt sets it in
    awk '
        { line = $0; gsub(/[ \t]/, "", line) }
        line ~ /^\[/ { sec = substr(line, 2, length(line) - 2); next }
        line ~ /^UseFirmwareBackground=/ { v[sec] = tolower(substr(line, index(line, "=") + 1)) }
        END { printf "boot-up=%s shutdown=%s reboot=%s\n", ("boot-up" in v ? v["boot-up"] : "unset"), ("shutdown" in v ? v["shutdown"] : "unset"), ("reboot" in v ? v["reboot"] : "unset") }' "$1"
}
ply_drawn_ground() { # ply_drawn_ground <theme file>: what the screen is filled with in the boot-up mode
    if ply_asks_firmware "$1"; then echo "black behind the firmware logo"; else awk '/^BackgroundStartColor=/ { bg = substr($0, index($0, "=") + 1) } END { print bg }' "$1"; fi
}
for where in "initrd overlay:$OVLX" "rootfs:$R"; do
    for theme in bgrt spinner; do
        conf="${where#*:}/$PLY_T/$theme/$theme.plymouth"; label="$theme.plymouth (${where%%:*})"
        [[ -f "$conf" ]] || continue
        if ! ply_asks_firmware "$conf"; then
            pass "$label: no section asks for the firmware background (UseFirmwareBackground: $(ply_fw_modes "$conf")), so the plugin fills the screen with BackgroundStartColor"
        else
            fail "$label: a section asks for the firmware background ($(ply_fw_modes "$conf")): the plugin paints black behind the firmware logo whatever BackgroundStartColor says"
        fi
        if [[ $CANON_OK -eq 1 ]]; then
            if [[ "$(ply_drawn_ground "$conf")" == "$ply_ground" ]]; then
                pass "$label: the ground drawn at boot is the canon dark background ($ply_ground)"
            else
                fail "$label: the ground drawn at boot is '$(ply_drawn_ground "$conf")', not the canon dark background $ply_ground"
            fi
        fi
    done
done
if [[ -f "$OVLX/$PLY_T/bgrt/bgrt.plymouth" ]]; then
    check "bgrt.plymouth (initrd overlay) sets UseFirmwareBackground=false in boot-up, shutdown and reboot (the key is there and off, not just missing)" \
        test "$(ply_fw_modes "$OVLX/$PLY_T/bgrt/bgrt.plymouth")" = "boot-up=false shutdown=false reboot=false"
fi
# The live boot and the installed system must look the same: the two copies of each theme are the same keys and values,
# only the fonts differ (the initrd has no Cantarell).
for theme in bgrt spinner; do
    a="$OVLX/$PLY_T/$theme/$theme.plymouth"; b="$R/$PLY_T/$theme/$theme.plymouth"
    [[ -f "$a" && -f "$b" ]] || continue
    ply_diff="$(diff <(grep -v -E '^(Font|TitleFont)=' "$a") <(grep -v -E '^(Font|TitleFont)=' "$b") 2>&1 | head -n 4 | tr '\n' ' ')"
    if [[ -z "$ply_diff" ]]; then
        pass "$theme.plymouth: the live (initrd overlay) and installed (rootfs) copies have the same keys and values apart from the fonts"
    else
        fail "$theme.plymouth: the live and installed copies differ apart from the fonts: $ply_diff"
    fi
done
ply_default="$(readlink "$R/etc/alternatives/default.plymouth" 2>/dev/null || true)"
if [[ "$ply_default" == "/$PLY_T/bgrt/bgrt.plymouth" ]]; then
    pass "installed system: the default Plymouth theme is bgrt, the one that is branded"
else
    fail "installed system: the default Plymouth theme is '${ply_default:-not set}', not the branded bgrt"
fi
OVL_TEXT="$OVLX/$PLY_T/ubuntu-text/ubuntu-text.plymouth"
if [[ -f "$OVL_TEXT" ]]; then
    check "text splash (initrd overlay) is titled Companion OS, not Ubuntu 26.04" file_has "$OVL_TEXT" '^title=Companion OS( [0-9][^ ]*)?$'
    check "text splash (initrd overlay) is no longer aubergine (0x2c001e)" bash -c "! grep -q -i '0x2c001e' '$OVL_TEXT'"
    if [[ $CANON_OK -eq 1 ]]; then
        # black= is the ground the text console is cleared to: the canon's dark background, like the graphical themes.
        check "text splash (initrd overlay) ground is the canon dark background ($ply_ground)" file_has "$OVL_TEXT" "^black=$ply_ground\$"
        check "text splash (installed system) ground is the canon dark background ($ply_ground)" file_has "$TEXT_PLYMOUTH" "^black=$ply_ground\$"
    fi
    ovl_title="$(grep -h '^title=' "$OVL_TEXT" 2>/dev/null | head -1)"
    root_title="$(grep -h '^title=' "$TEXT_PLYMOUTH" 2>/dev/null | head -1)"
    if [[ -n "$ovl_title" && "$ovl_title" == "$root_title" ]]; then
        pass "text splash title is the same in the initrd overlay and the installed system ($ovl_title)"
    else
        fail "text splash title differs: initrd overlay '${ovl_title:-none}', installed system '${root_title:-none}'"
    fi
else
    fail "no ubuntu-text.plymouth in the initrd overlay (the safe-graphics splash is still 'Ubuntu 26.04' on aubergine)"
fi
# bgrt-fallback.png: Ubuntu's own file is the 128 px logo in a circle of friends (this is its sha256).
STOCK_BGRT_FALLBACK_SHA=0d4f041619618c5202a2c30509e2552fb96c283a86d27cb17bc356fe54a13215
FB_INITRD="$OVLX/$PLY_T/spinner/bgrt-fallback.png"
FB_ROOT="$R/$PLY_T/spinner/bgrt-fallback.png"
if [[ -f "$FB_INITRD" && -f "$FB_ROOT" ]]; then
    if [[ "$(sha256sum "$FB_INITRD" | cut -d' ' -f1)" == "$(sha256sum "$FB_ROOT" | cut -d' ' -f1)" ]]; then
        pass "firmware-logo fallback (initrd overlay) is the same file as the installed system's"
    else
        fail "firmware-logo fallback in the initrd overlay differs from the rootfs one"
    fi
    for where in "initrd overlay:$FB_INITRD" "rootfs:$FB_ROOT"; do
        f="${where#*:}"; label="bgrt-fallback.png (${where%%:*})"
        if ! png_is "$f"; then fail "$label is not a PNG"; continue; fi
        if [[ "$(png_width "$f")" == 128 && "$(png_height "$f")" == 128 ]]; then pass "$label is 128x128, the size of Ubuntu's"; else fail "$label is $(png_width "$f")x$(png_height "$f") (Ubuntu's is 128x128)"; fi
        if [[ "$(sha256sum "$f" | cut -d' ' -f1)" != "$STOCK_BGRT_FALLBACK_SHA" ]]; then pass "$label is not Ubuntu's stock logo"; else fail "$label is still Ubuntu's stock logo"; fi
    done
    if [[ $CANON_OK -eq 1 ]]; then canon_png "bgrt-fallback.png (firmware-logo fallback)" "$FB_ROOT" palette "$(logo_ramp)" ""; fi
else
    fail "bgrt-fallback.png missing (initrd overlay: $([[ -f "$FB_INITRD" ]] && echo present || echo missing), rootfs: $([[ -f "$FB_ROOT" ]] && echo present || echo missing))"
fi
# Every Plymouth file the build rewrites belongs to a Plymouth package: diverted, so an upgrade of the package unpacks
# Ubuntu's file to <file>.ubuntu-stock and cannot bring Ubuntu's logo or colours back (or rebuild the initramfs with them).
# The text theme itself, ubuntu-text.plymouth, is no package's file: plymouth-theme-ubuntu-text's postinst regenerates it
# from the template ubuntu-text.plymouth.in on every configure and whenever /etc/lsb-release changes, so it is the
# template that is diverted and branded.
for f in spinner/bgrt-fallback.png spinner/watermark.png bgrt/bgrt.plymouth spinner/spinner.plymouth ubuntu-text/ubuntu-text.plymouth.in; do
    p="/$PLY_T/$f"
    if divert_ok "$p" && stock_copy_listed "$p"; then
        pass "$f is dpkg-diverted (a plymouth package upgrade cannot restore Ubuntu's)"
    else
        fail "$f is not dpkg-diverted to $f.ubuntu-stock (a package upgrade would restore Ubuntu's file)"
    fi
done
TEXT_TEMPLATE="$R/$PLY_T/ubuntu-text/ubuntu-text.plymouth.in"
if [[ -f "$TEXT_TEMPLATE" ]]; then
    root_template_title="$(grep -h '^title=' "$TEXT_TEMPLATE" 2>/dev/null | head -1)"
    check "text splash template is titled Companion OS and not aubergine (the postinst regenerates the text theme from it)" \
        bash -c "grep -q -E '^title=Companion OS( [0-9][^ ]*)?\$' '$TEXT_TEMPLATE' && ! grep -q -i '0x2c001e' '$TEXT_TEMPLATE'"
    if [[ -n "$root_template_title" && "$root_template_title" == "$(grep -h '^title=' "$TEXT_PLYMOUTH" 2>/dev/null | head -1)" ]]; then
        pass "text splash template has the same title as the installed text theme ($root_template_title)"
    else
        fail "text splash template title '${root_template_title:-none}' differs from the installed text theme's"
    fi
else
    fail "no ubuntu-text.plymouth.in in the rootfs (a trigger would regenerate the text theme without it)"
fi

# The overlay is appended to the initrd and nothing else is touched: the stock archives before it are the base ISO's bytes,
# then NUL padding to a 4-byte boundary (the kernel skips it between archives), then the overlay's zstd frame to the end of
# the file. Without the base ISO the layout is still checked: the overlay sits 4-byte aligned after the stock part.
if [[ -n "$OVL_OFF" ]]; then
    if [[ "$OVL_OFF" -gt 0 && $((OVL_OFF % 4)) -eq 0 ]]; then
        pass "initrd layout: the overlay is appended 4-byte aligned, at byte $OVL_OFF"
    else
        fail "initrd layout: the overlay is not appended 4-byte aligned after the stock part (byte ${OVL_OFF})"
    fi
    if [[ -n "${VERIFY_BASE_ISO:-}" && -f "$VERIFY_BASE_ISO" ]]; then
        if xorriso -osirrox on -indev "$VERIFY_BASE_ISO" -extract /casper/initrd "$ISOX/base-initrd" >/dev/null 2>&1 && [[ -s "$ISOX/base-initrd" ]]; then
            base_size="$(wc -c < "$ISOX/base-initrd")"; base_pad=$(( (4 - base_size % 4) % 4 ))
            if cmp -s -n "$base_size" "$ISOX/initrd" "$ISOX/base-initrd"; then
                pass "the stock part of the initrd is byte-identical to the base ISO's ($base_size bytes)"
            else
                fail "the first $base_size bytes of casper/initrd differ from the base ISO's initrd: the stock archives were modified, not appended to"
            fi
            if [[ "$OVL_OFF" -eq $((base_size + base_pad)) ]] \
               && [[ -z "$(tail -c +$((base_size + 1)) "$ISOX/initrd" | head -c "$base_pad" | tr -d '\0')" ]]; then
                pass "the overlay starts right after the stock initrd and its ${base_pad} NUL padding bytes"
            else
                fail "the overlay is not at byte $((base_size + base_pad)) (stock size $base_size + padding $base_pad); it is at ${OVL_OFF}"
            fi
        else
            fail "could not extract /casper/initrd from VERIFY_BASE_ISO ($VERIFY_BASE_ISO)"
        fi
    else
        note "stock initrd not compared with the base ISO's (skipped: set VERIFY_BASE_ISO=<stock Ubuntu ISO>)"
    fi
fi
# The no-tool fallback in render-grub-background.sh leaves a ~17 byte placeholder, so check the size too.
grub_bg_size="$(awk '$NF == "/usr/share/pixmaps/ci-os-grub-bg.png" {print $3; exit}' "$LISTING")"
if [[ "$VARCH" == arm64 && ! -e "$R/etc/default/grub" ]]; then
    note "GRUB background image of the installed system: not made on arm64 (the live menu's background is /boot/grub/ci-os-bg.png, checked above)"
elif [[ -n "$grub_bg_size" && "$grub_bg_size" -ge 5000 ]]; then
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
# The overlay's bgrt.plymouth only matters if the live boot loads that theme. plymouthd takes it from default.plymouth in the
# initrd (the stock plymouthd.conf there names no theme, and the overlay adds none), so unpack the STOCK part of the initrd the way the kernel will see
# it: the base ISO's initrd when given, else the first OVL_OFF bytes without the NUL padding the build added (0 to 3 bytes: the
# last bytes that are NUL are only candidates, and the one cut unmkinitramfs accepts is the stock initrd).
if [[ -n "$OVL_OFF" ]]; then
    if command -v unmkinitramfs >/dev/null 2>&1; then
        SIN="$WORK/stock-initrd"; SX="$WORK/stock-initrd-x"; stock_ok=""
        if [[ -s "$ISOX/base-initrd" ]]; then
            rm -rf "$SX"; mkdir -p "$SX"
            if unmkinitramfs "$ISOX/base-initrd" "$SX" >/dev/null 2>&1; then stock_ok=1; fi
        else
            ply_nul=0
            for b in $(head -c "$OVL_OFF" "$ISOX/initrd" | tail -c 3 | od -An -v -tu1 | awk '{ for (i = NF; i >= 1; i--) print $i }'); do
                if [[ "$b" == 0 ]]; then ply_nul=$((ply_nul + 1)); else break; fi
            done
            for ((pad = ply_nul; pad >= 0; pad--)); do
                head -c $((OVL_OFF - pad)) "$ISOX/initrd" > "$SIN"
                rm -rf "$SX"; mkdir -p "$SX"
                if unmkinitramfs "$SIN" "$SX" >/dev/null 2>&1; then stock_ok=1; break; fi
            done
        fi
        if [[ -n "$stock_ok" ]]; then
            ST="$SX"   # (initramfs-tools 0.151's unmkinitramfs extracts every segment flat into the target; no early/ and main/ directories)
            if [[ "$(readlink "$ST/$PLY_T/default.plymouth" 2>/dev/null)" == "/$PLY_T/bgrt/bgrt.plymouth" ]]; then
                pass "the initrd's default Plymouth theme is bgrt: the theme the overlay repaints is the one the live boot loads"
            else
                fail "the initrd's default.plymouth is '$(readlink "$ST/$PLY_T/default.plymouth" 2>/dev/null || echo missing)', not the bgrt theme the overlay repaints"
            fi
            # What plymouthd's configuration selects, if anything. Ubuntu 26.04.1's own initrd HAS /etc/plymouth/plymouthd.conf, with comments
            # only ("# Administrator customizations go in this file", "#[Daemon]"): no Theme= line, so default.plymouth (bgrt, above) applies.
            # 24.04's initrd had no such file, and a check written for that treated an existing file that lacks a Theme=bgrt line as a failure:
            # it failed on the first real 26.04.1 image. Only an ACTIVE Theme= line naming another theme is a defect.
            ply_conf="$ST/etc/plymouth/plymouthd.conf"
            ply_other="$(awk '/^[[:space:]]*Theme[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); if (v != "bgrt") print "Theme=" v }' "$ply_conf" 2>/dev/null | head -n 3 | tr '\n' ' ')"
            if [[ -z "$ply_other" ]]; then
                if [[ ! -f "$ply_conf" ]]; then ply_note="the initrd has no plymouthd.conf"
                elif grep -q -E '^[[:space:]]*Theme[[:space:]]*=' "$ply_conf"; then ply_note="its plymouthd.conf says Theme=bgrt"
                else ply_note="its plymouthd.conf names no theme, as in Ubuntu 26.04.1's own initrd"; fi
                pass "nothing in the initrd selects another Plymouth theme than bgrt ($ply_note)"
            else
                fail "the initrd's plymouthd.conf selects a theme other than bgrt: ${ply_other% }"
            fi
            ply_plugin="$(find "$ST" -name two-step.so 2>/dev/null | head -n 1)"
            if [[ -n "$ply_plugin" ]] && grep -a -q 'UseFirmwareBackground' "$ply_plugin"; then
                pass "the initrd's two-step plugin reads UseFirmwareBackground (the key the ground depends on)"
            else
                fail "the initrd's two-step plugin was not found or no longer reads UseFirmwareBackground: the key this build switches off may mean something else now"
            fi
        else
            fail "could not unpack the stock part of the initrd with unmkinitramfs (the default theme could not be checked)"
        fi
        rm -rf "$SX" "$SIN"
    else
        skip "initrd default Plymouth theme (needs unmkinitramfs: apt-get install initramfs-tools-core)"
    fi
fi
note "the kernel's acceptance of the appended archive is only proven by booting the ISO (see the QEMU boot check)"

# ── 8. md5sum.txt ───────────────────────────────────────────────────────────
section "8. Disc integrity: md5sum.txt matches the files in the image (casper-md5check)"
# casper-md5check.service, enabled in the live rootfs, runs casper-md5check over /md5sum.txt ("<md5>  ./<path>" per line) on every
# live boot (the 26.04.1 GRUB menu has no entry for it; fsck.mode=skip skips it). It prints "mismatch" for every file whose hash differs
# and counts an error for every file it cannot open. The stock file lists the stock layers, the stock initrd, grub.cfg and
# .disk/info, so it is wrong for every file the remaster changed or deleted (the image built from 584a867 had 14 mismatches,
# 55 missing files and an unlisted background). md5sum-txt.sh verify streams each listed file out of the ISO (xorriso report_lba
# for the extents, then dd | md5sum), so a multi-GB image needs no scratch space (measured: 34 to 37 s for a 7.7 GB image on a native Linux host;
# 1 min 41 s for the 6.4 GB stock 26.04.1 ISO read through a Docker Desktop bind mount, with uutils' dd and md5sum).
# verify MODELS casper-md5check; it is not casper's binary, and UNLISTED below is this script's own policy (casper ignores
# a file that md5sum.txt does not list).
MD5TXT_TOOL="$(dirname "${BASH_SOURCE[0]}")/md5sum-txt.sh"
if [[ -f "$MD5TXT_TOOL" ]]; then
    md5_field() { printf '%s\n' "$md5_summary" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
    bash "$MD5TXT_TOOL" verify "$ISO" > "$WORK/md5-verify.out" 2> "$WORK/md5-verify.err" || true
    md5_summary="$(grep '^SUMMARY ' "$WORK/md5-verify.out" 2>/dev/null | tail -n 1)"
    if [[ -z "$md5_summary" ]]; then
        fail "md5sum.txt could not be checked: $(tail -n 2 "$WORK/md5-verify.err" 2>/dev/null | tr '\n' ' ')"
    else
        md5_n="$(md5_field entries)"
        if [[ "${md5_n:-0}" -gt 0 ]]; then pass "md5sum.txt lists $md5_n files"; else fail "md5sum.txt is empty or missing"; fi
        md5_show() { grep "^$1 " "$WORK/md5-verify.out" | head -n 5 | while IFS= read -r l; do note "  $l"; done; }
        if [[ "$(md5_field mismatched)" == 0 ]]; then
            pass "every file listed in md5sum.txt hashes to its entry ($(md5_field matched) files, streamed out of the image)"
        else
            fail "$(md5_field mismatched) file(s) do not match their md5sum.txt entry (casper-md5check reports them as a mismatch)"; md5_show MISMATCH
        fi
        if [[ "$(md5_field missing)" == 0 ]]; then pass "no md5sum.txt entry names a file that is not in the image"
        else fail "$(md5_field missing) md5sum.txt entr(ies) name a file that is not in the image (the check fails on each)"; md5_show MISSING; fi
        if [[ "$(md5_field unlisted)" == 0 ]]; then pass "every regular file the stock convention lists is in md5sum.txt (all but /md5sum.txt, /boot.catalog and the BIOS boot image eltorito.img)"
        else fail "$(md5_field unlisted) regular file(s) of the image are not in md5sum.txt"; md5_show UNLISTED; fi
        if [[ "$(md5_field duplicate)" == 0 && "$(md5_field malformed)" == 0 ]]; then pass "md5sum.txt has no duplicate and no malformed line"
        else fail "md5sum.txt has $(md5_field duplicate) duplicate and $(md5_field malformed) malformed line(s)"; md5_show DUPLICATE; md5_show BADLINE; fi
    fi
    if [[ -n "${VERIFY_BASE_ISO:-}" && -f "$VERIFY_BASE_ISO" ]]; then
        if md5_stock="$(bash "$MD5TXT_TOOL" check-stock --base-iso "$VERIFY_BASE_ISO" 2>&1)"; then
            pass "the exclusions checked above are the stock ISO's own ($md5_stock)"
        else
            fail "the stock ISO's md5sum.txt does not follow the exclusions checked above: $(printf '%s' "$md5_stock" | head -n 3 | tr '\n' ' ')"
        fi
    else
        note "md5sum.txt exclusions not compared with the stock ISO's (skipped: set VERIFY_BASE_ISO=<stock Ubuntu ISO>)"
    fi
    note "casper-md5check itself is not run here: verify models it (compared with the real binary on a synthetic tree only), so the result on a booted image (journalctl -u casper-md5check, or /run/casper-md5check.json) is still the proof"
else
    skip "md5sum.txt check (md5sum-txt.sh is not next to this script)"
fi

# ── known, unfixable by remastering ─────────────────────────────────────────
section "9. The image fits the smallest Companion Stick boot slot"
# `ci-stick flash` writes the ISO raw into the stick's CI-BOOT-A slot and refuses one that is larger ("boot image ... does not fit"). The slot is
# the stick's usable space / 10, clamped to 8..=48 GiB (ci-stick-layout/1, stick/crates/ci-stick/src/layout.rs), so a 64 GB stick has 8 GiB
# (8,589,934,592 bytes) and a 128 GB one 11 GiB. The stock 26.04.1 ISO is 6.48 GB; an image that grows past 8 GiB (Ollama's CUDA libraries, a
# second language, the encryption variant's seed that remove_esb_seed deletes) could not go onto the 64 GB stick at all, and nothing else would
# say so before someone flashes it. VERIFY_MAX_ISO_BYTES=<n> sets another limit (a build meant for bigger sticks only), 0 turns the check off.
ISO_MAX_BYTES="${VERIFY_MAX_ISO_BYTES:-8589934592}"
ISO_BYTES="$(stat -c %s "$ISO" 2>/dev/null || wc -c < "$ISO" | tr -d ' ')"
if [[ ! "$ISO_MAX_BYTES" =~ ^[0-9]+$ ]]; then
    fail "VERIFY_MAX_ISO_BYTES is not a number: '$ISO_MAX_BYTES'"
elif [[ "$ISO_MAX_BYTES" -eq 0 ]]; then
    note "the image size ($ISO_BYTES bytes) is not compared with a Stick boot slot (VERIFY_MAX_ISO_BYTES=0)"
elif [[ ! "$ISO_BYTES" =~ ^[0-9]+$ ]]; then
    fail "could not read the size of $ISO"
elif [[ "$ISO_BYTES" -le "$ISO_MAX_BYTES" ]]; then
    pass "the image is $ISO_BYTES bytes, within $ISO_MAX_BYTES (the 8 GiB boot slot of a 64 GB Companion Stick); $((ISO_MAX_BYTES - ISO_BYTES)) bytes to spare"
else
    fail "the image is $ISO_BYTES bytes, $((ISO_BYTES - ISO_MAX_BYTES)) over $ISO_MAX_BYTES (the 8 GiB boot slot of a 64 GB Companion Stick): ci-stick flash would refuse it"
fi

section "Known residual Ubuntu strings (cannot be changed by remastering; not counted as failures)"
note "ISO volume id: '${PVD_VOLID:-unknown}' (casper/EFI rely on it, so it stays Ubuntu's)"
note "/.disk/info is now: $(tr -d '\n' < "$ISOX/disk-info" 2>/dev/null) (the product is spelt Companion OS in it, as the installer's last page shows it; the stock field layout is otherwise kept for casper, subiquity and pollinate, see section 5)"
note "installer window text ('Welcome to Ubuntu', 'Erase disk and install Ubuntu', the logo): Canonical snap ubuntu-desktop-bootstrap, fixed text; only its last page ('<product> is installed and ready to use') and the launcher's label come from /.disk/info"
note "ID=ubuntu / DISTRIB_ID=Ubuntu / UBUNTU_CODENAME: required by apt, curtin and tooling"
note "session file name (ubuntu.desktop), DesktopNames=ubuntu, extension uuids (*@ubuntu.com), OnlyShowIn=ubuntu: ids the session and the shell look things up by; only their display names are Companion OS"

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    printf '\n== SKIPPED: %d group(s) of checks did NOT run, so "%d failed" does not cover them:\n' "${#SKIPPED[@]}" "$FAIL"
    printf '   - %s\n' "${SKIPPED[@]}"
    if [[ "${VERIFY_REQUIRE_CANON:-0}" == 1 ]]; then
        echo "   VERIFY_REQUIRE_CANON=1: a run that skipped them fails."
        FAIL=$((FAIL + 1))
    fi
fi
[[ -n "${VERIFY_KEEP:-}" ]] && echo "scratch kept in $WORK"
[[ "$FAIL" -eq 0 ]]
