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
#   sudo ./backends/ubuntu/iso/scripts/build-iso.sh [options]
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
# Environment knobs (optional tools, customize-chroot.sh Step 10e; all default to 1 = baked in):
#   CI_OS_BAKE_THIRD_PARTY=0|1   tailscale + cloudflared + gh from the vendors' apt repositories
#   CI_OS_BAKE_OLLAMA=0|1        Ollama from the vendor's pinned release tarball (never install.sh)
#   CI_OS_BAKE_LAUNCHER=0|1      Companion Launcher .deb from dl.ci.computer (pinned sha256)
#   CI_OS_OLLAMA_CUDA=all|none   'none' drops Ollama's bundled CUDA libraries (saves about 1.5 GB)
#   CI_OS_LAUNCHER_AUTOSTART=0|1 start the Launcher at graphical login on the installed system (default 0)
#   CI_OS_CACHE_DIR=PATH         download cache for the Ollama tarball (default ~/.cache/ci-os, about 1.5 GB)
#   CI_OS_TIERB_PINS=PATH        pins file (default core/manifest/tier-b-pins.env)
# Pins are fail-closed: a key-fingerprint or sha256 mismatch aborts the build.
# See docs/architecture/tier-b-tools.md.
#
# Requirements:
#   - Ubuntu 24.04 (Noble) build host with Yaru theme installed
#   - Root privileges
#   - Network access to download.docker.com, pkgs.tailscale.com, pkg.cloudflare.com, cli.github.com,
#     github.com (Ollama release asset) and dl.ci.computer while building
#   - Packages: squashfs-tools xorriso glib2.0-bin libglib2.0-bin
#               yaru-theme-gnome-shell debootstrap rsync gpg cpio zstd curl
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
# SCRIPT_DIR is backends/ubuntu/iso/scripts/ — four levels below the repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
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
    
    for cmd in debootstrap mksquashfs unsquashfs xorriso rsync gpg glib-compile-resources gresource cpio zstd \
               curl sha256sum tar dpkg-deb; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    # The logo PNGs (greeter, Settings > About, GRUB background) are rendered on this host from the vendored SVG
    # marks (core/render/render-mark-png.sh); the stock desktop image has no renderer, and ImageMagick also
    # scales the Plymouth logo. Fail here, not after an hour of build.
    if ! command -v rsvg-convert &> /dev/null; then
        missing+=("rsvg-convert")
    fi
    if ! command -v convert &> /dev/null && ! command -v magick &> /dev/null; then
        missing+=("convert (or magick)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Install with: apt-get install debootstrap squashfs-tools xorriso rsync gpg libglib2.0-bin libglib2.0-dev-bin cpio zstd curl dpkg coreutils tar librsvg2-bin imagemagick"
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
    
    # Copy ALL ISO contents — including every squashfs layer, language
    # packs, enhanced-secureboot layers, manifests, and sizes.
    # We will only REPLACE the 3 main layers; all other casper files
    # (language layers, enhanced-secureboot, metadata) stay intact so the
    # installer and casper find the complete layered structure they expect.
    log_info "Copying ISO contents (all files including squashfs layers)..."
    rsync -a "$mount_point/" "$WORK_DIR/custom-iso/"
    
    # Stage the 3 main squashfs layers for chroot extraction.
    # These are the layers we merge, customize, and repack.
    mkdir -p "$WORK_DIR/squashfs"
    for layer in minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs; do
        if [[ -f "$mount_point/casper/$layer" ]]; then
            log_info "Staging layer for extraction: $layer"
            cp "$mount_point/casper/$layer" "$WORK_DIR/squashfs/$layer"
        fi
    done
    
    # Unmount (trap will also handle this on error)
    umount "$mount_point"
    rmdir "$mount_point"
    
    log_info "ISO extracted successfully"
}

# Overlay whiteouts in a Ubuntu casper layer are character devices 0,0.
# unsquashfs -f cannot replace a non-empty directory with one of those, so
# delete the lower path first. Ubuntu 26.04's live layer uses this to drop
# dracut from the minimal layer.
apply_layer_whiteouts() {
    local layer="$1"
    local dest="$2"
    local rel

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        rm -rf "${dest}/${rel}"
    done < <(unsquashfs -ll "$layer" 2>/dev/null | awk '
        /^c/ && /0,[[:space:]]*0/ {
            i = index($0, "squashfs-root/")
            if (i) print substr($0, i + length("squashfs-root/"))
        }')
}

# Drop any whiteout device nodes the extractor left behind.
remove_whiteout_nodes() {
    local dest="$1"
    local node major minor
    while IFS= read -r -d '' node; do
        major="$(stat -c '%t' "$node" 2>/dev/null || true)"
        minor="$(stat -c '%T' "$node" 2>/dev/null || true)"
        if [[ "$major" == "0" && "$minor" == "0" ]]; then
            rm -f "$node"
        fi
    done < <(find "$dest" -type c -print0 2>/dev/null)
}

# Extract squashfs
extract_squashfs() {
    log_info "Extracting squashfs filesystem (layered)..."

    # Extract layers in order — each layer overlays the previous
    for layer in minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs; do
        if [[ -f "$WORK_DIR/squashfs/$layer" ]]; then
            log_info "Extracting layer: $layer (this may take a few minutes)..."
            apply_layer_whiteouts "$WORK_DIR/squashfs/$layer" "$WORK_DIR/chroot"
            unsquashfs -f -q -d "$WORK_DIR/chroot" "$WORK_DIR/squashfs/$layer"
            remove_whiteout_nodes "$WORK_DIR/chroot"
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
    # A PRIVATE tmpfs for /run, never a bind of the host's. With the host's /run the chroot sees
    # /run/systemd/system, so maintainer scripts believe systemd is running and `systemctl start`/`pkill`
    # reach the BUILD HOST's services and processes (libvirt and NetworkManager run dnsmasq too).
    mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$chroot_dir/run"
    mkdir -p "$chroot_dir/run/lock"
    mount -t proc proc "$chroot_dir/proc"
    mount -t sysfs sysfs "$chroot_dir/sys"
    mount -t devpts devpts "$chroot_dir/dev/pts"
    
    # The live image's resolv.conf is often a symlink into a path this chroot
    # does not have, and Docker's own resolver is not visible here. Write a
    # plain file so apt inside the chroot can reach the Ubuntu archive.
    rm -f "$chroot_dir/etc/resolv.conf"
    cat > "$chroot_dir/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    # The installer CD source is not mounted. Leaving it enabled makes
    # apt-get update fail before any package install.
    if [[ -f "$chroot_dir/etc/apt/sources.list.d/cdrom.sources" ]]; then
        mv "$chroot_dir/etc/apt/sources.list.d/cdrom.sources" \
            "$chroot_dir/etc/apt/sources.list.d/cdrom.sources.disabled"
    fi

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
    "$REPO_ROOT/backends/ubuntu/chroot/customize-chroot.sh" "$WORK_DIR/chroot" "$CI_OS_VERSION"
    
    log_info "Customizations applied"
}

# Create the skeleton of an empty casper placeholder layer in $2, mirroring the
# directory modes of the rootfs in $1.
#
# casper stacks the layers with overlayfs, and a directory that exists in several layers
# takes its mode from the TOPMOST one. A placeholder made with a plain `mkdir -p` gets 0755
# (root's umask), which turns /tmp into drwxr-xr-x for the whole live session: the installer
# and the desktop launcher can no longer write their temp files (the launcher is shown as
# untrusted and the installer does not start). /tmp has to stay 1777 whatever the umask is.
# The layer's own root is mirrored too: it is the mktemp -d directory, mode 0700.
make_placeholder_layer() {
    local chroot_dir="$1"
    local empty_dir="$2"
    local d

    chmod --reference="$chroot_dir" "$empty_dir"
    for d in etc var tmp; do
        mkdir -p "$empty_dir/$d"
        chmod --reference="$chroot_dir/$d" "$empty_dir/$d"
    done
    chmod 1777 "$empty_dir/tmp"
}

# Repack squashfs
repack_squashfs() {
    log_info "Repacking squashfs filesystem..."
    
    local chroot_dir="$WORK_DIR/chroot"
    local casper_dir="$WORK_DIR/custom-iso/casper"
    local output_squashfs="$casper_dir/minimal.squashfs"
    
    # ─────────────────────────────────────────────────────────────────────────
    # Strategy: We put the full merged rootfs into minimal.squashfs (the base
    # layer). We create small empty placeholder layers for
    # minimal.standard.squashfs and minimal.standard.live.squashfs (since our
    # base already contains everything from all 3 original layers).
    #
    # The stock LANGUAGE layers (minimal.<lang>.squashfs, minimal.standard.<lang>.squashfs and the
    # *.no-languages ones) are REMOVED, and install-sources.yaml lists no preinstalled_langs. Why:
    # when a source has preinstalled_langs, subiquity installs from "<base>.<lang>.squashfs"
    # (models/source.py get_source), a layer stacked ON TOP of the base. Every stock language layer
    # carries a stock var/lib/dpkg/status and a stock gschemas.compiled and whiteouts for the font
    # packages it drops. Stacked over our merged base, an installed system would have all our files
    # but a package database that has never heard of docker-ce, setup-device, tailscale, ... and the
    # stock wallpaper schema. With no preinstalled_langs the installer uses minimal.squashfs alone;
    # locale_support: langpack still makes it install the chosen language's packs from apt.
    # ─────────────────────────────────────────────────────────────────────────

    # Remove ONLY the 3 main layers we are replacing. Keep all language
    # layers, enhanced-secureboot layers, and all metadata files intact.
    rm -f "$casper_dir/minimal.squashfs"
    rm -f "$casper_dir/minimal.standard.squashfs"
    rm -f "$casper_dir/minimal.standard.live.squashfs"

    # Drop the stock language layers (see above), with their .size and .manifest files.
    local lang_suffix
    for lang_suffix in de en es fr it pt ru zh no-languages; do
        rm -f "$casper_dir"/minimal."$lang_suffix".{squashfs,size,manifest} \
              "$casper_dir"/minimal.standard."$lang_suffix".{squashfs,size,manifest}
    done

    # mksquashfs packs /tmp itself (only its contents are excluded below), so it has to be 1777
    # before the pack, whatever the unsquashed layers or the customization steps left behind.
    if [[ "$(stat -c %a "$chroot_dir/tmp")" != 1777 ]]; then
        log_warn "chroot /tmp was not mode 1777; fixing it before packing"
        chmod 1777 "$chroot_dir/tmp"
    fi

    # Pack the full merged rootfs into minimal.squashfs
    # -quiet suppresses per-file progress output (millions of lines that crash terminals)
    log_info "Compressing rootfs into minimal.squashfs (this takes 5-15 minutes)..."
    mksquashfs "$chroot_dir" "$output_squashfs" \
        -comp xz -b 1M \
        -e 'var/cache/apt/archives/*' \
        -e 'var/lib/apt/lists/*' \
        -e 'tmp/*' \
        -e 'root/.bash_history' \
        -noappend \
        -no-recovery \
        -quiet

    # Create empty placeholder layers for standard and live.
    # Our minimal.squashfs already contains everything from all 3 original
    # layers plus our customizations, so these layers need to exist (casper
    # and the installer expect them) but don't need to add any content. Their
    # directory modes must mirror the rootfs, though (see make_placeholder_layer).
    local empty_dir
    empty_dir="$(mktemp -d)"
    make_placeholder_layer "$chroot_dir" "$empty_dir"
    for placeholder in minimal.standard.squashfs minimal.standard.live.squashfs; do
        log_info "Creating placeholder layer: $placeholder"
        mksquashfs "$empty_dir" "$casper_dir/$placeholder" \
            -comp xz -noappend -no-recovery 2>/dev/null
    done
    rm -rf "$empty_dir"

    # ── Update filesystem.size ──────────────────────────────────────────────
    # Total installed (uncompressed) size. Subiquity checks disk space.
    log_info "Updating filesystem sizes..."
    du -sx --block-size=1 "$chroot_dir" | cut -f1 > "$casper_dir/filesystem.size"
    local installed_size
    installed_size="$(cat "$casper_dir/filesystem.size")"

    # Update per-layer .size files for the 3 layers we replaced.
    # All other .size files remain from the original ISO.
    echo "$installed_size" > "$casper_dir/minimal.size"
    echo "0" > "$casper_dir/minimal.standard.size"
    echo "0" > "$casper_dir/minimal.standard.live.size"

    # ── Use the manifest generated earlier ──────────────────────────────────
    if [[ ! -f "$casper_dir/filesystem.manifest" ]] || [[ ! -s "$casper_dir/filesystem.manifest" ]]; then
        log_warn "Manifest not found or empty — generating now (chroot mounts may be down)..."
        chroot "$chroot_dir" dpkg-query -W --showformat='${Package} ${Version}\n' \
            > "$casper_dir/filesystem.manifest" 2>/dev/null || true
    fi

    # ── Regenerate install-sources.yaml ─────────────────────────────────────
    # MUST mirror the original Ubuntu structure with BOTH entries:
    #   1. ubuntu-desktop-minimal (default: true, path: minimal.squashfs)
    #   2. ubuntu-desktop (default: false, path: minimal.standard.squashfs)
    #
    # The id MUST be ubuntu-desktop-minimal / ubuntu-desktop — subiquity
    # dispatches curthooks (grub-install, initramfs, snap seeding) based on
    # these IDs and the installer was built expecting them.
    #
    # preinstalled_langs is [] on purpose: the stock language layers are gone
    # (see the strategy comment above), and a non-empty list would make
    # subiquity look for minimal.<lang>.squashfs.
    local squashfs_size
    squashfs_size="$(stat -c%s "$casper_dir/minimal.squashfs")"
    local standard_squashfs_size
    standard_squashfs_size="$(stat -c%s "$casper_dir/minimal.standard.squashfs")"

    # Calculate an approximate "enhanced-secureboot" size from original files
    # (these layers are untouched from the base ISO)
    local esb_size="${installed_size}"
    if [[ -f "$casper_dir/minimal.enhanced-secureboot.squashfs" ]]; then
        esb_size="$(stat -c%s "$casper_dir/minimal.enhanced-secureboot.squashfs")"
    fi

    cat > "$casper_dir/install-sources.yaml" << ISYAML
- default: true
  description:
    en: CI-OS Desktop (minimized)
  id: ubuntu-desktop-minimal
  locale_support: langpack
  name:
    en: CI-OS Desktop (minimized)
  path: minimal.squashfs
  preinstalled_langs: []
  size: ${installed_size}
  type: fsimage-layered
  variant: desktop
  variations:
    minimal:
      path: minimal.squashfs
      size: ${squashfs_size}
    minimal-enhanced-secureboot:
      path: minimal.enhanced-secureboot.squashfs
      size: ${esb_size}
      snapd_system_label: enhanced-secureboot-desktop
- default: false
  description:
    en: CI-OS Desktop (full)
  id: ubuntu-desktop
  locale_support: langpack
  name:
    en: CI-OS Desktop
  path: minimal.standard.squashfs
  preinstalled_langs: []
  size: ${installed_size}
  type: fsimage-layered
  variant: desktop
  variations:
    enhanced-secureboot:
      path: minimal.standard.enhanced-secureboot.squashfs
      size: ${esb_size}
      snapd_system_label: enhanced-secureboot-desktop
    standard:
      path: minimal.standard.squashfs
      size: ${squashfs_size}
ISYAML
    log_info "install-sources.yaml regenerated with both entries (minimal + standard)"

    # ── Regenerate SHA256SUMS for ALL squashfs files ────────────────────────
    # Must cover every .squashfs in casper/ or integrity checks fail.
    log_info "Regenerating casper/SHA256SUMS..."
    (cd "$casper_dir" && sha256sum *.squashfs > SHA256SUMS)
    log_info "casper/SHA256SUMS regenerated ($(wc -l < "$casper_dir/SHA256SUMS") entries)"

    # Remove stale Ubuntu GPG signature — it was signed over the original
    # SHA256SUMS and will cause verification failure with our new checksums.
    rm -f "$casper_dir/SHA256SUMS.gpg"
    log_info "Removed stale SHA256SUMS.gpg"

    log_info "Squashfs repacked successfully"
}

# Generate ISO
# Rebrand the parts of the live boot that are NOT in the root filesystem.
#
#  1. casper/initrd is copied verbatim from the base ISO, and the live session's Plymouth splash (the Ubuntu
#     logo) and casper.conf (live user and host name "ubuntu") live inside it. Appending a small compressed
#     cpio overlay replaces exactly those files without unpacking and repacking the whole initrd: the
#     kernel unpacks concatenated archives in order and later files win.
#  2. /.disk/info decides the launcher label ("Install ...") and, unless casper.conf sets FLAVOUR, the live
#     user and host name. Keep its field layout: casper reads field 1 (flavour), fields 1-3 (launcher label),
#     subiquity reads field 2 (release) and pollinate wants the trailing "(serial)".
#
# The ISO volume id is deliberately NOT touched: the signed EFI GRUB searches for it (see generate_iso).
brand_boot_media() {
    log_info "Rebranding live boot media (initrd splash + live identity, .disk/info)..."
    local custom="$WORK_DIR/custom-iso"
    local initrd="$custom/casper/initrd"
    local watermark="$WORK_DIR/chroot/usr/share/plymouth/themes/spinner/watermark.png"
    local casper_conf="$WORK_DIR/chroot/etc/casper.conf"

    if [[ ! -f "$initrd" ]]; then
        log_error "casper/initrd not found at $initrd"; return 1
    fi
    if [[ ! -f "$watermark" || ! -f "$casper_conf" ]]; then
        log_error "branded watermark or casper.conf missing from the chroot (Step 5 / Step 1 did not run?)"; return 1
    fi

    local ov="$WORK_DIR/initrd-overlay"
    rm -rf "$ov"
    mkdir -p "$ov/usr/share/plymouth/themes/spinner" "$ov/etc"
    install -m 644 "$watermark" "$ov/usr/share/plymouth/themes/spinner/watermark.png"
    install -m 644 "$watermark" "$ov/usr/share/plymouth/ubuntu-logo.png"
    install -m 644 "$casper_conf" "$ov/etc/casper.conf"

    ( cd "$ov" && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc -R 0:0 ) \
        | zstd -q -19 -T0 > "$WORK_DIR/initrd-overlay.cpio.zst"
    chmod u+w "$initrd"
    # Pad to a 4-byte boundary (the kernel skips NUL padding between archives), then append.
    local size pad
    size="$(stat -c%s "$initrd")"
    pad=$(( (4 - size % 4) % 4 ))
    if (( pad > 0 )); then head -c "$pad" /dev/zero >> "$initrd"; fi
    cat "$WORK_DIR/initrd-overlay.cpio.zst" >> "$initrd"
    log_info "initrd overlay appended ($(stat -c%s "$WORK_DIR/initrd-overlay.cpio.zst") bytes)"

    local info="$custom/.disk/info"
    if [[ -f "$info" ]]; then
        chmod u+w "$custom/.disk" "$info" 2>/dev/null || true
        cp "$info" "$info.orig"
        # "Ubuntu 24.04.5 LTS "Noble Numbat" - Release amd64 (date)" -> "Companion-OS 24.04.5 LTS ...":
        # the hyphen keeps field 1 a single word (FLAVOUR) and becomes a space in the launcher label.
        sed -i '1s/^Ubuntu\b/Companion-OS/' "$info"
        log_info ".disk/info: $(tr -d '\n' < "$info")"
    fi
}

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
            -e 's/\(menuentry "\)Try or Install Ubuntu/\1Try or Install Companion OS/' \
            -e 's/\(menuentry "\)Ubuntu (safe graphics)/\1Companion OS (safe graphics)/' \
            -e 's/\(menuentry[[:space:]]*"\)Ubuntu\b/\1Companion OS/' \
            "$grub_cfg"
        log_info "GRUB menuentry titles updated to Companion OS"
    fi

    # Also edit loopback.cfg if present (used for booting ISO from GRUB)
    local loopback_cfg="$WORK_DIR/custom-iso/boot/grub/loopback.cfg"
    if [[ -f "$loopback_cfg" ]]; then
        sed -i \
            -e 's/\(menuentry "\)Try or Install Ubuntu/\1Try or Install Companion OS/' \
            -e 's/\(menuentry "\)Ubuntu (safe graphics)/\1Companion OS (safe graphics)/' \
            -e 's/\(menuentry[[:space:]]*"\)Ubuntu\b/\1Companion OS/' \
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
    [[ -f "$WORK_DIR/custom-iso/.disk/info" ]] && xorriso_maps+=(-map "$WORK_DIR/custom-iso/.disk/info" /.disk/info)

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

    # Generate filesystem.manifest-remove is NOT needed for Ubuntu 24.04.
    # The original ISO does not ship one — subiquity handles package removal
    # internally. Adding one with wrong package names can break the installer.
    # Clean up any stale versions from previous builds.
    rm -f "$casper_dir/filesystem.manifest-remove"
    rm -f "$casper_dir/filesystem.manifest-minimal-remove"

    cleanup_chroot
    trap - EXIT
    
    # Finalize
    repack_squashfs
    brand_boot_media
    generate_iso
    
    log_info "Build complete!"
    log_info "ISO location: $OUTPUT_DIR/companion-os-${CI_OS_VERSION}-amd64.iso"
    log_info "Checksums: $OUTPUT_DIR/SHA256SUMS"
}

# Run main unless this file is being sourced (tests/placeholder-layer-modes.sh sources it for
# make_placeholder_layer).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
