#!/bin/bash
#=============================================================================
# Runner for the tests of core/headless/payload: the setup portal's backend, hotspot scripts, monitor and the installers
# of every backend that ships them. No root, no network, no radio, no Docker. bash 3.2 compatible.
#
#   core/headless/tests/payload/run.sh            run everything, one line per suite
#   core/headless/tests/payload/run.sh -v         also print every suite's own output
#   core/headless/tests/payload/run.sh SUITE...   only these (file names, e.g. test_static.py test_monitor.sh)
#
#   PAYLOAD_DIR=/some/copy run.sh                 test another copy of the payload (the mutation checker does this)
#
# Needs python3 (stdlib only) and bash. Flask is optional: with the real Flask installed the backend tests use it;
# without it they use standin/flask.py and say so. flock(1) is optional: the shell tests bring a stand-in.
#
# Exit status: 0 all suites passed, 1 a suite failed, 2 cannot run here (no python3, no scratch directory). A skipped test
# is printed, never silent.
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
SUITES=()
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=1 ;;
        -h|--help) sed -n '2,/^#====/p' "$0" | sed -e '/^#====/d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *) SUITES+=("$arg") ;;
    esac
done
if [ ${#SUITES[@]} -eq 0 ]; then
    SUITES=(test_static.py test_prescan.py test_setup_service.py test_hotspot_start.sh test_monitor.sh)
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "payload tests: cannot run here (python3 not found)" >&2
    exit 2
fi
export PYTHONDONTWRITEBYTECODE=1

flask_kind="$(python3 -B -c '
import sys
try:
    import flask
    print("real Flask " + getattr(flask, "__version__", "?"))
except ImportError:
    print("stand-in (real Flask is not installed here; standin/flask.py)")
')"
echo "payload tests: python3 $(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'), bash ${BASH_VERSION%%(*}, flask: $flask_kind"
if ! command -v flock >/dev/null 2>&1; then
    echo "  note: no flock(1) on this machine; the shell tests use their python flock stand-in"
fi

failed=0
ran=0
# The only directory this script ever removes is the one made here, and only when mktemp really made it.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/payload-run.XXXXXX")" || tmp=""
case "$tmp" in
    /*/payload-run.*) ;;
    *) echo "payload tests: cannot create a scratch directory (mktemp failed); nothing was run" >&2; exit 2 ;;
esac
trap 'case "$tmp" in /*/payload-run.*) rm -rf "$tmp" ;; esac' EXIT

for suite in "${SUITES[@]}"; do
    path="$HERE/$suite"
    if [ ! -f "$path" ]; then
        echo "  ✖ $suite: no such suite"
        failed=$((failed + 1))
        continue
    fi
    ran=$((ran + 1))
    out="$tmp/$suite.out"
    rc=0
    case "$suite" in
        *.py) python3 -B "$path" > "$out" 2>&1 || rc=$? ;;
        *.sh) bash "$path" > "$out" 2>&1 || rc=$? ;;
    esac
    if [ "$rc" -eq 2 ] && [ "${suite##*.}" = sh ]; then
        echo "  - $suite: cannot run here: $(grep -m1 '^payload tests:' "$out" || head -n 1 "$out")"
        continue
    fi
    case "$suite" in
        *.py)
            ran_line="$(grep -E '^Ran [0-9]+ test' "$out" | tail -n 1)"
            skips="$(grep -cE '\.\.\. skipped ' "$out" || true)"
            summary="${ran_line:-no result}"
            [ "${skips:-0}" -gt 0 ] && summary="$summary ($skips skipped)"
            ;;
        *.sh)
            summary="$(grep -E '^== [0-9]+ passed' "$out" | tail -n 1 | sed 's/^== //')"
            summary="${summary:-no result}"
            ;;
    esac
    if [ "$rc" -eq 0 ]; then
        echo "  ✔ $suite: $summary"
    else
        echo "  ✖ $suite: FAILED (exit $rc): $summary"
        failed=$((failed + 1))
        { grep -E '^(FAIL|ERROR:|FAILED|AssertionError|Traceback)' "$out" | head -n 40; } || true
        [ "$VERBOSE" -eq 1 ] || tail -n 12 "$out" | sed 's/^/      /'
    fi
    # visible skips
    { grep -E '^SKIP ' "$out" | sed 's/^/      /'; } || true
    if [ "$VERBOSE" -eq 1 ]; then sed 's/^/      | /' "$out"; fi
done

echo "== $ran suites run, $failed failed"
[ "$failed" -eq 0 ]
