#!/usr/bin/env bash
#=============================================================================
# Test: the Companion OS installer and the installed-system provisioning of the CachyOS edition, as far as they can be checked
# without a boot, a build or a network. The one entry point (the others can be run alone):
#
#   installer-config.py     the overlay's YAML and text, against contract.env and the recorded fixtures: parse, no CachyOS
#                           strings or hosts in what the installer shows or contacts, GRUB only, efiBootloaderId, the docker
#                           group, hostname, the install sequence (order of the Companion OS steps), the units that get enabled,
#                           every package name against the recorded archlinux.org / CachyOS repository check, the launcher
#                           .desktop and the cachyos-hello hook, the first-boot units
#   installer-launcher.sh   the guard library and calamares-online.sh on a fake Calamares tree built from the pinned
#                           installer's recorded shape (critical guards fail closed, cosmetic ones warn, CI_OS_CALAMARES_ROOT
#                           redirects every lookup; the launcher end to end against stubs)
#   installer-stage.sh      stage-installer.sh, stage-headless.sh (the payload PARITY test), the Calamares staging step, the
#                           post-install fix-ups, the first-boot driver, the provisioning wrapper, on fixture directories
#   compat-libs.sh          the compatibility libraries that keep the installer starting on a rolling-release skew (compat-libs.lock,
#                           the stager's checks, the mksquashfs shim, the wiring in 20-build.sh; risk R1, incident 2026-10-18)
#   gate-calamares.sh       the build-time gate that stops mkarchiso when the installer in the assembled image cannot start (every
#                           verdict, on a fake image with recorded ldd and start output). The proof on the real packages is manual:
#                           compat-gate-container.sh (Docker, network)
#
#   backends/cachyos/iso/tests/installer-config.sh
#
# Optional environment: CI_OS_REAL_CALAMARES_ROOT=<unpacked cachyos-calamares-next or ISO root> also runs the guards on the REAL
# installer files. Needs bash 3.2+, python3 (PyYAML for the YAML part, which is skipped without it), git, awk, sed, find, cmp.
# Exit: non-zero when any part fails; 2 when a tool is missing. No network, no root, no Docker.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1

command -v python3 >/dev/null 2>&1 || { echo "missing tool: python3" >&2; exit 2; }
rc=0
run() {  # NAME COMMAND...
  local name="$1"; shift
  echo "######## $name"
  if "$@"; then :; else rc=1; echo "######## $name: FAILED"; fi
  echo
}

run installer-config.py python3 -I "$HERE/installer-config.py"
run installer-launcher.sh bash "$HERE/installer-launcher.sh"
run installer-stage.sh bash "$HERE/installer-stage.sh"
run compat-libs.sh bash "$HERE/compat-libs.sh"
run gate-calamares.sh bash "$HERE/gate-calamares.sh"

if [ "$rc" -eq 0 ]; then echo "installer-config.sh: all parts passed"; else echo "installer-config.sh: at least one part FAILED"; fi
exit "$rc"
