# CI-OS v01 ISO Build Guide

This guide covers building CI-OS container images and ISOs locally and via GitHub Actions.

## Prerequisites

### For Local Building
- **Podman or Docker**: Container runtime for building images
- **System Requirements**: 
  - 8GB+ RAM recommended
  - 20GB+ free disk space
  - Fedora/RHEL-based system preferred

```bash
# Install podman on Fedora
sudo dnf install podman

# Install podman on Ubuntu/Debian  
sudo apt install podman
```

### For ISO Generation
- **GitHub Actions** (recommended): Fully automated build and release
- **build-container-installer**: For local ISO generation

## Quick Start

### 1. Local Container Build

```bash
# Clone the repository
git clone https://github.com/companionintelligence/CI-OS.git
cd CI-OS

# Build regular variant
./scripts/build-iso.sh regular

# Build NVIDIA variant
./scripts/build-iso.sh nvidia

# Build both variants with clean rebuild
./scripts/build-iso.sh both --clean --verbose
```

### 2. GitHub Actions (ISO Generation)

**Automatic Builds:**
- Weekly builds every Sunday at 2 AM UTC
- Triggered on pushes to `main` branch that modify Containerfiles

**Manual Builds:**
1. Go to GitHub Actions tab
2. Select "Build and Publish CI-OS ISOs" workflow
3. Click "Run workflow" button
4. Choose branch and options
5. Wait for build completion (~45-60 minutes)

**Results:**
- Container images published to `ghcr.io/companionintelligence/ci-os`
- Bootable ISOs published to GitHub Releases
- Signed images with cosign verification
- Checksums for verification

## Build Process Details

### Container Build Stages

1. **Base Image**: Pull Bazzite or Bazzite-NVIDIA as foundation
2. **System Packages**: Install Wine, Proton, virtualization stack
3. **CI-OS Integration**: Add ujust commands and scripts
4. **Configuration**: Set up environment variables and defaults
5. **Cleanup**: Remove build artifacts and optimize size

### ISO Generation Process

1. **Container Pull**: Download built container images
2. **Installer Creation**: Use `build-container-installer` tool
3. **ISO Assembly**: Create bootable installer ISO
4. **Verification**: Generate checksums and sign artifacts
5. **Publishing**: Upload to GitHub Releases

## Local Build Options

### Basic Build Commands

```bash
# Regular variant only
./scripts/build-iso.sh regular

# NVIDIA variant only  
./scripts/build-iso.sh nvidia

# Both variants
./scripts/build-iso.sh both
```

### Build Options

```bash
# Clean build (removes existing images first)
./scripts/build-iso.sh both --clean

# Verbose output for debugging
./scripts/build-iso.sh regular --verbose

# Push to registry after build
./scripts/build-iso.sh nvidia --push

# Combined options
./scripts/build-iso.sh both --clean --verbose --push
```

### Manual Container Build

```bash
# Regular variant
podman build -f Containerfile -t ci-os:latest .

# NVIDIA variant  
podman build -f Containerfile.nvidia -t ci-os-nvidia:latest .

# With build arguments
podman build \
  --build-arg FEDORA_MAJOR_VERSION=41 \
  --build-arg WINE_VERSION=9.0 \
  -f Containerfile \
  -t ci-os:v01 .
```

## ISO Generation (Advanced)

### Using build-container-installer

```bash
# Install build-container-installer
podman pull ghcr.io/jasonn3/build-container-installer:latest

# Generate ISO from local container
podman run --rm -it \
  -v $(pwd):/workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/jasonn3/build-container-installer:latest \
  --image-name ci-os \
  --image-tag latest \
  --version 41 \
  --variant Kinoite \
  --iso-name CI-OS-v01-regular.iso
```

### Custom ISO Configuration

Edit GitHub Actions workflow (`.github/workflows/build-iso.yml`) to customize:

- **Build Schedule**: Modify `cron` schedule
- **Fedora Version**: Change `fedora_version` matrix
- **ISO Names**: Modify `iso_name` generation
- **Build Options**: Add custom build arguments

## Troubleshooting

### Common Build Issues

**Out of Space:**
```bash
# Clean up old containers and images
podman system prune -a

# Check disk usage
df -h
podman system df
```

**Build Failures:**
```bash
# Enable verbose logging
./scripts/build-iso.sh regular --verbose

# Check build logs
podman logs <container-id>

# Manual debugging
podman run -it <image-id> /bin/bash
```

**Permission Issues:**
```bash
# Ensure user is in docker/podman group
sudo usermod -a -G docker $USER
# Log out and back in

# Check SELinux (Fedora/RHEL)
sudo setsebool -P container_manage_cgroup on
```

### GitHub Actions Issues

**Build Timeout:**
- Large images may exceed 6-hour limit
- Optimize Containerfile to reduce build time
- Remove unnecessary packages

**Registry Permissions:**
- Ensure GITHUB_TOKEN has packages:write permission
- Check organization settings for package publishing

**Signing Failures:**
- Verify cosign installation in workflow
- Check key generation and storage

## Advanced Customization

### Adding Packages

Edit `Containerfile` or `Containerfile.nvidia`:

```dockerfile
RUN --mount=type=cache,target=/var/cache/dnf \
    rpm-ostree install -y \
      your-package-here \
      another-package \
    && rpm-ostree cleanup -m \
    && ostree container commit
```

### Custom ujust Commands

1. Create new `.just` file in `files/just/`
2. Add to Containerfile:
```dockerfile
COPY files/just/my-commands.just /usr/share/ublue-os/justfiles/60-my-commands.just
```

### Environment Variables

Add to Containerfile:
```dockerfile
RUN echo 'export MY_VARIABLE="value"' >> /etc/environment
```

## Verification

### Container Verification

```bash
# Test container startup
podman run --rm ci-os:latest echo "Test successful"

# Test Wine installation
podman run --rm ci-os:latest wine --version

# Test ujust commands
podman run --rm ci-os:latest just --list
```

### ISO Verification

```bash
# Verify checksum
sha256sum -c CI-OS-v01-regular.iso-CHECKSUM

# Test in VM
qemu-kvm -m 4G -cdrom CI-OS-v01-regular.iso
```

### Signature Verification

```bash
# Install cosign
curl -O -L "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
sudo chmod +x /usr/local/bin/cosign

# Verify container signature
cosign verify \
  --certificate-identity-regexp=https://github.com/companionintelligence \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/companionintelligence/ci-os/ci-os:latest
```

## Best Practices

### Build Optimization

1. **Layer Caching**: Group related commands to leverage Docker layer caching
2. **Multi-stage Builds**: Use separate stages for build dependencies
3. **Package Cleanup**: Always run `rpm-ostree cleanup -m` after installs
4. **Cache Mounts**: Use `--mount=type=cache` for package manager caches

### Security

1. **Pin Versions**: Use specific package versions where possible
2. **Minimal Images**: Only install required packages
3. **Regular Updates**: Keep base images and dependencies updated
4. **Signature Verification**: Always verify signed images

### CI/CD

1. **Branch Protection**: Require reviews for Containerfile changes
2. **Test Builds**: Use pull requests to test changes before merge
3. **Release Automation**: Use semantic versioning for releases
4. **Monitoring**: Set up notifications for build failures

## Resources

- [Bazzite Documentation](https://bazzite.gg/)
- [Universal Blue Guide](https://universal-blue.org/)
- [Podman Documentation](https://docs.podman.io/)
- [build-container-installer](https://github.com/jasonn3/build-container-installer)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)