#!/bin/bash
# Script to test Linux build using Docker (Dev Container)
# Usage: ./Tools/linux-build-test.sh
#
# Note: This script uses the Dev Container Dockerfile.
# For a better development experience, use VS Code Dev Containers instead.

set -e

echo "🐳 Testing SwiftStateTree Linux build in Docker (using Dev Container Dockerfile)..."
echo ""

# Build Docker image using Dev Container Dockerfile
echo "📦 Building Docker image..."
docker build -f .devcontainer/Dockerfile -t swiftstatetree-dev .

echo ""
echo "✅ Build successful!"
echo ""
echo "To run the container interactively:"
echo "  docker run -it -v \$(pwd):/workspace swiftstatetree-dev /bin/bash"
echo ""
echo "To run tests:"
echo "  docker run -v \$(pwd):/workspace swiftstatetree-dev swift test"
echo ""
echo "To build only:"
echo "  docker run -v \$(pwd):/workspace swiftstatetree-dev swift build"
echo ""
echo "💡 Tip: For a better development experience, use VS Code Dev Containers:"
echo "  1. Install Dev Containers extension"
echo "  2. Press F1 and select 'Dev Containers: Reopen in Container'"
