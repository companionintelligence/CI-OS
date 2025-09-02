#!/usr/bin/bash
# CI-OS Build Script for Local Development
# Builds container images locally for testing

set -euo pipefail

# Configuration
REGISTRY="localhost"
IMAGE_NAME="ci-os"
FEDORA_VERSION="41"
BUILD_DATE=$(date +%Y%m%d)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Help function
show_help() {
    cat << EOF
CI-OS Build Script

Usage: $0 [VARIANT] [OPTIONS]

Variants:
  regular     Build regular CI-OS variant (default)
  nvidia      Build NVIDIA CI-OS variant  
  both        Build both variants

Options:
  --clean     Clean build (remove existing images first)
  --verbose   Enable verbose output
  --push      Push images to registry after build
  --help      Show this help message

Examples:
  $0                    # Build regular variant
  $0 nvidia             # Build NVIDIA variant
  $0 both --clean       # Clean build of both variants
  $0 regular --verbose  # Verbose build of regular variant

Note: This script builds container images locally. 
For ISO generation, use GitHub Actions or the 
jasonn3/build-container-installer tool separately.

EOF
}

# Parse command line arguments
VARIANT="regular"
CLEAN=false
VERBOSE=false
PUSH=false

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
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Set build options
BUILD_OPTS=(
    "--layers"
    "--force-rm"
)

if [[ "$VERBOSE" == "true" ]]; then
    BUILD_OPTS+=("--progress=plain")
fi

# Cleanup function
cleanup_images() {
    local variant=$1
    print_info "Cleaning up existing $variant images..."
    
    if [[ "$variant" == "regular" ]]; then
        podman rmi -f "${REGISTRY}/${IMAGE_NAME}:latest" 2>/dev/null || true
        podman rmi -f "${REGISTRY}/${IMAGE_NAME}:v01-${BUILD_DATE}" 2>/dev/null || true
    else
        podman rmi -f "${REGISTRY}/${IMAGE_NAME}-${variant}:latest" 2>/dev/null || true
        podman rmi -f "${REGISTRY}/${IMAGE_NAME}-${variant}:v01-${BUILD_DATE}" 2>/dev/null || true
    fi
}

# Build function
build_variant() {
    local variant=$1
    local containerfile="Containerfile"
    local image_tag=""
    
    if [[ "$variant" == "nvidia" ]]; then
        containerfile="Containerfile.nvidia"
        image_tag="${REGISTRY}/${IMAGE_NAME}-nvidia"
    else
        image_tag="${REGISTRY}/${IMAGE_NAME}"
    fi
    
    print_info "Building CI-OS $variant variant..."
    print_info "Using Containerfile: $containerfile"
    print_info "Image tag: $image_tag"
    
    # Check if Containerfile exists
    if [[ ! -f "$containerfile" ]]; then
        print_error "Containerfile not found: $containerfile"
        return 1
    fi
    
    # Clean if requested
    if [[ "$CLEAN" == "true" ]]; then
        cleanup_images "$variant"
    fi
    
    # Build the image
    print_info "Starting build process..."
    start_time=$(date +%s)
    
    if podman build "${BUILD_OPTS[@]}" \
        -f "$containerfile" \
        -t "$image_tag:latest" \
        -t "$image_tag:v01-${BUILD_DATE}" \
        . ; then
        
        end_time=$(date +%s)
        build_time=$((end_time - start_time))
        print_success "Build completed in ${build_time} seconds"
        
        # Show image info
        print_info "Image information:"
        podman images "$image_tag" --format "table {{.Repository}}:{{.Tag}} {{.Size}} {{.Created}}"
        
        # Push if requested
        if [[ "$PUSH" == "true" ]]; then
            print_info "Pushing images to registry..."
            podman push "$image_tag:latest"
            podman push "$image_tag:v01-${BUILD_DATE}"
            print_success "Images pushed to registry"
        fi
        
        return 0
    else
        print_error "Build failed for $variant variant"
        return 1
    fi
}

# Test function
test_build() {
    local variant=$1
    local image_tag=""
    
    if [[ "$variant" == "nvidia" ]]; then
        image_tag="${REGISTRY}/${IMAGE_NAME}-nvidia:latest"
    else
        image_tag="${REGISTRY}/${IMAGE_NAME}:latest"
    fi
    
    print_info "Testing $variant build..."
    
    # Test if image exists
    if ! podman images -q "$image_tag" >/dev/null; then
        print_error "Image not found: $image_tag"
        return 1
    fi
    
    # Test basic container functionality
    print_info "Testing container startup..."
    if podman run --rm "$image_tag" /bin/bash -c "echo 'Container test successful'"; then
        print_success "Container test passed"
    else
        print_error "Container test failed"
        return 1
    fi
    
    # Test CI-OS specific components
    print_info "Testing CI-OS components..."
    if podman run --rm "$image_tag" /bin/bash -c "test -f /usr/share/ublue-os/justfiles/10-ci-os.just"; then
        print_success "CI-OS just commands found"
    else
        print_warning "CI-OS just commands not found"
    fi
    
    if podman run --rm "$image_tag" /bin/bash -c "command -v wine >/dev/null"; then
        print_success "Wine installation verified"
    else
        print_warning "Wine not found in image"
    fi
    
    return 0
}

# Main execution
main() {
    print_info "CI-OS Build Script v01"
    print_info "======================"
    print_info "Variant: $VARIANT"
    print_info "Clean build: $CLEAN"
    print_info "Verbose: $VERBOSE"
    print_info "Push: $PUSH"
    print_info "Build date: $BUILD_DATE"
    echo ""
    
    # Check if podman is available
    if ! command -v podman >/dev/null 2>&1; then
        print_error "Podman not found. Please install podman first."
        print_info "On Fedora: sudo dnf install podman"
        exit 1
    fi
    
    # Check if we're in the right directory
    if [[ ! -f "README.md" ]] || [[ ! -f "Containerfile" ]]; then
        print_error "Run this script from the CI-OS repository root directory"
        exit 1
    fi
    
    # Build variants
    case $VARIANT in
        "regular")
            if build_variant "regular"; then
                test_build "regular"
            else
                exit 1
            fi
            ;;
        "nvidia") 
            if build_variant "nvidia"; then
                test_build "nvidia"
            else
                exit 1
            fi
            ;;
        "both")
            success=true
            
            if ! build_variant "regular"; then
                success=false
            else
                test_build "regular"
            fi
            
            if ! build_variant "nvidia"; then
                success=false
            else
                test_build "nvidia"
            fi
            
            if [[ "$success" == "false" ]]; then
                print_error "One or more builds failed"
                exit 1
            fi
            ;;
        *)
            print_error "Unknown variant: $VARIANT"
            show_help
            exit 1
            ;;
    esac
    
    print_success "Build process completed successfully!"
    echo ""
    print_info "Next steps:"
    print_info "  • Run the container: podman run -it ${REGISTRY}/${IMAGE_NAME}:latest"
    print_info "  • Generate ISO: Use GitHub Actions or build-container-installer"
    print_info "  • Test Wine: podman run --rm ${REGISTRY}/${IMAGE_NAME}:latest wine --version"
    echo ""
}

# Execute main function
main "$@"