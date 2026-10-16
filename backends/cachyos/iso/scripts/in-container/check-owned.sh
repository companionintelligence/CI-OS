#!/usr/bin/env bash
# check-owned.sh: find files the build adds to airootfs that a package of the image also ships, BEFORE mkarchiso spends 8 minutes
# downloading and verifying 1000 packages only to abort with "exists in filesystem". apply-overlay.sh's guard (b) is a rule of thumb
# about directories; this is the exact check, from the repositories' file lists:
#
#   1. candidates: every non-directory path in the merged airootfs that upstream's airootfs does not have (upstream's own paths
#      have been through pacstrap in upstream's builds)
#   2. the closure: what pacstrap will install, resolved from an empty root against the synced databases
#   3. `pacman -Fl` of that closure (files databases of [cachyos], [core], [extra]): which candidates a package ships
#   4. for each such package, its .PKGINFO: a path in `backup =` may be overridden (the overlay copy wins, the package copy becomes
#      .pacnew and mkarchiso deletes it); any other path is a conflict and pacstrap would abort
#
# Environment: WORK_ARCHISO_DIR (merged profile) and UPSTREAM_ARCHISO_DIR, both required;
#   CI_OS_OWNERSHIP_CHECK=error (default: a conflict fails) | warn (report it, succeed) | off.
# The scan needs the network (files databases, the few packages involved) and is skipped with a warning if it cannot run: it is a
# pre-flight, not the build. Exit 0 no conflict (or skipped), 1 conflict, 2 usage.
set -euo pipefail
export LC_ALL=C

export CI_PROG=check-owned
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

MODE="${CI_OS_OWNERSHIP_CHECK:-error}"
case "$MODE" in error|warn) ;; off) ci_log "CI_OS_OWNERSHIP_CHECK=off: skipped"; exit 0 ;; *) ci_err "CI_OS_OWNERSHIP_CHECK must be error, warn or off (got '$MODE')"; exit 2 ;; esac
[ -n "${WORK_ARCHISO_DIR:-}" ] && [ -n "${UPSTREAM_ARCHISO_DIR:-}" ] || { ci_err "WORK_ARCHISO_DIR and UPSTREAM_ARCHISO_DIR are required"; exit 2; }
WORK="$WORK_ARCHISO_DIR"; UP="$UPSTREAM_ARCHISO_DIR"
[ -d "$WORK/airootfs" ] && [ -f "$WORK/packages.x86_64" ] || { ci_err "$WORK is not a merged profile (no airootfs/ or packages.x86_64)"; exit 2; }
command -v pacman >/dev/null 2>&1 || { ci_warn "pacman not found: ownership scan skipped"; exit 0; }

skip() { ci_warn "ownership scan skipped: $*"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/tmp}/check-owned.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# 1. candidates
(cd "$WORK/airootfs" && find . -mindepth 1 ! -type d | sed 's|^\./||' | sort) > "$T/work.files"
if [ -d "$UP/airootfs" ]; then (cd "$UP/airootfs" && find . -mindepth 1 ! -type d | sed 's|^\./||' | sort) > "$T/up.files"; else : > "$T/up.files"; fi
comm -23 "$T/work.files" "$T/up.files" > "$T/cand.txt"
NCAND="$(wc -l < "$T/cand.txt" | tr -d ' ')"
[ "$NCAND" -gt 0 ] || { ci_log "no file in airootfs is new compared with upstream: nothing to check"; exit 0; }

# 2. files databases and the closure
ci_log "$NCAND new file(s) in airootfs; syncing the files databases"
n=1; until pacman -Fy >/dev/null 2>&1; do [ "$n" -lt 3 ] || skip "pacman -Fy failed (no network?)"; n=$((n + 1)); sleep 3; done
mkdir -p "$T/db/sync" "$T/db/local" "$T/root" "$T/cache"
cp /var/lib/pacman/sync/*.db "$T/db/sync/"
mapfile -t PKGS < <(ci_strip_list "$WORK/packages.x86_64")
[ "${#PKGS[@]}" -gt 0 ] || skip "the package list is empty"
pacman -r "$T/root" --dbpath "$T/db" --cachedir "$T/cache" -Sp --print-format '%n' --noconfirm "${PKGS[@]}" 2> "$T/closure.err" | sort -u > "$T/closure.txt" || true
if [ ! -s "$T/closure.txt" ]; then head -n 5 "$T/closure.err" >&2; skip "cannot resolve the package list against the synced databases"; fi
ci_log "the image installs $(wc -l < "$T/closure.txt" | tr -d ' ') package(s) (resolved from an empty root)"

# 3. which candidates does a package ship
xargs -n 150 pacman -Fl < "$T/closure.txt" 2>/dev/null \
  | awk 'NR == FNR { c[$0] = 1; next } ($2 in c) { print $1 "\t" $2 }' "$T/cand.txt" - | sort -u > "$T/hits.txt" || true
if [ ! -s "$T/hits.txt" ]; then ci_log "no new file in airootfs is shipped by a package of the image"; exit 0; fi

# 4. backup= or conflict
CONFLICTS=0; BACKUPS=0
while IFS= read -r pkg; do
  fname="$(pacman -Sp --print-format '%f' "$pkg" 2>/dev/null | head -n 1 || true)"
  if [ -z "$fname" ] || ! pacman -Sw --noconfirm "$pkg" > "$T/dl.log" 2>&1 || [ ! -f "/var/cache/pacman/pkg/$fname" ]; then
    ci_warn "cannot fetch $pkg to read its backup= list; its paths are reported as unverified:"
    awk -F'\t' -v p="$pkg" '$1 == p { print "    /" $2 }' "$T/hits.txt" >&2
    continue
  fi
  bsdtar -xOf "/var/cache/pacman/pkg/$fname" .PKGINFO | sed -n 's/^backup = //p' | sort -u > "$T/backup.$pkg"
  while IFS=$'\t' read -r p path; do
    [ "$p" = "$pkg" ] || continue
    if grep -qxF -- "$path" "$T/backup.$pkg"; then
      BACKUPS=$((BACKUPS + 1)); ci_log "ok: /$path is a backup= file of $pkg (the overlay copy wins, the package copy becomes .pacnew)"
    else
      CONFLICTS=$((CONFLICTS + 1))
      ci_err "conflict: /$path is shipped by $pkg and is not in its backup=; pacstrap would abort with 'exists in filesystem'"
    fi
  done < "$T/hits.txt"
done < <(cut -f1 "$T/hits.txt" | sort -u)

if [ "$CONFLICTS" -gt 0 ]; then
  ci_err "$CONFLICTS conflicting file(s). Move them to a path of your own (/usr/share/ci-os, /etc/ci-os, /usr/local), or handle them with a PostTransaction pacman hook (see airootfs/etc/pacman.d/hooks/ in upstream for the precedent)."
  [ "$MODE" = warn ] && { ci_warn "CI_OS_OWNERSHIP_CHECK=warn: continuing anyway"; exit 0; }
  exit 1
fi
ci_log "no conflict ($BACKUPS backup= override(s))"
