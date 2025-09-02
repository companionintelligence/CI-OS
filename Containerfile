# =====================================================================================
# CI-OS v01: Bazzite-based ISO with Windows Apps Support
# =====================================================================================
# This creates a container image that will be converted to a bootable ISO
# Final output: Installable ISO with Wine + Proton + WinApps support

ARG SOURCE_IMAGE="bazzite"
ARG SOURCE_SUFFIX=""
ARG SOURCE_TAG="stable"

FROM ghcr.io/ublue-os/${SOURCE_IMAGE}${SOURCE_SUFFIX}:${SOURCE_TAG}

# Set build arguments for versioning and variants
ARG FEDORA_MAJOR_VERSION="41"
ARG NVIDIA_MAJOR_VERSION="470"

# Metadata
LABEL org.opencontainers.image.title="CI-OS v01"
LABEL org.opencontainers.image.description="Bazzite-based ISO with Wine, Proton helpers, and WinApps support"
LABEL org.opencontainers.image.vendor="Companion Intelligence"
LABEL org.opencontainers.image.source="https://github.com/companionintelligence/CI-OS"
LABEL org.opencontainers.image.version="v01"

# Pin WinApps versions for reproducibility
ARG WINAPPS_REPO="https://github.com/winapps-org/winapps.git"
ARG WINAPPS_COMMIT="main"

# Set environment variables
ENV WINAPPS_DIR="/opt/winapps" \
    WINAPPS_BIN="/usr/bin/winapps"

# ---- Install Wine, Proton, and virtualization stack ----
RUN --mount=type=cache,target=/var/cache/dnf \
    rpm-ostree install -y \
      # Wine and related tools
      wine \
      winetricks \
      cabextract \
      # 32-bit libraries for Wine compatibility
      glibc.i686 \
      libgcc.i686 \
      zlib.i686 \
      mesa-dri-drivers.i686 \
      vulkan-loader.i686 \
      alsa-lib.i686 \
      libX11.i686 \
      libxcb.i686 \
      freetype.i686 \
      # Proton tools
      protontricks \
      # Virtualization for WinApps
      qemu-kvm \
      libvirt \
      virt-install \
      virt-manager \
      edk2-ovmf \
      swtpm \
      # RDP and remote tools for WinApps
      freerdp \
      remmina \
      nmap-ncat \
      # Build tools
      git \
      curl \
      tar \
    && rpm-ostree cleanup -m \
    && ostree container commit

# ---- Enable virtualization services ----
RUN systemctl enable libvirtd.service

# ---- Install WinApps ----
RUN git clone --depth=1 ${WINAPPS_REPO} ${WINAPPS_DIR} && \
    cd ${WINAPPS_DIR} && \
    ([ "${WINAPPS_COMMIT}" = "main" ] || (git fetch origin ${WINAPPS_COMMIT} && git checkout ${WINAPPS_COMMIT}))

# Create WinApps launcher
RUN install -Dm755 /dev/stdin ${WINAPPS_BIN} << 'EOF'
#!/usr/bin/bash
set -euo pipefail
# Launch WinApps from the installed location
exec /usr/bin/env bash /opt/winapps/winapps "$@"
EOF

# ---- Setup just commands for easy configuration ----
RUN mkdir -p /usr/share/ublue-os/justfiles

COPY files/just/ci-os-setup.just /usr/share/ublue-os/justfiles/50-ci-os-setup.just

# ---- Desktop integration and user experience ----
RUN mkdir -p /usr/share/applications

# Create a simple desktop entry for CI-OS setup
RUN install -Dm644 /dev/stdin /usr/share/applications/ci-os-setup.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=CI-OS Setup
Comment=Configure Wine, Proton, and WinApps
Exec=ujust setup-ci-os
Icon=wine
Categories=System;Settings;
EOF

# ---- Add welcome message ----
RUN install -Dm644 /dev/stdin /etc/motd.d/20-ci-os.motd << 'EOF'
=================================================================
 Welcome to CI-OS v01 - Bazzite with Windows Apps Support
=================================================================

First-time setup commands:
  ujust setup-ci-os       # Complete setup wizard
  ujust setup-wine        # Configure Wine prefix
  ujust setup-proton      # Install Proton tools  
  ujust setup-winapps     # Configure WinApps VM

For help: ujust --help
=================================================================
EOF

# Final commit
RUN ostree container commit