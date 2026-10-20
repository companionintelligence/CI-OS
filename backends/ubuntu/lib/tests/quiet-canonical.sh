#!/usr/bin/env bash
#=============================================================================
# Test: backends/ubuntu/lib/quiet-canonical.sh (no Ubuntu Pro prompts, nothing that reports to Canonical)
#
# The library has two halves that are tested against each other:
#   apply  ci_quiet_apply_all changes a root (the image build's chroot, a running system)
#   audit  ci_quiet_audit reads a root and says "ok", "bad" or "info" per property; verify-iso.sh runs it on the files it extracts
#          from the installed layer of a built image
#
# This test builds fake roots shaped like a stock Ubuntu 26.04 desktop for the parts that matter here (the Pro client's config and
# apt hook, the login-text scripts, the units, the autostart entries, a dpkg database) and checks that
#   * the stock root fails the audit in every category,
#   * after the apply the audit has no "bad" line, and what must stay (update-notifier, snapd's autostart, unattended-upgrades'
#     apt file, the unit that makes the Pro client work after `pro attach`) is untouched,
#   * a single defect planted in the finished root produces exactly its own "bad" line (so no check hides behind another),
#   * the apply is repeat-safe, also after the stock layers were extracted over a chroot that already had it,
#   * a machine attached to Ubuntu Pro is left alone, and
#   * a package that apt can only remove together with a meta-package is NOT purged (the autoremove after it would take the desktop).
# dpkg-divert, dpkg-statoverride, dpkg-query, dpkg -L, apt-get and apt-mark are stubs that work on the fake root (ci_quiet_exec is
# replaced); what the real commands do is shown by the image build and by verify-iso.sh, not here.
#
# Pure bash (3.2 safe), no root, no network, writes only to a temporary directory.
#   backends/ubuntu/lib/tests/quiet-canonical.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${CI_QUIET_LIB:-$HERE/../quiet-canonical.sh}"   # CI_QUIET_LIB: another copy of the library (how the test itself is tested: a copy with one step weakened must fail it)
CHROOT_SCRIPT="$HERE/../../chroot/customize-chroot.sh"
[[ -f "$LIB" && -f "$CHROOT_SCRIPT" ]] || { echo "missing $LIB or $CHROOT_SCRIPT" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/quiet-canonical.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# The stub commands and the fake roots are shared with backends/ubuntu/iso/tests/verify-quiet-appearance.sh.
# shellcheck source=../quiet-canonical.sh
source "$LIB"
# shellcheck source=lib/quiet-fixtures.sh
source "$HERE/lib/quiet-fixtures.sh"
quiet_fixtures_init

apply() { ROOT="$1"; ci_quiet_apply_all "$1" > "$WORK/apply.out" 2>&1; APPLY_RC=$?; }
audit() { ROOT="$1"; ci_quiet_audit "$1"; }
clone() { rm -rf "$2"; cp -Rp "$1" "$2"; }
count() { printf '%s\n' "$1" | grep -c "^$2 " || true; }
bad_lines() { printf '%s\n' "$1" | grep '^bad ' || true; }

# ── 1. primitives ─────────────────────────────────────────────────────────────────────────────────────────────────────
echo "== 1. primitives"
y="$WORK/y.yaml"
printf "# comment\ncontract_url: 'https://c'\napt_news: true\nfeatures:\n  apt_news: nested\n#apt_news: commented\napt_news_url: x\napt_news: again\n" > "$y"
chmod 640 "$y"
ci_quiet_set_yaml_key "$y" apt_news false
eq "set_yaml_key rewrites the first top-level line of that key" "$(grep -c '^apt_news: false$' "$y")" "1"
eq "  and drops a later duplicate" "$(grep -c '^apt_news:' "$y")" "1"
expect "  and leaves the indented, the commented and the longer-named keys alone" bash -c 'grep -q "^  apt_news: nested$" "$1" && grep -q "^#apt_news: commented$" "$1" && grep -q "^apt_news_url: x$" "$1" && grep -q "^contract_url:" "$1"' _ "$y"
eq "  and keeps the file mode" "$(ls -l "$y" | cut -c1-10)" "-rw-r-----"
ci_quiet_set_yaml_key "$y" update_status_timer 0
eq "set_yaml_key appends a key that is not there" "$(tail -n 1 "$y")" "update_status_timer: 0"
ci_quiet_set_yaml_key "$y" update_status_timer 0
eq "  and a second call changes nothing" "$(grep -c '^update_status_timer:' "$y")" "1"
expect "set_yaml_key on a file that does not exist is an error" bash -c '. "$1"; ! ci_quiet_set_yaml_key "$2/none.yaml" a b' _ "$LIB" "$WORK"

r="$WORK/r-prim"; make_stock_root "$r"; ROOT="$r"
ci_quiet_divert "$r" /etc/xdg/autostart/update-notifier.desktop >/dev/null
expect "divert moves the file aside and registers the diversion" bash -c '[ ! -e "$1/etc/xdg/autostart/update-notifier.desktop" ] && [ -f "$1/etc/xdg/autostart/update-notifier.desktop.disabled" ] && grep -q -x "/etc/xdg/autostart/update-notifier.desktop" "$1/var/lib/dpkg/diversions"' _ "$r"
ci_quiet_divert "$r" /etc/xdg/autostart/update-notifier.desktop >/dev/null; rc=$?
eq "  a second divert is a no-op (exit 0)" "$rc" "0"
eq "  and registers nothing twice" "$(grep -c -x '/etc/xdg/autostart/update-notifier.desktop' "$r/var/lib/dpkg/diversions")" "1"
ci_quiet_divert "$r" /etc/xdg/autostart/no-such.desktop >/dev/null; rc=$?
eq "  a path that is not there is nothing to do (exit 0)" "$rc" "0"
# the stock layers extracted over a chroot: the file is back, the registry is empty, the .disabled of the last run is still there
: > "$r/var/lib/dpkg/diversions"; printf '[Desktop Entry]\nName=again\n' > "$r/etc/xdg/autostart/update-notifier.desktop"
ci_quiet_divert "$r" /etc/xdg/autostart/update-notifier.desktop >/dev/null; rc=$?
eq "  after the stock layers came back over a leftover .disabled it diverts again (exit 0)" "$rc" "0"
expect "  and the new copy is the diverted one" grep -q '^Name=again$' "$r/etc/xdg/autostart/update-notifier.desktop.disabled"

ci_quiet_mask_unit "$r" system ua-timer.timer
expect "mask_unit makes a symlink to /dev/null for a unit that is in the image" bash -c '[ -L "$1/etc/systemd/system/ua-timer.timer" ] && [ "$(readlink "$1/etc/systemd/system/ua-timer.timer")" = /dev/null ]' _ "$r"
ci_quiet_mask_unit "$r" system not-installed.timer
expect "  and none for a unit that is not in the image" test ! -e "$r/etc/systemd/system/not-installed.timer" -a ! -L "$r/etc/systemd/system/not-installed.timer"
ci_quiet_mask_unit "$r" system ua-timer.timer; rc=$?
eq "  a second mask is a no-op (exit 0)" "$rc" "0"
printf '[Unit]\nDescription=an administrator wrote this\n' > "$r/etc/systemd/system/apt-news.service"
out="$(ci_quiet_mask_unit "$r" system apt-news.service)"; rc=$?
eq "  an administrator's own regular file is not replaced (exit 1)" "$rc" "1"
expect "  and the warning says so" bash -c 'printf "%s\n" "$1" | grep -q "regular file"' _ "$out"
expect "  and the file is still there" grep -q 'an administrator wrote this' "$r/etc/systemd/system/apt-news.service"

r="$WORK/r-hosts"; make_stock_root "$r"
ci_quiet_hosts "$r" >/dev/null
eq "hosts: every telemetry host is added once" "$(for h in $CI_QUIET_HOSTS; do grep -c -x -F "127.0.0.1 $h" "$r/etc/hosts"; done | sort -u | tr '\n' ' ')" "1 "
eq "  with one comment line" "$(grep -c -x -F "$CI_QUIET_HOSTS_COMMENT" "$r/etc/hosts")" "1"
cp "$r/etc/hosts" "$WORK/hosts.1"; ci_quiet_hosts "$r" >/dev/null
expect "  a second run changes nothing" cmp -s "$r/etc/hosts" "$WORK/hosts.1"
expect "  the first lines of the file are untouched" bash -c 'head -n 2 "$1/etc/hosts" | grep -q "^127.0.0.1 localhost$"' _ "$r"
expect "  contracts.canonical.com (where \`pro attach\` goes) and the archive are not blocked" bash -c '! grep -q -E "contracts.canonical.com|archive.ubuntu.com|security.ubuntu.com" "$1/etc/hosts"' _ "$r"
printf '127.0.0.1 localhost\n127.0.0.1 metrics.ubuntu.com\n' > "$r/etc/hosts"; ci_quiet_hosts "$r" >/dev/null
eq "  a host that was there already (the old Step 2 block) is not added again" "$(grep -c -x -F '127.0.0.1 metrics.ubuntu.com' "$r/etc/hosts")" "1"

# ── 2. the stock root fails the audit in every category ───────────────────────────────────────────────────────────────
echo
echo "== 2. a stock root fails the audit"
stock="$WORK/stock"; make_stock_root "$stock"
out="$(audit "$stock")"
for want in "telemetry package ubuntu-report is installed" "telemetry package apport is installed" "telemetry package whoopsie is installed" \
            "telemetry package apport-symptoms is installed" "ubuntu-insights is installed and these units are not masked" \
            "/etc/hosts does not send metrics.ubuntu.com to localhost" "/etc/hosts does not send motd.ubuntu.com to localhost" \
            "uaclient.conf does not have apt_news: false" "uaclient.conf does not have update_messaging_timer: 0" \
            "apt still runs the Ubuntu Pro hook (active in /etc/apt/apt.conf.d: 20apt-esm-hook.conf)" \
            "login-text script 00-header is still executable" "login-text script 88-esm-announce is still executable" \
            "login-text script 91-contract-ua-esm-status is still executable" \
            "an executable login-text script advertises Ubuntu Pro or fetches from Canonical" \
            "/etc/default/motd-news does not say ENABLED=0" "unit ua-timer.timer is not masked" "unit apt-news.service is not masked" \
            "unit esm-cache.service is not masked" "unit motd-news.timer is not masked" \
            "these autostart entries of the Pro client or of telemetry are still active: ubuntu-advantage-notification.desktop" \
            "the dconf defaults do not turn off error reports and usage statistics"; do
    expect "stock: bad - $want" bash -c 'printf "%s\n" "$1" | grep "^bad " | grep -q -F -- "$2"' _ "$out" "$want"
done
expect "stock: the autostart finding names ubuntu-report-on-upgrade.desktop, the insights entry and the Pro package's other entry" bash -c 'printf "%s\n" "$1" | grep "^bad .*autostart" | grep -q "ubuntu-report-on-upgrade.desktop" && printf "%s\n" "$1" | grep "^bad .*autostart" | grep -q "ubuntu-insights-first-run.desktop" && printf "%s\n" "$1" | grep "^bad .*autostart" | grep -q "canonical-nag.desktop"' _ "$out"
expect "stock: unattended-upgrades' apt file (it names ESM origins) is not mistaken for the Pro hook" bash -c '! printf "%s\n" "$1" | grep "^bad .*apt" | grep -q "50unattended-upgrades"' _ "$out"

# ── 3. after the apply the audit is clean, and what must stay stays ───────────────────────────────────────────────────
echo
echo "== 3. apply, then audit"
built="$WORK/built"; make_stock_root "$built"; apply "$built"; finish_like_the_build "$built"
eq "the apply exits 0 on a stock root" "$APPLY_RC" "0"
out="$(audit "$built")"
eq "the audit of the result has no bad line" "$(count "$out" bad)" "0"
[[ "$(count "$out" bad)" == 0 ]] || bad_lines "$out" | sed 's/^/        /'
expect "  and says ok to the insights package: it was alone, so it is purged" bash -c 'printf "%s\n" "$1" | grep -q "^ok Canonical: telemetry package ubuntu-insights is not installed"' _ "$out"
expect "  the package was purged and held" bash -c 'grep -q "^purge ubuntu-insights$" "$1/.apt-log" && grep -q "^ubuntu-insights$" "$1/.apt-holds"' _ "$built"
eq "  and prints 34 lines (a check that was dropped by accident changes this number)" "$(printf '%s\n' "$out" | grep -c .)" "34"
expect "update-notifier still autostarts (its pop-ups are a dconf default, not a missing entry)" test -f "$built/etc/xdg/autostart/update-notifier.desktop"
expect "an entry that only the Pro package's file list names (canonical-nag.desktop) is diverted aside too" bash -c '[ ! -e "$1/etc/xdg/autostart/canonical-nag.desktop" ] && [ -f "$1/etc/xdg/autostart/canonical-nag.desktop.disabled" ]' _ "$built"
expect "snapd's, geoclue's and Evolution's autostart entries are untouched" bash -c 'for f in snap-userd-autostart geoclue-demo-agent org.gnome.Evolution-alarm-notify ci-os-live-setup; do [ -f "$1/etc/xdg/autostart/$f.desktop" ] || exit 1; done' _ "$built"
expect "unattended-upgrades' apt file and the periodic file are untouched" bash -c 'grep -q "ESMApps" "$1/etc/apt/apt.conf.d/50unattended-upgrades" && [ -f "$1/etc/apt/apt.conf.d/20auto-upgrades" ]' _ "$built"
expect "the Pro hook is diverted, not deleted (the stock copy is at 20apt-esm-hook.conf.disabled)" bash -c '[ ! -e "$1/etc/apt/apt.conf.d/20apt-esm-hook.conf" ] && [ -f "$1/etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled" ] && grep -q -x "/etc/apt/apt.conf.d/20apt-esm-hook.conf" "$1/var/lib/dpkg/diversions"' _ "$built"
expect "ua-reboot-cmds.service and ubuntu-advantage.service (what pro attach and the cloud auto-attach need) are not masked" bash -c '[ ! -L "$1/etc/systemd/system/ua-reboot-cmds.service" ] && [ ! -L "$1/etc/systemd/system/ubuntu-advantage.service" ]' _ "$built"
expect "unattended-upgrades.service and apt-daily.timer are not masked (security updates keep installing)" bash -c '[ ! -L "$1/etc/systemd/system/unattended-upgrades.service" ] && [ ! -L "$1/etc/systemd/system/apt-daily.timer" ]' _ "$built"
expect "the Pro client's settings: apt news and the three timers" bash -c 'for l in "apt_news: false" "update_messaging_timer: 0" "update_status_timer: 0" "metering_timer: 0"; do grep -q -x -F "$l" "$1/etc/ubuntu-advantage/uaclient.conf" || exit 1; done; grep -q "^contract_url:" "$1/etc/ubuntu-advantage/uaclient.conf"' _ "$built"
expect "motd-news: ENABLED=0 and the other lines are kept" bash -c 'grep -q -x "ENABLED=0" "$1/etc/default/motd-news" && grep -q "^URLS=" "$1/etc/default/motd-news" && [ "$(grep -c "^ENABLED=" "$1/etc/default/motd-news")" = 1 ]' _ "$built"
expect "our own login banner (00-ci-os-header) is still executable" test -x "$built/etc/update-motd.d/00-ci-os-header"
expect "90-updates-available (update counts, no advert) is still executable" test -x "$built/etc/update-motd.d/90-updates-available"
eq "the five Pro and telemetry login-text scripts are kept off by dpkg-statoverride" "$(grep -c -E '^root root 644 /etc/update-motd\.d/(00-header|10-help-text|50-motd-news|88-esm-announce|91-contract-ua-esm-status)$' "$built/var/lib/dpkg/statoverride")" "5"
expect "the dconf block the build writes is what the audit reads (extracted from customize-chroot.sh, not retyped here)" bash -c 'grep -q -x "\[org/gnome/desktop/privacy\]" "$1" && grep -q -x "report-technical-problems=false" "$1" && grep -q -x "send-software-usage-stats=false" "$1" && grep -q -x "no-show-notifications=true" "$1"' _ "$built/etc/dconf/db/local.d/03-ci-os-quiet-first-run"

# ── 4. one planted defect, one bad line ───────────────────────────────────────────────────────────────────────────────
echo
echo "== 4. a defect planted in the finished root is found, and only it"
plant() { # plant <name> <want text> <command...>: clone the built root, run the command in it, expect exactly PLANT_N (default 1) bad lines, one containing the text
    local name="$1" want="$2" r="$WORK/plant-$1" want_n="${PLANT_N:-1}"; shift 2
    clone "$built" "$r"
    ( cd "$r" && "$@" ) >/dev/null 2>&1
    local out n; out="$(audit "$r")"; n="$(count "$out" bad)"
    if [[ "$n" == "$want_n" ]] && bad_lines "$out" | grep -q -F -- "$want"; then pass "$name: $n bad line(s), one says: $want"
    else fail "$name: want $want_n bad line(s), one containing '$want', got $n"; bad_lines "$out" | sed 's/^/        /'; fi
}
plant "package comes back" "telemetry package whoopsie is installed" bash -c 'para() { printf "Package: %s\nStatus: install ok installed\n\n" "$1"; }; para whoopsie >> var/lib/dpkg/status'
plant "host missing" "/etc/hosts does not send daisy.ubuntu.com to localhost" sed -i.bak '/daisy.ubuntu.com/d' etc/hosts
plant "apt news back on" "uaclient.conf does not have apt_news: false" sed -i.bak 's/^apt_news: false/apt_news: true/' etc/ubuntu-advantage/uaclient.conf
plant "a timer left at its default" "uaclient.conf does not have update_status_timer: 0" sed -i.bak '/^update_status_timer/d' etc/ubuntu-advantage/uaclient.conf
plant "the hook is back under its own name" "apt still runs the Ubuntu Pro hook (active in /etc/apt/apt.conf.d: 20apt-esm-hook.conf)" cp etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled etc/apt/apt.conf.d/20apt-esm-hook.conf
plant "a renamed hook that runs the client" "apt still runs the Ubuntu Pro hook (active in /etc/apt/apt.conf.d: 99-pro-news)" bash -c 'echo "APT::Update::Post-Invoke-Success {\"/usr/lib/ubuntu-advantage/apt-esm-hook\";};" > etc/apt/apt.conf.d/99-pro-news'
# (an executable script is found twice on purpose: by its name, and by what it prints)
PLANT_N=2 plant "a motd script executable again" "login-text script 88-esm-announce is still executable" chmod 755 etc/update-motd.d/88-esm-announce
plant "no statoverride for a motd script" "login-text script 50-motd-news is not executable but has no dpkg-statoverride" sed -i.bak '/50-motd-news/d' var/lib/dpkg/statoverride
plant "an unknown executable motd script advertises Pro" "an executable login-text script advertises Ubuntu Pro or fetches from Canonical: 95-pro-advert" bash -c 'printf "#!/bin/sh\necho \"Run ubuntu-advantage status\"\n" > etc/update-motd.d/95-pro-advert; chmod 755 etc/update-motd.d/95-pro-advert'
plant "motd-news enabled" "/etc/default/motd-news does not say ENABLED=0" sed -i.bak 's/^ENABLED=0/ENABLED=1/' etc/default/motd-news
plant "a timer unmasked" "unit ua-timer.timer is not masked" rm etc/systemd/system/ua-timer.timer
plant "motd-news service unmasked" "unit motd-news.service is not masked" rm etc/systemd/system/motd-news.service
plant "the Pro notification autostart is back" "still active: ubuntu-advantage-notification.desktop" cp etc/xdg/autostart/ubuntu-advantage-notification.desktop.disabled etc/xdg/autostart/ubuntu-advantage-notification.desktop
plant "an autostart entry of the Pro package under a plain name" "still active: canonical-nag.desktop" cp etc/xdg/autostart/canonical-nag.desktop.disabled etc/xdg/autostart/canonical-nag.desktop
plant "an autostart entry that runs the client under another name" "still active: pro-nag.desktop" bash -c 'printf "[Desktop Entry]\nType=Application\nName=nag\nExec=/usr/lib/ubuntu-advantage/nag\n" > etc/xdg/autostart/pro-nag.desktop'
plant "the privacy default is gone" "the dconf defaults do not turn off error reports and usage statistics" sed -i.bak '/send-software-usage-stats/d' etc/dconf/db/local.d/03-ci-os-quiet-first-run
plant "no dconf file at all" "the dconf defaults do not turn off error reports and usage statistics" rm etc/dconf/db/local.d/03-ci-os-quiet-first-run
clone "$built" "$WORK/nostatus"; rm "$WORK/nostatus/var/lib/dpkg/status"; out="$(audit "$WORK/nostatus")"
expect "no dpkg status to read: every package check says so (it does not pass for nothing)" bash -c '[ "$(printf "%s\n" "$1" | grep -c "^bad Canonical: the dpkg status could not be read")" = 7 ]' _ "$out"

# ubuntu-insights installed (apt would not purge it alone): its units are masked instead, and the audit knows
ins="$WORK/ins"; make_stock_root "$ins"; mkdir -p "$ins/.apt-sim"
printf 'Remv ubuntu-insights [1.0]\nRemv ubuntu-desktop-minimal [1.2]\n' > "$ins/.apt-sim/ubuntu-insights"
apply "$ins"; finish_like_the_build "$ins"
out="$(audit "$ins")"
eq "insights that apt cannot purge alone: the apply still exits 0" "$APPLY_RC" "0"
expect "  it is not purged, and the warning names what would go with it" bash -c '! grep -q "^purge" "$1/.apt-log" 2>/dev/null && grep -q "ubuntu-desktop-minimal" "$2"' _ "$ins" "$WORK/apply.out"
eq "  the audit has no bad line" "$(count "$out" bad)" "0"
expect "  every unit of the package is masked (system and user scope)" bash -c 'for u in system:ubuntu-insights-upload.service user:ubuntu-insights-collect.service user:ubuntu-insights-upload.timer; do l="$1/etc/systemd/${u%%:*}/${u#*:}"; [ -L "$l" ] && [ "$(readlink "$l")" = /dev/null ] || exit 1; done' _ "$ins"
expect "  the audit says how many: ok ubuntu-insights is installed and its 3 unit(s) are masked" bash -c 'printf "%s\n" "$1" | grep -q "^ok Canonical: ubuntu-insights is installed and its 3 unit(s) are masked"' _ "$out"
expect "  its autostart entry is diverted (by package)" bash -c '[ ! -e "$1/etc/xdg/autostart/ubuntu-insights-first-run.desktop" ] && [ -f "$1/etc/xdg/autostart/ubuntu-insights-first-run.desktop.disabled" ]' _ "$ins"
clone "$ins" "$WORK/ins2"; rm "$WORK/ins2/etc/systemd/user/ubuntu-insights-upload.timer"
out="$(audit "$WORK/ins2")"
expect "  one unit unmasked is found" bash -c 'printf "%s\n" "$1" | grep "^bad " | grep -q "ubuntu-insights is installed and these units are not masked: user:ubuntu-insights-upload.timer"' _ "$out"

# ── 5. purge only what apt can remove alone ───────────────────────────────────────────────────────────────────────────
echo
echo "== 5. purge_if_alone"
p5="$WORK/p5"; make_stock_root "$p5"; mkdir -p "$p5/.apt-sim"; ROOT="$p5"
printf 'Remv ubuntu-insights:amd64 [1.0]\nRemv libinsights0 [1.0]\n' > "$p5/.apt-sim/ubuntu-insights"
out="$(ci_quiet_purge_if_alone ubuntu-insights)"; rc=$?
eq "a package that apt removes with another one is kept (exit 0, a warning)" "$rc" "0"
expect "  the warning names the other package" bash -c 'printf "%s\n" "$1" | grep -q "^\[WARN\] ubuntu-insights is not purged: apt would remove libinsights0"' _ "$out"
expect "  nothing was purged or held" bash -c '[ ! -f "$1/.apt-log" ] && [ ! -f "$1/.apt-holds" ]' _ "$p5"
rm -f "$p5/.apt-sim/ubuntu-insights"
out="$(ci_quiet_purge_if_alone ubuntu-insights not-installed-at-all)"; rc=$?
eq "a package that apt removes alone is purged and held (exit 0)" "$rc" "0"
expect "  the purge and the hold happened once each" bash -c '[ "$(grep -c "^purge ubuntu-insights$" "$1/.apt-log")" = 1 ] && [ "$(grep -c "^ubuntu-insights$" "$1/.apt-holds")" = 1 ]' _ "$p5"
expect "  a name that is not installed is skipped without a word" bash -c '! printf "%s\n" "$1" | grep -q "not-installed-at-all"' _ "$out"

# ── 6. a machine attached to Ubuntu Pro is left alone ─────────────────────────────────────────────────────────────────
echo
echo "== 6. attached to Ubuntu Pro"
att="$WORK/att"; make_stock_root "$att"; mkdir -p "$att/var/lib/ubuntu-advantage/private"; : > "$att/var/lib/ubuntu-advantage/private/machine-token.json"
cp "$att/etc/ubuntu-advantage/uaclient.conf" "$WORK/uaclient.att"
apply "$att"; finish_like_the_build "$att"
eq "the apply exits 0" "$APPLY_RC" "0"
expect "the Pro client's config is unchanged" cmp -s "$att/etc/ubuntu-advantage/uaclient.conf" "$WORK/uaclient.att"
expect "the apt hook is still active" test -f "$att/etc/apt/apt.conf.d/20apt-esm-hook.conf"
expect "the Pro client's timers are not masked" bash -c '[ ! -L "$1/etc/systemd/system/ua-timer.timer" ] && [ ! -L "$1/etc/systemd/system/esm-cache.service" ]' _ "$att"
expect "motd-news and the telemetry are still handled (they are not part of a subscription)" bash -c '[ -L "$1/etc/systemd/system/motd-news.timer" ] && grep -q -x "ENABLED=0" "$1/etc/default/motd-news" && grep -q -x "127.0.0.1 metrics.ubuntu.com" "$1/etc/hosts"' _ "$att"
out="$(audit "$att")"
eq "the audit of an attached machine has no bad line about the Pro client" "$(bad_lines "$out" | grep -c -E 'uaclient|apt still|unit (ua-timer|apt-news|esm-cache)')" "0"
expect "  and says so in info lines" bash -c 'printf "%s\n" "$1" | grep -q "^info Canonical: this machine is attached to Ubuntu Pro"' _ "$out"

# ── 7. repeat-safe ────────────────────────────────────────────────────────────────────────────────────────────────────
echo
echo "== 7. a second run, and a run on a chroot the stock layers were extracted over again"
snapshot() { (cd "$1" && find . -not -name '.apt-*' | LC_ALL=C sort | while read -r f; do if [ -L "$f" ]; then echo "$f -> $(readlink "$f")"; elif [ -f "$f" ]; then echo "$f $(cksum < "$f")"; else echo "$f"; fi; done); }
snapshot "$built" > "$WORK/snap.1"
apply "$built"
snapshot "$built" > "$WORK/snap.2"
eq "a second apply exits 0" "$APPLY_RC" "0"
expect "  and changes nothing" cmp -s "$WORK/snap.1" "$WORK/snap.2"
again="$WORK/again"; clone "$built" "$again"
# the stock layers are extracted over it: stock files back (the hook, the Pro notification, the scripts' mode, the units' state), the
# diversion registry and statoverride forgotten, the .disabled files of the first run still in place, the dpkg status as stock
for f in etc/apt/apt.conf.d/20apt-esm-hook.conf etc/xdg/autostart/ubuntu-advantage-notification.desktop etc/xdg/autostart/ubuntu-report-on-upgrade.desktop; do
    cp "$stock/$f" "$again/$f"
done
cp -p "$stock/etc/update-motd.d/"* "$again/etc/update-motd.d/"
cp "$stock/etc/default/motd-news" "$again/etc/default/motd-news"; cp "$stock/etc/ubuntu-advantage/uaclient.conf" "$again/etc/ubuntu-advantage/uaclient.conf"
: > "$again/var/lib/dpkg/diversions"; : > "$again/var/lib/dpkg/statoverride"
rm -f "$again/etc/systemd/system/"*.timer "$again/etc/systemd/system/"*.service
apply "$again"; finish_like_the_build "$again"
eq "  the apply over a leftover .disabled exits 0" "$APPLY_RC" "0"
out="$(audit "$again")"
eq "  and the audit of the result is clean" "$(count "$out" bad)" "0"
[[ "$(count "$out" bad)" == 0 ]] || bad_lines "$out" | sed 's/^/        /'

# ── 8. under set -euo pipefail, as customize-chroot.sh runs it ─────────────────────────────────────────────────────────
echo
echo "== 8. strict mode"
strict="$WORK/strict"; make_stock_root "$strict"
out="$(bash -c 'set -euo pipefail; . "$1"; S="$2"; R="$3"; ci_quiet_exec() { PATH="$S:$PATH" STUB_ROOT="$R" "$@"; }; ci_quiet_apply_all "$R"; ci_quiet_apply_all "$R"; echo DONE' _ "$LIB" "$STUBS" "$strict" 2>&1)"; rc=$?
eq "apply, twice, with errexit, nounset and pipefail: exit 0 and it reached the end" "$rc:$(printf '%s\n' "$out" | tail -n 1)" "0:DONE"
out="$(bash -c 'set -euo pipefail; . "$1"; ci_quiet_audit "$2"; echo DONE' _ "$LIB" "$stock" 2>&1)"; rc=$?
eq "the audit of a stock root under errexit prints all its findings and exits 0" "$rc:$(printf '%s\n' "$out" | tail -n 1)" "0:DONE"
eq "  (it does not stop at the first bad line)" "$(printf '%s\n' "$out" | grep -c '^bad ')" "$(audit "$stock" | grep -c '^bad ')"
out="$(bash -c 'set -euo pipefail; . "$1"; ci_quiet_exec() { echo failed >&2; return 1; }; ci_quiet_apply_all "$2"; echo "rc=$?"' _ "$LIB" "$WORK/strict2" 2>&1 || true)"
expect "a root that is not a system: the apply reports instead of dying (no output past a crash, no unbound variable)" bash -c '! printf "%s\n" "$1" | grep -q "unbound variable"' _ "$out"

# ── 9. the lists ──────────────────────────────────────────────────────────────────────────────────────────────────────
echo
echo "== 9. the lists"
expect "the login-text list has the ESM announcement (the script that prints 'additional security updates can be applied with ESM Apps')" bash -c '. "$1"; case " $CI_QUIET_MOTD_SCRIPTS " in *" 88-esm-announce "*) true ;; *) false ;; esac' _ "$LIB"
expect "every purged package is a name apt knows how to hold (letters, digits, dash)" bash -c '. "$1"; for p in $CI_QUIET_PURGE_PACKAGES $CI_QUIET_PURGE_IF_ALONE; do case "$p" in *[!a-z0-9+.-]*|"") exit 1 ;; esac; done' _ "$LIB"
expect "every blocked host is a plain host name" bash -c '. "$1"; for h in $CI_QUIET_HOSTS; do case "$h" in *[!a-z0-9.-]*|"") exit 1 ;; esac; done' _ "$LIB"
expect "the old Step 2 hosts are still blocked" bash -c '. "$1"; for h in metrics.ubuntu.com www.metrics.ubuntu.com popcon.ubuntu.com www.popcon.ubuntu.com; do case " $CI_QUIET_HOSTS " in *" $h "*) ;; *) exit 1 ;; esac; done' _ "$LIB"
expect "the old Step 2 packages are still purged" bash -c '. "$1"; for p in ubuntu-report popularity-contest apport whoopsie apport-symptoms landscape-common; do case " $CI_QUIET_PURGE_PACKAGES " in *" $p "*) ;; *) exit 1 ;; esac; done' _ "$LIB"
expect "the update notifier is not on the autostart deny list" bash -c '. "$1"; ! ci_quiet_autostart_denied update-notifier.desktop && ! ci_quiet_autostart_denied snap-userd-autostart.desktop && ! ci_quiet_autostart_denied geoclue-demo-agent.desktop && ci_quiet_autostart_denied ubuntu-advantage-notification.desktop && ci_quiet_autostart_denied ubuntu-report-on-upgrade.desktop' _ "$LIB"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
