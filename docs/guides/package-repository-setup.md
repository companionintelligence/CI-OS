# CI-OS Package Repository Setup Guide

Guide for setting up and maintaining the CI-OS package repository.

© Companion Intelligence — Lifescope Inc

---

## Table of Contents

1. [Overview](#overview)
2. [Repository Architecture](#repository-architecture)
3. [Setup with Reprepro](#setup-with-reprepro)
4. [Setup with Aptly](#setup-with-aptly)
5. [Package Building](#package-building)
6. [Publishing Packages](#publishing-packages)
7. [Client Configuration](#client-configuration)
8. [Automation](#automation)

---

## Overview

The CI-OS package repository (`packages.ci.computer`) hosts:

- `companion-os-base` - Base system package
- `companion-os-keyring` - Repository GPG keyring
- `companion-agents` - AI agent framework
- `companion-memory` - Memory system
- `companion-os-amd-meta` - AMD/ROCm meta-package (future)

### Goals

- Signed, trusted package distribution
- Update mechanism for post-install systems
- Version control and rollback capability
- Snapshot-based deployment strategy

---

## Repository Architecture

### Directory Structure

```
/srv/packages.ci.computer/
├── conf/
│   └── distributions     # Repository configuration
├── db/                   # Database (reprepro)
├── dists/                # Distribution metadata (public)
│   └── noble/
│       ├── main/
│       ├── Release
│       └── Release.gpg
├── pool/                 # Package files (public)
│   └── main/
└── incoming/             # Upload staging
```

### Components

- **Distribution**: `noble` (Ubuntu 24.04)
- **Component**: `main`
- **Architecture**: `amd64`, `all`

---

## Setup with Reprepro

Reprepro is simpler and suitable for basic repositories.

### 1. Install Reprepro

```bash
sudo apt-get install reprepro nginx
```

### 2. Create Repository Structure

```bash
sudo mkdir -p /srv/packages.ci.computer/{conf,incoming}
cd /srv/packages.ci.computer
```

### 3. Generate GPG Key

```bash
# Generate dedicated repository key
gpg --full-generate-key

# Select:
# - Type: RSA and RSA
# - Size: 4096 bits
# - Validity: 2 years (or as needed)
# - Name: CI-OS Package Repository
# - Email: packages@ci.computer

# Export public key
gpg --armor --export packages@ci.computer > ci-archive-keyring.asc

# Note the key ID for later
gpg --list-keys packages@ci.computer
```

### 4. Configure Reprepro

Create `/srv/packages.ci.computer/conf/distributions`:

```
Origin: CI-OS
Label: CI-OS
Codename: noble
Architectures: amd64 all
Components: main
Description: CI-OS Official Package Repository
SignWith: YOUR_GPG_KEY_ID
```

Replace `YOUR_GPG_KEY_ID` with your GPG key ID.

### 5. Configure Nginx

Create `/etc/nginx/sites-available/packages.ci.computer`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name packages.ci.computer;
    
    # Redirect to HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name packages.ci.computer;
    
    # SSL configuration
    ssl_certificate /etc/letsencrypt/live/packages.ci.computer/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/packages.ci.computer/privkey.pem;
    
    root /srv/packages.ci.computer;
    
    location / {
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
    }
    
    location ~ /(db|conf|incoming)/ {
        deny all;
        return 404;
    }
    
    # Public key download
    location = /ci-archive-keyring.asc {
        alias /srv/packages.ci.computer/ci-archive-keyring.asc;
    }
}
```

Enable site:

```bash
sudo ln -s /etc/nginx/sites-available/packages.ci.computer /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### 6. Get SSL Certificate

```bash
sudo apt-get install certbot python3-certbot-nginx
sudo certbot --nginx -d packages.ci.computer
```

### 7. Add Package to Repository

```bash
cd /srv/packages.ci.computer
reprepro includedeb noble /path/to/package.deb
```

### 8. Update Repository

```bash
reprepro export
```

---

## Setup with Aptly

Aptly is more feature-rich with snapshot support.

### 1. Install Aptly

```bash
# Import Aptly GPG key into a dedicated keyring
sudo mkdir -p /usr/share/keyrings
wget -qO- https://www.aptly.info/pubkey.txt | sudo gpg --dearmor -o /usr/share/keyrings/aptly-archive-keyring.gpg

# Configure Aptly APT source using the dedicated keyring
echo "deb [signed-by=/usr/share/keyrings/aptly-archive-keyring.gpg] http://repo.aptly.info/ squeeze main" | sudo tee /etc/apt/sources.list.d/aptly.list

sudo apt-get update
sudo apt-get install aptly
```

### 2. Configure Aptly

Create `~/.aptly.conf`:

```json
{
  "rootDir": "/srv/packages.ci.computer/aptly",
  "downloadConcurrency": 4,
  "downloadSpeedLimit": 0,
  "architectures": ["amd64", "all"],
  "dependencyFollowSuggests": false,
  "dependencyFollowRecommends": false,
  "dependencyFollowAllVariants": false,
  "dependencyFollowSource": false,
  "dependencyVerboseResolve": false,
  "gpgDisableSign": false,
  "gpgDisableVerify": false,
  "gpgProvider": "gpg",
  "downloadSourcePackages": false,
  "skipLegacyPool": true,
  "ppaDistributorID": "ci-os",
  "ppaCodename": "noble",
  "FileSystemPublishEndpoints": {
    "public": {
      "rootDir": "/srv/packages.ci.computer/public"
    }
  }
}
```

### 3. Create Repository

```bash
# Create local repository
aptly repo create -distribution=noble -component=main ci-os-noble

# Add packages
aptly repo add ci-os-noble /path/to/*.deb

# Create snapshot
aptly snapshot create ci-os-noble-$(date +%Y%m%d) from repo ci-os-noble

# Publish snapshot
aptly publish snapshot -distribution=noble ci-os-noble-$(date +%Y%m%d) filesystem:public:
```

### 4. Configure Nginx

Same as reprepro, but point to `/srv/packages.ci.computer/public/`.

### 5. Update Workflow with Snapshots

```bash
# Add new packages
aptly repo add ci-os-noble /path/to/new-packages/*.deb

# Create new snapshot
DATE=$(date +%Y%m%d)
aptly snapshot create ci-os-noble-$DATE from repo ci-os-noble

# Switch published snapshot
aptly publish switch noble filesystem:public: ci-os-noble-$DATE

# Rollback if needed
aptly publish switch noble filesystem:public: ci-os-noble-PREVIOUS_DATE
```

---

## Package Building

### Build .deb Packages

Using the repository scripts:

```bash
# Build all packages
./backends/ubuntu/iso/scripts/build-packages.sh ./output/packages

# Built packages appear in ./output/packages/
ls -lh ./output/packages/*.deb
```

### Add to Repository

**With reprepro:**

```bash
cd /srv/packages.ci.computer
for deb in /path/to/output/packages/*.deb; do
    reprepro includedeb noble "$deb"
done
```

**With aptly:**

```bash
aptly repo add ci-os-noble /path/to/output/packages/*.deb
DATE=$(date +%Y%m%d)
aptly snapshot create ci-os-noble-$DATE from repo ci-os-noble
aptly publish switch noble filesystem:public: ci-os-noble-$DATE
```

---

## Publishing Packages

### Manual Publishing

1. **Build packages** on development machine
2. **Test packages** locally
3. **Upload to repository server**:
   ```bash
   scp *.deb user@packages.ci.computer:/srv/packages.ci.computer/incoming/
   ```
4. **Add to repository** on server:
   ```bash
   ssh user@packages.ci.computer
   cd /srv/packages.ci.computer
   reprepro processincoming incoming
   ```

### Automated Publishing (GitHub Actions)

Create `.github/workflows/publish-packages.yml`:

```yaml
name: Publish Packages

on:
  push:
    paths:
      - 'packages/**'
  workflow_dispatch:

jobs:
  build-and-publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Build packages
        run: |
          ./backends/ubuntu/iso/scripts/build-packages.sh ./output/packages
      
      - name: Upload to repository
        env:
          SSH_KEY: ${{ secrets.REPO_SSH_KEY }}
          REPO_HOST: ${{ secrets.REPO_HOST }}
        run: |
          # Setup SSH
          mkdir -p ~/.ssh
          echo "$SSH_KEY" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          
          # Upload packages
          scp -o StrictHostKeyChecking=no \
            ./output/packages/*.deb \
            ci-os@$REPO_HOST:/srv/packages.ci.computer/incoming/
          
          # Process on server
          ssh ci-os@$REPO_HOST "cd /srv/packages.ci.computer && reprepro processincoming incoming"
```

---

## Client Configuration

### Create Keyring Package

The `companion-os-keyring` package should install:

1. **GPG key** to `/usr/share/keyrings/ci-archive-keyring.gpg`
2. **APT source** to `/etc/apt/sources.list.d/companion-intelligence.list`

#### Build Keyring Package

```bash
# Package structure
mkdir -p backends/ubuntu/packages/companion-os-keyring/usr/share/keyrings
mkdir -p backends/ubuntu/packages/companion-os-keyring/etc/apt/sources.list.d

# Convert ASCII key to GPG format
gpg --dearmor < ci-archive-keyring.asc > \
  backends/ubuntu/packages/companion-os-keyring/usr/share/keyrings/ci-archive-keyring.gpg

# Create APT source
cat > backends/ubuntu/packages/companion-os-keyring/etc/apt/sources.list.d/companion-intelligence.list << 'EOF'
deb [signed-by=/usr/share/keyrings/ci-archive-keyring.gpg] https://packages.ci.computer/ubuntu noble main
EOF

# Build package
./backends/ubuntu/iso/scripts/build-packages.sh
```

### Install on Client

```bash
# Manual installation
wget https://packages.ci.computer/pool/main/companion-os-keyring_1.0.0_all.deb
sudo dpkg -i companion-os-keyring_1.0.0_all.deb

# Update package lists
sudo apt update

# Install CI-OS packages
sudo apt install companion-os-base
```

### Bake into ISO

Add to `backends/ubuntu/chroot/customize-chroot.sh`:

```bash
# Copy keyring package into chroot
copy_to_chroot "$REPO_ROOT/output/backends/ubuntu/packages/companion-os-keyring_1.0.0_all.deb" \
  "/tmp/companion-os-keyring.deb"

# Install keyring
chroot_exec "dpkg -i /tmp/companion-os-keyring.deb"
chroot_exec "apt update"

# Install other CI-OS packages
chroot_exec "apt install -y companion-os-base"
```

---

## Automation

### Update Script

Create `/usr/local/bin/update-ci-os-repo`:

```bash
#!/bin/bash
#=============================================================================
# CI-OS Repository Update Script
# Updates repository with new packages
#=============================================================================

set -euo pipefail

REPO_ROOT="/srv/packages.ci.computer"
INCOMING="$REPO_ROOT/incoming"

cd "$REPO_ROOT"

echo "[*] Processing incoming packages..."
reprepro processincoming incoming

echo "[*] Exporting repository..."
reprepro export

echo "[+] Repository updated successfully"
echo "[*] Repository statistics:"
reprepro list noble
```

### Monitoring

Monitor repository access:

```bash
# Log analysis
sudo tail -f /var/log/nginx/access.log | grep packages.ci.computer

# Most downloaded packages
sudo awk '{print $7}' /var/log/nginx/access.log | \
  grep '\.deb$' | \
  sort | uniq -c | sort -rn | head -20
```

---

## Security Best Practices

### GPG Key Management

1. **Store master key offline** (encrypted USB drive)
2. **Use subkeys** for daily signing
3. **Set expiration dates** (2 years recommended)
4. **Revocation certificate** stored separately

### Key Rotation

When rotating keys:

1. Generate new key
2. Sign new key with old key (trust chain)
3. Update repository configuration
4. Release updated keyring package
5. Keep old key valid for transition period (3 months)

### Repository Security

```bash
# Restrict permissions
sudo chown -R ci-os:ci-os /srv/packages.ci.computer
sudo chmod -R 755 /srv/packages.ci.computer
sudo chmod 700 /srv/packages.ci.computer/conf
sudo chmod 700 /srv/packages.ci.computer/db

# Firewall
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

---

## Troubleshooting

### Clients Can't Connect

**Check DNS**:
```bash
dig packages.ci.computer
```

**Check SSL**:
```bash
curl -I https://packages.ci.computer
```

### GPG Signature Verification Fails

**Re-sign repository**:
```bash
cd /srv/packages.ci.computer
reprepro export
```

### Package Not Appearing

**Check reprepro database**:
```bash
reprepro list noble
```

**Reprocess package**:
```bash
reprepro remove noble package-name
reprepro includedeb noble /path/to/package.deb
```

---

## Maintenance

### Regular Tasks

**Daily**:
- Monitor access logs
- Check disk space

**Weekly**:
- Review package versions
- Test repository on fresh install

**Monthly**:
- Update SSL certificates (automatic with certbot)
- Backup repository database

**Quarterly**:
- Review GPG key expiration
- Security audit

### Backup Strategy

```bash
#!/bin/bash
# Backup script

BACKUP_DIR="/backup/packages"
DATE=$(date +%Y%m%d)

# Backup repository database
tar -czf "$BACKUP_DIR/repo-db-$DATE.tar.gz" \
  /srv/packages.ci.computer/db \
  /srv/packages.ci.computer/conf

# Backup pool (optional - can be regenerated)
rsync -av /srv/packages.ci.computer/pool/ \
  "$BACKUP_DIR/pool-$DATE/"

# Keep last 30 days
find "$BACKUP_DIR" -name "repo-db-*.tar.gz" -mtime +30 -delete
```

---

## Resources

- [Reprepro Documentation](https://mirrorer.alioth.debian.org/)
- [Aptly Documentation](https://www.aptly.info/doc/overview/)
- [Debian Repository Format](https://wiki.debian.org/DebianRepository/Format)
- [APT signed-by](https://manpages.ubuntu.com/manpages/noble/man5/sources.list.5.html)

---

© Companion Intelligence — Lifescope Inc
