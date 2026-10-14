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
#      apt, casper, the installer and Secure Boot depend on are untouched;
#   2b. the Settings > About logo, the dock start icon, the LOGO= icon and the greeter logo
#      are the canon mark, and the stock files are dpkg-diverted so an upgrade cannot restore them;
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
#
# Needs: xorriso squashfs-tools zstd cpio (Ubuntu: apt-get install xorriso squashfs-tools zstd cpio);
#        gpg is optional (without it the keyring fingerprints are reported as skipped).
#        Exit status is non-zero if any check fails.
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
    -extract /casper/install-sources.yaml "$ISOX/install-sources.yaml" \
    -extract /casper/minimal.squashfs "$ISOX/minimal.squashfs" \
    -extract /casper/minimal.standard.squashfs "$ISOX/minimal.standard.squashfs" \
    -extract /casper/minimal.standard.live.squashfs "$ISOX/minimal.standard.live.squashfs" >/dev/null 2>&1
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
    etc/update-motd.d etc/systemd/system etc/sudoers.d etc/netplan \
    usr/lib/ci-os usr/local/bin/ci-os-info \
    etc/group etc/gshadow etc/passwd var/cache/debconf/config.dat etc/ci-os \
    usr/lib/systemd/system/docker.service usr/lib/systemd/system/docker.socket \
    usr/lib/systemd/system/containerd.service usr/lib/systemd/system/ci-os-docker-group.service \
    usr/lib/systemd/system/ci-os-live-container-storage.service \
    etc/apt/sources.list.d usr/share/keyrings etc/xdg/autostart usr/libexec/ci-os \
    usr/bin/ollama usr/lib/systemd/system/tailscaled.service var/lib/tailscale usr/share/ollama \
    usr/share/applications/ci-os-hub.desktop \
    usr/share/plymouth/themes/spinner/watermark.png usr/share/plymouth/themes/bgrt \
    usr/share/icons/Yaru/scalable/places usr/share/icons/hicolor/scalable/apps usr/share/icons/hicolor/icon-theme.cache \
    usr/share/pixmaps var/lib/dpkg/diversions etc/dconf/db/gdm.d \
    >/dev/null 2>&1 || true

in_listing() { grep -q -E "$1" "$LISTING"; }
pkg_ok() { # package installed ("install ok installed" in dpkg status)
    awk -v p="$1" 'BEGIN{RS=""; FS="\n"} $1=="Package: " p {for(i=1;i<=NF;i++) if($i=="Status: install ok installed") {found=1}} END{exit !found}' "$R/var/lib/dpkg/status" 2>/dev/null
}
file_has() { grep -q -E -- "$2" "$1" 2>/dev/null; }
png_width() { od -An -tu1 -j16 -N4 "$1" 2>/dev/null | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}'; }
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
check "/etc/issue is Companion OS" file_has "$R/etc/issue" 'Companion OS'
check "installed-system hostname is companion-os" file_has "$R/etc/hostname" '^companion-os$'
check "GRUB_DISTRIBUTOR is Companion OS" file_has "$R/etc/default/grub" '^GRUB_DISTRIBUTOR="Companion OS"'
check "live session host name is not 'ubuntu'" bash -c "! grep -q -E '^export HOST=\"ubuntu\"' '$R/etc/casper.conf'"
check "live session user is not 'ubuntu'" bash -c "! grep -q -E '^export USERNAME=\"ubuntu\"' '$R/etc/casper.conf'"
check "casper keeps BUILD_SYSTEM=Ubuntu (casper logic depends on it)" file_has "$R/etc/casper.conf" '^export BUILD_SYSTEM="Ubuntu"'
check "MOTD header is Companion OS" bash -c "grep -q 'Companion OS' '$R'/etc/update-motd.d/00-ci-os-header"
if in_listing '^-rw-r--r-- .* /etc/update-motd\.d/00-header$'; then pass "Ubuntu's own MOTD welcome (00-header) is disabled"; else fail "Ubuntu's own MOTD welcome (00-header) is still executable"; fi

section "4b. About logo, dock start icon, LOGO icon, greeter logo"
# Settings > About (gnome-control-center) hard-codes two base-files pixmaps, light and dark, and ignores LOGO=.
# These are the stock sha256 values of Ubuntu 24.04.5's pair (the orange wordmark, 260 and 256 px wide).
STOCK_ABOUT_LIGHT_SHA=26deac685457e38325d743c50ff3d7b83a820243afef26878c13ee262198528c
STOCK_ABOUT_DARK_SHA=2d6f9e55acdc9583bb2d7533e5aff0947252eaddc0734cdceeb58e38713925f3
for pair in "ubuntu-logo-text.png:$STOCK_ABOUT_LIGHT_SHA" "ubuntu-logo-text-dark.png:$STOCK_ABOUT_DARK_SHA"; do
    name="${pair%%:*}"; stock="${pair##*:}"; f="$R/usr/share/pixmaps/$name"
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
done

# The dock's bottom button is view-app-grid-ubuntu-symbolic.svg, a symlink to Yaru's start-here-symbolic.svg.
YARU_START="$R/usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg"
if [[ ! -f "$YARU_START" ]]; then
    fail "Yaru start-here-symbolic.svg missing"
elif file_has "$YARU_START" 'M51\.451,125\.652' && ! file_has "$YARU_START" 'viewBox="0 0 16 16"'; then
    pass "Yaru start-here-symbolic.svg is the Companion mark, not Ubuntu's (dock Show Applications button)"
else
    fail "Yaru start-here-symbolic.svg is still Ubuntu's (viewBox 0 0 16 16, no Companion mark path)"
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
check "Hub launcher entry uses the ci-os-logo icon" file_has "$R/usr/share/applications/ci-os-hub.desktop" '^Icon=ci-os-logo$'

# The greeter reads logo= from the gdm dconf database; the file is the 256 px colour mark, not the 1.6 MB hologram.
check "GDM login dconf points the greeter logo at companion-logo.png" file_has "$R/etc/dconf/db/gdm.d/01-ci-os-login" "^logo='/usr/share/pixmaps/companion-logo\\.png'\$"
GREETER_LOGO="$R/usr/share/pixmaps/companion-logo.png"
if [[ -f "$GREETER_LOGO" ]]; then
    w="$(png_width "$GREETER_LOGO")"; sz="$(wc -c < "$GREETER_LOGO")"
    if [[ "$w" == 256 && "$sz" -lt 200000 ]]; then
        pass "greeter logo companion-logo.png is the 256px canon mark (${sz} bytes)"
    else
        fail "greeter logo companion-logo.png is ${w:-unknown}px wide and ${sz} bytes (want 256px, the old ci-holo-depth.png is 1597257 bytes)"
    fi
else
    fail "greeter logo /usr/share/pixmaps/companion-logo.png missing"
fi

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
