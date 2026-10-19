#!/usr/bin/env bash
#=============================================================================
# Companion OS (CachyOS edition) ISO builder: live + installer ISO from the pinned CachyOS-Live-ISO profile plus the Companion
# OS overlay. Host side: needs only docker (Docker Desktop on Apple silicon runs the amd64 builder under Rosetta; a native
# x86-64 Linux host works too) and bash 3.2+. Runs as a normal user.
#
# Pipeline (one throw-away privileged amd64 container; the host's filesystem is never bind-mounted, see below):
#   1. builder image   ci-os-cachyos-builder:<hash of Dockerfile + key + pins>, built once from iso/docker/Dockerfile.builder
#   2. container       ci-os-cachyos-build, with a per-run work volume and the shared pacman package-cache volume
#   3. docker cp       the repo subset listed in iso/scripts/repo-subset.txt into /work/repo (tar stream, no AppleDouble files)
#   4. 10-bootstrap    [cachyos] repo + key (fingerprint checked), archiso/grub/git and iso/render-deps.txt
#   5. 20-build        clone + verify the pinned upstream; render-assets.sh -> staging tree; apply-overlay.sh (patches, files,
#                      packages, profiledef, guards); upstream's generators replayed into the COPY; stock mkarchiso
#   6. docker cp out   ISO, .sha256, .pkgs.txt, .build-info; hash re-checked on the host; container and work volume removed.
#                      If the build finished but the copy did not, the container and volume are KEPT with the ISO inside, and the
#                      docker cp command that recovers it is printed (the 35 to 60 minutes are not thrown away)
# The ISO is built from the WORKING TREE, not from a commit: step 3 tars the files as they are on disk (the container has no .git).
# The commit, whether the tree was clean, and a digest of what was copied go into the build record; uncommitted, untracked and
# ignored files under the copied subset are listed before the build starts (--require-clean makes that an error).
# Why no bind mount: a macOS bind mount cannot hold device nodes, ownership, xattrs or case-distinct names (research 03, E6).
# Time: about 35 to 60 minutes on a loaded Apple-silicon host (mksquashfs is single-digit MiB/s under emulation); disk: 25 GiB.
# On a laptop run it under `caffeinate -i` so the machine does not sleep half way through the squashfs step.
#
# Usage: backends/cachyos/iso/scripts/build-iso.sh [options]
#   --dry-run, --print-plan   print every input and every docker command, run nothing (docker is not even needed)
#   --out DIR                 output directory (default: <repo>/output)
#   --version VER             Companion OS version for os-release and the build record (default: $CI_OS_VERSION, else 1.0)
#   --stop-after STAGE        overlay | validate: run the pipeline only as far as the merged profile (overlay) or until mkarchiso has
#                             read it with no network (validate, about two minutes, no ISO). The way to check an overlay change.
#   --ownership-check MODE    error (default) | warn | off: before mkarchiso, check from the repositories' file lists that no package of
#                             the image ships a file the build adds to airootfs (a conflict would abort pacstrap 8 minutes in)
#   --fallback-pin            build upstream's fallback commit (UPSTREAM_FALLBACK_SHA in upstream.lock) instead of the primary
#   --source-date-epoch E     now | pin | SECONDS. The instant behind the date in the ISO name, the volume label, the boot UUID and
#                             the os-release build day. Default now (the UTC build day); pin uses the pinned upstream commit's time,
#                             so a rebuild keeps the same file name and a regression build can be compared byte for name.
#   --cpus N                  docker CPU quota (default 8)        --jobs N   mksquashfs threads (default: --cpus)
#   --memory SIZE             docker memory limit (default 16g; mksquashfs peaks near 8 GiB)
#   --unprivileged            --cap-add SYS_ADMIN instead of --privileged (smaller blast radius; only the mount primitives and
#                             a trimmed profile were proven that way, the full desktop profile was built with --privileged)
#   --cache-volume NAME       pacman package cache volume (default ci-os-cachyos-pkgcache, ~2.5 GiB, kept between builds)
#   --rebuild-image           rebuild the builder image even if its tag exists
#   --keep-container          leave the container and work volume behind for inspection (docker rm -f / docker volume rm them)
#   --force                   overwrite existing output files of the same name
#   --require-clean           refuse to build unless every file under the copied subset is exactly what HEAD has (no uncommitted
#                             edit, no untracked file, no ignored file such as a stray .env). Default: list them and build anyway
#   --allow-dirty             build from a dirty tree on purpose and do not list it (the build record says REPO_TREE=dirty anyway)
#   -h, --help
# Environment: CI_OS_VERSION, CI_OS_DOCKER (docker binary, default docker).
# Exit: 0 built and verified, 1 failed or --require-clean refused the tree, 2 usage or missing prerequisite (an unwritable --out too).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

export CI_PROG=build-iso
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # backends/cachyos
REPO_ROOT="$(cd "$CACHYOS_DIR/../.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

LOCK="$CACHYOS_DIR/upstream.lock"
DOCKERFILE="$CACHYOS_DIR/iso/docker/Dockerfile.builder"
DOCKER_CONTEXT="$CACHYOS_DIR/iso/docker"
KEY_FILE="$DOCKER_CONTEXT/cachyos-repo-key.asc"
OVERLAY_DIR="$CACHYOS_DIR/iso/overlay"
RENDER_SCRIPT="$CACHYOS_DIR/iso/scripts/render-assets.sh"
DOCKER="${CI_OS_DOCKER:-docker}"

CONTAINER=ci-os-cachyos-build
WORK_VOL=ci-os-cachyos-work
LABEL_KEY=ci-os.cachyos
IMAGE_REPO=ci-os-cachyos-builder
CT_REPO=/work/repo                                       # repo subset inside the container
CT_BUILD=$CT_REPO/backends/cachyos/iso/scripts/in-container

OUT_DIR="$REPO_ROOT/output"
VERSION="${CI_OS_VERSION:-1.0}"
PIN=primary
EPOCH_MODE=now
CPUS=8
JOBS=""
MEMORY=16g
PRIVILEGED=1
CACHE_VOL=ci-os-cachyos-pkgcache
REBUILD_IMAGE=0
STOP_AFTER=""
OWNERSHIP=error
KEEP=0
FORCE=0
REQUIRE_CLEAN=0
ALLOW_DIRTY=0
DRY=0

usage() { sed -n '2,/^# Exit:/p' "$0" | sed -e 's/^#\{1,2\}\( \{0,1\}\)//' -e '/^=*$/d'; }

# --- arguments -----------------------------------------------------------------------------------------------------
need_arg() {
  [ $# -ge 2 ] && [ -n "$2" ] || { ci_err "$1 needs a value"; exit 2; }
  case "$2" in -*) ci_err "$1 needs a value, but '$2' looks like another option (write ./$2 if that really is the value)"; exit 2 ;; esac
}
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|--print-plan) DRY=1; shift ;;
    --out)               need_arg "$@"; OUT_DIR="$2"; shift 2 ;;
    --version)           need_arg "$@"; VERSION="$2"; shift 2 ;;
    --stop-after)        need_arg "$@"; STOP_AFTER="$2"; shift 2 ;;
    --ownership-check)   need_arg "$@"; OWNERSHIP="$2"; shift 2 ;;
    --fallback-pin)      PIN=fallback; shift ;;
    --source-date-epoch) need_arg "$@"; EPOCH_MODE="$2"; shift 2 ;;
    --cpus)              need_arg "$@"; CPUS="$2"; shift 2 ;;
    --jobs)              need_arg "$@"; JOBS="$2"; shift 2 ;;
    --memory)            need_arg "$@"; MEMORY="$2"; shift 2 ;;
    --unprivileged)      PRIVILEGED=0; shift ;;
    --cache-volume)      need_arg "$@"; CACHE_VOL="$2"; shift 2 ;;
    --rebuild-image)     REBUILD_IMAGE=1; shift ;;
    --keep-container)    KEEP=1; shift ;;
    --force)             FORCE=1; shift ;;
    --require-clean)     REQUIRE_CLEAN=1; shift ;;
    --allow-dirty)       ALLOW_DIRTY=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) ci_err "unknown option: $1 (see --help)"; exit 2 ;;
  esac
done

[ "$REQUIRE_CLEAN" -eq 0 ] || [ "$ALLOW_DIRTY" -eq 0 ] || { ci_err "--require-clean and --allow-dirty contradict each other"; exit 2; }
printf '%s' "$VERSION" | grep -qE '^[0-9A-Za-z][0-9A-Za-z._+~-]*$' || { ci_err "--version '$VERSION' is not a plain version string (letters, digits and . _ + ~ -)"; exit 2; }
case "$OWNERSHIP" in error|warn|off) ;; *) ci_err "--ownership-check must be error, warn or off (got '$OWNERSHIP')"; exit 2 ;; esac
case "$STOP_AFTER" in ''|overlay|validate) ;; *) ci_err "--stop-after must be overlay or validate (got '$STOP_AFTER')"; exit 2 ;; esac
printf '%s' "$CPUS" | grep -qE '^[0-9]+(\.[0-9]+)?$' || { ci_err "--cpus must be a number (got '$CPUS')"; exit 2; }
if [ -z "$JOBS" ]; then JOBS="${CPUS%%.*}"; [ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1; fi
printf '%s' "$JOBS" | grep -qE '^[1-9][0-9]*$' || { ci_err "--jobs must be a positive integer (got '$JOBS')"; exit 2; }
printf '%s' "$MEMORY" | grep -qE '^[0-9]+[kKmMgG]?$' || { ci_err "--memory must look like 16g (got '$MEMORY')"; exit 2; }
printf '%s' "$CACHE_VOL" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || { ci_err "--cache-volume '$CACHE_VOL' is not a valid volume name"; exit 2; }
[ "$CACHE_VOL" != "$WORK_VOL" ] || { ci_err "--cache-volume must differ from the work volume $WORK_VOL"; exit 2; }

ci_load_lock "$LOCK"
ci_select_pin "$PIN"
case "$EPOCH_MODE" in
  pin) SDE="$PIN_EPOCH" ;;
  now) SDE="$(date +%s)" ;;
  *[!0-9]*|'') ci_err "--source-date-epoch must be pin, now or a number of seconds (got '$EPOCH_MODE')"; exit 2 ;;
  *) SDE="$EPOCH_MODE" ;;
esac
ISO_FILE="$(ci_iso_file_name "$SDE")"
BASE="${ISO_FILE%.iso}"
ARTIFACTS="$ISO_FILE $ISO_FILE.sha256 $BASE.pkgs.txt $BASE.build-info $BASE.build.log"

# Builder image tag: changes exactly when something the image is made of changes.
for f in "$DOCKERFILE" "$KEY_FILE"; do [ -f "$f" ] || ci_die "missing build input: $f"; done
IMAGE_HASH="$({ ci_sha256_file "$DOCKERFILE"; ci_sha256_file "$KEY_FILE"; printf '%s\n%s\n' "$BASE_IMAGE" "$CACHYOS_KEY_FPR"; } | ci_sha256_stdin | cut -c1-12)"
IMAGE="$IMAGE_REPO:$IMAGE_HASH"

OVERLAY_STATE=MISSING; OVERLAY_DIGEST="-"
if [ -d "$OVERLAY_DIR" ]; then OVERLAY_STATE=present; OVERLAY_DIGEST="$(ci_tree_digest "$OVERLAY_DIR" tar-view)"; fi    # as copied: equals the container's OVERLAY_SHA256
RENDER_STATE=absent; [ -f "$RENDER_SCRIPT" ] && RENDER_STATE=present

SUBSET_FILE="$SCRIPT_DIR/repo-subset.txt"
[ -f "$SUBSET_FILE" ] || ci_die "missing build input: $SUBSET_FILE"
PUSH_PATHS=""; SUBSET_MISSING=""
while IFS= read -r p; do
  case "$p" in /*|*..*|*[[:space:]]*) ci_die "$SUBSET_FILE: '$p' must be a plain relative path" ;; esac
  if [ -d "$REPO_ROOT/$p" ]; then PUSH_PATHS="$PUSH_PATHS $p"; else SUBSET_MISSING="$SUBSET_MISSING $p"; fi
done < <(ci_strip_list "$SUBSET_FILE")
PUSH_PATHS="${PUSH_PATHS# }"; SUBSET_MISSING="${SUBSET_MISSING# }"

# --- the working tree the ISO will be built from ---------------------------------------------------------------------------
# Step 3 tars the files as they are on disk and the container has no .git, so an uncommitted edit, an untracked file and an
# ignored file (a stray .env, an editor backup) all ship. Measured here (files the tar leaves out do not count), handed to the
# container for the build record, reported before the build starts.
REPO_COMMIT="$(ci_repo_commit "$REPO_ROOT")"
TREE_RC=0
# shellcheck disable=SC2086  # PUSH_PATHS is a list of plain repo paths
TREE_LIST="$(ci_repo_dirty_files "$REPO_ROOT" $PUSH_PATHS)" || TREE_RC=$?
if [ "$TREE_RC" -ne 0 ]; then TREE_STATE=unknown; TREE_LIST=""
elif [ -z "$TREE_LIST" ]; then TREE_STATE=clean
else TREE_STATE=dirty; fi
tree_count() { if [ "$TREE_STATE" = unknown ]; then echo unknown; else printf '%s\n' "$TREE_LIST" | awk -v k="$1" '$1 == k { n++ } END { print n + 0 }'; fi; }
TREE_CHANGED="$(tree_count changed)"; TREE_UNTRACKED="$(tree_count untracked)"; TREE_IGNORED="$(tree_count ignored)"
tree_summary() {
  case "$TREE_STATE" in
    clean)   echo "clean" ;;
    dirty)   echo "DIRTY ($TREE_CHANGED changed, $TREE_UNTRACKED untracked, $TREE_IGNORED ignored)" ;;
    *)       echo "unknown (not a git checkout, or no commit yet)" ;;
  esac
}

# --- command runner: the dry run prints exactly what the real run executes ----------------------------------------------
quote() { local a; for a in "$@"; do printf ' %q' "$a"; done; }
run() {
  if [ "$DRY" -eq 1 ]; then printf '+'; quote "$@"; printf '\n'; else "$@"; fi
}
note() { if [ "$DRY" -eq 1 ]; then printf '# %s\n' "$*"; else ci_log "$*"; fi; }

# push_tree: tar the repo subset (no AppleDouble, no .DS_Store) and stream it into the container.
TAR_EXCLUDES=(); for pat in "${CI_TAR_EXCLUDE_PATTERNS[@]}"; do TAR_EXCLUDES+=("--exclude=$pat"); done     # lib/common.sh: one list for tar, digest and tree check
push_tree() {
  if [ "$DRY" -eq 1 ]; then
    printf '+ COPYFILE_DISABLE=1 tar -cf -'
    # shellcheck disable=SC2086  # PUSH_PATHS is a list of plain repo paths
    quote "${TAR_EXCLUDES[@]}" -C "$REPO_ROOT" $PUSH_PATHS; printf ' | '
    printf '%s cp - %s:%s\n' "$DOCKER" "$CONTAINER" "$CT_REPO"
  else
    # shellcheck disable=SC2086  # PUSH_PATHS is a list of plain repo paths
    COPYFILE_DISABLE=1 tar -cf - "${TAR_EXCLUDES[@]}" -C "$REPO_ROOT" $PUSH_PATHS | "$DOCKER" cp - "$CONTAINER:$CT_REPO"
  fi
}

# --- plan ----------------------------------------------------------------------------------------------------------
print_plan() {
  cat <<EOF
== Companion OS (CachyOS edition) ISO build plan ==
repo              $REPO_ROOT
commit            $REPO_COMMIT   working tree: $(tree_summary)
upstream          $UPSTREAM_REPO
  pin ($PIN_NAME)  $PIN_SHA   committed $(ci_epoch_fmt "$PIN_EPOCH" %Y-%m-%dT%H:%M:%SZ)   archiso/ tree $PIN_TREE
base image        $BASE_IMAGE
builder image     $IMAGE   (Dockerfile + key + pins hash; built only if absent)
CachyOS key       $CACHYOS_KEY_FPR   committed copy: ${KEY_FILE#"$REPO_ROOT"/}
mirrorlist        $MIRRORLIST_REPO@$MIRRORLIST_REF   sha256 $MIRRORLIST_SHA256
overlay           ${OVERLAY_DIR#"$REPO_ROOT"/}: $OVERLAY_STATE   tree digest $OVERLAY_DIGEST (as copied; the build record's OVERLAY_SHA256)
render-assets.sh  $RENDER_STATE (${RENDER_SCRIPT#"$REPO_ROOT"/})
repo subset       ${PUSH_PATHS:-none}${SUBSET_MISSING:+   (not in this checkout: $SUBSET_MISSING)}
version           CI_OS_VERSION=$VERSION
source date       SOURCE_DATE_EPOCH=$SDE ($(ci_epoch_fmt "$SDE" %Y-%m-%dT%H:%M:%SZ), $EPOCH_MODE)
ownership check   $OWNERSHIP
resources         --cpus $CPUS  --jobs $JOBS  --memory $MEMORY  $([ "$PRIVILEGED" -eq 1 ] && echo "--privileged" || echo "--cap-add SYS_ADMIN")
containers        $CONTAINER (work volume $WORK_VOL, cache volume $CACHE_VOL)
output dir        $OUT_DIR
output ISO        $OUT_DIR/$ISO_FILE
artifacts         $([ -n "$STOP_AFTER" ] && echo "none (--stop-after $STOP_AFTER)" || echo "$ARTIFACTS")
EOF
}

# --- preflight -----------------------------------------------------------------------------------------------------
# report_tree: say what is not exactly HEAD in the tree about to be copied. Warns by default, --require-clean refuses,
# --allow-dirty stays quiet (the build record carries the state in every case). A --stop-after run builds no ISO, so by default
# it only notes it: checking an uncommitted overlay change is what that option is for.
report_tree() {
  local n msg
  case "$TREE_STATE" in
    clean) return 0 ;;
    unknown)
      if [ "$REQUIRE_CLEAN" -eq 1 ]; then ci_err "--require-clean: $REPO_ROOT is not a git checkout with a commit, so it cannot be shown to be clean"; exit 1; fi
      [ "$ALLOW_DIRTY" -eq 1 ] || ci_warn "$REPO_ROOT is not a git checkout (or has no commit yet): the build record will say REPO_COMMIT=unknown, REPO_TREE=unknown"
      return 0 ;;
  esac
  [ "$ALLOW_DIRTY" -eq 0 ] || return 0
  if [ "$REQUIRE_CLEAN" -eq 0 ] && [ -n "$STOP_AFTER" ]; then
    ci_log "the working tree is not commit ${REPO_COMMIT:0:12}: $(tree_summary); --stop-after builds no ISO, so nothing of it ships"
    return 0
  fi
  n="$(printf '%s\n' "$TREE_LIST" | awk 'END { print NR }')"
  msg="the ISO is built from the WORKING TREE of $REPO_ROOT, not from commit ${REPO_COMMIT:0:12}: $n file(s) under the copied subset are not what that commit has ($TREE_CHANGED changed = differ from HEAD, staged or not; $TREE_UNTRACKED untracked; $TREE_IGNORED ignored):"
  if [ "$REQUIRE_CLEAN" -eq 1 ]; then ci_err "--require-clean: $msg"; else ci_warn "$msg"; fi
  printf '%s\n' "$TREE_LIST" | awk 'NR <= 20 { print "    " $0 } END { if (NR > 20) printf "    ... and %d more\n", NR - 20 }' >&2
  if [ "$REQUIRE_CLEAN" -eq 1 ]; then
    ci_err "commit them or remove them (an ignored .env or an editor backup would ship too), or build without --require-clean"
    exit 1
  fi
  ci_warn "every one of these files ships exactly as it is now, and the build record (.build-info) will say REPO_TREE=dirty. For a release: commit or remove them and pass --require-clean to make this an error. --allow-dirty says the build from this tree is intended and drops this warning."
}

if [ "$DRY" -eq 1 ]; then
  print_plan
  report_tree
  printf '\n== Steps ==\n'
else
  command -v "$DOCKER" >/dev/null 2>&1 || {
    ci_err "docker not found ('$DOCKER'). Install Docker Desktop (macOS, Windows) or the docker engine (Linux), or run with --dry-run to see the plan."
    exit 2
  }
  "$DOCKER" info >/dev/null 2>&1 || { ci_err "the docker daemon is not reachable. Start Docker Desktop (or the engine) and retry."; exit 2; }
  [ "$OVERLAY_STATE" = present ] || ci_die "the overlay directory is missing: ${OVERLAY_DIR#"$REPO_ROOT"/} (the Companion OS overlay is part of the edition)"
  case " $PUSH_PATHS " in *" backends/cachyos "*) ;; *) ci_die "backends/cachyos is not under $REPO_ROOT: nothing to build" ;; esac
  # The result is written to --out only at the very end, 35 to 60 minutes in: find out now that it can be (nothing is created).
  if [ -z "$STOP_AFTER" ]; then
    why="$(ci_out_dir_problem "$OUT_DIR")" || { ci_err "--out $OUT_DIR: $why. Nothing was started: the ISO is only written there after the build."; exit 2; }
  fi
  for a in $([ -n "$STOP_AFTER" ] || echo "$ARTIFACTS"); do
    if [ -e "$OUT_DIR/$a" ] && [ "$FORCE" -eq 0 ]; then
      ci_err "$OUT_DIR/$a already exists. Pass --force to replace it (a failed build never touches existing files), or choose another --out."
      exit 1
    fi
  done
  report_tree
fi

# --- cleanup -------------------------------------------------------------------------------------------------------
# BUILT: 20-build.sh finished, so the container holds an ISO. COPIED: it is safely in --out. A failure between the two keeps the
# container and the work volume (the ISO would be lost with them) and says how to take it out.
CREATED_CONTAINER=0; CREATED_WORK_VOL=0; PARTIAL=""; BUILT=0; COPIED=0
LOG_TMP=""; LOG_FAILED="$OUT_DIR/$BASE.failed.log"
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e      # nothing below may abort the trap: a failed log move must not leave the container and the 25 GB volume behind
  [ -z "$PARTIAL" ] || rm -rf "$PARTIAL"
  if [ "$DRY" -eq 0 ]; then
    if [ "$KEEP" -eq 1 ]; then
      [ "$CREATED_CONTAINER" -eq 0 ] || ci_log "kept container $CONTAINER and volume $WORK_VOL. Remove with: $DOCKER rm -f -v $CONTAINER; $DOCKER volume rm $WORK_VOL"
    elif [ "$rc" -ne 0 ] && [ "$BUILT" -eq 1 ] && [ "$COPIED" -eq 0 ]; then
      ci_log "the build finished but its artifacts did not reach $OUT_DIR, so the container $CONTAINER and the volume $WORK_VOL are KEPT: the ISO is still inside."
      ci_log "take it out with: mkdir -p DIR && $DOCKER cp $CONTAINER:/work/out/. DIR      (sha256 of the ISO: DIR/<iso>.sha256)"
      ci_log "then remove with: $DOCKER rm -f -v $CONTAINER; $DOCKER volume rm $WORK_VOL"
    else
      [ "$CREATED_CONTAINER" -eq 0 ] || "$DOCKER" rm -f -v "$CONTAINER" >/dev/null 2>&1
      [ "$CREATED_WORK_VOL" -eq 0 ]  || "$DOCKER" volume rm "$WORK_VOL" >/dev/null 2>&1
    fi
  fi
  if [ -n "$LOG_TMP" ] && [ -e "$LOG_TMP" ]; then
    if [ "$rc" -ne 0 ] && [ -s "$LOG_TMP" ]; then
      if mkdir -p "$OUT_DIR" 2>/dev/null && mv -f "$LOG_TMP" "$LOG_FAILED" 2>/dev/null; then ci_log "log of the failed run: $LOG_FAILED"
      else ci_warn "could not write $LOG_FAILED; the log of the failed run stays at $LOG_TMP"; fi
    else rm -f "$LOG_TMP"; fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'ci_err "interrupted"; exit 130' INT
trap 'ci_err "terminated"; exit 143' TERM HUP

label_of_container() { "$DOCKER" inspect -f '{{index .Config.Labels "'"$LABEL_KEY"'"}}' "$1" 2>/dev/null || true; }
label_of_volume()    { "$DOCKER" volume inspect -f '{{index .Labels "'"$LABEL_KEY"'"}}' "$1" 2>/dev/null || true; }

# --- 1. builder image ----------------------------------------------------------------------------------------------
[ "$DRY" -eq 0 ] || echo "# an earlier run's stopped $CONTAINER container and $WORK_VOL volume (both labelled $LABEL_KEY) are removed first; anything else with those names stops the build"
note "1/6 builder image $IMAGE"
if [ "$DRY" -eq 1 ]; then
  echo "# only if the tag is absent (or --rebuild-image):"
  run "$DOCKER" build --platform linux/amd64 --build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "CACHYOS_KEY_FPR=$CACHYOS_KEY_FPR" \
      -f "$DOCKERFILE" -t "$IMAGE" "$DOCKER_CONTEXT"
else
  if [ "$REBUILD_IMAGE" -eq 1 ] || ! "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1; then
    ci_log "building $IMAGE (pinned base $BASE_IMAGE)"
    "$DOCKER" build --platform linux/amd64 --build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "CACHYOS_KEY_FPR=$CACHYOS_KEY_FPR" \
        -f "$DOCKERFILE" -t "$IMAGE" "$DOCKER_CONTEXT"
  else
    ci_log "builder image $IMAGE already exists"
  fi
  arch="$("$DOCKER" image inspect -f '{{.Architecture}}' "$IMAGE")"
  [ "$arch" = amd64 ] || ci_die "$IMAGE is $arch, not amd64: refusing to build an x86-64 ISO on it"
fi

# --- 2. container and volumes --------------------------------------------------------------------------------------
note "2/6 container $CONTAINER and volumes"
if [ "$DRY" -eq 0 ]; then
  if "$DOCKER" inspect "$CONTAINER" >/dev/null 2>&1; then
    [ "$(label_of_container "$CONTAINER")" = build ] || ci_die "a container named $CONTAINER exists and was not created by this script; refusing to touch it"
    [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$CONTAINER")" != true ] || \
      ci_die "$CONTAINER is running: another build is in progress, or a killed run left it behind. If no build is running: $DOCKER rm -f $CONTAINER (a kept container can hold a finished ISO that never reached --out: look first with $DOCKER exec $CONTAINER ls /work/out)"
    ci_log "removing the stopped $CONTAINER left by an earlier run (created by this script)"
    "$DOCKER" rm -f -v "$CONTAINER" >/dev/null
  fi
  if "$DOCKER" volume inspect "$WORK_VOL" >/dev/null 2>&1; then
    [ "$(label_of_volume "$WORK_VOL")" = work ] || ci_die "a volume named $WORK_VOL exists and was not created by this script; refusing to touch it"
    ci_log "removing the work volume $WORK_VOL left by an earlier run (created by this script)"
    "$DOCKER" volume rm "$WORK_VOL" >/dev/null
  fi
  if "$DOCKER" volume inspect "$CACHE_VOL" >/dev/null 2>&1; then
    [ "$(label_of_volume "$CACHE_VOL")" = cache ] || ci_die "a volume named $CACHE_VOL exists and was not created by this script; pick another one with --cache-volume NAME"
  fi
fi
run "$DOCKER" volume create --label "$LABEL_KEY=work" "$WORK_VOL"
CREATED_WORK_VOL=1
if [ "$DRY" -eq 1 ]; then
  echo "# only if the cache volume is absent:"
  run "$DOCKER" volume create --label "$LABEL_KEY=cache" "$CACHE_VOL"
elif ! "$DOCKER" volume inspect "$CACHE_VOL" >/dev/null 2>&1; then
  "$DOCKER" volume create --label "$LABEL_KEY=cache" "$CACHE_VOL" >/dev/null
fi
if [ "$PRIVILEGED" -eq 1 ]; then CAPS=(--privileged); else CAPS=(--cap-add SYS_ADMIN); fi
run "$DOCKER" run -d --name "$CONTAINER" --label "$LABEL_KEY=build" --platform linux/amd64 "${CAPS[@]}" \
    --cpus "$CPUS" --memory "$MEMORY" -v "$WORK_VOL:/work" -v "$CACHE_VOL:/var/cache/pacman/pkg" "$IMAGE" sleep infinity
CREATED_CONTAINER=1

# --- 3. copy the repo subset in ------------------------------------------------------------------------------------
note "3/6 copy ${PUSH_PATHS:-<repo subset>} into $CT_REPO (overlay, scripts and pins travel with backends/cachyos)"
run "$DOCKER" exec "$CONTAINER" mkdir -p "$CT_REPO"
push_tree
run "$DOCKER" exec "$CONTAINER" chown -R 0:0 "$CT_REPO"      # the tar stream carries the host user's uid; the profile must be root-owned

# --- 4 and 5. bootstrap and build ----------------------------------------------------------------------------------
EXEC_ENV=(-e "CI_OS_VERSION=$VERSION" -e "SOURCE_DATE_EPOCH=$SDE" -e "CI_OS_JOBS=$JOBS" -e "CI_OS_PIN=$PIN"
          -e "CI_OS_REPO_ROOT=$CT_REPO" -e "CI_OS_OWNERSHIP_CHECK=$OWNERSHIP"
          -e "CI_OS_REPO_COMMIT=$REPO_COMMIT" -e "CI_OS_REPO_TREE=$TREE_STATE"
          -e "CI_OS_REPO_TREE_CHANGED=$TREE_CHANGED" -e "CI_OS_REPO_TREE_UNTRACKED=$TREE_UNTRACKED" -e "CI_OS_REPO_TREE_IGNORED=$TREE_IGNORED")
[ -z "$STOP_AFTER" ] || EXEC_ENV+=(-e "CI_OS_STOP_AFTER=$STOP_AFTER")
exec_in() { # exec_in STEP SCRIPT
  local step="$1" script="$2" rc=0
  if [ "$DRY" -eq 1 ]; then
    run "$DOCKER" exec "${EXEC_ENV[@]}" "$CONTAINER" "$CT_BUILD/$script"
    return 0
  fi
  set +e
  "$DOCKER" exec "${EXEC_ENV[@]}" "$CONTAINER" "$CT_BUILD/$script" 2>&1 | tee -a "$LOG_TMP"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || ci_die "$step failed (exit $rc). The log is kept as $LOG_FAILED. Re-run with --keep-container to inspect the container."
}
if [ "$DRY" -eq 0 ]; then LOG_TMP="$(mktemp "${TMPDIR:-/tmp}/ci-os-cachyos-build.XXXXXX")"; fi
note "4/6 bootstrap: [cachyos] repo, key check, archiso grub git + iso/render-deps.txt"
exec_in "10-bootstrap.sh" 10-bootstrap.sh
note "5/6 build: pinned upstream, render-assets, overlay, mkarchiso$([ -n "$STOP_AFTER" ] && echo " (only as far as --stop-after $STOP_AFTER)" || echo " (35 to 60 minutes)")"
exec_in "20-build.sh" 20-build.sh
[ -n "$STOP_AFTER" ] || BUILT=1       # a finished ISO is in the container from here on

# --- 6. artifacts out ----------------------------------------------------------------------------------------------
if [ -n "$STOP_AFTER" ]; then
  note "6/6 --stop-after $STOP_AFTER: no ISO was built, nothing to copy out; the container and the work volume are removed"
  if [ "$DRY" -eq 0 ]; then ci_log "the pipeline ran up to '$STOP_AFTER' without error"; fi
  exit 0
fi
note "6/6 copy artifacts to $OUT_DIR and verify the ISO hash on the host"
if [ "$DRY" -eq 1 ]; then
  run "$DOCKER" cp "$CONTAINER:/work/out/." "$OUT_DIR/.partial.<pid>/"
  echo "# then: sha256 of the ISO on the host must equal the .sha256 written in the container; files are moved into $OUT_DIR"
  echo "# finally: $DOCKER rm -f -v $CONTAINER; $DOCKER volume rm $WORK_VOL   (unless --keep-container)"
  echo "# the cache volume $CACHE_VOL and the builder image $IMAGE are kept"
  exit 0
fi
mkdir -p "$OUT_DIR"
PARTIAL="$(mktemp -d "$OUT_DIR/.partial.XXXXXX")"
"$DOCKER" cp "$CONTAINER:/work/out/." "$PARTIAL/"
for a in "$ISO_FILE" "$ISO_FILE.sha256" "$BASE.pkgs.txt" "$BASE.build-info"; do
  [ -s "$PARTIAL/$a" ] || ci_die "the build finished but did not produce $a (found: $(find "$PARTIAL" -maxdepth 1 -type f | tr '\n' ' '))"
done
want="$(awk '{print $1}' "$PARTIAL/$ISO_FILE.sha256")"
have="$(ci_sha256_file "$PARTIAL/$ISO_FILE")"
[ "$want" = "$have" ] || ci_die "sha256 mismatch after docker cp: container says $want, host has $have. The copy is corrupt; nothing was installed into $OUT_DIR (the finished ISO is still in the container)."
for a in "$ISO_FILE" "$ISO_FILE.sha256" "$BASE.pkgs.txt" "$BASE.build-info"; do mv -f "$PARTIAL/$a" "$OUT_DIR/$a"; done
COPIED=1
if mv -f "$LOG_TMP" "$OUT_DIR/$BASE.build.log"; then LOG_TMP=""; else ci_warn "could not move the build log into $OUT_DIR; it stays at $LOG_TMP"; LOG_TMP=""; fi
rm -rf "$PARTIAL"; PARTIAL=""

ci_log "done: $OUT_DIR/$ISO_FILE ($(du -h "$OUT_DIR/$ISO_FILE" | cut -f1))"
printf 'SHA256 %s  %s\n' "$have" "$ISO_FILE"
printf 'build record: %s\n' "$OUT_DIR/$BASE.build-info"
