#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SOURCE_GRESOURCE="${SOURCE_GRESOURCE:-/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource}"
SOURCE_XML="${SOURCE_XML:-/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource.xml}"
OUTPUT_GRESOURCE="${OUTPUT_GRESOURCE:-$REPO_ROOT/packages/mydistro-branding/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource}"

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

echo "[*] Replacing symbolic banner/logo/wallpaper assets with CI banner..."
symbolic_replaced=0
while IFS= read -r symbolic_asset; do
    cp "$LOGO_BANNER_FILE" "$symbolic_asset"
    symbolic_replaced=$((symbolic_replaced + 1))
done < <(find "$work_theme_dir" -type f -name '*symbolic*.svg' | grep -E '/(banner|logo|wallpaper)[^/]*symbolic[^/]*\.svg$' || true)
echo "[+] Symbolic banner/logo/wallpaper replacements: $symbolic_replaced"

echo "[*] Applying accent color remapping in CSS..."
while IFS= read -r css_file; do
    perl -0pi -e 's/#E95420/'"$ACCENT_PRIMARY"'/g; s/#e95420/'"$ACCENT_PRIMARY"'/g; s/rgb\(233\s*,\s*84\s*,\s*32\)/rgb(0, 169, 167)/g; s/rgba\(233\s*,\s*84\s*,\s*32\s*,\s*([0-9.]+)\)/rgba(0, 169, 167, $1)/g; s/#77216F/'"$ACCENT_SECONDARY"'/g; s/#77216f/'"$ACCENT_SECONDARY"'/g; s/rgb\(119\s*,\s*33\s*,\s*111\)/rgb(6, 108, 128)/g; s/rgba\(119\s*,\s*33\s*,\s*111\s*,\s*([0-9.]+)\)/rgba(6, 108, 128, $1)/g;' "$css_file"
done < <(find "$work_theme_dir" -type f \( -name '*.css' -o -name '*.scss' \))

echo "[*] Compiling branded gresource..."
mkdir -p "$(dirname "$OUTPUT_GRESOURCE")"
glib-compile-resources \
    --target="$OUTPUT_GRESOURCE" \
    --sourcedir="$work_theme_dir" \
    "$work_theme_dir/gnome-shell-theme.gresource.xml"

echo "[+] Branded gresource built: $OUTPUT_GRESOURCE"
