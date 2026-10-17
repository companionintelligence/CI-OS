#!/usr/bin/env bash
#=============================================================================
# Test: the pieces that put Companion OS on the INSTALLED system, on fixture directories. No root, no chroot, no Docker, no
# network, no systemd.
#
#   A  stage-installer.sh   the overlay is assembled: every file guards.list asks for is there, nothing is executable (the
#                           overlay engine's guard (c)), the branding carries the brand tokens and no placeholder, the
#                           bootstrap payload equals core/headless/payload as git tracks it; the pictures render
#   B  stage-headless.sh    the PARITY test: every file of core/headless/payload lands where the Arch installer
#                           (backends/arch/headless-setup/install.sh) puts it, with the same content and mode, and nothing else
#                           appears in the root; a payload file no rule covers stops the script; nginx gets its conf.d include
#                           (Arch's stock nginx.conf has none) and the result is idempotent; --print-units: every unit is enabled by services-systemd.conf
#                           or started on demand by the hotspot script, never both
#   C  ci-os-stage-target   the Calamares step on a fixture target: bootstrap tree, first-boot service/timer/command, payload,
#                           the brand carry-over command; payload problems fail closed, brand problems only warn
#   D  post-install fix-ups the guarded fix-ups on a fixture target, with stub pacman/getent/id/usermod
#   E  first-boot driver    live session, no network, success, failure counting, "degraded" (a required Ollama model is missing:
#                           no done marker, counted, retried, bounded), "no desktop user yet", manual mode
#   F  provision.sh wrapper desktop-user detection from a passwd fixture, the default tier, argument passing, and the check of the
#                           Ollama models after the Arch provisioner reported success (readiness poll, tags, which runs check)
#
#   backends/cachyos/iso/tests/installer-stage.sh
#
# Needs bash 3.2+, git, awk, sed, find, cmp. A is skipped partly without rsvg-convert/ImageMagick. `flock` (Linux) is stubbed when
# missing. Exit: non-zero when a check fails, 2 when it cannot run.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$CACHYOS/../.." && pwd)"
INSTALLER="$CACHYOS/installer"
PROV="$CACHYOS/provision"
PAYLOAD="$REPO_ROOT/core/headless/payload"

PASS=0; FAIL=0; SKIP=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }
verdict() { if [ "$1" = 0 ]; then t_pass "$DESC"; else t_fail "$DESC"; fi; }

for t in git awk sed find cmp; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }; done
[ -d "$PAYLOAD" ] || { echo "no payload at $PAYLOAD" >&2; exit 2; }

W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/installer-stage.XXXXXX")" && pwd -P)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
command -v flock >/dev/null 2>&1 || { printf '#!/bin/bash\nexit 0\n' > "$W/bin/flock"; chmod +x "$W/bin/flock"; }

# git's view of the payload (the working tree may hold caches that are not part of it)
tracked_payload() { git -C "$REPO_ROOT" ls-files core/headless/payload | sed 's|^core/headless/payload/||' | LC_ALL=C sort; }
TRACKED="$W/tracked.txt"; tracked_payload > "$TRACKED"
[ -s "$TRACKED" ] || { echo "git does not track core/headless/payload here (not a checkout?)" >&2; exit 2; }

# =============================================================================================================================
echo "== A  stage-installer.sh"
SD="$W/stage"
CI_OS_STAGING_DIR="$SD" CI_OS_VERSION=2026.10.15 bash "$INSTALLER/stage-installer.sh" > "$W/stage.out" 2>&1 && rc=0 || rc=$?
DESC="stage-installer.sh runs"; verdict "$rc"; [ "$rc" = 0 ] || sed 's/^/      /' "$W/stage.out"
OV="$SD/airootfs/usr/share/ci-os/calamares"

miss=""
while IFS='|' read -r _sev kind a1 _rest; do
  [ "$(printf '%s' "$kind" | tr -d ' ')" = oexists ] || continue
  a1="$(printf '%s' "$a1" | sed -e 's/^ *//' -e 's/ *$//')"
  [ -e "$OV/$a1" ] || miss="$miss $a1"
done < <(grep -E '^(critical|cosmetic)[[:space:]]*\|' "$INSTALLER/guards.list")
DESC="every overlay path guards.list demands (the oexists rows) exists in the staged overlay"; if [ -z "$miss" ]; then verdict 0; else verdict 1; echo "      missing:$miss"; fi

DESC="no staged file is executable (the overlay engine wants a file_permissions entry for each executable file; the scripts run as 'bash <file>')"
if [ -z "$(find "$SD" -type f -perm -100)" ]; then verdict 0; else verdict 1; find "$SD" -type f -perm -100 | sed 's/^/      /'; fi

DESC="the staged bootstrap payload is exactly the files git tracks in core/headless/payload"
(cd "$OV/target/bootstrap/core/headless/payload" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "$W/staged-payload.txt"
if diff -q "$TRACKED" "$W/staged-payload.txt" >/dev/null; then verdict 0; else verdict 1; diff "$TRACKED" "$W/staged-payload.txt" | sed 's/^/      /'; fi
DESC="... byte for byte"
bad=0; while IFS= read -r f; do cmp -s "$PAYLOAD/$f" "$OV/target/bootstrap/core/headless/payload/$f" || bad=1; done < "$TRACKED"; verdict "$bad"

# shellcheck source=/dev/null
. "$REPO_ROOT/vendor/brand/tokens/tokens.sh"
BD="$OV/branding/companion/branding.desc"
DESC="branding.desc: sidebar colours are the dark-sidebar tokens, the version is the one given, no placeholder is left"
if grep -q "SidebarBackground:        \"$CI_DARK_SIDEBAR\"" "$BD" && grep -q "SidebarText:              \"$CI_DARK_SIDEBAR_FOREGROUND\"" "$BD" \
  && grep -q "SidebarBackgroundCurrent: \"$CI_DARK_SIDEBAR_PRIMARY\"" "$BD" && grep -q "SidebarTextCurrent:       \"$CI_DARK_SIDEBAR_PRIMARY_FOREGROUND\"" "$BD" \
  && grep -q 'versionedName:       "Companion OS 2026.10.15"' "$BD" && ! grep -rqE '@[A-Z][A-Z_]*@' "$OV/branding"; then verdict 0; else verdict 1; fi
DESC="show.qml: slide colours are the dark background and foreground tokens"
if grep -q "color: \"$CI_DARK_BACKGROUND\"" "$OV/branding/companion/show.qml" && grep -q "color: \"$CI_DARK_FOREGROUND\"" "$OV/branding/companion/show.qml"; then verdict 0; else verdict 1; fi

DESC="the overlay's scripts and libraries equal the repository's (copied, not edited on the way)"
bad=0
for f in lib/ci-guards.sh lib/ci-pkglist.py scripts/ci-os-stage-target.sh scripts/ci-os-post-install-fixups.sh settings.conf guards.list patches.list pacstrap-code-added.list; do
  cmp -s "$INSTALLER/$f" "$OV/$f" || bad=1
done
for f in "$INSTALLER"/modules/*; do cmp -s "$f" "$OV/modules/$(basename "$f")" || bad=1; done
verdict "$bad"
DESC="a CI_OS_VERSION with a shell metacharacter is refused"
if CI_OS_STAGING_DIR="$W/stage-bad" CI_OS_VERSION='1;rm -rf x' bash "$INSTALLER/stage-installer.sh" >/dev/null 2>&1; then verdict 1; else verdict 0; fi
DESC="without CI_OS_STAGING_DIR it stops (exit 2)"
if env -u CI_OS_STAGING_DIR bash "$INSTALLER/stage-installer.sh" >/dev/null 2>&1; then verdict 1; else rc=$?; [ "$rc" = 2 ] && verdict 0 || verdict 1; fi

if command -v rsvg-convert >/dev/null 2>&1 || command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
  CI_OS_STAGING_DIR="$W/stage-r" CI_OS_VERSION=2026.10.15 bash "$INSTALLER/render-installer-assets.sh" > "$W/render.out" 2>&1 && rc=0 || rc=$?
  DESC="render-installer-assets.sh renders logo.png, icon.png (128x128) and welcome.png (192x192) as 8-bit RGBA PNGs"
  B="$W/stage-r/airootfs/usr/share/ci-os/calamares/branding/companion"
  ok=1; [ "$rc" = 0 ] || ok=0
  for spec in logo.png:128 icon.png:128 welcome.png:192; do
    f="$B/${spec%%:*}"; px="${spec##*:}"
    [ -f "$f" ] || { ok=0; continue; }
    # IHDR: signature 8 bytes, length 4, "IHDR", width 4, height 4, depth 1, colour type 1
    dims="$(od -An -tu1 -j16 -N10 "$f" | awk 'NF >= 10 { w = $1*16777216 + $2*65536 + $3*256 + $4; h = $5*16777216 + $6*65536 + $7*256 + $8; print w "x" h " depth=" $9 " type=" $10 }')"
    [ "$dims" = "${px}x${px} depth=8 type=6" ] || { ok=0; echo "      ${spec%%:*}: $dims"; }
  done
  [ "$(od -An -c -N4 "$B/logo.png" | tr -d ' ' )" = '211PNG' ] || ok=0
  if [ "$ok" = 1 ]; then verdict 0; else verdict 1; sed 's/^/      /' "$W/render.out"; fi
  DESC="rendering twice gives identical files (nothing in the pictures depends on the day)"
  CI_OS_STAGING_DIR="$W/stage-r2" CI_OS_VERSION=2026.10.15 bash "$INSTALLER/render-installer-assets.sh" > /dev/null 2>&1 || true
  if cmp -s "$B/logo.png" "$W/stage-r2/airootfs/usr/share/ci-os/calamares/branding/companion/logo.png" \
     && cmp -s "$B/welcome.png" "$W/stage-r2/airootfs/usr/share/ci-os/calamares/branding/companion/welcome.png"; then verdict 0; else verdict 1; fi
else
  t_skip "render-installer-assets.sh (no rsvg-convert or ImageMagick on this machine)"
fi

# =============================================================================================================================
echo "== B  stage-headless.sh"
STAGER="$PROV/stage-headless.sh"
# A copy of the tracked payload (what a checkout holds), so caches in the working tree cannot matter.
PCOPY="$W/repo-copy"
mkdir -p "$PCOPY/core/lib" "$PCOPY/core/headless"
cp "$REPO_ROOT/core/lib/gpu-detect.sh" "$PCOPY/core/lib/"
mkdir -p "$PCOPY/core/headless/payload"
while IFS= read -r f; do mkdir -p "$PCOPY/core/headless/payload/$(dirname "$f")"; cp "$PAYLOAD/$f" "$PCOPY/core/headless/payload/$f"; done < "$TRACKED"
NG="$HERE/installer-fixtures/nginx-stock.conf"

T="$W/target-b"; mkdir -p "$T/etc/nginx"; cp "$NG" "$T/etc/nginx/nginx.conf"
bash "$STAGER" --root "$T" --payload "$PCOPY/core/headless/payload" > "$W/stage-headless.out" 2>&1 && rc=0 || rc=$?
DESC="stage-headless.sh stages the payload into a fixture target"; verdict "$rc"; [ "$rc" = 0 ] || sed 's/^/      /' "$W/stage-headless.out"

# The independent expectation: where backends/arch/headless-setup/install.sh puts each file (read from that script, not from ours).
expect_dest() {  # REL -> dest|mode  (one per line)
  case "$1" in
    opt/setup-backend/setup_service.py) echo "opt/setup-backend/setup_service.py|755" ;;
    opt/setup-backend/*)                echo "$1|644" ;;
    usr/local/bin/*)                    echo "$1|755" ;;
    usr/share/setup-device/defaults/*|usr/share/applications/*|usr/share/icons/hicolor/scalable/apps/*|var/www/setup-portal/*) echo "$1|644" ;;
    systemd/system/*)                   echo "etc/systemd/system/${1#systemd/system/}|644" ;;
    hostapd/hostapd-setup.conf)         echo "etc/hostapd/hostapd-setup.conf|644" ;;
    dnsmasq.d/setup-portal.conf)        echo "etc/dnsmasq.d/setup-portal.conf|644" ;;
    setup-device-defaults/device.conf)  echo "etc/setup-device/device.conf|600" ;;
    nginx/sites-available/setup-portal) echo "etc/nginx/sites-available/setup-portal|644"; echo "etc/nginx/conf.d/setup-portal.conf|644" ;;
    *) echo "UNCOVERED|$1" ;;
  esac
}
perm_of() { # file -> octal-ish mode string via find -perm probes (portable: no stat -c)
  local f="$1"
  for m in 755 644 600 700 640 664; do [ -n "$(find "$f" -perm "$m" -maxdepth 0 2>/dev/null)" ] && { echo "$m"; return; }; done
  echo other
}
expected="$W/expected-files.txt"; : > "$expected"
bad=""
while IFS= read -r rel; do
  expect_dest "$rel" | while IFS='|' read -r dest mode; do
    [ "$dest" = UNCOVERED ] && { echo "UNCOVERED $mode" >> "$W/uncovered.txt"; continue; }
    echo "$dest" >> "$expected"
    [ -f "$T/$dest" ] || { echo "missing /$dest" >> "$W/bad.txt"; continue; }
    cmp -s "$PAYLOAD/$rel" "$T/$dest" || echo "content differs /$dest" >> "$W/bad.txt"
    [ "$(perm_of "$T/$dest")" = "$mode" ] || echo "mode of /$dest is $(perm_of "$T/$dest"), wanted $mode" >> "$W/bad.txt"
  done
done < "$TRACKED"
DESC="PARITY: every payload file is in the target with the same content and the mode the Arch installer gives it"
if [ ! -e "$W/bad.txt" ] && [ ! -e "$W/uncovered.txt" ]; then verdict 0; else verdict 1; cat "$W/bad.txt" "$W/uncovered.txt" 2>/dev/null | sed 's/^/      /'; fi
DESC="PARITY: nothing else is in the target but the known extras (gpu-detect.sh, /etc/hosts, nginx.conf and its backup, the state directory)"
(cd "$T" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "$W/actual-files.txt"
{ cat "$expected"; echo usr/lib/ci-os/gpu-detect.sh; echo etc/hosts; echo etc/nginx/nginx.conf; echo etc/nginx/nginx.conf.ci-os-backup; } | LC_ALL=C sort -u > "$W/want-files.txt"
if diff -q "$W/want-files.txt" "$W/actual-files.txt" >/dev/null; then verdict 0; else verdict 1; diff "$W/want-files.txt" "$W/actual-files.txt" | sed 's/^/      /'; fi
DESC="the PARITY expectation itself covers every tracked payload file (the test's own table is complete)"
if [ ! -e "$W/uncovered.txt" ]; then verdict 0; else verdict 1; fi
DESC="gpu-detect.sh lands in /usr/lib/ci-os (644) and /etc/hosts maps setup.ci.computer to 192.168.99.1"
if cmp -s "$REPO_ROOT/core/lib/gpu-detect.sh" "$T/usr/lib/ci-os/gpu-detect.sh" && grep -qx '192.168.99.1 setup.ci.computer' "$T/etc/hosts"; then verdict 0; else verdict 1; fi
DESC="no pycache or .pyc from the working tree is staged"
if [ -z "$(find "$T" -name '*.pyc' -o -name __pycache__)" ]; then verdict 0; else verdict 1; fi

DESC="nginx: the stock nginx.conf had no conf.d include; stage-headless.sh adds exactly one, inside the http block, as its last line"
n_inc="$(grep -c 'include /etc/nginx/conf.d/\*.conf;' "$T/etc/nginx/nginx.conf")"
if ! grep -v '^#' "$NG" | grep -q 'conf\.d' && [ "$n_inc" = 1 ] && [ "$(tail -n 2 "$T/etc/nginx/nginx.conf" | head -n 1)" = '    include /etc/nginx/conf.d/*.conf;' ] && [ "$(tail -n 1 "$T/etc/nginx/nginx.conf")" = '}' ]; then verdict 0; else verdict 1; tail -n 5 "$T/etc/nginx/nginx.conf" | sed 's/^/      /'; fi
DESC="nginx: the include is inside http { } (brace depth 1 at that line), after the stock server block"
depth="$(awk '/include \/etc\/nginx\/conf.d/ { print d; exit } { n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); d += n - m }' "$T/etc/nginx/nginx.conf")"
if [ "$depth" = 1 ]; then verdict 0; else verdict 1; echo "      depth=$depth"; fi
cp "$T/etc/nginx/nginx.conf" "$W/nginx-after-1.conf"
bash "$STAGER" --root "$T" --payload "$PCOPY/core/headless/payload" >/dev/null 2>&1 && rc=0 || rc=$?
DESC="nginx: a second run changes nothing (idempotent) and exits 0"
if [ "$rc" = 0 ] && cmp -s "$W/nginx-after-1.conf" "$T/etc/nginx/nginx.conf"; then verdict 0; else verdict 1; fi
DESC="re-running keeps a configured device.conf, hostapd and dnsmasq config (config-if-missing)"
echo "SERIAL_SUFFIX=abc123" > "$T/etc/setup-device/device.conf"; chmod 600 "$T/etc/setup-device/device.conf"
bash "$STAGER" --root "$T" --payload "$PCOPY/core/headless/payload" >/dev/null 2>&1
if [ "$(cat "$T/etc/setup-device/device.conf")" = "SERIAL_SUFFIX=abc123" ]; then verdict 0; else verdict 1; fi

T2="$W/target-b2"; mkdir -p "$T2/etc"
bash "$STAGER" --root "$T2" --payload "$PCOPY/core/headless/payload" >/dev/null 2>&1 && rc=0 || rc=$?
DESC="without nginx.conf in the target (nginx not installed) it fails instead of staging a portal that cannot be served"
if [ "$rc" = 1 ]; then verdict 0; else verdict 1; fi

cp -R "$PCOPY" "$W/repo-copy2"; mkdir -p "$W/repo-copy2/core/headless/payload/etc-new"; echo x > "$W/repo-copy2/core/headless/payload/etc-new/surprise.conf"
T3="$W/target-b3"; mkdir -p "$T3/etc/nginx"; cp "$NG" "$T3/etc/nginx/nginx.conf"
bash "$STAGER" --root "$T3" --payload "$W/repo-copy2/core/headless/payload" > "$W/uncov.out" 2>&1 && rc=0 || rc=$?
DESC="a payload file no rule covers (etc-new/surprise.conf) stops the script and is named: the payload cannot drift from what ships elsewhere"
if [ "$rc" = 1 ] && grep -q 'etc-new/surprise.conf' "$W/uncov.out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/uncov.out"; fi

cp -R "$PCOPY" "$W/repo-copy3"; rm "$W/repo-copy3/core/headless/payload/var/www/setup-portal/index.html"
bash "$STAGER" --root "$W/target-b3" --payload "$W/repo-copy3/core/headless/payload" > "$W/req.out" 2>&1 && rc=0 || rc=$?
DESC="a missing required payload file (the portal page) stops the script"
if [ "$rc" = 1 ] && grep -q 'index.html' "$W/req.out"; then verdict 0; else verdict 1; fi

DESC="--root is mandatory (exit 2): staging into the running system must be explicit"
if bash "$STAGER" --payload "$PCOPY/core/headless/payload" >/dev/null 2>&1; then verdict 1; else rc=$?; [ "$rc" = 2 ] && verdict 0 || verdict 1; fi

# Which units run at boot and which only when the monitor decides the portal is needed (services-systemd.conf, "NOT enabled, on
# purpose"). Derived from the payload, not typed here: a unit that setup-device-hotspot-start.sh starts BY NAME needs no `enable`
# and must not have one (an enabled hostapd-setup is an access point at every boot, an enabled nginx is the setup API on port 80 on
# every network); a unit nothing else starts (the backend the portal proxies to, the monitor that runs the hotspot script) must be
# enabled, or the portal can never come up. No PyYAML needed: the file has one `- name:` per unit and an `action:` line after it.
HOTSPOT="$PCOPY/core/headless/payload/usr/local/bin/setup-device-hotspot-start.sh"
MONITOR="$PCOPY/core/headless/payload/usr/local/bin/setup-network-monitor.sh"
enabled_units() {  # the units services-systemd.conf enables
  awk '/^   - name: "/ { n = $0; sub(/^   - name: "/, "", n); sub(/".*$/, "", n) } /^     action: "enable"/ { print n }' "$INSTALLER/modules/services-systemd.conf" | sort
}
on_demand_units() {  # the units the hotspot script starts itself (comment lines ignored)
  { grep -v '^[[:space:]]*#' "$HOTSPOT" | grep -oE 'systemctl start [A-Za-z0-9@_.-]+' | awk '{ u = $3; sub(/\.service$/, "", u); print u }' | sort -u; } || true
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }   # NAME "a b c"
units="$(bash "$STAGER" --payload "$PCOPY/core/headless/payload" --print-units | sort | tr '\n' ' ')"
ENABLED="$(enabled_units | tr '\n' ' ')"; ONDEMAND="$(on_demand_units | tr '\n' ' ')"
DESC="--print-units: the monitor runs the hotspot script, and that script starts nginx itself (so nginx needs no enable and port 80 stays closed at boot)"
if grep -q 'setup-device-hotspot-start.sh' "$MONITOR" && in_list nginx "$ONDEMAND"; then verdict 0; else verdict 1; echo "      started on demand: $ONDEMAND"; fi
DESC="--print-units: every unit the payload ships (+ nginx) is enabled at boot OR started on demand by the hotspot script, never both and never neither"
bad=0
for u in $units nginx; do
  en=0; od=0; in_list "$u" "$ENABLED" && en=1; in_list "$u" "$ONDEMAND" && od=1
  if [ "$en" = "$od" ]; then bad=1; echo "      $u: enabled=$en started-on-demand=$od"; fi
done
verdict "$bad"
DESC="--print-units: the access point (hostapd-setup, dnsmasq-setup) is started on demand; the backend and the monitor are what runs at every boot"
if in_list hostapd-setup "$ONDEMAND" && in_list dnsmasq-setup "$ONDEMAND" && in_list setup-backend "$ENABLED" && in_list setup-network-monitor "$ENABLED"; then verdict 0
else verdict 1; echo "      enabled: $ENABLED  on demand: $ONDEMAND"; fi

# What the staged hotspot episode does and does not do (the payload's own tests are core/headless/tests/payload; these are the
# properties this edition relies on when it leaves the units to be started on demand).
DESC="the hotspot script never touches Docker or Traefik (it used to run 'docker stop traefik' and never started it again)"
if ! grep -v '^[[:space:]]*#' "$HOTSPOT" | grep -qiE 'docker|traefik'; then verdict 0; else verdict 1; fi
DESC="the hotspot script ends an episode it started: it has a stop mode and a trap that runs it when a start fails or is interrupted"
if grep -qE '^[[:space:]]*stop\)' "$HOTSPOT" && grep -qE '^trap on_exit EXIT' "$HOTSPOT" && grep -qE "^trap 'exit 143' TERM" "$HOTSPOT"; then verdict 0; else verdict 1; fi
DESC="the staged nginx site answers /api/ only to the setup network and this machine (the portal listens on every interface)"
NGSITE="$PCOPY/core/headless/payload/nginx/sites-available/setup-portal"
if awk '/location \/api\// { f = 1 } f && /allow 192\.168\.99\.0\/24;/ { a = 1 } f && /deny all;/ { d = 1 } f && /proxy_pass/ { exit } END { exit (a && d) ? 0 : 1 }' "$NGSITE"; then verdict 0; else verdict 1; fi
DESC="the staged hostapd config isolates clients (ap_isolate=1) and sets no country of its own"
if grep -q '^ap_isolate=1' "$T/etc/hostapd/hostapd-setup.conf" && ! grep -q '^country_code=' "$T/etc/hostapd/hostapd-setup.conf"; then verdict 0; else verdict 1; fi

# =============================================================================================================================
echo "== C  ci-os-stage-target.sh (the Calamares step)"
STG="$OV/scripts/ci-os-stage-target.sh"
mkdir -p "$W/fakecarry"
cat > "$W/fakecarry/carry-over" <<'EOF'
#!/bin/bash
# stand-in for /usr/share/ci-os/installed/carry-over: records its argument, makes the themes and the os-release
echo "carry-over $*" >> "$FAKE_CARRY_LOG"
mkdir -p "$1/usr/share/grub/themes/companion-os" "$1/usr/share/plymouth/themes/companion-os" "$1/etc"
: > "$1/usr/share/grub/themes/companion-os/theme.txt"; : > "$1/usr/share/plymouth/themes/companion-os/companion-os.plymouth"
echo 'NAME="Companion OS"' > "$1/etc/os-release"
exit "${FAKE_CARRY_RC:-0}"
EOF
new_target() { rm -rf "$1"; mkdir -p "$1/usr" "$1/etc/nginx"; cp "$NG" "$1/etc/nginx/nginx.conf"; }

T="$W/target-c"; new_target "$T"
FAKE_CARRY_LOG="$W/carry.log" CI_OS_OVERLAY_DIR="$OV" CI_OS_CARRY_OVER="$W/fakecarry/carry-over" bash "$STG" "$T" > "$W/c.out" 2>&1 && rc=0 || rc=$?
DESC="the step succeeds on a fixture target and calls the brand carry-over with the target root"
if [ "$rc" = 0 ] && grep -qx "carry-over $T" "$W/carry.log"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/c.out"; fi
DESC="it installs the provisioning tree (bootstrap), the first-boot script, the service, the timer, ci-os-setup and the fix-up script, with the right modes"
ok=0
[ -f "$T/usr/lib/ci-os/bootstrap/backends/arch/provision/provision.sh" ] || ok=1
[ -f "$T/usr/lib/ci-os/bootstrap/backends/cachyos/provision/provision.sh" ] || ok=1
[ -n "$(find "$T/usr/lib/ci-os/first-boot-setup.sh" -perm 755)" ] || ok=1
[ -n "$(find "$T/usr/local/bin/ci-os-setup" -perm 755)" ] || ok=1
[ -n "$(find "$T/usr/lib/ci-os/ci-os-post-install-fixups.sh" -perm 755)" ] || ok=1
[ -n "$(find "$T/usr/lib/systemd/system/ci-os-first-boot-setup.service" -perm 644)" ] || ok=1
cmp -s "$PROV/systemd/ci-os-first-boot-setup.timer" "$T/usr/lib/systemd/system/ci-os-first-boot-setup.timer" || ok=1
[ -n "$(find "$T/usr/lib/ci-os/bootstrap" -name provision.sh -perm 755)" ] || ok=1
verdict "$ok"
DESC="it stages the portal payload (same files as test B) and wires nginx"
if [ -f "$T/etc/systemd/system/setup-network-monitor.service" ] && [ -f "$T/etc/nginx/conf.d/setup-portal.conf" ] && grep -q 'include /etc/nginx/conf.d' "$T/etc/nginx/nginx.conf"; then verdict 0; else verdict 1; fi
DESC="the first-boot script in the target is the one in the repository"
if cmp -s "$PROV/first-boot-setup.sh" "$T/usr/lib/ci-os/first-boot-setup.sh" && cmp -s "$PROV/ci-os-setup.sh" "$T/usr/local/bin/ci-os-setup"; then verdict 0; else verdict 1; fi
DESC="a target that already runs the installed bootstrap can run stage-headless.sh again from /usr/lib/ci-os/bootstrap (the default payload path resolves there)"
T4="$W/target-c4"; new_target "$T4"
if bash "$T/usr/lib/ci-os/bootstrap/backends/cachyos/provision/stage-headless.sh" --root "$T4" >/dev/null 2>&1; then verdict 0; else verdict 1; fi

DESC="it creates its directories readable and searchable for everybody even when Calamares runs it under a strict umask (nginx, dnsmasq and systemd read them later)"
new_target "$T"
( umask 077; FAKE_CARRY_LOG="$W/carry.log" CI_OS_OVERLAY_DIR="$OV" CI_OS_CARRY_OVER="$W/fakecarry/carry-over" bash "$STG" "$T" > "$W/c-umask.out" 2>&1 ) || true
if [ -z "$(find "$T" -type d ! -perm -755)" ] && [ -f "$T/var/www/setup-portal/index.html" ]; then verdict 0; else verdict 1; find "$T" -type d ! -perm -755 | sed 's/^/      /'; fi

DESC="it refuses / and a target without /usr"
mkdir -p "$W/empty"
if CI_OS_OVERLAY_DIR="$OV" bash "$STG" / >/dev/null 2>&1 || CI_OS_OVERLAY_DIR="$OV" bash "$STG" "$W/empty" >/dev/null 2>&1; then verdict 1; else verdict 0; fi

new_target "$T"
FAKE_CARRY_LOG="$W/carry.log" FAKE_CARRY_RC=1 CI_OS_OVERLAY_DIR="$OV" CI_OS_CARRY_OVER="$W/fakecarry/carry-over" bash "$STG" "$T" > "$W/c1.out" 2>&1 && rc=0 || rc=$?
DESC="BRAND problems fail open: carry-over exits 1 -> a WARN line, exit 0, the rest is staged"
if [ "$rc" = 0 ] && grep -q 'WARN:' "$W/c1.out" && [ -f "$T/usr/lib/ci-os/first-boot-setup.sh" ]; then verdict 0; else verdict 1; sed 's/^/      /' "$W/c1.out"; fi
new_target "$T"
CI_OS_OVERLAY_DIR="$OV" CI_OS_CARRY_OVER="$W/fakecarry/does-not-exist" bash "$STG" "$T" > "$W/c2.out" 2>&1 && rc=0 || rc=$?
DESC="BRAND problems fail open: no carry-over command at all -> WARN lines naming the CachyOS defaults the system keeps, exit 0"
if [ "$rc" = 0 ] && grep -q 'is not in this live image' "$W/c2.out" && grep -q 'GRUB theme' "$W/c2.out" && grep -q 'Plymouth theme' "$W/c2.out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/c2.out"; fi

cp -R "$OV" "$W/ov-broken"; rm "$W/ov-broken/target/units/ci-os-first-boot-setup.timer"
new_target "$T"
FAKE_CARRY_LOG="$W/carry.log" CI_OS_OVERLAY_DIR="$W/ov-broken" CI_OS_CARRY_OVER="$W/fakecarry/carry-over" bash "$STG" "$T" > "$W/c3.out" 2>&1 && rc=0 || rc=$?
DESC="PAYLOAD problems fail closed: a missing first-boot timer in the overlay -> exit 1 (Calamares aborts the install)"
if [ "$rc" = 1 ] && grep -q 'ERROR' "$W/c3.out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/c3.out"; fi
cp -R "$OV" "$W/ov-broken2"; rm "$W/ov-broken2/target/bootstrap/core/headless/payload/systemd/system/hostapd-setup.service"
new_target "$T"
FAKE_CARRY_LOG="$W/carry.log" CI_OS_OVERLAY_DIR="$W/ov-broken2" CI_OS_CARRY_OVER="$W/fakecarry/carry-over" bash "$STG" "$T" > "$W/c4.out" 2>&1 && rc=0 || rc=$?
DESC="PAYLOAD problems fail closed: a missing payload unit -> exit 1"
if [ "$rc" = 1 ]; then verdict 0; else verdict 1; fi

# =============================================================================================================================
echo "== D  ci-os-post-install-fixups.sh"
FIX="$OV/scripts/ci-os-post-install-fixups.sh"
mkdir -p "$W/fbin"
stubf() { printf '#!/bin/bash\n%s\n' "$2" > "$W/fbin/$1"; chmod +x "$W/fbin/$1"; }
stubf pacman 'echo "pacman $*" >> "$FAKE_FIX_LOG"; case "$1 $2" in "-Q cachyos-grub-theme") [ "${FAKE_HAS_GRUB_THEME:-1}" = 1 ]; exit $? ;; esac; case "$1" in -Rns) exit "${FAKE_RM_RC:-0}" ;; esac; exit 0'
stubf getent 'case "$1" in passwd) [ "$2" = alice ] || exit 2; echo "alice:x:1000:1000::/home/alice:/bin/bash" ;; group) [ "${FAKE_HAS_DOCKER_GROUP:-1}" = 1 ] && echo "docker:x:970:" || exit 2 ;; esac; exit 0'
stubf id 'echo "${FAKE_GROUPS:-alice wheel docker}"'
stubf usermod 'echo "usermod $*" >> "$FAKE_FIX_LOG"; exit "${FAKE_USERMOD_RC:-0}"'
new_fix_root() { rm -rf "$1"; mkdir -p "$1/etc/default" "$1/usr/share/libalpm/scripts"
  printf 'GRUB_THEME="/usr/share/grub/themes/companion-os/theme.txt"\nGRUB_DISTRIBUTOR="Companion OS"\n' > "$1/etc/default/grub"
  echo 'NAME="Companion OS"' > "$1/etc/os-release"; }
run_fix() { # root [env...] -> FIX_OUT FIX_RC
  local r="$1"; shift; : > "$W/fix.log"
  FIX_OUT="$(env -i PATH="$W/fbin:/usr/bin:/bin" CI_OS_ROOT="$r" FAKE_FIX_LOG="$W/fix.log" "$@" bash "$FIX" alice 2>&1)" && FIX_RC=0 || FIX_RC=$?
}
FR="$W/fixroot"; new_fix_root "$FR"
run_fix "$FR"
DESC="a good install: cachyos-grub-theme is removed (GRUB_THEME is ours), alice is already in docker, no warning, exit 0"
if [ "$FIX_RC" = 0 ] && grep -q '^pacman -Rns --noconfirm cachyos-grub-theme' "$W/fix.log" && ! grep -q '^usermod' "$W/fix.log" && ! printf '%s' "$FIX_OUT" | grep -q 'WARN:' \
   && printf '%s' "$FIX_OUT" | grep -q 'done (0 warning(s))'; then verdict 0; else verdict 1; printf '%s\n' "$FIX_OUT" | sed 's/^/      /'; fi
new_fix_root "$FR"; printf 'GRUB_THEME="/usr/share/grub/themes/cachyos/theme.txt"\n' > "$FR/etc/default/grub"
run_fix "$FR"
DESC="if GRUB_THEME is not ours, the CachyOS theme package is KEPT (GRUB would lose its theme) and the script warns"
if ! grep -q 'Rns' "$W/fix.log" && printf '%s' "$FIX_OUT" | grep -q 'WARN:.*keeping cachyos-grub-theme'; then verdict 0; else verdict 1; printf '%s\n' "$FIX_OUT" | sed 's/^/      /'; fi
new_fix_root "$FR"
run_fix "$FR" FAKE_RM_RC=1
DESC="a package that cannot be removed (something depends on it) is a warning, never a failure"
if [ "$FIX_RC" = 0 ] && printf '%s' "$FIX_OUT" | grep -q 'WARN: could not remove cachyos-grub-theme'; then verdict 0; else verdict 1; fi
new_fix_root "$FR"
run_fix "$FR" FAKE_GROUPS="alice wheel users"
DESC="a user missing from docker is added with usermod -aG docker"
if grep -q '^usermod -aG docker alice' "$W/fix.log"; then verdict 0; else verdict 1; fi
new_fix_root "$FR"
run_fix "$FR" FAKE_HAS_DOCKER_GROUP=0
DESC="no docker group at all -> a warning that docker is missing"
if printf '%s' "$FIX_OUT" | grep -q 'WARN: no docker group'; then verdict 0; else verdict 1; fi
new_fix_root "$FR"; echo 'NAME="CachyOS Linux"' > "$FR/etc/os-release"
printf '#!/bin/bash\necho writer-ran >> "$FAKE_FIX_LOG"; echo "NAME=\\"Companion OS\\"" > "$CI_OS_ROOT/etc/os-release"\n' > "$FR/usr/share/libalpm/scripts/zz-ci-os-os-release"
run_fix "$FR"
DESC="/etc/os-release still saying CachyOS -> the identity writer runs once more and the result is checked"
if grep -q writer-ran "$W/fix.log" && grep -q 'NAME="Companion OS"' "$FR/etc/os-release" && printf '%s' "$FIX_OUT" | grep -q 'rewrote /etc/os-release'; then verdict 0; else verdict 1; printf '%s\n' "$FIX_OUT" | sed 's/^/      /'; fi
new_fix_root "$FR"; echo 'NAME="CachyOS Linux"' > "$FR/etc/os-release"; rm -f "$FR/usr/share/libalpm/scripts/zz-ci-os-os-release"
run_fix "$FR"
DESC="... and with no writer it only warns (exit 0): an installation never fails over its name"
if [ "$FIX_RC" = 0 ] && printf '%s' "$FIX_OUT" | grep -q 'WARN:.*zz-ci-os-os-release is missing'; then verdict 0; else verdict 1; fi
new_fix_root "$FR"; printf 'GRUB_DISTRIBUTOR="CachyOS"\nGRUB_THEME="/x/companion-os/theme.txt"\n' > "$FR/etc/default/grub"
run_fix "$FR" FAKE_HAS_GRUB_THEME=0
DESC="a GRUB_DISTRIBUTOR that still names CachyOS is reported"
if printf '%s' "$FIX_OUT" | grep -q 'WARN: GRUB_DISTRIBUTOR still names CachyOS'; then verdict 0; else verdict 1; fi

# =============================================================================================================================
echo "== E  first-boot-setup.sh"
FB="$PROV/first-boot-setup.sh"
mkdir -p "$W/fb"
cat > "$W/fb/provision.sh" <<'EOF'
#!/bin/bash
echo "provision $*" >> "$FB_LOG"
exit "${FB_PROVISION_RC:-0}"
EOF
cat > "$W/fb/net-up" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$W/fb/net-down" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$W/fb/net-up" "$W/fb/net-down"
# The script sends its output through `exec > >(tee -a LOG)`, and that tee can still be writing when the script has exited: a test that
# reads the output at once sometimes misses the last line. Wait for the tee of this directory to finish (bounded; without pgrep, no wait).
fb_settle() {  # DIR
  local i=0
  while pgrep -f "tee -a $1/first-boot.log" >/dev/null 2>&1 && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  return 0
}
fb_run() { # NAME [VAR=value ...] -> FB_RC; state in $W/fb-NAME
  local n="$1"; shift
  local D="$W/fb-$n"; mkdir -p "$D/boot/backends/cachyos/provision" "$D/state"
  cp "$W/fb/provision.sh" "$D/boot/backends/cachyos/provision/provision.sh"
  : > "$D/provision.log"; [ -e "$D/cmdline" ] || echo "BOOT_IMAGE=/vmlinuz-linux-cachyos root=UUID=x rw" > "$D/cmdline"
  env -i PATH="$W/bin:/usr/bin:/bin:/usr/sbin:/sbin" FB_LOG="$D/provision.log" CI_OS_BOOTSTRAP_ROOT="$D/boot" CI_OS_STATE_DIR="$D/state" \
    CI_OS_LOG_FILE="$D/first-boot.log" CI_OS_LOCK_FILE="$D/lock" CI_OS_CMDLINE_FILE="$D/cmdline" CI_OS_RUN_ARCHISO="$D/no-archiso" \
    CI_OS_NETWORK_PROBE="$W/fb/net-up" CI_OS_NETWORK_TRIES=2 CI_OS_NETWORK_SLEEP=0 "$@" bash "$FB" > "$D/out" 2>&1 && FB_RC=0 || FB_RC=$?
  FB_DIR="$D"; fb_settle "$D"
}
mkdir -p "$W/fb-live"
echo "BOOT_IMAGE=/arch/boot/x86_64/vmlinuz archisobasedir=arch archisosearchuuid=x" > "$W/fb-live/cmdline"
fb_run live
DESC="a live session (archisobasedir on the kernel command line) is never provisioned"
if [ "$FB_RC" = 0 ] && [ ! -s "$FB_DIR/provision.log" ] && grep -q 'Live session detected' "$FB_DIR/out" && [ ! -e "$FB_DIR/state/.first-boot-setup-done" ]; then verdict 0; else verdict 1; fi

fb_run offline CI_OS_NETWORK_PROBE="$W/fb/net-down"
DESC="no network: no provisioning, no marker, no attempt counted, exit 0 (the timer retries)"
if [ "$FB_RC" = 0 ] && [ ! -s "$FB_DIR/provision.log" ] && [ ! -e "$FB_DIR/state/.first-boot-setup-done" ] && [ ! -e "$FB_DIR/state/first-boot-setup-attempts" ]; then verdict 0; else verdict 1; fi

fb_run ok
DESC="success: provision.sh runs with --tier=core by default, the marker is written, the attempt file is removed"
if [ "$FB_RC" = 0 ] && grep -qx 'provision --tier=core' "$FB_DIR/provision.log" && [ -f "$FB_DIR/state/.first-boot-setup-done" ] && [ ! -e "$FB_DIR/state/first-boot-setup-attempts" ]; then verdict 0; else verdict 1; sed 's/^/      /' "$FB_DIR/out"; fi
: > "$FB_DIR/provision.log"
env -i PATH="$W/bin:/usr/bin:/bin" FB_LOG="$FB_DIR/provision.log" CI_OS_BOOTSTRAP_ROOT="$FB_DIR/boot" CI_OS_STATE_DIR="$FB_DIR/state" CI_OS_LOG_FILE="$FB_DIR/first-boot.log" \
  CI_OS_LOCK_FILE="$FB_DIR/lock" CI_OS_CMDLINE_FILE="$FB_DIR/cmdline" CI_OS_RUN_ARCHISO="$FB_DIR/no-archiso" CI_OS_NETWORK_PROBE="$W/fb/net-up" CI_OS_NETWORK_TRIES=2 CI_OS_NETWORK_SLEEP=0 \
  bash "$FB" > "$FB_DIR/out2" 2>&1; fb_settle "$FB_DIR"
DESC="after success an automatic run does nothing (marker present)"
if [ ! -s "$FB_DIR/provision.log" ] && grep -q 'already completed' "$FB_DIR/out2"; then verdict 0; else verdict 1; fi
env -i PATH="$W/bin:/usr/bin:/bin" FB_LOG="$FB_DIR/provision.log" CI_OS_BOOTSTRAP_ROOT="$FB_DIR/boot" CI_OS_STATE_DIR="$FB_DIR/state" CI_OS_LOG_FILE="$FB_DIR/first-boot.log" \
  CI_OS_LOCK_FILE="$FB_DIR/lock" CI_OS_CMDLINE_FILE="$FB_DIR/cmdline" CI_OS_RUN_ARCHISO="$FB_DIR/no-archiso" CI_OS_NETWORK_PROBE="$W/fb/net-up" CI_OS_NETWORK_TRIES=2 CI_OS_NETWORK_SLEEP=0 \
  bash "$FB" --manual --tier=core,hardware > "$FB_DIR/out3" 2>&1; fb_settle "$FB_DIR"
DESC="--manual runs anyway and forwards its arguments (ci-os-setup --tier=core,hardware)"
if grep -qx 'provision --tier=core,hardware' "$FB_DIR/provision.log"; then verdict 0; else verdict 1; fi

fb_run fail FB_PROVISION_RC=1
DESC="failure: no marker, one attempt counted, exit 0, 'Will retry' is said"
if [ "$FB_RC" = 0 ] && [ ! -e "$FB_DIR/state/.first-boot-setup-done" ] && [ "$(cat "$FB_DIR/state/first-boot-setup-attempts")" = 1 ] && grep -q 'Will retry automatically' "$FB_DIR/out"; then verdict 0; else verdict 1; fi
n=0
for i in 2 3; do
  env -i PATH="$W/bin:/usr/bin:/bin" FB_PROVISION_RC=1 FB_LOG="$FB_DIR/provision.log" CI_OS_BOOTSTRAP_ROOT="$FB_DIR/boot" CI_OS_STATE_DIR="$FB_DIR/state" CI_OS_LOG_FILE="$FB_DIR/first-boot.log" \
    CI_OS_LOCK_FILE="$FB_DIR/lock" CI_OS_CMDLINE_FILE="$FB_DIR/cmdline" CI_OS_RUN_ARCHISO="$FB_DIR/no-archiso" CI_OS_NETWORK_PROBE="$W/fb/net-up" CI_OS_NETWORK_TRIES=2 CI_OS_NETWORK_SLEEP=0 \
    bash "$FB" > "$FB_DIR/out-$i" 2>&1 || true; fb_settle "$FB_DIR"
  n=$((n + 1))
done
: > "$FB_DIR/provision.log"
env -i PATH="$W/bin:/usr/bin:/bin" FB_LOG="$FB_DIR/provision.log" CI_OS_BOOTSTRAP_ROOT="$FB_DIR/boot" CI_OS_STATE_DIR="$FB_DIR/state" CI_OS_LOG_FILE="$FB_DIR/first-boot.log" \
  CI_OS_LOCK_FILE="$FB_DIR/lock" CI_OS_CMDLINE_FILE="$FB_DIR/cmdline" CI_OS_RUN_ARCHISO="$FB_DIR/no-archiso" CI_OS_NETWORK_PROBE="$W/fb/net-up" CI_OS_NETWORK_TRIES=2 CI_OS_NETWORK_SLEEP=0 \
  bash "$FB" > "$FB_DIR/out-4" 2>&1; fb_settle "$FB_DIR"
DESC="after 3 failed automatic attempts it stops retrying (and says how to run it by hand)"
if [ ! -s "$FB_DIR/provision.log" ] && grep -q 'not retrying automatically' "$FB_DIR/out-4" && [ "$(cat "$FB_DIR/state/first-boot-setup-attempts")" = 3 ]; then verdict 0; else verdict 1; fi

# provision.sh exit 74: the run went to the end but a required Ollama model is missing. Silent success was the defect: the marker used to be
# written whenever provision.sh exited 0, and the Arch provisioner exits 0 after a failed model pull.
fb_run degraded FB_PROVISION_RC=74
DESC="degraded (provision.sh exit 74, a model is missing): NO done marker, the attempt stays counted, exit 0, the status file says so, a retry is announced"
if [ "$FB_RC" = 0 ] && [ ! -e "$FB_DIR/state/.first-boot-setup-done" ] && [ "$(cat "$FB_DIR/state/first-boot-setup-attempts")" = 1 ] \
   && grep -q '^degraded' "$FB_DIR/state/first-boot-setup-status" && grep -q 'Ollama models are missing' "$FB_DIR/out" && grep -q 'Will retry automatically' "$FB_DIR/out"; then verdict 0; else verdict 1; sed 's/^/      /' "$FB_DIR/out"; fi
for i in 2 3; do
  env -i PATH="$W/bin:/usr/bin:/bin" FB_PROVISION_RC=74 FB_LOG="$FB_DIR/provision.log" CI_OS_BOOTSTRAP_ROOT="$FB_DIR/boot" CI_OS_STATE_DIR="$FB_DIR/state" CI_OS_LOG_FILE="$FB_DIR/first-boot.log" \
    CI_OS_LOCK_FILE="$FB_DIR/lock" CI_OS_CMDLINE_FILE="$FB_DIR/cmdline" CI_OS_RUN_ARCHISO="$FB_DIR/no-archiso" CI_OS_NETWORK_PROBE="$W/fb/net-up" CI_OS_NETWORK_TRIES=2 CI_OS_NETWORK_SLEEP=0 \
    bash "$FB" > "$FB_DIR/out-$i" 2>&1 || true; fb_settle "$FB_DIR"
done
DESC="degraded three times: the third run says the models are STILL missing, that setup is NOT marked complete, and names 'sudo ci-os-setup'; still no marker"
if grep -q 'STILL missing' "$FB_DIR/out-3" && grep -q 'NOT marked complete' "$FB_DIR/out-3" && grep -q 'sudo ci-os-setup' "$FB_DIR/out-3" && [ ! -e "$FB_DIR/state/.first-boot-setup-done" ]; then verdict 0; else verdict 1; sed 's/^/      /' "$FB_DIR/out-3"; fi
: > "$FB_DIR/provision.log"
env -i PATH="$W/bin:/usr/bin:/bin" FB_LOG="$FB_DIR/provision.log" CI_OS_BOOTSTRAP_ROOT="$FB_DIR/boot" CI_OS_STATE_DIR="$FB_DIR/state" CI_OS_LOG_FILE="$FB_DIR/first-boot.log" \
  CI_OS_LOCK_FILE="$FB_DIR/lock" CI_OS_CMDLINE_FILE="$FB_DIR/cmdline" CI_OS_RUN_ARCHISO="$FB_DIR/no-archiso" CI_OS_NETWORK_PROBE="$W/fb/net-up" CI_OS_NETWORK_TRIES=2 CI_OS_NETWORK_SLEEP=0 \
  bash "$FB" > "$FB_DIR/out-4" 2>&1; fb_settle "$FB_DIR"
DESC="... and a fourth automatic run does nothing (the bound), with the marker still absent"
if [ ! -s "$FB_DIR/provision.log" ] && grep -q 'not retrying automatically' "$FB_DIR/out-4" && [ ! -e "$FB_DIR/state/.first-boot-setup-done" ]; then verdict 0; else verdict 1; fi
env -i PATH="$W/bin:/usr/bin:/bin" FB_PROVISION_RC=74 FB_LOG="$FB_DIR/provision.log" CI_OS_BOOTSTRAP_ROOT="$FB_DIR/boot" CI_OS_STATE_DIR="$FB_DIR/state" CI_OS_LOG_FILE="$FB_DIR/first-boot.log" \
  CI_OS_LOCK_FILE="$FB_DIR/lock" CI_OS_CMDLINE_FILE="$FB_DIR/cmdline" CI_OS_RUN_ARCHISO="$FB_DIR/no-archiso" CI_OS_NETWORK_PROBE="$W/fb/net-up" CI_OS_NETWORK_TRIES=2 CI_OS_NETWORK_SLEEP=0 \
  bash "$FB" --manual > "$FB_DIR/out-5" 2>&1; fb_settle "$FB_DIR"
DESC="--manual with a model still missing: runs even though the automatic attempts are used up, says what to check, writes no marker"
if grep -q 'provision' "$FB_DIR/provision.log" && grep -q 'models are missing' "$FB_DIR/out-5" && grep -q 're-run: sudo ci-os-setup' "$FB_DIR/out-5" && [ ! -e "$FB_DIR/state/.first-boot-setup-done" ]; then verdict 0; else verdict 1; sed 's/^/      /' "$FB_DIR/out-5"; fi

fb_run recover FB_PROVISION_RC=74
fb_run recover FB_PROVISION_RC=0
DESC="a later run that finds the models (provision.sh exit 0) completes: marker written, attempt counter and status file removed"
if [ "$FB_RC" = 0 ] && [ -f "$FB_DIR/state/.first-boot-setup-done" ] && [ ! -e "$FB_DIR/state/first-boot-setup-attempts" ] && [ ! -e "$FB_DIR/state/first-boot-setup-status" ]; then verdict 0; else verdict 1; sed 's/^/      /' "$FB_DIR/out"; fi
fb_run failstatus FB_PROVISION_RC=1
DESC="an ordinary failure writes a 'failed' status line (and no marker)"
if grep -q '^failed (status 1)' "$FB_DIR/state/first-boot-setup-status" && [ ! -e "$FB_DIR/state/.first-boot-setup-done" ]; then verdict 0; else verdict 1; fi

fb_run nouser FB_PROVISION_RC=75
DESC="provision.sh exit 75 (no desktop account yet): the attempt is given back, no marker, exit 0"
if [ "$FB_RC" = 0 ] && [ ! -e "$FB_DIR/state/.first-boot-setup-done" ] && [ "$(cat "$FB_DIR/state/first-boot-setup-attempts")" = 0 ]; then verdict 0; else verdict 1; fi

fb_run missing
rm -f "$FB_DIR/boot/backends/cachyos/provision/provision.sh"
env -i PATH="$W/bin:/usr/bin:/bin" CI_OS_BOOTSTRAP_ROOT="$FB_DIR/boot" CI_OS_STATE_DIR="$FB_DIR/state2" CI_OS_LOG_FILE="$FB_DIR/fb2.log" CI_OS_LOCK_FILE="$FB_DIR/lock2" \
  CI_OS_CMDLINE_FILE="$FB_DIR/cmdline" CI_OS_RUN_ARCHISO="$FB_DIR/no-archiso" CI_OS_NETWORK_PROBE="$W/fb/net-up" CI_OS_NETWORK_TRIES=1 CI_OS_NETWORK_SLEEP=0 bash "$FB" > "$FB_DIR/out5" 2>&1; fb_settle "$FB_DIR"
DESC="a missing provisioner (a broken image) writes a marker and stops: retrying cannot help"
if [ -f "$FB_DIR/state2/.first-boot-setup-done" ] && grep -q 'no provisioner' "$FB_DIR/state2/.first-boot-setup-done"; then verdict 0; else verdict 1; fi

DESC="ci-os-setup refuses to run as a normal user"
if [ "$(id -u)" = 0 ]; then t_skip "$DESC (tests run as root)"
elif bash "$PROV/ci-os-setup.sh" >/dev/null 2>&1; then verdict 1
else verdict 0; fi

# =============================================================================================================================
echo "== F  provision.sh wrapper"
PW="$PROV/provision.sh"
mkdir -p "$W/pw/home/alice" "$W/pw/home/bob" "$W/pw/home/ci"
cat > "$W/pw/arch-provision.sh" <<'EOF'
#!/bin/bash
echo "arch-provision SUDO_USER=${SUDO_USER:-} args=$*" >> "$PW_LOG"
exit "${PW_ARCH_RC:-0}"
EOF
# The stand-in for the ollama CLI (F6). By default it reports all the models the manifest requires, so the tests of the other
# behaviours of the wrapper run in a realistic setting; the model tests below change what it reports.
mkdir -p "$W/pw/bin"
cat > "$W/pw/bin/ollama" <<'EOF'
#!/bin/bash
# stand-in for the CLI: `ollama list` prints the models in $PW_OLLAMA_MODELS under the real header; it fails (server not up) for the
# first $PW_OLLAMA_FAIL_FIRST calls, and always when PW_OLLAMA_DEAD is set.
[ "$1" = list ] || exit 2
n=0; [ -f "$PW_OLLAMA_COUNT" ] && n="$(cat "$PW_OLLAMA_COUNT")"; n=$((n + 1)); echo "$n" > "$PW_OLLAMA_COUNT"
[ -z "${PW_OLLAMA_DEAD:-}" ] || exit 1
[ "$n" -gt "${PW_OLLAMA_FAIL_FIRST:-0}" ] || exit 1
echo "NAME                      ID              SIZE      MODIFIED"
for m in $PW_OLLAMA_MODELS; do echo "$m  0123456789ab  1.0 GB  2 minutes ago"; done
EOF
chmod +x "$W/pw/bin/ollama"
MANIFEST_MODELS="nomic-embed-text:latest gemma3:1b qwen3.6:27b"   # ecosystem.yaml llm.models: [nomic-embed-text, "gemma3:1b", "qwen3.6:27b"]
cat > "$W/pw/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:Kernel Overflow User:/:/usr/bin/nologin
liveuser:x:1000:1000::$W/pw/home/liveuser:/bin/bash
ci:x:1001:1001::$W/pw/home/ci:/bin/bash
svc:x:1002:1002::$W/pw/home/svc:/usr/bin/nologin
ghost:x:1003:1003::$W/pw/home/ghost:/bin/bash
alice:x:1004:1004::$W/pw/home/alice:/bin/bash
bob:x:1005:1005::$W/pw/home/bob:/bin/bash
EOF
pw_run() { : > "$W/pw/log"; env -i PATH="${PW_PATH:-$W/pw/bin:/usr/bin:/bin}" PW_OLLAMA_MODELS="$MANIFEST_MODELS" PW_OLLAMA_COUNT="$W/pw/ollama-count" PW_LOG="$W/pw/log" CI_OS_PASSWD_FILE="${PW_PASSWD:-$W/pw/passwd}" CI_OS_ARCH_PROVISION="${PW_ARCH:-$W/pw/arch-provision.sh}" "$@" > "$W/pw/out" 2>&1 && PW_RC=0 || PW_RC=$?; }
pw_run bash "$PW"
DESC="no SUDO_USER: the first real desktop account (not root, liveuser, ci, nobody, a nologin shell or a missing home) is chosen: alice"
if [ "$PW_RC" = 0 ] && grep -q 'SUDO_USER=alice' "$W/pw/log"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/pw/out"; fi
pw_run bash "$PW"
DESC="the default tier is core (NOT the Arch script's core,hardware, which installs ROCm and LACT on any GPU)"
if grep -q 'args=--tier=core$' "$W/pw/log"; then verdict 0; else verdict 1; cat "$W/pw/log" | sed 's/^/      /'; fi
pw_run bash "$PW" --tier=core,extended
DESC="an explicit --tier is passed through unchanged"
if grep -q 'args=--tier=core,extended$' "$W/pw/log"; then verdict 0; else verdict 1; fi
pw_run bash "$PW" --step=ci-hub
DESC="--step=ci-hub is passed through without a tier being added"
if grep -q 'args=--step=ci-hub$' "$W/pw/log"; then verdict 0; else verdict 1; fi
pw_run env SUDO_USER=bob bash "$PW"
DESC="an existing SUDO_USER is respected (a person ran sudo)"
if grep -q 'SUDO_USER=bob' "$W/pw/log"; then verdict 0; else verdict 1; fi
grep -v '^alice\|^bob' "$W/pw/passwd" > "$W/pw/passwd-nouser"
PW_PASSWD="$W/pw/passwd-nouser" pw_run bash "$PW"
DESC="no desktop account yet: exit 75 and root is NOT provisioned"
if [ "$PW_RC" = 75 ] && [ ! -s "$W/pw/log" ]; then verdict 0; else verdict 1; fi
DESC="the wrapper runs the Arch provisioner as a child, not with exec (it has to look at the result), and installs nothing itself (no pacman call)"
if ! grep -v '^[[:space:]]*#' "$PW" | grep -q 'exec bash' && grep -q 'bash "\$ARCH_PROVISION" "\$@" || rc=' "$PW" && ! grep -v '^[[:space:]]*#' "$PW" | grep -q 'pacman'; then verdict 0; else verdict 1; fi
pw_run env SUDO_USER=bob PW_ARCH_RC=3 bash "$PW" --tier=core,hardware
DESC="the Arch provisioner's own failure status is passed through unchanged (3), and no model check is attempted"
if [ "$PW_RC" = 3 ] && ! grep -q 'Ollama' "$W/pw/out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/pw/out"; fi

# --- the Ollama models (F6): the stub ollama and MANIFEST_MODELS are defined above, next to pw_run ---
pw_models() {  # [VAR=value ...] bash PW [args]: the wrapper with the stub ollama on the PATH and a fresh call counter
  rm -f "$W/pw/ollama-count"
  # The hardware-fit gate (core/lib/gpu-detect.sh) would answer for THIS machine; the checks below are about the wrapper's own logic, so
  # the gate is forced open here (a later VAR=value in "$@" overrides it, see the gate test below).
  PW_PATH="$W/pw/bin:/usr/bin:/bin" pw_run env SUDO_USER=bob PW_OLLAMA_COUNT="$W/pw/ollama-count" CI_OS_OLLAMA_TRIES=4 CI_OS_OLLAMA_SLEEP=0 CI_OS_MODEL_FIT_OVERRIDE=allow "$@"
}
DESC="the manifest the wrapper reads says what this test assumes (llm.models: nomic-embed-text, gemma3:1b, qwen3.6:27b)"
if [ "$(awk '/^llm:/ { f = 1; next } f && /models:/ { print; exit }' "$REPO_ROOT/core/manifest/ecosystem.yaml" | tr -d ' ')" = 'models:[nomic-embed-text,"gemma3:1b","qwen3.6:27b"]' ]; then verdict 0; else verdict 1; fi

pw_models PW_OLLAMA_MODELS="$MANIFEST_MODELS" bash "$PW"
DESC="all required models installed (a tag-less manifest name matches ':latest'): exit 0 after the Arch provisioner's own 0"
if [ "$PW_RC" = 0 ] && grep -q 'Ollama models present' "$W/pw/out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/pw/out"; fi
pw_models PW_OLLAMA_MODELS="nomic-embed-text:latest gemma3:1b" bash "$PW"
DESC="a required model missing (qwen3.6:27b: the pull failed or did not finish) although the Arch provisioner exited 0: exit 74, the missing model is named"
if [ "$PW_RC" = 74 ] && grep -q 'missing after provisioning: qwen3.6:27b' "$W/pw/out" && ! grep -q 'missing after provisioning:.*nomic-embed-text' "$W/pw/out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/pw/out"; fi
pw_models PW_OLLAMA_MODELS="gemma3:1b qwen3.6:27b" bash "$PW"
DESC="an EARLIER model missing (nomic-embed-text) is caught too: the Arch script's own warning only ever saw the last pull's status"
if [ "$PW_RC" = 74 ] && grep -q 'missing after provisioning: nomic-embed-text' "$W/pw/out"; then verdict 0; else verdict 1; fi
pw_models PW_OLLAMA_MODELS="nomic-embed-text:latest gemma3:1b-it-qat qwen3.6:27b" bash "$PW"
DESC="a different tag of the same model does not count (gemma3:1b-it-qat is not gemma3:1b)"
if [ "$PW_RC" = 74 ] && grep -q 'missing after provisioning: gemma3:1b' "$W/pw/out"; then verdict 0; else verdict 1; fi
pw_models PW_OLLAMA_MODELS="" bash "$PW"
DESC="an empty model list (a fresh server) is an answer, not a failure to answer: one call, all three reported missing, exit 74"
if [ "$PW_RC" = 74 ] && [ "$(cat "$W/pw/ollama-count")" = 1 ]; then verdict 0; else verdict 1; fi

pw_models CI_OS_MODEL_FIT_OVERRIDE=deny PW_OLLAMA_MODELS="" bash "$PW"
DESC="the hardware-fit gate: models this machine cannot hold are skipped on purpose and are NOT reported missing (no endless 'degraded'), exit 0"
if [ "$PW_RC" = 0 ] && grep -q 'skipped on purpose' "$W/pw/out" && ! grep -q 'missing after provisioning' "$W/pw/out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/pw/out"; fi

pw_models PW_OLLAMA_MODELS="$MANIFEST_MODELS" PW_OLLAMA_FAIL_FIRST=3 bash "$PW"
DESC="the Ollama server is not up yet: the check polls (3 failed answers, then the list) instead of a fixed pause, and passes"
if [ "$PW_RC" = 0 ] && [ "$(cat "$W/pw/ollama-count")" = 4 ]; then verdict 0; else verdict 1; sed 's/^/      /' "$W/pw/out"; fi
pw_models PW_OLLAMA_MODELS="$MANIFEST_MODELS" PW_OLLAMA_DEAD=1 bash "$PW"
DESC="a server that never answers: after the bounded number of tries (4) the models are treated as missing, exit 74"
if [ "$PW_RC" = 74 ] && [ "$(cat "$W/pw/ollama-count")" = 4 ] && grep -q 'did not answer after 4 tries' "$W/pw/out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/pw/out"; fi
PW_PATH="/usr/bin:/bin" pw_run env SUDO_USER=bob CI_OS_OLLAMA_TRIES=2 CI_OS_OLLAMA_SLEEP=0 bash "$PW"
DESC="no ollama command at all (its install failed): exit 74"
if [ "$PW_RC" = 74 ] && grep -q 'Ollama is not installed' "$W/pw/out"; then verdict 0; else verdict 1; fi

PW_PATH="/usr/bin:/bin" pw_run env SUDO_USER=bob bash "$PW" --tier=hardware
DESC="a run without the core tier (nothing pulls models) makes no model check, even with no ollama installed"
if [ "$PW_RC" = 0 ] && ! grep -q 'Ollama' "$W/pw/out"; then verdict 0; else verdict 1; fi
PW_PATH="/usr/bin:/bin" pw_run env SUDO_USER=bob bash "$PW" --step=ci-hub
DESC="--step=ci-hub (only the Hub deploy) makes no model check either"
if [ "$PW_RC" = 0 ] && ! grep -q 'Ollama' "$W/pw/out"; then verdict 0; else verdict 1; fi
PW_PATH="/usr/bin:/bin" pw_run env SUDO_USER=bob CI_OS_OLLAMA_TRIES=1 CI_OS_OLLAMA_SLEEP=0 bash "$PW" --light
DESC="--light means the core tier (as for the Arch script): the check runs"
if [ "$PW_RC" = 74 ]; then verdict 0; else verdict 1; fi
PW_PATH="/usr/bin:/bin" pw_run env SUDO_USER=bob CI_OS_OLLAMA_TRIES=1 CI_OS_OLLAMA_SLEEP=0 bash "$PW" --tier=core,hardware --tier=hardware
DESC="the last --tier= wins, as in the Arch script: core,hardware then hardware = no check"
if [ "$PW_RC" = 0 ]; then verdict 0; else verdict 1; fi

printf '%s\n' 'llm:' '  provider: ollama' '  models:' '    - "tiny:1b"      # a block list, with a comment' '    - other' 'ecosystem:' '  models: [not-this-one]' > "$W/pw/manifest-block.yaml"
pw_models PW_OLLAMA_MODELS="tiny:1b other:latest" CI_OS_ECOSYSTEM_MANIFEST="$W/pw/manifest-block.yaml" bash "$PW"
DESC="the manifest reader also takes a block list under llm.models, and ignores a 'models:' outside the llm block"
if [ "$PW_RC" = 0 ] && ! grep -q 'not-this-one' "$W/pw/out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/pw/out"; fi
printf '%s\n' 'llm:' '  provider: ollama' > "$W/pw/manifest-none.yaml"
pw_models PW_OLLAMA_MODELS="$MANIFEST_MODELS" CI_OS_ECOSYSTEM_MANIFEST="$W/pw/manifest-none.yaml" bash "$PW"
DESC="a manifest with no llm.models is an error (exit 1), never 'nothing required, all good'"
if [ "$PW_RC" = 1 ] && grep -q 'no llm.models' "$W/pw/out"; then verdict 0; else verdict 1; fi

# The installed layout: the wrapper in /usr/lib/ci-os/bootstrap/backends/cachyos/provision finds core/manifest/ecosystem.yaml next to it.
TF="$W/target-f"; new_target "$TF"
FAKE_CARRY_LOG="$W/carry.log" CI_OS_OVERLAY_DIR="$OV" CI_OS_CARRY_OVER="$W/fakecarry/carry-over" bash "$STG" "$TF" > "$W/f-stage.out" 2>&1 || true
printf '%s\n' '#!/bin/bash' 'echo "arch-provision args=$*" >> "$PW_LOG"' > "$W/pw/arch-installed.sh"
PW_ARCH="$W/pw/arch-installed.sh" PW_PATH="$W/pw/bin:/usr/bin:/bin" pw_run env SUDO_USER=bob PW_OLLAMA_COUNT="$W/pw/ollama-count2" PW_OLLAMA_MODELS="nomic-embed-text:latest gemma3:1b" CI_OS_OLLAMA_SLEEP=0 \
  bash "$TF/usr/lib/ci-os/bootstrap/backends/cachyos/provision/provision.sh"
DESC="from the installed bootstrap tree the wrapper finds the staged manifest on its own and reports the missing model (exit 74)"
if [ "$PW_RC" = 74 ] && grep -q 'qwen3.6:27b' "$W/pw/out"; then verdict 0; else verdict 1; sed 's/^/      /' "$W/pw/out"; fi

echo
printf '== %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
