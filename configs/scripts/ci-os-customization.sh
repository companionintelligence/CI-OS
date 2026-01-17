#!/bin/bash
# CI OS Post-Installation Script
# This script runs during the Cubic chroot environment

set -e

echo "=== CI OS Customization Started ==="

# Update package lists
apt-get update

# Install additional packages not in the base list
apt-get install -y \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

# Add custom repositories
# Docker repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Visual Studio Code repository
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | tee /etc/apt/sources.list.d/vscode.list

# Update package lists with new repositories
apt-get update

# Install packages from new repositories
apt-get install -y docker-ce docker-ce-cli containerd.io code

# Configure system settings
# Set timezone
timedatectl set-timezone UTC

# Configure SSH
systemctl enable ssh
mkdir -p /etc/ssh/sshd_config.d
echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/ci-os.conf
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/ci-os.conf

# Configure firewall
ufw --force enable
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp

# Create CI OS user
useradd -m -s /bin/bash -G sudo,docker,adm cios
echo "cios:ci0s2024!" | chpasswd

# Configure GRUB
sed -i 's/GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="CI OS"/' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub

# Install custom branding (this will be done via file copying in Cubic)
# Files will be copied from the assets directory

# Configure desktop environment
# Set default wallpaper
gsettings set org.gnome.desktop.background picture-uri "file:///usr/share/backgrounds/ci-os-wallpaper.png"
gsettings set org.gnome.desktop.background picture-uri-dark "file:///usr/share/backgrounds/ci-os-wallpaper.png"

# Install Python packages
pip3 install --upgrade pip
pip3 install docker-compose ansible flask

# Install Node.js packages
npm install -g pm2 yarn pnpm

# Install headless WiFi setup system
echo "=== Installing Headless Setup System ==="

# Install required packages for headless setup
apt-get install -y \
    python3-flask \
    dnsmasq \
    iptables \
    network-manager \
    wireless-tools \
    iw

# Copy and install headless setup system
if [ -d "/tmp/headless-setup" ]; then
    cd /tmp/headless-setup
    ./install.sh
    
    # Verify installation
    if [ -f /usr/local/bin/ci-os-headless-setup.sh ]; then
        echo "✓ Headless setup installed successfully"
        systemctl enable ci-os-headless-setup.service
    else
        echo "✗ Headless setup installation failed"
    fi
else
    echo "⚠ Headless setup directory not found, skipping"
fi

# Clean up
apt-get autoremove -y
apt-get autoclean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*

echo "=== CI OS Customization Completed ==="
