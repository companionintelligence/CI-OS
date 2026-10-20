#!/usr/bin/env bash
#=============================================================================
# Companion OS on Ubuntu: nothing prompts for Ubuntu Pro, nothing reports to Canonical
#
# Sourced (never run) by customize-chroot.sh (the image build, Step 2c), by remove-telemetry.sh (a machine that is
# already installed), by verify-iso.sh (the audit of a built image) and by backends/ubuntu/lib/tests/quiet-canonical.sh.
# It defines lists and functions and does nothing when it is sourced. bash 3.2 safe (the tests run on a stock macOS).
#
# What a stock Ubuntu 26.04 desktop does that this takes away, and how:
#
#   Ubuntu Pro prompts   the Pro client's apt hook (20apt-esm-hook.conf: the "more security updates through Ubuntu Pro" advert
#                        at the end of `apt upgrade`, and "apt news"), its login-text scripts (88-esm-announce,
#                        91-contract-ua-esm-status), its autostart notification, and its timers (ua-timer, apt-news, esm-cache,
#                        which fetch news and the ESM cache from Canonical's servers). The client stays installed and usable
#                        (`pro attach` still works); what changes is that it never speaks first:
#                          * /etc/ubuntu-advantage/uaclient.conf gets apt_news: false and the three job timers at 0, which is
#                            how the client documents "off";
#                          * the apt hook file is dpkg-diverted to <name>.disabled (an upgrade of the package then writes the new
#                            copy to the diverted name, so it cannot come back), found by name AND by what it runs;
#                          * the login-text scripts are non-executable and kept so by dpkg-statoverride (a plain chmod -x is
#                            undone by the next upgrade);
#                          * the timers and the services they start are masked (a symlink to /dev/null in /etc/systemd/system:
#                            configuration, not deletion; `systemctl unmask` brings them back).
#   telemetry            ubuntu-report, popularity-contest, apport, whoopsie, apport-symptoms and landscape-common are purged and
#                        held (customize-chroot.sh Step 2 and remove-telemetry.sh do that, from CI_QUIET_PURGE_PACKAGES);
#                        ubuntu-insights, Canonical's newer collector, is purged only when apt says nothing else goes with it
#                        (a meta-package that depends on it would be removed too, and the autoremove after it would take the
#                        desktop with it) and otherwise every unit it ships is masked; motd-news (a timer that fetches an
#                        advert from motd.ubuntu.com) is masked and set to ENABLED=0; the metrics, popcon, error-report and
#                        motd hosts resolve to localhost; GNOME's own two switches (report-technical-problems and
#                        send-software-usage-stats) default to false (customize-chroot.sh writes that dconf file).
#   autostart            every /etc/xdg/autostart entry of the Pro client and of the telemetry packages is diverted aside, by
#                        name (ubuntu-advantage-notification.desktop, ubuntu-report-on-upgrade.desktop and the patterns in
#                        ci_quiet_autostart_denied) and by package (dpkg -L of CI_QUIET_AUTOSTART_PACKAGES).
#
# What it deliberately leaves: update-notifier (its pop-ups are switched off by a dconf default instead; restart-required
# notices and the Software Updater window stay), snapd's autostart (snap:// links, snap refresh notices), geoclue's and
# Evolution's agents, unattended-upgrades (security updates install by themselves), the apt archive itself.
#
# A machine that is ATTACHED to an Ubuntu Pro subscription (the machine token exists) keeps its Pro client, hook and timers: this
# must never break a subscription somebody pays for. An image is never attached.
#
# Every function takes the root of the system as its first argument: the image build's chroot, "" or "/" for the running system,
# or a directory of files that verify-iso.sh extracted from the installed layer (the audit only reads). Commands that must run INSIDE
# that system (dpkg-divert, dpkg-statoverride, dpkg-query, apt-get) go through ci_quiet_exec: it runs them in the chroot named by
# CI_QUIET_CHROOT, or directly when that is empty. The tests replace ci_quiet_exec by a function with stub commands.
#
# Interface:
#   ci_quiet_apply_all  <root>    everything below except the package purge, in order; non-zero when a step failed (each step says why)
#   ci_quiet_hosts | ci_quiet_pro_client | ci_quiet_apt_hooks | ci_quiet_units | ci_quiet_autostart | ci_quiet_motd_scripts |
#   ci_quiet_motd_news  <root>    one step each
#   ci_quiet_purge_if_alone <package>...    purge each installed package that apt can remove alone, hold it; warn about the others
#   ci_quiet_audit <root>         prints "ok <label>", "bad <label>" or "info <label>" per property; changes nothing
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
# shellcheck shell=bash

# ── the policy: what is quiet, in one place ─────────────────────────────────────────────────────────────────────────

# Purged and held: customize-chroot.sh Step 2 and remove-telemetry.sh. popularity-contest and landscape-common are not on the 26.04.1
# desktop image (the build log says "not installed, so not removed"); the hold keeps apt from installing them as a dependency later.
CI_QUIET_PURGE_PACKAGES="ubuntu-report popularity-contest apport whoopsie apport-symptoms landscape-common"
# Purged only when `apt-get -s purge` would remove nothing else; otherwise their units are masked.
CI_QUIET_PURGE_IF_ALONE="ubuntu-insights"
# Resolved to 127.0.0.1 in /etc/hosts. contracts.canonical.com (where `pro attach` goes) and the archive are NOT here on purpose.
CI_QUIET_HOSTS="metrics.ubuntu.com www.metrics.ubuntu.com popcon.ubuntu.com www.popcon.ubuntu.com daisy.ubuntu.com motd.ubuntu.com"
CI_QUIET_HOSTS_COMMENT="# Block Ubuntu telemetry"
# The Pro client.
CI_QUIET_PRO_CONF="/etc/ubuntu-advantage/uaclient.conf"
CI_QUIET_PRO_TOKEN="/var/lib/ubuntu-advantage/private/machine-token.json"
CI_QUIET_PRO_KEYS="apt_news=false update_messaging_timer=0 update_status_timer=0 metering_timer=0"
# apt.conf.d files that are the Pro client's: these names, or any file that runs the client (the content test is narrow on purpose:
# 50unattended-upgrades mentions ESM origins and must stay).
CI_QUIET_APT_HOOK_FILES="20apt-esm-hook.conf"
CI_QUIET_APT_HOOK_RE="ubuntu-advantage|apt-esm|ubuntu-pro-client"
# System units masked when they exist: the Pro client's timer and the services it starts, and Canonical's other background callers.
CI_QUIET_PRO_UNITS="ua-timer.timer ua-timer.service apt-news.service esm-cache.service"
CI_QUIET_OTHER_UNITS="motd-news.timer motd-news.service pollinate.service"
# Every unit (system or user) these packages ship is masked when the package is still installed.
CI_QUIET_UNIT_PACKAGES="ubuntu-insights"
# Autostart entries of these packages are diverted whatever they are called.
CI_QUIET_AUTOSTART_PACKAGES="ubuntu-pro-client ubuntu-advantage-tools ubuntu-advantage-desktop-daemon ubuntu-report ubuntu-insights"
# Login-text scripts: Ubuntu's welcome line, its help text, motd-news, the ESM announcement and the contract status.
CI_QUIET_MOTD_SCRIPTS="00-header 10-help-text 50-motd-news 88-esm-announce 91-contract-ua-esm-status"

# ci_quiet_autostart_denied <file name>: an autostart entry that belongs to the Pro client or to a telemetry service, by its name.
# (ubuntu-advantage-notification.desktop is the Pro notification; ubuntu-report-on-upgrade.desktop is the usage report that asks after an
# upgrade. update-notifier.desktop is deliberately not matched.)
ci_quiet_autostart_denied() {
    case "$1" in
        ubuntu-advantage* | ubuntu-pro* | ubuntu-report* | ubuntu-insights* | apport* | whoopsie*) return 0 ;;
    esac
    return 1
}

# ── primitives ────────────────────────────────────────────────────────────────────────────────────────────────────────

# Run a command inside the system being changed.
ci_quiet_exec() {
    if [ -n "${CI_QUIET_CHROOT:-}" ]; then chroot "$CI_QUIET_CHROOT" "$@"; else "$@"; fi
}

# ci_quiet_pro_attached <root>: the machine is attached to an Ubuntu Pro subscription.
ci_quiet_pro_attached() {
    local root="${1:-}"
    root="${root%/}"
    [ -e "$root$CI_QUIET_PRO_TOKEN" ]
}

# ci_quiet_set_yaml_key <file> <key> <value>: set a top-level "key: value" line of a flat YAML file. The first line that starts with "key:"
# is rewritten and later ones are dropped; the key is appended when there is none; everything else stays, so the file keeps its mode and
# its other keys. A comment or an indented line of the same name is not a top-level key and is left alone.
ci_quiet_set_yaml_key() {
    local f="$1" k="$2" v="$3" tmp rc=0
    [ -f "$f" ] || return 1
    tmp="$(mktemp)" || return 1
    awk -v k="$k" -v v="$v" '
        BEGIN { done = 0; pre = k ":" }
        index($0, pre) == 1 { if (!done) { print k ": " v; done = 1 }; next }
        { print }
        END { if (!done) print k ": " v }
    ' "$f" > "$tmp" && cat "$tmp" > "$f" || rc=1
    rm -f "$tmp"
    return "$rc"
}

# ci_quiet_divert <root> <path>: dpkg-divert <path> to <path>.disabled (local, with rename), so that the owning package's next upgrade
# writes its copy to the diverted name. A path that is not there is nothing to do. Repeat-safe: an existing diversion is left alone, and a
# stale <path>.disabled of an earlier build is removed first (the stock layers are extracted over the chroot again, which restores the file
# and the diversion registry but cannot remove a file that is in no layer, and dpkg-divert refuses to rename over it).
ci_quiet_divert() {
    local root="${1:-}" p="$2"
    root="${root%/}"
    if [ ! -e "$root$p" ] && [ ! -L "$root$p" ]; then return 0; fi
    if [ -n "$(ci_quiet_exec dpkg-divert --list "$p" 2>/dev/null)" ]; then return 0; fi
    rm -f "$root$p.disabled"
    ci_quiet_exec dpkg-divert --local --rename --divert "$p.disabled" --add "$p"
}

# ci_quiet_unit_in_image <root> <scope> <unit>: the vendor ships that unit (scope system or user).
ci_quiet_unit_in_image() {
    local root="${1:-}" scope="$2" u="$3" d
    root="${root%/}"
    for d in usr/lib/systemd/$scope lib/systemd/$scope; do
        if [ -f "$root/$d/$u" ]; then return 0; fi
    done
    return 1
}

# ci_quiet_unit_masked <root> <scope> <unit>: /etc/systemd/<scope>/<unit> is a symlink to /dev/null.
ci_quiet_unit_masked() {
    local root="${1:-}" l
    root="${root%/}"
    l="$root/etc/systemd/$2/$3"
    [ -L "$l" ] && [ "$(readlink "$l")" = /dev/null ]
}

# ci_quiet_mask_unit <root> <scope> <unit>: mask a unit that is in the image (no litter of masks for packages that are not installed).
# An administrator's own regular file of that name in /etc is never replaced (non-zero, with a warning).
ci_quiet_mask_unit() {
    local root="${1:-}" scope="$2" u="$3" l
    root="${root%/}"
    l="$root/etc/systemd/$scope/$u"
    if ci_quiet_unit_masked "$root" "$scope" "$u"; then return 0; fi
    ci_quiet_unit_in_image "$root" "$scope" "$u" || return 0
    if [ -e "$l" ] && [ ! -L "$l" ]; then
        echo "[WARN] /etc/systemd/$scope/$u is a regular file: not replaced by a mask"
        return 1
    fi
    mkdir -p "$root/etc/systemd/$scope" && ln -sfn /dev/null "$l"
}

# ci_quiet_package_units <package>: "<scope> <unit>" for every systemd unit the package ships (dpkg -L), sorted.
ci_quiet_package_units() {
    ci_quiet_exec dpkg -L "$1" 2>/dev/null \
        | sed -n -E 's#^/(usr/)?lib/systemd/(system|user)/([^/]+\.(service|timer|path|socket))$#\2 \3#p' | sort -u
}

# ci_quiet_package_autostart <package>: the /etc/xdg/autostart entries the package ships.
ci_quiet_package_autostart() {
    ci_quiet_exec dpkg -L "$1" 2>/dev/null | sed -n -E 's#^(/etc/xdg/autostart/[^/]+\.desktop)$#\1#p'
}

# ci_quiet_pkg_installed <root> <package>: 0 installed (any hold), 1 not, 2 no dpkg status to read.
ci_quiet_pkg_installed() {
    local root="${1:-}" st
    root="${root%/}"
    st="$root/var/lib/dpkg/status"
    [ -f "$st" ] || return 2
    awk -v p="$2" 'BEGIN { RS = ""; FS = "\n" }
        $1 == "Package: " p { for (i = 1; i <= NF; i++) if ($i ~ /^Status: [a-z]+ ok installed$/) f = 1 }
        END { exit f ? 0 : 1 }' "$st"
}

# ── the steps ─────────────────────────────────────────────────────────────────────────────────────────────────────────

# ci_quiet_hosts <root>: the telemetry hosts resolve to localhost. Adds only what is missing.
ci_quiet_hosts() {
    local root="${1:-}" f h missing=""
    root="${root%/}"
    f="$root/etc/hosts"
    if [ ! -f "$f" ]; then echo "[WARN] telemetry hosts: $f does not exist"; return 1; fi
    for h in $CI_QUIET_HOSTS; do
        grep -q -x -F "127.0.0.1 $h" "$f" || missing="$missing $h"
    done
    [ -n "$missing" ] || return 0
    grep -q -x -F "$CI_QUIET_HOSTS_COMMENT" "$f" || printf '\n%s\n' "$CI_QUIET_HOSTS_COMMENT" >> "$f"
    for h in $missing; do printf '127.0.0.1 %s\n' "$h" >> "$f"; done
    echo "[+] telemetry hosts resolve to localhost:$missing"
}

# ci_quiet_pro_client <root>: apt news and the update timers off in uaclient.conf.
ci_quiet_pro_client() {
    local root="${1:-}" f kv k v rc=0
    root="${root%/}"
    f="$root$CI_QUIET_PRO_CONF"
    if ci_quiet_pro_attached "$root"; then
        echo "[i] Ubuntu Pro: this machine is attached to a subscription, so the Pro client's settings are left alone"
        return 0
    fi
    if [ ! -f "$f" ]; then
        echo "[i] Ubuntu Pro client: there is no $CI_QUIET_PRO_CONF in this system, nothing to set"
        return 0
    fi
    for kv in $CI_QUIET_PRO_KEYS; do
        k="${kv%%=*}"
        v="${kv#*=}"
        ci_quiet_set_yaml_key "$f" "$k" "$v" || { echo "[WARN] could not set $k in $CI_QUIET_PRO_CONF"; rc=1; }
    done
    [ "$rc" -ne 0 ] || echo "[+] Ubuntu Pro client: apt news and its update timers are off ($CI_QUIET_PRO_KEYS)"
    return "$rc"
}

# ci_quiet_apt_hooks <root>: apt runs none of the Pro client's hooks.
ci_quiet_apt_hooks() {
    local root="${1:-}" f name moved="" rc=0 hook k
    root="${root%/}"
    if ci_quiet_pro_attached "$root"; then
        echo "[i] Ubuntu Pro: this machine is attached, so apt keeps the Pro client's hooks"
        return 0
    fi
    for f in "$root"/etc/apt/apt.conf.d/*; do
        [ -f "$f" ] || continue
        name="${f##*/}"
        case "$name" in *.disabled | *.dpkg-* | *.ucf-* | *.bak | *.save | *.orig | *~) continue ;; esac
        hook=0
        for k in $CI_QUIET_APT_HOOK_FILES; do [ "$name" != "$k" ] || hook=1; done
        if [ "$hook" -eq 0 ] && grep -q -E -- "$CI_QUIET_APT_HOOK_RE" "$f" 2>/dev/null; then hook=1; fi
        [ "$hook" -eq 1 ] || continue
        if ci_quiet_divert "$root" "/etc/apt/apt.conf.d/$name"; then moved="$moved $name"
        else echo "[WARN] could not divert /etc/apt/apt.conf.d/$name"; rc=1; fi
    done
    [ -z "$moved" ] || echo "[+] apt no longer runs the Ubuntu Pro hooks (diverted:$moved)"
    return "$rc"
}

# ci_quiet_units <root>: mask the timers and services that call Canonical, and every unit of the packages in CI_QUIET_UNIT_PACKAGES.
ci_quiet_units() {
    local root="${1:-}" u pkg scope unit rc=0 masked="" attached=0
    root="${root%/}"
    if ci_quiet_pro_attached "$root"; then attached=1; echo "[i] Ubuntu Pro: this machine is attached, so the Pro client's timers keep running"; fi
    for u in $CI_QUIET_PRO_UNITS; do
        [ "$attached" -eq 0 ] || break
        if ci_quiet_mask_unit "$root" system "$u"; then ci_quiet_unit_masked "$root" system "$u" && masked="$masked $u"; else rc=1; fi
    done
    for u in $CI_QUIET_OTHER_UNITS; do
        if ci_quiet_mask_unit "$root" system "$u"; then ci_quiet_unit_masked "$root" system "$u" && masked="$masked $u"; else rc=1; fi
    done
    for pkg in $CI_QUIET_UNIT_PACKAGES; do
        [ "$(ci_quiet_exec dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" = "install ok installed" ] || continue
        while read -r scope unit; do
            [ -n "$unit" ] || continue
            if ci_quiet_mask_unit "$root" "$scope" "$unit"; then ci_quiet_unit_masked "$root" "$scope" "$unit" && masked="$masked $unit"; else rc=1; fi
        done < <(ci_quiet_package_units "$pkg")
    done
    if [ -n "$masked" ]; then echo "[+] units that call Canonical are masked:$masked"; else echo "[i] no unit that calls Canonical is in this system"; fi
    return "$rc"
}

# ci_quiet_autostart <root>: divert the autostart entries of the Pro client and of the telemetry services.
ci_quiet_autostart() {
    local root="${1:-}" f name pkg rc=0 moved=""
    root="${root%/}"
    for f in "$root"/etc/xdg/autostart/*.desktop; do
        [ -f "$f" ] || [ -L "$f" ] || continue
        name="${f##*/}"
        ci_quiet_autostart_denied "$name" || continue
        if ci_quiet_divert "$root" "/etc/xdg/autostart/$name"; then moved="$moved $name"; else echo "[WARN] could not divert /etc/xdg/autostart/$name"; rc=1; fi
    done
    for pkg in $CI_QUIET_AUTOSTART_PACKAGES; do
        while read -r f; do
            [ -n "$f" ] || continue
            [ -e "$root$f" ] || [ -L "$root$f" ] || continue
            if ci_quiet_divert "$root" "$f"; then moved="$moved ${f##*/}"; else echo "[WARN] could not divert $f"; rc=1; fi
        done < <(ci_quiet_package_autostart "$pkg")
    done
    if [ -n "$moved" ]; then echo "[+] autostart entries of the Pro client and of telemetry are diverted aside:$moved"; fi
    return "$rc"
}

# ci_quiet_motd_scripts <root>: the login-text scripts of CI_QUIET_MOTD_SCRIPTS are not executable, and stay so. chmod -x alone does not
# last: the installer runs unattended-upgrades on the new system, and a package upgrade puts the executable bit back (the first install of
# this image showed the "Expanded Security Maintenance" advert at the login prompt). dpkg-statoverride makes dpkg keep the mode.
ci_quiet_motd_scripts() {
    local root="${1:-}" m p rc=0
    root="${root%/}"
    for m in $CI_QUIET_MOTD_SCRIPTS; do
        p="/etc/update-motd.d/$m"
        [ -e "$root$p" ] || continue
        chmod -x "$root$p"
        ci_quiet_exec dpkg-statoverride --list "$p" >/dev/null 2>&1 || ci_quiet_exec dpkg-statoverride --update --add root root 0644 "$p" || rc=1
    done
    return "$rc"
}

# ci_quiet_motd_news <root>: /etc/default/motd-news says ENABLED=0 (the timer is masked by ci_quiet_units).
ci_quiet_motd_news() {
    local root="${1:-}" f tmp rc=0
    root="${root%/}"
    f="$root/etc/default/motd-news"
    [ -f "$f" ] || return 0
    tmp="$(mktemp)" || return 1
    awk 'BEGIN { done = 0 }
         /^ENABLED=/ { if (!done) { print "ENABLED=0"; done = 1 }; next }
         { print }
         END { if (!done) print "ENABLED=0" }' "$f" > "$tmp" && cat "$tmp" > "$f" || rc=1
    rm -f "$tmp"
    [ "$rc" -ne 0 ] || echo "[+] motd-news: ENABLED=0 in /etc/default/motd-news"
    return "$rc"
}

# ci_quiet_purge_if_alone <package>...: purge each installed package that apt can remove by itself, and hold it. When `apt-get -s purge`
# would remove something else with it (a meta-package that depends on it), the package stays, with a warning that names what would go;
# ci_quiet_units masks its units instead. Runs inside the chroot through ci_quiet_exec.
ci_quiet_purge_if_alone() {
    local p sim others rc=0
    for p in "$@"; do
        [ "$(ci_quiet_exec dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" = "install ok installed" ] || continue
        sim="$(ci_quiet_exec apt-get -s purge "$p" 2>/dev/null | sed -n 's/^Remv \([^ :]*\).*/\1/p' || true)"
        others="$(printf '%s\n' "$sim" | grep -v -x -F -e "$p" | grep -v '^$' || true)"
        if [ -n "$others" ]; then
            echo "[WARN] $p is not purged: apt would remove $(printf '%s' "$others" | tr '\n' ' ')with it. Its units are masked instead."
            continue
        fi
        if ci_quiet_exec env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p" >/dev/null && ci_quiet_exec apt-mark hold "$p" >/dev/null; then
            echo "[+] $p purged and held"
        else
            echo "[WARN] $p could not be purged"
            rc=1
        fi
    done
    return "$rc"
}

# ci_quiet_apply_all <root>: every step but the purge of CI_QUIET_PURGE_PACKAGES. Returns non-zero when any step failed, after running
# all of them (each failure has printed its reason).
ci_quiet_apply_all() {
    local root="${1:-}" rc=0
    ci_quiet_hosts "$root" || rc=1
    # shellcheck disable=SC2086
    ci_quiet_purge_if_alone $CI_QUIET_PURGE_IF_ALONE || rc=1
    ci_quiet_pro_client "$root" || rc=1
    ci_quiet_apt_hooks "$root" || rc=1
    ci_quiet_units "$root" || rc=1
    ci_quiet_autostart "$root" || rc=1
    ci_quiet_motd_scripts "$root" || rc=1
    ci_quiet_motd_news "$root" || rc=1
    return "$rc"
}

# ── the audit ─────────────────────────────────────────────────────────────────────────────────────────────────────────

ci_quiet__ok() { printf 'ok %s\n' "$*"; }
ci_quiet__bad() { printf 'bad %s\n' "$*"; }
ci_quiet__info() { printf 'info %s\n' "$*"; }

# ci_quiet_unit_list <root> <package>: "<scope> <unit>" of the units the installed package ships, from its dpkg file list (the .list file
# in the root), or, where that file is not there, the units whose name starts with the package's name.
ci_quiet_unit_list() {
    local root="${1:-}" pkg="$2" list d scope f
    root="${root%/}"
    list="$root/var/lib/dpkg/info/$pkg.list"
    if [ -f "$list" ]; then
        sed -n -E 's#^/(usr/)?lib/systemd/(system|user)/([^/]+\.(service|timer|path|socket))$#\2 \3#p' "$list" | sort -u
        return 0
    fi
    for scope in system user; do
        for d in usr/lib/systemd/$scope lib/systemd/$scope; do
            for f in "$root/$d/$pkg"*; do
                [ -f "$f" ] && printf '%s %s\n' "$scope" "${f##*/}"
            done
        done
    done | sort -u
}

# ci_quiet__dconf_has <root> <line>: the quiet-first-run dconf file (03-ci-os-quiet-first-run) carries that line.
ci_quiet__dconf_has() {
    local root="${1:-}"
    root="${root%/}"
    grep -q -x -F -- "$2" "$root/etc/dconf/db/local.d/03-ci-os-quiet-first-run" 2>/dev/null
}

# ci_quiet_audit <root>: one line per property, "ok <label>", "bad <label>" or "info <label>". Reads files only.
ci_quiet_audit() {
    local root="${1:-}" p m u h f name pkg scope unit kv k v rc attached=0 list n bad hits fail
    root="${root%/}"
    ci_quiet_pro_attached "$root" && attached=1

    # packages
    for p in $CI_QUIET_PURGE_PACKAGES; do
        rc=0
        ci_quiet_pkg_installed "$root" "$p" || rc=$?
        case "$rc" in
            0) ci_quiet__bad "Canonical: telemetry package $p is installed" ;;
            1) ci_quiet__ok "Canonical: telemetry package $p is not installed" ;;
            *) ci_quiet__bad "Canonical: the dpkg status could not be read, so package $p was not checked" ;;
        esac
    done
    for pkg in $CI_QUIET_PURGE_IF_ALONE; do
        rc=0
        ci_quiet_pkg_installed "$root" "$pkg" || rc=$?
        if [ "$rc" -eq 1 ]; then ci_quiet__ok "Canonical: telemetry package $pkg is not installed"; continue; fi
        if [ "$rc" -ne 0 ]; then ci_quiet__bad "Canonical: the dpkg status could not be read, so package $pkg was not checked"; continue; fi
        list="$(ci_quiet_unit_list "$root" "$pkg")"
        bad=""
        n=0
        while read -r scope unit; do
            [ -n "$unit" ] || continue
            n=$((n + 1))
            ci_quiet_unit_masked "$root" "$scope" "$unit" || bad="$bad $scope:$unit"
        done <<EOF
$list
EOF
        if [ -n "$bad" ]; then ci_quiet__bad "Canonical: $pkg is installed and these units are not masked:$bad"
        else ci_quiet__ok "Canonical: $pkg is installed and its $n unit(s) are masked"; fi
    done

    # hosts
    for h in $CI_QUIET_HOSTS; do
        if grep -q -x -F "127.0.0.1 $h" "$root/etc/hosts" 2>/dev/null; then ci_quiet__ok "Canonical: /etc/hosts sends $h to localhost"
        else ci_quiet__bad "Canonical: /etc/hosts does not send $h to localhost"; fi
    done

    # the Pro client's settings
    if ! ci_quiet_pkg_installed "$root" ubuntu-pro-client && ! ci_quiet_pkg_installed "$root" ubuntu-advantage-tools; then
        ci_quiet__info "Canonical: the Ubuntu Pro client is not installed, so it has no settings to check"
    elif [ "$attached" -eq 1 ]; then
        ci_quiet__info "Canonical: this machine is attached to Ubuntu Pro: the client's settings, hook and timers are left as they are"
    else
        f="$root$CI_QUIET_PRO_CONF"
        for kv in $CI_QUIET_PRO_KEYS; do
            k="${kv%%=*}"
            v="${kv#*=}"
            if [ -f "$f" ] && grep -q -x -F "$k: $v" "$f"; then ci_quiet__ok "Canonical: uaclient.conf has $k: $v"
            else ci_quiet__bad "Canonical: uaclient.conf does not have $k: $v"; fi
        done
    fi

    # apt: no active hook of the Pro client
    hits=""
    for f in "$root"/etc/apt/apt.conf.d/*; do
        [ -f "$f" ] || continue
        name="${f##*/}"
        case "$name" in *.disabled | *.dpkg-* | *.ucf-* | *.bak | *.save | *.orig | *~) continue ;; esac
        fail=0
        for k in $CI_QUIET_APT_HOOK_FILES; do [ "$name" != "$k" ] || fail=1; done
        grep -q -E -- "$CI_QUIET_APT_HOOK_RE" "$f" 2>/dev/null && fail=1
        [ "$fail" -eq 0 ] || hits="$hits $name"
    done
    if [ "$attached" -eq 1 ]; then ci_quiet__info "Canonical: apt keeps the Pro client's hooks on an attached machine"
    elif [ -n "$hits" ]; then ci_quiet__bad "Canonical: apt still runs the Ubuntu Pro hook (active in /etc/apt/apt.conf.d:$hits)"
    else ci_quiet__ok "Canonical: apt runs no Ubuntu Pro hook (no active file of /etc/apt/apt.conf.d runs the Pro client)"; fi

    # the login text
    for m in $CI_QUIET_MOTD_SCRIPTS; do
        f="$root/etc/update-motd.d/$m"
        if [ ! -e "$f" ]; then ci_quiet__ok "Canonical: login-text script $m is not in this system"
        elif [ -x "$f" ]; then ci_quiet__bad "Canonical: login-text script $m is still executable"
        elif ! grep -q -E "^root root 644 /etc/update-motd\\.d/$m\$" "$root/var/lib/dpkg/statoverride" 2>/dev/null; then
            ci_quiet__bad "Canonical: login-text script $m is not executable but has no dpkg-statoverride (an upgrade restores the mode)"
        else ci_quiet__ok "Canonical: login-text script $m is off and kept off by dpkg-statoverride"; fi
    done
    hits=""
    for f in "$root"/etc/update-motd.d/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        grep -q -E 'ubuntu-advantage|motd\.ubuntu\.com|ubuntu\.com/(pro|esm)' "$f" 2>/dev/null && hits="$hits ${f##*/}"
    done
    if [ -n "$hits" ]; then ci_quiet__bad "Canonical: an executable login-text script advertises Ubuntu Pro or fetches from Canonical:$hits"
    else ci_quiet__ok "Canonical: no executable login-text script advertises Ubuntu Pro or fetches from Canonical"; fi
    if [ -f "$root/etc/default/motd-news" ]; then
        if grep -q -x 'ENABLED=0' "$root/etc/default/motd-news"; then ci_quiet__ok "Canonical: /etc/default/motd-news says ENABLED=0"
        else ci_quiet__bad "Canonical: /etc/default/motd-news does not say ENABLED=0"; fi
    else ci_quiet__ok "Canonical: /etc/default/motd-news is not in this system"; fi

    # units
    for u in $CI_QUIET_PRO_UNITS $CI_QUIET_OTHER_UNITS; do
        case " $CI_QUIET_PRO_UNITS " in
            *" $u "*) if [ "$attached" -eq 1 ]; then ci_quiet__info "Canonical: unit $u runs on an attached machine"; continue; fi ;;
        esac
        if ci_quiet_unit_masked "$root" system "$u"; then ci_quiet__ok "Canonical: unit $u is masked"
        elif ci_quiet_unit_in_image "$root" system "$u"; then ci_quiet__bad "Canonical: unit $u is not masked"
        else ci_quiet__ok "Canonical: unit $u is not in this system"; fi
    done

    # autostart: by name, by what the entry runs, and by the file lists of the packages in CI_QUIET_AUTOSTART_PACKAGES
    hits=""
    for f in "$root"/etc/xdg/autostart/*.desktop; do
        [ -f "$f" ] || [ -L "$f" ] || continue
        name="${f##*/}"
        if ci_quiet_autostart_denied "$name"; then hits="$hits $name"
        elif grep -q -E -i '^Exec=.*(ubuntu-report|ubuntu-advantage|ubuntu-pro|ubuntu-insights|whoopsie|apport)' "$f" 2>/dev/null; then hits="$hits $name"; fi
    done
    for pkg in $CI_QUIET_AUTOSTART_PACKAGES; do
        list="$root/var/lib/dpkg/info/$pkg.list"
        [ -f "$list" ] || continue
        while read -r f; do
            case "$f" in
                /etc/xdg/autostart/*.desktop)
                    if [ -f "$root$f" ] || [ -L "$root$f" ]; then
                        case " $hits " in *" ${f##*/} "*) ;; *) hits="$hits ${f##*/}" ;; esac
                    fi ;;
            esac
        done < "$list"
    done
    if [ -n "$hits" ]; then ci_quiet__bad "Canonical: these autostart entries of the Pro client or of telemetry are still active:$hits"
    else ci_quiet__ok "Canonical: no autostart entry of the Pro client or of telemetry is active (/etc/xdg/autostart)"; fi

    # GNOME's own switches
    if ci_quiet__dconf_has "$root" "report-technical-problems=false" && ci_quiet__dconf_has "$root" "send-software-usage-stats=false" \
        && ci_quiet__dconf_has "$root" "[org/gnome/desktop/privacy]"; then
        ci_quiet__ok "Canonical: the dconf defaults turn off error reports and usage statistics (org.gnome.desktop.privacy)"
    else ci_quiet__bad "Canonical: the dconf defaults do not turn off error reports and usage statistics (org.gnome.desktop.privacy)"; fi
    return 0
}
