#!/usr/bin/env bash
# Memory protection of Companion OS: the five systemd drop-ins that keep the recovery path reachable and the desktop responsive when
# memory is short, and the lint that keeps them honest. Sourced by customize-chroot.sh (Step 10h), by both verify-iso.sh and by the tests;
# never run. Written for bash 3.2 (a stock macOS): no mapfile, no associative arrays, no ${v,,}. [I] until the VM runs of
# docs/guides/testing-in-qemu.md ("Memory protection runs") are recorded; nothing here proves what the kernel does with the values.
# shellcheck shell=bash
#
# What ships. One file per unit, /etc/systemd/system/<unit>.d/30-ci-os-memory.conf, mode 0644, on both editions (the SSH daemon is
# ssh.service on Ubuntu and sshd.service on CachyOS):
#
#   unit                                   key         value   why
#   ssh.service / sshd.service             MemoryMin   1%      the way in for a person who has to look at a thrashing machine
#   system.slice                           MemoryMin   2%      the parent must hold more than its children claim, or theirs is not effective
#   system.slice                           MemoryLow   10%     a shared best-effort share for the system daemons and the containers
#   docker.service, containerd.service     MemoryLow   3%      the engine daemons (the containers are scopes of system.slice, not of these)
#   user.slice                             MemoryLow   25%     the desktop session; given back before anything is killed
#
# Every value is a whole percentage of installed RAM, which systemd resolves when it loads the unit: no first-boot step, no per-machine
# state, and a small machine is not starved. No MemoryMax, MemorySwapMax or infinity anywhere: a ceiling that kills is not this change's
# to ship. A MemoryHigh ceiling for ollama.service is held back (deferred item B1-ollama-high: unmeasured, and whether GPU buffer memory
# is charged to the Ollama cgroup on a unified-memory machine is UNKNOWN); the lint already accepts an ollama.service file, so the item
# is one file away once the 6 and 16 GiB runs are recorded.
#
# Off-switch: delete the five 30-ci-os-memory.conf files (and, on CachyOS, their lines in usr/share/ci-os/installed/carry-over.list).
#
# The lint. ci_os_memprot_lint ROOT EDITION reads the drop-ins under ROOT/etc/systemd/system and prints one "FAIL: ..." line per
# problem; it returns 1 if there was one, 2 for a bad call. The invariants (a proposal that breaks one fails), each computed in bytes
# at 2, 4, 6, 8, 16, 32 and 64 GiB of RAM:
#   1. for system.slice, the sum of what its children claim (ssh, docker, containerd, and ollama when a file for it exists) is below
#      its own value, for MemoryMin and for MemoryLow. Below, not "at most": the parent keeps at least one point of slack for services
#      that are not listed (the design table's "1% plus slack"), and a child that equals its parent has no sibling to share with;
#   2. every MemoryMin together (a child's value is also part of its parent's, so this overcounts on purpose) is below 5% of RAM:
#      protecting more than is generally available can cause constant OOM kills;
#   3. with an ollama.service file, user.slice MemoryLow plus ollama.service MemoryHigh is at most 100% of RAM;
#   4. no MemoryMax, MemorySwapMax, MemoryZSwapMax or infinity;
#   5. every value is a whole percentage from 1% to 100% (no decimals, no bytes), every key is one of MemoryMin MemoryLow MemoryHigh and
#      sits in the section of its unit type ([Slice] for *.slice, [Service] for *.service), every file is a regular file of mode 0644
#      in a directory that is not a symlink (a *.conf of these units that is a symlink or a FIFO is reported and never opened), and the
#      file of each expected unit exists and sets the keys that unit needs;
#   6. the effective value of a key is the LAST assignment, in C-locale order of the *.conf files of ROOT/etc/systemd/system/<unit>.d/
#      (a later file that resets or lowers it counts).
# Not read: drop-ins that a package ships under /usr/lib/systemd/system (their order against ours is by file name across directories),
# and /run. The packages of both bases ship no Memory* setting for these units [I]; the VM runs read the cgroup files and settle it.
#
# Dynamic scope: ci_os_memprot_lint keeps the effective values in eff_<role>_<key> / src_<role>_<key> variables that the invariant
# functions read; it unsets them again before it returns.

CI_OS_MEMPROT_FILE="30-ci-os-memory.conf"
CI_OS_MEMPROT_RAM_MIB="2048 4096 6144 8192 16384 32768 65536"
CI_OS_MEMPROT_SYSTEM_CHILDREN="ssh docker containerd ollama"

# What each unit needs, as "role:key" pairs (the role names are the lint's: the SSH daemon is "ssh" on both editions).
CI_OS_MEMPROT_REQUIRED="ssh:MemoryMin system:MemoryMin system:MemoryLow docker:MemoryLow containerd:MemoryLow user:MemoryLow ollama:MemoryHigh"

# The awk program of the lint: reads one path per line (the *.conf files of the unit directories, in the order systemd reads them),
# prints "FAIL: ..." for a file-content problem and "EFF role key value file" for each key that has an effective value ("-" = none).
# Variables: root (with a trailing slash), sshunit (this edition's SSH daemon), memfile (the name of our drop-in).
IFS= read -r -d '' CI_OS_MEMPROT_AWK <<'AWKEOF' || true
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function rel(p) { return (index(p, root) == 1) ? substr(p, length(root) + 1) : p }
function role_of(u) {
    if (u == sshunit) return "ssh"
    if (u == "system.slice") return "system"
    if (u == "user.slice") return "user"
    if (u == "docker.service") return "docker"
    if (u == "containerd.service") return "containerd"
    if (u == "ollama.service") return "ollama"
    return ""
}
function bad(msg) { print "FAIL: " msg }
function scan(path,    n, parts, base, unit, role, ours, utype, section, line, rc, ln, eq, key, val, where, v2, pct) {
    n = split(path, parts, "/")
    base = parts[n]
    unit = parts[n - 1]
    sub(/\.d$/, "", unit)
    role = role_of(unit)
    if (role == "") return
    ours = (base == memfile)
    utype = (unit ~ /\.slice$/) ? "Slice" : "Service"
    section = ""
    ln = 0
    while ((rc = (getline line < path)) > 0) {
        ln++
        line = trim(line)
        if (line == "" || line ~ /^[#;]/) continue
        where = rel(path) ":" ln
        if (line ~ /^\[.*\]$/) { section = substr(line, 2, length(line) - 2); continue }
        eq = index(line, "=")
        if (eq == 0) {
            if (ours) bad(where ": not an assignment: " line)
            continue
        }
        key = trim(substr(line, 1, eq - 1))
        val = trim(substr(line, eq + 1))
        if (!ours && key !~ /^Memory(Min|Low|High|Max|SwapMax|ZSwapMax)$/) continue
        if (key ~ /^Memory(Max|SwapMax|ZSwapMax)$/) { bad(where ": " key " is not allowed: it ends in the OOM killer inside the unit (the ceiling is MemoryHigh, and none ships)"); continue }
        if (key != "MemoryMin" && key != "MemoryLow" && key != "MemoryHigh") { bad(where ": " key " is not one of MemoryMin, MemoryLow, MemoryHigh"); continue }
        if (section != utype) { bad(where ": " key " is " (section == "" ? "outside any section" : "in [" section "]") ", but a *" (utype == "Slice" ? ".slice" : ".service") " unit reads it in [" utype "]: systemd would ignore it"); continue }
        v2 = val
        if (val == "infinity") { bad(where ": " key "=infinity is not allowed: every value here is a whole percentage of installed RAM"); v2 = "" }
        else if (val !~ /^[1-9][0-9]*%$/) { bad(where ": " key "=" val " is not a whole percentage from 1% to 100%"); v2 = "" }
        else { pct = substr(val, 1, length(val) - 1) + 0; if (pct > 100) { bad(where ": " key "=" val " is not a whole percentage from 1% to 100%"); v2 = "" } }
        eff[role, key] = v2; src[role, key] = base
    }
    if (rc < 0) bad(rel(path) ": cannot be read")
    close(path)
}
{ scan($0) }
END { for (k in eff) { split(k, a, SUBSEP); print "EFF " a[1] " " a[2] " " (eff[k] == "" ? "-" : eff[k]) " " src[k] } }
AWKEOF

# ci_os_memprot_units EDITION: the units that must have a drop-in, one per line. An ollama.service file is optional and not listed.
ci_os_memprot_units() {
    case "${1:-}" in
        ubuntu) printf '%s\n' system.slice user.slice ssh.service docker.service containerd.service ;;
        cachyos) printf '%s\n' system.slice user.slice sshd.service docker.service containerd.service ;;
        *) echo "ci_os_memprot_units: the edition is ubuntu or cachyos (got '${1:-}')" >&2; return 2 ;;
    esac
}

# _ci_os_memprot_b PERCENT RAM_MIB: sets _CI_B to PERCENT of RAM_MIB MiB in bytes, rounded down (no subshell, no fork). This is what systemd
# resolves a limit to. _ci_os_memprot_bc rounds up: the invariants round what a unit CLAIMS up and what a parent HOLDS down, so that a
# violation of the percentages shows at every RAM size and rounding can never hide one.
_ci_os_memprot_b() { _CI_B=$(($2 * 1048576 * $1 / 100)); }
_ci_os_memprot_bc() { _CI_B=$((($2 * 1048576 * $1 + 99) / 100)); }

# ci_os_memprot_bytes VALUE MEM_MIB: VALUE ("25%": a whole percentage from 1% to 100%) of MEM_MIB MiB, in bytes, rounded down.
# Prints nothing and returns 2 for anything else.
ci_os_memprot_bytes() {
    local v="${1:-}" mib="${2:-}" pct
    case "$v" in [1-9]*%) ;; *) return 2 ;; esac
    pct="${v%\%}"
    case "$pct" in *[!0-9]*) return 2 ;; esac
    [ "${#pct}" -le 3 ] && [ "$pct" -le 100 ] || return 2
    case "$mib" in [1-9]*) ;; *) return 2 ;; esac
    case "$mib" in *[!0-9]*) return 2 ;; esac
    [ "${#mib}" -le 9 ] || return 2
    _ci_os_memprot_b "$pct" "$mib"
    printf '%s\n' "$_CI_B"
}

# _ci_os_memprot_get ROLE KEY: sets _CI_E to the effective percentage as a number (0 when the key has no valid value).
_ci_os_memprot_get() {
    local n="eff_${1}_${2}"
    _CI_E="${!n:-}"
    _CI_E="${_CI_E%\%}"
    [ -n "$_CI_E" ] || _CI_E=0
}

# _ci_os_memprot_gib RAM_MIB: the size as the messages say it.
_ci_os_memprot_gib() { printf '%s GiB' "$(($1 / 1024))"; }

# Invariant 1 (see the header). Prints a FAIL line and returns 1, or returns 0. Each of 1 to 3 takes the RAM size in MiB.
_ci_os_memprot_inv1() {
    local ram="$1" key role psum sum_b par_pct par_b
    for key in MemoryMin MemoryLow; do
        sum_b=0; psum=0
        for role in $CI_OS_MEMPROT_SYSTEM_CHILDREN; do
            _ci_os_memprot_get "$role" "$key"; psum=$((psum + _CI_E))
            _ci_os_memprot_bc "$_CI_E" "$ram"; sum_b=$((sum_b + _CI_B))
        done
        [ "$psum" -gt 0 ] || continue
        _ci_os_memprot_get system "$key"; par_pct="$_CI_E"
        _ci_os_memprot_b "$par_pct" "$ram"; par_b="$_CI_B"
        if ! [ "$sum_b" -lt "$par_b" ]; then
            printf 'FAIL: invariant 1: %s of system.slice is %s%%, which does not exceed the %s%% its children claim: their protection would not be fully effective, and no share is left for the other services (first at %s of RAM)\n' \
                "$key" "$par_pct" "$psum" "$(_ci_os_memprot_gib "$ram")"
            return 1
        fi
    done
    return 0
}

# Invariant 2: all hard minimums together stay below 5% of RAM.
_ci_os_memprot_inv2() {
    local ram="$1" role total_b=0 ptotal=0 lim_b
    for role in ssh system user docker containerd ollama; do
        _ci_os_memprot_get "$role" MemoryMin; ptotal=$((ptotal + _CI_E))
        _ci_os_memprot_bc "$_CI_E" "$ram"; total_b=$((total_b + _CI_B))
    done
    _ci_os_memprot_b 5 "$ram"; lim_b="$_CI_B"
    if ! [ "$total_b" -lt "$lim_b" ]; then
        printf 'FAIL: invariant 2: the MemoryMin values add up to %s%% of RAM, which is not below 5%%: protecting more than is generally available can cause constant OOM kills (first at %s of RAM)\n' \
            "$ptotal" "$(_ci_os_memprot_gib "$ram")"
        return 1
    fi
    return 0
}

# Invariant 3: with a ceiling for ollama.service, the protected desktop share and the ceiling fit in RAM together.
_ci_os_memprot_inv3() {
    local ram="$1" high low high_b low_b all_b
    _ci_os_memprot_get ollama MemoryHigh; high="$_CI_E"
    [ "$high" -gt 0 ] || return 0
    _ci_os_memprot_get user MemoryLow; low="$_CI_E"
    _ci_os_memprot_bc "$high" "$ram"; high_b="$_CI_B"
    _ci_os_memprot_bc "$low" "$ram"; low_b="$_CI_B"
    _ci_os_memprot_b 100 "$ram"; all_b="$_CI_B"
    if ! [ $((low_b + high_b)) -le "$all_b" ]; then
        printf 'FAIL: invariant 3: user.slice MemoryLow (%s%%) plus ollama.service MemoryHigh (%s%%) is %s%% of RAM, more than all of it: the ceiling would push the protected desktop share out (first at %s of RAM)\n' \
            "$low" "$high" "$((low + high))" "$(_ci_os_memprot_gib "$ram")"
        return 1
    fi
    return 0
}

# _ci_os_memprot_clear: forget the effective values of an earlier run.
_ci_os_memprot_clear() {
    local r k
    for r in ssh system user docker containerd ollama; do
        for k in MemoryMin MemoryLow MemoryHigh; do unset "eff_${r}_${k}" "src_${r}_${k}"; done
    done
}

# _ci_os_memprot_unit_of ROLE SSHUNIT: sets _CI_U to the unit name of a role.
_ci_os_memprot_unit_of() {
    case "$1" in
        ssh) _CI_U="$2" ;;
        system) _CI_U=system.slice ;;
        user) _CI_U=user.slice ;;
        docker) _CI_U=docker.service ;;
        containerd) _CI_U=containerd.service ;;
        ollama) _CI_U=ollama.service ;;
        *) _CI_U="$1" ;;
    esac
}

# ci_os_memprot_lint ROOT EDITION: see the header. ROOT is a tree with etc/systemd/system (the image payload, an overlay, or an extracted image).
ci_os_memprot_lint() {
    local root="${1:-}" edition="${2:-}" etc prefix units sshu u d f r rc=0 out line rest role key val srcf ram i bad p unit nl k mode want
    nl='
'
    units="$(ci_os_memprot_units "$edition")" || return 2
    case "$edition" in ubuntu) sshu=ssh.service ;; *) sshu=sshd.service ;; esac
    if [ -z "$root" ] || [ ! -d "$root/etc/systemd/system" ]; then
        echo "FAIL: ${root:-<no root>}/etc/systemd/system is not a directory: there are no drop-ins to read"
        return 1
    fi
    prefix="${root%/}/"
    etc="${prefix}etc/systemd/system"
    _ci_os_memprot_clear

    # The file of each expected unit exists, is a regular file, and the directory around it is not a link.
    for u in $units; do
        d="$etc/$u.d"; f="$d/$CI_OS_MEMPROT_FILE"; r="etc/systemd/system/$u.d/$CI_OS_MEMPROT_FILE"
        if [ -L "$d" ]; then echo "FAIL: etc/systemd/system/$u.d is a symlink: the drop-in must sit in a real directory"; rc=1
        elif [ -L "$f" ]; then echo "FAIL: $r is a symlink: it must be a regular file"; rc=1
        elif [ ! -f "$f" ]; then echo "FAIL: $r is missing: $u has no memory protection"; rc=1
        fi
    done
    # Mode 0644, like every other drop-in of the images.
    bad="$(find "$etc" -mindepth 2 -maxdepth 2 -type f -name "$CI_OS_MEMPROT_FILE" ! -perm 644 2>/dev/null | LC_ALL=C sort)"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        mode="$(stat -c %a "$p" 2>/dev/null || stat -f %Lp "$p" 2>/dev/null)"
        echo "FAIL: ${p:${#prefix}} is mode ${mode:-unknown}, not 0644"; rc=1
    done <<EOF
$bad
EOF
    # No file of ours for a unit that is not on this edition's list (the other edition's SSH name, a stray copy).
    bad="$(find "$etc" -mindepth 2 -maxdepth 2 -name "$CI_OS_MEMPROT_FILE" 2>/dev/null | LC_ALL=C sort)"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        unit="${p%/*}"; unit="${unit##*/}"; unit="${unit%.d}"
        case "$nl$units$nl" in *"$nl$unit$nl"*) continue ;; esac
        [ "$unit" = ollama.service ] && continue
        want=""
        case "$unit" in ssh.service|sshd.service) want=" (this edition's SSH daemon is $sshu)" ;; esac
        echo "FAIL: ${p:${#prefix}} belongs to no unit of the $edition edition$want"; rc=1
    done <<EOF
$bad
EOF

    # A *.conf of these units' directories that is not a regular file cannot be judged: a symlink may point at anything (or at /dev/null, which masks
    # the drop-in), and a FIFO or a device would block the reader. Our own file of a listed unit was reported above.
    bad="$(find "$etc" -mindepth 2 -maxdepth 2 -name '*.conf' ! -type f 2>/dev/null | LC_ALL=C sort)"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        unit="${p%/*}"; unit="${unit##*/}"; unit="${unit%.d}"
        case "$nl$units$nl" in *"$nl$unit$nl"*) k=1 ;; *) k=0 ;; esac
        [ "$k" = 1 ] || [ "$unit" = ollama.service ] || continue
        [ "$k" = 1 ] && [ "${p##*/}" = "$CI_OS_MEMPROT_FILE" ] && continue
        if [ -L "$p" ]; then echo "FAIL: ${p:${#prefix}} is a symlink: a drop-in of this unit must be a regular file, so that what it sets can be read"
        else echo "FAIL: ${p:${#prefix}} is not a regular file: a drop-in of this unit must be one, so that what it sets can be read"; fi
        rc=1
    done <<EOF
$bad
EOF

    # The content of every regular *.conf of the expected units' directories (and of ollama.service's), in the order systemd reads them.
    out="$(find "$etc" -mindepth 2 -maxdepth 2 -type f -name '*.conf' 2>/dev/null | LC_ALL=C sort \
        | awk -v root="$prefix" -v sshunit="$sshu" -v memfile="$CI_OS_MEMPROT_FILE" "$CI_OS_MEMPROT_AWK")"
    while IFS= read -r line; do
        case "$line" in
            "FAIL: "*) printf '%s\n' "$line"; rc=1 ;;
            "EFF "*)
                rest="${line#EFF }"; role="${rest%% *}"; rest="${rest#* }"; key="${rest%% *}"; rest="${rest#* }"; val="${rest%% *}"; srcf="${rest#* }"
                [ "$val" = - ] && val=""
                printf -v "eff_${role}_${key}" '%s' "$val"
                printf -v "src_${role}_${key}" '%s' "$srcf"
                ;;
        esac
    done <<EOF
$out
EOF

    # Each unit sets the keys it needs. The file of ollama.service is optional, but if it is there it sets its ceiling. A key that was
    # assigned something invalid has already been reported above; only a key nobody assigned is reported here.
    for p in $CI_OS_MEMPROT_REQUIRED; do
        role="${p%%:*}"; key="${p#*:}"
        if [ "$role" = ollama ] && [ ! -e "$etc/ollama.service.d/$CI_OS_MEMPROT_FILE" ] && [ ! -L "$etc/ollama.service.d/$CI_OS_MEMPROT_FILE" ]; then continue; fi
        k="src_${role}_${key}"
        if [ -z "${!k:-}" ]; then
            _ci_os_memprot_unit_of "$role" "$sshu"
            echo "FAIL: $_CI_U: $key is not set in any drop-in of etc/systemd/system/$_CI_U.d: the unit needs it"; rc=1
        fi
    done

    # The invariants, at each RAM size. An invariant that fails reports once, for the first size at which it does.
    for i in 1 2 3; do
        for ram in $CI_OS_MEMPROT_RAM_MIB; do
            if ! "_ci_os_memprot_inv$i" "$ram"; then rc=1; break; fi
        done
    done
    _ci_os_memprot_clear
    return "$rc"
}

# _ci_os_memprot_same A B: the two files have the same bytes (cmp, else a hash: a minimal image may have no diffutils).
_ci_os_memprot_same() {
    if command -v cmp >/dev/null 2>&1; then cmp -s "$1" "$2"; return; fi
    local ha hb
    if command -v sha256sum >/dev/null 2>&1; then ha="$(sha256sum "$1" | cut -d' ' -f1)"; hb="$(sha256sum "$2" | cut -d' ' -f1)"
    else ha="$(shasum -a 256 "$1" | cut -d' ' -f1)"; hb="$(shasum -a 256 "$2" | cut -d' ' -f1)"; fi
    [ -n "$ha" ] && [ "$ha" = "$hb" ]
}

# ci_os_memprot_parity UBUNTU_PAYLOAD_ROOT CACHYOS_FILES_ROOT: the five drop-ins are byte for byte the same on both editions (the SSH
# daemon's is ssh.service.d on Ubuntu and sshd.service.d on CachyOS; its text names both). One "FAIL: ..." line per difference.
ci_os_memprot_parity() {
    local ub="${1:-}" cx="${2:-}" u c a b rc=0
    for u in $(ci_os_memprot_units ubuntu); do
        c="$u"; [ "$u" = ssh.service ] && c=sshd.service
        a="$ub/etc/systemd/system/$u.d/$CI_OS_MEMPROT_FILE"; b="$cx/etc/systemd/system/$c.d/$CI_OS_MEMPROT_FILE"
        if [ ! -f "$a" ]; then echo "FAIL: parity: the Ubuntu file for $u is missing"; rc=1; continue; fi
        if [ ! -f "$b" ]; then echo "FAIL: parity: the CachyOS file for $c is missing"; rc=1; continue; fi
        if ! _ci_os_memprot_same "$a" "$b"; then echo "FAIL: parity: the Ubuntu file for $u and the CachyOS file for $c differ"; rc=1; fi
    done
    return "$rc"
}
