# CI OS Quick Start Guide

## 🚀 Getting Started with CI OS

Welcome to CI OS! This quick start guide will help you get up and running with your new development-focused Ubuntu distribution.

### First Boot

1. **Initial Setup**
   - Default username: `cios`
   - Default password: `ci0s2024!`
   - Change password after first login: `passwd`

2. **System Update**
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

### Essential Commands

#### Development Environment
```bash
# Check installed development tools
git --version
docker --version
node --version
python3 --version

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add user to docker group (logout/login required)
sudo usermod -aG docker $USER
```

#### Gaming Setup
```bash
# Run gaming optimization script
sudo /usr/local/bin/setup-gaming.sh

# Launch Steam
steam
```

#### System Monitoring
```bash
# Check system resources
htop

# Monitor network
iftop

# Check disk usage
df -h
```

### Pre-installed Software

#### Development Tools
- **Git**: Version control system
- **Docker**: Container platform
- **Node.js**: JavaScript runtime
- **Python 3.12**: Programming language
- **Visual Studio Code**: Code editor
- **PostgreSQL**: Database server

#### Gaming
- **Steam**: Game platform
- **GameMode**: Performance optimization
- **MangoHud**: Performance overlay

#### System Tools
- **SSH Server**: Remote access
- **UFW**: Firewall management
- **Fail2ban**: Intrusion prevention
- **PM2**: Process manager

### Quick Configuration

#### SSH Access
```bash
# Enable SSH
sudo systemctl enable ssh
sudo systemctl start ssh

# Check SSH status
sudo systemctl status ssh
```

#### Firewall
```bash
# Check firewall status
sudo ufw status

# Allow specific ports
sudo ufw allow 3000  # Node.js dev server
sudo ufw allow 5432  # PostgreSQL
```

#### Docker Setup
```bash
# Test Docker installation
docker run hello-world

# Start a development container
docker run -it ubuntu:latest bash
```

### Development Workflow

#### Web Development
```bash
# Create new project
mkdir my-project && cd my-project
npm init -y

# Install dependencies
npm install express

# Start development server with PM2
pm2 start app.js --name "my-app"
pm2 monit
```

#### Database Development
```bash
# Start PostgreSQL
sudo systemctl start postgresql

# Connect to database
sudo -u postgres psql

# Create development database
createdb myapp_dev
```

### Gaming Optimization

#### Steam Setup
1. Launch Steam from applications menu
2. Log in with your Steam account
3. Enable Proton for Windows games:
   - Steam → Settings → Steam Play
   - Check "Enable Steam Play for all other titles"

#### Performance Monitoring
```bash
# Launch game with performance overlay
mangohud steam

# Use GameMode for better performance
gamemoderun steam
```

### Troubleshooting

#### Common Issues

**Docker Permission Denied**
```bash
sudo usermod -aG docker $USER
# Logout and login again
```

**Steam Won't Start**
```bash
# Install additional 32-bit libraries
sudo apt install steam-devices
```

**Graphics Issues**
```bash
# Check graphics driver
lspci -k | grep -A 2 -i "VGA"

# Install NVIDIA drivers (if needed)
sudo ubuntu-drivers autoinstall
```

### Support Resources

- **Documentation**: `/usr/share/doc/ci-os/`
- **Log Files**: `/var/log/`
- **System Info**: `sudo dmidecode -t system`

### Next Steps

1. **Customize Environment**
   - Install additional development tools
   - Configure shell (zsh, oh-my-zsh)
   - Set up development configurations

2. **Explore Gaming**
   - Install games from Steam
   - Configure graphics settings
   - Join gaming communities

3. **Set Up Projects**
   - Clone repositories
   - Configure CI/CD pipelines
   - Set up development databases

### Getting Help

- Check `/usr/share/doc/ci-os/` for detailed documentation
- Visit GitHub repository for issues and discussions
- Community forums and support channels

---

🎉 **Welcome to CI OS!** You're now ready to develop, game, and create with your optimized Ubuntu environment.
