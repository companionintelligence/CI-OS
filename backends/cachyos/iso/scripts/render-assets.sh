#!/usr/bin/env bash
#=============================================================================
# Render the Companion OS brand assets of the CachyOS edition into a STAGING TREE that the overlay engine
# (in-container/apply-overlay.sh) merges over the profile after overlay/files. Everything here comes from the canon
# (vendor/brand tokens and marks, core/render/*, core/lib/theme-lib.sh) and is generated at build time: nothing this script
# writes is committed, and no CachyOS or Arch artwork is read or copied (decision D9).
#
#   CI_OS_STAGING_DIR=<dir> backends/cachyos/iso/scripts/render-assets.sh [--no-installed]
#
# The staging tree has the shape of overlay/files (so <dir>/airootfs/..., <dir>/grub/..., <dir>/syslinux/...). Files:
#
#   Live medium
#     grub/theme/                              GRUB theme of the UEFI menu: theme.txt, background.png (the mark in the upper
#                                              third), select_c.png. The patched grub.cfg sets it with `set theme`; the
#                                              theme keeps the picture's aspect ratio at any screen shape (crop), where
#                                              background_image would squash the mark on a 4:3 screen
#     grub/splash.png                          the same navy ground with the mark in the middle, 1920x1080: the menu's
#                                              background_image when the theme cannot load (replaces upstream's CachyOS
#                                              artwork of the same name)
#     grub/companion-os-theme.cfg              menu_color_normal / menu_color_highlight, from the tokens (the patched
#                                              grub.cfg sources it; the text menu's colours, used when the theme cannot load)
#     syslinux/splash.png                      BIOS menu background, 640x480 (the 1920x1080 file upstream ships does not
#                                              render under vesamenu), the mark above the menu box
#     syslinux/companion_colors.cfg            the MENU COLOR lines, from the tokens (the patched archiso_head.cfg INCLUDEs it)
#     airootfs/usr/share/wallpapers/companion/ Plasma wallpaper package: 1920x1080 and 3840x2160 JPEGs (16:9 crop of the
#                                              canon background), metadata.json, a preview
#     airootfs/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg    os-release LOGO=, the start button, About This System
#     airootfs/usr/share/color-schemes/CI-OS-Dark.colors               the shared KDE colour scheme
#     airootfs/etc/xdg/kcm-about-distrorc      About This System: logo and version
#     airootfs/usr/share/ci-os/release         version, build day and console colour that zz-ci-os-os-release writes into
#                                              /etc/os-release
#   Installed system (skipped with --no-installed; copied over by /usr/share/ci-os/installed/carry-over)
#     airootfs/usr/share/grub/themes/companion-os/       the same GRUB theme (theme.txt, background.png, select_c.png)
#     airootfs/usr/share/plymouth/themes/companion-os/   Plymouth theme: the stock spinner theme's animation, recoloured
#                                                        with ci_plymouth_recolor, our watermark; needs the plymouth package
#
# Environment
#   CI_OS_STAGING_DIR            (required) where to write. Anything already in it is replaced file by file.
#   CI_OS_REPO_ROOT              the repository (or the subset the container holds: backends/cachyos core vendor); default: this checkout
#   CI_OS_VERSION                Companion OS version for the stamp; default: the day of SOURCE_DATE_EPOCH (YYYY.MM.DD)
#   CI_OS_BUILD_DAY              YYYYMMDD build stamp; default: the day of SOURCE_DATE_EPOCH, else today
#   SOURCE_DATE_EPOCH            see above; the images themselves do not depend on it
#   CI_OS_PLYMOUTH_SPINNER_DIR   the stock spinner theme to start the Plymouth theme from; default /usr/share/plymouth/themes/spinner
#   CI_OS_COLOR_SCHEME           the KDE colour scheme to ship; default backends/_mixins/kde-plasma/CI-OS-Dark.colors under the repo
#
# Needs ImageMagick (magick or convert); librsvg's rsvg-convert is used when present (core/render/* decide). Exits non-zero
# with a message, so that the build stops before it merges a half-written tree, when a source asset or a tool is missing.
# Output is deterministic: two runs with the same inputs give byte-identical files.
# Runs on bash 3.2 (a stock macOS) for everything except the Plymouth theme, whose recolouring needs GNU sed.
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================
set -euo pipefail
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CI_OS_REPO_ROOT:-$(cd "$HERE/../../../.." && pwd)}"
export REPO_ROOT

WITH_INSTALLED=1
case "${1:-}" in
  --no-installed) WITH_INSTALLED=0 ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//' -e '/^====*$/d'; exit 0 ;;
  '') ;;
  *) echo "render-assets.sh: unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac

[[ -n "${CI_OS_STAGING_DIR:-}" ]] || { echo "render-assets.sh: CI_OS_STAGING_DIR is not set" >&2; exit 2; }
mkdir -p "$CI_OS_STAGING_DIR"
OUT="$(cd "$CI_OS_STAGING_DIR" && pwd)"

[[ -f "$REPO_ROOT/core/lib/theme-lib.sh" ]] || { echo "render-assets.sh: $REPO_ROOT has no core/lib/theme-lib.sh (CI_OS_REPO_ROOT wrong?)" >&2; exit 2; }
# shellcheck source=../../../../core/lib/theme-lib.sh
source "$REPO_ROOT/core/lib/theme-lib.sh"
# shellcheck source=../../../../core/lib/grub-merge.sh
source "$REPO_ROOT/core/lib/grub-merge.sh"

die() { log_error "render-assets: $*"; exit 1; }

# --- inputs: every one must exist ---------------------------------------------------------------------------------------
MARK_SVG="$REPO_ROOT/vendor/brand/logos/mark.svg"
BACKGROUND_PNG="$REPO_ROOT/core/render/inputs/background.png"
BANNER_PNG="$REPO_ROOT/core/render/inputs/Logo_Banner_Color.png"
RENDER_GRUB_BG="$REPO_ROOT/core/render/render-grub-background.sh"
RENDER_MARK="$REPO_ROOT/core/render/render-mark-png.sh"
COLOR_SCHEME="${CI_OS_COLOR_SCHEME:-$REPO_ROOT/backends/_mixins/kde-plasma/CI-OS-Dark.colors}"
SPINNER_DIR="${CI_OS_PLYMOUTH_SPINNER_DIR:-/usr/share/plymouth/themes/spinner}"

for f in "$MARK_SVG" "$BACKGROUND_PNG" "$BANNER_PNG" "$RENDER_GRUB_BG" "$RENDER_MARK"; do
  [[ -f "$f" ]] || die "source asset missing: $f"
done
[[ -f "$COLOR_SCHEME" ]] || die "the KDE colour scheme is missing: $COLOR_SCHEME (it lives in backends/_mixins/kde-plasma/; the build container's copy of the repo must include backends/_mixins, or set CI_OS_COLOR_SCHEME)"

if command -v magick >/dev/null 2>&1; then IM=(magick)
elif command -v convert >/dev/null 2>&1; then IM=(convert)
else die "ImageMagick (magick or convert) not found; install imagemagick (and librsvg for rsvg-convert)"
fi
if command -v magick >/dev/null 2>&1; then IDENTIFY=(magick identify); else IDENTIFY=(identify); fi

# Release stamp -----------------------------------------------------------------------------------------------------------
fmt_epoch() { # fmt_epoch <epoch|now> <strftime format>: GNU date first, BSD date second
  local e="$1" f="$2"
  if [[ "$e" == now ]]; then date -u +"$f"; else date -u -d "@$e" +"$f" 2>/dev/null || date -u -r "$e" +"$f"; fi
}
EPOCH="${SOURCE_DATE_EPOCH:-now}"
VERSION="${CI_OS_VERSION:-$(fmt_epoch "$EPOCH" %Y.%m.%d)}"
BUILD_DAY="${CI_OS_BUILD_DAY:-$(fmt_epoch "$EPOCH" %Y%m%d)}"
[[ "$VERSION" =~ ^[0-9A-Za-z._+~-]{1,32}$ ]] || die "CI_OS_VERSION '$VERSION' has characters outside [0-9A-Za-z._+~-] or is longer than 32"
[[ "$BUILD_DAY" =~ ^[0-9]{8}$ ]] || die "CI_OS_BUILD_DAY '$BUILD_DAY' is not YYYYMMDD"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-render-assets.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Canon colours, in the forms the targets want ---------------------------------------------------------------------------
GRUB_NORMAL="$(ci_grub_nearest_color "$CI_DARK_FOREGROUND")/black"
GRUB_HIGHLIGHT="black/$(ci_grub_nearest_color "$CI_ACCENT_AQUA")"
ANSI_COLOR="38;2;$(ci_rgb "$CI_DARK_PRIMARY" | tr ' ' ';')"
# syslinux wants #AARRGGBB
argb() { printf '#%s%s' "$1" "${2#\#}"; }

# --- helpers -------------------------------------------------------------------------------------------------------------
put_dir() { mkdir -p "$OUT/$1"; }

# normalize <in.png> <out.png>: plain 8-bit RGB, no metadata (no timestamps), so equal inputs give equal bytes.
normalize() { "${IM[@]}" "$1" -strip -depth 8 "PNG24:$2"; }

# dims <png>: "WxH" of the image
dims() { "${IDENTIFY[@]}" -format '%wx%h' "$1"; }

# Assets -----------------------------------------------------------------------------------------------------------------

render_boot_backgrounds() {
  log_info "GRUB (1920x1080) and syslinux (640x480) backgrounds..."
  put_dir grub; put_dir syslinux
  # GRUB's fallback background: the canon navy ground with the mark in the middle (core/render/render-grub-background.sh).
  bash "$RENDER_GRUB_BG" "$WORK/grub.png" 1920 1080 >/dev/null
  normalize "$WORK/grub.png" "$OUT/grub/splash.png"
  [[ "$(dims "$OUT/grub/splash.png")" == 1920x1080 ]] || die "GRUB background is not 1920x1080"
  # syslinux: vesamenu puts its box in the lower two thirds of a 640x480 screen, so the mark goes above it. The mark is
  # drawn by core/render/render-mark-png.sh (colour mark, transparent ground) and laid on the navy canvas.
  bash "$RENDER_MARK" "$WORK/mark-112.png" 112 >/dev/null
  "${IM[@]}" -size 640x480 "xc:$CI_DARK_BACKGROUND" "$WORK/mark-112.png" -gravity north -geometry +0+34 -composite "$WORK/syslinux.png"
  normalize "$WORK/syslinux.png" "$OUT/syslinux/splash.png"
  [[ "$(dims "$OUT/syslinux/splash.png")" == 640x480 ]] || die "syslinux background is not 640x480"
}

# render_grub_theme <dir relative to the staging tree>: the GRUB theme, used by the live menu (grub/theme) and by the
# installed system (/usr/share/grub/themes/companion-os).
render_grub_theme() {
  local dir="$1"
  put_dir "$dir"
  # Navy ground, the mark in the upper third; the menu box sits below it (theme.txt).
  bash "$RENDER_MARK" "$WORK/mark-216.png" 216 >/dev/null
  "${IM[@]}" -size 1920x1080 "xc:$CI_DARK_BACKGROUND" "$WORK/mark-216.png" -gravity north -geometry +0+150 -composite "$WORK/theme-bg.png"
  normalize "$WORK/theme-bg.png" "$OUT/$dir/background.png"
  [[ "$(dims "$OUT/$dir/background.png")" == 1920x1080 ]] || die "GRUB theme background is not 1920x1080"
  # The highlight bar of the menu: one solid tile in the canon accent, which GRUB stretches (select_c is the centre).
  "${IM[@]}" -size 8x8 "xc:$CI_ACCENT_AQUA" -strip -depth 8 "PNG24:$OUT/$dir/select_c.png"
  # Unifont Regular 16 is the font in GRUB's own unicode.pf2, which both the live and the installed grub.cfg load.
  cat > "$OUT/$dir/theme.txt" <<EOF
# Companion OS GRUB theme. Generated by render-assets.sh at image build time from the canon tokens; do not edit.
desktop-image: "background.png"
desktop-image-scale-method: "crop"
desktop-image-h-align: "center"
desktop-image-v-align: "center"
desktop-color: "$CI_DARK_BACKGROUND"
title-text: ""
terminal-font: "Unifont Regular 16"

+ boot_menu {
  left = 25%
  top = 46%
  width = 50%
  height = 40%
  item_font = "Unifont Regular 16"
  item_color = "$CI_DARK_FOREGROUND"
  selected_item_font = "Unifont Regular 16"
  selected_item_color = "$CI_DARK_BACKGROUND"
  item_height = 30
  item_padding = 8
  item_spacing = 4
  selected_item_pixmap_style = "select_*.png"
}

+ label {
  id = "__timeout__"
  top = 90%
  left = 0
  width = 100%
  align = "center"
  font = "Unifont Regular 16"
  color = "$CI_DARK_MUTED_FOREGROUND"
  text = "Starting in %d seconds"
}
EOF
}

write_boot_colors() {
  log_info "boot menu colours from the tokens..."
  cat > "$OUT/grub/companion-os-theme.cfg" <<EOF
# Companion OS UEFI menu colours. Generated by render-assets.sh at image build time from the canon tokens
# (vendor/brand/tokens/tokens.sh, nearest of GRUB's 16 terminal colours); do not edit. Sourced by grub.cfg.
set menu_color_normal=$GRUB_NORMAL
set menu_color_highlight=$GRUB_HIGHLIGHT
EOF
  local ground="$CI_DARK_BACKGROUND"
  cat > "$OUT/syslinux/companion_colors.cfg" <<EOF
# Companion OS BIOS menu colours. Generated by render-assets.sh at image build time from the canon tokens
# (vendor/brand/tokens/tokens.sh); do not edit. INCLUDEd by archiso_head.cfg. Colours are #AARRGGBB; the ANSI column is
# only used by the plain text console and keeps upstream's values.
MENU COLOR border       30;44   $(argb c0 "$CI_ACCENT_TEAL_MID") $(argb a0 "$ground") std
MENU COLOR title        1;36;44 $(argb ff "$CI_DARK_PRIMARY") $(argb a0 "$ground") std
MENU COLOR sel          7;37;40 $(argb ff "$ground") $(argb ff "$CI_ACCENT_AQUA") all
MENU COLOR unsel        37;44   $(argb ff "$CI_DARK_FOREGROUND") $(argb a0 "$ground") std
MENU COLOR help         37;40   $(argb ff "$CI_DARK_MUTED_FOREGROUND") $(argb a0 "$ground") std
MENU COLOR timeout_msg  37;40   $(argb c0 "$CI_DARK_MUTED_FOREGROUND") $(argb 00 "$ground") std
MENU COLOR timeout      1;37;40 $(argb ff "$CI_DARK_PRIMARY") $(argb 00 "$ground") std
MENU COLOR msg07        37;40   $(argb ff "$CI_DARK_FOREGROUND") $(argb a0 "$ground") std
MENU COLOR tabmsg       31;40   $(argb ff "$CI_DARK_MUTED_FOREGROUND") $(argb 00 "$ground") std
EOF
}

render_wallpaper() {
  log_info "wallpaper package (16:9 crop of the canon background)..."
  local dir="airootfs/usr/share/wallpapers/companion"
  put_dir "$dir/contents/images"
  # The canon background is 3:2 (1536x1024): crop the middle 16:9 band, then scale to each size.
  "${IM[@]}" "$BACKGROUND_PNG" -gravity center -crop 1536x864+0+0 +repage "$WORK/wall16x9.png"
  # JPEG, not PNG: the canon background carries film grain, which a PNG of 3840x2160 keeps at 9 MB and a JPEG at q92
  # (4:4:4, so no colour fringes) keeps at under 3. Plasma takes any image type in contents/images/.
  "${IM[@]}" "$WORK/wall16x9.png" -filter Lanczos -resize '1920x1080!' -strip -sampling-factor 4:4:4 -quality 92 "JPEG:$OUT/$dir/contents/images/1920x1080.jpg"
  "${IM[@]}" "$WORK/wall16x9.png" -filter Lanczos -resize '3840x2160!' -strip -sampling-factor 4:4:4 -quality 92 "JPEG:$OUT/$dir/contents/images/3840x2160.jpg"
  "${IM[@]}" "$WORK/wall16x9.png" -filter Lanczos -resize '480x270!' -strip -depth 8 "PNG24:$OUT/$dir/contents/screenshot.png"
  cat > "$OUT/$dir/metadata.json" <<'EOF'
{
    "KPackageStructure": "Wallpaper/Images",
    "KPlugin": {
        "Authors": [
            {
                "Name": "Companion Intelligence"
            }
        ],
        "Id": "companion",
        "License": "Proprietary",
        "Name": "Companion OS"
    }
}
EOF
  [[ "$(dims "$OUT/$dir/contents/images/1920x1080.jpg")" == 1920x1080 ]] || die "wallpaper 1920x1080 has the wrong size"
  [[ "$(dims "$OUT/$dir/contents/images/3840x2160.jpg")" == 3840x2160 ]] || die "wallpaper 3840x2160 has the wrong size"
}

install_desktop_files() {
  log_info "icon, colour scheme, About This System, release stamp..."
  put_dir airootfs/usr/share/icons/hicolor/scalable/apps
  cp "$MARK_SVG" "$OUT/airootfs/usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
  put_dir airootfs/usr/share/color-schemes
  cp "$COLOR_SCHEME" "$OUT/airootfs/usr/share/color-schemes/CI-OS-Dark.colors"
  put_dir airootfs/etc/xdg
  cat > "$OUT/airootfs/etc/xdg/kcm-about-distrorc" <<EOF
# Companion OS: Settings > About This System. Name, variant and website come from /etc/os-release.
# Generated by render-assets.sh at image build time.
[General]
LogoPath=ci-os-logo
Version=$VERSION
EOF
  put_dir airootfs/usr/share/ci-os
  cat > "$OUT/airootfs/usr/share/ci-os/release" <<EOF
# Companion OS release stamp. Generated by render-assets.sh at image build time; read by
# /usr/share/libalpm/scripts/zz-ci-os-os-release, which writes it into /etc/os-release. The colour is the canon's
# CI_DARK_PRIMARY as an ANSI truecolor sequence.
CI_OS_VERSION="$VERSION"
CI_OS_BUILD="$BUILD_DAY"
CI_OS_ANSI_COLOR="$ANSI_COLOR"
EOF
}

render_plymouth_theme() {
  log_info "Plymouth theme for the installed system (from $SPINNER_DIR)..."
  [[ -f "$SPINNER_DIR/spinner.plymouth" ]] || die "the stock Plymouth spinner theme is missing: $SPINNER_DIR/spinner.plymouth (install the plymouth package, see render-deps.txt, or set CI_OS_PLYMOUTH_SPINNER_DIR; --no-installed skips this)"
  sed --version >/dev/null 2>&1 || die "ci_plymouth_recolor needs GNU sed; run the installed-system part in the build container (or use --no-installed)"
  local dir="airootfs/usr/share/plymouth/themes/companion-os" theme f
  put_dir "$dir"
  # The animation, dialog and keyboard images of the stock spinner theme are generic (a spinner, a lock, a keyboard); what
  # carries a distribution is the watermark, which is replaced, and the theme's name and description.
  for f in "$SPINNER_DIR"/*.png; do
    [[ "$(basename "$f")" == watermark.png ]] && continue
    cp "$f" "$OUT/$dir/"
  done
  theme="$OUT/$dir/companion-os.plymouth"
  # The localised Name[xx]= lines name the stock theme in 60 languages; drop them, write our own header.
  sed -e '/^Name\[/d' -e 's|^Name=.*|Name=Companion OS|' -e 's|^Description=.*|Description=Companion OS boot splash|' \
      -e 's|^ImageDir=.*|ImageDir=/usr/share/plymouth/themes/companion-os|' "$SPINNER_DIR/spinner.plymouth" > "$theme"
  ci_plymouth_recolor "$theme"
  grep -q '^ModuleName=two-step' "$theme" || die "the stock spinner theme does not use the two-step module; its file layout changed, review render_plymouth_theme"
  # The same watermark the Ubuntu edition uses (the lockup, 50%), on the canon navy ground the recolour sets.
  "${IM[@]}" "$BANNER_PNG" -resize 50% -strip -depth 8 "PNG32:$OUT/$dir/watermark.png"
  if grep -qiE 'cachy|arch ?linux' "$theme"; then die "$theme still names the base distribution; review render_plymouth_theme"; fi
  [[ -s "$OUT/$dir/watermark.png" ]] || die "Plymouth watermark is empty"
}

render_boot_backgrounds
log_info "GRUB theme for the live menu..."
render_grub_theme grub/theme
write_boot_colors
render_wallpaper
install_desktop_files
if [[ "$WITH_INSTALLED" -eq 1 ]]; then
  log_info "GRUB theme for the installed system..."
  render_grub_theme airootfs/usr/share/grub/themes/companion-os
  render_plymouth_theme
else
  log_warn "--no-installed: the GRUB and Plymouth themes of the installed system are not rendered"
fi

# Nothing in the tree may be executable (the engine requires a file_permissions entry for every executable) or empty.
bad="$(find "$OUT" -type f -perm -100)"
[[ -z "$bad" ]] || die "unexpected executable file(s): $bad"
bad="$(find "$OUT" -type f -size 0)"
[[ -z "$bad" ]] || die "empty file(s) written: $bad"
log_success "brand assets rendered into $OUT ($(find "$OUT" -type f | wc -l | tr -d ' ') files, version $VERSION, build $BUILD_DAY)"
