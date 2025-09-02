# ujust / justfile fragment: Wine + Proton helpers

# Create a default 64-bit Wine prefix at ~/.wine and verify 32-bit is available
setup-wine:
    @echo ">>> Creating default Wine prefix and verifying 32-bit libs..."
    WINEARCH=win64 WINEPREFIX="${HOME}/.wine" wineboot -u
    echo
    echo ">>> Installing corefonts & common winetricks bits (optional)..."
    winetricks -q corefonts fontsmooth=rgb riched20

# Proton helper: ensure protontricks is ready and document how to run EXEs via Proton
setup-proton-tools:
    @echo ">>> protontricks is installed system-wide."
    echo "To run a non-Steam .exe under a Proton prefix, typical flow is:"
    echo "  - Create a Steam tool/game entry using desired Proton version"
    echo "  - Use: protontricks -c '/path/to/your.exe' <STEAM_APPID or prefix>"
    echo
    echo "For GUI prefix management, install Bottles from Flathub:"
    echo "  flatpak install -y flathub com.usebottles.bottles"