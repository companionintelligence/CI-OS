#!/usr/bin/env bash
# Plymouth boot splash: CI logo and colors (no GNOME/dconf here).
#
# This step brands the ROOTFS copy of the themes, which is what an installed system boots with (curtin
# regenerates its initramfs from it). The live session's own splash is drawn from the casper initrd, which carries
# its own copies of the same theme files; build-iso.sh (brand_boot_media) repaints those with the same
# ci_plymouth_* helpers and takes the watermark and the fallback logo from this rootfs. Note that the bgrt theme,
# the default, paints black behind the firmware logo (or the fallback below); see ci_plymouth_recolor.
#
# Every file below that a Plymouth package owns (watermark.png, bgrt-fallback.png, bgrt.plymouth, spinner.plymouth,
# and the text theme's template ubuntu-text.plymouth.in) goes in through ci_install_file / ci_install_edited, which
# dpkg-divert Ubuntu's file first: an upgrade of the package then unpacks Ubuntu's file to <file>.ubuntu-stock and
# cannot bring its logo or colours back, and its postinst cannot rebuild the initramfs with them. The text theme
# itself, ubuntu-text.plymouth, is no package's file but the package's postinst regenerates it from the template
# (on configure and whenever /etc/lsb-release changes), so the template is branded too.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/core/lib/theme-lib.sh"
require_root

LOGO_SOURCE="$ASSET_INPUTS_DIR/Logo_Banner_Color.png"
PLYMOUTH_SPINNER_DIR="/usr/share/plymouth/themes/spinner"
WATERMARK_SCALE_PERCENT=50
WATERMARK_DEST="$PLYMOUTH_SPINNER_DIR/watermark.png"
PLYMOUTH_UBUNTU_TEXT_DIR="/usr/share/plymouth/themes/ubuntu-text"
UBUNTU_TEXT_PLYMOUTH="$PLYMOUTH_UBUNTU_TEXT_DIR/ubuntu-text.plymouth"
UBUNTU_TEXT_TEMPLATE="$UBUNTU_TEXT_PLYMOUTH.in"
PLYMOUTH_SPINNER_CONF="$PLYMOUTH_SPINNER_DIR/spinner.plymouth"
PLYMOUTH_BGRT_CONF="/usr/share/plymouth/themes/bgrt/bgrt.plymouth"

# The firmware-logo fallback: the bgrt theme draws the firmware's own boot logo (the ACPI BGRT table) and, where
# there is none (legacy BIOS, most VMs, some firmware), bgrt-fallback.png from the theme directory, which is
# Ubuntu's logo in a circle of friends. Same size as Ubuntu's file, so the layout does not move.
FALLBACK_DEST="$PLYMOUTH_SPINNER_DIR/bgrt-fallback.png"
FALLBACK_PX=128
FALLBACK_PNG_NAME="ci-os-bgrt-fallback.png"
FALLBACK_STAGED_DIR="$REPO_ROOT/core/render/output"
MARK_SVG="$REPO_ROOT/vendor/brand/logos/mark.svg"
RENDER_MARK="$REPO_ROOT/core/render/render-mark-png.sh"

# The boot palette (ground = the dark background, progress = the dark primary, track = the dark secondary) is
# ci_plymouth_recolor's, from the canon tokens (vendor/brand/tokens/tokens.sh, sourced by theme-lib.sh). Before
# the canon the boot screen was painted in the logo ramp (#066c80 / #00a9a7 / #72ddd4), which is artwork, not
# the brand palette.

# The text-mode splash (safe-graphics boot, and the fallback when no graphics come up) is titled with the product
# and its version: the build's CI_OS_VERSION (run_theme_step exports it), else the CI_OS_VERSION a branded
# /etc/os-release carries, else a branded PRETTY_NAME as it stands. With none of them the title is plain "Companion OS":
# an invented version number would be worse than none.
ci_text_splash_title() {
  local ver="${CI_OS_VERSION:-}" pretty=""
  if [[ -z "$ver" && -r /etc/os-release ]]; then
    ver="$( . /etc/os-release 2>/dev/null && echo "${CI_OS_VERSION:-}" || true )"
    pretty="$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}" || true )"
  fi
  if [[ -n "$ver" ]]; then
    echo "Companion OS $ver"
  elif [[ "$pretty" == "Companion OS"* ]]; then
    echo "$pretty"
  else
    echo "Companion OS"
  fi
}

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

# Everything installed below is built in a private directory first and installed from there (ci_install_file moves
# Ubuntu's file aside, then puts ours in its place).
STEP_TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$STEP_TMP"
}
trap cleanup EXIT

log_info "Replacing Plymouth watermark with CI branding..."
if [[ -f "$WATERMARK_DEST" ]]; then
  backup_file "$WATERMARK_DEST" watermark.png.bak
fi

WATERMARK_NEW="$STEP_TMP/watermark.png"
if [[ "$WATERMARK_SCALE_PERCENT" -lt 100 ]] && command -v convert >/dev/null 2>&1; then
  convert "$LOGO_SOURCE" -resize "${WATERMARK_SCALE_PERCENT}%" "$WATERMARK_NEW"
elif [[ "$WATERMARK_SCALE_PERCENT" -lt 100 ]] && command -v magick >/dev/null 2>&1; then
  magick "$LOGO_SOURCE" -resize "${WATERMARK_SCALE_PERCENT}%" "$WATERMARK_NEW"
else
  # An image build runs in the stock desktop chroot, which has no ImageMagick: customize-chroot.sh scaled the logo on
  # the build host (which must have ImageMagick) and laid it over $LOGO_SOURCE, so it is copied as it is and there is
  # nothing to warn about; verify-iso.sh checks the width. Only a live system can really end up with the full-size logo.
  if [[ "$WATERMARK_SCALE_PERCENT" -lt 100 ]] && ! ci_image_build; then
    log_warn "ImageMagick not found; copying logo at full size."
  fi
  cp "$LOGO_SOURCE" "$WATERMARK_NEW"
fi
# watermark.png belongs to the plymouth package.
ci_install_file "$WATERMARK_NEW" "$WATERMARK_DEST"

# --- the firmware-logo fallback: staged (image build) or rendered here (live system) -----------------------
# The colour mark, transparent background, FALLBACK_PX square. The stock desktop image has no rsvg-convert or
# ImageMagick, so an image build renders it on the build host (core/render/render-mark-png.sh) and stages it in
# core/render/output/; with nothing staged (a live system) this step renders it itself. A live system with no
# renderer keeps Ubuntu's fallback logo, says so, and goes on; an image build never ships it, so it fails instead.
FALLBACK_PNG="$FALLBACK_STAGED_DIR/$FALLBACK_PNG_NAME"
if [[ ! -f "$FALLBACK_PNG" ]]; then
  if ci_image_build; then
    log_error "No pre-rendered firmware-logo fallback in $FALLBACK_STAGED_DIR: customize-chroot.sh renders it on the build host and stages it"
    exit 1
  fi
  FALLBACK_PNG=""
  if [[ ! -f "$MARK_SVG" || ! -f "$RENDER_MARK" ]]; then
    log_warn "No pre-rendered firmware-logo fallback in $FALLBACK_STAGED_DIR and no $RENDER_MARK or $MARK_SVG to render one"
  elif ! command -v rsvg-convert >/dev/null 2>&1 && ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
    log_warn "Neither rsvg-convert nor ImageMagick is installed, so the firmware-logo fallback cannot be drawn (apt-get install librsvg2-bin)"
  else
    log_info "Rendering the firmware-logo fallback..."
    if bash "$RENDER_MARK" "$STEP_TMP/$FALLBACK_PNG_NAME" "$FALLBACK_PX"; then
      FALLBACK_PNG="$STEP_TMP/$FALLBACK_PNG_NAME"
    else
      log_warn "Rendering the firmware-logo fallback failed"
    fi
  fi
  if [[ -z "$FALLBACK_PNG" ]]; then
    log_warn "Machines with no firmware boot logo keep Ubuntu's fallback logo; the rest of this step still applies. Re-run: apply-ci-os-desktop.sh --only plymouth"
  fi
fi
if [[ -n "$FALLBACK_PNG" ]]; then
  if [[ -f "$FALLBACK_DEST" ]]; then
    backup_file "$FALLBACK_DEST" bgrt-fallback.png.bak
  fi
  # bgrt-fallback.png belongs to a Plymouth theme package: ci_install_file diverts Ubuntu's file first, so an
  # upgrade of the package puts it at bgrt-fallback.png.ubuntu-stock and cannot bring the Ubuntu logo back.
  ci_install_file "$FALLBACK_PNG" "$FALLBACK_DEST"
fi

# The rootfs has Cantarell; the casper initrd's copy keeps Ubuntu's fonts, the only ones it carries.
bgrt_rootfs_theme() { # bgrt_rootfs_theme <copy of bgrt.plymouth>
  sed -i "s/Font=Ubuntu 12/Font=Cantarell 12/" "$1"
  sed -i "s/TitleFont=Ubuntu Light 30/TitleFont=Cantarell Light 30/" "$1"
  ci_plymouth_recolor "$1"
}

# spinner.plymouth and bgrt.plymouth belong to plymouth-theme-spinner.
if [[ -f "$PLYMOUTH_SPINNER_CONF" ]]; then
  backup_file "$PLYMOUTH_SPINNER_CONF" spinner.plymouth.bak
  ci_install_edited "$PLYMOUTH_SPINNER_CONF" ci_plymouth_recolor
fi

if [[ -f "$PLYMOUTH_BGRT_CONF" ]]; then
  backup_file "$PLYMOUTH_BGRT_CONF" bgrt.plymouth.bak
  ci_install_edited "$PLYMOUTH_BGRT_CONF" bgrt_rootfs_theme
fi

if [[ -f "$UBUNTU_TEXT_PLYMOUTH" ]]; then
  backup_file "$UBUNTU_TEXT_PLYMOUTH" ubuntu-text.plymouth.bak
  TEXT_TITLE="$(ci_text_splash_title)"
  ci_plymouth_text_theme "$UBUNTU_TEXT_PLYMOUTH" "$TEXT_TITLE"
  # plymouth-theme-ubuntu-text's postinst writes ubuntu-text.plymouth from its template ubuntu-text.plymouth.in, and its
  # sed changes only a title that starts "Ubuntu ", so a template that is already ours comes out as it went in.
  if [[ -f "$UBUNTU_TEXT_TEMPLATE" ]]; then
    ci_plymouth_text_theme "$STEP_TMP/ubuntu-text.plymouth.in" "$TEXT_TITLE"
    ci_install_file "$STEP_TMP/ubuntu-text.plymouth.in" "$UBUNTU_TEXT_TEMPLATE"
  fi
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
