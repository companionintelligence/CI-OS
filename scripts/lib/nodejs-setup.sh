#!/usr/bin/env bash
#=============================================================================
# Node.js Setup Library
# 
# Shared functions for Node.js, npm, yarn, and asdf version manager setup
#=============================================================================

# Install asdf version manager
install_asdf() {
    log_info "Installing asdf version manager..."
    
    local asdf_version="v0.14.0"
    local asdf_dir="$HOME/.asdf"
    
    # Remove existing asdf installation
    if [[ -d "$asdf_dir" ]]; then
        log_warning "Existing asdf installation found, removing..."
        rm -rf "$asdf_dir"
    fi
    
    # Clone asdf
    git clone https://github.com/asdf-vm/asdf.git "$asdf_dir" --branch "$asdf_version"
    
    # Add to shell profile
    local shell_profile="$HOME/.bashrc"
    if [[ "$SHELL" == *"zsh"* ]]; then
        shell_profile="$HOME/.zshrc"
    fi
    
    # Add asdf to shell profile if not already present
    if ! grep -q "asdf.sh" "$shell_profile" 2>/dev/null; then
        echo '' >> "$shell_profile"
        echo '# asdf version manager' >> "$shell_profile"
        echo '. "$HOME/.asdf/asdf.sh"' >> "$shell_profile"
        echo '. "$HOME/.asdf/completions/asdf.bash"' >> "$shell_profile"
    fi
    
    # Source asdf for current session
    export PATH="$HOME/.asdf/bin:$PATH"
    source "$HOME/.asdf/asdf.sh"
    
    # Create .asdfrc with legacy version file support
    echo 'legacy_version_file = yes' > "$HOME/.asdfrc"
    
    log_success "asdf version manager installed"
}

# Install Node.js plugin for asdf
install_nodejs_plugin() {
    log_info "Installing Node.js plugin for asdf..."
    
    # Ensure asdf is available
    if ! command_exists asdf; then
        source "$HOME/.asdf/asdf.sh"
    fi
    
    # Install nodejs plugin
    asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git || true
    
    # Install latest LTS Node.js
    local node_version="18.20.2"
    log_info "Installing Node.js $node_version..."
    asdf install nodejs "$node_version"
    asdf global nodejs "$node_version"
    
    # Verify installation
    local installed_version=$(asdf current nodejs | awk '{print $2}')
    log_success "Node.js $installed_version installed via asdf"
}

# Install Node.js directly (alternative to asdf)
install_nodejs_direct() {
    log_info "Installing Node.js directly..."
    
    # Install Node.js 18.x LTS via NodeSource
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
    
    # Verify installation
    local node_version=$(node --version)
    local npm_version=$(npm --version)
    log_success "Node.js installed: $node_version, npm: $npm_version"
}

# Setup global npm packages
setup_global_npm_packages() {
    log_info "Installing global npm packages..."
    
    # Enable corepack for yarn support
    sudo npm install -g corepack
    sudo corepack enable
    
    # Install essential global packages
    sudo npm install -g \
        pm2 \
        nodemon \
        typescript \
        @types/node
    
    # Verify yarn is available
    if command_exists yarn; then
        local yarn_version=$(yarn --version)
        log_success "Yarn available: $yarn_version"
    else
        log_error "Yarn not available after corepack enable"
        return 1
    fi
    
    log_success "Global npm packages installed"
}

# Configure npm for development
configure_npm() {
    log_info "Configuring npm for development..."
    
    # Set npm registry (default is fine, but making it explicit)
    npm config set registry https://registry.npmjs.org/
    
    # Set npm init defaults
    npm config set init-author-name "CI OS Developer"
    npm config set init-license "MIT"
    npm config set init-version "0.1.0"
    
    # Configure npm to use exact versions by default
    npm config set save-exact true
    
    log_success "npm configured for development"
}

# Install project dependencies
install_project_dependencies() {
    local project_dir="${1:-.}"
    
    log_info "Installing project dependencies in $project_dir..."
    
    cd "$project_dir"
    
    # Check if package.json exists
    if [[ ! -f "package.json" ]]; then
        log_warning "No package.json found in $project_dir"
        return 0
    fi
    
    # Install dependencies with yarn if available, otherwise npm
    if command_exists yarn; then
        log_info "Installing dependencies with yarn..."
        yarn install
    else
        log_info "Installing dependencies with npm..."
        npm install
    fi
    
    log_success "Project dependencies installed"
}

# Setup workspace dependencies
setup_workspace_dependencies() {
    local workspace_dir="$1"
    
    log_info "Setting up workspace dependencies..."
    
    cd "$workspace_dir"
    
    # Install root dependencies
    install_project_dependencies "$workspace_dir"
    
    # Install backend dependencies
    if [[ -d "backend/apps/api" ]]; then
        log_info "Installing backend API dependencies..."
        install_project_dependencies "$workspace_dir/backend/apps/api"
    fi
    
    # Install frontend dependencies
    if [[ -d "frontend/apps/web" ]]; then
        log_info "Installing frontend web dependencies..."
        install_project_dependencies "$workspace_dir/frontend/apps/web"
    fi
    
    # Install other app dependencies
    for app_dir in "$workspace_dir"/backend/apps/*; do
        if [[ -d "$app_dir" && -f "$app_dir/package.json" && "$app_dir" != "$workspace_dir/backend/apps/api" ]]; then
            local app_name=$(basename "$app_dir")
            log_info "Installing $app_name dependencies..."
            install_project_dependencies "$app_dir"
        fi
    done
    
    for app_dir in "$workspace_dir"/frontend/apps/*; do
        if [[ -d "$app_dir" && -f "$app_dir/package.json" && "$app_dir" != "$workspace_dir/frontend/apps/web" ]]; then
            local app_name=$(basename "$app_dir")
            log_info "Installing $app_name dependencies..."
            install_project_dependencies "$app_dir"
        fi
    done
    
    log_success "Workspace dependencies setup completed"
}

# Create .nvmrc file for Node.js version
create_nvmrc() {
    local project_dir="${1:-.}"
    local node_version="${2:-18.20.2}"
    
    echo "$node_version" > "$project_dir/.nvmrc"
    log_success "Created .nvmrc with Node.js version $node_version"
}

# Check Node.js installation
check_nodejs() {
    log_info "Checking Node.js installation..."
    
    if command_exists node; then
        local node_version=$(node --version)
        log_success "Node.js: $node_version"
    else
        log_error "Node.js not found"
        return 1
    fi
    
    if command_exists npm; then
        local npm_version=$(npm --version)
        log_success "npm: $npm_version"
    else
        log_error "npm not found"
        return 1
    fi
    
    if command_exists yarn; then
        local yarn_version=$(yarn --version)
        log_success "Yarn: $yarn_version"
    else
        log_warning "Yarn not found"
    fi
    
    if command_exists pm2; then
        local pm2_version=$(pm2 --version)
        log_success "PM2: $pm2_version"
    else
        log_warning "PM2 not found"
    fi
    
    return 0
}

# Setup Node.js complete environment
setup_nodejs_environment() {
    local use_asdf="${1:-false}"
    
    if [[ "$use_asdf" == "true" ]]; then
        install_asdf
        install_nodejs_plugin
    else
        install_nodejs_direct
    fi
    
    setup_global_npm_packages
    configure_npm
    check_nodejs
}
