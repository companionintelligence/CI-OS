ARG BASE_IMAGE="ghcr.io/ublue-os/bazzite"
ARG BASE_TAG="stable"

FROM ${BASE_IMAGE}:${BASE_TAG}

# CI-OS Bazzite Customization
# This containerfile customizes Bazzite with CI-OS branding and dark green theming

# Copy CI-OS assets and configurations
COPY assets/ /tmp/ci-os-assets/
COPY configs/bazzite/ /tmp/ci-os-configs/
COPY scripts/bazzite/ /tmp/ci-os-scripts/

# Install additional packages needed for CI-OS
RUN rpm-ostree install \
    neofetch \
    htop \
    git \
    vim \
    curl \
    wget \
    && \
    rpm-ostree cleanup -m

# Copy CI-OS branding assets to system locations
COPY assets/logos/2024_CI__LogoMark_Color_med.svg /usr/share/pixmaps/distributor-logo.svg
COPY assets/logos/ci-holo-depth.png /usr/share/pixmaps/ci-os-logo.png
COPY assets/wallpapers/ /usr/share/backgrounds/ci-os/

# Apply CI-OS theming and customizations
RUN /tmp/ci-os-scripts/apply-ci-os-theming.sh && \
    /tmp/ci-os-scripts/setup-dark-green-theme.sh && \
    /tmp/ci-os-scripts/configure-branding.sh

# Create CI-OS specific configuration overlays
COPY configs/bazzite/etc/ /etc/
COPY configs/bazzite/usr/ /usr/

# Set CI-OS specific environment variables
ENV CI_OS_VERSION="1.0.0"
ENV CI_OS_THEME="dark-green"
ENV XDG_CURRENT_DESKTOP="KDE"

# Clean up temporary files
RUN rm -rf /tmp/ci-os-* && \
    rpm-ostree cleanup -m

# Set metadata
LABEL org.opencontainers.image.title="CI-OS"
LABEL org.opencontainers.image.description="CI-OS - Custom Linux Distribution for AI Companions and Development (Based on Bazzite)"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.source="https://github.com/companionintelligence/CI-OS"