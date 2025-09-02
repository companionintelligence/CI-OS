#!/usr/bin/bash
# CI-Server Installation and Setup Script
# This script will install and configure CI-Server for CI-OS

set -euo pipefail

# Configuration
CI_SERVER_VERSION="latest"
CI_SERVER_DIR="/opt/ci-server"
CI_SERVER_USER="ci-server"
CI_SERVER_CONFIG_DIR="/etc/ci-server"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Create CI-Server user and directories
setup_user_and_dirs() {
    log_info "Setting up CI-Server user and directories..."
    
    # Create system user for CI-Server
    if ! id "$CI_SERVER_USER" &>/dev/null; then
        useradd --system --home-dir "$CI_SERVER_DIR" --shell /bin/false "$CI_SERVER_USER"
        log_success "Created CI-Server system user"
    else
        log_info "CI-Server user already exists"
    fi
    
    # Create directories
    mkdir -p "$CI_SERVER_DIR"
    mkdir -p "$CI_SERVER_CONFIG_DIR"
    mkdir -p "/var/log/ci-server"
    mkdir -p "/var/lib/ci-server"
    
    # Set permissions
    chown -R "$CI_SERVER_USER:$CI_SERVER_USER" "$CI_SERVER_DIR"
    chown -R "$CI_SERVER_USER:$CI_SERVER_USER" "/var/log/ci-server"
    chown -R "$CI_SERVER_USER:$CI_SERVER_USER" "/var/lib/ci-server"
    
    log_success "Directories and permissions configured"
}

# Install CI-Server binary
install_ci_server() {
    log_info "Installing CI-Server binary..."
    
    # TODO: Replace this placeholder with actual CI-Server installation
    # Once the CI-Server repository is accessible, this should:
    # 1. Download the latest CI-Server binary
    # 2. Install dependencies
    # 3. Set up the configuration
    
    # For now, create a placeholder script
    cat > "$CI_SERVER_DIR/ci-server" << 'EOF'
#!/usr/bin/bash
# CI-Server Placeholder
# This will be replaced with the actual CI-Server binary

echo "CI-Server v1.0 (Placeholder)"
echo "Starting Companion Intelligence Server..."
echo "Server would be running on http://localhost:8080"
echo "Web interface would be available at http://localhost:8080/ui"

# Simulate server running
while true; do
    sleep 60
    echo "$(date): CI-Server heartbeat"
done
EOF
    
    chmod +x "$CI_SERVER_DIR/ci-server"
    chown "$CI_SERVER_USER:$CI_SERVER_USER" "$CI_SERVER_DIR/ci-server"
    
    log_warning "CI-Server placeholder installed"
    log_info "This will be replaced with actual CI-Server binary when available"
}

# Create systemd service
create_systemd_service() {
    log_info "Creating systemd service..."
    
    cat > "/etc/systemd/system/ci-server.service" << EOF
[Unit]
Description=Companion Intelligence Server
Documentation=https://github.com/companionintelligence/CI-Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$CI_SERVER_USER
Group=$CI_SERVER_USER
ExecStart=$CI_SERVER_DIR/ci-server
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
KillMode=mixed
TimeoutStopSec=30

# Security settings
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/ci-server /var/log/ci-server
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Environment
Environment=CI_SERVER_CONFIG=$CI_SERVER_CONFIG_DIR/config.yaml
Environment=CI_SERVER_LOG_DIR=/var/log/ci-server
Environment=CI_SERVER_DATA_DIR=/var/lib/ci-server

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log_success "Systemd service created"
}

# Create default configuration
create_config() {
    log_info "Creating default configuration..."
    
    cat > "$CI_SERVER_CONFIG_DIR/config.yaml" << 'EOF'
# CI-Server Configuration
server:
  host: "0.0.0.0"
  port: 8080
  
logging:
  level: "info"
  file: "/var/log/ci-server/ci-server.log"
  
data:
  directory: "/var/lib/ci-server"
  
security:
  enable_auth: false
  
features:
  web_ui: true
  api: true
  
# Integration settings for CI-OS
ci_os:
  wine_integration: true
  proton_integration: true
  winapps_integration: true
  nvidia_support: auto
EOF
    
    chown "$CI_SERVER_USER:$CI_SERVER_USER" "$CI_SERVER_CONFIG_DIR/config.yaml"
    chmod 600 "$CI_SERVER_CONFIG_DIR/config.yaml"
    
    log_success "Default configuration created"
}

# Setup autostart for desktop users
setup_desktop_autostart() {
    log_info "Setting up desktop autostart..."
    
    # Create autostart entry for new users
    mkdir -p "/etc/skel/.config/autostart"
    
    cat > "/etc/skel/.config/autostart/ci-server.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=CI-Server
Comment=Companion Intelligence Server
Exec=systemctl --user start ci-server
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
EOF
    
    # Create user service template
    mkdir -p "/etc/skel/.config/systemd/user"
    
    cat > "/etc/skel/.config/systemd/user/ci-server.service" << EOF
[Unit]
Description=Companion Intelligence Server (User)
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/systemctl --no-block start ci-server.service
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF
    
    log_success "Desktop autostart configured"
}

# Main installation function
main() {
    log_info "CI-Server Installation Script"
    log_info "=============================="
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    setup_user_and_dirs
    install_ci_server
    create_systemd_service
    create_config
    setup_desktop_autostart
    
    # Enable but don't start yet (will start on first boot)
    systemctl enable ci-server
    
    log_success "CI-Server installation complete!"
    echo
    log_info "Service status: $(systemctl is-enabled ci-server)"
    log_info "Configuration: $CI_SERVER_CONFIG_DIR/config.yaml"
    log_info "Logs: /var/log/ci-server/ci-server.log"
    echo
    log_info "CI-Server will start automatically on first boot"
    log_info "Manual control:"
    echo "  • Start:  systemctl start ci-server"
    echo "  • Stop:   systemctl stop ci-server" 
    echo "  • Status: systemctl status ci-server"
    echo "  • Logs:   journalctl -u ci-server -f"
}

# Run main function
main "$@"