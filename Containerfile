# ---- 0) Base & metadata ------------------------------------------------------
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable
FROM ${BASE_IMAGE}

# Make bash strict during build steps
SHELL ["/usr/bin/bash", "-euxo", "pipefail", "-c"]

# Optional: stamp your image
LABEL org.opencontainers.image.title="Bazzite + WinApps/Wine/Proton"
LABEL org.opencontainers.image.description="Bazzite derivative with Windows app support via Wine, Proton helpers, and WinApps (KVM+RDP)."
LABEL org.opencontainers.image.vendor="Companion Intelligence"
LABEL org.opencontainers.image.source="https://github.com/companionintelligence/CI-OS"

# Runtime paths/env
ENV WINAPPS_DIR="/usr/share/winapps" \
    WINAPPS_BIN="/usr/bin/winapps"

# Pin the WinApps fork + commit (adjust to your preference)
ARG WINAPPS_REPO="https://github.com/winapps-org/winapps.git"
ARG WINAPPS_REF="main"

# ---- 1) Core packages --------------------------------------------------------
# Use rpm-ostree inside the image build, then commit to the ostree layer.
# Note: we cache package metadata to speed up CI.
RUN --mount=type=cache,target=/var/cache/dnf \
    --mount=type=cache,target=/var/cache \
    rpm-ostree install -y \
      # --- Wine stack
      wine winetricks cabextract \
      # common 32-bit runtime bits for Wine/Proton (expand as needed for your GPUs)
      glibc.i686 zlib.i686 libgcc.i686 \
      mesa-dri-drivers.i686 vulkan-loader.i686 \
      alsa-lib.i686 libX11.i686 libxcb.i686 freetype.i686 \
      # --- Proton helpers
      protontricks \
      # --- Virtualization stack for WinApps VM
      qemu-kvm libvirt virt-install virt-manager edk2-ovmf swtpm \
      # --- RDP + helpers for WinApps
      freerdp nmap-ncat remmina \
      # --- build-time tools (you can remove later if you prefer vendoring)
      git curl tar \
    && rpm-ostree cleanup -m \
    && ostree container commit

# ---- 2) Systemd enablement for libvirt (so WinApps VM can run) --------------
# Preset file (idempotent) and explicit enable as a belt-and-suspenders.
RUN printf '%s\n' "enable libvirtd.service" > /usr/lib/systemd/system-preset/90-ci-winapps.preset \
    && systemctl enable libvirtd.service

# ---- 3) Add WinApps source into the image -----------------------------------
# We vendor the repo into /usr/share/winapps at build time (pin via WINAPPS_REF).
RUN rm -rf "${WINAPPS_DIR}" \
    && git clone --depth=1 "${WINAPPS_REPO}" "${WINAPPS_DIR}" \
    && (cd "${WINAPPS_DIR}" && [ "${WINAPPS_REF}" = "main" ] || git fetch origin "${WINAPPS_REF}" && git checkout "${WINAPPS_REF}")

# Provide a stable launcher path
# Many users expect `/usr/bin/winapps` to exist; we wrap the repo's launcher.
RUN install -Dm0755 /dev/stdin "${WINAPPS_BIN}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Thin wrapper that runs the upstream launcher from /usr/share/winapps
exec /usr/bin/env bash /usr/share/winapps/winapps "$@"
EOF

# ---- 4) First-boot helper commands (ujust/just) ------------------------------
# Bazzite includes 'ujust' (a thin wrapper around 'just') reading /usr/share/ublue-os/justfiles/*.
# We drop a small set of tasks to smooth first-time setup.
RUN install -d /usr/share/ublue-os/justfiles

COPY files/just/win-wine-proton.just /usr/share/ublue-os/justfiles/50-win-wine-proton.just
COPY files/just/winapps.just        /usr/share/ublue-os/justfiles/60-winapps.just

# ---- 5) Desktop entries and UX polish (optional now, extend later) ----------
# You can ship desktop entries for common flows; we start with a placeholder dir.
RUN install -d /usr/share/applications

# Finalize the ostree layer
RUN ostree container commit

# ---- 6) Defaults & docs in the image (optional) ------------------------------
# Small MOTD-style hint so users know what to run.
RUN install -Dm0644 /dev/stdin /etc/motd.d/20-ci-winapps.motd <<'EOF'
Windows apps support is installed.
First-time setup:
  ujust setup-wine
  ujust setup-proton-tools
  ujust setup-winapps
EOF
RUN ostree container commit