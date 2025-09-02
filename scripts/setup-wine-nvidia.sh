#!/bin/bash
# Wine NVIDIA Setup Script for CI-OS
# Sets up Wine environment with NVIDIA GPU acceleration

set -euo pipefail

echo "Setting up Wine with NVIDIA GPU acceleration..."

# Run base Wine setup
source /usr/local/bin/setup-wine.sh

# Apply NVIDIA-specific Wine registry settings
if [ -f "/etc/wine/wine-nvidia.reg" ]; then
    echo "Applying NVIDIA Wine registry settings..."
    regedit /etc/wine/wine-nvidia.reg
fi

# Install DXVK for DirectX acceleration
echo "Installing DXVK for DirectX acceleration..."
winetricks -q dxvk

# Install VKD3D for DirectX 12 support
echo "Installing VKD3D for DirectX 12..."
winetricks -q vkd3d

# Configure NVIDIA environment variables
echo "Configuring NVIDIA environment variables..."
cat >> "$HOME/.bashrc" << 'EOF'
# NVIDIA Wine optimizations
export __GL_SHADER_DISK_CACHE=1
export __GL_THREADED_OPTIMIZATIONS=1
export NVIDIA_DRIVER_CAPABILITIES=all
export __GL_SYNC_TO_VBLANK=0

# DXVK NVIDIA optimizations  
export DXVK_ENABLE_NVAPI=1
export DXVK_NVAPI_DRIVER_VERSION=52.117

# VKD3D NVIDIA settings
export VKD3D_CONFIG=upload_hvv
export VKD3D_FEATURE_LEVEL=12_1
EOF

# Test NVIDIA acceleration
echo "Testing NVIDIA GPU acceleration..."
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi
    echo "NVIDIA GPU detected and available!"
else
    echo "Warning: NVIDIA GPU not detected. Make sure NVIDIA drivers are installed."
fi

echo "NVIDIA Wine setup completed successfully!"
echo "DirectX acceleration and GPU support are now enabled for Windows applications."