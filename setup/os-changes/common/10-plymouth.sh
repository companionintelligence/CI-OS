#!/usr/bin/env bash
# Plymouth boot splash: CI logo and colors (no GNOME/dconf here).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

LOGO_SOURCE="$OS_CHANGES_DIR/Logo_Banner_Color.png"
PLYMOUTH_SPINNER_DIR="/usr/share/plymouth/themes/spinner"
WATERMARK_SCALE_PERCENT=50
WATERMARK_DEST="$PLYMOUTH_SPINNER_DIR/watermark.png"
PLYMOUTH_UBUNTU_TEXT_DIR="/usr/share/plymouth/themes/ubuntu-text"
UBUNTU_TEXT_PLYMOUTH="$PLYMOUTH_UBUNTU_TEXT_DIR/ubuntu-text.plymouth"
PLYMOUTH_SPINNER_CONF="$PLYMOUTH_SPINNER_DIR/spinner.plymouth"
PLYMOUTH_BGRT_CONF="/usr/share/plymouth/themes/bgrt/bgrt.plymouth"

BG_DARK_GREEN="0x066c80"
PROGRESS_BG="0x1b4332"
PROGRESS_FG="0x00a9a7"

if [[ ! -f "$LOGO_SOURCE" ]]; then
  log_error "Logo file not found: $LOGO_SOURCE"
  exit 1
fi

if [[ ! -d "$PLYMOUTH_SPINNER_DIR" ]]; then
  log_error "Plymouth spinner theme directory not found: $PLYMOUTH_SPINNER_DIR"
  exit 1
fi

BACKUP_DIR="/usr/share/plymouth/ci-branding-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

log_info "Replacing Plymouth watermark with CI branding..."
if [[ -f "$WATERMARK_DEST" ]]; then
  cp "$WATERMARK_DEST" "$BACKUP_DIR/watermark.png.bak"
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
  cp "$PLYMOUTH_SPINNER_CONF" "$BACKUP_DIR/spinner.plymouth.bak"
  sed -i "s/BackgroundStartColor=0x[0-9a-fA-F]*/BackgroundStartColor=$BG_DARK_GREEN/" "$PLYMOUTH_SPINNER_CONF"
  sed -i "s/BackgroundEndColor=0x[0-9a-fA-F]*/BackgroundEndColor=$BG_DARK_GREEN/" "$PLYMOUTH_SPINNER_CONF"
  sed -i "s/ProgressBarBackgroundColor=0x[0-9a-fA-F]*/ProgressBarBackgroundColor=$PROGRESS_BG/" "$PLYMOUTH_SPINNER_CONF"
  sed -i "s/ProgressBarForegroundColor=0x[0-9a-fA-F]*/ProgressBarForegroundColor=$PROGRESS_FG/" "$PLYMOUTH_SPINNER_CONF"
fi

if [[ -f "$PLYMOUTH_BGRT_CONF" ]]; then
  cp "$PLYMOUTH_BGRT_CONF" "$BACKUP_DIR/bgrt.plymouth.bak"
  sed -i "s/Font=Ubuntu 12/Font=Cantarell 12/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/TitleFont=Ubuntu Light 30/TitleFont=Cantarell Light 30/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/BackgroundStartColor=0x[0-9a-fA-F]*/BackgroundStartColor=$BG_DARK_GREEN/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/BackgroundEndColor=0x[0-9a-fA-F]*/BackgroundEndColor=$BG_DARK_GREEN/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/ProgressBarBackgroundColor=0x[0-9a-fA-F]*/ProgressBarBackgroundColor=$PROGRESS_BG/" "$PLYMOUTH_BGRT_CONF"
  sed -i "s/ProgressBarForegroundColor=0x[0-9a-fA-F]*/ProgressBarForegroundColor=$PROGRESS_FG/" "$PLYMOUTH_BGRT_CONF"
fi

if [[ -f "$UBUNTU_TEXT_PLYMOUTH" ]]; then
  cp "$UBUNTU_TEXT_PLYMOUTH" "$BACKUP_DIR/ubuntu-text.plymouth.bak"
  cat > "$UBUNTU_TEXT_PLYMOUTH" <<'PLYMOUTH_EOF'
[Plymouth Theme]
Name=CI OS Text
Description=Text mode theme with CI OS branding
ModuleName=ubuntu-text

[ubuntu-text]
title=CI OS 0.0.1
black=0x000000
white=0x72ddd4
brown=0x00a9a7
blue=0x066c80
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

log_success "Plymouth CI branding applied (backup under $BACKUP_DIR)"
