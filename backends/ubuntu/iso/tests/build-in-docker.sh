#!/usr/bin/env bash
#=============================================================================
# Test: build-in-docker.sh builds and verifies the ISO in a container, and refuses what must not be built
#
# Runs the real script against a throw-away git repository and a STUB docker (it logs every call and answers like the real one would), so no
# container starts. It checks the command sequence of the happy path (privileged, the host's own platform, the checkout and the base ISO
# mounted read-only, the build and the verify with the arguments CI uses, the copy out, the cleanup), the refusals (a dirty tree, an unpinned base
# ISO, an arm64 image on an x86-64 host, a missing Docker), that an amd64 image on an Apple-silicon Mac is built in the arm64 container (the documented
# Rosetta route), the failures (a build that fails, a verify that fails, a setup step that fails),
# --keep, --no-verify and --dry-run, and that the pins and the package list are the workflow's own.
#
# Pure bash 3.2, no root, no Docker, no network; writes only to a temporary directory.
#   backends/ubuntu/iso/tests/build-in-docker.sh
#
# © Companion Intelligence, Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../scripts/build-in-docker.sh"
WF="$HERE/../../../../.github/workflows/build-companion-os-iso.yml"
[ -f "$TOOL" ] || { echo "missing $TOOL" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is needed" >&2; exit 2; }
command -v tar >/dev/null 2>&1 || { echo "tar is needed" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/build-in-docker.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
has()   { if printf '%s\n' "$OUT" | grep -q -F -- "$2"; then pass "$1"; else fail "$1 (no '$2' in the output)"; fi; }
lacks() { if printf '%s\n' "$OUT" | grep -q -F -- "$2"; then fail "$1 (found '$2')"; else pass "$1"; fi; }
logs()  { if grep -q -F -- "$2" "$STUB_LOG"; then pass "$1"; else fail "$1 (no '$2' in the docker calls)"; fi; }
nolog() { if grep -q -F -- "$2" "$STUB_LOG"; then fail "$1 (found '$2' in the docker calls)"; else pass "$1"; fi; }
rc_is() { if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1 (exit $RC, wanted $2)"; fi; }

# --- a throw-away repository with one commit, and a fake base ISO ------------------------------------------------------------------------
REPO="$WORK/repo"; mkdir -p "$REPO/backends/ubuntu/iso/scripts"
printf '#!/bin/sh\necho build\n' > "$REPO/backends/ubuntu/iso/scripts/build-iso.sh"
printf '#!/bin/sh\necho verify\n' > "$REPO/backends/ubuntu/iso/scripts/verify-iso.sh"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@example.invalid -c user.name=test commit -q -m init
printf 'not an ISO\n' > "$WORK/base.iso"
if command -v sha256sum >/dev/null 2>&1; then BASE_SHA="$(sha256sum "$WORK/base.iso" | cut -d' ' -f1)"; else BASE_SHA="$(shasum -a 256 "$WORK/base.iso" | cut -d' ' -f1)"; fi

# --- stubs: docker (logs, and fails where a scenario says), uname (the host's architecture) -------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
STUB_LOG="$WORK/docker.log"
cat > "$BIN/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$STUB_LOG"
case "$1" in
  info|volume|rm) [ "${STUB_FAIL:-}" = volume ] && [ "$1 $2" = "volume create" ] && { echo "Error: cannot create volume"; exit 1; }; exit 0 ;;
  run) [ "${STUB_FAIL:-}" = run ] && { echo "Error: no such image"; exit 125; }; exit 0 ;;
  exec)
    case "$*" in
      *build-iso.sh*)  [ "${STUB_FAIL:-}" = build ] && { echo "build exploded"; exit 7; }; echo "built"; exit 0 ;;
      *verify-iso.sh*) [ "${STUB_FAIL:-}" = verify ] && { echo "FAIL  something"; echo "== Summary: 3 failed"; exit 1; }; echo "== Summary: 446 passed, 0 failed"; exit 0 ;;
      *apt-get*)       [ "${STUB_FAIL:-}" = deps ] && { echo "E: unable to locate package"; exit 100; }; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  cp)
    dest="$3"; mkdir -p "$dest"
    printf 'iso\n' > "$dest/${STUB_ISO:-companion-os-1.0-arm64.iso}"
    printf 'sums\n' > "$dest/SHA256SUMS"; printf 'sums\n' > "$dest/MD5SUMS"
    exit 0 ;;
esac
exit 0
EOF
cat > "$BIN/uname" <<'EOF'
#!/bin/sh
case "$1" in -m) echo "${STUB_UNAME:-arm64}" ;; *) /usr/bin/uname "$@" ;; esac
EOF
chmod 755 "$BIN/docker" "$BIN/uname"

# run ARGS...: run the tool against the throw-away repository, an output directory of its own, the stubs first on PATH
OUTDIR=""
# the tool makes its temporary checkout under TMPDIR: give it a private one, so that "no checkout is left behind" counts only this test's own runs
# (a real build, or another agent's, running at the same time on the machine has its own and must not make this test fail)
MYTMP="$WORK/tmp"; mkdir -p "$MYTMP"
run() {
  : > "$STUB_LOG"
  OUTDIR="$WORK/out.$((RANDOM))"
  OUT="$(env PATH="$BIN:/usr/bin:/bin" TMPDIR="$MYTMP" STUB_LOG="$STUB_LOG" CI_OS_BASE_ISO_SHA256="$BASE_SHA" "$@" 2>&1)"; RC=$?
}
tool() { run bash "$TOOL" --repo "$REPO" --base-iso "$WORK/base.iso" --output-dir "$OUTDIR_NEXT" "$@"; }
next_out() { OUTDIR_NEXT="$WORK/out.$((RANDOM))"; }

echo "== the happy path: arm64 image on an arm64 host"
next_out; export STUB_UNAME=arm64 STUB_ISO=companion-os-1.0-arm64.iso; unset STUB_FAIL
tool
rc_is "exit 0" 0
has "the commit is named" "from commit"
logs "a work volume is created" "docker volume create ci-os-ubuild-arm64-"
logs "the container is privileged, detached, on the image's own platform" "run -d --name ci-os-ubuild-arm64-"
logs "  platform linux/arm64" "--platform linux/arm64"
logs "  --privileged" "--privileged"
logs "  the base ISO is mounted read-only" "/base/ubuntu-base.iso:ro"
logs "  the checkout is mounted read-only" ":/src:ro"
logs "  the build image is ubuntu:26.04" "ubuntu:26.04 sleep infinity"
logs "loop devices are made" "mknod -m 0660 /dev/loop"
logs "the dependencies are installed" "apt-get install -y -qq ca-certificates squashfs-tools xorriso"
nolog "  and debootstrap is not among them (nothing uses it)" "debootstrap"
logs "the checkout is copied into the volume" "rsync -a --delete /src/ /vol/repo/"
logs "the build runs with the arguments CI uses" "build-iso.sh --arch arm64 --base-iso /base/ubuntu-base.iso --output-dir /vol/out --work-dir /vol/work --version 1.0 --clean"
logs "  with the tool cache" "CI_OS_CACHE_DIR=/vol/cache"
logs "the verify runs with the stock ISO and the canon required" "-e VERIFY_BASE_ISO=/base/ubuntu-base.iso -e VERIFY_REQUIRE_CANON=1"
logs "  on the image the build wrote" "verify-iso.sh /vol/out/companion-os-1.0-arm64.iso"
logs "the image is copied out" "docker cp ci-os-ubuild-arm64-"
logs "the container is removed afterwards" "docker rm -f ci-os-ubuild-arm64-"
logs "the work volume is removed afterwards" "volume rm -f ci-os-ubuild-arm64-"
[ -f "$OUTDIR_NEXT/companion-os-1.0-arm64.iso" ] && pass "the image is in the output directory" || fail "the image is not in the output directory"
[ -f "$OUTDIR_NEXT/SHA256SUMS.arm64" ] && pass "SHA256SUMS.arm64 is written" || fail "SHA256SUMS.arm64 is missing"
grep -q "companion-os-1.0-arm64.iso" "$OUTDIR_NEXT/SHA256SUMS.arm64" 2>/dev/null && pass "  and names the image" || fail "  and does not name the image"
[ -f "$OUTDIR_NEXT/verify-iso-arm64.log" ] && pass "the verify log is kept (as CI names it)" || fail "the verify log is missing"
grep -q "446 passed" "$OUTDIR_NEXT/verify-iso-arm64.log" 2>/dev/null && pass "  with the summary line" || fail "  without the summary line"
[ -f "$OUTDIR_NEXT/build-in-docker-arm64.log" ] && pass "the build log is kept" || fail "the build log is missing"
has "the summary of the verify is shown" "== Summary: 446 passed, 0 failed"
has "the next step is the publisher's dry run" "publish-r2.sh --dir"
has "  for the dev channel" "--channel dev"
LEFT="$(ls -d "$MYTMP"/ci-os-build-tree.* 2>/dev/null | wc -l | tr -d ' ')"
[ "$LEFT" = 0 ] && pass "no temporary checkout is left behind" || fail "$LEFT temporary checkout(s) left in $MYTMP"

echo
echo "== the version and the architecture end up in the names"
next_out; export STUB_UNAME=x86_64 STUB_ISO=companion-os-1.0-rc1-amd64.iso
tool --arch amd64 --version 1.0-rc1
rc_is "exit 0" 0
logs "an amd64 image on an x86-64 host is native" "--platform linux/amd64"
logs "the version reaches the build" "--version 1.0-rc1 --clean"
logs "  and the verify" "verify-iso.sh /vol/out/companion-os-1.0-rc1-amd64.iso"
[ -f "$OUTDIR_NEXT/SHA256SUMS.amd64" ] && pass "SHA256SUMS.amd64 is written" || fail "SHA256SUMS.amd64 is missing"

echo
echo "== a foreign-architecture image: the container is always the host's own platform"
next_out; export STUB_UNAME=arm64 STUB_ISO=companion-os-1.0-amd64.iso
tool --arch amd64
rc_is "an amd64 image on an arm64 host (an Apple-silicon Mac) goes ahead with no flag" 0
logs "  in a container of the HOST's platform, which runs natively" "--platform linux/arm64"
nolog "  and never in an amd64 container (the less predictable route)" "--platform linux/amd64"
logs "  the build asks for the amd64 image" "build-iso.sh --arch amd64"
logs "  and the verify reads that file" "verify-iso.sh /vol/out/companion-os-1.0-amd64.iso"
has "  it says this is the Rosetta route" "Rosetta"
has "  and that a release image comes from an x86-64 host" "A release image comes from an x86-64 host"
[ -f "$OUTDIR_NEXT/SHA256SUMS.amd64" ] && pass "  SHA256SUMS.amd64 is written" || fail "  SHA256SUMS.amd64 is missing"

next_out; export STUB_UNAME=x86_64 STUB_ISO=companion-os-1.0-arm64.iso
tool --arch arm64
rc_is "an arm64 image on an x86-64 host is refused (qemu-user binfmt, never tried)" 3
has "  and the reason is qemu-user" "qemu-user"
nolog "  and no container was started" "docker run"
next_out
tool --arch arm64 --allow-emulated
rc_is "  --allow-emulated goes ahead" 0
logs "  in a container of the host's platform" "--platform linux/amd64"
logs "  building the arm64 image" "build-iso.sh --arch arm64"
has "  and says it is not for the release image" "not for the release image"

echo
echo "== what else it refuses (exit 3, nothing started)"
next_out; export STUB_UNAME=arm64 STUB_ISO=companion-os-1.0-arm64.iso
echo dirty > "$REPO/untracked-file"
tool
rc_is "a dirty working tree is refused" 3
has "  and says a build comes from a commit" "a build comes from a commit"
nolog "  and no container was started" "docker run"
next_out
tool --allow-dirty
rc_is "  --allow-dirty builds the commit anyway" 0
FILES_IN_TREE="$(grep -c 'untracked-file' "$STUB_LOG")"
[ "$FILES_IN_TREE" = 0 ] && pass "  and the untracked file is not part of the checkout" || fail "  the untracked file leaked into a docker call"
rm -f "$REPO/untracked-file"

next_out
run env CI_OS_BASE_ISO_SHA256="$(printf '0%.0s' $(seq 1 64))" bash "$TOOL" --repo "$REPO" --base-iso "$WORK/base.iso" --output-dir "$OUTDIR_NEXT"
rc_is "a base ISO that is not the pinned one is refused" 3
has "  and both hashes are named" "the pinned arm64 ISO is 0000"
nolog "  and no container was started" "docker run"
next_out
run bash "$TOOL" --repo "$REPO" --base-iso "$WORK/base.iso" --output-dir "$OUTDIR_NEXT"
# run() sets CI_OS_BASE_ISO_SHA256 for every call; this one needs it unset to read the real pin
OUT="$(env -u CI_OS_BASE_ISO_SHA256 PATH="$BIN:/usr/bin:/bin" TMPDIR="$MYTMP" STUB_LOG="$STUB_LOG" bash "$TOOL" --repo "$REPO" --base-iso "$WORK/base.iso" --output-dir "$OUTDIR_NEXT" 2>&1)"; RC=$?
rc_is "  with no override the real pin is used, and a fake ISO fails it" 3
has "  and the real arm64 pin is the one named" "c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517"
next_out
tool
has "an override of the pin is announced as porting work" "porting work on an unpinned base ISO"

next_out
run bash "$TOOL" --repo "$REPO" --base-iso "$WORK/none.iso" --output-dir "$OUTDIR_NEXT"
rc_is "a base ISO that does not exist is a usage error" 2

next_out
OUT="$(env PATH="/usr/bin:/bin" TMPDIR="$MYTMP" bash "$TOOL" --repo "$REPO" --base-iso "$WORK/base.iso" --output-dir "$OUTDIR_NEXT" 2>&1)"; RC=$?
if command -v docker >/dev/null 2>&1 && PATH="/usr/bin:/bin" command -v docker >/dev/null 2>&1; then
  pass "(skipped: a real docker is in /usr/bin here)"
else
  rc_is "a missing docker is exit 2" 2
  has "  and says so" "docker is not installed"
fi

next_out
run bash "$TOOL" --repo "$REPO" --base-iso "$WORK/base.iso" --output-dir "$OUTDIR_NEXT" --version "not a version"
rc_is "a version that is not a version is a usage error" 2
run bash "$TOOL" --repo "$REPO" --output-dir "$OUTDIR_NEXT"
rc_is "no --base-iso is a usage error" 2
run bash "$TOOL" --bogus
rc_is "an unknown option is a usage error" 2
run bash "$TOOL" --repo "$REPO" --base-iso "$WORK/base.iso" --output-dir "$OUTDIR_NEXT" --commit no-such-ref
rc_is "a commit that does not exist is a usage error" 2

echo
echo "== failures stop the run, show the log, and clean up"
export STUB_UNAME=arm64 STUB_ISO=companion-os-1.0-arm64.iso
next_out; export STUB_FAIL=build
tool
rc_is "a failing build is exit 1" 1
has "  its output is shown" "build exploded"
has "  and its exit code and the log path are named" "the build failed (exit 7)"
logs "  the container is still removed" "docker rm -f ci-os-ubuild-arm64-"
nolog "  the verify did not run" "verify-iso.sh"
nolog "  nothing was copied out" "docker cp"

next_out; export STUB_FAIL=build STUB_UNAME=arm64 STUB_ISO=companion-os-1.0-amd64.iso
tool --arch amd64
rc_is "a failing cross-architecture build is exit 1" 1
has "  and the hint names the binfmt handler and its error" "Exec format error"
export STUB_UNAME=arm64 STUB_ISO=companion-os-1.0-arm64.iso

next_out; export STUB_FAIL=verify
tool
rc_is "a failing verify is exit 1" 1
has "  its failures are shown" "== Summary: 3 failed"
has "  and it says the image was not copied out" "was NOT copied out"
nolog "  nothing was copied out" "docker cp"

next_out; export STUB_FAIL=deps
tool
rc_is "a failing dependency install is exit 4" 4
has "  with its error" "unable to locate package"
nolog "  the build did not start" "build-iso.sh"

next_out; export STUB_FAIL=run
tool
rc_is "a container that will not start is exit 4" 4
nolog "  nothing was built" "build-iso.sh"
unset STUB_FAIL

echo
echo "== --keep, --no-verify, --dry-run"
next_out
tool --keep
rc_is "--keep still succeeds" 0
nolog "  and leaves the container" "docker rm -f ci-os-ubuild-arm64-"
has "  and names what it left" "left in place (--keep)"

next_out
tool --no-verify
rc_is "--no-verify succeeds" 0
nolog "  and skips verify-iso.sh" "verify-iso.sh"
has "  and says the image is not for publishing" "do not publish this image"

next_out
tool --dry-run
rc_is "--dry-run succeeds" 0
has "  and prints the build command" "build-iso.sh --arch arm64"
has "  and the verify command" "verify-iso.sh"
nolog "  without calling docker at all" "docker "
[ ! -f "$OUTDIR_NEXT/SHA256SUMS.arm64" ] && pass "  and writes no checksum file" || fail "  a dry run wrote SHA256SUMS.arm64"

echo
echo "== the cache volume and the container names"
next_out
tool --cache-volume my-cache
logs "a named cache volume is mounted" "-v my-cache:/vol/cache"
next_out
tool
logs "the default cache volume is per architecture" "-v ci-os-build-cache-arm64:/vol/cache"
a="$(grep -o 'name ci-os-ubuild-arm64-[0-9]*' "$STUB_LOG" | head -1)"
case "$a" in "name ci-os-ubuild-arm64-"[0-9]*) pass "the container name carries the process id, so two builds never share a name" ;; *) fail "the container name is '$a'" ;; esac

echo
echo "== the workflow and the script agree"
if [ -f "$WF" ]; then
  for arch in AMD64 ARM64; do
    wf_pin="$(sed -n "s/^  BASE_ISO_SHA256_$arch: \"\\([0-9a-f]*\\)\"/\\1/p" "$WF")"
    sc_pin="$(sed -n "s/^PIN_$arch=\"\\([0-9a-f]*\\)\".*/\\1/p" "$TOOL")"
    if [ -n "$wf_pin" ] && [ "$wf_pin" = "$sc_pin" ]; then pass "the $arch base ISO pin is the same in the workflow and the script"; else fail "the $arch pin differs: workflow '$wf_pin', script '$sc_pin'"; fi
  done
  wf_deps="$(awk '/apt-get install -y \\$/ {on=1; next} on { gsub(/\\/,""); gsub(/\047/,""); gsub(/^[ \t]+|[ \t]+$/,""); if ($0!="") print $0; if ($0 ~ /file$/) exit }' "$WF" | sort | tr '\n' ' ')"
  sc_deps="$(sed -n 's/^DEPS="\(.*\)"$/\1/p' "$TOOL" | tr ' ' '\n' | sort | tr '\n' ' ')"
  if [ -n "$wf_deps" ] && [ "$wf_deps" = "$sc_deps" ]; then pass "the build dependencies are the same list in the workflow and the script"; else fail "the dependency lists differ: workflow '$wf_deps', script '$sc_deps'"; fi
  grep -q 'ubuntu:26.04' "$WF" && grep -q '^BUILD_IMAGE="ubuntu:26.04"' "$TOOL" && pass "both build in ubuntu:26.04" || fail "the build image differs"
else
  echo "! the workflow is not at $WF: its checks are skipped"
fi

echo
echo "== the script itself"
if bash -n "$TOOL"; then pass "it parses"; else fail "it does not parse"; fi
if [ -x "$TOOL" ]; then pass "it is executable"; else fail "it is not executable"; fi
if grep -q -E '(^|[^a-z])((rm -rf|rm -fr) +(/|~|\$HOME)( |$))' "$TOOL"; then fail "it has an rm -rf of a root or home path"; else pass "it never removes a root or home path"; fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
