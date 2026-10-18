#!/usr/bin/env bash
#=============================================================================
# CI-OS Repository Setup Helper
# Automates setting up a reprepro-based package repository
#
# Usage:
#   sudo ./backends/ubuntu/iso/scripts/setup-repository.sh [repo_root]
#
# Default repo root: /srv/packages.ci.computer
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

set -euo pipefail

REPO_ROOT="${1:-/srv/packages.ci.computer}"
GPG_KEY_ID="${CI_OS_GPG_KEY:-}"

echo "======================================"
echo "  CI-OS Repository Setup"
echo "======================================"
echo
echo "Repository root: $REPO_ROOT"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check for reprepro
if ! command -v reprepro &> /dev/null; then
    echo "[*] Installing reprepro..."
    apt-get update
    apt-get install -y reprepro
fi

# Check for nginx
if ! command -v nginx &> /dev/null; then
    echo "[*] Installing nginx..."
    apt-get install -y nginx
fi

# Create directory structure
echo "[*] Creating directory structure..."
mkdir -p "$REPO_ROOT"/{conf,db,dists,pool,incoming}

# Setup GPG key if not provided
if [[ -z "$GPG_KEY_ID" ]]; then
    echo
    echo "[!] No GPG key ID provided (CI_OS_GPG_KEY not set)"
    echo "[*] You need to generate a GPG key for signing:"
    echo
    echo "    gpg --full-generate-key"
    echo "    # Select: RSA and RSA, 4096 bits"
    echo "    # Name: CI-OS Package Repository"
    echo "    # Email: packages@ci.computer"
    echo
    echo "    Then export the public key:"
    echo "    gpg --armor --export packages@ci.computer > $REPO_ROOT/ci-archive-keyring.asc"
    echo
    echo "    And set the key ID:"
    echo "    export CI_OS_GPG_KEY=YOUR_KEY_ID"
    echo "    ./backends/ubuntu/iso/scripts/setup-repository.sh"
    echo
    exit 1
fi

# Create reprepro configuration
echo "[*] Creating reprepro configuration..."
cat > "$REPO_ROOT/conf/distributions" << EOF
Origin: CI-OS
Label: CI-OS
Codename: resolute
Architectures: amd64 all
Components: main
Description: CI-OS Official Package Repository
SignWith: $GPG_KEY_ID
EOF

# Set permissions
echo "[*] Setting permissions..."
chown -R root:root "$REPO_ROOT"
chmod -R 755 "$REPO_ROOT"
chmod 700 "$REPO_ROOT/conf"
chmod 700 "$REPO_ROOT/db"

# Verify that the GPG key exists before exporting
if ! gpg --list-keys "$GPG_KEY_ID" > /dev/null 2>&1; then
    echo "Error: GPG key '$GPG_KEY_ID' not found in keyring. Aborting."
    exit 1
fi

# Export to a temporary file first to avoid creating empty keyrings
tmp_keyring="$(mktemp)"
if ! gpg --armor --export "$GPG_KEY_ID" > "$tmp_keyring"; then
    echo "Error: Failed to export GPG key '$GPG_KEY_ID'. Aborting."
    rm -f "$tmp_keyring"
    exit 1
fi

# Ensure the exported key is non-empty before using it
if [[ ! -s "$tmp_keyring" ]]; then
    echo "Error: Exported key for '$GPG_KEY_ID' is empty. Aborting."
    rm -f "$tmp_keyring"
    exit 1
fi

mv "$tmp_keyring" "$REPO_ROOT/ci-archive-keyring.asc"
gpg --dearmor < "$REPO_ROOT/ci-archive-keyring.asc" > "$REPO_ROOT/ci-archive-keyring.gpg"

# Create nginx configuration
echo "[*] Creating nginx configuration..."
cat > "/etc/nginx/sites-available/packages.ci.computer" << EOFNGINX
server {
    listen 80;
    listen [::]:80;
    server_name packages.ci.computer;
    
    # Redirect to HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name packages.ci.computer;
    
    # SSL configuration (certbot will configure this)
    # ssl_certificate /etc/letsencrypt/live/packages.ci.computer/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/packages.ci.computer/privkey.pem;
    
    root $REPO_ROOT;
    
    location / {
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
    }
    
    # Deny access to internal directories
    location ~ /(db|conf|incoming)/ {
        deny all;
        return 404;
    }
    
    # Public key download
    location = /ci-archive-keyring.asc {
        alias $REPO_ROOT/ci-archive-keyring.asc;
    }
    
    location = /ci-archive-keyring.gpg {
        alias $REPO_ROOT/ci-archive-keyring.gpg;
    }
}
EOFNGINX

# Enable nginx site
if [[ ! -f "/etc/nginx/sites-enabled/packages.ci.computer" ]]; then
    ln -s /etc/nginx/sites-available/packages.ci.computer /etc/nginx/sites-enabled/
    echo "[*] Nginx site enabled"
fi

# Test nginx config
nginx -t

echo
echo "[+] Repository setup complete!"
echo
echo "Next steps:"
echo "1. Configure SSL certificate:"
echo "   sudo certbot --nginx -d packages.ci.computer"
echo
echo "2. Add packages to repository:"
echo "   sudo reprepro -b $REPO_ROOT includedeb resolute /path/to/package.deb"
echo
echo "3. Reload nginx:"
echo "   sudo systemctl reload nginx"
echo
echo "4. Client configuration (add to sources.list.d):"
echo "   deb [signed-by=/usr/share/keyrings/ci-archive-keyring.gpg] https://packages.ci.computer/ubuntu resolute main"
echo
echo "Public key available at:"
echo "https://packages.ci.computer/ci-archive-keyring.asc"
echo
