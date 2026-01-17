#!/usr/bin/env bash
set -euo pipefail

# Get script directory and load libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/postgresql-setup.sh"

log_info "CI Server Linux Development Setup"

# Update package index
log_info "Updating package index..."
sudo apt-get update -y

# Setup PostgreSQL database
setup_postgresql_database

# Setup Node.js and Yarn
log_info "Setting up Node.js and Yarn..."
if ! command_exists npm; then
    log_error "Node.js/npm not found. Please install Node.js first."
    exit 1
fi

npm install -g corepack
yarn install

# Setup hosts file
log_info "Adding development host to /etc/hosts..."
if ! grep -q "dev.companionintelligence.com" /etc/hosts; then
    sudo sh -c 'echo "127.0.0.1 dev.companionintelligence.com" >> /etc/hosts'
    log_success "Added dev.companionintelligence.com to hosts file"
else
    log_info "dev.companionintelligence.com already in hosts file"
fi

# Run database migrations
log_info "Running database migrations..."
if [[ -d "./backend/apps/api" ]]; then
    yarn migrate ./backend/apps/api
else
    log_warning "Backend API directory not found, skipping migrations"
fi

# Install PM2 for process management
log_info "Installing PM2 process manager..."
npm install -g pm2

# Start development servers
log_info "Starting development servers with PM2..."

# Start web frontend
if [[ -d "./frontend/apps/web" ]]; then
    pm2 start yarn --name web --cwd ./frontend/apps/web -- dev
    log_success "Started web frontend"
else
    log_warning "Frontend web directory not found"
fi

# Start API backend
if [[ -d "./backend/apps/api" ]]; then
    pm2 start yarn --name api --cwd ./backend/apps/api -- dev
    log_success "Started API backend"
else
    log_warning "Backend API directory not found"
fi

# Show PM2 status
log_info "Current PM2 processes:"
pm2 status

log_success "🎉 CI Server development setup completed!"
echo
echo "Services:"
echo "  🌐 Web: http://dev.companionintelligence.com"
echo "  📊 Database: PostgreSQL on localhost:$DB_PORT"
echo
echo "Management:"
echo "  📋 View logs: pm2 logs"
echo "  🔄 Restart: pm2 restart all"
echo "  ⏹️  Stop: pm2 stop all"
