# CI-OS v01 Setup and Configuration Commands
# These commands provide setup wizards and configuration tools for CI-OS

# Complete CI-OS setup wizard
setup-ci-os:
    #!/usr/bin/bash
    set -euo pipefail
    echo "🚀 CI-OS v01 Setup Wizard"
    echo "========================="
    echo ""
    echo "This will configure Wine, Proton tools, and WinApps prerequisites."
    echo "The setup process may take 10-15 minutes depending on your system."
    echo ""
    read -p "Continue with setup? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
    echo ""
    echo "📦 Setting up Wine environment..."
    just setup-wine
    echo ""
    echo "⚙️ Setting up Proton tools..."
    just setup-proton
    echo ""
    echo "🖥️ Setting up WinApps prerequisites..."
    just setup-winapps
    echo ""
    echo "✅ CI-OS setup complete!"
    echo ""
    echo "Next steps:"
    echo "  - Run 'just ci-os-info' to see system information"
    echo "  - Run 'just run-wine <app.exe>' to test Wine"
    echo "  - See 'just --list' for all available commands"
    
# NVIDIA-optimized CI-OS setup
setup-ci-os-nvidia:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "${CI_OS_VARIANT:-regular}" != "nvidia" ]]; then
        echo "⚠️  This command is only available on CI-OS NVIDIA variant"
        echo "   Current variant: ${CI_OS_VARIANT:-regular}"
        exit 1
    fi
    echo "🚀 CI-OS NVIDIA v01 Setup Wizard"
    echo "================================"
    echo ""
    echo "This will configure Wine with NVIDIA optimizations, Proton tools, and GPU passthrough."
    echo "The setup process may take 15-20 minutes depending on your system."
    echo ""
    read -p "Continue with NVIDIA setup? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
    echo ""
    echo "🎮 Checking NVIDIA drivers..."
    just nvidia-info
    echo ""
    echo "📦 Setting up Wine with NVIDIA optimizations..."
    just setup-wine
    echo ""
    echo "⚙️ Setting up Proton tools..."
    just setup-proton  
    echo ""
    echo "🖥️ Setting up WinApps with GPU passthrough..."
    just setup-winapps
    echo ""
    echo "🔧 Applying NVIDIA gaming optimizations..."
    just optimize-nvidia-gaming
    echo ""
    echo "✅ CI-OS NVIDIA setup complete!"
    echo ""
    echo "Next steps:"
    echo "  - Run 'just nvidia-info' to verify GPU status"
    echo "  - Run 'just test-nvidia-wine' to test Wine+NVIDIA"
    echo "  - See 'just --list' for all available commands"

# Display CI-OS system information
ci-os-info:
    #!/usr/bin/bash
    set -euo pipefail
    echo "📋 CI-OS System Information"
    echo "=========================="
    echo "Version: ${CI_OS_VERSION:-unknown}"
    echo "Variant: ${CI_OS_VARIANT:-unknown}"
    echo "Base: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
    echo "Kernel: $(uname -r)"
    echo ""
    echo "🍷 Wine Information:"
    if command -v wine >/dev/null 2>&1; then
        echo "  Wine: $(wine --version)"
        echo "  Wine Prefix: ${WINEPREFIX:-$HOME/.wine}"
        echo "  Wine Arch: ${WINEARCH:-win64}"
    else
        echo "  Wine: Not installed"
    fi
    echo ""
    echo "⚙️ Proton Information:"
    if command -v protontricks >/dev/null 2>&1; then
        echo "  Protontricks: $(protontricks --version 2>/dev/null || echo 'Available')"
    else
        echo "  Protontricks: Not available"
    fi
    echo ""
    echo "💻 WinApps Information:"
    if [[ -d "/usr/share/ci-os/winapps" ]]; then
        echo "  WinApps: Installed"
        echo "  Location: /usr/share/ci-os/winapps"
    else
        echo "  WinApps: Not installed"
    fi
    echo ""
    echo "🖥️ System Resources:"
    echo "  Memory: $(free -h | awk '/^Mem:/ {print $2}') total, $(free -h | awk '/^Mem:/ {print $7}') available"
    echo "  Storage: $(df -h / | awk 'NR==2 {print $2}') total, $(df -h / | awk 'NR==2 {print $4}') available"
    echo ""

# NVIDIA-specific information and status
nvidia-info:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "${CI_OS_VARIANT:-regular}" != "nvidia" ]]; then
        echo "⚠️  This command is only available on CI-OS NVIDIA variant"
        exit 1
    fi
    echo "🎮 NVIDIA System Information"
    echo "=========================="
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "📊 GPU Status:"
        nvidia-smi --query-gpu=gpu_name,driver_version,memory.total,temperature.gpu --format=csv,noheader,nounits | while IFS=, read -r name version memory temp; do
            echo "  GPU: $name"
            echo "  Driver: $version"
            echo "  Memory: ${memory}MB"
            echo "  Temperature: ${temp}°C"
        done
        echo ""
        echo "🔧 NVIDIA Processes:"
        nvidia-smi --query-compute-apps=pid,process_name,gpu_uuid,used_memory --format=csv,noheader 2>/dev/null | head -5 || echo "  No active NVIDIA processes"
    else
        echo "❌ NVIDIA drivers not detected or not working"
        echo "   Try: sudo dnf reinstall nvidia-driver"
    fi
    echo ""
    echo "🍷 NVIDIA Wine Integration:"
    if [[ -n "${__GL_SHADER_DISK_CACHE:-}" ]]; then
        echo "  ✅ NVIDIA Wine optimizations enabled"
        echo "  Cache path: ${__GL_SHADER_DISK_CACHE_PATH:-/home/$USER/.cache/nvidia}"
    else
        echo "  ⚠️  NVIDIA Wine optimizations not configured"
    fi