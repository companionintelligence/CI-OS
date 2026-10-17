#!/usr/bin/env bash
#=============================================================================
# Self-test of the installed-boot test's own parts (no Docker, no QEMU, a few seconds): the boot watcher's decisions against a fake
# QEMU, and the initrd audit against synthetic initramfs images.
#
#   backends/ubuntu/iso/tests/installed-boot.sh --selftest        (or run this file)
#
# Needs python3 (stdlib only), gzip; zstd is used when present. Exit status: 0 all passed, 1 a check failed, 2 cannot run here.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "needs python3" >&2; exit 2; }
command -v gzip >/dev/null 2>&1 || { echo "needs gzip" >&2; exit 2; }

PASS=0; FAIL=0
t_pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
t_fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

TMP="$(mktemp -d /tmp/ci-ibst.XXXXXX)"   # short: unix socket paths are limited to 104 bytes on macOS
trap 'rm -rf "$TMP"' EXIT

# ── boot-watch.py against the fake QEMU ─────────────────────────────────────────────────────────────────────────────
watch() { # watch <scenario> <expected exit> <expected text in REASON> [extra boot-watch args]
    local sc="$1" want="$2" text="$3" d="$TMP/$1" rc=0
    shift 3
    mkdir -p "$d"; : > "$d/serial.log"
    python3 -I "$LIB/boot-watch.py" --serial "$d/serial.log" --qmp "$d/q" --shots "$d/shots" --result "$d/boot-result.txt" \
        --timeline "$d/tl.txt" --timeout 40 --grace 6 --shot-interval 3 --poll 0.5 "$@" \
        -- python3 -I "$LIB/fake-qemu.py" --serial "$d/serial.log" --qmp "$d/q" --scenario "$sc" >"$d/out.txt" 2>&1 || rc=$?
    reason="$(sed -n 's/^REASON=//p' "$d/boot-result.txt" 2>/dev/null | head -1)"
    if [ "$rc" -eq "$want" ] && printf '%s' "$reason" | grep -qi -- "$text"; then t_pass "watcher, scenario $sc: exit $rc, \"${reason:0:90}\""
    else t_fail "watcher, scenario $sc: exit $rc (want $want), reason \"$reason\" (want it to contain \"$text\")"; fi
}
# The sockets need a short path: the scenario directories live under the short TMP.
watch casper 1 "casper"
watch casperloop 1 "casper"
watch pass 0 "greeter is up"
watch blank 1 "no drawn picture"
watch nogreeter 1 "no greeter"
watch exit 1 "exited early"
watch efishell 1 "found nothing to boot"
watch silent 1 "no serial output at all" --timeout 8
[ -s "$TMP/pass/shots/final.png" ] && t_pass "watcher: a final screenshot was written" || t_fail "watcher: no final.png after the pass scenario"
grep -q 'CI-PROBE-OK' "$TMP/pass/guest-report.txt" 2>/dev/null && t_pass "watcher: the probe report was saved" || t_fail "watcher: guest-report.txt lacks the probe's lines"

# ── install-source-layers.py against install-sources.yaml samples ─────────────────────────────────────────────────────
cat > "$TMP/is-v7.yaml" <<'EOF'
- default: true
  description:
    en: Companion OS (minimized)
  id: ubuntu-desktop-minimal
  path: minimal.squashfs
  preinstalled_langs: []
  type: fsimage-layered
  variations:
    minimal:
      path: minimal.squashfs
      size: 1
- default: false
  id: ubuntu-desktop
  path: minimal.standard.squashfs
  type: fsimage-layered
  variations:
    standard:
      path: minimal.standard.squashfs
EOF
cat > "$TMP/is-stock.yaml" <<'EOF'
- default: false
  id: ubuntu-desktop-minimal
  path: minimal.squashfs
- default: true
  id: ubuntu-desktop
  path: minimal.standard.live.squashfs
  variations:
    enhanced-secureboot:
      path: minimal.enhanced-secureboot.squashfs
EOF
layers() { python3 -I "$LIB/install-source-layers.py" "$@" 2>&1 | tr '\n' ' ' || :; }
got="$(layers "$TMP/is-v7.yaml")"
[ "$got" = "minimal.squashfs " ] && t_pass "install sources: the default entry first in the file is minimal.squashfs alone" || t_fail "install sources v7: got '$got'"
got="$(layers "$TMP/is-stock.yaml")"
[ "$got" = "minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs " ] && t_pass "install sources: a.b.c.squashfs is the stack a, a.b, a.b.c" || t_fail "install sources stock: got '$got'"
got="$(layers "$TMP/is-v7.yaml" ubuntu-desktop)"
[ "$got" = "minimal.squashfs minimal.standard.squashfs " ] && t_pass "install sources: an entry can be picked by id; variations' paths are not read" || t_fail "install sources by id: got '$got'"
got="$(layers "$TMP/is-v7.yaml" nosuch)"
case "$got" in *"no id: nosuch entry"*) t_pass "install sources: an unknown id is an error" ;; *) t_fail "install sources unknown id: got '$got'" ;; esac

# ── initrd-audit.py against synthetic images ─────────────────────────────────────────────────────────────────────────
while IFS= read -r l; do
    case "$l" in PASS*) PASS=$((PASS + 1)) ;; FAIL*) FAIL=$((FAIL + 1)) ;; esac
    printf '%s\n' "$l"
done < <(python3 -I "$LIB/selftest-initrd.py" "$TMP" "$LIB" 2>&1)

printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
