#!/usr/bin/env python3
"""
Unit Tests for CI-OS Provisioning Manager

Run with: python3 -m pytest test_provisioning.py -v
"""

import unittest
from unittest.mock import Mock, patch, MagicMock
import sys
import os
import json
from datetime import datetime

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

# Mock dbus before importing
sys.modules['dbus'] = MagicMock()
sys.modules['dbus.mainloop'] = MagicMock()
sys.modules['dbus.mainloop.glib'] = MagicMock()
sys.modules['gi'] = MagicMock()
sys.modules['gi.repository'] = MagicMock()

from provisioning_manager import (
    ConnectivityState,
    ProvisioningManager,
)


class TestConnectivityState(unittest.TestCase):
    """Test the connectivity state enum"""
    
    def test_state_values(self):
        """Test all states are defined"""
        states = [
            ConnectivityState.BOOT_INIT,
            ConnectivityState.ETHERNET_VERIFY,
            ConnectivityState.WIFI_CONNECT,
            ConnectivityState.INTERNET_CHECK,
            ConnectivityState.HOTSPOT_MODE,
            ConnectivityState.PROVISIONING,
            ConnectivityState.PAIRING,
            ConnectivityState.OPERATIONAL
        ]
        
        # Should have 8 unique states
        self.assertEqual(len(set(states)), 8)


class TestProvisioningManager(unittest.TestCase):
    """Test the ProvisioningManager class"""
    
    def setUp(self):
        """Set up test fixtures"""
        # Mock D-Bus and GLib
        with patch('dbus.SystemBus'), \
             patch('dbus.mainloop.glib.DBusGMainLoop'):
            self.manager = ProvisioningManager()
    
    def test_initialization(self):
        """Test manager initializes in BOOT_INIT state"""
        self.assertEqual(self.manager.state, ConnectivityState.BOOT_INIT)
        self.assertTrue(self.manager.running)
        self.assertFalse(self.manager.hotspot_active)
        self.assertIsNone(self.manager.wifi_credentials)
        self.assertIsNone(self.manager.pairing_token)
    
    @patch('os.makedirs')
    def test_scan_cache_directory_creation(self, mock_makedirs):
        """Test that scan cache directory is created"""
        with patch('dbus.SystemBus'), \
             patch('dbus.mainloop.glib.DBusGMainLoop'):
            manager = ProvisioningManager()
            mock_makedirs.assert_called()
    
    def test_save_scan_cache(self):
        """Test saving network scan results to cache"""
        networks = [
            {'ssid': 'TestNetwork', 'strength': 85, 'security': 'WPA2'},
            {'ssid': 'OpenNetwork', 'strength': 60, 'security': 'Open'}
        ]
        
        with patch('builtins.open', unittest.mock.mock_open()) as mock_file:
            self.manager._save_scan_cache(networks)
            mock_file.assert_called_once()
    
    def test_load_config(self):
        """Test loading configuration from file"""
        config_data = {
            'wifi_credentials': {
                'ssid': 'MyNetwork',
                'password': 'password123'
            },
            'pairing_token': 'ABC123',
            'new_credentials': True
        }
        
        with patch('os.path.exists', return_value=True), \
             patch('builtins.open', unittest.mock.mock_open(
                 read_data=json.dumps(config_data)
             )):
            config = self.manager._load_config()
            
            self.assertIsNotNone(config)
            self.assertEqual(
                self.manager.wifi_credentials['ssid'],
                'MyNetwork'
            )
            self.assertEqual(self.manager.pairing_token, 'ABC123')
    
    def test_save_config(self):
        """Test saving configuration to file"""
        config = {
            'wifi_credentials': {
                'ssid': 'TestNetwork',
                'password': 'test123'
            },
            'pairing_token': 'XYZ789'
        }
        
        with patch('os.makedirs'), \
             patch('builtins.open', unittest.mock.mock_open()) as mock_file:
            self.manager._save_config(config)
            mock_file.assert_called_once()


class TestStateTransitions(unittest.TestCase):
    """Test FSM state transitions"""
    
    def setUp(self):
        """Set up test fixtures"""
        with patch('dbus.SystemBus'), \
             patch('dbus.mainloop.glib.DBusGMainLoop'):
            self.manager = ProvisioningManager()
    
    def test_boot_init_to_ethernet_verify(self):
        """Test transition from BOOT_INIT to ETHERNET_VERIFY"""
        self.manager.state = ConnectivityState.BOOT_INIT
        
        with patch.object(self.manager.nm, 'state', return_value=70):
            self.manager._handle_boot_init()
            
        self.assertEqual(
            self.manager.state,
            ConnectivityState.ETHERNET_VERIFY
        )
    
    @patch('subprocess.run')
    def test_internet_check_success(self, mock_run):
        """Test successful internet connectivity check"""
        mock_run.return_value = Mock(
            returncode=0,
            stdout='success'
        )
        
        self.manager.state = ConnectivityState.INTERNET_CHECK
        self.manager.pairing_token = None
        
        self.manager._handle_internet_check()
        
        self.assertEqual(
            self.manager.state,
            ConnectivityState.OPERATIONAL
        )
    
    @patch('subprocess.run')
    def test_internet_check_with_token(self, mock_run):
        """Test internet check transitions to PAIRING when token present"""
        mock_run.return_value = Mock(
            returncode=0,
            stdout='success'
        )
        
        self.manager.state = ConnectivityState.INTERNET_CHECK
        self.manager.pairing_token = 'ABC123'
        
        self.manager._handle_internet_check()
        
        self.assertEqual(
            self.manager.state,
            ConnectivityState.PAIRING
        )


class TestHelperMethods(unittest.TestCase):
    """Test helper methods"""
    
    def setUp(self):
        """Set up test fixtures"""
        with patch('dbus.SystemBus'), \
             patch('dbus.mainloop.glib.DBusGMainLoop'):
            self.manager = ProvisioningManager()
    
    @patch('subprocess.run')
    def test_check_connectivity_success(self, mock_run):
        """Test connectivity check returns True when online"""
        mock_run.return_value = Mock(returncode=0)
        
        result = self.manager._check_connectivity()
        
        self.assertTrue(result)
        mock_run.assert_called_once()
    
    @patch('subprocess.run')
    def test_check_connectivity_failure(self, mock_run):
        """Test connectivity check returns False when offline"""
        mock_run.return_value = Mock(returncode=1)
        
        result = self.manager._check_connectivity()
        
        self.assertFalse(result)
    
    @patch('subprocess.run')
    def test_has_wifi_profiles_true(self, mock_run):
        """Test detecting existing Wi-Fi profiles"""
        mock_run.return_value = Mock(
            stdout='802-11-wireless:MyNetwork\n'
        )
        
        result = self.manager._has_wifi_profiles()
        
        self.assertTrue(result)
    
    @patch('subprocess.run')
    def test_has_wifi_profiles_false(self, mock_run):
        """Test when no Wi-Fi profiles exist"""
        mock_run.return_value = Mock(
            stdout='802-3-ethernet:Wired connection 1\n'
        )
        
        result = self.manager._has_wifi_profiles()
        
        self.assertFalse(result)
    
    @patch('subprocess.run')
    def test_connect_to_wifi_success(self, mock_run):
        """Test successful Wi-Fi connection"""
        mock_run.return_value = Mock(returncode=0)
        
        credentials = {
            'ssid': 'TestNetwork',
            'password': 'password123'
        }
        
        result = self.manager._connect_to_wifi(credentials)
        
        self.assertTrue(result)
    
    @patch('subprocess.run')
    def test_connect_to_wifi_failure(self, mock_run):
        """Test failed Wi-Fi connection"""
        mock_run.return_value = Mock(
            returncode=1,
            stderr='Connection failed'
        )
        
        credentials = {
            'ssid': 'TestNetwork',
            'password': 'wrongpassword'
        }
        
        result = self.manager._connect_to_wifi(credentials)
        
        self.assertFalse(result)


class TestHotspotManagement(unittest.TestCase):
    """Test hotspot activation and deactivation"""
    
    def setUp(self):
        """Set up test fixtures"""
        with patch('dbus.SystemBus'), \
             patch('dbus.mainloop.glib.DBusGMainLoop'):
            self.manager = ProvisioningManager()
    
    @patch('subprocess.run')
    @patch('time.sleep')
    def test_activate_hotspot_success(self, mock_sleep, mock_run):
        """Test successful hotspot activation"""
        # Mock NetworkManager device
        mock_device_proxy = Mock()
        mock_device_props = Mock()
        mock_device_props.Get.side_effect = [
            'wlan0',  # Interface name
            'aa:bb:cc:dd:ee:ff'  # MAC address
        ]
        
        with patch.object(
            self.manager.bus,
            'get_object',
            return_value=mock_device_proxy
        ), patch('dbus.Interface', return_value=mock_device_props), \
           patch.object(
               self.manager,
               '_get_wifi_device',
               return_value='/org/freedesktop/NetworkManager/Devices/1'
           ), patch.object(
               self.manager,
               '_setup_captive_dns'
           ):
            
            mock_run.return_value = Mock(returncode=0)
            
            result = self.manager._activate_hotspot()
            
            self.assertTrue(result)
    
    @patch('subprocess.run')
    @patch('os.path.exists', return_value=True)
    @patch('os.remove')
    def test_deactivate_hotspot(self, mock_remove, mock_exists, mock_run):
        """Test hotspot deactivation"""
        self.manager._deactivate_hotspot()
        
        mock_remove.assert_called_once()
        mock_run.assert_called_once()


class TestConfigurationParsing(unittest.TestCase):
    """Test configuration file parsing"""
    
    def setUp(self):
        """Set up test fixtures"""
        with patch('dbus.SystemBus'), \
             patch('dbus.mainloop.glib.DBusGMainLoop'):
            self.manager = ProvisioningManager()
    
    def test_parse_valid_config(self):
        """Test parsing valid configuration"""
        config_json = json.dumps({
            'wifi_credentials': {
                'ssid': 'TestNetwork',
                'password': 'password123'
            },
            'pairing_token': 'ABC123',
            'new_credentials': True
        })
        
        with patch('os.path.exists', return_value=True), \
             patch('builtins.open',
                   unittest.mock.mock_open(read_data=config_json)):
            config = self.manager._load_config()
            
            self.assertIsNotNone(config)
            self.assertTrue(config['new_credentials'])
    
    def test_parse_missing_config(self):
        """Test handling missing configuration file"""
        with patch('os.path.exists', return_value=False):
            config = self.manager._load_config()
            
            self.assertIsNone(config)


if __name__ == '__main__':
    unittest.main()
