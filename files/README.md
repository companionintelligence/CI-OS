# CI OS Container Files

This directory contains files that are copied into the container image during the build process.

## Structure

```
files/
└── just/              # ujust justfile fragments
    ├── win-wine-proton.just  # Wine and Proton setup automation  
    └── winapps.just          # WinApps VM provisioning
```

## ujust Integration

These justfiles are copied to `/usr/share/ublue-os/justfiles/` in the container image with numeric prefixes:

- `50-win-wine-proton.just` - Wine/Proton setup commands
- `60-winapps.just` - WinApps VM setup commands

The numeric prefixes ensure proper ordering when multiple justfiles are present.

## Available Commands

After the container is deployed, users can run:

```bash
# Wine setup
ujust setup-wine

# Proton tools configuration  
ujust setup-proton-tools

# WinApps VM setup (requires Windows ISO)
ujust setup-winapps WIN_ISO=/path/to/windows.iso VIRTIO_ISO=/path/to/virtio-win.iso
```

## Customization

To add more automation commands:

1. Create a new `.just` file in this directory
2. Add a `COPY` statement in the Containerfile
3. Use appropriate numeric prefix for ordering (e.g., `70-your-feature.just`)

The justfiles use standard [just](https://github.com/casey/just) syntax with variable substitution support.