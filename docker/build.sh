#!/usr/bin/env bash
# Docker build script for SwiftStateTree servers
# Builds build image and run images (DemoServer, GameServer)
# Usage: ./docker/build.sh [demo|game|build|all]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Default tags
BUILD_IMAGE_TAG="${DOCKER_BUILD_TAG:-swift-state-tree:build}"
DEMO_RUN_TAG="${DOCKER_DEMO_TAG:-swift-state-tree-demo:latest}"
GAME_RUN_TAG="${DOCKER_GAME_TAG:-swift-state-tree-game:latest}"

build_build_image() {
    echo "Building build image: $BUILD_IMAGE_TAG"
    docker build -f docker/Dockerfile.build -t "$BUILD_IMAGE_TAG" .
}

build_demo_run() {
    echo "Building DemoServer run image: $DEMO_RUN_TAG"
    docker build -f docker/Dockerfile.DemoServer -t "$DEMO_RUN_TAG" .
}

build_game_run() {
    echo "Building GameServer run image: $GAME_RUN_TAG"
    docker build -f docker/Dockerfile.GameServer -t "$GAME_RUN_TAG" .
}

case "${1:-all}" in
    build)
        build_build_image
        ;;
    demo)
        build_demo_run
        ;;
    game)
        build_game_run
        ;;
    all)
        build_build_image
        build_demo_run
        build_game_run
        echo ""
        echo "Done. Images:"
        echo "  Build: $BUILD_IMAGE_TAG"
        echo "  DemoServer (run): $DEMO_RUN_TAG"
        echo "  GameServer (run): $GAME_RUN_TAG"
        ;;
    *)
        echo "Usage: $0 [build|demo|game|all]"
        echo "  build - Build image only (for CI/compilation)"
        echo "  demo  - DemoServer run image only"
        echo "  game  - GameServer run image only"
        echo "  all   - All images (default)"
        exit 1
        ;;
esac
