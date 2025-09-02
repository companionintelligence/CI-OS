ARG BASE_IMAGE="ghcr.io/ublue-os/bazzite"
ARG FEDORA_VERSION="41"

FROM ${BASE_IMAGE}:${FEDORA_VERSION}

# CI-OS version info
ARG CI_OS_VERSION="v01"
LABEL org.opencontainers.image.title="CI-OS Regular"
LABEL org.opencontainers.image.description="Bazzite-based OS with Windows Apps Support and CI-Server"
LABEL org.opencontainers.image.version="${CI_OS_VERSION}"

# Copy customization files
COPY files/ /

# Install additional packages for Windows app compatibility
RUN rpm-ostree install \
    wine \
    winetricks \
    lutris \
    protontricks \
    && rpm-ostree cleanup -m

# Install and configure CI-Server
RUN /files/scripts/install-ci-server.sh

# Configure Wine and gaming optimizations
RUN mkdir -p /etc/skel/.local/share/applications \
    && mkdir -p /etc/skel/.wine

# Rebuild initramfs
RUN rpm-ostree initramfs --enable

# Clean up
RUN rpm-ostree cleanup -m \
    && ostree container commit