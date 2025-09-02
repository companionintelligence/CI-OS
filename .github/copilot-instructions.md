# CI-OS Bazzite Gaming Distribution (ISO v01)

Always reference these instructions first and fallback to search or bash commands only when you encounter unexpected information that does not match the info here.

CI-OS is a custom Bazzite-based Linux gaming distribution optimized for running Windows applications through Wine, Proton, and WinApps. Built using Universal Blue's container-based approach with Containerfiles, it provides seamless Windows app compatibility on a modern Fedora-based immutable operating system.

## Architecture Overview

### Bazzite Foundation
- **Base System**: Fedora-based immutable OS via Universal Blue
- **Gaming Focus**: Steam, Proton, and gaming optimizations built-in
- **Container Builds**: Uses Containerfiles instead of traditional ISO building
- **Atomic Updates**: Immutable system with atomic updates via ostree

### Windows App Integration
- **Wine**: Windows API compatibility layer for running Windows applications
- **Proton**: Steam's Wine fork optimized for gaming (also works for non-Steam apps)
- **WinApps**: Seamless Windows app integration (https://github.com/winapps-org/winapps)
- **Prerequisites**: All dependencies for Windows app compatibility pre-installed

## Working Effectively

### Bootstrap Environment
- Update system: `rpm-ostree upgrade` (requires reboot)
- Install development tools: `sudo rpm-ostree install git curl wget vim nano htop tree`
- Install podman/docker: `sudo rpm-ostree install podman docker-ce` (if not included)
- NEVER CANCEL: System updates may take 10-30 minutes. Set timeout to 45+ minutes.
- Reboot required after rpm-ostree operations: `systemctl reboot`

### Container Build System
- Build base image: `podman build -f Containerfile.ci-os -t ci-os:base .`
- Build NVIDIA variant: `podman build -f Containerfile.ci-os-nvidia -t ci-os:nvidia .`
- Test builds: `podman run --rm -it ci-os:base /bin/bash`
- Push to registry: `podman push ci-os:base ghcr.io/companionintelligence/ci-os:latest`
- NEVER CANCEL: Container builds may take 20-60 minutes. Set timeout to 90+ minutes.

### WinApps Setup Validation
- Check Wine installation: `wine --version`
- Verify Proton: `ls ~/.steam/steam/steamapps/common/`
- Test WinApps: `winapps check` (if available)
- Windows app prerequisites: `winapps doctor` (diagnostic command)
- These validations complete in <5 seconds each

### Development Environment Setup
- Clone Bazzite source: `git clone https://github.com/ublue-os/bazzite.git`
- Set up build environment: `./setup-dev-environment.sh`
- Test container builds: `just build` (if using justfile)
- Local development: `podman build --target development .`

## Validation Scenarios

### ALWAYS test functionality after making changes:
- Build container images: `podman build -f Containerfile.ci-os -t ci-os:test .`
- Test Wine integration: `podman run --rm ci-os:test wine --version`
- Validate WinApps: `podman run --rm -v /tmp:/tmp ci-os:test winapps check`
- Check base system: `podman run --rm ci-os:test cat /etc/os-release`

### Manual Testing Requirements
- Create test environment: `mkdir -p /tmp/ci-os-test && cd /tmp/ci-os-test`
- Test Windows app: Create simple Windows executable test in container
- Wine compatibility test: `wine notepad.exe` (basic Windows app test)
- WinApps integration: Test seamless app integration on host system
- Container tests complete in <30 seconds each

### Image Testing (when images exist)
- Run container validation: `./scripts/test-containers.sh`
- Test NVIDIA variant: `podman run --rm --device nvidia.com/gpu=all ci-os:nvidia nvidia-smi`
- Performance testing: Run gaming benchmarks in container
- NEVER CANCEL: Full system testing can take 15-45 minutes. Set timeout to 60+ minutes.

## Build & Test Commands

### Working Commands (Container-Based)
- `podman build -f Containerfile.ci-os .` - Build base image (20-60 min, NEVER CANCEL)
- `podman images` - List built container images (~0.1 sec)
- `wine --version` - Check Wine installation (~0.1 sec)  
- `podman run --rm ci-os:base wine --version` - Test Wine in container (~2 sec)
- `rpm-ostree status` - Check system state (~1 sec)

### Commands That Require External Dependencies
- GitHub Actions workflows - Require push to trigger automated builds
- Image registry operations - Require proper authentication to ghcr.io
- NVIDIA testing - Requires NVIDIA hardware and drivers
- WinApps integration - Requires host system setup for seamless integration

### Timing Expectations
- **NEVER CANCEL** any container build or system operation
- Container image pulls: 5-15 minutes (timeout: 30+ minutes)
- Full container builds: 20-60 minutes (timeout: 90+ minutes)
- System package updates: 10-30 minutes (timeout: 45+ minutes)
- Wine/Proton setup: 5-15 minutes (timeout: 30+ minutes)
- Image testing: 2-10 minutes per test (timeout: 15+ minutes)

## Critical Validation Steps

### Before Making Changes
- Always check container build status: `podman images | grep ci-os`
- Verify base system: `cat /etc/os-release` to confirm Fedora/Bazzite base
- Test Wine functionality: `wine --version` or in container

### After Making Changes  
- Build test container: `podman build -f Containerfile.ci-os -t ci-os:test .`
- Test Windows app compatibility: Run simple Windows executable
- Validate WinApps integration: Check app appears in system menus
- ALWAYS verify container runs without errors: `podman run --rm ci-os:test /bin/bash -c "echo 'Container OK'"`

## Common Locations

### Key Files
- **Containerfiles**: `Containerfile.ci-os`, `Containerfile.ci-os-nvidia`
- **GitHub Actions**: `.github/workflows/` directory for automated builds
- **Configuration files**: `configs/` directory for Wine, WinApps, Proton setup
- **Scripts**: `scripts/` directory for helper and setup scripts
- **Documentation**: `docs/` directory for build and usage guides

### Important Files
- `Containerfile.ci-os` - Base Bazzite image with Wine/WinApps integration
- `Containerfile.ci-os-nvidia` - NVIDIA variant for GPU acceleration
- `.github/workflows/build.yml` - Automated container build and publish
- `configs/wine/` - Wine configuration and Windows app compatibility
- `configs/winapps/` - WinApps configuration and app definitions
- `scripts/setup-development.sh` - Development environment setup
- `scripts/test-containers.sh` - Container testing and validation

### Configuration Directories
- **Wine setup**: `configs/wine/` - Wine prefixes and compatibility settings  
- **WinApps config**: `configs/winapps/` - Windows app integration settings
- **Proton helpers**: `configs/proton/` - Proton version management and helpers
- **GitHub Actions**: `.github/workflows/` - CI/CD pipeline definitions

## Known Limitations

- Container builds require podman/docker and may need elevated privileges
- Wine applications require X11 forwarding or Wayland compatibility for GUI apps
- NVIDIA variant requires NVIDIA Container Toolkit for GPU acceleration
- WinApps integration requires host system configuration for seamless operation
- Some Windows applications may have compatibility issues despite Wine/Proton
- Immutable system means traditional package management is limited to containers

## Troubleshooting

- Container build failures: Check base image availability and network connectivity
- Wine issues: Verify Windows dependencies and compatibility layers
- WinApps problems: Check host system integration and menu configuration  
- NVIDIA issues: Ensure NVIDIA drivers and container toolkit are properly installed
- Permission errors: Use `podman unshare` for rootless container debugging
- Missing directories: Create manually: `mkdir -p configs/wine configs/winapps configs/proton`