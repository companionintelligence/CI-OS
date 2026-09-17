#!/usr/bin/env bash
#
# Single entry point for CI-OS desktop / OS branding on Arch Linux (GNOME
# Shell — the plan's recommended DE for this backend, reusing
# backends/_mixins/gnome-dconf/ like Fedora, not a new DE-specific mixin).
# Modeled directly on backends/fedora/desktop-theme/apply-ci-os-desktop.sh;
# see docs/architecture/multi-distro-design.md for the Phase 4 (Arch) scope.
# archiso profile-building is explicitly out of scope here — nothing in this
# directory builds or touches install media.
#
# PREREQUISITE, not installed by this script or by
# backends/arch/provision/provision.sh: GNOME Shell + GDM already installed
# and a bootloader (GRUB or systemd-boot) already configured. Arch has no
# "Workstation"/"Desktop" installer flavor the way Ubuntu/Fedora do — see
# provision.sh's header and 15-grub-theme.sh's header for the fuller
# reasoning and how the GRUB step specifically detects and cleanly skips on
# a systemd-boot-only system instead of assuming GRUB is there.
#
# Reused directly, BY PATH (never copied):
#   - backends/ubuntu/desktop-theme/10-plymouth.sh   — Plymouth is
#     upstream-shared, not GNOME- or apt-specific. Identical reasoning to
#     Fedora's/Mint's reuse of this file.
#   - backends/ubuntu/desktop-theme/30-wallpaper.sh  — installs the canon
#     wallpaper PNG and its dconf defaults; no apt/Yaru assumptions.
#   - core/render/render-motd.sh — writes /etc/update-motd.d/*. Same
#     UNVERIFIED ASSUMPTION Fedora's apply-ci-os-desktop.sh already flags
#     honestly: /etc/update-motd.d is a Debian/Ubuntu pam_motd convention.
#     Whether Arch's stock openssh + PAM config wires motd_dir=/etc/update-motd.d
#     into login was NOT independently verified against a live Arch box for
#     this pass either — the files get written either way (harmless if
#     unused), but the MOTD may not actually display at login. See
#     80-validate-ci-theme.sh's MOTD check, which warns rather than fails
#     for exactly this reason, same as Fedora's.
#   - backends/_mixins/gnome-dconf/20-dconf-system.sh   — system dconf +
#     GDM-profile defaults (dock/power/privacy/background/window-manager
#     keys). GNOME-Shell-specific, which IS what this backend targets per
#     the plan's recommendation (see docs/architecture/multi-distro-design.md).
#   - backends/_mixins/gnome-dconf/25-session-gsettings.sh — live gsettings
#     apply for the current/sudo desktop user, mirroring the dconf defaults.
#   - backends/_mixins/gnome-dconf/27-terminal-theme.sh — GNOME Terminal +
#     Ptyxis blue/teal profile. Ptyxis is GNOME's own default terminal app
#     from GNOME 47 onward on ANY distro that ships stock upstream GNOME —
#     which Arch does even more closely than Fedora — so this script's
#     Ptyxis branch is live-relevant here too, not vestigial.
#
# NOT reused directly — Arch gets its OWN detect-and-delegate wrapper:
#   - backends/ubuntu/desktop-theme/15-grub-theme.sh is NOT called directly
#     here. See backends/arch/desktop-theme/15-grub-theme.sh's own header
#     for why: Ubuntu's script hard-fails (exit 1) when /etc/default/grub is
#     missing, which is correct on Ubuntu/Mint/Fedora (GRUB is guaranteed
#     there) but wrong on Arch, where systemd-boot-only systems are common
#     and expected. This backend's own 15-grub-theme.sh detects which
#     bootloader is in use and either delegates to Ubuntu's script (GRUB
#     present) or skips cleanly (systemd-boot, or neither detected).
#
# Known, disclosed no-ops from reusing 20-dconf-system.sh /
# 25-session-gsettings.sh unchanged (not bugs to fix here — see Fedora's
# identical disclosure, which applies unchanged to Arch's stock GNOME too):
#   - Their org/gnome/shell/extensions/dash-to-dock keys target an extension
#     that is not part of a stock Arch GNOME Shell install either (same as
#     Fedora Workstation) — harmless no-op, no visible effect.
#   - gnome-defaults.inc.sh's CI_FAVORITE_APPS list hardcodes
#     'chromium_chromium.desktop' (an Ubuntu snap .desktop id); Arch's
#     chromium package (see provision.sh) registers a plain
#     chromium.desktop, so this entry also resolves to nothing here.
#     Cosmetic, silently ignored by GNOME Shell.
#
# NOT reused, and out of scope for this pass (documented, not silently
# dropped) — identical reasoning to Fedora's:
#   - core/render/render-gnome-shell-gresource.sh (+ the Yaru-specific
#     THEME_NAME=Yaru caller/color-map/audit-patterns files) — this
#     backend's own research (see 28-gdm-accent-branding.sh's header)
#     independently confirmed Arch's GNOME Shell theme is compiled in, not a
#     separate package, same as Fedora's finding — the accent-color
#     mechanism is used instead.
#   - backends/ubuntu/desktop-theme/40-start-icon.sh — hardcodes
#     /usr/share/icons/Yaru*/scalable/places; Arch ships no Yaru icon theme
#     (official or AUR), so this would silently replace zero icons. No Arch
#     start-icon equivalent written for this first pass — same call
#     Mint/Fedora made, for the same reason.
#   - backends/ubuntu/desktop-theme/50-os-release.sh — forces ID=ubuntu, the
#     deliberately-correct choice for Ubuntu-as-CI-OS. Arch's own os-release
#     already correctly says ID=arch; nothing in this backend depends on it
#     saying anything else (pacman.yaml's role resolution doesn't key off
#     os-release at all, unlike apt's codename-based repo URLs), so it is
#     never rewritten. Same call Mint/Fedora made.
#   - backends/_mixins/kde-plasma/ — this pass targets GNOME Shell only, per
#     the plan's explicit recommendation for this backend. No --with-kde
#     flag here.
#
# New in this backend:
#   - 15-grub-theme.sh — the GRUB/systemd-boot detect-and-delegate wrapper
#     described above (Arch-specific; no Fedora/Mint equivalent needed,
#     since GRUB is guaranteed present on those distros).
#   - 28-gdm-accent-branding.sh — Arch's GDM/GNOME-Shell branding step
#     (accent-color + color-scheme) AND the corrective overlay for the
#     Yaru-hardcoded values the reused mixin steps above leave behind.
#     Modeled on Fedora's step of the same name; must run AFTER
#     dconf/session/terminal for the same dconf-filename-merge-order reason
#     (see its own header).
#   - gnome-defaults-arch-overrides.inc.sh — the small Adwaita-specific data
#     (GTK/icon/cursor theme names, accent-color, color-scheme) that
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
# backends/arch/desktop-theme/28-gdm-accent-branding.sh directly — both
# detect non-root and live-apply to the caller's own session only.
#
# No --wizard mode, matching Mint's/Fedora's own reasoning: no KDE handling
# is wired in here. --only/--validate cover this first pass.

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
run_step grub "$SCRIPT_DIR/15-grub-theme.sh"
run_step dconf "$MIXIN_GNOME/20-dconf-system.sh"
run_step terminal "$MIXIN_GNOME/27-terminal-theme.sh"
run_step wallpaper "$UBUNTU_THEME/30-wallpaper.sh"
run_step session "$MIXIN_GNOME/25-session-gsettings.sh"
run_step accent "$SCRIPT_DIR/28-gdm-accent-branding.sh"
run_step motd "$RENDER/render-motd.sh"

log_success "apply-ci-os-desktop finished (${ONLY:-all steps})"
