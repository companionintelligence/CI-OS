#!/usr/bin/env bash
# 20-build.sh: build the Companion OS (CachyOS edition) ISO from the PINNED upstream live profile without ever writing to it.
# Runs INSIDE the bootstrapped container (10-bootstrap.sh), as root, privileged. Replaces upstream's buildiso.sh, which rewrites its
# own tree, `sudo sed`s /usr/bin/mkarchiso, curls an unpinned mirrorlist and dies at `chown $USER` in a container.
#
#   1. fetch the pinned commit, assert commit id, committer time and archiso/ tree id against upstream.lock (ci_check_checkout)
#   2. render-assets.sh (iso/scripts/, optional) writes the brand assets into a staging tree
#   3. replay what upstream's prepare_profile() generates (motd, version/edition tags, environment, pinned mirrorlist,
#      display-manager link, timer masks) into a GENERATED layer, using upstream's own functions; add the build record
#   4. apply-overlay.sh: copy upstream archiso/, patches, generated layer, overlay files, staging layer, packages, profiledef,
#      guards. The overlay wins over generated files; staging wins over both
#   5. upstream's change_grub_version on the merged copy, then assert the pinned checkout is still pristine
#   5b. check-owned.sh: does a package of the image ship a file the build adds? (exact, from the repositories' file lists; a
#      conflict stops the build here instead of 8 minutes into pacstrap)
#   6. stock mkarchiso; checksums, package list and build record next to the ISO. mkarchiso runs with a `mksquashfs` in front of the
#      real one on its PATH (mksquashfs-gate.sh): when mkarchiso is about to squash the assembled airootfs, gate-calamares.sh checks
#      that the installer in it starts (ldd -r on its ELF files, an offscreen start) and stops the build if it does not. The
#      compatibility libraries that make it start on a rolling-release skew come from backends/cachyos/compat-libs.lock and are
#      fetched, verified and staged by stage-compat-libs.sh in step 2 (risk R1, incident 2026-10-18)
#
# Environment (build-iso.sh sets these): CI_OS_VERSION (default 1.0), SOURCE_DATE_EPOCH (default: the pin's commit time),
#   CI_OS_JOBS (mksquashfs threads), CI_OS_PIN (primary|fallback), CI_OS_REPO_ROOT (default: this checkout),
#   CI_OS_OWNERSHIP_CHECK (error, the default | warn | off; see check-owned.sh), CI_OS_REPO_COMMIT, CI_OS_REPO_TREE,
#   CI_OS_REPO_TREE_CHANGED|UNTRACKED|IGNORED (what build-iso.sh measured on the host about the working tree it copied in; the
#   container has no .git; they are copied into the build record, 'unknown' when absent).
#   CI_OS_COMPAT_LIBS=on|off (off: do not stage the compatibility libraries; the gate then has to fail on an image that needs them,
#   this is how the gate was proven), CI_OS_COMPAT_REVIEW=warn|error, CI_OS_GATE_SMOKE_SECONDS (see gate-calamares.sh).
# Test hooks: CI_OS_STOP_AFTER=overlay stops after step 5 (merged profile in $CI_OS_BUILD_DIR/archiso, no mkarchiso, no packages
#   downloaded); CI_OS_STOP_AFTER=validate does that and then lets the stock mkarchiso read the profile inside a network-less
#   namespace, which is archiso's nearest thing to a dry run: it validates the options, prints its settings (image name, volume
#   label, publisher, boot modes, package list), copies airootfs, applies file_permissions, starts pacstrap and stops at the
#   first package-database sync (about 10 seconds); CI_OS_UPSTREAM_REUSE=1 verifies and reuses an existing checkout in $CI_OS_UPSTREAM_DIR instead of fetching;
#   CI_OS_UPSTREAM_DIR, CI_OS_BUILD_DIR, CI_OS_STAGING_DIR, CI_OS_OUT_DIR relocate the work directories.
set -euo pipefail
export LC_ALL=C TZ=UTC

export CI_PROG=build
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

[ "$(id -u)" -eq 0 ] || ci_die "run as root inside the builder container"
REPO="${CI_OS_REPO_ROOT:-$(cd "$CACHYOS_DIR/../.." && pwd)}"
LOCK="${CI_OS_LOCK:-$CACHYOS_DIR/upstream.lock}"
OVERLAY="$CACHYOS_DIR/iso/overlay"
RENDER="$CACHYOS_DIR/iso/scripts/render-assets.sh"
UP="${CI_OS_UPSTREAM_DIR:-/work/upstream}"
BUILD="${CI_OS_BUILD_DIR:-/work/build}"
STAGING="${CI_OS_STAGING_DIR:-/work/staging}"
OUT="${CI_OS_OUT_DIR:-/work/out}"
VERSION="${CI_OS_VERSION:-1.0}"
JOBS="${CI_OS_JOBS:-}"
STOP_AFTER="${CI_OS_STOP_AFTER:-}"

ci_load_lock "$LOCK"
ci_select_pin "${CI_OS_PIN:-primary}"
SDE="${SOURCE_DATE_EPOCH:-$PIN_EPOCH}"
export SOURCE_DATE_EPOCH="$SDE"
BUILD_DAY="$(ci_epoch_fmt "$SDE" %Y%m%d)"
YYMMDD="$(ci_epoch_fmt "$SDE" %y%m%d)"
[ -d "$OVERLAY" ] || ci_die "overlay directory not found: $OVERLAY"
case "$STOP_AFTER" in ''|overlay|validate) ;; *) ci_die "CI_OS_STOP_AFTER must be empty, 'overlay' or 'validate' (got '$STOP_AFTER')" ;; esac
[ "$STOP_AFTER" = overlay ] || command -v mkarchiso >/dev/null 2>&1 || ci_die "mkarchiso not found: run 10-bootstrap.sh first"

ci_log "pin: $PIN_NAME $PIN_SHA   version $VERSION   source date $SDE ($BUILD_DAY)"

retry() { # retry N CMD...: network steps get three tries
  local n="$1" i=1; shift
  until "$@"; do
    [ "$i" -lt "$n" ] || return 1
    ci_warn "attempt $i of $n failed: $*"; i=$((i + 1)); sleep $((i * 3))
  done
}

# umount_under DIR: pacstrap bind-mounts /proc, /sys and /dev INSIDE the work tree. A build that died mid-way can leave them
# mounted, and an rm -rf through them would delete the container's device nodes. Unmount them first, deepest first.
umount_under() {
  local dir="$1" mp left
  [ -d "$dir" ] || return 0
  while IFS= read -r mp; do umount -l "$mp" 2>/dev/null || true; done \
    < <(awk -v d="$dir/" 'index($5, d) == 1 {print $5}' /proc/self/mountinfo | sort -r)
  left="$(awk -v d="$dir/" 'index($5, d) == 1 {print $5}' /proc/self/mountinfo | head -n 1)"
  [ -z "$left" ] || ci_die "$left is still mounted under $dir; refusing to delete the tree (rm -rf would follow it into the container's /proc or /dev)"
}
clean_dir() { umount_under "$1"; rm -rf --one-file-system "$1"; mkdir -p "$1"; }

# 1. upstream ---------------------------------------------------------------------------------------------------------
if [ "${CI_OS_UPSTREAM_REUSE:-0}" = 1 ]; then
  [ -d "$UP/.git" ] || ci_die "CI_OS_UPSTREAM_REUSE=1 but $UP is not a git checkout"
  ci_log "1/6 reusing the upstream checkout in $UP (verified below)"
else
  ci_log "1/6 fetching $UPSTREAM_REPO @ $PIN_SHA"
  rm -rf "$UP"; mkdir -p "$UP"
  git -C "$UP" init -q
  git -C "$UP" remote add origin "$UPSTREAM_REPO"
  if ! retry 3 git -C "$UP" fetch -q --depth 1 origin "$PIN_SHA"; then
    ci_warn "fetching the commit by id failed; fetching the branch history instead"
    retry 3 git -C "$UP" fetch -q --filter=blob:none origin
  fi
  git -C "$UP" checkout -q --detach "$PIN_SHA"
fi
ci_check_checkout "$UP" "$PIN_SHA" "$PIN_EPOCH" "$PIN_TREE"
ci_log "    HEAD, committer time and archiso/ tree match the pin"

clean_dir "$BUILD"; clean_dir "$STAGING"; clean_dir "$OUT"
GEN="$BUILD/generated"; WORK_PROFILE="$BUILD/archiso"; REPORT="$BUILD/overlay-report.env"

# 2. brand assets -----------------------------------------------------------------------------------------------------
if [ -f "$RENDER" ]; then
  ci_log "2/6 render-assets.sh -> $STAGING"
  CI_OS_STAGING_DIR="$STAGING" CI_OS_REPO_ROOT="$REPO" CI_OS_VERSION="$VERSION" CI_OS_BUILD_DAY="$BUILD_DAY" \
    bash "$RENDER"
else
  ci_log "2/6 no render-assets.sh: the staging tree stays empty"
fi
# The installer overlay (Calamares branding, module configs, guards, the first-boot provisioning payload) is staged into the
# same tree. It is NOT optional: without it the image has no /usr/share/ci-os/calamares and the launcher refuses to install.
INSTALLER_STAGE="$CACHYOS_DIR/installer/render-installer-assets.sh"
[ -f "$INSTALLER_STAGE" ] || ci_die "missing build input: $INSTALLER_STAGE"
ci_log "2/6 render-installer-assets.sh -> $STAGING"
CI_OS_STAGING_DIR="$STAGING" CI_OS_REPO_ROOT="$REPO" CI_OS_VERSION="$VERSION" CI_OS_BUILD_DAY="$BUILD_DAY" \
  bash "$INSTALLER_STAGE"
# The libraries of the previous generation that cachyos-calamares-next still needs (compat-libs.lock). NOT optional either: a build
# without them is exactly the ISO of 2026-10-18 whose installer did not start; CI_OS_COMPAT_LIBS=off exists to prove the gate.
COMPAT_LOCK="$CACHYOS_DIR/compat-libs.lock"
COMPAT_REPORT="$BUILD/compat-report.env"
ci_log "2/6 stage-compat-libs.sh -> $STAGING"
CI_OS_STAGING_DIR="$STAGING" CI_OS_COMPAT_LOCK="$COMPAT_LOCK" CI_OS_COMPAT_REPORT_FILE="$COMPAT_REPORT" \
  bash "$SCRIPT_DIR/stage-compat-libs.sh" stage
STAGING_DIGEST="$(ci_tree_digest "$STAGING")"

# Provenance. The container holds a tar of the working tree, not a repository: stage-installer.sh therefore takes EVERY file of
# core/headless/payload (its `git ls-files` branch cannot run here), tracked or not. build-iso.sh warns about strays on the host;
# this records what was really used, so a stray cannot ship unnoticed: the list goes into the log, its digest into the record.
REPO_COMMIT="$(ci_env_value CI_OS_REPO_COMMIT '^([0-9a-f]{40}|unknown)$' unknown)"
REPO_TREE="$(ci_env_value CI_OS_REPO_TREE '^(clean|dirty|unknown)$' unknown)"
REPO_TREE_CHANGED="$(ci_env_value CI_OS_REPO_TREE_CHANGED '^([0-9]+|unknown)$' unknown)"
REPO_TREE_UNTRACKED="$(ci_env_value CI_OS_REPO_TREE_UNTRACKED '^([0-9]+|unknown)$' unknown)"
REPO_TREE_IGNORED="$(ci_env_value CI_OS_REPO_TREE_IGNORED '^([0-9]+|unknown)$' unknown)"
subset_digest() { # one digest over every directory of repo-subset.txt that exists, as the container received it
  local d
  while IFS= read -r d; do
    [ -d "$REPO/$d" ] || continue
    printf '%s %s\n' "$d" "$(ci_tree_digest "$REPO/$d" tar-view)"
  done < <(ci_strip_list "$CACHYOS_DIR/iso/scripts/repo-subset.txt") | ci_sha256_stdin
}
REPO_SUBSET_DIGEST="$(subset_digest)"
PAYLOAD_DIR="$REPO/core/headless/payload"
PAYLOAD_LIST=""
if [ -d "$PAYLOAD_DIR" ]; then
  PAYLOAD_LIST="$(cd "$PAYLOAD_DIR" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    ci_tar_excluded "${f#./}" || printf '%s  %s\n' "$(ci_sha256_file "$f")" "${f#./}"
  done)"
fi
PAYLOAD_FILES="$(printf '%s\n' "$PAYLOAD_LIST" | awk 'NF { n++ } END { print n + 0 }')"
PAYLOAD_DIGEST="$(printf '%s\n' "$PAYLOAD_LIST" | ci_sha256_stdin)"
ci_log "    working tree: commit $REPO_COMMIT, $REPO_TREE (changed $REPO_TREE_CHANGED, untracked $REPO_TREE_UNTRACKED, ignored $REPO_TREE_IGNORED); copied subset digest $REPO_SUBSET_DIGEST"
ci_log "    headless payload: $PAYLOAD_FILES file(s), list digest $PAYLOAD_DIGEST"
printf '%s\n' "$PAYLOAD_LIST" | sed -e '/^$/d' -e 's/^/        /'

# 3. generated layer --------------------------------------------------------------------------------------------------
ci_log "3/6 generated layer (upstream prepare_profile() equivalents, pinned mirrorlist, build record)"
GENSRC="$BUILD/gensrc"
mkdir -p "$GEN/airootfs/etc/systemd/system" "$GEN/airootfs/etc/pacman.d" "$GEN/airootfs/usr/share/ci-os" "$GENSRC/archiso/airootfs/etc"
(
  # Upstream's own heredoc writers, run against a scratch tree; only function definitions are sourced.
  set +u
  # shellcheck disable=SC2034  # read by upstream's util-iso.sh
  src_dir="$GENSRC"
  # shellcheck disable=SC1091
  source "$UP/util-msg.sh"
  # shellcheck disable=SC1091
  source "$UP/util-iso.sh"
  generate_motd
  generate_environment desktop
  generate_version_tag desktop "$YYMMDD"
  generate_edition_tag desktop
)
cp -pPR "$GENSRC/archiso/airootfs/." "$GEN/airootfs/"
rm -rf "$GENSRC"

mirror_url="https://raw.githubusercontent.com/$MIRRORLIST_REPO/$MIRRORLIST_REF/$MIRRORLIST_PATH"
mirrorlist="$GEN/airootfs/etc/pacman.d/cachyos-mirrorlist"
retry 3 curl -fsSL "$mirror_url" -o "$mirrorlist"
ci_check_sha256 "$mirrorlist" "$MIRRORLIST_SHA256" "cachyos-mirrorlist from $mirror_url"
MIRRORLIST_ACTUAL="$(ci_sha256_file "$mirrorlist")"      # what was fetched, not what the lock says: the record then shows a check that was weakened
ln -sf /usr/lib/systemd/system/plasmalogin.service "$GEN/airootfs/etc/systemd/system/display-manager.service"   # util-iso.sh:146
ln -sf /dev/null "$GEN/airootfs/etc/systemd/system/cachyos-rate-mirrors.timer"                                  # util-iso.sh:139
# replaces util-iso.sh:modify_mkarchiso (a sudo sed on /usr/bin/mkarchiso): mask the timer instead of editing the tool
ln -sf /dev/null "$GEN/airootfs/etc/systemd/system/archlinux-keyring-wkd-sync.timer"

tool_version() { pacman -Q "$1" 2>/dev/null | awk '{print $2}' || true; }
build_info() { # build_info FILE: everything known before the ISO exists
  {
    printf 'CI_OS_EDITION=cachyos-plasma\n'
    printf 'CI_OS_VERSION=%s\n' "$VERSION"
    printf 'BUILD_DAY=%s\n' "$BUILD_DAY"
    printf 'SOURCE_DATE_EPOCH=%s\n' "$SDE"
    printf 'UPSTREAM_PIN=%s\n' "$PIN_NAME"
    printf 'UPSTREAM_REPO=%s\n' "$UPSTREAM_REPO"
    printf 'UPSTREAM_SHA=%s\n' "$PIN_SHA"
    printf 'UPSTREAM_ARCHISO_TREE=%s\n' "$PIN_TREE"
    printf 'BASE_IMAGE=%s\n' "$BASE_IMAGE"
    printf 'MIRRORLIST_REF=%s\n' "$MIRRORLIST_REF"
    printf 'MIRRORLIST_SHA256=%s\n' "$MIRRORLIST_ACTUAL"
    printf 'CACHYOS_KEY_FPR=%s\n' "$CACHYOS_KEY_FPR"
    printf 'OVERLAY_SHA256=%s\n' "$OVERLAY_DIGEST"
    printf 'STAGING_SHA256=%s\n' "$STAGING_DIGEST"
    printf 'REPO_COMMIT=%s\n' "$REPO_COMMIT"
    printf 'REPO_TREE=%s\n' "$REPO_TREE"
    printf 'REPO_TREE_CHANGED=%s\n' "$REPO_TREE_CHANGED"
    printf 'REPO_TREE_UNTRACKED=%s\n' "$REPO_TREE_UNTRACKED"
    printf 'REPO_TREE_IGNORED=%s\n' "$REPO_TREE_IGNORED"
    printf 'REPO_SUBSET_SHA256=%s\n' "$REPO_SUBSET_DIGEST"
    printf 'PAYLOAD_FILES=%s\n' "$PAYLOAD_FILES"
    printf 'PAYLOAD_SHA256=%s\n' "$PAYLOAD_DIGEST"
    # what the compatibility step staged (stage-compat-libs.sh report; only KEY=VALUE lines of that shape are copied)
    grep -E '^COMPAT_[A-Z0-9_]+=[A-Za-z0-9._,:+@/-]*$' "$COMPAT_REPORT" 2>/dev/null || printf 'COMPAT_LIBS=unknown\n'
    for t in archiso grub squashfs-tools libisoburn arch-install-scripts pacman cachyos-keyring; do
      printf 'TOOL_%s=%s\n' "$(printf '%s' "$t" | tr 'a-z-' 'A-Z_')" "$(tool_version "$t")"
    done
    for db in /var/lib/pacman/sync/*.db; do
      [ -f "$db" ] && printf 'PACMAN_DB_%s=%s\n' "$(basename "$db" .db)" "$(ci_sha256_file "$db")"
    done
  } > "$1"
}
OVERLAY_DIGEST="$(ci_tree_digest "$OVERLAY")"
build_info "$GEN/airootfs/usr/share/ci-os/iso-build-info"
chmod 644 "$GEN/airootfs/usr/share/ci-os/iso-build-info"

# 4. overlay ----------------------------------------------------------------------------------------------------------
ci_log "4/6 apply-overlay.sh"
UPSTREAM_ARCHISO_DIR="$UP/archiso" OVERLAY_DIR="$OVERLAY" WORK_ARCHISO_DIR="$WORK_PROFILE" \
CI_OS_STAGING_DIR="$STAGING" CI_OS_GENERATED_DIR="$GEN" CI_OS_LOCK="$LOCK" CI_OS_JOBS="$JOBS" CI_OS_REPORT_FILE="$REPORT" \
  bash "$SCRIPT_DIR/apply-overlay.sh"
report() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$REPORT"; }
ISO_FILE="$(report ISO_FILE)"; INSTALL_DIR="$(report INSTALL_DIR)"
[ -n "$ISO_FILE" ] && [ -n "$INSTALL_DIR" ] || ci_die "apply-overlay.sh left no usable report in $REPORT"
BASE="${ISO_FILE%.iso}"

# 5. upstream's grub version stamp, then prove upstream was not touched -------------------------------------------------
(
  set +u
  # shellcheck disable=SC2034  # read by upstream's util-iso.sh
  src_dir="$BUILD"        # util-iso.sh addresses ${src_dir}/archiso/grub/grub.cfg: the merged COPY, not the checkout
  # shellcheck disable=SC1091
  source "$UP/util-msg.sh"
  # shellcheck disable=SC1091
  source "$UP/util-iso.sh"
  change_grub_version "$YYMMDD"
)
[ -z "$(git -C "$UP" status --porcelain)" ] || ci_die "the pinned upstream checkout was modified during the build: $(git -C "$UP" status --short | head -n 5 | tr '\n' ' ')"
ci_log "5/6 merged profile ready: $WORK_PROFILE  (iso: $ISO_FILE)"
if [ "$STOP_AFTER" = overlay ]; then
  ci_log "CI_OS_STOP_AFTER=overlay: stopping before mkarchiso"
  exit 0
fi
CI_OS_OWNERSHIP_CHECK="${CI_OS_OWNERSHIP_CHECK:-error}" WORK_ARCHISO_DIR="$WORK_PROFILE" UPSTREAM_ARCHISO_DIR="$UP/archiso" \
  bash "$SCRIPT_DIR/check-owned.sh"

# The installer gate. Stock mkarchiso calls `mksquashfs <airootfs> <image>` by that bare name once the packages are installed, the
# overlay is copied and the image is cleaned up; a program of that name that comes first on PATH sees the finished tree and can stop the
# build before it is squashed, without editing the tool (the shim runs gate-calamares.sh, then execs the real mksquashfs).
# The marker proves the shim ran: a profile that stops using mksquashfs (erofs) would otherwise skip the gate without a word.
GATE_BIN="$BUILD/gate-bin"; GATE_MARKER="$BUILD/gate-calamares.passed"
REAL_MKSQUASHFS="$(command -v mksquashfs || true)"
[ -n "$REAL_MKSQUASHFS" ] || ci_die "mksquashfs not found: install squashfs-tools (mkarchiso needs it)"
mkdir -p "$GATE_BIN"
install -m 0755 "$SCRIPT_DIR/mksquashfs-gate.sh" "$GATE_BIN/mksquashfs"
rm -f "$GATE_MARKER"
if [ "$STOP_AFTER" = validate ]; then
  ci_log "CI_OS_STOP_AFTER=validate: mkarchiso reads the profile with no network; it has to stop at the package database sync"
  unshare --net true 2>/dev/null || ci_die "cannot create a network namespace here (unshare --net needs --privileged or --cap-add SYS_ADMIN)"
  VLOG="$BUILD/validate.log"; VWORK="$BUILD/work-validate"
  rc=0
  PATH="$GATE_BIN:$PATH" unshare --net timeout 300 mkarchiso -v -w "$VWORK" -o "$OUT" "$WORK_PROFILE" > "$VLOG" 2>&1 || rc=$?
  umount_under "$VWORK"
  grep -q "Image file name: *$ISO_FILE\$" "$VLOG" || { tail -n 25 "$VLOG" >&2; ci_die "mkarchiso did not accept the profile (no 'Image file name: $ISO_FILE' line); log: $VLOG"; }
  grep -q 'Installing packages to' "$VLOG" || { tail -n 25 "$VLOG" >&2; ci_die "mkarchiso stopped before it reached the package installation; log: $VLOG"; }
  [ "$rc" -ne 0 ] || ci_die "mkarchiso succeeded without a network: the namespace did not isolate it, and an ISO may have been written to $OUT"
  grep -qE 'Could not resolve host|failed to synchronize all databases' "$VLOG" || { tail -n 25 "$VLOG" >&2; ci_die "mkarchiso failed, but not at the network step; log: $VLOG"; }
  sed -n 's/^\[mkarchiso\] INFO: *\(Image file name\|ISO volume label\|ISO publisher\|ISO application\|Boot modes\):/    \1:/p' "$VLOG"
  ci_log "mkarchiso accepted the profile and stopped at the first package database sync, as expected (log: $VLOG)"
  exit 0
fi

# 6. mkarchiso --------------------------------------------------------------------------------------------------------
ci_log "6/6 mkarchiso ($(pacman -Q archiso)); the squashfs step prints nothing for ~10 minutes, that is not a hang"
MKLOG="$BUILD/mkarchiso.log"
cd "$BUILD"
set +e
CI_OS_REAL_MKSQUASHFS="$REAL_MKSQUASHFS" CI_OS_GATE_SCRIPT="$SCRIPT_DIR/gate-calamares.sh" CI_OS_GATE_MARKER="$GATE_MARKER" \
CI_OS_COMPAT_LOCK="$COMPAT_LOCK" PATH="$GATE_BIN:$PATH" \
  mkarchiso -v -w "$BUILD/work" -o "$OUT" "$WORK_PROFILE" 2>&1 | while IFS= read -r l; do printf '%(%T)T %s\n' -1 "$l"; done | tee "$MKLOG"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
  ci_err "mkarchiso failed (exit $rc). Last lines:"
  tail -n 40 "$MKLOG" >&2
  if grep -q 'exists in filesystem' "$MKLOG"; then
    ci_err "hint: a file in the overlay is also shipped by a package ('exists in filesystem'). Move it (see guard (b)), or handle it with a PostTransaction pacman hook."
  fi
  if grep -qi 'no space left' "$MKLOG"; then ci_err "hint: the docker VM is out of disk space (a build needs about 25 GiB)"; fi
  if grep -q 'THE CALAMARES GATE FAILED' "$MKLOG"; then ci_err "the installer gate stopped the build before the image was squashed (see the lines above; fix: backends/cachyos/compat-libs.lock)"; fi
  exit "$rc"
fi
[ -s "$GATE_MARKER" ] || ci_die "mkarchiso finished but the installer gate never ran (no $GATE_MARKER): mkarchiso did not call mksquashfs through PATH, so the image was NOT checked. Extend mksquashfs-gate.sh for the new image type before shipping this ISO."
ci_log "installer gate: $(cat "$GATE_MARKER")"

iso="$OUT/$ISO_FILE"
[ -f "$iso" ] || ci_die "mkarchiso succeeded but $ISO_FILE is not in $OUT (found: $(find "$OUT" -maxdepth 1 -type f | tr '\n' ' ')). The profile's iso_name/iso_version and the lock disagree."
[ "$(find "$OUT" -maxdepth 1 -name '*.iso' | wc -l)" -eq 1 ] || ci_die "more than one ISO in $OUT"
size="$(stat -c %s "$iso")"
[ "$size" -gt 1000000000 ] || ci_warn "the ISO is only $size bytes; the live image is normally about 3 GB"
cp "$BUILD/work/iso/$INSTALL_DIR/pkglist.x86_64.txt" "$OUT/$BASE.pkgs.txt"
(cd "$OUT" && sha256sum "$ISO_FILE" > "$ISO_FILE.sha256")
{
  cat "$GEN/airootfs/usr/share/ci-os/iso-build-info"
  printf 'PATCH_COUNT=%s\nPATCHES_SHA256=%s\nPACKAGES_TOTAL=%s\nPACKAGES_SHA256=%s\nWORK_PROFILE_SHA256=%s\n' \
    "$(report PATCH_COUNT)" "$(report PATCHES_SHA256)" "$(report PACKAGES_TOTAL)" "$(report PACKAGES_SHA256)" "$(report WORK_PROFILE_SHA256)"
  printf 'KERNEL_LINES_CHANGED=%s\nKERNEL_LINES_SHA256=%s\n' "$(report KERNEL_LINES_CHANGED)" "$(report KERNEL_LINES_SHA256)"
  printf 'ISO_FILE=%s\nISO_BYTES=%s\nISO_SHA256=%s\n' "$ISO_FILE" "$size" "$(awk '{print $1}' "$OUT/$ISO_FILE.sha256")"
} > "$OUT/$BASE.build-info"
ci_log "done: $iso ($(du -h "$iso" | cut -f1))"
(cd "$OUT" && cat "$ISO_FILE.sha256")
