#!/usr/bin/env bash
# CI MOTD: disable Ubuntu promo scripts, add the Companion OS header.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/lib/theme-lib.sh"
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

# 00-ci-os-header is the name customize-chroot.sh uses for the ISO; an older run of this script
# left 00-ci-header behind, which would print a second banner.
# The banner is the same text as the one the ISO ships (customize-chroot.sh Step 8), so an image and a re-skinned
# system greet alike. It is words only: the block-letter art that stood here spelled a retired name, and check-repo.sh
# refuses block art in the sources. Keep the two in step by hand.
rm -f "$MOTD_DIR/00-ci-header"
cat > "$MOTD_DIR/00-ci-os-header" <<'EOF'
#!/bin/sh
cat << 'MOTD'

  Companion OS
  Companion Intelligence - https://ci.computer

MOTD
EOF
chmod +x "$MOTD_DIR/00-ci-os-header"

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
