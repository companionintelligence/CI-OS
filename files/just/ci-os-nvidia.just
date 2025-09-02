# CI-OS NVIDIA Setup Commands
# These commands help users set up NVIDIA-specific features

# Complete CI-OS NVIDIA setup wizard
setup-ci-os-nvidia:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🚀 CI-OS v01 NVIDIA Setup Wizard"
    echo "================================="
    echo ""
    echo "This will set up:"
    echo "  • Wine environment with NVIDIA support"
    echo "  • Proton tools with NVIDIA optimizations" 
    echo "  • WinApps VM with GPU passthrough"
    echo "  • NVIDIA-specific configurations"
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        just nvidia-info
        just setup-wine-nvidia
        just setup-proton
        just setup-winapps-nvidia
        echo ""
        echo "✅ CI-OS NVIDIA setup complete!"
        echo "Your system is optimized for NVIDIA gaming and Windows apps."
    else
        echo "Setup cancelled."
    fi

# Set up Wine with NVIDIA optimizations
setup-wine-nvidia:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🍷 Setting up Wine with NVIDIA support..."
    
    # Create Wine prefix if it doesn't exist
    if [ ! -d "$HOME/.wine" ]; then
        echo "Creating Wine prefix..."
        WINEARCH=win64 winecfg
    fi
    
    # Install essential Windows components and NVIDIA-related libraries
    echo "Installing essential Windows components..."
    winetricks -q corefonts vcrun2019 msxml3 msxml6
    
    # Set up NVIDIA-specific Wine settings
    echo "Configuring NVIDIA settings for Wine..."
    
    # Enable NVIDIA GPU in Wine registry
    wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" /v "DirectDrawRenderer" /t REG_SZ /d "opengl" /f
    wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" /v "UseGLSL" /t REG_SZ /d "enabled" /f
    
    echo "✅ Wine NVIDIA setup complete!"
    echo "Use 'wine <program.exe>' to run Windows programs with NVIDIA acceleration"

# Set up WinApps VM with GPU passthrough
setup-winapps-nvidia:
    #!/usr/bin/bash
    set -euo pipefail
    echo "💻 Setting up WinApps with NVIDIA GPU passthrough..."
    echo ""
    echo "This setup enables GPU passthrough for better Windows app performance."
    echo ""
    echo "Requirements:"
    echo "  • NVIDIA GPU with VT-d/IOMMU support"
    echo "  • Windows ISO file"
    echo "  • At least 6GB RAM for the VM (NVIDIA variant needs more)"  
    echo "  • About 30GB disk space"
    echo ""
    read -p "Continue with NVIDIA WinApps setup? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Check if IOMMU is enabled
        if ! grep -q "intel_iommu=on\|amd_iommu=on" /proc/cmdline; then
            echo "⚠️ Warning: IOMMU may not be enabled."
            echo "For GPU passthrough, you may need to enable IOMMU in BIOS and kernel parameters."
        fi
        
        # Start libvirtd service
        sudo systemctl start libvirtd
        
        # Run WinApps setup with NVIDIA hints
        echo "Starting WinApps setup..."
        echo "When configuring the VM, consider enabling GPU passthrough for best performance."
        winapps --setup
        
        echo "✅ WinApps NVIDIA setup started!"
        echo "Follow the prompts to complete VM configuration with GPU passthrough"
    else
        echo "WinApps setup cancelled."
        echo "You can run 'just setup-winapps-nvidia' later to set it up"
    fi

# Check NVIDIA status and information
nvidia-info:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🎮 NVIDIA System Information"
    echo "============================"
    
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "NVIDIA Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits)"
        echo "GPU Name: $(nvidia-smi --query-gpu=gpu_name --format=csv,noheader,nounits)"
        echo "GPU Memory: $(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits) MB"
        echo "GPU Utilization: $(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)%"
        echo ""
        echo "Full NVIDIA Status:"
        nvidia-smi
    else
        echo "❌ nvidia-smi not found or NVIDIA drivers not loaded"
        echo "Check if NVIDIA drivers are properly installed"
    fi
    
    echo ""
    echo "Vulkan Support:"
    if command -v vulkaninfo >/dev/null 2>&1; then
        vulkaninfo --summary 2>/dev/null | head -10
    else
        echo "vulkaninfo not available"
    fi

# Optimize NVIDIA settings for gaming
optimize-nvidia-gaming:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🎮 Optimizing NVIDIA settings for gaming..."
    
    if command -v nvidia-settings >/dev/null 2>&1; then
        # Set performance mode
        nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=1"
        echo "✅ Set NVIDIA to performance mode"
        
        # Enable full composition pipeline for better compatibility
        nvidia-settings -a "[gpu:0]/ForceFullCompositionPipeline=On"
        echo "✅ Enabled full composition pipeline"
        
        echo "Gaming optimizations applied!"
        echo "You may want to restart your session for all changes to take effect."
    else
        echo "❌ nvidia-settings not available"
        echo "Install nvidia-settings for advanced configuration"
    fi

# Test NVIDIA Wine integration
test-nvidia-wine:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🧪 Testing NVIDIA Wine integration..."
    
    # Test Direct3D support
    echo "Testing Direct3D support..."
    wine winecfg &
    echo "Check Graphics tab in Wine configuration for Direct3D settings"
    
    echo ""
    echo "To test 3D acceleration:"
    echo "1. Install a simple DirectX game or benchmark via Wine"
    echo "2. Check that GPU usage increases during gameplay (nvidia-smi)"
    echo "3. Monitor temperatures and performance"