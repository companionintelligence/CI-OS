#!/usr/bin/env bash
#=============================================================================
# Test: the units that must run on the FIRST BOOT OF AN INSTALLED MACHINE really do, with systemd as PID 1 on Ubuntu 26.04
#
# Two things in the image depend on a machine that has just been installed from the live USB coming up "for the first time":
#
#   - the SSH host keys. customize-chroot.sh (Step 11) removes the keys openssh-server made while the image was built, and
#     payload/ssh/.../sshd-keygen.service.d/10-ci-os-host-keys.conf makes the machine create its own;
#   - ci-os-first-boot-rebrand.service, which re-applies the Companion OS identity once.
#
# Both used to be gated on ConditionFirstBoot=yes. systemd decides "first boot" from /etc/machine-id alone (machine-id(5):
# missing, empty or "uninitialized" is a first boot, a valid ID is not), and the installer (subiquity,
# subiquity/models/subiquity.py: write_files "etc_machine_id") copies the LIVE SESSION's machine-id into the new system. So on
# a real install neither unit ran: no host keys, ssh.service dying in `sshd -t` ("no hostkeys available"). A test that boots
# with an EMPTY machine-id (installed-boot.sh does) cannot see that, so this one boots with an installer-style ID.
#
# It builds a 26.04 image (systemd, openssh-server, cloud-init) with the host keys already removed and the build-time
# os-release in place, then boots containers from it with systemd as PID 1 and checks, per case:
#
#   host keys   control (no drop-in): the unit is skipped, no key, ssh.service fails      -> so the test can fail
#               the drop-in: keys made, ssh answers; a second boot keeps the keys and does not run the unit again;
#               a true first boot ("uninitialized") works too; a read-only /etc/ssh still skips the unit (the conditions
#               the package sets besides ConditionFirstBoot survive the reset) and an identical writable one makes the keys;
#               the cloud-init path of the real installer
#   rebrand     control (the old ConditionFirstBoot=yes unit): skipped. The shipped unit and script (cut out of
#               customize-chroot.sh): runs once, leaves os-release byte for byte what the build wrote, repairs an os-release
#               that was reset to Ubuntu's, never runs again (stamp), never runs in a live session (/cdrom/casper/vmlinuz)
#
# SAFETY: systemd as PID 1 must not be able to touch the engine's kernel
#
#   The hazard. In a PRIVILEGED container systemd mounts binfmt_misc and runs systemd-binfmt.service, which unregisters every
#   handler of the kernel and registers only /usr/lib/binfmt.d's (python3.14); systemd-sysctl.service writes the kernel's global
#   sysctls. On Docker Desktop, OrbStack, Colima and the like that kernel is the one Linux VM all containers share: its Rosetta
#   and qemu-user handlers are gone, every amd64 container and chroot on the machine then fails until the VM restarts, and
#   whatever was building at that moment is poisoned. The first version of this test ran `docker create --privileged ... /sbin/init`
#   and is the likely cause of several such wipes of an Apple-silicon Mac's Docker Desktop VM in 2026-10 (by timing and by what
#   systemd-binfmt does; the wipe itself was deliberately never reproduced).
#
#   So the default is "contained": the same flags minus --privileged, no added capability, the default seccomp profile, and the
#   engine's own read-only /proc/sys. That is enough for systemd to boot and for every case here (measured: Docker Desktop 29.8.2,
#   kernel 7.0.14-linuxkit, arm64, cgroup v2). The system ends "degraded": tmp.mount, systemd-resolved (its credentials setup
#   needs a mount) and netplan-configure fail; none of the units under test depends on them. No CAP_SYS_ADMIN, deliberately,
#   although `--cap-add SYS_ADMIN` with a read-only /proc/sys already keeps systemd-binfmt out: a container that has it can
#   `mount -t binfmt_misc` itself and gets the SHARED instance, read-write (measured on that engine: the VM's own superblock, the
#   rosetta and qemu handlers listed). Without it the mount is refused (EPERM). That is also why the read-only /etc/ssh case is a
#   read-only tmpfs below and not `mount -o remount,ro,bind` inside the container.
#
#   Layers, each checked here: (1) before any systemd container exists, a gate runs a container with the SAME flags and a plain
#   shell and tries what systemd would: is /proc/sys read-only? is a write refused (the container's own hostname written back)?
#   is `mount -t binfmt_misc` refused? If an answer is wrong the test stops with exit 1; (2) every container gets
#   systemd-binfmt.service, proc-sys-fs-binfmt_misc.{automount,mount} and systemd-sysctl.service masked (docker cp of /dev/null
#   symlinks into /etc/systemd/system, so a cached older image is covered too); (3) after every boot the same probe runs inside
#   the container: binfmt_misc is not mounted there, the four units are masked and, in contained mode, the answers of (1) hold.
#   --selftest runs the decision logic of all this against canned probe reports, mutants included, without Docker.
#
#   The old behaviour is still there, behind an explicit switch, for an engine on which the contained profile cannot boot systemd
#   (cgroup v1, a hardened daemon):  CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=1  runs the containers --privileged (the masks stay, the gate
#   is skipped, and where the engine looks shared a banner and a 10 s pause come first). Do not set it on Docker Desktop, OrbStack,
#   Colima, Rancher Desktop or any engine whose kernel has Rosetta/qemu handlers: run the test on a Linux host or VM instead. The
#   masks are meant to keep the handlers safe even then, but that is NOT verified, on purpose: nobody should find out on the
#   machine they work on. If the contained profile does not boot, the test says so and exits 2; it never falls back by itself.
#
# It needs docker (cgroup v2) and network for the first run (apt in the image build). Containers and the image are named
# ${CI_TEST_PREFIX:-ci-os-test-firstboot}-* and removed at the end (CI_TEST_KEEP=1 keeps the image). Host bash 3.2 is enough.
# Exit status is non-zero if a check fails (1); 2 if it cannot run here.
#
#   backends/ubuntu/chroot/tests/first-boot-units-boot.sh              the test (Docker; minutes on the first run)
#   backends/ubuntu/chroot/tests/first-boot-units-boot.sh --selftest   the containment logic only (no Docker; about a second)
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../customize-chroot.sh"
DROPIN_DIR="$HERE/../payload/ssh/etc/systemd/system/sshd-keygen.service.d"
OSREL_LIB="$HERE/../../lib/os-release.sh"
[[ -f "$SCRIPT" && -f "$DROPIN_DIR/10-ci-os-host-keys.conf" && -f "$OSREL_LIB" ]] || { echo "missing customize-chroot.sh, the drop-in or os-release.sh" >&2; exit 2; }

SELFTEST=0
case "${1:-}" in
    "") ;;
    --selftest) SELFTEST=1 ;;
    *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac
if [[ "$SELFTEST" -eq 0 ]]; then
    command -v docker >/dev/null 2>&1 || { echo "first-boot-units test: docker not found" >&2; exit 2; }
    docker info >/dev/null 2>&1 || { echo "first-boot-units test: the docker daemon is not reachable" >&2; exit 2; }
fi

PREFIX="${CI_TEST_PREFIX:-ci-os-test-firstboot}"
IMG="$(printf '%s' "$PREFIX" | tr 'A-Z' 'a-z')-img:26.04"   # image names must be lower case
WORK="$(mktemp -d "${TMPDIR:-/tmp}/first-boot-units.XXXXXX")"
BUILT_IMAGE=0
cleanup() {
    docker ps -aq --filter "name=^${PREFIX}-" 2>/dev/null | while read -r c; do docker rm -f "$c" >/dev/null 2>&1; done
    if [[ "$BUILT_IMAGE" -eq 1 && "${CI_TEST_KEEP:-0}" != 1 ]]; then docker rmi -f "$IMG" >/dev/null 2>&1; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
# check <label> <actual> <expected>
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', wanted '$3')"; fi; }
# has <label> <text> <fixed string that must be in it>
has() { if printf '%s\n' "$2" | grep -q -F -- "$3"; then pass "$1"; else fail "$1 (no '$3' in: $(printf '%s' "$2" | head -c 300 | tr '\n' '|'))"; fi; }

# ---------------------------------------------------------------------------------------------------------------------
# Containment (see SAFETY in the header). Everything that decides what a systemd container may do lives in this block, and
# --selftest exercises it with a fake `docker`.
# ---------------------------------------------------------------------------------------------------------------------
# The units through which systemd would write the kernel's global state, masked in every container.
MASKED_UNITS="systemd-binfmt.service proc-sys-fs-binfmt_misc.automount proc-sys-fs-binfmt_misc.mount systemd-sysctl.service"

# contained (the default), or privileged only when the caller asked for it with exactly CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=1
select_mode() { if [[ "${CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED:-}" == 1 ]]; then echo privileged; else echo contained; fi; }

# set_flags <mode>: SYSD_FLAGS, the `docker create/run` flags every systemd container gets. Never empty (bash 3.2 and set -u).
set_flags() {
    case "$1" in
        contained)  SYSD_FLAGS=(--cgroupns=host --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw) ;;
        privileged) SYSD_FLAGS=(--privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw) ;;
        *) return 1 ;;
    esac
}

# The probe: key=value lines about what this container can reach. Run by the gate (plain shell, same flags) and inside every booted
# container. PROBE_SYSTEMD=1 adds the unit masks (needs a running systemd), PROBE_ACTIVE=1 the three attempts. The only things it
# ever writes are the container's OWN hostname (its UTS namespace; the value it already has) and a mount of binfmt_misc that is
# unmounted at once if it works; it never writes to a binfmt_misc file.
IFS= read -r -d '' CONTAINMENT_PROBE <<'PROBE' || true
echo "binfmt_mounts=$(grep -c ' binfmt_misc ' /proc/self/mountinfo)"
if [ "${PROBE_SYSTEMD:-0}" = 1 ]; then
    for u in $MASKED_UNITS; do echo "load_$u=$(systemctl show -p LoadState --value "$u" 2>/dev/null)"; done
fi
if [ "${PROBE_ACTIVE:-0}" = 1 ]; then
    if grep -q -E ' /proc/sys ro(,| )' /proc/self/mountinfo; then echo proc_sys=read-only; else echo proc_sys=writable; fi
    h="$(cat /proc/sys/kernel/hostname)"
    if ( printf '%s' "$h" > /proc/sys/kernel/hostname ) 2>/dev/null; then echo proc_sys_write=allowed; else echo proc_sys_write=refused; fi
    mkdir -p /run/binfmt-probe
    if mount -t binfmt_misc binfmt_misc /run/binfmt-probe 2>/dev/null; then umount /run/binfmt-probe; echo binfmt_mount_attempt=succeeded; else echo binfmt_mount_attempt=refused; fi
fi
true
PROBE

# containment_violations <report> <masks 0|1> <active 0|1>: what in a probe report breaks the containment, as "[..] [..]"; empty = fine
containment_violations() {
    local r="$1" v="" u
    printf '%s\n' "$r" | grep -q -x 'binfmt_mounts=0' || v="$v [binfmt_misc is mounted inside the container]"
    if [[ "$2" == 1 ]]; then
        for u in $MASKED_UNITS; do
            printf '%s\n' "$r" | grep -q -x "load_$u=masked" || v="$v [$u is not masked]"
        done
    fi
    if [[ "$3" == 1 ]]; then
        printf '%s\n' "$r" | grep -q -x 'proc_sys=read-only' || v="$v [/proc/sys is not read-only]"
        printf '%s\n' "$r" | grep -q -x 'proc_sys_write=refused' || v="$v [a write to /proc/sys was not refused]"
        printf '%s\n' "$r" | grep -q -x 'binfmt_mount_attempt=refused' || v="$v [the container can mount binfmt_misc itself]"
    fi
    printf '%s' "$v"
}

# profile_gate: run the probe in a throw-away container with the flags of the systemd containers and no systemd. 0 = contained,
# 1 = it is not (GATE_WHY says why), 2 = the probe container did not run (GATE_WHY says why).
GATE_WHY=""
profile_gate() {
    local rep viol
    GATE_WHY=""
    if ! rep="$(docker run --rm --pull=never --name "$PREFIX-gate" "${SYSD_FLAGS[@]}" -e MASKED_UNITS="$MASKED_UNITS" -e PROBE_SYSTEMD=0 -e PROBE_ACTIVE=1 --entrypoint bash "$IMG" -c "$CONTAINMENT_PROBE" 2>&1)"; then
        GATE_WHY="the gate container did not run: $(printf '%s' "$rep" | head -c 300 | tr '\n' '|')"
        return 2
    fi
    viol="$(containment_violations "$rep" 0 1)"
    if [[ -n "$viol" ]]; then GATE_WHY="$viol"; return 1; fi
    return 0
}

# After every boot, inside the container; stops the whole test at the first container that fails it.
ACTIVE_PROBE=1       # set from the mode below
CONTAINED_N=0
contain_or_die() {
    local rep viol
    rep="$(docker exec -e MASKED_UNITS="$MASKED_UNITS" -e PROBE_SYSTEMD=1 -e PROBE_ACTIVE="$ACTIVE_PROBE" "$1" bash -c "$CONTAINMENT_PROBE" 2>&1)"
    viol="$(containment_violations "$rep" 1 "$ACTIVE_PROBE")"
    if [[ -n "$viol" ]]; then
        fail "$1 is not contained:$viol"
        printf 'FATAL  stopping at the first container that can reach the engine'"'"'s kernel state. Probe report: %s\n' "$(printf '%s' "$rep" | head -c 400 | tr '\n' '|')" >&2
        echo "$PASS passed, $FAIL failed (aborted)"
        exit 1
    fi
    CONTAINED_N=$((CONTAINED_N + 1))
}

# Could a privileged systemd harm this engine? Sets ENGINE_OS, ENGINE_HANDLERS, HAZARD_WHY. 0 = yes (a shared VM, or binfmt_misc
# handlers that would be wiped), 1 = nothing suggests it, 2 = could not tell. host_os is a function so --selftest can fake it.
ENGINE_OS=""; ENGINE_HANDLERS=""; HAZARD_WHY=""
host_os() { uname -s; }
# The handlers registered in the kernel the daemon runs on (one per line, `register` and `status` left out), read through a
# READ-ONLY bind mount of that kernel's /proc/sys/fs/binfmt_misc into a plain unprivileged container. Status 1 = could not look.
engine_binfmt_handlers() {
    local out
    out="$(docker run --rm --pull=never -v /proc/sys/fs/binfmt_misc:/binfmt:ro --entrypoint ls "$IMG" /binfmt 2>/dev/null)" || return 1
    printf '%s\n' "$out" | grep -v -x -e register -e status || true
}
engine_hazard() {
    local rc=1 h
    ENGINE_OS="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)"; ENGINE_HANDLERS=""; HAZARD_WHY=""
    case "$ENGINE_OS" in
        *"Docker Desktop"*|*"Rancher Desktop"*|*OrbStack*|*olima*) HAZARD_WHY="the engine is '$ENGINE_OS': one Linux VM whose kernel every container on this machine shares"; rc=0 ;;
    esac
    if [[ $rc -ne 0 && "$(host_os)" == Darwin ]]; then HAZARD_WHY="this is macOS: every Docker engine here is a Linux VM whose kernel all containers share"; rc=0; fi
    if h="$(engine_binfmt_handlers)"; then
        h="$(printf '%s' "$h" | tr '\n' ' ')"
        if [[ -n "${h// /}" ]]; then ENGINE_HANDLERS="${h% }"; HAZARD_WHY="$HAZARD_WHY${HAZARD_WHY:+; }the engine's kernel has binfmt_misc handlers registered (${ENGINE_HANDLERS})"; rc=0
        elif [[ $rc -ne 0 ]]; then rc=1; fi
    elif [[ $rc -ne 0 ]]; then rc=2; fi
    return $rc
}

# make_masks: $WORK/mask holds one /dev/null symlink per masked unit; new_machine copies it to /etc/systemd/system
make_masks() { local u; mkdir -p "$WORK/mask" && for u in $MASKED_UNITS; do ln -sf /dev/null "$WORK/mask/$u" || return 1; done; }

# ---------------------------------------------------------------------------------------------------------------------
# new_machine <name> <machine-id file> [with-dropin 0|1] [cloud-init 0|1] [rebrand unit file or ""] [tmpfs options for /etc/ssh]
# Creates (does not start) a container, so files can be placed before systemd reads them. Sets CT.
new_machine() {
    CT="$PREFIX-$1"
    docker rm -f "$CT" >/dev/null 2>&1
    local create=(create --name "$CT" "${SYSD_FLAGS[@]}")
    [[ -n "${6:-}" ]] && create+=(--tmpfs "/etc/ssh:$6")
    docker "${create[@]}" "$IMG" /sbin/init >/dev/null || return 1
    docker cp "$WORK/mask/." "$CT:/etc/systemd/system/" || return 1        # before systemd reads anything: binfmt and sysctl units masked
    docker cp "$2" "$CT:/etc/machine-id" || return 1
    if [[ "${3:-0}" == 1 ]]; then docker cp "$DROPIN_DIR" "$CT:/etc/systemd/system/sshd-keygen.service.d" || return 1; fi
    if [[ "${4:-0}" == 1 ]]; then
        docker cp "$WORK/99-installer.cfg" "$CT:/etc/cloud/cloud.cfg.d/99-installer.cfg" || return 1
        docker cp "$WORK/ds-identify.cfg" "$CT:/etc/cloud/ds-identify.cfg" || return 1
    else
        docker cp "$WORK/empty" "$CT:/etc/cloud/cloud-init.disabled" || return 1       # keep cloud-init out of the way
    fi
    if [[ -n "${5:-}" ]]; then
        docker cp "$5" "$CT:/usr/lib/systemd/system/ci-os-first-boot-rebrand.service" || return 1
        docker cp "$WORK/first-boot-rebrand.sh" "$CT:/usr/lib/ci-os/first-boot-rebrand.sh" || return 1
    fi
}
# boot <container>: start and wait until systemd has finished starting up (running or degraded), then check the containment.
boot() {
    docker start "$1" >/dev/null || return 1
    local st="" up=""
    for _ in $(seq 1 150); do
        st="$(docker exec "$1" systemctl is-system-running 2>/dev/null)"
        case "$st" in running|degraded) contain_or_die "$1"; return 0 ;; esac
        up="$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)"
        if [[ "$up" != true ]]; then echo "  ($1 exited while booting: $(docker logs --tail 5 "$1" 2>&1 | tr '\n' '|'))" >&2; return 1; fi
        sleep 1
    done
    echo "  (systemd in $1 is still '$st' after 150 s)" >&2
    return 1
}
dx() { docker exec "$CT" bash -c "$1" 2>&1; }
banner() { dx 'exec 3<>/dev/tcp/127.0.0.1/22 && timeout 5 head -n 1 <&3' | head -n 1; }
nkeys() { dx 'ls /etc/ssh | grep -c "^ssh_host_.*_key"'; }
fp() { dx 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | cut -d" " -f2'; }
state() { dx "systemctl is-active $1 2>/dev/null; true" | head -n 1; }

# ---------------------------------------------------------------------------------------------------------------------
# --selftest: the decisions above against a fake docker. Mutants: every way the probe's answers can be wrong must be named.
# ---------------------------------------------------------------------------------------------------------------------
selftest() {
    echo "== first-boot-units-boot.sh --selftest (no Docker): the containment logic"
    local FAKE_LOG="" FAKE_CREATE="" FAKE_OS="" FAKE_LS="" FAKE_LS_RC=0 FAKE_PROBE="" FAKE_RUN_RC=0 FAKE_HOST="Linux"
    docker() {
        FAKE_LOG="$FAKE_LOG
$*"
        case "$1" in
            create) FAKE_CREATE="$*" ;;
            info) printf '%s\n' "$FAKE_OS" ;;
            run) case "$*" in *binfmt:ro*) printf '%s' "$FAKE_LS"; return "$FAKE_LS_RC" ;; *) printf '%s\n' "$FAKE_PROBE"; return "$FAKE_RUN_RC" ;; esac ;;
            exec) printf '%s\n' "$FAKE_PROBE" ;;
        esac
        return 0
    }
    host_os() { echo "$FAKE_HOST"; }

    local good_c='binfmt_mounts=0
load_systemd-binfmt.service=masked
load_proc-sys-fs-binfmt_misc.automount=masked
load_proc-sys-fs-binfmt_misc.mount=masked
load_systemd-sysctl.service=masked
proc_sys=read-only
proc_sys_write=refused
binfmt_mount_attempt=refused'
    local rep

    # mode selection: only the exact value 1 leaves the contained profile
    check "mode: unset is contained" "$(unset CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED; select_mode)" "contained"
    check "mode: 0 is contained" "$(CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=0 select_mode)" "contained"
    check "mode: 'yes' is contained (only 1 counts)" "$(CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=yes select_mode)" "contained"
    check "mode: true is contained (only 1 counts)" "$(CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=true select_mode)" "contained"
    check "mode: 1 is privileged" "$(CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=1 select_mode)" "privileged"

    # what new_machine really asks docker for, contained: nothing that widens the container
    set_flags contained; make_masks
    new_machine st "$WORK/empty" 1 1 "$WORK/empty" "ro,size=1m"
    local bad="" t prev="" okv=1
    for t in --privileged --cap-add --security-opt --device --pid --uts --ipc --userns --net --network --volumes-from --sysctl --group-add --mount --cgroupns=private; do
        case " $FAKE_CREATE " in *" $t "*|*" $t="*) bad="$bad $t" ;; esac
    done
    check "contained create: no --privileged, capability, device, host namespace or security option" "$bad" ""
    for t in $FAKE_CREATE; do
        [[ "$prev" == -v && "$t" != /sys/fs/cgroup:/sys/fs/cgroup:rw ]] && okv=0
        prev="$t"
    done
    check "contained create: the only volume is the cgroup tree" "$okv" "1"
    has "contained create: cgroupns host (systemd needs its cgroup)" "$FAKE_CREATE" "--cgroupns=host"
    has "contained create: /run is a tmpfs" "$FAKE_CREATE" "--tmpfs /run "
    has "contained create: the optional /etc/ssh tmpfs is passed on" "$FAKE_CREATE" "--tmpfs /etc/ssh:ro,size=1m"
    has "contained create: runs /sbin/init" "$FAKE_CREATE" " /sbin/init"
    has "contained: the unit masks are copied in before the start" "$FAKE_LOG" "cp $WORK/mask/. $CT:/etc/systemd/system/"
    local nmask=0 u
    for u in $MASKED_UNITS; do [[ "$(readlink "$WORK/mask/$u")" == /dev/null ]] && nmask=$((nmask + 1)); done
    check "the mask directory holds a /dev/null symlink for each of the 4 units" "$nmask" "4"

    # privileged only by the switch, and still masked
    FAKE_LOG=""; set_flags privileged; new_machine st "$WORK/empty" 0 0
    has "privileged create (switch set): --privileged is there, so the switch is real" "$FAKE_CREATE" "--privileged"
    has "privileged: the masks are copied in as well" "$FAKE_LOG" "cp $WORK/mask/. $CT:/etc/systemd/system/"
    check "set_flags refuses an unknown mode" "$(set_flags bogus 2>&1; echo $?)" "1"
    set_flags contained

    # the engine hazard
    FAKE_OS="Docker Desktop"; FAKE_LS=""; engine_hazard; check "engine: Docker Desktop is a hazard (rc)" "$?" "0"
    has "  ... and says why" "$HAZARD_WHY" "Docker Desktop"
    FAKE_OS="OrbStack"; engine_hazard; check "engine: OrbStack is a hazard" "$?" "0"
    FAKE_OS="Ubuntu 26.04 LTS"; FAKE_LS=$'rosetta\nrosetta-wrapper\nregister\nstatus\n'; engine_hazard; check "engine: rosetta handlers visible on a plain Linux name are a hazard" "$?" "0"
    check "  ... the handlers are listed without register/status" "$ENGINE_HANDLERS" "rosetta rosetta-wrapper"
    FAKE_LS=$'register\nstatus\n'; engine_hazard; check "engine: Linux with an empty binfmt_misc is no hazard" "$?" "1"
    FAKE_LS=""; FAKE_LS_RC=1; engine_hazard; check "engine: Linux where the handlers cannot be read: could not tell" "$?" "2"
    FAKE_HOST=Darwin; engine_hazard; check "engine: a macOS host is a hazard whatever the engine calls itself" "$?" "0"
    FAKE_HOST=Linux; FAKE_LS_RC=0

    # the probe verdict and its mutants
    check "verdict: a contained container has no violation" "$(containment_violations "$good_c" 1 1)" ""
    check "verdict: the gate (no systemd) needs no masks" "$(containment_violations "$(printf '%s\n' "$good_c" | grep -v '^load_')" 0 1)" ""
    mutant() {   # mutant <label> <sed expression turning the good report into a bad one> <text the verdict must contain>
        rep="$(printf '%s\n' "$good_c" | sed "$2")"
        has "mutant: $1" "$(containment_violations "$rep" 1 1)" "$3"
    }
    mutant "binfmt_misc mounted in the container" 's/^binfmt_mounts=0/binfmt_mounts=1/' "binfmt_misc is mounted"
    mutant "no count at all (the grep itself failed)" '/^binfmt_mounts=/d' "binfmt_misc is mounted"
    mutant "systemd-binfmt.service not masked" 's/^load_systemd-binfmt.service=masked/load_systemd-binfmt.service=loaded/' "systemd-binfmt.service is not masked"
    mutant "the automount not masked" 's/^load_proc-sys-fs-binfmt_misc.automount=masked/load_proc-sys-fs-binfmt_misc.automount=not-found/' "proc-sys-fs-binfmt_misc.automount is not masked"
    mutant "the mount unit not masked" '/^load_proc-sys-fs-binfmt_misc.mount=/d' "proc-sys-fs-binfmt_misc.mount is not masked"
    mutant "systemd-sysctl.service not masked" 's/^load_systemd-sysctl.service=masked/load_systemd-sysctl.service=loaded/' "systemd-sysctl.service is not masked"
    mutant "/proc/sys writable" 's/^proc_sys=read-only/proc_sys=writable/' "/proc/sys is not read-only"
    mutant "a write to /proc/sys allowed" 's/^proc_sys_write=refused/proc_sys_write=allowed/' "write to /proc/sys was not refused"
    mutant "the container can mount binfmt_misc (the CAP_SYS_ADMIN case)" 's/^binfmt_mount_attempt=refused/binfmt_mount_attempt=succeeded/' "can mount binfmt_misc itself"
    mutant "the probe printed nothing" 's/.*//' "binfmt_misc is mounted"
    check "verdict: in privileged mode the active answers are not asked for" "$(containment_violations "$(printf '%s\n' "$good_c" | sed 's/^proc_sys=read-only/proc_sys=writable/;s/^binfmt_mount_attempt=refused/binfmt_mount_attempt=succeeded/')" 1 0)" ""

    # the gate and the per-boot check, with canned probe output
    FAKE_PROBE="$(printf '%s\n' "$good_c" | grep -v '^load_')"; FAKE_RUN_RC=0
    profile_gate; check "gate: a contained profile passes" "$?" "0"
    FAKE_PROBE="$(printf '%s\n' "$good_c" | grep -v '^load_' | sed 's/^binfmt_mount_attempt=refused/binfmt_mount_attempt=succeeded/')"
    profile_gate; check "gate: a profile that can mount binfmt_misc is stopped (rc 1)" "$?" "1"
    has "  ... and says what" "$GATE_WHY" "can mount binfmt_misc itself"
    FAKE_RUN_RC=125; profile_gate; check "gate: a probe container that does not run is rc 2, not a pass" "$?" "2"
    FAKE_RUN_RC=0
    FAKE_PROBE="$good_c"; ACTIVE_PROBE=1
    check "per-boot check: a contained container passes (no exit)" "$( (contain_or_die ct >/dev/null 2>&1; echo survived) )" "survived"
    FAKE_PROBE="$(printf '%s\n' "$good_c" | sed 's/^load_systemd-binfmt.service=masked/load_systemd-binfmt.service=loaded/')"
    check "per-boot check: an unmasked systemd-binfmt.service stops the test (exit 1)" "$( (contain_or_die ct >/dev/null 2>&1; echo survived); true )" ""

    echo
    echo "$PASS passed, $FAIL failed"
    [[ $FAIL -eq 0 ]]
}
if [[ "$SELFTEST" -eq 1 ]]; then selftest; exit $?; fi

# ---------------------------------------------------------------------------------------------------------------------
# The pieces under test, cut out of customize-chroot.sh exactly as shipped.
# ---------------------------------------------------------------------------------------------------------------------
sed -n '\%usr/lib/systemd/system/ci-os-first-boot-rebrand.service" << .SVCEOF.%,/^SVCEOF$/p' "$SCRIPT" | sed '1d;$d' >"$WORK/rebrand.service"
sed -n '\%usr/lib/ci-os/first-boot-rebrand.sh" << .REBRAND.%,/^REBRAND$/p' "$SCRIPT" | sed '1d;$d' >"$WORK/first-boot-rebrand.sh"
chmod 755 "$WORK/first-boot-rebrand.sh"
grep -q '^\[Unit\]' "$WORK/rebrand.service" && grep -q 'systemctl disable' "$WORK/first-boot-rebrand.sh" \
    || { echo "first-boot-units test: could not cut the rebrand unit and script out of $SCRIPT" >&2; exit 2; }
# The unit as it was before this fix: ConditionFirstBoot=yes in place of the stamp.
sed 's%^ConditionPathExists=!/var/lib/ci-os/.first-boot-rebrand-done$%ConditionFirstBoot=yes%' "$WORK/rebrand.service" >"$WORK/rebrand.service.old"

printf '7f3a1b9c2d4e4f5a8b6c0d1e2f3a4b5c\n' >"$WORK/id-installer"    # what subiquity copies: a valid ID
printf 'uninitialized\n' >"$WORK/id-uninitialized"                      # a true first boot (machine-id(5), rule 3)
: >"$WORK/empty"
cat >"$WORK/99-installer.cfg" <<'EOF'
datasource_list: [None]
datasource:
  None:
    metadata:
      instance-id: 5c0b8a62-3f9c-4d63-a0d4-2f5d8d0c1e11
    userdata_raw: |
      #cloud-config
      write_files:
      - path: /etc/cloud/cloud-init.disabled
        defer: true
        content: "Disabled by Ubuntu live installer after first boot.\n"
EOF
printf 'policy: enabled\n' >"$WORK/ds-identify.cfg"
make_masks || { echo "first-boot-units test: cannot create the unit masks in $WORK" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------------------------------
echo "== the image: Ubuntu 26.04 + systemd + openssh-server + cloud-init, host keys removed, build-time os-release"
mkdir -p "$WORK/ctx"
cp "$OSREL_LIB" "$WORK/ctx/os-release.sh"
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    cat >"$WORK/ctx/Dockerfile" <<'EOF'
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv dbus openssh-server cloud-init iproute2 >/dev/null \
 && rm -rf /var/lib/apt/lists/*
# What Step 11 leaves: no host keys. What the stock image has: an empty machine-id.
RUN rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub && : > /etc/machine-id
# What the build writes (Step 1: the one writer, backends/ubuntu/lib/os-release.sh) and the rebrand script reads.
COPY os-release.sh /usr/lib/ci-os/bootstrap/backends/ubuntu/lib/os-release.sh
RUN cp -L /etc/os-release /etc/os-release.ubuntu-base && cp -L /etc/os-release /root/os-release.stock \
 && CI_OS_VERSION=1.2.3 bash -c 'source /usr/lib/ci-os/bootstrap/backends/ubuntu/lib/os-release.sh; ci_os_write_branded_os_release /etc/os-release; ci_os_write_branded_lsb_release /etc/lsb-release' \
 && cp -L /etc/os-release /root/os-release.built && cp -L /etc/lsb-release /root/lsb-release.built && grep -q '^CI_OS_BUILD=' /root/os-release.built
# Step 1 records the build's version for the rebrand script and enables the service with this link.
RUN printf '1.2.3\n' > /usr/lib/ci-os/version && chmod 644 /usr/lib/ci-os/version \
 && mkdir -p /etc/systemd/system/multi-user.target.wants \
 && ln -s /usr/lib/systemd/system/ci-os-first-boot-rebrand.service /etc/systemd/system/multi-user.target.wants/ci-os-first-boot-rebrand.service
CMD ["/sbin/init"]
EOF
    if docker build -q -t "$IMG" "$WORK/ctx" >"$WORK/build.log" 2>&1; then BUILT_IMAGE=1; else cat "$WORK/build.log" >&2; echo "first-boot-units test: image build failed (no network?)" >&2; exit 2; fi
fi
pass "image $IMG is available"

# ---------------------------------------------------------------------------------------------------------------------
MODE="$(select_mode)"
set_flags "$MODE"
echo
echo "== the containers: mode '$MODE' (systemd as PID 1; see SAFETY in the header)"
engine_hazard; HAZ=$?
if [[ "$MODE" == privileged ]]; then
    ACTIVE_PROBE=0
    {
        echo "WARNING  CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=1: the containers below run --privileged, with systemd as PID 1."
        if [[ $HAZ -eq 0 ]]; then
            echo "WARNING  $HAZARD_WHY."
            echo "WARNING  A privileged systemd unregisters the kernel's binfmt_misc handlers (Rosetta, qemu-user): every amd64 container and"
            echo "WARNING  chroot on this engine can fail until it is restarted. The units that do it are masked here, but that was never"
            echo "WARNING  verified for a privileged container. Ctrl-C now and use a Linux host or VM instead, unless you accept that."
        elif [[ $HAZ -eq 2 ]]; then
            echo "WARNING  Could not tell whether this engine's kernel has binfmt_misc handlers that a privileged systemd would wipe."
        else
            echo "NOTE     Nothing suggests this engine's kernel has binfmt_misc handlers to lose (${ENGINE_OS:-unknown engine})."
        fi
    } >&2
    [[ $HAZ -eq 1 ]] || sleep 10          # the last chance to Ctrl-C; skipped only when nothing suggests a shared kernel with handlers
    echo "NOTE  containment gate skipped (privileged); the per-boot check below still verifies that binfmt_misc is not mounted and the units are masked"
else
    ACTIVE_PROBE=1
    case "$HAZ" in
        0) echo "NOTE  $HAZARD_WHY. None of it is reachable from the containers below (gate and per-boot checks)." ;;
        1) echo "NOTE  engine: ${ENGINE_OS:-unknown}; no binfmt_misc handlers are registered in its kernel" ;;
        *) echo "NOTE  engine: ${ENGINE_OS:-unknown}; the binfmt_misc handlers of its kernel could not be read (the gate below does not need them)" ;;
    esac
    profile_gate; GRC=$?
    case "$GRC" in
        0) pass "gate: a container with these flags and a plain shell has a read-only /proc/sys, its write is refused and mount -t binfmt_misc is refused" ;;
        1) fail "gate: the container flags can reach the engine's kernel state:$GATE_WHY"; echo "FATAL  no systemd container was started" >&2; echo; echo "$PASS passed, $FAIL failed"; exit 1 ;;
        *) echo "first-boot-units test: cannot run the containment gate: $GATE_WHY" >&2; exit 2 ;;
    esac
fi

# The drop-in resets ALL Condition lines of the unit, so it must restate every condition the package sets other than the one it
# drops. If a later openssh-server adds one, this fails and says which.
PACKAGED="$(docker run --rm "$IMG" cat /usr/lib/systemd/system/sshd-keygen.service)"
MISSING=""
while IFS= read -r line; do
    case "$line" in ""|ConditionFirstBoot=*) continue ;; esac
    grep -q -x -F -- "$line" "$DROPIN_DIR/10-ci-os-host-keys.conf" || MISSING="$MISSING [$line]"
done <<EOF
$(printf '%s\n' "$PACKAGED" | grep '^Condition')
EOF
check "the drop-in restates every other Condition of the packaged sshd-keygen.service" "$MISSING" ""
echo "NOTE  the packaged unit carries: $(printf '%s\n' "$PACKAGED" | grep -c '^ConditionFirstBoot=yes') x ConditionFirstBoot=yes (the reason for the drop-in; informational)"

docker run --rm "$IMG" cat /root/os-release.stock >"$WORK/os-release.stock" || { echo "first-boot-units test: cannot read the stock os-release from the image" >&2; exit 2; }

# A first container, to learn whether systemd runs as PID 1 under these flags at all. It is also the first one the per-boot check sees.
if ! { new_machine smoke "$WORK/id-installer" 0 0 && boot "$CT"; }; then
    {
        echo "first-boot-units test: systemd did not start as PID 1 in a '$MODE' container on this engine (${ENGINE_OS:-unknown})."
        if [[ "$MODE" == contained ]]; then
            echo "  The contained profile (no --privileged, no capability) needs a cgroup v2 engine that lets a container write its own cgroup tree."
            echo "  The test does NOT fall back to --privileged by itself: on an engine whose kernel is shared with other containers (Docker Desktop,"
            echo "  OrbStack, Colima, Rancher Desktop) that unregisters the Rosetta/qemu binfmt handlers of every container on the machine."
            echo "  Run it on a Linux host or VM. CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=1 selects --privileged (read the SAFETY section of this file first)."
        else
            echo "  Not even with --privileged. The contained profile was not tried because CI_OS_ALLOW_SYSTEMD_IN_PRIVILEGED=1 is set; unset it to try that."
        fi
    } >&2
    exit 2
fi
docker rm -f "$CT" >/dev/null 2>&1
pass "systemd runs as PID 1 under these flags (mode '$MODE')"

# ---------------------------------------------------------------------------------------------------------------------
echo
echo "== SSH host keys, machine installed from the live USB (valid machine-id copied from the live session)"

new_machine control "$WORK/id-installer" 0 0 && boot "$CT"
check "control, no drop-in: sshd-keygen.service is skipped" "$(state sshd-keygen.service)" "inactive"
has "  ... because ConditionFirstBoot=yes is not met" "$(dx 'systemctl status sshd-keygen.service --no-pager')" "ConditionFirstBoot=yes was not met"
check "  ... so there is no host key" "$(nkeys)" "0"
check "  ... and ssh does not answer on port 22" "$(banner | grep -c '^SSH-2.0-')" "0"
sleep 2
has "  ... because ssh.service fails in sshd -t" "$(dx 'journalctl -u ssh.service --no-pager | tail -n 20')" "no hostkeys available"

new_machine dropin "$WORK/id-installer" 1 0 && boot "$CT"
check "the drop-in is loaded" "$(dx 'systemctl show sshd-keygen.service -p DropInPaths --value')" "/etc/systemd/system/sshd-keygen.service.d/10-ci-os-host-keys.conf"
check "with the drop-in: sshd-keygen.service ran (ssh-keygen -A) and succeeded" "$(dx 'echo "$(systemctl show sshd-keygen.service -p Result --value) $(systemctl show sshd-keygen.service -p SubState --value)"')" "success exited"
check "  ... and made all three keys with their public halves (rsa, ecdsa, ed25519)" "$(nkeys)" "6"
has "  ... and ssh answers on port 22" "$(banner)" "SSH-2.0-OpenSSH"
check "  ... and ssh.service is running" "$(state ssh.service)" "active"
check "  ... and the system finished booting without a failed unit from ssh" "$(dx 'systemctl --failed --no-legend | grep -c ssh')" "0"
FP1="$(fp)"
[[ -n "$FP1" ]] && pass "  ... the ed25519 key has a fingerprint ($FP1)" || fail "  ... the ed25519 key has no fingerprint"
docker restart "$CT" >/dev/null && boot "$CT"
check "second boot: the keys are the same (never regenerated)" "$(fp)" "$FP1"
check "  ... the unit is skipped (an ed25519 key exists)" "$(state sshd-keygen.service)" "inactive"
has "  ... by ConditionPathExists" "$(dx 'systemctl status sshd-keygen.service --no-pager')" "ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key was not met"
has "  ... and ssh answers" "$(banner)" "SSH-2.0-OpenSSH"

# The conditions the package sets besides ConditionFirstBoot: an empty assignment drops ALL of them, so the drop-in restates them.
# Two machines that differ in one thing, /etc/ssh as an empty tmpfs that is read-only or writable (the first version remounted /etc/ssh
# read-only inside the container, which needs CAP_SYS_ADMIN; see SAFETY).
new_machine rossh "$WORK/id-installer" 1 0 "" "ro,mode=755,size=1m" && boot "$CT"
has "read-only /etc/ssh: the unit is still skipped (the package's own conditions survive)" "$(dx 'systemctl status sshd-keygen.service --no-pager')" "ConditionPathIsReadWrite=/etc/ssh was not met"
check "  ... so no key is made" "$(nkeys)" "0"
new_machine rwssh "$WORK/id-installer" 1 0 "" "rw,mode=755,size=1m" && boot "$CT"
check "the same machine with /etc/ssh writable (an empty tmpfs): the keys are made" "$(nkeys)" "6"

new_machine uninit "$WORK/id-uninitialized" 1 0 && boot "$CT"
check "a true first boot (machine-id 'uninitialized') with the drop-in: keys are made" "$(nkeys)" "6"
has "  ... and ssh answers" "$(banner)" "SSH-2.0-OpenSSH"

new_machine cloud "$WORK/id-installer" 1 1 && boot "$CT"
check "the installer's cloud-init path (datasource None, valid machine-id) with the drop-in: keys exist" "$(nkeys)" "6"
has "  ... and ssh answers" "$(banner)" "SSH-2.0-OpenSSH"
NSSH="$(dx 'grep -c "Running module ssh " /var/log/cloud-init.log')"
[[ "$NSSH" =~ ^[0-9]+$ && "$NSSH" -ge 1 ]] && pass "  ... cloud-init ran its ssh module (the installer's real path)" || fail "  ... cloud-init did not run its ssh module ($NSSH)"

# Evidence, not a requirement: is the unit-less case rescued by cloud-init alone? (It is on 26.04.1 / cloud-init 26.1.)
new_machine cloudonly "$WORK/id-installer" 0 1 && boot "$CT"
echo "NOTE  cloud-init alone, no drop-in: $(nkeys) key files, banner '$(banner)'  (informational: the drop-in does not rely on this)"

# ---------------------------------------------------------------------------------------------------------------------
echo
echo "== ci-os-first-boot-rebrand.service, machine installed from the live USB"

new_machine rb-old "$WORK/id-installer" 0 0 "$WORK/rebrand.service.old" && boot "$CT"
check "control, the old unit (ConditionFirstBoot=yes): skipped" "$(state ci-os-first-boot-rebrand.service)" "inactive"
has "  ... because ConditionFirstBoot=yes is not met" "$(dx 'systemctl status ci-os-first-boot-rebrand.service --no-pager')" "ConditionFirstBoot=yes was not met"
check "  ... so nothing was written" "$(dx 'test -e /var/lib/ci-os/.first-boot-rebrand-done && echo stamp || echo none')" "none"

new_machine rb "$WORK/id-installer" 0 0 "$WORK/rebrand.service" && boot "$CT"
has "the shipped unit is gated on a stamp, not on ConditionFirstBoot" "$(cat "$WORK/rebrand.service")" "ConditionPathExists=!/var/lib/ci-os/.first-boot-rebrand-done"
check "the shipped unit runs on the first boot of the installed machine and succeeds" "$(dx 'echo "$(systemctl show ci-os-first-boot-rebrand.service -p Result --value) $(systemctl show ci-os-first-boot-rebrand.service -p SubState --value)"')" "success exited"
check "  ... it leaves the stamp" "$(dx 'test -e /var/lib/ci-os/.first-boot-rebrand-done && echo stamp || echo none')" "stamp"
check "  ... it disables itself" "$(dx 'test -e /etc/systemd/system/multi-user.target.wants/ci-os-first-boot-rebrand.service && echo enabled || echo disabled')" "disabled"
check "  ... os-release is, byte for byte, what the build wrote (running it again is harmless)" "$(dx 'cmp -s /etc/os-release /root/os-release.built && echo same || echo different')" "same"
check "  ... and so is lsb-release" "$(dx 'cmp -s /etc/lsb-release /root/lsb-release.built && echo same || echo different')" "same"
check "  ... and the identity is Companion OS" "$(dx '. /etc/os-release; echo "$NAME|$ID|$CI_OS_ID|$VERSION_CODENAME|$CI_OS_VERSION"')" "Companion OS|ubuntu|ci-os|resolute|1.2.3"
dx 'ln -s /usr/lib/systemd/system/ci-os-first-boot-rebrand.service /etc/systemd/system/multi-user.target.wants/ci-os-first-boot-rebrand.service' >/dev/null
docker restart "$CT" >/dev/null && boot "$CT"
check "second boot, even re-enabled: skipped (the stamp)" "$(state ci-os-first-boot-rebrand.service)" "inactive"
has "  ... by the stamp" "$(dx 'systemctl status ci-os-first-boot-rebrand.service --no-pager')" "ConditionPathExists=!/var/lib/ci-os/.first-boot-rebrand-done was not met"

# base-files (or anything else) reset os-release to Ubuntu's while the system was being installed or updated: the point of the unit.
new_machine rb-reset "$WORK/id-installer" 0 0 "$WORK/rebrand.service" && docker cp "$WORK/os-release.stock" "$CT:/usr/lib/os-release" && boot "$CT"
check "an os-release reset to Ubuntu's is branded again (ignoring the build-day stamp)" \
    "$(dx 'diff <(grep -v ^CI_OS_BUILD= /etc/os-release) <(grep -v ^CI_OS_BUILD= /root/os-release.built) >/dev/null && echo same || echo different')" "same"
check "  ... the reset file really was Ubuntu's before (the check above can fail)" \
    "$(docker run --rm "$IMG" bash -c 'diff <(grep -v ^CI_OS_BUILD= /root/os-release.stock) <(grep -v ^CI_OS_BUILD= /root/os-release.built) >/dev/null && echo same || echo different')" "different"

mkdir -p "$WORK/cdrom/casper"; : >"$WORK/cdrom/casper/vmlinuz"
new_machine rb-live "$WORK/id-installer" 0 0 "$WORK/rebrand.service" && docker cp "$WORK/cdrom" "$CT:/cdrom" && boot "$CT"
check "a live session (/cdrom/casper/vmlinuz present): skipped" "$(state ci-os-first-boot-rebrand.service)" "inactive"
check "  ... and nothing was written" "$(dx 'test -e /var/lib/ci-os/.first-boot-rebrand-done && echo stamp || echo none')" "none"

echo
if [[ "$MODE" == contained ]]; then
    pass "all $CONTAINED_N systemd boots were contained: no --privileged, no capability, /proc/sys read-only and a write refused, mount -t binfmt_misc refused, binfmt_misc not mounted, binfmt and sysctl units masked"
else
    pass "all $CONTAINED_N systemd boots (privileged, by request) had binfmt_misc unmounted and the binfmt and sysctl units masked"
fi
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
