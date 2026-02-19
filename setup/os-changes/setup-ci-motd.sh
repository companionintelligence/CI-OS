#!/bin/bash
#
# CI OS MOTD (Message of the Day) Setup
#
# Disables Ubuntu MOTD news/ads and creates CI OS welcome message.
# Part of the Ubuntu → CI OS rebranding process.
#
# Usage: sudo ./setup-ci-motd.sh
# Requirements: Root/sudo access
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

MOTD_DIR="/etc/update-motd.d"
BACKUP_DIR="/etc/update-motd.d.ubuntu-backup-$(date +%Y%m%d-%H%M%S)"

# Backup existing MOTD
if [[ -d "$MOTD_DIR" ]]; then
    log_info "Backing up existing MOTD..."
    mkdir -p "$BACKUP_DIR"
    cp -r "$MOTD_DIR"/* "$BACKUP_DIR/" 2>/dev/null || true
    log_info "Backup created: $BACKUP_DIR"
fi

# Disable Ubuntu MOTD news and promotional content
log_info "Disabling Ubuntu MOTD news and ads..."

declare -a UBUNTU_MOTD_FILES=(
    "50-motd-news"
    "10-help-text"
    "88-esm-announce"
    "91-contract-ua-esm-status"
    "95-hwe-eol"
)

for file in "${UBUNTU_MOTD_FILES[@]}"; do
    if [[ -f "$MOTD_DIR/$file" ]]; then
        chmod -x "$MOTD_DIR/$file" 2>/dev/null || true
        log_info "Disabled: $file"
    fi
done

# Disable Ubuntu Pro/ESM notifications
if [[ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]]; then
    mv /etc/apt/apt.conf.d/20apt-esm-hook.conf /etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled 2>/dev/null || true
    log_info "Disabled Ubuntu Pro notifications"
fi

# Create CI OS header
log_info "Creating CI OS MOTD header..."
cat > "$MOTD_DIR/00-ci-header" <<'EOF'
#!/bin/bash
#
# CI OS Welcome Message
#

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

echo ""
echo -e "${CYAN}  ██████╗██╗     ██████╗ ███████╗${NC}"
echo -e "${CYAN} ██╔════╝██║    ██╔═══██╗██╔════╝${NC}"
echo -e "${CYAN} ██║     ██║    ██║   ██║███████╗${NC}"
echo -e "${CYAN} ██║     ██║    ██║   ██║╚════██║${NC}"
echo -e "${CYAN} ╚██████╗██║    ╚██████╔╝███████║${NC}"
echo -e "${CYAN}  ╚═════╝╚═╝     ╚═════╝ ╚══════╝${NC}"
echo ""
echo -e " ${GREEN}Companion Intelligence Operating System${NC}"
echo " Uncloud Modern Life"
echo ""
EOF

chmod +x "$MOTD_DIR/00-ci-header"
log_success "CI OS MOTD header created"

# Keep useful system info scripts
declare -a KEEP_MOTD_FILES=(
    "00-header"  # Will be replaced by our 00-ci-header
    "50-landscape-sysinfo"
    "90-updates-available"
    "91-release-upgrade"
)

# Optional: Create simplified system info
cat > "$MOTD_DIR/10-ci-sysinfo" <<'EOF'
#!/bin/bash
#
# CI OS System Information
#

echo "System information as of $(date)"
echo ""

# Memory
free -h | awk 'NR==2 {printf "  Memory usage: %s / %s (%.0f%%)\n", $3, $2, ($3/$2)*100}'

# Disk
df -h / | awk 'NR==2 {printf "  Disk usage:   %s / %s (%s)\n", $3, $2, $5}'

# Load
uptime | awk -F'load average:' '{print "  Load average: " $2}'

echo ""
EOF

chmod +x "$MOTD_DIR/10-ci-sysinfo"
log_success "CI OS system info created"

# Disable motd-news service if it exists
if systemctl list-unit-files | grep -q motd-news; then
    systemctl disable motd-news.timer 2>/dev/null || true
    systemctl stop motd-news.timer 2>/dev/null || true
    log_info "Disabled motd-news.timer service"
fi

# Disable Ubuntu Advantage messaging
if [[ -f /etc/default/motd-news ]]; then
    echo 'ENABLED=0' > /etc/default/motd-news
    log_info "Disabled MOTD news in /etc/default/motd-news"
fi

log_success "CI OS MOTD setup complete"
log_info ""
log_info "Test the new MOTD with:"
log_info "  run-parts /etc/update-motd.d/"
log_info ""
log_info "Or open a new login session to see it automatically"
