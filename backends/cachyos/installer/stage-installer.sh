#!/usr/bin/env bash
# stage-installer.sh -- build the installer overlay into the ISO's staging tree.
#
# The overlay is the directory /usr/share/ci-os/calamares of the live image: calamares-online.sh lays it over CachyOS' installer
# and the shellprocess steps of the install run its scripts. Its sources are spread over the repository (this directory, the
# provisioning wrapper, the headless payload, core/lib), so it is ASSEMBLED, not committed: this script copies each source to
# its place in $CI_OS_STAGING_DIR/airootfs/usr/share/ci-os/calamares, which apply-overlay.sh merges over the archiso profile after
# overlay/files. Nothing generated is committed (steward rule).
#
#   CI_OS_STAGING_DIR=<dir> backends/cachyos/installer/stage-installer.sh
#
# Layout written (every file mode 644: mkarchiso drops modes, and the overlay engine's guard (c) wants a file_permissions entry
# for each executable file, which none of these needs -- the scripts are started with `bash <file>`):
#   settings.conf guards.list patches.list pacstrap-code-added.list
#                                               from this directory (the last one is read by lib/ci-pkglist.py)
#   modules/*                                   module configs, netinstall.yaml, the two shellprocess instances
#   lib/ci-guards.sh lib/ci-pkglist.py          the guard library and the package-list reader
#   scripts/*.sh                                ci-os-stage-target.sh, ci-os-post-install-fixups.sh
#   branding/companion/                         branding.desc, show.qml, stylesheet.qss with the brand tokens filled in (its CTRL_*
#                                               placeholders: selection row, progress track, outline, fill and text)
#                                               (logo.png, icon.png, welcome.png, bootloader.png are added by render-installer-assets.sh)
#   target/bootstrap/                           the provisioning tree for the installed system, in the repository's own layout:
#                                               backends/arch/provision/provision.sh, backends/cachyos/provision/*.sh,
#                                               core/lib/{ci-hub,generate-tunnel-certs,gpu-detect}.sh, core/manifest/*,
#                                               core/headless/payload/** (tracked files only)
#   target/units/*  target/ci-os-setup          first-boot service and timer; the `ci-os-setup` command
#
# Environment
#   CI_OS_STAGING_DIR  (required) where to write; the previous copy of the overlay in it is replaced
#   CI_OS_REPO_ROOT    the repository, or the subset the build container holds (default: the checkout this file is in)
#   CI_OS_VERSION      version string for the installer window (default: the day of SOURCE_DATE_EPOCH, else today, YYYY.MM.DD)
set -euo pipefail
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${CI_OS_REPO_ROOT:-$(cd "$HERE/../../.." && pwd)}"

die() { printf 'stage-installer: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'stage-installer: %s\n' "$*"; }

[ -n "${CI_OS_STAGING_DIR:-}" ] || { printf 'stage-installer: CI_OS_STAGING_DIR is not set\n' >&2; exit 2; }
mkdir -p "$CI_OS_STAGING_DIR"
OUT="$(cd "$CI_OS_STAGING_DIR" && pwd)"
DEST="$OUT/airootfs/usr/share/ci-os/calamares"

# Version. Same default as render-assets.sh, so the installer window and os-release agree.
VERSION="${CI_OS_VERSION:-}"
if [ -z "$VERSION" ]; then
  epoch="${SOURCE_DATE_EPOCH:-$(date +%s)}"
  VERSION="$(date -u -d "@$epoch" +%Y.%m.%d 2>/dev/null || date -u -r "$epoch" +%Y.%m.%d)"
fi
case "$VERSION" in
  ''|*[!A-Za-z0-9._+-]*) die "CI_OS_VERSION '$VERSION' may only contain letters, digits and . _ + -" ;;
esac

TOKENS="$REPO/vendor/brand/tokens/tokens.sh"
[ -f "$TOKENS" ] || die "brand tokens not found: $TOKENS"
# shellcheck source=/dev/null
. "$TOKENS"
for v in CI_DARK_SIDEBAR CI_DARK_SIDEBAR_FOREGROUND CI_DARK_SIDEBAR_PRIMARY CI_DARK_SIDEBAR_PRIMARY_FOREGROUND CI_DARK_BACKGROUND CI_DARK_FOREGROUND \
         CI_DARK_PRIMARY CI_DARK_PRIMARY_FOREGROUND CI_DARK_MUTED_FOREGROUND CI_ACCENT_PHTHALO_HOVER; do
  [ -n "${!v:-}" ] || die "token $v is missing from $TOKENS"
done

rm -rf "$DEST"
mkdir -p "$DEST"

put() {  # SRC DEST-relative-to-$DEST
  [ -f "$1" ] || die "missing source: $1"
  mkdir -p "$(dirname "$DEST/$2")"
  cp "$1" "$DEST/$2"
  chmod 644 "$DEST/$2"
}

# --- the overlay's own files -----------------------------------------------------------------------------------------------------
for f in settings.conf guards.list patches.list pacstrap-code-added.list; do put "$HERE/$f" "$f"; done
for f in "$HERE"/modules/*; do put "$f" "modules/$(basename "$f")"; done
for f in ci-guards.sh ci-pkglist.py; do put "$HERE/lib/$f" "lib/$f"; done
for f in "$HERE"/scripts/*.sh; do put "$f" "scripts/$(basename "$f")"; done

# --- branding: fill in the tokens ---------------------------------------------------------------------------------------------------
subst() {  # SRC DEST
  mkdir -p "$(dirname "$DEST/$2")"
  sed -e "s|@CI_OS_VERSION@|$VERSION|g" \
      -e "s|@SIDEBAR_BACKGROUND@|$CI_DARK_SIDEBAR|g" \
      -e "s|@SIDEBAR_TEXT@|$CI_DARK_SIDEBAR_FOREGROUND|g" \
      -e "s|@SIDEBAR_HIGHLIGHT@|$CI_DARK_SIDEBAR_PRIMARY|g" \
      -e "s|@SIDEBAR_HIGHLIGHT_TEXT@|$CI_DARK_SIDEBAR_PRIMARY_FOREGROUND|g" \
      -e "s|@SLIDE_BACKGROUND@|$CI_DARK_BACKGROUND|g" \
      -e "s|@SLIDE_TEXT@|$CI_DARK_FOREGROUND|g" \
      -e "s|@CTRL_SELECTION@|$CI_DARK_PRIMARY|g" \
      -e "s|@CTRL_SELECTION_TEXT@|$CI_DARK_PRIMARY_FOREGROUND|g" \
      -e "s|@CTRL_TRACK@|$CI_DARK_BACKGROUND|g" \
      -e "s|@CTRL_TRACK_OUTLINE@|$CI_DARK_MUTED_FOREGROUND|g" \
      -e "s|@CTRL_FILL@|$CI_ACCENT_PHTHALO_HOVER|g" \
      -e "s|@CTRL_FILL_TEXT@|$CI_DARK_FOREGROUND|g" \
      "$1" > "$DEST/$2"
  chmod 644 "$DEST/$2"
  if grep -qE '@[A-Z][A-Z_]*@' "$DEST/$2"; then die "unresolved placeholder in $2: $(grep -oE '@[A-Z][A-Z_]*@' "$DEST/$2" | sort -u | tr '\n' ' ')"; fi
}
for f in branding.desc show.qml stylesheet.qss; do subst "$HERE/branding/companion/$f" "branding/companion/$f"; done

# --- the target payload ------------------------------------------------------------------------------------------------------------------
BOOT="target/bootstrap"
put "$REPO/backends/arch/provision/provision.sh" "$BOOT/backends/arch/provision/provision.sh"
for f in provision.sh first-boot-setup.sh stage-headless.sh progress-filter.sh; do put "$REPO/backends/cachyos/provision/$f" "$BOOT/backends/cachyos/provision/$f"; done
for f in ci-hub.sh generate-tunnel-certs.sh gpu-detect.sh; do put "$REPO/core/lib/$f" "$BOOT/core/lib/$f"; done
put "$REPO/core/manifest/ecosystem.yaml" "$BOOT/core/manifest/ecosystem.yaml"
put "$REPO/core/manifest/role-map/pacman.yaml" "$BOOT/core/manifest/role-map/pacman.yaml"

# The headless payload: the files git tracks when this is a checkout, else every file but caches (the build container holds a tar of
# the tree, not a repository).
PAYLOAD_REL="core/headless/payload"
payload_files() {
  if [ -e "$REPO/.git" ] && command -v git >/dev/null 2>&1 && git -C "$REPO" ls-files --error-unmatch "$PAYLOAD_REL" >/dev/null 2>&1; then
    git -C "$REPO" ls-files "$PAYLOAD_REL" | sed "s|^$PAYLOAD_REL/||"
  else
    (cd "$REPO/$PAYLOAD_REL" && find . -type f ! -name .DS_Store ! -name '*.pyc' ! -path '*/__pycache__/*' | sed 's|^\./||')
  fi
}
n=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  put "$REPO/$PAYLOAD_REL/$rel" "$BOOT/$PAYLOAD_REL/$rel"
  n=$((n + 1))
done <<EOF
$(payload_files | LC_ALL=C sort)
EOF
[ "$n" -gt 0 ] || die "no files found in $REPO/$PAYLOAD_REL"

for f in ci-os-first-boot-setup.service ci-os-first-boot-setup.timer; do put "$REPO/backends/cachyos/provision/systemd/$f" "target/units/$f"; done
put "$REPO/backends/cachyos/provision/ci-os-setup.sh" "target/ci-os-setup"

say "overlay staged in ${DEST#"$OUT"/} (version $VERSION, $n payload file(s), $(cd "$DEST" && find . -type f | wc -l | tr -d ' ') files in all)"
