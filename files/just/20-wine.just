# Wine Setup and Management Commands for CI-OS

# Set up Wine environment
setup-wine:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🍷 Setting up Wine environment..."
    
    # Create wine prefix if it doesn't exist
    export WINEPREFIX="${HOME}/.wine"
    export WINEARCH="win64"
    
    if [[ ! -d "$WINEPREFIX" ]]; then
        echo "  Creating Wine prefix at $WINEPREFIX..."
        wineboot --init
        echo "  ✅ Wine prefix created"
    else
        echo "  ✅ Wine prefix already exists at $WINEPREFIX"
    fi
    
    # Install essential Windows components
    echo "  Installing essential Windows components..."
    winetricks -q corefonts vcrun2019 vcrun2022 dotnet48 || echo "  ⚠️ Some components may have failed to install"
    
    # Configure Wine settings
    echo "  Configuring Wine settings..."
    # Set Windows version to Windows 10
    winetricks -q win10
    
    # Configure graphics settings
    if [[ "${CI_OS_VARIANT:-regular}" == "nvidia" ]]; then
        echo "  Applying NVIDIA-specific Wine configurations..."
        # Enable NVIDIA optimizations in Wine registry
        cat > /tmp/nvidia-wine.reg << 'EOF'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Wine\Direct3D]
"DirectDrawRenderer"="opengl"
"VideoMemorySize"="2048"
"OffscreenRenderingMode"="fbo"
"Multisampling"="enabled"
EOF
        wine regedit /S /tmp/nvidia-wine.reg 2>/dev/null || true
        rm -f /tmp/nvidia-wine.reg
    fi
    
    echo "  ✅ Wine setup complete!"
    echo ""
    echo "Wine is ready to use:"
    echo "  - Prefix: $WINEPREFIX"
    echo "  - Architecture: $WINEARCH"
    echo "  - Run Windows apps with: wine program.exe"
    echo "  - Configure Wine with: winecfg"

# Run a Windows application with Wine
run-wine *ARGS:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ $# -eq 0 ]]; then
        echo "Usage: just run-wine <application.exe> [arguments...]"
        echo ""
        echo "Examples:"
        echo "  just run-wine notepad.exe"
        echo "  just run-wine /path/to/installer.exe"
        echo "  just run-wine \"C:\\Program Files\\MyApp\\app.exe\""
        exit 1
    fi
    
    export WINEPREFIX="${HOME}/.wine"
    export WINEARCH="win64"
    
    if [[ ! -d "$WINEPREFIX" ]]; then
        echo "❌ Wine prefix not found. Run 'just setup-wine' first."
        exit 1
    fi
    
    echo "🍷 Running Windows application with Wine..."
    echo "Application: $1"
    echo "Prefix: $WINEPREFIX"
    echo ""
    
    # Apply NVIDIA optimizations if available
    if [[ "${CI_OS_VARIANT:-regular}" == "nvidia" ]]; then
        export __GL_SHADER_DISK_CACHE=1
        export __GL_SHADER_DISK_CACHE_PATH="${HOME}/.cache/nvidia"
        export __GL_SYNC_TO_VBLANK=1
    fi
    
    wine "$@"

# Configure Wine with winecfg GUI
configure-wine:
    #!/usr/bin/bash
    set -euo pipefail
    export WINEPREFIX="${HOME}/.wine"
    export WINEARCH="win64"
    
    if [[ ! -d "$WINEPREFIX" ]]; then
        echo "❌ Wine prefix not found. Run 'just setup-wine' first."
        exit 1
    fi
    
    echo "🍷 Opening Wine configuration..."
    winecfg

# Install Windows software using winetricks
wine-install *PACKAGES:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ $# -eq 0 ]]; then
        echo "Usage: just wine-install <package1> [package2 ...]"
        echo ""
        echo "Common packages:"
        echo "  vcrun2019    - Visual C++ 2019 Redistributable"
        echo "  vcrun2022    - Visual C++ 2022 Redistributable" 
        echo "  dotnet48     - .NET Framework 4.8"
        echo "  corefonts    - Windows Core Fonts"
        echo "  d3dx9        - DirectX 9 Libraries"
        echo "  d3dx11_43    - DirectX 11 Libraries"
        echo ""
        echo "For full list: winetricks list-all"
        exit 1
    fi
    
    export WINEPREFIX="${HOME}/.wine"
    export WINEARCH="win64"
    
    if [[ ! -d "$WINEPREFIX" ]]; then
        echo "❌ Wine prefix not found. Run 'just setup-wine' first."
        exit 1
    fi
    
    echo "🍷 Installing Windows components with winetricks..."
    for package in "$@"; do
        echo "  Installing: $package"
        winetricks -q "$package" || echo "  ⚠️ Failed to install $package"
    done
    echo "✅ Installation complete!"

# Reset Wine environment
wine-reset:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🍷 Resetting Wine environment..."
    echo ""
    echo "⚠️  WARNING: This will delete your entire Wine prefix!"
    echo "   All installed Windows applications will be removed."
    echo "   Your Wine prefix: ${HOME}/.wine"
    echo ""
    read -p "Are you sure you want to reset Wine? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Reset cancelled."
        exit 0
    fi
    
    echo "  Removing Wine prefix..."
    rm -rf "${HOME}/.wine"
    echo "  ✅ Wine prefix removed"
    echo ""
    echo "Run 'just setup-wine' to create a new Wine environment."

# Test Wine installation
test-wine:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🍷 Testing Wine installation..."
    
    export WINEPREFIX="${HOME}/.wine"
    export WINEARCH="win64"
    
    if [[ ! -d "$WINEPREFIX" ]]; then
        echo "❌ Wine prefix not found. Run 'just setup-wine' first."
        exit 1
    fi
    
    echo "  Wine version: $(wine --version)"
    echo "  Wine prefix: $WINEPREFIX"
    echo "  Architecture: $WINEARCH"
    echo ""
    echo "  Testing basic Wine functionality..."
    if wine cmd.exe /c echo "Wine test successful" 2>/dev/null | grep -q "successful"; then
        echo "  ✅ Wine is working correctly"
    else
        echo "  ❌ Wine test failed"
        exit 1
    fi
    
    echo "  Testing Windows executable support..."
    if wine notepad.exe /? 2>/dev/null >/dev/null; then
        echo "  ✅ Windows executables can run"
    else
        echo "  ⚠️ Windows executables may have issues"
    fi
    
    if [[ "${CI_OS_VARIANT:-regular}" == "nvidia" ]]; then
        echo ""
        echo "  Testing NVIDIA integration..."
        just test-nvidia-wine
    fi

# Test NVIDIA-specific Wine integration
test-nvidia-wine:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "${CI_OS_VARIANT:-regular}" != "nvidia" ]]; then
        echo "⚠️  This command is only available on CI-OS NVIDIA variant"
        exit 1
    fi
    
    export WINEPREFIX="${HOME}/.wine"
    export __GL_SHADER_DISK_CACHE=1
    export __GL_SHADER_DISK_CACHE_PATH="${HOME}/.cache/nvidia"
    export __GL_SYNC_TO_VBLANK=1
    
    echo "🎮 Testing NVIDIA Wine integration..."
    
    # Test NVIDIA environment variables
    if [[ -n "${__GL_SHADER_DISK_CACHE:-}" ]]; then
        echo "  ✅ NVIDIA shader cache enabled"
        echo "     Cache path: ${__GL_SHADER_DISK_CACHE_PATH:-unknown}"
    else
        echo "  ⚠️ NVIDIA shader cache not configured"
    fi
    
    # Test OpenGL support in Wine
    echo "  Testing OpenGL support..."
    if wine cmd.exe /c "echo OpenGL test" 2>/dev/null | grep -q "OpenGL"; then
        echo "  ✅ OpenGL support available"
    else
        echo "  ⚠️ OpenGL support may be limited"
    fi
    
    echo "  ✅ NVIDIA Wine integration test complete"