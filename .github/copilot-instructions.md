# Copilot Instructions for CI-OS

## Project Overview

CI-OS is a bootable Linux distribution that creates custom ISOs based on [Bazzite](https://bazzite.gg/) with pre-configured Windows application compatibility. This project focuses on providing seamless Windows app integration through Wine, Proton, and WinApps in a gaming-optimized Linux environment.

### Current State
This repository currently contains:
- Comprehensive documentation (README.md)
- GitHub Actions workflow for building ISOs  
- Brand assets and logos
- Basic project structure

**Implementation needed**: Containerfiles, ujust commands, setup scripts, and documentation files referenced in the README.md.

### Core Technologies
- **Base**: Bazzite (Fedora Silverblue derivative optimized for gaming)
- **Containerization**: OCI containers built with rpm-ostree
- **Windows Compatibility**: Wine, Proton, WinApps virtualization
- **Build System**: GitHub Actions with container-to-ISO conversion
- **Package Management**: rpm-ostree (immutable OS) + ujust commands
- **Variants**: Regular and NVIDIA-optimized builds

## Implementation Roadmap

### Priority 1: Core Build Files
1. **Create Containerfile** - Base definition for regular CI-OS variant
2. **Create Containerfile.nvidia** - NVIDIA-optimized variant with drivers
3. **Set up files/just/** - ujust command definitions for setup and management
4. **Create setup scripts** - First-time configuration and Wine/Proton setup

### Priority 2: Documentation
1. **docs/iso-build-guide.md** - Complete building documentation
2. **docs/installation-guide.md** - Detailed installation walkthrough  
3. **docs/quick-start-guide.md** - Get running fast

### Priority 3: Testing & Validation
1. **Local build testing** - Containerfile validation
2. **ISO generation testing** - Full workflow validation
3. **Windows app compatibility testing** - Wine/Proton functionality

## Architecture & Build System

### Container-to-ISO Workflow
1. **Containerfiles** define the base OS modifications
2. **GitHub Actions** builds container images (regular + NVIDIA variants)
3. **build-container-installer** converts containers to bootable ISOs
4. **Signed images** and checksums published to GitHub Releases

### File Organization
```
/
├── .github/
│   ├── workflows/build-iso.yml    # Main build pipeline
│   └── copilot-instructions.md    # This file
├── assets/logos/                  # Brand assets and logos
├── Containerfile                  # Regular variant build definition (to be created)
├── Containerfile.nvidia           # NVIDIA variant build definition (to be created)
├── files/                         # OS customization files (to be created)
│   ├── just/                      # ujust command definitions
│   └── scripts/                   # Setup and configuration scripts
├── docs/                          # Documentation (to be created)
├── README.md                      # Main project documentation
└── LICENSE.md                     # Licensing information
```

## Development Guidelines

### Containerfile Best Practices
- Use rpm-ostree for package installation with proper cleanup
- Always run `rpm-ostree cleanup -m && ostree container commit` after installs
- Leverage build caches: `--mount=type=cache,target=/var/cache/dnf`
- Keep regular and NVIDIA variants synchronized where possible
- Use multi-stage builds for complex setups

### ujust Command Conventions  
- Prefix CI-OS specific commands: `setup-ci-os`, `ci-os-info`
- Use descriptive names: `setup-wine`, `setup-proton`, `setup-winapps`
- Include help text and error handling in all commands
- Support both interactive and non-interactive modes
- NVIDIA-specific commands: `setup-ci-os-nvidia`, `nvidia-info`

### Version Management
- ISOs tagged with format: `v01-YYYYMMDD` (dated) and `v01-latest`
- Container images follow same tagging convention
- Base version currently: `v01` (Bazzite Fedora 41)
- Pin upstream dependencies to stable commits where possible

### Code Modifications
- **Minimal Changes**: Only modify what's necessary for the specific issue
- **Test Both Variants**: Ensure changes work for both regular and NVIDIA builds
- **Preserve Functionality**: Don't break existing ujust commands or workflows
- **Documentation Updates**: Update README.md for user-facing changes only

## Build & Testing

### Local Development
```bash
# Build container locally (testing only - ISOs built via GitHub Actions)
podman build -f Containerfile -t ci-os:test .
podman build -f Containerfile.nvidia -t ci-os-nvidia:test .
```

### GitHub Actions Workflow
- **Automatic**: Weekly builds every Sunday at 2 AM UTC
- **Manual**: Via GitHub Actions "Run workflow" button
- **On Push**: Triggered by changes to Containerfiles or workflow files
- **Outputs**: Signed container images + bootable ISOs + checksums

### Testing Approach
- **Container Builds**: Validate both variants build successfully
- **ISO Creation**: GitHub Actions handles full ISO build process
- **Manual Testing**: Boot ISOs in VMs for integration testing
- **ujust Commands**: Test setup commands work as expected

## Windows Compatibility Stack

### Wine Integration
- Pre-configured Wine environment with 32-bit libraries
- Winetricks for Windows components installation  
- Mesa and Vulkan drivers with 32-bit support
- Command patterns: `wine program.exe`, `ujust run-wine <app>`

### Proton Support
- Steam Proton compatibility tools included
- Protontricks for per-game configuration
- Lutris integration for non-Steam games
- Command patterns: `ujust setup-proton`, gaming-focused optimizations

### WinApps (VM-based)
- QEMU/KVM stack for Windows VM integration
- Seamless Linux app appearance for Windows software
- Hardware acceleration and GPU passthrough support
- Command patterns: `ujust setup-winapps`, `ujust list-winapps`

## Domain-Specific Knowledge

### Bazzite Foundation
- Fedora Silverblue derivative optimized for gaming
- Immutable OS with rpm-ostree package management
- KDE Plasma desktop environment
- Gaming kernel and hardware acceleration pre-configured

### Immutable OS Concepts
- System modifications via container layers, not direct package installs
- User data and configs preserved across OS updates
- rollback capabilities for system recovery
- Container-based customization workflow

### NVIDIA Considerations
- NVIDIA variant includes proprietary drivers
- GPU acceleration for gaming and Wine/Proton
- CUDA support for compatible applications
- Specific optimization commands for NVIDIA systems

## AI Assistant Guidelines

### When Making Changes
1. **Understand the dual-variant system** - most changes need to apply to both regular and NVIDIA builds
2. **Test container builds locally** before pushing changes
3. **Update documentation** only when adding user-facing features
4. **Preserve existing ujust commands** and their interfaces
5. **Consider Windows compatibility** impact for any Wine/Proton changes

### Common Tasks
- **Adding packages**: Modify Containerfile(s) with proper rpm-ostree syntax
- **New ujust commands**: Add to `files/just/` with consistent naming
- **Build fixes**: Focus on GitHub Actions workflow or Containerfile issues  
- **Documentation updates**: Keep README.md current with feature changes

### Things to Avoid
- Don't modify the base Bazzite functionality unnecessarily
- Don't break existing Windows app compatibility
- Don't change the ISO build process without careful testing
- Don't add heavyweight dependencies that significantly increase ISO size
- Don't modify LICENSE.md without explicit approval

## Security & Compliance

### Container Security
- All container images are signed with cosign
- Base images pinned to specific versions
- Regular dependency updates via automated workflows

### Licensing Compliance  
- Respect upstream licenses (Bazzite, Wine, Proton components)
- CI-OS assets and branding are proprietary to Companion Intelligence
- Third-party components maintain their original licenses

### Build Reproducibility
- Checksums provided for all ISO releases
- Container images tagged with build dates
- GitHub Actions provides full build audit trail

## Summary

This repository creates specialized Linux distributions focused on Windows application compatibility and gaming performance. All modifications should support this core mission while maintaining system stability and user experience. 

When contributing to CI-OS:
1. Understand the containerized OS build process
2. Test both regular and NVIDIA variants
3. Maintain Windows app compatibility
4. Follow immutable OS best practices
5. Document user-facing changes appropriately

For questions about CI-OS architecture or implementation details, refer to the README.md and GitHub Actions workflow files.