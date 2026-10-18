#!/usr/bin/env bash
#=============================================================================
# Manual test (Docker and network, about 10 minutes on Apple silicon under Rosetta, 4 GB of disk): the installer gate on the REAL
# packages. It reproduces incident 2026-10-18 (F2) and proves that the next rolling-release skew fails the build, not the person who
# clicks "Install Companion OS". Not part of check-repo.sh (it downloads about 1.5 GB); the offline tests of the same code are
# compat-libs.sh and gate-calamares.sh.
#
#   1  a throw-away privileged amd64 container from the builder image; 10-bootstrap.sh ([cachyos] repo and key)
#   2  F2 reproduced: pacstrap of cachyos-calamares-next into a scratch root; `ldd` says libboost_python314.so.1.91.0 => not found;
#      the offscreen start exits 127 "error while loading shared libraries"
#   3  the gate on that root, three times:
#        A  nothing staged (what CI_OS_COMPAT_LIBS=off does)           must FAIL, name the library and compat-libs.lock
#        B  the library as a SYMLINK to the 1.92 file (the by-hand      must FAIL on the undefined symbol boost::python::detail::
#           attempt of the capture)                                      init_module, from ldd -r and from the offscreen start
#        C  the real stager (Archive, sha256, signature) then the gate  must PASS (the installer stays up for the whole start) and
#                                                                         leave the image byte-for-byte as it was
#   4  stock mkarchiso on a minimal profile (base, pacman, linux, mkinitcpio-archiso, syslinux, cachyos-calamares-next; squashfs) with the
#      shim first on PATH exactly as 20-build.sh does it:
#        D  no compat libraries            mkarchiso must FAIL, the gate's message must be in its output, NO airootfs.sfs, no marker
#        E  the libraries from the stager  mkarchiso must SUCCEED, airootfs.sfs exists, the marker is there
#   --skip-mkarchiso stops after 3.
#
#   backends/cachyos/iso/tests/compat-gate-container.sh [--keep] [--skip-mkarchiso]
#
# Environment: CI_OS_TEST_CONTAINER (default ci-os-cachyos-compat-test; the script refuses to touch a container of that name that it did
# not create), CI_OS_TEST_IMAGE (default: the newest ci-os-cachyos-builder tag; build-iso.sh builds it). The repository is mounted
# read-only; nothing is installed on the host. The container is removed at the end unless --keep. Exit: non-zero when a check fails, 2
# when it cannot run (no Docker, no builder image).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
CT="${CI_OS_TEST_CONTAINER:-ci-os-cachyos-compat-test}"
LABEL=ci-os.cachyos.test=compat-gate
KEEP=0; SKIP_MK=0
for a in "$@"; do
  case "$a" in
    --keep) KEEP=1 ;;
    --skip-mkarchiso) SKIP_MK=1 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "Docker is not available" >&2; exit 2; }
IMAGE="${CI_OS_TEST_IMAGE:-$(docker images --format '{{.Repository}}:{{.Tag}}' ci-os-cachyos-builder | head -n 1)}"
[ -n "$IMAGE" ] || { echo "no ci-os-cachyos-builder image: run backends/cachyos/iso/scripts/build-iso.sh --stop-after validate once" >&2; exit 2; }
[ "$(docker image inspect -f '{{.Architecture}}' "$IMAGE")" = amd64 ] || { echo "$IMAGE is not amd64" >&2; exit 2; }
if docker inspect "$CT" >/dev/null 2>&1; then
  [ "$(docker inspect -f '{{index .Config.Labels "ci-os.cachyos.test"}}' "$CT")" = compat-gate ] || { echo "a container named $CT exists and was not created by this test; refusing to touch it (set CI_OS_TEST_CONTAINER)" >&2; exit 2; }
  docker rm -f -v "$CT" >/dev/null
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/compat-gate-container.XXXXXX")"
cleanup() {
  rm -rf "$W"
  if [ "$KEEP" -eq 1 ]; then echo "kept container $CT (docker rm -f -v $CT)"; else docker rm -f -v "$CT" >/dev/null 2>&1; fi
}
trap cleanup EXIT

SCR=/repo/backends/cachyos/iso/scripts/in-container
ex() { docker exec "$CT" "$@"; }
exb() { docker exec "$CT" bash -c "$1"; }

echo "== 1: container $CT from $IMAGE, [cachyos] repo and key"
docker run -d --name "$CT" --label "$LABEL" --platform linux/amd64 --privileged --cpus 4 --memory 8g -v "$REPO:/repo:ro" "$IMAGE" sleep infinity >/dev/null || { echo "cannot start the container" >&2; exit 2; }
if ex bash "$SCR/10-bootstrap.sh" > $W/bootstrap 2>&1; then t_pass "10-bootstrap.sh: ready ($(tail -n 1 $W/bootstrap | cut -c1-100))"; else tail -n 15 $W/bootstrap; t_fail "10-bootstrap.sh failed"; exit 1; fi

echo "== 2: F2 reproduced on the real packages"
exb 'pacman -Si cachyos-calamares-next | grep -E "^(Version|Build Date)"; pacman -Si boost-libs | grep -E "^(Version|Build Date)"' | sed 's/^/      /'
ex bash -c 'mkdir -p /scratch/root && pacstrap -c -K /scratch/root bash coreutils cachyos-calamares-next > /scratch/pacstrap.log 2>&1' && t_pass "pacstrap of cachyos-calamares-next into /scratch/root" || { t_fail "pacstrap failed"; exb 'tail -n 20 /scratch/pacstrap.log'; exit 1; }
out="$(exb 'chroot /scratch/root /usr/bin/ldd /usr/bin/calamares 2>&1 | grep "not found"')"
if printf '%s' "$out" | grep -q 'libboost_python314.so.1.91.0 => not found'; then t_pass "F2 first failure: ldd says libboost_python314.so.1.91.0 => not found"; else t_fail "F2 not reproduced: the installer resolves its libraries (did [cachyos] rebuild it? then the gate has nothing to catch today: $out)"; fi
out="$(exb 'arch-chroot /scratch/root env QT_QPA_PLATFORM=offscreen /usr/bin/bash -c "exec /usr/bin/timeout -k 5 20 /usr/bin/calamares -D6" 2>&1 | grep -v "not a mountpoint" | head -n 3; true')"
if printf '%s' "$out" | grep -q 'error while loading shared libraries: libboost_python314.so.1.91.0'; then t_pass "F2 first failure: the start exits with 'error while loading shared libraries: libboost_python314.so.1.91.0'"; else t_fail "start: $out"; fi

echo "== 3: the gate on that root (A: nothing staged, B: symlink to 1.92, C: the real stager)"
GATE="bash $SCR/gate-calamares.sh /scratch/root"
exb "$GATE" > $W/A 2>&1; rc=$?
if [ "$rc" = 1 ] && grep -q 'missing library libboost_python314.so.1.91.0' $W/A && grep -q 'IS listed in backends/cachyos/compat-libs.lock' $W/A && grep -q 'THE CALAMARES GATE FAILED' $W/A; then
  t_pass "A: nothing staged: the gate FAILS (exit 1), names the library and the lock"
else t_fail "A: exit $rc"; tail -n 12 $W/A; fi
grep -E 'ERROR|^    - ' $W/A | cut -c1-260 | sed 's/^/      /'
exb 'ln -s libboost_python314.so.1.92.0 /scratch/root/usr/lib/libboost_python314.so.1.91.0'
exb "$GATE" > $W/B 2>&1; rc=$?
exb 'rm -f /scratch/root/usr/lib/libboost_python314.so.1.91.0'
if [ "$rc" = 1 ] && grep -q 'init_module' $W/B && grep -q 'symbol lookup error' $W/B; then
  t_pass "B: the symlink to 1.92: the gate FAILS on boost::python::detail::init_module, from ldd -r and from the start (F2's second failure)"
else t_fail "B: exit $rc"; tail -n 12 $W/B; fi
grep -E '^    - ' $W/B | cut -c1-300 | sed 's/^/      /'
exb 'rm -rf /scratch/stg && mkdir -p /scratch/stg && CI_OS_STAGING_DIR=/scratch/stg bash '"$SCR"'/stage-compat-libs.sh stage' > $W/C0 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q 'signature verified with the pacman keyring' $W/C0 && grep -q 'sha256 matches the pin' $W/C0; then t_pass "C: the stager fetched boost-libs 1.91 from the Archive, matched the pinned sha256 and verified the signature"; else t_fail "C: stager exit $rc"; tail -n 8 $W/C0; fi
exb 'cp -a /scratch/stg/airootfs/. /scratch/root/ && touch /scratch/marker'
exb "$GATE" > $W/C 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q 'still running after 20 s: the installer starts' $W/C; then t_pass "C: with the pinned libraries the gate PASSES: 24 ELF files resolve, Calamares stays up for the whole start"; else t_fail "C: exit $rc"; tail -n 12 $W/C; fi
changed="$(exb 'find /scratch/root -xdev -newer /scratch/marker 2>/dev/null | head -n 5')"
if [ -z "$changed" ]; then t_pass "C: the gate left the image untouched (nothing newer than the marker taken before it ran)"; else t_fail "C: the gate changed the image: $changed"; fi
left="$(exb 'ps -eo args | grep -E "[c]alamares -D" | grep -v defunct | head -n 2')"
if [ -z "$left" ]; then t_pass "C: no Calamares process is left running"; else t_fail "C: leftover process: $left"; fi

if [ "$SKIP_MK" -eq 0 ]; then
  echo "== 4: stock mkarchiso, shim first on PATH (minimal profile; D without the libraries, E with them)"
  exb 'set -e
    rm -rf /scratch/mini && mkdir -p /scratch/mini && cp -a /usr/share/archiso/configs/baseline /scratch/mini/profile
    cd /scratch/mini/profile && cp /etc/pacman.conf pacman.conf && cp /etc/pacman.conf airootfs/etc/pacman.conf && mkdir -p airootfs/etc/pacman.d && cp /etc/pacman.d/mirrorlist airootfs/etc/pacman.d/mirrorlist   # mkarchiso reads both from the image
    printf "base\npacman\nlinux\nmkinitcpio\nmkinitcpio-archiso\nsyslinux\ncachyos-calamares-next\n" > packages.x86_64
    sed -i "s/^iso_name=.*/iso_name=\"compat-gate-mini\"/; s/^airootfs_image_type=.*/airootfs_image_type=\"squashfs\"/; s/^airootfs_image_tool_options=.*/airootfs_image_tool_options=(\"-comp\" \"zstd\" \"-Xcompression-level\" \"1\")/; /^bootmodes=/,/uefi.grub/c\\bootmodes=(\"bios.syslinux\")" profiledef.sh
    mkdir -p /scratch/mini/gate-bin && install -m 0755 '"$SCR"'/mksquashfs-gate.sh /scratch/mini/gate-bin/mksquashfs'
  mk() { # NAME: one stock mkarchiso run with the environment 20-build.sh gives it
    exb 'REAL=$(command -v mksquashfs); rm -rf /scratch/mini/work-'"$1"' /scratch/mini/out-'"$1"' /scratch/mini/'"$1"'.marker
      CI_OS_REAL_MKSQUASHFS=$REAL CI_OS_GATE_SCRIPT='"$SCR"'/gate-calamares.sh CI_OS_GATE_MARKER=/scratch/mini/'"$1"'.marker CI_OS_COMPAT_LOCK=/repo/backends/cachyos/compat-libs.lock CI_OS_GATE_SMOKE_SECONDS=10 \
        PATH=/scratch/mini/gate-bin:$PATH mkarchiso -v -w /scratch/mini/work-'"$1"' -o /scratch/mini/out-'"$1"' /scratch/mini/profile > /scratch/mini/'"$1"'.log 2>&1; echo $?'
  }
  rc="$(mk D)"
  exb 'grep -E "^mksquashfs-gate|THE CALAMARES GATE FAILED|^    - " /scratch/mini/D.log | cut -c1-240' | sed 's/^/      /'
  if [ "$rc" != 0 ] && exb 'grep -q "THE CALAMARES GATE FAILED" /scratch/mini/D.log' && ! exb 'test -e /scratch/mini/work-D/iso/arch/x86_64/airootfs.sfs' && ! exb 'test -e /scratch/mini/D.marker' && ! exb 'ls /scratch/mini/out-D/*.iso' >/dev/null 2>&1; then
    t_pass "D: stock mkarchiso with no compat libraries FAILS (exit $rc) at the squash step, with the gate's message; no airootfs.sfs, no marker, no ISO"
  else t_fail "D: mkarchiso exit $rc"; exb 'tail -n 15 /scratch/mini/D.log'; fi
  # E: the same profile with the libraries staged the way the build does it (profile airootfs, copied BEFORE the packages)
  exb 'mkdir -p /scratch/mini/stg && rm -rf /scratch/mini/stg/* && CI_OS_STAGING_DIR=/scratch/mini/stg bash '"$SCR"'/stage-compat-libs.sh stage >/dev/null 2>&1 && cp -a /scratch/mini/stg/airootfs/. /scratch/mini/profile/airootfs/ && ls /scratch/mini/profile/airootfs/usr/lib'
  rc="$(mk E)"
  exb 'grep -E "^mksquashfs-gate|^gate-calamares: passed|Image file|Done! Squash" /scratch/mini/E.log | cut -c1-240; ls -l /scratch/mini/work-E/iso/arch/x86_64/airootfs.sfs /scratch/mini/out-E 2>&1 | tail -n 3' | sed 's/^/      /'
  if [ "$rc" = 0 ] && exb 'test -s /scratch/mini/work-E/iso/arch/x86_64/airootfs.sfs' && exb 'grep -q "^passed " /scratch/mini/E.marker' && exb 'ls /scratch/mini/out-E/*.iso' >/dev/null 2>&1; then
    t_pass "E: with the pinned libraries in the profile mkarchiso SUCCEEDS: the gate passed inside it, airootfs.sfs and the ISO were written, the marker is there"
  else t_fail "E: mkarchiso exit $rc"; exb 'tail -n 15 /scratch/mini/E.log'; fi
  # what the squashed image holds: the libraries, with the pinned hashes
  exb 'unsquashfs -ll /scratch/mini/work-E/iso/arch/x86_64/airootfs.sfs 2>/dev/null | grep -E "libboost_(python314|container|graph).so.1.91.0$"' | sed 's/^/      /'
fi

echo
printf '== %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
