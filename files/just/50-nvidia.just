# NVIDIA-specific commands for CI-OS NVIDIA variant

# Apply NVIDIA gaming optimizations
optimize-nvidia-gaming:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "${CI_OS_VARIANT:-regular}" != "nvidia" ]]; then
        echo "⚠️  This command is only available on CI-OS NVIDIA variant"
        exit 1
    fi
    
    echo "🎮 Applying NVIDIA gaming optimizations..."
    
    # Check NVIDIA driver status
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "  ❌ NVIDIA drivers not found or not working"
        echo "     Try: sudo dnf reinstall nvidia-driver"
        exit 1
    fi
    
    echo "  🔧 Configuring NVIDIA driver settings..."
    
    # Set GPU performance mode
    if command -v nvidia-settings >/dev/null 2>&1; then
        echo "    Setting GPU performance mode to maximum..."
        nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=1" 2>/dev/null || echo "    ⚠️ Could not set performance mode"
        
        # Enable force composition pipeline for tear-free gaming
        nvidia-settings -a "[gpu:0]/ForceCompositionPipeline=On" 2>/dev/null || echo "    ⚠️ Could not enable composition pipeline"
        
        # Set maximum power limit
        nvidia-settings -a "[gpu:0]/GPUTargetFanSpeed=70" 2>/dev/null || echo "    ⚠️ Could not set fan speed"
    fi
    
    # Apply system-wide NVIDIA optimizations
    echo "  ⚙️ Applying system optimizations..."
    
    # NVIDIA module parameters
    if [[ ! -f "/etc/modprobe.d/nvidia.conf" ]] || ! grep -q "nvidia-drm.modeset=1" /etc/modprobe.d/nvidia.conf; then
        sudo tee /etc/modprobe.d/nvidia.conf >/dev/null << 'EOF'
# NVIDIA optimizations for CI-OS
options nvidia-drm modeset=1
options nvidia NVreg_UsePageAttributeTable=1
options nvidia NVreg_InitializeSystemMemoryAllocations=0
options nvidia NVreg_DynamicPowerManagement=0x02
EOF
        echo "    ✅ NVIDIA module parameters configured"
        echo "    ⚠️  Reboot required to apply module changes"
    fi
    
    # NVIDIA environment variables for all users
    if [[ ! -f "/etc/environment.d/nvidia.conf" ]]; then
        sudo tee /etc/environment.d/nvidia.conf >/dev/null << 'EOF'
# NVIDIA environment variables for CI-OS
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_PATH=/var/cache/nvidia/GLCache
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
__GL_SYNC_TO_VBLANK=1
__GL_ALLOW_UNOFFICIAL_PROTOCOL=1
__GL_THREADED_OPTIMIZATIONS=1
__GL_FSAA_MODE=0
__GL_LOG_MAX_ANISO=4
KWIN_TRIPLE_BUFFER=1
EOF
        echo "    ✅ NVIDIA environment variables configured"
    fi
    
    # Create NVIDIA cache directory
    sudo mkdir -p /var/cache/nvidia/GLCache
    sudo chmod 1777 /var/cache/nvidia/GLCache
    
    # User-specific optimizations
    echo "  👤 Applying user-specific optimizations..."
    
    # Create user NVIDIA cache directory
    mkdir -p "${HOME}/.cache/nvidia"
    
    # Add NVIDIA optimizations to user shell
    if [[ ! -f "${HOME}/.bashrc" ]] || ! grep -q "NVIDIA_GAMING" "${HOME}/.bashrc"; then
        cat >> "${HOME}/.bashrc" << 'EOF'

# NVIDIA gaming optimizations for CI-OS
export NVIDIA_GAMING=1
export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_PATH="$HOME/.cache/nvidia"
export __GL_SYNC_TO_VBLANK=1
export __GL_THREADED_OPTIMIZATIONS=1
export KWIN_TRIPLE_BUFFER=1
export WINE_CPU_TOPOLOGY=4:2
EOF
        echo "    ✅ User NVIDIA optimizations added to ~/.bashrc"
    fi
    
    echo "  ✅ NVIDIA gaming optimizations applied!"
    echo ""
    echo "Changes applied:"
    echo "  - GPU performance mode set to maximum"
    echo "  - NVIDIA driver optimizations enabled"
    echo "  - Shader cache configured for better performance"
    echo "  - Environment variables set for gaming"
    echo ""
    echo "⚠️  Reboot recommended to apply all changes"

# Monitor NVIDIA GPU performance and temperatures
nvidia-monitor:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "${CI_OS_VARIANT:-regular}" != "nvidia" ]]; then
        echo "⚠️  This command is only available on CI-OS NVIDIA variant"
        exit 1
    fi
    
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "❌ NVIDIA drivers not found. Install NVIDIA drivers first."
        exit 1
    fi
    
    echo "🎮 NVIDIA GPU Performance Monitor"
    echo "==============================="
    echo "Press Ctrl+C to stop monitoring"
    echo ""
    
    while true; do
        clear
        echo "🎮 NVIDIA GPU Status - $(date)"
        echo "=============================="
        
        # GPU utilization and memory
        nvidia-smi --query-gpu=gpu_name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits | while IFS=, read -r name gpu_util mem_util mem_used mem_total temp power_draw power_limit; do
            echo "GPU: $name"
            echo "GPU Utilization: ${gpu_util}%"
            echo "Memory Utilization: ${mem_util}%"
            echo "Memory: ${mem_used}MB / ${mem_total}MB"
            echo "Temperature: ${temp}°C"
            echo "Power: ${power_draw}W / ${power_limit}W"
            echo ""
        done
        
        # Running processes
        echo "🔧 GPU Processes:"
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | head -5 || echo "No active GPU processes"
        
        sleep 2
    done

# Test NVIDIA GPU functionality
test-nvidia:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "${CI_OS_VARIANT:-regular}" != "nvidia" ]]; then
        echo "⚠️  This command is only available on CI-OS NVIDIA variant"
        exit 1
    fi
    
    echo "🎮 Testing NVIDIA GPU functionality..."
    
    # Test nvidia-smi
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "  ✅ nvidia-smi is available"
        
        # Get basic GPU info
        gpu_info=$(nvidia-smi --query-gpu=gpu_name,driver_version,memory.total --format=csv,noheader,nounits | head -1)
        echo "  📊 GPU Info: $gpu_info"
        
        # Test GPU memory allocation
        nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | while read -r free_mem; do
            if [[ $free_mem -gt 1000 ]]; then
                echo "  ✅ GPU memory available: ${free_mem}MB"
            else
                echo "  ⚠️ Low GPU memory available: ${free_mem}MB"
            fi
        done
    else
        echo "  ❌ nvidia-smi not found. NVIDIA drivers may not be properly installed."
        exit 1
    fi
    
    # Test OpenGL
    echo "  🔍 Testing OpenGL support..."
    if command -v glxinfo >/dev/null 2>&1; then
        if glxinfo | grep -q "NVIDIA"; then
            echo "  ✅ NVIDIA OpenGL driver active"
            renderer=$(glxinfo | grep "OpenGL renderer" | cut -d':' -f2 | xargs)
            echo "     Renderer: $renderer"
        else
            echo "  ⚠️ NVIDIA OpenGL driver not active or not detected"
        fi
    else
        echo "  ⚠️ glxinfo not available (install mesa-utils for OpenGL testing)"
    fi
    
    # Test Vulkan
    echo "  🔍 Testing Vulkan support..."
    if command -v vulkaninfo >/dev/null 2>&1; then
        if vulkaninfo | grep -q "NVIDIA"; then
            echo "  ✅ NVIDIA Vulkan driver active"
        else
            echo "  ⚠️ NVIDIA Vulkan driver not detected"
        fi
    else
        echo "  ⚠️ vulkaninfo not available (install vulkan-tools for Vulkan testing)"
    fi
    
    # Test CUDA (if available)
    echo "  🔍 Testing CUDA support..."
    if command -v nvcc >/dev/null 2>&1; then
        cuda_version=$(nvcc --version | grep "release" | awk '{print $6}' | cut -d',' -f1)
        echo "  ✅ CUDA available: $cuda_version"
    else
        echo "  ⚠️ CUDA not available (install cuda-toolkit if needed)"
    fi
    
    echo "  ✅ NVIDIA GPU test complete"

# Reset NVIDIA settings to defaults
nvidia-reset:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "${CI_OS_VARIANT:-regular}" != "nvidia" ]]; then
        echo "⚠️  This command is only available on CI-OS NVIDIA variant"
        exit 1
    fi
    
    echo "🎮 Resetting NVIDIA settings to defaults..."
    echo ""
    echo "⚠️  WARNING: This will reset all NVIDIA optimizations!"
    echo "   This includes performance settings, module parameters, and environment variables."
    echo ""
    read -p "Are you sure you want to reset NVIDIA settings? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Reset cancelled."
        exit 0
    fi
    
    echo "  🔧 Resetting NVIDIA driver settings..."
    if command -v nvidia-settings >/dev/null 2>&1; then
        nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=0" 2>/dev/null || true
        nvidia-settings -a "[gpu:0]/ForceCompositionPipeline=Off" 2>/dev/null || true
        echo "    ✅ Driver settings reset"
    fi
    
    echo "  🗑️ Removing custom configurations..."
    sudo rm -f /etc/modprobe.d/nvidia.conf
    sudo rm -f /etc/environment.d/nvidia.conf
    
    # Remove user optimizations from bashrc
    if [[ -f "${HOME}/.bashrc" ]]; then
        sed -i '/# NVIDIA gaming optimizations for CI-OS/,/^$/d' "${HOME}/.bashrc"
        echo "    ✅ User optimizations removed"
    fi
    
    # Clear NVIDIA cache
    rm -rf "${HOME}/.cache/nvidia" 2>/dev/null || true
    sudo rm -rf /var/cache/nvidia 2>/dev/null || true
    echo "    ✅ NVIDIA caches cleared"
    
    echo "  ✅ NVIDIA settings reset complete!"
    echo ""
    echo "⚠️  Reboot required to fully apply changes"
    echo "   Run 'just optimize-nvidia-gaming' to re-apply optimizations"

# Troubleshoot NVIDIA issues
nvidia-troubleshoot:
    #!/usr/bin/bash
    set -euo pipefail
    if [[ "${CI_OS_VARIANT:-regular}" != "nvidia" ]]; then
        echo "⚠️  This command is only available on CI-OS NVIDIA variant"
        exit 1
    fi
    
    echo "🔧 NVIDIA Troubleshooting Guide"
    echo "==============================="
    
    echo "📋 System Information:"
    echo "  Kernel: $(uname -r)"
    echo "  OS: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
    echo ""
    
    echo "🔍 NVIDIA Hardware Detection:"
    if lspci | grep -i nvidia >/dev/null; then
        echo "  ✅ NVIDIA hardware detected:"
        lspci | grep -i nvidia | while read -r line; do
            echo "    $line"
        done
    else
        echo "  ❌ No NVIDIA hardware detected"
        echo "     - Check that NVIDIA GPU is properly seated"
        echo "     - Verify GPU power connections"
        exit 1
    fi
    echo ""
    
    echo "🔍 NVIDIA Driver Status:"
    if lsmod | grep -q nvidia; then
        echo "  ✅ NVIDIA kernel modules loaded:"
        lsmod | grep nvidia | while read -r module rest; do
            echo "    $module"
        done
    else
        echo "  ❌ NVIDIA kernel modules not loaded"
        echo "     Try: sudo modprobe nvidia"
    fi
    echo ""
    
    echo "🔍 Driver Installation:"
    if rpm -qa | grep -q nvidia-driver; then
        echo "  ✅ NVIDIA driver packages installed:"
        rpm -qa | grep nvidia-driver | head -3
    else
        echo "  ❌ NVIDIA driver packages not found"
        echo "     Try: sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda"
    fi
    echo ""
    
    echo "🔍 Common Issues and Solutions:"
    echo "  1. Black screen after boot:"
    echo "     - Boot with 'nomodeset' kernel parameter"
    echo "     - Reinstall drivers: sudo dnf reinstall nvidia-driver"
    echo ""
    echo "  2. nvidia-smi not working:"
    echo "     - Check kernel modules: sudo modprobe nvidia"
    echo "     - Rebuild modules: sudo akmods --force"
    echo ""
    echo "  3. Poor gaming performance:"
    echo "     - Run: just optimize-nvidia-gaming"
    echo "     - Check power settings in nvidia-settings"
    echo ""
    echo "  4. Multiple GPU issues:"
    echo "     - Check which GPU is active: prime-run glxinfo"
    echo "     - Switch GPUs: nvidia-settings"
    echo ""
    echo "For more help, check: /var/log/nvidia-installer.log"