#!/usr/bin/env bash
# Fixtures shared by the tests of backends/ubuntu/lib/quiet-canonical.sh: stub dpkg commands that work on a fake root, and a fake root shaped like a
# stock Ubuntu 26.04 desktop for the parts the library touches (the Pro client's config and apt hook, the login-text scripts, the units, the autostart
# entries, a dpkg database). Sourced by backends/ubuntu/lib/tests/quiet-canonical.sh and by backends/ubuntu/iso/tests/verify-quiet-appearance.sh.
#
# The caller sets WORK (a scratch directory) and CHROOT_SCRIPT (customize-chroot.sh, whose dconf block finish_like_the_build copies), sources
# quiet-canonical.sh, sources this file and calls quiet_fixtures_init. bash 3.2 safe.
# shellcheck shell=bash

# quiet_fixtures_init: write the stub commands to $WORK/stubs and replace ci_quiet_exec so that the library runs them against $ROOT (a global).
quiet_fixtures_init() {
    STUBS="$WORK/stubs"; mkdir -p "$STUBS"
    cat >"$STUBS/dpkg-divert" <<'EOF'
#!/bin/sh
# dpkg-divert --list <path>  |  dpkg-divert --local --rename --divert <to> --add <path>   (all paths inside $STUB_ROOT)
root="${STUB_ROOT:?}"; db="$root/var/lib/dpkg/diversions"; mkdir -p "$root/var/lib/dpkg"; touch "$db"
list=0; add=0; to=""; path=""
while [ $# -gt 0 ]; do
    case "$1" in
        --list) list=1 ;;
        --add) add=1 ;;
        --local | --rename) ;;
        --divert) shift; to="$1" ;;
        *) path="$1" ;;
    esac
    shift
done
if [ "$list" = 1 ]; then
    awk -v p="$path" 'NR % 3 == 1 { o = $0 } NR % 3 == 2 { if (o == p) print "local diversion of " o " to " $0 }' "$db"
    exit 0
fi
if [ "$add" = 1 ]; then
    if [ -e "$root$to" ] || [ -L "$root$to" ]; then echo "dpkg-divert: error: cannot divert: $to already exists" >&2; exit 2; fi
    mv "$root$path" "$root$to" || exit 2
    printf '%s\n%s\n:\n' "$path" "$to" >> "$db"
    echo "Adding 'local diversion of $path to $to'"
    exit 0
fi
exit 2
EOF
    cat >"$STUBS/dpkg-statoverride" <<'EOF'
#!/bin/sh
# dpkg-statoverride --list <path>  |  dpkg-statoverride --update --add root root 0644 <path>
root="${STUB_ROOT:?}"; db="$root/var/lib/dpkg/statoverride"; mkdir -p "$root/var/lib/dpkg"; touch "$db"
case "$1" in
    --list) grep -F " $2" "$db" | grep -q . && { grep -F " $2" "$db"; exit 0; }; exit 1 ;;
    --update) shift
        [ "$1" = --add ] || exit 2
        owner="$2"; group="$3"; mode="$4"; path="$5"
        chmod "$mode" "$root$path" || exit 2
        printf '%s %s %s %s\n' "$owner" "$group" "$(printf '%s' "$mode" | sed 's/^0*//')" "$path" >> "$db"
        exit 0 ;;
esac
exit 2
EOF
    cat >"$STUBS/dpkg-query" <<'EOF'
#!/bin/sh
# dpkg-query -W -f='${Status}' <package>
root="${STUB_ROOT:?}"; pkg="$3"
[ -f "$root/var/lib/dpkg/status" ] || exit 1
st="$(awk -v p="$pkg" 'BEGIN { RS = ""; FS = "\n" } $1 == "Package: " p { for (i = 1; i <= NF; i++) if ($i ~ /^Status: /) print substr($i, 9) }' "$root/var/lib/dpkg/status")"
[ -n "$st" ] || exit 1
printf '%s' "$st"
EOF
    cat >"$STUBS/dpkg" <<'EOF'
#!/bin/sh
# dpkg -L <package>
root="${STUB_ROOT:?}"
[ "$1" = -L ] && [ -f "$root/var/lib/dpkg/info/$2.list" ] && { cat "$root/var/lib/dpkg/info/$2.list"; exit 0; }
echo "dpkg-query: package '$2' is not installed" >&2; exit 1
EOF
    cat >"$STUBS/apt-get" <<'EOF'
#!/bin/sh
# apt-get -s purge <package>  (prints $STUB_ROOT/.apt-sim/<package>, or just that package)  |  apt-get purge -y <package>
root="${STUB_ROOT:?}"
if [ "$1" = -s ]; then
    if [ -f "$root/.apt-sim/$3" ]; then cat "$root/.apt-sim/$3"; else echo "Remv $3 [1.0]"; fi
    exit 0
fi
if [ "$1" = purge ]; then
    echo "purge $3" >> "$root/.apt-log"
    awk -v p="$3" 'BEGIN { RS = ""; ORS = "\n\n" } $0 !~ ("^Package: " p "\n") { print }' "$root/var/lib/dpkg/status" > "$root/var/lib/dpkg/status.new" && mv "$root/var/lib/dpkg/status.new" "$root/var/lib/dpkg/status"
    exit 0
fi
exit 2
EOF
    cat >"$STUBS/apt-mark" <<'EOF'
#!/bin/sh
root="${STUB_ROOT:?}"
[ "$1" = hold ] && { echo "$2" >> "$root/.apt-holds"; echo "$2 set on hold."; exit 0; }
exit 2
EOF
    chmod 755 "$STUBS"/*
    ROOT=""
    ci_quiet_exec() { PATH="$STUBS:$PATH" STUB_ROOT="$ROOT" "$@"; }
}

para() { printf 'Package: %s\nStatus: %s\nVersion: 1.0\nArchitecture: all\n\n' "$1" "${2:-install ok installed}"; }

make_stock_root() { # make_stock_root <dir>: what a stock 26.04 desktop has of the things this library touches
    local r="$1" u s
    rm -rf "$r"
    mkdir -p "$r/etc/ubuntu-advantage" "$r/etc/apt/apt.conf.d" "$r/etc/update-motd.d" "$r/etc/default" "$r/etc/xdg/autostart" \
             "$r/etc/systemd/system" "$r/etc/systemd/user" "$r/usr/lib/systemd/system" "$r/usr/lib/systemd/user" \
             "$r/var/lib/dpkg/info" "$r/etc/dconf/db/local.d"
    printf '127.0.0.1 localhost\n127.0.1.1 ubuntu\n' > "$r/etc/hosts"
    printf "contract_url: 'https://contracts.canonical.com'\nsecurity_url: 'https://ubuntu.com/security'\ndata_dir: /var/lib/ubuntu-advantage\nlog_file: /var/log/ubuntu-advantage.log\nlog_level: debug\napt_news: true\n" > "$r/etc/ubuntu-advantage/uaclient.conf"
    chmod 644 "$r/etc/ubuntu-advantage/uaclient.conf"
    cat > "$r/etc/apt/apt.conf.d/20apt-esm-hook.conf" <<'EOH'
APT::Update::Pre-Invoke {"[ ! -e /usr/lib/ubuntu-advantage/apt-esm-hook ] || /usr/lib/ubuntu-advantage/apt-esm-hook pre-invoke";};
APT::Update::Post-Invoke-Success {"[ ! -e /usr/lib/ubuntu-advantage/apt-esm-hook ] || /usr/lib/ubuntu-advantage/apt-esm-hook post-invoke";};
AptCli::Hooks::Upgrade {"/usr/lib/ubuntu-advantage/apt-esm-json-hook";};
EOH
    cat > "$r/etc/apt/apt.conf.d/50unattended-upgrades" <<'EOH'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
// Packages that are covered by Ubuntu Pro are described at https://ubuntu.com/pro
EOH
    printf 'APT::Periodic::Update-Package-Lists "1";\n' > "$r/etc/apt/apt.conf.d/20auto-upgrades"
    for s in 00-header 10-help-text 50-motd-news 88-esm-announce 91-contract-ua-esm-status; do
        printf '#!/bin/sh\n# %s\n[ -f /var/lib/ubuntu-advantage/messages/motd-%s ] && cat /var/lib/ubuntu-advantage/messages/motd-%s\n' "$s" "$s" "$s" > "$r/etc/update-motd.d/$s"
        chmod 755 "$r/etc/update-motd.d/$s"
    done
    # update counts from update-notifier: no advert, and it stays executable
    printf '#!/bin/sh\nstamp="/var/lib/update-notifier/updates-available"\n[ ! -r "$stamp" ] || cat "$stamp"\n' > "$r/etc/update-motd.d/90-updates-available"
    chmod 755 "$r/etc/update-motd.d/90-updates-available"
    printf '#!/bin/sh\ncat <<MOTD\n\n  Companion OS\n\nMOTD\n' > "$r/etc/update-motd.d/00-ci-os-header"; chmod 755 "$r/etc/update-motd.d/00-ci-os-header"
    printf '# Enable/disable the dynamic MOTD news service\nENABLED=1\nURLS="https://motd.ubuntu.com"\nWAIT="3"\n' > "$r/etc/default/motd-news"
    for u in motd-news.service motd-news.timer ua-timer.service ua-timer.timer apt-news.service esm-cache.service ua-reboot-cmds.service ubuntu-advantage.service \
             unattended-upgrades.service apt-daily.timer; do
        printf '[Unit]\nDescription=%s\n' "$u" > "$r/usr/lib/systemd/system/$u"
    done
    printf '[Unit]\nDescription=collect\n' > "$r/usr/lib/systemd/user/ubuntu-insights-collect.service"
    printf '[Unit]\nDescription=upload\n' > "$r/usr/lib/systemd/user/ubuntu-insights-upload.timer"
    printf '[Unit]\nDescription=upload\n' > "$r/usr/lib/systemd/system/ubuntu-insights-upload.service"
    printf '/usr\n/usr/bin/ubuntu-insights\n/usr/lib/systemd/user/ubuntu-insights-collect.service\n/usr/lib/systemd/user/ubuntu-insights-upload.timer\n/usr/lib/systemd/system/ubuntu-insights-upload.service\n/etc/xdg/autostart/ubuntu-insights-first-run.desktop\n' > "$r/var/lib/dpkg/info/ubuntu-insights.list"
    printf '/etc/ubuntu-advantage/uaclient.conf\n/etc/apt/apt.conf.d/20apt-esm-hook.conf\n/etc/xdg/autostart/ubuntu-advantage-notification.desktop\n/etc/xdg/autostart/canonical-nag.desktop\n/usr/lib/systemd/system/ua-timer.timer\n' > "$r/var/lib/dpkg/info/ubuntu-pro-client.list"
    # an entry of the Pro client's package whose name and command give nothing away: only the package's file list does
    printf '[Desktop Entry]\nType=Application\nName=Nag\nExec=/usr/bin/nagger\n' > "$r/etc/xdg/autostart/canonical-nag.desktop"
    printf '/etc/xdg/autostart/ubuntu-report-on-upgrade.desktop\n' > "$r/var/lib/dpkg/info/ubuntu-report.list"
    for s in ubuntu-advantage-notification ubuntu-report-on-upgrade ubuntu-insights-first-run; do
        printf '[Desktop Entry]\nType=Application\nName=%s\nExec=/usr/bin/%s\n' "$s" "$s" > "$r/etc/xdg/autostart/$s.desktop"
    done
    printf '[Desktop Entry]\nType=Application\nName=Software Updater\nExec=update-notifier\n' > "$r/etc/xdg/autostart/update-notifier.desktop"
    printf '[Desktop Entry]\nType=Application\nName=snap userd\nExec=snap userd --autostart\n' > "$r/etc/xdg/autostart/snap-userd-autostart.desktop"
    printf '[Desktop Entry]\nType=Application\nName=Geoclue Demo agent\nExec=/usr/libexec/geoclue-2.0/demos/agent\n' > "$r/etc/xdg/autostart/geoclue-demo-agent.desktop"
    printf '[Desktop Entry]\nType=Application\nName=Evolution alarms\nExec=/usr/libexec/evolution-data-server/evolution-alarm-notify\n' > "$r/etc/xdg/autostart/org.gnome.Evolution-alarm-notify.desktop"
    printf '[Desktop Entry]\nType=Application\nName=Companion OS live session setup\nExec=/usr/libexec/ci-os/ci-os-auto-install --live-setup\n' > "$r/etc/xdg/autostart/ci-os-live-setup.desktop"
    { para base-files; para update-notifier; para unattended-upgrades; para ubuntu-pro-client; para ubuntu-insights
      para apport; para apport-gtk; para whoopsie; para ubuntu-report; para apport-symptoms; } > "$r/var/lib/dpkg/status"
    : > "$r/var/lib/dpkg/diversions"; : > "$r/var/lib/dpkg/statoverride"
}

# What the rest of the image build does that is not in the library: Step 2's purge of the telemetry packages, and Step 3's dconf file (cut out of
# customize-chroot.sh itself, so that a change to it is what the tests read).
dconf_block() { sed -n '/03-ci-os-quiet-first-run" << /,/^EOF$/p' "$CHROOT_SCRIPT" | sed '1d;$d'; }
finish_like_the_build() { # finish_like_the_build <root>
    local r="$1" p
    for p in $CI_QUIET_PURGE_PACKAGES apport-gtk; do
        awk -v p="$p" 'BEGIN { RS = ""; ORS = "\n\n" } $0 !~ ("^Package: " p "\n") { print }' "$r/var/lib/dpkg/status" > "$r/var/lib/dpkg/status.new" && mv "$r/var/lib/dpkg/status.new" "$r/var/lib/dpkg/status"
    done
    dconf_block > "$r/etc/dconf/db/local.d/03-ci-os-quiet-first-run"
}
