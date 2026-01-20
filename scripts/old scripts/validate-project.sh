#!/bin/bash
# CI OS Project Validation Script
# Ensures all project components are properly set up

set -e

PROJECT_DIR="/Users/williambroza/devel/ci-os"
echo "=== CI OS Project Validation ==="
echo "Project Directory: $PROJECT_DIR"
echo ""

# Check directory structure
echo "📁 Checking project structure..."

REQUIRED_DIRS=(
    "assets/logos"
    "assets/icons" 
    "assets/wallpapers"
    "assets/branding"
    "cubic-project"
    "scripts"
    "configs/packages"
    "configs/preseed"
    "configs/boot"
    "configs/scripts"
    "docs"
    "iso/base"
    "iso/output"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [ -d "$PROJECT_DIR/$dir" ]; then
        echo "✅ $dir"
    else
        echo "❌ $dir (missing)"
    fi
done

echo ""
echo "📄 Checking essential files..."

REQUIRED_FILES=(
    "README.md"
    "LICENSE"
    "CONTRIBUTING.md"
    "CHANGELOG.md"
    "assets/logos/holo-ci.png"
    "assets/logos/2024_CI__Logo_Banner_Black.png"
    "assets/logos/2024_CI__Logo_Banner_Color_small.svg"
    "assets/logos/2024_CI__LogoMark_black.png"
    "assets/logos/2024_CI__LogoMark_Color_med.svg"
    "assets/icons/ci-os-icon.svg"
    "assets/wallpapers/ci-os-wallpaper.svg"
    "assets/branding/brand-guidelines.md"
    "scripts/build-ci-os.sh"
    "scripts/test-ci-os.sh"
    "scripts/ci-server-setup-ubuntu-amd.sh"
    "scripts/ci-server-linux-dev-setup.sh"
    "scripts/setup-gaming.sh"
    "configs/packages/package-list.txt"
    "configs/preseed/ci-os.preseed"
    "configs/boot/grub-default"
    "configs/scripts/ci-os-customization.sh"
    "docs/cubic-customization-plan.md"
    "docs/installation-guide.md"
    "docs/quick-start-guide.md"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$PROJECT_DIR/$file" ]; then
        echo "✅ $file"
    else
        echo "❌ $file (missing)"
    fi
done

echo ""
echo "🔧 Checking script permissions..."

SCRIPT_FILES=(
    "scripts/build-ci-os.sh"
    "scripts/test-ci-os.sh"
    "scripts/ci-server-setup-ubuntu-amd.sh"
    "scripts/ci-server-linux-dev-setup.sh"
    "scripts/setup-gaming.sh"
    "configs/scripts/ci-os-customization.sh"
)

for script in "${SCRIPT_FILES[@]}"; do
    if [ -x "$PROJECT_DIR/$script" ]; then
        echo "✅ $script (executable)"
    else
        echo "⚠️  $script (not executable)"
        chmod +x "$PROJECT_DIR/$script" 2>/dev/null && echo "   → Fixed permissions"
    fi
done

echo ""
echo "📊 Project statistics..."

# Count files by type
SVG_COUNT=$(find "$PROJECT_DIR/assets" -name "*.svg" 2>/dev/null | wc -l)
SH_COUNT=$(find "$PROJECT_DIR" -name "*.sh" 2>/dev/null | wc -l)
MD_COUNT=$(find "$PROJECT_DIR" -name "*.md" 2>/dev/null | wc -l)
TXT_COUNT=$(find "$PROJECT_DIR" -name "*.txt" 2>/dev/null | wc -l)

echo "   SVG assets: $SVG_COUNT"
echo "   Shell scripts: $SH_COUNT"
echo "   Markdown docs: $MD_COUNT"
echo "   Text files: $TXT_COUNT"

# Check for git repository
echo ""
echo "🔗 Git repository status..."
if [ -d "$PROJECT_DIR/.git" ]; then
    cd "$PROJECT_DIR"
    echo "✅ Git repository initialized"
    echo "   Current branch: $(git branch --show-current 2>/dev/null || echo 'No branch')"
    echo "   Commits: $(git rev-list --count HEAD 2>/dev/null || echo '0')"
    echo "   Status: $(git status --porcelain | wc -l) uncommitted changes"
else
    echo "⚠️  No git repository found"
    echo "   To initialize: cd $PROJECT_DIR && git init"
fi

echo ""
echo "🎯 Next steps for CI OS development:"
echo ""
echo "1. 📥 Install Cubic:"
echo "   Ubuntu: sudo apt install cubic"
echo "   Debian: Follow instructions in docs/cubic-customization-plan.md"
echo ""
echo "2. 💿 Download Ubuntu 24.04 LTS ISO:"
echo "   ./scripts/build-ci-os.sh"
echo ""
echo "3. 🔨 Build CI OS:"
echo "   - Launch Cubic"
echo "   - Create project in cubic-project/"
echo "   - Follow docs/cubic-customization-plan.md"
echo ""
echo "4. 🧪 Test CI OS:"
echo "   ./scripts/test-ci-os.sh"
echo ""
echo "5. 📖 Read documentation:"
echo "   - docs/installation-guide.md"
echo "   - docs/quick-start-guide.md"
echo "   - assets/branding/brand-guidelines.md"
echo ""

# Check system readiness for development
echo "💻 System readiness check..."

# Check for required tools
TOOLS=(
    "git:Git version control"
    "curl:HTTP client"
    "svg2png:SVG converter (optional)"
    "qemu-system-x86_64:VM testing (optional)"
)

for tool_info in "${TOOLS[@]}"; do
    tool="${tool_info%%:*}"
    desc="${tool_info#*:}"
    if command -v "$tool" &> /dev/null; then
        echo "✅ $tool ($desc)"
    else
        echo "⚠️  $tool ($desc) - not installed"
    fi
done

echo ""
echo "=== CI OS Project Validation Complete ==="
echo ""
echo "🎉 Your CI OS project is ready for development!"
echo "📋 Follow the Cubic customization plan to build your first ISO."
echo "🤝 See CONTRIBUTING.md for development guidelines."
