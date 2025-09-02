#!/usr/bin/bash
# CI-Server Installation and Setup Script for CI-OS
# Installs and configures CI-Server to run automatically at first login

set -euo pipefail

# Configuration
CI_SERVER_VERSION="latest"
CI_SERVER_DIR="/opt/ci-server"
CI_SERVER_USER="ci-server"
CI_SERVER_CONFIG_DIR="/etc/ci-server"
CI_SERVER_REPO_URL="https://github.com/companionintelligence/CI-Server"

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

# Download and install CI-Server
install_ci_server() {
    log_info "Installing CI-Server..."
    
    # Try to download CI-Server from GitHub releases
    local download_url=""
    local binary_name="ci-server"
    
    # Check if we can access the repository
    if curl -s --fail "$CI_SERVER_REPO_URL" > /dev/null 2>&1; then
        log_info "CI-Server repository is accessible, downloading latest release..."
        
        # Get latest release download URL
        download_url=$(curl -s "https://api.github.com/repos/companionintelligence/CI-Server/releases/latest" \
            | grep "browser_download_url.*linux.*amd64" \
            | cut -d '"' -f 4 \
            | head -n 1)
        
        if [ -n "$download_url" ]; then
            log_info "Downloading CI-Server from: $download_url"
            curl -L -o "$CI_SERVER_DIR/$binary_name" "$download_url"
            chmod +x "$CI_SERVER_DIR/$binary_name"
            log_success "CI-Server binary downloaded successfully"
        else
            log_warning "No suitable release found, creating placeholder"
            create_ci_server_placeholder
        fi
    else
        log_warning "CI-Server repository not accessible yet, creating integration framework"
        create_ci_server_placeholder
    fi
    
    chown "$CI_SERVER_USER:$CI_SERVER_USER" "$CI_SERVER_DIR/$binary_name"
}

# Create CI-Server placeholder that provides the integration framework
create_ci_server_placeholder() {
    local binary_name="ci-server"
    
    log_info "Creating CI-Server integration framework..."
    
    cat > "$CI_SERVER_DIR/$binary_name" << 'EOF'
#!/usr/bin/bash
# CI-Server Integration Framework
# This framework provides the structure for CI-Server integration
# and will automatically use the real CI-Server when available

set -euo pipefail

CI_SERVER_CONFIG="${CI_SERVER_CONFIG:-/etc/ci-server/config.yaml}"
CI_SERVER_LOG_DIR="${CI_SERVER_LOG_DIR:-/var/log/ci-server}"
CI_SERVER_DATA_DIR="${CI_SERVER_DATA_DIR:-/var/lib/ci-server}"

# Check if real CI-Server binary exists
REAL_CI_SERVER="/opt/ci-server/ci-server-bin"
if [ -f "$REAL_CI_SERVER" ] && [ -x "$REAL_CI_SERVER" ]; then
    echo "$(date): Starting CI-Server..." >> "$CI_SERVER_LOG_DIR/ci-server.log"
    exec "$REAL_CI_SERVER" "$@"
fi

# Placeholder mode - provides the expected interface
echo "CI-Server Integration Framework v1.0"
echo "======================================"
echo "Status: Waiting for CI-Server binary"
echo "Config: $CI_SERVER_CONFIG"
echo "Data:   $CI_SERVER_DATA_DIR" 
echo "Logs:   $CI_SERVER_LOG_DIR"
echo ""
echo "CI-Server would be running on http://localhost:8080"
echo "Web interface would be available at http://localhost:8080/ui"
echo ""
echo "To install CI-Server:"
echo "1. Download CI-Server binary as /opt/ci-server/ci-server-bin"  
echo "2. Restart the service: systemctl restart ci-server"
echo ""

# Log that we're running in placeholder mode
echo "$(date): CI-Server running in placeholder mode" >> "$CI_SERVER_LOG_DIR/ci-server.log"

# Keep running to maintain service
while true; do
    sleep 300  # 5 minute intervals
    echo "$(date): CI-Server placeholder heartbeat" >> "$CI_SERVER_LOG_DIR/ci-server.log"
done
EOF
    
    chmod +x "$CI_SERVER_DIR/$binary_name"
    log_success "CI-Server integration framework created"
    log_info "Framework will automatically use real CI-Server when available at /opt/ci-server/ci-server-bin"
}

# Create systemd service for automatic startup
create_systemd_service() {
    log_info "Creating systemd service for CI-Server..."
    
    cat > "/etc/systemd/system/ci-server.service" << EOF
[Unit]
Description=Companion Intelligence Server
Documentation=$CI_SERVER_REPO_URL
After=network.target network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=5

[Service]
Type=simple
User=$CI_SERVER_USER
Group=$CI_SERVER_USER
ExecStart=$CI_SERVER_DIR/ci-server
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
KillMode=mixed
TimeoutStopSec=30

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/ci-server /var/log/ci-server /tmp
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Environment variables
Environment=CI_SERVER_CONFIG=$CI_SERVER_CONFIG_DIR/config.yaml
Environment=CI_SERVER_LOG_DIR=/var/log/ci-server
Environment=CI_SERVER_DATA_DIR=/var/lib/ci-server
Environment=RUST_LOG=info

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ci-server

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log_success "Systemd service created and configured"
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

# Setup first-login autostart for CI-Server
setup_first_login_autostart() {
    log_info "Setting up first-login autostart for CI-Server..."
    
    # Create autostart directory for new users
    mkdir -p "/etc/skel/.config/autostart"
    
    # Create desktop entry that starts CI-Server service on first login
    cat > "/etc/skel/.config/autostart/ci-server-firstrun.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=CI-Server First Run
Comment=Start CI-Server on first login
Exec=/usr/bin/ci-server-firstrun
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
StartupNotify=false
EOF
    
    # Create the first-run script
    cat > "/usr/bin/ci-server-firstrun" << 'EOF'
#!/usr/bin/bash
# CI-Server first login startup script

set -euo pipefail

LOCKFILE="$HOME/.ci-server-started"

# Only run once per user
if [ -f "$LOCKFILE" ]; then
    exit 0
fi

# Start CI-Server system service (with error handling)
if systemctl is-enabled ci-server >/dev/null 2>&1; then
    systemctl --no-block start ci-server.service 2>/dev/null || true
else
    # Enable CI-Server to start automatically on boot
    systemctl --no-block enable ci-server.service 2>/dev/null || true
    systemctl --no-block start ci-server.service 2>/dev/null || true
fi

# Create lockfile to prevent running again
touch "$LOCKFILE"

# Optional: Show notification that CI-Server is starting
if command -v notify-send > /dev/null 2>&1; then
    notify-send "CI-Server" "Starting Companion Intelligence Server..." --icon=dialog-information 2>/dev/null || true
fi

exit 0
EOF
    
    chmod +x "/usr/bin/ci-server-firstrun"
    
    log_success "First-login autostart configured"
    log_info "CI-Server will start automatically when any user logs in for the first time"
}

# Main installation function
main() {
    log_info "CI-Server Installation and Integration Script for CI-OS"
    log_info "====================================================="
    
    # Check if running as root during container build
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root during container build"
        exit 1
    fi
    
    setup_user_and_dirs
    install_ci_server
    create_systemd_service
    create_config
    setup_first_login_autostart
    
    # Enable the service (will start on first login)
    systemctl enable ci-server
    
    log_success "CI-Server integration complete!"
    echo
    log_info "Integration Status:"
    echo "  • Service:     $(systemctl is-enabled ci-server 2>/dev/null || echo 'configured')"
    echo "  • Config:      $CI_SERVER_CONFIG_DIR/config.yaml"
    echo "  • Data:        /var/lib/ci-server"
    echo "  • Logs:        /var/log/ci-server"
    echo "  • Binary:      $CI_SERVER_DIR/ci-server"
    echo
    log_info "CI-Server will start automatically on first user login"
    log_info "Manual control (after installation):"
    echo "  • Start:       systemctl start ci-server"
    echo "  • Stop:        systemctl stop ci-server" 
    echo "  • Restart:     systemctl restart ci-server"
    echo "  • Status:      systemctl status ci-server"
    echo "  • Logs:        journalctl -u ci-server -f"
    echo "  • ujust:       ujust ci-server-status"
}

# Run main function
main "$@"