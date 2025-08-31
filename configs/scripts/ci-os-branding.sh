#!/bin/bash
# CI-OS Branding Customization Script
# This script applies all branding customizations including Plymouth, icons, and wallpapers

set -e

echo "=== Applying CI-OS Branding Customization ==="

# Copy Plymouth theme
echo "Installing CI-OS Plymouth theme..."
mkdir -p /usr/share/plymouth/themes/ci-os-theme
cp /tmp/ci-os-customization/plymouth/ci-os-theme/* /usr/share/plymouth/themes/ci-os-theme/
chmod 644 /usr/share/plymouth/themes/ci-os-theme/*

# Set CI-OS as default Plymouth theme
echo "Setting CI-OS Plymouth theme as default..."
plymouth-set-default-theme ci-os-theme
update-initramfs -u

# Copy icon replacements
echo "Installing CI-OS icon replacements..."
cp -r /tmp/ci-os-customization/icons/* /usr/share/icons/

# Update icon cache
echo "Updating icon cache..."
gtk-update-icon-cache /usr/share/icons/hicolor/ || true

# Copy wallpapers
echo "Installing CI-OS wallpapers..."
mkdir -p /usr/share/backgrounds
cp /tmp/ci-os-customization/wallpapers/* /usr/share/backgrounds/

# Set CI-OS wallpaper as default
echo "Setting default wallpaper..."
gsettings set org.gnome.desktop.background picture-uri "file:///usr/share/backgrounds/ci-os-wallpaper.svg"
gsettings set org.gnome.desktop.background picture-uri-dark "file:///usr/share/backgrounds/ci-os-wallpaper.svg"

# Create CI-OS release info
echo "Creating CI-OS release information..."
cat > /etc/os-release << 'EOF'
NAME="CI-OS"
VERSION="24.04 LTS"
ID=ci-os
ID_LIKE=ubuntu
PRETTY_NAME="CI-OS 24.04 LTS"
VERSION_ID="24.04"
HOME_URL="https://github.com/companionintelligence/CI-OS"
SUPPORT_URL="https://github.com/companionintelligence/CI-OS/issues"
BUG_REPORT_URL="https://github.com/companionintelligence/CI-OS/issues"
PRIVACY_POLICY_URL="https://github.com/companionintelligence/CI-OS"
VERSION_CODENAME=noble
UBUNTU_CODENAME=noble
EOF

# Update LSB release info
echo "Updating LSB release info..."
cat > /etc/lsb-release << 'EOF'
DISTRIB_ID=CI-OS
DISTRIB_RELEASE=24.04
DISTRIB_CODENAME=noble
DISTRIB_DESCRIPTION="CI-OS 24.04 LTS"
EOF

# Create CI-OS issue file (shown in terminal login)
cat > /etc/issue << 'EOF'
CI-OS 24.04 LTS \n \l

EOF

# Create CI-OS MOTD
cat > /etc/motd << 'EOF'

  ____  ___       ___   ____  
 / ___|_ _|     / _ \ / ___| 
| |    | |_____| | | \___ \ 
| |___ | |_____| |_| |___) |
 \____|___|     \___/|____/ 
                            
Welcome to CI-OS - Custom Linux Distribution for AI Companions

 * Documentation:  https://github.com/companionintelligence/CI-OS
 * Support:        https://github.com/companionintelligence/CI-OS/issues

EOF

# Create desktop entry for CI-OS Info (replaces Ubuntu's)
cat > /usr/share/applications/ci-os-about.desktop << 'EOF'
[Desktop Entry]
Name=About CI-OS
Comment=Learn more about your CI-OS system
Keywords=about;information;os;
Exec=gnome-control-center info-overview
Icon=distributor-logo
Terminal=false
Type=Application
Categories=System;Settings;
StartupNotify=true
EOF

# Hide original Ubuntu applications that show Ubuntu branding
mkdir -p /usr/share/applications
echo "Hidden=true" >> /usr/share/applications/ubuntu-desktop-guide.desktop || true
echo "Hidden=true" >> /usr/share/applications/ubuntu-help.desktop || true

# Update help system to show CI-OS information
if [ -d /usr/share/help/C/ubuntu-help ]; then
    mv /usr/share/help/C/ubuntu-help /usr/share/help/C/ubuntu-help.bak || true
fi

# Update GRUB distributor name
sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="CI-OS"/' /etc/default/grub

echo "✅ CI-OS branding customization completed successfully!"
echo "📝 Remember to run 'update-grub' after this script completes."