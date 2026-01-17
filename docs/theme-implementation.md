# CI-OS Dark Green Theme Implementation

## Overview

This document describes the complete dark green theme implementation for CI-OS, transforming the Bazzite base system with Companion Intelligence branding throughout.

## Color Palette

The CI-OS dark green theme uses three primary colors:

| Color Name | Hex Code | RGB | Usage |
|------------|----------|-----|-------|
| **Primary Dark Green** | `#066c80` | `6, 108, 128` | Backgrounds, window frames, selection areas |
| **Medium Green** | `#00a9a7` | `0, 169, 167` | Highlights, links, secondary UI elements |
| **Light Green** | `#72ddd4` | `114, 221, 212` | Accents, text highlights, branding elements |

### Supporting Colors

- **White**: `#FFFFFF` - Primary text on dark backgrounds
- **Light Gray**: `#E5E7EB` - Secondary text
- **Dark Gray**: `#374151` - Body text
- **Black**: `#000000` - Deep backgrounds

## Implementation Components

### 1. KDE Plasma Color Scheme

**File**: `files/usr/share/color-schemes/CI-OS-Dark.colors`

The KDE Plasma color scheme defines:
- Window backgrounds and frames
- Button colors and states
- Selection highlights
- Link colors
- Active/inactive window states
- Tooltip styling
- View and header colors

**Application Method**:
```bash
# Automatically applied on first boot via kdeglobals configuration
# Or manually applied with:
ujust apply-ci-theme
```

### 2. Boot Loader (GRUB)

**File**: `files/etc/default/grub.d/99-ci-os-branding.cfg`

Features:
- CI-OS distributor name
- Dark green color scheme for boot menu
- Cyan text on black background
- Custom GRUB background image support
- 1920x1080 graphics mode

**Colors**:
- Normal text: `light-cyan/black`
- Highlighted: `white/cyan`

### 3. Plymouth Boot Splash

**Files**:
- `files/usr/share/plymouth/themes/ci-os/ci-os.plymouth`
- `files/usr/share/plymouth/themes/ci-os/ci-os.script`

Features:
- Animated boot splash with CI logo
- Dark green gradient background
- Progress bar with CI colors
- Smooth color transitions:
  - Top: Black
  - Bottom: Primary Dark Green (#066c80)

### 4. SDDM Login Manager

**File**: `files/etc/sddm.conf.d/ci-os-theme.conf`

Configuration:
- Breeze dark theme as base
- Wayland display server
- Numlock enabled by default

### 5. Desktop Wallpaper

**File**: `files/usr/share/wallpapers/ci-os-wallpaper.svg`

- Scalable SVG format for any resolution
- CI branding with dark green theme
- Matches system color scheme

### 6. System Branding

**Files**:
- `files/usr/share/pixmaps/ci-os-logo.png` - System logo
- `files/usr/share/pixmaps/ci-os-grub-bg.png` - GRUB background (to be added)

## User Commands

### ujust Commands

All theme-related commands are defined in:
`files/usr/share/ublue-os/just/60-ci-os.just`

Available commands:

```bash
# Display CI-OS information and available commands
ujust ci-os-info

# Apply or reapply the dark green theme
ujust apply-ci-theme

# Complete first-time setup (includes theme application)
ujust setup-ci-os
```

## Theme Application Flow

### Automatic Application (First Boot)

1. System boots with CI-OS configuration
2. GRUB displays dark green boot menu
3. Plymouth shows animated boot splash
4. SDDM presents login screen with Breeze dark theme
5. KDE Plasma loads with CI-OS-Dark color scheme
6. Desktop wallpaper displays CI branding

### Manual Application

Users can manually apply or reapply the theme:

```bash
ujust apply-ci-theme
```

This command:
1. Sets the KDE color scheme to "CI-OS-Dark"
2. Applies Breeze dark look-and-feel
3. Sets the wallpaper (if available)
4. Restarts Plasma shell to apply changes

## Customization

### Modifying Colors

To change the color scheme:

1. Edit `files/usr/share/color-schemes/CI-OS-Dark.colors`
2. Update RGB values for desired colors
3. Rebuild the container image
4. Install or update CI-OS

### Adding New Theme Elements

1. Add files to appropriate `files/` subdirectories
2. Update Containerfile if needed
3. Create or update ujust commands
4. Document changes

## Technical Details

### KDE Color Scheme Format

The `.colors` file uses INI format with color groups:

- `[Colors:Button]` - Button styling
- `[Colors:Selection]` - Selected items
- `[Colors:Tooltip]` - Tooltip appearance
- `[Colors:View]` - List/tree views
- `[Colors:Window]` - Window chrome
- `[Colors:Header]` - Headers and toolbars
- `[Colors:Complementary]` - Complementary UI elements

### RGB to Hex Conversion

Our primary colors in different formats:

**Primary Dark Green** (`#066c80`):
- RGB: 6, 108, 128
- RGB Decimal: 0.024, 0.424, 0.502
- RGBA: rgba(6, 108, 128, 1.0)

**Medium Green** (`#00a9a7`):
- RGB: 0, 169, 167
- RGB Decimal: 0.0, 0.663, 0.655
- RGBA: rgba(0, 169, 167, 1.0)

**Light Green** (`#72ddd4`):
- RGB: 114, 221, 212
- RGB Decimal: 0.447, 0.867, 0.831
- RGBA: rgba(114, 221, 212, 1.0)

## Testing

### Visual Testing Checklist

- [ ] GRUB boot menu displays dark green theme
- [ ] Plymouth boot splash shows CI logo with gradient
- [ ] SDDM login screen uses dark theme
- [ ] KDE Plasma windows use dark green frames
- [ ] Selected items highlight in medium green
- [ ] Links display in light green
- [ ] Wallpaper displays correctly
- [ ] Theme persists across reboots
- [ ] ujust apply-ci-theme command works

### Automated Testing

Build testing via GitHub Actions:
1. Container image builds successfully
2. ISO generation completes
3. Files are properly copied into image
4. Permissions are set correctly

## Troubleshooting

### Theme Not Applied

If the theme doesn't apply automatically:

```bash
# Manually apply the theme
ujust apply-ci-theme

# Log out and log back in
```

### Colors Look Wrong

Check color scheme is installed:

```bash
ls -la /usr/share/color-schemes/CI-OS-Dark.colors
```

Verify it's selected:

```bash
kreadconfig5 --file kdeglobals --group General --key ColorScheme
```

### Wallpaper Not Showing

Check wallpaper exists:

```bash
ls -la /usr/share/wallpapers/ci-os-wallpaper.*
```

Set manually via System Settings > Appearance > Wallpaper

## References

- [KDE Plasma Theming Guide](https://develop.kde.org/docs/plasma/theme/)
- [Bazzite Documentation](https://universal-blue.discourse.group/docs?topic=37)
- [Universal Blue Just System](https://universal-blue.discourse.group/docs?topic=35)
- [Plymouth Theming](https://www.freedesktop.org/wiki/Software/Plymouth/)

## Version History

### v1.0 (2026-01-17)

- Initial dark green theme implementation
- KDE Plasma color scheme created
- GRUB, Plymouth, and SDDM themes configured
- ujust commands for theme management
- Complete CI branding throughout system

## Future Enhancements

- [ ] GTK theme matching KDE colors
- [ ] Firefox/browser theme integration
- [ ] VS Code color scheme matching CI-OS theme
- [ ] Terminal color scheme presets
- [ ] Cursor theme with CI colors
- [ ] Icon theme customization
- [ ] Sound theme with CI branding

---

**Maintained by**: Companion Intelligence
**Last Updated**: 2026-01-17
