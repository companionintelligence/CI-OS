#!/bin/bash
# Development Environment Setup for CI-OS Bazzite Fork
# Sets up container development environment for building CI-OS images

set -euo pipefail

echo "Setting up CI-OS development environment..."

# Check system requirements
echo "Checking system requirements..."

# Check for podman/docker
if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    echo "Installing podman..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y podman
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y podman
    else
        echo "Error: Cannot install podman. Please install it manually."
        exit 1
    fi
fi

# Check for git
if ! command -v git >/dev/null 2>&1; then
    echo "Installing git..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y git
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y git
    fi
fi

# Set up development directories
echo "Setting up development directories..."
mkdir -p {configs,scripts,docs}

# Clone Bazzite reference (for understanding the base system)
if [ ! -d "bazzite-reference" ]; then
    echo "Cloning Bazzite reference repository..."
    git clone https://github.com/ublue-os/bazzite.git bazzite-reference
fi

# Set up container development
echo "Setting up container development tools..."

# Pull base images
echo "Pulling base Bazzite images..."
podman pull ghcr.io/ublue-os/bazzite:latest
podman pull ghcr.io/ublue-os/bazzite-nvidia:latest

# Test container runtime
echo "Testing container runtime..."
if podman run --rm ghcr.io/ublue-os/bazzite:latest cat /etc/os-release; then
    echo "✅ Container runtime working correctly"
else
    echo "❌ Container runtime test failed"
    exit 1
fi

# Set up Git hooks for development
echo "Setting up Git hooks..."
mkdir -p .git/hooks

cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
# Pre-commit hook to validate Containerfiles
echo "Validating Containerfiles..."
if [ -f "Containerfile.ci-os" ]; then
    podman build --dry-run -f Containerfile.ci-os .
fi
if [ -f "Containerfile.ci-os-nvidia" ]; then  
    podman build --dry-run -f Containerfile.ci-os-nvidia .
fi
EOF

chmod +x .git/hooks/pre-commit

# Create development configuration
cat > .devcontainer.json << 'EOF'
{
    "name": "CI-OS Development",
    "image": "registry.fedoraproject.org/fedora:latest",
    "features": {
        "ghcr.io/devcontainers/features/podman-in-podman:1": {},
        "ghcr.io/devcontainers/features/git:1": {}
    },
    "mounts": [
        "source=/var/run/podman,target=/var/run/podman,type=bind"
    ],
    "containerEnv": {
        "CONTAINER_ENV": "development"
    }
}
EOF

echo ""
echo "🎉 Development environment setup complete!"
echo ""
echo "Next steps:"
echo "1. Build the base image: podman build -f Containerfile.ci-os -t ci-os:dev ."
echo "2. Build the NVIDIA image: podman build -f Containerfile.ci-os-nvidia -t ci-os-nvidia:dev ."
echo "3. Test the images: ./scripts/test-containers.sh"
echo "4. Review the bazzite-reference/ directory to understand the base system"
echo ""
echo "Development commands:"
echo "  - Build base: podman build -f Containerfile.ci-os -t ci-os:dev ."
echo "  - Test build: podman run --rm -it ci-os:dev /bin/bash"  
echo "  - Run tests: ./scripts/test-containers.sh"