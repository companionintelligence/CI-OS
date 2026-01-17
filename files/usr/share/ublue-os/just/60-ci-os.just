# CI-OS specific ujust commands
# These commands help set up and manage the CI-OS environment

# Display CI-OS information
ci-os-info:
    #!/usr/bin/bash
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║              CI-OS - Companion Intelligence OS             ║"
    echo "║         Bazzite with Windows Apps Support                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "🎨 Theme: CI-OS Dark Green"
    echo "🖥️  Desktop: KDE Plasma"
    echo "🎮 Base: Bazzite (Fedora $(rpm -E %fedora))"
    echo ""
    echo "Available commands:"
    echo "  ujust setup-ci-os          - First-time CI-OS setup"
    echo "  ujust setup-wine           - Configure Wine environment"
    echo "  ujust setup-proton         - Set up Proton compatibility"
    echo "  ujust setup-winapps        - Install WinApps (Windows VM apps)"
    echo "  ujust apply-ci-theme       - Apply CI-OS dark green theme"
    echo "  ujust ci-os-info           - Show this information"
    echo ""

# First-time CI-OS setup
setup-ci-os:
    #!/usr/bin/bash
    echo "🚀 Setting up CI-OS..."
    echo ""
    echo "This will configure:"
    echo "  ✓ Wine and Winetricks"
    echo "  ✓ Proton compatibility layers"
    echo "  ✓ CI-OS dark green theme"
    echo "  ✓ KDE Plasma customizations"
    echo ""
    read -p "Continue with setup? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ujust setup-wine
        ujust setup-proton
        ujust apply-ci-theme
        echo ""
        echo "✅ CI-OS setup complete!"
        echo "   To set up WinApps (optional), run: ujust setup-winapps"
    else
        echo "Setup cancelled."
    fi

# Configure Wine environment
setup-wine:
    #!/usr/bin/bash
    echo "🍷 Configuring Wine environment..."
    
    # Create Wine prefix if it doesn't exist
    if [ ! -d "$HOME/.wine" ]; then
        echo "Creating Wine prefix..."
        WINEARCH=win64 wineboot -u
    fi
    
    # Install common Windows components
    echo "Installing common Windows components via Winetricks..."
    winetricks -q corefonts vcrun2019 dotnet48 dxvk
    
    echo "✅ Wine setup complete!"
    echo "   Run Windows apps with: wine <program.exe>"

# Set up Proton compatibility
setup-proton:
    #!/usr/bin/bash
    echo "⚙️  Configuring Proton compatibility tools..."
    
    # Protontricks is already installed
    echo "Protontricks is ready for Steam games."
    echo "Usage: protontricks <appid> <winetricks-command>"
    
    echo "✅ Proton setup complete!"

# Install WinApps (Windows apps via VM)
setup-winapps:
    #!/usr/bin/bash
    echo "💻 Setting up WinApps..."
    echo ""
    echo "WinApps allows you to run Windows applications seamlessly"
    echo "through a QEMU/KVM Windows VM that looks like native Linux apps."
    echo ""
    echo "Prerequisites:"
    echo "  - Windows 10/11 ISO or installed VM"
    echo "  - At least 4GB RAM available for VM"
    echo "  - 40GB+ disk space"
    echo ""
    read -p "Continue with WinApps setup? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Clone WinApps repository
        if [ ! -d "$HOME/.local/share/winapps" ]; then
            git clone https://github.com/Fmstrat/winapps.git "$HOME/.local/share/winapps"
        fi
        
        echo ""
        echo "⚠️  WinApps repository cloned to: $HOME/.local/share/winapps"
        echo "   Please follow the setup instructions in the repository."
        echo "   You'll need to configure your Windows VM."
    else
        echo "WinApps setup cancelled."
    fi

# Apply CI-OS dark green theme
apply-ci-theme:
    #!/usr/bin/bash
    echo "🎨 Applying CI-OS dark green theme..."
    
    # Set color scheme
    kwriteconfig5 --file kdeglobals --group General --key ColorScheme "CI-OS-Dark"
    
    # Set dark theme
    kwriteconfig5 --file kdeglobals --group KDE --key LookAndFeelPackage "org.kde.breezedark.desktop"
    
    # Set wallpaper if available
    if [ -f "/usr/share/wallpapers/ci-os-wallpaper.svg" ] || [ -f "/usr/share/wallpapers/ci-os-wallpaper.png" ]; then
        WALLPAPER_PATH=$(ls /usr/share/wallpapers/ci-os-wallpaper.* 2>/dev/null | head -1)
        if [ -n "$WALLPAPER_PATH" ]; then
            kwriteconfig5 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General --key Image "$WALLPAPER_PATH"
        fi
    fi
    
    # Restart Plasma shell to apply changes
    echo "Restarting Plasma shell to apply theme..."
    kquitapp5 plasmashell && kstart5 plasmashell 2>/dev/null || true
    
    echo "✅ CI-OS theme applied!"
    echo "   If the theme doesn't apply completely, log out and log back in."

# NVIDIA-specific setup (only for NVIDIA variant)
setup-ci-os-nvidia:
    #!/usr/bin/bash
    echo "🎮 Configuring NVIDIA optimizations for CI-OS..."
    
    # Check if NVIDIA drivers are loaded
    if lsmod | grep -q nvidia; then
        echo "✅ NVIDIA drivers detected"
        
        # Enable NVIDIA settings
        echo "Configuring NVIDIA for optimal performance..."
        
        # Set PowerMizer to max performance
        nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1"
        
        echo "✅ NVIDIA optimizations applied!"
    else
        echo "⚠️  NVIDIA drivers not detected."
        echo "   Make sure you're using the CI-OS NVIDIA variant."
    fi

# Show NVIDIA info (only relevant for NVIDIA variant)
nvidia-info:
    #!/usr/bin/bash
    if lsmod | grep -q nvidia; then
        nvidia-smi
    else
        echo "⚠️  NVIDIA drivers not loaded."
        echo "   This command is only available on the NVIDIA variant."
    fi
