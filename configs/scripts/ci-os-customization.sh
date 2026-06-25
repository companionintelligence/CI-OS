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
# Allow Docker bridge networks to reach host-side Ollama. The Hub and marketplace
# apps run in containers and talk to Ollama via host.docker.internal, which Docker
# maps (host-gateway) to the docker0 bridge gateway 172.17.0.1. Without an allow
# rule, `default deny incoming` drops that hairpin and the Hub reports "Ollama not
# detected" (connection timeout).
#
# Scoped two ways for least privilege:
#  - destination 172.17.0.1: only container-originated traffic targets the bridge
#    gateway, so LAN/VPC hosts (which would hit the appliance's own IP) can't match
#    these rules even if their addresses fall in the source ranges below.
#  - port 11434 only: no other host ports are opened.
#
# Source ranges:
#  - 172.16.0.0/12: default docker bridge (172.17) and the Hub stack network (172.18).
#  - 10.128.0.0/9: marketplace app subnets. CI-Hub's SubnetManagerService (in the
#    CI-Hub repo, packages/backend/src/modules/network/subnet-manager.service.ts)
#    allocates these from 10.128.10.0/24 up to 10.254.254.0/24 (STARTING_OCTET_2=128,
#    MAX_OCTET_VALUE=254). If that allocator range changes, widen this rule to match
#    or apps lose host.docker.internal.
ufw allow in from 172.16.0.0/12 to 172.17.0.1 port 11434 proto tcp comment 'docker bridge -> host Ollama'
ufw allow in from 10.128.0.0/9 to 172.17.0.1 port 11434 proto tcp comment 'marketplace app subnets -> host Ollama'

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
pip3 install docker-compose ansible

# Install Node.js packages
npm install -g pm2 yarn pnpm

# Clean up
apt-get autoremove -y
apt-get autoclean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*

echo "=== CI OS Customization Completed ==="
