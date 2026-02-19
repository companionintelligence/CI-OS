# CI OS Ubuntu Rebranding - Quick Reference

## TL;DR

Apply complete CI OS dark green branding to Ubuntu 24.04:

```bash
sudo ./setup/os-changes/complete-rebranding.sh
sudo reboot
```

## Official Colors

```
Primary Dark Green:  #066c80  (backgrounds, frames, selection)
Medium Green:        #00a9a7  (highlights, links, buttons)
Light Green:         #72ddd4  (accents, text highlights)
Deep Green:          #1b4332  (dark backgrounds)
```

## Quick Commands

### One-Command Rebranding
```bash
# Apply everything (recommended)
sudo ./setup/os-changes/complete-rebranding.sh

# Validate
./setup/os-changes/validate-ci-theme.sh
```

### Individual Components
```bash
# Plymouth + GNOME theme + wallpaper
sudo ./setup/os-changes/set-ci-branding.sh

# OS identity
sudo ./setup/os-changes/update-os-release.sh

# MOTD customization
sudo ./setup/os-changes/setup-ci-motd.sh

# Start icon
sudo ./setup/os-changes/replace-start-icon.sh

# Wallpaper only
sudo ./setup/os-changes/replace-wallpaper.sh

# KDE theme (KDE users only)
./setup/os-changes/install-kde-theme.sh
```

## What Gets Changed

| Component | Before | After |
|-----------|--------|-------|
| Boot splash | Ubuntu purple | CI dark green (#066c80) |
| OS identity | Ubuntu 24.04 | CI OS 0.0.1 |
| Login screen | Ubuntu orange | CI dark green |
| Desktop theme | Yaru | Yaru-prussiangreen-dark |
| Wallpaper | Ubuntu default | CI OS wallpaper |
| Start icon | Ubuntu logo | CI logo |
| MOTD | Ubuntu news | CI OS welcome |
| Colors | Orange/purple | Dark green palette |

## File Locations

### Scripts
- `setup/os-changes/complete-rebranding.sh` - Master installer
- `setup/os-changes/validate-ci-theme.sh` - Validation
- `setup/os-changes/set-ci-branding.sh` - Core theme
- `setup/os-changes/update-os-release.sh` - OS identity
- `setup/os-changes/setup-ci-motd.sh` - MOTD
- `setup/os-changes/install-kde-theme.sh` - KDE support

### Assets
- `assets/branding/brand-guidelines.md` - Color specs
- `configs/desktop/CI-OS-Dark.colors` - KDE theme
- `configs/desktop/gnome-settings.sh` - GNOME defaults
- `setup/os-changes/background.png` - Wallpaper
- `setup/os-changes/Logo_Banner_Color.png` - Plymouth logo

### Documentation
- `docs/dark-green-theme-guide.md` - Complete theme guide
- `docs/iso-build-guide.md` - ISO customization
- `README.md` - Main documentation

## System Files Modified

```
/etc/os-release                                  # OS identity
/etc/lsb-release                                 # LSB info
/usr/share/plymouth/themes/spinner/              # Boot splash
/usr/share/plymouth/themes/bgrt/                 # UEFI boot
/usr/share/plymouth/themes/ubuntu-text/          # Text boot
/etc/dconf/db/local.d/01-ci-theme                # User defaults
/etc/dconf/db/gdm.d/01-ci-theme                  # Login screen
/etc/update-motd.d/00-ci-header                  # MOTD header
/etc/update-motd.d/10-ci-sysinfo                 # System info
/usr/share/backgrounds/ci-os-wallpaper.png       # Wallpaper
/usr/share/icons/Yaru*/scalable/places/          # Start icon
/usr/share/color-schemes/CI-OS-Dark.colors       # KDE theme (optional)
```

All original files are backed up with timestamps.

## Verification Commands

```bash
# Check OS identity
cat /etc/os-release
lsb_release -a

# Check GNOME theme
gsettings get org.gnome.desktop.interface gtk-theme
gsettings get org.gnome.desktop.background primary-color

# Check Plymouth
sudo plymouthd --debug
sudo plymouth --show-splash
# (Ctrl+C after 5 seconds)
sudo plymouth quit

# Test MOTD
run-parts /etc/update-motd.d/

# Automated validation
./setup/os-changes/validate-ci-theme.sh
```

## Revert Changes

All scripts create timestamped backups:

```bash
# Find backups
ls -la /usr/share/plymouth/ci-branding-backup-*
ls -la /etc/os-release.ubuntu-backup-*
ls -la /etc/update-motd.d.ubuntu-backup-*

# Restore example
sudo cp /etc/os-release.ubuntu-backup-YYYYMMDD-HHMMSS /etc/os-release
```

## ISO Building

### Quick Method (Cubic)
```bash
sudo apt install cubic
cubic
# Select Ubuntu 24.04 ISO
# In chroot: git clone repo, run complete-rebranding.sh
# Generate ISO
```

### Automated Method (GitHub Actions)
```bash
# Trigger workflow at:
# .github/workflows/build-companion-os-iso.yml
# Downloads Ubuntu 24.04, applies branding, creates ISO
```

### Manual Method
See `docs/iso-build-guide.md` for complete instructions.

## Desktop Environments

### GNOME (Default)
- Uses Yaru-prussiangreen-dark theme
- Colors applied via dconf
- Full support ✅

### KDE Plasma
- Custom CI-OS-Dark.colors scheme
- Run: `./setup/os-changes/install-kde-theme.sh`
- Full support ✅

### Others (XFCE, MATE, etc.)
- Manual theme customization needed
- Color values in `assets/branding/brand-guidelines.md`

## Common Issues

### Plymouth not showing after reboot
```bash
sudo update-initramfs -u -k all
sudo update-grub
sudo reboot
```

### Theme not applying in GNOME
```bash
dconf reset -f /org/gnome/desktop/
sudo ./setup/os-changes/set-ci-branding.sh
# Log out and back in
```

### "Permission denied" errors
```bash
# All main scripts require sudo
sudo ./setup/os-changes/complete-rebranding.sh
```

### Colors look wrong
```bash
# Verify correct colors applied
./setup/os-changes/validate-ci-theme.sh

# Re-apply if needed
sudo ./setup/os-changes/set-ci-branding.sh
```

## Testing Checklist

- [ ] Boot splash shows CI logo on dark green background
- [ ] Login screen is dark green themed
- [ ] Desktop theme is dark green
- [ ] Wallpaper is CI wallpaper
- [ ] Start menu icon is CI logo
- [ ] `cat /etc/os-release` shows "CI OS"
- [ ] MOTD shows CI OS welcome message
- [ ] No "Ubuntu" branding visible
- [ ] Validation script passes

## Architecture

```
complete-rebranding.sh (master)
├── set-ci-branding.sh
│   ├── Plymouth theme (dark green #066c80)
│   ├── GNOME/dconf config
│   └── Wallpaper + start icon
├── update-os-release.sh
│   ├── /etc/os-release
│   └── /etc/lsb-release
├── setup-ci-motd.sh
│   ├── Disable Ubuntu MOTD
│   └── Create CI MOTD
└── validate-ci-theme.sh
    └── Verify all changes
```

## Support

- **Issues**: https://github.com/companionintelligence/CI-OS/issues
- **Docs**: `docs/dark-green-theme-guide.md`
- **ISO Guide**: `docs/iso-build-guide.md`
- **Colors**: `assets/branding/brand-guidelines.md`

## Credits

- Base: Ubuntu 24.04 LTS (Noble Numbat)
- Theme: Yaru-prussiangreen-dark (modified)
- Colors: Official CI dark green palette
- CI OS: Companion Intelligence

---

**CI OS - Uncloud Modern Life**
