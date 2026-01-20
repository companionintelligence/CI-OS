#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# CI Server Development Environment Setup Script
# 
# This script downloads the CI Server repository and sets up a complete
# development environment on Ubuntu/Debian systems.
#
# Usage: ./setup-ci-server-dev.sh [OPTIONS]
#   -u, --username    GitHub username (required)
#   -t, --token       GitHub personal access token (required)
#   -d, --directory   Installation directory (default: ~/ci-server)
#   -h, --help        Show this help message
#
# Requirements:
#   - Ubuntu 20.04+ or Debian 11+
#   - Internet connection
#   - sudo privileges
#=============================================================================

# Default configuration
DEFAULT_INSTALL_DIR="$HOME/ci-server"
REPO_URL="https://github.com/companionintelligence/CI-Server.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load libraries
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/postgresql-setup.sh"
source "$SCRIPT_DIR/lib/docker-setup.sh"
source "$SCRIPT_DIR/lib/nodejs-setup.sh"
source "$SCRIPT_DIR/lib/ollama-setup.sh"

# Help function
show_help() {
    cat << EOF
CI Server Development Environment Setup

Usage: $0 [OPTIONS]

Options:
  -u, --username <user>     GitHub username (required)
  -t, --token <token>       GitHub personal access token (required)
  -d, --directory <dir>     Installation directory (default: ~/ci-server)
  -h, --help               Show this help message

Example:
  $0 -u myusername -t ghp_xxxxxxxxxxxxxxxxxxxx

GitHub Token Requirements:
  The token should have 'repo' scope for private repositories.
  Generate at: https://github.com/settings/tokens

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--username)
                GITHUB_USERNAME="$2"
                shift 2
                ;;
            -t|--token)
                GITHUB_TOKEN="$2"
                shift 2
                ;;
            -d|--directory)
                INSTALL_DIR="$2"
                shift 2
                ;;
            -h|--help)
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

    # Validate required arguments
    if [[ -z "${GITHUB_USERNAME:-}" ]]; then
        log_error "GitHub username is required. Use -u or --username"
        show_help
        exit 1
    fi

    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        log_error "GitHub token is required. Use -t or --token"
        show_help
        exit 1
    fi

    # Set default directory if not provided
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
}

# Check system requirements
check_system() {
    log_info "Checking system requirements..."
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine operating system"
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log_warning "This script is designed for Ubuntu/Debian. Your OS: $ID"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check sudo privileges
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo privileges"
        exit 1
    fi
    
    log_success "System requirements check passed"
}

# Install system dependencies
install_system_dependencies() {
    log_info "Installing system dependencies..."
    
    # Update package list
    sudo apt-get update -y
    
    # Install essential packages
    sudo apt-get install -y \
        curl \
        wget \
        git \
        build-essential \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        unzip \
        zip \
        htop \
        tree \
        vim \
        nano
    
    log_success "System dependencies installed"
}

# Install Node.js using NodeSource repository
install_nodejs() {
    log_info "Installing Node.js..."
    
    setup_nodejs_environment false
    
    log_success "Node.js setup completed"
}

# Install Docker
install_docker() {
    log_info "Installing Docker..."
    
    install_docker_ce
    configure_docker_user "$USER"
    start_docker_service
    test_docker
    
    log_success "Docker installation completed"
}

# Install Ollama
install_ollama() {
    log_info "Installing Ollama..."
    
    setup_ollama_complete "nomic-embed-text"
    
    log_success "Ollama installation completed"
}

# Install asdf version manager (optional alternative)
install_asdf() {
    log_info "Installing asdf version manager..."
    
    # This is now optional since we're using direct Node.js installation by default
    # Users can manually run setup_nodejs_environment true to use asdf instead
    
    log_info "Skipping asdf installation (using direct Node.js installation)"
    log_info "To use asdf instead, run: setup_nodejs_environment true"
}

# Clone CI Server repository
clone_repository() {
    log_info "Cloning CI Server repository to $INSTALL_DIR..."
    
    # Create installation directory
    mkdir -p "$(dirname "$INSTALL_DIR")"
    
    # Remove existing directory if it exists
    if [[ -d "$INSTALL_DIR" ]]; then
        log_warning "Directory $INSTALL_DIR already exists"
        read -p "Remove and re-clone? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
        else
            log_error "Installation cancelled"
            exit 1
        fi
    fi
    
    # Clone repository with authentication
    REPO_WITH_AUTH="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/companionintelligence/CI-Server.git"
    git clone "$REPO_WITH_AUTH" "$INSTALL_DIR"
    
    # Change to repository directory
    cd "$INSTALL_DIR"
    
    # Remove token from git remote for security
    git remote set-url origin "$REPO_URL"
    
    log_success "Repository cloned successfully"
}

# Setup PostgreSQL database
setup_postgresql() {
    log_info "Setting up PostgreSQL database..."
    
    # Use the existing PostgreSQL setup script logic
    source "$SCRIPT_DIR/lib/postgresql-setup.sh"
    setup_postgresql_database
    
    log_success "PostgreSQL setup completed"
}

# Setup development environment
setup_dev_environment() {
    log_info "Setting up development environment..."
    
    cd "$INSTALL_DIR"
    
    # Setup workspace dependencies
    setup_workspace_dependencies "$INSTALL_DIR"
    
    # Initialize repository
    if [[ -f "Makefile" ]]; then
        log_info "Running make init..."
        make init
        
        log_info "Running database migrations..."
        make migrate
    else
        log_warning "Makefile not found, running migrations manually..."
        
        # Run migrations manually
        if [[ -d "backend/apps/api" ]]; then
            cd backend/apps/api
            if [[ -f "package.json" ]] && grep -q "migrate" package.json; then
                yarn migrate || npm run migrate
            fi
            cd ../../..
        fi
    fi
    
    log_success "Development environment setup completed"
}

# Setup hosts file
setup_hosts() {
    log_info "Setting up hosts file..."
    
    # Check if entry already exists
    if ! grep -q "dev.companionintelligence.com" /etc/hosts; then
        echo "127.0.0.1 dev.companionintelligence.com" | sudo tee -a /etc/hosts
        log_success "Added dev.companionintelligence.com to hosts file"
    else
        log_info "hosts file entry already exists"
    fi
}

# Pull required Ollama models
setup_ollama_models() {
    log_info "Verifying Ollama models..."
    
    # Models should already be pulled during installation
    list_ollama_models
    
    log_success "Ollama models verified"
}

# Start development services
start_services() {
    log_info "Starting development services..."
    
    cd "$INSTALL_DIR"
    
    # Start Docker infrastructure
    setup_docker_compose_dev "$INSTALL_DIR"
    
    # Start development servers with PM2
    if [[ -d "frontend/apps/web" ]]; then
        pm2 start yarn --name "ci-web" --cwd ./frontend/apps/web -- dev
    fi
    
    if [[ -d "backend/apps/api" ]]; then
        pm2 start yarn --name "ci-api" --cwd ./backend/apps/api -- dev
    fi
    
    # Save PM2 configuration
    pm2 save
    pm2 startup
    
    log_success "Development services started"
}

# Show completion message
show_completion() {
    log_success "🎉 CI Server development environment setup completed!"
    echo
    echo "Installation Details:"
    echo "  📁 Installation Directory: $INSTALL_DIR"
    echo "  🌐 Web Application: http://dev.companionintelligence.com"
    echo "  📊 Database: PostgreSQL (companion_intel/comp4nion_1ntel_ftw!)"
    echo
    echo "Next Steps:"
    echo "  1. Log out and log back in (or run 'newgrp docker') to apply Docker group membership"
    echo "  2. Visit http://dev.companionintelligence.com to access the application"
    echo "  3. Check service status with: pm2 status"
    echo "  4. View logs with: pm2 logs"
    echo "  5. Stop services with: pm2 stop all"
    echo
    echo "Additional Tools:"
    echo "  • Docker services: docker compose --profile tools up -d"
    echo "  • OpenSearch Dashboard: Available after starting tools profile"
    echo "  • Open WebUI: Available after starting tools profile"
    echo
    log_info "Happy coding! 🚀"
}

# Main execution
main() {
    echo "=== CI Server Development Environment Setup ==="
    echo
    
    parse_args "$@"
    check_system
    install_system_dependencies
    install_nodejs
    install_docker
    install_ollama
    install_asdf
    clone_repository
    setup_postgresql
    setup_dev_environment
    setup_hosts
    setup_ollama_models
    start_services
    show_completion
}

# Run main function with all arguments
main "$@"
