# CI-OS Custom ujust Commands
# Main setup and configuration commands

# Complete CI-OS setup wizard
setup-ci-os:
    #!/usr/bin/bash
    echo "🚀 Starting CI-OS Setup Wizard..."
    echo "This will configure Wine, Proton, and CI-Server for optimal Windows app compatibility."
    echo ""
    
    # Check if running on NVIDIA system
    if lspci | grep -i nvidia > /dev/null 2>&1; then
        echo "🎯 NVIDIA GPU detected - using NVIDIA-optimized setup"
        just setup-ci-os-nvidia
        exit 0
    fi
    
    echo "⏳ Setting up Wine environment..."
    just setup-wine
    
    echo "⏳ Setting up Proton tools..."
    just setup-proton
    
    echo "⏳ Starting CI-Server..."
    just start-ci-server
    
    echo "✅ CI-OS setup complete!"
    echo "🎮 Ready to run Windows applications with Wine, Proton, and CI-Server"

# Configure Wine environment
setup-wine:
    #!/usr/bin/bash
    echo "🍷 Configuring Wine environment..."
    
    # Initialize Wine prefix if it doesn't exist
    if [ ! -d "$HOME/.wine" ]; then
        echo "Creating Wine prefix..."
        wineboot --init
    fi
    
    # Install essential Windows components
    echo "Installing essential Windows components..."
    winetricks -q corefonts vcrun2019 dxvk
    
    # Configure Wine for better compatibility
    echo "Configuring Wine settings..."
    winecfg /v win10
    
    echo "✅ Wine setup complete!"

# Setup Proton tools
setup-proton:
    #!/usr/bin/bash
    echo "⚙️ Setting up Proton tools..."
    
    # Ensure Steam is available
    if ! command -v steam > /dev/null 2>&1; then
        echo "Installing Steam..."
        flatpak install -y flathub com.valvesoftware.Steam
    fi
    
    # Configure Protontricks
    echo "Configuring Protontricks..."
    mkdir -p "$HOME/.local/share/Steam"
    
    echo "✅ Proton setup complete!"
    echo "Use protontricks to configure individual games"

# Setup WinApps VM integration
setup-winapps:
    #!/usr/bin/bash
    echo "💻 Setting up WinApps VM integration..."
    echo "⚠️  Note: WinApps requires a Windows VM. This will prepare the environment."
    
    # Install QEMU/KVM components
    echo "Preparing virtualization environment..."
    sudo systemctl enable --now libvirtd
    sudo usermod -aG libvirt $USER
    
    # Create WinApps configuration directory
    mkdir -p "$HOME/.local/share/winapps"
    
    echo "✅ WinApps environment prepared!"
    echo "📖 See documentation for Windows VM setup instructions"

# CI-Server management
start-ci-server:
    #!/usr/bin/bash
    echo "🖥️  Starting CI-Server..."
    
    if [ -x "/opt/ci-server/ci-server" ]; then
        /opt/ci-server/ci-server &
        echo "✅ CI-Server started successfully"
    else
        echo "❌ CI-Server not found or not executable"
        exit 1
    fi

stop-ci-server:
    #!/usr/bin/bash
    echo "🛑 Stopping CI-Server..."
    pkill -f ci-server
    echo "✅ CI-Server stopped"

restart-ci-server:
    #!/usr/bin/bash
    echo "🔄 Restarting CI-Server..."
    just stop-ci-server
    sleep 2
    just start-ci-server

ci-server-status:
    #!/usr/bin/bash
    echo "📊 CI-Server Status:"
    if pgrep -f ci-server > /dev/null; then
        echo "✅ CI-Server is running"
        echo "Process ID: $(pgrep -f ci-server)"
    else
        echo "❌ CI-Server is not running"
    fi

# System information
ci-os-info:
    #!/usr/bin/bash
    echo "ℹ️  CI-OS System Information"
    echo "=========================="
    echo "🖥️  Hostname: $(hostname)"
    echo "🐧 OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "🎯 CI-OS Version: v01"
    echo "🍷 Wine Version: $(wine --version 2>/dev/null || echo 'Not configured')"
    echo "⚙️  GPU: $(lspci | grep -i vga | cut -d: -f3)"
    echo ""
    echo "🖥️  CI-Server Status:"
    just ci-server-status

# Run Windows apps with Wine
run-wine TARGET:
    #!/usr/bin/bash
    echo "🍷 Running {{TARGET}} with Wine..."
    wine "{{TARGET}}"

# List available WinApps
list-winapps:
    #!/usr/bin/bash
    echo "💻 Available WinApps:"
    if [ -d "$HOME/.local/share/winapps" ]; then
        ls -la "$HOME/.local/share/winapps" || echo "No WinApps configured yet"
    else
        echo "WinApps not set up. Run 'ujust setup-winapps' first."
    fi