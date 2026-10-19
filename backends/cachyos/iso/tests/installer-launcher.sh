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
#   keyring     the pacman keyring before the first database sync (incident 2026-10-18, F1): the stubs MODEL the defect (a pacman -Sy
#               without a keyring fails with "Public keyring not found ... key is unknown"), so the cases are: no keyring, an empty
#               directory, a working keyring (kept, never deleted, re-populated before the first sync), a broken one (repaired in place,
#               or its CONTENTS cleared in place), network down, a keyring error at the sync (repaired in place, ONE retry), a 404 for a
#               keyring package (a mirror problem, not a keyring problem), a failing pacman-key --init, an unclassified error. The
#               keyring directory is modelled as a MOUNT POINT: removing or renaming the directory itself fails with EBUSY.
#               MUTANTS of the launcher (the old order, the init after the sync, a rename-aside, an rm -rf of the directory, a glob that
#               misses dot files, no retry, two retries, no stripping of package names, no pre-sync populate) that these cases must catch
#
#   backends/cachyos/iso/tests/installer-launcher.sh
#
# Needs bash 3.2+, awk, sed, cmp, find; the preflight cases need python3 with PyYAML (skipped without), and so does the
# `shell-timeouts` guard, which fails closed without it (as it does in the product: the live image has PyYAML), so the guard cases need it
# too. Exit: non-zero when any check fails, 2 when it cannot run.
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
      spconf)  name="${rest%% *}"; printf '%s\n' "${rest#* }" > "$d/etc/calamares/modules/$name" ;;   # a shellprocess config: JSON is valid YAML
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
  printf '%s\n' 'i18n:' '     name: "Preparing your system for online installation of CachyOS"' '     name[de]: "Online-Installation von CachyOS"' 'timeout: 10' 'script:' '    - command: "cp /etc/pacman-more.conf ${ROOT}/etc/pacman.conf"' '    - command: "/etc/calamares/scripts/detect-architecture ${ROOT}/etc/pacman.conf"' > "$d/etc/calamares/modules/shellprocess-before-online.conf"
  printf '%s\n' 'sed -i '"'"'s/TARGET_OS_NAME=".*"/TARGET_OS_NAME="CachyOS"/'"'"' "$limine_snapper_config"' > "$d/etc/calamares/scripts/bootloader-post-setup"
  # The two scripts of the keyring job, as the installer ships them (their text is what tells the `shell-timeouts` guard that a command talks to mirrors).
  printf '%s\n' '#!/usr/bin/env bash' 'exec 2>&1' 'pacman-key --init' 'for ((i=0; i<5; i++)); do pacman -Sy --noconfirm --needed cachyos-keyring && break; done' 'pacman-key --populate' > "$d/etc/calamares/scripts/create-pacman-keyring"
  printf '%s\n' '#!/usr/bin/env bash' 'sudo pacman -Sy --noconfirm --needed cachyos-rate-mirrors rate-mirrors' 'sudo cachyos-rate-mirrors' > "$d/etc/calamares/scripts/update-mirrorlist"
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

# --- the time limits of the shellprocess steps (ISO #5 died at job 13 of 47: Calamares kills a command after 30 s unless it has a timeout) ---
# The guard `shell-timeouts` (lib/ci-shellprocess.py) judges the EFFECTIVE config of every shellprocess step: the overlay's copy where
# there is one, the installer's own file otherwise. The fake installer tree holds the REAL commands and time limits of the pinned
# installer (the `spconf` facts), so the stock shape of the bug is in it.
DESC="the guard table has the shell-timeouts row, critical, and the overlay ships the reader it calls"
if grep -Eq '^critical[[:space:]]*\|[[:space:]]*shell-timeouts[[:space:]]*\|' "$OV/guards.list" && [ -f "$OV/lib/ci-shellprocess.py" ]; then t_pass "$DESC"; else t_fail "$DESC"; fi

DESC="the fake installer tree carries the installer's real stock shape: the keyring command of shellprocess_initialize_pacman.conf has NO timeout (the ISO #5 defect)"
if python3 -I -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
t = {s["command"]: s.get("timeout") for s in d["script"]}
sys.exit(0 if t.get("bash /etc/calamares/scripts/update-mirrorlist") == 3600 and t.get("bash /etc/calamares/scripts/create-pacman-keyring", "absent") is None and "timeout" not in d else 1)' "$W/up/etc/calamares/modules/shellprocess_initialize_pacman.conf" 2>/dev/null; then t_pass "$DESC"; else t_fail "$DESC"; fi

# The ISO #5 shape: the overlay WITHOUT its copy of the module config, so the installer's own file (keyring without a limit) is what runs.
cp -R "$OV" "$W/ov-st1"; rm "$W/ov-st1/modules/shellprocess_initialize_pacman.conf"
run_guards "$W/up" "$W/ov-st1"
DESC="MUTANT: without the overlay's copy, the installer's own shellprocess_initialize_pacman.conf (keyring command on the 30 s default) is critical, and the report names the command and the tools"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'create-pacman-keyring' && printf '%s\n' "$GR_OUT" | grep -q 'pacman-key' && printf '%s\n' "$GR_OUT" | grep -q 'after 30 s'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

# The overlay's copy has the limit on the keyring command itself.
DESC="the overlay's shellprocess_initialize_pacman.conf gives BOTH mirror-facing commands an own timeout of at least 3600 s and the rest a file-level one"
if python3 -I -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
t = {s["command"]: s.get("timeout") for s in d["script"] if isinstance(s, dict)}
ok = t.get("bash /etc/calamares/scripts/update-mirrorlist", 0) >= 3600 and t.get("bash /etc/calamares/scripts/create-pacman-keyring", 0) >= 3600 and d.get("timeout", 0) >= 600
sys.exit(0 if ok else 1)' "$OV/modules/shellprocess_initialize_pacman.conf" 2>/dev/null; then t_pass "$DESC"; else t_fail "$DESC"; fi

# Mutants of the overlay copy: each must be refused.
shell_mutant() {  # NAME SED-EXPRESSION FILE  -> $W/ov-NAME with the expression applied to modules/FILE
  cp -R "$OV" "$W/ov-$1"; sed -i.bak "$2" "$W/ov-$1/modules/$3"; rm -f "$W/ov-$1/modules/$3.bak"
  cmp -s "$OV/modules/$3" "$W/ov-$1/modules/$3" && { echo "shell_mutant $1: the expression changed nothing" >&2; return 1; }
  return 0
}
shell_mutant st2 '/create-pacman-keyring/{n;s/timeout: 3600/timeout: 0/;}' shellprocess_initialize_pacman.conf
run_guards "$W/up" "$W/ov-st2"
DESC="MUTANT: timeout 0 on the keyring command (no limit to Calamares, not a generous one) is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'create-pacman-keyring' && printf '%s\n' "$GR_OUT" | grep -q 'needs at least 600 s'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
shell_mutant st3 '/create-pacman-keyring/{n;s/timeout: 3600/timeout: 120/;}' shellprocess_initialize_pacman.conf
run_guards "$W/up" "$W/ov-st3"
DESC="MUTANT: 120 s on the keyring command (a limit below the network floor of 600 s) is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'create-pacman-keyring' && printf '%s\n' "$GR_OUT" | grep -q 'may only take 120 s'; then t_pass "$DESC"; else t_fail "$DESC"; fi
shell_mutant st4 '/create-pacman-keyring/{n;/timeout:/d;}' shellprocess_initialize_pacman.conf
# (the keyring command loses its own limit; the file's 600 s then applies to it: a heavy command on the file-level limit is fine)
run_guards "$W/up" "$W/ov-st4"
DESC="a keyring command that inherits the file's 600 s (no timeout of its own) passes: the floor is what matters, not where the number is written"
if [ "$GR_RC" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
shell_mutant st5 '/^timeout: 600$/d' shellprocess_modify_mk_hook.conf
run_guards "$W/up" "$W/ov-st5"
DESC="MUTANT: shellprocess_modify_mk_hook.conf without any timeout (every command on the silent 30 s default) is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'shellprocess_modify_mk_hook.conf' && printf '%s\n' "$GR_OUT" | grep -q 'default of 30 s'; then t_pass "$DESC"; else t_fail "$DESC"; fi
shell_mutant st6 '/^timeout: 600$/d' shellprocess_initialize_pacman.conf
run_guards "$W/up" "$W/ov-st6"
DESC="MUTANT: the copy loses its file-level timeout: the plain mkdir/cp commands fall back to 30 s and are reported together, once"
if [ "$GR_RC" = 1 ] && [ "$(printf '%s\n' "$GR_OUT" | grep -c 'default of 30 s')" = 1 ]; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

# Stock steps the overlay does NOT replace: an installer update must not be taken when one of them gains a heavy command with no limit.
cp -R "$W/up" "$W/st7"
printf '%s\n' '{"dontChroot": false, "script": [{"command": "-rm /etc/systemd/system/etc-pacman.d-gnupg.mount"}, {"command": "pacman -Syu --noconfirm"}], "timeout": 3600}' > "$W/st7/etc/calamares/modules/shellprocess.conf"
run_guards "$W/st7"
DESC="a stock step with a heavy command and a generous file-level limit passes (the fake installer is judged on its effective config, not on its text)"
if [ "$GR_RC" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/st8"
printf '%s\n' '{"dontChroot": false, "script": [{"command": "-rm /etc/systemd/system/etc-pacman.d-gnupg.mount"}, {"command": "pacman -Syu --noconfirm"}]}' > "$W/st8/etc/calamares/modules/shellprocess.conf"
run_guards "$W/st8"
DESC="MUTANT: an update gives the stock final step a pacman command with no limit: critical, so the update is not taken (the ISO's installer is kept)"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'shellprocess.conf: command 2' && printf '%s\n' "$GR_OUT" | grep -q 'pacman'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/st9"
printf '%s\n' '{"dontChroot": false, "script": [{"command": "/etc/calamares/scripts/btrfs-installation-snapshot"}], "timeout": 60}' > "$W/st9/etc/calamares/modules/shellprocess_btrfs_snapshot.conf"
printf '%s\n' 'snapper --no-dbus -c root create' > "$W/st9/etc/calamares/scripts/btrfs-installation-snapshot"
run_guards "$W/st9"
DESC="MUTANT: a stock step whose SCRIPT runs a disk tool (snapper) on a 60 s limit is critical (the script text is read, not only the command line)"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'snapper' && printf '%s\n' "$GR_OUT" | grep -q 'needs at least 300 s'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/st10"
printf '%s\n' '{"dontChroot": false, "script": [{"command": "/etc/calamares/scripts/btrfs-installation-snapshot"}], "timeout": 60}' > "$W/st10/etc/calamares/modules/shellprocess_btrfs_snapshot.conf"
printf '%s\n' '# snapper would be started here' 'if pacman -Qs cachyos-snapper-support > /dev/null; then echo ok; fi' > "$W/st10/etc/calamares/scripts/btrfs-installation-snapshot"
run_guards "$W/st10"
DESC="a comment that names snapper and a read-only pacman -Qs query are not heavy: a 60 s limit passes"
if [ "$GR_RC" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

# R3: the frozen copy must not fall behind the installer's file.
cp -R "$W/up" "$W/st11"
printf '%s\n' '{"dontChroot": true, "script": [{"command": "bash /etc/calamares/scripts/update-mirrorlist", "timeout": 3600}, {"command": "bash /etc/calamares/scripts/create-pacman-keyring"}, {"command": "bash /etc/calamares/scripts/new-upstream-step"}, {"command": "mkdir -p ${ROOT}/etc/pacman.d/"}], "newKey": "x", "i18n": "x"}' > "$W/st11/etc/calamares/modules/shellprocess_initialize_pacman.conf"
run_guards "$W/st11"
DESC="a command and a key the installer's shellprocess_initialize_pacman.conf gained and the overlay's copy lacks are critical (a frozen copy is reviewed, not silently outdated)"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'new-upstream-step' && printf '%s\n' "$GR_OUT" | grep -q "key 'newKey'"; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

# R3, second half: the frozen copy must also run the installer's commands WHERE (dontChroot) and in the ORDER the installer's file does; a copy
# that drops no command and no key but runs them in the other place, or backwards, is outdated just the same.
cp -R "$W/up" "$W/st15"
sed -i.bak 's/"dontChroot": true/"dontChroot": false/' "$W/st15/etc/calamares/modules/shellprocess_initialize_pacman.conf" && rm -f "$W/st15/etc/calamares/modules/shellprocess_initialize_pacman.conf.bak"
cmp -s "$W/up/etc/calamares/modules/shellprocess_initialize_pacman.conf" "$W/st15/etc/calamares/modules/shellprocess_initialize_pacman.conf" && echo "st15: the expression changed nothing" >&2
run_guards "$W/st15"
DESC="MUTANT: the installer's shellprocess_initialize_pacman.conf now runs in the target (dontChroot true -> false) while the overlay's frozen copy still runs on the live system: critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'shellprocess_initialize_pacman.conf: the installer.s config runs its commands inside the target' && printf '%s\n' "$GR_OUT" | grep -q 'live system'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$OV" "$W/ov-st16"
# swap the first two commands of the copy (mkdir of the hooks directory, then the cp into it): the same commands, the same keys, another order
awk 'BEGIN { h = "" } /^ - "mkdir -p \/etc\/pacman.d\/hooks\/"$/ && h == "" && !d { h = $0; next } h != "" { print; print h; h = ""; d = 1; next } { print }' \
  "$OV/modules/shellprocess_modify_mk_hook.conf" > "$W/ov-st16/modules/shellprocess_modify_mk_hook.conf"
cmp -s "$OV/modules/shellprocess_modify_mk_hook.conf" "$W/ov-st16/modules/shellprocess_modify_mk_hook.conf" && echo "st16: the awk program changed nothing" >&2
run_guards "$W/up" "$W/ov-st16"
DESC="MUTANT: the overlay's copy runs the installer's first two commands in the other order (nothing dropped, no key lost): critical, and the report names the command and the file"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'shellprocess_modify_mk_hook.conf: the installer.s config runs `cp /etc/calamares/scripts/90-mkinitcpio-install.hook /etc/pacman.d/hooks/` at a place in its order'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$OV" "$W/ov-st17"; sed -i.bak 's/^dontChroot: false$/dontChroot: true/' "$W/ov-st17/modules/shellprocess_reset_mk_hook.conf" && rm -f "$W/ov-st17/modules/shellprocess_reset_mk_hook.conf.bak"
cmp -s "$OV/modules/shellprocess_reset_mk_hook.conf" "$W/ov-st17/modules/shellprocess_reset_mk_hook.conf" && echo "st17: the expression changed nothing" >&2
run_guards "$W/up" "$W/ov-st17"
DESC="MUTANT: the overlay's copy of shellprocess_reset_mk_hook.conf runs on the live system where the installer's runs in the target: critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'shellprocess_reset_mk_hook.conf: the installer.s config runs its commands inside the target' && printf '%s\n' "$GR_OUT" | grep -q 'live system'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

# The shorter forms of `script:` (one string, one mapping) are read as the list they stand for.
cp -R "$W/up" "$W/st18"
printf '%s\n' '{"dontChroot": false, "script": "pacman -Syu --noconfirm", "timeout": 20}' > "$W/st18/etc/calamares/modules/shellprocess.conf"
run_guards "$W/st18"
DESC="MUTANT: a stock step whose \`script:\` is ONE STRING running pacman on a 20 s file-level limit is critical (the string was read one character at a time and passed)"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'shellprocess.conf: command 1' && printf '%s\n' "$GR_OUT" | grep -q 'may only take 20 s'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/st19"
printf '%s\n' '{"dontChroot": false, "script": {"command": "pacman -Syu --noconfirm", "timeout": 900}}' > "$W/st19/etc/calamares/modules/shellprocess.conf"
run_guards "$W/st19"
DESC="a stock step whose \`script:\` is ONE MAPPING with its own 900 s limit passes (it was reported as having no limit)"
if [ "$GR_RC" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
cp -R "$W/up" "$W/st20"
printf '%s\n' '{"dontChroot": false, "script": {"command": "pacman -Syu --noconfirm"}}' > "$W/st20/etc/calamares/modules/shellprocess.conf"
run_guards "$W/st20"
DESC="MUTANT: a stock step whose \`script:\` is ONE MAPPING without any limit is critical (the 30 s default)"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'shellprocess.conf: command 1' && printf '%s\n' "$GR_OUT" | grep -q 'after 30 s'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

# The initramfs, bootloader, locale and splash tools are disk-heavy too (300 s), whether the command line or the script it runs names them.
cp -R "$W/up" "$W/st21"
printf '%s\n' '{"dontChroot": false, "script": [{"command": "/etc/calamares/scripts/btrfs-installation-snapshot"}], "timeout": 60}' > "$W/st21/etc/calamares/modules/shellprocess_btrfs_snapshot.conf"
printf '%s\n' 'limine-update' 'locale-gen' 'dracut --force' 'plymouth-set-default-theme -R companion-os' > "$W/st21/etc/calamares/scripts/btrfs-installation-snapshot"
run_guards "$W/st21"
DESC="MUTANT: a stock step whose script runs limine-update, locale-gen, dracut and plymouth-set-default-theme on a 60 s limit is critical, naming each, and needing 300 s"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'limine-update' && printf '%s\n' "$GR_OUT" | grep -q 'locale-gen' && printf '%s\n' "$GR_OUT" | grep -q 'dracut' && printf '%s\n' "$GR_OUT" | grep -q 'plymouth-set-default-theme' && printf '%s\n' "$GR_OUT" | grep -q 'needs at least 300 s'; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi
printf '%s\n' '{"dontChroot": false, "script": [{"command": "/etc/calamares/scripts/btrfs-installation-snapshot"}], "timeout": 300}' > "$W/st21/etc/calamares/modules/shellprocess_btrfs_snapshot.conf"
run_guards "$W/st21"
DESC="... and 300 s is enough for them"
if [ "$GR_RC" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$GR_OUT" | sed 's/^/      /'; fi

# The guard fails closed.
cp -R "$OV" "$W/ov-st12"; rm "$W/ov-st12/lib/ci-shellprocess.py"
run_guards "$W/up" "$W/ov-st12"
DESC="a missing lib/ci-shellprocess.py is critical (the check cannot run, so it does not pass silently)"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'ci-shellprocess.py'; then t_pass "$DESC"; else t_fail "$DESC"; fi
cp -R "$OV" "$W/ov-st13"; printf '%s\n' 'this: is: not: [yaml' > "$W/ov-st13/modules/shellprocess_ci_os_fixups.conf"
run_guards "$W/up" "$W/ov-st13"
DESC="a shellprocess config that does not parse is critical"
if [ "$GR_RC" = 1 ] && printf '%s\n' "$GR_OUT" | grep -q 'does not parse'; then t_pass "$DESC"; else t_fail "$DESC"; fi

# On the live system the guards run with CI_OS_CALAMARES_ROOT unset and ci_g_root prints nothing; the reader joins paths to the root it is given, so
# an empty root would make it look in ./etc/calamares of the launcher's working directory. The guard must pass "/" then (a stub reader shows what it got).
mkdir -p "$W/ov-st14/lib"; printf 'import sys\nprint("ROOT=" + repr(sys.argv[2]))\nsys.exit(1)\n' > "$W/ov-st14/lib/ci-shellprocess.py"
OUT14="$(env -u CI_OS_CALAMARES_ROOT CI_OS_OVERLAY_DIR="$W/ov-st14" bash -c '. "$1/lib/ci-guards.sh"; ci_g_reset; ci_g_g_shell_timeouts critical why; printf "%s" "$CI_G_CRIT_MSGS"' _ "$INSTALLER" 2>&1)"
OUT14b="$(CI_OS_CALAMARES_ROOT="$W/up/" CI_OS_OVERLAY_DIR="$W/ov-st14" bash -c '. "$1/lib/ci-guards.sh"; ci_g_reset; ci_g_g_shell_timeouts critical why; printf "%s" "$CI_G_CRIT_MSGS"' _ "$INSTALLER" 2>&1)"
DESC="the shell-timeouts guard gives its reader '/' for the live system (no CI_OS_CALAMARES_ROOT), not an empty string that would read ./etc/calamares, and the given root, without its trailing slash, otherwise"
if printf '%s' "$OUT14" | grep -q "ROOT='/'" && printf '%s' "$OUT14b" | grep -qF "ROOT='$W/up'"; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n%s\n' "$OUT14" "$OUT14b" | sed 's/^/      /'; fi

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
DESC="cosmetic patches rename the product in the progress text, the Limine post-setup script, the Btrfs snapshot description and the driver job's label"
if grep -q 'installation of Companion OS' "$W/a1/etc/calamares/modules/shellprocess-before-online.conf" \
  && grep -q 'Online-Installation von Companion OS' "$W/a1/etc/calamares/modules/shellprocess-before-online.conf" \
  && grep -q 'TARGET_OS_NAME="Companion OS"' "$W/a1/etc/calamares/scripts/bootloader-post-setup" \
  && grep -q 'Fresh Companion OS Installation' "$W/a1/etc/calamares/scripts/btrfs-installation-snapshot" \
  && grep -q '^FIRST_WARN=0$' "$W/patch.out"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$W/patch.out"; fi
DESC="the driver job's label (job 26, the 35 percent status line of ISO #5: 'Installing needed drivers for CachyOS...') now names the product, and nothing of it still says CachyOS"
CHWD="$W/a1/usr/lib/calamares/modules/chwd/main.py"
if [ -f "$CHWD" ] && grep -qxF 'Installing needed drivers for Companion OS' "$CHWD" && ! grep -qi 'cachy' "$CHWD"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$CHWD" 2>/dev/null; fi
# The line as the installer's chwd/main.py has it (3.4.2-13, line 34), with its neighbours: only that line changes, the Python stays valid.
mkdir -p "$W/chwd1/usr/lib/calamares/modules/chwd"
printf '%s\n' 'def pretty_name():' '    return _("Installing needed drivers for CachyOS...")' '' 'def line_cb(line):' '    libcalamares.utils.debug("chwd: " + line.strip())' > "$W/chwd1/usr/lib/calamares/modules/chwd/main.py"
cp "$W/chwd1/usr/lib/calamares/modules/chwd/main.py" "$W/chwd1/main.py.orig"
CI_OS_CALAMARES_ROOT="$W/chwd1" CI_OS_SUDO='' bash -c '. "$1/lib/ci-guards.sh"; ci_g_reset; ci_g_apply_cosmetic_patches "$2/patches.list"' _ "$INSTALLER" "$OV" >/dev/null 2>&1 || true
DESC="the driver label patch turns '_(\"Installing needed drivers for CachyOS...\")' into the Companion OS wording, exactly, and leaves the other lines of chwd/main.py byte for byte"
if [ "$(sed -n 2p "$W/chwd1/usr/lib/calamares/modules/chwd/main.py")" = '    return _("Installing needed drivers for Companion OS...")' ] \
  && [ "$(sed '2d' "$W/chwd1/usr/lib/calamares/modules/chwd/main.py")" = "$(sed '2d' "$W/chwd1/main.py.orig")" ]; then t_pass "$DESC"; else t_fail "$DESC"; cat "$W/chwd1/usr/lib/calamares/modules/chwd/main.py" | sed 's/^/      /'; fi
DESC="applying them a second time is a warning each (the markers are gone), never an error"
if grep -q '^SECOND_WARN=4$' "$W/patch.out"; then t_pass "$DESC"; else t_fail "$DESC"; fi
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
  -Sy) exec fake-pacman-sy "$@" ;;
  -Sw)
    [ "${FAKE_SW_RC:-0}" = 0 ] || exit "$FAKE_SW_RC"
    mkdir -p "$CI_OS_PKG_CACHE"; : > "$CI_OS_PKG_CACHE/cachyos-calamares-next-$FAKE_REPO_VER-x86_64.pkg.tar.zst"; exit 0 ;;
  -S)
    # a reinstall of the installer: the candidate tree replaces the files of the installer tree
    [ -z "${FAKE_CANDIDATE:-}" ] || cp -R "$FAKE_CANDIDATE"/. "$CI_OS_CALAMARES_ROOT"/
    echo installed > "$FAKE_STATE/installed-candidate"; exit 0 ;;
esac
exit 0'
# stub_from_stdin NAME: the body comes from a heredoc (quoting inside the stubs below would otherwise be unreadable).
stub_from_stdin() { { printf '#!/bin/bash\n'; cat; } > "$W/bin/$1"; chmod +x "$W/bin/$1"; }
# pacman-key: a keyring is "working" when $CI_OS_PACMAN_GNUPG_DIR/pubring.gpg is not empty and there is no file named "corrupt" in it.
# --init creates it (and repairs a "corrupt" one only when FAKE_REPAIRABLE=1); FAKE_INIT_RC / FAKE_POPULATE_RC make a step fail.
stub_from_stdin pacman-key <<'STUB'
echo "pacman-key $*" >> "$FAKE_LOG"
G="$CI_OS_PACMAN_GNUPG_DIR"
case "$1" in
  --list-keys)
    if [ -s "$G/pubring.gpg" ] && [ ! -e "$G/corrupt" ]; then exit 0; fi
    echo "gpg: error reading key: No public key" >&2; exit 2 ;;
  --init)
    if [ "${FAKE_INIT_RC:-0}" != 0 ]; then echo "==> ERROR: could not initialise the keyring" >&2; exit "$FAKE_INIT_RC"; fi
    mkdir -p "$G"
    [ -s "$G/pubring.gpg" ] || echo keys > "$G/pubring.gpg"
    if [ -e "$G/corrupt" ] && [ "${FAKE_REPAIRABLE:-1}" = 1 ]; then rm -f "$G/corrupt"; fi
    exit 0 ;;
  --populate)
    if [ "${FAKE_POPULATE_RC:-0}" != 0 ]; then echo "==> ERROR: could not populate the keyring" >&2; exit "$FAKE_POPULATE_RC"; fi
    exit 0 ;;
esac
exit 0
STUB
# The keyring directory as a MOUNT POINT (FAKE_MOUNT=1, run_launcher's default): the directory itself can neither be removed nor
# renamed (EBUSY); what is inside it can. rm, mv and rmdir hand everything else to the real tool. /etc/pacman.d/gnupg is a mount
# point whenever pacman-init.service Requires= etc-pacman.d-gnupg.mount (archiso's releng profile does; the pinned CachyOS one ships
# the unit but does not pull it in, so an upstream change could).
stub_from_stdin rm <<'STUB'
for a in "$@"; do
  if [ "${FAKE_MOUNT:-0}" = 1 ] && [ -d "${CI_OS_PACMAN_GNUPG_DIR:-/nonexistent}" ] && [ "${a%/}" = "${CI_OS_PACMAN_GNUPG_DIR%/}" ]; then
    echo "BUSY rm $a" >> "$FAKE_LOG"; echo "rm: cannot remove '$a': Device or resource busy" >&2; exit 1
  fi
done
exec /bin/rm "$@"
STUB
stub_from_stdin rmdir <<'STUB'
for a in "$@"; do
  if [ "${FAKE_MOUNT:-0}" = 1 ] && [ -d "${CI_OS_PACMAN_GNUPG_DIR:-/nonexistent}" ] && [ "${a%/}" = "${CI_OS_PACMAN_GNUPG_DIR%/}" ]; then
    echo "BUSY rmdir $a" >> "$FAKE_LOG"; echo "rmdir: failed to remove '$a': Device or resource busy" >&2; exit 1
  fi
done
exec /bin/rmdir "$@"
STUB
stub_from_stdin mv <<'STUB'
for a in "$@"; do
  if [ "${FAKE_MOUNT:-0}" = 1 ] && [ -d "${CI_OS_PACMAN_GNUPG_DIR:-/nonexistent}" ] && [ "${a%/}" = "${CI_OS_PACMAN_GNUPG_DIR%/}" ]; then
    echo "BUSY mv $a" >> "$FAKE_LOG"; echo "mv: cannot move '$a': Device or resource busy" >&2; exit 1
  fi
done
exec /bin/mv "$@"
STUB
stub gpgconf 'echo "gpgconf $*" >> "$FAKE_LOG"; exit 0'
# pacman -Sy: models the defect of 2026-10-18. Without a public keyring the [cachyos] database cannot be verified.
# FAKE_SY_BAD_OUT / FAKE_SY_BAD_COUNT: the first N calls (default 1) fail with that output (a keyring error that goes away once the
# keyring is repaired); $FAKE_STATE/sy-count counts the calls.
stub_from_stdin fake-pacman-sy <<'STUB'
n=0; [ ! -f "$FAKE_STATE/sy-count" ] || n="$(cat "$FAKE_STATE/sy-count")"; n=$((n + 1)); echo "$n" > "$FAKE_STATE/sy-count"
if [ ! -s "$CI_OS_PACMAN_GNUPG_DIR/pubring.gpg" ]; then
  echo "warning: Public keyring not found; have you run 'pacman-key --init'?" >&2
  echo 'error: cachyos: key "882DCFE48E2051D48E2562ABF3B607488DB35A47" is unknown' >&2
  echo "error: keyring is not writable" >&2
  echo "error: failed to synchronize all databases (unexpected error)" >&2
  exit 1
fi
if [ -n "${FAKE_SY_BAD_OUT:-}" ] && [ "$n" -le "${FAKE_SY_BAD_COUNT:-1}" ]; then printf '%s\n' "$FAKE_SY_BAD_OUT" >&2; exit 1; fi
if [ "${FAKE_NET:-up}" = down ]; then
  echo "error: failed retrieving file 'core.db' from geo.mirror.pkgbuild.com : Could not resolve host: geo.mirror.pkgbuild.com" >&2
  echo "error: failed to synchronize all databases (unexpected error)" >&2
  exit 1
fi
[ -z "${FAKE_SY_OUT:-}" ] || printf '%s\n' "$FAKE_SY_OUT" >&2
exit "${FAKE_SY_RC:-0}"
STUB
stub timedatectl 'echo "timedatectl $*" >> "$FAKE_LOG"; exit 0'
stub bsdtar 'echo "bsdtar $*" >> "$FAKE_LOG"; [ "${FAKE_BSDTAR_RC:-0}" = 0 ] || exit "$FAKE_BSDTAR_RC"; while [ $# -gt 0 ]; do [ "$1" = -C ] && dest="$2"; shift; done; cp -R "$FAKE_CANDIDATE"/. "$dest"/; exit 0'
stub pkexec-wrapper 'echo "pkexec-wrapper $*" >> "$FAKE_LOG"; exit "${FAKE_CAL_RC:-0}"'
stub kdialog 'echo "kdialog $*" >> "$FAKE_UI"; exit 0'
stub notify-send 'echo "notify-send $*" >> "$FAKE_UI"; exit 0'
stub curl 'echo "curl $*" >> "$FAKE_LOG"; exit 0'
# ldd -r of the CANDIDATE installer: what FAKE_LDD_OUT holds (default: nothing wrong). The launcher runs it with LD_LIBRARY_PATH at the candidate.
stub ldd 'echo "ldd $*" >> "$FAKE_LOG"; echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}" >> "$FAKE_LOG"; [ -z "${FAKE_LDD_OUT:-}" ] || printf "%s\n" "$FAKE_LDD_OUT"; exit 0'

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
    CI_OS_KEYRING_DIAG_DIR="$R/diag" FAKE_MOUNT=1 \
    CI_OS_LOCK_FILE="$R/lock" CI_OS_LIVE_ROOT="$W/live" FAKE_LOG="$R/log" FAKE_UI="$R/ui" FAKE_STATE="$R/state" \
    FAKE_INSTALLED_VER=3.4.2-13 FAKE_REPO_VER=3.4.2-13 \
    "$@" bash "${L_SCRIPT:-$LAUNCHER}" > "$R/out" 2>&1 && L_RC=0 || L_RC=$?
  L_DIR="$R"
}
# The live system's normal state: pacman-init.service made a working keyring at boot. old-key is a marker that it is the same one afterwards.
seed_gnupg() { mkdir -p "$W/r-$1/gnupg"; echo old > "$W/r-$1/gnupg/old-key"; echo keys > "$W/r-$1/gnupg/pubring.gpg"; }

# 1. happy path, installer current
seed_gnupg happy
if [ "$HAVE_YAML" = 1 ]; then
  run_launcher happy
  DESC="launcher: a current installer is not downloaded; the overlay is applied; Calamares starts through pkexec-wrapper (exit 0)"
  if [ "$L_RC" = 0 ] && ! grep -q -- '-Sw' "$L_DIR/log" && grep -q '^pkexec-wrapper calamares -D6' "$L_DIR/log" \
    && cmp -s "$OV/settings.conf" "$L_DIR/root/etc/calamares/settings.conf"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/out"; fi
  DESC="launcher: a working keyring is kept (never deleted) and populated BEFORE the first sync: list, populate, NTP, one -Sy of both keyring packages, populate; no --init"
  seq="$(grep -E '^(pacman -Sy|pacman-key|timedatectl)' "$L_DIR/log" | tr '\n' ';')"
  if [ "$seq" = "pacman-key --list-keys;pacman-key --populate archlinux cachyos;timedatectl set-ntp true;pacman -Sy --noconfirm archlinux-keyring cachyos-keyring;pacman-key --populate archlinux cachyos;" ] \
    && [ "$(cat "$L_DIR/gnupg/old-key")" = old ] && [ "$(cat "$L_DIR/gnupg/pubring.gpg")" = keys ]; then t_pass "$DESC"; else t_fail "$DESC ($seq)"; fi
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
  mkdir -p "$W/cand-ok"; cp -R "$W/up"/. "$W/cand-ok"/; printf 'candidateMarker: 1\n' >> "$W/cand-ok/etc/calamares/modules/partition.conf"
  seed_gnupg upd
  run_launcher upd FAKE_REPO_VER=3.4.2-14 FAKE_CANDIDATE="$W/cand-ok"
  DESC="launcher: a newer installer that passes the guards is downloaded (pacman -Sw), unpacked (bsdtar) and installed (pacman -S)"
  if [ "$L_RC" = 0 ] && grep -q '^pacman -Sw --noconfirm cachyos-calamares-next' "$L_DIR/log" && grep -q '^bsdtar -xf' "$L_DIR/log" \
    && [ -f "$L_DIR/state/installed-candidate" ] && grep -q 'candidateMarker' "$L_DIR/root/etc/calamares/modules/partition.conf"; then t_pass "$DESC"; else t_fail "$DESC"; fi
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

  # 3b. a newer installer that passes the guards but does not LINK here (F2 on the install-day side: the package depends on boost-libs
  # without a version, so a rebuild against a newer boost installs fine and does not start): the installer on the ISO is kept.
  mkdir -p "$W/cand-bin"; cp -R "$W/cand-ok"/. "$W/cand-bin"/
  mkdir -p "$W/cand-bin/usr/bin" "$W/cand-bin/usr/lib"; : > "$W/cand-bin/usr/bin/calamares"; : > "$W/cand-bin/usr/lib/libcalamares.so.3.5"
  seed_gnupg lk1
  run_launcher lk1 FAKE_REPO_VER=3.5.0-1 FAKE_CANDIDATE="$W/cand-bin"
  DESC="launcher: a newer installer that links on this system is installed; ldd -r ran on ITS binary with LD_LIBRARY_PATH at its own libraries"
  if [ "$L_RC" = 0 ] && [ -f "$L_DIR/state/installed-candidate" ] && grep -q '^ldd -r .*/usr/bin/calamares' "$L_DIR/log" && grep -q '^LD_LIBRARY_PATH=.*/usr/lib' "$L_DIR/log" \
    && grep -q 'candidate installer links on this system' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/install.log" | tail -n 5; fi
  seed_gnupg lk2
  run_launcher lk2 FAKE_REPO_VER=3.5.0-1 FAKE_CANDIDATE="$W/cand-bin" FAKE_LDD_OUT="	libboost_python314.so.1.93.0 => not found"
  DESC="launcher: a newer installer that needs a library this system lacks (libboost_python314.so.1.93.0 => not found) is NOT installed; the ISO's installer is kept and started"
  if [ "$L_RC" = 0 ] && [ ! -f "$L_DIR/state/installed-candidate" ] && ! grep -q '^pacman -S --noconfirm cachyos-calamares-next' "$L_DIR/log" && grep -q '^pkexec-wrapper calamares' "$L_DIR/log" \
    && grep -q 'libboost_python314.so.1.93.0 => not found' "$L_DIR/install.log" && grep -q 'does not link on this system.*KEEPING the installer on this ISO' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/install.log" | tail -n 6; fi
  DESC="launcher: ... and the person is told why, with the version and the log path"
  if grep -q '3.5.0-1' "$L_DIR/out" && grep -q 'needs libraries that this live system does not have' "$L_DIR/out" && grep -q 'install.log' "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; fi
  seed_gnupg lk3
  run_launcher lk3 FAKE_REPO_VER=3.5.0-1 FAKE_CANDIDATE="$W/cand-bin" FAKE_LDD_OUT="undefined symbol: _ZN5boost6python6detail11init_moduleER11PyModuleDefPFvvE	(/usr/lib/libcalamares.so.3.5)"
  DESC="launcher: an undefined symbol (the second F2 failure) keeps the installer on the ISO as well"
  if [ "$L_RC" = 0 ] && [ ! -f "$L_DIR/state/installed-candidate" ] && grep -q 'undefined symbol: _ZN5boost6python6detail11init_module' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; fi

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
run_launcher sy FAKE_NET=down
DESC="launcher: an unreachable repository (pacman -Sy fails on the network) stops with a clear message before anything else"
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
  DESC="launcher: refuses to use '$bad' as the keyring directory (the keyring step works inside it)"
  if [ "$L_RC" = 1 ] && grep -q "refusing to use '$bad' as the pacman keyring directory" "$W/r-kd/out" && ! grep -q '^pacman' "$W/r-kd/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
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

# 13. the keyring (incident 2026-10-18, F1). The ISO of that day failed on every click, 20 s after it, with a dialog that blamed the
# network: the launcher removed /etc/pacman.d/gnupg, ran `pacman -Sy` (which cannot verify the [cachyos] database without a keyring)
# and only then `pacman-key --init`. The stubs above model exactly that failure, so these cases fail on the old order.
echo "== launcher: the keyring is created BEFORE the first sync, a working one is never deleted (F1)"
keys_seq() { grep -E '^(pacman -Sy|pacman-key|timedatectl)' "$1/log" | tr '\n' ';'; }
SEQ_INIT_THEN_SYNC="pacman-key --init;pacman-key --populate archlinux cachyos;timedatectl set-ntp true;pacman -Sy --noconfirm archlinux-keyring cachyos-keyring;pacman-key --populate archlinux cachyos;"

# check_no_keyring DIR RC: what a click on a live system with NO keyring must do. Used on the real launcher and on the mutants.
check_no_keyring() {
  local d="$1" rc="$2"
  [ "$(keys_seq "$d")" = "$SEQ_INIT_THEN_SYNC" ] || return 1
  [ -s "$d/gnupg/pubring.gpg" ] || return 1
  if [ "$HAVE_YAML" = 1 ]; then [ "$rc" = 0 ] || return 1; fi
  return 0
}

run_launcher k1                       # no gnupg directory at all
DESC="keyring: none at all: pacman-key --init and --populate run BEFORE the first -Sy, which then succeeds (the click goes on)"
if check_no_keyring "$L_DIR" "$L_RC"; then t_pass "$DESC"; else t_fail "$DESC ($(keys_seq "$L_DIR") rc=$L_RC)"; sed 's/^/      /' "$L_DIR/out" | tail -n 8; fi
DESC="keyring: ... and the log says so (no keyring: creating it ... before any database is synced)"
if grep -q 'no pacman keyring in .*creating it.*before any database is synced' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; fi

mkdir -p "$W/r-k1b/gnupg"; run_launcher k1b          # the directory exists and is empty
DESC="keyring: an empty directory counts as no keyring (same order)"
if check_no_keyring "$L_DIR" "$L_RC"; then t_pass "$DESC"; else t_fail "$DESC ($(keys_seq "$L_DIR") rc=$L_RC)"; fi

SEQ_HAPPY="pacman-key --list-keys;pacman-key --populate archlinux cachyos;timedatectl set-ntp true;pacman -Sy --noconfirm archlinux-keyring cachyos-keyring;pacman-key --populate archlinux cachyos;"
check_populate_first() { [ "$(keys_seq "$1")" = "$SEQ_HAPPY" ]; }   # DIR: list, populate, NTP, the first sync, populate
seed_gnupg k2; run_launcher k2
DESC="keyring: a working keyring is populated (pacman-key --populate archlinux cachyos) BEFORE the first -Sy, not only after it"
if check_populate_first "$L_DIR"; then t_pass "$DESC"; else t_fail "$DESC ($(keys_seq "$L_DIR"))"; fi
DESC="keyring: a working keyring is not touched: same files, no --init, no move"
if [ "$(cat "$L_DIR/gnupg/old-key")" = old ] && ! grep -q 'pacman-key --init' "$L_DIR/log" && ! ls "$L_DIR"/gnupg.broken.* >/dev/null 2>&1 \
  && grep -q 'works: keeping it' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; fi

seed_gnupg k3; : > "$W/r-k3/gnupg/corrupt"
run_launcher k3 FAKE_REPAIRABLE=1
DESC="keyring: a broken keyring that --init repairs is repaired IN PLACE (nothing set aside, the old files stay)"
seq="$(keys_seq "$L_DIR")"
if [ "$seq" = "pacman-key --list-keys;pacman-key --init;pacman-key --populate archlinux cachyos;pacman-key --list-keys;timedatectl set-ntp true;pacman -Sy --noconfirm archlinux-keyring cachyos-keyring;pacman-key --populate archlinux cachyos;" ] \
  && [ "$(cat "$L_DIR/gnupg/old-key")" = old ] && ! ls "$L_DIR"/gnupg.broken.* >/dev/null 2>&1; then t_pass "$DESC"; else t_fail "$DESC ($seq)"; fi

# A keyring that pacman-key --init can NOT repair (the "corrupt" marker survives it), with what a real one holds: a public keyring, a
# trust database, dot files, a socket, private keys and a legacy secret ring. The directory is a mount point (FAKE_MOUNT=1): it can
# not be renamed or removed, only emptied.
seed_unrepairable() { # NAME
  local g="$W/r-$1/gnupg"
  seed_gnupg "$1"
  : > "$g/corrupt"; echo trust > "$g/trustdb.gpg"; : > "$g/.gpg-v21-migrated"; : > "$g/S.gpg-agent"; echo ring > "$g/secring.gpg"
  mkdir -p "$g/private-keys-v1.d" "$g/openpgp-revocs.d"; echo k > "$g/private-keys-v1.d/abc.key"; echo r > "$g/openpgp-revocs.d/abc.rev"
}
# check_unrepairable DIR RC: the contents are gone (dot files and directories too), the directory itself is still there and was never
# renamed or removed (no BUSY line, nothing named gnupg.broken.*), a new keyring was made, and the click went on.
check_unrepairable() {
  local d="$1" rc="$2" g="$1/gnupg" f
  [ -d "$g" ] || return 1
  for f in old-key corrupt trustdb.gpg .gpg-v21-migrated S.gpg-agent secring.gpg private-keys-v1.d openpgp-revocs.d; do [ ! -e "$g/$f" ] || return 1; done
  [ -s "$g/pubring.gpg" ] || return 1
  if ls "$d"/gnupg.broken.* >/dev/null 2>&1; then return 1; fi
  if grep -q '^BUSY' "$d/log"; then return 1; fi
  if [ "$HAVE_YAML" = 1 ] && [ "$rc" != 0 ]; then return 1; fi
  return 0
}
# check_diag_copy DIR: the public files of the old keyring are kept for diagnosis, the private ones are not.
check_diag_copy() {
  local c
  c="$(ls -d "$1"/diag/ci-os-keyring-cleared.* 2>/dev/null | head -n 1)"
  [ -n "$c" ] || return 1
  [ "$(cat "$c/pubring.gpg" 2>/dev/null)" = keys ] && [ "$(cat "$c/trustdb.gpg" 2>/dev/null)" = trust ] || return 1
  [ ! -e "$c/secring.gpg" ] && [ ! -e "$c/private-keys-v1.d" ] && [ ! -e "$c/S.gpg-agent" ] && [ ! -e "$c/openpgp-revocs.d" ] || return 1
  [ "$(stat -c %a "$c" 2>/dev/null || stat -f %Lp "$c")" = 700 ]
}

seed_unrepairable k4
run_launcher k4 FAKE_REPAIRABLE=0
DESC="keyring: a keyring that cannot be repaired has its CONTENTS cleared in place (dot files, sockets, private keys, subdirectories); the directory itself is never renamed or removed, and the click goes on with a new keyring"
if check_unrepairable "$L_DIR" "$L_RC" && grep -q '^pacman -Sy' "$L_DIR/log" && grep -q 'cleared the contents of .*gnupg (the directory itself was left in place)' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/install.log" | tail -n 8; ls -la "$L_DIR/gnupg" | sed 's/^/      /'; fi
DESC="keyring: ... a stale gpg-agent is stopped first (gpgconf --homedir DIR --kill all)"
if grep -q "^gpgconf --homedir $L_DIR/gnupg --kill all" "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="keyring: ... a copy of the PUBLIC files is kept for diagnosis (mode 700); private keys, the legacy secret ring and sockets are not copied"
if check_diag_copy "$L_DIR" && grep -q 'kept [0-9]* public file(s) of the old keyring in .*diag/ci-os-keyring-cleared' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; ls -laR "$L_DIR/diag" 2>&1 | sed 's/^/      /'; fi

# the same on a directory that is NOT a mount point: the in-place clearing does not depend on it
seed_unrepairable k4b
run_launcher k4b FAKE_REPAIRABLE=0 FAKE_MOUNT=0
DESC="keyring: the same on an ordinary directory (not a mount point)"
if check_unrepairable "$L_DIR" "$L_RC"; then t_pass "$DESC"; else t_fail "$DESC"; fi

# what the clearing refuses: a directory that is not called gnupg (this DELETES), and a symbolic link
mkdir -p "$W/r-k4c/keys"; echo old > "$W/r-k4c/keys/old-key"; echo keys > "$W/r-k4c/keys/pubring.gpg"; : > "$W/r-k4c/keys/corrupt"
run_launcher k4c FAKE_REPAIRABLE=0 CI_OS_PACMAN_GNUPG_DIR="$W/r-k4c/keys"
DESC="keyring: it refuses to clear a directory that is not called gnupg: nothing is deleted, the click stops with the keyring dialog"
if [ "$L_RC" = 1 ] && [ "$(cat "$L_DIR/keys/old-key")" = old ] && [ -e "$L_DIR/keys/corrupt" ] && grep -q "refusing to clear '.*/keys'" "$L_DIR/install.log" \
  && grep -q 'not with your internet connection' "$L_DIR/out" && ! grep -q '^pkexec-wrapper' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/install.log" | tail -n 5; fi
mkdir -p "$W/r-k4d/elsewhere"; echo old > "$W/r-k4d/elsewhere/old-key"; echo keys > "$W/r-k4d/elsewhere/pubring.gpg"; : > "$W/r-k4d/elsewhere/corrupt"
ln -s "$W/r-k4d/elsewhere" "$W/r-k4d/gnupg"
run_launcher k4d FAKE_REPAIRABLE=0
DESC="keyring: it refuses to clear a symbolic link (the target keeps every file)"
if [ "$L_RC" = 1 ] && [ "$(cat "$L_DIR/elsewhere/old-key")" = old ] && [ -e "$L_DIR/elsewhere/corrupt" ] && grep -q "refusing to clear '.*gnupg': it is a symbolic link" "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/install.log" | tail -n 5; fi

seed_gnupg k5; run_launcher k5 FAKE_NET=down
DESC="keyring: network down: the dialog text says the repositories could not be reached, not a keyring problem"
if [ "$L_RC" = 1 ] && grep -q 'package repositories could not be reached' "$L_DIR/out" && ! grep -q 'not with your internet connection' "$L_DIR/out" && ! grep -q '^pkexec-wrapper' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="keyring: network down is not retried and not repaired: one -Sy, no --init, the keyring files untouched"
if [ "$(cat "$L_DIR/state/sy-count")" = 1 ] && ! grep -q 'pacman-key --init' "$L_DIR/log" && [ "$(cat "$L_DIR/gnupg/old-key")" = old ]; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="keyring: ... and the log classifies it as network, shows pacman's exact last error line and the line above it that says why"
if grep -q 'classified as: network' "$L_DIR/install.log" && grep -q "Last pacman error: error: failed to synchronize all databases (unexpected error)" "$L_DIR/install.log" \
  && grep -q "error and warning lines, in order: error: failed retrieving file 'core.db' from geo.mirror.pkgbuild.com : Could not resolve host" "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; grep -E 'classified|Last pacman' "$L_DIR/install.log" | sed 's/^/      /'; fi

seed_gnupg k6; run_launcher k6 FAKE_SY_RC=1 FAKE_SY_OUT='error: cachyos: key "882DCFE48E2051D48E2562ABF3B607488DB35A47" is unknown
error: failed to synchronize all databases (unexpected error)'
DESC="keyring: a keyring error at the sync (unknown key) is reported as a KEYRING problem, not as a network problem"
if [ "$L_RC" = 1 ] && grep -q 'not with your internet connection' "$L_DIR/out" && ! grep -q 'could not be reached' "$L_DIR/out" && grep -q 'classified as: keyring' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/out" | tail -n 4; fi

run_launcher k7 FAKE_INIT_RC=1
DESC="keyring: pacman-key --init failing stops at once as a keyring problem: no sync is attempted, the log carries the init error"
if [ "$L_RC" = 1 ] && ! grep -q '^pacman -Sy' "$L_DIR/log" && grep -q 'not with your internet connection' "$L_DIR/out" && grep -q 'pacman-key --init failed: ==> ERROR: could not initialise the keyring' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/install.log" | tail -n 4; fi

seed_gnupg k8; run_launcher k8 FAKE_SY_RC=1 FAKE_SY_OUT='error: failed to prepare transaction (could not satisfy dependencies)'
DESC="keyring: an error that is neither keyring nor network is not retried either (one -Sy, no --init)"
if [ "$(cat "$L_DIR/state/sy-count")" = 1 ] && ! grep -q 'pacman-key --init' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="keyring: an error that is neither keyring nor network is reported as such (could not be updated), with pacman's line in the log"
if [ "$L_RC" = 1 ] && grep -q 'could not be updated' "$L_DIR/out" && grep -q 'classified as: other' "$L_DIR/install.log" && grep -q 'Last pacman error: error: failed to prepare transaction' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; fi

seed_gnupg k9; run_launcher k9 CI_OS_SKIP_KEYRING=1
DESC="keyring: CI_OS_SKIP_KEYRING=1 skips the whole step as before (no pacman-key, no -Sy, no NTP)"
if ! grep -qE '^(pacman -Sy|pacman-key|timedatectl)' "$L_DIR/log"; then t_pass "$DESC"; else t_fail "$DESC"; fi

# 13b. A 404 for a keyring PACKAGE is a mirror problem. `pacman -Sy archlinux-keyring cachyos-keyring` fails with the package file's name in
# the error, and a classifier that looks for the word "keyring" called that a keyring problem and told the person that their internet
# connection was fine. These are pacman's own lines for a mirror that lacks the file the database lists.
KR404="error: failed retrieving file 'archlinux-keyring-20261015-1-any.pkg.tar.zst' from geo.mirror.pkgbuild.com : The requested URL returned error: 404
warning: failed to retrieve some files
error: failed to commit transaction (failed to retrieve some files)"
check_404() { # DIR RC: reported as a network/mirror problem, one sync, no repair
  local d="$1" rc="$2"
  [ "$rc" = 1 ] || return 1
  grep -q 'classified as: network' "$d/install.log" || return 1
  grep -q 'package repositories could not be reached' "$d/out" || return 1
  if grep -q 'not with your internet connection' "$d/out"; then return 1; fi
  [ "$(cat "$d/state/sy-count")" = 1 ] || return 1
  if grep -q 'pacman-key --init' "$d/log"; then return 1; fi
  if grep -q '^pkexec-wrapper' "$d/log"; then return 1; fi
  return 0
}
seed_gnupg k10; run_launcher k10 FAKE_SY_RC=1 FAKE_SY_OUT="$KR404"
DESC="keyring: a 404 for archlinux-keyring-<version>.pkg.tar.zst at the sync is a NETWORK/mirror problem, not a keyring problem (dialog, classification, no repair, no retry)"
if check_404 "$L_DIR" "$L_RC"; then t_pass "$DESC"; else t_fail "$DESC"; grep -E 'classified|Last pacman' "$L_DIR/install.log" | sed 's/^/      /'; tail -n 3 "$L_DIR/out" | sed 's/^/      /'; fi
DESC="keyring: ... and the log keeps pacman's own last error line, with the package file name in it, verbatim"
if grep -q "Last pacman error: error: failed to commit transaction (failed to retrieve some files)" "$L_DIR/install.log" \
  && grep -q "pacman's error and warning lines, in order: error: failed retrieving file 'archlinux-keyring-20261015-1-any.pkg.tar.zst' from geo.mirror.pkgbuild.com : The requested URL returned error: 404" "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC"; grep -E 'classified|Last pacman|in order' "$L_DIR/install.log" | sed 's/^/      /'; fi

# 13c. The classifier on its own (keys_strip and keys_classify are taken out of the launcher): the table says what each text is.
getfn() { awk -v n="$2" '$0 ~ "^" n "\\(\\) \\{" { p = 1 } p { print } p && /^\}/ { exit }' "$1"; }
classify_of() { # TEXT [LAUNCHER]: prints the kind
  ( eval "$(getfn "${2:-$LAUNCHER}" keys_strip)"; eval "$(getfn "${2:-$LAUNCHER}" keys_classify)"; keys_classify "$1"; printf '%s' "$KEYS_KIND" )
}
KEY_UNKNOWN='error: cachyos: key "882DCFE48E2051D48E2562ABF3B607488DB35A47" is unknown'
check_table() { # LAUNCHER: every row; prints the rows that are wrong
  local bad=0 got n=0 l="$1"
  while IFS='|' read -r want text; do
    [ -n "$want" ] || continue
    n=$((n + 1))
    got="$(classify_of "$(printf '%b' "$text")" "$l")"
    if [ "$got" != "$want" ]; then bad=$((bad + 1)); printf '      row %s: expected %s, got %s: %s\n' "$n" "$want" "$got" "$text"; fi
  done <<'ROWS'
network|error: failed retrieving file 'archlinux-keyring-20261015-1-any.pkg.tar.zst' from geo.mirror.pkgbuild.com : The requested URL returned error: 404
network|error: failed retrieving file 'cachyos-keyring-20240331-1-any.pkg.tar.zst' from cdn.cachyos.org : The requested URL returned error: 503
network|error: failed retrieving file 'archlinux-keyring-20261015-1-any.pkg.tar.zst.sig' from https://mirror.example.org/archlinux/core/os/x86_64/ : Could not resolve host: mirror.example.org
network|error: failed to commit transaction (failed to retrieve some files)
network|error: failed retrieving file 'keyring-tools-1.2-1-x86_64.pkg.tar.zst' from mirror.example.org : The requested URL returned error: 404
network|:: Retrieving packages...\nerror: archlinux-keyring-20261015-1-any.pkg.tar.zst: HTTP/1.1 502 Bad Gateway
network|error: failed retrieving file 'core.db' from geo.mirror.pkgbuild.com : Could not resolve host: geo.mirror.pkgbuild.com
network|error: failed retrieving file 'extra.db' from mirror1 : Connection timed out after 10001 milliseconds
keyring|error: cachyos: key "882DCFE48E2051D48E2562ABF3B607488DB35A47" is unknown\nerror: failed to synchronize all databases (unexpected error)
keyring|error: archlinux-keyring: signature from "Packager <p@archlinux.org>" is unknown trust
keyring|warning: Public keyring not found; have you run 'pacman-key --init'?\nerror: keyring is not writable
keyring|error: failed to commit transaction (invalid or corrupted package (PGP signature))
keyring|error: failed retrieving file 'extra.db' from mirror1 : Connection timed out after 10001 milliseconds\nerror: cachyos: key "882DCFE48E2051D48E2562ABF3B607488DB35A47" is unknown
keyring|error: archlinux-keyring-20261015-1-any.pkg.tar.zst: keyring is not writable
other|error: failed to prepare transaction (could not satisfy dependencies)
other|error: failed to prepare transaction (could not satisfy dependencies)\n:: installing cachyos-keyring (20240331-1) breaks dependency 'cachyos-keyring-old'
other|:: Synchronizing package databases...
ROWS
  [ "$bad" -eq 0 ]
}
DESC="classifier: network for a 404/5xx/DNS failure that names a keyring package; keyring for a key, a signature, a missing keyring (also when a mirror timed out on the way); other for the rest (17 texts)"
if tbl="$(check_table "$LAUNCHER")"; then t_pass "$DESC"; else t_fail "$DESC"; printf '%s\n' "$tbl"; fi

# 13d. A working keyring that pacman REJECTS at the sync (an unknown key, often a keyring made before the clock was right): repaired in
# place, then exactly one more try. The stub fails the first -Sy and accepts the second.
seed_gnupg k11; run_launcher k11 FAKE_SY_BAD_OUT="$KEY_UNKNOWN
error: failed to synchronize all databases (unexpected error)" FAKE_SY_BAD_COUNT=1
SEQ_RETRY="pacman-key --list-keys;pacman-key --populate archlinux cachyos;timedatectl set-ntp true;pacman -Sy --noconfirm archlinux-keyring cachyos-keyring;pacman-key --init;pacman-key --populate archlinux cachyos;pacman-key --list-keys;pacman -Sy --noconfirm archlinux-keyring cachyos-keyring;pacman-key --populate archlinux cachyos;"
check_retry_ok() { # DIR RC
  local d="$1" rc="$2"
  [ "$(keys_seq "$d")" = "$SEQ_RETRY" ] || return 1
  [ "$(cat "$d/state/sy-count")" = 2 ] || return 1
  [ "$(cat "$d/gnupg/old-key")" = old ] || return 1
  if ls "$d"/gnupg.broken.* >/dev/null 2>&1; then return 1; fi
  if [ "$HAVE_YAML" = 1 ] && [ "$rc" != 0 ]; then return 1; fi
  return 0
}
DESC="keyring: a keyring error at the first sync repairs the keyring IN PLACE (init, populate, list) and retries the sync once; the second try succeeds and the click goes on"
if check_retry_ok "$L_DIR" "$L_RC" && grep -q 'the sync failed with a keyring error: repairing the keyring in place and trying the sync once more' "$L_DIR/install.log" \
  && grep -q 'the pacman keyring was repaired in place' "$L_DIR/install.log"; then t_pass "$DESC"; else t_fail "$DESC ($(keys_seq "$L_DIR") rc=$L_RC)"; sed 's/^/      /' "$L_DIR/install.log" | tail -n 8; fi

seed_gnupg k12; run_launcher k12 FAKE_SY_BAD_OUT="$KEY_UNKNOWN
error: failed to synchronize all databases (unexpected error)" FAKE_SY_BAD_COUNT=9
check_retry_once() { # DIR RC: a keyring error that survives the repair: exactly two syncs, one repair, then the dialog
  local d="$1" rc="$2"
  [ "$rc" = 1 ] || return 1
  [ "$(cat "$d/state/sy-count")" = 2 ] || return 1
  [ "$(grep -c 'pacman-key --init' "$d/log")" = 1 ] || return 1
  if grep -q '^pkexec-wrapper' "$d/log"; then return 1; fi
  grep -q 'classified as: keyring' "$d/install.log"
}
DESC="keyring: a keyring error that survives the repair is retried ONCE, not again: two syncs, one repair, then the keyring dialog (no Calamares)"
if check_retry_once "$L_DIR" "$L_RC"; then t_pass "$DESC"; else t_fail "$DESC (syncs: $(cat "$L_DIR/state/sy-count"), rc=$L_RC)"; fi
DESC="keyring: ... and the dialog says it is not the connection, that a restart does not help, and to run it again online or download a newer ISO"
if grep -q 'not with your internet connection' "$L_DIR/out" && grep -q 'Restarting the computer does not help' "$L_DIR/out" && grep -q 'start the installer again' "$L_DIR/out" \
  && grep -q 'this ISO is older than the keys the package repositories use now: download a newer Companion OS ISO' "$L_DIR/out" && ! grep -q 'restart the computer and try once more' "$L_DIR/out" \
  && ! grep -q 'could not be reached' "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; tail -n 3 "$L_DIR/out" | sed 's/^/      /'; fi

seed_gnupg k13; echo trust > "$W/r-k13/gnupg/trustdb.gpg"
run_launcher k13 FAKE_SY_BAD_OUT="$KEY_UNKNOWN" FAKE_SY_BAD_COUNT=9 FAKE_INIT_RC=1
DESC="keyring: when the repair after a failed sync fails too (init fails), the contents are cleared in place, the init is tried once more, and there is no second sync"
if [ "$L_RC" = 1 ] && [ "$(cat "$L_DIR/state/sy-count")" = 1 ] && [ -d "$L_DIR/gnupg" ] && [ ! -e "$L_DIR/gnupg/old-key" ] && ! grep -q '^BUSY' "$L_DIR/log" \
  && [ "$(grep -c 'pacman-key --init' "$L_DIR/log")" = 2 ] && grep -q 'not with your internet connection' "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/install.log" | tail -n 8; fi

# 13e. A usable keyring whose populate fails before the first sync is repaired (not trusted blindly)
seed_gnupg k14; run_launcher k14 FAKE_POPULATE_RC=1
DESC="keyring: a working keyring whose pre-sync populate fails is repaired before the sync (the dialog is the keyring one when that fails too)"
if [ "$L_RC" = 1 ] && grep -q 'could not load the keys of the keyring packages: repairing it' "$L_DIR/install.log" && [ "$(cat "$L_DIR/state/sy-count" 2>/dev/null || echo 0)" = 0 ] \
  && grep -q 'not with your internet connection' "$L_DIR/out"; then t_pass "$DESC"; else t_fail "$DESC"; sed 's/^/      /' "$L_DIR/install.log" | tail -n 6; fi

# The mutants. A test that cannot fail proves nothing: the same no-keyring case must FAIL on the order of the old launcher and on the
# right steps in the wrong order. Each mutant is the real launcher with only ONE function replaced (refresh_keys, or the function named).
mutant() { # NAME [FUNCTION]: the new body of FUNCTION (default refresh_keys) comes from stdin; builds $W/mut-NAME.sh from the real launcher
  { cat; } > "$W/mut-$1.fn"
  awk -v fn="$W/mut-$1.fn" -v name="${2:-refresh_keys}" '
    $0 ~ "^" name "\\(\\) \\{" { while ((getline l < fn) > 0) print l; skip = 1; next }
    skip && /^\}/ { skip = 0; next }
    !skip { print }' "$LAUNCHER" > "$W/mut-$1.sh"
}
# M1: the function of commit 6e7b0b5, the one that failed on 2026-10-18: delete, sync, then init.
mutant m1 <<'FN'
refresh_keys() {
  local gnupg="${CI_OS_PACMAN_GNUPG_DIR:-/etc/pacman.d/gnupg}"
  [ "${CI_OS_SKIP_KEYRING:-0}" = 1 ] && return 0
  log "re-initialising the pacman keyring ($gnupg)"
  $PRIV rm -rf "$gnupg"
  $PRIV pacman -Sy --noconfirm archlinux-keyring cachyos-keyring >> "$LOG" 2>&1 || return 1
  $PRIV pacman-key --init >> "$LOG" 2>&1 || return 1
  $PRIV pacman-key --populate archlinux cachyos >> "$LOG" 2>&1 || return 1
  timedatectl set-ntp true 2>/dev/null || true
  return 0
}
FN
# M2: everything right except that the init comes after the sync.
mutant m2 <<'FN'
refresh_keys() {
  local gnupg="${CI_OS_PACMAN_GNUPG_DIR:-/etc/pacman.d/gnupg}" out rc=0
  [ "${CI_OS_SKIP_KEYRING:-0}" = 1 ] && return 0
  timedatectl set-ntp true 2>/dev/null || true
  out="$($PRIV pacman -Sy --noconfirm archlinux-keyring cachyos-keyring 2>&1)" || rc=$?
  printf '%s\n' "$out" >> "$LOG"
  if [ "$rc" -ne 0 ]; then keys_classify "$out"; return 1; fi
  if keyring_missing "$gnupg"; then keyring_init || return 1; fi
  $PRIV pacman-key --populate archlinux cachyos >> "$LOG" 2>&1 || return 1
  return 0
}
FN
for m in m1 m2; do
  if ! grep -q "^refresh_keys() {" "$W/mut-$m.sh" || cmp -s "$W/mut-$m.sh" "$LAUNCHER"; then t_fail "mutant $m was not built (refresh_keys() not found in the launcher)"; continue; fi
  L_SCRIPT="$W/mut-$m.sh" run_launcher "mut$m"
  DESC="mutant $m ($([ "$m" = m1 ] && echo 'the old order: delete, sync, init' || echo 'init after the sync')): the no-keyring check FAILS on it, as it must"
  if ! check_no_keyring "$L_DIR" "$L_RC"; then t_pass "$DESC"; else t_fail "$DESC (the check passed on a launcher with the F1 defect)"; fi
done

# caught NAME FUNCTION CHECK SEEDER "what is wrong with it" [VAR=value ...]: build the mutant (body on stdin), run it on the case the
# check belongs to, and require the CHECK to FAIL. SEEDER is called with the mutant's run name (: for none).
caught() {
  local name="$1" fn="$2" check="$3" seeder="$4" what="$5"; shift 5
  mutant "$name" "$fn"
  if ! grep -q "^$fn() {" "$W/mut-$name.sh" || cmp -s "$W/mut-$name.sh" "$LAUNCHER"; then t_fail "mutant $name was not built ($fn() not found in the launcher, or the mutant equals it)"; return 0; fi
  if ! bash -n "$W/mut-$name.sh" 2>/dev/null; then t_fail "mutant $name has a syntax error"; return 0; fi
  "$seeder" "mut$name"
  L_SCRIPT="$W/mut-$name.sh" run_launcher "mut$name" "$@"
  if ! "$check" "$L_DIR" "$L_RC"; then t_pass "mutant $name ($what): the check FAILS on it, as it must"; else t_fail "mutant $name ($what): the check PASSED on a launcher with that defect"; fi
}
BAD_SYNC="$KEY_UNKNOWN
error: failed to synchronize all databases (unexpected error)"
# in-place clearing (item: the directory can be a mount point)
caught m3 keyring_clear check_unrepairable seed_unrepairable "the directory is renamed aside (mv) as before: EBUSY on a mount point" FAKE_REPAIRABLE=0 <<'FN'
keyring_clear() {
  local g="$1"
  keyring_priv mv "$g" "$g.broken.$(date +%s)" >> "$LOG" 2>&1 || return 1
  keyring_priv mkdir -p "$g"
}
FN
caught m4 keyring_clear check_unrepairable seed_unrepairable "rm -rf of the directory itself, then mkdir" FAKE_REPAIRABLE=0 <<'FN'
keyring_clear() {
  keyring_priv rm -rf "$1" >> "$LOG" 2>&1 && keyring_priv mkdir -p "$1"
}
FN
caught m5 keyring_clear check_unrepairable seed_unrepairable "a glob: dot files, the socket and nothing hidden is removed" FAKE_REPAIRABLE=0 <<'FN'
keyring_clear() {
  rm -rf "$1"/*
  return 0
}
FN
caught m5b keyring_clear check_unrepairable seed_unrepairable "find without -mindepth 1: it removes the directory itself too" FAKE_REPAIRABLE=0 <<'FN'
keyring_clear() {
  keyring_priv find "$1" -maxdepth 1 -exec rm -rf -- {} + >> "$LOG" 2>&1
  keyring_priv mkdir -p "$1"
}
FN
# the retry
caught m6 keyring_sync_retry check_retry_ok seed_gnupg "no retry at all" FAKE_SY_BAD_OUT="$BAD_SYNC" FAKE_SY_BAD_COUNT=1 <<'FN'
keyring_sync_retry() {
  keyring_sync
}
FN
caught m6b keyring_sync_retry check_404 seed_gnupg "every failure is repaired and retried, a 404 too" FAKE_SY_RC=1 FAKE_SY_OUT="$KR404" <<'FN'
keyring_sync_retry() {
  local g="$1"
  keyring_sync && return 0
  keyring_repair "$g" || return 1
  keyring_sync
}
FN
caught m7 keyring_sync_retry check_retry_once seed_gnupg "retried up to three times, not once" FAKE_SY_BAD_OUT="$BAD_SYNC" FAKE_SY_BAD_COUNT=9 <<'FN'
keyring_sync_retry() {
  local g="$1" i=0
  keyring_sync && return 0
  while [ "$KEYS_KIND" = keyring ] && [ "$i" -lt 3 ]; do
    i=$((i + 1))
    keyring_repair "$g" || return 1
    keyring_sync && return 0
  done
  return 1
}
FN
# the classification
caught m8 keys_strip check_404 seed_gnupg "package file names are not stripped: the word keyring in a file name decides" FAKE_SY_RC=1 FAKE_SY_OUT="$KR404" <<'FN'
keys_strip() {
  printf '%s\n' "$1"
}
FN
# the populate before the first sync
caught m9 keyring_prepare check_populate_first seed_gnupg "a working keyring is kept but not populated before the first sync" <<'FN'
keyring_prepare() {
  local g="$1"
  if keyring_missing "$g"; then
    keyring_init || return 1
  elif keyring_usable "$g"; then
    log "the pacman keyring in $g works: keeping it"
  else
    keyring_repair "$g" || return 1
  fi
  return 0
}
FN
DESC="classifier table: a classifier that does not strip package names FAILS the table (the rows that name a keyring package), as it must"
if ! check_table "$W/mut-m8.sh" > /dev/null; then t_pass "$DESC"; else t_fail "$DESC"; fi
DESC="mutant m1 reproduces the reported failure on the model: 'Public keyring not found' in the log and exit 1 after ~the same steps"
if [ -f "$W/r-mutm1/install.log" ] && grep -q "Public keyring not found" "$W/r-mutm1/install.log" && [ "$(cat "$W/r-mutm1/out" 2>/dev/null | grep -c 'FATAL')" -ge 1 ]; then t_pass "$DESC"; else t_fail "$DESC"; fi

echo
printf '== %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
