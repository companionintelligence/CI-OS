#!/usr/bin/env bash
#=============================================================================
# CI-OS Ubuntu 24.04 ISO Builder
# Main orchestration script for building custom CI-OS ISOs
#
# This script coordinates the entire ISO build process:
# 1. Build .deb packages and branded gresource (unless --skip-packages)
# 2. Extract base Ubuntu ISO
# 3. Customize the squashfs rootfs
# 4. Apply branding and identity changes
# 5. Repack the ISO
# 6. Generate checksums and signatures
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
#   --skip-packages       Skip building .deb packages and gresource (use for
#                         iterative builds when packages have not changed)
#
# Requirements:
#   - Ubuntu 24.04 (Noble) build host with Yaru theme installed
#   - Root privileges
#   - Packages: squashfs-tools xorriso glib2.0-bin libglib2.0-bin
#               yaru-theme-gnome-shell debootstrap rsync gpg
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
SKIP_PACKAGES=false

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
            --skip-packages)
                SKIP_PACKAGES=true
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
    log_info "  Skip packages: $SKIP_PACKAGES"
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

# Build .deb packages (including the branded gresource)
build_packages() {
    if [[ "$SKIP_PACKAGES" == "true" ]]; then
        log_warn "Skipping package build (--skip-packages specified)"
        return 0
    fi

    log_info "Building packages (including branded gresource)..."
    "$SCRIPT_DIR/build-packages.sh" "$OUTPUT_DIR/packages"
    log_info "Packages built"
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
    
    # ─────────────────────────────────────────────────────────────────────────
    # Strategy: We put the full merged rootfs into minimal.squashfs (the base
    # layer). We keep minimal.standard.squashfs and minimal.standard.live.squashfs
    # as tiny empty placeholders since casper's initramfs expects all three
    # layer names to exist.
    #
    # CRITICALLY, install-sources.yaml must point path: to minimal.squashfs
    # (matching the original Ubuntu structure for the "minimized" variant)
    # because subiquity reads the 'path' field to determine what to rsync
    # onto the target disk.
    # ─────────────────────────────────────────────────────────────────────────

    # Remove only the squashfs files we will rebuild (preserve all other
    # casper metadata like manifests, sizes, language layers, etc.)
    rm -f "$casper_dir/minimal.squashfs"
    rm -f "$casper_dir/minimal.standard.squashfs"
    rm -f "$casper_dir/minimal.standard.live.squashfs"
    # Also remove enhanced-secureboot squashfs variants since our single-layer
    # approach doesn't support the secureboot path and leaving mismatched
    # squashfs/hash pairs causes integrity check failures.
    rm -f "$casper_dir"/minimal.enhanced-secureboot*.squashfs
    rm -f "$casper_dir"/minimal.standard.enhanced-secureboot*.squashfs

    # Pack the full merged rootfs into minimal.squashfs
    mksquashfs "$chroot_dir" "$output_squashfs" \
        -comp xz -b 1M \
        -e 'var/cache/apt/archives/*' \
        -e 'var/lib/apt/lists/*' \
        -e 'tmp/*' \
        -e 'root/.bash_history' \
        -noappend \
        -no-recovery

    # Create empty placeholder layers — casper expects all three names.
    # Must contain a valid filesystem (not literally empty).
    local empty_dir
    empty_dir="$(mktemp -d)"
    mkdir -p "$empty_dir"/{etc,var,tmp}
    for placeholder in minimal.standard.squashfs minimal.standard.live.squashfs; do
        log_info "Creating placeholder layer: $placeholder"
        mksquashfs "$empty_dir" "$casper_dir/$placeholder" \
            -comp xz -noappend -no-recovery 2>/dev/null
    done
    rm -rf "$empty_dir"

    # ── Update filesystem.size ──────────────────────────────────────────────
    # This is the total installed (uncompressed) size. Subiquity uses it to
    # check that the target disk has enough space.
    log_info "Updating filesystem sizes..."
    du -sx --block-size=1 "$chroot_dir" | cut -f1 > "$casper_dir/filesystem.size"
    local installed_size
    installed_size="$(cat "$casper_dir/filesystem.size")"

    # Update per-layer .size files to match actual squashfs contents.
    # For our setup: minimal.squashfs contains everything, the other layers
    # are trivially small.
    echo "$installed_size" > "$casper_dir/minimal.size"
    echo "0" > "$casper_dir/minimal.standard.size"
    echo "0" > "$casper_dir/minimal.standard.live.size"
    # Remove enhanced-secureboot .size files since we removed those squashfs
    rm -f "$casper_dir"/minimal.enhanced-secureboot*.size
    rm -f "$casper_dir"/minimal.standard.enhanced-secureboot*.size

    # ── Use the manifest generated earlier ──────────────────────────────────
    if [[ ! -f "$casper_dir/filesystem.manifest" ]] || [[ ! -s "$casper_dir/filesystem.manifest" ]]; then
        log_warn "Manifest not found or empty — generating now (chroot mounts may be down)..."
        chroot "$chroot_dir" dpkg-query -W --showformat='${Package} ${Version}\n' \
            > "$casper_dir/filesystem.manifest" 2>/dev/null || true
    fi

    # ── Regenerate install-sources.yaml ─────────────────────────────────────
    # Must mirror the original Ubuntu structure:
    #   - path: points to the BASE squashfs (minimal.squashfs), NOT the topmost
    #   - id: ubuntu-desktop-minimal (subiquity matches this to curthooks)
    #   - type: fsimage-layered
    #   - Only one entry (the "minimized" variant, which contains everything)
    local squashfs_size
    squashfs_size="$(stat -c%s "$casper_dir/minimal.squashfs")"
    cat > "$casper_dir/install-sources.yaml" << ISYAML
- default: true
  description:
    en: CI-OS Desktop
  id: ubuntu-desktop-minimal
  locale_support: langpack
  name:
    en: CI-OS Desktop
  path: minimal.squashfs
  preinstalled_langs:
  - en
  - ''
  size: ${installed_size}
  type: fsimage-layered
  variant: desktop
  variations:
    minimal:
      path: minimal.squashfs
      size: ${squashfs_size}
ISYAML
    log_info "install-sources.yaml regenerated (installed size: $installed_size, squashfs: $squashfs_size)"

    # ── Regenerate SHA256SUMS for ALL squashfs files ────────────────────────
    # Must cover every .squashfs in casper/ or integrity checks fail.
    log_info "Regenerating casper/SHA256SUMS..."
    (cd "$casper_dir" && sha256sum *.squashfs > SHA256SUMS)
    log_info "casper/SHA256SUMS regenerated ($(wc -l < "$casper_dir/SHA256SUMS") entries)"

    # Remove stale Ubuntu GPG signature — it was signed over the original
    # SHA256SUMS and will cause verification failure with our new checksums.
    rm -f "$casper_dir/SHA256SUMS.gpg"
    log_info "Removed stale SHA256SUMS.gpg"

    # Remove enhanced-secureboot manifest/size files that no longer have squashfs
    rm -f "$casper_dir"/minimal.enhanced-secureboot*.manifest
    rm -f "$casper_dir"/minimal.standard.enhanced-secureboot*.manifest

    log_info "Squashfs repacked successfully"
}

# Generate ISO
generate_iso() {
    log_info "Generating CI-OS ISO..."
    
    local iso_name="companion-os-${CI_OS_VERSION}-amd64.iso"
    local iso_path="$OUTPUT_DIR/$iso_name"
    
    # ─────────────────────────────────────────────────────────────────────────
    # CRITICAL: Read the original ISO volume id. We MUST keep it for the
    # output ISO so that the EFI boot-image's embedded GRUB search (which
    # looks for the original label) can still locate the boot medium.
    # Changing the volume label while using --boot_image any replay causes
    # the EFI embedded GRUB to fail → VFS: Unable to mount root fs → kernel
    # panic (exit code 0x00000100).
    # ─────────────────────────────────────────────────────────────────────────
    local orig_volid
    orig_volid="$(xorriso -indev "$BASE_ISO" -pvd_info 2>&1 \
        | grep -i 'volume.id' | head -1 \
        | sed "s/.*: *//" | sed "s/^ *'\{0,1\}//;s/'\{0,1\} *$//")" || true
    if [[ -z "$orig_volid" ]]; then
        orig_volid="Ubuntu 24.04.4 LTS amd64"
        log_warn "Could not read volume id from base ISO — using fallback: $orig_volid"
    fi
    log_info "Original ISO volume id: '$orig_volid' (preserving for EFI boot compatibility)"

    # ─────────────────────────────────────────────────────────────────────────
    # Surgically edit GRUB menus — change ONLY display text (menuentry
    # titles), NEVER the search label, UUID, kernel command-line parameters,
    # or any boot-critical values.
    # ─────────────────────────────────────────────────────────────────────────
    local grub_cfg="$WORK_DIR/custom-iso/boot/grub/grub.cfg"
    if [[ -f "$grub_cfg" ]]; then
        log_info "Editing GRUB configuration (display text only)..."
        cp "$grub_cfg" "$grub_cfg.orig"
        sed -i \
            -e 's/\(menuentry "\)Try or Install Ubuntu/\1Try or Install CI-OS/' \
            -e 's/\(menuentry "\)Ubuntu (safe graphics)/\1CI-OS (safe graphics)/' \
            -e 's/\(menuentry[[:space:]]*"\)Ubuntu\b/\1CI-OS/' \
            "$grub_cfg"
        log_info "GRUB menuentry titles updated to CI-OS"
    fi

    # Also edit loopback.cfg if present (used for booting ISO from GRUB)
    local loopback_cfg="$WORK_DIR/custom-iso/boot/grub/loopback.cfg"
    if [[ -f "$loopback_cfg" ]]; then
        sed -i \
            -e 's/\(menuentry "\)Try or Install Ubuntu/\1Try or Install CI-OS/' \
            -e 's/\(menuentry "\)Ubuntu (safe graphics)/\1CI-OS (safe graphics)/' \
            -e 's/\(menuentry[[:space:]]*"\)Ubuntu\b/\1CI-OS/' \
            "$loopback_cfg"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # Build ISO inheriting all boot parameters (EFI + BIOS) from the original
    # Ubuntu 24.04 ISO, then swap in our custom casper directory.
    # CRITICAL: Use the ORIGINAL volume id so the EFI embedded GRUB search
    # and casper can find the boot medium.
    # ─────────────────────────────────────────────────────────────────────────
    log_info "Building ISO with xorriso (inheriting boot from base ISO)..."
    rm -f "$iso_path"

    local -a xorriso_maps=(
        -map "$WORK_DIR/custom-iso/casper" /casper
        -map "$grub_cfg" /boot/grub/grub.cfg
    )
    [[ -f "$loopback_cfg" ]] && xorriso_maps+=(-map "$loopback_cfg" /boot/grub/loopback.cfg)

    xorriso \
        -indev "$BASE_ISO" \
        -outdev "$iso_path" \
        -volid "$orig_volid" \
        -boot_image any replay \
        -pathspecs on \
        -rm_r /casper -- \
        "${xorriso_maps[@]}" \
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

    # Build packages (including branded gresource) unless skipped
    build_packages
    
    # Build process
    extract_iso
    extract_squashfs
    setup_chroot
    
    # Apply customizations (wrapped in trap for cleanup)
    trap cleanup_chroot EXIT
    apply_customizations

    # Generate manifest while chroot mounts are still active
    log_info "Generating package manifest..."
    local casper_dir="$WORK_DIR/custom-iso/casper"
    chroot "$WORK_DIR/chroot" dpkg-query -W --showformat='${Package} ${Version}\n' \
        > "$casper_dir/filesystem.manifest" 2>/dev/null || true

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
