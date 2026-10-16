#!/usr/bin/env bash
#=============================================================================
# Check the Companion OS identity and desktop defaults of a root file system: the mkarchiso work tree
# (<work>/x86_64/airootfs), an unpacked airootfs.sfs, or a mounted installed target. It reads files only.
#
#   backends/cachyos/iso/tests/overlay-image-check.sh [--live] <root>
#
#   --live   also check what only the live medium has: hostname, motd, issue, the masked sshd, the sshd drop-in
#
# The identity checks are the decision D4 of the edition: /etc/os-release says Companion OS and is a REGULAR file
# (not Arch's symlink), keeps ID=cachyos and exactly ID_LIKE=arch, and cachyos-hooks' rewrite did not win. The
# desktop checks read /etc/skel the way zz-ci-os-skel leaves it. A path that does not exist is reported as FAIL for the
# identity files and as SKIP for the desktop ones that only exist when cachyos-kde-settings is installed.
#
# Exit status: 0 all checks passed (skips allowed), 1 a check failed, 2 usage.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

LIVE=0
if [[ "${1:-}" == --live ]]; then LIVE=1; shift; fi
ROOT="${1:-}"
[[ -n "$ROOT" && -d "$ROOT" ]] || { echo "usage: overlay-image-check.sh [--live] <root-directory>" >&2; exit 2; }
ROOT="${ROOT%/}"

PASS=0; FAIL=0; SKIP=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }

# value <file> <KEY>: the value of KEY= in an os-release style file, quotes removed ("" when absent)
value() { sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$1" | head -n 1; }

echo "== identity ($ROOT)"
OSR="$ROOT/etc/os-release"
if [[ ! -e "$OSR" && ! -L "$OSR" ]]; then
  t_fail "/etc/os-release does not exist"
else
  if [[ -L "$OSR" ]]; then t_fail "/etc/os-release is a symlink (to $(readlink "$OSR")): the hook writes a regular file"; else t_pass "/etc/os-release is a regular file"; fi
  [[ "$(value "$OSR" NAME)" == "Companion OS" ]] && t_pass "NAME=\"Companion OS\"" || t_fail "NAME is '$(value "$OSR" NAME)', expected Companion OS"
  case "$(value "$OSR" PRETTY_NAME)" in
    "Companion OS"|"Companion OS "[0-9A-Za-z]*) t_pass "PRETTY_NAME=\"$(value "$OSR" PRETTY_NAME)\"" ;;
    *) t_fail "PRETTY_NAME is '$(value "$OSR" PRETTY_NAME)', expected Companion OS [version]" ;;
  esac
  [[ "$(value "$OSR" ID)" == "cachyos" ]] && t_pass "ID=cachyos (the base's machine identity)" || t_fail "ID is '$(value "$OSR" ID)', expected cachyos"
  [[ "$(grep -c '^ID_LIKE=' "$OSR" || true)" == 1 && "$(grep '^ID_LIKE=' "$OSR")" == "ID_LIKE=arch" ]] \
    && t_pass "ID_LIKE=arch (one token; CI-Hub string-compares it)" || t_fail "ID_LIKE is not exactly 'ID_LIKE=arch' once: $(grep '^ID_LIKE' "$OSR" || echo absent)"
  [[ "$(value "$OSR" LOGO)" == "ci-os-logo" ]] && t_pass "LOGO=ci-os-logo" || t_fail "LOGO is '$(value "$OSR" LOGO)'"
  [[ "$(value "$OSR" HOME_URL)" == "https://ci.computer" ]] && t_pass "HOME_URL=https://ci.computer" || t_fail "HOME_URL is '$(value "$OSR" HOME_URL)'"
  [[ "$(value "$OSR" CI_OS_ID)" == "ci-os" ]] && t_pass "CI_OS_ID=ci-os" || t_fail "CI_OS_ID is '$(value "$OSR" CI_OS_ID)'"
  case "$(value "$OSR" VARIANT)" in *"based on CachyOS"*) t_pass "VARIANT says it is based on CachyOS" ;; *) t_fail "VARIANT is '$(value "$OSR" VARIANT)'" ;; esac
  ac="$(value "$OSR" ANSI_COLOR)"
  if [[ "$ac" =~ ^38\;2\;[0-9]{1,3}\;[0-9]{1,3}\;[0-9]{1,3}$ && "$ac" != "38;2;23;147;209" ]]; then t_pass "ANSI_COLOR=\"$ac\" (not CachyOS's blue)"; else t_fail "ANSI_COLOR is '$ac' (absent, malformed or CachyOS's own)"; fi
  # Everything a human reads must be ours: no CachyOS or Arch brand in these keys.
  leaks="$(grep -E '^(NAME|PRETTY_NAME|HOME_URL|DOCUMENTATION_URL|SUPPORT_URL|BUG_REPORT_URL|PRIVACY_POLICY_URL|LOGO)=' "$OSR" | grep -iE 'cachy|arch ?linux|archlinux' || true)"
  [[ -z "$leaks" ]] && t_pass "no CachyOS or Arch string in the name, URL and logo keys" || t_fail "brand leak in os-release: $leaks"
  if [[ -r "$ROOT/usr/share/ci-os/release" ]]; then
    v="$(value "$ROOT/usr/share/ci-os/release" CI_OS_VERSION)"
    [[ -n "$v" && "$(value "$OSR" CI_OS_VERSION)" == "$v" ]] && t_pass "CI_OS_VERSION=$v matches /usr/share/ci-os/release" || t_fail "CI_OS_VERSION '$(value "$OSR" CI_OS_VERSION)' differs from the release stamp '$v'"
    [[ "$(value "$OSR" PRETTY_NAME)" == "Companion OS $v" ]] && t_pass "PRETTY_NAME carries the version" || t_fail "PRETTY_NAME '$(value "$OSR" PRETTY_NAME)' does not carry version $v"
  else
    t_fail "/usr/share/ci-os/release is missing: render-assets.sh did not run, or its staging tree was not merged"
  fi
fi
LSB="$ROOT/etc/lsb-release"
if [[ -r "$LSB" ]]; then
  case "$(value "$LSB" DISTRIB_DESCRIPTION)" in "Companion OS"*) t_pass "lsb-release DISTRIB_DESCRIPTION is Companion OS" ;; *) t_fail "lsb-release DISTRIB_DESCRIPTION is '$(value "$LSB" DISTRIB_DESCRIPTION)'" ;; esac
  [[ "$(value "$LSB" DISTRIB_ID)" == "cachyos" ]] && t_pass "lsb-release DISTRIB_ID=cachyos" || t_fail "lsb-release DISTRIB_ID is '$(value "$LSB" DISTRIB_ID)'"
else
  t_fail "/etc/lsb-release is missing"
fi
for f in usr/share/libalpm/hooks/zz-ci-os-os-release.hook usr/share/libalpm/scripts/zz-ci-os-os-release usr/share/libalpm/hooks/zz-ci-os-skel.hook usr/share/libalpm/scripts/zz-ci-os-skel; do
  [[ -f "$ROOT/$f" ]] && t_pass "/$f present" || t_fail "/$f missing: the identity would revert on the next upgrade"
done

echo "== desktop defaults (/etc/skel)"
SK="$ROOT/etc/skel/.config"
AP="$SK/plasma-org.kde.plasma.desktop-appletsrc"
if [[ -f "$AP" ]]; then
  grep -q '^icon=org\.cachyos\.hello$' "$AP" && t_fail "start button still points at org.cachyos.hello (a package that is not shipped)" || t_pass "start button icon is not org.cachyos.hello"
  grep -qx 'icon=ci-os-logo' "$AP" && t_pass "start button icon=ci-os-logo" || t_fail "no icon=ci-os-logo in $AP"
  grep -qi 'cachyos' "$AP" && t_fail "the panel layout still names CachyOS: $(grep -i cachyos "$AP" | head -n 2 | tr '\n' ' ')" || t_pass "no CachyOS string left in the panel layout"
  desk="$(awk '/^\[Containments\]\[[0-9]+\]$/ { id = $0; sub(/^\[Containments\]\[/, "", id); sub(/\]$/, "", id); cur = id; next } /^\[/ { cur = "" } cur != "" && $0 == "plugin=org.kde.plasma.folder" { print cur; exit }' "$AP")"
  if [[ -n "$desk" ]] && awk -v g="[Containments][$desk][Wallpaper][org.kde.image][General]" '$0 == g { f = 1; next } /^\[/ { f = 0 } f && /^Image=file:\/\/\/usr\/share\/wallpapers\/companion\// { ok = 1 } END { exit !ok }' "$AP"; then
    t_pass "the wallpaper is set on the desktop containment ($desk)"
  else
    t_fail "no Companion OS wallpaper under the desktop containment (id '${desk:-none}')"
  fi
else
  t_skip "no $AP (cachyos-kde-settings not installed in this root)"
fi
KG="$SK/kdeglobals"
if [[ -f "$KG" ]]; then
  [[ "$(value "$KG" ColorScheme)" == "CI-OS-Dark" ]] && t_pass "kdeglobals ColorScheme=CI-OS-Dark" || t_fail "kdeglobals ColorScheme is '$(value "$KG" ColorScheme)'"
  grep -q '^\[Colors:Window\]$' "$KG" && grep -q '^\[Colors:Button\]$' "$KG" && t_pass "kdeglobals carries the scheme's colours" || t_fail "kdeglobals has no [Colors:*] groups: the scheme name alone changes nothing"
else
  t_skip "no $KG"
fi
if [[ -f "$SK/ksplashrc" ]]; then
  grep -qx 'Theme=None' "$SK/ksplashrc" && t_pass "ksplashrc: no splash screen" || t_fail "ksplashrc does not say Theme=None"
else
  t_skip "no ksplashrc"
fi
if [[ -f "$SK/kscreenlockerrc" ]]; then
  grep -q '^Image=file:///usr/share/wallpapers/companion/' "$SK/kscreenlockerrc" && t_pass "kscreenlockerrc: Companion OS lock-screen wallpaper" || t_fail "kscreenlockerrc has no Companion OS wallpaper"
else
  t_skip "no kscreenlockerrc"
fi

if [[ "$LIVE" -eq 1 ]]; then
  echo "== live medium"
  [[ "$(cat "$ROOT/etc/hostname" 2>/dev/null || true)" == "companion-os" ]] && t_pass "hostname companion-os" || t_fail "hostname is '$(cat "$ROOT/etc/hostname" 2>/dev/null || echo absent)'"
  [[ -f "$ROOT/etc/motd" ]] && ! grep -qiE 'cachy|arch ?linux' "$ROOT/etc/motd" && grep -q 'Companion OS' "$ROOT/etc/motd" && t_pass "motd says Companion OS and names no other distribution" || t_fail "motd missing, or names CachyOS/Arch, or does not say Companion OS"
  [[ -f "$ROOT/etc/issue" ]] && ! grep -qiE 'cachy|arch ?linux' "$ROOT/etc/issue" && t_pass "issue names no other distribution" || t_fail "issue missing or names CachyOS/Arch"
  for u in sshd.service sshd.socket; do
    [[ -L "$ROOT/etc/systemd/system/$u" && "$(readlink "$ROOT/etc/systemd/system/$u")" == /dev/null ]] && t_pass "$u is masked" || t_fail "$u is not masked (/etc/systemd/system/$u -> /dev/null)"
  done
  grep -qx 'PermitRootLogin no' "$ROOT/etc/ssh/sshd_config.d/10-archiso.conf" 2>/dev/null && t_pass "sshd drop-in forbids root login" || t_fail "sshd drop-in still allows root login"
  if [[ -f "$ROOT/etc/cachyos-release" ]]; then
    case "$(value "$ROOT/etc/cachyos-release" DISTRIB_DESCRIPTION)" in
      "Companion OS"*) t_pass "/etc/cachyos-release describes Companion OS" ;;
      *) t_fail "/etc/cachyos-release DISTRIB_DESCRIPTION is '$(value "$ROOT/etc/cachyos-release" DISTRIB_DESCRIPTION)'" ;;
    esac
  else
    t_fail "/etc/cachyos-release is missing (upstream's file would be ours to replace)"
  fi
fi

echo "== Summary: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
