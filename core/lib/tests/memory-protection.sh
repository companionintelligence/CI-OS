#!/usr/bin/env bash
#=============================================================================
# Test: the memory-protection drop-ins and the lint that keeps them honest (core/lib/memory-protection.sh)
#
# What it shows, in order:
#   1. the library by itself: it prints nothing when sourced, keeps to its own names, lists the units of each edition, and turns a
#      percentage into bytes the way systemd would (rounded down) and refuses everything that is not a whole percentage;
#   2. the files that ship: the lint passes on the Ubuntu payload and on the CachyOS overlay (at 2, 4, 6, 8, 16, 32 and 64 GiB of RAM),
#      the two editions' files are byte for byte the same, the values are the ones the documents quote, the CachyOS carry-over list
#      names all five;
#   3. planted defects in copies of those trees, each of which must turn the lint red with its own message: a value edited in one
#      edition only (parity), system.slice MemoryMin dropped to 1%, ssh raised to 3%, an ollama.service ceiling that does not fit next to
#      the session's MemoryLow, and the fixture roots of the brief: a unit's file missing, a value without "%", MemoryMax, a key typed
#      Memorylow, [Service] in a slice file, a later 99-x.conf that resets MemoryMin=0, an ollama.service file with infinity, an ssh
#      drop-in in a CachyOS tree, a symlink, a mode 0600 file (and a few more, listed in the table);
#   4. weakened copies of the library (one decisive line changed per copy, the way backends/ubuntu/chroot/tests/models-mutation.sh does it
#      for the model tooling), run on those defect trees: each weakening must make at least one of the fixtures designated for it stop
#      producing its message. A weakening that no fixture notices fails the suite, and so does a replacement that matched nothing;
#   5. the same trees minus the defect: green again, and silent; a symlink or a FIFO named like a drop-in is reported and never opened;
#   6. what the lint must leave alone (neighbouring drop-ins, other units, comments, a ceiling that fits).
#
# It cannot say what the kernel does with the values: that is a boot (docs/guides/testing-in-qemu.md, "Memory protection runs").
#
# Pure bash (3.2 safe), awk, sed, find, no root, no network, no systemd. Writes only to a temporary directory.
#   bash core/lib/tests/memory-protection.sh
# Exit status: 0 all passed, 1 a check failed, 2 cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
LIB="$REPO/core/lib/memory-protection.sh"
UBUNTU_PAYLOAD="$REPO/backends/ubuntu/chroot/payload"
CACHYOS_FILES="$REPO/backends/cachyos/iso/overlay/files/airootfs"
CARRY="$CACHYOS_FILES/usr/share/ci-os/installed/carry-over.list"
for f in "$LIB" "$UBUNTU_PAYLOAD/memory" "$CACHYOS_FILES" "$CARRY"; do
    [ -e "$f" ] || { echo "missing $f" >&2; exit 2; }
done
for t in awk sed find sort cp chmod mktemp; do
    command -v "$t" >/dev/null 2>&1 || { echo "cannot run here: $t is missing" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/memprot-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
has() { printf '%s\n' "$1" | grep -q -F -- "$2"; }   # has TEXT FRAGMENT

# shellcheck source=../memory-protection.sh
. "$LIB"

# replace_in FILE OLD NEW: literal, first occurrence only; fails (and leaves the file alone) when OLD is not there. awk with ENVIRON keeps
# backslashes as they are and index() is a literal search; LC_ALL=C because bash 3.2 and BSD tools are slow on UTF-8 text.
replace_in() {
    local file="$1"
    OLD_TEXT="$2" NEW_TEXT="$3" LC_ALL=C awk 'BEGIN { RS = "\001"; old = ENVIRON["OLD_TEXT"]; new = ENVIRON["NEW_TEXT"] }
        { i = index($0, old); if (i == 0) { missing = 1; exit 1 } ; printf "%s%s%s", substr($0, 1, i - 1), new, substr($0, i + length(old)) }
        END { if (missing) exit 1 }' "$file" > "$file.new" || { rm -f "$file.new"; return 1; }
    mv -f "$file.new" "$file"
}
# put_file PATH TEXT: a file of mode 0644 holding TEXT and a newline (the directory is made).
put_file() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; chmod 644 "$1"; }

# make_tree EDITION DIR: a root shaped like an image, holding the shipped drop-ins of the edition and, for Ubuntu, the other drop-ins
# the build installs next to them (so the lint is also shown to leave the neighbours alone). The modes are normalised: git keeps no
# permission bits but the executable one, so a checkout under another umask would otherwise change what the mode check sees.
make_tree() {
    local ed="$1" etc="$2/etc/systemd/system"
    mkdir -p "$etc"
    if [ "$ed" = ubuntu ]; then
        cp -R "$UBUNTU_PAYLOAD/memory/etc/systemd/system/." "$etc/"
        cp -R "$UBUNTU_PAYLOAD/docker/etc/systemd/system/." "$etc/"
        cp -R "$UBUNTU_PAYLOAD/ssh/etc/systemd/system/." "$etc/"
    else
        cp -R "$CACHYOS_FILES/etc/systemd/system/." "$etc/"
    fi
    find "$etc" -type f -exec chmod 644 {} +
}

U="etc/systemd/system"
CONF="30-ci-os-memory.conf"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "== 1. the library by itself"
out="$(bash -c ". '$LIB'" 2>&1)"
eq "sourcing the library prints nothing" "$out" ""
names="$(bash -c 'declare -F | sed "s/^declare -f //" | sort > "$1/before"; . "$2"; declare -F | sed "s/^declare -f //" | sort > "$1/after"; comm -13 "$1/before" "$1/after"' _ "$WORK" "$LIB" | grep -v -E '^_?ci_os_memprot_' || true)"
eq "every function it defines starts with ci_os_memprot_ or _ci_os_memprot_" "$names" ""
vars="$(bash -c 'set | sed -n "s/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p" | sort -u > "$1/vbefore"; . "$2"; set | sed -n "s/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p" | sort -u > "$1/vafter"; comm -13 "$1/vbefore" "$1/vafter"' _ "$WORK" "$LIB" | grep -v -E '^(CI_OS_MEMPROT_|_CI_|IFS$|_$|BASH_|PIPESTATUS$|OLDPWD$|FUNCNAME$)' || true)"
eq "every variable it defines starts with CI_OS_MEMPROT_ or _CI_" "$vars" ""
expect "it uses nothing bash 3.2 lacks (no mapfile, readarray, declare -A, \${v,,}, \${v^^}, &>>)" \
    bash -c '! grep -v "^ *#" "$1" | grep -q -E "mapfile|readarray|declare -A|typeset -A|\\$\\{[A-Za-z_]+(,,|\\^\\^)|&>>"' _ "$LIB"

eq "the RAM sizes the invariants are computed at: 2, 4, 6, 8, 16, 32 and 64 GiB" "$CI_OS_MEMPROT_RAM_MIB" "2048 4096 6144 8192 16384 32768 65536"
eq "Ubuntu's units, in order" "$(ci_os_memprot_units ubuntu | tr '\n' ' ')" "system.slice user.slice ssh.service docker.service containerd.service "
eq "CachyOS's units: sshd.service for the SSH daemon" "$(ci_os_memprot_units cachyos | tr '\n' ' ')" "system.slice user.slice sshd.service docker.service containerd.service "
ci_os_memprot_units some-other-edition >/dev/null 2>&1; eq "a third edition is refused (exit 2)" "$?" "2"
ci_os_memprot_units >/dev/null 2>&1; eq "no edition is refused (exit 2)" "$?" "2"

eq "1% of 2 GiB, rounded down (21474836.48)" "$(ci_os_memprot_bytes 1% 2048)" "21474836"
eq "25% of 2 GiB" "$(ci_os_memprot_bytes 25% 2048)" "536870912"
eq "100% of 1 MiB is all of it" "$(ci_os_memprot_bytes 100% 1)" "1048576"
eq "1% of 6 GiB (61.44 MiB)" "$(ci_os_memprot_bytes 1% 6144)" "64424509"
eq "10% of 64 GiB" "$(ci_os_memprot_bytes 10% 65536)" "6871947673"
for bad in "0%" "101%" "25" "1.5%" "-1%" "%" "" "25 %" "1e2%" "07%" " 25%" "25%%" "abc%" "100.0%"; do
    out="$(ci_os_memprot_bytes "$bad" 2048 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "ci_os_memprot_bytes refuses '$bad' (exit 2, prints nothing)"; else fail "ci_os_memprot_bytes accepted '$bad' (exit $rc, printed '$out')"; fi
done
for bad in 0 "" abc 08 "2048.5" -1 1234567890; do
    out="$(ci_os_memprot_bytes 25% "$bad" 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "ci_os_memprot_bytes refuses a RAM size of '$bad' (exit 2, prints nothing)"; else fail "ci_os_memprot_bytes accepted a RAM size of '$bad' (exit $rc, printed '$out')"; fi
done

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "== 2. the files that ship"
make_tree ubuntu "$WORK/ship-ubuntu"; make_tree cachyos "$WORK/ship-cachyos"
out="$(ci_os_memprot_lint "$WORK/ship-ubuntu" ubuntu)"; eq "the lint passes on the Ubuntu payload (and says nothing)" "$?:$out" "0:"
out="$(ci_os_memprot_lint "$WORK/ship-cachyos" cachyos)"; eq "the lint passes on the CachyOS overlay (and says nothing)" "$?:$out" "0:"
out="$(ci_os_memprot_parity "$UBUNTU_PAYLOAD/memory" "$CACHYOS_FILES")"; eq "the five files are byte for byte the same on both editions" "$?:$out" "0:"
eq "the Ubuntu payload holds exactly five files" "$(find "$UBUNTU_PAYLOAD/memory" -type f | wc -l | tr -d ' ')" "5"
eq "the CachyOS overlay holds exactly five of them" "$(find "$CACHYOS_FILES/$U" -name "$CONF" | wc -l | tr -d ' ')" "5"
ci_os_memprot_lint "$WORK/ship-cachyos" ubuntu >/dev/null 2>&1; expect "the CachyOS tree is not an Ubuntu tree (its SSH daemon is sshd.service)" test "$?" -eq 1
ci_os_memprot_lint "$WORK/ship-ubuntu" cachyos >/dev/null 2>&1; expect "and the Ubuntu tree is not a CachyOS tree" test "$?" -eq 1
ci_os_memprot_lint "$WORK/ship-ubuntu" some-other-edition >/dev/null 2>&1; eq "an unknown edition is a usage error (exit 2)" "$?" "2"
out="$(ci_os_memprot_lint "$WORK/does-not-exist" ubuntu)"; rc=$?
eq "a root without etc/systemd/system fails (exit 1) and says so" "$rc:$(has "$out" 'is not a directory' && echo said)" "1:said"

# The values the documents quote. Changing one is a decision: this line, the documents and the VM runs change with it.
val() { sed -n "s/^$2=//p" "$UBUNTU_PAYLOAD/memory/$U/$1.d/$CONF"; }
eq "ssh.service: MemoryMin=1%" "$(val ssh.service MemoryMin)" "1%"
eq "system.slice: MemoryMin=2%" "$(val system.slice MemoryMin)" "2%"
eq "system.slice: MemoryLow=10%" "$(val system.slice MemoryLow)" "10%"
eq "docker.service: MemoryLow=3%" "$(val docker.service MemoryLow)" "3%"
eq "containerd.service: MemoryLow=3%" "$(val containerd.service MemoryLow)" "3%"
eq "user.slice: MemoryLow=25%" "$(val user.slice MemoryLow)" "25%"
expect "no Memory key but MemoryMin, MemoryLow and MemoryHigh is assigned in a shipped file" \
    bash -c '! cat "$1"/memory/'"$U"'/*/'"$CONF"' | grep -v "^ *#" | grep -E "^Memory" | grep -v -E "^Memory(Min|Low|High)=" | grep -q .' _ "$UBUNTU_PAYLOAD"
expect "no ollama.service file ships (held back, B1-ollama-high)" \
    bash -c '[ ! -e "$1/memory/'"$U"'/ollama.service.d" ] && [ ! -e "$2/'"$U"'/ollama.service.d" ]' _ "$UBUNTU_PAYLOAD" "$CACHYOS_FILES"
for u in $(ci_os_memprot_units cachyos); do
    expect "carry-over.list names /etc/systemd/system/$u.d/$CONF (the installed system gets it)" grep -q -x "/etc/systemd/system/$u.d/$CONF" "$CARRY"
done
expect "the shipped files carry the reason and the evidence tag [I] in their header" \
    bash -c 'for f in "$1"/memory/'"$U"'/*/'"$CONF"'; do head -n 3 "$f" | grep -q "\[I\]" || exit 1; grep -q "Off-switch" "$f" || exit 1; done' _ "$UBUNTU_PAYLOAD"

# The sizes the documents quote (rounded down, in MiB), computed from the shipped values by the library's own arithmetic.
size_row() { # size_row RAM_MIB -> "ssh system-min system-low docker user" in MiB
    local ram="$1" a b c d e
    a="$(ci_os_memprot_bytes 1% "$ram")"; b="$(ci_os_memprot_bytes 2% "$ram")"; c="$(ci_os_memprot_bytes 10% "$ram")"; d="$(ci_os_memprot_bytes 3% "$ram")"; e="$(ci_os_memprot_bytes 25% "$ram")"
    echo "$((a / 1048576)) $((b / 1048576)) $((c / 1048576)) $((d / 1048576)) $((e / 1048576))"
}
eq "sizes at 2 GiB (MiB: ssh, system.slice min, system.slice low, docker or containerd low, user.slice low)" "$(size_row 2048)" "20 40 204 61 512"
eq "sizes at 6 GiB" "$(size_row 6144)" "61 122 614 184 1536"
eq "sizes at 16 GiB" "$(size_row 16384)" "163 327 1638 491 4096"
eq "sizes at 64 GiB" "$(size_row 65536)" "655 1310 6553 1966 16384"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo
echo "== 3. planted defects: each turns the lint red with its own message"
# A table: name | edition | the text that must be in the output | setup | undo. Setup and undo are shell snippets that run inside
# the fixture root (the tree of the edition, copied). A snippet that fails fails the suite: a fixture that did not change anything
# proves nothing.
NFX=0
fx() { # fx NAME EDITION EXPECTED_TEXT SETUP UNDO
    NFX=$((NFX + 1))
    eval "FX_NAME_$NFX=\$1; FX_ED_$NFX=\$2; FX_EXP_$NFX=\$3; FX_SET_$NFX=\$4; FX_UNDO_$NFX=\$5"
}
fxget() { eval "printf '%s' \"\${FX_$1_$2}\""; }   # fxget FIELD INDEX
idx_of() { local i=1; while [ "$i" -le "$NFX" ]; do [ "$(fxget NAME "$i")" = "$1" ] && { echo "$i"; return 0; }; i=$((i + 1)); done; return 1; }

OLLAMA="$U/ollama.service.d/$CONF"
fx "parity: one shared value edited in one edition" cachyos "differ" \
    "replace_in $U/docker.service.d/$CONF 'MemoryLow=3%' 'MemoryLow=4%'" \
    "replace_in $U/docker.service.d/$CONF 'MemoryLow=4%' 'MemoryLow=3%'"
fx "invariant 1: system.slice MemoryMin dropped to 1%" ubuntu "invariant 1: MemoryMin of system.slice is 1%" \
    "replace_in $U/system.slice.d/$CONF 'MemoryMin=2%' 'MemoryMin=1%'" \
    "replace_in $U/system.slice.d/$CONF 'MemoryMin=1%' 'MemoryMin=2%'"
fx "invariant 1 for MemoryLow: system.slice MemoryLow dropped to 6%" ubuntu "invariant 1: MemoryLow of system.slice is 6%" \
    "replace_in $U/system.slice.d/$CONF 'MemoryLow=10%' 'MemoryLow=6%'" \
    "replace_in $U/system.slice.d/$CONF 'MemoryLow=6%' 'MemoryLow=10%'"
fx "invariant 2: ssh raised to 3%" ubuntu "invariant 2: the MemoryMin values add up to 5%" \
    "replace_in $U/ssh.service.d/$CONF 'MemoryMin=1%' 'MemoryMin=3%'" \
    "replace_in $U/ssh.service.d/$CONF 'MemoryMin=3%' 'MemoryMin=1%'"
fx "invariant 2 alone: system.slice MemoryMin raised to 6%" ubuntu "invariant 2: the MemoryMin values add up to 7%" \
    "replace_in $U/system.slice.d/$CONF 'MemoryMin=2%' 'MemoryMin=6%'" \
    "replace_in $U/system.slice.d/$CONF 'MemoryMin=6%' 'MemoryMin=2%'"
fx "invariant 3: an ollama.service ceiling of 80% next to user.slice 25%" ubuntu "invariant 3: user.slice MemoryLow (25%) plus ollama.service MemoryHigh (80%) is 105%" \
    "put_file $OLLAMA \"\$(printf '[Service]\nMemoryHigh=80%%')\"" \
    "rm -r $U/ollama.service.d"
fx "a unit's file is missing" ubuntu "docker.service.d/$CONF is missing" \
    "mv $U/docker.service.d/$CONF $U/docker.service.d/saved.txt" \
    "mv $U/docker.service.d/saved.txt $U/docker.service.d/$CONF"
fx "a value without the percent sign" ubuntu "MemoryLow=25 is not a whole percentage" \
    "replace_in $U/user.slice.d/$CONF 'MemoryLow=25%' 'MemoryLow=25'" \
    "replace_in $U/user.slice.d/$CONF 'MemoryLow=25' 'MemoryLow=25%'"
fx "a decimal percentage" ubuntu "MemoryLow=2.5% is not a whole percentage" \
    "replace_in $U/user.slice.d/$CONF 'MemoryLow=25%' 'MemoryLow=2.5%'" \
    "replace_in $U/user.slice.d/$CONF 'MemoryLow=2.5%' 'MemoryLow=25%'"
fx "more than all of memory" ubuntu "MemoryLow=101% is not a whole percentage" \
    "replace_in $U/user.slice.d/$CONF 'MemoryLow=25%' 'MemoryLow=101%'" \
    "replace_in $U/user.slice.d/$CONF 'MemoryLow=101%' 'MemoryLow=25%'"
fx "MemoryMax is present" ubuntu "MemoryMax is not allowed" \
    "printf 'MemoryMax=50%%\n' >> $U/docker.service.d/$CONF" \
    "sed -i.bak '/^MemoryMax=/d' $U/docker.service.d/$CONF && rm -f $U/docker.service.d/$CONF.bak"
fx "a key typed Memorylow" ubuntu "Memorylow is not one of MemoryMin, MemoryLow, MemoryHigh" \
    "replace_in $U/user.slice.d/$CONF 'MemoryLow=25%' 'Memorylow=25%'" \
    "replace_in $U/user.slice.d/$CONF 'Memorylow=25%' 'MemoryLow=25%'"
fx "[Service] in a slice file" ubuntu "MemoryLow is in [Service], but a *.slice unit reads it in [Slice]" \
    "replace_in $U/user.slice.d/$CONF '[Slice]' '[Service]'" \
    "replace_in $U/user.slice.d/$CONF '[Service]' '[Slice]'"
fx "[Slice] in a service file" ubuntu "MemoryMin is in [Slice], but a *.service unit reads it in [Service]" \
    "replace_in $U/ssh.service.d/$CONF '[Service]' '[Slice]'" \
    "replace_in $U/ssh.service.d/$CONF '[Slice]' '[Service]'"
fx "a later 99-x.conf resets MemoryMin=0" ubuntu "ssh.service.d/99-x.conf:2: MemoryMin=0 is not a whole percentage" \
    "put_file $U/ssh.service.d/99-x.conf \"\$(printf '[Service]\nMemoryMin=0')\"" \
    "rm $U/ssh.service.d/99-x.conf"
fx "a later 99-x.conf empties MemoryLow" ubuntu "docker.service.d/99-x.conf:2: MemoryLow= is not a whole percentage" \
    "put_file $U/docker.service.d/99-x.conf \"\$(printf '[Service]\nMemoryLow=')\"" \
    "rm $U/docker.service.d/99-x.conf"
fx "a later 99-x.conf raises the hard minimum (the last assignment wins)" ubuntu "invariant 1: MemoryMin of system.slice is 2%, which does not exceed the 4%" \
    "put_file $U/ssh.service.d/99-x.conf \"\$(printf '[Service]\nMemoryMin=4%%')\"" \
    "rm $U/ssh.service.d/99-x.conf"
fx "an ollama.service file with infinity" ubuntu "MemoryHigh=infinity is not allowed" \
    "put_file $OLLAMA \"\$(printf '[Service]\nMemoryHigh=infinity')\"" \
    "rm -r $U/ollama.service.d"
fx "an ollama.service file that sets no ceiling" ubuntu "ollama.service: MemoryHigh is not set" \
    "put_file $OLLAMA \"\$(printf '[Service]\nMemoryLow=5%%')\"" \
    "rm -r $U/ollama.service.d"
fx "an ssh drop-in in a CachyOS tree" cachyos "ssh.service.d/$CONF belongs to no unit of the cachyos edition (this edition's SSH daemon is sshd.service)" \
    "mkdir -p $U/ssh.service.d && cp $U/sshd.service.d/$CONF $U/ssh.service.d/$CONF" \
    "rm -r $U/ssh.service.d"
fx "an sshd drop-in in an Ubuntu tree" ubuntu "sshd.service.d/$CONF belongs to no unit of the ubuntu edition (this edition's SSH daemon is ssh.service)" \
    "mkdir -p $U/sshd.service.d && cp $U/ssh.service.d/$CONF $U/sshd.service.d/$CONF" \
    "rm -r $U/sshd.service.d"
fx "a symlink in place of a file" ubuntu "docker.service.d/$CONF is a symlink" \
    "mv $U/docker.service.d/$CONF $U/containerd.service.d/real.txt && ln -s ../containerd.service.d/real.txt $U/docker.service.d/$CONF" \
    "rm $U/docker.service.d/$CONF && mv $U/containerd.service.d/real.txt $U/docker.service.d/$CONF"
fx "a file of mode 0600" ubuntu "docker.service.d/$CONF is mode 600, not 0644" \
    "chmod 600 $U/docker.service.d/$CONF" \
    "chmod 644 $U/docker.service.d/$CONF"
fx "a symlinked drop-in directory" ubuntu "etc/systemd/system/docker.service.d is a symlink" \
    "mv $U/docker.service.d $U/docker-real && ln -s docker-real $U/docker.service.d" \
    "rm $U/docker.service.d && mv $U/docker-real $U/docker.service.d"
fx "a file with no assignment at all" ubuntu "user.slice: MemoryLow is not set in any drop-in" \
    "mv $U/user.slice.d/$CONF $U/user.slice.d/saved.txt && put_file $U/user.slice.d/$CONF '# only a comment'" \
    "rm $U/user.slice.d/$CONF && mv $U/user.slice.d/saved.txt $U/user.slice.d/$CONF"
fx "a symlink named like a later drop-in" ubuntu "docker.service.d/99-x.conf is a symlink: a drop-in of this unit must be a regular file" \
    "ln -s $CONF $U/docker.service.d/99-x.conf" \
    "rm $U/docker.service.d/99-x.conf"
fx "an assignment before any section header" ubuntu "docker.service.d/$CONF:1: MemoryLow is outside any section" \
    "mv $U/docker.service.d/$CONF $U/docker.service.d/saved.txt && put_file $U/docker.service.d/$CONF 'MemoryLow=3%'" \
    "rm $U/docker.service.d/$CONF && mv $U/docker.service.d/saved.txt $U/docker.service.d/$CONF"

# Build every defect tree, and run the lint (or, for the parity row, the parity function) on it with the real library.
run_fx() { # run_fx INDEX -> sets FX_OUT FX_RC for the tree $WORK/fx-INDEX
    local i="$1" d="$WORK/fx-$1" ed
    ed="$(fxget ED "$i")"
    case "$(fxget NAME "$i")" in
        parity:*) FX_OUT="$(ci_os_memprot_parity "$WORK/fx-$i-ubuntu" "$d")"; FX_RC=$? ;;
        *) FX_OUT="$(ci_os_memprot_lint "$d" "$ed")"; FX_RC=$? ;;
    esac
}
i=1
while [ "$i" -le "$NFX" ]; do
    d="$WORK/fx-$i"; ed="$(fxget ED "$i")"; name="$(fxget NAME "$i")"
    make_tree "$ed" "$d"
    case "$name" in parity:*) mkdir -p "$WORK/fx-$i-ubuntu/$U"; cp -R "$UBUNTU_PAYLOAD/memory/$U/." "$WORK/fx-$i-ubuntu/$U/" ;; esac
    if ! ( cd "$d" && eval "$(fxget SET "$i")" ) >/dev/null 2>&1; then fail "fixture '$name': the setup did not apply (a fixture that changes nothing proves nothing)"; i=$((i + 1)); continue; fi
    run_fx "$i"
    if [ "$FX_RC" -ne 0 ] && has "$FX_OUT" "$(fxget EXP "$i")" && ! printf '%s\n' "$FX_OUT" | grep -v '^FAIL: ' | grep -q .; then pass "red: $name"
    else fail "red: $name (exit $FX_RC; wanted the text '$(fxget EXP "$i")'; got: $(printf '%s' "$FX_OUT" | head -n 3 | tr '\n' '|' | cut -c1-300))"; fi
    i=$((i + 1))
done

# Section 4 of the table is the weakened copies of the library. They are run on the DEFECT trees above, before the defects are undone.
echo
echo "== 4. weakened copies of the library: each weakening must make a fixture designated for it stop producing its message"
MUT_N=0
# behaving COPY FIXTURE_NAME...: prints the names of the fixtures that still behave as they should (red, with their message) when the
# lint of the library COPY runs on their defect tree. A fixture with no defect tree of its own (a name nobody defined) is an error.
behaving() {
    local copy="$1" fname j out rc exp ed
    shift
    for fname in "$@"; do
        j="$(idx_of "$fname")" || { echo "NO-SUCH-FIXTURE:$fname"; continue; }
        ed="$(fxget ED "$j")"; exp="$(fxget EXP "$j")"
        case "$fname" in
            parity:*) out="$(bash -c '. "$1"; ci_os_memprot_parity "$2" "$3"' _ "$copy" "$WORK/fx-$j-ubuntu" "$WORK/fx-$j" 2>&1)"; rc=$? ;;
            *) out="$(bash -c '. "$1"; ci_os_memprot_lint "$2" "$3"' _ "$copy" "$WORK/fx-$j" "$ed" 2>&1)"; rc=$? ;;
        esac
        if [ "$rc" -ne 0 ] && has "$out" "$exp"; then echo "$fname"; fi
    done
}
# The control: an unchanged copy of the library, through the same machinery, must keep every fixture red with its message.
ALL_FX=()
j=1; while [ "$j" -le "$NFX" ]; do ALL_FX+=("$(fxget NAME "$j")"); j=$((j + 1)); done
cp "$LIB" "$WORK/control.sh"
ok_n="$(behaving "$WORK/control.sh" "${ALL_FX[@]}" | grep -c .)"
eq "control: an unchanged copy of the library keeps all $NFX fixtures red with their message (so a kill below means the weakening, not the machinery)" "$ok_n" "$NFX"

mutant() { # mutant NAME OLD NEW FIXTURE_NAME...: the library with OLD replaced by NEW; at least one named fixture must stop behaving
    local name="$1" old="$2" new="$3" copy still
    shift 3
    MUT_N=$((MUT_N + 1))
    copy="$WORK/mutant-$MUT_N.sh"
    cp "$LIB" "$copy"
    if ! replace_in "$copy" "$old" "$new"; then fail "mutant '$name': the text to replace is not in the library (a replacement that matches nothing proves nothing)"; return; fi
    if cmp -s "$copy" "$LIB"; then fail "mutant '$name': the replacement did not change the library"; return; fi
    if ! bash -n "$copy" 2>/dev/null; then fail "mutant '$name': the weakened library does not parse"; return; fi
    still="$(behaving "$copy" "$@" | grep -c .)"
    if [ "$still" -lt "$#" ]; then pass "killed: $name ($((${#} - still)) of $# designated fixtures stopped behaving)"; else fail "SURVIVED: $name (every designated fixture still behaves)"; fi
}
mutant "invariant 1 replaced by true" '_ci_os_memprot_inv1() {' '_ci_os_memprot_inv1() { return 0;' \
    "invariant 1: system.slice MemoryMin dropped to 1%" "invariant 1 for MemoryLow: system.slice MemoryLow dropped to 6%"
mutant "the 5% bound removed" '_ci_os_memprot_inv2() {' '_ci_os_memprot_inv2() { return 0;' \
    "invariant 2 alone: system.slice MemoryMin raised to 6%"
mutant "invariant 3 removed" '_ci_os_memprot_inv3() {' '_ci_os_memprot_inv3() { return 0;' \
    "invariant 3: an ollama.service ceiling of 80% next to user.slice 25%"
mutant "last-wins replaced by first-wins" 'eff[role, key] = v2; src[role, key] = base' 'if (!((role, key) in eff)) { eff[role, key] = v2; src[role, key] = base }' \
    "a later 99-x.conf raises the hard minimum (the last assignment wins)"
mutant "the order of the files reversed" 'LC_ALL=C sort \' 'LC_ALL=C sort -r \' \
    "a later 99-x.conf raises the hard minimum (the last assignment wins)"
mutant "MemoryMax allowed" 'if (key ~ /^Memory(Max|SwapMax|ZSwapMax)$/) {' 'if (0) {' \
    "MemoryMax is present"
mutant "infinity treated like any other bad value" 'if (val == "infinity") {' 'if (0) {' \
    "an ollama.service file with infinity"
mutant "the percent sign not required" 'else if (val !~ /^[1-9][0-9]*%$/) {' 'else if (0) {' \
    "a value without the percent sign" "a decimal percentage" "a later 99-x.conf resets MemoryMin=0" "a later 99-x.conf empties MemoryLow"
mutant "any number accepted (no upper bound of 100)" 'if (pct > 100) {' 'if (0) {' \
    "more than all of memory"
mutant "the section not checked" 'if (section != utype) {' 'if (0) {' \
    "[Service] in a slice file" "[Slice] in a service file" "an assignment before any section header"
mutant "any key accepted" 'if (key != "MemoryMin" && key != "MemoryLow" && key != "MemoryHigh") {' 'if (0) {' \
    "a key typed Memorylow"
mutant "a symlink accepted" 'elif [ -L "$f" ]; then' 'elif false; then' \
    "a symlink in place of a file"
mutant "a symlinked directory accepted" 'if [ -L "$d" ]; then' 'if false; then' \
    "a symlinked drop-in directory"
mutant "a missing file accepted" 'elif [ ! -f "$f" ]; then' 'elif false; then' \
    "a unit's file is missing"
mutant "the mode not checked" '-name "$CI_OS_MEMPROT_FILE" ! -perm 644' '-name "$CI_OS_MEMPROT_FILE" -perm 7777' \
    "a file of mode 0600"
mutant "a file for another edition's unit accepted" 'case "$nl$units$nl" in *"$nl$unit$nl"*) continue ;; esac' 'continue' \
    "an ssh drop-in in a CachyOS tree" "an sshd drop-in in an Ubuntu tree"
mutant "a symlinked drop-in of a neighbour not reported" "-name '*.conf' ! -type f 2>/dev/null" "-name '*.conf' -type d 2>/dev/null" \
    "a symlink named like a later drop-in"
mutant "the keys a unit needs not required" 'if [ -z "${!k:-}" ]; then' 'if false; then' \
    "a file with no assignment at all" "an ollama.service file that sets no ceiling"
mutant "parity compares nothing" 'if ! _ci_os_memprot_same "$a" "$b"; then' 'if false; then' \
    "parity: one shared value edited in one edition"

# Back to the unweakened library: undo each defect and the tree must be green again.
echo
echo "== 5. the same trees minus the defect are green again"
i=1
while [ "$i" -le "$NFX" ]; do
    d="$WORK/fx-$i"; name="$(fxget NAME "$i")"
    if ! ( cd "$d" && eval "$(fxget UNDO "$i")" ) >/dev/null 2>&1; then fail "fixture '$name': the undo did not apply"; i=$((i + 1)); continue; fi
    run_fx "$i"
    if [ "$FX_RC" -eq 0 ] && [ -z "$FX_OUT" ]; then pass "green: $name, undone"; else fail "green: $name, undone (exit $FX_RC; $(printf '%s' "$FX_OUT" | head -n 2 | tr '\n' '|' | cut -c1-200))"; fi
    i=$((i + 1))
done

# Cases that are green on purpose.
echo
echo "== 6. what the lint must leave alone"
make_tree ubuntu "$WORK/ok1"
put_file "$WORK/ok1/$OLLAMA" "$(printf '[Service]\nMemoryHigh=70%%')"
out="$(ci_os_memprot_lint "$WORK/ok1" ubuntu)"; eq "an ollama.service ceiling of 70% fits next to user.slice 25% (95%): the held-back item is one file away" "$?:$out" "0:"
make_tree ubuntu "$WORK/ok2"
put_file "$WORK/ok2/$OLLAMA" "$(printf '[Service]\nMemoryHigh=75%%')"
out="$(ci_os_memprot_lint "$WORK/ok2" ubuntu)"; eq "75% plus 25% is exactly all of RAM: still allowed (invariant 3 says at most)" "$?:$out" "0:"
make_tree ubuntu "$WORK/ok3"
put_file "$WORK/ok3/$U/ssh.service.d/99-later.conf" "$(printf '[Service]\nMemoryMin=1%%\n[Unit]\nDescription=a neighbour')"
out="$(ci_os_memprot_lint "$WORK/ok3" ubuntu)"; eq "a later file that sets a valid value and other sections is fine" "$?:$out" "0:"
make_tree ubuntu "$WORK/ok4"
put_file "$WORK/ok4/$U/ssh.service.d/10-other.conf" "$(printf '[Service]\nMemoryAccounting=yes\nmemorymin=0\nRestart=always')"
out="$(ci_os_memprot_lint "$WORK/ok4" ubuntu)"; eq "another file's unrelated and differently spelled keys are not ours to judge" "$?:$out" "0:"
make_tree ubuntu "$WORK/ok5"
put_file "$WORK/ok5/$U/hostapd-setup.service.d/10-not-live.conf" "$(printf '[Unit]\nConditionPathExists=!/cdrom/casper/vmlinuz')"
put_file "$WORK/ok5/$U/nginx.service.d/99-x.conf" "$(printf '[Service]\nMemoryMax=64M')"
out="$(ci_os_memprot_lint "$WORK/ok5" ubuntu)"; eq "units outside the list keep their own settings (MemoryMax=64M on another unit is none of this lint's business)" "$?:$out" "0:"
make_tree ubuntu "$WORK/ok6"
put_file "$WORK/ok6/$U/ssh.service.d/$CONF" "$(printf '# a comment\n; another\n\n[Service]\n  MemoryMin = 1%%  \n')"
out="$(ci_os_memprot_lint "$WORK/ok6" ubuntu)"; eq "comments, blank lines and spaces around the sign are read the way systemd reads them" "$?:$out" "0:"
make_tree ubuntu "$WORK/ok7"
rm -r "$WORK/ok7/$U/ssh.service.d"; mkdir -p "$WORK/ok7/$U/ssh.service.d"; chmod 755 "$WORK/ok7/$U/ssh.service.d"
put_file "$WORK/ok7/$U/ssh.service.d/$CONF" "$(printf '[Service]\nMemoryMin=1%%')"
put_file "$WORK/ok7/$U/ssh.service.d/zz-later.conf" "$(printf '[Service]\nMemoryMin=1%%')"
out="$(ci_os_memprot_lint "$WORK/ok7" ubuntu)"; eq "a later file repeating the same value changes nothing" "$?:$out" "0:"
# The lint is run with a different current directory and a root given with a trailing slash.
out="$(cd / && ci_os_memprot_lint "$WORK/ship-ubuntu/" ubuntu)"; eq "a root with a trailing slash, run from another directory" "$?:$out" "0:"

echo
echo "== 7. a FIFO named like a drop-in: reported, and never opened (a reader would block on it)"
# guarded_lint LIB ROOT EDITION SECONDS: the lint of the library LIB runs in the background and gets SECONDS. Sets GL_OUT and GL_RC; GL_RC is HUNG when
# it did not finish. A FIFO under ROOT is then opened for writing, which lets a reader that blocked on it go on, so that nothing is left running.
guarded_lint() {
    local lib="$1" root="$2" ed="$3" max=$(($4 * 5)) pid i=0 f wp
    : > "$WORK/gl.out"; : > "$WORK/gl.rc"
    ( bash -c '. "$1"; ci_os_memprot_lint "$2" "$3"' _ "$lib" "$root" "$ed" > "$WORK/gl.out" 2>&1; echo $? > "$WORK/gl.rc" ) &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$max" ]; do sleep 0.2; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        for f in "$root/$U"/*/*.conf; do
            if [ -p "$f" ]; then ( : > "$f" ) & wp=$!; sleep 1; kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; fi
        done
        wait "$pid" 2>/dev/null
        GL_RC=HUNG
    else
        wait "$pid" 2>/dev/null
        GL_RC="$(cat "$WORK/gl.rc")"
    fi
    GL_OUT="$(cat "$WORK/gl.out")"
}
make_tree ubuntu "$WORK/fifo"
if mkfifo "$WORK/fifo/$U/docker.service.d/99-x.conf" 2>/dev/null; then
    guarded_lint "$LIB" "$WORK/fifo" ubuntu 60   # (a lint that works takes a second or two, a loaded machine more)
    eq "the lint finishes (it does not open the FIFO) and fails" "$GL_RC" "1"
    expect "  and names the file, and says it is not a regular file" has "$GL_OUT" "docker.service.d/99-x.conf is not a regular file"
    cp "$LIB" "$WORK/mutant-fifo.sh"
    if replace_in "$WORK/mutant-fifo.sh" "-mindepth 2 -maxdepth 2 -type f -name '*.conf' 2>/dev/null" "-mindepth 2 -maxdepth 2 -name '*.conf' 2>/dev/null"; then
        guarded_lint "$WORK/mutant-fifo.sh" "$WORK/fifo" ubuntu 6   # (this one never finishes on its own)
        eq "killed: a lint that hands every *.conf to awk blocks on the FIFO" "$GL_RC" "HUNG"
    else
        fail "mutant 'awk reads non-regular files': the text to replace is not in the library"
    fi
else
    printf 'info  SKIPPED: no mkfifo on this machine, so the FIFO case was not run\n'
fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
