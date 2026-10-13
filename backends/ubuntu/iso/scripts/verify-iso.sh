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
    etc/group etc/gshadow etc/passwd var/cache/debconf/config.dat etc/ci-os \
    usr/lib/systemd/system/docker.service usr/lib/systemd/system/docker.socket \
    usr/lib/systemd/system/containerd.service usr/lib/systemd/system/ci-os-docker-group.service \
    usr/lib/systemd/system/ci-os-live-container-storage.service \
    etc/apt/sources.list.d usr/share/keyrings etc/xdg/autostart usr/libexec/ci-os \
    usr/bin/ollama usr/lib/systemd/system/tailscaled.service var/lib/tailscale usr/share/ollama \
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
    if file_has "$f" '^Wants=ci-os-live-container-storage\.service$' && file_has "$f" '^After=ci-os-live-container-storage\.service$'; then
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
