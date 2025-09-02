#!/bin/bash
# Wine Setup Script for CI-OS
# Sets up Wine environment with Windows application compatibility

set -euo pipefail

echo "Setting up Wine environment for CI-OS..."

# Initialize Wine prefix if it doesn't exist
if [ ! -d "${WINEPREFIX:-$HOME/.wine}" ]; then
    echo "Creating Wine prefix..."
    winecfg /v win10
fi

# Install essential Windows components
echo "Installing Windows components via winetricks..."
winetricks -q corefonts
winetricks -q vcrun2019
winetricks -q vcrun2022
winetricks -q dotnet48

# Apply Wine registry settings
if [ -f "/etc/wine/wine.reg" ]; then
    echo "Applying Wine registry settings..."
    regedit /etc/wine/wine.reg
fi

# Set up WinApps integration
if command -v winapps >/dev/null 2>&1; then
    echo "Configuring WinApps integration..."
    winapps setup
    winapps install notepad
    winapps install calc
fi

# Create desktop integration for common Windows apps
mkdir -p "$HOME/.local/share/applications"

# Wine explorer desktop entry
cat > "$HOME/.local/share/applications/wine-explorer.desktop" << EOF
[Desktop Entry]
Name=Wine File Explorer
Exec=wine explorer
Icon=wine-winefile
Type=Application
Categories=System;
EOF

echo "Wine setup completed successfully!"
echo "You can now run Windows applications using 'wine <app.exe>'"