#!/usr/bin/env bash
#=============================================================================
# Test: verify-iso.sh section 3h (the memory protection drop-ins) fails on the defects it is for
#
# The invariants themselves are tested where they are written: core/lib/tests/memory-protection.sh (the lint, on fixture trees, with
# weakened copies of the library). What that cannot show is that verify-iso.sh calls the lint right: the root it hands over, the edition,
# the labels, the way a FAIL line of the lint becomes a FAIL line of the verifier, the skip when the library is not there, and the
# information line about ssh.socket. This test cuts the real section out of verify-iso.sh (from the line that begins `section "3h.` to the
# line before the next one that begins `section "`, whatever its number or letter, so a section added after it never leaks in) and RUNS
# it with verify-iso.sh's own pass/fail/note/skip helpers against fake extracted roots: one shaped like the installed layer, with the
# five drop-ins the build installs, and single defects planted in it.
#
# Then the same fixtures are run against weakened copies of verify-iso.sh (the lint call deleted, the wrong edition, a FAIL line no longer
# passed on, the label changed): each weakening must make at least one fixture stop behaving, or the suite fails.
#
# It cannot say that the image build produces such a root (that is a build) or that the extraction list of verify-iso.sh brings these
# files out of the squashfs (that is a run on an ISO); it says the section reads the right files and says the right thing about them.
#
# Pure bash (3.2 safe), no root, no network, no xorriso or squashfs-tools.
#   bash backends/ubuntu/iso/tests/verify-memory-protection.sh
# VERIFY_ISO_SCRIPT=<path> runs the fixtures against another copy of verify-iso.sh (a copy with the check weakened must fail them).
# Exit status: 0 all passed, 1 a check failed, 2 cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
REAL_VERIFY="$REPO/backends/ubuntu/iso/scripts/verify-iso.sh"
VERIFY="${VERIFY_ISO_SCRIPT:-$REAL_VERIFY}"
LIBDIR="$REPO/core/lib"
PAYLOAD="$REPO/backends/ubuntu/chroot/payload"
for f in "$VERIFY" "$REAL_VERIFY" "$LIBDIR/memory-protection.sh" "$PAYLOAD/memory" "$PAYLOAD/docker"; do
    [[ -e "$f" ]] || { echo "missing $f" >&2; exit 2; }
done
for t in awk sed find sort cp chmod mktemp; do
    command -v "$t" >/dev/null 2>&1 || { echo "cannot run here: $t is missing" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-memprot.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
T_PASS=0; T_FAIL=0
t_pass() { T_PASS=$((T_PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { T_FAIL=$((T_FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then t_pass "$label"; else t_fail "$label"; fi; }
eq() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1 (got '$2', want '$3')"; fi; }

# replace_in FILE OLD NEW: literal, first occurrence; fails when OLD is not there (awk: ENVIRON keeps backslashes, index() is literal).
replace_in() {
    local file="$1"
    OLD_TEXT="$2" NEW_TEXT="$3" LC_ALL=C awk 'BEGIN { RS = "\001"; old = ENVIRON["OLD_TEXT"]; new = ENVIRON["NEW_TEXT"] }
        { i = index($0, old); if (i == 0) { missing = 1; exit 1 } ; printf "%s%s%s", substr($0, 1, i - 1), new, substr($0, i + length(old)) }
        END { if (missing) exit 1 }' "$file" > "$file.new" || { rm -f "$file.new"; return 1; }
    mv -f "$file.new" "$file"
}
put_file() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; chmod 644 "$1"; }

# ── the section, cut out of a verify-iso.sh and placed where it finds the library the way it does in the repo ────────────────────────
# cut_section <verify-iso.sh> <out>: the lines from `section "3h.` up to (not including) the next line that begins `section "`.
cut_section() { awk '/^section "3h\./ { f = 1; print; next } f && /^section "/ { exit } f { print }' "$1" > "$2"; }
# in_repo <name> <section file> [<library directory>]: a fake repository whose backends/ubuntu/iso/scripts/verify-iso.sh is the section and
# whose core/lib is the real one (or the directory given, or none: the copy of the script outside a repository).
in_repo() {
    local d="$WORK/$1"
    mkdir -p "$d/backends/ubuntu/iso/scripts" "$d/core"
    cp "$2" "$d/backends/ubuntu/iso/scripts/verify-iso.sh"
    if [[ "${3-$LIBDIR}" != none ]]; then ln -s "${3-$LIBDIR}" "$d/core/lib"; fi
    echo "$d/backends/ubuntu/iso/scripts/verify-iso.sh"
}
# A library whose lint fails and says nothing (a lint that broke): the section must still fail, and say so.
STUBLIB="$WORK/stublib"; mkdir -p "$STUBLIB"
printf 'ci_os_memprot_lint() { return 1; }\n' > "$STUBLIB/memory-protection.sh"
SECT="$WORK/section.sh"
cut_section "$VERIFY" "$SECT"
[[ "$(wc -l < "$SECT" | tr -d ' ')" -gt 15 ]] || { echo "could not cut section 3h out of $VERIFY" >&2; exit 2; }
IN_REPO="$(in_repo repo "$SECT")"
NO_LIB="$(in_repo norepo "$SECT" none)"   # a copy of the script outside the repo
STUB_REPO="$(in_repo stubrepo "$SECT" "$STUBLIB")"

# run_section <script> <root>: the helpers of verify-iso.sh, then the section. The output is in $WORK/out.txt, the counts in P and F.
run_section() {
    local script="$1" R="$2" PASS=0 FAIL=0
    pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
    fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
    note() { printf 'info  %s\n' "$*"; }
    skip() { printf 'info  SKIPPED: %s\n' "$*"; }
    section() { printf '\n== %s\n' "$*"; }
    # shellcheck disable=SC1090
    . "$script" > "$WORK/out.txt" 2>&1
    P=$PASS; F=$FAIL
}

# ── the good root: what the image build produces, plus the neighbours it has ─────────────────────────────────────────────────────────
good="$WORK/good"
mkdir -p "$good/etc/systemd/system" "$good/usr/lib/systemd/system"
cp -R "$PAYLOAD/memory/etc/systemd/system/." "$good/etc/systemd/system/"
cp -R "$PAYLOAD/docker/etc/systemd/system/." "$good/etc/systemd/system/"
printf '[Unit]\nDescription=a stand-in for the packaged socket\n[Socket]\nListenStream=22\nAccept=no\n' > "$good/usr/lib/systemd/system/ssh.socket"
find "$good" -type f -exec chmod 644 {} +

U="etc/systemd/system"
CONF="30-ci-os-memory.conf"

# ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "== 1. a root built the way the image build builds it"
run_section "$IN_REPO" "$good"
eq "no FAIL in section 3h" "$F" "0"
[[ "$F" == 0 ]] || grep '^FAIL' "$WORK/out.txt" | sed 's/^/        /'
eq "  and one check passed (the lint over all five drop-ins)" "$P" "1"
expect "  the section header was printed" grep -q '^== 3h\. Memory protection drop-ins' "$WORK/out.txt"
expect "  and it prints the Accept= information line (Accept=no: one ssh.service serves the connections)" \
    grep -q '^info  ssh.socket: Accept=no: one ssh.service serves the connections' "$WORK/out.txt"
expect "  and no section after it was cut in" bash -c '! grep -q "Branding" "$1"' _ "$SECT"

echo
echo "== 2. the information line about ssh.socket (never a failure)"
sock_case() { # sock_case <name> <text of the packaged socket or "-" for none> [<text of a drop-in>]: sets F and the output
    local r="$WORK/sock-$1"
    rm -rf "$r"; cp -R "$good" "$r"
    if [[ "$2" == "-" ]]; then rm -f "$r/usr/lib/systemd/system/ssh.socket"; else printf '%s\n' "$2" > "$r/usr/lib/systemd/system/ssh.socket"; fi
    if [[ -n "${3:-}" ]]; then put_file "$r/etc/systemd/system/ssh.socket.d/10-local.conf" "$3"; fi
    run_section "$IN_REPO" "$r"
}
sock_case yes "$(printf '[Socket]\nAccept=yes')"
eq "Accept=yes: no FAIL" "$F" "0"
expect "  but the information line says the instances live in system-sshd.slice and are not covered" \
    grep -q '^info  ssh.socket sets Accept=yes: systemd starts one sshd@.service per connection, in system-sshd.slice, whose own memory.min is 0' "$WORK/out.txt"
sock_case unset "$(printf '[Socket]\nListenStream=22')"
eq "no Accept= at all: no FAIL" "$F" "0"
expect "  and the line says it is not set, so no" grep -q '^info  ssh.socket: Accept=<not set, so no>' "$WORK/out.txt"
sock_case override "$(printf '[Socket]\nAccept=no')" "$(printf '[Socket]\nAccept=yes')"
expect "a drop-in of the socket that sets Accept=yes wins over the packaged Accept=no (the last assignment)" grep -q '^info  ssh.socket sets Accept=yes' "$WORK/out.txt"
sock_case none -
eq "no ssh.socket in the image: no FAIL" "$F" "0"
expect "  and a note says it could not be read" grep -q '^info  ssh.socket is not in the image' "$WORK/out.txt"

echo
echo "== 3. a stock root, and a tree without etc/systemd/system"
stock="$WORK/stock"; mkdir -p "$stock/etc/systemd/system" "$stock/usr/lib/systemd/system"
run_section "$IN_REPO" "$stock"
expect "a root with no drop-in at all fails once for each unit's file and once for each key it needs (at least 10 FAIL lines)" test "$F" -ge 10
expect "  and the FAIL lines carry the section's label" bash -c '[ "$(grep -c "^FAIL  memory protection: " "$1")" = "$2" ]' _ "$WORK/out.txt" "$F"
empty="$WORK/empty-root"; mkdir -p "$empty"
run_section "$IN_REPO" "$empty"
eq "a root without etc/systemd/system: one FAIL" "$F" "1"
expect "  that says what is missing" grep -q '^FAIL  memory protection: .*etc/systemd/system is not a directory' "$WORK/out.txt"

run_section "$STUB_REPO" "$good"
eq "a lint that fails and says nothing: one FAIL that says so" "$F:$(grep -c 'FAIL  memory protection: the lint of core/lib/memory-protection.sh failed (exit 1) and said nothing' "$WORK/out.txt")" "1:1"

echo
echo "== 4. one defect, the FAIL lines that name it"
# The fixtures: name | text one FAIL line must contain | how many FAIL lines in all | the commands that plant it (run in the cloned root).
NFX=0
fx() { NFX=$((NFX + 1)); eval "FX_NAME_$NFX=\$1; FX_WANT_$NFX=\$2; FX_N_$NFX=\$3; FX_CMD_$NFX=\$4"; }
fxget() { eval "printf '%s' \"\${FX_$1_$2}\""; }
OLLAMA="$U/ollama.service.d/$CONF"
fx "a unit's file is missing" "memory protection: etc/systemd/system/docker.service.d/$CONF is missing" 2 "rm $U/docker.service.d/$CONF"
fx "a value without the percent sign" "memory protection: " 1 "replace_in $U/user.slice.d/$CONF 'MemoryLow=25%' 'MemoryLow=25'"
fx "MemoryMax is present" "MemoryMax is not allowed" 1 "printf 'MemoryMax=50%%\n' >> $U/docker.service.d/$CONF"
fx "a key typed Memorylow" "Memorylow is not one of MemoryMin, MemoryLow, MemoryHigh" 2 "replace_in $U/user.slice.d/$CONF 'MemoryLow=25%' 'Memorylow=25%'"
fx "[Service] in a slice file" "MemoryLow is in [Service], but a *.slice unit reads it in [Slice]" 2 "replace_in $U/user.slice.d/$CONF '[Slice]' '[Service]'"
fx "a later 99-x.conf resets MemoryMin=0" "ssh.service.d/99-x.conf:2: MemoryMin=0 is not a whole percentage" 1 "put_file $U/ssh.service.d/99-x.conf \"\$(printf '[Service]\nMemoryMin=0')\""
fx "system.slice MemoryMin dropped to 1%" "invariant 1: MemoryMin of system.slice is 1%" 1 "replace_in $U/system.slice.d/$CONF 'MemoryMin=2%' 'MemoryMin=1%'"
fx "ssh raised to 3%" "invariant 2: the MemoryMin values add up to 5%" 2 "replace_in $U/ssh.service.d/$CONF 'MemoryMin=1%' 'MemoryMin=3%'"
fx "an ollama.service ceiling that does not fit next to user.slice" "invariant 3: user.slice MemoryLow (25%) plus ollama.service MemoryHigh (80%) is 105%" 1 "put_file $OLLAMA \"\$(printf '[Service]\nMemoryHigh=80%%')\""
fx "an ollama.service file with infinity" "MemoryHigh=infinity is not allowed" 1 "put_file $OLLAMA \"\$(printf '[Service]\nMemoryHigh=infinity')\""
fx "the CachyOS name of the SSH daemon in an Ubuntu root" "sshd.service.d/$CONF belongs to no unit of the ubuntu edition (this edition's SSH daemon is ssh.service)" 1 "mkdir -p $U/sshd.service.d && cp $U/ssh.service.d/$CONF $U/sshd.service.d/$CONF"
fx "a symlink in place of a file" "docker.service.d/$CONF is a symlink" 2 "mv $U/docker.service.d/$CONF $U/containerd.service.d/real.txt && ln -s ../containerd.service.d/real.txt $U/docker.service.d/$CONF"
fx "a file of mode 0600" "docker.service.d/$CONF is mode 600, not 0644" 1 "chmod 600 $U/docker.service.d/$CONF"
fx "an empty drop-in" "user.slice: MemoryLow is not set in any drop-in" 1 ": > $U/user.slice.d/$CONF"

# Build every fixture root once; the weakened scripts below run on the same roots.
i=1
while [[ "$i" -le "$NFX" ]]; do
    r="$WORK/fx-$i"; rm -rf "$r"; cp -R "$good" "$r"
    if ! ( cd "$r" && eval "$(fxget CMD "$i")" ) >/dev/null 2>&1; then t_fail "fixture '$(fxget NAME "$i")': the planting did not apply"; fi
    i=$((i + 1))
done
# fixture_ok <script> <index>: the section run on that root gives exactly the number of FAIL lines wanted, one of them with the wanted text.
fixture_ok() {
    local script="$1" j="$2" want n
    run_section "$script" "$WORK/fx-$j"
    want="$(fxget WANT "$j")"; n="$(fxget N "$j")"
    [[ "$F" == "$n" ]] && grep '^FAIL' "$WORK/out.txt" | grep -q -F -- "$want"
}
i=1
while [[ "$i" -le "$NFX" ]]; do
    if fixture_ok "$IN_REPO" "$i"; then t_pass "$(fxget NAME "$i"): $(fxget N "$i") FAIL line(s), one says: $(fxget WANT "$i")"
    else t_fail "$(fxget NAME "$i"): want $(fxget N "$i") FAIL line(s), one containing '$(fxget WANT "$i")', got $F"; grep '^FAIL' "$WORK/out.txt" | sed 's/^/        /'; fi
    i=$((i + 1))
done

echo
echo "== 5. the same scenarios against weakened copies of verify-iso.sh: each weakening must change what at least one of them sees"
# scenarios_behaving <section file> <tag>: how many of the scenarios still behave as they should with this section: the good root, each planted
# defect, the lint that fails silently, and the copy outside a repository.
scenarios_behaving() {
    local cut="$1" tag="$2" j=1 ok=0 script
    script="$(in_repo "s-$tag" "$cut")"
    run_section "$script" "$good"
    [[ "$F" == 0 && "$P" == 1 ]] && ok=$((ok + 1))
    while [[ "$j" -le "$NFX" ]]; do fixture_ok "$script" "$j" && ok=$((ok + 1)); j=$((j + 1)); done
    run_section "$(in_repo "stub-$tag" "$cut" "$STUBLIB")" "$good"
    [[ "$F" == 1 ]] && grep -q 'FAIL  memory protection: the lint of core/lib/memory-protection.sh failed (exit 1) and said nothing' "$WORK/out.txt" && ok=$((ok + 1))
    run_section "$(in_repo "nolib-$tag" "$cut" none)" "$good"
    [[ "$F" == 0 && "$(grep -c 'SKIPPED' "$WORK/out.txt")" == 1 ]] && ok=$((ok + 1))
    echo "$ok"
}
ALL=$((NFX + 3))
M=0
weaken() { # weaken <name> <old> <new>: the repo's verify-iso.sh with OLD replaced by NEW, cut and run
    local name="$1" old="$2" new="$3" copy cut ok
    M=$((M + 1)); copy="$WORK/weak-$M.sh"; cut="$WORK/weak-$M-section.sh"
    cp "$REAL_VERIFY" "$copy"
    if ! replace_in "$copy" "$old" "$new"; then t_fail "weakening '$name': the text to replace is not in verify-iso.sh (a replacement that matches nothing proves nothing)"; return; fi
    cut_section "$copy" "$cut"
    ok="$(scenarios_behaving "$cut" "w$M")"
    if [[ "$ok" -lt "$ALL" ]]; then t_pass "caught: $name ($((ALL - ok)) of $ALL scenarios stopped behaving)"; else t_fail "NOT CAUGHT: $name (all $ALL scenarios still behave)"; fi
}
eq "control: the unweakened section behaves in all $ALL scenarios (so a catch below means the weakening, not the machinery)" "$(scenarios_behaving "$SECT" control)" "$ALL"
weaken "the lint call deleted" 'if memprot_out="$(ci_os_memprot_lint "$R" ubuntu)"; then' 'if memprot_out=""; then'
weaken "the lint run for the wrong edition" 'ci_os_memprot_lint "$R" ubuntu)"; then' 'ci_os_memprot_lint "$R" cachyos)"; then'
weaken "the lint run on another root" 'ci_os_memprot_lint "$R" ubuntu)"; then' 'ci_os_memprot_lint "$R/etc" ubuntu)"; then'
weaken "a FAIL line of the lint no longer becomes a FAIL" 'case "$memprot_line" in "FAIL: "*)' 'case "$memprot_line" in "FAIL-: "*)'
weaken "the label of the FAIL lines changed" 'fail "memory protection: ${memprot_line#FAIL: }"' 'fail "${memprot_line#FAIL: }"'
weaken "a lint that fails without a message is not noticed" '[[ "$memprot_n" -gt 0 ]] || fail' '[[ "$memprot_n" -gt 0 ]] || true'
weaken "the skip without the library becomes a pass" 'skip "memory protection drop-ins (core/lib/memory-protection.sh not found next to this script)"' 'pass "memory protection: nothing to check"'

echo
echo "== 6. a copy of verify-iso.sh outside the repository"
run_section "$NO_LIB" "$good"
eq "the section is listed as SKIPPED and fails nothing (VERIFY_REQUIRE_CANON=1 turns that into a failure)" "$F:$(grep -c 'SKIPPED' "$WORK/out.txt")" "0:1"
run_section "$NO_LIB" "$WORK/fx-1"
eq "  even for a root that is broken: without the library nothing is judged, and the SKIPPED block says so" "$F:$(grep -c 'SKIPPED' "$WORK/out.txt")" "0:1"

echo "== Summary: $T_PASS passed, $T_FAIL failed"
[[ $T_FAIL -eq 0 ]]
