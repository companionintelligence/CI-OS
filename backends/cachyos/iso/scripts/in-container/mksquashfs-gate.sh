#!/usr/bin/env bash
# mksquashfs-gate.sh: installed by 20-build.sh as `mksquashfs` at the FRONT of mkarchiso's PATH (never on the system's).
#
# Stock mkarchiso builds the airootfs in a work directory (packages, then the profile's airootfs/ files, then the clean-up) and as
# its next step runs, by that bare name,
#     mksquashfs <that directory> <image> -noappend ...
# so this program sees the finished tree at the one moment where a check can still stop the build before it is squashed: it runs
# gate-calamares.sh on the directory, and only if that passes does it exec the real mksquashfs with the same arguments. mkarchiso
# itself is not edited (the upstream script that did that, `sudo sed` on /usr/bin/mkarchiso, is what 20-build.sh replaced).
#
# Fail closed: a first argument that is not a directory (airootfs_image_type=ext4+squashfs squashes an .img file) cannot be checked
# and stops the build, with a message that says so. A profile that stops calling mksquashfs (erofs) never reaches this program;
# 20-build.sh notices that by the marker file and fails the build after mkarchiso.
#
# Environment (20-build.sh sets them for the one mkarchiso call): CI_OS_REAL_MKSQUASHFS (the real program), CI_OS_GATE_SCRIPT
# (gate-calamares.sh), CI_OS_GATE_MARKER (written only when the gate passed). CI_OS_COMPAT_LOCK and the gate's own variables pass through.
set -euo pipefail

say() { printf 'mksquashfs-gate: %s\n' "$*" >&2; }
REAL="${CI_OS_REAL_MKSQUASHFS:-}"; GATE="${CI_OS_GATE_SCRIPT:-}"; MARK="${CI_OS_GATE_MARKER:-}"
if [ -z "$REAL" ] || [ ! -x "$REAL" ] || [ -z "$GATE" ] || [ ! -f "$GATE" ] || [ -z "$MARK" ]; then
  say "ERROR: not configured (CI_OS_REAL_MKSQUASHFS, CI_OS_GATE_SCRIPT and CI_OS_GATE_MARKER must name the real mksquashfs, the gate and the marker file). Refusing to squash an unchecked image."
  exit 1
fi
src="${1:-}"
if [ ! -d "$src" ]; then
  say "ERROR: mksquashfs was called with '${src}', which is not a directory (airootfs_image_type changed?). The installer gate cannot inspect it, so the build is stopped instead of shipping an unchecked image."
  exit 1
fi
rm -f "$MARK"
say "checking the assembled airootfs ($src) before it is squashed"
if ! bash "$GATE" "$src"; then
  say "ERROR: the installer gate failed; mksquashfs was NOT run and no image was written."
  exit 1
fi
printf 'passed %s airootfs=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$src" > "$MARK"
exec "$REAL" "$@"
