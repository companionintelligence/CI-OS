# Ubuntu Desktop Wallpaper Replacement Guide

This document describes the process for replacing the default desktop wallpaper with a custom image in Ubuntu Linux systems.

## Overview

The desktop wallpaper is the background image displayed on the desktop. This guide covers setting a custom wallpaper system-wide so it applies to all users (existing and new).

## Wallpaper Location

The system wallpaper is stored in:
```
/usr/share/backgrounds/
```

Default wallpapers are typically stored here, and custom wallpapers should be placed in this directory as well.

## Prerequisites

- Root/sudo access (required for system-level file modifications)
- Custom wallpaper image file (PNG, JPG, JPEG, or WEBP format recommended)
- Basic understanding of Linux file system

## Step-by-Step Replacement Process

### Step 1: Prepare Your Custom Wallpaper

Ensure your custom wallpaper is ready:
- **Format**: PNG, JPG, JPEG, or WEBP
- **Recommended resolution**: 1920x1080 or higher for best quality
- **Location**: Have the wallpaper file accessible (e.g., `/home/user/custom-wallpaper.png`)

### Step 2: Create Backup

**IMPORTANT**: Always create a backup before modifying system files.

```bash
# Create backup directory with timestamp
sudo mkdir -p /usr/share/backgrounds/ubuntu-backup-$(date +%Y%m%d-%H%M%S)

# Store backup directory path
BACKUP_DIR=$(ls -d /usr/share/backgrounds/ubuntu-backup-* 2>/dev/null | tail -1)

# Backup existing wallpaper if it exists
if [[ -f /usr/share/backgrounds/ci-os-wallpaper.png ]]; then
    sudo cp /usr/share/backgrounds/ci-os-wallpaper.png "$BACKUP_DIR/ci-os-wallpaper.png.bak"
fi
```

### Step 3: Copy Wallpaper to System Directory

Copy your custom wallpaper to the system backgrounds directory:

```bash
# Copy wallpaper to system directory
sudo cp /path/to/your/custom-wallpaper.png /usr/share/backgrounds/ci-os-wallpaper.png
sudo chmod 644 /usr/share/backgrounds/ci-os-wallpaper.png
```

**Note**: You can use any filename, but `ci-os-wallpaper.png` is recommended for consistency.

### Step 4: Set Wallpaper for Current User

Set the wallpaper for the current user using gsettings:

```bash
# Get the current user (not root)
ACTUAL_USER=$(who | awk 'NR==1{print $1}')

# Set wallpaper as the actual user
sudo -u "$ACTUAL_USER" bash <<EOF
export DISPLAY=:0
export XAUTHORITY=\$HOME/.Xauthority
gsettings set org.gnome.desktop.background picture-uri "file:///usr/share/backgrounds/ci-os-wallpaper.png"
gsettings set org.gnome.desktop.background picture-uri-dark "file:///usr/share/backgrounds/ci-os-wallpaper.png"
EOF
```

### Step 5: Set System-Wide Defaults for New Users

Configure system-wide defaults so new users automatically get the custom wallpaper:

```bash
# Create dconf configuration directory
sudo mkdir -p /etc/dconf/db/local.d

# Create wallpaper configuration file
sudo cat > /etc/dconf/db/local.d/00-wallpaper <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/ci-os-wallpaper.png'
picture-uri-dark='file:///usr/share/backgrounds/ci-os-wallpaper.png'
EOF

# Update dconf database
sudo dconf update
```

### Step 6: Apply Changes

For the changes to take effect:

1. **Current user**: The wallpaper should change immediately if gsettings was successful
   - If not, log out and log back in

2. **Existing users**: They may need to log out and log back in to see the change

3. **New users**: Will automatically get the custom wallpaper when their account is created

## Verification

After applying changes, verify the wallpaper was set:

```bash
# Check wallpaper file exists
ls -la /usr/share/backgrounds/ci-os-wallpaper.png

# Check current user's wallpaper setting
gsettings get org.gnome.desktop.background picture-uri

# Check system-wide defaults
cat /etc/dconf/db/local.d/00-wallpaper
```

## Restoring Original Wallpaper

To restore the original wallpaper from backup:

```bash
# Find your backup directory
BACKUP_DIR=$(ls -d /usr/share/backgrounds/ubuntu-backup-* 2>/dev/null | tail -1)

# Restore the original wallpaper
if [[ -f "$BACKUP_DIR/ci-os-wallpaper.png.bak" ]]; then
    sudo cp "$BACKUP_DIR/ci-os-wallpaper.png.bak" /usr/share/backgrounds/ci-os-wallpaper.png
    
    # Reset for current user
    ACTUAL_USER=$(who | awk 'NR==1{print $1}')
    sudo -u "$ACTUAL_USER" bash <<EOF
export DISPLAY=:0
export XAUTHORITY=\$HOME/.Xauthority
gsettings reset org.gnome.desktop.background picture-uri
gsettings reset org.gnome.desktop.background picture-uri-dark
EOF
    
    # Update dconf
    sudo dconf update
fi
```

## Implementation in Ubuntu Distro

To implement this in your custom Ubuntu distribution:

### Option 1: Post-Install Script

Create a script that runs during or after installation:

```bash
#!/bin/bash
# replace-wallpaper.sh

WALLPAPER="/path/to/custom-wallpaper.png"
DEST_WALLPAPER="/usr/share/backgrounds/ci-os-wallpaper.png"

# Copy wallpaper
cp "$WALLPAPER" "$DEST_WALLPAPER"
chmod 644 "$DEST_WALLPAPER"

# Set system-wide defaults
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-wallpaper <<EOF
[org/gnome/desktop/background]
picture-uri='file://$DEST_WALLPAPER'
picture-uri-dark='file://$DEST_WALLPAPER'
EOF

# Update dconf
dconf update
```

### Option 2: Custom Package

Create a Debian package that:
1. Includes your custom wallpaper
2. Copies it to `/usr/share/backgrounds/` during package installation
3. Sets dconf defaults in postinst script

### Option 3: Live ISO Modification

Modify the Ubuntu ISO before creating your distribution:
1. Mount the ISO
2. Copy wallpaper to the filesystem
3. Set dconf defaults
4. Rebuild the ISO

## Troubleshooting

### Wallpaper doesn't appear for current user

1. **Check gsettings**: Ensure gsettings is available and working
   ```bash
   gsettings list-schemas | grep desktop.background
   ```

2. **Check DISPLAY**: Ensure DISPLAY is set correctly
   ```bash
   echo $DISPLAY
   ```

3. **Try manual setting**: Set it manually from Settings > Appearance > Background

4. **Log out and log back in**: This is the most reliable method

### Wallpaper doesn't appear for new users

1. **Check dconf configuration**: Verify the configuration file exists
   ```bash
   cat /etc/dconf/db/local.d/00-wallpaper
   ```

2. **Update dconf database**: Force update the database
   ```bash
   sudo dconf update
   ```

3. **Check dconf locks**: Ensure there are no locks preventing the setting
   ```bash
   ls -la /etc/dconf/db/local.d/locks/
   ```

### Permission denied errors

- Ensure you're using `sudo` for all system directory operations
- Verify you have root access: `sudo -v`

## Files Modified

- `/usr/share/backgrounds/ci-os-wallpaper.png` - Custom wallpaper file
- `/etc/dconf/db/local.d/00-wallpaper` - System-wide wallpaper configuration
- User-specific gsettings (via dconf) - Current user's wallpaper preference

## Backup Location

Backups are stored in:
```
/usr/share/backgrounds/ubuntu-backup-YYYYMMDD-HHMMSS/
```

## Notes

- The wallpaper is set for both light and dark modes (`picture-uri` and `picture-uri-dark`)
- Changes persist across reboots unless system updates replace the wallpaper
- Individual users can still change their wallpaper manually if desired
- The system-wide default only applies to new users; existing users keep their current wallpaper until they log out/in
- Consider creating a custom wallpaper package for easier distribution

## Date Created

January 23, 2025

## Example Implementation

On this system, the wallpaper was replaced using:
- Source wallpaper: `/home/companion/devel/background.png` (2048x1152 PNG)
- Destination: `/usr/share/backgrounds/ci-os-wallpaper.png`
- Backup location: `/usr/share/backgrounds/ubuntu-backup-20260123-163122/`
- System-wide defaults: Configured via `/etc/dconf/db/local.d/00-wallpaper`
- Status: Successfully replaced
