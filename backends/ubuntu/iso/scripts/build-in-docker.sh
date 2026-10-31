#!/usr/bin/env bash
#=============================================================================
# build-in-docker.sh: build and verify the Ubuntu edition's ISO in a container on this machine. The CI build job, by hand.
#
#   backends/ubuntu/iso/scripts/build-in-docker.sh --base-iso ~/Downloads/ubuntu-26.04.1-desktop-arm64.iso
#   backends/ubuntu/iso/scripts/build-in-docker.sh --arch amd64 --base-iso ./ubuntu-26.04.1-desktop-amd64.iso --version 1.0-rc1 --output-dir ./out
#
# Why it exists. GitHub-hosted runners are billed and the org gates its workflows to manual runs (docs/CI.md), so the images are built on
# hardware we already own and published from there (publish-r2.sh), or by .github/workflows/build-companion-os-iso.yml when a hosted run is
# wanted. This script is the build half of the first route: the recipe of docs/guides/building-on-a-mac.md, in one command, that every
# step of which the workflow also runs (a test keeps the two in step: the pins, the build image and the package list).
#
# What it does, in order (each step stops the run when it fails):
#   1. refuses to start from a dirty tree (a build comes from a commit), a base ISO whose sha256 is not the pinned one, an arm64 image on an
#      x86-64 host (qemu-user, never tried), a missing Docker;
#   2. takes a clean checkout of the commit with `git archive` (nothing untracked, nothing from your working tree can leak in);
#   3. starts a privileged ubuntu:26.04 container (BUILD_IMAGE, pinned by the digest of its image index) of THIS HOST'S OWN platform, which
#      runs natively and builds an image of either architecture, with loop devices, the build dependencies, the checkout and the base ISO
#      (read-only). An amd64 image on an Apple-silicon Mac is built
#      this way: the image's x86-64 programs run in a chroot through the Docker VM's Rosetta binfmt, the route that built and verified the first
#      amd64 image (772 s; an amd64 container is the less predictable one: docs/guides/building-on-a-mac.md, "Why arm64");
#   4. runs build-iso.sh, then verify-iso.sh with VERIFY_BASE_ISO and VERIFY_REQUIRE_CANON=1, as CI does;
#   5. copies the image, SHA256SUMS, MD5SUMS and the two logs to --output-dir, writes SHA256SUMS.<arch>, removes the container and the volume.
#
# Options:
#   --base-iso FILE        the stock Ubuntu 26.04.1 desktop ISO of the architecture (required); its sha256 must be the pinned one
#   --arch amd64|arm64     the image to build; default: this machine's own architecture
#   --version V            default 1.0
#   --output-dir DIR       default ./output
#   --commit REF           default HEAD
#   --allow-dirty          build the commit even though the working tree has changes (they are NOT in the image)
#   --allow-emulated       build an arm64 image on an x86-64 host, through qemu-user binfmt (never tried, slow; not for the release image).
#                          An amd64 image on an arm64 host does not need it: that is the Rosetta route above
#   --cache-volume NAME    a Docker volume that keeps the downloaded tier B tools between builds (default ci-os-build-cache-<arch>)
#   --no-verify            skip verify-iso.sh (not for an image that will be published)
#   --keep                 leave the container and the work volume in place afterwards, for debugging
#   --repo DIR             build the repository at DIR instead of the one that holds this script
#   -n, --dry-run          print what would run and stop
#   -h, --help
#
# Environment: CI_OS_BASE_ISO_SHA256 replaces the pin, for porting work on a newer stock ISO; the script says so loudly and the image is not a
# supported build (a new stock ISO is a port, not a pin bump: see the comment by BASE_ISO_SHA256_AMD64 in the workflow).
#
# Needs: Docker, git, tar, shasum or sha256sum, and about 40 GiB free where Docker keeps its data (a build uses about 25 GiB; Time Machine local
# snapshots pin freed space on a Mac: `tmutil thinlocalsnapshots / <bytes> 4`).
# Exit status: 0 built and verified, 1 the build or the verify failed, 2 bad usage or a missing tool, 3 refused (dirty tree, wrong base ISO,
# an untried cross-architecture build), 4 the container could not be set up.
#
# © Companion Intelligence, Lifescope Inc
#=============================================================================
set -u

# The stock Ubuntu 26.04.1 desktop ISOs this build starts from. The workflow pins the same two (a test compares them).
PIN_AMD64="601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f"   # releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso
PIN_ARM64="c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517"   # cdimage.ubuntu.com/ubuntu/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso
# The build container's image, pinned by the digest of its OCI image index (amd64 and arm64), so a moved tag cannot change what the build
# starts from. It pins the starting userland only: the container then runs apt-get update against the live archive. The workflow pins the
# same reference (a test compares them); to refresh it: docs/guides/release-checklist.md, "Pinned inputs and how to refresh them".
BUILD_IMAGE="ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c"
# What the build needs inside the container; the workflow's "Install dependencies" step lists the same packages.
DEPS="ca-certificates squashfs-tools xorriso rsync gpg curl cpio zstd initramfs-tools-core imagemagick librsvg2-bin libglib2.0-bin libglib2.0-dev-bin yaru-theme-gnome-shell python3 python3-yaml diffutils mount util-linux file"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"

BASE_ISO=""; ARCH=""; VERSION="1.0"; OUT="./output"; COMMIT="HEAD"; ALLOW_DIRTY=0; ALLOW_EMULATED=0
CACHE_VOL=""; VERIFY=1; KEEP=0; DRY=0

usage() { sed -n '2,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed -e '/^#=\{10,\}$/d' -e 's/^# \{0,1\}//'; }
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m ! %s\033[0m\n' "$*" >&2; }
fail() { local code="$1"; shift; printf '\033[1;31m x %s\033[0m\n' "$*" >&2; exit "$code"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base-iso)       [ $# -ge 2 ] || fail 2 "--base-iso needs a file"; BASE_ISO="$2"; shift 2 ;;
    --arch)           [ $# -ge 2 ] || fail 2 "--arch needs amd64 or arm64"; ARCH="$2"; shift 2 ;;
    --version)        [ $# -ge 2 ] || fail 2 "--version needs a value"; VERSION="$2"; shift 2 ;;
    --output-dir)     [ $# -ge 2 ] || fail 2 "--output-dir needs a directory"; OUT="$2"; shift 2 ;;
    --commit)         [ $# -ge 2 ] || fail 2 "--commit needs a ref"; COMMIT="$2"; shift 2 ;;
    --cache-volume)   [ $# -ge 2 ] || fail 2 "--cache-volume needs a name"; CACHE_VOL="$2"; shift 2 ;;
    --repo)           [ $# -ge 2 ] || fail 2 "--repo needs a directory"; REPO="$(cd "$2" && pwd)" || fail 2 "no such repository: $2"; shift 2 ;;
    --allow-dirty)    ALLOW_DIRTY=1; shift ;;
    --allow-emulated) ALLOW_EMULATED=1; shift ;;
    --no-verify)      VERIFY=0; shift ;;
    --keep)           KEEP=1; shift ;;
    -n|--dry-run)     DRY=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

[ -n "$BASE_ISO" ] || fail 2 "--base-iso is required (the stock Ubuntu 26.04.1 desktop ISO of the architecture)"
echo "$VERSION" | grep -q -E '^[0-9]+(\.[0-9]+)*([-.][0-9A-Za-z]+)*$' || fail 2 "version '$VERSION' is not like 1.0 or 1.0-rc1"

# --- the host ---------------------------------------------------------------------------------------------------------------------------
case "$(uname -m)" in
  arm64|aarch64) HOST_ARCH=arm64 ;;
  x86_64|amd64)  HOST_ARCH=amd64 ;;
  *) HOST_ARCH="$(uname -m)" ;;
esac
[ -n "$ARCH" ] || ARCH="$HOST_ARCH"
case "$ARCH" in amd64|arm64) ;; *) fail 2 "--arch is amd64 or arm64 (this host reads as '$HOST_ARCH')" ;; esac
# The container is always this host's own platform, so it runs natively and builds an image of either architecture. What differs is where the image's
# customisation steps run: for a foreign architecture they run in a chroot of the ISO's root filesystem through the Docker VM's binfmt handlers.
#   amd64 image on an arm64 host (an Apple-silicon Mac): Rosetta. [V] the route that built and verified the amd64 image, 772 s. Allowed.
#   arm64 image on an amd64 host: qemu-user binfmt. Never tried. Needs --allow-emulated.
PLATFORM="linux/$HOST_ARCH"
CROSS=0
if [ "$ARCH" != "$HOST_ARCH" ]; then
  CROSS=1
  if [ "$HOST_ARCH" = arm64 ] && [ "$ARCH" = amd64 ]; then
    warn "an amd64 image on an arm64 host: the container is arm64 and the image's x86-64 programs run through the Docker VM's Rosetta binfmt (the route that built and verified the amd64 image). A release image comes from an x86-64 host"
  elif [ "$ALLOW_EMULATED" != 1 ]; then
    fail 3 "this host is $HOST_ARCH and the image is $ARCH: the chroot would run through qemu-user binfmt, which was never tried here. Build it on an $ARCH host, or pass --allow-emulated for a try that is not the release image (docs/guides/building-on-a-mac.md)"
  else
    warn "an $ARCH image on a $HOST_ARCH host through qemu-user binfmt (--allow-emulated): never tried, not for the release image"
  fi
fi

if [ "$DRY" != 1 ]; then
  command -v docker >/dev/null 2>&1 || fail 2 "docker is not installed (or not on PATH)"
  docker info >/dev/null 2>&1 || fail 2 "docker is installed but not answering: start Docker Desktop (or the daemon) and run this again"
fi
for tool in git tar; do command -v "$tool" >/dev/null 2>&1 || fail 2 "$tool is not installed"; done
if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else fail 2 "neither sha256sum nor shasum is installed"; fi

# --- the base ISO and the commit --------------------------------------------------------------------------------------------------------
[ -f "$BASE_ISO" ] || fail 2 "no such file: $BASE_ISO"
BASE_ISO="$(cd "$(dirname "$BASE_ISO")" && pwd)/$(basename "$BASE_ISO")"
case "$ARCH" in amd64) PIN="$PIN_AMD64" ;; arm64) PIN="$PIN_ARM64" ;; esac
if [ -n "${CI_OS_BASE_ISO_SHA256:-}" ]; then
  PIN="$CI_OS_BASE_ISO_SHA256"
  warn "CI_OS_BASE_ISO_SHA256 replaces the pin: this is porting work on an unpinned base ISO, not a supported build"
fi
have="$(sha256 "$BASE_ISO")"
[ "$have" = "$PIN" ] || fail 3 "the base ISO is $have, the pinned $ARCH ISO is $PIN (the 26.04.1 file, not the 26.04.0 image; docs/architecture/arm64.md for the arm64 one)"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || fail 2 "$REPO is not a git repository"
SHA="$(git -C "$REPO" rev-parse --verify --quiet "$COMMIT^{commit}")" || fail 2 "no such commit: $COMMIT"
if [ "$COMMIT" = HEAD ] && [ "$ALLOW_DIRTY" != 1 ] && [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  fail 3 "the working tree has changes and a build comes from a commit: commit them, or pass --allow-dirty to build $(git -C "$REPO" rev-parse --short HEAD) without them"
fi
[ -n "$CACHE_VOL" ] || CACHE_VOL="ci-os-build-cache-$ARCH"

mkdir -p "$OUT" 2>/dev/null || fail 2 "cannot create $OUT"
OUT="$(cd "$OUT" && pwd)"
# keep room: a build writes about 25 GiB and Docker's data sits on the same disk on a Mac
free_kb="$(df -Pk "$OUT" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "${free_kb:-}" ] && [ "$free_kb" -lt $((40 * 1024 * 1024)) ] 2>/dev/null; then
  warn "only $((free_kb / 1024 / 1024)) GiB free where $OUT is; keep more than 40 GiB free (a full disk wedges Docker; Time Machine snapshots pin freed space)"
fi

SUFFIX="$$"
CNAME="ci-os-ubuild-$ARCH-$SUFFIX"
VOL="ci-os-ubuild-$ARCH-$SUFFIX-vol"
LOG="$OUT/build-in-docker-$ARCH.log"
ISO_NAME="companion-os-$VERSION-$ARCH.iso"

# dk runs docker, or only says what it would run
dk() {
  if [ "$DRY" = 1 ]; then printf '  docker'; printf ' %q' "$@"; printf '\n'; return 0; fi
  docker "$@"
}
# step LABEL CMD...: run a docker step with its output in the log; stop the run with exit code 4 (setup) when it fails
setup_step() {
  local label="$1"; shift
  [ "$DRY" = 1 ] && { dk "$@"; return 0; }
  printf '\n$ docker %s\n' "$*" >> "$LOG"
  docker "$@" >> "$LOG" 2>&1 || { tail -n 25 "$LOG" >&2; fail 4 "$label failed (log: $LOG)"; }
}

TREE=""
cleanup() {
  local rc=$?
  if [ "$DRY" != 1 ]; then
    if [ "$KEEP" = 1 ]; then
      warn "left in place (--keep): container $CNAME, volume $VOL; remove with: docker rm -f $CNAME; docker volume rm $VOL"
    else
      docker rm -f "$CNAME" >/dev/null 2>&1 || true
      docker volume rm -f "$VOL" >/dev/null 2>&1 || true
    fi
  fi
  [ -n "$TREE" ] && rm -rf "$TREE"
  exit "$rc"
}
trap cleanup EXIT

say "Companion OS $VERSION, $ARCH, from commit $(git -C "$REPO" rev-parse --short "$SHA")  ->  $OUT"
: > "$LOG" 2>/dev/null || true

TREE="$(mktemp -d "${TMPDIR:-/tmp}/ci-os-build-tree.XXXXXX")" || fail 2 "cannot make a temporary directory"
say "clean checkout of the commit"
git -C "$REPO" archive "$SHA" | tar -x -C "$TREE" || fail 2 "git archive failed"
echo "  $(find "$TREE" -type f | wc -l | tr -d ' ') files in $TREE"

say "starting the $BUILD_IMAGE container (privileged, platform $PLATFORM)"
setup_step "creating the work volume" volume create "$VOL"
setup_step "starting the container" run -d --name "$CNAME" --privileged --platform "$PLATFORM" \
  -v "$VOL":/vol -v "$CACHE_VOL":/vol/cache -v "$TREE":/src:ro -v "$BASE_ISO":/base/ubuntu-base.iso:ro \
  -w /vol -e DEBIAN_FRONTEND=noninteractive "$BUILD_IMAGE" sleep infinity
# a container's /dev holds only the loop nodes that existed at start, and `mount -o loop` takes the first free one
setup_step "making the loop devices" exec "$CNAME" bash -euc \
  'for i in $(seq 0 127); do [ -e /dev/loop$i ] || mknod -m 0660 /dev/loop$i b 7 $i; done; [ -e /dev/loop-control ] || mknod -m 0660 /dev/loop-control c 10 237; . /etc/os-release; echo "build container: $PRETTY_NAME $(dpkg --print-architecture)"'
say "installing the build dependencies"
setup_step "installing the dependencies" exec "$CNAME" bash -euo pipefail -c "apt-get update -qq && apt-get install -y -qq $DEPS"
setup_step "copying the checkout into the volume" exec "$CNAME" bash -euc 'mkdir -p /vol/repo /vol/work /vol/out && rsync -a --delete /src/ /vol/repo/'

say "building $ISO_NAME (about 10 to 15 minutes natively; the log is $LOG)"
t0="$(date +%s)"
build_rc=0
if [ "$DRY" = 1 ]; then
  dk exec -e CI_OS_CACHE_DIR=/vol/cache -w /vol/repo "$CNAME" ./backends/ubuntu/iso/scripts/build-iso.sh --arch "$ARCH" --base-iso /base/ubuntu-base.iso --output-dir /vol/out --work-dir /vol/work --version "$VERSION" --clean
else
  printf '\n$ build-iso.sh --arch %s --version %s\n' "$ARCH" "$VERSION" >> "$LOG"
  docker exec -e CI_OS_CACHE_DIR=/vol/cache -w /vol/repo "$CNAME" ./backends/ubuntu/iso/scripts/build-iso.sh \
    --arch "$ARCH" --base-iso /base/ubuntu-base.iso --output-dir /vol/out --work-dir /vol/work --version "$VERSION" --clean >> "$LOG" 2>&1 || build_rc=$?
fi
if [ "$build_rc" -ne 0 ]; then
  tail -n 40 "$LOG" >&2
  if [ "$CROSS" = 1 ]; then
    warn "a $ARCH image on a $HOST_ARCH host needs the Docker VM's binfmt handler for $ARCH programs. If the log says 'Exec format error', enable Rosetta (Docker Desktop: Use Rosetta for x86_64/amd64 emulation) or restart Docker Desktop, then run this again"
  fi
  fail 1 "the build failed (exit $build_rc) after $(( $(date +%s) - t0 )) s; the whole log is $LOG"
fi
echo "  built in $(( $(date +%s) - t0 )) s"

if [ "$VERIFY" = 1 ]; then
  say "verifying the image (verify-iso.sh with the stock ISO and the brand canon required)"
  vlog="$OUT/verify-iso-$ARCH.log"
  verify_rc=0
  if [ "$DRY" = 1 ]; then
    dk exec -e VERIFY_BASE_ISO=/base/ubuntu-base.iso -e VERIFY_REQUIRE_CANON=1 -w /vol/repo "$CNAME" ./backends/ubuntu/iso/scripts/verify-iso.sh "/vol/out/$ISO_NAME"
  else
    docker exec -e VERIFY_BASE_ISO=/base/ubuntu-base.iso -e VERIFY_REQUIRE_CANON=1 -w /vol/repo "$CNAME" \
      ./backends/ubuntu/iso/scripts/verify-iso.sh "/vol/out/$ISO_NAME" > "$vlog" 2>&1 || verify_rc=$?
  fi
  if [ "$verify_rc" -ne 0 ]; then
    tail -n 40 "$vlog" >&2
    fail 1 "verify-iso.sh failed (exit $verify_rc); the log is $vlog. The image was NOT copied out: it is in the container's volume only while you --keep it"
  fi
  [ "$DRY" = 1 ] || echo "  $(grep -E '^== Summary' "$vlog" | tail -n 1)"
else
  warn "verify-iso.sh skipped (--no-verify): do not publish this image"
fi

say "copying the image out"
setup_step "copying the image out" cp "$CNAME:/vol/out/." "$OUT/"
if [ "$DRY" != 1 ]; then
  [ -f "$OUT/$ISO_NAME" ] || fail 4 "$ISO_NAME is not in $OUT after the copy"
  ( cd "$OUT" && if command -v sha256sum >/dev/null 2>&1; then sha256sum "$ISO_NAME"; else shasum -a 256 "$ISO_NAME"; fi > "SHA256SUMS.$ARCH" )
  echo
  echo "  $(cat "$OUT/SHA256SUMS.$ARCH")"
  echo "  $(wc -c < "$OUT/$ISO_NAME" | tr -d ' ') bytes, built from commit $(git -C "$REPO" rev-parse --short "$SHA")"
  echo
  echo "Next: publish it (a dry run first; docs/guides/release-checklist.md, \"Publishing to R2\"):"
  echo "  backends/ubuntu/iso/scripts/publish-r2.sh --dir $OUT --version $VERSION --channel dev"
fi
