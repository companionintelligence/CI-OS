#!/bin/bash
# CI-OS Dark Green Theme Setup for Bazzite
# Sets up dark green theming across KDE Plasma and system components

set -e

echo "=== Setting up CI-OS Dark Green Theme ==="

# Define CI-OS color palette (dark green focused)
CI_PRIMARY_GREEN="#066c80"      # Deep teal-green
CI_SECONDARY_GREEN="#00a9a7"    # Bright teal
CI_ACCENT_GREEN="#72ddd4"       # Light teal
CI_DARK_BG="#1a1a1a"          # Dark background
CI_LIGHT_TEXT="#ffffff"        # White text

# Create CI-OS color scheme directory
COLORSCHEME_DIR="/usr/share/color-schemes"
mkdir -p "$COLORSCHEME_DIR"

# Create CI-OS KDE color scheme
cat > "$COLORSCHEME_DIR/CI-OS-DarkGreen.colors" << 'EOF'
[ColorEffects:Disabled]
Color=56,56,56
ColorAmount=0
ColorEffect=0
ContrastAmount=0.65
ContrastEffect=1
IntensityAmount=0.1
IntensityEffect=2

[ColorEffects:Inactive]
ChangeSelectionColor=true
Color=112,111,110
ColorAmount=0.025
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=2
Enable=false
IntensityAmount=0
IntensityEffect=0

[Colors:Button]
BackgroundAlternate=77,77,77
BackgroundNormal=49,54,59
DecorationFocus=6,108,128
DecorationHover=0,169,167
ForegroundActive=61,174,233
ForegroundInactive=161,169,177
ForegroundLink=114,221,212
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:Complementary]
BackgroundAlternate=30,87,116
BackgroundNormal=6,108,128
DecorationFocus=0,169,167
DecorationHover=114,221,212
ForegroundActive=252,252,252
ForegroundInactive=161,169,177
ForegroundLink=114,221,212
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:Selection]
BackgroundAlternate=0,169,167
BackgroundNormal=6,108,128
DecorationFocus=6,108,128
DecorationHover=0,169,167
ForegroundActive=252,252,252
ForegroundInactive=161,169,177
ForegroundLink=114,221,212
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:Tooltip]
BackgroundAlternate=77,77,77
BackgroundNormal=49,54,59
DecorationFocus=6,108,128
DecorationHover=0,169,167
ForegroundActive=61,174,233
ForegroundInactive=161,169,177
ForegroundLink=114,221,212
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:View]
BackgroundAlternate=35,38,39
BackgroundNormal=26,26,26
DecorationFocus=6,108,128
DecorationHover=0,169,167
ForegroundActive=61,174,233
ForegroundInactive=161,169,177
ForegroundLink=114,221,212
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[Colors:Window]
BackgroundAlternate=77,77,77
BackgroundNormal=49,54,59
DecorationFocus=6,108,128
DecorationHover=0,169,167
ForegroundActive=61,174,233
ForegroundInactive=161,169,177
ForegroundLink=114,221,212
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundNormal=252,252,252
ForegroundPositive=39,174,96
ForegroundVisited=155,89,182

[General]
ColorScheme=CI-OS-DarkGreen
Name=CI-OS Dark Green
shadeSortColumn=true

[KDE]
contrast=4

[WM]
activeBackground=49,54,59
activeForeground=252,252,252
inactiveBackground=42,46,50
inactiveForeground=161,169,177
EOF

# Create CI-OS Plasma theme structure
PLASMA_THEME_DIR="/usr/share/plasma/desktoptheme/ci-os-dark-green"
mkdir -p "$PLASMA_THEME_DIR"/{colors,dialogs,opaque/dialogs,opaque/widgets,widgets}

# Create plasma theme metadata
cat > "$PLASMA_THEME_DIR/metadata.desktop" << 'EOF'
[Desktop Entry]
Name=CI-OS Dark Green
Comment=CI-OS themed dark green plasma style
Encoding=UTF-8
Keywords=Desktop;Workspace;Appearance;Look and Feel;Logout;Lock;Suspend;Shutdown;Hibernate;
Type=Service
ServiceTypes=Plasma/Theme
X-KDE-PluginInfo-Author=CI-OS Team
X-KDE-PluginInfo-Category=Plasma Theme
X-KDE-PluginInfo-Depends=
X-KDE-PluginInfo-Email=contact@ci-os.org
X-KDE-PluginInfo-EnabledByDefault=true
X-KDE-PluginInfo-License=GPL
X-KDE-PluginInfo-Name=ci-os-dark-green
X-KDE-PluginInfo-Version=1.0
X-KDE-PluginInfo-Website=https://ci-os.org
X-Plasma-API=5.0
EOF

# Create CI-OS color definitions for plasma theme
cat > "$PLASMA_THEME_DIR/colors/colors" << 'EOF'
[Colors:Button]
BackgroundNormal=49,54,59
BackgroundAlternate=77,77,77
ForegroundNormal=252,252,252
ForegroundInactive=161,169,177
ForegroundActive=6,108,128
ForegroundLink=114,221,212
ForegroundVisited=155,89,182
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundPositive=39,174,96
DecorationFocus=6,108,128
DecorationHover=0,169,167

[Colors:Window]
BackgroundNormal=26,26,26
BackgroundAlternate=35,38,39
ForegroundNormal=252,252,252
ForegroundInactive=161,169,177
ForegroundActive=6,108,128
ForegroundLink=114,221,212
ForegroundVisited=155,89,182
ForegroundNegative=218,68,83
ForegroundNeutral=246,116,0
ForegroundPositive=39,174,96
DecorationFocus=6,108,128
DecorationHover=0,169,167

[Colors:Selection]
BackgroundNormal=6,108,128
BackgroundAlternate=0,169,167
ForegroundNormal=252,252,252
ForegroundInactive=161,169,177
EOF

# Create global theme look and feel
LOOKANDFEEL_DIR="/usr/share/plasma/look-and-feel/ci-os-dark-green"
mkdir -p "$LOOKANDFEEL_DIR/contents/"{defaults,previews,splash,lockscreen}

cat > "$LOOKANDFEEL_DIR/metadata.desktop" << 'EOF'
[Desktop Entry]
Name=CI-OS Dark Green
Comment=CI-OS dark green look and feel theme
Encoding=UTF-8
Keywords=Desktop;Workspace;Appearance;Look and Feel;
Type=Service
ServiceTypes=Plasma/LookAndFeel
X-KDE-PluginInfo-Author=CI-OS Team
X-KDE-PluginInfo-Category=Plasma Look And Feel
X-KDE-PluginInfo-Email=contact@ci-os.org
X-KDE-PluginInfo-License=GPL
X-KDE-PluginInfo-Name=ci-os-dark-green
X-KDE-PluginInfo-Version=1.0
X-KDE-PluginInfo-Website=https://ci-os.org
X-Plasma-MainScript=defaults
EOF

# Set default theme configurations
cat > "$LOOKANDFEEL_DIR/contents/defaults" << 'EOF'
[kdeglobals][KDE]
LookAndFeelPackage=ci-os-dark-green

[kdeglobals][General]
ColorScheme=CI-OS-DarkGreen

[kwinrc][org.kde.kdecoration2]
library=org.kde.breeze
theme=Breeze

[kwinrc][Effect-MagicLamp]
AnimationDuration=200

[plasmarc][Theme]
name=ci-os-dark-green

[Wallpaper][org.kde.image][General]
Image=/usr/share/backgrounds/ci-os/
EOF

# Create system-wide default configurations for CI-OS theming
mkdir -p /etc/skel/.config

# Configure default KDE settings for new users
cat > "/etc/skel/.config/kdeglobals" << 'EOF'
[ColorEffects:Disabled]
Color=56,56,56
ColorAmount=0
ColorEffect=0
ContrastAmount=0.65
ContrastEffect=1
IntensityAmount=0.1
IntensityEffect=2

[General]
ColorScheme=CI-OS-DarkGreen
Name=CI-OS Dark Green
shadeSortColumn=true

[KDE]
contrast=4
LookAndFeelPackage=ci-os-dark-green
EOF

# Set default wallpaper configuration
cat > "/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc" << 'EOF'
[Containments][1][Wallpaper][org.kde.image][General]
Image=/usr/share/backgrounds/ci-os/ci-os-wallpaper.svg
EOF

# Configure SDDM (login screen) with CI-OS theming
mkdir -p /etc/sddm.conf.d
cat > "/etc/sddm.conf.d/ci-os-theme.conf" << 'EOF'
[Theme]
Current=ci-os-dark-green
CursorTheme=breeze_cursors
EOF

echo "✅ CI-OS Dark Green theme setup completed"
echo "   - KDE color scheme: CI-OS-DarkGreen"  
echo "   - Plasma theme: ci-os-dark-green"
echo "   - Look and feel: ci-os-dark-green"
echo "   - Login screen themed with CI-OS colors"