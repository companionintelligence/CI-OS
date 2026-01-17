#!/bin/bash
# CI OS Automated Build Script
# This script automates the creation of CI OS using Cubic

set -e

PROJECT_DIR="/Users/williambroza/devel/ci-os"
CUBIC_PROJECT_DIR="$PROJECT_DIR/cubic-project"
ISO_BASE_DIR="$PROJECT_DIR/iso/base"
ISO_OUTPUT_DIR="$PROJECT_DIR/iso/output"
UBUNTU_ISO_URL="https://releases.ubuntu.com/noble/ubuntu-24.04.2-desktop-amd64.iso"
UBUNTU_ISO_NAME="ubuntu-24.04-desktop-amd64.iso"

echo "=== CI OS Automated Build Script ==="

# Check if Cubic is installed
if ! command -v cubic &> /dev/null; then
    echo "❌ Cubic is not installed. Please install Cubic first:"
    echo "   Ubuntu: sudo apt install cubic"
    echo "   See: https://github.com/PJ-Singh-001/Cubic/wiki/Install-Cubic"
    exit 1
fi

# Create directories if they don't exist
mkdir -p "$ISO_BASE_DIR" "$ISO_OUTPUT_DIR" "$CUBIC_PROJECT_DIR"

# Download Ubuntu ISO if it doesn't exist
if [ ! -f "$ISO_BASE_DIR/$UBUNTU_ISO_NAME" ]; then
    echo "📥 Downloading Ubuntu 24.04 LTS ISO..."
    curl -L "$UBUNTU_ISO_URL" -o "$ISO_BASE_DIR/$UBUNTU_ISO_NAME"
    echo "✅ Ubuntu ISO downloaded"
else
    echo "✅ Ubuntu ISO already exists"
fi

# Verify ISO integrity (optional)
echo "🔍 Verifying ISO integrity..."
cd "$ISO_BASE_DIR"
if command -v sha256sum &> /dev/null; then
    # Download checksum file and verify
    curl -s https://releases.ubuntu.com/24.04/SHA256SUMS | grep "$UBUNTU_ISO_NAME" > ubuntu.sha256
    if sha256sum -c ubuntu.sha256; then
        echo "✅ ISO integrity verified"
    else
        echo "❌ ISO integrity check failed"
        exit 1
    fi
fi

# Make scripts executable
chmod +x "$PROJECT_DIR"/scripts/*.sh
chmod +x "$PROJECT_DIR"/configs/scripts/*.sh

echo "✅ Build environment prepared"
echo ""
echo "Next steps:"
echo "1. Launch Cubic: cubic"
echo "2. Create new project in: $CUBIC_PROJECT_DIR"
echo "3. Select base ISO: $ISO_BASE_DIR/$UBUNTU_ISO_NAME"
echo "4. Follow the customization plan in docs/cubic-customization-plan.md"
echo "5. Copy assets and configs during customization"
echo "6. Run customization scripts in the chroot environment"
echo ""
echo "For detailed instructions, see: docs/cubic-customization-plan.md"
