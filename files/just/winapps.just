# ujust / justfile fragment: WinApps VM provisioning

# Choose your backend via the BACKEND var: libvirt (default) or podman
# Usage:
#   ujust setup-winapps
#   ujust setup-winapps BACKEND=libvirt
#   ujust setup-winapps BACKEND=podman
setup-winapps BACKEND="libvirt" WIN_ISO="" VIRTIO_ISO="":
    @echo ">>> Preparing WinApps with backend: {{BACKEND}}"
    if [ "{{BACKEND}}" = "libvirt" ]; then \
      echo "Enabling and starting libvirtd..."; \
      sudo systemctl enable --now libvirtd; \
      echo "Adding current user to libvirt & kvm groups (may require log out/in)..."; \
      sudo usermod -aG libvirt,kvm "$USER" || true; \
    fi
    echo
    echo ">>> WinApps repo: /usr/share/winapps"
    echo ">>> You must supply a Windows ISO path to install the VM the first time."
    if [ -z "{{WIN_ISO}}" ]; then \
      echo "No WIN_ISO provided. Example:"; \
      echo "  ujust setup-winapps WIN_ISO=/path/to/Win11.iso VIRTIO_ISO=/path/virtio-win.iso"; \
      exit 1; \
    fi
    echo
    echo ">>> Running WinApps installer..."
    if [ "{{BACKEND}}" = "libvirt" ]; then \
      /usr/bin/env bash /usr/share/winapps/install.sh --backend libvirt --iso "{{WIN_ISO}}" --virtio "{{VIRTIO_ISO}}"; \
    else \
      /usr/bin/env bash /usr/share/winapps/install.sh --backend podman --iso "{{WIN_ISO}}" --virtio "{{VIRTIO_ISO}}"; \
    fi
    echo
    echo ">>> If successful, .desktop launchers for detected Windows apps will be created."
    echo ">>> You can re-run 'ujust setup-winapps' to adjust settings or rebuild the VM."