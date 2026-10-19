#!/usr/bin/env bash
# Unit tests of the ci_setup library (core/headless/ci_setup): python3 standard library only, no root, no hardware, no network.
#
#   core/headless/tests/ci_setup/run.sh [--quick] [--no-mutation] [--pythons "python3 python3.9"] [-v]
#
# What runs: py_compile of the package and the tests (bytecode goes to a temporary directory, never into the tree), the
# unittest suites (validators, parsers, regulatory domain, probe, policy, credentials, QR payload, captive answers, job state
# machine, renderers, command line, repository hygiene, seeded fuzz of every validator and parser), the library's own
# `python3 -m ci_setup selftest`, and the mutation check of the security-relevant functions (mutation_check.py).
#
#   --quick          small fuzz sizes (CI_SETUP_FUZZ_N=4000) and no mutation check: about half a minute
#   --no-mutation    skip the mutation check only
#   --pythons "..."  run the unittest step once per interpreter (default: $PYTHON or python3)
#   -v               show every test name
#
# Environment: PYTHON (interpreter), CI_SETUP_FUZZ_N / CI_SETUP_FUZZ_SEED (fuzz size and seed),
# CI_SETUP_UPDATE_GOLDEN=1 (rewrite the golden files; read the diff before committing).
# Needs bash 3.2 or newer. Exit status: 0 all passed, 1 a check failed, 2 cannot run here (no python3 3.8 or newer).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADLESS="$(cd "$HERE/../.." && pwd)"
PYTHONS="${PYTHON:-python3}"
quick=0
mutation=1
verbose=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) quick=1; mutation=0 ;;
    --no-mutation) mutation=0 ;;
    --pythons) shift; PYTHONS="${1:-}" ;;
    -v) verbose=1 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# the first interpreter does the single-run steps (compile, selftest, mutation)
FIRST="${PYTHONS%% *}"
if ! command -v "$FIRST" >/dev/null 2>&1; then
  echo "cannot run: $FIRST not found" >&2
  exit 2
fi
if ! "$FIRST" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
  echo "cannot run: $FIRST is older than Python 3.8" >&2
  exit 2
fi

export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$HEADLESS${PYTHONPATH:+:$PYTHONPATH}"
if [ "$quick" = 1 ] && [ -z "${CI_SETUP_FUZZ_N:-}" ]; then
  export CI_SETUP_FUZZ_N=4000
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci-setup-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
rc=0

echo "-- py_compile ($FIRST)"
pyfiles="$TMP/pyfiles"
find "$HEADLESS/ci_setup" "$HERE" -name '*.py' -not -path '*/__pycache__/*' | sort > "$pyfiles"
compile_files=()
while IFS= read -r f; do compile_files+=("$f"); done < "$pyfiles"
if PYTHONPYCACHEPREFIX="$TMP/pyc" "$FIRST" -m py_compile "${compile_files[@]}"; then
  echo "   ${#compile_files[@]} files compile"
else
  echo "FAIL: py_compile"; rc=1
fi

tests_total=0
for py in $PYTHONS; do
  if ! command -v "$py" >/dev/null 2>&1; then
    echo "-- unittest ($py): SKIPPED, not installed"
    continue
  fi
  echo "-- unittest ($py $("$py" --version 2>&1 | awk '{print $2}'))"
  log="$TMP/unittest.$$.log"
  uflag=""
  [ "$verbose" = 1 ] && uflag="-v"
  # cd into the tests directory so test modules and helpers import by name; the package comes from PYTHONPATH
  if (cd "$HERE" && "$py" -W default -m unittest discover -s . -p 'test_*.py' $uflag) > "$log" 2>&1; then
    ran="$(grep -E '^Ran [0-9]+ tests?' "$log" | awk '{print $2}')"
    [ "$verbose" = 1 ] && cat "$log"
    echo "   $(grep -E '^Ran ' "$log"), OK"
    tests_total="${ran:-0}"
  else
    echo "FAIL: unittest under $py"; tail -n 60 "$log"; rc=1
  fi
  rm -f "$log"
done

echo "-- selftest ($FIRST -m ci_setup selftest)"
if sres="$(cd "$HEADLESS" && "$FIRST" -m ci_setup selftest 2>&1)"; then
  echo "   $(printf '%s\n' "$sres" | "$FIRST" -c 'import json, sys; d = json.load(sys.stdin); print("%d of %d checks ok" % (sum(1 for c in d["checks"] if c["ok"]), len(d["checks"])))')"
else
  echo "FAIL: selftest"; printf '%s\n' "$sres" | tail -n 40; rc=1
fi

mutants="skipped"
if [ "$mutation" = 1 ]; then
  echo "-- mutation check"
  if mres="$("$FIRST" "$HERE/mutation_check.py" 2>&1)"; then
    mutants="$(printf '%s\n' "$mres" | grep -E '^== mutation' | tail -n 1 | sed 's/^== mutation: //')"
    echo "   $mutants"
  else
    echo "FAIL: mutation check"; printf '%s\n' "$mres" | tail -n 40; rc=1
  fi
fi

if [ "$rc" = 0 ]; then
  echo "== ci_setup: $tests_total tests OK, selftest OK, mutation check: $mutants"
else
  echo "== ci_setup: FAILED"
fi
exit "$rc"
