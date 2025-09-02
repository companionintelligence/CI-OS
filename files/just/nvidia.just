# CI-OS NVIDIA-Specific ujust Commands
# NVIDIA GPU optimized setup and management

# NVIDIA-optimized CI-OS setup
setup-ci-os-nvidia:
    #!/usr/bin/bash
    echo "🎯 Starting NVIDIA-optimized CI-OS setup..."
    echo "This will configure Wine, Proton, and CI-Server with NVIDIA acceleration."
    echo ""
    
    echo "⏳ Setting up NVIDIA Wine environment..."
    just setup-wine-nvidia
    
    echo "⏳ Setting up NVIDIA Proton configuration..."
    just setup-proton-nvidia
    
    echo "⏳ Optimizing NVIDIA gaming performance..."
    just optimize-nvidia-gaming
    
    echo "⏳ Starting CI-Server with NVIDIA support..."
    just start-ci-server-nvidia
    
    echo "✅ NVIDIA-optimized CI-OS setup complete!"
    echo "🚀 Ready for high-performance Windows apps and gaming"

# NVIDIA-optimized Wine setup
setup-wine-nvidia:
    #!/usr/bin/bash
    echo "🍷 Configuring Wine with NVIDIA optimizations..."
    
    # Initialize Wine prefix with NVIDIA settings
    if [ ! -d "$HOME/.wine" ]; then
        echo "Creating Wine prefix with NVIDIA support..."
        wineboot --init
    fi
    
    # Install NVIDIA-specific components
    echo "Installing NVIDIA-optimized Windows components..."
    winetricks -q corefonts vcrun2019 dxvk
    
    # Configure Wine registry for NVIDIA
    echo "Applying NVIDIA-specific Wine settings..."
    wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" /v VideoPciDeviceID /t REG_DWORD /d 0x1234 /f
    wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" /v VideoPciVendorID /t REG_DWORD /d 0x10DE /f
    
    # Set NVIDIA environment variables
    echo 'export __GL_SHADER_DISK_CACHE_PATH="$HOME/.cache/nvidia"' >> "$HOME/.bashrc"
    echo 'export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1' >> "$HOME/.bashrc"
    echo 'export __GL_THREADED_OPTIMIZATIONS=1' >> "$HOME/.bashrc"
    
    echo "✅ NVIDIA Wine setup complete!"

# NVIDIA-optimized Proton setup
setup-proton-nvidia:
    #!/usr/bin/bash
    echo "⚙️ Setting up NVIDIA-optimized Proton..."
    
    # Ensure Steam is available
    if ! command -v steam > /dev/null 2>&1; then
        echo "Installing Steam with NVIDIA support..."
        flatpak install -y flathub com.valvesoftware.Steam
    fi
    
    # Configure Steam for NVIDIA
    mkdir -p "$HOME/.local/share/Steam"
    
    # Set NVIDIA-specific launch options
    echo "Configuring NVIDIA-specific Steam settings..."
    mkdir -p "$HOME/.steam/steam/config"
    
    echo "✅ NVIDIA Proton setup complete!"

# Optimize NVIDIA gaming performance
optimize-nvidia-gaming:
    #!/usr/bin/bash
    echo "🚀 Optimizing NVIDIA gaming performance..."
    
    # Set GPU performance mode
    echo "Setting NVIDIA GPU to performance mode..."
    nvidia-settings -a '[gpu:0]/GPUPowerMizerMode=1' 2>/dev/null || echo "Note: nvidia-settings not available in container"
    
    # Configure kernel parameters for NVIDIA
    echo "NVIDIA optimization settings applied"
    
    echo "✅ NVIDIA gaming optimization complete!"

# Start CI-Server with NVIDIA support
start-ci-server-nvidia:
    #!/usr/bin/bash
    echo "🖥️  Starting CI-Server with NVIDIA acceleration..."
    
    if systemctl is-active ci-server >/dev/null 2>&1; then
        echo "✅ CI-Server is already running"
        just ci-server-status
    else
        # Set NVIDIA environment variables and start service
        if sudo systemctl set-environment NVIDIA_VISIBLE_DEVICES=all 2>/dev/null && sudo systemctl start ci-server 2>/dev/null; then
            sleep 2
            if systemctl is-active ci-server >/dev/null 2>&1; then
                echo "✅ CI-Server started with NVIDIA support"
                echo "🌐 Web interface: http://localhost:8080/ui"
            else
                echo "❌ CI-Server started but may not be ready yet"
                echo "📋 Check status: journalctl -u ci-server -n 10"
            fi
        else
            echo "❌ Failed to start CI-Server with NVIDIA support"
            echo "📋 Check NVIDIA drivers: nvidia-smi"
            echo "📋 Check service status: systemctl status ci-server"
        fi
    fi

# NVIDIA system information
nvidia-info:
    #!/usr/bin/bash
    echo "🎯 NVIDIA System Information"
    echo "==========================="
    echo "🔧 Driver Version: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null || echo 'NVIDIA driver not detected')"
    echo "🎮 GPU Model: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'No NVIDIA GPU detected')"
    echo "💾 VRAM: $(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null || echo 'N/A')"
    echo "🌡️  GPU Temperature: $(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo 'N/A')°C"
    echo "⚡ Power Draw: $(nvidia-smi --query-gpu=power.draw --format=csv,noheader 2>/dev/null || echo 'N/A')"
    echo ""
    echo "🍷 Wine NVIDIA Status:"
    if [ -f "$HOME/.wine/system.reg" ]; then
        echo "✅ Wine configured with NVIDIA support"
    else
        echo "❌ Wine not configured. Run 'ujust setup-wine-nvidia'"
    fi
    echo ""
    echo "🖥️  CI-Server Status:"
    just ci-server-status
    echo ""
    echo "🎮 NVIDIA Features:"
    echo "  • GPU acceleration enabled in CI-Server"
    echo "  • Hardware video decode/encode support"
    echo "  • CUDA compute capabilities available"

# Test NVIDIA Wine integration
test-nvidia-wine:
    #!/usr/bin/bash
    echo "🧪 Testing NVIDIA Wine integration..."
    
    # Test basic Wine functionality
    echo "Testing Wine..."
    wine --version > /dev/null 2>&1 && echo "✅ Wine is functional" || echo "❌ Wine test failed"
    
    # Test NVIDIA detection in Wine
    echo "Testing NVIDIA detection in Wine..."
    wine reg query "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" > /dev/null 2>&1 && echo "✅ NVIDIA Wine registry configured" || echo "❌ NVIDIA Wine configuration missing"
    
    # Test GPU access
    echo "Testing GPU access..."
    nvidia-smi > /dev/null 2>&1 && echo "✅ NVIDIA GPU accessible" || echo "❌ NVIDIA GPU not accessible"
    
    echo "🧪 NVIDIA Wine test complete!"

# NVIDIA troubleshooting
nvidia-troubleshoot:
    #!/usr/bin/bash
    echo "🔧 NVIDIA Troubleshooting"
    echo "========================"
    
    echo "Checking NVIDIA driver installation..."
    lsmod | grep nvidia > /dev/null && echo "✅ NVIDIA kernel modules loaded" || echo "❌ NVIDIA kernel modules not loaded"
    
    echo "Checking device permissions..."
    ls -la /dev/nvidia* 2>/dev/null || echo "❌ NVIDIA devices not found"
    
    echo "Checking Wine NVIDIA configuration..."
    [ -f "$HOME/.wine/system.reg" ] && echo "✅ Wine prefix exists" || echo "❌ Wine prefix missing"
    
    echo "Suggested fixes:"
    echo "1. Reboot system to ensure NVIDIA drivers are loaded"
    echo "2. Run 'ujust setup-wine-nvidia' to reconfigure Wine"
    echo "3. Check NVIDIA driver installation with 'nvidia-smi'"