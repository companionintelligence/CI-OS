#!/usr/bin/bash
# CI-OS Local Build Script
# Builds container images locally for testing

set -euo pipefail

# Configuration
REGISTRY="localhost"
IMAGE_NAME="ci-os"
VERSION="v01-dev"
FEDORA_VERSION="41"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Help message
show_help() {
    cat << EOF
CI-OS Local Build Script

Usage: $0 [VARIANT] [OPTIONS]

VARIANTS:
    regular     Build regular CI-OS variant (default)
    nvidia      Build NVIDIA-optimized variant  
    both        Build both variants

OPTIONS:
    --clean     Remove existing images before building
    --verbose   Enable verbose output
    --push      Push images to registry (requires login)
    --help      Show this help message

EXAMPLES:
    $0                          # Build regular variant
    $0 nvidia                   # Build NVIDIA variant
    $0 both --clean            # Build both, clean first
    $0 regular --verbose       # Build with verbose output

NOTES:
    - Images are tagged as ${REGISTRY}/${IMAGE_NAME}:${VERSION}
    - Use 'podman images' to see built images
    - GitHub Actions handles official builds and ISOs
EOF
}

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prereqs() {
    log_info "Checking prerequisites..."
    
    if ! command -v podman &> /dev/null; then
        log_error "Podman is required but not installed"
        echo "Install with: sudo dnf install podman"
        exit 1
    fi
    
    if [ ! -f "Containerfile" ] || [ ! -f "Containerfile.nvidia" ]; then
        log_error "Containerfiles not found in current directory"
        echo "Make sure you're running this from the CI-OS repository root"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Clean existing images
clean_images() {
    log_info "Cleaning existing images..."
    
    # Remove CI-OS images
    podman rmi -f "${REGISTRY}/${IMAGE_NAME}:${VERSION}" 2>/dev/null || true
    podman rmi -f "${REGISTRY}/${IMAGE_NAME}-nvidia:${VERSION}" 2>/dev/null || true
    
    # Clean up dangling images
    podman image prune -f
    
    log_success "Image cleanup complete"
}

# Build a single variant
build_variant() {
    local variant=$1
    local containerfile=""
    local image_tag=""
    
    case $variant in
        regular)
            containerfile="Containerfile"
            image_tag="${REGISTRY}/${IMAGE_NAME}:${VERSION}"
            ;;
        nvidia)
            containerfile="Containerfile.nvidia"
            image_tag="${REGISTRY}/${IMAGE_NAME}-nvidia:${VERSION}"
            ;;
        *)
            log_error "Unknown variant: $variant"
            exit 1
            ;;
    esac
    
    log_info "Building $variant variant..."
    log_info "Containerfile: $containerfile"
    log_info "Image tag: $image_tag"
    
    # Build arguments
    local build_args=(
        "--file" "$containerfile"
        "--tag" "$image_tag"
        "--build-arg" "FEDORA_VERSION=${FEDORA_VERSION}"
        "--build-arg" "CI_OS_VERSION=${VERSION}"
    )
    
    # Add verbose flag if requested
    if [ "$VERBOSE" = true ]; then
        build_args+=("--progress=plain")
    fi
    
    # Execute build
    if podman build "${build_args[@]}" .; then
        log_success "$variant variant built successfully"
        log_info "Image: $image_tag"
        
        # Show image size
        local size=$(podman images --format "{{.Size}}" "$image_tag")
        log_info "Size: $size"
        
        return 0
    else
        log_error "Failed to build $variant variant"
        return 1
    fi
}

# Push images to registry
push_images() {
    log_info "Pushing images to registry..."
    
    if [ "$BUILD_REGULAR" = true ]; then
        podman push "${REGISTRY}/${IMAGE_NAME}:${VERSION}"
        log_success "Regular variant pushed"
    fi
    
    if [ "$BUILD_NVIDIA" = true ]; then
        podman push "${REGISTRY}/${IMAGE_NAME}-nvidia:${VERSION}"
        log_success "NVIDIA variant pushed"
    fi
}

# Parse command line arguments
VARIANT="regular"
CLEAN=false
VERBOSE=false
PUSH=false
BUILD_REGULAR=false
BUILD_NVIDIA=false

while [[ $# -gt 0 ]]; do
    case $1 in
        regular|nvidia|both)
            VARIANT="$1"
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Determine what to build
case $VARIANT in
    regular)
        BUILD_REGULAR=true
        ;;
    nvidia)
        BUILD_NVIDIA=true
        ;;
    both)
        BUILD_REGULAR=true
        BUILD_NVIDIA=true
        ;;
esac

# Main execution
main() {
    log_info "CI-OS Local Build Script"
    log_info "========================"
    
    check_prereqs
    
    if [ "$CLEAN" = true ]; then
        clean_images
    fi
    
    # Build variants
    local build_success=true
    
    if [ "$BUILD_REGULAR" = true ]; then
        if ! build_variant "regular"; then
            build_success=false
        fi
    fi
    
    if [ "$BUILD_NVIDIA" = true ]; then
        if ! build_variant "nvidia"; then
            build_success=false
        fi
    fi
    
    if [ "$build_success" = false ]; then
        log_error "One or more builds failed"
        exit 1
    fi
    
    # Push if requested
    if [ "$PUSH" = true ]; then
        push_images
    fi
    
    log_success "Build complete!"
    echo
    log_info "Built images:"
    podman images | grep "${REGISTRY}/${IMAGE_NAME}"
    echo
    log_info "Next steps:"
    echo "  • Test images locally with podman run"
    echo "  • Push to GitHub for automated ISO building"
    echo "  • GitHub Actions will create bootable ISOs"
}

# Run main function
main "$@"