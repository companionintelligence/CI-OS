#!/usr/bin/env bash
#=============================================================================
# Real-pacman test of the build-time hook ci-os-neutralise-hello.hook (manual; needs Docker, no network)
#
# The first full build shipped cachyos-hello in the application menu although the hook was there: pacman's hook parser consumes
# one level of backslashes inside the double-quoted Exec string, so the sed address '\\[Desktop Entry\\]' never matched and the
# NoDisplay line was never inserted. A text test of the hook cannot see that; only a pacman that runs it can. This test builds a
# fake cachyos-hello package (the two files the hook touches), installs it with the real pacman into a scratch root that has
# the hook, and asserts the effect:
#   - /etc/skel/.config/autostart/cachyos-hello.desktop is gone,
#   - /usr/share/applications/cachyos-hello.desktop has exactly one NoDisplay=true line, directly below [Desktop Entry],
#   - a second run (an Upgrade of the same package) leaves exactly one NoDisplay=true line (idempotent).
# The hook's Depends lines are dropped for the test (the scratch root has no package database to satisfy them); the Exec line is
# the one under test and is not modified.
#
# Usage: backends/cachyos/iso/tests/overlay-hook-pacman.sh [BUILDER_IMAGE]   (default: ci-os-cachyos-builder:<newest tag>)
# Exit: 0 pass, 1 fail, 2 cannot run (no docker / no builder image).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../overlay/files/airootfs/etc/pacman.d/hooks/ci-os-neutralise-hello.hook"
[ -f "$HOOK" ] || { echo "missing $HOOK" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "docker is not installed: this test needs the builder image" >&2; exit 2; }
IMAGE="${1:-}"
if [ -z "$IMAGE" ]; then
  IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^ci-os-cachyos-builder:' | head -n 1 || true)"
fi
[ -n "$IMAGE" ] || { echo "no ci-os-cachyos-builder image: run backends/cachyos/iso/scripts/build-iso.sh once (or --stop-after validate)" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hook-pacman.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
grep -v '^Depends' "$HOOK" > "$TMP/hook"

cat > "$TMP/inner.sh" <<'EOF'
set -eu
ROOT=/tmp/root
mkdir -p /tmp/pkg/usr/share/applications /tmp/pkg/etc/skel/.config/autostart /tmp/cache
printf '[Desktop Entry]\nTerminal=false\nType=Application\nName=CachyOS Hello\nExec=/usr/bin/cachyos-hello\n' > /tmp/pkg/usr/share/applications/cachyos-hello.desktop
printf '[Desktop Entry]\nType=Application\nName=hello autostart\nExec=/usr/bin/cachyos-hello\n' > /tmp/pkg/etc/skel/.config/autostart/cachyos-hello.desktop
cd /tmp/pkg
printf 'pkgname = cachyos-hello\npkgver = 0.28.1-1\npkgdesc = fake\nbuilddate = 1\npackager = test\nsize = 1\narch = any\n' > .PKGINFO
bsdtar -czf /tmp/hello.pkg.tar.gz .PKGINFO usr etc
# a merged-/usr scratch root with bash (as sh), sed, rm and their libraries: the hook runs chrooted in it
mkdir -p $ROOT/var/lib/pacman $ROOT/etc/pacman.d/hooks $ROOT/usr/bin $ROOT/usr/lib
ln -s usr/bin $ROOT/bin; ln -s usr/lib $ROOT/lib; ln -s usr/lib $ROOT/lib64
cp -L /usr/bin/bash $ROOT/usr/bin/bash; ln -s bash $ROOT/usr/bin/sh
cp -L /usr/bin/sed /usr/bin/rm $ROOT/usr/bin/
ldd /usr/bin/bash /usr/bin/sed /usr/bin/rm | grep -o '/[^ ]*\.so[^ ]*' | sort -u | while read -r l; do cp -L "$l" $ROOT/usr/lib/; done
cp /hook.in $ROOT/etc/pacman.d/hooks/ci-os-neutralise-hello.hook
inst() { pacman -r $ROOT --dbpath $ROOT/var/lib/pacman --hookdir $ROOT/etc/pacman.d/hooks --cachedir /tmp/cache \
           -U --noconfirm --nodeps --noscriptlet --disable-sandbox-syscalls /tmp/hello.pkg.tar.gz >/tmp/pacman.out 2>&1 || { cat /tmp/pacman.out; echo "FAIL pacman failed"; exit 0; }; }
D=$ROOT/usr/share/applications/cachyos-hello.desktop
inst
[ ! -e $ROOT/etc/skel/.config/autostart/cachyos-hello.desktop ] && echo "PASS autostart entry removed" || echo "FAIL autostart entry still there"
[ "$(grep -c '^NoDisplay=true$' $D)" = 1 ] && echo "PASS exactly one NoDisplay=true" || { echo "FAIL NoDisplay=true count is $(grep -c '^NoDisplay=true$' $D)"; cat $D; }
[ "$(sed -n 2p $D)" = "NoDisplay=true" ] && echo "PASS NoDisplay=true sits directly below [Desktop Entry]" || echo "FAIL NoDisplay=true is not on line 2"
inst
[ "$(grep -c '^NoDisplay=true$' $D)" = 1 ] && echo "PASS idempotent: still exactly one NoDisplay=true after an upgrade" || echo "FAIL a second run left $(grep -c '^NoDisplay=true$' $D) NoDisplay lines"
EOF

out="$(docker run --rm --platform linux/amd64 -v "$TMP/hook:/hook.in:ro" -v "$TMP/inner.sh:/inner.sh:ro" "$IMAGE" bash /inner.sh 2>&1)" || { echo "$out"; echo "FAIL the container run failed"; exit 1; }
echo "$out"
if printf '%s\n' "$out" | grep -q '^FAIL'; then exit 1; fi
n="$(printf '%s\n' "$out" | grep -c '^PASS' || true)"
[ "$n" -eq 4 ] || { echo "FAIL expected 4 PASS lines, saw $n"; exit 1; }
echo "== Summary: $n passed, 0 failed"
