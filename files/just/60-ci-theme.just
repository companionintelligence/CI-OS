# CI-OS Theming and Branding Commands

# Apply CI-OS dark green theme
setup-ci-theme:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🎨 Setting up CI-OS Dark Green Theme..."
    
    # Ensure config directories exist
    mkdir -p "${HOME}/.local/share/color-schemes"
    mkdir -p "${HOME}/.config"
    
    # Copy CI-OS color scheme if not already present
    if [[ ! -f "${HOME}/.local/share/color-schemes/CI-OS-Dark.colors" ]]; then
        echo "  Installing CI-OS color scheme..."
        cp /etc/skel/.local/share/color-schemes/CI-OS-Dark.colors "${HOME}/.local/share/color-schemes/"
    fi
    
    # Apply KDE theme settings
    echo "  Configuring KDE theme settings..."
    
    # Set color scheme
    kwriteconfig5 --file kdeglobals --group General --key ColorScheme "CI-OS-Dark"
    kwriteconfig5 --file kdeglobals --group ColorScheme --key ColorScheme "CI-OS-Dark"
    
    # Set window decorations to use CI colors
    kwriteconfig5 --file kdeglobals --group WM --key activeBackground "27,30,32"
    kwriteconfig5 --file kdeglobals --group WM --key activeBlend "239,240,241"
    kwriteconfig5 --file kdeglobals --group WM --key activeForeground "239,240,241"
    kwriteconfig5 --file kdeglobals --group WM --key inactiveBackground "42,46,50"
    kwriteconfig5 --file kdeglobals --group WM --key inactiveBlend "102,106,115"
    kwriteconfig5 --file kdeglobals --group WM --key inactiveForeground "102,106,115"
    
    # Set wallpaper to CI-OS theme
    echo "  Setting CI-OS wallpaper..."
    qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
        var allDesktops = desktops();
        for (i=0; i<allDesktops.length; i++) {
            d = allDesktops[i];
            d.wallpaperPlugin = "org.kde.image";
            d.currentConfigGroup = Array("Wallpaper", "org.kde.image", "General");
            d.writeConfig("Image", "file:///usr/share/wallpapers/CI-OS/ci-os-dark.svg");
            d.writeConfig("FillMode", "2");
        }
    ' 2>/dev/null || echo "    ⚠️  Could not set wallpaper automatically, please set manually"
    
    echo "  ✅ CI-OS Dark Green Theme applied!"
    echo "  📝 You may need to log out and back in for all changes to take effect"
    echo ""

# Show current theme information
ci-theme-info:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🎨 CI-OS Theme Information"
    echo "========================="
    
    # Check current color scheme
    current_scheme=$(kreadconfig5 --file kdeglobals --group General --key ColorScheme 2>/dev/null || echo "Unknown")
    echo "Current Color Scheme: $current_scheme"
    
    # Check if CI-OS color scheme is installed
    if [[ -f "${HOME}/.local/share/color-schemes/CI-OS-Dark.colors" ]]; then
        echo "CI-OS Color Scheme: ✅ Installed"
    else
        echo "CI-OS Color Scheme: ❌ Not installed"
    fi
    
    # Check wallpaper
    echo "Available CI-OS Wallpapers:"
    if [[ -d "/usr/share/wallpapers/CI-OS" ]]; then
        ls -la /usr/share/wallpapers/CI-OS/
    else
        echo "  ❌ CI-OS wallpapers not found"
    fi
    echo ""

# Reset to default CI-OS theme
reset-ci-theme:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🔄 Resetting to default CI-OS theme..."
    
    # Copy original theme files from skeleton
    echo "  Restoring CI-OS theme configurations..."
    
    # Copy color scheme
    mkdir -p "${HOME}/.local/share/color-schemes"
    cp /etc/skel/.local/share/color-schemes/CI-OS-Dark.colors "${HOME}/.local/share/color-schemes/"
    
    # Copy KDE configurations
    cp /etc/skel/.config/kdeglobals "${HOME}/.config/"
    cp /etc/skel/.config/kwinrc "${HOME}/.config/"
    cp /etc/skel/.config/plasmarc "${HOME}/.config/"
    cp /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc "${HOME}/.config/"
    
    echo "  ✅ CI-OS theme configurations restored!"
    echo "  📝 Please log out and back in for changes to take effect"
    echo ""

# Show CI-OS branding information
ci-branding-info:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🏢 CI-OS Branding Information"
    echo "============================"
    echo "Organization: Companion Intelligence - LIFESCOPE INC"
    echo "Product: CI-OS - Linux for AI"
    echo "Website: https://www.companionintelligence.com/"
    echo ""
    echo "🎨 Brand Colors:"
    echo "  Primary Dark Green:  #066c80"
    echo "  Medium Green:        #00a9a7" 
    echo "  Light Green:         #72ddd4"
    echo ""
    echo "📁 Brand Assets Location:"
    echo "  Logos: /usr/share/pixmaps/ci-os/"
    echo "  Wallpapers: /usr/share/wallpapers/CI-OS/"
    echo "  Themes: /usr/share/themes/CI-OS/"
    echo ""

# Apply boot splash theme
setup-boot-theme:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "$EUID" -ne 0 ]]; then
        echo "❌ This command requires root privileges"
        echo "Please run: sudo ujust setup-boot-theme"
        exit 1
    fi
    
    echo "🚀 Setting up CI-OS boot splash theme..."
    
    # Set Plymouth theme to CI-OS
    if [[ -f "/usr/share/plymouth/themes/ci-os/ci-os.plymouth" ]]; then
        echo "  Setting Plymouth theme to CI-OS..."
        plymouth-set-default-theme ci-os
        
        # Rebuild initramfs for the new theme
        echo "  Rebuilding initramfs..."
        dracut --force --regenerate-all
        
        echo "  ✅ CI-OS boot splash theme configured!"
        echo "  📝 Reboot to see the new boot splash"
    else
        echo "  ❌ CI-OS Plymouth theme not found"
        echo "  Theme should be at: /usr/share/plymouth/themes/ci-os/"
    fi
    echo ""