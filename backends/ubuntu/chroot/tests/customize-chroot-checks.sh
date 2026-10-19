#!/usr/bin/env bash
#=============================================================================
# Test: customize-chroot.sh is an Ubuntu 26.04 script, and the parts of it that cannot be run without root are pinned
#
# customize-chroot.sh needs root and a whole extracted image, so most of it can only be read, not run. This test does the
# two things that can be done on any machine:
#
#   1. It RUNS the script against fake chroot directories (with stub renderers on PATH, as render-preflight.sh does) to see
#      what the first step does with the base image's identity: a Ubuntu 26.04 (resolute) base is accepted, anything else
#      (24.04, 22.04, 25.10, a mixed-up pair, no os-release at all) is refused with the supported release named, and a refused
#      directory is left exactly as it was (no .ubuntu-base copy, no apt pin, no staged files).
#   2. It READS the script for properties whose failure shows up only after a one-hour build: the order of the steps that
#      matter (identity check first, dracut pin before the first apt call, curl before its first use), that nothing for
#      another Ubuntu release is left, that a failed package install stops the build, that the baked SSH host keys are
#      removed (and only when the unit that makes new ones is in place), that nothing is gated on ConditionFirstBoot, that
#      the wallpaper collections are found by glob.
#
# Pure bash (3.2 safe), no root, no network, writes only to a temporary directory.
#   backends/ubuntu/chroot/tests/customize-chroot-checks.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../customize-chroot.sh"
PIN="$HERE/../payload/apt/etc/apt/preferences.d/ci-os-no-dracut"
DROPIN="$HERE/../payload/ssh/etc/systemd/system/sshd-keygen.service.d/10-ci-os-host-keys.conf"
[[ -f "$SCRIPT" && -f "$PIN" && -f "$DROPIN" ]] || { echo "missing $SCRIPT, $PIN or $DROPIN" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cc-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

# line_of <extended regex>: the number of the first line of the script that matches, or 0.
line_of() { grep -n -E -- "$1" "$SCRIPT" | head -n 1 | cut -d: -f1 | grep . || echo 0; }
# before <label> <regex A> <regex B>: A appears, B appears, and A comes first.
before() {
    local a b
    a="$(line_of "$2")"; b="$(line_of "$3")"
    if [[ "$a" -gt 0 && "$b" -gt 0 && "$a" -lt "$b" ]]; then pass "$1 (line $a before line $b)"; else fail "$1 (A at line $a, B at line $b)"; fi
}
# body_of <start BRE> <end BRE>: the lines of the script from the first start match through the next end match (sed range).
body_of() { sed -n "\\%$1%,\\%$2%p" "$SCRIPT"; }

# ---------------------------------------------------------------------------------------------------------------------
echo "== 1. the identity check, run against fake chroots"

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
# rsvg-convert must write its -o file (render-mark-png.sh copies it); the ImageMagick names only have to exist.
cat >"$STUBS/rsvg-convert" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then shift; : > "$1"; fi; shift; done
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"$STUBS/magick"; printf '#!/bin/sh\nexit 0\n' >"$STUBS/convert"
chmod 755 "$STUBS"/*

# run_base <name> <os-release text or "-" for none>: sets RC and OUT; CHROOT is the fake directory.
run_base() {
    CHROOT="$WORK/chroot-$1"
    mkdir -p "$CHROOT/etc"
    if [[ "$2" != "-" ]]; then printf '%s\n' "$2" >"$CHROOT/etc/os-release"; fi
    OUT="$(PATH="$STUBS:$PATH" bash "$SCRIPT" "$CHROOT" 1.0 2>&1)"; RC=$?
}
snapshot() { (cd "$1" && find . | LC_ALL=C sort | tr '\n' ' '); }

os_text() { # os_text <VERSION_ID> <VERSION_CODENAME>
    printf 'NAME="Ubuntu"\nVERSION_ID="%s"\nVERSION_CODENAME=%s\nID=ubuntu\nUBUNTU_CODENAME=%s\n' "$1" "$2" "$2"
}

for pair in "24.04 noble" "22.04 jammy" "25.10 questing" "26.04 noble" "24.04 resolute"; do
    # shellcheck disable=SC2086
    set -- $pair
    run_base "r-$1-$2" "$(os_text "$1" "$2")"
    before_snap="$(snapshot "$CHROOT")"
    expect "$1 / $2 is refused (exit 1)" test "$RC" -eq 1
    expect "$1 / $2: the message names Ubuntu 26.04 LTS (resolute)" bash -c "printf '%s\n' \"\$1\" | grep -q 'Ubuntu 26.04 LTS (resolute)'" _ "$OUT"
    expect "$1 / $2: it never started Step 1" bash -c "! printf '%s\n' \"\$1\" | grep -q 'Base Ubuntu identity'" _ "$OUT"
    expect "$1 / $2: the directory holds only the os-release it was given (no .ubuntu-base, no pin, no staging)" test "$before_snap" = ". ./etc ./etc/os-release "
done

run_base none -
expect "no os-release at all is refused (exit 1)" test "$RC" -eq 1
expect "  and says it is not an extracted Ubuntu 26.04 image" bash -c "printf '%s\n' \"\$1\" | grep -q 'not an extracted Ubuntu 26.04 desktop image'" _ "$OUT"
expect "  and the directory is still empty of files" test "$(find "$CHROOT" -type f | wc -l | tr -d ' ')" -eq 0

run_base ok "$(os_text 26.04 resolute)"
expect "26.04 / resolute passes the check: Step 1 reports it" bash -c "printf '%s\n' \"\$1\" | grep -q 'Base Ubuntu identity: 26.04 (resolute)'" _ "$OUT"
expect "  and the pristine identity was saved as /etc/os-release.ubuntu-base" test -f "$CHROOT/etc/os-release.ubuntu-base"
expect "  and it is a copy of the base's file" cmp -s "$CHROOT/etc/os-release" "$CHROOT/etc/os-release.ubuntu-base"
# The script goes on to run things inside the chroot, which needs root and a real image: it stops there on this machine.

# ---------------------------------------------------------------------------------------------------------------------
echo
echo "== 2. the order of the steps that matter"
before "the release check comes before the pristine identity is saved" 'ci_os_base_is_supported "\$BASE_VERSION_ID"' 'os-release\.ubuntu-base"$'
before "the identity is saved before os-release is rewritten (Step 1's run_theme_step 50-os-release.sh)" 'os-release\.ubuntu-base"$' 'run_theme_step 50-os-release\.sh'
before "the dracut pin is installed before Step 2 runs its first apt-get" 'preferences\.d/ci-os-no-dracut"' 'chroot_exec "/tmp/remove-packages\.sh"'
before "the dracut pin is installed before every other apt-get in the chroot (the dev packages, Step 10b)" 'preferences\.d/ci-os-no-dracut"' 'install-dev-packages\.sh"$'
before "Step 1b (pin) comes before Step 2" 'Step 1b: Pinning' 'Step 2: Removing'

# ---------------------------------------------------------------------------------------------------------------------
echo
echo "== 3. the dracut pin"
expect "the pin names dracut and dracut-core" grep -q -x 'Package: dracut dracut-core' "$PIN"
expect "  at priority -1" grep -q -x 'Pin-Priority: -1' "$PIN"
expect "  for every origin" grep -q -x 'Pin: release \*' "$PIN"
expect "dracut-install is NOT pinned (initramfs-tools-core depends on it; -1 holds back its security updates)" \
    bash -c "! grep -v '^#' '$PIN' | grep -q 'dracut-install'"
expect "the file is installed to /etc/apt/preferences.d/ci-os-no-dracut" grep -q 'CHROOT_PATH/etc/apt/preferences.d/ci-os-no-dracut"' "$SCRIPT"
expect "the file is world-readable (apt reads it as _apt in some paths)" grep -q 'install -D -m 0644 "\$SCRIPT_DIR/payload/apt/etc/apt/preferences.d/ci-os-no-dracut"' "$SCRIPT"

# ---------------------------------------------------------------------------------------------------------------------
echo
echo "== 4. curl, packages and keys"
dev="$(body_of 'tmp/install-dev-packages\.sh" <<' '^EOFSCRIPT$')"
expect "Step 10b installs curl (the stock 26.04.1 image has none)" bash -c "printf '%s\n' \"\$1\" | grep -q '^ *curl *\\\\\$'" _ "$dev"
expect "Step 10b stops the build when a package cannot be installed (set -e, no '|| true' on the install)" \
    bash -c "printf '%s\n' \"\$1\" | grep -q 'set -euo pipefail' && ! printf '%s\n' \"\$1\" | grep -q 'openssh-server || true'" _ "$dev"
hub="$(body_of 'tmp/preinstall-hub-wireless\.sh" <<' '^EOSCRIPT$')"
inst="$(printf '%s\n' "$hub" | grep -n 'apt-get install -y --no-install-recommends curl' | head -n 1 | cut -d: -f1)"
use="$(printf '%s\n' "$hub" | grep -n 'curl -fsSL' | head -n 1 | cut -d: -f1)"
if [[ -n "$inst" && -n "$use" && "$inst" -lt "$use" ]]; then pass "Step 10d installs curl (line $inst of its script) before its first curl -fsSL (line $use)"; else fail "Step 10d runs curl before it installs it (install line '${inst:-none}', first use '${use:-none}')"; fi
expect "Step 10d (curl) runs before Step 10f, which requires curl in the image" bash -c "[[ $(line_of 'Step 10d: Pre-installing') -lt $(line_of 'Step 10f: Installing the one-click') ]]"
expect "Step 10f checks curl is in the image" grep -q 'for _tool in zenity curl openssl lsblk findmnt' "$SCRIPT"
expect "no 32-bit (:i386) package is installed" bash -c "! grep -v '^ *#' '$SCRIPT' | grep -q ':i386'"
expect "the Vulkan install is not masked by '|| true'" bash -c "! grep -A4 -E '^ *vulkan-tools' '$SCRIPT' | grep -q '|| true'"
fin="$(body_of 'tmp/final-cleanup\.sh" <<' '^EOFSCRIPT$')"
expect "the final cleanup removes the SSH host keys openssh-server generated in the chroot" bash -c "printf '%s\n' \"\$1\" | grep -q 'rm -f /etc/ssh/ssh_host_\\*_key /etc/ssh/ssh_host_\\*_key.pub'" _ "$fin"
expect "openssh-server is installed in the image (so the removal above is needed)" grep -q 'openssh-server' "$SCRIPT"

# ---------------------------------------------------------------------------------------------------------------------
echo
echo "== 5. Ubuntu 26.04 only"
expect "no 24.04, noble, Numbat, jammy or 22.04 anywhere in the script" bash -c "! grep -n -i -E '24\\.04|noble|numbat|jammy|22\\.04' '$SCRIPT'"
expect "the first-boot fallback names resolute and 26.04" bash -c "grep -q 'echo resolute' '$SCRIPT' && grep -q 'echo 26.04' '$SCRIPT'"
expect "the disabled package-repository template names resolute" grep -q 'packages.ci.computer/ubuntu resolute main' "$SCRIPT"
expect "the wallpaper collections are found by glob, not by a list of names" \
    bash -c "grep -q 'gnome-background-properties/\\*\\.xml' '$SCRIPT' && ! grep -q 'for xml in ubuntu-wallpapers' '$SCRIPT'"
expect "  and our own collection is skipped" grep -q '"\$xml" == "ci-os-wallpapers.xml"' "$SCRIPT"
expect "no Xorg session is mentioned as something to rename" bash -c "! grep -v '^ *#' '$SCRIPT' | grep -i -q 'xorg'"
expect "the shell theme goes through ci_os_install_shell_theme (the Yaru file always, the upstream file only when safe)" \
    grep -q 'ci_os_install_shell_theme "\$GRESOURCE_SRC" "\$CHROOT_PATH"' "$SCRIPT"
expect "  and the script no longer copies the Yaru blob over gnome-shell-theme.gresource by hand" \
    bash -c "! grep -q 'CHROOT_PATH/usr/share/gnome-shell/gnome-shell-theme.gresource' '$SCRIPT'"

# ---------------------------------------------------------------------------------------------------------------------
echo
echo "== 6. SSH host keys and first-boot units: nothing may depend on ConditionFirstBoot (the installer copies the live machine-id)"
# subiquity writes the live session's /etc/machine-id into the new system, and systemd calls a boot "first" only for a missing,
# empty or "uninitialized" machine-id, so ConditionFirstBoot=yes is FALSE on an installed machine. first-boot-units-boot.sh
# proves that with systemd as PID 1; these checks pin the files that fix it.
expect "the sshd-keygen drop-in resets the packaged ConditionFirstBoot (an empty assignment)" grep -q -x 'ConditionFirstBoot=' "$DROPIN"
expect "  and restates the package's other two conditions (the empty assignment drops all of them)" \
    bash -c "grep -q -x 'ConditionPathIsReadWrite=/etc/ssh' '$DROPIN' && grep -q -x 'ConditionPathIsSymbolicLink=!/etc/ssh' '$DROPIN'"
expect "  and gates the unit on the key it exists for (no ed25519 host key)" grep -q -x 'ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key' "$DROPIN"
expect "  and never sets ConditionFirstBoot to a value" bash -c "! grep -v '^ *#' '$DROPIN' | grep -q 'ConditionFirstBoot=.'"
expect "  and is a [Unit] drop-in only (it changes no command)" \
    bash -c "[[ \$(grep -v '^ *#' '$DROPIN' | grep -c '^\\[') -eq 1 ]] && grep -v '^ *#' '$DROPIN' | grep -q -x '\\[Unit\\]'"
expect "nothing in the script is gated on ConditionFirstBoot (comments aside)" bash -c "! grep -v '^ *#' '$SCRIPT' | grep -q 'ConditionFirstBoot'"
expect "the drop-in is installed from the payload into /etc/systemd/system/sshd-keygen.service.d/" \
    grep -q 'install -D -m 0644 "\$SCRIPT_DIR/payload/ssh/etc/systemd/system/sshd-keygen.service.d/10-ci-os-host-keys.conf"' "$SCRIPT"
before "  and it is installed before the final cleanup script runs (which removes the keys)" \
    'payload/ssh/etc/systemd/system/sshd-keygen\.service\.d/10-ci-os-host-keys\.conf"' 'chroot_exec "/tmp/final-cleanup\.sh"'
expect "the old claim (the stock unit makes a fresh set on the first boot of each machine) is gone" bash -c "! grep -q 'makes a fresh set on the first boot' '$SCRIPT'"

# The guard: the keys are removed only when the replacement is in place. The block is cut out of the cleanup script and run
# against a scratch root.
guard="$(printf '%s\n' "$fin" | sed -n '/^if \[ ! -f \/etc\/systemd\/system\/sshd-keygen\.service\.d/,/^rm -f \/etc\/ssh\/ssh_host_/p')"
expect "the cleanup has a guard in front of the key removal" bash -c "[[ -n \"\$1\" ]] && printf '%s\n' \"\$1\" | grep -q 'exit 1' && printf '%s\n' \"\$1\" | tail -n 1 | grep -q '^rm -f /etc/ssh/ssh_host_'" _ "$guard"
# root_for <name> <with-dropin 0|1> <with-unit 0|1>: a scratch root with host keys, a config and (optionally) the pieces.
root_for() {
    ROOT="$WORK/guard-$1"; rm -rf "$ROOT"
    mkdir -p "$ROOT/etc/ssh" "$ROOT/etc/systemd/system" "$ROOT/usr/lib/systemd/system"
    for t in rsa ecdsa ed25519; do : >"$ROOT/etc/ssh/ssh_host_${t}_key"; : >"$ROOT/etc/ssh/ssh_host_${t}_key.pub"; done
    : >"$ROOT/etc/ssh/sshd_config"
    if [[ "$2" == 1 ]]; then mkdir -p "$ROOT/etc/systemd/system/sshd-keygen.service.d"; cp "$DROPIN" "$ROOT/etc/systemd/system/sshd-keygen.service.d/10-ci-os-host-keys.conf"; fi
    if [[ "$3" == 1 ]]; then : >"$ROOT/usr/lib/systemd/system/sshd-keygen.service"; fi
}
run_guard() { # run_guard <root>: sets GRC and GOUT
    local code; code="$(printf '%s\n' "$guard" | sed "s%/etc/%$1/etc/%g; s%/usr/lib/%$1/usr/lib/%g")"
    GOUT="$(bash -c "$code" 2>&1)"; GRC=$?
}
nkeyfiles() { find "$1/etc/ssh" -name 'ssh_host_*_key*' | wc -l | tr -d ' '; }
root_for ok 1 1; run_guard "$ROOT"
expect "guard, drop-in and unit in place: the host keys are removed (exit 0)" test "$GRC" -eq 0 -a "$(nkeyfiles "$ROOT")" -eq 0
expect "  and the rest of /etc/ssh is left alone" test -f "$ROOT/etc/ssh/sshd_config"
root_for nodropin 0 1; run_guard "$ROOT"
expect "guard, no drop-in: the build stops (exit 1), says so, and the keys stay" test "$GRC" -eq 1 -a "$(nkeyfiles "$ROOT")" -eq 6
expect "  and the message names the drop-in" bash -c "printf '%s\n' \"\$1\" | grep -q 'sshd-keygen drop-in'" _ "$GOUT"
root_for nounit 1 0; run_guard "$ROOT"
expect "guard, no sshd-keygen.service from openssh-server: the build stops (exit 1) and the keys stay" test "$GRC" -eq 1 -a "$(nkeyfiles "$ROOT")" -eq 6

# The first-boot rebrand unit and script (heredocs in the script).
rb_unit="$(sed -n '\%usr/lib/systemd/system/ci-os-first-boot-rebrand.service" << .SVCEOF.%,/^SVCEOF$/p' "$SCRIPT")"
rb_script="$(sed -n '\%usr/lib/ci-os/first-boot-rebrand.sh" << .REBRAND.%,/^REBRAND$/p' "$SCRIPT")"
expect "the rebrand unit was found in the script" bash -c "printf '%s\n' \"\$1\" | grep -q '^\\[Unit\\]'" _ "$rb_unit"
expect "  it runs until it has left its stamp (ConditionPathExists=!/var/lib/ci-os/.first-boot-rebrand-done)" \
    bash -c "printf '%s\n' \"\$1\" | grep -q -x 'ConditionPathExists=!/var/lib/ci-os/.first-boot-rebrand-done'" _ "$rb_unit"
expect "  it still never runs in a live session (ConditionPathExists=!/cdrom/casper/vmlinuz)" \
    bash -c "printf '%s\n' \"\$1\" | grep -q -x 'ConditionPathExists=!/cdrom/casper/vmlinuz'" _ "$rb_unit"
expect "the rebrand script writes the stamp before it disables the service" \
    bash -c "a=\$(printf '%s\n' \"\$1\" | grep -n -F ': > /var/lib/ci-os/.first-boot-rebrand-done' | head -n 1 | cut -d: -f1); b=\$(printf '%s\n' \"\$1\" | grep -n '^systemctl disable' | head -n 1 | cut -d: -f1); [[ -n \"\$a\" && -n \"\$b\" && \"\$a\" -lt \"\$b\" ]]" _ "$rb_script"
ver_write='printf '"'"'%s\n'"'"' "$CI_OS_VERSION" > "$CHROOT_PATH/usr/lib/ci-os/version"'
ver_read='CI_OS_VERSION="$(head -n 1 /usr/lib/ci-os/version)"'
expect "the build records its version in /usr/lib/ci-os/version (/etc/os-release is what gets reset)" grep -q -F -- "$ver_write" "$SCRIPT"
expect "  and the rebrand script reads it first" bash -c 'printf "%s\n" "$1" | grep -q -F -- "$2"' _ "$rb_script" "$ver_read"

echo
echo "== 7. Companion Capture (Tier B) and the dock list"
# Capture's release is on a PRIVATE repository: the .deb comes from the build cache or from `gh`, and what makes either one safe is the pin.
PINS_FILE="$HERE/../../../../core/manifest/tier-b-pins.env"
DOCK_LIST="$HERE/../dock-favorites.txt"
[[ -f "$PINS_FILE" && -f "$DOCK_LIST" ]] || { echo "missing $PINS_FILE or $DOCK_LIST" >&2; exit 2; }
pin() { ( set +u; . "$PINS_FILE"; eval "printf '%s' \"\${$1}\"" ); }
for k in CAPTURE_VERSION CAPTURE_REPO CAPTURE_TAG CAPTURE_ASSET CAPTURE_SHA256 CAPTURE_SIZE CAPTURE_PACKAGE CAPTURE_BINARY; do
    expect "pin $k is set" test -n "$(pin "$k")"
done
expect "  the sha256 pin is 64 lower-case hex digits" bash -c '[[ "$1" =~ ^[0-9a-f]{64}$ ]]' _ "$(pin CAPTURE_SHA256)"
expect "  the size pin is a number of bytes" bash -c '[[ "$1" =~ ^[0-9]+$ ]]' _ "$(pin CAPTURE_SIZE)"
expect "  the tag is v<version>" test "$(pin CAPTURE_TAG)" = "v$(pin CAPTURE_VERSION)"
expect "  the asset is <package>_<version>_amd64.deb" test "$(pin CAPTURE_ASSET)" = "$(pin CAPTURE_PACKAGE)_$(pin CAPTURE_VERSION)_amd64.deb"
expect "  the repository is owner/name" bash -c '[[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]' _ "$(pin CAPTURE_REPO)"

expect "the Capture knob is validated as 0 or 1 with the others" grep -q -E '^for _k in .*CI_OS_BAKE_CAPTURE' "$SCRIPT"
expect "the cache file is named <package>_<version>_amd64.deb (what a person places there)" \
    grep -q -F 'TB_CAPTURE_DEB="$TB_CACHE/${CAPTURE_PACKAGE}_${CAPTURE_VERSION}_amd64.deb"' "$SCRIPT"
before "gh is asked for only after the cache file failed its check" \
    'if \[\[ ! -f "\$TB_CAPTURE_DEB" \]\]' 'gh release download "\$CAPTURE_TAG"'
before "the Capture .deb is checked against the sha256 pin before the chroot is touched" \
    'tb_expect_sha256 "\$TB_CAPTURE_DEB"' 'chroot "\$CHROOT_PATH" /tmp/preinstall-tier-b\.sh'
expect "a missing gh stops the build and says where the file goes" \
    bash -c 'sed -n "/command -v gh/,/^            install -d/p" "$1" | grep -q -F "Put \$CAPTURE_ASSET"' _ "$SCRIPT"
expect "a Capture .deb with files under /etc or systemd is refused (no autostart, no service)" \
    bash -c 'sed -n "/capture.members/,/^    fi/p" "$1" | grep -q -F "tb_die \"Capture .deb ships files under /etc or systemd"' _ "$SCRIPT"
expect "the finished image is asserted to have no Capture autostart" grep -q -F '[[ ! -e "$CHROOT_PATH/etc/xdg/autostart/companion-capture.desktop" ]]' "$SCRIPT"
expect "the finished image is asserted to have no Capture service" grep -q -F 'a companion-capture unit appeared' "$SCRIPT"
expect "what was baked records bake-capture and the package version" \
    bash -c 'grep -q -F "echo \"bake-capture=\$CI_OS_BAKE_CAPTURE\"" "$1" && grep -q -F "\"\$CAPTURE_PACKAGE\"" "$1"' _ "$SCRIPT"

# The dock pins the desktop file that the .deb check requires, so the two cannot drift apart.
expect "the dock list holds the desktop file the Capture .deb must ship" bash -c 'grep -q -x "companion-capture.desktop" "$1" && grep -q -F "usr/share/applications/companion-capture.desktop" "$2"' _ "$DOCK_LIST" "$SCRIPT"
expect "the dock default is written from the list, and a bad list stops the build" \
    bash -c 'grep -q -F "dock_favorites_value \"\$REPO_ROOT/backends/ubuntu/chroot/dock-favorites.txt\"" "$1" && grep -q -F "02-ci-os-dock" "$1" && grep -q -F "is not a valid dock list" "$1"' _ "$SCRIPT"
before "the dock default is written before dconf is compiled" '02-ci-os-dock" << EOF' 'chroot_exec "dconf update"'

echo
echo "== 8. the first-boot setup unit must not fight the desktop"
# Found on a real install (the 26.04.1 image, QEMU): the first login failed twice while snapd.seeded and the model download were
# running, the console showed first-boot-setup's progress bar over the screen, and boot stayed "not finished" for 30 minutes.
fb_unit="$(sed -n '\%usr/lib/systemd/system/ci-os-first-boot-setup.service" << .SVCEOF.%,/^SVCEOF$/p' "$SCRIPT")"
expect "the first-boot setup unit was found in the script" bash -c 'printf "%s\n" "$1" | grep -q "^\[Service\]"' _ "$fb_unit"
for want in 'Type=exec' 'Nice=19' 'CPUSchedulingPolicy=idle' 'IOSchedulingClass=idle' 'StandardOutput=journal' 'StandardError=journal' 'RuntimeMaxSec=1800'; do
    expect "  it has $want" bash -c 'printf "%s\n" "$1" | grep -q -x -F -- "$2"' _ "$fb_unit" "$want"
done
expect "  it does not hold the boot targets (not a oneshot)" bash -c '! printf "%s\n" "$1" | grep -q "^Type=oneshot"' _ "$fb_unit"
expect "  it does not print on the console (no console in StandardOutput or StandardError)" bash -c '! printf "%s\n" "$1" | grep -q -E "^Standard(Output|Error)=.*(console|tty)"' _ "$fb_unit"
expect "  it starts after the snap seeding" bash -c 'printf "%s\n" "$1" | grep -q "^After=.*snapd.seeded.service"' _ "$fb_unit"
expect "  it still never runs in a live session" bash -c 'printf "%s\n" "$1" | grep -q -x "ConditionPathExists=!/cdrom/casper/vmlinuz"' _ "$fb_unit"
expect "  and still stops once it has succeeded (the marker condition)" bash -c 'printf "%s\n" "$1" | grep -q -x "ConditionPathExists=!/var/lib/ci-os/.first-boot-setup-done"' _ "$fb_unit"

echo
echo "== 9. the Companion links (Step 10g)"
before "the links list is checked before anything of Step 10g is written" 'START_LINKS_ROWS="\$\(start_links_rows' 'install -d -m 0755 "\$CHROOT_PATH/usr/share/applications" "\$CHROOT_PATH/etc/skel/Desktop"'
expect "a bad links list stops the build" grep -q -F 'is not a valid links list' "$SCRIPT"
expect "each link is written to /usr/share/applications from the list" grep -q -F 'start_links_entry "$_name" "$_url" "$_comment" "$_icon" > "$CHROOT_PATH/usr/share/applications/$_id.desktop"' "$SCRIPT"
expect "a desktop shortcut is the same file, executable, in /etc/skel/Desktop" \
    grep -q -F 'install -m 0755 "$CHROOT_PATH/usr/share/applications/$_id.desktop" "$CHROOT_PATH/etc/skel/Desktop/$_id.desktop"' "$SCRIPT"
expect "the welcome script is installed executable and its autostart entry is installed" \
    bash -c 'grep -q -F "install -m 0755 \"\$START_PAYLOAD/usr/libexec/ci-os/welcome-once\"" "$1" && grep -q -F "ci-os-welcome.desktop" "$1"' _ "$SCRIPT"
before "Step 10g comes after the one-click installer (which it shares curl with)" 'echo "\[\+\] One-click automatic installer installed"' 'echo "\[\*\] Step 10g'

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
