#!/bin/bash
#
# CI Server Production Deployment Script
# This script sets up the CI Server for production deployment on Ubuntu Server
#
# Author: CI OS Team
# Version: 1.0.0
# Usage: ./ci-server-production-deploy.sh [options]

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Production configuration
readonly PRODUCTION_USER="${PRODUCTION_USER:-ciserver}"
readonly PRODUCTION_DIR="${PRODUCTION_DIR:-/opt/ci-server}"
readonly DOMAIN_NAME="${DOMAIN_NAME:-companionintelligence.com}"
readonly SSL_EMAIL="${SSL_EMAIL:-admin@companionintelligence.com}"
readonly DB_NAME="${DB_NAME:-ci_server_prod}"
readonly NODEJS_VERSION="${NODEJS_VERSION:-18}"

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--github-username)
                GITHUB_USERNAME="$2"
                shift 2
                ;;
            -t|--github-token)
                GITHUB_TOKEN="$2"
                shift 2
                ;;
            -d|--domain)
                DOMAIN_NAME="$2"
                shift 2
                ;;
            -e|--email)
                SSL_EMAIL="$2"
                shift 2
                ;;
            --db-name)
                DB_NAME="$2"
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
}

show_help() {
    cat << EOF
CI Server Production Deployment Script

Usage: $0 [OPTIONS]

Options:
    -u, --github-username USERNAME  GitHub username for repository access
    -t, --github-token TOKEN        GitHub personal access token
    -d, --domain DOMAIN             Domain name for production deployment
    -e, --email EMAIL               Email for SSL certificate registration
    --db-name DATABASE              Production database name
    -h, --help                      Show this help message

Environment Variables:
    PRODUCTION_USER    Production system user (default: ciserver)
    PRODUCTION_DIR     Installation directory (default: /opt/ci-server)
    DOMAIN_NAME        Production domain (default: companionintelligence.com)
    SSL_EMAIL          SSL certificate email (default: admin@companionintelligence.com)
    DB_NAME            Database name (default: ci_server_prod)
    NODEJS_VERSION     Node.js version (default: 18)

Examples:
    # Basic production deployment
    sudo $0 -u myuser -t ghp_token123 -d mycompany.com -e admin@mycompany.com

    # With custom database name
    sudo $0 -u myuser -t ghp_token123 --db-name my_ci_db
EOF
}

# Validate prerequisites for production deployment
validate_prerequisites() {
    log_info "Validating prerequisites for production deployment..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root for production deployment"
        exit 1
    fi
    
    # Check required parameters
    if [[ -z "${GITHUB_USERNAME:-}" || -z "${GITHUB_TOKEN:-}" ]]; then
        log_error "GitHub username and token are required for production deployment"
        show_help
        exit 1
    fi
    
    # Check Ubuntu version
    if ! grep -q "Ubuntu" /etc/os-release; then
        log_error "This script is designed for Ubuntu Server"
        exit 1
    fi
    
    # Check internet connectivity
    if ! ping -c 1 google.com &> /dev/null; then
        log_error "Internet connectivity is required for production deployment"
        exit 1
    fi
    
    log_success "Prerequisites validation completed"
}

# Create production user and directories
setup_production_user() {
    log_info "Setting up production user and directories..."
    
    # Create production user if it doesn't exist
    if ! id "$PRODUCTION_USER" &>/dev/null; then
        useradd -r -m -s /bin/bash "$PRODUCTION_USER"
        log_success "Created production user: $PRODUCTION_USER"
    else
        log_info "Production user already exists: $PRODUCTION_USER"
    fi
    
    # Create production directory
    mkdir -p "$PRODUCTION_DIR"
    chown "$PRODUCTION_USER:$PRODUCTION_USER" "$PRODUCTION_DIR"
    
    # Add production user to docker group (will be created later)
    usermod -aG sudo "$PRODUCTION_USER"
    
    log_success "Production user and directories setup completed"
}

# Setup firewall for production
setup_production_firewall() {
    log_info "Configuring production firewall..."
    
    # Enable UFW
    ufw --force enable
    
    # Allow SSH
    ufw allow ssh
    
    # Allow HTTP and HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Allow database access (restricted to localhost)
    ufw allow from 127.0.0.1 to any port 5432
    
    # Allow Ollama API (restricted to localhost)
    ufw allow from 127.0.0.1 to any port 11434
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    log_success "Production firewall configured"
}

# Install and configure Nginx for production
setup_nginx() {
    log_info "Setting up Nginx for production..."
    
    # Install Nginx
    apt update
    apt install -y nginx
    
    # Create Nginx configuration for CI Server
    cat > "/etc/nginx/sites-available/$DOMAIN_NAME" << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    
    # Redirect HTTP to HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    
    # SSL configuration (will be updated by Certbot)
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied expired no-cache no-store private must-revalidate auth;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml+rss;
    
    # Proxy to CI Server application
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # API endpoints
    location /api/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Increase timeouts for API calls
        proxy_connect_timeout 120s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
    }
    
    # Static assets
    location /static/ {
        alias $PRODUCTION_DIR/public/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
    
    # Enable the site
    ln -sf "/etc/nginx/sites-available/$DOMAIN_NAME" "/etc/nginx/sites-enabled/"
    
    # Remove default site
    rm -f /etc/nginx/sites-enabled/default
    
    # Test Nginx configuration
    nginx -t
    
    # Start and enable Nginx
    systemctl enable nginx
    systemctl restart nginx
    
    log_success "Nginx configured for production"
}

# Install SSL certificate with Let's Encrypt
setup_ssl() {
    log_info "Setting up SSL certificate with Let's Encrypt..."
    
    # Install Certbot
    apt install -y certbot python3-certbot-nginx
    
    # Obtain SSL certificate
    certbot --nginx -d "$DOMAIN_NAME" -d "www.$DOMAIN_NAME" \
        --non-interactive --agree-tos --email "$SSL_EMAIL" \
        --redirect
    
    # Setup automatic renewal
    systemctl enable certbot.timer
    systemctl start certbot.timer
    
    log_success "SSL certificate configured and auto-renewal enabled"
}

# Create production environment file
create_production_env() {
    log_info "Creating production environment configuration..."
    
    local env_file="$PRODUCTION_DIR/.env.production"
    
    cat > "$env_file" << EOF
# CI Server Production Environment Configuration
NODE_ENV=production
PORT=3000

# Database Configuration
DATABASE_URL=postgresql://ciserver:$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)@localhost:5432/$DB_NAME
DB_HOST=localhost
DB_PORT=5432
DB_NAME=$DB_NAME
DB_USER=ciserver
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

# Application Configuration
APP_URL=https://$DOMAIN_NAME
API_URL=https://$DOMAIN_NAME/api
SECRET_KEY=$(openssl rand -base64 64 | tr -d "=+/" | cut -c1-64)
JWT_SECRET=$(openssl rand -base64 64 | tr -d "=+/" | cut -c1-64)

# Security Configuration
CORS_ORIGIN=https://$DOMAIN_NAME
RATE_LIMIT_WINDOW_MS=900000
RATE_LIMIT_MAX_REQUESTS=100

# Logging Configuration
LOG_LEVEL=info
LOG_FILE=/var/log/ci-server/application.log

# Ollama Configuration
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=llama3.2:3b

# Email Configuration (configure based on your email provider)
SMTP_HOST=
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=
SMTP_PASS=
EMAIL_FROM=noreply@$DOMAIN_NAME

# Monitoring Configuration
HEALTH_CHECK_INTERVAL=30000
METRICS_ENABLED=true
EOF
    
    # Secure the environment file
    chown "$PRODUCTION_USER:$PRODUCTION_USER" "$env_file"
    chmod 600 "$env_file"
    
    log_success "Production environment file created"
}

# Create systemd service for production
create_systemd_service() {
    log_info "Creating systemd service for CI Server..."
    
    cat > /etc/systemd/system/ci-server.service << EOF
[Unit]
Description=CI Server Production
Documentation=https://github.com/companionintelligence/CI-Server
After=network.target postgresql.service

[Service]
Type=simple
User=$PRODUCTION_USER
WorkingDirectory=$PRODUCTION_DIR
Environment=NODE_ENV=production
EnvironmentFile=$PRODUCTION_DIR/.env.production
ExecStart=/usr/bin/node server.js
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=ci-server

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$PRODUCTION_DIR /var/log/ci-server

# Resource limits
LimitNOFILE=65536
LimitNPROC=32768

[Install]
WantedBy=multi-user.target
EOF
    
    # Create log directory
    mkdir -p /var/log/ci-server
    chown "$PRODUCTION_USER:$PRODUCTION_USER" /var/log/ci-server
    
    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable ci-server
    
    log_success "Systemd service created and enabled"
}

# Setup log rotation
setup_log_rotation() {
    log_info "Setting up log rotation..."
    
    cat > /etc/logrotate.d/ci-server << EOF
/var/log/ci-server/*.log {
    daily
    missingok
    rotate 52
    compress
    delaycompress
    notifempty
    copytruncate
    postrotate
        systemctl reload ci-server > /dev/null 2>&1 || true
    endscript
}
EOF
    
    log_success "Log rotation configured"
}

# Deploy CI Server application
deploy_application() {
    log_info "Deploying CI Server application..."
    
    # Switch to production user for deployment
    sudo -u "$PRODUCTION_USER" bash << EOF
        cd "$PRODUCTION_DIR"
        
        # Download CI Server repository
        if [[ ! -d ".git" ]]; then
            git clone "https://$GITHUB_USERNAME:$GITHUB_TOKEN@github.com/companionintelligence/CI-Server.git" .
            # Remove credentials from git config
            git remote set-url origin "https://github.com/companionintelligence/CI-Server.git"
        else
            git fetch origin
            git reset --hard origin/main
        fi
        
        # Install production dependencies
        npm ci --only=production
        
        # Build application if build script exists
        if npm run | grep -q "build"; then
            npm run build
        fi
        
        # Run database migrations if they exist
        if [[ -f "migrate.js" || -f "migrations/index.js" ]]; then
            npm run migrate 2>/dev/null || echo "No migrations to run"
        fi
EOF
    
    log_success "CI Server application deployed"
}

# Start production services
start_production_services() {
    log_info "Starting production services..."
    
    # Start and verify PostgreSQL
    systemctl start postgresql
    systemctl enable postgresql
    
    # Start and verify Docker
    systemctl start docker
    systemctl enable docker
    
    # Add production user to docker group
    usermod -aG docker "$PRODUCTION_USER"
    
    # Start Ollama
    systemctl start ollama
    systemctl enable ollama
    
    # Start CI Server
    systemctl start ci-server
    
    # Check service status
    sleep 5
    if systemctl is-active --quiet ci-server; then
        log_success "CI Server started successfully"
    else
        log_error "Failed to start CI Server"
        systemctl status ci-server
        exit 1
    fi
    
    log_success "All production services started"
}

# Create production monitoring script
create_monitoring_script() {
    log_info "Creating production monitoring script..."
    
    cat > "$PRODUCTION_DIR/monitor.sh" << 'EOF'
#!/bin/bash
# CI Server Production Monitoring Script

check_service() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        echo "✅ $service is running"
    else
        echo "❌ $service is not running"
        return 1
    fi
}

check_url() {
    local url=$1
    local name=$2
    if curl -s -f "$url" > /dev/null; then
        echo "✅ $name is accessible"
    else
        echo "❌ $name is not accessible"
        return 1
    fi
}

echo "=== CI Server Production Health Check ==="
echo "Timestamp: $(date)"
echo

# Check services
check_service postgresql
check_service docker
check_service ollama
check_service ci-server
check_service nginx

echo

# Check URLs
check_url "http://localhost:3000/health" "CI Server Application"
check_url "http://localhost:11434/api/tags" "Ollama API"
check_url "https://$(hostname -f)/health" "Public Website"

echo

# Check disk space
echo "=== Disk Usage ==="
df -h /

echo

# Check memory usage
echo "=== Memory Usage ==="
free -h

echo

# Check system load
echo "=== System Load ==="
uptime

echo
echo "=== Recent CI Server Logs ==="
journalctl -u ci-server --no-pager -n 5 --output=short
EOF
    
    chmod +x "$PRODUCTION_DIR/monitor.sh"
    chown "$PRODUCTION_USER:$PRODUCTION_USER" "$PRODUCTION_DIR/monitor.sh"
    
    log_success "Production monitoring script created"
}

# Main deployment function
main() {
    log_info "Starting CI Server production deployment..."
    
    parse_arguments "$@"
    validate_prerequisites
    
    # Setup system components
    setup_production_user
    setup_production_firewall
    
    # Source library functions for component installation
    source "${SCRIPT_DIR}/lib/postgresql-setup.sh"
    source "${SCRIPT_DIR}/lib/docker-setup.sh"
    source "${SCRIPT_DIR}/lib/nodejs-setup.sh"
    source "${SCRIPT_DIR}/lib/ollama-setup.sh"
    
    # Install core components
    install_nodejs "$NODEJS_VERSION"
    install_docker
    install_postgresql
    install_ollama
    
    # Setup production database
    setup_postgresql_user "ciserver" "$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)"
    create_postgresql_database "ciserver" "$DB_NAME"
    
    # Setup web server and SSL
    setup_nginx
    setup_ssl
    
    # Configure application
    create_production_env
    create_systemd_service
    setup_log_rotation
    
    # Deploy and start
    deploy_application
    start_production_services
    
    # Setup monitoring
    create_monitoring_script
    
    log_success "CI Server production deployment completed successfully!"
    echo
    log_info "Production deployment details:"
    echo "  🌐 Website: https://$DOMAIN_NAME"
    echo "  👤 Production User: $PRODUCTION_USER"
    echo "  📁 Installation Directory: $PRODUCTION_DIR"
    echo "  🗄️ Database: $DB_NAME"
    echo "  📊 Monitor: $PRODUCTION_DIR/monitor.sh"
    echo
    log_info "Next steps:"
    echo "  1. Configure your DNS to point $DOMAIN_NAME to this server"
    echo "  2. Configure email settings in $PRODUCTION_DIR/.env.production"
    echo "  3. Run monitoring script: $PRODUCTION_DIR/monitor.sh"
    echo "  4. Check logs: journalctl -u ci-server -f"
}

# Run main function with all arguments
main "$@"
