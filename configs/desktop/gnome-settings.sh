# CI OS Desktop Configuration Script
# Applied during Cubic customization in chroot environment
# Same settings are applied by setup/os-changes/set-ci-branding.sh for standalone setup flow

# GNOME Settings via gsettings
# These settings will be applied system-wide

# Set CI OS wallpaper
gsettings set org.gnome.desktop.background picture-uri "file:///usr/share/backgrounds/ci-os-wallpaper.png"
gsettings set org.gnome.desktop.background picture-uri-dark "file:///usr/share/backgrounds/ci-os-wallpaper.png"
# Official CI brand colors: Primary Dark Green #066c80, Deep Green #1b4332
gsettings set org.gnome.desktop.background primary-color "#066c80"
gsettings set org.gnome.desktop.background secondary-color "#1b4332"

# Desktop interface settings (dark green theme to match Plymouth and CI branding)
# Using Yaru-prussiangreen-dark for closest match to CI official dark green palette
gsettings set org.gnome.desktop.interface gtk-theme "Yaru-prussiangreen-dark"
gsettings set org.gnome.desktop.interface icon-theme "Yaru"
gsettings set org.gnome.desktop.interface cursor-theme "Yaru"

# Dock configuration
gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed false
gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'
gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false
gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 48

# Favorite applications (dock) - Chromium, CI OS Hub; chromium_chromium.desktop for snap
gsettings set org.gnome.shell favorite-apps "['org.gnome.Nautilus.desktop', 'chromium_chromium.desktop', 'ci-os-hub.desktop', 'org.gnome.Terminal.desktop', 'code.desktop', 'steam.desktop', 'org.gnome.Settings.desktop']"

# Window management
gsettings set org.gnome.desktop.wm.preferences button-layout "close,minimize,maximize:"
gsettings set org.gnome.desktop.wm.preferences focus-mode "click"

# Power settings
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 1800

# Privacy settings
gsettings set org.gnome.desktop.privacy disable-microphone false
gsettings set org.gnome.desktop.privacy disable-camera false
gsettings set org.gnome.desktop.privacy report-technical-problems false

# Software updates
gsettings set com.ubuntu.update-notifier no-show-notifications false

# Terminal settings
gsettings set org.gnome.Terminal.Legacy.Settings default-show-menubar false
gsettings set org.gnome.Terminal.Legacy.Settings theme-variant 'dark'
