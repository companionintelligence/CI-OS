#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# CI Server Development Environment Validation Script
# 
# Validates that the CI Server development environment is properly set up
#=============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Configuration
CI_SERVER_DIR="${1:-$HOME/ci-server}"

# Validation results
VALIDATION_RESULTS=()
FAILED_CHECKS=0

# Add validation result
add_result() {
    local status="$1"
    local message="$2"
    
    if [[ "$status" == "PASS" ]]; then
        VALIDATION_RESULTS+=("✅ $message")
    elif [[ "$status" == "FAIL" ]]; then
        VALIDATION_RESULTS+=("❌ $message")
        ((FAILED_CHECKS++))
    elif [[ "$status" == "WARN" ]]; then
        VALIDATION_RESULTS+=("⚠️  $message")
    else
        VALIDATION_RESULTS+=("ℹ️  $message")
    fi
}

# Check system dependencies
check_system_dependencies() {
    log_info "Checking system dependencies..."
    
    local deps=("curl" "wget" "git" "docker" "node" "npm" "yarn" "pm2" "psql" "ollama")
    
    for dep in "${deps[@]}"; do
        if command_exists "$dep"; then
            local version=""
            case "$dep" in
                "docker") version=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',') ;;
                "node") version=$(node --version) ;;
                "npm") version=$(npm --version) ;;
                "yarn") version=$(yarn --version) ;;
                "pm2") version=$(pm2 --version) ;;
                "ollama") version=$(ollama --version 2>/dev/null | head -n1 | cut -d' ' -f2 || echo "installed") ;;
                *) version="installed" ;;
            esac
            add_result "PASS" "$dep: $version"
        else
            add_result "FAIL" "$dep: not found"
        fi
    done
}

# Check services
check_services() {
    log_info "Checking services..."
    
    # PostgreSQL
    if service_running postgresql; then
        add_result "PASS" "PostgreSQL service is running"
        
        # Test database connection
        if PGPASSWORD="comp4nion_1ntel_ftw!" psql -h localhost -U companion_intel -d companion_intel -c "SELECT 1;" > /dev/null 2>&1; then
            add_result "PASS" "PostgreSQL database connection successful"
        else
            add_result "FAIL" "PostgreSQL database connection failed"
        fi
    else
        add_result "FAIL" "PostgreSQL service is not running"
    fi
    
    # Docker
    if service_running docker; then
        add_result "PASS" "Docker service is running"
        
        # Test docker command
        if docker ps > /dev/null 2>&1; then
            add_result "PASS" "Docker command works (user in docker group)"
        else
            add_result "WARN" "Docker command failed (may need to log out/in)"
        fi
    else
        add_result "FAIL" "Docker service is not running"
    fi
    
    # Ollama
    if pgrep -f "ollama serve" > /dev/null || service_running ollama; then
        add_result "PASS" "Ollama service is running"
        
        # Test Ollama API
        if ollama list > /dev/null 2>&1; then
            add_result "PASS" "Ollama API is responsive"
            
            # Check for required models
            if ollama list | grep -q "nomic-embed-text"; then
                add_result "PASS" "Required Ollama model (nomic-embed-text) is installed"
            else
                add_result "WARN" "Required Ollama model (nomic-embed-text) not found"
            fi
        else
            add_result "FAIL" "Ollama API is not responsive"
        fi
    else
        add_result "FAIL" "Ollama service is not running"
    fi
}

# Check CI Server installation
check_ci_server() {
    log_info "Checking CI Server installation..."
    
    if [[ -d "$CI_SERVER_DIR" ]]; then
        add_result "PASS" "CI Server directory exists: $CI_SERVER_DIR"
        
        cd "$CI_SERVER_DIR"
        
        # Check git repository
        if [[ -d ".git" ]]; then
            add_result "PASS" "Git repository initialized"
            
            local remote_url=$(git remote get-url origin 2>/dev/null || echo "none")
            if [[ "$remote_url" == *"companionintelligence/CI-Server"* ]]; then
                add_result "PASS" "Git remote correctly set to CI-Server repository"
            else
                add_result "WARN" "Git remote: $remote_url"
            fi
        else
            add_result "FAIL" "Not a git repository"
        fi
        
        # Check package.json files
        if [[ -f "package.json" ]]; then
            add_result "PASS" "Root package.json exists"
        fi
        
        if [[ -f "backend/apps/api/package.json" ]]; then
            add_result "PASS" "Backend API package.json exists"
        else
            add_result "WARN" "Backend API package.json not found"
        fi
        
        if [[ -f "frontend/apps/web/package.json" ]]; then
            add_result "PASS" "Frontend web package.json exists"
        else
            add_result "WARN" "Frontend web package.json not found"
        fi
        
        # Check node_modules
        if [[ -d "node_modules" ]]; then
            add_result "PASS" "Root node_modules installed"
        else
            add_result "WARN" "Root node_modules not found"
        fi
        
        # Check Docker Compose
        if [[ -f "docker-compose.yml" ]]; then
            add_result "PASS" "Docker Compose configuration exists"
        else
            add_result "FAIL" "Docker Compose configuration not found"
        fi
        
        # Check Makefile
        if [[ -f "Makefile" ]]; then
            add_result "PASS" "Makefile exists"
        else
            add_result "WARN" "Makefile not found"
        fi
        
    else
        add_result "FAIL" "CI Server directory not found: $CI_SERVER_DIR"
    fi
}

# Check development environment
check_dev_environment() {
    log_info "Checking development environment..."
    
    # Check hosts file
    if grep -q "dev.companionintelligence.com" /etc/hosts; then
        add_result "PASS" "Development host configured in /etc/hosts"
    else
        add_result "FAIL" "Development host not found in /etc/hosts"
    fi
    
    # Check PM2 processes
    if command_exists pm2; then
        local pm2_list=$(pm2 list 2>/dev/null || echo "")
        if [[ -n "$pm2_list" ]]; then
            local running_processes=$(echo "$pm2_list" | grep -c "online" || echo "0")
            if [[ "$running_processes" -gt 0 ]]; then
                add_result "PASS" "PM2 processes running: $running_processes"
            else
                add_result "WARN" "No PM2 processes are running"
            fi
        else
            add_result "WARN" "PM2 not initialized"
        fi
    fi
    
    # Check Docker containers
    if command_exists docker && docker ps > /dev/null 2>&1; then
        local running_containers=$(docker ps --format "table {{.Names}}" | grep -v NAMES | wc -l)
        if [[ "$running_containers" -gt 0 ]]; then
            add_result "PASS" "Docker containers running: $running_containers"
        else
            add_result "WARN" "No Docker containers are running"
        fi
    fi
}

# Check network connectivity
check_network() {
    log_info "Checking network connectivity..."
    
    # Check if development URL responds
    if curl -s -o /dev/null -w "%{http_code}" http://dev.companionintelligence.com | grep -q "200\|301\|302"; then
        add_result "PASS" "Development URL is accessible"
    else
        add_result "WARN" "Development URL not responding (services may not be started)"
    fi
    
    # Check PostgreSQL port
    if nc -z localhost 5432 2>/dev/null; then
        add_result "PASS" "PostgreSQL port (5432) is accessible"
    else
        add_result "FAIL" "PostgreSQL port (5432) is not accessible"
    fi
    
    # Check Ollama port
    if nc -z localhost 11434 2>/dev/null; then
        add_result "PASS" "Ollama port (11434) is accessible"
    else
        add_result "WARN" "Ollama port (11434) is not accessible"
    fi
}

# Main validation function
main() {
    echo "=== CI Server Development Environment Validation ==="
    echo "🔍 Checking installation in: $CI_SERVER_DIR"
    echo
    
    check_system_dependencies
    check_services
    check_ci_server
    check_dev_environment
    check_network
    
    echo
    echo "=== Validation Results ==="
    
    for result in "${VALIDATION_RESULTS[@]}"; do
        echo "$result"
    done
    
    echo
    if [[ $FAILED_CHECKS -eq 0 ]]; then
        log_success "🎉 All critical checks passed! Development environment is ready."
        echo
        echo "🚀 Next steps:"
        echo "  1. Visit http://dev.companionintelligence.com"
        echo "  2. Check running services: pm2 status"
        echo "  3. View logs: pm2 logs"
        echo "  4. Start Docker tools: docker compose --profile tools up -d"
        exit 0
    else
        log_error "❌ $FAILED_CHECKS critical check(s) failed."
        echo
        echo "🔧 Troubleshooting:"
        echo "  1. Run the setup script again: ./setup-ci-server-dev.sh"
        echo "  2. Check service logs: journalctl -u postgresql -u docker -u ollama"
        echo "  3. Verify permissions: groups (should include 'docker')"
        echo "  4. Check README.md for detailed troubleshooting"
        exit 1
    fi
}

# Show help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat << EOF
CI Server Development Environment Validation

Usage: $0 [CI_SERVER_DIRECTORY]

Arguments:
  CI_SERVER_DIRECTORY    Path to CI Server installation (default: ~/ci-server)

This script validates that the CI Server development environment is properly
configured and all required services are running.

Examples:
  $0                      # Check default location (~/ci-server)
  $0 /opt/ci-server      # Check custom location
  $0 --help              # Show this help

Exit codes:
  0    All checks passed
  1    One or more critical checks failed

EOF
    exit 0
fi

# Run main function
main
