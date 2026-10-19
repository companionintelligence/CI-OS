#!/usr/bin/env bash
#=============================================================================
# Test: the overlay engine and the host build entry point of the Companion OS (CachyOS edition) ISO build, with no Docker
#
#   Part A  upstream.lock: parses with plain `set -a; . file` in bash and sh, agrees with an awk KEY=VALUE reader, and every pin
#           has the right shape.
#   Part B  in-container/apply-overlay.sh on a tiny FAKE upstream archiso/ tree and FAKE overlays in a temp dir. Success path,
#           then every way it must refuse: a patch that no longer applies, a removed package upstream lacks, a kernel line changed
#           without the marker (and with it; the marker licenses a patch, not an overlay file, the staging or the generated layer
#           that moves a kernel line later), an executable without a file_permissions entry, an overlay file in a package-owned
#           place (and the documented exemption), a wrong edition identity, a stale or reused work directory. Also that upstream is
#           never written to and that two runs on fresh copies produce the same tree.
#   Part C  build-iso.sh: --dry-run prints the pins, the base image digest, the docker cp steps and the output name and runs no
#           docker at all; it fails clearly when docker is missing; argument checks; it works from a copy of the tree outside
#           this repo. Then the real code path against a FAKE docker (a bash script with state in a temp dir): the happy path, no
#           overwrite without --force, a corrupt copy, a failing build, --keep-container, and a container it did not create.
#           C5: the working tree the ISO is built from (clean, changed, untracked, ignored, tar-excluded files, no .git) in a throwaway
#           git repository: the warning, --require-clean, --allow-dirty, what reaches the build record; the plan digest equals what
#           the container computes. C6: an --out that cannot be written is refused before docker is touched, the cleanup trap always
#           removes the container and volume, and a finished ISO that could not be copied out is kept with the recovery command.
#   Part D  the assertions behind upstream.lock (commit id, committer time, archiso/ tree id, mirrorlist sha256, key fingerprint) as
#           the small functions in lib/common.sh that 20-build.sh and 10-bootstrap.sh call, each run with a wrong value against a
#           throwaway repository, file or canned gpg output, plus static checks that the call sites (and the Dockerfile) still make them.
#
# Needs bash 3.2+, git, awk, sed, tar (gpg too for one case of part D; skipped without it). No Docker, no network, no root; runs on a
# stock macOS. Part C5 and D create throwaway git repositories under the temp directory and never touch the repository under test. What it cannot show: that
# mkarchiso accepts the merged profile (tests/ is not a build; see the "stop after overlay" container run in the README).
#
#   backends/cachyos/iso/tests/overlay-engine.sh
#
# CI_TEST_KEEP=1 keeps the temp directory (one sandbox per case, with the engine's output in <case>/out). Exit status is non-zero
# if any check fails; 2 if a tool is missing.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS="$(cd "$HERE/../.." && pwd)"
SCRIPTS="$CACHYOS/iso/scripts"
ENGINE="$SCRIPTS/in-container/apply-overlay.sh"
BUILD="$SCRIPTS/build-iso.sh"
LOCK="$CACHYOS/upstream.lock"
EPOCH=1791041490            # the primary pin's commit time: 2026-10-03T15:31:30Z

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { printf 'SKIP  %s\n' "$*"; }

for t in git awk sed tar diff find sort comm grep cp mktemp; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done
[ -f "$ENGINE" ] && [ -f "$BUILD" ] && [ -f "$LOCK" ] || { echo "cannot find the scripts under $CACHYOS" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/overlay-engine-test.XXXXXX")"
if [ -n "${CI_TEST_KEEP:-}" ]; then trap 'echo "kept the sandboxes in $W"' EXIT; else trap 'rm -rf "$W"' EXIT; fi

mk() { mkdir -p "$(dirname "$1")"; cat > "$1"; }     # mk FILE < content

# --- Part A: upstream.lock ------------------------------------------------------------------------------------------------
printf '== Part A: upstream.lock\n'
if grep -qE '^[A-Z_0-9]+="|^[A-Z_0-9]+=.* ' <(grep -vE '^[[:space:]]*(#|$)' "$LOCK"); then t_fail "lock: a value is quoted or has a space"; else t_pass "lock: no quotes and no spaces in values"; fi
bash_out="$(env -i PATH="$PATH" bash -c 'set -eu; set -a; . "$1"; set +a; printf "%s\n" "$UPSTREAM_SHA" "$BASE_IMAGE" "$CACHYOS_KEY_FPR" "$EDITION_ISO_NAME"' _ "$LOCK" 2>&1)" || bash_out="ERR $bash_out"
sh_out="$(env -i PATH="$PATH" sh -c 'set -eu; set -a; . "$1"; set +a; printf "%s\n" "$UPSTREAM_SHA" "$BASE_IMAGE" "$CACHYOS_KEY_FPR" "$EDITION_ISO_NAME"' _ "$LOCK" 2>&1)" || sh_out="ERR $sh_out"
awk_val() { awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$LOCK"; }
awk_out="$(printf '%s\n' "$(awk_val UPSTREAM_SHA)" "$(awk_val BASE_IMAGE)" "$(awk_val CACHYOS_KEY_FPR)" "$(awk_val EDITION_ISO_NAME)")"
if [ "$bash_out" = "$sh_out" ] && [ "$sh_out" = "$awk_out" ] && [ "${bash_out#ERR}" = "$bash_out" ]; then t_pass "lock: bash, sh and an awk reader agree on the pins"
else t_fail "lock: readers disagree: bash=[$bash_out] sh=[$sh_out] awk=[$awk_out]"; fi
load_lock_in_subshell() { ( set -e; export CI_PROG=test; . "$SCRIPTS/lib/common.sh"; ci_load_lock "$1" ); }
if load_lock_in_subshell "$LOCK" >"$W/lock.out" 2>&1; then t_pass "lock: ci_load_lock accepts every pin (40-hex ids, sha256 digests, full fingerprint)"
else t_fail "lock: ci_load_lock rejected the committed lock: $(head -n 3 "$W/lock.out")"; fi
bad="$W/bad.lock"; sed 's/^UPSTREAM_SHA=.*/UPSTREAM_SHA=4937780/' "$LOCK" > "$bad"
if load_lock_in_subshell "$bad" >"$W/bad.out" 2>&1; then t_fail "lock: a 7-digit UPSTREAM_SHA was accepted"
elif grep -q 'UPSTREAM_SHA must be 40' "$W/bad.out"; then t_pass "lock: an abbreviated commit id is rejected"; else t_fail "lock: wrong rejection message: $(head -n 2 "$W/bad.out")"; fi
sed 's/^BASE_IMAGE=.*/BASE_IMAGE=archlinux:latest/' "$LOCK" > "$bad"
if load_lock_in_subshell "$bad" >"$W/bad.out" 2>&1; then t_fail "lock: an unpinned base image tag was accepted"
elif grep -q 'pinned by digest' "$W/bad.out"; then t_pass "lock: a base image without a digest is rejected"; else t_fail "lock: wrong rejection message: $(head -n 2 "$W/bad.out")"; fi
{ cat "$LOCK"; echo 'EVIL=$(touch /tmp/should-not-exist)'; } > "$bad"
if load_lock_in_subshell "$bad" >"$W/bad.out" 2>&1; then t_fail "lock: a value with a command substitution was accepted"
else t_pass "lock: shell syntax in a value is rejected before the file is sourced"; fi

# --- Part B: apply-overlay.sh ---------------------------------------------------------------------------------------------
printf '== Part B: apply-overlay.sh on a fake upstream\n'

make_upstream() { # make_upstream DIR: a miniature of upstream's archiso/ (same file names and line shapes)
  local u="$1/archiso"
  mk "$u/profiledef.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="cachyos"
iso_label="COS_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="CachyOS <https://cachyos.org>"
iso_application="CachyOS Live/Rescue DVD"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/usr/local/bin/calamares-online.sh"]="0:0:755"
  ["/usr/local/bin/nvidia-module-loader"]="0:0:755"
)
EOF
  mk "$u/packages_desktop.x86_64" <<'EOF'
# the package list (comments are stripped by mkarchiso)
base
linux-cachyos
linux-cachyos-lts   # LTS kernel
mkinitcpio-archiso
syslinux
grub
memtest86+
memtest86+-efi
edk2-shell
occt
cachyos-hello

plasma-desktop
EOF
  mk "$u/pacman.conf" <<'EOF'
[options]
Architecture = auto
[cachyos]
Server = https://mirror.cachyos.org/repo/$arch/$repo
[core]
Include = /etc/pacman.d/mirrorlist
EOF
  mk "$u/grub/grub.cfg" <<'EOF'
CACHYOS_VERSION="GIT"
default=cachyos
timeout=10

menuentry "CachyOS" --class arch --id 'cachyos' {
    set gfxpayload=keep
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux-cachyos archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% cow_spacesize=10G
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux-cachyos.img
}

menuentry "CachyOS LTS Kernel" --class arch --id 'cachyos-lts' {
    set gfxpayload=keep
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux-cachyos-lts archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% cow_spacesize=10G
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux-cachyos-lts.img
}
EOF
  mk "$u/grub/loopback.cfg" <<'EOF'
menuentry "CachyOS (loopback)" --id 'cachyos' {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux-cachyos-lts archisobasedir=%INSTALL_DIR% img_dev=$imgdevpath img_loop=$isofile
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux-cachyos-lts.img
}
EOF
  mk "$u/syslinux/archiso_sys-linux.cfg" <<'EOF'
LABEL cos64
MENU LABEL CachyOS default (%ARCH%, BIOS)
LINUX /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux-cachyos-lts
INITRD /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux-cachyos-lts.img
APPEND archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% cow_spacesize=10G
EOF
  mk "$u/syslinux/archiso_head.cfg" <<'EOF'
UI vesamenu.c32
MENU TITLE CachyOS
MENU BACKGROUND splash.png
EOF
  mk "$u/airootfs/etc/hostname" <<'EOF'
CachyOS
EOF
  mk "$u/airootfs/etc/os-release" <<'EOF'
NAME="CachyOS"
EOF
  mk "$u/airootfs/usr/local/bin/calamares-online.sh" <<'EOF'
#!/usr/bin/env bash
echo upstream installer launcher
EOF
  chmod 755 "$u/airootfs/usr/local/bin/calamares-online.sh"
  mkdir -p "$u/airootfs/etc/systemd/system/multi-user.target.wants"
  ln -s /usr/lib/systemd/system/sshd.service "$u/airootfs/etc/systemd/system/multi-user.target.wants/sshd.service"
}

# patch_of FILE-RELATIVE-PATH OLD NEW: a unified diff, a/ and b/ prefixed, between two files
patch_of() {
  diff -u -L "a/$1" -L "b/$1" "$2" "$3" || true
}

make_overlay() { # make_overlay DIR UPSTREAM_DIR: a good overlay, one of each kind of thing
  local o="$1" u="$2/archiso"
  mk "$o/files/airootfs/etc/hostname" <<'EOF'
companion-os
EOF
  mk "$o/files/airootfs/usr/local/bin/ci-os-hello" <<'EOF'
#!/usr/bin/env bash
echo hello from the overlay
EOF
  chmod 755 "$o/files/airootfs/usr/local/bin/ci-os-hello"
  mk "$o/files/airootfs/usr/share/ci-os/readme.txt" <<'EOF'
Companion OS overlay file in a path of our own
EOF
  mkdir -p "$o/files/airootfs/etc/systemd/system/multi-user.target.wants"
  ln -s /usr/lib/systemd/system/docker.service "$o/files/airootfs/etc/systemd/system/multi-user.target.wants/docker.service"
  # a title-only patch: the menuentry line changes, no kernel line does
  sed 's/^menuentry "CachyOS" /menuentry "Companion OS" /' "$u/grub/grub.cfg" > "$W/new.grub.cfg"
  { printf '# Rename the first menu entry.\n'; patch_of grub/grub.cfg "$u/grub/grub.cfg" "$W/new.grub.cfg"; } > "$W/p1"
  mk "$o/patches/0001-grub-title.patch" < "$W/p1"
  printf 'docker\ndocker-compose\n# a comment\n' | mk "$o/packages.add"
  printf 'occt\ncachyos-hello # replaced by our launcher\n' | mk "$o/packages.remove"
  mk "$o/profiledef.append.sh" <<'EOF'
iso_name="companion-os-plasma"
iso_label="COMPANION_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Companion Intelligence <https://ci.computer>"
iso_application="Companion OS Live/Installer"
file_permissions+=(
  ["/usr/local/bin/ci-os-hello"]="0:0:755"
)
EOF
}

new_case() { # new_case NAME: a fresh sandbox with fake upstream, good overlay, staging and generated layers
  C="$W/$1"; rm -rf "$C"; mkdir -p "$C"
  make_upstream "$C/up"
  make_overlay "$C/overlay" "$C/up"
  mk "$C/staging/airootfs/usr/share/wallpapers/companion-os/wallpaper.png" <<'EOF'
rendered-by-a-fake-render-assets
EOF
  mk "$C/gen/airootfs/etc/motd" <<'EOF'
Welcome to CachyOS (generated by upstream's script; the overlay must win if it ships one)
EOF
  mk "$C/gen/airootfs/etc/version-tag" <<'EOF'
261003
EOF
  mkdir -p "$C/gen/airootfs/etc/systemd/system"
  ln -s /dev/null "$C/gen/airootfs/etc/systemd/system/cachyos-rate-mirrors.timer"
}

# run_engine: the engine against the sandbox $C; output in $C/out, report in $C/report; status in ENGINE_RC
run_engine() {
  ENGINE_RC=0
  ( export UPSTREAM_ARCHISO_DIR="$C/up/archiso" OVERLAY_DIR="$C/overlay" WORK_ARCHISO_DIR="${WORK_OVERRIDE:-$C/work}" \
           CI_OS_STAGING_DIR="$C/staging" CI_OS_GENERATED_DIR="$C/gen" SOURCE_DATE_EPOCH="$EPOCH" CI_OS_LOCK="$LOCK" \
           CI_OS_REPORT_FILE="$C/report" TMPDIR="$W"
    unset CI_OS_JOBS CI_OS_PACKAGE_OWNED_OK
    for kv in "$@"; do export "${kv?}"; done
    bash "$ENGINE" ) > "$C/out" 2>&1 || ENGINE_RC=$?
}
expect_ok() { # expect_ok NAME: the last run_engine succeeded
  if [ "$ENGINE_RC" -eq 0 ]; then t_pass "$1"; else t_fail "$1 (exit $ENGINE_RC): $(tail -n 6 "$C/out" | tr '\n' '|')"; fi
}
expect_fail() { # expect_fail NAME PATTERN: the last run_engine failed, and its message matches PATTERN
  if [ "$ENGINE_RC" -eq 0 ]; then t_fail "$1: the engine accepted it"
  elif grep -qE -- "$2" "$C/out"; then t_pass "$1 (refused: $2)"
  else t_fail "$1: refused, but not with /$2/: $(tail -n 5 "$C/out" | tr '\n' '|')"; fi
}
tree_sum() { ( cd "$1" && find . | LC_ALL=C sort | while IFS= read -r p; do if [ -L "$p" ]; then echo "L $p $(readlink "$p")"; elif [ -f "$p" ]; then echo "F $p $(cksum < "$p")"; else echo "D $p"; fi; done | cksum ); }

# B1 success path -----------------------------------------------------------------------------------------------------------
new_case good
UP_BEFORE="$(tree_sum "$C/up/archiso")"
run_engine
expect_ok "B1 success: patch, generated layer, overlay files, staging layer, packages and profiledef merge, all guards pass"
W1="$C/work"
[ "$(tree_sum "$C/up/archiso")" = "$UP_BEFORE" ] && t_pass "B1 upstream's archiso/ is byte-identical after the run (never written to)" || t_fail "B1 upstream was modified"
grep -q '^menuentry "Companion OS" ' "$W1/grub/grub.cfg" && t_pass "B1 the patch changed the menu entry title" || t_fail "B1 patch not applied"
[ "$(cat "$W1/airootfs/etc/hostname")" = companion-os ] && t_pass "B1 an overlay file replaces the upstream file at the same path" || t_fail "B1 hostname not replaced"
grep -q '^261003$' "$W1/airootfs/etc/version-tag" && t_pass "B1 a generated file with no overlay twin is kept" || t_fail "B1 generated file missing"
[ -L "$W1/airootfs/etc/systemd/system/cachyos-rate-mirrors.timer" ] && [ "$(readlink "$W1/airootfs/etc/systemd/system/cachyos-rate-mirrors.timer")" = /dev/null ] && t_pass "B1 a generated /dev/null mask symlink survives" || t_fail "B1 mask symlink lost"
grep -q 'Welcome to CachyOS' "$W1/airootfs/etc/motd" && t_pass "B1 the generated motd is used when the overlay ships none (the real overlay must ship its own)" || t_fail "B1 motd missing"
[ -f "$W1/airootfs/usr/share/wallpapers/companion-os/wallpaper.png" ] && t_pass "B1 the staging layer is merged" || t_fail "B1 staging file missing"
[ -x "$W1/airootfs/usr/local/bin/ci-os-hello" ] && [ -x "$W1/airootfs/usr/local/bin/calamares-online.sh" ] && t_pass "B1 executable bits survive the merge" || t_fail "B1 exec bit lost"
[ "$(readlink "$W1/airootfs/etc/systemd/system/multi-user.target.wants/docker.service")" = /usr/lib/systemd/system/docker.service ] && t_pass "B1 an overlay symlink is copied as a symlink" || t_fail "B1 symlink not preserved"
PK="$(grep -v '^#' "$W1/packages.x86_64" | tr '\n' ' ')"
[ "$PK" = "base linux-cachyos linux-cachyos-lts mkinitcpio-archiso syslinux grub memtest86+ memtest86+-efi edk2-shell plasma-desktop docker docker-compose " ] \
  && t_pass "B1 packages: upstream list, comments stripped, -occt -cachyos-hello, +docker +docker-compose" || t_fail "B1 packages wrong: $PK"
tail -n 8 "$W1/profiledef.sh" | grep -q 'iso_name="companion-os-plasma"' && grep -q 'Companion OS overlay: profiledef.append.sh' "$W1/profiledef.sh" && t_pass "B1 profiledef.append.sh is appended after upstream's content" || t_fail "B1 profiledef not appended"
grep -q '^ISO_FILE=companion-os-plasma-2026.10.03-x86_64.iso$' "$C/report" && grep -q '^ISO_LABEL=COMPANION_202610$' "$C/report" && t_pass "B1 the report names the ISO file and label (companion-os-plasma-2026.10.03-x86_64.iso, COMPANION_202610)" || t_fail "B1 report wrong: $(tr '\n' ' ' < "$C/report")"
grep -q '^KERNEL_LINES_CHANGED=0$' "$C/report" && t_pass "B1 the report says no kernel line changed" || t_fail "B1 kernel flag wrong"
KL_GOOD="$(grep -E '^KERNEL_LINES_SHA256=[0-9a-f]{64}$' "$C/report" || true)"
[ -n "$KL_GOOD" ] && t_pass "B1 the report carries a digest of the final kernel/initrd/append lines" || t_fail "B1 no KERNEL_LINES_SHA256 in the report"
SUM1="$(grep '^WORK_PROFILE_SHA256=' "$C/report")"

# B2 a patch that no longer applies ---------------------------------------------------------------------------------------------
new_case patchfail
sed 's/^default=cachyos$/default=other/' "$C/up/archiso/grub/grub.cfg" > "$W/drifted"
# written against a grub.cfg whose context differs from the pinned one
{ patch_of grub/grub.cfg "$W/drifted" "$W/new.grub.cfg"; } > "$C/overlay/patches/0002-drift.patch"
run_engine
expect_fail "B2 a patch whose context no longer matches upstream" 'patch 0002-drift.patch does not apply'
[ "$ENGINE_RC" -eq 1 ] && t_pass "B2 ...with exit status 1" || t_fail "B2 exit status $ENGINE_RC"

# B3 removing a package upstream does not list --------------------------------------------------------------------------------------
new_case rmmissing
printf 'occt\nnot-in-upstream\n' > "$C/overlay/packages.remove"
run_engine
expect_fail "B3 packages.remove names a package upstream lacks" "packages.remove lists 'not-in-upstream'"

# B3b removing a boot-critical package ----------------------------------------------------------------------------------------------
new_case rmsyslinux
printf 'syslinux\n' > "$C/overlay/packages.remove"
run_engine
expect_fail "B3b removing syslinux (needed for the BIOS boot mode)" "guard \\(e\\).*syslinux"

# B3c bad package names, add/remove clash ---------------------------------------------------------------------------------------------
new_case badpkg
printf 'docker compose\n' > "$C/overlay/packages.add"
run_engine
expect_fail "B3c two names on one packages.add line" "packages.add: 'docker compose' is not a package name"
new_case clash
printf 'occt\n' > "$C/overlay/packages.add"
run_engine
expect_fail "B3d a package in both packages.add and packages.remove" "both packages.add and packages.remove"

# B4 kernel lines ----------------------------------------------------------------------------------------------------------------------
new_case kernel
sed 's|vmlinuz-linux-cachyos-lts archisobasedir|vmlinuz-linux-cachyos-lts quiet archisobasedir|' "$C/up/archiso/grub/grub.cfg" > "$W/k.cfg"
patch_of grub/grub.cfg "$C/up/archiso/grub/grub.cfg" "$W/k.cfg" > "$C/overlay/patches/0002-add-quiet.patch"
run_engine
expect_fail "B4 a patch that adds a kernel parameter without the marker" 'patch 0002-add-quiet.patch changes the kernel'
new_case kernel-marker
{ printf '# Add quiet to the LTS entry.\n# ci-os: allow-kernel-line-change\n'; patch_of grub/grub.cfg "$C/up/archiso/grub/grub.cfg" "$W/k.cfg"; } > "$C/overlay/patches/0002-add-quiet.patch"
run_engine
expect_ok "B4 the same patch with the '# ci-os: allow-kernel-line-change' marker"
grep -q '^KERNEL_LINES_CHANGED=1$' "$C/report" && t_pass "B4 ...and the report records that kernel lines changed" || t_fail "B4 flag not set"
new_case kernel-file
sed 's|initramfs-linux-cachyos.img|initramfs-other.img|' "$C/up/archiso/grub/grub.cfg" | mk "$C/overlay/files/grub/grub.cfg"
run_engine
expect_fail "B4 an overlay file that replaces grub.cfg and changes an initrd line" 'guard \(a\)'
new_case kernel-syslinux
sed 's|^APPEND archisobasedir|APPEND nomodeset archisobasedir|' "$C/up/archiso/syslinux/archiso_sys-linux.cfg" > "$W/s.cfg"
patch_of syslinux/archiso_sys-linux.cfg "$C/up/archiso/syslinux/archiso_sys-linux.cfg" "$W/s.cfg" > "$C/overlay/patches/0002-syslinux-append.patch"
run_engine
expect_fail "B4 a patch that changes a syslinux APPEND line" 'patch 0002-syslinux-append.patch changes the kernel'
new_case title-only
sed 's|^MENU TITLE CachyOS|MENU TITLE Companion OS|' "$C/up/archiso/syslinux/archiso_head.cfg" > "$W/h.cfg"
patch_of syslinux/archiso_head.cfg "$C/up/archiso/syslinux/archiso_head.cfg" "$W/h.cfg" > "$C/overlay/patches/0002-menu-title.patch"
run_engine
expect_ok "B4 a menu-title patch (no kernel line) needs no marker"

# B4b the marker licenses a PATCH. It must not switch guard (a) off for what the other layers add afterwards: the real overlay always
# carries a marked patch (the Memtest path), so a guard that the marker disabled would never see an overlay file, the staging layer
# or the generated layer move a kernel line.
marked_case() { # marked_case NAME: a good overlay plus a MARKED patch that adds `quiet` to the LTS entry of grub.cfg
  new_case "$1"
  sed 's|vmlinuz-linux-cachyos-lts archisobasedir|vmlinuz-linux-cachyos-lts quiet archisobasedir|' "$C/up/archiso/grub/grub.cfg" > "$W/km.cfg"
  { printf '# Add quiet to the LTS entry.\n# ci-os: allow-kernel-line-change\n'; patch_of grub/grub.cfg "$C/up/archiso/grub/grub.cfg" "$W/km.cfg"; } > "$C/overlay/patches/0002-add-quiet.patch"
  sed 's|^APPEND archisobasedir|APPEND nomodeset archisobasedir|' "$C/up/archiso/syslinux/archiso_sys-linux.cfg" > "$W/sm.cfg"
}
marked_case marked-files
mk "$C/overlay/files/syslinux/archiso_sys-linux.cfg" < "$W/sm.cfg"
run_engine
expect_fail "B4b a marked patch plus an overlay file that edits a syslinux APPEND line" 'guard \(a\)'
grep -q 'nomodeset' "$C/out" && ! grep -q 'patch 0002-add-quiet.patch changes the kernel' "$C/out" && t_pass "B4b ...the report shows the offending line and does not blame the (marked) patch" || t_fail "B4b wrong report: $(tail -n 6 "$C/out" | tr '\n' '|')"
marked_case marked-staging
mk "$C/staging/syslinux/archiso_sys-linux.cfg" < "$W/sm.cfg"
run_engine
expect_fail "B4b a marked patch plus a staging-layer file that edits a syslinux APPEND line" 'guard \(a\)'
marked_case marked-generated
mk "$C/gen/syslinux/archiso_sys-linux.cfg" < "$W/sm.cfg"
run_engine
expect_fail "B4b a marked patch plus a generated-layer file that edits a syslinux APPEND line" 'guard \(a\)'
marked_case marked-grub
sed 's|initramfs-linux-cachyos-lts.img|initramfs-other.img|' "$W/km.cfg" | mk "$C/overlay/files/grub/grub.cfg"
run_engine
expect_fail "B4b a marked patch plus an overlay grub.cfg that also changes an initrd line (the whole file replaced)" 'guard \(a\)'
marked_case marked-benign
sed 's|^MENU TITLE CachyOS|MENU TITLE Companion OS|' "$C/up/archiso/syslinux/archiso_head.cfg" | mk "$C/overlay/files/syslinux/archiso_head.cfg"
run_engine
expect_ok "B4b a marked patch plus an overlay file that touches no kernel line is fine"
grep -q '^KERNEL_LINES_CHANGED=1$' "$C/report" && t_pass "B4b ...and the report still records the marked change" || t_fail "B4b flag"
KL_MARKED="$(grep '^KERNEL_LINES_SHA256=' "$C/report" || true)"
[ -n "$KL_MARKED" ] && [ "$KL_MARKED" != "$KL_GOOD" ] && t_pass "B4b ...and KERNEL_LINES_SHA256 differs from the unmarked build's: the record says WHICH lines, not just that some changed" || t_fail "B4b kernel digest: [$KL_MARKED] vs [$KL_GOOD]"
new_case kernel-both
sed 's|vmlinuz-linux-cachyos-lts archisobasedir|vmlinuz-linux-cachyos-lts quiet archisobasedir|' "$C/up/archiso/grub/grub.cfg" > "$W/kb.cfg"
patch_of grub/grub.cfg "$C/up/archiso/grub/grub.cfg" "$W/kb.cfg" > "$C/overlay/patches/0002-add-quiet.patch"
sed 's|^APPEND archisobasedir|APPEND nomodeset archisobasedir|' "$C/up/archiso/syslinux/archiso_sys-linux.cfg" | mk "$C/overlay/files/syslinux/archiso_sys-linux.cfg"
run_engine
expect_fail "B4b an UNmarked patch plus an overlay file: the patch is named" 'patch 0002-add-quiet.patch changes the kernel'
grep -q 'guard (a)' "$C/out" && t_pass "B4b ...and the overlay file is reported as well" || t_fail "B4b overlay file not reported"

# B5 executables ---------------------------------------------------------------------------------------------------------------------
new_case exec-noperm
mk "$C/overlay/files/airootfs/usr/local/bin/ci-os-forgotten" <<'EOF'
#!/usr/bin/env bash
echo no file_permissions entry
EOF
chmod 755 "$C/overlay/files/airootfs/usr/local/bin/ci-os-forgotten"
run_engine
expect_fail "B5 an executable overlay file with no file_permissions entry" 'guard \(c\).*/usr/local/bin/ci-os-forgotten'
new_case exec-badmode
sed 's|\["/usr/local/bin/ci-os-hello"\]="0:0:755"|["/usr/local/bin/ci-os-hello"]="0:0:644"|' "$C/overlay/profiledef.append.sh" > "$W/pd"; cp "$W/pd" "$C/overlay/profiledef.append.sh"
run_engine
expect_fail "B5 a file_permissions entry that is not executable" "mode '644'"
new_case exec-staging
mk "$C/staging/airootfs/usr/local/bin/ci-os-rendered" <<'EOF'
#!/usr/bin/env bash
echo
EOF
chmod 755 "$C/staging/airootfs/usr/local/bin/ci-os-rendered"
run_engine
expect_fail "B5 an executable file in the staging layer is held to the same rule" 'guard \(c\).*ci-os-rendered'
new_case exec-singlequote
sed "s|\[\"/usr/local/bin/ci-os-hello\"\]=\"0:0:755\"|['/usr/local/bin/ci-os-hello']='0:0:755'|" "$C/overlay/profiledef.append.sh" > "$W/pd"; cp "$W/pd" "$C/overlay/profiledef.append.sh"
run_engine
expect_ok "B5 a single-quoted file_permissions key is understood"

# B6 package-owned locations ---------------------------------------------------------------------------------------------------------
new_case owned
mk "$C/overlay/files/airootfs/usr/lib/os-release" <<'EOF'
NAME="Companion OS"
EOF
run_engine
expect_fail "B6 an overlay file under /usr/lib (a package location)" 'guard \(b\).*/usr/lib/os-release'
new_case owned-share
mk "$C/overlay/files/airootfs/usr/share/libalpm/hooks/cachyos-branding.hook" <<'EOF'
[Trigger]
EOF
run_engine
expect_fail "B6 an overlay file under /usr/share that is not ours" 'guard \(b\).*/usr/share/libalpm/hooks/cachyos-branding.hook'
new_case owned-ok-names
mk "$C/overlay/files/airootfs/usr/share/applications/companion-install.desktop" <<'EOF'
[Desktop Entry]
EOF
mk "$C/overlay/files/airootfs/usr/share/wallpapers/companion-os-dark/x.png" <<'EOF'
x
EOF
run_engine
expect_ok "B6 /usr/share/ci-os, wallpapers/companion*, applications/companion-* are our namespaces and need no exemption"
new_case owned-exempt
mk "$C/overlay/files/airootfs/usr/lib/os-release" <<'EOF'
NAME="Companion OS"
EOF
printf '# justified exceptions\n/usr/lib/os-release | the filesystem package ships it as a symlink and lists it in backup=, checked on a build\n' > "$C/overlay/package-owned-ok.txt"
run_engine
expect_ok "B6 the same file listed in package-owned-ok.txt with a justification"
new_case owned-nojust
mk "$C/overlay/files/airootfs/usr/lib/os-release" <<'EOF'
x
EOF
printf '/usr/lib/os-release | ok\n' > "$C/overlay/package-owned-ok.txt"
run_engine
expect_fail "B6 an exemption with a one-word justification is refused" 'needs a real justification'
new_case owned-stale
printf '/usr/lib/never-used | this exemption matches no overlay file at all, so it is stale\n' > "$C/overlay/package-owned-ok.txt"
run_engine
expect_ok "B6 a stale exemption only warns"
grep -q "exempts nothing" "$C/out" && t_pass "B6 ...and the warning names it" || t_fail "B6 no stale warning"
new_case owned-prefix
mk "$C/overlay/files/airootfs/usr/share/icons/companion/a.png" <<'EOF'
x
EOF
mk "$C/overlay/files/airootfs/usr/share/icons/companion/b.png" <<'EOF'
x
EOF
printf '/usr/share/icons/companion/ | our own icon theme directory, no package ships a directory of this name\n' > "$C/overlay/package-owned-ok.txt"
run_engine
expect_ok "B6 a directory-prefix exemption covers everything below it"
new_case owned-patch
{ printf 'diff --git a/airootfs/usr/lib/evil b/airootfs/usr/lib/evil\nnew file mode 100644\n--- /dev/null\n+++ b/airootfs/usr/lib/evil\n@@ -0,0 +1 @@\n+x\n'; } > "$C/overlay/patches/0002-newfile.patch"
run_engine
expect_fail "B6 a patch that creates a file in a package location" 'guard \(b\).*a patch.*/usr/lib/evil'

# B7 identity -----------------------------------------------------------------------------------------------------------------------
new_case no-identity
rm "$C/overlay/profiledef.append.sh"
run_engine
expect_fail "B7 no profiledef.append.sh: the profile still says iso_name=cachyos" "guard \\(d\\): iso_name is 'cachyos'"
new_case long-label
sed 's|iso_label="COMPANION_|iso_label="COMPANION_ABCDEFGHIJKLMNOPQRSTUV_|' "$C/overlay/profiledef.append.sh" > "$W/pd"; cp "$W/pd" "$C/overlay/profiledef.append.sh"
run_engine
expect_fail "B7 a volume label longer than 32 characters" 'guard \(d\).*iso_label'
new_case cachy-mark
sed 's|Companion OS Live/Installer|Companion OS, a CachyOS remix|' "$C/overlay/profiledef.append.sh" > "$W/pd"; cp "$W/pd" "$C/overlay/profiledef.append.sh"
run_engine
expect_fail "B7 the CachyOS mark in iso_application" "iso_application carries the CachyOS mark"
new_case wrong-publisher
sed 's|Companion Intelligence <https://ci.computer>|Somebody Else|' "$C/overlay/profiledef.append.sh" > "$W/pd"; cp "$W/pd" "$C/overlay/profiledef.append.sh"
run_engine
expect_fail "B7 a publisher that is not Companion Intelligence" 'iso_publisher'
new_case other-day
run_engine SOURCE_DATE_EPOCH=1798800000
expect_ok "B7 another SOURCE_DATE_EPOCH (2027-01-01) moves the name and label with it"
grep -q '^ISO_FILE=companion-os-plasma-2027.01.01-x86_64.iso$' "$C/report" && grep -q '^ISO_LABEL=COMPANION_202701$' "$C/report" && t_pass "B7 ...to companion-os-plasma-2027.01.01-x86_64.iso / COMPANION_202701" || t_fail "B7 report: $(tr '\n' ' ' < "$C/report")"

# B8 overlay shape --------------------------------------------------------------------------------------------------------------------
new_case shape-profiledef
cp "$C/up/archiso/profiledef.sh" "$C/overlay/files/profiledef.sh"
run_engine
expect_fail "B8 overlay/files/profiledef.sh (must use profiledef.append.sh)" 'overlay/files/profiledef.sh must not exist'
new_case shape-stray
echo junk > "$C/overlay/patches/0001-grub-title.patch.orig"
run_engine
expect_fail "B8 a stray file in patches/" 'unexpected file in patches'
new_case shape-clash
rm -f "$C/overlay/files/airootfs/etc/hostname"
mkdir -p "$C/overlay/files/airootfs/etc/hostname"; echo x > "$C/overlay/files/airootfs/etc/hostname/inner"
run_engine
expect_fail "B8 a directory in the overlay where upstream has a file" 'type clash'
new_case jobs
run_engine CI_OS_JOBS=3
expect_ok "B8 CI_OS_JOBS adds a mksquashfs -processors line"
grep -q "airootfs_image_tool_options+=('-processors' '3')" "$C/work/profiledef.sh" && t_pass "B8 ...appended to profiledef.sh" || t_fail "B8 no processors line"
new_case jobs-bad
run_engine CI_OS_JOBS=lots
expect_fail "B8 a non-numeric CI_OS_JOBS" 'CI_OS_JOBS must be a positive number'

# B9 directories and idempotence -------------------------------------------------------------------------------------------------------------
new_case reuse
run_engine
expect_ok "B9 first run into an empty work directory"
run_engine
expect_fail "B9 a second run into the same, now non-empty, work directory" 'WORK_ARCHISO_DIR is not empty'
new_case fresh2
run_engine
expect_ok "B9 a fresh copy of the same inputs"
SUM2="$(grep '^WORK_PROFILE_SHA256=' "$C/report")"
[ -n "$SUM1" ] && [ "$SUM1" = "$SUM2" ] && t_pass "B9 two runs on fresh copies produce the identical profile (digest ${SUM1#*=})" || t_fail "B9 profiles differ: $SUM1 vs $SUM2"
new_case emptydir
mkdir -p "$C/work"
run_engine
expect_ok "B9 an existing empty work directory is accepted"
new_case inside
WORK_OVERRIDE="$C/up/archiso/work"
run_engine
unset WORK_OVERRIDE
expect_fail "B9 a work directory inside upstream's archiso/" 'must not be inside the upstream or overlay'
new_case bare
rm -rf "$C/staging" "$C/gen" "$C/overlay/package-owned-ok.txt"
( export UPSTREAM_ARCHISO_DIR="$C/up/archiso" OVERLAY_DIR="$C/overlay" WORK_ARCHISO_DIR="$C/work" SOURCE_DATE_EPOCH="$EPOCH" CI_OS_LOCK="$LOCK" TMPDIR="$W"
  unset CI_OS_STAGING_DIR CI_OS_GENERATED_DIR CI_OS_JOBS CI_OS_REPORT_FILE
  bash "$ENGINE" ) > "$C/out" 2>&1 && ENGINE_RC=0 || ENGINE_RC=$?
expect_ok "B9 only the required inputs: no staging layer, no generated layer, no report file"

# --- Part C: build-iso.sh -------------------------------------------------------------------------------------------------------------------
printf '== Part C: build-iso.sh\n'
# shellcheck source=/dev/null
. "$LOCK"
FAKE="$W/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/docker" <<'EOF'
#!/usr/bin/env bash
# A recording stand-in for docker. State lives in $FAKE_DOCKER_STATE. Modes: FAKE_DOCKER_BUILD=ok|fail|badsum,
# FAKE_DOCKER_CP=ok|fail (copying the artifacts OUT of the container fails), FAKE_DOCKER_RM=fail (docker rm fails and removes nothing).
# The -e variables of the 20-build.sh call are kept in $S/env.20-build.
set -u
S="${FAKE_DOCKER_STATE:?}"; mkdir -p "$S/images" "$S/volumes" "$S/containers"
echo "$*" >> "$S/calls.log"
cmd="${1:-}"; shift || true
label_arg() { for a in "$@"; do case "$a" in ci-os.cachyos=*) echo "${a#*=}"; return;; esac; done; }
case "$cmd" in
  info) exit 0 ;;
  build) tag=""; while [ $# -gt 0 ]; do [ "$1" = -t ] && tag="$2"; shift; done; echo amd64 > "$S/images/$tag"; echo "building $tag" ;;
  image) # image inspect [-f F] TAG
    shift; [ "${1:-}" = -f ] && shift 2 || true
    [ -e "$S/images/${1:-}" ] || exit 1; cat "$S/images/$1" ;;
  volume)
    sub="$1"; shift
    case "$sub" in
      inspect) [ "${1:-}" = -f ] && shift 2; [ -e "$S/volumes/$1" ] || exit 1; cat "$S/volumes/$1" ;;
      create) lab="$(label_arg "$@")"; for last; do :; done; echo "$lab" > "$S/volumes/$last"; echo "$last" ;;
      rm) rm -f "$S/volumes/$1" ;;
    esac ;;
  inspect) fmt=""; [ "${1:-}" = -f ] && { fmt="$2"; shift 2; }; n="$1"; [ -d "$S/containers/$n" ] || exit 1
    case "$fmt" in *State.Running*) cat "$S/containers/$n/running" ;; *Labels*) cat "$S/containers/$n/label" ;; esac ;;
  run) name=""; lab=""; prev=""; for a in "$@"; do [ "$prev" = --name ] && name="$a"; case "$a" in ci-os.cachyos=*) lab="${a#*=}";; esac; prev="$a"; done
    mkdir -p "$S/containers/$name/out"; echo "$lab" > "$S/containers/$name/label"; echo true > "$S/containers/$name/running"; echo "$name" ;;
  exec)
    envs=""; while [ "${1:-}" = -e ]; do envs="$envs $2"; shift 2; done
    n="$1"; shift
    case "$*" in
      *10-bootstrap.sh) echo "fake bootstrap ok" ;;
      *20-build.sh)
        printf '%s\n' "$envs" > "$S/env.20-build"
        case "${FAKE_DOCKER_BUILD:-ok}" in
          fail) echo "fake build: mkarchiso exploded"; exit 1 ;;
        esac
        o="$S/containers/$n/out"; iso="${FAKE_ISO_NAME:?}"; base="${iso%.iso}"
        printf 'not a real iso, %s\n' "$iso" > "$o/$iso"
        if [ "${FAKE_DOCKER_BUILD:-ok}" = badsum ]; then echo "0000000000000000000000000000000000000000000000000000000000000000  $iso" > "$o/$iso.sha256"
        else ( cd "$o" && { sha256sum "$iso" 2>/dev/null || shasum -a 256 "$iso"; } > "$iso.sha256" ); fi
        echo "linux-cachyos 1.0-1" > "$o/$base.pkgs.txt"; echo "CI_OS_EDITION=cachyos-plasma" > "$o/$base.build-info"
        echo "fake build ok" ;;
      *) : ;;
    esac ;;
  cp) src="$1"; dst="$2"
    if [ "$src" = - ]; then tar -tf - > "$S/pushed-$(echo "$dst" | tr '/:' '__').txt"; exit 0; fi
    [ "${FAKE_DOCKER_CP:-ok}" != fail ] || { echo "fake docker: cp out of the container failed" >&2; exit 1; }
    n="${src%%:*}"; [ -d "$S/containers/$n" ] || exit 1; mkdir -p "$dst"; cp -R "$S/containers/$n/out/." "$dst/" ;;
  rm) [ "${FAKE_DOCKER_RM:-ok}" != fail ] || { echo "fake docker: rm failed" >&2; exit 1; }
      shift_n=0; for a in "$@"; do case "$a" in -*) ;; *) rm -rf "$S/containers/$a" ;; esac; done ;;
  *) echo "fake docker: unhandled: $cmd $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$FAKE/docker"

ISO_EXPECT="companion-os-plasma-2026.10.03-x86_64.iso"
run_build() { # run_build NAME ARGS...: build-iso.sh with the fake docker; output in $W/<NAME>.out; status in BUILD_RC
  local name="$1"; shift
  BUILD_RC=0
  CI_OS_DOCKER="$FAKE/docker" FAKE_DOCKER_STATE="$W/$name.state" FAKE_ISO_NAME="${FAKE_ISO_NAME:-$ISO_EXPECT}" bash "$BUILD" --source-date-epoch pin "$@" > "$W/$name.out" 2>&1 || BUILD_RC=$?
}

# C1 dry run: nothing executes ----------------------------------------------------------------------------------------------------
DRYOUT="$W/dry.out"; rm -rf "$W/dry.state"
CI_OS_DOCKER="$FAKE/docker" FAKE_DOCKER_STATE="$W/dry.state" bash "$BUILD" --dry-run --source-date-epoch pin --out "$W/dry-out" > "$DRYOUT" 2>&1 && DRY_RC=0 || DRY_RC=$?
[ "$DRY_RC" -eq 0 ] && t_pass "C1 --dry-run exits 0" || t_fail "C1 --dry-run exited $DRY_RC: $(tail -n 3 "$DRYOUT")"
[ ! -s "$W/dry.state/calls.log" ] && t_pass "C1 --dry-run ran no docker command at all (and created no output directory)" || t_fail "C1 --dry-run called docker: $(cat "$W/dry.state/calls.log")"
[ ! -e "$W/dry-out" ] && t_pass "C1 --dry-run created nothing on disk" || t_fail "C1 --dry-run created the output directory"
for needle in "$UPSTREAM_SHA" "$BASE_IMAGE" "$ISO_EXPECT" "$CACHYOS_KEY_FPR" "$MIRRORLIST_SHA256" "$UPSTREAM_ARCHISO_TREE" \
              'docker build --platform linux/amd64' 'docker run -d --name ci-os-cachyos-build' 'docker volume create' \
              'tar -cf -' 'docker cp - ci-os-cachyos-build:/work/repo' '10-bootstrap.sh' '20-build.sh' 'docker cp ci-os-cachyos-build:/work/out/' \
              '--privileged' '--platform linux/amd64' 'SOURCE_DATE_EPOCH=1791041490' 'CI_OS_VERSION=1.0' 'CI_OS_OWNERSHIP_CHECK=error'; do
  if grep -qF -- "$needle" "$DRYOUT"; then t_pass "C1 the plan shows: $needle"; else t_fail "C1 the plan lacks: $needle"; fi
done
CI_OS_DOCKER="$FAKE/docker" FAKE_DOCKER_STATE="$W/dry2.state" bash "$BUILD" --print-plan --fallback-pin --version 7.1 --cpus 4 --jobs 2 --memory 12g --unprivileged --source-date-epoch now > "$W/dry2.out" 2>&1 && DRY_RC=0 || DRY_RC=$?
if [ "$DRY_RC" -eq 0 ] && grep -qF -- "$UPSTREAM_FALLBACK_SHA" "$W/dry2.out" && grep -qF -- 'CI_OS_VERSION=7.1' "$W/dry2.out" && grep -qF -- '--cap-add SYS_ADMIN' "$W/dry2.out" \
   && grep -qF -- '--cpus 4 --memory 12g' "$W/dry2.out" && grep -qF -- 'CI_OS_JOBS=2' "$W/dry2.out" && grep -qF -- 'CI_OS_PIN=fallback' "$W/dry2.out" && ! grep -qF -- '--privileged' "$W/dry2.out" \
   && grep -qE "companion-os-plasma-20[0-9]{2}\.[0-9]{2}\.[0-9]{2}-x86_64\.iso" "$W/dry2.out"; then
  t_pass "C1 --print-plan with --fallback-pin --version --cpus --jobs --memory --unprivileged --source-date-epoch now"
else t_fail "C1 options not reflected in the plan (rc $DRY_RC): $(grep -E 'pin|version|resources' "$W/dry2.out" | tr '\n' '|')"; fi
CI_OS_DOCKER="$FAKE/docker" FAKE_DOCKER_STATE="$W/dry3.state" bash "$BUILD" --dry-run --source-date-epoch 1798800000 > "$W/dry3.out" 2>&1 || true
grep -qF 'companion-os-plasma-2027.01.01-x86_64.iso' "$W/dry3.out" && t_pass "C1 --source-date-epoch SECONDS moves the date in the output name" || t_fail "C1 explicit epoch not reflected"
# without --source-date-epoch the ISO is dated by the day it is built
CI_OS_DOCKER="$FAKE/docker" FAKE_DOCKER_STATE="$W/dry4.state" bash "$BUILD" --dry-run > "$W/dry4.out" 2>&1 || true
TODAY="$(date -u +%Y.%m.%d)"
grep -qF "companion-os-plasma-$TODAY-x86_64.iso" "$W/dry4.out" && t_pass "C1 by default the ISO name carries the UTC build day ($TODAY); --source-date-epoch pin gives the reproducible name" || t_fail "C1 default date: $(grep 'output ISO' "$W/dry4.out")"
# the hash in the builder image tag follows the inputs
TAG1="$(grep -o 'ci-os-cachyos-builder:[0-9a-f]*' "$DRYOUT" | head -n 1)"
case "$TAG1" in ci-os-cachyos-builder:????????????) t_pass "C1 the builder image tag carries a 12-digit input hash ($TAG1)" ;; *) t_fail "C1 odd image tag: $TAG1" ;; esac

# C2 relocatable: a copy of the build scripts outside this repo -----------------------------------------------------------------------
R="$W/relocated"; mkdir -p "$R/backends/cachyos/iso"; R="$(cd "$R" && pwd)"     # pwd -P form: TMPDIR may end in a slash
cp "$LOCK" "$R/backends/cachyos/upstream.lock"; cp -R "$SCRIPTS" "$R/backends/cachyos/iso/scripts"; cp -R "$CACHYOS/iso/docker" "$R/backends/cachyos/iso/docker"
mkdir -p "$R/backends/cachyos/iso/overlay/files"; echo x > "$R/backends/cachyos/iso/overlay/files/marker"
mkdir -p "$R/core" "$R/vendor"
CI_OS_DOCKER="$FAKE/docker" FAKE_DOCKER_STATE="$W/reloc.state" bash "$R/backends/cachyos/iso/scripts/build-iso.sh" --dry-run --source-date-epoch pin > "$W/reloc.out" 2>&1 && RC=0 || RC=$?
if [ "$RC" -eq 0 ] && grep -qF "repo              $R" "$W/reloc.out" && grep -qF 'backends/cachyos core vendor' "$W/reloc.out" \
   && ! grep -E '^\+ COPYFILE_DISABLE' "$W/reloc.out" | grep -q ' assets'; then t_pass "C2 from a copy outside this repo: its own root is used and only the existing subtrees are copied in"
else t_fail "C2 relocated dry run (rc $RC): $(head -n 4 "$W/reloc.out" | tr '\n' '|')"; fi

# C3 prerequisites and arguments --------------------------------------------------------------------------------------------------------
CI_OS_DOCKER="ci-os-no-such-docker-binary" bash "$BUILD" --out "$W/nodocker-out" > "$W/nodocker.out" 2>&1 && RC=0 || RC=$?
if [ "$RC" -eq 2 ] && grep -q 'docker not found' "$W/nodocker.out" && grep -q -- '--dry-run' "$W/nodocker.out"; then t_pass "C3 without docker and without --dry-run: exit 2, says docker is missing and points at --dry-run"
else t_fail "C3 missing docker (rc $RC): $(cat "$W/nodocker.out")"; fi
[ ! -e "$W/nodocker-out" ] && t_pass "C3 ...and created no output directory" || t_fail "C3 output directory created before the prerequisite check"
for bad in "--ownership-check|maybe" "--stop-after|build" "--version|a b" "--version|" "--cpus|many" "--jobs|0" "--memory|lots" "--source-date-epoch|yesterday" "--cache-volume|ci-os-cachyos-work" "--nope|1"; do
  opt="${bad%%|*}"; val="${bad#*|}"
  bash "$BUILD" --dry-run "$opt" "$val" > "$W/arg.out" 2>&1 && RC=0 || RC=$?
  if [ "$RC" -eq 2 ]; then t_pass "C3 '$opt $val' is refused with exit 2"; else t_fail "C3 '$opt $val' gave exit $RC: $(head -n 2 "$W/arg.out")"; fi
done
bash "$BUILD" --help > "$W/help.out" 2>&1 && grep -q -- '--dry-run' "$W/help.out" && grep -q -- '--keep-container' "$W/help.out" && t_pass "C3 --help documents the options" || t_fail "C3 --help: $(head -n 3 "$W/help.out")"

# C4 the real code path against a fake docker ---------------------------------------------------------------------------------------------
run_build ok --out "$W/o1"
if [ "$BUILD_RC" -eq 0 ]; then t_pass "C4 happy path: exit 0"; else t_fail "C4 happy path failed (rc $BUILD_RC): $(tail -n 8 "$W/ok.out")"; fi
for a in "$ISO_EXPECT" "$ISO_EXPECT.sha256" "${ISO_EXPECT%.iso}.pkgs.txt" "${ISO_EXPECT%.iso}.build-info" "${ISO_EXPECT%.iso}.build.log"; do
  [ -s "$W/o1/$a" ] && t_pass "C4 artifact present: $a" || t_fail "C4 artifact missing: $a"
done
grep -q "^SHA256 [0-9a-f]\{64\}  $ISO_EXPECT\$" "$W/ok.out" && t_pass "C4 the SHA256 of the ISO is printed" || t_fail "C4 no SHA256 line: $(tail -n 4 "$W/ok.out")"
grep -q 'fake bootstrap ok' "$W/o1/${ISO_EXPECT%.iso}.build.log" && grep -q 'fake build ok' "$W/o1/${ISO_EXPECT%.iso}.build.log" && t_pass "C4 the host log has both in-container steps" || t_fail "C4 host log incomplete"
[ -z "$(ls -A "$W/ok.state/containers")" ] && [ ! -e "$W/ok.state/volumes/ci-os-cachyos-work" ] && t_pass "C4 the container and the work volume are gone afterwards" || t_fail "C4 leftovers: $(ls "$W/ok.state/containers" "$W/ok.state/volumes" | tr '\n' ' ')"
[ -e "$W/ok.state/volumes/ci-os-cachyos-pkgcache" ] && t_pass "C4 the package cache volume is kept" || t_fail "C4 cache volume deleted"
[ -z "$(find "$W/o1" -name '.partial*' -o -name '.build-*' | head -n 1)" ] && t_pass "C4 no temporary files are left in the output directory" || t_fail "C4 temp files left: $(find "$W/o1" -name '.*' -type f | tr '\n' ' ')"
PUSHED="$(cat "$W"/ok.state/pushed-*.txt 2>/dev/null | tr '\n' ' ')"
case "$PUSHED" in *backends/cachyos/upstream.lock*) t_pass "C4 the tar stream pushed into the container carries backends/cachyos/upstream.lock" ;; *) t_fail "C4 pushed tree lacks the lock: ${PUSHED:0:200}" ;; esac
case "$PUSHED" in *.DS_Store*|*'/._'*) t_fail "C4 .DS_Store or AppleDouble files were pushed" ;; *) t_pass "C4 no .DS_Store or AppleDouble files in the pushed tree" ;; esac
grep -q 'volume create --label ci-os.cachyos=work ci-os-cachyos-work' "$W/ok.state/calls.log" && grep -q 'run -d --name ci-os-cachyos-build --label ci-os.cachyos=build' "$W/ok.state/calls.log" && t_pass "C4 volumes and container are created with this script's label" || t_fail "C4 labels missing in: $(cat "$W/ok.state/calls.log")"

run_build again --out "$W/o1"
if [ "$BUILD_RC" -ne 0 ] && grep -q 'already exists' "$W/again.out" && grep -q -- '--force' "$W/again.out"; then t_pass "C4 a second build refuses to overwrite the ISO without --force (before touching docker)"
else t_fail "C4 overwrite check (rc $BUILD_RC): $(tail -n 3 "$W/again.out")"; fi
[ ! -s "$W/again.state/calls.log" ] || ! grep -qE '^(run|build|volume create)' "$W/again.state/calls.log" && t_pass "C4 ...it created no container, volume or image" || t_fail "C4 docker was used before the overwrite check"
echo OLD > "$W/o1/$ISO_EXPECT"
run_build forced --out "$W/o1" --force
if [ "$BUILD_RC" -eq 0 ] && ! grep -q '^OLD$' "$W/o1/$ISO_EXPECT"; then t_pass "C4 --force replaces the existing ISO"; else t_fail "C4 --force (rc $BUILD_RC): $(tail -n 3 "$W/forced.out")"; fi

FAKE_DOCKER_BUILD=badsum run_build badsum --out "$W/o3"
if [ "$BUILD_RC" -ne 0 ] && grep -q 'sha256 mismatch' "$W/badsum.out"; then t_pass "C4 a corrupt copy (hash differs from the container's .sha256) fails the build"; else t_fail "C4 badsum (rc $BUILD_RC): $(tail -n 3 "$W/badsum.out")"; fi
[ -z "$(find "$W/o3" -name 'companion-os-plasma-*' ! -name '*.failed.log' | head -n 1)" ] && t_pass "C4 ...and nothing was installed into the output directory" || t_fail "C4 files installed despite the mismatch: $(ls -A "$W/o3" | tr '\n' ' ')"

FAKE_DOCKER_BUILD=fail run_build failing --out "$W/o4"
if [ "$BUILD_RC" -ne 0 ] && grep -q '20-build.sh failed' "$W/failing.out"; then t_pass "C4 a failing in-container build fails the run"; else t_fail "C4 failing build (rc $BUILD_RC): $(tail -n 3 "$W/failing.out")"; fi
[ -s "$W/o4/${ISO_EXPECT%.iso}.failed.log" ] && grep -q 'mkarchiso exploded' "$W/o4/${ISO_EXPECT%.iso}.failed.log" && t_pass "C4 ...the log is kept as <name>.failed.log" || t_fail "C4 no failed log: $(ls -A "$W/o4" | tr '\n' ' ')"
[ -z "$(ls -A "$W/failing.state/containers")" ] && [ ! -e "$W/failing.state/volumes/ci-os-cachyos-work" ] && t_pass "C4 ...and the container and work volume are cleaned up anyway" || t_fail "C4 leftovers after a failure"

FAKE_DOCKER_BUILD=fail run_build keep --out "$W/o5" --keep-container
if [ "$BUILD_RC" -ne 0 ] && [ -d "$W/keep.state/containers/ci-os-cachyos-build" ] && [ -e "$W/keep.state/volumes/ci-os-cachyos-work" ] && grep -q 'kept container' "$W/keep.out"; then t_pass "C4 --keep-container leaves the container and the work volume, and says how to remove them"
else t_fail "C4 --keep-container (rc $BUILD_RC): $(tail -n 3 "$W/keep.out")"; fi

run_build stop --out "$W/o10" --stop-after validate
if [ "$BUILD_RC" -eq 0 ] && grep -q "ran up to 'validate'" "$W/stop.out" && grep -q 'CI_OS_STOP_AFTER=validate' "$W/stop.state/calls.log"; then t_pass "C4 --stop-after validate runs both container steps with CI_OS_STOP_AFTER set and exits 0"
else t_fail "C4 --stop-after (rc $BUILD_RC): $(tail -n 4 "$W/stop.out")"; fi
[ ! -e "$W/o10" ] && [ -z "$(ls -A "$W/stop.state/containers")" ] && [ ! -e "$W/stop.state/volumes/ci-os-cachyos-work" ] && t_pass "C4 ...copies nothing out (no output directory) and removes the container and the work volume" || t_fail "C4 --stop-after left things: $(ls -A "$W/o10" 2>&1 | tr '\n' ' ')"

# a container with our name that this script did not create must be left alone
mkdir -p "$W/foreign.state/containers/ci-os-cachyos-build"; echo "" > "$W/foreign.state/containers/ci-os-cachyos-build/label"; echo false > "$W/foreign.state/containers/ci-os-cachyos-build/running"
run_build foreign --out "$W/o6"
if [ "$BUILD_RC" -ne 0 ] && grep -q 'was not created by this script' "$W/foreign.out" && [ -d "$W/foreign.state/containers/ci-os-cachyos-build" ]; then t_pass "C4 a container named ci-os-cachyos-build that this script did not create is refused and not removed"
else t_fail "C4 foreign container (rc $BUILD_RC): $(tail -n 3 "$W/foreign.out")"; fi
mkdir -p "$W/foreignvol.state/volumes"; echo "" > "$W/foreignvol.state/volumes/ci-os-cachyos-pkgcache"
run_build foreignvol --out "$W/o7"
if [ "$BUILD_RC" -ne 0 ] && grep -q 'was not created by this script' "$W/foreignvol.out" && [ -e "$W/foreignvol.state/volumes/ci-os-cachyos-pkgcache" ]; then t_pass "C4 a foreign cache volume is refused (use --cache-volume) and not touched"
else t_fail "C4 foreign volume (rc $BUILD_RC): $(tail -n 3 "$W/foreignvol.out")"; fi
mkdir -p "$W/running.state/containers/ci-os-cachyos-build"; echo build > "$W/running.state/containers/ci-os-cachyos-build/label"; echo true > "$W/running.state/containers/ci-os-cachyos-build/running"
run_build running --out "$W/o8"
if [ "$BUILD_RC" -ne 0 ] && grep -q 'another build is in progress' "$W/running.out" && [ -d "$W/running.state/containers/ci-os-cachyos-build" ]; then t_pass "C4 a RUNNING build container of its own is not killed: the second build stops with a hint"
else t_fail "C4 running container (rc $BUILD_RC): $(tail -n 3 "$W/running.out")"; fi
mkdir -p "$W/stale.state/containers/ci-os-cachyos-build" "$W/stale.state/volumes"; echo build > "$W/stale.state/containers/ci-os-cachyos-build/label"; echo false > "$W/stale.state/containers/ci-os-cachyos-build/running"; echo work > "$W/stale.state/volumes/ci-os-cachyos-work"
run_build stale --out "$W/o9"
[ "$BUILD_RC" -eq 0 ] && grep -q 'removing the stopped' "$W/stale.out" && t_pass "C4 a stopped container and work volume left by an earlier run of this script are replaced" || t_fail "C4 stale leftovers (rc $BUILD_RC): $(tail -n 4 "$W/stale.out")"

# C5 the working tree the ISO is built from ---------------------------------------------------------------------------------------------
printf '== Part C5: working-tree provenance\n'
# git as a stranger's machine runs it: no inherited GIT_DIR (a pre-push hook exports one), no user or system config, no hooks
rgit() { local d="$1"; shift
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
      git -c core.hooksPath=/dev/null -c commit.gpgsign=false -C "$d" "$@"; }
cdig() { ( export CI_PROG=test; . "$SCRIPTS/lib/common.sh"; "$@" ); }       # run a lib/common.sh function in a subshell
TR="$W/tree-repo"; TREE_ROOT="$TR"
tgit() { rgit "$TR" "$@"; }
mk_tree_repo() { # a throwaway repository $TR: a copy of the build scripts, a tiny repo subset, one commit
  rm -rf "$TR"; mkdir -p "$TR/backends/cachyos/iso/overlay/files" "$TR/core/headless/payload" "$TR/vendor"
  cp "$LOCK" "$TR/backends/cachyos/upstream.lock"; cp -R "$SCRIPTS" "$TR/backends/cachyos/iso/scripts"; cp -R "$CACHYOS/iso/docker" "$TR/backends/cachyos/iso/docker"
  echo x > "$TR/backends/cachyos/iso/overlay/files/marker"; echo p > "$TR/core/headless/payload/file"; echo v > "$TR/vendor/v"
  echo outside > "$TR/README.md"; printf '*.secret\n' > "$TR/.gitignore"
  tgit init -q 2>/dev/null; tgit add -A; tgit commit -q -m init
}
tree_run() { # tree_run NAME ARGS...: dry run of the build script in $TREE_ROOT; output in $W/NAME.out, status in TRC
  local name="$1"; shift
  TRC=0
  bash "$TREE_ROOT/backends/cachyos/iso/scripts/build-iso.sh" --dry-run --source-date-epoch pin "$@" > "$W/$name.out" 2>&1 || TRC=$?
}
dirty_case() { # dirty_case NAME KIND PATH WHAT: $TR was changed; the default run lists PATH as KIND and goes ahead, --require-clean refuses
  tree_run "$1"
  if [ "$TRC" -eq 0 ] && grep -qE "^    $2 $3\$" "$W/$1.out" && grep -q 'warning: the ISO is built from the WORKING TREE' "$W/$1.out" && grep -q 'working tree: DIRTY' "$W/$1.out"; then
    t_pass "C5 $4: listed as '$2', warned about, the build still goes ahead"
  else t_fail "C5 $4 (exit $TRC): $(grep -E 'working tree|^    |warning' "$W/$1.out" | head -n 6 | tr '\n' '|')"; fi
  tree_run "$1-req" --require-clean
  if [ "$TRC" -eq 1 ] && grep -qE "^    $2 $3\$" "$W/$1-req.out" && grep -q 'ERROR: --require-clean' "$W/$1-req.out"; then t_pass "C5 ...and --require-clean refuses it (exit 1, the file is named)"
  else t_fail "C5 $4 with --require-clean (exit $TRC): $(grep -E 'ERROR|^    ' "$W/$1-req.out" | head -n 4 | tr '\n' '|')"; fi
}

mk_tree_repo; COMMIT_T="$(tgit rev-parse HEAD)"
tree_run tclean
if [ "$TRC" -eq 0 ] && grep -qF "commit            $COMMIT_T   working tree: clean" "$W/tclean.out" && ! grep -qi 'warning' "$W/tclean.out"; then t_pass "C5 a clean tree: the plan names the commit and says clean, nothing is warned about"
else t_fail "C5 clean tree (exit $TRC): $(grep -E 'commit|warning' "$W/tclean.out" | head -n 3 | tr '\n' '|')"; fi
tree_run tclean-req --require-clean
[ "$TRC" -eq 0 ] && t_pass "C5 --require-clean accepts a clean tree" || t_fail "C5 --require-clean on a clean tree: exit $TRC"

echo more >> "$TR/core/headless/payload/file"
dirty_case tmod changed core/headless/payload/file "an edited tracked file"
tree_run tallow --allow-dirty
if [ "$TRC" -eq 0 ] && ! grep -qi 'warning' "$W/tallow.out" && ! grep -q 'payload/file' "$W/tallow.out" && grep -q 'working tree: DIRTY' "$W/tallow.out"; then t_pass "C5 --allow-dirty builds without the warning or the list (the plan still says DIRTY)"
else t_fail "C5 --allow-dirty (exit $TRC): $(head -n 4 "$W/tallow.out" | tr '\n' '|')"; fi
tree_run tboth --allow-dirty --require-clean
[ "$TRC" -eq 2 ] && grep -q 'contradict' "$W/tboth.out" && t_pass "C5 --allow-dirty with --require-clean is a usage error (exit 2)" || t_fail "C5 both flags: exit $TRC"
tree_run tstop --stop-after overlay
if [ "$TRC" -eq 0 ] && ! grep -qi 'warning' "$W/tstop.out" && grep -q 'builds no ISO, so nothing of it ships' "$W/tstop.out"; then t_pass "C5 --stop-after builds no ISO: a one-line note instead of the warning"
else t_fail "C5 --stop-after on a dirty tree (exit $TRC): $(head -n 3 "$W/tstop.out" | tr '\n' '|')"; fi
tree_run tstop-req --stop-after overlay --require-clean
[ "$TRC" -eq 1 ] && t_pass "C5 ...but --require-clean still applies to it" || t_fail "C5 --stop-after --require-clean: exit $TRC"

mk_tree_repo; echo x > "$TR/core/headless/payload/stray.orig"
dirty_case tuntracked untracked core/headless/payload/stray.orig "an untracked file in the payload"
mk_tree_repo; echo secret > "$TR/core/headless/payload/token.secret"
dirty_case tignored ignored core/headless/payload/token.secret "an IGNORED file (a stray .env would be one)"
mk_tree_repo; echo n > "$TR/backends/cachyos/iso/overlay/files/new"; tgit add backends/cachyos/iso/overlay/files/new
dirty_case tstaged changed backends/cachyos/iso/overlay/files/new "a file that is staged but not committed"
mk_tree_repo; rm "$TR/vendor/v"
dirty_case tdeleted changed vendor/v "a deleted tracked file"

# what the tar leaves out never reaches the container, so it is not dirt; nor is anything outside the copied subset
mk_tree_repo
mkdir -p "$TR/core/headless/payload/__pycache__" "$TR/backends/cachyos/iso/overlay/files/sub" "$TR/vendor/x.iso"
: > "$TR/core/headless/payload/.DS_Store"; : > "$TR/core/headless/payload/._file"; : > "$TR/core/headless/payload/__pycache__/m.cpython-312.pyc"
: > "$TR/core/headless/payload/mod.pyc"; : > "$TR/vendor/disc.iso"; : > "$TR/vendor/x.iso/inner"; : > "$TR/backends/cachyos/iso/overlay/files/sub/.DS_Store"
echo changed >> "$TR/README.md"; mkdir -p "$TR/docs"; echo x > "$TR/docs/new.md"
[ -n "$(tgit status --porcelain -uall)" ] && t_pass "C5 (fixture) git itself sees .DS_Store, ._*, __pycache__, *.pyc, *.iso and files outside the subset as untracked or changed" || t_fail "C5 fixture: git sees nothing"
tree_run texcl
if [ "$TRC" -eq 0 ] && grep -q 'working tree: clean' "$W/texcl.out" && ! grep -qi 'warning' "$W/texcl.out"; then t_pass "C5 files the tar leaves out, and files outside the copied subset, do not make the tree dirty"
else t_fail "C5 tar-excluded files (exit $TRC): $(grep -E 'working tree|^    ' "$W/texcl.out" | head -n 6 | tr '\n' '|')"; fi

# not a git checkout, a copy inside another repository, and a hook's GIT_DIR in the environment
rm -rf "$W/tree-nogit"; mk_tree_repo; cp -R "$TR" "$W/tree-nogit"; rm -rf "$W/tree-nogit/.git"
TREE_ROOT="$W/tree-nogit" tree_run tnogit
if [ "$TRC" -eq 0 ] && grep -q 'working tree: unknown' "$W/tnogit.out" && grep -q 'not a git checkout' "$W/tnogit.out"; then t_pass "C5 a tree without .git: the state is 'unknown', said once, and the build is not stopped"
else t_fail "C5 no .git (exit $TRC): $(head -n 3 "$W/tnogit.out" | tr '\n' '|')"; fi
TREE_ROOT="$W/tree-nogit" tree_run tnogit-req --require-clean
[ "$TRC" -eq 1 ] && grep -q 'cannot be shown to be clean' "$W/tnogit-req.out" && t_pass "C5 --require-clean cannot prove a tree without .git clean: exit 1" || t_fail "C5 no .git with --require-clean: exit $TRC"
mkdir -p "$TR/nested"; cp -R "$W/tree-nogit/." "$TR/nested/"
TREE_ROOT="$TR/nested" tree_run tnested
if [ "$TRC" -eq 0 ] && grep -q 'working tree: unknown' "$W/tnested.out"; then t_pass "C5 a copy dropped inside another repository is not mistaken for that repository's tree"
else t_fail "C5 nested copy (exit $TRC): $(grep -E 'commit|warning' "$W/tnested.out" | head -n 3 | tr '\n' '|')"; fi
rm -rf "$TR/nested"
COMMIT_T="$(tgit rev-parse HEAD)"
GIT_DIR="$W/no-such-gitdir" GIT_WORK_TREE="$W" GIT_INDEX_FILE="$W/no-index" tree_run tleak
if [ "$TRC" -eq 0 ] && grep -qF "commit            $COMMIT_T" "$W/tleak.out"; then t_pass "C5 a GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE exported by a hook does not redirect the tree check"
else t_fail "C5 hook environment (exit $TRC): $(grep -E 'commit|ERROR|fatal' "$W/tleak.out" | head -n 3 | tr '\n' '|')"; fi

# ci_repo_dirty_files itself: kind and sort order
mk_tree_repo; echo more >> "$TR/vendor/v"; echo x > "$TR/core/headless/payload/zz.orig"; echo s > "$TR/core/headless/payload/a.secret"
got="$(cdig ci_repo_dirty_files "$TR" backends/cachyos core vendor | tr '\n' '|')"
[ "$got" = "changed vendor/v|ignored core/headless/payload/a.secret|untracked core/headless/payload/zz.orig|" ] && t_pass "C5 ci_repo_dirty_files: one 'KIND path' line per changed, ignored and untracked file, sorted" || t_fail "C5 ci_repo_dirty_files gave [$got]"
cdig ci_repo_dirty_files "$TR" >/dev/null 2>&1 && t_fail "C5 ci_repo_dirty_files with no path was accepted (it would mean the whole repository)" || t_pass "C5 ci_repo_dirty_files without a path is refused instead of meaning 'the whole repository'"

# what the container is told, and what the plan shows
run_build_tree() { # run_build_tree NAME ARGS...: the build script of $TREE_ROOT against the fake docker
  local name="$1"; shift
  BUILD_RC=0
  CI_OS_DOCKER="$FAKE/docker" FAKE_DOCKER_STATE="$W/$name.state" FAKE_ISO_NAME="$ISO_EXPECT" bash "$TREE_ROOT/backends/cachyos/iso/scripts/build-iso.sh" --source-date-epoch pin "$@" > "$W/$name.out" 2>&1 || BUILD_RC=$?
}
mk_tree_repo; COMMIT_T="$(tgit rev-parse HEAD)"
run_build_tree tbuild-clean --out "$W/ot1"
if [ "$BUILD_RC" -eq 0 ] && grep -qF "CI_OS_REPO_COMMIT=$COMMIT_T" "$W/tbuild-clean.state/env.20-build" && grep -qF 'CI_OS_REPO_TREE=clean' "$W/tbuild-clean.state/env.20-build" \
   && grep -qF 'CI_OS_REPO_TREE_CHANGED=0' "$W/tbuild-clean.state/env.20-build"; then t_pass "C5 the container is told the commit and 'clean' (CI_OS_REPO_COMMIT, CI_OS_REPO_TREE, ...)"
else t_fail "C5 clean build (exit $BUILD_RC): $(cat "$W/tbuild-clean.state/env.20-build" 2>&1 | tr '\n' '|') $(tail -n 3 "$W/tbuild-clean.out" | tr '\n' '|')"; fi
echo more >> "$TR/core/headless/payload/file"; echo x > "$TR/core/headless/payload/stray.orig"
run_build_tree tbuild-dirty --out "$W/ot2"
if [ "$BUILD_RC" -eq 0 ] && grep -qF "CI_OS_REPO_COMMIT=$COMMIT_T" "$W/tbuild-dirty.state/env.20-build" && grep -qF 'CI_OS_REPO_TREE=dirty' "$W/tbuild-dirty.state/env.20-build" \
   && grep -qF 'CI_OS_REPO_TREE_CHANGED=1' "$W/tbuild-dirty.state/env.20-build" && grep -qF 'CI_OS_REPO_TREE_UNTRACKED=1' "$W/tbuild-dirty.state/env.20-build" \
   && grep -qF 'CI_OS_REPO_TREE_IGNORED=0' "$W/tbuild-dirty.state/env.20-build" && grep -q 'warning: the ISO is built from the WORKING TREE' "$W/tbuild-dirty.out"; then
  t_pass "C5 a dirty build still builds, warns, and tells the container 'dirty' with the counts (changed 1, untracked 1, ignored 0)"
else t_fail "C5 dirty build (exit $BUILD_RC): $(cat "$W/tbuild-dirty.state/env.20-build" 2>&1 | tr '\n' '|') $(grep -E 'warning|ERROR' "$W/tbuild-dirty.out" | head -n 2 | tr '\n' '|')"; fi
run_build_tree tbuild-req --out "$W/ot3" --require-clean
if [ "$BUILD_RC" -eq 1 ] && ! grep -qvx 'info' "$W/tbuild-req.state/calls.log" && [ ! -e "$W/ot3" ]; then t_pass "C5 --require-clean on a dirty tree stops before any container, volume or image exists, and creates no output directory"
else t_fail "C5 --require-clean build (exit $BUILD_RC): $(cat "$W/tbuild-req.state/calls.log" 2>&1 | head -n 3 | tr '\n' '|')"; fi
run_build_tree tbuild-allow --out "$W/ot4" --allow-dirty
if [ "$BUILD_RC" -eq 0 ] && ! grep -qi 'warning' "$W/tbuild-allow.out" && grep -qF 'CI_OS_REPO_TREE=dirty' "$W/tbuild-allow.state/env.20-build"; then t_pass "C5 --allow-dirty: no warning, and the record is still told 'dirty'"
else t_fail "C5 --allow-dirty build (exit $BUILD_RC): $(tail -n 3 "$W/tbuild-allow.out" | tr '\n' '|')"; fi
tree_run tplan
grep -qF "CI_OS_REPO_COMMIT=$COMMIT_T" "$W/tplan.out" && grep -qF 'CI_OS_REPO_TREE=dirty' "$W/tplan.out" && t_pass "C5 the dry-run plan shows the same -e variables" || t_fail "C5 plan lacks the provenance variables"

# the digest in the plan is the one the container will compute: both look at the tar's view of the overlay
mk_tree_repo
plan_digest() { tree_run "$1"; sed -n 's/^overlay .*tree digest \([0-9a-f]*\).*/\1/p' "$W/$1.out"; }
D1="$(plan_digest pd1)"
: > "$TR/backends/cachyos/iso/overlay/files/.DS_Store"; : > "$TR/backends/cachyos/iso/overlay/files/._marker"; mkdir -p "$TR/backends/cachyos/iso/overlay/files/__pycache__"; : > "$TR/backends/cachyos/iso/overlay/files/__pycache__/x.pyc"
D2="$(plan_digest pd2)"
echo y > "$TR/backends/cachyos/iso/overlay/files/marker"
D3="$(plan_digest pd3)"
[ -n "$D1" ] && [ "$D1" = "$D2" ] && [ "$D1" != "$D3" ] && t_pass "C5 the overlay digest in the plan ignores what the tar drops (.DS_Store, ._*, __pycache__) and follows real changes" || t_fail "C5 plan digest: [$D1] [$D2] [$D3]"
rm -rf "$W/tv-src" "$W/tv-dst"; mkdir -p "$W/tv-src/a/b" "$W/tv-src/a/__pycache__" "$W/tv-src/a/e.iso" "$W/tv-src/a/._d" "$W/tv-dst"
echo k > "$W/tv-src/a/keep"; echo k > "$W/tv-src/a/b/keep"; chmod 755 "$W/tv-src/a/b/keep"; ln -s keep "$W/tv-src/a/link"
: > "$W/tv-src/a/.DS_Store"; : > "$W/tv-src/a/b/._x"; : > "$W/tv-src/a/__pycache__/m.pyc"; : > "$W/tv-src/a/c.pyc"; : > "$W/tv-src/a/d.iso"; : > "$W/tv-src/a/e.iso/inner"; : > "$W/tv-src/a/._d/inner"
(
  export CI_PROG=test; . "$SCRIPTS/lib/common.sh"
  ex=(); for pat in "${CI_TAR_EXCLUDE_PATTERNS[@]}"; do ex+=("--exclude=$pat"); done
  COPYFILE_DISABLE=1 tar -cf - "${ex[@]}" -C "$W/tv-src" a | tar -xf - -C "$W/tv-dst"
  printf '%s %s %s\n' "$(ci_tree_digest "$W/tv-src" tar-view)" "$(ci_tree_digest "$W/tv-dst")" "$(ci_tree_digest "$W/tv-src")"
) > "$W/tv.out" 2>&1 || true
tv_a=""; tv_b=""; tv_c=""; read -r tv_a tv_b tv_c < "$W/tv.out" || true
if [ -n "$tv_a" ] && [ "$tv_a" = "$tv_b" ] && [ "$tv_a" != "$tv_c" ]; then t_pass "C5 ci_tar_excluded agrees with the real tar: the tar-view digest of a tree equals the digest of what tar extracts"
else t_fail "C5 tar view: $(tr '\n' ' ' < "$W/tv.out")"; fi

# C6 the output directory and the cleanup trap -------------------------------------------------------------------------------------------
printf '== Part C6: --out and cleanup\n'
: > "$W/afile"
run_build outfile --out "$W/afile/sub"
if [ "$BUILD_RC" -eq 2 ] && grep -q 'is not a directory, so .* cannot be created' "$W/outfile.out" && ! grep -qvx 'info' "$W/outfile.state/calls.log"; then t_pass "C6 an --out below a regular file is refused with exit 2 before docker creates anything (no 35-minute build first)"
else t_fail "C6 --out below a file (exit $BUILD_RC): $(tail -n 2 "$W/outfile.out" | tr '\n' '|') calls: $(tr '\n' '|' < "$W/outfile.state/calls.log")"; fi
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$W/ro"; chmod 555 "$W/ro"
  run_build outro --out "$W/ro/out"
  chmod 755 "$W/ro"
  if [ "$BUILD_RC" -eq 2 ] && grep -q 'is not writable, so .* cannot be created' "$W/outro.out" && ! grep -qvx 'info' "$W/outro.state/calls.log" && [ ! -e "$W/ro/out" ]; then t_pass "C6 an --out whose parent is read-only is refused with exit 2, nothing is created"
  else t_fail "C6 --out below a read-only directory (exit $BUILD_RC): $(tail -n 2 "$W/outro.out" | tr '\n' '|')"; fi
else t_skip "C6 read-only parent (running as root: every directory is writable)"; fi
run_build optval --out --force
if [ "$BUILD_RC" -eq 2 ] && grep -q "looks like another option" "$W/optval.out" && [ ! -s "$W/optval.state/calls.log" ]; then t_pass "C6 '--out --force' is a usage error: an option is not swallowed as the value"
else t_fail "C6 --out --force (exit $BUILD_RC): $(tail -n 2 "$W/optval.out" | tr '\n' '|')"; fi
run_build stopfile --out "$W/afile/sub" --stop-after validate
[ "$BUILD_RC" -eq 0 ] && t_pass "C6 --stop-after writes nothing to --out, so an unwritable one does not matter there" || t_fail "C6 --stop-after with an unwritable --out (exit $BUILD_RC): $(tail -n 3 "$W/stopfile.out" | tr '\n' '|')"
# the failed run's log cannot be saved (--out is unusable): that must not leave the container and the 25 GB volume behind
mkdir -p "$W/tmp-clean"
FAKE_DOCKER_BUILD=fail TMPDIR="$W/tmp-clean" run_build cleanfail --out "$W/afile/sub" --stop-after validate
if [ "$BUILD_RC" -ne 0 ] && [ -z "$(ls -A "$W/cleanfail.state/containers")" ] && [ ! -e "$W/cleanfail.state/volumes/ci-os-cachyos-work" ]; then t_pass "C6 when saving the failed log fails, the container and the work volume are still removed (cleanup does not abort half way)"
else t_fail "C6 cleanup after an unsavable log (exit $BUILD_RC): left $(ls "$W/cleanfail.state/containers" "$W/cleanfail.state/volumes" 2>&1 | tr '\n' ' ')"; fi
grep -q 'could not write' "$W/cleanfail.out" && [ -n "$(ls -A "$W/tmp-clean")" ] && t_pass "C6 ...and the log is kept where it was, with a message that says so" || t_fail "C6 no message about the unsaved log: $(tail -n 3 "$W/cleanfail.out" | tr '\n' '|')"

# a docker that cannot remove the container must not stop the cleanup before it has removed the work volume as well
FAKE_DOCKER_BUILD=fail FAKE_DOCKER_RM=fail run_build rmfail --out "$W/o12"
if [ "$BUILD_RC" -ne 0 ] && [ ! -e "$W/rmfail.state/volumes/ci-os-cachyos-work" ] && [ -s "$W/o12/${ISO_EXPECT%.iso}.failed.log" ]; then t_pass "C6 a failing 'docker rm' does not abort the cleanup: the work volume is removed and the failed log is saved anyway"
else t_fail "C6 cleanup with a failing docker rm (exit $BUILD_RC): volumes $(ls "$W/rmfail.state/volumes" 2>&1 | tr '\n' ' ') out $(ls -A "$W/o12" 2>&1 | tr '\n' ' ')"; fi

# a finished ISO that cannot be copied out is not thrown away with the container
FAKE_DOCKER_CP=fail run_build cpfail --out "$W/o11"
CTD="$W/cpfail.state/containers/ci-os-cachyos-build"
if [ "$BUILD_RC" -ne 0 ] && [ -s "$CTD/out/$ISO_EXPECT" ] && [ -e "$W/cpfail.state/volumes/ci-os-cachyos-work" ] && grep -q 'KEPT' "$W/cpfail.out" \
   && grep -qF 'docker cp ci-os-cachyos-build:/work/out/.' "$W/cpfail.out"; then t_pass "C6 build finished but docker cp out failed: the container and volume are KEPT with the ISO inside, and the docker cp command is printed"
else t_fail "C6 copy-out failure (exit $BUILD_RC): $(ls "$W/cpfail.state/containers" 2>&1 | tr '\n' ' ') $(grep -E 'KEPT|docker cp' "$W/cpfail.out" | head -n 2 | tr '\n' '|')"; fi
[ ! -e "$W/o11/$ISO_EXPECT" ] && [ -z "$(find "$W/o11" -name '.partial*' 2>/dev/null | head -n 1)" ] && t_pass "C6 ...nothing half-copied is left in --out" || t_fail "C6 leftovers in --out: $(ls -A "$W/o11" | tr '\n' ' ')"
BUILD_RC=0
CI_OS_DOCKER="$FAKE/docker" FAKE_DOCKER_STATE="$W/cpfail.state" FAKE_ISO_NAME="$ISO_EXPECT" bash "$BUILD" --source-date-epoch pin --out "$W/o11" > "$W/cpfail2.out" 2>&1 || BUILD_RC=$?
if [ "$BUILD_RC" -ne 0 ] && grep -q 'another build is in progress' "$W/cpfail2.out" && grep -q 'finished ISO that never reached --out' "$W/cpfail2.out" && [ -s "$CTD/out/$ISO_EXPECT" ]; then t_pass "C6 the next run does not delete the kept container; its message says it may hold an ISO and how to look"
else t_fail "C6 run after a kept container (exit $BUILD_RC): $(tail -n 2 "$W/cpfail2.out" | tr '\n' '|')"; fi
[ -d "$W/badsum.state/containers/ci-os-cachyos-build" ] && grep -q 'KEPT' "$W/badsum.out" && t_pass "C6 a corrupt copy (hash mismatch) also keeps the container: the copy may be retried" || t_fail "C6 container gone after a hash mismatch"

# --- Part D: the assertions behind upstream.lock ----------------------------------------------------------------------------------------------
printf '== Part D: pin, mirrorlist and key assertions\n'
# Each one is a function in lib/common.sh that 20-build.sh / 10-bootstrap.sh call. Here every one is run with the right value (it
# passes) and with a wrong one (it must refuse and say why), against a throwaway repository, a temp file or canned gpg output.
dcall() { # dcall FUNCTION ARGS...: run a lib/common.sh function in a subshell under set -e; output in $W/d.out, status in DRC
  DRC=0
  ( set -euo pipefail; export CI_PROG=test; . "$SCRIPTS/lib/common.sh"; "$@" ) > "$W/d.out" 2>&1 || DRC=$?
}
d_ok()  { local name="$1"; shift; dcall "$@"; if [ "$DRC" -eq 0 ]; then t_pass "D $name"; else t_fail "D $name (exit $DRC): $(head -n 3 "$W/d.out" | tr '\n' '|')"; fi; }
d_die() { local name="$1" pat="$2"; shift 2; dcall "$@"
  if [ "$DRC" -eq 0 ]; then t_fail "D $name: it was accepted"
  elif grep -qE -- "$pat" "$W/d.out"; then t_pass "D $name (refused: $pat)"
  else t_fail "D $name: refused, but not with /$pat/: $(head -n 3 "$W/d.out" | tr '\n' '|')"; fi; }
bump() { case "${1: -1}" in 0) printf '%s1' "${1%?}" ;; *) printf '%s0' "${1%?}" ;; esac; }     # the same string with another last character

# D1 ci_check_checkout: a throwaway "upstream" repository with a fixed committer time
UPR="$W/up-repo"
mk_up() {
  rm -rf "$UPR"; mkdir -p "$UPR/archiso"; echo profile > "$UPR/archiso/profiledef.sh"; echo top > "$UPR/README"
  rgit "$UPR" init -q 2>/dev/null; rgit "$UPR" add -A
  GIT_AUTHOR_DATE='2026-10-03T15:31:30Z' GIT_COMMITTER_DATE='2026-10-03T15:31:30Z' rgit "$UPR" commit -q -m pin
  UP_SHA="$(rgit "$UPR" rev-parse HEAD)"; UP_EPOCH="$(rgit "$UPR" log -1 --format=%ct)"; UP_TREE="$(rgit "$UPR" rev-parse HEAD:archiso)"
}
mk_up
[ "$UP_EPOCH" = "$EPOCH" ] && t_pass "D (fixture) the throwaway upstream commit has the committer time we set ($UP_EPOCH)" || t_fail "D fixture: committer time $UP_EPOCH, expected $EPOCH"
d_ok  "ci_check_checkout: the right commit, committer time and archiso/ tree" ci_check_checkout "$UPR" "$UP_SHA" "$UP_EPOCH" "$UP_TREE"
d_die "ci_check_checkout: another commit id" 'upstream HEAD is' ci_check_checkout "$UPR" "$(bump "$UP_SHA")" "$UP_EPOCH" "$UP_TREE"
d_die "ci_check_checkout: another committer time" 'upstream commit time is' ci_check_checkout "$UPR" "$UP_SHA" "$((UP_EPOCH + 1))" "$UP_TREE"
d_die "ci_check_checkout: another archiso/ tree id" 'upstream archiso/ tree is' ci_check_checkout "$UPR" "$UP_SHA" "$UP_EPOCH" "$(bump "$UP_TREE")"
echo edited >> "$UPR/archiso/profiledef.sh"
d_die "ci_check_checkout: a modified tracked file" 'not clean' ci_check_checkout "$UPR" "$UP_SHA" "$UP_EPOCH" "$UP_TREE"
rgit "$UPR" checkout -q -- archiso/profiledef.sh; : > "$UPR/archiso/stray"
d_die "ci_check_checkout: an untracked file" 'not clean' ci_check_checkout "$UPR" "$UP_SHA" "$UP_EPOCH" "$UP_TREE"
rm "$UPR/archiso/stray"
d_ok  "ci_check_checkout: clean again" ci_check_checkout "$UPR" "$UP_SHA" "$UP_EPOCH" "$UP_TREE"
echo more >> "$UPR/README"; rgit "$UPR" commit -q -am second
d_die "ci_check_checkout: HEAD moved on from the pin (the same archiso/ tree, a newer commit)" 'upstream HEAD is' ci_check_checkout "$UPR" "$UP_SHA" "$UP_EPOCH" "$UP_TREE"
mkdir -p "$W/not-a-repo"
d_die "ci_check_checkout: a directory that is not a git checkout" 'not a git checkout' ci_check_checkout "$W/not-a-repo" "$UP_SHA" "$UP_EPOCH" "$UP_TREE"
mk_up; rgit "$UPR" rm -rq archiso; rgit "$UPR" commit -q -m 'no archiso'
d_die "ci_check_checkout: a commit without an archiso/ directory" 'no archiso/' ci_check_checkout "$UPR" "$(rgit "$UPR" rev-parse HEAD)" "$(rgit "$UPR" log -1 --format=%ct)" "$UP_TREE"
d_die "ci_check_checkout: a directory that does not exist" 'is not a directory' ci_check_checkout "$W/no-such-dir" "$UP_SHA" "$UP_EPOCH" "$UP_TREE"

# D2 ci_check_sha256 (the pinned cachyos-mirrorlist)
printf 'Server = https://cdn77.cachyos.org/repo/$arch/$repo\n' > "$W/mirrorlist"
ML_SHA="$(cdig ci_sha256_file "$W/mirrorlist")"
d_ok  "ci_check_sha256: the pinned hash" ci_check_sha256 "$W/mirrorlist" "$ML_SHA" "cachyos-mirrorlist"
d_die "ci_check_sha256: a mirrorlist that is not the pinned one" 'cachyos-mirrorlist has sha256 .* pins' ci_check_sha256 "$W/mirrorlist" "$(bump "$ML_SHA")" "cachyos-mirrorlist"
printf 'Server = https://evil.example/\n' > "$W/mirrorlist2"
d_die "ci_check_sha256: the pinned hash and a tampered file" 'has sha256' ci_check_sha256 "$W/mirrorlist2" "$ML_SHA" "cachyos-mirrorlist"
d_die "ci_check_sha256: an empty pin" 'not 64 lowercase hex' ci_check_sha256 "$W/mirrorlist" "" "cachyos-mirrorlist"
d_die "ci_check_sha256: an upper-case pin (the lock holds lower case)" 'not 64 lowercase hex' ci_check_sha256 "$W/mirrorlist" "$(printf '%s' "$ML_SHA" | tr 'a-f' 'A-F')" "cachyos-mirrorlist"
d_die "ci_check_sha256: a file that does not exist" 'cannot hash' ci_check_sha256 "$W/no-such-mirrorlist" "$ML_SHA" "cachyos-mirrorlist"

# D3 ci_check_fpr / ci_check_key_fpr (the CachyOS repository key). gpg is stood in for by canned --with-colons output chosen by the
# content of the key file, so the parsing (primary key only, subkeys ignored, exactly one key) is tested without a real key or gpg.
FPR="$(sed -n 's/^CACHYOS_KEY_FPR=//p' "$LOCK")"
d_ok  "ci_check_fpr: the pinned fingerprint" ci_check_fpr "$FPR" "$FPR" "key"
d_die "ci_check_fpr: another fingerprint" 'carries key .*, not the pinned' ci_check_fpr "$(bump "$FPR")" "$FPR" "key"
d_die "ci_check_fpr: nothing found" 'carries key .<none>' ci_check_fpr "" "$FPR" "key"
d_die "ci_check_fpr: an empty pin is not matched by an empty finding" 'not a full 40-digit' ci_check_fpr "" "" "key"
d_die "ci_check_fpr: a lower-case pin" 'not a full 40-digit' ci_check_fpr "$(printf '%s' "$FPR" | tr 'A-F' 'a-f')" "$(printf '%s' "$FPR" | tr 'A-F' 'a-f')" "key"
d_die "ci_check_fpr: a short pin" 'not a full 40-digit' ci_check_fpr "${FPR#????????}" "${FPR#????????}" "key"
mkdir -p "$W/fakegpg"
cat > "$W/fakegpg/gpg" <<'GPGEOF'
#!/usr/bin/env bash
# canned `gpg --batch --show-keys --with-colons FILE`, chosen by the content of FILE (the last argument)
f="${!#}"
one() { printf 'pub:-:3072:1:F3B607488DB35A47:1628600000:::-:::scESC:::::::\nfpr:::::::::882DCFE48E2051D48E2562ABF3B607488DB35A47:\nuid:-::::1628600000::AAAA::CachyOS <admin@cachyos.org>::::::::::0:\nsub:-:3072:1:9B71BE9D397982C5:1628600000::::::e::::::\nfpr:::::::::9149495EB47A04A82FF0BA6F9B71BE9D397982C5:\n'; }
two() { printf 'pub:-:255:22:1111111111111111:1628600000:::-:::scESC:::::::\nfpr:::::::::0000000000000000000000000000000011111111:\nuid:-::::1628600000::BBBB::Someone Else <x@example.invalid>::::::::::0:\n'; }
case "$(cat "$f")" in
  one) one ;;
  two) one; two ;;
  other) two ;;
  broken) exit 2 ;;
esac
GPGEOF
chmod +x "$W/fakegpg/gpg"
for k in one two other none broken; do printf '%s\n' "$k" > "$W/key-$k.asc"; done
PATH="$W/fakegpg:$PATH" d_ok  "ci_check_key_fpr: one primary key, the pinned one (its subkey's fingerprint is not mistaken for it)" ci_check_key_fpr "$W/key-one.asc" "$FPR"
PATH="$W/fakegpg:$PATH" d_die "ci_check_key_fpr: the pin does not match the key in the file" 'carries key .*, not the pinned' ci_check_key_fpr "$W/key-one.asc" "$(bump "$FPR")"
PATH="$W/fakegpg:$PATH" d_die "ci_check_key_fpr: a file with another key" 'carries key .0000000000000000000000000000000011111111' ci_check_key_fpr "$W/key-other.asc" "$FPR"
PATH="$W/fakegpg:$PATH" d_die "ci_check_key_fpr: the pinned key plus a second key (pacman-key --add would import both)" 'holds 2 primary keys' ci_check_key_fpr "$W/key-two.asc" "$FPR"
PATH="$W/fakegpg:$PATH" d_die "ci_check_key_fpr: a file with no key in it" 'carries key .<none>' ci_check_key_fpr "$W/key-none.asc" "$FPR"
PATH="$W/fakegpg:$PATH" d_die "ci_check_key_fpr: gpg failing is a refusal, not a pass" 'carries key .<none>' ci_check_key_fpr "$W/key-broken.asc" "$FPR"
if command -v gpg >/dev/null 2>&1; then
  mkdir -p "$W/gnupg-empty"; chmod 700 "$W/gnupg-empty"
  GNUPGHOME="$W/gnupg-empty" d_ok  "ci_check_key_fpr: the key file committed in iso/docker carries exactly the fingerprint in upstream.lock (real gpg)" ci_check_key_fpr "$CACHYOS/iso/docker/cachyos-repo-key.asc" "$FPR"
  GNUPGHOME="$W/gnupg-empty" d_die "ci_check_key_fpr: ...and not a one-digit-different pin (real gpg)" 'carries key' ci_check_key_fpr "$CACHYOS/iso/docker/cachyos-repo-key.asc" "$(bump "$FPR")"
  GNUPGHOME="$W/gnupg-empty" d_die "ci_check_key_fpr: a file that is not a key (real gpg)" 'carries key .<none>' ci_check_key_fpr "$W/mirrorlist" "$FPR"
else t_skip "D ci_check_key_fpr against the committed key file (gpg is not installed here; the canned-output cases above ran)"; fi

# D4 the other small helpers the build record relies on
CI_OS_TEST_VAL=dirty d_ok  "ci_env_value: a value of the expected shape" ci_env_value CI_OS_TEST_VAL '^(clean|dirty|unknown)$' unknown
[ "$(cat "$W/d.out")" = dirty ] && t_pass "D ...is returned as it is" || t_fail "D ci_env_value returned [$(cat "$W/d.out")]"
d_ok  "ci_env_value: unset falls back to the default" ci_env_value CI_OS_TEST_UNSET '^(clean|dirty|unknown)$' unknown
[ "$(cat "$W/d.out")" = unknown ] && t_pass "D ...and the default is returned" || t_fail "D ci_env_value default returned [$(cat "$W/d.out")]"
CI_OS_TEST_VAL=bogus d_die "ci_env_value: a value of another shape" 'unexpected value' ci_env_value CI_OS_TEST_VAL '^(clean|dirty|unknown)$' unknown
CI_OS_TEST_VAL="$(printf 'dirty\nEVIL=1')" d_die "ci_env_value: a second line smuggled into a value that goes into the KEY=VALUE record" 'several lines' ci_env_value CI_OS_TEST_VAL '^(clean|dirty|unknown)$' unknown
mkdir -p "$W/outd/existing"
d_ok  "ci_out_dir_problem: an existing writable directory" ci_out_dir_problem "$W/outd/existing"
d_ok  "ci_out_dir_problem: a directory that can be created below a writable one" ci_out_dir_problem "$W/outd/new/deeper/x"
[ ! -e "$W/outd/new" ] && t_pass "D ...and nothing was created to find that out" || t_fail "D ci_out_dir_problem created $W/outd/new"
d_die "ci_out_dir_problem: a path below a regular file" 'is not a directory, so' ci_out_dir_problem "$W/afile/x/y"
d_die "ci_out_dir_problem: the path is a regular file" 'exists and is not a directory' ci_out_dir_problem "$W/afile"
d_die "ci_out_dir_problem: an empty path" 'empty' ci_out_dir_problem ""

# D5 the call sites: neutering a call (or running it after the thing it guards) must fail here too. Anchored on whole lines, so a
# commented-out call or one followed by `|| true` does not match.
site() { # site NAME FILE ERE
  if grep -qE -- "$3" "$2"; then t_pass "D call site: $1"; else t_fail "D call site: $1 (no line of ${2#"$CACHYOS"/} matches /$3/)"; fi
}
BUILD_SH="$SCRIPTS/in-container/20-build.sh"; BOOT_SH="$SCRIPTS/in-container/10-bootstrap.sh"; DOCKERFILE="$CACHYOS/iso/docker/Dockerfile.builder"
site "20-build.sh checks the commit, committer time and archiso/ tree against the pin" "$BUILD_SH" '^ci_check_checkout "\$UP" "\$PIN_SHA" "\$PIN_EPOCH" "\$PIN_TREE"$'
site "20-build.sh checks the fetched mirrorlist against MIRRORLIST_SHA256" "$BUILD_SH" '^ci_check_sha256 "\$mirrorlist" "\$MIRRORLIST_SHA256" "cachyos-mirrorlist from \$mirror_url"$'
site "20-build.sh records the hash of what it fetched, not the lock's" "$BUILD_SH" "printf 'MIRRORLIST_SHA256=%s.n' \"\\\$MIRRORLIST_ACTUAL\""
site "10-bootstrap.sh checks the key file's fingerprint" "$BOOT_SH" '^  ci_check_key_fpr "\$KEY_FILE" "\$CACHYOS_KEY_FPR" *(#.*)?$'
if awk '/ci_check_key_fpr "\$KEY_FILE"/ { c = NR } /pacman-key --add "\$KEY_FILE"/ { a = NR } END { exit !(c && a && c < a) }' "$BOOT_SH"; then t_pass "D call site: 10-bootstrap.sh checks the key BEFORE pacman-key --add imports it"; else t_fail "D call site: 10-bootstrap.sh does not check the key before importing it"; fi
site "Dockerfile.builder refuses an empty fingerprint argument" "$DOCKERFILE" '^ +test -n "\$CACHYOS_KEY_FPR"; \\$'
site "Dockerfile.builder compares the key file's fingerprint with the pin" "$DOCKERFILE" '^ +test "\$got" = "\$CACHYOS_KEY_FPR"; \\$'
if awk '/test -n "\$CACHYOS_KEY_FPR"/ { n = NR } /test "\$got" = "\$CACHYOS_KEY_FPR"/ { c = NR } /pacman-key --add/ { a = NR } END { exit !(n && c && a && n < c && c < a) }' "$DOCKERFILE"; then t_pass "D call site: Dockerfile.builder compares the fingerprint BEFORE pacman-key --add"; else t_fail "D call site: Dockerfile.builder order of the key check and pacman-key --add"; fi
if grep -nE '^(ci_check_[a-z0-9_]+|ci_asc_primary_fprs|ci_env_value|ci_git)\(\)' "$BUILD_SH" "$BOOT_SH" "$SCRIPTS/build-iso.sh" >/dev/null; then t_fail "D an in-container script or build-iso.sh redefines one of the checked functions of lib/common.sh"; else t_pass "D no script redefines (shadows) a checking function of lib/common.sh"; fi

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
