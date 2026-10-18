#!/usr/bin/env bash
# Rebrand a GNOME Shell theme's compiled gresource: extract, swap widget/logo
# SVGs, recolor accent hexes via a caller-supplied Perl substitution file, and
# recompile. Distro-portable mechanic — the source theme (Yaru on Ubuntu)
# and its color-remap table are caller-supplied data, not hardcoded here. See docs/architecture/multi-distro-design.md.
#
# Promoted from backends/ubuntu/iso/scripts/build-gdm-branding-gresource.sh,
# which originally hardcoded "Yaru" and a Yaru-specific color table together
# in one script. Ubuntu's script is now a thin caller passing THEME_NAME=Yaru
# and its own color-map file (it is the only caller today).
#
# WHERE THE SOURCE THEME COMES FROM MATTERS. A gresource is compiled against one release of the theme: the Yaru of
# an earlier Ubuntu release has other resources than the Yaru of Ubuntu 26.04 (the blob built from the previous release's
# Yaru was 5.9 MB, the 26.04 one is 1.3 MB), and
# a blob built from the wrong one is wrong for the GNOME Shell it ships with. Before 2026-10-17 the script read the
# BUILD HOST's /usr/share/gnome-shell/theme/Yaru, whatever the host was. It now refuses a source it cannot identify as
# Ubuntu 26.04's (SOURCE_REQUIRE_OS_VERSION_ID, default 26.04) and, for Yaru, a yaru-theme-gnome-shell package that is not
# a 26.04 one (SOURCE_PACKAGE_VERSION_REGEX, default ^26\.04\.). Two ways to give it a source it can identify:
#   SOURCE_ROOTFS=/path/to/rootfs   a root filesystem (the base ISO's extracted layers, a debootstrap, a `dpkg -x` tree
#                                   with etc/os-release and var/lib/dpkg/status): the theme and the identity are read from it
#   (nothing)                       the running system: its /etc/os-release and dpkg database must say Ubuntu 26.04
# so the tracked blob can be rebuilt from the base ISO's own yaru-theme-gnome-shell files, or inside an ubuntu:26.04
# container, and not from an arbitrary host. The identity of what was used (os-release, package and version, size and sha256
# of the source) is printed in a [PROVENANCE] block and also written to PROVENANCE_FILE when that is set.
#
# Usage (all via env vars, matching the original script's convention):
#   THEME_NAME=Yaru \
#   COLOR_MAP_FILE=/path/to/yaru-color-map.pl \
#   ACCENT_PRIMARY=#c5e8dc ACCENT_SECONDARY=#0a6358 \
#   ACCENT_PRIMARY_RGB=197,232,220 ACCENT_SECONDARY_RGB=10,99,88 \
#   SOURCE_ROOTFS=/path/to/ubuntu-26.04-rootfs \
#   PROVENANCE_FILE=/path/to/provenance.txt \
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

# SOURCE_ROOTFS: where the source theme and its identity are read from; "/" (the running system) when not set.
SOURCE_ROOTFS="${SOURCE_ROOTFS:-}"
_src_root="${SOURCE_ROOTFS%/}"
SOURCE_GRESOURCE="${SOURCE_GRESOURCE:-${_src_root}/usr/share/gnome-shell/theme/${THEME_NAME}/gnome-shell-theme.gresource}"
SOURCE_XML="${SOURCE_XML:-${_src_root}/usr/share/gnome-shell/theme/${THEME_NAME}/gnome-shell-theme.gresource.xml}"
# The identity the source must have. Unset means Ubuntu 26.04 and (for Yaru) a 26.04 yaru-theme-gnome-shell; set to an
# empty string to turn a check off (then the [PROVENANCE] block says "not checked").
SOURCE_REQUIRE_OS_VERSION_ID="${SOURCE_REQUIRE_OS_VERSION_ID-26.04}"
if [[ "$THEME_NAME" == "Yaru" ]]; then
    SOURCE_PACKAGE="${SOURCE_PACKAGE-yaru-theme-gnome-shell}"
    SOURCE_PACKAGE_VERSION_REGEX="${SOURCE_PACKAGE_VERSION_REGEX-^26\\.04\\.}"
else
    SOURCE_PACKAGE="${SOURCE_PACKAGE-}"
    SOURCE_PACKAGE_VERSION_REGEX="${SOURCE_PACKAGE_VERSION_REGEX-}"
fi

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
    echo "[HINT] Install the ${THEME_NAME} GNOME Shell theme package on the build host first, or point SOURCE_ROOTFS at the base image's rootfs."
    exit 1
fi

# --- who made the source theme: refuse anything that is not what the blob is meant to be built from ---------------------
os_value() { # os_value <KEY>: the value of KEY in the source system's os-release (usr/lib first: etc/os-release is a symlink to it)
    local f key="$1" v
    for f in "${_src_root}/usr/lib/os-release" "${_src_root}/etc/os-release"; do
        [[ -f "$f" ]] || continue
        v="$(sed -n "s/^${key}=//p" "$f" | head -n 1 | tr -d '"')"
        if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
    done
    return 1
}
package_version() { # package_version <name>: the installed version in the source system's dpkg database, or nothing
    local name="$1" status_file
    if [[ -n "$_src_root" ]]; then status_file="${_src_root}/var/lib/dpkg/status"; else status_file=/var/lib/dpkg/status; fi
    [[ -f "$status_file" ]] || return 1
    awk -v pkg="$name" 'BEGIN { RS = ""; FS = "\n" }
        { ok = 0; ver = ""; inst = 0
          for (i = 1; i <= NF; i++) {
              if ($i == "Package: " pkg) ok = 1
              if (index($i, "Version: ") == 1) ver = substr($i, 10)
              if ($i == "Status: install ok installed") inst = 1
          }
          if (ok && inst && ver != "") { print ver; exit } }' "$status_file"
}
src_name="the running system"; [[ -n "$_src_root" ]] && src_name="$_src_root"
src_os_id="$(os_value ID || true)"; src_os_version="$(os_value VERSION_ID || true)"; src_os_codename="$(os_value UBUNTU_CODENAME || os_value VERSION_CODENAME || true)"
if [[ -n "$SOURCE_REQUIRE_OS_VERSION_ID" && "$src_os_version" != "$SOURCE_REQUIRE_OS_VERSION_ID" ]]; then
    echo "[ERROR] The source theme comes from ${src_name}, which says it is ${src_os_id:-?} ${src_os_version:-(no os-release)} (${src_os_codename:-?}); the gresource is built from Ubuntu ${SOURCE_REQUIRE_OS_VERSION_ID} only."
    echo "[HINT] Run this inside an ubuntu:${SOURCE_REQUIRE_OS_VERSION_ID} container, or set SOURCE_ROOTFS to the extracted ubuntu-${SOURCE_REQUIRE_OS_VERSION_ID} base image."
    exit 1
fi
src_pkg_version=""
if [[ -n "$SOURCE_PACKAGE" ]]; then
    src_pkg_version="$(package_version "$SOURCE_PACKAGE" || true)"
    if [[ -z "$src_pkg_version" ]]; then
        echo "[ERROR] ${src_name} has no installed package ${SOURCE_PACKAGE} in its dpkg database, so the source theme cannot be identified."
        exit 1
    fi
    if [[ -n "$SOURCE_PACKAGE_VERSION_REGEX" ]] && ! [[ "$src_pkg_version" =~ $SOURCE_PACKAGE_VERSION_REGEX ]]; then
        echo "[ERROR] ${SOURCE_PACKAGE} ${src_pkg_version} in ${src_name} does not match ${SOURCE_PACKAGE_VERSION_REGEX}: not the theme this blob is built from."
        exit 1
    fi
fi
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
PROVENANCE_TEXT="[PROVENANCE] gresource source: ${src_name}
[PROVENANCE]   os-release: ${src_os_id:-?} ${src_os_version:-?} (${src_os_codename:-?})$([[ -z "$SOURCE_REQUIRE_OS_VERSION_ID" ]] && echo ' [release not checked]')
[PROVENANCE]   package: ${SOURCE_PACKAGE:-none} ${src_pkg_version:-}$([[ -z "$SOURCE_PACKAGE_VERSION_REGEX" ]] && echo ' [version not checked]')
[PROVENANCE]   source file: ${SOURCE_GRESOURCE#"${_src_root}"} $(wc -c < "$SOURCE_GRESOURCE" | tr -d ' ') bytes, sha256 $(sha256_of "$SOURCE_GRESOURCE")"
printf '%s\n' "$PROVENANCE_TEXT"

if [[ ! -f "$COLOR_MAP_FILE" ]]; then
    echo "[ERROR] COLOR_MAP_FILE not found: $COLOR_MAP_FILE"
    exit 1
fi

if [[ ! -f "$SOURCE_XML" ]]; then
    echo "[*] SOURCE_XML not found on disk; auto-generating from gresource binary..."
    _gen_xml="$(mktemp "${TMPDIR:-/tmp}/ci-gresource-xml.XXXXXX")"
    GENERATED_XML="$_gen_xml"
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
    if [[ -n "${GENERATED_XML:-}" ]]; then rm -f "$GENERATED_XML"; fi
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
PROVENANCE_TEXT="${PROVENANCE_TEXT}
[PROVENANCE] output: $(wc -c < "$OUTPUT_GRESOURCE" | tr -d ' ') bytes, sha256 $(sha256_of "$OUTPUT_GRESOURCE")"
printf '%s\n' "$PROVENANCE_TEXT" | tail -n 1
if [[ -n "${PROVENANCE_FILE:-}" ]]; then
    printf '%s\n' "$PROVENANCE_TEXT" | sed 's/^\[PROVENANCE\] //' > "$PROVENANCE_FILE"
    echo "[+] Provenance written: $PROVENANCE_FILE"
fi
