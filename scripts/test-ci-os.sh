#!/bin/bash
# CI OS Testing Script
# This script automates testing of the generated CI OS ISO

set -e

PROJECT_DIR="/Users/williambroza/devel/ci-os"
ISO_OUTPUT_DIR="$PROJECT_DIR/iso/output"
TEST_VM_NAME="ci-os-test"

echo "=== CI OS Testing Script ==="

# Find the latest CI OS ISO
CI_OS_ISO=$(find "$ISO_OUTPUT_DIR" -name "ci-os-*.iso" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)

if [ -z "$CI_OS_ISO" ]; then
    echo "❌ No CI OS ISO found in $ISO_OUTPUT_DIR"
    echo "Please build CI OS first using: ./scripts/build-ci-os.sh"
    exit 1
fi

echo "🔍 Testing ISO: $(basename "$CI_OS_ISO")"

# Basic ISO validation
echo "📋 Running basic ISO validation..."

# Check ISO size (should be reasonable)
ISO_SIZE=$(stat -c%s "$CI_OS_ISO")
ISO_SIZE_GB=$((ISO_SIZE / 1024 / 1024 / 1024))
echo "   ISO Size: ${ISO_SIZE_GB}GB"

if [ "$ISO_SIZE_GB" -lt 3 ] || [ "$ISO_SIZE_GB" -gt 8 ]; then
    echo "⚠️  Warning: Unusual ISO size (expected 3-8GB)"
fi

# Check if ISO is bootable
if command -v file &> /dev/null; then
    FILE_INFO=$(file "$CI_OS_ISO")
    if echo "$FILE_INFO" | grep -q "ISO 9660"; then
        echo "✅ Valid ISO 9660 format"
    else
        echo "❌ Invalid ISO format"
        exit 1
    fi
fi

# Mount ISO and check contents
echo "📁 Checking ISO contents..."
MOUNT_POINT="/tmp/ci-os-test-mount"
sudo mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$CI_OS_ISO" "$MOUNT_POINT"

# Check for essential files
ESSENTIAL_FILES=(
    "casper/vmlinuz"
    "casper/initrd"
    "casper/filesystem.squashfs"
    ".disk/info"
)

for file in "${ESSENTIAL_FILES[@]}"; do
    if [ -f "$MOUNT_POINT/$file" ]; then
        echo "✅ Found: $file"
    else
        echo "❌ Missing: $file"
    fi
done

# Check disk info
if [ -f "$MOUNT_POINT/.disk/info" ]; then
    DISK_INFO=$(cat "$MOUNT_POINT/.disk/info")
    echo "💿 Disk Info: $DISK_INFO"
fi

# Unmount
sudo umount "$MOUNT_POINT"
sudo rmdir "$MOUNT_POINT"

echo "✅ Basic ISO validation completed"

# Virtual machine testing (if requested)
read -p "🤖 Do you want to test in a virtual machine? (requires VirtualBox) [y/N]: " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if command -v VBoxManage &> /dev/null; then
        echo "🚀 Creating test virtual machine..."
        
        # Create VM
        VBoxManage createvm --name "$TEST_VM_NAME" --ostype "Ubuntu_64" --register
        
        # Configure VM
        VBoxManage modifyvm "$TEST_VM_NAME" \
            --memory 4096 \
            --cpus 2 \
            --vram 128 \
            --graphicscontroller vmsvga \
            --boot1 dvd \
            --boot2 disk \
            --nic1 nat
        
        # Create and attach storage
        VBoxManage createhd --filename "$HOME/VirtualBox VMs/$TEST_VM_NAME/$TEST_VM_NAME.vdi" --size 25600
        VBoxManage storagectl "$TEST_VM_NAME" --name "SATA Controller" --add sata --controller IntelAhci
        VBoxManage storageattach "$TEST_VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$HOME/VirtualBox VMs/$TEST_VM_NAME/$TEST_VM_NAME.vdi"
        
        # Attach ISO
        VBoxManage storagectl "$TEST_VM_NAME" --name "IDE Controller" --add ide
        VBoxManage storageattach "$TEST_VM_NAME" --storagectl "IDE Controller" --port 1 --device 0 --type dvddrive --medium "$CI_OS_ISO"
        
        echo "✅ Virtual machine '$TEST_VM_NAME' created"
        echo "🎯 Starting VM for testing..."
        
        VBoxManage startvm "$TEST_VM_NAME"
        
        echo "📝 Manual testing checklist:"
        echo "   1. Boot process completes successfully"
        echo "   2. Desktop environment loads"
        echo "   3. Test development tools (git, docker, etc.)"
        echo "   4. Test gaming tools (steam, if applicable)"
        echo "   5. Network connectivity works"
        echo "   6. Installation process works"
        
        read -p "⏹️  Press Enter when testing is complete to clean up..."
        
        # Clean up
        VBoxManage controlvm "$TEST_VM_NAME" poweroff 2>/dev/null || true
        sleep 5
        VBoxManage unregistervm "$TEST_VM_NAME" --delete
        
        echo "🧹 Test VM cleaned up"
    else
        echo "❌ VirtualBox not found. Please install VirtualBox for VM testing."
    fi
fi

echo ""
echo "=== Testing Summary ==="
echo "✅ ISO validation completed"
echo "📁 ISO Location: $CI_OS_ISO"
echo "📊 ISO Size: ${ISO_SIZE_GB}GB"
echo ""
echo "🎉 CI OS testing completed!"
