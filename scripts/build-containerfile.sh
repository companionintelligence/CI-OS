#!/bin/bash
# CI OS Containerfile (v0) Build and Test Script

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="ci-os-bazzite"
TAG="dev"

echo "=== CI OS Containerfile (v0) Build Script ==="
echo "Project Directory: $PROJECT_DIR"
echo "Image: $IMAGE_NAME:$TAG"
echo ""

# Check if Docker/Podman is available
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
else
    echo "❌ Neither Docker nor Podman found. Please install one of them."
    exit 1
fi

echo "📦 Using container runtime: $CONTAINER_CMD"

# Build the container
echo "🔨 Building container image..."
cd "$PROJECT_DIR"

$CONTAINER_CMD build -t "$IMAGE_NAME:$TAG" -f Containerfile . \
    --progress=plain \
    --build-arg BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable

echo ""
echo "✅ Container build completed successfully!"
echo ""
echo "📋 Next steps:"
echo ""
echo "1. 📋 List the built image:"
echo "   $CONTAINER_CMD images | grep $IMAGE_NAME"
echo ""
echo "2. 🚀 Deploy to your system (requires Fedora/Universal Blue):"
echo "   rpm-ostree rebase ostree-unverified-registry:localhost/$IMAGE_NAME:$TAG"
echo "   systemctl reboot"
echo ""
echo "3. 🎮 After reboot, run first-time setup:"
echo "   ujust setup-wine"
echo "   ujust setup-proton-tools"
echo "   ujust setup-winapps WIN_ISO=/path/to/Windows.iso VIRTIO_ISO=/path/to/virtio-win.iso"
echo ""
echo "4. 🏷️ To publish to a registry:"
echo "   $CONTAINER_CMD tag $IMAGE_NAME:$TAG ghcr.io/yourorg/ci-os-bazzite:latest"
echo "   $CONTAINER_CMD push ghcr.io/yourorg/ci-os-bazzite:latest"
echo ""
echo "For more details, see: docs/containerfile-guide.md"