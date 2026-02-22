#!/bin/bash
# Build script for setup-device .deb package

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="${SCRIPT_DIR}/setup-device"
BUILD_DIR="${SCRIPT_DIR}"

echo "Building setup-device package..."

# Check if package directory exists
if [ ! -d "$PACKAGE_DIR" ]; then
    echo "Error: Package directory not found: $PACKAGE_DIR"
    exit 1
fi

# Validate required files exist
echo "Validating required files..."

REQUIRED_FILES=(
    "DEBIAN/control"
    "DEBIAN/postinst"
    "DEBIAN/prerm"
    "DEBIAN/postrm"
    "etc/hostapd/hostapd-setup.conf"
    "etc/dnsmasq.d/setup-portal.conf"
    "etc/nginx/sites-available/setup-portal"
    "etc/netplan/50-setup-mode.yaml"
    "etc/setup-device/device.conf"
    "etc/systemd/system/hostapd-setup.service"
    "etc/systemd/system/dnsmasq-setup.service"
    "etc/systemd/system/setup-backend.service"
    "opt/setup-backend/setup_service.py"
    "usr/local/bin/setup-device-prescan.py"
    "var/www/setup-portal/index.html"
)

MISSING_FILES=()

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${PACKAGE_DIR}/${file}" ]; then
        MISSING_FILES+=("$file")
    fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    echo "Error: Missing required files:"
    for file in "${MISSING_FILES[@]}"; do
        echo "  - ${file}"
    done
    exit 1
fi

echo "✓ All required files present"

# Get version from control file
VERSION=$(grep "^Version:" "${PACKAGE_DIR}/DEBIAN/control" | awk '{print $2}')
ARCH=$(grep "^Architecture:" "${PACKAGE_DIR}/DEBIAN/control" | awk '{print $2}')

if [ -z "$VERSION" ]; then
    echo "Error: Could not determine package version"
    exit 1
fi

if [ -z "$ARCH" ]; then
    echo "Error: Could not determine package architecture"
    exit 1
fi

PACKAGE_NAME="setup-device_${VERSION}_${ARCH}.deb"
OUTPUT_FILE="${BUILD_DIR}/${PACKAGE_NAME}"

# Remove old package if it exists
if [ -f "$OUTPUT_FILE" ]; then
    echo "Removing old package: $OUTPUT_FILE"
    rm -f "$OUTPUT_FILE"
fi

# Ensure DEBIAN maintainer scripts are executable (git may not preserve +x)
for script in postinst prerm postrm; do
    if [ -f "${PACKAGE_DIR}/DEBIAN/${script}" ]; then
        chmod 0755 "${PACKAGE_DIR}/DEBIAN/${script}"
    fi
done

# Build the package
echo "Building package: $PACKAGE_NAME"
cd "$BUILD_DIR"

dpkg-deb --build setup-device "$OUTPUT_FILE"

if [ $? -eq 0 ]; then
    echo "✓ Package built successfully: $OUTPUT_FILE"
    echo ""
    echo "Package info:"
    dpkg-deb --info "$OUTPUT_FILE"
    echo ""
    echo "To install:"
    echo "  sudo dpkg -i $OUTPUT_FILE"
else
    echo "Error: Package build failed"
    exit 1
fi
