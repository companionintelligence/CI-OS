#!/bin/bash
# Build script for the setup-device .deb package.
#
# The package tree is assembled at build time from two sources (see
# docs/architecture/multi-distro-design.md): the distro-portable payload in
# core/headless/payload/ (the Flask backend, static portal, hostapd/dnsmasq
# configs — shared with any future non-Ubuntu backend) and the apt/dpkg-specific
# packaging in this directory (DEBIAN/ control scripts, the Ubuntu-only netplan
# config). Nothing here duplicates the payload; this only stages and packages it.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PAYLOAD_DIR="${REPO_ROOT}/core/headless/payload"
BUILD_DIR="${SCRIPT_DIR}"
# Environment knobs, used by the ISO build (backends/ubuntu/chroot/customize-chroot.sh), which must
# not write into the repo tree or install packages onto the build host:
#   SETUP_DEVICE_OUTPUT_DIR       where the .deb is written          (default: this directory)
#   SETUP_DEVICE_PKGROOT          scratch staging tree               (default: ./.pkgroot)
#   SETUP_DEVICE_SKIP_BUILD_DEPS  1 = never apt-install on this host (default: install when root)
OUTPUT_DIR="${SETUP_DEVICE_OUTPUT_DIR:-${BUILD_DIR}}"
PACKAGE_DIR="${SETUP_DEVICE_PKGROOT:-${BUILD_DIR}/.pkgroot}"

echo "Building setup-device package..."

if [ ! -d "$PAYLOAD_DIR" ]; then
    echo "Error: Payload directory not found: $PAYLOAD_DIR"
    exit 1
fi

# Assemble the staging tree: payload (etc/{hostapd,dnsmasq.d,nginx,systemd},
# opt, usr, var — renamed back to their real /etc subpaths) + this backend's
# DEBIAN/ and netplan config.
echo "Assembling package tree at $PACKAGE_DIR..."
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/etc"
cp -r "$PAYLOAD_DIR/hostapd" "$PACKAGE_DIR/etc/hostapd"
cp -r "$PAYLOAD_DIR/dnsmasq.d" "$PACKAGE_DIR/etc/dnsmasq.d"
cp -r "$PAYLOAD_DIR/nginx" "$PACKAGE_DIR/etc/nginx"
cp -r "$PAYLOAD_DIR/setup-device-defaults" "$PACKAGE_DIR/etc/setup-device"
cp -r "$PAYLOAD_DIR/systemd" "$PACKAGE_DIR/etc/systemd"
cp -r "$PAYLOAD_DIR/opt" "$PACKAGE_DIR/opt"
cp -r "$PAYLOAD_DIR/usr" "$PACKAGE_DIR/usr"
# The support rule lives in one file. Ship it in the package so post-validation
# can refuse unsupported hardware without a full CI-OS checkout.
mkdir -p "$PACKAGE_DIR/usr/lib/ci-os"
cp "$REPO_ROOT/core/lib/gpu-detect.sh" "$PACKAGE_DIR/usr/lib/ci-os/gpu-detect.sh"
chmod 644 "$PACKAGE_DIR/usr/lib/ci-os/gpu-detect.sh"
cp -r "$PAYLOAD_DIR/var" "$PACKAGE_DIR/var"
mkdir -p "$PACKAGE_DIR/etc/netplan"
cp "${SCRIPT_DIR}/netplan/50-setup-mode.yaml" "$PACKAGE_DIR/etc/netplan/50-setup-mode.yaml"
cp -r "${SCRIPT_DIR}/DEBIAN" "$PACKAGE_DIR/DEBIAN"

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
    "usr/share/icons/hicolor/scalable/apps/ci-os-logo.svg"
    "etc/nginx/sites-available/setup-portal"
    "etc/netplan/50-setup-mode.yaml"
    "etc/setup-device/device.conf"
    "etc/systemd/system/hostapd-setup.service"
    "etc/systemd/system/dnsmasq-setup.service"
    "etc/systemd/system/setup-backend.service"
    "opt/setup-backend/setup_service.py"
    "opt/setup-backend/scripts/get-device-id.ts"
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
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="${OUTPUT_DIR}/${PACKAGE_NAME}"

# Build-time dependencies needed to install/configure the package during local testing
BUILD_DEPS=(hostapd dnsmasq nginx-light python3-flask network-manager iw iproute2 rfkill)

# If running as root, attempt to install missing build-time packages so
# a local `dpkg -i` of the produced package will complete without unmet deps.
if [ "${SETUP_DEVICE_SKIP_BUILD_DEPS:-0}" = "1" ]; then
    echo "Skipping build-dependency installation (SETUP_DEVICE_SKIP_BUILD_DEPS=1)."
elif [ "${EUID:-0}" -eq 0 ]; then
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

# Ensure DEBIAN maintainer scripts are executable (git may not preserve +x)
for script in postinst prerm postrm; do
    if [ -f "${PACKAGE_DIR}/DEBIAN/${script}" ]; then
        chmod 0755 "${PACKAGE_DIR}/DEBIAN/${script}"
    fi
done

# Build the package
echo "Building package: $PACKAGE_NAME"
cd "$BUILD_DIR"

# --root-owner-group: files are owned by root:root in the package even when built by a regular user
# (otherwise the builder's uid would be baked into code that runs as root).
dpkg-deb --root-owner-group --build "$PACKAGE_DIR" "$OUTPUT_FILE"

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
