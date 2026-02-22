#!/usr/bin/env bash
#=============================================================================
# PostgreSQL Setup Library
# 
# Shared functions for setting up PostgreSQL database for CI Server
#=============================================================================

# PostgreSQL configuration
DB_USER="companion_intel"
DB_PASSWORD="comp4nion_1ntel_ftw!"
DB_NAME="companion_intel"
DB_PORT="5432"

# Setup PostgreSQL database
setup_postgresql_database() {
    log_info "Installing and configuring PostgreSQL..."
    
    # Install PostgreSQL
    sudo apt-get install -y postgresql postgresql-contrib
    
    # Start PostgreSQL service
    sudo systemctl start postgresql
    sudo systemctl enable postgresql
    
    # Wait for PostgreSQL to be fully up
    sleep 3
    
    log_info "Creating database user and database..."
    
    # Create the PostgreSQL user and database
    sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'" | grep -q 1 || \
      sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    
    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 || \
      sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
    
    sudo -u postgres psql -c "ALTER USER $DB_USER WITH SUPERUSER;"
    
    log_info "Configuring PostgreSQL for remote access..."
    
    # Get PostgreSQL version
    PG_VERSION=$(sudo -u postgres psql -t -c "SELECT version();" | grep -oP 'PostgreSQL \K[0-9]+')
    PG_CONFIG_DIR="/etc/postgresql/$PG_VERSION/main"
    
    # Modify configs to allow remote access and password authentication
    PG_HBA="$PG_CONFIG_DIR/pg_hba.conf"
    POSTGRESQL_CONF="$PG_CONFIG_DIR/postgresql.conf"
    
    # Backup original files
    sudo cp "$PG_HBA" "$PG_HBA.backup.$(date +%Y%m%d)"
    sudo cp "$POSTGRESQL_CONF" "$POSTGRESQL_CONF.backup.$(date +%Y%m%d)"
    
    # Update authentication methods
    sudo sed -i "s/^local\s\+all\s\+postgres\s\+peer/local all postgres md5/" "$PG_HBA"
    sudo sed -i "s/^local\s\+all\s\+all\s\+peer/local all all md5/" "$PG_HBA"
    sudo sed -i "s/^host\s\+all\s\+all\s\+127.0.0.1\/32\s\+ident/host all all 0.0.0.0\/0 md5/" "$PG_HBA"
    
    # Update connection settings
    sudo sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$POSTGRESQL_CONF"
    sudo sed -i "s/^port = .*/port = $DB_PORT/" "$POSTGRESQL_CONF"
    
    # Restart PostgreSQL
    sudo systemctl restart postgresql
    
    # Test connection
    log_info "Testing database connection..."
    if PGPASSWORD="$DB_PASSWORD" psql -h localhost -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" > /dev/null 2>&1; then
        log_success "Database connection test successful"
    else
        log_error "Database connection test failed"
        return 1
    fi
    
    # Create .env file with database configuration
    create_database_env_file
    
    echo
    log_success "PostgreSQL setup complete:"
    echo "  📊 User:     $DB_USER"
    echo "  🔐 Password: $DB_PASSWORD"
    echo "  🗄️  Database: $DB_NAME"
    echo "  🔌 Port:     $DB_PORT"
}

# Create environment file with database configuration
create_database_env_file() {
    if [[ -n "${INSTALL_DIR:-}" ]]; then
        local env_file="$INSTALL_DIR/.env.local"
        log_info "Creating database environment file: $env_file"
        
        cat > "$env_file" << EOF
# Database Configuration
DATABASE_URL=postgresql://$DB_USER:$DB_PASSWORD@localhost:$DB_PORT/$DB_NAME
DB_HOST=localhost
DB_PORT=$DB_PORT
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME

# Development Settings
NODE_ENV=development
PORT=3000
EOF
        
        log_success "Environment file created"
    fi
}

# Check if PostgreSQL is running
check_postgresql_status() {
    if sudo systemctl is-active --quiet postgresql; then
        log_success "PostgreSQL is running"
        return 0
    else
        log_error "PostgreSQL is not running"
        return 1
    fi
}

# Create database backup
backup_database() {
    local backup_file="${1:-backup_$(date +%Y%m%d_%H%M%S).sql}"
    log_info "Creating database backup: $backup_file"
    
    PGPASSWORD="$DB_PASSWORD" pg_dump -h localhost -U "$DB_USER" -d "$DB_NAME" > "$backup_file"
    
    if [[ $? -eq 0 ]]; then
        log_success "Database backup created: $backup_file"
    else
        log_error "Database backup failed"
        return 1
    fi
}

# Restore database from backup
restore_database() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    log_info "Restoring database from: $backup_file"
    
    PGPASSWORD="$DB_PASSWORD" psql -h localhost -U "$DB_USER" -d "$DB_NAME" < "$backup_file"
    
    if [[ $? -eq 0 ]]; then
        log_success "Database restored successfully"
    else
        log_error "Database restore failed"
        return 1
    fi
}
