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
#               the package sets besides ConditionFirstBoot survive the reset); the cloud-init path of the real installer
#   rebrand     control (the old ConditionFirstBoot=yes unit): skipped. The shipped unit and script (cut out of
#               customize-chroot.sh): runs once, leaves os-release byte for byte what the build wrote, repairs an os-release
#               that was reset to Ubuntu's, never runs again (stamp), never runs in a live session (/cdrom/casper/vmlinuz)
#
# It needs docker (privileged containers, cgroup v2) and network for the first run (apt in the image build). Containers and
# the image are named ${CI_TEST_PREFIX:-ci-os-test-firstboot}-* and removed at the end (CI_TEST_KEEP=1 keeps the image).
# Host bash 3.2 is enough. Exit status is non-zero if a check fails; 2 if it cannot run here.
#
#   backends/ubuntu/chroot/tests/first-boot-units-boot.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../customize-chroot.sh"
DROPIN_DIR="$HERE/../payload/ssh/etc/systemd/system/sshd-keygen.service.d"
OSREL_LIB="$HERE/../../lib/os-release.sh"
[[ -f "$SCRIPT" && -f "$DROPIN_DIR/10-ci-os-host-keys.conf" && -f "$OSREL_LIB" ]] || { echo "missing customize-chroot.sh, the drop-in or os-release.sh" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "first-boot-units test: docker not found" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "first-boot-units test: the docker daemon is not reachable" >&2; exit 2; }

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

# ---------------------------------------------------------------------------------------------------------------------
# new_machine <name> <machine-id file> [with-dropin 0|1] [cloud-init 0|1] [rebrand unit file or ""]
# Creates (does not start) a container, so files can be placed before systemd reads them. Sets CT.
new_machine() {
    CT="$PREFIX-$1"
    docker rm -f "$CT" >/dev/null 2>&1
    docker create --name "$CT" --privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$IMG" /sbin/init >/dev/null || return 1
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
# boot <container>: start and wait until systemd has finished starting up (running or degraded).
boot() {
    docker start "$1" >/dev/null || return 1
    local st=""
    for _ in $(seq 1 150); do
        st="$(docker exec "$1" systemctl is-system-running 2>/dev/null)"
        case "$st" in running|degraded) return 0 ;; esac
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

docker run --rm "$IMG" cat /root/os-release.stock >"$WORK/os-release.stock" || { echo "first-boot-units test: cannot read the stock os-release from the image" >&2; exit 2; }

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
dx 'rm -f /etc/ssh/ssh_host_*; mount --bind /etc/ssh /etc/ssh && mount -o remount,ro,bind /etc/ssh; systemctl restart sshd-keygen.service' >/dev/null
has "read-only /etc/ssh: the unit is still skipped (the package's own conditions survive)" "$(dx 'systemctl status sshd-keygen.service --no-pager')" "ConditionPathIsReadWrite=/etc/ssh was not met"
dx 'umount /etc/ssh; systemctl restart sshd-keygen.service' >/dev/null
check "  ... and with /etc/ssh writable again the keys are made" "$(nkeys)" "6"

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
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
