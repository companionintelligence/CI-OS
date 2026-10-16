#!/usr/bin/env bash
#=============================================================================
# Test (manual, needs docker and the network, about 2 to 4 minutes): does the Companion OS identity survive the CachyOS
# hooks in a REAL pacstrap? It is the check that decision D4 asks the build to make, on a small transaction instead of a
# 3 GB image.
#
#   CACHYOS_UPSTREAM_ARCHISO=<archiso/ of the pinned CachyOS-Live-ISO checkout> backends/cachyos/iso/tests/overlay-pacstrap.sh
#
# In a throw-away privileged builder container it (1) renders the brand assets, (2) merges the overlay onto a copy of the
# upstream profile with the build's own engine (in-container/apply-overlay.sh, guards included), then pacstraps the merged
# airootfs the way mkarchiso does (same pacman.conf shape, HookDir = <root>/etc/pacman.d/hooks, -c -G -M) with the packages
# that matter for identity: filesystem, lsb-release, cachyos-hooks, cachyos-kde-settings and what they need, twice:
#
#   control    the overlay's zz-ci-os-* hooks removed: shows what cachyos-hooks and cachyos-kde-settings leave behind
#              (NAME="CachyOS Linux", org.cachyos.hello as the start button). If the control already looks like Companion OS
#              the test is not measuring anything and fails.
#   overlay    the merged airootfs as it is: the hooks run after the CachyOS ones; then overlay-image-check.sh --live runs
#              on the result (os-release, lsb-release, the real cachyos-kde-settings skeleton, hostname, motd, sshd mask ...)
#
# Needs a builder image with pacman, pacstrap (arch-install-scripts), git and the CachyOS key imported and locally signed
# (iso/docker/Dockerfile.builder, or research's ci-cachyos-builder). Packages come from the live [cachyos], [core] and
# [extra] repositories, so the result moves with them.
#
# Environment
#   CACHYOS_UPSTREAM_ARCHISO   required; also UPSTREAM_ARCHISO_DIR
#   CI_OS_TEST_IMAGE           builder image; default ci-cachyos-builder:latest
#   CI_OS_TEST_PACKAGES        packages to pacstrap; default "filesystem lsb-release cachyos-hooks bash gawk sed coreutils grep cachyos-kde-settings"
#   CI_OS_TEST_CPUS, CI_OS_TEST_MEMORY   docker limits (4, 8g)
#
# Exit status: 0 pass; 1 fail; 2 cannot run here. The repository and the upstream checkout are mounted read-only.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
UP="${CACHYOS_UPSTREAM_ARCHISO:-${UPSTREAM_ARCHISO_DIR:-}}"
IMAGE="${CI_OS_TEST_IMAGE:-ci-cachyos-builder:latest}"
PACKAGES="${CI_OS_TEST_PACKAGES:-filesystem lsb-release cachyos-hooks bash gawk sed coreutils grep cachyos-kde-settings}"

command -v docker >/dev/null 2>&1 || { echo "needs docker" >&2; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "builder image $IMAGE not found (set CI_OS_TEST_IMAGE)" >&2; exit 2; }
[[ -n "$UP" && -f "$UP/profiledef.sh" ]] || { echo "set CACHYOS_UPSTREAM_ARCHISO to the archiso/ directory of the pinned upstream checkout" >&2; exit 2; }
UP="$(cd "$UP" && pwd)"
# the engine reads the pinned commit time from upstream.lock for SOURCE_DATE_EPOCH
EPOCH="$(sed -n 's/^UPSTREAM_COMMIT_EPOCH=//p' "$REPO_ROOT/backends/cachyos/upstream.lock" 2>/dev/null | head -n 1)"
EPOCH="${EPOCH:-1791041490}"

read -r -d '' INNER <<'EOS' || true
set -euo pipefail
PKGS="$CI_PKGS"
say() { printf '\n######## %s\n' "$*"; }
say "tools: librsvg imagemagick plymouth"
pacman -Sy --noconfirm --needed librsvg imagemagick plymouth archlinux-keyring >/tmp/pacman.log 2>&1 || { tail -15 /tmp/pacman.log; exit 1; }
git config --global --add safe.directory '*'

say "render-assets.sh"
CI_OS_STAGING_DIR=/stage CI_OS_REPO_ROOT=/repo CI_OS_VERSION=2026.10 CI_OS_BUILD_DAY=20261015 bash /repo/backends/cachyos/iso/scripts/render-assets.sh 2>&1 | tail -2

say "apply-overlay.sh (the build's own engine, guards included)"
UPSTREAM_ARCHISO_DIR=/up OVERLAY_DIR=/repo/backends/cachyos/iso/overlay WORK_ARCHISO_DIR=/profile CI_OS_STAGING_DIR=/stage SOURCE_DATE_EPOCH="$CI_EPOCH" \
  bash /repo/backends/cachyos/iso/scripts/in-container/apply-overlay.sh 2>&1 | tail -3 | cut -c1-200

pacstrap_into() { # pacstrap_into <root> <label>
  local rt="$1"
  pacman-conf --config /profile/pacman.conf | sed "/CacheDir/d;/DBPath/d;/HookDir/d;/LogFile/d;/RootDir/d;/\[options\]/a CacheDir = /var/cache/pacman/pkg
/\[options\]/a HookDir = ${rt}/etc/pacman.d/hooks/" > "/tmp/$2.pacman.conf"
  # shellcheck disable=SC2086
  pacstrap -C "/tmp/$2.pacman.conf" -c -G -M "$rt" $PKGS > "/tmp/pacstrap-$2.log" 2>&1 || { tail -30 "/tmp/pacstrap-$2.log"; exit 1; }
}

say "CONTROL: the overlay without its zz-ci-os-* hooks (what the CachyOS packages leave behind)"
mkdir -p /rt-control && cp -a /profile/airootfs/. /rt-control/
rm -f /rt-control/usr/share/libalpm/hooks/zz-ci-os-* /rt-control/usr/share/libalpm/scripts/zz-ci-os-*
pacstrap_into /rt-control control
grep -E '^(NAME|PRETTY_NAME|ID|ID_LIKE|LOGO)=' /rt-control/etc/os-release | sed 's/^/  os-release: /'
grep -E '^icon=' /rt-control/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc | sed 's/^/  start button: /'
control_ok=1
grep -qx 'NAME="CachyOS Linux"' /rt-control/etc/os-release || control_ok=0
grep -qx 'icon=org.cachyos.hello' /rt-control/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc || control_ok=0
if [ "$control_ok" -eq 1 ]; then echo "PASS  control: without our hooks the image would say CachyOS Linux and point the start button at org.cachyos.hello"; else echo "FAIL  control: the CachyOS packages did not leave their identity behind, so this test measures nothing"; fi

say "OVERLAY: the merged airootfs as built"
mkdir -p /rt-overlay && cp -a /profile/airootfs/. /rt-overlay/
pacstrap_into /rt-overlay overlay
echo "hook order in the pacstrap log:"; grep -nE 'Updating CachyOS|Add CachyOS|Companion OS' /tmp/pacstrap-overlay.log | sed 's/^/  /'
overlay_rc=0
bash /repo/backends/cachyos/iso/tests/overlay-image-check.sh --live /rt-overlay || overlay_rc=$?
[ "$control_ok" -eq 1 ] && [ "$overlay_rc" -eq 0 ]
EOS

echo "image $IMAGE, upstream $UP, packages: $PACKAGES"
docker run --rm --platform linux/amd64 --cap-add SYS_ADMIN --cpus "${CI_OS_TEST_CPUS:-4}" --memory "${CI_OS_TEST_MEMORY:-8g}" \
  -v "$REPO_ROOT:/repo:ro" -v "$UP:/up:ro" -e "CI_PKGS=$PACKAGES" -e "CI_EPOCH=$EPOCH" "$IMAGE" bash -c "$INNER"
