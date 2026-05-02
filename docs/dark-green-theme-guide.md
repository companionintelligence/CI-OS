# CI OS Dark Green Theme Implementation Guide

## Overview

This document describes the implementation of the official CI OS dark green color scheme throughout the Ubuntu 24.04-based system. The theme provides a consistent, beautiful dark green aesthetic from boot to desktop.

## Official Color Palette

### Primary Colors
- **Primary Dark Green**: `#066c80` (RGB: 6, 108, 128)
  - Used for: backgrounds, window frames, primary selections
  - Plymouth boot splash background
  - GNOME/KDE primary theme color

- **Medium Green**: `#00a9a7` (RGB: 0, 169, 167)
  - Used for: highlights, links, buttons, progress bars
  - Interactive UI elements
  - Secondary accents

- **Light Green**: `#72ddd4` (RGB: 114, 221, 212)
  - Used for: text highlights, branding elements, accents
  - Focus states
  - Tertiary UI elements

### Supporting Colors
- **Deep Green**: `#1b4332` - Dark backgrounds, secondary surfaces
- **Forest Green**: `#2d5a45` - Progress bars, tertiary elements
- **Teal**: `#20b2aa` - Interactive elements, legacy compatibility

## Desktop Environment Support

### GNOME (Default)
The system uses **Yaru-prussiangreen-dark** as the base GTK theme, which provides the closest match to our official dark green palette. Custom color overrides are applied via dconf/gsettings.

**Installation:**
```bash
sudo ./setup/os-changes/apply-ci-os-desktop.sh
```

**Manual application:**
```bash
gsettings set org.gnome.desktop.interface gtk-theme "Yaru-prussiangreen-dark"
gsettings set org.gnome.desktop.background primary-color "#066c80"
gsettings set org.gnome.desktop.background secondary-color "#1b4332"
```

### KDE Plasma
A custom color scheme file `CI-OS-Dark.colors` is provided for KDE Plasma users.

**Installation:**
```bash
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only kde
```

**Manual installation:**
1. Copy `configs/desktop/CI-OS-Dark.colors` to `/usr/share/color-schemes/` (system-wide) or `~/.local/share/color-schemes/` (user)
2. System Settings → Appearance → Colors → Select "CI OS Dark Green"

## Boot & System Branding

### Plymouth Boot Splash
The Plymouth spinner and text themes are customized with CI branding and colors:

**Colors applied:**
- Background: `0x066c80` (Primary Dark Green)
- Progress background: `0x1b4332` (Deep Green)
- Progress foreground: `0x00a9a7` (Medium Green)

**Modified files:**
- `/usr/share/plymouth/themes/spinner/watermark.png` - CI logo
- `/usr/share/plymouth/themes/spinner/spinner.plymouth` - Color config
- `/usr/share/plymouth/themes/bgrt/bgrt.plymouth` - UEFI boot logo config
- `/usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth` - Text mode

**Testing Plymouth:**
```bash
sudo plymouthd --debug --debug-file=/tmp/plymouth-debug.log
sudo plymouth --show-splash
# Wait 5 seconds
sudo plymouth quit
# Check /tmp/plymouth-debug.log for issues
```

### GRUB Theme
GRUB menu colors should be updated to match the dark green scheme (future enhancement).

### Login Screen (GDM)
The GNOME Display Manager is themed with dark green colors via dconf system database.

**Configuration:** `/etc/dconf/db/gdm.d/01-ci-theme`

## System Identity

### OS Release Information
Update `/etc/os-release` to reflect CI OS branding:

```bash
NAME="CI OS"
VERSION="0.0.1"
ID=ci-os
ID_LIKE=ubuntu
PRETTY_NAME="CI OS 0.0.1 (Companion Intelligence)"
VERSION_ID="0.0.1"
HOME_URL="https://ci.computer"
SUPPORT_URL="https://ci.computer/support"
BUG_REPORT_URL="https://ci.computer/bugs"
PRIVACY_POLICY_URL="https://ci.computer/privacy"
VERSION_CODENAME=ci
UBUNTU_CODENAME=noble
```

### MOTD (Message of the Day)
Ubuntu's dynamic MOTD with news/ads should be disabled and replaced with CI OS welcome message.

**Disable Ubuntu MOTD news:**
```bash
sudo chmod -x /etc/update-motd.d/50-motd-news
sudo chmod -x /etc/update-motd.d/10-help-text
```

**Create CI OS MOTD:** `/etc/update-motd.d/00-ci-header`
```bash
#!/bin/bash
echo ""
echo "  ██████╗██╗     ██████╗ ███████╗"
echo " ██╔════╝██║    ██╔═══██╗██╔════╝"
echo " ██║     ██║    ██║   ██║███████╗"
echo " ██║     ██║    ██║   ██║╚════██║"
echo " ╚██████╗██║    ╚██████╔╝███████║"
echo "  ╚═════╝╚═╝     ╚═════╝ ╚══════╝"
echo ""
echo " Companion Intelligence Operating System"
echo " Uncloud Modern Life"
echo ""
```

## ISO Customization (Cubic/Remastering)

### Prerequisites
- Ubuntu 24.04 LTS ISO (base)
- Cubic (for live CD customization)
- CI OS repository cloned

### Build Process

1. **Extract base ISO in Cubic**
   ```bash
   # Mount ISO and extract squashfs
   sudo cubic
   # Select Ubuntu 24.04 ISO as source
   ```

2. **Apply branding in chroot**
   ```bash
   # Inside Cubic chroot terminal:
   
   # Copy CI OS assets
   cp -r /path/to/CI-OS/assets /root/ci-assets
   cp -r /path/to/CI-OS/setup/os-changes /root/ci-setup
   cp -r /path/to/CI-OS/configs/desktop /root/ci-configs
   
   # Run branding script
   cd /root/ci-setup
   chmod +x *.sh
   ./apply-ci-os-desktop.sh
   
   # Apply desktop settings
   bash /root/ci-configs/gnome-settings.sh
   
   # Update OS release
   cat > /etc/os-release <<EOF
   NAME="CI OS"
   VERSION="0.0.1"
   ID=ci-os
   ID_LIKE=ubuntu
   PRETTY_NAME="CI OS 0.0.1"
   [... rest of config ...]
   EOF
   
   # Disable Ubuntu MOTD
   chmod -x /etc/update-motd.d/50-motd-news
   chmod -x /etc/update-motd.d/10-help-text
   
   # Regenerate initramfs
   update-initramfs -u -k all
   ```

3. **Generate ISO**
   - Cubic will repack the squashfs
   - Create new ISO with CI OS branding
   - Test in VM before distribution

### Installer Customization (Ubuntu Desktop Installer)

For Ubuntu 24.04's new desktop installer (Flutter-based), create whitelabel config:

**File:** `/usr/share/desktop-provision/whitelabel.yaml`
```yaml
app_name: "CI OS Installer"
theme_colors:
  primary: "#066c80"
  accent: "#00a9a7"
  secondary: "#72ddd4"
page_visibility:
  welcome: true
  try_or_install: false  # Skip "Try Ubuntu" option
  rst: false
  telemetry: false
oem_mode: false
```

**Installer slides:** Place HTML slides in `/usr/share/desktop-provision/slides/`

## Testing Checklist

### Visual Validation
- [ ] Plymouth boot splash shows CI logo with dark green background
- [ ] Boot text (if fallback) shows CI OS branding
- [ ] Login screen (GDM) uses dark green theme
- [ ] Desktop background is CI wallpaper
- [ ] Start menu icon is CI logo (GNOME)
- [ ] Window decorations use dark green accent
- [ ] System theme is dark green throughout

### Branding Validation
- [ ] No "Ubuntu" text visible in boot sequence
- [ ] No Ubuntu logo in Plymouth
- [ ] No Ubuntu branding in login screen
- [ ] `/etc/os-release` shows CI OS identity
- [ ] MOTD shows CI OS message (not Ubuntu news)
- [ ] About dialog shows CI OS (may require additional patching)

### Functional Testing
- [ ] System boots normally with new theme
- [ ] Login works correctly
- [ ] Desktop environment loads properly
- [ ] Theme colors are consistent across applications
- [ ] No broken icons or missing resources

## Color Conversion Reference

For developers needing to convert hex colors to other formats:

| Color Name | Hex | RGB | 0x (Plymouth) |
|------------|-----|-----|---------------|
| Primary Dark Green | #066c80 | 6,108,128 | 0x066c80 |
| Medium Green | #00a9a7 | 0,169,167 | 0x00a9a7 |
| Light Green | #72ddd4 | 114,221,212 | 0x72ddd4 |
| Deep Green | #1b4332 | 27,67,50 | 0x1b4332 |

## Troubleshooting

### Plymouth not showing changes
```bash
sudo update-initramfs -u -k all
sudo update-grub
# Reboot
```

### Theme not applying in GNOME
```bash
# Reset dconf
dconf reset -f /org/gnome/desktop/
# Re-run branding script
sudo ./setup/os-changes/apply-ci-os-desktop.sh
# Log out and back in
```

### KDE theme not visible
```bash
# Ensure color scheme is in correct location
ls -la ~/.local/share/color-schemes/CI-OS-Dark.colors
# Or system-wide:
ls -la /usr/share/color-schemes/CI-OS-Dark.colors
# Restart KDE
```

## References

- [CI OS Brand Guidelines](../../assets/branding/brand-guidelines.md)
- [Plymouth Theme Guide](https://www.freedesktop.org/wiki/Software/Plymouth/Scripts/)
- [GNOME dconf](https://wiki.gnome.org/Projects/dconf)
- [KDE Color Schemes](https://techbase.kde.org/Development/Tutorials/Plasma5/ThemeDetails#Color_Schemes)
- [Ubuntu Remastering Guide](https://help.ubuntu.com/community/LiveCDCustomization)

## Future Enhancements

- [ ] Custom GRUB theme with dark green colors
- [ ] Breeze-based window decoration for KDE matching CI colors
- [ ] Custom GTK theme (not just Yaru variant)
- [ ] Animated Plymouth splash with CI branding
- [ ] Installer slideshow with CI messaging
- [ ] About dialog patching for CI OS identity
