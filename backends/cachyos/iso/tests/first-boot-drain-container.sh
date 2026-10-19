#!/usr/bin/env bash
#=============================================================================
# Manual test (Docker, no network): the last lines of the first-boot output survive the exit of the main process under a REAL systemd.
#
# The unit has the default KillMode=control-group: the moment first-boot-setup.sh exits, systemd SIGTERMs whatever is left in the
# cgroup, and the filter and the tee of the log live in a process substitution that bash does not wait for. A first version of
# progress-filter.sh (a bash loop, a byte at a time) was slower than a plain tee and lost "First-boot setup completed", "NOTE: Log
# out ..." and "Will retry automatically ..." in 24 to 32 of 40 runs; the EXIT trap of the driver (drain_output) is the fix.
# iso/tests/progress-filter.sh, section M, tests that without systemd (a process group killed when the main process exits, 200 runs,
# a slow filter as the sensitive case); this runs the same thing under a systemd manager:
#   1. the unit file in the repository does not override KillMode (so the control-group default is what the test models)
#   2. N runs of the REAL driver with the real filter                           -> no run may lose the tail
#   3. N runs of the real driver with a SLOW filter (20 ms a line)              -> no run may lose the tail
#   4. CONTROL: N runs of the driver WITHOUT the trap, slow filter              -> the tail IS lost (otherwise the test proves nothing)
#   5. a background child that keeps the pipe open: the unit is done after the drain's bound (5 s), not after the child
# and, before that, the whole of progress-filter.sh in the container (bash 5.3 and GNU userland instead of the host's).
#
# systemd is NEVER run as PID 1 here (that wiped the Docker VM's Rosetta registration once): the container's PID 1 is this script, and
# the manager is `systemd --user`, a USER manager, started by hand. The unit is a minimal one next to the real one (Type=exec, default
# KillMode, output to a file instead of journal+console), because a user manager has no journal in a container.
#
#   backends/cachyos/iso/tests/first-boot-drain-container.sh [--image IMAGE] [--runs N] [--no-suite]
#       --image IMAGE   the builder image (default: the newest ci-os-cachyos-builder:*)
#       --runs N        runs per variant (default 40)
#       --no-suite      do not run progress-filter.sh in the container first
#   CI_OS_DRAIN_NAME=name   name the container, so that it can be found and removed
#
# Needs: Docker, and an image with systemd, bash 4.4+, gawk and procps (the builder image has them, and is the default). The manager must start:
# in the amd64 builder image under Rosetta (Apple silicon) `systemd --user` stops with "Failed to pin executor binary
# /usr/lib/systemd/systemd-executor: Invalid argument" (the same emulation artefact as in first-boot-units-container.sh), and this script
# says so and exits 2. It was run for real in an arm64 Ubuntu 26.04 container (systemd 259) with gawk and procps installed:
#   docker run -d --privileged --name X -v "$PWD:/repo:ro" ubuntu:26.04 sleep infinity
#   docker exec X sh -c 'apt-get update -qq && apt-get install -y -qq systemd gawk procps'
#   docker exec -e CI_OS_DRAIN_INSIDE=1 -e CI_OS_DRAIN_RUNS=40 -e CI_OS_DRAIN_SUITE=0 X bash /repo/backends/cachyos/iso/tests/first-boot-drain-container.sh
# (CI_OS_DRAIN_SYSTEMD=path names another systemd binary.) Exit: 0 all pass, 1 a check failed, 2 cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
die() { echo "first-boot-drain-container: $*" >&2; exit 2; }

if [ "${CI_OS_DRAIN_INSIDE:-}" != 1 ]; then
  IMAGE=""; RUNS=40; SUITE=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --image) [ $# -ge 2 ] || die "--image needs a value"; IMAGE="$2"; shift 2 ;;
      --runs) [ $# -ge 2 ] || die "--runs needs a value"; RUNS="$2"; shift 2 ;;
      --no-suite) SUITE=0; shift ;;
      -h|--help) sed -n '2,/^# Needs:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$RUNS" in ''|*[!0-9]*|0) die "--runs needs a positive number" ;; esac
  command -v docker >/dev/null 2>&1 || die "docker not found"
  docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"
  if [ -z "$IMAGE" ]; then
    IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' ci-os-cachyos-builder 2>/dev/null | head -n 1)"
    [ -n "$IMAGE" ] || die "no ci-os-cachyos-builder image: run backends/cachyos/iso/scripts/build-iso.sh once, or pass --image"
  fi
  args=(run --rm --privileged --platform linux/amd64 -v "$REPO_ROOT:/repo:ro" -e CI_OS_DRAIN_INSIDE=1 -e "CI_OS_DRAIN_RUNS=$RUNS" -e "CI_OS_DRAIN_SUITE=$SUITE")
  [ -z "${CI_OS_DRAIN_NAME:-}" ] || args+=(--name "$CI_OS_DRAIN_NAME")
  exec docker "${args[@]}" "$IMAGE" bash /repo/backends/cachyos/iso/tests/first-boot-drain-container.sh
fi

#=== container part ===========================================================================================================
SYSTEMD="${CI_OS_DRAIN_SYSTEMD:-/usr/lib/systemd/systemd}"
[ -x "$SYSTEMD" ] || die "no systemd in this image"
command -v systemctl >/dev/null 2>&1 || die "no systemctl in this image"
[ "$$" != 1 ] || [ "$(cat /proc/1/comm 2>/dev/null)" != systemd ] || die "refusing to run: systemd is PID 1 here"
RUNS="${CI_OS_DRAIN_RUNS:-40}"
PROV=/repo/backends/cachyos/provision
FAIL=0
t_pass() { printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

if [ "${CI_OS_DRAIN_SUITE:-1}" = 1 ]; then
  echo "== progress-filter.sh in the container ($(bash --version | head -n 1 | cut -c1-40), $(awk --version 2>&1 | head -n 1 | cut -c1-30))"
  if bash /repo/backends/cachyos/iso/tests/progress-filter.sh > /tmp/suite.out 2>&1; then t_pass "progress-filter.sh: $(grep -E '^== [0-9]+ passed' /tmp/suite.out | tail -n 1)"
  else t_fail "progress-filter.sh failed in the container"; grep -E '^FAIL' /tmp/suite.out | head -n 20; fi
fi

echo "== the unit"
if grep -q '^KillMode=' "$PROV/systemd/ci-os-first-boot-setup.service"; then t_fail "the unit file sets KillMode: this test models the control-group default and must be adapted"
else t_pass "ci-os-first-boot-setup.service leaves KillMode at its default (control-group), which is what this test models"; fi

echo "== a systemd USER manager (not PID 1)"
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR" /run/systemd/system; chmod 700 "$XDG_RUNTIME_DIR"
U=/root/.config/systemd/user; mkdir -p "$U"
"$SYSTEMD" --user > /tmp/user-manager.log 2>&1 &
UM=$!
trap 'systemctl --user stop "drain-*.service" >/dev/null 2>&1; kill "$UM" 2>/dev/null' EXIT
st=""
for _ in $(seq 1 80); do st="$(systemctl --user is-system-running 2>/dev/null)"; case "$st" in running|degraded) break ;; esac; sleep 0.5; done
case "$st" in
  running|degraded) t_pass "the user manager is up (pid $UM, $st)" ;;
  *) tail -n 10 /tmp/user-manager.log
     die "the user manager did not come up ($st): under Rosetta systemd cannot pin its executor binary (see the header); use a native container" ;;
esac

# A bootstrap tree per variant: the driver and the filter from the repository, a provisioner that floods the output and ends normally.
mkdir -p /bin-stubs
cat > /bin-stubs/provision.sh <<'PROVISIONER'
#!/bin/bash
echo "provisioner running"
n=0
while [ "$n" -lt "${DRAIN_REDRAWS:-0}" ]; do
  n=$((n + 1))
  printf '\033[?25l\033[?2026hpulling manifest \033[K\n'
  printf 'pulling 797b70c4edf8: %3d%% \342\226\225\342\226\210\342\226\210\342\226\217 15 MB/ 45 MB 26 MB/s 9s\033[K\n' $((n % 101))
  printf '\033[?2026l\033[?25h\033[2A'
done
[ -z "${DRAIN_BACKGROUND:-}" ] || { sleep 60 & }
echo "[SUCCESS] the provisioner's last line"
exit 0
PROVISIONER
printf '#!/bin/bash\nwhile IFS= read -r l; do sleep 0.02; printf "%%s\\n" "$l"; done\n' > /bin-stubs/slow-filter.sh
mkvariant() {  # NAME FILTER-FILE DRIVER-FILE REDRAWS [BACKGROUND]
  local v="$1" B="/b-$1"
  rm -rf "$B" "/st-$v"; mkdir -p "$B/backends/cachyos/provision" "/st-$v"
  cp /bin-stubs/provision.sh "$B/backends/cachyos/provision/provision.sh"; cp "$2" "$B/backends/cachyos/provision/progress-filter.sh"
  cp "$3" "/d-$v.sh"; chmod +x "/d-$v.sh" "$B/backends/cachyos/provision/"*.sh
  cat > "$U/drain-$v.service" <<UNIT
[Service]
Type=exec
Environment=HOME=/root DRAIN_REDRAWS=$4 ${5:+DRAIN_BACKGROUND=1} CI_OS_BOOTSTRAP_ROOT=$B CI_OS_STATE_DIR=/st-$v CI_OS_LOG_FILE=/st-$v/log CI_OS_LOCK_FILE=/st-$v/lock CI_OS_CMDLINE_FILE=/dev/null CI_OS_RUN_ARCHISO=/nonexistent CI_OS_NETWORK_PROBE=/bin/true
ExecStart=/d-$v.sh --manual
StandardOutput=append:/st-$v/unit-out
StandardError=append:/st-$v/unit-out
UNIT
}
# runs V N: start the unit N times; count the runs whose log or unit output lack the last lines
runs() {
  local v="$1" n="$2" i lost=0 t0 t1
  RUN_MS=0
  for ((i = 1; i <= n; i++)); do
    rm -rf "/st-$v"; mkdir -p "/st-$v"
    t0=$(date +%s%N)
    systemctl --user start "drain-$v.service"
    while systemctl --user is-active -q "drain-$v.service"; do sleep 0.02; done
    t1=$(date +%s%N); RUN_MS=$(( (t1 - t0) / 1000000 ))
    sleep 0.3
    if grep -q 'NOTE: Log out' "/st-$v/log" 2>/dev/null && grep -q 'NOTE: Log out' "/st-$v/unit-out" 2>/dev/null && grep -q "provisioner's last line" "/st-$v/log" 2>/dev/null; then :; else lost=$((lost + 1)); fi
  done
  RUN_LOST=$lost
}

echo "== the real driver"
mkvariant real "$PROV/progress-filter.sh" "$PROV/first-boot-setup.sh" 300
mkvariant slow /bin-stubs/slow-filter.sh "$PROV/first-boot-setup.sh" 0
# CONTROL: the same driver without the drain
grep -v '^trap drain_output EXIT' "$PROV/first-boot-setup.sh" > /bin-stubs/driver-notrap.sh
if [ "$(grep -c '^trap drain_output EXIT' "$PROV/first-boot-setup.sh")" != 1 ]; then die "cannot build the control: the driver has no single 'trap drain_output EXIT' line"; fi
mkvariant ctl /bin-stubs/slow-filter.sh /bin-stubs/driver-notrap.sh 0
mkvariant bg "$PROV/progress-filter.sh" "$PROV/first-boot-setup.sh" 0 1
systemctl --user daemon-reload

runs real "$RUNS"
if [ "$RUN_LOST" = 0 ]; then t_pass "real driver, real filter, a 300-redraw flood: $RUNS runs, none lost the tail"; else t_fail "real driver, real filter: $RUN_LOST of $RUNS runs lost the tail"; tail -n 6 /st-real/log | cat -v | sed 's/^/      /'; fi
runs slow "$RUNS"
if [ "$RUN_LOST" = 0 ]; then t_pass "real driver, slow filter (20 ms a line): $RUNS runs, none lost the tail"; else t_fail "real driver, slow filter: $RUN_LOST of $RUNS runs lost the tail"; fi
runs ctl "$RUNS"
if [ "$RUN_LOST" -gt 0 ]; then t_pass "CONTROL, the driver without the trap, slow filter: $RUN_LOST of $RUNS runs lost the tail (so this test can see the defect)"; else t_fail "CONTROL: the driver without the trap lost nothing in $RUNS runs, so a pass above proves nothing"; fi
runs bg 1
if [ "$RUN_MS" -ge 3500 ] && [ "$RUN_MS" -lt 20000 ] && [ "$RUN_LOST" = 0 ]; then t_pass "a background child holding the pipe (sleep 60): the unit was done after $RUN_MS ms (the drain's bound is 5 s), not after the child, and the tail is in the log"
else t_fail "background child: $RUN_MS ms, lost=$RUN_LOST"; fi

echo
if [ "$FAIL" = 0 ]; then echo "== all passed"; else echo "== $FAIL failed"; fi
[ "$FAIL" = 0 ]
