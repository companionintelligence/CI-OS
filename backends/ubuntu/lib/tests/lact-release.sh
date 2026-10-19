#!/usr/bin/env bash
#=============================================================================
# Test: provision.sh installs the LACT .deb built for Ubuntu 26.04, never another release's
#
# provision.sh used to pick the first release asset whose name matched the regex 'amd64.deb'. The "." is any character,
# so that is also "amd64.debian": the Debian 13 build, listed first, was the one installed on Ubuntu. The selector is
# now backends/ubuntu/lib/lact-release.sh (lact_pick_asset), keyed on the series suffix of the asset name.
#
# The fixture is the real asset list of the LACT v0.10.1 release (names, sizes, URLs), read from
#   https://api.github.com/repos/ilya-zlobintsev/LACT/releases/latest   on 2026-10-17
# trimmed to name, size and URL, and to the .deb, Arch and Flatpak builds (the .rpm builds are left out: nothing here installs
# them). The checksum cases add a "digest" to two assets at run time (the live API sends one on every asset).
#
# Needs python3 and bash. No network, no root. bash 3.2 safe.
#   backends/ubuntu/lib/tests/lact-release.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lact-release.sh"
FIXTURE="$HERE/fixtures/lact-release-v0.10.1.json"
[[ -f "$LIB" && -f "$FIXTURE" ]] || { echo "missing $LIB or $FIXTURE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is needed" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lact-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=../lact-release.sh
source "$LIB"
set +e +u

BASE="https://github.com/ilya-zlobintsev/LACT/releases/download/v0.10.1"
echo "== the series comes from the Ubuntu release"
( ci_os_ubuntu_version_id() { echo 26.04; }; [[ "$(lact_series)" == "ubuntu-2604" ]] ) && pass "26.04 -> ubuntu-2604" || fail "26.04 did not give ubuntu-2604"
( ci_os_ubuntu_version_id() { echo 24.04; }; [[ "$(lact_series)" == "ubuntu-2404" ]] ) && pass "24.04 -> ubuntu-2404 (the mapping is mechanical)" || fail "24.04 did not give ubuntu-2404"

echo
echo "== the choice from the real asset list"
got="$(lact_pick_asset ubuntu-2604 <"$FIXTURE")"
eq "ubuntu-2604 picks the GUI deb of that series" "${got%%$'\t'*}" "$BASE/lact-0.10.1-0.amd64.ubuntu-2604.deb"
eq "  and has no sha256 when the release lists none" "${got#*$'\t'}" ""
eq "ubuntu-2404 picks the 2404 build (proves the series decides)" "$(lact_pick_asset ubuntu-2404 <"$FIXTURE" | cut -f1)" "$BASE/lact-0.10.1-0.amd64.ubuntu-2404.deb"
eq "debian-13 picks the Debian build" "$(lact_pick_asset debian-13 <"$FIXTURE" | cut -f1)" "$BASE/lact-0.10.1-0.amd64.debian-13.deb"
out="$(lact_pick_asset ubuntu-2804 <"$FIXTURE")"; rc=$?
eq "a series with no build gives nothing" "$out" ""
if [[ $rc -ne 0 ]]; then pass "  and status 1, so the caller stops instead of installing another build"; else fail "  status was 0"; fi
for s in ubuntu-26 ubuntu-260 ubuntu "ubuntu-2604.deb" ".*" "ubuntu-26.4"; do
    eq "'$s' (a prefix or a pattern, not a series) picks nothing" "$(lact_pick_asset "$s" <"$FIXTURE")" ""
done
case "$(lact_pick_asset ubuntu-2604 <"$FIXTURE")" in *headless*) fail "the headless build was picked";; *) pass "the headless build (no GUI) is never picked";; esac

echo
echo "== the old selector took the Debian build; the new one cannot"
old="$(grep -o '"browser_download_url": "[^"]*"' "$FIXTURE" | grep 'amd64.deb' | cut -d '"' -f 4 | head -n 1)"
eq "grep 'amd64.deb' (the old code) picked" "$old" "$BASE/lact-0.10.1-0.amd64.debian-13.deb"

echo
echo "== the checksum from the release's digest field"
python3 - "$FIXTURE" "$TMP/with-digest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for a in d["assets"]:
    if a["name"].endswith("amd64.ubuntu-2604.deb") and a["name"].startswith("lact-0"):
        a["digest"] = "sha256:" + "ab" * 32
    if a["name"].endswith("amd64.ubuntu-2404.deb") and a["name"].startswith("lact-0"):
        a["digest"] = "md5:not-a-sha256"
json.dump(d, open(sys.argv[2], "w"))          # compact, one line: the parser must not depend on the layout
PY
got="$(lact_pick_asset ubuntu-2604 <"$TMP/with-digest.json")"
eq "sha256 digest is returned after the URL" "${got#*$'\t'}" "$(printf 'ab%.0s' $(seq 1 32))"
eq "  and the URL is unchanged" "${got%%$'\t'*}" "$BASE/lact-0.10.1-0.amd64.ubuntu-2604.deb"
got="$(lact_pick_asset ubuntu-2404 <"$TMP/with-digest.json")"
eq "a digest that is not sha256 is ignored" "${got#*$'\t'}" ""

echo
echo "== unusable input never yields a URL"
for bad in "" "not json" "{}" '{"assets": null}' '{"assets": [{"name": 7}]}' '[]' '{"message": "API rate limit exceeded"}'; do
    out="$(printf '%s' "$bad" | lact_pick_asset ubuntu-2604 2>/dev/null)"; rc=$?
    if [[ -z "$out" && $rc -ne 0 ]]; then pass "'${bad:-<empty>}' -> nothing, status $rc"; else fail "'${bad:-<empty>}' gave '$out' (status $rc)"; fi
done

echo
echo "== provision.sh uses the selector"
PROV="$HERE/../../provision/provision.sh"
if grep -q 'lact_pick_asset' "$PROV" && grep -q 'lact-release.sh' "$PROV"; then pass "install_lact calls lact_pick_asset"; else fail "install_lact does not use lact_pick_asset"; fi
if grep -v '^ *#' "$PROV" | grep -q "grep 'amd64.deb'"; then fail "the old amd64.deb grep is still in provision.sh"; else pass "the old amd64.deb grep is gone"; fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
