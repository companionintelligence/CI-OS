#!/bin/bash
# CI-OS Theming Application Script for Bazzite
# Applies CI-OS branding, logos, and visual customizations

set -e

echo "=== Applying CI-OS Theming to Bazzite ==="

# Create directories for CI-OS assets
mkdir -p /usr/share/backgrounds/ci-os
mkdir -p /usr/share/pixmaps/ci-os
mkdir -p /usr/share/icons/ci-os

# Copy CI-OS logos to appropriate system locations
echo "📋 Installing CI-OS logos and branding assets..."

# Main distributor logo (used by various system components)
cp /tmp/ci-os-assets/logos/2024_CI__LogoMark_Color_med.svg /usr/share/pixmaps/distributor-logo.svg
cp /tmp/ci-os-assets/logos/ci-holo-depth.png /usr/share/pixmaps/ci-os-logo.png
cp /tmp/ci-os-assets/logos/ci-holo-flat.png /usr/share/pixmaps/ci-os-logo-flat.png

# Copy all logos to CI-OS specific directory
cp /tmp/ci-os-assets/logos/* /usr/share/pixmaps/ci-os/

# Install CI-OS wallpapers
echo "🖼️  Installing CI-OS wallpapers..."
cp /tmp/ci-os-assets/wallpapers/* /usr/share/backgrounds/ci-os/

# Create additional dark green wallpaper variants if they don't exist
if [ ! -f "/usr/share/backgrounds/ci-os/ci-os-dark-green.svg" ]; then
    # Create a dark green variant of the main wallpaper
    sed 's/#066c80/#0a4f3c/g; s/#00a9a7/#1a6b3a/g; s/#72ddd4/#4ade80/g' \
        /usr/share/backgrounds/ci-os/ci-os-wallpaper.svg > \
        /usr/share/backgrounds/ci-os/ci-os-dark-green.svg
fi

# Set up icon theme replacements
echo "🎨 Setting up CI-OS icon replacements..."

# Replace distributor logos in existing icon themes
ICON_THEMES_DIR="/usr/share/icons"
for theme_dir in "$ICON_THEMES_DIR"/*/; do
    if [ -d "$theme_dir" ]; then
        theme_name=$(basename "$theme_dir")
        
        # Skip if it's our own theme
        [ "$theme_name" = "ci-os" ] && continue
        
        # Replace distributor logos in scalable apps
        if [ -d "$theme_dir/scalable/apps" ]; then
            cp /usr/share/pixmaps/distributor-logo.svg "$theme_dir/scalable/apps/distributor-logo.svg" 2>/dev/null || true
            cp /usr/share/pixmaps/distributor-logo.svg "$theme_dir/scalable/apps/ubuntu-logo-icon.svg" 2>/dev/null || true
            cp /usr/share/pixmaps/distributor-logo.svg "$theme_dir/scalable/apps/fedora-logo-icon.svg" 2>/dev/null || true
        fi
        
        # Replace in different sizes
        for size in 16 22 24 32 48 64 128 256; do
            if [ -d "$theme_dir/${size}x${size}/apps" ]; then
                # Convert SVG to appropriate size PNG if needed
                if command -v convert &> /dev/null; then
                    convert /usr/share/pixmaps/distributor-logo.svg -resize "${size}x${size}" \
                        "$theme_dir/${size}x${size}/apps/distributor-logo.png" 2>/dev/null || true
                fi
            fi
        done
    fi
done

# Set up GRUB/boot theme
echo "🚀 Configuring boot theme..."
GRUB_THEME_DIR="/usr/share/grub/themes/ci-os"
mkdir -p "$GRUB_THEME_DIR"

# Create GRUB theme configuration
cat > "$GRUB_THEME_DIR/theme.txt" << 'EOF'
# CI-OS GRUB Theme
desktop-image: "background.png"
desktop-color: "#066c80"
terminal-font: "Unifont Regular 16"
terminal-box: "terminal_box_*.png"
terminal-left: "0"
terminal-top: "0"
terminal-width: "100%"
terminal-height: "100%"
terminal-border: "0"

# Boot menu
+ boot_menu {
    left = 20%
    width = 60%
    top = 30%
    height = 50%
    item_color = "#ffffff"
    item_font = "Unifont Regular 16"
    selected_item_color = "#72ddd4"
    selected_item_font = "Unifont Bold 16"
    item_height = 32
    item_padding = 8
    item_spacing = 4
    icon_width = 24
    icon_height = 24
}

# Progress bar
+ progress_bar {
    id = "__timeout__"
    left = 20%
    width = 60%
    top = 85%
    height = 24
    show_text = false
    bar_style = "progress_bar_*.png"
    highlight_style = "progress_highlight_*.png"
}

# Title
+ label {
    top = 15%
    left = 0
    width = 100%
    height = 64
    text = "CI-OS"
    color = "#72ddd4"
    font = "Unifont Bold 32"
    align = "center"
}
EOF

# Create simple background for GRUB (dark green gradient)
if command -v convert &> /dev/null; then
    convert -size 1920x1080 gradient:"#0a4f3c-#066c80" "$GRUB_THEME_DIR/background.png"
fi

# Configure system information/neofetch
echo "🖥️  Configuring system information display..."
mkdir -p /etc/neofetch

cat > "/etc/neofetch/config.conf" << 'EOF'
# CI-OS Neofetch Configuration
print_info() {
    info title
    info underline

    info "OS" distro
    info "Host" model
    info "Kernel" kernel
    info "Uptime" uptime
    info "Packages" packages
    info "Shell" shell
    info "Resolution" resolution
    info "DE" de
    info "WM" wm
    info "WM Theme" wm_theme
    info "Theme" theme
    info "Icons" icons
    info "Terminal" term
    info "Terminal Font" term_font
    info "CPU" cpu
    info "GPU" gpu
    info "Memory" memory

    info cols
}

# Kernel
kernel_shorthand="on"

# Distro
distro_shorthand="off"
os_arch="on"

# Uptime
uptime_shorthand="on"

# Memory
memory_percent="on"
memory_unit="gib"

# Packages
package_managers="on"

# Shell
shell_path="off"
shell_version="on"

# CPU
speed_type="bios_limit"
speed_shorthand="off"
cpu_brand="on"
cpu_speed="on"
cpu_cores="logical"
cpu_temp="off"

# GPU
gpu_brand="on"
gpu_type="all"

# Resolution
refresh_rate="off"

# Theme/Icons/Font
gtk_shorthand="off"
gtk2="on"
gtk3="on"

# IP Address
public_ip_host="http://ident.me"
public_ip_timeout=2

# Desktop Environment
de_version="on"

# Disk
disk_show=('/')
disk_subtitle="mount"
disk_percent="on"

# Song
music_player="auto"
song_format="%artist% - %album% - %title%"
song_shorthand="off"
mpc_args=()

# Text Colors
colors=(4 6 1 8 8 6)

# Text Options
bold="on"
underline_enabled="on"
underline_char="-"
separator=":"

# Color Blocks
block_range=(0 15)
color_blocks="on"
block_width=3
block_height=1
col_offset="auto"

# Progress Bars
bar_char_elapsed="-"
bar_char_total="="
bar_border="on"
bar_length=15
bar_color_elapsed="distro"
bar_color_total="distro"
cpu_display="off"
memory_display="off"
battery_display="off"
disk_display="off"

# Backend Settings
image_backend="ascii"
image_source="auto"

# Ascii Options
ascii_distro="auto"
ascii_colors=(4 6 1 8 8 6)
ascii_bold="on"

# Image Options
image_loop="off"
thumbnail_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/thumbnails/neofetch"
crop_mode="normal"
crop_offset="center"
image_size="auto"
gap=3
yoffset=0
xoffset=0
background_color=

# Misc Options
stdout="off"
EOF

# Create CI-OS ASCII art for neofetch
cat > "/etc/neofetch/ci-os-ascii.txt" << 'EOF'
${c1}                    .:+o+:.                    
${c1}                 -+o++++++o+-                 
${c1}              .+o++++++++++o+.              
${c1}            :+o+++++++++++++o+:            
${c1}          .+o++++++++++++++++++o+.          
${c1}        .+o++++++++${c2}+oo+${c1}++++++++o+.        
${c1}       +o+++++++++${c2}o${c3}::${c2}o${c1}+++++++++o+       
${c1}     .o++++++++++${c2}o${c3}::::${c2}o${c1}++++++++++o.     
${c1}    .o+++++++++++${c2}o${c3}::::::${c2}o${c1}+++++++++++o.    
${c1}   .o++++++++++++${c2}+oo${c3}::${c2}oo+${c1}++++++++++++o.   
${c1}  .o+++++++++++++++++${c2}oo${c1}++++++++++++++o.  
${c1}  +o+++++++++++++++++++++++++++++++o+  
${c1} +o+++++++++++++++++++++++++++++++++o+ 
${c1}+o+++++++++++++++++++++++++++++++++++o+
${c1}o+++++++++++++++++++++++++++++++++++++o
${c1}+o+++++++++++++++++++++++++++++++++++o+
${c1} +o+++++++++++++++++++++++++++++++++o+ 
${c1}  +o+++++++++++++++++++++++++++++++o+  
${c1}  .o+++++++++++++++++++++++++++++o.  
${c1}   .o+++++++++++++++++++++++++++o.   
${c1}    .o+++++++++++++++++++++++o.    
${c1}     .o+++++++++++++++++++o.     
${c1}       +o+++++++++++++++o+       
${c1}        .+o+++++++++++o+.        
${c1}          .+o++++++o+.          
${c1}            :+o+++o+:            
${c1}              .+o+.              
${c1}                +-                

${c4}            C I - O S
${c6}      Custom Linux for Developers
EOF

echo "✅ CI-OS theming application completed"
echo "   - System logos updated"
echo "   - Wallpapers installed" 
echo "   - Icon themes updated"
echo "   - Boot theme configured"
echo "   - System info customized"