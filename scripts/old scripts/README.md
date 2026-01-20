These scripts are used on an old version of CI OS and should not be considered valid to run without review.

# CI-OS Scripts

This directory contains setup and utility scripts for the CI-OS development environment and the CI Server application.

## Main Setup Scripts

### `setup-ci-server-dev.sh` 🚀
**Primary development environment setup script**

Downloads the CI Server repository and sets up a complete development environment on Ubuntu/Debian systems.

**Usage:**
```bash
./setup-ci-server-dev.sh -u <github-username> -t <github-token> [-d <install-dir>]
```

**Options:**
- `-u, --username`: GitHub username (required)
- `-t, --token`: GitHub personal access token (required)
- `-d, --directory`: Installation directory (default: ~/ci-server)
- `-h, --help`: Show help message

**What it does:**
1. ✅ Installs system dependencies (curl, wget, git, build tools)
2. ✅ Installs Node.js 18.x LTS and npm/yarn
3. ✅ Installs Docker CE with compose
4. ✅ Installs Ollama with required models
5. ✅ Clones CI Server repository with authentication
6. ✅ Sets up PostgreSQL database
7. ✅ Installs project dependencies
8. ✅ Configures development hosts
9. ✅ Starts development services with PM2

**Requirements:**
- Ubuntu 20.04+ or Debian 11+
- sudo privileges
- GitHub personal access token with repo scope

### `ci-server-linux-dev-setup.sh` 🔧
**Lightweight setup for existing CI Server repository**

Sets up the development environment assuming the repository is already cloned.

**Usage:**
```bash
cd /path/to/ci-server
../ci-os/scripts/ci-server-linux-dev-setup.sh
```

### `ci-server-setup-ubuntu-amd.sh` 🖥️
**Hardware-specific setup for AMD systems**

Installs CI Server with AMD GPU support (ROCm) and Docker Desktop.

## Library Scripts

Located in the `lib/` directory, these provide reusable functions:

### `lib/common.sh` 🛠️
Common utilities and logging functions used by all scripts.

**Functions:**
- Logging: `log_info`, `log_success`, `log_warning`, `log_error`
- System checks: `check_sudo`, `command_exists`, `service_running`
- File operations: `backup_file`, `create_directory`
- Network: `wait_for_port`, `get_public_ip`

### `lib/postgresql-setup.sh` 🗄️
PostgreSQL database installation and configuration.

**Functions:**
- `setup_postgresql_database`: Complete PostgreSQL setup
- `check_postgresql_status`: Verify PostgreSQL is running
- `backup_database`: Create database backup
- `restore_database`: Restore from backup

### `lib/docker-setup.sh` 🐳
Docker installation and container management.

**Functions:**
- `install_docker_ce`: Install Docker Community Edition
- `install_docker_desktop`: Install Docker Desktop (Ubuntu)
- `configure_docker_user`: Add user to docker group
- `setup_docker_compose_dev`: Start development containers
- `cleanup_docker`: Clean unused Docker resources

### `lib/nodejs-setup.sh` 📦
Node.js, npm, yarn, and version manager setup.

**Functions:**
- `install_asdf`: Install asdf version manager
- `install_nodejs_direct`: Install Node.js via NodeSource
- `setup_global_npm_packages`: Install global packages (PM2, etc.)
- `setup_workspace_dependencies`: Install all project dependencies

### `lib/ollama-setup.sh` 🤖
Ollama AI model server installation and management.

**Functions:**
- `install_ollama`: Install Ollama server
- `start_ollama_service`: Start Ollama as systemd service
- `pull_ollama_models`: Download required AI models
- `test_ollama`: Verify Ollama functionality

## Other Utility Scripts

### `ubuntu-remove-telemetry.sh` 🔒
Removes Ubuntu telemetry and analytics services.

### `setup-gaming.sh` 🎮
Sets up gaming environment (Steam, MangoHUD, etc.).

### `build-ci-os.sh` 📀
Builds custom CI-OS ISO using Cubic.

### `test-ci-os.sh` 🧪
Tests CI-OS functionality and installations.

### `validate-project.sh` ✅
Validates project structure and dependencies.

## Usage Examples

### Quick CI Server Setup
```bash
# Download and setup everything
./setup-ci-server-dev.sh -u myusername -t ghp_xxxxxxxxxxxxxxxxxxxx

# Or specify custom directory
./setup-ci-server-dev.sh -u myusername -t ghp_xxxxxxxxxxxxxxxxxxxx -d /opt/ci-server
```

### Manual Component Setup
```bash
# Source libraries for manual setup
source scripts/lib/common.sh
source scripts/lib/docker-setup.sh

# Install only Docker
install_docker_ce
configure_docker_user $USER
start_docker_service
```

### Development Workflow
```bash
# Start all services
cd /path/to/ci-server
docker compose --profile local up -d
pm2 start all

# View logs
pm2 logs

# Stop services
pm2 stop all
docker compose down
```

## Environment Configuration

The scripts create several configuration files:

- `.env.local`: Database and development settings
- `~/.asdfrc`: asdf version manager configuration  
- PM2 ecosystem: Process management configuration

## System Requirements

### Minimum Requirements
- **OS**: Ubuntu 20.04+ or Debian 11+
- **Memory**: 4GB RAM (8GB recommended)
- **Storage**: 20GB free space (50GB recommended)
- **Network**: Broadband internet connection

### Recommended Hardware
- **CPU**: 4+ cores
- **Memory**: 16GB RAM
- **Storage**: SSD with 100GB+ free space
- **GPU**: Optional (AMD supported via ROCm)

## Troubleshooting

### Common Issues

**Docker permission denied:**
```bash
# Log out and back in, or run:
newgrp docker
```

**PostgreSQL connection failed:**
```bash
# Check service status
sudo systemctl status postgresql

# Restart PostgreSQL
sudo systemctl restart postgresql
```

**Ollama models not downloading:**
```bash
# Check Ollama status
ollama list

# Manual model pull
ollama pull nomic-embed-text
```

**PM2 processes not starting:**
```bash
# Check PM2 status
pm2 status

# Restart PM2
pm2 restart all
```

### Service URLs

After setup, these services are available:

- **Web Application**: http://dev.companionintelligence.com
- **PostgreSQL**: localhost:5432
- **Ollama**: localhost:11434
- **Docker Services**: Various ports (see docker-compose.yml)

## Contributing

When adding new scripts:

1. Use the common library functions
2. Add proper error handling and logging
3. Make scripts idempotent (safe to run multiple times)
4. Update this README with new functionality
5. Test on clean Ubuntu/Debian systems

## Security Notes

- GitHub tokens are removed from git remotes after cloning
- Database passwords are configurable via environment variables
- All services run with minimal required privileges
- Firewall configuration is recommended for production use

---

For more information, see the main [CI-OS documentation](../docs/).
