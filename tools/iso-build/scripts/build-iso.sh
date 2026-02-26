#!/usr/bin/env bash
#=============================================================================
# CI-OS Ubuntu 24.04 ISO Builder
# Main orchestration script for building custom CI-OS ISOs
#
# This script coordinates the entire ISO build process:
# 1. Extract base Ubuntu ISO
# 2. Customize the squashfs rootfs
# 3. Apply branding and identity changes
# 4. Repack the ISO
# 5. Generate checksums and signatures
#
# Usage:
#   sudo ./tools/iso-build/scripts/build-iso.sh [options]
#
# Options:
#   --base-iso PATH       Path to Ubuntu 24.04 Desktop ISO
#   --output-dir PATH     Output directory for built ISO (default: ./output)
#   --work-dir PATH       Working directory (default: ./work)
#   --version VERSION     CI-OS version string (default: 1.0)
#   --sign                Sign the ISO checksums with GPG
#   --clean               Clean work directory before building
#
# Requirements:
#   - Ubuntu 24.04 or newer build host
#   - Root privileges
#   - Packages: debootstrap, squashfs-tools, xorriso, rsync, gpg
#
# © Companion Intelligence — Lifescope Inc
#=============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
REPO_ROOT="$(dirname "$TOOLS_ROOT")"
BASE_ISO="${BASE_ISO:-$REPO_ROOT/ubuntu-24.04.4-desktop-amd64.iso}"
OUTPUT_DIR="$REPO_ROOT/output"
WORK_DIR="$REPO_ROOT/work"
CI_OS_VERSION="${CI_OS_VERSION:-1.0}"
SIGN_CHECKSUMS=false
CLEAN_WORK=false

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check required dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    local missing=()
    
    for cmd in debootstrap mksquashfs unsquashfs xorriso rsync gpg; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Install with: apt-get install debootstrap squashfs-tools xorriso rsync gpg"
        exit 1
    fi
    
    log_info "All dependencies satisfied"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --base-iso)
                BASE_ISO="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --work-dir)
                WORK_DIR="$2"
                shift 2
                ;;
            --version)
                CI_OS_VERSION="$2"
                shift 2
                ;;
            --sign)
                SIGN_CHECKSUMS=true
                shift
                ;;
            --clean)
                CLEAN_WORK=true
                shift
                ;;
            -h|--help)
                grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Validate configuration
validate_config() {
    if [[ -z "$BASE_ISO" ]]; then
        log_error "Base ISO path is required (use --base-iso)"
        exit 1
    fi
    
    if [[ ! -f "$BASE_ISO" ]]; then
        log_error "Base ISO not found: $BASE_ISO"
        exit 1
    fi
    
    log_info "Configuration validated"
    log_info "  Base ISO: $BASE_ISO"
    log_info "  Output directory: $OUTPUT_DIR"
    log_info "  Work directory: $WORK_DIR"
    log_info "  CI-OS version: $CI_OS_VERSION"
}

# Setup working directories
setup_directories() {
    log_info "Setting up directories..."
    
    if [[ "$CLEAN_WORK" == "true" ]] && [[ -d "$WORK_DIR" ]]; then
        log_warn "Cleaning work directory: $WORK_DIR"
        rm -rf "$WORK_DIR"
    fi
    
    mkdir -p "$WORK_DIR"/{iso,squashfs,chroot,custom-iso}
    mkdir -p "$OUTPUT_DIR"
    
    log_info "Directories ready"
}

# Extract base ISO
extract_iso() {
    log_info "Extracting base ISO..."
    
    # Mount ISO
    local mount_point="$WORK_DIR/iso-mount"
    mkdir -p "$mount_point"
    
    # Setup cleanup trap for this function
    trap 'umount "$mount_point" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' RETURN
    
    mount -o loop,ro "$BASE_ISO" "$mount_point"
    
    # Copy ISO contents (exclude all squashfs layers — we'll rebuild them)
    log_info "Copying ISO contents..."
    rsync -a --exclude='casper/*.squashfs' "$mount_point/" "$WORK_DIR/custom-iso/"
    
    # Copy squashfs layers in layer order (Ubuntu 24.04 layered structure)
    mkdir -p "$WORK_DIR/squashfs"
    for layer in minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs; do
        if [[ -f "$mount_point/casper/$layer" ]]; then
            log_info "Copying squashfs layer: $layer"
            cp "$mount_point/casper/$layer" "$WORK_DIR/squashfs/$layer"
        fi
    done
    
    # Unmount (trap will also handle this on error)
    umount "$mount_point"
    rmdir "$mount_point"
    
    log_info "ISO extracted successfully"
}

# Extract squashfs
extract_squashfs() {
    log_info "Extracting squashfs filesystem (layered)..."
    
    # Extract layers in order — each layer overlays the previous
    for layer in minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs; do
        if [[ -f "$WORK_DIR/squashfs/$layer" ]]; then
            log_info "Extracting layer: $layer"
            unsquashfs -f -d "$WORK_DIR/chroot" "$WORK_DIR/squashfs/$layer"
        fi
    done
    
    log_info "Squashfs extracted to: $WORK_DIR/chroot"
}

# Setup chroot environment
setup_chroot() {
    log_info "Setting up chroot environment..."
    
    local chroot_dir="$WORK_DIR/chroot"
    
    # Bind mount system directories
    mount --bind /dev "$chroot_dir/dev"
    mount --bind /run "$chroot_dir/run"
    mount -t proc proc "$chroot_dir/proc"
    mount -t sysfs sysfs "$chroot_dir/sys"
    mount -t devpts devpts "$chroot_dir/dev/pts"
    
    # Copy resolv.conf for network access (skip if it's already the same file via bind mount)
    cp /etc/resolv.conf "$chroot_dir/etc/resolv.conf" 2>/dev/null || true
    
    log_info "Chroot environment ready"
}

# Cleanup chroot mounts
cleanup_chroot() {
    log_info "Cleaning up chroot mounts..."
    
    local chroot_dir="$WORK_DIR/chroot"
    
    # Unmount in reverse order
    umount -lf "$chroot_dir/dev/pts" 2>/dev/null || true
    umount -lf "$chroot_dir/sys" 2>/dev/null || true
    umount -lf "$chroot_dir/proc" 2>/dev/null || true
    umount -lf "$chroot_dir/run" 2>/dev/null || true
    umount -lf "$chroot_dir/dev" 2>/dev/null || true
    
    log_info "Chroot cleaned up"
}

# Apply customizations
apply_customizations() {
    log_info "Applying CI-OS customizations..."
    
    # Call customization scripts
    "$SCRIPT_DIR/customize-chroot.sh" "$WORK_DIR/chroot" "$CI_OS_VERSION"
    
    log_info "Customizations applied"
}

# Repack squashfs
repack_squashfs() {
    log_info "Repacking squashfs filesystem..."
    
    local chroot_dir="$WORK_DIR/chroot"
    local casper_dir="$WORK_DIR/custom-iso/casper"
    local output_squashfs="$casper_dir/minimal.squashfs"
    
    # Remove all existing squashfs layers
    rm -f "$casper_dir"/*.squashfs
    
    # Pack the full merged rootfs into minimal.squashfs
    mksquashfs "$chroot_dir" "$output_squashfs" \
        -comp xz -b 1M \
        -e 'var/cache/apt/archives/*' \
        -e 'var/lib/apt/lists/*' \
        -e 'tmp/*' \
        -e 'root/.bash_history' \
        -noappend \
        -no-recovery

    # Ubuntu 24.04 casper initramfs hardcodes all three layer names and will
    # refuse to boot if any are missing. Create empty squashfs placeholders for
    # the layers we merged into minimal.squashfs so casper's layer check passes.
    local empty_dir
    empty_dir="$(mktemp -d)"
    for placeholder in minimal.standard.squashfs minimal.standard.live.squashfs; do
        log_info "Creating empty placeholder: $placeholder"
        mksquashfs "$empty_dir" "$casper_dir/$placeholder" \
            -comp xz -noappend -no-recovery 2>/dev/null
    done
    rmdir "$empty_dir"
    
    # Update filesystem size in manifest
    log_info "Updating filesystem manifest..."
    du -sx --block-size=1 "$chroot_dir" | cut -f1 > "$casper_dir/filesystem.size"
    
    # Generate new manifest
    chroot "$chroot_dir" dpkg-query -W --showformat='${Package} ${Version}\n' \
        > "$casper_dir/filesystem.manifest"
    
    log_info "Squashfs repacked successfully"
}

# Generate ISO
generate_iso() {
    log_info "Generating CI-OS ISO..."
    
    local iso_name="companion-os-${CI_OS_VERSION}-amd64.iso"
    local iso_path="$OUTPUT_DIR/$iso_name"
    
    # Update GRUB configuration
    sed -i "s/Ubuntu/CI-OS/g" "$WORK_DIR/custom-iso/boot/grub/grub.cfg" || true
    
    # Build ISO inheriting all boot parameters (EFI + BIOS) from the original
    # Ubuntu 24.04 ISO, then swap in our custom casper directory.
    # This avoids having to manually replicate Ubuntu's complex boot setup.
    log_info "Building ISO with xorriso (inheriting boot from base ISO)..."
    # xorriso requires blank output when indev != outdev
    rm -f "$iso_path"
    xorriso \
        -indev "$BASE_ISO" \
        -outdev "$iso_path" \
        -volid "CI-OS ${CI_OS_VERSION}" \
        -boot_image any replay \
        -pathspecs on \
        -rm_r /casper -- \
        -map "$WORK_DIR/custom-iso/casper" /casper \
        -map "$WORK_DIR/custom-iso/boot/grub/grub.cfg" /boot/grub/grub.cfg \
        -commit_eject all
    
    log_info "ISO generated: $iso_path"
    
    # Generate checksums
    generate_checksums "$iso_path"
}

# Generate checksums and optionally sign
generate_checksums() {
    local iso_path="$1"
    local iso_name="$(basename "$iso_path")"
    
    log_info "Generating checksums..."
    
    cd "$OUTPUT_DIR"
    
    # SHA256
    sha256sum "$iso_name" > SHA256SUMS
    log_info "SHA256: $(cat SHA256SUMS)"
    
    # MD5
    md5sum "$iso_name" > MD5SUMS
    
    # Sign if requested
    if [[ "$SIGN_CHECKSUMS" == "true" ]]; then
        log_info "Signing checksums with GPG..."
        gpg --armor --detach-sign --output SHA256SUMS.gpg SHA256SUMS
        gpg --armor --detach-sign --output MD5SUMS.gpg MD5SUMS
        log_info "Checksums signed"
    fi
    
    cd - > /dev/null
}

# Main function
main() {
    log_info "CI-OS ISO Builder starting..."
    log_info "© Companion Intelligence — Lifescope Inc"
    echo
    
    check_root
    parse_args "$@"
    check_dependencies
    validate_config
    setup_directories
    
    # Build process
    extract_iso
    extract_squashfs
    setup_chroot
    
    # Apply customizations (wrapped in trap for cleanup)
    trap cleanup_chroot EXIT
    apply_customizations
    cleanup_chroot
    trap - EXIT
    
    # Finalize
    repack_squashfs
    generate_iso
    
    log_info "Build complete!"
    log_info "ISO location: $OUTPUT_DIR/companion-os-${CI_OS_VERSION}-amd64.iso"
    log_info "Checksums: $OUTPUT_DIR/SHA256SUMS"
}

# Run main function
main "$@"
