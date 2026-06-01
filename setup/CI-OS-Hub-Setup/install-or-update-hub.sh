#!/usr/bin/env bash

set -euo pipefail

HUB_PAGE_URL="${HUB_PAGE_URL:-https://ci.computer/hub}"
DL_BASE_URL="${DL_BASE_URL:-https://dl.ci.computer}"
FALLBACK_VERSION="${FALLBACK_VERSION:-v0.1.4}"
TMP_DEB=""

log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

cleanup() {
    if [[ -n "$TMP_DEB" && -f "$TMP_DEB" ]]; then
        rm -f "$TMP_DEB"
    fi
}

require_root() {
    if [[ ${EUID:-0} -ne 0 ]]; then
        log_error "Run this script as root: sudo $0"
        exit 1
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command not found: $1"
        exit 1
    fi
}

detect_arch() {
    local arch

    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64)
            DEB_ARCH="amd64"
            DL_ARCH="x64"
            ARCH_REGEX='(amd64|x64)'
            ;;
        arm64)
            DEB_ARCH="arm64"
            DL_ARCH="arm"
            ARCH_REGEX='(arm64|aarch64|arm)'
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

fetch_latest_version() {
    local latest_json version_tag

    version_tag="$FALLBACK_VERSION"
    latest_json="$(curl -fsSL --connect-timeout 20 --retry 2 "$DL_BASE_URL/latest.json" 2>/dev/null || true)"
    if [[ -n "$latest_json" ]]; then
        version_tag="$(echo "$latest_json" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)"/\1/' || true)"
    fi

    if [[ -z "$version_tag" ]]; then
        version_tag="$FALLBACK_VERSION"
    fi

    printf '%s\n' "$version_tag"
}

resolve_from_manifest() {
    local version_tag="$1"
    local manifest_json manifest_url

    manifest_url="$DL_BASE_URL/$version_tag/manifest.json"
    manifest_json="$(curl -fsSL --connect-timeout 20 --retry 2 "$manifest_url" 2>/dev/null || true)"
    if [[ -z "$manifest_json" ]]; then
        return 1
    fi

    echo "$manifest_json" | tr '\n' ' ' | grep -Eo 'https?://[^"[:space:]]+\.deb' | grep -Ei "$ARCH_REGEX" | head -n 1
}

resolve_from_hub_page() {
    local page_html

    page_html="$(curl -fsSL --connect-timeout 20 --retry 2 "$HUB_PAGE_URL" 2>/dev/null || true)"
    if [[ -z "$page_html" ]]; then
        return 1
    fi

    echo "$page_html" | tr '\n' ' ' | grep -Eo 'https?://[^"[:space:]]+\.deb' | grep -Ei "$ARCH_REGEX" | head -n 1
}

resolve_download_url() {
    local version_tag="$1"
    local clean_version resolved_url

    resolved_url="$(resolve_from_manifest "$version_tag" || true)"
    if [[ -n "$resolved_url" ]]; then
        printf '%s\n' "$resolved_url"
        return 0
    fi

    resolved_url="$(resolve_from_hub_page || true)"
    if [[ -n "$resolved_url" ]]; then
        printf '%s\n' "$resolved_url"
        return 0
    fi

    clean_version="${version_tag#v}"
    printf '%s\n' "$DL_BASE_URL/$version_tag/linux/deb/$DL_ARCH/Companion%20Hub_${clean_version}_${DEB_ARCH}.deb"
}

download_package() {
    local url="$1"
    local version_tag="$2"
    local clean_version

    clean_version="${version_tag#v}"
    TMP_DEB="/tmp/Companion_Hub_${clean_version}_${DEB_ARCH}.deb"
    log_info "Downloading Companion Hub from $url"
    curl -fL --connect-timeout 90 --retry 3 -o "$TMP_DEB" "$url"
}

install_package() {
    log_info "Installing Companion Hub package from $TMP_DEB"

    if apt-get install --reinstall -y "$TMP_DEB"; then
        return 0
    fi

    log_warn "apt local install failed, retrying with dpkg + apt fixup"
    dpkg -i "$TMP_DEB" || true
    apt-get install -f -y
    dpkg -i "$TMP_DEB"
}

main() {
    local version_tag hub_url

    require_root
    require_command curl
    require_command dpkg
    require_command apt-get
    trap cleanup EXIT

    detect_arch
    version_tag="$(fetch_latest_version)"
    hub_url="$(resolve_download_url "$version_tag")"

    log_info "Resolved latest Companion Hub package for $DEB_ARCH"
    log_info "Version hint: $version_tag"

    download_package "$hub_url" "$version_tag"
    install_package

    log_info "Companion Hub install/update complete"
}

main "$@"