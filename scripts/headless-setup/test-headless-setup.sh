#!/bin/bash
# CI OS Headless Setup - Test Script
# Tests the headless setup system components

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

# Test result tracking
pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((PASSED++))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((FAILED++))
}

warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

info() {
    echo -e "ℹ INFO: $1"
}

# Test 1: Check if running as root
test_root() {
    info "Checking root privileges..."
    if [ "$EUID" -eq 0 ]; then
        pass "Running as root"
    else
        fail "Not running as root (required for most tests)"
    fi
}

# Test 2: Check required commands
test_commands() {
    info "Checking required commands..."
    
    local commands=("nmcli" "python3" "iptables" "systemctl")
    local all_found=true
    
    for cmd in "${commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            pass "Command '$cmd' found"
        else
            fail "Command '$cmd' not found"
            all_found=false
        fi
    done
    
    if [ "$all_found" = true ]; then
        pass "All required commands available"
    fi
}

# Test 3: Check Python dependencies
test_python_deps() {
    info "Checking Python dependencies..."
    
    if python3 -c "import flask" 2>/dev/null; then
        pass "Flask module available"
    else
        fail "Flask module not installed (pip3 install flask)"
    fi
}

# Test 4: Check NetworkManager
test_networkmanager() {
    info "Checking NetworkManager..."
    
    if systemctl is-active --quiet NetworkManager; then
        pass "NetworkManager is running"
    else
        fail "NetworkManager is not running"
    fi
    
    if nmcli device status >/dev/null 2>&1; then
        pass "NetworkManager CLI working"
    else
        fail "NetworkManager CLI not working"
    fi
}

# Test 5: Check WiFi interface
test_wifi_interface() {
    info "Checking WiFi interface..."
    
    local wifi_interface=$(nmcli -t -f DEVICE,TYPE device status | grep ":wifi" | head -n 1 | cut -d: -f1)
    
    if [ -n "$wifi_interface" ]; then
        pass "WiFi interface found: $wifi_interface"
    else
        warn "No WiFi interface found (required for hotspot)"
    fi
}

# Test 6: Check installation
test_installation() {
    info "Checking installation..."
    
    if [ -f /usr/local/bin/ci-os-headless-setup.sh ]; then
        pass "Main script installed"
    else
        fail "Main script not installed"
    fi
    
    if [ -f /usr/local/share/ci-os-headless-setup/web/captive-portal.py ]; then
        pass "Web server installed"
    else
        fail "Web server not installed"
    fi
    
    if [ -f /etc/systemd/system/ci-os-headless-setup.service ]; then
        pass "Systemd service installed"
    else
        fail "Systemd service not installed"
    fi
}

# Test 7: Check systemd service
test_systemd_service() {
    info "Checking systemd service..."
    
    if systemctl list-unit-files | grep -q "ci-os-headless-setup.service"; then
        pass "Systemd service registered"
    else
        fail "Systemd service not registered"
    fi
    
    if systemctl is-enabled --quiet ci-os-headless-setup.service 2>/dev/null; then
        pass "Service is enabled"
    else
        warn "Service is not enabled"
    fi
}

# Test 8: Test hotspot creation (dry-run)
test_hotspot_creation() {
    info "Testing hotspot creation (dry-run)..."
    
    # Check if we can create a connection (without activating)
    if nmcli connection show "CI-OS-Setup-Test" >/dev/null 2>&1; then
        nmcli connection delete "CI-OS-Setup-Test" >/dev/null 2>&1
    fi
    
    local wifi_interface=$(nmcli -t -f DEVICE,TYPE device status | grep ":wifi" | head -n 1 | cut -d: -f1)
    
    if [ -z "$wifi_interface" ]; then
        warn "Cannot test hotspot creation - no WiFi interface"
        return
    fi
    
    if nmcli connection add type wifi ifname "$wifi_interface" \
        con-name "CI-OS-Setup-Test" \
        autoconnect no \
        ssid "CI-OS-Setup-Test" \
        mode ap \
        ipv4.method shared \
        ipv4.addresses "10.42.0.1/24" >/dev/null 2>&1; then
        pass "Hotspot connection can be created"
        nmcli connection delete "CI-OS-Setup-Test" >/dev/null 2>&1
    else
        fail "Cannot create hotspot connection"
    fi
}

# Test 9: Check file permissions
test_permissions() {
    info "Checking file permissions..."
    
    if [ -x /usr/local/bin/ci-os-headless-setup.sh ]; then
        pass "Main script is executable"
    else
        fail "Main script is not executable"
    fi
    
    if [ -r /usr/local/share/ci-os-headless-setup/web/captive-portal.py ]; then
        pass "Web server is readable"
    else
        fail "Web server is not readable"
    fi
}

# Test 10: Check log directory
test_log_directory() {
    info "Checking log directory..."
    
    if [ -d /var/log ]; then
        pass "Log directory exists"
    else
        fail "Log directory does not exist"
    fi
    
    if [ -w /var/log ]; then
        pass "Log directory is writable"
    else
        fail "Log directory is not writable"
    fi
}

# Test 11: Validate Python script syntax
test_python_syntax() {
    info "Validating Python script syntax..."
    
    if [ -f /usr/local/share/ci-os-headless-setup/web/captive-portal.py ]; then
        if python3 -m py_compile /usr/local/share/ci-os-headless-setup/web/captive-portal.py 2>/dev/null; then
            pass "Python script syntax is valid"
        else
            fail "Python script has syntax errors"
        fi
    else
        warn "Python script not found, skipping syntax check"
    fi
}

# Test 12: Check dnsmasq
test_dnsmasq() {
    info "Checking dnsmasq..."
    
    if command -v dnsmasq >/dev/null 2>&1; then
        pass "dnsmasq is installed"
    else
        fail "dnsmasq is not installed"
    fi
    
    if [ -d /etc/dnsmasq.d ]; then
        pass "dnsmasq config directory exists"
    else
        fail "dnsmasq config directory missing"
    fi
}

# Main test execution
main() {
    echo "======================================="
    echo "CI OS Headless Setup - Test Suite"
    echo "======================================="
    echo ""
    
    test_root
    echo ""
    
    test_commands
    echo ""
    
    test_python_deps
    echo ""
    
    test_networkmanager
    echo ""
    
    test_wifi_interface
    echo ""
    
    test_installation
    echo ""
    
    test_systemd_service
    echo ""
    
    test_hotspot_creation
    echo ""
    
    test_permissions
    echo ""
    
    test_log_directory
    echo ""
    
    test_python_syntax
    echo ""
    
    test_dnsmasq
    echo ""
    
    echo "======================================="
    echo "Test Results"
    echo "======================================="
    echo -e "${GREEN}Passed: $PASSED${NC}"
    echo -e "${RED}Failed: $FAILED${NC}"
    echo ""
    
    if [ $FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed. Please review the output above.${NC}"
        exit 1
    fi
}

# Run tests
main
