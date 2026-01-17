#!/bin/bash
# CI OS Headless Setup - Installation Script
# Installs and configures the headless setup system

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/share/ci-os-headless-setup"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

echo "=== Installing CI OS Headless Setup System ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Install required packages
echo "Installing required packages..."
apt-get update
apt-get install -y \
    python3 \
    python3-pip \
    python3-flask \
    dnsmasq \
    iptables \
    network-manager \
    wireless-tools

# Create installation directories
echo "Creating installation directories..."
mkdir -p "$INSTALL_DIR/web"
mkdir -p "$INSTALL_DIR/lib"
mkdir -p /var/lib/ci-os
mkdir -p /var/log

# Copy main daemon script
echo "Installing daemon script..."
cp "$SCRIPT_DIR/ci-os-headless-setup.sh" "$BIN_DIR/"
chmod +x "$BIN_DIR/ci-os-headless-setup.sh"

# Copy web server files
echo "Installing web server..."
cp "$SCRIPT_DIR/web/captive-portal.py" "$INSTALL_DIR/web/"
chmod +x "$INSTALL_DIR/web/captive-portal.py"

# Install systemd service
echo "Installing systemd service..."
cp "$SCRIPT_DIR/systemd/ci-os-headless-setup.service" "$SYSTEMD_DIR/"

# Reload systemd
systemctl daemon-reload

# Enable the service (will run on next boot if setup not complete)
systemctl enable ci-os-headless-setup.service

# Configure dnsmasq
echo "Configuring dnsmasq..."
# Ensure dnsmasq configuration directory exists
mkdir -p /etc/dnsmasq.d

# Enable and start dnsmasq (will be configured by the daemon when needed)
systemctl enable dnsmasq || true

# Configure NetworkManager to use dnsmasq
if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
    if ! grep -q "dns=dnsmasq" /etc/NetworkManager/NetworkManager.conf; then
        echo "Configuring NetworkManager to use dnsmasq..."
        sed -i '/\[main\]/a dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf
    fi
fi

# Set permissions
chmod 755 "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR/web"
chmod 644 "$INSTALL_DIR/web/captive-portal.py"
chmod 755 "$BIN_DIR/ci-os-headless-setup.sh"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "The headless setup system has been installed and will run automatically"
echo "on first boot if no WiFi network is configured."
echo ""
echo "To test the setup manually:"
echo "  sudo systemctl start ci-os-headless-setup.service"
echo ""
echo "To check status:"
echo "  sudo systemctl status ci-os-headless-setup.service"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u ci-os-headless-setup.service -f"
echo "  sudo tail -f /var/log/ci-os-headless-setup.log"
echo ""
echo "To reset setup (for testing):"
echo "  sudo rm -f /var/lib/ci-os/setup-complete"
echo ""
