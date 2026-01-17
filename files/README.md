# CI-OS Customization Files

This directory contains all customization files that are copied into the CI-OS image during the build process. Files here are overlaid onto the base Bazzite system.

## Directory Structure

```
files/
├── etc/
│   ├── default/
│   │   └── grub.d/
│   │       └── 99-ci-os-branding.cfg    # GRUB bootloader configuration
│   ├── sddm.conf.d/
│   │   └── ci-os-theme.conf             # SDDM login manager theme
│   └── xdg/
│       └── kdeglobals.d/                # KDE global settings (set via Containerfile)
├── usr/
│   └── share/
│       ├── color-schemes/
│       │   └── CI-OS-Dark.colors        # KDE Plasma color scheme (dark green)
│       ├── pixmaps/
│       │   ├── ci-os-logo.png           # CI-OS logo for various uses
│       │   └── ci-os-grub-bg.png        # GRUB background (to be added)
│       ├── plymouth/
│       │   └── themes/
│       │       └── ci-os/               # Boot splash theme
│       ├── ublue-os/
│       │   ├── just/
│       │   │   └── 60-ci-os.just        # ujust commands for CI-OS
│       │   └── scripts/                 # Helper scripts
│       └── wallpapers/
│           └── ci-os-wallpaper.svg      # Desktop wallpaper
└── README.md                             # This file

## Color Scheme

CI-OS uses a professional dark green color scheme:

- **Primary Dark Green**: `#066c80` - Backgrounds, window frames, selection
- **Medium Green**: `#00a9a7` - Highlights, links, secondary elements  
- **Light Green**: `#72ddd4` - Accents, text highlights, branding text

## Theming Components

### KDE Plasma Color Scheme
- File: `usr/share/color-schemes/CI-OS-Dark.colors`
- Applied automatically on first boot
- Can be manually applied with: `ujust apply-ci-theme`

### GRUB Bootloader
- Configuration: `etc/default/grub.d/99-ci-os-branding.cfg`
- Sets CI-OS as distributor name
- Dark green color scheme for boot menu
- Background image support

### Plymouth Boot Splash
- Theme files: `usr/share/plymouth/themes/ci-os/`
- Animated dark green boot splash
- CI-OS logo display during boot

### SDDM Login Manager
- Configuration: `etc/sddm.conf.d/ci-os-theme.conf`
- Uses Breeze theme as base
- Wayland display server

### Desktop Wallpaper
- SVG wallpaper: `usr/share/wallpapers/ci-os-wallpaper.svg`
- Scalable to any resolution
- Dark green theme matching color scheme

## ujust Commands

The following commands are available after installation:

- `ujust ci-os-info` - Display CI-OS information
- `ujust setup-ci-os` - First-time setup (Wine, Proton, theme)
- `ujust setup-wine` - Configure Wine environment
- `ujust setup-proton` - Set up Proton compatibility
- `ujust setup-winapps` - Install WinApps for Windows VM apps
- `ujust apply-ci-theme` - Apply CI-OS dark green theme
- `ujust setup-ci-os-nvidia` - NVIDIA-specific optimizations (NVIDIA variant only)
- `ujust nvidia-info` - Display NVIDIA GPU information (NVIDIA variant only)

## Build Integration

These files are automatically integrated during the container build process:

1. Files are copied via `COPY files /` in the Containerfile
2. KDE theme is set as default via kdeglobals configuration
3. ujust commands are symlinked into the system
4. Permissions are set for executable scripts

## Customization

To modify the theme or add new customizations:

1. Edit files in this directory structure
2. Rebuild the container image
3. Test changes in a VM before deploying

## Notes

- All paths are relative to the root filesystem `/`
- Files here override base Bazzite configurations
- Changes require rebuilding the container image
- KDE Plasma theme applies per-user, not system-wide by default
