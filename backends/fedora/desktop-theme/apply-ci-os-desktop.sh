#!/usr/bin/env bash
#
# Single entry point for CI-OS desktop / OS branding on Fedora Workstation
# (GNOME Shell). Modeled directly on
# backends/mint/desktop-theme/apply-ci-os-desktop.sh; see
# docs/architecture/multi-distro-design.md for the Phase 3a (Fedora) scope.
# Phase 3b (kickstart/lorax ISO building) is explicitly out of scope here —
# nothing in this directory builds or touches an ISO.
#
# Reused directly, BY PATH (never copied):
#   - backends/ubuntu/desktop-theme/10-plymouth.sh   — Plymouth is
#     upstream-shared, not GNOME- or apt-specific.
#   - backends/ubuntu/desktop-theme/15-grub-theme.sh — GRUB2 is shared by
#     Fedora; already fully distro-portable (uses update-grub OR
#     grub-mkconfig, whichever is present — Fedora has grub-mkconfig).
#   - backends/ubuntu/desktop-theme/30-wallpaper.sh  — installs the canon
#     wallpaper PNG and its dconf defaults; no apt/Yaru assumptions.
#   - core/render/render-motd.sh — writes /etc/update-motd.d/*. UNVERIFIED
#     ASSUMPTION carried over from this backend's brief, flagged honestly
#     here rather than silently trusted: /etc/update-motd.d is a
#     Debian/Ubuntu pam_motd convention. Whether Fedora's stock
#     openssh-server + PAM config actually wires motd_dir=/etc/update-motd.d
#     into login (the way Ubuntu's does) was NOT independently verified
#     against a live Fedora box for this pass — the files get written
#     either way (harmless if unused), but the MOTD may not actually
#     display at login. See 80-validate-ci-theme.sh's MOTD check, which
#     warns rather than fails for exactly this reason.
#   - backends/_mixins/gnome-dconf/20-dconf-system.sh   — system dconf +
#     GDM-profile defaults (dock/power/privacy/background/window-manager
#     keys). GNOME-Shell-specific, which IS what Fedora Workstation ships
#     (unlike Mint/Cinnamon, which correctly does not reuse this mixin).
#   - backends/_mixins/gnome-dconf/25-session-gsettings.sh — live gsettings
#     apply for the current/sudo desktop user, mirroring the dconf defaults.
#   - backends/_mixins/gnome-dconf/27-terminal-theme.sh — GNOME Terminal +
#     Ptyxis blue/teal profile. Actually a BETTER fit on modern Fedora than
#     on Ubuntu: Ptyxis (not GNOME Terminal) is the default terminal app
#     from GNOME 47 onward, which is the GNOME version this backend
#     targets — this script's Ptyxis branch is live-relevant here, not
#     vestigial.
#
# Known, disclosed no-ops from reusing 20-dconf-system.sh /
# 25-session-gsettings.sh unchanged (not bugs to fix here; see the
# "Exception: report genuine bugs found while reading" note in this task's
# brief — these ARE that report):
#   - Their org/gnome/shell/extensions/dash-to-dock keys target an
#     extension Fedora Workstation does not install by default (Ubuntu
#     ships dash-to-dock out of the box; stock GNOME Shell uses its
#     built-in overview dash instead). Writing dconf keys for a schema that
#     isn't installed is harmless — dconf keyfiles aren't schema-validated
#     at write time, and gsettings failures are already swallowed
#     (`2>/dev/null || true`) — but the dock branding has no visible effect
#     on a stock Fedora install.
#   - gnome-defaults.inc.sh's CI_FAVORITE_APPS list hardcodes
#     'chromium_chromium.desktop' (an Ubuntu snap .desktop id) and
#     'org.gnome.Nautilus.desktop' — Nautilus's id matches Fedora too, but
#     the Chromium entry resolves to nothing on Fedora (no Chromium
#     installed/no snap). Cosmetic: an unresolvable favorite-apps entry is
#     silently ignored by GNOME Shell, not an error.
#
# NOT reused, and out of scope for this pass (documented, not silently
# dropped):
#   - core/render/render-gnome-shell-gresource.sh (+ the Yaru-specific
#     THEME_NAME=Yaru caller/color-map/audit-patterns files) — Fedora's
#     GDM/GNOME-Shell branding uses the accent-color mechanism instead; see
#     28-gdm-accent-branding.sh's header for the full reasoning.
#   - backends/ubuntu/desktop-theme/40-start-icon.sh — hardcodes
#     /usr/share/icons/Yaru*/scalable/places; Fedora ships no Yaru icon
#     theme, so this would silently replace zero icons (and its own
#     "nothing replaced" guard would exit 1). No Fedora start-icon
#     equivalent written for this first pass — same call Mint made, for the
#     same reason.
#   - backends/ubuntu/desktop-theme/50-os-release.sh — forces ID=ubuntu,
#     the deliberately-correct choice for Ubuntu-as-CI-OS (keeps
#     apt/ROCm/AMDGPU installers happy). Fedora's own os-release already
#     correctly says ID=fedora; nothing in this backend depends on it
#     saying anything else, so it is never rewritten. Same call Mint made.
#   - backends/_mixins/kde-plasma/ — this pass targets Fedora Workstation
#     (GNOME Shell) only, not Fedora KDE Plasma spin. No --with-kde flag
#     here; add a Fedora KDE step later if that spin becomes in-scope.
#
# New in this backend:
#   - 28-gdm-accent-branding.sh — Fedora's GDM/GNOME-Shell branding step
#     (accent-color + color-scheme) AND the corrective overlay for the
#     Yaru-hardcoded values the reused mixin steps above leave behind. Must
#     run AFTER dconf/session/terminal (see its own header for the ordering
#     rationale — it wins on a higher-numbered dconf fragment and a
#     later-applied live gsettings call).
#   - gnome-defaults-fedora-overrides.inc.sh — the small Adwaita-specific
#     data (GTK/icon/cursor theme names, accent-color, color-scheme) that
#     28-gdm-accent-branding.sh sources.
#
# Usage:
#   sudo ./apply-ci-os-desktop.sh
#                       Full apply: plymouth, grub, dconf, terminal,
#                       wallpaper, session, accent, motd
#   sudo ./apply-ci-os-desktop.sh --only plymouth,dconf
#   ./apply-ci-os-desktop.sh --validate
#                       Read-only checks (no sudo)
#
# Session-only (current user, no sudo): run
# backends/_mixins/gnome-dconf/25-session-gsettings.sh or
# backends/fedora/desktop-theme/28-gdm-accent-branding.sh directly — both
# detect non-root and live-apply to the caller's own session only.
#
# No --wizard mode, matching Mint's own reasoning: that adds interactive
# prompts, KDE handling, and a reboot prompt this backend doesn't need yet
# (no KDE mixin wired in here). --only/--validate cover this first pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../core/lib/theme-lib.sh
source "$REPO_ROOT/core/lib/theme-lib.sh"

UBUNTU_THEME="$REPO_ROOT/backends/ubuntu/desktop-theme"
MIXIN_GNOME="$REPO_ROOT/backends/_mixins/gnome-dconf"
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

Steps: plymouth, grub, dconf, terminal, wallpaper, session, accent, motd

Examples:
  sudo $0
  sudo $0 --only dconf,accent
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
  log_error "Run with sudo (or use: $0 --validate / backends/_mixins/gnome-dconf/25-session-gsettings.sh for session-only)"
  exit 1
fi

run_step plymouth "$UBUNTU_THEME/10-plymouth.sh"
run_step grub "$UBUNTU_THEME/15-grub-theme.sh"
run_step dconf "$MIXIN_GNOME/20-dconf-system.sh"
run_step terminal "$MIXIN_GNOME/27-terminal-theme.sh"
run_step wallpaper "$UBUNTU_THEME/30-wallpaper.sh"
run_step session "$MIXIN_GNOME/25-session-gsettings.sh"
run_step accent "$SCRIPT_DIR/28-gdm-accent-branding.sh"
run_step motd "$RENDER/render-motd.sh"

log_success "apply-ci-os-desktop finished (${ONLY:-all steps})"
