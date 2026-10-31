#!/usr/bin/env bash
# Test: core/lib/check-guards.sh, the workflow and secret guard. A failing and a passing case for every rule, the allow-list, the exit
# status, and four planted defects.
#
# Every case is a throw-away git repository that holds one workflow, composite action, key file or allow-list; the guard runs on it and
# the case reads its exit status and its FAIL lines. Then four mutants of the guard (copies with one decisive line weakened) run the same
# cases through CI_GUARDS_SCRIPT, and each must turn a named case red while a control case stays green: that is the proof that the cases
# can see the defect each mutant plants.
#
# Neither this file nor the guard holds a private-key header or a line of the ci-local gated markers: both are put together at run time,
# and a check below fails if one of them appears.
#
# bash 3.2 with git, awk, grep, cut, tr and cmp; no root, no network; writes only to a temporary directory.
#   bash core/lib/tests/guards.sh
#   CI_GUARDS_SCRIPT=<a copy of check-guards.sh> bash core/lib/tests/guards.sh     # the cases only, against that copy
# CI_GUARDS_CASES (case names, one per line) limits a run to those cases; the planted defects use it to run two cases each.
#
# © Companion Intelligence, Lifescope Inc
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
REAL_GUARD="$(cd "$HERE/.." && pwd)/check-guards.sh"
G="${CI_GUARDS_SCRIPT:-$REAL_GUARD}"
CASES_ONLY=0
[ "${1:-}" = --cases-only ] && CASES_ONLY=1

for tool in git awk grep cut tr cmp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "guards test: $tool is needed" >&2; exit 2; }
done
[ -f "$G" ] || { echo "guards test: no guard at $G" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/guards-test.XXXXXX")" || { echo "guards test: cannot make a temporary directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
# The fixtures must not depend on the user's git configuration (a global ignore file could hide a fixture from git add or ls-files).
: > "$WORK/gitconfig"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s -- %s\n' "$1" "$2"; }

# The markers, put together here so that this file holds neither.
KD='-----'; KB='BEGIN'; KE='END'; KP='PRIVATE KEY'
GATE_OPEN="# >>> ci-local"":gated original triggers below, restore with \`ci-local restore\`"
GATE_CLOSE="# <<< ci-local"":gated"

SHA="0123456789abcdef0123456789abcdef01234567"                               # synthetic, 40 lowercase hex
DIGEST="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"     # synthetic, 64 lowercase hex
WF=.github/workflows/ci.yml

REPO=""
fixture() { REPO="$(mktemp -d "$WORK/repo.XXXXXX")" && git -C "$REPO" init -q; }
put() { mkdir -p "$REPO/$(dirname "$1")" && cat > "$REPO/$1"; }
track() { git -C "$REPO" add -f -- "$@"; }
# at FILE TEXT: "FILE:LINE" for the first line of FILE (in the fixture) that holds TEXT
at() { printf '%s:%s' "$1" "$(grep -n -F -- "$2" "$REPO/$1" | head -n 1 | cut -d: -f1)"; }

# wf_steps FILE LINE...: a workflow that is clean apart from the lines given, which go under "steps:"
wf_steps() {
  local f="$1"; shift
  { printf 'name: case\non:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  job:\n    runs-on: ubuntu-24.04\n    steps:\n'
    printf '%s\n' "$@"; } | put "$f"
}
# wf_on FILE LINE...: a clean workflow whose lines before "permissions:" are the lines given (the on: block)
wf_on() {
  local f="$1"; shift
  { printf 'name: case\n'; printf '%s\n' "$@"
    printf 'permissions:\n  contents: read\njobs:\n  job:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ok\n'; } | put "$f"
}
# wf_call FILE LINE: a clean workflow with one job that calls a pinned reusable workflow; LINE is its secrets: line
wf_call() {
  printf 'name: case\non:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  call:\n    uses: example-org/example-repo/.github/workflows/x.yml@%s # v1.0.0\n%s\n' "$SHA" "$2" | put "$1"
}
# key FILE TYPE: a tracked text file with a private-key block of TYPE (RSA, EC, OPENSSH, PGP, or PKCS8 for the bare header) on line 2;
# the body is filler, not key material
key() {
  local hdr ftr
  case "$2" in
    PGP)   hdr="$KD$KB PGP $KP BLOCK$KD"; ftr="$KD$KE PGP $KP BLOCK$KD" ;;
    PKCS8) hdr="$KD$KB $KP$KD";           ftr="$KD$KE $KP$KD" ;;
    *)     hdr="$KD$KB $2 $KP$KD";        ftr="$KD$KE $2 $KP$KD" ;;
  esac
  printf 'a test fixture\n%s\nAAAAnotakeyAAAA\n%s\n' "$hdr" "$ftr" | put "$1"
  track "$1"
}

# t NAME pass                              exit 0 and no output
# t NAME fail RULE FILE:LINE [COUNT]       exit 1, a line "FAIL RULE FILE:LINE ...", and COUNT FAIL lines in all (default 1)
# t NAME cannot                            exit 2
# With CI_GUARDS_CASES set (one case name per line), only those cases run: a mutant's run needs two of them.
t() {
  local name="$1" want="$2" out rc n
  if [ -n "${CI_GUARDS_CASES:-}" ]; then printf '%s\n' "$CI_GUARDS_CASES" | grep -q -x -F -- "$name" || return 0; fi
  out="$(bash "$G" "$REPO" 2>&1)"; rc=$?
  case "$want" in
    pass)
      if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "$name"
      else fail "$name" "exit $rc, wanted 0 and no output: $(printf '%s' "$out" | head -n 3 | tr '\n' '|')"; fi ;;
    fail)
      n="$(printf '%s\n' "$out" | grep -c '^FAIL ')"
      if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q -F -- "FAIL $3 $4 " && [ "$n" -eq "${5:-1}" ]; then pass "$name"
      else fail "$name" "exit $rc and $n FAIL lines, wanted 1, ${5:-1} and 'FAIL $3 $4': $(printf '%s' "$out" | head -n 4 | tr '\n' '|')"; fi ;;
    cannot)
      if [ "$rc" -eq 2 ]; then pass "$name"
      else fail "$name" "exit $rc, wanted 2: $(printf '%s' "$out" | head -n 2 | tr '\n' '|')"; fi ;;
  esac
}

echo "== unpinned-uses"
for ref in v4 main; do
  fixture; wf_steps "$WF" "      - uses: example-org/example-action@$ref"
  t "unpinned-uses refuses a tag or a branch (@$ref)" fail unpinned-uses "$(at "$WF" "@$ref")"
done
fixture; wf_steps "$WF" "      - uses: example-org/example-action@${SHA%?}"
t "unpinned-uses refuses a 39 character sha" fail unpinned-uses "$(at "$WF" example-action@)"
fixture; wf_steps "$WF" "      - uses: example-org/example-action@${SHA}0"
t "unpinned-uses refuses a 41 character sha" fail unpinned-uses "$(at "$WF" example-action@)"
fixture; wf_steps "$WF" "      - uses: example-org/example-action@$(printf '%s' "$SHA" | tr 'a-f' 'A-F')"
t "unpinned-uses refuses an uppercase sha" fail unpinned-uses "$(at "$WF" example-action@)"
fixture; wf_steps "$WF" "      - uses: docker://alpine:3"
t "unpinned-uses refuses a docker image by tag (docker://alpine:3)" fail unpinned-uses "$(at "$WF" docker://)"
fixture; wf_steps "$WF" "      - uses: docker://alpine@sha256:${DIGEST%?}"
t "unpinned-uses refuses a docker digest that is one hex digit short" fail unpinned-uses "$(at "$WF" docker://)"
fixture
printf 'name: case\non:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  call:\n    uses: example-org/example-repo/.github/workflows/x.yml@v1\n' | put "$WF"
t "unpinned-uses refuses a reusable workflow called by tag" fail unpinned-uses "$(at "$WF" x.yml@v1)"
fixture; wf_steps "$WF" "      - {uses: example-org/example-action@$SHA}"
t "unpinned-uses refuses a flow-style step it cannot read" fail unpinned-uses "$(at "$WF" '{uses:')"
fixture
printf 'name: x\ndescription: a composite action\nruns:\n  using: composite\n  steps:\n    - uses: example-org/example-action@v4\n' | put .github/actions/x/action.yml
t "unpinned-uses reads composite actions (.github/actions/x/action.yml)" fail unpinned-uses "$(at .github/actions/x/action.yml @v4)"
fixture; wf_steps .github/workflows/ci.yaml "      - uses: example-org/example-action@v4"
t "unpinned-uses reads a .yaml workflow" fail unpinned-uses "$(at .github/workflows/ci.yaml @v4)"

fixture; wf_steps "$WF" "      - uses: example-org/example-action@$SHA # v4.4.0"
t "unpinned-uses accepts a 40 character sha with a release comment" pass
fixture; wf_steps "$WF" "      - uses: example-org/example-action@$SHA"
t "unpinned-uses accepts a 40 character sha without a comment" pass
fixture; wf_steps "$WF" "      - uses: \"example-org/example-action@$SHA\" # v4.4.0" "      - uses: 'example-org/other-action/path@$SHA'"
t "unpinned-uses accepts a quoted sha (double and single quotes, a path in the repository)" pass
fixture; wf_steps "$WF" "      - uses: ./.github/actions/x"
t "unpinned-uses accepts a local action (./.github/actions/x)" pass
fixture; wf_steps "$WF" "      - uses: docker://alpine@sha256:$DIGEST"
t "unpinned-uses accepts a docker image by digest" pass
fixture; wf_steps "$WF" "      # uses: a/b@v1" "      - uses: example-org/example-action@$SHA # v1.0.0"
t "unpinned-uses ignores a commented-out uses line" pass
fixture
printf 'name: case\non:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  call:\n    uses: example-org/example-repo/.github/workflows/x.yml@%s # v1.0.0\n' "$SHA" | put "$WF"
t "unpinned-uses accepts a reusable workflow called by sha" pass
fixture; wf_steps "$WF" "      - run: |" "          echo 'uses: example-org/example-action@v4'"
t "unpinned-uses does not read the text of a run block as YAML" pass
fixture; wf_steps .github/workflows/drafts/ci.yml "      - uses: example-org/example-action@v4"
t "a file below .github/workflows/<dir>/ is not read (GitHub runs only the top level)" pass

echo
echo "== dangerous-trigger"
fixture; wf_on "$WF" "on:" "  pull_request_target:"
t "dangerous-trigger refuses a live pull_request_target trigger" fail dangerous-trigger "$(at "$WF" pull_request_target)"
fixture; wf_on "$WF" "on:" "  workflow_run:" "    workflows: [build]" "    types: [completed]"
t "dangerous-trigger refuses a live workflow_run trigger" fail dangerous-trigger "$(at "$WF" workflow_run)"
fixture; wf_on "$WF" "on: [push, pull_request_target]"
t "dangerous-trigger refuses a flow-style trigger list" fail dangerous-trigger "$(at "$WF" pull_request_target)"
fixture; wf_on "$WF" "# pull_request_target and workflow_run are never used here" "on:" "  workflow_dispatch:"
t "dangerous-trigger lets an ordinary comment name the triggers" pass
fixture; wf_on "$WF" "$GATE_OPEN" "# on: [pull_request_target]" "$GATE_CLOSE" "on:" "  workflow_dispatch:"
t "dangerous-trigger refuses pull_request_target inside the gated block" fail dangerous-trigger "$(at "$WF" '# on: [pull_request_target]')"
fixture; wf_on "$WF" "$GATE_OPEN" "# on:" "#   push:" "#     branches: [main]" "$GATE_CLOSE" "on:" "  workflow_dispatch:"
t "dangerous-trigger accepts a gated block that restores harmless triggers" pass

echo
echo "== secrets-inherit"
fixture; wf_call "$WF" "    secrets: inherit"
t "secrets-inherit refuses secrets: inherit" fail secrets-inherit "$(at "$WF" 'secrets:')"
fixture; wf_call "$WF" "    secrets:  inherit"
t "secrets-inherit refuses extra spaces (secrets:  inherit)" fail secrets-inherit "$(at "$WF" 'secrets:')"
fixture; wf_call "$WF" "    secrets: \"inherit\""
t "secrets-inherit refuses the double-quoted form" fail secrets-inherit "$(at "$WF" 'secrets:')"
fixture; wf_call "$WF" "    secrets: 'inherit'"
t "secrets-inherit refuses the single-quoted form" fail secrets-inherit "$(at "$WF" 'secrets:')"
fixture; wf_call "$WF" "    secrets: inherit   # every secret"
t "secrets-inherit refuses it with a trailing comment" fail secrets-inherit "$(at "$WF" 'secrets:')"
fixture; wf_call "$WF" "    secrets:"$'\n'"      token: \${{ secrets.EXAMPLE_TOKEN }}"
t "secrets-inherit accepts secrets named one by one" pass

echo
echo "== the allow-list (core/lib/guards.allow)"
fixture; wf_call "$WF" "    secrets: inherit"
printf 'secrets-inherit\t%s\tthe called workflow is ours and needs every secret\n' "$WF" | put core/lib/guards.allow
t "an allow-list entry with a reason excuses the finding" pass
fixture; wf_call "$WF" "    secrets: inherit"
printf '# a comment line\n\nsecrets-inherit\t.github/workflows/*.yml\ta glob entry of the test fixture\n' | put core/lib/guards.allow
t "an allow-list entry may be a glob; comment and empty lines are skipped" pass
fixture; wf_steps "$WF" "      - uses: example-org/example-action@$SHA # v1.0.0"
printf 'secrets-inherit\t%s\tnothing in this file needs it any more\n' "$WF" | put core/lib/guards.allow
t "a stale allow-list entry is itself a finding (stale-allow)" fail stale-allow "core/lib/guards.allow:1"
fixture; wf_call "$WF" "    secrets: inherit"
printf 'secrets-inherit\t%s\tshort\n' "$WF" | put core/lib/guards.allow
t "a reason shorter than 8 characters is refused, and excuses nothing" fail allow-syntax "core/lib/guards.allow:1" 2
fixture; wf_steps "$WF" "      - uses: example-org/example-action@$SHA # v1.0.0"
printf 'no-such-rule\t%s\ta reason that is long enough\n' "$WF" | put core/lib/guards.allow
t "an entry for an unknown rule is refused" fail allow-syntax "core/lib/guards.allow:1"
fixture; wf_steps "$WF" "      - uses: example-org/example-action@$SHA # v1.0.0"
printf 'secrets-inherit %s a reason with spaces and no tab\n' "$WF" | put core/lib/guards.allow
t "a line that is not three tab separated columns is refused" fail allow-syntax "core/lib/guards.allow:1"
fixture; wf_call "$WF" "    secrets: inherit"
printf 'secrets-inherit\t./%s\ta path written with a leading ./\n' "$WF" | put core/lib/guards.allow
t "a path with a leading ./ is refused" fail allow-syntax "core/lib/guards.allow:1" 2

echo
echo "== private-key"
for kt in RSA EC OPENSSH PGP PKCS8; do
  fixture; key "keys/$kt.txt" "$kt"
  t "private-key refuses a private key block: $kt" fail private-key "keys/$kt.txt:2"
done
fixture; wf_steps "$WF" "      - uses: example-org/example-action@$SHA # v1.0.0" "      # $KD$KB RSA $KP$KD"; track "$WF"
t "private-key reads comment lines too (a key in a comment is still a key)" fail private-key "$(at "$WF" "$KB RSA")"
fixture
printf 'a test fixture\n%s%s PGP PUBLIC KEY BLOCK%s\nmQINBF\n%s%s PGP PUBLIC KEY BLOCK%s\n' "$KD" "$KB" "$KD" "$KD" "$KE" "$KD" | put keys/public.asc
track keys/public.asc
t "private-key accepts a PGP public key block" pass
fixture
printf '%s%s CERTIFICATE%s\nMIIB\n%s%s CERTIFICATE%s\n' "$KD" "$KB" "$KD" "$KD" "$KE" "$KD" | put certs/ca.pem
track certs/ca.pem
t "private-key accepts a certificate" pass
fixture; key fixtures/test-only.txt RSA
printf 'private-key\tfixtures/test-only.txt\ta synthetic header for a test, no key material\n' | put core/lib/guards.allow
t "private-key accepts an allow-listed file" pass

echo
echo "== missing-permissions"
fixture
printf 'name: case\non:\n  workflow_dispatch:\njobs:\n  job:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ok\n' | put "$WF"
t "missing-permissions refuses a workflow with no permissions block" fail missing-permissions "$(at "$WF" '  job:')"
fixture
printf 'name: case\non:\n  workflow_dispatch:\njobs:\n  # the first job\n  one:\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n    steps:\n      - run: echo ok\n  two:\n    runs-on: ubuntu-24.04\n    permissions: {}\n    steps:\n      - run: echo ok\n' | put "$WF"
t "missing-permissions accepts a permissions block on every job" pass
fixture
printf 'name: case\non:\n  workflow_dispatch:\njobs:\n  one:\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n    steps:\n      - run: echo ok\n  two:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ok\n' | put "$WF"
t "missing-permissions names the job without one when the top level has none" fail missing-permissions "$(at "$WF" '  two:')"
fixture
printf 'name: case\non:\n  workflow_dispatch:\npermissions: {}\njobs:\n  job:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ok\n' | put "$WF"
t "missing-permissions accepts a top-level block (permissions: {})" pass
fixture
printf 'name: x\ndescription: a composite action\nruns:\n  using: composite\n  steps:\n    - run: echo ok\n      shell: bash\n' | put .github/actions/x/action.yml
t "missing-permissions does not apply to a composite action" pass

echo
echo "== checkout-credentials"
fixture; wf_steps "$WF" "      - uses: actions/checkout@$SHA # v4.4.0"
t "checkout-credentials refuses a checkout that keeps its token" fail checkout-credentials "$(at "$WF" actions/checkout)"
fixture; wf_steps "$WF" "      - uses: actions/checkout@$SHA # v4.4.0" "        with:" "          persist-credentials: true"
t "checkout-credentials refuses persist-credentials: true" fail checkout-credentials "$(at "$WF" actions/checkout)"
fixture; wf_steps "$WF" "      - name: Checkout" "        uses: actions/checkout@$SHA # v4.4.0" "        with:" "          fetch-depth: 0" "          persist-credentials: false"
t "checkout-credentials accepts persist-credentials: false" pass
fixture; wf_steps "$WF" "      - uses: actions/checkout@$SHA # v4.4.0" "        with:" "          persist-credentials: \"false\""
t "checkout-credentials accepts the quoted form" pass
fixture; wf_steps "$WF" "      - uses: actions/checkout@$SHA # v4.4.0" "      - uses: example-org/example-action@$SHA # v1.0.0" "        with:" "          persist-credentials: false"
t "checkout-credentials reads the checkout's own step, not the next one" fail checkout-credentials "$(at "$WF" actions/checkout)"

echo
echo "== exit status and usage"
fixture
t "an empty repository is clean (exit 0, no output)" pass
REPO="$WORK/not-a-repository"; mkdir -p "$REPO"
t "a directory that is not a git work tree cannot be checked (exit 2)" cannot
REPO="$WORK/no-such-directory"
t "a directory that does not exist cannot be checked (exit 2)" cannot
if out="$(bash "$G" --help 2>&1)" && printf '%s\n' "$out" | grep -q 'Usage:'; then pass "--help prints the usage and exits 0"
else fail "--help prints the usage and exits 0" "$(printf '%s' "$out" | head -n 2 | tr '\n' '|')"; fi

echo
echo "== the guard and this test hold no marker"
KEY_RE="$KD$KB [A-Z0-9 ]*$KP( BLOCK)?$KD"
if grep -q -E -e "$KEY_RE" "$G" "$SELF"; then fail "no private-key header in the guard or this test" "one is there: assemble it at run time"
else pass "no private-key header in the guard or this test"; fi
GATE_RE='^[[:space:]]*#[[:space:]]*(>>>|<<<)[[:space:]]*ci-local:gated'
if grep -q -E -e "$GATE_RE" "$G" "$SELF"; then fail "no gated-block marker line in the guard or this test" "one is there: assemble it at run time"
else pass "no gated-block marker line in the guard or this test"; fi

# --- planted defects ---------------------------------------------------------------------------------------------------------------
# mutant NAME MARKER REPLACEMENT RED CONTROL: a copy of the real guard whose first line that holds MARKER is REPLACEMENT; the cases run
# against it (CI_GUARDS_SCRIPT), and the case RED must fail while the case CONTROL still passes.
mutant() {
  local name="$1" marker="$2" repl="$3" red="$4" ctl="$5" m="$WORK/mutant-$1.sh" out
  MARKER="$marker" REPL="$repl" awk 'index($0, ENVIRON["MARKER"]) && !done { print ENVIRON["REPL"]; done = 1; next } { print }' "$REAL_GUARD" > "$m"
  if cmp -s "$REAL_GUARD" "$m"; then fail "mutant $name" "its line is not in the guard any more; update the marker in this test"; return; fi
  if ! bash -n "$m" 2>/dev/null; then fail "mutant $name" "the mutant does not parse"; return; fi
  out="$(CI_GUARDS_SCRIPT="$m" CI_GUARDS_CASES="$red"$'\n'"$ctl" bash "$SELF" --cases-only 2>&1)"
  if printf '%s\n' "$out" | grep -q -F -- "FAIL  $red --"; then pass "mutant $name turns red: $red"
  else fail "mutant $name" "'$red' stayed green, so the cases cannot see this defect"; fi
  if printf '%s\n' "$out" | grep -q -x -F -- "PASS  $ctl"; then pass "  and leaves green: $ctl"
  else fail "mutant $name" "the control case '$ctl' is not green: the mutant is broken, not weakened"; fi
}

if [ "$CASES_ONLY" = 1 ]; then
  :
elif [ -n "${CI_GUARDS_SCRIPT:-}" ]; then
  echo
  echo "(CI_GUARDS_SCRIPT is set: the cases ran against $G; the planted defects run only against the real guard)"
else
  echo
  echo "== planted defects: each mutant turns its case red and leaves a control case green"
  mutant pin-accepts-any-ref 'function pinned_ref(' 'function pinned_ref(ref) { return (ref ~ /^[A-Za-z0-9._-]+$/) }' \
    "unpinned-uses refuses a tag or a branch (@v4)" "unpinned-uses accepts a 40 character sha with a release comment"
  # shellcheck disable=SC2016  # the replacement is a line of the guard's own source, expanded when the mutant runs
  mutant key-header-rsa-only 'KEY_RE=' 'KEY_RE="${KD}${KB} RSA ${KP}${KD}"' \
    "private-key refuses a private key block: OPENSSH" "private-key refuses a private key block: RSA"
  mutant workflows-only '.github/actions/action.yml|' '    .github/no-such-directory/*) ;;' \
    "unpinned-uses reads composite actions (.github/actions/x/action.yml)" "unpinned-uses refuses a tag or a branch (@v4)"
  mutant comments-read 'if (k == "C") continue' '' \
    "unpinned-uses ignores a commented-out uses line" "unpinned-uses refuses a tag or a branch (@v4)"
fi

echo
echo "== Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
