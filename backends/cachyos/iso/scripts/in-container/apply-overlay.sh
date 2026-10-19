#!/usr/bin/env bash
# apply-overlay.sh: merge the Companion OS overlay onto a throw-away copy of upstream's archiso/ profile, then run the
# guards that make upstream drift and overlay mistakes fail HERE (seconds) instead of 20 minutes into mkarchiso.
# Stand-alone and container-free on purpose: tests/overlay-engine.sh runs it on a fake tree, on macOS and Linux alike
# (bash 3.2 + BSD or GNU userland). Upstream is never written to.
#
# Inputs (environment):
#   UPSTREAM_ARCHISO_DIR  the pinned upstream checkout's archiso/ directory                       (required, read-only)
#   OVERLAY_DIR           backends/cachyos/iso/overlay                                            (required)
#                           files/                    merged over the copy (files/airootfs/..., files/grub/..., files/syslinux/...)
#                           patches/NNNN-*.patch      `git apply -p1`, exact context, applied in name order, any failure is fatal
#                           packages.add|remove       one package per line, # comments; removing a package upstream lacks is fatal
#                           profiledef.append.sh      appended to profiledef.sh (mkarchiso drops modes: list every executable there)
#                           package-owned-ok.txt      "ABSOLUTE_PATH | justification" per line; exempts a path from guard (b)
#   WORK_ARCHISO_DIR      where the merged profile is written; must not exist or be empty        (required)
#   CI_OS_STAGING_DIR     optional: tree rendered by render-assets.sh, same shape as OVERLAY_DIR/files; merged AFTER files/
#   CI_OS_GENERATED_DIR   optional: what upstream's own build script would generate (motd, mirrorlist ...), same shape as the
#                         archiso dir; merged after the patches and BEFORE files/, so any overlay file wins over it
#   SOURCE_DATE_EPOCH     the instant iso_version and iso_label are computed from                 (default: now, with a warning)
#   CI_OS_LOCK            upstream.lock, for the edition identity                                 (default: backends/cachyos/upstream.lock)
#   CI_OS_JOBS            optional: mksquashfs -processors N (appended to profiledef.sh)
#   CI_OS_REPORT_FILE     optional: KEY=VALUE report (ISO_FILE, ISO_LABEL, digests, counts) for the caller
#
# Order: copy upstream -> patches -> generated layer -> overlay files -> staging layer -> packages -> profiledef -> guards.
# Guards (all violations are collected and printed together; any one fails the run):
#   (a) the `linux`/`initrd` lines of grub/grub.cfg and grub/loopback.cfg and the LINUX/INITRD/APPEND/KERNEL lines of
#       syslinux/*.cfg are byte-identical to upstream's, except where a PATCH changes them and carries the line
#       "# ci-os: allow-kernel-line-change" (those lines decide whether the live system finds its medium and boots). The marker
#       licenses patches and nothing else: whatever the generated layer, overlay/files or the staging layer add on top is
#       compared with the state right after the patches, so a marked patch does not switch the guard off for the rest of the
#       profile. Which lines a marked patch may touch is not checked here: tests/overlay-brand.sh pins the one real change.
#   (b) no overlay file in a package-owned location (/usr/lib, /usr/share except /usr/share/ci-os, /usr/share/wallpapers/companion*
#       and companion-* / ci-os-* launchers in /usr/share/applications, /usr/bin, /usr/sbin, /usr/include, /etc/xdg, /opt, /boot)
#       unless package-owned-ok.txt lists it with a justification: pacstrap aborts on a file that a package also ships, and
#       only `backup=` files may be overridden. /etc is NOT judged here (most of upstream's overlay lives there); the build tells.
#   (c) every executable file under airootfs has a file_permissions entry with an owner-execute mode in the final profiledef.sh
#   (d) iso_name, iso_label, iso_version, iso_publisher, iso_application and install_dir match the edition identity in the lock
#       (label <= 32 chars of [A-Z0-9_], none of the five contains "cachy") -- iso_* assignments must be one-liners
#   (e) the package list still has syslinux, grub and mkinitcpio-archiso; the overlay may not carry profiledef.sh or packages lists
#
# Exit: 0 merged and all guards passed, 1 patch/guard failure, 2 usage.
set -euo pipefail
export LC_ALL=C

export CI_PROG=apply-overlay
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) ci_err "takes no arguments, it is configured by environment (see --help)"; exit 2 ;;
esac

abs_dir() { (cd "$1" 2>/dev/null && pwd) || return 1; }

[ -n "${UPSTREAM_ARCHISO_DIR:-}" ] || { ci_err "UPSTREAM_ARCHISO_DIR is not set"; exit 2; }
[ -n "${OVERLAY_DIR:-}" ]          || { ci_err "OVERLAY_DIR is not set"; exit 2; }
[ -n "${WORK_ARCHISO_DIR:-}" ]     || { ci_err "WORK_ARCHISO_DIR is not set"; exit 2; }
UP="$(abs_dir "$UPSTREAM_ARCHISO_DIR")" || ci_die "UPSTREAM_ARCHISO_DIR is not a directory: $UPSTREAM_ARCHISO_DIR"
OV="$(abs_dir "$OVERLAY_DIR")"          || ci_die "OVERLAY_DIR is not a directory: $OVERLAY_DIR"
[ -f "$UP/profiledef.sh" ] || ci_die "$UP has no profiledef.sh: not an archiso profile"
STAGING=""; GEN=""
if [ -n "${CI_OS_STAGING_DIR:-}" ]; then STAGING="$(abs_dir "$CI_OS_STAGING_DIR")" || ci_die "CI_OS_STAGING_DIR is not a directory: $CI_OS_STAGING_DIR"; fi
if [ -n "${CI_OS_GENERATED_DIR:-}" ]; then GEN="$(abs_dir "$CI_OS_GENERATED_DIR")" || ci_die "CI_OS_GENERATED_DIR is not a directory: $CI_OS_GENERATED_DIR"; fi
if [ -e "$WORK_ARCHISO_DIR" ]; then
  [ -d "$WORK_ARCHISO_DIR" ] || ci_die "WORK_ARCHISO_DIR exists and is not a directory: $WORK_ARCHISO_DIR"
  [ -z "$(ls -A "$WORK_ARCHISO_DIR")" ] || ci_die "WORK_ARCHISO_DIR is not empty: $WORK_ARCHISO_DIR (the engine only writes a fresh copy; remove it first)"
fi
mkdir -p "$WORK_ARCHISO_DIR"
WORK="$(abs_dir "$WORK_ARCHISO_DIR")"
case "$WORK" in "$UP"|"$UP"/*|"$OV"|"$OV"/*) ci_die "WORK_ARCHISO_DIR must not be inside the upstream or overlay directory" ;; esac

LOCK="${CI_OS_LOCK:-$SCRIPT_DIR/../../../upstream.lock}"
ci_load_lock "$LOCK"
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH="$(date +%s)"
  ci_warn "SOURCE_DATE_EPOCH is not set; using now ($SOURCE_DATE_EPOCH). The ISO name and label will change with the day."
fi
export SOURCE_DATE_EPOCH

TMP="$(mktemp -d "${TMPDIR:-/tmp}/apply-overlay.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

VIOLATIONS=()
violation() { VIOLATIONS+=("$*"); }

# git apply must treat the work directory as a plain directory, never as part of some enclosing repository.
git_apply() { (cd "$WORK" && GIT_CEILING_DIRECTORIES="$(dirname "$WORK")" git apply -p1 --whitespace=nowarn "$@"); }

# --- helpers -------------------------------------------------------------------------------------------------------
# list_nondirs DIR: relative paths of everything that is not a directory (files and symlinks), sorted, no leading ./
list_nondirs() { (cd "$1" && find . -mindepth 1 ! -type d | sed 's|^\./||' | LC_ALL=C sort); }
list_dirs()    { (cd "$1" && find . -mindepth 1 -type d | sed 's|^\./||' | LC_ALL=C sort); }

# merge_tree SRC DST: copy SRC over DST. A file or symlink replaces whatever is at its path (a symlink is replaced, never written
# through); a type clash (file over directory or the reverse) is a violation, not a silent surprise.
merge_tree() {
  local src="$1" dst="$2" rel target
  [ -d "$src" ] || return 0
  while IFS= read -r rel; do
    target="$dst/$rel"
    if { [ -e "$target" ] || [ -L "$target" ]; } && [ ! -d "$target" ]; then
      violation "type clash: '$rel' is a directory in $src but not in the profile"; continue
    fi
    mkdir -p "$target"
  done < <(list_dirs "$src")
  while IFS= read -r rel; do
    target="$dst/$rel"
    if [ -d "$target" ] && [ ! -L "$target" ]; then
      violation "type clash: '$rel' is a file in $src but a directory in the profile"; continue
    fi
    if [ -e "$(dirname "$target")" ] && [ ! -d "$(dirname "$target")" ]; then
      violation "type clash: '$rel' sits below a path that is a file in the profile"; continue
    fi
    mkdir -p "$(dirname "$target")"
    rm -f "$target"
    if [ -L "$src/$rel" ]; then ln -s "$(readlink "$src/$rel")" "$target"; else cp -p "$src/$rel" "$target"; fi
  done < <(list_nondirs "$src")
}

# kernel_lines DIR: the lines that decide how the live system boots, prefixed by file. Compared byte for byte.
kernel_lines() {
  local dir="$1" f
  for f in grub/grub.cfg grub/loopback.cfg; do
    if [ -f "$dir/$f" ]; then { grep -E '^[[:space:]]*(linux|initrd)[[:space:]]' "$dir/$f" || true; } | sed "s|^|$f: |"; fi
  done
  for f in "$dir"/syslinux/*.cfg; do
    if [ -f "$f" ]; then { grep -iE '^[[:space:]]*(linux|initrd|append|kernel)[[:space:]]' "$f" || true; } | sed "s|^|syslinux/$(basename "$f"): |"; fi
  done
}
kernel_digest() { kernel_lines "$1" | ci_sha256_stdin; }

# profile_var FILE NAME: evaluate the LAST top-level `NAME=...` line of profiledef.sh the way mkarchiso would (TZ=UTC, GNU date
# semantics), so that $(date --date="@$SOURCE_DATE_EPOCH" +%Y%m) works on a BSD host as well. One-line assignments only.
profile_var() {
  local file="$1" name="$2" line
  line="$(grep -E "^$name=" "$file" | tail -n 1 || true)"
  [ -n "$line" ] || return 0
  (
    export TZ=UTC
    if ! date --date="@0" +%Y >/dev/null 2>&1; then
      # shellcheck disable=SC2329  # called by the eval'd profiledef line, not by name
      date() {
        local a epoch="" fmt=""
        for a in "$@"; do
          case "$a" in
            --date=@*) epoch="${a#--date=@}" ;;
            @*)        epoch="${a#@}" ;;
            +*)        fmt="$a" ;;
          esac
        done
        if [ -n "$epoch" ]; then command date -u -r "$epoch" "$fmt"; else command date "$@"; fi
      }
    fi
    eval "$line"
    eval "printf '%s' \"\${$name-}\""
  )
}

# perm_mode FILE PATH: the mode (third field of "uid:gid:mode") that profiledef.sh gives PATH, empty if it has no entry.
perm_mode() {
  awk -v p="$2" '
    { sub(/#.*/, "") }
    { dq = "\""; sq = "\047"
      k1 = "[" dq p dq "]="; k2 = "[" sq p sq "]="
      i = index($0, k1); kl = length(k1)
      if (!i) { i = index($0, k2); kl = length(k2) }
      if (i) {
        v = substr($0, i + kl); sub(/^["\047]/, "", v)
        n = split(v, a, "[:\"\047) \t]")
        if (n >= 3) { print a[3]; exit }
      }
    }' "$1"
}

# --- 1. copy upstream ----------------------------------------------------------------------------------------------
ci_log "copy upstream profile  $UP"
cp -pPR "$UP/." "$WORK/"
(cd "$UP" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort) > "$TMP/up.all"
ALLOW_KERNEL_CHANGE=0      # 1 once a patch with the marker has changed kernel lines (reported as KERNEL_LINES_CHANGED)

# --- 2. patches ----------------------------------------------------------------------------------------------------
PATCH_COUNT=0
: > "$TMP/patch.digests"
if [ -d "$OV/patches" ]; then
  for f in "$OV/patches"/*; do
    [ -e "$f" ] || continue
    case "$f" in *.patch) ;; *) ci_die "unexpected file in patches/: $(basename "$f") (only NNNN-name.patch files belong there)" ;; esac
  done
  for p in "$OV/patches"/*.patch; do
    [ -e "$p" ] || continue
    pname="$(basename "$p")"
    before="$(kernel_digest "$WORK")"
    if ! out="$(git_apply --check "$p" 2>&1)"; then
      ci_err "patch $pname does not apply to this upstream (exact context required, no fuzz):"
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      ci_err "upstream has drifted from the pin the patch was written against: port the patch, do not loosen the engine."
      exit 1
    fi
    git_apply "$p"
    after="$(kernel_digest "$WORK")"
    if [ "$before" != "$after" ]; then
      if grep -q '^# ci-os: allow-kernel-line-change' "$p"; then
        ci_warn "patch $pname changes kernel/initrd/append lines (allowed by its '# ci-os: allow-kernel-line-change' marker)"
        ALLOW_KERNEL_CHANGE=1
      else
        violation "patch $pname changes the kernel/initrd/append lines of the boot menus without a '# ci-os: allow-kernel-line-change' line in the patch"
      fi
    fi
    printf '%s  %s\n' "$(ci_sha256_file "$p")" "$pname" >> "$TMP/patch.digests"
    PATCH_COUNT=$((PATCH_COUNT + 1))
    ci_log "patch applied          $pname"
  done
fi
# What the patches left behind is the reference for guard (a): from here on nothing but a patch may move a kernel line.
PATCHED_KERNEL_DIGEST="$(kernel_digest "$WORK")"
kernel_lines "$WORK" | LC_ALL=C sort > "$TMP/kl.patched"
(cd "$WORK" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort) > "$TMP/after-patches.all"
comm -13 "$TMP/up.all" "$TMP/after-patches.all" | while IFS= read -r rel; do
  [ -f "$WORK/$rel" ] && printf '%s\n' "$rel"
done > "$TMP/patch-added.files" || true

# --- 3. generated layer, overlay files, staging layer ------------------------------------------------------------------
if [ -n "$GEN" ]; then
  merge_tree "$GEN" "$WORK"
  ci_log "generated layer merged $GEN"
fi
FILES_COUNT=0
if [ -d "$OV/files" ]; then
  for f in profiledef.sh packages.x86_64 packages_desktop.x86_64 bootstrap_packages.x86_64; do
    [ -e "$OV/files/$f" ] && violation "overlay/files/$f must not exist: change profiledef.sh with profiledef.append.sh and the package list with packages.add/packages.remove"
  done
  merge_tree "$OV/files" "$WORK"
  FILES_COUNT="$(list_nondirs "$OV/files" | wc -l | tr -d ' ')"
  ci_log "overlay files merged   $FILES_COUNT file(s)"
fi
STAGING_COUNT=0
if [ -n "$STAGING" ]; then
  merge_tree "$STAGING" "$WORK"
  STAGING_COUNT="$(list_nondirs "$STAGING" | wc -l | tr -d ' ')"
  ci_log "staging layer merged   $STAGING_COUNT file(s)"
fi

# --- 4. packages ---------------------------------------------------------------------------------------------------
UP_PKGS="$UP/packages_desktop.x86_64"
[ -f "$UP_PKGS" ] || ci_die "upstream has no packages_desktop.x86_64 (the list this edition is built from)"
ci_strip_list "$UP_PKGS" > "$TMP/pkg.up"
ADD_COUNT=0; REMOVE_COUNT=0
: > "$TMP/pkg.remove"; : > "$TMP/pkg.add"
if [ -f "$OV/packages.remove" ]; then
  ci_strip_list "$OV/packages.remove" > "$TMP/pkg.remove"
  while IFS= read -r n; do
    ci_valid_pkg_name "$n" || { violation "packages.remove: '$n' is not a package name (one name per line)"; continue; }
    if ! grep -qxF -- "$n" "$TMP/pkg.up"; then
      ci_err "packages.remove lists '$n', but upstream's packages_desktop.x86_64 no longer has it: upstream drifted. Review the change and drop the line."
      exit 1
    fi
    REMOVE_COUNT=$((REMOVE_COUNT + 1))
  done < "$TMP/pkg.remove"
fi
if [ -f "$OV/packages.add" ]; then
  ci_strip_list "$OV/packages.add" > "$TMP/pkg.add"
  while IFS= read -r n; do
    ci_valid_pkg_name "$n" || { violation "packages.add: '$n' is not a package name (one name per line)"; continue; }
    if grep -qxF -- "$n" "$TMP/pkg.remove"; then violation "package '$n' is in both packages.add and packages.remove"; continue; fi
    if grep -qxF -- "$n" "$TMP/pkg.up"; then ci_warn "packages.add: '$n' is already in upstream's list (redundant, harmless)"; continue; fi
    ADD_COUNT=$((ADD_COUNT + 1))
  done < "$TMP/pkg.add"
fi
{
  printf '# Generated by apply-overlay.sh from upstream packages_desktop.x86_64 minus overlay/packages.remove plus overlay/packages.add.\n'
  grep -vxFf "$TMP/pkg.remove" "$TMP/pkg.up" || true
  while IFS= read -r n; do
    grep -qxF -- "$n" "$TMP/pkg.up" || printf '%s\n' "$n"
  done < "$TMP/pkg.add"
} > "$WORK/packages.x86_64"
ci_strip_list "$WORK/packages.x86_64" > "$TMP/pkg.final"
PKG_TOTAL="$(wc -l < "$TMP/pkg.final" | tr -d ' ')"
ci_log "package list            $PKG_TOTAL package(s): -$REMOVE_COUNT +$ADD_COUNT vs upstream"

# --- 5. profiledef -------------------------------------------------------------------------------------------------
if [ -f "$OV/profiledef.append.sh" ]; then
  {
    printf '\n# --- Companion OS overlay: profiledef.append.sh (appended by apply-overlay.sh; later assignments win) ---\n'
    cat "$OV/profiledef.append.sh"
    printf '\n'
  } >> "$WORK/profiledef.sh"
  ci_log "profiledef.sh          appended profiledef.append.sh"
fi
if [ -n "${CI_OS_JOBS:-}" ]; then
  case "$CI_OS_JOBS" in ''|*[!0-9]*|0) ci_die "CI_OS_JOBS must be a positive number (got '$CI_OS_JOBS')" ;; esac
  {
    printf '\n# --- apply-overlay.sh: limit mksquashfs threads (the container sees every CPU of the VM, --cpus only throttles) ---\n'
    printf "airootfs_image_tool_options+=('-processors' '%s')\n" "$CI_OS_JOBS"
  } >> "$WORK/profiledef.sh"
  ci_log "profiledef.sh          mksquashfs -processors $CI_OS_JOBS"
fi

# --- 6. guards -----------------------------------------------------------------------------------------------------
PROFILEDEF="$WORK/profiledef.sh"

# (a) kernel lines: compared with the state right after the patches (an unmarked patch was reported above, so it is not
# reported twice). With no marked patch that state IS upstream's; with one, the marker licenses that patch's change and
# nothing that the generated layer, overlay/files or the staging layer did afterwards.
FINAL_KERNEL_DIGEST="$(kernel_digest "$WORK")"
if [ "$FINAL_KERNEL_DIGEST" != "$PATCHED_KERNEL_DIGEST" ]; then
  kernel_lines "$WORK" | LC_ALL=C sort > "$TMP/kl.final"
  violation "guard (a): the kernel/initrd/append lines of the boot menus differ from what upstream plus the patches give, so the generated layer, an overlay file or the staging layer changed them (replaced grub.cfg, loopback.cfg or a syslinux menu?). The marker '# ci-os: allow-kernel-line-change' only covers a patch. Only the lines after the patches are in the left column, only the merged profile's in the right:
$(comm -3 "$TMP/kl.patched" "$TMP/kl.final" | sed 's/^/        /')"
fi

# (b) package-owned locations
: > "$TMP/ok.exact"; : > "$TMP/ok.prefix"; : > "$TMP/ok.used"
OKFILE="${CI_OS_PACKAGE_OWNED_OK:-$OV/package-owned-ok.txt}"
if [ -f "$OKFILE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    ok_path="${line%%|*}"; ok_why="${line#*|}"
    [ "$ok_path" != "$line" ] || { violation "package-owned-ok.txt: '$line' has no '|' justification (format: /absolute/path | why this does not conflict)"; continue; }
    ok_path="$(printf '%s' "$ok_path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    ok_why="$(printf '%s' "$ok_why" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$ok_path" in /*) ;; *) violation "package-owned-ok.txt: '$ok_path' is not an absolute image path"; continue ;; esac
    [ "${#ok_why}" -ge 10 ] || { violation "package-owned-ok.txt: '$ok_path' needs a real justification (10+ characters), got '$ok_why'"; continue; }
    case "$ok_path" in */) printf '%s\n' "$ok_path" >> "$TMP/ok.prefix" ;; *) printf '%s\n' "$ok_path" >> "$TMP/ok.exact" ;; esac
  done < "$OKFILE"
fi

is_package_territory() {
  case "$1" in
    /usr/share/ci-os|/usr/share/ci-os/*) return 1 ;;
    /usr/share/wallpapers/companion*) return 1 ;;
    /usr/share/applications/companion-*|/usr/share/applications/ci-os-*) return 1 ;;
    /usr/lib/*|/usr/lib64/*|/usr/share/*|/usr/bin/*|/usr/sbin/*|/usr/include/*|/etc/xdg/*|/opt/*|/boot/*|/var/lib/pacman/*) return 0 ;;
  esac
  return 1
}
is_exempt() {
  local p="$1" pre
  if grep -qxF -- "$p" "$TMP/ok.exact"; then printf '%s\n' "$p" >> "$TMP/ok.used"; return 0; fi
  while IFS= read -r pre; do
    case "$p" in "$pre"*) printf '%s\n' "$pre" >> "$TMP/ok.used"; return 0 ;; esac
  done < "$TMP/ok.prefix"
  return 1
}
# check_owned LABEL: reads relative paths (airootfs/usr/lib/x) on stdin; hits go to owned.hits as label|dir|file
: > "$TMP/owned.hits"
check_owned() {
  local label="$1" rel img
  while IFS= read -r rel; do
    case "$rel" in airootfs/*) ;; *) continue ;; esac
    img="/${rel#airootfs/}"
    if is_package_territory "$img" && ! is_exempt "$img"; then
      printf '%s|%s|%s\n' "$label" "$(dirname "$img")" "$img" >> "$TMP/owned.hits"
    fi
  done
}
if [ -d "$OV/files" ]; then check_owned "overlay/files" < <(list_nondirs "$OV/files"); fi
if [ -n "$STAGING" ]; then check_owned "the staging layer" < <(list_nondirs "$STAGING"); fi
if [ -s "$TMP/patch-added.files" ]; then check_owned "a patch" < "$TMP/patch-added.files"; fi
# one violation per label and directory, not one per file (a rendered theme is dozens of frames)
while IFS='|' read -r o_label o_dir o_count o_first; do
  violation "guard (b): $o_label puts $o_count file(s) in $o_dir (first: $o_first), a location packages own. pacstrap aborts with 'exists in filesystem' when a package ships the same path (only backup= files may be overridden). Use a path of your own (/usr/share/ci-os, /etc/ci-os, /usr/local) or a PostTransaction pacman hook, or, if no package ships it, list the file (or its directory, ending in /) in package-owned-ok.txt with a justification."
done < <(LC_ALL=C sort "$TMP/owned.hits" | awk -F'|' '
  { k = $1 "|" $2; if (k != last) { if (last != "") print last "|" n "|" first; last = k; n = 0; first = $3 } n++ }
  END { if (last != "") print last "|" n "|" first }')
if [ -s "$TMP/ok.exact" ] || [ -s "$TMP/ok.prefix" ]; then
  { cat "$TMP/ok.exact" "$TMP/ok.prefix"; } | while IFS= read -r entry; do
    grep -qxF -- "$entry" "$TMP/ok.used" || ci_warn "package-owned-ok.txt: '$entry' exempts nothing in this overlay (stale entry? remove it)"
  done
fi

# (c) executables need file_permissions entries
check_exec_layer() {
  local label="$1" layer="$2" rel img mode owner
  [ -n "$layer" ] && [ -d "$layer/airootfs" ] || return 0
  while IFS= read -r rel; do
    img="/${rel#airootfs/}"
    mode="$(perm_mode "$PROFILEDEF" "$img")"
    if [ -z "$mode" ]; then
      violation "guard (c): $label has an executable file $img but profiledef.sh has no file_permissions entry for it (mkarchiso would install it without the execute bit). Add [\"$img\"]=\"0:0:755\" to profiledef.append.sh."
      continue
    fi
    owner="$(printf '%s' "$mode" | awk '{print substr($0, length($0) - 2, 1)}')"
    case "$owner" in 1|3|5|7) ;; *) violation "guard (c): $label has an executable file $img but profiledef.sh gives it mode '$mode', which is not executable for the owner." ;; esac
  done < <(cd "$layer" && find airootfs -type f -perm -100 | LC_ALL=C sort)
}
check_exec_layer "overlay/files" "$OV/files"
check_exec_layer "the staging layer" "$STAGING"
check_exec_layer "the generated layer" "$GEN"

# (d) identity
ISO_NAME="$(profile_var "$PROFILEDEF" iso_name)"
ISO_LABEL="$(profile_var "$PROFILEDEF" iso_label)"
ISO_VERSION="$(profile_var "$PROFILEDEF" iso_version)"
ISO_PUBLISHER="$(profile_var "$PROFILEDEF" iso_publisher)"
ISO_APPLICATION="$(profile_var "$PROFILEDEF" iso_application)"
INSTALL_DIR="$(profile_var "$PROFILEDEF" install_dir)"
PROFILE_ARCH="$(profile_var "$PROFILEDEF" arch)"
[ "$ISO_NAME" = "$EDITION_ISO_NAME" ] || violation "guard (d): iso_name is '$ISO_NAME', expected '$EDITION_ISO_NAME' (upstream.lock EDITION_ISO_NAME; set it in profiledef.append.sh)"
case "$ISO_LABEL" in
  "$EDITION_LABEL_PREFIX"[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) violation "guard (d): iso_label is '$ISO_LABEL', expected ${EDITION_LABEL_PREFIX}YYYYMM (evaluated at SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)" ;;
esac
[ "${#ISO_LABEL}" -le 32 ] || violation "guard (d): iso_label '$ISO_LABEL' is longer than the 32 characters an ISO 9660 volume id allows"
case "$ISO_LABEL" in *[!A-Z0-9_]*) violation "guard (d): iso_label '$ISO_LABEL' has characters outside A-Z 0-9 _" ;; esac
printf '%s' "$ISO_VERSION" | grep -qE '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$' || violation "guard (d): iso_version is '$ISO_VERSION', expected YYYY.MM.DD"
EXPECT_VERSION="$(ci_epoch_fmt "$SOURCE_DATE_EPOCH" %Y.%m.%d)"
[ -z "$ISO_VERSION" ] || [ "$ISO_VERSION" = "$EXPECT_VERSION" ] || violation "guard (d): iso_version '$ISO_VERSION' is not the day of SOURCE_DATE_EPOCH ($EXPECT_VERSION)"
[ "$PROFILE_ARCH" = "$EDITION_ARCH" ] || violation "guard (d): arch is '$PROFILE_ARCH', expected '$EDITION_ARCH'"
printf '%s' "$INSTALL_DIR" | grep -qE '^[a-z0-9]{1,30}$' || violation "guard (d): install_dir '$INSTALL_DIR' must be 1-30 characters of [a-z0-9]"
case "$ISO_PUBLISHER" in *Companion*) ;; *) violation "guard (d): iso_publisher '$ISO_PUBLISHER' does not name Companion Intelligence" ;; esac
case "$ISO_APPLICATION" in *Companion\ OS*) ;; *) violation "guard (d): iso_application '$ISO_APPLICATION' does not name Companion OS" ;; esac
for pair in "iso_name=$ISO_NAME" "iso_label=$ISO_LABEL" "iso_publisher=$ISO_PUBLISHER" "iso_application=$ISO_APPLICATION"; do
  if printf '%s' "$pair" | grep -qi 'cachy'; then violation "guard (d): ${pair%%=*} carries the CachyOS mark ('${pair#*=}'); the artifact is named Companion OS (decision D1)"; fi
done

# (e) packages and overlay shape
for n in syslinux grub mkinitcpio-archiso; do
  grep -qxF -- "$n" "$TMP/pkg.final" || violation "guard (e): '$n' is not in the final package list, but mkarchiso needs it for the bios.syslinux/uefi.grub boot modes and the initramfs"
done
for n in memtest86+ memtest86+-efi edk2-shell; do
  grep -qxF -- "$n" "$TMP/pkg.final" || ci_warn "'$n' is not in the final package list: the boot menu loses that entry"
done
[ -d "$WORK/airootfs" ] || violation "guard (e): the merged profile has no airootfs/ directory"

# --- 7. report ---------------------------------------------------------------------------------------------------
if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
  ci_err "${#VIOLATIONS[@]} guard violation(s); the merged profile at $WORK must not be built:"
  for v in "${VIOLATIONS[@]}"; do printf '  - %s\n' "$v" >&2; done
  exit 1
fi

ISO_FILE="${ISO_NAME}-${ISO_VERSION}-${PROFILE_ARCH}.iso"
WORK_DIGEST="$(ci_tree_digest "$WORK")"
PATCHES_DIGEST="$(ci_sha256_stdin < "$TMP/patch.digests")"
PACKAGES_DIGEST="$(ci_sha256_stdin < "$TMP/pkg.final")"
ci_log "guards (a)-(e) passed   iso: $ISO_FILE   label: $ISO_LABEL"
ci_log "merged profile digest   $WORK_DIGEST"
if [ -n "${CI_OS_REPORT_FILE:-}" ]; then
  {
    printf 'ISO_NAME=%s\n' "$ISO_NAME"
    printf 'ISO_LABEL=%s\n' "$ISO_LABEL"
    printf 'ISO_VERSION=%s\n' "$ISO_VERSION"
    printf 'ISO_FILE=%s\n' "$ISO_FILE"
    printf 'INSTALL_DIR=%s\n' "$INSTALL_DIR"
    printf 'PATCH_COUNT=%s\n' "$PATCH_COUNT"
    printf 'PATCHES_SHA256=%s\n' "$PATCHES_DIGEST"
    printf 'OVERLAY_FILE_COUNT=%s\n' "$FILES_COUNT"
    printf 'STAGING_FILE_COUNT=%s\n' "$STAGING_COUNT"
    printf 'PACKAGES_ADDED=%s\n' "$ADD_COUNT"
    printf 'PACKAGES_REMOVED=%s\n' "$REMOVE_COUNT"
    printf 'PACKAGES_TOTAL=%s\n' "$PKG_TOTAL"
    printf 'PACKAGES_SHA256=%s\n' "$PACKAGES_DIGEST"
    printf 'KERNEL_LINES_CHANGED=%s\n' "$ALLOW_KERNEL_CHANGE"
    printf 'KERNEL_LINES_SHA256=%s\n' "$FINAL_KERNEL_DIGEST"
    printf 'WORK_PROFILE_SHA256=%s\n' "$WORK_DIGEST"
  } > "$CI_OS_REPORT_FILE"
fi
