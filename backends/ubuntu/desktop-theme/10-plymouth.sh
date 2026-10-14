#!/usr/bin/env bash
# Plymouth boot splash: CI logo and colors (no GNOME/dconf here).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

LOGO_SOURCE="$ASSET_INPUTS_DIR/Logo_Banner_Color.png"
PLYMOUTH_SPINNER_DIR="/usr/share/plymouth/themes/spinner"
WATERMARK_SCALE_PERCENT=50
WATERMARK_DEST="$PLYMOUTH_SPINNER_DIR/watermark.png"
PLYMOUTH_UBUNTU_TEXT_DIR="/usr/share/plymouth/themes/ubuntu-text"
UBUNTU_TEXT_PLYMOUTH="$PLYMOUTH_UBUNTU_TEXT_DIR/ubuntu-text.plymouth"
PLYMOUTH_SPINNER_CONF="$PLYMOUTH_SPINNER_DIR/spinner.plymouth"
PLYMOUTH_BGRT_CONF="/usr/share/plymouth/themes/bgrt/bgrt.plymouth"

# Boot palette from the canon tokens (vendor/brand/tokens/tokens.sh, sourced by lib.sh):
# ground = the dark background (navy), progress = the dark primary (sage), track = dark secondary.
# Before this the boot screen was painted in the logo ramp (#066c80 / #00a9a7 / #72ddd4), which
# is artwork, not the brand palette. Design review: see the PR that introduced this.
BG_DARK_GREEN="$(ci_hex0x "$CI_DARK_BACKGROUND")"
PROGRESS_BG="$(ci_hex0x "$CI_DARK_SECONDARY")"
PROGRESS_FG="$(ci_hex0x "$CI_DARK_PRIMARY")"

if [[ ! -f "$LOGO_SOURCE" ]]; then
  log_error "Logo file not found: $LOGO_SOURCE"
  exit 1
fi

if [[ ! -d "$PLYMOUTH_SPINNER_DIR" ]]; then
  log_error "Plymouth spinner theme directory not found: $PLYMOUTH_SPINNER_DIR"
  exit 1
fi

# An image build starts from the stock ISO every time and keeps no backups: a backup directory would ship
# Ubuntu's watermark and Plymouth configs inside the image, and its timestamped name makes the squashfs differ
# from build to build. Only a live system keeps one. A rebuild without --clean also reuses the chroot of the
# previous run, so an image build removes the backup directories an older version of this step left in it.
BACKUP_DIR=""
if ci_image_build; then
  rm -rf -- /usr/share/plymouth/ci-branding-backup-*
else
  BACKUP_DIR="/usr/share/plymouth/ci-branding-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
fi
backup_file() { # backup_file <file> <backup name>; nothing in an image build
  if [[ -n "$BACKUP_DIR" ]]; then cp "$1" "$BACKUP_DIR/$2"; fi
}

log_info "Replacing Plymouth watermark with CI branding..."
if [[ -f "$WATERMARK_DEST" ]]; then
  backup_file "$WATERMARK_DEST" watermark.png.bak
fi

if [[ "$WATERMARK_SCALE_PERCENT" -lt 100 ]] && command -v convert >/dev/null 2>&1; then
  convert "$LOGO_SOURCE" -resize "${WATERMARK_SCALE_PERCENT}%" "$WATERMARK_DEST"
elif [[ "$WATERMARK_SCALE_PERCENT" -lt 100 ]] && command -v magick >/dev/null 2>&1; then
  magick "$LOGO_SOURCE" -resize "${WATERMARK_SCALE_PERCENT}%" "$WATERMARK_DEST"
else
  if [[ "$WATERMARK_SCALE_PERCENT" -lt 100 ]]; then
    log_warn "ImageMagick not found; copying logo at full size."
  fi
  cp "$LOGO_SOURCE" "$WATERMARK_DEST"
fi
chmod 644 "$WATERMARK_DEST"

if [[ -f "$PLYMOUTH_SPINNER_CONF" ]]; then
  backup_file "$PLYMOUTH_SPINNER_CONF" spinner.plymouth.bak
  sed -i "s/BackgroundStartColor=0x[0-9a-fA-F]*/BackgroundStartColor=$BG_DARK_GREEN/" "$PLYMOUTH_SPINNER_CONF"
  sed -i "s/BackgroundEndColor=0x[0-9a-fA-F]*/BackgroundEndColor=$BG_DARK_GREEN/" "$PLYMOUTH_SPINNER_CONF"
  sed -i "s/ProgressBarBackgroundColor=0x[0-9a-fA-F]*/ProgressBarBackgroundColor=$PROGRESS_BG/" "$PLYMOUTH_SPINNER_CONF"
  sed -i "s/ProgressBarForegroundColor=0x[0-9a-fA-F]*/ProgressBarForegroundColor=$PROGRESS_FG/" "$PLYMOUTH_SPINNER_CONF"
fi

if [[ -f "$PLYMOUTH_BGRT_CONF" ]]; then
  backup_file "$PLYMOUTH_BGRT_CONF" bgrt.plymouth.bak
  sed -i "s/Font=Ubuntu 12/Font=Cantarell 12/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/TitleFont=Ubuntu Light 30/TitleFont=Cantarell Light 30/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/BackgroundStartColor=0x[0-9a-fA-F]*/BackgroundStartColor=$BG_DARK_GREEN/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/BackgroundEndColor=0x[0-9a-fA-F]*/BackgroundEndColor=$BG_DARK_GREEN/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/ProgressBarBackgroundColor=0x[0-9a-fA-F]*/ProgressBarBackgroundColor=$PROGRESS_BG/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/ProgressBarForegroundColor=0x[0-9a-fA-F]*/ProgressBarForegroundColor=$PROGRESS_FG/" "$PLYMOUTH_BGRT_CONF"
fi

if [[ -f "$UBUNTU_TEXT_PLYMOUTH" ]]; then
  backup_file "$UBUNTU_TEXT_PLYMOUTH" ubuntu-text.plymouth.bak
  TEXT_WHITE="$(ci_hex0x "$CI_DARK_FOREGROUND")"
  TEXT_BROWN="$(ci_hex0x "$CI_DARK_PRIMARY")"
  TEXT_BLUE="$(ci_hex0x "$CI_LIGHT_PRIMARY")"
  cat > "$UBUNTU_TEXT_PLYMOUTH" <<PLYMOUTH_EOF
[Plymouth Theme]
Name=CI OS Text
Description=Text mode theme with CI OS branding
ModuleName=ubuntu-text

[ubuntu-text]
title=CI OS 0.0.1
black=0x000000
white=$TEXT_WHITE
brown=$TEXT_BROWN
blue=$TEXT_BLUE
PLYMOUTH_EOF
  chmod 644 "$UBUNTU_TEXT_PLYMOUTH"
fi

if command -v update-alternatives >/dev/null 2>&1; then
  if update-alternatives --list default.plymouth 2>/dev/null | grep -q "bgrt"; then
    update-alternatives --set default.plymouth /usr/share/plymouth/themes/bgrt/bgrt.plymouth 2>/dev/null || true
  fi
  if [[ -f "$UBUNTU_TEXT_PLYMOUTH" ]] && update-alternatives --list text.plymouth 2>/dev/null | grep -q "ubuntu-text"; then
    update-alternatives --set text.plymouth "$UBUNTU_TEXT_PLYMOUTH" 2>/dev/null || true
  fi
fi

if command -v update-initramfs >/dev/null 2>&1; then
  log_info "Regenerating initramfs for Plymouth..."
  update-initramfs -u -k all 2>/dev/null || log_warn "update-initramfs reported warnings"
fi

if [[ -n "$BACKUP_DIR" ]]; then
  log_success "Plymouth CI branding applied (backup under $BACKUP_DIR)"
else
  log_success "Plymouth CI branding applied (image build: no backup)"
fi
