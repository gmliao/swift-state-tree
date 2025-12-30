#!/bin/bash
# Script to test Linux build using Docker
# Usage: ./Tools/linux-build-test.sh

set -e

echo "🐳 Testing SwiftStateTree Linux build in Docker..."
echo ""

# Build Docker image
echo "📦 Building Docker image..."
docker build -f Dockerfile.linux -t swiftstatetree-linux-test .

echo ""
echo "✅ Build successful!"
echo ""
echo "To run the container interactively:"
echo "  docker run -it swiftstatetree-linux-test /bin/bash"
echo ""
echo "To run tests:"
echo "  docker run swiftstatetree-linux-test swift test"
echo ""
echo "To build only:"
echo "  docker run swiftstatetree-linux-test swift build"
