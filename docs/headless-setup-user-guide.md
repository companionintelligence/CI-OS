# CI OS Headless Setup - User Guide

## What is Headless Setup?

Headless Setup allows you to configure your CI OS device's WiFi connection and link it to your account **without needing a keyboard, mouse, or display**. Simply use your smartphone or laptop to connect to the device and complete setup through a simple web interface.

## Before You Begin

You'll need:
- ✅ Your CI OS device (powered on)
- ✅ A smartphone, tablet, or laptop with WiFi
- ✅ Your home WiFi network name and password
- ✅ A pairing code from [setup.ci.computer](https://setup.ci.computer)

## Getting Your Pairing Code

1. Visit **[setup.ci.computer](https://setup.ci.computer)** on any device
2. Create an account or log in
3. Click **"Add New Device"**
4. Write down your pairing code (e.g., **X25-RJ8**)
5. Keep this code handy for the setup process

## Setup Steps

### Step 1: Power On Your Device

1. Connect your CI OS device to power
2. Turn it on
3. Wait **1-2 minutes** for it to start up

### Step 2: Find the Setup WiFi Network

On your phone, tablet, or laptop:

1. Open **WiFi settings**
2. Look for a network named: **CI-OS-Setup**
3. Connect to this network
   - No password required
   - It's an open network

### Step 3: Open the Setup Portal

The setup portal should open **automatically** when you connect. If not:

**On iOS/Android:**
- A notification may appear saying "Sign in to network"
- Tap the notification to open the setup page

**On Windows/Mac/Linux:**
- Open any web browser
- Try to visit any website (e.g., http://example.com)
- You'll be redirected to the setup page

**If nothing happens:**
- Manually open a browser
- Go to: **http://10.42.0.1**

### Step 4: Complete the Setup Form

You'll see a friendly setup page with three sections:

#### 1. Enter Your Pairing Code

- Type in the pairing code from setup.ci.computer
- Format: **XXX-XXX** (e.g., X25-RJ8)
- Use uppercase letters and numbers

#### 2. Select Your WiFi Network

- Click **"🔍 Scan for Networks"** button
- Wait a moment for nearby networks to appear
- Select your home WiFi network from the list
- **OR** click "Enter manually..." to type it in

#### 3. Enter WiFi Password

- Type in your WiFi network password
- Make sure it's correct (double-check!)
- Your password is encrypted and stored securely

### Step 5: Submit and Wait

1. Click **"Complete Setup"** button
2. Wait while your device:
   - Connects to your WiFi network
   - Links to your account
   - Completes configuration
3. You'll see a success message when done

### Step 6: You're Done!

✅ Your CI OS device is now:
- Connected to your WiFi network
- Linked to your account
- Ready to use

The setup WiFi network will disappear, and you can disconnect from it.

## Troubleshooting

### Problem: Can't find "CI-OS-Setup" WiFi network

**Solutions:**
- Wait a bit longer (up to 3 minutes after power on)
- Make sure the device has a WiFi adapter
- Move closer to the device
- Restart the device and try again

### Problem: Captive portal doesn't open automatically

**Solutions:**
- Manually visit: http://10.42.0.1
- Try opening any HTTP website (not HTTPS)
- Disable VPN if you're using one
- Try a different device

### Problem: "Failed to connect to WiFi network" error

**Solutions:**
- Double-check your WiFi password
- Make sure you selected the correct network
- Check if your router is working
- Try entering the network name manually

### Problem: Setup page is slow or unresponsive

**Solutions:**
- Stay close to the device
- Make sure you're connected to "CI-OS-Setup" network
- Wait a moment - it may be scanning for networks
- Refresh the page

### Problem: Invalid pairing code error

**Solutions:**
- Check you entered the code correctly
- Pairing codes are case-sensitive (use UPPERCASE)
- Get a new pairing code from setup.ci.computer
- Make sure you didn't already use this code

## Tips for Success

💡 **Stay Close**: Keep your phone/laptop near the CI OS device during setup

💡 **Use Mobile Data**: Turn off mobile data on your phone to prevent it from switching away from the setup WiFi

💡 **Check Twice**: Verify your WiFi password before submitting - it's the most common mistake

💡 **Be Patient**: The first connection to your WiFi may take 30-60 seconds

💡 **One Time Only**: This setup process only runs once. After completion, your device connects to WiFi automatically

## Security & Privacy

**Is this secure?**
- ✅ The setup WiFi is temporary (only during setup)
- ✅ Your WiFi password is encrypted before storage
- ✅ All setup happens locally on your device
- ✅ Setup portal automatically closes after completion
- ✅ Pairing codes are single-use only

**What data is sent to the cloud?**
- Only your pairing code and device ID
- This links the device to your account
- No WiFi passwords are sent to the cloud

## Need More Help?

📧 **Email Support**: support@ci-os.org

💬 **Live Chat**: Available at [setup.ci.computer](https://setup.ci.computer)

📖 **Documentation**: https://github.com/companionintelligence/ci-os/wiki

🐛 **Report Issues**: https://github.com/companionintelligence/ci-os/issues

## Frequently Asked Questions

**Q: Can I change my WiFi network later?**  
A: Yes! Use the standard system settings on your device, or contact support for assistance.

**Q: What if I don't have a pairing code?**  
A: You must get a pairing code from setup.ci.computer before starting setup. It's free and takes 1 minute.

**Q: Can I skip the cloud pairing?**  
A: The pairing code is required for setup. It links your device to your account for remote management and support.

**Q: Does this work with 5GHz WiFi?**  
A: Yes! The system supports both 2.4GHz and 5GHz networks (if your device hardware supports them).

**Q: Can I use Ethernet instead?**  
A: Not for initial setup. After setup, you can connect Ethernet and it will work alongside WiFi.

**Q: What happens if I need to reset?**  
A: Contact support. They can help you reset the device and run setup again.

## Advanced Users

If you're comfortable with command line:

**Check setup status:**
```bash
sudo systemctl status ci-os-headless-setup.service
```

**View setup logs:**
```bash
sudo tail -f /var/log/ci-os-headless-setup.log
```

**Manually trigger setup (for testing):**
```bash
sudo rm -f /var/lib/ci-os/setup-complete
sudo systemctl restart ci-os-headless-setup.service
```

---

**Congratulations on setting up your CI OS device! 🎉**

For next steps, visit your account dashboard at [setup.ci.computer](https://setup.ci.computer) to manage your device.
