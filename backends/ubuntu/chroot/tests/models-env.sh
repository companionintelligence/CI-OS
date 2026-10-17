#!/usr/bin/env bash
#=============================================================================
# Test: backends/ubuntu/chroot/payload/ci-os-ollama-models-env.sh (installed as /usr/libexec/ci-os/ollama-models-env,
# the ExecStartPre of ollama.service) - the existing contract, and the Hugging Face / llama.cpp additions
#
# Runs the real script as an ordinary user against PATH stubs (id, blkid, findmnt, mount, umount, runuser, getent) and
# temporary directories standing in for /run/ollama, /etc/ci-os and the mount point. What it proves:
#   * the old behaviour is untouched: opt-out file, no ollama user, no volume, a volume that is not exFAT, a mount that
#     fails, a directory the ollama user cannot write: each writes an EMPTY environment file, logs at most one line and
#     exits 0; a usable volume is mounted for the ollama user with the old options and gives OLLAMA_MODELS and
#     OLLAMA_NOPRUNE=1; `release` unmounts only what the script mounted;
#   * with /usr/bin/ci-os-models installed the same file also carries HF_HUB_CACHE, HUGGINGFACE_HUB_CACHE, LLAMA_CACHE
#     and CI_STICK_CACHE, and the Hugging Face view is built; if the helper is missing, fails, disagrees about
#     OLLAMA_MODELS or prints junk, the file is the two OLLAMA_* lines (or the well-formed lines only);
#   * the mount options can be widened (CI_OS_CACHE_UMASK, CI_OS_CACHE_GROUP) and nothing else changes them.
# The exFAT mount itself needs a block device and root; here `mount` is a stub, so what is checked is the command the
# script would run. (The mount was tested on a real exFAT image on 2026-10-13: docs/architecture/tier-b-tools.md, 5.)
#
#   bash backends/ubuntu/chroot/tests/models-env.sh        (bash 3.2 or 5)
#
# Exit status: non-zero if any check fails; 2 if it cannot run here.
#
# (c) Companion Intelligence - Lifescope Inc
#=============================================================================
# shellcheck disable=SC1090,SC2034  # the library is sourced by a variable path; some variables are read only inside subshells
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models-testlib.sh
. "$HERE/lib/models-testlib.sh"
SCRIPT="${CI_MODELS_TEST_ENV_SCRIPT:-$HERE/../payload/ci-os-ollama-models-env.sh}"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 2; }

# The script insists on a block device for the label's device node (`[ -b "$dev" ]`). Use a real one if there is one.
BLK=""
for d in /dev/disk0 /dev/loop0 /dev/sda /dev/vda /dev/nvme0n1 /dev/mmcblk0 /dev/xvda; do
  if [ -b "$d" ]; then BLK="$d"; break; fi
done
if [ -z "$BLK" ] && [ "$(id -u)" -eq 0 ]; then
  mknod "$WORK/blockdev" b 7 99 2>/dev/null && BLK="$WORK/blockdev"
fi
[ -n "$BLK" ] || { echo "no block device node to stand in for the CI-CACHE partition (need /dev/disk0, /dev/loop0, /dev/sda... or root for mknod)" >&2; exit 2; }

CASE=0
setup() { # fresh T with run dir, etc dir, mount point, the stubs, and a helper wrapper around the real library
  CASE=$((CASE + 1))
  T="$WORK/env$CASE"; mkdir -p "$T/run" "$T/etc" "$T/mnt" "$T/bin" "$T/cwd"
  default_stubs
  mkstub id 'case "$*" in
  "-u ollama") [ -e "$FAKE/no-ollama-user" ] && exit 1; echo 999 ;;
  "-g ollama") echo 998 ;;
  *) exec /usr/bin/id "$@" ;;
esac'
  mkstub mount 'exit "$(cat "$FAKE/mount.rc" 2>/dev/null || echo 0)"'
  mkstub umount 'exit 0'
  mkstub runuser '[ -e "$FAKE/runuser.fail" ] && exit 1; shift 3; exec "$@"'
  mkstub getent 'cat "$FAKE/getent.group" 2>/dev/null; exit 0'
  mkstub timeout 'shift; exec "$@"'
  fake blkid.label "$BLK"; fake blkid.type exfat
  printf '#!/bin/sh\nexec bash "%s" "$@"\n' "$MODELS_SH" > "$T/bin/ci-os-models"; chmod +x "$T/bin/ci-os-models"
  export CI_OS_OLLAMA_RUN_DIR="$T/run" CI_OS_ETC_DIR="$T/etc" CI_OS_CACHE_MOUNT="$T/mnt" CI_OS_MODELS_BIN="$T/bin/ci-os-models"
  export CI_OS_HF_VIEW="$T/view" CI_OS_MODELS_CONF="$T/none.conf"
  unset CI_OS_CACHE_UMASK CI_OS_CACHE_GROUP CI_OS_MODEL_LOCK_FILE CI_OS_MODELS_CACHE
}
envrun() { # envrun [release]: sets rc and err; the environment file is $T/run/ci-models.env
  rc=0; (cd "$T/cwd" && bash "$SCRIPT" "$@") >"$T/stdout" 2>"$T/stderr" || rc=$?; err="$(cat "$T/stderr")"
}
envfile() { cat "$T/run/ci-models.env" 2>/dev/null; }

echo "== the old contract"
setup; touch "$T/etc/ollama-no-cache"; envrun
t_eq "opt-out file: exit 0" "0" "$rc"
expect "opt-out file: an environment file exists" test -f "$T/run/ci-models.env"
t_eq "opt-out file: and it is empty" "0" "$(wc -c < "$T/run/ci-models.env" | tr -d ' ')"
t_eq "opt-out file: no mount" "" "$(stub_log mount)"
t_has "opt-out file: one line says why" "$err" "disabled by"

setup; fake no-ollama-user 1; envrun
t_eq "no ollama user: exit 0, empty file" "0:0" "$rc:$(wc -c < "$T/run/ci-models.env" | tr -d ' ')"
t_has "no ollama user: says so" "$err" "no ollama user"

setup; unfake blkid.label; envrun
t_eq "no CI-CACHE volume: exit 0, empty file" "0:0" "$rc:$(wc -c < "$T/run/ci-models.env" | tr -d ' ')"
t_eq "no CI-CACHE volume (the normal case): says nothing" "" "$err"

setup; fake blkid.type vfat; envrun
t_eq "the volume is not exFAT: empty file, no mount" "0:0:" "$rc:$(wc -c < "$T/run/ci-models.env" | tr -d ' '):$(stub_log mount)"
t_has "and says so" "$err" "is not exFAT"

setup; fake mount.rc 32; envrun
t_eq "mount fails: exit 0, empty file" "0:0" "$rc:$(wc -c < "$T/run/ci-models.env" | tr -d ' ')"
t_has "and says why" "$err" "could not mount"
expect_not "no stamp is left behind after a failed mount" test -e "$T/run/ci-cache-mounted-by-us"

setup; fake runuser.fail 1; envrun
t_eq "the ollama user cannot write the volume: exit 0, empty file" "0:0" "$rc:$(wc -c < "$T/run/ci-models.env" | tr -d ' ')"
t_has "and says so" "$err" "not writable by the ollama user"

echo "== a usable volume, without the helper: exactly the old two lines"
setup; export CI_OS_MODELS_BIN="$T/bin/none"; envrun
t_eq "exit 0" "0" "$rc"
t_eq "mounted once, for the ollama user, with the old options" "-t exfat -o uid=999,gid=998,umask=0077,nosuid,nodev,noexec $BLK $T/mnt" "$(stub_log mount)"
t_eq "the file is OLLAMA_MODELS and OLLAMA_NOPRUNE=1, nothing else" "OLLAMA_MODELS=$T/mnt/models
OLLAMA_NOPRUNE=1" "$(envfile)"
expect "the models directory was made" test -d "$T/mnt/models"
expect "the stamp says this script mounted it" test -e "$T/run/ci-cache-mounted-by-us"
t_eq "the file is world-readable (0644)" "-rw-r--r--" "$(ls -l "$T/run/ci-models.env" | cut -c1-10)"
t_has "one log line names the directory" "$err" "models on $T/mnt/models"
envrun release
t_eq "release unmounts what it mounted" "$T/mnt" "$(stub_log umount)"
expect_not "and removes the stamp" test -e "$T/run/ci-cache-mounted-by-us"
clear_logs; envrun release
t_eq "release again: nothing to unmount" "0:" "$rc:$(stub_log umount)"

setup; mkdir -p "$T/elsewhere"; fake findmnt.dev "$T/elsewhere"; export CI_OS_MODELS_BIN="$T/bin/none"; envrun
t_eq "a volume that something else mounted is used where it is, not mounted again" "0:" "$rc:$(stub_log mount)"
t_eq "and its directory is the one in the file" "OLLAMA_MODELS=$T/elsewhere/models
OLLAMA_NOPRUNE=1" "$(envfile)"
clear_logs; envrun release
t_eq "release leaves a mount it did not make alone" "" "$(stub_log umount)"

echo "== mount options"
setup; export CI_OS_MODELS_BIN="$T/bin/none" CI_OS_CACHE_UMASK=0027; envrun
t_has "CI_OS_CACHE_UMASK=0027 widens the mask" "$(stub_log mount)" "umask=0027,"
setup; export CI_OS_MODELS_BIN="$T/bin/none" CI_OS_CACHE_UMASK=022; envrun
t_has "a three-digit mask is accepted" "$(stub_log mount)" "umask=022,"
for bad in "99z" "0o77" "1777" "0077; id" '$(id)' ""; do
  setup; export CI_OS_MODELS_BIN="$T/bin/none" CI_OS_CACHE_UMASK="$bad"; envrun
  t_has "a bad CI_OS_CACHE_UMASK ('$bad') falls back to 0077" "$(stub_log mount)" "umask=0077,"
done
setup; export CI_OS_MODELS_BIN="$T/bin/none" CI_OS_CACHE_UMASK=bad; envrun
t_has "and a bad mask is mentioned" "$err" "not an octal mask"
setup; export CI_OS_MODELS_BIN="$T/bin/none" CI_OS_CACHE_GROUP=ci-models; fake getent.group "ci-models:x:2345:liam"; envrun
t_has "CI_OS_CACHE_GROUP=ci-models: gid=2345" "$(stub_log mount)" "uid=999,gid=2345,"
setup; export CI_OS_MODELS_BIN="$T/bin/none" CI_OS_CACHE_GROUP=nonesuch; envrun
t_has "an unknown group: the ollama group, and a note" "$(stub_log mount)" "gid=998,"
t_has "the note" "$err" "no group 'nonesuch'"
setup; export CI_OS_MODELS_BIN="$T/bin/none" CI_OS_CACHE_GROUP=weird; fake getent.group "weird:x:0; reboot:"; envrun
t_has "a group entry that is not a number is not used in the options" "$(stub_log mount)" "gid=998,"

echo "== with ci-os-models installed: Hugging Face and llama.cpp variables in the same file"
setup; envrun
t_eq "exit 0" "0" "$rc"
f="$(envfile)"
t_has "OLLAMA_MODELS first, as before" "$f" "OLLAMA_MODELS=$T/mnt/models"
t_has "OLLAMA_NOPRUNE=1" "$f" "OLLAMA_NOPRUNE=1"
t_has "CI_STICK_CACHE is the volume" "$f" "CI_STICK_CACHE=$T/mnt"
t_has "HF_HUB_CACHE is the view" "$f" "HF_HUB_CACHE=$T/view/hub"
t_has "HUGGINGFACE_HUB_CACHE" "$f" "HUGGINGFACE_HUB_CACHE=$T/view/hub"
t_has "LLAMA_CACHE" "$f" "LLAMA_CACHE=$T/view/hub"
t_eq "the first two lines are exactly the old ones, in the old order" "OLLAMA_MODELS=$T/mnt/models
OLLAMA_NOPRUNE=1" "$(envfile | sed -n 1,2p)"
t_eq "every line is KEY=value" "0" "$(envfile | grep -vcE '^[A-Z][A-Z0-9_]*=[^[:cntrl:]]*$' || true)"
t_eq "the file is still world-readable (0644)" "-rw-r--r--" "$(ls -l "$T/run/ci-models.env" | cut -c1-10)"

setup; cache_make "$T/mnt"; blob_make "$T/mnt" "$HEX64_A" "gguf-bytes"
cat > "$T/lock.json" <<JEOF
{"models":[{"hf":{"repo":"unsloth/gemma-3-270m-it-GGUF","revision":"$REV_A","file":"gemma-3-270m-it-Q4_K_M.gguf","sha256":"$HEX64_A"}}]}
JEOF
export CI_OS_MODEL_LOCK_FILE="$T/lock.json"; envrun
L="$T/view/hub/models--unsloth--gemma-3-270m-it-GGUF/snapshots/$REV_A/gemma-3-270m-it-Q4_K_M.gguf"
expect "the Hugging Face view was built from the lock" test -L "$L"
t_eq "and reads through to the blob on the volume" "gguf-bytes" "$(cat "$L" 2>/dev/null)"
t_eq "the build left the environment file intact" "0" "$rc"

setup; printf '#!/bin/sh\nexit 3\n' > "$T/bin/ci-os-models"; envrun
t_eq "a helper that fails: the old two lines" "OLLAMA_MODELS=$T/mnt/models
OLLAMA_NOPRUNE=1" "$(envfile)"
setup; printf '#!/bin/sh\necho OLLAMA_MODELS=/somewhere/else\necho HF_HUB_CACHE=/x\n' > "$T/bin/ci-os-models"; envrun
t_eq "a helper that disagrees about OLLAMA_MODELS is not believed: the old two lines" "OLLAMA_MODELS=$T/mnt/models
OLLAMA_NOPRUNE=1" "$(envfile)"
setup; printf '#!/bin/sh\necho "OLLAMA_MODELS=%s/mnt/models"\necho "OLLAMA_NOPRUNE=1"\necho "junk line without equals"\necho "lower=case"\nprintf "HF_HUB_CACHE=/x\\001y\\n"\necho "LLAMA_CACHE=/ok"\n' "$T" > "$T/bin/ci-os-models"; envrun
t_eq "junk lines from a helper are dropped, well-formed ones kept" "OLLAMA_MODELS=$T/mnt/models
OLLAMA_NOPRUNE=1
LLAMA_CACHE=/ok" "$(envfile)"
setup; printf '#!/bin/sh\necho "OLLAMA_MODELS=%s/mnt/models"\necho "HF_HUB_CACHE=/x"\nsleep 0\n' "$T" > "$T/bin/ci-os-models"; chmod -x "$T/bin/ci-os-models"; envrun
t_eq "a helper that is not executable is ignored: the old two lines" "OLLAMA_MODELS=$T/mnt/models
OLLAMA_NOPRUNE=1" "$(envfile)"

echo "== the unit never fails"
for variant in "ollama-no-cache" "no-user" "no-label" "vfat" "mount-fails" "runuser-fails" "all-good" "helper-fails"; do
  setup
  case "$variant" in
    ollama-no-cache) touch "$T/etc/ollama-no-cache" ;;
    no-user) fake no-ollama-user 1 ;;
    no-label) unfake blkid.label ;;
    vfat) fake blkid.type vfat ;;
    mount-fails) fake mount.rc 1 ;;
    runuser-fails) fake runuser.fail 1 ;;
    helper-fails) printf '#!/bin/sh\nexit 1\n' > "$T/bin/ci-os-models" ;;
  esac
  envrun
  t_eq "$variant: exit status 0" "0" "$rc"
  envrun release
  t_eq "$variant: release exits 0" "0" "$rc"
done

t_summary "models-env"
