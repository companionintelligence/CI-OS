#!/bin/bash
# Quick Start - CI OS Headless Setup Testing
# This script helps you quickly test the headless setup system

set -e

echo "================================================"
echo "CI OS Headless Setup - Quick Start Test"
echo "================================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (sudo ./quick-start.sh)"
    exit 1
fi

echo "Step 1: Installing dependencies..."
apt-get update -qq
apt-get install -y python3 python3-pip python3-flask dnsmasq iptables network-manager wireless-tools iw

echo ""
echo "Step 2: Running installation..."
./install.sh

echo ""
echo "Step 3: Running tests..."
./test-headless-setup.sh

echo ""
echo "================================================"
echo "Installation Complete!"
echo "================================================"
echo ""
echo "To test the headless setup:"
echo "  1. Remove setup flag: sudo rm -f /var/lib/ci-os/setup-complete"
echo "  2. Start service: sudo systemctl start ci-os-headless-setup.service"
echo "  3. Connect to 'CI-OS-Setup' WiFi from another device"
echo "  4. Open browser (captive portal should appear)"
echo ""
echo "To monitor logs:"
echo "  sudo journalctl -u ci-os-headless-setup.service -f"
echo "  sudo tail -f /var/log/ci-os-headless-setup.log"
echo ""
echo "To stop testing:"
echo "  sudo systemctl stop ci-os-headless-setup.service"
echo ""
