#!/bin/bash
# CI OS Headless Setup - Utility Functions Library

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate WiFi interface exists
validate_wifi_interface() {
    local interface="$1"
    
    if ! nmcli device status | grep -q "$interface"; then
        return 1
    fi
    
    if ! nmcli device status | grep "$interface" | grep -q "wifi"; then
        return 1
    fi
    
    return 0
}

# Get default WiFi interface
get_default_wifi_interface() {
    # Try to find first WiFi interface
    local interface=$(nmcli -t -f DEVICE,TYPE device status | grep ":wifi" | head -n 1 | cut -d: -f1)
    
    if [ -n "$interface" ]; then
        echo "$interface"
        return 0
    fi
    
    # Fallback to wlan0
    echo "wlan0"
    return 1
}

# Check if NetworkManager is running
check_networkmanager() {
    if ! systemctl is-active --quiet NetworkManager; then
        return 1
    fi
    return 0
}

# Get device hostname
get_device_hostname() {
    hostname
}

# Get device ID
get_device_id() {
    if [ -f /etc/machine-id ]; then
        cat /etc/machine-id
    else
        # Fallback to MAC address
        local mac=$(cat /sys/class/net/*/address 2>/dev/null | head -n 1 | tr -d ':')
        echo "${mac:-unknown}"
    fi
}

# Check if port is available
check_port_available() {
    local port="$1"
    
    if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    fi
    
    return 0
}

# Wait for network interface to be ready
wait_for_interface() {
    local interface="$1"
    local max_wait="${2:-30}"
    local count=0
    
    while [ $count -lt $max_wait ]; do
        if nmcli device status | grep -q "$interface"; then
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    return 1
}

# Backup NetworkManager connection
backup_nm_connection() {
    local connection_name="$1"
    local backup_dir="/var/lib/ci-os/nm-backups"
    
    mkdir -p "$backup_dir"
    
    if [ -d "/etc/NetworkManager/system-connections" ]; then
        find /etc/NetworkManager/system-connections -name "${connection_name}*" \
            -exec cp {} "$backup_dir/" \; 2>/dev/null
    fi
}

# Restore NetworkManager connection
restore_nm_connection() {
    local backup_dir="/var/lib/ci-os/nm-backups"
    
    if [ -d "$backup_dir" ]; then
        cp "$backup_dir"/* /etc/NetworkManager/system-connections/ 2>/dev/null || true
        nmcli connection reload
    fi
}

# Export functions
export -f command_exists
export -f validate_wifi_interface
export -f get_default_wifi_interface
export -f check_networkmanager
export -f get_device_hostname
export -f get_device_id
export -f check_port_available
export -f wait_for_interface
export -f backup_nm_connection
export -f restore_nm_connection
