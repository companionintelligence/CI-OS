#!/usr/bin/env bash
#=============================================================================
# Runs the model-tooling tests: models-gate.sh, models-view.sh, models-lib.sh, models-env.sh, models-units.sh, and with --mutation also
# models-mutation.sh (110 broken copies of the code, one rule each; every one must make its test fail; this takes a while).
#
#   bash backends/ubuntu/chroot/tests/models-all.sh [--mutation]
#
# No root, no Docker, no network; bash 3.2 or 5, awk from BSD, mawk or gawk. Run it as a normal user (as root the
# "cache is not writable" cases are skipped). A test that exits 2 cannot run on this machine; it is reported, not failed.
# Exit status: non-zero if any test failed.
#
# (c) Companion Intelligence - Lifescope Inc
#=============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tests="models-gate.sh models-view.sh models-lib.sh models-env.sh models-units.sh"
[ "${1:-}" != "--mutation" ] || tests="$tests models-mutation.sh"

rc=0
for t in $tests; do
  out="$(mktemp "${TMPDIR:-/tmp}/ci-models-all.XXXXXX")"
  trc=0
  bash "$HERE/$t" > "$out" 2>&1 || trc=$?
  case "$trc" in
    0) printf '  %-22s %s\n' "$t" "$(grep -E '^== ' "$out" | tail -n 1)" ;;
    2) printf '! %-22s cannot run here: %s\n' "$t" "$(head -n 1 "$out")" ;;
    *) printf 'x %-22s failed (exit %s):\n' "$t" "$trc"; { grep -E '^(FAIL|info)' "$out" | head -n 25; } || true; tail -n 3 "$out"; rc=1 ;;
  esac
  rm -f "$out"
done
exit "$rc"
