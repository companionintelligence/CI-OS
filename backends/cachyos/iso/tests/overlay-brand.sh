#!/usr/bin/env bash
#=============================================================================
# Test: the Companion OS brand and identity overlay of the CachyOS edition (backends/cachyos/iso/overlay), without a build,
# a container for the main part, or a boot. It is the brand half of what a build has to be sure of before mkarchiso starts:
#
#   A  the overlay itself     no retired product name or block-letter art; every executable has a file_permissions entry;
#                             hook names sort after the CachyOS hooks they must outlast; sshd is masked; profiledef.append.sh
#                             sets the edition identity; carry-over.list names only files the overlay or the renderer provide
#   B  the patches            apply with `git apply -p1` to a pristine copy of upstream's archiso/ directory; change exactly one
#                             linux/initrd/APPEND/KERNEL line (patch 0002 points the BIOS Memtest entry at the path mkarchiso
#                             installs it under) and no other; leave no CachyOS word outside those lines; keep every `default=` id
#                             and the syslinux DEFAULT label pointing at an entry that exists. The assertion that bounds the
#                             kernel-line change is itself tested on fixtures (B0), which needs no upstream checkout
#   C  the scripts            zz-ci-os-os-release and zz-ci-os-skel on fixture roots: the golden os-release, idempotence, a
#                             symlinked os-release, hostile release stamps, a skel without the expected groups; carry-over
#                             onto a fixture target; the finished fixture image passes overlay-image-check.sh
#   D  render-assets.sh       runs; every output has the right size and type, is non-empty and deterministic; the menu colours
#                             equal what core/lib/theme-lib.sh and grub-merge.sh derive from the tokens; the pixels are the
#                             canon ground
#   E  NOTICE                 every path NOTICE names exists; no file it lists as GPL-derived or as original carries a licence
#                             line that contradicts the list; the CC0 headers it states are the ones the files have; every file
#                             with an SPDX line is listed
#   F  the documents          they do not repeat claims the tree has made false (the default of the build date, the Memtest
#                             path, the installer overlay's staging, the VM generator, the live package list, "every endpoint"),
#                             and every host our scripts and configs name is in the endpoint table or on the list of
#                             references that nothing contacts
#
#   backends/cachyos/iso/tests/overlay-brand.sh
#
# Environment (all optional)
#   CACHYOS_UPSTREAM_ARCHISO   the archiso/ directory of a CachyOS-Live-ISO checkout at the pinned commit (part B; without it
#                              B is skipped, unless CACHYOS_TEST_FETCH=1, which fetches the pinned commit from GitHub)
#   CACHYOS_SKEL_SRC           the etc/skel directory of a cachyos-kde-settings checkout: part C also runs on the real files
#   CI_OS_TEST_STAGING_FULL    a staging tree rendered WITH the installed-system parts (GRUB and Plymouth themes), e.g. by
#                              the builder container: part D checks those too
#   CI_OS_TEST_DOCKER=1        render the full staging tree in a throw-away container (needs docker; CI_OS_TEST_IMAGE, default
#                              ci-cachyos-builder:latest, an archlinux image with pacman)
#   CI_OS_PREVIEW_DIR          write small PNGs of the rendered backgrounds and wallpaper there, for a human to look at
#   CACHYOS_NOTICE            a NOTICE file to check in part E instead of backends/cachyos/NOTICE (to try a mutation of it)
#
# Needs bash 3.2+, git, awk, sed, python3; part D needs ImageMagick (magick or convert) and runs without librsvg only if
# ImageMagick can draw the mark itself. Exit status: non-zero if any check fails; 2 if it cannot run at all.
# Runs on a stock macOS and on the Arch builder; does not touch the repository or upstream's checkout.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS="$(cd "$HERE/../.." && pwd)"
REPO_ROOT="$(cd "$CACHYOS/../.." && pwd)"
OVERLAY="$CACHYOS/iso/overlay"
FILES="$OVERLAY/files/airootfs"
SCRIPTS="$CACHYOS/iso/scripts"
HOOKSCRIPT="$FILES/usr/share/libalpm/scripts/zz-ci-os-os-release"
SKELSCRIPT="$FILES/usr/share/libalpm/scripts/zz-ci-os-skel"
CHECK="$HERE/overlay-image-check.sh"

PASS=0; FAIL=0; SKIP=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
t_skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$*"; }

for t in git awk sed python3 cmp diff; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done
[[ -d "$OVERLAY" ]] || { echo "no overlay at $OVERLAY" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/overlay-brand.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The same words and the same block character that core/lib/check-repo.sh rejects, built from pieces so that this file does
# not contain them itself (check-repo.sh scans backends/ and would flag the test that looks for them).
RETIRED_RE="CI"" OS|CI-OS"" Desktop|CI-OS"" Blue Teal|Companion"" Ubuntu|Intelligence"" Operating System|Companion Intelligence"" OS|Companion Intelligence"" [0-9\$]"
BLOCK_CHAR="$(printf '\342\226\210')"

# lock values
lock_value() { sed -n "s/^$1=//p" "$CACHYOS/upstream.lock" 2>/dev/null | head -n 1; }

# What the canon tokens give for the GRUB menu: the pair the patched grub.cfg falls back to and render-assets.sh writes.
expect="$( ( source "$REPO_ROOT/core/lib/theme-lib.sh" >/dev/null; source "$REPO_ROOT/core/lib/grub-merge.sh"; printf '%s/black black/%s ' "$(ci_grub_nearest_color "$CI_DARK_FOREGROUND")" "$(ci_grub_nearest_color "$CI_ACCENT_AQUA")" ) )"

# The pinned upstream archiso/ directory (parts A and B): given, or fetched from the commit upstream.lock pins.
UP="${CACHYOS_UPSTREAM_ARCHISO:-${UPSTREAM_ARCHISO_DIR:-}}"
if [[ -z "$UP" && "${CACHYOS_TEST_FETCH:-0}" == 1 ]]; then
  repo="$(lock_value UPSTREAM_REPO)"; sha="$(lock_value UPSTREAM_SHA)"
  if [[ -n "$repo" && -n "$sha" ]]; then
    git init -q "$WORK/upstream" && git -C "$WORK/upstream" remote add origin "$repo" \
      && git -C "$WORK/upstream" fetch -q --depth 1 origin "$sha" && git -C "$WORK/upstream" checkout -q --detach FETCH_HEAD \
      && UP="$WORK/upstream/archiso" || t_fail "could not fetch the pinned upstream commit"
  fi
fi

#=== A: the overlay itself ======================================================================================================
echo "== A: the overlay"
retired="$(grep -rInE "$RETIRED_RE" "$OVERLAY" "$SCRIPTS/render-assets.sh" "$HERE"/overlay-* 2>/dev/null || true)"
[[ -z "$retired" ]] && t_pass "no retired product name in the overlay, renderer and tests" || t_fail "retired product name: $retired"
blocks="$(grep -rInF "$BLOCK_CHAR" "$OVERLAY" "$SCRIPTS/render-assets.sh" "$HERE"/overlay-* 2>/dev/null || true)"
[[ -z "$blocks" ]] && t_pass "no block-letter art (U+2588)" || t_fail "block art: $blocks"
# The CachyOS word is allowed only where it is a fact: package and kernel names, the VARIANT text, docs and comments.
# (only the identity files of this overlay: the installer overlay has its own files in etc/, such as pacman hooks that name packages)
leak="$(cd "$FILES" && grep -rIniE 'cachyos' etc/hostname etc/issue etc/motd etc/os-release etc/cachyos-release etc/plasmalogin.conf.d etc/ssh 2>/dev/null | grep -vE 'based on CachyOS|^[^:]*:[0-9]+:[[:space:]]*#' | grep -vE 'ID=cachyos|DISTRIB_ID=cachyos' || true)"
[[ -z "$leak" ]] && t_pass "the CachyOS name appears in the identity files only as ID=, the VARIANT text or a comment" || t_fail "unexpected CachyOS wording: $leak"

# every executable file of the overlay has a file_permissions entry; every entry names a file that exists
profdef="$OVERLAY/profiledef.append.sh"
missing_perm=""; stale_perm=""
perm_sources=("$profdef")
[[ -n "$UP" && -f "$UP/profiledef.sh" ]] && perm_sources+=("$UP/profiledef.sh")
# The installer overlay's files (launcher, /usr/share/ci-os/calamares, desktop entries) are another part's: the engine's
# guard (c) checks them in the build; this test covers the files of the brand and identity overlay.
while IFS= read -r f; do
  img="/${f#"$FILES"/}"
  case "$img" in /usr/share/ci-os/calamares/*|/usr/local/bin/*|/usr/share/applications/*) continue ;; esac
  grep -qF "[\"$img\"]=" "${perm_sources[@]}" || missing_perm="$missing_perm $img"
done < <( { find "$FILES" -type f -perm -100; grep -rIl '^#!' "$FILES" 2>/dev/null; } | LC_ALL=C sort -u )
while IFS= read -r img; do
  [[ -f "$FILES$img" ]] || stale_perm="$stale_perm $img"
done < <(sed -n 's/^[[:space:]]*\["\([^"]*\)"\]=.*/\1/p' "$profdef")
[[ -z "$missing_perm" ]] && t_pass "every executable or #! file of the brand overlay has a file_permissions entry" || t_fail "no file_permissions entry for:$missing_perm"
[[ -z "$stale_perm" ]] && t_pass "every file_permissions entry names a file of the overlay" || t_fail "file_permissions names missing file(s):$stale_perm"
nonexec=""
while IFS= read -r f; do [[ -x "$f" ]] || nonexec="$nonexec $f"; done < <(grep -rIl '^#!' "$FILES" "$SCRIPTS/render-assets.sh" "$HERE"/overlay-* 2>/dev/null)
[[ -z "$nonexec" ]] && t_pass "every #! file is executable in the working tree" || t_fail "not executable:$nonexec"

# hook names: libalpm runs hooks alphabetically by name, suffix ignored; ours must come after the CachyOS ones
for h in "$FILES"/usr/share/libalpm/hooks/*.hook; do
  b="$(basename "$h" .hook)"
  late=1
  for other in cachyos-branding lsb-release os-release; do
    # LC_ALL=C comparison of the names without the suffix
    [[ "$(printf '%s\n%s\n' "$other" "$b" | LC_ALL=C sort | tail -n 1)" == "$b" ]] || late=0
  done
  [[ $late -eq 1 ]] && t_pass "hook $b sorts after cachyos-branding, lsb-release and os-release" || t_fail "hook $b does not sort after the CachyOS hooks"
  grep -q 'remove from airootfs' "$h" && t_fail "hook $b contains the build-only marker 'remove from airootfs' (upstream deletes such hooks)" || true
done
grep -q '^Target = filesystem$' "$FILES/usr/share/libalpm/hooks/zz-ci-os-os-release.hook" \
  && grep -q '^Target = lsb-release$' "$FILES/usr/share/libalpm/hooks/zz-ci-os-os-release.hook" \
  && grep -q '^Target = cachyos-hooks$' "$FILES/usr/share/libalpm/hooks/zz-ci-os-os-release.hook" \
  && t_pass "the identity hook watches filesystem, lsb-release and cachyos-hooks (every CachyOS os-release trigger)" || t_fail "the identity hook does not watch all three CachyOS triggers"
grep -q '^Target = cachyos-kde-settings$' "$FILES/usr/share/libalpm/hooks/zz-ci-os-skel.hook" && t_pass "the skel hook watches cachyos-kde-settings" || t_fail "the skel hook does not watch cachyos-kde-settings"
for u in sshd.service sshd.socket; do
  [[ -L "$FILES/etc/systemd/system/$u" && "$(readlink "$FILES/etc/systemd/system/$u")" == /dev/null ]] && t_pass "$u masked (-> /dev/null)" || t_fail "$u is not a symlink to /dev/null"
done

# profiledef.append.sh: the edition identity, evaluated the way mkarchiso does (needs bash 4 for associative arrays)
if bash -c 'declare -A a' >/dev/null 2>&1; then
  ident="$(SOURCE_DATE_EPOCH=1791041490 bash -c 'declare -A file_permissions; source "$1"; printf "%s|%s|%s|%s" "$iso_name" "$iso_label" "$iso_publisher" "$iso_application"' _ "$profdef" 2>&1 || true)"
  [[ "$ident" == "companion-os-plasma|COMPANION_202610|Companion Intelligence <https://ci.computer>|Companion OS Live/Installer" ]] \
    && t_pass "profiledef.append.sh sets the edition identity (D1): $ident" || t_fail "profiledef.append.sh identity is: $ident"
  grep -qi cachy <<< "$ident" && t_fail "the identity names CachyOS" || t_pass "iso_name, label, publisher and application do not carry the CachyOS mark"
else
  t_skip "profiledef.append.sh evaluation needs bash 4 (this is $(bash --version | head -n 1))"
  grep -q '^iso_name="companion-os-plasma"$' "$profdef" && grep -q '^iso_label="COMPANION_' "$profdef" && t_pass "profiledef.append.sh names companion-os-plasma and a COMPANION_ label (text check)" || t_fail "profiledef.append.sh identity lines missing"
fi

# carry-over.list: each path is a file of the overlay or one the renderer writes
GENERATED="/usr/share/ci-os/release /usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg /etc/xdg/kcm-about-distrorc /usr/share/color-schemes/CI-OS-Dark.colors /usr/share/wallpapers/companion /usr/share/grub/themes/companion-os /usr/share/plymouth/themes/companion-os"
badlist=""
while IFS= read -r p; do
  case "$p" in ''|'#'*) continue ;; esac
  if [[ -e "$FILES$p" || -L "$FILES$p" ]]; then continue; fi
  case " $GENERATED " in *" $p "*) continue ;; esac
  badlist="$badlist $p"
done < "$FILES/usr/share/ci-os/installed/carry-over.list"
[[ -z "$badlist" ]] && t_pass "carry-over.list names only overlay files and what render-assets.sh generates" || t_fail "carry-over.list names unknown path(s):$badlist"
# every generated path of the list must be one the renderer's header documents
for g in $GENERATED; do
  grep -qF "${g#/}" "$SCRIPTS/render-assets.sh" 2>/dev/null || grep -qF "$(basename "$g")" "$SCRIPTS/render-assets.sh" || t_fail "render-assets.sh does not mention $g"
done

# package-owned-ok.txt: every entry has a justification and an absolute path
bad_ok=""
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  p="${line%%|*}"; w="${line#*|}"
  [[ "$p" != "$line" && "$p" == /* && ${#w} -ge 12 ]] || bad_ok="$bad_ok [$line]"
done < "$OVERLAY/package-owned-ok.txt"
[[ -z "$bad_ok" ]] && t_pass "package-owned-ok.txt: every line is '/absolute/path | justification'" || t_fail "package-owned-ok.txt malformed:$bad_ok"

#=== B: the patches ===============================================================================================================
# The kernel, initrd and APPEND lines of the boot menus decide whether the live system finds its medium, so the patches must not
# touch them. The one deliberate exception is patch 0002: upstream's BIOS Memtest entry loads /%INSTALL_DIR%/boot/memtest, but
# mkarchiso installs memtest86+ as /boot/memtest86+/memtest, so the entry never worked. That is a LINUX line, which the engine's
# guard (a) lets through only for a patch that carries `# ci-os: allow-kernel-line-change`, and the marker is a blanket allowance
# for that whole patch. This assertion is what bounds it: the kernel-line set of the patched profile must equal upstream's with
# that one line replaced, byte for byte, and nothing else.
KL_OLD='syslinux/archiso_tail.cfg: LINUX /%INSTALL_DIR%/boot/memtest'
KL_NEW='syslinux/archiso_tail.cfg: LINUX /boot/memtest86+/memtest'
KL_WANT="< $KL_OLD"$'\n'"> $KL_NEW"
kl() { # kernel-ish lines of the boot menus of the profile directory $1, each prefixed with its file
  local d="$1" f
  for f in grub/grub.cfg grub/loopback.cfg; do grep -E '^[[:space:]]*(linux|initrd)[[:space:]]' "$d/$f" | sed "s|^|$f: |" || true; done
  for f in "$d"/syslinux/*.cfg; do grep -iE '^[[:space:]]*(linux|initrd|append|kernel)[[:space:]]' "$f" | sed "s|^|syslinux/$(basename "$f"): |" || true; done
}
kl_diff_check() { # <pristine dir> <patched dir>: 0 when the kernel lines differ by exactly KL_OLD -> KL_NEW, else prints what differs
  local got
  got="$(diff <(kl "$1") <(kl "$2") | grep -E '^[<>]' || true)"
  [[ "$got" == "$KL_WANT" ]] && return 0
  if [[ -z "$got" ]]; then echo "(no kernel line differs from upstream's: the Memtest path fix is missing)"; else printf '%s\n' "$got" | head -n 8; fi
  return 1
}

echo "== B0: the kernel-line assertion, on fixtures"
mkklfix() { # mkklfix <dir>: a miniature of upstream's boot menus (the shape kl() reads)
  mkdir -p "$1/grub" "$1/syslinux"
  printf 'menuentry "x" --id x {\n    linux /%%INSTALL_DIR%%/boot/x86_64/vmlinuz-linux-cachyos archisobasedir=%%INSTALL_DIR%% archisosearchuuid=%%ARCHISO_UUID%%\n    initrd /%%INSTALL_DIR%%/boot/x86_64/initramfs-linux-cachyos.img\n}\n' > "$1/grub/grub.cfg"
  printf 'menuentry "y" --id y {\n    linux /%%INSTALL_DIR%%/boot/x86_64/vmlinuz-linux-cachyos-lts img_dev=x\n}\n' > "$1/grub/loopback.cfg"
  printf 'LABEL arch64\nLINUX /%%INSTALL_DIR%%/boot/%%ARCH%%/vmlinuz-linux-cachyos-lts\nINITRD /%%INSTALL_DIR%%/boot/%%ARCH%%/initramfs-linux-cachyos-lts.img\nAPPEND archisobasedir=%%INSTALL_DIR%% archisosearchuuid=%%ARCHISO_UUID%% copytoram=auto\n' > "$1/syslinux/archiso_sys-linux.cfg"
  printf 'LABEL memtest\nMENU LABEL Run Memtest86+ (RAM test)\nLINUX /%%INSTALL_DIR%%/boot/memtest\n' > "$1/syslinux/archiso_tail.cfg"
}
fixmut() { # fixmut <dir> <file> <sed expression>: edit one fixture file in place
  sed "$3" "$1/$2" > "$1/$2.new" && mv "$1/$2.new" "$1/$2"
}
KLF="$WORK/klfix"; mkdir -p "$KLF"
mkklfix "$KLF/pristine"
fixture_patched() { # fixture_patched <name> [<file> <sed expression>]...: pristine, with the deliberate Memtest change, plus the given edits
  local name="$1"; shift
  rm -rf "${KLF:?}/$name"; mkklfix "$KLF/$name"
  fixmut "$KLF/$name" syslinux/archiso_tail.cfg 's|^LINUX /%INSTALL_DIR%/boot/memtest$|LINUX /boot/memtest86+/memtest|'
  while [[ $# -ge 2 ]]; do fixmut "$KLF/$name" "$1" "$2"; shift 2; done
}
fixture_patched good
kl_diff_check "$KLF/pristine" "$KLF/good" >/dev/null && t_pass "the Memtest path change alone is accepted" || t_fail "the Memtest path change alone is rejected: $(kl_diff_check "$KLF/pristine" "$KLF/good")"
kl_diff_check "$KLF/pristine" "$KLF/pristine" >/dev/null && t_fail "an unpatched profile is accepted: the Memtest fix could be lost without a failure" || t_pass "a profile without the Memtest fix is rejected"
fixture_patched b1 syslinux/archiso_sys-linux.cfg 's|^APPEND \(.*\)$|APPEND \1 quiet|'
kl_diff_check "$KLF/pristine" "$KLF/b1" >/dev/null && t_fail "an extra word on a syslinux APPEND line is accepted next to the Memtest change" || t_pass "an extra APPEND word is rejected even next to the Memtest change"
fixture_patched b2 grub/grub.cfg 's|archisosearchuuid=%ARCHISO_UUID%|archisosearchuuid=%ARCHISO_UUID% quiet|'
kl_diff_check "$KLF/pristine" "$KLF/b2" >/dev/null && t_fail "a changed GRUB linux line is accepted next to the Memtest change" || t_pass "a changed GRUB linux line is rejected even next to the Memtest change"
fixture_patched b3 syslinux/archiso_sys-linux.cfg '/^INITRD /d'
kl_diff_check "$KLF/pristine" "$KLF/b3" >/dev/null && t_fail "a deleted INITRD line is accepted next to the Memtest change" || t_pass "a deleted INITRD line is rejected even next to the Memtest change"
fixture_patched b4 syslinux/archiso_tail.cfg 's|^LINUX /boot/memtest86+/memtest$|LINUX /boot/memtest86+/memtest.bin|'
kl_diff_check "$KLF/pristine" "$KLF/b4" >/dev/null && t_fail "a different Memtest path than the expected one is accepted" || t_pass "only the exact expected Memtest path is accepted"
fixture_patched b5 grub/loopback.cfg 's|img_dev=x$|img_dev=x |'
kl_diff_check "$KLF/pristine" "$KLF/b5" >/dev/null && t_fail "a trailing space on a GRUB linux line is accepted" || t_pass "a whitespace-only change of a kernel line is rejected (byte-identical is the rule)"
fixture_patched b6; printf 'LINUX /%%INSTALL_DIR%%/boot/%%ARCH%%/vmlinuz-extra\n' >> "$KLF/b6/syslinux/archiso_sys-linux.cfg"
kl_diff_check "$KLF/pristine" "$KLF/b6" >/dev/null && t_fail "an added LINUX line is accepted" || t_pass "an added kernel line is rejected"
# The marker that lets a patch through guard (a) is a blanket allowance for that patch: only the Memtest patch may carry it.
markers=""
for p in "$OVERLAY"/patches/*.patch; do grep -q '^# ci-os: allow-kernel-line-change' "$p" && markers="$markers$(basename "$p") "; done
[[ "$markers" == "0002-syslinux-companion-os-menu.patch " ]] && t_pass "only the Memtest patch (0002) carries the allow-kernel-line-change marker" || t_fail "patches carrying the allow-kernel-line-change marker: ${markers:-none} (only 0002 may; any other needs this test and the guard reviewed)"

echo "== B: the patches"
if [[ -z "$UP" || ! -f "$UP/grub/grub.cfg" ]]; then
  t_skip "part B needs the pinned upstream archiso/ directory: set CACHYOS_UPSTREAM_ARCHISO (or CACHYOS_TEST_FETCH=1)"
else
  sha="$(lock_value UPSTREAM_SHA)"
  if [[ -n "$sha" ]] && git -C "$UP/.." rev-parse HEAD >/dev/null 2>&1; then
    [[ "$(git -C "$UP/.." rev-parse HEAD)" == "$sha" ]] && t_pass "the upstream checkout is at the pinned commit $sha" || t_fail "the upstream checkout is at $(git -C "$UP/.." rev-parse HEAD), the lock pins $sha"
  else
    t_skip "cannot compare the upstream checkout with the pin (not a git checkout, or no upstream.lock)"
  fi
  cp -R "$UP" "$WORK/pristine" && cp -R "$UP" "$WORK/patched"
  applied=1
  for p in "$OVERLAY"/patches/*.patch; do
    if (cd "$WORK/pristine" && git apply --check -p1 --whitespace=nowarn "$p") >/dev/null 2>&1; then t_pass "git apply --check: $(basename "$p")"; else t_fail "git apply --check FAILS: $(basename "$p")"; applied=0; fi
  done
  if [[ $applied -eq 1 ]]; then
    for p in "$OVERLAY"/patches/*.patch; do (cd "$WORK/patched" && git apply -p1 --whitespace=nowarn "$p"); done
    if klout="$(kl_diff_check "$WORK/pristine" "$WORK/patched")"; then
      t_pass "the only kernel-line difference from upstream is the BIOS Memtest path ($(kl "$WORK/patched" | wc -l | tr -d ' ') linux/initrd/APPEND/KERNEL lines compared, all others byte-identical)"
    else
      t_fail "the kernel lines differ from upstream's by more than the Memtest path change (or the Memtest change is missing): $klout"
    fi
    # no CachyOS word outside the kernel/initrd file names
    rest="$(cd "$WORK/patched" && grep -rniE 'cachy' grub/grub.cfg grub/loopback.cfg syslinux/*.cfg | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(linux|initrd|LINUX|INITRD|APPEND)[[:space:]]' | grep -v 'syslinux/archiso_pxe.cfg' || true)"
    [[ -z "$rest" ]] && t_pass "the patched boot menus say CachyOS nowhere outside the kernel and initrd file names" || t_fail "CachyOS left in the boot menus: $(printf '%s' "$rest" | head -n 4)"
    # default= must name an entry id, the syslinux DEFAULT a LABEL
    for f in grub/grub.cfg grub/loopback.cfg; do
      d="$(sed -n 's/^default=//p' "$WORK/patched/$f" | head -n 1)"
      grep -q -- "--id '$d'" "$WORK/patched/$f" && t_pass "$f: default=$d names an existing entry id" || t_fail "$f: default=$d matches no --id"
      dup="$(grep -o -- "--id '[^']*'" "$WORK/patched/$f" | sort | uniq -d || true)"
      [[ -z "$dup" ]] && t_pass "$f: entry ids are unique" || t_fail "$f: duplicate ids: $dup"
    done
    dl="$(sed -n 's/^DEFAULT //p' "$WORK/patched/syslinux/archiso_sys.cfg" | head -n 1)"
    grep -q "^LABEL $dl\$" "$WORK/patched/syslinux/archiso_sys-linux.cfg" && t_pass "syslinux DEFAULT $dl is a LABEL that exists" || t_fail "syslinux DEFAULT $dl is not a LABEL (upstream's dangling DEFAULT)"
    grep -q '^INCLUDE companion_colors.cfg$' "$WORK/patched/syslinux/archiso_head.cfg" && t_pass "archiso_head.cfg INCLUDEs the generated colours" || t_fail "archiso_head.cfg does not INCLUDE companion_colors.cfg"
    grep -q '^MENU TITLE Companion OS$' "$WORK/patched/syslinux/archiso_head.cfg" && t_pass "BIOS menu title is Companion OS" || t_fail "BIOS menu title is not Companion OS"
    grep -q '^background_image /boot/grub/splash.png$' <(sed 's/^[[:space:]]*//' "$WORK/patched/grub/grub.cfg") && t_pass "grub.cfg loads /boot/grub/splash.png (the rendered fallback background)" || t_fail "grub.cfg does not load the background"
    grep -q '^set theme=/boot/grub/theme/theme.txt$' <(sed 's/^[[:space:]]*//' "$WORK/patched/grub/grub.cfg") && grep -q '^insmod gfxmenu$' <(sed 's/^[[:space:]]*//' "$WORK/patched/grub/grub.cfg") \
      && t_pass "grub.cfg sets the theme /boot/grub/theme/theme.txt (rendered by render-assets.sh) after insmod gfxmenu" || t_fail "grub.cfg does not set the theme"
    # insmod only what grub-mkstandalone embeds (archiso 91: all_video font gfxmenu gfxterm png jpeg ... + the list below)
    embedded=" all_video at_keyboard boot btrfs cat chain configfile echo efifwsetup efinet exfat ext2 f2fs fat font gfxmenu gfxterm gzio halt hfsplus iso9660 jpeg keylayouts linux loadenv loopback lsefi lsefimmap minicmd normal ntfs ntfscomp part_apple part_gpt part_msdos png read reboot regexp search search_fs_file search_fs_uuid search_label serial sleep tpm udf usb usbserial_common usbserial_ftdi usbserial_pl2303 usbserial_usbdebug video xfs zstd "
    bad_mod=""
    for m in $(sed -n 's/^[[:space:]]*insmod[[:space:]]*\([A-Za-z0-9_]*\).*/\1/p' "$WORK/patched/grub/grub.cfg"); do
      case "$embedded" in *" $m "*) ;; *) bad_mod="$bad_mod $m" ;; esac
    done
    [[ -z "$bad_mod" ]] && t_pass "grub.cfg insmods only modules that mkarchiso's grub-mkstandalone embeds (archiso 91)" || t_fail "insmod of a module that is not embedded:$bad_mod"
    # the fallback colours of the patched menu equal what the tokens give (the generated file overrides them)
    fallback="$(sed -n 's/^set menu_color_normal=//p;s/^set menu_color_highlight=//p' "$WORK/patched/grub/grub.cfg" | tr '\n' ' ')"
    [[ "$fallback" == "$expect" ]] && t_pass "the menu's fallback colours equal the token-derived ones ($expect)" || t_fail "fallback colours '$fallback' differ from the token-derived '$expect'"
    if command -v grub-script-check >/dev/null 2>&1; then
      ok=1
      for f in grub/grub.cfg grub/loopback.cfg; do sed 's|%[A-Z_]*%|x|g' "$WORK/patched/$f" > "$WORK/gs.cfg"; grub-script-check "$WORK/gs.cfg" >/dev/null 2>&1 || ok=0; done
      [[ $ok -eq 1 ]] && t_pass "grub-script-check accepts both patched menus" || t_fail "grub-script-check rejects a patched menu"
    else
      t_skip "grub-script-check not installed here (it is in the builder container: grub package)"
    fi
  fi
fi

#=== C: the scripts on fixtures =============================================================================================================
echo "== C: the scripts"
mkroot() { # mkroot <dir>: a root with the CachyOS state before our scripts: os-release as cachyos-hooks leaves it, a skel, the scheme
  local r="$1" s
  mkdir -p "$r/etc/skel/.config" "$r/usr/share/color-schemes" "$r/usr/share/ci-os" "$r/usr/lib"
  printf 'NAME="Arch Linux"\nID=arch\n' > "$r/usr/lib/os-release"
  printf 'NAME="CachyOS Linux"\nPRETTY_NAME=CachyOS\nID=cachyos\nID_LIKE=arch\nBUILD_ID=rolling\nANSI_COLOR="38;2;23;147;209"\nHOME_URL="https://cachyos.org/"\nLOGO=cachyos\nIMAGE_ID=companion-os-plasma\nIMAGE_VERSION=2026.10.03\n' > "$r/etc/os-release"
  printf 'LSB_VERSION=1.4\nDISTRIB_ID=cachyos\nDISTRIB_RELEASE=rolling\nDISTRIB_DESCRIPTION="CachyOS"\n' > "$r/etc/lsb-release"
  cp "$REPO_ROOT/backends/_mixins/kde-plasma/CI-OS-Dark.colors" "$r/usr/share/color-schemes/CI-OS-Dark.colors"
  printf 'CI_OS_VERSION="2026.10"\nCI_OS_BUILD="20261015"\nCI_OS_ANSI_COLOR="38;2;197;232;220"\n' > "$r/usr/share/ci-os/release"
  s="$r/etc/skel/.config"
  if [[ -n "${CACHYOS_SKEL_SRC:-}" && -d "${CACHYOS_SKEL_SRC}/.config" ]]; then
    cp -R "${CACHYOS_SKEL_SRC}/." "$r/etc/skel/"
  else
    # The shape of cachyos-kde-settings' skeleton (tag 4.9): the desktop is containment 22, the panel 23 with the
    # start button, and the wallpaper group sits under containment 4, which does not exist.
    cat > "$s/plasma-org.kde.plasma.desktop-appletsrc" <<'EOF'
[ActionPlugins][0]
RightButton;NoModifier=org.kde.contextmenu

[Containments][22]
activityId=4207bc28-eb35-4a29-bcfb-3bd345389509
formfactor=0
lastScreen=0
plugin=org.kde.plasma.folder
wallpaperplugin=org.kde.image

[Containments][23]
formfactor=2
plugin=org.kde.panel
wallpaperplugin=org.kde.image

[Containments][23][Applets][24]
immutability=1
plugin=org.kde.plasma.kickoff

[Containments][23][Applets][24][Configuration][General]
favoritesPortedToKAstats=true
icon=org.cachyos.hello
systemFavorites=suspend\\,hibernate\\,reboot\\,shutdown

[Containments][23][Applets][26][Configuration][General]
launchers=applications:systemsettings.desktop,preferred://filemanager,preferred://browser

[Containments][4][Wallpaper][org.kde.image][General]
Image=/usr/share/wallpapers/cachyos-wallpapers/north.png
PreviewImage=/usr/share/wallpapers/cachyos-wallpapers/north.png
SlidePaths=/usr/share/wallpapers/

[ScreenMapping]
itemsOnDisabledScreens=
EOF
    printf '[General]\nColorScheme=BreezeDark\n\n[Icons]\nTheme=breeze-dark\n\n[KDE]\nAnimationDurationFactor=0.25\nwidgetStyle=Breeze\n' > "$s/kdeglobals"
    mkdir -p "$s/kdedefaults"
    printf '[General]\nColorScheme=BreezeDark\n\n[KDE]\nwidgetStyle=Breeze\n' > "$s/kdedefaults/kdeglobals"
    printf '[$Version]\nupdate_info=kscreenlocker.upd:0.1-autolock\n\n[Daemon]\nAutolock=false\nLockGrace=300\n' > "$s/kscreenlockerrc"
  fi
}
tree_sum() { (cd "$1" && find . -type f -o -type l | LC_ALL=C sort | while IFS= read -r f; do if [[ -L "$f" ]]; then printf 'L %s %s\n' "$f" "$(readlink "$f")"; else printf 'F %s %s\n' "$f" "$(cksum < "$f")"; fi; done); }

R1="$WORK/c1"; mkroot "$R1"
CI_OS_ROOT="$R1" bash "$HOOKSCRIPT" >/dev/null 2>&1 && t_pass "zz-ci-os-os-release runs" || t_fail "zz-ci-os-os-release failed"
expected_osr='NAME="Companion OS"
PRETTY_NAME="Companion OS 2026.10"
ID=cachyos
ID_LIKE=arch
BUILD_ID=rolling
VARIANT="Plasma (based on CachyOS)"
ANSI_COLOR="38;2;197;232;220"
HOME_URL="https://ci.computer"
DOCUMENTATION_URL="https://docs.ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
LOGO=ci-os-logo
CI_OS_ID=ci-os
CI_OS_VERSION="2026.10"
CI_OS_BUILD="20261015"
IMAGE_ID=companion-os-plasma
IMAGE_VERSION=2026.10.03'
[[ "$(cat "$R1/etc/os-release")" == "$expected_osr" ]] && t_pass "os-release is the golden text (CachyOS's rewrite replaced whole; IMAGE_ID/IMAGE_VERSION kept)" || t_fail "os-release differs from the golden text: $(diff <(printf '%s\n' "$expected_osr") "$R1/etc/os-release" | head -n 8)"
[[ "$(cat "$R1/etc/lsb-release")" == 'LSB_VERSION=1.4
DISTRIB_ID=cachyos
DISTRIB_RELEASE=rolling
DISTRIB_DESCRIPTION="Companion OS 2026.10"' ]] && t_pass "lsb-release is the golden text" || t_fail "lsb-release differs: $(cat "$R1/etc/lsb-release")"
[[ "$(cat "$R1/usr/lib/os-release")" == 'NAME="Arch Linux"
ID=arch' ]] && t_pass "the package-owned /usr/lib/os-release is not touched" || t_fail "/usr/lib/os-release was modified"
# the static file of the overlay carries the same keys and values (it only lacks what the stamp supplies)
static_missing=""
while IFS= read -r line; do
  case "$line" in PRETTY_NAME=*|CI_OS_VERSION=*|CI_OS_BUILD=*|IMAGE_*) continue ;; esac
  grep -qxF -- "$line" "$FILES/etc/os-release" || static_missing="$static_missing [$line]"
done <<< "$expected_osr"
[[ -z "$static_missing" ]] && t_pass "overlay/files/airootfs/etc/os-release has every fixed key and value of the golden text" || t_fail "the static os-release lacks:$static_missing"
want_ansi="38;2;$( ( source "$REPO_ROOT/core/lib/theme-lib.sh" >/dev/null; ci_rgb "$CI_DARK_PRIMARY" | tr ' ' ';' ) )"
[[ "$want_ansi" == "38;2;197;232;220" ]] && grep -qx 'ANSI_COLOR="38;2;197;232;220"' "$FILES/etc/os-release" && t_pass "the static ANSI_COLOR is CI_DARK_PRIMARY from the tokens ($want_ansi)" || t_fail "the static ANSI_COLOR differs from the token-derived $want_ansi"

# idempotence and symlink handling
before="$(tree_sum "$R1")"; CI_OS_ROOT="$R1" bash "$HOOKSCRIPT" >/dev/null 2>&1; [[ "$(tree_sum "$R1")" == "$before" ]] && t_pass "running the identity writer twice changes nothing" || t_fail "the identity writer is not idempotent"
R2="$WORK/c2"; mkroot "$R2"; rm -f "$R2/etc/os-release"; ln -s ../usr/lib/os-release "$R2/etc/os-release"
CI_OS_ROOT="$R2" bash "$HOOKSCRIPT" >/dev/null 2>&1
if [[ ! -L "$R2/etc/os-release" && "$(grep -c '^NAME=' "$R2/etc/os-release")" == 1 && "$(cat "$R2/usr/lib/os-release" | head -n 1)" == 'NAME="Arch Linux"' ]]; then t_pass "a symlinked /etc/os-release becomes a regular file; the link's target is untouched"; else t_fail "symlink case: $(ls -l "$R2/etc/os-release")"; fi
# hostile and missing stamps
R3="$WORK/c3"; mkroot "$R3"
{ printf 'CI_OS_VERSION="1.0"; touch %s/pwned; #"\n' "$R3"; printf 'CI_OS_BUILD="x"\n'; printf 'CI_OS_ANSI_COLOR="1;2m"\n'; } > "$R3/usr/share/ci-os/release"
CI_OS_ROOT="$R3" bash "$HOOKSCRIPT" >/dev/null 2>&1 || true
if [[ ! -e "$R3/pwned" ]] && grep -qx 'PRETTY_NAME="Companion OS"' "$R3/etc/os-release" && ! grep -q 'CI_OS_BUILD\|ANSI_COLOR' "$R3/etc/os-release"; then t_pass "a release stamp with quotes, shell syntax or junk is ignored, not written"; else t_fail "hostile stamp was accepted: $(cat "$R3/etc/os-release" | head -n 4)"; fi
R4="$WORK/c4"; mkroot "$R4"; rm -f "$R4/usr/share/ci-os/release"
CI_OS_ROOT="$R4" bash "$HOOKSCRIPT" >/dev/null 2>&1 && grep -qx 'PRETTY_NAME="Companion OS"' "$R4/etc/os-release" && t_pass "without a release stamp: PRETTY_NAME has no invented version, the file is still ours" || t_fail "missing-stamp case failed"
# the CachyOS blue is never carried over
grep -q '23;147;209' "$R4/etc/os-release" && t_fail "CachyOS's ANSI_COLOR survived a rewrite" || t_pass "CachyOS's ANSI_COLOR is not carried over"

# skel
CI_OS_ROOT="$R1" bash "$SKELSCRIPT" >/dev/null 2>&1 && t_pass "zz-ci-os-skel runs" || t_fail "zz-ci-os-skel failed"
bash "$CHECK" "$R1" > "$WORK/check1.log" 2>&1 || true
# fixture root lacks the hook files themselves; they are asserted on the assembled image below
grep -E '^FAIL' "$WORK/check1.log" | grep -v 'zz-ci-os' > "$WORK/check1.fail" || true
[[ ! -s "$WORK/check1.fail" ]] && t_pass "overlay-image-check.sh accepts the fixture after both scripts ran (skel, colours, wallpaper group moved to the desktop containment)" || t_fail "image check: $(cat "$WORK/check1.fail")"
before="$(tree_sum "$R1")"; CI_OS_ROOT="$R1" bash "$SKELSCRIPT" >/dev/null 2>&1; [[ "$(tree_sum "$R1")" == "$before" ]] && t_pass "running the skel editor twice changes nothing" || t_fail "the skel editor is not idempotent: $(diff <(printf '%s\n' "$before") <(tree_sum "$R1") | head -n 6)"
# only the documented keys changed in the layout
if [[ -z "${CACHYOS_SKEL_SRC:-}" ]]; then
  mkroot "$WORK/c1ref"
  ref="$WORK/c1ref/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"; now="$R1/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"
  removed="$(diff "$ref" "$now" | grep '^<' || true)"
  unexpected="$(printf '%s\n' "$removed" | grep -vE '^< (icon=org\.cachyos\.hello|\[Containments\]\[4\]\[Wallpaper\]\[org\.kde\.image\]\[General\]|Image=/usr/share/wallpapers/cachyos-wallpapers/north\.png|PreviewImage=/usr/share/wallpapers/cachyos-wallpapers/north\.png|SlidePaths=/usr/share/wallpapers/)$' | grep -vE '^< ?$' || true)"
  [[ -z "$unexpected" ]] && t_pass "the panel layout edit removes only the start icon and the misplaced wallpaper group ($(printf '%s\n' "$removed" | grep -c . || true) lines)" || t_fail "the layout edit removed other lines too: $unexpected"
  grep -qF 'systemFavorites=suspend\\,hibernate' "$now" && t_pass "escaped values elsewhere in the layout survive byte for byte" || t_fail "systemFavorites was altered"
fi
# a skel without the folder containment, and a missing scheme
R5="$WORK/c5"; mkroot "$R5"; sed -i.bak 's/^plugin=org.kde.plasma.folder$/plugin=org.kde.plasma.something/' "$R5/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null && rm -f "$R5/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc.bak" || true
if [[ -z "${CACHYOS_SKEL_SRC:-}" ]]; then
  rm -f "$R5/usr/share/color-schemes/CI-OS-Dark.colors"
  out="$(CI_OS_ROOT="$R5" bash "$SKELSCRIPT" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]] && grep -q 'no desktop containment' <<< "$out" && grep -q 'colour scheme not set' <<< "$out" \
     && ! grep -q 'Image=file:' "$R5/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc" && grep -qx 'icon=ci-os-logo' "$R5/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc" \
     && grep -qx 'ColorScheme=BreezeDark' "$R5/etc/skel/.config/kdeglobals"; then
    t_pass "unexpected layout or missing scheme: warns, exits 0, edits nothing it cannot do, still fixes the start icon"
  else
    t_fail "degraded-skel case: rc=$rc output: $out"
  fi
fi

# the start button gets our icon whatever icon name the package's layout carried (CachyOS renames its icons now and then)
if [[ -z "${CACHYOS_SKEL_SRC:-}" ]]; then
  R6="$WORK/c6"; mkroot "$R6"
  sed 's/^icon=org\.cachyos\.hello$/icon=some-other-cachyos-icon/' "$R6/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc" > "$R6/appletsrc.new" && mv "$R6/appletsrc.new" "$R6/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"
  CI_OS_ROOT="$R6" bash "$SKELSCRIPT" >/dev/null 2>&1
  if grep -qx 'icon=ci-os-logo' "$R6/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc" && ! grep -q 'some-other-cachyos-icon' "$R6/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"; then t_pass "the Kickoff applet's icon is set to ci-os-logo whatever name the layout carried"; else t_fail "the start icon was not replaced when its old name differed"; fi
fi

# the assembled live image: overlay files + the renderer's staging + the fixture's CachyOS state, then both scripts, then the checker
echo "== D: render-assets.sh"
IM=""
if command -v magick >/dev/null 2>&1; then IM="magick"; elif command -v convert >/dev/null 2>&1; then IM="convert"; fi
STAGE="$WORK/stage"
STAGE_FULL=""
if [[ -z "$IM" ]]; then
  t_skip "part D needs ImageMagick (magick or convert)"
else
  if [[ "$IM" == magick ]]; then IDENT=(magick identify); else IDENT=(identify); fi
  if bash "$SCRIPTS/render-assets.sh" --help >/dev/null 2>&1; then t_pass "render-assets.sh --help works"; else t_fail "render-assets.sh --help failed"; fi
  if CI_OS_STAGING_DIR="$STAGE" CI_OS_VERSION=2026.10 CI_OS_BUILD_DAY=20261015 bash "$SCRIPTS/render-assets.sh" --no-installed > "$WORK/render.log" 2>&1; then t_pass "render-assets.sh --no-installed runs"; else t_fail "render-assets.sh failed: $(tail -n 5 "$WORK/render.log")"; fi
  if [[ -d "$STAGE/grub" ]]; then
    dim() { "${IDENT[@]}" -format '%wx%h %m' "$1" 2>/dev/null; }
    [[ "$(dim "$STAGE/grub/splash.png")" == "1920x1080 PNG" ]] && t_pass "grub/splash.png is a 1920x1080 PNG" || t_fail "grub/splash.png is $(dim "$STAGE/grub/splash.png")"
    [[ "$(dim "$STAGE/syslinux/splash.png")" == "640x480 PNG" ]] && t_pass "syslinux/splash.png is a 640x480 PNG (vesamenu's mode)" || t_fail "syslinux/splash.png is $(dim "$STAGE/syslinux/splash.png")"
    # the live menu's GRUB theme (grub/theme): files, the picture's shape, token colours, and where the mark is
    TH="$STAGE/grub/theme"
    [[ "$(dim "$TH/background.png")" == "1920x1080 PNG" && -s "$TH/select_c.png" && -s "$TH/theme.txt" ]] && t_pass "grub/theme: background.png 1920x1080, select_c.png, theme.txt" || t_fail "grub/theme is incomplete: $(ls "$TH" 2>&1 | tr '\n' ' ')"
    grep -qx 'desktop-image: "background.png"' "$TH/theme.txt" && grep -qx 'desktop-image-scale-method: "crop"' "$TH/theme.txt" && grep -qx '+ boot_menu {' "$TH/theme.txt" && grep -qx '  id = "__timeout__"' "$TH/theme.txt" \
      && t_pass "theme.txt: desktop-image cropped (not stretched), a boot_menu, the countdown label" || t_fail "theme.txt lacks desktop-image, the crop scale method, boot_menu or the countdown label"
    ( source "$REPO_ROOT/core/lib/theme-lib.sh" >/dev/null
      grep -qF "desktop-color: \"$CI_DARK_BACKGROUND\"" "$TH/theme.txt" && grep -qF "item_color = \"$CI_DARK_FOREGROUND\"" "$TH/theme.txt" && grep -qF "selected_item_color = \"$CI_DARK_BACKGROUND\"" "$TH/theme.txt" && grep -qF "color = \"$CI_DARK_MUTED_FOREGROUND\"" "$TH/theme.txt" ) \
      && t_pass "theme.txt colours are the tokens" || t_fail "theme.txt colours are not the tokens"
    sel="$("$IM" "$TH/select_c.png" -format '%[pixel:p{3,3}]' info: 2>/dev/null)"
    [[ "$sel" == "$( ( source "$REPO_ROOT/core/lib/theme-lib.sh" >/dev/null; printf 'srgb(%s)' "$(ci_rgb "$CI_ACCENT_AQUA" | tr ' ' ',')" ) )" ]] && t_pass "the highlight tile is CI_ACCENT_AQUA ($sel)" || t_fail "the highlight tile is $sel"
    gm="$("$IM" "$TH/background.png" -format '%[pixel:p{960,260}]' info: 2>/dev/null)"; gg="$("$IM" "$TH/background.png" -format '%[pixel:p{960,700}]' info: 2>/dev/null)"
    [[ "$gm" != "$gg" ]] && t_pass "theme background: the mark is in the upper third (centre-top differs from the ground), the menu area is bare ground" || t_fail "theme background layout: mark pixel $gm, ground $gg"
    sm="$("$IM" "$STAGE/syslinux/splash.png" -format '%[pixel:p{320,90}]' info: 2>/dev/null)"; sc="$("$IM" "$STAGE/syslinux/splash.png" -format '%[pixel:p{320,300}]' info: 2>/dev/null)"
    [[ "$sm" != "$sc" && "$sc" == "$("$IM" "$STAGE/syslinux/splash.png" -format '%[pixel:p{5,5}]' info: 2>/dev/null)" ]] && t_pass "syslinux background: the mark is above the menu box, the box area is bare ground" || t_fail "syslinux background layout: mark pixel $sm, box area $sc"
    # Text that ends up on the medium must not carry the CachyOS name: the generated boot configuration and the theme
    leaks="$(grep -rIil 'cachy' "$STAGE/grub" "$STAGE/syslinux" "$STAGE/airootfs/etc" "$STAGE/airootfs/usr/share/ci-os" "$STAGE/airootfs/usr/share/wallpapers" 2>/dev/null || true)"
    [[ -z "$leaks" ]] && t_pass "no generated file of the boot menus, wallpaper package, About page or release stamp contains 'cachy'" || t_fail "generated file(s) with the CachyOS name: $leaks"
    W="$STAGE/airootfs/usr/share/wallpapers/companion"
    [[ "$(dim "$W/contents/images/1920x1080.jpg")" == "1920x1080 JPEG" && "$(dim "$W/contents/images/3840x2160.jpg")" == "3840x2160 JPEG" ]] && t_pass "wallpaper package: 1920x1080 and 3840x2160 JPEGs" || t_fail "wallpaper sizes: $(dim "$W/contents/images/1920x1080.jpg") $(dim "$W/contents/images/3840x2160.jpg")"
    [[ "$(dim "$W/contents/screenshot.png")" == "480x270 PNG" ]] && t_pass "wallpaper preview is 480x270" || t_fail "wallpaper preview is $(dim "$W/contents/screenshot.png")"
    python3 -I - "$W/metadata.json" > "$WORK/meta.out" 2>&1 <<'PYEOF' && t_pass "wallpaper metadata.json parses: Id companion, KPackageStructure Wallpaper/Images" || t_fail "wallpaper metadata.json: $(cat "$WORK/meta.out")"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["KPlugin"]["Id"] == "companion", m
assert m["KPackageStructure"] == "Wallpaper/Images", m
assert m["KPlugin"]["Name"] == "Companion OS", m
PYEOF
    empty="$(find "$STAGE" -type f -size 0 || true)"; [[ -z "$empty" ]] && t_pass "no empty file in the staging tree" || t_fail "empty: $empty"
    nonwhite="$(find "$STAGE" -type f -perm -100 || true)"; [[ -z "$nonwhite" ]] && t_pass "no executable file in the staging tree (the engine would need a file_permissions entry)" || t_fail "executable: $nonwhite"
    # the ground colour of both boot backgrounds is the canon's dark background
    want="$( ( source "$REPO_ROOT/core/lib/theme-lib.sh" >/dev/null; printf 'srgb(%s)' "$(ci_rgb "$CI_DARK_BACKGROUND" | tr ' ' ',')" ) )"
    got1="$("$IM" "$STAGE/grub/splash.png" -format '%[pixel:p{5,5}]' info: 2>/dev/null)"; got2="$("$IM" "$STAGE/syslinux/splash.png" -format '%[pixel:p{5,5}]' info: 2>/dev/null)"
    [[ "$got1" == "$want" && "$got2" == "$want" ]] && t_pass "the corner of both boot backgrounds is CI_DARK_BACKGROUND ($want)" || t_fail "corner pixels $got1 / $got2, expected $want"
    # menu colours derived from the tokens
    sed -n 's/^set menu_color_normal=//p;s/^set menu_color_highlight=//p' "$STAGE/grub/companion-os-theme.cfg" | tr '\n' ' ' > "$WORK/gc.out"
    [[ "$(cat "$WORK/gc.out")" == "$expect" ]] && t_pass "grub/companion-os-theme.cfg: $(cat "$WORK/gc.out")(from ci_grub_nearest_color of the tokens)" || t_fail "grub colours '$(cat "$WORK/gc.out")' differ from '$expect'"
    sl="$STAGE/syslinux/companion_colors.cfg"
    if [[ "$(grep -c '^MENU COLOR ' "$sl")" == 9 ]] && grep -q '#ff041620 #ff00a9a7' "$sl" && grep -q '#ffc5e8dc' "$sl"; then t_pass "syslinux colours: 9 MENU COLOR lines in token hex (selection: ground on aqua, title: primary)"; else t_fail "syslinux colours are not the expected token values"; fi
    ( source "$REPO_ROOT/core/lib/theme-lib.sh" >/dev/null
      grep -q "$(printf '%s' "$CI_DARK_FOREGROUND" | sed 's/#//')" "$sl" && grep -q "$(printf '%s' "$CI_ACCENT_AQUA" | sed 's/#//')" "$sl" ) && t_pass "syslinux colours contain CI_DARK_FOREGROUND and CI_ACCENT_AQUA from the tokens" || t_fail "syslinux colours lack a token value"
    cmp -s "$REPO_ROOT/vendor/brand/logos/mark.svg" "$STAGE/airootfs/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg" && t_pass "ci-os-logo.svg is the vendored mark, byte for byte" || t_fail "ci-os-logo.svg differs from vendor/brand/logos/mark.svg"
    cmp -s "$REPO_ROOT/backends/_mixins/kde-plasma/CI-OS-Dark.colors" "$STAGE/airootfs/usr/share/color-schemes/CI-OS-Dark.colors" && t_pass "CI-OS-Dark.colors is the shared scheme, byte for byte" || t_fail "the colour scheme differs from the mixin's"
    grep -qx 'LogoPath=ci-os-logo' "$STAGE/airootfs/etc/xdg/kcm-about-distrorc" && grep -qx 'Version=2026.10' "$STAGE/airootfs/etc/xdg/kcm-about-distrorc" && t_pass "kcm-about-distrorc: LogoPath=ci-os-logo, Version=2026.10" || t_fail "kcm-about-distrorc is wrong"
    grep -qx 'CI_OS_ANSI_COLOR="38;2;197;232;220"' "$STAGE/airootfs/usr/share/ci-os/release" && grep -qx 'CI_OS_VERSION="2026.10"' "$STAGE/airootfs/usr/share/ci-os/release" && grep -qx 'CI_OS_BUILD="20261015"' "$STAGE/airootfs/usr/share/ci-os/release" && t_pass "the release stamp has version, build day and the token-derived colour" || t_fail "release stamp is wrong: $(cat "$STAGE/airootfs/usr/share/ci-os/release")"
    # deterministic: a second render is byte-identical
    if CI_OS_STAGING_DIR="$WORK/stage2" CI_OS_VERSION=2026.10 CI_OS_BUILD_DAY=20261015 bash "$SCRIPTS/render-assets.sh" --no-installed > "$WORK/render2.log" 2>&1 && diff -r "$STAGE" "$WORK/stage2" >/dev/null 2>&1; then t_pass "a second render is byte-identical (deterministic)"; else t_fail "two renders differ: $(diff -rq "$STAGE" "$WORK/stage2" 2>&1 | head -n 4)"; fi
    # missing source asset: loud failure, nothing claimed
    mkdir -p "$WORK/emptyrepo"
    if CI_OS_STAGING_DIR="$WORK/stage3" CI_OS_REPO_ROOT="$WORK/emptyrepo" bash "$SCRIPTS/render-assets.sh" --no-installed >/dev/null 2>&1; then t_fail "render-assets.sh succeeded against a repo without the canon"; else t_pass "render-assets.sh fails (non-zero) when the repository lacks the canon"; fi
    # versions that would break the stamp are refused
    if CI_OS_STAGING_DIR="$WORK/stage4" CI_OS_VERSION='1.0"; x' bash "$SCRIPTS/render-assets.sh" --no-installed >/dev/null 2>&1; then t_fail "a version with a quote was accepted"; else t_pass "a CI_OS_VERSION with shell characters is refused"; fi
  fi

  # the installed-system parts: rendered in a container on request, or taken from CI_OS_TEST_STAGING_FULL
  if [[ "${CI_OS_TEST_DOCKER:-0}" == 1 ]]; then
    img="${CI_OS_TEST_IMAGE:-ci-cachyos-builder:latest}"
    if command -v docker >/dev/null 2>&1 && docker image inspect "$img" >/dev/null 2>&1; then
      mkdir -p "$WORK/stage-full"
      if docker run --rm --platform linux/amd64 --cpus 4 --memory 8g -v "$REPO_ROOT:/repo:ro" -v "$WORK/stage-full:/out" \
           -e CI_OS_STAGING_DIR=/out -e CI_OS_REPO_ROOT=/repo -e CI_OS_VERSION=2026.10 -e CI_OS_BUILD_DAY=20261015 "$img" bash -c \
           'pacman -Sy --noconfirm --needed $(grep -vE "^[[:space:]]*(#|$)" /repo/backends/cachyos/iso/render-deps.txt) >/tmp/p.log 2>&1 && bash /repo/backends/cachyos/iso/scripts/render-assets.sh' > "$WORK/render-full.log" 2>&1; then
        STAGE_FULL="$WORK/stage-full"; t_pass "render-assets.sh renders the full tree (with the installed-system themes) in $img"
      else
        t_fail "the container render failed: $(tail -n 6 "$WORK/render-full.log")"
      fi
    else
      t_skip "CI_OS_TEST_DOCKER=1 but docker or image $img is not available"
    fi
  elif [[ -n "${CI_OS_TEST_STAGING_FULL:-}" && -d "${CI_OS_TEST_STAGING_FULL}/airootfs" ]]; then
    STAGE_FULL="$CI_OS_TEST_STAGING_FULL"
  elif [[ -f "${CI_OS_PLYMOUTH_SPINNER_DIR:-/usr/share/plymouth/themes/spinner}/spinner.plymouth" ]] && sed --version >/dev/null 2>&1; then
    # Inside the builder (plymouth installed, GNU sed): render the full tree right here.
    if CI_OS_STAGING_DIR="$WORK/stage-full" CI_OS_VERSION=2026.10 CI_OS_BUILD_DAY=20261015 bash "$SCRIPTS/render-assets.sh" > "$WORK/render-full.log" 2>&1; then
      STAGE_FULL="$WORK/stage-full"; t_pass "render-assets.sh renders the full tree here (plymouth and GNU sed found)"
    else
      t_fail "the full render failed: $(tail -n 6 "$WORK/render-full.log")"
    fi
  fi
  if [[ -n "$STAGE_FULL" ]]; then
    G="$STAGE_FULL/airootfs/usr/share/grub/themes/companion-os"; P="$STAGE_FULL/airootfs/usr/share/plymouth/themes/companion-os"
    diff -r "$STAGE_FULL/grub/theme" "$G" >/dev/null 2>&1 && t_pass "the installed system's GRUB theme is byte-identical to the live menu's" || t_fail "the installed GRUB theme differs from grub/theme"
    pl="$P/companion-os.plymouth"
    ( source "$REPO_ROOT/core/lib/theme-lib.sh" >/dev/null
      grep -qx "BackgroundStartColor=$(ci_hex0x "$CI_DARK_BACKGROUND")" "$pl" && grep -qx "BackgroundEndColor=$(ci_hex0x "$CI_DARK_BACKGROUND")" "$pl" \
        && grep -qx "ProgressBarBackgroundColor=$(ci_hex0x "$CI_DARK_SECONDARY")" "$pl" && grep -qx "ProgressBarForegroundColor=$(ci_hex0x "$CI_DARK_PRIMARY")" "$pl" ) \
      && t_pass "Plymouth theme: ci_plymouth_recolor colours (ground, track, fill) from the tokens" || t_fail "Plymouth theme colours are not the canon's"
    grep -qx 'Name=Companion OS' "$pl" && grep -qx 'ModuleName=two-step' "$pl" && grep -qx 'ImageDir=/usr/share/plymouth/themes/companion-os' "$pl" && ! grep -q '^Name\[' "$pl" && t_pass "Plymouth theme: Name, two-step module, own ImageDir, no localised stock names" || t_fail "Plymouth theme header is wrong"
    grep -qiE 'cachy|arch ?linux' "$pl" && t_fail "the Plymouth theme names the base distribution" || t_pass "the Plymouth theme names neither CachyOS nor Arch"
    [[ "$("${IDENT[@]}" -format '%w' "$P/watermark.png")" == 512 ]] && t_pass "Plymouth watermark: the lockup at 50% (512 px wide)" || t_fail "Plymouth watermark has the wrong width"
    ls "$P"/animation-*.png >/dev/null 2>&1 && t_pass "Plymouth theme has the animation frames" || t_fail "Plymouth theme has no animation frames"
  else
    t_skip "the GRUB and Plymouth themes of the installed system are rendered only in the builder container: CI_OS_TEST_DOCKER=1 or CI_OS_TEST_STAGING_FULL=<dir>"
  fi

  #=== C (cont.): the assembled live image and the carry-over onto a target ===================================================
  echo "== C: assembled image and carry-over"
  IMG="$WORK/img"; mkdir -p "$IMG"
  cp -R "$FILES/." "$IMG/"
  SRC_STAGE="${STAGE_FULL:-$STAGE}"
  cp -R "$SRC_STAGE/airootfs/." "$IMG/"
  # the CachyOS state that cachyos-hooks and cachyos-kde-settings leave, as the fixture builder makes it
  mkroot "$WORK/cachy"
  cp "$WORK/cachy/etc/os-release" "$IMG/etc/os-release"; cp "$WORK/cachy/etc/lsb-release" "$IMG/etc/lsb-release"
  mkdir -p "$IMG/etc/skel"; cp -R "$WORK/cachy/etc/skel/." "$IMG/etc/skel/"
  # run both scripts the way the hooks do (the paths are absolute in a chroot; here CI_OS_ROOT stands in for it)
  CI_OS_ROOT="$IMG" bash "$IMG/usr/share/libalpm/scripts/zz-ci-os-os-release" >/dev/null 2>&1; CI_OS_ROOT="$IMG" bash "$IMG/usr/share/libalpm/scripts/zz-ci-os-skel" >/dev/null 2>&1
  if bash "$CHECK" --live "$IMG" > "$WORK/check-img.log" 2>&1; then t_pass "the assembled live image passes overlay-image-check.sh --live ($(grep '^== Summary' "$WORK/check-img.log"))"; else t_fail "assembled image: $(grep -E '^FAIL' "$WORK/check-img.log" | head -n 6)"; fi
  # carry-over onto a fixture target that has what pacstrap would have installed
  TGT="$WORK/target"; mkroot "$TGT"; rm -rf "$TGT/usr/share/ci-os" "$TGT/usr/share/color-schemes"
  if CI_OS_SOURCE_ROOT="$IMG" bash "$IMG/usr/share/ci-os/installed/carry-over" "$TGT" > "$WORK/carry.log" 2>&1; then rc=0; else rc=$?; fi
  if [[ -n "$STAGE_FULL" ]]; then
    [[ $rc -eq 0 ]] && t_pass "carry-over exits 0 with the full staging tree" || t_fail "carry-over exit $rc: $(grep -E 'MISSING|refus' "$WORK/carry.log" | head -n 4)"
  else
    [[ $rc -eq 1 ]] && grep -q 'MISSING in the live image: /usr/share/grub/themes/companion-os' "$WORK/carry.log" && t_pass "carry-over exits 1 and names the GRUB theme when the staging tree lacks the installed-system parts" || t_fail "carry-over without the themes: rc=$rc"
  fi
  if bash "$CHECK" "$TGT" > "$WORK/check-tgt.log" 2>&1; then t_pass "the carried-over target passes overlay-image-check.sh ($(grep '^== Summary' "$WORK/check-tgt.log"))"; else t_fail "target: $(grep -E '^FAIL' "$WORK/check-tgt.log" | head -n 6)"; fi
  [[ -f "$TGT/etc/motd" ]] && grep -q 'Companion OS' "$TGT/etc/motd" && ! grep -qi 'live medium' "$TGT/etc/motd" && t_pass "the target gets the installed system's motd, not the live medium's" || t_fail "target motd wrong"
  [[ -f "$TGT/usr/share/libalpm/hooks/zz-ci-os-os-release.hook" && -d "$TGT/usr/share/wallpapers/companion/contents/images" ]] && t_pass "the target has the hooks and the wallpaper package" || t_fail "the target lacks hooks or wallpapers"
  before="$(tree_sum "$TGT")"; CI_OS_SOURCE_ROOT="$IMG" bash "$IMG/usr/share/ci-os/installed/carry-over" "$TGT" >/dev/null 2>&1 || true; [[ "$(tree_sum "$TGT")" == "$before" ]] && t_pass "carry-over is idempotent" || t_fail "carry-over changed the target on a second run"
  if bash "$IMG/usr/share/ci-os/installed/carry-over" / >/dev/null 2>&1; then t_fail "carry-over accepted / as the target"; else t_pass "carry-over refuses / as the target"; fi
  if bash "$IMG/usr/share/ci-os/installed/carry-over" "$WORK/does-not-exist" >/dev/null 2>&1; then t_fail "carry-over accepted a missing directory"; else t_pass "carry-over refuses a directory that does not exist"; fi

  # previews for a human
  if [[ -n "${CI_OS_PREVIEW_DIR:-}" ]]; then
    mkdir -p "$CI_OS_PREVIEW_DIR"
    "$IM" "$STAGE/grub/splash.png" -resize 640x360 "$CI_OS_PREVIEW_DIR/grub-menu-background-640x360.png"
    "$IM" "$STAGE/syslinux/splash.png" "$CI_OS_PREVIEW_DIR/syslinux-menu-background-640x480.png"
    "$IM" "$STAGE/airootfs/usr/share/wallpapers/companion/contents/images/1920x1080.jpg" -resize 640x360 "$CI_OS_PREVIEW_DIR/wallpaper-640x360.png"
    "$IM" "$STAGE/airootfs/usr/share/wallpapers/companion/contents/images/3840x2160.jpg" -gravity center -crop 640x360+0+0 +repage "$CI_OS_PREVIEW_DIR/wallpaper-4k-crop-640x360.png"
    echo "info  previews written to $CI_OS_PREVIEW_DIR"
  fi
fi

#=== E: NOTICE agrees with the files it names =====================================================================================
# backends/cachyos/NOTICE says, file by file, what licence text a file carries. Nothing else read it, so it drifted: it once said
# a file stated GPL-3.0-or-later when it states nothing, and listed CC0 files as GPL. This keeps the list and the headers in
# step. It checks what the files SAY; what the law makes of that is for counsel (NOTICE section 6).
echo "== E: NOTICE"
NOTICE="${CACHYOS_NOTICE:-$CACHYOS/NOTICE}"
if [[ ! -f "$NOTICE" ]]; then
  t_fail "no NOTICE at $NOTICE"
else
  grp=""; named=""; n_2a=0; n_2b=0; n_2c=0; n_2d=0; bad_notice=""
  while IFS= read -r line; do
    case "$line" in
      "2a. "*) grp=a; continue ;; "2b. "*) grp=b; continue ;; "2c. "*) grp=c; continue ;; "2d. "*) grp=d; continue ;;
      [3-9].\ *) grp=""; continue ;;
    esac
    [[ -n "$grp" && "$line" == "  * "* ]] || continue
    pat="${line#  \* }"; pat="${pat%%:*}"; pat="${pat%% *}"
    found=0
    for f in "$CACHYOS"/$pat; do
      [[ -e "$f" ]] || continue
      found=1; named="$named $f"
      spdx="$(grep -m1 -oE 'SPDX-License-Identifier: *[A-Za-z0-9.+-]+' "$f" 2>/dev/null | sed 's/.*: *//' || true)"
      case "$grp" in
        a) n_2a=$((n_2a + 1))
           if [[ -n "$spdx" && "$spdx" != GPL-3.0* ]]; then bad_notice="$bad_notice [2a ${f#"$CACHYOS"/}: the file says SPDX $spdx, NOTICE lists it as GPL-derived]"; fi
           if grep -q 'Lifescope' "$f"; then bad_notice="$bad_notice [2a ${f#"$CACHYOS"/}: carries a Lifescope notice, NOTICE lists it as GPL-derived]"; fi ;;
        b) n_2b=$((n_2b + 1))
           if ! head -n 5 "$f" | grep -q 'SPDX-License-Identifier: CC0-1.0'; then bad_notice="$bad_notice [2b ${f#"$CACHYOS"/}: no SPDX-License-Identifier: CC0-1.0 in its header]"; fi ;;
        c) n_2c=$((n_2c + 1))
           if grep -qE 'GPL|General Public Licen' "$f"; then bad_notice="$bad_notice [2c ${f#"$CACHYOS"/}: names the GPL, NOTICE lists it as original code]"; fi
           if ! grep -q 'Lifescope' "$f"; then bad_notice="$bad_notice [2c ${f#"$CACHYOS"/}: carries no Lifescope notice, NOTICE says it does]"; fi ;;
        d) n_2d=$((n_2d + 1))
           if ! head -n 6 "$f" | grep -q 'SPDX-License-Identifier: CC0-1.0'; then bad_notice="$bad_notice [2d ${f#"$CACHYOS"/}: its header no longer says CC0-1.0, which is what NOTICE 2d states]"; fi ;;
      esac
    done
    [[ $found -eq 1 ]] || bad_notice="$bad_notice [NOTICE names $pat, which does not exist]"
  done < "$NOTICE"
  [[ $n_2a -ge 1 && $n_2b -ge 1 && $n_2c -ge 1 && $n_2d -ge 1 ]] \
    && t_pass "NOTICE parses: $n_2a file(s) in 2a (GPL-derived), $n_2b in 2b (CC0 templates), $n_2c in 2c (original), $n_2d in 2d (open)" \
    || t_fail "NOTICE has an empty list (2a=$n_2a 2b=$n_2b 2c=$n_2c 2d=$n_2d): the section headings or the bullet format changed, so nothing below is checked"
  [[ -z "$bad_notice" ]] && t_pass "every path NOTICE names exists and no file's own licence text contradicts its list" || t_fail "NOTICE disagrees with the files:$bad_notice"
  # Every file that carries an SPDX line must be listed, so a new template cannot ship unclassified.
  unlisted=""
  while IFS= read -r f; do
    case " $named " in *" $f "*) ;; *) unlisted="$unlisted ${f#"$CACHYOS"/}" ;; esac
  done < <(grep -rIlE '^[#/* ]*SPDX-License-Identifier:' "$CACHYOS" --exclude=NOTICE --exclude=overlay-brand.sh 2>/dev/null | LC_ALL=C sort)
  [[ -z "$unlisted" ]] && t_pass "every file with an SPDX-License-Identifier line is classified in NOTICE" || t_fail "files with an SPDX-License-Identifier line that NOTICE does not list:$unlisted"
fi

#=== F: the documents agree with the tree =========================================================================================
# Each line below is a claim the review found false against the tree. The pattern is the exact old wording, the condition is the
# fact that made it false, so a later change that makes the claim true again has to change this table too.
echo "== F: the documents"
ARCHDOC="$REPO_ROOT/docs/architecture/cachyos-backend.md"
DOCS=("$CACHYOS/README.md" "$ARCHDOC" "$OVERLAY/README.md" "$OVERLAY/INSTALLED.md" "$HERE/verify-mini-iso.sh")
doc_claim() { # doc_claim <label> <ERE of the stale wording>: fails if any document says it
  local hits d
  hits=""
  for d in "${DOCS[@]}"; do
    [[ -f "$d" ]] || continue
    grep -qiE -- "$2" "$d" && hits="$hits ${d#"$REPO_ROOT"/}"
  done
  [[ -z "$hits" ]] && t_pass "no document says: $1" || t_fail "stale claim ($1) in:$hits"
}
epoch_default="$(sed -n 's/^EPOCH_MODE=\([a-z]*\).*/\1/p' "$SCRIPTS/build-iso.sh" | head -n 1)"
case "$epoch_default" in
  now) doc_claim "the build date defaults to the pinned commit's date (build-iso.sh defaults to --source-date-epoch now)" 'By default it is the committer date'
       grep -q 'By default that is the UTC build day' "$CACHYOS/README.md" && t_pass "README says the date in the file name is the UTC build day by default, as build-iso.sh does" || t_fail "README.md does not say that the file name carries the UTC build day by default (build-iso.sh: EPOCH_MODE=now)" ;;
  pin) grep -q 'By default it is the committer date' "$CACHYOS/README.md" && t_pass "README says the date defaults to the pinned commit's, as build-iso.sh does" || t_fail "README.md does not say the date defaults to the pinned commit's (build-iso.sh: EPOCH_MODE=pin)" ;;
  *) t_fail "cannot read EPOCH_MODE= from build-iso.sh (got '$epoch_default')" ;;
esac
if grep -q '^+LINUX /boot/memtest86+/memtest$' "$OVERLAY/patches/0002-syslinux-companion-os-menu.patch"; then
  doc_claim "the overlay does not fix the BIOS Memtest path (patch 0002 does)" "the overlay's patch does not|fixing it changes a .LINUX. line|BIOS Memtest86\+ path \(|182 passed, 1 failed: the BIOS Memtest"
fi
if grep -q 'render-installer-assets.sh' "$CACHYOS/iso/scripts/in-container/20-build.sh" && grep -q 'render-installer-assets.sh' "$HERE/verify-mini-iso.sh"; then
  doc_claim "20-build.sh stages nothing but render-assets.sh (it also runs render-installer-assets.sh)" 'calls .render-assets.sh. and nothing else|20-build.sh runs nothing else|render-assets.sh did not stage the installer'
else
  t_fail "20-build.sh and verify-mini-iso.sh must both run installer/render-installer-assets.sh (the image has no /usr/share/ci-os/calamares without it)"
fi
if [[ -x "$FILES/usr/lib/systemd/system-generators/companion-vm-timeouts" ]] && grep -q '/usr/lib/systemd/system-generators/companion-vm-timeouts' "$profdef"; then
  doc_claim "the VM generator is not in the overlay, or the desktop was never reached" 'is a decision for the lead|never reached a desktop under emulation|No desktop boot was reached on this host|The desktop was \*\*not reached\*\* in any run'
else
  t_fail "the VM slow-boot generator is not an executable file of the overlay with a file_permissions entry"
fi
if grep -qvE '^[[:space:]]*(#|$)' "$OVERLAY/packages.add"; then
  doc_claim "the overlay adds no package to the live list (packages.add is not empty)" 'adds no package to the live list|live package list unchanged|the live list is unchanged'
fi
doc_claim "a complete list of external endpoints (the table is not exhaustive)" 'every external endpoint'

# Every host that our own scripts and configs name is in the endpoint table, or is a link that nothing contacts.
REFERENCES=" ci.computer docs.ci.computer www.supergrubdisk.org www.memtest.org syslinux.zytor.com hdt-project.org "   # links in os-release, branding and comments
hosts="$( { (cd "$CACHYOS" && grep -rhoIE 'https?://[A-Za-z0-9._-]+' installer provision iso/overlay iso/docker iso/scripts/in-container iso/scripts/build-iso.sh iso/scripts/render-assets.sh upstream.lock 2>/dev/null) | sed -E 's|https?://||; s|\.$||'
          (cd "$CACHYOS" && grep -rhoIE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' installer provision iso/overlay iso/docker iso/scripts/in-container iso/scripts/build-iso.sh iso/scripts/render-assets.sh upstream.lock 2>/dev/null) \
            | grep -vE '^(0\.|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; } | LC_ALL=C sort -u )"
missing_hosts=""
for h in $hosts; do
  case "$REFERENCES" in *" $h "*) continue ;; esac
  grep -qF -- "$h" "$ARCHDOC" 2>/dev/null || missing_hosts="$missing_hosts $h"
done
[[ -n "$hosts" ]] || t_fail "found no host in the scripts and configs: the scan broke"
[[ -z "$missing_hosts" ]] && t_pass "every host the scripts and configs name is in the endpoint table of cachyos-backend.md or is a link nothing contacts ($(printf '%s\n' $hosts | wc -l | tr -d ' ') hosts)" || t_fail "hosts in the scripts or configs that cachyos-backend.md does not mention:$missing_hosts"

echo "== Summary: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
