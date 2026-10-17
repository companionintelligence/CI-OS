#!/usr/bin/env bash
#=============================================================================
# Test: the model tooling's files as files - systemd units, the profile snippet, the conf example, the Arch-based
# edition's copies - without systemd
#
#   * the copies under backends/cachyos/iso/overlay/files/airootfs/usr/share/ci-os/models/ are byte-identical to the payload
#     they copy (they cannot drift), are not executable, have no shebang and no empty file (what that overlay's own tests
#     require), and do not contain the base distribution's name (its leak check);
#   * every line of every unit is a [Section] header, a comment, or a Key=Value with a key and a section systemd(1) knows
#     (a typo such as ExecConditon= is caught); the commands the units run are real `ci-os-models` commands;
#   * the opt-in is real: the service has an ExecCondition and no Restart, the timer needs no flag of its own, the conf
#     example has no active key (loading it gives the defaults), the profile snippet is valid sh and prints nothing without
#     a cache;
#   * the scripts are executable and the data files are not.
#
# What it does NOT do: run systemd. `systemd-analyze verify` is not run here (it needs systemd); run it where it exists.
#
#   bash backends/ubuntu/chroot/tests/models-units.sh        (bash 3.2 or 5)
#
# Exit status: non-zero if any check fails.
#
# (c) Companion Intelligence - Lifescope Inc
#=============================================================================
# shellcheck disable=SC1090,SC2034  # the library is sourced by a variable path; some variables are read only inside subshells
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models-testlib.sh
. "$HERE/lib/models-testlib.sh"
default_stubs

PAYLOAD="$REPO_ROOT/backends/ubuntu/chroot/payload/models"
ARCH="$REPO_ROOT/backends/cachyos/iso/overlay/files/airootfs/usr/share/ci-os/models"
SVC="$PAYLOAD/usr/lib/systemd/system/ci-os-models-prefetch.service"
TMR="$PAYLOAD/usr/lib/systemd/system/ci-os-models-prefetch.timer"
PTH="$PAYLOAD/usr/lib/systemd/system/ci-os-models-prefetch.path"
VIEW="$PAYLOAD/usr/lib/systemd/system/ci-os-hf-view.service"
CONF="$PAYLOAD/usr/share/ci-os/models.conf.example"
PROF="$PAYLOAD/etc/profile.d/ci-os-models.sh"

echo "== the Arch-based edition's copies"
for pair in "ci-os-models-prefetch.service:usr/lib/systemd/system/ci-os-models-prefetch.service" \
            "ci-os-models-prefetch.timer:usr/lib/systemd/system/ci-os-models-prefetch.timer" \
            "ci-os-models-prefetch.path:usr/lib/systemd/system/ci-os-models-prefetch.path" \
            "ci-os-hf-view.service:usr/lib/systemd/system/ci-os-hf-view.service" \
            "models.conf.example:usr/share/ci-os/models.conf.example" \
            "profile-ci-os-models.sh:etc/profile.d/ci-os-models.sh"; do
  copy="${pair%%:*}"; orig="${pair#*:}"
  if cmp -s "$ARCH/$copy" "$PAYLOAD/$orig"; then t_pass "$copy is identical to the payload's $orig"; else t_fail "$copy differs from the payload's $orig (re-copy it)"; fi
done
expect "the ollama drop-in exists" test -s "$ARCH/ollama.service.d-20-ci-os-models.conf"
expect "the README exists" test -s "$ARCH/README"
t_eq "no file there is executable" "" "$(find "$ARCH" -type f -perm -100 | head -1)"
t_eq "no file there is empty" "" "$(find "$ARCH" -type f -size 0 | head -1)"
t_eq "no file there starts with a shebang (the overlay lists every script in file_permissions)" "" "$(grep -rIl '^#!' "$ARCH" | head -1)"
t_eq "no file there names the base distribution (the overlay's leak check)" "" "$(grep -rIil 'cachy' "$ARCH" | head -1)"
t_eq "the drop-in names the same script and env file as the Ubuntu unit" "3" "$(grep -cE '^(ExecStartPre|ExecStopPost|EnvironmentFile)=.*(ollama-models-env|ci-models.env)' "$ARCH/ollama.service.d-20-ci-os-models.conf")"

echo "== units: sections and keys"
# keys systemd.unit(5), systemd.service(5), systemd.timer(5), systemd.exec(5), systemd.resource-control(5) define, as used here
known_keys="Description Documentation After Before Wants Requires ConditionPathExists ConditionKernelCommandLine \
Type RemainAfterExit User Group ExecCondition ExecStart ExecStartPre ExecStop ExecStopPost TimeoutStartSec Restart \
Nice IOSchedulingClass CPUWeight RuntimeDirectory RuntimeDirectoryMode RuntimeDirectoryPreserve Environment \
NoNewPrivileges PrivateTmp ProtectHome ProtectSystem ProtectKernelTunables ProtectKernelModules ProtectControlGroups \
RestrictSUIDSGID LockPersonality OnBootSec OnCalendar OnUnitInactiveSec RandomizedDelaySec AccuracySec Unit WantedBy EnvironmentFile PathExists"
check_unit() { # check_unit <file>: prints nothing when well formed, else one problem per line
  awk -v known="$known_keys" '
    BEGIN { n = split(known, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    /^[ \t]*$/ { next }
    /^[ \t]*[#;]/ { next }
    /^\[(Unit|Service|Timer|Path|Install)\][ \t]*$/ { sec = $0; next }
    /^\[/ { print FILENAME ": unknown section " $0; next }
    {
      if (sec == "") { print "line before any section: " $0; next }
      eq = index($0, "="); if (eq == 0) { print "not Key=Value: " $0; next }
      key = substr($0, 1, eq - 1)
      if (!(key in ok)) print "unknown key " key " in " sec
    }' "$1"
}
for u in "$SVC" "$TMR" "$PTH" "$VIEW"; do
  t_eq "$(basename "$u"): every line is a known section, comment or Key=Value" "" "$(check_unit "$u")"
done
bad="$WORK/bad.service"; printf '[Service]\nExecConditon=/x\nType=oneshot\n' > "$bad"
t_has "the checker catches a typo'd key" "$(check_unit "$bad")" "unknown key ExecConditon"
printf 'Type=oneshot\n' > "$bad"; t_has "...and a line before any section" "$(check_unit "$bad")" "before any section"
printf '[Servce]\nType=oneshot\n' > "$bad"; t_has "...and a typo'd section" "$(check_unit "$bad")" "unknown section"

echo "== units: what they run, and the opt-in"
t_has "the service is a oneshot" "$(cat "$SVC")" "Type=oneshot"
t_has "it runs as the user that owns the exFAT mount" "$(cat "$SVC")" "User=ollama"
t_has "ExecCondition runs prefetch-check" "$(cat "$SVC")" "ExecCondition=/usr/bin/ci-os-models prefetch-check"
t_has "ExecStart runs prefetch" "$(cat "$SVC")" "ExecStart=/usr/bin/ci-os-models prefetch"
t_lacks "the service never restarts itself" "$(cat "$SVC")" "Restart="
t_has "low priority: Nice" "$(cat "$SVC")" "Nice=19"
t_has "low priority: idle I/O" "$(cat "$SVC")" "IOSchedulingClass=idle"
t_has "NoNewPrivileges" "$(cat "$SVC")" "NoNewPrivileges=yes"
t_has "the timer starts the service" "$(cat "$TMR")" "Unit=ci-os-models-prefetch.service"
t_has "the timer has a calendar entry (it re-arms whatever the last run did)" "$(cat "$TMR")" "OnCalendar="
t_lacks "the timer has no [Install] section: nothing but the path unit starts it" "$(grep -v '^[#;]' "$TMR")" "[Install]"
t_has "the path unit starts the timer" "$(cat "$PTH")" "Unit=ci-os-models-prefetch.timer"
t_has "the path unit watches the opt-in flag file" "$(cat "$PTH")" "PathExists=/etc/ci-os/models-prefetch"
t_has "the path unit is the one that is enabled" "$(cat "$PTH")" "WantedBy=multi-user.target"
t_eq "the flag file the path unit watches is the one prefetch-check looks for" "/etc/ci-os/models-prefetch" "$(grep -o '/etc/ci-os/models-prefetch' "$MODELS_SH" | head -1)"
t_lacks "the timer is not tied to a flag unit or a condition of its own (the flag file is the switch)" "$(grep -v '^[#;]' "$TMR")" "Condition"
t_has "the view unit runs the view command quietly" "$(cat "$VIEW")" "ExecStart=/usr/bin/ci-os-models view --quiet"
t_has "the view unit waits for the file systems and for ollama.service" "$(cat "$VIEW")" "After=local-fs.target ollama.service"
help="$(bash "$MODELS_SH" help 2>&1)"
for sub in prefetch-check prefetch view; do
  t_has "'ci-os-models $sub' is a command" "$help" "$sub"
done
t_eq "the commands in the units are the ones the library dispatches" "3" "$(grep -cE 'prefetch-check\) ci_models_prefetch_check|prefetch\) ci_models_cmd_prefetch|view\) ci_models_cmd_view' "$MODELS_SH" | tr -d ' ')"
t_eq "every Exec line of the units runs /usr/bin/ci-os-models and nothing else" "" "$(grep -h '^Exec' "$SVC" "$VIEW" | grep -v '=/usr/bin/ci-os-models ')"

echo "== the conf example and the profile snippet"
t_eq "the conf example has no active key" "0" "$(grep -cE '^[[:space:]]*[a-z_]+[[:space:]]*=' "$CONF")"
t_eq "so loading it gives the defaults (no pack)" "none" "$(CI_OS_MODELS_CONF="$CONF" bash -c '. "$1"; ci_models_conf_get pack none' _ "$MODELS_SH")"
t_eq "its commented keys are exactly the ones the code reads" "accept_licenses assume_unmetered limit_rate offline pack set_hf_home" \
  "$(sed -n 's/^#\([a-z_]*\)=.*/\1/p' "$CONF" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
for key in pack limit_rate assume_unmetered accept_licenses set_hf_home offline; do
  expect "the library reads '$key'" grep -q "ci_models_conf_get $key" "$MODELS_SH"
done
expect "the profile snippet is valid sh" sh -n "$PROF"
expect "...and valid bash" bash -n "$PROF"
t_eq "...and prints nothing and exports nothing when there is no cache" "" "$(
  mkdir -p "$WORK/bin"; printf '#!/bin/sh\nexec bash "%s" "$@"\n' "$MODELS_SH" > "$WORK/bin/ci-os-models"; chmod +x "$WORK/bin/ci-os-models"
  # the snippet calls /usr/bin/ci-os-models; run it with that path replaced, in a clean environment
  sed "s|/usr/bin/ci-os-models|$WORK/bin/ci-os-models|g" "$PROF" > "$WORK/profile-test.sh"
  env -i PATH="$PATH" CI_OS_MODELS_FALLBACK_ROOT="$WORK/nowhere" CI_OS_PROC_NET_ROUTE="$CI_OS_PROC_NET_ROUTE" HOME="$WORK" \
    sh -c '. "$1"; env | grep -E "^(HF_|LLAMA_|OLLAMA_|CI_STICK)" || true' _ "$WORK/profile-test.sh" 2>&1)"
mkdir -p "$WORK/cache/models"
t_has "...and exports the Hugging Face variables when there is one" "$(
  env -i PATH="$PATH" CI_OS_MODELS_CACHE="$WORK/cache" CI_OS_HF_VIEW="$WORK/view" CI_OS_PROC_NET_ROUTE="$CI_OS_PROC_NET_ROUTE" HOME="$WORK" \
    sh -c '. "$1"; echo "$HF_HUB_CACHE|$LLAMA_CACHE|${OLLAMA_MODELS:-unset}"' _ "$WORK/profile-test.sh" 2>&1)" "$WORK/view/hub|$WORK/view/hub|unset"

echo "== modes: scripts are executable, data is not"
if [ -x "$REPO_ROOT/core/manifest/model-packs.yaml" ]; then
  t_skip "this file system reports every file as executable (a Docker Desktop bind mount): the mode checks run on a normal checkout"
else
  for f in "$REPO_ROOT/core/lib/ci-os-models.sh" "$REPO_ROOT/core/lib/gpu-detect.sh" "$REPO_ROOT/backends/ubuntu/chroot/payload/ci-os-ollama-models-env.sh" \
           "$HERE/models-gate.sh" "$HERE/models-view.sh" "$HERE/models-lib.sh" "$HERE/models-env.sh" "$HERE/models-units.sh" \
           "$HERE/models-mutation.sh" "$HERE/models-all.sh"; do
    expect "$(basename "$f") is executable" test -x "$f"
  done
  for f in "$SVC" "$TMR" "$VIEW" "$CONF" "$PROF" "$HERE/lib/models-testlib.sh"; do
    expect_not "$(basename "$f") (no shebang) is not executable" test -x "$f"
    t_eq "$(basename "$f") has no shebang" "0" "$(head -c 2 "$f" | grep -c '^#!' || true)"
  done
  for f in "$REPO_ROOT/core/lib/ci-os-models.sh" "$HERE/models-gate.sh" "$HERE/models-all.sh"; do
    t_eq "$(basename "$f") starts with a shebang" "#!" "$(head -c 2 "$f")"
  done
fi

echo "== names"
files="$REPO_ROOT/core/lib/ci-os-models.sh $REPO_ROOT/core/lib/gpu-detect.sh $PAYLOAD $ARCH $HERE/models-*.sh $HERE/lib $REPO_ROOT/backends/ubuntu/chroot/payload/ci-os-ollama-models-env.sh"
# the retired product names, exactly as core/lib/check-repo.sh spells them
# shellcheck disable=SC2086  # a list of paths
t_eq "no retired product name (check-repo.sh's list)" "" "$(grep -rnE 'CI OS|CI-OS Desktop|CI-OS Blue Teal|Companion Ubuntu|Intelligence Operating System|Companion Intelligence OS|Companion Intelligence [0-9$]' $files 2>/dev/null | grep -v 'models-units.sh' | head -3)"
# shellcheck disable=SC2086
t_eq "no block-letter art" "" "$(grep -rIlF "$(printf '\342\226\210')" $files 2>/dev/null | head -1)"

t_summary "models-units"
