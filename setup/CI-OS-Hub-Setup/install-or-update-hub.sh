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

pin_to_dock() {
    local desktop_id="ci-os-hub-desktop.desktop"
    local target_user

    # Determine the target user: prefer SUDO_USER (i.e. the person who ran sudo).
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        target_user="$SUDO_USER"
    elif [[ -n "${TARGET_USER:-}" ]]; then
        target_user="$TARGET_USER"
    else
        log_warn "Could not determine a non-root desktop user; skipping dock pin."
        log_warn "Re-run as: sudo TARGET_USER=<your-user> $0"
        return 0
    fi

    local uid_num runtime_dir dbus_addr
    uid_num="$(id -u "$target_user" 2>/dev/null || true)"
    runtime_dir="/run/user/${uid_num}"
    dbus_addr="unix:path=${runtime_dir}/bus"

    if [[ ! -S "${runtime_dir}/bus" ]]; then
        log_warn "No active D-Bus session found for $target_user (not logged in to a desktop session?)."
        log_warn "Companion Hub was NOT pinned to the dock. Log in as $target_user and re-run to pin it."
        return 0
    fi

    local env_args=(
        DISPLAY=:0
        XAUTHORITY="/home/$target_user/.Xauthority"
        DBUS_SESSION_BUS_ADDRESS="$dbus_addr"
    )

    local current_favs
    current_favs="$(sudo -u "$target_user" env "${env_args[@]}" \
        gsettings get org.gnome.shell favorite-apps 2>/dev/null || true)"

    if [[ "$current_favs" == *"$desktop_id"* ]]; then
        log_info "Companion Hub is already pinned to the dock for $target_user."
        return 0
    fi

    local favs_clean new_favs
    favs_clean="$(echo "$current_favs" | sed -e "s/^\[//" -e "s/\]$//" -e "s/'//g" -e 's/, /,/g')"

    if [[ -z "$favs_clean" ]]; then
        new_favs="['$desktop_id']"
    else
        # Rebuild the GVariant array, appending the new entry.
        new_favs="['$(echo "$favs_clean" | sed "s/,/', '/g")', '$desktop_id']"
    fi

    sudo -u "$target_user" env "${env_args[@]}" \
        gsettings set org.gnome.shell favorite-apps "$new_favs" 2>/dev/null || {
        log_warn "gsettings call failed; Companion Hub was NOT pinned to the dock."
        return 0
    }

    log_info "Companion Hub pinned to the dock for $target_user."
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
    pin_to_dock

    log_info "Companion Hub install/update complete"
}

main "$@"