#!/usr/bin/env bash
#=============================================================================
# Record a VM's screen as numbered-by-time PNG frames, for make-video.py
#
#   record-frames.sh DIR [INTERVAL]      one screendump every INTERVAL seconds (default 2) into DIR/f-<epoch>.png, until DIR/STOP exists
#   touch DIR/STOP                       ends it
#
# It uses the VM harness of boot-arm64-vm.sh (CI_VM_DIR, default /tmp/ci-arm64-vm), so it works for any run that harness started, and it
# keeps going when the VM is off (a screendump then fails and the loop goes on: start it before power-on, stop it when the story is over).
# A frame takes about a second to write, so the real spacing is INTERVAL plus that. Frames can show a one-time password: redact them
# with make-video.py before anything is shared, and keep DIR out of the repository.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u
DIR="${1:?usage: record-frames.sh DIR [INTERVAL]}"
INTERVAL="${2:-2}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$DIR"
rm -f "$DIR/STOP"
while [ ! -e "$DIR/STOP" ]; do
  CI_VM_DIR="${CI_VM_DIR:-/tmp/ci-arm64-vm}" bash "$HERE/boot-arm64-vm.sh" shot "$DIR/f-$(date +%s).png" >/dev/null 2>&1 || rm -f "$DIR/f-$(date +%s).png"
  sleep "$INTERVAL"
done
