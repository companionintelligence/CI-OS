#!/bin/bash
#
# Install Chromium and set as default browser
#
# Installs chromium-browser and configures it as the system default web browser
# for CI OS. Works in chroot (ISO build) and on live systems.
#
# Usage: sudo ./set-chromium-default.sh
# Requirements: Root/sudo access
#
# Also invoked during CI OS setup (customize-chroot.sh, complete-rebranding.sh)
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

# --- Install Chromium (skip if already present) ---
CHROMIUM_ALREADY_INSTALLED=0
if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
    log_info "Chromium is already installed, skipping installation..."
    CHROMIUM_ALREADY_INSTALLED=1
else
    log_info "Installing Chromium..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y chromium-browser || apt-get install -y chromium || {
        log_error "Failed to install Chromium"
        exit 1
    }
    log_success "Chromium installed"
fi

# Determine desktop file (deb: chromium-browser.desktop; snap: chromium_chromium.desktop; flatpak: org.chromium.Chromium.desktop)
CHROMIUM_DESKTOP=""
if [[ -f /usr/share/applications/chromium-browser.desktop ]]; then
    CHROMIUM_DESKTOP="chromium-browser.desktop"
elif [[ -f /var/lib/snapd/desktop/applications/chromium_chromium.desktop ]]; then
    CHROMIUM_DESKTOP="chromium_chromium.desktop"
elif [[ -f /var/lib/flatpak/exports/share/applications/org.chromium.Chromium.desktop ]] || \
     [[ -f "$HOME/.local/share/flatpak/exports/share/applications/org.chromium.Chromium.desktop" ]]; then
    CHROMIUM_DESKTOP="org.chromium.Chromium.desktop"
else
    found=$(find /usr/share/applications /var/lib/snapd/desktop/applications \
        /var/lib/flatpak/exports/share/applications \
        "${HOME:-/root}/.local/share/flatpak/exports/share/applications" \
        -maxdepth 1 -name '*chromium*.desktop' 2>/dev/null | head -1)
    [[ -n "$found" ]] && CHROMIUM_DESKTOP="$(basename "$found")"
fi
[[ -z "$CHROMIUM_DESKTOP" ]] && CHROMIUM_DESKTOP="chromium_chromium.desktop"

# --- Set as default via update-alternatives (x-www-browser, gnome-www-browser) ---
CHROMIUM_BIN=""
for candidate in /usr/bin/chromium-browser /usr/bin/chromium; do
    if [[ -x "$candidate" ]]; then
        CHROMIUM_BIN="$candidate"
        break
    fi
done
if [[ -z "$CHROMIUM_BIN" ]] && command -v chromium-browser &>/dev/null; then
    CHROMIUM_BIN="$(command -v chromium-browser)"
elif [[ -z "$CHROMIUM_BIN" ]] && command -v chromium &>/dev/null; then
    CHROMIUM_BIN="$(command -v chromium)"
fi

if [[ -n "$CHROMIUM_BIN" ]]; then
    # Priority 200 so Chromium wins over Firefox (typically 40)
    update-alternatives --install /usr/bin/x-www-browser x-www-browser "$CHROMIUM_BIN" 200 2>/dev/null || true
    update-alternatives --set x-www-browser "$CHROMIUM_BIN" 2>/dev/null || true
    if update-alternatives --list gnome-www-browser &>/dev/null; then
        update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser "$CHROMIUM_BIN" 200 2>/dev/null || true
        update-alternatives --set gnome-www-browser "$CHROMIUM_BIN" 2>/dev/null || true
    fi
    log_success "Set Chromium as x-www-browser default"
else
    log_warn "Could not find Chromium binary for update-alternatives"
fi

# --- Set MIME defaults for new users (system-wide) via /etc/skel ---
MIMEAPPS_SKEL="/etc/skel/.config/mimeapps.list"
mkdir -p "$(dirname "$MIMEAPPS_SKEL")"

# Remove existing browser entries, then add Chromium defaults
if [[ -f "$MIMEAPPS_SKEL" ]]; then
    sed -i '/^x-scheme-handler\/http=/d;/^x-scheme-handler\/https=/d;/^text\/html=/d' "$MIMEAPPS_SKEL"
fi
# Insert Chromium lines after [Default Applications] (or create section)
if grep -q '^\[Default Applications\]' "$MIMEAPPS_SKEL" 2>/dev/null; then
    # Use awk to insert after the section header
    awk -v d="$CHROMIUM_DESKTOP" '
        /^\[Default Applications\]/ { print; print "x-scheme-handler/http=" d; print "x-scheme-handler/https=" d; print "text/html=" d; next }
        { print }
    ' "$MIMEAPPS_SKEL" > "${MIMEAPPS_SKEL}.new" && mv "${MIMEAPPS_SKEL}.new" "$MIMEAPPS_SKEL"
else
    printf "[Default Applications]\nx-scheme-handler/http=%s\nx-scheme-handler/https=%s\ntext/html=%s\n" "$CHROMIUM_DESKTOP" "$CHROMIUM_DESKTOP" "$CHROMIUM_DESKTOP" >> "$MIMEAPPS_SKEL"
fi

log_success "Set Chromium as default browser for new users (mimeapps.list)"

# --- Runtime validation ---
log_info "Verifying default browser configuration..."
VERIFY_FAILED=0

# Check update-alternatives
if [[ -n "$CHROMIUM_BIN" ]]; then
    ALT_RESULT=$(update-alternatives --query x-www-browser 2>/dev/null | awk '/^Value:/{print $2}' || true)
    if [[ "$ALT_RESULT" == "$CHROMIUM_BIN" ]]; then
        log_success "update-alternatives: x-www-browser → $CHROMIUM_BIN"
    else
        log_warn "update-alternatives x-www-browser may not point to Chromium (got: ${ALT_RESULT:-unset})"
        VERIFY_FAILED=1
    fi
fi

# Check xdg-mime default (best-effort: xdg-mime may not be available in chroot)
if command -v xdg-mime >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    XDG_RESULT=$(sudo -u "${SUDO_USER:-root}" xdg-mime query default x-scheme-handler/https 2>/dev/null || true)
    if echo "$XDG_RESULT" | grep -qi "chromium"; then
        log_success "xdg-mime: x-scheme-handler/https → $XDG_RESULT"
    else
        log_warn "xdg-mime default for https: ${XDG_RESULT:-unset} (expected Chromium; will apply on next login)"
        VERIFY_FAILED=1
    fi
else
    log_info "xdg-mime check skipped (no display or not available)"
fi

# Check /etc/skel mimeapps.list
if grep -q "$CHROMIUM_DESKTOP" "$MIMEAPPS_SKEL" 2>/dev/null; then
    log_success "mimeapps.list: Chromium is default for new users"
else
    log_warn "mimeapps.list does not reference $CHROMIUM_DESKTOP"
    VERIFY_FAILED=1
fi

if [[ $VERIFY_FAILED -eq 0 ]]; then
    log_success "Chromium set as default browser — all checks passed"
else
    log_warn "Chromium configured as default browser (some checks may need reboot/login to confirm)"
fi
