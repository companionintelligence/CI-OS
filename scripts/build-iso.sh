#!/usr/bin/env bash
# =====================================================================================
# CI-OS Local ISO Builder
# =====================================================================================
# This script builds CI-OS container images and converts them to bootable ISOs locally
# for testing before pushing to GitHub Actions.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
REGISTRY="localhost"
IMAGE_NAME="ci-os"
IMAGE_TAG="local-$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Help function
show_help() {
    cat << EOF
CI-OS Local ISO Builder

Usage: $0 [OPTIONS] [VARIANT]

VARIANTS:
    regular     Build regular CI-OS ISO (default)
    nvidia      Build CI-OS NVIDIA ISO
    both        Build both variants

OPTIONS:
    -h, --help              Show this help message
    -c, --clean             Clean build directory before building
    -k, --keep-containers   Keep container images after ISO build
    -v, --verbose           Enable verbose output
    --no-iso                Only build containers, skip ISO generation
    --fedora-version VER    Fedora version to use (default: 41)

Examples:
    $0                      # Build regular ISO
    $0 nvidia               # Build NVIDIA ISO
    $0 both --clean         # Clean build and create both ISOs
    $0 regular --no-iso     # Only build container, skip ISO

EOF
}

# Parse command line arguments
VARIANT="regular"
CLEAN_BUILD=false
KEEP_CONTAINERS=false
VERBOSE=false
BUILD_ISO=true
FEDORA_VERSION="41"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        -k|--keep-containers)
            KEEP_CONTAINERS=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            set -x
            shift
            ;;
        --no-iso)
            BUILD_ISO=false
            shift
            ;;
        --fedora-version)
            FEDORA_VERSION="$2"
            shift 2
            ;;
        regular|nvidia|both)
            VARIANT="$1"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Ensure we're in the project root
cd "$PROJECT_ROOT"

# Clean build directory if requested
if [[ "$CLEAN_BUILD" == true ]]; then
    log_info "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

# Create build directory
mkdir -p "$BUILD_DIR"

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v podman >/dev/null 2>&1; then
        missing_deps+=("podman")
    fi
    
    if [[ "$BUILD_ISO" == true ]] && ! command -v mkksiso >/dev/null 2>&1; then
        log_warn "mkksiso not found. Install lorax for ISO building."
        log_info "On Fedora: sudo dnf install lorax"
        log_info "Alternatively, use --no-iso to skip ISO generation"
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
    
    log_success "Dependencies check passed"
}

# Build container image
build_container() {
    local variant="$1"
    local containerfile="Containerfile"
    local full_image_name="$REGISTRY/$IMAGE_NAME"
    
    if [[ "$variant" == "nvidia" ]]; then
        containerfile="Containerfile.nvidia"
        full_image_name="$REGISTRY/$IMAGE_NAME-nvidia"
    fi
    
    log_info "Building $variant container image..."
    log_info "Using: $containerfile"
    log_info "Target: $full_image_name:$IMAGE_TAG"
    
    podman build \
        -f "$containerfile" \
        -t "$full_image_name:$IMAGE_TAG" \
        -t "$full_image_name:latest" \
        .
    
    log_success "Container build completed: $full_image_name:$IMAGE_TAG"
    
    # Save container info for ISO building
    echo "$full_image_name:$IMAGE_TAG" > "$BUILD_DIR/container-$variant.txt"
}

# Build ISO from container
build_iso() {
    local variant="$1"
    local container_image_file="$BUILD_DIR/container-$variant.txt"
    
    if [[ ! -f "$container_image_file" ]]; then
        log_error "Container image info not found: $container_image_file"
        return 1
    fi
    
    local container_image="$(cat "$container_image_file")"
    local iso_name="CI-OS-v01-$variant-$FEDORA_VERSION-$(date +%Y%m%d).iso"
    local iso_path="$BUILD_DIR/$iso_name"
    
    log_info "Building ISO for $variant variant..."
    log_info "Container: $container_image"
    log_info "ISO Output: $iso_path"
    
    # Note: This is a simplified approach. In production, we use the jasonn3/build-container-installer
    # GitHub Action which handles the complex process of converting container images to bootable ISOs.
    # For local testing, we would need to set up the full lorax/anaconda toolchain.
    
    log_warn "Local ISO building requires complex toolchain setup."
    log_info "For now, container images are built and tagged."
    log_info "Use GitHub Actions workflow for full ISO generation."
    log_info "Container image available as: $container_image"
    
    # Create a placeholder info file
    cat > "$BUILD_DIR/iso-$variant-info.txt" << EOF
CI-OS $variant ISO Build Info
============================
Date: $(date)
Container Image: $container_image
ISO Name: $iso_name
Fedora Version: $FEDORA_VERSION

To build actual ISO:
1. Push container to registry
2. Use GitHub Actions workflow: build-iso.yml
3. Or set up local lorax/anaconda environment

Container can be tested with:
podman run --rm -it $container_image bash
EOF
    
    log_success "Container ready for ISO conversion: $container_image"
}

# Cleanup containers
cleanup_containers() {
    if [[ "$KEEP_CONTAINERS" == false ]]; then
        log_info "Cleaning up container images..."
        podman rmi "$REGISTRY/$IMAGE_NAME:$IMAGE_TAG" 2>/dev/null || true
        podman rmi "$REGISTRY/$IMAGE_NAME:latest" 2>/dev/null || true
        podman rmi "$REGISTRY/$IMAGE_NAME-nvidia:$IMAGE_TAG" 2>/dev/null || true
        podman rmi "$REGISTRY/$IMAGE_NAME-nvidia:latest" 2>/dev/null || true
    fi
}

# Main build process
main() {
    log_info "Starting CI-OS local build process..."
    log_info "Variant: $VARIANT"
    log_info "Build directory: $BUILD_DIR"
    log_info "Build ISO: $BUILD_ISO"
    
    check_dependencies
    
    case "$VARIANT" in
        regular)
            build_container "regular"
            [[ "$BUILD_ISO" == true ]] && build_iso "regular"
            ;;
        nvidia)
            build_container "nvidia"
            [[ "$BUILD_ISO" == true ]] && build_iso "nvidia"
            ;;
        both)
            build_container "regular"
            [[ "$BUILD_ISO" == true ]] && build_iso "regular"
            build_container "nvidia"
            [[ "$BUILD_ISO" == true ]] && build_iso "nvidia"
            ;;
        *)
            log_error "Invalid variant: $VARIANT"
            exit 1
            ;;
    esac
    
    log_success "Build process completed!"
    log_info "Build artifacts in: $BUILD_DIR"
    
    if [[ "$BUILD_ISO" == true ]]; then
        log_info "Check *-info.txt files for container details"
        log_info "Use GitHub Actions for full ISO generation"
    fi
}

# Trap for cleanup
trap cleanup_containers EXIT

# Run main function
main