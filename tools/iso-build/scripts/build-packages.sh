#!/usr/bin/env bash
#=============================================================================
# Build CI-OS Debian Packages
# Builds all .deb packages from the packages/ directory
#
# Usage:
#   ./tools/iso-build/scripts/build-packages.sh [output_dir]
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

set -euo pipefail

OUTPUT_DIR="${1:-./output/packages}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PACKAGES_DIR="$REPO_ROOT/packages"

echo "[*] Building CI-OS packages..."
echo "[*] Output directory: $OUTPUT_DIR"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Build each package
for pkg_dir in "$PACKAGES_DIR"/*/; do
    pkg_name=$(basename "$pkg_dir")
    
    if [[ ! -f "$pkg_dir/DEBIAN/control" ]]; then
        echo "[!] Skipping $pkg_name (no DEBIAN/control)"
        continue
    fi
    
    echo "[*] Building package: $pkg_name"
    
    # Make postinst/preinst/prerm/postrm executable if they exist
    for script in postinst preinst prerm postrm; do
        if [[ -f "$pkg_dir/DEBIAN/$script" ]]; then
            chmod +x "$pkg_dir/DEBIAN/$script"
        fi
    done
    
    # Build the package
    dpkg-deb --build "$pkg_dir" "$OUTPUT_DIR"
    
    echo "[+] Built: $pkg_name"
done

echo
echo "[+] All packages built successfully"
echo "[+] Location: $OUTPUT_DIR"
if compgen -G "$OUTPUT_DIR"/*.deb > /dev/null; then
    ls -lh "$OUTPUT_DIR"/*.deb
else
    echo "[!] No .deb packages were built (none found in $OUTPUT_DIR)"
fi
