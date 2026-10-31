#!/usr/bin/env bash
#=============================================================================
# Self-test of the installed-boot test's own parts (no Docker, no QEMU, a few seconds): the boot watcher's decisions against a fake
# QEMU, and the initrd audit against synthetic initramfs images.
#
#   backends/ubuntu/iso/tests/installed-boot.sh --selftest        (or run this file)
#
# Needs python3 (stdlib only), gzip; zstd is used when present. Exit status: 0 all passed, 1 a check failed, 2 cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "needs python3" >&2; exit 2; }
command -v gzip >/dev/null 2>&1 || { echo "needs gzip" >&2; exit 2; }

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

TMP="$(mktemp -d /tmp/ci-ibst.XXXXXX)"   # short: unix socket paths are limited to 104 bytes on macOS
trap 'rm -rf "$TMP"' EXIT

# ── boot-watch.py against the fake QEMU ─────────────────────────────────────────────────────────────────────────────
watch() { # watch <scenario> <expected exit> <expected text in REASON> [extra boot-watch args]
    local sc="$1" want="$2" text="$3" d="$TMP/$1" rc=0
    shift 3
    mkdir -p "$d"; : > "$d/serial.log"
    python3 -I "$LIB/boot-watch.py" --serial "$d/serial.log" --qmp "$d/q" --shots "$d/shots" --result "$d/boot-result.txt" \
        --timeline "$d/tl.txt" --timeout 40 --grace 6 --shot-interval 3 --poll 0.5 "$@" \
        -- python3 -I "$LIB/fake-qemu.py" --serial "$d/serial.log" --qmp "$d/q" --scenario "$sc" >"$d/out.txt" 2>&1 || rc=$?
    reason="$(sed -n 's/^REASON=//p' "$d/boot-result.txt" 2>/dev/null | head -1)"
    if [ "$rc" -eq "$want" ] && printf '%s' "$reason" | grep -qi -- "$text"; then t_pass "watcher, scenario $sc: exit $rc, \"${reason:0:90}\""
    else t_fail "watcher, scenario $sc: exit $rc (want $want), reason \"$reason\" (want it to contain \"$text\")"; fi
}
# The sockets need a short path: the scenario directories live under the short TMP.
watch casper 1 "casper"
watch casperloop 1 "casper"
watch pass 0 "greeter is up"
watch blank 1 "no drawn picture"
watch nogreeter 1 "no greeter"
watch exit 1 "exited early"
watch efishell 1 "found nothing to boot"
watch silent 1 "no serial output at all" --timeout 8
[ -s "$TMP/pass/shots/final.png" ] && t_pass "watcher: a final screenshot was written" || t_fail "watcher: no final.png after the pass scenario"
grep -q 'CI-PROBE-OK' "$TMP/pass/guest-report.txt" 2>/dev/null && t_pass "watcher: the probe report was saved" || t_fail "watcher: guest-report.txt lacks the probe's lines"

# ── installed-boot-probe.sh against fake systemctl, loginctl, pgrep and plymouth ─────────────────────────────────────────
# The probe runs inside the booted guest, so its own logic (which user's gnome-shell it waits for) is exercised here with stand-ins for the commands
# it calls. The greeter's gnome-shell runs as "gdm" up to GDM 46 and as a dynamic user "gdm-greeter" since GDM 50 (Ubuntu 26.04); the probe used to
# wait for gdm's and, on 26.04, sat out its whole limit with the greeter up (the screen had blanked when the host looked).
PB="$TMP/probe-bin"; mkdir -p "$PB"
cat > "$PB/systemctl" <<'EOF'
#!/bin/sh
case "$1" in is-active) echo active ;; is-system-running) echo running ;; esac
exit 0
EOF
cat > "$PB/loginctl" <<'EOF'
#!/bin/sh
# list-sessions: one greeter session; show-session <id> -p <Property> --value: the fake greeter session's properties
case "$1" in
    list-sessions) echo "c1 ${FAKE_GREETER_UID} ${FAKE_GREETER_USER} seat0 1449 greeter tty1 yes" ;;
    show-session) case "$4" in Class) echo greeter ;; Type) echo wayland ;; State) echo active ;; User) echo "${FAKE_GREETER_UID}" ;; Name) echo "${FAKE_GREETER_USER}" ;; esac ;;
esac
exit 0
EOF
cat > "$PB/pgrep" <<'EOF'
#!/bin/sh
# pgrep -u <user or uid> -x gnome-shell: a gnome-shell is running only as FAKE_SHELL_USER (its name) or FAKE_SHELL_UID
[ "$1" = -u ] && [ "$3" = -x ] && [ "$4" = gnome-shell ] || exit 1
[ "$2" = "${FAKE_SHELL_USER:-}" ] && exit 0
[ "$2" = "${FAKE_SHELL_UID:-}" ] && exit 0
exit 1
EOF
printf '#!/bin/sh\n[ -n "${FAKE_PLYMOUTH:-}" ] && exit 0   # plymouthd still answers\nexit 1                              # `plymouth --ping` fails: plymouthd is gone, the splash has handed over to the greeter\n' > "$PB/plymouth"
printf '#!/bin/sh\nexit 0\n' > "$PB/sleep"        # the probe's waits are not the test's
printf '#!/bin/sh\necho systemd\n' > "$PB/docker"   # `docker info --format {{.CgroupDriver}}`: the host's Docker is none of the probe test's business (and may hang)
chmod +x "$PB"/*
probe() { # probe <name> <greeter user> <greeter uid> <the user whose gnome-shell runs> <its uid> [limit [plymouth still running: any text]]: run the probe, print its OK/FAIL marker
    local out="$TMP/probe-$1.out"
    : > "$out"
    PATH="$PB:$PATH" CI_PROBE_TTY="$out" CI_PROBE_LIMIT="${6:-4}" FAKE_PLYMOUTH="${7:-}" FAKE_GREETER_USER="$2" FAKE_GREETER_UID="$3" FAKE_SHELL_USER="$4" FAKE_SHELL_UID="$5" \
        bash "${CI_PROBE_SCRIPT:-$LIB/installed-boot-probe.sh}" >/dev/null 2>&1 || true   # (CI_PROBE_SCRIPT: another copy, how the test itself is tested)
    grep -h -E '^CI-PROBE-(OK|FAIL)' "$out" | head -n 1
}
got="$(probe gdm50 gdm-greeter 60578 gdm-greeter 60578)"
case "$got" in "CI-PROBE-OK gdm greeter up"*"user=gdm-greeter"*) t_pass "probe: GDM 50's greeter (dynamic user gdm-greeter, uid 60578) is recognised: ${got:0:90}" ;; *) t_fail "probe: a GDM 50 greeter session was not recognised: '$got'" ;; esac
got="$(probe gdm46 gdm 120 gdm 120)"
case "$got" in "CI-PROBE-OK gdm greeter up"*"user=gdm"*) t_pass "probe: the older greeter (user gdm) is recognised too: ${got:0:90}" ;; *) t_fail "probe: a greeter run by gdm was not recognised: '$got'" ;; esac
got="$(probe noshell gdm-greeter 60578 nobody 4242 3)"
case "$got" in "CI-PROBE-FAIL the GDM greeter did not come up"*"its gnome-shell running: no"*) t_pass "probe: a greeter session without a gnome-shell of the session's user is not a greeter that is up (waits out the limit, then fails, and says why)" ;; *) t_fail "probe: reported '$got' for a greeter session whose gnome-shell is not running" ;; esac
got="$(probe wrongshell gdm-greeter 60578 gdm 120 3)"
case "$got" in "CI-PROBE-FAIL"*) t_pass "probe: a gnome-shell of another user (gdm) does not count as the greeter session's (the 26.04 case the probe got wrong the other way round)" ;; *) t_fail "probe: took another user's gnome-shell for the greeter's: '$got'" ;; esac
got="$(probe plymouth gdm-greeter 60578 gdm-greeter 60578 3 yes)"
case "$got" in "CI-PROBE-FAIL"*"plymouth running: yes"*) t_pass "probe: the greeter's gnome-shell is up but Plymouth still answers: not the login screen yet (FAIL at the limit, with the reason)" ;; *) t_fail "probe: reported '$got' while Plymouth was still running" ;; esac

# The memory facts (the memory-protection drop-ins, core/lib/memory-protection.sh): read from a fake cgroup tree (CI_PROBE_CGROUP). A unit that has
# no cgroup is said to have none, an unreadable file is said to be unreadable, and the verdict of the probe is still given, after the facts.
CG="$TMP/cg"; mkdir -p "$CG/system.slice/docker.service" "$CG/user.slice"
printf '42949672\n' > "$CG/system.slice/memory.min"; printf '214748364\n' > "$CG/system.slice/memory.low"; printf 'max\n' > "$CG/system.slice/memory.high"
printf '0\n' > "$CG/user.slice/memory.min"; printf '536870912\n' > "$CG/user.slice/memory.low"            # no memory.high file
printf '0\n' > "$CG/system.slice/docker.service/memory.min"; printf '64424509\n' > "$CG/system.slice/docker.service/memory.low"; printf 'max\n' > "$CG/system.slice/docker.service/memory.high"
printf 'cpu io memory pids\n' > "$CG/system.slice/cgroup.controllers"
MEMOUT="$TMP/probe-memory.out"; : > "$MEMOUT"
PATH="$PB:$PATH" CI_PROBE_TTY="$MEMOUT" CI_PROBE_LIMIT=4 FAKE_GREETER_USER=gdm-greeter FAKE_GREETER_UID=60578 FAKE_SHELL_USER=gdm-greeter FAKE_SHELL_UID=60578 CI_PROBE_CGROUP="$CG" \
    bash "${CI_PROBE_SCRIPT:-$LIB/installed-boot-probe.sh}" >/dev/null 2>&1 || true
memfact() { grep -q -F -- "$2" "$MEMOUT" && t_pass "$1" || t_fail "$1 (no line contains: $2)"; }
memfact "probe: system.slice's memory.min, memory.low and memory.high are printed as they are" "CI-PROBE: memory system.slice min=42949672 low=214748364 high=max active=active"
memfact "probe: a service cgroup is looked for under system.slice (docker.service)" "CI-PROBE: memory docker.service min=0 low=64424509 high=max active=active"
memfact "probe: user.slice, whose memory.high file is not there, is said to be unreadable there and nowhere else" "CI-PROBE: memory user.slice min=0 low=536870912 high=unreadable"
memfact "probe: a unit with no cgroup (ssh.service, started by its socket) is said to have none" "CI-PROBE: memory ssh.service cgroup-absent"
memfact "probe: ollama.service, whose ceiling is held back, is reported too" "CI-PROBE: memory ollama.service cgroup-absent"
memfact "probe: the memory controller list of system.slice is printed" "controllers-system.slice=cpu io memory pids"
memfact "probe: the Docker cgroup driver is printed" "CI-PROBE: docker-cgroup-driver=systemd"
memfact "probe: systemd-oomd (enabled or not) is printed" "CI-PROBE: systemd-oomd="
memfact "probe: the packaged ssh.socket is printed" "CI-PROBE: ssh.socket="
[ "$(grep -n '^CI-PROBE: memory system.slice' "$MEMOUT" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^CI-PROBE-OK' "$MEMOUT" | head -n 1 | cut -d: -f1)" ] 2>/dev/null \
    && t_pass "probe: the facts come before the verdict, and the verdict (OK) is still given" || t_fail "probe: the memory facts are missing or come after the verdict"

# ── install-source-layers.py against install-sources.yaml samples ─────────────────────────────────────────────────────
cat > "$TMP/is-v7.yaml" <<'EOF'
- default: true
  description:
    en: Companion OS (minimized)
  id: ubuntu-desktop-minimal
  path: minimal.squashfs
  preinstalled_langs: []
  type: fsimage-layered
  variations:
    minimal:
      path: minimal.squashfs
      size: 1
- default: false
  id: ubuntu-desktop
  path: minimal.standard.squashfs
  type: fsimage-layered
  variations:
    standard:
      path: minimal.standard.squashfs
EOF
cat > "$TMP/is-stock.yaml" <<'EOF'
- default: false
  id: ubuntu-desktop-minimal
  path: minimal.squashfs
- default: true
  id: ubuntu-desktop
  path: minimal.standard.live.squashfs
  variations:
    enhanced-secureboot:
      path: minimal.enhanced-secureboot.squashfs
EOF
# 26.04.1's file is a version 2 MAPPING (kernel:, sources:, version: 2); the sources are list items at column 0, so the parser needs no change
cat > "$TMP/is-v2.yaml" <<'EOF'
kernel:
  default: linux-generic-hwe-24.04
sources:
- default: true
  id: ubuntu-desktop-minimal
  path: minimal.squashfs
  variations:
    minimal:
      path: minimal.squashfs
    minimal-enhanced-secureboot:
      path: minimal.enhanced-secureboot.squashfs
      snapd_system_label: enhanced-secureboot-desktop
- default: false
  id: ubuntu-desktop
  path: minimal.standard.squashfs
  variations:
    enhanced-secureboot:
      path: minimal.standard.enhanced-secureboot.squashfs
    standard:
      path: minimal.standard.squashfs
version: 2
EOF
layers() { python3 -I "$LIB/install-source-layers.py" "$@" 2>&1 | tr '\n' ' ' || :; }
got="$(layers "$TMP/is-v7.yaml")"
[ "$got" = "minimal.squashfs " ] && t_pass "install sources: the default entry first in the file is minimal.squashfs alone" || t_fail "install sources v7: got '$got'"
got="$(layers "$TMP/is-stock.yaml")"
[ "$got" = "minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs " ] && t_pass "install sources: a.b.c.squashfs is the stack a, a.b, a.b.c" || t_fail "install sources stock: got '$got'"
got="$(layers "$TMP/is-v7.yaml" ubuntu-desktop)"
[ "$got" = "minimal.squashfs minimal.standard.squashfs " ] && t_pass "install sources: an entry can be picked by id; variations' paths are not read" || t_fail "install sources by id: got '$got'"
got="$(layers "$TMP/is-v2.yaml")"
[ "$got" = "minimal.squashfs " ] && t_pass "install sources: a version 2 mapping (kernel: block, sources:, version: 2) gives the default entry's layer, minimal.squashfs alone" || t_fail "install sources v2: got '$got'"
got="$(layers "$TMP/is-v2.yaml" ubuntu-desktop)"
[ "$got" = "minimal.squashfs minimal.standard.squashfs " ] && t_pass "install sources: v2, the standard entry by id is minimal + minimal.standard (the variations' enhanced-secureboot paths are not read)" || t_fail "install sources v2 by id: got '$got'"
got="$(layers "$TMP/is-v7.yaml" nosuch)"
case "$got" in *"no id: nosuch entry"*) t_pass "install sources: an unknown id is an error" ;; *) t_fail "install sources unknown id: got '$got'" ;; esac

# ── initrd-audit.py against synthetic images ─────────────────────────────────────────────────────────────────────────
while IFS= read -r l; do
    case "$l" in PASS*) PASS=$((PASS + 1)) ;; FAIL*) FAIL=$((FAIL + 1)) ;; esac
    printf '%s\n' "$l"
done < <(python3 -I "$LIB/selftest-initrd.py" "$TMP" "$LIB" 2>&1)

# With CI_TEST_STOCK_INITRD=<the casper/initrd of the Ubuntu 26.04.1 ISO> the audit is also run on the real thing: three uncompressed early
# archives (AMD and Intel microcode, 1 783 firmware entries) and a zstd main archive of 1 104 entries that holds casper (it is the LIVE initrd),
# so the audit must read all four segments and find casper in the last (needs zstd).
if [ -n "${CI_TEST_STOCK_INITRD:-}" ]; then
    if [ -f "$CI_TEST_STOCK_INITRD" ] && command -v zstd >/dev/null 2>&1; then
        res="$(python3 -I "$LIB/initrd-audit.py" "$CI_TEST_STOCK_INITRD" 2>&1 || true)"
        entries="$(printf '%s\n' "$res" | awk '$1 == "entries" { print $2 }')"; total="$(printf '%s\n' "$res" | awk '$1 == "total" { print $2 }')"
        if [ "${entries:-0}" -ge 2800 ] && [ "${total:-0}" -ge 30 ] && printf '%s\n' "$res" | grep -q 'default-boot-to-casper.conf'; then
            t_pass "real stock casper/initrd: $entries entries over its four segments, $total of them casper's, default-boot-to-casper.conf found"
        else t_fail "real stock casper/initrd: entries=${entries:-?} total=${total:-?} ($(printf '%s' "$res" | head -n 3 | tr '\n' '|'))"; fi
    else t_fail "CI_TEST_STOCK_INITRD is not a file, or zstd is missing"; fi
fi

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
