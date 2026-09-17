#!/usr/bin/env bash
#=============================================================================
# Docker Setup Library
# 
# Shared functions for Docker installation and configuration
#=============================================================================

# Install Docker CE
install_docker_ce() {
    log_info "Installing Docker CE..."
    
    # Remove old versions
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Install prerequisites
    sudo apt-get update
    sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    log_success "Docker CE installed successfully"
}

# Install Docker Desktop (for Ubuntu)
install_docker_desktop() {
    local codename="${1:-$(lsb_release -cs)}"
    local docker_deb_url="https://desktop.docker.com/linux/main/amd64/docker-desktop-amd64.deb"
    
    log_info "Installing Docker Desktop..."
    
    # Install Docker CE first
    install_docker_ce
    
    # Download and install Docker Desktop
    local temp_deb="/tmp/docker-desktop.deb"
    download_file "$docker_deb_url" "$temp_deb" "Downloading Docker Desktop"
    
    sudo apt-get install -y "$temp_deb"
    rm -f "$temp_deb"
    
    log_success "Docker Desktop installed successfully"
}

# Configure Docker for current user
configure_docker_user() {
    local username="${1:-$USER}"
    
    log_info "Configuring Docker for user: $username"
    
    # Add user to docker group
    sudo usermod -aG docker "$username"
    
    # Create docker directory if it doesn't exist
    if [[ ! -d "/home/$username/.docker" ]]; then
        sudo mkdir -p "/home/$username/.docker"
        sudo chown "$username:$username" "/home/$username/.docker"
    fi
    
    log_success "Docker configured for user: $username"
    log_warning "Please log out and log back in (or run 'newgrp docker') for group changes to take effect"
}

# Start and enable Docker service
start_docker_service() {
    log_info "Starting Docker service..."
    
    sudo systemctl start docker
    sudo systemctl enable docker
    
    if wait_for_service docker 30; then
        log_success "Docker service started successfully"
    else
        log_error "Failed to start Docker service"
        return 1
    fi
}

# Test Docker installation
test_docker() {
    log_info "Testing Docker installation..."
    
    if docker --version > /dev/null 2>&1; then
        local docker_version=$(docker --version)
        log_success "Docker version: $docker_version"
    else
        log_error "Docker command not found or not working"
        return 1
    fi
    
    if docker compose version > /dev/null 2>&1; then
        local compose_version=$(docker compose version)
        log_success "Docker Compose version: $compose_version"
    else
        log_error "Docker Compose not found or not working"
        return 1
    fi
    
    # Test docker run (if user is in docker group)
    if groups | grep -q docker; then
        log_info "Testing Docker container execution..."
        if docker run --rm hello-world > /dev/null 2>&1; then
            log_success "Docker container test passed"
        else
            log_warning "Docker container test failed - you may need to log out and back in"
        fi
    else
        log_warning "Current user not in docker group - container test skipped"
    fi
}

# Setup Docker Compose for development
setup_docker_compose_dev() {
    local project_dir="${1:-.}"
    
    log_info "Setting up Docker Compose for development..."
    
    if [[ ! -f "$project_dir/docker-compose.yml" ]]; then
        log_warning "docker-compose.yml not found in $project_dir"
        return 1
    fi
    
    cd "$project_dir"
    
    # Start local development infrastructure
    log_info "Starting local development infrastructure..."
    docker compose --profile local up -d
    
    # Wait for services to be ready
    sleep 10
    
    # Check if services are running
    if docker compose ps | grep -q "Up"; then
        log_success "Docker Compose services started successfully"
        docker compose ps
    else
        log_error "Failed to start Docker Compose services"
        docker compose logs
        return 1
    fi
}

# Setup Docker Compose tools profile
setup_docker_compose_tools() {
    local project_dir="${1:-.}"
    
    log_info "Setting up Docker Compose tools profile..."
    
    cd "$project_dir"
    
    # Start tools/monitoring infrastructure
    log_info "Starting tools and monitoring infrastructure..."
    docker compose --profile tools up -d
    
    # Wait for services to be ready
    sleep 15
    
    # Check if services are running
    if docker compose ps --profile tools | grep -q "Up"; then
        log_success "Docker Compose tools started successfully"
        docker compose ps --profile tools
    else
        log_error "Failed to start Docker Compose tools"
        docker compose logs
        return 1
    fi
}

# Clean up Docker resources
cleanup_docker() {
    log_info "Cleaning up Docker resources..."
    
    # Remove stopped containers
    docker container prune -f
    
    # Remove unused images
    docker image prune -f
    
    # Remove unused volumes
    docker volume prune -f
    
    # Remove unused networks
    docker network prune -f
    
    log_success "Docker cleanup completed"
}

# Get Docker system information
docker_system_info() {
    log_info "Docker System Information:"
    
    if command_exists docker; then
        echo "🐳 Docker Version: $(docker --version)"
        echo "🔧 Docker Compose Version: $(docker compose version --short)"
        
        if docker info > /dev/null 2>&1; then
            local containers_running=$(docker ps -q | wc -l)
            local containers_total=$(docker ps -a -q | wc -l)
            local images_count=$(docker images -q | wc -l)
            local volumes_count=$(docker volume ls -q | wc -l)
            
            echo "📦 Containers: $containers_running running, $containers_total total"
            echo "🖼️  Images: $images_count"
            echo "💾 Volumes: $volumes_count"
        fi
    else
        echo "❌ Docker not installed"
    fi
}
