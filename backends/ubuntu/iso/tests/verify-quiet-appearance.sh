#!/usr/bin/env bash
#=============================================================================
# Test: verify-iso.sh sections 6b (Ubuntu Pro and telemetry) and 6c (dark, green accent) fail on the defects they are for
#
# The properties are tested where they are written: backends/ubuntu/lib/tests/quiet-canonical.sh (the audit of ci_quiet_audit) and
# backends/ubuntu/lib/tests/appearance.sh. What neither can show is that verify-iso.sh calls them right: the labels, the quoting of the
# `bash -c` checks, the paths it reads, the listing it consults for the Pro machine token and the diversion. This test cuts the two sections
# out of verify-iso.sh (from `section "6b.` to the line before `section "7.`) and RUNS them, with verify-iso.sh's own pass/fail/check helpers,
# against fake extracted roots shaped like the installed layer: one built the way the image build builds it (the library's apply, the dconf
# and schema files cut out of customize-chroot.sh), one stock, and single defects planted in the built one.
#
# It cannot say that the image build produces such a root (that is a build) or that the extraction list of verify-iso.sh brings these files
# out of the squashfs (that is a run on an ISO); it says the sections read the right files and say the right thing about them.
#
# Pure bash (3.2 safe), no root, no network, no xorriso or squashfs-tools.
#   backends/ubuntu/iso/tests/verify-quiet-appearance.sh
# VERIFY_ISO_SCRIPT=<path> runs it against another copy of verify-iso.sh (a copy with a check weakened must fail it).
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
VERIFY="${VERIFY_ISO_SCRIPT:-$REPO/backends/ubuntu/iso/scripts/verify-iso.sh}"
LIBDIR="$REPO/backends/ubuntu/lib"
CHROOT_SCRIPT="$REPO/backends/ubuntu/chroot/customize-chroot.sh"
for f in "$VERIFY" "$LIBDIR/quiet-canonical.sh" "$LIBDIR/appearance.sh" "$LIBDIR/tests/lib/quiet-fixtures.sh" "$CHROOT_SCRIPT"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-quiet.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

# shellcheck source=../../lib/quiet-canonical.sh
source "$LIBDIR/quiet-canonical.sh"
# shellcheck source=../../lib/appearance.sh
source "$LIBDIR/appearance.sh"
# shellcheck source=../../lib/tests/lib/quiet-fixtures.sh
source "$LIBDIR/tests/lib/quiet-fixtures.sh"
quiet_fixtures_init

# ── the sections, cut out of verify-iso.sh and placed where they find the libraries the way they do in the repo ───────────────────────
SECT="$WORK/sections.sh"
sed -n '/^section "6b\./,/^section "7\./p' "$VERIFY" | sed '$d' > "$SECT"
[[ "$(wc -l < "$SECT" | tr -d ' ')" -gt 40 ]] || { echo "could not cut sections 6b and 6c out of $VERIFY" >&2; exit 2; }
IN_REPO="$WORK/repo/backends/ubuntu/iso/scripts"; mkdir -p "$IN_REPO"
cp "$SECT" "$IN_REPO/verify-iso.sh"
ln -s "$LIBDIR" "$WORK/repo/backends/ubuntu/lib"
NO_LIBS="$WORK/norepo/backends/ubuntu/iso/scripts"; mkdir -p "$NO_LIBS"; cp "$SECT" "$NO_LIBS/verify-iso.sh"   # a copy of the script outside the repo

# run_sections <script> <root> <listing text>: the helpers of verify-iso.sh, then the sections. Output in $WORK/out.txt, counts in P and F.
run_sections() {
    local script="$1" R="$2" LISTING="$WORK/listing.txt" PASS=0 FAIL=0
    printf '%s\n' "$3" > "$LISTING"
    pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
    fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
    note() { printf 'info  %s\n' "$*"; }
    skip() { printf 'info  SKIPPED: %s\n' "$*"; }
    section() { printf '\n== %s\n' "$*"; }
    check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }
    in_listing() { grep -q -E "$1" "$LISTING"; }
    # shellcheck disable=SC1090
    . "$script" > "$WORK/out.txt" 2>&1
    P=$PASS; F=$FAIL
}
HOOK_LISTED=' -rw-r--r-- root/root 321 2026-10-19 12:00 /etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled'

# ── the good root: what the image build produces ──────────────────────────────────────────────────────────────────────────────────────
good="$WORK/good"; make_stock_root "$good"; ROOT="$good"
ci_quiet_apply_all "$good" >/dev/null 2>&1; finish_like_the_build "$good"
ci_os_appearance_dconf > "$good/etc/dconf/db/local.d/04-ci-os-appearance"
mkdir -p "$good/usr/share/glib-2.0/schemas"
sed -n '/local.d\/01-ci-os-wallpaper" << /,/^EOF$/p' "$CHROOT_SCRIPT" | sed '1d;$d' > "$good/etc/dconf/db/local.d/01-ci-os-wallpaper"
{ sed -n '/90_companion-os.gschema.override" << /,/^EOF$/p' "$CHROOT_SCRIPT" | sed '1d;$d'; ci_os_appearance_override; } > "$good/usr/share/glib-2.0/schemas/90_companion-os.gschema.override"
printf 'GVariant\0favorite-apps\0color-scheme\0prefer-dark\0accent-color\0green\0' > "$good/etc/dconf/db/local"   # what dconf update compiles: the strings as they are
expect "the fixture is the image build's: the wallpaper keyfile and the schema override were cut out of customize-chroot.sh" \
    bash -c 'grep -q "^picture-uri-dark=" "$1/etc/dconf/db/local.d/01-ci-os-wallpaper" && grep -q "^\[org.gnome.desktop.background\]" "$1/usr/share/glib-2.0/schemas/90_companion-os.gschema.override"' _ "$good"

echo "== 1. a root built the way the image build builds it"
run_sections "$IN_REPO/verify-iso.sh" "$good" "$HOOK_LISTED"
eq "no FAIL in sections 6b and 6c" "$F" "0"
[[ "$F" == 0 ]] || grep '^FAIL' "$WORK/out.txt" | sed 's/^/        /'
eq "  and 42 checks passed: the token, 34 of the audit, the diversion, 6 of the appearance (a check that stopped running changes this)" "$P" "42"
expect "  both section headers were printed" bash -c 'grep -q "^== 6b\. " "$1" && grep -q "^== 6c\. " "$1"' _ "$WORK/out.txt"

echo
echo "== 2. a stock root fails both"
stock="$WORK/stock"; make_stock_root "$stock"; ROOT="$stock"
run_sections "$IN_REPO/verify-iso.sh" "$stock" ' -rw-r--r-- root/root 321 2026-10-19 12:00 /etc/apt/apt.conf.d/20apt-esm-hook.conf'
expect "many failures (the audit's, and the appearance files that are not there)" test "$F" -ge 30
for want in "Canonical: apt still runs the Ubuntu Pro hook" "Canonical: uaclient.conf does not have apt_news: false" "Canonical: unit ua-timer.timer is not masked" \
            "Canonical: these autostart entries of the Pro client or of telemetry are still active" "appearance: /etc/dconf/db/local.d/04-ci-os-appearance is the library's keyfile" \
            "appearance: the compiled local dconf database holds color-scheme"; do
    expect "  FAIL  $want" bash -c 'grep "^FAIL" "$1" | grep -q -F -- "$2"' _ "$WORK/out.txt" "$want"
done
expect "  no hook diversion is demanded of an image that has no .disabled hook (it says there was nothing to divert)" bash -c 'grep -q "^info  the Pro client.s apt hook (20apt-esm-hook.conf.disabled) is not in this image" "$1"' _ "$WORK/out.txt"

echo
echo "== 3. one defect, one FAIL"
one() { # one <name> <want text> <listing> <command...>: clone the good root, run the command in it, expect exactly ONE_N (default 1) FAIL lines, one of them with the text
    local name="$1" want="$2" listing="$3" r="$WORK/one-$1" n_want="${ONE_N:-1}"; shift 3
    rm -rf "$r"; cp -Rp "$good" "$r"; ROOT="$r"
    ( cd "$r" && "$@" ) >/dev/null 2>&1
    run_sections "$IN_REPO/verify-iso.sh" "$r" "$listing"
    if [[ "$F" == "$n_want" ]] && grep '^FAIL' "$WORK/out.txt" | grep -q -F -- "$want"; then pass "$name: $F FAIL line(s), one says: $want"
    else fail "$name: want $n_want FAIL line(s), one containing '$want', got $F"; grep '^FAIL' "$WORK/out.txt" | sed 's/^/        /'; fi
}
one "a machine token in the image" "no Ubuntu Pro machine token is baked into the image" "$HOOK_LISTED
 -rw------- root/root 12 2026-10-19 12:00 /var/lib/ubuntu-advantage/private/machine-token.json" true
one "the hook is not a registered diversion" "the Pro client's apt hook is a registered local diversion" "$HOOK_LISTED" sed -i.bak '/20apt-esm-hook/d' var/lib/dpkg/diversions
one "apt news back on" "uaclient.conf does not have apt_news: false" "$HOOK_LISTED" sed -i.bak 's/^apt_news: false/apt_news: true/' etc/ubuntu-advantage/uaclient.conf
one "a timer unmasked" "Canonical: unit esm-cache.service is not masked" "$HOOK_LISTED" rm etc/systemd/system/esm-cache.service
ONE_N=2 one "the ESM announcement executable again (found by its name, and by what it prints)" "login-text script 88-esm-announce is still executable" "$HOOK_LISTED" chmod 755 etc/update-motd.d/88-esm-announce
one "the keyfile says orange" "appearance: /etc/dconf/db/local.d/04-ci-os-appearance is the library's keyfile" "$HOOK_LISTED" sed -i.bak "s/accent-color='green'/accent-color='orange'/" etc/dconf/db/local.d/04-ci-os-appearance
one "no keyfile" "appearance: /etc/dconf/db/local.d/04-ci-os-appearance is the library's keyfile" "$HOOK_LISTED" rm etc/dconf/db/local.d/04-ci-os-appearance
one "the schema override lacks the interface stanza" "appearance: 90_companion-os.gschema.override carries the same two keys" "$HOOK_LISTED" bash -c "printf \"[org.gnome.desktop.background]\npicture-uri-dark='file:///usr/share/backgrounds/ci-os-wallpaper.png'\n\" > usr/share/glib-2.0/schemas/90_companion-os.gschema.override"
one "dconf update never ran" "appearance: the compiled local dconf database holds accent-color" "$HOOK_LISTED" bash -c "printf 'GVariant\\0favorite-apps\\0color-scheme\\0prefer-dark\\0' > etc/dconf/db/local"
one "no dark wallpaper key" "appearance: the wallpaper has a dark-scheme variant" "$HOOK_LISTED" sed -i.bak '/picture-uri-dark/d' etc/dconf/db/local.d/01-ci-os-wallpaper

echo
echo "== 4. a copy of verify-iso.sh outside the repository"
ROOT="$good"
run_sections "$NO_LIBS/verify-iso.sh" "$good" "$HOOK_LISTED"
expect "the two sections are listed as SKIPPED and fail nothing (VERIFY_REQUIRE_CANON=1 turns that into a failure)" \
    bash -c '[ "$2" = 0 ] && grep -c "SKIPPED" "$1" | grep -q "^2$"' _ "$WORK/out.txt" "$F"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
