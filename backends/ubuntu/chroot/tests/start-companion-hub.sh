#!/usr/bin/env bash
#=============================================================================
# Test: the first-boot start of the Companion Hub (start_companion_hub and companion_hub_user in backends/ubuntu/provision/provision.sh)
#
# provision.sh runs main() when it is sourced, so the two functions are cut out of the file with sed and run against stub commands
# (getent, id, docker, sudo, usermod, companion-hub, timeout): no Docker, no root, no network.
#   backends/ubuntu/chroot/tests/start-companion-hub.sh
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$HERE/../../provision/provision.sh"
[[ -f "$PROV" ]] || { echo "missing $PROV" >&2; exit 2; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hubstart.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# the two functions, cut out of provision.sh
{ sed -n '/^companion_hub_user() {/,/^}/p' "$PROV"; sed -n '/^start_companion_hub() {/,/^}/p' "$PROV"; } > "$TMP/funcs.sh"
[[ "$(grep -c '^[a-z_]*() {' "$TMP/funcs.sh")" == 2 ]] || { echo "could not cut both functions out of $PROV" >&2; exit 2; }

BIN="$TMP/bin"; mkdir -p "$BIN"
cat >"$BIN/getent" <<'STUB'
#!/bin/sh
[ "$1" = passwd ] && cat "$STUB_PASSWD"
STUB
cat >"$BIN/id" <<'STUB'
#!/bin/sh
echo "${STUB_GROUPS:-users}"
STUB
cat >"$BIN/docker" <<'STUB'
#!/bin/sh
[ "$1 $2" = "compose version" ] && { [ -n "${STUB_COMPOSE:-}" ] && echo "$STUB_COMPOSE"; exit 0; }
exit 0
STUB
cat >"$BIN/usermod" <<'STUB'
#!/bin/sh
echo "usermod $*" >> "$STUB_LOG"
STUB
cat >"$BIN/timeout" <<'STUB'
#!/bin/sh
shift; exec "$@"
STUB
cat >"$BIN/sudo" <<'STUB'
#!/bin/sh
echo "sudo $*" >> "$STUB_LOG"
shift 3
exec "$@"
STUB
cat >"$BIN/companion-hub" <<'STUB'
#!/bin/sh
echo "companion-hub $*" >> "$STUB_LOG"
exit "${STUB_HUB_RC:-0}"
STUB
chmod +x "$BIN"/*
cat >"$TMP/passwd" <<'P'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
ci:x:1000:1000::/home/ci:/bin/sh
ollama:x:998:998::/usr/share/ollama:/bin/false
companion-demo:x:1001:1001:Companion Demo:/home/companion-demo:/bin/bash
later:x:1002:1002::/home/later:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
P

run() { # [extra env...]  -> runs start_companion_hub, sets RC, LOG
  : > "$TMP/log"
  OUT="$(env PATH="$BIN:$PATH" STUB_PASSWD="$TMP/passwd" STUB_LOG="$TMP/log" CI_OS_HUB_STAMP="$TMP/stamp" STUB_COMPOSE=2.40.3 STUB_GROUPS="companion-demo docker" "$@" bash -c '
      log_info() { echo "info: $*"; }; log_success() { echo "ok: $*"; }; log_warning() { echo "warn: $*"; }
      command_exists() { command -v "$1" >/dev/null 2>&1; }
      . "$1"; start_companion_hub' _ "$TMP/funcs.sh" 2>&1)"; RC=$?
  LOG="$(cat "$TMP/log")"
}
echo "== who is the human user"
eq "the lowest uid from 1000 with a login shell, not ci, not a service account" "$(env PATH="$BIN:$PATH" STUB_PASSWD="$TMP/passwd" bash -c '. "$1"; companion_hub_user' _ "$TMP/funcs.sh")" "companion-demo"
printf 'root:x:0:0::/root:/bin/bash\nci:x:1000:1000::/home/ci:/bin/sh\n' > "$TMP/passwd.none"
eq "no human user yet: empty" "$(env PATH="$BIN:$PATH" STUB_PASSWD="$TMP/passwd.none" bash -c '. "$1"; companion_hub_user' _ "$TMP/funcs.sh")" ""

echo
echo "== the start"
rm -f "$TMP/stamp"; run
eq "it starts the Hub once, as the human user, in a login-like home (sudo -u USER -H)" "$LOG" "sudo -u companion-demo -H timeout 1500 companion-hub --detached
companion-hub --detached"
eq "  exits 0 and writes the stamp" "$RC/$(test -s "$TMP/stamp" && echo stamp || echo none)" "0/stamp"
run
eq "with the stamp present it does nothing" "$LOG/$RC" "/0"
rm -f "$TMP/stamp"; run STUB_HUB_RC=1
eq "a failed start returns 1 (the first-boot retry runs it again) and writes no stamp" "$RC/$(test -e "$TMP/stamp" && echo stamp || echo none)" "1/none"
rm -f "$TMP/stamp"; run STUB_GROUPS="companion-demo users"
eq "a user not yet in the docker group is added to it first" "$(grep -c '^usermod -aG docker companion-demo$' <<<"$LOG" | tr -d ' ')" "1"
rm -f "$TMP/stamp"; run
eq "a user already in the docker group is not touched" "$(grep -c '^usermod' <<<"$LOG" | tr -d ' ')" "0"
for v in 2.33.0 2.33 3.0.1 2.40.3; do rm -f "$TMP/stamp"; run STUB_COMPOSE="$v"; eq "Compose $v is new enough" "$(grep -c 'companion-hub --detached$' <<<"$LOG" | tr -d ' ')" "2"; done
for v in 2.32.4 2.9.0 1.29.2; do rm -f "$TMP/stamp"; run STUB_COMPOSE="$v"; eq "Compose $v is too old: skipped with exit 0, no start" "$RC/$(grep -c 'companion-hub' <<<"$LOG" | tr -d ' ')" "0/0"; done
rm -f "$TMP/stamp"; run STUB_COMPOSE=""
eq "no Compose at all: skipped with exit 0, no start" "$RC/$(grep -c 'companion-hub' <<<"$LOG" | tr -d ' ')" "0/0"
rm -f "$TMP/stamp"; PASSWD_SAVE="$TMP/passwd"; cp "$TMP/passwd.none" "$TMP/passwd.use"
: > "$TMP/log"
OUT="$(env PATH="$BIN:$PATH" STUB_PASSWD="$TMP/passwd.none" STUB_LOG="$TMP/log" CI_OS_HUB_STAMP="$TMP/stamp" STUB_COMPOSE=2.40.3 bash -c '
    log_info() { echo "info: $*"; }; log_success() { echo "ok: $*"; }; log_warning() { echo "warn: $*"; }
    command_exists() { command -v "$1" >/dev/null 2>&1; }
    . "$1"; start_companion_hub' _ "$TMP/funcs.sh" 2>&1)"; RC=$?
eq "no human user: skipped with exit 0, no start" "$RC/$(grep -c 'companion-hub' "$TMP/log" | tr -d ' ')" "0/0"
rm -f "$BIN/companion-hub"
run
eq "Hub not installed: skipped with exit 0" "$RC/$(grep -c 'not installed' <<<"$OUT" | tr -d ' ')" "0/1"

echo
echo "== wiring in provision.sh"
eq "the start is called in the core tier right after deploy_ci_hub" "$(grep -n -A1 '^        deploy_ci_hub$' "$PROV" | grep -c 'start_companion_hub')" "1"
eq "nothing in the start function asks for a registry credential" "$(sed -n '/^start_companion_hub() {/,/^}/p' "$PROV" | grep -c -i -E 'REGISTRY_(USERNAME|PASSWORD)|docker login')" "0"

echo
echo "== Summary: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
