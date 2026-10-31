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
# Capture's .deb comes from the build cache or from dl.ci.computer/applet, and what makes either one safe is the pin.
PINS_FILE="$HERE/../../../../core/manifest/tier-b-pins.env"
DOCK_LIST="$HERE/../dock-favorites.txt"
[[ -f "$PINS_FILE" && -f "$DOCK_LIST" ]] || { echo "missing $PINS_FILE or $DOCK_LIST" >&2; exit 2; }
pin() { ( set +u; . "$PINS_FILE"; eval "printf '%s' \"\${$1}\"" ); }
for k in CAPTURE_VERSION CAPTURE_URL CAPTURE_SHA256 CAPTURE_SIZE CAPTURE_PACKAGE CAPTURE_BINARY; do
    expect "pin $k is set" test -n "$(pin "$k")"
done
expect "  the sha256 pin is 64 lower-case hex digits" bash -c '[[ "$1" =~ ^[0-9a-f]{64}$ ]]' _ "$(pin CAPTURE_SHA256)"
expect "  the size pin is a number of bytes" bash -c '[[ "$1" =~ ^[0-9]+$ ]]' _ "$(pin CAPTURE_SIZE)"
expect "  the URL is https on dl.ci.computer/applet, for this version, and names <package>_<version>_amd64.deb" \
    test "$(pin CAPTURE_URL)" = "https://dl.ci.computer/applet/v$(pin CAPTURE_VERSION)/linux/deb/x64/$(pin CAPTURE_PACKAGE)_$(pin CAPTURE_VERSION)_amd64.deb"

expect "the Capture knob is validated as 0 or 1 with the others" grep -q -E '^for _k in .*CI_OS_BAKE_CAPTURE' "$SCRIPT"
expect "the cache file is named <package>_<version>_amd64.deb (what a person places there)" \
    grep -q -F 'TB_CAPTURE_DEB="$TB_CACHE/${CAPTURE_PACKAGE}_${CAPTURE_VERSION}_${TB_ARCH}.deb"' "$SCRIPT"
before "the download happens only after the cache file failed its check" \
    'if \[\[ ! -f "\$TB_CAPTURE_DEB" \]\]' 'tb_fetch "\$\(tb_pin CAPTURE_URL\)"'
expect "  and needs no GitHub credentials (no gh)" bash -c '! sed -n "/TB_CAPTURE_DEB=/,/tb_expect_sha256 \"\$TB_CAPTURE_DEB\"/p" "$1" | grep -q "gh "' _ "$SCRIPT"
before "the Capture .deb is checked against the sha256 pin before the chroot is touched" \
    'tb_expect_sha256 "\$TB_CAPTURE_DEB"' 'chroot "\$CHROOT_PATH" /tmp/preinstall-tier-b\.sh'
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

# Started by the timer only, three minutes after boot, and quiet before it works (found on the same install, KI-27)
expect "  it has no [Install] section: nothing starts it at boot" bash -c '! printf "%s\n" "$1" | grep -q "^\[Install\]"' _ "$fb_unit"
fb_timer="$(sed -n '\%usr/lib/systemd/system/ci-os-first-boot-setup.timer" << .TIMEREOF.%,/^TIMEREOF$/p' "$SCRIPT")"
expect "the first-boot timer was found in the script" bash -c 'printf "%s\n" "$1" | grep -q "^\[Timer\]"' _ "$fb_timer"
expect "  it fires 3 minutes after boot (not 15: the first login is not racing the setup)" bash -c 'printf "%s\n" "$1" | grep -q -x "OnBootSec=3min"' _ "$fb_timer"
expect "  and retries every 15 minutes while the setup is pending" bash -c 'printf "%s\n" "$1" | grep -q -x "OnUnitInactiveSec=15min"' _ "$fb_timer"
expect "the service is not linked into multi-user.target any more" bash -c '! grep -q "multi-user.target.wants/ci-os-first-boot-setup.service" "$1"' _ "$SCRIPT"
expect "the timer is still linked into timers.target" grep -q -F 'timers.target.wants/ci-os-first-boot-setup.timer' "$SCRIPT"
fb_script="$(sed -n '\%usr/lib/ci-os/first-boot-setup.sh" << .BOOTSTRAP_SCRIPT.%,/^BOOTSTRAP_SCRIPT$/p' "$SCRIPT")"
expect "the setup script waits for a quiet machine before it installs anything" bash -c 'a=$(printf "%s\n" "$1" | grep -n "wait-quiet" | head -n 1 | cut -d: -f1); b=$(printf "%s\n" "$1" | grep -n "snap remove" | head -n 1 | cut -d: -f1); [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]' _ "$fb_script"
expect "  it throttles ollama.service (which does the downloads) for this run only" bash -c 'printf "%s\n" "$1" | grep -q -F "set-property --runtime ollama.service CPUWeight=20 IOWeight=20" && printf "%s\n" "$1" | grep -q -F "trap ci_os_unthrottle EXIT"' _ "$fb_script"
expect "wait-quiet is installed executable from its payload" grep -q -F 'install -m 0755 "$REPO_ROOT/backends/ubuntu/chroot/payload/first-boot/usr/libexec/ci-os/wait-quiet" "$CHROOT_PATH/usr/libexec/ci-os/wait-quiet"' "$SCRIPT"

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
echo "== 10. the first run and the login text are Companion OS's, not Ubuntu's"
# gnome-initial-setup (Canonical's first-run: raccoon artwork, Ubuntu Pro, "Help improve Ubuntu") runs unless this stamp is in the home
expect "the skel carries gnome-initial-setup-done, so no new user gets Canonical's first-run" grep -q -F ': > "$CHROOT_PATH/etc/skel/.config/gnome-initial-setup-done"' "$SCRIPT"
# The same screen returns as the "welcome to the new release" page: gnome-initial-setup-upgrade-login.service runs when the stamp above
# exists and ~/.config/gnome-initial-setup/upgrade-<release>-done does not (found on the first installed arm64 image, 2026-10-19).
# The block is RUN against a fake chroot holding the real unit (fixtures/gnome-initial-setup-upgrade-login.service, captured from the image).
GIS_FIX="$HERE/fixtures/gnome-initial-setup-upgrade-login.service"
GIS_BLOCK="$WORK/gis-block.sh"
body_of 'gis-upgrade-stamp begin' 'gis-upgrade-stamp end' > "$GIS_BLOCK"
expect "the skel stamp block of Step 10g is found (and is not empty)" test "$(wc -l < "$GIS_BLOCK" | tr -d ' ')" -gt 8
gis_run() { # gis_run <unit file or "-" for none> -> prints "<exit>|<skel stamps found>|<stderr first line>"
    local root="$WORK/gis-root.$$.$RANDOM" rc err
    mkdir -p "$root/usr/lib/systemd/user" "$root/etc/skel/.config"
    [[ "$1" == "-" ]] || cp "$1" "$root/usr/lib/systemd/user/gnome-initial-setup-upgrade-login.service"
    err="$(CHROOT_PATH="$root" bash -c 'set -euo pipefail; . "$1"' _ "$GIS_BLOCK" 2>&1 >/dev/null)"; rc=$?
    echo "$rc|$(cd "$root/etc/skel/.config" && find . -type f | sed 's|^\./||' | sort | tr '\n' ',')|$(printf '%s' "$err" | head -n 1 | cut -c1-60)"
    rm -rf "$root"
}
expect "the real 26.04 unit: exit 0 and the skel gets gnome-initial-setup/upgrade-26.04-done" test "$(gis_run "$GIS_FIX")" = "0|gnome-initial-setup/upgrade-26.04-done,|"
sed 's/upgrade-26\.04-done/upgrade-26.10-done/' "$GIS_FIX" > "$WORK/unit-2610.service"
expect "  a later release's unit: the stamp is named by the unit (upgrade-26.10-done), not written as 26.04" test "$(gis_run "$WORK/unit-2610.service")" = "0|gnome-initial-setup/upgrade-26.10-done,|"
grep -v 'upgrade-26' "$GIS_FIX" > "$WORK/unit-nostamp.service"
gis_nostamp="$(gis_run "$WORK/unit-nostamp.service")"
case "$gis_nostamp" in
    "1||[ERROR] Step 10g:"*) pass "  a unit that names no stamp stops the build (exit 1, Step 10g named) and writes nothing" ;;
    *) fail "  a unit that names no stamp stops the build (got: $gis_nostamp)" ;;
esac
expect "  no upgrade unit in the image: exit 0 and no stamp (nothing to skip)" test "$(gis_run -)" = "0||"
# an upgrade restores the executable bit of a motd script; dpkg-statoverride is what keeps it off (ci_quiet_motd_scripts, which Step 2c calls)
QUIET="$HERE/../../lib/quiet-canonical.sh"
REMOVE_TELEMETRY="$HERE/../../lib/remove-telemetry.sh"
[[ -f "$QUIET" && -f "$REMOVE_TELEMETRY" ]] || { echo "missing $QUIET or $REMOVE_TELEMETRY" >&2; exit 2; }
for m in 00-header 10-help-text 50-motd-news 88-esm-announce 91-contract-ua-esm-status; do
    expect "motd script $m is kept off by dpkg-statoverride, not only by chmod" bash -c '. "$1"; case " $CI_QUIET_MOTD_SCRIPTS " in *" $2 "*) true ;; *) false ;; esac' _ "$QUIET" "$m"
done
expect "  the override is 0644 root root and is applied now (--update)" grep -q -F 'dpkg-statoverride --update --add root root 0644 "$p"' "$QUIET"
expect "/etc/legal is diverted, then rewritten for Companion OS" bash -c 'grep -q -F "dpkg-divert --local --rename --divert /etc/legal.ubuntu-stock --add /etc/legal" "$1" && grep -q -F "Companion OS comes with ABSOLUTELY NO WARRANTY" "$1"' _ "$SCRIPT"
expect "  the new text keeps the distribution-terms sentence and the no-warranty sentence" bash -c 'sed -n "/cat > \"\$CHROOT_PATH\/etc\/legal\"/,/^LEGAL$/p" "$1" | grep -c -E "exact distribution terms|ABSOLUTELY NO WARRANTY" | grep -q "^2$"' _ "$SCRIPT"
expect "  and says nothing about Ubuntu except that it is the base" bash -c 'sed -n "/cat > \"\$CHROOT_PATH\/etc\/legal\"/,/^LEGAL$/p" "$1" | grep -i -c "ubuntu" | grep -q "^1$"' _ "$SCRIPT"
expect "the Ubuntu Pro autostart notification is on the library's deny list, and the library diverts it aside (not just deleted)" \
    bash -c '. "$1"; ci_quiet_autostart_denied ubuntu-advantage-notification.desktop' _ "$QUIET"
expect "  with dpkg-divert --local --rename to <name>.disabled" grep -q -F 'dpkg-divert --local --rename --divert "$p.disabled" --add "$p"' "$QUIET"

echo
echo "== 11. one script for two architectures (amd64 and arm64)"
BUILD_ISO="$HERE/../../iso/scripts/build-iso.sh"
CONTROL="$HERE/../../headless-package/DEBIAN/control"
[[ -f "$BUILD_ISO" && -f "$CONTROL" ]] || { echo "missing $BUILD_ISO or $CONTROL" >&2; exit 2; }
for k in OLLAMA_URL OLLAMA_SHA256 OLLAMA_SIZE LAUNCHER_URL LAUNCHER_SHA256 LAUNCHER_SIZE; do
    expect "arm64 pin ${k}_ARM64 is set" test -n "$(pin "${k}_ARM64")"
done
for k in OLLAMA LAUNCHER; do
    expect "  ${k}_SHA256_ARM64 is a sha256, and not the amd64 one" bash -c '[[ "$1" =~ ^[0-9a-f]{64}$ && "$1" != "$2" ]]' _ "$(pin "${k}_SHA256_ARM64")" "$(pin "${k}_SHA256")"
done
expect "  the arm64 Ollama and Launcher URLs name an arm64 file" bash -c '[[ "$1" == *arm64* && "$2" == *arm64* ]]' _ "$(pin OLLAMA_URL_ARM64)" "$(pin LAUNCHER_URL_ARM64)"
expect "  Companion Capture publishes no arm64 build: its arm64 pins are empty, so an arm64 image does not bake it" bash -c '[[ -z "$1$2$3" ]]' _ "$(pin CAPTURE_URL_ARM64)" "$(pin CAPTURE_SHA256_ARM64)" "$(pin CAPTURE_SIZE_ARM64)"
expect "the chroot script takes its architecture from CI_OS_ARCH and refuses anything but amd64 or arm64" bash -c 'grep -q -F "CI_ARCH=\"\${CI_OS_ARCH:-amd64}\"" "$1" && grep -q -F "CI_OS_ARCH must be amd64 or arm64" "$1"' _ "$SCRIPT"
expect "Step 10e resolves every pin of the image's architecture through tb_pin" bash -c 'grep -q -F "tb_pin() {" "$1" && [[ $(grep -c "tb_pin " "$1") -ge 12 ]]' _ "$SCRIPT"
expect "an explicit CI_OS_BAKE_CAPTURE=1 on an image with no Capture build stops the build" grep -q -F 'publishes no $TB_ARCH build' "$SCRIPT"
expect "the gh apt source is for the image's architecture, not always amd64" bash -c 'grep -q -F "deb [arch=%s signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg]" "$1" && ! grep -q "arch=amd64" "$1"' _ "$SCRIPT"
expect "amd64-microcode is installed on amd64 only (apt refuses the name on arm64)" bash -c 'sed -n "/dpkg --print-architecture/,/^fi$/p" "$1" | grep -q "amd64-microcode"' _ "$SCRIPT"
expect "the ROCm helper command is made on amd64 only" bash -c 'sed -n "/ROCm is x86-64 only/,/^fi$/p" "$1" | grep -q "ci-os-install-rocm"' _ "$SCRIPT"
expect "the setup-device package is Architecture: all (its payload is shell, Python and config: an arm64 chroot must be able to install it)" grep -q -x 'Architecture: all' "$CONTROL"
expect "build-iso.sh takes --arch, validates it and exports CI_OS_ARCH" bash -c 'grep -q -F -- "--arch)" "$1" && grep -q -F "amd64 | arm64) ;;" "$1" && grep -q -F "export CI_OS_ARCH" "$1"' _ "$BUILD_ISO"
expect "  the output name carries the architecture" bash -c 'grep -q -F "companion-os-\${CI_OS_VERSION}-\${CI_OS_ARCH}.iso" "$1" && ! grep -q "CI_OS_VERSION}-amd64.iso" "$1"' _ "$BUILD_ISO"
expect "  the base ISO must be the image's architecture (its volume id ends with it)" grep -q -F 'needs the $CI_OS_ARCH desktop ISO' "$BUILD_ISO"

echo
echo "== 12. a quiet first sign-in, and a setup log without leftovers"
# Found on the first installed arm64 image (2026-10-19): a second Firefox tab ("Firefox Privacy Notice"), an "80 Updates Available" notice,
# a setup log with lines from an older flow, and a ci-os-info that offered a command arm64 does not have.
POLICY="$HERE/../payload/firefox/etc/firefox/policies/policies.json"
PROVISION="$HERE/../../provision/provision.sh"
CIHUB="$HERE/../../../../core/lib/ci-hub.sh"
policy_keys() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(sorted("%s=%s" % (k, json.dumps(v)) for k, v in d["policies"].items())))' "$POLICY" 2>&1; }
expect "the Firefox policy file is JSON with exactly the four policies, as proved on a fresh user" test "$(policy_keys)" = 'DisableTelemetry=true,DontCheckDefaultBrowser=true,OverrideFirstRunPage="",OverridePostUpdatePage=""'
expect "Step 10g installs it as /etc/firefox/policies/policies.json, mode 0644" grep -q -F 'install -m 0644 "$REPO_ROOT/backends/ubuntu/chroot/payload/firefox/etc/firefox/policies/policies.json" "$CHROOT_PATH/etc/firefox/policies/policies.json"' "$SCRIPT"
expect "the update notifier's pop-ups are off by dconf default (section and key)" bash -c 'grep -q -F "[com/ubuntu/update-notifier]" "$1" && grep -q -F "no-show-notifications=true" "$1" && grep -q -F "03-ci-os-quiet-first-run" "$1"' _ "$SCRIPT"
before "  and the default is written before the dconf database is compiled" '03-ci-os-quiet-first-run" << ' 'chroot_exec "dconf update"'
expect "ci-os-info is installed from its payload (a test can run it), not written inline" bash -c 'grep -q -F "install -m 0755 \"\$REPO_ROOT/backends/ubuntu/chroot/payload/info/usr/local/bin/ci-os-info\"" "$1" && ! grep -q "cat > \"\$CHROOT_PATH/usr/local/bin/ci-os-info\"" "$1"' _ "$SCRIPT"
expect "the first-boot wrapper no longer ends by telling the user to log out for Docker and PATH" bash -c '! grep -q "NOTE: Log out and back in for Docker group and PATH" "$1"' _ "$SCRIPT"
for stale in "Create deploy read key" "log in as 'ci' user" "Start Ollama service: systemctl start ollama" "Verify installations: docker --version, node --version, pnpm"; do
    expect "provision.sh no longer prints: $stale" bash -c '! grep -q -F -- "$1" "$2"' _ "$stale" "$PROVISION"
done
expect "provision.sh: the missing-desktop-user case is a note, not a WARNING" bash -c '! grep -q "log_warning \"gsettings not available or no valid user detected. Skipping GNOME Power" "$1" && grep -q "log_info \"No desktop user to configure" "$1"' _ "$PROVISION"
expect "ci-hub.sh no longer says \"not deployed\" and sends the user to a portal that does not do this" bash -c '! grep -q "CI-Hub not deployed" "$1" && ! grep -q "run the WiFi/pairing portal, to enable this step" "$1"' _ "$CIHUB"
expect "provision.sh's next steps name Hub, ci-os-info and the Docker group" bash -c 'grep -q "Open Companion Hub (from the dock" "$1" && grep -q "See how the machine is doing at any time: ci-os-info" "$1" && grep -q "no permission for Docker, sign out and back in" "$1"' _ "$PROVISION"

echo
echo "== 13. Ubuntu Pro and Canonical telemetry go quiet (Step 2c, backends/ubuntu/lib/quiet-canonical.sh)"
# What the steps do is shown by backends/ubuntu/lib/tests/quiet-canonical.sh on fake roots; these pin how the build calls them.
expect "the library is sourced, and the chroot its commands run in is the build's" \
    bash -c 'grep -q -F "source \"\$REPO_ROOT/backends/ubuntu/lib/quiet-canonical.sh\"" "$1" && grep -q -x "CI_QUIET_CHROOT=\"\$CHROOT_PATH\"" "$1"' _ "$SCRIPT"
expect "Step 2c runs every step on the chroot" grep -q -F 'ci_quiet_apply_all "$CHROOT_PATH"' "$SCRIPT"
before "the Pro client's apt hook is diverted before the first apt-get of the build (Step 2, before remove-packages.sh)" 'ci_quiet_apt_hooks "\$CHROOT_PATH"' 'chroot_exec "/tmp/remove-packages\.sh"'
before "Step 2c runs after the telemetry packages were purged" 'chroot_exec "/tmp/remove-packages\.sh"' 'ci_quiet_apply_all "\$CHROOT_PATH"'
before "  and before the branding of Step 3" 'ci_quiet_apply_all "\$CHROOT_PATH"' 'Step 3: Installing CI-OS branding'
before "  and before the first later apt-get update (Step 10b), which would otherwise run the Pro client's apt hook" 'ci_quiet_apply_all "\$CHROOT_PATH"' 'install-dev-packages\.sh"$'
expect "a quieting step that fails is reported and the build goes on (verify-iso.sh names what is still loud)" grep -q -F 'a quieting step failed (see above); verify-iso.sh will name what is still loud' "$SCRIPT"
inline_purge="$(grep -E '^apt-get purge -y ubuntu-report' "$SCRIPT" | sed 's/^apt-get purge -y //; s/ || true$//')"
inline_hold="$(grep -E '^apt-mark hold ubuntu-report' "$SCRIPT" | sed 's/^apt-mark hold //; s/ || true$//')"
lib_list="$(bash -c '. "$1"; printf "%s" "$CI_QUIET_PURGE_PACKAGES"' _ "$QUIET")"
expect "Step 2 purges, and holds, exactly the library's list of telemetry packages (the list the verifier and remove-telemetry.sh use)" \
    test "$inline_purge" = "$lib_list" -a "$inline_hold" = "$lib_list"
expect "no second copy of the telemetry hosts is left in Step 2" bash -c '! grep -q "^127\.0\.0\.1 .*ubuntu\.com" "$1"' _ "$SCRIPT"
expect "no second copy of the motd loop, or of the Pro notification divert, is left in Step 8" \
    bash -c '! grep -q "for _motd in" "$1" && ! grep -q "ubuntu-advantage-notification.desktop.disabled --add" "$1"' _ "$SCRIPT"
quiet_dconf="$(sed -n '/03-ci-os-quiet-first-run" << /,/^EOF$/p' "$SCRIPT")"
expect "the quiet-first-run dconf file turns off GNOME's error reports and usage statistics, and still the update notifier's pop-ups" \
    bash -c 'for l in "[org/gnome/desktop/privacy]" "report-technical-problems=false" "send-software-usage-stats=false" "[com/ubuntu/update-notifier]" "no-show-notifications=true"; do printf "%s\n" "$1" | grep -q -x -F -- "$l" || exit 1; done' _ "$quiet_dconf"
expect "remove-telemetry.sh (an installed machine) takes its lists and its steps from the same library" \
    bash -c 'grep -q -F "source \"\$HERE/quiet-canonical.sh\"" "$1" && grep -q -F "\$CI_QUIET_PURGE_PACKAGES" "$1" && grep -q -F "ci_quiet_apply_all \"\"" "$1" && ! grep -q "TELEMETRY_PACKAGES=" "$1"' _ "$REMOVE_TELEMETRY"
expect "the library reaches the image's bootstrap tree with the other backends/ubuntu/lib scripts (remove-telemetry.sh sources it there)" \
    grep -q -F 'for lib_script in "$REPO_ROOT/backends/ubuntu/lib/"*.sh' "$SCRIPT"

echo
echo "== 14. Canonical's installer window does not open by itself in the live session (Step 7b)"
# The stock live layer enables ubuntu-desktop-installer.service with a user-level wants link; the window opened in front of the Companion dialog.
# The block of Step 7b is cut out of the script and RUN against fake chroots: the link goes, the unit file and every other link stay.
LI_BLOCK="$WORK/li-block.sh"
body_of 'live-installer-autostart begin' 'live-installer-autostart end' > "$LI_BLOCK"
expect "the Step 7b block is found (and is not empty)" test "$(wc -l < "$LI_BLOCK" | tr -d ' ')" -gt 8
before "Step 7b comes after Step 7 and before the MOTD of Step 8" 'Step 7: Installer: nothing to configure' 'Step 7b: Canonical.s installer window'
before "  and the MOTD of Step 8 comes after it" 'Step 7b: Canonical.s installer window' 'Step 8: Creating Companion OS MOTD'
li_root() { # li_root <name> <layout>: a fake chroot; layout "stock" has the live layer's link, "none" has only the unit file, "alt" has a requires link in the vendor directory
    LIR="$WORK/li-$1"; rm -rf "$LIR"
    mkdir -p "$LIR/usr/lib/systemd/user" "$LIR/etc/systemd/user/graphical-session.target.wants"
    printf '[Unit]\nDescription=installer\n' > "$LIR/usr/lib/systemd/user/ubuntu-desktop-installer.service"
    printf '[Unit]\nDescription=other\n' > "$LIR/usr/lib/systemd/user/gnome-other.service"
    ln -s /usr/lib/systemd/user/gnome-other.service "$LIR/etc/systemd/user/graphical-session.target.wants/gnome-other.service"
    case "$2" in
        stock) ln -s /usr/lib/systemd/user/ubuntu-desktop-installer.service "$LIR/etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service" ;;
        alt) mkdir -p "$LIR/usr/lib/systemd/user/default.target.requires" "$LIR/usr/lib/systemd/user/default.target.wants"
             ln -s ../ubuntu-desktop-installer.service "$LIR/usr/lib/systemd/user/default.target.requires/ubuntu-desktop-installer.service"
             ln -s ../ubuntu-desktop-installer.service "$LIR/usr/lib/systemd/user/default.target.wants/ubuntu-desktop-installer.service" ;;
    esac
}
li_run() { LI_OUT="$(CHROOT_PATH="$LIR" bash -c 'set -euo pipefail; . "$1"' _ "$LI_BLOCK" 2>&1)"; LI_RC=$?; }
li_links() { (cd "$LIR" && find . -name ubuntu-desktop-installer.service -not -path './usr/lib/systemd/user/ubuntu-desktop-installer.service' | LC_ALL=C sort | tr '\n' ' '); }
li_root stock stock
eq_() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
eq_ "the live layer's link exists before the block runs" "$(li_links)" "./etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service "
li_run
eq_ "the block exits 0 under set -euo pipefail" "$LI_RC" "0"
eq_ "  the link that starts the installer with the session is gone" "$(li_links)" ""
expect "  the unit file stays (live-only; the layer split and verify-iso.sh require it in the live layer)" test -f "$LIR/usr/lib/systemd/user/ubuntu-desktop-installer.service"
expect "  every other link of that directory stays" test -L "$LIR/etc/systemd/user/graphical-session.target.wants/gnome-other.service"
expect "  and the build log says what was removed" bash -c 'printf "%s\n" "$1" | grep -q "removed: etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service"' _ "$LI_OUT"
li_run
eq_ "a second run is a no-op that exits 0 (a rebuild without --clean extracts the stock layers again, and the block runs again)" "$LI_RC" "0"
expect "  and says there was nothing to remove" bash -c 'printf "%s\n" "$1" | grep -q "nothing to remove"' _ "$LI_OUT"
li_root none none; li_run
eq_ "an image without any such link: exit 0, nothing removed" "$LI_RC|$(li_links)" "0|"
li_root alt alt; li_run
eq_ "a wants and a requires link in the vendor directory are removed too" "$LI_RC|$(li_links)" "0|"
expect "  without touching the unit file" test -f "$LIR/usr/lib/systemd/user/ubuntu-desktop-installer.service"
expect "the block never removes anything but a link inside a .wants or .requires directory of the user units" \
    bash -c 'grep -v "^ *#" "$1" | grep "rm " | grep -q -F "rm -f \"\$_link\"" && [ "$(grep -v "^ *#" "$1" | grep -c "rm ")" = 1 ]' _ "$LI_BLOCK"

echo
echo "== 15. dark with a green accent by default (backends/ubuntu/lib/appearance.sh)"
# The values and the two texts are tested by backends/ubuntu/lib/tests/appearance.sh; these pin how the build uses them.
expect "the library is sourced" grep -q -F 'source "$REPO_ROOT/backends/ubuntu/lib/appearance.sh"' "$SCRIPT"
before "the two values are validated before the base release is checked and the chroot is touched" 'ci_os_appearance_valid\)' 'ci_os_base_is_supported "\$BASE_VERSION_ID"'
expect "a value GNOME does not accept stops the build" bash -c 'grep -q -F "backends/ubuntu/lib/appearance.sh: \$_appearance_problem" "$1"' _ "$SCRIPT"
expect "the dconf default is written to /etc/dconf/db/local.d/04-ci-os-appearance from the library" grep -q -F 'ci_os_appearance_dconf > "$CHROOT_PATH/etc/dconf/db/local.d/04-ci-os-appearance"' "$SCRIPT"
before "  and before the dconf database is compiled" 'ci_os_appearance_dconf > ' 'chroot_exec "dconf update"'
expect "the schema override gets the same two keys, appended to 90_companion-os.gschema.override" grep -q -F 'ci_os_appearance_override >> "$CHROOT_PATH/usr/share/glib-2.0/schemas/90_companion-os.gschema.override"' "$SCRIPT"
before "  and before the schemas are compiled" 'ci_os_appearance_override >> ' 'chroot_exec "glib-compile-schemas'
expect "the colour scheme and the accent are not written as literals anywhere in the script (the library is the one place)" \
    bash -c '! grep -v "^ *#" "$1" | grep -q -E "prefer-dark|accent-color"' _ "$SCRIPT"
gdm_block="$(sed -n '/gdm.d\/01-ci-os-login" << /,/^EOF$/p' "$SCRIPT")"
expect "the greeter's database (gdm.d/01-ci-os-login) is found, and has no appearance keys: the login screen keeps its recoloured shell theme" \
    bash -c 'printf "%s\n" "$1" | grep -q -F "[org/gnome/login-screen]" && ! printf "%s\n" "$1" | grep -q -E "color-scheme|accent-color"' _ "$gdm_block"

echo
echo "== 16. memory protection drop-ins (Step 10h, core/lib/memory-protection.sh, backends/ubuntu/chroot/payload/memory)"
# The values, the units and the lint are tested by core/lib/tests/memory-protection.sh; these pin how the build uses them, and run the
# real block of Step 10h against fake chroots.
MEMLIB="$HERE/../../../../core/lib/memory-protection.sh"
MEMPAY="$HERE/../payload/memory"
[[ -f "$MEMLIB" && -d "$MEMPAY" ]] || { echo "missing $MEMLIB or $MEMPAY" >&2; exit 2; }
expect "the header list of the script names Step 10h" bash -c 'sed -n 1,20p "$1" | grep -q "Step 10h"' _ "$SCRIPT"
expect "the library is sourced" grep -q -F 'source "$REPO_ROOT/core/lib/memory-protection.sh"' "$SCRIPT"
expect "the units to install come from the library (the build and the lint cannot disagree about the list)" grep -q -F 'for _unit in $(ci_os_memprot_units ubuntu); do' "$SCRIPT"
expect "each drop-in is installed from the payload with mode 0644 into /etc/systemd/system/<unit>.d/" \
    bash -c 'grep -q -F "install -m 0644 \"\$MEMORY_PAYLOAD/etc/systemd/system/\${_unit}.d/30-ci-os-memory.conf\"" "$1" && grep -q -F "install -d -m 0755 \"\$CHROOT_PATH/etc/systemd/system/\${_unit}.d\"" "$1"' _ "$SCRIPT"
expect "the lint runs on the chroot for the Ubuntu edition, and a refusal stops the build (exit 1)" \
    bash -c 'grep -q -F "if ! _memprot_problems=\"\$(ci_os_memprot_lint \"\$CHROOT_PATH\" ubuntu)\"; then" "$1" && sed -n "/ci_os_memprot_lint/,/^fi$/p" "$1" | grep -q "^    exit 1$"' _ "$SCRIPT"
before "the drop-ins are installed before the lint looks at them" 'install -m 0644 "\$MEMORY_PAYLOAD' 'ci_os_memprot_lint "\$CHROOT_PATH" ubuntu'
before "Step 10h comes after the first-boot bootstrap of Step 10c" 'echo "\[\+\] Manual re-run available via: sudo ci-os-setup"' 'echo "\[\*\] Step 10h'
before "Step 10h comes before Step 11" 'echo "\[\*\] Step 10h' 'echo "\[\*\] Step 11'
before "the lint has run before Step 11 starts its cleanup" 'ci_os_memprot_lint "\$CHROOT_PATH" ubuntu' 'echo "\[\*\] Step 11'
expect "no Memory*= literal is in the script (the values live only in the payload files)" \
    bash -c '! grep -v "^ *#" "$1" | grep -q -E "Memory(Min|Low|High|Max|SwapMax)[A-Za-z]*="' _ "$SCRIPT"
expect "the payload has exactly the five drop-ins, one per unit the library lists" \
    bash -c 'n=$(find "$1" -type f | wc -l | tr -d " "); [ "$n" = 5 ] && for u in $(. "$2"; ci_os_memprot_units ubuntu); do [ -f "$1/etc/systemd/system/$u.d/30-ci-os-memory.conf" ] || exit 1; done' _ "$MEMPAY" "$MEMLIB"

# The block of Step 10h, cut out of the script and RUN against a fake chroot: with the real payload it installs five files of mode
# 0644 and the lint passes; with a payload that holds a MemoryMax it stops with exit 1 and says what is wrong.
MP_BLOCK="$WORK/mp-block.sh"
body_of 'Step 10h: Installing the memory protection' 'Memory protection drop-ins installed' > "$MP_BLOCK"
expect "the Step 10h block is found (and is not empty)" test "$(wc -l < "$MP_BLOCK" | tr -d ' ')" -gt 8
mp_run() { # mp_run <script dir holding payload/memory> <chroot>: sets MP_RC and MP_OUT
    MP_OUT="$(SCRIPT_DIR="$1" CHROOT_PATH="$2" bash -c 'set -euo pipefail; . "$1"; . "$2"' _ "$MEMLIB" "$MP_BLOCK" 2>&1)"; MP_RC=$?
}
mkdir -p "$WORK/mp-good/chroot"
mp_run "$HERE/.." "$WORK/mp-good/chroot"
expect "the real payload: the block exits 0 under set -euo pipefail" test "$MP_RC" -eq 0
expect "  five files are installed, all of mode 0644" \
    bash -c '[ "$(find "$1/etc/systemd/system" -name 30-ci-os-memory.conf -perm 644 | wc -l | tr -d " ")" = 5 ]' _ "$WORK/mp-good/chroot"
expect "  into the directories of the units the library lists (ssh.service on Ubuntu)" \
    bash -c 'for u in system.slice user.slice ssh.service docker.service containerd.service; do [ -f "$1/etc/systemd/system/$u.d/30-ci-os-memory.conf" ] || exit 1; done; [ ! -e "$1/etc/systemd/system/sshd.service.d" ]' _ "$WORK/mp-good/chroot"
expect "  and the build log says how many units" bash -c 'printf "%s\n" "$1" | grep -q "Memory protection drop-ins installed (5 units)"' _ "$MP_OUT"
expect "  and the files are the payload's, byte for byte" \
    bash -c 'for u in system.slice user.slice ssh.service docker.service containerd.service; do cmp -s "$1/etc/systemd/system/$u.d/30-ci-os-memory.conf" "$2/etc/systemd/system/$u.d/30-ci-os-memory.conf" || exit 1; done' _ "$WORK/mp-good/chroot" "$MEMPAY"
mkdir -p "$WORK/mp-bad/script/payload" "$WORK/mp-bad/chroot"
cp -R "$MEMPAY" "$WORK/mp-bad/script/payload/memory"
printf 'MemoryMax=50%%\n' >> "$WORK/mp-bad/script/payload/memory/etc/systemd/system/docker.service.d/30-ci-os-memory.conf"
mp_run "$WORK/mp-bad/script" "$WORK/mp-bad/chroot"
expect "a payload with a MemoryMax in it: the block exits 1" test "$MP_RC" -eq 1
expect "  names Step 10h and what is wrong" bash -c 'printf "%s\n" "$1" | grep -q "\[ERROR\] Step 10h" && printf "%s\n" "$1" | grep -q "MemoryMax is not allowed"' _ "$MP_OUT"
expect "  and never says the drop-ins were installed" bash -c '! printf "%s\n" "$1" | grep -q "drop-ins installed"' _ "$MP_OUT"
rm "$WORK/mp-bad/script/payload/memory/etc/systemd/system/ssh.service.d/30-ci-os-memory.conf"; rm -rf "$WORK/mp-bad/chroot"; mkdir -p "$WORK/mp-bad/chroot"
mp_run "$WORK/mp-bad/script" "$WORK/mp-bad/chroot"
expect "a payload that lacks one of the files: the block stops (non-zero) and installs no complete set" test "$MP_RC" -ne 0

echo
echo "== 17. every Step label of the script is unique (this test finds a step by its label)"
dup_labels() { grep -o -E '^echo "\[\*\] Step [0-9]+[a-z]*:' | sort | uniq -d; }   # stdin: a script; prints the labels that appear twice
expect "no two steps of customize-chroot.sh share a label" test -z "$(dup_labels < "$SCRIPT")"
expect "  the labels are found (more than twenty of them: a pattern that matches nothing proves nothing)" test "$(grep -c -E '^echo "\[\*\] Step [0-9]+[a-z]*:' "$SCRIPT")" -gt 20
expect "  the check can fail: a script with Step 10h twice reports it" \
    test "$({ cat "$SCRIPT"; printf 'echo "[*] Step 10h: another step"\n'; } | dup_labels)" = 'echo "[*] Step 10h:'

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
