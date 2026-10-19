#!/usr/bin/env bash
#=============================================================================
# Test: pull-progress-filter keeps a model download readable in the log and the journal, and never hides what is not progress
#
# The fixture, fixtures/ollama-pull-raw.txt, is the REAL start of the first-boot log of an installed arm64 image (2026-10-19, QEMU/HVF): apt output,
# the first-boot script's own lines, and the raw `ollama pull` progress of two models, 330 lines of it with its escape sequences.
# Also pins how provision.sh uses the filter (pipefail, the failure is remembered, a checkout without the helper falls back to cat).
#   backends/ubuntu/chroot/tests/pull-progress-filter.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="$HERE/../payload/first-boot/usr/libexec/ci-os/pull-progress-filter"
FIX="$HERE/fixtures/ollama-pull-raw.txt"
PROV="$HERE/../../provision/provision.sh"
for f in "$FILTER" "$FIX" "$PROV"; do [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }; done
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ppf.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
ESC="$(printf '\033')"

sh "$FILTER" < "$FIX" > "$TMP/out.txt"
in_lines="$(wc -l < "$FIX" | tr -d ' ')"; out_lines="$(wc -l < "$TMP/out.txt" | tr -d ' ')"
in_esc="$(grep -c "$ESC" "$FIX" | tr -d ' ')"
echo "== the real fixture ($in_lines lines, $(wc -c < "$FIX" | tr -d ' ') bytes, $in_esc lines with escape sequences)"
[[ "$in_esc" -gt 100 ]] && pass "the fixture is raw progress output (escape sequences in $in_esc lines), so the test means something" || fail "the fixture has too few escape sequences ($in_esc)"
eq "no escape character is left" "$(grep -c "$ESC" "$TMP/out.txt" | tr -d ' ')" "0"
in_pull="$(grep -c 'pulling' "$FIX" | tr -d ' ')"; out_pull="$(grep -c 'pulling' "$TMP/out.txt" | tr -d ' ')"
[[ "$in_pull" -gt 0 && "$out_pull" -lt $((in_pull * 20 / 100)) ]] && pass "the progress lines are under 20 percent of the input's ($out_pull of $in_pull); the rest of the file is apt and script output that stays ($out_lines of $in_lines lines in all)" || fail "the progress lines are $out_pull of $in_pull"
eq "'pulling manifest' is written once per run" "$(grep -c '^pulling manifest$' "$TMP/out.txt" | tr -d ' ')" "1"
worst=0
for id in $(grep -o -E '^pulling [0-9a-f]{12}' "$TMP/out.txt" | sort -u | cut -d' ' -f2); do
    n="$(grep -c "^pulling $id:" "$TMP/out.txt" | tr -d ' ')"; [[ "$n" -gt "$worst" ]] && worst="$n"
done
[[ "$worst" -ge 1 && "$worst" -le 11 ]] && pass "no layer has more than 11 progress lines (one per 10 percent; the worst has $worst)" || fail "a layer has $worst progress lines"
# every non-progress line of the input appears in the output, once
missing=0
while IFS= read -r l; do
    clean="$(printf '%s' "$l" | sed "s/${ESC}\\[[0-9;?]*[A-Za-z]//g" | sed 's/[[:space:]]*$//')"
    [[ -z "$clean" || "$clean" == pulling* ]] && continue
    grep -qxF -- "$clean" "$TMP/out.txt" || { missing=$((missing + 1)); echo "      lost: $clean"; }
done < <(grep -v 'pulling' "$FIX" | head -n 120)
eq "the first 120 non-progress lines (apt, the first-boot script, provision.sh) are all still there" "$missing" "0"
eq "the progress it keeps still shows a size and a layer id" "$(grep -c -E '^pulling [0-9a-f]{12}: +[0-9]+% .*[0-9] (MB|KB|B)/' "$TMP/out.txt" | tr -d ' ' | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"

echo
echo "== small cases"
printf 'pulling manifest \n' | sh "$FILTER" > "$TMP/a.txt"; eq "a lone 'pulling manifest' passes" "$(cat "$TMP/a.txt")" "pulling manifest"
printf 'Error: pull model manifest: file does not exist\n' | sh "$FILTER" > "$TMP/b.txt"; eq "an error line passes untouched" "$(cat "$TMP/b.txt")" "Error: pull model manifest: file does not exist"
printf 'writing manifest \nsuccess \n' | sh "$FILTER" > "$TMP/c.txt"; eq "the closing lines pass, trailing blanks trimmed" "$(tr '\n' '|' < "$TMP/c.txt")" "writing manifest|success|"
: | sh "$FILTER" > "$TMP/d.txt"; eq "empty input gives empty output" "$(wc -c < "$TMP/d.txt" | tr -d ' ')" "0"
{ for p in 1 2 3 9 10 11 19 20 55 99 100; do printf 'pulling 0123456789ab: %3d%% \342\226\225\342\226\210\342\226\210        \342\226\217 %d MB/100 MB\n' "$p" "$p"; done; } | sh "$FILTER" > "$TMP/e.txt"
eq "11 redraws of one layer keep the first of each 10-percent bucket (1 2 3 9 | 10 11 19 | 20 | 55 | 99 | 100 -> 1 10 20 55 99 100)" "$(grep -o -E ': +[0-9]+%' "$TMP/e.txt" | tr -d ': %' | tr '\n' ' ')" "1 10 20 55 99 100 "
printf 'pulling aaaaaaaaaaaa:  50%% x\npulling bbbbbbbbbbbb:  50%% x\npulling aaaaaaaaaaaa:  51%% x\n' | sh "$FILTER" > "$TMP/f.txt"
eq "layers are counted separately" "$(grep -c . "$TMP/f.txt" | tr -d ' ')" "2"
printf 'line\n' | sh "$FILTER" | sh "$FILTER" > "$TMP/g.txt"; eq "filtering twice changes nothing" "$(cat "$TMP/g.txt")" "line"

echo
echo "== how provision.sh uses it"
eq "the helper is used when installed, cat otherwise" "$(grep -c -E 'PULL_FILTER=cat|-x /usr/libexec/ci-os/pull-progress-filter \]\] && PULL_FILTER=' "$PROV" | tr -d ' ')" "2"
eq "the three pulls go through it" "$(grep -c -E 'ollama pull [^ ]+ 2>&1 \| \$PULL_FILTER \|\| rc=1' "$PROV" | tr -d ' ')" "3"
eq "pipefail is set so a failed pull is not hidden by the filter" "$(sed -n '/PULL_FILTER=cat/,/^EOF$/p' "$PROV" | grep -c -x 'set -o pipefail' | tr -d ' ')" "1"
eq "a failed pull sets the exit status" "$(sed -n '/PULL_FILTER=cat/,/^EOF$/p' "$PROV" | grep -c -x 'exit \\$rc' | tr -d ' ')" "1"
eq "the image installs the helper" "$(grep -c 'pull-progress-filter" "$CHROOT_PATH/usr/libexec/ci-os/pull-progress-filter"' "$HERE/../customize-chroot.sh" | tr -d ' ')" "1"
# the failure semantics, run for real with stub ollama and filter
cat > "$TMP/ollama" <<'STUB'
#!/bin/sh
printf 'pulling manifest \n'; exit "${STUB_PULL_RC:-0}"
STUB
chmod +x "$TMP/ollama"
for rc in 0 3; do
    got="$(env PATH="$TMP:$PATH" STUB_PULL_RC=$rc F="$FILTER" bash -c 'set -o pipefail; rc=0; ollama pull x 2>&1 | sh "$F" >/dev/null || rc=1; echo $rc')"
    eq "a pull that exits $rc through the filter leaves rc=$([ $rc = 0 ] && echo 0 || echo 1)" "$got" "$([ $rc = 0 ] && echo 0 || echo 1)"
done

echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
