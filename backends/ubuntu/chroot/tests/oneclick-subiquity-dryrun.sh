#!/usr/bin/env bash
#=============================================================================
# Manual test: the one-click installer helper against the REAL installer server (subiquity, dry-run mode)
#
# ci-os-auto-install writes an autoinstall file, restarts the installer's server, waits for NEEDS_CONFIRMATION, confirms with
# `POST /meta/confirm` and follows the install. Its unit tests (test_auto_install.py) model the server; this test is the other
# end: the server's own code, taken from the snap on a STOCK Ubuntu 26.04.1 ISO (ubuntu-desktop-bootstrap, rev 665), run with
# `python -m subiquity.cmd.server --dry-run`: the real state machine, the real autoinstall loading, the real HTTP API, a
# simulated machine (examples/machines/simple.json: one 100 GiB disk /dev/sda) and a replayed curtin run. Nothing is installed.
#
# WHAT IT SHOWS (the failure it was written for is in docs/architecture/one-click-install.md, "What went wrong on the first real run")
#
#   protocol  curl against the server with the document that ci-os-auto-install builds:
#             1. the server reaches NEEDS_CONFIRMATION by itself (WAITING -> NEEDS_CONFIRMATION, interactive=false)
#             2. the OLD confirm request, the tty as a JSON body, is answered HTTP 500 `missing required argument "tty"`
#                (the tty is a QUERY argument of the API; the server's state does not change)
#             3. what the old helper did next (drop its file, restart the idle server) leaves a stock server in WAITING with
#                interactive=true for ever: the stuck state seen in the VM run
#             4. the NEW request, ?tty=%22%2Fdev%2Ftty1%22 with no body, is answered 200; then RUNNING -> UU_RUNNING -> DONE,
#                `shutdown: poweroff` is honoured (mode=POWEROFF), the late-commands run
#   helper    run_install() of ci-os-auto-install itself, with only its surroundings replaced (sudo, systemctl, zenity, the disk
#             list): the OLD copy (optional) fails with HTTP 500 exactly as in the VM; the NEW copy installs to DONE, says at once
#             and clearly when the server did not read its file, and reports a failed target check with the server's state
#
# HOW IT WAS RUN (2026-10-18, macOS 27.0.1 with its bash 3.2.57, Docker Desktop 29.8.2 / linuxkit 7.0.14 on Apple silicon)
#
#   CI_OS_DRYRUN_OLD_HELPER=/path/to/helper-before-the-fix \
#     bash backends/ubuntu/chroot/tests/oneclick-subiquity-dryrun.sh
#
#   The old helper is `git show <commit before the fix>:backends/ubuntu/chroot/payload/live-start/usr/libexec/ci-os/ci-os-auto-install`.
#   Without CI_OS_DRYRUN_OLD_HELPER the old-helper checks are left out; everything else runs.
#
#   Environment (all optional):
#     CI_OS_DRYRUN_ISO          the stock ISO     (default ~/.cache/ci-stick-test/iso/ubuntu-26.04.1-desktop-amd64.iso)
#     CI_OS_DRYRUN_OLD_HELPER   a copy of the helper from before the fix
#     CI_OS_DRYRUN_OUT          where the evidence goes (default: a new directory under ${TMPDIR:-/tmp})
#     CI_OS_DRYRUN_CONTAINER    container name    (default ci-os-oneclick-1; use ci-os-oneclick-<n>)
#     CI_OS_DRYRUN_IMAGE        container image   (default ubuntu:26.04, run as linux/arm64 like the other container tests)
#     CI_OS_DRYRUN_STAGE        protocol | helper | all (default all)
#
#   What it does on the host: one `docker run --rm --init --platform linux/arm64` of this very script (`--inside`) with the ISO, this
#   repository and the output directory mounted. NOT privileged and no mounts inside: the snap is unpacked with unsquashfs, so
#   nothing here can touch the Docker VM's kernel (binfmt_misc, sysctl). Inside, as root of a throw-away ubuntu:26.04:
#     1. apt-get install python3 + the installer's Python dependencies, squashfs-tools, libarchive-tools (bsdtar), curl, procps ...
#     2. bsdtar casper/minimal.standard.live.squashfs and casper/install-sources.yaml out of the ISO; unsquashfs the snap
#        var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_<rev>.snap out of the layer, then its meta, bin/subiquity, bin/curtin,
#        bin/probert and lib/python3.12 (curtin and probert are bundled there as pure Python); the snap's own Python 3.12 is amd64
#        and is NOT used: the container's python3 runs the server (3.14 on 26.04), which is enough for the dry-run
#     3. stubs in front of PATH for what the container lacks: systemd-run, systemd-cat (no systemd), sudo, systemctl (restarts the dry-run
#        server), blockdev (answers for /dev/sda), curtin (records the call of the late-command; there is no /target)
#     4. oneclick_dryrun_driver.py: the stages above, `PASS`/`FAIL` per check, exit status 1 on any FAIL
#   Measured on 2026-10-18: about 5 minutes in all (about 1 minute of setup: apt and unsquashfs; the dry-run install itself takes 75-80 s, twice).
#   Result of that run: 47 of 47 checks passed, with the pre-fix helper as CI_OS_DRYRUN_OLD_HELPER.
#   Bash 3.2 compatible on the host (macOS); ShellCheck clean at -S warning.
#
# CAVEATS: the container's Python (3.14) is not the snap's (3.12); the curtin run is a replay (examples/curtin-events), so disks,
# bootloader and the first boot are NOT tested; `systemd-run` is stubbed, so unit isolation is not tested. What IS the real code:
# subiquity's server.py, install.py, models, the autoinstall schema and loader, the HTTP API binder, the shutdown controller.
#=============================================================================
set -u

SELF="${BASH_SOURCE[0]}"
case "$SELF" in /*) ;; *) SELF="$PWD/$SELF" ;; esac
HERE="$(cd "$(dirname "$SELF")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
HELPER_REL="backends/ubuntu/chroot/payload/live-start/usr/libexec/ci-os/ci-os-auto-install"
KNOWN_ISO_SHA256="601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f"
UNIT="snap.ubuntu-desktop-bootstrap.subiquity-server.service"

# ───────────────────────────── inside the container ─────────────────────────────
OPT=/opt/ci-os-oneclick
SNAP="$OPT/snap"
STUBS="$OPT/stubs"
RUNROOT="${ONECLICK_RUN:-/tmp/ci-os-oneclick-run}"
OUT="${ONECLICK_OUT:-/out}"

say() { printf '%s\n' "$*"; }
die() { printf 'oneclick-dryrun: %s\n' "$*" >&2; exit 2; }

setup_packages() {
  [ -f "$OPT/.packages-done" ] && return 0
  say "== setup: apt packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null || die "apt-get update failed (no network in the container?)"
  # the dependencies of subiquity (apt-deps.txt of the source) that its server imports, plus the tools around it
  apt-get install -y -qq --no-install-recommends \
    python3 python3-yaml python3-attr python3-jsonschema python3-aiohttp python3-requests python3-requests-unixsocket \
    python3-pyudev python3-pyroute2 python3-passlib python3-more-itertools python3-distro-info python3-bson python3-systemd \
    python3-apport python3-apt python3-debian python3-pycountry python3-prettytable python3-ruamel.yaml python3-oauthlib \
    python3-dnspython python3-async-timeout python3-jinja2 python3-packaging python3-urwid \
    squashfs-tools libarchive-tools curl openssl procps util-linux iproute2 udev ca-certificates \
    language-selector-common dctrl-tools lsb-release cloud-init >/dev/null || die "apt-get install failed"
  : > "$OPT/.packages-done"
}

extract_snap() {
  [ -f "$SNAP/meta/snap.yaml" ] && return 0
  [ -f /iso/base.iso ] || die "the ISO is not mounted at /iso/base.iso"
  say "== setup: unpacking the installer snap from the stock ISO"
  local x="$OPT/iso-extract"
  rm -rf "$x" "$SNAP"; mkdir -p "$x" "$SNAP"
  ( cd "$x" && bsdtar -xf /iso/base.iso casper/minimal.standard.live.squashfs casper/install-sources.yaml ) || die "bsdtar failed"
  cp "$x/casper/install-sources.yaml" "$OPT/install-sources.yaml"
  local rel
  rel="$(unsquashfs -l "$x/casper/minimal.standard.live.squashfs" 2>/dev/null | grep -o 'var/lib/snapd/seed/snaps/ubuntu-desktop-bootstrap_[0-9]*\.snap$' | head -n 1)"
  [ -n "$rel" ] || die "no ubuntu-desktop-bootstrap snap in the live layer of this ISO"
  unsquashfs -q -no-xattrs -f -d "$x/layer" "$x/casper/minimal.standard.live.squashfs" "$rel" >/dev/null || die "unsquashfs of the layer failed"
  sha256sum "$x/layer/$rel" | tee "$OPT/snap.sha256"
  # the snap's own code: subiquity (bin/subiquity), curtin and probert (bundled pure Python in lib/python3.12)
  unsquashfs -q -no-xattrs -f -d "$SNAP" "$x/layer/$rel" meta bin/subiquity bin/curtin bin/probert lib/python3.12 >/dev/null || die "unsquashfs of the snap failed"
  rm -rf "$x/layer" "$x/casper/minimal.standard.live.squashfs"
  grep -E '^(name|version):' "$SNAP/meta/snap.yaml"
}

write_stubs() {
  mkdir -p "$STUBS" "$RUNROOT"
  cat > "$STUBS/systemd-run" <<'EOF'
#!/bin/sh
# stand-in for systemd-run (the container has no systemd): apply --setenv, run the command after "--"
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    --setenv) export "$2"; shift 2 ;;
    --property) shift 2 ;;
    *) shift ;;
  esac
done
exec "$@"
EOF
  cat > "$STUBS/systemd-cat" <<'EOF'
#!/bin/sh
# stand-in for systemd-cat (no journald): run the command, its output stays on stdout/stderr
while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
exec "$@"
EOF
  cat > "$STUBS/sudo" <<'EOF'
#!/bin/sh
# stand-in for sudo: the container user is root already; the helper calls `sudo -n <command>`
[ "$1" = "-n" ] && shift
exec "$@"
EOF
  cat > "$STUBS/systemctl" <<EOF
#!/bin/sh
# stand-in for systemctl: the only thing the helper asks for is a restart of the installer's server
if [ "\$*" = "restart $UNIT" ]; then exec bash "$SELF" --serverctl restart; fi
echo "stub systemctl: unexpected arguments: \$*" >&2
exit 1
EOF
  cat > "$STUBS/blockdev" <<EOF
#!/bin/sh
# stand-in for blockdev: the simulated disk /dev/sda; the size can be changed through $RUNROOT/disk-bytes
if [ "\$1" = "--getsize64" ] && [ "\$2" = "/dev/sda" ]; then
  cat "$RUNROOT/disk-bytes" 2>/dev/null || echo 107374182400
  exit 0
fi
exec /usr/bin/blockdev "\$@"
EOF
  cat > "$STUBS/curtin" <<EOF
#!/bin/sh
# stand-in for the snap's curtin (there is no /target in a dry run): record the call, succeed
echo "curtin \$*" >> "$RUNROOT/curtin-calls.log"
exit 0
EOF
  chmod +x "$STUBS"/*
}

# serverctl start <name> <mode> <fresh|keep> | restart | stop [<name>]
#   mode  file:<path>  --autoinstall <path>                       (the server reads exactly that file)
#         root         no option: the server looks at <output base>/autoinstall.yaml, as the real one looks at /autoinstall.yaml
#         none         --autoinstall ""                              (autoinstall switched off)
sc_stop() {
  local pidfile pid n
  [ -f "$RUNROOT/current" ] || return 0
  pidfile="$RUNROOT/$(sed -n 1p "$RUNROOT/current")/server.pid"
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile")"
    kill "$pid" 2>/dev/null
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
    kill -9 "$pid" 2>/dev/null
    rm -f "$pidfile"
  fi
  return 0
}

sc_launch() {
  local name mode out
  local -a extra=()
  name="$(sed -n 1p "$RUNROOT/current")"; mode="$(sed -n 2p "$RUNROOT/current")"
  out="$RUNROOT/$name"
  case "$mode" in
    file:*) extra=(--autoinstall "${mode#file:}") ;;
    none) extra=(--autoinstall "") ;;
    *) ;;
  esac
  (
    cd "$SNAP/bin/subiquity" || exit 1
    export PYTHONPATH="$SNAP/lib/python3.12/site-packages:$PWD" PYTHONIOENCODING=utf-8 PYTHONDONTWRITEBYTECODE=1
    export USER=root ONECLICK_RUN="$RUNROOT" PATH="$STUBS:$PATH"
    # the arguments of the real unit (bin/subiquity-server) that matter, plus the dry-run machine; the kernel command line has
    # ci.autoinstall=1 and NOT the bare word `autoinstall`: that word would skip the confirmation (install.py)
    nohup python3 -m subiquity.cmd.server --dry-run --machine-config examples/machines/simple.json --bootloader uefi \
      --source-catalog "$OPT/install-sources.yaml" --postinst-hooks-dir examples/postinst.d/ \
      --output-base "$out" --socket "$out/socket" --storage-version=2 --use-os-prober --no-wlan-listener \
      --kernel-cmdline "BOOT_IMAGE=/casper/vmlinuz ci.autoinstall=1 --- quiet splash" "${extra[@]}" \
      > "$out/server.out" 2>&1 < /dev/null &
    echo $! > "$out/server.pid"
  )
}

serverctl() {
  local name
  case "${1:-}" in
    start)
      name="${2:?name}"
      sc_stop
      [ "${4:-fresh}" = fresh ] && rm -rf "${RUNROOT:?}/$name"
      mkdir -p "$RUNROOT/$name"
      printf '%s\n%s\n' "$name" "${3:?mode}" > "$RUNROOT/current"
      sc_launch ;;
    restart)
      [ -f "$RUNROOT/current" ] || die "serverctl restart: no server was started"
      sc_stop
      sc_launch ;;
    stop)
      sc_stop
      rm -f "$RUNROOT/current" ;;
    *) die "serverctl: start|restart|stop" ;;
  esac
}

inside() {
  mkdir -p "$OPT" "$OUT"
  [ "$(id -u)" = 0 ] || die "--inside is meant to run as root in the throw-away container"
  setup_packages
  extract_snap
  write_stubs
  local old="" rc
  [ -f /old-helper/ci-os-auto-install ] && old="--old-helper /old-helper/ci-os-auto-install"
  say "== running the stages (python3 -I $HERE/oneclick_dryrun_driver.py)"
  export ONECLICK_SELF="$SELF" ONECLICK_RUN="$RUNROOT" PYTHONDONTWRITEBYTECODE=1 PATH="$STUBS:$PATH"
  # shellcheck disable=SC2086
  python3 -I "$HERE/oneclick_dryrun_driver.py" --helper "$REPO/$HELPER_REL" --stage "${CI_OS_DRYRUN_STAGE:-all}" $old 2>&1 | tee "$OUT/dryrun.log"
  rc=${PIPESTATUS[0]}
  serverctl stop
  mkdir -p "$OUT/server-logs"
  for d in "$RUNROOT"/*/; do
    [ -d "$d" ] || continue
    mkdir -p "$OUT/server-logs/$(basename "$d")"
    cp -p "$d"/subiquity-server-debug.log.* "$d"/server.out "$OUT/server-logs/$(basename "$d")/" 2>/dev/null
  done
  cp -p "$RUNROOT/curtin-calls.log" "$OUT/" 2>/dev/null
  cp -p "$OPT/snap.sha256" "$OUT/" 2>/dev/null
  say "== evidence in $OUT (dryrun.log, server-logs/)"
  exit "$rc"
}

# ───────────────────────────── on the host ─────────────────────────────
host() {
  command -v docker >/dev/null 2>&1 || die "docker is needed"
  local iso="${CI_OS_DRYRUN_ISO:-$HOME/.cache/ci-stick-test/iso/ubuntu-26.04.1-desktop-amd64.iso}"
  local name="${CI_OS_DRYRUN_CONTAINER:-ci-os-oneclick-1}"
  local image="${CI_OS_DRYRUN_IMAGE:-ubuntu:26.04}"
  local out="${CI_OS_DRYRUN_OUT:-}"
  [ -f "$iso" ] || die "the stock ISO is not at $iso (set CI_OS_DRYRUN_ISO)"
  [ -n "$out" ] || out="$(mktemp -d "${TMPDIR:-/tmp}/oneclick-dryrun.XXXXXX")"
  mkdir -p "$out"
  case "$name" in ci-os-oneclick-*) ;; *) die "the container name must be ci-os-oneclick-<n>" ;; esac
  if command -v shasum >/dev/null 2>&1; then
    local sum
    sum="$(shasum -a 256 "$iso" | cut -d' ' -f1)"
    [ "$sum" = "$KNOWN_ISO_SHA256" ] || printf 'oneclick-dryrun: note: the ISO is not the 26.04.1 build this test was written with (sha256 %s)\n' "$sum" >&2
  fi
  local old_mount=""
  if [ -n "${CI_OS_DRYRUN_OLD_HELPER:-}" ]; then
    [ -f "$CI_OS_DRYRUN_OLD_HELPER" ] || die "CI_OS_DRYRUN_OLD_HELPER is not a file"
    old_mount="-v $CI_OS_DRYRUN_OLD_HELPER:/old-helper/ci-os-auto-install:ro"
  fi
  docker rm -f "$name" >/dev/null 2>&1
  printf 'oneclick-dryrun: evidence goes to %s\n' "$out"
  # shellcheck disable=SC2086
  docker run --rm --init --name "$name" --platform linux/arm64 \
    -e "CI_OS_DRYRUN_STAGE=${CI_OS_DRYRUN_STAGE:-all}" \
    -v "$iso:/iso/base.iso:ro" -v "$REPO:$REPO:ro" -v "$out:/out" $old_mount \
    "$image" bash "$SELF" --inside
}

case "${1:-}" in
  --inside) inside ;;
  --serverctl) shift; serverctl "$@" ;;
  "") host ;;
  *) die "usage: $0   (see the header; the only argument it takes itself is the internal --inside / --serverctl)" ;;
esac
