# Testing Guide for Headless Wi-Fi Provisioning System

This document provides comprehensive testing procedures for the CI-OS headless Wi-Fi provisioning system.

## Test Environment Setup

### Hardware Requirements

- Ubuntu 24.04 LTS device with Wi-Fi capability
- Test client devices:
  - iPhone or iPad (iOS 14+)
  - Android phone or tablet (Android 10+)
  - Windows 10/11 laptop
  - macOS device (optional)
- Wi-Fi router for testing network connectivity

### Software Requirements

```bash
# Install testing dependencies
sudo apt install -y python3-pytest python3-mock network-manager wireless-tools

# Install Python testing libraries
pip3 install pytest pytest-cov pytest-mock requests
```

## Unit Testing

### Running Unit Tests

```bash
cd /path/to/CI-OS/scripts/provisioning

# Run all tests
python3 -m pytest test_provisioning.py -v

# Run with coverage report
python3 -m pytest test_provisioning.py --cov=provisioning_manager --cov-report=html

# Run specific test class
python3 -m pytest test_provisioning.py::TestProvisioningManager -v

# Run specific test
python3 -m pytest test_provisioning.py::TestProvisioningManager::test_initialization -v
```

### Test Coverage Goals

- **Provisioning Manager**: >80% code coverage
- **Captive Portal**: >75% code coverage
- **State Transitions**: 100% coverage of all FSM states
- **Error Handling**: 100% coverage of error paths

## Integration Testing

### Test Scenario 1: First-Time Device Setup

**Objective**: Verify complete setup flow from power-on to cloud pairing.

**Steps**:

1. **Prepare Device**:
   ```bash
   # Remove any existing Wi-Fi credentials
   sudo rm -f /etc/NetworkManager/system-connections/*
   sudo rm -f /etc/provisioning/config.json
   
   # Restart provisioning service
   sudo systemctl restart device-provisioning.service
   ```

2. **Verify Hotspot Creation**:
   ```bash
   # Wait 30-45 seconds, then check
   nmcli device status
   nmcli connection show
   
   # Should show Hotspot active on wlan0
   ```

3. **Connect Client Device**:
   - On test phone, open Wi-Fi settings
   - Look for "Setup-Device-XXXX"
   - Connect to network
   - Password: `ci-os-setup` (if enabled)

4. **Verify Captive Portal**:
   - Portal should open automatically
   - If not, manually navigate to `http://10.42.0.1/config`
   - Verify network list is populated

5. **Submit Configuration**:
   - Select a test Wi-Fi network
   - Enter Wi-Fi password
   - Enter a test pairing token (6 characters)
   - Click "Connect Device"

6. **Verify Connection**:
   ```bash
   # On device, monitor logs
   journalctl -u device-provisioning.service -f
   
   # Should show:
   # - Hotspot deactivation
   # - Wi-Fi connection attempt
   # - Successful connection
   # - Internet check
   # - Cloud pairing (if backend available)
   ```

7. **Verify State**:
   ```bash
   # Check network connection
   nmcli device status
   ip addr show wlan0
   
   # Should show wlan0 connected with IP address
   ```

**Expected Results**:
- ✅ Hotspot created within 45 seconds
- ✅ Captive portal opens automatically
- ✅ Network list populated correctly
- ✅ Configuration submitted successfully
- ✅ Device connects to Wi-Fi
- ✅ Internet connectivity verified
- ✅ Cloud pairing attempted (if backend available)

### Test Scenario 2: Network Password Change Recovery

**Objective**: Verify device auto-recovers when Wi-Fi password changes.

**Steps**:

1. **Configure Device** (use Scenario 1)

2. **Change Wi-Fi Password** on router

3. **Observe Device Behavior**:
   ```bash
   journalctl -u device-provisioning.service -f
   
   # Should show:
   # - Connection failure
   # - Retry attempts
   # - Transition to HOTSPOT_MODE
   ```

4. **Verify Hotspot Reactivation**:
   - Hotspot should appear within 60 seconds
   - Connect and reconfigure with new password

**Expected Results**:
- ✅ Device detects connection failure
- ✅ Automatically reverts to hotspot mode
- ✅ User can reconfigure with new credentials

### Test Scenario 3: Ethernet Priority

**Objective**: Verify Ethernet connection takes priority over Wi-Fi.

**Steps**:

1. **Configure Wi-Fi** (use Scenario 1)

2. **Connect Ethernet Cable**:
   ```bash
   # Monitor connection changes
   journalctl -u device-provisioning.service -f
   ```

3. **Verify Ethernet Active**:
   ```bash
   nmcli device status
   ip route
   
   # Default route should use Ethernet interface
   ```

4. **Disconnect Ethernet**:
   - Should fall back to Wi-Fi automatically

**Expected Results**:
- ✅ Ethernet connection detected
- ✅ Ethernet used as primary connection
- ✅ Automatic fallback to Wi-Fi when Ethernet removed

### Test Scenario 4: Multiple Device Setup

**Objective**: Verify multiple devices can be configured simultaneously.

**Steps**:

1. **Power On 2-3 Devices** simultaneously

2. **Verify Unique SSIDs**:
   - Each device should have unique SSID (different MAC suffix)
   - Example: `Setup-Device-A1B2`, `Setup-Device-C3D4`

3. **Configure Devices** independently

**Expected Results**:
- ✅ Each device creates unique hotspot
- ✅ No interference between devices
- ✅ All devices can be configured simultaneously

## Captive Portal Detection Testing

### iOS Testing

**Devices**: iPhone, iPad running iOS 14+

**Test Steps**:

1. Connect to device hotspot
2. Observe automatic portal launch
3. Verify portal appearance (not Safari)
4. Test form submission
5. Verify portal closes after configuration

**Check**:
```bash
# On device, check for iOS CPD probes
journalctl -u captive-portal.service -f | grep hotspot-detect
```

**Expected Results**:
- ✅ Portal opens automatically (no manual navigation)
- ✅ Appears in Captive Network Assistant (not Safari)
- ✅ Portal closes after successful configuration

### Android Testing

**Devices**: Android 10+ phones/tablets

**Test Steps**:

1. Connect to device hotspot
2. Tap notification: "Sign in to network"
3. Verify portal loads correctly
4. Test form submission

**Check**:
```bash
# Check for Android CPD probes
journalctl -u captive-portal.service -f | grep generate_204
```

**Expected Results**:
- ✅ Notification appears: "Sign in to network"
- ✅ Portal opens in captive browser
- ✅ Form submission works correctly

### Windows Testing

**Devices**: Windows 10/11 laptops

**Test Steps**:

1. Connect to device hotspot
2. Observe automatic browser launch
3. Verify portal loads
4. Test configuration

**Check**:
```bash
# Check for Windows CPD probes
journalctl -u captive-portal.service -f | grep connecttest
```

**Expected Results**:
- ✅ Browser opens automatically
- ✅ Portal loads correctly
- ✅ Configuration works

## Network Scanning Testing

### Test Scenario: Network Scan Caching

**Objective**: Verify scan results are cached and served correctly.

**Steps**:

1. **Activate Hotspot**:
   ```bash
   sudo systemctl restart device-provisioning.service
   ```

2. **Wait for Hotspot** (45 seconds)

3. **Check Scan Cache**:
   ```bash
   cat /run/provisioning/scan_results.json
   
   # Should contain list of networks with:
   # - SSID
   # - Signal strength
   # - Security type
   ```

4. **Connect to Portal**:
   - Verify network list matches cache
   - Verify signal strength indicators
   - Verify security icons (🔒 vs 📡)

**Expected Results**:
- ✅ Scan performed before AP activation
- ✅ Results cached to JSON file
- ✅ Portal displays cached results
- ✅ Signal strength accurate

### Test Scenario: Network Rescan

**Objective**: Verify rescan functionality works correctly.

**Steps**:

1. **Connect to Portal**

2. **Click "Rescan Networks"**:
   - Should show warning about disconnection
   - Confirm action

3. **Observe Behavior**:
   ```bash
   journalctl -u device-provisioning.service -f
   
   # Should show:
   # - AP deactivation
   # - Network scan
   # - AP reactivation
   ```

4. **Reconnect to Hotspot**:
   - New scan results should appear

**Expected Results**:
- ✅ Warning displayed before rescan
- ✅ AP tears down correctly
- ✅ Scan completes successfully
- ✅ AP reactivates
- ✅ Updated network list available

## API Endpoint Testing

### Test /api/networks

```bash
# Connect to hotspot, then:
curl http://10.42.0.1/api/networks

# Should return JSON array:
# [
#   {"ssid": "Network1", "strength": 85, "security": "WPA2"},
#   {"ssid": "Network2", "strength": 60, "security": "Open"}
# ]
```

### Test /api/configure

```bash
curl -X POST http://10.42.0.1/api/configure \
  -H "Content-Type: application/json" \
  -d '{
    "ssid": "TestNetwork",
    "password": "testpass123",
    "token": "ABC123"
  }'

# Should return:
# {"status": "success"}
```

### Test Invalid Input

```bash
# Missing SSID
curl -X POST http://10.42.0.1/api/configure \
  -H "Content-Type: application/json" \
  -d '{"password": "test", "token": "ABC123"}'

# Should return 400 error

# Invalid token (not 6 characters)
curl -X POST http://10.42.0.1/api/configure \
  -H "Content-Type: application/json" \
  -d '{"ssid": "Test", "password": "test", "token": "AB"}'

# Should return 400 error
```

## Performance Testing

### Boot Time Measurement

```bash
# Reboot device and measure time to hotspot
sudo reboot

# After reboot, on another machine:
time_start=$(date +%s)

# Wait for hotspot to appear
while ! nmcli device wifi list | grep -q "Setup-Device"; do
  sleep 1
done

time_end=$(date +%s)
boot_time=$((time_end - time_start))

echo "Boot to hotspot: ${boot_time} seconds"

# Target: < 45 seconds
```

### Configuration Time Measurement

```bash
# Measure total configuration time
# (From form submission to internet connectivity)

# Target: < 3 minutes
```

### Memory Usage Monitoring

```bash
# Check memory usage
ps aux | grep provisioning_manager.py
ps aux | grep captive_portal.py

# Provisioning manager should use < 100 MB
# Captive portal should use < 50 MB
```

## Security Testing

### Test 1: Firewall Rules

```bash
# From external network, attempt to access services
nmap -p 22,80,443 10.42.0.1

# Only port 80 should be accessible from 10.42.0.0/24
```

### Test 2: DNS Hijacking

```bash
# From connected client:
nslookup google.com 10.42.0.1

# Should return 10.42.0.1 (not actual Google IP)
```

### Test 3: HTTPS API Communication

```bash
# If cloud API is HTTPS, verify TLS
openssl s_client -connect api.example.com:443 -showcerts

# Verify TLS 1.2+ and strong ciphers
```

## Stress Testing

### Test: Rapid Reconnections

```bash
# Connect and disconnect repeatedly
for i in {1..10}; do
  nmcli device wifi connect "Setup-Device-XXXX" password "ci-os-setup"
  sleep 5
  nmcli connection down "Setup-Device-XXXX"
  sleep 5
done

# System should remain stable
```

### Test: Multiple Simultaneous Clients

- Connect 5-10 devices to hotspot simultaneously
- All should receive captive portal
- All should be able to view network list
- Submit configurations from multiple clients

**Expected**: System handles concurrent connections gracefully

## Failure Mode Testing

### Test: Invalid Wi-Fi Password

1. Submit configuration with wrong password
2. Verify device attempts connection
3. Verify failure is logged
4. Verify device returns to hotspot mode
5. Verify user can retry

### Test: Unreachable Network

1. Configure device with network SSID that doesn't exist
2. Verify connection timeout
3. Verify fallback to hotspot mode

### Test: Power Loss During Configuration

1. Submit configuration
2. Power off device during Wi-Fi connection
3. Power on device
4. Verify device enters hotspot mode
5. Verify configuration can be retried

### Test: Cloud API Failure

1. Configure device with valid Wi-Fi but invalid token
2. Verify Wi-Fi connection succeeds
3. Verify cloud pairing fails gracefully
4. Verify device remains operational (with limited functionality)

## Regression Testing

After each code change, run:

```bash
# 1. Unit tests
python3 -m pytest test_provisioning.py -v

# 2. Basic integration test
./scripts/provisioning/integration-test.sh

# 3. Captive portal detection (iOS + Android)

# 4. Network scan caching

# 5. Ethernet fallback
```

## Test Reporting

### Success Criteria

A test passes if:
- ✅ All expected results achieved
- ✅ No errors in logs
- ✅ Performance within targets
- ✅ Security requirements met

### Bug Reporting Format

```markdown
**Bug Title**: [Component] Brief description

**Severity**: Critical / High / Medium / Low

**Steps to Reproduce**:
1. Step one
2. Step two
3. Step three

**Expected Result**:
What should happen

**Actual Result**:
What actually happened

**Logs**:
```
Relevant log excerpts
```

**Environment**:
- OS: Ubuntu 24.04 LTS
- Device: [Hardware model]
- Client: [iOS 15.1 / Android 12 / Windows 11]
```

## Continuous Integration

### Automated Testing Pipeline

```yaml
# .github/workflows/test-provisioning.yml
name: Test Provisioning System

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      
      - name: Install dependencies
        run: |
          sudo apt update
          sudo apt install -y python3-pytest python3-mock
          
      - name: Run unit tests
        run: |
          cd scripts/provisioning
          python3 -m pytest test_provisioning.py -v --cov
      
      - name: Upload coverage
        uses: codecov/codecov-action@v3
```

## Test Checklist

Before releasing, verify:

- [ ] All unit tests pass
- [ ] Integration test (first-time setup) succeeds
- [ ] Captive portal works on iOS
- [ ] Captive portal works on Android
- [ ] Captive portal works on Windows
- [ ] Ethernet fallback works
- [ ] Network password change recovery works
- [ ] Network scan caching works
- [ ] Rescan functionality works
- [ ] Invalid input handled gracefully
- [ ] Boot time < 45 seconds
- [ ] Memory usage < 150 MB total
- [ ] Security tests pass
- [ ] Documentation updated
- [ ] No critical bugs

---

**Version**: 1.0.0  
**Last Updated**: 2026-01-17  
**Maintainer**: CI-OS Team
