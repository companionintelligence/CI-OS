#!/usr/bin/env bash
# Fast repo checks, run on every PR (.github/workflows/pr-checks.yml) and before any push.
# Needs: bash 3.2+ (so it runs on a stock macOS too), git, shellcheck, python3, yamllint.
# Runs every category and exits non-zero if any of them failed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
rc=0

missing=()
for tool in git shellcheck python3 yamllint; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "✖ missing tools: ${missing[*]}" >&2
  echo "  macOS:         brew install shellcheck yamllint" >&2
  echo "  Debian/Ubuntu: sudo apt-get install shellcheck yamllint python3" >&2
  exit 2
fi

# Shell sources: *.sh plus extensionless maintainer scripts and payload bins with a shell shebang.
# vendor/ is generated (vendor-brand.sh) and linted upstream.
# (Arrays are filled with read loops, not mapfile: macOS ships bash 3.2, which has no mapfile.)
SH=()
while IFS= read -r f; do SH+=("$f"); done < <(
  { git ls-files '*.sh'
    git ls-files | grep -E '(^|/)DEBIAN/(preinst|postinst|prerm|postrm)$'
    git ls-files 'core/headless/payload/usr/local/bin/*' | while read -r f; do
      head -1 "$f" | grep -qE '^#!.*\b(ba)?sh\b' && echo "$f"; done
  } | grep -v '^vendor/' | sort -u)

echo "── bash -n (${#SH[@]} files)"
for f in "${SH[@]}"; do bash -n "$f" || { echo "✖ syntax: $f"; rc=1; }; done

echo "── shellcheck -S error"
LC_ALL=C.UTF-8 shellcheck -x -S error "${SH[@]}" || rc=1

echo "── no ((VAR++)) statements in shell scripts"
# ((n++)) and ((n--)) exit with status 1 while n is 0, so under `set -e` the first increment ends the
# script: the Fedora, Arch and Mint 80-validate-ci-theme.sh did exactly that and printed one check.
# Use n=$((n + 1)).
post_incr="$(git grep -nE '^[[:space:]]*\(\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\+\+|--)[[:space:]]*\)\)' -- '*.sh' ':(exclude)vendor' 2>/dev/null || true)"
if [ -n "$post_incr" ]; then
  echo "✖ a ((VAR++)) statement aborts a set -e script while VAR is 0; write VAR=\$((VAR + 1)):"; echo "$post_incr"; rc=1
fi

echo "── no retired product names in backends/, core/ and .github/"
# The product is "Companion OS". "CI OS", "CI-OS Desktop", "CI-OS Blue Teal", "Companion Ubuntu", "Companion Intelligence OS",
# "Companion Intelligence Operating System" and "Companion Intelligence <version>" (os-release VERSION=) were earlier
# spellings of it (the GRUB distributor, the text splash, the installer's source names, the MOTD banner, the Hub launcher
# entry, the terminal and KDE profiles, release notes, the os-release version string), and the
# image checks of verify-iso.sh would only catch a return after a full build. The repo name "CI-OS", the CI_OS_* variables and
# ci-os-* paths are not product names and do not match. Three places spell the old names on purpose and are not scanned:
# this file, verify-iso.sh (it asserts they are absent from a built image) and iso/tests (a test plants one to see that it
# is caught). docs/ keeps the history and stick/ is a separate change.
old_names="$(git grep -nE 'CI OS|CI-OS Desktop|CI-OS Blue Teal|Companion Ubuntu|Intelligence Operating System|Companion Intelligence OS|Companion Intelligence [0-9$]' -- backends core .github ':(exclude)core/lib/check-repo.sh' ':(exclude)backends/ubuntu/iso/scripts/verify-iso.sh' ':(exclude)backends/ubuntu/iso/tests' ':(exclude)backends/ubuntu/chroot/tests/models-units.sh' 2>/dev/null || true)"
if [ -n "$old_names" ]; then
  echo "✖ a retired product name is back; the name is \"Companion OS\":"; echo "$old_names"; rc=1
fi

echo "── no retired distro names outside core/lib/retired-names.allow"
# Supported targets: Companion OS on Ubuntu 26.04 LTS and Companion OS on CachyOS. Linux Mint, Fedora, Bazzite and NixOS were
# retired on 2026-10-17 and their backends removed; the tag pre-retire-multidistro-2026-10-17 keeps them (restore with
# `git checkout <tag> -- backends/<name>`). So that they do not creep back in by copy-paste, a mention of one of them, or of its
# tooling (dnf, bootc, rpm-ostree, kickstart, lorax, Cinnamon, nixpkgs, flake.nix), is rejected anywhere in the tracked tree
# unless the path is listed in core/lib/retired-names.allow (deliberate history: the frozen backends/arch, the design doc, docs
# still to be rewritten) or the line itself cites the restore tag. A stale allow-list entry (no retired name left in that path)
# also fails, so the list shrinks as documents are cleaned. This file and the allow-list are not scanned (they spell the names).
# "mint" is also an English verb (setup_service.py mints nonces), so the distro is matched only as the capitalised word Mint or
# MINT; \b is avoided on purpose, because BSD regex (macOS git) silently ignores it, so boundaries are spelled out.
# Ubuntu 24.04 wording is a separate port and is not matched here.
RETIRED_TAG='pre-retire-multidistro-2026-10-17'
RETIRED_ALLOW='core/lib/retired-names.allow'
RETIRED_RE_I='fedora|linux ?mint|linuxmint|backends/\{?[a-z,]*mint|mint-y|cinnamon|bazzite|nixos|nixpkgs|flake\.nix|(^|[^A-Za-z0-9_])dnf5?([^A-Za-z0-9_]|$)|(^|[^A-Za-z])bootc([^A-Za-z]|$)|rpm-ostree|kickstart|lorax'
RETIRED_RE_S='(^|[^A-Za-z])(Mint|MINT)([^A-Za-z]|$)'
if [ ! -f "$RETIRED_ALLOW" ]; then
  echo "✖ missing: $RETIRED_ALLOW"; rc=1
else
  retired_report="$(
    { git grep -n -I -i -E "$RETIRED_RE_I" -- . ":(exclude)$RETIRED_ALLOW" ':(exclude)core/lib/check-repo.sh' 2>/dev/null || true
      git grep -n -I -E "$RETIRED_RE_S" -- . ":(exclude)$RETIRED_ALLOW" ':(exclude)core/lib/check-repo.sh' 2>/dev/null || true
    } | sort -u | awk -v tag="$RETIRED_TAG" -v allow="$RETIRED_ALLOW" '
      BEGIN {
        while ((getline line < allow) > 0) {
          sub(/#.*/, "", line); gsub(/^[ \t]+/, "", line); gsub(/[ \t]+$/, "", line)
          if (line != "") { n++; entry[n] = line }
        }
      }
      NF == 0 { next }
      {
        path = $0; sub(/:.*/, "", path)
        listed = 0
        for (i = 1; i <= n; i++) if (substr(path, 1, length(entry[i])) == entry[i]) { used[i] = 1; listed = 1 }
        if (listed || index($0, tag)) next
        print "HIT " $0
      }
      END { for (i = 1; i <= n; i++) if (!used[i]) print "STALE " entry[i] }')"
  retired_hits="$(printf '%s\n' "$retired_report" | sed -n 's/^HIT //p')"
  retired_stale="$(printf '%s\n' "$retired_report" | sed -n 's/^STALE //p')"
  if [ -n "$retired_hits" ]; then
    echo "✖ a retired distro name is back (supported: Companion OS on Ubuntu 26.04 LTS and on CachyOS). If this is a deliberate note about the"
    echo "  retirement, put the restore tag $RETIRED_TAG on the same line, or list the file in $RETIRED_ALLOW:"
    echo "$retired_hits"; rc=1
  fi
  if [ -n "$retired_stale" ]; then
    echo "✖ $RETIRED_ALLOW has entries that no longer match any retired name; delete these lines:"
    echo "$retired_stale"; rc=1
  fi
fi

echo "── no block-letter banner art in backends/, core/ and .github/"
# A grep for the retired names reads text, not pictures: the MOTD banner drew the letters C, I, O, S in full-block
# characters, which spelled "CI OS" and passed every check above. Draw no names; write them.
block_art="$(git grep -InF '█' -- backends core .github ':(exclude)core/lib/check-repo.sh' 2>/dev/null || true)"
if [ -n "$block_art" ]; then
  echo "✖ block-letter art (U+2588) is back; it can spell a retired name that no text check can see:"; echo "$block_art"; rc=1
fi

echo "── python3 py_compile"
PY=()
while IFS= read -r f; do PY+=("$f"); done < <(git ls-files '*.py')
if [ ${#PY[@]} -gt 0 ]; then
  PYTHONPYCACHEPREFIX="$(mktemp -d)" python3 -m py_compile "${PY[@]}" || rc=1
fi

echo "── yamllint (relaxed)"
YML=()
while IFS= read -r f; do YML+=("$f"); done < <(git ls-files '*.yml' '*.yaml')
yamllint -d relaxed --no-warnings "${YML[@]}" || rc=1

echo "── shebang files are executable"
# A file that starts with #! but is stored as mode 100644 fails with "Permission denied" when
# run as ./script. Fix with `chmod +x` (git records it), or drop the shebang if it is only
# ever sourced. vendor/ is generated.
noexec=""
while IFS=$' \t' read -r mode _ _ f; do
  [ "$mode" = 100644 ] || continue
  case "$f" in vendor/*) continue ;; esac
  if [ -f "$f" ] && head -c 2 "$f" | grep -q '^#!'; then noexec="$noexec$f"$'\n'; fi
done < <(git ls-files -s)
if [ -n "$noexec" ]; then
  echo "✖ these files start with #! but are not executable (chmod +x):"; printf '%s' "$noexec"; rc=1
fi

echo "── no committed build artifacts"
# .gitignore already excludes these; this catches force-adds and old branches that predate it.
if art="$(git ls-files | grep -E '\.(deb|rpm|iso|squashfs|dsc|changes|buildinfo)$')"; then
  echo "✖ build artifacts are tracked — build them in CI, don't commit them:"; echo "$art"; rc=1
fi

echo "── tracked files that name an untracked file (core/lib/check-untracked-deps.sh)"
# Everything here runs on the working tree, so a new script, fixture or payload file that was never `git add`ed passes every check below and is
# missing from the commit (the image build, test_auto_install.py and `cargo test` then fail on a clean checkout). CI checks out the commit and has
# nothing untracked to report; this is for the run before the push. `git add -N <path>` is enough for `git add -u` / `git commit -a` to take it.
untracked_out="$(mktemp)"; untracked_rc=0
bash core/lib/check-untracked-deps.sh > "$untracked_out" 2>&1 || untracked_rc=$?
if [ "$untracked_rc" -eq 0 ]; then
  echo "  none"
elif [ "$untracked_rc" -eq 2 ]; then
  echo "! cannot run here: $(head -n 1 "$untracked_out")"
else
  cat "$untracked_out"; rc=1
fi
rm -f "$untracked_out"

echo "── one-click installer unit tests (backends/ubuntu/chroot/tests/test_auto_install.py)"
# Disk selection and the autoinstall file of ci-os-auto-install, on fixtures: no root, no disk, no VM. It is the rule that the
# boot medium is never offered as a target, so it runs on every push. python3-yaml is already needed by yamllint.
ai_out="$(mktemp)"
if PYTHONDONTWRITEBYTECODE=1 python3 backends/ubuntu/chroot/tests/test_auto_install.py > "$ai_out" 2>&1; then
  grep -E '^(Ran|OK)' "$ai_out" | tr '\n' ' '; echo
else
  tail -n 25 "$ai_out"; rc=1
fi
rm -f "$ai_out"

echo "── ISO md5sum.txt tests (backends/ubuntu/iso/tests/md5sum-txt.sh)"
# The one ISO test that needs no container: it checks how the image's md5sum.txt is written and verified on a synthetic tree
# (awk, find, a hash tool; bash 3.2 is enough). With xorriso and GNU dd on the machine it also remasters a mini ISO and runs
# build-iso.sh's generate_iso on it, so a change that breaks the md5sum.txt wiring fails here and not after a one-hour build.
# The other ISO tests need a container or Plymouth; they are manual, see the "Tests" section of backends/ubuntu/iso/README.md.
md5_out="$(mktemp)"; md5_rc=0
bash backends/ubuntu/iso/tests/md5sum-txt.sh > "$md5_out" 2>&1 || md5_rc=$?
if [ "$md5_rc" -eq 0 ]; then
  grep -E '^(info|== Summary)' "$md5_out" || true
elif [ "$md5_rc" -eq 2 ]; then
  echo "! cannot run here: $(head -n 1 "$md5_out")"
else
  grep -E '^(FAIL|info|== Summary)' "$md5_out" || tail -n 10 "$md5_out"; rc=1
fi
rm -f "$md5_out"

echo "── CachyOS edition tests (backends/cachyos/iso/tests)"
# The no-Docker tests of the CachyOS edition: the overlay engine and host entry point (against a fake docker), the brand and
# identity overlay, the installer overlay with the first-boot provisioning, the self-test of verify-iso.sh (every check against a
# good and a broken fixture) and the helper code of the QEMU boot recipe. They need bash 3.2, awk, sed and python3 with PyYAML
# (yamllint already needs it); a test that exits 2 cannot run here and is reported, not failed. The tests that need Docker, the
# network or QEMU (overlay-engine-container.sh, overlay-pacstrap.sh, overlay-menu-shot.sh, verify-mini-iso.sh, qemu-boot.sh
# itself) are manual.
if [ "${SKIP_CACHYOS_TESTS:-0}" = 1 ]; then
  echo "! skipped (SKIP_CACHYOS_TESTS=1)"
else
  for t in overlay-engine.sh overlay-brand.sh installer-config.sh verify-selftest.sh; do
    tf="backends/cachyos/iso/tests/$t"
    if [ ! -f "$tf" ]; then echo "✖ missing: $tf"; rc=1; continue; fi
    tout="$(mktemp)"; trc=0
    bash "$tf" > "$tout" 2>&1 || trc=$?
    if [ "$trc" -eq 0 ]; then
      echo "  $t: $(grep -E '^== ' "$tout" | tail -n 1)"
    elif [ "$trc" -eq 2 ]; then
      echo "! $t cannot run here: $(head -n 1 "$tout")"
    else
      echo "✖ $t failed (exit $trc):"
      { grep -E '^FAIL' "$tout" | head -n 25; } || true
      tail -n 5 "$tout"
      rc=1
    fi
    rm -f "$tout"
  done
  qb_out="$(mktemp)"; qb_rc=0
  bash backends/cachyos/iso/tests/qemu-boot.sh --selftest > "$qb_out" 2>&1 || qb_rc=$?
  if [ "$qb_rc" -eq 0 ]; then echo "  qemu-boot.sh --selftest: $(grep -E 'passed' "$qb_out" | tail -n 1)"
  elif [ "$qb_rc" -eq 2 ]; then echo "! qemu-boot.sh --selftest cannot run here: $(head -n 1 "$qb_out")"
  else echo "✖ qemu-boot.sh --selftest failed (exit $qb_rc):"; tail -n 15 "$qb_out"; rc=1; fi
  rm -f "$qb_out"
fi

echo "── setup portal, Ubuntu 26.04 backend, ISO layer split and model tooling tests (fixtures and stubs only: no root, no Docker, no network)"
# Each suite exits 0 = passed, 2 = cannot run here (reported, not failed), anything else = failed. They cover: the shared setup-portal
# payload (core/headless/tests/payload), the ci_setup library (quick run), the layer split (Part A: pure helpers; Part B runs only with
# SPLIT_TEST_CHROOT, in a container), the installed-boot smoke test's self-test, the OS-side model adapter (core/lib/ci-os-models.sh), and the
# Ubuntu 26.04 port's own suites: the os-release writer's golden files, the ROCm and LACT helpers, customize-chroot.sh's base-release guard and
# step order (it refuses a 24.04 base: ci_os_base_is_supported), the headless package's dependencies, the gnome-shell theme overlay decision and
# the gresource provenance (these two need the glib tools), the live GRUB menu's modules against the signed GRUB's built-in list, and the
# untracked-file guard's own test. The heavy parts (Part B of the split test, verify-installer-base.sh, no-dracut-pin.sh, about-logo-svg.sh,
# visible-names.sh and the other container tests, the installed-boot boot, the hwsim harness stick/tests/qemu/hotspot-hwsim.sh,
# `ci-stick models lock --check`) are manual: see their READMEs and backends/ubuntu/iso/README.md "Script tests".
for suite in \
  "setup-portal payload|bash core/headless/tests/payload/run.sh" \
  "ci_setup library|bash core/headless/tests/ci_setup/run.sh --quick" \
  "ISO layer split, Part A|bash backends/ubuntu/iso/tests/split-live-layer.sh" \
  "installed-boot self-test|bash backends/ubuntu/iso/tests/installed-boot.sh --selftest" \
  "OS model adapter|bash backends/ubuntu/chroot/tests/models-all.sh" \
  "os-release writer, golden files|bash backends/ubuntu/lib/tests/os-release-golden.sh" \
  "ROCm driver installer|bash backends/ubuntu/lib/tests/install-rocm-driver.sh" \
  "LACT release lookup|bash backends/ubuntu/lib/tests/lact-release.sh" \
  "customize-chroot guards (26.04 base only)|bash backends/ubuntu/chroot/tests/customize-chroot-checks.sh" \
  "first-boot-units containment self-test|bash backends/ubuntu/chroot/tests/first-boot-units-boot.sh --selftest" \
  "headless package dependencies|bash backends/ubuntu/headless-package/tests/control-depends.sh" \
  "gnome-shell theme overlay|bash backends/ubuntu/lib/tests/shell-theme.sh" \
  "dock favourites list|bash backends/ubuntu/lib/tests/dock-favorites.sh" \
  "Companion links and welcome|bash backends/ubuntu/lib/tests/start-links.sh" \
  ".deb member names (needs dpkg-deb)|bash backends/ubuntu/lib/tests/deb-members.sh" \
  "first-boot wait-quiet|bash backends/ubuntu/chroot/tests/wait-quiet.sh" \
  "Companion Hub first-boot start|bash backends/ubuntu/chroot/tests/start-companion-hub.sh" \
  "ollama pull progress filter|bash backends/ubuntu/chroot/tests/pull-progress-filter.sh" \
  "gresource provenance|bash core/render/tests/gresource-provenance.sh" \
  "live GRUB menu modules|bash backends/ubuntu/iso/tests/grub-live-menu-modules.sh" \
  "untracked-file guard|bash core/lib/tests/untracked-deps.sh"; do
  sname="${suite%%|*}"; scmd="${suite#*|}"
  sfile="$(printf '%s' "$scmd" | sed -n 's/.*\(core\/[^ ]*\.sh\|backends\/[^ ]*\.sh\).*/\1/p')"
  if [ -n "$sfile" ] && [ ! -f "$sfile" ]; then echo "✖ missing: $sfile ($sname)"; rc=1; continue; fi
  sout="$(mktemp)"; src=0
  $scmd > "$sout" 2>&1 || src=$?
  if [ "$src" -eq 0 ]; then
    echo "  $sname: $(grep -E '(passed|PASS|✔| OK)' "$sout" | tail -n 1 | cut -c1-110)"
  elif [ "$src" -eq 2 ]; then
    echo "! $sname cannot run here: $(head -n 1 "$sout" | cut -c1-110)"
  else
    echo "✖ $sname failed (exit $src):"; { grep -E '^(FAIL|✖)' "$sout" | head -n 20; } || true; tail -n 5 "$sout"; rc=1
  fi
  rm -f "$sout"
done

[ $rc -eq 0 ] && echo "✔ all checks passed"
exit $rc
