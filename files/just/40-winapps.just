# WinApps Setup and Management Commands for CI-OS

# Set up WinApps VM infrastructure
setup-winapps:
    #!/usr/bin/bash
    set -euo pipefail
    echo "💻 Setting up WinApps virtualization environment..."
    
    # Check if virtualization is supported
    if ! grep -E '(vmx|svm)' /proc/cpuinfo >/dev/null; then
        echo "  ❌ Hardware virtualization not supported or not enabled in BIOS"
        echo "     Please enable VT-x/AMD-V in your BIOS settings"
        exit 1
    fi
    echo "  ✅ Hardware virtualization supported"
    
    # Check if KVM is available
    if [[ ! -e /dev/kvm ]]; then
        echo "  ⚠️ KVM device not found. Loading KVM modules..."
        sudo modprobe kvm
        if [[ -e /proc/cpuinfo ]] && grep -q Intel /proc/cpuinfo; then
            sudo modprobe kvm_intel
        else
            sudo modprobe kvm_amd
        fi
    fi
    
    if [[ -e /dev/kvm ]]; then
        echo "  ✅ KVM is available"
    else
        echo "  ❌ KVM setup failed. Check kernel modules."
        exit 1
    fi
    
    # Start and enable libvirt services
    echo "  🔧 Configuring libvirt services..."
    sudo systemctl enable --now libvirtd
    sudo systemctl enable --now virtlogd
    
    # Add user to libvirt group
    sudo usermod -a -G libvirt "$USER"
    echo "  ✅ User added to libvirt group"
    
    # Configure WinApps
    echo "  💻 Downloading and configuring WinApps..."
    
    # Create WinApps configuration directory
    mkdir -p "${HOME}/.config/winapps"
    
    if [[ ! -d "${HOME}/.local/share/winapps" ]]; then
        # Download WinApps to user directory
        cd /tmp
        curl -L -o winapps.tar.gz "https://github.com/winapps-org/winapps/archive/refs/heads/main.tar.gz" 2>/dev/null || {
            echo "  ❌ Failed to download WinApps. Check internet connection."
            exit 1
        }
        tar xzf winapps.tar.gz
        mv winapps-main "${HOME}/.local/share/winapps"
        chmod +x "${HOME}/.local/share/winapps/bin/"* 2>/dev/null || true
        rm -f winapps.tar.gz
        echo "  ✅ WinApps downloaded and installed"
    else
        echo "  ✅ WinApps already installed"
    fi
        
        # Create basic WinApps configuration
        cat > "${HOME}/.config/winapps/winapps.conf" << 'EOF'
# WinApps Configuration for CI-OS
RDP_USER=MyWindowsUser
RDP_PASS=MyWindowsPassword
WINDOWS_HOST=192.168.1.100
RDP_DOMAIN=
DEBUG=false
EOF
        echo "  ✅ WinApps configuration created at ~/.config/winapps/winapps.conf"
        echo "     Edit this file with your Windows VM details"
    
    # GPU passthrough setup for NVIDIA systems
    if [[ "${CI_OS_VARIANT:-regular}" == "nvidia" ]]; then
        echo "  🎮 Configuring NVIDIA GPU passthrough..."
        just setup-gpu-passthrough
    fi
    
    echo "  ✅ WinApps setup complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Create a Windows VM using virt-manager"
    echo "  2. Configure RDP access in Windows"
    echo "  3. Edit ~/.config/winapps/winapps.conf with VM details"
    echo "  4. Run 'just winapps-install <app>' to add Windows applications"

# Install a Windows application through WinApps
winapps-install APP:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ -z "{{APP}}" ]]; then
        echo "Usage: just winapps-install <application>"
        echo ""
        echo "Available applications:"
        echo "  adobe-cc        - Adobe Creative Cloud"
        echo "  cmd             - Command Prompt" 
        echo "  explorer        - File Explorer"
        echo "  notepad         - Notepad"
        echo "  powershell      - PowerShell"
        echo "  word            - Microsoft Word"
        echo "  excel           - Microsoft Excel"
        echo "  powerpoint      - Microsoft PowerPoint"
        echo ""
        echo "For custom apps, edit the WinApps configuration manually."
        exit 1
    fi
    
    if [[ ! -d "${HOME}/.local/share/winapps" ]]; then
        echo "❌ WinApps not configured. Run 'just setup-winapps' first."
        exit 1
    fi
    
    echo "💻 Installing Windows application: {{APP}}"
    
    cd "${HOME}/.local/share/winapps"
    
    # Check if WinApps script exists
    if [[ -f "install.sh" ]]; then
        echo "  Running WinApps installer for {{APP}}..."
        ./install.sh {{APP}} || {
            echo "  ❌ Installation failed. Check your WinApps configuration."
            echo "     Configuration file: ~/.config/winapps/winapps.conf"
            exit 1
        }
        echo "  ✅ {{APP}} installed successfully"
    else
        echo "  ❌ WinApps installer not found"
        echo "     Make sure WinApps is properly installed and configured"
        exit 1
    fi

# List installed WinApps applications
list-winapps:
    #!/usr/bin/bash
    set -euo pipefail
    echo "💻 Installed WinApps applications:"
    echo "================================"
    
    # Check for desktop files created by WinApps
    WINAPPS_DIR="${HOME}/.local/share/applications"
    if [[ -d "$WINAPPS_DIR" ]]; then
        found=false
        for desktop_file in "$WINAPPS_DIR"/*winapps*.desktop; do
            if [[ -f "$desktop_file" ]]; then
                app_name=$(grep "^Name=" "$desktop_file" 2>/dev/null | cut -d'=' -f2 || basename "$desktop_file" .desktop)
                echo "  📱 $app_name"
                found=true
            fi
        done
        
        if [[ "$found" == "false" ]]; then
            echo "  No WinApps applications installed"
            echo ""
            echo "Install applications with:"
            echo "  just winapps-install <app_name>"
        fi
    else
        echo "  No WinApps applications directory found"
        echo "  Run 'just setup-winapps' to set up WinApps"
    fi

# Remove a WinApps application
winapps-remove APP:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ -z "{{APP}}" ]]; then
        echo "Usage: just winapps-remove <application>"
        echo ""
        echo "Use 'just list-winapps' to see installed applications"
        exit 1
    fi
    
    echo "💻 Removing WinApps application: {{APP}}"
    
    cd "${HOME}/.local/share/winapps" 2>/dev/null || {
        echo "❌ WinApps not configured. Run 'just setup-winapps' first."
        exit 1
    }
    
    if [[ -f "uninstall.sh" ]]; then
        ./uninstall.sh {{APP}} || {
            echo "  ⚠️ Uninstall script failed, removing manually..."
            # Remove desktop files
            rm -f "${HOME}/.local/share/applications/*{{APP}}*.desktop" 2>/dev/null || true
            # Remove icons
            rm -f "${HOME}/.local/share/icons/winapps-{{APP}}.svg" 2>/dev/null || true
            echo "  ✅ Manual removal completed"
        }
    else
        echo "  ⚠️ Uninstall script not found, removing manually..."
        rm -f "${HOME}/.local/share/applications/*{{APP}}*.desktop" 2>/dev/null || true
        rm -f "${HOME}/.local/share/icons/winapps-{{APP}}.svg" 2>/dev/null || true
        echo "  ✅ Manual removal completed"
    fi

# Configure WinApps connection settings
configure-winapps:
    #!/usr/bin/bash
    set -euo pipefail
    echo "💻 Configuring WinApps connection settings..."
    
    CONFIG_FILE="${HOME}/.config/winapps/winapps.conf"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "❌ WinApps configuration not found. Run 'just setup-winapps' first."
        exit 1
    fi
    
    echo "Current configuration:"
    echo "====================="
    cat "$CONFIG_FILE"
    echo ""
    echo "Configuration file location: $CONFIG_FILE"
    echo ""
    echo "To edit configuration:"
    echo "  1. Open the file: nano $CONFIG_FILE"
    echo "  2. Update RDP_USER, RDP_PASS, and WINDOWS_HOST"
    echo "  3. Save and test with 'just test-winapps'"
    echo ""
    echo "Required Windows VM setup:"
    echo "  1. Enable RDP in Windows (Control Panel → System → Remote Settings)"
    echo "  2. Create a user account for RDP access"
    echo "  3. Configure network to allow RDP connections"

# Test WinApps connectivity
test-winapps:
    #!/usr/bin/bash
    set -euo pipefail
    echo "💻 Testing WinApps connectivity..."
    
    CONFIG_FILE="${HOME}/.config/winapps/winapps.conf"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "❌ WinApps configuration not found. Run 'just setup-winapps' first."
        exit 1
    fi
    
    # Source configuration
    source "$CONFIG_FILE"
    
    echo "  Testing connection to Windows host: ${WINDOWS_HOST:-not_set}"
    
    if [[ -z "${WINDOWS_HOST:-}" ]]; then
        echo "  ❌ WINDOWS_HOST not configured in $CONFIG_FILE"
        exit 1
    fi
    
    # Test ping connectivity
    if ping -c 1 -W 2 "$WINDOWS_HOST" >/dev/null 2>&1; then
        echo "  ✅ Host $WINDOWS_HOST is reachable"
    else
        echo "  ❌ Host $WINDOWS_HOST is not reachable"
        echo "     Check network connectivity and Windows VM status"
        exit 1
    fi
    
    # Test RDP port
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w2 "$WINDOWS_HOST" 3389 2>/dev/null; then
            echo "  ✅ RDP port (3389) is open"
        else
            echo "  ❌ RDP port (3389) is not accessible"
            echo "     Check Windows RDP settings and firewall"
        fi
    fi
    
    echo "  ✅ WinApps connectivity test complete"

# Set up GPU passthrough for NVIDIA systems  
setup-gpu-passthrough:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "${CI_OS_VARIANT:-regular}" != "nvidia" ]]; then
        echo "⚠️  GPU passthrough setup is only available on CI-OS NVIDIA variant"
        exit 1
    fi
    
    echo "🎮 Setting up NVIDIA GPU passthrough for WinApps..."
    
    # Check if IOMMU is enabled
    if [[ ! -d "/sys/kernel/iommu_groups" ]]; then
        echo "  ❌ IOMMU not enabled. Add 'intel_iommu=on' or 'amd_iommu=on' to kernel parameters"
        echo "     Edit /etc/default/grub and run 'sudo grub2-mkconfig -o /boot/grub2/grub.cfg'"
        exit 1
    fi
    echo "  ✅ IOMMU is enabled"
    
    # Get NVIDIA GPU info
    if command -v lspci >/dev/null 2>&1; then
        echo "  🔍 NVIDIA GPUs found:"
        lspci | grep -i nvidia | while read -r line; do
            echo "    $line"
        done
    fi
    
    echo "  📝 GPU passthrough requires manual configuration:"
    echo "     1. Identify your NVIDIA GPU PCI ID with: lspci -nn | grep -i nvidia"
    echo "     2. Add GPU PCI ID to VFIO configuration: /etc/modprobe.d/vfio.conf"
    echo "     3. Update initramfs: sudo dracut -f"
    echo "     4. Reboot and verify with: dmesg | grep -i vfio"
    echo ""
    echo "  ⚠️  Warning: GPU passthrough will make the GPU unavailable to the host"
    echo "     Consider using a secondary GPU for passthrough"
    
    echo "  ✅ GPU passthrough guidance provided"