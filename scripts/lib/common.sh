#!/usr/bin/env bash
#=============================================================================
# Common Utilities Library
# 
# Shared utility functions for CI-OS setup scripts
#=============================================================================

# Color definitions
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export CYAN='\033[0;36m'
export WHITE='\033[1;37m'
export NC='\033[0m' # No Color

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

log_debug() {
    if [[ "${DEBUG:-}" == "true" ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $1"
    fi
}

# Progress indicator
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if service is running
service_running() {
    systemctl is-active --quiet "$1"
}

# Get OS information
get_os_info() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        export OS_ID="$ID"
        export OS_VERSION="$VERSION_ID"
        export OS_CODENAME="$VERSION_CODENAME"
        export OS_NAME="$NAME"
    else
        log_error "Cannot determine operating system"
        return 1
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Check if user has sudo privileges
check_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Create directory with proper permissions
create_directory() {
    local dir="$1"
    local owner="${2:-$USER}"
    local mode="${3:-755}"
    
    if [[ ! -d "$dir" ]]; then
        log_info "Creating directory: $dir"
        sudo mkdir -p "$dir"
        sudo chown "$owner:$owner" "$dir"
        sudo chmod "$mode" "$dir"
    fi
}

# Download file with progress
download_file() {
    local url="$1"
    local output="$2"
    local description="${3:-Downloading file}"
    
    log_info "$description from $url"
    
    if command_exists wget; then
        wget --progress=bar:force -O "$output" "$url" 2>&1 | grep -o '[0-9]*%' | tail -1
    elif command_exists curl; then
        curl -L --progress-bar -o "$output" "$url"
    else
        log_error "Neither wget nor curl is available"
        return 1
    fi
}

# Backup file with timestamp
backup_file() {
    local file="$1"
    local backup_dir="${2:-$(dirname "$file")}"
    
    if [[ -f "$file" ]]; then
        local filename=$(basename "$file")
        local backup_name="${filename}.backup.$(date +%Y%m%d_%H%M%S)"
        local backup_path="$backup_dir/$backup_name"
        
        log_info "Backing up $file to $backup_path"
        sudo cp "$file" "$backup_path"
        log_success "Backup created: $backup_path"
    fi
}

# Wait for service to be ready
wait_for_service() {
    local service="$1"
    local timeout="${2:-60}"
    local counter=0
    
    log_info "Waiting for $service to be ready..."
    
    while ! service_running "$service" && [[ $counter -lt $timeout ]]; do
        sleep 1
        ((counter++))
    done
    
    if service_running "$service"; then
        log_success "$service is ready"
        return 0
    else
        log_error "$service failed to start within $timeout seconds"
        return 1
    fi
}

# Wait for port to be available
wait_for_port() {
    local host="${1:-localhost}"
    local port="$2"
    local timeout="${3:-60}"
    local counter=0
    
    log_info "Waiting for $host:$port to be available..."
    
    while ! nc -z "$host" "$port" 2>/dev/null && [[ $counter -lt $timeout ]]; do
        sleep 1
        ((counter++))
    done
    
    if nc -z "$host" "$port" 2>/dev/null; then
        log_success "$host:$port is available"
        return 0
    else
        log_error "$host:$port is not available after $timeout seconds"
        return 1
    fi
}

# Check minimum requirements
check_requirements() {
    local requirements=("$@")
    local missing=()
    
    for req in "${requirements[@]}"; do
        if ! command_exists "$req"; then
            missing+=("$req")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        return 1
    else
        log_success "All required commands are available"
        return 0
    fi
}

# Clean up temporary files
cleanup_temp() {
    local temp_pattern="${1:-/tmp/ci-os-*}"
    log_info "Cleaning up temporary files: $temp_pattern"
    rm -rf $temp_pattern 2>/dev/null || true
}

# Get available memory in MB
get_memory_mb() {
    awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

# Get available disk space in MB
get_disk_space_mb() {
    local path="${1:-.}"
    df -m "$path" | awk 'NR==2 {print $4}'
}

# Check system resources
check_system_resources() {
    local min_memory_mb="${1:-2048}"
    local min_disk_mb="${2:-10240}"
    local path="${3:-.}"
    
    local memory_mb=$(get_memory_mb)
    local disk_mb=$(get_disk_space_mb "$path")
    
    log_info "System resources check:"
    echo "  💾 Memory: ${memory_mb}MB (minimum: ${min_memory_mb}MB)"
    echo "  💿 Disk space: ${disk_mb}MB (minimum: ${min_disk_mb}MB)"
    
    if [[ $memory_mb -lt $min_memory_mb ]]; then
        log_warning "Insufficient memory. Recommended: ${min_memory_mb}MB"
    fi
    
    if [[ $disk_mb -lt $min_disk_mb ]]; then
        log_error "Insufficient disk space. Required: ${min_disk_mb}MB"
        return 1
    fi
    
    return 0
}

# Prompt for confirmation
confirm() {
    local message="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        local prompt="$message (Y/n): "
    else
        local prompt="$message (y/N): "
    fi
    
    read -p "$prompt" -n 1 -r
    echo
    
    if [[ "$default" == "y" ]]; then
        [[ $REPLY =~ ^[Nn]$ ]] && return 1 || return 0
    else
        [[ $REPLY =~ ^[Yy]$ ]] && return 0 || return 1
    fi
}

# Generate random password
generate_password() {
    local length="${1:-16}"
    openssl rand -base64 $length | tr -d "=+/" | cut -c1-$length
}

# Validate email address
validate_email() {
    local email="$1"
    if [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Get public IP address
get_public_ip() {
    curl -s https://api.ipify.org || curl -s https://checkip.amazonaws.com || echo "unknown"
}

# Print system information
print_system_info() {
    get_os_info
    local memory_mb=$(get_memory_mb)
    local disk_mb=$(get_disk_space_mb)
    local public_ip=$(get_public_ip)
    
    echo "=== System Information ==="
    echo "🖥️  OS: $OS_NAME $OS_VERSION"
    echo "💾 Memory: ${memory_mb}MB"
    echo "💿 Disk Space: ${disk_mb}MB available"
    echo "🌐 Public IP: $public_ip"
    echo "👤 User: $USER"
    echo "📁 Home: $HOME"
    echo "==========================="
}
