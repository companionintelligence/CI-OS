#!/usr/bin/env bash
#=============================================================================
# Test: the Companion OS installer and the installed-system provisioning of the CachyOS edition, as far as they can be checked
# without a boot, a build or a network. The one entry point (the others can be run alone):
#
#   installer-config.py     the overlay's YAML and text, against contract.env and the recorded fixtures: parse, no CachyOS
#                           strings or hosts in what the installer shows or contacts, GRUB only, efiBootloaderId, the docker
#                           group, hostname, the install sequence (order of the Companion OS steps), the units that get enabled,
#                           every package name against the recorded archlinux.org / CachyOS repository check, the launcher
#                           .desktop and the cachyos-hello hook, the first-boot units, the installer stylesheet, the time limits of every
#                           shellprocess command (Calamares kills one after 30 s by default: ISO #5 died on it), the install page label
#                           patch, the grubcfg switches that keep the firmware's leftovers out of the installed GRUB menu
#   installer-launcher.sh   the guard library and calamares-online.sh on a fake Calamares tree built from the pinned
#                           installer's recorded shape, its real shellprocess commands and time limits included (critical guards fail
#                           closed, cosmetic ones warn, CI_OS_CALAMARES_ROOT redirects every lookup; the launcher end to end against stubs)
#   installer-stage.sh      stage-installer.sh, stage-headless.sh (the payload PARITY test), the Calamares staging step, the
#                           post-install fix-ups, the first-boot driver, the provisioning wrapper, on fixture directories
#   progress-filter.sh      the filter that keeps terminal redraws (Ollama's progress, colour codes) out of the first-boot log and
#                           the journal: the real recorded stream, a 3000-redraw flood, pass-through, consecutive pulls, the time rule,
#                           garbage input, streaming
#   compat-libs.sh          the compatibility libraries that keep the installer starting on a rolling-release skew (compat-libs.lock,
#                           the stager's checks, the mksquashfs shim, the wiring in 20-build.sh; risk R1, incident 2026-10-18)
#   gate-calamares.sh       the build-time gate that stops mkarchiso when the installer in the assembled image cannot start (every
#                           verdict, on a fake image with recorded ldd and start output). The proof on the real packages is manual:
#                           compat-gate-container.sh (Docker, network)
#
#   backends/cachyos/iso/tests/installer-config.sh
#
# Optional environment: CI_OS_REAL_CALAMARES_ROOT=<unpacked cachyos-calamares-next or ISO root> also runs the guards on the REAL
# installer files. Needs bash 3.2+, python3 (PyYAML for the YAML part, which is skipped without it), git, awk, sed, find, cmp, and bsdtar
# for compat-libs.sh (macOS has it; Debian and Ubuntu: the package libarchive-tools).
# Exit: 1 when any part fails; 2 when python3 is missing, or when no part failed but a part could not run here because a tool it needs
# is missing (that part exits 2 and is named on the last line: it neither passed nor failed); 0 when every part passed.
# No network, no root, no Docker.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1

command -v python3 >/dev/null 2>&1 || { echo "missing tool: python3" >&2; exit 2; }
rc=0
parts=0
passed=0
cannot=""   # the parts that exited 2, each with the first line it printed (the tool it misses)
run() {  # NAME COMMAND...
  local name="$1" prc=0 log; shift
  parts=$((parts + 1))
  echo "######## $name"
  log="$(mktemp "${TMPDIR:-/tmp}/installer-config.XXXXXX")"
  "$@" > "$log" 2>&1 || prc=$?
  cat "$log"
  case "$prc" in
    0) passed=$((passed + 1)) ;;
    2) cannot="${cannot:+$cannot; }$name ($(head -n 1 "$log"))"; echo "######## $name: COULD NOT RUN HERE (exit 2): a tool it needs is missing, so it neither passed nor failed" ;;
    *) rc=1; echo "######## $name: FAILED" ;;
  esac
  rm -f "$log"
  echo
}

run installer-config.py python3 -I "$HERE/installer-config.py"
run installer-launcher.sh bash "$HERE/installer-launcher.sh"
run installer-stage.sh bash "$HERE/installer-stage.sh"
run progress-filter.sh bash "$HERE/progress-filter.sh"
run compat-libs.sh bash "$HERE/compat-libs.sh"
run gate-calamares.sh bash "$HERE/gate-calamares.sh"

if [ "$rc" -ne 0 ]; then
  echo "installer-config.sh: at least one part FAILED"
elif [ -n "$cannot" ]; then
  echo "$passed of $parts parts passed, the rest could not run here: $cannot"
  rc=2
else
  echo "installer-config.sh: all parts passed"
fi
exit "$rc"
