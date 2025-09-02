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

# CI-Server management commands that work with systemd service
start-ci-server:
    #!/usr/bin/bash
    echo "🖥️  Starting CI-Server..."
    
    if systemctl is-active ci-server >/dev/null 2>&1; then
        echo "✅ CI-Server is already running"
        just ci-server-status
    else
        sudo systemctl start ci-server
        sleep 2
        if systemctl is-active ci-server >/dev/null 2>&1; then
            echo "✅ CI-Server started successfully"
            echo "🌐 Web interface: http://localhost:8080/ui"
        else
            echo "❌ Failed to start CI-Server"
            echo "📋 Check status: journalctl -u ci-server -n 10"
        fi
    fi

stop-ci-server:
    #!/usr/bin/bash
    echo "🛑 Stopping CI-Server..."
    
    if systemctl is-active ci-server >/dev/null 2>&1; then
        sudo systemctl stop ci-server
        echo "✅ CI-Server stopped"
    else
        echo "ℹ️  CI-Server is not running"
    fi

restart-ci-server:
    #!/usr/bin/bash
    echo "🔄 Restarting CI-Server..."
    sudo systemctl restart ci-server
    sleep 2
    just ci-server-status

ci-server-status:
    #!/usr/bin/bash
    echo "📊 CI-Server Status:"
    echo "==================="
    
    if systemctl is-active ci-server >/dev/null 2>&1; then
        echo "✅ Status: Running"
        echo "🔗 Service: $(systemctl is-enabled ci-server 2>/dev/null)"
        echo "🌐 Interface: http://localhost:8080/ui"
        echo "📊 Process: $(systemctl show ci-server --property=MainPID --value)"
        echo "⏱️  Uptime: $(systemctl show ci-server --property=ActiveEnterTimestamp --value | cut -d' ' -f2-3)"
    else
        echo "❌ Status: Not running"
        echo "🔗 Service: $(systemctl is-enabled ci-server 2>/dev/null || echo 'disabled')"
        echo "❓ Last logs:"
        journalctl -u ci-server -n 5 --no-pager --output=cat 2>/dev/null || echo "  No logs available"
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
    echo ""
    echo "🎮 To get started:"
    echo "  • Web interface: http://localhost:8080/ui"
    echo "  • Manage service: ujust start-ci-server / ujust stop-ci-server"
    echo "  • View logs: journalctl -u ci-server -f"

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