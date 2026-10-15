#!/usr/bin/env bash
# Rebrand a GNOME Shell theme's compiled gresource: extract, swap widget/logo
# SVGs, recolor accent hexes via a caller-supplied Perl substitution file, and
# recompile. Distro-portable mechanic — the source theme (Yaru on Ubuntu/Mint,
# Adwaita on Fedora, ...) and its color-remap table are caller-supplied data,
# not hardcoded here. See docs/architecture/multi-distro-design.md.
#
# Promoted from backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh,
# which originally hardcoded "Yaru" and a Yaru-specific color table together
# in one script. Ubuntu's script is now a thin caller passing THEME_NAME=Yaru
# and its own color-map file; Fedora's does the same with THEME_NAME=Adwaita.
#
# Usage (all via env vars, matching the original script's convention):
#   THEME_NAME=Yaru \
#   COLOR_MAP_FILE=/path/to/yaru-color-map.pl \
#   ACCENT_PRIMARY=#c5e8dc ACCENT_SECONDARY=#0a6358 \
#   ACCENT_PRIMARY_RGB=197,232,220 ACCENT_SECONDARY_RGB=10,99,88 \
#   OUTPUT_GRESOURCE=/path/to/output.gresource \
#   THEME_ASSETS_DIR="/path/to/package theme assets" \
#   LOGO_BANNER_FILE=/path/to/logo-banner.svg \
#   core/render/render-gnome-shell-gresource.sh
#
# COLOR_MAP_FILE is a Perl snippet (just the body of s/.../.../g; substitution
# lines — see backends/ubuntu/iso/scripts/yaru-color-map.pl for the reference
# example) run inside a single-quoted `perl -0pi -e` invocation here, so it
# can reference $ENV{ACCENT_PRIMARY} etc. but must NOT assume any other
# variable interpolation — the file is interpolated by Perl, not by this
# shell script.
set -euo pipefail

: "${THEME_NAME:?THEME_NAME is required (e.g. Yaru, Adwaita)}"
: "${COLOR_MAP_FILE:?COLOR_MAP_FILE is required — path to a Perl substitution snippet}"
: "${OUTPUT_GRESOURCE:?OUTPUT_GRESOURCE is required}"
: "${THEME_ASSETS_DIR:?THEME_ASSETS_DIR is required}"
: "${LOGO_BANNER_FILE:?LOGO_BANNER_FILE is required}"
: "${ACCENT_PRIMARY:?ACCENT_PRIMARY is required}"
: "${ACCENT_SECONDARY:?ACCENT_SECONDARY is required}"
: "${ACCENT_PRIMARY_RGB:?ACCENT_PRIMARY_RGB is required}"
: "${ACCENT_SECONDARY_RGB:?ACCENT_SECONDARY_RGB is required}"

SOURCE_GRESOURCE="${SOURCE_GRESOURCE:-/usr/share/gnome-shell/theme/${THEME_NAME}/gnome-shell-theme.gresource}"
SOURCE_XML="${SOURCE_XML:-/usr/share/gnome-shell/theme/${THEME_NAME}/gnome-shell-theme.gresource.xml}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[ERROR] Missing command: $1"
        exit 1
    fi
}

require_cmd gresource
require_cmd glib-compile-resources
require_cmd perl

if [[ ! -f "$SOURCE_GRESOURCE" ]]; then
    echo "[ERROR] Source gresource not found: $SOURCE_GRESOURCE"
    echo "[HINT] Install the ${THEME_NAME} GNOME Shell theme package on the build host first."
    exit 1
fi

if [[ ! -f "$COLOR_MAP_FILE" ]]; then
    echo "[ERROR] COLOR_MAP_FILE not found: $COLOR_MAP_FILE"
    exit 1
fi

if [[ ! -f "$SOURCE_XML" ]]; then
    echo "[*] SOURCE_XML not found on disk; auto-generating from gresource binary..."
    _gen_xml="$(mktemp --suffix=.xml)"
    THEME_NAME="$THEME_NAME" python3 - "$SOURCE_GRESOURCE" "$_gen_xml" <<'PYEOF'
import os, subprocess, sys
from collections import defaultdict

src, out = sys.argv[1], sys.argv[2]
theme_name = os.environ["THEME_NAME"]
paths = subprocess.run(['gresource', 'list', src], capture_output=True, text=True, check=True).stdout.strip().splitlines()

# Two known prefixes – order matters (deeper prefix first)
PREFIXES = [f'/org/gnome/shell/theme/{theme_name}', '/org/gnome/shell/theme']
groups = defaultdict(list)
for p in paths:
    for prefix in PREFIXES:
        if p.startswith(prefix + '/'):
            groups[prefix].append(p[len(prefix)+1:])
            break

lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<gresources>']
for prefix in PREFIXES:
    if not groups[prefix]:
        continue
    lines.append(f'  <gresource prefix="{prefix}">')
    for f in sorted(groups[prefix]):
        lines.append(f'    <file>{f}</file>')
    lines.append('  </gresource>')
lines.append('</gresources>')
open(out, 'w').write('\n'.join(lines) + '\n')
print(f"[*] Generated XML: {len(paths)} resources across {len(groups)} prefixes")
PYEOF
    SOURCE_XML="$_gen_xml"
fi

for required_asset in \
    checkbox-focused-light.svg \
    checkbox-light.svg \
    checkbox-off-focused-light.svg \
    toggle-on-light.svg; do
    if [[ ! -f "$THEME_ASSETS_DIR/$required_asset" ]]; then
        echo "[ERROR] Missing required asset: $THEME_ASSETS_DIR/$required_asset"
        exit 1
    fi
done

if [[ ! -f "$LOGO_BANNER_FILE" ]]; then
    echo "[ERROR] Missing logo banner file: $LOGO_BANNER_FILE"
    exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

work_theme_dir="$tmp_dir/theme"
mkdir -p "$work_theme_dir"

echo "[*] Extracting ${THEME_NAME} gresource (all resources)..."
while IFS= read -r resource_path; do
    # Strip the deeper prefix first, then the shallower one
    if [[ "$resource_path" == "/org/gnome/shell/theme/${THEME_NAME}/"* ]]; then
        relative_path="${resource_path#/org/gnome/shell/theme/${THEME_NAME}/}"
    else
        relative_path="${resource_path#/org/gnome/shell/theme/}"
    fi
    target_path="$work_theme_dir/$relative_path"
    mkdir -p "$(dirname "$target_path")"
    gresource extract "$SOURCE_GRESOURCE" "$resource_path" > "$target_path"
done < <(gresource list "$SOURCE_GRESOURCE")

echo "[*] Copying upstream gresource XML..."
cp "$SOURCE_XML" "$work_theme_dir/gnome-shell-theme.gresource.xml"

replace_asset_by_name() {
    local asset_name="$1"
    local source_asset="$THEME_ASSETS_DIR/$asset_name"
    local replaced_count=0

    while IFS= read -r matched; do
        cp "$source_asset" "$matched"
        replaced_count=$((replaced_count + 1))
    done < <(find "$work_theme_dir" -type f -name "$asset_name")

    if [[ "$replaced_count" -eq 0 ]]; then
        echo "[WARN] No ${THEME_NAME} resource named $asset_name found in gresource contents"
    else
        echo "[+] Replaced $asset_name ($replaced_count file(s))"
    fi
}

echo "[*] Replacing targeted ${THEME_NAME} widget assets..."
replace_asset_by_name checkbox-focused-light.svg
replace_asset_by_name checkbox-light.svg
replace_asset_by_name checkbox-off-focused-light.svg
replace_asset_by_name toggle-on-light.svg

echo "[*] Replacing upstream-distro logo SVG files with the CI logo..."
logo_replaced=0

# a) Replace ALL SVG files whose filename contains 'ubuntu' (case-insensitive).
#    A no-op on themes with no Ubuntu-sourced assets (e.g. Adwaita) — harmless,
#    kept as a defensive catch-all rather than made theme-conditional, since
#    (b)/(c)/(d) below already cover the generic, theme-agnostic resource names.
while IFS= read -r ubuntu_svg; do
    cp "$LOGO_BANNER_FILE" "$ubuntu_svg"
    echo "[+] Replaced (ubuntu filename): $ubuntu_svg"
    logo_replaced=$((logo_replaced + 1))
done < <(find "$work_theme_dir" -type f -iname '*ubuntu*.svg' || true)

# b) Replace logo.svg and logo-text.svg if they exist
for logo_name in logo.svg logo-text.svg; do
    while IFS= read -r logo_file; do
        cp "$LOGO_BANNER_FILE" "$logo_file"
        echo "[+] Replaced (logo file): $logo_file"
        logo_replaced=$((logo_replaced + 1))
    done < <(find "$work_theme_dir" -type f -name "$logo_name" || true)
done

# c) Replace symbolic banner/logo/wallpaper SVGs (original logic kept)
while IFS= read -r symbolic_asset; do
    cp "$LOGO_BANNER_FILE" "$symbolic_asset"
    echo "[+] Replaced (symbolic): $symbolic_asset"
    logo_replaced=$((logo_replaced + 1))
done < <(find "$work_theme_dir" -type f -name '*symbolic*.svg' | grep -E '/(banner|logo|wallpaper)[^/]*symbolic[^/]*\.svg$' || true)

echo "[+] Total logo/banner replacements: $logo_replaced"

# d) Replace gnome-shell-start.svg (Activities button / distro logo) — a
#    theme-agnostic GNOME Shell resource name, not Ubuntu-specific; every
#    GNOME Shell theme ships one.
if [[ -f "$work_theme_dir/gnome-shell-start.svg" ]]; then
    cp "$LOGO_BANNER_FILE" "$work_theme_dir/gnome-shell-start.svg"
    echo "[+] Replaced gnome-shell-start.svg (Activities button logo)"
fi

echo "[*] Applying accent color remapping in CSS from $COLOR_MAP_FILE..."
while IFS= read -r css_file; do
    ACCENT_PRIMARY="$ACCENT_PRIMARY" ACCENT_SECONDARY="$ACCENT_SECONDARY" \
    ACCENT_PRIMARY_RGB="$ACCENT_PRIMARY_RGB" ACCENT_SECONDARY_RGB="$ACCENT_SECONDARY_RGB" \
    perl -0pi -e "$(cat "$COLOR_MAP_FILE")" "$css_file"
done < <(find "$work_theme_dir" -type f \( -name '*.css' -o -name '*.scss' \))

# Optional regression guard: AUDIT_PATTERNS_FILE, if set, is a file of
# grep -E patterns (one per line, blank lines/# comments ignored) checked
# against the DEFAULT + GDM CSS specifically (the alternate variant CSS files
# like bark/magenta/sage — or Adwaita's own dark/hc variants — have their own
# palettes intentionally left alone, since they're never active by default).
# Point this at a source-theme-specific list of patterns that should no
# longer appear post-substitution (both the original upstream colors and the
# retired/superseded token values), the same regression-guard role
# yaru-color-map.pl's caller applies for Ubuntu.
if [[ -n "${AUDIT_PATTERNS_FILE:-}" ]] && [[ -f "$AUDIT_PATTERNS_FILE" ]]; then
    echo "[*] Auditing default + GDM CSS for remaining pre-rebrand colors..."
    audit_files=(
        "$work_theme_dir/gnome-shell.css"
        "$work_theme_dir/gnome-shell-dark.css"
        "$work_theme_dir/gdm.css"
    )
    audit_found=0
    while IFS= read -r pat; do
        # Comment lines use "## " (not a bare "#") since the patterns
        # themselves are hex-color regexes that legitimately start with "#".
        [[ -z "$pat" || "$pat" == "## "* ]] && continue
        for afile in "${audit_files[@]}"; do
            [[ -f "$afile" ]] || continue
            while IFS= read -r hit; do
                echo "[AUDIT] Remaining pre-rebrand color match: $hit"
                audit_found=$((audit_found + 1))
            done < <(grep -n -E "$pat" "$afile" 2>/dev/null || true)
        done
    done < "$AUDIT_PATTERNS_FILE"
    if [[ "$audit_found" -eq 0 ]]; then
        echo "[+] Audit clean — no remaining pre-rebrand colors found in CSS"
    else
        echo "[WARN] $audit_found remaining pre-rebrand color occurrence(s) found (see [AUDIT] lines above)"
    fi
fi

echo "[*] Compiling branded gresource..."
mkdir -p "$(dirname "$OUTPUT_GRESOURCE")"
glib-compile-resources \
    --target="$OUTPUT_GRESOURCE" \
    --sourcedir="$work_theme_dir" \
    "$work_theme_dir/gnome-shell-theme.gresource.xml"

echo "[+] Branded gresource built: $OUTPUT_GRESOURCE"
