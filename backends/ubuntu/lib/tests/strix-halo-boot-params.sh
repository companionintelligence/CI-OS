#!/bin/sh
#=============================================================================
# Test: backends/ubuntu/lib/strix-halo-boot-params.sh rewrites GRUB_CMDLINE_LINUX_DEFAULT the way it says it does
#
# The script edits /etc/default/grub as root and then runs update-grub, so this test never runs it on the real files. It
# rehearses the real script (a byte-for-byte copy) against throwaway /etc/default/grub files:
#   - the copy sits in a throwaway tree whose core/lib/gpu-detect.sh is a stub: the real support rule, fed made-up facts
#     (RAM, CPU model) instead of /proc/meminfo, lscpu and rocminfo;
#   - PATH holds only symlinks to the few tools the script uses, plus shims for id (root), dpkg-query (the amdgpu-dkms
#     package state), update-grub (records the call) and mv (the real one, unless a case makes the rename fail), so nothing
#     on the machine running the test is touched;
#   - the three CI_OS_* path hooks of the script point into a per-case directory (a GRUB file, a /lib/modules tree and a
#     /sys/module tree), and the script runs in a working directory of its own inside it.
# After every rewrite the file is also sourced by dash and by bash, the way grub-mkconfig sources it (under /bin/sh, which
# is dash on Ubuntu), and the value of GRUB_CMDLINE_LINUX_DEFAULT is compared with the expected one.
#
# This file is POSIX sh, so `sh`, `dash` and `bash` all run it the same way; the script under test needs bash 4 (it sources
# core/lib/gpu-detect.sh), and this rig has only been run on GNU sed and coreutils (Ubuntu 26.04), so on a Mac the test
# exits 2 ("cannot run here"). Run it in a container:
#
#   docker run --rm -v "$PWD":/src:ro -w /src ubuntu:26.04 bash backends/ubuntu/lib/tests/strix-halo-boot-params.sh
#   docker run --rm -v "$PWD":/src:ro -w /src ubuntu:26.04 dash backends/ubuntu/lib/tests/strix-halo-boot-params.sh
#
# BOOT_PARAMS_SCRIPT=/path/to/other.sh runs the same checks against another copy of the script (a candidate, a mutant).
#
# © Companion Intelligence - Lifescope Inc
#=============================================================================
set -u
LC_ALL=C
export LC_ALL

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
SCRIPT="${BOOT_PARAMS_SCRIPT:-$HERE/../strix-halo-boot-params.sh}"
GPU_LIB="$REPO/core/lib/gpu-detect.sh"

cannot_run() {
    echo "cannot run here: $*"
    echo "  it needs GNU sed, bash 4 or newer and a Linux userland; run it in an Ubuntu 26.04 container:"
    echo "  docker run --rm -v \"\$PWD\":/src:ro -w /src ubuntu:26.04 bash backends/ubuntu/lib/tests/strix-halo-boot-params.sh"
    exit 2
}

[ -f "$SCRIPT" ] || { echo "FAIL  the script under test is missing: $SCRIPT"; exit 1; }
[ -f "$GPU_LIB" ] || { echo "FAIL  core/lib/gpu-detect.sh is missing: $GPU_LIB"; exit 1; }

BASH_BIN="$(command -v bash)" || cannot_run "no bash"
"$BASH_BIN" -c '[ "${BASH_VERSINFO:-0}" -ge 4 ]' || cannot_run "bash 4 or newer is needed (core/lib/gpu-detect.sh uses \${var,,})"
ENV_BIN="$(command -v env)" || cannot_run "no env"
for tool in sed grep tail cp mv rm date dirname cat cksum mktemp stat chmod; do
    command -v "$tool" >/dev/null 2>&1 || cannot_run "no $tool"
done
REAL_MV="$(command -v mv)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/boot-params-test.XXXXXX")" || cannot_run "mktemp -d failed"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM

# This tells GNU sed from BSD sed: BSD sed (macOS) reads the script of `sed -i "s|...|"` as the backup suffix. The script under
# test no longer calls sed -i, but the rig has only been run on GNU userland, so any other sed is refused here, not trusted.
printf 'a\n' >"$TMP/sedprobe"
sed -i "s|^a\$|b|" "$TMP/sedprobe" 2>/dev/null && [ "$(cat "$TMP/sedprobe")" = b ] || cannot_run "sed -i is not GNU sed's"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$*"
    if [ -n "${C:-}" ] && [ -f "$C/out" ]; then
        sed 's/^/      out| /' "$C/out" | tail -n 6
        sed 's/^/      err| /' "$C/err" | tail -n 6
    fi
}
expect() { label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

# --- the rehearsal rig ---------------------------------------------------------------------------------------------------
TOOLS="$TMP/tools"
GRUB_SHIM="$TMP/grub-shim"
TREE="$TMP/tree"
mkdir -p "$TOOLS" "$GRUB_SHIM" "$TREE/core/lib" "$TREE/backends/ubuntu/lib"

for tool in sed grep tail cp rm date dirname; do
    ln -s "$(command -v "$tool")" "$TOOLS/$tool"
done
cat >"$TOOLS/id" <<'EOF'
#!/bin/sh
# stand-in for id: the script asks only `id -u`
if [ "${1:-}" = "-u" ]; then echo "$T_UID"; else echo "id shim: only -u" >&2; exit 1; fi
EOF
cat >"$TOOLS/dpkg-query" <<'EOF'
#!/bin/sh
# stand-in for dpkg-query: answers the amdgpu-dkms status question from T_DPKG_STATUS (empty = dpkg does not know the package)
echo "dpkg-query $*" >>"$T_CALLS"
if [ -n "$T_DPKG_STATUS" ]; then printf '%s' "$T_DPKG_STATUS"; exit 0; fi
echo "dpkg-query: no packages found matching amdgpu-dkms" >&2
exit 1
EOF
cat >"$GRUB_SHIM/update-grub" <<'EOF'
#!/bin/sh
# stand-in for update-grub: records the call
echo "update-grub" >>"$T_CALLS"
exit 0
EOF
cat >"$TOOLS/mv" <<'EOF'
#!/bin/sh
# stand-in for mv: the real one, unless T_MV_FAILS is set (a rename that cannot happen: a read-only file system, a full disk)
if [ -n "${T_MV_FAILS:-}" ]; then echo "mv: cannot move '$1' to '$2': simulated failure" >&2; exit 1; fi
exec "$T_REAL_MV" "$@"
EOF
chmod +x "$TOOLS/id" "$TOOLS/dpkg-query" "$TOOLS/mv" "$GRUB_SHIM/update-grub"

cat >"$TREE/core/lib/gpu-detect.sh" <<'EOF'
# shellcheck shell=bash
# Test stub: the real support rule, fed made-up facts instead of /proc/meminfo, lscpu and rocminfo.
source "$T_REAL_GPU_LIB"
ci_os_total_ram_mib() { printf '%s\n' "$T_RAM_MIB"; }
ci_os_cpu_model() { printf '%s\n' "$T_CPU"; }
rocminfo_shows_strix_halo() { return 1; }
EOF
cp "$SCRIPT" "$TREE/backends/ubuntu/lib/strix-halo-boot-params.sh"

# The shells that source /etc/default/grub for real: grub-mkconfig runs under /bin/sh (dash on Ubuntu).
SHELLS=""
for s in dash bash; do
    p="$(command -v "$s" 2>/dev/null)" && SHELLS="$SHELLS $p"
done
case "$SHELLS" in *dash*) ;; *) echo "SKIP  dash is not installed here: the file is only sourced by bash" ;; esac

# A stock Ubuntu /etc/default/grub (the backtick line is there to see that nothing else is touched), with the given
# GRUB_CMDLINE_LINUX_DEFAULT line (nothing when it is empty).
make_grub() {
    {
        cat <<'EOF'
# If you change this file, run 'update-grub' afterwards to update
# /boot/grub/grub.cfg.
# For full documentation of the options in this file, see:
#   info -f grub -n 'Simple configuration'

GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=0
GRUB_DISTRIBUTOR=`( . /etc/os-release; echo ${NAME:-Ubuntu} ) 2>/dev/null || echo Ubuntu`
EOF
        [ -n "$2" ] && printf '%s\n' "$2"
        printf 'GRUB_CMDLINE_LINUX=""\n'
    } >"$1"
}

CASE_N=0
C=""
RC=0
T_RAM_MIB=0
T_CPU=""
T_DPKG_STATUS=""
T_UID=0
T_PATH=""
T_MV_FAILS=""
NAMES0=""

# new_case LINE: a fresh case directory whose GRUB file carries LINE, on a 125,780 MiB Strix Halo machine with no DKMS sign
new_case() {
    CASE_N=$((CASE_N + 1))
    C="$TMP/case$CASE_N"
    mkdir -p "$C/modules/7.0.0-14-generic/kernel" "$C/sysmod/ttm" "$C/cwd"
    : >"$C/calls"
    : >"$C/out"
    : >"$C/err"
    make_grub "$C/grub" "$1"
    cp "$C/grub" "$C/grub.orig"
    T_RAM_MIB=125780
    T_CPU="AMD RYZEN AI MAX+ 395 w/ Radeon 8060S"
    T_DPKG_STATUS=""
    T_UID=0
    T_PATH="$GRUB_SHIM:$TOOLS"
    T_MV_FAILS=""
}
# the three signs of the DKMS driver
sign_module() { mkdir -p "$C/modules/$1/updates/dkms"; : >"$C/modules/$1/updates/dkms/amdttm.ko.zst"; }
sign_loaded() { mkdir -p "$C/sysmod/amdttm/parameters"; }
sign_package() { T_DPKG_STATUS="$1"; }

run_script() {
    (
        cd "$C/cwd" || exit 97
        exec "$ENV_BIN" -i PATH="$T_PATH" HOME="$C" LC_ALL=C \
            CI_OS_GRUB_DEFAULT_FILE="$C/grub" CI_OS_MODULES_DIR="$C/modules" CI_OS_SYSFS_MODULE_DIR="$C/sysmod" \
            T_CALLS="$C/calls" T_RAM_MIB="$T_RAM_MIB" T_CPU="$T_CPU" T_DPKG_STATUS="$T_DPKG_STATUS" T_UID="$T_UID" \
            T_MV_FAILS="$T_MV_FAILS" T_REAL_MV="$REAL_MV" T_REAL_GPU_LIB="$GPU_LIB" \
            "$BASH_BIN" "$TREE/backends/ubuntu/lib/strix-halo-boot-params.sh" >"$C/out" 2>"$C/err"
    )
    RC=$?
}

# --- what the checks look at -----------------------------------------------------------------------------------------------
out_has() { grep -qF -- "$1" "$C/out"; }
out_lacks() { ! grep -qF -- "$1" "$C/out"; }
err_has() { grep -qF -- "$1" "$C/err"; }
file_has_line() { grep -qxF -- "$1" "$C/grub"; }
no_amdttm_anywhere() { ! grep -q amdttm "$C/grub" && ! grep -q amdttm "$C/out"; }
same_file() { [ "$(cksum <"$1")" = "$(cksum <"$2")" ]; }
file_untouched() { same_file "$C/grub" "$C/grub.orig"; }
others_untouched() { [ "$(grep -v '^GRUB_CMDLINE_LINUX_DEFAULT=' "$C/grub.orig")" = "$(grep -v '^GRUB_CMDLINE_LINUX_DEFAULT=' "$C/grub")" ]; }
count_calls() { grep -cF -- "$1" "$C/calls"; }
count_backups() {
    n=0
    for f in "$C"/grub.bak.*; do [ -e "$f" ] && n=$((n + 1)); done
    echo "$n"
}
backup_is_the_original() {
    for f in "$C"/grub.bak.*; do [ -e "$f" ] && same_file "$f" "$C/grub.orig" && return 0; done
    return 1
}
cmdline_via() { "$1" -c '. "$1"; printf %s "$GRUB_CMDLINE_LINUX_DEFAULT"' sh "$C/grub" 2>/dev/null; }

# the names in the case directory other than the backup: a rewrite must not leave a temporary file beside the GRUB file
case_names() {
    for cn_path in "$C"/* "$C"/.[!.]*; do
        [ -e "$cn_path" ] || continue
        case "${cn_path##*/}" in grub.bak.*) ;; *) printf '%s\n' "${cn_path##*/}" ;; esac
    done
}
snap() { NAMES0="$(case_names)"; }
expect_clean_dir() { expect "nothing new in the directory but the backup" test "$(case_names)" = "$NAMES0"; }
# put_file: the bytes on stdin become the case's GRUB file (and its pristine copy)
put_file() { cat >"$C/grub"; cp "$C/grub" "$C/grub.orig"; }

# expect_cmdline VALUE: the file has exactly that value, and every shell that sources it gets the same value back
expect_cmdline() {
    ec_want="$1"
    expect "GRUB_CMDLINE_LINUX_DEFAULT is \"$ec_want\"" file_has_line "GRUB_CMDLINE_LINUX_DEFAULT=\"$ec_want\""
    for ec_sh in $SHELLS; do
        expect "  ${ec_sh##*/} sources the file and gets the same value" test "$(cmdline_via "$ec_sh")" = "$ec_want"
    done
}
# expect_rewritten: a rewrite happened once: backup, update-grub, everything else in the file as it was
expect_rewritten() {
    expect "exit status 0" test "$RC" -eq 0
    expect "the old file is kept as grub.bak.<time>, unchanged" backup_is_the_original
    expect "exactly one backup" test "$(count_backups)" -eq 1
    expect "update-grub ran once" test "$(count_calls update-grub)" -eq 1
    expect "no other line of the file changed" others_untouched
    expect "it says it ran update-grub" out_has "[+] Ran update-grub."
}
# expect_left_alone: nothing was written and nothing was run
expect_left_alone() {
    expect "the file is byte for byte as it was" file_untouched
    expect "no backup was made" test "$(count_backups)" -eq 0
    expect "update-grub did not run" test "$(count_calls update-grub)" -eq 0
}

GTT=110058
PAGES=28174848
BASE="iommu=pt amdgpu.gttsize=$GTT ttm.pages_limit=$PAGES"
DKMS="$BASE amdttm.pages_limit=$PAGES"

echo "== a node with the inbox driver (no DKMS sign): the parameters it always got"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
run_script
expect_rewritten
expect_cmdline "quiet splash $BASE"
expect "the sizing line is unchanged: 125780 MiB gives gttsize $GTT and pages_limit $PAGES" out_has "detected with 125780 MiB total RAM"
expect "  and names exactly those two parameters" out_has "targeting amdgpu.gttsize=$GTT ttm.pages_limit=$PAGES"
expect "it says it updated the file" out_has "[+] Updated $C/grub: GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $BASE\""
expect "the reboot line names the three parameters" out_has "(iommu=pt, amdgpu.gttsize, ttm.pages_limit) to take effect."
expect "amdttm is nowhere: not in the file, not in the output" no_amdttm_anywhere
expect "nothing went to stderr" test ! -s "$C/err"

echo
echo "== the same node run again: nothing to do"
cp "$C/grub" "$C/grub.after1"
run_script
expect "exit status 0" test "$RC" -eq 0
expect "it says there is nothing to do" out_has "already has the correct Strix Halo boot params; nothing to do."
expect "the file did not change" same_file "$C/grub" "$C/grub.after1"
expect "still one backup" test "$(count_backups)" -eq 1
expect "update-grub did not run again" test "$(count_calls update-grub)" -eq 1

echo
echo "== an empty value, and tokens it does not manage"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT=""'
run_script
expect_rewritten
expect_cmdline "$BASE"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="ttm.pages_limit=1 quiet amdgpu.dc=1 splash ttm.page_pool_size=3145728 amdgpu.gttsize=3 iommu=pt"'
run_script
expect_rewritten
expect_cmdline "quiet amdgpu.dc=1 splash ttm.page_pool_size=3145728 $BASE"

echo
echo "== the DKMS driver, by each sign: amdttm.pages_limit follows ttm.pages_limit"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
sign_module 7.0.0-38-generic
mkdir -p "$C/modules/7.0.0-30-generic/updates/dkms"
run_script
expect_rewritten
expect_cmdline "quiet splash $DKMS"
expect "it names the sign and the new parameter" out_has "DKMS amdgpu driver found (amdttm is built at $C/modules/7.0.0-38-generic/updates/dkms/amdttm.ko.zst)"
expect "  and targets the same number as ttm.pages_limit" out_has "also targeting amdttm.pages_limit=$PAGES"
expect "the sizing line is the same one" out_has "targeting amdgpu.gttsize=$GTT ttm.pages_limit=$PAGES"
expect "the reboot line names four parameters" out_has "(iommu=pt, amdgpu.gttsize, ttm.pages_limit, amdttm.pages_limit) to take effect."
expect "sign 2 is enough: no dpkg-query was needed" test "$(count_calls dpkg-query)" -eq 0

new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
sign_loaded
run_script
expect_rewritten
expect_cmdline "quiet splash $DKMS"
expect "it names the sign" out_has "DKMS amdgpu driver found (the module amdttm is loaded)"

new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
sign_package installed
run_script
expect_rewritten
expect_cmdline "quiet splash $DKMS"
expect "it names the sign" out_has "DKMS amdgpu driver found (the package amdgpu-dkms is installed)"
expect "it asked dpkg-query about amdgpu-dkms" test "$(count_calls 'dpkg-query -W -f ${db:Status-Status} amdgpu-dkms')" -eq 1

new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
sign_module 7.0.0-22-generic
sign_loaded
sign_package installed
run_script
expect_rewritten
expect_cmdline "quiet splash $DKMS"
expect "all three signs together give the same line, once" test "$(grep -c amdttm "$C/grub")" -eq 1

echo "-- the built module may be stored plain or compressed (DKMS on Ubuntu writes .ko.zst)"
for module_file in amdttm.ko amdttm.ko.zst amdttm.ko.xz amdttm.ko.gz; do
    new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
    mkdir -p "$C/modules/7.0.0-38-generic/updates/dkms"
    : >"$C/modules/7.0.0-38-generic/updates/dkms/$module_file"
    run_script
    expect "$module_file is the sign: amdttm.pages_limit is added" file_has_line "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $DKMS\""
done

echo
echo "== things that look like DKMS and are not: the line stays what the inbox driver gets"
# fzzy, 2026-10-19: amdgpu-dkms is "config-files" (removed, configuration kept); dpkg still knows the package, so dpkg -s and
# dpkg-query -W both succeed for it. "not-installed" is there because it contains the word "installed".
for status in config-files not-installed half-configured unpacked ""; do
    new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
    sign_package "$status"
    run_script
    expect_rewritten
    expect_cmdline "quiet splash $BASE"
    expect "dpkg status '${status:-unknown package}': no amdttm anywhere" no_amdttm_anywhere
done
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
mkdir -p "$C/modules/7.0.0-38-generic/kernel/drivers/gpu/drm/ttm" "$C/modules/7.0.0-38-generic/updates/dkms"
: >"$C/modules/7.0.0-38-generic/kernel/drivers/gpu/drm/ttm/ttm.ko.zst"
: >"$C/modules/7.0.0-38-generic/updates/dkms/nvidia.ko.zst"
: >"$C/modules/7.0.0-38-generic/updates/dkms/amdttm-notes.txt"
run_script
expect_rewritten
expect_cmdline "quiet splash $BASE"
expect "the kernel's own ttm, another DKMS module and a file that only starts with amdttm are not the sign" no_amdttm_anywhere
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
rm -rf "$C/modules" "$C/sysmod"
run_script
expect_rewritten
expect_cmdline "quiet splash $BASE"
expect "no /lib/modules and no /sys/module at all (a chroot) is not an error" no_amdttm_anywhere

echo
echo "== the DKMS node run again: nothing to do"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
sign_module 7.0.0-38-generic
run_script
cp "$C/grub" "$C/grub.after1"
run_script
expect "exit status 0" test "$RC" -eq 0
expect "it says there is nothing to do" out_has "already has the correct Strix Halo boot params; nothing to do."
expect "the file did not change" same_file "$C/grub" "$C/grub.after1"
expect "update-grub ran only the first time" test "$(count_calls update-grub)" -eq 1

echo
echo "== core-7 as it was measured on 2026-10-19: its hand-fixed line is what the script writes, so the script leaves it alone"
new_case "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $DKMS\""
sign_module 7.0.0-22-generic
sign_module 7.0.0-34-generic
sign_module 7.0.0-38-generic
sign_loaded
sign_package installed
run_script
expect "exit status 0" test "$RC" -eq 0
expect "it says there is nothing to do" out_has "already has the correct Strix Halo boot params; nothing to do."
expect_left_alone

echo
echo "== stale values are replaced, in the right order, with the user's tokens kept"
# 96 GiB is what the script used to write on every machine; the line also carries an amdttm value from the same time
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=pt amdgpu.gttsize=98304 ttm.pages_limit=25165824 amdttm.pages_limit=25165824"'
sign_module 7.0.0-38-generic
run_script
expect_rewritten
expect_cmdline "quiet splash $DKMS"

new_case 'GRUB_CMDLINE_LINUX_DEFAULT="amdttm.pages_limit=2 quiet ttm.pages_limit=1 amdgpu.dc=1 splash amdgpu.gttsize=3 amdttm.pages_limit=4"'
sign_package installed
run_script
expect_rewritten
expect_cmdline "quiet amdgpu.dc=1 splash $DKMS"

echo "-- the DKMS driver was removed since the last run: its parameter goes"
new_case "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $DKMS\""
sign_package config-files
run_script
expect_rewritten
expect_cmdline "quiet splash $BASE"
expect "amdttm is nowhere" no_amdttm_anywhere

echo "-- the DKMS driver was installed since the last run: the next run adds its parameter"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
run_script
expect_cmdline "quiet splash $BASE"
sign_module 7.0.0-38-generic
run_script
expect "exit status 0" test "$RC" -eq 0
expect_cmdline "quiet splash $DKMS"
expect "update-grub ran for both changes" test "$(count_calls update-grub)" -eq 2

echo "-- the RAM was upgraded since the last run (64 GiB to 125,780 MiB)"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=pt amdgpu.gttsize=57344 ttm.pages_limit=14680064 amdttm.pages_limit=14680064"'
sign_loaded
run_script
expect_rewritten
expect_cmdline "quiet splash $DKMS"

echo
echo "== other RAM sizes: the sizing is unchanged and amdttm always takes the ttm number"
# 31,000 MiB: one eighth is 3,875 MiB, below the 4,096 MiB floor, so the reserve is 4,096 and the GTT 26,904 MiB
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
T_RAM_MIB=31000
run_script
expect_rewritten
expect_cmdline "quiet splash iommu=pt amdgpu.gttsize=26904 ttm.pages_limit=6887424"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
T_RAM_MIB=31000
sign_loaded
run_script
expect_rewritten
expect_cmdline "quiet splash iommu=pt amdgpu.gttsize=26904 ttm.pages_limit=6887424 amdttm.pages_limit=6887424"
# 131,072 MiB: the reserve is 16,384 MiB, the GTT 114,688 MiB
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
T_RAM_MIB=131072
sign_loaded
run_script
expect_rewritten
expect_cmdline "quiet splash iommu=pt amdgpu.gttsize=114688 ttm.pages_limit=29360128 amdttm.pages_limit=29360128"

echo
echo "== a line the script cannot read safely is refused, with or without the DKMS driver, and nothing is written"
for line in "GRUB_CMDLINE_LINUX_DEFAULT='quiet splash'" 'GRUB_CMDLINE_LINUX_DEFAULT=quiet' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash" # keep'; do
    for sign in none dkms; do
        new_case "$line"
        [ "$sign" = dkms ] && { sign_module 7.0.0-38-generic; sign_package installed; }
        run_script
        expect "[$sign] $line: exit status 1" test "$RC" -eq 1
        expect "  it says the line is not in the expected double-quoted format" err_has "is not in the expected double-quoted format; refusing to guess a format"
        expect_left_alone
    done
done

echo
echo "== no line, a commented-out line, no file"
new_case ""
run_script
expect "no line: exit status 1" test "$RC" -eq 1
expect "  it says there is no GRUB_CMDLINE_LINUX_DEFAULT line" err_has "No GRUB_CMDLINE_LINUX_DEFAULT line found"
expect_left_alone
new_case '#GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
run_script
expect "only a comment: exit status 1" test "$RC" -eq 1
expect "  it says there is no GRUB_CMDLINE_LINUX_DEFAULT line" err_has "No GRUB_CMDLINE_LINUX_DEFAULT line found"
expect_left_alone
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
rm -f "$C/grub"
run_script
expect "no file: exit status 1" test "$RC" -eq 1
expect "  it says the file is not found" err_has "not found; cannot set kernel boot parameters."
expect "update-grub did not run" test "$(count_calls update-grub)" -eq 0

echo
echo "== hardware the script leaves alone, even when a DKMS sign is there"
for fact in "Intel(R) Core(TM) Ultra 7 155H|125780" "AMD Ryzen AI 9 HX 370 w/ Radeon 890M|125780" "AMD RYZEN AI MAX+ 395 w/ Radeon 8060S|16000"; do
    new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
    sign_module 7.0.0-38-generic
    sign_package installed
    T_CPU="${fact%|*}"
    T_RAM_MIB="${fact#*|}"
    run_script
    expect "${T_CPU} with ${T_RAM_MIB} MiB: exit status 0" test "$RC" -eq 0
    expect "  it says the hardware is unsupported" out_has "Unsupported hardware"
    expect_left_alone
    expect "  it did not look for the DKMS driver" test "$(count_calls dpkg-query)" -eq 0
done
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
T_UID=1000
run_script
expect "not root: exit status 1" test "$RC" -eq 1
expect "  it says the privileges are missing" out_has "Missing privileges."
expect_left_alone

echo
echo "== no update-grub on the machine: the file is written and the missing command is said"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
sign_loaded
T_PATH="$TOOLS"
run_script
expect "exit status 0" test "$RC" -eq 0
expect_cmdline "quiet splash $DKMS"
expect "it says GRUB was not regenerated" err_has "update-grub not found; boot params written to $C/grub but GRUB config was NOT regenerated."
expect "it does not claim to have run update-grub" out_lacks "[+] Ran update-grub."

echo
echo "== the user's own kernel parameters come back exactly as they were"
# The line used to be written by sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|<new line>|", and in a sed replacement & is the matched
# text, a backslash escapes and | ends the expression. Every case has an existing line "quiet TEXT splash": TEXT is a parameter
# written the way it stands in the file, VALUE is what a shell that sources the file reads for it (the two differ wherever TEXT
# has a backslash: grub-mkconfig reads \\ as one backslash, \$ as a dollar sign, \` as a backtick and \" as a double quote).
# The file must come back byte for byte with only the managed parameters added, both shells must read the same VALUE as before,
# and a second run must find nothing to do.
hostile() {
    h_label="$1"; h_text="$2"; h_value="$3"
    printf '%s\n' "-- $h_label: $h_text"
    new_case "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet $h_text splash\""
    make_grub "$C/grub.want" "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet $h_text splash $BASE\""
    for h_sh in $SHELLS; do
        expect "before: ${h_sh##*/} reads the line as: quiet $h_value splash" test "$(cmdline_via "$h_sh")" = "quiet $h_value splash"
    done
    snap
    run_script
    expect_rewritten
    expect "it says what it wrote, as written" out_has "[+] Updated $C/grub: GRUB_CMDLINE_LINUX_DEFAULT=\"quiet $h_text splash $BASE\""
    expect "the file is the original with only that line replaced, byte for byte" same_file "$C/grub" "$C/grub.want"
    for h_sh in $SHELLS; do
        expect "after: ${h_sh##*/} reads the line as: quiet $h_value splash $BASE" test "$(cmdline_via "$h_sh")" = "quiet $h_value splash $BASE"
    done
    expect_clean_dir
    cp "$C/grub" "$C/grub.after1"
    run_script
    expect "run again: exit status 0" test "$RC" -eq 0
    expect "  it says there is nothing to do" out_has "already has the correct Strix Halo boot params; nothing to do."
    expect "  the file did not change" same_file "$C/grub" "$C/grub.after1"
    expect "  update-grub did not run again" test "$(count_calls update-grub)" -eq 1
}
hostile 'ampersand' 'foo=a&b' 'foo=a&b'
hostile 'pipe' 'foo=a|b' 'foo=a|b'
hostile 'doubled backslash' 'foo=a\\b' 'foo=a\b'
hostile 'escaped dollar sign' 'foo=\$HOME' 'foo=$HOME'
hostile 'escaped backtick' 'foo=\`id\`' 'foo=`id`'
hostile 'escaped double quote' 'foo=\"a\"' 'foo="a"'
hostile 'single quote' "foo='a'" "foo='a'"
hostile 'dollar sign, unescaped' 'foo=$ci_os_unset' 'foo='
hostile 'backslash and ampersand' 'foo=a\&b' 'foo=a\&b'
hostile 'backslash n' 'foo=a\nb' 'foo=a\nb'
hostile 'backslash and a digit' 'foo=a\1b' 'foo=a\1b'
hostile 'printf directives' 'foo=50%s%b%d' 'foo=50%s%b%d'
hostile 'punctuation' 'foo=/dev/sda1,x:y@z%1#2~3^4=!' 'foo=/dev/sda1,x:y@z%1#2~3^4=!'
hostile 'all of it at once' 'foo=a&b|c\\d\$e\`f\"g%s' 'foo=a&b|c\d$e`f"g%s'

echo
echo "== the rest of the file comes back byte for byte"
# expect_swapped LABEL: one run, and the file is now exactly grub.want
expect_swapped() {
    expect "$1: exit status 0" test "$RC" -eq 0
    expect "  the file is byte for byte what was wanted" same_file "$C/grub" "$C/grub.want"
    expect "  the old file is kept as grub.bak.<time>, unchanged" backup_is_the_original
    expect "  update-grub ran once" test "$(count_calls update-grub)" -eq 1
    expect_clean_dir
}
# odd_lines LINE: a GRUB file whose other lines are what a careless copy mangles: printf directives and backslashes, a leading
# tab, a line of blanks, trailing spaces, lines that look like echo options
odd_lines() {
    cat <<'EOF'
# 100% sure: %s %b %d \n \t \\ \x41 \0 `no` $HOME "q" 'q'
-n
-e
EOF
    printf '\ta line that starts with a tab\n'
    printf '   \n\n'
    printf 'GRUB_TIMEOUT=0   \n'
    printf '%s\n' "$1"
    printf 'GRUB_CMDLINE_LINUX=""\n'
}
# look_alikes LINE: lines that start like the one the script rewrites and are not it
look_alikes() {
    cat <<'EOF'
#GRUB_CMDLINE_LINUX_DEFAULT="from a comment"
# GRUB_CMDLINE_LINUX_DEFAULT="from another comment"
EOF
    printf ' GRUB_CMDLINE_LINUX_DEFAULT="indented"\n'
    printf 'GRUB_CMDLINE_LINUX_DEFAULT_EXTRA="another variable"\n'
    printf 'XGRUB_CMDLINE_LINUX_DEFAULT="prefixed"\n'
    printf '%s\n' "$1"
    printf 'GRUB_CMDLINE_LINUX="keep me"\n'
}

echo "-- the line is the last one and the file has no newline at its end"
new_case ""
printf '# stock\nGRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' | put_file
printf '# stock\nGRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash %s"' "$BASE" >"$C/grub.want"
snap
run_script
expect_swapped "no newline after the line"

echo "-- the file has no newline at its end and the last line is another one"
new_case ""
printf 'GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\nGRUB_CMDLINE_LINUX=""' | put_file
printf 'GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash %s"\nGRUB_CMDLINE_LINUX=""' "$BASE" >"$C/grub.want"
snap
run_script
expect_swapped "no newline after the last line"

echo "-- the line is the only one and has no newline"
new_case ""
printf 'GRUB_CMDLINE_LINUX_DEFAULT=""' | put_file
printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"' "$BASE" >"$C/grub.want"
snap
run_script
expect_swapped "one line, no newline"

echo "-- other lines end in a carriage return (a file edited on Windows)"
new_case ""
printf 'GRUB_DEFAULT=0\r\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\nGRUB_TIMEOUT=0\r\n' | put_file
printf 'GRUB_DEFAULT=0\r\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash %s"\nGRUB_TIMEOUT=0\r\n' "$BASE" >"$C/grub.want"
snap
run_script
expect_swapped "carriage returns"

echo "-- other lines a careless copy would mangle: printf directives, backslashes, a tab, blanks, trailing spaces, echo options"
new_case ""
odd_lines 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' | put_file
odd_lines "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $BASE\"" >"$C/grub.want"
snap
run_script
expect_swapped "odd lines"

echo "-- lines that only start like it (a comment, an indented line, GRUB_CMDLINE_LINUX_DEFAULT_EXTRA, a prefix) are left alone"
new_case ""
look_alikes 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' | put_file
look_alikes "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $BASE\"" >"$C/grub.want"
snap
run_script
expect_swapped "look-alikes"

echo "-- two lines set it: both are replaced, with the line worked out from the last one"
new_case ""
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\nGRUB_TIMEOUT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' | put_file
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash %s"\nGRUB_TIMEOUT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash %s"\n' "$BASE" "$BASE" >"$C/grub.want"
snap
run_script
expect_swapped "two assignments"

echo
echo "== the rewritten file keeps the mode and the owner of the one it replaces"
for mode in 600 640 664; do
    new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
    chmod "$mode" "$C/grub"
    run_script
    expect "mode $mode: exit status 0" test "$RC" -eq 0
    expect "  the file is rewritten" file_has_line "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $BASE\""
    expect "  and is still mode $mode" test "$(stat -c %a "$C/grub")" = "$mode"
done
if [ "$(id -u)" -eq 0 ] && command -v chown >/dev/null 2>&1; then
    new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
    chmod 640 "$C/grub"
    chown 4242:4343 "$C/grub"
    run_script
    expect "owner 4242:4343: exit status 0" test "$RC" -eq 0
    expect "  the file is rewritten" file_has_line "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $BASE\""
    expect "  and is still owned by 4242:4343" test "$(stat -c %u:%g "$C/grub")" = "4242:4343"
else
    echo "SKIP  not root here: the owner of the rewritten file is not checked"
fi

echo
echo "== a rewrite that fails leaves the file as it was, and no temporary file behind"
new_case 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
T_MV_FAILS=1
snap
run_script
expect "the rename fails: exit status 1" test "$RC" -eq 1
expect "  it says the file was left as it was" err_has "Could not rewrite $C/grub; the file was left as it was and update-grub was not run."
expect "  the file is byte for byte as it was" file_untouched
expect "  the old file is still kept as grub.bak.<time>, unchanged" backup_is_the_original
expect "  update-grub did not run" test "$(count_calls update-grub)" -eq 0
expect "  it does not say it updated the file" out_lacks "[+] Updated"
expect_clean_dir

echo
echo "== the real paths are still the defaults"
expect "GRUB file: /etc/default/grub" grep -qF 'GRUB_DEFAULT_FILE="${CI_OS_GRUB_DEFAULT_FILE:-/etc/default/grub}"' "$SCRIPT"
expect "kernel modules: /lib/modules" grep -qF 'MODULES_DIR="${CI_OS_MODULES_DIR:-/lib/modules}"' "$SCRIPT"
expect "sysfs modules: /sys/module" grep -qF 'SYSFS_MODULE_DIR="${CI_OS_SYSFS_MODULE_DIR:-/sys/module}"' "$SCRIPT"
expect "the strip list knows amdttm.pages_limit" grep -qF 'iommu=pt|amdgpu.gttsize=*|ttm.pages_limit=*|amdttm.pages_limit=*) continue ;;' "$SCRIPT"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
