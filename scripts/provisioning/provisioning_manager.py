#!/usr/bin/env python3
"""
CI-OS Device Provisioning Manager
==================================

A comprehensive network provisioning daemon for headless Ubuntu 24.04 LTS devices.
Implements a Finite State Machine (FSM) to manage connectivity modes:
- Ethernet (Priority)
- Wi-Fi Station (Client)
- Hotspot (Access Point) with Captive Portal

The daemon orchestrates network transitions via NetworkManager D-Bus API,
ensuring resilient operation across network failures and configuration changes.

Architecture:
- FSM coordinates state transitions based on connectivity status
- NetworkManager D-Bus API provides programmatic control
- Single-radio handling with sequential scan/AP operation
- Automatic Ethernet priority with Wi-Fi fallback
- Hotspot fail-safe mode for unconfigured devices

Author: CI-OS Team
License: MIT
"""

import os
import sys
import time
import json
import logging
import signal
import subprocess
from enum import Enum, auto
from typing import Optional, Dict, List, Any
from pathlib import Path
import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('/var/log/device-provisioning.log')
    ]
)
logger = logging.getLogger(__name__)

# Constants
SCAN_CACHE_PATH = '/run/provisioning/scan_results.json'
CONFIG_PATH = '/etc/provisioning/config.json'
HOTSPOT_SSID_PREFIX = 'Setup-Device'
HOTSPOT_PASSWORD = 'ci-os-setup'  # WPA2-PSK for security, or None for open network
HOTSPOT_CHANNEL = 6
INTERNET_CHECK_URL = 'http://detectportal.firefox.com/success.txt'
INTERNET_CHECK_TIMEOUT = 10

# NetworkManager D-Bus constants
NM_BUS_NAME = 'org.freedesktop.NetworkManager'
NM_OBJECT_PATH = '/org/freedesktop/NetworkManager'
NM_INTERFACE = 'org.freedesktop.NetworkManager'
NM_DEVICE_INTERFACE = 'org.freedesktop.NetworkManager.Device'
NM_WIRELESS_INTERFACE = 'org.freedesktop.NetworkManager.Device.Wireless'
NM_CONNECTION_ACTIVE_INTERFACE = 'org.freedesktop.NetworkManager.Connection.Active'
NM_SETTINGS_INTERFACE = 'org.freedesktop.NetworkManager.Settings'
NM_SETTINGS_CONNECTION_INTERFACE = 'org.freedesktop.NetworkManager.Settings.Connection'

# NetworkManager enums
NM_DEVICE_TYPE_ETHERNET = 1
NM_DEVICE_TYPE_WIFI = 2
NM_DEVICE_STATE_ACTIVATED = 100
NM_ACTIVE_CONNECTION_STATE_ACTIVATED = 2


class ConnectivityState(Enum):
    """FSM States for device connectivity"""
    BOOT_INIT = auto()
    ETHERNET_VERIFY = auto()
    WIFI_CONNECT = auto()
    INTERNET_CHECK = auto()
    HOTSPOT_MODE = auto()
    PROVISIONING = auto()
    PAIRING = auto()
    OPERATIONAL = auto()


class ProvisioningManager:
    """
    Main provisioning daemon implementing the connectivity FSM.
    
    This class manages the entire lifecycle of device network configuration,
    from initial boot to cloud pairing and operational state.
    """
    
    def __init__(self):
        """Initialize the provisioning manager"""
        self.state = ConnectivityState.BOOT_INIT
        self.running = True
        self.hotspot_active = False
        self.wifi_credentials = None
        self.pairing_token = None
        
        # Initialize D-Bus
        DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SystemBus()
        
        try:
            nm_proxy = self.bus.get_object(NM_BUS_NAME, NM_OBJECT_PATH)
            self.nm = dbus.Interface(nm_proxy, NM_INTERFACE)
            logger.info("NetworkManager D-Bus connection established")
        except dbus.DBusException as e:
            logger.error(f"Failed to connect to NetworkManager: {e}")
            sys.exit(1)
        
        # Ensure runtime directory exists
        os.makedirs(os.path.dirname(SCAN_CACHE_PATH), exist_ok=True)
        
        # Setup signal handlers
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)
        
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully"""
        logger.info(f"Received signal {signum}, shutting down...")
        self.running = False
        if self.hotspot_active:
            self._deactivate_hotspot()
        sys.exit(0)
    
    def run(self):
        """Main FSM loop"""
        logger.info("Starting Device Provisioning Manager")
        
        while self.running:
            try:
                logger.info(f"Current state: {self.state.name}")
                
                if self.state == ConnectivityState.BOOT_INIT:
                    self._handle_boot_init()
                elif self.state == ConnectivityState.ETHERNET_VERIFY:
                    self._handle_ethernet_verify()
                elif self.state == ConnectivityState.WIFI_CONNECT:
                    self._handle_wifi_connect()
                elif self.state == ConnectivityState.INTERNET_CHECK:
                    self._handle_internet_check()
                elif self.state == ConnectivityState.HOTSPOT_MODE:
                    self._handle_hotspot_mode()
                elif self.state == ConnectivityState.PROVISIONING:
                    self._handle_provisioning()
                elif self.state == ConnectivityState.PAIRING:
                    self._handle_pairing()
                elif self.state == ConnectivityState.OPERATIONAL:
                    self._handle_operational()
                
                # Sleep between state checks
                time.sleep(5)
                
            except Exception as e:
                logger.error(f"Error in FSM loop: {e}", exc_info=True)
                time.sleep(10)
    
    def _handle_boot_init(self):
        """Initialize system and verify hardware"""
        logger.info("Initializing system...")
        
        # Verify NetworkManager is running
        try:
            state = self.nm.state()
            logger.info(f"NetworkManager state: {state}")
        except Exception as e:
            logger.error(f"NetworkManager not responding: {e}")
            time.sleep(10)
            return
        
        # Load configuration if exists
        self._load_config()
        
        # Transition to Ethernet verification
        self.state = ConnectivityState.ETHERNET_VERIFY
    
    def _handle_ethernet_verify(self):
        """Check for active wired connection"""
        logger.info("Checking for Ethernet connection...")
        
        try:
            devices = self.nm.GetDevices()
            for device_path in devices:
                device_proxy = self.bus.get_object(NM_BUS_NAME, device_path)
                device_props = dbus.Interface(device_proxy, 'org.freedesktop.DBus.Properties')
                
                device_type = device_props.Get(NM_DEVICE_INTERFACE, 'DeviceType')
                device_state = device_props.Get(NM_DEVICE_INTERFACE, 'State')
                
                if device_type == NM_DEVICE_TYPE_ETHERNET and device_state == NM_DEVICE_STATE_ACTIVATED:
                    logger.info("Ethernet connection active")
                    self.state = ConnectivityState.INTERNET_CHECK
                    return
            
            logger.info("No active Ethernet connection")
            self.state = ConnectivityState.WIFI_CONNECT
            
        except Exception as e:
            logger.error(f"Error checking Ethernet: {e}")
            self.state = ConnectivityState.WIFI_CONNECT
    
    def _handle_wifi_connect(self):
        """Attempt to connect to known Wi-Fi networks"""
        logger.info("Attempting Wi-Fi connection...")
        
        # Check if we have stored credentials
        if self.wifi_credentials:
            logger.info(f"Attempting to connect to {self.wifi_credentials.get('ssid')}")
            if self._connect_to_wifi(self.wifi_credentials):
                self.state = ConnectivityState.INTERNET_CHECK
                return
        
        # Check for existing Wi-Fi connection profiles
        if self._has_wifi_profiles():
            logger.info("Existing Wi-Fi profiles found, attempting connection...")
            # NetworkManager will auto-connect to known networks
            time.sleep(10)  # Wait for auto-connect
            
            # Check if connected
            if self._is_wifi_connected():
                self.state = ConnectivityState.INTERNET_CHECK
                return
        
        logger.info("No Wi-Fi connection available, entering Hotspot mode")
        self.state = ConnectivityState.HOTSPOT_MODE
    
    def _handle_internet_check(self):
        """Validate end-to-end internet connectivity"""
        logger.info("Checking internet connectivity...")
        
        try:
            result = subprocess.run(
                ['curl', '-s', '-m', str(INTERNET_CHECK_TIMEOUT), INTERNET_CHECK_URL],
                capture_output=True,
                text=True,
                timeout=INTERNET_CHECK_TIMEOUT + 5
            )
            
            if result.returncode == 0 and 'success' in result.stdout.lower():
                logger.info("Internet connectivity confirmed")
                
                # If we have a pairing token, proceed to pairing
                if self.pairing_token:
                    self.state = ConnectivityState.PAIRING
                else:
                    self.state = ConnectivityState.OPERATIONAL
                return
            
        except Exception as e:
            logger.warning(f"Internet check failed: {e}")
        
        logger.info("No internet connectivity, reverting to Wi-Fi connect")
        self.state = ConnectivityState.WIFI_CONNECT
    
    def _handle_hotspot_mode(self):
        """Activate Access Point and wait for user configuration"""
        logger.info("Entering Hotspot mode...")
        
        if not self.hotspot_active:
            # Perform Wi-Fi scan before activating AP
            scan_results = self._scan_wifi_networks()
            if scan_results:
                self._save_scan_cache(scan_results)
            
            # Activate hotspot
            if self._activate_hotspot():
                self.hotspot_active = True
                self.state = ConnectivityState.PROVISIONING
            else:
                logger.error("Failed to activate hotspot, retrying...")
                time.sleep(30)
    
    def _handle_provisioning(self):
        """Wait for user to submit configuration via captive portal"""
        logger.info("Waiting for user provisioning input...")
        
        # Check if new credentials were received
        # This would be set by the captive portal web server via IPC
        config = self._load_config()
        
        if config and config.get('new_credentials'):
            self.wifi_credentials = config.get('wifi_credentials')
            self.pairing_token = config.get('pairing_token')
            
            # Clear the new_credentials flag
            config['new_credentials'] = False
            self._save_config(config)
            
            # Deactivate hotspot and attempt connection
            self._deactivate_hotspot()
            self.hotspot_active = False
            self.state = ConnectivityState.WIFI_CONNECT
    
    def _handle_pairing(self):
        """Perform cloud pairing with token"""
        logger.info("Attempting cloud pairing...")
        
        if not self.pairing_token:
            logger.warning("No pairing token available")
            self.state = ConnectivityState.OPERATIONAL
            return
        
        # Attempt cloud pairing
        success = self._perform_cloud_pairing()
        
        if success:
            logger.info("Cloud pairing successful")
            self.pairing_token = None
            self.state = ConnectivityState.OPERATIONAL
        else:
            logger.error("Cloud pairing failed, entering operational mode")
            self.state = ConnectivityState.OPERATIONAL
    
    def _handle_operational(self):
        """Normal operational mode - monitor connectivity"""
        logger.info("Device operational")
        
        # Monitor connectivity and revert to appropriate state if lost
        time.sleep(30)
        
        if not self._check_connectivity():
            logger.warning("Connectivity lost, reverting to verification")
            self.state = ConnectivityState.ETHERNET_VERIFY
    
    # Helper methods
    
    def _get_wifi_device(self) -> Optional[str]:
        """Get the Wi-Fi device path"""
        try:
            devices = self.nm.GetDevices()
            for device_path in devices:
                device_proxy = self.bus.get_object(NM_BUS_NAME, device_path)
                device_props = dbus.Interface(device_proxy, 'org.freedesktop.DBus.Properties')
                device_type = device_props.Get(NM_DEVICE_INTERFACE, 'DeviceType')
                
                if device_type == NM_DEVICE_TYPE_WIFI:
                    return device_path
        except Exception as e:
            logger.error(f"Error getting Wi-Fi device: {e}")
        
        return None
    
    def _scan_wifi_networks(self) -> List[Dict[str, Any]]:
        """Scan for available Wi-Fi networks"""
        logger.info("Scanning for Wi-Fi networks...")
        
        wifi_device = self._get_wifi_device()
        if not wifi_device:
            logger.error("No Wi-Fi device found")
            return []
        
        try:
            device_proxy = self.bus.get_object(NM_BUS_NAME, wifi_device)
            wireless = dbus.Interface(device_proxy, NM_WIRELESS_INTERFACE)
            
            # Request scan
            wireless.RequestScan({})
            time.sleep(5)  # Wait for scan to complete
            
            # Get access points
            aps = wireless.GetAccessPoints()
            
            networks = []
            seen_ssids = set()
            
            for ap_path in aps:
                ap_proxy = self.bus.get_object(NM_BUS_NAME, ap_path)
                ap_props = dbus.Interface(ap_proxy, 'org.freedesktop.DBus.Properties')
                
                ssid_bytes = ap_props.Get('org.freedesktop.NetworkManager.AccessPoint', 'Ssid')
                ssid = bytes(ssid_bytes).decode('utf-8', errors='ignore')
                
                if not ssid or ssid in seen_ssids:
                    continue
                
                seen_ssids.add(ssid)
                
                strength = ap_props.Get('org.freedesktop.NetworkManager.AccessPoint', 'Strength')
                flags = ap_props.Get('org.freedesktop.NetworkManager.AccessPoint', 'Flags')
                wpa_flags = ap_props.Get('org.freedesktop.NetworkManager.AccessPoint', 'WpaFlags')
                rsn_flags = ap_props.Get('org.freedesktop.NetworkManager.AccessPoint', 'RsnFlags')
                
                # Determine security type
                security = 'Open'
                if wpa_flags != 0 or rsn_flags != 0:
                    security = 'WPA/WPA2'
                elif flags & 0x1:  # NM_802_11_AP_FLAGS_PRIVACY
                    security = 'WEP'
                
                networks.append({
                    'ssid': ssid,
                    'strength': int(strength),
                    'security': security
                })
            
            # Sort by signal strength
            networks.sort(key=lambda x: x['strength'], reverse=True)
            
            logger.info(f"Found {len(networks)} networks")
            return networks
            
        except Exception as e:
            logger.error(f"Error scanning Wi-Fi networks: {e}")
            return []
    
    def _save_scan_cache(self, networks: List[Dict[str, Any]]):
        """Save scan results to cache file"""
        try:
            with open(SCAN_CACHE_PATH, 'w') as f:
                json.dump(networks, f, indent=2)
            logger.info(f"Saved {len(networks)} networks to cache")
        except Exception as e:
            logger.error(f"Error saving scan cache: {e}")
    
    def _activate_hotspot(self) -> bool:
        """Activate Wi-Fi hotspot"""
        logger.info("Activating hotspot...")
        
        wifi_device = self._get_wifi_device()
        if not wifi_device:
            logger.error("No Wi-Fi device found")
            return False
        
        try:
            # Get device interface name
            device_proxy = self.bus.get_object(NM_BUS_NAME, wifi_device)
            device_props = dbus.Interface(device_proxy, 'org.freedesktop.DBus.Properties')
            iface = device_props.Get(NM_DEVICE_INTERFACE, 'Interface')
            
            # Get MAC address for unique SSID
            hw_address = device_props.Get(NM_DEVICE_INTERFACE, 'HwAddress')
            mac_suffix = hw_address.replace(':', '')[-4:].upper()
            ssid = f"{HOTSPOT_SSID_PREFIX}-{mac_suffix}"
            
            logger.info(f"Creating hotspot: {ssid}")
            
            # Use nmcli to create hotspot (simpler than D-Bus connection creation)
            cmd = [
                'nmcli', 'device', 'wifi', 'hotspot',
                'ifname', iface,
                'ssid', ssid,
                'band', 'bg',
                'channel', str(HOTSPOT_CHANNEL)
            ]
            
            if HOTSPOT_PASSWORD:
                cmd.extend(['password', HOTSPOT_PASSWORD])
            
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            if result.returncode == 0:
                logger.info("Hotspot activated successfully")
                
                # Copy dnsmasq configuration
                self._setup_captive_dns()
                
                # Restart NetworkManager to apply dnsmasq config
                subprocess.run(['systemctl', 'restart', 'NetworkManager'], check=False)
                time.sleep(5)
                
                return True
            else:
                logger.error(f"Failed to activate hotspot: {result.stderr}")
                return False
                
        except Exception as e:
            logger.error(f"Error activating hotspot: {e}")
            return False
    
    def _deactivate_hotspot(self):
        """Deactivate Wi-Fi hotspot"""
        logger.info("Deactivating hotspot...")
        
        try:
            # Remove captive DNS config
            dns_conf = '/etc/NetworkManager/dnsmasq-shared.d/captive.conf'
            if os.path.exists(dns_conf):
                os.remove(dns_conf)
            
            # Disconnect hotspot
            subprocess.run(['nmcli', 'connection', 'down', 'Hotspot'], check=False)
            
            logger.info("Hotspot deactivated")
            
        except Exception as e:
            logger.error(f"Error deactivating hotspot: {e}")
    
    def _setup_captive_dns(self):
        """Setup DNS hijacking for captive portal"""
        try:
            os.makedirs('/etc/NetworkManager/dnsmasq-shared.d', exist_ok=True)
            
            with open('/etc/NetworkManager/dnsmasq-shared.d/captive.conf', 'w') as f:
                f.write('address=/#/10.42.0.1\n')
                f.write('no-resolv\n')
            
            logger.info("Captive DNS configuration installed")
        except Exception as e:
            logger.error(f"Error setting up captive DNS: {e}")
    
    def _connect_to_wifi(self, credentials: Dict[str, str]) -> bool:
        """Connect to Wi-Fi network with provided credentials"""
        ssid = credentials.get('ssid')
        password = credentials.get('password')
        
        logger.info(f"Connecting to Wi-Fi: {ssid}")
        
        try:
            cmd = ['nmcli', 'device', 'wifi', 'connect', ssid]
            if password:
                cmd.extend(['password', password])
            
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            
            if result.returncode == 0:
                logger.info(f"Successfully connected to {ssid}")
                return True
            else:
                logger.error(f"Failed to connect to {ssid}: {result.stderr}")
                return False
                
        except Exception as e:
            logger.error(f"Error connecting to Wi-Fi: {e}")
            return False
    
    def _has_wifi_profiles(self) -> bool:
        """Check if there are stored Wi-Fi connection profiles"""
        try:
            result = subprocess.run(
                ['nmcli', '-t', '-f', 'TYPE,NAME', 'connection', 'show'],
                capture_output=True,
                text=True
            )
            
            for line in result.stdout.split('\n'):
                if line.startswith('802-11-wireless:'):
                    return True
            
            return False
            
        except Exception as e:
            logger.error(f"Error checking Wi-Fi profiles: {e}")
            return False
    
    def _is_wifi_connected(self) -> bool:
        """Check if Wi-Fi is currently connected"""
        try:
            wifi_device = self._get_wifi_device()
            if not wifi_device:
                return False
            
            device_proxy = self.bus.get_object(NM_BUS_NAME, wifi_device)
            device_props = dbus.Interface(device_proxy, 'org.freedesktop.DBus.Properties')
            device_state = device_props.Get(NM_DEVICE_INTERFACE, 'State')
            
            return device_state == NM_DEVICE_STATE_ACTIVATED
            
        except Exception as e:
            logger.error(f"Error checking Wi-Fi connection: {e}")
            return False
    
    def _check_connectivity(self) -> bool:
        """Check if device has network connectivity"""
        try:
            result = subprocess.run(
                ['ping', '-c', '1', '-W', '3', '8.8.8.8'],
                capture_output=True,
                timeout=5
            )
            return result.returncode == 0
        except Exception:
            return False
    
    def _perform_cloud_pairing(self) -> bool:
        """Perform cloud pairing with token"""
        logger.info("Performing cloud pairing...")
        
        # This is a placeholder - actual implementation would call cloud API
        # See documentation for API endpoint specifications
        
        try:
            # Get device MAC address
            wifi_device = self._get_wifi_device()
            if not wifi_device:
                return False
            
            device_proxy = self.bus.get_object(NM_BUS_NAME, wifi_device)
            device_props = dbus.Interface(device_proxy, 'org.freedesktop.DBus.Properties')
            mac_address = device_props.Get(NM_DEVICE_INTERFACE, 'HwAddress')
            
            # Prepare pairing data
            pairing_data = {
                'pairing_token': self.pairing_token,
                'mac_address': mac_address,
                'firmware_version': '1.0.0',
                'ip_address': self._get_ip_address()
            }
            
            logger.info(f"Pairing data: {pairing_data}")
            
            # TODO: Implement actual cloud API call
            # response = requests.post(
            #     'https://api.example.com/v1/devices/claim',
            #     json=pairing_data,
            #     timeout=30
            # )
            
            # For now, just log and return success
            logger.info("Cloud pairing would be performed here")
            return True
            
        except Exception as e:
            logger.error(f"Error performing cloud pairing: {e}")
            return False
    
    def _get_ip_address(self) -> str:
        """Get current IP address"""
        try:
            result = subprocess.run(
                ['hostname', '-I'],
                capture_output=True,
                text=True
            )
            ips = result.stdout.strip().split()
            return ips[0] if ips else 'unknown'
        except Exception:
            return 'unknown'
    
    def _load_config(self) -> Optional[Dict[str, Any]]:
        """Load configuration from file"""
        try:
            if os.path.exists(CONFIG_PATH):
                with open(CONFIG_PATH, 'r') as f:
                    config = json.load(f)
                    
                    # Update instance variables
                    self.wifi_credentials = config.get('wifi_credentials')
                    self.pairing_token = config.get('pairing_token')
                    
                    return config
        except Exception as e:
            logger.error(f"Error loading config: {e}")
        
        return None
    
    def _save_config(self, config: Dict[str, Any]):
        """Save configuration to file"""
        try:
            os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
            with open(CONFIG_PATH, 'w') as f:
                json.dump(config, f, indent=2)
        except Exception as e:
            logger.error(f"Error saving config: {e}")


def main():
    """Main entry point"""
    # Ensure running as root
    if os.geteuid() != 0:
        print("This daemon must be run as root")
        sys.exit(1)
    
    manager = ProvisioningManager()
    manager.run()


if __name__ == '__main__':
    main()
