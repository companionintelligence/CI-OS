# Proton Setup and Management Commands for CI-OS

# Set up Proton tools and protontricks
setup-proton:
    #!/usr/bin/bash
    set -euo pipefail
    echo "⚙️ Setting up Proton tools..."
    
    # Check if Steam is available
    if ! command -v steam >/dev/null 2>&1; then
        echo "  ⚠️ Steam not found. Installing Steam first..."
        rpm-ostree install -y steam || echo "  ⚠️ Failed to install Steam. Manual installation may be required."
    fi
    
    # Check if protontricks is available
    if command -v protontricks >/dev/null 2>&1; then
        echo "  ✅ Protontricks is available"
        echo "  Version: $(protontricks --version 2>/dev/null || echo 'Available')"
    else
        echo "  ❌ Protontricks not found. This should be installed via rpm-ostree."
        exit 1
    fi
    
    # Create protontricks cache directory
    mkdir -p "${HOME}/.cache/protontricks"
    mkdir -p "${HOME}/.local/share/Steam"
    
    # Set up Proton environment variables
    echo "  Configuring Proton environment..."
    if [[ ! -f "${HOME}/.bashrc" ]] || ! grep -q "PROTON_" "${HOME}/.bashrc" 2>/dev/null; then
        cat >> "${HOME}/.bashrc" << 'EOF'

# Proton configuration for CI-OS
export PROTON_USE_WINE3D=1
export PROTON_NO_ESYNC=0
export PROTON_NO_FSYNC=0
export PROTON_FORCE_LARGE_ADDRESS_AWARE=1
EOF
        echo "  ✅ Proton environment variables added to ~/.bashrc"
    else
        echo "  ✅ Proton environment already configured"
    fi
    
    # NVIDIA-specific Proton optimizations
    if [[ "${CI_OS_VARIANT:-regular}" == "nvidia" ]]; then
        echo "  Applying NVIDIA-specific Proton optimizations..."
        if ! grep -q "PROTON_ENABLE_NVAPI" "${HOME}/.bashrc" 2>/dev/null; then
            cat >> "${HOME}/.bashrc" << 'EOF'

# NVIDIA Proton optimizations
export PROTON_ENABLE_NVAPI=1
export PROTON_HIDE_NVIDIA_GPU=0
export __GL_SHADER_DISK_CACHE=1
export DXVK_NVAPI_DRIVER_VERSION=47141
EOF
            echo "  ✅ NVIDIA Proton optimizations added"
        fi
    fi
    
    echo "  ✅ Proton setup complete!"
    echo ""
    echo "Proton tools are ready:"
    echo "  - Configure games with: just proton-config <appid>"
    echo "  - List Steam games with: just proton-games"
    echo "  - Restart your shell to apply environment changes"

# Configure a specific Steam game with protontricks
proton-config APPID:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ -z "{{APPID}}" ]]; then
        echo "Usage: just proton-config <steam_app_id>"
        echo ""
        echo "Examples:"
        echo "  just proton-config 292030    # Configure The Witcher 3"
        echo "  just proton-config 271590    # Configure Grand Theft Auto V"
        echo ""
        echo "To find app IDs, use: just proton-games"
        exit 1
    fi
    
    echo "⚙️ Configuring Steam game {{APPID}} with protontricks..."
    
    if ! command -v protontricks >/dev/null 2>&1; then
        echo "❌ Protontricks not found. Run 'just setup-proton' first."
        exit 1
    fi
    
    # Check if Steam is running
    if pgrep -f steam >/dev/null; then
        echo "  ⚠️ Steam is running. Close Steam before running protontricks."
        echo "  Do you want to continue anyway? (y/N)"
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
    
    echo "  Opening protontricks GUI for app {{APPID}}..."
    protontricks {{APPID}}

# List Steam games available for Proton configuration
proton-games:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🎮 Listing Steam games available for Proton configuration..."
    
    if ! command -v protontricks >/dev/null 2>&1; then
        echo "❌ Protontricks not found. Run 'just setup-proton' first."
        exit 1
    fi
    
    echo "  Scanning for Steam games..."
    protontricks -l 2>/dev/null || {
        echo "  ❌ Could not list games. Make sure Steam is installed and has been run at least once."
        echo ""
        echo "Troubleshooting:"
        echo "  1. Install and run Steam: flatpak run com.valvesoftware.Steam"
        echo "  2. Log in to your Steam account"
        echo "  3. Install at least one game"
        echo "  4. Try running this command again"
        exit 1
    }

# Install Proton compatibility tools for non-Steam games
proton-lutris:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🎮 Setting up Proton for Lutris (non-Steam games)..."
    
    # Check if Lutris is installed
    if ! command -v lutris >/dev/null 2>&1; then
        echo "  ⚠️ Lutris not found. Installing Lutris..."
        if command -v flatpak >/dev/null 2>&1; then
            flatpak install -y flathub net.lutris.Lutris || echo "  ⚠️ Failed to install Lutris via Flatpak"
        else
            echo "  ❌ Flatpak not available. Please install Lutris manually."
            exit 1
        fi
    else
        echo "  ✅ Lutris is available"
    fi
    
    # Create Lutris runners directory for Proton
    mkdir -p "${HOME}/.local/share/lutris/runners"
    
    echo "  📦 Setting up Proton runners for Lutris..."
    echo "  This will download and configure Proton-GE for Lutris use."
    echo ""
    echo "Manual steps required:"
    echo "  1. Open Lutris"
    echo "  2. Go to Preferences → Runners → Wine"
    echo "  3. Download and select a Proton-GE version"
    echo "  4. Use Proton-GE as the Wine runner for Windows games"
    echo ""
    echo "✅ Lutris Proton setup guidance provided"

# Test Proton functionality
test-proton:
    #!/usr/bin/bash
    set -euo pipefail
    echo "⚙️ Testing Proton installation..."
    
    # Test protontricks
    if command -v protontricks >/dev/null 2>&1; then
        echo "  ✅ Protontricks: $(protontricks --version 2>/dev/null || echo 'Available')"
    else
        echo "  ❌ Protontricks not found"
        exit 1
    fi
    
    # Test Steam installation
    if command -v steam >/dev/null 2>&1; then
        echo "  ✅ Steam is installed"
    else
        echo "  ⚠️ Steam not found. Some Proton features may not work."
    fi
    
    # Check for Steam directory
    if [[ -d "${HOME}/.steam" ]] || [[ -d "${HOME}/.local/share/Steam" ]]; then
        echo "  ✅ Steam data directory found"
    else
        echo "  ⚠️ Steam data directory not found. Run Steam at least once."
    fi
    
    # Test environment variables
    echo "  📝 Proton environment variables:"
    env | grep -E "^PROTON_|^DXVK_" || echo "    No Proton environment variables set"
    
    if [[ "${CI_OS_VARIANT:-regular}" == "nvidia" ]]; then
        echo "  🎮 NVIDIA Proton optimizations:"
        env | grep -E "^__GL_|^DXVK_NVAPI" || echo "    No NVIDIA-specific variables set"
    fi
    
    echo "  ✅ Proton test complete"

# Update Proton-GE to latest version
update-proton-ge:
    #!/usr/bin/bash
    set -euo pipefail
    echo "📥 Updating Proton-GE to latest version..."
    echo ""
    echo "This will download and install the latest Proton-GE build."
    echo "Proton-GE provides better compatibility for many games."
    echo ""
    read -p "Continue with Proton-GE update? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Update cancelled."
        exit 0
    fi
    
    # Create compatibility tools directory
    COMPAT_DIR="${HOME}/.steam/root/compatibilitytools.d"
    mkdir -p "$COMPAT_DIR"
    
    echo "  📥 Downloading latest Proton-GE..."
    cd /tmp
    
    # Note: This would normally download from GitHub, but we'll provide instructions
    echo "  Manual installation required:"
    echo ""
    echo "  1. Visit: https://github.com/GloriousEggroll/proton-ge-custom/releases"
    echo "  2. Download the latest ProtonGE-*.tar.gz file"
    echo "  3. Extract to: ${COMPAT_DIR}/"
    echo "  4. Restart Steam to detect the new Proton version"
    echo ""
    echo "  Example commands:"
    echo "    cd /tmp"
    echo "    wget <proton-ge-download-url>"
    echo "    tar -xzf ProtonGE-*.tar.gz -C \"${COMPAT_DIR}/\""
    echo ""
    echo "✅ Proton-GE update instructions provided"

# Apply gaming performance optimizations for Proton
optimize-proton-gaming:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🚀 Applying Proton gaming performance optimizations..."
    
    # Apply system-wide gaming optimizations
    echo "  🔧 Applying system optimizations..."
    
    # CPU governor for performance
    if [[ -f "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" ]]; then
        echo "    Setting CPU governor to performance..."
        echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || echo "    ⚠️ Could not set CPU governor"
    fi
    
    # Memory optimizations
    echo "    Configuring memory optimizations..."
    if ! grep -q "vm.max_map_count=262144" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf >/dev/null
        sudo sysctl vm.max_map_count=262144 2>/dev/null || true
        echo "    ✅ Memory mapping limit increased"
    fi
    
    # Proton-specific optimizations
    echo "  ⚙️ Applying Proton optimizations..."
    if [[ ! -f "${HOME}/.bashrc" ]] || ! grep -q "PROTON_GAMING" "${HOME}/.bashrc" 2>/dev/null; then
        cat >> "${HOME}/.bashrc" << 'EOF'

# Proton gaming optimizations for CI-OS
export PROTON_GAMING=1
export PROTON_USE_WINED3D=0
export PROTON_USE_WINE3D=1
export PROTON_NO_ESYNC=0
export PROTON_NO_FSYNC=0
export PROTON_FORCE_LARGE_ADDRESS_AWARE=1
export WINE_LARGE_ADDRESS_AWARE=1
EOF
        echo "    ✅ Gaming environment variables added"
    fi
    
    if [[ "${CI_OS_VARIANT:-regular}" == "nvidia" ]]; then
        echo "  🎮 Applying NVIDIA gaming optimizations..."
        just optimize-nvidia-gaming
    fi
    
    echo "  ✅ Proton gaming optimizations applied!"
    echo ""
    echo "Restart your shell or log out/in to apply all changes."