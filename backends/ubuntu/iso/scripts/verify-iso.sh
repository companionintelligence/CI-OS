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
#      tokens, and only the modules the signed GRUB has built in (all_video, gfxterm, png); and,
#      given VERIFY_BASE_ISO, the Secure Boot EFI binaries are byte-identical to the stock ISO's;
#   2d. the Ubuntu display names that were still on screen read Companion OS: the four sessions in GDM's gear
#      menu, the Settings sidebar entry and the three shell extensions; while the identifiers behind them
#      (session file names, Exec=, DesktopNames=, OnlyShowIn=, extension uuids) are untouched and the stock files
#      are dpkg-diverted;
#   2e. the live boot's Plymouth (section 7): the initrd overlay carries the canon-painted bgrt, spinner and text-splash
#      themes and the firmware-logo fallback, only those files, appended after a stock initrd that is byte-identical
#      to the base ISO's (given VERIFY_BASE_ISO); the installed system's fallback logo is the same file, and every package-owned
#      Plymouth file the build rewrites (the watermark, the bgrt and spinner themes, the text theme's template) is dpkg-diverted;
#   3e. the placeholder casper layers keep the rootfs directory modes (/tmp stays 1777);
#   3f. NetworkManager still manages wired devices (no netplan file overrides the
#      global NetworkManager renderer, which would leave every Ethernet NIC unmanaged).
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
#                          CI_OS_BAKE_OLLAMA=0 CI_OS_BAKE_LAUNCHER=0)
#   VERIFY_BASE_ISO=ISO .. the stock Ubuntu ISO this one was built from: also assert that
#                          /EFI/boot/{bootx64,grubx64,mmx64}.efi are byte-identical to it
#                          (the Secure Boot chain is intact) and that casper/initrd starts with the
#                          stock initrd, byte for byte; without it those checks are skipped
#
# Needs: xorriso squashfs-tools zstd cpio python3 (Ubuntu: apt-get install xorriso squashfs-tools zstd cpio python3);
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
    -extract /casper/install-sources.yaml "$ISOX/install-sources.yaml" \
    -extract /casper/minimal.squashfs "$ISOX/minimal.squashfs" \
    -extract /casper/minimal.standard.squashfs "$ISOX/minimal.standard.squashfs" \
    -extract /casper/minimal.standard.live.squashfs "$ISOX/minimal.standard.live.squashfs" >/dev/null 2>&1
[[ -s "$ISOX/minimal.squashfs" ]] || { echo "could not extract /casper/minimal.squashfs from $ISO" >&2; exit 2; }
# The boot-menu extras, each in its own run: an -extract of a path that is absent (an ISO built before the GRUB
# theming has no ci-os-bg.png) is a FAILURE that aborts the rest of that xorriso command line, and must not hide
# the files after it.
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/ci-os-bg.png "$ISOX/ci-os-bg.png" >/dev/null 2>&1
xorriso -osirrox on -indev "$ISO" \
    -extract /EFI/boot/bootx64.efi "$ISOX/bootx64.efi" \
    -extract /EFI/boot/grubx64.efi "$ISOX/grubx64.efi" \
    -extract /EFI/boot/mmx64.efi "$ISOX/mmx64.efi" >/dev/null 2>&1
PVD_VOLID="$(xorriso -indev "$ISO" -pvd_info 2>&1 | sed -n 's/^Volume Id *: *//p' | head -1)"

SQ="$ISOX/minimal.squashfs"
LISTING="$WORK/listing.txt"
unsquashfs -ll "$SQ" 2>/dev/null | sed 's#squashfs-root##' > "$LISTING"
R="$WORK/root"; mkdir -p "$R"
# Extract the small files we read. Missing ones are fine here; the checks report them.
# -no-xattrs: an unprivileged run cannot write trusted.overlay.* and unsquashfs aborts on the first failure.
unsquashfs -no-xattrs -q -f -d "$R" "$SQ" \
    etc/os-release usr/lib/os-release etc/os-release.ubuntu-base etc/lsb-release etc/issue etc/issue.net etc/hostname \
    etc/casper.conf etc/default/grub var/lib/dpkg/status \
    etc/dconf/profile/user etc/dconf/db/local.d \
    usr/share/glib-2.0/schemas \
    usr/share/gnome-background-properties \
    etc/update-motd.d etc/systemd/system etc/sudoers.d etc/netplan \
    usr/lib/ci-os usr/local/bin/ci-os-info \
    etc/group etc/gshadow etc/passwd var/cache/debconf/config.dat etc/ci-os \
    usr/lib/systemd/system/docker.service usr/lib/systemd/system/docker.socket \
    usr/lib/systemd/system/containerd.service usr/lib/systemd/system/ci-os-docker-group.service \
    usr/lib/systemd/system/ci-os-live-container-storage.service \
    etc/apt/sources.list.d usr/share/keyrings etc/xdg/autostart usr/libexec/ci-os \
    usr/bin/ollama usr/lib/systemd/system/tailscaled.service var/lib/tailscale usr/share/ollama \
    usr/share/applications/ci-os-hub.desktop \
    usr/share/plymouth/themes/spinner/watermark.png usr/share/plymouth/themes/spinner/bgrt-fallback.png \
    usr/share/plymouth/themes/spinner/spinner.plymouth usr/share/plymouth/themes/bgrt usr/share/plymouth/themes/ubuntu-text \
    usr/share/icons/Yaru/scalable/places usr/share/icons/hicolor/scalable/apps usr/share/icons/hicolor/icon-theme.cache \
    usr/share/pixmaps var/lib/dpkg/diversions etc/dconf/db/gdm.d \
    usr/share/xsessions usr/share/wayland-sessions usr/share/applications/gnome-ubuntu-panel.desktop \
    usr/share/gnome-shell/extensions/ubuntu-dock@ubuntu.com/metadata.json \
    usr/share/gnome-shell/extensions/ubuntu-appindicators@ubuntu.com/metadata.json \
    usr/share/gnome-shell/extensions/tiling-assistant@ubuntu.com/metadata.json \
    >/dev/null 2>&1 || true

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
check "casper.conf does not pretend to set USERGROUPS (casper ignores it)" bash -c "! grep -q USERGROUPS '$R/etc/casper.conf'"
check "docker.io is not installed (conflicts with docker-ce)" bash -c "! awk 'BEGIN{RS=\"\"} \$1==\"Package: docker.io\"' '$R/var/lib/dpkg/status' | grep -q 'install ok installed'"

section "3c. Optional tools (Tier B): tailscale, cloudflared, gh, Ollama, Companion Launcher"
if [[ "${VERIFY_TIERB:-1}" == 0 ]]; then
    note "skipped (VERIFY_TIERB=0)"
else
    PINS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../core/manifest/tier-b-pins.env"
    # shellcheck source=../../../../core/manifest/tier-b-pins.env
    if [[ -f "$PINS" ]]; then source "$PINS"; else fail "pins file not found: $PINS"; fi
    BAKED="$R/usr/lib/ci-os/baked-hub-tools.txt"
    baked_has() { grep -q -E -- "$1" "$BAKED" 2>/dev/null; }
    guarded() { file_has "$R/etc/systemd/system/$1.d/10-not-live.conf" '^ConditionPathExists=!/cdrom/casper/vmlinuz'; }

    # 8.1 what was baked is recorded, and the knobs were all on
    for k in bake-third-party bake-ollama bake-launcher; do
        if baked_has "^${k}=1\$"; then pass "baked-hub-tools.txt: ${k}=1"; else fail "baked-hub-tools.txt does not say ${k}=1 (rebuild, or run with VERIFY_TIERB=0)"; fi
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
    for f in /usr/bin/ollama /usr/lib/ollama/libggml-base.so.0 /usr/lib/ollama/vulkan/libggml-vulkan.so \
             /etc/systemd/system/ollama.service /usr/libexec/ci-os/ollama-models-env; do
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
    if baked_has "^ollama=${OLLAMA_VERSION:-x}\$" && baked_has "^ollama-tarball-sha256=${OLLAMA_SHA256:-x}\$"; then pass "baked Ollama is the pinned release (${OLLAMA_VERSION:-?})"; else fail "baked Ollama version/tarball hash differs from core/manifest/tier-b-pins.env"; fi

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

    # 8.6 size report (informational)
    note "root squashfs: $(du -h "$SQ" | cut -f1)"
fi

section "3d. Installed system: one layer, so the package database stays ours"
# Stock language layers carry a stock var/lib/dpkg/status and gschemas.compiled; subiquity stacks
# <base>.<lang>.squashfs on top whenever install-sources.yaml lists preinstalled_langs, which would give an
# installed system all our files but a dpkg database without docker-ce, setup-device, tailscale, ...
if [[ -s "$ISOX/install-sources.yaml" ]]; then
    check "install-sources.yaml lists no preinstalled_langs (installer uses minimal.squashfs alone)" \
        bash -c "grep -c '^  preinstalled_langs: \[\]\$' '$ISOX/install-sources.yaml' | grep -qx 2"
    check "install-sources.yaml keeps both entries (ubuntu-desktop-minimal, ubuntu-desktop)" \
        bash -c "grep -q '^  id: ubuntu-desktop-minimal\$' '$ISOX/install-sources.yaml' && grep -q '^  id: ubuntu-desktop\$' '$ISOX/install-sources.yaml'"
else
    fail "could not read /casper/install-sources.yaml"
fi
LANGLAYERS="$(xorriso -indev "$ISO" -ls /casper/ 2>/dev/null | tr -d "'" | tr ' ' '\n' | grep -E '^minimal(\.standard)?\.(de|en|es|fr|it|pt|ru|zh|no-languages)\.' || true)"
if [[ -z "$LANGLAYERS" ]]; then pass "no stock language layers on the ISO"; else fail "stock language layers still on the ISO: $(echo $LANGLAYERS | tr '\n' ' ')"; fi

section "3e. Casper overlay layers must not change directory modes"
# casper stacks minimal.squashfs, minimal.standard.squashfs and minimal.standard.live.squashfs with overlayfs, and a
# directory that exists in several layers takes its mode from the TOPMOST one. The two upper layers are placeholders;
# made with a plain mkdir they turn /tmp into drwxr-xr-x for the whole live session, and then the installer and the
# desktop launcher (shown as untrusted) cannot write their temp files. So every directory in an upper layer must carry
# the same mode as the same path in the root layer, and /tmp must be sticky and world-writable everywhere.
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
    unsquashfs -ll "$LSQ" 2>/dev/null | sed 's#squashfs-root##' > "$LAYERLIST"
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
    if [[ "$tmp_layer" == drwxrwxrwt ]]; then pass "layer $layer: /tmp is drwxrwxrwt"; else fail "layer $layer: /tmp is ${tmp_layer:-missing}, must be drwxrwxrwt"; fi
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

# ── 4. branding ─────────────────────────────────────────────────────────────
section "4. Branding: user-visible identity is Companion OS"
check "os-release NAME is Companion OS" file_has "$R/usr/lib/os-release" '^NAME="Companion OS"$'
check "os-release PRETTY_NAME starts with Companion OS" file_has "$R/usr/lib/os-release" '^PRETTY_NAME="Companion OS '
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
check "GRUB_DISTRIBUTOR is Companion OS" file_has "$R/etc/default/grub" '^GRUB_DISTRIBUTOR="Companion OS"'
check "live session host name is not 'ubuntu'" bash -c "! grep -q -E '^export HOST=\"ubuntu\"' '$R/etc/casper.conf'"
check "live session user is not 'ubuntu'" bash -c "! grep -q -E '^export USERNAME=\"ubuntu\"' '$R/etc/casper.conf'"
check "casper keeps BUILD_SYSTEM=Ubuntu (casper logic depends on it)" file_has "$R/etc/casper.conf" '^export BUILD_SYSTEM="Ubuntu"'
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
OLD_NAMES='CI OS|Companion Ubuntu|Intelligence Operating System|Companion Intelligence OS'
old_name_hits=""
for f in "$R/usr/lib/os-release" "$R/etc/lsb-release" "$R/etc/issue" "$R/etc/issue.net" "$R/etc/default/grub" "$R"/etc/update-motd.d/* \
         "$R/usr/share/applications/ci-os-hub.desktop" "$TEXT_PLYMOUTH" "$ISRC" "$ISOX/disk-info" "$ISOX/grub.cfg" "$ISOX/loopback.cfg"; do
    if [[ -f "$f" ]] && grep -q -E -- "$OLD_NAMES" "$f"; then old_name_hits="$old_name_hits ${f#"$WORK"/}"; fi
done
if [[ -z "$old_name_hits" ]]; then
    pass "no retired product name (CI OS, Companion Ubuntu, Intelligence Operating System) in os-release, issue, GRUB, MOTD, the Hub entry, the splash or the installer sources"
else
    fail "a retired product name is still in:$old_name_hits"
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
    note "logo content not checked against the canon: run this script from the repo checkout (vendor/brand, core/render, backends/ubuntu/lib/png-colours.py)"
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

# Settings > About (gnome-control-center) hard-codes two base-files pixmaps, light and dark, and ignores LOGO=.
# These are the stock sha256 values of Ubuntu 24.04.5's pair (the orange wordmark, 260 and 256 px wide).
# 45-about-logo.sh installs the one-colour mark in the canon primary of each mode.
STOCK_ABOUT_LIGHT_SHA=26deac685457e38325d743c50ff3d7b83a820243afef26878c13ee262198528c
STOCK_ABOUT_DARK_SHA=2d6f9e55acdc9583bb2d7533e5aff0947252eaddc0734cdceeb58e38713925f3
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
    if divert_ok "/usr/share/pixmaps/$name" && in_listing " /usr/share/pixmaps/${name//./\\.}\\.ubuntu-stock\$"; then
        pass "$name is dpkg-diverted (base-files cannot restore Ubuntu's)"
    else
        fail "$name is not dpkg-diverted to $name.ubuntu-stock (a base-files upgrade would restore Ubuntu's wordmark)"
    fi
    if [[ $CANON_OK -eq 1 ]] && png_is "$f"; then
        if [[ "$mode" == light ]]; then fill="$CI_LIGHT_PRIMARY"; else fill="$CI_DARK_PRIMARY"; fi
        canon_png "$name ($mode mode)" "$f" solid "${fill#\#}" "$fill"
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
# 60-visible-names.sh renames the display strings Ubuntu still showed after the logos: the sessions in GDM's gear menu,
# the Settings sidebar entry (gnome-ubuntu-panel.desktop) and the names of three shell extensions. What the session and
# the shell find them by must stay Ubuntu's, and is asserted as hard as the names: a session whose file name, Exec= or
# DesktopNames= changed does not log in, a panel without OnlyShowIn=ubuntu; vanishes, and an extension whose uuid no
# longer matches its directory is not loaded. The stock files are diverted so a package upgrade cannot restore them.
listed() { awk -v p="$1" '$NF == p { f = 1 } END { exit !f }' "$LISTING"; } # a file at exactly this path in the image
has_line() { grep -q -x -F -- "$2" "$1" 2>/dev/null; }                     # has_line <file> <whole line>
json_field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2" 2>/dev/null; }
SESSION_ENTRIES=(
    "/usr/share/xsessions/ubuntu.desktop|Companion OS"
    "/usr/share/xsessions/ubuntu-xorg.desktop|Companion OS on Xorg"
    "/usr/share/wayland-sessions/ubuntu.desktop|Companion OS"
    "/usr/share/wayland-sessions/ubuntu-wayland.desktop|Companion OS on Wayland"
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
    if has_line "$R$f" "Exec=env GNOME_SHELL_SESSION_MODE=ubuntu /usr/bin/gnome-session --session=ubuntu" \
       && has_line "$R$f" "TryExec=/usr/bin/gnome-shell" && file_has "$R$f" '^DesktopNames=ubuntu;GNOME;?$'; then
        pass "$f keeps its session identifiers (Exec= ubuntu session, TryExec=, DesktopNames=ubuntu;GNOME)"
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
    pass "every Name= in the four session files starts with 'Companion OS'"
else
    fail "a Name= in a session file does not start with 'Companion OS':$session_name_bad"
fi

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

section "5. Branding: boot menu"
check "GRUB menu says Companion OS" file_has "$ISOX/grub.cfg" 'menuentry "Try or Install Companion OS"'
check "/.disk/info starts with Companion-OS (launcher label 'Install Companion OS ...')" bash -c "head -1 '$ISOX/disk-info' | grep -q -E '^Companion-OS [0-9.]+ LTS '"
check "/.disk/info keeps the (serial) suffix pollinate parses" bash -c "head -1 '$ISOX/disk-info' | grep -q -E '\\([0-9.]+\\)\\s*\$'"
check "no Ubuntu in any GRUB menu entry title" bash -c "! grep -E '^\s*menuentry' '$ISOX/grub.cfg' '$ISOX/loopback.cfg' | grep -q -i ubuntu"

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
insmods="$(grep -E '^[[:space:]]*insmod[[:space:]]' "$ISOX/grub.cfg" | awk '{print $2}' | sort -u | tr '\n' ' ')"
if [[ "$insmods" == "all_video gfxterm png " ]]; then
    pass "grub.cfg insmods exactly all_video, gfxterm and png (built into the signed GRUB)"
else
    fail "grub.cfg insmod set is '${insmods:-none}' (want 'all_video gfxterm png': any other module is refused under Secure Boot)"
fi
if [[ -f "$VERIFY_REPO/core/lib/grub-merge.sh" && -f "$VERIFY_REPO/vendor/brand/tokens/tokens.sh" ]]; then
    # shellcheck source=../../../../core/lib/grub-merge.sh
    source "$VERIFY_REPO/core/lib/grub-merge.sh"
    # shellcheck source=../../../../vendor/brand/tokens/tokens.sh
    source "$VERIFY_REPO/vendor/brand/tokens/tokens.sh"
    want_normal="$(ci_grub_nearest_color "$CI_DARK_FOREGROUND")/black"
    want_highlight="black/$(ci_grub_nearest_color "$CI_ACCENT_AQUA")"
    have_normal="$(sed -n 's/^set menu_color_normal=//p' "$ISOX/grub.cfg" | head -1)"
    have_highlight="$(sed -n 's/^set menu_color_highlight=//p' "$ISOX/grub.cfg" | head -1)"
    if [[ "$have_highlight" == "$want_highlight" ]]; then pass "menu_color_highlight is $have_highlight (nearest GRUB colour to the accent aqua)"; else fail "menu_color_highlight is '${have_highlight:-unset}', the tokens give $want_highlight"; fi
    if [[ "$have_normal" == "$want_normal" ]]; then pass "menu_color_normal is $have_normal (nearest GRUB colour to the dark foreground)"; else fail "menu_color_normal is '${have_normal:-unset}', the tokens give $want_normal"; fi
else
    note "menu colours not re-derived from the tokens: run this script from the repo checkout (core/lib/grub-merge.sh, vendor/brand/tokens/tokens.sh)"
fi

# The installed system's GRUB background is rendered by the same script and must be the same kind of file.
GRUB_BG_ROOT="$R/usr/share/pixmaps/ci-os-grub-bg.png"
if [[ -f "$GRUB_BG_ROOT" ]] && png_is "$GRUB_BG_ROOT"; then
    d="$(png_depth "$GRUB_BG_ROOT")"
    if [[ "$d" == 8 ]]; then pass "installed-system GRUB background (/usr/share/pixmaps/ci-os-grub-bg.png) has 8-bit depth"; else fail "installed-system GRUB background has IHDR bit depth ${d:-unknown} (want 8)"; fi
else
    fail "installed-system GRUB background /usr/share/pixmaps/ci-os-grub-bg.png is missing or not a PNG"
fi

# Secure Boot: theming edits grub.cfg and adds one data file; the signed binaries must be the stock bytes.
if [[ -n "${VERIFY_BASE_ISO:-}" && -f "$VERIFY_BASE_ISO" ]]; then
    BASEX="$WORK/base"; mkdir -p "$BASEX"
    xorriso -osirrox on -indev "$VERIFY_BASE_ISO" \
        -extract /EFI/boot/bootx64.efi "$BASEX/bootx64.efi" \
        -extract /EFI/boot/grubx64.efi "$BASEX/grubx64.efi" \
        -extract /EFI/boot/mmx64.efi "$BASEX/mmx64.efi" >/dev/null 2>&1
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
check "Ubuntu wallpaper collections are not offered in Settings" bash -c "! ls '$R'/usr/share/gnome-background-properties 2>/dev/null | grep -E '\\.xml\$' | grep -q -i -E 'ubuntu|noble|resolute'"

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
# safe-graphics splash) and bgrt-fallback.png (what the bgrt theme shows where the firmware has no boot logo). They are the
# initrd's own files repainted (build-iso.sh brand_initrd_plymouth), so the Font= lines are still Ubuntu's, the only fonts
# that initrd carries. The colours are the canon's, derived from the repo's tokens like the logo checks above. (The bgrt
# theme draws black behind its logo, so the ground colour is only seen in the spinner theme: the files are checked, not
# a screen. A boot of the ISO shows the fallback logo.)
PLY_T="usr/share/plymouth/themes"
if [[ -n "$found_overlay" ]]; then
    ovl_files="$(cd "$OVLX" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | paste -sd' ' -)"
    ovl_want="etc/casper.conf $PLY_T/bgrt/bgrt.plymouth $PLY_T/spinner/bgrt-fallback.png $PLY_T/spinner/spinner.plymouth $PLY_T/spinner/watermark.png $PLY_T/ubuntu-text/ubuntu-text.plymouth usr/share/plymouth/ubuntu-logo.png"
    ovl_want="$(printf '%s\n' $ovl_want | LC_ALL=C sort | paste -sd' ' -)"
    if [[ "$ovl_files" == "$ovl_want" ]]; then
        pass "initrd overlay carries exactly the branded files: casper.conf, the bgrt, spinner and text-splash themes, the watermark, ubuntu-logo.png and bgrt-fallback.png"
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
OVL_TEXT="$OVLX/$PLY_T/ubuntu-text/ubuntu-text.plymouth"
if [[ -f "$OVL_TEXT" ]]; then
    check "text splash (initrd overlay) is titled Companion OS, not Ubuntu 24.04" file_has "$OVL_TEXT" '^title=Companion OS( [0-9][^ ]*)?$'
    check "text splash (initrd overlay) is no longer aubergine (0x2c001e)" bash -c "! grep -q -i '0x2c001e' '$OVL_TEXT'"
    ovl_title="$(grep -h '^title=' "$OVL_TEXT" 2>/dev/null | head -1)"
    root_title="$(grep -h '^title=' "$TEXT_PLYMOUTH" 2>/dev/null | head -1)"
    if [[ -n "$ovl_title" && "$ovl_title" == "$root_title" ]]; then
        pass "text splash title is the same in the initrd overlay and the installed system ($ovl_title)"
    else
        fail "text splash title differs: initrd overlay '${ovl_title:-none}', installed system '${root_title:-none}'"
    fi
else
    fail "no ubuntu-text.plymouth in the initrd overlay (the safe-graphics splash is still 'Ubuntu 24.04' on aubergine)"
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
    if divert_ok "$p" && in_listing " ${p//./\\.}\\.ubuntu-stock\$"; then
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
note "session file names (ubuntu.desktop, ubuntu-xorg.desktop, ...), DesktopNames=ubuntu, extension uuids (*@ubuntu.com), OnlyShowIn=ubuntu: ids the session and the shell look things up by; only their display names are Companion OS"

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ -n "${VERIFY_KEEP:-}" ]] && echo "scratch kept in $WORK"
[[ "$FAIL" -eq 0 ]]
