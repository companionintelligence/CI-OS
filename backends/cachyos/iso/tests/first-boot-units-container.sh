#!/usr/bin/env bash
#=============================================================================
# Manual test (Docker, no network): systemd reads the first-boot service and its retry timer without a complaint.
#
# `systemd-analyze verify` loads the two unit files the way the manager would and prints every directive it does not know, every value
# it cannot parse and every dependency name it cannot resolve. It does NOT start anything and it does NOT compute the boot order, so it
# cannot see the ISO #4 defect (a oneshot linked into multi-user.target delaying graphical.target); the shape is checked by the text tests
# (installer-config.py, verify-iso.sh) and rests on systemd.target(5). What this adds is the parse: a typo in a directive is otherwise
# found on the first boot of an installed system.
#
# systemd is NEVER run as PID 1 here (that wiped the Docker VM's Rosetta registration once): only the analyzer, in a plain container.
#
#   backends/cachyos/iso/tests/first-boot-units-container.sh [--image IMAGE]
#       --image IMAGE   the builder image (default: the newest ci-os-cachyos-builder:*)
#   CI_OS_UNITS_NAME=name   name the container, so that it can be found and removed
#
# Under Rosetta (Apple silicon) systemd 262 reports "Command ... is not executable: Invalid argument" for EVERY command, /usr/bin/true
# included (an emulation artefact: installer/README.md, "What is not tested"); that one line is ignored, anything else fails the test.
# Exit: 0 clean, 1 the analyzer said something, 2 cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
die() { echo "first-boot-units-container: $*" >&2; exit 2; }

if [ "${CI_OS_UNITS_INSIDE:-}" != 1 ]; then
  IMAGE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --image) [ $# -ge 2 ] || die "--image needs a value"; IMAGE="$2"; shift 2 ;;
      -h|--help) sed -n '2,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  command -v docker >/dev/null 2>&1 || die "docker not found"
  docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"
  if [ -z "$IMAGE" ]; then
    IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' ci-os-cachyos-builder 2>/dev/null | head -n 1)"
    [ -n "$IMAGE" ] || die "no ci-os-cachyos-builder image: run backends/cachyos/iso/scripts/build-iso.sh once, or pass --image"
  fi
  args=(run --rm --platform linux/amd64 -v "$REPO_ROOT:/repo:ro" -e CI_OS_UNITS_INSIDE=1)
  [ -z "${CI_OS_UNITS_NAME:-}" ] || args+=(--name "$CI_OS_UNITS_NAME")
  exec docker "${args[@]}" "$IMAGE" bash /repo/backends/cachyos/iso/tests/first-boot-units-container.sh
fi

#=== container part ===========================================================================================================
command -v systemd-analyze >/dev/null 2>&1 || die "no systemd-analyze in this image"
U=/tmp/units; rm -rf "$U"; mkdir -p "$U" /usr/lib/ci-os
printf '#!/bin/bash\nexit 0\n' > /usr/lib/ci-os/first-boot-setup.sh; chmod 755 /usr/lib/ci-os/first-boot-setup.sh
cp /repo/backends/cachyos/provision/systemd/ci-os-first-boot-setup.service /repo/backends/cachyos/provision/systemd/ci-os-first-boot-setup.timer "$U/"
echo "systemd: $(systemd-analyze --version | head -n 1)"
out="$(systemd-analyze verify "$U/ci-os-first-boot-setup.service" "$U/ci-os-first-boot-setup.timer" 2>&1)" || true
problems="$(printf '%s\n' "$out" | grep -v -e 'system-environment-generators/10-arch' -e 'is not executable: Invalid argument' | sed '/^$/d')"
printf '%s\n' "$out" | sed 's/^/  analyzer: /'
# Control: the analyzer can fail. A unit with an unknown directive and a missing binary must produce lines this test would not ignore.
printf '[Service]\nType=exec\nExecStart=/usr/lib/ci-os/nope.sh\nBogusKey=1\n' > "$U/control.service"
ctl="$(systemd-analyze verify "$U/control.service" 2>&1 | grep -v -e 'system-environment-generators/10-arch' -e 'is not executable: Invalid argument' | sed '/^$/d')"
if [ -n "$ctl" ]; then echo "PASS  the analyzer can fail (control unit: $(printf '%s' "$ctl" | head -n 1))"; else echo "FAIL  the control unit produced nothing: this test could not see a typo"; exit 1; fi
if [ -z "$problems" ]; then echo "PASS  systemd-analyze verify reads ci-os-first-boot-setup.service and .timer without a complaint"; else echo "FAIL  the analyzer said:"; printf '%s\n' "$problems" | sed 's/^/      /'; exit 1; fi
