#!/usr/bin/env bash
#=============================================================================
# Test: the installer launcher (calamares-online.sh) and its guard library, on a FAKE Calamares tree. No root, no Docker, no
# network, no pacman: every external command is a stub on PATH that logs its arguments.
#
# The fake installer tree is built from iso/tests/installer-fixtures/upstream-3.4.2-13.facts, which
# installer/packages/capture-upstream-facts.sh recorded from the real cachyos-calamares-next 3.4.2-13 (empty files with the
# right names, the strings the guards look for, the real top-level keys and the real install sequence). The overlay under test
# is the real one, assembled by installer/stage-installer.sh.
#
#   guards      critical failures (a missing script, a missing code marker, a new step in the installer's sequence, a settings.conf
#               that does not resolve, a missing payload file) fail closed; cosmetic ones (a code marker of the Plymouth job, a key the
#               overlay's config lacks) only warn; CI_OS_CALAMARES_ROOT redirects every lookup
#   apply       the overlay lands in the tree, byte for byte, in one step; a failure leaves the tree as it was; cosmetic patches edit
#               the files the overlay does not replace and warn when their marker is gone
#   launcher    the whole script against stubs: current installer, a compatible update (installed), an incompatible update (the
#               installer on the ISO is KEPT), an incompatible bundled installer (stops, nothing changed), a package that vanished
#               (stops before Calamares), an unreachable repository, a non-live system, a dangerous keyring path, the dialogs
#
#   backends/cachyos/iso/tests/installer-launcher.sh
#
# Needs bash 3.2+, awk, sed, cmp, find; the preflight cases need python3 with PyYAML (skipped without). Exit: non-zero when any
# check fails, 2 when it cannot run.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS="$(cd "$HERE/../.." && pwd)"
INSTALLER="$CACHYOS/installer"
LAUNCHER="$CACHYOS/iso/overlay/files/airootfs/usr/local/bin/calamares-online.sh"
FACTS="$HERE/installer-fixtures/upstream-3.4.2-13.facts"

PASS=0; FAIL=0; SKIP=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }

for f in "$LAUNCHER" "$FACTS" "$INSTALLER/lib/ci-guards.sh"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
HAVE_YAML=0
PYDIR="$(dirname "$(command -v python3)")"
# `-I` like the launcher's own call (calamares-online.sh): a PyYAML that only the user site holds is NOT visible to it, and a probe
# without -I would say "yes" and then fail every preflight case on such a dev machine instead of skipping it.
if python3 -I -c 'import yaml' >/dev/null 2>&1; then HAVE_YAML=1; fi

W="$(mktemp -d "${TMPDIR:-/tmp}/installer-launcher.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# --- the overlay under test ------------------------------------------------------------------------------------------------------
CI_OS_STAGING_DIR="$W/stage" CI_OS_VERSION=2026.10.15 bash "$INSTALLER/stage-installer.sh" > "$W/stage.out" 2>&1 \
  || { cat "$W/stage.out" >&2; echo "stage-installer.sh failed" >&2; exit 2; }
OV="$W/stage/airootfs/usr/share/ci-os/calamares"

# --- a fake installer tree from the facts ------------------------------------------------------------------------------------------------
# build_fake DIR: DIR gets the installer's files at their installed paths.
build_fake() {
  local d="$1" line kind rest name f path str mode="" seq="" listkeys key
  # `list` facts hold the items of a block list (pacstrap basePackages ...): that key is written as a real list, not as `key: x`.
  listkeys=" $(sed -n 's/^list \([^ ]*\) \([^ ]*\) .*/\1.\2/p' "$FACTS" | tr '\n' ' ') "
  mkdir -p "$d/etc/calamares/modules" "$d/etc/calamares/scripts" "$d/usr/lib/calamares/modules" "$d/usr/share/calamares"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    kind="${line%% *}"; rest="${line#* }"
    case "$kind" in
      module)  mkdir -p "$d/usr/lib/calamares/modules/$rest"; : > "$d/usr/lib/calamares/modules/$rest/module.desc" ;;
      modfile) name="${rest%% *}"; f="${rest#* }"; : > "$d/usr/lib/calamares/modules/$name/$f" ;;
      conf)    : > "$d/etc/calamares/modules/$rest" ;;
      script)  : > "$d/etc/calamares/scripts/$rest" ;;
      file)    mkdir -p "$d$(dirname "$rest")"; : > "$d$rest" ;;
      marker)  path="${rest%% *}"; str="${rest#* }"; mkdir -p "$d$(dirname "$path")"; printf '%s\n' "$str" >> "$d$path" ;;
      keys)    name="${rest%% *}"; rest="${rest#"$name"}"
               for f in $rest; do
                 case "$listkeys" in *" $name.$f "*) continue ;; esac
                 printf '%s: x\n' "$f" >> "$d/etc/calamares/modules/$name.conf"
               done ;;
      list)    name="${rest%% *}"; rest="${rest#"$name" }"; key="${rest%% *}"; rest="${rest#"$key"}"
               printf '%s:\n' "$key" >> "$d/etc/calamares/modules/$name.conf"
               for f in $rest; do printf '  - %s\n' "$f" >> "$d/etc/calamares/modules/$name.conf"; done ;;
      seq)     seq="$seq$rest"$'\n' ;;
    esac
  done < "$FACTS"
  {
    echo '---'; echo 'modules-search: [ local ]'; echo 'instances:'; echo 'sequence:'
    mode=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if [ "${line%%:*}" != "$mode" ]; then mode="${line%%:*}"; echo "- $mode:"; fi
      echo "  - ${line#*:}"
    done <<EOF
$seq
EOF
    echo 'branding: cachyos'
  } > "$d/usr/share/calamares/settings_online.conf"
  # Files the cosmetic patches edit.
  printf '%s\n' 'i18n:' '     name: "Preparing your system for online installation of CachyOS"' '     name[de]: "Online-Installation von CachyOS"' 'script:' '    - command: "cp /etc/pacman-more.conf ${ROOT}/etc/pacman.conf"' > "$d/etc/calamares/modules/shellprocess-before-online.conf"
  printf '%s\n' 'sed -i '"'"'s/TARGET_OS_NAME=".*"/TARGET_OS_NAME="CachyOS"/'"'"' "$limine_snapper_config"' > "$d/etc/calamares/scripts/bootloader-post-setup"
  printf '%s\n' '--description "Fresh CachyOS Installation"' > "$d/etc/calamares/scripts/btrfs-installation-snapshot"
  # An upstream settings.conf and a module config the overlay replaces, with CachyOS content, to see them replaced.
  printf '%s\n' 'branding: cachyos' > "$d/etc/calamares/settings.conf"
  printf '%s\n' 'efiBootloaderId: "cachyos"' 'efiBootLoader: "limine"' >> "$d/etc/calamares/modules/bootloader.conf"
}

# Run guards on ROOT and OVERLAY; prints the report; sets GR_CRIT / GR_WARN / GR_OUT / GR_RC.
run_guards() {  # ROOT [OVERLAY]
  GR_OUT="$(CI_OS_CALAMARES_ROOT="$1" CI_OS_OVERLAY_DIR="${2:-$OV}" CI_OS_LIVE_ROOT="${CI_OS_LIVE_ROOT:-$W/live}" bash -c '
    . "$1/lib/ci-guards.sh"; ci_g_reset; ci_g_run_table "$CI_OS_OVERLAY_DIR/guards.list"; ci_g_report; rc=$?
    printf "COUNTS %s %s\n" "$CI_G_CRIT_COUNT" "$CI_G_WARN_COUNT"; exit $rc' _ "$INSTALLER" 2>&1)" && GR_RC=0 || GR_RC=$?
  GR_CRIT="$(printf '%s\n' "$GR_OUT" | sed -n 's/^COUNTS \([0-9]*\) .*/\1/p')"
  GR_WARN="$(printf '%s\n' "$GR_OUT" | sed -n 's/^COUNTS [0-9]* \([0-9]*\)$/\1/p')"
}

# The live-system side of the cosmetic guards (carry-over and the themes of the brand overlay).
mkdir -p "$W/live/usr/share/ci-os/installed" "$W/live/usr/share/grub/themes/companion-os" "$W/live/usr/share/plymouth/themes/companion-os"
: > "$W/live/usr/share/ci-os/installed/carry-over"; : > "$W/live/usr/share/ci-os/installed/carry-over.list"
: > "$W/live/usr/share/grub/themes/companion-os/theme.txt"; : > "$W/live/usr/share/plymouth/themes/companion-os/companion-os.plymouth"

echo "== guards"
build_fake "$W/up"

run_guards "$W/up"
DESC="the overlay passes every critical guard on the pinned installer's shape (0 critical, 0 warnings)"
if [ "$GR_RC" = 0 ] && [ "$GR_CRIT" = 0 ] && [ "$GR_WARN" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
[ "$GR_RC" = 0 ] || printf '%s\n' "$GR_OUT" | sed 's/^/      /'

cp -R "$W/up" "$W/g1"; rm "$W/g1/etc/calamares/scripts/pacstrap_calamares"
run_guards "$W/g1"
DESC="a missing stock script (pacstrap_calamares) is critical and the report names it"
if [ "$GR_RC" = 1 ] && [ "$GR_CRIT" -ge 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'pacstrap_calamares'; then t_pass "$DESC"; else t_fail "$DESC"; fi

cp -R "$W/up" "$W/g2"; : > "$W/g2/usr/lib/calamares/modules/packages/main.py"
run_guards "$W/g2"
DESC="the packages job losing packageOperations / operations is critical (the package list would be ignored)"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q "packageOperations"; then t_pass "$DESC"; else t_fail "$DESC"; fi

cp -R "$W/up" "$W/g3"; : > "$W/g3/usr/lib/calamares/modules/plymouthcfg/main.py"
run_guards "$W/g3"
DESC="a cosmetic marker gone (plymouthcfg's plymouth-set-default-theme) is a warning, not a stop"
if [ "$GR_RC" = 0 ] && [ "$GR_CRIT" = 0 ] && [ "$GR_WARN" -ge 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'plymouth-set-default-theme'; then t_pass "$DESC"; else t_fail "$DESC"; fi

cp -R "$W/up" "$W/g4"
awk '/^  - umount$/ { print "  - shellprocess@brand_new_step" } { print }' "$W/up/usr/share/calamares/settings_online.conf" > "$W/g4/usr/share/calamares/settings_online.conf"
run_guards "$W/g4"
DESC="a step the installer added to its sequence (shellprocess@brand_new_step) is critical, so it is reviewed rather than dropped"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'shellprocess@brand_new_step'; then t_pass "$DESC"; else t_fail "$DESC"; fi

cp -R "$W/up" "$W/g5"; printf 'newFeatureKey: 1\n' >> "$W/g5/etc/calamares/modules/grubcfg.conf"
run_guards "$W/g5"
DESC="a top-level key the installer's grubcfg.conf gained and the overlay's lacks is a warning that names the key"
if [ "$GR_RC" = 0 ] && [ "$GR_WARN" -ge 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'newFeatureKey'; then t_pass "$DESC"; else t_fail "$DESC"; fi

cp -R "$W/up" "$W/g6"; rm -rf "$W/g6/usr/lib/calamares/modules/netinstall"
run_guards "$W/g6"
DESC="a module the overlay's settings.conf uses but the installer lacks (netinstall) is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q "module 'netinstall'"; then t_pass "$DESC"; else t_fail "$DESC"; fi

cp -R "$OV" "$W/ov2"; rm "$W/ov2/target/bootstrap/backends/cachyos/provision/stage-headless.sh"
run_guards "$W/up" "$W/ov2"
DESC="a payload-staging file missing from the overlay (stage-headless.sh) is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'stage-headless.sh'; then t_pass "$DESC"; else t_fail "$DESC"; fi

cp -R "$OV" "$W/ov3"; sed -i.bak 's/^  - bootloader$/  - bogus_module/' "$W/ov3/settings.conf"; rm -f "$W/ov3/settings.conf.bak"
run_guards "$W/up" "$W/ov3"
DESC="a settings.conf entry that names no installed module (bogus_module) is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q "module 'bogus_module'"; then t_pass "$DESC"; else t_fail "$DESC"; fi

cp -R "$OV" "$W/ov4"; rm "$W/ov4/modules/shellprocess_ci_os_stage.conf"
run_guards "$W/up" "$W/ov4"
DESC="an instance without a config file (ci_os_stage) is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'ci_os_stage'; then t_pass "$DESC"; else t_fail "$DESC"; fi

cp -R "$OV" "$W/ov5"; sed -i.bak 's/^componentName:.*/componentName:  other/' "$W/ov5/branding/companion/branding.desc"; rm -f "$W/ov5/branding/companion/branding.desc.bak"
run_guards "$W/up" "$W/ov5"
DESC="a branding componentName that differs from its directory is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'componentName'; then t_pass "$DESC"; else t_fail "$DESC"; fi

# --- the install sequence the settings-drift guard reads (decision D6: a new upstream step is reviewed, not silently dropped) ---------
# A guard that cannot parse the installer's file must FAIL, not report "no difference". Each case below passed with 0 critical before the
# parse check existed (an empty file, flow-style lists and a renamed key all parse to zero steps).
SO_REL=usr/share/calamares/settings_online.conf
cp -R "$W/up" "$W/s1"; : > "$W/s1/$SO_REL"
run_guards "$W/s1"
DESC="an installer sequence file that is EMPTY is critical (it parses to no steps), not 'no difference'"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'could not read an install sequence'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

cp -R "$W/up" "$W/s2"
printf '%s\n' '---' 'modules-search: [ local ]' 'sequence:' '- show: [ welcome@online, locale, keyboard, partition ]' \
  '- exec: [ partition, zfs, mount, pacstrap, packages@online, bootloader, shellprocess@brand_new_step ]' 'branding: cachyos' > "$W/s2/$SO_REL"
run_guards "$W/s2"
DESC="FLOW-STYLE step lists in the installer's sequence (which the parser cannot read) are critical, even with a new step inside them"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'could not read an install sequence'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

cp -R "$W/up" "$W/s3"
awk '/^  - umount$/ { print "  - shellprocess@brand_new_step" } { print }' "$W/up/$SO_REL" | sed 's/^sequence:$/steps:/' > "$W/s3/$SO_REL"
run_guards "$W/s3"
DESC="a RENAMED 'sequence' key (steps:) with a new step in it is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'could not read an install sequence'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

cp -R "$W/up" "$W/s4"; sed 's/^sequence:$/sequence:   # the steps/' "$W/up/$SO_REL" > "$W/s4/$SO_REL"
run_guards "$W/s4"
DESC="a trailing comment on the 'sequence:' header is read like the plain header: the unchanged sequence passes with 0 critical"
if [ "$GR_RC" = 0 ] && [ "$GR_CRIT" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/s5"
awk '/^  - umount$/ { print "  - shellprocess@brand_new_step" } { print }' "$W/up/$SO_REL" | sed 's/^sequence:$/sequence:   # the steps/' > "$W/s5/$SO_REL"
run_guards "$W/s5"
DESC="... and with a new step in it the report names THAT step (not just 'could not read')"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'shellprocess@brand_new_step' && ! printf '%s\n' "$GR_OUT" | grep -q 'could not read an install sequence'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

cp -R "$W/up" "$W/s6"; grep -v '^  - pacstrap$' "$W/up/$SO_REL" > "$W/s6/$SO_REL"
run_guards "$W/s6"
DESC="an installer sequence that LACKS an anchor step (pacstrap) and gained nothing is critical and names the anchor"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'lacks exec:pacstrap'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

# --- keys: critical only where the installer's Python reads the frozen copy key by key -----------------------------------------------
cp -R "$W/up" "$W/k1"; printf 'newMandatoryKey: 1\n' >> "$W/k1/etc/calamares/modules/pacstrap.conf"
run_guards "$W/k1"
DESC="a new top-level key in the installer's pacstrap.conf is CRITICAL (the overlay's frozen copy would lack it) and names the key"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'newMandatoryKey'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/k2"; printf 'newMandatoryKey: 1\n' >> "$W/k2/etc/calamares/modules/bootloader.conf"
run_guards "$W/k2"
DESC="a new top-level key in the installer's bootloader.conf is CRITICAL too"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'newMandatoryKey'; then t_pass "$DESC"; else t_fail "$DESC"; fi
cp -R "$W/up" "$W/k3"; printf 'newOptionalKey: 1\n' >> "$W/k3/etc/calamares/modules/users.conf"
run_guards "$W/k3"
DESC="... while a new key in users.conf (optional keys with defaults) stays a warning"
if [ "$GR_RC" = 0 ] && [ "$GR_CRIT" = 0 ] && [ "$GR_WARN" -ge 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'newOptionalKey'; then t_pass "$DESC"; else t_fail "$DESC"; fi

# --- list-drift: values inside the lists the overlay freezes -----------------------------------------------------------------------------
cp -R "$W/up" "$W/l1"
# the new item must sit inside basePackages: rebuild the file with it at the head of that list
awk '{ print } /^basePackages:$/ { print "  - fwupd" }' "$W/up/etc/calamares/modules/pacstrap.conf" > "$W/l1/etc/calamares/modules/pacstrap.conf"
run_guards "$W/l1"
DESC="a package the installer ADDS to pacstrap basePackages (fwupd) is critical and named: it is reviewed, not silently dropped"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q "has 'fwupd'"; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/l2"
awk '{ print } /^postInstallFiles:$/ { print "  - /etc/calamares/scripts/new-hook" }' "$W/up/etc/calamares/modules/pacstrap.conf" > "$W/l2/etc/calamares/modules/pacstrap.conf"
run_guards "$W/l2"
DESC="a file the installer adds to postInstallFiles is critical and named"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'new-hook'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/l3"
awk '/^basePackages:$/ { print "basePackages: [ base, base-devel, fwupd ]"; skip = 1; next } skip && /^[A-Za-z_]/ { skip = 0 } !skip { print }' "$W/up/etc/calamares/modules/pacstrap.conf" > "$W/l3/etc/calamares/modules/pacstrap.conf"
run_guards "$W/l3"
DESC="a basePackages list the parser cannot read (flow style) is critical, not 'no difference'"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q "could not read the list 'basePackages'"; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/l4"
awk '!/^  - cachyos-plymouth-(bootanimation|theme)$/ { print }' "$W/up/etc/calamares/modules/pacstrap.conf" > "$W/l4/etc/calamares/modules/pacstrap.conf"
run_guards "$W/l4"
DESC="the intentional drops (cachyos-plymouth-*, enable-ufw) are the ONLY allowed difference: the installer without them still passes"
if [ "$GR_RC" = 0 ] && [ "$GR_CRIT" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

# --- code-names: the packages pacstrap/main.py adds in code are the ones the overlay lists (so the preflight asks about them) ----------
cp -R "$W/up" "$W/c1"; printf '%s\n' '        base_packages += ["fwupd-code"]' >> "$W/c1/usr/lib/calamares/modules/pacstrap/main.py"
run_guards "$W/c1"
DESC="a package the installer's code starts adding to the base system (fwupd-code) is critical: the preflight would not check it"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q "adds 'fwupd-code'"; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/c2"; sed 's/"grub-hook", //' "$W/up/usr/lib/calamares/modules/pacstrap/main.py" > "$W/c2/usr/lib/calamares/modules/pacstrap/main.py"
run_guards "$W/c2"
DESC="a package the overlay lists that the code no longer adds (grub-hook) is critical too (the list would rot)"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q "lists 'grub-hook'"; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/c3"; sed 's/base_packages/pkgs/g' "$W/up/usr/lib/calamares/modules/pacstrap/main.py" > "$W/c3/usr/lib/calamares/modules/pacstrap/main.py"
run_guards "$W/c3"
DESC="code restructured so that no base_packages addition is found (renamed variable) is critical: nothing to compare is not 'no difference'"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'found no base_packages additions'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/c4"; awk '{ print } END { print "        base_packages += [\"split-a\","; print "                          \"split-b\"]" }' "$W/up/usr/lib/calamares/modules/pacstrap/main.py" > "$W/c4/usr/lib/calamares/modules/pacstrap/main.py"
run_guards "$W/c4"
DESC="a statement that spans two lines is read to its closing bracket (both names are reported)"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q "adds 'split-a'" && printf '%s\n' "$GR_OUT" | grep -q "adds 'split-b'"; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

DESC="CI_OS_CALAMARES_ROOT redirects lookups (and strips a trailing slash)"
if [ "$(CI_OS_CALAMARES_ROOT="$W/up/" bash -c '. "$1"; ci_g_path /etc/calamares' _ "$INSTALLER/lib/ci-guards.sh")" = "$W/up/etc/calamares" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="with no root set the lookups are the live system's absolute paths"
if [ "$(env -u CI_OS_CALAMARES_ROOT bash -c '. "$1"; ci_g_path /etc/calamares' _ "$INSTALLER/lib/ci-guards.sh")" = "/etc/calamares" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi

if [ -n "${CI_OS_REAL_CALAMARES_ROOT:-}" ] && [ -d "$CI_OS_REAL_CALAMARES_ROOT/usr/lib/calamares/modules" ]; then
  run_guards "$CI_OS_REAL_CALAMARES_ROOT"
  DESC="the overlay passes the guards on a REAL unpacked installer ($CI_OS_REAL_CALAMARES_ROOT)"
  if [ "$GR_RC" = 0 ] && [ "$GR_CRIT" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
else
  t_skip "guards on a real unpacked installer (set CI_OS_REAL_CALAMARES_ROOT to an unpacked cachyos-calamares-next or ISO root)"
fi

echo "== apply"
cp -R "$W/up" "$W/a1"
CI_OS_CALAMARES_ROOT="$W/a1" CI_OS_OVERLAY_DIR="$OV" CI_OS_SUDO='' bash -c '. "$1/lib/ci-guards.sh"; ci_g_apply_overlay' _ "$INSTALLER" && AP_RC=0 || AP_RC=$?
DESC="the overlay copies in (settings.conf, every module file, the branding component), byte for byte"
ok=1; [ "$AP_RC" = 0 ] || ok=0
cmp -s "$OV/settings.conf" "$W/a1/etc/calamares/settings.conf" || ok=0
for f in "$OV"/modules/*; do cmp -s "$f" "$W/a1/etc/calamares/modules/$(basename "$f")" || ok=0; done
for f in "$OV"/branding/companion/*; do cmp -s "$f" "$W/a1/usr/share/calamares/branding/companion/$(basename "$f")" || ok=0; done
if [ "$ok" = 1 ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="the installer's own files the overlay does not replace are untouched (pacstrap_calamares, shellprocess-before-online.conf)"
if [ -f "$W/a1/etc/calamares/scripts/pacstrap_calamares" ] && [ -f "$W/a1/etc/calamares/modules/shellprocess-before-online.conf" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="applied files are world-readable (644) even under a 077 umask"
(umask 077; CI_OS_CALAMARES_ROOT="$W/a1b" CI_OS_OVERLAY_DIR="$OV" CI_OS_SUDO='' bash -c '. "$1/lib/ci-guards.sh"; ci_g_apply_overlay' _ "$INSTALLER")
if [ -z "$(find "$W/a1b" -type f ! -perm -644 2>/dev/null)" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi

mkdir -p "$W/ov6" && cp -R "$OV"/. "$W/ov6/" && rm -rf "$W/ov6/modules"
cp -R "$W/up" "$W/a2"
CI_OS_CALAMARES_ROOT="$W/a2" CI_OS_OVERLAY_DIR="$W/ov6" CI_OS_SUDO='' bash -c '. "$1/lib/ci-guards.sh"; ci_g_apply_overlay' _ "$INSTALLER" >/dev/null 2>&1 && AP_RC=0 || AP_RC=$?
DESC="a failure while building the file set leaves the installer exactly as it was (settings.conf still upstream's)"
if [ "$AP_RC" != 0 ] && [ "$(cat "$W/a2/etc/calamares/settings.conf")" = "branding: cachyos" ] && [ ! -d "$W/a2/usr/share/calamares/branding/companion" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi

CI_OS_CALAMARES_ROOT="$W/a1" CI_OS_SUDO='' bash -c '. "$1/lib/ci-guards.sh"; ci_g_reset; ci_g_apply_cosmetic_patches "$2/patches.list"; printf "FIRST_WARN=%s\n" "$CI_G_WARN_COUNT"; ci_g_reset; ci_g_apply_cosmetic_patches "$2/patches.list"; printf "SECOND_WARN=%s\n" "$CI_G_WARN_COUNT"' _ "$INSTALLER" "$OV" > "$W/patch.out" 2>&1 || true
DESC="cosmetic patches rename the product in the progress text, the Limine post-setup script and the Btrfs snapshot description"
if grep -q 'installation of Companion OS' "$W/a1/etc/calamares/modules/shellprocess-before-online.conf" \
  && grep -q 'Online-Installation von Companion OS' "$W/a1/etc/calamares/modules/shellprocess-before-online.conf" \
  && grep -q 'TARGET_OS_NAME="Companion OS"' "$W/a1/etc/calamares/scripts/bootloader-post-setup" \
  && grep -q 'Fresh Companion OS Installation' "$W/a1/etc/calamares/scripts/btrfs-installation-snapshot" \
  && grep -q '^FIRST_WARN=0$' "$W/patch.out"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$W/patch.out"; fi
DESC="applying them a second time is a warning each (the markers are gone), never an error"
if grep -q '^SECOND_WARN=3$' "$W/patch.out"; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="the patches left the commands of shellprocess-before-online.conf alone"
if grep -q 'cp /etc/pacman-more.conf' "$W/a1/etc/calamares/modules/shellprocess-before-online.conf"; then t_pass "$DESC"; else t_fail "$DESC"; fi

echo "== package lists (lib/ci-pkglist.py)"
if [ "$HAVE_YAML" = 1 ]; then
  python3 -I "$OV/lib/ci-pkglist.py" "$OV" always > "$W/pk-always.txt" 2>"$W/pk.err" && pk_rc=0 || pk_rc=$?
  python3 -I "$OV/lib/ci-pkglist.py" "$OV" optional > "$W/pk-optional.txt" 2>>"$W/pk.err" || pk_rc=1
  # the overlay's own basePackages, read independently of the reader under test
  sed -n '/^basePackages:/,/^[A-Za-z]/ s/^  - \(.*\)$/\1/p' "$OV/modules/pacstrap.conf" | LC_ALL=C sort -u > "$W/pk-base.txt"
  DESC="ci-pkglist.py: the 'always' set holds every pacstrap.conf basePackages name (the base system is preflighted, not only the package job)"
  if [ "$pk_rc" = 0 ] && [ -s "$W/pk-base.txt" ] && [ -z "$(LC_ALL=C comm -23 "$W/pk-base.txt" "$W/pk-always.txt")" ]; then t_pass "$DESC"; else t_fail "$DESC"; LC_ALL=C comm -23 "$W/pk-base.txt" "$W/pk-always.txt" | sed 's/^/      missing: /'; fi
  DESC="ci-pkglist.py: 'always' holds the packages pacstrap adds in code that every install needs (grub, grub-hook, both microcodes), 'optional' the filesystem-specific ones"
  if grep -qx grub-hook "$W/pk-always.txt" && grep -qx amd-ucode "$W/pk-always.txt" && grep -qx intel-ucode "$W/pk-always.txt" && grep -qx zfs-utils "$W/pk-optional.txt" && ! grep -qx zfs-utils "$W/pk-always.txt"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  DESC="ci-pkglist.py: the 'unused' names (other bootloaders) are in neither set"
  if ! cat "$W/pk-always.txt" "$W/pk-optional.txt" | grep -Eqx 'limine|refind|systemd-boot-manager|limine-entry-tool'; then t_pass "$DESC"; else t_fail "$DESC"; fi
  mkdir -p "$W/ov-badlist" && cp -R "$OV"/. "$W/ov-badlist/" && printf 'sometimes | grub\n' >> "$W/ov-badlist/pacstrap-code-added.list"
  python3 -I "$OV/lib/ci-pkglist.py" "$W/ov-badlist" always > /dev/null 2>"$W/pk-bad.err" && pk_rc=0 || pk_rc=$?
  DESC="ci-pkglist.py: a malformed pacstrap-code-added.list line (unknown set) is an error naming the line, never silently skipped"
  if [ "$pk_rc" = 1 ] && grep -q 'pacstrap-code-added.list' "$W/pk-bad.err" && grep -q 'sometimes' "$W/pk-bad.err"; then t_pass "$DESC"; else t_fail "$DESC"; cat "$W/pk-bad.err" | sed 's/^/      /'; fi
else
  t_skip "ci-pkglist.py cases (need python3 with PyYAML)"
fi

echo "== launcher (stubs on PATH)"
mkdir -p "$W/bin"
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$W/bin/$1"; chmod +x "$W/bin/$1"; }
stub pacman '
echo "pacman $*" >> "$FAKE_LOG"
case "$1 $2" in
  "-Q cachyos-calamares-next") echo "cachyos-calamares-next $FAKE_INSTALLED_VER"; exit 0 ;;
esac
case "$1" in
  -Si)
    shift
    if [ "$1" = cachyos-calamares-next ]; then echo "Version         : $FAKE_REPO_VER"; exit 0; fi
    rc=0
    for n in "$@"; do
      case " ${FAKE_MISSING:-} " in *" $n "*) echo "error: package '"'"'$n'"'"' was not found" >&2; rc=1 ;; esac
    done
    exit $rc ;;
  -Sy) exit "${FAKE_SY_RC:-0}" ;;
  -Sw)
    [ "${FAKE_SW_RC:-0}" = 0 ] || exit "$FAKE_SW_RC"
    mkdir -p "$CI_OS_PKG_CACHE"; : > "$CI_OS_PKG_CACHE/cachyos-calamares-next-$FAKE_REPO_VER-x86_64.pkg.tar.zst"; exit 0 ;;
  -S)
    # a reinstall of the installer: the candidate tree replaces the files of the installer tree
    [ -z "${FAKE_CANDIDATE:-}" ] || cp -R "$FAKE_CANDIDATE"/. "$CI_OS_CALAMARES_ROOT"/
    echo installed > "$FAKE_STATE/installed-candidate"; exit 0 ;;
esac
exit 0'
stub pacman-key 'echo "pacman-key $*" >> "$FAKE_LOG"; if [ "$1" = --init ]; then if [ -e "$CI_OS_PACMAN_GNUPG_DIR" ]; then echo "keyring dir still existed at --init" >> "$FAKE_LOG"; fi; mkdir -p "$CI_OS_PACMAN_GNUPG_DIR"; fi; exit 0'
stub timedatectl 'echo "timedatectl $*" >> "$FAKE_LOG"; exit 0'
stub bsdtar 'echo "bsdtar $*" >> "$FAKE_LOG"; [ "${FAKE_BSDTAR_RC:-0}" = 0 ] || exit "$FAKE_BSDTAR_RC"; while [ $# -gt 0 ]; do [ "$1" = -C ] && dest="$2"; shift; done; cp -R "$FAKE_CANDIDATE"/. "$dest"/; exit 0'
stub pkexec-wrapper 'echo "pkexec-wrapper $*" >> "$FAKE_LOG"; exit "${FAKE_CAL_RC:-0}"'
stub kdialog 'echo "kdialog $*" >> "$FAKE_UI"; exit 0'
stub notify-send 'echo "notify-send $*" >> "$FAKE_UI"; exit 0'
stub curl 'echo "curl $*" >> "$FAKE_LOG"; exit 0'

# run_launcher NAME [VAR=value ...]: a fresh copy of the fake installer in $W/r-NAME, the stubs, the launcher; sets L_RC.
run_launcher() {
  local name="$1"; shift
  local R="$W/r-$name"
  mkdir -p "$R/state" "$R/cache"
  cp -R "$W/up" "$R/root"
  : > "$R/log"; : > "$R/ui"
  env -i PATH="$W/bin:$PYDIR:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$R" TMPDIR="$R" \
    CI_OS_OVERLAY_DIR="$OV" CI_OS_CALAMARES_ROOT="$R/root" CI_OS_INSTALL_LOG="$R/install.log" CI_OS_SUDO='' \
    CI_OS_PACMAN_GNUPG_DIR="$R/gnupg" CI_OS_PKG_CACHE="$R/cache" CI_OS_ALLOW_NON_LIVE=1 CI_OS_NONINTERACTIVE=1 \
    CI_OS_LOCK_FILE="$R/lock" CI_OS_LIVE_ROOT="$W/live" FAKE_LOG="$R/log" FAKE_UI="$R/ui" FAKE_STATE="$R/state" \
    FAKE_INSTALLED_VER=3.4.2-13 FAKE_REPO_VER=3.4.2-13 \
    "$@" bash "$LAUNCHER" > "$R/out" 2>&1 && L_RC=0 || L_RC=$?
  L_DIR="$R"
}
# The keyring directory exists before the run (the stub checks that the launcher removed it first).
seed_gnupg() { mkdir -p "$W/r-$1/gnupg"; echo old > "$W/r-$1/gnupg/old-key"; }

# 1. happy path, installer current
seed_gnupg happy
if [ "$HAVE_YAML" = 1 ]; then
  run_launcher happy
  DESC="launcher: a current installer is not downloaded; the overlay is applied; Calamares starts through pkexec-wrapper (exit 0)"
  if [ "$L_RC" = 0 ] && ! grep -q -- '-Sw' "$L_DIR/log" && grep -q '^pkexec-wrapper calamares -D6' "$L_DIR/log" \
    && cmp -s "$OV/settings.conf" "$L_DIR/root/etc/calamares/settings.conf"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/out"; fi
  DESC="launcher: upstream's key re-init order is kept (rm gnupg, pacman -Sy both keyrings, --init, --populate archlinux cachyos, NTP)"
  seq="$(grep -E '^(pacman -Sy|pacman-key|timedatectl)' "$L_DIR/log" | tr '\n' ';')"
  if [ "$seq" = "pacman -Sy --noconfirm archlinux-keyring cachyos-keyring;pacman-key --init;pacman-key --populate archlinux cachyos;timedatectl set-ntp true;" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
  DESC="launcher: the old keyring directory was removed before the new one was made"
  if [ ! -e "$L_DIR/gnupg/old-key" ] && ! grep -q 'still existed' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  DESC="launcher: the log exists, is private (600) and names the preflight result"
  if [ -f "$L_DIR/install.log" ] && [ -n "$(find "$L_DIR/install.log" -perm 600)" ] && grep -q 'package preflight' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  DESC="launcher: no CachyOS web host is contacted (no curl at all; nothing in the log mentions cachyos.org)"
  if ! grep -q '^curl' "$L_DIR/log" && ! grep -qi 'cachyos\.org' "$L_DIR/install.log" "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  DESC="launcher: pacman -Si is asked for the required packages (docker, hostapd, plasma-desktop ...) but not for opt-in groups' names as required"
  if grep -q '^pacman -Si .*docker' "$L_DIR/log" && grep -q '^pacman -Si .*plasma-desktop' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  DESC="launcher: ... and for the WHOLE base system: pacstrap.conf basePackages (netctl, jfsutils, texinfo ...) and the packages pacstrap adds in code (grub-hook, intel-ucode, amd-ucode)"
  if grep -q '^pacman -Si .* netctl ' "$L_DIR/log" && grep -q '^pacman -Si .* jfsutils ' "$L_DIR/log" && grep -q '^pacman -Si .* texinfo ' "$L_DIR/log" \
    && grep -q '^pacman -Si .* grub-hook ' "$L_DIR/log" && grep -q '^pacman -Si .* intel-ucode ' "$L_DIR/log" && grep -q '^pacman -Si .* amd-ucode ' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  DESC="launcher: the code-added names of other bootloaders (limine, refind) are not asked for: this edition offers GRUB only"
  if ! grep '^pacman -Si' "$L_DIR/log" | grep -Eq ' (limine|refind|systemd-boot-manager)( |$)'; then t_pass "$DESC"; else t_fail "$DESC"; fi
else
  t_skip "launcher cases (need python3 with PyYAML for the package preflight)"
fi

# 2. compatible update
if [ "$HAVE_YAML" = 1 ]; then
  mkdir -p "$W/cand-ok"; cp -R "$W/up"/. "$W/cand-ok"/; printf 'candidateMarker: 1\n' >> "$W/cand-ok/etc/calamares/modules/shellprocess.conf"
  seed_gnupg upd
  run_launcher upd FAKE_REPO_VER=3.4.2-14 FAKE_CANDIDATE="$W/cand-ok"
  DESC="launcher: a newer installer that passes the guards is downloaded (pacman -Sw), unpacked (bsdtar) and installed (pacman -S)"
  if [ "$L_RC" = 0 ] && grep -q '^pacman -Sw --noconfirm cachyos-calamares-next' "$L_DIR/log" && grep -q '^bsdtar -xf' "$L_DIR/log" \
    && [ -f "$L_DIR/state/installed-candidate" ] && grep -q 'candidateMarker' "$L_DIR/root/etc/calamares/modules/shellprocess.conf"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  DESC="launcher: the overlay is applied AFTER the update, on the new installer"
  if cmp -s "$OV/settings.conf" "$L_DIR/root/etc/calamares/settings.conf"; then t_pass "$DESC"; else t_fail "$DESC"; fi

  # 3. incompatible update: the installer on the ISO is kept
  mkdir -p "$W/cand-bad"; cp -R "$W/up"/. "$W/cand-bad"/; rm "$W/cand-bad/etc/calamares/scripts/detect-architecture"
  seed_gnupg bad
  run_launcher bad FAKE_REPO_VER=3.5.0-1 FAKE_CANDIDATE="$W/cand-bad" CI_OS_NONINTERACTIVE=1
  DESC="launcher: a newer installer that fails a critical guard is NOT installed; the installer on the ISO is kept and used"
  if [ "$L_RC" = 0 ] && [ ! -f "$L_DIR/state/installed-candidate" ] && grep -q 'KEEPING the installer on this ISO' "$L_DIR/install.log" \
    && [ -f "$L_DIR/root/etc/calamares/scripts/detect-architecture" ] && grep -q '^pkexec-wrapper calamares' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  DESC="launcher: ... and the person is told why (message names the version) and where the log is"
  if grep -q '3.5.0-1' "$L_DIR/out" && grep -q 'install.log' "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; fi

  # 4. update disabled
  seed_gnupg off
  run_launcher off FAKE_REPO_VER=3.5.0-1 FAKE_CANDIDATE="$W/cand-ok" CI_OS_INSTALLER_UPDATE=0
  DESC="launcher: CI_OS_INSTALLER_UPDATE=0 never downloads anything"
  if [ "$L_RC" = 0 ] && ! grep -q -- '-Sw' "$L_DIR/log" && grep -q 'update disabled' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; fi

  # 4b. download or unpack fails: keep the bundled installer
  seed_gnupg dl
  run_launcher dl FAKE_REPO_VER=3.5.0-1 FAKE_SW_RC=1
  DESC="launcher: a failed download keeps the installer on the ISO and still starts it"
  if [ "$L_RC" = 0 ] && grep -q 'could not download' "$L_DIR/install.log" && grep -q '^pkexec-wrapper' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  seed_gnupg un
  run_launcher un FAKE_REPO_VER=3.5.0-1 FAKE_BSDTAR_RC=1 FAKE_CANDIDATE="$W/cand-ok"
  DESC="launcher: a package that cannot be unpacked keeps the installer on the ISO and still starts it"
  if [ "$L_RC" = 0 ] && grep -q 'cannot unpack' "$L_DIR/install.log" && grep -q '^pkexec-wrapper' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi

  # 5. bundled installer fails a critical guard: stop, change nothing
  seed_gnupg stop
  mkdir -p "$W/r-stop"; cp -R "$W/up" "$W/r-stop/root"; rm "$W/r-stop/root/etc/calamares/scripts/pacstrap_calamares"
  R="$W/r-stop"; mkdir -p "$R/state" "$R/cache"; : > "$R/log"; : > "$R/ui"
  env -i PATH="$W/bin:$PYDIR:/usr/bin:/bin" HOME="$R" TMPDIR="$R" \
    CI_OS_OVERLAY_DIR="$OV" CI_OS_CALAMARES_ROOT="$R/root" CI_OS_INSTALL_LOG="$R/install.log" CI_OS_SUDO= CI_OS_PACMAN_GNUPG_DIR="$R/gnupg" \
    CI_OS_PKG_CACHE="$R/cache" CI_OS_ALLOW_NON_LIVE=1 CI_OS_NONINTERACTIVE=1 CI_OS_LIVE_ROOT="$W/live" FAKE_LOG="$R/log" FAKE_UI="$R/ui" \
    FAKE_STATE="$R/state" FAKE_INSTALLED_VER=3.4.2-13 FAKE_REPO_VER=3.4.2-13 bash "$LAUNCHER" > "$R/out" 2>&1 && L_RC=0 || L_RC=$?
  DESC="launcher: a bundled installer that fails a critical guard stops with status 1, never starts Calamares and changes nothing"
  if [ "$L_RC" = 1 ] && ! grep -q '^pkexec-wrapper' "$R/log" && [ "$(cat "$R/root/etc/calamares/settings.conf")" = "branding: cachyos" ] \
    && grep -q 'NOT started' "$R/out" && grep -q 'nothing was changed on your disks' "$R/out"; then t_pass "$DESC"; else t_fail "$DESC"; fi

  # 6. a required package vanished
  seed_gnupg miss
  run_launcher miss FAKE_MISSING="docker nginx"
  DESC="launcher: a required package missing from the repositories stops before Calamares and names it (docker, nginx)"
  if [ "$L_RC" = 1 ] && ! grep -q '^pkexec-wrapper' "$L_DIR/log" && grep -q 'docker' "$L_DIR/out" && grep -q 'nginx' "$L_DIR/out" && grep -q 'NOT started' "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; fi

  # 6a. a base-system package vanished: pacstrap would die AFTER the disk was written, so the preflight must catch it now
  seed_gnupg base
  run_launcher base FAKE_MISSING="netctl jfsutils"
  DESC="launcher: a pacstrap.conf basePackages name missing from the repositories (netctl, jfsutils) stops before Calamares and names it"
  if [ "$L_RC" = 1 ] && ! grep -q '^pkexec-wrapper' "$L_DIR/log" && grep -q 'netctl' "$L_DIR/out" && grep -q 'jfsutils' "$L_DIR/out" && grep -q 'NOT started' "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/out"; fi
  seed_gnupg code
  run_launcher code FAKE_MISSING="grub-hook"
  DESC="launcher: a package pacstrap adds in code (grub-hook) missing from the repositories stops before Calamares and names it"
  if [ "$L_RC" = 1 ] && ! grep -q '^pkexec-wrapper' "$L_DIR/log" && grep -q 'grub-hook' "$L_DIR/out" && grep -q 'nothing was changed on your disks' "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/out"; fi
  seed_gnupg codeopt
  run_launcher codeopt FAKE_MISSING="grub-btrfs-support"
  DESC="launcher: a package only a Btrfs/ZFS/bcachefs/handheld install needs (grub-btrfs-support) missing is a warning; the installer still starts"
  if [ "$L_RC" = 0 ] && grep -q '^pkexec-wrapper' "$L_DIR/log" && grep -q 'optional package.*grub-btrfs-support' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/out"; fi

  # 6b. an opt-in package vanished: warn only
  seed_gnupg opt
  run_launcher opt FAKE_MISSING="chromium"
  DESC="launcher: an opt-in package missing (chromium) is a warning; the installer still starts"
  if [ "$L_RC" = 0 ] && grep -q '^pkexec-wrapper' "$L_DIR/log" && grep -q 'optional package' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
fi

# 7. repository unreachable
seed_gnupg sy
run_launcher sy FAKE_SY_RC=1
DESC="launcher: an unreachable repository (pacman -Sy fails) stops with a clear message before anything else"
if [ "$L_RC" = 1 ] && ! grep -q '^pkexec-wrapper' "$L_DIR/log" && grep -q 'package repositories could not be reached' "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; fi

# 8. not live
mkdir -p "$W/r-nl"; : > "$W/r-nl/log"
env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W/r-nl" CI_OS_OVERLAY_DIR="$OV" CI_OS_INSTALL_LOG="$W/r-nl/install.log" CI_OS_SUDO= CI_OS_NONINTERACTIVE=1 \
  CI_OS_SKIP_KEYRING=1 FAKE_LOG="$W/r-nl/log" FAKE_UI="$W/r-nl/ui" bash "$LAUNCHER" > "$W/r-nl/out" 2>&1 && L_RC=0 || L_RC=$?
DESC="launcher: outside the live medium it refuses (the installer repartitions disks)"
if [ -d /run/archiso ] || grep -q 'archisobasedir=' /proc/cmdline 2>/dev/null; then
  t_skip "launcher refuses outside the live medium (this machine IS a live archiso system)"
else
  if [ "$L_RC" = 1 ] && grep -q 'only runs from the Companion OS live medium' "$W/r-nl/out" && [ ! -s "$W/r-nl/log" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
fi

# 9. dangerous keyring path
for bad in /etc /etc/pacman.d /; do
  mkdir -p "$W/r-kd"; : > "$W/r-kd/log"
  env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W/r-kd" CI_OS_OVERLAY_DIR="$OV" CI_OS_INSTALL_LOG="$W/r-kd/install.log" CI_OS_SUDO= CI_OS_NONINTERACTIVE=1 \
    CI_OS_ALLOW_NON_LIVE=1 CI_OS_PACMAN_GNUPG_DIR="$bad" FAKE_LOG="$W/r-kd/log" FAKE_UI="$W/r-kd/ui" bash "$LAUNCHER" > "$W/r-kd/out" 2>&1 && L_RC=0 || L_RC=$?
  DESC="launcher: refuses to delete '$bad' as the keyring directory"
  if [ "$L_RC" = 1 ] && grep -q 'refusing to delete' "$W/r-kd/out"; then t_pass "$DESC"; else t_fail "$DESC"; fi
done

# 10. dialogs
mkdir -p "$W/r-ui1"; : > "$W/r-ui1/ui"; : > "$W/r-ui1/log"
cp -R "$W/up" "$W/r-ui1/root"
env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W/r-ui1" TMPDIR="$W/r-ui1" DISPLAY=:0 CI_OS_OVERLAY_DIR="$OV" CI_OS_CALAMARES_ROOT="$W/r-ui1/root" CI_OS_INSTALL_LOG="$W/r-ui1/install.log" \
  CI_OS_SUDO= CI_OS_PACMAN_GNUPG_DIR="$W/r-ui1/gnupg" CI_OS_ALLOW_NON_LIVE=1 FAKE_LOG="$W/r-ui1/log" FAKE_UI="$W/r-ui1/ui" FAKE_STATE="$W/r-ui1" FAKE_SY_RC=1 \
  bash "$LAUNCHER" > "$W/r-ui1/out" 2>&1 || true
DESC="dialog: on a desktop the failure goes to kdialog --error, with the log path in the text"
if grep -q '^kdialog --title Companion OS installer --error ' "$W/r-ui1/ui" && grep -q 'install.log' "$W/r-ui1/ui"; then t_pass "$DESC"; else t_fail "$DESC"; fi
mv "$W/bin/kdialog" "$W/bin/kdialog.off"
: > "$W/r-ui1/ui"; rm -rf "$W/r-ui1/gnupg"
env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W/r-ui1" TMPDIR="$W/r-ui1" DISPLAY=:0 CI_OS_OVERLAY_DIR="$OV" CI_OS_CALAMARES_ROOT="$W/r-ui1/root" CI_OS_INSTALL_LOG="$W/r-ui1/install.log" \
  CI_OS_SUDO= CI_OS_PACMAN_GNUPG_DIR="$W/r-ui1/gnupg" CI_OS_ALLOW_NON_LIVE=1 FAKE_LOG="$W/r-ui1/log" FAKE_UI="$W/r-ui1/ui" FAKE_STATE="$W/r-ui1" FAKE_SY_RC=1 \
  bash "$LAUNCHER" > "$W/r-ui1/out" 2>&1 || true
DESC="dialog: without kdialog and zenity it falls back to notify-send (critical urgency), which the live image has"
if grep -q '^notify-send -a Companion OS installer -u critical ' "$W/r-ui1/ui"; then t_pass "$DESC"; else t_fail "$DESC"; fi
mv "$W/bin/kdialog.off" "$W/bin/kdialog"

# 11. a second launcher while the first one runs (the lock is flock -n; stubbed to "held")
printf '#!/bin/bash\nexit 1\n' > "$W/bin/flock"; chmod +x "$W/bin/flock"
seed_gnupg lock
run_launcher lock
rm -f "$W/bin/flock"
DESC="launcher: a second start while one is preparing exits 0 at once, says so, and runs no pacman and no Calamares"
if [ "$L_RC" = 0 ] && grep -q 'already running' "$L_DIR/install.log" && ! grep -q '^pacman' "$L_DIR/log" && ! grep -q '^pkexec-wrapper' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/out"; fi

# 12. the heads-up notification while it prepares
seed_gnupg hu; mkdir -p "$W/r-hu"
: > "$W/r-hu/ui"; : > "$W/r-hu/log"; cp -R "$W/up" "$W/r-hu/root"; mkdir -p "$W/r-hu/state" "$W/r-hu/cache"
env -i PATH="$W/bin:$PYDIR:/usr/bin:/bin" HOME="$W/r-hu" TMPDIR="$W/r-hu" DISPLAY=:0 CI_OS_OVERLAY_DIR="$OV" CI_OS_CALAMARES_ROOT="$W/r-hu/root" CI_OS_INSTALL_LOG="$W/r-hu/install.log" \
  CI_OS_SUDO='' CI_OS_PACMAN_GNUPG_DIR="$W/r-hu/gnupg" CI_OS_PKG_CACHE="$W/r-hu/cache" CI_OS_LOCK_FILE="$W/r-hu/lock" CI_OS_ALLOW_NON_LIVE=1 CI_OS_LIVE_ROOT="$W/live" FAKE_LOG="$W/r-hu/log" \
  FAKE_UI="$W/r-hu/ui" FAKE_STATE="$W/r-hu" FAKE_INSTALLED_VER=3.4.2-13 FAKE_REPO_VER=3.4.2-13 bash "$LAUNCHER" > "$W/r-hu/out" 2>&1 || true
DESC="dialog: on a desktop a passing notification tells the person the installer is being prepared (not a modal dialog)"
if grep -q '^notify-send -a Companion OS installer Companion OS installer Preparing the installer' "$W/r-hu/ui" && ! grep -q '^kdialog' "$W/r-hu/ui"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$W/r-hu/ui"; fi

echo
printf '== %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
