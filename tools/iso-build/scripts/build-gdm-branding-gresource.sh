#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SOURCE_GRESOURCE="${SOURCE_GRESOURCE:-/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource}"
SOURCE_XML="${SOURCE_XML:-/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource.xml}"
OUTPUT_GRESOURCE="${OUTPUT_GRESOURCE:-$REPO_ROOT/packages/ci-os-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource}"

THEME_ASSETS_DIR="${THEME_ASSETS_DIR:-$REPO_ROOT/assets/package theme assets}"
LOGO_BANNER_FILE="${LOGO_BANNER_FILE:-$REPO_ROOT/assets/logos/2024_CI__Logo_Banner_Color_small.svg}"

ACCENT_PRIMARY="#00a9a7"
ACCENT_SECONDARY="#066c80"

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
    echo "[HINT] Install yaru-theme-gnome-shell on the build host first."
    exit 1
fi

if [[ ! -f "$SOURCE_XML" ]]; then
    echo "[*] SOURCE_XML not found on disk; auto-generating from gresource binary..."
    _gen_xml="$(mktemp --suffix=.xml)"
    python3 - "$SOURCE_GRESOURCE" "$_gen_xml" <<'PYEOF'
import subprocess, sys
from collections import defaultdict

src, out = sys.argv[1], sys.argv[2]
paths = subprocess.run(['gresource', 'list', src], capture_output=True, text=True, check=True).stdout.strip().splitlines()

# Two known prefixes – order matters (deeper prefix first)
PREFIXES = ['/org/gnome/shell/theme/Yaru', '/org/gnome/shell/theme']
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

echo "[*] Extracting Yaru gresource (all resources)..."
while IFS= read -r resource_path; do
    # Strip the deeper prefix first, then the shallower one
    if [[ "$resource_path" == /org/gnome/shell/theme/Yaru/* ]]; then
        relative_path="${resource_path#/org/gnome/shell/theme/Yaru/}"
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
        echo "[WARN] No Yaru resource named $asset_name found in gresource contents"
    else
        echo "[+] Replaced $asset_name ($replaced_count file(s))"
    fi
}

echo "[*] Replacing targeted Yaru assets..."
replace_asset_by_name checkbox-focused-light.svg
replace_asset_by_name checkbox-light.svg
replace_asset_by_name checkbox-off-focused-light.svg
replace_asset_by_name toggle-on-light.svg

echo "[*] Replacing Ubuntu logo SVG files with CI logo..."
logo_replaced=0

# a) Replace ALL SVG files whose filename contains 'ubuntu' (case-insensitive)
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

# d) Replace gnome-shell-start.svg (Activities button / Ubuntu logo)
#    This file contains the Ubuntu Circle of Friends logo but its filename
#    does NOT contain 'ubuntu', so the above patterns miss it.
if [[ -f "$work_theme_dir/gnome-shell-start.svg" ]]; then
    cp "$LOGO_BANNER_FILE" "$work_theme_dir/gnome-shell-start.svg"
    echo "[+] Replaced gnome-shell-start.svg (Activities button logo)"
fi

echo "[*] Applying comprehensive accent color remapping in CSS..."
# ──────────────────────────────────────────────────────────────────────────────
# Yaru's default theme uses a wide palette of orange variants, NOT just #E95420.
# We must remap ALL of them to CI-OS teal/green equivalents. The mapping
# preserves relative luminance relationships (darkest→darkest, lightest→lightest).
# ──────────────────────────────────────────────────────────────────────────────
while IFS= read -r css_file; do
    perl -0pi -e '
        # ── Yaru orange accent family (sorted dark→light) ────────────────────
        # Dark orange variants → CI-OS dark teal
        s/#be3f13/#04525e/g;  s/#BE3F13/#04525e/g;
        s/#c04013/#045260/g;  s/#C04013/#045260/g;
        s/#c14013/#045360/g;  s/#C14013/#045360/g;
        s/#c54113/#055663/g;  s/#C54113/#055663/g;
        s/#c74214/#055865/g;  s/#C74214/#055865/g;
        s/#d34615/#066c80/g;  s/#D34615/#066c80/g;   # Primary Yaru accent (24×)
        s/#da4816/#077486/g;  s/#DA4816/#077486/g;

        # Mid orange variants → CI-OS primary teal
        s/#e14b16/#08808e/g;  s/#E14B16/#08808e/g;
        s/#e54c17/#098891/g;  s/#E54C17/#098891/g;
        s/#e64c17/#098a93/g;  s/#E64C17/#098a93/g;
        s/#e84f19/#0a8e96/g;  s/#E84F19/#0a8e96/g;
        s/#E95420/#00a9a7/g;  s/#e95420/#00a9a7/g;   # Classic Ubuntu orange
        s/#e95c2a/#14b0ab/g;  s/#e95C2A/#14b0ab/g;
        s/#ea5d2c/#1ab2ad/g;  s/#EA5D2C/#1ab2ad/g;
        s/#eb6030/#20b5b0/g;  s/#EB6030/#20b5b0/g;

        # Light orange variants → CI-OS light teal
        s/#ec6b3e/#33bbb6/g;  s/#EC6B3E/#33bbb6/g;
        s/#ef845f/#55ccc8/g;  s/#EF845F/#55ccc8/g;
        s/#ef8661/#59ceca/g;  s/#EF8661/#59ceca/g;   # Most common Yaru light accent (32×)

        # ── Yaru yellow/amber warning palette → CI-OS gold-teal ──────────────
        s/#f9990c/#0ec4a8/g;  s/#F9990C/#0ec4a8/g;
        s/#f99b11/#12c5aa/g;  s/#F99B11/#12c5aa/g;
        s/#faa52a/#2dccb3/g;  s/#FAA52A/#2dccb3/g;

        # ── Yaru red accent variants → CI-OS dark teal ───────────────────────
        s/#c7162b/#044f5b/g;  s/#C7162B/#044f5b/g;
        s/#da3450/#066677/g;  s/#DA3450/#066677/g;
        s/#dc415b/#07707e/g;  s/#DC415B/#07707e/g;
        s/#dd445e/#077381/g;  s/#DD445E/#077381/g;
        s/#dd455f/#077482/g;  s/#DD455F/#077482/g;
        s/#de4a63/#087986/g;  s/#DE4A63/#087986/g;
        s/#e82d43/#0a8c94/g;  s/#E82D43/#0a8c94/g;
        s/#e15970/#099098/g;  s/#E15970/#099098/g;
        s/#e15b71/#09929a/g;  s/#E15B71/#09929a/g;
        s/#e25f75/#0a969d/g;  s/#E25F75/#0a969d/g;

        # ── Yaru aubergine/purple brand (#77216F) ────────────────────────────
        s/#77216F/#066c80/g;  s/#77216f/#066c80/g;
        s/rgb\(119\s*,\s*33\s*,\s*111\)/rgb(6, 108, 128)/g;
        s/rgba\(119\s*,\s*33\s*,\s*111\s*,\s*([0-9.]+)\)/rgba(6, 108, 128, $1)/g;

        # ── Ubuntu highlight/selection blue (#19B6EE) ────────────────────────
        s/#19B6EE/#00a9a7/g;  s/#19b6ee/#00a9a7/g;
        s/rgb\(25\s*,\s*182\s*,\s*238\)/rgb(0, 169, 167)/g;
        s/rgba\(25\s*,\s*182\s*,\s*238\s*,\s*([0-9.]+)\)/rgba(0, 169, 167, $1)/g;

        # ── Catch rgb/rgba forms of the main Ubuntu orange ───────────────────
        s/rgb\(233\s*,\s*84\s*,\s*32\)/rgb(0, 169, 167)/g;
        s/rgba\(233\s*,\s*84\s*,\s*32\s*,\s*([0-9.]+)\)/rgba(0, 169, 167, $1)/g;
        s/rgb\(211\s*,\s*70\s*,\s*21\)/rgb(6, 108, 128)/g;
        s/rgba\(211\s*,\s*70\s*,\s*21\s*,\s*([0-9.]+)\)/rgba(6, 108, 128, $1)/g;
    ' "$css_file"
done < <(find "$work_theme_dir" -type f \( -name '*.css' -o -name '*.scss' \))

# Audit: scan for remaining orange accent colors in the DEFAULT and GDM CSS only
# (the alternate variant CSS files like bark, magenta, sage have their own color
# palettes that we intentionally leave alone — they're never active by default)
echo "[*] Auditing default + GDM CSS for remaining Yaru accent colors..."
audit_patterns=(
    '#[Ee]95420'
    '#[Dd]34615'
    '#[Ee][Ff]8661'
    '#[Ee][Ff]845[Ff]'
    '#77216[Ff]'
    '#19[Bb]6[Ee][Ee]'
)
audit_files=(
    "$work_theme_dir/gnome-shell.css"
    "$work_theme_dir/gnome-shell-dark.css"
    "$work_theme_dir/gdm.css"
)
audit_found=0
for pat in "${audit_patterns[@]}"; do
    for afile in "${audit_files[@]}"; do
        [[ -f "$afile" ]] || continue
        while IFS= read -r hit; do
            echo "[AUDIT] Remaining brand color match: $hit"
            audit_found=$((audit_found + 1))
        done < <(grep -n -E "$pat" "$afile" 2>/dev/null || true)
    done
done
if [[ "$audit_found" -eq 0 ]]; then
    echo "[+] Audit clean — no remaining Ubuntu brand colors found in CSS"
else
    echo "[WARN] $audit_found remaining brand color occurrence(s) found (see [AUDIT] lines above)"
fi

echo "[*] Compiling branded gresource..."
mkdir -p "$(dirname "$OUTPUT_GRESOURCE")"
glib-compile-resources \
    --target="$OUTPUT_GRESOURCE" \
    --sourcedir="$work_theme_dir" \
    "$work_theme_dir/gnome-shell-theme.gresource.xml"

echo "[+] Branded gresource built: $OUTPUT_GRESOURCE"
