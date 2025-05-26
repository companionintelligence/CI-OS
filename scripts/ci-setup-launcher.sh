#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# CI Server Quick Setup Launcher
# 
# Interactive launcher for CI Server development environment setup
#=============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Show welcome banner
show_banner() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    CI Server Setup Launcher                 ║"
    echo "║                                                              ║"
    echo "║  Automated setup for CI Server development environment      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo
}

# Show main menu
show_menu() {
    echo "Please select an option:"
    echo
    echo "1) 🚀 Full CI Server Setup (Download + Install Everything)"
    echo "2) 🔧 Local Repository Setup (Setup Existing Repository)"
    echo "3) 🖥️  AMD Hardware Setup (CI Server + AMD GPU Support)"
    echo "4) 🧪 Validate Installation"
    echo "5) 📖 View Documentation"
    echo "6) 🚪 Exit"
    echo
}

# Get GitHub credentials
get_github_credentials() {
    echo "GitHub Authentication Required"
    echo "==============================="
    echo
    read -p "GitHub Username: " github_username
    echo
    read -s -p "GitHub Personal Access Token: " github_token
    echo
    echo
    
    if [[ -z "$github_username" || -z "$github_token" ]]; then
        log_error "GitHub credentials are required for repository access"
        return 1
    fi
    
    # Validate token format
    if [[ ! "$github_token" =~ ^(ghp_|github_pat_) ]]; then
        log_warning "Token format looks unusual. Expected format: ghp_... or github_pat_..."
        if ! confirm "Continue anyway?"; then
            return 1
        fi
    fi
    
    export GITHUB_USERNAME="$github_username"
    export GITHUB_TOKEN="$github_token"
}

# Get installation directory
get_install_directory() {
    local default_dir="$HOME/ci-server"
    echo
    read -p "Installation directory [$default_dir]: " install_dir
    install_dir="${install_dir:-$default_dir}"
    
    if [[ -d "$install_dir" ]]; then
        log_warning "Directory $install_dir already exists"
        if ! confirm "Continue and overwrite?"; then
            return 1
        fi
    fi
    
    export INSTALL_DIR="$install_dir"
}

# Full setup option
full_setup() {
    log_info "Starting full CI Server setup..."
    
    get_github_credentials || return 1
    get_install_directory || return 1
    
    log_info "Starting setup with:"
    echo "  📁 Directory: $INSTALL_DIR"
    echo "  👤 GitHub User: $GITHUB_USERNAME"
    echo "  🔑 Token: ${GITHUB_TOKEN:0:10}..."
    echo
    
    if confirm "Proceed with installation?"; then
        "$SCRIPT_DIR/setup-ci-server-dev.sh" \
            --username "$GITHUB_USERNAME" \
            --token "$GITHUB_TOKEN" \
            --directory "$INSTALL_DIR"
    fi
}

# Local repository setup
local_setup() {
    log_info "Setting up existing repository..."
    
    # Find CI Server directory
    local current_dir="$PWD"
    local ci_server_dir=""
    
    # Check current directory
    if [[ -f "$current_dir/package.json" ]] && grep -q "companionintelligence" "$current_dir/package.json" 2>/dev/null; then
        ci_server_dir="$current_dir"
    elif [[ -d "$current_dir/ci-server" ]]; then
        ci_server_dir="$current_dir/ci-server"
    elif [[ -d "$HOME/ci-server" ]]; then
        ci_server_dir="$HOME/ci-server"
    fi
    
    if [[ -n "$ci_server_dir" ]]; then
        log_info "Found CI Server repository: $ci_server_dir"
        if confirm "Setup development environment in $ci_server_dir?"; then
            cd "$ci_server_dir"
            "$SCRIPT_DIR/ci-server-linux-dev-setup.sh"
        fi
    else
        echo "CI Server repository not found."
        read -p "Enter path to CI Server repository: " ci_server_dir
        
        if [[ -d "$ci_server_dir" ]]; then
            cd "$ci_server_dir"
            "$SCRIPT_DIR/ci-server-linux-dev-setup.sh"
        else
            log_error "Directory not found: $ci_server_dir"
        fi
    fi
}

# AMD hardware setup
amd_setup() {
    log_info "Starting AMD hardware setup..."
    
    log_warning "This will install AMD ROCm drivers and Docker Desktop"
    if confirm "Continue with AMD hardware setup?"; then
        sudo "$SCRIPT_DIR/ci-server-setup-ubuntu-amd.sh"
    fi
}

# Validate installation
validate_installation() {
    local default_dir="$HOME/ci-server"
    read -p "CI Server directory to validate [$default_dir]: " validate_dir
    validate_dir="${validate_dir:-$default_dir}"
    
    "$SCRIPT_DIR/validate-ci-server.sh" "$validate_dir"
}

# View documentation
view_documentation() {
    if command_exists less; then
        less "$SCRIPT_DIR/README.md"
    elif command_exists more; then
        more "$SCRIPT_DIR/README.md"
    else
        cat "$SCRIPT_DIR/README.md"
    fi
}

# Main loop
main() {
    show_banner
    print_system_info
    echo
    
    while true; do
        show_menu
        read -p "Enter your choice [1-6]: " choice
        echo
        
        case $choice in
            1)
                full_setup
                ;;
            2)
                local_setup
                ;;
            3)
                amd_setup
                ;;
            4)
                validate_installation
                ;;
            5)
                view_documentation
                ;;
            6)
                log_info "Goodbye! 👋"
                exit 0
                ;;
            *)
                log_error "Invalid choice. Please select 1-6."
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
        echo
    done
}

# Check if running on supported OS
if ! get_os_info; then
    log_error "Cannot determine operating system"
    exit 1
fi

if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
    log_warning "This launcher is designed for Ubuntu/Debian systems"
    log_warning "Current OS: $OS_NAME"
    echo
    if ! confirm "Continue anyway?"; then
        exit 1
    fi
fi

# Run main function
main
