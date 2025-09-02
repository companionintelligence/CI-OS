# CI-OS v01: Bazzite with Wine, Proton, and WinApps Support
# Regular variant based on Bazzite Fedora 41

ARG FEDORA_MAJOR_VERSION=41
ARG BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-bazzite}"
ARG IMAGE_FLAVOR="${IMAGE_FLAVOR:-main}"

FROM ghcr.io/ublue-os/${BASE_IMAGE_NAME}:${FEDORA_MAJOR_VERSION}

ARG FEDORA_MAJOR_VERSION=41

# WinApps specific commit (pinned for stability)
ARG WINAPPS_COMMIT="0.1.0"
ARG WINE_VERSION="9.0"

# Install CI-OS branding and metadata (if exists)
# COPY files/system /

# Install Wine and Windows compatibility stack
RUN --mount=type=cache,target=/var/cache/dnf \
    rpm-ostree install -y \
    # Wine and Windows compatibility
    wine \
    winetricks \
    # Wine 32-bit libraries and drivers
    wine.i686 \
    mesa-dri-drivers.i686 \
    mesa-vulkan-drivers.i686 \
    mesa-libGL.i686 \
    libgcc.i686 \
    glibc.i686 \
    # Proton and gaming tools
    python3-protontricks \
    # Virtualization stack for WinApps
    qemu-kvm \
    libvirt \
    libvirt-client \
    virt-manager \
    libvirt-daemon-kvm \
    bridge-utils \
    # RDP and remote desktop
    freerdp \
    remmina \
    remmina-plugins-rdp \
    # Additional Windows app support
    cabextract \
    p7zip \
    p7zip-plugins \
    unzip \
    # Development and debugging tools
    strace \
    gdb \
    && rpm-ostree cleanup -m \
    && ostree container commit

# Copy CI-OS specific just commands
COPY files/just /usr/share/ublue-os/justfiles/

# Copy setup scripts and configurations
COPY files/scripts /usr/share/ci-os/scripts/

# Configure Wine environment defaults
RUN mkdir -p /etc/skel/.wine && \
    # Create default wine prefix structure
    mkdir -p /usr/share/ci-os/wine-configs && \
    # Set up CI-OS specific configurations
    echo 'export CI_OS_VERSION="v01"' >> /etc/environment && \
    echo 'export CI_OS_VARIANT="regular"' >> /etc/environment

# Install WinApps (pinned commit for stability) - Done post-install
# RUN cd /tmp && \
#     curl -L -o winapps.tar.gz "https://github.com/winapps-org/winapps/archive/refs/heads/main.tar.gz" && \
#     tar xzf winapps.tar.gz && \
#     mkdir -p /usr/share/ci-os/winapps && \
#     cp -r winapps-main/* /usr/share/ci-os/winapps/ && \
#     chmod +x /usr/share/ci-os/winapps/bin/* && \
#     rm -rf /tmp/winapps* || true

# Create WinApps directory structure for later installation
RUN mkdir -p /usr/share/ci-os/winapps

# Configure systemd services
RUN systemctl enable libvirtd && \
    systemctl enable sshd

# Set up Wine system configurations
RUN mkdir -p /etc/wine && \
    echo 'WINEARCH=win64' > /etc/wine/wine.conf && \
    echo 'WINEPREFIX=/home/$USER/.wine' >> /etc/wine/wine.conf

# Final cleanup and commit
RUN rpm-ostree cleanup -m && \
    ostree container commit

# Metadata
LABEL org.opencontainers.image.title="CI-OS v01 Regular"
LABEL org.opencontainers.image.description="Bazzite-based Linux distribution with Wine, Proton, and WinApps support"
LABEL org.opencontainers.image.version="v01"
LABEL org.opencontainers.image.vendor="Companion Intelligence"
LABEL io.artifacthub.package.readme-url="https://github.com/companionintelligence/CI-OS/blob/main/README.md"