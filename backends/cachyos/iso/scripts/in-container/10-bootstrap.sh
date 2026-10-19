#!/usr/bin/env bash
# 10-bootstrap.sh: turn an Arch container into the ISO build host. Runs INSIDE the builder container as root; idempotent, and
# works on a bare archlinux container as well as on the prepared ci-os-cachyos-builder image (Dockerfile.builder does the
# slow, stable half of this at image build time).
#
#   1. pacman's seccomp/landlock download sandbox: switched off only if pacman says it cannot start it (Rosetta)
#   2. pacman -Syu on the stock Arch repositories, keyring initialised
#   3. the CachyOS repository key: the committed armoured copy (or, if absent, a keyserver) must carry EXACTLY the fingerprint
#      pinned in upstream.lock before it is imported, and is locally signed
#   4. the [cachyos] repository above [core], as upstream's own CI does (the live profile's pacman.conf uses only this generic,
#      baseline x86-64 repo; the cachyos-v3/v4 repos are never configured: they break under Rosetta)
#   5. archiso grub cachyos-keyring git curl + the packages named in iso/render-deps.txt; archiso >= ARCHISO_MIN_VERSION
#
# Environment: CI_OS_LOCK (default: backends/cachyos/upstream.lock), CI_OS_RENDER_DEPS (default: iso/render-deps.txt).
set -euo pipefail
export LC_ALL=C

export CI_PROG=bootstrap
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHYOS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

[ "$(id -u)" -eq 0 ] || ci_die "run as root inside the builder container"
command -v pacman >/dev/null 2>&1 || ci_die "pacman not found: this is not an Arch container"
LOCK="${CI_OS_LOCK:-$CACHYOS_DIR/upstream.lock}"
RENDER_DEPS="${CI_OS_RENDER_DEPS:-$CACHYOS_DIR/iso/render-deps.txt}"
KEY_FILE="$CACHYOS_DIR/iso/docker/cachyos-repo-key.asc"
GNUPGHOME_PACMAN=/etc/pacman.d/gnupg
ci_load_lock "$LOCK"

# 1. sandbox ----------------------------------------------------------------------------------------------------------
# set_pacman_option NAME: make sure "NAME" is an active option under the first [options] header (the shipped file has two).
set_pacman_option() {
  local opt="$1"
  if grep -q "^${opt}\$" /etc/pacman.conf; then return 0; fi
  if grep -q "^#${opt}\$" /etc/pacman.conf; then sed -i "s/^#${opt}\$/${opt}/" /etc/pacman.conf; return 0; fi
  awk -v o="$opt" '{ print } /^\[options\]$/ && !d { print o; d = 1 }' /etc/pacman.conf > /etc/pacman.conf.new
  cat /etc/pacman.conf.new > /etc/pacman.conf
  rm -f /etc/pacman.conf.new
}
out="$(pacman -Sy 2>&1 || true)"      # not `| grep -q`: pipefail + SIGPIPE makes that test flaky
case "$out" in
  *seccomp*)  set_pacman_option DisableSandboxSyscalls; ci_log "pacman syscall sandbox disabled (it cannot start under Rosetta/qemu-user)" ;;
  *landlock*) set_pacman_option DisableSandboxFilesystem; ci_log "pacman filesystem sandbox disabled (landlock is unavailable here)" ;;
esac
if ! out="$(pacman -Sy 2>&1)"; then ci_err "pacman cannot sync its databases:"; printf '%s\n' "$out" >&2; exit 1; fi

# 2. stock Arch ---------------------------------------------------------------------------------------------------------
ci_log "pacman -Syu (stock Arch repositories)"
pacman -Syu --noconfirm
pacman-key --init
pacman-key --populate archlinux

# 3. CachyOS key --------------------------------------------------------------------------------------------------------
have_fpr() {
  gpg --homedir "$GNUPGHOME_PACMAN" --batch --with-colons --fingerprint "$1" 2>/dev/null \
    | awk -F: -v f="$1" '$1=="fpr" && $10==f {ok=1} END{exit !ok}'
}
if have_fpr "$CACHYOS_KEY_FPR"; then
  ci_log "CachyOS key $CACHYOS_KEY_FPR already in the pacman keyring"
elif [ -f "$KEY_FILE" ]; then
  ci_check_key_fpr "$KEY_FILE" "$CACHYOS_KEY_FPR"      # exactly one primary key, and it is the pinned one (lib/common.sh, unit-tested)
  pacman-key --add "$KEY_FILE"
else
  ci_warn "committed key file $KEY_FILE not found; falling back to the keyservers ($CACHYOS_KEYSERVERS)"
  imported=0
  for ks in $(printf '%s' "$CACHYOS_KEYSERVERS" | tr ',' ' '); do
    if pacman-key --recv-keys "$CACHYOS_KEY_FPR" --keyserver "$ks"; then imported=1; break; fi
  done
  [ "$imported" -eq 1 ] || ci_die "could not fetch the CachyOS key from any keyserver"
fi
have_fpr "$CACHYOS_KEY_FPR" || ci_die "after the import the pacman keyring does not hold $CACHYOS_KEY_FPR (fingerprint mismatch?)"
pacman-key --lsign-key "$CACHYOS_KEY_FPR"

# 4. [cachyos] above [core] ---------------------------------------------------------------------------------------------
if ! grep -q '^\[cachyos\]' /etc/pacman.conf; then
  # shellcheck disable=SC2016  # $arch and $repo are pacman variables, not shell variables
  sed -i '/^\[core\]$/i[cachyos]\nServer = https://mirror.cachyos.org/repo/$arch/$repo\n' /etc/pacman.conf
fi
first_repo="$(pacman-conf --repo-list | head -n 1)"
[ "$first_repo" = cachyos ] || ci_die "expected [cachyos] to be the first repository in /etc/pacman.conf, got '$first_repo'"

# 5. toolchain -----------------------------------------------------------------------------------------------------------
PKGS=(archiso grub cachyos-keyring git curl)
if [ -f "$RENDER_DEPS" ]; then
  while IFS= read -r n; do
    ci_valid_pkg_name "$n" || ci_die "$RENDER_DEPS: '$n' is not a package name (one per line)"
    PKGS+=("$n")
  done < <(ci_strip_list "$RENDER_DEPS")
else
  ci_log "no $RENDER_DEPS: no render dependencies to install"
fi
ci_log "pacman -Syu ${PKGS[*]}"
pacman -Syu --noconfirm --needed "${PKGS[@]}"
# The keyring package carries the packager keys; its hook populates them, this makes sure (idempotent).
pacman-key --populate cachyos

ver="$(pacman -Q archiso | awk '{print $2}')"
[ "$(vercmp "$ver" "$ARCHISO_MIN_VERSION")" -ge 0 ] || ci_die "archiso $ver is older than ARCHISO_MIN_VERSION=$ARCHISO_MIN_VERSION from upstream.lock"
command -v mkarchiso >/dev/null 2>&1 || ci_die "mkarchiso is not on PATH after installing archiso"
command -v grub-install >/dev/null 2>&1 || ci_die "grub-install is not on PATH (mkarchiso refuses uefi.grub without it)"

git config --global --add safe.directory '*'      # /work is a volume owned by another uid

ci_log "ready: $(pacman -Q archiso grub cachyos-keyring pacman | tr '\n' ' ')"
