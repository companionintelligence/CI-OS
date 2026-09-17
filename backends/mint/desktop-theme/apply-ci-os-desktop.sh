#!/usr/bin/env bash
#
# Single entry point for CI-OS desktop / OS branding on Linux Mint (Cinnamon
# edition). Modeled directly on
# backends/ubuntu/desktop-theme/apply-ci-os-desktop.sh; see
# docs/architecture/multi-distro-design.md for the Phase 2 (Mint) scope.
#
# Reused directly from the Ubuntu backend, BY PATH (never copied — see that
# file's own header for why each is distro-portable):
#   - 10-plymouth.sh   — Plymouth is upstream-shared, not GNOME-specific.
#   - 15-grub-theme.sh — GRUB2 is shared by Mint; already fully distro-portable.
#   - core/render/render-motd.sh — fully portable MOTD renderer.
#
# NOT reused, by design:
#   - backends/_mixins/gnome-dconf/* — GNOME-Shell-specific (dash-to-dock,
#     GDM dconf profile, GNOME/Ptyxis Terminal enforcement). Cinnamon's
#     equivalents are the new 20-cinnamon-dconf.sh in this directory.
#     This also means Ubuntu's terminal theming (27-terminal-theme.sh) has NO
#     Mint counterpart yet, even though Mint Cinnamon ships the same GNOME
#     Terminal package and the dconf approach would likely carry over
#     unchanged — it lives under the excluded gnome-dconf mixin, so wiring it
#     in here would violate that exclusion. Known gap, not done in this pass;
#     see backends/mint/desktop-theme/80-validate-ci-theme.sh's header and the
#     implementation report for the follow-up options.
#   - backends/ubuntu/desktop-theme/40-start-icon.sh — hardcodes
#     /usr/share/icons/Yaru*/scalable/places; Mint ships Mint-Y icons at a
#     different path, so this would silently replace zero icons (and its own
#     "no theme replaced" guard would make it exit 1). No Mint version
#     written for this first pass — out of scope per the brief.
#   - backends/ubuntu/desktop-theme/50-os-release.sh — forces ID=ubuntu,
#     which is the deliberately-correct choice for Ubuntu-as-CI-OS (keeps
#     apt/Docker/AMDGPU installers happy on a machine that really is Ubuntu).
#     Mint's real ID is `linuxmint` (ID_LIKE="ubuntu debian"), and Mint's own
#     tooling (mintupdate, etc.) may key off that — overwriting it to `ubuntu`
#     is a real behavior change this backend does not make. Mint's apt
#     role-map already resolves via UBUNTU_CODENAME, which Mint's stock
#     os-release already carries natively (Mint 22.x = Ubuntu Noble base), so
#     no identity rewrite is needed for provisioning to work.
#   - backends/ubuntu/desktop-theme/30-wallpaper.sh — folded into
#     20-cinnamon-dconf.sh instead of ported separately; see that file's
#     header for why.
#
# Usage:
#   sudo ./apply-ci-os-desktop.sh
#                       Full apply: plymouth, grub, dconf, slick-greeter, motd
#   sudo ./apply-ci-os-desktop.sh --only plymouth,dconf
#   ./apply-ci-os-desktop.sh --validate
#                       Read-only checks (no sudo)
#
# Session-only (current user, no sudo): run
# backends/mint/desktop-theme/20-cinnamon-dconf.sh directly — it detects
# non-root and live-applies to the caller's own session only.
#
# No --wizard mode: Ubuntu's wizard adds interactive prompts, optional-KDE
# handling, and a reboot prompt that don't have a Mint equivalent yet (no KDE
# mixin is wired in here, and there's nothing Mint-specific left to prompt
# about). --only/--validate cover this backend's needs for a first pass;
# add --wizard here later if it earns its complexity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../core/lib/theme-lib.sh
source "$REPO_ROOT/core/lib/theme-lib.sh"

UBUNTU_THEME="$REPO_ROOT/backends/ubuntu/desktop-theme"
RENDER="$REPO_ROOT/core/render"

MODE="apply"
ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      ONLY="${2:-}"
      ONLY="${ONLY// /}"
      shift 2
      ;;
    --validate | --validate-only)
      MODE="validate"
      shift
      ;;
    -h | --help)
      cat <<EOF
Usage:
  sudo $0 [--only STEP,...]     Apply selected steps (default: all).
  $0 --validate                 Run validation only (no root).

Steps: plymouth, grub, dconf, slick-greeter, motd

Examples:
  sudo $0
  sudo $0 --only dconf,slick-greeter
  $0 --validate
EOF
      exit 0
      ;;
    *)
      log_error "Unknown option: $1 (try --help)"
      exit 1
      ;;
  esac
done

if [[ "$MODE" == "validate" ]]; then
  exec bash "$SCRIPT_DIR/80-validate-ci-theme.sh"
fi

want() {
  local n="$1"
  if [[ -z "$ONLY" ]]; then
    return 0
  fi
  case ",$ONLY," in
    *",$n,"*) return 0 ;;
    *) return 1 ;;
  esac
}

run_step() {
  local name="$1" file="$2"
  if want "$name"; then
    log_info "=== $name ==="
    bash "$file"
  fi
}

if [[ ${EUID:-0} -ne 0 ]]; then
  log_error "Run with sudo (or use: $0 --validate / backends/mint/desktop-theme/20-cinnamon-dconf.sh for session-only)"
  exit 1
fi

run_step plymouth "$UBUNTU_THEME/10-plymouth.sh"
run_step grub "$UBUNTU_THEME/15-grub-theme.sh"
run_step dconf "$SCRIPT_DIR/20-cinnamon-dconf.sh"
run_step slick-greeter "$SCRIPT_DIR/30-slick-greeter.sh"
run_step motd "$RENDER/render-motd.sh"

log_success "apply-ci-os-desktop finished (${ONLY:-all steps})"
