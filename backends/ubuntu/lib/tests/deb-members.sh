#!/usr/bin/env bash
#=============================================================================
# Test: deb_members (backends/ubuntu/lib/deb-members.sh) gives the same names for a .deb that stores "./usr/bin/x" and one that
# stores "usr/bin/x", and the checks of customize-chroot.sh Step 10e work on both
#
# Found by a real image build (2026-10-19): the Companion Capture .deb stores its names WITHOUT a leading "./" (the Launcher's
# stores them with it). Step 10e's first version looked for "./usr/bin/companion-capture", so the build stopped with "Capture
# .deb has no /usr/bin/companion-capture", and the refusal check ("nothing under /etc or systemd") would have matched nothing
# and passed silently on a package that did ship an autostart. The script-reading tests of customize-chroot-checks.sh could not
# see that; this one builds real packages, in both styles, and runs the same patterns.
#
# Needs dpkg-deb, ar, tar and gzip (an Ubuntu or Debian host, or a container: `docker run --rm -v "$PWD":/r:ro ubuntu:26.04 bash -c
# 'apt-get update -qq && apt-get install -y -qq binutils && bash /r/backends/ubuntu/lib/tests/deb-members.sh'`). Exit 2 ("cannot
# run here") where they are missing, as on a Mac. No network, no root, writes only to a temporary directory.
#   backends/ubuntu/lib/tests/deb-members.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../deb-members.sh"
CHROOT_SCRIPT="$HERE/../../chroot/customize-chroot.sh"
[[ -f "$LIB" && -f "$CHROOT_SCRIPT" ]] || { echo "missing $LIB or $CHROOT_SCRIPT" >&2; exit 2; }
for t in dpkg-deb ar tar gzip; do
  command -v "$t" >/dev/null 2>&1 || { echo "cannot run here: $t is missing" >&2; exit 2; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deb-members.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=../deb-members.sh
source "$LIB"
set +e +u

# make_deb NAME STYLE FILE...: a package with the given files (each "path" or "path->target" for a symlink), stored
# with ("dot": dpkg-deb's own way) or without ("plain") a leading "./".
make_deb() {
  local name="$1" style="$2"; shift 2
  local tree="$TMP/$name-tree" f path target
  rm -rf "$tree"; mkdir -p "$tree/DEBIAN"
  printf 'Package: %s\nVersion: 1\nArchitecture: amd64\nMaintainer: test <t@example.com>\nDescription: test package\n' "$name" >"$tree/DEBIAN/control"
  for f in "$@"; do
    path="${f%%->*}"; target=""; [[ "$f" == *"->"* ]] && target="${f#*->}"
    mkdir -p "$tree/$(dirname "$path")"
    if [[ -n "$target" ]]; then ln -s "$target" "$tree/$path"; else printf 'x\n' >"$tree/$path"; fi
  done
  dpkg-deb --root-owner-group --build "$tree" "$TMP/$name-dot.deb" >/dev/null 2>&1 || return 1
  if [[ "$style" == plain ]]; then
    local w="$TMP/$name-repack"; rm -rf "$w"; mkdir -p "$w/data" "$w/ar"
    ( cd "$w/ar" && ar x "$TMP/$name-dot.deb" )
    dpkg-deb -x "$TMP/$name-dot.deb" "$w/data"
    ( cd "$w/data" && tar -cf "$w/ar/data.tar" -- * && gzip -f "$w/ar/data.tar" )
    rm -f "$w"/ar/data.tar.xz "$w"/ar/data.tar.zst "$w"/ar/data.tar.gz.orig
    ( cd "$w/ar" && rm -f "$TMP/$name-plain.deb" && ar rc "$TMP/$name-plain.deb" debian-binary control.tar.* data.tar.gz )
    echo "$TMP/$name-plain.deb"
  else
    echo "$TMP/$name-dot.deb"
  fi
}

echo "== names come out the same in both styles"
for style in dot plain; do
  deb="$(make_deb "good-$style" "$style" usr/bin/companion-capture usr/share/applications/companion-capture.desktop usr/share/icons/x.png)"
  raw="$(dpkg-deb -c "$deb" | awk '{print $NF}' | grep -c '^\./')"
  if [[ "$style" == dot ]]; then
    [[ "$raw" -gt 0 ]] && pass "[$style] the raw listing does carry ./ (so this case tests what it claims)" || fail "[$style] the raw listing has no ./"
  else
    eq "[$style] the raw listing carries no ./ (so this case tests what it claims)" "$raw" "0"
  fi
  names="$(deb_members "$deb")"
  if grep -qx 'usr/bin/companion-capture' <<<"$names"; then pass "[$style] usr/bin/companion-capture is found as written in Step 10e"; else fail "[$style] usr/bin/companion-capture not found: $(tr '\n' ' ' <<<"$names")"; fi
  if grep -qx 'usr/share/applications/companion-capture.desktop' <<<"$names"; then pass "[$style] the desktop file is found"; else fail "[$style] the desktop file is not found"; fi
  eq "[$style] no name starts with ./" "$(grep -c '^\./' <<<"$names" | tr -d ' ')" "0"
done

echo
echo "== the refusal pattern of Step 10e catches both styles"
for style in dot plain; do
  for bad in etc/xdg/autostart/companion-capture.desktop usr/lib/systemd/system/companion-capture.service lib/systemd/system/x.service etc/sudoers.d/x; do
    deb="$(make_deb "bad-$style" "$style" usr/bin/companion-capture "$bad")"
    if deb_members "$deb" | grep -E '^(etc/|lib/systemd|usr/lib/systemd)' | grep -q .; then pass "[$style] refused: $bad"; else fail "[$style] NOT refused: $bad"; fi
  done
  deb="$(make_deb "ok-$style" "$style" usr/bin/companion-capture usr/share/applications/companion-capture.desktop usr/share/etcetera/x usr/lib/companion/x)"
  if deb_members "$deb" | grep -E '^(etc/|lib/systemd|usr/lib/systemd)' | grep -q .; then fail "[$style] a clean package was refused"; else pass "[$style] a clean package (usr/share/etcetera, usr/lib/companion) is not refused"; fi
done

echo
echo "== details"
deb="$(make_deb "link-dot" dot usr/bin/real "usr/bin/alias->real")"
eq "a symlink member is listed by its own name, without ' -> target'" "$(deb_members "$deb" | grep -c -x 'usr/bin/alias')" "1"
eq "  and no member keeps an arrow" "$(deb_members "$deb" | grep -c -e '->' | tr -d ' ')" "0"
printf 'not a deb\n' >"$TMP/junk.deb"
deb_members "$TMP/junk.deb" >/dev/null 2>&1; rc=$?
eq "a file that is not a .deb fails (status 1) and prints nothing" "$rc/$(deb_members "$TMP/junk.deb" 2>/dev/null | wc -c | tr -d ' ')" "1/0"

echo
echo "== customize-chroot.sh uses exactly these patterns"
for lit in 'deb_members "$TB_CAPTURE_DEB" > "$TB_WORK/capture.members"' \
           'grep -qx "usr/bin/$CAPTURE_BINARY" "$TB_WORK/capture.members"' \
           "grep -qx 'usr/share/applications/companion-capture.desktop' \"\$TB_WORK/capture.members\"" \
           "grep -E '^(etc/|lib/systemd|usr/lib/systemd)' \"\$TB_WORK/capture.members\""; do
  if grep -q -F -- "$lit" "$CHROOT_SCRIPT"; then pass "Step 10e has: ${lit:0:70}"; else fail "Step 10e lacks: $lit"; fi
done
eq "Step 10e no longer looks for a name with a leading ./ in the Capture members" "$(grep -c -F './usr/bin/$CAPTURE_BINARY' "$CHROOT_SCRIPT" | tr -d ' ')" "0"

echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
