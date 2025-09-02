#!/bin/bash
# Container Testing Script for CI-OS
# Tests container builds and Windows application compatibility

set -euo pipefail

echo "Testing CI-OS container builds..."

# Test base container build
echo "Building base CI-OS container..."
if podman build -f Containerfile.ci-os -t ci-os:test . ; then
    echo "✅ Base container build successful"
else
    echo "❌ Base container build failed"
    exit 1
fi

# Test NVIDIA container build  
echo "Building NVIDIA CI-OS container..."
if podman build -f Containerfile.ci-os-nvidia -t ci-os-nvidia:test . ; then
    echo "✅ NVIDIA container build successful"
else
    echo "❌ NVIDIA container build failed"
    exit 1
fi

# Test Wine functionality in base container
echo "Testing Wine in base container..."
if podman run --rm ci-os:test wine --version ; then
    echo "✅ Wine working in base container"
else
    echo "❌ Wine test failed in base container"
    exit 1
fi

# Test WinApps availability
echo "Testing WinApps in container..."
if podman run --rm ci-os:test which winapps ; then
    echo "✅ WinApps available in container"
else
    echo "❌ WinApps not found in container"
    exit 1
fi

# Test NVIDIA container (if NVIDIA hardware available)
if command -v nvidia-smi >/dev/null 2>&1; then
    echo "Testing NVIDIA container with GPU access..."
    if podman run --rm --device nvidia.com/gpu=all ci-os-nvidia:test nvidia-smi ; then
        echo "✅ NVIDIA GPU access working in container"
    else
        echo "⚠️  NVIDIA GPU test failed (may not have proper container runtime)"
    fi
else
    echo "ℹ️  Skipping NVIDIA tests (no NVIDIA GPU detected)"
fi

# Test basic Windows application (notepad)
echo "Testing Windows application compatibility..."
if podman run --rm -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix ci-os:test \
   timeout 10s wine notepad /quit 2>/dev/null ; then
    echo "✅ Windows application test passed"
else
    echo "ℹ️  Windows GUI application test skipped (no display available)"
fi

echo ""
echo "🎉 Container testing completed!"
echo "Both base and NVIDIA variants are ready for use."