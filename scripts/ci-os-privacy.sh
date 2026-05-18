#!/usr/bin/env bash
#=============================================================================
# CI-OS Privacy Controls
#
# Installed command names:
#   ci-os-privacy-status
#   ci-os-privacy-apply
#=============================================================================

set -euo pipefail

APP_NAME="$(basename "$0")"
COMMAND="${1:-status}"

case "$APP_NAME" in
    ci-os-privacy-status) COMMAND="status" ;;
    ci-os-privacy-apply) COMMAND="apply" ;;
esac

if [[ "$APP_NAME" == "ci-os-privacy.sh" || "$APP_NAME" == "ci-os-privacy" ]]; then
    shift || true
fi

TELEMETRY_PACKAGES=(ubuntu-report popularity-contest apport whoopsie apport-symptoms landscape-common)
TELEMETRY_DOMAINS=(metrics.ubuntu.com www.metrics.ubuntu.com popcon.ubuntu.com www.popcon.ubuntu.com)

if [[ "$(id -u)" -eq 0 ]]; then
    DATA_DIR="${CI_OS_DATA_DIR:-/var/lib/ci-os}"
else
    DATA_DIR="${CI_OS_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ci-os}"
fi
STATUS_JSON="$DATA_DIR/privacy-status.json"
mkdir -p "$DATA_DIR"

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    printf '%s' "$value"
}

package_state() {
    local pkg="$1"
    if dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'; then
        echo "installed"
    else
        echo "absent"
    fi
}

package_hold_state() {
    local pkg="$1"
    if apt-mark showhold 2>/dev/null | grep -qx "$pkg"; then
        echo "held"
    else
        echo "not-held"
    fi
}

domain_state() {
    local domain="$1"
    if grep -qE "^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+$domain([[:space:]]|$)" /etc/hosts 2>/dev/null; then
        echo "blocked"
    else
        echo "not-blocked"
    fi
}

write_status_json() {
    local created_at first pkg domain motd_news_state motd_help_state
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    motd_news_state="missing"
    motd_help_state="missing"
    [[ -e /etc/update-motd.d/50-motd-news ]] && motd_news_state="$([[ -x /etc/update-motd.d/50-motd-news ]] && echo enabled || echo disabled)"
    [[ -e /etc/update-motd.d/10-help-text ]] && motd_help_state="$([[ -x /etc/update-motd.d/10-help-text ]] && echo enabled || echo disabled)"

    {
        echo "{"
        echo "  \"created_at\": \"$created_at\","
        echo "  \"packages\": {"
        first=1
        for pkg in "${TELEMETRY_PACKAGES[@]}"; do
            [[ "$first" -eq 0 ]] && echo ","
            first=0
            printf '    "%s": {"state": "%s", "hold": "%s"}' \
                "$(json_escape "$pkg")" "$(package_state "$pkg")" "$(package_hold_state "$pkg")"
        done
        echo
        echo "  },"
        echo "  \"domains\": {"
        first=1
        for domain in "${TELEMETRY_DOMAINS[@]}"; do
            [[ "$first" -eq 0 ]] && echo ","
            first=0
            printf '    "%s": "%s"' "$(json_escape "$domain")" "$(domain_state "$domain")"
        done
        echo
        echo "  },"
        echo "  \"motd\": {"
        echo "    \"50-motd-news\": \"$(json_escape "$motd_news_state")\","
        echo "    \"10-help-text\": \"$(json_escape "$motd_help_state")\""
        echo "  }"
        echo "}"
    } > "$STATUS_JSON"
}

print_status() {
    write_status_json
    echo "Privacy status written to $STATUS_JSON"
    echo
    echo "Packages:"
    local pkg
    for pkg in "${TELEMETRY_PACKAGES[@]}"; do
        printf '  %-22s %-10s %s\n' "$pkg" "$(package_state "$pkg")" "$(package_hold_state "$pkg")"
    done
    echo
    echo "Domains:"
    local domain
    for domain in "${TELEMETRY_DOMAINS[@]}"; do
        printf '  %-28s %s\n' "$domain" "$(domain_state "$domain")"
    done
}

apply_privacy() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Run with sudo: sudo ci-os-privacy-apply" >&2
        exit 1
    fi

    local script_dir remove_script
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    remove_script="$script_dir/lib/remove-telemetry.sh"

    if [[ -f "$remove_script" ]]; then
        bash "$remove_script" --from-setup
    elif [[ -f /usr/lib/ci-os/bootstrap/lib/remove-telemetry.sh ]]; then
        bash /usr/lib/ci-os/bootstrap/lib/remove-telemetry.sh --from-setup
    else
        echo "[*] Applying built-in privacy fallback"
        local domain pkg
        for domain in "${TELEMETRY_DOMAINS[@]}"; do
            if ! grep -qF "127.0.0.1 $domain" /etc/hosts 2>/dev/null; then
                echo "127.0.0.1 $domain" >> /etc/hosts
            fi
        done
        apt-get purge -y "${TELEMETRY_PACKAGES[@]}" >/dev/null 2>&1 || true
        apt-mark hold "${TELEMETRY_PACKAGES[@]}" >/dev/null 2>&1 || true
    fi

    chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
    chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
    write_status_json
    echo "Privacy controls applied. Status: $STATUS_JSON"
}

usage() {
    cat <<'EOF'
Usage:
  ci-os-privacy-status
  sudo ci-os-privacy-apply
  ci-os-privacy.sh status|apply
EOF
}

case "$COMMAND" in
    status|--status)
        print_status
        ;;
    apply|--apply)
        apply_privacy
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage
        exit 2
        ;;
esac
