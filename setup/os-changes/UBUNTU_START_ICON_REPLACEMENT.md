# Ubuntu Start Icon Replacement Guide

This document describes the process for replacing the Ubuntu start icon (Activities button/app grid icon) with a custom icon in Ubuntu Linux systems.

## Overview

The Ubuntu start icon is the icon that appears in the GNOME Shell Activities button (typically in the top-left corner or dock). This icon is part of the Yaru icon theme and is stored as a symbolic SVG icon.

## Icon Location

The primary location for the Ubuntu start icon (Show Apps button in the dock) is:
```
/usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg
```

**Important Note**: The Ubuntu Dock extension uses `view-app-grid-ubuntu-symbolic.svg` which is a symlink pointing to `start-here-symbolic.svg` in the places directory. This is the actual icon file that needs to be replaced.

The icon is referenced by the Ubuntu Dock extension using the icon name pattern `view-app-grid-${sessionMode}-symbolic`, which resolves to `start-here-symbolic.svg`.

## Prerequisites

- Root/sudo access (required for system-level file modifications)
- Custom icon file (PNG or SVG format recommended)
- Basic understanding of Linux file system

## Step-by-Step Replacement Process

### Step 1: Prepare Your Custom Icon

Ensure your custom icon is ready:
- **Format**: PNG or SVG (PNG will be wrapped in SVG for compatibility)
- **Recommended size**: 1024x1024 pixels or higher for PNG
- **Location**: Have the icon file accessible (e.g., `/home/user/custom-icon.png`)

### Step 2: Create Backup

**IMPORTANT**: Always create a backup before modifying system files.

```bash
# Create backup directory with timestamp
sudo mkdir -p /usr/share/icons/ubuntu-backup-$(date +%Y%m%d-%H%M%S)/Yaru/scalable/places

# Store backup directory path
BACKUP_DIR=$(ls -d /usr/share/icons/ubuntu-backup-* 2>/dev/null | tail -1)

# Backup the original icon
sudo cp /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg \
       "$BACKUP_DIR/Yaru/scalable/places/start-here-symbolic.svg.bak"
```

### Step 3: Replace the Icon

**For SVG icons** (recommended): If your custom icon is already SVG, copy it directly:
```bash
sudo cp /path/to/your/custom-icon.svg /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg
sudo chmod 644 /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg
```

**For PNG icons**: If you have a PNG file, you have two options:

**Option A - Convert PNG to SVG wrapper:**
```bash
# Copy PNG to system pixmaps
sudo cp /path/to/your/custom-icon.png /usr/share/pixmaps/ci-os-activities-icon.png

# Create SVG wrapper
sudo cat > /tmp/start-here-symbolic.svg << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="24" height="24" viewBox="0 0 24 24">
  <image xlink:href="file:///usr/share/pixmaps/ci-os-activities-icon.png" width="24" height="24"/>
</svg>
EOF

# Replace the icon
sudo cp /tmp/start-here-symbolic.svg /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg
sudo chmod 644 /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg
```

**Option B - Use a tool to convert PNG to SVG** (better quality):
```bash
# Install imagemagick if needed: sudo apt install imagemagick
convert /path/to/your/custom-icon.png /tmp/start-here-symbolic.svg
sudo cp /tmp/start-here-symbolic.svg /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg
sudo chmod 644 /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg
```

### Step 4: Update Icon Cache

Update the icon cache so the system recognizes the change:

```bash
sudo gtk-update-icon-cache -f /usr/share/icons/Yaru
```

### Step 5: Apply Changes

For the changes to take effect, you may need to:

1. **Restart GNOME Shell** (if possible):
   ```bash
   # Press Alt+F2, type 'r' and press Enter
   # OR
   killall -SIGQUIT gnome-shell
   ```

2. **Log out and log back in** (most reliable method)

3. **Reboot the system** (if other methods don't work)

## Optional: Update Icon Theme Variants

Ubuntu includes multiple Yaru theme variants (Yaru-dark, Yaru-blue, etc.). If you want the custom icon to appear in all variants, repeat steps 3-6 for each variant:

```bash
# List available variants
ls -d /usr/share/icons/Yaru*/

# For each variant (example for Yaru-dark):
sudo cp /path/to/your/custom-icon.svg /usr/share/icons/Yaru-dark/scalable/places/start-here-symbolic.svg
sudo chmod 644 /usr/share/icons/Yaru-dark/scalable/places/start-here-symbolic.svg
sudo gtk-update-icon-cache -f /usr/share/icons/Yaru-dark
```

## Verification

After applying changes, verify the icon was replaced:

```bash
# Check file exists and has correct permissions
ls -la /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg

# View the first few lines to confirm content
head -5 /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg

# Verify the symlink still points to the correct location
readlink -f /usr/share/icons/Yaru/scalable/actions/view-app-grid-ubuntu-symbolic.svg
```

## Restoring Original Icon

To restore the original Ubuntu icon from backup:

```bash
# Find your backup directory
BACKUP_DIR=$(ls -d /usr/share/icons/ubuntu-backup-* 2>/dev/null | tail -1)

# Restore the original icon
sudo cp "$BACKUP_DIR/Yaru/scalable/places/start-here-symbolic.svg.bak" \
       /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg

# Update icon cache
sudo gtk-update-icon-cache -f /usr/share/icons/Yaru

# Restart GNOME Shell or log out/in
```

## Implementation in Ubuntu Distro

To implement this in your custom Ubuntu distribution:

### Option 1: Post-Install Script

Create a script that runs during or after installation:

```bash
#!/bin/bash
# replace-start-icon.sh

CUSTOM_ICON="/path/to/custom-icon.svg"  # Use SVG for best results
BACKUP_DIR="/usr/share/icons/ubuntu-backup-$(date +%Y%m%d-%H%M%S)"

# Create backup
mkdir -p "$BACKUP_DIR/Yaru/scalable/places"
cp /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg \
   "$BACKUP_DIR/Yaru/scalable/places/start-here-symbolic.svg.bak"

# Replace icon (for SVG)
cp "$CUSTOM_ICON" /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg
chmod 644 /usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg

# Update cache
gtk-update-icon-cache -f /usr/share/icons/Yaru
```

### Option 2: Custom Package

Create a Debian package that:
1. Includes your custom icon
2. Replaces the icon during package installation
3. Updates the icon cache in postinst script

### Option 3: Live ISO Modification

Modify the Ubuntu ISO before creating your distribution:
1. Mount the ISO
2. Replace the icon in the filesystem
3. Rebuild the ISO

## Troubleshooting

### Icon doesn't appear after replacement

1. **Check file permissions**: Ensure the icon file is readable
   ```bash
   ls -la /usr/share/icons/Yaru/scalable/actions/view-app-grid-symbolic.svg
   ```

2. **Verify icon cache**: Force rebuild the cache
   ```bash
   sudo rm /usr/share/icons/Yaru/icon-theme.cache
   sudo gtk-update-icon-cache -f /usr/share/icons/Yaru
   ```

3. **Check SVG syntax**: Ensure the SVG file is valid XML
   ```bash
   xmllint --noout /usr/share/icons/Yaru/scalable/actions/view-app-grid-symbolic.svg
   ```

4. **Restart GNOME Shell**: Try logging out and back in

### Icon appears distorted

- Ensure your PNG is square (equal width and height)
- For SVG wrapper, adjust the viewBox dimensions if needed
- Consider using a higher resolution PNG (1024x1024 or higher)

### Permission denied errors

- Ensure you're using `sudo` for all system directory operations
- Verify you have root access: `sudo -v`

## Files Modified

- `/usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg` - Main icon file (the actual icon used by Ubuntu Dock)
- `/usr/share/icons/Yaru/scalable/actions/view-app-grid-ubuntu-symbolic.svg` - Symlink pointing to start-here-symbolic.svg (do not modify)
- `/usr/share/icons/Yaru/icon-theme.cache` - Icon cache (regenerated)

## Backup Location

Backups are stored in:
```
/usr/share/icons/ubuntu-backup-YYYYMMDD-HHMMSS/
```

## Notes

- The Ubuntu Dock extension uses `view-app-grid-${sessionMode}-symbolic` which resolves to `start-here-symbolic.svg`
- The actual icon file is `start-here-symbolic.svg` in the places directory, not the actions directory
- Symbolic icons can be full color SVGs - they don't need to be monochrome
- Changes persist across reboots unless system updates replace the icon
- Consider creating a custom icon theme package for easier distribution
- SVG format is recommended over PNG for better scalability and quality

## Date Created

January 23, 2025

## Example Implementation

On this system, the icon was replaced using:
- Source icon: `/home/companion/devel/LogoMark_Color_StartIcon.svg` (SVG format)
- Target location: `/usr/share/icons/Yaru/scalable/places/start-here-symbolic.svg`
- Backup location: `/usr/share/icons/ubuntu-backup-20260123-162314/`
- Icon cache updated: Yes
- Status: Successfully replaced

**Important**: The icon must be replaced in the `places` directory, not the `actions` directory, as the Ubuntu Dock uses `start-here-symbolic.svg` which is referenced via symlink from `view-app-grid-ubuntu-symbolic.svg`.
