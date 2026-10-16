# shellcheck shell=bash
# Shared helpers for the Companion OS (CachyOS edition) build scripts. Sourced, never executed.
#
# build-iso.sh and tests/overlay-engine.sh run on macOS (bash 3.2, BSD userland), the in-container scripts on Arch
# (bash 5, GNU), so everything here sticks to the common subset: no mapfile, no associative arrays, no GNU-only
# flags, and every empty-array expansion written as ${arr[@]+"${arr[@]}"} (bash 3.2 + set -u).

# Messages. The caller sets CI_PROG (for example "build-iso") before sourcing.
ci_log()  { printf '%s: %s\n' "${CI_PROG:-cachyos}" "$*"; }
ci_warn() { printf '%s: warning: %s\n' "${CI_PROG:-cachyos}" "$*" >&2; }
ci_err()  { printf '%s: ERROR: %s\n' "${CI_PROG:-cachyos}" "$*" >&2; }
ci_die()  { ci_err "$@"; exit 1; }

# --- hashing -----------------------------------------------------------------------------------------------------
_ci_sha_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then echo "sha256sum"
  elif command -v shasum >/dev/null 2>&1; then echo "shasum -a 256"
  elif command -v openssl >/dev/null 2>&1; then echo "openssl dgst -sha256 -r"
  else return 1
  fi
}

# ci_sha256_stdin: hex digest of stdin.
ci_sha256_stdin() {
  local cmd
  cmd="$(_ci_sha_cmd)" || ci_die "need sha256sum, shasum or openssl to hash files"
  # shellcheck disable=SC2086  # $cmd is a fixed command line with at most one flag
  $cmd | awk '{print $1}'
}

# ci_sha256_file FILE: hex digest of one file.
ci_sha256_file() {
  [ -f "$1" ] || ci_die "cannot hash $1: not a file"
  ci_sha256_stdin < "$1"
}

# --- the tar view of the repository -------------------------------------------------------------------------------
# What build-iso.sh leaves out of the tree it copies into the container: tar --exclude patterns, each matched against every
# path component. ONE list: it builds the tar command, the digest the plan prints and the working-tree check, so the three
# cannot disagree about which files the container sees.
CI_TAR_EXCLUDE_PATTERNS=('.DS_Store' '._*' '__pycache__' '*.pyc' '*.iso')

# ci_tar_excluded RELPATH: true if tar would leave RELPATH (or the directory above it) out.
ci_tar_excluded() {
  local rest="$1" comp pat
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    for pat in "${CI_TAR_EXCLUDE_PATTERNS[@]}"; do
      # shellcheck disable=SC2254  # $pat is a glob on purpose
      case "$comp" in $pat) return 0 ;; esac
    done
  done
  return 1
}

# ci_tree_digest DIR [tar-view]: one digest for a whole tree: every directory, regular file (content and whether the owner may
# execute it) and symlink (target), in C-locale path order. Two trees with the same digest are the same profile. With tar-view
# the paths build-iso.sh's tar leaves out (ci_tar_excluded) are skipped: the digest of a host directory then equals the digest
# the container computes over the copy it received.
ci_tree_digest() {
  local dir="$1" view="${2:-}" p
  [ -d "$dir" ] || ci_die "ci_tree_digest: $dir is not a directory"
  case "$view" in ''|tar-view) ;; *) ci_die "ci_tree_digest: unknown view '$view'" ;; esac
  (
    cd "$dir" || exit 1
    LC_ALL=C find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
      if [ "$view" = tar-view ] && ci_tar_excluded "${p#./}"; then continue; fi
      if [ -L "$p" ]; then
        printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
      elif [ -d "$p" ]; then
        printf 'D %s\n' "$p"
      else
        if [ -n "$(find "$p" -maxdepth 0 -perm -100 -print)" ]; then x=x; else x=-; fi
        printf 'F %s %s %s\n' "$x" "$(ci_sha256_file "$p")" "$p"
      fi
    done
  ) | ci_sha256_stdin
}

# --- time --------------------------------------------------------------------------------------------------------
# ci_epoch_fmt EPOCH FORMAT: format an epoch in UTC with GNU date (-d @N) or BSD date (-r N).
ci_epoch_fmt() {
  local epoch="$1" fmt="$2"
  case "$epoch" in ''|*[!0-9]*) ci_die "not an epoch: '$epoch'" ;; esac
  # Probe for GNU date first: BSD date has a -d flag too, with a different meaning (kernel DST value), and must not get it.
  if date --version >/dev/null 2>&1; then
    date -u -d "@$epoch" "+$fmt"
  else
    date -u -r "$epoch" "+$fmt"
  fi
}

# --- lists -------------------------------------------------------------------------------------------------------
# ci_strip_list FILE: the lines of a package-list style file without comments and blank lines.
ci_strip_list() {
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# ci_valid_pkg_name NAME: pacman package names are [a-z0-9@._+-], not starting with - or .
ci_valid_pkg_name() {
  case "$1" in ''|-*|.*|*[!A-Za-z0-9@._+-]*) return 1 ;; esac
  return 0
}

# --- lock file ---------------------------------------------------------------------------------------------------
# ci_load_lock FILE: source upstream.lock into the caller's shell (KEY=VALUE lines only) and validate every pin.
ci_lock_line_re='^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*=[^[:space:]"'"'"'$`;&|<>()\\]*$'
ci_load_lock() {
  local lock="$1" k v bad
  [ -f "$lock" ] || ci_die "pin file not found: $lock"
  bad="$(grep -vE "$ci_lock_line_re" "$lock" || true)"
  if [ -n "$bad" ]; then
    ci_err "$lock has a line that is not KEY=VALUE (no quotes, spaces, substitutions or shell syntax in values):"
    printf '%s\n' "$bad" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "$lock"
  set +a
  for k in UPSTREAM_REPO UPSTREAM_SHA UPSTREAM_COMMIT_EPOCH UPSTREAM_ARCHISO_TREE \
           UPSTREAM_FALLBACK_SHA UPSTREAM_FALLBACK_COMMIT_EPOCH UPSTREAM_FALLBACK_ARCHISO_TREE \
           BASE_IMAGE ARCHISO_MIN_VERSION CACHYOS_KEY_FPR CACHYOS_KEYSERVERS \
           MIRRORLIST_REPO MIRRORLIST_REF MIRRORLIST_PATH MIRRORLIST_SHA256 \
           EDITION_ISO_NAME EDITION_LABEL_PREFIX EDITION_ARCH; do
    eval "v=\${$k:-}"
    [ -n "$v" ] || ci_die "$lock: $k is missing or empty"
  done
  for k in UPSTREAM_SHA UPSTREAM_FALLBACK_SHA UPSTREAM_ARCHISO_TREE UPSTREAM_FALLBACK_ARCHISO_TREE MIRRORLIST_REF; do
    eval "v=\${$k}"
    printf '%s' "$v" | grep -qE '^[0-9a-f]{40}$' || ci_die "$lock: $k must be 40 lowercase hex digits (got '$v')"
  done
  printf '%s' "$CACHYOS_KEY_FPR" | grep -qE '^[0-9A-F]{40}$' || ci_die "$lock: CACHYOS_KEY_FPR must be a full 40-digit upper-case fingerprint"
  printf '%s' "$MIRRORLIST_SHA256" | grep -qE '^[0-9a-f]{64}$' || ci_die "$lock: MIRRORLIST_SHA256 must be 64 lowercase hex digits"
  printf '%s' "$BASE_IMAGE" | grep -qE '^[a-z0-9./_-]+@sha256:[0-9a-f]{64}$' || ci_die "$lock: BASE_IMAGE must be pinned by digest (name@sha256:...)"
  for k in UPSTREAM_COMMIT_EPOCH UPSTREAM_FALLBACK_COMMIT_EPOCH ARCHISO_MIN_VERSION; do
    eval "v=\${$k}"
    printf '%s' "$v" | grep -qE '^[0-9]+$' || ci_die "$lock: $k must be a number (got '$v')"
  done
  case "$UPSTREAM_REPO" in https://*) ;; *) ci_die "$lock: UPSTREAM_REPO must be an https URL" ;; esac
  return 0
}

# ci_select_pin primary|fallback: set PIN_NAME PIN_SHA PIN_TREE PIN_EPOCH from the loaded lock.
# shellcheck disable=SC2034  # the PIN_* variables are the outputs, read by the sourcing script
ci_select_pin() {
  case "${1:-primary}" in
    primary)  PIN_NAME=primary;  PIN_SHA="$UPSTREAM_SHA";          PIN_TREE="$UPSTREAM_ARCHISO_TREE";          PIN_EPOCH="$UPSTREAM_COMMIT_EPOCH" ;;
    fallback) PIN_NAME=fallback; PIN_SHA="$UPSTREAM_FALLBACK_SHA"; PIN_TREE="$UPSTREAM_FALLBACK_ARCHISO_TREE"; PIN_EPOCH="$UPSTREAM_FALLBACK_COMMIT_EPOCH" ;;
    *) ci_die "unknown pin '$1' (expected primary or fallback)" ;;
  esac
}

# ci_iso_file_name EPOCH: the file mkarchiso will produce, from the lock's edition identity.
ci_iso_file_name() {
  printf '%s-%s-%s.iso' "$EDITION_ISO_NAME" "$(ci_epoch_fmt "$1" %Y.%m.%d)" "$EDITION_ARCH"
}

# --- where the build runs from ------------------------------------------------------------------------------------
# The ISO is built from the WORKING TREE: build-iso.sh tars the repo subset into a container that has no .git. These helpers
# say which commit that tree started from and what differs from it, so the host can warn before a 40 minute build and the
# build record can say so.

# ci_git ARGS...: git without the GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE a hook may have exported (inside a pre-push hook
# they would send every git call here to the repository that is running the hook).
ci_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git "$@"; }

# ci_is_git_root DIR: DIR is the top level of its own git work tree (a copy of the tree dropped inside another repository is not).
ci_is_git_root() {
  local root top
  command -v git >/dev/null 2>&1 || return 1
  root="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  top="$(ci_git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$top" = "$root" ]
}

# ci_repo_commit ROOT: the 40-digit id of HEAD, or "unknown" (not a git checkout of its own, no git, no commit).
ci_repo_commit() {
  local c=""
  if ci_is_git_root "$1"; then c="$(ci_git -C "$1" rev-parse --verify -q HEAD 2>/dev/null || true)"; fi
  printf '%s\n' "${c:-unknown}"
}

_ci_emit_dirty() { # _ci_emit_dirty KIND LIST: "KIND path" for every line of LIST the tar does not leave out
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    ci_tar_excluded "$path" || printf '%s %s\n' "$1" "$path"
  done <<EOT
$2
EOT
}

# ci_repo_dirty_files ROOT PATH...: one "KIND path" line (sorted) for every file below PATH... (repo-relative) that is not exactly
# what HEAD has: `changed` (tracked, differs from HEAD in the index or the work tree, or deleted), `untracked` (not ignored)
# and `ignored` (an ignored .env counts: it would ship). Paths the tar leaves out are not listed, they never reach the
# container. No output when the tree is clean. Status 3, no output, when that cannot be known (not a git checkout of its
# own, no commit yet, no PATH).
ci_repo_dirty_files() {
  local root="$1" changed untracked ignored
  shift
  [ $# -gt 0 ] || return 3
  ci_is_git_root "$root" || return 3
  ci_git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1 || return 3
  changed="$(ci_git -c core.quotepath=off -C "$root" diff --name-only HEAD -- "$@")" || return 3
  untracked="$(ci_git -c core.quotepath=off -C "$root" ls-files --others --exclude-standard -- "$@")" || return 3
  ignored="$(ci_git -c core.quotepath=off -C "$root" ls-files --others --ignored --exclude-standard -- "$@")" || return 3
  { _ci_emit_dirty changed "$changed"; _ci_emit_dirty untracked "$untracked"; _ci_emit_dirty ignored "$ignored"; } | LC_ALL=C sort
}

# ci_out_dir_problem DIR: decided without creating anything. Prints why DIR cannot be written (and returns 1) or prints nothing
# (and returns 0): DIR must be a writable directory, or must be creatable below the nearest existing ancestor, which must be one.
ci_out_dir_problem() {
  local d="$1" up
  [ -n "$d" ] || { echo "the path is empty"; return 1; }
  up="$d"
  while [ ! -e "$up" ] && [ ! -L "$up" ]; do
    case "$up" in
      */*) up="${up%/*}"; [ -n "$up" ] || up=/ ;;
      *)   up=. ;;
    esac
  done
  if [ "$up" = "$d" ]; then
    [ -d "$d" ] || { echo "$d exists and is not a directory"; return 1; }
    { [ -w "$d" ] && [ -x "$d" ]; } || { echo "$d is not writable"; return 1; }
  else
    [ -d "$up" ] || { echo "$up exists and is not a directory, so $d cannot be created"; return 1; }
    { [ -w "$up" ] && [ -x "$up" ]; } || { echo "$up is not writable, so $d cannot be created"; return 1; }
  fi
  return 0
}

# ci_env_value VAR REGEX DEFAULT: the value of the environment variable VAR (DEFAULT when unset or empty), which must match the
# extended REGEX: a value that goes into the KEY=VALUE build record may not carry a newline or anything else unexpected.
ci_env_value() {
  local v nl='
'
  eval "v=\${$1:-}"
  [ -n "$v" ] || v="$3"
  case "$v" in *"$nl"*) ci_die "$1 has an unexpected value (it spans several lines)" ;; esac     # grep -E would judge line by line
  printf '%s' "$v" | grep -qE "$2" || ci_die "$1 has an unexpected value (does not match $2)"
  printf '%s\n' "$v"
}

# --- the assertions behind upstream.lock --------------------------------------------------------------------------
# Small functions, so that tests/overlay-engine.sh can run each one against a throwaway repository or file with a wrong value
# and watch it refuse. The in-container scripts only call them (20-build.sh, 10-bootstrap.sh); iso/docker/Dockerfile.builder
# cannot source this file at image build time and keeps its own copy of the key check (a static test pins that line).

# ci_check_checkout DIR SHA EPOCH TREE: DIR is a clean checkout of exactly commit SHA, whose committer time is EPOCH and whose
# archiso/ tree id is TREE. Dies on the first difference.
ci_check_checkout() {
  local dir="$1" sha="$2" epoch="$3" tree="$4" head ctime got
  [ -d "$dir" ] || ci_die "ci_check_checkout: $dir is not a directory"
  head="$(ci_git -C "$dir" rev-parse HEAD)" || ci_die "$dir is not a git checkout"
  [ "$head" = "$sha" ] || ci_die "upstream HEAD is $head, expected the pin $sha"
  ctime="$(ci_git -C "$dir" log -1 --format=%ct)" || ci_die "cannot read the committer time in $dir"
  [ "$ctime" = "$epoch" ] || ci_die "upstream commit time is $ctime, upstream.lock says $epoch"
  got="$(ci_git -C "$dir" rev-parse HEAD:archiso)" || ci_die "the upstream checkout $dir has no archiso/ directory"
  [ "$got" = "$tree" ] || ci_die "upstream archiso/ tree is $got, upstream.lock says $tree"
  [ -z "$(ci_git -C "$dir" status --porcelain)" ] || ci_die "the upstream checkout $dir is not clean before the build started"
}

# ci_check_sha256 FILE HASH LABEL: FILE hashes to HASH (64 lowercase hex digits). LABEL names the file in the message.
ci_check_sha256() {
  local file="$1" want="$2" label="$3" have
  printf '%s' "$want" | grep -qE '^[0-9a-f]{64}$' || ci_die "$label: the pinned sha256 '$want' is not 64 lowercase hex digits"
  have="$(ci_sha256_file "$file")"
  [ "$have" = "$want" ] || ci_die "$label has sha256 $have, upstream.lock pins $want"
}

# ci_check_fpr GOT WANT LABEL: the fingerprint found equals the pinned one, which must itself be a full 40-digit upper-case
# fingerprint (so an empty pin cannot be matched by an empty finding).
ci_check_fpr() {
  local got="$1" want="$2" label="$3"
  printf '%s' "$want" | grep -qE '^[0-9A-F]{40}$' || ci_die "$label: the pinned fingerprint '$want' is not a full 40-digit upper-case fingerprint"
  [ "$got" = "$want" ] || ci_die "$label carries key '${got:-<none>}', not the pinned $want: refusing to use it"
}

# ci_asc_primary_fprs ASC: the fingerprint of every primary key in an armoured key file, one per line (needs gpg).
ci_asc_primary_fprs() {
  gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print $10; p = 0 }'
}

# ci_check_key_fpr ASC FPR: the armoured file holds exactly one primary key and it is FPR, so `pacman-key --add` cannot import
# anything else. A file gpg cannot read, or gpg missing, is a refusal, not a pass.
ci_check_key_fpr() {
  local asc="$1" want="$2" found n
  found="$(ci_asc_primary_fprs "$asc" || true)"
  n="$(printf '%s\n' "$found" | awk 'NF { n++ } END { print n + 0 }')"
  [ "$n" -le 1 ] || ci_die "$asc holds $n primary keys, not just the pinned $want: refusing to import it"
  ci_check_fpr "$found" "$want" "$asc"
}
