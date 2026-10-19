#!/bin/bash
#=============================================================================
# Runs INSIDE the throw-away installed system that tests/installed-boot.sh boots (installed there by installed-boot-disk.sh as
# /usr/local/sbin/ci-installed-boot-probe, started by ci-installed-boot-probe.service only when the kernel command line carries
# ci.bootprobe). Reports on the serial console what the host cannot see from outside, one marker per line:
#
#   CI-PROBE: begin / end            the report is complete between these
#   CI-PROBE-OK <detail>             the display manager's greeter is up and Plymouth has gone: the screen is the login screen
#   CI-PROBE-FAIL <reason>           the display manager did not come up within the time limit
#   CI-PROBE: <key>=<value>          facts for the report (root device, command line, system state, failed units, errors)
#
# The probe judges nothing about the build. It only says whether the greeter is there; the host decides.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
exec 2>/dev/null
TTY="${CI_PROBE_TTY:-/dev/ttyS0}"   # (the override is for the probe's own self-test, lib/selftest.sh)
say() { printf '%s\n' "$*" >> "$TTY"; }   # (append: a device does not mind, and the self-test's TTY is a plain file)
LIMIT="${CI_PROBE_LIMIT:-1200}"

say "CI-PROBE: begin"
say "CI-PROBE: cmdline=$(cat /proc/cmdline)"
say "CI-PROBE: root=$(findmnt -no SOURCE,FSTYPE,OPTIONS / | head -1)"
say "CI-PROBE: kernel=$(uname -r)"
# Secure Boot as the guest sees it: the EFI variable SecureBoot (4 attribute bytes, then 1 = enabled) and the kernel's lockdown mode.
sbvar=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
say "CI-PROBE: efi=$([ -d /sys/firmware/efi ] && echo yes || echo no) secureboot=$( [ -r "$sbvar" ] && od -An -tu1 -j4 -N1 "$sbvar" | tr -d ' ' || echo unknown) lockdown=$(cat /sys/kernel/security/lockdown 2>/dev/null || echo unknown)"
say "CI-PROBE: casper-package=$(dpkg-query -W -f='${Version}' casper 2>/dev/null || echo none)"
say "CI-PROBE: display-manager=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo unset)"

# The greeter's gnome-shell runs as the user of the greeter SESSION: "gdm" up to GDM 46 (Ubuntu 24.04), a dynamic user "gdm-greeter" (uid 60578 and the
# like) since GDM 50 (Ubuntu 26.04). So the user is read from the session and not assumed: a probe that waited for gdm's gnome-shell on 26.04 never saw
# it, sat out its whole limit (1200 s) with the greeter up from the first five minutes, and the screen had blanked by the time the host looked.
greeter_uid=""
greeter_shell_up() { [ -n "$greeter_uid" ] && pgrep -u "$greeter_uid" -x gnome-shell >/dev/null 2>&1; }

start=$(date +%s)
greeter=""
up=""          # set only when the greeter's gnome-shell was seen alive and Plymouth had gone: a greeter SESSION that merely exists proves nothing
lastbeat=0
while :; do
    waited=$(( $(date +%s) - start ))
    if [ "$(systemctl is-active display-manager.service)" = active ]; then
        # A session of class "greeter" is the GDM login screen (gdm-launch-environment); gnome-shell runs as that session's user in it.
        for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{ print $1 }'); do
            if [ "$(loginctl show-session "$s" -p Class --value 2>/dev/null)" = greeter ]; then
                greeter_uid="$(loginctl show-session "$s" -p User --value 2>/dev/null)"
                [ -n "$greeter_uid" ] || greeter_uid=gdm
                greeter="session $s user=$(loginctl show-session "$s" -p Name --value 2>/dev/null) uid=$greeter_uid type=$(loginctl show-session "$s" -p Type --value) state=$(loginctl show-session "$s" -p State --value)"
                break
            fi
        done
        if [ -n "$greeter" ] && greeter_shell_up && ! plymouth --ping >/dev/null 2>&1; then
            sleep 5
            # Still there after 5 s: not a greeter that crashed and is being respawned.
            if greeter_shell_up; then up=1; break; fi
            greeter=""
        fi
    fi
    if [ "$waited" -ge "$LIMIT" ]; then break; fi
    # A heartbeat every 30 s: where the boot is while the greeter is not up (the jobs systemd still runs, the load).
    if [ $((waited - lastbeat)) -ge 30 ]; then
        lastbeat=$waited
        say "CI-PROBE: progress t=${waited}s system=$(systemctl is-system-running 2>&1) display-manager=$(systemctl is-active display-manager.service 2>&1) load=$(cut -d' ' -f1 /proc/loadavg) jobs=$(systemctl list-jobs --no-legend 2>/dev/null | awk '{ print $2 ":" $3 }' | head -6 | tr '\n' ' ')"
    fi
    sleep 2
done

say "CI-PROBE: system-state=$(systemctl is-system-running 2>&1)"
say "CI-PROBE: display-manager-active=$(systemctl is-active display-manager.service 2>&1)"
say "CI-PROBE: failed-units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' | tr '\n' ' ')"
# Units that systemd has restarted (a Restart=on-failure service with a bad config is "activating (auto-restart)", never "failed", so
# failed-units misses it), with the last journal lines of each as the reason, and what listens on the network beyond loopback. Facts for
# the report, not verdicts. `systemctl show` prints NRestarts BEFORE Id inside one unit's block, so the blocks are read as paragraphs.
restarted="$(systemctl show '*.service' -p Id -p NRestarts 2>/dev/null | awk 'BEGIN { RS = ""; FS = "\n" }
    { id = ""; n = 0
      for (i = 1; i <= NF; i++) { if ($i ~ /^Id=/) id = substr($i, 4); else if ($i ~ /^NRestarts=/) n = substr($i, 11) + 0 }
      if (n > 0) printf "%s(%d) ", id, n }')"
say "CI-PROBE: restarted-units=$restarted"
for u in $(printf '%s\n' "$restarted" | tr ' ' '\n' | sed -n 's/(.*//p' | head -6); do
    say "CI-PROBE: restart-reason $u: $(journalctl -b -u "$u" -n 3 --no-pager -o cat 2>/dev/null | cut -c1-160 | tr '\n' '|')"
done
say "CI-PROBE: listening=$(ss -H -ltn 2>/dev/null | awk '$4 !~ /^(127\.|\[::1\]|::1)/ { printf "%s ", $4 }')"
# Accounts and units that a live-session leftover would add (cloud-init creates the default user of /etc/cloud/cloud.cfg on the first boot;
# passwd -S says only whether a password is usable (P), absent (NP) or locked (L), never the hash).
say "CI-PROBE: cloud-init=$(cloud-init status 2>&1 | tr '\n' ' ')"
say "CI-PROBE: users=$(awk -F: '$3 >= 1000 && $3 < 60000 { printf "%s(uid=%s,shell=%s) ", $1, $3, $7 }' /etc/passwd)"
say "CI-PROBE: password-state=$(for u in $(awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }' /etc/passwd); do passwd -S "$u" 2>/dev/null | awk '{ printf "%s:%s ", $1, $2 }'; done)"
say "CI-PROBE: sudo-nopasswd-files=$(grep -rl NOPASSWD /etc/sudoers /etc/sudoers.d 2>/dev/null | tr '\n' ' ')"
say "CI-PROBE: masked-units=$(systemctl list-unit-files --state=masked --no-legend --plain 2>/dev/null | awk '{ printf "%s ", $1 }')"
say "CI-PROBE: plymouth-running=$(plymouth --ping >/dev/null 2>&1 && echo yes || echo no)"
say "CI-PROBE: sessions=$(loginctl list-sessions --no-legend 2>/dev/null | tr -s ' ' | tr '\n' ';')"
# Errors of this boot, by source ("unit[pid]: message" with the time, host and pid removed), most frequent first.
journalctl -b -p err --no-pager -o short 2>/dev/null | awk '{ $1 = $2 = $3 = $4 = ""; print }' | sed -e 's/^ *//' -e 's/\[[0-9]*\]//' | cut -c1-180 \
    | sort | uniq -c | sort -rn | head -15 | while IFS= read -r l; do say "CI-PROBE: journal-err $l"; done

# The verdict is the condition the loop broke on, not "a greeter session exists": at the limit that session may be there with its gnome-shell
# not running (or Plymouth still up), and reporting OK for it would hide exactly the failures this probe is for (it reported OK at the limit
# for a greeter it could not find, on 26.04).
if [ -n "$up" ]; then
    say "CI-PROBE-OK gdm greeter up after ${waited}s ($greeter)"
else
    say "CI-PROBE-FAIL the GDM greeter did not come up within ${LIMIT}s (display-manager=$(systemctl is-active display-manager.service 2>&1), greeter session: ${greeter:-none}, its gnome-shell running: $(greeter_shell_up && echo yes || echo no), plymouth running: $(plymouth --ping >/dev/null 2>&1 && echo yes || echo no))"
fi
say "CI-PROBE: end"
