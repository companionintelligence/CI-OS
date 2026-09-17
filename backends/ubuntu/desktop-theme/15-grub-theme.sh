#!/usr/bin/env bash
# GRUB boot-menu theming: canon background image + branding-only keys in
# /etc/default/grub (GRUB_DISTRIBUTOR, GRUB_BACKGROUND, GRUB_GFXMODE,
# GRUB_TIMEOUT*). Never touches GRUB_CMDLINE_LINUX_DEFAULT/kernel params.
#
# Deliberately does NOT set GRUB_TERMINAL — that used to be hardcoded to
# "console" here, which silently disables GRUB_BACKGROUND (console mode is
# text-only; backgrounds need gfxterm). Leaving it unset lets GRUB default to
# gfxterm when a background is present.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
source "${REPO_ROOT}/core/lib/grub-merge.sh"
require_root

GRUB_BG_DEST="/usr/share/pixmaps/ci-os-grub-bg.png"
GRUB_DEFAULT_FILE="/etc/default/grub"

if [[ ! -f "$GRUB_DEFAULT_FILE" ]]; then
  log_error "GRUB default file not found: $GRUB_DEFAULT_FILE (is grub2-common installed?)"
  exit 1
fi

log_info "Rendering GRUB background from the canon tokens..."
bash "${REPO_ROOT}/core/render/render-grub-background.sh" "$GRUB_BG_DEST" || {
  log_warn "Could not render GRUB background; GRUB will keep its previous/default background"
}

if [[ -f "$GRUB_BG_DEST" ]]; then
  chmod 644 "$GRUB_BG_DEST"
  ci_grub_merge_key "$GRUB_DEFAULT_FILE" GRUB_BACKGROUND "$GRUB_BG_DEST"
fi

ci_grub_merge_key "$GRUB_DEFAULT_FILE" GRUB_DISTRIBUTOR "CI OS"
ci_grub_merge_key "$GRUB_DEFAULT_FILE" GRUB_GFXMODE "auto"
ci_grub_merge_key "$GRUB_DEFAULT_FILE" GRUB_TIMEOUT_STYLE "menu"
ci_grub_merge_key "$GRUB_DEFAULT_FILE" GRUB_TIMEOUT "5"

if command -v update-grub >/dev/null 2>&1; then
  log_info "Regenerating GRUB config..."
  update-grub || log_warn "update-grub reported warnings"
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg || log_warn "grub-mkconfig reported warnings"
else
  log_warn "Neither update-grub nor grub-mkconfig found; GRUB config not regenerated"
fi

log_success "GRUB theme applied (background + CI OS distributor name)"
