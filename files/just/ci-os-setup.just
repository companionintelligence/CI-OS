# CI-OS Setup Commands
# These commands help users set up Wine, Proton, and WinApps on CI-OS

# Complete CI-OS setup wizard
setup-ci-os:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🚀 CI-OS v01 Setup Wizard"
    echo "=========================="
    echo ""
    echo "This will set up:"
    echo "  • Wine environment"
    echo "  • Proton tools" 
    echo "  • WinApps VM configuration"
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        just setup-wine
        just setup-proton
        just setup-winapps
        echo ""
        echo "✅ CI-OS setup complete!"
        echo "You can now run Windows apps via WinApps or Wine directly."
    else
        echo "Setup cancelled."
    fi

# Set up Wine environment
setup-wine:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🍷 Setting up Wine..."
    
    # Create Wine prefix if it doesn't exist
    if [ ! -d "$HOME/.wine" ]; then
        echo "Creating Wine prefix..."
        WINEARCH=win64 winecfg
    fi
    
    # Install essential Windows components via winetricks
    echo "Installing essential Windows components..."
    winetricks -q corefonts vcrun2019 msxml3 msxml6
    
    echo "✅ Wine setup complete!"
    echo "Use 'wine <program.exe>' to run Windows programs"

# Set up Proton tools
setup-proton:
    #!/usr/bin/bash
    set -euo pipefail
    echo "⚙️ Setting up Proton tools..."
    
    # Ensure Steam directory exists for Proton
    mkdir -p "$HOME/.steam/steam"
    
    # Check if protontricks is working
    if command -v protontricks >/dev/null 2>&1; then
        echo "Protontricks is available!"
        echo "Use 'protontricks <appid> <winetricks-command>' to configure games"
    fi
    
    echo "✅ Proton setup complete!"
    echo "Install Steam to get full Proton support"

# Set up WinApps VM
setup-winapps:
    #!/usr/bin/bash
    set -euo pipefail
    echo "💻 Setting up WinApps..."
    echo ""
    echo "WinApps allows you to run Windows applications seamlessly"
    echo "in Linux by using a Windows VM with RDP integration."
    echo ""
    echo "Setup requirements:"
    echo "  • A Windows ISO file"
    echo "  • At least 4GB RAM for the VM"  
    echo "  • About 25GB disk space"
    echo ""
    read -p "Continue with WinApps setup? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Start libvirtd service
        sudo systemctl start libvirtd
        
        # Run WinApps setup
        winapps --setup
        
        echo "✅ WinApps setup started!"
        echo "Follow the prompts to complete VM configuration"
    else
        echo "WinApps setup cancelled."
        echo "You can run 'just setup-winapps' later to set it up"
    fi

# Quick Wine application launcher
run-wine APP:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🍷 Running {{ APP }} with Wine..."
    wine "{{ APP }}"

# List installed Windows apps via WinApps
list-winapps:
    #!/usr/bin/bash
    set -euo pipefail
    echo "📱 Installed Windows apps:"
    winapps --list 2>/dev/null || echo "WinApps not configured yet. Run 'just setup-winapps' first."

# Show CI-OS status and info
ci-os-info:
    #!/usr/bin/bash
    set -euo pipefail
    echo "ℹ️  CI-OS v01 Information"
    echo "========================"
    echo "Wine version: $(wine --version 2>/dev/null || echo 'Not configured')"
    echo "WinApps status: $([ -d /opt/winapps ] && echo 'Installed' || echo 'Not found')"
    echo "Virtualization: $(systemctl is-active libvirtd 2>/dev/null || echo 'Not running')"
    echo ""
    echo "Available commands:"
    echo "  just setup-ci-os    # Complete setup"
    echo "  just setup-wine     # Wine only"
    echo "  just setup-proton   # Proton only"
    echo "  just setup-winapps  # WinApps only"
    echo "  just run-wine <app> # Run Wine app"
    echo "  just list-winapps   # List WinApps"