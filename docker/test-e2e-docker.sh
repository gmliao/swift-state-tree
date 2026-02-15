#!/usr/bin/env bash
# Requires: Docker, Node.js, npm. Run from repo root.
# Build DemoServer Docker image, run container, and execute E2E tests against it.
# Usage: ./docker/test-e2e-docker.sh [encoding]
#   encoding: json|jsonOpcode|messagepack (default: runs all three)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

IMAGE_TAG="${DOCKER_DEMO_TAG:-swift-state-tree-demo:e2e}"
CONTAINER_NAME="demo-e2e-$$"
PORT=8080

cleanup() {
    echo "Stopping container..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=========================================="
echo "  Docker E2E Test"
echo "=========================================="

# Build image
echo ""
echo "Building Docker image: $IMAGE_TAG"
docker build -f docker/Dockerfile.DemoServer -t "$IMAGE_TAG" .

echo ""
echo "Image size:"
docker images "$IMAGE_TAG" --format "{{.Size}}"

# Run encoding tests
run_encoding() {
    local encoding=$1
    local test_cmd=""
    case "$encoding" in
        json) test_cmd="npm run test:e2e:jsonObject" ;;
        jsonOpcode) test_cmd="npm run test:e2e:opcodeJsonArray" ;;
        messagepack) test_cmd="npm run test:e2e:messagepack" ;;
        *) echo "Unknown encoding: $encoding"; return 1 ;;
    esac

    echo ""
    echo "=========================================="
    echo "  Testing encoding: $encoding"
    echo "=========================================="

    # Start container
    docker run -d --rm --name "$CONTAINER_NAME" \
        -p ${PORT}:8080 \
        -e TRANSPORT_ENCODING="$encoding" \
        "$IMAGE_TAG"

    # Wait for server
    echo "Waiting for server..."
    for i in $(seq 1 30); do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/schema" 2>/dev/null | grep -q 200; then
            echo "Server ready."
            break
        fi
        if [ $i -eq 30 ]; then
            echo "Server failed to start. Logs:"
            docker logs "$CONTAINER_NAME"
            return 1
        fi
        sleep 1
    done

    # Run E2E tests
    cd "$REPO_ROOT/Tools/CLI"
    TRANSPORT_ENCODING="$encoding" $test_cmd
    local result=$?
    cd "$REPO_ROOT"

    # Stop container before next encoding
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true

    return $result
}

# Main
if [ -n "$1" ]; then
    run_encoding "$1"
else
    failed=0
    for enc in json jsonOpcode messagepack; do
        if ! run_encoding "$enc"; then
            failed=1
        fi
    done
    exit $failed
fi
