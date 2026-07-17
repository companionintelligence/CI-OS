# CI OS Ubuntu Rebranding - Quick Reference

## TL;DR

Apply complete CI OS dark green branding to Ubuntu 24.04:

```bash
sudo ./setup/os-changes/apply-ci-os-desktop.sh
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

### One entry script
```bash
# Full apply (recommended)
sudo ./setup/os-changes/apply-ci-os-desktop.sh

# Interactive wizard (optional KDE, validate, reboot prompt)
sudo ./setup/os-changes/apply-ci-os-desktop.sh --wizard

# Validate only (no sudo)
./setup/os-changes/apply-ci-os-desktop.sh --validate
```

### Partial apply (`--only` is comma-separated)
```bash
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only plymouth,dconf,session
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only wallpaper
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only start-icon
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only os-release
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only motd
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only kde
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
- `setup/os-changes/apply-ci-os-desktop.sh` — only top-level script (`--wizard`, `--validate`, `--only`)
- `setup/os-changes/common/*.sh` — Plymouth, dconf, wallpaper, session, icon, os-release, MOTD, KDE, validate

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
/etc/dconf/db/local.d/01-ci-os-gnome-defaults     # User defaults
/etc/dconf/db/gdm.d/01-ci-os-gdm                  # Login screen
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
./setup/os-changes/apply-ci-os-desktop.sh --validate
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
# In chroot: git clone repo, run apply-ci-os-desktop.sh (or --wizard)
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
- Run: `sudo ./setup/os-changes/apply-ci-os-desktop.sh --only kde` (from Plasma session)
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
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only plymouth,dconf,session
# Log out and back in
```

### "Permission denied" errors
```bash
# All main scripts require sudo
sudo ./setup/os-changes/apply-ci-os-desktop.sh --wizard
```

### Colors look wrong
```bash
# Verify correct colors applied
./setup/os-changes/apply-ci-os-desktop.sh --validate

# Re-apply if needed
sudo ./setup/os-changes/apply-ci-os-desktop.sh --only plymouth,dconf,session
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
apply-ci-os-desktop.sh   (only script beside common/; flags: --wizard, --validate, --only)
└── common/
    ├── 10-plymouth.sh
    ├── 20-dconf-system.sh
    ├── 30-wallpaper.sh
    ├── 25-session-gsettings.sh
    ├── 40-start-icon.sh
    ├── 50-os-release.sh
    ├── 60-motd.sh
    ├── 65-kde-theme.sh
    └── 80-validate-ci-theme.sh
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
