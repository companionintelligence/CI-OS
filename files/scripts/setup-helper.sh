#!/usr/bin/bash
# CI-OS Setup Helper Script
# This script provides common functions used by ujust commands

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Check if running as root
check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        exit 1
    fi
}

# Check system requirements
check_system_requirements() {
    local variant="${CI_OS_VARIANT:-regular}"
    
    log_info "Checking system requirements for CI-OS $variant..."
    
    # Check available memory
    local total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    if [[ $total_mem -lt 8192 ]]; then
        log_warning "Less than 8GB RAM detected ($total_mem MB). Some features may not work optimally."
    else
        log_success "Memory: ${total_mem}MB available"
    fi
    
    # Check available disk space
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local available_gb=$((available_space / 1024 / 1024))
    if [[ $available_gb -lt 20 ]]; then
        log_warning "Less than 20GB disk space available (${available_gb}GB). Some features may not work."
    else
        log_success "Disk space: ${available_gb}GB available"
    fi
    
    # NVIDIA-specific checks
    if [[ "$variant" == "nvidia" ]]; then
        if command -v nvidia-smi >/dev/null 2>&1; then
            log_success "NVIDIA drivers detected"
        else
            log_warning "NVIDIA drivers not detected. Some features may not work."
        fi
    fi
}

# Create user directories
create_user_directories() {
    log_info "Creating user directories..."
    
    mkdir -p "${HOME}/.config/ci-os"
    mkdir -p "${HOME}/.cache/ci-os"
    mkdir -p "${HOME}/.local/share/ci-os"
    
    # Wine directories
    mkdir -p "${HOME}/.wine"
    mkdir -p "${HOME}/.cache/wine"
    
    # Proton directories
    mkdir -p "${HOME}/.cache/protontricks"
    mkdir -p "${HOME}/.local/share/Steam"
    
    # WinApps directories
    mkdir -p "${HOME}/.config/winapps"
    mkdir -p "${HOME}/.local/share/winapps"
    
    log_success "User directories created"
}

# Set up CI-OS environment
setup_environment() {
    log_info "Setting up CI-OS environment..."
    
    # Create CI-OS info file
    cat > "${HOME}/.config/ci-os/info" << EOF
CI_OS_VERSION=${CI_OS_VERSION:-v01}
CI_OS_VARIANT=${CI_OS_VARIANT:-regular}
CI_OS_SETUP_DATE=$(date -Iseconds)
EOF
    
    # Set up shell environment if not already done
    if [[ ! -f "${HOME}/.bashrc" ]] || ! grep -q "CI-OS Environment" "${HOME}/.bashrc"; then
        cat >> "${HOME}/.bashrc" << 'EOF'

# CI-OS Environment
export CI_OS_USER_CONFIG="${HOME}/.config/ci-os"
export CI_OS_USER_CACHE="${HOME}/.cache/ci-os"
export CI_OS_USER_DATA="${HOME}/.local/share/ci-os"

# Wine environment
export WINEPREFIX="${HOME}/.wine"
export WINEARCH="win64"

# Add CI-OS tools to PATH
if [[ -d "/usr/share/ci-os/scripts" ]]; then
    export PATH="/usr/share/ci-os/scripts:$PATH"
fi
EOF
        log_success "Environment configuration added to ~/.bashrc"
    else
        log_info "Environment already configured"
    fi
}

# Main setup function
main() {
    log_info "CI-OS Setup Helper"
    log_info "=================="
    
    check_not_root
    check_system_requirements
    create_user_directories
    setup_environment
    
    log_success "CI-OS setup helper completed successfully!"
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi