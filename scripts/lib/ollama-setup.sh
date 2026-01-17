#!/usr/bin/env bash
#=============================================================================
# Ollama Setup Library
# 
# Shared functions for Ollama installation and model management
#=============================================================================

# Install Ollama
install_ollama() {
    log_info "Installing Ollama..."
    
    # Check if Ollama is already installed
    if command_exists ollama; then
        local current_version=$(ollama --version 2>/dev/null | head -n1 || echo "unknown")
        log_info "Ollama already installed: $current_version"
        return 0
    fi
    
    # Install Ollama using official installer
    curl -fsSL https://ollama.com/install.sh | sh
    
    # Verify installation
    if command_exists ollama; then
        local ollama_version=$(ollama --version 2>/dev/null | head -n1 || echo "installed")
        log_success "Ollama installed: $ollama_version"
    else
        log_error "Ollama installation failed"
        return 1
    fi
}

# Start Ollama service
start_ollama_service() {
    log_info "Starting Ollama service..."
    
    # Check if running as systemd service
    if systemctl is-active --quiet ollama 2>/dev/null; then
        log_info "Ollama service already running"
        return 0
    fi
    
    # Try to start as systemd service
    if sudo systemctl start ollama 2>/dev/null; then
        sudo systemctl enable ollama
        log_success "Ollama service started and enabled"
    else
        # Start Ollama in background if systemd not available
        log_info "Starting Ollama in background..."
        nohup ollama serve > /tmp/ollama.log 2>&1 &
        
        # Wait for service to be ready
        sleep 5
        
        if pgrep -f "ollama serve" > /dev/null; then
            log_success "Ollama started in background"
        else
            log_error "Failed to start Ollama"
            return 1
        fi
    fi
}

# Check if Ollama is running
check_ollama_status() {
    if systemctl is-active --quiet ollama 2>/dev/null; then
        log_success "Ollama service is running (systemd)"
        return 0
    elif pgrep -f "ollama serve" > /dev/null; then
        log_success "Ollama is running (background process)"
        return 0
    else
        log_warning "Ollama is not running"
        return 1
    fi
}

# Pull required models
pull_ollama_models() {
    local models=("${@:-nomic-embed-text}")
    
    log_info "Pulling Ollama models: ${models[*]}"
    
    # Wait for Ollama to be ready
    wait_for_ollama
    
    for model in "${models[@]}"; do
        log_info "Pulling model: $model"
        
        if ollama pull "$model"; then
            log_success "Model pulled: $model"
        else
            log_error "Failed to pull model: $model"
            return 1
        fi
    done
    
    log_success "All models pulled successfully"
}

# Wait for Ollama to be ready
wait_for_ollama() {
    local timeout="${1:-60}"
    local counter=0
    
    log_info "Waiting for Ollama to be ready..."
    
    while [[ $counter -lt $timeout ]]; do
        if ollama list > /dev/null 2>&1; then
            log_success "Ollama is ready"
            return 0
        fi
        
        sleep 2
        ((counter += 2))
    done
    
    log_error "Ollama not ready after $timeout seconds"
    return 1
}

# List installed models
list_ollama_models() {
    log_info "Listing installed Ollama models:"
    
    if wait_for_ollama 10; then
        ollama list
    else
        log_error "Cannot connect to Ollama"
        return 1
    fi
}

# Remove a model
remove_ollama_model() {
    local model="$1"
    
    if [[ -z "$model" ]]; then
        log_error "Model name required"
        return 1
    fi
    
    log_info "Removing model: $model"
    
    if ollama rm "$model"; then
        log_success "Model removed: $model"
    else
        log_error "Failed to remove model: $model"
        return 1
    fi
}

# Test Ollama functionality
test_ollama() {
    log_info "Testing Ollama functionality..."
    
    if ! wait_for_ollama 30; then
        log_error "Ollama test failed - service not ready"
        return 1
    fi
    
    # Test with nomic-embed-text if available
    if ollama list | grep -q "nomic-embed-text"; then
        log_info "Testing embedding generation..."
        
        local test_response=$(echo "test embedding" | ollama run nomic-embed-text 2>/dev/null)
        if [[ -n "$test_response" ]]; then
            log_success "Ollama embedding test passed"
        else
            log_warning "Ollama embedding test produced no output"
        fi
    else
        log_info "No models available for testing"
    fi
    
    return 0
}

# Configure Ollama environment
configure_ollama() {
    log_info "Configuring Ollama environment..."
    
    # Create Ollama configuration directory
    local ollama_config_dir="$HOME/.ollama"
    mkdir -p "$ollama_config_dir"
    
    # Set environment variables in shell profile
    local shell_profile="$HOME/.bashrc"
    if [[ "$SHELL" == *"zsh"* ]]; then
        shell_profile="$HOME/.zshrc"
    fi
    
    # Add Ollama environment variables if not present
    if ! grep -q "OLLAMA_HOST" "$shell_profile" 2>/dev/null; then
        echo '' >> "$shell_profile"
        echo '# Ollama configuration' >> "$shell_profile"
        echo 'export OLLAMA_HOST=127.0.0.1:11434' >> "$shell_profile"
        echo 'export OLLAMA_KEEP_ALIVE=5m' >> "$shell_profile"
    fi
    
    # Set for current session
    export OLLAMA_HOST=127.0.0.1:11434
    export OLLAMA_KEEP_ALIVE=5m
    
    log_success "Ollama environment configured"
}

# Install and setup Ollama completely
setup_ollama_complete() {
    local models="${1:-nomic-embed-text}"
    
    install_ollama
    configure_ollama
    start_ollama_service
    
    # Convert models string to array
    IFS=',' read -ra model_array <<< "$models"
    pull_ollama_models "${model_array[@]}"
    
    test_ollama
    
    log_success "Ollama setup completed"
}

# Show Ollama status and information
ollama_status() {
    echo "=== Ollama Status ==="
    
    if command_exists ollama; then
        local version=$(ollama --version 2>/dev/null | head -n1 || echo "unknown")
        echo "🤖 Version: $version"
        
        if check_ollama_status; then
            echo "🟢 Status: Running"
            echo "📊 Models:"
            ollama list 2>/dev/null | sed 's/^/  /'
        else
            echo "🔴 Status: Not running"
        fi
    else
        echo "❌ Ollama not installed"
    fi
    
    echo "===================="
}
