#!/usr/bin/env bash
#
# Single entry point for CI-OS desktop / OS branding (backends/ubuntu/desktop-theme/).
# Steps live here, in backends/_mixins/{gnome-dconf,kde-plasma}/ (shared with future
# non-Ubuntu backends), and in core/render/ — run in a fixed order so nothing is
# applied twice. See docs/architecture/multi-distro-design.md.
#
# Usage:
#   sudo ./apply-ci-os-desktop.sh
#                       Full apply: plymouth, grub, dconf, wallpaper, session, start-icon, os-release, motd
#   sudo ./apply-ci-os-desktop.sh --only plymouth,dconf
#   ./apply-ci-os-desktop.sh --validate
#                       Read-only checks (no sudo)
#   sudo ./apply-ci-os-desktop.sh --wizard
#                       Prompts, full apply, optional KDE, validation, optional reboot
#   sudo ./apply-ci-os-desktop.sh --wizard --yes
#                       Same flow without prompts (full apply + validate; skips KDE and reboot)
#   sudo ./apply-ci-os-desktop.sh --wizard --yes --with-kde
#                       Non-interactive wizard but run KDE step if Plasma is present
#   sudo ./apply-ci-os-desktop.sh --wizard --skip-reboot-check
#
# Session-only (current user, no sudo): see backends/ubuntu/desktop-theme/gnome-settings.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../core/lib/theme-lib.sh
source "$REPO_ROOT/core/lib/theme-lib.sh"

MIXIN_GNOME="$REPO_ROOT/backends/_mixins/gnome-dconf"
MIXIN_KDE="$REPO_ROOT/backends/_mixins/kde-plasma"
RENDER="$REPO_ROOT/core/render"

MODE="apply"
ONLY=""
AUTO_YES=0
SKIP_REBOOT=0
WITH_KDE=0

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
    --wizard | -i)
      MODE="wizard"
      shift
      ;;
    --yes)
      AUTO_YES=1
      shift
      ;;
    --skip-reboot-check)
      SKIP_REBOOT=1
      shift
      ;;
    --with-kde)
      WITH_KDE=1
      shift
      ;;
    -h | --help)
      cat <<EOF
Usage:
  sudo $0 [--only STEP,...]     Apply selected steps (default: all).
  $0 --validate                 Run validation only (no root).
  sudo $0 --wizard [options]    Interactive full apply + validate + reboot prompt.

Steps: plymouth, grub, dconf, terminal, wallpaper, session, start-icon, os-release, motd, kde

Examples:
  sudo $0
  sudo $0 --only wallpaper,session
  $0 --validate
  sudo $0 --wizard
  sudo $0 --wizard --yes
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

run_full_apply() {
  run_step plymouth "$SCRIPT_DIR/10-plymouth.sh"
  run_step grub "$SCRIPT_DIR/15-grub-theme.sh"
  run_step dconf "$MIXIN_GNOME/20-dconf-system.sh"
  run_step terminal "$MIXIN_GNOME/27-terminal-theme.sh"
  run_step wallpaper "$SCRIPT_DIR/30-wallpaper.sh"
  run_step session "$MIXIN_GNOME/25-session-gsettings.sh"
  run_step start-icon "$SCRIPT_DIR/40-start-icon.sh"
  run_step os-release "$SCRIPT_DIR/50-os-release.sh"
  run_step motd "$RENDER/render-motd.sh"
}

run_kde_if_requested() {
  case ",$ONLY," in
    *",kde,"*) ;;
    *) return 0 ;;
  esac
  log_info "=== kde ==="
  bash "$MIXIN_KDE/65-kde-theme.sh" || log_warn "KDE step failed (OK on GNOME-only systems)"
}

if [[ "$MODE" == "wizard" ]]; then
  if [[ ${EUID:-0} -ne 0 ]]; then
    log_error "Wizard requires sudo"
    exit 1
  fi
  echo ""
  log_info "CI-OS branding wizard (full apply + validate + optional reboot)"
  log_info "Dock: left + autohide. Assets: $ASSET_INPUTS_DIR"
  echo ""
  if [[ $AUTO_YES -eq 0 ]]; then
    read -r -p "Continue? (y/N) " -n 1 -r
    echo ""
    if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
      log_info "Aborted"
      exit 0
    fi
  fi
  ONLY=""
  run_full_apply
  if [[ $AUTO_YES -eq 0 ]]; then
    read -r -p "Install KDE color scheme if Plasma is present? (Y/n) " -n 1 -r
    echo ""
    if [[ ! ${REPLY:-} =~ ^[Nn]$ ]]; then
      bash "$MIXIN_KDE/65-kde-theme.sh" || log_warn "KDE step skipped or failed"
    fi
  elif [[ $WITH_KDE -eq 1 ]]; then
    bash "$MIXIN_KDE/65-kde-theme.sh" || log_warn "KDE step skipped or failed"
  fi
  log_info "=== validate ==="
  bash "$SCRIPT_DIR/80-validate-ci-theme.sh" || log_warn "Validation reported warnings"
  if [[ $SKIP_REBOOT -eq 0 ]] && [[ $AUTO_YES -eq 0 ]]; then
    echo ""
    read -r -p "Reboot now? (y/N) " -n 1 -r
    echo ""
    if [[ ${REPLY:-} =~ ^[Yy]$ ]]; then
      log_info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
      sleep 5
      reboot
    fi
  fi
  log_success "Wizard finished"
  exit 0
fi

# --- default: apply mode ---
if [[ ${EUID:-0} -ne 0 ]]; then
  log_error "Run with sudo (or use: $0 --validate / backends/ubuntu/desktop-theme/gnome-settings.sh for session-only)"
  exit 1
fi

run_full_apply
run_kde_if_requested

log_success "apply-ci-os-desktop finished (${ONLY:-all steps})"
