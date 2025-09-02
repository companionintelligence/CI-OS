#!/bin/bash
# CI-OS Branding Configuration Script for Bazzite
# Replaces system branding elements with CI-OS branding

set -e

echo "=== Configuring CI-OS Branding ==="

# Configure OS release information
echo "📄 Updating OS release information..."

# Update /etc/os-release with CI-OS branding
cat > "/etc/os-release" << 'EOF'
NAME="CI-OS"
VERSION="1.0 (Sage)"
ID="ci-os" 
ID_LIKE="fedora"
VERSION_CODENAME="sage"
VERSION_ID="1.0"
PRETTY_NAME="CI-OS 1.0 (Sage)"
ANSI_COLOR="0;32"
LOGO="ci-os-logo"
CPE_NAME="cpe:/o:ci-os:ci-os:1.0"
HOME_URL="https://ci-os.org/"
DOCUMENTATION_URL="https://docs.ci-os.org/"
SUPPORT_URL="https://github.com/companionintelligence/CI-OS"
BUG_REPORT_URL="https://github.com/companionintelligence/CI-OS/issues"
REDHAT_BUGZILLA_PRODUCT="CI-OS"
REDHAT_BUGZILLA_PRODUCT_VERSION="1.0"
REDHAT_SUPPORT_PRODUCT="CI-OS"
REDHAT_SUPPORT_PRODUCT_VERSION="1.0"
PRIVACY_POLICY_URL="https://ci-os.org/privacy"
VARIANT="Desktop"
VARIANT_ID="desktop"
EOF

# Create CI-OS specific release file
cat > "/etc/ci-os-release" << 'EOF'
CI_OS_VERSION="1.0"
CI_OS_CODENAME="Sage"
CI_OS_BUILD_DATE="$(date +%Y-%m-%d)"
CI_OS_THEME="dark-green"
CI_OS_BASE="Bazzite"
CI_OS_DESKTOP="KDE Plasma"
EOF

# Update system hostname defaults
echo "🏠 Configuring system hostname defaults..."
echo "ci-os" > /etc/hostname

# Configure default hosts file
cat > "/etc/hosts" << 'EOF'
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
127.0.1.1   ci-os ci-os.localdomain
EOF

# Update MOTD (Message of the Day)
echo "💬 Setting up CI-OS welcome message..."
mkdir -p /etc/motd.d

cat > "/etc/motd.d/00-ci-os" << 'EOF'

 ██████╗██╗      ██████╗ ███████╗
██╔════╝██║     ██╔═══██╗██╔════╝
██║     ██║     ██║   ██║███████╗
██║     ██║     ██║   ██║╚════██║
╚██████╗██║     ╚██████╔╝███████║
 ╚═════╝╚═╝      ╚═════╝ ╚══════╝

Welcome to CI-OS - Custom Linux for Developers
Built on Bazzite | Dark Green Theme | Version 1.0

• Documentation: https://docs.ci-os.org
• Support: https://github.com/companionintelligence/CI-OS
• Community: https://community.ci-os.org

EOF

# Configure system branding in KDE About dialog
echo "ℹ️  Configuring KDE About dialog branding..."
mkdir -p /etc/xdg

cat > "/etc/xdg/kcm-about-distrorc" << 'EOF'
[General]
LogoPath=/usr/share/pixmaps/ci-os-logo.png
Name=CI-OS
Version=1.0 (Sage)
Variant=Desktop
Website=https://ci-os.org
EOF

# Configure Plymouth boot splash theme
echo "🚀 Setting up Plymouth boot splash..."
PLYMOUTH_THEME_DIR="/usr/share/plymouth/themes/ci-os-dark-green"
mkdir -p "$PLYMOUTH_THEME_DIR"

# Create Plymouth theme configuration
cat > "$PLYMOUTH_THEME_DIR/ci-os-dark-green.plymouth" << 'EOF'
[Plymouth Theme]
Name=CI-OS Dark Green
Description=CI-OS boot splash with dark green theming
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/ci-os-dark-green
ScriptFile=/usr/share/plymouth/themes/ci-os-dark-green/ci-os-dark-green.script
EOF

# Create Plymouth theme script (simplified version)
cat > "$PLYMOUTH_THEME_DIR/ci-os-dark-green.script" << 'EOF'
# CI-OS Plymouth Boot Splash Script

Window.SetBackgroundTopColor(0.02, 0.31, 0.20);     # Dark green top
Window.SetBackgroundBottomColor(0.02, 0.42, 0.31);  # Slightly lighter bottom

# Load CI-OS logo
logo.image = Image("ci-logo.png");
logo.sprite = Sprite(logo.image);
logo.opacity = 1;

# Center the logo
logo.x = Window.GetX() + Window.GetWidth()  / 2 - logo.image.GetWidth()  / 2;
logo.y = Window.GetY() + Window.GetHeight() / 2 - logo.image.GetHeight() / 2;
logo.sprite.SetPosition(logo.x, logo.y, 0);

# Progress indicator
progress = 0;

fun refresh_callback() {
    # Simple progress animation
    if (Plymouth.GetMode() == "boot") {
        progress++;
        if (progress > 50) progress = 0;
        
        # Pulsing effect for logo
        alpha = 0.7 + 0.3 * Math.Sin(progress * 0.1);
        logo.sprite.SetOpacity(alpha);
    }
}

Plymouth.SetRefreshFunction(refresh_callback);

# Display boot messages
fun display_normal_callback() {
    # Keep logo visible during normal boot
}

Plymouth.SetDisplayNormalFunction(display_normal_callback);

# Password prompt theming
fun display_password_callback(prompt, bullets) {
    # Style password prompts with CI-OS colors
}

Plymouth.SetDisplayPasswordFunction(display_password_callback);
EOF

# Copy CI-OS logo for Plymouth
if [ -f "/tmp/ci-os-assets/logos/ci-holo-flat.png" ]; then
    cp "/tmp/ci-os-assets/logos/ci-holo-flat.png" "$PLYMOUTH_THEME_DIR/ci-logo.png"
fi

# Configure system-wide desktop entries and applications
echo "🖥️  Configuring desktop application branding..."

# Update desktop entries to reflect CI-OS branding where appropriate
if [ -d "/usr/share/applications" ]; then
    # Create CI-OS system information desktop entry
    cat > "/usr/share/applications/ci-os-system-info.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=CI-OS System Information
Comment=View system information for CI-OS
Icon=ci-os-logo
Exec=neofetch
Terminal=true
Categories=System;Monitor;
Keywords=system;information;hardware;ci-os;
EOF
fi

# Configure user profile defaults
echo "👤 Setting up user profile defaults..."
mkdir -p /etc/skel/.config/autostart

# Create welcome application for first boot
cat > "/etc/skel/.config/autostart/ci-os-welcome.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=CI-OS Welcome
Comment=Welcome to CI-OS
Icon=ci-os-logo
Exec=/usr/bin/ci-os-welcome
Terminal=false
Categories=System;
X-KDE-autostart-after=panel
X-KDE-StartupNotify=false
X-GNOME-Autostart-Delay=3
EOF

# Create simple welcome script
cat > "/usr/bin/ci-os-welcome" << 'EOF'
#!/bin/bash
# CI-OS Welcome Script

if [ ! -f "$HOME/.ci-os-welcomed" ]; then
    kdialog --title "Welcome to CI-OS" \
            --msgbox "Welcome to CI-OS 1.0 (Sage)!\n\nCI-OS is a custom Linux distribution built for developers and AI companions.\n\nKey features:\n• Dark green themed interface\n• Development tools pre-installed\n• Gaming optimizations\n• Based on Bazzite\n\nVisit https://docs.ci-os.org for documentation and support.\n\nEnjoy your CI-OS experience!" \
            --icon ci-os-logo 2>/dev/null || \
    zenity --info \
           --title="Welcome to CI-OS" \
           --text="Welcome to CI-OS 1.0 (Sage)!\n\nCI-OS is a custom Linux distribution built for developers and AI companions.\n\nVisit https://docs.ci-os.org for more information." \
           --width=400 2>/dev/null || \
    notify-send "Welcome to CI-OS" "CI-OS 1.0 (Sage) is ready to use!"
    
    touch "$HOME/.ci-os-welcomed"
fi
EOF

chmod +x /usr/bin/ci-os-welcome

# Configure system-wide environment variables
echo "🌍 Setting CI-OS environment variables..."
cat > "/etc/environment.d/99-ci-os.conf" << 'EOF'
CI_OS_VERSION=1.0
CI_OS_THEME=dark-green
CI_OS_DESKTOP=KDE
XDG_CURRENT_DESKTOP=KDE
EOF

# Set default applications and MIME types
echo "🔗 Configuring default applications..."
mkdir -p /etc/xdg

cat > "/etc/xdg/mimeapps.list" << 'EOF'
[Default Applications]
text/plain=org.kde.kate.desktop
text/x-shellscript=org.kde.kate.desktop
application/x-shellscript=org.kde.kate.desktop
image/png=org.kde.gwenview.desktop
image/jpeg=org.kde.gwenview.desktop
image/svg+xml=org.kde.gwenview.desktop
application/pdf=org.kde.okular.desktop
video/mp4=org.kde.haruna.desktop
audio/mpeg=org.kde.haruna.desktop

[Added Associations]
text/plain=org.kde.kate.desktop;
text/x-shellscript=org.kde.kate.desktop;
application/x-shellscript=org.kde.kate.desktop;
EOF

echo "✅ CI-OS branding configuration completed"
echo "   - OS release information updated"
echo "   - System hostname and hosts configured" 
echo "   - MOTD and welcome messages set"
echo "   - KDE About dialog branded"
echo "   - Plymouth boot splash configured"
echo "   - User profile defaults established"
echo "   - Environment variables set"