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
    "usr/share/setup-device/defaults/hostapd-setup.conf"
    "usr/share/setup-device/defaults/setup-portal.conf"
    "etc/nginx/sites-available/setup-portal"
    "etc/netplan/50-setup-mode.yaml"
    "etc/setup-device/device.conf"
    "etc/systemd/system/hostapd-setup.service"
    "etc/systemd/system/dnsmasq-setup.service"
    "etc/systemd/system/setup-backend.service"
    "etc/systemd/system/setup-network-monitor.service"
    "etc/systemd/system/setup-pairing-verify-hub.service"
    "opt/setup-backend/setup_service.py"
    "opt/setup-backend/scripts/get-device-id.ts"
    "usr/local/bin/setup-device-hotspot-start.sh"
    "usr/local/bin/setup-network-monitor.sh"
    "usr/local/bin/setup-pairing-verify-and-hub.sh"
    "usr/local/bin/setup-start-ci-os-hub.sh"
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

# Build-time dependencies needed to install/configure the package during local testing
BUILD_DEPS=(hostapd dnsmasq nginx-light python3-flask network-manager)

# If running as root, attempt to install missing build-time packages so
# a local `dpkg -i` of the produced package will complete without unmet deps.
if [ "${EUID:-0}" -eq 0 ]; then
    echo "Running as root — checking build dependencies (will install missing packages)..."
    # Prefer IPv4 for apt in environments with broken IPv6
    apt-get -o Acquire::ForceIPv4=true update || apt-get update || true
    MISSING_DEPS=()
    for dep in "${BUILD_DEPS[@]}"; do
        if ! dpkg -s "$dep" >/dev/null 2>&1; then
            MISSING_DEPS+=("$dep")
        fi
    done
    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
        echo "Installing missing packages: ${MISSING_DEPS[*]}"
        apt-get install -y --no-install-recommends "${MISSING_DEPS[@]}"
    else
        echo "All build dependencies are already installed."
    fi
else
    echo "Note: To auto-install build dependencies, run this script with sudo."
    echo "Missing dependencies will cause 'dpkg -i' of the resulting .deb to be unconfigured." 
fi

# Remove old package if it exists
if [ -f "$OUTPUT_FILE" ]; then
    echo "Removing old package: $OUTPUT_FILE"
    rm -f "$OUTPUT_FILE"
fi

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
