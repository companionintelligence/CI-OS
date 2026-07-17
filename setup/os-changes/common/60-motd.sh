#!/usr/bin/env bash
# CI MOTD: disable Ubuntu promo scripts, add CI header.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root

MOTD_DIR="/etc/update-motd.d"
BACKUP_DIR="/etc/update-motd.d.ubuntu-backup-$(date +%Y%m%d-%H%M%S)"

if [[ -d "$MOTD_DIR" ]]; then
  mkdir -p "$BACKUP_DIR"
  cp -r "$MOTD_DIR"/* "$BACKUP_DIR/" 2>/dev/null || true
  log_info "MOTD backup: $BACKUP_DIR"
fi

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

if [[ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]]; then
  mv /etc/apt/apt.conf.d/20apt-esm-hook.conf /etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled 2>/dev/null || true
fi

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

cat > "$MOTD_DIR/10-ci-sysinfo" <<'EOF'
#!/bin/bash
echo "System information as of $(date)"
echo ""
free -h | awk 'NR==2 {printf "  Memory usage: %s / %s (%.0f%%)\n", $3, $2, ($3/$2)*100}'
df -h / | awk 'NR==2 {printf "  Disk usage:   %s / %s (%s)\n", $3, $2, $5}'
uptime | awk -F'load average:' '{print "  Load average: " $2}'
echo ""
EOF
chmod +x "$MOTD_DIR/10-ci-sysinfo"

if systemctl list-unit-files 2>/dev/null | grep -q motd-news; then
  systemctl disable motd-news.timer 2>/dev/null || true
  systemctl stop motd-news.timer 2>/dev/null || true
fi

if [[ -f /etc/default/motd-news ]]; then
  echo 'ENABLED=0' > /etc/default/motd-news
fi

log_success "MOTD configured"
