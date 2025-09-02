# CI-OS Linux Distribution

Always reference these instructions first and fallback to search or bash commands only when you encounter unexpected information that does not match the info here.

CI-OS is a custom Ubuntu-based Linux distribution optimized for continuous integration, software development, and gaming workloads. Built using Cubic (Custom Ubuntu ISO Creator), it provides a pre-configured environment with essential development tools, CI/CD platforms, and gaming support.

## Working Effectively

### Bootstrap Environment
- Update system packages: `sudo apt-get update -y`
- Install essential development tools: `sudo apt-get install -y build-essential git curl wget vim nano htop tree unzip zip`
- Install QEMU for VM testing: `sudo apt-get install -y qemu-system-x86`
- NEVER CANCEL: System updates may take 5-15 minutes. Set timeout to 30+ minutes.

### Repository Structure Validation
- Run project validation: `./scripts/validate-project.sh`
- Validates directory structure, file permissions, and git status
- Takes <1 second to complete
- Note: Script contains hardcoded paths - validate output manually

### Cubic ISO Building Process
- Install Cubic: `sudo apt-get install cubic` (Ubuntu/Debian derivatives only)
- Build fails on systems without Cubic - this is expected behavior
- Download Ubuntu 24.04 LTS ISO: Run `./scripts/build-ci-os.sh` 
- NEVER CANCEL: ISO download is ~6GB and may take 10-30 minutes. Set timeout to 60+ minutes.
- The build script only prepares the environment - actual ISO building requires Cubic GUI

### CI Server Development Setup
- Full automated setup: `./scripts/setup-ci-server-dev.sh -u <github-username> -t <github-token>`
- Local setup only: `./scripts/ci-server-linux-dev-setup.sh`
- Interactive setup: `./scripts/ci-setup-launcher.sh`
- NEVER CANCEL: Full setup takes 15-45 minutes including repository clone, dependency installation, and service startup. Set timeout to 60+ minutes.

### Development Environment Validation
- Check system dependencies: `source scripts/lib/common.sh && check_requirements curl git wget`
- Validate Node.js: `source scripts/lib/common.sh && source scripts/lib/nodejs-setup.sh && check_nodejs`
- Test Docker: `source scripts/lib/common.sh && source scripts/lib/docker-setup.sh && test_docker`
- Docker validation takes ~0.5 seconds including container test
- PostgreSQL check: `source scripts/lib/common.sh && source scripts/lib/postgresql-setup.sh && check_postgresql_status`
- PostgreSQL check will show "not running" if service isn't started - this is expected
- These validations complete in <10 seconds each

### Dependency Installation
- Node.js project deps: `source scripts/lib/nodejs-setup.sh && install_project_dependencies <directory>`
- Uses yarn if available, falls back to npm
- Empty project installation takes <1 second
- Real projects may take 2-10 minutes. Set timeout to 15+ minutes.

## Validation Scenarios

### ALWAYS test functionality after making changes:
- Run `./scripts/validate-project.sh` to verify project structure
- Test library functions: `source scripts/lib/common.sh && check_requirements curl git`
- Validate Docker setup: `docker --version && docker compose version`
- Check Node.js environment: `node --version && npm --version && yarn --version`

### Manual Testing Requirements
- Create test project in /tmp: `mkdir -p /tmp/test-validation && cd /tmp/test-validation`
- Test dependency installation with minimal package.json: `echo '{"name": "test-project", "version": "1.0.0"}' > package.json`
- Run installation test: `source /path/to/CI-OS/scripts/lib/common.sh && source /path/to/CI-OS/scripts/lib/nodejs-setup.sh && install_project_dependencies .`
- Installation should complete successfully in <0.3 seconds for empty projects
- Verify script permissions: `ls -la scripts/` - most are executable, some production scripts are not (expected)

### ISO Testing (when ISO exists)
- Run `./scripts/test-ci-os.sh` to validate generated ISO files
- Script checks for ISOs in `iso/output/` directory
- Includes VM testing with VirtualBox if available
- NEVER CANCEL: VM testing can take 10-30 minutes. Set timeout to 45+ minutes.

## Build & Test Commands

### Working Commands (Validated)
- `./scripts/validate-project.sh` - Project structure validation (<1 sec)
- `docker --version` - Check Docker availability (~0.01 sec)
- `node --version` - Check Node.js availability (~0.004 sec)
- Library functions work when properly sourced with common.sh first
- `sudo apt-get update` - System updates (5-15 min, NEVER CANCEL)

### Commands That Require External Dependencies
- `./scripts/build-ci-os.sh` - Requires Cubic installation, fails gracefully
- CI Server setup scripts - Require GitHub credentials and may fail on network issues
- ISO testing - Requires existing ISO files in correct location
- PostgreSQL functions - Require PostgreSQL service to be running

### Timing Expectations
- **NEVER CANCEL** any build or setup operation
- Library function tests: <1 second each
- Docker container test: ~0.5 seconds  
- Empty npm/yarn install: <0.3 seconds
- System package updates: 5-15 minutes (timeout: 30+ minutes)
- CI Server full setup: 15-45 minutes (timeout: 60+ minutes)
- ISO download: 10-30 minutes for ~6GB file (timeout: 60+ minutes)
- VM testing: 10-30 minutes (timeout: 45+ minutes)

## Critical Validation Steps

### Before Making Changes
- Always run `./scripts/validate-project.sh` to understand current state
- Source library files correctly: `source scripts/lib/common.sh && source scripts/lib/<specific-lib>.sh`
- Test basic functionality: `node --version && docker --version`

### After Making Changes  
- Run validation scripts to ensure nothing is broken
- Test any modified library functions with proper sourcing
- Create minimal test scenarios in /tmp directory
- ALWAYS verify file permissions with `ls -la scripts/` - scripts should be executable

## Common Locations

### Key Files
- Main setup scripts: `scripts/` directory
- Library functions: `scripts/lib/` directory  
- Configuration templates: `configs/` directory
- Documentation: `docs/` directory
- Asset storage: `assets/` directory (created during build)
- ISO storage: `iso/base/` and `iso/output/` (created during build)

### Important Scripts
- `scripts/lib/common.sh` - Core utility functions (ALWAYS source first)
- `scripts/lib/nodejs-setup.sh` - Node.js environment setup
- `scripts/lib/docker-setup.sh` - Docker installation and testing  
- `scripts/lib/postgresql-setup.sh` - Database setup functions
- `scripts/validate-project.sh` - Project structure validation
- `scripts/build-ci-os.sh` - ISO build preparation

### Configuration
- Package lists: `configs/packages/package-list.txt`
- CI customization: `configs/scripts/ci-os-customization.sh`
- Desktop settings: `configs/desktop/`

## Known Limitations

- Cubic installation only works on Ubuntu/Debian systems
- PostgreSQL functions require service to be running
- CI Server setup requires valid GitHub credentials
- VM testing requires VirtualBox installation
- Some scripts have hardcoded paths that may need adjustment
- ISO building requires GUI interaction with Cubic - cannot be fully automated via CLI

## Troubleshooting

- If library functions fail, ensure `source scripts/lib/common.sh` is run first
- Missing directories can be created: `mkdir -p iso/base iso/output cubic-project`
- Permission issues: Most scripts are executable, non-executable ones noted in validation output
- Network access: Limited in some environments - external downloads and repository clones may fail
- PostgreSQL "not running" errors are expected when service isn't started
- Script validation shows hardcoded paths - ignore missing file warnings that don't match your environment